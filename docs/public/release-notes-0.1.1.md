# Galaxy Bridge 0.1.1 — prerelease

[Download](https://github.com/XopMC/GalaxyBridge/releases/tag/0.1.1) · [English](#english) · [Русский](#russian)

<a id="english"></a>

## English

This maintenance prerelease fixes the macOS 26 crash that occurred when the QR pairing sheet opened. The Direct macOS application now loads localizations from its application bundle instead of SwiftPM's generated resource bundle.

Wireless ADB discovery now resolves Android's Bonjour `.local` endpoints to private IPv4 addresses and tries an already-trusted connection service before asking for a six-digit pairing code. The setup sheet searches the local network instead of incorrectly waiting for the phone's code screen.

Android-to-Mac clipboard sync now uses a bounded capture-free agent inside the bundled scrcpy server. The Mac launches it under the already-authorized ADB shell, so it can poll the current Android clipboard while Gallery or another app is in front. Text and copied PNG images are forwarded without a Galaxy Bridge keyboard and without the Share menu. Sensitive clips are ignored.

The release includes a rebuilt drag-to-Applications DMG for **macOS 14+ / Apple Silicon** and a signed Direct APK for **Android 12+**. ADB remains included in the Mac app. The QR pairing screen was opened successfully from the packaged macOS app during release validation.

### Maintenance update

The refreshed 0.1.1 builds fix repeated clipboard copies and background image
reads, bound notification queues and reconcile missed removals after reconnect,
retain removable offline devices, and keep catalog tiles visible during refresh.
Camera controls fit the selected language and describe phone-camera preview.
QUIC session files are removed after normal retirement and partial launch failure.
First pairing now observes the committed discovery snapshot immediately; concurrent
Android identity creation is serialized. A protected-folder permission wait can
no longer delay requested application termination indefinitely.
If a device disappears, its mirror now shows a readable unavailable state and
a close button instead of a blank borderless window. A follow-up 331-second
Wireless ADB motion run completed without disconnects; occasional pauses remain.

The experimental QUIC path retains its existing transport. Its native child now
uses the owned ADB environment and endpoint; AVC requests constant bitrate,
matching the Wireless ADB profile. In the tested S24 runs this improved sustained
presentation and input timing; occasional stalls remain. QUIC remains opt-in.
See [audit evidence and validation limits](production-audit.md).

### Wi-Fi and input update

The bundled private ADB server now enables negotiated Burst Mode. At the same
1920-max / 60 fps target / 6 Mbps profile, sequential S24 motion checks reduced
the maximum presentation gap from 317 ms (258 s run) to 125 ms (93 s run).
All twelve measured clicks arrived in 83–216 ms. Network jitter remains; these
figures are observations, not universal limits. Precise trackpad scrolling now
uses the Mac's system-adjusted direction. Metal redraws recover when a drawable
is temporarily unavailable. QUIC keeps its architecture and receives bounded
intake, pacing and gesture-order fixes; it remains opt-in.

This Wi-Fi update rebuilds the DMG and bundled native resources. The signed APK
is byte-identical to the preceding maintenance upload.

### Known limits

- Wi-Fi reliability, clean-Mac installation, and the wider hardware matrix still need validation.
- File reception uses an explicit Downloads folder chooser and remembers the selection. A neutral phone→Mac→phone round trip passed exact-byte verification after restart.
- Android requires the user to enable Developer options/Wireless debugging and approve the initial ADB pairing. A regular APK cannot enable these protected system settings itself.
- Full SMS history/direct sending and virtual webcam activation are not included.
- The Mac app is ad-hoc signed and not Apple-notarized.

<a id="russian"></a>

## Русский

В этом техническом предварительном выпуске исправлено падение macOS 26 при открытии окна QR-сопряжения. Приложение Direct для macOS теперь загружает локализации из бандла приложения, а не из сгенерированного SwiftPM пакета ресурсов.

Поиск Wireless ADB теперь преобразует Android Bonjour-адреса `.local` в локальный IPv4 и сначала пробует уже доверенный сервис подключения. Шестизначный код запрашивается только для нового сопряжения; окно настройки больше не утверждает, что ждёт экран кода на телефоне.

Для передачи буфера Android → Mac добавлен ограниченный по размеру агент внутри встроенного scrcpy-сервера. Mac запускает его в уже разрешённом ADB shell, поэтому он опрашивает текущий буфер Android, даже когда открыта «Галерея» или другое приложение. Текст и скопированные PNG передаются без клавиатуры Galaxy Bridge и без меню «Поделиться». Чувствительные данные буфера игнорируются.

В выпуск входят заново собранный DMG с переносом приложения в «Программы» для **macOS 14+ / Apple Silicon** и подписанный Direct APK для **Android 12+**. ADB по-прежнему встроен в приложение для Mac. В ходе проверки выпуска QR-экран был успешно открыт из упакованного приложения macOS.

### Обновление сборок

В обновлённых сборках 0.1.1 исправлены повторное копирование в буфер и фоновое
чтение изображений. Очереди уведомлений ограничены, пропущенные удаления
восстанавливаются после переподключения. Ранее добавленные устройства остаются
доступны для удаления без сети, а каталог сохраняет плитки при обновлении.
Элементы управления камерой адаптируются к языку и описывают предпросмотр камеры
телефона.
Временные файлы QUIC удаляются после штатного завершения и ошибки подготовки сеанса.
После первой привязки Mac сразу читает актуальный список найденных устройств;
параллельное создание идентификатора и ключей Android синхронизировано. Ожидание
доступа к защищённой папке больше не может бесконечно задерживать выход приложения.
При исчезновении устройства окно трансляции показывает понятное сообщение
и кнопку закрытия вместо пустого окна без рамки. Дополнительный 331-секундный
прогон Wireless ADB прошёл без разрывов; отдельные паузы картинки сохраняются.

Экспериментальный QUIC сохраняет прежний транспорт. Дочерний процесс получает
параметры встроенного ADB, а кодировщик AVC использует постоянный битрейт, как
в Wireless ADB. В проведённых проверках на S24 это улучшило плавность и задержку
управления; отдельные паузы остаются. QUIC по-прежнему включается отдельно.
Подробнее — [результаты аудита и границы проверки](production-audit.md).

### Обновление Wi-Fi и управления

Встроенный приватный сервер ADB теперь включает согласуемый Burst Mode. При
прежних 1920 пикселях, целевых 60 кадрах/с и 6 Мбит/с последовательные проверки
S24 показали уменьшение максимальной паузы с 317 мс (258 секунд) до 125 мс
(93 секунды). Все 12 измеренных кликов дошли за 83–216 мс. Это результаты
конкретных прогонов, а не универсальная гарантия: колебания сети остаются.
Прокрутка трекпадом следует системному направлению Mac, а Metal повторяет
отрисовку при временно недоступной поверхности. Архитектура QUIC сохранена;
исправлены чтение кадров, опережение отправки и порядок жестов. Он остаётся
экспериментальным режимом.

В этом обновлении Wi-Fi пересобраны DMG и встроенные нативные ресурсы. Подписанный
APK побайтово совпадает с предыдущей загрузкой технического обновления.

### Известные ограничения

- Надёжность Wi-Fi, установка на чистый Mac и расширенная матрица устройств ещё требуют проверки.
- Для приёма файлов добавлен выбор «Загрузок» через системное окно с сохранением выбора. Нейтральный файл прошёл проверку телефон→Mac→телефон после перезапуска с совпадением всех байтов.
- Android требует вручную включить параметры разработчика/Wireless debugging и подтвердить первое ADB-сопряжение. Обычный APK не может сам включить защищённые системные настройки.
- Полная история SMS, прямая отправка SMS и активация виртуальной веб-камеры пока не входят в выпуск.
- Приложение для Mac имеет локальную ad-hoc подпись и не нотарифицировано Apple.
