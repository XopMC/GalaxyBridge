use crate::bootstrap::{Frame, Replies, Requests};
use crate::process::{Cleanup, OwnedChild, OwnedCommand};
use crate::{
    bootstrap::Binding,
    bulk::{self, Blob, Object},
    stock::{self, SocketGroup},
    Error, Role, Side, MS,
};
use galaxybridge_quic::tls::Identity;
use galaxybridge_quic::{Admission, Endpoint, Lane, Message};
use galaxybridge_quic_media::{
    control::WriteLease, media::OutputLease, wire::Record, DispatchPolicy, Owner,
};
use std::net::{IpAddr, SocketAddr};
use std::{
    collections::{BTreeMap, BTreeSet, VecDeque},
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};
static OWNERS: AtomicUsize = AtomicUsize::new(0);
/// Advancing host-test clock for the one stdio fixture process lifetime. It is
/// NOT Android BOOTTIME and is never selected by a production/Android owner.
#[cfg(all(feature = "qa", not(target_os = "android")))]
fn qa_fixture_monotonic_ns() -> Result<u64, Error> {
    static ORIGIN: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
    let origin = *ORIGIN.get_or_init(Instant::now);
    let elapsed = Instant::now()
        .checked_duration_since(origin)
        .ok_or(Error::Clock)?;
    u64::try_from(elapsed.as_nanos())
        .map_err(|_| Error::Clock)?
        .checked_add(1)
        .ok_or(Error::Clock)
}
#[cfg(all(test, feature = "qa", not(target_os = "android")))]
#[test]
fn qa_fixture_clock_advances_without_restarting() {
    let before = qa_fixture_monotonic_ns().unwrap();
    std::thread::sleep(Duration::from_millis(2));
    let after = qa_fixture_monotonic_ns().unwrap();
    assert!(after > before && after - before >= 1_000_000);
}
#[cfg(feature = "qa")]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QaDisplayScenario {
    Assigned,
    Duplicate,
    Conflict,
    Ended,
}
#[cfg(feature = "qa")]
impl QaDisplayScenario {
    pub fn parse(value: &str) -> Result<Self, Error> {
        match value {
            "assigned" => Ok(Self::Assigned),
            "duplicate" => Ok(Self::Duplicate),
            "conflict" => Ok(Self::Conflict),
            "ended" => Ok(Self::Ended),
            _ => Err(Error::Protocol),
        }
    }
    pub fn events(self) -> &'static [crate::process::DisplayStatus] {
        use crate::process::DisplayStatus;
        const A: DisplayStatus = DisplayStatus {
            kind: 1,
            width: 64,
            height: 64,
            density: 160,
            display: 7,
        };
        const C: DisplayStatus = DisplayStatus {
            kind: 2,
            width: 0,
            height: 0,
            density: 0,
            display: 0,
        };
        const E: DisplayStatus = DisplayStatus {
            kind: 3,
            width: 0,
            height: 0,
            density: 0,
            display: 0,
        };
        match self {
            Self::Assigned => &[A],
            Self::Duplicate => &[A, A],
            Self::Conflict => &[A, C],
            Self::Ended => &[A, E],
        }
    }
}
struct Slot;
impl Drop for Slot {
    fn drop(&mut self) {
        OWNERS.fetch_sub(1, Ordering::SeqCst);
    }
}
#[derive(Clone)]
pub struct OwnerSlot(Arc<Slot>);
impl OwnerSlot {
    pub fn acquire() -> Result<Self, Error> {
        crate::process::poll_abandoned_cleanup();
        OWNERS
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| {
                (n < 16).then_some(n + 1)
            })
            .map_err(|_| Error::Capacity)?;
        Ok(Self(Arc::new(Slot)))
    }
    pub fn retained(&self) -> usize {
        Arc::strong_count(&self.0)
    }
}
pub enum Event {
    Ready,
    Media { handle: u64 },
    Device { handle: u64, ordinal: u64 },
    BulkComplete(bulk::Completion),
    Transaction(galaxybridge_quic_media::TransactionResult),
    Retired(Error),
    Display(crate::process::DisplayStatus),
}
pub struct MediaView<'a> {
    pub record: &'a Record,
    pub bytes: &'a [u8],
    pub configuration: Option<&'a [u8]>,
    pub deadline: u64,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DeviceCutoffs {
    pub reverse: u64,
    pub clipboard: Option<u64>,
}
impl DeviceCutoffs {
    pub fn effective(self) -> u64 {
        self.clipboard.map_or(self.reverse, |d| d.min(self.reverse))
    }
}
pub struct CopyLease {
    #[cfg(feature = "qa")]
    pub(crate) payload_shape: Option<(bool, usize)>,
    pub(crate) _charge: Option<galaxybridge_quic_media::media::ForeignCopyCharge>,
    pub(crate) _payload: Option<galaxybridge_quic_media::media::PayloadCopyCharge>,
    pub(crate) _owner: OwnerSlot,
}
enum Held {
    Media(OutputLease),
    Device { object: Object, committed: bool },
}
enum Writing {
    G1(WriteLease),
    Bulk(Object, usize),
    Recovery(crate::recovery::Request, usize),
    Bitrate(crate::quality::Request, usize),
}
struct Small {
    record: bulk::Record,
    deadline: u64,
}
struct VideoDatagram {
    record: Record,
    deadline: u64,
    repair: bool,
}
pub struct Backend {
    binding: Binding,
    side: Side,
    pub(crate) slot: OwnerSlot,
    pub(crate) g1: Owner,
    endpoints: Vec<Endpoint>,
    startup: Option<HostStartup>,
    child: Option<OwnedChild>,
    producer: Option<stock::ProducerLaunch>,
    producer_policy: Option<stock::LaunchPolicy>,
    display_parser: crate::process::DisplayParser,
    display_pending: VecDeque<crate::process::DisplayStatus>,
    display_received: u8,
    connector: Option<stock::Connector>,
    pair_deadline: u64,
    stock_deadline: Option<u64>,
    origin: Instant,
    last: u64,
    outer: [u64; 3],
    video_datagrams: BTreeMap<u64, VideoDatagram>,
    pub(crate) bulk: bulk::Channel,
    stock: Option<stock::Source>,
    pair_ready: bool,
    stock_ready: bool,
    remote_start: bool,
    start_sent: bool,
    start_token: Option<u64>,
    start_confirmed: bool,
    ready: bool,
    events: VecDeque<Event>,
    promised: BTreeSet<(u8, u64)>,
    held: BTreeMap<u64, Held>,
    serial: u64,
    terminal: Option<Error>,
    pending_bulk: VecDeque<Object>,
    writing: Option<Writing>,
    small: VecDeque<Small>,
    reverse: BTreeMap<u64, Object>,
    reverse_next: u64,
    reverse_issued: Option<u64>,
    reverse_sent: u64,
    critical: u64,
    bulk_id: u64,
    clipboard: Option<(u64, u64)>,
    parser: stock::DeviceParser,
    small_pool: bulk::BlobPool,
    ack_pool: bulk::BlobPool,
    buffers: [Vec<u8>; 3],
    active_track: Option<u8>,
    track_turn: u8,
    poll_turn: bool,
    producer_map: crate::recovery::ProducerMap,
    recovery_id: u64,
    quality: Option<crate::quality::Controller>,
    quality_video: u64,
    quality_id: u64,
    quality_pending: Option<crate::quality::Request>,
    quality_precedes_recovery: bool,
    quality_submitted: Option<u32>,
    first_diagnostics: bool,
    first_reported: bool,
    reliable_observations: [Option<ReliableObservation>; 3],
    first_terminal_site: Option<u32>,
    first_ticket: Option<crate::ffi::TerminalTicket>,
    trace_last_flush: Option<u64>,
    trace_emitted: u64,
    trace_counts: (u64, u64),
    trace_final: bool,
    send_stages: Option<Box<SendStages>>,
    boottime: fn() -> Result<u64, Error>,
    #[cfg(feature = "qa")]
    drop_filter: Option<QaDrop>,
    #[cfg(feature = "qa")]
    observation_gate: bool,
    #[cfg(feature = "qa")]
    whole_deadline: Option<Instant>,
    #[cfg(feature = "qa")]
    write_limit: usize,
    #[cfg(feature = "qa")]
    local_clock: Option<u64>,
    #[cfg(feature = "qa")]
    service_trace: Option<Vec<[u64; 4]>>,
    #[cfg(feature = "qa")]
    source_admissions: [u64; 4],
    #[cfg(feature = "qa")]
    policy_observation: [u64; 32],
    #[cfg(feature = "qa")]
    receive_peaks: [usize; 2],
}
#[derive(Default)]
struct SendStages {
    progress: crate::progress::Observer,
    peer_progress: [Option<crate::progress::Line>; 6],
    progress_last_offer: Option<u64>,
    progress_peer_turn: bool,
    progress_peer_kind: usize,
    terminal_progress: Option<[Option<crate::progress::Line>; 12]>,
    started: Option<u64>,
    last: Option<u64>,
    captured: u64,
    final_captured: bool,
    pending: VecDeque<crate::recovery::SendStageLine>,
    #[cfg(feature = "qa")]
    hold_output: bool,
}
impl SendStages {
    fn finish_progress(&mut self) {
        let mut rows = [None; 12];
        rows[..6].copy_from_slice(&self.progress.finish());
        rows[6..].copy_from_slice(&self.peer_progress);
        self.terminal_progress = Some(rows);
    }
}
#[cfg(feature = "qa")]
struct QaDrop {
    track: u8,
    sequence: u64,
    index: u16,
    repeat: bool,
    dropped: u64,
}
pub struct HostConfig {
    pub binding: Binding,
    pub peer_ip: IpAddr,
}
struct HostStartup {
    requests: Requests,
    identities: Option<[Identity; 3]>,
    wire: Vec<u8>,
    written: usize,
    frame: Frame,
    peer_ip: IpAddr,
    local_ip: IpAddr,
}
/// Ask the kernel which local source reaches this exact peer. UDP connect
/// selects a route but sends no datagram; the temporary socket is then closed.
/// All three real endpoints bind the selected source advertised in private bootstrap.
fn routed_source(peer: IpAddr) -> Result<IpAddr, Error> {
    if peer.is_unspecified()
        || peer.is_multicast()
        || peer == IpAddr::V4(std::net::Ipv4Addr::BROADCAST)
    {
        return Err(Error::Protocol);
    }
    let any = if peer.is_ipv4() {
        IpAddr::V4(std::net::Ipv4Addr::UNSPECIFIED)
    } else {
        IpAddr::V6(std::net::Ipv6Addr::UNSPECIFIED)
    };
    let route = std::net::UdpSocket::bind(SocketAddr::new(any, 0))?;
    route.connect(SocketAddr::new(peer, 9))?;
    let local = route.local_addr()?.ip();
    if local.is_unspecified()
        || local.is_multicast()
        || local.is_ipv4() != peer.is_ipv4()
        || local == IpAddr::V4(std::net::Ipv4Addr::BROADCAST)
    {
        return Err(Error::Io);
    }
    Ok(local)
}

/// Input and bounded loss-repair requests are latency-critical bidirectional
/// GQM control. Keep cache request/release, down/up, replaceable moves and
/// boundary acknowledgements on their own authenticated QUIC connection. A
/// kind-13 delivery watermark stays on the media route: it
/// is configuration-ordered feedback, and a separate connection could deliver
/// it before the track configuration it describes. A GQB1 receiver-recovery
/// request is independent control: the replacement video AU remains on the
/// expiring datagram path, but the request for it must not wait behind the
/// stream it is repairing.
fn message_route(payload: &[u8]) -> usize {
    let priority_media_control = payload.starts_with(b"GQM1")
        && payload
            .get(4)
            .is_some_and(|kind| matches!(kind, 6 | 7 | 8 | 9 | 10));
    let priority_receiver_recovery =
        payload.starts_with(b"GQB1") && payload.get(4) == Some(&4) && payload.get(5) == Some(&3);
    usize::from(priority_media_control || priority_receiver_recovery) * 2
}

fn is_reliable_video_recovery(lane: Lane, payload: &[u8]) -> bool {
    if lane != Lane::Reliable {
        return false;
    }
    Record::decode(lane, payload).is_ok_and(|record| {
        record.kind == 5
            && record.track == 1
            && record.flags & galaxybridge_quic_media::wire::RELIABLE_RECOVERY_FLAG != 0
    })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ReliableObservation {
    kind: u8,
    track: u8,
    bytes: usize,
}

fn reliable_observation(payload: &[u8]) -> ReliableObservation {
    if payload.starts_with(b"GQM1") && payload.len() >= 6 {
        ReliableObservation {
            kind: payload[4],
            track: payload[5],
            bytes: payload.len(),
        }
    } else {
        // Private scalar class only. 255 identifies non-GQM reliable data
        // without retaining or exposing any of its bytes.
        ReliableObservation {
            kind: 255,
            track: 0,
            bytes: payload.len(),
        }
    }
}

fn reliable_stall_rejection(
    route: usize,
    retirement: Option<galaxybridge_quic::endpoint::Retirement>,
    observation: Option<ReliableObservation>,
    backlog: usize,
) -> [usize; 5] {
    if retirement == Some(galaxybridge_quic::endpoint::Retirement::ReliableStall) {
        if let Some(observation) = observation {
            return [
                observation.kind as usize,
                observation.track as usize,
                route + 1,
                observation.bytes,
                backlog,
            ];
        }
    }
    [0; 5]
}

fn endpoint_terminal_rejection(
    route: usize,
    stats: galaxybridge_quic::endpoint::Stats,
    observation: Option<ReliableObservation>,
) -> [usize; 5] {
    if stats.retirement == Some(galaxybridge_quic::endpoint::Retirement::PeerIdle) {
        // Existing opt-in module7 record, site=endpoint role. For PeerIdle
        // only: presence/timed-out bits, local/peer QUIC close codes, RX/TX
        // packet counts. Keep absent distinct from a valid NO_ERROR (zero).
        // Never include reason strings, addresses or packet contents.
        return [
            usize::from(stats.local_close_code.is_some())
                | (usize::from(stats.peer_close_code.is_some()) << 1)
                | (usize::from(stats.quic_timed_out) << 2),
            stats.local_close_code.unwrap_or(0) as usize,
            stats.peer_close_code.unwrap_or(0) as usize,
            stats.received_udp_packets as usize,
            stats.sent_udp_packets as usize,
        ];
    }
    reliable_stall_rejection(
        route,
        stats.retirement,
        observation,
        stats.reliable_backlog_bytes,
    )
}

// RFC 4594-aligned traffic classes. Keep bulk best-effort, map interactive
// media to WMM video and latency-critical input to WMM voice. These markings
// are hints only; reliability, ordering and authentication remain unchanged.
fn route_dscp(index: usize) -> Result<u8, Error> {
    match index {
        0 => Ok(34), // AF41: interactive video/audio
        1 => Ok(0),  // CS0: files, clipboard and other bulk traffic
        2 => Ok(46), // EF: input and its acknowledgements
        _ => Err(Error::Protocol),
    }
}

fn apply_route_dscp(endpoints: &mut [Endpoint]) -> Result<(), Error> {
    if !endpoints.is_empty() && endpoints.len() != 3 {
        return Err(Error::Protocol);
    }
    for (index, endpoint) in endpoints.iter_mut().enumerate() {
        if endpoint.stats().retired {
            continue;
        }
        endpoint
            .set_dscp(route_dscp(index)?)
            .map_err(|_| Error::Io)?;
    }
    Ok(())
}

impl Backend {
    /// QA-only bounded observation of the real service order, not a replacement
    /// ingest/output path. Each ordinary poll starts a fresh finite trace.
    #[cfg(feature = "qa")]
    pub fn qa_service_trace(&mut self) -> Vec<[u64; 4]> {
        self.service_trace
            .replace(Vec::with_capacity(128))
            .unwrap_or_default()
    }
    #[cfg(feature = "qa")]
    fn trace_service(&mut self, event: [u64; 4]) {
        if let Some(trace) = self.service_trace.as_mut() {
            assert!(trace.len() < 128, "bounded service trace");
            trace.push(event);
        }
    }
    /// Only pump the existing authenticated UDP endpoints to stage an actual
    /// application receive batch; never inject records or run a fake Source.
    #[cfg(feature = "qa")]
    pub fn qa_stage_receive(&mut self) -> Result<u64, Error> {
        for endpoint in &mut self.endpoints {
            endpoint.poll().map_err(|_| Error::Io)?;
        }
        Ok(self.endpoints[0].stats().datagrams_received)
    }
    #[cfg(feature = "qa")]
    pub fn qa_media_usage(&self) -> [usize; 10] {
        let (au, _) = self.g1.receiver.usage();
        let cache = self.g1.cache.usage();
        [
            au.0,
            au.1,
            cache.0,
            cache.1,
            self.source_admissions[0] as usize,
            self.source_admissions[1] as usize,
            self.receive_peaks[0],
            self.receive_peaks[1],
            self.source_admissions[2] as usize,
            self.source_admissions[3] as usize,
        ]
    }
    /// QA-only terminal scalar accounting. 0..4 source admission/drop per
    /// track;4 AU241 source outcome;5..7 accepted target fragments/count;
    ///7..10 target received count/bitmap/expected count;10/11 config/AU offered;
    ///12 native commit result;13 explicit decline;14..17 receive drops/skips;
    ///17..20 actual source ACK/repair;20 producer sync writes;21..25 native
    /// input/output drops;26 generation;27..29 video admission/state/reason;
    ///30 actual source ACK for video sequence2 (queued-input-loss oracle).
    /// No packet bytes or pointer identity.
    #[cfg(feature = "qa")]
    pub fn qa_policy_snapshot(&self) -> [u64; 32] {
        let mut v = self.policy_observation;
        if let Ok(h) = self.g1.receiver.media_health(1) {
            v[14] = h.declined;
            v[15] = h.skipped;
            v[21] = h.admitted_input_dropped;
            v[23] = h.output_dropped;
            v[27] = h.admitted_sequence;
            v[28] = h.state as u64;
            v[29] = h.reason as u64;
        }
        if let Ok(h) = self.g1.receiver.media_health(2) {
            v[16] = h.declined;
            v[22] = h.admitted_input_dropped;
            v[24] = h.output_dropped;
        }
        v[20] = self.stock.as_ref().map_or(0, |s| s.recovery_requests());
        v[26] = self.binding.context.generation;
        v
    }
    #[cfg(feature = "qa")]
    pub fn from_prepared_channels(
        slot: OwnerSlot,
        binding: Binding,
        endpoints: [Endpoint; 3],
        fixture: stock::PreparedFixture,
    ) -> Result<Self, Error> {
        if binding.context.enabled & 7 != fixture.enabled() {
            return Err(Error::Protocol);
        }
        let mut backend = Self::from_channels(slot, Side::Peer, binding, endpoints, None)?;
        backend.stock = Some(stock::Source::PreparedFixture(fixture));
        backend.observation_gate = true;
        Ok(backend)
    }
    #[cfg(feature = "qa")]
    pub fn stdio_fixture(
        fixture: stock::PreparedFixture,
        whole_deadline: Instant,
    ) -> Result<Self, Error> {
        let now = Instant::now();
        if whole_deadline <= now || whole_deadline.duration_since(now) > Duration::from_secs(30) {
            return Err(Error::Deadline);
        }
        let slot = OwnerSlot::acquire()?;
        let (binding, endpoints) = crate::bootstrap::accept_stdio_until(Some(whole_deadline))?;
        let mut backend = Self::from_prepared_channels(slot, binding, endpoints, fixture)?;
        backend.whole_deadline = Some(whole_deadline);
        #[cfg(not(target_os = "android"))]
        {
            qa_fixture_monotonic_ns()?;
            backend.qa_clock(qa_fixture_monotonic_ns)?;
        }
        Ok(backend)
    }
    /// Closed synthetic status input for the prepared QA owner only. It does
    /// not emulate a producer process or expose arbitrary stdout/identity.
    #[cfg(feature = "qa")]
    pub fn qa_display_scenario(&mut self, scenario: QaDisplayScenario) -> Result<(), Error> {
        if self.pair_ready
            || self.side != Side::Peer
            || self.binding.context.capture_kind != 1
            || !matches!(self.stock, Some(stock::Source::PreparedFixture(_)))
            || !self.display_pending.is_empty()
        {
            return Err(Error::Protocol);
        }
        for status in scenario.events() {
            self.display_pending.push_back(status.validate()?);
        }
        Ok(())
    }
    #[cfg(feature = "qa")]
    pub fn qa_clock(&mut self, clock: fn() -> Result<u64, Error>) -> Result<(), Error> {
        if self.pair_ready || self.side != Side::Peer {
            return Err(Error::Protocol);
        }
        self.boottime = clock;
        Ok(())
    }
    /// Deterministic boundary clock, never available in production builds.
    #[cfg(feature = "qa")]
    pub fn qa_local_time(&mut self, now: u64) -> Result<(), Error> {
        if now < self.now_ns()? {
            return Err(Error::Clock);
        }
        self.local_clock = Some(now);
        Ok(())
    }
    #[cfg(feature = "qa")]
    pub fn qa_cleanup_elapsed(&mut self, ns: u64) -> Result<(), Error> {
        self.child
            .as_mut()
            .ok_or(Error::Protocol)?
            .qa_cleanup_elapsed(ns)
    }
    #[cfg(feature = "qa")]
    pub fn qa_drop_fragment(
        &mut self,
        track: u8,
        sequence: u64,
        index: u16,
        repeat: bool,
    ) -> Result<(), Error> {
        if self.pair_ready
            || self.side != Side::Host
            || !matches!(track, 1 | 2)
            || sequence == 0
            || self.drop_filter.is_some()
        {
            return Err(Error::Protocol);
        }
        self.drop_filter = Some(QaDrop {
            track,
            sequence,
            index,
            repeat,
            dropped: 0,
        });
        Ok(())
    }
    #[cfg(feature = "qa")]
    pub fn qa_dropped(&self) -> u64 {
        self.drop_filter.as_ref().map_or(0, |f| f.dropped)
    }
    #[cfg(feature = "qa")]
    pub fn qa_recovery_requests(&self) -> u64 {
        self.stock
            .as_ref()
            .map_or(0, stock::Source::recovery_requests)
    }
    #[cfg(feature = "qa")]
    pub fn qa_recovery_observations(&mut self) -> Vec<[u64; 8]> {
        let mut out = vec![];
        if let Some(t) = self.g1.receiver.recovery_trace.as_mut() {
            while let Some((_, e)) = t.pop() {
                out.push(e.0);
            }
        }
        out
    }
    #[cfg(feature = "qa")]
    pub fn qa_unavailable_repairs(&self) -> u64 {
        self.g1.cache.unavailable
    }
    #[cfg(feature = "qa")]
    pub fn qa_stock_write_limit(&mut self, limit: usize) -> Result<(), Error> {
        if self.pair_ready || limit == 0 || limit > 8192 {
            return Err(Error::Protocol);
        }
        self.write_limit = limit;
        Ok(())
    }
    #[cfg(feature = "qa")]
    pub fn qa_observation_gate(&mut self, enabled: bool) -> Result<(), Error> {
        if self.pair_ready {
            return Err(Error::Protocol);
        }
        self.observation_gate = enabled;
        Ok(())
    }
    #[cfg(feature = "qa")]
    pub fn qa_component(
        &mut self,
        duration_ms: u32,
        mode: u32,
        sequence: u64,
        index: u16,
    ) -> Result<(), Error> {
        if self.pair_ready
            || self.side != Side::Host
            || self.whole_deadline.is_some()
            || !(1..=30000).contains(&duration_ms)
            || mode > 2
            || mode == 0 && (sequence != 0 || index != 0)
            || mode != 0 && sequence == 0
        {
            return Err(Error::Protocol);
        }
        let cutoff = self
            .origin
            .checked_add(Duration::from_millis(duration_ms as u64))
            .ok_or(Error::Clock)?;
        if Instant::now() >= cutoff {
            return Err(Error::Deadline);
        }
        if mode != 0 {
            self.qa_drop_fragment(
                1,
                sequence,
                if mode == 2 { u16::MAX } else { index },
                mode == 2,
            )?;
        }
        self.observation_gate = true;
        self.whole_deadline = Some(cutoff);
        Ok(())
    }
    #[cfg(feature = "qa")]
    pub fn qa_fixture(&mut self, fixture: stock::PreparedFixture) -> Result<(), Error> {
        if self.pair_ready
            || self.side != Side::Peer
            || self.binding.context.enabled & 7 != fixture.enabled()
        {
            return Err(Error::Protocol);
        }
        self.stock = Some(stock::Source::PreparedFixture(fixture));
        self.observation_gate = true;
        Ok(())
    }
    /// Android-only production peer. Configuration is validated before private
    /// bootstrap; producer launch and stock connection remain behind both gates.
    pub fn stdio_peer(launch: stock::ProducerLaunch) -> Result<Self, Error> {
        Self::stdio_peer_with_policy(launch, None)
    }
    pub fn stdio_peer_with_policy(
        launch: stock::ProducerLaunch,
        policy: Option<stock::LaunchPolicy>,
    ) -> Result<Self, Error> {
        Self::stdio_peer_with_policy_and_media_max_pacing_rate(launch, policy, None)
    }
    pub fn stdio_peer_with_policy_and_media_max_pacing_rate(
        launch: stock::ProducerLaunch,
        policy: Option<stock::LaunchPolicy>,
        media_max_pacing_rate: Option<u64>,
    ) -> Result<Self, Error> {
        #[cfg(not(target_os = "android"))]
        {
            let _ = (launch, policy, media_max_pacing_rate);
            return Err(Error::Unsupported);
        }
        #[cfg(target_os = "android")]
        {
            let slot = OwnerSlot::acquire()?;
            launch.verify_artifact()?;
            let (binding, endpoints) =
                crate::bootstrap::accept_stdio_with_media_max_pacing_rate(media_max_pacing_rate)?;
            launch.command_with_policy(&binding, policy)?;
            let mut backend = Self::from_channels(slot, Side::Peer, binding, endpoints, None)?;
            if Self::adaptive_primary(&backend.binding, &launch, policy) {
                backend.quality = Some(crate::quality::Controller::new(launch.video_bit_rate)?);
            }
            backend.producer = Some(launch);
            backend.producer_policy = policy;
            Ok(backend)
        }
    }
    pub fn spawn_host(config: HostConfig, command: OwnedCommand) -> Result<Self, Error> {
        command.validate()?;
        let slot = OwnerSlot::acquire()?;
        let origin = Instant::now();
        let local_ip = routed_source(config.peer_ip)?;
        let (requests, identities) = Requests::fresh(config.binding, local_ip)?;
        let wire = requests.encode()?;
        let mut child = OwnedChild::spawn_recovery_helper(&command, slot.clone())?;
        child.observe_recovery(requests.binding.context.generation);
        child.observe_first_cause(
            requests.binding.context.generation,
            requests.binding.context.target_token,
            1,
        );
        let mut backend =
            Self::new_inner(slot, Side::Host, requests.binding.clone(), vec![], None)?;
        backend.origin = origin;
        backend.child = Some(child);
        backend.startup = Some(HostStartup {
            requests,
            identities: Some(identities),
            wire,
            written: 0,
            frame: Frame::default(),
            peer_ip: config.peer_ip,
            local_ip,
        });
        Ok(backend)
    }
    pub fn from_channels(
        slot: OwnerSlot,
        side: Side,
        binding: Binding,
        endpoints: [Endpoint; 3],
        stock: Option<SocketGroup>,
    ) -> Result<Self, Error> {
        Self::new_inner(slot, side, binding, endpoints.into_iter().collect(), stock)
    }
    fn new_inner(
        slot: OwnerSlot,
        side: Side,
        binding: Binding,
        mut endpoints: Vec<Endpoint>,
        stock: Option<SocketGroup>,
    ) -> Result<Self, Error> {
        binding.validate()?;
        apply_route_dscp(&mut endpoints)?;
        crate::ffi::prepare_recovery_diagnostics();
        let origin = Instant::now();
        let mut g1 = Owner::new(binding.context.clone(), 0)?;
        if std::env::var_os("GB_QUIC_RECOVERY_DIAGNOSTICS").is_some_and(|v| v == "1") {
            g1.receiver.recovery_trace = Some(Box::default());
        }
        let send_stages = g1
            .receiver
            .recovery_trace
            .as_ref()
            .map(|_| Box::<SendStages>::default());
        Ok(Self {
            bulk: bulk::Channel::new(side, binding.context.generation),
            binding,
            side,
            slot,
            g1,
            endpoints,
            startup: None,
            child: None,
            producer: None,
            producer_policy: None,
            display_parser: Default::default(),
            display_pending: VecDeque::new(),
            display_received: 0,
            connector: None,
            pair_deadline: crate::PHASE_LIFETIME,
            stock_deadline: None,
            origin,
            last: 0,
            outer: [0; 3],
            video_datagrams: BTreeMap::new(),
            stock: stock.map(stock::Source::LiveStock),
            pair_ready: false,
            stock_ready: false,
            remote_start: false,
            start_sent: false,
            start_token: None,
            start_confirmed: false,
            ready: false,
            events: VecDeque::new(),
            promised: BTreeSet::new(),
            held: BTreeMap::new(),
            serial: 0,
            terminal: None,
            pending_bulk: VecDeque::new(),
            writing: None,
            small: VecDeque::new(),
            reverse: BTreeMap::new(),
            reverse_next: 1,
            reverse_issued: None,
            reverse_sent: 0,
            critical: 0,
            bulk_id: 0,
            clipboard: None,
            parser: Default::default(),
            small_pool: bulk::BlobPool::small_events(),
            ack_pool: bulk::BlobPool::ack_events(),
            buffers: std::array::from_fn(|_| Vec::new()),
            active_track: None,
            track_turn: 1,
            poll_turn: false,
            producer_map: Default::default(),
            recovery_id: 0,
            quality: None,
            quality_video: 0,
            quality_id: 0,
            quality_pending: None,
            quality_precedes_recovery: false,
            quality_submitted: None,
            first_diagnostics: crate::ffi::first_cause_enabled(),
            first_reported: false,
            reliable_observations: [None; 3],
            first_terminal_site: None,
            first_ticket: None,
            trace_last_flush: None,
            trace_emitted: 0,
            trace_counts: (0, 0),
            trace_final: false,
            send_stages,
            boottime: crate::recovery::boottime_ns,
            #[cfg(feature = "qa")]
            drop_filter: None,
            #[cfg(feature = "qa")]
            observation_gate: false,
            #[cfg(feature = "qa")]
            whole_deadline: None,
            #[cfg(feature = "qa")]
            write_limit: 8192,
            #[cfg(feature = "qa")]
            local_clock: None,
            #[cfg(feature = "qa")]
            service_trace: None,
            #[cfg(feature = "qa")]
            source_admissions: [0; 4],
            #[cfg(feature = "qa")]
            policy_observation: [0; 32],
            #[cfg(feature = "qa")]
            receive_peaks: [0; 2],
        })
    }
    pub fn now_ns(&self) -> Result<u64, Error> {
        #[cfg(feature = "qa")]
        if let Some(now) = self.local_clock {
            return Ok(now);
        }
        self.origin
            .elapsed()
            .as_nanos()
            .try_into()
            .map_err(|_| Error::Clock)
    }
    fn refresh_receiver_repair_margin(&mut self) -> Option<u64> {
        let margin = Self::receiver_repair_margin(self.endpoints[0].stats().path);
        self.g1.set_receiver_repair_margin(margin);
        margin
    }
    fn receiver_repair_margin(p: galaxybridge_quic::endpoint::PathObservation) -> Option<u64> {
        if p.valid && p.available && p.rtt_available {
            p.rttvar_ns
                .checked_mul(4)
                .and_then(|v| p.rtt_ns.checked_add(v))
                .filter(|m| *m > 0)
        } else {
            None
        }
    }
    pub fn ready(&self) -> bool {
        self.ready && self.terminal.is_none()
    }
    pub fn terminal(&self) -> Option<Error> {
        self.terminal
    }
    pub fn stats(&self, role: Role) -> galaxybridge_quic::endpoint::Stats {
        self.endpoints
            .get(if role == Role::Media { 0 } else { 1 })
            .map(Endpoint::stats)
            .unwrap_or_default()
    }
    fn reserve(&self, completion: bool) -> Result<(), Error> {
        if self.events.len() + self.held.len() + self.promised.len()
            >= if completion { 128 } else { 96 }
        {
            galaxybridge_quic_media::media::first_error::reject(
                3,
                line!(),
                self.events.len() + self.held.len() + self.promised.len(),
                if completion { 128 } else { 96 },
                1,
                0,
                0,
            );
            Err(Error::Capacity)
        } else {
            Ok(())
        }
    }
    fn reserve_progress(&self) -> Result<(), Error> {
        if self.events.len() + self.held.len() + self.promised.len() >= 112 {
            galaxybridge_quic_media::media::first_error::reject(
                3,
                line!(),
                self.events.len() + self.held.len() + self.promised.len(),
                112,
                1,
                0,
                0,
            );
            Err(Error::Capacity)
        } else {
            Ok(())
        }
    }
    pub(crate) fn event_is_stock_ack(&self, event: &Event) -> bool {
        match event {
            Event::Device { handle, .. } => {
                matches!(self.held.get(handle),Some(Held::Device{object,..})if object.bytes.as_slice()[0]==1)
            }
            _ => false,
        }
    }
    fn token(&mut self) -> Result<u64, Error> {
        self.serial = self.serial.checked_add(1).ok_or(Error::Capacity)?;
        Ok(self.serial)
    }
    fn event(&mut self, e: Event) -> Result<(), Error> {
        self.reserve(true)?;
        self.events.push_back(e);
        Ok(())
    }
    pub fn next_event(&mut self) -> Option<Event> {
        self.events.pop_front()
    }
    pub(crate) fn peek_event(&self) -> Option<&Event> {
        self.events.front()
    }
    pub fn check_media(&mut self, id: u64) -> Result<MediaView<'_>, Error> {
        self.refresh_receiver_repair_margin();
        let now = self.now_ns()?;
        let Some(Held::Media(l)) = self.held.get(&id) else {
            return Err(Error::InvalidHandle);
        };
        self.g1.receiver.check_output(l, now)?;
        Ok(MediaView {
            record: &l.record,
            bytes: l.bytes.as_slice(),
            configuration: l.configuration.as_ref().map(|b| b.as_slice()),
            deadline: l.deadline,
        })
    }
    pub(crate) fn retain_media(&self, id: u64) -> Result<OutputLease, Error> {
        let Some(Held::Media(l)) = self.held.get(&id) else {
            return Err(Error::InvalidHandle);
        };
        Ok(l.clone())
    }
    pub(crate) fn retain_device(&self, id: u64) -> Result<Blob, Error> {
        let Some(Held::Device { object: o, .. }) = self.held.get(&id) else {
            return Err(Error::InvalidHandle);
        };
        Ok(o.bytes.clone())
    }
    pub fn replace_move(
        &mut self,
        record: Record,
        received: u64,
    ) -> Result<galaxybridge_quic_media::control::MoveAdmission, Error> {
        if !self.ready() || self.side != Side::Host {
            return Err(Error::Retired);
        }
        self.refresh_receiver_repair_margin();
        let now = self.now_ns()?;
        Ok(self.g1.replace_move(record, received, now)?)
    }
    pub fn reserve_copy(&mut self, id: u64) -> Result<CopyLease, Error> {
        self.refresh_receiver_repair_margin();
        let now = self.now_ns()?;
        let Some(Held::Media(l)) = self.held.get(&id) else {
            return Err(Error::InvalidHandle);
        };
        Ok(CopyLease {
            #[cfg(feature = "qa")]
            payload_shape: None,
            _charge: Some(self.g1.receiver.reserve_output_copy(l, now)?),
            _payload: None,
            _owner: self.slot.clone(),
        })
    }
    pub fn reserve_payload_copy(&mut self, id: u64) -> Result<CopyLease, Error> {
        self.refresh_receiver_repair_margin();
        let now = self.now_ns()?;
        let Some(Held::Media(l)) = self.held.get(&id) else {
            return Err(Error::InvalidHandle);
        };
        Ok(CopyLease {
            #[cfg(feature = "qa")]
            payload_shape: Some((l.record.kind == 5, l.bytes.len())),
            _charge: None,
            _payload: Some(self.g1.receiver.reserve_output_payload_copy(l, now)?),
            _owner: self.slot.clone(),
        })
    }
    pub fn reserve_native_payload(
        &mut self,
        id: u64,
    ) -> Result<
        (
            galaxybridge_quic_media::media::MediaOutcome,
            Option<CopyLease>,
        ),
        Error,
    > {
        self.refresh_receiver_repair_margin();
        let now = self.now_ns()?;
        let Some(Held::Media(l)) = self.held.get(&id) else {
            return Err(Error::InvalidHandle);
        };
        let (outcome, payload) = self.g1.receiver.reserve_native_media_payload(l, now)?;
        Ok((
            outcome,
            payload.map(|payload| CopyLease {
                #[cfg(feature = "qa")]
                payload_shape: Some((true, l.bytes.len())),
                _charge: None,
                _payload: Some(payload),
                _owner: self.slot.clone(),
            }),
        ))
    }
    pub fn phase(&self) -> u32 {
        if self.terminal.is_some() {
            4
        } else if self.startup.is_some() {
            0
        } else if !self.pair_ready {
            1
        } else if !self.ready {
            2
        } else {
            3
        }
    }
    pub fn commit_media(&mut self, id: u64) -> Result<(), Error> {
        self.refresh_receiver_repair_margin();
        let now = self.now_ns()?;
        let Some(Held::Media(l)) = self.held.get(&id) else {
            return Err(Error::InvalidHandle);
        };
        self.g1.receiver.consumer_commit(l, now)?;
        Ok(())
    }
    pub fn media_eligibility(
        &mut self,
        id: u64,
    ) -> Result<galaxybridge_quic_media::media::MediaOutcome, Error> {
        self.refresh_receiver_repair_margin();
        let now = self.now_ns()?;
        let Some(Held::Media(lease)) = self.held.get(&id) else {
            return Err(Error::InvalidHandle);
        };
        Ok(self.g1.receiver.media_eligibility(lease, now)?)
    }
    pub fn native_copy_preflight(
        &mut self,
        id: u64,
        copy: Option<&CopyLease>,
    ) -> Result<galaxybridge_quic_media::media::MediaOutcome, Error> {
        self.refresh_receiver_repair_margin();
        let now = self.now_ns()?;
        let Some(Held::Media(lease)) = self.held.get(&id) else {
            return Err(Error::InvalidHandle);
        };
        let payload = copy
            .map(|c| c._payload.as_ref().ok_or(Error::Protocol))
            .transpose()?;
        Ok(self
            .g1
            .receiver
            .native_copy_preflight(lease, payload, now)?)
    }
    pub fn decline_media(
        &mut self,
        id: u64,
        reason: galaxybridge_quic_media::media::MediaDeclineReason,
    ) -> Result<(), Error> {
        self.refresh_receiver_repair_margin();
        let now = self.now_ns()?;
        let Some(Held::Media(lease)) = self.held.get(&id) else {
            return Err(Error::InvalidHandle);
        };
        self.g1.receiver.decline_output(lease, reason, now)?;
        #[cfg(feature = "qa")]
        if lease.record.track == 1 && lease.record.sequence == 241 {
            self.policy_observation[13] = reason as u64;
        }
        Ok(())
    }
    pub fn retry_media(&mut self, episode: u64) -> Result<(), Error> {
        self.refresh_receiver_repair_margin();
        let now = self.now_ns()?;
        self.g1.receiver.media_retry(episode, now)?;
        Ok(())
    }
    pub fn native_media_status(
        &mut self,
        track: u8,
        epoch: u32,
        config: u32,
        input_loss: u64,
        input_drops: u64,
        output: u64,
        pressure: bool,
        drops: u64,
    ) -> Result<(), Error> {
        self.refresh_receiver_repair_margin();
        let now = self.now_ns()?;
        self.g1.receiver.native_media_status(
            track,
            epoch,
            config,
            input_loss,
            input_drops,
            output,
            pressure,
            drops,
            now,
        )?;
        Ok(())
    }
    /// Bounded native ownership must already exist; commit and transfer one AU
    /// together so rejected destination capacity cannot produce a delivered ACK.
    pub fn commit_native_copy(
        &mut self,
        id: u64,
        copy: &mut CopyLease,
    ) -> Result<galaxybridge_quic_media::media::MediaOutcome, Error> {
        if self.terminal.is_some() {
            return Err(Error::Retired);
        }
        self.refresh_receiver_repair_margin();
        let now = self.now_ns()?;
        let Some(Held::Media(lease)) = self.held.get(&id) else {
            return Err(Error::InvalidHandle);
        };
        let payload = copy._payload.as_mut().ok_or(Error::Protocol)?;
        let result = self.g1.receiver.commit_native_media(lease, payload, now)?;
        #[cfg(feature = "qa")]
        if lease.record.track == 1 && lease.record.sequence == 241 {
            self.policy_observation[12] = match result {
                galaxybridge_quic_media::media::MediaOutcome::Admitted => 1,
                galaxybridge_quic_media::media::MediaOutcome::DeclinedPressure => 2,
                galaxybridge_quic_media::media::MediaOutcome::DeclinedExpired => 3,
                galaxybridge_quic_media::media::MediaOutcome::SkippedDependent => 4,
            };
        }
        Ok(result)
    }
    pub fn device(&self, id: u64) -> Result<&[u8], Error> {
        let Some(Held::Device { object: o, .. }) = self.held.get(&id) else {
            return Err(Error::InvalidHandle);
        };
        Ok(o.bytes.as_slice())
    }
    /// Original immutable cutoffs, read before commit transfers admission to
    /// an exact-owner downstream consumer. No receipt or timer is renewed.
    pub fn device_cutoffs(&self, id: u64) -> Result<DeviceCutoffs, Error> {
        let Some(Held::Device {
            object,
            committed: false,
        }) = self.held.get(&id)
        else {
            return Err(Error::InvalidHandle);
        };
        let clipboard = self.clipboard.and_then(|(sequence, deadline)| {
            (object.purpose == 2
                && object.bytes.as_slice()[0] == 1
                && bulk::u64_at(object.bytes.as_slice(), 1) == sequence)
                .then_some(deadline)
        });
        Ok(DeviceCutoffs {
            reverse: object.deadline,
            clipboard,
        })
    }
    pub fn release_event(&mut self, id: u64) -> Result<(), Error> {
        self.refresh_receiver_repair_margin();
        let now = self.now_ns()?;
        let held = self.held.remove(&id).ok_or(Error::InvalidHandle)?;
        match held {
            Held::Media(l) => {
                if self.terminal.is_none() {
                    if let Err(failure) = self.g1.receiver.release_output(&l, now) {
                        let error = Error::from(failure);
                        self.retire(error);
                        return Err(error);
                    }
                }
            }
            Held::Device {
                committed: false, ..
            } => {
                if self.terminal.is_none() {
                    self.first_terminal_site = Some(line!());
                    galaxybridge_quic_media::media::first_error::reject(
                        8,
                        self.first_terminal_site.unwrap(),
                        0,
                        0,
                        0,
                        0,
                        0,
                    );
                    galaxybridge_quic_media::media::first_error::error(crate::ffi::status(
                        Error::Retired,
                    ));
                }
                self.retire(Error::Retired);
            }
            Held::Device {
                committed: true, ..
            } => {}
        }
        Ok(())
    }
    pub fn consume_device(&mut self, id: u64) -> Result<(), Error> {
        if self.terminal.is_some() {
            return Err(Error::Retired);
        }
        let now = self.now_ns()?;
        let Some(Held::Device {
            object: o,
            committed,
        }) = self.held.get_mut(&id)
        else {
            return Err(Error::InvalidHandle);
        };
        if *committed || self.reverse_issued != Some(o.id) || o.id != self.reverse_next {
            return Err(Error::Protocol);
        }
        let matching_cutoff = self.clipboard.and_then(|(sequence, deadline)| {
            (o.purpose == 2
                && o.bytes.as_slice()[0] == 1
                && bulk::u64_at(o.bytes.as_slice(), 1) == sequence)
                .then_some(deadline)
        });
        if matching_cutoff.is_some_and(|deadline| now >= deadline) {
            self.retire(Error::ClipboardAckMissing);
            return Err(Error::ClipboardAckMissing);
        }
        if now >= o.deadline {
            return Err(Error::Deadline);
        }
        if matching_cutoff.is_some() {
            self.clipboard = None;
        }
        if o.bytes.as_slice()[0] == 0 || o.bytes.len() > 976 {
            self.bulk.applied(o, now)?;
        }
        *committed = true;
        self.reverse_next = self.reverse_next.checked_add(1).ok_or(Error::Capacity)?;
        self.reverse_issued = None;
        Ok(())
    }
    pub fn queue_bulk(&mut self, bytes: &[u8], received: u64) -> Result<u64, Error> {
        if !self.ready() || self.side != Side::Host || self.binding.context.enabled & 4 == 0 {
            return Err(Error::Retired);
        }
        self.reserve(false)?;
        stock::validate_bulk_command(bytes)?;
        let now = self.now_ns()?;
        let id = self.bulk_id.checked_add(1).ok_or(Error::Capacity)?;
        if bytes[0] == 9 {
            let sequence = bulk::u64_at(bytes, 1);
            if sequence == 0 || self.clipboard.is_some() {
                galaxybridge_quic_media::media::first_error::reject(3, line!(), 0, 0, 0, 0, 0);
                return Err(Error::Protocol);
            }
            if now >= crate::deadline(received, crate::CLIPBOARD_LIFETIME)? {
                return Err(Error::Deadline);
            }
        }
        self.bulk.queue(id, self.critical, bytes, received, now)?;
        self.promised.insert((3, id));
        self.bulk_id = id;
        if bytes[0] == 9 {
            self.clipboard = Some((
                bulk::u64_at(bytes, 1),
                crate::deadline(received, crate::CLIPBOARD_LIFETIME)?,
            ));
        }
        Ok(id)
    }
    pub fn queue_critical(&mut self, record: Record, received: u64) -> Result<u64, Error> {
        self.refresh_receiver_repair_margin();
        if !self.ready() || self.side != Side::Host {
            return Err(Error::Retired);
        }
        if semantic_release(&record) {
            self.reserve_progress()?;
        } else {
            self.reserve(false)?;
        }
        let now = self.now_ns()?;
        if received > now {
            return Err(Error::Clock);
        }
        if now >= crate::deadline(received, 500 * MS)? {
            return Err(Error::Deadline);
        }
        if record.sequence != self.critical.checked_add(1).ok_or(Error::Capacity)? {
            galaxybridge_quic_media::media::first_error::reject(3, line!(), 0, 0, 0, 0, 0);
            return Err(Error::Protocol);
        }
        let sequence = record.sequence;
        let id = self.g1.queue_critical_received(record, received, now)?;
        self.promised.insert((1, id));
        self.critical += 1;
        self.g1.tick(now)?;
        self.trace_control_stage(1, sequence, now);
        Ok(id)
    }
    pub fn poll(&mut self) -> Result<(), Error> {
        // Only the CLI peer creates its own scope; never shadow the host C scope.
        let scope = (self.side == Side::Peer && self.first_diagnostics && !self.first_reported)
            .then(|| galaxybridge_quic_media::media::first_error::Scope::begin(true));
        let r = self.service();
        if let Err(e) = r {
            if let Some(Writing::Recovery(request, n)) = &self.writing {
                let (epoch, config, sequence) = request.identity;
                let id = request.id;
                let n = *n;
                self.trace_request(9, epoch, config, sequence, id, 3, n as u64);
            }
            galaxybridge_quic_media::media::first_error::error(crate::ffi::status(e));
            if let Some(scope) = scope.as_ref() {
                if let Some(o) = scope.observation() {
                    self.first_reported = true;
                    let rejection = o.rejection.unwrap_or_default();
                    let cache = self.g1.cache.usage();
                    let (au, metadata) = self.g1.receiver.usage();
                    let mut record = crate::ffi::TerminalRecord {
                        first: Some([
                            0,
                            self.binding.context.generation,
                            self.binding.context.target_token,
                            line!() as u64,
                            o.stage as u64,
                            o.status as u64,
                            rejection.module as u64,
                            rejection.site as u64,
                            rejection.used,
                            rejection.limit,
                            rejection.requested,
                            rejection.bytes,
                            rejection.byte_limit,
                        ]),
                        source: Some([
                            crate::ffi::status(e) as u64,
                            1,
                            cache.0 as u64,
                            cache.1 as u64,
                            au.0 as u64,
                            au.1 as u64,
                            metadata.0 as u64,
                            metadata.1 as u64,
                        ]),
                        exits: [None; 2],
                        ..Default::default()
                    };
                    if let Some(child) = self.child.as_ref() {
                        record.exits = child.first_cause().exits;
                    }
                    self.first_ticket = crate::ffi::terminal_offer(record);
                }
            }
            #[cfg(feature = "qa")]
            if !self.first_diagnostics
                && self.terminal.is_none()
                && self.side == Side::Peer
                && matches!(self.stock, Some(stock::Source::PreparedFixture(_)))
            {
                // FIRST original service error and pre-retirement pool usage.
                // A numeric diagnostic on the existing exact-child stderr,
                // never a protocol message or a replacement error outcome.
                let code = match e {
                    Error::Protocol => 101,
                    Error::Capacity => 102,
                    Error::Deadline => 103,
                    Error::Clock => 104,
                    Error::Authentication => 105,
                    Error::Io => 106,
                    Error::Retired => 107,
                    Error::Unsupported => 108,
                    Error::WrongThread => 109,
                    Error::InvalidHandle => 110,
                    Error::Cleanup => 111,
                    Error::ClipboardAckMissing => 112,
                    Error::Codec => 113,
                    Error::UnrecoverableVideoGap => 114,
                    Error::ConnectTimeout => 115,
                    Error::PeerIdle => 116,
                    Error::ReliableStall => 117,
                };
                let cache = self.g1.cache.usage();
                let (au, metadata) = self.g1.receiver.usage();
                eprintln!(
                    "GBQS1 {} 1 {} {} {} {} {} {}",
                    code, cache.0, cache.1, au.0, au.1, metadata.0, metadata.1
                );
            }
            self.retire(e);
        }
        self.observe_progress();
        self.flush_recovery_trace(false);
        self.sample_send_stages(3);
        self.flush_send_stages();
        r
    }
    fn observe_progress(&mut self) {
        if self.send_stages.is_none() || self.terminal.is_some() {
            return;
        }
        let Ok(now) = self.now_ns() else {
            return;
        };
        let s = self.stats(Role::Media);
        let stage = self.send_stages.as_mut().unwrap();
        stage.progress.sample_with_pressure(
            self.binding.context.generation,
            if self.side == Side::Host { 1 } else { 2 },
            now,
            [
                s.datagrams_admitted,
                s.datagrams_generated,
                s.datagrams_udp_sent,
                s.udp_socket_received,
                s.datagrams_received,
            ],
            [
                // Span::snapshot includes the still-active portion in total_ns.
                // Do not add active_ns again or a held intake gets double-counted.
                s.pressure
                    .valid
                    .then_some(s.pressure.retained.duration.total_ns),
                s.pressure.valid.then_some(s.pressure.expiry_generated),
            ],
        );
        if let Some(child) = self.child.as_mut() {
            while let Some(line) = child.take_progress() {
                stage.peer_progress[line.0[3] as usize] = Some(line);
            }
        }
        #[cfg(feature = "qa")]
        if stage.hold_output {
            return;
        }
        // Leave at least every other low-priority emitter slot to the existing
        // recovery trace. A blocked sink retains only six maxima per origin.
        if stage
            .progress_last_offer
            .is_some_and(|last| now.saturating_sub(last) < 1_000 * MS)
        {
            return;
        }
        let mut offered = false;
        for peer in [stage.progress_peer_turn, !stage.progress_peer_turn] {
            if peer {
                if let Some(i) = (0..6)
                    .map(|n| (stage.progress_peer_kind + n) % 6)
                    .find(|&n| stage.peer_progress[n].is_some())
                {
                    if crate::ffi::progress_offer(stage.peer_progress[i].unwrap()) {
                        stage.peer_progress[i] = None;
                        stage.progress_peer_kind = (i + 1) % 6;
                        offered = true;
                    }
                }
            } else {
                offered = stage.progress.offer(crate::ffi::progress_offer);
            }
            if offered {
                stage.progress_peer_turn = !peer;
                break;
            }
        }
        if offered {
            stage.progress_last_offer = Some(now);
        }
    }
    fn sample_send_stages(&mut self, trigger: u64) {
        if self.send_stages.is_none() {
            return;
        }
        let Ok(now) = self.now_ns() else {
            return;
        };
        let s = self.stats(Role::Media);
        let p = s.path;
        let stage = self.send_stages.as_mut().unwrap();
        if stage.final_captured {
            return;
        }
        if trigger != 4 {
            if self.terminal.is_some() {
                return;
            }
            if stage.started.is_none() {
                if trigger == 3 && s.datagrams_admitted == 0 && s.datagrams_received == 0 {
                    return;
                }
                stage.started = Some(now);
            }
            if stage.captured >= 15 || now.saturating_sub(stage.started.unwrap()) > 3_000 * MS {
                return;
            }
            if trigger == 3
                && stage
                    .last
                    .is_some_and(|last| now.saturating_sub(last) < 250 * MS)
            {
                return;
            }
        } else {
            stage.final_captured = true;
        }
        stage.captured += 1;
        stage.last = Some(now);
        // At most16 local +16 strictly validated peer-origin records. No media
        // references or payloads are retained, and captures never wait on a sink.
        stage.pending.push_back(crate::recovery::SendStageLine([
            self.binding.context.generation,
            if self.side == Side::Host { 1 } else { 2 },
            stage.captured,
            now,
            trigger,
            s.datagrams_admitted,
            s.datagrams_generated,
            s.datagrams_udp_sent,
            s.datagram_queue_records as u64,
            s.generated_packets as u64,
            s.pressure.expiry_submission,
            s.pressure.expiry_queued,
            s.pressure.expiry_generated,
            s.pressure.quiche_done_pending_dg,
            s.pressure.future_send_stops,
            s.pressure.udp_would_block,
            u64::from(p.valid) | (u64::from(p.available) << 1) | (u64::from(p.rtt_available) << 2),
            p.sample_at_ns,
            p.rtt_ns,
            p.rttvar_ns,
            p.cwnd_bytes as u64,
            p.lost_packets,
            p.pto_count,
        ]));
    }
    fn flush_send_stages(&mut self) {
        let Some(stage) = self.send_stages.as_mut() else {
            return;
        };
        if let Some(child) = self.child.as_mut() {
            while let Some(line) = child.take_send_stage() {
                stage.pending.push_back(line);
            }
        }
        #[cfg(feature = "qa")]
        if stage.hold_output {
            return;
        }
        while let Some(line) = stage.pending.front().copied() {
            if !crate::ffi::send_stage_offer(line) {
                break;
            }
            stage.pending.pop_front();
        }
    }
    #[cfg(feature = "qa")]
    pub fn qa_hold_send_stage_output(&mut self) {
        if let Some(s) = self.send_stages.as_mut() {
            s.hold_output = true;
        }
    }
    #[cfg(feature = "qa")]
    pub fn qa_progress_observations(&mut self) -> Vec<[u64; 15]> {
        self.send_stages
            .as_mut()
            .map(|s| {
                s.peer_progress
                    .iter_mut()
                    .filter_map(Option::take)
                    .map(|l| l.0)
                    .collect()
            })
            .unwrap_or_default()
    }
    #[cfg(feature = "qa")]
    pub fn qa_send_stage_observations(&mut self) -> Vec<[u64; 23]> {
        self.send_stages
            .as_mut()
            .map(|s| s.pending.drain(..).map(|r| r.0).collect())
            .unwrap_or_default()
    }
    fn trace_request(
        &mut self,
        kind: u64,
        epoch: u32,
        config: u32,
        sequence: u64,
        id: u64,
        a: u64,
        b: u64,
    ) {
        if let Some(t) = self.g1.receiver.recovery_trace.as_mut() {
            t.push(galaxybridge_quic_media::media::recovery_trace::Event([
                kind,
                1,
                epoch as u64,
                config as u64,
                sequence,
                id,
                a,
                b,
            ]));
        }
    }
    /// Diagnostic-only scalar control-path breadcrumb. `Trace::update` keeps
    /// one latest record per stage so gesture bursts cannot evict the causal
    /// path before terminal cleanup flushes it.
    fn trace_control_stage(&mut self, stage: u64, sequence: u64, value: u64) {
        if let Some(trace) = self.g1.receiver.recovery_trace.as_mut() {
            trace.update(galaxybridge_quic_media::media::recovery_trace::Event([
                30, stage, 0, 0, 0, 0, sequence, value,
            ]));
        }
    }
    fn flush_recovery_trace(&mut self, final_flush: bool) {
        if self.g1.receiver.recovery_trace.is_none() || self.trace_final {
            return;
        }
        let Ok(now) = self.now_ns() else {
            return;
        };
        if !final_flush
            && self
                .trace_last_flush
                .is_some_and(|last| now.saturating_sub(last) < 500 * MS)
        {
            return;
        }
        self.trace_last_flush = Some(now);
        self.trace_final = final_flush;
        let trace = self.g1.receiver.recovery_trace.as_mut().unwrap();
        if final_flush || self.trace_counts != (trace.overwritten, trace.suppressed) {
            trace.update(galaxybridge_quic_media::media::recovery_trace::Event([
                0,
                0,
                0,
                0,
                0,
                0,
                trace.overwritten,
                trace.suppressed,
            ]));
            self.trace_counts = (trace.overwritten, trace.suppressed);
        }
        while self.trace_emitted < 512 {
            let Some((serial, event, foreign)) = trace.front() else {
                break;
            };
            let side = if foreign != 0 {
                2
            } else if self.side == Side::Host {
                1
            } else {
                2
            };
            let mut record = [0; 11];
            record[0] = self.binding.context.generation;
            record[1] = side;
            record[2] = if foreign == 0 { serial } else { foreign };
            record[3..].copy_from_slice(&event.0);
            if !crate::ffi::recovery_trace_offer(record) {
                trace.suppressed = trace.suppressed.saturating_add(1);
                break;
            }
            trace.pop();
            self.trace_emitted += 1;
        }
        if self.trace_emitted == 512 {
            trace.suppressed = trace.suppressed.saturating_add(1);
        }
    }
    #[cfg(feature = "qa")]
    pub fn qa_control_observation(&mut self) -> Option<[u64; 8]> {
        self.child
            .as_mut()
            .and_then(|child| child.qa_control_observation())
    }
    fn service(&mut self) -> Result<(), Error> {
        #[cfg(feature = "qa")]
        if let Some(trace) = self.service_trace.as_mut() {
            trace.clear();
        }
        use galaxybridge_quic_media::media::first_error;
        first_error::stage(line!());
        crate::process::poll_abandoned_cleanup();
        #[cfg(feature = "qa")]
        if self.whole_deadline.is_some_and(|d| Instant::now() >= d) {
            return Err(Error::Deadline);
        }
        if self.terminal.is_some() {
            first_error::reject(
                8,
                self.first_terminal_site.unwrap_or(line!()),
                0,
                0,
                0,
                0,
                0,
            );
            return Err(Error::Retired);
        }
        if self.startup.is_some() {
            self.service_bootstrap()?;
            return Ok(());
        }
        if let Some(child) = self.child.as_mut() {
            child.drain_stderr_observed(self.g1.receiver.recovery_trace.as_deref_mut())?;
            if self.side == Side::Peer {
                if self.binding.context.capture_kind == 1 {
                    self.display_pending
                        .extend(child.observe_display(&mut self.display_parser)?);
                } else {
                    child.drain_stdout()?;
                }
            }
            if child.exited()? {
                // Reap may race the first drain; consume exact remaining pipe bytes.
                let _ = child.drain_stderr_observed(self.g1.receiver.recovery_trace.as_deref_mut());
                if self.side == Side::Host {
                    self.first_ticket = child.emit_first_cause();
                }
                first_error::reject(8, line!(), 0, 0, 0, 0, 0);
                return Err(Error::Retired);
            }
        }
        let now = self.now_ns()?;
        if now < self.last {
            return Err(Error::Clock);
        }
        self.last = now;
        self.refresh_receiver_repair_margin();
        first_error::stage(line!());
        self.g1.tick(now)?;
        first_error::stage(line!());
        self.bulk.tick(now)?;
        if self.clipboard.is_some_and(|(_, d)| now >= d) {
            first_error::reject(10, line!(), 1, 0, 0, 0, 0);
            return Err(Error::ClipboardAckMissing);
        }
        if self.local_pending_deadline().is_some_and(|d| now >= d) {
            let reverse = self.reverse.len();
            let held = self
                .held
                .values()
                .filter(|h| {
                    matches!(
                        h,
                        Held::Device {
                            committed: false,
                            ..
                        }
                    )
                })
                .count();
            first_error::reject(
                11,
                line!(),
                reverse,
                held,
                usize::from(self.parser.started.is_some()),
                usize::from(self.reverse_issued.is_some()),
                self.events.len(),
            );
            return Err(Error::Deadline);
        }
        // Service the latency-critical input connection first on every turn.
        // Alternate media and bulk behind it so neither background lane can
        // starve the other while a gesture burst is in progress.
        for i in if self.poll_turn { [2, 1, 0] } else { [2, 0, 1] } {
            self.endpoints[i].poll().map_err(|_| Error::Io)?;
            if self.endpoints[i].stats().retired {
                // Module7 is endpoint retirement, not a capacity pool. This is
                // the first observed failed endpoint, not its sibling's health.
                use galaxybridge_quic::endpoint::Retirement;
                let stats = self.endpoints[i].stats();
                let fields = if self.first_diagnostics {
                    endpoint_terminal_rejection(i, stats, self.reliable_observations[i])
                } else {
                    [0; 5]
                };
                first_error::reject(
                    7,
                    (i + 1) as u32,
                    fields[0],
                    fields[1],
                    fields[2],
                    fields[3],
                    fields[4],
                );
                return Err(match stats.retirement {
                    Some(Retirement::Authentication) => Error::Authentication,
                    Some(Retirement::Protocol) => Error::Protocol,
                    Some(Retirement::ConnectTimeout) => Error::ConnectTimeout,
                    Some(Retirement::PeerIdle) => Error::PeerIdle,
                    Some(Retirement::ReliableStall) => Error::ReliableStall,
                    Some(Retirement::Io) => Error::Io,
                    _ => Error::Retired,
                });
            }
        }
        self.poll_turn = !self.poll_turn;
        self.pair_ready = self.endpoints.iter().all(|e| e.stats().application_ready);
        if !self.pair_ready && now >= self.pair_deadline {
            return Err(Error::Deadline);
        }
        if self.pair_ready && self.stock_deadline.is_none() {
            self.stock_deadline = Some(crate::deadline(now, crate::PHASE_LIFETIME)?);
        }
        if !self.ready && self.stock_deadline.is_some_and(|d| now >= d) {
            return Err(Error::Deadline);
        }
        let margin = self.refresh_receiver_repair_margin();
        let mut output_budget = 16;
        let mut media_handoff = self.offer_media(&mut output_budget)?;
        for i in 0..3 {
            for _ in 0..32 {
                if i == 0 && media_handoff {
                    break;
                }
                let Some(r) = self.endpoints[i].receive() else {
                    break;
                };
                let now = self.now_ns()?;
                #[cfg(feature = "qa")]
                self.trace_service([1, i as u64, 0, 0]);
                if r.payload.starts_with(b"GDS1") {
                    if i != 0 || self.side != Side::Host || r.lane != Lane::Reliable {
                        return Err(Error::Protocol);
                    }
                    let status = crate::bootstrap::decode_display(&self.binding, &r.payload)?;
                    // Exactly one assignment, optional conflict, one end. No
                    // hostile scalar flood may consume the ordinary event pool.
                    match (self.display_received, status.kind) {
                        (0, 1) => self.display_received = 1,
                        (1, 2) => self.display_received = 2,
                        (0..=2, 3) => self.display_received = 3,
                        _ => return Err(Error::Protocol),
                    }
                    self.event(Event::Display(status))?;
                } else if r.payload.starts_with(b"GQM1") {
                    let decoded =
                        Record::decode(r.lane, &r.payload).map_err(|_| Error::Protocol)?;
                    if i != message_route(&r.payload) {
                        return Err(Error::Protocol);
                    }
                    if decoded.kind == 8 {
                        self.trace_control_stage(2, decoded.sequence, now);
                    } else if decoded.kind == 10 {
                        self.trace_control_stage(5, decoded.sequence, now);
                    }
                    #[cfg(feature = "qa")]
                    if decoded.kind == 5 && decoded.track == 1 && decoded.sequence == 241 {
                        self.policy_observation[7] += 1;
                        self.policy_observation[9] = decoded.count as u64;
                        if decoded.index < 64 {
                            self.policy_observation[8] |= 1u64 << decoded.index;
                        }
                    }
                    #[cfg(feature = "qa")]
                    if let Some(filter) = self.drop_filter.as_mut() {
                        if decoded.kind == 5
                            && decoded.track == filter.track
                            && decoded.sequence == filter.sequence
                            && (filter.index == u16::MAX || decoded.index == filter.index)
                            && (filter.repeat || filter.dropped == 0)
                        {
                            filter.dropped =
                                filter.dropped.checked_add(1).ok_or(Error::Capacity)?;
                            continue;
                        }
                    }
                    let start = decoded.kind == 1;
                    if self.side == Side::Peer
                        && decoded.kind == 8
                        && self
                            .bulk
                            .incoming_barrier()
                            .is_some_and(|barrier| decoded.sequence > barrier)
                    {
                        return Err(Error::Protocol);
                    }
                    first_error::stage(line!());
                    if let Err(error) = self.g1.ingest(r, now, margin) {
                        // Preserve the exact authenticated record that caused a
                        // protocol failure when the media layer has no more
                        // specific rejection site.  This is diagnostic-only:
                        // the fixed scalar observation neither retains nor
                        // changes the incoming payload or admission result.
                        first_error::reject(
                            11,
                            line!(),
                            decoded.kind as usize,
                            decoded.track as usize,
                            ((decoded.index as usize) << 16) | decoded.count as usize,
                            decoded.sequence as usize,
                            ((decoded.epoch as usize) << 32) | decoded.config as usize,
                        );
                        return Err(error.into());
                    }
                    if decoded.kind == 7 && decoded.track == 1 {
                        self.discard_confirmed_video_copies(&decoded);
                    }
                    #[cfg(feature = "qa")]
                    {
                        if self.side == Side::Peer && matches!(decoded.kind, 6 | 7) {
                            self.source_admissions[if decoded.kind == 7 { 2 } else { 3 }] += 1;
                            if decoded.kind == 7 && matches!(decoded.track, 1 | 2) {
                                self.policy_observation[16 + decoded.track as usize] += 1;
                            }
                            if decoded.kind == 7 && decoded.track == 1 && decoded.sequence == 2 {
                                self.policy_observation[30] = 1;
                            }
                            if decoded.kind == 6 {
                                self.policy_observation[19] += 1;
                            }
                        }
                        let (usage, _) = self.g1.receiver.usage();
                        self.receive_peaks[0] = self.receive_peaks[0].max(usage.0);
                        self.receive_peaks[1] = self.receive_peaks[1].max(usage.1);
                        self.trace_service([
                            2,
                            decoded.kind as u64,
                            decoded.track as u64,
                            decoded.sequence,
                        ]);
                    }
                    if start {
                        self.remote_start = true;
                    }
                } else {
                    let expected_priority_route = message_route(&r.payload) == 2;
                    if (i == 2) != expected_priority_route {
                        return Err(Error::Protocol);
                    }
                    let b = bulk::Record::decode(
                        &r.payload,
                        if i == 1 { Role::Bulk } else { Role::Media },
                        self.side.opposite(),
                        r.lane,
                        self.binding.context.generation,
                    )?;
                    if i == 1 {
                        first_error::stage(line!());
                        self.bulk.ingest(b, now)?;
                    } else if b.kind == 3 {
                        stock::validate_device(&b.body)?;
                        let blob = if b.body[0] == 1 {
                            self.ack_pool.copy(&b.body)?
                        } else {
                            self.small_pool.copy(&b.body)?
                        };
                        self.reverse_insert(Object {
                            id: b.id,
                            purpose: 2,
                            barrier: b.barrier,
                            bytes: blob,
                            deadline: crate::deadline(now, 500 * MS)?,
                        })?;
                    } else if b.kind == 4 && self.binding.context.enabled & 5 == 5 {
                        // Receiver recovery clears old cache/expiry ownership.
                        // First honor any unconfirmed local initial loss so
                        // this cleanup cannot hide a later broken successor.
                        // Exact ACKs already ingested above still take priority.
                        self.handle_video_datagram_expiry(now)?;
                        let clock = (self.boottime)()?;
                        let previous = self.producer_map.pending_observation();
                        let outcome = self.admit_receiver_recovery(&b, clock)?;
                        if let Some((id, deadline, epoch, config, sequence)) = previous {
                            if clock >= deadline {
                                self.trace_request(
                                    9,
                                    epoch,
                                    config,
                                    sequence,
                                    id,
                                    2,
                                    clock - deadline,
                                );
                            }
                        }
                        self.trace_request(
                            7,
                            bulk::u32_at(&b.body, 0),
                            bulk::u32_at(&b.body, 4),
                            bulk::u64_at(&b.body, 8),
                            b.id,
                            match outcome {
                                crate::recovery::RecoveryAdmission::Queued => 1,
                                crate::recovery::RecoveryAdmission::Coalesced => 2,
                                crate::recovery::RecoveryAdmission::IgnoredSupersededRequest => 3,
                            },
                            clock,
                        );
                    } else {
                        return Err(Error::Protocol);
                    }
                }
                if i == 0 {
                    media_handoff = self.offer_media(&mut output_budget)?;
                }
            }
        }
        // A successfully ingested consumer ACK proves that this exact AU was
        // committed and released. Process received ACKs before treating an
        // expired queued copy as a new source loss; never wait for future ACKs.
        self.handle_video_datagram_expiry(self.now_ns()?)?;
        if self.pair_ready {
            while let Some(status) = self.display_pending.front().copied() {
                let bytes = crate::bootstrap::encode_display(&self.binding, status)?;
                if self.send(0, Lane::Reliable, bytes, u64::MAX)? == Admission::Backpressured {
                    break;
                }
                self.display_pending.pop_front();
            }
            if let Some(launch) = self.producer.take() {
                let command = launch.command_with_policy(&self.binding, self.producer_policy)?;
                let mut child =
                    OwnedChild::spawn_producer(&command, &launch.jar, self.slot.clone())?;
                child.observe_first_cause(
                    self.binding.context.generation,
                    self.binding.context.target_token,
                    2,
                );
                self.connector = Some(stock::Connector::new(
                    self.binding.context.scid,
                    self.binding.context.enabled,
                    child.id(),
                ));
                self.child = Some(child);
            }
            if let Some(connector) = self.connector.as_mut() {
                if let Some(stock) = connector.poll()? {
                    self.stock = Some(stock::Source::LiveStock(stock));
                    self.connector = None;
                }
            }
            if self.side == Side::Host {
                self.stock_ready = true;
            } else if let Some(stock) = self.stock.as_mut() {
                self.stock_ready = stock.consume_preamble()?;
            }
            let observation_ready = {
                #[cfg(feature = "qa")]
                {
                    !self.observation_gate || margin.is_some()
                }
                #[cfg(not(feature = "qa"))]
                {
                    true
                }
            };
            if self.stock_ready && !self.start_sent && observation_ready {
                let now = self.now_ns()?;
                self.start_token = Some(self.g1.queue_start(now)?);
                self.start_sent = true;
            }
            if self.stock_ready && self.remote_start && self.start_confirmed && !self.ready {
                self.ready = true;
                self.event(Event::Ready)?;
            }
            while let Some(o) = self.bulk.next_object(self.now_ns()?)? {
                if self.side == Side::Peer {
                    stock::validate_bulk_command(o.bytes.as_slice())?;
                    self.pending_bulk.push_back(o);
                } else {
                    stock::validate_device(o.bytes.as_slice())?;
                    self.reverse_insert(o)?;
                }
            }
            // G0 readiness does not order application datagrams behind G1
            // Start. Its existing MetadataCommit ACK is the evidence that the
            // opposite Receiver has admitted Start; keep source bytes in the
            // bounded stock socket until then, without restarting any timer.
            if self.ready && self.side == Side::Peer {
                first_error::stage(line!());
                self.service_stock()?;
            }
        }
        if self.side == Side::Host {
            for _ in 0..16 {
                let Some(_) = self.g1.receiver.disposition() else {
                    break;
                };
            }
            self.small.retain(|s| {
                s.record.purpose != 3
                    || self.g1.receiver.recovery_current(
                        bulk::u32_at(&s.record.body, 0),
                        bulk::u32_at(&s.record.body, 4),
                        bulk::u64_at(&s.record.body, 8),
                    )
            });
            if self.small.len() < 16 && !self.small.iter().any(|s| s.record.purpose == 3) {
                let now = self.now_ns()?;
                if let Some(context) = self.g1.receiver.publish_recovery(now)? {
                    if self.binding.context.enabled & 4 == 0 {
                        return Err(Error::Unsupported);
                    }
                    self.recovery_id = self.recovery_id.checked_add(1).ok_or(Error::Capacity)?;
                    self.trace_request(
                        6,
                        context.epoch,
                        context.config,
                        context.sequence,
                        self.recovery_id,
                        now,
                        context.deadline,
                    );
                    let mut body = Vec::with_capacity(16);
                    body.extend(context.epoch.to_be_bytes());
                    body.extend(context.config.to_be_bytes());
                    body.extend(context.sequence.to_be_bytes());
                    self.small.push_back(Small {
                        record: bulk::Record {
                            kind: 4,
                            purpose: 3,
                            generation: self.binding.context.generation,
                            id: self.recovery_id,
                            barrier: 0,
                            total: 16,
                            offset: 0,
                            age_us: 0,
                            body,
                        },
                        deadline: context.deadline,
                    });
                }
            }
            self.offer_media(&mut output_budget)?;
            if self.reverse_issued.is_none() {
                if let Some(o) = self.reverse.remove(&self.reverse_next) {
                    if o.bytes.as_slice()[0] == 1 {
                        self.reserve_progress()?;
                    } else {
                        self.reserve(false)?;
                    }
                    self.reverse_issued = Some(o.id);
                    let id = self.token()?;
                    let ordinal = o.id;
                    self.held.insert(
                        id,
                        Held::Device {
                            object: o,
                            committed: false,
                        },
                    );
                    self.event(Event::Device {
                        handle: id,
                        ordinal,
                    })?;
                }
            }
        }
        if self.pair_ready {
            self.send_records()?;
            #[cfg(feature = "qa")]
            self.trace_service([4, 0, 0, 0]);
        }
        self.collect_results()?;
        #[cfg(feature = "qa")]
        self.trace_service([5, 0, 0, 0]);
        Ok(())
    }
    /// Transfer only existing eligible output. One shared per-service output
    /// budget covers all probes; a successful transfer yields the media batch,
    /// not the remaining control/bulk/timer/send work in this service turn.
    fn offer_media(&mut self, budget: &mut usize) -> Result<bool, Error> {
        if self.side != Side::Host {
            return Ok(false);
        }
        let mut offered = false;
        while *budget > 0 {
            galaxybridge_quic_media::media::first_error::stage(line!());
            self.reserve(false)?;
            let now = self.now_ns()?;
            let Some(lease) = self.g1.receiver.next_output(now)? else {
                break;
            };
            #[cfg(feature = "qa")]
            if lease.record.track == 1 && lease.record.sequence == 241 {
                if lease.record.kind == 4 {
                    self.policy_observation[10] += 1;
                }
                if lease.record.kind == 5 {
                    self.policy_observation[11] += 1;
                }
            }
            let id = self.token()?;
            #[cfg(feature = "qa")]
            let trace = [
                3,
                lease.record.kind as u64,
                lease.record.track as u64,
                lease.record.sequence,
            ];
            self.held.insert(id, Held::Media(lease));
            self.event(Event::Media { handle: id })?;
            *budget -= 1;
            offered = true;
            #[cfg(feature = "qa")]
            self.trace_service(trace);
        }
        Ok(offered)
    }
    fn collect_results(&mut self) -> Result<(), Error> {
        for _ in 0..16 {
            let Some(c) = self.bulk.completion() else {
                break;
            };
            if self.promised.remove(&(3, c.id)) {
                self.event(Event::BulkComplete(c))?;
            }
        }
        for _ in 0..16 {
            let Some(c) = self.g1.transactions.next_transaction_result() else {
                break;
            };
            if self.terminal.is_none() && self.start_token == Some(c.token) {
                if c.outcome
                    != galaxybridge_quic_media::Outcome::PeerBoundaryConfirmed(
                        galaxybridge_quic_media::Confirmation::MetadataCommit,
                    )
                {
                    return Err(Error::Deadline);
                }
                self.start_confirmed = true;
            }
            if self.promised.remove(&(1, c.token)) {
                self.event(Event::Transaction(c))?;
            }
        }
        Ok(())
    }
    fn reverse_insert(&mut self, o: Object) -> Result<(), Error> {
        if o.id < self.reverse_next
            || self.reverse_issued == Some(o.id)
            || o.barrier != o.id - 1
            || self.reverse.len() >= 16
            || self.reverse.contains_key(&o.id)
        {
            return Err(Error::Protocol);
        }
        self.reverse.insert(o.id, o);
        Ok(())
    }
    fn send(
        &mut self,
        index: usize,
        lane: Lane,
        payload: Vec<u8>,
        deadline: u64,
    ) -> Result<Admission, Error> {
        self.send_observed(index, lane, payload, deadline)
            .map(|(admission, _)| admission)
    }
    fn send_observed(
        &mut self,
        index: usize,
        lane: Lane,
        payload: Vec<u8>,
        deadline: u64,
    ) -> Result<(Admission, u64), Error> {
        let sequence = advance_outer(&mut self.outer[index])?;
        let d = self
            .origin
            .checked_add(Duration::from_nanos(deadline))
            .ok_or(Error::Clock)?;
        let observation = (self.first_diagnostics && lane == Lane::Reliable)
            .then(|| reliable_observation(&payload));
        let admission = self.endpoints[index].send(
            Message {
                lane,
                sequence,
                payload,
            },
            d,
        );
        if admission == Admission::Accepted {
            if let Some(observation) = observation {
                self.reliable_observations[index] = Some(observation);
            }
        }
        Ok((admission, sequence))
    }
    fn handle_video_datagram_expiry(&mut self, now: u64) -> Result<(), Error> {
        let mut lost = None::<Record>;
        while let Some(expiry) = self.endpoints[0].take_datagram_expiry() {
            if let Some(tracked) = self.video_datagrams.remove(&expiry.sequence) {
                if !tracked.repair
                    && lost
                        .as_ref()
                        .is_none_or(|record| tracked.record.sequence < record.sequence)
                {
                    lost = Some(tracked.record);
                }
            }
        }
        let Some(lost) = lost else {
            self.video_datagrams
                .retain(|_, tracked| now < tracked.deadline);
            return Ok(());
        };

        // A missing fragment invalidates the whole video AU and every dependent
        // AU already queued behind it. Audio and the independent input endpoint
        // stay live while the producer emits one fresh independently decodable
        // frame.
        self.discard_pending_video_for_recovery(lost.sequence, now);

        if self.side == Side::Peer {
            self.recovery_id = self.recovery_id.checked_add(1).ok_or(Error::Capacity)?;
            let boottime = (self.boottime)()?;
            match self.producer_map.request_local(
                lost.epoch,
                lost.config,
                lost.sequence,
                self.recovery_id,
                boottime,
            ) {
                Ok(_) | Err(Error::Retired) => {}
                Err(error) => return Err(error),
            }
        }
        Ok(())
    }
    fn discard_confirmed_video_copies(&mut self, ack: &Record) {
        let confirmed = self
            .video_datagrams
            .iter()
            .filter_map(|(sequence, tracked)| {
                let r = &tracked.record;
                (r.generation == ack.generation
                    && r.track == ack.track
                    && r.epoch == ack.epoch
                    && r.config == ack.config
                    && r.sequence == ack.sequence)
                    .then_some(*sequence)
            })
            .collect::<BTreeSet<_>>();
        self.endpoints[0].discard_datagrams(|sequence| confirmed.contains(&sequence));
        self.video_datagrams
            .retain(|sequence, _| !confirmed.contains(sequence));
        // Do not drain the expiry queue here: an unrelated initial copy may
        // still need recovery. Its tracker remains for the normal expiry pass.
    }
    fn discard_pending_video_for_recovery(&mut self, lost_sequence: u64, now: u64) {
        self.g1.cache.expire(now);
        self.g1.discard_source_video_for_recovery(lost_sequence);
        let stale = self
            .video_datagrams
            .iter()
            .filter_map(|(transport_sequence, tracked)| {
                if self.g1.cache.contains_video_access_unit(&tracked.record) {
                    None
                } else {
                    Some(*transport_sequence)
                }
            })
            .collect::<BTreeSet<_>>();
        self.endpoints[0].discard_datagrams(|sequence| stale.contains(&sequence));
        while self.endpoints[0].take_datagram_expiry().is_some() {}
        self.video_datagrams
            .retain(|sequence, _| !stale.contains(sequence));
    }
    fn send_records(&mut self) -> Result<(), Error> {
        let mut reliable = 0;
        let mut issued = 0;
        for _ in 0..32 {
            let now = self.now_ns()?;
            let mut policy = DispatchPolicy::default();
            policy.critical_through = self.bulk.fence();
            policy.moves = policy.critical_through.is_none();
            if reliable >= 4 {
                policy.feedback = false;
                policy.metadata = false;
                policy.critical_through = Some(0);
            }
            let Some(d) = self.g1.next_transport_record_with_policy(now, policy) else {
                break;
            };
            let lane = d.message.lane;
            let trace_control_ack = self.g1.receiver.recovery_trace.as_ref().and_then(|_| {
                (d.message.payload.len() >= 64 && d.message.payload[4] == 10)
                    .then(|| bulk::u64_at(&d.message.payload, 24))
            });
            let trace_fragment = if self.g1.receiver.recovery_trace.is_some()
                && d.message.payload.len() >= 64
                && d.message.payload[4] == 5
                && d.message.payload[5] == 1
            {
                Some((
                    bulk::u32_at(&d.message.payload, 16),
                    bulk::u32_at(&d.message.payload, 20),
                    bulk::u64_at(&d.message.payload, 24),
                    u16::from_be_bytes([d.message.payload[46], d.message.payload[47]]) as u64,
                ))
            } else {
                None
            };
            #[cfg(feature = "qa")]
            let target = if d.message.payload.len() >= 64
                && d.message.payload[4] == 5
                && d.message.payload[5] == 1
                && bulk::u64_at(&d.message.payload, 24) == 241
            {
                Some(u16::from_be_bytes([
                    d.message.payload[46],
                    d.message.payload[47],
                ]))
            } else {
                None
            };
            issued += 1;
            let route = message_route(&d.message.payload);
            let video = (route == 0 && lane == Lane::Datagram)
                .then(|| Record::decode(lane, &d.message.payload).ok())
                .flatten()
                .filter(|record| record.kind == 5 && record.track == 1)
                .map(|record| record.with_body(Vec::new()));
            if route == 0 && is_reliable_video_recovery(lane, &d.message.payload) {
                #[cfg(feature = "qa")]
                {
                    self.policy_observation[31] = self.policy_observation[31]
                        .checked_add(1)
                        .ok_or(Error::Capacity)?;
                }
                self.endpoints[0].prioritize_reliable_generation();
            }
            let (a, transport_sequence) =
                self.send_observed(route, lane, d.message.payload, d.deadline)?;
            if a == Admission::Accepted {
                if let Some(record) = video {
                    self.video_datagrams.insert(
                        transport_sequence,
                        VideoDatagram {
                            record,
                            deadline: d.deadline,
                            repair: d.media_repair,
                        },
                    );
                }
            }
            if let Some(sequence) = trace_control_ack {
                self.trace_control_stage(4, sequence, u64::from(a == Admission::Accepted));
            }
            if let Some((epoch, config, sequence, count)) = trace_fragment {
                self.g1.receiver.trace_fragment_admission(
                    epoch,
                    config,
                    sequence,
                    count,
                    a == Admission::Accepted,
                );
            }
            #[cfg(feature = "qa")]
            if let Some(count) = target {
                if a == Admission::Accepted {
                    self.policy_observation[5] += 1;
                }
                self.policy_observation[6] = count as u64;
            }
            self.g1
                .transport_admission(d.record_token, a, self.now_ns()?)?;
            if lane == Lane::Reliable {
                reliable += 1;
            }
            if a == Admission::Backpressured {
                break;
            }
        }
        for _ in 0..(32 - issued) {
            let now = self.now_ns()?;
            let Some(s) = self.small.front() else {
                break;
            };
            if now >= s.deadline {
                if s.record.purpose == 3 {
                    let r = self.small.pop_front().unwrap().record;
                    self.trace_request(
                        8,
                        bulk::u32_at(&r.body, 0),
                        bulk::u32_at(&r.body, 4),
                        bulk::u64_at(&r.body, 8),
                        r.id,
                        2,
                        now,
                    );
                    continue;
                }
                return Err(Error::Deadline);
            }
            let b = s.record.encode(Role::Media, self.side)?;
            let d = s.deadline;
            let a = self.send(message_route(&b), Lane::Reliable, b, d)?;
            match a {
                Admission::Accepted => {
                    let r = self.small.pop_front().unwrap().record;
                    if r.purpose == 3 {
                        self.trace_request(
                            8,
                            bulk::u32_at(&r.body, 0),
                            bulk::u32_at(&r.body, 4),
                            bulk::u64_at(&r.body, 8),
                            r.id,
                            1,
                            now,
                        );
                    }
                }
                Admission::Backpressured => break,
                _ => return Err(Error::Retired),
            }
        }
        for _ in 0..32 {
            let now = self.now_ns()?;
            let Some(r) = self.bulk.next_record(now)? else {
                break;
            };
            let b = r.encode(Role::Bulk, self.side)?;
            let d = self
                .bulk
                .next_deadline()
                .unwrap_or(crate::deadline(now, 500 * MS)?);
            let a = self.send(1, Lane::Reliable, b, d)?;
            self.bulk.admission(a, self.now_ns()?)?;
            if a == Admission::Backpressured {
                break;
            }
        }
        Ok(())
    }
    #[cfg(any(target_os = "android", test))]
    fn adaptive_primary(
        binding: &Binding,
        launch: &stock::ProducerLaunch,
        policy: Option<stock::LaunchPolicy>,
    ) -> bool {
        binding.context.capture_kind == 0
            && binding.context.display_id == 0
            && binding.context.enabled & 5 == 5
            && launch.new_display.is_none()
            && matches!(
                policy,
                Some(stock::LaunchPolicy::Primary | stock::LaunchPolicy::PrimaryCleanup { .. })
            )
    }
    fn sample_quality(&mut self, now: u64) -> Result<(), Error> {
        self.apply_quality_sample(now, self.stats(Role::Media))
    }
    fn apply_quality_sample(
        &mut self,
        now: u64,
        stats: galaxybridge_quic::endpoint::Stats,
    ) -> Result<(), Error> {
        let Some((epoch, config)) = self.producer_map.identity() else {
            return Ok(());
        };
        let Some(controller) = self.quality.as_mut() else {
            return Ok(());
        };
        if let Some(target) = controller.sample(now, self.quality_video, stats) {
            let ceiling = controller.ceiling();
            self.queue_quality_request(epoch, config, target, ceiling)?;
        }
        Ok(())
    }
    fn queue_quality_request(
        &mut self,
        epoch: u64,
        config: u64,
        target: u32,
        ceiling: u32,
    ) -> Result<(), Error> {
        self.quality_id = self.quality_id.checked_add(1).ok_or(Error::Capacity)?;
        self.quality_pending = Some(crate::quality::Request::new(
            epoch,
            config,
            self.quality_id,
            (self.boottime)()?,
            target,
            ceiling,
        )?);
        Ok(())
    }
    fn queue_receiver_recovery_quality(&mut self, now: u64) -> Result<(), Error> {
        let Some((epoch, config)) = self.producer_map.identity() else {
            return Ok(());
        };
        let Some(controller) = self.quality.as_mut() else {
            return Ok(());
        };
        let ceiling = controller.ceiling();
        let Some(target) = controller.receiver_recovery(now) else {
            return Ok(());
        };
        self.queue_quality_request(epoch, config, target, ceiling)?;
        self.producer_map.reserve_preceding_rate_window()?;
        self.quality_precedes_recovery = true;
        Ok(())
    }
    fn admit_receiver_recovery(
        &mut self,
        record: &bulk::Record,
        now: u64,
    ) -> Result<crate::recovery::RecoveryAdmission, Error> {
        let outcome = self.producer_map.admit(record, now)?;
        if outcome == crate::recovery::RecoveryAdmission::Queued {
            // The receiver already proved that its decode chain has a hole.
            // Do not let queued dependent deltas compete with the replacement
            // keyframe, even when they have not expired on this sender.
            self.discard_pending_video_for_recovery(
                crate::bulk::u64_at(&record.body, 8),
                self.now_ns()?,
            );
            self.queue_receiver_recovery_quality(now)?;
        }
        Ok(outcome)
    }
    fn service_stock(&mut self) -> Result<(), Error> {
        let now = self.now_ns()?;
        galaxybridge_quic_media::media::first_error::stage(line!());
        self.sample_quality(now)?;
        if matches!(self.writing, Some(Writing::Bitrate(_, 0))) {
            // Entirely unwritten rate work yields to input/sync before selection.
            if let Some(Writing::Bitrate(r, 0)) = self.writing.take() {
                if self.quality_pending.is_none() {
                    self.quality_pending = Some(r);
                }
            }
        }
        if self.writing.is_none() {
            if self.g1.receiver.control.draining_geometry() {
                if let Some(lease) = self.g1.receiver.control.next_write(now) {
                    self.writing = Some(Writing::G1(lease));
                }
            } else if self
                .pending_bulk
                .front()
                .is_some_and(|o| self.g1.receiver.control.applied() >= o.barrier)
            {
                self.writing = Some(Writing::Bulk(self.pending_bulk.pop_front().unwrap(), 0));
            } else if let Some(l) = self.g1.receiver.control.next_write(now) {
                self.writing = Some(Writing::G1(l));
            }
        }
        if self.writing.is_none() && self.quality_precedes_recovery {
            if let Some(request) = self.quality_pending.take() {
                if request.current(self.producer_map.identity())
                    && (self.boottime)()? < request.deadline
                {
                    self.writing = Some(Writing::Bitrate(request, 0));
                } else {
                    self.quality_precedes_recovery = false;
                }
            } else {
                self.quality_precedes_recovery = false;
            }
        }
        if self.writing.is_none() {
            if self.producer_map.pending() {
                let observation = self.producer_map.pending_observation();
                let now = (self.boottime)()?;
                if let Some(request) = self.producer_map.take(now) {
                    self.writing = Some(Writing::Recovery(request, 0));
                } else if let Some((id, deadline, epoch, config, sequence)) = observation {
                    self.trace_request(
                        9,
                        epoch,
                        config,
                        sequence,
                        id,
                        2,
                        now.saturating_sub(deadline),
                    );
                }
            } else if let Some(request) = self.quality_pending.take() {
                if request.current(self.producer_map.identity())
                    && (self.boottime)()? < request.deadline
                {
                    self.writing = Some(Writing::Bitrate(request, 0));
                }
            }
        }
        if let Some(Writing::Bitrate(r, 0)) = &self.writing {
            if !r.current(self.producer_map.identity()) || (self.boottime)()? >= r.deadline {
                self.writing = None;
                if self.quality_pending.is_none() {
                    self.quality_precedes_recovery = false;
                }
            }
        }
        if let Some(w) = self.writing.as_mut() {
            let (bytes, offset, deadline) = match w {
                Writing::G1(l) => (l.bytes.as_slice(), l.offset, l.deadline),
                Writing::Bulk(o, n) => (o.bytes.as_slice(), *n, o.deadline),
                Writing::Recovery(r, n) => {
                    if !self.producer_map.is_current(r) {
                        return Err(Error::Retired);
                    }
                    if (self.boottime)()? >= r.deadline {
                        return Err(Error::Deadline);
                    }
                    (r.bytes.as_slice(), *n, u64::MAX)
                }
                Writing::Bitrate(r, n) => {
                    if *n > 0 {
                        if !r.current(self.producer_map.identity()) {
                            return Err(Error::Retired);
                        }
                        if (self.boottime)()? >= r.deadline {
                            return Err(Error::Deadline);
                        }
                    }
                    (r.bytes.as_slice(), *n, u64::MAX)
                }
            };
            if now >= deadline {
                return Err(Error::Deadline);
            }
            let limit = {
                #[cfg(feature = "qa")]
                {
                    self.write_limit
                }
                #[cfg(not(feature = "qa"))]
                {
                    8192
                }
            };
            galaxybridge_quic_media::media::first_error::stage(line!());
            let n = self
                .stock
                .as_mut()
                .unwrap()
                .write(&bytes[offset..(offset + limit).min(bytes.len())])?;
            let complete = offset + n == bytes.len();
            let now = self.now_ns()?;
            let mut recovery_complete = None;
            let mut rate_refused = false;
            let mut control_complete = None;
            match self.writing.as_mut().unwrap() {
                Writing::G1(l) => {
                    if n > 0 {
                        let outcome = self.g1.receiver.control_write_result(l.token, n, now)?;
                        if let galaxybridge_quic_media::control::WriteOutcome::Complete {
                            sequence,
                            ..
                        } = outcome
                        {
                            control_complete = Some(sequence);
                        }
                        l.offset += n;
                    }
                }
                Writing::Bulk(o, nwritten) => {
                    *nwritten += n;
                    if now >= o.deadline {
                        return Err(Error::Deadline);
                    }
                    if complete {
                        self.bulk.applied(o, now)?;
                    }
                }
                Writing::Recovery(request, nwritten) => {
                    *nwritten += n;
                    if (self.boottime)()? >= request.deadline {
                        return Err(Error::Deadline);
                    }
                    if complete {
                        self.producer_map
                            .sync_submitted(request, (self.boottime)()?)?;
                        recovery_complete = Some((request.id, request.identity));
                    }
                }
                Writing::Bitrate(request, nwritten) => {
                    *nwritten += n;
                    if (self.boottime)()? >= request.deadline {
                        if *nwritten == 0 {
                            rate_refused = true;
                        } else {
                            return Err(Error::Deadline);
                        }
                    }
                    if complete {
                        self.quality_submitted = Some(request.target);
                    }
                }
            }
            if let Some(sequence) = control_complete {
                self.trace_control_stage(3, sequence, now);
            }
            if let Some((id, (epoch, config, sequence))) = recovery_complete {
                self.trace_request(9, epoch, config, sequence, id, 1, now);
                if let Some(t) = self.g1.receiver.recovery_trace.as_mut() {
                    t.watch(id, epoch, config);
                }
            }
            if complete || rate_refused {
                self.writing = None;
                if self.quality_pending.is_none() {
                    self.quality_precedes_recovery = false;
                }
            }
        }
        // At most one partial media record is fed to the shared G1 source pool.
        let track = self.active_track.unwrap_or(self.track_turn);
        self.track_turn = if self.track_turn == 1 { 2 } else { 1 };
        if self.binding.context.enabled & (1 << (track - 1)) != 0 {
            self.read_stock(track)?;
        }
        if self.binding.context.enabled & 4 != 0 {
            self.read_stock(3)?;
        }
        Ok(())
    }
    fn read_stock(&mut self, track: u8) -> Result<(), Error> {
        galaxybridge_quic_media::media::first_error::stage(line!());
        let index = (track - 1) as usize;
        let mut bytes = std::mem::take(&mut self.buffers[index]);
        if bytes.is_empty() {
            let mut b = [0; 8192];
            if let Some(n) = self.stock.as_mut().unwrap().read(track, &mut b)? {
                bytes.extend_from_slice(&b[..n]);
            }
        }
        let mut at = 0;
        for _ in 0..32 {
            if at == bytes.len() && self.g1.deferred_stock_track() != Some(track) {
                break;
            }
            let now = self.now_ns()?;
            if track <= 2 {
                let (n, a, publication) =
                    self.g1
                        .ingest_stock_observed_deferred(track, &bytes[at..], now)?;
                if let Some(publication) = publication {
                    let recovery = self.producer_map.publication(publication)?;
                    if publication.kind == 5
                        && publication.track == 1
                        // A valid independent AU can precede sync submission
                        // (for example in the bitrate-first owner turn).
                        // Keep it even without producer-request correlation.
                        && !publication.independent
                        && self.producer_map.active()
                        && !recovery
                    {
                        self.g1.discard_source_video_sequence_for_recovery(
                            self.binding.context.generation,
                            publication.sequence,
                        );
                    }
                    if recovery
                        && matches!(
                            a,
                            galaxybridge_quic_media::stock::Admission::AccessUnit { sequence }
                                if sequence == publication.sequence
                        )
                    {
                        // A producer-correlated replacement IDR is still video:
                        // keep it on the expiring datagram/FEC path. Promoting a
                        // large IDR to QUIC stream data makes one lost recovery
                        // packet head-of-line block the entire media session and
                        // eventually retire it as ReliableStall. If this IDR is
                        // incomplete, the receiver requests another fresh IDR;
                        // it never waits behind stream retransmissions.
                        self.g1.cache.supersede_video_before(
                            self.binding.context.generation,
                            publication.sequence,
                        );
                    }
                    if publication.track == 1 && matches!(publication.kind, 3 | 4) {
                        self.quality_pending = None;
                        self.quality_precedes_recovery = false;
                        if let Some(q) = self.quality.as_mut() {
                            q.discontinuity();
                        }
                    }
                    if publication.kind == 5
                        && (self
                            .send_stages
                            .as_ref()
                            .is_some_and(|s| s.started.is_none())
                            || publication.independent)
                    {
                        self.sample_send_stages(if publication.independent { 2 } else { 1 });
                    }
                }
                if track == 1
                    && matches!(
                        a,
                        galaxybridge_quic_media::stock::Admission::AccessUnit { .. }
                    )
                {
                    self.quality_video =
                        self.quality_video.checked_add(1).ok_or(Error::Capacity)?;
                }
                #[cfg(feature = "qa")]
                match a {
                    galaxybridge_quic_media::stock::Admission::AccessUnit { sequence } => {
                        self.source_admissions[0] += 1;
                        self.policy_observation[index] += 1;
                        if track == 1 && sequence == 241 {
                            self.policy_observation[4] = 1;
                        }
                    }
                    galaxybridge_quic_media::stock::Admission::DroppedAccessUnit {
                        sequence,
                        reason,
                    } => {
                        self.source_admissions[1] += 1;
                        self.policy_observation[index + 2] += 1;
                        if track == 1 && sequence == 241 {
                            self.policy_observation[4] =
                                if reason == galaxybridge_quic_media::Failure::Capacity {
                                    2
                                } else {
                                    3
                                };
                        }
                    }
                    _ => {}
                }
                at += n;
                self.active_track =
                    if matches!(a, galaxybridge_quic_media::stock::Admission::Incomplete)
                        && self.g1.deferred_stock_track() != Some(track)
                    {
                        Some(track)
                    } else {
                        None
                    };
                if n == 0 {
                    break;
                }
            } else {
                let start = self.parser.started.unwrap_or(now);
                let (n, event) = self.parser.push_with_pools(
                    &bytes[at..],
                    &self.bulk.outgoing_pool,
                    &self.small_pool,
                    &self.ack_pool,
                    now,
                )?;
                at += n;
                if let Some(blob) = event {
                    self.reverse_sent = self.reverse_sent.checked_add(1).ok_or(Error::Capacity)?;
                    if blob.as_slice()[0] == 0 || blob.len() > 976 {
                        self.bulk.queue_blob(
                            self.reverse_sent,
                            self.reverse_sent - 1,
                            blob,
                            start,
                            now,
                        )?;
                    } else {
                        if self.small.len() >= 16 {
                            return Err(Error::Capacity);
                        }
                        self.small.push_back(Small {
                            record: bulk::Record {
                                kind: 3,
                                purpose: 2,
                                generation: self.binding.context.generation,
                                id: self.reverse_sent,
                                barrier: self.reverse_sent - 1,
                                total: blob.len() as u32,
                                offset: 0,
                                age_us: 0,
                                body: blob.as_slice().to_vec(),
                            },
                            deadline: crate::deadline(start, 500 * MS)?,
                        });
                    }
                }
                if n == 0 {
                    break;
                }
            }
        }
        bytes.drain(..at);
        self.buffers[index] = bytes;
        Ok(())
    }
    pub fn next_wakeup(&self) -> Duration {
        if self.terminal.is_some() {
            return Duration::from_millis(10);
        }
        if self
            .events
            .iter()
            .any(|event| matches!(event, Event::Media { .. }))
        {
            return Duration::ZERO;
        }
        let now = self.now_ns().unwrap_or(u64::MAX);
        let mut d = self
            .endpoints
            .iter()
            .map(Endpoint::next_wakeup)
            .min()
            .unwrap_or(Duration::from_millis(1));
        for deadline in self
            .g1
            .next_wakeup()
            .into_iter()
            .chain(self.bulk.next_deadline())
            .chain(self.clipboard.map(|(_, d)| d))
            .chain(self.small.front().map(|s| s.deadline))
            .chain(self.local_pending_deadline())
            .chain(if self.startup.is_some() {
                Some(crate::PHASE_LIFETIME)
            } else if !self.pair_ready {
                Some(self.pair_deadline)
            } else if !self.stock_ready {
                self.stock_deadline
            } else {
                None
            })
        {
            d = d.min(Duration::from_nanos(deadline.saturating_sub(now)));
        }
        #[cfg(feature = "qa")]
        if let Some(deadline) = self.whole_deadline {
            d = d.min(deadline.saturating_duration_since(Instant::now()));
        }
        d
    }
    fn local_pending_deadline(&self) -> Option<u64> {
        self.reverse
            .values()
            .map(|o| o.deadline)
            .chain(self.held.values().filter_map(|h| match h {
                Held::Device {
                    object,
                    committed: false,
                } => Some(object.deadline),
                _ => None,
            }))
            .chain(
                self.parser
                    .started
                    .and_then(|n| n.checked_add(crate::BULK_LIFETIME)),
            )
            .min()
    }
    pub fn retire(&mut self, e: Error) {
        if self.terminal.is_some() {
            return;
        }
        self.flush_recovery_trace(true);
        self.sample_send_stages(4);
        self.flush_send_stages();
        if let Some(stage) = self.send_stages.as_mut() {
            stage.finish_progress();
        }
        self.flush_terminal_progress();
        #[cfg(feature = "qa")]
        if self.side == Side::Host || matches!(self.stock, Some(stock::Source::PreparedFixture(_)))
        {
            let values = self
                .qa_policy_snapshot()
                .iter()
                .map(u64::to_string)
                .collect::<Vec<_>>()
                .join(" ");
            eprintln!(
                "{} {}",
                if self.side == Side::Host {
                    "qa-host-policy"
                } else {
                    "GBQHP1"
                },
                values
            );
        }
        self.terminal = Some(e);
        if self.side == Side::Host
            && self.binding.context.capture_kind == 1
            && self.display_received != 3
        {
            self.display_received = 3;
            let _ = self.event(Event::Display(crate::process::DisplayStatus::scalar(3)));
        }
        self.ready = false;
        self.g1.retire(galaxybridge_quic_media::Failure::Retired);
        self.bulk.retire();
        // Completion reservations transfer to result events; accepted work
        // keeps UnknownRemoteOutcome instead of vanishing at joint retirement.
        let _ = self.collect_results();
        for endpoint in &mut self.endpoints {
            endpoint.close();
        }
        self.stock = None;
        self.connector = None;
        self.producer = None;
        self.display_pending.clear();
        let _ = self.display_parser.finish();
        self.writing = None;
        self.pending_bulk.clear();
        self.small.clear();
        self.reverse.clear();
        self.reverse_issued = None;
        self.clipboard = None;
        self.producer_map.clear();
        self.video_datagrams.clear();
        self.quality_pending = None;
        self.quality_precedes_recovery = false;
        self.quality = None;
        self.startup = None;
        if let Some(child) = self.child.as_mut() {
            child.stop();
        }
        let _ = self.event(Event::Retired(e));
    }
    pub fn cleanup(&mut self) -> Result<Cleanup, Error> {
        if self.terminal.is_none() {
            return Err(Error::Protocol);
        }
        self.flush_terminal_progress();
        match self.child.as_mut() {
            Some(child) => {
                let result = child.cleanup();
                if self.side == Side::Host {
                    if let Some(ticket) = child.emit_first_cause() {
                        self.first_ticket = Some(ticket);
                    }
                }
                result
            }
            None => Ok(Cleanup {
                complete: true,
                ..Default::default()
            }),
        }
    }
    fn flush_terminal_progress(&mut self) {
        let Some(stage) = self.send_stages.as_mut() else {
            return;
        };
        let Some(lines) = stage.terminal_progress else {
            return;
        };
        if lines.iter().all(Option::is_none) {
            stage.terminal_progress = None;
            return;
        }
        let mut record = crate::ffi::TerminalRecord::default();
        record.progress = lines;
        if let Some(ticket) = crate::ffi::terminal_offer(record) {
            self.first_ticket = Some(ticket);
            stage.terminal_progress = None;
            stage.peer_progress = [None; 6];
        }
    }
    /// CLI-only diagnostic completion; no media/cleanup result is changed.
    pub fn first_cause_pending(&self) -> bool {
        self.first_ticket
            .as_ref()
            .is_some_and(|t| !t.load(Ordering::Acquire))
            || self
                .send_stages
                .as_ref()
                .is_some_and(|s| s.terminal_progress.is_some())
    }
    pub fn observe_lifetime_eof(&mut self) {
        if !self.first_diagnostics || self.first_reported {
            return;
        }
        self.first_reported = true;
        self.first_ticket = crate::ffi::terminal_offer(crate::ffi::TerminalRecord {
            exits: [
                Some([
                    self.binding.context.generation,
                    if self.side == Side::Peer { 2 } else { 1 },
                    1,
                    0,
                ]),
                None,
            ],
            ..Default::default()
        });
    }
    pub fn cleanup_report(&self) -> Cleanup {
        self.child
            .as_ref()
            .map(OwnedChild::report)
            .unwrap_or(Cleanup {
                complete: self.terminal.is_some(),
                ..Default::default()
            })
    }
    #[cfg(feature = "qa")]
    pub fn qa_first_source_error(&self) -> Option<[u64; 8]> {
        self.child
            .as_ref()
            .and_then(OwnedChild::qa_first_source_error)
    }
    #[cfg(feature = "qa")]
    pub fn qa_first_cause(&self) -> (Option<[u64; 13]>, [Option<[u64; 4]>; 2]) {
        self.child
            .as_ref()
            .map(OwnedChild::qa_first_cause)
            .unwrap_or((None, [None; 2]))
    }
    pub fn context(&self) -> &galaxybridge_quic_media::Context {
        &self.binding.context
    }
    fn service_bootstrap(&mut self) -> Result<(), Error> {
        if self.now_ns()? >= crate::PHASE_LIFETIME {
            return Err(Error::Deadline);
        }
        let mut startup = self.startup.take().ok_or(Error::Protocol)?;
        let child = self.child.as_mut().ok_or(Error::Protocol)?;
        child.drain_stderr_observed(self.g1.receiver.recovery_trace.as_deref_mut())?;
        if child.exited()? {
            let _ = child.drain_stderr_observed(self.g1.receiver.recovery_trace.as_deref_mut());
            self.first_ticket = child.emit_first_cause();
            galaxybridge_quic_media::media::first_error::reject(8, line!(), 0, 0, 0, 0, 0);
            return Err(Error::Retired);
        }
        if startup.written < startup.wire.len() {
            startup.written += child.write(&startup.wire[startup.written..])?;
        }
        let mut bytes = [0; 4096];
        for _ in 0..4 {
            let Some(n) = child.read(&mut bytes)? else {
                break;
            };
            if n == 0 {
                return Err(Error::Retired);
            }
            let mut at = 0;
            while at < n {
                if startup.frame.complete() {
                    return Err(Error::Protocol);
                }
                at += startup.frame.push(&bytes[at..n])?;
            }
            if startup.frame.complete() {
                break;
            }
        }
        if startup.frame.complete() {
            if startup.written != startup.wire.len() {
                return Err(Error::Protocol);
            }
            let reply = Replies::decode(startup.frame.bytes(), &startup.requests)?;
            let identities = startup.identities.take().ok_or(Error::Protocol)?;
            for (i, identity) in identities.into_iter().enumerate() {
                let bind = SocketAddr::new(startup.local_ip, 0);
                let mut endpoint = Endpoint::connect_with_transport_options(
                    bind,
                    SocketAddr::new(startup.peer_ip, reply.roles[i].port),
                    startup.requests.roles[i].session,
                    identity,
                    reply.roles[i].fingerprint,
                    if i == 0 {
                        galaxybridge_quic::CongestionControl::Bbr2
                    } else {
                        galaxybridge_quic::CongestionControl::Cubic
                    },
                    // Match the peer's latency-critical delayed-ACK profile on
                    // the independent input connection only.
                    (i == 2).then_some(1),
                    // Sparse reliable input should leave immediately; media
                    // remains paced on its separate endpoint.
                    i != 2,
                )
                .map_err(|_| Error::Authentication)?;
                if i == 0 {
                    endpoint.preserve_committed_datagrams();
                }
                endpoint.set_dscp(route_dscp(i)?).map_err(|_| Error::Io)?;
                self.endpoints.push(endpoint);
            }
            self.pair_deadline = crate::deadline(self.now_ns()?, crate::PHASE_LIFETIME)?;
        } else {
            self.startup = Some(startup);
        }
        Ok(())
    }
}
impl Drop for Backend {
    fn drop(&mut self) {
        self.retire(Error::Retired);
    }
}
pub(crate) fn semantic_release(record: &Record) -> bool {
    if record.kind != 8 || record.body.len() < 37 {
        return false;
    }
    let raw = &record.body[36..];
    use galaxybridge_quic_media::control::{validate, Class};
    matches!(validate(record.body[0], raw), Ok(Class::Up | Class::Cancel))
        || matches!(validate(record.body[0], raw), Ok(Class::Key)) && raw.get(1) == Some(&1)
        || matches!(validate(record.body[0], raw), Ok(Class::Uhid)) && raw.first() == Some(&14)
}
fn advance_outer(value: &mut u64) -> Result<u64, Error> {
    *value = value.checked_add(1).ok_or(Error::Capacity)?;
    Ok(*value)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn transport_roles_have_stable_non_overlapping_dscp_classes() {
        assert_eq!(route_dscp(0), Ok(34));
        assert_eq!(route_dscp(1), Ok(0));
        assert_eq!(route_dscp(2), Ok(46));
        assert_eq!(route_dscp(3), Err(Error::Protocol));
    }
    #[test]
    fn bitrate_primary_policy_is_explicit_not_transport_heuristic() {
        let mut binding = Binding {
            nonce: [3; 32],
            sidecar_sha: [4; 32],
            context: galaxybridge_quic_media::Context {
                session: [7; 32],
                generation: 1,
                scid: 1,
                capture_kind: 0,
                display_id: 0,
                target_token: 9,
                enabled: 7,
            },
        };
        let mut launch = stock::ProducerLaunch {
            jar: "/owned/derivative".into(),
            hevc: true,
            max_size: 2560,
            max_fps: 60,
            video_bit_rate: 20_000_000,
            audio_bit_rate: 128_000,
            key_frame_interval_seconds: None,
            new_display: None,
        };
        assert!(Backend::adaptive_primary(
            &binding,
            &launch,
            Some(stock::LaunchPolicy::Primary)
        ));
        assert!(Backend::adaptive_primary(
            &binding,
            &launch,
            Some(stock::LaunchPolicy::PrimaryCleanup { cleanup: false })
        ));
        for policy in [
            None,
            Some(stock::LaunchPolicy::Application { density: None }),
            Some(stock::LaunchPolicy::VirtualDesktop { density: None }),
        ] {
            assert!(!Backend::adaptive_primary(&binding, &launch, policy));
        }
        binding.context.display_id = 1;
        assert!(!Backend::adaptive_primary(
            &binding,
            &launch,
            Some(stock::LaunchPolicy::Primary)
        ));
        binding.context.display_id = 0;
        binding.context.enabled = 6;
        assert!(!Backend::adaptive_primary(
            &binding,
            &launch,
            Some(stock::LaunchPolicy::Primary)
        ));
        binding.context.enabled = 7;
        launch.new_display = Some((100, 100));
        assert!(!Backend::adaptive_primary(
            &binding,
            &launch,
            Some(stock::LaunchPolicy::Primary)
        ));
    }
    #[test]
    fn recovery_preserves_independent_stock_before_sync_submission() {
        exercise_recovery_stock(false);
    }
    #[test]
    fn recovery_preserves_live_idr_when_successor_expires() {
        exercise_recovery_stock(true);
    }
    #[test]
    fn expired_repair_copy_does_not_request_another_idr() {
        exercise_copy_expiry(true, false, false);
    }
    #[test]
    fn committed_au_ack_cancels_pending_copies_before_expiry() {
        exercise_copy_expiry(true, true, false);
    }
    #[test]
    fn committed_au_ack_does_not_hide_other_initial_expiry() {
        exercise_copy_expiry(true, true, true);
    }
    #[test]
    fn committed_au_ack_cancels_live_plaintext_copies() {
        let (mut owner, mut remotes) = copy_expiry_owner();
        exercise_copy_expiry_channels(&mut owner, &mut remotes, true, true, false, true);
        owner.retire(Error::Retired);
        assert!(owner.cleanup().unwrap().complete);
        for remote in &mut remotes {
            remote.close();
        }
    }
    #[test]
    fn expired_unconfirmed_initial_copy_still_requests_recovery() {
        exercise_copy_expiry(false, false, false);
    }
    fn exercise_copy_expiry(repair: bool, acknowledge: bool, unrelated_loss: bool) {
        let (mut owner, mut remotes) = copy_expiry_owner();
        exercise_copy_expiry_channels(
            &mut owner,
            &mut remotes,
            repair,
            acknowledge,
            unrelated_loss,
            false,
        );
        owner.retire(Error::Retired);
        assert!(owner.cleanup().unwrap().complete);
        for remote in &mut remotes {
            remote.close();
        }
    }
    fn copy_expiry_owner() -> (Backend, Vec<Endpoint>) {
        let mut remotes = Vec::new();
        let endpoints = std::array::from_fn(|i| {
            let local = Identity::generate().unwrap();
            let remote = Identity::generate().unwrap();
            let local_pin = local.fingerprint();
            let mut sender = Endpoint::listen(
                "127.0.0.1:0".parse().unwrap(),
                "127.0.0.1".parse().unwrap(),
                [i as u8 + 7; 32],
                local,
                remote.fingerprint(),
            )
            .unwrap();
            let mut receiver = Endpoint::connect(
                "127.0.0.1:0".parse().unwrap(),
                sender.local_addr().unwrap(),
                [i as u8 + 7; 32],
                remote,
                local_pin,
            )
            .unwrap();
            let end = Instant::now() + Duration::from_secs(2);
            while !(sender.stats().application_ready && receiver.stats().application_ready) {
                assert!(Instant::now() < end);
                sender.poll().unwrap();
                receiver.poll().unwrap();
                std::thread::sleep(Duration::from_millis(1));
            }
            sender.preserve_committed_datagrams();
            remotes.push(receiver);
            sender
        });
        let binding = Binding {
            nonce: [3; 32],
            sidecar_sha: [4; 32],
            context: galaxybridge_quic_media::Context {
                session: [7; 32],
                generation: 1,
                scid: 1,
                capture_kind: 0,
                display_id: 0,
                target_token: 9,
                enabled: 7,
            },
        };
        let mut owner = Backend::from_channels(
            OwnerSlot::acquire().unwrap(),
            Side::Peer,
            binding,
            endpoints,
            None,
        )
        .unwrap();
        owner.origin = Instant::now();
        owner.local_clock = Some(1);
        owner.boottime = || Ok(1_000_000_000);
        for kind in [3, 4] {
            owner
                .producer_map
                .publication(galaxybridge_quic_media::StockPublication {
                    kind,
                    track: 1,
                    epoch: 1,
                    config: if kind == 4 { 1 } else { 0 },
                    sequence: 0,
                    started: 1,
                    independent: false,
                })
                .unwrap();
        }
        (owner, remotes)
    }
    fn copy_expiry_record(sequence: u64, independent: bool) -> Record {
        Record {
            kind: 5,
            track: 1,
            flags: if independent { 3 } else { 2 },
            generation: 1,
            epoch: 1,
            config: 1,
            sequence,
            pts: 166_667,
            total: 0,
            index: 0,
            count: 0,
            age_us: 0,
            lifetime_us: 0,
            body: vec![0x37; 1200],
        }
    }
    fn exercise_copy_expiry_channels(
        owner: &mut Backend,
        remotes: &mut [Endpoint],
        repair: bool,
        acknowledge: bool,
        unrelated_loss: bool,
        live_ack: bool,
    ) {
        let au = copy_expiry_record(10, false);
        owner.g1.cache.insert(au, 1).unwrap();
        owner.send_records().unwrap();
        assert_eq!(owner.video_datagrams.len(), 2);
        if repair {
            // Deliver both original fragments over real authenticated UDP.
            // Then a delayed hole report asks for a duplicate of fragment 0.
            let mut originals = Vec::new();
            while originals.len() < 2 {
                assert!(owner.origin.elapsed() < Duration::from_millis(60));
                owner.endpoints[0].poll().unwrap();
                remotes[0].poll().unwrap();
                while let Some(received) = remotes[0].receive() {
                    originals.push(Record::decode(received.lane, &received.payload).unwrap());
                }
                std::thread::sleep(Duration::from_millis(1));
            }
            assert_eq!(
                originals
                    .iter()
                    .flat_map(|r| r.body.iter().copied())
                    .collect::<Vec<_>>(),
                vec![0x37; 1200]
            );
            let mut hole = originals[0].with_body(vec![1]);
            hole.kind = 6;
            hole.flags = 0;
            hole.pts = 0;
            hole.index = 0;
            hole.age_us = 0;
            hole.lifetime_us = 0;
            owner.g1.cache.request(&hole, 1, Some(1)).unwrap();
            owner.send_records().unwrap();
            assert_eq!(owner.video_datagrams.len(), 3);
            if acknowledge {
                // The consumer can finish an AU using a duplicate or parity
                // while an initial copy is still queued. Model that remaining
                // initial admission as well as the actual repair above: both
                // must lose to the exact consumer ACK, even in the same poll.
                let (admission, outer) = owner
                    .send_observed(
                        0,
                        Lane::Datagram,
                        originals[0].encode().unwrap(),
                        120 * MS + 1,
                    )
                    .unwrap();
                assert_eq!(admission, Admission::Accepted);
                owner.video_datagrams.insert(
                    outer,
                    VideoDatagram {
                        record: originals[0].with_body(Vec::new()),
                        deadline: 120 * MS + 1,
                        repair: false,
                    },
                );
                if unrelated_loss {
                    let mut other = originals[0].clone();
                    other.sequence += 1;
                    let (admission, outer) = owner
                        .send_observed(0, Lane::Datagram, other.encode().unwrap(), 120 * MS + 1)
                        .unwrap();
                    assert_eq!(admission, Admission::Accepted);
                    owner.video_datagrams.insert(
                        outer,
                        VideoDatagram {
                            record: other.with_body(Vec::new()),
                            deadline: 120 * MS + 1,
                            repair: false,
                        },
                    );
                }
                let mut ack = hole.with_body(Vec::new());
                ack.kind = 7;
                ack.total = 0;
                ack.count = 0;
                assert_eq!(
                    remotes[2].send(
                        Message {
                            lane: Lane::Reliable,
                            sequence: 1,
                            payload: ack.encode().unwrap(),
                        },
                        Instant::now() + Duration::from_secs(1)
                    ),
                    Admission::Accepted
                );
                // Queue the exact peer ACK without consuming it at G1 yet.
                while owner.endpoints[2].stats().receive_queue_records == 0 {
                    assert!(owner.origin.elapsed() < Duration::from_millis(80));
                    remotes[2].poll().unwrap();
                    owner.endpoints[2].poll().unwrap();
                    std::thread::sleep(Duration::from_millis(1));
                }
            }
        }
        if live_ack {
            assert!(owner.origin.elapsed() < Duration::from_millis(100));
            assert!(owner.endpoints[0].stats().datagram_queue_records > 0);
            // Exercise the validated ACK boundary before polling media: an
            // empty queue must mean cancellation, not successful UDP sending.
            let before = owner.endpoints[0].stats().datagrams_generated;
            let received = owner.endpoints[2].receive().unwrap();
            let ack = Record::decode(received.lane, &received.payload).unwrap();
            owner
                .g1
                .ingest(received, owner.now_ns().unwrap(), Some(1))
                .unwrap();
            owner.discard_confirmed_video_copies(&ack);
            assert!(
                owner.video_datagrams.is_empty(),
                "exact ACK removes live trackers"
            );
            assert_eq!(owner.endpoints[0].stats().datagram_queue_records, 0);
            assert_eq!(owner.endpoints[0].stats().pressure.expiry_queued, 0);
            assert_eq!(owner.endpoints[0].stats().datagrams_generated, before);
        }
        let cutoff = owner.origin + Duration::from_millis(121);
        if let Some(wait) = cutoff.checked_duration_since(Instant::now()) {
            std::thread::sleep(wait);
        }
        owner.local_clock = Some(owner.origin.elapsed().as_nanos() as u64);
        if acknowledge {
            // Real poll expires pending plaintext in the same turn that the
            // already-received committed-AU ACK reaches the application.
            owner.service().unwrap();
            assert!(
                owner.video_datagrams.is_empty(),
                "ACK must retire every exact-AU copy"
            );
        } else {
            owner.endpoints[0].poll().unwrap();
            assert!(owner.endpoints[0].stats().pressure.expiry_queued > 0);
            owner
                .handle_video_datagram_expiry(owner.now_ns().unwrap())
                .unwrap();
        }
        assert_eq!(
            owner.producer_map.active(),
            !repair || unrelated_loss,
            "expiry of a retransmitted/confirmed copy is not a new missing video AU"
        );
        assert!(owner.terminal.is_none());
    }
    #[test]
    fn receiver_recovery_cannot_hide_later_initial_expiry() {
        let (mut owner, mut remotes) = copy_expiry_owner();
        // Receiver reports loss10. Sender still owns IDR20, initial21 and22.
        // Only21 expires this turn: recovery for10 must not retain22 as a
        // decodable successor of20 by draining the evidence of missing21.
        owner
            .g1
            .cache
            .insert(copy_expiry_record(20, true), 40 * MS)
            .unwrap();
        owner
            .g1
            .cache
            .insert(copy_expiry_record(21, false), 1)
            .unwrap();
        owner
            .g1
            .cache
            .insert(copy_expiry_record(22, false), 40 * MS)
            .unwrap();
        owner.local_clock = Some(40 * MS);
        owner.send_records().unwrap();
        let admitted = |sequence| {
            owner
                .video_datagrams
                .values()
                .find(|d| d.record.sequence == sequence)
                .unwrap()
                .record
                .clone()
        };
        let key = admitted(20);
        let lost = admitted(21);
        let successor = admitted(22);
        let mut body = Vec::new();
        body.extend(1u32.to_be_bytes());
        body.extend(1u32.to_be_bytes());
        body.extend(10u64.to_be_bytes());
        let recovery = bulk::Record {
            kind: 4,
            purpose: 3,
            generation: 1,
            id: 1,
            barrier: 0,
            total: 16,
            offset: 0,
            age_us: 0,
            body,
        };
        assert_eq!(
            remotes[2].send(
                Message {
                    lane: Lane::Reliable,
                    sequence: 1,
                    payload: recovery.encode(Role::Media, Side::Host).unwrap()
                },
                Instant::now() + Duration::from_secs(1),
            ),
            Admission::Accepted,
        );
        while owner.endpoints[2].stats().receive_queue_records == 0 {
            assert!(owner.origin.elapsed() < Duration::from_millis(80));
            remotes[2].poll().unwrap();
            owner.endpoints[2].poll().unwrap();
            std::thread::sleep(Duration::from_millis(1));
        }
        let cutoff = owner.origin + Duration::from_millis(121);
        if let Some(wait) = cutoff.checked_duration_since(Instant::now()) {
            std::thread::sleep(wait);
        }
        assert!(owner.origin.elapsed() < Duration::from_millis(150));
        owner.local_clock = Some(owner.origin.elapsed().as_nanos() as u64);
        owner.service().unwrap();
        assert!(owner.g1.cache.contains_video_access_unit(&key));
        assert!(!owner.g1.cache.contains_video_access_unit(&lost));
        assert!(
            !owner.g1.cache.contains_video_access_unit(&successor),
            "receiver recovery must not erase evidence of the later initial loss",
        );
        assert!(owner.producer_map.active());
        assert_eq!(owner.producer_map.pending_observation().unwrap().4, 21);
        owner.retire(Error::Retired);
        assert!(owner.cleanup().unwrap().complete);
        for remote in &mut remotes {
            remote.close();
        }
    }
    fn exercise_recovery_stock(expire_successor: bool) {
        use std::io::{Read, Write};
        use std::os::unix::net::UnixStream;
        fn clock() -> Result<u64, Error> {
            Ok(1_000_000_000)
        }
        let bytes = std::fs::read(std::path::PathBuf::from(std::env::var_os("GB_QUIC_TEST_FIXTURES").expect("run scripts/test-quic-backend.sh")).join("h264.stock")).unwrap();
        let mut frames = vec![];
        let mut at = 0;
        while at < bytes.len() {
            let n = u32::from_be_bytes(bytes[at..at + 4].try_into().unwrap()) as usize;
            at += 4;
            frames.push(bytes[at..at + n].to_vec());
            at += n;
        }
        let endpoints = std::array::from_fn(|i| {
            Endpoint::listen(
                "127.0.0.1:0".parse().unwrap(),
                "127.0.0.1".parse().unwrap(),
                [i as u8 + 7; 32],
                Identity::generate().unwrap(),
                [1; 32],
            )
            .unwrap()
        });
        let binding = Binding {
            nonce: [3; 32],
            sidecar_sha: [4; 32],
            context: galaxybridge_quic_media::Context {
                session: [7; 32],
                generation: 1,
                scid: 1,
                capture_kind: 0,
                display_id: 0,
                target_token: 9,
                enabled: 7,
            },
        };
        let (video, mut producer_video) = UnixStream::pair().unwrap();
        let (audio, _producer_audio) = UnixStream::pair().unwrap();
        let (control, mut producer_control) = UnixStream::pair().unwrap();
        producer_control.set_nonblocking(true).unwrap();
        let stock = stock::SocketGroup::connected(Some(video), Some(audio), control).unwrap();
        let mut owner = Backend::from_channels(
            OwnerSlot::acquire().unwrap(),
            Side::Peer,
            binding,
            endpoints,
            Some(stock),
        )
        .unwrap();
        owner.boottime = clock;
        owner.local_clock = Some(1);
        owner.quality = Some(crate::quality::Controller::new(20_000_000).unwrap());
        producer_video.write_all(&[0; 65]).unwrap();
        for frame in &frames[..3] {
            producer_video.write_all(frame).unwrap();
        }
        assert!(owner.stock.as_mut().unwrap().consume_preamble().unwrap());
        owner.g1.queue_start(1).unwrap();
        owner.read_stock(1).unwrap();
        assert_eq!(owner.producer_map.identity(), Some((1, 1)));

        let mut body = vec![];
        body.extend(1u32.to_be_bytes());
        body.extend(1u32.to_be_bytes());
        body.extend(1u64.to_be_bytes());
        let request = bulk::Record {
            kind: 4,
            purpose: 3,
            generation: 1,
            id: 1,
            barrier: 0,
            total: 16,
            offset: 0,
            age_us: 0,
            body,
        };
        assert_eq!(
            owner.admit_receiver_recovery(&request, clock().unwrap()),
            Ok(crate::recovery::RecoveryAdmission::Queued)
        );
        assert!(owner.quality_precedes_recovery && owner.producer_map.pending());
        // A real owner turn writes the bitrate first, then reads a fresh IDR
        // already emitted by the encoder. The sync request is still pending.
        producer_video.write_all(&frames[3]).unwrap();
        producer_video.write_all(&frames[4]).unwrap();
        owner.track_turn = 1;
        owner.service_stock().unwrap();
        let mut rate = [0u8; 37];
        producer_control.read_exact(&mut rate).unwrap();
        assert_eq!(rate[0], 24);
        let mut extra = [0; 1];
        assert_eq!(
            producer_control.read(&mut extra).unwrap_err().kind(),
            std::io::ErrorKind::WouldBlock
        );
        assert!(owner.producer_map.pending());
        assert_eq!(
            owner.g1.cache.usage().0,
            1,
            "the independent AU survives; its following dependent AU stays fenced"
        );
        let mut payload = vec![];
        while let Some((r, _, repair)) = owner.g1.cache.next(1) {
            assert_eq!((r.track, r.sequence, r.flags & 1), (1, 1, 1));
            payload.extend_from_slice(&r.body);
            owner.g1.cache.accepted(&r, repair).unwrap();
        }
        assert_eq!(payload, frames[3][12..]);

        // Preserve the existing correlation: only a key after the actual sync
        // submission ends the fence and admits the following dependent AU.
        owner.service_stock().unwrap();
        let mut sync = [0u8; 33];
        producer_control.read_exact(&mut sync).unwrap();
        assert_eq!(sync[0], 23);
        assert!(!owner.producer_map.pending() && owner.producer_map.active());
        let mut requested = frames[3].clone();
        requested[..8].copy_from_slice(&((1u64 << 61) | 100_000).to_be_bytes());
        let mut dependent = frames[4].clone();
        dependent[..8].copy_from_slice(&116_667u64.to_be_bytes());
        producer_video.write_all(&requested).unwrap();
        producer_video.write_all(&dependent).unwrap();
        owner.read_stock(1).unwrap();
        assert!(!owner.producer_map.active());
        assert_eq!(owner.g1.cache.usage().0, 2);
        let mut remote = expire_successor.then(|| {
            let sender_identity = Identity::generate().unwrap();
            let receiver_identity = Identity::generate().unwrap();
            let sender_pin = sender_identity.fingerprint();
            let receiver_pin = receiver_identity.fingerprint();
            let mut sender = Endpoint::listen(
                "127.0.0.1:0".parse().unwrap(),
                "127.0.0.1".parse().unwrap(),
                [7; 32],
                sender_identity,
                receiver_pin,
            )
            .unwrap();
            let mut receiver = Endpoint::connect(
                "127.0.0.1:0".parse().unwrap(),
                sender.local_addr().unwrap(),
                [7; 32],
                receiver_identity,
                sender_pin,
            )
            .unwrap();
            let limit = Instant::now() + Duration::from_secs(2);
            while !(sender.stats().application_ready && receiver.stats().application_ready) {
                assert!(Instant::now() < limit);
                sender.poll().unwrap();
                receiver.poll().unwrap();
                std::thread::sleep(Duration::from_millis(1));
            }
            sender.preserve_committed_datagrams();
            owner.endpoints[0] = sender;
            // The source fixture clock is1ns. Bind its queued lifetime to a
            // fresh real Instant only after completing the unrelated handshake.
            owner.origin = Instant::now();
            receiver
        });
        let mut sequences = vec![];
        let mut key_fragments = 0;
        while let Some((r, _, repair)) = owner.g1.cache.next(owner.now_ns().unwrap()) {
            if sequences.last() != Some(&r.sequence) {
                sequences.push(r.sequence);
            }
            if expire_successor {
                let deadline = 1 + if r.sequence == 3 { 250 * MS } else { 120 * MS };
                let (admission, outer) = owner
                    .send_observed(0, Lane::Datagram, r.encode().unwrap(), deadline)
                    .unwrap();
                assert_eq!(admission, Admission::Accepted);
                key_fragments += usize::from(r.sequence == 3);
                owner.video_datagrams.insert(
                    outer,
                    VideoDatagram {
                        record: r.with_body(Vec::new()),
                        deadline,
                        repair,
                    },
                );
            }
            owner.g1.cache.accepted(&r, repair).unwrap();
        }
        assert_eq!(sequences, [3, 4]);
        if let Some(receiver) = remote.as_mut() {
            assert_eq!(owner.endpoints[0].stats().datagrams_generated, 0);
            let cutoff = owner.origin + Duration::from_millis(121);
            if let Some(wait) = cutoff.checked_duration_since(Instant::now()) {
                std::thread::sleep(wait);
            }
            let now = owner.origin.elapsed().as_nanos() as u64;
            assert!(now < 200 * MS, "fixture lost its live-IDR precondition");
            owner.local_clock = Some(now);
            // Actual endpoint admission expires the successor plaintext,
            // without polling/generating the earlier still-live IDR.
            assert_eq!(
                owner.endpoints[0].send(
                    Message {
                        lane: Lane::Datagram,
                        sequence: 9000,
                        payload: vec![8]
                    },
                    owner.origin + Duration::from_millis(250)
                ),
                Admission::Accepted
            );
            assert_eq!(owner.endpoints[0].stats().datagrams_generated, 0);
            owner.handle_video_datagram_expiry(now).unwrap();
            assert_eq!(
                owner.g1.cache.usage().0,
                1,
                "a lost successor must not cancel the still-live preceding IDR"
            );
            assert_eq!(owner.video_datagrams.len(), key_fragments);
            assert!(
                owner.producer_map.pending(),
                "successor recovery is still requested"
            );
            let mut payload = Vec::new();
            let mut received = 0;
            let mut received_key = None;
            while received != key_fragments {
                assert!(
                    Instant::now() < owner.origin + Duration::from_millis(250),
                    "IDR must arrive within its original source lifetime"
                );
                owner.endpoints[0].poll().unwrap();
                receiver.poll().unwrap();
                while let Some(message) = receiver.receive() {
                    if message.sequence == 9000 {
                        continue;
                    }
                    let r = Record::decode(message.lane, &message.payload).unwrap();
                    assert_eq!(r.sequence, 3, "lost dependent AU must not escape cleanup");
                    payload.extend_from_slice(&r.body);
                    received_key = Some(r);
                    received += 1;
                }
                std::thread::sleep(Duration::from_millis(1));
            }
            assert_eq!(payload, requested[12..]);
            assert!(!owner.endpoints[0].stats().retired && !receiver.stats().retired);
            // Once that exact AU is ACKed, its queued duplicate must NOT be
            // protected merely because the old transport tracker says key.
            let key = received_key.unwrap();
            let (admission, duplicate) = owner
                .send_observed(0, Lane::Datagram, key.encode().unwrap(), 250 * MS + 1)
                .unwrap();
            assert_eq!(admission, Admission::Accepted);
            owner.video_datagrams.insert(
                duplicate,
                VideoDatagram {
                    record: key.with_body(Vec::new()),
                    deadline: 250 * MS + 1,
                    repair: true,
                },
            );
            let mut ack = key.with_body(Vec::new());
            ack.kind = 7;
            owner.g1.cache.ack(&ack).unwrap();
            owner.discard_pending_video_for_recovery(4, owner.origin.elapsed().as_nanos() as u64);
            assert!(owner.video_datagrams.is_empty());
            for _ in 0..10 {
                owner.endpoints[0].poll().unwrap();
                receiver.poll().unwrap();
                while let Some(message) = receiver.receive() {
                    assert_ne!(message.sequence, duplicate, "ACKed duplicate was cancelled");
                }
                std::thread::sleep(Duration::from_millis(1));
            }
            receiver.close();
        }
        owner.retire(Error::Retired);
        assert!(owner.cleanup().unwrap().complete);
    }
    #[test]
    fn bitrate_actual_owner_samples_and_partial_socket_writer() {
        use std::io::Read;
        use std::os::unix::net::UnixStream;
        fn clock() -> Result<u64, Error> {
            Ok(1_000_000_000)
        }
        let endpoints = std::array::from_fn(|i| {
            Endpoint::listen(
                "127.0.0.1:0".parse().unwrap(),
                "127.0.0.1".parse().unwrap(),
                [i as u8 + 7; 32],
                Identity::generate().unwrap(),
                [1; 32],
            )
            .unwrap()
        });
        let binding = Binding {
            nonce: [3; 32],
            sidecar_sha: [4; 32],
            context: galaxybridge_quic_media::Context {
                session: [7; 32],
                generation: 1,
                scid: 1,
                capture_kind: 0,
                display_id: 0,
                target_token: 9,
                enabled: 6,
            },
        };
        let (audio, _producer_audio) = UnixStream::pair().unwrap();
        let (control, mut producer_control) = UnixStream::pair().unwrap();
        producer_control.set_nonblocking(true).unwrap();
        let stock = stock::SocketGroup::connected(None, Some(audio), control).unwrap();
        let mut owner = Backend::from_channels(
            OwnerSlot::acquire().unwrap(),
            Side::Peer,
            binding,
            endpoints,
            Some(stock),
        )
        .unwrap();
        owner.boottime = clock;
        owner.local_clock = Some(1);
        owner.write_limit = 1;
        owner.quality = Some(crate::quality::Controller::new(20_000_000).unwrap());
        for kind in [3, 4] {
            owner
                .producer_map
                .publication(galaxybridge_quic_media::StockPublication {
                    kind,
                    track: 1,
                    epoch: 1,
                    config: if kind == 4 { 1 } else { 0 },
                    sequence: 0,
                    started: 1,
                    independent: false,
                })
                .unwrap();
        }
        for n in 1..=3 {
            let mut s = galaxybridge_quic::endpoint::Stats::default();
            s.authenticated = true;
            s.application_ready = true;
            s.path.valid = true;
            s.path.available = true;
            s.datagrams_admitted = n * 100;
            s.pressure.expiry_queued = n - 1;
            s.datagram_queue_records = 32;
            owner.quality_video = n;
            owner.apply_quality_sample(n * 250 * MS, s).unwrap();
            assert_eq!(owner.quality_pending.is_some(), n == 3);
        }
        let first = owner.quality_pending.clone().unwrap();
        assert_eq!(first.target, 15_000_000);
        owner.service_stock().unwrap();
        assert!(matches!(owner.writing, Some(Writing::Bitrate(_, 1))));
        // A newer coalesced target cannot alter the bytes/deadline of a partial frame.
        let successor =
            crate::quality::Request::new(1, 1, 2, clock().unwrap(), 10_000_000, 20_000_000)
                .unwrap();
        owner.quality_pending = Some(successor.clone());
        for _ in 1..37 {
            owner.service_stock().unwrap();
        }
        assert_eq!(owner.quality_submitted, Some(15_000_000));
        let mut bytes = [0u8; 37];
        producer_control.read_exact(&mut bytes).unwrap();
        assert_eq!(bytes, first.bytes);
        for _ in 0..37 {
            owner.service_stock().unwrap();
        }
        producer_control.read_exact(&mut bytes).unwrap();
        assert_eq!(bytes, successor.bytes);
        assert_eq!(owner.quality_submitted, Some(10_000_000));
        // Entirely unwritten expiry is a refusal, not owner failure or renewed deadline.
        let expired = crate::quality::Request::new(
            1,
            1,
            3,
            clock().unwrap() - 100 * MS,
            2_000_000,
            20_000_000,
        )
        .unwrap();
        owner.quality_pending = Some(expired);
        owner.service_stock().unwrap();
        assert!(owner.quality_pending.is_none() && owner.writing.is_none());
        assert!(owner.terminal.is_none());
        assert_eq!(
            producer_control.read(&mut bytes).unwrap_err().kind(),
            std::io::ErrorKind::WouldBlock
        );
        // Original sync work wins over an entirely unwritten target.
        owner.quality_pending = Some(
            crate::quality::Request::new(1, 1, 4, clock().unwrap(), 2_000_000, 20_000_000).unwrap(),
        );
        let mut body = vec![];
        body.extend(1u32.to_be_bytes());
        body.extend(1u32.to_be_bytes());
        body.extend(1u64.to_be_bytes());
        let record = bulk::Record {
            kind: 4,
            purpose: 3,
            generation: 1,
            id: 1,
            barrier: 0,
            total: 16,
            offset: 0,
            age_us: 0,
            body,
        };
        owner.producer_map.admit(&record, clock().unwrap()).unwrap();
        owner.service_stock().unwrap();
        assert!(matches!(owner.writing, Some(Writing::Recovery(_, 1))));
        let mut prior_sync_kind = [0u8; 1];
        producer_control.read_exact(&mut prior_sync_kind).unwrap();
        assert_eq!(prior_sync_kind[0], 23);

        // A peer-observed loss is stronger evidence than sender-local queue
        // pressure.  Its rate reduction must reach the encoder before the
        // recovery keyframe request, otherwise the replacement IDR may be lost
        // under the same congestion window.
        owner.writing = None;
        owner.producer_map.clear();
        for kind in [3, 4] {
            owner
                .producer_map
                .publication(galaxybridge_quic_media::StockPublication {
                    kind,
                    track: 1,
                    epoch: 1,
                    config: if kind == 4 { 1 } else { 0 },
                    sequence: 0,
                    started: 1,
                    independent: false,
                })
                .unwrap();
        }
        let mut receiver_record = record;
        receiver_record.id = 2;
        owner.video_datagrams.insert(
            88,
            VideoDatagram {
                record: Record {
                    kind: 5,
                    track: 1,
                    flags: 2,
                    generation: 1,
                    epoch: 1,
                    config: 1,
                    sequence: 7,
                    pts: 1,
                    total: 1,
                    index: 0,
                    count: 1,
                    age_us: 0,
                    lifetime_us: 250_000,
                    body: vec![0],
                },
                deadline: clock().unwrap() + 250 * MS,
                repair: false,
            },
        );
        assert_eq!(
            owner.admit_receiver_recovery(&receiver_record, clock().unwrap()),
            Ok(crate::recovery::RecoveryAdmission::Queued)
        );
        assert!(
            owner.video_datagrams.is_empty(),
            "stale video must not compete with the replacement IDR"
        );
        owner.service_stock().unwrap();
        assert!(matches!(owner.writing, Some(Writing::Bitrate(_, 1))));
        for _ in 1..37 {
            owner.service_stock().unwrap();
        }
        let mut ordered = [0u8; 37];
        producer_control.read_exact(&mut ordered).unwrap();
        assert_eq!(
            ordered[0], 24,
            "bitrate command must be complete before sync"
        );
        owner.service_stock().unwrap();
        let mut sync_kind = [0u8; 1];
        producer_control.read_exact(&mut sync_kind).unwrap();
        assert_eq!(sync_kind[0], 23, "recovery request follows the rate update");
        owner.retire(Error::Retired);
        assert!(owner.cleanup().unwrap().complete);
    }
    #[test]
    fn stall_repair_actual_path_scalar_validity_and_overflow() {
        use galaxybridge_quic::endpoint::PathObservation;
        let p = PathObservation {
            valid: true,
            available: true,
            rtt_available: true,
            rtt_ns: 30 * MS,
            rttvar_ns: 5 * MS,
            ..Default::default()
        };
        assert_eq!(Backend::receiver_repair_margin(p), Some(50 * MS));
        for absent in [
            PathObservation { valid: false, ..p },
            PathObservation {
                available: false,
                ..p
            },
            PathObservation {
                rtt_available: false,
                ..p
            },
            PathObservation {
                rtt_ns: 0,
                rttvar_ns: 0,
                ..p
            },
            PathObservation {
                rtt_ns: u64::MAX,
                ..p
            },
            PathObservation {
                rttvar_ns: u64::MAX,
                ..p
            },
        ] {
            assert_eq!(
                Backend::receiver_repair_margin(absent),
                None,
                "no default or overflow-created repair opportunity"
            );
        }
        // A positive measured RTT with zero variance is valid, not an absent estimate.
        assert_eq!(
            Backend::receiver_repair_margin(PathObservation { rttvar_ns: 0, ..p }),
            Some(30 * MS)
        );
    }
    #[test]
    fn recovery_observation_actual_owner_disabled_rate_terminal_and_ceiling() {
        let endpoints = std::array::from_fn(|i| {
            Endpoint::listen(
                "127.0.0.1:0".parse().unwrap(),
                "127.0.0.1".parse().unwrap(),
                [i as u8 + 7; 32],
                Identity::generate().unwrap(),
                [1; 32],
            )
            .unwrap()
        });
        let binding = Binding {
            nonce: [3; 32],
            sidecar_sha: [4; 32],
            context: galaxybridge_quic_media::Context {
                session: [7; 32],
                generation: 1,
                scid: 1,
                capture_kind: 0,
                display_id: 0,
                target_token: 9,
                enabled: 6,
            },
        };
        let mut owner = Backend::from_channels(
            OwnerSlot::acquire().unwrap(),
            Side::Host,
            binding,
            endpoints,
            None,
        )
        .unwrap();
        owner.g1.receiver.recovery_trace = None;
        owner.local_clock = Some(1);
        owner.trace_request(6, 1, 1, 1, 1, 1, 1);
        owner.flush_recovery_trace(false);
        assert_eq!(
            (
                owner.trace_last_flush,
                owner.trace_emitted,
                owner.trace_final
            ),
            (None, 0, false)
        );
        owner.g1.receiver.recovery_trace = Some(Box::default());
        owner.flush_recovery_trace(false);
        owner.local_clock = Some(500 * MS);
        owner.flush_recovery_trace(false);
        assert_eq!(owner.trace_last_flush, Some(1));
        owner.local_clock = Some(500 * MS + 1);
        owner.flush_recovery_trace(false);
        assert_eq!(owner.trace_last_flush, owner.local_clock);
        owner.trace_emitted = 512;
        owner.trace_request(6, 1, 1, 1, 1, 1, 1);
        owner.local_clock = Some(500 * MS + 2);
        owner.flush_recovery_trace(true);
        assert!(owner.trace_final);
        assert_eq!(owner.trace_emitted, 512);
        let serial = owner.g1.receiver.recovery_trace.as_ref().unwrap().serial;
        owner.local_clock = Some(2_000 * MS);
        owner.flush_recovery_trace(true);
        assert_eq!(
            owner.g1.receiver.recovery_trace.as_ref().unwrap().serial,
            serial
        );
        assert_eq!(owner.trace_last_flush, Some(500 * MS + 2));
        owner.retire(Error::Retired);
        assert!(owner.cleanup().unwrap().complete);
    }
    #[test]
    fn send_stage_observation_actual_owner_opt_out_media_start_rate_and_cap() {
        let endpoints = std::array::from_fn(|i| {
            Endpoint::listen(
                "127.0.0.1:0".parse().unwrap(),
                "127.0.0.1".parse().unwrap(),
                [i as u8 + 7; 32],
                Identity::generate().unwrap(),
                [1; 32],
            )
            .unwrap()
        });
        let binding = Binding {
            nonce: [3; 32],
            sidecar_sha: [4; 32],
            context: galaxybridge_quic_media::Context {
                session: [7; 32],
                generation: 29,
                scid: 1,
                capture_kind: 0,
                display_id: 0,
                target_token: 9,
                enabled: 6,
            },
        };
        let mut owner = Backend::from_channels(
            OwnerSlot::acquire().unwrap(),
            Side::Host,
            binding,
            endpoints,
            None,
        )
        .unwrap();
        owner.send_stages = None;
        assert!(!owner.first_cause_pending());
        owner.local_clock = Some(1);
        owner.sample_send_stages(1);
        assert!(owner.qa_send_stage_observations().is_empty());
        owner.send_stages = Some(Box::default());
        let pending_line = crate::progress::Line::without_pressure([
            29,
            2,
            1,
            3,
            1,
            200_000_001,
            1,
            11,
            10,
            10,
            10,
            0,
            0,
        ]);
        owner.send_stages.as_mut().unwrap().peer_progress[3] = Some(pending_line);
        owner.send_stages.as_mut().unwrap().finish_progress();
        assert!(
            owner.first_cause_pending(),
            "retained terminal snapshot needs the original bounded drain even before acceptance"
        );
        assert_eq!(
            owner
                .send_stages
                .as_ref()
                .unwrap()
                .terminal_progress
                .unwrap()[9],
            Some(pending_line),
            "child terminal row already parsed before child exit must survive host retirement"
        );
        owner.send_stages = Some(Box::default());
        owner.qa_hold_send_stage_output();
        owner.local_clock = Some(9_000 * MS);
        owner.sample_send_stages(3);
        assert!(
            owner.send_stages.as_ref().unwrap().started.is_none(),
            "handshake wait is not media start"
        );
        owner.sample_send_stages(1);
        owner.local_clock = Some(9_249 * MS);
        owner.sample_send_stages(3);
        assert_eq!(owner.send_stages.as_ref().unwrap().captured, 1);
        owner.local_clock = Some(9_250 * MS);
        owner.sample_send_stages(3);
        assert_eq!(owner.send_stages.as_ref().unwrap().captured, 2);
        for tick in 1..=20 {
            owner.local_clock = Some((9_250 + tick) * MS);
            owner.sample_send_stages(2);
        }
        assert_eq!(owner.send_stages.as_ref().unwrap().captured, 15);
        owner.sample_send_stages(4);
        owner.sample_send_stages(4);
        owner.sample_send_stages(2);
        let rows = owner.qa_send_stage_observations();
        assert_eq!(rows.len(), 16);
        for (i, row) in rows.iter().enumerate() {
            assert_eq!(&row[..3], &[29, 1, i as u64 + 1]);
        }
        assert_eq!(rows[15][4], 4);
        assert_eq!(owner.stats(Role::Media).datagrams_admitted, 0);
        owner.send_stages = Some(Box::default());
        owner.sample_send_stages(1);
        owner.local_clock = Some(13_000 * MS);
        owner.sample_send_stages(2);
        assert_eq!(
            owner.send_stages.as_ref().unwrap().captured,
            1,
            "closed three-second capture window"
        );
        owner.retire(Error::Retired);
        assert!(owner.cleanup().unwrap().complete);
    }
    #[test]
    fn reliable_stall_diagnostics_keep_only_class_track_size_and_backlog() {
        use galaxybridge_quic::endpoint::Retirement;

        let mut payload = vec![0xA5; 96];
        payload[..6].copy_from_slice(b"GQM1\r\x01");
        let observation = reliable_observation(&payload);
        assert_eq!(
            observation,
            ReliableObservation {
                kind: 13,
                track: 1,
                bytes: 96,
            }
        );
        assert_eq!(
            reliable_stall_rejection(
                0,
                Some(Retirement::ReliableStall),
                Some(observation),
                15_667
            ),
            [13, 1, 1, 96, 15_667]
        );
        assert_eq!(
            reliable_stall_rejection(0, Some(Retirement::Io), Some(observation), 15_667),
            [0; 5]
        );
        assert_eq!(
            reliable_observation(b"private reliable payload"),
            ReliableObservation {
                kind: 255,
                track: 0,
                bytes: 24,
            }
        );
    }
    #[test]
    fn idle_terminal_diagnostics_preserve_close_presence_and_packet_counts() {
        use galaxybridge_quic::endpoint::{Retirement, Stats};
        let stats = Stats {
            retirement: Some(Retirement::PeerIdle),
            local_close_code: Some(0),
            peer_close_code: Some(0x174),
            received_udp_packets: 12_345,
            sent_udp_packets: 6_789,
            ..Default::default()
        };
        assert_eq!(
            endpoint_terminal_rejection(0, stats, None),
            [3, 0, 0x174, 12_345, 6_789]
        );
        assert_eq!(
            endpoint_terminal_rejection(
                0,
                Stats {
                    local_close_code: None,
                    peer_close_code: None,
                    ..stats
                },
                None
            ),
            [0, 0, 0, 12_345, 6_789]
        );
        assert_eq!(
            endpoint_terminal_rejection(
                0,
                Stats {
                    quic_timed_out: true,
                    ..stats
                },
                None
            ),
            [7, 0, 0x174, 12_345, 6_789]
        );
        assert_eq!(
            endpoint_terminal_rejection(
                0,
                Stats {
                    retirement: Some(Retirement::Closed),
                    ..stats
                },
                None
            ),
            [0; 5],
            "normal close keeps its existing diagnostic shape"
        );
    }

    #[test]
    fn keepalive_endpoint_retirement_first_site_is_bounded_and_opt_in() {
        use galaxybridge_quic_media::media::first_error;
        for enabled in [false, true] {
            for index in 0..3 {
                let endpoints = std::array::from_fn(|i| {
                    let identity = Identity::generate().unwrap();
                    Endpoint::listen(
                        "127.0.0.1:0".parse().unwrap(),
                        "127.0.0.1".parse().unwrap(),
                        [i as u8 + 7; 32],
                        identity,
                        [1; 32],
                    )
                    .unwrap()
                });
                let binding = Binding {
                    nonce: [3; 32],
                    sidecar_sha: [4; 32],
                    context: galaxybridge_quic_media::Context {
                        session: [7; 32],
                        generation: 1,
                        scid: 1,
                        capture_kind: 0,
                        display_id: 0,
                        target_token: 9,
                        enabled: 6,
                    },
                };
                let mut owner = Backend::from_channels(
                    OwnerSlot::acquire().unwrap(),
                    Side::Host,
                    binding,
                    endpoints,
                    None,
                )
                .unwrap();
                // Close exactly one role. The diagnostic site must identify
                // that endpoint rather than infer failure from either sibling.
                owner.endpoints[index].close();
                let scope = first_error::Scope::begin(enabled);
                assert_eq!(owner.poll(), Err(Error::Retired));
                if enabled {
                    let observation = scope.observation().unwrap();
                    assert_eq!(observation.status, 107);
                    assert_eq!(
                        observation.rejection,
                        Some(first_error::Rejection {
                            module: 7,
                            site: (index + 1) as u32,
                            ..Default::default()
                        })
                    );
                } else {
                    assert!(scope.observation().is_none());
                }
                assert!(owner.cleanup().unwrap().complete);
            }
        }
    }
    #[test]
    fn first_cause_reverse_release_site_survives_later_poll_and_retire() {
        use galaxybridge_quic_media::media::first_error;
        let make = || {
            let endpoints = std::array::from_fn(|i| {
                Endpoint::listen(
                    "127.0.0.1:0".parse().unwrap(),
                    "127.0.0.1".parse().unwrap(),
                    [i as u8 + 7; 32],
                    Identity::generate().unwrap(),
                    [1; 32],
                )
                .unwrap()
            });
            let binding = Binding {
                nonce: [3; 32],
                sidecar_sha: [4; 32],
                context: galaxybridge_quic_media::Context {
                    session: [7; 32],
                    generation: 774,
                    scid: 1,
                    capture_kind: 0,
                    display_id: 0,
                    target_token: 9,
                    enabled: 6,
                },
            };
            Backend::from_channels(
                OwnerSlot::acquire().unwrap(),
                Side::Host,
                binding,
                endpoints,
                None,
            )
            .unwrap()
        };
        for enabled in [false, true] {
            let mut owner = make();
            let pool = bulk::BlobPool::small_events();
            for id in 1..=2 {
                owner.held.insert(
                    id,
                    Held::Device {
                        object: Object {
                            id,
                            purpose: 2,
                            barrier: 0,
                            bytes: pool.copy(&[0]).unwrap(),
                            deadline: u64::MAX,
                        },
                        committed: false,
                    },
                );
            }
            let scope = first_error::Scope::begin(enabled);
            owner.release_event(1).unwrap();
            let first = scope.observation();
            drop(scope);
            let original = owner.first_terminal_site.unwrap();
            owner.retire(Error::Io);
            owner.release_event(2).unwrap();
            assert_eq!(owner.first_terminal_site, Some(original));
            assert_eq!(owner.terminal, Some(Error::Retired));
            let scope = first_error::Scope::begin(enabled);
            assert_eq!(owner.poll(), Err(Error::Retired));
            if enabled {
                let initial = first.unwrap();
                let later = scope.observation().unwrap();
                assert_eq!(initial.status, 107);
                assert_eq!(later.status, 107);
                assert_eq!(initial.rejection.unwrap().module, 8);
                assert_eq!(initial.rejection.unwrap().site, original);
                assert_eq!(
                    later.rejection.unwrap().site,
                    original,
                    "later poll must not replace initiating release site"
                );
            } else {
                assert!(first.is_none() && scope.observation().is_none());
            }
            assert!(owner.cleanup().unwrap().complete);
        }
        let mut owner = make();
        owner.retire(Error::Io);
        let scope = first_error::Scope::begin(true);
        assert_eq!(owner.poll(), Err(Error::Retired));
        let retired = scope.observation().unwrap().rejection.unwrap();
        assert_eq!(retired.module, 8);
        drop(scope);
        let mut owner = make();
        owner.child = Some(
            OwnedChild::spawn(&OwnedCommand {
                program: "/usr/bin/true".into(),
                args: vec![],
            })
            .unwrap(),
        );
        let until = Instant::now() + Duration::from_secs(1);
        while !owner.child.as_mut().unwrap().exited().unwrap() {
            assert!(Instant::now() < until);
            std::thread::sleep(Duration::from_millis(1));
        }
        let scope = first_error::Scope::begin(true);
        assert_eq!(owner.poll(), Err(Error::Retired));
        let exited = scope.observation().unwrap().rejection.unwrap();
        assert_eq!(exited.module, 8);
        assert_ne!(exited.site, retired.site);
        assert_eq!(owner.cleanup().unwrap().exit_code, Some(0));
    }
    #[test]
    fn routed_source_preserves_family_and_rejects_invalid_destinations() {
        for peer in ["127.0.0.1", "::1"] {
            let peer: IpAddr = peer.parse().unwrap();
            assert_eq!(routed_source(peer).unwrap(), peer);
        }
        for peer in ["0.0.0.0", "::", "224.0.0.1", "ff02::1", "255.255.255.255"] {
            assert_eq!(routed_source(peer.parse().unwrap()), Err(Error::Protocol));
        }
    }
    #[test]
    fn priority_route_is_exact_and_never_moves_payload_media_or_recovery_au() {
        for kind in [6, 7, 8, 9, 10] {
            let mut payload = b"GQM1".to_vec();
            payload.push(kind);
            assert_eq!(message_route(&payload), 2);
        }
        // Delivery progress must remain ordered behind its media configuration.
        assert_eq!(message_route(b"GQM1\x0d"), 0);
        // A receiver recovery request is control, not the replacement video
        // AU itself. It must not wait behind the media stream it is repairing.
        assert_eq!(message_route(b"GQB1\x04\x03"), 2);
        assert_eq!(message_route(b"GQB1\x04\x02"), 0);
        for kind in [1, 4, 5, 11, 12, 14] {
            let mut payload = b"GQM1".to_vec();
            payload.push(kind);
            assert_eq!(message_route(&payload), 0);
        }
        assert_eq!(message_route(b"GQM"), 0);
        assert_eq!(message_route(b"GBQ1\x08"), 0);
    }
    #[test]
    fn actual_spawn_bootstrap_advertises_distinct_source_to_pinned_listener() {
        // Requires an existing usable non-loopback route. This socket selects
        // an address only: no packet is sent to the declared destination.
        // The explicit fixture input avoids silently choosing a VPN default
        // route whose local address cannot receive ordinary local UDP.
        let destination: IpAddr = std::env::var("GB_QUIC_ROUTE_TEST_DESTINATION")
            .expect("set an existing non-loopback route destination; no packets are sent there")
            .parse()
            .unwrap();
        let route = std::net::UdpSocket::bind("0.0.0.0:0").unwrap();
        route
            .connect(SocketAddr::new(destination, 9))
            .expect("existing IPv4 route prerequisite");
        let source = route.local_addr().unwrap().ip();
        assert!(
            !source.is_unspecified() && !source.is_loopback() && source != destination,
            "this regression requires an existing distinct local IPv4 source"
        );
        let binding = Binding {
            nonce: [3; 32],
            sidecar_sha: [4; 32],
            context: galaxybridge_quic_media::Context {
                session: [0; 32],
                generation: 1,
                scid: 1,
                capture_kind: 0,
                display_id: 0,
                target_token: 9,
                enabled: 6,
            },
        };
        let mut host = Backend::spawn_host(
            HostConfig {
                binding,
                peer_ip: destination,
            },
            OwnedCommand {
                program: "/usr/bin/true".into(),
                args: vec![],
            },
        )
        .unwrap();
        // These are the production spawn owner's actual encoded requests and
        // identities, not independently reconstructed bootstrap lookalikes.
        let startup = host.startup.as_mut().unwrap();
        let requests = Requests::decode(&startup.wire).unwrap();
        let identities = startup.identities.take().unwrap();
        host.retire(Error::Retired);
        let cleanup_end = Instant::now() + Duration::from_secs(2);
        while !host.cleanup().unwrap().complete {
            assert!(Instant::now() < cleanup_end);
            std::thread::sleep(Duration::from_millis(1));
        }
        for (role, identity) in requests.roles.iter().zip(identities) {
            let listener_identity = Identity::generate().unwrap();
            let pin = listener_identity.fingerprint();
            let mut listener = Endpoint::listen(
                SocketAddr::new(source, 0),
                role.expected_ip,
                role.session,
                listener_identity,
                role.fingerprint,
            )
            .unwrap();
            let mut client = Endpoint::connect(
                SocketAddr::new(source, 0),
                listener.local_addr().unwrap(),
                role.session,
                identity,
                pin,
            )
            .unwrap();
            let end = Instant::now() + Duration::from_millis(500);
            while Instant::now() < end
                && !(client.stats().application_ready && listener.stats().application_ready)
            {
                client.poll().unwrap();
                listener.poll().unwrap();
                std::thread::sleep(Duration::from_millis(1));
            }
            let stats = listener.stats();
            assert!(stats.application_ready && client.stats().application_ready,
                "actual bootstrap expected={} source={} destination={} raw_udp={} rejected={} tls={}",
                role.expected_ip, source, destination, stats.udp_socket_received, stats.rejected, stats.reached_tls);
            assert_eq!(role.expected_ip, source);
            assert_eq!(client.local_addr().unwrap().ip(), source);
            client.close();
            listener.close();
        }
        // Preserve the rejection boundary: the phone destination is NOT a
        // valid source for a packet emitted by this actual local socket.
        let a = Identity::generate().unwrap();
        let b = Identity::generate().unwrap();
        let mut wrong = Endpoint::listen(
            SocketAddr::new(source, 0),
            destination,
            [5; 32],
            b,
            a.fingerprint(),
        )
        .unwrap();
        let sender = std::net::UdpSocket::bind(SocketAddr::new(source, 0)).unwrap();
        sender
            .send_to(&[0; 1200], wrong.local_addr().unwrap())
            .unwrap();
        let end = Instant::now() + Duration::from_millis(100);
        while wrong.stats().udp_socket_received == 0 && Instant::now() < end {
            wrong.poll().unwrap();
            std::thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(wrong.stats().rejected, 1);
        assert!(!wrong.stats().reached_tls && !wrong.stats().application_ready);
        wrong.close();
    }
    #[test]
    fn shared_outer_allocator_never_aliases_or_wraps() {
        let mut media = 0;
        assert_eq!(advance_outer(&mut media), Ok(1));
        assert_eq!(advance_outer(&mut media), Ok(2));
        let mut bulk = u64::MAX - 1;
        assert_eq!(advance_outer(&mut bulk), Ok(u64::MAX));
        assert_eq!(advance_outer(&mut bulk), Err(Error::Capacity));
        assert_eq!(bulk, u64::MAX);
        assert_eq!(media, 2);
    }
}
