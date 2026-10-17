package com.xopmc.galaxybridge.qa.gestureresponse;

/** Synthetic GBM1 image marker; no phone identity or user content. */
final class InputMarkerBits {
    static byte[] encode(long nonce, int counter) {
        if (nonce <= 0 || nonce > 0xffffffffL || counter < 0 || counter > 65535) {
            throw new IllegalArgumentException("marker bounds");
        }
        byte[] data = new byte[] {0x47, 0x42, 0x4d, 0x31, 0, 0, 0, 0, 0, 0, 0, 0};
        for (int index = 0; index < 4; index++) data[4 + index] = (byte) (nonce >>> (24 - index * 8));
        data[8] = (byte) (counter >>> 8); data[9] = (byte) counter;
        int crc = 0xffff;
        for (int index = 0; index < 10; index++) {
            crc ^= (data[index] & 255) << 8;
            for (int bit = 0; bit < 8; bit++) crc = ((crc << 1) ^ ((crc & 0x8000) == 0 ? 0 : 0x1021)) & 65535;
        }
        data[10] = (byte) (crc >>> 8); data[11] = (byte) crc;
        return data;
    }
}
