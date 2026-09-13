import Foundation

private enum SpecFailure: Error, CustomStringConvertible {
    case mismatch(label: String, got: String, expected: String)
    case leakedIdentifier(label: String, value: String)

    var description: String {
        switch self {
        case let .mismatch(label, got, expected):
            "\(label): got \(String(reflecting: got)); expected \(String(reflecting: expected))"
        case let .leakedIdentifier(label, value):
            "\(label): leaked internal identifier \(String(reflecting: value))"
        }
    }
}

private func expect(_ got: String, _ expected: String, _ label: String) throws {
    guard got == expected else { throw SpecFailure.mismatch(label: label, got: got, expected: expected) }
}

private func expectNoIdentifier(_ value: String, _ label: String) throws {
    let looksInternal = value.contains("_") || value.hasPrefix("CAPABILITY_") || value == value.lowercased()
    guard !looksInternal else { throw SpecFailure.leakedIdentifier(label: label, value: value) }
}

@main
private enum UserFacingTextSpec {
    static func main() throws {
        guard CommandLine.arguments.count == 3,
              let englishBundle = Bundle(path: CommandLine.arguments[1]),
              let russianBundle = Bundle(path: CommandLine.arguments[2])
        else {
            fatalError("expected English and Russian test bundle paths")
        }

        let english = UserFacingTextResolver(bundle: englishBundle)
        let russian = UserFacingTextResolver(bundle: russianBundle)

        try verifyPreferredLanguages()
        try verifyMirrorCopy(english: english, russian: russian)
        try verifyDiagnosticCopy(english: english, russian: russian)

        try expect(
            english.capabilityName(for: "CAPABILITY_AUDIO_FORWARDING"),
            "Phone audio",
            "English capability name"
        )
        try expect(
            russian.capabilityName(for: "CAPABILITY_AUDIO_FORWARDING"),
            "Звук телефона",
            "Russian capability name"
        )
        try expect(
            english.unavailableReason(for: "media_projection_consent_required"),
            "Start screen sharing in Galaxy Bridge on your phone.",
            "English permission reason"
        )
        try expect(
            russian.unavailableReason(for: "media_projection_consent_required"),
            "Запустите трансляцию экрана в Galaxy Bridge на телефоне.",
            "Russian permission reason"
        )
        try expect(
            english.capabilityName(for: "CAPABILITY_PHYSICAL_SCREEN_OFF"),
            "Phone screen privacy",
            "English companion privacy capability"
        )
        try expect(
            russian.unavailableReason(for: "physical_screen_off_while_mirroring_requires_enhanced_adb"),
            "Для выключения экрана телефона во время трансляции используйте подключение по кабелю или прямое беспроводное подключение.",
            "Russian companion public API boundary"
        )
        try expect(
            english.unavailableReason(for: "media_projection_stopped_when_device_locked"),
            "Android stopped screen sharing when the phone was locked. Start sharing again on your phone.",
            "English lock-stop reason"
        )
        try expect(
            english.connectionStatus(isReady: true, usesPhoneApp: true),
            "Connected",
            "English connected status"
        )
        try expect(
            russian.connectionStatus(isReady: false, usesPhoneApp: true),
            "Ожидание телефона",
            "Russian phone status"
        )
        try expect(
            english.connectionStatus(isReady: false, usesPhoneApp: false),
            "Confirm the connection on your phone",
            "English direct status"
        )

        let unknownCapability = russian.capabilityName(for: "CAPABILITY_FUTURE_PRIVATE_MODE")
        let unknownReason = english.unavailableReason(for: "future_internal_reason")
        try expect(unknownCapability, "Возможность Galaxy Bridge", "Unknown capability fallback")
        try expect(unknownReason, "This feature is currently unavailable on this phone.", "Unknown reason fallback")
        try expectNoIdentifier(unknownCapability, "Unknown capability fallback")
        try expectNoIdentifier(unknownReason, "Unknown reason fallback")

        let knownCapabilities = [
            "CAPABILITY_UNSPECIFIED",
            "CAPABILITY_SCREEN_CAPTURE",
            "CAPABILITY_INPUT_INJECTION",
            "CAPABILITY_AUDIO_FORWARDING",
            "CAPABILITY_CLIPBOARD_READ",
            "CAPABILITY_CLIPBOARD_WRITE",
            "CAPABILITY_FILES",
            "CAPABILITY_NOTIFICATIONS",
            "CAPABILITY_SMS",
            "CAPABILITY_CALLS",
            "CAPABILITY_CAMERA_STREAM",
            "CAPABILITY_VIRTUAL_DISPLAY",
            "CAPABILITY_RECORDING",
            "CAPABILITY_PHYSICAL_SCREEN_OFF",
        ]
        for code in knownCapabilities {
            try expectNoIdentifier(english.capabilityName(for: code), "Known capability \(code)")
            try expectNoIdentifier(russian.capabilityName(for: code), "Known capability \(code)")
        }

        let knownReasons = [
            "media_projection_consent_required",
            "screen_capture_not_running",
            "accessibility_service_disabled",
            "notification_access_disabled",
            "storage_folder_not_selected",
            "record_audio_permission_required",
            "media_projection_audio_not_running_or_blocked",
            "notification_actions_only",
            "call_permissions_required",
            "default_dialer_role_required",
            "camera_permission_required",
            "enhanced_adb_required",
            "physical_screen_off_while_mirroring_requires_enhanced_adb",
            "media_projection_stopped_when_device_locked",
        ]
        for code in knownReasons {
            try expectNoIdentifier(english.unavailableReason(for: code), "Known reason \(code)")
            try expectNoIdentifier(russian.unavailableReason(for: code), "Known reason \(code)")
        }

        let callStates = [
            (0, "Call status unavailable", "Статус звонка недоступен"),
            (1, "No active call", "Нет активного звонка"),
            (2, "Ringing", "Входящий звонок"),
            (3, "Dialing", "Набор номера"),
            (4, "Call in progress", "Разговор"),
            (5, "Call ended", "Звонок завершён"),
            (999, "Call status unavailable", "Статус звонка недоступен"),
        ]
        for (code, en, ru) in callStates {
            try expect(english.callStateName(rawValue: code), en, "English call state \(code)")
            try expect(russian.callStateName(rawValue: code), ru, "Russian call state \(code)")
        }
        print("User-facing localization spec passed")
    }

    private static func verifyPreferredLanguages() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let resources = root.appendingPathComponent("macos/GalaxyBridgeMac/Resources")
        let supported = try FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "lproj" }
            .map { $0.deletingPathExtension().lastPathComponent }
        let approved = ["en", "ru", "de", "fr", "es", "pt", "ar", "zh-Hans", "zh-Hant", "ja", "ko"]
        try expect(supported.sorted().joined(separator: ","), approved.sorted().joined(separator: ","),
                   "User-selected shipping language scope")
        for language in supported {
            let selected = Bundle.preferredLocalizations(from: supported, forPreferences: [language]).first ?? ""
            try expect(selected, language, "Exact system language \(language)")
        }
        let cases: [(preferences: [String], expected: String)] = [
            (["ru"], "ru"),
            (["en"], "en"),
            (["fr-FR", "ru"], "fr"),
            (["fr-CA", "en"], "fr"),
            (["de-DE", "en"], "de"),
            (["de-AT", "en"], "de"),
            (["ja-JP", "ru"], "ja"),
            (["ar", "de"], "ar"),
            (["he-IL", "en"], "en"),
            (["ko-KR", "en"], "ko"),
            (["zh-CN", "en"], "zh-Hans"),
            (["zh-TW", "en"], "zh-Hant"),
            (["zh-HK", "en"], "zh-Hant"),
            (["pt-BR", "en"], "pt"),
            (["pt-PT", "en"], "pt"),
            (["sr-Latn-RS", "en"], "en"),
            (["sr-Cyrl-RS", "en"], "en"),
            (["no", "en"], "en"),
            // Standard ordered preferences: a supported second choice still wins.
            (["zz-ZZ", "ru"], "ru"),
            (["it-IT", "de-DE"], "de"),
            // Unsupported-only preferences must use English, never an incidental catalog.
            (["it-IT"], "en"), (["uk-UA"], "en"), (["he-IL"], "en"),
            (["fa-IR"], "en"), (["sr-Latn-RS"], "en"), (["zz-ZZ"], "en"),
            (["it-IT", "uk-UA"], "en"), (["pt-PT"], "pt"),
            (["ru-RU"], "ru"),
            (["en-GB"], "en"),
        ]
        for test in cases {
            let selected = Bundle.preferredLocalizations(
                from: supported, forPreferences: test.preferences
            ).first ?? ""
            try expect(selected, test.expected, "Bundle language selection for \(test.preferences)")
        }
    }

    private static func verifyMirrorCopy(
        english: UserFacingTextResolver, russian: UserFacingTextResolver
    ) throws {
        try expect(english.localized("DISPLAY_TARGET"), "Choose display", "English display control")
        try expect(russian.localized("DISPLAY_TARGET"), "Выбрать экран", "Russian display control")
        try expect(english.localized("SCREEN_ON"), "Turn screen on", "English screen power control")
        try expect(russian.localized("SCREEN_ON"), "Включить экран", "Russian screen power control")
        try expect(english.displayName(id: 0, width: nil, height: nil), "Display 0", "English display name")
        try expect(russian.displayName(id: 0, width: nil, height: nil), "Экран 0", "Russian display name")
        try expect(
            english.displayName(id: 2, width: 1920, height: 1080),
            "Display 2 1920×1080", "English display size"
        )
        try expect(
            russian.displayName(id: 2, width: 1920, height: 1080),
            "Экран 2 1920×1080", "Russian display size"
        )
        try expect(english.displayName(id: 1, width: 1920, height: nil), "Display 1", "Incomplete display size")
        try expect(russian.displayName(id: 1, width: nil, height: 1080), "Экран 1", "Incomplete display size")
        for rate: UInt32 in [24, 30, 60] {
            try expect(english.formatted("CAMERA_FPS_VALUE", rate), "\(rate) fps", "English frame rate")
            try expect(russian.formatted("CAMERA_FPS_VALUE", rate), "\(rate) кадр/с", "Russian frame rate")
        }
    }

    private static func verifyDiagnosticCopy(
        english: UserFacingTextResolver, russian: UserFacingTextResolver
    ) throws {
        try expect(
            english.localized("ADB_BUNDLED_RUNTIME_MISSING"),
            "Galaxy Bridge is missing a connection component. Reinstall Galaxy Bridge using the official installer.",
            "Customer build repairs the app, not external Android tools"
        )
        try expect(
            russian.localized("ADB_BUNDLED_RUNTIME_MISSING"),
            "В Galaxy Bridge отсутствует компонент подключения. Переустановите Galaxy Bridge из официального установщика.",
            "Russian customer bundle repair guidance"
        )
        let detail = "Diagnostic detail: 100% %@"
        let cases = [
            ("NATIVE_NOTIFICATION_SCHEDULING_FAILED", "macOS could not schedule a notification", "macOS не удалось запланировать уведомление"),
            ("PEER_STORE_FAILED", "Could not read paired devices", "Не удалось прочитать привязанные устройства"),
            ("COMPANION_CONNECTION_FAILED", "Companion connection failed", "Ошибка Companion-подключения"),
        ]
        for (key, englishTitle, russianTitle) in cases {
            try expect(english.formatted(key, detail), "\(englishTitle): \(detail)", "English \(key)")
            try expect(russian.formatted(key, detail), "\(russianTitle): \(detail)", "Russian \(key)")
        }
        try expect(
            english.formatted("ADB_BINDING_EXHAUSTED", 4),
            "Wireless ADB identity could not be verified after 4 attempts. Reconnect the device or refresh to retry.",
            "English binding exhaustion"
        )
        try expect(
            russian.formatted("ADB_BINDING_EXHAUSTED", 4),
            "Не удалось подтвердить Wireless ADB после 4 попыток. Переподключите устройство или обновите список, чтобы повторить.",
            "Russian binding exhaustion"
        )
    }
}
