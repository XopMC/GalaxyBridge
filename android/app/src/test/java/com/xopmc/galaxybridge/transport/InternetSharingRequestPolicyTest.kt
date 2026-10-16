package com.xopmc.galaxybridge.transport

import org.junit.Assert.assertEquals
import org.junit.Test

class InternetSharingRequestPolicyTest {
    @Test fun enablingWithoutPhoneConsentIdentifiesTheRequiredUserAction() {
        assertEquals("internet_sharing_not_allowed", InternetSharingRequestPolicy.errorCode(
            enabled = true, phoneAllowed = false, operationFailed = true, gatewayErrorCode = ""))
    }

    @Test fun disablingDoesNotRequirePhoneConsent() {
        assertEquals("", InternetSharingRequestPolicy.errorCode(
            enabled = false, phoneAllowed = false, operationFailed = false, gatewayErrorCode = ""))
    }

    @Test fun unrelatedEnableFailureKeepsTheGenericGatewayError() {
        assertEquals("internet_gateway_unavailable", InternetSharingRequestPolicy.errorCode(
            enabled = true, phoneAllowed = true, operationFailed = true, gatewayErrorCode = ""))
    }

    @Test fun unrelatedDisableFailureDoesNotMasqueradeAsMissingConsent() {
        assertEquals("internet_gateway_unavailable", InternetSharingRequestPolicy.errorCode(
            enabled = false, phoneAllowed = false, operationFailed = true, gatewayErrorCode = ""))
    }

    @Test fun gatewayReadinessErrorStillReachesTheMac() {
        assertEquals("no_validated_upstream", InternetSharingRequestPolicy.errorCode(
            enabled = true, phoneAllowed = true, operationFailed = false, gatewayErrorCode = "no_validated_upstream"))
    }
}
