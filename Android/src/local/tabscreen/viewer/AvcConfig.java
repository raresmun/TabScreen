package local.tabscreen.viewer;

import java.io.ByteArrayOutputStream;

/**
 * The H.264 setup record ("avcC") the Mac sends before the video, turned into what Android's decoder reads:
 * the sequence and picture parameter sets, each behind a 00 00 00 01 start code. The sequence parameter set also
 * gets the "never hold frames back" hint (see {@link SpsRewriter}).
 *
 * The Mac's encoder puts a length in front of every piece (NAL unit) of a frame; Android's decoder wants
 * start codes instead. {@link #convertInPlace} and {@link #convertCopy} do that swap.
 */
final class AvcConfig {
    /** csd-0: sequence parameter sets. */
    final byte[] sps;
    /** csd-1: picture parameter sets. */
    final byte[] pps;
    /** How many bytes the length in front of each NAL unit takes (4 from Apple's encoder). */
    final int nalLengthSize;
    /** What happened to the sequence parameter set, for the Mac's log. */
    final String note;

    private AvcConfig(byte[] sps, byte[] pps, int nalLengthSize, String note) {
        this.sps = sps;
        this.pps = pps;
        this.nalLengthSize = nalLengthSize;
        this.note = note;
    }

    static AvcConfig parse(byte[] avcC) {
        if (avcC == null || avcC.length < 7 || (avcC[0] & 0xFF) != 1) {
            throw new IllegalArgumentException("not an avcC record");
        }
        int lengthSize = (avcC[4] & 0x03) + 1;
        if (lengthSize == 3) throw new IllegalArgumentException("unsupported NAL length size 3");
        int position = 5;
        int spsCount = avcC[position++] & 0x1F;
        ByteArrayOutputStream sps = new ByteArrayOutputStream();
        String note = null;
        for (int i = 0; i < spsCount; i++) {
            byte[] unit = readParameterSet(avcC, position);
            position += 2 + unit.length;
            byte[] hinted = null;
            String result;
            try {
                hinted = SpsRewriter.addLowDelayHint(unit);
                result = hinted == null ? "already says frames are never held back" : "now says frames are never held back";
            } catch (IllegalArgumentException e) {
                result = "left as it was (" + e.getMessage() + ")";
            }
            if (note == null) note = "stream format " + result + "; SPS " + hex(unit);
            writeWithStartCode(sps, hinted != null ? hinted : unit);
        }
        if (position >= avcC.length) throw new IllegalArgumentException("avcC record is cut short");
        int ppsCount = avcC[position++] & 0xFF;
        ByteArrayOutputStream pps = new ByteArrayOutputStream();
        for (int i = 0; i < ppsCount; i++) {
            byte[] unit = readParameterSet(avcC, position);
            position += 2 + unit.length;
            writeWithStartCode(pps, unit);
        }
        if (sps.size() == 0 || pps.size() == 0) throw new IllegalArgumentException("avcC record has no parameter sets");
        return new AvcConfig(sps.toByteArray(), pps.toByteArray(), lengthSize, note);
    }

    private static byte[] readParameterSet(byte[] avcC, int position) {
        if (position + 2 > avcC.length) throw new IllegalArgumentException("avcC record is cut short");
        int length = ((avcC[position] & 0xFF) << 8) | (avcC[position + 1] & 0xFF);
        position += 2;
        if (length == 0 || position + length > avcC.length) throw new IllegalArgumentException("avcC record is cut short");
        byte[] unit = new byte[length];
        System.arraycopy(avcC, position, unit, 0, length);
        return unit;
    }

    private static void writeWithStartCode(ByteArrayOutputStream out, byte[] unit) {
        out.write(0);
        out.write(0);
        out.write(0);
        out.write(1);
        out.write(unit, 0, unit.length);
    }

    private static String hex(byte[] data) {
        StringBuilder text = new StringBuilder(data.length * 2);
        for (int i = 0; i < data.length && i < 64; i++) text.append(String.format("%02x", data[i] & 0xFF));
        return text.toString();
    }

    /**
     * Swaps the 4-byte lengths in front of each NAL unit for start codes, in place.
     * Returns false (and may leave the frame half converted) if the frame is damaged.
     */
    static boolean convertInPlace(byte[] data, int offset, int length) {
        int position = offset;
        int end = offset + length;
        while (position < end) {
            if (position + 4 > end) return false;
            int unit = ((data[position] & 0xFF) << 24) | ((data[position + 1] & 0xFF) << 16)
                    | ((data[position + 2] & 0xFF) << 8) | (data[position + 3] & 0xFF);
            if (unit <= 0 || unit > end - position - 4) return false;
            data[position] = 0;
            data[position + 1] = 0;
            data[position + 2] = 0;
            data[position + 3] = 1;
            position += 4 + unit;
        }
        return position == end;
    }

    /** Same as {@link #convertInPlace} for any length size (1, 2 or 4 bytes); returns a new array, or null if damaged. */
    static byte[] convertCopy(byte[] data, int offset, int length, int lengthSize) {
        ByteArrayOutputStream out = new ByteArrayOutputStream(length + 64);
        int position = offset;
        int end = offset + length;
        while (position < end) {
            if (position + lengthSize > end) return null;
            int unit = 0;
            for (int i = 0; i < lengthSize; i++) unit = (unit << 8) | (data[position + i] & 0xFF);
            position += lengthSize;
            if (unit <= 0 || unit > end - position) return null;
            out.write(0);
            out.write(0);
            out.write(0);
            out.write(1);
            out.write(data, position, unit);
            position += unit;
        }
        return out.toByteArray();
    }
}
