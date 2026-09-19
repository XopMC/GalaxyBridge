package com.xopmc.galaxybridge.theme

import java.nio.file.Files
import java.nio.file.Path
import javax.xml.parsers.DocumentBuilderFactory
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.w3c.dom.Element

class PrimaryCopyResourceTest {
    @Test
    fun primarySetupCopyIsUserFacingInEnglishAndRussian() {
        val resourceRoot = Path.of(System.getProperty("user.dir"), "src", "main", "res")
        val english = strings(resourceRoot.resolve("values/strings.xml"))
        val russian = strings(resourceRoot.resolve("values-ru/strings.xml"))

        assertEquals("Galaxy Bridge", english.getValue("home_title"))
        assertEquals("Galaxy Bridge", russian.getValue("home_title"))
        assertEquals("Use your Galaxy alongside your Apple Mac", english.getValue("home_subtitle"))
        assertEquals("Используйте ваш Galaxy совместно с Apple Mac", russian.getValue("home_subtitle"))
        assertEquals("Connect your Mac", english.getValue("identity_title"))
        assertEquals("Подключение к Mac", russian.getValue("identity_title"))
        assertEquals(
            "Allow Galaxy Bridge to follow your mouse, keyboard, and trackpad commands from your Mac.",
            english.getValue("input_description"),
        )
        assertEquals(
            "Разрешите Galaxy Bridge выполнять команды мыши, клавиатуры и трекпада с вашего Mac.",
            russian.getValue("input_description"),
        )
        assertFalse(english.containsKey("identity_description"))
        assertFalse(russian.containsKey("identity_description"))

        val primaryNames = listOf(
            "service_channel_name",
            "service_channel_description",
            "service_notification_title",
            "service_notification_text",
            "capture_notification_title",
            "capture_notification_text",
            "camera_notification_title",
            "camera_notification_text",
            "accessibility_service_name",
            "accessibility_service_description",
            "home_title",
            "home_subtitle",
            "setup_complete_body",
            "local_network_title",
            "local_network_description",
            "post_notifications_title",
            "post_notifications_description",
            "microphone_title",
            "microphone_description",
            "input_title",
            "identity_title",
            "pairing_scan_hint",
            "notifications_description",
            "files_description",
            "camera_description",
            "input_description",
            "calls_permissions_description",
            "sms_notification_only_title",
            "sms_notification_only_description",
            "qr_scanner_title",
            "qr_scanner_hint",
            "qr_camera_required",
            "qr_invalid",
            "revoke_pairing_body",
            "setup_features_title",
            "setup_features_body",
            "setup_save_choices",
            "setup_edit_choices",
            "setup_choose_one",
            "setup_screen_feature_title",
            "setup_screen_feature_body",
            "setup_audio_feature_body",
            "setup_clipboard_feature_title",
            "setup_clipboard_feature_body",
            "setup_permission_section_title",
            "setup_permissions_allowed",
            "setup_waiting_title",
            "setup_waiting_body",
            "setup_test_pending",
            "setup_permission_allowed",
            "setup_feature_unavailable",
            "setup_action_unavailable",
            "setup_save_failed",
            "setup_camera_notifications_description",
        )
        val forbidden = Regex(
            "\\badb\\b|companion|компань|\\blan\\b|\\bsaf\\b|camerax|sha-?256|p-?256|protobuf|protocol|протокол|galaxybridge://|storage access framework|fingerprint|отпечат|\\btls\\b|secure channel|encrypted channel|local bridge|локальный мост|\\bkey\\b|\\bключ(?:а|и|ей|ом|у)?\\b|зашифрованн|default dialer|роль телефона|\\bhfp\\b|remote input|удалённ(?:ый|ого) ввод",
            RegexOption.IGNORE_CASE,
        )
        for (name in primaryNames) {
            assertFalse("Technical copy leaked into English $name", forbidden.containsMatchIn(english.getValue(name)))
            assertFalse("Technical copy leaked into Russian $name", forbidden.containsMatchIn(russian.getValue(name)))
        }
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
