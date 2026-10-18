package com.genymobile.scrcpy;

import java.io.IOException;
import java.util.*;

public final class DisplayStateRuntimeBackendTest {
    static class Platform implements DisplayStateRuntimeBackend.Platform {
        long now = 1000, ordinary = 100, noLights = 80, wake = 100, sleep = 200;
        boolean interactive, changing, failPanel, failWake, hideFocusedPanel, flipInteractiveRead, failPrepare;
        String mode = "DOZE", active = "20";
        int focused, full, mutations;
        boolean rejectBeforeMutation, failAfterMutation;
        Thread beforeThread, invocationThread, afterThread;
        public void beforeMutation() throws Exception {
            beforeThread = Thread.currentThread();
            if (rejectBeforeMutation) throw new IOException("service_identity_rejected_before_invocation");
        }
        public void afterMutation() throws Exception {
            afterThread = Thread.currentThread();
            if (failAfterMutation) throw new IOException("service_health_unknown_after_invocation");
        }
        public long uptimeMillis() { return ++now; }
        public void pause() { now += 40; }
        public boolean defaultInteractive() { if (flipInteractiveRead) { interactive = !interactive; } return interactive; }
        public String powerDump(long deadline) throws Exception {
            assert deadline > now;
            return "Power Manager State:\n  mWakefulness=" + (interactive ? "Awake" : "Dozing")
                + "\n  mWakefulnessChanging=" + changing + "\n  mLastWakeTime=" + wake + "\n  mLastSleepTime=" + sleep
                + "\nPower Group User Activity:\ngroupId: 0\nlastUserActivityTime=" + ordinary
                + "\nlastUserActivityTimeNoChangeLights=" + noLights + "\nmWakefulness=" + (interactive ? "1" : "3") + "\n";
        }
        public Set<String> physicalIDs() { return new LinkedHashSet<>(Arrays.asList("10", "20")); }
        public String activePhysicalID() { return active; }
        public String panelDump(boolean onlyDisplays, long deadline) {
            assert deadline > now;
            if (onlyDisplays) focused++; else full++;
            return (onlyDisplays && hideFocusedPanel ? "" : "Display 10\n connectionType=Internal\n powerMode=OFF\n")
                + "Display 20\n connectionType=Internal\n powerMode=" + mode + "\n";
        }
        public void wake(long token) throws Exception {
            invocationThread = Thread.currentThread();
            mutations++; interactive = true; mode = "ON"; ordinary = token; wake = token;
            if (failWake) throw new IOException("wake_reply_unknown");
        }
        public void sleep(long token, DisplayStateSnapshot.Wakefulness target) {
            invocationThread = Thread.currentThread();
            mutations++; assert token == wake; interactive = false; mode = "DOZE"; sleep = token;
        }
        public void activity(long time) { invocationThread = Thread.currentThread(); mutations++; noLights = time; }
        public DisplayStateRuntimeBackend.Mutation preparePanel(final String id, final DisplayStateSnapshot.Mode target) throws Exception {
            if (failPrepare) throw new IOException("token_lookup_failed_before_invocation");
            return new DisplayStateRuntimeBackend.Mutation() { public void run() throws Exception {
                invocationThread = Thread.currentThread();
                mutations++; assert physicalIDs().contains(id);
                if (failPanel) throw new IOException("panel_reply_unknown");
                if (id.equals("20")) mode = target.name();
            } };
        }
    }
    interface Throwing { void run() throws Exception; }
    static void reject(Throwing call) throws Exception {
        try { call.run(); throw new AssertionError("unknown backend evidence accepted"); }
        catch (DisplayStateSnapshot.Failure | IOException expected) {}
    }
    public static void main(String[] args) throws Exception {
        testContinuousActivityObservation();
        testTransientWakeObservation();
        Platform platform = new Platform(); DisplayStateRuntimeBackend backend = new DisplayStateRuntimeBackend(platform);
        DisplayStateSnapshot initial = backend.read();
        assert initial.panels.get("20") == DisplayStateSnapshot.Mode.DOZE && !initial.power.defaultInteractive;
        assert platform.mutations == 0 && platform.full == 0;
        DisplayStateOwnership owner = new DisplayStateOwnership(backend);
        owner.apply(true, DisplayStateOwnership.Policy.HIDE, 1); owner.poll();
        assert platform.interactive && platform.mode.equals("OFF") && platform.noLights > platform.ordinary;
        owner.restore(); assert !platform.interactive && platform.mode.equals("DOZE");
        backend.synchronizeMutations();
        assert platform.beforeThread == platform.invocationThread && platform.afterThread == platform.invocationThread;
        assert platform.invocationThread != Thread.currentThread() : "service checks and invocation must share a dedicated mutation thread";
        Platform beforeFailure = new Platform(); beforeFailure.rejectBeforeMutation = true;
        DisplayStateRuntimeBackend rejected = new DisplayStateRuntimeBackend(beforeFailure);
        reject(() -> rejected.wake(500)); rejected.synchronizeMutations(); assert beforeFailure.mutations == 0;
        beforeFailure.rejectBeforeMutation = false; rejected.wake(500); rejected.synchronizeMutations(); assert beforeFailure.mutations == 1;
        Platform afterFailure = new Platform(); afterFailure.failAfterMutation = true;
        DisplayStateRuntimeBackend uncertainHealth = new DisplayStateRuntimeBackend(afterFailure);
        reject(() -> uncertainHealth.wake(500)); reject(uncertainHealth::synchronizeMutations); assert afterFailure.mutations == 1;
        Platform narrow = new Platform(); narrow.hideFocusedPanel = true;
        DisplayStateRuntimeBackend fallback = new DisplayStateRuntimeBackend(narrow);
        assert fallback.read().physicalIDs.size() == 2 && narrow.focused == 1 && narrow.full >= 2;
        int before = narrow.focused; fallback.read(); assert narrow.focused == before : "known incomplete focused dump should not repeat";
        Platform changing = new Platform(); changing.changing = true;
        long transitionStart = changing.now;
        reject(() -> new DisplayStateRuntimeBackend(changing).read()); assert changing.mutations == 0;
        assert changing.now - transitionStart <= 2600 : "permanent transition must retain the original read deadline";
        final int[] malformedReads = {0};
        Platform malformedAfterTransition = new Platform() {
            public String powerDump(long deadline) throws Exception {
                changing = ++malformedReads[0] == 1;
                String value = super.powerDump(deadline);
                return changing ? value : value.replace("mWakefulness=Dozing", "mWakefulness=Unknown");
            }
        };
        reject(() -> new DisplayStateRuntimeBackend(malformedAfterTransition).read());
        assert malformedReads[0] == 2 && malformedAfterTransition.mutations == 0
            : "a malformed sample after a transition must fail without retry";
        Platform inconsistent = new Platform(); inconsistent.flipInteractiveRead = true;
        reject(() -> new DisplayStateRuntimeBackend(inconsistent).read()); assert inconsistent.mutations == 0;
        Platform panelFailure = new Platform(); panelFailure.failPanel = true;
        DisplayStateRuntimeBackend unknownPanel = new DisplayStateRuntimeBackend(panelFailure);
        reject(() -> unknownPanel.setPanel("20", DisplayStateSnapshot.Mode.OFF));
        reject(unknownPanel::synchronizeMutations);
        panelFailure.failPanel = false;
        reject(() -> unknownPanel.setPanel("20", DisplayStateSnapshot.Mode.ON));
        assert panelFailure.mutations == 1 : "unknown queued mutation must block a second write";
        Platform wakeFailure = new Platform(); wakeFailure.failWake = true;
        DisplayStateRuntimeBackend unknownWake = new DisplayStateRuntimeBackend(wakeFailure);
        reject(() -> unknownWake.wake(500)); reject(unknownWake::synchronizeMutations);
        Platform invalid = new Platform(); DisplayStateRuntimeBackend validation = new DisplayStateRuntimeBackend(invalid);
        reject(() -> validation.setPanel("900", DisplayStateSnapshot.Mode.ON));
        validation.synchronizeMutations(); assert invalid.mutations == 0 : "local preflight rejection creates no pending Android operation";
        Platform tokenFailure = new Platform(); tokenFailure.failPrepare = true;
        DisplayStateRuntimeBackend prepared = new DisplayStateRuntimeBackend(tokenFailure);
        reject(() -> prepared.setPanel("20", DisplayStateSnapshot.Mode.OFF));
        prepared.synchronizeMutations(); assert tokenFailure.mutations == 0;
        tokenFailure.failPrepare = false; prepared.setPanel("20", DisplayStateSnapshot.Mode.OFF); prepared.synchronizeMutations();
        final java.util.concurrent.CountDownLatch entered = new java.util.concurrent.CountDownLatch(1), release = new java.util.concurrent.CountDownLatch(1);
        final java.util.concurrent.atomic.AtomicInteger blockedCalls = new java.util.concurrent.atomic.AtomicInteger();
        Platform blocked = new Platform() { public boolean defaultInteractive() {
            blockedCalls.incrementAndGet(); entered.countDown();
            try { release.await(); } catch (InterruptedException unexpected) { throw new AssertionError("read-only Binder calls must not be cancelled into false completion"); }
            return interactive;
        } };
        DisplayStateRuntimeBackend bounded = new DisplayStateRuntimeBackend(blocked, 25);
        try {
            long start = System.nanoTime(); reject(bounded::read);
            assert entered.await(1, java.util.concurrent.TimeUnit.SECONDS);
            assert java.util.concurrent.TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - start) < 1000;
            reject(bounded::read); reject(() -> bounded.wake(500));
            assert blockedCalls.get() == 1 && blocked.mutations == 0 : "one blocked read must not accumulate readers or admit mutations";
        } finally { release.countDown(); }
        DisplayStateSnapshot refreshed = null;
        for (int i = 0; i < 100 && refreshed == null; ++i) {
            try { refreshed = bounded.read(); } catch (DisplayStateRuntimeBackend.Failure settling) { Thread.sleep(5); }
        }
        assert refreshed != null && blockedCalls.get() >= 8 : "completed timed-out result must be discarded, then freshly sampled";
        Platform budget = new Platform() { public String powerDump(long deadline) throws Exception { String result = super.powerDump(deadline); now = deadline + 1; return result; } };
        reject(() -> new DisplayStateRuntimeBackend(budget).read()); assert budget.mutations == 0;
        final java.util.concurrent.CountDownLatch prepareEntered = new java.util.concurrent.CountDownLatch(1), prepareRelease = new java.util.concurrent.CountDownLatch(1);
        Platform latePreparation = new Platform() {
            public DisplayStateRuntimeBackend.Mutation preparePanel(String id, DisplayStateSnapshot.Mode target) throws Exception {
                prepareEntered.countDown(); prepareRelease.await(); return super.preparePanel(id, target);
            }
        };
        DisplayStateRuntimeBackend late = new DisplayStateRuntimeBackend(latePreparation, 25);
        try {
            reject(() -> late.setPanel("20", DisplayStateSnapshot.Mode.OFF));
            assert prepareEntered.await(1, java.util.concurrent.TimeUnit.SECONDS) && latePreparation.mutations == 0;
            late.synchronizeMutations();
        } finally { prepareRelease.countDown(); }
        DisplayStateSnapshot freshAfterPreparation = null;
        for (int i = 0; i < 100 && freshAfterPreparation == null; ++i) {
            try { freshAfterPreparation = late.read(); } catch (DisplayStateRuntimeBackend.Failure settling) { Thread.sleep(5); }
        }
        assert freshAfterPreparation != null && freshAfterPreparation.panels.get("20") == DisplayStateSnapshot.Mode.DOZE;
        assert latePreparation.mutations == 0 : "timed-out token preparation must never invoke its late action";
        late.setPanel("20", DisplayStateSnapshot.Mode.OFF); assert latePreparation.mutations == 1;
        testPendingMutation(false);
        testPendingMutation(true);
        testEndpointGuard();
        testDeathAfterInvocation();
        assert DisplayStateRuntimeBackend.powerMode(DisplayStateSnapshot.Mode.OFF) == 0;
        assert DisplayStateRuntimeBackend.powerMode(DisplayStateSnapshot.Mode.DOZE) == 1;
        assert DisplayStateRuntimeBackend.powerMode(DisplayStateSnapshot.Mode.ON) == 2;
        assert DisplayStateRuntimeBackend.powerMode(DisplayStateSnapshot.Mode.DOZE_SUSPEND) == 3;
        assert DisplayStateRuntimeBackend.powerMode(DisplayStateSnapshot.Mode.ON_SUSPEND) == 4;
        System.out.println("PASS actual backend on synthetic platform: stable inventory, focused fallback, interactivity, raw modes, lifecycle, one bounded reader, discarded late preparation and unknown mutations quarantined");
    }
    static void testContinuousActivityObservation() throws Exception {
        final boolean[] moving = {false};
        final int[] powerReads = {0};
        Platform input = new Platform() {
            public String powerDump(long deadline) throws Exception {
                powerReads[0]++;
                if (moving[0]) { ordinary++; noLights++; }
                return super.powerDump(deadline);
            }
        };
        DisplayStateOwnership owner = new DisplayStateOwnership(new DisplayStateRuntimeBackend(input));
        owner.apply(true, DisplayStateOwnership.Policy.HIDE, 1);
        moving[0] = true;
        int before = powerReads[0];
        try { owner.poll(); }
        catch (Exception failure) {
            throw new AssertionError("Continuous input must not turn a current-state poll into repeated snapshots; power reads="
                + (powerReads[0] - before), failure);
        }
        assert owner.state() == DisplayStateOwnership.State.READY && input.mode.equals("OFF");
        assert powerReads[0] - before == 2 : "One stable power epoch needs only its before/after observations";
        moving[0] = false;
        owner.restore();
        assert owner.state() == DisplayStateOwnership.State.YIELDED_ACTIVITY && input.interactive && input.mode.equals("ON")
            : "Later activity must revoke cleanup sleep and release only our blackout";
        moving[0] = true;
        int mutations = input.mutations;
        reject(() -> new DisplayStateOwnership(new DisplayStateRuntimeBackend(input)));
        assert input.mutations == mutations : "A moving initial snapshot must still be rejected without writes";
    }
    static void testTransientWakeObservation() throws Exception {
        final int[] transitionReads = {0}, pauses = {0};
        Platform transitioning = new Platform() {
            public void wake(long token) throws Exception { super.wake(token); transitionReads[0] = 6; }
            public String powerDump(long deadline) throws Exception {
                changing = transitionReads[0] > 0;
                if (transitionReads[0] > 0) transitionReads[0]--;
                return super.powerDump(deadline);
            }
            public void pause() { super.pause(); pauses[0]++; }
        };
        DisplayStateRuntimeBackend backend = new DisplayStateRuntimeBackend(transitioning);
        DisplayStateOwnership owner = new DisplayStateOwnership(backend);
        owner.apply(true, DisplayStateOwnership.Policy.PRESERVE, 1);
        assert owner.state() == DisplayStateOwnership.State.READY && owner.current().power.defaultInteractive;
        assert pauses[0] > 0 && transitionReads[0] == 0 : "own wake transition must settle before admission";
        owner.restore();
        assert owner.state() == DisplayStateOwnership.State.RESTORED && transitioning.mutations == 2;
    }
    static void testPendingMutation(final boolean postcheck) throws Exception {
        final java.util.concurrent.CountDownLatch entered = new java.util.concurrent.CountDownLatch(1), release = new java.util.concurrent.CountDownLatch(1);
        Platform port = new Platform() {
            public void wake(long token) throws Exception { if (!postcheck) { entered.countDown(); release.await(); } super.wake(token); }
            public void afterMutation() throws Exception { super.afterMutation(); if (postcheck) { entered.countDown(); release.await(); } }
        };
        final DisplayStateRuntimeBackend backend = new DisplayStateRuntimeBackend(port, 25);
        java.util.concurrent.FutureTask<Exception> caller = new java.util.concurrent.FutureTask<>(new java.util.concurrent.Callable<Exception>() {
            public Exception call() { try { backend.wake(500); return null; } catch (Exception expected) { return expected; } }
        });
        Thread client = new Thread(caller, "test-bounded-mutation-caller"); client.setDaemon(true); client.start();
        try {
            Exception timeout = caller.get(1, java.util.concurrent.TimeUnit.SECONDS);
            assert timeout instanceof DisplayStateRuntimeBackend.Failure && entered.await(1, java.util.concurrent.TimeUnit.SECONDS);
            reject(backend::synchronizeMutations); reject(backend::read);
            reject(() -> backend.setPanel("20", DisplayStateSnapshot.Mode.OFF));
            assert port.mutations == (postcheck ? 1 : 0) : "timeout must retain the pending invocation/postcheck and block successors";
        } finally { release.countDown(); }
        boolean complete = false;
        for (int i = 0; i < 100 && !complete; ++i) {
            try { backend.synchronizeMutations(); complete = true; } catch (DisplayStateRuntimeBackend.Failure pending) { Thread.sleep(5); }
        }
        assert complete && port.mutations == 1 && backend.read().power.defaultInteractive;
        assert port.beforeThread == port.invocationThread && port.afterThread == port.invocationThread;
    }
    static final class Endpoint implements DisplayStateRuntimeBackend.Endpoint {
        final String token;
        String descriptor = "neutral.interface";
        boolean alive = true, ping = true;
        Runnable death;
        Endpoint(String token) { this.token = token; }
        public Object identity() { return token; }
        public String descriptor() { return descriptor; }
        public boolean alive() { return alive; }
        public boolean ping() { return ping; }
        public void watchDeath(Runnable observer) { death = observer; }
    }
    static void testEndpointGuard() throws Exception {
        final Endpoint original = new Endpoint("one"), replacement = new Endpoint("two");
        final Endpoint[] current = {original};
        DisplayStateRuntimeBackend.Registry registry = name -> current[0];
        DisplayStateRuntimeBackend.EndpointGuard guard = new DisplayStateRuntimeBackend.EndpointGuard(registry, "power", "neutral.interface");
        guard.check(); current[0] = replacement; reject(guard::check); current[0] = original; reject(guard::check);
        DisplayStateRuntimeBackend.EndpointGuard death = new DisplayStateRuntimeBackend.EndpointGuard(registry, "power", "neutral.interface");
        original.death.run(); reject(death::check);
        DisplayStateRuntimeBackend.EndpointGuard health = new DisplayStateRuntimeBackend.EndpointGuard(registry, "power", "neutral.interface");
        original.ping = false; reject(health::check); original.ping = true; reject(health::check);
        reject(() -> new DisplayStateRuntimeBackend.EndpointGuard(registry, "power", "wrong.interface"));
        current[0] = null; reject(() -> new DisplayStateRuntimeBackend.EndpointGuard(registry, "power", "neutral.interface"));
    }
    static void testDeathAfterInvocation() throws Exception {
        final Endpoint service = new Endpoint("live");
        final DisplayStateRuntimeBackend.EndpointGuard guard = new DisplayStateRuntimeBackend.EndpointGuard(name -> service, "power", "neutral.interface");
        Platform port = new Platform() {
            public void beforeMutation() throws Exception { super.beforeMutation(); guard.check(); }
            public void afterMutation() throws Exception { super.afterMutation(); guard.check(); }
            public void wake(long token) throws Exception { super.wake(token); service.death.run(); }
        };
        DisplayStateRuntimeBackend backend = new DisplayStateRuntimeBackend(port);
        reject(() -> backend.wake(500)); reject(backend::synchronizeMutations);
        reject(() -> backend.setPanel("20", DisplayStateSnapshot.Mode.OFF));
        assert port.mutations == 1 && port.interactive : "service death after application cannot become clean completion";
    }
}
