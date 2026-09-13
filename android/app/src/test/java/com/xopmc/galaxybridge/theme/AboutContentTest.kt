package com.xopmc.galaxybridge.theme

import com.xopmc.galaxybridge.AboutContent
import java.net.URI
import java.nio.file.Files
import java.nio.file.Path
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

class AboutContentTest {
    @Test
    fun aboutContentCreditsTheAuthorAndUsesTheCanonicalGithubProfile() {
        assertEquals("Mikhail Khoroshavin aka XopMC", AboutContent.author)

        val uri = URI(AboutContent.githubURL)
        assertEquals("https", uri.scheme)
        assertEquals("github.com", uri.host)
        assertEquals("/XopMC", uri.path)
    }

    @Test
    fun aboutPageHasCompleteEnglishAndRussianCopy() {
        val resourceRoot = Path.of(System.getProperty("user.dir"), "src", "main", "res")
        val english = strings(resourceRoot.resolve("values/strings.xml"))
        val russian = strings(resourceRoot.resolve("values-ru/strings.xml"))

        val requiredKeys = setOf(
            "about_entry",
            "about_title",
            "about_author_label",
            "about_github_action",
            "about_icon_content_description",
            "action_back",
        )
        assertTrue(requiredKeys.all(english::containsKey))
        assertTrue(requiredKeys.all(russian::containsKey))
        assertEquals("About Galaxy Bridge", english.getValue("about_title"))
        assertEquals("О приложении", russian.getValue("about_title"))
    }

    private fun strings(path: Path): Map<String, String> {
        val document = Files.newInputStream(path).use {
            DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(it)
        }
        val strings = document.getElementsByTagName("string")
        return (0 until strings.length)
            .map { strings.item(it) as Element }
            .associate { it.getAttribute("name") to it.textContent.trim() }
    }
}
