# Contributing guide

[English](#english) · [Русский](#russian) · [README](../../README.md)

<a id="english"></a>

## English

Use a focused issue or pull request for one concrete problem. Describe what triggers it, the expected result, and the actual result. Include app and OS versions, phone model, and connection route (USB, Wireless ADB, or Companion). A model name is enough; device serials are unnecessary.

For code changes, explain the resulting behavior and run the checks relevant to the changed component. Follow the [build guide](build.md). Separate source checks, artifact validation, and hardware results in your report. Do not describe untested routes or devices as working.

Preserve cancellation, reconnect, permission, pairing, and file-integrity behavior. Test with uniquely named synthetic files and input. Do not automate consent, change a tester’s IME, or collect unrelated phone data. Clean up only the test data you created.

For translations, update the existing catalogs together and preserve format placeholders. The supported set contains ten languages / eleven catalogs: `en`, `ru`, `de`, `fr`, `es`, `pt`, `ar`, `zh-Hans`, `zh-Hant`, `ja`, `ko`. Keep English fallback and RTL behavior. Describe whether a translation was reviewed by a native speaker.

Keep pairing secrets, signing material, notification/message contents, phone numbers, and personal paths out of source, screenshots, and reports. Share minimal redacted diagnostics instead of full logs. For a security issue, avoid posting exploit details or secrets in a public issue; contact the maintainer using an available private channel first.

Contributions to the project’s own code are provided under the [MIT License](../../LICENSE). Preserve third-party copyright and license notices.

<a id="russian"></a>

## Русский

Посвящайте issue или pull request одной конкретной проблеме. Опишите условия возникновения, ожидаемый и фактический результат. Укажите версии приложения и ОС, модель телефона и способ подключения (USB, Wireless ADB или Companion). Модели достаточно; серийные номера устройств не нужны.

Для изменений кода объясните итоговое поведение и выполните проверки затронутого компонента по [инструкции сборки](build.md#russian). Отдельно указывайте проверки исходников, артефактов и реальные аппаратные результаты. Не называйте рабочими непроверенные устройства и способы подключения.

Сохраняйте поведение отмены, восстановления подключения, разрешений, сопряжения и целостности файлов. Для проверок используйте синтетические файлы и ввод с уникальными именами. Не автоматизируйте согласие, не меняйте клавиатуру пользователя и не собирайте посторонние данные телефона. Удаляйте только созданные вами тестовые данные.

При переводе обновляйте существующие каталоги согласованно, сохраняя подстановки. Поддерживаются десять языков / одиннадцать каталогов: `en`, `ru`, `de`, `fr`, `es`, `pt`, `ar`, `zh-Hans`, `zh-Hant`, `ja`, `ko`. Сохраняйте английский резервный язык и направление RTL. Укажите, проверен ли перевод носителем языка.

Не включайте секреты сопряжения, материалы подписи, содержимое уведомлений и сообщений, номера телефонов и личные пути в код, скриншоты и отчёты. Прикладывайте минимальную обезличенную диагностику вместо полных логов. Об уязвимости сначала сообщите автору по доступному закрытому каналу, не публикуя секреты и подробности эксплуатации в открытом issue.

Вклад в собственный код проекта распространяется по [лицензии MIT](../../LICENSE). Сохраняйте авторские права и лицензии сторонних компонентов.
