package com.genymobile.scrcpy;

import java.io.*;
import java.util.concurrent.*;
import java.util.concurrent.atomic.*;

public final class DisplayStateControllerTest {
    static byte[] commands(boolean stop) throws IOException {
        ByteArrayOutputStream bytes = new ByteArrayOutputStream(); DataOutputStream out = new DataOutputStream(bytes);
        policy(out, true, 1, 1); out.writeByte(0); policy(out, true, 0, 2); policy(out, true, 1, 3);
        if (stop) out.writeByte(2); return bytes.toByteArray();
    }
    static void policy(DataOutputStream out, boolean interactive, int mode, long revision) throws IOException {
        out.writeByte(1); out.writeByte(interactive ? 1 : 0); out.writeByte(mode); out.writeLong(revision); out.flush();
    }
    static DisplayStateController.Clock clock() { return () -> TimeUnit.NANOSECONDS.toMillis(System.nanoTime()); }
    static boolean serve(InputStream input, OutputStream output, DisplayStateController.Session session, long lease, java.util.function.IntConsumer exit) throws Exception {
        return DisplayStateController.serve(input, output, session, 123, "456", lease, 5, clock(), exit);
    }
    public static void main(String[] args) throws Exception {
        if (args.length == 1 && args[0].equals("wire-startup-failed")) {
            Class<?> type = Class.forName("com.genymobile.scrcpy.DisplayStateController$Writer");
            java.lang.reflect.Constructor<?> constructor = type.getDeclaredConstructor(OutputStream.class, int.class, String.class);
            constructor.setAccessible(true);
            Object writer = constructor.newInstance(System.out, 123, "456");
            java.lang.reflect.Method frame = type.getDeclaredMethod("frame", DisplayStateController.Session.class,
                    String.class, boolean.class, String.class, String.class);
            frame.setAccessible(true);
            frame.invoke(writer, null, "startup_failed", false, "display_default_wakefulness_unknown", "startup");
            return;
        }
        if (args.length == 1 && args[0].equals("wire")) {
            serve(new ByteArrayInputStream(commands(true)), System.out,
                new DisplayStateController.Session(new DisplayStateOwnershipTest.Backend()), 10000, code -> {}); return;
        }
        DisplayStateOwnershipTest.Backend backend = new DisplayStateOwnershipTest.Backend();
        DisplayStateController.Session session = new DisplayStateController.Session(backend);
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        assert serve(new ByteArrayInputStream(commands(true)), bytes, session, 10000, code -> {});
        assert session.terminal() && !backend.interactive && backend.panels.get("20") == DisplayStateSnapshot.Mode.DOZE;
        assert bytes.toString("UTF-8").contains("\"version\":2") && bytes.toString("UTF-8").contains("\"event\":\"retired\"");
        DisplayStateOwnershipTest.Backend eof = new DisplayStateOwnershipTest.Backend();
        assert serve(new ByteArrayInputStream(commands(false)), new ByteArrayOutputStream(), new DisplayStateController.Session(eof), 10000, code -> {});
        assert !eof.interactive && eof.panels.get("20") == DisplayStateSnapshot.Mode.DOZE;
        DisplayStateOwnershipTest.Backend malformed = new DisplayStateOwnershipTest.Backend();
        assert !serve(new ByteArrayInputStream(new byte[] {1,2,1,0,0,0,0,0,0,0,1}), new ByteArrayOutputStream(), new DisplayStateController.Session(malformed), 10000, code -> {});
        assert malformed.wakes == 0 && malformed.writes == 0;
        testExpiryAndRenewal(); testDrainBlocksNewPolicies(); testLostOutput(); testBlockedOutput(false); testBlockedOutput(true); testTerminalRetirementIsSticky(false); testTerminalRetirementIsSticky(true); testExpiredCommandCannotReviveLease(); testEofRetainsPendingMutation();
        System.out.println("PASS actual composite controller: typed framing, EOF/deadline restoration, renewal, partial command expiry, drain-only admission, output failure and pending cleanup retention");
    }
    static void testExpiryAndRenewal() throws Exception {
        DisplayStateOwnershipTest.Backend backend = new DisplayStateOwnershipTest.Backend();
        DisplayStateController.Session session = new DisplayStateController.Session(backend);
        PipedInputStream input = new PipedInputStream(); PipedOutputStream pipe = new PipedOutputStream(input);
        ByteArrayOutputStream output = new ByteArrayOutputStream(); CountDownLatch exited = new CountDownLatch(1);
        AtomicReference<Throwable> failed = new AtomicReference<>(); AtomicInteger status = new AtomicInteger(-1);
        Thread server = new Thread(() -> { try { serve(input, output, session, 150, code -> { status.set(code); exited.countDown(); }); }
            catch (Throwable error) { failed.set(error); } }); server.setDaemon(true); server.start();
        try {
            DataOutputStream commands = new DataOutputStream(pipe); policy(commands, true, 1, 1);
            for (int i = 0; i < 5; ++i) { commands.writeByte(0); commands.flush(); Thread.sleep(50); assert exited.getCount() == 1; }
            // An incomplete policy does not renew the lease or block its independent retirement thread.
            commands.write(new byte[] {1,1}); commands.flush();
            assert exited.await(2, TimeUnit.SECONDS) && status.get() == 0;
            assert session.terminal() && !backend.interactive && backend.wakes == 1;
        } finally { pipe.close(); server.join(1000); input.close(); }
        assert !server.isAlive() && failed.get() == null;
    }
    static void testDrainBlocksNewPolicies() throws Exception {
        DisplayStateOwnershipTest.Backend backend = new DisplayStateOwnershipTest.Backend();
        DisplayStateController.Session session = new DisplayStateController.Session(backend);
        session.apply(true, DisplayStateOwnership.Policy.HIDE, 1);
        backend.ignoreSleep = true; assert !session.retire(); assert !session.terminal();
        int wakeCount = backend.wakes;
        try { session.apply(true, DisplayStateOwnership.Policy.SHOW, 2); throw new AssertionError("draining owner accepted another policy"); }
        catch (DisplayStateController.Failure expected) {}
        assert backend.wakes == wakeCount;
        backend.ignoreSleep = false; backend.physicalSleep();
        assert session.retire() && session.terminal() : "pending/unconfirmed cleanup must be retained until a terminal observation";
    }
    // A parent that keeps stdout open but never reads must not prevent the lease
    // restoring the device and exiting. Exercise both the ready and policy reply.
    static void testBlockedOutput(boolean afterPolicy) throws Exception {
        DisplayStateOwnershipTest.Backend backend = new DisplayStateOwnershipTest.Backend();
        DisplayStateController.Session session = new DisplayStateController.Session(backend);
        if (!afterPolicy) session.apply(true, DisplayStateOwnership.Policy.HIDE, 1);
        PipedInputStream input = new PipedInputStream(); PipedOutputStream pipe = new PipedOutputStream(input);
        CountDownLatch blocked = new CountDownLatch(1), release = new CountDownLatch(1), exited = new CountDownLatch(1);
        AtomicInteger lines = new AtomicInteger(); AtomicReference<Throwable> failed = new AtomicReference<>();
        OutputStream output = new OutputStream() {
            public void write(int value) throws IOException {
                if (!afterPolicy || lines.get() >= 1) {
                    blocked.countDown();
                    try { release.await(); } catch (InterruptedException error) { throw new IOException(error); }
                }
                if (value == '\n') lines.incrementAndGet();
            }
        };
        Thread server = new Thread(() -> { try { serve(input, output, session, 100, code -> exited.countDown()); }
            catch (Throwable error) { failed.set(error); } }); server.setDaemon(true); server.start();
        try {
            if (afterPolicy) policy(new DataOutputStream(pipe), true, 1, 1);
            assert blocked.await(1, TimeUnit.SECONDS) : "test never blocked a real frame write";
            assert exited.await(2, TimeUnit.SECONDS) : "stalled stdout blocked terminal exit";
            assert session.terminal() && !backend.interactive && backend.panels.get("20") == DisplayStateSnapshot.Mode.DOZE;
        } finally { release.countDown(); pipe.close(); server.join(1000); input.close(); }
        assert !server.isAlive() && failed.get() == null;
    }
    static void testTerminalRetirementIsSticky(boolean activityYield) throws Exception {
        DisplayStateOwnershipTest.Backend backend = new DisplayStateOwnershipTest.Backend();
        DisplayStateController.Session session = new DisplayStateController.Session(backend);
        session.apply(true, DisplayStateOwnership.Policy.HIDE, 1);
        if (activityYield) backend.activity = backend.now + 10;
        else backend.panels.put("20", DisplayStateSnapshot.Mode.ON);
        assert session.retire();
        assert session.owner.state() == (activityYield ? DisplayStateOwnership.State.YIELDED_ACTIVITY : DisplayStateOwnership.State.YIELDED_EXTERNAL);
        int reads = backend.reads;
        backend.afterNextRead = () -> { throw new IllegalStateException("service unavailable after confirmed retirement"); };
        assert session.retire() && session.terminal() && session.settled() : "shutdown must retain a confirmed terminal disposition";
        assert backend.reads == reads : "confirmed drain must never reacquire device ownership or re-read for shutdown";
    }
    static void testExpiredCommandCannotReviveLease() throws Exception {
        DisplayStateOwnershipTest.Backend backend = new DisplayStateOwnershipTest.Backend();
        DisplayStateController.Session session = new DisplayStateController.Session(backend);
        AtomicInteger foregroundReads = new AtomicInteger(); CountDownLatch releaseWatchdog = new CountDownLatch(1);
        DisplayStateController.Clock delayedWatchdog = () -> {
            if (Thread.currentThread().getName().equals("gb-display-state-deadline")) {
                try { releaseWatchdog.await(); } catch (InterruptedException ignored) {}
                return 101;
            }
            return foregroundReads.getAndIncrement() == 0 ? 0 : 101;
        };
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        try {
            DisplayStateController.serve(new ByteArrayInputStream(commands(true)), output, session, 123, "456", 100, 5,
                delayedWatchdog, code -> {});
            assert backend.wakes == 0 && backend.writes == 0 : "a complete command revived a lease whose deadline had already elapsed";
            assert session.terminal() && output.toString("UTF-8").contains("lease_expired");
        } finally { releaseWatchdog.countDown(); }
    }
    static void testEofRetainsPendingMutation() throws Exception {
        DisplayStateOwnershipTest.Backend backend = new DisplayStateOwnershipTest.Backend(); backend.initiallyAwake();
        DisplayStateController.Session session = new DisplayStateController.Session(backend); backend.queueNextWrite = true;
        CountDownLatch exited = new CountDownLatch(1); AtomicReference<Throwable> failed = new AtomicReference<>();
        Thread server = new Thread(() -> { try {
            serve(new ByteArrayInputStream(commands(false)), new ByteArrayOutputStream(), session, 1000, code -> exited.countDown());
        } catch (Throwable error) { failed.set(error); } }); server.setDaemon(true); server.start();
        try {
            long limit = System.nanoTime() + TimeUnit.SECONDS.toNanos(1); boolean pending = false;
            while (System.nanoTime() < limit) {
                synchronized (session) { pending = backend.pendingPanel != null && session.draining; }
                if (pending) break;
                Thread.sleep(5);
            }
            assert pending : "test never reached a pending real engine write";
            assert !exited.await(50, TimeUnit.MILLISECONDS) : "EOF retired a mutation that could still apply later";
            synchronized (session) { backend.finishPendingPanel(); }
            assert exited.await(2, TimeUnit.SECONDS) && session.terminal();
            assert backend.panels.get("20") == DisplayStateSnapshot.Mode.ON && backend.interactive;
        } finally {
            synchronized (session) { if (backend.pendingPanel != null) backend.finishPendingPanel(); }
            server.join(1000);
        }
        assert !server.isAlive() && failed.get() == null;
    }
    static void testLostOutput() throws Exception {
        DisplayStateOwnershipTest.Backend backend = new DisplayStateOwnershipTest.Backend();
        final int[] lines = {0}; OutputStream broken = new OutputStream() {
            public void write(int value) throws IOException { if (lines[0] >= 2) throw new IOException("reader_lost"); if (value == '\n') lines[0]++; }
        };
        DisplayStateController.Session session = new DisplayStateController.Session(backend);
        try { serve(new ByteArrayInputStream(commands(true)), broken, session, 10000, code -> {}); }
        catch (IOException expected) {}
        assert session.terminal() && !backend.interactive && backend.panels.get("20") == DisplayStateSnapshot.Mode.DOZE;
    }
}
