use galaxybridge_quic::{
    bootstrap::{Reply, Request},
    wire, Lane, Message,
};

// Independent GQ01 bytes: session 00..1f, sequence 0102030405060708, length 1.
const GOLDEN: [u8; 48] = [
    0x47, 0x51, 0x30, 0x31, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19,
    20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 0, 1, 2, 3, 4, 5, 6, 7, 8, 0, 1, 0x7f,
];
const SESSION: [u8; 32] = [
    0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25,
    26, 27, 28, 29, 30, 31,
];

#[test]
fn literal_wire_golden_proves_endianness_and_layout() {
    let msg = Message {
        lane: Lane::Datagram,
        sequence: 0x0102030405060708,
        payload: vec![0x7f],
    };
    assert_eq!(wire::encode(&SESSION, &msg).unwrap(), GOLDEN);
    let got = wire::decode(&GOLDEN, &SESSION, Lane::Datagram).unwrap();
    assert_eq!(got.lane, Lane::Datagram);
    assert_eq!(got.sequence, 0x0102030405060708);
    assert_eq!(got.payload, [0x7f]);
}

#[test]
fn wire_rejects_every_truncation_trailing_wrong_session_lane_and_version() {
    for n in 0..GOLDEN.len() {
        assert!(wire::decode(&GOLDEN[..n], &SESSION, Lane::Datagram).is_err());
    }
    for (index, value) in [(3, b'2'), (4, 0xff), (36, 2), (45, 4), (46, 2)] {
        let mut bad = GOLDEN;
        bad[index] = value;
        assert!(
            wire::decode(&bad, &SESSION, Lane::Datagram).is_err(),
            "index {index}"
        );
    }
    let mut trailing = GOLDEN.to_vec();
    trailing.push(0);
    assert!(wire::decode(&trailing, &SESSION, Lane::Datagram).is_err());
    assert!(wire::decode(&GOLDEN, &[0xff; 32], Lane::Datagram).is_err());
    assert!(wire::decode(&GOLDEN, &SESSION, Lane::Reliable).is_err());
}

#[test]
fn exact_max_payload_and_reliable_record_boundary() {
    let mut msg = Message {
        lane: Lane::Reliable,
        sequence: 9,
        payload: vec![0x55; 1024],
    };
    let encoded = wire::encode_reliable(&SESSION, &msg).unwrap();
    assert_eq!(&encoded[..4], &[0, 0, 4, 47]); // 47-byte envelope + 1024.
    assert_eq!(encoded.len(), 1075);
    assert_eq!(
        wire::decode_reliable(&encoded, &SESSION).unwrap().payload,
        vec![0x55; 1024]
    );
    for n in 0..encoded.len() {
        assert!(wire::decode_reliable(&encoded[..n], &SESSION).is_err());
    }
    let mut bad = encoded.clone();
    bad.push(1);
    assert!(wire::decode_reliable(&bad, &SESSION).is_err());
    bad = encoded;
    bad[..4].copy_from_slice(&[0xff; 4]);
    assert!(wire::decode_reliable(&bad, &SESSION).is_err());
    msg.payload.push(0);
    assert!(wire::encode(&SESSION, &msg).is_err());
    assert!(wire::encode_reliable(&SESSION, &msg).is_err());
}

#[test]
fn bootstrap_has_literal_prefix_version_ip_and_port() {
    let request = Request {
        session: [0x11; 32],
        fingerprint: [0x22; 32],
        expected_ip: "127.0.0.1".parse().unwrap(),
    };
    let mut expected = vec![0, 0, 0, 70, 1];
    expected.extend_from_slice(&[0x11; 32]);
    expected.extend_from_slice(&[0x22; 32]);
    expected.extend_from_slice(&[4, 127, 0, 0, 1]);
    assert_eq!(request.encode().unwrap(), expected);
    assert_eq!(Request::decode(&expected).unwrap(), request);
    let reply = Reply {
        session: [0x11; 32],
        fingerprint: [0x33; 32],
        port: 0x1234,
    };
    let mut expected = vec![0, 0, 0, 67, 1];
    expected.extend_from_slice(&[0x11; 32]);
    expected.extend_from_slice(&[0x33; 32]);
    expected.extend_from_slice(&[0x12, 0x34]);
    assert_eq!(reply.encode().unwrap(), expected);
    assert_eq!(Reply::decode(&expected, &[0x11; 32]).unwrap(), reply);
    assert!(Reply::decode(&expected, &[0x44; 32]).is_err());
}

#[test]
fn bootstrap_rejects_malformed_and_accepts_ipv6_boundary() {
    let req = Request {
        session: [1; 32],
        fingerprint: [2; 32],
        expected_ip: "::1".parse().unwrap(),
    };
    let bytes = req.encode().unwrap();
    assert_eq!(bytes.len(), 86);
    assert_eq!(Request::decode(&bytes).unwrap(), req);
    for n in 0..bytes.len() {
        assert!(Request::decode(&bytes[..n]).is_err());
    }
    for (index, value) in [(3, 83), (4, 2), (69, 5)] {
        let mut bad = bytes.clone();
        bad[index] = value;
        assert!(Request::decode(&bad).is_err());
    }
    let mut trailing = bytes;
    trailing.push(0);
    assert!(Request::decode(&trailing).is_err());
    assert!(Request::decode(&[0, 0, 16, 1]).is_err());
    assert!(Reply {
        session: [1; 32],
        fingerprint: [2; 32],
        port: 0
    }
    .encode()
    .is_err());
    assert!(Request {
        expected_ip: "0.0.0.0".parse().unwrap(),
        ..req
    }
    .encode()
    .is_err());
}

#[test]
fn probe_self_test_is_loopback_only_and_reports_scalar_success() {
    use std::{io::Read, process::Stdio, time::Duration};
    let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_gb-quic-probe"))
        .arg("--self-test")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    assert!(wait_child(&mut child, Duration::from_secs(4)).success());
    let mut stdout = vec![];
    let mut stderr = String::new();
    child
        .stdout
        .take()
        .unwrap()
        .read_to_end(&mut stdout)
        .unwrap();
    child
        .stderr
        .take()
        .unwrap()
        .read_to_string(&mut stderr)
        .unwrap();
    assert!(stdout.is_empty());
    assert!(stderr.contains("delivered=4"));
}

fn read_reply(child: &mut std::process::Child) -> [u8; 71] {
    use std::{
        io::Read,
        os::fd::AsRawFd,
        time::{Duration, Instant},
    };
    let deadline = Instant::now() + Duration::from_secs(2);
    let mut bytes = [0; 71];
    let mut used = 0;
    while used < bytes.len() {
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("protected bootstrap reply deadline");
        }
        let stdout = child.stdout.as_mut().unwrap();
        let mut pfd = libc::pollfd {
            fd: stdout.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: initialized descriptor structure referencing live child pipe.
        if unsafe { libc::poll(&mut pfd, 1, 10) } > 0 {
            let count = stdout.read(&mut bytes[used..]).unwrap();
            if count == 0 {
                let _ = child.wait();
                panic!("probe exited without a complete reply");
            }
            used += count;
        }
    }
    bytes
}

fn wait_child(
    child: &mut std::process::Child,
    limit: std::time::Duration,
) -> std::process::ExitStatus {
    let end = std::time::Instant::now() + limit;
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return status;
        }
        if std::time::Instant::now() >= end {
            child.kill().unwrap();
            child.wait().unwrap();
            panic!("owned probe did not exit within deadline");
        }
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
}

#[test]
fn protected_stdio_reply_and_eof_retire_owned_peer() {
    use std::{
        io::{Read, Write},
        process::{Command, Stdio},
        time::Duration,
    };
    let identity = galaxybridge_quic::tls::Identity::generate().unwrap();
    let request = Request {
        session: [0x33; 32],
        fingerprint: identity.fingerprint(),
        expected_ip: "127.0.0.1".parse().unwrap(),
    };
    let mut child = Command::new(env!("CARGO_BIN_EXE_gb-quic-probe"))
        .args(["--stdio-peer", "--duration-ms", "1000"])
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
    let reply = read_reply(&mut child);
    let reply = Reply::decode(&reply, &request.session).unwrap();
    assert!(reply.port > 0);
    assert_ne!(reply.fingerprint, [0; 32]);
    let started = std::time::Instant::now();
    drop(child.stdin.take());
    assert!(wait_child(&mut child, Duration::from_millis(500)).success());
    assert!(started.elapsed() < Duration::from_millis(500));
    let mut trailing = vec![];
    child
        .stdout
        .take()
        .unwrap()
        .read_to_end(&mut trailing)
        .unwrap();
    assert!(trailing.is_empty());
    assert!(std::net::UdpSocket::bind(("127.0.0.1", reply.port)).is_ok());
}

#[test]
fn stdio_programmatic_client_exchanges_both_lanes_and_lifetime_is_bounded() {
    use galaxybridge_quic::{Admission, Endpoint, Lane, Message};
    use std::{
        io::Write,
        process::{Command, Stdio},
        thread,
        time::{Duration, Instant},
    };
    let identity = galaxybridge_quic::tls::Identity::generate().unwrap();
    let request = Request {
        session: [0x44; 32],
        fingerprint: identity.fingerprint(),
        expected_ip: "127.0.0.1".parse().unwrap(),
    };
    let mut child = Command::new(env!("CARGO_BIN_EXE_gb-quic-probe"))
        .args(["--stdio-peer", "--duration-ms", "500"])
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
    let reply = Reply::decode(&read_reply(&mut child), &request.session).unwrap();
    let mut endpoint = Endpoint::connect(
        "127.0.0.1:0".parse().unwrap(),
        ("127.0.0.1".parse::<std::net::IpAddr>().unwrap(), reply.port).into(),
        request.session,
        identity,
        reply.fingerprint,
    )
    .unwrap();
    let end = Instant::now() + Duration::from_millis(400);
    let mut submitted = false;
    while Instant::now() < end && endpoint.stats().delivered < 2 {
        endpoint.poll().unwrap();
        if endpoint.stats().application_ready && !submitted {
            for lane in [Lane::Datagram, Lane::Reliable] {
                assert_eq!(
                    endpoint.send(
                        Message {
                            lane,
                            sequence: 9,
                            payload: vec![0x7f]
                        },
                        Instant::now() + Duration::from_millis(200)
                    ),
                    Admission::Accepted
                );
            }
            submitted = true;
        }
        thread::sleep(Duration::from_millis(1));
    }
    assert_eq!(endpoint.stats().delivered, 2);
    for _ in 0..2 {
        let got = endpoint.receive().unwrap();
        assert_eq!(got.sequence, 9);
        assert_eq!(got.payload, [0x7f]);
    }
    // stdin remains open: the explicit lifetime alone must retire the peer.
    assert!(wait_child(&mut child, Duration::from_millis(700)).success());
    endpoint.close();
}

#[test]
fn stdio_client_cli_owns_loopback_child_and_confirms_both_lanes() {
    use std::{
        io::Read,
        process::{Command, Stdio},
        time::Duration,
    };
    let executable = env!("CARGO_BIN_EXE_gb-quic-probe");
    let mut child = Command::new(executable)
        .args([
            "--stdio-client",
            "--peer-ip",
            "127.0.0.1",
            "--local-ip",
            "127.0.0.1",
            "--duration-ms",
            "120",
            "--",
            executable,
            "--stdio-peer",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    assert!(wait_child(&mut child, Duration::from_secs(4)).success());
    let mut stdout = vec![];
    let mut stderr = String::new();
    child
        .stdout
        .take()
        .unwrap()
        .read_to_end(&mut stdout)
        .unwrap();
    child
        .stderr
        .take()
        .unwrap()
        .read_to_string(&mut stderr)
        .unwrap();
    assert!(stdout.is_empty());
    assert!(
        stderr.contains("client=pass")
            && stderr.contains("lanes_completed=2")
            && stderr.contains("cleanup=1"),
        "{stderr}"
    );
    assert!(stderr.contains("client_origin=Completed"), "{stderr}");
    assert!(stderr.contains("peer_origin=StdinEof"), "{stderr}");
    assert!(
        stderr.contains("peer_echo_datagrams=") && stderr.contains("client_datagrams_udp_sent="),
        "{stderr}"
    );
    for role in ["peer", "client"] {
        assert!(
            stderr
                .split_whitespace()
                .any(|s| s == format!("{role}_path_terminal=1")),
            "actual owner must commit terminal path: {stderr}"
        );
        assert!(
            stderr
                .split_whitespace()
                .any(|s| s == format!("{role}_owner_valid=1")),
            "{stderr}"
        );
        for name in ["owner_turns", "owner_poll_count", "owner_step_count"] {
            let key = format!("{role}_{name}=");
            let count: u64 = stderr
                .split_whitespace()
                .find_map(|s| s.strip_prefix(&key))
                .unwrap()
                .parse()
                .unwrap();
            assert!(count > 0, "real owner hook absent: {stderr}");
        }
        for key in [
            "udp_would_block",
            "generated_write_age_count",
            "owner_turns",
            "socket_send_available",
            "path_samples",
        ] {
            assert!(
                stderr.contains(&format!("{role}_{key}=")),
                "missing {role}_{key}: {stderr}"
            );
        }
        for (name, expected) in [
            ("datagram_observation_valid", "1"),
            ("datagram_observation_failures", "0"),
            ("receive_resource_failure", "0"),
            ("quiche_datagrams_evicted", "0"),
            ("quiche_datagrams_pending_records", "0"),
            ("quiche_datagrams_pending_bytes", "0"),
        ] {
            assert!(
                stderr
                    .split_whitespace()
                    .any(|s| s == format!("{role}_{name}={expected}")),
                "{stderr}"
            );
        }
        for name in ["quiche_datagrams_decoded", "datagrams_extracted"] {
            let key = format!("{role}_{name}=");
            let value: u64 = stderr
                .split_whitespace()
                .find_map(|s| s.strip_prefix(&key))
                .unwrap()
                .parse()
                .unwrap();
            assert!(value > 0, "{stderr}");
        }
    }
    // Diagnostics contain only fixed ASCII keys and scalar/enum values.
    // No raw peer strings or binary bootstrap/certificate/payload dumps.
    for token in stderr.split_whitespace() {
        let (key, value) = token.split_once('=').expect("scalar diagnostic");
        assert!(!key.is_empty() && key.bytes().all(|c| c.is_ascii_lowercase() || c == b'_'));
        assert!(
            !value.is_empty()
                && value
                    .bytes()
                    .all(|c| c.is_ascii_alphanumeric() || c == b'-')
        );
        assert!(![
            "nonce",
            "pin",
            "key",
            "session",
            "payload",
            "certificate",
            "bootstrap"
        ]
        .contains(&key));
    }
}

#[test]
fn client_rejects_invalid_options_before_spawning_and_reaps_failed_bootstrap() {
    use galaxybridge_quic::bootstrap::{run_stdio_client, ClientOptions, ClientStage};
    use std::time::Duration;
    for duration in [Duration::ZERO, Duration::from_millis(15001)] {
        let error = run_stdio_client(ClientOptions {
            program: "/nonexistent/never-spawn".into(),
            args: vec![],
            peer_ip: "127.0.0.1".parse().unwrap(),
            local_ip: "127.0.0.1".parse().unwrap(),
            duration,
        })
        .unwrap_err();
        assert!(matches!(error.stage, ClientStage::Configuration));
    }
    let error = run_stdio_client(ClientOptions {
        program: env!("CARGO_BIN_EXE_gb-quic-probe").into(),
        args: vec!["--self-test".into()],
        peer_ip: "127.0.0.1".parse().unwrap(),
        local_ip: "127.0.0.1".parse().unwrap(),
        duration: Duration::from_millis(100),
    })
    .unwrap_err();
    assert!(matches!(error.stage, ClientStage::Bootstrap));
    assert!(error.report.cleanup);
    assert!(!error.report.cleanup_forced);
    assert_eq!(error.report.lanes_completed(), 0);
}

#[test]
fn partial_bootstrap_with_open_stdin_obeys_owned_lifetime() {
    use std::{
        io::{Read, Write},
        process::{Command, Stdio},
        time::Duration,
    };
    let mut child = Command::new(env!("CARGO_BIN_EXE_gb-quic-probe"))
        .args(["--stdio-peer", "--duration-ms", "100"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.as_mut().unwrap().write_all(&[0, 0]).unwrap();
    assert!(!wait_child(&mut child, Duration::from_millis(500)).success());
    let mut output = vec![];
    child
        .stdout
        .take()
        .unwrap()
        .read_to_end(&mut output)
        .unwrap();
    assert!(output.is_empty());
}

#[test]
fn incomplete_bootstrap_eof_and_oversized_prefix_exit_without_reply() {
    use std::{
        io::{Read, Write},
        process::{Command, Stdio},
        time::Duration,
    };
    for bytes in [vec![], vec![0, 0], vec![0, 0, 16, 1]] {
        let mut child = Command::new(env!("CARGO_BIN_EXE_gb-quic-probe"))
            .arg("--stdio-peer")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.as_mut().unwrap().write_all(&bytes).unwrap();
        drop(child.stdin.take());
        assert!(!wait_child(&mut child, Duration::from_millis(500)).success());
        let mut output = vec![];
        child
            .stdout
            .take()
            .unwrap()
            .read_to_end(&mut output)
            .unwrap();
        assert!(output.is_empty());
    }
}

// Standalone fixture compiled only into the project-local test target. No
// production mode or mock cryptography: these children never speak QUIC.
const LIFECYCLE_CHILD: &str = r#"
use std::{io::{Read,Write},net::UdpSocket,time::{Duration,Instant},thread};
fn main() {
    let args:Vec<_>=std::env::args().collect();
    if args[1]=="relay" {
        let mut channel=std::os::unix::net::UnixStream::connect(&args[2]).unwrap();
        channel.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        channel.set_write_timeout(Some(Duration::from_secs(5))).unwrap();
        thread::spawn(|| {thread::sleep(Duration::from_secs(10));std::process::exit(3);});
        let mut prefix=[0;4];std::io::stdin().read_exact(&mut prefix).unwrap();
        let length=u32::from_be_bytes(prefix) as usize;assert!(length<=82);
        let mut body=vec![0;length];std::io::stdin().read_exact(&mut body).unwrap();
        channel.write_all(&prefix).unwrap();channel.write_all(&body).unwrap();
        let mut reply=[0;71];channel.read_exact(&mut reply).unwrap();
        std::io::stdout().write_all(&reply).unwrap();std::io::stdout().flush().unwrap();
        let mut byte=[0;1];assert_eq!(std::io::stdin().read(&mut byte).unwrap(),0);
        return;
    }
    std::fs::write(&args[2],std::process::id().to_string()).unwrap();
    // Bound even a regressed parent that never closes stdin or retires us.
    thread::spawn(|| {thread::sleep(Duration::from_secs(10));std::process::exit(3);});
    let mut prefix=[0;4];std::io::stdin().read_exact(&mut prefix).unwrap();
    let length=u32::from_be_bytes(prefix) as usize;
    assert!(length==70 || length==82);
    let mut request=vec![0;length];std::io::stdin().read_exact(&mut request).unwrap();
    assert_eq!(request[0],1);
    let socket=UdpSocket::bind("127.0.0.1:0").unwrap();
    if args[1]=="no-handshake" || args[1]=="stdout-event" {
        let mut reply=vec![0,0,0,67,1];
        reply.extend_from_slice(&request[1..33]);
        reply.extend_from_slice(&[0x66;32]);
        reply.extend_from_slice(&socket.local_addr().unwrap().port().to_be_bytes());
        std::io::stdout().write_all(&reply).unwrap();std::io::stdout().flush().unwrap();
        if args[1]=="stdout-event" {std::io::stdout().write_all(&[0x7f]).unwrap();std::io::stdout().flush().unwrap();}
    } else if args[1]=="ignore-eof" {
        std::io::stdout().write_all(&[0,0,0,0]).unwrap();std::io::stdout().flush().unwrap();
        let end=Instant::now()+Duration::from_secs(10);
        while Instant::now()<end {thread::sleep(Duration::from_millis(10));}
        std::process::exit(3);
    } else {assert_eq!(args[1],"stall-bootstrap");}
    // Hold the socket but never generate QUIC. Exit only after owned stdin EOF.
    let mut byte=[0;1];
    assert_eq!(std::io::stdin().read(&mut byte).unwrap(),0);
}
"#;

fn lifecycle_child() -> &'static std::path::Path {
    static BINARY: std::sync::OnceLock<std::path::PathBuf> = std::sync::OnceLock::new();
    BINARY
        .get_or_init(|| {
            use std::{
                io::Write,
                process::{Command, Stdio},
                time::{SystemTime, UNIX_EPOCH},
            };
            let target = std::env::var_os("CARGO_TARGET_DIR")
                .map(std::path::PathBuf::from)
                .expect("test runner must provide project-local CARGO_TARGET_DIR");
            let directory = target.join(format!(
                "quic-lifecycle-child-{}-{}",
                std::process::id(),
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_nanos()
            ));
            std::fs::create_dir(&directory).unwrap();
            let binary = directory.join("owned-child");
            let rustc = std::env::var_os("RUSTC").expect("test runner must provide prepared RUSTC");
            let mut compiler = Command::new(rustc)
                .args([
                    "--edition=2021",
                    "--crate-name",
                    "quic_lifecycle_child",
                    "-C",
                    "codegen-units=1",
                    "-o",
                ])
                .arg(&binary)
                .arg("-")
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap();
            compiler
                .stdin
                .take()
                .unwrap()
                .write_all(LIFECYCLE_CHILD.as_bytes())
                .unwrap();
            assert!(
                wait_child(&mut compiler, std::time::Duration::from_secs(10)).success(),
                "owned helper must compile"
            );
            binary
        })
        .as_path()
}

fn run_lifecycle_child(mode: &str) -> galaxybridge_quic::bootstrap::ClientFailure {
    use galaxybridge_quic::bootstrap::{run_stdio_client, ClientOptions};
    let binary = lifecycle_child();
    let pid_file = binary.parent().unwrap().join(format!("{mode}.pid"));
    let failure = run_stdio_client(ClientOptions {
        program: binary.to_path_buf(),
        args: vec![mode.into(), pid_file.as_os_str().to_owned()],
        peer_ip: "127.0.0.1".parse().unwrap(),
        local_ip: "127.0.0.1".parse().unwrap(),
        duration: std::time::Duration::from_millis(100),
    })
    .unwrap_err();
    let pid = std::fs::read_to_string(pid_file)
        .unwrap()
        .parse::<libc::pid_t>()
        .unwrap();
    let mut status = 0;
    // SAFETY: exact PID recorded by this test-owned child; waitpid cannot reap
    // or signal an unrelated non-child. ECHILD proves the driver already reaped.
    let waited = unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) };
    assert_eq!(
        waited, -1,
        "driver must already have reaped its owned child"
    );
    assert_eq!(
        std::io::Error::last_os_error().raw_os_error(),
        Some(libc::ECHILD)
    );
    failure
}

#[test]
fn owned_child_valid_bootstrap_without_handshake_counts_one_timeout() {
    use galaxybridge_quic::bootstrap::ClientStage;
    let failure = run_lifecycle_child("no-handshake");
    assert!(matches!(failure.stage, ClientStage::Connect));
    assert_eq!(
        failure.report.terminal.origin,
        galaxybridge_quic::bootstrap::ClientOrigin::EndpointRetired
    );
    assert_eq!(
        failure.report.terminal.endpoint.retirement,
        Some(galaxybridge_quic::endpoint::Retirement::ConnectTimeout)
    );
    assert_eq!(
        failure.report.timeouts, 1,
        "endpoint-owned ConnectTimeout must not bypass diagnostics"
    );
    assert!(failure.report.cleanup);
    assert!(!failure.report.cleanup_forced);
    assert_eq!(failure.report.lanes_completed(), 0);
    assert!((5000..7000).contains(&failure.report.elapsed_ms));
}

#[test]
fn driver_stdout_failure_has_distinct_terminal_origin() {
    let failure = run_lifecycle_child("stdout-event");
    assert_eq!(
        failure.report.terminal.origin,
        galaxybridge_quic::bootstrap::ClientOrigin::StdoutEvent
    );
    assert_eq!(failure.report.timeouts, 0);
    assert!(failure.report.cleanup && !failure.report.cleanup_forced);
}

#[test]
fn driver_constructor_failure_preserves_io_category_and_errno() {
    use galaxybridge_quic::bootstrap::{run_stdio_client, ClientOptions, ClientOrigin, ErrorKind};
    // macOS's unconfigured loopback addresses cannot be bound. Select one by
    // the actual bind result, without touching a LAN interface or its config.
    let local_ip = (2..=254)
        .map(|last| std::net::Ipv4Addr::new(127, 0, 0, last))
        .find(|ip| std::net::UdpSocket::bind((*ip, 0)).is_err())
        .expect("host needs one unconfigured loopback alias for real bind-failure coverage");
    let binary = lifecycle_child();
    let pid_file = binary.parent().unwrap().join("constructor.pid");
    let failure = run_stdio_client(ClientOptions {
        program: binary.to_path_buf(),
        args: vec!["no-handshake".into(), pid_file.into_os_string()],
        peer_ip: "127.0.0.1".parse().unwrap(),
        local_ip: local_ip.into(),
        duration: std::time::Duration::from_millis(100),
    })
    .unwrap_err();
    assert_eq!(failure.report.terminal.origin, ClientOrigin::Constructor);
    assert_eq!(failure.report.terminal.error, ErrorKind::Io);
    assert_ne!(failure.report.terminal.errno, 0);
    assert_eq!(failure.report.timeouts, 0);
    assert!(failure.report.cleanup && !failure.report.cleanup_forced);
}

#[test]
fn owned_child_stalling_bootstrap_counts_one_timeout_and_exits_on_eof() {
    use galaxybridge_quic::bootstrap::ClientStage;
    let failure = run_lifecycle_child("stall-bootstrap");
    assert!(matches!(failure.stage, ClientStage::Bootstrap));
    assert_eq!(failure.report.timeouts, 1);
    assert!(failure.report.cleanup);
    assert!(!failure.report.cleanup_forced);
    assert!((5000..7000).contains(&failure.report.elapsed_ms));
}

#[test]
fn owned_child_ignoring_eof_is_killed_and_reaped_after_two_second_grace() {
    use galaxybridge_quic::bootstrap::ClientStage;
    let failure = run_lifecycle_child("ignore-eof");
    assert!(matches!(failure.stage, ClientStage::Bootstrap));
    assert_eq!(
        failure.report.timeouts, 0,
        "malformed bootstrap is not a transport timeout"
    );
    assert!(failure.report.cleanup);
    assert!(failure.report.cleanup_forced);
    assert!(
        (2000..3500).contains(&failure.report.elapsed_ms),
        "2s grace plus bounded scheduling tolerance"
    );
}

// Darwin sockaddr_un has a short pathname bound independent of the build
// directory length. Each test owns a private short directory and one socket.
struct TestSocketDirectory(std::path::PathBuf);
impl TestSocketDirectory {
    fn new() -> Self {
        use std::{
            os::unix::fs::DirBuilderExt,
            sync::atomic::{AtomicUsize, Ordering},
        };
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        for _ in 0..100 {
            let directory = std::path::Path::new("/tmp").join(format!(
                "gbq-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            match std::fs::DirBuilder::new().mode(0o700).create(&directory) {
                Ok(()) => return Self(directory),
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => panic!("private test socket directory: {error}"),
            }
        }
        panic!("could not allocate a private test socket directory");
    }
    fn socket(&self) -> std::path::PathBuf {
        self.0.join("s")
    }
}
impl Drop for TestSocketDirectory {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(self.socket());
        let _ = std::fs::remove_dir(&self.0);
    }
}

// Private local stream carries bootstrap only in memory. The owned child
// relays it; the test thread is a genuine authenticated UDP peer.
fn relay_attempt(
    serve: impl FnOnce(std::os::unix::net::UnixStream) + Send + 'static,
    duration: std::time::Duration,
) -> Result<galaxybridge_quic::bootstrap::ClientReport, galaxybridge_quic::bootstrap::ClientFailure>
{
    use std::os::unix::net::UnixListener;
    let socket_directory = TestSocketDirectory::new();
    let path = socket_directory.socket();
    let listener = UnixListener::bind(&path).unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    listener.set_nonblocking(true).unwrap();
    let server = std::thread::spawn(move || {
        let end = std::time::Instant::now() + std::time::Duration::from_secs(3);
        loop {
            match listener.accept() {
                Ok((channel, _)) => {
                    serve(channel);
                    break;
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                    assert!(
                        std::time::Instant::now() < end,
                        "owned relay connect deadline"
                    );
                    std::thread::sleep(std::time::Duration::from_millis(1));
                }
                Err(e) => panic!("owned relay accept: {:?}", e.kind()),
            }
        }
    });
    let result = galaxybridge_quic::bootstrap::run_stdio_client(
        galaxybridge_quic::bootstrap::ClientOptions {
            program: lifecycle_child().to_path_buf(),
            args: vec!["relay".into(), path.as_os_str().to_owned()],
            peer_ip: "127.0.0.1".parse().unwrap(),
            local_ip: "127.0.0.1".parse().unwrap(),
            duration,
        },
    );
    server.join().unwrap();
    std::fs::remove_file(path).unwrap(); // only this test's socket inode
    result
}

#[test]
fn accepted_relay_stream_waits_for_delayed_prefix_with_existing_timeout() {
    use std::{
        io::Write,
        os::{
            fd::AsRawFd,
            unix::net::{UnixListener, UnixStream},
        },
        time::{Duration, Instant},
    };
    let socket_directory = TestSocketDirectory::new();
    let path = socket_directory.socket();
    let listener = UnixListener::bind(&path).unwrap();
    listener.set_nonblocking(true).unwrap();
    let mut sender = UnixStream::connect(&path).unwrap();
    sender
        .set_write_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    let (mut channel, _) = listener.accept().unwrap();
    // F_GETFL only reads flags on this live, owned accepted descriptor.
    let before = unsafe { libc::fcntl(channel.as_raw_fd(), libc::F_GETFL) };
    assert!(before >= 0);
    eprintln!(
        "h2 accepted_nonblocking={} initial_read_timeout={:?}",
        before & libc::O_NONBLOCK != 0,
        channel.read_timeout().unwrap()
    );
    let expected = Request {
        session: [0x11; 32],
        fingerprint: [0x22; 32],
        expected_ip: "127.0.0.1".parse().unwrap(),
    };
    let bytes = expected.encode().unwrap();
    let writer = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(20));
        sender.write_all(&bytes).unwrap();
    });
    let started = Instant::now();
    // Join the bounded writer and remove only our socket even for the RED panic.
    let received =
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| relay_request(&mut channel)));
    let elapsed = started.elapsed();
    let after = unsafe { libc::fcntl(channel.as_raw_fd(), libc::F_GETFL) };
    let read_timeout = channel.read_timeout().unwrap();
    let write_timeout = channel.write_timeout().unwrap();
    writer.join().unwrap();
    std::fs::remove_file(path).unwrap();
    eprintln!("h2 after_nonblocking={} read_timeout={read_timeout:?} write_timeout={write_timeout:?} read_elapsed_us={} request_ok={}",
        after & libc::O_NONBLOCK != 0, elapsed.as_micros(), received.is_ok());
    assert_eq!(received.unwrap(), expected);
    assert!(after >= 0);
    assert_eq!(after & libc::O_NONBLOCK, 0);
    assert_eq!(read_timeout, Some(Duration::from_secs(3)));
    assert_eq!(write_timeout, Some(Duration::from_secs(3)));
    assert!(elapsed < Duration::from_secs(3));
}

fn relay_request(channel: &mut std::os::unix::net::UnixStream) -> Request {
    use std::io::Read;
    // Darwin accept inherits the nonblocking listener flag; these bounded
    // request reads must wait for the owned child to deliver its prefix.
    channel.set_nonblocking(false).unwrap();
    channel
        .set_read_timeout(Some(std::time::Duration::from_secs(3)))
        .unwrap();
    channel
        .set_write_timeout(Some(std::time::Duration::from_secs(3)))
        .unwrap();
    let mut prefix = [0; 4];
    channel.read_exact(&mut prefix).unwrap();
    let length = u32::from_be_bytes(prefix) as usize;
    assert!(length <= 82);
    let mut bytes = vec![0; 4 + length];
    bytes[..4].copy_from_slice(&prefix);
    channel.read_exact(&mut bytes[4..]).unwrap();
    Request::decode(&bytes).unwrap()
}

fn echo_with_loss_and_optional_late_duplicate(
    late: bool,
) -> galaxybridge_quic::bootstrap::ClientFailure {
    use galaxybridge_quic::{tls::Identity, Admission, Endpoint};
    use std::{
        io::{Read, Write},
        time::{Duration, Instant},
    };
    let result = relay_attempt(
        move |mut channel| {
            let request = relay_request(&mut channel);
            let identity = Identity::generate().unwrap();
            let fingerprint = identity.fingerprint();
            let mut endpoint = Endpoint::listen(
                "127.0.0.1:0".parse().unwrap(),
                request.expected_ip,
                request.session,
                identity,
                request.fingerprint,
            )
            .unwrap();
            channel
                .write_all(
                    &Reply {
                        session: request.session,
                        fingerprint,
                        port: endpoint.local_addr().unwrap().port(),
                    }
                    .encode()
                    .unwrap(),
                )
                .unwrap();
            channel.set_nonblocking(true).unwrap();
            let end = Instant::now() + Duration::from_secs(3);
            let mut held: Option<(Message, Instant)> = None;
            while Instant::now() < end {
                let mut byte = [0];
                match channel.read(&mut byte) {
                    Ok(0) => break,
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                    _ => panic!("unexpected owned relay traffic"),
                }
                endpoint.poll().unwrap();
                while let Some(message) = endpoint.receive() {
                    if message.lane == Lane::Datagram {
                        if (!late && message.sequence < 16) || (late && message.sequence == 1) {
                            continue;
                        }
                        if late && message.sequence == 0 {
                            held = Some((
                                Message {
                                    lane: message.lane,
                                    sequence: message.sequence,
                                    payload: message.payload,
                                },
                                Instant::now() + Duration::from_millis(300),
                            ));
                            continue;
                        }
                    }
                    assert_eq!(
                        endpoint.send(
                            Message {
                                lane: message.lane,
                                sequence: message.sequence,
                                payload: message.payload
                            },
                            Instant::now() + Duration::from_millis(200)
                        ),
                        Admission::Accepted
                    );
                }
                if held.as_ref().is_some_and(|(_, at)| *at <= Instant::now()) {
                    let (message, _) = held.take().unwrap();
                    for _ in 0..2 {
                        assert_eq!(
                            endpoint.send(
                                Message {
                                    lane: message.lane,
                                    sequence: message.sequence,
                                    payload: message.payload.clone()
                                },
                                Instant::now() + Duration::from_millis(200)
                            ),
                            Admission::Accepted
                        );
                    }
                }
                std::thread::sleep(Duration::from_millis(1));
            }
            endpoint.close();
        },
        Duration::from_millis(1000),
    )
    .unwrap_err();
    result
}

#[test]
fn late_and_duplicate_datagram_echoes_preserve_missing_verdict() {
    let result = echo_with_loss_and_optional_late_duplicate(true);
    assert_eq!(result.report.datagram_loss(), 1);
    assert_eq!(result.report.duplicates, 1);
    assert!(result.report.datagram_active_peak <= 16);
    assert!(result.report.datagram_credit_expired >= 2);
    assert_eq!(
        result.report.terminal.origin,
        galaxybridge_quic::bootstrap::ClientOrigin::FinalMissing
    );
    assert!(result.report.cleanup && !result.report.cleanup_forced);
}

#[test]
fn sixteen_missing_datagrams_do_not_permanently_stop_driver_admission() {
    let result = echo_with_loss_and_optional_late_duplicate(false);
    assert!(
        result.report.datagrams_sent > 16,
        "lost replies must not permanently occupy credits"
    );
    assert_eq!(result.report.datagram_loss(), 16);
    assert_eq!(result.report.reliable_loss(), 0);
    assert!(result.report.datagram_active_peak <= 16);
    assert!(result.report.datagram_credit_expired >= 16);
    assert_eq!(
        result.report.terminal.origin,
        galaxybridge_quic::bootstrap::ClientOrigin::FinalMissing
    );
    assert!(result.report.terminal.endpoint.reached_tls);
    assert!(result.report.terminal.endpoint.reached_ready);
    assert_eq!(
        result.report.terminal.endpoint.datagrams_admitted,
        result.report.datagrams_sent
    );
    assert!(result.report.terminal.endpoint.datagrams_udp_sent > 16);
    assert!(result.report.cleanup && !result.report.cleanup_forced);
}

fn rejecting_tls_attempt(
    validity: i64,
    wrong_pin: bool,
) -> galaxybridge_quic::bootstrap::ClientFailure {
    use std::{
        io::{Read, Write},
        net::UdpSocket,
        time::{Duration, Instant},
    };
    relay_attempt(
        move |mut channel| {
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
            let request = relay_request(&mut channel);
            let key = PKey::from_ec_key(
                EcKey::generate(&EcGroup::from_curve_name(Nid::X9_62_PRIME256V1).unwrap()).unwrap(),
            )
            .unwrap();
            let mut name = X509NameBuilder::new().unwrap();
            name.append_entry_by_text("CN", "private negative fixture")
                .unwrap();
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
            let (before, after) = match validity {
                1 => (now + 3600, now + 7200),
                -1 => (now - 7200, now - 3600),
                _ => (now, now + 3600),
            };
            cert.set_not_before(&Asn1Time::from_unix(before).unwrap())
                .unwrap();
            cert.set_not_after(&Asn1Time::from_unix(after).unwrap())
                .unwrap();
            cert.sign(&key, MessageDigest::sha256()).unwrap();
            let cert = cert.build();
            let mut fingerprint = boring::sha::sha256(&cert.to_der().unwrap());
            if wrong_pin {
                fingerprint[0] ^= 1;
            }
            let mut ctx = SslContextBuilder::new(SslMethod::tls()).unwrap();
            ctx.set_certificate(&cert).unwrap();
            ctx.set_private_key(&key).unwrap();
            ctx.set_custom_verify_callback(
                SslVerifyMode::PEER | SslVerifyMode::FAIL_IF_NO_PEER_CERT,
                move |ssl| {
                    let reject = || SslVerifyError::Invalid(SslAlert::BAD_CERTIFICATE);
                    let cert = ssl.peer_certificate().ok_or_else(reject)?;
                    let der = cert.to_der().map_err(|_| reject())?;
                    if !boring::memcmp::eq(&boring::sha::sha256(&der), &request.fingerprint) {
                        return Err(reject());
                    }
                    Ok(())
                },
            );
            let mut config =
                quiche::Config::with_boring_ssl_ctx_builder(quiche::PROTOCOL_VERSION, ctx).unwrap();
            config
                .set_application_protos(&[galaxybridge_quic::tls::ALPN])
                .unwrap();
            config.set_max_send_udp_payload_size(1200);
            let socket = UdpSocket::bind("127.0.0.1:0").unwrap();
            socket.set_nonblocking(true).unwrap();
            channel
                .write_all(
                    &Reply {
                        session: request.session,
                        fingerprint,
                        port: socket.local_addr().unwrap().port(),
                    }
                    .encode()
                    .unwrap(),
                )
                .unwrap();
            channel.set_nonblocking(true).unwrap();
            let mut connection: Option<quiche::Connection> = None;
            let end = Instant::now() + Duration::from_secs(3);
            while Instant::now() < end {
                let mut byte = [0];
                if matches!(channel.read(&mut byte), Ok(0)) {
                    return;
                }
                let mut buffer = [0; 1200];
                if let Ok((len, from)) = socket.recv_from(&mut buffer) {
                    if connection.is_none() {
                        let header =
                            quiche::Header::from_slice(&mut buffer[..len], quiche::MAX_CONN_ID_LEN)
                                .unwrap();
                        connection = Some(
                            quiche::accept(
                                &header.dcid,
                                None,
                                socket.local_addr().unwrap(),
                                from,
                                &mut config,
                            )
                            .unwrap(),
                        );
                    }
                    let connection = connection.as_mut().unwrap();
                    let _ = connection.recv(
                        &mut buffer[..len],
                        quiche::RecvInfo {
                            from,
                            to: socket.local_addr().unwrap(),
                        },
                    );
                    while let Ok((length, info)) = connection.send(&mut buffer) {
                        socket.send_to(&buffer[..length], info.to).unwrap();
                    }
                }
                std::thread::sleep(Duration::from_millis(1));
            }
            panic!("negative peer did not observe bounded driver EOF");
        },
        Duration::from_millis(200),
    )
    .unwrap_err()
}

#[test]
fn driver_terminal_diagnostics_distinguish_real_tls_rejections() {
    use galaxybridge_quic::{
        bootstrap::ClientOrigin, endpoint::Retirement, tls::VerificationFailure,
    };
    for (validity, wrong_pin, expected) in [
        (0, true, VerificationFailure::PinMismatch),
        (1, false, VerificationFailure::NotYetValid),
        (-1, false, VerificationFailure::Expired),
    ] {
        let failure = rejecting_tls_attempt(validity, wrong_pin);
        assert!(
            failure.report.terminal.endpoint.udp_socket_received > 0,
            "a TLS-rejected UDP packet still reached the socket"
        );
        assert_eq!(
            failure.report.terminal.origin,
            ClientOrigin::EndpointRetired
        );
        assert_eq!(
            failure.report.terminal.endpoint.retirement,
            Some(Retirement::Authentication)
        );
        assert_eq!(failure.report.terminal.endpoint.tls_failure, expected);
        assert!(!failure.report.terminal.endpoint.reached_ready);
        assert_eq!(failure.report.timeouts, 0);
        assert!(failure.report.cleanup && !failure.report.cleanup_forced);
    }
}
