package com.genymobile.scrcpy;

import java.io.IOException;
import java.util.*;

/** Actual composite engine with synthetic Android state transitions; no device access. */
public final class DisplayStateOwnershipTest {
    static final DisplayStateSnapshot.Mode OFF = DisplayStateSnapshot.Mode.OFF, ON = DisplayStateSnapshot.Mode.ON,
        DOZE = DisplayStateSnapshot.Mode.DOZE;
    static final class Backend implements DisplayStateOwnership.Backend {
        final Map<String, DisplayStateSnapshot.Mode> panels = new LinkedHashMap<>();
        final List<String> operations = new ArrayList<>();
        String active = "20", wakefulness = "3";
        boolean interactive, otherGroupAwake, ignoreSleep, ignoreWake;
        long now = 1000, activity = 100, noLights = 80, wake = 100, sleep = 200, defaultWake = 100;
        int failedWrite = -1, writes, reads, wakes, sleeps, renewals;
        boolean failWakeAfterApply, failSleepAfterApply, failNextWriteBeforeApply, omitGroupWakefulness;
        Runnable afterNextRead;
        Exception failNextRead;
        DisplayStateSnapshot.Mode modeAfterSleep;
        String failNextBeforeID;
        boolean queueNextWrite;
        String pendingPanel;
        DisplayStateSnapshot.Mode pendingMode;
        Backend() { panels.put("10", OFF); panels.put("20", DOZE); }
        void initiallyAwake() { interactive = true; wakefulness = "1"; panels.put("20", ON); wake = 300; activity = 300; defaultWake = 300; }
        public DisplayStateSnapshot read() throws Exception {
            if (++reads > 10000) throw new AssertionError("unbounded controller observations");
            if (failNextRead != null) { Exception failure = failNextRead; failNextRead = null; throw failure; }
            String global = interactive || otherGroupAwake ? "Awake" : wakefulness.equals("0") ? "Asleep" : "Dozing";
            String dump = "Power Manager State:\n  mWakefulness=" + global + "\n  mWakefulnessChanging=false\n"
                + "  mLastWakeTime=" + wake + "\n  mLastSleepTime=" + sleep + "\n\n"
                + "Power Group User Activity:\ngroupId: 0\nlastUserActivityTime=" + activity
                + "\nlastUserActivityTimeNoChangeLights=" + noLights + "\n" + (omitGroupWakefulness ? "" : "mWakefulness=" + wakefulness + "\n");
            DisplayStateSnapshot snapshot = new DisplayStateSnapshot(panels, active, panels.keySet(), DisplayStateSnapshot.parsePower(dump, interactive));
            Runnable pending = afterNextRead; afterNextRead = null; if (pending != null) pending.run();
            return snapshot;
        }
        public long uptimeMillis() { return ++now; }
        public void pause() { now += 40; }
        public void wake(long eventTime) throws Exception {
            operations.add("wake:" + eventTime); wakes++;
            if (ignoreWake) return;
            defaultWake = eventTime; activity = eventTime;
            interactive = true; wakefulness = "1"; panels.put(active, ON); if (!otherGroupAwake) wake = eventTime;
            if (failWakeAfterApply) throw new IOException("applied_wake_then_failed");
        }
        public void sleep(long eventTime, DisplayStateSnapshot.Wakefulness target) throws Exception {
            operations.add("sleep:" + eventTime); sleeps++;
            if (eventTime < defaultWake || ignoreSleep) return; // Android's group-specific event-time fence
            interactive = false; wakefulness = target == DisplayStateSnapshot.Wakefulness.ASLEEP ? "0" : "3";
            panels.put(active, target == DisplayStateSnapshot.Wakefulness.ASLEEP ? OFF : DOZE); if (!otherGroupAwake) sleep = now;
            if (modeAfterSleep != null) panels.put(active, modeAfterSleep);
            if (failSleepAfterApply) throw new IOException("applied_sleep_then_failed");
        }
        public void setPanel(String id, DisplayStateSnapshot.Mode mode) throws Exception {
            if (queueNextWrite) {
                queueNextWrite = false; pendingPanel = id; pendingMode = mode;
                throw new IOException("queued_panel_write_outcome_unknown");
            }
            if (id.equals(failNextBeforeID)) { failNextBeforeID = null; throw new IOException("second_panel_failed_before_apply"); }
            if (failNextWriteBeforeApply) { failNextWriteBeforeApply = false; throw new IOException("panel_failed_before_apply"); }
            operations.add(id + ":" + mode); panels.put(id, mode);
            if (++writes == failedWrite) throw new IOException("applied_panel_then_failed");
        }
        public void activityWithoutLights() { operations.add("activity_no_lights"); renewals++; noLights = ++now; }
        public void synchronizeMutations() throws Exception {
            if (pendingPanel != null || ignoreWake) throw new IOException("mutation_still_pending");
        }
        void finishPendingPanel() { panels.put(pendingPanel, pendingMode); pendingPanel = null; pendingMode = null; }
        void physicalSleep() { now += 10; interactive = false; wakefulness = "3"; sleep = now; panels.put(active, DOZE); }
        void physicalWake() { now += 10; interactive = true; wakefulness = "1"; activity = now; defaultWake = now; panels.put(active, ON); if (!otherGroupAwake) wake = now; }
    }
    interface Throwing { void run() throws Exception; }
    static void reject(Throwing action) throws Exception {
        try { action.run(); throw new AssertionError("unsafe controller operation accepted"); }
        catch (DisplayStateOwnership.Failure expected) {}
    }
    static DisplayStateOwnership owner(Backend backend) throws Exception { return new DisplayStateOwnership(backend); }
    public static void main(String[] args) throws Exception {
        Backend diagnostic = new Backend(); diagnostic.initiallyAwake(); DisplayStateOwnership diagnosticOwner = owner(diagnostic);
        Exception original = new DisplayStateSnapshot.Failure("display_snapshot_unsettled"); diagnostic.failNextRead = original;
        try { diagnosticOwner.apply(true, DisplayStateOwnership.Policy.PRESERVE, 1); throw new AssertionError("read failure accepted"); }
        catch (DisplayStateOwnership.Failure failed) {
            assert failed.getCause() == original : "underlying display failure was discarded, preventing hardware diagnosis";
            assert failed.code.equals("display_operation_failed") && diagnosticOwner.state() == DisplayStateOwnership.State.UNCONFIRMED;
        }
        diagnosticOwner.restore(); assert diagnosticOwner.state() == DisplayStateOwnership.State.RESTORED;
        Backend basic = new Backend(); DisplayStateOwnership first = owner(basic);
        first.apply(true, DisplayStateOwnership.Policy.HIDE, 1);
        long token = first.ownedWakeEventTime();
        assert first.state() == DisplayStateOwnership.State.READY && basic.interactive && basic.panels.get("20") == OFF;
        assert first.initial.panels.get("20") == DOZE && !first.initial.power.defaultInteractive;
        assert first.initial.power.defaultActivityTime == 100 : "baseline must be captured before wake";
        first.poll(); assert basic.renewals == 1 && basic.panels.get("10") == OFF && basic.panels.get("20") == OFF;
        first.apply(true, DisplayStateOwnership.Policy.PRESERVE, 2);
        assert basic.wakes == 1 && basic.sleeps == 0 && basic.panels.get("20") == ON && basic.panels.get("10") == OFF;
        first.apply(true, DisplayStateOwnership.Policy.HIDE, 3);
        assert basic.wakes == 1 && basic.sleeps == 0 && basic.panels.get("20") == OFF;
        first.restore(); first.restore();
        assert first.state() == DisplayStateOwnership.State.RESTORED && basic.sleeps == 1 && !basic.interactive;
        assert basic.panels.get("10") == OFF && basic.panels.get("20") == DOZE;
        assert basic.operations.contains("sleep:" + token) : "sleep must use the exact immutable owned wake timestamp";
        assert !basic.operations.contains("10:ON");
        Backend asleep = new Backend(); asleep.wakefulness = "0"; asleep.panels.put("20", OFF);
        DisplayStateOwnership deepSleep = owner(asleep); deepSleep.apply(true, DisplayStateOwnership.Policy.HIDE, 1); deepSleep.restore();
        assert deepSleep.state() == DisplayStateOwnership.State.RESTORED && asleep.wakefulness.equals("0") && asleep.panels.get("20") == OFF;

        Backend awake = new Backend(); awake.initiallyAwake(); DisplayStateOwnership awakeOwner = owner(awake);
        awakeOwner.apply(true, DisplayStateOwnership.Policy.HIDE, 1); awakeOwner.restore();
        assert awake.wakes == 0 && awake.sleeps == 0 && awake.interactive && awake.panels.get("20") == ON;
        Backend idempotent = new Backend(); DisplayStateOwnership repeated = owner(idempotent);
        repeated.apply(true, DisplayStateOwnership.Policy.HIDE, 1); int writes = idempotent.writes;
        repeated.apply(true, DisplayStateOwnership.Policy.HIDE, 1);
        assert idempotent.writes == writes && idempotent.wakes == 1;
        reject(() -> repeated.apply(true, DisplayStateOwnership.Policy.SHOW, 1));
        reject(() -> repeated.apply(false, DisplayStateOwnership.Policy.HIDE, 1));
        reject(() -> repeated.apply(true, DisplayStateOwnership.Policy.HIDE, 0));
        repeated.apply(true, DisplayStateOwnership.Policy.HIDE, 2);
        reject(() -> repeated.apply(true, DisplayStateOwnership.Policy.HIDE, 1));
        repeated.restore(); reject(() -> repeated.apply(true, DisplayStateOwnership.Policy.HIDE, 2));

        Backend sleeping = new Backend(); DisplayStateOwnership noWake = owner(sleeping);
        noWake.apply(false, DisplayStateOwnership.Policy.HIDE, 1); noWake.poll(); noWake.restore();
        assert sleeping.wakes == 0 && sleeping.sleeps == 0 && sleeping.renewals == 0 && sleeping.panels.get("20") == DOZE;
        Backend unknown = new Backend(); unknown.omitGroupWakefulness = true;
        reject(() -> owner(unknown)); assert unknown.operations.isEmpty();
        Backend partial = new Backend(); partial.initiallyAwake(); partial.failedWrite = 1;
        DisplayStateOwnership partialOwner = owner(partial); reject(() -> partialOwner.apply(true, DisplayStateOwnership.Policy.HIDE, 1));
        partialOwner.restore(); assert partialOwner.state() == DisplayStateOwnership.State.RESTORED && partial.panels.get("20") == ON;
        Backend failedWake = new Backend(); failedWake.failWakeAfterApply = true;
        DisplayStateOwnership interrupted = owner(failedWake); reject(() -> interrupted.apply(true, DisplayStateOwnership.Policy.HIDE, 1));
        interrupted.restore(); assert interrupted.state() == DisplayStateOwnership.State.RESTORED && !failedWake.interactive && failedWake.panels.get("20") == DOZE;
        Backend failedSleep = new Backend(); failedSleep.failSleepAfterApply = true;
        DisplayStateOwnership appliedSleep = owner(failedSleep); appliedSleep.apply(true, DisplayStateOwnership.Policy.HIDE, 1); appliedSleep.restore();
        assert appliedSleep.state() == DisplayStateOwnership.State.RESTORED : "an exception after confirmed exact restoration is not false failure";

        Backend panelOnly = new Backend(); DisplayStateOwnership revealed = owner(panelOnly);
        revealed.apply(true, DisplayStateOwnership.Policy.HIDE, 1); panelOnly.panels.put("20", ON);
        revealed.restore();
        assert revealed.state() == DisplayStateOwnership.State.YIELDED_EXTERNAL && panelOnly.sleeps == 0 && panelOnly.interactive;
        Backend failedRestore = new Backend(); failedRestore.initiallyAwake(); DisplayStateOwnership retry = owner(failedRestore);
        retry.apply(true, DisplayStateOwnership.Policy.HIDE, 1); failedRestore.failNextWriteBeforeApply = true;
        reject(retry::restore); assert failedRestore.panels.get("20") == OFF;
        retry.restore(); assert retry.state() == DisplayStateOwnership.State.RESTORED && failedRestore.panels.get("20") == ON;
        Backend both = new Backend(); both.initiallyAwake(); both.panels.put("10", ON);
        DisplayStateOwnership exactBoth = owner(both); exactBoth.apply(true, DisplayStateOwnership.Policy.HIDE, 1);
        exactBoth.restore(); assert both.panels.get("10") == ON && both.panels.get("20") == ON;
        Backend secondFailure = new Backend(); secondFailure.initiallyAwake(); secondFailure.panels.put("10", ON);
        DisplayStateOwnership twoPanels = owner(secondFailure); twoPanels.apply(true, DisplayStateOwnership.Policy.HIDE, 1);
        secondFailure.failNextBeforeID = "20"; reject(twoPanels::restore);
        assert secondFailure.panels.get("10") == ON && secondFailure.panels.get("20") == OFF;
        twoPanels.restore(); assert twoPanels.state() == DisplayStateOwnership.State.RESTORED && secondFailure.panels.get("20") == ON;
        Backend pending = new Backend(); pending.ignoreWake = true; DisplayStateOwnership delayed = owner(pending);
        reject(() -> delayed.apply(true, DisplayStateOwnership.Policy.HIDE, 1));
        reject(delayed::restore);
        assert delayed.state() == DisplayStateOwnership.State.UNCONFIRMED : "an unchanged sleeping snapshot cannot retire a potentially pending wake";
        Backend ambient = new Backend(); ambient.modeAfterSleep = DisplayStateSnapshot.Mode.DOZE_SUSPEND;
        DisplayStateOwnership changedAmbient = owner(ambient); changedAmbient.apply(true, DisplayStateOwnership.Policy.HIDE, 1);
        int beforeSleepWrites = ambient.writes; reject(changedAmbient::restore);
        assert changedAmbient.state() == DisplayStateOwnership.State.UNCONFIRMED && ambient.writes == beforeSleepWrites;
        assert ambient.panels.get("20") == DisplayStateSnapshot.Mode.DOZE_SUSPEND : "a fresh post-sleep mode is observation, never newly acquired write authority";
        Backend missing = new Backend(); DisplayStateOwnership lostEvidence = owner(missing);
        lostEvidence.apply(true, DisplayStateOwnership.Policy.HIDE, 1); missing.omitGroupWakefulness = true;
        reject(lostEvidence::poll); assert lostEvidence.state() == DisplayStateOwnership.State.UNCONFIRMED;
        reject(lostEvidence::restore); assert missing.sleeps == 0;
        missing.omitGroupWakefulness = false; lostEvidence.restore();
        assert lostEvidence.state() == DisplayStateOwnership.State.RESTORED && !missing.interactive;
        Backend missingAtClose = new Backend(); DisplayStateOwnership closeEvidence = owner(missingAtClose);
        closeEvidence.apply(true, DisplayStateOwnership.Policy.HIDE, 1); missingAtClose.omitGroupWakefulness = true;
        reject(closeEvidence::restore); assert closeEvidence.state() == DisplayStateOwnership.State.UNCONFIRMED && missingAtClose.sleeps == 0;
        missingAtClose.omitGroupWakefulness = false; closeEvidence.restore();
        assert closeEvidence.state() == DisplayStateOwnership.State.RESTORED;
        Backend delayedPanel = new Backend(); delayedPanel.initiallyAwake(); delayedPanel.queueNextWrite = true;
        DisplayStateOwnership queued = owner(delayedPanel); reject(() -> queued.apply(true, DisplayStateOwnership.Policy.HIDE, 1));
        reject(queued::restore); assert queued.state() == DisplayStateOwnership.State.UNCONFIRMED && delayedPanel.panels.get("20") == ON;
        delayedPanel.finishPendingPanel(); queued.restore();
        assert queued.state() == DisplayStateOwnership.State.RESTORED && delayedPanel.panels.get("20") == ON;
        Backend regressed = new Backend(); DisplayStateOwnership clockEvidence = owner(regressed);
        clockEvidence.apply(true, DisplayStateOwnership.Policy.HIDE, 1); long ownedActivity = regressed.activity;
        regressed.activity--; reject(clockEvidence::poll);
        assert clockEvidence.state() == DisplayStateOwnership.State.UNCONFIRMED && regressed.sleeps == 0;
        regressed.activity = ownedActivity; clockEvidence.restore(); assert clockEvidence.state() == DisplayStateOwnership.State.RESTORED;
        Backend remoteTouch = new Backend(); DisplayStateOwnership primaryInput = owner(remoteTouch);
        primaryInput.apply(true, DisplayStateOwnership.Policy.HIDE, 1);
        remoteTouch.activity += 10; // Display-0 injected input also advances the ordinary activity witness.
        primaryInput.poll();
        assert primaryInput.state() == DisplayStateOwnership.State.READY && remoteTouch.renewals == 1 : "ordinary activity alone must not suspend an otherwise interactive primary mirror";
        primaryInput.apply(true, DisplayStateOwnership.Policy.HIDE, 2);
        assert primaryInput.state() == DisplayStateOwnership.State.READY && remoteTouch.wakes == 1;
        primaryInput.restore();
        assert primaryInput.state() == DisplayStateOwnership.State.YIELDED_ACTIVITY && remoteTouch.sleeps == 0;
        Backend awakeTouch = new Backend(); awakeTouch.initiallyAwake(); DisplayStateOwnership awakeInput = owner(awakeTouch);
        awakeInput.apply(true, DisplayStateOwnership.Policy.HIDE, 1); awakeTouch.activity += 10; awakeInput.poll(); awakeInput.restore();
        assert awakeInput.state() == DisplayStateOwnership.State.RESTORED && awakeTouch.panels.get("20") == ON;
        assert awakeTouch.wakes == 0 && awakeTouch.sleeps == 0;
        Backend cleanupTouch = new Backend(); DisplayStateOwnership directActivity = owner(cleanupTouch);
        directActivity.apply(true, DisplayStateOwnership.Policy.HIDE, 1); cleanupTouch.activity += 10; directActivity.restore();
        assert directActivity.state() == DisplayStateOwnership.State.YIELDED_ACTIVITY && cleanupTouch.sleeps == 0;
        Backend sleepAfterTouch = new Backend(); DisplayStateOwnership touchedThenLocked = owner(sleepAfterTouch);
        touchedThenLocked.apply(true, DisplayStateOwnership.Policy.HIDE, 1); sleepAfterTouch.activity += 10; touchedThenLocked.poll();
        int beforeLockRenewals = sleepAfterTouch.renewals; sleepAfterTouch.physicalSleep(); touchedThenLocked.poll();
        assert touchedThenLocked.state() == DisplayStateOwnership.State.SUSPENDED && sleepAfterTouch.renewals == beforeLockRenewals;
        reject(() -> touchedThenLocked.apply(true, DisplayStateOwnership.Policy.HIDE, 2)); touchedThenLocked.restore();
        assert sleepAfterTouch.wakes == 1 && sleepAfterTouch.sleeps == 0;

        Backend button = new Backend(); DisplayStateOwnership sleepingUser = owner(button);
        sleepingUser.apply(true, DisplayStateOwnership.Policy.HIDE, 1); button.physicalSleep(); sleepingUser.poll();
        assert sleepingUser.state() == DisplayStateOwnership.State.SUSPENDED;
        reject(() -> sleepingUser.apply(true, DisplayStateOwnership.Policy.HIDE, 2));
        sleepingUser.poll(); sleepingUser.restore();
        assert button.wakes == 1 && button.sleeps == 0 && button.renewals == 0 && !button.interactive;
        assert sleepingUser.state() == DisplayStateOwnership.State.YIELDED_EXTERNAL;

        Backend roundTrip = new Backend(); roundTrip.otherGroupAwake = true;
        DisplayStateOwnership changedGroup = owner(roundTrip); changedGroup.apply(true, DisplayStateOwnership.Policy.HIDE, 1);
        long globalWake = roundTrip.wake, globalSleep = roundTrip.sleep;
        roundTrip.physicalSleep(); roundTrip.physicalWake(); roundTrip.panels.put("20", OFF);
        // Simulate another group's continued Awake state suppressing both aggregate transition stamps.
        roundTrip.wake = globalWake; roundTrip.sleep = globalSleep;
        changedGroup.poll(); changedGroup.restore();
        assert changedGroup.state() == DisplayStateOwnership.State.YIELDED_ACTIVITY && roundTrip.sleeps == 0 && roundTrip.wakes == 1;

        Backend posture = new Backend(); DisplayStateOwnership folded = owner(posture);
        folded.apply(true, DisplayStateOwnership.Policy.HIDE, 1); int beforeFold = posture.writes;
        posture.active = "10"; folded.poll(); folded.restore();
        assert folded.state() == DisplayStateOwnership.State.YIELDED_EXTERNAL && posture.writes == beforeFold && posture.sleeps == 0;
        Backend inventory = new Backend(); DisplayStateOwnership topology = owner(inventory);
        topology.apply(true, DisplayStateOwnership.Policy.HIDE, 1); int beforeInventory = inventory.writes;
        inventory.panels.put("30", OFF); topology.poll(); topology.restore();
        assert topology.state() == DisplayStateOwnership.State.YIELDED_EXTERNAL && inventory.writes == beforeInventory && inventory.sleeps == 0;

        Backend race = new Backend(); DisplayStateOwnership fenced = owner(race);
        fenced.apply(true, DisplayStateOwnership.Policy.HIDE, 1);
        race.afterNextRead = new Runnable() { public void run() { race.physicalSleep(); race.physicalWake(); } };
        fenced.restore();
        assert fenced.state() == DisplayStateOwnership.State.YIELDED_EXTERNAL && race.interactive;
        assert race.sleeps == 1 && race.wakes == 1 : "old owned wake timestamp lets Android reject a stale cleanup sleep";

        Backend ignored = new Backend(); ignored.ignoreSleep = true;
        DisplayStateOwnership unconfirmed = owner(ignored); unconfirmed.apply(true, DisplayStateOwnership.Policy.HIDE, 1);
        reject(unconfirmed::restore);
        assert unconfirmed.state() == DisplayStateOwnership.State.UNCONFIRMED && ignored.interactive && ignored.sleeps == 1;
        int renewedBefore = ignored.renewals; unconfirmed.poll();
        assert ignored.renewals == renewedBefore : "uncertain cleanup must stop activity renewal";
        System.out.println("PASS composite engine: pre-wake baseline, privacy-independent input lifetime, exact raw restoration, partial writes, user sleep/posture/topology yield, default-group activity fence and bounded unconfirmed cleanup");
    }
}
