package com.genymobile.scrcpy;

import java.util.LinkedHashMap;

/** A clipboard-history recopy is a new occurrence even if extras were preserved. */
final class ClipboardOriginTracker {
    private final LinkedHashMap<String, Long> firstTimestamps = new LinkedHashMap<>();

    String originFor(String origin, long timestamp, String platformSource) {
        if (origin == null || timestamp <= 0) return null;
        // Extras can survive a copy made by another app. The platform-owned
        // writer attribution distinguishes that new copy even when this
        // process never observed the original injection. Unknown attribution
        // must not suppress a genuine user copy.
        if (!"com.android.shell".equals(platformSource)
                && !"com.xopmc.galaxybridge".equals(platformSource)
                && !"com.xopmc.galaxybridge.internal".equals(platformSource)) return null;
        Long first = firstTimestamps.get(origin);
        if (first != null) return first.longValue() == timestamp ? origin : null;
        firstTimestamps.put(origin, timestamp);
        if (firstTimestamps.size() > 512) firstTimestamps.remove(firstTimestamps.keySet().iterator().next());
        return origin;
    }
}
