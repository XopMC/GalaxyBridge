# scrcpy server protocol

Galaxy Bridge speaks scrcpy 4.1's internal server protocol. Client and server
versions must be updated together because that protocol changes between releases.

The public CMake workflow downloads the pinned upstream sources, verifies their
SHA-256, and builds both the stock and Galaxy Bridge patched servers. The result
is bound to the application through compiled integrity pins. See the
[build guide](../../docs/public/build.md) and [patch notes](../scrcpy-gb-sync/README.md).

The original upstream `scrcpy-server-v4.1` is retained here for the standalone
Xcode project and developer probes. CMake does not use it as a build input. It
retains the upstream Apache-2.0 license in this directory.
