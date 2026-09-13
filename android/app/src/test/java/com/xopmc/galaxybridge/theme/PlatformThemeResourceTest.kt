package com.xopmc.galaxybridge.theme

import java.nio.file.Files
import java.nio.file.Path
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

class PlatformThemeResourceTest {
    @Test
    fun platformWindowThemeTracksSystemDayNightAndAccent() {
        val resourceRoot = Path.of(System.getProperty("user.dir"), "src", "main", "res")
        val day = theme(resourceRoot.resolve("values/themes.xml"))
        val nightPath = resourceRoot.resolve("values-night/themes.xml")

        assertTrue("A night-qualified platform theme is required", Files.isRegularFile(nightPath))
        val night = theme(nightPath)

        assertEquals("android:style/Theme.Material.Light.NoActionBar", day.getAttribute("parent"))
        assertEquals("android:style/Theme.Material.NoActionBar", night.getAttribute("parent"))
        assertEquals("true", day.item("android:windowLightStatusBar"))
        assertEquals("false", night.item("android:windowLightStatusBar"))
        assertEquals("true", day.item("android:windowLightNavigationBar"))
        assertEquals("false", night.item("android:windowLightNavigationBar"))
        assertEquals(SYSTEM_ACCENT, day.item("android:colorAccent"))
        assertEquals(SYSTEM_ACCENT, night.item("android:colorAccent"))
    }

    private fun theme(path: Path): Element {
        val document = Files.newInputStream(path).use {
            DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(it)
        }
        val styles = document.getElementsByTagName("style")
        return (0 until styles.length)
            .map { styles.item(it) as Element }
            .single { it.getAttribute("name") == "Theme.GalaxyBridge" }
    }

    private fun Element.item(name: String): String {
        val items = getElementsByTagName("item")
        return (0 until items.length)
            .map { items.item(it) as Element }
            .single { it.getAttribute("name") == name }
            .textContent
            .trim()
    }

    private companion object {
        const val SYSTEM_ACCENT = "@android:color/system_accent1_500"
    }
}
