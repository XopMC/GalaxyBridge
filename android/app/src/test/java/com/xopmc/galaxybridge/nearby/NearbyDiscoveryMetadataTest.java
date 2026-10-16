package com.xopmc.galaxybridge.nearby;

import java.nio.charset.StandardCharsets;
import org.junit.Test;
import static org.junit.Assert.*;

public class NearbyDiscoveryMetadataTest {
    @Test public void pairedHostHintContainsOnlyPublicKeyDigest() throws Exception {
        byte[] key = new byte[65]; key[0] = 4;
        byte[] wire = NearbyDiscoveryMetadata.encode("Samsung", "SM-S928B", key);
        String value = new String(wire, StandardCharsets.US_ASCII);
        assertTrue(value.startsWith("GBD2\nSamsung SM-S928B\n"));
        String hint = value.substring(value.lastIndexOf('\n') + 1);
        assertEquals(64, hint.length());
        assertTrue(hint.matches("[0-9a-f]{64}"));
        byte[] digest = java.security.MessageDigest.getInstance("SHA-256").digest(key);
        StringBuilder expected = new StringBuilder();
        for (byte part : digest) expected.append(String.format("%02x", part & 255));
        assertEquals(expected.toString(), hint);
        assertArrayEquals(NearbyDiscoveryMetadata.encode("Samsung", "SM-S928B"),
            NearbyDiscoveryMetadata.encode("Samsung", "SM-S928B", new byte[32]));
        assertTrue(NearbyDiscoveryMetadata.encode("Samsung", "A".repeat(1000), key).length <= 134);
    }
    @Test public void genericModelHasTheBoundedPublicWireFormat() {
        assertEquals("GBD1\nSamsung SM-S928B", text("Samsung", "SM-S928B"));
        assertEquals("GBD1\nSamsung Galaxy S24", text("Samsung", "Samsung Galaxy S24"));
        assertEquals("GBD1\nAndroid", text(null, null));
        assertEquals("GBD1\nSamsung Phone", text("Samsung", "\u202ePhone\n\u0000"));
        assertTrue(NearbyDiscoveryMetadata.encode("Samsung", "A".repeat(1_000)).length <= 69);
    }
    private String text(String manufacturer, String model) {
        return new String(NearbyDiscoveryMetadata.encode(manufacturer, model), StandardCharsets.US_ASCII);
    }
}
