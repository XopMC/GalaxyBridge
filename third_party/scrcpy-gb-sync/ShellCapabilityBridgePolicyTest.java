package com.genymobile.scrcpy;

import java.util.HashMap;
import java.util.Map;

/** Host execution of the actual server's typed policy; no Android APIs invoked. */
public final class ShellCapabilityBridgePolicyTest {
    private static void testCompositeRetirementStore() {
        String lease = "69830b65-6352-4b3a-8a21-70bcda45787e";
        ShellCapabilityBridge.CompositeRetirementStore store = new ShellCapabilityBridge.CompositeRetirementStore();
        assert store.get(lease) == null;
        store.remember(lease, "exact validated typed terminal and absence receipt");
        store.remember(lease, "exact validated typed terminal and absence receipt");
        reject(() -> store.remember(lease, "stopped"));
        assert store.get(lease).equals("exact validated typed terminal and absence receipt");
        assert store.get("181892ff-7429-4d94-95b6-f425e01f4b06") == null;
    }
    private static void testCompositeProofInitializationQuarantine() throws Exception {
        java.util.concurrent.CountDownLatch entered = new java.util.concurrent.CountDownLatch(1), release = new java.util.concurrent.CountDownLatch(1);
        java.util.concurrent.atomic.AtomicInteger created = new java.util.concurrent.atomic.AtomicInteger();
        ShellCapabilityBridge.CompositeRetirementProbe probe = new ShellCapabilityBridge.CompositeRetirementProbe(() -> {
            created.incrementAndGet(); entered.countDown(); release.await();
            return new DisplayStateRuntimeBackend(new DisplayStateRuntimeBackendTest.Platform());
        }, 25);
        java.util.concurrent.FutureTask<Exception> caller = new java.util.concurrent.FutureTask<>(() -> {
            try { probe.read(); return null; } catch (Exception expected) { return expected; }
        });
        Thread thread = new Thread(caller, "test-proof-initialization-caller"); thread.setDaemon(true); thread.start();
        try {
            assert entered.await(1, java.util.concurrent.TimeUnit.SECONDS);
            Exception timeout;
            try { timeout = caller.get(500, java.util.concurrent.TimeUnit.MILLISECONDS); }
            catch (java.util.concurrent.TimeoutException hung) { throw new AssertionError("proof initialization held the broker monitor indefinitely", hung); }
            assert timeout instanceof java.io.IOException;
            for (int i = 0; i < 2; ++i) {
                try { probe.read(); throw new AssertionError("unsettled initialization admitted"); } catch (java.io.IOException expected) {}
            }
            assert created.get() == 1 : "timed-out initialization must not spawn replacements";
        } finally { release.countDown(); }
        DisplayStateSnapshot observed = null;
        for (int i = 0; i < 100 && observed == null; ++i) {
            try { observed = probe.read(); } catch (java.io.IOException pending) { Thread.sleep(5); }
        }
        assert observed != null && created.get() == 1 : "settled late initialization must be reused for a fresh observation";
        System.out.println("PASS bounded proof initialization: one retained task, no cancellation/relaunch, late completion followed by fresh snapshot");
    }
    private static void testCompositeProofReaderQuarantine() throws Exception {
        java.util.concurrent.CountDownLatch entered = new java.util.concurrent.CountDownLatch(1), release = new java.util.concurrent.CountDownLatch(1);
        java.util.concurrent.atomic.AtomicInteger created = new java.util.concurrent.atomic.AtomicInteger(), calls = new java.util.concurrent.atomic.AtomicInteger();
        ShellCapabilityBridge.CompositeRetirementProbe probe = new ShellCapabilityBridge.CompositeRetirementProbe(() -> {
            created.incrementAndGet();
            return new DisplayStateRuntimeBackend(new DisplayStateRuntimeBackendTest.Platform() {
                public boolean defaultInteractive() {
                    calls.incrementAndGet(); entered.countDown();
                    try { release.await(); } catch (InterruptedException failure) { throw new AssertionError(failure); }
                    return false;
                }
            }, 25);
        });
        try {
            for (int i = 0; i < 3; ++i) {
                try { probe.read(); throw new AssertionError("blocked proof reader admitted"); } catch (java.io.IOException expected) {}
            }
            assert entered.await(1, java.util.concurrent.TimeUnit.SECONDS);
            assert created.get() == 1 && calls.get() == 1 : "proof retry bypassed the pending-read quarantine";
        } finally { release.countDown(); }
        DisplayStateSnapshot observed = null;
        for (int i = 0; i < 100 && observed == null; ++i) {
            try { observed = probe.read(); } catch (java.io.IOException pending) { Thread.sleep(5); }
        }
        assert observed != null && created.get() == 1 : "proof retry must reuse the settled backend and discard its late result";
        System.out.println("PASS composite retirement proof retries retain one actual bounded backend and quarantine a pending Binder read");
    }
    private static Map<String, Object> compositeSnapshot() {
        Map<String, Object> value = new HashMap<>();
        Map<String, Object> panel = new HashMap<>(); panel.put("id", "20"); panel.put("mode", "DOZE");
        value.put("panels", java.util.Collections.singletonList(panel)); value.put("activeID", "20");
        value.put("defaultInteractive", false); value.put("defaultWakefulness", "DOZING");
        value.put("globalWakefulness", "DOZING"); value.put("transitionScope", "GLOBAL");
        for (String key : new String[]{"lastGlobalWakeTime", "lastGlobalSleepTime", "defaultActivityTime", "defaultActivityNoChangeLightsTime"}) value.put(key, "100");
        return value;
    }
    private static Map<String, Object> compositeFrame() {
        Map<String, Object> value = new HashMap<>();
        value.put("version", 2); value.put("event", "ready"); value.put("pid", 123); value.put("startTime", "456");
        value.put("revision", 0L); value.put("state", "SNAPSHOTTED"); value.put("draining", false);
        value.put("mutation_settled", true); value.put("initial", compositeSnapshot()); value.put("current", compositeSnapshot());
        value.put("ok", true); value.put("error", ""); value.put("reason", "startup"); return value;
    }
    private static void testCompositeReceipts() {
        ShellCapabilityBridge.CompositeReceipt header = ShellCapabilityBridge.CompositeReceipt.parse(compositeFrame()); header.header();
        for (String key : compositeFrame().keySet()) {
            Map<String, Object> missing = compositeFrame(); missing.remove(key);
            reject(() -> ShellCapabilityBridge.CompositeReceipt.parse(missing));
        }
        for (Object invalid : new Object[]{true, 2.0, "2", -1, 1, 3}) {
            Map<String, Object> value = compositeFrame(); value.put("version", invalid);
            reject(() -> ShellCapabilityBridge.CompositeReceipt.parse(value));
        }
        for (Object invalid : new Object[]{"0456", "0", "-1", "9223372036854775808", 456}) {
            Map<String, Object> value = compositeFrame(); value.put("startTime", invalid);
            reject(() -> ShellCapabilityBridge.CompositeReceipt.parse(value));
        }
        Map<String, Object> extra = compositeFrame(); extra.put("legacy_on", true);
        reject(() -> ShellCapabilityBridge.CompositeReceipt.parse(extra));
        Map<String, Object> nonBoolean = compositeFrame(); nonBoolean.put("mutation_settled", 1);
        reject(() -> ShellCapabilityBridge.CompositeReceipt.parse(nonBoolean));
        Map<String, Object> wrongReason = compositeFrame(); wrongReason.put("reason", "command");
        reject(() -> ShellCapabilityBridge.CompositeReceipt.parse(wrongReason).header());
        Map<String, Object> missingError = compositeFrame(); missingError.put("event", "reply"); missingError.put("ok", false);
        reject(() -> ShellCapabilityBridge.CompositeReceipt.parse(missingError));
        Map<String, Object> unknownGroup = compositeFrame(), snapshot = compositeSnapshot(); snapshot.put("defaultWakefulness", null);
        unknownGroup.put("initial", snapshot); reject(() -> ShellCapabilityBridge.CompositeReceipt.parse(unknownGroup));
        Map<String, Object> duplicatePanels = compositeFrame(), panels = compositeSnapshot();
        Object panel = ((java.util.List<?>)panels.get("panels")).get(0); panels.put("panels", java.util.Arrays.asList(panel, panel));
        duplicatePanels.put("current", panels); reject(() -> ShellCapabilityBridge.CompositeReceipt.parse(duplicatePanels));
        Map<String, Object> command = new HashMap<>(); command.put("action", 2); command.put("interactive", true);
        command.put("panel_policy", 1); command.put("revision", 7L);
        ShellCapabilityBridge.CompositeCommand hide = ShellCapabilityBridge.CompositeCommand.parse(command);
        Map<String, Object> ready = compositeFrame(), awake = compositeSnapshot();
        awake.put("defaultInteractive", true); awake.put("defaultWakefulness", "AWAKE"); awake.put("globalWakefulness", "AWAKE");
        Map<String, Object> off = new HashMap<>(); off.put("id", "20"); off.put("mode", "OFF"); awake.put("panels", java.util.Collections.singletonList(off));
        ready.put("event", "reply"); ready.put("state", "READY"); ready.put("revision", 7L); ready.put("current", awake);
        ShellCapabilityBridge.CompositeReceipt.parse(ready).policy(header, hide);
        Map<String, Object> wrongPID = new HashMap<>(ready); wrongPID.put("pid", 124);
        reject(() -> ShellCapabilityBridge.CompositeReceipt.parse(wrongPID).policy(header, hide));
        Map<String, Object> rebase = new HashMap<>(ready), changed = compositeSnapshot(); changed.put("lastGlobalWakeTime", "101"); rebase.put("initial", changed);
        reject(() -> ShellCapabilityBridge.CompositeReceipt.parse(rebase).policy(header, hide));
        Map<String, Object> stale = new HashMap<>(ready); stale.put("revision", 6L);
        reject(() -> ShellCapabilityBridge.CompositeReceipt.parse(stale).policy(header, hide));
        Map<String, Object> notInteractive = new HashMap<>(ready); notInteractive.put("current", compositeSnapshot());
        reject(() -> ShellCapabilityBridge.CompositeReceipt.parse(notInteractive).policy(header, hide));
        Map<String, Object> terminal = compositeFrame(), restored = compositeSnapshot();
        terminal.put("event", "retired"); terminal.put("state", "RESTORED"); terminal.put("draining", true);
        restored.put("lastGlobalWakeTime", "200"); restored.put("globalWakefulness", "AWAKE"); terminal.put("current", restored);
        ShellCapabilityBridge.CompositeReceipt.parse(terminal).terminal(header, 0, 7);
        reject(() -> ShellCapabilityBridge.CompositeReceipt.parse(terminal).terminal(header, 7, 7));
        Map<String, Object> falseRestoration = new HashMap<>(terminal); falseRestoration.put("current", awake);
        reject(() -> ShellCapabilityBridge.CompositeReceipt.parse(falseRestoration));
        for (String disposition : new String[]{"YIELDED_ACTIVITY", "YIELDED_EXTERNAL"}) {
            Map<String, Object> yielded = new HashMap<>(falseRestoration); yielded.put("state", disposition);
            ShellCapabilityBridge.CompositeReceipt.parse(yielded).terminal(header, 0, 7);
        }
        Map<String, Object> pending = new HashMap<>(terminal); pending.put("mutation_settled", false);
        reject(() -> ShellCapabilityBridge.CompositeReceipt.parse(pending).terminal(header, 0, 7));
        Map<String, Object> startupFailed = compositeFrame(); startupFailed.put("event", "startup_failed"); startupFailed.put("state", "NOT_STARTED");
        startupFailed.put("ok", false); startupFailed.put("draining", true); startupFailed.put("initial", null); startupFailed.put("current", null);
        startupFailed.put("error", "display_default_wakefulness_unknown");
        reject(() -> ShellCapabilityBridge.CompositeReceipt.parse(startupFailed).header());
        startupFailed.put("reason", "command"); reject(() -> ShellCapabilityBridge.CompositeReceipt.parse(startupFailed));
        System.out.println("PASS v2 broker receipts: strict native fields, immutable initial identity, exact policy correlation and typed conditional retirement");
    }
    private static Map<String, Object> options() {
        Map<String, Object> value = new HashMap<>();
        value.put("scid", 123); value.put("display_id", 0); value.put("package_name", "com.example.notes");
        value.put("max_size", 1920); value.put("max_fps", 60); value.put("video_bit_rate", 6000000L);
        value.put("codec", "h264"); value.put("width", 1920); value.put("height", 1080);
        value.put("audio", true); value.put("control", true); return value;
    }
    private static void reject(Runnable operation) {
        try { operation.run(); throw new AssertionError("invalid policy admitted"); }
        catch (IllegalArgumentException expected) {}
    }
    public static void main(String[] args) throws Exception {
        if (args.length == 2 && args[0].equals("child")) {
            java.nio.file.Path path = java.nio.file.Paths.get(args[1]);
            java.nio.file.Files.write(path, "off".getBytes(java.nio.charset.StandardCharsets.UTF_8));
            System.out.println("ready"); System.out.flush();
            ShellCapabilityBridge.panelLifetime(System.in, true, on -> {
                java.nio.file.Files.write(path, (on ? "on" : "off").getBytes(java.nio.charset.StandardCharsets.UTF_8)); return true;
            });
            return;
        }
        if (args.length == 2 && args[0].equals("parent")) {
            String javaProgram = System.getProperty("java.home") + "/bin/java";
            Process child = new ProcessBuilder(javaProgram, "-cp", System.getProperty("java.class.path"), ShellCapabilityBridgePolicyTest.class.getName(), "child", args[1]).start();
            java.io.BufferedReader childReceipt = new java.io.BufferedReader(new java.io.InputStreamReader(child.getInputStream()));
            long deadline = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(3);
            while (!childReceipt.ready() && child.isAlive() && System.nanoTime() < deadline) Thread.sleep(10);
            assert childReceipt.ready() && "ready".equals(childReceipt.readLine()) : "child did not finish writing its initial panel snapshot";
            System.out.println("ready"); System.out.flush(); Thread.sleep(30000); return;
        }
        String lease = "69830b65-6352-4b3a-8a21-70bcda45787e";
        testCompositeProofInitializationQuarantine();
        testCompositeProofReaderQuarantine();
        testCompositeRetirementStore();
        testCompositeReceipts();
        testCompositeCommands();
        testCompositeAdmission();
        ShellCapabilityBridge.Policy composite = ShellCapabilityBridge.Policy.parse(8, lease, new HashMap<String, Object>());
        assert composite.streams().isEmpty() && composite.serverArguments().length == 0
            : "display-state owner must never start media or expose a stream";
        assert composite.scid == 0 && !composite.control && !composite.audio;
        reject(() -> ShellCapabilityBridge.Policy.parse(8, lease, options()));
        Map<String, Object> disguised = new HashMap<>(); disguised.put("scid", 0);
        reject(() -> ShellCapabilityBridge.Policy.parse(8, lease, disguised));
        testVerifiedSourceCleanup();
        testPanelStatusReadinessIsolation();
        testRegistrationAgainstStop();
        ShellCapabilityBridge.BinderAdmission admission = new ShellCapabilityBridge.BinderAdmission(10234);
        admission.enforceCallingUID(10234);
        boolean rejectedCaller = false;
        try { admission.enforceCallingUID(2000); } catch (SecurityException expected) { rejectedCaller = true; }
        assert rejectedCaller : "non-Helper Binder caller was admitted before argument parsing";
        assert ShellCapabilityBridge.BINDER_DESCRIPTOR.equals("com.xopmc.galaxybridge.shellbridge.v1");
        assert ShellCapabilityBridge.OPEN_OWNER == 1 && ShellCapabilityBridge.OPEN_STREAM == 2;
        String secret = String.join("", java.util.Collections.nCopies(64, "a"));
        assert ShellCapabilityBridge.credentialsMatch(lease, secret, lease, secret);
        assert !ShellCapabilityBridge.credentialsMatch(lease, secret, "other", secret);
        assert !ShellCapabilityBridge.credentialsMatch(lease, secret, lease, secret + "a");
        assert !ShellCapabilityBridge.credentialsMatch(lease, secret, lease, null);
        assert !ShellCapabilityBridge.validStreamID(null);
        testSocketRetirement();
        testOrderedConnections();
        ShellCapabilityBridge.Policy valid = ShellCapabilityBridge.Policy.parse(1, lease, options());
        String[] argv = valid.serverArguments();
        String joined = String.join(" ", argv);
        assert joined.contains("video_bit_rate=6000000") && joined.contains("max_fps=60");
        assert java.util.Arrays.asList(argv).contains("video_codec_options=i-frame-interval=1,priority=0,latency=0,bitrate-mode=2")
                : "prepared AVC capture lost the wireless profile's realtime / zero-latency encoder hints";
        Map<String, Object> hevcOptions = options(); hevcOptions.put("codec", "h265");
        java.util.List<String> hevcArguments = java.util.Arrays.asList(ShellCapabilityBridge.Policy.parse(1, lease, hevcOptions).serverArguments());
        assert hevcArguments.contains("video_codec_options=i-frame-interval=1,priority=0,latency=0")
                : "HEVC needs the same interactive hints without AVC's CBR override";
        assert joined.contains("new_display=1920x1080/420") && joined.contains("cleanup=true");
        assert java.util.Arrays.asList(argv).contains("flex_display=true") && java.util.Arrays.asList(argv).contains("vd_system_decorations=false") : "typed app windows must resize without a competing launcher/taskbar";
        assert java.util.Arrays.asList(argv).contains("display_ime_policy=hide") && !joined.contains("hide_device_ime=");
        Map<String, Object> desktopOptions = options(); desktopOptions.put("package_name", "");
        java.util.List<String> desktopArguments = java.util.Arrays.asList(ShellCapabilityBridge.Policy.parse(1, lease, desktopOptions).serverArguments());
        assert desktopArguments.contains("vd_system_decorations=true") && !desktopArguments.contains("flex_display=true") : "a general virtual desktop retains its system controls";
        assert joined.contains("power_on=false") && joined.contains("clipboard_autosync=false");
        assert java.util.Arrays.asList(argv).contains("audio_codec=aac") : "shell capture must use the Mac decoder's AAC codec instead of scrcpy's Opus default";
        assert java.util.Arrays.asList(argv).contains("audio_bit_rate=128000");
        Map<String, Object> silentOptions = options(); silentOptions.put("audio", false);
        java.util.List<String> silentArguments = java.util.Arrays.asList(ShellCapabilityBridge.Policy.parse(1, lease, silentOptions).serverArguments());
        assert silentArguments.contains("audio=false") && !silentArguments.contains("audio_codec=aac");
        assert valid.streams().contains(lease + "/log") && valid.streams().size() == 4;
        assert !joined.contains("com.example.notes"); // package launch is the existing typed control message.
        Map<String, Object> injection = options(); injection.put("server_arguments", "anything");
        reject(() -> ShellCapabilityBridge.Policy.parse(1, lease, injection));
        Map<String, Object> badPackage = options(); badPackage.put("package_name", "a;echo unsafe");
        reject(() -> ShellCapabilityBridge.Policy.parse(1, lease, badPackage));
        Map<String, Object> tooLarge = options(); tooLarge.put("width", 100000);
        reject(() -> ShellCapabilityBridge.Policy.parse(1, lease, tooLarge));
        Map<String, Object> fractional = options(); fractional.put("scid", 1.5);
        reject(() -> ShellCapabilityBridge.Policy.parse(1, lease, fractional));
        reject(() -> ShellCapabilityBridge.Policy.parse(1, "../other", options()));
        reject(() -> ShellCapabilityBridge.Policy.parse(9, lease, options()));
        ShellCapabilityBridge.Policy clipboard = ShellCapabilityBridge.Policy.parse(2, lease, options());
        assert clipboard.streams().size() == 2 && clipboard.streams().contains(lease + "/clipboard");
        assert String.join(" ", clipboard.serverArguments()).contains("video=false");
        assert !String.join(" ", clipboard.serverArguments()).contains("video_codec_options=")
                : "capture-free clipboard must not configure a video encoder";
        assert java.util.Arrays.asList(clipboard.serverArguments()).contains("audio=false") && !java.util.Arrays.asList(clipboard.serverArguments()).contains("audio_codec=aac");
        assert !java.util.Arrays.asList(clipboard.serverArguments()).contains("display_ime_policy=hide") : "clipboard-only capture must leave the phone's IME policy unchanged";
        assert ShellCapabilityBridge.Policy.parse(3, lease, options()).streams().isEmpty();
        assert ShellCapabilityBridge.validStreamID(lease + "/control");
        assert !ShellCapabilityBridge.validStreamID(lease + "/../control");
        assert !ShellCapabilityBridge.validStreamID(lease + "/arbitrary");
        java.util.List<Boolean> writes = new java.util.ArrayList<>();
        ShellCapabilityBridge.panelLifetime(new java.io.ByteArrayInputStream(new byte[] {0, 1}), false, on -> { writes.add(on); return true; });
        assert writes.equals(java.util.Arrays.asList(false, true, false));
        java.nio.file.Path directory = java.nio.file.Files.createTempDirectory("gb-shell-lifetime-");
        java.nio.file.Path state = directory.resolve("panel");
        String javaCommand = System.getProperty("java.home") + "/bin/java";
        Process parent = new ProcessBuilder(javaCommand, "-cp", System.getProperty("java.class.path"), ShellCapabilityBridgePolicyTest.class.getName(), "parent", state.toString()).start();
        try {
            assert "ready".equals(new java.io.BufferedReader(new java.io.InputStreamReader(parent.getInputStream())).readLine());
            assert new String(java.nio.file.Files.readAllBytes(state), java.nio.charset.StandardCharsets.UTF_8).equals("off");
            parent.destroyForcibly(); assert parent.waitFor(3, java.util.concurrent.TimeUnit.SECONDS);
            long deadline = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(3);
            while (!new String(java.nio.file.Files.readAllBytes(state), java.nio.charset.StandardCharsets.UTF_8).equals("on") && System.nanoTime() < deadline) Thread.sleep(10);
            assert new String(java.nio.file.Files.readAllBytes(state), java.nio.charset.StandardCharsets.UTF_8).equals("on") : "parent SIGKILL did not restore child-owned panel snapshot";
        } finally { parent.destroyForcibly(); java.nio.file.Files.deleteIfExists(state); java.nio.file.Files.delete(directory); }
        System.out.println("PASS actual shell bridge typed options, fixed argv, stream allowlist, bounds and injection rejection");
        System.out.println("PASS actual panel lifetime loop restores initial OFF and real parent SIGKILL restores synthetic ON via owned stdin EOF");
    }

    private static void testPanelStatusReadinessIsolation() throws Exception {
        String unknown = ShellCapabilityBridge.readOnlyPanelStatus(() -> {
            return new DisplayPowerController.Frame(DisplayPowerController.parsePhysical(
                "Display 10\n connectionType=Internal\n powerMode=DOZE\n"), "10").state();
        });
        assert unknown.equals("panel_unknown") : "unsupported physical state must remain isolated from general broker readiness";
        assert ShellCapabilityBridge.readOnlyPanelStatus(() -> { throw new java.io.IOException("read_failed"); }).equals("panel_unknown");
        assert ShellCapabilityBridge.readOnlyPanelStatus(() -> { throw new AssertionError("hidden_API_unavailable"); }).equals("panel_unknown");
        assert ShellCapabilityBridge.readOnlyPanelStatus(() -> { throw new AbstractMethodError("hidden_API_unavailable"); }).equals("panel_unknown");
        for (String value : java.util.Arrays.asList("panel_on", "panel_off", "panel_multi_on", "panel_multi_off"))
            assert ShellCapabilityBridge.readOnlyPanelStatus(() -> value).equals(value);
        String lease = "69830b65-6352-4b3a-8a21-70bcda45787e";
        assert ShellCapabilityBridge.Policy.parse(1, lease, options()).streams().contains(lease + "/video");
        assert ShellCapabilityBridge.Policy.parse(2, lease, options()).streams().contains(lease + "/clipboard");
        System.out.println("PASS read-only panel probe failure isolation; known multi-panel states and clipboard/app start policies remain available");
    }

    private static void testOrderedConnections() throws Exception {
        ShellCapabilityBridge.StreamOrder gate = new ShellCapabilityBridge.StreamOrder(java.util.Arrays.asList("video", "audio", "control"));
        java.util.concurrent.CountDownLatch audioStarted = new java.util.concurrent.CountDownLatch(1);
        java.util.concurrent.CountDownLatch audioConnected = new java.util.concurrent.CountDownLatch(1);
        java.util.List<String> connected = java.util.Collections.synchronizedList(new java.util.ArrayList<>());
        java.util.concurrent.atomic.AtomicReference<Throwable> failure = new java.util.concurrent.atomic.AtomicReference<>();
        Thread audio = new Thread(() -> {
            audioStarted.countDown();
            try { gate.connect("audio", 1000, () -> { connected.add("audio"); audioConnected.countDown(); }); }
            catch (Throwable error) { failure.set(error); }
        });
        audio.start(); assert audioStarted.await(1, java.util.concurrent.TimeUnit.SECONDS);
        assert !audioConnected.await(100, java.util.concurrent.TimeUnit.MILLISECONDS) : "audio occupied scrcpy video accept slot before video connected";
        gate.connect("video", 1000, () -> connected.add("video"));
        assert audioConnected.await(1, java.util.concurrent.TimeUnit.SECONDS); audio.join(1000);
        gate.connect("control", 1000, () -> connected.add("control"));
        assert failure.get() == null && connected.equals(java.util.Arrays.asList("video", "audio", "control"));

        // Admission is insufficient: the predecessor's actual connect must
        // complete before the next connection can reach scrcpy's accept queue.
        ShellCapabilityBridge.StreamOrder inFlight = new ShellCapabilityBridge.StreamOrder(java.util.Arrays.asList("video", "control"));
        java.util.concurrent.CountDownLatch entered = new java.util.concurrent.CountDownLatch(1), finish = new java.util.concurrent.CountDownLatch(1);
        java.util.concurrent.CountDownLatch controlConnected = new java.util.concurrent.CountDownLatch(1);
        java.util.concurrent.CompletableFuture<Void> video = connectAsync(inFlight, "video", () -> {
            entered.countDown(); assert finish.await(1, java.util.concurrent.TimeUnit.SECONDS);
        });
        assert entered.await(1, java.util.concurrent.TimeUnit.SECONDS);
        java.util.concurrent.CompletableFuture<Void> control = connectAsync(inFlight, "control", controlConnected::countDown);
        assert !controlConnected.await(100, java.util.concurrent.TimeUnit.MILLISECONDS);
        finish.countDown(); video.get(1, java.util.concurrent.TimeUnit.SECONDS); control.get(1, java.util.concurrent.TimeUnit.SECONDS);

        ShellCapabilityBridge.StreamOrder retired = new ShellCapabilityBridge.StreamOrder(java.util.Arrays.asList("video", "control"));
        java.util.concurrent.CompletableFuture<Void> waiting = connectAsync(retired, "control", () -> { throw new AssertionError("retired stream connected"); });
        retired.stop(); expectConnectionFailure(waiting);
        ShellCapabilityBridge.StreamOrder failed = new ShellCapabilityBridge.StreamOrder(java.util.Arrays.asList("video", "control"));
        java.util.concurrent.CompletableFuture<Void> follower = connectAsync(failed, "control", () -> { throw new AssertionError("failed predecessor was skipped"); });
        try { failed.connect("video", 1000, () -> { throw new java.io.IOException("synthetic connect failure"); }); throw new AssertionError("failure swallowed"); }
        catch (java.io.IOException expected) {}
        expectConnectionFailure(follower);
        ShellCapabilityBridge.StreamOrder missing = new ShellCapabilityBridge.StreamOrder(java.util.Arrays.asList("video", "control"));
        try { missing.connect("control", 20, () -> { throw new AssertionError("missing video skipped"); }); throw new AssertionError("deadline ignored"); }
        catch (java.io.IOException expected) {}
        // No cross-lease serialization and no audio-disabled phantom slot.
        ShellCapabilityBridge.StreamOrder silent = new ShellCapabilityBridge.StreamOrder(java.util.Arrays.asList("video", "control"));
        silent.connect("video", 1000, () -> {}); silent.connect("control", 1000, () -> {});
        ShellCapabilityBridge.StreamOrder clipboard = new ShellCapabilityBridge.StreamOrder(java.util.Collections.singletonList("control"));
        clipboard.connect("control", 1000, () -> {});
        System.out.println("PASS actual per-lease scrcpy connect ordering, in-flight completion, stop/failure wakeup, missing-predecessor deadline and optional audio");
    }
    private static void testRegistrationAgainstStop() throws Exception {
        // Exercise both classes of candidate through the production registry:
        // an adopted Binder channel and a freshly allocated child socket.
        for (String kind : java.util.Arrays.asList("binder", "child")) {
            java.util.Set<java.io.Closeable> sockets = java.util.Collections.synchronizedSet(new java.util.HashSet<>());
            java.util.concurrent.atomic.AtomicBoolean stopped = new java.util.concurrent.atomic.AtomicBoolean(false);
            java.util.concurrent.atomic.AtomicInteger closes = new java.util.concurrent.atomic.AtomicInteger();
            java.io.Closeable candidate = closes::incrementAndGet;
            java.util.concurrent.CountDownLatch checked = new java.util.concurrent.CountDownLatch(1), proceed = new java.util.concurrent.CountDownLatch(1);
            java.util.concurrent.atomic.AtomicReference<Throwable> failure = new java.util.concurrent.atomic.AtomicReference<>();
            Thread registration = new Thread(() -> {
                try {
                    assert !stopped.get(); checked.countDown();
                    assert proceed.await(1, java.util.concurrent.TimeUnit.SECONDS);
                    ShellCapabilityBridge.registerOwnedSocket(sockets, stopped, candidate);
                } catch (Throwable error) { failure.set(error); }
            });
            registration.setDaemon(true); registration.start();
            try {
                assert checked.await(1, java.util.concurrent.TimeUnit.SECONDS);
                stopped.set(true); ShellCapabilityBridge.retireOwnedSockets(sockets);
            } finally { proceed.countDown(); registration.join(1000); }
            assert failure.get() instanceof java.io.IOException && closes.get() == 1 && sockets.isEmpty() : kind + " registered after STOP escaped its closed snapshot";
        }
        java.util.Set<java.io.Closeable> sockets = java.util.Collections.synchronizedSet(new java.util.HashSet<>());
        java.util.concurrent.atomic.AtomicBoolean stopped = new java.util.concurrent.atomic.AtomicBoolean(false);
        java.util.concurrent.atomic.AtomicInteger closes = new java.util.concurrent.atomic.AtomicInteger();
        ShellCapabilityBridge.registerOwnedSocket(sockets, stopped, closes::incrementAndGet);
        stopped.set(true); ShellCapabilityBridge.retireOwnedSockets(sockets);
        assert sockets.isEmpty() && closes.get() == 1 : "accepted-before-STOP resource was not retired";
        System.out.println("PASS barrier-controlled Binder/child late registration rejected and closed, accepted registration included in STOP snapshot");
    }
    private static void testVerifiedSourceCleanup() throws Exception {
        java.nio.file.Path directory = java.nio.file.Files.createTempDirectory("gb-shell-source-");
        java.nio.file.Path earlyReturn = directory.resolve("return.jar"), failure = directory.resolve("failure.jar"), live = directory.resolve("live.jar");
        try {
            java.nio.file.Files.write(earlyReturn, new byte[] {1});
            ShellCapabilityBridge.withVerifiedSource(earlyReturn.toFile(), () -> {});
            assert !java.nio.file.Files.exists(earlyReturn) : "early missing-Helper return leaked verified source JAR";
            java.nio.file.Files.write(failure, new byte[] {1});
            try { ShellCapabilityBridge.withVerifiedSource(failure.toFile(), () -> { throw new java.io.IOException("synthetic package lookup failure"); });
                throw new AssertionError("startup error swallowed"); } catch (java.io.IOException expected) {}
            assert !java.nio.file.Files.exists(failure) : "throwing package lookup leaked verified source JAR";
            java.nio.file.Files.write(live, new byte[] {1});
            java.util.concurrent.CountDownLatch entered = new java.util.concurrent.CountDownLatch(1), retired = new java.util.concurrent.CountDownLatch(1), finished = new java.util.concurrent.CountDownLatch(1);
            java.util.concurrent.atomic.AtomicReference<Throwable> error = new java.util.concurrent.atomic.AtomicReference<>();
            Thread startup = new Thread(() -> {
                try { ShellCapabilityBridge.withVerifiedSource(live.toFile(), () -> { entered.countDown(); ShellCapabilityBridge.awaitPhysicalRetirement(retired); });
                    assert Thread.currentThread().isInterrupted() : "interrupt status was lost";
                } catch (Throwable caught) { error.set(caught); } finally { finished.countDown(); }
            });
            startup.setDaemon(true); startup.start();
            try {
                assert entered.await(1, java.util.concurrent.TimeUnit.SECONDS); startup.interrupt();
                assert !finished.await(100, java.util.concurrent.TimeUnit.MILLISECONDS) && java.nio.file.Files.exists(live) : "interruption unlinked a live source before physical retirement";
            } finally { retired.countDown(); startup.join(1000); }
            assert error.get() == null && !java.nio.file.Files.exists(live);
        } finally {
            java.nio.file.Files.deleteIfExists(earlyReturn); java.nio.file.Files.deleteIfExists(failure); java.nio.file.Files.deleteIfExists(live); java.nio.file.Files.deleteIfExists(directory);
        }
        System.out.println("PASS verified source cleanup on early return/exception and source retained through interrupted physical retirement");
    }
    private static void testSocketRetirement() throws Exception {
        String fixture = System.getenv("GB_SHELL_SOCKET_RETIREMENT_FIXTURE");
        if (fixture == null) throw new AssertionError("real socket fixture required");
        // Cross-UID listener no longer exists: Binder transfers connected PFDs.
        for (String operation : java.util.Collections.singletonList("read")) {
            Process process = new ProcessBuilder(fixture, operation).start();
            try {
                java.io.BufferedReader receipts = new java.io.BufferedReader(new java.io.InputStreamReader(process.getInputStream()));
                assert "ready".equals(receipts.readLine());
                ShellCapabilityBridge.shutdownAndClose(() -> {
                    process.getOutputStream().write("shutdown\n".getBytes(java.nio.charset.StandardCharsets.US_ASCII)); process.getOutputStream().flush();
                }, () -> {
                    process.getOutputStream().write("close\n".getBytes(java.nio.charset.StandardCharsets.US_ASCII)); process.getOutputStream().flush();
                });
                java.util.concurrent.CompletableFuture<Boolean> unblocked = new java.util.concurrent.CompletableFuture<>();
                Thread reader = new Thread(() -> {
                    try { String line; while ((line = receipts.readLine()) != null) {
                        if (line.equals("unblocked")) { unblocked.complete(true); return; }
                        if (operation.equals("accept") && line.equals("darwin_listener_shutdown_unsupported")) {
                            System.out.println("NOTE Darwin listener shutdown returns ENOTCONN; Android accept wakeup requires device acceptance");
                            unblocked.complete(true); return;
                        }
                    }
                        unblocked.complete(false); } catch (Exception failure) { unblocked.completeExceptionally(failure); }
                }); reader.setDaemon(true); reader.start();
                try { assert unblocked.get(1, java.util.concurrent.TimeUnit.SECONDS) : "blocked " + operation + " never returned"; }
                catch (java.util.concurrent.TimeoutException failure) { throw new AssertionError("close alone left retained socket " + operation + " blocked", failure); }
            } finally {
                process.getOutputStream().close();
                if (!process.waitFor(2, java.util.concurrent.TimeUnit.SECONDS)) process.destroyForcibly();
            }
        }
        java.util.List<String> order = new java.util.ArrayList<>();
        ShellCapabilityBridge.shutdownAndClose(() -> { order.add("shutdown"); throw new java.io.IOException("already disconnected"); }, () -> order.add("close"));
        assert order.equals(java.util.Arrays.asList("shutdown", "close")) : "shutdown failure skipped close";
        System.out.println("PASS production FD shutdown-before-close seam with real retained-socket read EOF and shutdown-error close fallback");
    }
    private static java.util.concurrent.CompletableFuture<Void> connectAsync(ShellCapabilityBridge.StreamOrder gate, String type,
            ShellCapabilityBridge.StreamConnector connector) {
        java.util.concurrent.CompletableFuture<Void> result = new java.util.concurrent.CompletableFuture<>();
        Thread thread = new Thread(() -> { try { gate.connect(type, 1000, connector); result.complete(null); }
            catch (Throwable failure) { result.completeExceptionally(failure); } });
        thread.setDaemon(true); thread.start(); return result;
    }
    private static void expectConnectionFailure(java.util.concurrent.CompletableFuture<Void> result) throws Exception {
        try { result.get(1, java.util.concurrent.TimeUnit.SECONDS); throw new AssertionError("connection unexpectedly succeeded"); }
        catch (java.util.concurrent.ExecutionException expected) { assert expected.getCause() instanceof java.io.IOException; }
    }
    private static Map<String, Object> composite(int action, boolean interactive, int policy, long revision) {
        Map<String, Object> fields = new HashMap<>(); fields.put("action", action); fields.put("interactive", interactive);
        fields.put("panel_policy", policy); fields.put("revision", revision); return fields;
    }
    private static void testCompositeCommands() {
        for (int action : new int[] {0, 1}) {
            ShellCapabilityBridge.CompositeCommand parsed = ShellCapabilityBridge.CompositeCommand.parse(composite(action, false, 0, 0));
            assert parsed.action == action && !parsed.interactive && parsed.panelPolicy == 0 && parsed.revision == 0;
            reject(() -> ShellCapabilityBridge.CompositeCommand.parse(composite(action, true, 0, 0)));
            reject(() -> ShellCapabilityBridge.CompositeCommand.parse(composite(action, false, 1, 0)));
            reject(() -> ShellCapabilityBridge.CompositeCommand.parse(composite(action, false, 0, 1)));
        }
        for (int policy : new int[] {0, 1, 2}) {
            ShellCapabilityBridge.CompositeCommand parsed = ShellCapabilityBridge.CompositeCommand.parse(composite(2, true, policy, Long.MAX_VALUE));
            assert parsed.action == 2 && parsed.interactive && parsed.panelPolicy == policy && parsed.revision == Long.MAX_VALUE;
        }
        reject(() -> ShellCapabilityBridge.CompositeCommand.parse(composite(2, true, 1, 0)));
        reject(() -> ShellCapabilityBridge.CompositeCommand.parse(composite(2, true, 1, -1)));
        reject(() -> ShellCapabilityBridge.CompositeCommand.parse(composite(3, true, 1, 1)));
        reject(() -> ShellCapabilityBridge.CompositeCommand.parse(composite(2, true, 3, 1)));
        for (String key : new String[] {"action", "interactive", "panel_policy", "revision"}) {
            Map<String, Object> missing = composite(2, true, 1, 1); missing.remove(key);
            reject(() -> ShellCapabilityBridge.CompositeCommand.parse(missing));
        }
        Map<String, Object> unknown = composite(2, true, 1, 1); unknown.put("scid", 123);
        reject(() -> ShellCapabilityBridge.CompositeCommand.parse(unknown));
        for (Object value : new Object[] {"1", 1.0, null}) {
            Map<String, Object> malformed = composite(2, true, 1, 1); malformed.put("revision", value);
            reject(() -> ShellCapabilityBridge.CompositeCommand.parse(malformed));
        }
        Map<String, Object> booleanString = composite(2, true, 1, 1); booleanString.put("interactive", "true");
        reject(() -> ShellCapabilityBridge.CompositeCommand.parse(booleanString));
        System.out.println("PASS native composite command format: zero-field snapshot/status, explicit bounded policy action");
    }

    private static void testCompositeAdmission() throws Exception {
        String lease = "69830b65-6352-4b3a-8a21-70bcda45787e", other = "d5e1590c-47fb-4d73-9ac2-45988ba0a876";
        ShellCapabilityBridge.CompositeLeaseAdmission admission = new ShellCapabilityBridge.CompositeLeaseAdmission(4);
        reject(() -> admission.requireStatus(lease));
        reject(() -> admission.admitApply(lease, ShellCapabilityBridge.CompositeCommand.parse(composite(2, true, 0, 1))));
        assert admission.reserveSnapshot(lease) : "first SNAPSHOT did not reserve a read-only lifetime";
        assert !admission.mayHaveMutated(lease);
        assert !admission.reserveSnapshot(lease) : "duplicate SNAPSHOT rebased the initial snapshot";
        reject(() -> admission.requireStatus(lease));
        reject(() -> admission.admitApply(lease, ShellCapabilityBridge.CompositeCommand.parse(composite(2, true, 0, 1))));
        admission.snapshotReady(lease); admission.requireStatus(lease);
        assert !admission.mayHaveMutated(lease) && !admission.reserveSnapshot(lease);
        admission.admitApply(lease, ShellCapabilityBridge.CompositeCommand.parse(composite(2, true, 0, 1)));
        assert admission.mayHaveMutated(lease) : "possible mutation must be armed before a write can fail";
        admission.requireStatus(lease);
        admission.admitApply(lease, ShellCapabilityBridge.CompositeCommand.parse(composite(2, true, 0, 1)));
        reject(() -> admission.admitApply(lease, ShellCapabilityBridge.CompositeCommand.parse(composite(2, true, 1, 1))));
        reject(() -> admission.reserveSnapshot(lease));
        admission.admitApply(lease, ShellCapabilityBridge.CompositeCommand.parse(composite(2, true, 1, 2)));
        reject(() -> admission.admitApply(lease, ShellCapabilityBridge.CompositeCommand.parse(composite(2, true, 0, 1))));
        admission.beginRetirement(lease);
        assert admission.mayHaveMutated(lease) : "drain discarded uncertainty about an earlier attempted policy";
        reject(() -> admission.requireStatus(lease));
        reject(() -> admission.snapshotReady(lease));
        reject(() -> admission.admitApply(lease, ShellCapabilityBridge.CompositeCommand.parse(composite(2, true, 1, 3))));
        admission.finishRetirement(lease); admission.finishRetirement(lease);
        assert admission.isRetired(lease); reject(() -> admission.reserveSnapshot(lease));
        admission.beginRetirement(other); assert admission.isRetired(other);
        reject(() -> admission.reserveSnapshot(other));
        String late = new java.util.UUID(0, 3).toString(); assert admission.reserveSnapshot(late);
        java.util.concurrent.CountDownLatch release = new java.util.concurrent.CountDownLatch(1);
        java.util.concurrent.atomic.AtomicBoolean lateRejected = new java.util.concurrent.atomic.AtomicBoolean();
        Thread callback = new Thread(() -> {
            try { release.await(); admission.snapshotReady(late); }
            catch (IllegalArgumentException expected) { lateRejected.set(true); }
            catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
        }); callback.start(); admission.beginRetirement(late); release.countDown(); callback.join(2000);
        assert !callback.isAlive() && lateRejected.get() : "late startup callback revived a draining owner";
        assert !admission.mayHaveMutated(late); admission.finishRetirement(late);
        String last = new java.util.UUID(0, 4).toString(); assert admission.reserveSnapshot(last);
        admission.beginRetirement(last); admission.finishRetirement(last);
        assert admission.retainedCount() == 4;
        reject(() -> admission.reserveSnapshot(new java.util.UUID(0, 5).toString()));
        reject(() -> admission.reserveSnapshot(lease));
        reject(() -> new ShellCapabilityBridge.CompositeLeaseAdmission(0));
        System.out.println("PASS native composite admission: immutable snapshot phase, pre-write uncertainty, drain fencing, late callbacks and bounded STOP tombstones");
    }

}
