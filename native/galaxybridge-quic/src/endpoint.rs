use crate::{
    bootstrap::diagnostics::{add, elapsed, increment, Metric, Span, SpanSummary},
    tls::{self, Identity},
    wire, Admission, CertificateFingerprint, CongestionControl, Error, Lane, Message, Received,
    SessionId,
};
use std::{
    collections::VecDeque,
    net::{IpAddr, SocketAddr, UdpSocket},
    ops::Range,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    },
    time::{Duration, Instant},
};

const TIMEOUT: Duration = Duration::from_secs(5);
const UDP_SIZE: usize = 1200;
const DATAGRAM_RECORDS: usize = 32;
const GENERATED_PACKETS: usize = 32;
const DATAGRAM_EXPIRIES: usize = DATAGRAM_RECORDS + GENERATED_PACKETS + 1;
const RECEIVE_RECORDS: usize = 64;
const RELIABLE_BYTES: usize = 64 * 1024;
const RECEIVE_BYTES: usize = 64 * 1024;
const KEEPALIVE_INTERVAL: Duration = Duration::from_millis(tls::IDLE_TIMEOUT_MS / 2);

/// Service opportunities only, never peer-liveness evidence. quiche owns its
/// coalesced PING flag and negotiated idle/PTO timer, including unanswered sends.
#[derive(Default)]
struct Keepalive {
    next: Option<Instant>,
    last: Option<Instant>,
}
impl Keepalive {
    fn observe(&mut self, now: Instant) -> Result<(), ()> {
        if self.last.is_some_and(|last| now < last) {
            return Err(());
        }
        self.last = Some(now);
        Ok(())
    }
    fn opportunity(&mut self, now: Instant, ready: bool, retained: bool) -> Result<bool, ()> {
        self.observe(now)?;
        if !ready {
            self.next = None;
            return Ok(false);
        }
        let due = self.next.is_some_and(|next| now >= next);
        if self.next.is_none() || due {
            self.next = Some(now.checked_add(KEEPALIVE_INTERVAL).ok_or(())?);
        }
        Ok(due && !retained)
    }
}
#[derive(Clone, Copy, PartialEq, Eq)]
enum WritePermit {
    Open,
    One,
    Denied,
}
macro_rules! pressure {
    ($e:ident, $field:ident) => {
        pressure!($e, $field, 1)
    };
    ($e:ident, $field:ident, $count:expr) => {
        add(
            &mut $e.stats.pressure.$field,
            $count,
            &mut $e.stats.pressure.valid,
        )
    };
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Retirement {
    Closed,
    Authentication,
    Protocol,
    ConnectTimeout,
    PeerIdle,
    ReliableStall,
    Io,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DatagramExpiryStage {
    Queued,
    Quiche,
    Generated,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DatagramExpiry {
    pub sequence: u64,
    pub stage: DatagramExpiryStage,
}
#[derive(Clone, Copy, Default, Debug)]
pub struct Stats {
    pub pressure: PressureStats,
    pub path: PathObservation,
    pub socket_buffers: SocketBuffers,
    pub reached_tls: bool,
    pub reached_ready: bool,
    pub tls_failure: tls::VerificationFailure,
    pub datagrams_admitted: u64,
    pub datagrams_received: u64,
    pub datagrams_rejected: u64,
    pub datagrams_generated: u64,
    pub datagrams_udp_sent: u64,
    pub udp_socket_received: u64,
    pub quiche_datagrams_decoded: u64,
    pub quiche_datagrams_pending_records: usize,
    pub quiche_datagrams_pending_bytes: usize,
    pub datagrams_extracted: u64,
    pub quiche_datagrams_evicted: u64,
    pub datagram_observation_valid: bool,
    pub datagram_observation_failures: u64,
    pub receive_resource_failure: bool,
    pub io_errno: i32,
    pub local_close_code: Option<u64>,
    pub peer_close_code: Option<u64>,
    pub quic_timed_out: bool,
    pub authenticated: bool,
    pub application_ready: bool,
    pub retired: bool,
    pub admitted: u64,
    pub delivered: u64,
    pub rejected: u64,
    pub expired: u64,
    pub reliable_backlog_bytes: usize,
    pub datagram_queue_records: usize,
    pub generated_packets: usize,
    pub receive_queue_records: usize,
    pub receive_queue_bytes: usize,
    pub sent_udp_packets: u64,
    pub received_udp_packets: u64,
    pub retirement: Option<Retirement>,
}

#[derive(Clone, Copy, Debug)]
pub struct PressureStats {
    pub valid: bool,
    pub generated_cap_stops: u64,
    pub quiche_done_pending_dg: u64,
    pub future_send_stops: u64,
    pub udp_attempts: u64,
    pub udp_would_block: u64,
    pub udp_would_block_due: u64,
    pub udp_success: u64,
    pub udp_errors: u64,
    pub udp_short: u64,
    pub expiry_submission: u64,
    pub expiry_queued: u64,
    pub expiry_generated: u64,
    pub wrapper_record_stops: u64,
    pub wrapper_byte_stops: u64,
    pub dg_budget_stops: u64,
    pub retained_intake_pauses: u64,
    pub udp_saturated_turns: u64,
    pub generated_write_age: Metric,
    pub write_blocked: SpanSummary,
    pub retained: SpanSummary,
}

#[derive(Clone, Copy, Debug)]
pub struct PathObservation {
    pub terminal: bool,
    pub samples: u64,
    pub unavailable_samples: u64,
    pub valid: bool,
    pub available: bool,
    pub rtt_available: bool,
    pub delivery_rate_available: bool,
    pub max_bandwidth_available: bool,
    pub sample_at_ns: u64,
    pub rtt_ns: u64,
    pub min_rtt_ns: u64,
    pub max_rtt_ns: u64,
    pub rttvar_ns: u64,
    pub cwnd_bytes: u64,
    pub cwnd_min_bytes: u64,
    pub cwnd_max_bytes: u64,
    pub lost_packets: u64,
    pub retrans_packets: u64,
    pub pto_count: u64,
    pub lost_dg_frames: u64,
    pub stream_retrans_bytes: u64,
    pub delivery_rate_bytes_per_second: u64,
    pub delivery_rate_max_bytes_per_second: u64,
    pub pmtu_bytes: u64,
    pub max_bandwidth_bytes_per_second: u64,
}
impl Default for PathObservation {
    fn default() -> Self {
        Self {
            terminal: false,
            samples: 0,
            unavailable_samples: 0,
            valid: true,
            available: false,
            rtt_available: false,
            delivery_rate_available: false,
            max_bandwidth_available: false,
            sample_at_ns: 0,
            rtt_ns: 0,
            min_rtt_ns: 0,
            max_rtt_ns: 0,
            rttvar_ns: 0,
            cwnd_bytes: 0,
            cwnd_min_bytes: 0,
            cwnd_max_bytes: 0,
            lost_packets: 0,
            retrans_packets: 0,
            pto_count: 0,
            lost_dg_frames: 0,
            stream_retrans_bytes: 0,
            delivery_rate_bytes_per_second: 0,
            delivery_rate_max_bytes_per_second: 0,
            pmtu_bytes: 0,
            max_bandwidth_bytes_per_second: 0,
        }
    }
}
#[derive(Clone, Copy, Debug, Default)]
pub struct SocketValue {
    pub available: bool,
    pub bytes: i32,
    pub errno: i32,
}
#[derive(Clone, Copy, Debug, Default)]
pub struct SocketBuffers {
    pub send: SocketValue,
    pub receive: SocketValue,
}
impl SocketBuffers {
    fn query(socket: &UdpSocket) -> Self {
        use std::os::fd::AsRawFd;
        Self::query_with(|option| {
            let mut bytes: libc::c_int = 0;
            let mut len = std::mem::size_of_val(&bytes) as libc::socklen_t;
            // SAFETY: one live owned descriptor and correctly sized integer
            // output. Read-only query: no socket option is set here.
            let result = unsafe {
                libc::getsockopt(
                    socket.as_raw_fd(),
                    libc::SOL_SOCKET,
                    option,
                    (&mut bytes as *mut libc::c_int).cast(),
                    &mut len,
                )
            };
            if result != 0 {
                return Err(std::io::Error::last_os_error().raw_os_error().unwrap_or(0));
            }
            if len as usize != std::mem::size_of_val(&bytes) || bytes < 0 {
                return Err(0);
            }
            Ok(bytes)
        })
    }
    fn query_with(mut query: impl FnMut(libc::c_int) -> Result<i32, i32>) -> Self {
        let mut one = |option| match query(option) {
            Ok(bytes) => SocketValue {
                available: true,
                bytes,
                errno: 0,
            },
            Err(errno) => SocketValue {
                available: false,
                bytes: 0,
                errno,
            },
        };
        Self {
            send: one(libc::SO_SNDBUF),
            receive: one(libc::SO_RCVBUF),
        }
    }
}
impl PathObservation {
    fn observe(&mut self, path: Option<quiche::PathStats>, at: Option<u64>) {
        self.available = false;
        self.rtt_available = false;
        self.delivery_rate_available = false;
        self.max_bandwidth_available = false;
        let Some(at) = at else {
            self.valid = false;
            return;
        };
        if at < self.sample_at_ns {
            self.valid = false;
            return;
        }
        self.sample_at_ns = at;
        let Some(p) = path else {
            increment(&mut self.unavailable_samples, &mut self.valid);
            return;
        };
        let counters = [p.lost, p.retrans, p.total_pto_count, p.dgram_lost];
        let old = [
            self.lost_packets,
            self.retrans_packets,
            self.pto_count,
            self.lost_dg_frames,
        ];
        if counters.iter().zip(old).any(|(new, old)| {
            *new == usize::MAX || u64::try_from(*new).map_or(true, |new| new < old)
        }) || p.stream_retrans_bytes < self.stream_retrans_bytes
            || p.stream_retrans_bytes == u64::MAX
        {
            self.valid = false;
            return;
        }
        let ns = |d: Duration| u64::try_from(d.as_nanos()).ok();
        let measured_rtt = p
            .min_rtt
            .zip(p.max_rtt)
            .and_then(|(min, max)| Some((ns(p.rtt)?, ns(min)?, ns(max)?, ns(p.rttvar)?)));
        if p.min_rtt.is_some() && measured_rtt.is_none() {
            self.valid = false;
            return;
        }
        increment(&mut self.samples, &mut self.valid);
        self.available = true;
        if let Some((rtt, min, max, var)) = measured_rtt {
            self.rtt_available = true;
            self.rtt_ns = rtt;
            self.min_rtt_ns = min;
            self.max_rtt_ns = max;
            self.rttvar_ns = var;
        }
        self.cwnd_bytes = p.cwnd as u64;
        self.cwnd_min_bytes = if self.samples == 1 {
            self.cwnd_bytes
        } else {
            self.cwnd_min_bytes.min(self.cwnd_bytes)
        };
        self.cwnd_max_bytes = self.cwnd_max_bytes.max(self.cwnd_bytes);
        self.lost_packets = p.lost as u64;
        self.retrans_packets = p.retrans as u64;
        self.pto_count = p.total_pto_count as u64;
        self.lost_dg_frames = p.dgram_lost as u64;
        self.stream_retrans_bytes = p.stream_retrans_bytes;
        self.delivery_rate_available = p.delivery_rate > 0 && self.rtt_available;
        self.delivery_rate_bytes_per_second = p.delivery_rate;
        if self.delivery_rate_available {
            self.delivery_rate_max_bytes_per_second =
                self.delivery_rate_max_bytes_per_second.max(p.delivery_rate);
        }
        self.pmtu_bytes = p.pmtu as u64;
        self.max_bandwidth_available =
            self.rtt_available && p.max_bandwidth.is_some_and(|rate| rate > 0);
        self.max_bandwidth_bytes_per_second = p.max_bandwidth.unwrap_or(0);
    }
}
impl Default for PressureStats {
    fn default() -> Self {
        Self {
            valid: true,
            generated_cap_stops: 0,
            quiche_done_pending_dg: 0,
            future_send_stops: 0,
            udp_attempts: 0,
            udp_would_block: 0,
            udp_would_block_due: 0,
            udp_success: 0,
            udp_errors: 0,
            udp_short: 0,
            expiry_submission: 0,
            expiry_queued: 0,
            expiry_generated: 0,
            wrapper_record_stops: 0,
            wrapper_byte_stops: 0,
            dg_budget_stops: 0,
            retained_intake_pauses: 0,
            udp_saturated_turns: 0,
            generated_write_age: Metric::default(),
            write_blocked: SpanSummary::default(),
            retained: SpanSummary::default(),
        }
    }
}

// The allocation, including retransmission references inside quiche, holds its
// admission charge until its LAST reference is dropped (normally on ACK).
// Counting stream_send's accepted bytes alone would miss retained retransmits.
struct Allocation {
    bytes: Vec<u8>,
    charge: Option<Arc<AtomicUsize>>,
}
impl Drop for Allocation {
    fn drop(&mut self) {
        if let Some(charge) = &self.charge {
            charge.fetch_sub(self.bytes.len(), Ordering::Relaxed);
        }
    }
}
#[derive(Clone)]
struct Buffer {
    allocation: Arc<Allocation>,
    range: Range<usize>,
}
impl std::fmt::Debug for Buffer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Buffer")
            .field("len", &self.range.len())
            .finish()
    }
}
impl Buffer {
    fn new(bytes: Vec<u8>, charge: Option<Arc<AtomicUsize>>) -> Self {
        let len = bytes.len();
        if let Some(counter) = &charge {
            counter.fetch_add(len, Ordering::Relaxed);
        }
        Self {
            allocation: Arc::new(Allocation { bytes, charge }),
            range: 0..len,
        }
    }
}
impl AsRef<[u8]> for Buffer {
    fn as_ref(&self) -> &[u8] {
        &self.allocation.bytes[self.range.clone()]
    }
}
impl quiche::BufSplit for Buffer {
    fn split_at(&mut self, at: usize) -> Self {
        let middle = self.range.start + at;
        let tail = Self {
            allocation: self.allocation.clone(),
            range: middle..self.range.end,
        };
        self.range.end = middle;
        tail
    }
}
#[derive(Clone, Default, Debug)]
struct Buffers;
impl quiche::BufFactory for Buffers {
    type Buf = Buffer;
    type DgramBuf = Vec<u8>;
    fn buf_from_slice(bytes: &[u8]) -> Buffer {
        Buffer::new(bytes.to_vec(), None)
    }
    fn dgram_buf_from_slice(bytes: &[u8]) -> Vec<u8> {
        bytes.to_vec()
    }
}
struct Datagram {
    bytes: Vec<u8>,
    deadline: Instant,
    sequence: u64,
}
struct Packet {
    generated_at: Instant,
    bytes: [u8; UDP_SIZE],
    len: usize,
    at: Instant,
    expires: Option<Instant>,
    datagram_sequence: Option<u64>,
}

#[derive(Clone, Copy)]
struct DatagramObservation {
    decoded: usize,
    records: usize,
    bytes: usize,
}
impl DatagramObservation {
    fn has_receive_headroom(self) -> bool {
        // Every decoded DATAGRAM frame consumes at least one packet byte.
        // Reserve the maximum accepted UDP size before quiche's usize counter
        // increments, avoiding a dependency overflow before we can observe it.
        self.decoded.checked_add(UDP_SIZE).is_some()
    }
    fn capture(connection: &quiche::Connection<Buffers>) -> Self {
        Self {
            decoded: connection.stats().dgram_recv,
            records: connection.dgram_recv_queue_len(),
            bytes: connection.dgram_recv_queue_byte_size(),
        }
    }
    fn eviction_since(self, before: Self) -> Option<u64> {
        if self.decoded == usize::MAX
            || before.decoded == usize::MAX
            || self.records > DATAGRAM_RECORDS
            || before.records > DATAGRAM_RECORDS
            || self.bytes > DATAGRAM_RECORDS * UDP_SIZE
            || before.bytes > DATAGRAM_RECORDS * UDP_SIZE
            || (self.records == 0 && self.bytes != 0)
            || (before.records == 0 && before.bytes != 0)
        {
            return None;
        }
        let decoded = self.decoded.checked_sub(before.decoded)?;
        let evicted = before
            .records
            .checked_add(decoded)?
            .checked_sub(self.records)?;
        u64::try_from(evicted).ok()
    }
}

/// One attempt, one selected UDP path, one bidirectional stream. All methods
/// are nonblocking; the owner must poll no later than next_wakeup().
pub struct Endpoint {
    keepalive: Keepalive,
    #[cfg(test)]
    keepalive_requests: u64,
    needs_writable: bool,
    write_permit: WritePermit,
    preserve_committed: bool,
    #[cfg(test)]
    poll_io: Option<std::rc::Rc<TestPollIo>>,
    #[cfg(test)]
    observation_clock: Option<Instant>,
    #[cfg(test)]
    path_queries: std::cell::Cell<u64>,
    #[cfg(test)]
    pacing_enabled: bool,
    last_path_sample: Option<Instant>,
    write_blocked: Span,
    retained: Span,
    tls_failure: Arc<std::sync::atomic::AtomicU8>,
    terminal: Option<Stats>,
    socket: Option<UdpSocket>,
    local: SocketAddr,
    peer: Option<SocketAddr>,
    expected_ip: IpAddr,
    session: SessionId,
    pin: CertificateFingerprint,
    config: Option<quiche::Config>,
    is_server: bool,
    connection: Option<quiche::Connection<Buffers>>,
    created: Instant,
    stats: Stats,
    reliable: VecDeque<Buffer>,
    reliable_charge: Arc<AtomicUsize>,
    reliable_progress: Instant,
    last_reliable_charge: usize,
    prioritize_reliable: bool,
    datagrams: VecDeque<Datagram>,
    quiche_datagram_deadline: Option<Instant>,
    quiche_datagram_sequence: Option<u64>,
    datagram_expiries: VecDeque<DatagramExpiry>,
    generated: VecDeque<Packet>,
    received: VecDeque<Received>,
    receive_bytes: usize,
    stream_record: [u8; wire::MAX_RECORD + 4],
    stream_used: usize,
    stream_needed: usize,
}
impl Endpoint {
    pub fn listen(
        bind: SocketAddr,
        expected_ip: IpAddr,
        session: SessionId,
        identity: Identity,
        pin: CertificateFingerprint,
    ) -> Result<Self, Error> {
        Self::listen_with_congestion_control(
            bind,
            expected_ip,
            session,
            identity,
            pin,
            CongestionControl::Cubic,
        )
    }
    pub fn listen_with_congestion_control(
        bind: SocketAddr,
        expected_ip: IpAddr,
        session: SessionId,
        identity: Identity,
        pin: CertificateFingerprint,
        congestion_control: CongestionControl,
    ) -> Result<Self, Error> {
        Self::listen_with_transport_options(
            bind,
            expected_ip,
            session,
            identity,
            pin,
            congestion_control,
            None,
            None,
            true,
        )
    }
    pub fn listen_with_transport_options(
        bind: SocketAddr,
        expected_ip: IpAddr,
        session: SessionId,
        identity: Identity,
        pin: CertificateFingerprint,
        congestion_control: CongestionControl,
        max_pacing_rate: Option<u64>,
        max_ack_delay_ms: Option<u64>,
        pacing_enabled: bool,
    ) -> Result<Self, Error> {
        Self::new(
            bind,
            expected_ip,
            session,
            identity,
            pin,
            congestion_control,
            max_pacing_rate,
            max_ack_delay_ms,
            pacing_enabled,
        )
    }
    pub fn connect(
        bind: SocketAddr,
        peer: SocketAddr,
        session: SessionId,
        identity: Identity,
        pin: CertificateFingerprint,
    ) -> Result<Self, Error> {
        Self::connect_with_congestion_control(
            bind,
            peer,
            session,
            identity,
            pin,
            CongestionControl::Cubic,
        )
    }
    pub fn connect_with_congestion_control(
        bind: SocketAddr,
        peer: SocketAddr,
        session: SessionId,
        identity: Identity,
        pin: CertificateFingerprint,
        congestion_control: CongestionControl,
    ) -> Result<Self, Error> {
        Self::connect_with_transport_options(
            bind,
            peer,
            session,
            identity,
            pin,
            congestion_control,
            None,
            true,
        )
    }
    pub fn connect_with_transport_options(
        bind: SocketAddr,
        peer: SocketAddr,
        session: SessionId,
        identity: Identity,
        pin: CertificateFingerprint,
        congestion_control: CongestionControl,
        max_ack_delay_ms: Option<u64>,
        pacing_enabled: bool,
    ) -> Result<Self, Error> {
        if peer.port() == 0 {
            return Err(Error::InvalidConfiguration);
        }
        let mut endpoint = Self::new(
            bind,
            peer.ip(),
            session,
            identity,
            pin,
            congestion_control,
            None,
            max_ack_delay_ms,
            pacing_enabled,
        )?;
        let mut cid = [0; 16];
        boring::rand::rand_bytes(&mut cid)?;
        endpoint.connection = Some(quiche::connect_with_buffer_factory(
            None,
            &quiche::ConnectionId::from_ref(&cid),
            endpoint.local,
            peer,
            endpoint
                .config
                .as_mut()
                .ok_or(Error::InvalidConfiguration)?,
        )?);
        endpoint.peer = Some(peer);
        endpoint.is_server = false;
        Ok(endpoint)
    }
    fn new(
        bind: SocketAddr,
        expected_ip: IpAddr,
        session: SessionId,
        identity: Identity,
        pin: CertificateFingerprint,
        congestion_control: CongestionControl,
        max_pacing_rate: Option<u64>,
        max_ack_delay_ms: Option<u64>,
        pacing_enabled: bool,
    ) -> Result<Self, Error> {
        if bind.is_ipv4() != expected_ip.is_ipv4()
            || expected_ip.is_unspecified()
            || expected_ip.is_multicast()
            || expected_ip == IpAddr::V4(std::net::Ipv4Addr::BROADCAST)
        {
            return Err(Error::InvalidConfiguration);
        }
        let tls_failure = Arc::new(std::sync::atomic::AtomicU8::new(0));
        let config = tls::config(
            &identity,
            pin,
            tls_failure.clone(),
            congestion_control,
            max_pacing_rate,
            max_ack_delay_ms,
            pacing_enabled,
        )?;
        let socket = UdpSocket::bind(bind)?;
        socket.set_nonblocking(true)?;
        disable_fragmentation(&socket, bind.is_ipv4())?;
        let local = socket.local_addr()?;
        let socket_buffers = SocketBuffers::query(&socket);
        let now = Instant::now();
        Ok(Self {
            keepalive: Keepalive {
                next: None,
                last: Some(now),
            },
            #[cfg(test)]
            keepalive_requests: 0,
            needs_writable: false,
            write_permit: WritePermit::Open,
            preserve_committed: false,
            #[cfg(test)]
            poll_io: None,
            #[cfg(test)]
            observation_clock: None,
            #[cfg(test)]
            path_queries: std::cell::Cell::new(0),
            #[cfg(test)]
            pacing_enabled,
            last_path_sample: None,
            write_blocked: Span::default(),
            retained: Span::default(),
            tls_failure,
            terminal: None,
            socket: Some(socket),
            local,
            peer: None,
            expected_ip,
            session,
            pin,
            config: Some(config),
            is_server: true,
            connection: None,
            created: now,
            stats: Stats {
                socket_buffers,
                ..Stats::default()
            },
            reliable: VecDeque::new(),
            reliable_charge: Arc::new(AtomicUsize::new(0)),
            reliable_progress: now,
            last_reliable_charge: 0,
            prioritize_reliable: false,
            datagrams: VecDeque::new(),
            quiche_datagram_deadline: None,
            quiche_datagram_sequence: None,
            datagram_expiries: VecDeque::new(),
            generated: VecDeque::new(),
            received: VecDeque::new(),
            receive_bytes: 0,
            stream_record: [0; wire::MAX_RECORD + 4],
            stream_used: 0,
            stream_needed: 4,
        })
    }
    pub fn local_addr(&self) -> Result<SocketAddr, Error> {
        Ok(self.local)
    }
    /// Mark every UDP packet from this authenticated endpoint with one DSCP
    /// class. The caller owns role selection; ECN bits remain clear so quiche
    /// can continue to own congestion signalling independently.
    pub fn set_dscp(&mut self, dscp: u8) -> Result<(), Error> {
        if dscp > 63 {
            return Err(Error::InvalidConfiguration);
        }
        let socket = self.socket.as_ref().ok_or(Error::InvalidConfiguration)?;
        set_traffic_class(socket, self.local.is_ipv4(), dscp << 2)
    }
    /// Datagram deadline is an absolute Instant in this process. Reliable
    /// messages ignore it and instead use the endpoint's five-second stall timer.
    /// Rejected messages are never copied into endpoint storage.
    pub fn send(&mut self, message: Message, deadline: Instant) -> Admission {
        if self.stats.retired {
            return Admission::Retired;
        }
        let now = Instant::now();
        if message.lane == Lane::Datagram && deadline <= now {
            self.stats.expired += 1;
            pressure!(self, expiry_submission);
            return Admission::Expired;
        }
        if message.payload.len() > wire::MAX_PAYLOAD {
            self.stats.rejected += 1;
            self.stats.datagrams_rejected += u64::from(message.lane == Lane::Datagram);
            return Admission::TooLarge;
        }
        if !self.stats.application_ready {
            return Admission::Backpressured;
        }
        match message.lane {
            Lane::Datagram => {
                let capacity = self
                    .connection
                    .as_ref()
                    .and_then(|c| c.dgram_max_writable_len())
                    .unwrap_or(0);
                if wire::HEADER + message.payload.len() > capacity {
                    self.stats.rejected += 1;
                    self.stats.datagrams_rejected += 1;
                    return Admission::TooLarge;
                }
                self.expire_datagrams(now);
                if self.datagrams.len() + usize::from(self.quiche_datagram_deadline.is_some())
                    >= DATAGRAM_RECORDS
                {
                    return Admission::Backpressured;
                }
                let Ok(bytes) = wire::encode(&self.session, &message) else {
                    return Admission::TooLarge;
                };
                self.datagrams.push_back(Datagram {
                    bytes,
                    deadline,
                    sequence: message.sequence,
                });
                self.stats.datagrams_admitted += 1;
            }
            Lane::Reliable => {
                let charge = self.reliable_charge.load(Ordering::Relaxed);
                if charge + wire::HEADER + 4 + message.payload.len() > RELIABLE_BYTES {
                    return Admission::Backpressured;
                }
                let Ok(bytes) = wire::encode_reliable(&self.session, &message) else {
                    return Admission::TooLarge;
                };
                if charge == 0 || charge < self.last_reliable_charge {
                    self.reliable_progress = now;
                }
                self.reliable
                    .push_back(Buffer::new(bytes, Some(self.reliable_charge.clone())));
                self.last_reliable_charge = self.reliable_charge.load(Ordering::Relaxed);
            }
        }
        self.stats.admitted += 1;
        Admission::Accepted
    }
    pub fn poll(&mut self) -> Result<(), Error> {
        if self.stats.retired {
            return Ok(());
        }
        if let Err(error) = self.poll_inner() {
            if let Error::Io(ref error) = error {
                self.stats.io_errno = error.raw_os_error().unwrap_or(0);
            }
            self.retire(Retirement::Io);
            return Err(error);
        }
        self.sample_path(self.observation_now());
        Ok(())
    }
    fn path_at(&self, now: Instant) -> PathObservation {
        let mut result = self.stats.path;
        let path = self.connection.as_ref().and_then(|connection| {
            #[cfg(test)]
            self.path_queries.set(self.path_queries.get() + 1);
            let mut paths = connection.path_stats().filter(|p| p.active);
            let path = paths.next()?;
            if paths.next().is_some()
                || path.local_addr != self.local
                || Some(path.peer_addr) != self.peer
            {
                result.valid = false;
                return None;
            }
            Some(path)
        });
        result.observe(path, elapsed(self.created, now));
        result
    }
    fn sample_path(&mut self, now: Instant) {
        if self.stats.retired || self.stats.path.terminal {
            return;
        }
        if let Some(last) = self.last_path_sample {
            let Some(gap) = now.checked_duration_since(last) else {
                self.stats.path.valid = false;
                return;
            };
            if gap < Duration::from_millis(100) {
                return;
            }
        }
        self.stats.path = self.path_at(now);
        self.last_path_sample = Some(now);
    }
    fn poll_inner(&mut self) -> Result<(), Error> {
        let now = self.service_now();
        if self.keepalive.observe(now).is_err() {
            self.retire(Retirement::Protocol);
            return Ok(());
        }
        let charge = self.reliable_charge.load(Ordering::Relaxed);
        if charge < self.last_reliable_charge {
            self.reliable_progress = now;
        }
        self.last_reliable_charge = charge;
        if charge > 0 && now.duration_since(self.reliable_progress) >= TIMEOUT {
            self.retire(Retirement::ReliableStall);
            return Ok(());
        }
        if !self.stats.application_ready && now.duration_since(self.created) >= TIMEOUT {
            self.retire(Retirement::ConnectTimeout);
            return Ok(());
        }
        self.expire_datagrams(now);
        self.begin_write_turn()?;
        self.flush_packets(now)?;
        let mut datagram_budget = RECEIVE_RECORDS;
        let mut stream_budget = RECEIVE_RECORDS * 2;
        self.read_ready_application(&mut datagram_budget, &mut stream_budget);
        if self.stats.retired {
            return Ok(());
        }
        // Bounded work per poll also prevents a UDP flood from starving timers.
        for read_index in 0..64 {
            // Never put another packet into an undrained quiche DG queue.
            // The caller owns release of the bounded wrapper queue; no spin.
            if self
                .connection
                .as_ref()
                .is_some_and(|c| c.dgram_recv_queue_len() > 0)
            {
                pressure!(self, retained_intake_pauses);
                self.retained.start(Instant::now());
                break;
            }
            let mut bytes = [0; UDP_SIZE + 1];
            let result = self
                .socket
                .as_ref()
                .ok_or(Error::InvalidConfiguration)?
                .recv_from(&mut bytes);
            let (len, from) = match result {
                Ok(result) => result,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(e) => return Err(e.into()),
            };
            self.stats.udp_socket_received += 1;
            if read_index == 63 {
                pressure!(self, udp_saturated_turns);
            }
            if len > UDP_SIZE
                || from.ip() != self.expected_ip
                || self.peer.is_some_and(|peer| peer != from)
            {
                self.stats.rejected += 1;
                continue;
            }
            if self.connection.is_none() {
                let header =
                    match quiche::Header::from_slice(&mut bytes[..len], quiche::MAX_CONN_ID_LEN) {
                        Ok(h) => h,
                        Err(_) => continue,
                    };
                if header.ty != quiche::Type::Initial || header.version != quiche::PROTOCOL_VERSION
                {
                    continue;
                }
                self.connection = Some(quiche::accept_with_buf_factory(
                    &header.dcid,
                    None,
                    self.local,
                    from,
                    self.config.as_mut().ok_or(Error::InvalidConfiguration)?,
                )?);
                self.peer = Some(from);
            }
            let connection = self
                .connection
                .as_mut()
                .ok_or(Error::InvalidConfiguration)?;
            let before = DatagramObservation::capture(connection);
            if !before.has_receive_headroom() {
                self.observation_failed();
                return Ok(());
            }
            let result = connection.recv(
                &mut bytes[..len],
                quiche::RecvInfo {
                    from,
                    to: self.local,
                },
            );
            let after = DatagramObservation::capture(connection);
            if result.is_ok() {
                self.stats.received_udp_packets += 1;
            }
            // Observe even failed/closing receives before any extraction or
            // retirement destroys the synchronous conservation evidence.
            if !self.observe_datagram_receive(Some(before), Some(after)) {
                return Ok(());
            }
            match result {
                Ok(_) => {}
                Err(quiche::Error::Done) => {}
                Err(_) => {
                    self.retire(Retirement::Authentication);
                    return Ok(());
                }
            }
            if self
                .connection
                .as_ref()
                .is_some_and(|c| c.is_closed() || c.is_draining())
            {
                self.retire(Retirement::Closed);
                return Ok(());
            }
            self.read_ready_application(&mut datagram_budget, &mut stream_budget);
            if self.stats.retired {
                return Ok(());
            }
        }
        let Some(connection) = self.connection.as_mut() else {
            return Ok(());
        };
        if connection
            .timeout()
            .is_some_and(|timeout| timeout.is_zero())
        {
            connection.on_timeout();
        }
        if connection.is_closed() || connection.is_draining() {
            self.retire(Retirement::PeerIdle);
            return Ok(());
        }
        // Expired native timers above win. Arming requires the actual session
        // preface, not TLS alone. Neither queued ciphertext nor WouldBlock may
        // acquire another periodic request; missed periods are never replayed.
        let ready =
            connection.is_established() && self.stats.authenticated && self.stats.application_ready;
        let due = match self.keepalive.opportunity(
            self.service_now(),
            ready,
            self.needs_writable || !self.generated.is_empty(),
        ) {
            Ok(due) => due,
            Err(()) => {
                self.retire(Retirement::Protocol);
                return Ok(());
            }
        };
        if due {
            if self
                .connection
                .as_mut()
                .unwrap()
                .send_ack_eliciting()
                .is_err()
            {
                self.retire(Retirement::Protocol);
                return Ok(());
            }
            #[cfg(test)]
            {
                self.keepalive_requests += 1;
            }
        }
        if self.stats.authenticated {
            self.write_reliable()?;
        }
        self.generate_packets_with_drain(true)?;
        self.flush_packets(self.service_now())?;
        Ok(())
    }
    fn read_ready_application(&mut self, datagram_budget: &mut usize, stream_budget: &mut usize) {
        let Some(connection) = self.connection.as_ref() else {
            return;
        };
        if connection.is_established() && !self.stats.authenticated {
            if connection.application_proto() != tls::ALPN
                || !connection
                    .peer_cert()
                    .is_some_and(|der| boring::memcmp::eq(&boring::sha::sha256(der), &self.pin))
            {
                self.retire(Retirement::Authentication);
                return;
            }
            self.stats.authenticated = true;
            self.stats.reached_tls = true;
            if !self.is_server {
                self.reliable
                    .push_front(Buffer::new(preface(b"GQH1", &self.session), None));
            }
        }
        if self.stats.authenticated {
            self.read_application(datagram_budget, stream_budget);
        }
    }
    fn observation_failed(&mut self) {
        self.stats.datagram_observation_valid = false;
        self.stats.datagram_observation_failures =
            self.stats.datagram_observation_failures.saturating_add(1);
        self.stats.receive_resource_failure = true;
        self.retire(Retirement::Protocol);
    }
    fn observe_datagram_receive(
        &mut self,
        before: Option<DatagramObservation>,
        after: Option<DatagramObservation>,
    ) -> bool {
        let measured = before.zip(after).and_then(|(before, after)| {
            if u64::try_from(before.decoded).ok()? != self.stats.quiche_datagrams_decoded {
                return None;
            }
            if self
                .stats
                .quiche_datagrams_decoded
                .checked_sub(self.stats.datagrams_extracted)?
                .checked_sub(self.stats.quiche_datagrams_evicted)?
                != u64::try_from(before.records).ok()?
            {
                return None;
            }
            let evicted = after.eviction_since(before)?;
            Some((
                u64::try_from(after.decoded).ok()?,
                self.stats.quiche_datagrams_evicted.checked_add(evicted)?,
                evicted,
            ))
        });
        let Some((decoded, total_evicted, evicted)) = measured else {
            self.observation_failed();
            return false;
        };
        self.stats.quiche_datagrams_decoded = decoded;
        self.stats.quiche_datagrams_evicted = total_evicted;
        self.stats.datagram_observation_valid = true;
        if evicted > 0 {
            self.stats.receive_resource_failure = true;
            self.retire(Retirement::Protocol);
            return false;
        }
        true
    }
    fn write_reliable(&mut self) -> Result<(), Error> {
        let Some(connection) = self.connection.as_mut() else {
            return Ok(());
        };
        for _ in 0..64 {
            let Some(buffer) = self.reliable.pop_front() else {
                break;
            };
            // Keep a cheap reference because quiche consumes the argument even
            // when congestion/stream creation prevents a write.
            match connection.stream_send_zc(0, buffer.clone(), false) {
                Ok((_, Some(tail))) => {
                    self.reliable.push_front(tail);
                    break;
                }
                Ok((_, None)) => {}
                Err(quiche::Error::Done | quiche::Error::InvalidStreamState(_)) => {
                    self.reliable.push_front(buffer);
                    break;
                }
                Err(_) => {
                    self.retire(Retirement::Protocol);
                    return Ok(());
                }
            }
        }
        Ok(())
    }
    fn expire_datagrams(&mut self, now: Instant) {
        let expired = self
            .datagrams
            .iter()
            .filter(|d| d.deadline <= now)
            .map(|d| d.sequence)
            .collect::<Vec<_>>();
        self.datagrams.retain(|d| d.deadline > now);
        self.stats.expired += expired.len() as u64;
        pressure!(self, expiry_queued, expired.len() as u64);
        for sequence in expired {
            self.record_datagram_expiry(sequence, DatagramExpiryStage::Queued);
        }
        if self
            .quiche_datagram_deadline
            .is_some_and(|deadline| deadline <= now)
        {
            if let Some(connection) = self.connection.as_mut() {
                connection.dgram_purge_outgoing(|_: &[u8]| true);
            }
            self.quiche_datagram_deadline = None;
            if let Some(sequence) = self.quiche_datagram_sequence.take() {
                self.record_datagram_expiry(sequence, DatagramExpiryStage::Quiche);
            }
            self.stats.expired += 1;
            pressure!(self, expiry_queued);
        }
    }
    fn record_datagram_expiry(&mut self, sequence: u64, stage: DatagramExpiryStage) {
        if self.datagram_expiries.len() == DATAGRAM_EXPIRIES {
            self.datagram_expiries.pop_front();
        }
        self.datagram_expiries
            .push_back(DatagramExpiry { sequence, stage });
    }
    /// Returns late ownership failures after a datagram was accepted. The
    /// bounded queue can hold every datagram owned by one poll turn; callers
    /// using this signal for recovery must drain it after each poll.
    pub fn take_datagram_expiry(&mut self) -> Option<DatagramExpiry> {
        self.datagram_expiries.pop_front()
    }
    /// Preserve QUIC's committed packet ownership on realtime media endpoints.
    /// Plaintext still expires; generated ciphertext retains FIFO, pacing and
    /// the existing 32-packet bound until UDP send or endpoint retirement.
    pub fn preserve_committed_datagrams(&mut self) {
        self.preserve_committed = true;
    }

    /// Discard selected plaintext datagrams. With committed preservation,
    /// packets already produced by quiche.send() cannot be withdrawn: they may
    /// carry ACK/control and have already consumed recovery/probe accounting.
    pub fn discard_datagrams(&mut self, discard: impl Fn(u64) -> bool) {
        self.datagrams.retain(|d| !discard(d.sequence));
        if self.quiche_datagram_sequence.is_some_and(&discard) {
            if let Some(connection) = self.connection.as_mut() {
                connection.dgram_purge_outgoing(|_: &[u8]| true);
            }
            self.quiche_datagram_deadline = None;
            self.quiche_datagram_sequence = None;
        }
        if !self.preserve_committed {
            self.generated.retain(|p| {
                p.datagram_sequence
                    .is_none_or(|sequence| !discard(sequence))
            });
        }
    }
    /// Give one explicitly selected reliable recovery transfer clean packets.
    /// Ordinary reliable control retains the original datagram interleaving.
    pub fn prioritize_reliable_generation(&mut self) {
        if !self.prioritize_reliable {
            self.preempt_staged_datagram_for_reliable();
            self.prioritize_reliable = true;
        }
    }
    fn preempt_staged_datagram_for_reliable(&mut self) {
        // Queued and already generated datagrams cannot acquire newly queued
        // reliable bytes. Keep them owned: only the datagram already staged
        // inside quiche could be coalesced with the recovery stream by the
        // next connection.send(). Purging that one stage prevents mixed
        // recovery packets without manufacturing loss for unrelated audio or
        // live video that still has time to meet its deadline.
        let quiche = self.quiche_datagram_sequence.take();
        if quiche.is_some() {
            if let Some(connection) = self.connection.as_mut() {
                connection.dgram_purge_outgoing(|_: &[u8]| true);
            }
            self.quiche_datagram_deadline = None;
        }

        // This is intentional recovery replacement, not evidence of network
        // loss. Reporting it through take_datagram_expiry() would make the
        // media owner request another keyframe for the packet it deliberately
        // superseded and could create an unbounded recovery loop.
    }
    #[cfg(test)]
    fn generate_packets(&mut self) -> Result<(), Error> {
        // Existing descriptor-boundary fixtures intentionally stage ciphertext.
        self.generate_packets_with_drain(false)
    }
    fn generate_packets_with_drain(&mut self, drain: bool) -> Result<(), Error> {
        let reliable_only = self.prioritize_reliable;
        let mut output_drained = false;
        for _ in 0..GENERATED_PACKETS {
            if self.generated.len() == GENERATED_PACKETS {
                break;
            }
            self.expire_datagrams(Instant::now());
            let Some(connection) = self.connection.as_mut() else {
                break;
            };
            if !reliable_only && self.quiche_datagram_deadline.is_none() {
                if let Some(datagram) = self.datagrams.pop_front() {
                    if connection.dgram_send_buf(datagram.bytes).is_err() {
                        self.stats.rejected += 1;
                        self.stats.datagrams_rejected += 1;
                    } else {
                        self.quiche_datagram_deadline = Some(datagram.deadline);
                        self.quiche_datagram_sequence = Some(datagram.sequence);
                    }
                }
            }
            let before = connection.stats().dgram_sent;
            let mut packet = Packet {
                generated_at: Instant::now(),
                bytes: [0; UDP_SIZE],
                len: 0,
                at: Instant::now(),
                expires: None,
                datagram_sequence: None,
            };
            match connection.send(&mut packet.bytes) {
                Ok((len, info)) => {
                    packet.generated_at = Instant::now();
                    if Some(info.to) != self.peer || len > UDP_SIZE {
                        self.retire(Retirement::Protocol);
                        break;
                    }
                    packet.len = len;
                    packet.at = info.at;
                    if connection.stats().dgram_sent > before {
                        packet.expires = self.quiche_datagram_deadline.take();
                        packet.datagram_sequence = self.quiche_datagram_sequence.take();
                        self.stats.datagrams_generated += 1;
                        #[cfg(test)]
                        if let Some(io) = &self.poll_io {
                            if let Some(deadline) = io.committed_deadline.get() {
                                packet.expires = Some(deadline);
                                io.preserved_committed.set(io.preserved_committed.get() + 1);
                            }
                        }
                    }
                    self.generated.push_back(packet);
                    #[cfg(test)]
                    if let Some(io) = &self.poll_io {
                        if let Some(delay) = io.generation_delays.borrow_mut().pop_front() {
                            // Model bounded work after genuine quiche packet
                            // commitment; use elapsed real time, not a fake ACK.
                            std::thread::sleep(delay);
                            io.now.set(Instant::now());
                        }
                    }
                }
                Err(quiche::Error::Done) => {
                    output_drained = true;
                    if self.quiche_datagram_deadline.is_some()
                        || !self.datagrams.is_empty()
                        || connection.dgram_send_queue_len() > 0
                    {
                        pressure!(self, quiche_done_pending_dg);
                    }
                    break;
                }
                Err(_) => {
                    self.retire(Retirement::Protocol);
                    break;
                }
            }
            if drain {
                // quiche already committed this packet to recovery/accounting.
                // Try the existing deadline/pacing/permit-checked socket drain
                // before unrelated later generation consumes its remaining TTL.
                // The turn still generates at most GENERATED_PACKETS packets.
                self.flush_packets(self.service_now())?;
            }
        }
        // The barrier is only for the generation that first carries the
        // explicitly selected recovery stream. Keeping it until ACK would
        // hold live media for at least one RTT and turn healthy queued frames
        // into a new recovery storm. If quiche still has output (or the stream
        // queue could not be submitted), retain the barrier for the next poll.
        if reliable_only && output_drained && self.reliable.is_empty() {
            self.prioritize_reliable = false;
        }
        if self.generated.len() == GENERATED_PACKETS {
            pressure!(self, generated_cap_stops);
        }
        Ok(())
    }
    fn begin_write_turn(&mut self) -> Result<(), Error> {
        // Only poll starts a turn. Expiring/emptying/refilling a queue or a
        // successful write cannot restore a permit already consumed this turn.
        self.write_permit = WritePermit::Open;
        if self.needs_writable && !self.generated.is_empty() {
            let socket = self
                .socket
                .as_ref()
                .ok_or_else(|| std::io::Error::from_raw_os_error(libc::EBADF))?;
            #[cfg(test)]
            if let Some(io) = &self.poll_io {
                self.write_permit = writable_permit_with(socket, |fd, count, timeout| {
                    io.queries.set(io.queries.get() + 1);
                    use std::os::fd::AsRawFd;
                    assert_eq!(
                        (fd.fd, fd.events, count, timeout),
                        (socket.as_raw_fd(), libc::POLLOUT, 1, 0)
                    );
                    match io.readiness.borrow_mut().pop_front().unwrap_or(Ok(0)) {
                        Ok(events) => {
                            fd.revents = events;
                            Ok(i32::from(events != 0))
                        }
                        Err(errno) => Err(std::io::Error::from_raw_os_error(errno)),
                    }
                })?;
                return Ok(());
            }
            self.write_permit = writable_permit_with(socket, |fd, count, timeout| {
                // SAFETY: one live owned descriptor, one correctly sized pollfd.
                let result = unsafe { libc::poll(fd, count, timeout) };
                if result < 0 {
                    Err(std::io::Error::last_os_error())
                } else {
                    Ok(result)
                }
            })?;
        }
        Ok(())
    }
    fn flush_packets(&mut self, now: Instant) -> Result<(), Error> {
        #[cfg(test)]
        if let Some(io) = self.poll_io.clone() {
            return self.flush_packets_with(
                now,
                || io.now.get(),
                |socket, bytes, peer| {
                    io.writes.borrow_mut().push(bytes.to_vec());
                    let (error, advance) = io
                        .actions
                        .borrow_mut()
                        .pop_front()
                        .unwrap_or((io.send_error.get(), None));
                    let result = match error {
                        Some(errno) => Err(std::io::Error::from_raw_os_error(errno)),
                        None => socket.send_to(bytes, peer),
                    };
                    if let Some(time) = advance {
                        io.now.set(time);
                    }
                    result
                },
            );
        }
        self.flush_packets_with(now, Instant::now, |socket, bytes, peer| {
            socket.send_to(bytes, peer)
        })
    }
    fn flush_packets_with(
        &mut self,
        now: Instant,
        mut clock: impl FnMut() -> Instant,
        mut send: impl FnMut(&UdpSocket, &[u8], SocketAddr) -> std::io::Result<usize>,
    ) -> Result<(), Error> {
        // Legacy strict deadline users may expire generated packets. Realtime
        // media preserves commitment so ACK/probe accounting is not withdrawn.
        let expired_count = self
            .generated
            .iter()
            .filter(|p| {
                !self.preserve_committed && p.expires.is_some_and(|deadline| deadline <= now)
            })
            .count();
        let expired = self
            .generated
            .iter()
            .filter(|p| {
                !self.preserve_committed && p.expires.is_some_and(|deadline| deadline <= now)
            })
            .filter_map(|p| p.datagram_sequence)
            .collect::<Vec<_>>();
        self.generated.retain(|p| {
            self.preserve_committed || !p.expires.is_some_and(|deadline| deadline <= now)
        });
        self.stats.expired += expired_count as u64;
        pressure!(self, expiry_generated, expired_count as u64);
        for sequence in expired {
            self.record_datagram_expiry(sequence, DatagramExpiryStage::Generated);
        }
        while let Some(packet) = self.generated.front() {
            // Earlier sends or descheduling can consume this packet's budget.
            // Recheck its own deadline at the last decision before each send.
            let now = clock();
            if !self.preserve_committed && packet.expires.is_some_and(|deadline| deadline <= now) {
                let packet = self.generated.pop_front().unwrap();
                if let Some(sequence) = packet.datagram_sequence {
                    self.record_datagram_expiry(sequence, DatagramExpiryStage::Generated);
                }
                self.stats.expired += 1;
                pressure!(self, expiry_generated);
                continue;
            }
            if packet.at > now {
                pressure!(self, future_send_stops);
                break;
            }
            if self.write_permit == WritePermit::Denied {
                break;
            }
            if self.write_permit == WritePermit::One {
                self.write_permit = WritePermit::Denied;
            }
            let peer = self.peer.ok_or(Error::InvalidConfiguration)?;
            pressure!(self, udp_attempts);
            match send(
                self.socket.as_ref().ok_or(Error::InvalidConfiguration)?,
                &packet.bytes[..packet.len],
                peer,
            ) {
                Ok(len) if len == packet.len => {
                    self.needs_writable = false;
                    let completed = clock();
                    self.stats
                        .pressure
                        .generated_write_age
                        .interval(packet.generated_at, completed);
                    self.write_blocked.close(completed);
                    pressure!(self, udp_success);
                    self.stats.sent_udp_packets += 1;
                    self.stats.datagrams_udp_sent += u64::from(packet.expires.is_some());
                    self.generated.pop_front();
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    self.needs_writable = true;
                    self.write_permit = WritePermit::Denied;
                    pressure!(self, udp_would_block);
                    if packet.at <= now {
                        pressure!(self, udp_would_block_due);
                    }
                    self.write_blocked.start(clock());
                    break;
                }
                Err(e) => {
                    pressure!(self, udp_errors);
                    return Err(e.into());
                }
                Ok(_) => {
                    pressure!(self, udp_short);
                    return Err(Error::Transport);
                }
            }
        }
        if self.generated.is_empty() {
            self.needs_writable = false;
            self.write_blocked.close(clock());
        }
        Ok(())
    }
    fn read_application(&mut self, datagram_budget: &mut usize, stream_budget: &mut usize) {
        let Some(connection) = self.connection.as_mut() else {
            return;
        };
        if connection.readable().any(|id| id != 0) {
            self.retire(Retirement::Protocol);
            return;
        }
        while *datagram_budget > 0 {
            let Some(len) = connection.dgram_recv_front_len() else {
                break;
            };
            // Peek length without popping. Pressure retains ownership inside
            // the existing32-slot quiche queue until the caller makes room.
            if self.stats.application_ready
                && (self.received.len() >= RECEIVE_RECORDS
                    || self.receive_bytes + len + 4 > RECEIVE_BYTES)
            {
                if self.received.len() >= RECEIVE_RECORDS {
                    pressure!(self, wrapper_record_stops);
                }
                if self.receive_bytes + len + 4 > RECEIVE_BYTES {
                    pressure!(self, wrapper_byte_stops);
                }
                self.retained.start(Instant::now());
                break;
            }
            *datagram_budget -= 1;
            let Some(extracted) = self.stats.datagrams_extracted.checked_add(1) else {
                self.observation_failed();
                return;
            };
            let mut bytes = [0; UDP_SIZE];
            match connection.dgram_recv(&mut bytes) {
                Ok(len) => {
                    self.stats.datagrams_extracted = extracted;
                    if !self.stats.application_ready {
                        self.stats.rejected += 1;
                        self.stats.datagrams_rejected += 1;
                        continue;
                    }
                    match wire::decode(&bytes[..len], &self.session, Lane::Datagram) {
                        Ok(message) => {
                            self.stats.datagrams_received += 1;
                            self.receive_bytes += len + 4;
                            self.received.push_back(message);
                            self.stats.delivered += 1;
                        }
                        Err(_) => {
                            self.stats.datagrams_rejected += 1;
                            self.retire(Retirement::Protocol);
                            return;
                        }
                    }
                }
                Err(_) => {
                    self.observation_failed();
                    return;
                }
            }
        }
        if connection.dgram_recv_queue_len() == 0 {
            self.retained.close(Instant::now());
        } else if *datagram_budget == 0 {
            pressure!(self, dg_budget_stops);
            self.retained.start(Instant::now());
        }
        while *stream_budget > 0 {
            if self.received.len() >= RECEIVE_RECORDS
                || self.receive_bytes + self.stream_needed.max(wire::MAX_RECORD + 4) > RECEIVE_BYTES
            {
                if self.received.len() >= RECEIVE_RECORDS {
                    pressure!(self, wrapper_record_stops);
                }
                if self.receive_bytes + self.stream_needed.max(wire::MAX_RECORD + 4) > RECEIVE_BYTES
                {
                    pressure!(self, wrapper_byte_stops);
                }
                break;
            }
            *stream_budget -= 1;
            match connection.stream_recv(
                0,
                &mut self.stream_record[self.stream_used..self.stream_needed],
            ) {
                Ok((len, fin)) => {
                    self.stream_used += len;
                    if fin {
                        self.retire(Retirement::Closed);
                        return;
                    }
                    if self.stream_used < self.stream_needed {
                        break;
                    }
                    if self.stream_needed == 4 {
                        let length = u32::from_be_bytes(self.stream_record[..4].try_into().unwrap())
                            as usize;
                        if if self.stats.application_ready {
                            !(wire::HEADER..=wire::MAX_RECORD).contains(&length)
                        } else {
                            length != 36
                        } {
                            self.retire(Retirement::Protocol);
                            return;
                        }
                        self.stream_needed = 4 + length;
                    } else {
                        if !self.stats.application_ready {
                            let magic = if self.is_server { b"GQH1" } else { b"GQA1" };
                            if &self.stream_record[4..8] != magic
                                || self.stream_record[8..40] != self.session
                            {
                                self.retire(Retirement::Protocol);
                                return;
                            }
                            if self.is_server {
                                self.reliable
                                    .push_front(Buffer::new(preface(b"GQA1", &self.session), None));
                            }
                            self.stats.application_ready = true;
                            self.stats.reached_ready = true;
                            self.stream_used = 0;
                            self.stream_needed = 4;
                            continue;
                        }
                        match wire::decode_reliable(
                            &self.stream_record[..self.stream_needed],
                            &self.session,
                        ) {
                            Ok(message) => {
                                self.receive_bytes += self.stream_needed;
                                self.received.push_back(message);
                                self.stats.delivered += 1;
                            }
                            Err(_) => {
                                self.retire(Retirement::Protocol);
                                return;
                            }
                        }
                        self.stream_used = 0;
                        self.stream_needed = 4;
                    }
                }
                Err(quiche::Error::Done | quiche::Error::InvalidStreamState(_)) => break,
                Err(_) => {
                    self.retire(Retirement::Protocol);
                    return;
                }
            }
        }
    }
    pub fn receive(&mut self) -> Option<Received> {
        let message = self.received.pop_front()?;
        self.receive_bytes -= wire::HEADER + 4 + message.payload.len();
        Some(message)
    }
    pub fn stats(&self) -> Stats {
        self.stats_at(self.observation_now())
    }
    fn observation_now(&self) -> Instant {
        #[cfg(test)]
        if let Some(now) = self.observation_clock {
            return now;
        }
        Instant::now()
    }
    fn stats_at(&self, now: Instant) -> Stats {
        let mut pressure = self.stats.pressure;
        pressure.write_blocked = self.write_blocked.snapshot(now);
        pressure.retained = self.retained.snapshot(now);
        pressure.valid &= pressure.generated_write_age.valid
            && pressure.write_blocked.duration.valid
            && pressure.retained.duration.valid;
        Stats {
            pressure,
            quiche_datagrams_pending_records: self
                .connection
                .as_ref()
                .map_or(0, |c| c.dgram_recv_queue_len()),
            quiche_datagrams_pending_bytes: self
                .connection
                .as_ref()
                .map_or(0, |c| c.dgram_recv_queue_byte_size()),
            tls_failure: tls::VerificationFailure::load(&self.tls_failure),
            reliable_backlog_bytes: self.reliable_charge.load(Ordering::Relaxed),
            datagram_queue_records: self.datagrams.len()
                + usize::from(self.quiche_datagram_deadline.is_some()),
            generated_packets: self.generated.len(),
            receive_queue_records: self.received.len(),
            receive_queue_bytes: self.receive_bytes,
            ..self.stats
        }
    }
    /// Fixed-size terminal snapshot, retained across retirement and cleanup.
    pub fn diagnostics(&self) -> Stats {
        self.terminal.unwrap_or_else(|| self.stats())
    }
    /// Actual owner outcome only: commit the one terminal path observation
    /// without closing transport or changing its pre-close fields/balances.
    /// Casual live readers use diagnostics(). Repeated capture/close cannot
    /// resample, even if a caller continues servicing the transport afterwards.
    pub fn capture_terminal_diagnostics(&mut self) -> Stats {
        if let Some(terminal) = self.terminal {
            return terminal;
        }
        let now = self.observation_now();
        self.capture_terminal_path(now);
        self.stats_at(now)
    }
    fn capture_terminal_path(&mut self, now: Instant) {
        if !self.stats.path.terminal {
            self.stats.path = self.path_at(now);
            self.stats.path.terminal = true;
            self.last_path_sample = Some(now);
        }
    }
    pub fn next_wakeup(&self) -> Duration {
        if self.stats.retired {
            return Duration::ZERO;
        }
        let now = self.service_now();
        let mut delay = Duration::from_millis(10);
        if let Some(next) = self.keepalive.next {
            delay = delay.min(next.saturating_duration_since(now));
        }
        if let Some(connection) = &self.connection {
            if let Some(timeout) = connection.timeout() {
                delay = delay.min(timeout);
            }
        }
        if let Some(packet) = self.generated.front() {
            if !self.needs_writable || packet.at > now {
                delay = delay.min(packet.at.saturating_duration_since(now));
            }
        }
        for packet in self.generated.iter().filter(|_| !self.preserve_committed) {
            if let Some(deadline) = packet.expires {
                delay = delay.min(deadline.saturating_duration_since(now));
            }
        }
        if !self.stats.application_ready {
            delay = delay.min((self.created + TIMEOUT).saturating_duration_since(now));
        }
        if self.reliable_charge.load(Ordering::Relaxed) > 0 {
            delay = delay.min((self.reliable_progress + TIMEOUT).saturating_duration_since(now));
        }
        for datagram in &self.datagrams {
            delay = delay.min(datagram.deadline.saturating_duration_since(now));
        }
        if let Some(deadline) = self.quiche_datagram_deadline {
            delay = delay.min(deadline.saturating_duration_since(now));
        }
        delay
    }
    fn service_now(&self) -> Instant {
        #[cfg(test)]
        if let Some(io) = &self.poll_io {
            return io.now.get();
        }
        Instant::now()
    }
    pub fn close(&mut self) {
        self.retire(Retirement::Closed);
    }
    fn retire(&mut self, reason: Retirement) {
        self.retire_at(reason, self.observation_now());
    }
    fn retire_at(&mut self, reason: Retirement, retired_at: Instant) {
        if self.stats.retired {
            return;
        }
        self.stats.retired = true;
        self.keepalive = Keepalive::default();
        self.prioritize_reliable = false;
        self.stats.retirement = Some(reason);
        if let Some(connection) = &self.connection {
            self.stats.quic_timed_out = connection.is_timed_out();
            self.stats.local_close_code = connection.local_error().map(|e| e.error_code);
            self.stats.peer_close_code = connection.peer_error().map(|e| e.error_code);
            // BoringSSL rejects an absent required certificate before invoking
            // custom verification. QUIC carries TLS alert116 as0x100+116.
            if tls::VerificationFailure::load(&self.tls_failure) == tls::VerificationFailure::None
                && connection
                    .local_error()
                    .is_some_and(|e| !e.is_app && e.error_code == 0x174)
            {
                self.tls_failure.store(
                    tls::VerificationFailure::MissingCertificate as u8,
                    Ordering::Relaxed,
                );
            }
        }
        self.capture_terminal_path(retired_at);
        self.terminal = Some(self.stats_at(retired_at));
        self.write_blocked.close(retired_at);
        self.retained.close(retired_at);
        self.stats.authenticated = false;
        self.stats.application_ready = false;
        self.stats.retirement = Some(reason);
        self.connection.take();
        self.config.take();
        self.socket.take();
        self.reliable.clear();
        self.datagrams.clear();
        self.quiche_datagram_deadline = None;
        self.quiche_datagram_sequence = None;
        self.datagram_expiries.clear();
        self.generated.clear();
        self.needs_writable = false;
        self.write_permit = WritePermit::Denied;
        self.received.clear();
        self.receive_bytes = 0;
        self.stream_used = 0;
        self.stream_record.fill(0);
    }
}

// Only the socket-result/clock boundary is injected; tests still run the real
// authenticated Endpoint::poll, both flushes, queues, quiche and receive path.
#[cfg(test)]
struct TestPollIo {
    now: std::cell::Cell<Instant>,
    send_error: std::cell::Cell<Option<i32>>,
    actions: std::cell::RefCell<VecDeque<(Option<i32>, Option<Instant>)>>,
    writes: std::cell::RefCell<Vec<Vec<u8>>>,
    readiness: std::cell::RefCell<VecDeque<Result<libc::c_short, i32>>>,
    queries: std::cell::Cell<usize>,
    generation_delays: std::cell::RefCell<VecDeque<Duration>>,
    committed_deadline: std::cell::Cell<Option<Instant>>,
    preserved_committed: std::cell::Cell<u64>,
}
#[cfg(test)]
impl TestPollIo {
    fn blocked(now: Instant) -> std::rc::Rc<Self> {
        std::rc::Rc::new(Self {
            now: std::cell::Cell::new(now),
            send_error: std::cell::Cell::new(Some(libc::EWOULDBLOCK)),
            actions: Default::default(),
            writes: Default::default(),
            readiness: Default::default(),
            queries: Default::default(),
            generation_delays: Default::default(),
            committed_deadline: Default::default(),
            preserved_committed: Default::default(),
        })
    }
}

fn writable_permit_with(
    socket: &UdpSocket,
    query: impl FnOnce(&mut libc::pollfd, libc::nfds_t, libc::c_int) -> std::io::Result<i32>,
) -> std::io::Result<WritePermit> {
    use std::os::fd::AsRawFd;
    let mut fd = libc::pollfd {
        fd: socket.as_raw_fd(),
        events: libc::POLLOUT,
        revents: 0,
    };
    let result = match query(&mut fd, 1, 0) {
        Ok(result) => result,
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::Interrupted | std::io::ErrorKind::WouldBlock
            ) =>
        {
            return Ok(WritePermit::Denied)
        }
        Err(error) => return Err(error),
    };
    if result == 0 {
        return Ok(WritePermit::Denied);
    }
    if result != 1 {
        return Err(std::io::ErrorKind::InvalidData.into());
    }
    if fd.revents & libc::POLLNVAL != 0 {
        return Err(std::io::Error::from_raw_os_error(libc::EBADF));
    }
    if fd.revents & (libc::POLLERR | libc::POLLHUP) != 0 {
        return Ok(WritePermit::One);
    }
    Ok(if fd.revents & libc::POLLOUT != 0 {
        WritePermit::Open
    } else {
        WritePermit::Denied
    })
}

fn preface(magic: &[u8; 4], session: &SessionId) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(40);
    bytes.extend_from_slice(&[0, 0, 0, 36]);
    bytes.extend_from_slice(magic);
    bytes.extend_from_slice(session);
    bytes
}

fn disable_fragmentation(socket: &UdpSocket, ipv4: bool) -> Result<(), Error> {
    use std::os::fd::AsRawFd;
    let (level, option, value): (_, _, libc::c_int) = if ipv4 {
        #[cfg(target_os = "macos")]
        {
            (libc::IPPROTO_IP, libc::IP_DONTFRAG, 1)
        }
        #[cfg(target_os = "android")]
        {
            (
                libc::IPPROTO_IP,
                libc::IP_MTU_DISCOVER,
                libc::IP_PMTUDISC_DO,
            )
        }
    } else {
        // IPV6_DONTFRAG is 62 in Darwin in6.h and the Android UAPI.
        (libc::IPPROTO_IPV6, 62, 1)
    };
    // SAFETY: live owned socket and a correctly sized integer option value.
    let result = unsafe {
        libc::setsockopt(
            socket.as_raw_fd(),
            level,
            option,
            (&value as *const libc::c_int).cast(),
            std::mem::size_of_val(&value) as libc::socklen_t,
        )
    };
    if result != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(())
}

fn set_traffic_class(socket: &UdpSocket, ipv4: bool, traffic_class: u8) -> Result<(), Error> {
    use std::os::fd::AsRawFd;
    let (level, option) = if ipv4 {
        (libc::IPPROTO_IP, libc::IP_TOS)
    } else {
        (libc::IPPROTO_IPV6, libc::IPV6_TCLASS)
    };
    let value = libc::c_int::from(traffic_class);
    // SAFETY: live owned socket and a correctly sized integer option value.
    let result = unsafe {
        libc::setsockopt(
            socket.as_raw_fd(),
            level,
            option,
            (&value as *const libc::c_int).cast(),
            std::mem::size_of_val(&value) as libc::socklen_t,
        )
    };
    if result != 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn keepalive_scheduler_readiness_exact_opportunity_no_replay_and_overflow() {
        let t = Instant::now();
        let mut k = Keepalive::default();
        assert!(!k.opportunity(t, false, false).unwrap());
        assert!(k.next.is_none());
        assert!(!k.opportunity(t, true, false).unwrap());
        assert_eq!(k.next, Some(t + KEEPALIVE_INTERVAL));
        assert!(!k
            .opportunity(
                t + KEEPALIVE_INTERVAL - Duration::from_nanos(1),
                true,
                false
            )
            .unwrap());
        assert!(k.opportunity(t + KEEPALIVE_INTERVAL, true, false).unwrap());
        assert!(!k.opportunity(t + KEEPALIVE_INTERVAL, true, false).unwrap());
        let late = t + KEEPALIVE_INTERVAL * 9;
        assert!(k.opportunity(late, true, false).unwrap());
        assert_eq!(k.next, Some(late + KEEPALIVE_INTERVAL));
        assert!(!k
            .opportunity(late + KEEPALIVE_INTERVAL, true, true)
            .unwrap());
        assert_eq!(k.next, Some(late + KEEPALIVE_INTERVAL * 2));
        assert!(k.opportunity(late, true, false).is_err());
        let mut limit = t;
        for bit in (0..64).rev() {
            if let Some(next) = limit.checked_add(Duration::from_secs(1u64 << bit)) {
                limit = next;
            }
        }
        assert!(Keepalive::default()
            .opportunity(limit, true, false)
            .is_err());
    }
    #[test]
    fn keepalive_real_poll_ready_wakeup_getters_close_and_backward_clock() {
        let (mut a, mut b) = ready_pair();
        let now = Instant::now();
        let io = TestPollIo::blocked(now);
        a.poll_io = Some(io.clone());
        a.keepalive.next = Some(now + Duration::from_micros(25));
        assert_eq!(a.next_wakeup(), Duration::from_micros(25));
        let requests = a.keepalive_requests;
        for _ in 0..10 {
            let _ = a.stats();
            let _ = a.diagnostics();
            let _ = a.next_wakeup();
        }
        assert_eq!(a.keepalive_requests, requests);
        io.now.set(now + Duration::from_micros(25));
        a.poll().unwrap();
        assert_eq!(a.keepalive_requests, requests + 1);
        assert_eq!(a.stats().admitted, 0);
        assert_eq!(a.stats().datagrams_admitted, 0);
        assert!(a.next_wakeup() > Duration::ZERO);
        io.now.set(now);
        a.poll().unwrap();
        assert_eq!(a.stats().retirement, Some(Retirement::Protocol));
        assert!(a.keepalive.next.is_none());
        a.close();
        a.poll().unwrap();
        assert_eq!(a.keepalive_requests, requests + 1);
        b.close();
        let (mut successor, mut peer) = ready_pair();
        assert_eq!(successor.keepalive_requests, 0);
        successor.close();
        peer.close();
        assert!(successor.keepalive.next.is_none());
    }
    #[test]
    fn keepalive_real_poll_retained_and_unwritable_opportunities_do_not_spin() {
        let (mut a, mut b, io) = blocked_poll_pair();
        a.keepalive.next = Some(io.now.get());
        let packets = a.generated.len();
        a.poll().unwrap();
        assert_eq!(a.keepalive_requests, 0);
        assert!(a.needs_writable);
        assert_eq!(a.generated.len(), packets);
        assert!(a.next_wakeup() > Duration::ZERO);
        a.keepalive.next = Some(io.now.get());
        a.poll().unwrap();
        assert_eq!(a.keepalive_requests, 0);
        assert_eq!(io.writes.borrow().len(), 1);
        assert!(a.next_wakeup() > Duration::ZERO);
        a.close();
        b.close();
        let (mut a, mut b, io) = blocked_poll_pair();
        a.generated.front_mut().unwrap().at = io.now.get() + Duration::from_millis(1);
        a.keepalive.next = Some(io.now.get());
        a.poll().unwrap();
        assert_eq!(a.keepalive_requests, 0);
        assert!(!a.needs_writable);
        assert_eq!(a.next_wakeup(), Duration::from_millis(1));
        a.close();
        b.close();
    }
    #[test]
    fn keepalive_real_poll_tls_only_never_arms_and_native_timeout_wins() {
        let (mut a, mut b) = ready_pair();
        // Isolate the session-preface gate with the real established connection.
        a.stats.application_ready = false;
        a.keepalive = Keepalive::default();
        a.poll().unwrap();
        assert!(a.keepalive.next.is_none());
        assert_eq!(a.keepalive_requests, 0);
        a.close();
        b.close();
        let (mut a, mut b) = ready_pair();
        let until = Instant::now() + Duration::from_secs(6);
        while Instant::now() < until {
            std::thread::sleep(Duration::from_millis(10));
        }
        a.poll().unwrap();
        assert_eq!(a.stats().retirement, Some(Retirement::PeerIdle));
        assert_eq!(a.keepalive_requests, 0);
        assert!(a.keepalive.next.is_none());
        b.close();
    }
    #[test]
    fn send_commit_drains_first_packet_before_later_generation_work() {
        let (mut sender, mut receiver) = ready_pair();
        let now = Instant::now();
        let first_deadline = now + Duration::from_millis(30);
        for sequence in 1..=3 {
            assert_eq!(
                sender.send(
                    Message {
                        lane: Lane::Datagram,
                        sequence,
                        payload: vec![sequence as u8; 800],
                    },
                    if sequence == 1 {
                        first_deadline
                    } else {
                        now + Duration::from_millis(500)
                    }
                ),
                Admission::Accepted
            );
        }
        let io = TestPollIo::blocked(now);
        io.send_error.set(None);
        io.generation_delays.borrow_mut().extend([
            Duration::ZERO,
            Duration::from_millis(60),
            Duration::ZERO,
        ]);
        sender.poll_io = Some(io.clone());
        let before = sender.stats();
        let quiche_before = sender.connection.as_ref().unwrap().stats().sent;
        sender.poll().unwrap();
        let after = sender.stats();
        let quiche_committed = sender.connection.as_ref().unwrap().stats().sent - quiche_before;
        let until = Instant::now() + Duration::from_millis(100);
        let mut got = Vec::new();
        while Instant::now() < until && got.len() < 3 {
            receiver.poll().unwrap();
            while let Some(record) = receiver.receive() {
                assert_eq!(record.payload, vec![record.sequence as u8; 800]);
                got.push(record.sequence);
            }
            std::thread::sleep(Duration::from_micros(100));
        }
        let generated = after.datagrams_generated - before.datagrams_generated;
        let udp = after.datagrams_udp_sent - before.datagrams_udp_sent;
        let expired = after.pressure.expiry_generated - before.pressure.expiry_generated;
        println!("send-commit actual quicheCommitted={quiche_committed} generated={generated} udp={udp} generatedExpiry={expired} queuedExpiry={} pacing={} wouldblock={} received={got:?}",
            after.pressure.expiry_queued - before.pressure.expiry_queued,
            after.pressure.future_send_stops - before.pressure.future_send_stops,
            after.pressure.udp_would_block - before.pressure.udp_would_block);
        sender.close();
        receiver.close();
        assert_eq!(
            generated, 3,
            "all three original messages genuinely reached quiche commitment"
        );
        assert!(quiche_committed as u64 >= generated);
        assert_eq!(after.pressure.expiry_queued, before.pressure.expiry_queued);
        assert_eq!(
            after.pressure.future_send_stops,
            before.pressure.future_send_stops
        );
        assert_eq!(
            after.pressure.udp_would_block,
            before.pressure.udp_would_block
        );
        assert_eq!((udp, expired, got), (3, 0, vec![1, 2, 3]),
            "first valid committed packet must drain before unrelated later generation consumes its residual deadline");
    }
    #[test]
    fn bbr2_pacing_limit_uses_bytes_per_second_at_adapter_boundary() {
        exercise_pacing_byte_rate(2_000_000, 1024, Duration::from_millis(350));
    }
    #[test]
    fn bbr2_pacing_cap_keeps_datagrams_live_below_one_packet_bdp() {
        // At localhost RTT, 1.25*125kB/s*RTT is below one DATAGRAM. The cap
        // must not remove BBR2's existing congestion-window lower bound.
        exercise_pacing_byte_rate(125_000, 32, Duration::from_millis(100));
    }
    fn exercise_pacing_byte_rate(bytes_per_second: u64, packets: u64, minimum: Duration) {
        // A real pinned QUIC pair and real quiche pacing, not injected packet
        // timestamps or a simulated ACK. Exercise the exact production cap:
        // 2 MB/s (16 Mbps), not accidentally requesting 2,000,000 Mbps.
        let (mut sender, mut receiver) =
            ready_pair_with_pacing_cap(32, CongestionControl::Bbr2, Some(bytes_per_second));
        if bytes_per_second == 125_000 {
            let path = sender
                .connection
                .as_ref()
                .unwrap()
                .path_stats()
                .find(|p| p.active)
                .unwrap();
            let unclamped_window = 1.25 * bytes_per_second as f64 * path.rtt.as_secs_f64();
            assert!(
                unclamped_window < 1_000.0,
                "fixture did not reach sub-packet BDP: rtt={:?}, window={unclamped_window}",
                path.rtt
            );
        }
        sender.preserve_committed_datagrams();
        let start = Instant::now();
        let mut sequence = 1;
        let mut received = Vec::new();
        let mut high = 0;
        let until = start + Duration::from_secs(3);
        while received.len() < packets as usize && Instant::now() < until {
            while sequence <= packets {
                if sender.send(
                    Message {
                        lane: Lane::Datagram,
                        sequence,
                        payload: vec![sequence as u8; 1_000],
                    },
                    start + Duration::from_secs(3),
                ) != Admission::Accepted
                {
                    break;
                }
                sequence += 1;
            }
            sender.poll().unwrap();
            high = high.max(sender.generated.len());
            receiver.poll().unwrap();
            while let Some(message) = receiver.receive() {
                assert_eq!(message.payload, vec![message.sequence as u8; 1_000]);
                received.push(message.sequence);
            }
            assert!(!sender.stats().retired && !receiver.stats().retired);
            std::thread::sleep(Duration::from_millis(1));
        }
        let elapsed = start.elapsed();
        let stats = sender.stats();
        println!("paced-rate cap_Bps={bytes_per_second} elapsed_ms={} generated_high={high} received={} rtt_ns={} write_age_max_ns={} pacing_stops={} expired={}",
            elapsed.as_millis(), received.len(), stats.path.rtt_ns, stats.pressure.generated_write_age.max_ns,
            stats.pressure.future_send_stops, stats.expired);
        sender.close();
        receiver.close();
        assert_eq!(received, (1..=packets).collect::<Vec<_>>());
        assert!(
            stats.pressure.future_send_stops > 0,
            "fixture must exercise real pacing"
        );
        // Allow the real initial unpaced burst and considerable timing margin.
        // 1,024 kB must not be emitted in a few milliseconds at 2 MB/s.
        assert!(
            elapsed >= minimum,
            "byte/s cap must reach the actual packet pacer in the correct units"
        );
    }
    fn blocked_poll_pair() -> (Endpoint, Endpoint, std::rc::Rc<TestPollIo>) {
        let (mut a, b) = ready_pair();
        let now = Instant::now();
        assert_eq!(
            a.send(
                Message {
                    lane: Lane::Datagram,
                    sequence: 901,
                    payload: vec![0x19; 800]
                },
                now + Duration::from_secs(2)
            ),
            Admission::Accepted
        );
        a.generate_packets().unwrap();
        assert!(a.generated.iter().any(|p| p.expires.is_some()));
        let io = TestPollIo::blocked(now + Duration::from_millis(1));
        a.poll_io = Some(io.clone());
        (a, b, io)
    }

    #[test]
    fn committed_datagram_expiry_characterizes_real_bbr2_recovery() {
        // A controlled descriptor outage, not a simulated QUIC peer or ACK.
        // Both arms run the same authenticated transport and source workload.
        // Only the control arm keeps already committed ciphertext alive; this
        // is test-only and makes no production deadline/policy change.
        for preserve_committed in [false, true] {
            let (mut sender, mut receiver) = ready_pair_with_options(32, CongestionControl::Bbr2);
            let start = Instant::now();
            let io = TestPollIo::blocked(start);
            sender.poll_io = Some(io.clone());
            let mut sequence = 1;
            let mut max_generated = 0;
            let before = sender.connection.as_ref().unwrap().stats();
            while start.elapsed() < Duration::from_millis(250) {
                let now = Instant::now();
                io.now.set(now);
                for _ in 0..4 {
                    if sender.send(
                        Message {
                            lane: Lane::Datagram,
                            sequence,
                            payload: vec![0x53; 1_000],
                        },
                        now + Duration::from_millis(60),
                    ) == Admission::Accepted
                    {
                        sequence += 1;
                    }
                }
                sender.poll().unwrap();
                max_generated = max_generated.max(sender.generated.len());
                if preserve_committed {
                    for packet in &mut sender.generated {
                        // Keep original ciphertext and SendInfo.at; no fake
                        // transmission, packet copy, ACK or congestion credit.
                        if packet.expires.is_some() {
                            packet.expires = Some(start + Duration::from_secs(3));
                        }
                    }
                }
                receiver.poll().unwrap();
                assert!(receiver.receive().is_none());
                assert!(!sender.stats().retired && !receiver.stats().retired);
                std::thread::sleep(Duration::from_millis(1));
            }
            let after_outage = sender.connection.as_ref().unwrap().stats();
            let expiry = sender.stats().pressure.expiry_generated;
            assert!(after_outage.sent > before.sent);
            assert_eq!(sender.stats().datagrams_udp_sent, 0);
            assert!(max_generated > 0 && max_generated <= GENERATED_PACKETS);
            if preserve_committed {
                assert_eq!(expiry, 0);
            } else {
                assert!(expiry > 0, "real committed ciphertext must expire");
            }

            // Restore the actual UDP descriptor, preserving the same connection.
            sender.poll_io = None;
            let restored = Instant::now();
            let recovery_sequence = sequence;
            assert_eq!(
                sender.send(
                    Message {
                        lane: Lane::Reliable,
                        sequence: recovery_sequence,
                        payload: b"recovery-marker".to_vec()
                    },
                    restored + Duration::from_secs(2)
                ),
                Admission::Accepted
            );
            let mut reliable_at = None;
            let mut fresh_datagram_at = None;
            let mut old_datagrams = 0;
            let mut fresh_datagrams = 0;
            while restored.elapsed() < Duration::from_secs(2) {
                let now = Instant::now();
                if sender.send(
                    Message {
                        lane: Lane::Datagram,
                        sequence,
                        payload: vec![0x54; 1_000],
                    },
                    now + Duration::from_millis(60),
                ) == Admission::Accepted
                {
                    sequence += 1;
                }
                sender.poll().unwrap();
                receiver.poll().unwrap();
                while let Some(record) = receiver.receive() {
                    match record.lane {
                        Lane::Reliable => {
                            assert_eq!(record.payload, b"recovery-marker");
                            assert_eq!(record.sequence, recovery_sequence);
                            reliable_at.get_or_insert(restored.elapsed());
                        }
                        Lane::Datagram => {
                            if record.sequence >= recovery_sequence {
                                assert_eq!(record.payload, vec![0x54; 1_000]);
                                fresh_datagrams += 1;
                                fresh_datagram_at.get_or_insert(restored.elapsed());
                            } else {
                                assert_eq!(record.payload, vec![0x53; 1_000]);
                                old_datagrams += 1;
                            }
                        }
                    }
                }
                assert!(!sender.stats().retired && !receiver.stats().retired);
                if reliable_at.is_some() && fresh_datagram_at.is_some() && fresh_datagrams >= 100 {
                    break;
                }
                std::thread::sleep(Duration::from_millis(1));
            }
            let final_stats = sender.connection.as_ref().unwrap().stats();
            let path = sender
                .connection
                .as_ref()
                .unwrap()
                .path_stats()
                .next()
                .unwrap();
            eprintln!("committed-expiry preserve={preserve_committed} expired={expiry} admittedDuringOutage={} committedDuringOutage={} lostDuringOutage={} maxGenerated={max_generated} reliableUs={:?} freshDatagramUs={:?} freshDelivered={fresh_datagrams} oldDelivered={old_datagrams} lostFinal={} pto={} cwnd={} elapsedUs={}",
                recovery_sequence - 1,
                after_outage.sent - before.sent, after_outage.lost - before.lost,
                reliable_at.map(|d| d.as_micros()), fresh_datagram_at.map(|d| d.as_micros()),
                final_stats.lost - before.lost, path.total_pto_count, path.cwnd,
                restored.elapsed().as_micros());
            sender.close();
            receiver.close();
            assert!(reliable_at.is_some() && fresh_datagram_at.is_some());
            assert!(
                fresh_datagrams >= 100,
                "sending must resume beyond a single probe"
            );
        }
    }
    #[test]
    fn paced_path_loss_without_descriptor_stall_characterizes_committed_expiry() {
        // Authenticated endpoints are serviced continuously. Only a real UDP
        // relay delays/drops packets: no forged ACK, pacing, RTT or WouldBlock.
        for preserve_committed in [false, true] {
            let a = Identity::generate().unwrap();
            let b = Identity::generate().unwrap();
            let ap = a.fingerprint();
            let bp = b.fingerprint();
            let mut sender = Endpoint::listen_with_congestion_control(
                "127.0.0.1:0".parse().unwrap(),
                "127.0.0.1".parse().unwrap(),
                [1; 32],
                b,
                ap,
                CongestionControl::Bbr2,
            )
            .unwrap();
            let relay = UdpSocket::bind("127.0.0.1:0").unwrap();
            relay.set_nonblocking(true).unwrap();
            let mut receiver = Endpoint::connect_with_congestion_control(
                "127.0.0.1:0".parse().unwrap(),
                relay.local_addr().unwrap(),
                [1; 32],
                a,
                bp,
                CongestionControl::Bbr2,
            )
            .unwrap();
            let from_sender = sender.local_addr().unwrap();
            let from_receiver = receiver.local_addr().unwrap();
            let mut pending: VecDeque<(Instant, SocketAddr, Vec<u8>)> = VecDeque::new();
            let mut network_dropped = 0_u64;
            let mut relay_step = |outage: bool| {
                let mut bytes = [0_u8; 2_048];
                for _ in 0..256 {
                    match relay.recv_from(&mut bytes) {
                        Ok((count, from)) => {
                            assert!(from == from_sender || from == from_receiver);
                            if outage {
                                network_dropped += 1;
                                continue;
                            }
                            let destination = if from == from_sender {
                                from_receiver
                            } else {
                                from_sender
                            };
                            pending.push_back((
                                Instant::now() + Duration::from_millis(40),
                                destination,
                                bytes[..count].to_vec(),
                            ));
                            assert!(
                                pending.len() < 4_096,
                                "relay capacity must not introduce hidden loss"
                            );
                        }
                        Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                        Err(e) => panic!("relay receive: {e}"),
                    }
                }
                while pending.front().is_some_and(|p| p.0 <= Instant::now()) {
                    let (_, destination, bytes) = pending.pop_front().unwrap();
                    if outage {
                        network_dropped += 1;
                        continue;
                    }
                    assert_eq!(relay.send_to(&bytes, destination).unwrap(), bytes.len());
                }
            };
            let handshake_limit = Instant::now() + Duration::from_secs(3);
            while !(sender.stats().application_ready && receiver.stats().application_ready) {
                assert!(Instant::now() < handshake_limit);
                sender.poll().unwrap();
                receiver.poll().unwrap();
                relay_step(false);
                std::thread::sleep(Duration::from_micros(500));
            }
            let start = Instant::now();
            let end = start + Duration::from_secs(12);
            if preserve_committed {
                // Isolate only the media sender's committed ownership. The
                // feedback endpoint keeps exactly the same policy in both arms.
                sender.preserve_committed_datagrams();
            }
            assert!(sender.poll_io.is_none() && receiver.poll_io.is_none());
            let mut next_frame = start;
            let mut next_feedback = start;
            let mut sequence = 1_u64;
            let mut feedback = 1_u64;
            let mut delivered = 0_u64;
            let mut fresh = 0_u64;
            let mut fresh_cutoff = None;
            let mut generated_expiry = 0_u64;
            let mut cancelled_committed = 0_usize;
            let mut last_delivery = start;
            let mut max_gap = Duration::ZERO;
            while Instant::now() < end && !sender.stats().retired && !receiver.stats().retired {
                let now = Instant::now();
                let elapsed = now.duration_since(start);
                let outage = (Duration::from_secs(3)..Duration::from_millis(3250))
                    .contains(&elapsed)
                    || (Duration::from_secs(6)..Duration::from_millis(6250)).contains(&elapsed);
                if elapsed >= Duration::from_millis(6250) && fresh_cutoff.is_none() {
                    fresh_cutoff = Some(sequence);
                }
                if now >= next_frame {
                    next_frame = now + Duration::from_millis(16);
                    for _ in 0..12 {
                        let result = sender.send(
                            Message {
                                lane: Lane::Datagram,
                                sequence,
                                payload: vec![0x6b; 1_000],
                            },
                            now + Duration::from_millis(60),
                        );
                        if result == Admission::Accepted {
                            sequence += 1;
                        }
                    }
                }
                if now >= next_feedback {
                    next_feedback = now + Duration::from_millis(100);
                    if receiver.send(
                        Message {
                            lane: Lane::Datagram,
                            sequence: feedback,
                            payload: vec![0x42; 40],
                        },
                        now + Duration::from_millis(60),
                    ) == Admission::Accepted
                    {
                        feedback += 1;
                    }
                }
                sender.poll().unwrap();
                receiver.poll().unwrap();
                let mut lost_source = false;
                while let Some(expiry) = sender.take_datagram_expiry() {
                    generated_expiry += u64::from(expiry.stage == DatagramExpiryStage::Generated);
                    lost_source = true;
                }
                if lost_source {
                    let before = sender.generated.len();
                    sender.discard_datagrams(|_| true);
                    cancelled_committed += before - sender.generated.len();
                }
                while receiver.take_datagram_expiry().is_some() {}
                while let Some(message) = receiver.receive() {
                    assert_eq!(message.payload, vec![0x6b; 1_000]);
                    let delivered_at = Instant::now();
                    max_gap = max_gap.max(delivered_at.duration_since(last_delivery));
                    last_delivery = delivered_at;
                    delivered += 1;
                    fresh +=
                        u64::from(fresh_cutoff.is_some_and(|cutoff| message.sequence >= cutoff));
                }
                while let Some(message) = sender.receive() {
                    assert_eq!(message.payload, vec![0x42; 40]);
                }
                relay_step(outage);
                std::thread::sleep(Duration::from_micros(500));
            }
            max_gap = max_gap.max(Instant::now().duration_since(last_delivery));
            let stats = sender.stats();
            let peer_stats = receiver.stats();
            drop(relay_step);
            eprintln!("paced-loss preserve={preserve_committed} admitted={} delivered={delivered} fresh={fresh} generatedExpiry={generated_expiry} cancelledCommitted={cancelled_committed} receiverGeneratedExpiry={} networkDropped={network_dropped} maxGapUs={} senderRetired={:?} receiverRetired={:?} generated={} udpSent={} lost={} pto={} cwnd={}", sequence-1, peer_stats.pressure.expiry_generated, max_gap.as_micros(), stats.retirement, peer_stats.retirement, stats.datagrams_generated, stats.datagrams_udp_sent, stats.path.lost_packets, stats.path.pto_count, stats.path.cwnd_bytes);
            sender.close();
            receiver.close();
            assert_eq!(
                stats.pressure.udp_would_block + peer_stats.pressure.udp_would_block,
                0
            );
            assert!(network_dropped > 0 && sequence > 1_000 && delivered > 0);
            if preserve_committed {
                assert_eq!(generated_expiry + cancelled_committed as u64, 0);
            } else {
                assert!(
                    generated_expiry + cancelled_committed as u64 > 0,
                    "baseline must actually exercise committed deletion"
                );
            }
            assert!(
                fresh >= 100 && !stats.retired && !peer_stats.retired,
                "both peers must survive with sustained fresh post-outage progress"
            );
            // Relative timings remain characterization, not a latency gate.
        }
    }

    #[test]
    fn committed_media_full_queue_preserves_ciphertext_and_releases_recovery() {
        let (mut sender, mut receiver) = ready_pair_with_options(32, CongestionControl::Bbr2);
        sender.preserve_committed_datagrams();
        // Build actual congestion credit with acknowledged application traffic.
        // A busy host can legitimately fill the admission queue during this
        // setup. Retry the same message with its original deadline while real
        // polling/ACKs drain it; never assume one admission every 2 ms.
        fn drain_warmup(receiver: &mut Endpoint) -> usize {
            let mut count = 0;
            while let Some(message) = receiver.receive() {
                assert_eq!(message.lane, Lane::Datagram);
                assert!((1..=160).contains(&message.sequence));
                assert_eq!(message.payload, vec![1; 1_000]);
                count += 1;
            }
            count
        }
        let mut warmup_received = 0;
        let warmup_deadline = Instant::now() + Duration::from_secs(10);
        for sequence in 1..=160 {
            let deadline = Instant::now() + Duration::from_secs(2);
            loop {
                assert!(
                    Instant::now() < deadline && Instant::now() < warmup_deadline,
                    "warmup failed to admit sequence {sequence} before its original deadline"
                );
                match sender.send(
                    Message {
                        lane: Lane::Datagram,
                        sequence,
                        payload: vec![1; 1_000],
                    },
                    deadline,
                ) {
                    Admission::Accepted => break,
                    Admission::Backpressured => {
                        sender.poll().unwrap();
                        receiver.poll().unwrap();
                        warmup_received += drain_warmup(&mut receiver);
                        std::thread::sleep(Duration::from_micros(500));
                    }
                    admission => panic!("unexpected warmup admission: {admission:?}"),
                }
            }
            sender.poll().unwrap();
            receiver.poll().unwrap();
            warmup_received += drain_warmup(&mut receiver);
            std::thread::sleep(Duration::from_millis(2));
        }
        // Finish the actual warmup drain rather than assuming twenty timer
        // ticks settle it under concurrent compiler load. Keep the same finite
        // setup deadline and require every warmup record to reach the receiver.
        loop {
            assert!(Instant::now() < warmup_deadline, "warmup did not drain");
            sender.poll().unwrap();
            receiver.poll().unwrap();
            warmup_received += drain_warmup(&mut receiver);
            if warmup_received == 160
                && sender.datagrams.is_empty()
                && sender.generated.is_empty()
                && sender.connection.as_ref().unwrap().dgram_send_queue_len() == 0
            {
                break;
            }
            std::thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(warmup_received, 160);
        assert!(sender.generated.is_empty());
        let deadline = Instant::now() + Duration::from_millis(60);
        for sequence in 200..232 {
            assert_eq!(
                sender.send(
                    Message {
                        lane: Lane::Datagram,
                        sequence,
                        // Small real datagrams fill the 32-slot packet pool
                        // without requiring an artificial congestion window.
                        payload: vec![2; 100]
                    },
                    deadline
                ),
                Admission::Accepted
            );
            sender.generate_packets().unwrap();
        }
        assert_eq!(sender.generated.len(), GENERATED_PACKETS);
        let original: Vec<_> = sender
            .generated
            .iter()
            .map(|p| p.bytes[..p.len].to_vec())
            .collect();
        std::thread::sleep(
            deadline.saturating_duration_since(Instant::now()) + Duration::from_millis(1),
        );
        sender.discard_datagrams(|_| true);
        assert_eq!(
            sender
                .generated
                .iter()
                .map(|p| p.bytes[..p.len].to_vec())
                .collect::<Vec<_>>(),
            original
        );
        assert_eq!(
            sender.send(
                Message {
                    lane: Lane::Reliable,
                    sequence: 900,
                    payload: b"recovery".to_vec()
                },
                Instant::now() + Duration::from_secs(2)
            ),
            Admission::Accepted
        );
        assert_eq!(
            sender.send(
                Message {
                    lane: Lane::Datagram,
                    sequence: 901,
                    payload: b"fresh audio".to_vec()
                },
                Instant::now() + Duration::from_secs(2)
            ),
            Admission::Accepted
        );
        let start = Instant::now();
        let mut recovered = false;
        let mut audio = false;
        while start.elapsed() < Duration::from_secs(2) && !(recovered && audio) {
            sender.poll().unwrap();
            receiver.poll().unwrap();
            while let Some(message) = receiver.receive() {
                recovered |= message.lane == Lane::Reliable && message.sequence == 900;
                audio |= message.lane == Lane::Datagram && message.sequence == 901;
            }
            while sender.receive().is_some() {}
            std::thread::sleep(Duration::from_micros(500));
        }
        eprintln!(
            "committed-full-queue recovery={recovered} audio={audio} drainUs={} generatedExpiry={}",
            start.elapsed().as_micros(),
            sender.stats().pressure.expiry_generated
        );
        assert!(recovered && audio && !sender.stats().retired && !receiver.stats().retired);
        assert_eq!(sender.stats().pressure.expiry_generated, 0);
        sender.close();
        receiver.close();
    }

    #[test]
    fn committed_datagram_loss_after_warmup_characterizes_sustained_recovery() {
        // Real authenticated BBR2 and real UDP writes, with two bounded
        // descriptor stalls after source warmup. This is an ownership stress
        // stimulus, NOT evidence that hardware experienced WouldBlock.
        // No fabricated ACKs, pacing timestamps or congestion accounting.
        for preserve_committed in [false, true] {
            let (mut sender, mut receiver) = ready_pair_with_options(32, CongestionControl::Bbr2);
            let start = Instant::now();
            let end = start + Duration::from_secs(8);
            let io = TestPollIo::blocked(start);
            io.send_error.set(None);
            if preserve_committed {
                // Apply at genuine commitment, before the first internal flush.
                // Source/plaintext deadlines remain 60 ms in both arms.
                io.committed_deadline.set(Some(end));
            }
            sender.poll_io = Some(io.clone());
            let mut next_frame = start;
            let mut next_receive = start;
            let mut sequence = 1;
            let mut admitted = 0;
            let mut delivered = 0;
            let mut after_second_outage = 0;
            let mut fresh_cutoff = None;
            let mut last_delivery = None;
            let mut greatest_delivery_gap = Duration::ZERO;
            let mut original_generated_expiries = 0;
            let mut cancellations = 0;
            let mut cancelled_committed = 0;
            while Instant::now() < end {
                let now = Instant::now();
                let elapsed = now.duration_since(start);
                let outage = (Duration::from_secs(2)..Duration::from_millis(2250))
                    .contains(&elapsed)
                    || (Duration::from_secs(4)..Duration::from_millis(4250)).contains(&elapsed);
                io.now.set(now);
                io.send_error.set(outage.then_some(libc::EWOULDBLOCK));
                io.readiness.borrow_mut().clear();
                io.readiness
                    .borrow_mut()
                    .push_back(Ok(if outage { 0 } else { libc::POLLOUT }));
                if elapsed >= Duration::from_millis(4250) && fresh_cutoff.is_none() {
                    fresh_cutoff = Some(sequence);
                }
                // Four 1000-byte fragments per 16 ms, about 2 Mbit/s. Missed
                // source ticks are not replayed as an artificial catch-up burst.
                if now >= next_frame {
                    next_frame = now + Duration::from_millis(16);
                    for _ in 0..4 {
                        if sender.send(
                            Message {
                                lane: Lane::Datagram,
                                sequence,
                                payload: vec![0x6b; 1_000],
                            },
                            now + Duration::from_millis(60),
                        ) == Admission::Accepted
                        {
                            sequence += 1;
                            admitted += 1;
                        }
                    }
                }
                sender.poll().unwrap();
                io.writes.borrow_mut().clear();
                let mut expired = false;
                while let Some(expiry) = sender.take_datagram_expiry() {
                    original_generated_expiries +=
                        u64::from(expiry.stage == DatagramExpiryStage::Generated);
                    expired = true;
                }
                if expired {
                    // Same source-recovery boundary as the backend: a missing
                    // fragment supersedes dependent video already in flight to
                    // the transport. No audio/reliable payload in this fixture.
                    cancellations += 1;
                    let committed =
                        preserve_committed.then(|| std::mem::take(&mut sender.generated));
                    let before = sender
                        .generated
                        .iter()
                        .filter(|p| p.datagram_sequence.is_some())
                        .count();
                    sender.discard_datagrams(|_| true);
                    cancelled_committed += before
                        - sender
                            .generated
                            .iter()
                            .filter(|p| p.datagram_sequence.is_some())
                            .count();
                    if let Some(committed) = committed {
                        sender.generated = committed;
                    }
                }
                if now >= next_receive {
                    next_receive = now + Duration::from_millis(20);
                    receiver.poll().unwrap();
                    while let Some(message) = receiver.receive() {
                        assert_eq!(message.lane, Lane::Datagram);
                        assert_eq!(message.payload, vec![0x6b; 1_000]);
                        assert!(message.sequence < sequence);
                        delivered += 1;
                        if fresh_cutoff.is_some_and(|cutoff| message.sequence >= cutoff) {
                            after_second_outage += 1;
                        }
                        if let Some(previous) = last_delivery {
                            greatest_delivery_gap =
                                greatest_delivery_gap.max(now.duration_since(previous));
                        }
                        last_delivery = Some(now);
                    }
                }
                while sender.receive().is_some() {}
                assert!(
                    !sender.stats().retired && !receiver.stats().retired,
                    "the same connections must remain alive throughout the observation"
                );
                std::thread::sleep(Duration::from_micros(500));
            }
            let stats = sender.stats();
            if let Some(previous) = last_delivery {
                greatest_delivery_gap =
                    greatest_delivery_gap.max(Instant::now().duration_since(previous));
            }
            let path = sender
                .connection
                .as_ref()
                .and_then(|c| c.path_stats().next());
            eprintln!("sustained-expiry preserve={preserve_committed} admitted={admitted} delivered={delivered} freshAfterSecondOutage={after_second_outage} generatedExpiry={original_generated_expiries} cancelledCommitted={cancelled_committed} preservedCommitted={} cancellations={cancellations} generated={} udpSent={} maxDeliveryGapUs={} senderRetired={:?} receiverRetired={:?} path={:?}",
                io.preserved_committed.get(),
                stats.datagrams_generated, stats.datagrams_udp_sent, greatest_delivery_gap.as_micros(),
                stats.retirement, receiver.stats().retirement,
                path.as_ref().map(|p| (p.cwnd, p.lost, p.total_pto_count)));
            sender.close();
            receiver.close();
            assert!(admitted >= 1_000 && delivered > 0);
            assert!(
                stats.pressure.udp_would_block > 0,
                "descriptor stimulus must be exercised"
            );
            if preserve_committed {
                assert_eq!(original_generated_expiries + cancelled_committed as u64, 0);
                assert!(io.preserved_committed.get() > 0);
            } else {
                assert!(
                    original_generated_expiries + cancelled_committed as u64 > 0,
                    "baseline must actually lose committed ciphertext"
                );
            }
            assert!(
                after_second_outage >= 100,
                "must restore sustained delivery, not just one probe"
            );
        }
    }

    #[test]
    fn write_gate_real_poll_consumes_failure_permit_across_both_flushes() {
        let (mut a, mut b, io) = blocked_poll_pair();
        let bytes = a.generated.front().unwrap().bytes;
        let deadline = a.generated.front().unwrap().expires;
        a.poll().unwrap();
        eprintln!(
            "real_poll_actual_send_calls={} blocked_attempts={}",
            io.writes.borrow().len(),
            a.stats().pressure.udp_would_block
        );
        assert_eq!(
            io.writes.borrow().len(),
            1,
            "second real flush must not retry this poll"
        );
        assert_eq!(a.generated.front().unwrap().bytes, bytes);
        assert_eq!(a.generated.front().unwrap().expires, deadline);
        a.close();
        b.close();
    }
    #[test]
    fn write_gate_real_blocked_poll_omits_only_stale_head_wake() {
        let (mut a, mut b, _) = blocked_poll_pair();
        a.poll().unwrap();
        let wake = a.next_wakeup();
        // The actual unchanged source cap is independently fixed at100us.
        let capped = wake.min(Duration::from_micros(100));
        eprintln!(
            "real_blocked_wake_ns={} source_capped_wake_ns={}",
            wake.as_nanos(),
            capped.as_nanos()
        );
        assert!(
            capped > Duration::ZERO,
            "blocked past head is not a due timer"
        );
        a.close();
        b.close();
    }
    #[test]
    fn write_gate_real_successive_polls_getters_admission_and_recovery() {
        let (mut a, mut b, io) = blocked_poll_pair();
        let original = a.generated.front().unwrap().bytes.to_vec();
        let length = a.generated.front().unwrap().len;
        let deadline = a.generated.front().unwrap().expires;
        let baseline = a.stats();
        a.poll().unwrap();
        a.stats.pressure.valid = false; // Diagnostic validity is not a service gate.
        assert_eq!(
            io.queries.get(),
            0,
            "no readiness query before actual block"
        );
        for turn in 1..=3 {
            io.now.set(io.now.get() + Duration::from_micros(100));
            a.poll().unwrap();
            assert_eq!(io.queries.get(), turn);
            assert_eq!(io.writes.borrow().len(), 1);
            assert_eq!(a.generated.front().unwrap().expires, deadline);
            assert_eq!(a.generated.front().unwrap().bytes.as_slice(), original);
            assert!(a.next_wakeup() > Duration::ZERO);
        }
        for sequence in 0..64 {
            let admission = a.send(
                Message {
                    lane: Lane::Datagram,
                    sequence,
                    payload: vec![1; 20],
                },
                Instant::now() + Duration::from_secs(1),
            );
            assert!(matches!(
                admission,
                Admission::Accepted | Admission::Backpressured
            ));
        }
        assert_eq!(a.stats().datagram_queue_records, DATAGRAM_RECORDS);
        assert_eq!(
            a.send(
                Message {
                    lane: Lane::Datagram,
                    sequence: 99,
                    payload: vec![2]
                },
                Instant::now()
            ),
            Admission::Expired
        );
        for sequence in 0..128 {
            let admission = a.send(
                Message {
                    lane: Lane::Reliable,
                    sequence,
                    payload: vec![3; 1024],
                },
                Instant::now(),
            );
            assert!(matches!(
                admission,
                Admission::Accepted | Admission::Backpressured
            ));
        }
        assert!(a.stats().reliable_backlog_bytes <= RELIABLE_BYTES);
        for _ in 0..10 {
            let _ = a.receive();
            let _ = a.stats();
            let _ = a.diagnostics();
            let _ = a.next_wakeup();
        }
        assert_eq!((io.queries.get(), io.writes.borrow().len()), (3, 1));
        a.flush_packets(io.now.get()).unwrap();
        assert_eq!(
            io.writes.borrow().len(),
            1,
            "private second flush shares consumed permit"
        );
        io.readiness.borrow_mut().push_back(Ok(libc::POLLOUT));
        a.poll().unwrap(); // Optimistic readiness still gets just one failure.
        assert_eq!((io.queries.get(), io.writes.borrow().len()), (4, 2));
        assert!(a.needs_writable && a.next_wakeup() > Duration::ZERO);
        assert_eq!(
            a.stats().pressure.udp_would_block - baseline.pressure.udp_would_block,
            2
        );
        io.readiness.borrow_mut().push_back(Ok(libc::POLLOUT));
        io.send_error.set(None);
        let before = io.writes.borrow().len();
        a.poll().unwrap();
        assert_eq!(io.queries.get(), 5);
        assert!(!a.needs_writable);
        assert_eq!(
            io.writes.borrow()[before..]
                .iter()
                .filter(|bytes| bytes.as_slice() == &original[..length])
                .count(),
            1,
            "same still-valid ciphertext is successfully written exactly once"
        );
        assert!(a.stats().pressure.udp_success > baseline.pressure.udp_success);
        assert_eq!(a.stats().pressure.write_blocked.duration.count, 1);
        eprintln!(
            "successive_blocked_queries=3 writes=0 optimistic_failure=1 recovered_original_once=1"
        );
        a.close();
        b.close();
        let counts = (io.queries.get(), io.writes.borrow().len());
        a.poll().unwrap();
        a.close();
        let _ = a.next_wakeup();
        assert_eq!((io.queries.get(), io.writes.borrow().len()), counts);
    }
    #[test]
    fn write_gate_real_incoming_recipe_preserves_actual_source_cap_and_deadline() {
        use crate::rate_probe::{RatePeer, RatePeerError, RateShape};
        let (mut a, mut b, io) = blocked_poll_pair();
        a.poll().unwrap();
        // Independent literal authenticated constant recipe/GO, unchanged wire.
        let recipe = vec![
            71, 81, 83, 49, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 46, 224, 0, 0, 117, 48, 0, 0, 2, 88, 0,
            0, 1, 244, 0, 0, 0, 200,
        ];
        assert_eq!(
            b.send(
                Message {
                    lane: Lane::Reliable,
                    sequence: 0,
                    payload: recipe.clone()
                },
                Instant::now()
            ),
            Admission::Accepted
        );
        let end = Instant::now() + Duration::from_secs(1);
        while a.received.is_empty() {
            assert!(Instant::now() < end);
            b.poll().unwrap();
            std::thread::sleep(Duration::from_millis(1));
            a.poll().unwrap();
        }
        assert_eq!(a.received.front().unwrap().payload, recipe);
        assert_eq!(
            io.writes.borrow().len(),
            1,
            "input service never bypasses unavailable output"
        );
        let mut source = RatePeer::new(RateShape::Constant);
        let start = Instant::now();
        source.step(&mut a, start).unwrap();
        let cap = source.next_wakeup(start);
        assert_eq!(
            cap,
            Duration::from_micros(100),
            "actual protected source timer"
        );
        let wait = a.next_wakeup().min(cap);
        assert!(wait > Duration::ZERO && wait <= Duration::from_micros(100));
        let admitted = a.stats().admitted;
        assert!(matches!(
            source.step(&mut a, start + Duration::from_secs(15)),
            Err(RatePeerError::Deadline)
        ));
        assert_eq!(
            a.stats().admitted,
            admitted,
            "original absolute source lease rejects late work"
        );
        assert!(
            b.receive().is_none(),
            "Accepted control is not delivered through a blocked socket"
        );
        assert!(a.stats().reliable_backlog_bytes > 0);
        eprintln!("authenticated_recipe_received=1 actual_source_cap_us={} bounded_wait_us={} original15s_deadline=1", cap.as_micros(), wait.as_micros());
        a.close();
        b.close();
    }
    #[test]
    fn write_gate_real_query_transients_and_fatal_errors_preserve_classification() {
        for errno in [libc::EINTR, libc::EAGAIN] {
            let (mut a, mut b, io) = blocked_poll_pair();
            a.poll().unwrap();
            io.readiness.borrow_mut().push_back(Err(errno));
            a.poll().unwrap();
            assert_eq!((io.queries.get(), io.writes.borrow().len()), (1, 1));
            assert!(!a.stats().retired && a.needs_writable);
            io.readiness.borrow_mut().push_back(Ok(libc::POLLOUT));
            io.send_error.set(None);
            a.poll().unwrap();
            assert!(!a.needs_writable);
            a.close();
            b.close();
        }
        for outcome in [Err(libc::EBADF), Err(libc::EIO), Ok(libc::POLLNVAL)] {
            let (mut a, mut b, io) = blocked_poll_pair();
            a.poll().unwrap();
            io.readiness.borrow_mut().push_back(outcome);
            let errno = outcome.err().unwrap_or(libc::EBADF);
            assert!(matches!(a.poll(), Err(Error::Io(e)) if e.raw_os_error() == Some(errno)));
            assert_eq!(a.diagnostics().retirement, Some(Retirement::Io));
            assert_eq!(a.diagnostics().io_errno, errno);
            assert_eq!((io.queries.get(), io.writes.borrow().len()), (1, 1));
            assert!(a.socket.is_none());
            a.poll().unwrap();
            assert_eq!(io.queries.get(), 1);
            b.close();
        }
        eprintln!("query_EINTR_EAGAIN_defer=1 query_EBADF_EIO_POLLNVAL_retire_actual_errno=1");
    }
    #[test]
    fn write_gate_real_error_ready_is_one_advisory_send_not_success() {
        for events in [libc::POLLERR, libc::POLLHUP, libc::POLLOUT | libc::POLLERR] {
            for failure in [Some(libc::ENOBUFS), Some(libc::EWOULDBLOCK), None] {
                let (mut a, mut b, io) = blocked_poll_pair();
                a.poll().unwrap();
                io.readiness.borrow_mut().push_back(Ok(events));
                io.send_error.set(failure);
                let before = a.stats().pressure.udp_success;
                let result = a.poll();
                assert_eq!((io.queries.get(), io.writes.borrow().len()), (1, 2));
                if failure == Some(libc::ENOBUFS) {
                    assert!(
                        matches!(result, Err(Error::Io(e)) if e.raw_os_error() == Some(libc::ENOBUFS))
                    );
                    assert_eq!(a.diagnostics().io_errno, libc::ENOBUFS);
                } else {
                    result.unwrap();
                }
                assert_eq!(
                    a.stats().pressure.udp_success - before,
                    u64::from(failure.is_none())
                );
                assert!(a.write_permit == WritePermit::Denied);
                a.close();
                b.close();
            }
        }
        eprintln!("POLLERR_HUP_each_one_real_send_advisory_error_block_or_success=1");
    }
    #[test]
    fn write_gate_real_expiry_minima_include_later_descriptor_and_future_release() {
        let (mut a, mut b, io) = blocked_poll_pair();
        a.poll().unwrap();
        let now = io.now.get();
        // Reuse genuinely encrypted bytes for descriptor-boundary fixtures;
        // none of these copied packets can be written in the denied turns.
        let head = a.generated.front_mut().unwrap();
        head.expires = None;
        let later = Packet {
            generated_at: head.generated_at,
            bytes: head.bytes,
            len: head.len,
            at: now + Duration::from_millis(1),
            expires: Some(now + Duration::from_micros(50)),
            datagram_sequence: None,
        };
        a.generated.push_back(later);
        assert_eq!(
            a.next_wakeup(),
            Duration::from_micros(50),
            "all descriptor expiry minima, not only head"
        );
        io.now.set(now + Duration::from_micros(50));
        assert_eq!(
            a.next_wakeup(),
            Duration::ZERO,
            "genuine expiry stays immediately due"
        );
        let before = a.stats();
        a.poll().unwrap();
        assert_eq!(a.stats().expired, before.expired + 1);
        assert_eq!(
            a.stats().pressure.expiry_generated,
            before.pressure.expiry_generated + 1
        );
        assert_eq!(
            a.stats().pressure.generated_write_age.count,
            before.pressure.generated_write_age.count
        );
        assert_eq!(io.writes.borrow().len(), 1);
        assert!(a
            .generated
            .iter()
            .all(|p| p.expires != Some(now + Duration::from_micros(50))));
        a.generated.front_mut().unwrap().at = io.now.get() + Duration::from_micros(40);
        assert_eq!(
            a.next_wakeup(),
            Duration::from_micros(40),
            "future pacing is still a wake minimum"
        );
        a.generated.front_mut().unwrap().expires = Some(io.now.get() + Duration::from_micros(20));
        assert_eq!(a.next_wakeup(), Duration::from_micros(20));
        io.now.set(io.now.get() + Duration::from_micros(20));
        a.poll().unwrap();
        assert_eq!(a.stats().expired, before.expired + 2);
        assert!(!a.needs_writable && !a.stats_at(io.now.get()).pressure.write_blocked.active);
        assert_eq!(io.writes.borrow().len(), 1);
        a.close();
        b.close();
    }
    #[test]
    fn write_gate_real_fresh_clock_expires_second_packet_between_successful_writes() {
        let (mut a, mut b, io) = blocked_poll_pair();
        assert_eq!(
            a.send(
                Message {
                    lane: Lane::Datagram,
                    sequence: 902,
                    payload: vec![0x29; 800]
                },
                Instant::now() + Duration::from_secs(2)
            ),
            Admission::Accepted
        );
        a.generate_packets().unwrap();
        assert_eq!(a.generated.len(), 2);
        let deadline = io.now.get() + Duration::from_millis(1);
        for p in &mut a.generated {
            p.expires = Some(deadline);
        }
        io.send_error.set(None);
        io.actions.borrow_mut().push_back((None, Some(deadline)));
        let before = a.stats();
        a.poll().unwrap();
        assert_eq!(
            io.writes.borrow().len(),
            1,
            "fresh expiry must precede the second actual send"
        );
        assert_eq!(
            a.stats().pressure.udp_success,
            before.pressure.udp_success + 1
        );
        assert_eq!(a.stats().expired, before.expired + 1);
        assert_eq!(
            a.stats().pressure.expiry_generated,
            before.pressure.expiry_generated + 1
        );
        assert_eq!(
            a.stats().pressure.generated_write_age.count,
            before.pressure.generated_write_age.count + 1
        );
        assert!(a.generated.is_empty());
        a.close();
        b.close();
    }
    #[test]
    fn write_gate_real_expired_empty_refilled_queue_cannot_rearm_same_turn() {
        for first_failure_this_turn in [false, true] {
            let (mut a, mut b, io) = blocked_poll_pair();
            let deadline = io.now.get() + Duration::from_millis(1);
            a.generated.front_mut().unwrap().expires = Some(deadline);
            if !first_failure_this_turn {
                a.poll().unwrap();
            }
            assert_eq!(
                a.send(
                    Message {
                        lane: Lane::Datagram,
                        sequence: 902,
                        payload: vec![0x29; 800]
                    },
                    Instant::now() + Duration::from_secs(2)
                ),
                Admission::Accepted
            );
            if first_failure_this_turn {
                io.actions
                    .borrow_mut()
                    .push_back((Some(libc::EWOULDBLOCK), Some(deadline)));
            } else {
                io.now.set(deadline);
            }
            let before = a.stats();
            a.poll().unwrap();
            assert_eq!(
                io.writes.borrow().len(),
                1,
                "expired old output plus freshly generated output cannot retry same poll"
            );
            assert!(
                !a.generated.is_empty(),
                "real quiche generated the replacement output"
            );
            assert!(a.generated.iter().all(|p| p.expires != Some(deadline)));
            assert_eq!(a.stats().expired, before.expired + 1);
            assert!(a.write_permit == WritePermit::Denied);
            assert_eq!(io.queries.get(), usize::from(!first_failure_this_turn));
            a.close();
            b.close();
        }
    }
    #[test]
    fn write_gate_real_connect_stall_and_quiche_timer_minima_are_not_renewed() {
        let mut listener = endpoint();
        let now = listener.created + TIMEOUT - Duration::from_micros(25);
        let io = TestPollIo::blocked(now);
        listener.poll_io = Some(io.clone());
        assert_eq!(listener.next_wakeup(), Duration::from_micros(25));
        listener.poll().unwrap();
        assert!(!listener.stats().retired);
        io.now.set(now + Duration::from_micros(25));
        assert_eq!(listener.next_wakeup(), Duration::ZERO);
        listener.poll().unwrap();
        assert_eq!(
            listener.diagnostics().retirement,
            Some(Retirement::ConnectTimeout)
        );
        assert_eq!(io.queries.get(), 0);
        let (mut a, mut b, io) = blocked_poll_pair();
        a.poll().unwrap();
        let deadline = io.now.get() + Duration::from_micros(25);
        assert_eq!(
            a.send(
                Message {
                    lane: Lane::Reliable,
                    sequence: 0,
                    payload: vec![9; 20]
                },
                Instant::now()
            ),
            Admission::Accepted
        );
        a.reliable_progress = deadline - TIMEOUT;
        assert_eq!(a.next_wakeup(), Duration::from_micros(25));
        a.poll().unwrap();
        assert!(!a.stats().retired);
        assert_eq!(a.reliable_progress + TIMEOUT, deadline);
        io.now.set(deadline);
        assert_eq!(a.next_wakeup(), Duration::ZERO);
        a.observation_clock = Some(deadline);
        a.poll().unwrap();
        assert_eq!(a.diagnostics().retirement, Some(Retirement::ReliableStall));
        assert!(a.diagnostics().pressure.write_blocked.active);
        assert_eq!(io.writes.borrow().len(), 1);
        assert_eq!(
            io.queries.get(),
            1,
            "due terminal boundary runs before readiness query"
        );
        assert!(a.socket.is_none() && a.generated.is_empty());
        b.close();
        let (mut a, mut b, io) = blocked_poll_pair();
        a.poll().unwrap();
        let timeout = a.connection.as_ref().unwrap().timeout().unwrap();
        assert!(a.next_wakeup() <= timeout);
        // The unchanged real quiche timer must remain observable while blocked.
        let end = Instant::now() + Duration::from_secs(1);
        while !a
            .connection
            .as_ref()
            .unwrap()
            .timeout()
            .is_some_and(|t| t.is_zero())
        {
            assert!(Instant::now() < end);
            std::thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(a.next_wakeup(), Duration::ZERO);
        a.poll().unwrap();
        assert_eq!(io.writes.borrow().len(), 1);
        a.close();
        b.close();
    }
    #[test]
    fn write_gate_real_unblocked_poll_preserves_multi_packet_service() {
        let (mut a, mut b, io) = blocked_poll_pair();
        for sequence in 902..908 {
            assert_eq!(
                a.send(
                    Message {
                        lane: Lane::Datagram,
                        sequence,
                        payload: vec![0x29; 800]
                    },
                    Instant::now() + Duration::from_secs(2)
                ),
                Admission::Accepted
            );
        }
        io.send_error.set(None);
        a.poll().unwrap();
        assert_eq!(io.queries.get(), 0);
        assert!(
            io.writes.borrow().len() > 1,
            "no one-packet throttle on normally writable output"
        );
        assert!(!a.needs_writable);
        a.close();
        b.close();
    }
    #[test]
    fn write_gate_real_owned_fd_readiness_recovers_authenticated_ciphertext() {
        let (mut a, mut b, io) = blocked_poll_pair();
        a.poll().unwrap();
        assert!(a.needs_writable);
        // The injected first turn is 1ms in the future. Return to the real
        // clock only after that same instant, not a backwards clock jump.
        while Instant::now() < io.now.get() {
            std::thread::sleep(Duration::from_micros(50));
        }
        a.poll_io = None; // Subsequent poll uses actual libc POLLOUT/timeout0.
        let end = Instant::now() + Duration::from_secs(1);
        let mut received = None;
        while received.is_none() {
            assert!(Instant::now() < end);
            a.poll().unwrap();
            b.poll().unwrap();
            received = b.receive();
            std::thread::sleep(Duration::from_micros(100));
        }
        let record = received.unwrap();
        assert_eq!(
            (record.lane, record.sequence, record.payload),
            (Lane::Datagram, 901, vec![0x19; 800])
        );
        assert!(!a.needs_writable);
        assert_eq!(
            io.writes.borrow().len(),
            1,
            "only first injected failure; recovery uses owned actual socket"
        );
        a.close();
        b.close();
    }
    #[test]
    fn write_gate_readiness_adapter_checks_count_and_irrelevant_flags() {
        let socket = UdpSocket::bind("127.0.0.1:0").unwrap();
        socket.set_nonblocking(true).unwrap();
        assert!(writable_permit_with(&socket, |_, _, _| Ok(0)).unwrap() == WritePermit::Denied);
        assert!(
            writable_permit_with(&socket, |fd, _, _| {
                fd.revents = libc::POLLIN;
                Ok(1)
            })
            .unwrap()
                == WritePermit::Denied
        );
        assert!(
            matches!(writable_permit_with(&socket, |_, _, _| Ok(2)), Err(e) if e.kind() == std::io::ErrorKind::InvalidData)
        );
        assert!(
            matches!(writable_permit_with(&socket, |fd, _, _| { fd.revents = libc::POLLNVAL | libc::POLLOUT; Ok(1) }), Err(e) if e.raw_os_error() == Some(libc::EBADF))
        );
    }
    #[test]
    fn write_gate_real_continuously_unwritable_output_keeps_quiche_idle_retirement() {
        let (mut a, mut b, io) = blocked_poll_pair();
        a.poll().unwrap();
        let end = Instant::now() + Duration::from_secs(7);
        let mut turns = 1;
        while !a.stats().retired {
            assert!(
                Instant::now() < end,
                "original quiche idle boundary must still retire"
            );
            std::thread::sleep(Duration::from_millis(1));
            a.poll().unwrap();
            turns += 1;
        }
        let terminal = a.diagnostics();
        assert_eq!(terminal.retirement, Some(Retirement::PeerIdle));
        assert!(
            a.stats().quic_timed_out,
            "retain quiche's actual timeout cause after cleanup"
        );
        assert!(terminal.pressure.write_blocked.active);
        assert!(terminal.generated_packets > 0);
        assert_eq!(io.writes.borrow().len(), 1);
        assert!(io.queries.get() <= turns - 1);
        assert_eq!(a.stats().generated_packets, 0);
        assert!(a.socket.is_none());
        let queries = io.queries.get();
        a.poll().unwrap();
        assert_eq!(io.queries.get(), queries);
        eprintln!("blocked_real_idle_retirement=PeerIdle turns={turns} queries={queries} actual_failed_sends=1 released=1");
        b.close();
    }
    #[test]
    fn observation_public_live_views_do_not_query_paths_outside_poll_cadence() {
        let (mut a, mut b) = ready_pair();
        let t = Instant::now();
        a.observation_clock = Some(t);
        a.last_path_sample = None;
        a.poll().unwrap();
        let base = a.path_queries.get();
        let samples = a.stats().path.samples;
        for offset in [0, 99, 100, 101, 199, 200, 201] {
            a.observation_clock = Some(t + Duration::from_millis(offset));
            let before = a.path_queries.get();
            for _ in 0..10 {
                let _ = a.stats();
                let _ = a.diagnostics();
            }
            assert_eq!(
                a.path_queries.get(),
                before,
                "casual public reads at {offset}ms queried quiche"
            );
            a.poll().unwrap();
            let expected = base + u64::from(offset >= 100) + u64::from(offset >= 200);
            assert_eq!(
                a.path_queries.get(),
                expected,
                "actual public poll cadence at {offset}ms"
            );
            assert_eq!(a.stats().path.samples, samples + expected - base);
        }
        eprintln!(
            "public_live_queries={} expected={} retained_samples={}",
            a.path_queries.get() - base,
            2,
            a.stats().path.samples - samples
        );
        a.close();
        b.close();
    }
    #[test]
    fn observation_terminal_capture_commits_once_and_preserves_preclose_evidence() {
        let (mut a, mut b) = ready_pair();
        let t = Instant::now();
        a.observation_clock = Some(t);
        a.last_path_sample = Some(t);
        // No periodic path measurement retained yet; the real terminal query
        // must populate actual quiche values/extrema, not merely flip a flag.
        a.stats.path = PathObservation::default();
        let before = a.path_queries.get();
        assert_eq!(
            a.send(
                Message {
                    lane: Lane::Datagram,
                    sequence: 22,
                    payload: vec![8]
                },
                t + Duration::from_secs(1)
            ),
            Admission::Accepted
        );
        let original = a.stats();
        let captured = a.capture_terminal_diagnostics();
        assert_eq!(a.path_queries.get(), before + 1);
        assert_eq!(captured.path.samples, 1);
        assert!(captured.path.terminal && captured.path.available && captured.path.rtt_available);
        assert!(
            captured.path.cwnd_min_bytes > 0
                && captured.path.cwnd_max_bytes >= captured.path.cwnd_min_bytes
        );
        assert!(captured.path.max_rtt_ns >= captured.path.min_rtt_ns);
        assert_eq!(
            captured.datagram_queue_records,
            original.datagram_queue_records
        );
        assert!(captured.application_ready && !captured.retired);
        assert_eq!(captured.retirement, None);
        assert_eq!(
            a.send(
                Message {
                    lane: Lane::Datagram,
                    sequence: 23,
                    payload: vec![9]
                },
                t + Duration::from_secs(1)
            ),
            Admission::Accepted,
            "observer freeze does not change admission"
        );
        for offset in [0, 99, 100, 101, 201] {
            a.observation_clock = Some(t + Duration::from_millis(offset));
            for _ in 0..10 {
                let _ = a.stats();
                let view = a.diagnostics();
                assert_eq!(view.path.samples, 1);
                assert!(view.path.terminal);
            }
            a.capture_terminal_diagnostics();
            a.poll().unwrap();
        }
        a.close();
        let terminal = a.diagnostics();
        a.capture_terminal_diagnostics();
        a.close();
        assert_eq!(a.path_queries.get(), before + 1);
        assert_eq!(terminal.path.sample_at_ns, captured.path.sample_at_ns);
        assert_eq!(terminal.path.cwnd_max_bytes, captured.path.cwnd_max_bytes);
        assert_eq!(terminal.path.min_rtt_ns, captured.path.min_rtt_ns);
        assert_eq!(terminal.path.max_rtt_ns, captured.path.max_rtt_ns);
        assert_eq!(terminal.path.samples, 1);
        assert!(terminal.path.terminal);
        assert_eq!(a.stats().generated_packets, 0);
        assert_eq!(a.stats().datagram_queue_records, 0);
        eprintln!("owner_terminal_queries=1 terminal_samples={} before_close_ready={} before_close_retirement={:?} terminal_cwnd_min={} terminal_cwnd_max={} terminal_rtt_min={} terminal_rtt_max={}",captured.path.samples,captured.application_ready,captured.retirement,captured.path.cwnd_min_bytes,captured.path.cwnd_max_bytes,captured.path.min_rtt_ns,captured.path.max_rtt_ns);
        b.close();
        let (mut a, mut b) = ready_pair();
        let before = a.path_queries.get();
        a.close();
        let terminal = a.diagnostics();
        assert_eq!(a.path_queries.get(), before + 1);
        assert!(terminal.path.terminal);
        a.capture_terminal_diagnostics();
        a.close();
        assert_eq!(a.path_queries.get(), before + 1);
        b.close();
    }
    #[test]
    fn observation_terminal_worst_width_and_retained_memory_caps() {
        let mut s = Stats::default();
        s.pressure.generated_cap_stops = u64::MAX;
        s.pressure.quiche_done_pending_dg = u64::MAX;
        s.pressure.future_send_stops = u64::MAX;
        s.pressure.udp_attempts = u64::MAX;
        s.pressure.udp_would_block = u64::MAX;
        s.pressure.udp_would_block_due = u64::MAX;
        s.pressure.udp_success = u64::MAX;
        s.pressure.udp_errors = u64::MAX;
        s.pressure.udp_short = u64::MAX;
        s.pressure.expiry_submission = u64::MAX;
        s.pressure.expiry_queued = u64::MAX;
        s.pressure.expiry_generated = u64::MAX;
        s.pressure.wrapper_record_stops = u64::MAX;
        s.pressure.wrapper_byte_stops = u64::MAX;
        s.pressure.dg_budget_stops = u64::MAX;
        s.pressure.retained_intake_pauses = u64::MAX;
        s.pressure.udp_saturated_turns = u64::MAX;
        s.path.sample_at_ns = u64::MAX;
        s.path.rtt_ns = u64::MAX;
        s.path.min_rtt_ns = u64::MAX;
        s.path.max_rtt_ns = u64::MAX;
        s.path.rttvar_ns = u64::MAX;
        s.path.cwnd_bytes = u64::MAX;
        s.path.cwnd_min_bytes = u64::MAX;
        s.path.cwnd_max_bytes = u64::MAX;
        s.path.lost_packets = u64::MAX;
        s.path.retrans_packets = u64::MAX;
        s.path.pto_count = u64::MAX;
        s.path.lost_dg_frames = u64::MAX;
        s.path.stream_retrans_bytes = u64::MAX;
        s.path.delivery_rate_bytes_per_second = u64::MAX;
        s.path.delivery_rate_max_bytes_per_second = u64::MAX;
        s.path.pmtu_bytes = u64::MAX;
        s.path.max_bandwidth_bytes_per_second = u64::MAX;
        s.path.samples = u64::MAX;
        s.path.unavailable_samples = u64::MAX;
        let metric = Metric {
            count: u64::MAX,
            total_ns: u64::MAX,
            max_ns: u64::MAX,
            valid: true,
        };
        s.pressure.generated_write_age = metric;
        s.pressure.write_blocked = SpanSummary {
            duration: metric,
            active: true,
            active_ns: u64::MAX,
        };
        s.pressure.retained = s.pressure.write_blocked;
        s.socket_buffers.send = SocketValue {
            available: true,
            bytes: i32::MIN,
            errno: i32::MIN,
        };
        s.socket_buffers.receive = s.socket_buffers.send;
        let owner = crate::bootstrap::diagnostics::OwnerSummary {
            turns: u64::MAX,
            zero_sleep: u64::MAX,
            retired_step_skips: u64::MAX,
            valid: true,
            poll: metric,
            step: metric,
            service_gap: metric,
            requested_sleep: metric,
            actual_sleep: metric,
            overshoot: metric,
        };
        let mut output = Vec::new();
        for role in [
            crate::bootstrap::diagnostics::Role::Peer,
            crate::bootstrap::diagnostics::Role::Client,
        ] {
            crate::bootstrap::diagnostics::write_terminal(&mut output, role, s, owner).unwrap();
        }
        let text = String::from_utf8(output).unwrap();
        assert!(
            text.len() <= 16 * 1024,
            "exact worst-width bytes={}",
            text.len()
        );
        let tokens: Vec<_> = text.split_whitespace().collect();
        let names: std::collections::HashSet<_> = tokens
            .iter()
            .map(|t| t.split_once('=').unwrap().0)
            .collect();
        assert_eq!(tokens.len(), names.len(), "duplicate scalar names");
        assert!(tokens
            .iter()
            .all(|t| t.split_once('=').unwrap().1.parse::<i128>().is_ok()));
        // Conservative accounting includes entire enlarged live+terminal Stats
        // (including their old fields), both spans, per-existing-packet added
        // timestamp, sampling timestamp and one owner. No additional heap.
        let retained = 2 * std::mem::size_of::<Stats>()
            + 2 * std::mem::size_of::<Span>()
            + GENERATED_PACKETS * std::mem::size_of::<Instant>()
            + std::mem::size_of::<Option<Instant>>()
            + std::mem::size_of::<crate::bootstrap::diagnostics::OwnerTiming>();
        assert!(
            retained <= 16 * 1024,
            "conservative retained diagnostic bytes={retained}"
        );
        eprintln!("observation_extra_terminal_worst_bytes={} scalar_count={} retained_diagnostic_upper_bytes={} stats_bytes={} packet_timestamp_bytes={} owner_bytes={}",
            text.len(),tokens.len(),retained,std::mem::size_of::<Stats>(),std::mem::size_of::<Instant>(),std::mem::size_of::<crate::bootstrap::diagnostics::OwnerTiming>());
    }
    #[test]
    fn pressure_observation_path_sampling_counter_validity_and_socket_failures() {
        let (mut a, mut b) = ready_pair();
        let t = Instant::now();
        a.last_path_sample = None;
        a.sample_path(t);
        let count = a.stats.path.samples;
        a.sample_path(t + Duration::from_millis(99));
        assert_eq!(a.stats.path.samples, count);
        a.sample_path(t + Duration::from_millis(100));
        assert_eq!(a.stats.path.samples, count + 1);
        a.sample_path(t + Duration::from_millis(201));
        assert_eq!(a.stats.path.samples, count + 2);
        a.sample_path(t);
        assert!(!a.stats.path.valid);
        assert!(!a.stats.retired);
        let path = a
            .connection
            .as_ref()
            .unwrap()
            .path_stats()
            .find(|p| p.active)
            .unwrap();
        let mut observation = PathObservation::default();
        let mut no_measurement = path.clone();
        no_measurement.min_rtt = None;
        no_measurement.max_rtt = None;
        no_measurement.max_bandwidth = Some(0);
        observation.observe(Some(no_measurement), Some(1));
        assert!(
            observation.available
                && !observation.rtt_available
                && !observation.max_bandwidth_available
                && !observation.delivery_rate_available
        );
        let mut newer = path.clone();
        newer.lost = 2;
        observation.observe(Some(newer), Some(2));
        observation.observe(Some(path.clone()), Some(3));
        assert!(!observation.valid, "decreasing public counter");
        let mut overflow = PathObservation {
            samples: u64::MAX,
            ..PathObservation::default()
        };
        overflow.observe(Some(path.clone()), Some(1));
        assert!(!overflow.valid);
        let mut invalid = PathObservation::default();
        let mut saturated = path;
        saturated.dgram_lost = usize::MAX;
        invalid.observe(Some(saturated), Some(1));
        assert!(!invalid.valid);
        let mut missing = PathObservation::default();
        missing.observe(None, Some(1));
        assert_eq!(missing.unavailable_samples, 1);
        assert!(!missing.available);
        missing.observe(None, None);
        assert!(!missing.valid);
        let mut options = Vec::new();
        let buffers = SocketBuffers::query_with(|option| {
            options.push(option);
            if option == libc::SO_SNDBUF {
                Ok(4096)
            } else {
                Err(libc::EBADF)
            }
        });
        assert_eq!(options, [libc::SO_SNDBUF, libc::SO_RCVBUF]);
        assert!(buffers.send.available);
        assert_eq!(buffers.send.bytes, 4096);
        assert!(!buffers.receive.available);
        assert_eq!(buffers.receive.errno, libc::EBADF);
        a.close();
        b.close();
        let saved = a.diagnostics();
        assert_eq!(a.diagnostics().path.samples, saved.path.samples);
    }
    #[test]
    fn pressure_observation_generated_cap_done_and_other_os_results() {
        let mut e = endpoint();
        e.peer = Some("127.0.0.1:9".parse().unwrap());
        let t = Instant::now();
        for _ in 0..GENERATED_PACKETS {
            e.generated.push_back(Packet {
                generated_at: t,
                bytes: [1; UDP_SIZE],
                len: 1,
                at: t,
                expires: None,
                datagram_sequence: None,
            });
        }
        e.generate_packets().unwrap();
        assert_eq!(e.stats().pressure.generated_cap_stops, 1);
        assert_eq!(e.generated.len(), 32);
        assert!(matches!(
            e.flush_packets_with(
                t,
                || t,
                |_, _, _| Err(std::io::ErrorKind::PermissionDenied.into())
            ),
            Err(Error::Io(_))
        ));
        assert_eq!(e.stats().pressure.udp_errors, 1);
        assert_eq!(e.generated.len(), 32);
        assert!(matches!(
            e.flush_packets_with(t, || t, |_, _, _| Ok(0)),
            Err(Error::Transport)
        ));
        assert_eq!(e.stats().pressure.udp_short, 1);
        assert_eq!(e.stats().pressure.udp_attempts, 2);
        e.stats.pressure.udp_attempts = u64::MAX;
        e.flush_packets_with(t, || t, |_, bytes, _| Ok(bytes.len()))
            .unwrap();
        assert!(!e.stats().pressure.valid);
        assert!(!e.stats().retired);
        assert_eq!(e.stats().pressure.udp_attempts, u64::MAX);
        let (mut sender, mut receiver) = ready_pair();
        for sequence in 0..256 {
            sender.send(
                Message {
                    lane: Lane::Datagram,
                    sequence,
                    payload: vec![1; 1024],
                },
                Instant::now() + Duration::from_secs(1),
            );
            sender.poll().unwrap();
            if sender.stats().pressure.quiche_done_pending_dg > 0 {
                break;
            }
        }
        assert!(
            sender.stats().pressure.quiche_done_pending_dg > 0,
            "real quiche Done with queued DG, not a mocked congestion result"
        );
        assert!(!sender.stats().retired);
        sender.close();
        receiver.close();
    }
    #[test]
    fn pressure_observation_byte_stop_and_last_decision_expiry() {
        let (mut sender, mut receiver) = ready_pair();
        for sequence in 0..61 {
            assert_eq!(
                sender.send(
                    Message {
                        lane: Lane::Datagram,
                        sequence,
                        payload: vec![8; 1024]
                    },
                    Instant::now() + Duration::from_secs(1)
                ),
                Admission::Accepted
            );
            sender.poll().unwrap();
            std::thread::sleep(Duration::from_millis(1));
            receiver.poll().unwrap();
        }
        assert_eq!(receiver.stats().receive_queue_records, 60);
        assert!(receiver.stats().pressure.wrapper_byte_stops > 0);
        assert_eq!(receiver.stats().pressure.wrapper_record_stops, 0);
        assert!(receiver.stats().pressure.retained.active);
        while receiver.receive().is_some() {}
        receiver.poll().unwrap();
        assert!(!receiver.stats().pressure.retained.active);
        assert_eq!(receiver.receive().unwrap().sequence, 60);
        sender.close();
        receiver.close();
        let mut e = endpoint();
        let start = Instant::now();
        let deadline = start + Duration::from_millis(1);
        e.generated.push_back(Packet {
            generated_at: start,
            bytes: [1; UDP_SIZE],
            len: 1,
            at: start,
            expires: Some(deadline),
            datagram_sequence: None,
        });
        e.flush_packets_with(
            start,
            || deadline,
            |_, _, _| panic!("expired at final OS decision"),
        )
        .unwrap();
        assert_eq!(e.stats().pressure.expiry_generated, 1);
        assert_eq!(e.stats().expired, 1);
        assert_eq!(e.stats().pressure.udp_attempts, 0);
    }
    #[test]
    fn pressure_observation_socket_and_active_path_are_not_missing_or_default_rtt() {
        let empty = endpoint();
        assert!(empty.stats().socket_buffers.send.available);
        assert!(empty.stats().socket_buffers.receive.available);
        assert!(!empty.stats().path.available);
        assert!(!empty.stats().path.rtt_available);
        let (mut a, mut b) = ready_pair();
        let terminal = a.capture_terminal_diagnostics();
        assert!(terminal.path.samples > 0);
        assert!(terminal.path.rtt_available);
        assert!(!terminal.path.max_bandwidth_available);
        a.close();
        b.close();
        assert!(a.diagnostics().path.samples > 0);
    }
    #[test]
    fn pressure_observation_expiry_sites_and_future_pacing_are_disjoint() {
        let mut e = endpoint();
        let now = Instant::now();
        assert_eq!(
            e.send(
                Message {
                    lane: Lane::Datagram,
                    sequence: 0,
                    payload: vec![]
                },
                now
            ),
            Admission::Expired
        );
        e.datagrams.push_back(Datagram {
            bytes: vec![1],
            deadline: now,
            sequence: 1,
        });
        e.quiche_datagram_deadline = Some(now);
        e.quiche_datagram_sequence = Some(2);
        e.expire_datagrams(now);
        e.generated.push_back(Packet {
            generated_at: now,
            bytes: [1; UDP_SIZE],
            len: 1,
            at: now,
            expires: Some(now),
            datagram_sequence: Some(3),
        });
        e.flush_packets_with(now, || now, |_, _, _| panic!("expired packet reached OS"))
            .unwrap();
        let p = e.stats_at(now).pressure;
        assert_eq!(
            (p.expiry_submission, p.expiry_queued, p.expiry_generated),
            (1, 2, 1)
        );
        assert_eq!(
            e.stats().expired,
            p.expiry_submission + p.expiry_queued + p.expiry_generated
        );
        assert_eq!(
            std::iter::from_fn(|| e.take_datagram_expiry()).collect::<Vec<_>>(),
            vec![
                DatagramExpiry {
                    sequence: 1,
                    stage: DatagramExpiryStage::Queued,
                },
                DatagramExpiry {
                    sequence: 2,
                    stage: DatagramExpiryStage::Quiche,
                },
                DatagramExpiry {
                    sequence: 3,
                    stage: DatagramExpiryStage::Generated,
                },
            ]
        );
        e.generated.push_back(Packet {
            generated_at: now,
            bytes: [1; UDP_SIZE],
            len: 1,
            at: now + Duration::from_millis(1),
            expires: None,
            datagram_sequence: None,
        });
        e.flush_packets_with(now, || now, |_, _, _| panic!("future pacing reached OS"))
            .unwrap();
        let p = e.stats_at(now).pressure;
        assert_eq!(p.future_send_stops, 1);
        assert_eq!(p.udp_attempts, 0);
        assert_eq!(p.udp_would_block, 0);
        assert!(!p.write_blocked.active);
        assert_eq!(p.expiry_generated, 1);
        assert_eq!(e.stats_at(now).pressure.expiry_generated, 1);
    }
    #[test]
    fn pressure_observation_active_span_snapshot_and_retirement_do_not_restart() {
        let mut e = endpoint();
        e.peer = Some("127.0.0.1:9".parse().unwrap());
        let start = Instant::now();
        e.generated.push_back(Packet {
            generated_at: start,
            bytes: [1; UDP_SIZE],
            len: 1,
            at: start,
            expires: None,
            datagram_sequence: None,
        });
        e.flush_packets_with(
            start,
            || start,
            |_, _, _| Err(std::io::ErrorKind::WouldBlock.into()),
        )
        .unwrap();
        let end = start + Duration::from_millis(3);
        for _ in 0..2 {
            let p = e.stats_at(end).pressure;
            assert!(p.write_blocked.active);
            assert_eq!(p.write_blocked.duration.count, 1);
            assert_eq!(p.write_blocked.duration.total_ns, 3_000_000);
        }
        e.retire_at(Retirement::Closed, end);
        assert!(e.diagnostics().pressure.write_blocked.active);
        assert_eq!(
            e.diagnostics().pressure.write_blocked.duration.total_ns,
            3_000_000
        );
        assert!(!e.stats_at(end).pressure.write_blocked.active);
        assert_eq!(e.stats_at(end).pressure.write_blocked.duration.count, 1);
        assert_eq!(e.stats().generated_packets, 0);
    }
    #[test]
    fn pressure_observation_real_receive_budget_pause_and_release() {
        let (mut sender, mut receiver) = ready_pair();
        queue_one_dg_packets(&mut sender, 63, 0);
        let frames = (63..65)
            .map(|sequence| {
                wire::encode(
                    &[1; 32],
                    &Message {
                        lane: Lane::Datagram,
                        sequence,
                        payload: vec![8],
                    },
                )
                .unwrap()
            })
            .collect();
        send_frame_packet(&mut sender, &receiver, frames);
        std::thread::sleep(Duration::from_millis(1));
        receiver.poll().unwrap();
        assert_eq!(receiver.stats().quiche_datagrams_decoded, 65);
        assert_eq!(receiver.stats().datagrams_extracted, 64);
        let p = receiver.stats().pressure;
        assert_eq!(p.udp_saturated_turns, 1);
        assert_eq!(p.dg_budget_stops, 1);
        assert!(p.retained.active);
        receiver.poll().unwrap();
        let p = receiver.stats().pressure;
        assert_eq!(p.retained_intake_pauses, 1);
        assert!(p.wrapper_record_stops > 0);
        while receiver.receive().is_some() {}
        receiver.poll().unwrap();
        assert_eq!(receiver.receive().unwrap().sequence, 64);
        let p = receiver.stats().pressure;
        assert!(!p.retained.active);
        assert_eq!(p.retained.duration.count, 1);
        assert!(p.retained.duration.max_ns > 0);
        assert_eq!(receiver.stats().quiche_datagrams_evicted, 0);
    }
    #[test]
    fn pressure_observation_would_block_span_keeps_deadline_and_write_age() {
        let mut e = endpoint();
        e.peer = Some("127.0.0.1:9".parse().unwrap());
        let start = Instant::now();
        let deadline = start + Duration::from_millis(10);
        e.generated.push_back(Packet {
            generated_at: start,
            bytes: [1; UDP_SIZE],
            len: 1,
            at: start,
            expires: Some(deadline),
            datagram_sequence: None,
        });
        for elapsed in [1, 2] {
            let now = start + Duration::from_millis(elapsed);
            // These observations deliberately represent separate poll turns.
            e.begin_write_turn().unwrap();
            e.flush_packets_with(
                now,
                || now,
                |_, _, _| Err(std::io::ErrorKind::WouldBlock.into()),
            )
            .unwrap();
            assert_eq!(e.generated.front().unwrap().expires, Some(deadline));
        }
        let now = start + Duration::from_millis(5);
        e.begin_write_turn().unwrap();
        e.flush_packets_with(now, || now, |_, bytes, _| Ok(bytes.len()))
            .unwrap();
        let p = e.stats().pressure;
        assert_eq!(p.udp_would_block, 2);
        assert_eq!(p.udp_would_block_due, 2);
        assert_eq!(p.udp_attempts, 3);
        assert_eq!(p.udp_success, 1);
        assert_eq!(p.write_blocked.duration.count, 1);
        assert_eq!(p.write_blocked.duration.total_ns, 4_000_000);
        assert_eq!(p.generated_write_age.count, 1);
        assert_eq!(p.generated_write_age.max_ns, 5_000_000);
        assert_eq!(e.stats().expired, 0);
        assert_eq!(e.stats().generated_packets, 0);
    }
    fn ready_pair() -> (Endpoint, Endpoint) {
        ready_pair_with_sender_capacity(32)
    }
    #[test]
    fn latency_critical_pair_is_unpaced_and_negotiates_one_millisecond_ack_delay() {
        let a = Identity::generate().unwrap();
        let b = Identity::generate().unwrap();
        let ap = a.fingerprint();
        let bp = b.fingerprint();
        let mut listener = Endpoint::listen_with_transport_options(
            "127.0.0.1:0".parse().unwrap(),
            "127.0.0.1".parse().unwrap(),
            [9; 32],
            b,
            ap,
            CongestionControl::Cubic,
            None,
            Some(1),
            false,
        )
        .unwrap();
        assert!(!listener.pacing_enabled);
        let mut connector = Endpoint::connect_with_transport_options(
            "127.0.0.1:0".parse().unwrap(),
            listener.local_addr().unwrap(),
            [9; 32],
            a,
            bp,
            CongestionControl::Cubic,
            Some(1),
            false,
        )
        .unwrap();
        assert!(!connector.pacing_enabled);
        let deadline = Instant::now() + Duration::from_secs(2);
        while !(listener.stats().application_ready && connector.stats().application_ready) {
            assert!(Instant::now() < deadline);
            listener.poll().unwrap();
            connector.poll().unwrap();
            std::thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(
            listener
                .connection
                .as_ref()
                .unwrap()
                .peer_transport_params()
                .unwrap()
                .max_ack_delay,
            1
        );
        assert_eq!(
            connector
                .connection
                .as_ref()
                .unwrap()
                .peer_transport_params()
                .unwrap()
                .max_ack_delay,
            1
        );
        listener.close();
        connector.close();
    }
    fn ready_pair_with_sender_capacity(sender_capacity: usize) -> (Endpoint, Endpoint) {
        ready_pair_with_options(sender_capacity, CongestionControl::Cubic)
    }
    fn ready_pair_with_options(
        sender_capacity: usize,
        cc: CongestionControl,
    ) -> (Endpoint, Endpoint) {
        ready_pair_with_pacing_cap(sender_capacity, cc, None)
    }
    fn ready_pair_with_pacing_cap(
        sender_capacity: usize,
        cc: CongestionControl,
        max_pacing_rate: Option<u64>,
    ) -> (Endpoint, Endpoint) {
        let a = Identity::generate().unwrap();
        let b = Identity::generate().unwrap();
        let ap = a.fingerprint();
        let bp = b.fingerprint();
        let mut sender = Endpoint::listen_with_transport_options(
            "127.0.0.1:0".parse().unwrap(),
            "127.0.0.1".parse().unwrap(),
            [1; 32],
            b,
            ap,
            cc,
            max_pacing_rate,
            None,
            true,
        )
        .unwrap();
        // Adversarial fixture may use34 outgoing slots; production stays32.
        sender
            .config
            .as_mut()
            .unwrap()
            .enable_dgram(true, 32, sender_capacity);
        let mut receiver = Endpoint::connect_with_congestion_control(
            "127.0.0.1:0".parse().unwrap(),
            sender.local_addr().unwrap(),
            [1; 32],
            a,
            bp,
            cc,
        )
        .unwrap();
        let deadline = Instant::now() + Duration::from_secs(2);
        while !(sender.stats().application_ready && receiver.stats().application_ready) {
            assert!(Instant::now() < deadline);
            sender.poll().unwrap();
            receiver.poll().unwrap();
            std::thread::sleep(Duration::from_millis(1));
        }
        // Drain handshake/ACK work, with no application warmup or queue changes.
        for _ in 0..30 {
            sender.poll().unwrap();
            receiver.poll().unwrap();
            std::thread::sleep(Duration::from_millis(1));
        }
        (sender, receiver)
    }
    fn queue_one_dg_packets(sender: &mut Endpoint, count: u64, start: u64) {
        let sent = sender.stats().datagrams_udp_sent;
        for sequence in start..start + count {
            assert_eq!(
                sender.send(
                    Message {
                        lane: Lane::Datagram,
                        sequence,
                        payload: vec![0x5a],
                    },
                    Instant::now() + Duration::from_secs(1)
                ),
                Admission::Accepted
            );
            sender.poll().unwrap();
        }
        assert_eq!(sender.stats().datagrams_udp_sent - sent, count);
    }
    #[test]
    fn receive_pressure_authenticated_34_one_dg_batch_is_not_evicted() {
        let (mut sender, mut receiver) = ready_pair();
        let before = receiver.connection.as_ref().unwrap().stats().dgram_recv;
        let udp_before = receiver.stats().udp_socket_received;
        queue_one_dg_packets(&mut sender, 34, 0);
        receiver.poll().unwrap();
        let frames = receiver.connection.as_ref().unwrap().stats().dgram_recv - before;
        let mut ids = Vec::new();
        while let Some(record) = receiver.receive() {
            ids.push(record.sequence);
        }
        eprintln!(
            "queued_one_dg=34 decoded_frames={frames} udp_reads={} delivered={} rejected={}",
            receiver.stats().udp_socket_received - udp_before,
            ids.len(),
            receiver.stats().datagrams_rejected
        );
        assert_eq!(
            frames, 34,
            "all authenticated frames must actually reach quiche"
        );
        assert_eq!(ids, (0..34).collect::<Vec<_>>());
        assert_eq!(receiver.stats().datagrams_rejected, 0);
    }
    #[test]
    fn receive_pressure_single_udp_34_frames_reports_eviction_before_decode() {
        let (mut sender, mut receiver) = ready_pair_with_sender_capacity(34);
        let connection = sender.connection.as_mut().unwrap();
        let before = connection.stats().dgram_sent;
        for _ in 0..34 {
            connection.dgram_send_buf(Vec::new()).unwrap();
        }
        let mut packet = [0; UDP_SIZE];
        let (len, info) = connection.send(&mut packet).unwrap();
        assert_eq!(
            connection.stats().dgram_sent - before,
            34,
            "all34 frames must share exactly one real encrypted packet"
        );
        assert_eq!(
            sender
                .socket
                .as_ref()
                .unwrap()
                .send_to(&packet[..len], info.to)
                .unwrap(),
            len
        );
        let arrival = Instant::now() + Duration::from_millis(100);
        loop {
            let mut peek = [0; UDP_SIZE];
            match receiver.socket.as_ref().unwrap().peek_from(&mut peek) {
                Ok(_) => break,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(Instant::now() < arrival);
                    std::thread::sleep(Duration::from_micros(100));
                }
                Err(e) => panic!("{e}"),
            }
        }
        let udp_before = receiver.stats().udp_socket_received;
        let quic_before = receiver.stats().received_udp_packets;
        receiver.poll().unwrap();
        let diag = receiver.diagnostics();
        assert_eq!(diag.received_udp_packets - quic_before, 1);
        eprintln!("single_udp_bytes={len} udp_reads={} decoded={} evicted={} extracted={} retirement={:?}",
            receiver.stats().udp_socket_received - udp_before, diag.quiche_datagrams_decoded,
            diag.quiche_datagrams_evicted, diag.datagrams_extracted, diag.retirement);
        assert_eq!(diag.quiche_datagrams_decoded, 34);
        assert_eq!(diag.quiche_datagrams_evicted, 2);
        assert!(diag.datagram_observation_valid && diag.receive_resource_failure);
        assert_eq!(diag.retirement, Some(Retirement::Protocol));
        assert_eq!(diag.datagrams_extracted, 0);
        assert!(receiver.receive().is_none());
        assert_eq!(diag.quiche_datagrams_pending_records, 32);
        assert_eq!(diag.quiche_datagrams_pending_bytes, 0); // Empty frame bodies.
        assert_eq!(receiver.stats().quiche_datagrams_pending_records, 0);
        assert_eq!(receiver.stats().receive_queue_records, 0);
        assert_eq!(diag.io_errno, 0);
        assert_eq!(diag.tls_failure, tls::VerificationFailure::None);
    }
    #[test]
    fn receive_pressure_boundaries_31_32_33_64_keep_exact_records() {
        for count in [31, 32, 33, 64] {
            let (mut sender, mut receiver) = ready_pair();
            queue_one_dg_packets(&mut sender, count, 0);
            receiver.poll().unwrap();
            let before = receiver.stats();
            assert_eq!(before.quiche_datagrams_decoded, count);
            assert_eq!(before.datagrams_extracted, count);
            assert_eq!(before.receive_queue_records, count as usize);
            assert_eq!(
                before.receive_queue_bytes,
                count as usize * (wire::HEADER + 5)
            );
            assert_eq!(before.quiche_datagrams_evicted, 0);
            assert!(before.datagram_observation_valid);
            let mut ids = Vec::new();
            while let Some(record) = receiver.receive() {
                ids.push(record.sequence);
            }
            assert_eq!(ids, (0..count).collect::<Vec<_>>());
            receiver.close();
            assert_eq!(receiver.diagnostics().datagrams_extracted, count);
            assert_eq!(receiver.stats().receive_queue_bytes, 0);
            assert_eq!(receiver.stats().quiche_datagrams_pending_bytes, 0);
        }
    }
    #[test]
    fn receive_pressure_full_wrapper_retains_pending_and_reliable_across_polls() {
        let (mut sender, mut receiver) = ready_pair();
        queue_one_dg_packets(&mut sender, 64, 0);
        receiver.poll().unwrap();
        assert_eq!(receiver.stats().receive_queue_records, 64);
        assert_eq!(
            sender.send(
                Message {
                    lane: Lane::Reliable,
                    sequence: 999,
                    payload: vec![7]
                },
                Instant::now()
            ),
            Admission::Accepted
        );
        queue_one_dg_packets(&mut sender, 3, 64);
        receiver.poll().unwrap();
        let held = receiver.stats();
        assert_eq!(held.receive_queue_records, 64);
        assert_eq!(held.quiche_datagrams_pending_records, 1);
        assert_eq!(held.quiche_datagrams_pending_bytes, wire::HEADER + 1);
        assert_eq!(held.datagrams_extracted, 64);
        for _ in 0..3 {
            receiver.poll().unwrap();
        }
        assert_eq!(
            receiver.stats().udp_socket_received,
            held.udp_socket_received,
            "no intake while a complete DG remains blocked in quiche"
        );
        assert!(receiver.next_wakeup() > Duration::ZERO);
        let mut seen = Vec::new();
        while let Some(record) = receiver.receive() {
            seen.push((record.lane, record.sequence));
        }
        for _ in 0..4 {
            receiver.poll().unwrap();
            sender.poll().unwrap();
            while let Some(record) = receiver.receive() {
                seen.push((record.lane, record.sequence));
            }
        }
        let ids: Vec<_> = seen
            .iter()
            .filter(|(lane, _)| *lane == Lane::Datagram)
            .map(|(_, id)| *id)
            .collect();
        assert_eq!(ids, (0..67).collect::<Vec<_>>());
        assert_eq!(
            seen.iter()
                .filter(|(lane, id)| *lane == Lane::Reliable && *id == 999)
                .count(),
            1
        );
        assert_eq!(receiver.stats().quiche_datagrams_decoded, 67);
        assert_eq!(receiver.stats().datagrams_extracted, 67);
        assert_eq!(receiver.stats().quiche_datagrams_evicted, 0);
        assert_eq!(receiver.stats().quiche_datagrams_pending_records, 0);
    }
    #[test]
    fn receive_pressure_byte_limit_retains_whole_datagram_without_discard() {
        let (mut sender, mut receiver) = ready_pair();
        // Real receives fill60*1075=64500 wrapper bytes. Each packet is drained
        // between sender turns; only app consumption is withheld.
        for sequence in 0..61 {
            assert_eq!(
                sender.send(
                    Message {
                        lane: Lane::Datagram,
                        sequence,
                        payload: vec![9; 1024]
                    },
                    Instant::now() + Duration::from_secs(1)
                ),
                Admission::Accepted
            );
            sender.poll().unwrap();
            std::thread::sleep(Duration::from_millis(1));
            receiver.poll().unwrap();
        }
        let held = receiver.stats();
        assert_eq!(held.quiche_datagrams_decoded, 61);
        assert_eq!(held.datagrams_extracted, 60);
        assert_eq!(held.receive_queue_records, 60);
        assert_eq!(held.receive_queue_bytes, 64500);
        assert_eq!(held.quiche_datagrams_pending_records, 1);
        assert_eq!(held.quiche_datagrams_pending_bytes, 1071);
        receiver.poll().unwrap();
        assert_eq!(
            receiver.stats().udp_socket_received,
            held.udp_socket_received
        );
        assert_eq!(receiver.receive().unwrap().sequence, 0);
        receiver.poll().unwrap();
        let ids: Vec<_> = std::iter::from_fn(|| receiver.receive())
            .map(|r| r.sequence)
            .collect();
        assert_eq!(ids, (1..61).collect::<Vec<_>>());
        assert_eq!(receiver.stats().datagrams_extracted, 61);
        assert_eq!(receiver.stats().quiche_datagrams_evicted, 0);
        assert_eq!(receiver.stats().datagrams_rejected, 0);
    }
    fn send_frame_packet(sender: &mut Endpoint, receiver: &Endpoint, frames: Vec<Vec<u8>>) {
        let count = frames.len();
        let connection = sender.connection.as_mut().unwrap();
        let before = connection.stats().dgram_sent;
        for frame in frames {
            connection.dgram_send_buf(frame).unwrap();
        }
        let mut packet = [0; UDP_SIZE];
        let (len, info) = connection.send(&mut packet).unwrap();
        assert_eq!(connection.stats().dgram_sent - before, count);
        assert_eq!(
            sender
                .socket
                .as_ref()
                .unwrap()
                .send_to(&packet[..len], info.to)
                .unwrap(),
            len
        );
        let deadline = Instant::now() + Duration::from_millis(100);
        let mut peek = [0; UDP_SIZE];
        while receiver
            .socket
            .as_ref()
            .unwrap()
            .peek_from(&mut peek)
            .is_err()
        {
            assert!(Instant::now() < deadline);
            std::thread::sleep(Duration::from_micros(100));
        }
    }
    #[test]
    fn receive_pressure_valid_multiframe_and_rejected_extraction_have_distinct_units() {
        let (mut sender, mut receiver) = ready_pair();
        let frames = (0..2)
            .map(|sequence| {
                wire::encode(
                    &[1; 32],
                    &Message {
                        lane: Lane::Datagram,
                        sequence,
                        payload: vec![4],
                    },
                )
                .unwrap()
            })
            .collect();
        let udp = receiver.stats().udp_socket_received;
        send_frame_packet(&mut sender, &receiver, frames);
        receiver.poll().unwrap();
        assert_eq!(receiver.stats().udp_socket_received - udp, 1);
        assert_eq!(receiver.stats().quiche_datagrams_decoded, 2);
        assert_eq!(receiver.stats().datagrams_extracted, 2);
        assert_eq!(receiver.stats().datagrams_received, 2);
        assert_eq!(receiver.receive().unwrap().sequence, 0);
        assert_eq!(receiver.receive().unwrap().sequence, 1);
        send_frame_packet(&mut sender, &receiver, vec![Vec::new()]);
        receiver.poll().unwrap();
        let diag = receiver.diagnostics();
        assert_eq!(diag.retirement, Some(Retirement::Protocol));
        assert_eq!(diag.quiche_datagrams_decoded, 3);
        assert_eq!(diag.datagrams_extracted, 3);
        assert_eq!(diag.datagrams_received, 2);
        assert_eq!(diag.datagrams_rejected, 1);
        assert_eq!(diag.quiche_datagrams_evicted, 0);
        assert!(diag.datagram_observation_valid && !diag.receive_resource_failure);
        assert!(receiver.receive().is_none());
    }
    #[test]
    fn receive_pressure_unavailable_inconsistent_saturated_observations_fail_visible() {
        let zero = DatagramObservation {
            decoded: 0,
            records: 0,
            bytes: 0,
        };
        for (before, after) in [
            (None, Some(zero)),
            (Some(zero), None),
            (Some(zero), Some(DatagramObservation { records: 1, ..zero })),
            (
                Some(zero),
                Some(DatagramObservation {
                    decoded: usize::MAX,
                    ..zero
                }),
            ),
            (Some(DatagramObservation { decoded: 1, ..zero }), Some(zero)),
            (
                Some(zero),
                Some(DatagramObservation {
                    decoded: 33,
                    records: 33,
                    ..zero
                }),
            ),
            (Some(zero), Some(DatagramObservation { bytes: 1, ..zero })),
        ] {
            let mut endpoint = endpoint();
            assert!(!endpoint.observe_datagram_receive(before, after));
            let diag = endpoint.diagnostics();
            assert!(!diag.datagram_observation_valid);
            assert_eq!(diag.datagram_observation_failures, 1);
            assert!(diag.receive_resource_failure);
            assert_eq!(diag.retirement, Some(Retirement::Protocol));
            assert_eq!(diag.io_errno, 0);
            assert!(endpoint.receive().is_none());
            assert_eq!(endpoint.stats().quiche_datagrams_pending_records, 0);
        }
        assert!(DatagramObservation {
            decoded: usize::MAX - UDP_SIZE,
            ..zero
        }
        .has_receive_headroom());
        assert!(!DatagramObservation {
            decoded: usize::MAX - UDP_SIZE + 1,
            ..zero
        }
        .has_receive_headroom());
    }
    #[test]
    fn receive_pressure_blocked_intake_still_services_deadlines_and_reliable_output() {
        let (mut sender, mut receiver) = ready_pair();
        queue_one_dg_packets(&mut sender, 64, 0);
        receiver.poll().unwrap();
        queue_one_dg_packets(&mut sender, 1, 64);
        let arrival = Instant::now() + Duration::from_millis(100);
        let mut peek = [0; UDP_SIZE];
        while receiver
            .socket
            .as_ref()
            .unwrap()
            .peek_from(&mut peek)
            .is_err()
        {
            assert!(Instant::now() < arrival);
            std::thread::sleep(Duration::from_micros(100));
        }
        receiver.poll().unwrap();
        assert_eq!(receiver.stats().quiche_datagrams_pending_records, 1);
        let udp = receiver.stats().udp_socket_received;
        assert_eq!(
            receiver.send(
                Message {
                    lane: Lane::Reliable,
                    sequence: 900,
                    payload: vec![5]
                },
                Instant::now()
            ),
            Admission::Accepted
        );
        receiver.datagrams.push_back(Datagram {
            bytes: vec![1],
            deadline: Instant::now() - Duration::from_nanos(1),
            sequence: 1,
        });
        let until = Instant::now() + Duration::from_millis(100);
        let mut output = None;
        while output.is_none() {
            assert!(Instant::now() < until);
            receiver.poll().unwrap();
            sender.poll().unwrap();
            output = sender.receive();
            std::thread::sleep(Duration::from_micros(100));
        }
        assert_eq!(output.unwrap().sequence, 900);
        assert_eq!(receiver.stats().udp_socket_received, udp);
        assert_eq!(receiver.stats().expired, 1);
        assert!(receiver.stats().reliable_backlog_bytes > 0); // ACK is blocked, not invented.
        receiver.reliable_progress = Instant::now() - TIMEOUT;
        receiver.poll().unwrap();
        let diag = receiver.diagnostics();
        assert_eq!(diag.retirement, Some(Retirement::ReliableStall));
        assert_eq!(diag.quiche_datagrams_pending_records, 1);
        assert_eq!(diag.quiche_datagrams_decoded, 65);
        assert_eq!(diag.datagrams_extracted, 64);
        assert_eq!(receiver.stats().quiche_datagrams_pending_records, 0);
        assert_eq!(receiver.stats().receive_queue_records, 0);
        assert_eq!(receiver.stats().receive_queue_bytes, 0);
        assert_eq!(receiver.stats().reliable_backlog_bytes, 0);
    }
    fn endpoint() -> Endpoint {
        Endpoint::listen(
            "127.0.0.1:0".parse().unwrap(),
            "127.0.0.1".parse().unwrap(),
            [1; 32],
            Identity::generate().unwrap(),
            [2; 32],
        )
        .unwrap()
    }
    #[test]
    fn acknowledged_allocation_before_next_send_is_progress_not_stall() {
        let mut endpoint = endpoint();
        endpoint.stats.application_ready = true;
        let first = Buffer::new(vec![0; 100], Some(endpoint.reliable_charge.clone()));
        let remaining = Buffer::new(vec![0; 100], Some(endpoint.reliable_charge.clone()));
        endpoint.last_reliable_charge = 200;
        endpoint.reliable_progress = Instant::now() - Duration::from_secs(6);
        drop(first);
        assert_eq!(
            endpoint.send(
                Message {
                    lane: Lane::Reliable,
                    sequence: 1,
                    payload: vec![1]
                },
                Instant::now()
            ),
            Admission::Accepted
        );
        endpoint.poll().unwrap();
        assert!(
            !endpoint.stats().retired,
            "a completed allocation must reset stall timer even when send precedes poll"
        );
        drop(remaining);
    }
    #[test]
    fn paced_packets_expire_without_waiting_for_send_time() {
        let mut endpoint = endpoint();
        let now = Instant::now();
        for sequence in 0..32 {
            endpoint.generated.push_back(Packet {
                generated_at: now,
                bytes: [0; 1200],
                len: 1200,
                at: now + Duration::from_secs(1),
                expires: Some(now + Duration::from_millis(5)),
                datagram_sequence: Some(sequence),
            });
        }
        endpoint.flush_packets(now).unwrap();
        assert_eq!(endpoint.stats().generated_packets, 32);
        assert_eq!(endpoint.stats().sent_udp_packets, 0);
        endpoint
            .flush_packets(now + Duration::from_millis(5))
            .unwrap();
        assert_eq!(endpoint.stats().generated_packets, 0);
        assert_eq!(endpoint.stats().expired, 32);
        assert_eq!(endpoint.stats().sent_udp_packets, 0);
        let expiries = std::iter::from_fn(|| endpoint.take_datagram_expiry()).collect::<Vec<_>>();
        assert_eq!(expiries.len(), 32);
        assert!(expiries.iter().enumerate().all(|(sequence, expiry)| {
            *expiry
                == (DatagramExpiry {
                    sequence: sequence as u64,
                    stage: DatagramExpiryStage::Generated,
                })
        }));
    }
    #[test]
    fn discard_datagrams_is_selective_without_falsifying_expiry() {
        let mut endpoint = endpoint();
        let now = Instant::now();
        for sequence in [1, 2] {
            endpoint.datagrams.push_back(Datagram {
                bytes: vec![sequence as u8],
                deadline: now + Duration::from_secs(1),
                sequence,
            });
        }
        endpoint.quiche_datagram_deadline = Some(now + Duration::from_secs(1));
        endpoint.quiche_datagram_sequence = Some(3);
        for sequence in [4, 5] {
            endpoint.generated.push_back(Packet {
                generated_at: now,
                bytes: [sequence as u8; UDP_SIZE],
                len: 1,
                at: now,
                expires: Some(now + Duration::from_secs(1)),
                datagram_sequence: Some(sequence),
            });
        }

        endpoint.discard_datagrams(|sequence| sequence % 2 == 0);

        assert_eq!(
            endpoint
                .datagrams
                .iter()
                .map(|datagram| datagram.sequence)
                .collect::<Vec<_>>(),
            vec![1]
        );
        assert_eq!(endpoint.quiche_datagram_sequence, Some(3));
        assert_eq!(
            endpoint
                .generated
                .iter()
                .filter_map(|packet| packet.datagram_sequence)
                .collect::<Vec<_>>(),
            vec![5]
        );
        assert_eq!(endpoint.take_datagram_expiry(), None);
        assert_eq!(endpoint.stats().expired, 0);
    }
    #[test]
    fn recovery_preempts_only_the_quiche_datagram_that_could_mix() {
        let mut endpoint = endpoint();
        endpoint.stats.application_ready = true;
        let now = Instant::now();
        endpoint.datagrams.push_back(Datagram {
            bytes: vec![1],
            deadline: now + Duration::from_secs(1),
            sequence: 11,
        });
        endpoint.quiche_datagram_deadline = Some(now + Duration::from_secs(1));
        endpoint.quiche_datagram_sequence = Some(12);
        endpoint.generated.push_back(Packet {
            generated_at: now,
            bytes: [3; UDP_SIZE],
            len: 1,
            at: now,
            expires: Some(now + Duration::from_secs(1)),
            datagram_sequence: Some(13),
        });
        endpoint.generated.push_back(Packet {
            generated_at: now,
            bytes: [4; UDP_SIZE],
            len: 1,
            at: now,
            expires: None,
            datagram_sequence: None,
        });

        endpoint.prioritize_reliable_generation();
        assert_eq!(
            endpoint.send(
                Message {
                    lane: Lane::Reliable,
                    sequence: 20,
                    payload: vec![5],
                },
                now,
            ),
            Admission::Accepted
        );

        assert_eq!(
            endpoint
                .datagrams
                .iter()
                .map(|datagram| datagram.sequence)
                .collect::<Vec<_>>(),
            vec![11]
        );
        assert_eq!(endpoint.quiche_datagram_deadline, None);
        assert_eq!(endpoint.quiche_datagram_sequence, None);
        assert_eq!(endpoint.generated.len(), 2);
        assert_eq!(
            endpoint.generated.front().unwrap().datagram_sequence,
            Some(13)
        );
        assert_eq!(endpoint.stats().expired, 0);
        assert_eq!(endpoint.stats().pressure.expiry_queued, 0);
        assert_eq!(endpoint.stats().pressure.expiry_generated, 0);
        assert_eq!(endpoint.take_datagram_expiry(), None);
    }
    #[test]
    fn datagrams_resume_after_clean_reliable_generation_on_same_endpoint() {
        let (mut sender, mut receiver) = ready_pair();
        let datagrams_before = sender.stats().datagrams_generated;
        sender.prioritize_reliable_generation();
        assert_eq!(
            sender.send(
                Message {
                    lane: Lane::Reliable,
                    sequence: 900,
                    payload: vec![7; 1024],
                },
                Instant::now(),
            ),
            Admission::Accepted
        );
        assert_eq!(
            sender.send(
                Message {
                    lane: Lane::Datagram,
                    sequence: 901,
                    payload: vec![8],
                },
                Instant::now() + Duration::from_secs(2),
            ),
            Admission::Accepted
        );

        sender.poll().unwrap();
        assert_eq!(sender.datagrams.len(), 1);
        assert_eq!(sender.quiche_datagram_sequence, None);
        assert_eq!(sender.stats().datagrams_generated, datagrams_before);
        assert!(!sender.prioritize_reliable);

        let deadline = Instant::now() + Duration::from_secs(2);
        let mut received = Vec::new();
        while received.len() < 2 {
            assert!(Instant::now() < deadline);
            sender.poll().unwrap();
            receiver.poll().unwrap();
            while let Some(record) = receiver.receive() {
                received.push((record.lane, record.sequence));
            }
            std::thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(received, vec![(Lane::Reliable, 900), (Lane::Datagram, 901)]);
        assert_eq!(sender.stats().datagrams_generated, datagrams_before + 1);
        assert!(!sender.stats().retired && !receiver.stats().retired);
    }
    #[test]
    fn queued_deadlines_use_exact_monotonic_boundary() {
        let mut endpoint = endpoint();
        let now = Instant::now();
        endpoint.datagrams.push_back(Datagram {
            bytes: vec![0; 1071],
            deadline: now,
            sequence: 41,
        });
        endpoint.datagrams.push_back(Datagram {
            bytes: vec![0; 1071],
            deadline: now + Duration::from_nanos(1),
            sequence: 42,
        });
        endpoint.expire_datagrams(now);
        assert_eq!(endpoint.stats().datagram_queue_records, 1);
        assert_eq!(endpoint.stats().expired, 1);
        assert_eq!(
            endpoint.take_datagram_expiry(),
            Some(DatagramExpiry {
                sequence: 41,
                stage: DatagramExpiryStage::Queued,
            })
        );
        endpoint.expire_datagrams(now + Duration::from_nanos(1));
        assert_eq!(endpoint.stats().datagram_queue_records, 0);
        assert_eq!(endpoint.stats().expired, 2);
        assert_eq!(
            endpoint.take_datagram_expiry(),
            Some(DatagramExpiry {
                sequence: 42,
                stage: DatagramExpiryStage::Queued,
            })
        );
        assert_eq!(endpoint.take_datagram_expiry(), None);
    }
    #[test]
    fn v4_socket_disables_ip_fragmentation() {
        use std::os::fd::AsRawFd;
        let endpoint = endpoint();
        let fd = endpoint.socket.as_ref().unwrap().as_raw_fd();
        #[cfg(target_os = "macos")]
        let option = libc::IP_DONTFRAG;
        #[cfg(target_os = "android")]
        let option = libc::IP_MTU_DISCOVER;
        let mut value: libc::c_int = 0;
        let mut length = std::mem::size_of_val(&value) as libc::socklen_t;
        // SAFETY: live UDP descriptor and correctly sized output pointers.
        assert_eq!(
            unsafe {
                libc::getsockopt(
                    fd,
                    libc::IPPROTO_IP,
                    option,
                    (&mut value as *mut libc::c_int).cast(),
                    &mut length,
                )
            },
            0
        );
        #[cfg(target_os = "macos")]
        assert_eq!(value, 1);
        #[cfg(target_os = "android")]
        assert_eq!(value, libc::IP_PMTUDISC_DO);
    }
    #[test]
    fn v4_socket_applies_exact_dscp_without_ecn_bits() {
        use std::os::fd::AsRawFd;
        let mut endpoint = endpoint();
        assert!(matches!(
            endpoint.set_dscp(64),
            Err(Error::InvalidConfiguration)
        ));
        endpoint.set_dscp(46).unwrap();
        let fd = endpoint.socket.as_ref().unwrap().as_raw_fd();
        let mut value: libc::c_int = 0;
        let mut length = std::mem::size_of_val(&value) as libc::socklen_t;
        // SAFETY: live UDP descriptor and correctly sized output pointers.
        assert_eq!(
            unsafe {
                libc::getsockopt(
                    fd,
                    libc::IPPROTO_IP,
                    libc::IP_TOS,
                    (&mut value as *mut libc::c_int).cast(),
                    &mut length,
                )
            },
            0
        );
        assert_eq!(value, 46 << 2);
    }
    #[test]
    fn connect_deadline_is_owned_and_not_reset_by_polling() {
        let mut endpoint = endpoint();
        endpoint.created = Instant::now() - TIMEOUT;
        endpoint.poll().unwrap();
        assert_eq!(
            endpoint.stats().retirement,
            Some(Retirement::ConnectTimeout)
        );
        assert_eq!(endpoint.stats().received_udp_packets, 0);
    }
    #[test]
    fn packet_expiring_between_two_udp_sends_is_never_transmitted() {
        let mut endpoint = endpoint();
        let receiver = UdpSocket::bind("127.0.0.1:0").unwrap();
        receiver
            .set_read_timeout(Some(Duration::from_millis(100)))
            .unwrap();
        endpoint.peer = Some(receiver.local_addr().unwrap());
        let started = Instant::now();
        let clock = std::cell::Cell::new(started);
        for (byte, budget) in [(1, Duration::from_secs(1)), (2, Duration::from_millis(5))] {
            endpoint.generated.push_back(Packet {
                generated_at: started,
                bytes: [byte; UDP_SIZE],
                len: 1,
                at: started,
                expires: Some(started + budget),
                datagram_sequence: None,
            });
        }
        let mut sends = 0;
        endpoint
            .flush_packets_with(
                started,
                || clock.get(),
                |socket, bytes, peer| {
                    let sent = socket.send_to(bytes, peer);
                    sends += 1;
                    // Simulate descheduling/elapsed syscall time after the first real
                    // UDP send. The second packet expires during this SAME flush.
                    clock.set(started + Duration::from_millis(5));
                    sent
                },
            )
            .unwrap();
        assert_eq!(sends, 1, "expired second packet must not reach send_to");
        assert_eq!(endpoint.stats().expired, 1);
        assert_eq!(endpoint.stats().sent_udp_packets, 1);
        assert_eq!(endpoint.stats().generated_packets, 0);
        let mut bytes = [0; UDP_SIZE];
        let (count, _) = receiver.recv_from(&mut bytes).unwrap();
        assert_eq!(&bytes[..count], &[1]);
        receiver.set_nonblocking(true).unwrap();
        assert_eq!(
            receiver.recv_from(&mut bytes).unwrap_err().kind(),
            std::io::ErrorKind::WouldBlock
        );
    }
}
