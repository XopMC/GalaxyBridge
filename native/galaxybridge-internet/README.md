# Internet runtime boundary

This optional runtime is separate from screen/media/QUIC transports. Sources are
pinned by commit and SHA-256 in `upstream.lock.json`; tarballs, working copies,
compiler outputs and proof manifests stay under repository `out/`.

Build with `python3 scripts/build-internet-runtime.py --platform all`.
The Android build defaults to NDK 29.0.14206865 and arm64-v8a/x86_64; pass an
explicit NDK path with `--ndk`. No installer, adb command or host route is run.

Outputs:

- `out/internet-runtime/artifacts/macos/libgalaxybridge_internet.a` includes the
  Hev tunnel, lwIP, task system, YAML and the small adapter/flow selector.
- `out/internet-runtime/artifacts/android/<ABI>/libgalaxybridge_internet.so`
  includes the Hev server and the JNI network-binding adapter.
- `THIRD_PARTY_NOTICES.txt` must accompany distributed artifacts. The two Hev
  projects are MIT; dependency notices, including lwIP's BSD terms, are retained.

## Mac application API

`include/galaxybridge_internet.h` / module `CInternetRuntime` is the public C ABI.
The helper-provided utun descriptor remains owned by its unprivileged caller.
Call `gb_internet_tunnel_prepare()` synchronously before publishing its worker.
The reservation latches `stop()` even before `gb_internet_tunnel_run()` starts;
that blocking call retires the reservation on every return, including invalid
input and cancellation. STOP while idle never affects a later reservation.
Two narrow upstream hooks mark the interval after initialization and before
cleanup: cancellation before that interval skips the run loop; cancellation
inside it wakes the upstream loop. No quit is sent after upstream cleanup.
The supplied descriptor avoids every upstream interface/route setup path.
`bash scripts/test-internet-tunnel-lifecycle.sh` tests these scheduling boundaries
against the actual adapter with a fake upstream and no utun/network operations.

The per-session upstream hook selects one of two **loopback** SOCKS ports.
Each flow saves its chosen gateway and port atomically. Changing health, policy
or port never reassigns an already admitted flow. A failed gateway can break its
old flows; there is no single-flow bonding or transparent external-IP migration.
`set_gateways_checked()` additionally refuses peer-slot reuse while old flows
remain. Counters and tables are process-local and bounded at 4096 sessions. Monotonic
per-slot started-flow counters increment only on a newly admitted native tunnel
flow, not on policy changes or a local SOCKS probe. They reset at global pool
retirement; a default-network HTTPS probe must be correlated with these counters
and route/VPN checks before claiming system routing worked.

Both local adapters use the same private, 64-character lowercase-hex RFC1929
credentials. Phone credentials stay on Android. The Mac adapter verifies local
credentials, then conducts a no-auth SOCKS greeting **inside the already pinned,
authenticated paired TLS channel**. Only loopback accepts SOCKS connections.

## DNS

The separate unprivileged `PairedDNSRelay` accepts UDP and TCP on one loopback
port, caps active queries at 32 and applies an absolute eight-second deadline
across retry. Each complete DNS query uses a fresh authenticated `dns-wire-v1`
TLS channel with a u16 network-order frame length. Android `DnsResolver.rawQuery`
uses the selected Network and its Private DNS behavior. All DNS record types are
preserved; there is no A-only fake-IP mapper or public-resolver fallback.
Replies must match the transaction ID, QR flag and exact bounded frame. Loss of a
peer only cancels that peer's active queries; automatic/balanced policy can retry
once on another healthy peer within the original deadline.

## Android JNI API

Class: `com.xopmc.galaxybridge.internet.NativeInternetGateway`.

- `start(String config, long networkHandle): long`: one generation ID or zero.
- `stop(long id): int`: zero, ENOENT for a retired generation, or ETIMEDOUT while
  the same worker still owns resources. Preserve that ID on timeout.
- `updateNetwork(long id, long networkHandle): int`: changes new socket/DNS
  admissions only. A zero network fails closed; it never chooses Android's
  process-default network.
- `localPort(long id): int`: readiness comes from the actual upstream listener
  after bind/listen, not from probing a potentially unrelated occupied port.

Input is a strict mini-format, not arbitrary YAML or a path:

```
port: 12345
username: <64 lowercase hex characters>
password: <64 lowercase hex characters>
```

The adapter generates its own loopback-only authenticated server configuration.
Outgoing TCP and UDP sockets call `android_setsocknetwork` before use;
`getaddrinfo` calls `android_getaddrinfofornetwork`. Existing bound sockets retain
their network. The selected Network must remain held by the Java owner. Network
loss must stop the owner before replacement; late generation calls cannot stop
its successor. Startup reaps an already exited retained worker before restart.

Hev UDP-over-TCP is SOCKS command **5**, not 0xf3. The matched tunnel/server
versions implement this extension together. Standard public SOCKS clients are
not promised to understand it.

## Evidence limits

Host Clang compilation, NDK builds and policy/ownership tests are separate from
real networking acceptance. No privileged utun allocation, route/DNS mutation,
helper installation, phone execution, throughput or VPN compatibility was tested
by the implementation agent. Full TCP/UDP/DNS/IPv4/IPv6, network fallback,
concurrent gateway and prolonged-load acceptance remain mandatory.
