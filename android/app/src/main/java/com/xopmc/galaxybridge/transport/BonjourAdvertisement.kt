package com.xopmc.galaxybridge.transport

internal object BonjourAdvertisement {
    fun attributes(
        deviceId: String,
        publicKeyFingerprint: ByteArray,
        displayName: String,
        protocolMajor: Int,
    ): Map<String, String> = linkedMapOf(
        "id" to deviceId.lowercase(),
        "pkfp" to publicKeyFingerprint.joinToString("") { byte -> "%02x".format(byte.toInt() and 0xff) },
        "v" to protocolMajor.toString(),
        "name" to displayName.trim().ifEmpty { "Samsung Galaxy" }.take(MAX_DISPLAY_NAME_LENGTH),
    )

    fun serviceName(displayName: String): String =
        "GalaxyBridge ${displayName.trim().ifEmpty { "Samsung Galaxy" }}"

    private const val MAX_DISPLAY_NAME_LENGTH = 128
}
