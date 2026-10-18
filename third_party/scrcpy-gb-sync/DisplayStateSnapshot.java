package com.genymobile.scrcpy;

import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Exact, read-only evidence for composite display ownership. Does not wake, sleep or write panels. */
final class DisplayStateSnapshot {
    static final int MAX_DUMP_BYTES = 8 * 1024 * 1024;
    private static final int MAX_PANELS = 8;
    private static final int MAX_DUMP_LINES = 32768;
    private static final int SAMPLE_ATTEMPTS = 3;
    private static final Pattern DISPLAY = Pattern.compile("^(Virtual )?Display ([0-9]{1,20})(?:\\b.*)?$");
    private static final Pattern UPTIME = Pattern.compile("^(0|[1-9][0-9]{0,18})(?: \\([^\\r\\n]*\\))?$");
    private static final Comparator<String> IDS = new Comparator<String>() {
        public int compare(String one, String two) {
            return one.length() == two.length() ? one.compareTo(two) : Integer.compare(one.length(), two.length());
        }
    };

    static final class Failure extends Exception {
        final String code;
        Failure(String code) { super(code); this.code = code; }
    }
    enum Mode {
        OFF, ON, DOZE, DOZE_SUSPEND, ON_SUSPEND;
        static Mode parse(String text) throws Failure {
            switch (text.toUpperCase(Locale.ROOT)) {
                case "OFF": return OFF;
                case "ON": return ON;
                case "DOZE": return DOZE;
                case "DOZE_SUSPEND": case "DOZESUSPEND": return DOZE_SUSPEND;
                case "ON_SUSPEND": case "ONSUSPEND": return ON_SUSPEND;
                default: throw new Failure("display_mode_unknown");
            }
        }
    }
    enum Wakefulness {
        ASLEEP, AWAKE, DREAMING, DOZING;
        boolean interactive() { return this == AWAKE || this == DREAMING; }
        int aggregateRank() {
            switch (this) {
                case AWAKE: return 3;
                case DREAMING: return 2;
                case DOZING: return 1;
                default: return 0;
            }
        }
        static Wakefulness name(String value) throws Failure {
            switch (value) {
                case "Asleep": return ASLEEP;
                case "Awake": return AWAKE;
                case "Dreaming": return DREAMING;
                case "Dozing": return DOZING;
                default: throw new Failure("display_wakefulness_unknown");
            }
        }
        static Wakefulness group(String value) throws Failure {
            switch (value) {
                case "0": return ASLEEP;
                case "1": return AWAKE;
                case "2": return DREAMING;
                case "3": return DOZING;
                default: return name(value);
            }
        }
    }
    enum TransitionScope { GLOBAL }

    /** The top-level PowerManager stamps are GLOBAL, even when display 0 has a different state. */
    static final class PowerEvidence {
        final boolean defaultInteractive;
        final Wakefulness defaultWakefulness; // explicit, or uniquely resolved from a complete group inventory
        final Wakefulness globalWakefulness;
        final Set<String> powerGroupIDs;
        final boolean completePowerGroupInventory;
        final long lastGlobalWakeTime, lastGlobalSleepTime;
        final long defaultActivityTime, defaultActivityNoChangeLightsTime;
        final TransitionScope transitionScope = TransitionScope.GLOBAL;
        private PowerEvidence(boolean interactive, Wakefulness group, Wakefulness global, long wake, long sleep,
                long activity, long noChangeLights, Set<String> groups, boolean completeGroups) throws Failure {
            if ((group != null && group.interactive() != interactive) || (interactive && !global.interactive())
                    || (group != null && group.aggregateRank() > global.aggregateRank()))
                throw new Failure("display_interactivity_unsettled");
            defaultInteractive = interactive; defaultWakefulness = group; globalWakefulness = global;
            powerGroupIDs = Collections.unmodifiableSet(new LinkedHashSet<>(groups));
            completePowerGroupInventory = completeGroups;
            lastGlobalWakeTime = wake; lastGlobalSleepTime = sleep;
            defaultActivityTime = activity; defaultActivityNoChangeLightsTime = noChangeLights;
        }
        boolean sameObservation(PowerEvidence other) {
            return other != null && defaultInteractive == other.defaultInteractive && defaultWakefulness == other.defaultWakefulness
                && globalWakefulness == other.globalWakefulness && lastGlobalWakeTime == other.lastGlobalWakeTime
                && lastGlobalSleepTime == other.lastGlobalSleepTime && defaultActivityTime == other.defaultActivityTime
                && defaultActivityNoChangeLightsTime == other.defaultActivityNoChangeLightsTime
                && completePowerGroupInventory == other.completePowerGroupInventory && powerGroupIDs.equals(other.powerGroupIDs);
        }
    }

    static final class PhysicalEvidence {
        final Map<String, Mode> panels;
        final String activePhysicalID;
        final Set<String> physicalIDs;
        PhysicalEvidence(Map<String, Mode> values, String active, Set<String> inventory) throws Failure {
            if (values == null || inventory == null || values.isEmpty() || values.size() > MAX_PANELS
                    || !values.keySet().equals(inventory) || !validID(active) || !inventory.contains(active))
                throw new Failure("display_inventory_unknown");
            List<String> ordered = new ArrayList<>(inventory);
            for (String id : ordered) if (!validID(id) || values.get(id) == null) throw new Failure("display_inventory_unknown");
            Collections.sort(ordered, IDS);
            Map<String, Mode> copy = new LinkedHashMap<>();
            for (String id : ordered) copy.put(id, values.get(id));
            panels = Collections.unmodifiableMap(copy); activePhysicalID = active;
            physicalIDs = Collections.unmodifiableSet(new LinkedHashSet<>(ordered));
        }
        boolean samePhysicalState(PhysicalEvidence other) {
            return other != null && activePhysicalID.equals(other.activePhysicalID) && physicalIDs.equals(other.physicalIDs)
                && panels.equals(other.panels);
        }
    }
    final Map<String, Mode> panels;
    final String activePhysicalID;
    final Set<String> physicalIDs;
    final PowerEvidence power;
    DisplayStateSnapshot(Map<String, Mode> values, String active, Set<String> inventory, PowerEvidence evidence) throws Failure {
        if (evidence == null) throw new Failure("display_power_evidence_missing");
        PhysicalEvidence physical = new PhysicalEvidence(values, active, inventory);
        panels = physical.panels; activePhysicalID = physical.activePhysicalID; physicalIDs = physical.physicalIDs; power = evidence;
    }

    interface SampleSource {
        PowerEvidence power() throws Exception;
        PhysicalEvidence physical() throws Exception;
    }
    /** Source reads must themselves have bounded I/O. No mutable observation becomes a restoration baseline. */
    static DisplayStateSnapshot sample(SampleSource source) throws Exception {
        for (int attempt = 0; attempt < SAMPLE_ATTEMPTS; ++attempt) {
            PowerEvidence before = source.power(); PhysicalEvidence first = source.physical();
            PhysicalEvidence second = source.physical(); PowerEvidence after = source.power();
            if (before != null && after != null && first != null && second != null
                    && before.sameObservation(after) && first.samePhysicalState(second))
                return new DisplayStateSnapshot(second.panels, second.activePhysicalID, second.physicalIDs, after);
        }
        throw new Failure("display_snapshot_unsettled");
    }

    static boolean validID(String value) {
        if (value == null || !value.matches("0|[1-9][0-9]{0,19}")) return false;
        return value.length() < 20 || value.compareTo("18446744073709551615") <= 0;
    }
    private static String[] lines(String dump) throws Failure {
        if (dump == null || dump.length() > MAX_DUMP_BYTES || dump.getBytes(StandardCharsets.UTF_8).length > MAX_DUMP_BYTES
                || dump.indexOf('\0') >= 0) throw new Failure("display_dump_limit");
        String[] result = dump.split("\n", MAX_DUMP_LINES + 1);
        if (result.length > MAX_DUMP_LINES) throw new Failure("display_dump_limit");
        return result;
    }
    private static final class PanelRecord {
        final String id;
        final boolean virtual;
        boolean internal;
        Mode mode;
        PanelRecord(String id, boolean virtual) { this.id = id; this.virtual = virtual; }
    }
    private static void add(PanelRecord record, Map<String, Mode> modes) throws Failure {
        if (record == null || record.virtual || !record.internal) return;
        if (!validID(record.id) || record.mode == null || modes.size() >= MAX_PANELS || modes.containsKey(record.id))
            throw new Failure("display_physical_state_unknown");
        modes.put(record.id, record.mode);
    }
    static Map<String, Mode> parsePhysical(String dump) throws Failure {
        Map<String, Mode> modes = new LinkedHashMap<>(); PanelRecord record = null;
        for (String raw : lines(dump)) {
            String line = raw.trim(); Matcher header = DISPLAY.matcher(line);
            if (header.matches()) {
                add(record, modes);
                record = new PanelRecord(header.group(2), header.group(1) != null || line.toLowerCase(Locale.ROOT).contains("virtual"));
            } else if (record != null && !record.virtual) {
                if (line.equals("connectionType=Internal")) record.internal = true;
                else if (line.startsWith("powerMode=")) {
                    if (record.mode != null) throw new Failure("display_physical_state_unknown");
                    record.mode = Mode.parse(line.substring(10).trim());
                }
            }
        }
        add(record, modes);
        if (modes.isEmpty()) throw new Failure("display_physical_state_unknown");
        return Collections.unmodifiableMap(modes);
    }
    private static long uptime(String text) throws Failure {
        Matcher value = UPTIME.matcher(text);
        if (!value.matches()) throw new Failure("display_power_time_unknown");
        try { return Long.parseLong(value.group(1)); }
        catch (NumberFormatException invalid) { throw new Failure("display_power_time_unknown"); }
    }
    private static void put(Map<String, String> values, String key, String value) throws Failure {
        if (values.put(key, value) != null) throw new Failure("display_power_field_duplicate");
    }
    private static String required(Map<String, String> values, String key) throws Failure {
        String value = values.get(key);
        if (value == null) throw new Failure("display_power_field_missing");
        return value;
    }
    static PowerEvidence parsePower(String dump, boolean defaultInteractive) throws Failure {
        Map<String, String> global = new HashMap<>(), group = null, defaultGroup = null;
        Set<String> groups = new HashSet<>();
        Map<String, Map<String, String>> groupFields = new HashMap<>();
        boolean stateSection = false, activitySection = false, sawState = false, sawActivity = false;
        boolean completeGroups = false;
        for (String raw : lines(dump)) {
            String line = raw.trim();
            if (line.equals("Power Manager State:")) {
                if (sawState) throw new Failure("display_power_field_duplicate");
                sawState = true; stateSection = true; activitySection = false; continue;
            }
            if (line.equals("Power Group User Activity:") || line.equals("Display Group User Activity:")) {
                if (sawActivity) throw new Failure("display_power_field_duplicate");
                sawActivity = true; activitySection = true; stateSection = false; continue;
            }
            // Section headers are unindented. Do not consume similarly named vendor diagnostics elsewhere.
            if (!raw.isEmpty() && !Character.isWhitespace(raw.charAt(0)) && line.endsWith(":")) {
                if (activitySection) completeGroups = line.equals("Wireless Charger Detector State:")
                    || line.equals("Notifier:") || line.equals("FaceDownDetector:");
                stateSection = false; activitySection = false; continue;
            }
            if (stateSection) {
                int split = line.indexOf('=');
                if (split < 0) continue;
                String name = line.substring(0, split);
                if (name.equals("mWakefulness") || name.equals("mWakefulnessChanging")
                        || name.equals("mLastWakeTime") || name.equals("mLastSleepTime"))
                    put(global, name, line.substring(split + 1));
            } else if (activitySection) {
                if (line.startsWith("groupId: ") || line.startsWith("displayGroupId=")) {
                    String id = line.substring(line.startsWith("groupId: ") ? 9 : 15);
                    if (!id.matches("0|[1-9][0-9]{0,8}") || !groups.add(id) || groups.size() > 64)
                        throw new Failure("display_group_unknown");
                    group = new HashMap<>();
                    groupFields.put(id, group);
                    if (id.equals("0")) defaultGroup = group;
                } else if (line.startsWith("groupId") || line.startsWith("displayGroupId")) {
                    throw new Failure("display_group_unknown");
                } else if (group != null) {
                    int split = line.indexOf('=');
                    if (split < 0) continue;
                    String name = line.substring(0, split);
                    if (name.equals("lastUserActivityTime") || name.equals("lastUserActivityTimeNoChangeLights") || name.equals("mWakefulness"))
                        put(group, name, line.substring(split + 1));
                }
            }
        }
        if (!sawState || defaultGroup == null) throw new Failure("display_power_evidence_missing");
        if (!required(global, "mWakefulnessChanging").equals("false")) throw new Failure("display_power_unsettled");
        Wakefulness globalState = Wakefulness.name(required(global, "mWakefulness"));
        Wakefulness defaultState = defaultGroup.containsKey("mWakefulness") ? Wakefulness.group(defaultGroup.get("mWakefulness")) : null;
        if (defaultState == null && completeGroups) {
            // AOSP's global state is max(all live groups). The activity section
            // enumerates that same locked inventory. Resolve only unique cases;
            // another awake group must never turn a dreaming default into AWAKE.
            for (Map<String, String> fields : groupFields.values()) {
                uptime(required(fields, "lastUserActivityTime"));
                uptime(required(fields, "lastUserActivityTimeNoChangeLights"));
                if (fields.containsKey("mWakefulness") && Wakefulness.group(fields.get("mWakefulness")).aggregateRank() > globalState.aggregateRank())
                    throw new Failure("display_power_unsettled");
            }
            if (groups.size() == 1 || globalState == Wakefulness.ASLEEP
                    || (globalState == Wakefulness.DREAMING && defaultInteractive)) defaultState = globalState;
        }
        return new PowerEvidence(defaultInteractive, defaultState, globalState,
            uptime(required(global, "mLastWakeTime")), uptime(required(global, "mLastSleepTime")),
            uptime(required(defaultGroup, "lastUserActivityTime")), uptime(required(defaultGroup, "lastUserActivityTimeNoChangeLights")),
            groups, completeGroups);
    }
}
