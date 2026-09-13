use galaxybridge_quic::{tls::Identity, Endpoint};
use galaxybridge_quic_media::{wire::Record, Confirmation, Context, Driver, Outcome, Owner};
use std::time::{Duration, Instant};

fn context() -> Context {
    Context {
        session: [7; 32],
        generation: 1,
        scid: 1,
        capture_kind: 0,
        display_id: 0,
        target_token: 9,
        enabled: 7,
    }
}
fn pair() -> (Driver, Driver) {
    pair_with_context(context())
}
fn pair_with_context(context: Context) -> (Driver, Driver) {
    let a = Identity::generate().unwrap();
    let b = Identity::generate().unwrap();
    let ap = a.fingerprint();
    let bp = b.fingerprint();
    let server = Endpoint::listen(
        "127.0.0.1:0".parse().unwrap(),
        "127.0.0.1".parse().unwrap(),
        [7; 32],
        b,
        ap,
    )
    .unwrap();
    let client = Endpoint::connect(
        "127.0.0.1:0".parse().unwrap(),
        server.local_addr().unwrap(),
        [7; 32],
        a,
        bp,
    )
    .unwrap();
    let origin = Instant::now();
    (
        Driver::new(Owner::new(context.clone(), 0).unwrap(), client, origin),
        Driver::new(Owner::new(context, 0).unwrap(), server, origin),
    )
}
fn pump(a: &mut Driver, b: &mut Driver, done: impl Fn(&Driver, &Driver) -> bool) {
    let until = Instant::now() + Duration::from_secs(2);
    while Instant::now() < until {
        a.poll().unwrap();
        b.poll().unwrap();
        if done(a, b) {
            return;
        }
        std::thread::sleep(
            a.next_wakeup()
                .min(b.next_wakeup())
                .min(Duration::from_millis(1)),
        );
    }
    panic!("bounded loopback condition not reached")
}
fn packet(kind: u8, body: Vec<u8>) -> Record {
    Record {
        kind,
        track: 2,
        flags: 0,
        generation: 1,
        epoch: if kind == 2 { 0 } else { 1 },
        config: if kind == 2 { 0 } else { 1 },
        sequence: if kind == 2 { 0 } else { 1 },
        pts: 0,
        total: body.len() as u32,
        index: 0,
        count: 1,
        age_us: 0,
        lifetime_us: 500000,
        body,
    }
}

struct BitFixture(Vec<bool>);
impl BitFixture {
    fn bits(&mut self, count: usize, value: u64) {
        for index in (0..count).rev() {
            self.0.push((value >> index) & 1 != 0);
        }
    }
    fn ue(&mut self, value: u64) {
        let count = 64 - (value + 1).leading_zeros() as usize;
        self.bits(count - 1, 0);
        self.bits(count, value + 1);
    }
    fn finish(mut self) -> Vec<u8> {
        self.0.push(true);
        while self.0.len() % 8 != 0 {
            self.0.push(false);
        }
        self.0
            .chunks(8)
            .map(|bits| {
                bits.iter()
                    .fold(0, |value, bit| (value << 1) | u8::from(*bit))
            })
            .collect()
    }
}
fn h264_configuration() -> Vec<u8> {
    let mut sps = BitFixture(vec![]);
    sps.bits(8, 66);
    sps.bits(8, 0);
    sps.bits(8, 30);
    sps.ue(0);
    sps.ue(0);
    sps.ue(0);
    sps.ue(0);
    sps.ue(1);
    sps.bits(1, 0);
    sps.ue(3);
    sps.ue(1);
    sps.bits(1, 1);
    sps.bits(1, 1);
    sps.bits(1, 0);
    sps.bits(1, 0);
    let mut pps = BitFixture(vec![]);
    pps.ue(0);
    pps.ue(0);
    pps.bits(1, 0);
    pps.bits(1, 0);
    pps.ue(0);
    pps.ue(0);
    pps.ue(0);
    pps.bits(1, 0);
    pps.bits(2, 0);
    pps.ue(0);
    pps.ue(0);
    pps.ue(0);
    pps.bits(1, 1);
    pps.bits(1, 0);
    pps.bits(1, 0);
    let mut bytes = vec![0, 0, 0, 1, 0x67];
    bytes.extend(sps.finish());
    bytes.extend([0, 0, 0, 1, 0x68]);
    bytes.extend(pps.finish());
    bytes
}
fn h264_idr() -> Vec<u8> {
    let mut slice = BitFixture(vec![]);
    slice.ue(0);
    slice.ue(2);
    slice.ue(0);
    slice.bits(4, 0);
    slice.ue(0);
    slice.bits(4, 0);
    slice.bits(8, 0x55);
    let mut bytes = vec![0, 0, 0, 1, 0x65];
    bytes.extend(slice.finish());
    bytes
}

#[test]
fn real_authenticated_endpoint_drives_bidirectional_application_acks_and_original_bytes() {
    let (mut a, mut b) = pair();
    pump(&mut a, &mut b, |a, b| a.ready() && b.ready());
    let an = a.now().unwrap();
    let bn = b.now().unwrap();
    a.owner.queue_start(an).unwrap();
    b.owner.queue_start(bn).unwrap();
    pump(&mut a, &mut b, |a, b| {
        a.transport_stats().delivered >= 2 && b.transport_stats().delivered >= 2
    });
    assert_eq!(
        a.owner
            .transactions
            .next_transaction_result()
            .unwrap()
            .outcome,
        Outcome::PeerBoundaryConfirmed(Confirmation::MetadataCommit)
    );
    assert_eq!(
        b.owner
            .transactions
            .next_transaction_result()
            .unwrap()
            .outcome,
        Outcome::PeerBoundaryConfirmed(Confirmation::MetadataCommit)
    );
    for r in [packet(2, vec![0, 97, 97, 99]), packet(4, vec![0x11, 0x90])] {
        a.owner
            .transactions
            .queue_object(r.clone(), a.now().unwrap())
            .unwrap();
        let until = Instant::now() + Duration::from_secs(1);
        let mut committed = false;
        let mut confirmed = false;
        while Instant::now() < until && !confirmed {
            a.poll().unwrap();
            b.poll().unwrap();
            let now = b.now().unwrap();
            if let Some(lease) = b.owner.receiver.next_output(now).unwrap() {
                assert_eq!(lease.bytes.as_slice(), r.body);
                assert_eq!(lease.record.kind, r.kind);
                // Contract sink admission only; actual AAC conversion is a separate Swift gate.
                b.owner.receiver.consumer_commit(&lease, now).unwrap();
                b.owner.receiver.release_output(&lease, now).unwrap();
                committed = true;
            }
            confirmed = a.owner.transactions.next_transaction_result().is_some();
            std::thread::sleep(Duration::from_micros(100));
        }
        assert!(committed && confirmed);
    }
    let mut au = packet(5, vec![0x21, 0x10, 0x55]);
    au.flags = 2;
    au.pts = 12345;
    au.lifetime_us = 120000;
    let now = a.now().unwrap();
    a.owner.queue_access_unit(au.clone(), now, now).unwrap();
    let until = Instant::now() + Duration::from_millis(100);
    let mut got = false;
    while Instant::now() < until && !got {
        a.poll().unwrap();
        b.poll().unwrap();
        let now = b.now().unwrap();
        if let Some(lease) = b.owner.receiver.next_output(now).unwrap() {
            assert_eq!(lease.bytes.as_slice(), au.body);
            assert_eq!(lease.record.pts, 12345);
            b.owner.receiver.consumer_commit(&lease, now).unwrap();
            b.owner.receiver.release_output(&lease, now).unwrap();
            got = true;
        }
        std::thread::sleep(Duration::from_micros(100));
    }
    assert!(got);
    pump(&mut a, &mut b, |a, _| a.owner.cache.usage() == (0, 0));
    a.retire(galaxybridge_quic_media::Failure::Retired);
    assert!(a.transport_stats().retired);
}

#[test]
fn private_child_has_binary_ready_frame_and_bounded_eof_cleanup() {
    use std::io::Read;
    let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_gb-quic-media-fixture"))
        .arg("--stdio-fixture")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdout = child.stdout.take().unwrap();
    let (tx, rx) = std::sync::mpsc::sync_channel(1);
    let reader = std::thread::spawn(move || {
        let mut header = [0u8; 40];
        let result = stdout.read_exact(&mut header).map(|_| header);
        let _ = tx.send(result);
    });
    let result = rx.recv_timeout(Duration::from_secs(2));
    drop(child.stdin.take());
    let until = Instant::now() + Duration::from_secs(2);
    let status = loop {
        if let Some(status) = child.try_wait().unwrap() {
            break status;
        }
        if Instant::now() >= until {
            child.kill().unwrap();
            break child.wait().unwrap();
        }
        std::thread::sleep(Duration::from_millis(1));
    };
    reader.join().unwrap();
    let header = result
        .expect("bounded ready wait")
        .expect("child must establish real mutual TLS/G1 Start before ready");
    assert_eq!(header[0], 65);
    assert_eq!(&header[1..], &[0u8; 39]);
    assert!(!status.success(), "unexpected EOF is explicit retirement");
}

#[test]
fn first_multifragment_au_repairs_after_authenticated_partial_loss() {
    let (mut a, mut b) = pair();
    pump(&mut a, &mut b, |a, b| a.ready() && b.ready());
    a.owner.queue_start(a.now().unwrap()).unwrap();
    b.owner.queue_start(b.now().unwrap()).unwrap();
    pump(&mut a, &mut b, |a, b| {
        a.transport_stats().delivered >= 2 && b.transport_stats().delivered >= 2
    });
    for r in [packet(2, vec![0, 97, 97, 99]), packet(4, vec![0x11, 0x90])] {
        a.owner
            .transactions
            .queue_object(r, a.now().unwrap())
            .unwrap();
        let until = Instant::now() + Duration::from_secs(1);
        let mut committed = false;
        while Instant::now() < until && !committed {
            a.poll().unwrap();
            b.poll().unwrap();
            let now = b.now().unwrap();
            if let Some(l) = b.owner.receiver.next_output(now).unwrap() {
                b.owner.receiver.consumer_commit(&l, now).unwrap();
                b.owner.receiver.release_output(&l, now).unwrap();
                committed = true;
            }
        }
        assert!(committed);
    }
    let mut au = packet(5, vec![0x21; 5504]);
    au.flags = 2;
    au.pts = 12345;
    au.lifetime_us = 120000;
    // Before stock admission, obtain the existing sampled RTT prerequisite.
    pump(&mut a, &mut b, |a, b| {
        a.transport_stats().path.rtt_available && b.transport_stats().path.rtt_available
    });
    let now = a.now().unwrap();
    a.owner.queue_access_unit(au.clone(), now, now).unwrap();
    let until = Instant::now() + Duration::from_millis(60);
    let mut dropped = false;
    let mut delivered = false;
    while Instant::now() < until && !delivered {
        a.poll().unwrap();
        b.poll_filtered(&mut |received| {
            let r = Record::decode(received.lane, &received.payload).unwrap();
            if r.kind == 5 && r.index == 0 && !dropped {
                dropped = true;
                false
            } else {
                true
            }
        })
        .unwrap();
        let now = b.now().unwrap();
        if let Some(l) = b.owner.receiver.next_output(now).unwrap() {
            assert_eq!(l.bytes.as_slice(), au.body);
            delivered = true;
        }
        std::thread::sleep(Duration::from_micros(100));
    }
    let p = a.transport_stats().path;
    assert!(dropped&&delivered,"partial repair: dropped={dropped} delivered={delivered} unavailable={} rtt_ns={} rttvar_ns={} rtt_available={}",a.owner.cache.unavailable,p.rtt_ns,p.rttvar_ns,p.rtt_available);
}

#[test]
fn authenticated_loopback_single_video_datagram_loss_is_completed_by_negotiated_parity() {
    let mut negotiated = context();
    negotiated.enabled |= galaxybridge_quic_media::FEATURE_XOR_PARITY;
    let (mut source, mut target) = pair_with_context(negotiated);
    pump(&mut source, &mut target, |source, target| {
        source.ready() && target.ready()
    });
    source.owner.queue_start(source.now().unwrap()).unwrap();
    target.owner.queue_start(target.now().unwrap()).unwrap();
    pump(&mut source, &mut target, |source, target| {
        source.transport_stats().delivered >= 2 && target.transport_stats().delivered >= 2
    });
    let startup_until = Instant::now() + Duration::from_secs(1);
    let mut source_started = false;
    let mut target_started = false;
    while Instant::now() < startup_until && !(source_started && target_started) {
        source.poll().unwrap();
        target.poll().unwrap();
        source_started |= source
            .owner
            .transactions
            .next_transaction_result()
            .is_some();
        target_started |= target
            .owner
            .transactions
            .next_transaction_result()
            .is_some();
    }
    assert!(source_started && target_started);

    for (kind, body) in [
        (2, b"h264".to_vec()),
        (3, vec![128, 0, 0, 1, 0, 0, 0, 64, 0, 0, 0, 32]),
        (4, h264_configuration()),
    ] {
        let mut metadata = packet(kind, body);
        metadata.track = 1;
        if kind == 3 {
            metadata.config = 0;
        }
        source
            .owner
            .transactions
            .queue_object(metadata.clone(), source.now().unwrap())
            .unwrap_or_else(|error| panic!("video metadata kind {kind} queue failed: {error:?}"));
        let until = Instant::now() + Duration::from_secs(1);
        let mut committed = false;
        let mut confirmed = false;
        while Instant::now() < until && !(committed && confirmed) {
            source.poll().unwrap();
            target.poll().unwrap();
            let now = target.now().unwrap();
            if let Some(lease) = target.owner.receiver.next_output(now).unwrap() {
                assert_eq!(lease.record.kind, kind);
                target.owner.receiver.consumer_commit(&lease, now).unwrap();
                target.owner.receiver.release_output(&lease, now).unwrap();
                committed = true;
            }
            confirmed |= source
                .owner
                .transactions
                .next_transaction_result()
                .is_some();
        }
        assert!(
            committed && confirmed,
            "video metadata kind {kind} must cross the authenticated pair"
        );
    }

    let mut bytes = h264_idr();
    bytes.resize(galaxybridge_quic_media::wire::BODY * 3, 0xff);
    *bytes.last_mut().unwrap() = 0x80;
    let mut access_unit = packet(5, bytes.clone());
    access_unit.track = 1;
    access_unit.flags = 3;
    access_unit.pts = 16_667;
    access_unit.lifetime_us = 120_000;
    let now = source.now().unwrap();
    source
        .owner
        .queue_access_unit(access_unit, now, now)
        .unwrap();

    let until = Instant::now() + Duration::from_millis(500);
    let mut dropped = false;
    let mut parity = false;
    let mut completed = false;
    while Instant::now() < until && !completed {
        source.poll().unwrap();
        target
            .poll_filtered(&mut |received| {
                let record = Record::decode(received.lane, &received.payload).unwrap();
                parity |= record.kind == galaxybridge_quic_media::wire::XOR_PARITY_KIND;
                if record.kind == 5 && record.track == 1 && record.index == 1 && !dropped {
                    dropped = true;
                    false
                } else {
                    true
                }
            })
            .unwrap();
        let now = target.now().unwrap();
        if let Some(lease) = target.owner.receiver.next_output(now).unwrap() {
            assert_eq!(lease.record.kind, 5);
            assert_eq!(lease.bytes.as_slice(), bytes);
            target.owner.receiver.consumer_commit(&lease, now).unwrap();
            target.owner.receiver.release_output(&lease, now).unwrap();
            completed = true;
        }
        std::thread::sleep(Duration::from_micros(100));
    }
    assert!(
        dropped && parity && completed,
        "one lost video fragment must not break the dependent chain"
    );
}

struct PipeChild {
    child: std::process::Child,
    frames: Option<std::sync::mpsc::Receiver<std::io::Result<[u8; 40]>>>,
    reader: Option<std::thread::JoinHandle<()>>,
}
impl PipeChild {
    fn launch() -> Self {
        use std::io::Read;
        let mut child = std::process::Command::new(env!("CARGO_BIN_EXE_gb-quic-media-fixture"))
            .arg("--stdio-fixture")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap();
        let mut stdout = child.stdout.take().unwrap();
        let (tx, frames) = std::sync::mpsc::sync_channel(4);
        let reader = std::thread::spawn(move || loop {
            let mut h = [0; 40];
            let result = stdout.read_exact(&mut h).map(|_| h);
            let ended = result.is_err();
            if tx.send(result).is_err() || ended {
                break;
            }
        });
        let value = Self {
            child,
            frames: Some(frames),
            reader: Some(reader),
        };
        assert_eq!(value.frame()[0], 65);
        value
    }
    fn frame(&self) -> [u8; 40] {
        self.frames
            .as_ref()
            .unwrap()
            .recv_timeout(Duration::from_secs(2))
            .expect("bounded own-child frame")
            .expect("complete own-child header")
    }
    fn send(&mut self, bytes: &[u8]) {
        use std::io::Write;
        self.child.stdin.as_mut().unwrap().write_all(bytes).unwrap();
    }
    fn cleanup(&mut self) -> (std::process::ExitStatus, bool) {
        drop(self.child.stdin.take());
        let until = Instant::now() + Duration::from_secs(2);
        loop {
            if let Some(status) = self.child.try_wait().unwrap() {
                return (status, false);
            }
            if Instant::now() >= until {
                break;
            }
            std::thread::sleep(Duration::from_millis(1));
        }
        self.child.kill().unwrap();
        let until = Instant::now() + Duration::from_secs(1);
        loop {
            if let Some(status) = self.child.try_wait().unwrap() {
                return (status, true);
            }
            assert!(
                Instant::now() < until,
                "owned killed child failed bounded reap"
            );
            std::thread::sleep(Duration::from_millis(1));
        }
    }
}
impl Drop for PipeChild {
    fn drop(&mut self) {
        let _ = self.cleanup();
        drop(self.frames.take());
        if let Some(reader) = self.reader.take() {
            reader.join().unwrap();
        }
    }
}

#[test]
fn private_pipe_rejects_irrelevant_track_and_malformed_lengths_before_body_allocation() {
    for header in [
        [4, 1, 0, 0, 0, 0, 0, 0],
        [1, 1, 0, 0, 0, 0, 128, 1],
        [4, 0, 1, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0, 0],
    ] {
        let mut child = PipeChild::launch();
        for byte in header {
            child.send(&[byte]);
        }
        let terminal = child.frame();
        assert_eq!((terminal[0], terminal[1], terminal[3]), (67, 3, 1));
        let (status, forced) = child.cleanup();
        assert_eq!(status.code(), Some(1));
        assert!(!forced);
    }
}

#[test]
fn private_pipe_short_header_eof_has_bounded_explicit_retirement() {
    let mut child = PipeChild::launch();
    child.send(&[1, 1, 0]);
    drop(child.child.stdin.take());
    let terminal = child.frame();
    assert_eq!((terminal[0], terminal[1], terminal[3]), (67, 3, 5));
    let (status, forced) = child.cleanup();
    assert_eq!(status.code(), Some(5));
    assert!(!forced);
}

#[cfg(target_os = "macos")]
#[test]
fn private_pipe_stopped_exact_child_is_killed_and_reaped_after_two_second_grace() {
    use std::os::unix::process::ExitStatusExt;
    unsafe extern "C" {
        fn kill(pid: i32, signal: i32) -> i32;
    }
    let mut child = PipeChild::launch();
    // Only this owned, unreaped child is stopped; no name lookup or user process.
    assert_eq!(unsafe { kill(child.child.id() as i32, 17) }, 0);
    let began = Instant::now();
    let (status, forced) = child.cleanup();
    assert!(forced);
    assert_eq!(status.signal(), Some(9));
    assert!(began.elapsed() >= Duration::from_secs(2));
    assert!(began.elapsed() < Duration::from_millis(3500));
}

#[test]
fn private_pipe_stalled_partial_input_reaches_original_hard_lifetime_and_reaps() {
    let began = Instant::now();
    let mut child = PipeChild::launch();
    child.send(&[1]);
    let terminal = child
        .frames
        .as_ref()
        .unwrap()
        .recv_timeout(Duration::from_secs(11))
        .expect("hard lifetime bounds a stalled partial input")
        .unwrap();
    eprintln!(
        "stalled_input_failure={} transport_retirement={} elapsed_ms={}",
        terminal[3],
        u32::from_be_bytes(terminal[16..20].try_into().unwrap()),
        began.elapsed().as_millis()
    );
    assert_eq!((terminal[0], terminal[1], terminal[3]), (67, 3, 3));
    assert_eq!(
        u32::from_be_bytes(terminal[16..20].try_into().unwrap()),
        0,
        "responsive peers keep alive until the unchanged ten-second fixture lifetime"
    );
    let (status, forced) = child.cleanup();
    assert_eq!(status.code(), Some(3));
    assert!(!forced);
    assert!(began.elapsed() >= Duration::from_secs(10));
    assert!(began.elapsed() < Duration::from_secs(12));
}
