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
        testBoundedRevalidation(); testDirtyGeneration();

        ClipboardOriginTracker origins = new ClipboardOriginTracker();
        if (origins.originFor("hub:unseen", 100, "com.example.notes") != null)
            throw new AssertionError("First-observed copy from another app must not inherit injection provenance");
        if (origins.originFor("hub:unknown", 100, null) != null)
            throw new AssertionError("Unavailable platform attribution must not suppress a user copy");
        if (!"hub:a".equals(origins.originFor("hub:a", 100, "com.android.shell"))) throw new AssertionError("Injection provenance lost");
        if (origins.originFor("hub:a", 101, "com.android.shell") != null) throw new AssertionError("History recopy must be a fresh occurrence");
        if (!"hub:image".equals(origins.originFor("hub:image", 102, "com.xopmc.galaxybridge")))
            throw new AssertionError("Helper image injection provenance lost");
        System.out.println("PASS clipboard cache: stable polling avoids redundant reads; bounded text/image revalidation, copy callbacks, load races, reset and retry fallbacks preserved");
    }
    static void testBoundedRevalidation() throws Exception {
        long[] time={0}; int[] reads={0}; String[] payload={"first"};
        ClipboardSnapshotCache<String> cache=new ClipboardSnapshotCache<>(()->time[0]);
        if(!"first".equals(cache.read(100,"text/plain",()->{reads[0]++;return payload[0];})))throw new AssertionError();
        // Same millisecond/metadata and missing listener: never retain stale text forever.
        payload[0]="second";time[0]=10000;
        if(!"second".equals(cache.read(100,"text/plain",()->{reads[0]++;return payload[0];})))
            throw new AssertionError("Same-ms text remained cached after bounded revalidation");
        if(reads[0]!=2)throw new AssertionError("Expected one real bounded refresh");
        // A provider can change bytes without changing its URI or clipboard timestamp.
        byte[][] image={{1}}; ClipboardSnapshotCache<byte[]> images=new ClipboardSnapshotCache<>(()->time[0]);
        images.read(101,"image/png",()->image[0]);image[0]=new byte[]{2};time[0]=20000;
        if(images.read(101,"image/png",()->image[0])[0]!=2)throw new AssertionError("Unchanged URI hid changed image bytes");
        time[0]=0; // A backwards clock cannot extend a cached lifetime indefinitely.
        payload[0]="after-clock-reset";
        if(!payload[0].equals(cache.read(100,"text/plain",()->payload[0])))throw new AssertionError("Clock regression retained stale payload");
    }
    static void testDirtyGeneration() throws Exception {
        long[] time={0};String[] payload={"first"};int[] reads={0};
        ClipboardSnapshotCache<String> cache=new ClipboardSnapshotCache<>(()->time[0]);
        cache.read(100,"text/plain",()->{reads[0]++;return payload[0];});
        cache.changed();payload[0]="same-ms-new-copy";
        if(!payload[0].equals(cache.read(100,"text/plain",()->{reads[0]++;return payload[0];})))
            throw new AssertionError("Listener invalidation did not reload a same-ms copy");
        cache.changed(); // Classification callback may repeat: reread but do not invent changed bytes.
        if(!payload[0].equals(cache.read(100,"text/plain",()->{reads[0]++;return payload[0];}))||reads[0]!=3)throw new AssertionError();
        cache.changed();
        if(cache.read(100,"text/plain",()->{cache.changed();return "stale-loaded";})!=null)
            throw new AssertionError("Payload changed during loading was published");
        if(!"current".equals(cache.read(100,"text/plain",()->"current")))throw new AssertionError("Concurrent copy failed to recover");
        cache.changed();
        cache.read(100,"text/plain",()->null);cache.changed();
        if(!"retry".equals(cache.read(100,"text/plain",()->"retry")))throw new AssertionError("New callback failed to bypass failure backoff");
    }

}
