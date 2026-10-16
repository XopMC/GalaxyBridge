package com.xopmc.galaxybridge.setup

import org.junit.Assert.assertEquals
import org.junit.Test

class ExplicitPermissionPolicyTest {
    private val permanentlyDenied = PermissionAccess(false, true, false)

    @Test fun explicitRetryAfterPermanentDenialOpensSettings() {
        assertEquals(PermissionRoute.Settings,
            ExplicitPermissionPolicy.route(listOf(permanentlyDenied), explicitRequest = true))
    }

    @Test fun returningToTheActivityNeverRequestsOrOpensAnything() {
        for (permission in listOf(permanentlyDenied, PermissionAccess(false, false, false))) {
            assertEquals(PermissionRoute.None,
                ExplicitPermissionPolicy.route(listOf(permission), explicitRequest = false))
        }
    }

    @Test fun firstRequestAndRationaleDenialCanRequestPermissions() {
        for (permission in listOf(PermissionAccess(false, false, false), PermissionAccess(false, true, true))) {
            assertEquals(PermissionRoute.Request,
                ExplicitPermissionPolicy.route(listOf(permission), explicitRequest = true))
        }
    }

    @Test fun onePermanentlyDeniedPermissionRequiresSettingsEvenWithOtherMissingPermissions() {
        assertEquals(PermissionRoute.Settings, ExplicitPermissionPolicy.route(
            listOf(PermissionAccess(false, false, false), permanentlyDenied), explicitRequest = true))
    }

    @Test fun grantedPermissionsNeedNoAction() {
        assertEquals(PermissionRoute.None,
            ExplicitPermissionPolicy.route(listOf(PermissionAccess(true, true, false)), explicitRequest = true))
    }
}
