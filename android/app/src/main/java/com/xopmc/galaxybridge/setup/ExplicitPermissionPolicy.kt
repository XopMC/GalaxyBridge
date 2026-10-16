package com.xopmc.galaxybridge.setup

internal data class PermissionAccess(val granted: Boolean, val previouslyRequested: Boolean, val showRationale: Boolean)
internal enum class PermissionRoute { None, Request, Settings }

internal object ExplicitPermissionPolicy {
    fun route(permissions: List<PermissionAccess>, explicitRequest: Boolean): PermissionRoute = when {
        !explicitRequest || permissions.all { it.granted } -> PermissionRoute.None
        permissions.any { !it.granted && it.previouslyRequested && !it.showRationale } -> PermissionRoute.Settings
        else -> PermissionRoute.Request
    }
}
