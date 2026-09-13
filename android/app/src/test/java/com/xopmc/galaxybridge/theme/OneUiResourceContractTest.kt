package com.xopmc.galaxybridge.theme

import java.awt.image.BufferedImage
import java.nio.file.Files
import java.nio.file.Path
import javax.imageio.ImageIO
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element

class OneUiResourceContractTest {
    private val resourceRoot: Path = Path.of(System.getProperty("user.dir"), "src", "main", "res")

    @Test
    fun oneUiLayoutKeepsComfortableSamsungScaleAndTouchTargets() {
        val dimensions = xmlValues(resourceRoot.resolve("values/dimens.xml"), "dimen")

        assertDpInRange(dimensions, "one_ui_content_horizontal", 20f, 28f)
        assertDpInRange(dimensions, "one_ui_content_top", 24f, 48f)
        assertDpInRange(dimensions, "one_ui_section_spacing", 20f, 32f)
        assertDpInRange(dimensions, "one_ui_card_radius", 28f, 36f)
        assertDpInRange(dimensions, "one_ui_card_padding", 20f, 28f)
        assertDpInRange(dimensions, "one_ui_button_height", 52f, 64f)
        assertDpInRange(dimensions, "one_ui_button_radius", 24f, 32f)
    }

    @Test
    fun launcherUsesLayeredAdaptiveArtworkAndARealRasterFallback() {
        val manifest = parse(Path.of(System.getProperty("user.dir"), "src", "main", "AndroidManifest.xml"))
        val application = manifest.getElementsByTagName("application").item(0) as Element
        val androidNamespace = "http://schemas.android.com/apk/res/android"
        assertEquals("@mipmap/ic_galaxy_bridge", application.getAttributeNS(androidNamespace, "icon"))
        assertEquals("@mipmap/ic_galaxy_bridge_round", application.getAttributeNS(androidNamespace, "roundIcon"))

        val adaptivePath = resourceRoot.resolve("mipmap-anydpi-v26/ic_galaxy_bridge.xml")
        val roundPath = resourceRoot.resolve("mipmap-anydpi-v26/ic_galaxy_bridge_round.xml")
        assertTrue("Adaptive launcher icon is required", Files.isRegularFile(adaptivePath))
        assertTrue("Round adaptive launcher icon is required", Files.isRegularFile(roundPath))

        val adaptive = parse(adaptivePath).documentElement
        assertEquals("adaptive-icon", adaptive.tagName)
        val background = adaptive.getElementsByTagName("background").item(0) as Element
        val foreground = adaptive.getElementsByTagName("foreground").item(0) as Element
        val monochrome = adaptive.getElementsByTagName("monochrome").item(0) as Element
        assertEquals("@drawable/ic_galaxy_bridge_background", background.getAttributeNS(androidNamespace, "drawable"))
        assertEquals("@drawable/ic_galaxy_bridge_foreground", foreground.getAttributeNS(androidNamespace, "drawable"))
        assertEquals("@drawable/ic_galaxy_bridge_monochrome", monochrome.getAttributeNS(androidNamespace, "drawable"))

        val backgroundPng = resourceRoot.resolve("drawable-nodpi/ic_galaxy_bridge_background.png")
        assertTrue("Shared gradient background is required", Files.isRegularFile(backgroundPng))
        val backgroundImage = ImageIO.read(backgroundPng.toFile())
        val backgroundPixels = backgroundImage.getRGB(0, 0, backgroundImage.width, backgroundImage.height, null, 0, backgroundImage.width)
        assertTrue("Adaptive background must fill system overscan", backgroundPixels.all { it ushr 24 == 255 })

        val foregroundPng = resourceRoot.resolve("drawable-nodpi/ic_galaxy_bridge_foreground.png")
        assertTrue("Foreground artwork is required", Files.isRegularFile(foregroundPng))
        assertLayeredForeground(ImageIO.read(foregroundPng.toFile()))

        val legacyPng = resourceRoot.resolve("mipmap-xxxhdpi/ic_galaxy_bridge.png")
        assertTrue("High-density raster fallback is required", Files.isRegularFile(legacyPng))
        assertPolishedRaster(ImageIO.read(legacyPng.toFile()), minimumSize = 192)
        assertFalse(
            "The old generic teal-phone drawable must not remain the launcher icon",
            Files.exists(resourceRoot.resolve("drawable/ic_galaxy_bridge.xml")),
        )
    }

    private fun assertLayeredForeground(image: BufferedImage) {
        assertTrue("Foreground artwork must be high resolution", image.width >= 432 && image.height >= 432)
        assertEquals(image.width, image.height)
        val pixels = image.getRGB(0, 0, image.width, image.height, null, 0, image.width)
        val transparent = pixels.count { it ushr 24 < 16 }
        val visible = pixels.size - transparent
        assertTrue("Adaptive foreground must leave room for masking and motion", transparent > pixels.size / 4)
        // Android's guaranteed safe circle is 66dp inside the 108dp layer.
        // Measure visual weight within that circle, not across the overscan
        // area which must remain transparent for launcher masks and motion.
        val radius = image.width * 33.0 / 108.0
        val safeArea = Math.PI * radius * radius
        assertTrue("Adaptive outline mark must be substantial inside its safe circle", visible > safeArea / 8)
        val center = (image.width - 1) / 2.0
        for (y in 0 until image.height) {
            for (x in 0 until image.width) {
                if (image.getRGB(x, y) ushr 24 >= 16) {
                    val dx = x - center
                    val dy = y - center
                    assertTrue("Foreground must survive every system mask", dx * dx + dy * dy <= radius * radius)
                }
            }
        }
    }

    private fun assertPolishedRaster(image: BufferedImage, minimumSize: Int) {
        assertTrue(image.width >= minimumSize && image.height >= minimumSize)
        assertEquals(image.width, image.height)
        val sampledColors = mutableSetOf<Int>()
        for (y in 0 until image.height step 4) {
            for (x in 0 until image.width step 4) {
                sampledColors += image.getRGB(x, y) and 0x00FFFFFF
            }
        }
        assertTrue("Launcher artwork must not be a flat placeholder", sampledColors.size >= 64)
    }

    private fun assertDpInRange(values: Map<String, String>, name: String, minimum: Float, maximum: Float) {
        val value = values.getValue(name)
        assertTrue("$name must use dp", value.endsWith("dp"))
        val number = value.removeSuffix("dp").toFloat()
        assertTrue("$name=$number is below One UI range", number >= minimum)
        assertTrue("$name=$number is above One UI range", number <= maximum)
    }

    private fun xmlValues(path: Path, tagName: String): Map<String, String> {
        val document = parse(path)
        val nodes = document.getElementsByTagName(tagName)
        return (0 until nodes.length)
            .map { nodes.item(it) as Element }
            .associate { it.getAttribute("name") to it.textContent.trim() }
    }

    private fun parse(path: Path) = Files.newInputStream(path).use {
        DocumentBuilderFactory.newInstance().apply { isNamespaceAware = true }.newDocumentBuilder().parse(it)
    }
}
