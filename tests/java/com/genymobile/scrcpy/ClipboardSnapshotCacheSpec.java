package com.genymobile.scrcpy;

public final class ClipboardSnapshotCacheSpec {
    public static void main(String[] args) throws Exception {
        long[] clock = {0};
        ClipboardSnapshotCache<byte[]> cache = new ClipboardSnapshotCache<>(() -> clock[0]);
        int[] reads = {0};
        byte[] original = {1, 2, 3};
        for (int i = 0; i < 172; i++) {
            byte[] value = cache.read(100, "image:content://fixture/one", () -> {
                reads[0]++;
                return original;
            });
            if (value != original) throw new AssertionError("Image bytes changed during polling");
        }
        if (reads[0] != 1) throw new AssertionError("Unchanged image was read/encoded " + reads[0] + " times, expected once");
        cache.read(101, "image:content://fixture/one", () -> { reads[0]++; return original; });
        cache.read(101, "image:content://fixture/two", () -> { reads[0]++; return original; });
        if (reads[0] != 3) throw new AssertionError("New occurrence or URI must be re-read");
        cache.clear();
        cache.read(101, "image:content://fixture/two", () -> { reads[0]++; return original; });
        if (reads[0] != 4) throw new AssertionError("Clearing/sensitive clip must invalidate cached content");
        for (int i = 0; i < 3; i++) cache.read(0, "image:unknown-timestamp", () -> { reads[0]++; return original; });
        if (reads[0] != 7) throw new AssertionError("Unknown timestamps must be polled in full");
        for (int i = 0; i < 3; i++) cache.read(102, "image:unreadable", () -> { reads[0]++; return null; });
        if (reads[0] != 8) throw new AssertionError("Unchanged failed image must not retry every poll");
        clock[0] = 2000;
        cache.read(102, "image:unreadable", () -> { reads[0]++; return null; });
        if (reads[0] != 9) throw new AssertionError("Failed image must retry after bounded backoff");
        cache.read(103, "image:unreadable", () -> { reads[0]++; return null; });
        if (reads[0] != 10) throw new AssertionError("New copy must bypass failed-read backoff");
        ClipboardOriginTracker origins = new ClipboardOriginTracker();
        if (origins.originFor("hub:unseen", 100, "com.example.notes") != null)
            throw new AssertionError("First-observed copy from another app must not inherit injection provenance");
        if (origins.originFor("hub:unknown", 100, null) != null)
            throw new AssertionError("Unavailable platform attribution must not suppress a user copy");
        if (!"hub:a".equals(origins.originFor("hub:a", 100, "com.android.shell"))) throw new AssertionError("Injection provenance lost");
        if (origins.originFor("hub:a", 101, "com.android.shell") != null) throw new AssertionError("History recopy must be a fresh occurrence");
        if (!"hub:image".equals(origins.originFor("hub:image", 102, "com.xopmc.galaxybridge")))
            throw new AssertionError("Helper image injection provenance lost");
        System.out.println("PASS unchanged image: 172 polls, one read/encode/hash; new occurrence, URI, reset and retry fallbacks preserved");
    }
}
