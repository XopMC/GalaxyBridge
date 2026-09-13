use galaxybridge_quic_backend::process::{OwnedChild, OwnedCommand};
use std::time::{Duration, Instant};

#[test]
fn progress_actual_owned_source_socket_stderr_parent_and_default_off() {
    use galaxybridge_quic_backend::{
        bootstrap::Binding,
        owner::{Event, HostConfig},
        Backend, Error,
    };
    for enabled in [false, true] {
        let prior = std::env::var_os("GB_QUIC_RECOVERY_DIAGNOSTICS");
        if enabled {
            std::env::set_var("GB_QUIC_RECOVERY_DIAGNOSTICS", "1");
        } else {
            std::env::remove_var("GB_QUIC_RECOVERY_DIAGNOSTICS");
        }
        let mut host = Backend::spawn_host(
            HostConfig {
                binding: Binding {
                    nonce: [3; 32],
                    sidecar_sha: [4; 32],
                    context: galaxybridge_quic_media::Context {
                        session: [0; 32],
                        generation: 771,
                        scid: 1,
                        capture_kind: 0,
                        display_id: 0,
                        target_token: 9,
                        enabled: 6,
                    },
                },
                peer_ip: "127.0.0.1".parse().unwrap(),
            },
            OwnedCommand {
                program: env!("CARGO_BIN_EXE_gb-quic-backend").into(),
                args: vec!["--test-peer-identity".into()],
            },
        )
        .unwrap();
        if let Some(v) = prior {
            std::env::set_var("GB_QUIC_RECOVERY_DIAGNOSTICS", v);
        } else {
            std::env::remove_var("GB_QUIC_RECOVERY_DIAGNOSTICS");
        }
        host.qa_hold_send_stage_output();
        let until = Instant::now() + Duration::from_secs(4);
        let mut rows = vec![];
        let mut media = 0;
        while Instant::now() < until && (!enabled || rows.is_empty()) {
            host.poll().unwrap();
            rows.extend(host.qa_progress_observations());
            while let Some(event) = host.next_event() {
                if let Event::Media { handle } = event {
                    media += 1;
                    host.commit_media(handle).unwrap();
                    host.release_event(handle).unwrap();
                }
            }
            std::thread::sleep(Duration::from_millis(1));
        }
        assert!(
            media >= 2,
            "same real producer and media path with observation on/off"
        );
        assert_eq!(rows.is_empty(), !enabled);
        assert!(rows
            .iter()
            .all(|r| r[0] == 771 && r[1] == 2 && r[2] > 0 && r[5] - r[4] >= 100_000_000));
        assert!(
            rows.iter().all(|r| r[13] != u64::MAX && r[14] != u64::MAX),
            "real peer pressure context survives exact stderr and parent parsing"
        );
        println!("progress actual owned helper={rows:?}");
        host.retire(Error::Retired);
        let stop = Instant::now();
        while !host.cleanup().unwrap().complete {
            assert!(stop.elapsed() < Duration::from_secs(2));
            std::thread::sleep(Duration::from_millis(1));
        }
        assert!(!host.cleanup_report().forced);
    }
}

#[test]
fn first_cause_actual_owned_source_service_survives_child_cleanup() {
    use galaxybridge_quic_backend::{bootstrap::Binding, owner::HostConfig, Backend, Error};
    for enabled in [false, true] {
        let prior = std::env::var_os("GB_QUIC_FIRST_ERROR_DIAGNOSTICS");
        if enabled {
            std::env::set_var("GB_QUIC_FIRST_ERROR_DIAGNOSTICS", "1");
        } else {
            std::env::remove_var("GB_QUIC_FIRST_ERROR_DIAGNOSTICS");
        }
        let binding = Binding {
            nonce: [3; 32],
            sidecar_sha: [4; 32],
            context: galaxybridge_quic_media::Context {
                session: [0; 32],
                generation: 771,
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
                peer_ip: "127.0.0.1".parse().unwrap(),
            },
            OwnedCommand {
                program: env!("CARGO_BIN_EXE_gb-quic-backend").into(),
                args: vec!["--test-peer-source-failure".into()],
            },
        )
        .unwrap();
        if let Some(v) = prior {
            std::env::set_var("GB_QUIC_FIRST_ERROR_DIAGNOSTICS", v);
        } else {
            std::env::remove_var("GB_QUIC_FIRST_ERROR_DIAGNOSTICS");
        }
        let until = Instant::now() + Duration::from_secs(3);
        let error = loop {
            if let Err(e) = host.poll() {
                break e;
            }
            assert!(
                Instant::now() < until,
                "real source service must fail finitely"
            );
            std::thread::sleep(Duration::from_millis(1));
        };
        host.retire(error);
        let until = Instant::now() + Duration::from_secs(2);
        while !host.cleanup().unwrap().complete {
            assert!(Instant::now() < until);
            std::thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(host.cleanup_report().exit_code, Some(1));
        assert_eq!(
            host.qa_first_source_error().map(|r| (r[0], r[1])),
            enabled.then_some((101, 1)),
            "original stock Protocol must cross actual child stderr before generic retired/cleanup"
        );
        let (first, exits) = host.qa_first_cause();
        if enabled {
            let first = first.unwrap();
            assert_eq!(&first[..3], &[0, 771, 9]);
            assert!(first[3] > 0 && first[4] > 0);
            assert_eq!(first[5], 101);
            assert_eq!(exits[0], Some([771, 1, 2, 1]));
            assert_eq!(exits[1], None);
        } else {
            assert!(first.is_none());
            assert_eq!(exits, [None; 2]);
        }
        assert!(matches!(
            error,
            Error::Retired | Error::Io | Error::Protocol
        ));
    }
}

#[test]
fn first_cause_actual_owned_normal_eof_and_default_off() {
    use galaxybridge_quic_backend::{
        bootstrap::Binding,
        owner::{Event, HostConfig},
        Backend, Error,
    };
    for enabled in [false, true] {
        let prior = std::env::var_os("GB_QUIC_FIRST_ERROR_DIAGNOSTICS");
        if enabled {
            std::env::set_var("GB_QUIC_FIRST_ERROR_DIAGNOSTICS", "1");
        } else {
            std::env::remove_var("GB_QUIC_FIRST_ERROR_DIAGNOSTICS");
        }
        let binding = Binding {
            nonce: [3; 32],
            sidecar_sha: [4; 32],
            context: galaxybridge_quic_media::Context {
                session: [0; 32],
                generation: 772,
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
                peer_ip: "127.0.0.1".parse().unwrap(),
            },
            OwnedCommand {
                program: env!("CARGO_BIN_EXE_gb-quic-backend").into(),
                args: vec!["--test-peer-normal-eof".into()],
            },
        )
        .unwrap();
        if let Some(v) = prior {
            std::env::set_var("GB_QUIC_FIRST_ERROR_DIAGNOSTICS", v);
        } else {
            std::env::remove_var("GB_QUIC_FIRST_ERROR_DIAGNOSTICS");
        }
        let until = Instant::now() + Duration::from_secs(3);
        let mut au = false;
        while !au {
            host.poll().unwrap();
            while let Some(e) = host.next_event() {
                if let Event::Media { handle } = e {
                    au |= host.check_media(handle).unwrap().record.kind == 5;
                    host.commit_media(handle).unwrap();
                    host.release_event(handle).unwrap();
                }
            }
            assert!(Instant::now() < until);
            std::thread::sleep(Duration::from_millis(1));
        }
        host.retire(Error::Retired);
        let until = Instant::now() + Duration::from_secs(2);
        while !host.cleanup().unwrap().complete {
            assert!(Instant::now() < until);
            std::thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(host.cleanup_report().exit_code, Some(0));
        assert_eq!(host.qa_first_source_error(), None);
        let (first, exits) = host.qa_first_cause();
        assert_eq!(first, None);
        assert_eq!(
            exits,
            if enabled {
                [Some([772, 1, 2, 0]), Some([772, 2, 1, 0])]
            } else {
                [None; 2]
            }
        );
    }
}

#[test]
fn finite_qa_stdio_fixture_uses_same_owner_and_original_whole_deadline() {
    use galaxybridge_quic_backend::{
        bootstrap::Binding,
        owner::{Event, HostConfig},
        Backend, Error,
    };
    let input=std::path::PathBuf::from(std::env::var_os("GB_QUIC_TEST_FIXTURES").expect("run scripts/test-quic-backend.sh")).join("aac.stock");
    let expected = std::fs::read_to_string(input.with_extension("stock.sha256")).unwrap();
    let stock = std::fs::read(input).unwrap();
    assert_eq!(
        boring::sha::sha256(&stock)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>(),
        expected.trim()
    );
    let mut fixture = b"GBF1".to_vec();
    fixture.extend([6, 0, 0, 0]);
    fixture.extend(13u32.to_be_bytes());
    let mut at = 0;
    while at < stock.len() {
        let n = u32::from_be_bytes(stock[at..at + 4].try_into().unwrap()) as usize;
        at += 4;
        fixture.extend(0u64.to_be_bytes());
        fixture.extend([2, 0, 0, 0]);
        fixture.extend((n as u32).to_be_bytes());
        fixture.extend(&stock[at..at + n]);
        at += n;
    }
    let hash = boring::sha::sha256(&fixture)
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<String>();
    let file = std::env::temp_dir().join(format!(
        "galaxybridge-owned-qa-{}-{}.gbf",
        std::process::id(),
        Instant::now().elapsed().as_nanos()
    ));
    use std::io::Write;
    let mut output = std::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&file)
        .unwrap();
    output.write_all(&fixture).unwrap();
    drop(output);
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
    let command = OwnedCommand {
        program: env!("CARGO_BIN_EXE_gb-quic-backend").into(),
        args: vec![
            "--stdio-fixture".into(),
            "--fixture".into(),
            file.into_os_string(),
            "--sha256".into(),
            hash.into(),
            "--duration-ms".into(),
            "2000".into(),
        ],
    };
    let start = Instant::now();
    let mut host = Backend::spawn_host(
        HostConfig {
            binding,
            peer_ip: "127.0.0.1".parse().unwrap(),
        },
        command,
    )
    .unwrap();
    assert_eq!(host.qa_component(0, 0, 0, 0), Err(Error::Protocol));
    assert_eq!(host.qa_component(30001, 0, 0, 0), Err(Error::Protocol));
    host.qa_component(1000, 0, 0, 0).unwrap();
    assert_eq!(host.qa_component(1000, 0, 0, 0), Err(Error::Protocol));
    let mut packets = 0;
    let error = loop {
        let result = host.poll();
        while let Some(event) = host.next_event() {
            if let Event::Media { handle } = event {
                packets += usize::from(host.check_media(handle).unwrap().record.kind == 5);
                host.commit_media(handle).unwrap();
                host.release_event(handle).unwrap();
            }
        }
        if let Err(e) = result {
            break e;
        }
        assert!(start.elapsed() < Duration::from_millis(1500));
        std::thread::sleep(host.next_wakeup().min(Duration::from_millis(1)));
    };
    assert_eq!(error, Error::Deadline);
    assert_eq!(packets, 11);
    assert!(
        start.elapsed() >= Duration::from_millis(1000)
            && start.elapsed() < Duration::from_millis(1500)
    );
    let stop = Instant::now();
    loop {
        let cleanup = host.cleanup().unwrap();
        if cleanup.complete {
            assert!(!cleanup.forced);
            break;
        }
        assert!(stop.elapsed() < Duration::from_secs(2));
        std::thread::sleep(Duration::from_millis(1));
    }
}

#[test]
fn actual_owned_stdio_pair_bootstrap_stock_and_eof_join() {
    use galaxybridge_quic_backend::{
        bootstrap::Binding,
        owner::{Event, HostConfig},
        Backend, Error,
    };
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
    let command = OwnedCommand {
        program: env!("CARGO_BIN_EXE_gb-quic-backend").into(),
        args: vec!["--test-peer".into()],
    };
    let prior = std::env::var_os("GB_QUIC_RECOVERY_DIAGNOSTICS");
    std::env::set_var("GB_QUIC_RECOVERY_DIAGNOSTICS", "1");
    let mut host = Backend::spawn_host(
        HostConfig {
            binding,
            peer_ip: "127.0.0.1".parse().unwrap(),
        },
        command,
    )
    .unwrap();
    if let Some(v) = prior {
        std::env::set_var("GB_QUIC_RECOVERY_DIAGNOSTICS", v);
    } else {
        std::env::remove_var("GB_QUIC_RECOVERY_DIAGNOSTICS");
    }
    host.qa_hold_send_stage_output();
    let mut peer_stages = vec![];
    let until = Instant::now() + Duration::from_secs(3);
    let mut au = false;
    while Instant::now() < until && (!au || !peer_stages.iter().any(|r: &[u64; 23]| r[7] > 0)) {
        host.poll().unwrap();
        peer_stages.extend(
            host.qa_send_stage_observations()
                .into_iter()
                .filter(|r| r[1] == 2),
        );
        while let Some(e) = host.next_event() {
            if let Event::Media { handle } = e {
                let l = host.check_media(handle).unwrap();
                au |= l.record.kind == 5;
                host.commit_media(handle).unwrap();
                host.release_event(handle).unwrap();
            }
        }
        std::thread::sleep(host.next_wakeup().min(Duration::from_millis(1)));
    }
    assert!(
        host.ready() && au,
        "real private child must complete both pins and stock source"
    );
    assert!(
        !peer_stages.is_empty() && peer_stages.len() <= 16,
        "actual helper stderr export and exact-child forwarding"
    );
    assert!(peer_stages
        .iter()
        .all(|r| r[0] == 1 && r[1] == 2 && r[7] <= r[6] && r[6] <= r[5]));
    assert!(peer_stages.iter().any(|r| r[7] > 0));
    println!("send-stage actual owned helper={peer_stages:?}");
    host.retire(Error::Retired);
    let until = Instant::now() + Duration::from_secs(2);
    loop {
        let c = host.cleanup().unwrap();
        if c.complete {
            assert!(!c.forced);
            break;
        }
        assert!(Instant::now() < until);
        std::thread::sleep(Duration::from_millis(1));
    }
}
#[test]
fn cleanup_original_cutoff_classifies_actual_late_observation_and_settlement() {
    use galaxybridge_quic_backend::Error;
    for elapsed in [1_999_999_999, 2_000_000_000, 2_000_000_001] {
        let command = OwnedCommand {
            program: env!("CARGO_BIN_EXE_gb-quic-backend").into(),
            args: vec!["--test-child-eof".into()],
        };
        let mut child = OwnedChild::spawn(&command).unwrap();
        child.stop();
        child.qa_cleanup_elapsed(elapsed).unwrap();
        // Real child exits; only observation time is controlled, not try_wait.
        let until = Instant::now() + Duration::from_secs(1);
        let mut byte = [0];
        while child.read(&mut byte).unwrap() != Some(0) {
            assert!(Instant::now() < until);
            std::thread::sleep(Duration::from_millis(1));
        }
        let report = loop {
            let _ = child.cleanup();
            if child.report().complete {
                break child.report();
            }
            assert!(Instant::now() < until);
        };
        assert_eq!(
            report.failed,
            elapsed >= 2_000_000_000,
            "observed cutoff {elapsed}"
        );
        assert!(child.exited().unwrap());
        assert_eq!(child.report().failed, report.failed);
    }
    let command = OwnedCommand {
        program: env!("CARGO_BIN_EXE_gb-quic-backend").into(),
        args: vec!["--test-child-stall".into()],
    };
    let mut child = OwnedChild::spawn(&command).unwrap();
    assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGSTOP) }, 0);
    child.stop();
    child.qa_cleanup_elapsed(2_000_000_000).unwrap();
    assert_eq!(child.cleanup(), Err(Error::Cleanup));
    assert!(child.report().failed);
    let until = Instant::now() + Duration::from_secs(1);
    while !child.exited().unwrap() {
        assert!(Instant::now() < until);
        std::thread::sleep(Duration::from_millis(1));
    }
    let report = child.cleanup().unwrap();
    assert!(report.complete && report.failed && report.forced);
}

#[test]
fn exact_owned_child_eof_and_forced_cleanup_are_bounded() {
    for mode in ["--test-child-eof", "--test-child-stall"] {
        let command = OwnedCommand {
            program: env!("CARGO_BIN_EXE_gb-quic-backend").into(),
            args: vec![mode.into()],
        };
        let mut child = OwnedChild::spawn(&command).unwrap();
        let start = Instant::now();
        child.stop();
        let report = loop {
            let report = child.cleanup().unwrap();
            if report.complete {
                break report;
            }
            assert!(start.elapsed() < Duration::from_secs(3));
            std::thread::sleep(Duration::from_millis(1));
        };
        assert!(start.elapsed() < Duration::from_secs(2));
        assert_eq!(report.forced, mode == "--test-child-stall");
        assert!(!report.failed);
        assert!(child.exited().unwrap());
    }
}

#[test]
fn stopped_owned_child_is_killed_and_reaped_within_original_cleanup_ceiling() {
    let command = OwnedCommand {
        program: env!("CARGO_BIN_EXE_gb-quic-backend").into(),
        args: vec!["--test-child-stall".into()],
    };
    let mut child = OwnedChild::spawn(&command).unwrap();
    assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGSTOP) }, 0);
    child.stop();
    let start = Instant::now();
    loop {
        let report = child.cleanup().unwrap();
        if report.complete {
            assert!(report.forced);
            break;
        }
        assert!(start.elapsed() < Duration::from_secs(2));
        std::thread::sleep(Duration::from_millis(1));
    }
    assert!(child.exited().unwrap());
}

#[test]
fn abandoned_exact_child_retains_slot_until_nonblocking_reap() {
    let command = OwnedCommand {
        program: env!("CARGO_BIN_EXE_gb-quic-backend").into(),
        args: vec!["--test-child-stall".into()],
    };
    let child = OwnedChild::spawn(&command).unwrap();
    assert_eq!(unsafe { libc::kill(child.id() as i32, libc::SIGSTOP) }, 0);
    drop(child);
    let until = Instant::now() + Duration::from_secs(2);
    while galaxybridge_quic_backend::process::poll_abandoned_cleanup() != 0 {
        assert!(Instant::now() < until);
        std::thread::sleep(Duration::from_millis(1));
    }
    let slots: Vec<_> = (0..16)
        .map(|_| galaxybridge_quic_backend::owner::OwnerSlot::acquire().unwrap())
        .collect();
    assert!(galaxybridge_quic_backend::owner::OwnerSlot::acquire().is_err());
    drop(slots);
}

#[test]
fn actual_second_role_pin_session_and_context_faults_never_publish_ready() {
    use galaxybridge_quic_backend::{
        bootstrap::Binding,
        owner::{Event, HostConfig},
        Backend, Error, Role,
    };
    for fault in [1, 2, 3] {
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
                enabled: 7,
            },
        };
        let command = OwnedCommand {
            program: env!("CARGO_BIN_EXE_gb-quic-backend").into(),
            args: vec!["--test-pair-fault".into(), fault.to_string().into()],
        };
        let mut host = Backend::spawn_host(
            HostConfig {
                binding,
                peer_ip: "127.0.0.1".parse().unwrap(),
            },
            command,
        )
        .unwrap();
        let until = Instant::now() + Duration::from_secs(6);
        let mut ready = false;
        let error = loop {
            let r = host.poll();
            while let Some(event) = host.next_event() {
                ready |= matches!(
                    event,
                    Event::Ready | Event::Media { .. } | Event::Device { .. }
                );
            }
            if let Err(e) = r {
                break e;
            }
            assert!(Instant::now() < until);
            std::thread::sleep(Duration::from_millis(1));
        };
        eprintln!(
            "paired fault={fault} terminal={error:?} media_ready={} bulk_ready={}",
            host.stats(Role::Media).reached_ready,
            host.stats(Role::Bulk).reached_ready
        );
        assert!(!ready && !host.ready());
        assert!(matches!(
            error,
            Error::Authentication | Error::Protocol | Error::Retired
        ));
        if fault == 1 {
            assert!(
                host.stats(Role::Bulk).tls_failure
                    != galaxybridge_quic::tls::VerificationFailure::None
                    || error == Error::Authentication,
                "actual TLS path must fail authentication"
            );
        }
        let until = Instant::now() + Duration::from_secs(2);
        loop {
            if host.cleanup().unwrap().complete {
                break;
            }
            assert!(Instant::now() < until);
            std::thread::sleep(Duration::from_millis(1));
        }
    }
}

#[test]
fn original_partial_bootstrap_no_handshake_and_stock_stall_are_finite() {
    use galaxybridge_quic_backend::{
        bootstrap::Binding,
        owner::{Event, HostConfig},
        Backend, Error,
    };
    for args in [
        vec!["--test-private-partial"],
        vec!["--test-pair-fault", "0"],
        vec!["--test-pair-fault", "4"],
    ] {
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
                enabled: 7,
            },
        };
        let command = OwnedCommand {
            program: env!("CARGO_BIN_EXE_gb-quic-backend").into(),
            args: args.iter().map(|s| (*s).into()).collect(),
        };
        let started = Instant::now();
        let mut host = Backend::spawn_host(
            HostConfig {
                binding,
                peer_ip: "127.0.0.1".parse().unwrap(),
            },
            command,
        )
        .unwrap();
        let mut previous_phase = 0;
        let error = loop {
            previous_phase = previous_phase.max(host.phase());
            let result = host.poll();
            while let Some(event) = host.next_event() {
                assert!(!matches!(
                    event,
                    Event::Ready | Event::Media { .. } | Event::Device { .. }
                ));
            }
            if let Err(e) = result {
                break e;
            }
            assert!(started.elapsed() < Duration::from_secs(6));
            std::thread::sleep(Duration::from_millis(1));
        };
        eprintln!(
            "phase case={} previous_phase={previous_phase} terminal={error:?} elapsed_ms={}",
            args.last().unwrap(),
            started.elapsed().as_millis()
        );
        if args.len() == 1 {
            assert_eq!(error, Error::Deadline);
            assert!(started.elapsed() >= Duration::from_secs(5));
        } else if args[1] == "0" {
            assert!(matches!(error, Error::Deadline | Error::ConnectTimeout));
            assert!(started.elapsed() >= Duration::from_secs(5));
        } else {
            assert!(matches!(
                error,
                Error::Deadline | Error::PeerIdle | Error::Retired
            ));
        }
        let stopped = Instant::now();
        loop {
            if host.cleanup().unwrap().complete {
                break;
            }
            assert!(stopped.elapsed() < Duration::from_secs(2));
            std::thread::sleep(Duration::from_millis(1));
        }
    }
}
