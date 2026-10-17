package com.genymobile.scrcpy;

import java.util.HashMap;
import java.util.Map;

/** Host execution of the actual server's typed policy; no Android APIs invoked. */
public final class ShellCapabilityBridgePolicyTest {
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
            ShellCapabilityBridge.panelLifetime(System.in, true, on -> {
                java.nio.file.Files.write(path, (on ? "on" : "off").getBytes(java.nio.charset.StandardCharsets.UTF_8)); return true;
            });
            return;
        }
        if (args.length == 2 && args[0].equals("parent")) {
            String javaProgram = System.getProperty("java.home") + "/bin/java";
            new ProcessBuilder(javaProgram, "-cp", System.getProperty("java.class.path"), ShellCapabilityBridgePolicyTest.class.getName(), "child", args[1]).start();
            long deadline = System.nanoTime() + java.util.concurrent.TimeUnit.SECONDS.toNanos(3);
            while (!java.nio.file.Files.exists(java.nio.file.Paths.get(args[1])) && System.nanoTime() < deadline) Thread.sleep(10);
            System.out.println("ready"); System.out.flush(); Thread.sleep(30000); return;
        }
        String lease = "69830b65-6352-4b3a-8a21-70bcda45787e";
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
}
