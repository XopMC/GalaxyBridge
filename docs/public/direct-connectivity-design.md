# Direct connectivity and internet sharing — 0.1.2

Approved implementation contract:

- Keep USB/LAN and existing media/QUIC architecture. BLE discovers/authenticates peers; Android Wi-Fi Direct Group Owner accepts the Mac as a legacy Wi-Fi client. Local-only hotspot is a compatibility fallback.
- Preserve the phone's existing Wi-Fi when concurrency supports it. No automatic disruptive radio change on an unverified model. One Mac radio uses one shared group for two wireless phones.
- Reuse saved identities and TLS pins. Offline QR uses a short-lived secret; authenticated encrypted BLE bootstrap carries network credentials. Never trust names, addresses or SSIDs as identity.
- Direct connectivity and internet sharing work independently of shell access. An ADB-activated bounded shell bridge supplies advanced operations until reboot; regular Helper capabilities remain available without it.
- Shell activation uses a one-use, short-lived DUMP-authorized ticket. A shell-UID ContentProvider call transfers a Binder factory; every factory operation checks the fixed Helper UID and activation generation before adopting a Helper-created unnamed socketpair endpoint. The Helper owns the socket on which it sets timeouts, and transferred sender copies close without shutdown. This avoids a cross-domain abstract-socket connection without changing Android security policy. Owner FD EOF and Binder death retire the broker's exact children.
- Internet sharing is opt-in. A Mac utun and embedded tun2socks connect to an authenticated Android gateway. Prefer phone Wi-Fi, automatically fall back to cellular. No public unauthenticated proxy, unsafe ADB TCP port, kernel extension or SIP change.
- Two peers have isolated sessions and gateways. A single Mac tunnel supports fixed gateway, automatic selection and new-flow balancing; existing flows retain their gateway and can fail when its external IP disappears. No single-flow bandwidth aggregation claim.
- Root network helper only manages owned tunnel/route/DNS leases; data processing stays unprivileged. Optional helper installer belongs in the DMG. Validate caller identity and recover owned state after failure.
- Independent launchd test guardian, restoration journal, fixed deadlines and DNS/HTTPS/VPN checks precede network mutation. First risky trials last at most 30 seconds, with forced rollback after 60 seconds. No sole-uplink switch without validated independent reserve.
- Protocol additions negotiate capabilities and retain major version 1. Keep eleven system-language catalogs and English fallback. Versions: 0.1.2, Android versionCode 3, Mac build 3.
- Acceptance: real two-phone USB/USB, USB/direct and shared direct group; text/PNG, files, notifications, windows, screen privacy, TCP/UDP/DNS/IPv4/IPv6, automatic upstream fallback, gateway failure, 30 reconnect cycles and a one-hour dual-phone load run under verified reserve. Report unsupported/unverified cases honestly.

Implementation status and private runtime evidence stay outside public source documentation until verified.
