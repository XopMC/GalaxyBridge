# Internal scrcpy producer-sync derivative

This separately pinned server is **4.1-gb-sync.1**, based on upstream scrcpy
v4.1 commit2926c06c5dc3064ae6d8db706f1a98a37cfcf3f0. It is not the stock
artifact. The opt-in Internal QUIC launcher selects its exact SHA; the stock
USB/TCP artifact and pin remain unchanged. This is not a release approval.

Build from the pinned upstream source archive (downloaded and SHA-256 verified on
first use), using JDK 21 and Android SDK platform 37.0 / build tools 37.0.0:

```sh
export JAVA_HOME=$(/usr/libexec/java_home -v 21)
export ANDROID_SDK_ROOT="$HOME/Library/Android/sdk"
bash scripts/build-scrcpy-gb-sync.sh
bash scripts/test-scrcpy-gb-sync.sh /absolute/path/printed/as/SOURCE_BUILD_DIR
```

`GB_BUILD_DIR` selects the source/cache directory and `GB_OUTPUT_DIR` selects
artifact output. The build emits both stock `scrcpy-server-v4.1` and enhanced
`scrcpy-server-4.1-gb-sync.1` from the same source commit, retaining compiled
classes for the JVM tests. `GB_SYNC_ARCHIVE` supplies an offline archive;
`GB_OFFLINE=1` forbids downloads. `GB_ANDROID_PLATFORM` and
`GB_ANDROID_BUILD_TOOLS` override installed SDK components. The build records
actual compiler and SDK inputs in `BUILD-INPUTS.txt`; `SHA256SUMS` records the
new artifacts. Historical toolchain hashes in `UPSTREAM.lock` describe the
original reference build and are not required to reproduce source behavior
with an installed JDK. Artifact hashes can differ across toolchains and must
be bound to the resulting app bundle by the release orchestrator.

The derivative also contains `ClipboardAgent`, a capture-free helper launched
by the Mac app through the already-authorized ADB shell. It polls Android's
current primary clip without installing an input method or requiring the
Android Helper to remain in the foreground. It sends bounded UTF-8 text or PNG
frames over a private ADB-forwarded abstract socket. The stream starts with
`GBC2`; each frame carries a byte kind (`1` text, `3` PNG), a big-endian
64-bit Android copy timestamp, a 16-bit origin length (at most 256 UTF-8 bytes),
a 32-bit content length (at most 4 MiB), then origin and content bytes. The Mac
reader also accepts legacy `GBC1`. Text commands use the GBC2 frame with timestamp
zero and an origin ID. Sensitive clips are ignored. Clipboard images use a shell
resolver that acquires and releases external provider leases, including the
unstable-provider path required by `openInputStream`.
Injection origins are accepted only with a matching payload digest and
platform-owned writer attribution to the shell or Helper. Other apps and
unavailable attribution produce a fresh occurrence, including a first-observed
copy that retained old extras. Android still controls the initial Wireless
debugging enablement and pairing.

Each poll still reads the current clip metadata and item. A one-entry cache
reuses the bounded decoded payload and hash only while a positive Android clip
timestamp and item identity remain unchanged. Copying again or changing the
URI/text triggers a fresh read. Unknown timestamps are read again on each poll. Failed reads retry after two
seconds, or immediately when the copy timestamp or item changes. Sensitive or
empty clips clear the cache; no previous payload is returned for them. A second metadata check after expensive
image processing prevents a superseded image from being sent over newer text.

Private control type23 is exactly33 bytes: u8 opcode, then four big-endian
positive signed64 integers: producerEpoch, producerConfigOrdinal, requestId,
androidDeadlineNs. The full derivative version must match. Required video,
control, stream metadata and frame metadata cannot be disabled. No new ACK,
socket, permission, key, or authenticated remote transport is added.

The exact encoder owns a single-slot mailbox. Each well-formed new request ID
is consumed even if rejected as stale/busy or with no legal rate slot before
its deadline. A valid request arriving during the 100ms cooldown retains the
single mailbox slot until the first eligible video-thread service; that service
does not wait/block or renew the deadline, and can service pending bitrate work.
The video thread alone
checks the fresh elapsedRealtimeNanos deadline and calls request-sync with
integer0. Strict local expiry, maximum100ms admission horizon, minimum100ms
between actual calls, epoch/config ownership and publication guards do not
establish a hard vendor-call execution bound. An API return is not IDR proof.

Patch 0002 fixes lost recovery requests observed at 46/69ms after an earlier
sync call. It changes mailbox scheduling, not the 100ms call-rate limit, media
TTL, bitrate profile or any device-model selection. RecoveryRateWindowTest
executes the real CaptureControl with injected clock/codec operations; it
covers cooldown boundaries, original expiry, ownership changes and rate-work
progress. Hardware flow/presentation still require separate evidence.

Epochs count session metadata publications; config ordinals count every config
packet, including identical duplicates. Config0 cannot accept a request.
Matching newly publishing config may enqueue but cannot apply until the write
completes. Partial publication is terminal; reset winning a write never revives
the old owner. Request-specific runtime errors disable the extension for that
epoch without invoking stock retry/downsize.

The tests execute actual production state/core/parser classes with nested
platform-operation seams. They do not execute Android Looper/codec/Bundle/Os
semantics. Start/termination wrapper, real clock equivalence, codec/capture
behavior, actual H.264/H.265 recovery, cross-host deadline mapping, future G1
tuple validation/raw-type23 smuggling prevention and presentation are separate
root-owned adapter/device gates. This is not a recovery or performance pass.
