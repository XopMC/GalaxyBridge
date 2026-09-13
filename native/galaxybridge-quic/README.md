# Galaxy Bridge native QUIC G0

## Task6e5j native idle survival

Each established, pinned, application-ready endpoint independently requests the
native quiche0.29.3 `send_ack_eliciting()` operation every2500ms, derived from the
unchanged5000ms idle transport parameter. First readiness arms one future
opportunity, never a startup PING. TLS without the session preface cannot arm it.
The existing owner poll services due quiche timeout/closure before a request and
uses ordinary bounded generation, congestion control, pacing and UDP writes.

One private next/last-service record holds no application bytes or liveness
claim. A late service consumes at most one opportunity and advances from fresh
now, with no catch-up burst. Retained ciphertext or WouldBlock suppresses that
opportunity, also advancing it; quiche coalesces its own pending PING flag.
`next_wakeup()` includes the next opportunity alongside every original minimum.
Read-only getters never arm/request/replenish it. Retirement clears it, including
successor construction. Backward service time, checked deadline overflow or an
unexpected native request error retires Protocol; none silently disables liveness.

Scheduling success/generation/UDP send is not peer acknowledgement. No wrapper
peer-liveness timer is refreshed, and repeated unanswered sends still reach
quiche's original negotiated idle timeout with its three-PTO minimum and its
one first-ack-eliciting-send reset after receive (RFC9000 section10.1). Therefore
dead-peer closure is not promised at exactly5s of wall silence. The wrapper's
connect/reliable-stall/cleanup deadlines and application records stay unchanged.
No control/clipboard/input heartbeat, raw socket heartbeat, extra thread, timer,
queue, dependency, transport option or public Stats field is added. QUIC/UDP
counters include the extra encrypted PING/ACK traffic; application admission and
DATAGRAM delivery counters do not. This adds bounded idle network/power work,
not a latency, congestion or real-phone performance guarantee.

The matched backend's existing opt-in GBQF1 module7 is the first observed endpoint
retirement boundary: site1=Media/index0, site2=Bulk/index1, all five capacity
scalars zero. It does not claim the sibling was healthy; existing status116
still means PeerIdle. No per-PING or content-bearing logging is added.

## Task6e12 bounded UDP write-readiness service

After an actual UDP WouldBlock, Endpoint suppresses every further actual send
in that poll, across both flush sites and expired/empty/refilled output. A private
service flag and per-poll permit are independent of diagnostic validity. Only a
new public poll starts a turn: send/receive/stats/diagnostics/next_wakeup do not
query readiness, write packets or replenish that permit.

Each later poll with blocked generated output makes at most one owned-fd
poll(POLLOUT,timeout0) query. No readiness query occurs when unblocked or retired.
No readiness means no writes that turn, while expiry, incoming authenticated
records, application service, generation and QUIC timers still run under their
existing limits. Readiness is advisory: another WouldBlock consumes the permit;
it is not success. A full write or empty generated queue clears persistent block,
but never rearms an already consumed same-turn permit. Normally writable output
keeps its existing multi-packet service, not a one-packet-per-turn throttle.

EINTR/EAGAIN defer that turn without retry or timer reset. Nonrecoverable query
errors retain the existing I/O retirement/errno path; POLLNVAL maps to EBADF.
POLLERR/HUP grant at most one actual send to expose the existing socket result,
including when POLLOUT is also set. A readiness bit never increments successful
write/delivery counters. The diagnostic blocked span keeps its original meaning
and closes only on a full write, empty generated output or retirement.

While blocked, next_wakeup omits only a past/due generated-head release time.
Future pacing, expiry of every existing generated descriptor, application/quiche
DG expiry, QUIC timers and original connect/reliable-stall absolute deadlines
remain minima. Real due expiry/timers may still return zero. Fresh per-packet
expiry checks remain immediately before each actual write; no deadline renews.
The existing source100us/client500us active caps, owner sleep/EOF/liveness loops,
five-second transport timeouts and fifteen-second rate cutoff do not change.
There is no wait inside Endpoint, new backoff/minimum sleep, thread or queue.

This is one bounded retry/service correction, not a promise of writable readiness
on Android, reduced physical unavailability, loss-free DG, probe RTT percentiles,
media latency or production acceptance. Control remains admitted/read/prepared
under pressure but cannot be transmitted through an unavailable socket. All
public signatures, 93-key observations and strict rate/wire/security contracts
below are unchanged. Only cfg(test) endpoint-boundary injections model socket
results and clocks for real authenticated poll regressions; no shipping fault
CLI/environment switch or production owner refactor exists.

## Task6e10 terminal pressure observations (no policy change)

The extra schema is93 numeric scalars per role, each uniquely named with
`peer_` or `client_`. Parse whitespace-separated `key=value` tokens from
stderr; do not infer order or parse private bootstrap stdout. There is one
terminal group per role after that owner's outcome/scoring, never hot-loop
output. A killed/broken stderr writer may leave an incomplete group: missing
keys or `diagnostic_output_failed=1` mean unavailable evidence. They do not
change the existing rate verdict. All existing counts/48-field GQS1 and CLI
arguments remain unchanged. Endpoint observations are additive nested
`Stats.pressure/path/socket_buffers`; owner fields are in
`ClientDiagnostic.owner_timing`, also carried by unchanged RateReport. The
peer retains its own separate terminal owner summary.

Below, omit the role prefix when matching each listed key. Booleans are0/1;
counters are checked u64, durations are local monotonic nanoseconds. Numeric
placeholders are not measurements when the corresponding availability/validity
flag is0. Invalid accumulators latch invalid without transport retirement;
an invalid provisional active-span snapshot invalidates that view without
mutating its accumulator (a later committed close performs the checked update).
the earlier6e9 receive-conservation retirement contract is unchanged.

| Keys | Meaning / unit / exact scope |
|---|---|
|pressure_valid|All added pressure arithmetic, residence metrics and spans valid; lifetime since Endpoint construction|
|generated_cap_stops|Generation calls stopped with the existing32 descriptors full, including a call that just filled the final slot; not dropped records|
|quiche_done_pending_dg|quiche.send returned Done while application/quiche outgoing DG remained; not proof of cwnd exhaustion|
|future_send_stops|Flush stopped on head SendInfo.at later than its last decision time; no OS attempt|
|udp_attempts, udp_would_block, udp_would_block_due|Actual socket send attempts and WouldBlock returns; due subset has head.at <= pre-call decision time (all current attempted heads are due)|
|udp_success, udp_errors, udp_short|Full writes, non-WouldBlock errors, short writes; same original error classification and ownership|
|expiry_submission, expiry_queued, expiry_generated|Disjoint increments alongside original expired: caller deadline, application/quiche pre-generation deadline, generated pre-write deadline. Sum equals original expired absent overflow. These retain original mixed logical-record/packet units; not all unique DG drops|
|wrapper_record_stops, wrapper_byte_stops|Existing wrapper guard checks, DG or reliable parser. Both can increment on one check. Reliable byte guard may stop without a readable stream. Not unique packets or drops|
|dg_budget_stops|A drain exhausted shared64-DG budget with quiche DG still pending; per drain stop, not a lost DG|
|retained_intake_pauses|Existing poll intake guard found quiche DG pending and refused another UDP read|
|udp_saturated_turns|Turns with64 successful raw socket receives, even if later QUIC processing rejects them|

Metric families `generated_write_age`, `write_blocked`, `retained`,
`owner_poll`, `owner_step`, `owner_service_gap`,
`owner_requested_sleep`, `owner_actual_sleep`, `owner_overshoot`
each expose exactly `_count`, `_total_ns`, `_max_ns`, `_valid`.
Zero samples means unobserved, not a zero-duration event.

- generated_write_age: successful full UDP writes only, from completion of
  quiche packet generation to completion of the actual socket write. Expired,
  failed and still-pending descriptors are not successful residence samples.
- write_blocked: continuous first-observed WouldBlock to first full write,
  no generated output, or retirement. Retries do not restart it. The queue may
  change inside a span; this is output-queue pressure, not per-packet attribution.
- retained: first observed DG retained by wrapper/budget/intake pressure to a
  subsequent drain observing quiche DG empty or retirement. It excludes
  unobserved kernel residence and may cover different queued DG records.
- The two span families also expose `_active` and `_active_ns`. A snapshot
  includes one provisional active span in count/total/max. Repeated snapshots
  do not accumulate that duration. Terminal retirement saves active facts before
  closing/releasing; live balances are subsequently cleared.

| Path keys | Meaning / availability |
|---|---|
|path_samples, path_unavailable_samples|Successful active-path observations and absent-path attempts, checked lifetime counts|
|path_terminal|The one forced path observation was committed at an explicit owner outcome or endpoint retirement; the path observer is now frozen, not the transport|
|path_valid, path_available|Latched consistency validity and whether this snapshot obtained exactly the owned fixed local/peer active path; no addresses printed|
|path_sample_at_ns|Last observation attempt's local time since Endpoint construction; not comparable across hosts|
|path_rtt_available|Both quiche min/max RTT exist and all RTT durations fit u64; default initial RTT is never claimed measured|
|path_rtt_ns, path_min_rtt_ns, path_max_rtt_ns, path_rttvar_ns|Smoothed RTT, path-lifetime measured min/max and mean variation from public quiche PathStats|
|path_cwnd_bytes, path_cwnd_min_bytes, path_cwnd_max_bytes|Current actual cwnd, minimum/maximum among retained samples (not exact inter-sample extrema or free cwnd)|
|path_lost_packets, path_retrans_packets, path_pto_count, path_lost_dg_frames, path_stream_retrans_bytes|Path-lifetime quiche loss/retransmission/PTO counters. Decrease, saturation or checked count/time failure invalidates evidence; not peer delivery ACKs|
|path_delivery_rate_available|Current estimate >0 and measured RTT available; absent/default0 is unmeasured|
|path_delivery_rate_bytes_per_second, path_delivery_rate_max_bytes_per_second|Current public delivery estimate and maximum of available samples, BYTES/second (not bits/s)|
|path_pmtu_bytes|Current public path PMTU when path_available=1|
|path_max_bandwidth_available, path_max_bandwidth_bytes_per_second|Public optional positive maximum bandwidth with measured RTT; implemented by bbr2_gcongestion upstream, absent under the unchanged CUBIC configuration. None/default0 is unavailable|

Path sampling runs after successful poll, at least100ms apart, plus one forced
terminal observation. Decreasing sampling time invalidates without changing poll.
Active-path loss counters are checked against the last stored sample; no
per-packet history or delta-as-throughput inference. Public `diagnostics()`
and `stats()` on a live endpoint only read retained path observations; even
repeated reads at/after100ms do not query quiche or change sample counts.
The explicit `capture_terminal_diagnostics(&mut self)` commits the one forced
observation at the actual owner's outcome while preserving pre-close fields
and balances. It sets path_terminal and freezes only path observation: admission,
readiness, transport service and normal cleanup remain unchanged. Repeated
capture, later polls and close cannot query paths again. Endpoint retirement
commits this observation itself if the owner has not captured it. Retired
diagnostics are frozen; ordinary live stats
after close retain historical path samples, not a claim of a currently live
path. No path yet is explicitly unavailable. A valid zero loss counter on an
available path is distinct from an unavailable RTT or BBR estimate.

Each `socket_send`/`socket_receive` family exposes `_available`,
`_bytes`, `_errno`. Read-only getsockopt(SO_SNDBUF/SO_RCVBUF) runs exactly
once each per existing socket. Raw signed integer results are bytes as returned
by the kernel, not a user-space queue cap: Linux/Android includes its doubled
kernel accounting, while Darwin reports its socket buffer capacity. No setting
is changed; no kernel-drop counter is queried. Error errno0 means missing errno
or invalid return shape, not success; unavailable raw bytes0 is a placeholder.

Owner scope starts after client application readiness and at peer turns already
ready at entry (the transition turn is excluded). It includes active recipe,
load, drain and terminal exchange, not bootstrap/cleanup. `owner_turns` counts
these turn starts, `owner_zero_sleep` counts requested zero sleeps,
`owner_valid` checks arithmetic and sample coverage. Poll count equals turn
count; only the final interrupted/complete turn may omit step or sleep.
`owner_retired_step_skips` records the rate peer's legitimate final skipped
workload phase after an already-ready poll retires. Its real sleep still runs
and is measured. The checked marker requires retirement, one completed current
poll, exactly one uncovered step, and preceding sleeps matching real steps;
it may occur once and no new observed turn may follow. It is not a zero-duration
workload call. Missing the marker remains invalid when that final sleep exists;
nonretired omissions, duplicate markers and missing poll hooks stay invalid.
Peer poll measures Endpoint.poll; client poll measures its existing poll_owned
wrapper, including stdout/child/liveness checks. Step measures the actual
unchanged rate.step or ordinary receive/submit work. Service gap is between
consecutive turn starts. Sleep measures the interval around the exact original
sleep call; overshoot=max(actual-requested,0). These intervals include OS
scheduling/clock overhead, are not CPU time, and must not be summed as disjoint
latency causes. No shared-clock mapping or input-to-photon claim is possible.

Retained observer memory is fixed; a test conservatively charges both entire
enlarged Stats copies, spans,32 added descriptor timestamps, sample timestamp and
owner against16KiB. The formatter tests worst numeric widths for both roles
against16KiB extra terminal text. Existing256KiB rate-harness tests remain
authoritative. No allocation occurs per timing observation (terminal output may
allocate). Added monotonic reads, scalar copies, checked arithmetic and100ms path
queries can perturb scheduling; no CPU or observer-overhead benchmark was made.
Correlated pressure is evidence for further diagnosis, not proof that Wi-Fi
power saving, congestion, CPU load or the OS caused a particular missing DG.

Internal transport foundation only. This does not alter Swift, Kotlin, stock
capture, ADB routing, packaging or installed app behavior. G0 actual-device
execution, G1 media/input correctness and G2 installed performance remain gates.

## Trust and bounded ownership

Each endpoint creates an ephemeral P-256 identity using BoringSSL in memory.
Issuance samples the actual system UTC Unix time once in whole seconds. A new
certificate uses notBefore=captured-120s and notAfter=captured+3480s: an exact
3600-second validity span with a bounded issuer margin for small clock
disagreement. Checked conversion/arithmetic and X.509 time construction fail
closed for pre-epoch, overflowing or unrepresentable issuance times. Peer
verification still rejects before notBefore and after notAfter (the exact
endpoints remain inclusive); it adds no verifier grace. Offsets outside that
window still fail visibly. This is not cross-host monotonic media-clock
mapping and does not change the active-session deadlines.
The private key has no export API and is never
serialized. The exact leaf DER SHA-256 pin comes from the caller's authenticated
private bootstrap pipe. TLS 1.3 requires both certificates, both pins and ALPN
`galaxybridge-quic/1`; an accept-any-certificate callback is not used.
Early data is never enabled, tickets are disabled, and session state is never
exported or reused across attempts. Quiche internally registers a client session
callback when wrapping the context; the wrapper provides no resumption API.

TLS-authenticated and application-ready are separate scalar states. After TLS,
client stream0 sends BE u32 length36, `GQH1`, then the 32-byte SessionId. Server
checks the exact session and replies with length36, `GQA1`, same session. The
client is ready only after this ACK; server reliable data follows its ACK in
the same stream. Pre-ready datagrams are discarded. Wrong, unexpected or repeated
prefaces retire the attempt. All of this shares the original five-second
connect deadline, with no reset from hostile traffic.

Application records are exactly `GQ01 | session[32] | lane:u8 |
sequence:u64-be | payload_length:u16-be | payload`, with lanes0/1 and a
1024-byte maximum payload. Reliable records additionally have a BE u32 length.
Only stream0 is accepted; no unidirectional streams are granted. There is no
application fragmentation or reliability for the datagram lane.

The reliable admission charge includes full record allocations still held by
QUIC retransmission references, up to64KiB. The charge is released only when the
last reference disappears, normally following ACK. Partially written reliable
records remain ordered and are never replayed into another Endpoint. A backlog
without allocation completion for five seconds retires the attempt.

Sender datagrams (application + quiche queue) are bounded to32records;
quiche receive datagrams to32records. The wrapper feeds quiche at most one
datagram at a time so its deadline remains attributable through packet
generation. Expired queued datagrams are purged before generation. Generated UDP
packets are separately bounded to32 ×1200bytes and respect quiche SendInfo.at.
Expired paced-but-unsent datagram packets are discarded; QUIC can retransmit
reliable bytes if a mixed packet is dropped. Application receive storage is
64records/64KiB, counted including envelopes, plus one fixed1075-byte parser.
The QUIC connection receive window is256KiB and stream receive window64KiB.
UDP output is1200bytes maximum with IPv4/IPv6 fragmentation disabled. A route
that cannot carry QUIC's minimum datagram fails instead of fragmenting.

The selected source IP is fixed by bootstrap; the server selects a port from the
first valid QUIC Initial on that IP, then the entire SocketAddr is fixed. This
is path selection, not authentication. There is no migration, downgrade, retry
into a successor, qlog, key log, telemetry, media capture or app launch.

## Public Rust seam

```rust
pub type SessionId = [u8; 32];
pub type CertificateFingerprint = [u8; 32];
pub enum Lane { Datagram, Reliable }
pub struct Message { pub lane: Lane, pub sequence: u64, pub payload: Vec<u8> }
pub struct Received { pub lane: Lane, pub sequence: u64, pub payload: Vec<u8> }
pub enum Admission { Accepted, Backpressured, TooLarge, Expired, Retired }

Identity::generate() -> Result<Identity, Error>
Identity::fingerprint(&self) -> CertificateFingerprint
Identity::certificate_der(&self) -> Result<Vec<u8>, Error> // public certificate only
tls::random_session() -> Result<SessionId, Error>

Endpoint::listen(bind: SocketAddr, expected_ip: IpAddr, session: SessionId,
                 identity: Identity, pin: CertificateFingerprint) -> Result<Endpoint, Error>
Endpoint::connect(bind: SocketAddr, peer: SocketAddr, session: SessionId,
                  identity: Identity, pin: CertificateFingerprint) -> Result<Endpoint, Error>
Endpoint::local_addr(&self) -> Result<SocketAddr, Error>
Endpoint::send(&mut self, message: Message, deadline: Instant) -> Admission
Endpoint::poll(&mut self) -> Result<(), Error>
Endpoint::receive(&mut self) -> Option<Received>
Endpoint::stats(&self) -> Stats
Endpoint::diagnostics(&self) -> Stats // terminal snapshot retained across cleanup
Endpoint::capture_terminal_diagnostics(&mut self) -> Stats // explicit owner outcome, pre-close
Endpoint::next_wakeup(&self) -> Duration
Endpoint::close(&mut self)

bootstrap::run_stdio_client(options: ClientOptions) -> Result<ClientReport, ClientFailure>
```

`send` consumes the caller's Message even on rejection; it copies nothing into
endpoint storage before validating size/state/budget. A datagram deadline uses
the caller's process-local monotonic Instant and is ignored for reliable data.
Before application-ready, sends return Backpressured. `poll` never waits and
processes at most64incoming UDP packets and32generated packets per call. The owner
must service it promptly, including timers, and may sleep until next_wakeup.
`receive` removes one admitted record. Stats are an immutable scalar snapshot:
TLS/application state, retirement reason, admitted/delivered/rejected/expired
counts, reliable bytes, queue counts/bytes, and UDP counters.
Protocol/TLS failure retires with a scalar reason; local I/O errors additionally
return Error. `close` is idempotent and immediately releases the exact socket,
TLS/QUIC state and all queues. No Swift C ABI is frozen.

Bootstrap Request body is version1:u8, session[32], fingerprint[32],
address-family:u8 (4 or6), address octets[4 or16]. Reply body is version1:u8,
session[32], fingerprint[32], port:u16-be. Both have BE u32 framing; body maximum
4096bytes. Actual Request sizes are70/82bytes and Reply67bytes. Decoders reject
truncation, trailing bytes, wrong version/family/session, zero port, unspecified
or multicast IPs and IPv4 broadcast.

## Build and host verification

Install Rust 1.92+ with Mac/Android standard libraries, CMake, rustfmt,
libclang and Android NDK r29 (`29.0.14206865`). The wrappers honor standard
`CARGO`, `RUSTC`, `RUSTDOC`, `RUSTFMT`, `CMAKE`, `LIBCLANG_PATH` and
`ANDROID_NDK_HOME` environment variables. No project-private tool layout is
required. Cargo.lock pins dependency sources and checksums; use `GB_OFFLINE=1`
to prohibit dependency downloads.

```bash
bash scripts/test-quic-transport.sh
bash scripts/build-quic-transport.sh
```

`GB_BUILD_DIR` selects the build cache and `GB_OUTPUT_DIR` selects artifact
output. Each crate's build and test wrappers use separate Cargo target directories.

Tests use only loopback and owned local probe children, with bounded deadlines.
The runners use at most2compile jobs. Build outputs are under
`build/native/quic-transport/`: two probe executables, two static libraries,
SHA256SUMS and architecture/linkage evidence. Android uses API31 and16KiB ELF
LOAD alignment. Its C++ runtime is static; system libc remains shared.
The build explicitly rejects any unbundled C++ shared runtime dependency.
Mac deployment target is14.0. See `third_party/quic/NOTICE.md` and Cargo.lock.

## Probes and the later root-owned device gate

`gb-quic-probe --self-test` creates two loopback peers and writes scalar success
only to stderr; stdout is empty. `--stdio-peer` reads one protected Request on
stdin, writes exactly one71-byte framed Reply to stdout, and echoes synthetic
records over QUIC. It exits on stdin EOF, failure, idle/connect timeout or its
30-second total lifetime. Tests may lower that lifetime with
`--duration-ms 1..30000`. Loopback bootstrap IPs bind loopback; a real selected
peer IP causes a same-family wildcard bind for the device sidecar.

`--stdio-client --peer-ip IP --local-ip IP [--duration-ms N] -- PROGRAM ARGS...`
uses direct Command argv, with no shell. N defaults to5000 and is restricted to
1..15000 before spawning. PROGRAM must be an explicitly authorized binary-safe
non-PTY command with separate stdout/stderr. The driver owns piped stdin/stdout
and inherits separate stderr. It generates identity/session in memory, writes
the Request, reads/validates the Reply within5s, then connects directly to
IP:Reply.port within5s. It sends fixed synthetic32-byte records every20ms,
bounded to16active scheduling credits per lane, within the requested probe
duration. Datagram credits expire at their200ms local budget; this frees a
scheduling slot, never records delivery or removes a missing admitted sequence.
Late replies release only their own sequence's credit; duplicates never release
another credit and remain a failure. Reliable credits retain ordered reply
accounting. The last200ms (or half a tiny duration) drains replies. Tiny requested
durations may legitimately fail to complete both lanes.

Both success and failure close child stdin, wait at most2s, and kill/reap only
that still-owned unreaped child if necessary. Forced cleanup is reported as
failure. Scalars distinguish requested probe duration from whole elapsed time,
both lane counts/loss, duplicates, timeouts and cleanup. Missing lanes, loss,
duplicates, failed bootstrap/transport or failed cleanup yield nonzero exit.
An application-level echo is a synthetic G0 check, not a media-latency result.

Terminal diagnostics are fixed-size scalar snapshots, captured before cleanup.
The receive schedule drains retained quiche DG records before another UDP
intake and between synchronous quiche receives. Each poll still reads at most64
UDP packets; it shares a64-DG extraction budget and128 reliable stream-read
budget across all drains, rather than multiplying budgets per packet. Quiche
keeps32 receive/send DG slots; wrapper storage remains64 records/64KiB.
The next complete DG stays in quiche when wrapper count/bytes cannot hold it.
No further UDP intake occurs while any quiche DG remains undrained. Owned
timeouts, reliable output and generated output still run in that finite turn;
waiting for caller consumption does not create a zero-delay wakeup/spin loop.
If a non-consuming caller blocks incoming ACKs, the existing reliable-stall
timer may retire the attempt; no ACK progress is invented under backpressure.

Additive Stats fields (also nested in ClientDiagnostic.endpoint, and printed
for both peer/client by ordinary and rate probes):

| Field | Unit and commit point |
|---|---|
|quiche_datagrams_decoded:u64|Checked cumulative quiche Stats.dgram_recv DATAGRAM frames, sampled before/after every synchronous recv, including failed/closing recv calls; not UDP packets or valid G0 records|
|quiche_datagrams_pending_records:usize|Current quiche receive queue record balance|
|quiche_datagrams_pending_bytes:usize|Current quiche queue body-byte balance, excluding QUIC frame headers and wrapper accounting charge; an empty frame counts one record and zero bytes|
|datagrams_extracted:u64|Cumulative successful quiche-to-wrapper pops including not-ready/malformed records later rejected; not consumer deliveries|
|quiche_datagrams_evicted:u64|Checked cumulative measured old-record evictions inside quiche.recv, before extraction|
|datagram_observation_valid:bool|Whether conservation evidence is available and valid; false initially before any observed recv, or latched false on observation failure|
|datagram_observation_failures:u64|Observation failure events (unavailable, inconsistent, reset/overflow/saturated counters); any such failure immediately retires, so a live attempt never accumulates an unbounded history|
|receive_resource_failure:bool|Terminal receive-resource-budget failure: measured eviction if validity=true/evictions>0, or unavailable/inconsistent observation if validity=false/failures>0|

The locked quiche0.29.3 queue is not concurrently drained during recv. Therefore
before_pending + (after_decoded-before_decoded) - after_pending measures that
call's evictions. Checked arithmetic,32-record/byte bounds and cross-call
decoded=extracted+evicted+pending conservation reject inconsistent evidence.
A pre-recv headroom check conservatively reserves1200 frame increments before
quiche's usize counter could overflow. Zero eviction with validity=false is
unavailable evidence, never a proven zero-loss observation. A successful
quiche.recv still increments received_udp_packets even when measured eviction
causes the attempt to retire immediately afterwards.

More than32 short DG frames may fit inside one authenticated UDP packet; no
inter-packet schedule prevents such intra-call eviction. A measured eviction
retires the exact attempt as existing Protocol, with receive_resource_failure,
before any application extraction from that receive. This is resource-budget
classification, not a claim that an evicted frame was malformed, TLS failed or
I/O failed. Invalid G0 envelopes still retire Protocol separately. Unavailable
or inconsistent observation also fails visibly as Protocol/resource failure.
No wire, method signature, rate source48-scalar schema, threshold, CC, queue
capacity or production authentication/readiness behavior changes.

diagnostics() preserves pending balances immediately before retirement, as well
as cumulative counters; stats() after cleanup reports zero released queue
balances and retains cumulative counters. The counters carry no payload or
credentials, are not delivery ACKs, and cannot prove network/kernel lossless DG
delivery, per-sequence actual sending, smooth CUBIC pacing, or G1 repair.

ClientReport adds terminal:ClientDiagnostic plus datagram_active_peak,
datagram_credit_expired, datagram_credit_blocked, datagram_backpressured,
reliable_credit_blocked and reliable_backpressured. ClientDiagnostic contains
origin:ClientOrigin, endpoint:Stats, error:ErrorKind and errno:i32.
ClientOrigin distinguishes Configuration/Spawn/Bootstrap/Constructor/StdoutEvent/
Poll/EndpointRetired/ConnectDeadline/ChildExit/InvalidReply/Admission/FinalMissing/
FinalDuplicate/Completed/Cleanup (None before an outcome).
ErrorKind is None/InvalidConfiguration/Identity/Transport/Io.

Stats adds reached_tls/reached_ready, tls_failure:tls::VerificationFailure,
datagrams_admitted/datagrams_received/datagrams_rejected/datagrams_generated/
datagrams_udp_sent, udp_socket_received, io_errno, and optional numeric
local_close_code/peer_close_code.
VerificationFailure is None/MissingCertificate/PinMismatch/NotYetValid/Expired/
VerificationError. These categories do not alter certificate validity or pins.
The missing-certificate category also recognizes the local TLS certificate-required
alert generated before BoringSSL invokes its verify callback.

The existing sent counters are admission counts; datagrams_generated counts QUIC
packet generation, datagrams_udp_sent counts datagram-bearing packets handed
successfully to the UDP socket, and datagrams_received counts decoded delivery
into the receive queue. udp_socket_received includes every successful socket
receive, even packets rejected by path/TLS checks; the existing received_udp_packets
counts only successful quiche.recv. Stderr distinguishes udp_received from
quic_received. None proves remote arrival. expired counts local datagram
expiry; credit_expired counts probe scheduling releases, not delivery. Endpoint
diagnostics retain queue depths immediately before retirement; stats() still
reports cleared live queues after retirement. reached_* flags remain sticky,
while authenticated/application_ready retain their existing live-state meaning.

Client stderr labels client_origin=FinalMissing separately from
client_origin=EndpointRetired and its retirement reason. Normal EOF and peer
errors both emit peer_origin, received/echo-admission counts and the endpoint
snapshot. Output is fixed keys, enums and numbers; stdout remains only the
private bootstrap Reply. No certificate, pin, nonce, session, payload, arbitrary
peer error text or raw TLS errors are printed. The final strict loss/duplicate
verdict,20ms pacing,200ms drain,5s timers and2s child cleanup are unchanged.

Reproducible loopback use:

```bash
GB_PROBE="$PWD/build/native/quic-transport/gb-quic-probe-macos-arm64"
"$GB_PROBE" --stdio-client --peer-ip 127.0.0.1 --local-ip 127.0.0.1 \
  --duration-ms 500 -- "$GB_PROBE" --stdio-peer
```

After independent review and the separate device checklist, the root may
supply its already selected ADB executable, serial, local route IP, phone IP
and exact uploaded sidecar path:

```bash
"$GB_PROBE" --stdio-client --peer-ip "$GB_PHONE_IP" --local-ip "$GB_MAC_IP" \
  --duration-ms 5000 -- "$GB_ADB" -s "$GB_SERIAL" shell -T -e none "$GB_REMOTE_PROBE" --stdio-peer
```

This recipe assumes root has verified ADB shell-v2 binary-safe stdout/stderr
separation and no PTY. Legacy exec-out multiplexing is not acceptable. No
credentials are arguments; pins/session are exchanged only through owned
pipes. The driver does not discover/select/upload/start app UI, pair, change
permissions or kill ADB globally. It starts only the explicitly supplied child.
Expected successful stderr includes `client=pass lanes_completed=2` (with
other scalar fields between them), zero loss/duplicates/timeouts,
`cleanup=1 cleanup_forced=0`; exit0 and empty client stdout. No phone or media
work is performed by the automated test runner.

## Finite rate screener: frozen harness schema

The separate `bootstrap::run_stdio_rate_client(ClientOptions, RateShape)` uses
Constant/FrameBurst, requires duration15000ms before spawn, and shares the private
owned lifecycle with the unchanged ordinary echo entrypoint. CLI client and peer
both select `--rate-shape constant|frame-burst`; their authenticated reliable
recipe must match. This is synthetic data, not capture, media repair or a product
mode. One connection carries one12s source leg:30,000 video records with1000 data
bytes (20Mbps),600 audio-rate records with320 data bytes (128kbps). Constant video
is due every400us; burst video uses60fps41/42/42-packet frames repeating. Audio is
due every20ms in both. Source deadlines remain scheduled+200ms. No bulk echo.
The central10s has50032-byte reliable probes at50Hz, beginning500ms after the
client receives LoadBegin. Echoes report source-load-active at processing time.

All multibyte integers below are unsigned big-endian. Unknown, reserved,
truncated, overlong or conflicting records fail. G0 lane sequences are separate
monotonic per-direction domains. Reliable sequences start0 and advance on each
Accepted message; DG sequences merge due video/audio slots, video first on ties.

DG payload: bytes0..3 `GQR1`;4 version1;5 kind1=video/2=audio;6 shape0/1;
7 zero;8..11 class ordinal;12..15 frame ordinal (constant/audio0xffffffff);
16..19 data length1000/320;20..23 class total30000/600; then deterministic data.
Byte i of data is `(kind*17 + ordinal*31 + i) mod256`. All data bytes are checked.
Burst frame IDs0..719 and sequence/class mapping must match the fixed schedule.

Reliable payload prefix: bytes0..3 `GQS1`;4 version1;5 kind;6 shape0/1;7 flags.
Kinds1=Recipe,2=LoadBegin,3=LoadEnd,4=Probe,5=Echo,6=FinalAck have exactly32bytes:
8..11 ID (Probe/Echo0..499, otherwise0);12..31 five u32 values. Recipe values are
12000,30000,600,500,200; all other kinds require five zeros. Flags are0 except
Echo's bit0 (source currently active); all other bits must be zero.

Kinds7=SourceSummary,8=AdmittedBitmap,9=SourceBins use a16-byte prefix: flags0;
8..9 chunk index;10..11 chunk count;12..15 body length. Summary is one400-byte
record (index0,count1,body384) containing48 u64 fields. Fields0..6 are video
offered/first_attempted/admitted/overflow/expired_before_admission/rejected/
unfinished;7..13 same audio fields;14 backpressure attempts;15 pending FIFO peak;
16 jitter sample count;17..20 first-attempt jitter p50/p95/p99/max in microseconds;
21..29 source DG admitted/generated/UDP-sent/received/rejected, raw UDP sent/
received, successful QUIC receive, generic expiry;30 generic rejection;
31..35 sampled peaks reliable bytes/DG queue/generated packets/receive queue/
receive bytes;36 source elapsed microseconds at end-of-drain;37 source error
flags (bits0 transport,1 recipe,2 delivery,3 measurement);38..40 reliable echo
offered/admitted/dropped;41..47 zero. Counters are not per-sequence send evidence.

Bitmap has four ordered chunks, body lengths1000/1000/1000/825, indices0..3,
count4. It contains30600bits (least-significant bit first per byte) indexed by
DG sequence. Including the G0 envelopes/reliable prefixes, all four occupy4093
bytes. SourceBins has15 ordered chunks, count15; each body is10 bins×4u64=320
bytes, record length336. A bin's fields are offered/admitted/received useful
bytes and control completions.150 bins cover the fixed15s active scope at100ms
resolution, with source times based on source load start and receiver times on
local LoadBegin receipt. These are distinct local timelines, not clock mapping.
Summary then bitmap then bins follow LoadEnd and200ms source drain, after probe
scoring; FinalAck follows full validation and the client's local200ms drain.
No peer text or variable-size allocation is accepted from this schema.

Durations use process-local Instant. Report microseconds rounded upward (a
conservative1us quantization); nearest-rank percentiles use every completed
sample and show missing/late denominators. Fixed thresholds: accepted-to-echo
p95<=50ms/p99<=100ms, scheduled-to-echo max<=200ms; source first-attempt jitter
p99<=5ms/max<=20ms. Missing or late responses cannot improve the strict verdict.
Per class, admitted<=first_attempted<=offered is required. Jitter samples must
equal the first-attempt total; a complete-load Pass requires all30600 samples.
Absent/underreported source timing is MeasurementIncomplete, even when default
zero quantiles would satisfy thresholds; known loss keeps its higher precedence.
Queues are128 pending DG (<=147456bytes),16 active200ms probe credits, bounded
4 reliable/8 DG attempts per turn, and<=256KiB harness allocation per endpoint
excluding the separately bounded Endpoint/stdio owner. Internal peaks are
sampled; actual-DG-send attribution is aggregate only. Exact recipe payload
rate is20.6176Mbps; with G0 DG envelopes21.5764Mbps, excluding QUIC/IP and controls.

Recipe is the authenticated GO. The Mac installs its receiver/bitmaps first;
Android begins counted DG only after receiving Recipe. DG overtaking LoadBegin
is counted and reported as `pre_begin`, never discarded as warm-up. The source
stops new admission at12s (including retained FIFO work); accepted records get
only their original deadline during drain. LoadEnd reception starts a separate
Mac-local200ms collection boundary, not a cross-host absolute expiry guarantee.
Client FinalAck requires summary, all four bitmap chunks, all15 bin chunks and
local drain. Peer replies FinalAck; only its receipt completes the exchange.

Public `RateReport` retains shape, primary verdict, all four failure flags,
per-class received/malformed/duplicate/late counts, all500 probe denominators,
credit accounting, nearest-rank admission-delay/RTT/scheduled-response quantiles,
largest no-completion interval,150 local bins, sampled queue peaks, optional
SourceReport, terminal ClientDiagnostic, elapsed/cleanup/forced facts and the
post-close `endpoint_released` balance check. SourceReport's48 values use the
exact Summary field order above; its150 bins use the SourceBins order. Missing
source or metric evidence prints `unavailable`; contradictory count differences
are not clamped into zero evidence. Source generic expiry/rejection stay raw,
not an invented disjoint accepted-unsent partition. Actual sent is the reviewed
aggregate successfully-written application-DG counter, not raw UDP or generation.
Aggregate reconciliation and admitted-bitmap membership cannot identify the
class/sequence of a datagram actually written, or explain a failed route's loss.

`RateFailure { stage, report }` preserves the original lifecycle stage. Primary
verdict order is TransportOrCleanupFailure, InvalidRecipe,
DeliveryOrDeadlineFailure, MeasurementIncomplete, Pass; all except Pass return
nonzero. A peer-side recipe mismatch can retire before its reason reaches the
client, so its fixed scalar `peer_rate_error=Recipe` accompanies the client's
transport/cleanup failure; the client does not guess a remote cause. A transport
or cleanup failure retains known missing counts and incomplete-measurement flags.
Pass requires30600 admitted=actual-sent=timely unique received, all500 in-load
echoes, all frozen thresholds, valid complete reports and graceful exact-owned
cleanup. A unit/integration test can pass its negative accounting oracle while
the deliberate impaired scenario correctly returns a failed screener verdict.
This is neither input-to-photon, PERF-01, production/foundation nor G1 repair
acceptance. Raw unreliable-DG loss is not itself a QUIC protocol bug.

Live timestamps are taken per attempt/admission, not reused from an earlier
poll turn. Caller200ms probe credit expiry does not cancel an accepted reliable
message: G0 ignores reliable send deadlines and retains its5s stall policy.
No application retransmit follows Accepted. All500 IDs stay in the fixed table;
late echoes remain in the tail and missing samples remain in the denominator.
The source retains only128 small slot descriptors (payloads generated on demand),
30600 u32 jitter samples, fixed bitmaps/bins, and16 echo IDs. Tests account actual
Vec capacities, fixed fields, terminal construction and transient payload space
against256KiB. Endpoint peaks are sampled before poll-draining/submission work;
they are not exact hidden high-water marks. After close the client checks retired
state and zero reliable/DG/generated/receive retained balances separately from
the preserved terminal diagnostic snapshot.

Finite host runner (requires the already prepared project-local toolchain):

```bash
bash scripts/test-quic-rate-probe.sh
GB_PROBE="$PWD/build/native/quic-transport/gb-quic-probe-macos-arm64"
"$GB_PROBE" --stdio-client --peer-ip 127.0.0.1 --local-ip 127.0.0.1 \
  --rate-shape constant -- "$GB_PROBE" --stdio-peer --rate-shape constant
```

Use frame-burst at both positions for the other leg. Client rate mode selects
15000ms and rejects a conflicting explicit duration before spawn; rate peer
keeps its30s lease and rejects a shortened duration. Bootstrap5s, connect5s,
active15s, cleanup2s share the existing owner; no phase renews on packet activity.
The rate owner rechecks its original15s cutoff after poll before dispatch;
the receiver checks fresh time again at terminal ACK acceptance. At equality
expiry wins, including preemption inside a bounded receive batch. Expiry is
latched: a later queued ACK cannot complete the exchange or replace FinalMissing
with Completed. A valid ACK committed strictly before the cutoff can complete.
Both sides check owned pipe EOF/errors during load. Scalar stderr is bounded;
stdout is bootstrap-only. The dedicated runner logs every real leg, including
all150-bin reports and failed gates. It uses loopback and test-only fault peers,
never phones. Root alone may later supply its verified shell-v2/ADB direct argv
and explicit matching shape; each12s shape uses a fresh owned attempt. Device
screening requires all declared three equal repetitions per shape/phone with
stable posture/route/concurrency and every failure retained. Host results cannot
substitute for that requirement; G1/G2 and the full client release remain open.
