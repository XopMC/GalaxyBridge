package com.xopmc.galaxybridge.setup

internal sealed interface AutomaticSetupStep {
    data object Wait : AutomaticSetupStep
    data class Request(val action: SetupAction) : AutomaticSetupStep
    data object NotificationGuide : AutomaticSetupStep
    data object Finish : AutomaticSetupStep
}

internal data class AutomaticPermissionSetup(
    val attemptedActions: Set<SetupAction> = emptySet(),
    val notificationGuideOffered: Boolean = false,
    val completed: Boolean = false,
) {
    val savedAttempts: Set<String> get() = attemptedActions.mapTo(mutableSetOf()) { it.name }
    fun attempted(action: SetupAction) = copy(attemptedActions = attemptedActions + action)
    // Called only while the activity is resumed. Attempt history is not permission state:
    // denials and later revocations remain visible in SetupStateResolver.
    fun next(state: SetupState, resumed: Boolean, inFlight: SetupAction? = null): AutomaticSetupStep {
        if (completed || !resumed || inFlight != null) return AutomaticSetupStep.Wait
        // Calls are optional even when Galaxy Bridge already holds the dialer role.
        // Their repair card requires a separate user action and never joins first-launch prompts.
        state.runtimeQueue.firstOrNull { it != SetupAction.DialerRuntimePermissions && it !in attemptedActions }
            ?.let { return AutomaticSetupStep.Request(it) }
        if (!notificationGuideOffered && state.cards.any { it.action == SetupAction.NotificationListenerSettings }) {
            return AutomaticSetupStep.NotificationGuide
        }
        return AutomaticSetupStep.Finish
    }
    companion object {
        fun restore(attemptedNames: Set<String>, guideOffered: Boolean, completed: Boolean) = AutomaticPermissionSetup(
            SetupAction.entries.filterTo(mutableSetOf()) { it.name in attemptedNames }, guideOffered, completed,
        )
    }
}
