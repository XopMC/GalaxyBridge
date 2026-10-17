# Roadmap

[English](#english) · [Русский](#russian) · [README](../../README.md)

<a id="english"></a>

## English

Work toward the 0.1.2 Direct preview for macOS and Android. Completed checks and remaining work are listed separately.

### Release checks

- [x] Exercise five phone screens and five app windows together over USB and Wi-Fi.
- [x] Check text and image clipboard, in-app notification replies, file checksums, recording and camera preview.
- [x] Complete 30 consecutive screen opens and closes over the prepared wireless connection.
- [ ] Finish the hour-long concurrent run, then recheck the windows and controls.
- [ ] Complete network interruption and roaming checks, direct groups and two-phone internet sharing with automatic restoration.
- [ ] Finish large-file cancellation and transfer recovery checks.
- [ ] Validate installation and first launch on a clean Apple Silicon Mac without development tools.
- [ ] Expand app, phone and network compatibility testing.
- [ ] Review all shipped translations with native speakers and check layout on additional devices.
- [x] Rebuild and validate installable artifacts from the public CMake workflow.

### Future capabilities

- [ ] Design and implement full SMS history and direct sending with appropriate Android roles and consent.
- [ ] Finish supported virtual webcam distribution, activation, and app compatibility testing.
- [ ] Evaluate Developer ID signing and notarization for smoother macOS installation.
- [ ] Document the constrained store-distribution path separately from the current ADB-enhanced Direct release.

USB and Companion routes have different requirements. A source test, successful package, and real-device acceptance are separate checks. Please include the route and versions when proposing a fix or reporting a result.

<a id="russian"></a>

## Русский

Подготовка предварительного выпуска 0.1.2 для macOS и Android. Пройденные проверки и оставшиеся задачи перечислены отдельно.

### Проверки перед выпуском

- [x] Проверить пять экранов телефонов и пять окон приложений одновременно по USB и Wi-Fi.
- [x] Проверить текст и изображения в буфере, ответы внутри панели уведомлений, контрольные суммы файлов, запись и предпросмотр камеры.
- [x] Пройти 30 открытий и закрытий экрана по подготовленному беспроводному соединению.
- [ ] Завершить часовую одновременную проверку, затем повторно проверить окна и управление.
- [ ] Проверить обрывы и смену сети, прямые группы и раздачу интернета с двух телефонов с автоматическим восстановлением.
- [ ] Завершить проверки отмены больших файлов и восстановления передачи.
- [ ] Проверить установку и первый запуск на чистом Mac с Apple Silicon без инструментов разработчика.
- [ ] Расширить проверки совместимости приложений, телефонов и сетей.
- [ ] Проверить все переводы с носителями языка и раскладку интерфейса на дополнительных устройствах.
- [x] Пересобрать и проверить установочные файлы публичным процессом CMake.

### Будущие возможности

- [ ] Спроектировать и реализовать полную историю SMS и прямую отправку с необходимыми ролями Android и согласием пользователя.
- [ ] Довести распространение, активацию и совместимость виртуальной веб-камеры.
- [ ] Рассмотреть подпись Developer ID и нотарификацию для более простой установки на macOS.
- [ ] Отдельно описать ограниченный вариант для магазинов приложений и текущий Direct с расширенными возможностями ADB.

USB и Companion предъявляют разные требования. Проверки исходников, успешная упаковка и приёмка на реальном устройстве — отдельные этапы. В сообщениях об ошибках и результатах указывайте способ подключения и версии.
