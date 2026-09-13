# Galaxy Bridge owned ADB

This is a source patch set for `meator/android-tools-static` 36.0.1 (AOSP ADB),
not a redistributed Google SDK binary. The pinned source archive SHA-256 is
`6aff0c12aa8d22f3621845fb2dd7e1fb874546761376f9791312c4939cab38e6`.

Apply `0001-owned-runtime.patch` before Meson dependency setup, then apply
`0002-nonseizing-usb.patch` after the pinned libusb wrap is materialized.
`scripts/build-owned-adb.sh` performs these steps in a separate source/build
directory, compiles, stages licenses and exact modified LGPL source, and runs
the real artifact contract. See [the public build guide](../../docs/public/build.md) for builder requirements.

The first patch requires a private canonical 0700 key directory, explicit Unix
socket, foreground owner and inherited stdin lifetime pipe. It rejects implicit
server launch/restart, version replacement, global kill-server, vendor keys,
automatic key generation and destructive corrupt-trust recovery. Production
Swift first checks the reviewed binary hash, provisions only its separate
identity, and preserves that identity across app restarts.

The second patch enables USB only with the explicit policy
`GALAXYBRIDGE_ADB_USB_POLICY=usb-nonseizing-v1`. It forces the patched libusb
backend, tries ordinary `USBDeviceOpen` exactly once, declines busy/denied
devices, and disables seize, reset, reenumeration, kernel-driver detach/attach,
configuration changes and descriptor recovery that changes suspension/config.
The shared direct app owner selects this policy for normal cable use. Tests
default to USB disabled. Fake callbacks exercise the source's acquisition
policy; they do not prove physical-device compatibility or coexistence.

The public CMake build generates a Swift module containing the SHA-256 of its
freshly built ADB and libusb artifacts. Those expected hashes are compiled into
the application; an adjacent manifest cannot redefine runtime trust. Source
patch hashes and build provenance are recorded alongside the runtime. Rebuild
the app when changing runtime sources. This is integrity binding, not a claim
of byte-identical builds across toolchains or build paths.

libusb remains dynamically replaceable under its LGPL terms; its exact source,
build files and replacement/rehash/re-sign instructions are included in the
runtime, and hardened-runtime library validation is not enabled.

Hardware acceptance is separate from these source and artifact contracts;
see the [public roadmap](../../docs/public/roadmap.md).

Patch 3 increases the private Unix listen backlog from 4 to SOMAXCONN. A real
concurrent-client regression exposed refused connections with the old backlog;
24 simultaneous workers / 48 commands now pass without starting another daemon.
All 834 compiled Mach-O objects now have explicit macOS 14.0 deployment flags,
verified by `scripts/verify-adb-deployment-target.py`. An environment variable
alone had left static Meson dependencies targeting the build host OS.

Patch 3 SHA-256: `7d2d77c20cd20d62b67f48c1c69388beed303afb85efc1bbd7491589a3b1ee9a`.
