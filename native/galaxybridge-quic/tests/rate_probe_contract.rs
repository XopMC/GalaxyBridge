use galaxybridge_quic::{
    bootstrap::{run_stdio_rate_client, ClientOptions, ClientOrigin, ClientStage, Reply, Request},
    rate_probe::{RateShape, RateVerdict},
    tls::Identity,
    Admission, Endpoint, Lane, Message,
};
use std::{
    io::Read,
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

fn options(program: std::path::PathBuf, args: Vec<std::ffi::OsString>) -> ClientOptions {
    ClientOptions {
        program,
        args,
        peer_ip: "127.0.0.1".parse().unwrap(),
        local_ip: "127.0.0.1".parse().unwrap(),
        duration: Duration::from_secs(15),
    }
}
#[test]
fn fixed_duration_is_rejected_before_spawn_and_constructor_cause_survives_cleanup() {
    let mut invalid = options("/no-rate-child-must-be-spawned".into(), vec![]);
    invalid.duration = Duration::from_secs(12);
    let f = run_stdio_rate_client(invalid, RateShape::Constant).unwrap_err();
    assert!(matches!(f.stage, ClientStage::Configuration));
    let mut invalid = options(
        env!("CARGO_BIN_EXE_gb-quic-probe").into(),
        vec![
            "--stdio-peer".into(),
            "--rate-shape".into(),
            "constant".into(),
        ],
    );
    invalid.local_ip = "192.0.2.1".parse().unwrap();
    let now = Instant::now();
    let f = run_stdio_rate_client(invalid, RateShape::Constant).unwrap_err();
    assert_eq!(f.report.terminal.origin, ClientOrigin::Constructor);
    assert!(f.report.cleanup && !f.report.cleanup_forced);
    assert!(now.elapsed() < Duration::from_secs(3));
}
#[test]
fn mismatched_authenticated_recipe_fails_promptly_without_load() {
    let now = Instant::now();
    let f = run_stdio_rate_client(
        options(
            env!("CARGO_BIN_EXE_gb-quic-probe").into(),
            vec![
                "--stdio-peer".into(),
                "--rate-shape".into(),
                "frame-burst".into(),
            ],
        ),
        RateShape::Constant,
    )
    .unwrap_err();
    assert_ne!(f.report.verdict, RateVerdict::Pass);
    assert_eq!(f.report.received, [0, 0]);
    assert!(now.elapsed() < Duration::from_secs(3));
}

fn wait_owned(child: &mut std::process::Child, limit: Duration) -> std::process::ExitStatus {
    let end = Instant::now() + limit;
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return status;
        }
        if Instant::now() >= end {
            child.kill().unwrap();
            child.wait().unwrap();
            panic!("exact owned child exceeded watchdog");
        }
        thread::sleep(Duration::from_millis(5));
    }
}
fn bounded_reply(child: &mut std::process::Child) -> [u8; 71] {
    use std::os::fd::AsRawFd;
    let mut bytes = [0; 71];
    let mut used = 0;
    let end = Instant::now() + Duration::from_secs(5);
    while used < 71 {
        if Instant::now() >= end {
            child.kill().unwrap();
            child.wait().unwrap();
            panic!("bounded reply");
        }
        let mut pfd = libc::pollfd {
            fd: child.stdout.as_ref().unwrap().as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: initialized descriptor for the exact live child's stdout.
        let ready = unsafe { libc::poll(&mut pfd, 1, 10) };
        assert!(ready >= 0);
        if ready > 0 {
            let n = child
                .stdout
                .as_mut()
                .unwrap()
                .read(&mut bytes[used..])
                .unwrap();
            assert!(n > 0);
            used += n;
        }
    }
    bytes
}
#[test]
fn authenticated_peer_observes_stdin_eof_during_counted_load() {
    use std::io::Write;
    let identity = Identity::generate().unwrap();
    let request = Request {
        session: [0x71; 32],
        fingerprint: identity.fingerprint(),
        expected_ip: "127.0.0.1".parse().unwrap(),
    };
    let mut child = Command::new(env!("CARGO_BIN_EXE_gb-quic-probe"))
        .args(["--stdio-peer", "--rate-shape", "constant"])
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
    let reply = Reply::decode(&bounded_reply(&mut child), &request.session).unwrap();
    let mut endpoint = Endpoint::connect(
        "127.0.0.1:0".parse().unwrap(),
        format!("127.0.0.1:{}", reply.port).parse().unwrap(),
        request.session,
        identity,
        reply.fingerprint,
    )
    .unwrap();
    let end = Instant::now() + Duration::from_secs(5);
    let mut go = false;
    let mut received = 0;
    while Instant::now() < end && received < 100 {
        endpoint.poll().unwrap();
        assert!(!endpoint.stats().retired);
        if endpoint.stats().application_ready && !go {
            // Independent literal authenticated Recipe/GO, not the private codec.
            let recipe = [
                71, 81, 83, 49, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 46, 224, 0, 0, 117, 48, 0, 0, 2, 88,
                0, 0, 1, 244, 0, 0, 0, 200,
            ];
            go = endpoint.send(
                Message {
                    lane: Lane::Reliable,
                    sequence: 0,
                    payload: recipe.to_vec(),
                },
                Instant::now(),
            ) == Admission::Accepted;
        }
        while let Some(record) = endpoint.receive() {
            if record.lane == Lane::Datagram {
                received += 1;
            }
        }
        thread::sleep(Duration::from_micros(100));
    }
    assert!(received >= 100, "must interrupt actual authenticated load");
    let stopped = Instant::now();
    drop(child.stdin.take());
    assert!(wait_owned(&mut child, Duration::from_secs(2)).success());
    assert!(stopped.elapsed() < Duration::from_secs(2));
    endpoint.close();
    let mut log = String::new();
    child
        .stderr
        .take()
        .unwrap()
        .take(20_000)
        .read_to_string(&mut log)
        .unwrap();
    assert!(log.contains("stdin_eof=1 peer_origin=StdinEof"), "{log}");
}

#[test]
fn ready_rate_peer_retirement_inside_poll_keeps_observed_sleep_and_skipped_step() {
    use std::io::Write;
    let identity = Identity::generate().unwrap();
    let request = Request {
        session: [0x72; 32],
        fingerprint: identity.fingerprint(),
        expected_ip: "127.0.0.1".parse().unwrap(),
    };
    let mut child = Command::new(env!("CARGO_BIN_EXE_gb-quic-probe"))
        .args(["--stdio-peer", "--rate-shape", "constant"])
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
    let reply = Reply::decode(&bounded_reply(&mut child), &request.session).unwrap();
    let mut endpoint = Endpoint::connect(
        "127.0.0.1:0".parse().unwrap(),
        format!("127.0.0.1:{}", reply.port).parse().unwrap(),
        request.session,
        identity,
        reply.fingerprint,
    )
    .unwrap();
    let end = Instant::now() + Duration::from_secs(5);
    let mut go = false;
    let mut received = 0;
    while Instant::now() < end && received < 100 {
        endpoint.poll().unwrap();
        assert!(!endpoint.stats().retired);
        if endpoint.stats().application_ready && !go {
            let recipe = [
                71, 81, 83, 49, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 46, 224, 0, 0, 117, 48, 0, 0, 2, 88,
                0, 0, 1, 244, 0, 0, 0, 200,
            ];
            go = endpoint.send(
                Message {
                    lane: Lane::Reliable,
                    sequence: 0,
                    payload: recipe.to_vec(),
                },
                Instant::now(),
            ) == Admission::Accepted;
        }
        while let Some(record) = endpoint.receive() {
            if record.lane == Lane::Datagram {
                received += 1;
            }
        }
        thread::sleep(Duration::from_micros(100));
    }
    assert!(
        received >= 100,
        "genuine ready rate owner must have produced counted DG"
    );
    // Hold the socket and private stdin open but cease client servicing. The
    // real peer's unchanged five-second QUIC idle policy retires inside poll.
    let stderr = child.stderr.take().unwrap();
    let reader = thread::spawn(move || {
        let mut log = String::new();
        stderr.take(32_768).read_to_string(&mut log).unwrap();
        log
    });
    let status = wait_owned(&mut child, Duration::from_secs(8));
    let log = reader.join().unwrap();
    endpoint.close();
    eprintln!(
        "ready_rate_retirement_exit_success={}\n{log}",
        status.success()
    );
    assert!(!status.success());
    assert!(log.contains("peer_origin=EndpointRetired"), "{log}");
    assert!(log.contains("peer_retirement=PeerIdle"), "{log}");
    let n = |key: &str| -> u64 {
        let prefix = format!("peer_{key}=");
        log.split_whitespace()
            .find_map(|s| s.strip_prefix(&prefix))
            .unwrap()
            .parse()
            .unwrap()
    };
    assert!(n("owner_turns") > 1);
    assert_eq!(n("owner_poll_count"), n("owner_turns"));
    assert_eq!(n("owner_step_count") + 1, n("owner_turns"));
    assert_eq!(n("owner_actual_sleep_count"), n("owner_turns"));
    assert_eq!(n("owner_requested_sleep_count"), n("owner_turns"));
    assert!(
        n("owner_zero_sleep") > 0,
        "the genuine final zero sleep is recorded"
    );
    assert_eq!(
        n("owner_valid"),
        1,
        "all actual phases observed; no missing hook"
    );
    assert_eq!(n("owner_retired_step_skips"), 1);
}

// A bounded test-only stdio relay, not another authentication or socket layer.
// The real G0 peer owns QUIC. After forwarding its one binary bootstrap reply,
// inject stdout text mid-load; then relay exact EOF and reap that nested child.
const STDOUT_RELAY: &str = r#"
use std::{io::{Read,Write},process::{Command,Stdio},thread,time::Duration};
fn main(){
    thread::spawn(||{thread::sleep(Duration::from_secs(8));std::process::exit(3);});
    let probe=std::env::args_os().nth(1).unwrap();
    let mut child=Command::new(probe).args(["--stdio-peer","--rate-shape","constant"]).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::inherit()).spawn().unwrap();
    let mut request=[0;74];std::io::stdin().read_exact(&mut request).unwrap();child.stdin.as_mut().unwrap().write_all(&request).unwrap();
    let mut reply=[0;71];child.stdout.as_mut().unwrap().read_exact(&mut reply).unwrap();std::io::stdout().write_all(&reply).unwrap();std::io::stdout().flush().unwrap();
    thread::sleep(Duration::from_millis(500));std::io::stdout().write_all(&[0x7f]).unwrap();std::io::stdout().flush().unwrap();
    let mut byte=[0];assert_eq!(std::io::stdin().read(&mut byte).unwrap(),0);drop(child.stdin.take());
    let end=std::time::Instant::now()+Duration::from_secs(2);
    loop{if let Some(s)=child.try_wait().unwrap(){assert!(s.success());break;}if std::time::Instant::now()>=end{child.kill().unwrap();child.wait().unwrap();std::process::exit(4);}thread::sleep(Duration::from_millis(5));}
}
"#;

// Authenticated test-only peer: acknowledges GO and echoes probes, but never
// sends LoadEnd/terminal summary. It uses the production public Endpoint and
// trust bootstrap, so only the owner's original fifteen-second boundary can
// complete the scenario. No production fault selector is introduced.
const MISSING_REPORT_PEER: &str = r#"
use galaxybridge_quic::{bootstrap::{Request,Reply},tls::Identity,Endpoint,Lane,Message,Admission};
use std::{io::{Read,Write},thread,time::{Instant,Duration}};
fn main(){
 let deadline=Instant::now()+Duration::from_secs(20);
 let mut request=[0;74];std::io::stdin().read_exact(&mut request).unwrap();let request=Request::decode(&request).unwrap();
 let id=Identity::generate().unwrap();let pin=id.fingerprint();let mut e=Endpoint::listen("127.0.0.1:0".parse().unwrap(),request.expected_ip,request.session,id,request.fingerprint).unwrap();
 let reply=Reply{session:request.session,fingerprint:pin,port:e.local_addr().unwrap().port()}.encode().unwrap();std::io::stdout().write_all(&reply).unwrap();std::io::stdout().flush().unwrap();
 let(tx,rx)=std::sync::mpsc::channel();thread::spawn(move||{let mut byte=[0];let n=std::io::stdin().read(&mut byte).unwrap();tx.send(n==0).unwrap();});
 let mut sequence=0;let mut pending=None;
 while Instant::now()<deadline {
  if let Ok(eof)=rx.try_recv(){assert!(eof);e.close();return;}
  e.poll().unwrap();
  if pending.is_none(){if let Some(m)=e.receive(){assert_eq!(m.lane,Lane::Reliable);let mut p=m.payload;assert_eq!(p.len(),32);match p[5]{1=>{p[5]=2;p[8..].fill(0);},4=>{p[5]=5;p[7]=1;},_=>panic!("unexpected control")};pending=Some(p);}}
  if let Some(p)=&pending{if e.send(Message{lane:Lane::Reliable,sequence,payload:p.clone()},Instant::now())==Admission::Accepted{sequence+=1;pending=None;}}
  thread::sleep(Duration::from_micros(100));
 }
 std::process::exit(3);
}
"#;
fn exact_test_library(
    deps: &std::path::Path,
    supplied: Option<std::ffi::OsString>,
) -> std::path::PathBuf {
    if let Some(path) = supplied {
        let path = std::path::PathBuf::from(path)
            .canonicalize()
            .expect("supplied Cargo artifact must exist");
        assert!(
            path.is_file(),
            "supplied Cargo artifact must be a regular file"
        );
        assert_eq!(
            path.parent().unwrap(),
            deps.canonicalize().unwrap(),
            "supplied Cargo artifact parent"
        );
        assert!(
            path.file_name()
                .unwrap()
                .to_str()
                .is_some_and(|n| n.starts_with("libgalaxybridge_quic-")),
            "supplied Cargo artifact name"
        );
        assert!(
            path.extension().is_some_and(|x| x == "rlib"),
            "supplied Cargo artifact extension"
        );
        return path;
    }
    panic!("run scripts/test-quic-transport.sh or test-quic-rate-probe.sh to select the current Cargo artifact");
}
#[test]
fn supplied_test_library_rejects_invalid_path_without_fallback() {
    let executable = std::env::current_exe().unwrap();
    let deps = executable.parent().unwrap();
    assert!(std::panic::catch_unwind(|| exact_test_library(deps, None)).is_err());
    for path in [
        executable.clone(),
        deps.to_path_buf(),
        deps.join("missing-explicit.rlib"),
    ] {
        assert!(
            std::panic::catch_unwind(|| exact_test_library(deps, Some(path.into_os_string())))
                .is_err()
        );
    }
}
#[test]
fn incomplete_terminal_exchange_retires_at_original_active_deadline() {
    use std::io::Write;
    let deps = std::env::current_exe()
        .unwrap()
        .parent()
        .unwrap()
        .to_path_buf();
    let library = exact_test_library(&deps, std::env::var_os("GB_QUIC_TEST_RLIB"));
    let target = std::path::PathBuf::from(std::env::var_os("CARGO_TARGET_DIR").unwrap());
    let directory = target.join(format!("rate-deadline-child-{}", std::process::id()));
    std::fs::create_dir(&directory).unwrap();
    let binary = directory.join("owned-child");
    let mut compiler = Command::new(std::env::var_os("RUSTC").unwrap())
        .args([
            "--edition=2021",
            "--target",
            "aarch64-apple-darwin",
            "--crate-name",
            "rate_deadline_child",
            "--extern",
        ])
        .arg(format!("galaxybridge_quic={}", library.display()))
        .arg("-L")
        .arg(format!("dependency={}", deps.display()))
        .arg("-L")
        .arg(format!(
            "dependency={}",
            target.join("debug/deps").display()
        ))
        .arg("-o")
        .arg(&binary)
        .arg("-")
        .stdin(Stdio::piped())
        .spawn()
        .unwrap();
    compiler
        .stdin
        .take()
        .unwrap()
        .write_all(MISSING_REPORT_PEER.as_bytes())
        .unwrap();
    assert!(wait_owned(&mut compiler, Duration::from_secs(10)).success());
    let start = Instant::now();
    let f = run_stdio_rate_client(options(binary, vec![]), RateShape::Constant).unwrap_err();
    let elapsed = start.elapsed();
    assert!(elapsed >= Duration::from_secs(15) && elapsed < Duration::from_secs(17));
    assert_eq!(f.report.terminal.origin, ClientOrigin::FinalMissing);
    assert!(f.report.cleanup && !f.report.cleanup_forced && f.report.endpoint_released);
    assert_eq!(f.report.probe_received, 500);
    assert!(f.report.flags.delivery && f.report.flags.measurement && !f.report.flags.transport);
    assert!(f.report.source.is_none());
}
#[test]
fn client_owned_stdout_event_interrupts_real_load_and_reaps_exact_child() {
    use std::io::Write;
    let target = std::path::PathBuf::from(std::env::var_os("CARGO_TARGET_DIR").unwrap());
    let directory = target.join(format!("rate-stdout-child-{}", std::process::id()));
    std::fs::create_dir(&directory).unwrap();
    let binary = directory.join("owned-child");
    let mut compiler = Command::new(std::env::var_os("RUSTC").unwrap())
        .args(["--edition=2021", "--crate-name", "rate_stdout_child", "-o"])
        .arg(&binary)
        .arg("-")
        .stdin(Stdio::piped())
        .spawn()
        .unwrap();
    compiler
        .stdin
        .take()
        .unwrap()
        .write_all(STDOUT_RELAY.as_bytes())
        .unwrap();
    assert!(wait_owned(&mut compiler, Duration::from_secs(10)).success());
    let start = Instant::now();
    let f = run_stdio_rate_client(
        options(binary, vec![env!("CARGO_BIN_EXE_gb-quic-probe").into()]),
        RateShape::Constant,
    )
    .unwrap_err();
    assert_eq!(f.report.terminal.origin, ClientOrigin::StdoutEvent);
    assert!(f.report.received[0] > 100);
    assert!(f.report.cleanup && !f.report.cleanup_forced);
    assert!(start.elapsed() < Duration::from_secs(3));
}

// Break caught: CLI silently uses ordinary tiny echo instead of the declared rate recipe.
#[test]
fn owned_constant_rate_transfers_declared_load_and_strict_verdict() {
    owned_rate("constant");
}
#[test]
fn owned_burst_rate_transfers_declared_load_and_strict_verdict() {
    owned_rate("frame-burst");
}
fn owned_rate(shape: &str) {
    let probe = env!("CARGO_BIN_EXE_gb-quic-probe");
    let mut child = Command::new(probe)
        .args([
            "--stdio-client",
            "--peer-ip",
            "127.0.0.1",
            "--local-ip",
            "127.0.0.1",
            "--rate-shape",
            shape,
            "--",
            probe,
            "--stdio-peer",
            "--rate-shape",
            shape,
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let stderr = child.stderr.take().unwrap();
    let reader = thread::spawn(move || {
        let mut text = String::new();
        stderr.take(200_000).read_to_string(&mut text).unwrap();
        text
    });
    let end = Instant::now() + Duration::from_secs(29);
    let status = loop {
        if let Some(s) = child.try_wait().unwrap() {
            break s;
        }
        if Instant::now() >= end {
            child.kill().unwrap();
            child.wait().unwrap();
            panic!("owned rate watchdog");
        }
        thread::sleep(Duration::from_millis(10));
    };
    let log = reader.join().unwrap();
    // Preserve every scored leg even when the full G0 runner captures output
    // from successful tests. No best-run selection or overwritten log path.
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let evidence = std::path::PathBuf::from(std::env::var_os("CARGO_TARGET_DIR").unwrap()).join(
        format!("rate-scored-{stamp}-{}-{shape}.log", std::process::id()),
    );
    std::fs::write(
        &evidence,
        format!(
            "owned_rate_shape={shape} exit_success={}\n{log}",
            status.success()
        ),
    )
    .unwrap();
    eprintln!("rate_evidence_path={}", evidence.display());
    eprintln!(
        "owned_rate_shape={shape} exit_success={}\n{log}",
        status.success()
    );
    assert!(
        log.contains("video_offered=30000"),
        "required video load absent: {log}"
    );
    assert!(
        log.contains("audio_offered=600"),
        "required audio-rate load absent: {log}"
    );
    assert!(log.contains("cleanup=1 cleanup_forced=0"), "{log}");
    for role in ["peer", "client"] {
        for key in [
            "pressure_valid",
            "path_terminal",
            "owner_valid",
            "socket_send_available",
            "socket_receive_available",
            "path_available",
            "path_rtt_available",
            "path_valid",
        ] {
            assert!(
                log.split_whitespace()
                    .any(|s| s == format!("{role}_{key}=1")),
                "missing/invalid {role}_{key}: {log}"
            );
        }
        for key in [
            "owner_turns",
            "owner_poll_count",
            "owner_step_count",
            "generated_write_age_count",
            "path_samples",
        ] {
            let prefix = format!("{role}_{key}=");
            let value: u64 = log
                .split_whitespace()
                .find_map(|s| s.strip_prefix(&prefix))
                .unwrap()
                .parse()
                .unwrap();
            assert!(value > 0, "absent live hook {role}_{key}: {log}");
        }
        assert!(
            log.split_whitespace()
                .any(|s| s == format!("{role}_path_max_bandwidth_available=0")),
            "CUBIC has no BBR bandwidth: {log}"
        );
    }
    assert!(
        log.contains("bitmap_verified=1 exchange_complete=1"),
        "{log}"
    );
    assert!(log.contains("transport_flag=0 recipe_flag=0"), "{log}");
    assert!(log.contains("measurement_flag=0"), "{log}");
    assert!(
        log.contains("probe_offered=500 probe_admitted=500 probe_received=500"),
        "{log}"
    );
    assert!(
        log.contains("video_received=30000 audio_received=600")
            || log.contains("rate_verdict=DeliveryOrDeadlineFailure"),
        "{log}"
    );
    // A timing/loss miss must be a truthful nonzero result, not a false pass.
    assert_eq!(
        status.success(),
        log.contains("rate_verdict=Pass "),
        "{log}"
    );
    let mut stdout = vec![];
    child
        .stdout
        .take()
        .unwrap()
        .read_to_end(&mut stdout)
        .unwrap();
    assert!(stdout.is_empty());
}
