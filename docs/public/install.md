# Install Galaxy Bridge 0.1.0

[English](#english) · [Русский](#russian) · [README](../../README.md)

<a id="english"></a>

## English

### Requirements and downloads

Use macOS 14 or later on an Apple Silicon Mac and Android 12 or later on a Samsung phone. Intel Macs are not included in this release. Download both the DMG and APK from [release 0.1.0](https://github.com/XopMC/GalaxyBridge/releases/tag/0.1.0); check any published checksums before installation.

### Mac

1. Open the DMG and drag **Galaxy Bridge** to **Applications**.
2. Launch the installed app. This prerelease uses an ad-hoc signature and is not Apple notarized.
3. If macOS blocks it, confirm you downloaded the intended release. After attempting to open it, go to **System Settings → Privacy & Security → Open Anyway** for Galaxy Bridge and confirm the system dialog. Keep macOS protection enabled for other apps.
4. Allow Local Network access when prompted so the Mac can communicate with your phone.

ADB is bundled; installing Homebrew, Android SDK, or a separate ADB package is unnecessary for using the download.

### Android and first connection

1. Open the APK on your phone and allow installation from the app you used to download it, if Android asks.
2. Open Galaxy Bridge, select the features you want, and grant their requested access. Declining a permission can leave that feature unavailable without blocking unrelated features.
3. For screen mirroring, enable Developer options and USB debugging, connect a data-capable USB cable, and approve the Mac’s debugging request on the phone.
4. Follow the pairing instructions in the apps for notifications, clipboard, and file transfers. Keep both devices on a mutually reachable local network for Companion features.
5. Test each selected feature on the connected devices. A granted permission or a connection indicator alone is not proof that a feature works.

Use the system language or the operating system’s per-app language setting. Ten languages are included, with separate Simplified and Traditional Chinese catalogs and English fallback.

### Troubleshooting

| Symptom | Next step |
|---|---|
| Phone missing over USB | Check the cable, USB debugging, and the authorization prompt on the phone. |
| Companion cannot connect | Check pairing, both devices’ local connectivity, and macOS Local Network permission. |
| No notification replies | The original Android notification must expose a reply action. |
| No audio in a recording | Some phone/app combinations cannot provide audio; the app indicates video-only recording. |
| File transfer interrupted | Reconnect and use the transfer’s retry/resume controls; wait for cancellation confirmation before assuming it completed. |

Received files appear in **Downloads** on Mac and **Download/GalaxyBridge** on Android. Wi-Fi acceptance and clean-Mac validation are still incomplete; report reproducible problems using the [bug template](https://github.com/XopMC/GalaxyBridge/issues/new/choose). Do not include pairing codes, keys, notification text, or personal files.

<a id="russian"></a>

## Русский

### Требования и загрузка

Нужны macOS 14 или новее на Mac с Apple Silicon и Android 12 или новее на телефоне Samsung. Intel Mac в этом выпуске не поддерживается. Скачайте DMG и APK со страницы [выпуска 0.1.0](https://github.com/XopMC/GalaxyBridge/releases/tag/0.1.0); перед установкой проверьте опубликованные контрольные суммы, если они приложены.

### Mac

1. Откройте DMG и перенесите **Galaxy Bridge** в **«Программы»**.
2. Запустите установленное приложение. У этого предварительного выпуска локальная ad-hoc подпись, нотарификации Apple нет.
3. Если macOS блокирует запуск, убедитесь, что скачали нужный выпуск. После попытки открытия перейдите в **«Системные настройки → Конфиденциальность и безопасность»** и разрешите запуск Galaxy Bridge кнопкой **«Всё равно открыть»**, затем подтвердите системный диалог. Оставьте защиту macOS включённой для остальных приложений.
4. Разрешите доступ к локальной сети по запросу, чтобы Mac мог связываться с телефоном.

ADB уже встроен: для использования готового приложения не нужны Homebrew, Android SDK и отдельная установка ADB.

### Android и первое подключение

1. Откройте APK на телефоне и, если Android попросит, разрешите установку из приложения, через которое скачали файл.
2. Откройте Galaxy Bridge, выберите нужные возможности и предоставьте запрошенный доступ. Отказ от разрешения может отключить эту функцию, не мешая остальным.
3. Для трансляции экрана включите режим разработчика и отладку по USB, подключите кабель с передачей данных и подтвердите запрос отладки для Mac на телефоне.
4. Следуйте подсказкам сопряжения в приложениях для уведомлений, буфера обмена и файлов. Для функций Companion устройства должны видеть друг друга в локальной сети.
5. Проверьте каждую выбранную функцию на подключённых устройствах. Одно выданное разрешение или индикатор подключения ещё не подтверждают её работу.

Приложения используют системный язык или язык, выбранный для приложения средствами ОС. Включены десять языков, отдельные каталоги упрощённого и традиционного китайского; резервный язык — английский.

### Если что-то не работает

| Проблема | Что проверить |
|---|---|
| Телефон не виден по USB | Кабель, отладку по USB и запрос авторизации на телефоне. |
| Companion не подключается | Сопряжение, доступность устройств в локальной сети и разрешение локальной сети в macOS. |
| Нет ответа на уведомление | Исходное уведомление Android должно предоставлять действие ответа. |
| В записи нет звука | Некоторые сочетания телефона и приложения не передают звук; Galaxy Bridge сообщает о записи только видео. |
| Передача файла прервалась | Подключитесь снова и используйте повтор/возобновление; дождитесь подтверждения отмены, прежде чем считать её завершённой. |

Файлы сохраняются в **«Загрузки»** на Mac и **Download/GalaxyBridge** на Android. Проверки Wi-Fi и чистого Mac ещё не завершены; воспроизводимые проблемы можно описать через [шаблон ошибки](https://github.com/XopMC/GalaxyBridge/issues/new/choose). Не прикладывайте коды сопряжения, ключи, содержимое уведомлений и личные файлы.
