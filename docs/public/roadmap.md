# Roadmap

[English](#english) · [Русский](#russian) · [README](../../README.md)

<a id="english"></a>

## English

0.1.1 is an early Direct-channel release for macOS and Android. This list distinguishes remaining validation from future product work; it is not a promise of delivery dates.

### Release follow-up

- [ ] Complete Wi-Fi performance, interruption, and recovery acceptance.
- [ ] Validate installation and first launch on a clean Apple Silicon Mac without development tools.
- [ ] Expand the Samsung/Android/macOS hardware matrix, including audio, recording, input, notification actions, and transfer recovery.
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

0.1.1 — ранний выпуск канала Direct для macOS и Android. Ниже отдельно перечислены незавершённые проверки и будущие возможности; сроки не обещаются.

### После выпуска

- [ ] Завершить приёмку Wi-Fi: производительность, обрывы и восстановление.
- [ ] Проверить установку и первый запуск на чистом Mac с Apple Silicon без инструментов разработчика.
- [ ] Расширить матрицу Samsung/Android/macOS: звук, запись, ввод, действия уведомлений и восстановление передачи файлов.
- [ ] Проверить все переводы с носителями языка и раскладку интерфейса на дополнительных устройствах.
- [x] Пересобрать и проверить установочные файлы публичным процессом CMake.

### Будущие возможности

- [ ] Спроектировать и реализовать полную историю SMS и прямую отправку с необходимыми ролями Android и согласием пользователя.
- [ ] Довести распространение, активацию и совместимость виртуальной веб-камеры.
- [ ] Рассмотреть подпись Developer ID и нотарификацию для более простой установки на macOS.
- [ ] Отдельно описать ограниченный вариант для магазинов приложений и текущий Direct с расширенными возможностями ADB.

USB и Companion предъявляют разные требования. Проверки исходников, успешная упаковка и приёмка на реальном устройстве — отдельные этапы. В сообщениях об ошибках и результатах указывайте способ подключения и версии.
