package com.genymobile.scrcpy;

import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;

/** Fixed IPowerManager operations. Errors stay errors; no global-interactivity or POWER-toggle fallback. */
final class DisplayStatePowerCalls {
    private final Object manager;
    private final Method interactive, wake, sleep, activity;
    private final boolean explicitWakeDisplay;
    DisplayStatePowerCalls(Class<?> type, Object target) throws ReflectiveOperationException {
        if (type == null || target == null || !type.isInstance(target)) throw new IllegalArgumentException("display_power_interface_invalid");
        manager = target;
        interactive = method(type, "isDisplayInteractive", boolean.class, int.class);
        Method displayWake;
        try { displayWake = type.getMethod("wakeUpWithDisplayId", long.class, int.class, String.class, String.class, int.class); }
        catch (NoSuchMethodException older) { displayWake = null; }
        if (displayWake != null) {
            if (displayWake.getReturnType() != void.class) throw new NoSuchMethodException("display_wake_signature_invalid");
            wake = displayWake; explicitWakeDisplay = true;
        } else {
            // This older API explicitly targets the default display group in AOSP.
            wake = method(type, "wakeUp", void.class, long.class, int.class, String.class, String.class); explicitWakeDisplay = false;
        }
        sleep = method(type, "goToSleepWithDisplayId", void.class, int.class, long.class, int.class, int.class);
        activity = method(type, "userActivity", void.class, int.class, long.class, int.class, int.class);
    }
    static DisplayStatePowerCalls connect() throws Exception {
        Class<?> binder = Class.forName("android.os.IBinder"), type = Class.forName("android.os.IPowerManager");
        Object service = Class.forName("android.os.ServiceManager").getDeclaredMethod("getService", String.class).invoke(null, "power");
        if (service == null || !binder.isInstance(service)) throw new IllegalStateException("display_power_service_unavailable");
        Object manager = Class.forName("android.os.IPowerManager$Stub").getMethod("asInterface", binder).invoke(null, service);
        return new DisplayStatePowerCalls(type, manager);
    }
    private static Method method(Class<?> type, String name, Class<?> result, Class<?>... parameters) throws ReflectiveOperationException {
        Method value = type.getMethod(name, parameters);
        if (value.getReturnType() != result) throw new NoSuchMethodException("display_power_signature_invalid");
        return value;
    }
    private Object call(Method method, Object... args) throws Exception {
        try { return method.invoke(manager, args); }
        catch (InvocationTargetException failure) {
            Throwable cause = failure.getCause();
            if (cause instanceof Exception) throw (Exception) cause;
            if (cause instanceof Error) throw (Error) cause;
            throw new ReflectiveOperationException("display_power_invocation_failed", cause);
        }
    }
    private static void eventTime(long time) {
        if (time <= 0) throw new IllegalArgumentException("display_power_event_time_invalid");
    }
    boolean defaultInteractive() throws Exception {
        Object value = call(interactive, 0);
        if (!(value instanceof Boolean)) throw new ReflectiveOperationException("display_interactivity_reply_invalid");
        return (Boolean) value;
    }
    void wake(long ownedEventTime) throws Exception {
        eventTime(ownedEventTime);
        if (explicitWakeDisplay) call(wake, ownedEventTime, 2, "galaxybridge:remote-display", "com.android.shell", 0);
        else call(wake, ownedEventTime, 2, "galaxybridge:remote-display", "com.android.shell");
    }
    void sleep(long ownedEventTime, DisplayStateSnapshot.Wakefulness target) throws Exception {
        eventTime(ownedEventTime);
        if (target != DisplayStateSnapshot.Wakefulness.ASLEEP && target != DisplayStateSnapshot.Wakefulness.DOZING)
            throw new IllegalArgumentException("display_sleep_target_invalid");
        call(sleep, 0, ownedEventTime, 0, target == DisplayStateSnapshot.Wakefulness.ASLEEP ? 1 : 0);
    }
    void activityWithoutLights(long time) throws Exception {
        eventTime(time); call(activity, 0, time, 0, 1); // default display, OTHER, NO_CHANGE_LIGHTS
    }
}
