package com.xopmc.galaxybridge.nearby;

import java.nio.charset.StandardCharsets;

/** Public generic model and optional host public-key digest. Never emits raw keys, phone identity or credentials. */
public final class NearbyDiscoveryMetadata {
    private NearbyDiscoveryMetadata() {}
    public static byte[] encode(String manufacturer, String model, byte[] pairedHostPublicKey) {
        byte[] generic = encode(manufacturer, model);
        if (pairedHostPublicKey == null || pairedHostPublicKey.length != 65 || pairedHostPublicKey[0] != 4) return generic;
        try {
            byte[] digest = java.security.MessageDigest.getInstance("SHA-256").digest(pairedHostPublicKey);
            StringBuilder hex = new StringBuilder(64);
            char[] digits = "0123456789abcdef".toCharArray();
            for (byte value : digest) { hex.append(digits[(value & 255) >>> 4]); hex.append(digits[value & 15]); }
            return ("GBD2" + new String(generic, StandardCharsets.US_ASCII).substring(4) + "\n" + hex)
                .getBytes(StandardCharsets.US_ASCII);
        } catch (java.security.NoSuchAlgorithmException unavailable) {
            return generic;
        }
    }
    public static byte[] encode(String manufacturer, String model) {
        String maker = sanitize(manufacturer), hardware = sanitize(model);
        String label = hardware.regionMatches(true, 0, maker, 0, maker.length())
            ? hardware : maker + " " + hardware;
        label = label.trim();
        if (label.isEmpty()) label = "Android";
        if (label.length() > 64) label = label.substring(0, 64).trim();
        return ("GBD1\n" + label).getBytes(StandardCharsets.US_ASCII);
    }
    private static String sanitize(String text) {
        if (text == null) return "";
        // Build fields can contain vendor anomalies; bound work before normalizing.
        return text.substring(0, Math.min(128, text.length()))
            .replaceAll("[^A-Za-z0-9 .()+_\\-]", " ").replaceAll(" +", " ").trim();
    }
}
