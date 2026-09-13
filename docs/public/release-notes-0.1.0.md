# Galaxy Bridge 0.1.0 — prerelease

[Download](https://github.com/XopMC/GalaxyBridge/releases/tag/0.1.0) · [English](#english) · [Русский](#russian)

<a id="english"></a>

## English

The first Direct-channel distribution includes a drag-to-Applications DMG for **macOS 14+ / Apple Silicon** and an APK for **Android 12+**. ADB is included in the Mac app. Both apps use the same One UI-inspired icon and follow system language preferences with English fallback.

The release focuses on phone mirroring and control, supported phone audio and recording, notification actions, clipboard, and resumable file transfers in both directions. Setup saves selected features and explains missing access. A feature is not marked verified solely because a permission was granted.

Included languages: English, Russian, German, French, Spanish, Portuguese, Arabic, Chinese (Simplified and Traditional), Japanese, and Korean. Native-speaker review is still welcome.

### Known limits

- This is a prerelease: Wi-Fi acceptance, clean-Mac installation, and the extended hardware matrix remain incomplete.
- Full SMS history/direct sending and virtual webcam activation are outside 0.1.0. Notification replies require a reply action from the original Android notification.
- Audio availability depends on the phone and app; recording can be video-only.
- The Mac app is ad-hoc signed, without Apple notarization. Follow the [installation guide](install.md).
- Existing 0.1.0 DMG/APK binaries were prepared before the public CMake integration. Documentation/build-system changes do not imply that those binaries were rebuilt from the public workflow.

See [installation](install.md), [source builds](build.md), and the [remaining work](roadmap.md). Build/package checks do not substitute for device acceptance.

<a id="russian"></a>

## Русский

Первый выпуск канала Direct включает DMG с переносом приложения в «Программы» для **macOS 14+ / Apple Silicon** и APK для **Android 12+**. ADB встроен в приложение для Mac. У обоих приложений общая иконка в духе One UI и выбор языка по настройкам системы с английским резервным языком.

Основные возможности выпуска: экран и управление телефоном, доступный на устройстве звук и запись, действия уведомлений, буфер обмена и возобновляемая передача файлов в обе стороны. Настройка сохраняет выбранные функции и объясняет недостающий доступ. Выданное разрешение само по себе не означает успешную проверку функции.

Языки: английский, русский, немецкий, французский, испанский, португальский, арабский, китайский (упрощённый и традиционный), японский и корейский. Проверка переводов носителями языка ещё приветствуется.

### Известные ограничения

- Это предварительный выпуск: приёмка Wi-Fi, установка на чистый Mac и расширенная матрица устройств ещё не завершены.
- Полная история SMS, прямая отправка SMS и активация виртуальной веб-камеры не входят в 0.1.0. Ответ на уведомление требует действия ответа от исходного уведомления Android.
- Доступность звука зависит от телефона и приложения; запись может содержать только видео.
- Приложение для Mac имеет локальную ad-hoc подпись без нотарификации Apple. Порядок установки описан в [инструкции](install.md#russian).
- Существующие DMG/APK 0.1.0 подготовлены до публичной интеграции CMake. Изменение документации и процесса сборки не означает пересборку этих бинарников публичным процессом.

Подробнее: [установка](install.md#russian), [сборка исходников](build.md#russian), [незавершённые задачи](roadmap.md#russian). Проверки сборки и упаковки не заменяют приёмку на устройствах.
