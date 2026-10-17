package com.genymobile.scrcpy;

import java.util.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;

/** Synthetic observations only. No Android runtime, device names or serials. */
public final class DisplayStateSnapshotTest {
    interface Throwing { void run() throws Exception; }
    static void reject(Throwing action) throws Exception {
        try { action.run(); throw new AssertionError("ambiguous display evidence accepted"); }
        catch (DisplayStateSnapshot.Failure expected) {}
    }
    static String panels(String one, String two) {
        return "Display 10 (HWC display 0): name=neutral\nDisplay 20 color modes:\n"
            + "Display 10\n connectionType=Internal\n powerMode=" + one + "\n"
            + "Display 20\n connectionType=Internal\n powerMode=" + two + "\n"
            + "Virtual Display 900\n powerMode=ON\nDisplay 10 (physical, neutral)\n";
    }
    static String power(String global, long wake, long sleep, String group) {
        return "POWER MANAGER (dumpsys power)\n\nPower Manager State:\n"
            + "  mWakefulness=" + global + "\n  mWakefulnessChanging=false\n"
            + "  mLastWakeTime=" + wake + " (20 ms ago)\n"
            + "  mLastSleepTime=" + sleep + " (never)\n\nSettings and Configuration:\n"
            + "  ignored=true\n\n" + group + "\nWireless Charger Detector State:\n"
            + "mWakefulness=3\nlastUserActivityTime=999\n";
    }
    static String group(int id, String wakefulness, long activity) {
        return "groupId: " + id + "\nlastUserActivityTime=" + activity + " (1 ms ago)\n"
            + "lastUserActivityTimeNoChangeLights=123 (2 ms ago)\nmWakefulness=" + wakefulness + "\n";
    }
    static DisplayStateSnapshot.PowerEvidence evidence(boolean interactive, long activity) throws Exception {
        return DisplayStateSnapshot.parsePower(power("Awake", 200, 100,
            "Power Group User Activity:\n" + group(0, "1", activity)), interactive);
    }
    public static void main(String[] args) throws Exception {
        Map<String, DisplayStateSnapshot.Mode> parsed = new LinkedHashMap<>(DisplayStateSnapshot.parsePhysical(panels("OFF", "DOZE")));
        assert parsed.size() == 2 && parsed.get("10") == DisplayStateSnapshot.Mode.OFF;
        assert parsed.get("20") == DisplayStateSnapshot.Mode.DOZE && !parsed.containsKey("900");
        assert DisplayStateSnapshot.parsePhysical(panels("DozeSuspend", "OnSuspend")).get("10") == DisplayStateSnapshot.Mode.DOZE_SUSPEND;
        assert DisplayStateSnapshot.parsePhysical(panels("DOZE_SUSPEND", "ON_SUSPEND")).get("20") == DisplayStateSnapshot.Mode.ON_SUSPEND;
        assert DisplayStateSnapshot.parsePhysical(panels("Off", "On")).get("20") == DisplayStateSnapshot.Mode.ON;
        reject(() -> DisplayStateSnapshot.parsePhysical(panels("OFF", "UNKNOWN")));
        reject(() -> DisplayStateSnapshot.parsePhysical(panels("OFF", "0")));
        reject(() -> DisplayStateSnapshot.parsePhysical(panels("OFF", "ON") + "Display 20\n connectionType=Internal\n powerMode=OFF\n"));
        reject(() -> DisplayStateSnapshot.parsePhysical("Virtual Display 2\n powerMode=ON\n"));
        reject(() -> DisplayStateSnapshot.parsePhysical(panels("OFF", "ON").replace("powerMode=ON", "powerMode=ON\n powerMode=OFF")));
        reject(() -> DisplayStateSnapshot.parsePhysical(panels("OFF", "ON").replace("Display 20\n", "Display 020\n")));
        reject(() -> DisplayStateSnapshot.parsePhysical(new String(new char[DisplayStateSnapshot.MAX_DUMP_BYTES + 1])));
        char[] utf8 = new char[DisplayStateSnapshot.MAX_DUMP_BYTES / 3 + 1]; Arrays.fill(utf8, '\u754c');
        reject(() -> DisplayStateSnapshot.parsePhysical(new String(utf8)));
        char[] tooManyLines = new char[32769]; Arrays.fill(tooManyLines, '\n');
        reject(() -> DisplayStateSnapshot.parsePhysical(new String(tooManyLines)));
        reject(() -> DisplayStateSnapshot.parsePhysical(null));
        assert DisplayStateSnapshot.validID("18446744073709551615");
        for (String id : Arrays.asList("-1", "01", "18446744073709551616", "", "1\n2")) assert !DisplayStateSnapshot.validID(id);

        // Global state can stay Awake while group 0 sleeps. Never relabel it as default-display evidence.
        DisplayStateSnapshot.PowerEvidence mixed = DisplayStateSnapshot.parsePower(power("Awake", 200, 100,
            "Power Group User Activity:\n" + group(1, "1", 880) + group(0, "3", 90)), false);
        assert mixed.globalWakefulness == DisplayStateSnapshot.Wakefulness.AWAKE;
        assert mixed.defaultWakefulness == DisplayStateSnapshot.Wakefulness.DOZING && !mixed.defaultInteractive;
        assert mixed.defaultActivityTime == 90 && mixed.lastGlobalWakeTime == 200 && mixed.lastGlobalSleepTime == 100;
        assert mixed.transitionScope == DisplayStateSnapshot.TransitionScope.GLOBAL : "global stamps and activity time are not per-group transition history";
        DisplayStateSnapshot.PowerEvidence old = DisplayStateSnapshot.parsePower(power("Awake", 0, 0,
            "Display Group User Activity:\n  displayGroupId=1\n  lastUserActivityTime=999\n  lastUserActivityTimeNoChangeLights=9\n"
            + "  displayGroupId=0\n  lastUserActivityTime=70 (1 ms ago)\n  lastUserActivityTimeNoChangeLights=40 (2 ms ago)"), true);
        assert old.defaultWakefulness == null && old.defaultActivityTime == 70;
        assert old.defaultInteractive && old.transitionScope == DisplayStateSnapshot.TransitionScope.GLOBAL;
        reject(() -> DisplayStateSnapshot.parsePower(power("Dozing", 1, 2,
            "Display Group User Activity:\n  displayGroupId=0\n  lastUserActivityTime=9\n  lastUserActivityTimeNoChangeLights=8"), true));
        reject(() -> DisplayStateSnapshot.parsePower(power("Asleep", 1, 2, "Power Group User Activity:\n" + group(0, "1", 9)), true));
        reject(() -> DisplayStateSnapshot.parsePower(power("Asleep", 1, 2, "Power Group User Activity:\n" + group(0, "3", 9)), false));
        reject(() -> DisplayStateSnapshot.parsePower(power("Dreaming", 1, 2, "Power Group User Activity:\n" + group(0, "1", 9)), true));
        assert !mixed.sameObservation(evidence(true, 90));
        assert !evidence(true, 90).sameObservation(evidence(true, 91)) : "group activity changes must fence sampled evidence";
        assert evidence(true, 90).sameObservation(evidence(true, 90));
        reject(() -> DisplayStateSnapshot.parsePower(power("Awake", 1, 2, ""), true));
        reject(() -> DisplayStateSnapshot.parsePower(power("Awake", 1, 2, "Power Group User Activity:\n" + group(0, "3", 9)), true));
        reject(() -> DisplayStateSnapshot.parsePower(power("Awake", 1, 2, "Power Group User Activity:\n" + group(0, "1", 9) + group(0, "1", 9)), true));
        reject(() -> DisplayStateSnapshot.parsePower(power("Awake", 1, 2, "Power Group User Activity:\n" + group(0, "9", 9)), true));
        reject(() -> DisplayStateSnapshot.parsePower(power("Unknown", 1, 2, "Power Group User Activity:\n" + group(0, "1", 9)), true));
        reject(() -> DisplayStateSnapshot.parsePower(power("Awake", 1, 2, "Power Group User Activity:\n" + group(0, "1", 9)).replace("mWakefulnessChanging=false", "mWakefulnessChanging=true"), true));
        reject(() -> DisplayStateSnapshot.parsePower(power("Awake", 1, 2, "Power Group User Activity:\n" + group(0, "1", 9)).replace("mLastWakeTime=1", "mLastWakeTime=-1"), true));
        reject(() -> DisplayStateSnapshot.parsePower(power("Awake", 1, 2, "Power Group User Activity:\n" + group(0, "1", 9)).replace("mLastWakeTime=1", "mLastWakeTime=9223372036854775808"), true));
        reject(() -> DisplayStateSnapshot.parsePower(power("Awake", 1, 2, "Power Group User Activity:\n" + group(0, "1", 9)).replace("  mLastSleepTime=2 (never)\n", ""), true));

        Set<String> ids = new HashSet<>(Arrays.asList("10", "20"));
        DisplayStateSnapshot snapshot = new DisplayStateSnapshot(parsed, "20", ids, mixed);
        assert snapshot.panels.get("20") == DisplayStateSnapshot.Mode.DOZE;
        parsed.put("20", DisplayStateSnapshot.Mode.ON); ids.add("30");
        assert snapshot.panels.get("20") == DisplayStateSnapshot.Mode.DOZE && snapshot.physicalIDs.size() == 2;
        try { snapshot.panels.put("20", DisplayStateSnapshot.Mode.OFF); throw new AssertionError(); } catch (UnsupportedOperationException expected) {}
        reject(() -> new DisplayStateSnapshot(parsed, "900", parsed.keySet(), mixed));
        reject(() -> new DisplayStateSnapshot(parsed, "20", ids, mixed));
        Map<String, DisplayStateSnapshot.Mode> many = new LinkedHashMap<>();
        for (int i = 0; i < 9; ++i) many.put("" + i, DisplayStateSnapshot.Mode.OFF);
        reject(() -> new DisplayStateSnapshot(many, "0", many.keySet(), mixed));

        // Sampling is read-only and fences changes on either side of the physical observation.
        final int[] calls = {0};
        DisplayStateSnapshot.SampleSource stable = new DisplayStateSnapshot.SampleSource() {
            public DisplayStateSnapshot.PowerEvidence power() throws Exception { calls[0]++; return evidence(true, calls[0] < 3 ? calls[0] : 3); }
            public DisplayStateSnapshot.PhysicalEvidence physical() throws Exception {
                return new DisplayStateSnapshot.PhysicalEvidence(DisplayStateSnapshot.parsePhysical(panels("OFF", "ON")), "20", new HashSet<>(Arrays.asList("10", "20")));
            }
        };
        assert DisplayStateSnapshot.sample(stable).power.defaultActivityTime == 3 && calls[0] == 4;
        final int[] changes = {0};
        reject(() -> DisplayStateSnapshot.sample(new DisplayStateSnapshot.SampleSource() {
            public DisplayStateSnapshot.PowerEvidence power() throws Exception { return evidence(true, ++changes[0]); }
            public DisplayStateSnapshot.PhysicalEvidence physical() throws Exception { return stable.physical(); }
        }));
        assert changes[0] == 6 : "unstable sampling must have a fixed attempt bound";
        final int[] topology = {0};
        reject(() -> DisplayStateSnapshot.sample(new DisplayStateSnapshot.SampleSource() {
            public DisplayStateSnapshot.PowerEvidence power() throws Exception { return evidence(true, 3); }
            public DisplayStateSnapshot.PhysicalEvidence physical() throws Exception {
                DisplayStateSnapshot.PhysicalEvidence value = stable.physical();
                return new DisplayStateSnapshot.PhysicalEvidence(value.panels, ++topology[0] % 2 == 0 ? "10" : "20", value.physicalIDs);
            }
        }));
        assert topology[0] == 6;
        if (args.length % 2 != 0) throw new IllegalArgumentException("Expected private power dump / explicit interactivity pairs");
        for (int i = 0; i < args.length; i += 2) {
            if (!args[i + 1].equals("true") && !args[i + 1].equals("false")) throw new IllegalArgumentException("Interactivity must be explicit");
            DisplayStateSnapshot.parsePower(new String(Files.readAllBytes(Paths.get(args[i])), StandardCharsets.UTF_8), Boolean.parseBoolean(args[i + 1]));
        }
        System.out.println("PASS exact raw panel modes, independent default interactivity, global/group isolation, strict bounded evidence and stable read-only sampling");
        if (args.length != 0) System.out.println("PASS private captured power schemas: " + args.length / 2 + "; contents not emitted or included in source fixtures");
    }
}
