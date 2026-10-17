package com.genymobile.scrcpy;

import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.net.Uri;
import android.os.Binder;
import android.os.Bundle;
import android.os.IBinder;
import android.os.Looper;
import android.os.Parcel;
import android.os.ParcelFileDescriptor;
import android.os.RemoteException;
import android.system.Os;
import android.system.OsConstants;
import com.genymobile.scrcpy.wrappers.ClipboardContentResolver;
import org.json.JSONArray;
import org.json.JSONObject;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.AtomicBoolean;

/** Shell-only, per-boot capability broker. No cross-UID socket listener or arbitrary commands.
 * Binder accepts Helper-created socket-pair endpoints only from the fixed Helper UID.
 * Private FD wire: u32BE UTF-8 JSON <=64KiB. First frame kind=owner|stream,
 * token=64lowerhex, boot_generation=UUID. Only fixed production Helper UID.
 * Owner EOF closes every lifetime pipe; fixed child wrappers restore/exit even
 * when this broker is SIGKILLed. Each child owns a separate copy of the JAR.
 */
public final class ShellCapabilityBridge implements AutoCloseable {
    interface VerifiedStartup { void run() throws Exception; }
    static void withVerifiedSource(File source, VerifiedStartup startup) throws Exception {
        try { startup.run(); } finally { source.delete(); }
    }
    static void awaitPhysicalRetirement(CountDownLatch retirement) {
        boolean interrupted = false;
        while (true) {
            try { retirement.await(); break; } catch (InterruptedException ignored) { interrupted = true; }
        }
        if (interrupted) Thread.currentThread().interrupt();
    }
    static final class BinderAdmission {
        private final int uid;
        BinderAdmission(int uid) { this.uid = uid; }
        void enforceCallingUID(int caller) { if (caller != uid) throw new SecurityException("shell_bridge_uid"); }
    }
    static final String BINDER_DESCRIPTOR = "com.xopmc.galaxybridge.shellbridge.v1";
    static final int OPEN_OWNER = 1, OPEN_STREAM = 2;
    static boolean credentialsMatch(String generation, String token, String suppliedGeneration, String suppliedToken) {
        return generation.equals(suppliedGeneration) && suppliedToken != null &&
            MessageDigest.isEqual(token.getBytes(StandardCharsets.US_ASCII), suppliedToken.getBytes(StandardCharsets.US_ASCII));
    }
    static void registerOwnedSocket(Set<Closeable> sockets, AtomicBoolean stopped, Closeable socket) throws IOException {
        synchronized (sockets) {
            // STOP marks stopped before taking this same monitor. A resource
            // is therefore either in its closed snapshot or rejected here.
            if (stopped.get()) { closeOwnedSocket(socket); throw new IOException("lease_stopped"); }
            sockets.add(socket);
        }
    }
    static void retireOwnedSockets(Set<Closeable> sockets) {
        synchronized (sockets) { for (Closeable socket : sockets) closeOwnedSocket(socket); sockets.clear(); }
    }
    interface SocketCloseAction { void run() throws Exception; }
    static void shutdownAndClose(SocketCloseAction shutdown, SocketCloseAction close) {
        try { shutdown.run(); } catch (Exception ignored) {}
        finally { try { close.run(); } catch (Exception ignored) {} }
    }
    interface StreamConnector { void connect() throws Exception; }
    static final class StreamOrder {
        private final List<String> types;
        private int next;
        private boolean connecting, stopped;
        StreamOrder(List<String> types) { this.types = new ArrayList<>(types); }
        void connect(String type, long timeoutMillis, StreamConnector connector) throws Exception {
            int position = types.indexOf(type);
            long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMillis);
            synchronized (this) {
                if (position < 0) throw new IOException("stream_not_ordered");
                while (!stopped && (position != next || connecting)) {
                    long remaining = deadline - System.nanoTime();
                    if (position < next || remaining <= 0) {
                        stop(); throw new IOException("stream_order_timeout");
                    }
                    TimeUnit.NANOSECONDS.timedWait(this, remaining);
                }
                if (stopped) throw new IOException("stream_order_stopped");
                connecting = true;
            }
            try {
                // Advance only after the real abstract socket connect returns.
                // Do not hold this monitor: STOP must close an in-flight socket.
                connector.connect();
                synchronized (this) {
                    if (stopped) throw new IOException("stream_order_stopped");
                    next++; connecting = false; notifyAll();
                }
            } catch (Exception failure) { stop(); throw failure; }
        }
        synchronized void stop() { stopped = true; notifyAll(); }
    }
    private static final int MAX_FRAME = 65536;
    static boolean compositeStopFlag(int operation, boolean present, Object value) {
        if (!present) return false;
        if (operation != 4 || !(value instanceof Boolean) || !((Boolean)value)) throw new IllegalArgumentException("display_stop_kind_invalid");
        return true;
    }

    static final class CompositeCommand {
        private static final Set<String> FIELDS = Collections.unmodifiableSet(new HashSet<>(
                Arrays.asList("action", "interactive", "panel_policy", "revision")));
        final int action, panelPolicy;
        final boolean interactive;
        final long revision;
        private CompositeCommand(int action, boolean interactive, int panelPolicy, long revision) {
            this.action = action; this.interactive = interactive; this.panelPolicy = panelPolicy; this.revision = revision;
        }
        static CompositeCommand parse(Map<String, Object> fields) {
            if (fields == null || !fields.keySet().equals(FIELDS) || !(fields.get("interactive") instanceof Boolean))
                throw new IllegalArgumentException("display_state_command_invalid");
            long action = integer(fields.get("action")), policy = integer(fields.get("panel_policy"));
            long revision = integer(fields.get("revision"));
            boolean interactive = (Boolean) fields.get("interactive");
            if (action < 0 || action > 2 || policy < 0 || policy > 2 || revision < 0
                    || (action == 2 ? revision == 0 : interactive || policy != 0 || revision != 0))
                throw new IllegalArgumentException("display_state_command_invalid");
            return new CompositeCommand((int) action, interactive, (int) policy, revision);
        }
        private static long integer(Object value) {
            if (!(value instanceof Integer) && !(value instanceof Long))
                throw new IllegalArgumentException("display_state_command_invalid");
            return ((Number) value).longValue();
        }
    }
    private static Map<String, Object> objectFields(Object raw) {
        if (!(raw instanceof Map)) throw new IllegalArgumentException("display_receipt_object");
        Map<?, ?> source = (Map<?, ?>) raw; Map<String, Object> result = new HashMap<>();
        for (Map.Entry<?, ?> field : source.entrySet()) {
            if (!(field.getKey() instanceof String)) throw new IllegalArgumentException("display_receipt_key");
            result.put((String) field.getKey(), field.getValue());
        }
        return result;
    }
    private static void exactFields(Map<String, Object> fields, String... expected) {
        if (!fields.keySet().equals(new HashSet<>(Arrays.asList(expected)))) throw new IllegalArgumentException("display_receipt_fields");
    }
    private static String strictText(Object value) {
        if (!(value instanceof String)) throw new IllegalArgumentException("display_receipt_text"); return (String) value;
    }
    private static boolean strictFlag(Object value) {
        if (!(value instanceof Boolean)) throw new IllegalArgumentException("display_receipt_flag"); return (Boolean) value;
    }
    private static String strictTime(Object raw, boolean positive) {
        String value = strictText(raw);
        if (!value.matches(positive ? "[1-9][0-9]{0,18}" : "0|[1-9][0-9]{0,18}")) throw new IllegalArgumentException("display_receipt_time");
        Long.parseLong(value); return value;
    }
    static final class CompositeSnapshot {
        final Map<String, DisplayStateSnapshot.Mode> panels;
        final String activeID;
        final boolean interactive;
        final DisplayStateSnapshot.Wakefulness group, global;
        final Map<String, String> times;
        CompositeSnapshot(Object raw) {
            Map<String, Object> fields = objectFields(raw);
            exactFields(fields, "panels", "activeID", "defaultInteractive", "defaultWakefulness", "globalWakefulness", "transitionScope",
                "lastGlobalWakeTime", "lastGlobalSleepTime", "defaultActivityTime", "defaultActivityNoChangeLightsTime");
            activeID = strictText(fields.get("activeID")); interactive = strictFlag(fields.get("defaultInteractive"));
            group = DisplayStateSnapshot.Wakefulness.valueOf(strictText(fields.get("defaultWakefulness")));
            global = DisplayStateSnapshot.Wakefulness.valueOf(strictText(fields.get("globalWakefulness")));
            if (!"GLOBAL".equals(fields.get("transitionScope")) || interactive != group.interactive()
                    || (interactive && !global.interactive()) || group.aggregateRank() > global.aggregateRank())
                throw new IllegalArgumentException("display_receipt_power");
            Object rawPanels = fields.get("panels");
            if (!(rawPanels instanceof List)) throw new IllegalArgumentException("display_receipt_panels");
            List<?> list = (List<?>) rawPanels;
            if (list.isEmpty() || list.size() > 8) throw new IllegalArgumentException("display_receipt_panels");
            Map<String, DisplayStateSnapshot.Mode> parsed = new HashMap<>();
            for (Object panel : list) {
                Map<String, Object> item = objectFields(panel); exactFields(item, "id", "mode");
                String id = strictText(item.get("id"));
                if (!DisplayStateSnapshot.validID(id) || parsed.put(id,
                        DisplayStateSnapshot.Mode.valueOf(strictText(item.get("mode")))) != null)
                    throw new IllegalArgumentException("display_receipt_panel_identity");
            }
            if (!parsed.containsKey(activeID)) throw new IllegalArgumentException("display_receipt_active_panel");
            panels = Collections.unmodifiableMap(parsed);
            Map<String, String> stamps = new HashMap<>();
            for (String key : Arrays.asList("lastGlobalWakeTime", "lastGlobalSleepTime", "defaultActivityTime", "defaultActivityNoChangeLightsTime"))
                stamps.put(key, strictTime(fields.get(key), false));
            times = Collections.unmodifiableMap(stamps);
        }
        boolean sameOwnedState(CompositeSnapshot other) {
            return other != null && panels.equals(other.panels) && activeID.equals(other.activeID)
                && interactive == other.interactive && group == other.group;
        }
        boolean sameSnapshot(CompositeSnapshot other) {
            return sameOwnedState(other) && global == other.global && times.equals(other.times);
        }
    }
    static final class CompositeReceipt {
        final int pid;
        final String start, event, state, error, reason;
        final long revision;
        final boolean ok, draining, settled;
        final CompositeSnapshot initial, current;
        private CompositeReceipt(Map<String, Object> fields) {
            exactFields(fields, "version", "event", "pid", "startTime", "revision", "state", "draining", "mutation_settled", "initial", "current", "ok", "error", "reason");
            long version = CompositeCommand.integer(fields.get("version")), rawPID = CompositeCommand.integer(fields.get("pid"));
            revision = CompositeCommand.integer(fields.get("revision"));
            if (version != 2 || rawPID <= 1 || rawPID > Integer.MAX_VALUE || revision < 0) throw new IllegalArgumentException("display_receipt_identity");
            pid = (int) rawPID; start = strictTime(fields.get("startTime"), true);
            event = strictText(fields.get("event")); state = strictText(fields.get("state")); error = strictText(fields.get("error"));
            reason = strictText(fields.get("reason"));
            ok = strictFlag(fields.get("ok")); draining = strictFlag(fields.get("draining")); settled = strictFlag(fields.get("mutation_settled"));
            if (!Arrays.asList("ready", "reply", "retired", "startup_failed").contains(event)
                    || !Arrays.asList("NOT_STARTED", "SNAPSHOTTED", "READY", "SUSPENDED", "RESTORED", "YIELDED_EXTERNAL", "YIELDED_ACTIVITY", "UNCONFIRMED").contains(state)
                    || !error.matches("[a-z0-9_]{0,96}") || !reason.matches("[a-z0-9_]{1,96}") || ok != error.isEmpty())
                throw new IllegalArgumentException("display_receipt_state");
            if (event.equals("startup_failed")) {
                if (!state.equals("NOT_STARTED") || ok || !draining || !settled || revision != 0
                        || fields.get("initial") != null || fields.get("current") != null || error.isEmpty() || !reason.equals("startup"))
                    throw new IllegalArgumentException("display_receipt_startup");
                initial = current = null;
            } else {
                if (state.equals("NOT_STARTED")) throw new IllegalArgumentException("display_receipt_startup");
                initial = new CompositeSnapshot(fields.get("initial")); current = new CompositeSnapshot(fields.get("current"));
                if (state.equals("RESTORED") && !current.sameOwnedState(initial)) throw new IllegalArgumentException("display_receipt_restoration");
                if (event.equals("ready")) header();
                if (event.equals("retired") && (!ok || !draining || !settled
                        || !Arrays.asList("RESTORED", "YIELDED_EXTERNAL", "YIELDED_ACTIVITY").contains(state)))
                    throw new IllegalArgumentException("display_receipt_terminal");
            }
        }
        static CompositeReceipt parse(Map<String, Object> value) { return new CompositeReceipt(value); }
        void header() {
            if (!event.equals("ready") || !state.equals("SNAPSHOTTED") || !ok || draining || !settled || revision != 0
                    || !initial.sameSnapshot(current) || !reason.equals("startup")) throw new IllegalArgumentException("display_receipt_header");
        }
        void sameOwner(CompositeReceipt header) {
            if (header == null || pid != header.pid || !start.equals(header.start) || initial == null || !initial.sameSnapshot(header.initial))
                throw new IllegalArgumentException("display_receipt_owner_changed");
        }
        void policy(CompositeReceipt header, CompositeCommand command) {
            sameOwner(header);
            if (command == null || command.action != 2 || !event.equals("reply") || !ok || !state.equals("READY") || draining || !settled
                    || revision != command.revision || !current.panels.keySet().equals(initial.panels.keySet()) || !current.activeID.equals(initial.activeID)
                    || (command.interactive && !current.interactive)) throw new IllegalArgumentException("display_receipt_policy");
            for (Map.Entry<String, DisplayStateSnapshot.Mode> panel : current.panels.entrySet()) {
                if (command.panelPolicy == 1 && panel.getValue() != DisplayStateSnapshot.Mode.OFF
                        || command.panelPolicy == 2 && panel.getValue() != (panel.getKey().equals(current.activeID) ? DisplayStateSnapshot.Mode.ON : DisplayStateSnapshot.Mode.OFF))
                    throw new IllegalArgumentException("display_receipt_panel_policy");
            }
        }
        void terminal(CompositeReceipt header, long confirmed, long attempted) {
            sameOwner(header);
            if (!event.equals("retired") || !ok || !draining || !settled || confirmed < 0 || attempted < confirmed || revision < confirmed || revision > attempted
                    || !Arrays.asList("RESTORED", "YIELDED_EXTERNAL", "YIELDED_ACTIVITY").contains(state))
                throw new IllegalArgumentException("display_receipt_terminal");
        }
    }
    /** Lease admission is distinct from the child's physical state machine. */
    static final class CompositeLeaseAdmission {
        private enum Phase { SNAPSHOT_PENDING, SNAPSHOTTED, POLICY, DRAINING }
        private static final class Entry {
            Phase phase = Phase.SNAPSHOT_PENDING;
            boolean policyAttempted;
            CompositeCommand lastPolicy;
        }
        private final int maximumIdentities;
        private final Map<String, Entry> active = new HashMap<>();
        private final Set<String> retired = new HashSet<>();
        CompositeLeaseAdmission(int maximumIdentities) {
            if (maximumIdentities < 1 || maximumIdentities > 65536) throw new IllegalArgumentException("display_owner_capacity");
            this.maximumIdentities = maximumIdentities;
        }
        private void valid(String lease) {
            if (!canonicalUUID(lease)) throw new IllegalArgumentException("display_owner_identity");
        }
        private Entry entry(String lease) {
            valid(lease); Entry value = active.get(lease);
            if (value == null) throw new IllegalArgumentException("display_owner_unknown");
            return value;
        }
        private void capacity() {
            // Tombstones are never evicted within a broker generation. Reject
            // further admission rather than resurrect a previously stopped UUID.
            if (active.size() + retired.size() >= maximumIdentities) throw new IllegalArgumentException("display_owner_capacity");
        }
        synchronized boolean reserveSnapshot(String lease) {
            valid(lease);
            if (retired.contains(lease)) throw new IllegalArgumentException("display_owner_retired");
            Entry existing = active.get(lease);
            if (existing != null) {
                if (existing.phase != Phase.SNAPSHOT_PENDING && existing.phase != Phase.SNAPSHOTTED)
                    throw new IllegalArgumentException("display_owner_cannot_rebase");
                return false;
            }
            capacity(); active.put(lease, new Entry()); return true;
        }
        synchronized void snapshotReady(String lease) {
            Entry value = entry(lease);
            if (value.phase != Phase.SNAPSHOT_PENDING) throw new IllegalArgumentException("display_owner_not_pending");
            value.phase = Phase.SNAPSHOTTED;
        }
        synchronized void requireStatus(String lease) {
            Entry value = entry(lease);
            if (value.phase != Phase.SNAPSHOTTED && value.phase != Phase.POLICY)
                throw new IllegalArgumentException("display_owner_not_ready");
        }
        synchronized void admitApply(String lease, CompositeCommand policy) {
            requireStatus(lease); Entry value = entry(lease);
            if (policy == null || policy.action != 2) throw new IllegalArgumentException("display_owner_policy_required");
            CompositeCommand previous = value.lastPolicy;
            if (previous != null && (policy.revision < previous.revision || (policy.revision == previous.revision
                    && (policy.interactive != previous.interactive || policy.panelPolicy != previous.panelPolicy))))
                throw new IllegalArgumentException("display_owner_revision");
            // This happens before I/O, including a write that partially succeeds
            // and then throws. Neither drain nor a lost ACK may clear the fact.
            value.policyAttempted = true; value.lastPolicy = policy; value.phase = Phase.POLICY;
        }
        synchronized void beginRetirement(String lease) {
            valid(lease); if (retired.contains(lease)) return;
            Entry value = active.get(lease);
            if (value != null) value.phase = Phase.DRAINING;
            else { capacity(); retired.add(lease); } // Seal an overtaken SNAPSHOT too.
        }
        /** Caller must first prove child/mutation/resource retirement. This
         * admission book does not itself provide any physical retirement proof. */
        synchronized void finishRetirement(String lease) {
            valid(lease); if (retired.contains(lease)) return;
            Entry value = entry(lease);
            if (value.phase != Phase.DRAINING) throw new IllegalArgumentException("display_owner_not_draining");
            active.remove(lease); retired.add(lease);
        }
        synchronized boolean mayHaveMutated(String lease) { return entry(lease).policyAttempted; }
        synchronized boolean isRetired(String lease) { valid(lease); return retired.contains(lease); }
        synchronized int retainedCount() { return active.size() + retired.size(); }
    }
    static final class CompositeRetirementProbe {
        interface Factory { DisplayStateOwnership.Backend open() throws Exception; }
        private final Factory factory;
        private DisplayStateOwnership.Backend backend;
        private Exception initializationFailure;
        private FutureTask<DisplayStateOwnership.Backend> initialization;
        private final long initializationTimeoutMillis;
        CompositeRetirementProbe(Factory factory) { this(factory, 2500); }
        CompositeRetirementProbe(Factory factory, long timeoutMillis) {
            if (factory == null || timeoutMillis <= 0 || timeoutMillis > 2500) throw new IllegalArgumentException();
            this.factory = factory; initializationTimeoutMillis = timeoutMillis;
        }
        synchronized DisplayStateSnapshot read() throws Exception {
            if (initializationFailure != null) throw initializationFailure;
            if (backend == null) {
                if (initialization == null) {
                    initialization = new FutureTask<>(() -> {
                        DisplayStateOwnership.Backend value = factory.open();
                        if (value == null) throw new IOException("display_proof_backend_unavailable");
                        return value;
                    });
                    Thread worker = new Thread(initialization, "gb-display-proof-initialization"); worker.setDaemon(true); worker.start();
                }
                try { backend = initialization.get(initializationTimeoutMillis, TimeUnit.MILLISECONDS); }
                catch (TimeoutException pending) { throw new IOException("display_proof_initialization_pending"); }
                catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); throw new IOException("display_proof_initialization_interrupted"); }
                catch (ExecutionException failed) {
                    Throwable cause = failed.getCause();
                    initializationFailure = cause instanceof Exception ? (Exception)cause : new IOException("display_proof_initialization_failed", cause);
                    throw initializationFailure;
                }
                // Never cancel/relaunch a timed-out initializer. Once it
                // settles, the retained backend takes a fresh bounded sample.
            }
            return backend.read();
        }
    }
    static final class CompositeRetirementStore {
        private final Map<String, String> receipts = new HashMap<>();
        synchronized void remember(String lease, String receipt) {
            if (!canonicalUUID(lease) || receipt == null || receipt.isEmpty() || receipt.length() > MAX_FRAME) throw new IllegalArgumentException();
            if (receipts.size() >= 4096 && !receipts.containsKey(lease)) throw new IllegalArgumentException("display_retirement_capacity");
            String prior = receipts.get(lease);
            if (prior != null && !prior.equals(receipt)) throw new IllegalArgumentException("display_retirement_rebase");
            receipts.put(lease, receipt);
        }
        synchronized String get(String lease) { return receipts.get(lease); }
    }
    private final String token, generation, activationID, helperPackage;
    private final int helperUID;
    private final BinderAdmission admission;
    private final Object admissionLock = new Object();
    private final Binder bridgeBinder;
    private final byte[] jar;
    private final String runtimeSHA256;
    private final File sourceJar, directory;
    private final Map<String, Lease> leases = new LinkedHashMap<>();
    private final Map<String, String> receipts = new LinkedHashMap<>();
    private final CompositeLeaseAdmission compositeAdmission = new CompositeLeaseAdmission(4096);
    private final Map<String, JSONObject> compositeProofs = new HashMap<>();
    private final CompositeRetirementProbe compositeProbe = new CompositeRetirementProbe(DisplayStateRuntimeBackend::open);
    private final CompositeRetirementStore compositeRetiredResponses = new CompositeRetirementStore();
    private final Set<FDChannel> clients = Collections.synchronizedSet(new HashSet<>());
    private final AtomicBoolean closed = new AtomicBoolean();
    private final AtomicBoolean ownerAccepted = new AtomicBoolean();
    private final CountDownLatch physicallyClosed = new CountDownLatch(1);
    private volatile FDChannel owner;
    private volatile IBinder helperLifetime;
    private final IBinder.DeathRecipient helperDeath = this::close;
    private final ThreadPoolExecutor workers = new ThreadPoolExecutor(0, 40, 10, TimeUnit.SECONDS,
        new SynchronousQueue<>(), task -> { Thread t = new Thread(task, "gb-shell-broker"); t.setDaemon(true); return t; });
    private final ScheduledExecutorService timer = Executors.newSingleThreadScheduledExecutor(task -> {
        Thread t = new Thread(task, "gb-shell-deadline"); t.setDaemon(true); return t;
    });

    public static void main(String[] args) throws Exception {
        if (args.length != 5 || !Arrays.asList("production", "internal").contains(args[4]) || !args[0].matches("[A-Za-z0-9_.-]{1,100}") || !args[1].matches("[a-f0-9]{64}") ||
            !canonicalUUID(args[2]) || !args[3].matches("[a-f0-9]{64}") || android.os.Process.myUid() != 2000) return;
        File source = new File(System.getProperty("java.class.path").split(File.pathSeparator)[0]);
        String expectedSource = "/data/local/tmp/galaxybridge-shell-" + args[2] + ".jar";
        if (!source.getAbsolutePath().equals(expectedSource) || !source.getCanonicalPath().equals(expectedSource) ||
            !source.isFile() || source.length() > 4 * 1024 * 1024) return;
        byte[] jar = Files.readAllBytes(source.toPath());
        if (!hex(MessageDigest.getInstance("SHA-256").digest(jar)).equals(args[3])) return;
        // Cleanup authority begins only after exact generation path and bytes
        // are verified. Every subsequent pre-bridge failure owns this file.
        withVerifiedSource(source, () -> {
            detachSession();
            if (Looper.myLooper() == null) Looper.prepare();
            Workarounds.apply();
            String helperPackage = args[4].equals("internal") ? "com.xopmc.galaxybridge.internal" : "com.xopmc.galaxybridge";
            int uid = packageUID(helperPackage);
            if (uid < 10000) return;
            FileDescriptor descriptor = Os.open("/data/local/tmp/galaxybridge-shell-owner.lock", OsConstants.O_CREAT | OsConstants.O_RDWR | OsConstants.O_NOFOLLOW, 0600);
            try (FileOutputStream file = new FileOutputStream(descriptor);
                 java.nio.channels.FileLock lifetime = file.getChannel().tryLock()) {
                if (lifetime == null || ownedOrphans()) return;
                try (ShellCapabilityBridge bridge = new ShellCapabilityBridge(args[0], args[1], args[2], uid, helperPackage, source, jar)) {
                    try {
                        Runtime.getRuntime().addShutdownHook(new Thread(bridge::close, "gb-shell-shutdown"));
                        bridge.run();
                    } finally {
                        try { bridge.close(); }
                        finally { awaitPhysicalRetirement(bridge.physicallyClosed); }
                    }
                }
            }
        });
    }

    private ShellCapabilityBridge(String activationID, String token, String generation, int uid, String helperPackage, File source, byte[] jar) throws Exception {
        this.token = token; this.generation = generation; helperUID = uid; sourceJar = source; this.jar = jar;
        runtimeSHA256 = hex(MessageDigest.getInstance("SHA-256").digest(jar));
        this.activationID = activationID; this.helperPackage = helperPackage; admission = new BinderAdmission(uid);
        directory = new File("/data/local/tmp/galaxybridge-shell-" + generation);
        if (!directory.mkdir()) throw new IOException("owned_directory_unavailable");
        Os.chmod(directory.getPath(), 0700);
        bridgeBinder = new BridgeBinder();
        timer.schedule(() -> { if (owner == null) close(); }, 10, TimeUnit.SECONDS);
    }

    private void run() {
        try {
            Bundle extras = new Bundle(); extras.putBinder("bridge", bridgeBinder);
            extras.putString("boot_generation", generation); extras.putString("token", token); extras.putString("activation_id", activationID);
            // The upstream FakeContext resolver has no unstable acquisition and
            // does not release external leases. Use the existing balanced
            // shell-attributed resolver for this fixed-authority call.
            Bundle receipt = new ClipboardContentResolver(FakeContext.get()).call(
                Uri.parse("content://" + helperPackage + ".shellbridge"), "attach", null, extras);
            if (receipt == null || !receipt.getBoolean("available", false) || !generation.equals(receipt.getString("boot_generation")) ||
                !"ready".equals(receipt.getString("state"))) close();
        } catch (Exception unavailable) {
            close();
        }
        // Keep the ownership lock until child/cleanup retirement is proven.
        awaitPhysicalRetirement(physicallyClosed);
    }

    private final class BridgeBinder extends Binder {
        BridgeBinder() { attachInterface(null, BINDER_DESCRIPTOR); }
        @Override protected boolean onTransact(int code, Parcel data, Parcel reply, int flags) throws RemoteException {
            // This MUST precede interface-token and all attacker-controlled
            // Parcel reads, including unsupported transaction handling.
            admission.enforceCallingUID(Binder.getCallingUid());
            if (code == IBinder.INTERFACE_TRANSACTION) { reply.writeString(BINDER_DESCRIPTOR); return true; }
            if (code != OPEN_OWNER && code != OPEN_STREAM) return false;
            data.enforceInterface(BINDER_DESCRIPTOR);
            String requestedGeneration = data.readString(), requestedToken = data.readString();
            if (!credentialsMatch(generation, token, requestedGeneration, requestedToken))
                throw new SecurityException("shell_bridge_credentials");
            boolean isOwner = code == OPEN_OWNER;
            IBinder lifetime = isOwner ? data.readStrongBinder() : null;
            String streamID = isOwner ? "" : data.readString();
            if ((isOwner && lifetime == null) || (!isOwner && !validStreamID(streamID)))
                throw new SecurityException("shell_bridge_arguments");
            ParcelFileDescriptor supplied = null;
            FDChannel channel = null;
            Lease lease = null;
            boolean reservedOwner = false;
            try {
                synchronized (admissionLock) {
                    if (closed.get()) throw new IOException("owner_closed");
                    if (isOwner) {
                        if (!ownerAccepted.compareAndSet(false, true)) throw new IOException("owner_already_open");
                        reservedOwner = true;
                        lifetime.linkToDeath(helperDeath, 0); helperLifetime = lifetime;
                    } else {
                        if (owner == null) throw new IOException("owner_unavailable");
                        String leaseID = streamID.substring(0, 36), type = streamID.substring(37);
                        synchronized (ShellCapabilityBridge.this) { lease = leases.get(leaseID); }
                        if (lease == null || !lease.policy.streams().contains(streamID)) throw new IOException("stream_unavailable");
                        synchronized (lease) { if (lease.stopped.get() || !lease.opened.add(type)) throw new IOException("stream_already_open"); }
                    }
                    // The Helper creates both endpoints in its own SELinux
                    // domain, retaining the endpoint on which it sets timeouts.
                    // Read/adopt no FD until caller, credentials and lease/type
                    // admission above have succeeded.
                    supplied = ParcelFileDescriptor.CREATOR.createFromParcel(data);
                    if (supplied == null || data.dataAvail() != 0 || !isStreamSocket(supplied.getFileDescriptor()))
                        throw new IOException("stream_socket_required");
                    channel = new FDChannel(supplied); supplied = null; clients.add(channel);
                    if (isOwner) owner = channel;
                    else registerOwnedSocket(lease.sockets, lease.stopped, channel);
                    FDChannel accepted = channel; Lease acceptedLease = lease; String declaredStream = streamID;
                    workers.execute(() -> handle(accepted, isOwner, declaredStream, acceptedLease));
                    reply.writeNoException();
                }
                return true;
            } catch (Exception unavailable) {
                if (channel != null) { clients.remove(channel); channel.close(); }
                if (reservedOwner) close();
                throw new IllegalStateException("shell_bridge_unavailable");
            } finally {
                // A rejected descriptor is only closed, never shut down: it
                // has not passed admission into this broker's owned channels.
                if (supplied != null) try { supplied.close(); } catch (IOException ignored) {}
            }
        }
    }

    private void handle(FDChannel socket, boolean ownsLifetime, String declaredStream, Lease lease) {
        ScheduledFuture<?> admissionDeadline = timer.schedule(socket::close, 3, TimeUnit.SECONDS);
        try {
            JSONObject hello = read(socket.getInputStream());
            if (!credentialsMatch(generation, token, hello.optString("boot_generation"), hello.optString("token"))) return;
            String kind = hello.optString("kind");
            if (ownsLifetime && kind.equals("owner")) {
                admissionDeadline.cancel(false);
                write(socket.getOutputStream(), result("", "", "ready", "", Collections.emptyList()));
                while (!closed.get()) {
                    JSONObject request = read(socket.getInputStream());
                    write(socket.getOutputStream(), command(request));
                }
            } else if (!ownsLifetime && kind.equals("stream") && owner != null && !closed.get() &&
                declaredStream.equals(hello.optString("lease_id") + "/" + hello.optString("stream_type"))) {
                admissionDeadline.cancel(false); stream(socket, hello, lease);
            }
        } catch (Exception ignored) {
            // Never log token, clipboard, credentials, process output, or remote JSON.
        } finally {
            admissionDeadline.cancel(false);
            clients.remove(socket); closeSocket(socket);
            if (ownsLifetime) close();
        }
    }

    /** Separate stream duplicates avoid two Java stream objects sharing close
     * ownership of a single descriptor. Shutdown the socket before closing any
     * duplicate so blocking reads/writes cannot retain the owner indefinitely. */
    private static final class FDChannel implements Closeable {
        final ParcelFileDescriptor descriptor;
        final InputStream input;
        final OutputStream output;
        final AtomicBoolean closed = new AtomicBoolean();
        FDChannel(ParcelFileDescriptor descriptor) throws Exception {
            this.descriptor = descriptor;
            FileInputStream openedInput = null;
            try {
                openedInput = new FileInputStream(Os.dup(descriptor.getFileDescriptor()));
                output = new FileOutputStream(Os.dup(descriptor.getFileDescriptor()));
                input = openedInput;
            } catch (Exception failure) {
                if (openedInput != null) try { openedInput.close(); } catch (IOException ignored) {}
                descriptor.close(); throw failure;
            }
        }
        InputStream getInputStream() { return input; }
        OutputStream getOutputStream() { return output; }
        @Override public void close() {
            if (!closed.compareAndSet(false, true)) return;
            shutdownAndClose(() -> Os.shutdown(descriptor.getFileDescriptor(), OsConstants.SHUT_RDWR), () -> {
                try { input.close(); }
                finally { try { output.close(); } finally { descriptor.close(); } }
            });
        }
    }

    private synchronized JSONObject command(JSONObject request) throws Exception {
        if (closed.get()) throw new IOException("owner_closed");
        String id = request.optString("request_id"), leaseID = request.optString("lease_id");
        if (!canonicalUUID(id) || !generation.equals(request.optString("boot_generation")))
            return result(id, leaseID, "failed", "invalid_request", Collections.emptyList());
        Set<String> allowed = new HashSet<>(Arrays.asList("request_id", "lease_id", "boot_generation", "operation", "options", "power_on", "retirement", "display_state", "display_state_stop"));
        for (Iterator<String> keys = request.keys(); keys.hasNext();) if (!allowed.contains(keys.next()))
            return result(id, leaseID, "failed", "unsupported_field", Collections.emptyList());
        // Same request UUID has one exact body and outcome. Different bodies
        // never execute; timeout handling on Helper closes this lifetime owner.
        String fingerprint = hex(MessageDigest.getInstance("SHA-256").digest(request.toString().getBytes(StandardCharsets.UTF_8)));
        String prior = receipts.get(id);
        if (prior != null) {
            JSONObject recorded = new JSONObject(prior);
            return fingerprint.equals(recorded.getString("fingerprint")) ? recorded.getJSONObject("result") :
                result(id, leaseID, "failed", "request_id_reused", Collections.emptyList());
        }
        JSONObject response;
        try {
            Object rawOperation = request.get("operation");
            if (!(rawOperation instanceof Integer) && !(rawOperation instanceof Long)) throw new IllegalArgumentException();
            long operationValue = ((Number) rawOperation).longValue();
            if (operationValue < 0 || operationValue > 8 || operationValue == 5) throw new IllegalArgumentException();
            int operation = (int) operationValue;
            boolean compositeStop = compositeStopFlag(operation, request.has("display_state_stop"), request.opt("display_state_stop"));
            if (operation != 6 && operation != 7 && request.has("retirement")) throw new IllegalArgumentException();
            if (operation != 8 && request.has("display_state")) throw new IllegalArgumentException();
            if (operation == 6 || operation == 7) {
                if (!leaseID.isEmpty() || request.optBoolean("power_on")) throw new IllegalArgumentException();
                JSONObject raw = request.getJSONObject("retirement");
                Map<String, Object> fields = new HashMap<>();
                for (Iterator<String> keys = raw.keys(); keys.hasNext();) { String key = keys.next(); fields.put(key, raw.get(key)); }
                RetirementQuery query = RetirementQuery.parse(fields, operation == 7);
                JSONObject proof;
                if (operation == 7) {
                    confirmControllerAbsent(query.pid, query.startTicks, () -> readControllerStat(query.pid));
                    boolean removed = releasePrivacyResource(new File("/data/local/tmp"), query.resourceID, query.resourceSHA, jar);
                    proof = baseRetirementProof(query).put("absent", true).put("resource_removed", removed);
                } else proof = retirementProof(query);
                response = result(id, leaseID, operation == 7 ? "resources_released" : query.kind == 0 ? "retirement_supported" : "retired", "", Collections.emptyList())
                    .put("retirement_proof", proof);
            } else if (operation == 8) {
                if (request.has("options") || request.optBoolean("power_on") || !request.has("display_state")) throw new IllegalArgumentException();
                JSONObject rawState = request.getJSONObject("display_state");
                Map<String, Object> fields = new HashMap<>();
                for (Iterator<String> keys = rawState.keys(); keys.hasNext();) { String key = keys.next(); fields.put(key, rawState.get(key)); }
                response = compositeCommand(id, leaseID, CompositeCommand.parse(fields));
            } else if (operation == 0) {
                if (!leaseID.isEmpty() && !canonicalUUID(leaseID)) throw new IllegalArgumentException();
                if (!leaseID.isEmpty() && leases.containsKey(leaseID) && leases.get(leaseID).policy.operation == 8)
                    throw new IllegalArgumentException("typed_display_state_required");
                response = result(id, leaseID, !leaseID.isEmpty() && !leases.containsKey(leaseID) ? "stopped" :
                    readOnlyPanelStatus(() -> panelState()), "", Collections.emptyList());
            } else if (operation == 4) {
                if (!canonicalUUID(leaseID)) throw new IllegalArgumentException();
                Lease lease = leases.get(leaseID);
                if (lease != null) {
                    if ((lease.policy.operation == 8) != compositeStop) throw new IllegalArgumentException("display_stop_kind_mismatch");
                    if (lease.policy.operation == 8) compositeAdmission.beginRetirement(leaseID);
                    lease.retire();
                    if (lease.policy.operation == 8) {
                        response = rememberCompositeRetirement(id, leaseID, lease);
                        compositeAdmission.finishRetirement(leaseID);
                    } else response = result(id, leaseID, "stopped", "", Collections.emptyList());
                    leases.remove(leaseID);
                } else if (compositeRetiredResponses.get(leaseID) != null) {
                    if (!compositeStop) throw new IllegalArgumentException("display_stop_kind_mismatch");
                    response = new JSONObject(compositeRetiredResponses.get(leaseID)).put("request_id", id);
                } else {
                    // Seal an overtaken SNAPSHOT; unknown STOP is not a v2
                    // physical retirement receipt and never carries an ACK.
                    compositeAdmission.beginRetirement(leaseID);
                    response = compositeStop ? rememberCompositeRetirement(id, leaseID, null)
                        : result(id, leaseID, "stopped", "", Collections.emptyList());
                }
            } else {
                JSONObject raw = request.optJSONObject("options");
                Map<String, Object> options = new HashMap<>();
                if (raw != null) for (Iterator<String> keys = raw.keys(); keys.hasNext();) { String key = keys.next(); options.put(key, raw.get(key)); }
                Policy policy = Policy.parse(operation, leaseID, options);
                Lease lease = leases.get(leaseID);
                if (lease == null) {
                    if (leases.size() >= 8) throw new IOException("capacity");
                    if (compositeAdmission.isRetired(leaseID)) throw new IOException("display_owner_retired");
                    if (operation == 3) for (Lease existing : leases.values())
                        if (existing.policy.operation == 3 || existing.policy.operation == 8) throw new IOException("panel_owner_busy");
                    for (Lease existing : leases.values()) if (existing.policy.scid == policy.scid && operation != 3) throw new IOException("scid_reused");
                    lease = new Lease(policy); leases.put(leaseID, lease);
                    try { lease.start(); } catch (Exception failure) { lease.retire(); leases.remove(leaseID); throw failure; }
                } else if (lease.stopped.get() || !lease.policy.equivalent(policy)) throw new IllegalArgumentException();
                if (operation == 3) lease.power(request.optBoolean("power_on"));
                response = result(id, leaseID, operation == 3 ? lease.panelCurrentState : "ready", "", policy.streams());
            }
        } catch (Exception failure) { response = result(id, leaseID, "failed", "shell_operation_failed", Collections.emptyList()); }
        if (receipts.size() >= 512) receipts.remove(receipts.keySet().iterator().next());
        receipts.put(id, new JSONObject().put("fingerprint", fingerprint).put("result", response).toString());
        return response;
    }

    private static Object jsonValue(Object value) throws Exception {
        if (value == JSONObject.NULL) return null;
        if (value instanceof JSONObject) return jsonFields((JSONObject)value);
        if (value instanceof JSONArray) {
            JSONArray array = (JSONArray)value; List<Object> result = new ArrayList<>();
            for (int i = 0; i < array.length(); ++i) result.add(jsonValue(array.get(i)));
            return result;
        }
        return value;
    }
    private static Map<String, Object> jsonFields(JSONObject object) throws Exception {
        Map<String, Object> result = new HashMap<>();
        for (Iterator<String> keys = object.keys(); keys.hasNext();) { String key = keys.next(); result.put(key, jsonValue(object.get(key))); }
        return result;
    }
    /** Called only after physical/resource retirement, or before any child was
     * created. Preserve negative startup evidence as well as terminal ACKs. */
    private JSONObject rememberCompositeRetirement(String requestID, String leaseID, Lease lease) throws Exception {
        JSONObject response = result(requestID, leaseID, lease == null || lease.compositeHeader == null
            ? "display_state_not_started" : "display_state_retired", "", Collections.emptyList());
        if (lease != null) {
            JSONObject acknowledgement = lease.compositeTerminalJSON != null ? lease.compositeTerminalJSON : lease.compositeStartupFailure;
            if (acknowledgement != null) response.put("display_state_acknowledgement", acknowledgement);
            if (lease.compositeHeader != null) response.put("retirement_proof", lease.compositeProof());
        }
        // Cache before removing the lease; retries never have to invent a
        // Boolean/v1 proof or perform another possibly unavailable read.
        compositeRetiredResponses.remember(leaseID, response.toString());
        return response;
    }
    private JSONObject compositeCommand(String requestID, String leaseID, CompositeCommand command) throws Exception {
        Lease lease = leases.get(leaseID);
        if (lease != null && lease.policy.operation != 8) throw new IOException("display_owner_lease_kind");
        if (command.action == 0) {
            boolean reserved = compositeAdmission.reserveSnapshot(leaseID);
            if (reserved) {
                try {
                    if (leases.size() >= 8) throw new IOException("capacity");
                    for (Lease existing : leases.values()) if (existing.policy.operation == 3 || existing.policy.operation == 8)
                        throw new IOException("display_owner_busy");
                    lease = new Lease(Policy.parse(8, leaseID, Collections.emptyMap())); leases.put(leaseID, lease);
                    lease.start(); compositeAdmission.snapshotReady(leaseID);
                } catch (Exception failed) {
                    compositeAdmission.beginRetirement(leaseID);
                    if (lease == null) { rememberCompositeRetirement(requestID, leaseID, null); compositeAdmission.finishRetirement(leaseID); }
                    else try {
                        lease.retire(); rememberCompositeRetirement(requestID, leaseID, lease);
                        compositeAdmission.finishRetirement(leaseID); leases.remove(leaseID);
                    } catch (Exception pending) { /* Retain owner and physical cleanup fence. */ }
                    throw failed;
                }
            }
            if (lease == null || lease.policy.operation != 8 || lease.stopped.get() || lease.compositeHeaderJSON == null)
                throw new IOException("display_owner_unknown");
            return result(requestID, leaseID, "display_state_snapshotted", "", Collections.emptyList())
                .put("display_state_acknowledgement", lease.compositeHeaderJSON);
        }
        compositeAdmission.requireStatus(leaseID);
        if (lease == null || lease.policy.operation != 8 || lease.stopped.get()) throw new IOException("display_owner_unknown");
        if (command.action == 2) compositeAdmission.admitApply(leaseID, command);
        JSONObject acknowledgement = lease.composite(command);
        return result(requestID, leaseID, "display_state_reply", "", Collections.emptyList())
            .put("display_state_acknowledgement", acknowledgement);
    }

    private void stream(FDChannel remote, JSONObject request, Lease lease) throws Exception {
        String leaseID = request.optString("lease_id"), type = request.optString("stream_type");
        String streamID = leaseID + "/" + type;
        if (lease == null || !validStreamID(streamID) || !lease.policy.streams().contains(streamID)) return;
        synchronized (lease) { if (lease.stopped.get()) return; }
        if (type.equals("log")) {
            write(remote.getOutputStream(), result("", leaseID, "stream_ready", "", Collections.singletonList(streamID)));
            while (!closed.get() && !lease.stopped.get()) {
                byte[] line = lease.announcements.poll(1, TimeUnit.SECONDS);
                if (line != null) { remote.getOutputStream().write(line); remote.getOutputStream().flush(); }
            }
            return;
        }
        LocalSocket child = new LocalSocket();
        registerOwnedSocket(lease.sockets, lease.stopped, child);
        try {
            String socketName = type.equals("clipboard") ? lease.clipboardName() : lease.socketName();
            if (type.equals("clipboard")) child.connect(new LocalSocketAddress(socketName, LocalSocketAddress.Namespace.ABSTRACT));
            else lease.streamOrder.connect(type, 8000,
                () -> child.connect(new LocalSocketAddress(socketName, LocalSocketAddress.Namespace.ABSTRACT)));
            write(remote.getOutputStream(), result("", leaseID, "stream_ready", "", Collections.singletonList(streamID)));
            if (type.equals("control") || type.equals("clipboard")) {
                workers.execute(() -> { try { copy(remote.getInputStream(), child.getOutputStream()); }
                    catch (Exception ignored) {} finally { closeSocket(child); closeSocket(remote); } });
            }
            copy(child.getInputStream(), remote.getOutputStream());
        } finally { closeSocket(child); closeSocket(remote); }
    }

    private JSONObject result(String id, String lease, String state, String error, List<String> streams) throws Exception {
        return new JSONObject().put("request_id", id).put("lease_id", lease).put("boot_generation", generation)
            .put("available", true).put("state", state).put("error_code", error).put("stream_ids", new JSONArray(streams))
            .put("runtime_sha256", runtimeSHA256);
    }

    private final class Lease {
        final Policy policy;
        final List<Process> children = new ArrayList<>();
        final List<File> jars = new ArrayList<>();
        final Set<String> opened = ConcurrentHashMap.newKeySet();
        final Set<Closeable> sockets = Collections.synchronizedSet(new HashSet<>());
        final ArrayBlockingQueue<byte[]> announcements = new ArrayBlockingQueue<>(8);
        final AtomicBoolean stopped = new AtomicBoolean();
        final StreamOrder streamOrder;
        Process panel;
        final ArrayBlockingQueue<String> panelReplies = new ArrayBlockingQueue<>(4);
        volatile boolean panelReplyOverflow;
        Map<String, Boolean> initialPanels;
        int panelPID;
        String panelStartTime;
        String panelCurrentState;
        boolean panelFailureRestored;
        Process compositeChild;
        Thread compositeReader;
        final ArrayBlockingQueue<JSONObject> compositeReplies = new ArrayBlockingQueue<>(8);
        volatile boolean compositeReplyInvalid;
        volatile CompositeReceipt compositeHeader;
        volatile JSONObject compositeHeaderJSON, compositeStartupFailure, compositeTerminalJSON;
        JSONObject compositePhysicalProof;
        volatile long compositeConfirmedRevision, compositeAttemptedRevision;
        Lease(Policy policy) {
            this.policy = policy;
            streamOrder = new StreamOrder(policy.operation == 2 ? Collections.singletonList("control") :
                policy.audio ? Arrays.asList("video", "audio", "control") : Arrays.asList("video", "control"));
        }
        String socketName() { return String.format(Locale.ROOT, "scrcpy_%08x", policy.scid); }
        String clipboardName() { return String.format(Locale.ROOT, "gb_clip_%08x", policy.scid); }
        void start() throws Exception {
            if (policy.operation == 8) {
                compositeChild = spawn("display-state", new String[] {"--owner-lease"});
                JSONObject startup = compositeReply();
                CompositeReceipt receipt = CompositeReceipt.parse(jsonFields(startup)); receipt.header();
                if (compositeHeader == null) throw new IOException("display_header_unavailable");
            } else if (policy.operation == 3) {
                panel = spawn("panel", new String[0]);
                panelReply(); // The child owns the exact mixed physical snapshot.
            } else {
                spawn("scrcpy", policy.serverArguments());
                if (policy.operation == 2) spawn("clipboard", new String[] { clipboardName() });
                long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(8);
                while (true) {
                    String unix = new String(Files.readAllBytes(new File("/proc/net/unix").toPath()), StandardCharsets.UTF_8);
                    boolean serverReady = false, clipboardReady = policy.operation != 2;
                    for (String line : unix.split("\n")) {
                        String[] fields = line.trim().split("\\s+");
                        if (fields.length > 0 && fields[fields.length - 1].equals("@" + socketName())) serverReady = true;
                        if (fields.length > 0 && fields[fields.length - 1].equals("@" + clipboardName())) clipboardReady = true;
                    }
                    if (serverReady && clipboardReady) break;
                    if (System.nanoTime() >= deadline) throw new IOException("child_socket_timeout");
                    for (Process child : children) if (!child.isAlive()) throw new IOException("child_failed");
                    Thread.sleep(40);
                }
            }
        }
        Process spawn(String mode, String[] arguments) throws Exception {
            File owned = new File(directory, policy.lease + "-" + mode + ".jar");
            Files.write(owned.toPath(), jar, java.nio.file.StandardOpenOption.CREATE_NEW);
            Os.chmod(owned.getPath(), 0600); jars.add(owned);
            List<String> args = new ArrayList<>(Arrays.asList("/system/bin/app_process", "/", "com.genymobile.scrcpy.ShellCapabilityBridge$ChildMain", mode));
            args.addAll(Arrays.asList(arguments));
            ProcessBuilder builder = new ProcessBuilder(args); builder.environment().put("CLASSPATH", owned.getPath());
            if (mode.equals("panel") || mode.equals("display-state")) builder.redirectError(new File("/dev/null"));
            else builder.redirectErrorStream(true);
            Process child = builder.start(); children.add(child);
            Thread drain = new Thread(() -> drainAnnouncements(child, mode), "gb-shell-owned-output");
            if (mode.equals("display-state")) compositeReader = drain;
            drain.setDaemon(true); drain.start();
            timer.schedule(() -> { if (opened.isEmpty() && !stopped.get() && policy.operation != 3 && policy.operation != 8) {
                synchronized (ShellCapabilityBridge.this) { try { retire(); leases.remove(policy.lease); } catch (Exception ignored) {} }
            } }, 15, TimeUnit.SECONDS);
            return child;
        }
        JSONObject compositeReply() throws Exception {
            JSONObject reply = compositeReplies.poll(8, TimeUnit.SECONDS);
            if (reply == null || compositeReplyInvalid) throw new IOException("display_reply_unavailable");
            return reply;
        }
        JSONObject composite(CompositeCommand command) throws Exception {
            if (compositeChild == null || !compositeChild.isAlive() || compositeHeader == null || compositeReplyInvalid)
                throw new IOException("display_owner_unavailable");
            DataOutputStream output = new DataOutputStream(compositeChild.getOutputStream());
            if (command.action == 2) {
                // Arm before even the first byte can be accepted remotely.
                compositeAttemptedRevision = command.revision;
                output.writeByte(1); output.writeByte(command.interactive ? 1 : 0); output.writeByte(command.panelPolicy);
                output.writeLong(command.revision);
            } else output.writeByte(0);
            output.flush();
            JSONObject frame = compositeReply(); CompositeReceipt receipt = CompositeReceipt.parse(jsonFields(frame));
            receipt.sameOwner(compositeHeader);
            if (command.action == 2) { receipt.policy(compositeHeader, command); compositeConfirmedRevision = command.revision; }
            else if (!receipt.event.equals("reply") || !receipt.ok || receipt.draining || !receipt.settled)
                throw new IOException("display_status_unconfirmed");
            return frame;
        }
        void compositeLine(String line, boolean overflow) {
            try {
                if (overflow || line.getBytes(StandardCharsets.UTF_8).length > DisplayStateController.MAX_REPLY) throw new IOException();
                JSONObject raw = new JSONObject(line); CompositeReceipt receipt = CompositeReceipt.parse(jsonFields(raw));
                if (receipt.event.equals("ready")) {
                    receipt.header();
                    if (compositeHeader != null || compositeStartupFailure != null) throw new IOException();
                    compositeHeader = receipt; compositeHeaderJSON = raw;
                } else if (receipt.event.equals("startup_failed")) {
                    if (compositeHeader != null || compositeAttemptedRevision != 0 || compositeStartupFailure != null) throw new IOException();
                    compositeStartupFailure = raw;
                } else {
                    receipt.sameOwner(compositeHeader);
                    if (receipt.event.equals("retired")) {
                        receipt.terminal(compositeHeader, compositeConfirmedRevision, compositeAttemptedRevision);
                        if (compositeTerminalJSON != null) throw new IOException();
                        compositeTerminalJSON = raw;
                    }
                }
                if (!compositeReplies.offer(raw)) throw new IOException();
            } catch (Exception invalid) { compositeReplyInvalid = true; }
        }
        void power(boolean on) throws Exception {
            if (panel == null || !panel.isAlive()) throw new IOException("panel_owner_gone");
            panel.getOutputStream().write(on ? 1 : 0); panel.getOutputStream().flush();
            panelReply();
            if (!(on ? Arrays.asList("panel_on", "panel_multi_on") : Arrays.asList("panel_off", "panel_multi_off")).contains(panelCurrentState))
                throw new IOException("panel_unconfirmed");
        }
        Map<String, Boolean> panelStates(JSONArray array) throws Exception {
            if (array.length() < 1 || array.length() > DisplayPowerController.MAX_PANELS) throw new IOException("panel_reply_invalid");
            Map<String, Boolean> states = new LinkedHashMap<>();
            for (int index = 0; index < array.length(); ++index) {
                JSONObject value = array.getJSONObject(index);
                if (value.length() != 2 || !(value.get("id") instanceof String) || !(value.get("on") instanceof Boolean))
                    throw new IOException("panel_reply_invalid");
                String id = value.getString("id");
                if (!DisplayPowerController.validID(id) || states.put(id, value.getBoolean("on")) != null) throw new IOException("panel_reply_invalid");
            }
            return states;
        }
        void panelReply() throws Exception {
            String line = panelReplies.poll(8, TimeUnit.SECONDS);
            if (line == null || panelReplyOverflow) throw new IOException("panel_reply_unavailable");
            JSONObject reply = new JSONObject(line);
            Object version = reply.get("version");
            if (reply.length() != 7 || !(version instanceof Integer || version instanceof Long) || ((Number) version).longValue() != 1 || !(reply.get("ok") instanceof Boolean) ||
                !(reply.get("startTime") instanceof String) || !(reply.get("error") instanceof String)) throw new IOException("panel_reply_invalid");
            Object rawPID = reply.get("pid");
            if (!(rawPID instanceof Integer || rawPID instanceof Long) || ((Number) rawPID).longValue() < 1 ||
                ((Number) rawPID).longValue() > Integer.MAX_VALUE) throw new IOException("panel_reply_invalid");
            int pid = ((Number) rawPID).intValue(); String start = reply.getString("startTime"), error = reply.getString("error");
            if (!start.matches("[1-9][0-9]{0,19}") || !error.matches("[a-z_]{0,64}")) throw new IOException("panel_reply_invalid");
            if (panelPID != 0 && (panelPID != pid || !panelStartTime.equals(start))) throw new IOException("panel_identity_changed");
            if (!reply.getBoolean("ok") && initialPanels == null) throw new IOException(error.isEmpty() ? "panel_unavailable" : error);
            Map<String, Boolean> initial = panelStates(reply.getJSONArray("initial")), current = panelStates(reply.getJSONArray("current"));
            if (!initial.keySet().equals(current.keySet()) || (initialPanels != null && !initialPanels.equals(initial))) throw new IOException("panel_snapshot_changed");
            if (initialPanels == null) {
                if (!initial.equals(current)) throw new IOException("panel_snapshot_changed");
                initialPanels = initial; panelPID = pid; panelStartTime = start;
            }
            panelCurrentState = new DisplayPowerController.Frame(current, current.keySet().iterator().next()).state();
            panelFailureRestored = !reply.getBoolean("ok") && error.equals("panel_operation_failed_restored") && current.equals(initialPanels);
            if (!reply.getBoolean("ok") || !error.isEmpty()) throw new IOException(error.isEmpty() ? "panel_unconfirmed" : error);
        }
        void drainAnnouncements(Process child, String mode) {
            boolean panelChild = mode.equals("panel"), composite = mode.equals("display-state");
            try (InputStream input = child.getInputStream()) {
                ByteArrayOutputStream line = new ByteArrayOutputStream(); boolean overflow = false;
                int b;
                while ((b = input.read()) != -1) {
                    if (b == '\n') {
                        String value = new String(line.toByteArray(), StandardCharsets.UTF_8);
                        if (composite) compositeLine(value, overflow);
                        else if (panelChild) {
                            if (overflow || !panelReplies.offer(value)) panelReplyOverflow = true;
                        } else if (!overflow && value.matches("\\[server\\] INFO: New display: [0-9]+x[0-9]+/[0-9]+ \\(id=[0-9]+\\)"))
                            announcements.offer((value + "\n").getBytes(StandardCharsets.UTF_8));
                        line.reset(); overflow = false;
                    } else if (line.size() < (composite ? DisplayStateController.MAX_REPLY : panelChild ? DisplayPowerController.MAX_REPLY_BYTES : 1024)) line.write(b); else overflow = true;
                }
            } catch (IOException ignored) {}
        }
        JSONObject compositeProof() throws Exception {
            if (compositePhysicalProof == null || compositeChild != null && compositeChild.isAlive()) throw new IOException("display_retirement_unconfirmed");
            for (File owned : jars) if (owned.exists()) throw new IOException("display_resource_retirement_unconfirmed");
            return new JSONObject(compositePhysicalProof.toString());
        }
        void retire() throws Exception {
            stopped.set(true);
            streamOrder.stop();
            retireOwnedSockets(sockets);
            // Close all parent-owned pipes FIRST. Panel child restores its exact
            // snapshot; scrcpy child exits and its stock cleanup restores state.
            for (Process child : children) try { child.getOutputStream().close(); } catch (IOException ignored) {}
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
            for (Process child : children) {
                long remaining = Math.max(1, deadline - System.nanoTime());
                if (!child.waitFor(remaining, TimeUnit.NANOSECONDS)) {
                    // Do not SIGKILL a panel child while it may be restoring.
                    if (child == panel || child == compositeChild) throw new IOException("display_retirement_unsettled");
                    child.destroy();
                    if (!child.waitFor(500, TimeUnit.MILLISECONDS)) { child.destroyForcibly(); child.waitFor(500, TimeUnit.MILLISECONDS); }
                    if (child.isAlive()) throw new IOException("child_retirement_unsettled");
                }
            }
            // CleanUp is independently surviving: exact unique CLASSPATH plus
            // class + PID/start identity must disappear before allowing reuse.
            for (File owned : jars) awaitCleanup(owned, deadline);
            if (policy.operation == 8) {
                if (compositeReader != null) compositeReader.join(200);
                if (compositeReader != null && compositeReader.isAlive()) throw new IOException("display_reply_unsettled");
                if (compositeHeader != null && compositePhysicalProof == null) {
                    confirmControllerAbsent(compositeHeader.pid, Long.parseLong(compositeHeader.start), () -> readControllerStat(compositeHeader.pid));
                    JSONObject proof = new JSONObject().put("kind", 3).put("scid", 0).put("pid", compositeHeader.pid)
                        .put("process_start_ticks", Long.parseLong(compositeHeader.start)).put("supported", true).put("absent", true)
                        .put("panels", new JSONArray()).put("owned_resource_id", "").put("resource_removed", false);
                    if (compositeTerminalJSON != null && !compositeReplyInvalid) {
                        CompositeReceipt.parse(jsonFields(compositeTerminalJSON)).terminal(compositeHeader, compositeConfirmedRevision, compositeAttemptedRevision);
                        proof.put("display_state_terminal_acknowledgement", compositeTerminalJSON);
                    } else {
                        // Exact-restored fallback only. A changed final state
                        // requires the retained typed YIELD/barrier receipt.
                        JSONObject observed = new JSONObject(DisplayStateController.snapshot(compositeProbe.read()));
                        if (!new CompositeSnapshot(jsonFields(observed)).sameOwnedState(compositeHeader.initial))
                            throw new IOException("display_retirement_unconfirmed");
                        proof.put("display_state_snapshot", observed);
                    }
                    compositePhysicalProof = proof;
                    compositeProofs.put(compositeHeader.pid + ":" + compositeHeader.start, proof);
                } else if (compositeHeader == null && compositeAttemptedRevision != 0) throw new IOException("display_startup_retirement_unconfirmed");
            }
            // The child exits0 only after confirmed exact per-panel restoration.
            // An operation error can also prove rollback explicitly in its ack.
            if (policy.operation == 3 && panel != null && initialPanels != null && panel.exitValue() != 0 && !panelFailureRestored)
                throw new IOException("panel_restore_unconfirmed");
            for (File owned : jars) {
                if (policy.operation == 8) { Files.deleteIfExists(owned.toPath()); if (owned.exists()) throw new IOException("display_resource_retirement_unconfirmed"); }
                else owned.delete();
            }
        }
    }

    /** Fixed child wrapper: the lifetime descriptor is not an ADB connection. */
    public static final class Bootstrap {
        public static void main(String[] args) throws Exception {
            if (args.length != 5 || android.os.Process.myUid() != 2000) return;
            List<String> command = new ArrayList<>(Arrays.asList("/system/bin/app_process", "/", "com.genymobile.scrcpy.ShellCapabilityBridge"));
            command.addAll(Arrays.asList(args));
            ProcessBuilder builder = new ProcessBuilder(command);
            builder.environment().put("CLASSPATH", System.getProperty("java.class.path"));
            File sink = new File("/dev/null");
            builder.redirectInput(sink); builder.redirectOutput(sink); builder.redirectError(sink);
            builder.start();
            // This ADB-owned bootstrap exits. Its child creates a new session
            // before exposing the Helper socket; no ADB lifetime FD is retained.
        }
    }

    /** Raw ADB media may retain a stalled relay after USB detach. This lease is
     * private to one child; its deadline cannot retire a sibling capture. */
    static final class OwnedCaptureLifetime implements AutoCloseable {
        private final AtomicBoolean closed = new AtomicBoolean();
        private volatile long lastHeartbeat = System.nanoTime();
        private final Thread deadline;
        OwnedCaptureLifetime(InputStream input, long timeoutMillis, long pollMillis, Runnable expired) {
            if (timeoutMillis <= 0 || pollMillis <= 0 || pollMillis > timeoutMillis) throw new IllegalArgumentException();
            Runnable retire = () -> { if (closed.compareAndSet(false, true)) expired.run(); };
            Thread reader = new Thread(() -> {
                try { int value; while (!closed.get() && (value = input.read()) == 126) lastHeartbeat = System.nanoTime(); }
                catch (IOException ignored) {}
                retire.run();
            }, "gb-adb-owner-input");
            reader.setDaemon(true);
            deadline = new Thread(() -> {
                try { while (!closed.get()) {
                    if (System.nanoTime() - lastHeartbeat >= TimeUnit.MILLISECONDS.toNanos(timeoutMillis)) { retire.run(); return; }
                    Thread.sleep(pollMillis);
                } } catch (InterruptedException ignored) { Thread.currentThread().interrupt(); }
            }, "gb-adb-owner-deadline");
            deadline.setDaemon(true); reader.start(); deadline.start();
        }
        @Override public void close() { closed.set(true); deadline.interrupt(); }
    }

    public static final class ChildMain {
        public static void main(String[] args) throws Exception {
            if (args.length < 1 || android.os.Process.myUid() != 2000) return;
            detachSession();
            String mode = args[0]; String[] values = Arrays.copyOfRange(args, 1, args.length);
            if (mode.equals("panel")) {
                if (values.length != 0) return;
                DisplayPowerController.main(values);
            } else if (mode.equals("display-state")) {
                if (values.length != 1 || !values[0].equals("--owner-lease")) return;
                // The composite controller owns drain/restore. Never attach
                // the capture wrapper's unconditional System.exit deadline.
                DisplayStateController.main(values);
            } else if ((mode.equals("scrcpy") || mode.equals("clipboard")) && values.length > 0 && values[0].equals("--owner-lease")) {
                try (OwnedCaptureLifetime lifetime = new OwnedCaptureLifetime(System.in, 12000, 200, () -> System.exit(0))) {
                    String[] payload = Arrays.copyOfRange(values, 1, values.length);
                    if (mode.equals("scrcpy")) Server.main(payload); else ClipboardAgent.main(payload);
                }
            } else if (mode.equals("scrcpy") || mode.equals("clipboard")) {
                Thread lifetime = new Thread(() -> { try { while (System.in.read() != -1) {} } catch (IOException ignored) {}
                    System.exit(0); }, "gb-shell-parent-lifetime"); lifetime.setDaemon(true); lifetime.start();
                if (mode.equals("scrcpy")) Server.main(values); else ClipboardAgent.main(values);
            }
        }
    }

    interface PanelPower { boolean apply(boolean on) throws Exception; }
    static void panelLifetime(InputStream input, boolean initial, PanelPower power) throws Exception {
        try { int command; while ((command = input.read()) != -1) {
            if (command != 0 && command != 1) break;
            if (!power.apply(command == 1)) break;
        } } finally { power.apply(initial); }
    }

    private static void detachSession() throws Exception {
        try { Os.setsid(); }
        catch (android.system.ErrnoException failure) {
            String self = new String(Files.readAllBytes(new File("/proc/self/stat").toPath()), StandardCharsets.UTF_8);
            String[] fields = self.substring(self.lastIndexOf(')') + 1).trim().split("\\s+");
            if (fields.length < 4 || Integer.parseInt(fields[3]) != android.os.Process.myPid()) throw failure;
        }
    }

    @Override public void close() {
        if (!closed.compareAndSet(false, true)) return;
        synchronized (admissionLock) {
            IBinder lifetime = helperLifetime; helperLifetime = null;
            if (lifetime != null) try { lifetime.unlinkToDeath(helperDeath, 0); } catch (Exception ignored) {}
            synchronized (clients) { for (FDChannel socket : clients) closeSocket(socket); clients.clear(); }
        }
        synchronized (this) {
            // All lifetimes close before sequential bounded waits.
            for (Lease lease : leases.values()) for (Process child : lease.children) try { child.getOutputStream().close(); } catch (IOException ignored) {}
            for (Iterator<Map.Entry<String, Lease>> entries = leases.entrySet().iterator(); entries.hasNext();) {
                try { entries.next().getValue().retire(); entries.remove(); } catch (Exception ignored) {}
            }
        }
        timer.shutdownNow(); workers.shutdownNow();
        if (leases.isEmpty()) finishClose();
        else {
            // A bounded STOP failure is not physical retirement. Retain only
            // owned metadata and the global lock; retry at low frequency.
            Thread watcher = new Thread(() -> {
                while (true) {
                    try { Thread.sleep(2000); } catch (InterruptedException ignored) {}
                    synchronized (ShellCapabilityBridge.this) {
                        for (Iterator<Map.Entry<String, Lease>> entries = leases.entrySet().iterator(); entries.hasNext();) {
                            try { entries.next().getValue().retire(); entries.remove(); } catch (Exception ignored) {}
                        }
                        if (leases.isEmpty()) { finishClose(); return; }
                    }
                }
            }, "gb-shell-physical-retirement"); watcher.setDaemon(false); watcher.start();
        }
    }

    private void finishClose() { directory.delete(); sourceJar.delete(); physicallyClosed.countDown(); }

    private static boolean ownedOrphans() throws Exception {
        File[] entries = new File("/proc").listFiles();
        if (entries == null) throw new IOException("process_inventory_unavailable");
        for (File entry : entries) if (entry.getName().matches("[0-9]+")) {
            try {
                String command = new String(Files.readAllBytes(new File(entry, "cmdline").toPath()), StandardCharsets.UTF_8).replace('\0', ' ');
                List<String> fields = Arrays.asList(command.trim().split("\\s+"));
                if (!fields.contains("com.genymobile.scrcpy.ShellCapabilityBridge$ChildMain") && !fields.contains("com.genymobile.scrcpy.CleanUp")) continue;
                String env = new String(Files.readAllBytes(new File(entry, "environ").toPath()), StandardCharsets.UTF_8);
                boolean owned = false;
                for (String value : env.split("\u0000")) if (value.matches("CLASSPATH=/data/local/tmp/galaxybridge-shell-[a-f0-9-]{36}/[a-f0-9-]{36}-(?:scrcpy|clipboard|panel|display-state)\\.jar")) owned = true;
                if (!owned) continue;
                String stat = new String(Files.readAllBytes(new File(entry, "stat").toPath()), StandardCharsets.UTF_8);
                String[] state = stat.substring(stat.lastIndexOf(')') + 1).trim().split("\\s+");
                if (state.length < 20) throw new IOException("process_identity_unavailable");
                Long.parseLong(state[19]); if (!state[0].equals("Z")) return true;
            } catch (java.nio.file.NoSuchFileException gone) {} catch (java.nio.file.AccessDeniedException unrelated) {}
        }
        return false;
    }

    private static JSONObject read(InputStream stream) throws Exception {
        DataInputStream input = new DataInputStream(stream); int length = input.readInt();
        if (length <= 0 || length > MAX_FRAME) throw new IOException("frame_bound");
        byte[] bytes = new byte[length]; input.readFully(bytes);
        return new JSONObject(new String(bytes, StandardCharsets.UTF_8));
    }
    private static void write(OutputStream stream, JSONObject object) throws Exception {
        byte[] bytes = object.toString().getBytes(StandardCharsets.UTF_8);
        if (bytes.length > MAX_FRAME) throw new IOException("frame_bound");
        DataOutputStream output = new DataOutputStream(stream); output.writeInt(bytes.length); output.write(bytes); output.flush();
    }
    private static void copy(InputStream input, OutputStream output) throws IOException {
        byte[] buffer = new byte[65536]; int n;
        while ((n = input.read(buffer)) != -1) { output.write(buffer, 0, n); output.flush(); }
    }
    private static void closeSocket(LocalSocket socket) {
        shutdownAndClose(() -> {
            try { socket.shutdownInput(); }
            finally { socket.shutdownOutput(); }
        }, socket::close);
    }
    private static void closeSocket(FDChannel socket) { socket.close(); }
    private static boolean isStreamSocket(FileDescriptor descriptor) throws Exception {
        // getsockoptInt exists in Android's Os implementation but is hidden
        // from the public SDK. Absence/denial fails admission closed.
        Object type = Os.class.getMethod("getsockoptInt", FileDescriptor.class, int.class, int.class)
            .invoke(null, descriptor, OsConstants.SOL_SOCKET, OsConstants.SO_TYPE);
        return type instanceof Integer && ((Integer) type) == OsConstants.SOCK_STREAM;
    }
    private static void closeOwnedSocket(Closeable socket) {
        if (socket instanceof LocalSocket) closeSocket((LocalSocket) socket);
        else try { socket.close(); } catch (IOException ignored) {}
    }
    private static boolean canonicalUUID(String value) {
        try { return UUID.fromString(value).toString().equals(value); } catch (Exception invalid) { return false; }
    }
    static boolean validStreamID(String value) {
        if (value == null) return false;
        int slash = value.indexOf('/');
        return slash == 36 && canonicalUUID(value.substring(0, slash)) &&
            Arrays.asList("video", "audio", "control", "clipboard", "log").contains(value.substring(slash + 1));
    }
    private static String hex(byte[] bytes) { StringBuilder out = new StringBuilder(); for (byte b : bytes) out.append(String.format(Locale.ROOT, "%02x", b & 255)); return out.toString(); }
    static final class RetirementQuery {
        final int kind, scid, pid;
        final long startTicks;
        final String resourceID, resourceSHA;
        private RetirementQuery(Map<String, Object> fields, boolean release) {
            kind = (int) Policy.number(fields, "kind", 0, 3);
            scid = (int) Policy.number(fields, "scid", 0, 0x7fffffffL);
            pid = (int) Policy.number(fields, "pid", 0, 0x7fffffffL);
            startTicks = Policy.number(fields, "process_start_ticks", 0, Long.MAX_VALUE);
            resourceID = Policy.text(fields, "owned_resource_id"); resourceSHA = Policy.text(fields, "resource_sha256");
            if (release) {
                if ((kind != 2 && kind != 3) || !canonicalUUID(resourceID) || !resourceSHA.matches("[a-f0-9]{64}")) throw new IllegalArgumentException();
            } else if (!resourceID.isEmpty() || !resourceSHA.isEmpty()) throw new IllegalArgumentException();
            if (kind == 0 && (scid != 0 || pid != 0 || startTicks != 0)) throw new IllegalArgumentException();
            if (kind == 1 && (scid <= 0 || pid != 0 || startTicks != 0)) throw new IllegalArgumentException();
            if ((kind == 2 || kind == 3) && (scid != 0 || pid <= 1 || startTicks <= 0)) throw new IllegalArgumentException();
        }
        static RetirementQuery parse(Map<String, Object> fields) { return parse(fields, false); }
        static RetirementQuery parse(Map<String, Object> fields, boolean release) {
            if (!new HashSet<>(Arrays.asList("kind", "scid", "pid", "process_start_ticks", "owned_resource_id", "resource_sha256")).containsAll(fields.keySet()))
                throw new IllegalArgumentException();
            return new RetirementQuery(fields, release);
        }
    }

    private static JSONObject baseRetirementProof(RetirementQuery query) throws Exception {
        return new JSONObject().put("kind", query.kind).put("scid", query.scid).put("pid", query.pid)
            .put("process_start_ticks", query.startTicks).put("supported", true).put("absent", false)
            .put("owned_resource_id", query.resourceID).put("resource_removed", false).put("panels", new JSONArray());
    }

    static boolean releasePrivacyResource(File directory, String id, String suppliedSHA, byte[] verifiedJar) throws Exception {
        if (!canonicalUUID(id) || !suppliedSHA.matches("[a-f0-9]{64}") || verifiedJar.length == 0 || verifiedJar.length > 4 * 1024 * 1024)
            throw new IllegalArgumentException("runtime_resource_identity");
        byte[] expected = MessageDigest.getInstance("SHA-256").digest(verifiedJar);
        if (!hex(expected).equals(suppliedSHA)) throw new IOException("runtime_resource_hash");
        File parent = directory.getCanonicalFile();
        File file = new File(parent, "galaxybridge-privacy-" + id + ".jar");
        if (!file.getAbsolutePath().equals(file.getCanonicalPath())) throw new IOException("runtime_resource_path");
        if (!file.exists()) return true;
        if (!file.isFile() || file.length() != verifiedJar.length) throw new IOException("runtime_resource_bytes");
        byte[] actual = MessageDigest.getInstance("SHA-256").digest(Files.readAllBytes(file.toPath()));
        if (!MessageDigest.isEqual(actual, expected)) throw new IOException("runtime_resource_hash");
        if (!file.delete() && file.exists()) throw new IOException("runtime_resource_cleanup");
        return true;
    }

    private JSONObject retirementProof(RetirementQuery query) throws Exception {
        JSONObject proof = baseRetirementProof(query);
        JSONArray panels = new JSONArray();
        if (query.kind == 1) {
            confirmCaptureAbsent(query.scid, () -> fixedRead("/system/bin/ps", "-A", "-w", "-o", "PID,ARGS"));
            proof.put("absent", true);
        } else if (query.kind == 2) {
            confirmControllerAbsent(query.pid, query.startTicks, () -> readControllerStat(query.pid));
            DisplayPowerController.Frame frame = DisplayPowerController.runtimeFrame();
            for (Map.Entry<String, Boolean> panel : frame.states.entrySet())
                panels.put(new JSONObject().put("physical_id", panel.getKey()).put("on", panel.getValue()));
            proof.put("absent", true);
        }
        if (query.kind == 3) {
            confirmControllerAbsent(query.pid, query.startTicks, () -> readControllerStat(query.pid));
            proof.put("absent", true);
            JSONObject retained = compositeProofs.get(query.pid + ":" + query.startTicks);
            if (retained != null) {
                if (retained.has("display_state_terminal_acknowledgement")) proof.put("display_state_terminal_acknowledgement", retained.get("display_state_terminal_acknowledgement"));
                if (retained.has("display_state_snapshot")) proof.put("display_state_snapshot", retained.get("display_state_snapshot"));
            } else proof.put("display_state_snapshot", new JSONObject(DisplayStateController.snapshot(compositeProbe.read())));
        }
        return proof.put("panels", panels);
    }

    private static String readControllerStat(int pid) throws Exception {
        try {
            byte[] bytes = Files.readAllBytes(new File("/proc/" + pid + "/stat").toPath());
            if (bytes.length > 4096) throw new IOException("controller_stat_limit");
            return StandardCharsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString();
        } catch (java.nio.file.NoSuchFileException gone) { return null; }
    }

    static String controllerRetirementState(int pid, long ticks, String stat) throws IOException {
        if (pid <= 1 || ticks <= 0) throw new IllegalArgumentException("controller_identity_invalid");
        if (stat == null) return "absent";
        if (stat.length() > 4096 || !stat.endsWith("\n")) throw new IOException("controller_stat_incomplete");
        int opening = stat.indexOf('('), closing = stat.lastIndexOf(')');
        if (opening < 1 || closing <= opening || !stat.substring(0, opening).trim().equals(Integer.toString(pid)))
            throw new IOException("controller_stat_identity");
        String[] fields = stat.substring(closing + 1).trim().split("\\s+");
        if (fields.length < 20 || !fields[0].matches("[RSDZTWXtIPKx]")) throw new IOException("controller_stat_incomplete");
        long current;
        try { current = Long.parseUnsignedLong(fields[19]); }
        catch (NumberFormatException invalid) { throw new IOException("controller_start_ticks", invalid); }
        if (!Long.toUnsignedString(current).equals(fields[19])) throw new IOException("controller_start_ticks");
        return current != ticks || fields[0].equals("Z") ? "absent" : "present";
    }

    static void confirmControllerAbsent(int pid, long ticks, CaptureInventory inventory) throws Exception {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3);
        for (int sample = 0; sample < 5; sample++) {
            if (System.nanoTime() >= deadline) throw new IOException("retirement_probe_timeout");
            if (!controllerRetirementState(pid, ticks, inventory.read()).equals("absent")) throw new IOException("display_controller_present");
            if (System.nanoTime() >= deadline) throw new IOException("retirement_probe_timeout");
            if (sample + 1 < 5) Thread.sleep(50);
        }
    }

    interface CaptureInventory { String read() throws Exception; }

    static String captureRetirementState(int scid, String inventory) throws IOException {
        if (scid <= 0) throw new IllegalArgumentException("capture_scid_invalid");
        if (inventory == null || inventory.length() > 8 * 1024 * 1024 || !inventory.endsWith("\n") || inventory.indexOf('\0') >= 0)
            throw new IOException("capture_inventory_incomplete");
        String[] lines = inventory.split("\n", -1);
        if (lines.length < 3 || !(lines[0].trim().matches("PID\\s+(ARGS|COMMAND)")))
            throw new IOException("capture_inventory_header");
        Set<Integer> pids = new HashSet<>();
        boolean hasInit = false, present = false;
        String expected = String.format(Locale.ROOT, "scid=%08x", scid);
        for (int i = 1; i < lines.length - 1; i++) {
            String[] fields = lines[i].trim().split("\\s+");
            if (fields.length < 2 || !fields[0].matches("[0-9]+")) throw new IOException("capture_inventory_row");
            int pid;
            try { pid = Integer.parseInt(fields[0]); }
            catch (NumberFormatException invalid) { throw new IOException("capture_inventory_pid", invalid); }
            if (pid <= 0 || !pids.add(pid)) throw new IOException("capture_inventory_pid");
            hasInit |= pid == 1;
            List<String> tokens = Arrays.asList(fields);
            boolean producer = tokens.contains("com.genymobile.scrcpy.Server");
            int child = tokens.indexOf("com.genymobile.scrcpy.ShellCapabilityBridge$ChildMain");
            if (child >= 0 && child + 1 < fields.length && fields[child + 1].equals("scrcpy")) producer = true;
            if (!producer) continue;
            int scids = 0;
            for (String field : fields) if (field.startsWith("scid=")) {
                if (!field.matches("scid=[0-7][a-f0-9]{7}") || ++scids > 1) throw new IOException("capture_inventory_scid");
                if (field.equals(expected)) present = true;
            }
        }
        if (!hasInit) throw new IOException("capture_inventory_incomplete");
        return present ? "present" : "absent";
    }

    static void confirmCaptureAbsent(int scid, CaptureInventory inventory) throws Exception {
        long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3);
        for (int sample = 0; sample < 5; sample++) {
            if (System.nanoTime() >= deadline) throw new IOException("retirement_probe_timeout");
            if (!captureRetirementState(scid, inventory.read()).equals("absent")) throw new IOException("adb_capture_present");
            if (System.nanoTime() >= deadline) throw new IOException("retirement_probe_timeout");
            if (sample + 1 < 5) Thread.sleep(50);
        }
    }



    private static String fixedRead(String... args) throws Exception {
        Process process = new ProcessBuilder(args).redirectErrorStream(true).start();
        process.getOutputStream().close();
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        java.util.concurrent.atomic.AtomicReference<IOException> failure = new java.util.concurrent.atomic.AtomicReference<>();
        Thread reader = new Thread(() -> { try (InputStream input = process.getInputStream()) {
            byte[] buffer = new byte[4096]; int n;
            while ((n = input.read(buffer)) != -1) {
                if (output.size() + n > 8 * 1024 * 1024) throw new IOException("fixed_read_limit");
                output.write(buffer, 0, n);
            }
        } catch (IOException error) { failure.set(error); } }, "gb-shell-fixed-read");
        reader.setDaemon(true); reader.start();
        try {
            if (!process.waitFor(2, TimeUnit.SECONDS)) throw new IOException("fixed_read_timeout");
            reader.join(200);
            if (process.exitValue() != 0 || reader.isAlive()) throw new IOException("fixed_read_failed");
            if (failure.get() != null) throw failure.get();
            return StandardCharsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(output.toByteArray())).toString();
        } finally {
            if (process.isAlive()) process.destroyForcibly();
        }
    }
    private static int packageUID(String packageName) throws Exception {
        String output = fixedRead("/system/bin/cmd", "package", "list", "packages", "-U", packageName);
        for (String line : output.split("\n")) if (line.matches("package:" + packageName.replace(".", "\\.") + " uid:[0-9]+"))
            return Integer.parseInt(line.substring(line.lastIndexOf(':') + 1));
        return -1;
    }
    interface PanelStatusProbe { String read() throws Exception; }
    static String readOnlyPanelStatus(PanelStatusProbe probe) {
        // General STATUS attests the broker, not physical-power support. A
        // private-API/DOZE/read failure must not disable clipboard/app capture.
        try {
            String state = probe.read();
            return Arrays.asList("panel_on", "panel_off", "panel_multi_on", "panel_multi_off").contains(state) ? state : "panel_unknown";
        } catch (Exception | LinkageError | AssertionError unavailable) { return "panel_unknown"; }
    }
    private static String panelState() throws Exception {
        return DisplayPowerController.runtimeFrame().state();
    }
    private static void awaitCleanup(File jar, long deadline) throws Exception {
        while (true) {
            boolean live = false; File[] entries = new File("/proc").listFiles();
            if (entries == null) throw new IOException("cleanup_identity_unavailable");
            for (File entry : entries) if (entry.getName().matches("[0-9]+")) {
                try {
                    String command = new String(Files.readAllBytes(new File(entry, "cmdline").toPath()), StandardCharsets.UTF_8).replace('\0', ' ');
                    List<String> commands = Arrays.asList(command.trim().split("\\s+"));
                    if (!commands.contains("com.genymobile.scrcpy.CleanUp") && !commands.contains("com.genymobile.scrcpy.ShellCapabilityBridge$ChildMain")) continue;
                    String env = new String(Files.readAllBytes(new File(entry, "environ").toPath()), StandardCharsets.UTF_8);
                    if (!Arrays.asList(env.split("\u0000")).contains("CLASSPATH=" + jar.getPath())) continue;
                    String stat = new String(Files.readAllBytes(new File(entry, "stat").toPath()), StandardCharsets.UTF_8);
                    String[] fields = stat.substring(stat.lastIndexOf(')') + 1).trim().split("\\s+");
                    if (fields.length < 20) throw new IOException("cleanup_identity_unavailable");
                    Long.parseLong(fields[19]); // Validate exact PID/start identity; never signal this child.
                    if (!fields[0].equals("Z")) live = true;
                } catch (java.nio.file.NoSuchFileException gone) {} catch (java.nio.file.AccessDeniedException otherUID) {}
            }
            if (!live) return;
            if (System.nanoTime() >= deadline) throw new IOException("cleanup_unsettled");
            Thread.sleep(50);
        }
    }

    static final class Policy {
        final int operation, scid, display, size, fps, width, height;
        final long bitrate;
        final boolean audio, control;
        final String lease, codec, application;
        private Policy(int operation, String lease, Map<String, Object> options) {
            this.operation = operation; this.lease = lease;
            if (operation == 8) {
                if (!options.isEmpty()) throw new IllegalArgumentException("display_owner_media_options");
                scid = display = size = fps = width = height = 0;
                bitrate = 0; audio = control = false; codec = application = "";
                return;
            }
            scid = (int) number(options, "scid", 1, 0x7fffffffL);
            display = (int) number(options, "display_id", 0, 4095);
            size = (int) number(options, "max_size", 0, 8192);
            fps = (int) number(options, "max_fps", 0, 240);
            bitrate = number(options, "video_bit_rate", operation == 1 ? 100000 : 0, 100000000);
            width = (int) number(options, "width", 0, 8192); height = (int) number(options, "height", 0, 8192);
            codec = text(options, "codec"); application = text(options, "package_name");
            audio = flag(options, "audio"); control = flag(options, "control");
            if (!codec.equals("h264") && !codec.equals("h265")) throw new IllegalArgumentException();
            if (!application.isEmpty() && (!application.matches("[A-Za-z][A-Za-z0-9_]*(?:\\.[A-Za-z][A-Za-z0-9_]*)+") || application.length() > 255 || width < 16 || height < 16)) throw new IllegalArgumentException();
            if ((width == 0) != (height == 0) || (!control && operation != 1)) throw new IllegalArgumentException();
        }
        static Policy parse(int operation, String lease, Map<String, Object> options) {
            if ((operation < 1 || operation > 3) && operation != 8 || !canonicalUUID(lease)) throw new IllegalArgumentException();
            Set<String> fields = new HashSet<>(Arrays.asList("scid", "display_id", "package_name", "max_size", "max_fps", "video_bit_rate", "codec", "width", "height", "audio", "control"));
            if (!fields.containsAll(options.keySet())) throw new IllegalArgumentException();
            return new Policy(operation, lease, options);
        }
        private static long number(Map<String, Object> source, String key, long min, long max) {
            Object value = source.getOrDefault(key, 0);
            if (!(value instanceof Integer) && !(value instanceof Long)) throw new IllegalArgumentException();
            long n = ((Number) value).longValue(); if (n < min || n > max) throw new IllegalArgumentException(); return n;
        }
        private static String text(Map<String, Object> source, String key) { Object value = source.getOrDefault(key, ""); if (!(value instanceof String)) throw new IllegalArgumentException(); return (String) value; }
        private static boolean flag(Map<String, Object> source, String key) { Object value = source.getOrDefault(key, false); if (!(value instanceof Boolean)) throw new IllegalArgumentException(); return (Boolean) value; }
        boolean equivalent(Policy other) { return operation == other.operation && (operation == 3 || operation == 8 || Arrays.equals(serverArguments(), other.serverArguments())); }
        List<String> streams() {
            if (operation == 3 || operation == 8) return Collections.emptyList();
            List<String> types = operation == 2 ? Arrays.asList("control", "clipboard") : audio ? Arrays.asList("video", "audio", "control", "log") : Arrays.asList("video", "control", "log");
            List<String> ids = new ArrayList<>(); for (String type : types) ids.add(lease + "/" + type); return ids;
        }
        String[] serverArguments() {
            if (operation == 8) return new String[0];
            List<String> args = new ArrayList<>(Arrays.asList(BuildConfig.VERSION_NAME, String.format(Locale.ROOT, "scid=%08x", scid),
                "log_level=info", "tunnel_forward=true", "cleanup=true", "power_on=false", "clipboard_autosync=false",
                "send_device_meta=" + (operation == 1), "send_stream_meta=true", "send_frame_meta=true",
                "keep_active=" + (operation == 1), "video=" + (operation == 1),
                "audio=" + (operation == 1 && audio), "control=true"));
            if (operation == 1) {
                args.add("display_ime_policy=hide");
                if (audio) { args.add("audio_codec=aac"); args.add("audio_bit_rate=128000"); }
                args.add("video_codec=" + codec); args.add("max_size=" + size); args.add("max_fps=" + fps); args.add("video_bit_rate=" + bitrate);
                // Match ScrcpyLaunchProfile.wirelessADB: prepared capture must
                // keep the same standard interactive encoder hints as raw ADB.
                args.add("video_codec_options=i-frame-interval=1,priority=0,latency=0" + (codec.equals("h264") ? ",bitrate-mode=2" : ""));
                if (width > 0 && height > 0) {
                    args.add("new_display=" + width + "x" + height + "/420"); args.add("vd_destroy_content=true");
                    args.add("vd_system_decorations=" + application.isEmpty());
                    if (!application.isEmpty()) args.add("flex_display=true");
                }
                else args.add("display_id=" + display);
            }
            return args.toArray(new String[0]);
        }
    }
}
