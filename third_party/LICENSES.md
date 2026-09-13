# Third-party registry

| Component | Pinned version | License | Distribution use |
|---|---:|---|---|
| SwiftProtobuf | 1.38.1 | Apache-2.0 | Swift protocol runtime and build plugin |
| Protocol Buffers | 36.0 / Java lite 4.36.0 | BSD-3-Clause | schema compiler and Android runtime |
| Jetpack Compose | BOM 2026.08.00 | Apache-2.0 | Android UI |
| AndroidX Activity | 1.12.4 | Apache-2.0 | Android lifecycle and Compose host |
| AndroidX CameraX | 1.6.2 | Apache-2.0 | companion camera source |
| AndroidX DocumentFile | 1.1.0 | Apache-2.0 | SAF transfer destination |
| Kotlin coroutines | 1.10.2 | Apache-2.0 | Android service streams |
| scrcpy server | 4.1 | Apache-2.0 | internal/enhanced server only |
| Android Debug Bridge | AOSP `android-17.0.0_r1` | Apache-2.0 | Developer ID package only; built by `scripts/build-aosp-adb.sh` |
| Owned Android Debug Bridge | android-tools-static 36.0.1 + published owned-runtime patches | Apache-2.0 and dependency notices | GitHub Direct; built from source, never copied from the Google SDK |
| libusb | 1.0.29 + nonseizing USB patch | LGPL-2.1-or-later | Replaceable shared library; exact corresponding source and replacement instructions ship with the runtime |
| quiche and Rust QUIC dependencies | Cargo.lock and vendored source pins | Original component licenses | See `quic/NOTICE.md` and vendored quiche license |
| SQLite | macOS system library | Public domain | encrypted-cache metadata |
| XcodeGen | build-time only | MIT | generates the macOS Xcode project |
| Gradle | 9.5.0 wrapper | Apache-2.0 | Android build-time only |
| JUnit | 4.13.2 | EPL-1.0 | tests only |

The installed Android SDK Platform Tools binary is an internal development dependency and is not a redistributable project artifact.

The private-key-shaped file `native/galaxybridge-quic/vendor/quiche/examples/cert.key`
is public upstream test material, not a production identity. Its approved SHA-256
is checked by `scripts/check-public-tree.py`. No personal signing or pairing keys
are distributed. The root MIT license applies to Galaxy Bridge's own code only.
