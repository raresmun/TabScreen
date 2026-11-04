package local.tabscreen.viewer;

import java.io.ByteArrayOutputStream;

/**
 * Adds a "show every frame right away" hint to an H.264 sequence parameter set (SPS): a bitstream restriction saying
 * frames are never reordered (max_num_reorder_frames = 0) and the decoder only needs to keep the reference frames
 * (max_dec_frame_buffering = max_num_ref_frames). Without it, some decoders hold back as many frames as the H.264
 * level allows before showing the first one. Apple's encoder doesn't write this hint; WebRTC adds it the same way.
 *
 * Anything unexpected leaves the SPS untouched: the stream still plays, just without the hint.
 */
final class SpsRewriter {
    /** Where things are in an SPS (bit positions in the payload after the NAL header byte), and a few values. */
    static final class Layout {
        int maxNumRefFrames;
        int vuiFlagBit;
        boolean hasVui;
        int restrictionFlagBit = -1;
        boolean hasRestriction;
        int motionVectorsOverBoundaries = 1;
        long maxBytesPerPicDenom = 2;
        long maxBitsPerMbDenom = 1;
        long log2MaxMvLengthHorizontal = 15;
        long log2MaxMvLengthVertical = 15;
        long maxNumReorderFrames = -1;
        long maxDecFrameBuffering = -1;
    }

    private SpsRewriter() {
    }

    /**
     * Returns a rewritten SPS NAL unit, or null when it already carries the hint. Throws if the SPS can't be read
     * or isn't Baseline profile (only Baseline guarantees frames are never reordered; TabScreen's Mac encoder uses it).
     */
    static byte[] addLowDelayHint(byte[] nal) {
        return addLowDelayHint(nal, false);
    }

    static byte[] addLowDelayHint(byte[] nal, boolean anyProfile) {
        if (nal == null || nal.length < 4 || (nal[0] & 0x1F) != 7) throw new IllegalArgumentException("not an SPS");
        byte[] rbsp = unescape(nal, 1, nal.length - 1);
        if (!anyProfile && (rbsp[0] & 0xFF) != 66) {
            throw new IllegalArgumentException("not Baseline profile, frames may be reordered");
        }
        Layout layout = parse(rbsp);
        long buffering = Math.max(1, layout.maxNumRefFrames);
        if (layout.hasRestriction && layout.maxNumReorderFrames == 0 && layout.maxDecFrameBuffering <= buffering) {
            return null;
        }
        BitWriter out = new BitWriter();
        if (layout.hasVui) {
            out.copy(rbsp, 0, layout.restrictionFlagBit);
        } else {
            out.copy(rbsp, 0, layout.vuiFlagBit);
            out.bit(1);   // vui_parameters_present_flag
            // aspect ratio, overscan, video signal type, chroma location, timing, NAL HRD, VCL HRD, pic struct: all absent
            for (int i = 0; i < 8; i++) out.bit(0);
        }
        out.bit(1);   // bitstream_restriction_flag
        out.bit(layout.motionVectorsOverBoundaries);
        out.ue(layout.maxBytesPerPicDenom);
        out.ue(layout.maxBitsPerMbDenom);
        out.ue(layout.log2MaxMvLengthHorizontal);
        out.ue(layout.log2MaxMvLengthVertical);
        out.ue(0);           // max_num_reorder_frames
        out.ue(buffering);   // max_dec_frame_buffering
        return escape(nal[0], out.finishWithTrailingBits());
    }

    /** Reads an SPS payload (no NAL header, emulation prevention removed). */
    static Layout parse(byte[] rbsp) {
        BitReader in = new BitReader(rbsp);
        Layout layout = new Layout();
        int profile = in.bits(8);
        in.bits(8);   // constraint flags and reserved bits
        in.bits(8);   // level_idc
        in.ue();      // seq_parameter_set_id
        if (profile == 100 || profile == 110 || profile == 122 || profile == 244 || profile == 44 || profile == 83
                || profile == 86 || profile == 118 || profile == 128 || profile == 138 || profile == 139
                || profile == 134 || profile == 135) {
            long chromaFormat = in.ue();
            if (chromaFormat == 3) in.bit();   // separate_colour_plane_flag
            in.ue();   // bit_depth_luma_minus8
            in.ue();   // bit_depth_chroma_minus8
            in.bit();  // qpprime_y_zero_transform_bypass_flag
            if (in.bit() == 1) {   // seq_scaling_matrix_present_flag
                int lists = chromaFormat != 3 ? 8 : 12;
                for (int i = 0; i < lists; i++) {
                    if (in.bit() == 1) skipScalingList(in, i < 6 ? 16 : 64);
                }
            }
        }
        in.ue();   // log2_max_frame_num_minus4
        long pocType = in.ue();
        if (pocType == 0) {
            in.ue();   // log2_max_pic_order_cnt_lsb_minus4
        } else if (pocType == 1) {
            in.bit();  // delta_pic_order_always_zero_flag
            in.se();   // offset_for_non_ref_pic
            in.se();   // offset_for_top_to_bottom_field
            long cycle = in.ue();
            if (cycle > 255) throw new IllegalArgumentException("bad SPS");
            for (long i = 0; i < cycle; i++) in.se();
        } else if (pocType != 2) {
            throw new IllegalArgumentException("bad SPS");
        }
        long references = in.ue();
        if (references > 16) throw new IllegalArgumentException("bad SPS");
        layout.maxNumRefFrames = (int) references;
        in.bit();  // gaps_in_frame_num_value_allowed_flag
        in.ue();   // pic_width_in_mbs_minus1
        in.ue();   // pic_height_in_map_units_minus1
        if (in.bit() == 0) in.bit();   // frame_mbs_only_flag, mb_adaptive_frame_field_flag
        in.bit();  // direct_8x8_inference_flag
        if (in.bit() == 1) {   // frame_cropping_flag
            in.ue();
            in.ue();
            in.ue();
            in.ue();
        }
        layout.vuiFlagBit = in.position;
        layout.hasVui = in.bit() == 1;
        if (layout.hasVui) {
            if (in.bit() == 1) {   // aspect_ratio_info_present_flag
                if (in.bits(8) == 255) {   // extended SAR
                    in.bits(16);
                    in.bits(16);
                }
            }
            if (in.bit() == 1) in.bit();   // overscan
            if (in.bit() == 1) {   // video_signal_type_present_flag
                in.bits(3);
                in.bit();
                if (in.bit() == 1) {   // colour_description_present_flag
                    in.bits(8);
                    in.bits(8);
                    in.bits(8);
                }
            }
            if (in.bit() == 1) {   // chroma_loc_info_present_flag
                in.ue();
                in.ue();
            }
            if (in.bit() == 1) {   // timing_info_present_flag
                in.bits(16);
                in.bits(16);
                in.bits(16);
                in.bits(16);
                in.bit();
            }
            boolean nalHrd = in.bit() == 1;
            if (nalHrd) skipHrd(in);
            boolean vclHrd = in.bit() == 1;
            if (vclHrd) skipHrd(in);
            if (nalHrd || vclHrd) in.bit();   // low_delay_hrd_flag
            in.bit();   // pic_struct_present_flag
            layout.restrictionFlagBit = in.position;
            layout.hasRestriction = in.bit() == 1;
            if (layout.hasRestriction) {
                layout.motionVectorsOverBoundaries = in.bit();
                layout.maxBytesPerPicDenom = in.ue();
                layout.maxBitsPerMbDenom = in.ue();
                layout.log2MaxMvLengthHorizontal = in.ue();
                layout.log2MaxMvLengthVertical = in.ue();
                layout.maxNumReorderFrames = in.ue();
                layout.maxDecFrameBuffering = in.ue();
            }
        }
        // What follows must be the stop bit and zero padding; anything else means the SPS wasn't read right.
        if (in.bit() != 1) throw new IllegalArgumentException("unexpected SPS layout");
        while (in.position < rbsp.length * 8) {
            if (in.bit() != 0) throw new IllegalArgumentException("unexpected SPS layout");
        }
        return layout;
    }

    private static void skipScalingList(BitReader in, int size) {
        int last = 8;
        int next = 8;
        for (int j = 0; j < size; j++) {
            if (next != 0) next = (int) ((last + in.se() + 256) % 256);
            if (next != 0) last = next;
        }
    }

    private static void skipHrd(BitReader in) {
        long count = in.ue() + 1;
        if (count > 32) throw new IllegalArgumentException("bad SPS");
        in.bits(4);   // bit_rate_scale
        in.bits(4);   // cpb_size_scale
        for (long i = 0; i < count; i++) {
            in.ue();   // bit_rate_value_minus1
            in.ue();   // cpb_size_value_minus1
            in.bit();  // cbr_flag
        }
        in.bits(5);
        in.bits(5);
        in.bits(5);
        in.bits(5);
    }

    /** Removes emulation prevention bytes (00 00 03 → 00 00). */
    static byte[] unescape(byte[] data, int offset, int length) {
        ByteArrayOutputStream out = new ByteArrayOutputStream(length);
        int zeros = 0;
        for (int i = offset; i < offset + length; i++) {
            int value = data[i] & 0xFF;
            if (zeros >= 2 && value == 3) {
                zeros = 0;
                continue;
            }
            out.write(value);
            zeros = value == 0 ? zeros + 1 : 0;
        }
        return out.toByteArray();
    }

    /** Puts the NAL header back and adds emulation prevention bytes where needed. */
    static byte[] escape(byte header, byte[] rbsp) {
        ByteArrayOutputStream out = new ByteArrayOutputStream(rbsp.length + 8);
        out.write(header);
        int zeros = 0;
        for (byte b : rbsp) {
            int value = b & 0xFF;
            if (zeros >= 2 && value <= 3) {
                out.write(3);
                zeros = 0;
            }
            out.write(value);
            zeros = value == 0 ? zeros + 1 : 0;
        }
        return out.toByteArray();
    }

    static final class BitReader {
        private final byte[] data;
        int position;

        BitReader(byte[] data) {
            this.data = data;
        }

        int bit() {
            if (position >= data.length * 8) throw new IllegalArgumentException("SPS too short");
            int value = (data[position >> 3] >> (7 - (position & 7))) & 1;
            position++;
            return value;
        }

        int bits(int count) {   // up to 16 at a time
            int value = 0;
            for (int i = 0; i < count; i++) value = (value << 1) | bit();
            return value;
        }

        long ue() {
            int zeros = 0;
            while (bit() == 0) {
                zeros++;
                if (zeros > 31) throw new IllegalArgumentException("bad SPS");
            }
            long rest = 0;
            for (int i = 0; i < zeros; i++) rest = (rest << 1) | bit();
            return (1L << zeros) - 1 + rest;
        }

        long se() {
            long code = ue();
            return (code & 1) == 1 ? (code + 1) / 2 : -(code / 2);
        }
    }

    static final class BitWriter {
        private final ByteArrayOutputStream out = new ByteArrayOutputStream();
        private int current;
        private int count;

        void bit(int value) {
            current = (current << 1) | (value & 1);
            count++;
            if (count == 8) {
                out.write(current);
                current = 0;
                count = 0;
            }
        }

        void bits(long value, int length) {
            for (int i = length - 1; i >= 0; i--) bit((int) (value >>> i) & 1);
        }

        void ue(long value) {
            long code = value + 1;
            int length = 63 - Long.numberOfLeadingZeros(code);
            for (int i = 0; i < length; i++) bit(0);
            bits(code, length + 1);
        }

        /** Copies bits [from, to) of data. */
        void copy(byte[] data, int from, int to) {
            for (int position = from; position < to; position++) {
                bit((data[position >> 3] >> (7 - (position & 7))) & 1);
            }
        }

        byte[] finishWithTrailingBits() {
            bit(1);
            while (count != 0) bit(0);
            return out.toByteArray();
        }
    }
}
