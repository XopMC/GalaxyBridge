# Galaxy Bridge 0.1.1 — prerelease

[Download](https://github.com/XopMC/GalaxyBridge/releases/tag/0.1.1) · [English](#english) · [Русский](#russian)

<a id="english"></a>

## English

This maintenance prerelease fixes the macOS 26 crash that occurred when the QR pairing sheet opened. The Direct macOS application now loads localizations from its application bundle instead of SwiftPM's generated resource bundle.

It also fixes Wireless ADB discovery for the bundled ADB build: the Mac app now discovers Android's pairing and connection services through native Bonjour, then continues pairing and connecting through its owned ADB runtime. The previous path called ADB's unavailable `mdns services` command and could show a local-network error before entering the six-digit pairing code.

The release includes a rebuilt drag-to-Applications DMG for **macOS 14+ / Apple Silicon** and a signed Direct APK for **Android 12+**. ADB remains included in the Mac app. The QR pairing screen was opened successfully from the packaged macOS app during release validation.

### Known limits

- Wi-Fi reliability, clean-Mac installation, and the wider hardware matrix still need validation.
- Full SMS history/direct sending and virtual webcam activation are not included.
- The Mac app is ad-hoc signed and not Apple-notarized.

<a id="russian"></a>

## Русский

В этом техническом предварительном выпуске исправлено падение macOS 26 при открытии окна QR-сопряжения. Приложение Direct для macOS теперь загружает локализации из бандла приложения, а не из сгенерированного SwiftPM пакета ресурсов.

Также исправлен поиск Wireless ADB для встроенной сборки ADB: Mac-приложение находит сервисы сопряжения и подключения Android через нативный Bonjour, после чего использует свой owned ADB runtime для сопряжения и подключения. Раньше приложение вызывало отсутствующую в этой сборке ADB команду `mdns services` и могло показать ошибку локальной сети до ввода шестизначного кода.

В выпуск входят заново собранный DMG с переносом приложения в «Программы» для **macOS 14+ / Apple Silicon** и подписанный Direct APK для **Android 12+**. ADB по-прежнему встроен в приложение для Mac. В ходе проверки выпуска QR-экран был успешно открыт из упакованного приложения macOS.

### Известные ограничения

- Надёжность Wi-Fi, установка на чистый Mac и расширенная матрица устройств ещё требуют проверки.
- Полная история SMS, прямая отправка SMS и активация виртуальной веб-камеры пока не входят в выпуск.
- Приложение для Mac имеет локальную ad-hoc подпись и не нотарифицировано Apple.
