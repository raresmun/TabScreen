package local.tabscreen.viewer;

import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaCodecList;
import android.media.MediaFormat;
import android.os.Build;
import android.os.Process;
import android.util.Log;
import android.view.Surface;

import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Locale;

/**
 * The tablet's hardware H.264 decoder, drawing straight onto the screen. It is set up to hand out every frame the
 * moment it's decoded (no buffering), and each frame is shown at the very next screen refresh.
 */
final class VideoDecoder {
    interface Callback {
        /** The first picture after (re)connecting is on screen. */
        void onFirstFrame();

        /** A line for the Mac's TabScreen.log. */
        void onReport(String text);

        /** No decoder on this tablet could start (it keeps retrying for a while). */
        void onDecoderFailed();
    }

    private static final String TAG = "TabScreen";
    private static final String MIME = "video/avc";
    private static final int MAX_RESTARTS = 8;   // per connection; after that, wait for the next connection

    // Low-latency settings, from most to least eager. Some decoders reject or mishandle the eager ones.
    private static final int TUNING_ALL = 0;        // standard low-latency flag + chip maker's own flag + real-time priority
    private static final int TUNING_STANDARD = 1;   // standard low-latency flag only (Android 11+)
    private static final int TUNING_PLAIN = 2;

    /** The settings that worked on this tablet; later decoders start there (remembered while the app runs). */
    private static volatile int learnedTuning = TUNING_ALL;

    private final Surface surface;
    private final Callback callback;
    private final Object lock = new Object();

    // Guarded by lock
    private MediaCodec codec;
    private Thread outputThread;
    private byte[] avcC;
    private AvcConfig config;
    private int width;
    private int height;
    private int tuning = learnedTuning;
    private boolean released;
    private boolean needKeyFrame = true;   // a fresh decoder must start from a key frame
    private long firstQueuedAt;
    private int restarts;
    private long lastRetry;

    private volatile MediaCodec active;            // the codec the output thread is serving
    private volatile boolean announceFrame = true;
    private volatile int queuedSinceStart;
    private volatile int shownSinceStart;

    VideoDecoder(Surface surface, Callback callback) {
        this.surface = surface;
        this.callback = callback;
    }

    /** Sets the decoder up for the Mac's stream format (the avcC record). Returns false if it couldn't. */
    boolean configure(byte[] newAvcC, int newWidth, int newHeight) {
        synchronized (lock) {
            if (released) return false;
            if (codec != null && Arrays.equals(newAvcC, avcC) && newWidth == width && newHeight == height) return true;
            AvcConfig parsed;
            try {
                parsed = AvcConfig.parse(newAvcC);
            } catch (IllegalArgumentException e) {
                callback.onReport("unusable stream format: " + e.getMessage());
                return false;
            }
            boolean newFormat = !Arrays.equals(newAvcC, avcC);
            stopCodec();
            avcC = newAvcC;
            config = parsed;
            width = newWidth;
            height = newHeight;
            tuning = learnedTuning;
            restarts = 0;
            if (newFormat && parsed.note != null) callback.onReport(parsed.note);
            return startCodec();
        }
    }

    /** Bytes in front of each piece of a frame, or 0 while no decoder is running. */
    int nalLengthSize() {
        synchronized (lock) {
            return codec != null && config != null ? config.nalLengthSize : 0;
        }
    }

    boolean isRunning() {
        synchronized (lock) {
            return codec != null;
        }
    }

    /** Reports the next picture shown (used after reconnecting). */
    void announceNextFrame() {
        announceFrame = true;
    }

    /**
     * Hands one frame (start-code form) to the decoder. Returns false if that didn't work or the decoder needs a key
     * frame first; the caller then asks the Mac for one.
     */
    boolean decode(byte[] data, int offset, int length, boolean keyFrame) {
        long giveUp = System.nanoTime() + 500000000L;
        while (true) {
            synchronized (lock) {
                MediaCodec current = codec;
                if (current == null) return false;
                if (needKeyFrame && !keyFrame) return false;
                if (queuedSinceStart > 45 && shownSinceStart == 0 && tuning < TUNING_PLAIN) {
                    usePlainerSettings("after 45 frames");
                    return false;
                }
                try {
                    int index = current.dequeueInputBuffer(5000);
                    if (index >= 0) {
                        ByteBuffer input = current.getInputBuffer(index);
                        if (input == null || input.capacity() < length) {
                            current.queueInputBuffer(index, 0, 0, 0, 0);
                            callback.onReport("a frame was too big for the decoder (" + length + " bytes)");
                            needKeyFrame = true;
                            return false;
                        }
                        input.clear();
                        input.put(data, offset, length);
                        // The time stamp is "now" on this tablet, so the output side can tell how long decoding took.
                        current.queueInputBuffer(index, 0, length, System.nanoTime() / 1000,
                                keyFrame ? MediaCodec.BUFFER_FLAG_KEY_FRAME : 0);
                        if (queuedSinceStart == 0) firstQueuedAt = System.nanoTime();
                        queuedSinceStart++;
                        if (keyFrame) needKeyFrame = false;
                        return true;
                    }
                } catch (IllegalStateException e) {   // includes MediaCodec.CodecException
                    restart("decoder error (" + e + ")");
                    return false;
                }
            }
            if (System.nanoTime() > giveUp) {
                synchronized (lock) {
                    if (codec != null) restart("decoder stopped taking frames");
                }
                return false;
            }
        }
    }

    /**
     * Called every couple of seconds while connected: starts the decoder again if it isn't running, and switches to
     * plainer settings if it takes frames but never shows any. Returns true when it started a decoder (which then
     * needs a key frame).
     */
    boolean maintain() {
        synchronized (lock) {
            if (released || config == null) return false;
            long now = System.nanoTime();
            if (codec == null) {
                if (now - lastRetry < 2000000000L) return false;
                lastRetry = now;
                return restart("decoder not running");
            }
            if (shownSinceStart == 0 && queuedSinceStart > 0 && now - firstQueuedAt > 1500000000L && tuning < TUNING_PLAIN) {
                return usePlainerSettings("for 1.5 seconds");
            }
            return false;
        }
    }

    void release() {
        synchronized (lock) {
            released = true;
            stopCodec();
        }
    }

    // Called with lock held. Returns true if a decoder runs afterwards.
    private boolean usePlainerSettings(String when) {
        callback.onReport("decoder showed nothing " + when + " with " + describe(tuning) + ", trying plainer settings");
        tuning++;
        learnedTuning = Math.max(learnedTuning, tuning);
        return restart("switching settings");
    }

    // Called with lock held. Returns true if a decoder runs afterwards.
    private boolean restart(String why) {
        stopCodec();
        if (restarts >= MAX_RESTARTS) {
            if (restarts == MAX_RESTARTS) {
                restarts++;
                callback.onReport(why + "; the decoder keeps failing, giving up until the next connection");
                callback.onDecoderFailed();
            }
            return false;
        }
        restarts++;
        callback.onReport(why + ", restarting the decoder");
        return startCodec();
    }

    // Called with lock held.
    private boolean startCodec() {
        List<String> names = decoderNames(width, height);
        for (int n = 0; n < names.size() && n < 3; n++) {
            for (int level = tuning; level <= TUNING_PLAIN; level++) {
                MediaCodec candidate = null;
                try {
                    candidate = MediaCodec.createByCodecName(names.get(n));
                    candidate.configure(format(names.get(n), level), surface, null, 0);
                    candidate.start();
                    codec = candidate;
                    tuning = level;
                    needKeyFrame = true;
                    queuedSinceStart = 0;
                    shownSinceStart = 0;
                    firstQueuedAt = 0;
                    announceFrame = true;
                    startOutputThread(candidate);
                    callback.onReport("decoder " + names.get(n) + " with " + describe(level) + ", " + width + "x" + height);
                    return true;
                } catch (Exception e) {
                    Log.w(TAG, "Decoder " + names.get(n) + " (" + describe(level) + ") failed", e);
                    if (candidate != null) {
                        try {
                            candidate.release();
                        } catch (Exception ignored) {
                            // nothing more to do
                        }
                    }
                }
            }
        }
        callback.onReport("no video decoder could start (" + names + ")");
        callback.onDecoderFailed();
        return false;
    }

    // Called with lock held.
    private void stopCodec() {
        MediaCodec current = codec;
        Thread thread = outputThread;
        codec = null;
        outputThread = null;
        active = null;
        if (current == null) return;
        try {
            current.stop();
        } catch (Exception ignored) {
            // already broken
        }
        if (thread != null) {
            try {
                thread.join(500);
            } catch (InterruptedException ignored) {
                Thread.currentThread().interrupt();
            }
        }
        try {
            current.release();
        } catch (Exception ignored) {
            // already released
        }
    }

    private MediaFormat format(String name, int level) {
        MediaFormat format = MediaFormat.createVideoFormat(MIME, width, height);
        format.setByteBuffer("csd-0", ByteBuffer.wrap(config.sps));
        format.setByteBuffer("csd-1", ByteBuffer.wrap(config.pps));
        format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, Math.max(2 * 1024 * 1024, width * height));
        if (level <= TUNING_STANDARD) {
            format.setInteger("low-latency", 1);   // MediaFormat.KEY_LOW_LATENCY (Android 11+)
        }
        if (level == TUNING_ALL) {
            format.setInteger(MediaFormat.KEY_PRIORITY, 0);   // real time
            String lower = name.toLowerCase(Locale.ROOT);
            if (lower.startsWith("c2.exynos") || lower.startsWith("omx.exynos")) {
                format.setInteger("vendor.rtc-ext-dec-low-latency.enable", 1);   // Samsung Exynos (Galaxy Tab S10 FE)
            } else if (lower.startsWith("c2.qti") || lower.startsWith("omx.qcom")) {
                format.setInteger("vendor.qti-ext-dec-picture-order.enable", 1);
                format.setInteger("vendor.qti-ext-dec-low-latency.enable", 1);
            } else if (lower.startsWith("c2.mtk") || lower.startsWith("omx.mtk")) {
                format.setInteger("vdec-lowlatency", 1);
            } else if (lower.startsWith("c2.amlogic")) {
                format.setInteger("vendor.low-latency.enable", 1);
            }
        }
        return format;
    }

    private static String describe(int level) {
        switch (level) {
            case TUNING_ALL: return "full low-latency settings";
            case TUNING_STANDARD: return "standard low-latency setting";
            default: return "plain settings";
        }
    }

    private void startOutputThread(final MediaCodec current) {
        active = current;
        Thread thread = new Thread(new Runnable() {
            @Override
            public void run() {
                drain(current);
            }
        }, "TabScreen decoder");
        outputThread = thread;
        thread.start();
    }

    /** Takes decoded frames and puts each one on screen right away. */
    private void drain(MediaCodec current) {
        StreamClient.setPriority(Process.THREAD_PRIORITY_URGENT_DISPLAY);
        MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
        long statsStart = System.nanoTime();
        long nextReport = statsStart + 5000000000L;   // first report after 5 seconds, then every minute
        int frames = 0;
        long decodeTotal = 0;
        long decodeMax = 0;
        while (active == current) {
            int index;
            try {
                index = current.dequeueOutputBuffer(info, 100000);
            } catch (IllegalStateException e) {
                break;
            }
            if (index < 0) continue;   // nothing yet, or a format notice
            long now = System.nanoTime();
            try {
                // "Show at the next screen refresh"; if a newer frame arrives before then, the newer one wins.
                current.releaseOutputBuffer(index, now);
            } catch (IllegalStateException e) {
                break;
            }
            shownSinceStart++;
            if (announceFrame) {
                announceFrame = false;
                callback.onFirstFrame();
            }
            long decodeMicros = Math.max(0, now / 1000 - info.presentationTimeUs);
            frames++;
            decodeTotal += decodeMicros;
            decodeMax = Math.max(decodeMax, decodeMicros);
            if (now >= nextReport) {
                callback.onReport(String.format(Locale.ROOT, "%d frames shown in %.0f s, decoding took %.1f ms on average (at most %.1f ms)",
                        frames, (now - statsStart) / 1e9, decodeTotal / 1000.0 / frames, decodeMax / 1000.0));
                statsStart = now;
                nextReport = now + 60000000000L;
                frames = 0;
                decodeTotal = 0;
                decodeMax = 0;
            }
        }
    }

    /**
     * The largest video with the screen's shape (and the highest frame rate up to {@code fps}) that this device's
     * hardware H.264 decoder says it can play: {width, height, fps}. Null if it can't tell.
     */
    static int[] largestVideo(int width, int height, int fps) {
        MediaCodecInfo.VideoCapabilities best = null;
        try {
            for (MediaCodecInfo info : new MediaCodecList(MediaCodecList.REGULAR_CODECS).getCodecInfos()) {
                if (info.isEncoder() || !handlesAvc(info) || isSoftwareOnly(info)) continue;
                if (info.getName().toLowerCase(Locale.ROOT).contains(".secure")) continue;
                MediaCodecInfo.CodecCapabilities capabilities = info.getCapabilitiesForType(MIME);
                if (capabilities.isFeatureRequired(MediaCodecInfo.CodecCapabilities.FEATURE_SecurePlayback)
                        || capabilities.isFeatureRequired(MediaCodecInfo.CodecCapabilities.FEATURE_TunneledPlayback)) continue;
                MediaCodecInfo.VideoCapabilities video = capabilities.getVideoCapabilities();
                if (video == null) continue;
                if (best == null || capabilities.isFeatureSupported("low-latency")) best = video;   // same choice as decoderNames
                if (capabilities.isFeatureSupported("low-latency")) break;
            }
        } catch (RuntimeException e) {
            return null;
        }
        if (best == null) return null;
        int[] rates = {fps, 60, 30};
        double[] scales = {1.0, 0.9, 0.8, 0.75, 2 / 3.0, 0.5};
        for (int rate : rates) {
            if (rate > fps && rate != rates[0]) continue;
            for (double scale : scales) {
                int w = ((int) Math.round(width * scale)) & ~1;
                int h = ((int) Math.round(height * scale)) & ~1;
                try {
                    if (best.areSizeAndRateSupported(w, h, rate)) return new int[]{w, h, rate};
                } catch (IllegalArgumentException ignored) {
                    // not a size this decoder accepts at all
                }
            }
        }
        return null;
    }

    /** H.264 decoders that can handle the picture size: hardware ones with a low-latency mode first. */
    private static List<String> decoderNames(int width, int height) {
        List<String> lowLatency = new ArrayList<String>();
        List<String> hardware = new ArrayList<String>();
        List<String> software = new ArrayList<String>();
        try {
            for (MediaCodecInfo info : new MediaCodecList(MediaCodecList.REGULAR_CODECS).getCodecInfos()) {
                if (info.isEncoder() || !handlesAvc(info)) continue;
                String name = info.getName();
                if (name.toLowerCase(Locale.ROOT).contains(".secure")) continue;
                MediaCodecInfo.CodecCapabilities capabilities = info.getCapabilitiesForType(MIME);
                if (capabilities.isFeatureRequired(MediaCodecInfo.CodecCapabilities.FEATURE_SecurePlayback)
                        || capabilities.isFeatureRequired(MediaCodecInfo.CodecCapabilities.FEATURE_TunneledPlayback)) continue;
                MediaCodecInfo.VideoCapabilities video = capabilities.getVideoCapabilities();
                if (video != null && !video.isSizeSupported(width, height)) continue;
                if (isSoftwareOnly(info)) {
                    software.add(name);
                } else if (capabilities.isFeatureSupported("low-latency")) {
                    lowLatency.add(name);
                } else {
                    hardware.add(name);
                }
            }
        } catch (RuntimeException e) {
            Log.w(TAG, "Couldn't list decoders", e);
        }
        List<String> names = new ArrayList<String>(lowLatency);
        names.addAll(hardware);
        names.addAll(software);
        if (names.isEmpty()) {
            try {
                String fallback = new MediaCodecList(MediaCodecList.REGULAR_CODECS)
                        .findDecoderForFormat(MediaFormat.createVideoFormat(MIME, width, height));
                if (fallback != null) names.add(fallback);
            } catch (RuntimeException e) {
                Log.w(TAG, "No decoder for the stream", e);
            }
        }
        return names;
    }

    private static boolean handlesAvc(MediaCodecInfo info) {
        for (String type : info.getSupportedTypes()) {
            if (type.equalsIgnoreCase(MIME)) return true;
        }
        return false;
    }

    private static boolean isSoftwareOnly(MediaCodecInfo info) {
        if (Build.VERSION.SDK_INT >= 29) {
            try {
                return (Boolean) MediaCodecInfo.class.getMethod("isSoftwareOnly").invoke(info);
            } catch (Exception ignored) {
                // fall back to the name
            }
        }
        String name = info.getName().toLowerCase(Locale.ROOT);
        return name.startsWith("omx.google.") || name.startsWith("c2.android.") || name.contains(".sw.");
    }
}
