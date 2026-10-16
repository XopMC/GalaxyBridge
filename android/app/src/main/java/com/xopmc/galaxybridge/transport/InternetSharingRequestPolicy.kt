package com.xopmc.galaxybridge.transport

/** Protocol error classification after an authenticated internet-sharing request. */
internal object InternetSharingRequestPolicy {
    fun errorCode(enabled: Boolean, phoneAllowed: Boolean, operationFailed: Boolean, gatewayErrorCode: String): String = when {
        enabled && !phoneAllowed -> "internet_sharing_not_allowed"
        operationFailed -> "internet_gateway_unavailable"
        else -> gatewayErrorCode
    }
}
