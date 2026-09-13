use galaxybridge_quic::{tls::Identity, Admission, Endpoint, Lane, Message};
use std::{
    net::SocketAddr,
    thread,
    time::{Duration, Instant},
};

fn pair(
    same_session: bool,
    wrong_server_pin: bool,
    wrong_client_pin: bool,
) -> (Endpoint, Endpoint) {
    let client = Identity::generate().unwrap();
    let server = Identity::generate().unwrap();
    let client_pin = if wrong_client_pin {
        [0; 32]
    } else {
        client.fingerprint()
    };
    let server_pin = if wrong_server_pin {
        [0; 32]
    } else {
        server.fingerprint()
    };
    let server = Endpoint::listen(
        "127.0.0.1:0".parse().unwrap(),
        "127.0.0.1".parse().unwrap(),
        [1; 32],
        server,
        client_pin,
    )
    .unwrap();
    let client = Endpoint::connect(
        "127.0.0.1:0".parse().unwrap(),
        server.local_addr().unwrap(),
        if same_session { [1; 32] } else { [2; 32] },
        client,
        server_pin,
    )
    .unwrap();
    (client, server)
}
fn pump_until(
    a: &mut Endpoint,
    b: &mut Endpoint,
    duration: Duration,
    done: impl Fn(&Endpoint, &Endpoint) -> bool,
) {
    let end = Instant::now() + duration;
    while Instant::now() < end {
        a.poll().unwrap();
        b.poll().unwrap();
        if done(a, b) {
            return;
        }
        thread::sleep(Duration::from_millis(1));
    }
}
fn establish(a: &mut Endpoint, b: &mut Endpoint) {
    pump_until(a, b, Duration::from_secs(2), |a, b| {
        a.stats().application_ready && b.stats().application_ready
    });
    assert!(
        a.stats().authenticated
            && b.stats().authenticated
            && a.stats().application_ready
            && b.stats().application_ready,
        "real handshake and session preface must complete"
    );
}
fn message(lane: Lane, sequence: u64, size: usize) -> Message {
    Message {
        lane,
        sequence,
        payload: vec![0x5a; size],
    }
}

#[test]
fn authenticated_peers_exchange_exact_messages_on_both_lanes() {
    let (mut a, mut b) = pair(true, false, false);
    establish(&mut a, &mut b);
    for lane in [Lane::Reliable, Lane::Datagram] {
        assert_eq!(
            a.send(
                message(lane, 7, 1024),
                Instant::now() + Duration::from_secs(1)
            ),
            Admission::Accepted
        );
        assert_eq!(
            b.send(message(lane, 8, 1), Instant::now() + Duration::from_secs(1)),
            Admission::Accepted
        );
    }
    pump_until(&mut a, &mut b, Duration::from_secs(2), |a, b| {
        a.stats().receive_queue_records == 2 && b.stats().receive_queue_records == 2
    });
    for (endpoint, seq, size) in [(&mut a, 8, 1), (&mut b, 7, 1024)] {
        let mut lanes = vec![];
        while let Some(got) = endpoint.receive() {
            assert_eq!(got.sequence, seq);
            assert_eq!(got.payload, vec![0x5a; size]);
            lanes.push(got.lane);
        }
        assert_eq!(lanes.len(), 2);
        assert!(lanes.contains(&Lane::Reliable));
        assert!(lanes.contains(&Lane::Datagram));
    }
}

#[test]
fn wrong_pin_on_either_side_never_admits_application_data() {
    for (server_pin, client_pin) in [(true, false), (false, true)] {
        let (mut a, mut b) = pair(true, server_pin, client_pin);
        pump_until(&mut a, &mut b, Duration::from_secs(2), |a, b| {
            a.stats().retired || b.stats().retired
        });
        for endpoint in [&mut a, &mut b] {
            let _ = endpoint.send(
                message(Lane::Reliable, 1, 1),
                Instant::now() + Duration::from_secs(1),
            );
        }
        pump_until(&mut a, &mut b, Duration::from_millis(100), |_, _| false);
        assert_eq!(a.stats().delivered + b.stats().delivered, 0);
        assert!(
            a.stats().retired || b.stats().retired,
            "TLS authentication failure must retire"
        );
    }
}

#[test]
fn wrong_session_retires_before_delivering_any_record() {
    let (mut a, mut b) = pair(false, false, false);
    for lane in [Lane::Datagram, Lane::Reliable] {
        assert_eq!(
            a.send(message(lane, 1, 1), Instant::now() + Duration::from_secs(1)),
            Admission::Backpressured
        );
    }
    pump_until(&mut a, &mut b, Duration::from_secs(1), |_, b| {
        b.stats().retired
    });
    assert!(b.stats().retired);
    assert_eq!(b.stats().delivered, 0);
    assert!(b.receive().is_none());
    assert_eq!(a.stats().delivered, 0);
    assert!(!a.stats().application_ready);
}

#[test]
fn burst_and_expiry_admission_are_bounded_before_io() {
    let (mut a, mut b) = pair(true, false, false);
    establish(&mut a, &mut b);
    assert_eq!(
        a.send(message(Lane::Datagram, 0, 1), Instant::now()),
        Admission::Expired
    );
    assert_eq!(
        a.send(
            message(Lane::Datagram, 0, 1025),
            Instant::now() + Duration::from_secs(1)
        ),
        Admission::TooLarge
    );
    let expired_deadline = Instant::now() + Duration::from_millis(20);
    for n in 0..32 {
        assert_eq!(
            a.send(message(Lane::Datagram, n, 1024), expired_deadline),
            Admission::Accepted
        );
    }
    assert_eq!(
        a.send(message(Lane::Datagram, 33, 1), expired_deadline),
        Admission::Backpressured
    );
    assert_eq!(a.stats().datagram_queue_records, 32);
    thread::sleep(Duration::from_millis(25));
    pump_until(&mut a, &mut b, Duration::from_millis(100), |_, _| false);
    assert_eq!(a.stats().datagram_queue_records, 0);
    assert_eq!(b.stats().delivered, 0);
    assert_eq!(a.stats().expired, 33);
    for n in 0..60 {
        assert_eq!(
            a.send(message(Lane::Reliable, n, 1024), Instant::now()),
            Admission::Accepted
        );
    }
    assert_eq!(
        a.send(message(Lane::Reliable, 61, 1024), Instant::now()),
        Admission::Backpressured
    );
    assert!(a.stats().reliable_backlog_bytes <= 65536);
    a.close();
    a.close();
    let addr: SocketAddr = a.local_addr().unwrap();
    assert!(
        std::net::UdpSocket::bind(addr).is_ok(),
        "close releases exact socket"
    );
    assert_eq!(
        a.send(message(Lane::Reliable, 9, 0), Instant::now()),
        Admission::Retired
    );
    assert_eq!(a.stats().reliable_backlog_bytes, 0);
}

#[test]
fn stalled_reliable_attempt_retires_and_releases_backlog() {
    let (mut a, mut b) = pair(true, false, false);
    establish(&mut a, &mut b);
    assert_eq!(
        a.send(message(Lane::Reliable, 1, 1024), Instant::now()),
        Admission::Accepted
    );
    let end = Instant::now() + Duration::from_millis(5300);
    while Instant::now() < end && !a.stats().retired {
        a.poll().unwrap();
        thread::sleep(Duration::from_millis(2));
    }
    assert!(a.stats().retired);
    assert_eq!(
        a.stats().retirement,
        Some(galaxybridge_quic::endpoint::Retirement::ReliableStall)
    );
    assert!(a.diagnostics().reliable_backlog_bytes > 0);
    assert!(a.diagnostics().reached_ready);
    assert_eq!(a.stats().reliable_backlog_bytes, 0);
    assert!(a.receive().is_none());
}

// These peers use genuine BoringSSL/quiche, but deliberately violate the
// production contract without adding insecure switches to Endpoint.
fn raw_client_context(
    with_certificate: bool,
    alpn: &[u8],
    server_pin: [u8; 32],
) -> (quiche::Config, [u8; 32]) {
    use boring::{
        asn1::Asn1Time,
        bn::BigNum,
        ec::{EcGroup, EcKey},
        hash::MessageDigest,
        nid::Nid,
        pkey::PKey,
        ssl::{SslAlert, SslContextBuilder, SslMethod, SslVerifyError, SslVerifyMode},
        x509::{X509NameBuilder, X509},
    };
    let key = PKey::from_ec_key(
        EcKey::generate(&EcGroup::from_curve_name(Nid::X9_62_PRIME256V1).unwrap()).unwrap(),
    )
    .unwrap();
    let mut name = X509NameBuilder::new().unwrap();
    name.append_entry_by_text("CN", "test attempt").unwrap();
    let name = name.build();
    let mut cert = X509::builder().unwrap();
    cert.set_version(2).unwrap();
    cert.set_serial_number(&BigNum::from_u32(1).unwrap().to_asn1_integer().unwrap())
        .unwrap();
    cert.set_subject_name(&name).unwrap();
    cert.set_issuer_name(&name).unwrap();
    cert.set_pubkey(&key).unwrap();
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    cert.set_not_before(&Asn1Time::from_unix(now).unwrap())
        .unwrap();
    cert.set_not_after(&Asn1Time::from_unix(now + 3600).unwrap())
        .unwrap();
    cert.sign(&key, MessageDigest::sha256()).unwrap();
    let cert = cert.build();
    let pin = boring::sha::sha256(&cert.to_der().unwrap());
    let mut ctx = SslContextBuilder::new(SslMethod::tls()).unwrap();
    if with_certificate {
        ctx.set_certificate(&cert).unwrap();
        ctx.set_private_key(&key).unwrap();
    }
    ctx.set_custom_verify_callback(SslVerifyMode::PEER, move |ssl| {
        let der = ssl.peer_certificate().and_then(|c| c.to_der().ok());
        if der.is_some_and(|der| boring::memcmp::eq(&boring::sha::sha256(&der), &server_pin)) {
            Ok(())
        } else {
            Err(SslVerifyError::Invalid(SslAlert::BAD_CERTIFICATE))
        }
    });
    let mut config =
        quiche::Config::with_boring_ssl_ctx_builder(quiche::PROTOCOL_VERSION, ctx).unwrap();
    config.set_application_protos(&[alpn]).unwrap();
    config.set_max_send_udp_payload_size(1200);
    config.set_max_recv_udp_payload_size(1200);
    config.set_initial_max_data(262144);
    config.set_initial_max_streams_bidi(1);
    config.set_initial_max_stream_data_bidi_local(65536);
    config.set_initial_max_stream_data_bidi_remote(65536);
    config.enable_dgram(true, 32, 32);
    config.set_max_idle_timeout(1000);
    (config, pin)
}

#[test]
fn certificate_less_client_and_wrong_alpn_fail_real_tls() {
    for (certificate, alpn) in [
        (false, galaxybridge_quic::tls::ALPN),
        (true, b"wrong-alpn".as_slice()),
    ] {
        let identity = Identity::generate().unwrap();
        let (mut config, pin) = raw_client_context(certificate, alpn, identity.fingerprint());
        let mut server = Endpoint::listen(
            "127.0.0.1:0".parse().unwrap(),
            "127.0.0.1".parse().unwrap(),
            [1; 32],
            identity,
            pin,
        )
        .unwrap();
        let socket = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        socket.set_nonblocking(true).unwrap();
        let peer = server.local_addr().unwrap();
        let local = socket.local_addr().unwrap();
        let mut cid = [0; 16];
        boring::rand::rand_bytes(&mut cid).unwrap();
        let mut raw = quiche::connect(
            None,
            &quiche::ConnectionId::from_ref(&cid),
            local,
            peer,
            &mut config,
        )
        .unwrap();
        let end = Instant::now() + Duration::from_secs(2);
        let mut attempted = false;
        while Instant::now() < end && !server.stats().retired {
            let mut buffer = [0; 1200];
            while let Ok((len, info)) = raw.send(&mut buffer) {
                if let Some(delay) = info.at.checked_duration_since(Instant::now()) {
                    thread::sleep(delay.min(Duration::from_secs(1)));
                }
                socket.send_to(&buffer[..len], info.to).unwrap();
            }
            server.poll().unwrap();
            while let Ok((len, from)) = socket.recv_from(&mut buffer) {
                let _ = raw.recv(&mut buffer[..len], quiche::RecvInfo { from, to: local });
            }
            if raw.is_established() && !attempted {
                let msg = message(Lane::Reliable, 1, 1);
                let wire = galaxybridge_quic::wire::encode_reliable(&[1; 32], &msg).unwrap();
                let _ = raw.stream_send(0, &wire, false);
                attempted = true;
            }
            if raw.timeout().is_some_and(|t| t.is_zero()) {
                raw.on_timeout();
            }
            thread::sleep(Duration::from_millis(1));
        }
        assert!(server.stats().retired, "TLS violation must retire server");
        assert!(!server.stats().authenticated);
        assert_eq!(server.stats().delivered, 0);
        assert!(server.receive().is_none());
    }
}

#[test]
fn peer_terminal_stderr_reports_missing_certificate_from_real_tls() {
    use galaxybridge_quic::bootstrap::{Reply, Request};
    use std::{
        io::{Read, Write},
        process::{Command, Stdio},
    };
    let request = Request {
        session: [0x31; 32],
        fingerprint: [0x62; 32],
        expected_ip: "127.0.0.1".parse().unwrap(),
    };
    let mut child = Command::new(env!("CARGO_BIN_EXE_gb-quic-probe"))
        .args(["--stdio-peer", "--duration-ms", "3000"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child
        .stdin
        .as_mut()
        .unwrap()
        .write_all(&request.encode().unwrap())
        .unwrap();
    let mut reply = [0; 71];
    // An independent parent watchdog also bounds a regressed peer bootstrap.
    use std::os::fd::AsRawFd;
    let bootstrap_end = Instant::now() + Duration::from_secs(3);
    let mut used = 0;
    while used < reply.len() {
        if Instant::now() >= bootstrap_end {
            let _ = child.kill();
            let _ = child.wait();
            panic!("owned peer bootstrap watchdog");
        }
        let mut fd = libc::pollfd {
            fd: child.stdout.as_ref().unwrap().as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: one initialized descriptor borrowed from the owned child.
        if unsafe { libc::poll(&mut fd, 1, 20) } > 0 {
            match child.stdout.as_mut().unwrap().read(&mut reply[used..]) {
                Ok(count) if count > 0 => used += count,
                _ => {
                    let _ = child.kill();
                    let _ = child.wait();
                    panic!("owned peer bootstrap failed");
                }
            }
        }
    }
    let reply = Reply::decode(&reply, &request.session).unwrap();
    let peer = ("127.0.0.1".parse::<std::net::IpAddr>().unwrap(), reply.port).into();
    let (mut config, _) =
        raw_client_context(false, galaxybridge_quic::tls::ALPN, reply.fingerprint);
    let socket = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    socket.set_nonblocking(true).unwrap();
    let local = socket.local_addr().unwrap();
    let mut raw = quiche::connect(
        None,
        &quiche::ConnectionId::from_ref(&[0x33; 16]),
        local,
        peer,
        &mut config,
    )
    .unwrap();
    let end = Instant::now() + Duration::from_secs(4);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if Instant::now() >= end {
            child.kill().unwrap();
            child.wait().unwrap();
            panic!("owned negative peer exceeded watchdog");
        }
        let mut buffer = [0; 1200];
        while let Ok((len, info)) = raw.send(&mut buffer) {
            if let Some(delay) = info.at.checked_duration_since(Instant::now()) {
                thread::sleep(delay.min(Duration::from_millis(10)));
            }
            socket.send_to(&buffer[..len], info.to).unwrap();
        }
        while let Ok((len, from)) = socket.recv_from(&mut buffer) {
            let _ = raw.recv(&mut buffer[..len], quiche::RecvInfo { from, to: local });
        }
        thread::sleep(Duration::from_millis(1));
    };
    drop(child.stdin.take());
    assert!(!status.success());
    let mut stderr = String::new();
    child
        .stderr
        .take()
        .unwrap()
        .read_to_string(&mut stderr)
        .unwrap();
    let mut stdout = vec![];
    child
        .stdout
        .take()
        .unwrap()
        .read_to_end(&mut stdout)
        .unwrap();
    assert!(stdout.is_empty());
    assert!(stderr.contains("peer_origin=EndpointRetired"), "{stderr}");
    assert!(
        stderr.contains("peer_tls_failure=MissingCertificate"),
        "{stderr}"
    );
    assert!(
        stderr.contains("peer_echo_datagrams=0") && stderr.contains("peer_echo_reliable=0"),
        "{stderr}"
    );
}

#[test]
fn ephemeral_identity_is_p256_and_no_more_than_one_hour() {
    let a = Identity::generate().unwrap();
    let b = Identity::generate().unwrap();
    assert_ne!(a.fingerprint(), b.fingerprint());
    let cert = boring::x509::X509::from_der(&a.certificate_der().unwrap()).unwrap();
    assert_eq!(
        cert.public_key()
            .unwrap()
            .ec_key()
            .unwrap()
            .group()
            .curve_name(),
        Some(boring::nid::Nid::X9_62_PRIME256V1)
    );
    let lifetime = cert.not_before().diff(cert.not_after()).unwrap();
    assert_eq!(lifetime.days, 0);
    assert!(lifetime.secs > 0 && lifetime.secs <= 3600);
}

#[test]
fn server_can_send_first_reliable_application_record() {
    let (mut a, mut b) = pair(true, false, false);
    establish(&mut a, &mut b);
    assert_eq!(a.stats().admitted, 0);
    assert_eq!(
        b.send(message(Lane::Reliable, 42, 5), Instant::now()),
        Admission::Accepted
    );
    pump_until(&mut a, &mut b, Duration::from_secs(1), |a, _| {
        a.stats().delivered == 1
    });
    let got = a.receive().unwrap();
    assert_eq!(got.sequence, 42);
    assert_eq!(got.payload, [0x5a; 5]);
}

#[test]
fn receive_queue_exhaustion_and_ack_accounting_remain_bounded() {
    let (mut a, mut b) = pair(true, false, false);
    establish(&mut a, &mut b);
    let end = Instant::now() + Duration::from_millis(600);
    let mut sequence = 0;
    while Instant::now() < end {
        if a.send(message(Lane::Reliable, sequence, 1024), Instant::now()) == Admission::Accepted {
            sequence += 1;
        }
        a.poll().unwrap();
        b.poll().unwrap();
        assert!(a.stats().reliable_backlog_bytes <= 65536);
        assert!(a.stats().generated_packets <= 32);
        assert!(b.stats().receive_queue_records <= 64);
        assert!(b.stats().receive_queue_bytes <= 65536);
        thread::sleep(Duration::from_millis(1));
    }
    assert!(b.stats().receive_queue_records >= 60);
    assert!(sequence > 60, "ACKed allocations release admission budget");
    let mut expected = 0;
    let end = Instant::now() + Duration::from_secs(2);
    while Instant::now() < end && expected < sequence {
        a.poll().unwrap();
        b.poll().unwrap();
        while let Some(got) = b.receive() {
            assert_eq!(got.sequence, expected);
            expected += 1;
        }
        thread::sleep(Duration::from_millis(1));
    }
    assert_eq!(
        expected, sequence,
        "reliable prefix survives receive backpressure"
    );
    pump_until(&mut a, &mut b, Duration::from_secs(1), |a, _| {
        a.stats().reliable_backlog_bytes == 0
    });
    assert_eq!(a.stats().reliable_backlog_bytes, 0);
}

struct Relay {
    socket: std::net::UdpSocket,
    client: Option<SocketAddr>,
    server: SocketAddr,
    captured: Vec<Vec<u8>>,
}

struct RawPeer {
    socket: std::net::UdpSocket,
    connection: Option<quiche::Connection>,
    config: quiche::Config,
    peer: Option<SocketAddr>,
}
impl RawPeer {
    fn server(config: quiche::Config) -> Self {
        let socket = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        socket.set_nonblocking(true).unwrap();
        Self {
            socket,
            connection: None,
            config,
            peer: None,
        }
    }
    fn client(config: quiche::Config, peer: SocketAddr) -> Self {
        let mut raw = Self::server(config);
        let mut cid = [0; 16];
        boring::rand::rand_bytes(&mut cid).unwrap();
        raw.connection = Some(
            quiche::connect(
                None,
                &quiche::ConnectionId::from_ref(&cid),
                raw.socket.local_addr().unwrap(),
                peer,
                &mut raw.config,
            )
            .unwrap(),
        );
        raw.peer = Some(peer);
        raw
    }
    fn poll(&mut self) {
        let local = self.socket.local_addr().unwrap();
        for _ in 0..64 {
            let mut bytes = [0; 1200];
            let Ok((len, from)) = self.socket.recv_from(&mut bytes) else {
                break;
            };
            if self.connection.is_none() {
                let header =
                    quiche::Header::from_slice(&mut bytes[..len], quiche::MAX_CONN_ID_LEN).unwrap();
                self.connection = Some(
                    quiche::accept(&header.dcid, None, local, from, &mut self.config).unwrap(),
                );
                self.peer = Some(from);
            }
            let _ = self
                .connection
                .as_mut()
                .unwrap()
                .recv(&mut bytes[..len], quiche::RecvInfo { from, to: local });
        }
        if let Some(connection) = self.connection.as_mut() {
            if connection.timeout().is_some_and(|t| t.is_zero()) {
                connection.on_timeout();
            }
            for _ in 0..32 {
                let mut bytes = [0; 1200];
                let Ok((len, info)) = connection.send(&mut bytes) else {
                    break;
                };
                if let Some(delay) = info.at.checked_duration_since(Instant::now()) {
                    assert!(delay < Duration::from_millis(100));
                    thread::sleep(delay);
                }
                self.socket.send_to(&bytes[..len], info.to).unwrap();
            }
        }
    }
    fn pump(&mut self, endpoint: &mut Endpoint, duration: Duration) {
        let end = Instant::now() + duration;
        while Instant::now() < end {
            endpoint.poll().unwrap();
            self.poll();
            thread::sleep(Duration::from_millis(1));
        }
    }
    fn send_stream(&mut self, bytes: &[u8]) {
        assert_eq!(
            self.connection
                .as_mut()
                .unwrap()
                .stream_send(0, bytes, false)
                .unwrap(),
            bytes.len()
        );
    }
}
fn session_preface(magic: &[u8; 4], session: u8) -> Vec<u8> {
    let mut bytes = vec![0, 0, 0, 36];
    bytes.extend_from_slice(magic);
    bytes.extend_from_slice(&[session; 32]);
    bytes
}

#[test]
fn tls_alone_cannot_admit_datagrams_and_duplicate_hello_is_terminal() {
    let identity = Identity::generate().unwrap();
    let (config, pin) =
        raw_client_context(true, galaxybridge_quic::tls::ALPN, identity.fingerprint());
    let mut endpoint = Endpoint::listen(
        "127.0.0.1:0".parse().unwrap(),
        "127.0.0.1".parse().unwrap(),
        [1; 32],
        identity,
        pin,
    )
    .unwrap();
    let mut raw = RawPeer::client(config, endpoint.local_addr().unwrap());
    raw.pump(&mut endpoint, Duration::from_millis(100));
    assert!(endpoint.stats().authenticated);
    assert!(!endpoint.stats().application_ready);
    let bytes = galaxybridge_quic::wire::encode(&[1; 32], &message(Lane::Datagram, 1, 1)).unwrap();
    raw.connection.as_mut().unwrap().dgram_send(&bytes).unwrap();
    raw.pump(&mut endpoint, Duration::from_millis(30));
    assert_eq!(endpoint.stats().delivered, 0);
    assert!(endpoint.stats().rejected > 0);
    raw.connection
        .as_mut()
        .unwrap()
        .dgram_send(&[0; 1100])
        .unwrap();
    raw.pump(&mut endpoint, Duration::from_millis(20));
    assert!(
        !endpoint.stats().retired,
        "all pre-ready datagrams are discarded without parsing"
    );
    raw.send_stream(&session_preface(b"GQH1", 1));
    raw.pump(&mut endpoint, Duration::from_millis(30));
    assert!(endpoint.stats().application_ready);
    assert_eq!(
        endpoint.stats().delivered,
        0,
        "preface is not application data"
    );
    raw.send_stream(&session_preface(b"GQH1", 1));
    raw.pump(&mut endpoint, Duration::from_millis(30));
    assert!(endpoint.stats().retired);
    assert_eq!(endpoint.stats().delivered, 0);
}

#[test]
fn keepalive_authenticated_quiet_pair_survives_eleven_seconds_then_both_lanes() {
    let (mut a, mut b) = pair(true, false, false);
    establish(&mut a, &mut b);
    let addresses = (a.local_addr().unwrap(), b.local_addr().unwrap());
    let started = Instant::now();
    pump_until(&mut a, &mut b, Duration::from_secs(11), |a, b| {
        a.stats().retired || b.stats().retired
    });
    assert!(
        !a.stats().retired && !b.stats().retired,
        "quiet authenticated pair retired after {:?}: {:?}/{:?}",
        started.elapsed(),
        a.stats().retirement,
        b.stats().retirement
    );
    assert!(started.elapsed() >= Duration::from_secs(11));
    assert_eq!((a.stats().admitted, b.stats().admitted), (0, 0));
    assert_eq!(
        (a.local_addr().unwrap(), b.local_addr().unwrap()),
        addresses
    );
    for endpoint in [&mut a, &mut b] {
        for lane in [Lane::Reliable, Lane::Datagram] {
            assert_eq!(
                endpoint.send(
                    message(lane, 19, 16),
                    Instant::now() + Duration::from_secs(1)
                ),
                Admission::Accepted
            );
        }
    }
    pump_until(&mut a, &mut b, Duration::from_secs(1), |a, b| {
        a.stats().receive_queue_records == 2 && b.stats().receive_queue_records == 2
    });
    for endpoint in [&mut a, &mut b] {
        let mut lanes = Vec::new();
        while let Some(got) = endpoint.receive() {
            assert_eq!(got.sequence, 19);
            assert_eq!(got.payload, vec![0x5a; 16]);
            lanes.push(got.lane);
        }
        assert_eq!(lanes.len(), 2);
        assert!(lanes.contains(&Lane::Reliable) && lanes.contains(&Lane::Datagram));
        endpoint.close();
        assert!(endpoint.stats().retired);
    }
    println!("quiet real pair survived {:?}; same endpoints, no application keepalive, both lanes and close",started.elapsed());
}

#[test]
fn malformed_unexpected_and_wrong_session_prefaces_retire_server() {
    for bad in [
        session_preface(b"GQH2", 1),
        session_preface(b"GQA1", 1),
        session_preface(b"GQH1", 2),
        vec![0, 0, 0, 35],
    ] {
        let identity = Identity::generate().unwrap();
        let (config, pin) =
            raw_client_context(true, galaxybridge_quic::tls::ALPN, identity.fingerprint());
        let mut endpoint = Endpoint::listen(
            "127.0.0.1:0".parse().unwrap(),
            "127.0.0.1".parse().unwrap(),
            [1; 32],
            identity,
            pin,
        )
        .unwrap();
        let mut raw = RawPeer::client(config, endpoint.local_addr().unwrap());
        raw.pump(&mut endpoint, Duration::from_millis(80));
        assert!(endpoint.stats().authenticated);
        raw.send_stream(&bad);
        raw.pump(&mut endpoint, Duration::from_millis(30));
        assert!(endpoint.stats().retired);
        assert_eq!(endpoint.stats().delivered, 0);
    }
}

#[test]
fn keepalive_unanswered_peer_still_retires_without_local_renewal() {
    let (mut a, mut b) = pair(true, false, false);
    establish(&mut a, &mut b);
    // Drain handshake acknowledgements, then never service the exact peer.
    pump_until(&mut a, &mut b, Duration::from_millis(100), |_, _| false);
    let started = Instant::now();
    while !a.stats().retired && started.elapsed() < Duration::from_secs(12) {
        a.poll().unwrap();
        thread::sleep(Duration::from_millis(1));
    }
    assert_eq!(
        a.diagnostics().retirement,
        Some(galaxybridge_quic::endpoint::Retirement::PeerIdle)
    );
    assert!(started.elapsed() >= Duration::from_secs(5));
    assert!(
        started.elapsed() < Duration::from_secs(12),
        "native idle/PTO watchdog, not a renewed application timer"
    );
    assert_eq!(a.stats().generated_packets, 0);
    assert_eq!(a.stats().admitted, 0);
    let packets = a.stats().sent_udp_packets;
    a.poll().unwrap();
    assert_eq!(a.stats().sent_udp_packets, packets);
    b.close();
    println!(
        "unanswered real peer native expiry {:?}, no local renewal, closed",
        started.elapsed()
    );
}

#[test]
fn mismatched_server_ack_and_application_before_ack_retire_client() {
    let application =
        galaxybridge_quic::wire::encode_reliable(&[1; 32], &message(Lane::Reliable, 1, 1)).unwrap();
    for bad in [
        session_preface(b"GQA1", 2),
        session_preface(b"GQH1", 1),
        application,
    ] {
        let identity = Identity::generate().unwrap();
        let (config, pin) =
            raw_client_context(true, galaxybridge_quic::tls::ALPN, identity.fingerprint());
        let mut raw = RawPeer::server(config);
        let mut endpoint = Endpoint::connect(
            "127.0.0.1:0".parse().unwrap(),
            raw.socket.local_addr().unwrap(),
            [1; 32],
            identity,
            pin,
        )
        .unwrap();
        raw.pump(&mut endpoint, Duration::from_millis(100));
        assert!(endpoint.stats().authenticated);
        assert!(!endpoint.stats().application_ready);
        assert_eq!(
            endpoint.send(message(Lane::Reliable, 9, 1), Instant::now()),
            Admission::Backpressured
        );
        let mut hello = [0; 40];
        assert_eq!(
            raw.connection
                .as_mut()
                .unwrap()
                .stream_recv(0, &mut hello)
                .unwrap(),
            (40, false)
        );
        assert_eq!(hello.as_slice(), session_preface(b"GQH1", 1));
        raw.send_stream(&bad);
        raw.pump(&mut endpoint, Duration::from_millis(30));
        assert!(endpoint.stats().retired);
        assert_eq!(endpoint.stats().delivered, 0);
    }
}
impl Relay {
    fn new(server: SocketAddr) -> Self {
        let socket = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        socket.set_nonblocking(true).unwrap();
        Self {
            socket,
            client: None,
            server,
            captured: vec![],
        }
    }
    fn forward(&mut self, capture: bool) {
        for _ in 0..64 {
            let mut bytes = [0; 1200];
            let Ok((len, from)) = self.socket.recv_from(&mut bytes) else {
                break;
            };
            let to = if from == self.server {
                self.client.unwrap()
            } else {
                self.client = Some(from);
                if capture && self.captured.len() < 64 {
                    self.captured.push(bytes[..len].to_vec());
                }
                self.server
            };
            self.socket.send_to(&bytes[..len], to).unwrap();
        }
    }
    fn pump(&mut self, a: &mut Endpoint, b: &mut Endpoint, duration: Duration, capture: bool) {
        let end = Instant::now() + duration;
        while Instant::now() < end {
            a.poll().unwrap();
            self.forward(capture);
            b.poll().unwrap();
            self.forward(capture);
            thread::sleep(Duration::from_millis(1));
        }
    }
}

#[test]
fn old_attempt_ciphertext_replayed_on_selected_path_yields_zero_successor_deliveries() {
    let a_id = Identity::generate().unwrap();
    let b_id = Identity::generate().unwrap();
    let a_pin = a_id.fingerprint();
    let b_pin = b_id.fingerprint();
    let mut b = Endpoint::listen(
        "127.0.0.1:0".parse().unwrap(),
        "127.0.0.1".parse().unwrap(),
        [1; 32],
        b_id,
        a_pin,
    )
    .unwrap();
    let mut relay = Relay::new(b.local_addr().unwrap());
    let mut a = Endpoint::connect(
        "127.0.0.1:0".parse().unwrap(),
        relay.socket.local_addr().unwrap(),
        [1; 32],
        a_id,
        b_pin,
    )
    .unwrap();
    relay.pump(&mut a, &mut b, Duration::from_millis(100), false);
    assert!(a.stats().application_ready && b.stats().application_ready);
    for lane in [Lane::Datagram, Lane::Reliable] {
        assert_eq!(
            a.send(
                message(lane, 11, 8),
                Instant::now() + Duration::from_secs(1)
            ),
            Admission::Accepted
        );
    }
    relay.pump(&mut a, &mut b, Duration::from_millis(100), true);
    assert_eq!(b.stats().delivered, 2);
    assert!(!relay.captured.is_empty());
    let old_server = b.local_addr().unwrap();
    a.close();
    b.close();
    let a_id = Identity::generate().unwrap();
    let b_id = Identity::generate().unwrap();
    let a_pin = a_id.fingerprint();
    let b_pin = b_id.fingerprint();
    let mut b = Endpoint::listen(
        old_server,
        "127.0.0.1".parse().unwrap(),
        [2; 32],
        b_id,
        a_pin,
    )
    .unwrap();
    let mut a = Endpoint::connect(
        "127.0.0.1:0".parse().unwrap(),
        relay.socket.local_addr().unwrap(),
        [2; 32],
        a_id,
        b_pin,
    )
    .unwrap();
    relay.client = None;
    relay.pump(&mut a, &mut b, Duration::from_millis(100), false);
    assert!(a.stats().application_ready && b.stats().application_ready);
    for bytes in &relay.captured {
        relay.socket.send_to(bytes, old_server).unwrap();
    }
    relay.pump(&mut a, &mut b, Duration::from_millis(100), false);
    assert_eq!(b.stats().delivered, 0);
    assert!(b.receive().is_none());
    assert!(
        b.stats().application_ready,
        "unauthenticated replay must not replace a valid attempt"
    );
}
