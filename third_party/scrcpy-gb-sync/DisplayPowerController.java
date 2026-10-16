package com.genymobile.scrcpy;

import android.os.IBinder;
import android.os.Looper;
import android.system.Os;
import com.genymobile.scrcpy.display.DisplayInfo;
import com.genymobile.scrcpy.util.Ln;
import com.genymobile.scrcpy.wrappers.DisplayControl;
import com.genymobile.scrcpy.wrappers.ServiceManager;
import com.genymobile.scrcpy.wrappers.SurfaceControl;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Shell-only physical panel owner. No sockets, input, brightness or keyguard operations. */
public final class DisplayPowerController {
    static final int MAX_PANELS = 8;
    static final int MAX_DUMP_BYTES = 8 * 1024 * 1024;
    static final int MAX_REPLY_BYTES = 4096;
    private static final Pattern HEADER = Pattern.compile("^(Virtual )?Display ([0-9]{1,20})(?:\\b.*)?$");
    private DisplayPowerController() {}

    static final class Failure extends IOException {
        final String code;
        Failure(String code) { super(code); this.code = code; }
    }
    interface Backend {
        Frame read() throws Exception;
        boolean set(String physicalID, boolean on) throws Exception;
    }
    static boolean validID(String value) {
        if (value == null || !value.matches("0|[1-9][0-9]{0,19}")) return false;
        try { return Long.toUnsignedString(Long.parseUnsignedLong(value)).equals(value); }
        catch (NumberFormatException invalid) { return false; }
    }
    static final class Frame {
        final Map<String, Boolean> states;
        final Set<String> topology;
        final String active;
        Frame(Map<String, Boolean> values, String active) throws Failure {
            this(values, active, values.keySet());
        }
        Frame(Map<String, Boolean> values, String active, Set<String> physicalIDs) throws Failure {
            if (values.isEmpty() || values.size() > MAX_PANELS || !validID(active) || !values.containsKey(active))
                throw new Failure("panel_topology_unknown");
            if (physicalIDs.isEmpty() || physicalIDs.size() > MAX_PANELS || !physicalIDs.containsAll(values.keySet()))
                throw new Failure("panel_topology_unknown");
            for (String id : physicalIDs) if (!validID(id)) throw new Failure("panel_topology_unknown");
            for (String id : values.keySet()) if (!validID(id) || values.get(id) == null) throw new Failure("panel_state_unknown");
            List<String> ids = new ArrayList<>(values.keySet());
            Collections.sort(ids, (a, b) -> a.length() == b.length() ? a.compareTo(b) : Integer.compare(a.length(), b.length()));
            Map<String, Boolean> copy = new LinkedHashMap<>();
            for (String id : ids) {
                if (!validID(id) || values.get(id) == null) throw new Failure("panel_state_unknown");
                copy.put(id, values.get(id));
            }
            states = Collections.unmodifiableMap(copy); topology = Collections.unmodifiableSet(new HashSet<>(physicalIDs)); this.active = active;
        }
        String state() {
            boolean on = states.containsValue(Boolean.TRUE);
            return states.size() == 1 ? (on ? "panel_on" : "panel_off") : (on ? "panel_multi_on" : "panel_multi_off");
        }
    }
    private static final class Record {
        final String id;
        final boolean virtual;
        boolean internal;
        String power;
        Record(String id, boolean virtual) { this.id = id; this.virtual = virtual; }
    }
    private static void addRecord(Record record, Map<String, Boolean> values) throws Failure {
        if (record == null || record.virtual || !record.internal) return;
        if (!validID(record.id) || values.containsKey(record.id) || values.size() >= MAX_PANELS ||
            !("ON".equals(record.power) || "OFF".equals(record.power))) throw new Failure("panel_state_unknown");
        values.put(record.id, record.power.equals("ON"));
    }
    static Map<String, Boolean> parsePhysical(String dump) throws Failure {
        if (dump == null || dump.length() > MAX_DUMP_BYTES || dump.getBytes(StandardCharsets.UTF_8).length > MAX_DUMP_BYTES)
            throw new Failure("panel_dump_limit");
        Map<String, Boolean> values = new LinkedHashMap<>(); Record record = null;
        for (String raw : dump.split("\n")) {
            String line = raw.trim(); Matcher header = HEADER.matcher(line);
            if (header.matches()) {
                addRecord(record, values);
                record = new Record(header.group(2), header.group(1) != null || line.toLowerCase(Locale.ROOT).contains("virtual"));
            } else if (record != null && !record.virtual) {
                if (line.equals("connectionType=Internal")) record.internal = true;
                else if (line.startsWith("powerMode=")) {
                    if (record.power != null) throw new Failure("panel_state_unknown");
                    record.power = line.substring(10).trim().toUpperCase(Locale.ROOT);
                }
            }
        }
        addRecord(record, values);
        if (values.isEmpty()) throw new Failure("panel_state_unknown");
        return values;
    }

    static final class Controller {
        final Backend backend;
        final Frame initial;
        Frame current;
        final Map<String, Boolean> attempted = new HashMap<>();
        boolean restored;
        Controller(Backend backend) throws Exception { this.backend = backend; initial = backend.read(); current = initial; }
        private Frame read() throws Exception {
            Frame frame = backend.read();
            if (!frame.states.keySet().equals(initial.states.keySet()) || !frame.topology.equals(initial.topology)) throw new Failure("panel_topology_changed");
            current = frame; return frame;
        }
        synchronized Frame status() throws Exception { return read(); }
        private void write(String id, boolean value) throws Exception {
            // Arm ownership before the call: native code can apply and still fail.
            attempted.put(id, value);
            try { if (!backend.set(id, value)) throw new Failure("panel_apply_failed"); }
            catch (Failure failure) { throw failure; }
            catch (Exception failure) { throw new Failure("panel_apply_failed"); }
        }
        private void confirm(Map<String, Boolean> expected, String active) throws Exception {
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3);
            do {
                Frame frame = read();
                if (!frame.active.equals(active)) throw new Failure("panel_posture_changed");
                if (frame.states.equals(expected)) return;
                Thread.sleep(40);
            } while (System.nanoTime() < deadline);
            throw new Failure("panel_unconfirmed");
        }
        synchronized void power(boolean on) throws Exception {
            if (restored) throw new Failure("panel_owner_closed");
            Frame before = read(); Map<String, Boolean> target = new LinkedHashMap<>();
            for (String id : before.states.keySet()) target.put(id, on && id.equals(before.active));
            // Turn inactive panels OFF before enabling the current physical panel.
            for (String id : target.keySet()) if (!target.get(id) && before.states.get(id)) write(id, false);
            if (on && !before.states.get(before.active)) {
                Frame guard = read();
                if (!guard.active.equals(before.active)) throw new Failure("panel_posture_changed");
                write(before.active, true);
            }
            confirm(target, before.active);
        }
        synchronized void restore() throws Exception {
            if (restored) return;
            Frame before = read(); boolean changedPosture = !before.active.equals(initial.active);
            // Only restore IDs this owner attempted to change. Never overwrite
            // a newly discovered display or wake an old inactive fold panel.
            for (String id : initial.states.keySet()) {
                boolean desired = initial.states.get(id);
                if (!attempted.containsKey(id)) {
                    if (before.states.get(id) != desired) throw new Failure("panel_ownership_lost");
                    continue;
                }
                if (before.states.get(id) == desired) continue;
                if (!before.states.get(id).equals(attempted.get(id))) throw new Failure("panel_ownership_lost");
                if (!desired) write(id, false);
            }
            if (changedPosture) throw new Failure("panel_posture_changed");
            for (String id : initial.states.keySet()) if (initial.states.get(id) && attempted.containsKey(id)) {
                Frame guard = read();
                if (!guard.active.equals(initial.active)) throw new Failure("panel_posture_changed");
                if (!guard.states.get(id)) write(id, true);
            }
            confirm(initial.states, initial.active); restored = true;
        }
    }

    private static String statesJSON(Map<String, Boolean> states) {
        StringBuilder json = new StringBuilder("[");
        for (Map.Entry<String, Boolean> entry : states.entrySet()) {
            if (json.length() > 1) json.append(',');
            json.append("{\"id\":\"").append(entry.getKey()).append("\",\"on\":").append(entry.getValue()).append('}');
        }
        return json.append(']').toString();
    }
    private static void reply(OutputStream output, Controller owner, int pid, String startTime, boolean ok, String error) throws IOException {
        String line = "{\"version\":1,\"pid\":" + pid + ",\"startTime\":\"" + startTime + "\",\"initial\":" +
            statesJSON(owner == null ? Collections.emptyMap() : owner.initial.states) + ",\"current\":" +
            statesJSON(owner == null ? Collections.emptyMap() : owner.current.states) + ",\"ok\":" + ok + ",\"error\":\"" + error + "\"}\n";
        byte[] bytes = line.getBytes(StandardCharsets.UTF_8);
        if (bytes.length > MAX_REPLY_BYTES) throw new IOException("panel_reply_limit");
        output.write(bytes); output.flush();
        if (output instanceof PrintStream && ((PrintStream) output).checkError()) throw new IOException("panel_output_closed");
    }
    static boolean serve(InputStream input, OutputStream output, Controller owner, int pid, String startTime) throws Exception {
        if (pid <= 0 || !startTime.matches("[1-9][0-9]{0,19}")) throw new Failure("panel_identity_unknown");
        try {
            reply(output, owner, pid, startTime, true, "");
            int command;
            while ((command = input.read()) != -1) {
                try {
                    if (command == 0 || command == 1) owner.power(command == 1);
                    else if (command == 2) owner.restore();
                    else if (command == 3) owner.status();
                    else throw new Failure("panel_command_invalid");
                    reply(output, owner, pid, startTime, true, "");
                    if (command == 2) return true;
                } catch (Failure failure) {
                    String code = "panel_operation_failed_restored";
                    try { owner.restore(); } catch (Exception restoration) { code = restoration instanceof Failure ? ((Failure) restoration).code : "panel_restore_unconfirmed"; }
                    reply(output, owner, pid, startTime, false, code); return false;
                }
            }
            return true;
        } finally { owner.restore(); }
    }

    private static byte[] readBounded(File file, int limit) throws IOException {
        try (InputStream input = new FileInputStream(file); ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] bytes = new byte[4096]; int count;
            while ((count = input.read(bytes)) != -1) { if (output.size() + count > limit) throw new IOException("panel_read_limit"); output.write(bytes, 0, count); }
            return output.toByteArray();
        }
    }
    private static String fixedDump() throws Exception {
        Process process = new ProcessBuilder("/system/bin/dumpsys", "SurfaceFlinger").redirectErrorStream(true).start();
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        final IOException[] error = new IOException[1];
        Thread reader = new Thread(() -> { try (InputStream input = process.getInputStream()) {
            byte[] bytes = new byte[4096]; int count;
            while ((count = input.read(bytes)) != -1) {
                if (output.size() + count > MAX_DUMP_BYTES) throw new IOException("panel_dump_limit"); output.write(bytes, 0, count);
            }
        } catch (IOException failure) { error[0] = failure; } }, "gb-panel-read");
        reader.setDaemon(true); reader.start();
        try {
            if (!process.waitFor(2, TimeUnit.SECONDS)) throw new Failure("panel_read_timeout");
            reader.join(200);
            if (reader.isAlive() || error[0] != null || process.exitValue() != 0) throw new Failure("panel_read_failed");
            return new String(output.toByteArray(), StandardCharsets.UTF_8);
        } finally { if (process.isAlive()) process.destroyForcibly(); }
    }
    static Frame runtimeFrame() throws Exception { return new RuntimeBackend().read(); }
    private static final class RuntimeBackend implements Backend {
        private final boolean displayControl = !SurfaceControl.hasGetPhysicalDisplayIdsMethod();
        private Set<String> physicalIDs() throws Failure {
            long[] ids = displayControl ? DisplayControl.getPhysicalDisplayIds() : SurfaceControl.getPhysicalDisplayIds();
            if (ids == null || ids.length == 0 || ids.length > MAX_PANELS) throw new Failure("panel_topology_unknown");
            Set<String> values = new HashSet<>();
            for (long id : ids) if (!values.add(Long.toUnsignedString(id))) throw new Failure("panel_topology_unknown");
            return values;
        }
        private String activeID() throws Failure {
            DisplayInfo display = ServiceManager.getDisplayManager().getDisplayInfo(0);
            String unique = display == null ? null : display.getUniqueId();
            if (unique == null || !unique.startsWith("local:") || !validID(unique.substring(6))) throw new Failure("panel_posture_unknown");
            return unique.substring(6);
        }
        public Frame read() throws Exception {
            Set<String> physical = physicalIDs(); String active = activeID();
            Map<String, Boolean> states = parsePhysical(fixedDump());
            if (!physical.containsAll(states.keySet()) || !physical.equals(physicalIDs()) || !active.equals(activeID()))
                throw new Failure("panel_topology_changed");
            return new Frame(states, active, physical);
        }
        public boolean set(String id, boolean on) throws Exception {
            if (!physicalIDs().contains(id)) throw new Failure("panel_topology_changed");
            long value = Long.parseUnsignedLong(id);
            IBinder token = displayControl ? DisplayControl.getPhysicalDisplayToken(value) : SurfaceControl.getPhysicalDisplayToken(value);
            if (token == null) throw new Failure("panel_token_unavailable");
            return SurfaceControl.setDisplayPowerMode(token, on ? SurfaceControl.POWER_MODE_NORMAL : SurfaceControl.POWER_MODE_OFF);
        }
    }
    public static void main(String[] args) {
        Controller owner = null; int result = 1; int pid = 0; String startTime = "";
        try {
            if (args.length != 0 || android.os.Process.myUid() != 2000) throw new Failure("panel_shell_required");
            String self = new String(readBounded(new File("/proc/self/stat"), 4096), StandardCharsets.UTF_8);
            String[] stat = self.substring(self.lastIndexOf(')') + 1).trim().split("\\s+");
            if (stat.length < 20) throw new Failure("panel_identity_unknown");
            pid = android.os.Process.myPid(); startTime = stat[19];
            try { Os.setsid(); } catch (android.system.ErrnoException failure) {
                if (Integer.parseInt(stat[3]) != android.os.Process.myPid()) throw failure;
            }
            Ln.initLogLevel(Ln.Level.ERROR);
            if (Looper.myLooper() == null) Looper.prepare(); Workarounds.apply();
            owner = new Controller(new RuntimeBackend()); final Controller snapshotOwner = owner;
            Runtime.getRuntime().addShutdownHook(new Thread(() -> { try { snapshotOwner.restore(); } catch (Exception ignored) {} }, "gb-panel-restore"));
            if (serve(System.in, new FileOutputStream(FileDescriptor.out), owner, android.os.Process.myPid(), stat[19])) result = 0;
        } catch (Throwable failure) {
            if (owner == null && pid > 0 && startTime.matches("[1-9][0-9]{0,19}")) try {
                reply(new FileOutputStream(FileDescriptor.out), owner, pid, startTime, false,
                    failure instanceof Failure ? ((Failure) failure).code : "panel_controller_unavailable");
            } catch (IOException ignored) {}
            System.err.println("panel_controller_unavailable");
        }
        finally { if (owner != null) try { owner.restore(); } catch (Exception ignored) { result = 1; } }
        System.exit(result);
    }
}
