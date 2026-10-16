# Direct connections and internet sharing

[English](#english) · [Русский](#russian) · [Build](build.md)

<a id="english"></a>

## English

This guide describes the **0.1.2 source candidate**. The published 0.1.1 downloads do not contain these controls. A source build and automated checks do not establish two-phone hardware compatibility; the acceptance matrix remains open until those tests are completed.

### Connect without a router

Enable nearby connections in Android Helper and allow its Bluetooth and nearby Wi-Fi permissions. On the Mac, allow Bluetooth, Local Network and Location access; macOS requires Location access to identify the current Wi-Fi association safely.

Use **Nearby connection** for a paired phone. For first pairing without a shared network, open the nearby pairing QR on the Mac and scan it with Helper. Bluetooth carries an authenticated, encrypted setup exchange; screen, files and other data use Wi-Fi. Closing the QR cancels an unfinished pairing.

Galaxy Bridge uses an Android Wi-Fi Direct group, with a local-only hotspot fallback. The Mac joins that network as a Wi-Fi client. A Mac with one Wi-Fi radio can use one shared group for two phones. An existing healthy USB or LAN connection remains preferred. Automatic nearby connection is available after a successful explicit connection and only joins when the Mac is not already associated with another Wi-Fi network.

The phone may keep its existing Wi-Fi only when the required concurrency is verified. Unsupported or unverified combinations are refused rather than silently disconnecting its station network. Bluetooth loss after verified Wi-Fi setup does not itself end the data connection. **Disconnect** keeps a shared group alive while another paired phone uses it; the last owned connection restores the Mac's previous association when it is still owned by Galaxy Bridge. Forgetting the group owner also retires dependent direct sessions; those phones remain paired and can reconnect independently.

### Share the phone's internet

Allow internet sharing in Helper, then enable **Internet sharing** for that phone on the Mac. System-wide sharing needs the optional **Galaxy Bridge Network** installer embedded in the Mac app. Install Galaxy Bridge in `/Applications` first; the system installer requires administrator authentication. Screen control, files and ordinary pairing do not need this component.

The component creates an owned tunnel and route/DNS lease. Network data runs in the regular app process. The Mac reports ready only after probes through the selected gateway and the installed tunnel succeed. An existing Mac VPN prevents route installation; it is not replaced automatically.

An active phone VPN is respected for both internet traffic and DNS. If it becomes unavailable, the gateway waits instead of bypassing it through physical Wi-Fi. Without a VPN, the phone prefers validated Wi-Fi and falls back to validated cellular service. IPv6 depends on the selected upstream; a network or VPN without an IPv6 route cannot supply it.

With two phones, select automatic gateway choice, a fixed phone, or balancing of new connections. Existing connections stay on their selected phone; this does not combine two links into one faster download. Loss of an upstream can interrupt its connections. Stop sharing to restore owned network state; **Remove network component** first stops sharing and then removes the optional helper.

### Enhanced access

Basic nearby connectivity and internet sharing do not require Android shell access. Separate app windows, the full clipboard bridge and phone display privacy use the bounded shell bridge activated through an authorized ADB connection. It lasts until the phone reboots or the bridge is stopped; ordinary Android permissions cannot grant shell privileges automatically. No public ADB TCP listener is enabled.

### Acceptance still required

The release gate includes two real phones in USB/USB, USB/direct and shared direct modes; upstream switching; TCP/UDP/DNS and IPv4/IPv6; forced recovery; 30 reconnect cycles; and one hour of simultaneous load. Risky Mac network trials require a validated independent uplink and an armed recovery guardian. Unsupported or untested cases must not be reported as passed.

<a id="russian"></a>

## Русский

Здесь описан **кандидат 0.1.2 из исходников**. В опубликованных файлах 0.1.1 этих настроек нет. Сборка и автоматические проверки не подтверждают совместимость двух реальных телефонов: аппаратная матрица остаётся открытой до завершения испытаний.

### Подключение без роутера

Включите подключения поблизости в Android Helper и разрешите Bluetooth и доступ к устройствам Wi-Fi поблизости. На Mac разрешите Bluetooth, локальную сеть и геопозицию: macOS требует геопозицию, чтобы безопасно определить текущее подключение Wi-Fi.

Для сопряжённого телефона используйте **Подключение поблизости**. Для первого сопряжения без общей сети откройте QR на Mac и отсканируйте его через Helper. Bluetooth передаёт зашифрованные данные настройки с проверкой подлинности; экран, файлы и остальные данные идут по Wi-Fi. Закрытие QR отменяет незавершённое сопряжение.

Galaxy Bridge создаёт группу Android Wi-Fi Direct; запасной вариант — локальная точка доступа. Mac подключается к ней как клиент Wi-Fi. Один Wi-Fi-модуль Mac использует одну общую группу для двух телефонов. Рабочее подключение USB или LAN сохраняет приоритет. Автоподключение поблизости доступно после успешного ручного подключения и присоединяется к сети только тогда, когда Mac не подключён к другой сети Wi-Fi.

Телефон сохраняет своё подключение Wi-Fi только при проверенной поддержке нужного совмещения режимов. Неподдерживаемая или непроверенная комбинация отклоняется без скрытого отключения текущей сети. Потеря Bluetooth после проверки Wi-Fi сама по себе не завершает передачу данных. **Отключить** сохраняет общую группу, пока ей пользуется другой сопряжённый телефон; последнее подключение восстанавливает прежнюю сеть Mac, если ей всё ещё управляет Galaxy Bridge. Удаление владельца группы завершает и зависимые прямые сеансы; эти телефоны сохраняют привязку и могут подключиться самостоятельно.

### Интернет с телефона

Разрешите раздачу интернета в Helper, затем включите **Интернет с телефона** для нужного устройства на Mac. Для системной раздачи нужен необязательный установщик **Galaxy Bridge Network**, встроенный в приложение Mac. Сначала установите Galaxy Bridge в `/Applications`; системный установщик запросит пароль администратора. Управление экраном, файлы и обычное сопряжение этого компонента не требуют.

Компонент создаёт собственный туннель и временные настройки маршрутов и DNS. Данные обрабатывает обычный процесс приложения. Статус готовности появляется только после проверок выбранного шлюза и установленного туннеля. Если на Mac уже работает VPN, установка маршрутов отклоняется: приложение не заменяет VPN автоматически.

Если на телефоне работает VPN, через него идут и данные, и DNS. При его недоступности шлюз ждёт восстановления, не обходя VPN через физический Wi-Fi. Без VPN телефон предпочитает проверенное подключение Wi-Fi и переключается на мобильную сеть. IPv6 зависит от выбранного внешнего подключения: сеть или VPN без маршрута IPv6 не смогут его предоставить.

С двумя телефонами можно выбрать автоматический шлюз, конкретный телефон или распределение новых соединений. Уже открытое соединение остаётся на выбранном телефоне; скорости двух линий в одной загрузке не суммируются. При потере внешнего подключения его соединения могут оборваться. Выключение раздачи восстанавливает принадлежащие приложению сетевые настройки; **Удалить сетевой компонент** сначала останавливает раздачу, затем удаляет дополнительный компонент.

### Расширенный доступ

Базовое подключение поблизости и раздача интернета не требуют shell-доступа Android. Отдельные окна приложений, полный мост буфера обмена и отключение дисплея телефона используют ограниченный shell-мост, активированный через авторизованное ADB-подключение. Он действует до перезагрузки телефона или остановки моста. Обычные разрешения APK не позволяют автоматически получить shell-права. Общедоступный TCP-порт ADB не включается.

### Незавершённая приёмка

Перед выпуском нужны два реальных телефона в режимах USB/USB, USB/direct и общей прямой группы; переключение внешней сети; TCP/UDP/DNS и IPv4/IPv6; принудительное восстановление; 30 переподключений и час одновременной нагрузки. Опасные сетевые испытания Mac требуют проверенного независимого канала и включённого watchdog восстановления. Неподдерживаемые и непроверенные случаи нельзя отмечать как пройденные.
