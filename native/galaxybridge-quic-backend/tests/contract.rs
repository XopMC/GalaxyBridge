use galaxybridge_quic::Lane;
use galaxybridge_quic_backend::{bulk::Record, Role, Side};
#[cfg(feature = "qa")]
#[test]
fn qa_display_scenarios_are_closed_finite_validated_scalars() {
    use galaxybridge_quic_backend::owner::QaDisplayScenario as S;
    for (text, expected) in [
        ("assigned", vec![1]),
        ("duplicate", vec![1, 1]),
        ("conflict", vec![1, 2]),
        ("ended", vec![1, 3]),
    ] {
        let events = S::parse(text).unwrap().events();
        assert!(events.len() <= 4);
        assert_eq!(events.iter().map(|s| s.kind).collect::<Vec<_>>(), expected);
        for event in events {
            event.validate().unwrap();
        }
        assert_eq!(events[0].display, 7);
    }
    for invalid in ["", "Assigned", "assigned ", "7", "assigned\nended"] {
        assert!(S::parse(invalid).is_err());
    }
}
#[test]
fn exact_display_lines_and_private_literal_identity_are_bounded() {
    use galaxybridge_quic_backend::{
        bootstrap::{decode_display, encode_display, Binding},
        process::{DisplayParser, DisplayStatus},
    };
    let first = b"[server] INFO: New display: 640x480/420 (id=7)\r\n";
    for split in 0..=first.len() {
        let mut parser = DisplayParser::default();
        let mut events = parser.push(&first[..split]);
        events.extend(parser.push(&first[split..]));
        assert_eq!(
            events,
            [DisplayStatus {
                kind: 1,
                width: 640,
                height: 480,
                density: 420,
                display: 7
            }]
        );
        assert!(parser
            .push(b"[server] INFO: New display: 800x600/300 (id=7)\n")
            .is_empty());
        assert_eq!(
            parser.push(b"[server] INFO: New display: 640x480/420 (id=8)\n"),
            [DisplayStatus::scalar(2)]
        );
        assert!(parser.push(first).is_empty());
        assert_eq!(parser.finish(), [DisplayStatus::scalar(3)]);
        assert!(parser.finish().is_empty());
        assert!(parser.push(first).is_empty());
    }
    for invalid in ["0", "2147483648", "-1", "+1", "1 "] {
        let mut parser = DisplayParser::default();
        assert!(parser
            .push(format!("[server] INFO: New display: {invalid}x480/420 (id=7)\n").as_bytes())
            .is_empty());
    }
    let mut parser = DisplayParser::default();
    let mut oversize = vec![b'x'; 1025];
    oversize.extend_from_slice(first);
    assert!(parser.push(&oversize).is_empty());
    assert_eq!(parser.push(first).len(), 1);
    let binding = Binding {
        nonce: [3; 32],
        sidecar_sha: [4; 32],
        context: galaxybridge_quic_media::Context {
            session: [7; 32],
            generation: 9,
            scid: 1,
            capture_kind: 1,
            display_id: u32::MAX,
            target_token: 11,
            enabled: 7,
        },
    };
    let status = DisplayStatus {
        kind: 1,
        width: 640,
        height: 480,
        density: 420,
        display: 7,
    };
    let mut literal = vec![0; 48];
    literal[..4].copy_from_slice(b"GDS1");
    literal[4] = 1;
    literal[5] = 1;
    literal[15] = 9;
    literal[19] = 1;
    literal[31] = 11;
    literal[20..24].fill(255);
    literal[32..36].copy_from_slice(&640u32.to_be_bytes());
    literal[36..40].copy_from_slice(&480u32.to_be_bytes());
    literal[40..44].copy_from_slice(&420u32.to_be_bytes());
    literal[47] = 7;
    assert_eq!(encode_display(&binding, status).unwrap(), literal);
    assert_eq!(decode_display(&binding, &literal).unwrap(), status);
    for at in [0, 4, 6, 7, 15, 19, 23, 31] {
        let mut bad = literal.clone();
        bad[at] ^= 1;
        assert!(decode_display(&binding, &bad).is_err(), "byte {at}");
    }
    for n in 0..48 {
        assert!(decode_display(&binding, &literal[..n]).is_err());
    }
    let mut extra = literal.clone();
    extra.push(0);
    assert!(decode_display(&binding, &extra).is_err());
    let mut primary = binding.clone();
    primary.context.capture_kind = 0;
    assert!(decode_display(&primary, &literal).is_err());
}
#[test]
fn ceil_age_last_dispatch_boundary_preserves_outcome_and_never_emits_invalid_record() {
    use galaxybridge_quic_backend::{
        bulk::{Channel, Outcome},
        Error,
    };
    for accepted in [false, true] {
        let mut channel = Channel::new(Side::Host, 1);
        channel.queue(1, 0, &[5; 977], 0, 0).unwrap();
        if accepted {
            assert_eq!(channel.next_record(0).unwrap().unwrap().offset, 0);
            channel
                .admission(galaxybridge_quic::Admission::Accepted, 0)
                .unwrap();
        }
        assert!(
            matches!(channel.next_record(499_999_001), Err(Error::Deadline)),
            "ceil boundary must retire as Deadline"
        );
        assert_eq!(
            channel.completion().unwrap().outcome,
            if accepted {
                Outcome::UnknownRemoteOutcome
            } else {
                Outcome::NotDispatched
            }
        );
        assert!(channel.completion().is_none());
    }
    let mut channel = Channel::new(Side::Host, 1);
    channel.queue(1, 0, &[5], 0, 0).unwrap();
    let record = channel.next_record(499_999_000).unwrap().unwrap();
    assert_eq!(record.age_us, 499999);
    record.encode(Role::Bulk, Side::Host).unwrap();
}

#[test]
fn bulk_size_caps_final_reference_and_fragment_progress_are_exact() {
    use galaxybridge_quic_backend::{
        bulk::{BlobPool, Channel},
        Error,
    };
    for n in [0, 1, 976, 977, 262144, 262145] {
        let mut source = Channel::new(Side::Host, 1);
        let bytes = vec![5; n];
        let queued = source.queue(1, 0, &bytes, 0, 0);
        if n == 0 || n == 262145 {
            assert_eq!(queued, Err(Error::Capacity));
            continue;
        }
        queued.unwrap();
        let mut offset = 0;
        while offset < n {
            let record = source.next_record(0).unwrap().unwrap();
            assert_eq!(record.offset as usize, offset);
            assert_eq!(record.body.len(), 976.min(n - offset));
            offset += record.body.len();
            source
                .admission(galaxybridge_quic::Admission::Accepted, 0)
                .unwrap();
        }
        assert!(
            source.next_record(0).unwrap().is_none(),
            "accepted bytes are not replayed"
        );
    }
    let pool = BlobPool::default();
    let one = pool.allocate(262144).unwrap();
    let held = one.clone();
    let two = pool.allocate(262144).unwrap();
    assert!(pool.allocate(1).is_err());
    drop(one);
    assert_eq!(pool.usage(), (2, 524288));
    drop(held);
    assert_eq!(pool.usage(), (1, 262144));
    drop(two);
    assert_eq!(pool.usage(), (0, 0));
}
fn literal() -> Vec<u8> {
    let mut b = vec![0u8; 49];
    b[..4].copy_from_slice(b"GQB1");
    b[4] = 1;
    b[5] = 1;
    b[15] = 1;
    b[23] = 1;
    b[35] = 1;
    b[41] = 1;
    b[48] = 5;
    b
}
#[test]
fn independent_gqb_literal_and_strict_fields() {
    let b = literal();
    let r = Record::decode(&b, Role::Bulk, Side::Host, Lane::Reliable, 1).expect("literal GQB1");
    assert_eq!((r.kind, r.id, r.body.as_slice()), (1, 1, &[5][..]));
    assert_eq!(r.encode(Role::Bulk, Side::Host).unwrap(), b);
    for at in [0, 6, 7, 42, 43] {
        let mut bad = b.clone();
        bad[at] = 255;
        assert!(Record::decode(&bad, Role::Bulk, Side::Host, Lane::Reliable, 1).is_err());
    }
    for n in 0..b.len() {
        assert!(Record::decode(&b[..n], Role::Bulk, Side::Host, Lane::Reliable, 1).is_err());
    }
    for (role, side, lane, generation) in [
        (Role::Media, Side::Host, Lane::Reliable, 1),
        (Role::Bulk, Side::Peer, Lane::Reliable, 1),
        (Role::Bulk, Side::Host, Lane::Datagram, 1),
        (Role::Bulk, Side::Host, Lane::Reliable, 2),
    ] {
        assert!(Record::decode(&b, role, side, lane, generation).is_err());
    }
}

#[test]
fn popped_bulk_lease_keeps_deadline_and_applied_is_once() {
    use galaxybridge_quic_backend::{bulk::Channel, Error, MS};
    for expired in [false, true] {
        let mut peer = Channel::new(Side::Peer, 1);
        let r = Record::decode(&literal(), Role::Bulk, Side::Host, Lane::Reliable, 1).unwrap();
        peer.ingest(r, 0).unwrap();
        let object = peer.next_object(0).unwrap().unwrap();
        if expired {
            assert_eq!(
                peer.tick(500 * MS),
                Err(Error::Deadline),
                "handoff cannot remove original receiver deadline"
            );
        } else {
            peer.applied(&object, 1).unwrap();
            assert!(
                peer.applied(&object, 2).is_err(),
                "duplicate application confirmation must not enqueue a second ACK"
            );
        }
    }
}

#[test]
fn bootstrap_encode_rejects_duplicate_roles_before_private_write() {
    use galaxybridge_quic_backend::bootstrap::{Binding, Requests};
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
    let (mut requests, _) = Requests::fresh(binding, "127.0.0.1".parse().unwrap()).unwrap();
    requests.roles[1].session = requests.roles[0].session;
    assert!(
        requests.encode().is_err(),
        "local bootstrap must reject aliasing before emitting bytes"
    );
}

#[test]
fn popped_bulk_lease_expiry_is_independent_of_ack_duplicate_case() {
    use galaxybridge_quic_backend::{bulk::Channel, Error, MS};
    let mut peer = Channel::new(Side::Peer, 1);
    let r = Record::decode(&literal(), Role::Bulk, Side::Host, Lane::Reliable, 1).unwrap();
    peer.ingest(r, 0).unwrap();
    let _object = peer.next_object(0).unwrap().unwrap();
    assert_eq!(
        peer.tick(500 * MS),
        Err(Error::Deadline),
        "issued lease still owns a deadline"
    );
}

#[test]
fn producer_request_is_exact_published_epoch_ordinal_and_original_boottime() {
    use galaxybridge_quic_backend::recovery::ProducerMap;
    use galaxybridge_quic_media::StockPublication;
    let mut map = ProducerMap::default();
    let mut p = StockPublication {
        kind: 3,
        track: 1,
        epoch: 1,
        config: 0,
        sequence: 1,
        started: 0,
        independent: false,
    };
    map.publication(p).unwrap();
    p.kind = 4;
    p.config = 1;
    map.publication(p).unwrap();
    p.config = 2;
    map.publication(p).unwrap();
    let mut body = vec![];
    body.extend(1u32.to_be_bytes());
    body.extend(2u32.to_be_bytes());
    body.extend(3u64.to_be_bytes());
    let mut r = Record {
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
    map.admit(&r, 1_000_000_000)
        .expect("current published request must be admitted");
    let request = map.take(1_000_000_001).unwrap();
    let mut expected = vec![23];
    for n in [1u64, 2, 1, 1_100_000_000] {
        expected.extend(n.to_be_bytes());
    }
    assert_eq!(request.bytes.as_slice(), expected);
    assert!(map.admit(&r, 1_000_000_002).is_err());
    p.kind = 3;
    p.epoch = 2;
    map.publication(p).unwrap();
    p.kind = 4;
    p.config = 3;
    map.publication(p).unwrap();
    r.id = 2;
    r.body[..4].copy_from_slice(&2u32.to_be_bytes());
    r.body[4..8].copy_from_slice(&3u32.to_be_bytes());
    map.admit(&r, 2_000_000_000).unwrap();
    let request = map.take(2_000_000_001).unwrap();
    assert_eq!(&request.bytes[1..9], &2u64.to_be_bytes());
    assert_eq!(
        &request.bytes[9..17],
        &1u64.to_be_bytes(),
        "ordinal resets, G1 config version does not"
    );
    r.id = 3;
    assert!(map.admit(&r, i64::MAX as u64).is_err());
    map.admit(&r, 3_000_000_000).unwrap();
    assert!(
        map.take(3_100_000_000).is_none(),
        "equality expires without renewing BOOTTIME"
    );
}

#[test]
fn current_producer_artifact_and_private_bootstrap_are_one_exact_pin() {
    use galaxybridge_quic_backend::{
        bootstrap::{Binding, Replies, Requests},
        stock::ProducerLaunch,
        Error,
    };
    let current = std::path::PathBuf::from(std::env::var_os("GB_QUIC_TEST_PRODUCER").expect("run scripts/test-quic-backend.sh"));
    let previous = std::env::temp_dir().join(format!("galaxybridge-wrong-producer-{}.jar", std::process::id()));
    std::fs::write(&previous, b"wrong artifact with the same advertised version").unwrap();
    let expected = galaxybridge_quic_backend::bootstrap::PRODUCER_SHA;
    assert_eq!(
        boring::sha::sha256(&std::fs::read(&current).expect("immutable current producer")),
        expected
    );
    let mut launch = ProducerLaunch {
        jar: current,
        hevc: false,
        max_size: 1920,
        max_fps: 60,
        video_bit_rate: 20_000_000,
        audio_bit_rate: 128_000,
        key_frame_interval_seconds: None,
        new_display: None,
    };
    assert!(
        launch.verify_artifact().is_ok(),
        "actual Android pre-bootstrap artifact validator must accept the packaged producer"
    );
    launch.jar = previous.clone();
    assert!(
        matches!(launch.verify_artifact(), Err(Error::Authentication)),
        "old same-version producer must not silently pass"
    );
    std::fs::remove_file(previous).unwrap();
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
    let (request, _) = Requests::fresh(binding, "127.0.0.1".parse().unwrap()).unwrap();
    let bytes = request.encode().unwrap();
    assert_eq!(
        &bytes[104..136],
        &expected,
        "framed GBP3 carries the same producer pin"
    );
    Requests::decode(&bytes).unwrap();
    let mut wrong = bytes;
    wrong[104] ^= 1;
    assert!(
        matches!(Requests::decode(&wrong), Err(Error::Protocol)),
        "mismatched peer producer remains rejected"
    );
    let reply = Replies {
        binding: request.binding.clone(),
        roles: std::array::from_fn(|i| galaxybridge_quic::bootstrap::Reply {
            session: request.roles[i].session,
            fingerprint: [i as u8 + 5; 32],
            port: 20000 + i as u16,
        }),
    };
    let bytes = reply.encode().unwrap();
    assert_eq!(&bytes[104..136], &expected);
    Replies::decode(&bytes, &request).unwrap();
    let mut wrong = bytes;
    wrong[135] ^= 1;
    assert!(
        matches!(Replies::decode(&wrong, &request), Err(Error::Protocol)),
        "host must reject mismatched reply producer too"
    );
}

#[test]
fn producer_launch_preserves_disabled_control_and_selected_profile() {
    use galaxybridge_quic_backend::{bootstrap::Binding, stock::ProducerLaunch};
    let binding = Binding {
        nonce: [3; 32],
        sidecar_sha: [4; 32],
        context: galaxybridge_quic_media::Context {
            session: [7; 32],
            generation: 1,
            scid: 0xabc,
            capture_kind: 0,
            display_id: 0,
            target_token: 9,
            enabled: 3,
        },
    };
    let launch = ProducerLaunch {
        jar: "/data/local/tmp/gb-sync-approved.jar".into(),
        hevc: true,
        max_size: 1920,
        max_fps: 60,
        video_bit_rate: 20_000_000,
        audio_bit_rate: 128_000,
        key_frame_interval_seconds: Some(1),
        new_display: None,
    };
    let command = launch
        .command(&binding)
        .expect("media-only enabled tracks remain legal");
    let args: Vec<_> = command.args.iter().map(|a| a.to_str().unwrap()).collect();
    for required in [
        "control=false",
        "video=true",
        "audio=true",
        "video_codec=h265",
        "audio_codec=aac",
        "display_id=0",
        "scid=00000abc",
        "send_stream_meta=true",
        "video_codec_options=i-frame-interval=1,priority=0,latency=0",
    ] {
        assert!(args.contains(&required), "missing exact option {required}");
    }
    assert_eq!(
        command.args,
        launch.command_with_policy(&binding, None).unwrap().args
    );
    assert!(args.contains(&"log_level=warn"));
    assert!(!args.contains(&"clipboard_autosync=false"));
    use galaxybridge_quic_backend::stock::LaunchPolicy;
    let primary = launch
        .command_with_policy(&binding, Some(LaunchPolicy::Primary))
        .unwrap();
    let primary: Vec<_> = primary.args.iter().map(|a| a.to_str().unwrap()).collect();
    for required in [
        "log_level=info",
        "cleanup=true",
        "clipboard_autosync=false",
        "power_on=false",
        "keep_active=true",
        "display_ime_policy=hide",
    ] {
        assert!(primary.contains(&required));
    }
    for cleanup in [false, true] {
        let explicit = launch
            .command_with_policy(&binding, Some(LaunchPolicy::Primary.with_cleanup(cleanup)))
            .unwrap();
        let expected: Vec<_> = primary
            .iter()
            .map(|a| {
                if *a == "cleanup=true" {
                    format!("cleanup={cleanup}")
                } else {
                    a.to_string()
                }
            })
            .collect();
        assert_eq!(
            explicit.args,
            expected
                .iter()
                .map(std::ffi::OsString::from)
                .collect::<Vec<_>>()
        );
    }
    let mut virtual_binding = binding.clone();
    virtual_binding.context.capture_kind = 1;
    virtual_binding.context.display_id = u32::MAX;
    let application = ProducerLaunch {
        new_display: Some((720, 1280)),
        ..launch
    };
    let app = application
        .command_with_policy(
            &virtual_binding,
            Some(LaunchPolicy::Application { density: Some(420) }),
        )
        .unwrap();
    let app: Vec<_> = app.args.iter().map(|a| a.to_str().unwrap()).collect();
    for required in [
        "new_display=720x1280/420",
        "cleanup=false",
        "vd_destroy_content=true",
        "vd_system_decorations=false",
        "flex_display=true",
        "keep_active=true",
    ] {
        assert!(app.contains(&required));
    }
    for cleanup in [false, true] {
        let explicit = application
            .command_with_policy(
                &virtual_binding,
                Some(LaunchPolicy::Application { density: Some(420) }.with_cleanup(cleanup)),
            )
            .unwrap();
        let expected: Vec<_> = app
            .iter()
            .map(|a| {
                if *a == "cleanup=false" {
                    format!("cleanup={cleanup}")
                } else {
                    a.to_string()
                }
            })
            .collect();
        assert_eq!(
            explicit.args,
            expected
                .iter()
                .map(std::ffi::OsString::from)
                .collect::<Vec<_>>()
        );
    }
    assert!(application
        .command_with_policy(&virtual_binding, Some(LaunchPolicy::Primary))
        .is_err());
    assert!(application
        .command_with_policy(
            &virtual_binding,
            Some(LaunchPolicy::Application { density: Some(0) })
        )
        .is_err());
}

#[test]
fn prepared_fixture_is_hash_checked_complete_and_bounded_before_selection() {
    use galaxybridge_quic_backend::stock::PreparedFixture;
    let mut bytes = b"GBF1".to_vec();
    bytes.extend([6, 0, 0, 0]);
    bytes.extend(1u32.to_be_bytes());
    bytes.extend(0u64.to_be_bytes());
    bytes.extend([2, 0, 0, 0]);
    bytes.extend(4u32.to_be_bytes());
    bytes.extend([0, 97, 97, 99]);
    let hash = boring::sha::sha256(&bytes);
    let fixture =
        PreparedFixture::from_bytes(bytes.clone(), hash).expect("complete enabled stock fixture");
    assert_eq!(fixture.enabled(), 6);
    assert!(PreparedFixture::from_bytes(bytes.clone(), [0; 32]).is_err());
    bytes.push(0);
    let hash = boring::sha::sha256(&bytes);
    assert!(PreparedFixture::from_bytes(bytes, hash).is_err());
}

#[test]
fn prepared_fixture_six_second_index_remains_finitely_bounded() {
    use galaxybridge_quic_backend::{stock::PreparedFixture, Error};
    for count in [768u32, 769] {
        let mut bytes = b"GBF1".to_vec();
        bytes.extend([6, 0, 0, 0]);
        bytes.extend(count.to_be_bytes());
        for index in 0..count {
            let record = if index == 0 {
                vec![0, 97, 97, 99]
            } else {
                let mut r = (if index == 1 {
                    1u64 << 62
                } else {
                    index as u64 * 21_333
                })
                .to_be_bytes()
                .to_vec();
                let payload = if index == 1 {
                    vec![0x11, 0x90]
                } else {
                    vec![1]
                };
                r.extend((payload.len() as u32).to_be_bytes());
                r.extend(payload);
                r
            };
            bytes.extend((index as u64 * 10_000_000).to_be_bytes());
            bytes.extend([2, 0, 0, 0]);
            bytes.extend((record.len() as u32).to_be_bytes());
            bytes.extend(record);
        }
        assert!(bytes.capacity() + std::mem::size_of::<PreparedFixture>() < PreparedFixture::LIMIT);
        let hash = boring::sha::sha256(&bytes);
        let result = PreparedFixture::from_bytes(bytes, hash);
        if count == 768 {
            assert_eq!(result.unwrap().access_units(), [0, 766]);
        } else {
            assert!(matches!(result, Err(Error::Capacity)));
        }
    }
}

#[test]
fn retained_bulk_objects_cannot_consume_reserved_stock_ack_storage() {
    use galaxybridge_quic_backend::{bulk::BlobPool, stock::DeviceParser};
    let bulk = BlobPool::default();
    let small = BlobPool::small_events();
    let acks = BlobPool::ack_events();
    let retained = [
        bulk.allocate(262144).unwrap(),
        bulk.allocate(262144).unwrap(),
    ];
    let mut parser = DeviceParser::default();
    let (n, event) = parser
        .push_with_pools(&[1, 0, 0, 0, 0, 0, 0, 0, 9], &bulk, &small, &acks, 0)
        .expect("stock ACK reservation is independent of foreign bulk retention");
    assert_eq!(n, 9);
    assert_eq!(event.unwrap().as_slice(), [1, 0, 0, 0, 0, 0, 0, 0, 9]);
    assert_eq!(bulk.usage(), (2, 524288));
    drop(retained);
}

#[test]
fn private_bundle_fragmentation_trailing_roles_and_cap_are_strict() {
    use galaxybridge_quic_backend::bootstrap::{Binding, Frame, Requests};
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
    let (requests, _) = Requests::fresh(binding, "127.0.0.1".parse().unwrap()).unwrap();
    let bytes = requests.encode().unwrap();
    assert_eq!(&bytes[4..10], b"GBP3\x01\x00");
    let mut frame = Frame::default();
    for (i, b) in bytes.iter().enumerate() {
        assert_eq!(frame.push(&[*b]).unwrap(), 1);
        assert_eq!(frame.complete(), i + 1 == bytes.len());
    }
    Requests::decode(frame.bytes()).unwrap();
    for at in [4, 8, 9] {
        let mut invalid = bytes.clone();
        invalid[at] = 255;
        assert!(Requests::decode(&invalid).is_err());
    }
    for n in 0..bytes.len() {
        assert!(Requests::decode(&bytes[..n]).is_err());
    }
    let mut trailing = bytes.clone();
    trailing.push(0);
    assert!(Requests::decode(&trailing).is_err());
    for length in [0u32, 4097, u32::MAX] {
        assert!(Frame::default().push(&length.to_be_bytes()).is_err());
    }
}

#[test]
fn stock_unicode_uhid_copy_cut_and_boottime_edge_vectors() {
    use galaxybridge_quic_backend::{
        recovery::checked_timespec,
        stock::{validate_bulk_command, validate_device},
    };
    for action in [0, 1, 2] {
        assert!(validate_bulk_command(&[8, action]).is_ok());
    }
    assert!(validate_bulk_command(&[8, 3]).is_err());
    let mut unicode = vec![1, 0, 0, 0, 4];
    unicode.extend("😀".as_bytes());
    assert!(validate_bulk_command(&unicode).is_ok());
    unicode.pop();
    assert!(validate_bulk_command(&unicode).is_err());
    let clipboard = [0, 0, 0, 0, 1, b'x'];
    assert!(validate_device(&clipboard).is_ok());
    let uhid = [2, 0, 1, 0, 1, 255];
    assert!(validate_device(&uhid).is_ok());
    assert!(validate_device(&uhid[..5]).is_err());
    for (sec, nanos) in [(-1, 0), (0, -1), (0, 1_000_000_000), (0, 0), (i64::MAX, 0)] {
        assert!(checked_timespec(sec, nanos).is_err());
    }
    assert_eq!(checked_timespec(1, 1).unwrap(), 1_000_000_001);
}
