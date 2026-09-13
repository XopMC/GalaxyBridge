package com.xopmc.galaxybridge.transport

import com.xopmc.galaxybridge.BuildConfig
import java.nio.file.Files
import java.nio.file.Path
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

class DownloadsProviderQaSurfaceTest {
    @Test
    fun receiverAndBytecodeExistOnlyInInternalDebug() {
        assertInternalDebugSurface("com.xopmc.galaxybridge.transport.DownloadsProviderQaReceiver", "receiver")
    }

    @Test
    fun textInputActivityAndBytecodeExistOnlyInInternalDebug() {
        assertInternalDebugSurface("com.xopmc.galaxybridge.service.TextInputQaActivity", "activity")
    }

    @Test
    fun audioVideoActivityAndBytecodeExistOnlyInInternalDebug() {
        assertInternalDebugSurface("com.xopmc.galaxybridge.service.AudioVideoQaActivity", "activity")
    }

    private fun assertInternalDebugSurface(className: String, elementName: String) {
        val allowed = BuildConfig.DISTRIBUTION == "internal" && BuildConfig.DEBUG
        val variant = BuildConfig.DISTRIBUTION + BuildConfig.BUILD_TYPE.replaceFirstChar(Char::uppercaseChar)
        val path = Path.of(System.getProperty("user.dir"), "build", "intermediates", "merged_manifests",
            variant, "process${variant.replaceFirstChar(Char::uppercaseChar)}Manifest", "AndroidManifest.xml")
        val document = Files.newInputStream(path).use {
            DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(it)
        }
        val receivers = document.getElementsByTagName(elementName)
        val matches = (0 until receivers.length).map { receivers.item(it) as Element }.filter {
            it.getAttribute("android:name") == className
        }
        assertEquals("QA entry point must not ship in release or direct builds", if (allowed) 1 else 0, matches.size)
        val hasClass = runCatching { Class.forName(className, false, javaClass.classLoader) }.isSuccess
        assertEquals("QA bytecode must not ship in release or direct builds", allowed, hasClass)
        if (allowed) {
            assertEquals("android.permission.DUMP", matches.single().getAttribute("android:permission"))
            assertEquals("true", matches.single().getAttribute("android:exported"))
            assertTrue(BuildConfig.DEBUG)
        } else {
            assertFalse(hasClass)
        }
    }

}
