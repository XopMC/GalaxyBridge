package com.genymobile.scrcpy;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.TimeUnit;

/** Actual controller engine/lifetime on a synthetic physical backend; never invokes Android. */
public final class DisplayPowerControllerTest {
    static final class Backend implements DisplayPowerController.Backend {
        final Map<String, Boolean> states = new LinkedHashMap<>();
        final List<String> writes = new ArrayList<>();
        final Set<String> additionalPhysical = new HashSet<>();
        String active = "20";
        int failAfterWrite = -1;
        Path file;
        Backend() { states.put("10", false); states.put("20", true); }
        public DisplayPowerController.Frame read() throws Exception {
            Set<String> topology = new HashSet<>(states.keySet()); topology.addAll(additionalPhysical);
            return new DisplayPowerController.Frame(states, active, topology);
        }
        public boolean set(String id, boolean on) throws Exception {
            writes.add(id + ":" + on); states.put(id, on); persist();
            if (writes.size() == failAfterWrite) throw new IOException("injected_partial_write");
            return true;
        }
        void persist() throws IOException { if (file != null) Files.write(file, (states.get("10") + "," + states.get("20")).getBytes(StandardCharsets.UTF_8)); }
    }
    static void reject(Throwing action) throws Exception {
        try { action.run(); throw new AssertionError("unsafe physical snapshot accepted"); }
        catch (DisplayPowerController.Failure expected) {}
    }
    interface Throwing { void run() throws Exception; }
    static String boundedLine(BufferedReader reader) throws Exception {
        java.util.concurrent.FutureTask<String> task = new java.util.concurrent.FutureTask<>(reader::readLine);
        Thread worker = new Thread(task, "panel-test-read"); worker.setDaemon(true); worker.start();
        try { return task.get(3, TimeUnit.SECONDS); } finally { task.cancel(true); }
    }
    static String dump(String one, String two) {
        return "Display 10 (HWC display 0): name=private\nDisplay 20 color modes:\n"
            + "Display 10\n connectionType=Internal\n powerMode=" + one + "\n"
            + "Display 20\n connectionType=Internal\n powerMode=" + two + "\n"
            + "Virtual Display 900\n powerMode=ON\nDisplay 10 (physical, private)\n";
    }
    public static void main(String[] args) throws Exception {
        if (args.length == 1 && args[0].equals("wire")) {
            DisplayPowerController.serve(new ByteArrayInputStream(new byte[] {0, 1, 3, 2}), System.out,
                new DisplayPowerController.Controller(new Backend()), 123, "456"); return;
        }
        if (args.length == 2 && (args[0].equals("child") || args[0].equals("signal"))) {
            Backend backend = new Backend(); backend.file = Paths.get(args[1]); backend.persist();
            DisplayPowerController.Controller controller = new DisplayPowerController.Controller(backend);
            Runtime.getRuntime().addShutdownHook(new Thread(() -> { try { controller.restore(); } catch (Exception ignored) {} }));
            if (args[0].equals("signal")) {
                controller.power(false); System.out.println("ready"); System.out.flush(); Thread.sleep(30000); return;
            }
            DisplayPowerController.serve(System.in, System.out, controller, 123, "456"); return;
        }
        if (args.length == 2 && args[0].equals("parent")) {
            String java = System.getProperty("java.home") + "/bin/java";
            Process child = new ProcessBuilder(java, "-ea", "-cp", System.getProperty("java.class.path"),
                DisplayPowerControllerTest.class.getName(), "child", args[1]).start();
            BufferedReader output = new BufferedReader(new InputStreamReader(child.getInputStream(), StandardCharsets.UTF_8));
            assert boundedLine(output).contains("\"ok\":true");
            child.getOutputStream().write(0); child.getOutputStream().flush();
            assert boundedLine(output).contains("\"ok\":true");
            System.out.println("ready"); System.out.flush(); Thread.sleep(30000); return;
        }
        Map<String, Boolean> physical = DisplayPowerController.parsePhysical(dump("OFF", "ON"));
        assert physical.size() == 2 && !physical.get("10") && physical.get("20") : "mixed physical states must remain exact";
        assert !physical.containsKey("900");
        assert DisplayPowerController.parsePhysical(dump("Off", "On")).equals(physical) : "known SurfaceFlinger power enums also use title case";
        reject(() -> DisplayPowerController.parsePhysical(dump("DOZE", "ON")));
        reject(() -> DisplayPowerController.parsePhysical(dump("OFF", "UNKNOWN")));
        reject(() -> DisplayPowerController.parsePhysical(dump("OFF", "ON") + "Display 20\n connectionType=Internal\n powerMode=OFF\n"));
        reject(() -> DisplayPowerController.parsePhysical("Virtual Display 20\n powerMode=ON\n"));
        reject(() -> DisplayPowerController.parsePhysical(new String(new char[DisplayPowerController.MAX_DUMP_BYTES + 1]).replace('\0', 'x')));
        reject(() -> new DisplayPowerController.Frame(physical, "900"));
        Map<String, Boolean> tooMany = new LinkedHashMap<>(); for (int n = 0; n < 9; ++n) tooMany.put("" + n, true);
        reject(() -> new DisplayPowerController.Frame(tooMany, "0"));
        assert DisplayPowerController.validID("18446744073709551615");
        for (String invalid : Arrays.asList("-1", "01", "18446744073709551616", "", "10\n20")) assert !DisplayPowerController.validID(invalid);
        Backend backend = new Backend(); DisplayPowerController.Controller owner = new DisplayPowerController.Controller(backend);
        owner.power(false); assert !backend.states.get("10") && !backend.states.get("20");
        owner.power(true); assert !backend.states.get("10") && backend.states.get("20");
        owner.power(false); owner.restore(); owner.restore();
        assert !backend.states.get("10") && backend.states.get("20") : "restore must not turn every Fold panel on";
        assert !backend.writes.contains("10:true");
        Backend allOff = new Backend(); allOff.states.put("20", false);
        DisplayPowerController.Controller initiallyOff = new DisplayPowerController.Controller(allOff);
        initiallyOff.power(true); initiallyOff.restore(); assert !allOff.states.get("10") && !allOff.states.get("20");
        Backend partial = new Backend(); partial.states.put("10", true); partial.failAfterWrite = 2;
        DisplayPowerController.Controller interrupted = new DisplayPowerController.Controller(partial);
        reject(() -> interrupted.power(false)); interrupted.restore();
        assert partial.states.get("10") && partial.states.get("20") : "a write that applied then threw still requires exact rollback";
        Backend changed = new Backend(); DisplayPowerController.Controller posture = new DisplayPowerController.Controller(changed);
        posture.power(false); changed.active = "10"; posture.power(true);
        assert changed.states.get("10") && !changed.states.get("20") : "ON follows the current posture";
        reject(posture::restore); assert !changed.writes.contains("20:true") : "restoration cannot wake the old inactive panel";
        Backend topology = new Backend(); DisplayPowerController.Controller fenced = new DisplayPowerController.Controller(topology);
        topology.states.put("30", false); reject(() -> fenced.power(true)); assert topology.writes.isEmpty();
        Backend external = new Backend(); DisplayPowerController.Controller topologyOwner = new DisplayPowerController.Controller(external);
        external.additionalPhysical.add("30"); reject(() -> topologyOwner.power(false)); assert external.writes.isEmpty();
        Backend eof = new Backend(); ByteArrayOutputStream wire = new ByteArrayOutputStream();
        assert DisplayPowerController.serve(new ByteArrayInputStream(new byte[] {0}), wire,
            new DisplayPowerController.Controller(eof), 123, "456");
        assert !eof.states.get("10") && eof.states.get("20");
        String json = wire.toString("UTF-8"); assert json.contains("\"initial\":[{\"id\":\"10\",\"on\":false}") && json.split("\n").length == 2;
        Backend badInput = new Backend(); assert !DisplayPowerController.serve(new ByteArrayInputStream(new byte[] {0, 99}),
            new ByteArrayOutputStream(), new DisplayPowerController.Controller(badInput), 123, "456");
        assert badInput.states.get("20");
        Backend brokenOutput = new Backend(); final int headerLength = json.indexOf('\n') + 1;
        OutputStream broken = new OutputStream() { int count; public void write(int value) throws IOException { if (++count > headerLength) throw new IOException("pipe_closed"); } };
        try { DisplayPowerController.serve(new ByteArrayInputStream(new byte[] {0}), broken,
            new DisplayPowerController.Controller(brokenOutput), 123, "456"); throw new AssertionError(); } catch (IOException expected) {}
        assert brokenOutput.states.get("20") : "lost acknowledgement output still restores the child-owned snapshot";
        testIndependentEOF();
        testShutdownHook();
        for (String path : args) {
            Map<String, Boolean> captured = DisplayPowerController.parsePhysical(new String(Files.readAllBytes(Paths.get(path)), StandardCharsets.UTF_8));
            assert !captured.isEmpty() && captured.size() <= 8;
        }
        System.out.println("PASS actual physical power engine: mixed exact restore, active-only ON, partial writes, EOF/output failure, bounds, unknown states, topology/posture fences, independent parent SIGKILL");
    }
    static void testIndependentEOF() throws Exception {
        Path directory = Files.createTempDirectory("gb-panel-owner-"); Path state = directory.resolve("state");
        Process parent = new ProcessBuilder(System.getProperty("java.home") + "/bin/java", "-ea", "-cp", System.getProperty("java.class.path"),
            DisplayPowerControllerTest.class.getName(), "parent", state.toString()).start();
        try {
            assert "ready".equals(boundedLine(new BufferedReader(new InputStreamReader(parent.getInputStream(), StandardCharsets.UTF_8))));
            assert new String(Files.readAllBytes(state), StandardCharsets.UTF_8).equals("false,false");
            parent.destroyForcibly(); assert parent.waitFor(3, TimeUnit.SECONDS);
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3);
            while (!new String(Files.readAllBytes(state), StandardCharsets.UTF_8).equals("false,true") && System.nanoTime() < deadline) Thread.sleep(10);
            assert new String(Files.readAllBytes(state), StandardCharsets.UTF_8).equals("false,true");
        } finally { parent.destroyForcibly(); Files.deleteIfExists(state); Files.deleteIfExists(directory); }
    }
    static void testShutdownHook() throws Exception {
        Path directory = Files.createTempDirectory("gb-panel-signal-"); Path state = directory.resolve("state");
        Process child = new ProcessBuilder(System.getProperty("java.home") + "/bin/java", "-ea", "-cp", System.getProperty("java.class.path"),
            DisplayPowerControllerTest.class.getName(), "signal", state.toString()).start();
        try {
            assert "ready".equals(boundedLine(new BufferedReader(new InputStreamReader(child.getInputStream(), StandardCharsets.UTF_8))));
            assert new String(Files.readAllBytes(state), StandardCharsets.UTF_8).equals("false,false");
            child.destroy(); assert child.waitFor(3, TimeUnit.SECONDS);
            assert new String(Files.readAllBytes(state), StandardCharsets.UTF_8).equals("false,true");
        } finally { child.destroyForcibly(); Files.deleteIfExists(state); Files.deleteIfExists(directory); }
    }
}
