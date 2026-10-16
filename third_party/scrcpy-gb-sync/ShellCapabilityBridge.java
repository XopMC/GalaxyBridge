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
import com.genymobile.scrcpy.device.Device;
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
    private final String token, generation, activationID, helperPackage;
    private final int helperUID;
    private final BinderAdmission admission;
    private final Object admissionLock = new Object();
    private final Binder bridgeBinder;
    private final byte[] jar;
    private final File sourceJar, directory;
    private final Map<String, Lease> leases = new LinkedHashMap<>();
    private final Map<String, String> receipts = new LinkedHashMap<>();
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
        Set<String> allowed = new HashSet<>(Arrays.asList("request_id", "lease_id", "boot_generation", "operation", "options", "power_on"));
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
            if (operationValue < 0 || operationValue > 4) throw new IllegalArgumentException();
            int operation = (int) operationValue;
            if (operation == 0) {
                if (!leaseID.isEmpty() && !canonicalUUID(leaseID)) throw new IllegalArgumentException();
                response = result(id, leaseID, !leaseID.isEmpty() && !leases.containsKey(leaseID) ? "stopped" : panelState(), "", Collections.emptyList());
            } else if (operation == 4) {
                if (!canonicalUUID(leaseID)) throw new IllegalArgumentException();
                Lease lease = leases.get(leaseID);
                if (lease != null) { lease.retire(); leases.remove(leaseID); }
                response = result(id, leaseID, "stopped", "", Collections.emptyList());
            } else {
                JSONObject raw = request.optJSONObject("options");
                Map<String, Object> options = new HashMap<>();
                if (raw != null) for (Iterator<String> keys = raw.keys(); keys.hasNext();) { String key = keys.next(); options.put(key, raw.get(key)); }
                Policy policy = Policy.parse(operation, leaseID, options);
                Lease lease = leases.get(leaseID);
                if (lease == null) {
                    if (leases.size() >= 8) throw new IOException("capacity");
                    if (operation == 3) for (Lease existing : leases.values()) if (existing.policy.operation == 3) throw new IOException("panel_owner_busy");
                    for (Lease existing : leases.values()) if (existing.policy.scid == policy.scid && operation != 3) throw new IOException("scid_reused");
                    lease = new Lease(policy); leases.put(leaseID, lease);
                    try { lease.start(); } catch (Exception failure) { lease.retire(); leases.remove(leaseID); throw failure; }
                } else if (lease.stopped.get() || !lease.policy.equivalent(policy)) throw new IllegalArgumentException();
                if (operation == 3) lease.power(request.optBoolean("power_on"));
                response = result(id, leaseID, operation == 3 ? panelState() : "ready", "", policy.streams());
            }
        } catch (Exception failure) { response = result(id, leaseID, "failed", "shell_operation_failed", Collections.emptyList()); }
        if (receipts.size() >= 512) receipts.remove(receipts.keySet().iterator().next());
        receipts.put(id, new JSONObject().put("fingerprint", fingerprint).put("result", response).toString());
        return response;
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
            .put("available", true).put("state", state).put("error_code", error).put("stream_ids", new JSONArray(streams));
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
        String initialPanel;
        Lease(Policy policy) {
            this.policy = policy;
            streamOrder = new StreamOrder(policy.operation == 2 ? Collections.singletonList("control") :
                policy.audio ? Arrays.asList("video", "audio", "control") : Arrays.asList("video", "control"));
        }
        String socketName() { return String.format(Locale.ROOT, "scrcpy_%08x", policy.scid); }
        String clipboardName() { return String.format(Locale.ROOT, "gb_clip_%08x", policy.scid); }
        void start() throws Exception {
            if (policy.operation == 3) {
                String initial = panelState(); initialPanel = initial;
                if (initial.equals("panel_unknown")) throw new IOException("panel_unknown");
                panel = spawn("panel", new String[] { initial.equals("panel_on") ? "true" : "false" });
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
            builder.redirectErrorStream(true);
            Process child = builder.start(); children.add(child);
            Thread drain = new Thread(() -> drainAnnouncements(child), "gb-shell-owned-output"); drain.setDaemon(true); drain.start();
            timer.schedule(() -> { if (opened.isEmpty() && !stopped.get() && policy.operation != 3) {
                synchronized (ShellCapabilityBridge.this) { try { retire(); leases.remove(policy.lease); } catch (Exception ignored) {} }
            } }, 15, TimeUnit.SECONDS);
            return child;
        }
        void power(boolean on) throws Exception {
            if (panel == null || !panel.isAlive()) throw new IOException("panel_owner_gone");
            panel.getOutputStream().write(on ? 1 : 0); panel.getOutputStream().flush();
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(3);
            while (System.nanoTime() < deadline) {
                if (panelState().equals(on ? "panel_on" : "panel_off")) return;
                Thread.sleep(50);
            }
            throw new IOException("panel_unconfirmed");
        }
        void drainAnnouncements(Process child) {
            try (InputStream input = child.getInputStream()) {
                ByteArrayOutputStream line = new ByteArrayOutputStream(); boolean overflow = false;
                int b;
                while ((b = input.read()) != -1) {
                    if (b == '\n') {
                        String value = new String(line.toByteArray(), StandardCharsets.UTF_8);
                        if (!overflow && value.matches("\\[server\\] INFO: New display: [0-9]+x[0-9]+/[0-9]+ \\(id=[0-9]+\\)"))
                            announcements.offer((value + "\n").getBytes(StandardCharsets.UTF_8));
                        line.reset(); overflow = false;
                    } else if (line.size() < 1024) line.write(b); else overflow = true;
                }
            } catch (IOException ignored) {}
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
                    if (child == panel) throw new IOException("panel_retirement_unsettled");
                    child.destroy();
                    if (!child.waitFor(500, TimeUnit.MILLISECONDS)) { child.destroyForcibly(); child.waitFor(500, TimeUnit.MILLISECONDS); }
                    if (child.isAlive()) throw new IOException("child_retirement_unsettled");
                }
            }
            // CleanUp is independently surviving: exact unique CLASSPATH plus
            // class + PID/start identity must disappear before allowing reuse.
            for (File owned : jars) awaitCleanup(owned, deadline);
            if (policy.operation == 3 && !panelState().equals(initialPanel)) {
                if (!Device.setDisplayPower(0, initialPanel.equals("panel_on")) || !panelState().equals(initialPanel))
                    throw new IOException("panel_restore_unconfirmed");
            }
            for (File owned : jars) owned.delete();
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

    public static final class ChildMain {
        public static void main(String[] args) throws Exception {
            if (args.length < 1 || android.os.Process.myUid() != 2000) return;
            detachSession();
            String mode = args[0]; String[] values = Arrays.copyOfRange(args, 1, args.length);
            if (mode.equals("panel")) {
                if (values.length != 1 || !(values[0].equals("true") || values[0].equals("false"))) return;
                if (Looper.myLooper() == null) Looper.prepare(); Workarounds.apply();
                panelLifetime(System.in, Boolean.parseBoolean(values[0]), on -> Device.setDisplayPower(0, on));
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
                for (String value : env.split("\u0000")) if (value.matches("CLASSPATH=/data/local/tmp/galaxybridge-shell-[a-f0-9-]{36}/[a-f0-9-]{36}-(?:scrcpy|clipboard|panel)\\.jar")) owned = true;
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
    private static String fixedRead(String... args) throws Exception {
        Process process = new ProcessBuilder(args).redirectErrorStream(true).start();
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        Thread reader = new Thread(() -> { try (InputStream input = process.getInputStream()) {
            byte[] buffer = new byte[4096]; int n;
            while ((n = input.read(buffer)) != -1) { synchronized (output) { if (output.size() + n > 8 * 1024 * 1024) return; output.write(buffer, 0, n); } }
        } catch (IOException ignored) {} }, "gb-shell-fixed-read"); reader.setDaemon(true); reader.start();
        if (!process.waitFor(2, TimeUnit.SECONDS)) { process.destroyForcibly(); throw new IOException("fixed_read_timeout"); }
        reader.join(200);
        if (process.exitValue() != 0 || reader.isAlive()) throw new IOException("fixed_read_failed");
        return new String(output.toByteArray(), StandardCharsets.UTF_8);
    }
    private static int packageUID(String packageName) throws Exception {
        String output = fixedRead("/system/bin/cmd", "package", "list", "packages", "-U", packageName);
        for (String line : output.split("\n")) if (line.matches("package:" + packageName.replace(".", "\\.") + " uid:[0-9]+"))
            return Integer.parseInt(line.substring(line.lastIndexOf(':') + 1));
        return -1;
    }
    private static String panelState() throws Exception {
        String output = fixedRead("/system/bin/dumpsys", "SurfaceFlinger");
        Map<String, String> states = new HashMap<>(); Set<String> physical = new HashSet<>(); String current = null; boolean virtual = false;
        for (String raw : output.split("\n")) {
            String line = raw.trim();
            if (line.matches("(?:Virtual )?Display [0-9]+\\b.*")) {
                virtual = line.startsWith("Virtual "); String[] fields = line.split("\\s+");
                current = fields[virtual ? 2 : 1].replaceAll("[^0-9].*$", "");
                if (!virtual && line.contains("HWC display")) physical.add(current);
            } else if (current != null && !virtual && line.equals("connectionType=Internal")) physical.add(current);
            else if (current != null && !virtual && line.startsWith("powerMode=")) states.put(current, line.substring(10).trim());
        }
        if (physical.isEmpty()) return "panel_unknown";
        boolean on = true, off = true;
        for (String id : physical) { on &= "ON".equals(states.get(id)); off &= "OFF".equals(states.get(id)); }
        return on ? "panel_on" : off ? "panel_off" : "panel_unknown";
    }
    private static void awaitCleanup(File jar, long deadline) throws Exception {
        while (true) {
            boolean live = false; File[] entries = new File("/proc").listFiles();
            if (entries == null) throw new IOException("cleanup_identity_unavailable");
            for (File entry : entries) if (entry.getName().matches("[0-9]+")) {
                try {
                    String command = new String(Files.readAllBytes(new File(entry, "cmdline").toPath()), StandardCharsets.UTF_8).replace('\0', ' ');
                    if (!Arrays.asList(command.trim().split("\\s+")).contains("com.genymobile.scrcpy.CleanUp")) continue;
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
            if (operation < 1 || operation > 3 || !canonicalUUID(lease)) throw new IllegalArgumentException();
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
        boolean equivalent(Policy other) { return operation == other.operation && (operation == 3 || Arrays.equals(serverArguments(), other.serverArguments())); }
        List<String> streams() {
            if (operation == 3) return Collections.emptyList();
            List<String> types = operation == 2 ? Arrays.asList("control", "clipboard") : audio ? Arrays.asList("video", "audio", "control", "log") : Arrays.asList("video", "control", "log");
            List<String> ids = new ArrayList<>(); for (String type : types) ids.add(lease + "/" + type); return ids;
        }
        String[] serverArguments() {
            List<String> args = new ArrayList<>(Arrays.asList(BuildConfig.VERSION_NAME, String.format(Locale.ROOT, "scid=%08x", scid),
                "log_level=info", "tunnel_forward=true", "cleanup=true", "power_on=false", "clipboard_autosync=false",
                "send_device_meta=" + (operation == 1), "send_stream_meta=true", "send_frame_meta=true",
                "keep_active=" + (operation == 1), "hide_device_ime=false", "video=" + (operation == 1),
                "audio=" + (operation == 1 && audio), "control=true"));
            if (operation == 1) {
                args.add("video_codec=" + codec); args.add("max_size=" + size); args.add("max_fps=" + fps); args.add("video_bit_rate=" + bitrate);
                args.add("video_codec_options=i-frame-interval=1" + (codec.equals("h264") ? ",bitrate-mode=2" : ""));
                if (width > 0 && height > 0) { args.add("new_display=" + width + "x" + height + "/420"); args.add("vd_destroy_content=true"); }
                else args.add("display_id=" + display);
            }
            return args.toArray(new String[0]);
        }
    }
}
