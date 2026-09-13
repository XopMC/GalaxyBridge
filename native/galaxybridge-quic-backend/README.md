# Paired QUIC backend (not installed)

This crate is the polling application owner over two unchanged authenticated G0
endpoints: media/small Critical and isolated bulk. It owns one G1 Owner, one
stock source/writer, and one joint retirement/child lifetime. USB, application
routing, Swift consumers and the Android producer are not modified.

## Integration entrypoints

`Backend::spawn_host(HostConfig { binding, peer_ip }, OwnedCommand { program,
args }) -> Result<Backend, Error>` acquires an owner slot before creating TLS
identities or its exact child. The caller supplies a trusted, nonsensitive direct
argv, not a shell string. An external ADB caller must already have selected and
verified its own private binary-safe shell-v2 peer command; discovery, pairing,
staging, device permissions and remote process attestation are not provided.
Private GBP3 Request/Reply and ephemeral identities remain in pipes/memory.
`Binding` contains nonce, selected sidecar SHA and G1 immutable context. Its
session is filled from the actual media G0 session; display0 is legal.

Poll `Backend::poll()`, process `next_event()`, and wait at most `next_wakeup()`.
`now_ns()` is this owner's local monotonic origin, not a wall clock, Android
BOOTTIME or another owner's timeline. Pass original locally captured receipt
time into `queue_bulk(bytes, received)` or `queue_critical(record, received)`.
`replace_move(record, received)` retains G1's original MOVE admission semantics.
`ready()` requires both independent G0 application-ready gates, original stock
setup, remote G1 Start and confirmation of this owner's own Start. Stock bytes
are not read before this gate. This is not a first-frame latency guarantee.

`Event::Media { handle }`: check immediately before consumer work with
`check_media`, reserve any explicit extra copy with `reserve_copy` **before**
allocating it, then `commit_media` on the actual accepted consumer boundary.
Commit changes eligibility; do not check it again as if it were unconsumed.
Keep the original immutable pointer/lease until the consumer's actual final
reference is gone, then `release_event`. Release of uncommitted live media
fails closed and retires the owner; release is not an invented consume ACK.
`Event::Device`: read original complete stock bytes with `device`, preserve
ordinal order, call `consume_device` once, then release its storage handle.
Critical/Bulk completion means the specified stock boundary, not guaranteed
Android semantic execution or remotely recalled bytes. Retired immutable storage
remains valid until its final release but cannot regain eligibility.

Call `retire(reason)` once, continue `cleanup()` until `complete`, and only then
destroy. Closing parent stdin is the peer lifetime signal. Exact-child cleanup
starts once, attempts kill after1.5s and reaps within the original2s ceiling;
incomplete/failed cleanup is not success. An abandoned Drop kills and retains
an unreaped exact child plus its owner slot in a fixed16-entry escrow. Service
`process::poll_abandoned_cleanup()` to finish nonblocking reaping; no background
reaper or PID-based process discovery is used.

## C ABI1

Include `include/galaxybridge_quic_backend.h` or its module map and link the
matching Mac static library plus system dependencies. Every struct header is
`{1, sizeof(struct), {0,0}}`; all reserved fields must be zero. Readable buffers,
alignment and valid pointer lifetime are caller obligations. Length validation
does not prove arbitrary pointer safety. One owner thread calls all operations;
only event/copy releases are permitted on foreign destructor threads. No callback
or reentrant consumer call occurs under the registry lock.

`gb_backend_create`, `poll`, `now_ns`, `next_wakeup_ns`, `submit`, `next_event`,
`media_check`, `media_commit`, `device_commit`, `copy_reserve`, `event_release`,
`copy_release`, `retire`, `destroy` are executable operations, not model stubs.
The header defines exact layouts, status values and event/input kind meanings.
Use caller generation/target in GQM1 input; stale/wrong owner, ABI, generation,
thread and double releases fail closed. Handle IDs never wrap or get reused.
Destroy does not invalidate retained foreign storage; that old slot is freed
only after final storage release. The later Swift integration must propagate
that final-reference callback; it is not already provided by this C library.

## Fixed bounds and outcomes

-16 owners/process, including destroyed owners with retained event/copy storage;
 the17th fails before child/endpoint/native allocation. No eviction.
-128 public event/copy/result reservations per owner:96 ordinary,16 additional
 validated UP/CANCEL/key-up/UHID-destroy or original stock-ACK progress,16
 terminal/completion. This reduces ordinary capacity from112 to96; it does not
 increase the ceiling. All tighter G1/payload limits still apply. Completion
 transfers its pre-admission promise into a result rather than double charging.
- Bulk≤262144B, two retained objects/512KiB per direction, including parser,
 reassembly and foreign storage. No extra whole-object copy pool. Lazy one-record
 fragmentation uses976B bodies; the bounded implementation remains below the
32-record/32KiB staging ceiling. Completion metadata≤16/2KiB. Small reverse
 payload pool16×976B and original stock-ACK pool16×9B cannot consume bulk storage.
- Bulk admission→on-time Applied500ms; equality expires. Wire age is ceil ns/1000
 and must be<500000, including final dispatch's last999ns rounding boundary.
 Before any Accepted fragment: NotDispatched. After Accepted without on-time
 matching ACK: UnknownRemoteOutcome. Accepted fragments are never replayed.
- Small reverse parse/staging/admission500ms locally, no cross-host age claim.
 Physical SET_CLIPBOARD/type9 and reverse clipboard/type0 use bulk even at one
 character. BulkApplied releases the source fence but does not settle paste.
 The original physical-operation stock-ACK watchdog is2000ms, never refreshed
 by Applied or wrong ACK. Missing ACK retires with ClipboardAckMissing/unknown
 paste outcome. Existing240ms post-ACK Swift settlement remains a later gate.
- Original5s bootstrap,5s pair-connect,5s stock-setup ceilings. Partial progress
 never restarts them. Earlier G0 retirement may legitimately win.
- G1's actual AU/configuration pools charge original storage and explicit
 foreign copies until final release; no codec/GPU memory guarantee is inferred.

## G1 opt-in seams

`queue_critical_received(record, received, now)` uses fresh service time but the
checked original receipt+500ms deadline. Existing `queue_critical(record, now)`
is unchanged as receipt=now. `DispatchPolicy` gates pre-dispatch feedback,
metadata, Critical-through sequence, MOVE and media without hiding a Dispatch.
`ingest_stock_observed` publishes complete source identities and original start.

The backend opts into `ingest_stock_observed_deferred(track, bytes, now)` and
`deferred_stock_track()`. Only complete VideoSession/Configuration awaiting an
existing watermark ACK may be retained. This moves the Reader's allocation,
charges its actual capacity to the shared metadata pool, and consumes only that
record's prefix. Resumption returns zero consumed successor bytes and publishes
the original event; callers must retry the untouched successor. A fixed one-event
slot is not an AU queue. Its original first-byte+120ms cutoff remains in tick and
next-wakeup, without restarting existing watermark/ACK deadlines. Other-track
ordinary AUs and control/ACK service continue; a second simultaneously deferred
metadata event fails the fixed capacity rather than allocating another queue.
The old stock wrappers do not silently acquire this opt-in behavior.

## Android and QA modes

### c native-copy and device/display handoff

`gb_backend_payload_copy_reserve` charges only the actual payload being copied,
pins its real configuration version, and is released only at the final native
actual compressed-input/encoded-observer Data reference. Decoded pixels and
scheduled PCM own their separate native output storage, not compressed input.
AU pointers remain borrowed only through the
original event: finish synchronous copying, fresh eligibility check and commit
BEFORE event release. A payload-only AU ticket does not extend that pointer's
lifetime; it charges the independently owned allocation. Metadata payload
tickets continue pinning original metadata storage. New AU payload
copies have a separate hard8 in-transfer allowance, not eight more network AU slots.
`gb_backend_native_copy_commit(owner,event,copy)` prevalidates the exact AU
payload ticket, fresh uncommitted lease and a separate hard64 storage-ticket
ceiling, then performs the existing commit and moves that same ticket from
transfer to storage. It allocates/copies nothing and renews no deadline. The
destination must already hold bounded independently copied native ownership;
Swift queues VT/AAC only after this call succeeds. Capacity rejection leaves
the lease uncommitted and the ticket charged, with no delivered ACK. Duplicate,
foreign, retired, metadata/composite and legacy-already-committed uses reject.
Original/composite AU admission remains8 slots. All original/composite/new-copy
bytes share the SAME16MiB ceiling. Metadata payload copies use the existing
metadata slot/byte ceiling. A configuration payload copy pins the original real
version without creating a fictitious second version. The old composite copy
API keeps its original allocation/version semantics. Neither cap nor retention
is waived on retirement or a consume return.
After successful owned AU copy admission and `native_copy_commit` (unchanged
`media_commit` for metadata), the Swift bridge
releases the borrowed event immediately. Final original ownership then destroys
the original AU allocation and releases its charge. The separate copy ticket
keeps the actual copied bytes and configuration charged until the final native
reference, without redundantly pinning original AU storage. This permits
the existing `release_output` AU ACK without treating playout as a required
borrow lifetime or releasing the actual backing charge early.

`gb_backend_device_eligibility` is a read-only owner-thread view before commit:
original reverse cutoff, matching original clipboard-watch cutoff (zero if no
match), and their minimum. At equality expiry applies;112 clipboard-watch
classification wins even if both have expired. Committing before a MainActor
hop requires an exact-owner bounded downstream gate retaining storage and
enforcing these same cutoffs until synchronous callback admission/completion.
It must retire while the actor is held; commit is not a keyboard effect.

Event kind7 carries exact-owned producer display scalars; see the C header's
explicit fields. The private authenticated reliable48B GDS1 frame binds original
generation/scid/target/capture context, validates direction and permits at most
assignment, optional conflict, and end. Raw stdout is discarded. Exact process
EOF/exit/cancel/read failure clears assignment, not a parsed text marker.
Optional closed `--launch-policy primary|application|virtual-desktop` and
positive-u16 `--density` preserve existing caller defaults when omitted; c
supplies existing app/primary launch options and INFO assignment visibility.

QA-only `gb_backend_qa_pools` returns eight scalars: original/composite receiver
AU slots and aggregate bytes, metadata slots/bytes, held new AU copy slots/bytes,
held metadata copy slots/bytes. It does not change admission or export content.
`gb_backend_qa_transfer_usage` returns two additional independent scalars:
in-transfer AU credit and transferred AU storage tickets. `qa_pools` counts
both ticket states and all actual copy bytes; transfer never reports storage
freed. Final release from any thread drops the exact state/byte/config charge.

Production Android CLI (all values/paths are nonsensitive):

```
gb-quic-backend --stdio-peer --producer /data/local/tmp/gb-sync-approved.jar \
  --video-codec h264 --max-size 1920 --max-fps 60 \
  --video-bit-rate 20000000 --audio-bit-rate 128000
```

Use h265 for HEVC; optional `--new-display WxH` must match new-display context.
The peer verifies the distinct selected4.1-gb-sync.1 artifact SHA
`a0d98e35500828263534ddf054bd84a78d22592a505cfec18e8dde01b7516046`, launches
only after both authentications, and connects enabled video→audio→control through
`scrcpy_%08x`. Peer credential checks bind stock sockets to the owned child.
Actual Java clock/API return/causal IDR remains a later hardware observer gate.
Current published producer tuple maps typed recovery to exact33-byte type23.
Android CLOCK_BOOTTIME is validated positive signed64 ns. The ordinary command
cutoff is admission+100ms. A preceding bitrate command may reserve one enclosing
admission+250ms operation; at selection the sync wire cutoff is finalized as
min(original operation cutoff, selection+100ms), matching CaptureControl's100ms
gate. That immutable cutoff is rechecked before every write, never renewed after
partial output or substituted by Rust Instant. Producer command IDs come from
one monotonic owner counter shared by local and receiver-driven recovery; their
origin IDs remain separate for correlation. Capture publication/clear does not
reset the producer counter or reuse a consumed command ID.

Only explicit `--features qa` artifacts expose:

```
gb-quic-backend --stdio-fixture --fixture /explicit/prevalidated.gbf \
  --sha256 HEX64 --duration-ms 30000
```

Fixture input is a≤16MiB validated allocation including its fixed768-entry index
(QA/test-only; production has no prepared-fixture parser or expanded pool):
GBF1, enabled u8/reserved3, count u32BE; each entry due-ns u64BE, track u8/reserved3,
length u32BE, original complete stock bytes. Due times are ordered and<30s.
The fixture has no stock65B connection preamble. Load/hash/codec validation happens
before selection; no file/ADB media reads during score. Host QA configuration
`qa_component(duration_ms1..30000, mode0clean/1fragment/2wholeAU, sequence,index)`
and matching `gb_backend_qa_component` must happen before poll; its whole deadline
starts at owner creation, not readiness. `gb_backend_qa_dropped` counts deliberate
post-auth drops separately. Both fixture roles wait only for an existing valid
observation, never a favourable RTT. Immediate unmeasured repair remains a negative
startup case. No production first-frame deadline or latency target is changed.

## Offline verification/build

### h media-only decline, health and native outcome

Current validated AU admission has four outcomes: admitted, declined pressure,
declined original expiry, or skipped dependent video. These do not reinterpret
arbitrary Capacity/Protocol/Deadline failures. Original reassembly stays8 slots /
16MiB. A present incomplete or complete next AU already owns its reservation;
the missing-placeholder capacity check cannot discard that existing AU.

Native AU callers use `gb_backend_media_admission_check`,
`gb_backend_media_copy_reserve`, native destination allocation, and
`gb_backend_native_copy_commit` before publishing asynchronous consumer work.
Status119 is checked media pressure,120 original AU expiry,121 dependent skip.
On checked pressure call `gb_backend_media_decline(owner,event,1)`; reason2 is
valid only at/after that original AU cutoff. Release the event exactly once in
all cases. Decline does not commit or enqueue a kind7 delivered ACK. Expired
uncommitted AU identity remains releasable; committed, foreign, duplicate or
metadata decline is strict. A failed per-AU allocation unwinds only unpublished
work; it does not retire the whole native attempt. Ordinary APIs/statuses remain
strict. No copy/original/native capacity or deadline is enlarged.

The g atomic commit+transfer operation still prevalidates freshness and the
8 transfer /64 retained storage /shared16MiB budget under the same owner state.
Successful transfer keeps independently owned compressed bytes and real pinned
configuration charged through the final native/encoded-observer reference.
Decoded pixels and scheduled PCM have separate owned output lifetimes. A later
admitted input loss preserves the already-issued ACK; it is not retroactive
decline. Successful decode followed by output pressure does not break decoder
dependency state or request another keyframe.

`gb_backend_media_native_status` takes the immutable full media identity plus
coalesced admitted-input high-water/count and output high-water/pressure/count.
Only the owning thread calls it. Old publication/output observations cannot clear
newer state; foreign/future identities remain strict. `gb_backend_media_health`
returns a fixed value without allocating an event/handle: state0 Waiting,1 Live,
2 Recovering,3 Degraded,4 Disabled; reason0 None,1 OriginalPressure,2 CopyPressure,
3 NativePressure,4 ExpiredOrMissing,5 RecoveryExhausted; output_pressure6 decoded
output or7 PCM. Counts distinguish receiver declined ranges, dependent skipped
ranges, admitted native input losses and post-decode output losses. Receiver
ranges can include source/network missing records; they are not source-drop
attribution. Native admission Live is not proof of display/presentation.

One video episode publishes at most three requests with absolute windows anchored
at first actual owner queue publication: initial cutoff250ms, second[500,750)ms,
third[1500,1750)ms. Missed windows are skipped; one local pending request only.
After1750ms the track stays Degraded without recovery wakeup/request looping.
Actual fresh independent native admission or genuinely new committed source
publication supersedes it; same-version configuration republish does not.
`gb_backend_media_retry(owner,expected_episode)` is explicit and accepts only the
current exhausted episode once. No automatic caller retry is added. Android's
receipt-local100ms remains distinct; reliable Accepted bytes cannot be recalled,
and these windows do not promise cross-host cancellation or encoded-IDR latency.

The Swift caller coalesces payload-free native status on the existing owner
service. Its opt-in scrcpy logger emits fixed numeric `GBQH1` snapshots at most
once per enabled track per250ms plus one final flush. No per-packet logger or
timer is added, and actual health propagation is not throttled. QA terminal
`qa-host-policy` / `qa-owned-source-policy` tuples are bounded32-number snapshots;
missing/truncated output is unknown, never zero. They are absent from production.

With the explicit first-error diagnostics flag, a module7 `PeerIdle` rejection
uses its existing five scalar fields for close-presence bits (local1, peer2,
quiche timed-out4), local QUIC error code, peer QUIC error code, accepted RX UDP
packet count, and sent UDP packet count. A missing close code is not the same
as an explicitly present `NO_ERROR=0`. The site remains the one-based endpoint
role. `ReliableStall` keeps its existing kind/track/role/size/backlog fields;
normal shutdown and diagnostics-off behavior are unchanged. This is local
diagnostic evidence, not media protocol data or a timeout-policy change.

### Fix1 boundary contracts

Matching stock ACK consumption checks fresh owner-local time against the
original physical-operation receipt + 2000ms. Equality or later returns
ClipboardAckMissing, jointly retires, and cannot clear/revive the watchdog.
The event's separate 500ms residence budget is not a renewed clipboard budget.

GbEvent exports original GQM1 sequence/flags and OutputLease.owner plus the
complete immutable G1 Context. Metadata sequence is its next-AU boundary;
reverse ordinal remains separate. next_event/media_check agree exactly.
The extended struct sizes remain mandatory; old-size callers fail Protocol.

GbPoll.cleanup is physical settlement, cleanup_failed is sticky original-2s
timing failure, and phase5 alone is not success. Destroy returns 118
GB_CLEANUP_PENDING without consuming an incomplete/not-retired owner; 0 consumes
an on-time settled owner; 111 GB_CLEANUP consumes a physically settled but
deadline-failed owner. Never retry a consumed outcome. Foreign event/copy
release remains valid after either consumed outcome until the final reference.
QA-only gb_backend_qa_time controls local or cleanup observation time without
faking child reaping or transport and is absent from production. Live defaults
remain Instant-based, with no clock or timeout policy change.

Use installed Rust 1.92 or newer (including the `aarch64-linux-android`
target), CMake, libclang and Android NDK r29 (`29.0.14206865`). The scripts
honor `CARGO`, `RUSTC`, `RUSTDOC`, `CMAKE`, `LIBCLANG_PATH` and
`ANDROID_NDK_HOME`; Cargo.lock pins dependencies. Build the producer first:

```sh
bash scripts/build-scrcpy-gb-sync.sh
export GB_PRODUCER_JAR="$PWD/build/native/scrcpy/scrcpy-server-4.1-gb-sync.1"
bash scripts/build-quic-backend.sh all
bash scripts/build-quic-backend.sh all --qa
bash scripts/test-quic-backend.sh --ffi
bash scripts/test-quic-backend.sh
```

The route test selects a destination on an active non-loopback, non-P2P IPv4
LAN subnet, without sending network traffic. Set `GB_QUIC_ROUTE_TEST_DESTINATION`
to override the selected destination. A host without a suitable route reports
a clear prerequisite failure.
`GB_BUILD_DIR` selects the build/cache directory and `GB_OUTPUT_DIR` selects
artifact output (default `build/native/quic-backend`). `GB_OFFLINE=1` disables
dependency downloads. Production and QA artifact names remain distinct.
Android is API31 arm64 PIE, dynamic Bionic, 16 KiB LOAD alignment, static C++
runtime. No phone execution occurs. The enhanced producer's actual digest is
compiled into the backend through `build.rs`; the runtime still rejects any
other artifact. Direct Cargo invocation must provide `GB_PRODUCER_SHA256`.

The test wrapper generates synthetic H264/HEVC/AAC stock records using the
source `QuicCodecFixtureFactory` and checks the generated integrity manifests.
It never reads private evidence directories or prior phone recordings. Codec
output may differ across macOS versions. `GB_QUIC_TEST_FIXTURES` can select a
retained generated fixture directory; `GB_QUIC_TEST_PRODUCER` can select the
fresh producer used by the contract tests.

Backend byte/PTS equality and C pointer accounting are not VT/AAC callbacks,
audible audio, final Swift/renderer/recorder storage settlement, installed keyboard
routing, phone component results, or a wireless performance fix. Eligibility
remains NotIntegrated pending independent source review and later integration.
