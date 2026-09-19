# Galaxy Bridge 0.1.1 — prerelease

[Download](https://github.com/XopMC/GalaxyBridge/releases/tag/0.1.1) · [English](#english) · [Русский](#russian)

<a id="english"></a>

## English

This maintenance prerelease fixes the macOS 26 crash that occurred when the QR pairing sheet opened. The Direct macOS application now loads localizations from its application bundle instead of SwiftPM's generated resource bundle.

Wireless ADB discovery now resolves Android's Bonjour `.local` endpoints to private IPv4 addresses and tries an already-trusted connection service before asking for a six-digit pairing code. The setup sheet searches the local network instead of incorrectly waiting for the phone's code screen.

Android-to-Mac clipboard sync now uses a bounded capture-free agent inside the bundled scrcpy server. The Mac launches it under the already-authorized ADB shell, so it can poll the current Android clipboard while Gallery or another app is in front. Text and copied PNG images are forwarded without a Galaxy Bridge keyboard and without the Share menu. Sensitive clips are ignored.

The release includes a rebuilt drag-to-Applications DMG for **macOS 14+ / Apple Silicon** and a signed Direct APK for **Android 12+**. ADB remains included in the Mac app. The QR pairing screen was opened successfully from the packaged macOS app during release validation.

### Known limits

- Wi-Fi reliability, clean-Mac installation, and the wider hardware matrix still need validation.
- Android requires the user to enable Developer options/Wireless debugging and approve the initial ADB pairing. A regular APK cannot enable these protected system settings itself.
- Full SMS history/direct sending and virtual webcam activation are not included.
- The Mac app is ad-hoc signed and not Apple-notarized.

<a id="russian"></a>

## Русский

В этом техническом предварительном выпуске исправлено падение macOS 26 при открытии окна QR-сопряжения. Приложение Direct для macOS теперь загружает локализации из бандла приложения, а не из сгенерированного SwiftPM пакета ресурсов.

Поиск Wireless ADB теперь преобразует Android Bonjour-адреса `.local` в локальный IPv4 и сначала пробует уже доверенный сервис подключения. Шестизначный код запрашивается только для нового сопряжения; окно настройки больше не утверждает, что ждёт экран кода на телефоне.

Для передачи буфера Android → Mac добавлен ограниченный по размеру агент внутри встроенного scrcpy-сервера. Mac запускает его в уже разрешённом ADB shell, поэтому он опрашивает текущий буфер Android, даже когда открыта «Галерея» или другое приложение. Текст и скопированные PNG передаются без клавиатуры Galaxy Bridge и без меню «Поделиться». Чувствительные данные буфера игнорируются.

В выпуск входят заново собранный DMG с переносом приложения в «Программы» для **macOS 14+ / Apple Silicon** и подписанный Direct APK для **Android 12+**. ADB по-прежнему встроен в приложение для Mac. В ходе проверки выпуска QR-экран был успешно открыт из упакованного приложения macOS.

### Известные ограничения

- Надёжность Wi-Fi, установка на чистый Mac и расширенная матрица устройств ещё требуют проверки.
- Android требует вручную включить параметры разработчика/Wireless debugging и подтвердить первое ADB-сопряжение. Обычный APK не может сам включить защищённые системные настройки.
- Полная история SMS, прямая отправка SMS и активация виртуальной веб-камеры пока не входят в выпуск.
- Приложение для Mac имеет локальную ad-hoc подпись и не нотарифицировано Apple.
