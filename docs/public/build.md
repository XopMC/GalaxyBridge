# Build from source

[English](#english) · [Русский](#russian) · [README](../../README.md)

<a id="english"></a>

## English

The public CMake workflow builds the native runtimes, macOS app, and Android Direct APK from this checkout. It does not use the existing release downloads as build inputs. A successful source build is separate from installation and hardware acceptance.

### Prerequisites

- Apple Silicon Mac, macOS 14+, Apple command-line developer tools with Swift 6 and the macOS SDK.
- CMake 3.25+, Ninja, Meson, Python 3.10+, and a working C/C++ toolchain.
- Rust 1.92+ with rustfmt and Cargo, with `aarch64-apple-darwin` and `aarch64-linux-android` standard libraries installed.
- JDK 21.0.3+; Android SDK platform 37, Build Tools 37.0.0, and Android NDK r29. The Gradle wrapper supplies the pinned Gradle version.
- Network access for pinned source archives and language-package dependencies on the initial build.

Select your JDK, SDK, and NDK through `JAVA_HOME`, `ANDROID_SDK_ROOT`, and `ANDROID_NDK_HOME`. Alternatively, pass CMake cache variables `GB_JAVA_HOME`, `GB_ANDROID_SDK_ROOT`, and `GB_ANDROID_NDK_HOME`. `GB_CARGO`, `GB_RUSTC`, and `GB_RUSTDOC` select an explicit Rust toolchain. Never put signing secrets into checked-in presets. Gradle verifies the wrapper distribution SHA-256 and the checked-in `android/gradle/verification-metadata.xml` pins the resolved dependency files for the supported Direct build and test graphs.

### Configure and build

Run these commands from the repository root. The optional bootstrap installs pinned CMake 3.31.6, Ninja 1.11.1.4, and Meson 1.11.1 into this build tree:

```sh
python3 scripts/bootstrap-build-tools.py
export PATH="$PWD/out/macos-arm64-release/tools/bin:$PATH"
```

Then configure and build:

```sh
cmake --preset macos-arm64-release
cmake --build --preset macos-arm64-release --target native macos-app android-apk
cmake --build --preset macos-arm64-release --target check
cmake --build --preset macos-arm64-release --target package
```

| Target | Result |
|---|---|
| `native` | Source-built QUIC backend, scrcpy server, and owned ADB runtime. |
| `macos-app` | Ad-hoc-signed `out/macos-arm64-release/artifacts/GalaxyBridge.app`; depends on `native`. |
| `android-apk` | Direct release APK under `out/macos-arm64-release/artifacts`; unsigned unless signing inputs are supplied. |
| `check` | Builds `native`, then checks compiled runtime pins, Swift core/protocol, Rust backend/media/transport/FFI, scrcpy and Android unit tests; no app installation or phone operation. |
| `package` | DMG, APK, and checksum files in `out/macos-arm64-release/packages`; builds app/APK prerequisites. |

The build preset defaults to `package` when no target is specified. The default concurrency is four jobs; configure `-DGB_BUILD_JOBS=2` if necessary. Build-generated integrity pins bind the Mac executable to the runtimes produced by the same build. Intermediate outputs live under `out/`, `.build/`, and the Android Gradle build directories. CMake isolates Cargo, Gradle, SwiftPM and bootstrap pip dependency caches under the selected build tree’s `dependency-cache/`; the externally installed Rust toolchain, JDK and Android SDK/NDK remain prerequisites. APK packaging disables Gradle build-cache reuse and reruns build tasks.

The supported automated entry point is CMake `check`, including Direct app and companion-core unit tests. Other legacy or Internal diagnostic scripts are retained as manual probes and may require their own fixture/signing harness; they are not covered by a claim that every historical script runs on a clean clone.

Packaging refuses to overwrite an existing `packages` directory. Move that directory aside or choose a fresh build directory before packaging again. Keep accepted release artifacts separate from build scratch files.

### Android signing

An unsigned APK is useful as a build artifact but **cannot be installed**. To make an installable Direct APK, supply all four environment variables using your own stable Android release identity:

```text
GB_ANDROID_DIRECT_KEYSTORE
GB_ANDROID_DIRECT_KEYSTORE_PASSWORD
GB_ANDROID_DIRECT_KEY_ALIAS
GB_ANDROID_DIRECT_KEY_PASSWORD
```

Do not commit a keystore or password. The build does not create or reuse the maintainer’s identity. Your key will differ from the official APK’s key, so Android may not accept a source build as an update over the official installation. Preserve your key for updates to your own build.

The macOS source app is ad-hoc signed; this workflow does not perform Apple notarization or activate a virtual webcam. A source rebuild is not claimed to be byte-identical to the 0.1.0 downloads, which predate the public CMake integration. See the [roadmap](roadmap.md) for remaining validation.

<a id="russian"></a>

## Русский

Публичный процесс CMake собирает нативные компоненты, приложение macOS и APK Android Direct из этого дерева исходников. Готовые файлы выпуска не используются как входные данные. Успешная сборка исходников — отдельная проверка, не заменяющая установку и аппаратную приёмку.

### Зависимости

- Mac с Apple Silicon, macOS 14+, инструменты разработчика Apple со Swift 6 и SDK macOS.
- CMake 3.25+, Ninja, Meson, Python 3.10+ и рабочий компилятор C/C++.
- Rust 1.92+ с rustfmt и Cargo со стандартными библиотеками `aarch64-apple-darwin` и `aarch64-linux-android`.
- JDK 21.0.3+; платформа Android SDK 37, Build Tools 37.0.0 и Android NDK r29. Закреплённую версию Gradle предоставляет wrapper.
- Доступ к сети для загрузки закреплённых архивов исходников и пакетных зависимостей при первой сборке.

Выберите JDK, SDK и NDK переменными `JAVA_HOME`, `ANDROID_SDK_ROOT` и `ANDROID_NDK_HOME`. Либо передайте параметры CMake `GB_JAVA_HOME`, `GB_ANDROID_SDK_ROOT` и `GB_ANDROID_NDK_HOME`. Для явного выбора Rust служат `GB_CARGO`, `GB_RUSTC` и `GB_RUSTDOC`. Не записывайте секреты подписи в отслеживаемые preset-файлы. Gradle проверяет SHA-256 дистрибутива wrapper; отслеживаемый `android/gradle/verification-metadata.xml` закрепляет файлы зависимостей поддерживаемых Direct-сборки и тестов.

### Настройка и сборка

Выполните из корня репозитория. Необязательный bootstrap устанавливает закреплённые CMake 3.31.6, Ninja 1.11.1.4 и Meson 1.11.1 в дерево сборки:

```sh
python3 scripts/bootstrap-build-tools.py
export PATH="$PWD/out/macos-arm64-release/tools/bin:$PATH"
```

Затем настройте и соберите проект:

```sh
cmake --preset macos-arm64-release
cmake --build --preset macos-arm64-release --target native macos-app android-apk
cmake --build --preset macos-arm64-release --target check
cmake --build --preset macos-arm64-release --target package
```

| Цель | Результат |
|---|---|
| `native` | Сборка QUIC, сервера scrcpy и собственного варианта ADB из исходников. |
| `macos-app` | Приложение с ad-hoc подписью `out/macos-arm64-release/artifacts/GalaxyBridge.app`; зависит от `native`. |
| `android-apk` | APK Direct release в `out/macos-arm64-release/artifacts`; без подписи, если её параметры не переданы. |
| `check` | Собирает `native`, проверяет скомпилированные runtime pins, Swift/core/protocol, Rust/backend/media/transport/FFI, scrcpy и Android unit tests; без установки приложений и действий на телефоне. |
| `package` | DMG, APK и контрольные суммы в `out/macos-arm64-release/packages`; сначала собираются необходимые приложение и APK. |

Без явного указания цели preset запускает `package`. По умолчанию используются четыре задания; при необходимости задайте `-DGB_BUILD_JOBS=2`. Созданные при сборке контрольные суммы связывают исполняемый файл Mac с собранными вместе с ним нативными компонентами. Промежуточные результаты находятся в `out/`, `.build/` и каталогах сборки Android Gradle. CMake размещает кэши зависимостей Cargo, Gradle, SwiftPM и bootstrap pip в `dependency-cache/` выбранного дерева сборки; установленные Rust, JDK и Android SDK/NDK остаются внешними инструментами. Упаковка APK отключает повторное использование Gradle build cache и заново выполняет задачи сборки.

Поддерживаемая автоматическая проверка — CMake `check`, включая unit tests Direct-приложения и companion-core. Остальные старые и Internal-диагностические скрипты сохранены как ручные проверки; им может потребоваться отдельная подготовка данных и подписи. Работоспособность каждого исторического скрипта на чистом клоне не заявляется.

Упаковка отказывается перезаписывать существующий каталог `packages`. Переместите его или выберите новый каталог сборки перед повторной упаковкой. Храните принятые файлы выпуска отдельно от промежуточных результатов.

### Подпись Android

APK без подписи подходит для проверки сборки, но **не устанавливается на устройство**. Для устанавливаемого Direct APK передайте все четыре переменные окружения со своей постоянной подписью Android:

```text
GB_ANDROID_DIRECT_KEYSTORE
GB_ANDROID_DIRECT_KEYSTORE_PASSWORD
GB_ANDROID_DIRECT_KEY_ALIAS
GB_ANDROID_DIRECT_KEY_PASSWORD
```

Не добавляйте хранилище ключей или пароль в репозиторий. Сборка не создаёт и не использует подпись автора. Ваш ключ отличается от ключа официального APK, поэтому Android может отказать в установке вашей сборки как обновления официального приложения. Сохраните свой ключ для обновления собственных сборок.

Приложение macOS подписывается ad-hoc; этот процесс не выполняет нотарификацию Apple и не активирует виртуальную веб-камеру. Побайтовое совпадение с файлами 0.1.0 не заявляется: они подготовлены до публичной интеграции CMake. Незавершённые проверки перечислены в [планах](roadmap.md#russian).
