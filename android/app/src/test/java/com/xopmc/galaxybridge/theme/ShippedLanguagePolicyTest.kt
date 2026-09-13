package com.xopmc.galaxybridge.theme

import java.nio.file.Files
import java.nio.file.Path
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Test
import org.w3c.dom.Element

class ShippedLanguagePolicyTest {
    private val resources = Path.of(System.getProperty("user.dir"), "src/main/res")

    @Test
    fun onlyTheUserSelectedLanguagesAreOfferedAndShipped() {
        val expected = setOf("en", "ru", "de", "fr", "es", "pt", "ar", "zh-Hans", "zh-Hant", "ja", "ko")
        val config = xml(resources.resolve("xml/locales_config.xml")).getElementsByTagName("locale")
        val offered = (0 until config.length).map {
            (config.item(it) as Element).getAttribute("android:name")
        }
        assertEquals(expected, offered.toSet())
        assertEquals(expected.size, offered.size)
        val expectedDirectories = setOf("values", "values-ru", "values-de", "values-fr", "values-es",
            "values-pt", "values-ar", "values-b+zh+Hans", "values-b+zh+Hant", "values-ja", "values-ko")
        val actualDirectories = Files.list(resources).use { paths ->
            paths.filter { Files.isRegularFile(it.resolve("strings.xml")) }.map { it.fileName.toString() }.toList().toSet()
        }
        assertEquals("Removed translations must not enter the product, including pt-PT", expectedDirectories, actualDirectories)
    }

    @Test
    fun unqualifiedResourcesProvideCompleteEnglishFallback() {
        val entries = xml(resources.resolve("values/strings.xml")).getElementsByTagName("string")
        val values = (0 until entries.length).associate {
            val item = entries.item(it) as Element
            item.getAttribute("name") to item.textContent
        }
        assertEquals("Continue", values["action_continue"])
        assertEquals("Connect your Mac", values["identity_title"])
        assertEquals("Choose what to set up", values["setup_features_title"])
        val russian = xml(resources.resolve("values-ru/strings.xml")).getElementsByTagName("string")
        assertEquals("Every localized key must have an unqualified fallback", russian.length, values.size)
    }

    private fun xml(path: Path) = Files.newInputStream(path).use {
        DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(it)
    }
}
