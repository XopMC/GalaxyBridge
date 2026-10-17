package com.genymobile.scrcpy;

import android.os.IBinder;
import android.os.SystemClock;
import com.genymobile.scrcpy.display.DisplayInfo;
import com.genymobile.scrcpy.wrappers.DisplayControl;
import com.genymobile.scrcpy.wrappers.ServiceManager;
import com.genymobile.scrcpy.wrappers.SurfaceControl;

import java.io.*;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;

/** Android adapter for the composite engine. It never launches a capture or changes keyguard/brightness. */
final class DisplayStateRuntimeBackend implements DisplayStateOwnership.Backend {
    static final class Failure extends IOException {
        Failure(String code) { super(code); }
    }
    /** Mutations must use synchronous service operations, with no writes queued after successful return. */
    interface Platform {
        void beforeMutation() throws Exception;
        void afterMutation() throws Exception;
        long uptimeMillis();
        void pause() throws Exception;
        boolean defaultInteractive() throws Exception;
        String powerDump(long deadline) throws Exception;
        Set<String> physicalIDs() throws Exception;
        String activePhysicalID() throws Exception;
        String panelDump(boolean displaysOnly, long deadline) throws Exception;
        void wake(long eventTime) throws Exception;
        void sleep(long eventTime, DisplayStateSnapshot.Wakefulness target) throws Exception;
        void activity(long eventTime) throws Exception;
        /** Read-only token/inventory preparation; returned action contains only the actual mutation. */
        Mutation preparePanel(String physicalID, DisplayStateSnapshot.Mode mode) throws Exception;
    }
    private final Platform platform;
    private final long readTimeoutMillis;
    private FutureTask<?> pendingRead;
    private MutationJob pendingMutation;
    private boolean focused = true, uncertain;
    private final ExecutorService mutationExecutor = new ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS,
        new ArrayBlockingQueue<Runnable>(1), new ThreadFactory() { public Thread newThread(Runnable action) {
            Thread thread = new Thread(action, "gb-display-mutation"); thread.setDaemon(true); return thread;
        } });
    private static final long READ_MILLIS = 2500;
    DisplayStateRuntimeBackend(Platform platform) {
        this(platform, READ_MILLIS);
    }
    DisplayStateRuntimeBackend(Platform platform, long readTimeoutMillis) {
        if (platform == null || readTimeoutMillis <= 0 || readTimeoutMillis > READ_MILLIS) throw new IllegalArgumentException();
        this.platform = platform; this.readTimeoutMillis = readTimeoutMillis;
    }
    static DisplayStateRuntimeBackend open() throws Exception { return new DisplayStateRuntimeBackend(new AndroidPlatform()); }
    private void within(long deadline) throws Failure {
        if (platform.uptimeMillis() >= deadline) throw new Failure("display_read_deadline");
    }
    public DisplayStateSnapshot read() throws Exception {
        return boundedRead(new Callable<DisplayStateSnapshot>() { public DisplayStateSnapshot call() throws Exception { return sample(); } });
    }
    private synchronized <T> T boundedRead(Callable<T> operation) throws Exception {
        if (pendingMutation != null && !pendingMutation.task.isDone()) throw new Failure("display_mutation_still_pending");
        if (pendingRead != null && !pendingRead.isDone()) throw new Failure("display_read_still_pending");
        final FutureTask<T> task = new FutureTask<>(operation); pendingRead = task;
        Thread worker = new Thread(task, "gb-display-bounded-read"); worker.setDaemon(true); worker.start();
        try { return task.get(readTimeoutMillis, TimeUnit.MILLISECONDS); }
        catch (TimeoutException expired) { throw new Failure("display_binder_read_timeout"); }
        catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt(); throw new Failure("display_read_interrupted");
        } catch (ExecutionException failed) {
            Throwable cause = failed.getCause();
            if (cause instanceof Exception) throw (Exception) cause;
            if (cause instanceof Error) throw (Error) cause;
            throw new Failure("display_read_failed");
        } finally {
            // Do not cancel a Binder read into false completion or enqueue more
            // work behind it. Its late result is discarded, never a new baseline.
            if (task.isDone()) pendingRead = null;
        }
    }
    private DisplayStateSnapshot sample() throws Exception {
        final long deadline = platform.uptimeMillis() + READ_MILLIS;
        return DisplayStateSnapshot.sample(new DisplayStateSnapshot.SampleSource() {
            public DisplayStateSnapshot.PowerEvidence power() throws Exception {
                within(deadline); boolean before = platform.defaultInteractive();
                String dump = platform.powerDump(deadline);
                boolean after = platform.defaultInteractive(); within(deadline);
                if (before != after) throw new Failure("display_interactivity_unsettled");
                return DisplayStateSnapshot.parsePower(dump, after);
            }
            public DisplayStateSnapshot.PhysicalEvidence physical() throws Exception {
                within(deadline); Set<String> inventory = platform.physicalIDs(); String active = platform.activePhysicalID();
                Map<String, DisplayStateSnapshot.Mode> panels = null;
                if (focused) {
                    try {
                        panels = DisplayStateSnapshot.parsePhysical(platform.panelDump(true, deadline));
                        if (!panels.keySet().equals(inventory)) throw new Failure("display_focused_inventory_incomplete");
                    } catch (Exception unavailable) { focused = false; panels = null; }
                }
                if (panels == null) { within(deadline); panels = DisplayStateSnapshot.parsePhysical(platform.panelDump(false, deadline)); }
                if (!inventory.equals(platform.physicalIDs()) || !active.equals(platform.activePhysicalID()))
                    throw new Failure("display_physical_inventory_unsettled");
                within(deadline);
                return new DisplayStateSnapshot.PhysicalEvidence(panels, active, inventory);
            }
        });
    }
    public long uptimeMillis() { return platform.uptimeMillis(); }
    public void pause() throws Exception { platform.pause(); }
    interface Mutation { void run() throws Exception; }
    private enum MutationOutcome { PENDING, COMPLETED, REJECTED_BEFORE_INVOCATION, UNKNOWN }
    private static final class MutationJob {
        volatile MutationOutcome outcome = MutationOutcome.PENDING;
        final FutureTask<Void> task;
        MutationJob(final Platform platform, final Mutation action) {
            task = new FutureTask<>(new Callable<Void>() { public Void call() throws Exception {
                boolean invoked = false;
                try {
                    platform.beforeMutation(); invoked = true; action.run(); platform.afterMutation();
                    outcome = MutationOutcome.COMPLETED; return null;
                } catch (Throwable failure) {
                    outcome = invoked ? MutationOutcome.UNKNOWN : MutationOutcome.REJECTED_BEFORE_INVOCATION;
                    if (failure instanceof Exception) throw (Exception) failure;
                    if (failure instanceof Error) throw (Error) failure;
                    throw new Failure("display_mutation_failed");
                }
            } });
        }
    }
    private void reconcileMutation() {
        if (pendingMutation != null && pendingMutation.task.isDone()) {
            if (pendingMutation.outcome == MutationOutcome.UNKNOWN || pendingMutation.outcome == MutationOutcome.PENDING) uncertain = true;
            pendingMutation = null;
        }
    }
    private synchronized void mutate(Mutation action) throws Exception {
        synchronizeMutations();
        if (pendingRead != null && !pendingRead.isDone()) throw new Failure("display_read_still_pending");
        final MutationJob job = new MutationJob(platform, action); pendingMutation = job;
        mutationExecutor.execute(job.task);
        try { job.task.get(readTimeoutMillis, TimeUnit.MILLISECONDS); }
        catch (TimeoutException expired) { throw new Failure("display_mutation_still_pending"); }
        catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); throw new Failure("display_mutation_interrupted"); }
        catch (ExecutionException failed) {
            Throwable cause = failed.getCause();
            if (cause instanceof Exception) throw (Exception) cause;
            if (cause instanceof Error) throw (Error) cause;
            throw new Failure("display_mutation_failed");
        } finally { reconcileMutation(); }
    }
    public synchronized void synchronizeMutations() throws Failure {
        // A failed synchronous Binder/SurfaceControl call is not completion
        // evidence. Never clear this fence by merely observing the old state.
        if (pendingMutation != null && !pendingMutation.task.isDone()) throw new Failure("display_mutation_still_pending");
        reconcileMutation();
        if (uncertain) throw new Failure("display_mutation_completion_unknown");
    }
    public void wake(final long eventTime) throws Exception {
        if (eventTime <= 0) throw new Failure("display_wake_time_invalid");
        mutate(new Mutation() { public void run() throws Exception { platform.wake(eventTime); } });
    }
    public void sleep(final long eventTime, final DisplayStateSnapshot.Wakefulness target) throws Exception {
        if (eventTime <= 0 || (target != DisplayStateSnapshot.Wakefulness.ASLEEP && target != DisplayStateSnapshot.Wakefulness.DOZING))
            throw new Failure("display_sleep_target_invalid");
        mutate(new Mutation() { public void run() throws Exception { platform.sleep(eventTime, target); } });
    }
    public void activityWithoutLights() throws Exception {
        final long time = platform.uptimeMillis();
        mutate(new Mutation() { public void run() throws Exception { platform.activity(time); } });
    }
    public void setPanel(final String id, final DisplayStateSnapshot.Mode mode) throws Exception {
        if (!DisplayStateSnapshot.validID(id) || mode == null) throw new Failure("display_panel_preflight_failed");
        Mutation prepared = boundedRead(new Callable<Mutation>() { public Mutation call() throws Exception {
            if (!platform.physicalIDs().contains(id)) throw new Failure("display_panel_preflight_failed");
            return platform.preparePanel(id, mode);
        } });
        if (prepared == null) throw new Failure("display_panel_preflight_failed");
        mutate(prepared);
    }
    static int powerMode(DisplayStateSnapshot.Mode mode) {
        switch (mode) {
            case OFF: return 0;
            case DOZE: return 1;
            case ON: return 2;
            case DOZE_SUSPEND: return 3;
            case ON_SUSPEND: return 4;
            default: throw new IllegalArgumentException();
        }
    }
    interface Endpoint {
        Object identity();
        String descriptor() throws Exception;
        boolean alive();
        boolean ping() throws Exception;
        void watchDeath(Runnable observer) throws Exception;
    }
    interface Registry { Endpoint resolve(String service) throws Exception; }
    static final class EndpointGuard {
        final Endpoint endpoint;
        private final Registry registry;
        private final String service;
        private volatile boolean invalid;
        EndpointGuard(Registry registry, String service, String descriptor) throws Exception {
            this.registry = registry; this.service = service; endpoint = registry.resolve(service);
            if (endpoint == null || endpoint.identity() == null || !descriptor.equals(endpoint.descriptor()))
                throw new Failure("display_service_interface_unknown");
            endpoint.watchDeath(new Runnable() { public void run() { invalid = true; } }); check();
        }
        void check() throws Exception {
            try {
                if (invalid || !endpoint.alive() || !endpoint.ping()) throw new Failure("display_service_unavailable");
                Endpoint current = registry.resolve(service);
                if (current == null || !endpoint.identity().equals(current.identity()) || invalid)
                    throw new Failure("display_service_generation_changed");
            } catch (Exception failure) { invalid = true; throw failure; }
        }
    }
    private static final class AndroidRegistry implements Registry {
        private final Object manager;
        private final Method checkService;
        AndroidRegistry() throws Exception {
            Method getManager = Class.forName("android.os.ServiceManager").getDeclaredMethod("getIServiceManager");
            getManager.setAccessible(true); manager = getManager.invoke(null);
            checkService = Class.forName("android.os.IServiceManager").getMethod("checkService", String.class);
            if (manager == null || checkService.getReturnType() != IBinder.class) throw new Failure("display_registry_unavailable");
        }
        public Endpoint resolve(String name) throws Exception {
            if (!name.equals("power") && !name.equals("display") && !name.equals("SurfaceFlingerAIDL")) throw new IllegalArgumentException();
            // Call the registry interface directly: ServiceManager's public
            // get/checkService helpers may return cached service objects.
            final IBinder binder = (IBinder) checkService.invoke(manager, name);
            if (binder == null) return null;
            return new Endpoint() {
                public Object identity() { return binder; }
                public String descriptor() throws Exception { return binder.getInterfaceDescriptor(); }
                public boolean alive() { return binder.isBinderAlive(); }
                public boolean ping() { return binder.pingBinder(); }
                public void watchDeath(final Runnable observer) throws Exception {
                    binder.linkToDeath(new IBinder.DeathRecipient() { public void binderDied() { observer.run(); } }, 0);
                }
            };
        }
    }
    private static final class AndroidPlatform implements Platform {
        private final DisplayStatePowerCalls power;
        private final EndpointGuard powerEndpoint, displayEndpoint, compositorEndpoint;
        private final boolean useDisplayControl = !SurfaceControl.hasGetPhysicalDisplayIdsMethod();
        private final Method panelMode = Class.forName("android.view.SurfaceControl").getMethod("setDisplayPowerMode", IBinder.class, int.class);
        private Thread pendingDumpReader;
        private Process pendingDumpChild;
        AndroidPlatform() throws Exception {
            if (android.os.Process.myUid() != 2000 || panelMode.getReturnType() != void.class)
                throw new Failure("display_shell_backend_required");
            AndroidRegistry registry = new AndroidRegistry();
            powerEndpoint = new EndpointGuard(registry, "power", "android.os.IPowerManager");
            displayEndpoint = new EndpointGuard(registry, "display", "android.hardware.display.IDisplayManager");
            compositorEndpoint = new EndpointGuard(registry, "SurfaceFlingerAIDL", "android.gui.ISurfaceComposer");
            Class<?> type = Class.forName("android.os.IPowerManager");
            Object manager = Class.forName("android.os.IPowerManager$Stub").getMethod("asInterface", IBinder.class)
                .invoke(null, powerEndpoint.endpoint.identity());
            power = new DisplayStatePowerCalls(type, manager);
        }
        public void beforeMutation() throws Exception { powerEndpoint.check(); displayEndpoint.check(); compositorEndpoint.check(); }
        public void afterMutation() throws Exception {
            // Same mutation thread as the synchronous invocation. These are
            // identity/liveness checks, not a scheduler flush or a claim that
            // hidden Binder-driver corruption is recoverable. Raw postconditions
            // independently establish whether the requested mode actually applied.
            beforeMutation();
        }
        public long uptimeMillis() { return SystemClock.uptimeMillis(); }
        public void pause() throws InterruptedException { Thread.sleep(40); }
        public boolean defaultInteractive() throws Exception {
            powerEndpoint.check(); boolean value = power.defaultInteractive(); powerEndpoint.check(); return value;
        }
        public String powerDump(long deadline) throws Exception {
            powerEndpoint.check(); String value = dump(new String[] {"/system/bin/dumpsys", "power"}, deadline); powerEndpoint.check(); return value;
        }
        public String panelDump(boolean only, long deadline) throws Exception {
            compositorEndpoint.check(); String value = dump(only ? new String[] {"/system/bin/dumpsys", "SurfaceFlinger", "--displays"}
                : new String[] {"/system/bin/dumpsys", "SurfaceFlinger"}, deadline); compositorEndpoint.check(); return value;
        }
        public Set<String> physicalIDs() throws Exception {
            compositorEndpoint.check();
            long[] raw = useDisplayControl ? DisplayControl.getPhysicalDisplayIds() : SurfaceControl.getPhysicalDisplayIds();
            if (raw == null || raw.length == 0 || raw.length > 8) throw new Failure("display_inventory_unknown");
            Set<String> values = new LinkedHashSet<>();
            for (long id : raw) if (!values.add(Long.toUnsignedString(id))) throw new Failure("display_inventory_unknown");
            compositorEndpoint.check(); return values;
        }
        public String activePhysicalID() throws Exception {
            displayEndpoint.check();
            DisplayInfo info = ServiceManager.getDisplayManager().getDisplayInfo(0);
            String unique = info == null ? null : info.getUniqueId();
            if (unique == null || !unique.startsWith("local:") || !DisplayStateSnapshot.validID(unique.substring(6)))
                throw new Failure("display_active_id_unknown");
            displayEndpoint.check(); return unique.substring(6);
        }
        public void wake(long time) throws Exception { power.wake(time); }
        public void sleep(long time, DisplayStateSnapshot.Wakefulness target) throws Exception { power.sleep(time, target); }
        public void activity(long time) throws Exception { power.activityWithoutLights(time); }
        public Mutation preparePanel(String id, final DisplayStateSnapshot.Mode mode) throws Exception {
            if (!physicalIDs().contains(id)) throw new Failure("display_inventory_changed");
            long raw = Long.parseUnsignedLong(id);
            final IBinder token = useDisplayControl ? DisplayControl.getPhysicalDisplayToken(raw) : SurfaceControl.getPhysicalDisplayToken(raw);
            if (token == null) throw new Failure("display_token_missing");
            return new Mutation() { public void run() throws Exception {
                try { panelMode.invoke(null, token, powerMode(mode)); }
                catch (InvocationTargetException failed) {
                    Throwable cause = failed.getCause();
                    if (cause instanceof Exception) throw (Exception) cause;
                    if (cause instanceof Error) throw (Error) cause;
                    throw new ReflectiveOperationException("display_panel_invocation_failed", cause);
                }
            } };
        }
        private String dump(String[] fixedCommand, long deadline) throws Exception {
            if ((pendingDumpReader != null && pendingDumpReader.isAlive()) || (pendingDumpChild != null && pendingDumpChild.isAlive()))
                throw new Failure("display_previous_dump_still_pending");
            long remaining = deadline - uptimeMillis();
            if (remaining <= 0) throw new Failure("display_read_deadline");
            final Process child = new ProcessBuilder(fixedCommand).redirectErrorStream(true).start();
            pendingDumpChild = child;
            final ByteArrayOutputStream bytes = new ByteArrayOutputStream(); final IOException[] failure = new IOException[1];
            Thread reader = new Thread(new Runnable() { public void run() {
                try (InputStream input = child.getInputStream()) {
                    byte[] buffer = new byte[4096]; int count;
                    while ((count = input.read(buffer)) != -1) {
                        if (bytes.size() + count > DisplayStateSnapshot.MAX_DUMP_BYTES) throw new IOException("display_dump_limit");
                        bytes.write(buffer, 0, count);
                    }
                } catch (IOException error) { failure[0] = error; }
            } }, "gb-display-state-read");
            pendingDumpReader = reader; reader.setDaemon(true); reader.start();
            try {
                if (!child.waitFor(Math.min(remaining, 1500), TimeUnit.MILLISECONDS)) throw new Failure("display_dump_timeout");
                remaining = deadline - uptimeMillis();
                if (remaining <= 0) throw new Failure("display_read_deadline");
                reader.join(Math.min(remaining, 200));
                if (reader.isAlive() || failure[0] != null || child.exitValue() != 0) throw new Failure("display_dump_failed");
                return new String(bytes.toByteArray(), StandardCharsets.UTF_8);
            } finally {
                if (child.isAlive()) child.destroyForcibly();
                // A service can retain the duplicated dump descriptor after
                // dumpsys exits. Keep its reader/child identities until they
                // finish, so repeated failures cannot accumulate more work.
                if (!child.isAlive()) pendingDumpChild = null;
                if (!reader.isAlive()) pendingDumpReader = null;
            }
        }
    }
}
