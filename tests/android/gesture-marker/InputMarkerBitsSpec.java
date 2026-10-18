package com.xopmc.galaxybridge.qa.gestureresponse;

public final class InputMarkerBitsSpec {
    private static String hex(byte[] bytes) {
        StringBuilder result = new StringBuilder();
        for (byte value : bytes) result.append(String.format("%02x", value & 255));
        return result.toString();
    }
    public static void main(String[] args) {
        for (int counter = 1; counter <= 256; ++counter) {
            if (InputMarkerBits.pressureCounter((0x8000 + counter) / 65535f) != counter)
                throw new AssertionError("actual 16-bit wire pressure did not retain its source ordinal");
        }
        for (float pressure : new float[] {0, 1, -1, Float.NaN, Float.POSITIVE_INFINITY, 0x8000 / 65535f, 0x8101 / 65535f}) {
            if (InputMarkerBits.pressureCounter(pressure) != -1) throw new AssertionError("unowned pressure accepted");
        }
        int[] counters = {0, 1, 2, 7, 65535};
        String[] golden = {"47424d31102030400000744b", "47424d31102030400001646a", "47424d311020304000025409", "47424d3110203040000704ac", "47424d3110203040ffff6944"};
        for (int index = 0; index < counters.length; index++) {
            if (!hex(InputMarkerBits.encode(0x10203040L, counters[index])).equals(golden[index])) throw new AssertionError("independent GBM1 golden mismatch");
        }
        for (long nonce : new long[] {0, -1, 0x100000000L}) {
            try { InputMarkerBits.encode(nonce, 0); throw new AssertionError("invalid nonce accepted"); }
            catch (IllegalArgumentException expected) {}
        }
        for (int counter : new int[] {-1, 65536}) {
            try { InputMarkerBits.encode(1, counter); throw new AssertionError("invalid counter accepted"); }
            catch (IllegalArgumentException expected) {}
        }
        System.out.println("PASS Java fixture marker: independent shared golden bytes and bounds");
    }
}
