//! Private, bounded synthetic host fixture. No external address, path, or command arguments.
use galaxybridge_quic::{tls::Identity, Endpoint};
use galaxybridge_quic_media::{media::OutputLease, Context, Driver, Failure, Owner};
use std::{
    collections::VecDeque,
    fs::File,
    io::{ErrorKind, Read, Write},
    os::fd::FromRawFd,
    time::{Duration, Instant},
};

unsafe extern "C" {
    fn fcntl(fd: i32, command: i32, ...) -> i32;
}
const PIPE_FRAME: usize = 32 * 1024;
const TOTAL_INPUT: usize = 64 * 1024 * 1024;
const HARD_LIFETIME: Duration = Duration::from_secs(10);
fn nonblocking(fd: i32) -> Result<(), Failure> {
    #[cfg(target_os = "macos")]
    const NONBLOCK: i32 = 4;
    #[cfg(not(target_os = "macos"))]
    const NONBLOCK: i32 = 2048;
    // Preserve all inherited status flags; only these owned pipe endpoints change.
    let flags = unsafe { fcntl(fd, 3) };
    if flags < 0 || unsafe { fcntl(fd, 4, flags | NONBLOCK) } < 0 {
        return Err(Failure::Sink);
    }
    Ok(())
}
fn context(session: [u8; 32]) -> Context {
    Context {
        session,
        generation: 1,
        scid: 1,
        capture_kind: 0,
        display_id: 0,
        target_token: 9,
        enabled: 7,
    }
}
fn pair() -> Result<(Driver, Driver), Failure> {
    let a = Identity::generate().map_err(|_| Failure::Retired)?;
    let b = Identity::generate().map_err(|_| Failure::Retired)?;
    let ap = a.fingerprint();
    let bp = b.fingerprint();
    let session = galaxybridge_quic::tls::random_session().map_err(|_| Failure::Retired)?;
    let address = "127.0.0.1:0".parse().map_err(|_| Failure::Protocol)?;
    let ip = "127.0.0.1".parse().map_err(|_| Failure::Protocol)?;
    let server = Endpoint::listen(address, ip, session, b, ap).map_err(|_| Failure::Retired)?;
    let client = Endpoint::connect(
        address,
        server.local_addr().map_err(|_| Failure::Retired)?,
        session,
        a,
        bp,
    )
    .map_err(|_| Failure::Retired)?;
    let origin = Instant::now();
    Ok((
        Driver::new(Owner::new(context(session), 0)?, client, origin),
        Driver::new(Owner::new(context(session), 0)?, server, origin),
    ))
}
fn header(kind: u8) -> [u8; 40] {
    let mut h = [0; 40];
    h[0] = kind;
    h
}
struct Output {
    header: [u8; 40],
    position: usize,
    lease: Option<OutputLease>,
}
impl Output {
    fn event(lease: OutputLease) -> Self {
        let r = &lease.record;
        let mut h = header(r.kind);
        h[1] = r.track;
        h[2..4].copy_from_slice(&r.flags.to_be_bytes());
        h[4..8].copy_from_slice(&(lease.bytes.len() as u32).to_be_bytes());
        h[8..16].copy_from_slice(&lease.token.to_be_bytes());
        h[16..20].copy_from_slice(&r.epoch.to_be_bytes());
        h[20..24].copy_from_slice(&r.config.to_be_bytes());
        h[24..32].copy_from_slice(&r.sequence.to_be_bytes());
        h[32..40].copy_from_slice(&r.pts.to_be_bytes());
        Self {
            header: h,
            position: 0,
            lease: Some(lease),
        }
    }
    fn scalar(h: [u8; 40]) -> Self {
        Self {
            header: h,
            position: 0,
            lease: None,
        }
    }
    fn write(&mut self, out: &mut File) -> Result<bool, Failure> {
        let body = self.lease.as_ref().map_or(&[][..], |l| l.bytes.as_slice());
        let bytes = if self.position < 40 {
            &self.header[self.position..]
        } else {
            let at = self.position - 40;
            &body[at..(at + PIPE_FRAME).min(body.len())]
        };
        if bytes.is_empty() {
            return Ok(true);
        }
        match out.write(bytes) {
            Ok(0) => Err(Failure::Sink),
            Ok(n) => {
                self.position += n;
                Ok(self.position == 40 + body.len())
            }
            Err(e) if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::Interrupted) => {
                Ok(false)
            }
            Err(_) => Err(Failure::Sink),
        }
    }
}
fn transport_reason(reason: Option<galaxybridge_quic::endpoint::Retirement>) -> u32 {
    use galaxybridge_quic::endpoint::Retirement::*;
    match reason {
        None => 0,
        Some(Closed) => 1,
        Some(Authentication) => 2,
        Some(Protocol) => 3,
        Some(ConnectTimeout) => 4,
        Some(PeerIdle) => 5,
        Some(ReliableStall) => 6,
        Some(Io) => 7,
    }
}
fn run(
    frame_open: &mut bool,
    skipped_video: &mut u64,
    retirement: &mut u32,
) -> Result<(), Failure> {
    let args: Vec<_> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) != Some("--stdio-fixture") || args.len() > 2 {
        return Err(Failure::Protocol);
    }
    let mode = args.get(1).map_or("none", String::as_str);
    if !matches!(mode, "none" | "drop-once" | "whole-once" | "hole") {
        return Err(Failure::Protocol);
    }
    nonblocking(0)?;
    nonblocking(1)?;
    let mut input = unsafe { File::from_raw_fd(0) };
    let mut output = std::mem::ManuallyDrop::new(unsafe { File::from_raw_fd(1) });
    let (mut sender, mut receiver) = pair()?;
    let began = Instant::now();
    let mut started = false;
    let mut ready = false;
    let mut starts = 0;
    let mut input_header = [0u8; 8];
    let mut header_used = 0;
    let mut body = Vec::new();
    let mut expected = 0usize;
    let mut total = 0usize;
    let mut scalars = VecDeque::new();
    let mut writing: Option<Output> = None;
    let mut held: Vec<OutputLease> = vec![];
    let mut done = false;
    let mut finish_sent = false;
    let mut tracks = [false; 2];
    let mut dropped = false;
    loop {
        if began.elapsed() >= HARD_LIFETIME {
            return Err(Failure::Deadline);
        }
        let sent = sender.poll();
        if sent == Err(Failure::Retired) {
            *retirement = transport_reason(sender.transport_stats().retirement);
        }
        sent?;
        let received = receiver.poll_filtered(&mut |received| {
            let Ok(r) =
                galaxybridge_quic_media::wire::Record::decode(received.lane, &received.payload)
            else {
                return true;
            };
            if r.kind != 5 || r.track != 1 {
                return true;
            }
            let discard = match mode {
                "drop-once" => r.sequence == 1 && r.index == 0 && !dropped,
                "whole-once" => r.sequence == 2 && r.age_us < 5000,
                "hole" => r.sequence == 2,
                _ => false,
            };
            if discard {
                dropped = true
            }
            !discard
        });
        *skipped_video = receiver.owner.receiver.skipped_video();
        if received == Err(Failure::Retired) {
            *retirement = transport_reason(receiver.transport_stats().retirement);
        }
        received?;
        if !started && sender.ready() && receiver.ready() {
            sender.owner.queue_start(sender.now()?)?;
            receiver.owner.queue_start(receiver.now()?)?;
            started = true;
        }
        while let Some(r) = sender.owner.transactions.next_transaction_result() {
            if !matches!(
                r.outcome,
                galaxybridge_quic_media::Outcome::PeerBoundaryConfirmed(_)
                    | galaxybridge_quic_media::Outcome::SupersededBeforeDispatch
            ) {
                return Err(Failure::Deadline);
            }
            if starts < 2 {
                starts += 1
            }
        }
        while let Some(r) = receiver.owner.transactions.next_transaction_result() {
            if !matches!(
                r.outcome,
                galaxybridge_quic_media::Outcome::PeerBoundaryConfirmed(_)
            ) {
                return Err(Failure::Deadline);
            }
            if starts < 2 {
                starts += 1
            }
        }
        // Fixture prerequisite, before any stock bytes are read: G0 publishes
        // measured recovery statistics at its unchanged 100ms sampling cadence.
        // Missing RTT remains a reason NOT to repair; never invent a margin or
        // wait here after the original stock/AU clock has started.
        let measured = |d: &Driver| {
            let p = d.transport_stats().path;
            p.valid && p.available && p.rtt_available
        };
        if started && !ready && starts == 2 && measured(&sender) && measured(&receiver) {
            ready = true;
            scalars.push_back(header(65));
        }
        while let Some(disposition) = receiver.owner.receiver.disposition() {
            if scalars.len() >= 16 {
                return Err(Failure::Capacity);
            }
            let mut h = header(67);
            match disposition {
                galaxybridge_quic_media::media::Disposition::RecoveryRequired {
                    track,
                    epoch,
                    sequence,
                } => {
                    h[1] = 1;
                    h[2] = track;
                    h[16..20].copy_from_slice(&epoch.to_be_bytes());
                    h[24..32].copy_from_slice(&sequence.to_be_bytes());
                }
                galaxybridge_quic_media::media::Disposition::AudioGap { sequence } => {
                    h[1] = 2;
                    h[24..32].copy_from_slice(&sequence.to_be_bytes());
                }
                galaxybridge_quic_media::media::Disposition::Retired(reason) => {
                    h[1] = 3;
                    h[3] = code(reason);
                    h[24..32].copy_from_slice(&skipped_video.to_be_bytes());
                }
            }
            scalars.push_back(h);
        }
        if ready && !done && scalars.len() < 16 {
            let target = if header_used < 8 {
                &mut input_header[header_used..]
            } else {
                &mut body[expected..]
            };
            if !target.is_empty() {
                match input.read(target) {
                    Ok(0) => return Err(Failure::Retired),
                    Ok(n) => {
                        total = total.checked_add(n).ok_or(Failure::Capacity)?;
                        if total > TOTAL_INPUT {
                            return Err(Failure::Capacity);
                        }
                        if header_used < 8 {
                            header_used += n;
                            if header_used == 8 {
                                if input_header[2..4] != [0, 0] {
                                    return Err(Failure::Protocol);
                                }
                                let length =
                                    u32::from_be_bytes(input_header[4..8].try_into().unwrap())
                                        as usize;
                                if length > PIPE_FRAME
                                    || !matches!(input_header[0], 1..=5)
                                    || input_header[0] != 1 && input_header[1] != 0
                                    || input_header[0] == 1
                                        && (!matches!(input_header[1], 1 | 2) || length == 0)
                                    || matches!(input_header[0], 2 | 3 | 5) && length != 8
                                    || input_header[0] == 4 && length != 0
                                {
                                    return Err(Failure::Protocol);
                                }
                                body = vec![0; length];
                                expected = 0;
                            }
                        } else {
                            expected += n;
                        }
                    }
                    Err(e)
                        if matches!(e.kind(), ErrorKind::WouldBlock | ErrorKind::Interrupted) => {}
                    Err(_) => return Err(Failure::Sink),
                }
            }
            if header_used == 8 && expected == body.len() {
                match input_header[0] {
                    1 => {
                        let track = input_header[1];
                        tracks[track as usize - 1] = true;
                        let mut used = 0;
                        while used < body.len() {
                            let (n, _) =
                                sender
                                    .owner
                                    .ingest_stock(track, &body[used..], sender.now()?)?;
                            if n == 0 {
                                return Err(Failure::Protocol);
                            }
                            used += n;
                        }
                        scalars.push_back(header(64));
                    }
                    2 | 3 | 5 => {
                        let token = u64::from_be_bytes(body[..8].try_into().unwrap());
                        let pos = held
                            .iter()
                            .position(|h| h.token == token)
                            .ok_or(Failure::Protocol)?;
                        if input_header[0] == 2 {
                            receiver
                                .owner
                                .receiver
                                .consumer_commit(&held[pos], receiver.now()?)?;
                        } else if input_header[0] == 5 {
                            receiver
                                .owner
                                .receiver
                                .check_output(&held[pos], receiver.now()?)?;
                        } else {
                            receiver
                                .owner
                                .receiver
                                .release_output(&held[pos], receiver.now()?)?;
                            held.remove(pos);
                        }
                        scalars.push_back(header(64));
                    }
                    4 => {
                        for (i, seen) in tracks.iter().enumerate() {
                            if *seen {
                                sender.owner.stock_eof((i + 1) as u8, sender.now()?)?;
                            }
                        }
                        done = true;
                    }
                    _ => return Err(Failure::Protocol),
                }
                header_used = 0;
                body = vec![];
                expected = 0;
            }
        }
        if writing.is_none() {
            if let Some(h) = scalars.pop_front() {
                writing = Some(Output::scalar(h));
            } else if held.len() < 32 {
                if let Some(lease) = receiver.owner.receiver.next_output(receiver.now()?)? {
                    held.push(lease.clone());
                    writing = Some(Output::event(lease));
                }
            }
        }
        if let Some(w) = writing.as_mut() {
            *frame_open = true;
            if w.write(&mut output)? {
                *frame_open = false;
                writing = None;
                if finish_sent {
                    return Ok(());
                }
            }
        }
        if done
            && !finish_sent
            && held.is_empty()
            && writing.is_none()
            && scalars.is_empty()
            && sender.owner.cache.usage() == (0, 0)
            && sender.owner.transactions.next_wakeup().is_none()
        {
            writing = Some(Output::scalar(header(66)));
            finish_sent = true;
        }
        std::thread::sleep(
            sender
                .next_wakeup()
                .min(receiver.next_wakeup())
                .min(Duration::from_micros(100)),
        );
    }
}
fn code(e: Failure) -> u8 {
    match e {
        Failure::Protocol => 1,
        Failure::Capacity => 2,
        Failure::Deadline => 3,
        Failure::Clock => 4,
        Failure::Retired => 5,
        Failure::Unsupported => 6,
        Failure::Codec => 7,
        Failure::UnrecoverableVideoGap => 8,
        Failure::Sink => 9,
    }
}
fn main() {
    let mut frame_open = false;
    let mut skipped_video = 0;
    let mut retirement = 0;
    if let Err(error) = run(&mut frame_open, &mut skipped_video, &mut retirement) {
        // Fixed numeric terminal record only. Never print payload, bootstrap or key material.
        if !frame_open && nonblocking(1).is_ok() {
            let mut h = header(67);
            h[1] = 3;
            h[3] = code(error);
            h[16..20].copy_from_slice(&retirement.to_be_bytes());
            h[24..32].copy_from_slice(&skipped_video.to_be_bytes());
            let mut terminal = Output::scalar(h);
            let mut out = unsafe { File::from_raw_fd(1) };
            let until = Instant::now() + Duration::from_millis(50);
            while Instant::now() < until {
                match terminal.write(&mut out) {
                    Ok(true) | Err(_) => break,
                    Ok(false) => std::thread::sleep(Duration::from_millis(1)),
                }
            }
        }
        std::process::exit(code(error) as i32)
    }
}
