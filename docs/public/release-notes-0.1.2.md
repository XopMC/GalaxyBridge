# Galaxy Bridge 0.1.2 — candidate

[English](#english) · [Русский](#russian) · [Setup](direct-connectivity.md)

<a id="english"></a>

## English

0.1.2 adds nearby setup and optional system-wide internet sharing. USB, LAN and the existing QUIC path are retained.

- Authenticated BLE setup for Android Wi-Fi Direct, with a local-only hotspot fallback and offline QR pairing.
- Per-device connection controls and two independent gateway slots: automatic selection, a fixed phone or balancing of new connections.
- Phone Wi-Fi preference and cellular fallback; an active phone VPN is respected for data and DNS.
- Optional Mac network installer, owned route/DNS leases, heartbeat recovery and caller checks against the approved hardened application.
- Per-boot enhanced access over an ADB-activated Binder/FD bridge, with bounded requests, ordered media streams and exact child retirement.
- Eleven system-language catalogs with English fallback; bundled ADB remains included.
- Serialized shared-group creation for simultaneous nearby connections, basic connection fallback after optional bridge activation errors, and cancellation retained before the tunnel worker starts.
- Cancellable setup, clear phone-update/permission guidance, pairing-sheet dismissal, compact connection controls and stable small-window layout. Fixed gateway selection cannot silently use another phone.
- Background clipboard image conversion and history writes, bounded pending work and recipient trust checks. App windows publish geometry changes only when needed; video frames and QUIC remain unchanged.
- Bluetooth discovery recovers after radio changes; pending QR offers survive Activity recreation, and leaving the scanner fences late camera startup. Notification rows have equal card heights and expose additional actions; file reception confirms the selected folder.

### Verified

The automated source suite and source builds pass. S24 Ultra checks over an owned USB test channel covered gateway HTTPS, UDP and DNS; real H.264 and text/Enter control; the capture-free clipboard channel; physical panel restoration after STOP, an independent 30-second timeout and Helper process death. A real Bluetooth OFF/ON trial recovered discovery without restarting the Activity, using an independent 18-second restore process on the phone. These checks do not establish direct Wi-Fi latency or Mac system routing.

### Before public release

Two-phone USB/direct/shared-group operation, STA concurrency, the Mac installer and real tunnel/route/DNS recovery still require hardware acceptance. Complete 30 reconnect cycles and one hour of concurrent load with an independent reserve uplink. Until concurrency is verified, a phone already connected to Wi-Fi may refuse direct group creation. IPv6 depends on the selected upstream; the tested phone VPN did not provide an IPv6 route.

macOS 14+ on Apple Silicon and Android 12+ remain required. The Mac app is ad-hoc signed and not notarized. Virtual webcam activation and full SMS history/direct sending remain outside this candidate. See the [setup guide](direct-connectivity.md) for installation and scope.

<a id="russian"></a>

## Русский

0.1.2 добавляет подключение поблизости и необязательную системную раздачу интернета. USB, LAN и существующий QUIC сохраняются.

- Настройка Android Wi-Fi Direct через защищённый BLE-обмен, запасной режим локальной точки доступа и QR-сопряжение без общей сети.
- Отдельное управление устройствами и два независимых шлюза: автоматический выбор, конкретный телефон или распределение новых соединений.
- Приоритет Wi-Fi телефона и переход на мобильную сеть; действующий VPN телефона используется и для данных, и для DNS.
- Необязательный сетевой установщик Mac, собственные временные маршруты и DNS, восстановление по heartbeat и проверка вызывающего hardened-приложения.
- Расширенный доступ до перезагрузки через активированный по ADB мост Binder/FD: ограниченные запросы, правильный порядок медиаканалов и завершение принадлежащих сеансу процессов.
- Одиннадцать системных языков с английским fallback; ADB по-прежнему встроен.
- Последовательное создание общей группы при одновременном подключении, сохранение базового подключения при ошибке дополнительного моста и обработка отмены до запуска туннеля.
- Отмена настройки, понятные подсказки об обновлении и разрешениях телефона, закрытие QR после привязки и компактный блок подключений с корректными размерами небольшого окна. Выбор конкретного шлюза не приводит к скрытому использованию другого телефона.
- Обработка изображений буфера и запись истории в фоне, ограниченная очередь и проверка доверия получателей. Окна приложений сообщают об изменении геометрии только при необходимости; видеокадры и QUIC сохранены.
- Обнаружение восстанавливается после переключения Bluetooth; QR сохраняется при пересоздании Activity, а выход из сканера блокирует поздний запуск камеры. Карточки уведомлений выровнены по строкам, доступны дополнительные действия и подтверждение папки приёма файлов.

### Проверено

Автоматические проверки и сборка исходников проходят. На S24 Ultra через собственный тестовый USB-канал проверены HTTPS, UDP и DNS шлюза; настоящая H.264-картинка и ввод текста/Enter; канал буфера без захвата экрана; восстановление физической панели после STOP, независимого таймера 30 секунд и завершения Helper. Настоящее выключение/включение Bluetooth восстановило обнаружение без перезапуска Activity; отдельный процесс на телефоне вернул радио через 18 секунд. Эти проверки не подтверждают задержку прямого Wi-Fi и системную маршрутизацию Mac.

### До публичного выпуска

Нужна аппаратная приёмка двух телефонов в режимах USB/direct/общей группы, совмещения STA, установщика Mac и реального восстановления туннеля, маршрутов и DNS. Также нужны 30 переподключений и час параллельной нагрузки с независимым резервным каналом. Пока совмещение режимов не проверено, телефон с активным Wi-Fi может отказаться создавать прямую группу. IPv6 зависит от внешней сети; проверенный VPN телефона не предоставил маршрут IPv6.

Требования прежние: macOS 14+ на Apple Silicon и Android 12+. Mac-приложение имеет ad-hoc подпись без нотарификации. Активация виртуальной веб-камеры, полная история и прямая отправка SMS остаются вне этого кандидата. Установка и границы возможностей описаны в [руководстве](direct-connectivity.md#russian).
