pub mod diagnostics;
use crate::{CertificateFingerprint, InvalidRecord, SessionId};
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};
pub const MAX_BODY: usize = 4096;
#[derive(Debug, PartialEq, Eq)]
pub struct Request {
    pub session: SessionId,
    pub fingerprint: CertificateFingerprint,
    pub expected_ip: IpAddr,
}
#[derive(Debug, PartialEq, Eq)]
pub struct Reply {
    pub session: SessionId,
    pub fingerprint: CertificateFingerprint,
    pub port: u16,
}
impl Request {
    pub fn encode(&self) -> Result<Vec<u8>, InvalidRecord> {
        validate_ip(self.expected_ip)?;
        let mut body = common(&self.session, &self.fingerprint);
        match self.expected_ip {
            IpAddr::V4(ip) => {
                body.push(4);
                body.extend_from_slice(&ip.octets());
            }
            IpAddr::V6(ip) => {
                body.push(6);
                body.extend_from_slice(&ip.octets());
            }
        }
        Ok(frame(body))
    }
    pub fn decode(bytes: &[u8]) -> Result<Self, InvalidRecord> {
        let body = unframe(bytes)?;
        let expected_ip = match (body.len(), body.get(65)) {
            (70, Some(4)) => IpAddr::V4(Ipv4Addr::from(
                <[u8; 4]>::try_from(&body[66..]).map_err(|_| InvalidRecord)?,
            )),
            (82, Some(6)) => IpAddr::V6(Ipv6Addr::from(
                <[u8; 16]>::try_from(&body[66..]).map_err(|_| InvalidRecord)?,
            )),
            _ => return Err(InvalidRecord),
        };
        validate_ip(expected_ip)?;
        Ok(Self {
            session: body[1..33].try_into().map_err(|_| InvalidRecord)?,
            fingerprint: body[33..65].try_into().map_err(|_| InvalidRecord)?,
            expected_ip,
        })
    }
}
impl Reply {
    pub fn encode(&self) -> Result<Vec<u8>, InvalidRecord> {
        if self.port == 0 {
            return Err(InvalidRecord);
        }
        let mut body = common(&self.session, &self.fingerprint);
        body.extend_from_slice(&self.port.to_be_bytes());
        Ok(frame(body))
    }
    pub fn decode(bytes: &[u8], expected: &SessionId) -> Result<Self, InvalidRecord> {
        let body = unframe(bytes)?;
        if body.len() != 67 || &body[1..33] != expected {
            return Err(InvalidRecord);
        }
        let port = u16::from_be_bytes([body[65], body[66]]);
        if port == 0 {
            return Err(InvalidRecord);
        }
        Ok(Self {
            session: *expected,
            fingerprint: body[33..65].try_into().map_err(|_| InvalidRecord)?,
            port,
        })
    }
}

fn common(session: &SessionId, fingerprint: &CertificateFingerprint) -> Vec<u8> {
    let mut body = Vec::with_capacity(82);
    body.push(1);
    body.extend_from_slice(session);
    body.extend_from_slice(fingerprint);
    body
}
fn frame(body: Vec<u8>) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(body.len() + 4);
    bytes.extend_from_slice(&(body.len() as u32).to_be_bytes());
    bytes.extend_from_slice(&body);
    bytes
}
fn unframe(bytes: &[u8]) -> Result<&[u8], InvalidRecord> {
    if bytes.len() < 5 {
        return Err(InvalidRecord);
    }
    let length = u32::from_be_bytes(bytes[..4].try_into().map_err(|_| InvalidRecord)?) as usize;
    if length > MAX_BODY || bytes.len() != length + 4 || bytes[4] != 1 {
        return Err(InvalidRecord);
    }
    Ok(&bytes[4..])
}
fn validate_ip(ip: IpAddr) -> Result<(), InvalidRecord> {
    if ip.is_unspecified() || ip.is_multicast() || ip == IpAddr::V4(Ipv4Addr::BROADCAST) {
        return Err(InvalidRecord);
    }
    Ok(())
}

/// The caller supplies one explicitly authorized, non-PTY child command with
/// binary-safe separated stdin/stdout/stderr. Never put attempt credentials in
/// program/args. No discovery, shell interpolation, or pairing happens here.
pub struct ClientOptions {
    pub program: std::path::PathBuf,
    pub args: Vec<std::ffi::OsString>,
    pub peer_ip: IpAddr,
    pub local_ip: IpAddr,
    pub duration: std::time::Duration,
}
#[derive(Clone, Copy, Debug, Default)]
pub struct ClientReport {
    pub terminal: ClientDiagnostic,
    pub requested_duration_ms: u64,
    pub elapsed_ms: u64,
    pub datagrams_sent: u64,
    pub datagrams_received: u64,
    pub reliable_sent: u64,
    pub reliable_received: u64,
    pub duplicates: u64,
    pub timeouts: u64,
    pub cleanup: bool,
    pub cleanup_forced: bool,
    pub datagram_active_peak: usize,
    pub datagram_credit_expired: u64,
    pub datagram_credit_blocked: u64,
    pub datagram_backpressured: u64,
    pub reliable_credit_blocked: u64,
    pub reliable_backpressured: u64,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ClientOrigin {
    #[default]
    None,
    Configuration,
    Spawn,
    Bootstrap,
    Constructor,
    StdoutEvent,
    Poll,
    EndpointRetired,
    ConnectDeadline,
    ChildExit,
    InvalidReply,
    Admission,
    FinalMissing,
    FinalDuplicate,
    Completed,
    Cleanup,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum ErrorKind {
    #[default]
    None,
    InvalidConfiguration,
    Identity,
    Transport,
    Io,
}
#[derive(Clone, Copy, Debug, Default)]
pub struct ClientDiagnostic {
    pub owner_timing: diagnostics::OwnerSummary,
    pub origin: ClientOrigin,
    // Includes the endpoint's checked DG receive-conservation scalars and
    // pre-retirement pending balances; these are not delivery acknowledgments.
    pub endpoint: crate::Stats,
    pub error: ErrorKind,
    pub errno: i32,
}
impl ClientDiagnostic {
    fn record_error(&mut self, error: &crate::Error) {
        self.error = match error {
            crate::Error::InvalidConfiguration => ErrorKind::InvalidConfiguration,
            crate::Error::Identity => ErrorKind::Identity,
            crate::Error::Transport => ErrorKind::Transport,
            crate::Error::Io(error) => {
                self.errno = error.raw_os_error().unwrap_or(0);
                ErrorKind::Io
            }
        };
    }
}
impl ClientReport {
    pub fn datagram_loss(&self) -> u64 {
        self.datagrams_sent.saturating_sub(self.datagrams_received)
    }
    pub fn reliable_loss(&self) -> u64 {
        self.reliable_sent.saturating_sub(self.reliable_received)
    }
    pub fn lanes_completed(&self) -> u8 {
        u8::from(self.datagrams_received > 0) + u8::from(self.reliable_received > 0)
    }
}
#[derive(Clone, Copy, Debug)]
pub enum ClientStage {
    Configuration,
    Spawn,
    Bootstrap,
    Connect,
    Probe,
    Cleanup,
}
#[derive(Clone, Copy, Debug)]
pub struct ClientFailure {
    pub stage: ClientStage,
    pub report: ClientReport,
}

/// Bounded synthetic dual-lane G0 probe against the exact owned stdio child.
/// The return value contains only scalars; keys, pins, nonce and payloads never
/// enter diagnostic errors. Every return closes stdin and reaps the child.
pub fn run_stdio_client(options: ClientOptions) -> Result<ClientReport, ClientFailure> {
    run_stdio_client_with_identity(options, crate::tls::Identity::generate)
}
fn run_stdio_client_with_identity(
    options: ClientOptions,
    identity: impl FnOnce() -> Result<crate::tls::Identity, crate::Error>,
) -> Result<ClientReport, ClientFailure> {
    run_owned_client(options, identity, Workload::Echo, &mut None)
}
#[derive(Clone, Copy)]
enum Workload {
    Echo,
    Rate(crate::rate_probe::RateShape),
}

/// Fixed fifteen-second synthetic workload, sharing the ordinary client's
/// exact child, trust bootstrap, connect watchdog and bounded cleanup owner.
pub fn run_stdio_rate_client(
    options: ClientOptions,
    shape: crate::rate_probe::RateShape,
) -> Result<crate::rate_probe::RateReport, crate::rate_probe::RateFailure> {
    run_rate_with_identity(options, shape, crate::tls::Identity::generate)
}
fn run_rate_with_identity(
    options: ClientOptions,
    shape: crate::rate_probe::RateShape,
    identity: impl FnOnce() -> Result<crate::tls::Identity, crate::Error>,
) -> Result<crate::rate_probe::RateReport, crate::rate_probe::RateFailure> {
    use crate::rate_probe::{RateFailure, RateReport, RateVerdict};
    let mut rate = None;
    let outcome = run_owned_client(options, identity, Workload::Rate(shape), &mut rate);
    let (lifecycle, stage) = match outcome {
        Ok(report) => (report, None),
        Err(f) => (f.report, Some(f.stage)),
    };
    let mut report = rate.unwrap_or_else(|| RateReport::new(shape));
    report.terminal = lifecycle.terminal;
    report.cleanup = lifecycle.cleanup;
    report.cleanup_forced = lifecycle.cleanup_forced;
    report.elapsed_ms = lifecycle.elapsed_ms;
    report.flags.transport |= stage.is_some();
    report.conclude();
    if report.verdict == RateVerdict::Pass {
        Ok(report)
    } else {
        Err(RateFailure {
            stage: stage.unwrap_or(ClientStage::Probe),
            report,
        })
    }
}
fn run_owned_client(
    options: ClientOptions,
    identity: impl FnOnce() -> Result<crate::tls::Identity, crate::Error>,
    workload: Workload,
    rate: &mut Option<crate::rate_probe::RateReport>,
) -> Result<ClientReport, ClientFailure> {
    use std::{
        process::{Command, Stdio},
        time::{Duration, Instant},
    };
    let started = Instant::now();
    let mut report = ClientReport {
        requested_duration_ms: options.duration.as_millis().min(u64::MAX as u128) as u64,
        ..ClientReport::default()
    };
    if options.duration < Duration::from_millis(1)
        || options.duration > Duration::from_secs(15)
        || (matches!(workload, Workload::Rate(_)) && options.duration != Duration::from_secs(15))
        || options.program.as_os_str().is_empty()
        || options.peer_ip.is_ipv4() != options.local_ip.is_ipv4()
        || validate_ip(options.peer_ip).is_err()
        || validate_ip(options.local_ip).is_err()
    {
        report.terminal.origin = ClientOrigin::Configuration;
        return Err(ClientFailure {
            stage: ClientStage::Configuration,
            report,
        });
    }
    report.terminal.origin = ClientOrigin::Spawn;
    let child = Command::new(&options.program)
        .args(&options.args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::inherit())
        .spawn()
        .map_err(|_| ClientFailure {
            stage: ClientStage::Spawn,
            report,
        })?;
    let mut owned = OwnedChild(Some(child));
    let outcome = drive_child(
        &options,
        owned.0.as_mut().unwrap(),
        &mut report,
        identity,
        workload,
        rate,
    );
    let (clean, forced) = owned.retire();
    report.cleanup = clean;
    report.cleanup_forced = forced;
    report.elapsed_ms = started.elapsed().as_millis().min(u64::MAX as u128) as u64;
    match outcome {
        Err(stage) => Err(ClientFailure { stage, report }),
        Ok(()) if !clean || forced => {
            report.terminal.origin = ClientOrigin::Cleanup;
            Err(ClientFailure {
                stage: ClientStage::Cleanup,
                report,
            })
        }
        Ok(()) => Ok(report),
    }
}
struct OwnedChild(Option<std::process::Child>);
impl OwnedChild {
    fn retire(&mut self) -> (bool, bool) {
        use std::{
            thread,
            time::{Duration, Instant},
        };
        let Some(mut child) = self.0.take() else {
            return (true, false);
        };
        drop(child.stdin.take());
        let end = Instant::now() + Duration::from_secs(2);
        loop {
            match child.try_wait() {
                Ok(Some(status)) => return (status.success(), false),
                Ok(None) if Instant::now() < end => thread::sleep(Duration::from_millis(5)),
                Ok(None) => break,
                Err(_) => return (false, false),
            }
        }
        // Only this still-owned, unreaped child is addressed. No name/pid
        // search or global daemon/session cleanup is performed.
        let killed = child.kill().is_ok();
        let reaped = child.wait().is_ok();
        (killed && reaped, true)
    }
}
impl Drop for OwnedChild {
    fn drop(&mut self) {
        self.retire();
    }
}

fn pipe_io(
    fd: libc::c_int,
    bytes: &mut [u8],
    write: bool,
    deadline: std::time::Instant,
) -> Result<(), ()> {
    use std::{io, time::Instant};
    let mut offset = 0;
    while offset < bytes.len() {
        let now = Instant::now();
        if now >= deadline {
            return Err(());
        }
        let mut pfd = libc::pollfd {
            fd,
            events: if write { libc::POLLOUT } else { libc::POLLIN },
            revents: 0,
        };
        // SAFETY: a single initialized pollfd and valid borrowed child pipe.
        let ready = unsafe {
            libc::poll(
                &mut pfd,
                1,
                deadline.duration_since(now).as_millis().clamp(1, 20) as i32,
            )
        };
        if ready < 0 {
            if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(());
        }
        if ready == 0 {
            continue;
        }
        if pfd.revents & (libc::POLLERR | libc::POLLNVAL) != 0 {
            return Err(());
        }
        // SAFETY: the remaining slice is valid for exactly its specified size;
        // writes are bounded bootstrap records below PIPE_BUF on a fresh pipe.
        let count = unsafe {
            if write {
                libc::write(fd, bytes[offset..].as_ptr().cast(), bytes.len() - offset)
            } else {
                libc::read(
                    fd,
                    bytes[offset..].as_mut_ptr().cast(),
                    bytes.len() - offset,
                )
            }
        };
        if count <= 0 {
            return Err(());
        }
        offset += count as usize;
    }
    Ok(())
}

fn stdout_is_quiet(fd: libc::c_int) -> bool {
    let mut pfd = libc::pollfd {
        fd,
        events: libc::POLLIN,
        revents: 0,
    };
    // SAFETY: initialized pollfd for the live, owned child stdout.
    let ready = unsafe { libc::poll(&mut pfd, 1, 0) };
    // After the one Reply, data, EOF, or a descriptor error is a protocol/
    // lifecycle event. Never read or log unexpected child output.
    ready == 0
}

fn count_endpoint_timeout(
    retirement: Option<crate::endpoint::Retirement>,
    report: &mut ClientReport,
) {
    use crate::endpoint::Retirement;
    if matches!(
        retirement,
        Some(Retirement::ConnectTimeout | Retirement::PeerIdle | Retirement::ReliableStall)
    ) {
        report.timeouts += 1;
    }
}

// Scheduling credit is not proof of delivery. Missing sequences remain in
// ClientReport even after their finite local credit is released.
#[derive(Default)]
struct DatagramCredits {
    slots: [Option<(u64, std::time::Instant)>; 16],
}
impl DatagramCredits {
    fn expire(&mut self, now: std::time::Instant) -> u64 {
        let mut count = 0;
        for slot in &mut self.slots {
            if slot.is_some_and(|(_, deadline)| deadline <= now) {
                *slot = None;
                count += 1;
            }
        }
        count
    }
    fn active(&self) -> usize {
        self.slots.iter().flatten().count()
    }
    fn admit(&mut self, sequence: u64, deadline: std::time::Instant) {
        *self
            .slots
            .iter_mut()
            .find(|slot| slot.is_none())
            .expect("checked credit") = Some((sequence, deadline));
    }
    fn received(&mut self, sequence: u64) {
        if let Some(slot) = self
            .slots
            .iter_mut()
            .find(|slot| slot.is_some_and(|(owned, _)| owned == sequence))
        {
            *slot = None;
        }
    }
}

struct ProbeSchedule {
    end: std::time::Instant,
    sending_end: std::time::Instant,
    next_send: std::time::Instant,
}
impl ProbeSchedule {
    fn new(start: std::time::Instant, duration: std::time::Duration) -> Self {
        let end = start + duration;
        Self {
            end,
            sending_end: end - duration.min(std::time::Duration::from_millis(400)) / 2,
            next_send: start,
        }
    }
    fn running(&self, now: std::time::Instant) -> bool {
        now < self.end
    }
    fn sending(&mut self, now: std::time::Instant) -> bool {
        if now >= self.next_send && now < self.sending_end {
            self.next_send = now + std::time::Duration::from_millis(20);
            true
        } else {
            false
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn issuance_second() -> u64 {
        use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
        let end = Instant::now() + Duration::from_secs(2);
        loop {
            let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap();
            if now.subsec_nanos() < 100_000_000 {
                return now.as_secs();
            }
            assert!(Instant::now() < end, "bounded timestamp selection");
            std::thread::sleep(Duration::from_millis(5));
        }
    }
    fn issuance_driver(offset: i64) -> Result<ClientReport, ClientFailure> {
        use std::time::Duration;
        let probe = std::env::current_exe()
            .unwrap()
            .parent()
            .unwrap()
            .parent()
            .unwrap()
            .join("gb-quic-probe");
        assert!(probe.is_file(), "Cargo-built owned peer is required");
        run_stdio_client_with_identity(
            ClientOptions {
                program: probe,
                args: vec!["--stdio-peer".into()],
                peer_ip: "127.0.0.1".parse().unwrap(),
                local_ip: "127.0.0.1".parse().unwrap(),
                duration: Duration::from_millis(200),
            },
            || {
                let seconds = issuance_second().checked_add_signed(offset).unwrap();
                crate::tls::Identity::generate_at(seconds)
            },
        )
    }
    #[test]
    fn issuance_one_second_ahead_and_behind_passes_real_owned_driver() {
        for offset in [1, -1] {
            let result = issuance_driver(offset);
            assert!(
                result.is_ok(),
                "one-second issuer offset must authenticate: {result:?}"
            );
            let report = result.unwrap();
            assert_eq!(report.terminal.origin, ClientOrigin::Completed);
            assert!(report.terminal.endpoint.reached_tls && report.terminal.endpoint.reached_ready);
            assert_eq!(report.lanes_completed(), 2);
            assert_eq!(
                report.datagram_loss()
                    + report.reliable_loss()
                    + report.duplicates
                    + report.timeouts,
                0
            );
            assert!(report.cleanup && !report.cleanup_forced);
        }
    }
    #[test]
    fn issuance_outside_window_still_fails_real_owned_driver() {
        for offset in [180, -3540] {
            let report = issuance_driver(offset).unwrap_err().report;
            assert_eq!(report.lanes_completed(), 0);
            assert_eq!(report.datagrams_sent + report.reliable_sent, 0);
            assert_eq!(report.timeouts, 0);
            assert!(!report.cleanup_forced);
        }
    }
    #[test]
    fn probe_schedule_preserves_pacing_and_exact_final_drain_boundary() {
        use std::time::{Duration, Instant};
        let start = Instant::now();
        let mut schedule = ProbeSchedule::new(start, Duration::from_millis(1000));
        assert!(schedule.sending(start));
        assert!(!schedule.sending(start + Duration::from_millis(19)));
        assert!(schedule.sending(start + Duration::from_millis(20)));
        assert!(schedule.sending(start + Duration::from_millis(799)));
        assert!(!schedule.sending(start + Duration::from_millis(800)));
        assert!(schedule.running(start + Duration::from_millis(999)));
        assert!(!schedule.running(start + Duration::from_millis(1000)));
        let mut tiny = ProbeSchedule::new(start, Duration::from_millis(1));
        assert!(tiny.sending(start));
        assert!(!tiny.sending(start + Duration::from_micros(500)));
        assert!(!tiny.running(start + Duration::from_millis(1)));
    }
    #[test]
    fn expired_credit_late_and_duplicate_echo_cannot_release_a_new_sequence() {
        use std::time::{Duration, Instant};
        let start = Instant::now();
        let mut credits = DatagramCredits::default();
        for sequence in 0..16 {
            credits.admit(sequence, start + Duration::from_millis(200));
        }
        assert_eq!(credits.active(), 16);
        assert_eq!(credits.expire(start + Duration::from_millis(199)), 0);
        assert_eq!(credits.expire(start + Duration::from_millis(200)), 16);
        assert_eq!(credits.active(), 0);
        credits.admit(16, start + Duration::from_millis(400));
        credits.received(0); // old echo after that slot was reused
        credits.received(0); // duplicate old echo
        assert_eq!(credits.active(), 1);
        credits.received(16);
        credits.received(16);
        assert_eq!(credits.active(), 0);
        assert_eq!(credits.expire(start + Duration::from_millis(400)), 0);
    }
    #[test]
    fn endpoint_timeout_reasons_are_counted_without_counting_other_failures() {
        use crate::endpoint::Retirement;
        for (reason, expected) in [
            (Some(Retirement::ConnectTimeout), 1),
            (Some(Retirement::PeerIdle), 1),
            (Some(Retirement::ReliableStall), 1),
            (Some(Retirement::Authentication), 0),
            (Some(Retirement::Protocol), 0),
            (Some(Retirement::Io), 0),
            (Some(Retirement::Closed), 0),
            (None, 0),
        ] {
            let mut report = ClientReport::default();
            count_endpoint_timeout(reason, &mut report);
            assert_eq!(report.timeouts, expected, "retirement {reason:?}");
            for other in [
                Some(Retirement::Authentication),
                Some(Retirement::Protocol),
                Some(Retirement::Io),
                None,
            ] {
                count_endpoint_timeout(other, &mut report);
            }
            assert_eq!(
                report.timeouts, expected,
                "non-deadline failures must not add another timeout"
            );
        }
    }
}
fn drive_child(
    options: &ClientOptions,
    child: &mut std::process::Child,
    report: &mut ClientReport,
    identity: impl FnOnce() -> Result<crate::tls::Identity, crate::Error>,
    workload: Workload,
    rate: &mut Option<crate::rate_probe::RateReport>,
) -> Result<(), ClientStage> {
    use crate::{tls::random_session, Endpoint};
    use std::{
        net::SocketAddr,
        os::fd::AsRawFd,
        time::{Duration, Instant},
    };
    let bootstrap_deadline = Instant::now() + Duration::from_secs(5);
    report.terminal.origin = ClientOrigin::Bootstrap;
    let identity = identity().map_err(|_| ClientStage::Bootstrap)?;
    let session = random_session().map_err(|_| ClientStage::Bootstrap)?;
    let mut request = Request {
        session,
        fingerprint: identity.fingerprint(),
        expected_ip: options.local_ip,
    }
    .encode()
    .map_err(|_| ClientStage::Bootstrap)?;
    pipe_io(
        child.stdin.as_ref().unwrap().as_raw_fd(),
        &mut request,
        true,
        bootstrap_deadline,
    )
    .map_err(|_| {
        if Instant::now() >= bootstrap_deadline {
            report.timeouts += 1;
        }
        ClientStage::Bootstrap
    })?;
    let fd = child.stdout.as_ref().unwrap().as_raw_fd();
    let mut prefix = [0; 4];
    pipe_io(fd, &mut prefix, false, bootstrap_deadline).map_err(|_| {
        if Instant::now() >= bootstrap_deadline {
            report.timeouts += 1;
        }
        ClientStage::Bootstrap
    })?;
    // This version has one exact 67-byte reply; do not allocate a length
    // selected by a child before validating it.
    if u32::from_be_bytes(prefix) != 67 {
        report.terminal.origin = ClientOrigin::InvalidReply;
        return Err(ClientStage::Bootstrap);
    }
    let mut bytes = [0; 71];
    bytes[..4].copy_from_slice(&prefix);
    pipe_io(fd, &mut bytes[4..], false, bootstrap_deadline).map_err(|_| {
        if Instant::now() >= bootstrap_deadline {
            report.timeouts += 1;
        }
        ClientStage::Bootstrap
    })?;
    let reply = Reply::decode(&bytes, &session).map_err(|_| {
        report.terminal.origin = ClientOrigin::InvalidReply;
        ClientStage::Bootstrap
    })?;
    report.terminal.origin = ClientOrigin::Constructor;
    let mut endpoint = Endpoint::connect(
        SocketAddr::new(options.local_ip, 0),
        SocketAddr::new(options.peer_ip, reply.port),
        session,
        identity,
        reply.fingerprint,
    )
    .map_err(|error| {
        report.terminal.record_error(&error);
        ClientStage::Connect
    })?;
    let outcome = probe_endpoint(options, child, report, &mut endpoint, fd, workload, rate);
    report.terminal.endpoint = endpoint.capture_terminal_diagnostics();
    endpoint.close();
    if let Some(rate) = rate {
        let closed = endpoint.stats();
        rate.endpoint_released = closed.retired
            && closed.reliable_backlog_bytes == 0
            && closed.datagram_queue_records == 0
            && closed.generated_packets == 0
            && closed.receive_queue_records == 0
            && closed.receive_queue_bytes == 0
            && closed.quiche_datagrams_pending_records == 0
            && closed.quiche_datagrams_pending_bytes == 0;
    }
    outcome
}
fn probe_endpoint(
    options: &ClientOptions,
    child: &mut std::process::Child,
    report: &mut ClientReport,
    endpoint: &mut crate::Endpoint,
    fd: libc::c_int,
    workload: Workload,
    rate: &mut Option<crate::rate_probe::RateReport>,
) -> Result<(), ClientStage> {
    use std::{
        thread,
        time::{Duration, Instant},
    };
    let connect_end = Instant::now() + Duration::from_secs(5);
    while !endpoint.stats().application_ready {
        if !stdout_is_quiet(fd) {
            report.terminal.origin = ClientOrigin::StdoutEvent;
            return Err(ClientStage::Connect);
        }
        endpoint.poll().map_err(|error| {
            report.terminal.origin = ClientOrigin::Poll;
            report.terminal.record_error(&error);
            ClientStage::Connect
        })?;
        if endpoint.stats().retired {
            report.terminal.origin = ClientOrigin::EndpointRetired;
            count_endpoint_timeout(endpoint.stats().retirement, report);
            return Err(ClientStage::Connect);
        }
        if Instant::now() >= connect_end {
            report.terminal.origin = ClientOrigin::ConnectDeadline;
            report.timeouts += 1;
            return Err(ClientStage::Connect);
        }
        report.terminal.origin = ClientOrigin::ChildExit;
        if child
            .try_wait()
            .map_err(|_| ClientStage::Connect)?
            .is_some()
        {
            return Err(ClientStage::Connect);
        }
        thread::sleep(endpoint.next_wakeup().min(Duration::from_millis(1)));
    }
    let timing = diagnostics::OwnerTiming::default();
    let outcome = probe_active(
        options, child, report, endpoint, fd, workload, rate, &timing,
    );
    report.terminal.owner_timing = timing.snapshot();
    outcome
}
fn probe_active(
    options: &ClientOptions,
    child: &mut std::process::Child,
    report: &mut ClientReport,
    endpoint: &mut crate::Endpoint,
    fd: libc::c_int,
    workload: Workload,
    rate: &mut Option<crate::rate_probe::RateReport>,
    timing: &diagnostics::OwnerTiming,
) -> Result<(), ClientStage> {
    use crate::{Admission, Lane, Message};
    use std::{
        thread,
        time::{Duration, Instant},
    };
    if let Workload::Rate(shape) = workload {
        // Arm accounting before the first authenticated Recipe/GO submission.
        let start = Instant::now();
        let mut client = crate::rate_probe::RateClient::new(shape, start);
        let outcome = (|| {
            while Instant::now() < start + Duration::from_secs(15) {
                timing.turn(Instant::now());
                let Some((now, complete)) = rate_poll_dispatch(
                    endpoint,
                    start + Duration::from_secs(15),
                    Instant::now,
                    |endpoint| {
                        timing.poll(Instant::now, || poll_owned(child, report, endpoint, fd))
                    },
                    |endpoint, now| timing.step(Instant::now, || client.step(endpoint, now)),
                )?
                else {
                    break;
                };
                if complete {
                    report.terminal.origin = if client.is_expired() {
                        ClientOrigin::FinalMissing
                    } else {
                        ClientOrigin::Completed
                    };
                    return Ok(());
                }
                timing.sleep(
                    endpoint.next_wakeup().min(client.wakeup(now)),
                    Instant::now,
                    thread::sleep,
                );
            }
            // Workload boundary is a missing-measurement/deadline result, not
            // evidence that the unreliable transport itself malfunctioned.
            client.expire_exchange();
            report.terminal.origin = ClientOrigin::FinalMissing;
            Ok(())
        })();
        *rate = Some(client.finish());
        return outcome;
    }
    let start = Instant::now();
    let mut schedule = ProbeSchedule::new(start, options.duration);
    let mut seen_datagram = [false; 1024];
    let mut seen_reliable = [false; 1024];
    let mut credits = DatagramCredits::default();
    while schedule.running(Instant::now()) {
        timing.turn(Instant::now());
        report.datagram_credit_expired += credits.expire(Instant::now());
        timing.poll(Instant::now, || poll_owned(child, report, endpoint, fd))?;
        timing.step(Instant::now, || -> Result<(), ClientStage> {
            while let Some(received) = endpoint.receive() {
                let (sent, count, seen) = match received.lane {
                    Lane::Datagram => (
                        report.datagrams_sent,
                        &mut report.datagrams_received,
                        &mut seen_datagram,
                    ),
                    Lane::Reliable => (
                        report.reliable_sent,
                        &mut report.reliable_received,
                        &mut seen_reliable,
                    ),
                };
                if received.sequence >= sent
                    || received.sequence >= seen.len() as u64
                    || received.payload != [0x5a; 32]
                {
                    report.terminal.origin = ClientOrigin::InvalidReply;
                    return Err(ClientStage::Probe);
                }
                if seen[received.sequence as usize] {
                    report.duplicates += 1;
                    continue;
                }
                if received.lane == Lane::Reliable && received.sequence != *count {
                    report.terminal.origin = ClientOrigin::InvalidReply;
                    return Err(ClientStage::Probe);
                }
                seen[received.sequence as usize] = true;
                *count += 1;
                if received.lane == Lane::Datagram {
                    credits.received(received.sequence);
                }
            }
            let now = Instant::now();
            if schedule.sending(now) {
                for lane in [Lane::Datagram, Lane::Reliable] {
                    let (sent, received) = match lane {
                        Lane::Datagram => (&mut report.datagrams_sent, report.datagrams_received),
                        Lane::Reliable => (&mut report.reliable_sent, report.reliable_received),
                    };
                    // Fixed probe workload, at most16 outstanding per lane and
                    // at most750 admitted per lane for the15-second maximum.
                    let blocked = match lane {
                        Lane::Datagram => credits.active() >= 16,
                        Lane::Reliable => *sent - received >= 16,
                    };
                    if blocked {
                        match lane {
                            Lane::Datagram => report.datagram_credit_blocked += 1,
                            Lane::Reliable => report.reliable_credit_blocked += 1,
                        }
                        continue;
                    }
                    if *sent >= seen_datagram.len() as u64 {
                        continue;
                    }
                    match endpoint.send(
                        Message {
                            lane,
                            sequence: *sent,
                            payload: vec![0x5a; 32],
                        },
                        now + Duration::from_millis(200),
                    ) {
                        Admission::Accepted => {
                            if lane == Lane::Datagram {
                                credits.admit(*sent, now + Duration::from_millis(200));
                                report.datagram_active_peak =
                                    report.datagram_active_peak.max(credits.active());
                            }
                            *sent += 1;
                        }
                        Admission::Backpressured => match lane {
                            Lane::Datagram => report.datagram_backpressured += 1,
                            Lane::Reliable => report.reliable_backpressured += 1,
                        },
                        Admission::Expired => {}
                        _ => {
                            report.terminal.origin = ClientOrigin::Admission;
                            return Err(ClientStage::Probe);
                        }
                    }
                }
            }
            Ok(())
        })?;
        timing.sleep(
            endpoint.next_wakeup().min(Duration::from_millis(1)),
            Instant::now,
            thread::sleep,
        );
    }
    if report.lanes_completed() != 2
        || report.datagram_loss() != 0
        || report.reliable_loss() != 0
        || report.duplicates != 0
    {
        report.terminal.origin = if report.lanes_completed() != 2
            || report.datagram_loss() + report.reliable_loss() > 0
        {
            ClientOrigin::FinalMissing
        } else {
            ClientOrigin::FinalDuplicate
        };
        report.timeouts += u64::from(report.datagram_loss() + report.reliable_loss() > 0);
        return Err(ClientStage::Probe);
    }
    report.terminal.origin = ClientOrigin::Completed;
    Ok(())
}
fn poll_owned(
    child: &mut std::process::Child,
    report: &mut ClientReport,
    endpoint: &mut crate::Endpoint,
    fd: libc::c_int,
) -> Result<(), ClientStage> {
    if !stdout_is_quiet(fd) {
        report.terminal.origin = ClientOrigin::StdoutEvent;
        return Err(ClientStage::Probe);
    }
    endpoint.poll().map_err(|error| {
        report.terminal.origin = ClientOrigin::Poll;
        report.terminal.record_error(&error);
        ClientStage::Probe
    })?;
    if endpoint.stats().retired {
        report.terminal.origin = ClientOrigin::EndpointRetired;
        count_endpoint_timeout(endpoint.stats().retirement, report);
        return Err(ClientStage::Probe);
    }
    report.terminal.origin = ClientOrigin::ChildExit;
    if child.try_wait().map_err(|_| ClientStage::Probe)?.is_some() {
        return Err(ClientStage::Probe);
    }
    Ok(())
}
// A single bounded owner turn, with the same poll and workload collaborators as
// production. A private clock seam permits deterministic poll-preemption tests.
fn rate_poll_dispatch<C>(
    context: &mut C,
    deadline: std::time::Instant,
    mut clock: impl FnMut() -> std::time::Instant,
    poll: impl FnOnce(&mut C) -> Result<(), ClientStage>,
    dispatch: impl FnOnce(&mut C, std::time::Instant) -> bool,
) -> Result<Option<(std::time::Instant, bool)>, ClientStage> {
    poll(context)?;
    let now = clock();
    if now >= deadline {
        return Ok(None);
    }
    Ok(Some((now, dispatch(context, now))))
}

#[cfg(test)]
mod rate_deadline_tests {
    use super::*;
    use std::{
        cell::Cell,
        time::{Duration, Instant},
    };
    #[test]
    fn owner_poll_straddling_cutoff_cannot_dispatch_even_a_valid_completion() {
        let deadline = Instant::now() + Duration::from_secs(15);
        for (after_poll, allowed) in [
            (deadline - Duration::from_nanos(1), true),
            (deadline, false),
            (deadline + Duration::from_nanos(1), false),
        ] {
            let now = Cell::new(deadline - Duration::from_nanos(2));
            let dispatched = Cell::new(false);
            assert!(now.get() < deadline); // Original while-loop entry is eligible.
            let result = rate_poll_dispatch(
                &mut (),
                deadline,
                || now.get(),
                |_| {
                    now.set(after_poll);
                    Ok(())
                },
                |_, received| {
                    assert_eq!(received, after_poll);
                    dispatched.set(true);
                    true
                },
            )
            .unwrap();
            assert_eq!(result.is_some(), allowed);
            assert_eq!(dispatched.get(), allowed);
        }
    }
}
