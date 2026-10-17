package com.genymobile.scrcpy;

import android.os.Looper;
import android.os.SystemClock;
import android.system.Os;
import com.genymobile.scrcpy.util.Ln;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.atomic.*;
import java.util.function.IntConsumer;

/** Capture-free v2 child. A lost transport is never settled through a v1 Boolean-panel proof. */
public final class DisplayStateController {
    static final int MAX_REPLY = 8192;
    interface Clock { long nowMillis(); }
    static final class Failure extends IOException {
        final String code;
        Failure(String code) { super(code); this.code = code; }
    }
    static final class Session {
        final DisplayStateOwnership owner;
        final DisplayStateOwnership.Backend backend;
        volatile boolean draining;
        private boolean retired;
        private long revision;
        private String lastError = "";
        Session(DisplayStateOwnership.Backend backend) throws Exception { this.backend = backend; owner = new DisplayStateOwnership(backend); }
        synchronized void apply(boolean interactive, DisplayStateOwnership.Policy policy, long value) throws Exception {
            if (draining) throw new Failure("display_owner_draining");
            owner.apply(interactive, policy, value); revision = value;
            if (draining || owner.state() != DisplayStateOwnership.State.READY) throw new Failure("display_owner_not_ready");
        }
        synchronized void status() throws Exception {
            if (draining) throw new Failure("display_owner_draining");
            owner.poll();
        }
        boolean retire() {
            draining = true;
            synchronized (this) {
                if (retired) return true;
                try { owner.restore(); backend.synchronizeMutations(); lastError = ""; retired = terminal(); return retired; }
                catch (Throwable failure) { lastError = code(failure); return false; }
            }
        }
        synchronized boolean terminal() {
            if (retired) return true;
            DisplayStateOwnership.State state = owner.state();
            if (state != DisplayStateOwnership.State.RESTORED && state != DisplayStateOwnership.State.YIELDED_EXTERNAL
                    && state != DisplayStateOwnership.State.YIELDED_ACTIVITY) return false;
            try { backend.synchronizeMutations(); return true; } catch (Exception pending) { return false; }
        }
        synchronized boolean settled() { if (retired) return true; try { backend.synchronizeMutations(); return true; } catch (Exception unknown) { return false; } }
    }
    private static final class Lease {
        private final Session session;
        private final long duration;
        private long lastAccepted;
        private boolean expired;
        Lease(Session session, long duration, long start) { this.session = session; this.duration = duration; lastAccepted = start; }
        synchronized boolean expired(long now) {
            if (expired || now - lastAccepted >= duration) { expired = true; session.draining = true; return true; }
            return false;
        }
        synchronized boolean admit(long now) {
            if (session.draining || expired(now)) return false;
            lastAccepted = now; return true;
        }
    }
    private static String code(Throwable failure) {
        String value = failure instanceof Failure ? ((Failure) failure).code
            : failure instanceof DisplayStateOwnership.Failure ? ((DisplayStateOwnership.Failure) failure).code
            : failure instanceof DisplayStateSnapshot.Failure ? ((DisplayStateSnapshot.Failure) failure).code
            : failure instanceof DisplayStateRuntimeBackend.Failure ? failure.getMessage() : "display_controller_operation_failed";
        return value != null && value.matches("[a-z0-9_]{1,96}") ? value : "display_controller_operation_failed";
    }
    private static String snapshot(DisplayStateSnapshot value) {
        if (value == null) return "null";
        StringBuilder out = new StringBuilder("{\"panels\":[");
        for (Map.Entry<String, DisplayStateSnapshot.Mode> panel : value.panels.entrySet()) {
            if (out.charAt(out.length() - 1) != '[') out.append(',');
            out.append("{\"id\":\"").append(panel.getKey()).append("\",\"mode\":\"").append(panel.getValue().name()).append("\"}");
        }
        DisplayStateSnapshot.PowerEvidence p = value.power;
        out.append("],\"activeID\":\"").append(value.activePhysicalID).append("\",\"defaultInteractive\":").append(p.defaultInteractive)
            .append(",\"defaultWakefulness\":");
        if (p.defaultWakefulness == null) out.append("null"); else out.append('"').append(p.defaultWakefulness.name()).append('"');
        out.append(",\"globalWakefulness\":\"").append(p.globalWakefulness.name()).append("\",\"transitionScope\":\"GLOBAL\"")
            .append(",\"lastGlobalWakeTime\":\"").append(p.lastGlobalWakeTime).append("\",\"lastGlobalSleepTime\":\"").append(p.lastGlobalSleepTime)
            .append("\",\"defaultActivityTime\":\"").append(p.defaultActivityTime).append("\",\"defaultActivityNoChangeLightsTime\":\"")
            .append(p.defaultActivityNoChangeLightsTime).append("\"}");
        return out.toString();
    }
    private static final class Writer {
        final OutputStream output;
        final int pid;
        final String start;
        Writer(OutputStream output, int pid, String start) throws Failure {
            if (pid <= 1 || !DisplayStateSnapshot.validID(start) || start.equals("0")) throw new Failure("display_controller_identity_unknown");
            this.output = output; this.pid = pid; this.start = start;
        }
        synchronized void frame(Session session, String event, boolean ok, String error, String reason) throws IOException {
            String line;
            if (session == null) line = "{\"version\":2,\"event\":\"startup_failed\",\"pid\":" + pid + ",\"startTime\":\"" + start
                + "\",\"revision\":0,\"state\":\"NOT_STARTED\",\"draining\":true,\"mutation_settled\":true,\"initial\":null,\"current\":null,\"ok\":false,\"error\":\"" + error + "\",\"reason\":\"startup\"}\n";
            else synchronized (session) {
                line = "{\"version\":2,\"event\":\"" + event + "\",\"pid\":" + pid + ",\"startTime\":\"" + start
                    + "\",\"revision\":" + session.revision + ",\"state\":\"" + session.owner.state().name() + "\",\"draining\":" + session.draining
                    + ",\"mutation_settled\":" + session.settled() + ",\"initial\":" + snapshot(session.owner.initial)
                    + ",\"current\":" + snapshot(session.owner.current()) + ",\"ok\":" + ok + ",\"error\":\"" + error + "\",\"reason\":\"" + reason + "\"}\n";
            }
            byte[] bytes = line.getBytes(StandardCharsets.UTF_8);
            if (bytes.length > MAX_REPLY) throw new Failure("display_controller_reply_limit");
            output.write(bytes); output.flush();
            if (output instanceof PrintStream && ((PrintStream) output).checkError()) throw new IOException("display_controller_output_closed");
        }
    }
    /** Output is advisory after positive restoration. A blocked pipe/Writer monitor
     * must not retain the child after its mutation barrier has completed. This is
     * not a substitute for an independent parent-side retirement proof. */
    private static void finalFrame(final Session session, final Writer writer, final String event,
            final boolean ok, final String error, final String reason) {
        Thread output = new Thread(new Runnable() { public void run() {
            try { writer.frame(session, event, ok, error, reason); } catch (IOException lostOutput) { /* State is already settled. */ }
        } }, "gb-display-state-final-output");
        output.setDaemon(true); output.start();
        try { output.join(200); } catch (InterruptedException interrupted) { Thread.currentThread().interrupt(); }
    }
    private static void finish(Session session, Writer writer, String reason, AtomicBoolean finished, IntConsumer exit) {
        if (finished.compareAndSet(false, true)) {
            finalFrame(session, writer, "retired", true, "", reason);
            exit.accept(0);
        }
    }
    private static void drain(Session session, Writer writer, String reason, AtomicBoolean finished, long retryMillis, IntConsumer exit) {
        session.draining = true;
        while (!finished.get()) {
            if (session.retire()) { finish(session, writer, reason, finished, exit); return; }
            try { Thread.sleep(retryMillis); } catch (InterruptedException shutdown) { /* Never convert an interrupted cleanup into successful exit. */ }
        }
    }
    /** Fixed framing: 0 status; 1 [u8 interactivity 0/1, u8 policy 0..2, i64 revision]; 2 stop.
     * Only a complete accepted command renews the lease. EOF/expiry close policy admission,
     * then keep the process alive until outstanding mutations and restoration settle. */
    static boolean serve(InputStream input, OutputStream output, Session session, int pid, String start, long leaseMillis,
            long retryMillis, Clock clock, IntConsumer exit) throws Exception {
        if (leaseMillis <= 0 || retryMillis <= 0 || retryMillis > leaseMillis) throw new IllegalArgumentException();
        final Writer writer = new Writer(output, pid, start);
        final AtomicBoolean finished = new AtomicBoolean();
        final Lease lease = new Lease(session, leaseMillis, clock.nowMillis());
        Thread deadline = new Thread(new Runnable() { public void run() {
            while (!finished.get()) {
                if (lease.expired(clock.nowMillis())) { drain(session, writer, "lease_expired", finished, retryMillis, exit); return; }
                try { Thread.sleep(Math.min(retryMillis, 200)); } catch (InterruptedException stopped) { if (finished.get()) return; }
            }
        } }, "gb-display-state-deadline");
        deadline.setDaemon(true); boolean valid = true; String reason = "stdin_eof";
        try {
            deadline.start(); writer.frame(session, "ready", true, "", "startup");
            DataInputStream commands = new DataInputStream(input);
            while (!finished.get()) {
                int command = commands.read();
                if (command == -1) break;
                if (command == 2) { reason = "requested"; break; }
                try {
                    if (command == 0) {
                        if (!lease.admit(clock.nowMillis())) { reason = "lease_expired"; break; }
                        session.status();
                    }
                    else if (command == 1) {
                        int interactive = commands.readUnsignedByte(), policy = commands.readUnsignedByte(); long revision = commands.readLong();
                        if (interactive > 1 || policy > 2 || revision <= 0) throw new Failure("display_controller_policy_invalid");
                        if (!lease.admit(clock.nowMillis())) { reason = "lease_expired"; break; }
                        session.apply(interactive == 1, DisplayStateOwnership.Policy.values()[policy], revision);
                    } else throw new Failure("display_controller_command_invalid");
                    if (session.draining || finished.get()) break;
                    writer.frame(session, "reply", true, "", "command");
                } catch (EOFException partial) { valid = false; reason = "incomplete_command"; break; }
                catch (Exception failure) {
                    valid = false; reason = "command_failed"; writer.frame(session, "reply", false, code(failure), reason); break;
                }
            }
            return valid;
        } finally {
            drain(session, writer, reason, finished, retryMillis, exit);
            deadline.interrupt();
        }
    }
    private static String stat() throws IOException {
        try (InputStream input = new FileInputStream("/proc/self/stat"); ByteArrayOutputStream out = new ByteArrayOutputStream()) {
            byte[] bytes = new byte[512]; int count;
            while ((count = input.read(bytes)) != -1) { if (out.size() + count > 4096) throw new IOException("display_controller_stat_limit"); out.write(bytes, 0, count); }
            return new String(out.toByteArray(), StandardCharsets.UTF_8);
        }
    }
    public static void main(String[] args) {
        Session session = null; Writer writer = null;
        try {
            if (args.length != 1 || !args[0].equals("--owner-lease") || android.os.Process.myUid() != 2000)
                throw new Failure("display_controller_shell_required");
            String raw = stat(); String[] fields = raw.substring(raw.lastIndexOf(')') + 1).trim().split("\\s+");
            if (fields.length < 20) throw new Failure("display_controller_identity_unknown");
            int pid = android.os.Process.myPid(); writer = new Writer(new FileOutputStream(FileDescriptor.out), pid, fields[19]);
            try { Os.setsid(); } catch (android.system.ErrnoException alreadyLeader) { if (Integer.parseInt(fields[3]) != pid) throw alreadyLeader; }
            final AtomicBoolean setupSettled = new AtomicBoolean(); final Writer startup = writer;
            Thread setupDeadline = new Thread(new Runnable() { public void run() {
                try { Thread.sleep(8000); } catch (InterruptedException complete) { return; }
                if (setupSettled.compareAndSet(false, true)) {
                    finalFrame(null, startup, "startup_failed", false, "display_controller_startup_timeout", "startup");
                    System.exit(2); // Only read-only preparation has been admitted.
                }
            } }, "gb-display-state-startup"); setupDeadline.setDaemon(true); setupDeadline.start();
            Ln.initLogLevel(Ln.Level.ERROR); if (Looper.myLooper() == null) Looper.prepare(); Workarounds.apply();
            session = new Session(DisplayStateRuntimeBackend.open());
            // Timeout claims admission before sending its bounded final frame.
            // Preparation finishing during that frame must never accept a policy.
            if (!setupSettled.compareAndSet(false, true)) { System.exit(2); return; }
            setupDeadline.interrupt();
            final Session owned = session;
            Runtime.getRuntime().addShutdownHook(new Thread(new Runnable() { public void run() {
                while (!owned.retire()) try { Thread.sleep(1000); } catch (InterruptedException ignored) {}
            } }, "gb-display-state-restore"));
            boolean valid = serve(System.in, new FileOutputStream(FileDescriptor.out), session, pid, fields[19], 12000, 200,
                new Clock() { public long nowMillis() { return SystemClock.elapsedRealtime(); } }, new IntConsumer() { public void accept(int code) { System.exit(code); } });
            System.exit(valid ? 0 : 1);
        } catch (Throwable failure) {
            if (session == null) {
                if (writer != null) finalFrame(null, writer, "startup_failed", false, code(failure), "startup");
                System.exit(2);
            }
            // IO failures do not detach a still-mutating child. A terminal frame
            // on this transport is not an independent proof after parent loss.
            while (!session.retire()) try { Thread.sleep(1000); } catch (InterruptedException ignored) {}
            System.exit(1);
        }
    }
}
