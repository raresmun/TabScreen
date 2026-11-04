package local.tabscreen.viewer;

import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Process;
import android.util.Base64;
import android.util.Log;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.IOException;
import java.io.UnsupportedEncodingException;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.net.URLEncoder;
import java.nio.charset.Charset;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;

/**
 * Finds the Mac and keeps the picture coming. It tries the USB cable first (adb makes TabScreen on the Mac reachable
 * at this tablet's own localhost), then Wi-Fi if the Mac's address and key are known. Runs on its own thread.
 */
final class StreamClient implements Runnable {
    static final int PORT = 7171;

    static final int PROBLEM_WRONG_KEY = 1;
    static final int PROBLEM_BLOCKED = 2;
    static final int PROBLEM_REPLACED = 3;

    /** Called on the network thread; implementations hand things over to the UI thread. */
    interface Listener {
        /** No Mac found after a couple of tries. */
        void onSearching();

        void onConnected(boolean overUsb);

        /** A working connection ended; trying again right away. */
        void onDisconnected();

        void onProblem(int problem);

        void onVideoSize(int width, int height);

        /** x and y go from 0 to 1 across the extra display; displayWidth is its width in Mac points. */
        void onCursor(boolean visible, float x, float y, float displayWidth);

        /** The pointer's look; sizes and hot spot in Mac points. */
        void onCursorImage(Bitmap image, float hotX, float hotY, float width, float height);

        /**
         * Whether touches control the Mac: "on"; "off" (Touch control is off in TabScreen's menu); "permission"
         * (macOS hasn't allowed it under Accessibility yet); "nokey" (this connection didn't bring the access key).
         */
        void onInputState(String state);
    }

    private static final String TAG = "TabScreen";
    private static final Charset UTF8 = Charset.forName("UTF-8");

    // How one connection attempt went
    private static final int UNAVAILABLE = 0;
    private static final int STREAMED = 1;
    private static final int WRONG_KEY = 2;
    private static final int BLOCKED = 3;
    private static final int STOPPED = 4;

    private final Listener listener;
    private final VideoDecoder decoder;
    private final String wifiHost;
    private final String wifiKey;
    private final String userAgent;
    private final JSONObject screen;   // this tablet's screen, sent to the Mac in "hello" (see MainActivity.screenInfo)

    private volatile boolean running = true;
    private volatile Socket connecting;
    private volatile WebSocket socket;
    private volatile boolean waitingForKeyFrame = true;
    private long lastKeyFrameRequest;
    private boolean replaced;
    private Thread thread;
    // Touches go out from here: Android doesn't allow network use on the UI thread, where they come in.
    private final ExecutorService sender = Executors.newSingleThreadExecutor();

    StreamClient(Listener listener, VideoDecoder decoder, String wifiHost, String wifiKey, String userAgent,
                 JSONObject screen) {
        this.listener = listener;
        this.decoder = decoder;
        this.wifiHost = wifiHost;
        this.wifiKey = wifiKey;
        this.userAgent = userAgent;
        this.screen = screen;
    }

    void start() {
        thread = new Thread(this, "TabScreen network");
        thread.start();
    }

    /** Stops trying and ends the connection. Doesn't wait; see {@link #join}. */
    void stop() {
        running = false;
        Socket pending = connecting;
        if (pending != null) closeQuietly(pending);
        WebSocket current = socket;
        if (current != null) current.close();
        if (thread != null) thread.interrupt();
        sender.shutdownNow();
    }

    /** Sends a touch (a mouse action, see {@link TouchGestures}) to the Mac. Called on the UI thread. */
    void sendInput(final String json) {
        final WebSocket current = socket;
        if (current == null) return;
        try {
            sender.execute(new Runnable() {
                @Override
                public void run() {
                    try {
                        current.sendText(json);
                    } catch (IOException ignored) {
                        // the connection is going away; the network thread notices
                    }
                }
            });
        } catch (RejectedExecutionException ignored) {
            // stopped
        }
    }

    /** Writes a line into TabScreen.log on the Mac (handy for finding out how things run on the tablet). */
    void sendLog(String text) {
        WebSocket current = socket;
        if (current == null) return;
        try {
            JSONObject message = new JSONObject();
            message.put("type", "log");
            message.put("text", text);
            current.sendText(message.toString());
        } catch (Exception ignored) {
            // the connection is going away; nothing to report to
        }
    }

    @Override
    public void run() {
        setPriority(Process.THREAD_PRIORITY_URGENT_DISPLAY);
        boolean wifiUsable = wifiHost != null && wifiKey != null;
        int misses = 0;
        while (running) {
            // The key goes over USB too: the Mac only takes touches from a viewer that knows it, so other apps on this
            // tablet can't use the cable's tunnel to click on the Mac.
            int result = session("127.0.0.1", wifiKey, true);
            if (result == UNAVAILABLE && running && wifiUsable) {
                result = session(wifiHost, wifiKey, false);
                if (result == WRONG_KEY || result == BLOCKED) {
                    // Don't keep trying a key the Mac refuses: it blocks the tablet after 5 wrong ones.
                    wifiUsable = false;
                    listener.onProblem(result == WRONG_KEY ? PROBLEM_WRONG_KEY : PROBLEM_BLOCKED);
                }
            }
            if (!running || result == STOPPED) break;
            if (result == STREAMED) {
                misses = 0;
                listener.onDisconnected();
                continue;   // it worked a moment ago: try again right away
            }
            misses++;
            if (misses == 2) listener.onSearching();
            pause(misses < 6 ? 500 : 1000);
        }
        if (replaced) {
            decoder.release();   // hand the hardware decoder to whatever shows the screen now
            listener.onProblem(PROBLEM_REPLACED);
        }
    }

    private int session(String host, String key, boolean usb) {
        Socket raw = new Socket();
        WebSocket webSocket;
        connecting = raw;
        try {
            if (!running) {
                closeQuietly(raw);
                return STOPPED;
            }
            raw.setTcpNoDelay(true);
            raw.setReceiveBufferSize(1 << 20);
            raw.connect(new InetSocketAddress(host, PORT), usb ? 1000 : 2500);
            String path = key == null ? "/ws" : "/ws?k=" + urlEncode(key);
            webSocket = WebSocket.open(raw, host + ":" + PORT, path, userAgent);
        } catch (WebSocket.RefusedException e) {
            closeQuietly(raw);
            if (e.status == 403) return WRONG_KEY;
            if (e.status == 429) return BLOCKED;
            return UNAVAILABLE;
        } catch (IOException e) {
            closeQuietly(raw);
            return running ? UNAVAILABLE : STOPPED;
        } finally {
            connecting = null;
        }

        socket = webSocket;
        replaced = false;
        waitingForKeyFrame = true;
        decoder.announceNextFrame();
        boolean answered = false;   // the Mac sent something back: a working connection, not one that closes at once
        Thread keepAlive = startKeepAlive(webSocket);
        try {
            webSocket.sendText(hello().toString());
            while (running) {
                int type = webSocket.readMessage();
                if (type == WebSocket.CLOSE) break;
                if (!answered) {
                    answered = true;
                    listener.onConnected(usb);
                    Log.i(TAG, "Connected to the Mac over " + (usb ? "USB" : "Wi-Fi"));
                }
                if (type == WebSocket.TEXT) {
                    handleText(webSocket, new String(webSocket.data(), 0, webSocket.length(), UTF8));
                } else {
                    handleVideo(webSocket, webSocket.data(), webSocket.length());
                }
            }
        } catch (IOException e) {
            Log.i(TAG, "Connection ended: " + e.getMessage());
        } finally {
            socket = null;
            webSocket.close();
            keepAlive.interrupt();
        }
        if (replaced) {
            running = false;
            return STOPPED;
        }
        if (!running) return STOPPED;
        return answered ? STREAMED : UNAVAILABLE;
    }

    /** Introduces this tablet: the Mac shapes the extra display and the video to fit its screen. */
    private JSONObject hello() {
        JSONObject hello = new JSONObject();
        try {
            java.util.Iterator<String> keys = screen.keys();
            while (keys.hasNext()) {
                String key = keys.next();
                hello.put(key, screen.get(key));
            }
            hello.put("type", "hello");
            hello.put("mode", "h264");
            hello.put("client", "app");
            hello.put("ua", userAgent);
            hello.put("secure", true);
        } catch (JSONException ignored) {
            // only plain values go in
        }
        return hello;
    }

    private void handleText(WebSocket webSocket, String text) throws IOException {
        JSONObject message;
        try {
            message = new JSONObject(text);
        } catch (JSONException e) {
            return;
        }
        String type = message.optString("type");
        if ("cursor".equals(type)) {
            listener.onCursor(message.optInt("v") == 1, (float) message.optDouble("x", 0), (float) message.optDouble("y", 0),
                    (float) message.optDouble("dw", 0));
        } else if ("config".equals(type)) {
            byte[] avcC = decodeBase64(message.optString("description"));
            int width = message.optInt("width");
            int height = message.optInt("height");
            if (avcC != null && width > 0 && height > 0 && decoder.configure(avcC, width, height)) {
                listener.onVideoSize(width, height);
            }
            waitingForKeyFrame = true;   // the Mac follows a new format with a key frame
        } else if ("cursorImage".equals(type)) {
            byte[] png = decodeBase64(message.optString("png"));
            Bitmap image = png == null ? null : BitmapFactory.decodeByteArray(png, 0, png.length);
            if (image != null) {
                listener.onCursorImage(image, (float) message.optDouble("hx", 0), (float) message.optDouble("hy", 0),
                        (float) message.optDouble("w", 17), (float) message.optDouble("h", 25));
            }
        } else if ("replaced".equals(type)) {
            replaced = true;   // another TabScreen window on this tablet took over; the Mac closes this connection
        } else if ("input".equals(type)) {
            listener.onInputState(message.optString("touch", ""));
        }
    }

    /** A video frame: [flags][8-byte time][H.264 with 4-byte lengths]. */
    private void handleVideo(WebSocket webSocket, byte[] data, int length) throws IOException {
        if (length < 10) return;
        int flags = data[0] & 0xFF;
        if ((flags & 0xF0) != 0) return;   // a picture for the browser's picture mode; this app asked for video
        boolean keyFrame = (flags & 0x01) != 0;
        int lengthSize = decoder.nalLengthSize();
        if (lengthSize == 0) {
            // No decoder running (no format yet, or it failed). The keep-alive restarts it and then asks for a key frame.
            waitingForKeyFrame = true;
            return;
        }
        if (waitingForKeyFrame && !keyFrame) {
            askForKeyFrame(webSocket);
            return;
        }
        int offset = 9;
        int size = length - 9;
        boolean decoded;
        if (lengthSize == 4) {
            decoded = AvcConfig.convertInPlace(data, offset, size) && decoder.decode(data, offset, size, keyFrame);
        } else {
            byte[] frame = AvcConfig.convertCopy(data, offset, size, lengthSize);
            decoded = frame != null && decoder.decode(frame, 0, frame.length, keyFrame);
        }
        if (decoded) {
            waitingForKeyFrame = false;
        } else {
            waitingForKeyFrame = true;
            askForKeyFrame(webSocket);
        }
    }

    /** Asks the Mac for a picture that doesn't depend on earlier ones (at most once a second). */
    private synchronized void askForKeyFrame(WebSocket webSocket) throws IOException {
        long now = System.nanoTime();
        if (now - lastKeyFrameRequest < 1000000000L) return;
        lastKeyFrameRequest = now;
        webSocket.sendText("{\"type\":\"key\"}");
    }

    /** Pings the Mac every 2 seconds and drops the connection if it stops answering. */
    private Thread startKeepAlive(final WebSocket webSocket) {
        Thread keepAlive = new Thread(new Runnable() {
            @Override
            public void run() {
                while (running && socket == webSocket) {
                    try {
                        Thread.sleep(2000);
                    } catch (InterruptedException e) {
                        return;
                    }
                    if (socket != webSocket) return;
                    if (webSocket.millisSinceLastMessage() > 7000) {
                        Log.i(TAG, "The Mac stopped answering");
                        webSocket.close();
                        return;
                    }
                    try {
                        webSocket.sendPing();
                        if (decoder.maintain()) waitingForKeyFrame = true;   // a (re)started decoder needs a key frame
                        if (waitingForKeyFrame && decoder.isRunning()) askForKeyFrame(webSocket);
                    } catch (IOException e) {
                        webSocket.close();
                        return;
                    }
                }
            }
        }, "TabScreen keep-alive");
        keepAlive.setDaemon(true);
        keepAlive.start();
        return keepAlive;
    }

    private void pause(long millis) {
        try {
            Thread.sleep(millis);
        } catch (InterruptedException ignored) {
            // stop() interrupts; the loop checks running
        }
    }

    private static byte[] decodeBase64(String text) {
        if (text == null || text.isEmpty()) return null;
        try {
            return Base64.decode(text, Base64.DEFAULT);
        } catch (IllegalArgumentException e) {
            return null;
        }
    }

    private static String urlEncode(String text) {
        try {
            return URLEncoder.encode(text, "UTF-8");
        } catch (UnsupportedEncodingException e) {
            return text;
        }
    }

    private static void closeQuietly(Socket socket) {
        try {
            socket.close();
        } catch (IOException ignored) {
            // already closed
        }
    }

    static void setPriority(int priority) {
        try {
            Process.setThreadPriority(priority);
        } catch (Throwable e) {
            try {
                Process.setThreadPriority(Process.THREAD_PRIORITY_DISPLAY);
            } catch (Throwable ignored) {
                // keep the default priority
            }
        }
    }
}
