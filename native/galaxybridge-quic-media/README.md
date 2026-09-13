# Standalone G1 media/control core

Task6e6 synthetic integration slice. This crate is not registered with the app,
does not launch a phone process, and does not select an installed transport.
Its only dependency is the unchanged sibling `galaxybridge-quic` and that
crate's existing locked graph. No C ABI or production adapter is supplied.

## Owner and public entry points

All state belongs to one `Context { session:[u8;32], generation:u64, scid:u32,
capture_kind:u8, display_id:u32, target_token:u64, enabled:u8 }`. The caller must
bind this exact context to the already authenticated Endpoint used by Driver.
Context is not permission to retarget an Endpoint; G0 has no public session-ID
getter. Requested virtual display uses `display_id=u32::MAX`, not a global
display lookup. Start checks the immutable expected fields before media.

The preferred integration seam is `Owner::new(Context, now:u64) -> Result<Owner,
Failure>` and `Driver::new(Owner, Endpoint, origin:Instant) -> Driver`. Every
numeric `now`, deadline, received-at time and measured margin is **nanoseconds
on that owner's local monotonic origin**; create Owner with the matching origin.
`Driver::now() -> Result<u64,Failure>`, `poll() -> Result<(),Failure>`,
`next_wakeup() -> Duration`, `ready() -> bool`, `transport_stats() -> G0 Stats`,
and `retire(Failure)` operate the exact owned transport. Drop closes it.
`poll_filtered(&mut impl FnMut(&Received)->bool)` is the explicit synthetic
post-authenticated receive-loss seam, not an RF impairment or production filter.

`Owner::ingest_stock(track, bytes, now)` incrementally consumes original stock
bytes; its returned count is the consumed prefix. `stock_eof(track,now)` rejects
an incomplete record. Do not buffer complete uncharged stock AUs outside it.
`queue_start(now)`, `queue_critical(Record,now)` and
`replace_move(Record,received_at,now)` are the bound source entry points.
`queue_access_unit` is a bounded complete-fixture seam. Codec/geometry/epoch
ordering normally derives from `ingest_stock`, not arbitrary raw Core queues.

For a manually serialized adapter, `Owner::next_transport_record(now,
allow_transaction) -> Option<Dispatch>` returns a token, G0 Message and absolute
owner-local deadline. Call G0 send and `transport_admission(token,Admission,now)`
synchronously, with a fresh time after send; do not hold a Dispatch across an
unrelated await. `ingest(Received,now,Option<rtt_plus_4var_ns>)`, `tick(now)` and
`next_wakeup()` must continue while consumer work is pending. Driver services
at most32 records per turn and at most4 reliable admissions; this does not cap
already accepted G0 reliable backlog to four. ACK feedback precedes requests.
Only valid, available measured G0 RTT/variance enables selective repair.
For the first full missing-fragment request, a successfully admitted ordinary
successor AU on the same generation/track/epoch/config proves that the source
has completed the previous AU's initial admission pass. After the existing
5ms reordering grace (also following any new fragment progress), it may repair
that AU's missing tail without waiting an additional quiet RTT. Reliable
recovery, parity, duplicates and rejected records provide no such evidence.
The original deadlines, measured repair margin and two-request cap still apply;
this rule is independent of device model, codec and configured bitrate.

`Core` is the lower-level transaction tracker (`queue_transaction`,
`queue_object`, `queue_watermark`, `ingest_ack`, `next_transaction_result`).
Its public low-level record API is not a substitute for Owner's stock/input
validation. Results are single-assignment `NotDispatched`,
`UnknownRemoteOutcome`, `PeerBoundaryConfirmed(MetadataCommit|StockSinkWrite)`,
or `SupersededBeforeDispatch`. Results retain their charged entry until drained.

Receiver's `next_output(now)` returns an owner-bound `OutputLease`. Keep the
lease and its charged `Bytes` through the actual native callback/queue boundary.
`check_output` is a last software eligibility check; `consumer_commit` means
ordered consumer ownership, not decode/presentation success. `release_output`
releases the core reference, not arbitrary external clones. `Bytes` clones
remain charged until their final drop. A committed AU released after its
residence deadline frees memory but does not send a timely MediaAck.

The byte sink is `receiver.control`: `next_write(now)` gives exactly one
`WriteLease`. Report actual bytes through `receiver.control_write_result(token,
written,now)`, which also queues ControlApplied after a complete on-time write.
The lower-level Writer's `write_result` alone cannot emit the receiver ACK.
Use a fresh post-write time. Partial commands cannot interleave. A full late write is
`CompletedWriteAfterCutoff`, never 'not executed'. `cancellation()` consumes
one exact-owner potentially pressed pointer/key/UHID list; it is not confirmed
Android release. Geometry replacement requires consuming the prior cancellation
before admitting new input. Any consumer/sink error must retire Driver; do not
continue after a failing lower-level callback. No callback may target a new
Owner, and no accepted command is replayed into its successor.

## Wire, limits and time meaning

GQM1 is a strict64-byte BE header plus at most960 bytes, kinds1..14; `wire.rs`
defines exact fields and exceptions. Only AU/MOVE use DATAGRAM; other records
use G0 stream0 framing. MetadataApplied14 and ControlApplied10 are application
ACKs, not transport ACKs. No string payload diagnostics or new stock command.

| Bound | Maximum / outcome |
| --- | --- |
| Video AU / AAC or configuration | 4MiB /64KiB; reject before retained allocation |
| Sender original AU ownership |16 aggregate entries / one16MiB byte cap; matching real ACK or original expiry releases each entry |
| Receiver AU ownership |8 entries/16MiB including external references; unchanged by sender residency allowance |
| Receiver payload-only native AU copies | Separate8 copy slots; originals/composite copies retain their8-slot limit; ALL share the same16MiB aggregate byte ceiling |
| Incremental stock input | One additional incomplete record; no parallel-track partial read |
| Configurations | Two versions per track,256KiB aggregate shared across owner directions |
| Metadata transactions/results |16 entries; exhausted ordered transitions fail visibly |
| Critical entries/results |64/64KiB,16 release/cancel reservations inside64 |
| MOVE |16 entries/16KiB; active pointer cap16; newest pending input replaces only unsent MOVE |
| Feedback |64/16KiB,16 ACK slots/2KiB reserved inside the total |
| Staging / output |32 records/32KiB per bounded dispatch turn; one sink write lease |
| Active input identities |16 pointers,64 keys,64 UHID; pending creates reserve ownership before write |
| Ordinary source AU / receiver VIDEO / receiver AUDIO / MOVE |120ms / maximum120ms / maximum60ms /40ms original local residence |
| Codec-qualified independent video | Source250ms; provisional matching key header receiver200ms, min inherited source remainder; original observation anchors, no repair renewal |
| Receiver watermark history |32 unresolved upper-bound/original-time ranges pertrack; exact overflow is terminalCapacity, no lossy age coalescing |
| Repairs / reorder / recovery | At most2 accepted repairs per fragment;5ms grace,10ms separation;first gap+250ms |
| Metadata/Critical |500ms original source queue-to-valid-ACK ingestion deadline |

Equality expires. Checked clock arithmetic and backward time reject/retire;
duplicate/retry/partial write/lease migration never renews original deadlines.
Payload-only copy reservations charge exact copied payload bytes before
allocation and retain the original AU/configuration storage through final
ticket release. A copied configuration pins its real version, not a fictitious
additional version. The two-real-version limit and old composite-copy semantics
are unchanged. Releasing a committed output event may acknowledge the original
AU while a separate native copy ticket still pins and charges its storage.
Metadata age is rounded upward in microseconds before G0 admission. Peer time
means first G1 observation plus remaining advertised budget, not synchronized
source time. G0 ignores reliable-message deadlines and Accepted is not delivery.
After any Accepted without timely valid ACK, timeout means UnknownRemoteOutcome.
Closing G0 cannot recall accepted bytes or cancel an external write already
started. The test suite includes a delayed Critical acting after source timeout
but before peer retirement: no original-source remote non-effect guarantee.

## Declared codec policy

Closed policy: H.264 supported SPS/PPS associations, I/P slices, progressive
8-bit4:2:0 forms and qualified IDR; HEVC supported VPS/SPS/PPS associations,
layer0/temporal-id1, VCL0/1 and IDR19/20, no reordered B/CRA/BLA/RASL/dependent
slice policy. Unsupported parameter flags/profiles/layouts fail explicitly.
Every VCL header must match the picture and parameter identity, with first
address0 and strictly increasing later addresses. This is bounded required
header validation, not an entropy decoder. Actual VT callbacks separately prove
the synthetic streams decode. Header-only/two-byte HEVC NAL is Unsupported.
The parser caps NAL count4096 and bit reads8192 per bit-reader.

AAC is exactly AAC-LC48kHz stereo1024-sample ASC1190; no SBR/PS/960-frame mode.
Compressed AAC bytes are never replaced with PCM or a default configuration.
PTS must increase strictly within an epoch; discontinuity retires instead of
rebasing. Video resumes only with complete matching config and qualified IDR;
configuration is republished before the recovery IDR. Descendants of a lost
reference do not reach the consumer. Numeric skipped-video range accounting
does not erase raw loss. Failure to recover by250ms retires the entire owner.

## Reproducible prepared host fixtures

From the project root, with installed Rust 1.92+, CMake and libclang:

```sh
bash scripts/test-quic-media-contract.sh
bash scripts/test-macos-quic-media-consumers.sh
GB_QUIC_NATIVE_FILTER=PrimaryMediaDiagnosticsTests/clockHookIsActualAndDecisionsUnchanged bash scripts/test-macos-quic-media-consumers.sh
bash scripts/test-macos-media-playout-clock.sh
```

Cargo uses the locked dependency graph with two jobs; set `GB_OFFLINE=1`
to prohibit dependency downloads. `GB_BUILD_DIR` selects the cache; standard
`CARGO`, `RUSTC`, `RUSTDOC`, `CMAKE` and `LIBCLANG_PATH` select tools.
The wrapper generates its synthetic codec fixtures using the source factory;
`GB_QUIC_TEST_FIXTURES` may select a retained generated directory with SHA
manifests. Native tests synthesize deterministic64x64 NV12 markers, real VT
H264/HEVC, and low-amplitude440Hz PCM encoded to real AAC; no screen/microphone.
The actual AAC positive oracle is nonempty conversion through the unchanged
player's original diagnostic trace, not a direct clock-oracle call. Existing
diagnostics on/off unit parity is separate from actual AAC conversion evidence.

The private binary takes only `--stdio-fixture [none|drop-once|whole-once|hole]`.
It creates its own ephemeral authenticated loopback pair. Ready65 waits for
actual valid RTT observations **before stock admission**, within its original
10s hard lifetime; this is fixture preconditioning, not a production first-frame
recovery fix. No credentials enter argv, logs or persistent storage.

Private input:8-byte header `(kind:u8,track:u8,zero:u16,length:u32BE)`, then body.
1=stock(track1/2,1..32768 bytes),2=commit/3=release/5=check(track0,8-byte token),
4=done(track0,empty). Total input64MiB; one partial header/body; EOF retires.
Output:40-byte header `(kind,track,flags:u16,length:u32,token:u64,epoch:u32,
configuration:u32,sequence:u64,PTS:u64)`, then at most4MiB body.2/3/4/5/12 are
stock-compatible events;64=input ACK,65=ready,66=done,67=numeric disposition.
Terminal67/track3 has failure code1..9 in flags, skipped-video count in sequence;
epoch is transport reason only for G1 Retired:0 none,1 Closed,2 Authentication,
3 Protocol,4 ConnectTimeout,5 PeerIdle,6 ReliableStall,7 Io. Other fields zero.
G1 failures do not attribute their cleanup-induced G0 Closed as an input cause.

Swift validates headers and reserves quota before body allocation; leases retain
final-reference tickets. Children are direct argv/exact PID owners, no shell.
Parent closes stdin, waits2s, then kills only its unreaped child and bounds reap
to another1s; per-I/O8s, whole native fixture process60s watchdog. Partial framed
output failure ends EOF rather than injecting a header into an unfinished body.
The child10s watchdog branch is not dynamically proven by the stalled-input case:
unchanged G0 PeerIdle wins at about5s. Forced stopped-child cleanup is separate.

## Gates explicitly left open

Independent source review, real producer recovery/first-frame margin, Android
input/cancellation, native already-queued audio retirement, original-source
cross-host freshness, actual Metal presentation/visible latency, physical loss,
strict rate/performance, sound audibility/exact PCM, and audio recording remain
open. Host MOV readback proves video decodability/marker/PTS gaps only. This core
does not change quality, codecs, capture dimensions, CC, device power, bulk
routing or product defaults, and cannot claim the failed G0 rate legs fixed.
