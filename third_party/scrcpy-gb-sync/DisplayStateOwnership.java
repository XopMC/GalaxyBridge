package com.genymobile.scrcpy;

import java.util.*;

/** Single-phone composite state machine. Android I/O and transport lifetime are supplied separately. */
final class DisplayStateOwnership {
    enum Policy { PRESERVE, HIDE, SHOW }
    enum State { SNAPSHOTTED, READY, SUSPENDED, RESTORED, YIELDED_EXTERNAL, YIELDED_ACTIVITY, UNCONFIRMED }
    static final class Failure extends Exception {
        final String code;
        Failure(String code) { super(code); this.code = code; }
    }
    interface Backend {
        /** Stable observation with independently bounded I/O; never mutates Android state. */
        DisplayStateSnapshot read() throws Exception;
        long uptimeMillis();
        void pause() throws Exception;
        void wake(long eventTime) throws Exception;
        /** Must target display 0 with the supplied immutable wake event time, never current time or POWER toggle. */
        void sleep(long ownedWakeEventTime, DisplayStateSnapshot.Wakefulness target) throws Exception;
        void setPanel(String physicalID, DisplayStateSnapshot.Mode mode) throws Exception;
        /** Default display only, OTHER + NO_CHANGE_LIGHTS; must throw on unavailable/failed Binder calls. */
        void activityWithoutLights() throws Exception;
        /** Positive completion barrier for this backend's preceding writes, including calls that threw.
         * Must throw while an earlier wake/panel/activity/sleep operation can still apply later. */
        void synchronizeMutations() throws Exception;
    }
    final DisplayStateSnapshot initial;
    private final Backend backend;
    private DisplayStateSnapshot current, awakeBaseline;
    private DisplayStateSnapshot.PowerEvidence reference;
    private Map<String, DisplayStateSnapshot.Mode> expected;
    private Map<String, DisplayStateSnapshot.Mode> confirmed;
    private State state = State.SNAPSHOTTED;
    private boolean interactiveDemand, wakeAttempted, sleepAttempted, renewalDisabled, sleepAuthorityRevoked;
    private long wakeEventTime = -1, revision;
    private Policy policy;
    private static final long SETTLE_MILLIS = 3000;
    private static final int MAX_OBSERVATIONS = 128;

    DisplayStateOwnership(Backend backend) throws Exception {
        this.backend = backend; initial = backend.read();
        if (initial == null) throw new Failure("display_initial_snapshot_missing");
        if (initial.power.defaultWakefulness == null) throw new Failure("display_default_wakefulness_unknown");
        current = initial; reference = initial.power; expected = new LinkedHashMap<>(initial.panels);
        confirmed = new LinkedHashMap<>(initial.panels);
        if (initial.power.defaultInteractive) awakeBaseline = initial;
    }
    synchronized State state() { return state; }
    synchronized long ownedWakeEventTime() { return wakeEventTime; }
    synchronized DisplayStateSnapshot current() { return current; }

    private boolean topology(DisplayStateSnapshot value) {
        return initial.physicalIDs.equals(value.physicalIDs) && initial.activePhysicalID.equals(value.activePhysicalID);
    }
    private boolean powerAuthority(DisplayStateSnapshot value) {
        // Activity is a conservative invalidation witness, not a universal transition epoch.
        // The Android backend must additionally enforce the timestamp fence when requesting sleep.
        return powerEpoch(value) && value.power.defaultActivityTime == reference.defaultActivityTime;
    }
    private boolean powerEpoch(DisplayStateSnapshot value) {
        return value.power.defaultInteractive == reference.defaultInteractive
            && value.power.defaultWakefulness == reference.defaultWakefulness
            && value.power.lastGlobalWakeTime == reference.lastGlobalWakeTime
            && value.power.lastGlobalSleepTime == reference.lastGlobalSleepTime;
    }
    private void observeActivity(DisplayStateSnapshot value) {
        if (topology(value) && powerEpoch(value) && panelAuthority(value) && value.power.defaultInteractive
                && value.power.defaultActivityTime > reference.defaultActivityTime) {
            // Injected primary-display touches advance this witness too. Keep
            // input alive, but never assume they authorize automatic sleep.
            sleepAuthorityRevoked = true; reference = value.power;
        }
    }
    private void yieldAuthority(DisplayStateSnapshot value) {
        current = value; renewalDisabled = true;
        state = interactiveDemand && !value.power.defaultInteractive ? State.SUSPENDED : State.YIELDED_EXTERNAL;
    }
    private boolean ownedWake(DisplayStateSnapshot value) {
        return wakeAttempted && value.power.defaultInteractive && value.power.defaultWakefulness == DisplayStateSnapshot.Wakefulness.AWAKE
            && value.power.defaultActivityTime == wakeEventTime && value.power.lastGlobalSleepTime == initial.power.lastGlobalSleepTime
            && (value.power.lastGlobalWakeTime == initial.power.lastGlobalWakeTime || value.power.lastGlobalWakeTime == wakeEventTime);
    }
    private DisplayStateSnapshot read() throws Exception {
        DisplayStateSnapshot value = backend.read();
        if (value == null) throw new Failure("display_snapshot_missing");
        if (value.power.defaultWakefulness == null) throw new Failure("display_default_wakefulness_unknown");
        if (current != null && (value.power.defaultActivityTime < current.power.defaultActivityTime
                || value.power.defaultActivityNoChangeLightsTime < current.power.defaultActivityNoChangeLightsTime
                || value.power.lastGlobalWakeTime < current.power.lastGlobalWakeTime
                || value.power.lastGlobalSleepTime < current.power.lastGlobalSleepTime))
            throw new Failure("display_power_time_regressed");
        current = value; return value;
    }
    private void guardOwned(DisplayStateSnapshot value, boolean checkPanels) throws Failure {
        observeActivity(value);
        if (!topology(value) || !powerAuthority(value) || (checkPanels && !expected.equals(value.panels))) {
            yieldAuthority(value); throw new Failure("display_ownership_superseded");
        }
    }
    private void uncertain() {
        renewalDisabled = true;
        if (state != State.SUSPENDED && state != State.YIELDED_EXTERNAL) state = State.UNCONFIRMED;
    }
    private void wake() throws Exception {
        if (wakeAttempted || initial.power.defaultInteractive || initial.power.defaultWakefulness == null
                || initial.power.defaultWakefulness.interactive()) throw new Failure("display_wake_baseline_unavailable");
        // Arm before Binder invocation: the method can apply and then throw.
        wakeEventTime = backend.uptimeMillis();
        if (wakeEventTime <= initial.power.defaultActivityTime) throw new Failure("display_wake_time_unsettled");
        wakeAttempted = true; backend.wake(wakeEventTime); backend.synchronizeMutations();
        long deadline = backend.uptimeMillis() + SETTLE_MILLIS;
        for (int attempt = 0; attempt < MAX_OBSERVATIONS; ++attempt) {
            DisplayStateSnapshot value = read();
            if (!topology(value)) { yieldAuthority(value); throw new Failure("display_topology_superseded"); }
            if (ownedWake(value)) {
                awakeBaseline = value; reference = value.power; expected = new LinkedHashMap<>(value.panels);
                confirmed = new LinkedHashMap<>(value.panels); return;
            }
            if (value.power.defaultActivityTime != initial.power.defaultActivityTime || value.power.defaultInteractive) {
                yieldAuthority(value); throw new Failure("display_wake_superseded");
            }
            if (backend.uptimeMillis() >= deadline) break;
            backend.pause();
        }
        throw new Failure("display_wake_unconfirmed");
    }
    synchronized void apply(boolean interactive, Policy requested, long requestedRevision) throws Exception {
        if (requested == null || requestedRevision <= 0 || requestedRevision < revision
                || (requestedRevision == revision && (requested != policy || interactive != interactiveDemand)))
            throw new Failure("display_policy_revision_invalid");
        if (state == State.RESTORED || state == State.YIELDED_EXTERNAL || state == State.YIELDED_ACTIVITY
                || state == State.SUSPENDED || state == State.UNCONFIRMED)
            throw new Failure("display_owner_not_active");
        if (requestedRevision == revision) { poll(); return; }
        try {
            DisplayStateSnapshot before = read(); guardOwned(before, true);
            interactiveDemand = interactive;
            if (interactive && !before.power.defaultInteractive) wake();
            Map<String, DisplayStateSnapshot.Mode> target = new LinkedHashMap<>();
            if (requested == Policy.PRESERVE) target.putAll((awakeBaseline != null ? awakeBaseline : initial).panels);
            else for (String id : initial.physicalIDs) target.put(id,
                requested == Policy.SHOW && id.equals(initial.activePhysicalID) ? DisplayStateSnapshot.Mode.ON : DisplayStateSnapshot.Mode.OFF);
            writeTarget(target, requested == Policy.PRESERVE);
            revision = requestedRevision; policy = requested; state = State.READY;
        } catch (Exception failure) { uncertain(); throw failure instanceof Failure ? (Failure) failure : new Failure("display_operation_failed"); }
    }
    private void write(String id, DisplayStateSnapshot.Mode mode) throws Exception {
        expected.put(id, mode); // arm ownership before a potentially partially applied write
        backend.setPanel(id, mode); backend.synchronizeMutations();
    }
    private void confirmPanels(Map<String, DisplayStateSnapshot.Mode> target) throws Exception {
        long deadline = backend.uptimeMillis() + SETTLE_MILLIS;
        for (int attempt = 0; attempt < MAX_OBSERVATIONS; ++attempt) {
            DisplayStateSnapshot value = read(); guardOwned(value, false);
            if (value.panels.equals(target)) { confirmed = new LinkedHashMap<>(target); return; }
            if (backend.uptimeMillis() >= deadline) break;
            backend.pause();
        }
        throw new Failure("display_panel_state_unconfirmed");
    }
    private void writeTarget(Map<String, DisplayStateSnapshot.Mode> target, boolean baseline) throws Exception {
        // Explicit SHOW enables only the active panel. Baseline policies may
        // restore preexisting modes, after the same identity/posture checks.
        for (String id : initial.physicalIDs) if (target.get(id) == DisplayStateSnapshot.Mode.OFF && current.panels.get(id) != target.get(id)) {
            guardOwned(read(), true); write(id, target.get(id)); confirmPanels(expected);
        }
        for (String id : initial.physicalIDs) if (target.get(id) != DisplayStateSnapshot.Mode.OFF && current.panels.get(id) != target.get(id)) {
            if (!id.equals(initial.activePhysicalID) && (!baseline || (target.get(id) != initial.panels.get(id)
                    && (awakeBaseline == null || target.get(id) != awakeBaseline.panels.get(id)))))
                throw new Failure("display_inactive_panel_enable_rejected");
            guardOwned(read(), true); write(id, target.get(id)); confirmPanels(expected);
        }
        confirmPanels(target);
    }
    synchronized void poll() throws Exception {
        if (state != State.READY || renewalDisabled) return;
        try {
            DisplayStateSnapshot value = read();
            observeActivity(value);
            if (!topology(value) || !powerAuthority(value) || !expected.equals(value.panels)) { yieldAuthority(value); return; }
            if (interactiveDemand && value.power.defaultInteractive) { backend.activityWithoutLights(); backend.synchronizeMutations(); }
        } catch (Exception failure) { uncertain(); throw failure instanceof Failure ? (Failure) failure : new Failure("display_operation_failed"); }
    }
    private boolean restorationState(DisplayStateSnapshot value) {
        return topology(value) && value.panels.equals(initial.panels) && value.power.defaultInteractive == initial.power.defaultInteractive
            && value.power.defaultWakefulness == initial.power.defaultWakefulness;
    }
    private boolean panelAuthority(DisplayStateSnapshot value) {
        for (String id : initial.physicalIDs) {
            DisplayStateSnapshot.Mode mode = value.panels.get(id);
            // At most the last confirmed value and one pending target, never a history of old modes.
            if (mode != confirmed.get(id) && mode != expected.get(id)) return false;
        }
        return true;
    }
    private void finishYield() throws Exception { finishYield(State.YIELDED_EXTERNAL); }
    private void finishYield(State disposition) throws Exception { current = read(); state = disposition; }
    private boolean settleSleep() throws Exception {
        long deadline = backend.uptimeMillis() + SETTLE_MILLIS;
        for (int attempt = 0; attempt < MAX_OBSERVATIONS; ++attempt) {
            DisplayStateSnapshot value = read();
            if (!topology(value) || value.power.defaultActivityTime != wakeEventTime
                    || value.power.lastGlobalWakeTime != reference.lastGlobalWakeTime) { yieldAuthority(value); return false; }
            if (!value.power.defaultInteractive && value.power.defaultWakefulness == initial.power.defaultWakefulness
                    && value.panels.equals(initial.panels)) { reference = value.power; return true; }
            if (backend.uptimeMillis() >= deadline) break;
            backend.pause();
        }
        // Give the OS a bounded chance to restore ambient panels itself. A
        // newly observed mode never replaces the last confirmed/pending write.
        if (!current.power.defaultInteractive && current.power.defaultWakefulness == initial.power.defaultWakefulness) {
            reference = current.power; return true;
        }
        throw new Failure("display_sleep_unconfirmed");
    }
    synchronized void restore() throws Exception {
        renewalDisabled = true;
        if (state == State.RESTORED) return;
        if (state == State.YIELDED_ACTIVITY) { finishYield(State.YIELDED_ACTIVITY); return; }
        if (state == State.SUSPENDED || state == State.YIELDED_EXTERNAL) { finishYield(); return; }
        try {
            backend.synchronizeMutations();
            DisplayStateSnapshot before = read();
            if (wakeAttempted && awakeBaseline == null && !sleepAttempted && !ownedWake(before))
                throw new Failure("display_wake_outcome_unconfirmed");
            if (!topology(before)) { yieldAuthority(before); finishYield(); return; }
            // Recover an interrupted wake only with the separately armed exact event-time witness.
            if (wakeAttempted && !sleepAttempted && ownedWake(before)) {
                if (awakeBaseline == null) {
                    awakeBaseline = before; reference = before.power; expected = new LinkedHashMap<>(before.panels);
                    confirmed = new LinkedHashMap<>(before.panels);
                }
            }
            observeActivity(before);
            if (!sleepAttempted && !powerAuthority(before)) { yieldAuthority(before); finishYield(); return; }
            if (!sleepAttempted && !panelAuthority(before)) { yieldAuthority(before); finishYield(); return; }
            if (sleepAuthorityRevoked && wakeAttempted && !initial.power.defaultInteractive && !sleepAttempted
                    && before.power.defaultInteractive) { finishYield(State.YIELDED_ACTIVITY); return; }
            if (wakeAttempted && !initial.power.defaultInteractive && before.power.defaultInteractive) {
                if (sleepAttempted) throw new Failure("display_sleep_unconfirmed");
                sleepAttempted = true;
                try { backend.sleep(wakeEventTime, initial.power.defaultWakefulness); }
                catch (Exception possiblyApplied) { /* Only the following complete observation can establish restoration. */ }
                backend.synchronizeMutations();
                if (!settleSleep()) { finishYield(); return; }
                before = current;
            } else if (sleepAttempted) {
                if (!settleSleep()) { finishYield(); return; }
                before = current;
            }
            // Do not treat unfamiliar post-sleep/AOD modes as our writes.
            // Natural exact restoration needs no additional panel command.
            if (restorationState(before)) { state = State.RESTORED; return; }
            for (String id : initial.physicalIDs) if (before.panels.get(id) != initial.panels.get(id)
                    && before.panels.get(id) != confirmed.get(id) && before.panels.get(id) != expected.get(id))
                throw new Failure("display_restore_panel_authority_unknown");
            expected = new LinkedHashMap<>(before.panels);
            confirmed = new LinkedHashMap<>(before.panels);
            writeTarget(initial.panels, true);
            if (!restorationState(read())) throw new Failure("display_restore_unconfirmed");
            state = State.RESTORED;
        } catch (Exception failure) { uncertain(); throw failure instanceof Failure ? (Failure) failure : new Failure("display_operation_failed"); }
    }
}
