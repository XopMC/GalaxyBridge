package com.xopmc.galaxybridge.setup

import java.nio.file.Files
import java.nio.file.Path
import com.xopmc.galaxybridge.BuildConfig
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ManifestPermissionPolicyTest {
    @Test
    fun mergedManifestExposesRestrictedTelephonySurfaceOnlyInternally() {
        val manifest = Files.readString(mergedManifest())
        val restrictedSurface = listOf(
            "android.permission.READ_PHONE_STATE",
            "android.permission.CALL_PHONE",
            "android.permission.READ_CALL_LOG",
            "android.permission.ANSWER_PHONE_CALLS",
            "com.xopmc.galaxybridge.service.GalaxyInCallService",
            "android.intent.action.DIAL",
        )

        restrictedSurface.forEach { marker ->
            if (BuildConfig.DISTRIBUTION in setOf("internal", "direct")) {
                assertTrue("${BuildConfig.DISTRIBUTION} merged manifest must retain $marker", manifest.contains(marker))
            } else {
                assertFalse("Play merged manifest must exclude $marker", manifest.contains(marker))
            }
        }
    }

    @Test
    fun flavorsDoNotRequestSmsOrUnusedCallLogWriteAccess() {
        val sourceRoot = Path.of(System.getProperty("user.dir"), "src")
        val forbidden = listOf(
            "android.permission.WRITE_CALL_LOG",
            "android.permission.READ_SMS",
            "android.permission.SEND_SMS",
            "android.permission.WRITE_SMS",
            "android.app.role.SMS",
        )

        listOf("internal/AndroidManifest.xml", "play/AndroidManifest.xml").forEach { relativePath ->
            val manifest = Files.readString(sourceRoot.resolve(relativePath))
            forbidden.forEach { permission ->
                assertFalse("$relativePath must not request $permission", manifest.contains(permission))
            }
        }
    }

    @Test
    fun remoteTextReceiverIsShellOnlyAndInternalOnly() {
        val manifest = Files.readString(mergedManifest())
        val receiver = "com.xopmc.galaxybridge.service.RemoteTextInputReceiver"
        if (BuildConfig.DISTRIBUTION in setOf("internal", "direct")) {
            assertTrue(manifest.contains(receiver))
            assertTrue(manifest.contains("android.permission.DUMP"))
            assertTrue(manifest.contains("com.xopmc.galaxybridge.INJECT_REMOTE_TEXT"))
        } else {
            assertFalse(manifest.contains(receiver))
            assertFalse(manifest.contains("com.xopmc.galaxybridge.INJECT_REMOTE_TEXT"))
        }
    }

    private fun mergedManifest(): Path {
        val variant = "${BuildConfig.DISTRIBUTION}Debug"
        val directory = Path.of(
            System.getProperty("user.dir"),
            "build",
            "intermediates",
            "merged_manifests",
            variant,
            "process${variant.replaceFirstChar(Char::uppercaseChar)}Manifest",
        )
        return directory.resolve("AndroidManifest.xml")
    }
}
