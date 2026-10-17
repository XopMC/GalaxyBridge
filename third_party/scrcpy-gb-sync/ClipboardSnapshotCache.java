package com.genymobile.scrcpy;

import java.util.function.LongSupplier;
import java.util.concurrent.atomic.AtomicLong;

/** One bounded decoded clipboard value, owned by the polling thread. */
final class ClipboardSnapshotCache<T> {
    interface Loader<T> { T load() throws Exception; }
    private long timestamp;
    private String identity;
    private T value;
    private long retryAt, loadedAt;
    private static final long REVALIDATE_MILLIS = 5000;
    private final LongSupplier clock;
    private final AtomicLong changes = new AtomicLong();
    private long cachedGeneration;

    ClipboardSnapshotCache() { this(() -> System.nanoTime() / 1000000); }
    ClipboardSnapshotCache(LongSupplier clock) { this.clock = clock; }

    /** May run on the callback Looper; payload/cache fields remain polling-thread owned. */
    void changed() { changes.incrementAndGet(); }

    T read(long observedTimestamp, String observedIdentity, Loader<T> loader) throws Exception {
        long observedGeneration = changes.get();
        long now = clock.getAsLong();
        if (observedTimestamp > 0 && observedTimestamp == timestamp
                && observedIdentity.equals(identity) && cachedGeneration == observedGeneration) {
            if (value != null && now >= loadedAt && now - loadedAt < REVALIDATE_MILLIS) return value;
            if (value == null && now < retryAt) return null;
        }
        clear();
        if (observedTimestamp > 0) {
            timestamp = observedTimestamp;
            identity = observedIdentity; cachedGeneration = observedGeneration;
            retryAt = clock.getAsLong() + 2000;
        }
        T loaded = loader.load();
        if (observedGeneration != changes.get()) { clear(); return null; }
        if (observedTimestamp > 0 && loaded != null) {
            value = loaded; cachedGeneration = observedGeneration; loadedAt = clock.getAsLong();
        }
        return loaded;
    }

    void clear() { timestamp = 0; identity = null; value = null; retryAt = 0; loadedAt = 0; }
}
