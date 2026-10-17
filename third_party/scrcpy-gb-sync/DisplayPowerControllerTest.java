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
        testStalledOwnerRestoration();
        testFocusedPhysicalProbe();
        testIndependentEOF();
        testShutdownHook();
        for (String path : args) {
            Map<String, Boolean> captured = DisplayPowerController.parsePhysical(new String(Files.readAllBytes(Paths.get(path)), StandardCharsets.UTF_8));
            assert !captured.isEmpty() && captured.size() <= 8;
        }
        System.out.println("PASS actual physical power engine: mixed exact restore, active-only ON, partial writes, EOF/output failure, bounds, unknown states, topology/posture fences, independent parent SIGKILL");
    }
    static void testStalledOwnerRestoration() throws Exception {
        java.lang.reflect.Method serve;
        try { serve=DisplayPowerController.class.getDeclaredMethod("serveWithOwnerLease",InputStream.class,OutputStream.class,
            DisplayPowerController.Controller.class,int.class,String.class,long.class,long.class,java.util.function.IntConsumer.class); }
        catch (NoSuchMethodException missing) { throw new AssertionError("stalled raw panel owner has no independent restoration deadline",missing); }
        serve.setAccessible(true);
        Backend backend=new Backend(); DisplayPowerController.Controller owner=new DisplayPowerController.Controller(backend);
        PipedInputStream input=new PipedInputStream(); PipedOutputStream commands=new PipedOutputStream(input);
        java.util.concurrent.CountDownLatch expired=new java.util.concurrent.CountDownLatch(1);
        java.util.concurrent.atomic.AtomicInteger status=new java.util.concurrent.atomic.AtomicInteger(-1);
        Thread worker=new Thread(() -> { try {
            serve.invoke(null,input,new ByteArrayOutputStream(),owner,123,"456",1000L,5L,
                (java.util.function.IntConsumer)(code -> { status.set(code); expired.countDown(); }));
        } catch (Exception error) { throw new AssertionError(error); } });
        worker.setDaemon(true); worker.start();
        commands.write(0); commands.flush();
        // Existing one-second status requests renew the lease without extra
        // power changes or a second writer on the acknowledgement stream.
        for(int i=0;i<8;i++) { commands.write(3); commands.flush(); Thread.sleep(150); assert expired.getCount()==1; }
        assert expired.await(2000,TimeUnit.MILLISECONDS) : "open but stalled owner did not expire";
        assert status.get()==0 && !backend.states.get("10") && backend.states.get("20") : "deadline must restore the exact mixed snapshot before reporting retirement";
        commands.close(); worker.join(1000); assert !worker.isAlive(); input.close();
        assert backend.writes.equals(Arrays.asList("20:false", "20:true")) : "status renewal must not toggle a physical panel";
        Backend uncertain = new Backend(); uncertain.failAfterWrite = 2;
        DisplayPowerController.Controller failedOwner = new DisplayPowerController.Controller(uncertain);
        PipedInputStream failedInput = new PipedInputStream(); PipedOutputStream failedCommands = new PipedOutputStream(failedInput);
        java.util.concurrent.CountDownLatch failedExpiry = new java.util.concurrent.CountDownLatch(1);
        java.util.concurrent.atomic.AtomicInteger failedStatus = new java.util.concurrent.atomic.AtomicInteger(-1);
        Thread failedWorker = new Thread(() -> { try {
            serve.invoke(null, failedInput, new ByteArrayOutputStream(), failedOwner, 124, "457", 1000L, 5L,
                (java.util.function.IntConsumer)(code -> { failedStatus.set(code); failedExpiry.countDown(); }));
        } catch (Exception error) { throw new AssertionError(error); } });
        failedWorker.setDaemon(true); failedWorker.start(); failedCommands.write(0); failedCommands.flush();
        assert failedExpiry.await(2000, TimeUnit.MILLISECONDS) && failedStatus.get() == 1 : "failed restoration must never report clean retirement";
        failedCommands.close(); failedWorker.join(1000); assert !failedWorker.isAlive(); failedInput.close();
        java.util.concurrent.atomic.AtomicInteger normalExpiry = new java.util.concurrent.atomic.AtomicInteger();
        Backend normal = new Backend();
        assert (Boolean)serve.invoke(null, new ByteArrayInputStream(new byte[] {0, 2}), new ByteArrayOutputStream(),
            new DisplayPowerController.Controller(normal), 125, "458", 80L, 5L,
            (java.util.function.IntConsumer)(code -> normalExpiry.incrementAndGet()));
        Thread.sleep(160);
        assert normalExpiry.get() == 0 : "normal restored completion must cancel the independent deadline";
        System.out.println("PASS stalled raw owner restores exact physical snapshot; renewal adds no writes; restoration failure stays unsuccessful; normal exit cancels deadline");
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
    static void testFocusedPhysicalProbe() throws Exception {
        Class<?> sourceType, probeType;
        try {sourceType=Class.forName("com.genymobile.scrcpy.DisplayPowerController$DumpSource");probeType=Class.forName("com.genymobile.scrcpy.DisplayPowerController$PhysicalStateProbe");}
        catch(ClassNotFoundException missing){throw new AssertionError("physical monitor still requires a full layer dump",missing);}
        java.lang.reflect.Constructor<?> constructor=probeType.getDeclaredConstructor(sourceType);constructor.setAccessible(true);
        java.lang.reflect.Method read=probeType.getDeclaredMethod("read",Set.class);read.setAccessible(true);
        Set<String> topology=new HashSet<>(java.util.Arrays.asList("10","20"));
        final int[] focused={0}, full={0};
        Object goodSource=java.lang.reflect.Proxy.newProxyInstance(sourceType.getClassLoader(),new Class<?>[]{sourceType},(proxy,method,args)->{
            if((Boolean)args[0])focused[0]++;else full[0]++;return dump("OFF","ON");});
        Object probe=constructor.newInstance(goodSource);
        Map<?,?> observed=(Map<?,?>)read.invoke(probe,topology);
        assert observed.equals(DisplayPowerController.parsePhysical(dump("OFF","ON"))) && focused[0]==1 && full[0]==0 : "complete display-only state must avoid full layer traversal";
        final int[] attempts={0};
        Object fallbackSource=java.lang.reflect.Proxy.newProxyInstance(sourceType.getClassLoader(),new Class<?>[]{sourceType},(proxy,method,args)->{
            attempts[0]++;return (Boolean)args[0] ? "unsupported --displays" : dump("OFF","ON");});
        Object fallback=constructor.newInstance(fallbackSource);
        read.invoke(fallback,topology);read.invoke(fallback,topology);
        assert attempts[0]==3 : "unsupported filtered dump must be probed once, then full fallback cached";
        Object partialSource=java.lang.reflect.Proxy.newProxyInstance(sourceType.getClassLoader(),new Class<?>[]{sourceType},(proxy,method,args)->
            (Boolean)args[0] ? "Display 10\n connectionType=Internal\n powerMode=OFF\n" : dump("OFF","ON"));
        Map<?,?> mixed=(Map<?,?>)read.invoke(constructor.newInstance(partialSource),topology);
        assert mixed.size()==2 && Boolean.TRUE.equals(mixed.get("20")) : "focused probe must not omit an inactive fold panel";
        System.out.println("PASS focused physical-state probe with exact topology and cached full-dump fallback; no power action or polling delay changed");
    }

}
