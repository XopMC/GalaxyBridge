package com.genymobile.scrcpy;

import java.util.*;

public final class DisplayStatePowerCallsTest {
    public static class DefaultPort {
        final List<String> calls = new ArrayList<>();
        boolean interactive, failRead, failWrite;
        public boolean isDisplayInteractive(int display) {
            if (failRead) throw new IllegalStateException("binder_read_failed");
            calls.add("read:" + display); return interactive;
        }
        public void wakeUp(long time, int reason, String details, String pkg) {
            calls.add("wake_default:" + time + ":" + reason + ":" + details + ":" + pkg);
            if (failWrite) throw new SecurityException("write_rejected");
        }
        public void goToSleepWithDisplayId(int display, long time, int reason, int flags) {
            calls.add("sleep:" + display + ":" + time + ":" + reason + ":" + flags);
        }
        public void userActivity(int display, long time, int event, int flags) {
            calls.add("activity:" + display + ":" + time + ":" + event + ":" + flags);
        }
    }
    public static class DisplayPort extends DefaultPort {
        public void wakeUpWithDisplayId(long time, int reason, String details, String pkg, int display) {
            calls.add("wake_display:" + display + ":" + time + ":" + reason + ":" + details + ":" + pkg);
            if (failWrite) throw new SecurityException("write_rejected");
        }
    }
    public static class GlobalOnly {
        public boolean isInteractive() { throw new AssertionError("global fallback must never be invoked"); }
    }
    public static class BoxedRead { public Boolean isDisplayInteractive(int display) { return false; } }
    interface Throwing { void run() throws Exception; }
    static void reject(Throwing action) throws Exception {
        try { action.run(); throw new AssertionError("unsafe power call accepted"); }
        catch (ReflectiveOperationException | IllegalArgumentException expected) {}
    }
    public static void main(String[] args) throws Exception {
        DisplayPort current = new DisplayPort(); DisplayStatePowerCalls power = new DisplayStatePowerCalls(DisplayPort.class, current);
        assert current.calls.isEmpty() : "all methods must be bound before the first mutation";
        assert !power.defaultInteractive() && current.calls.equals(Arrays.asList("read:0"));
        current.interactive = true; assert power.defaultInteractive();
        power.wake(900); power.activityWithoutLights(920);
        power.sleep(900, DisplayStateSnapshot.Wakefulness.DOZING);
        power.sleep(900, DisplayStateSnapshot.Wakefulness.ASLEEP);
        assert current.calls.contains("wake_display:0:900:2:galaxybridge:remote-display:com.android.shell");
        assert current.calls.contains("activity:0:920:0:1") : "only default display + OTHER + NO_CHANGE_LIGHTS";
        assert current.calls.contains("sleep:0:900:0:0") && current.calls.contains("sleep:0:900:0:1") : "sleep reuses the immutable owned event time";
        assert !current.calls.stream().anyMatch(value -> value.startsWith("wake_default"));
        reject(() -> power.sleep(900, DisplayStateSnapshot.Wakefulness.AWAKE));
        reject(() -> power.sleep(900, null)); reject(() -> power.wake(0)); reject(() -> power.activityWithoutLights(-1));
        current.failRead = true;
        try { power.defaultInteractive(); throw new AssertionError("failed read became false"); }
        catch (IllegalStateException expected) { assert expected.getMessage().equals("binder_read_failed"); }
        current.failWrite = true;
        try { power.wake(950); throw new AssertionError("write error swallowed"); }
        catch (SecurityException expected) { assert expected.getMessage().equals("write_rejected"); }
        DefaultPort older = new DefaultPort(); new DisplayStatePowerCalls(DefaultPort.class, older).wake(400);
        assert older.calls.equals(Arrays.asList("wake_default:400:2:galaxybridge:remote-display:com.android.shell"));
        reject(() -> new DisplayStatePowerCalls(GlobalOnly.class, new GlobalOnly()));
        reject(() -> new DisplayStatePowerCalls(BoxedRead.class, new BoxedRead()));
        reject(() -> new DisplayStatePowerCalls(DisplayPort.class, new Object()));
        assert current.calls.stream().noneMatch(value -> value.contains("isInteractive"));
        System.out.println("PASS exact default-display power signatures, prebound APIs, old owned sleep timestamp, NO_CHANGE_LIGHTS and throwing failures without global fallback");
    }
}
