use galaxybridge_quic::{
    bootstrap::{Reply, Request, MAX_BODY},
    rate_probe::{RatePeer, RateShape},
    tls::{random_session, Identity},
    Admission, Endpoint, Lane, Message,
};
use std::{
    io,
    net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr},
    thread,
    time::{Duration, Instant},
};

fn main() {
    if run().is_err() {
        eprintln!("probe_failed=1");
        std::process::exit(1);
    }
}
fn run() -> Result<(), ()> {
    if std::env::args_os()
        .nth(1)
        .is_some_and(|arg| arg == "--stdio-client")
    {
        return stdio_client();
    }
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args == ["--self-test"] {
        return self_test();
    }
    if args.first().map(String::as_str) != Some("--stdio-peer") {
        return Err(());
    }
    let mut lifetime = Duration::from_secs(30);
    let mut duration_set = false;
    let mut shape = None;
    let mut options = args[1..].chunks_exact(2);
    for pair in &mut options {
        match pair[0].as_str() {
            "--duration-ms" if !duration_set => {
                let millis = pair[1].parse::<u64>().map_err(|_| ())?;
                if millis == 0 || millis > 30_000 {
                    return Err(());
                }
                lifetime = Duration::from_millis(millis);
                duration_set = true;
            }
            "--rate-shape" if shape.is_none() => shape = Some(parse_shape(&pair[1])?),
            _ => return Err(()),
        }
    }
    if !options.remainder().is_empty() || (shape.is_some() && lifetime != Duration::from_secs(30)) {
        return Err(());
    }
    stdio_peer(lifetime, shape)
}
fn parse_shape(value: &str) -> Result<RateShape, ()> {
    match value {
        "constant" => Ok(RateShape::Constant),
        "frame-burst" => Ok(RateShape::FrameBurst),
        _ => Err(()),
    }
}

fn stdio_client() -> Result<(), ()> {
    use galaxybridge_quic::bootstrap::{run_stdio_client, ClientOptions, ClientReport};
    let mut args = std::env::args_os().skip(2);
    let mut peer = None;
    let mut local = None;
    let mut duration = Duration::from_secs(5);
    let mut duration_set = false;
    let mut shape = None;
    let mut program = None;
    let mut child_args = vec![];
    while let Some(option) = args.next() {
        if option == "--" {
            program = args.next();
            child_args.extend(args);
            break;
        }
        let value = args.next().ok_or(())?;
        let value = value.to_str().ok_or(())?;
        if option == "--peer-ip" && peer.is_none() {
            peer = Some(value.parse::<IpAddr>().map_err(|_| ())?);
        } else if option == "--local-ip" && local.is_none() {
            local = Some(value.parse::<IpAddr>().map_err(|_| ())?);
        } else if option == "--duration-ms" && !duration_set {
            duration = Duration::from_millis(value.parse::<u64>().map_err(|_| ())?);
            duration_set = true;
        } else if option == "--rate-shape" && shape.is_none() {
            shape = Some(parse_shape(value)?);
        } else {
            return Err(());
        }
    }
    if shape.is_some() && !duration_set {
        duration = Duration::from_secs(15);
    }
    let options = ClientOptions {
        program: program.ok_or(())?.into(),
        args: child_args,
        peer_ip: peer.ok_or(())?,
        local_ip: local.ok_or(())?,
        duration,
    };
    if let Some(shape) = shape {
        return match galaxybridge_quic::bootstrap::run_stdio_rate_client(options, shape) {
            Ok(report) => {
                report.print_scalars();
                print_transport("client", report.terminal.endpoint);
                print_observations(
                    "client",
                    report.terminal.endpoint,
                    report.terminal.owner_timing,
                );
                Ok(())
            }
            Err(failure) => {
                failure.report.print_scalars();
                print_transport("client", failure.report.terminal.endpoint);
                print_observations(
                    "client",
                    failure.report.terminal.endpoint,
                    failure.report.terminal.owner_timing,
                );
                eprintln!(
                    "client_stage={:?} client_origin={:?} client_error={:?} client_errno={}",
                    failure.stage,
                    failure.report.terminal.origin,
                    failure.report.terminal.error,
                    failure.report.terminal.errno
                );
                Err(())
            }
        };
    }
    let result = run_stdio_client(options);
    fn print_report(outcome: &str, report: ClientReport) {
        eprintln!("client={} requested_ms={} elapsed_ms={} lanes_completed={} datagrams_sent={} datagrams_received={} datagram_loss={} reliable_sent={} reliable_received={} reliable_loss={} duplicates={} timeouts={} cleanup={} cleanup_forced={}",
            outcome,report.requested_duration_ms,report.elapsed_ms,report.lanes_completed(),report.datagrams_sent,report.datagrams_received,report.datagram_loss(),report.reliable_sent,report.reliable_received,report.reliable_loss(),report.duplicates,report.timeouts,u8::from(report.cleanup),u8::from(report.cleanup_forced));
        eprintln!("client_origin={:?} client_error={:?} client_errno={} datagram_active_peak={} datagram_credit_expired={} datagram_credit_blocked={} datagram_backpressured={} reliable_credit_blocked={} reliable_backpressured={}",
            report.terminal.origin, report.terminal.error, report.terminal.errno,
            report.datagram_active_peak, report.datagram_credit_expired,
            report.datagram_credit_blocked, report.datagram_backpressured,
            report.reliable_credit_blocked, report.reliable_backpressured);
        print_transport("client", report.terminal.endpoint);
        print_observations(
            "client",
            report.terminal.endpoint,
            report.terminal.owner_timing,
        );
    }
    match result {
        Ok(report) => {
            print_report("pass", report);
            Ok(())
        }
        Err(failure) => {
            print_report("fail", failure.report);
            eprintln!("client_stage={:?}", failure.stage);
            Err(())
        }
    }
}
// Role is selected only by these two call sites; all remaining values are
// bounded enums or numeric scalars, never peer-supplied diagnostic text.
fn print_transport(role: &str, stats: galaxybridge_quic::Stats) {
    eprintln!("{role}_quiche_datagrams_decoded={} {role}_quiche_datagrams_pending_records={} {role}_quiche_datagrams_pending_bytes={} {role}_datagrams_extracted={} {role}_quiche_datagrams_evicted={} {role}_datagram_observation_valid={} {role}_datagram_observation_failures={} {role}_receive_resource_failure={}",
        stats.quiche_datagrams_decoded, stats.quiche_datagrams_pending_records,
        stats.quiche_datagrams_pending_bytes, stats.datagrams_extracted,
        stats.quiche_datagrams_evicted, u8::from(stats.datagram_observation_valid),
        stats.datagram_observation_failures, u8::from(stats.receive_resource_failure));
    eprintln!("{role}_retirement={} {role}_reached_tls={} {role}_reached_ready={} {role}_tls_failure={:?} {role}_udp_sent={} {role}_udp_received={} {role}_quic_received={} {role}_datagrams_admitted={} {role}_datagrams_received={} {role}_datagrams_rejected={} {role}_datagrams_generated={} {role}_datagrams_udp_sent={} {role}_expired={} {role}_rejected={} {role}_datagram_queue={} {role}_generated_queue={} {role}_receive_queue={} {role}_receive_bytes={} {role}_reliable_bytes={} {role}_io_errno={} {role}_local_close_present={} {role}_local_close_code={} {role}_peer_close_present={} {role}_peer_close_code={}",
        stats.retirement.map(|reason| format!("{reason:?}")).unwrap_or_else(|| "None".into()),
        u8::from(stats.reached_tls),u8::from(stats.reached_ready),stats.tls_failure,
        stats.sent_udp_packets,stats.udp_socket_received,stats.received_udp_packets,stats.datagrams_admitted,
        stats.datagrams_received,stats.datagrams_rejected,stats.datagrams_generated,
        stats.datagrams_udp_sent,stats.expired,stats.rejected,stats.datagram_queue_records,
        stats.generated_packets,stats.receive_queue_records,stats.receive_queue_bytes,
        stats.reliable_backlog_bytes,stats.io_errno,
        u8::from(stats.local_close_code.is_some()),stats.local_close_code.unwrap_or(0),
        u8::from(stats.peer_close_code.is_some()),stats.peer_close_code.unwrap_or(0));
}
fn print_observations(
    role: &str,
    stats: galaxybridge_quic::Stats,
    owner: galaxybridge_quic::bootstrap::diagnostics::OwnerSummary,
) {
    use galaxybridge_quic::bootstrap::diagnostics::{write_terminal, Role};
    let local_role = if role == "peer" {
        Role::Peer
    } else {
        Role::Client
    };
    if write_terminal(std::io::stderr().lock(), local_role, stats, owner).is_err() {
        eprintln!("{role}_diagnostic_output_failed=1");
    }
}
fn self_test() -> Result<(), ()> {
    let a = Identity::generate().map_err(|_| ())?;
    let b = Identity::generate().map_err(|_| ())?;
    let a_pin = a.fingerprint();
    let b_pin = b.fingerprint();
    let session = random_session().map_err(|_| ())?;
    let mut b = Endpoint::listen(
        "127.0.0.1:0".parse().unwrap(),
        "127.0.0.1".parse().unwrap(),
        session,
        b,
        a_pin,
    )
    .map_err(|_| ())?;
    let mut a = Endpoint::connect(
        "127.0.0.1:0".parse().unwrap(),
        b.local_addr().map_err(|_| ())?,
        session,
        a,
        b_pin,
    )
    .map_err(|_| ())?;
    let end = Instant::now() + Duration::from_secs(3);
    let mut submitted = false;
    while Instant::now() < end {
        a.poll().map_err(|_| ())?;
        b.poll().map_err(|_| ())?;
        if a.stats().retired || b.stats().retired {
            return Err(());
        }
        if !submitted && a.stats().application_ready && b.stats().application_ready {
            for endpoint in [&mut a, &mut b] {
                for lane in [Lane::Datagram, Lane::Reliable] {
                    if endpoint.send(
                        Message {
                            lane,
                            sequence: 1,
                            payload: vec![0x5a],
                        },
                        Instant::now() + Duration::from_millis(200),
                    ) != Admission::Accepted
                    {
                        return Err(());
                    }
                }
            }
            submitted = true;
        }
        if a.stats().delivered + b.stats().delivered == 4 {
            for endpoint in [&mut a, &mut b] {
                let mut datagram = false;
                let mut reliable = false;
                while let Some(message) = endpoint.receive() {
                    if message.sequence != 1 || message.payload != [0x5a] {
                        return Err(());
                    }
                    match message.lane {
                        Lane::Datagram => datagram = true,
                        Lane::Reliable => reliable = true,
                    }
                }
                if !datagram || !reliable {
                    return Err(());
                }
            }
            a.close();
            b.close();
            eprintln!("self_test=pass peers=2 delivered=4 retired=2");
            return Ok(());
        }
        thread::sleep(
            a.next_wakeup()
                .min(b.next_wakeup())
                .min(Duration::from_millis(1)),
        );
    }
    Err(())
}

// Poll/read only the owned pipe. No reader thread outlives the attempt, no
// private material is serialized, and allocation follows validated lengths.
fn readable(fd: libc::c_int, deadline: Instant) -> Result<bool, ()> {
    loop {
        let now = Instant::now();
        if now >= deadline {
            return Ok(false);
        }
        let millis = deadline.duration_since(now).as_millis().clamp(1, 20) as i32;
        let mut pfd = libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: one initialized pollfd, valid for the duration of this call.
        let result = unsafe { libc::poll(&mut pfd, 1, millis) };
        if result < 0 {
            if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(());
        }
        if result > 0 {
            if pfd.revents & libc::POLLNVAL != 0 {
                return Err(());
            }
            return Ok(pfd.revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0);
        }
    }
}
fn read_exact_deadline(bytes: &mut [u8], deadline: Instant) -> Result<(), ()> {
    let mut used = 0;
    while used < bytes.len() {
        if !readable(0, deadline)? {
            return Err(());
        }
        // SAFETY: descriptor 0 is the owned stdin; destination is a valid,
        // writable slice and read is limited to its remaining length.
        let len = unsafe { libc::read(0, bytes[used..].as_mut_ptr().cast(), bytes.len() - used) };
        if len == 0 {
            return Err(());
        }
        if len < 0 {
            if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                continue;
            }
            return Err(());
        }
        used += len as usize;
    }
    Ok(())
}
#[derive(Clone, Copy, Debug, Default)]
enum PeerOrigin {
    #[default]
    Bootstrap,
    StdinEof,
    StdinEvent,
    Poll,
    EndpointRetired,
    Lifetime,
    Rate,
}
#[derive(Default)]
struct PeerReport {
    owner_timing: galaxybridge_quic::bootstrap::diagnostics::OwnerSummary,
    origin: PeerOrigin,
    stats: galaxybridge_quic::Stats,
    received_datagrams: u64,
    received_reliable: u64,
    echo_datagrams: u64,
    echo_reliable: u64,
    echo_backpressured: u64,
}
fn stdio_peer(lifetime: Duration, shape: Option<RateShape>) -> Result<(), ()> {
    let mut report = PeerReport::default();
    let outcome = stdio_peer_inner(lifetime, &mut report, shape);
    eprintln!("retired=1 stdin_eof={} peer_origin={:?} peer_received_datagrams={} peer_received_reliable={} peer_echo_datagrams={} peer_echo_reliable={} peer_echo_backpressured={}",
        u8::from(matches!(report.origin, PeerOrigin::StdinEof)), report.origin,
        report.received_datagrams, report.received_reliable,
        report.echo_datagrams, report.echo_reliable, report.echo_backpressured);
    print_transport("peer", report.stats);
    print_observations("peer", report.stats, report.owner_timing);
    outcome
}
fn stdio_peer_inner(
    lifetime: Duration,
    report: &mut PeerReport,
    shape: Option<RateShape>,
) -> Result<(), ()> {
    let end = Instant::now() + lifetime;
    let bootstrap_deadline = (Instant::now() + Duration::from_secs(5)).min(end);
    let mut prefix = [0; 4];
    read_exact_deadline(&mut prefix, bootstrap_deadline)?;
    let len = u32::from_be_bytes(prefix) as usize;
    if len > MAX_BODY {
        return Err(());
    }
    let mut bytes = vec![0; len + 4];
    bytes[..4].copy_from_slice(&prefix);
    read_exact_deadline(&mut bytes[4..], bootstrap_deadline)?;
    let request = Request::decode(&bytes).map_err(|_| ())?;
    let identity = Identity::generate().map_err(|_| ())?;
    let fingerprint = identity.fingerprint();
    let bind_ip = match request.expected_ip {
        IpAddr::V4(ip) => IpAddr::V4(if ip.is_loopback() {
            Ipv4Addr::LOCALHOST
        } else {
            Ipv4Addr::UNSPECIFIED
        }),
        IpAddr::V6(ip) => IpAddr::V6(if ip.is_loopback() {
            Ipv6Addr::LOCALHOST
        } else {
            Ipv6Addr::UNSPECIFIED
        }),
    };
    let mut endpoint = Endpoint::listen(
        SocketAddr::new(bind_ip, 0),
        request.expected_ip,
        request.session,
        identity,
        request.fingerprint,
    )
    .map_err(|_| ())?;
    let reply = Reply {
        session: request.session,
        fingerprint,
        port: endpoint.local_addr().map_err(|_| ())?.port(),
    }
    .encode()
    .map_err(|_| ())?;
    // The only stdout record is 71 bytes, below POSIX PIPE_BUF; poll bounds a
    // blocked parent, then one atomic pipe write avoids a partial reply.
    let mut pfd = libc::pollfd {
        fd: 1,
        events: libc::POLLOUT,
        revents: 0,
    };
    let timeout = bootstrap_deadline
        .saturating_duration_since(Instant::now())
        .as_millis()
        .min(5000) as i32;
    // SAFETY: initialized single pollfd and immutable, bounded reply storage.
    if unsafe { libc::poll(&mut pfd, 1, timeout) } != 1 || pfd.revents & libc::POLLOUT == 0 {
        return Err(());
    }
    // SAFETY: reply points to reply.len() valid bytes for the syscall.
    if unsafe { libc::write(1, reply.as_ptr().cast(), reply.len()) } != reply.len() as isize {
        return Err(());
    }
    let mut pending: Option<(Message, Instant)> = None;
    let mut rate = shape.map(RatePeer::new);
    let timing = galaxybridge_quic::bootstrap::diagnostics::OwnerTiming::default();
    let outcome = (|| {
        while Instant::now() < end && !endpoint.stats().retired {
            // EOF owns retirement, even while no QUIC packet arrives.
            let mut pfd = libc::pollfd {
                fd: 0,
                events: libc::POLLIN,
                revents: 0,
            };
            // SAFETY: initialized single pollfd, nonblocking readiness query.
            let status = unsafe { libc::poll(&mut pfd, 1, 0) };
            if status < 0 {
                report.origin = PeerOrigin::StdinEvent;
                return Err(());
            }
            if status > 0 {
                let mut extra = 0u8;
                // SAFETY: one valid writable byte; poll signalled readiness/EOF.
                let count = unsafe { libc::read(0, (&mut extra as *mut u8).cast(), 1) };
                if count == 0 {
                    report.origin = PeerOrigin::StdinEof;
                    return Ok(());
                }
                report.origin = PeerOrigin::StdinEvent;
                return Err(());
            }
            // Observe complete turns which start application-ready. The one
            // readiness-transition turn remains outside this active summary.
            let observed = endpoint.stats().application_ready;
            if observed {
                timing.turn(Instant::now());
            }
            let polled = if observed {
                timing.poll(Instant::now, || endpoint.poll())
            } else {
                endpoint.poll()
            };
            polled.map_err(|_| {
                report.origin = PeerOrigin::Poll;
            })?;
            if let Some(rate) = &mut rate {
                let now = Instant::now();
                if endpoint.stats().application_ready {
                    let stepped = if observed {
                        timing.step(Instant::now, || rate.step(&mut endpoint, now))
                    } else {
                        rate.step(&mut endpoint, now)
                    };
                    stepped.map_err(|error| {
                        report.origin = PeerOrigin::Rate;
                        eprintln!("peer_rate_error={error:?}");
                    })?;
                } else if observed {
                    timing.retired_step_skipped(endpoint.stats().retired);
                }
                let sleep = endpoint.next_wakeup().min(rate.next_wakeup(now));
                if observed {
                    timing.sleep(sleep, Instant::now, thread::sleep);
                } else {
                    thread::sleep(sleep);
                }
                continue;
            }
            let mut step = || {
                if pending.is_none() {
                    pending = endpoint.receive().map(|received| {
                        match received.lane {
                            Lane::Datagram => report.received_datagrams += 1,
                            Lane::Reliable => report.received_reliable += 1,
                        }
                        (
                            Message {
                                lane: received.lane,
                                sequence: received.sequence,
                                payload: received.payload,
                            },
                            Instant::now() + Duration::from_millis(200),
                        )
                    });
                }
                if let Some((message, deadline)) = &pending {
                    let admission = endpoint.send(
                        Message {
                            lane: message.lane,
                            sequence: message.sequence,
                            payload: message.payload.clone(),
                        },
                        *deadline,
                    );
                    if admission == Admission::Accepted {
                        match message.lane {
                            Lane::Datagram => report.echo_datagrams += 1,
                            Lane::Reliable => report.echo_reliable += 1,
                        }
                    } else if admission == Admission::Backpressured {
                        report.echo_backpressured += 1;
                    }
                    if admission != Admission::Backpressured {
                        pending = None;
                    }
                }
            };
            if observed {
                timing.step(Instant::now, step);
            } else {
                step();
            }
            let sleep = endpoint.next_wakeup().min(Duration::from_millis(2));
            if observed {
                timing.sleep(sleep, Instant::now, thread::sleep);
            } else {
                thread::sleep(sleep);
            }
        }
        if endpoint.stats().retired {
            report.origin = PeerOrigin::EndpointRetired;
            Err(())
        } else {
            report.origin = PeerOrigin::Lifetime;
            Ok(())
        }
    })();
    report.owner_timing = timing.snapshot();
    report.stats = endpoint.capture_terminal_diagnostics();
    endpoint.close();
    outcome
}
