package com.genymobile.scrcpy;

import java.util.function.LongSupplier;

/** One bounded decoded clipboard value, owned by the polling thread. */
final class ClipboardSnapshotCache<T> {
    interface Loader<T> { T load() throws Exception; }
    private long timestamp;
    private String identity;
    private T value;
    private long retryAt;
    private final LongSupplier clock;

    ClipboardSnapshotCache() { this(() -> System.nanoTime() / 1000000); }
    ClipboardSnapshotCache(LongSupplier clock) { this.clock = clock; }

    T read(long observedTimestamp, String observedIdentity, Loader<T> loader) throws Exception {
        if (observedTimestamp > 0 && observedTimestamp == timestamp
                && observedIdentity.equals(identity)) {
            if (value != null || clock.getAsLong() < retryAt) return value;
        }
        clear();
        if (observedTimestamp > 0) {
            timestamp = observedTimestamp;
            identity = observedIdentity;
            retryAt = clock.getAsLong() + 2000;
        }
        T loaded = loader.load();
        if (observedTimestamp > 0 && loaded != null) {
            value = loaded;
        }
        return loaded;
    }

    void clear() { timestamp = 0; identity = null; value = null; retryAt = 0; }
}
