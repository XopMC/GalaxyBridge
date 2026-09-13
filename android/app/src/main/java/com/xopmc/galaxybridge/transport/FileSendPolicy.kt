package com.xopmc.galaxybridge.transport

internal object FileSendPolicy {
    fun enabled(distribution: String) = distribution == "internal" || distribution == "direct"
    fun acceptsShare(action: String?, scheme: String?, itemCount: Int, hasReadGrant: Boolean) =
        action == "android.intent.action.SEND" && scheme == "content" && itemCount == 1 && hasReadGrant
}
