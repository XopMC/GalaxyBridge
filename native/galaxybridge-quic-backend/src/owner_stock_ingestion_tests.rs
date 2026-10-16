use super::*;
use std::io::Write;
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;

// Refill budget is injected so scheduler preemption cannot change exact
// read-turn assertions. Production uses a real two-millisecond clock.
// Appending an AVC user-data SEI preserves the source IDR picture and makes
// the complete, valid access unit span several stock socket read buffers.
fn fixture_with_sei(payload: usize) -> (Vec<Vec<u8>>, Vec<u8>) {
    let bytes = std::fs::read(
        std::path::PathBuf::from(
            std::env::var_os("GB_QUIC_TEST_FIXTURES").expect("fixture directory"),
        )
        .join("h264.stock"),
    )
    .unwrap();
    let mut frames = vec![];
    let mut at = 0;
    while at < bytes.len() {
        let n = u32::from_be_bytes(bytes[at..at + 4].try_into().unwrap()) as usize;
        at += 4;
        frames.push(bytes[at..at + n].to_vec());
        at += n;
    }
    let mut idr = frames[3].clone();
    idr.extend([0, 0, 0, 1, 6, 5]);
    idr.extend(std::iter::repeat_n(255, payload / 255));
    idr.push((payload % 255) as u8);
    idr.extend(std::iter::repeat_n(0x55, payload));
    idr.push(0x80);
    let len = (idr.len() - 12) as u32;
    idr[8..12].copy_from_slice(&len.to_be_bytes());
    (frames, idr)
}

fn peer() -> (Backend, UnixStream, UnixStream) {
    let endpoints = std::array::from_fn(|i| {
        Endpoint::listen(
            "127.0.0.1:0".parse().unwrap(),
            "127.0.0.1".parse().unwrap(),
            [i as u8 + 7; 32],
            Identity::generate().unwrap(),
            [1; 32],
        )
        .unwrap()
    });
    let binding = Binding {
        nonce: [3; 32],
        sidecar_sha: [4; 32],
        context: galaxybridge_quic_media::Context {
            session: [7; 32],
            generation: 1,
            scid: 1,
            capture_kind: 0,
            display_id: 0,
            target_token: 9,
            enabled: 5,
        },
    };
    let (video, mut producer) = UnixStream::pair().unwrap();
    // Ensure the entire AU is ready before service; no concurrent producer.
    let capacity: libc::c_int = 256 * 1024;
    assert_eq!(
        unsafe {
            libc::setsockopt(
                producer.as_raw_fd(),
                libc::SOL_SOCKET,
                libc::SO_SNDBUF,
                (&capacity as *const libc::c_int).cast(),
                std::mem::size_of_val(&capacity) as libc::socklen_t,
            )
        },
        0
    );
    let (control, producer_control) = UnixStream::pair().unwrap();
    let stock = stock::SocketGroup::connected(Some(video), None, control).unwrap();
    let mut owner = Backend::from_channels(
        OwnerSlot::acquire().unwrap(),
        Side::Peer,
        binding,
        endpoints,
        Some(stock),
    )
    .unwrap();
    owner.local_clock = Some(1);
    producer.write_all(&[0; 65]).unwrap();
    let (frames, _) = fixture_with_sei(20_000);
    for frame in &frames[..3] {
        producer.write_all(frame).unwrap();
    }
    assert!(owner.stock.as_mut().unwrap().consume_preamble().unwrap());
    owner.g1.queue_start(1).unwrap();
    owner.read_stock(1).unwrap();
    assert_eq!(owner.producer_map.identity(), Some((1, 1)));
    (owner, producer, producer_control)
}

#[test]
fn preloaded_large_idr_publishes_in_one_stock_service_turn() {
    let (mut owner, mut producer, _control) = peer();
    let (_, idr) = fixture_with_sei(20_000);
    producer.write_all(&idr).unwrap();
    owner.track_turn = 1;
    let mut turns = 0;
    while owner.g1.cache.usage().0 == 0 && turns < 8 {
        owner.read_stock_with_budget(1, || false).unwrap();
        turns += 1;
    }
    assert_eq!(
        turns,
        1,
        "a ready {}-byte AU must not pay one owner wait per 8192 bytes",
        idr.len()
    );
    let mut payload = vec![];
    while let Some((r, _, repair)) = owner.g1.cache.next(1) {
        assert_eq!((r.track, r.sequence, r.flags & 1), (1, 1, 1));
        payload.extend_from_slice(&r.body);
        owner.g1.cache.accepted(&r, repair).unwrap();
    }
    assert_eq!(
        payload,
        idr[12..],
        "published AU retains exact encoded bytes"
    );
    owner.retire(Error::Retired);
    assert!(owner.cleanup().unwrap().complete);
}

#[test]
fn oversized_ready_idr_yields_before_completion_then_preserves_partial_bytes() {
    let (mut owner, mut producer, _control) = peer();
    let (_, idr) = fixture_with_sei(100_000);
    producer.write_all(&idr).unwrap();
    owner.track_turn = 1;
    owner.read_stock_with_budget(1, || false).unwrap();
    assert_eq!(
        owner.g1.cache.usage().0,
        0,
        "large AU must yield to the remaining owner work before draining all ready bytes"
    );
    assert_eq!(owner.active_track, Some(1));
    owner.read_stock_with_budget(1, || false).unwrap();
    assert_eq!(owner.g1.cache.usage().0, 1);
    let mut payload = vec![];
    while let Some((r, _, repair)) = owner.g1.cache.next(1) {
        payload.extend_from_slice(&r.body);
        owner.g1.cache.accepted(&r, repair).unwrap();
    }
    assert_eq!(payload, idr[12..]);
    owner.retire(Error::Retired);
    assert!(owner.cleanup().unwrap().complete);
}

#[test]
fn unavailable_partial_idr_yields_and_resumes_without_restarting_au() {
    let (mut owner, mut producer, _control) = peer();
    let (_, idr) = fixture_with_sei(20_000);
    producer.write_all(&idr[..10_000]).unwrap();
    owner.track_turn = 1;
    owner.read_stock_with_budget(1, || false).unwrap();
    assert_eq!(owner.g1.cache.usage().0, 0);
    assert_eq!(owner.active_track, Some(1));
    // Several empty reads must not publish, lose framing, or renew ownership.
    for _ in 0..3 {
        owner.read_stock_with_budget(1, || false).unwrap();
    }
    producer.write_all(&idr[10_000..]).unwrap();
    owner.read_stock_with_budget(1, || false).unwrap();
    assert_eq!(owner.g1.cache.usage().0, 1);
    let mut payload = vec![];
    while let Some((r, _, repair)) = owner.g1.cache.next(1) {
        assert_eq!((r.sequence, r.epoch, r.config), (1, 1, 1));
        payload.extend_from_slice(&r.body);
        owner.g1.cache.accepted(&r, repair).unwrap();
    }
    assert_eq!(payload, idr[12..]);
    owner.retire(Error::Retired);
    assert!(owner.cleanup().unwrap().complete);
}

#[test]
fn elapsed_refill_budget_yields_without_losing_the_ready_au() {
    let (mut owner, mut producer, _control) = peer();
    let (_, idr) = fixture_with_sei(20_000);
    producer.write_all(&idr).unwrap();
    owner.read_stock_with_budget(1, || true).unwrap();
    assert_eq!(owner.g1.cache.usage().0, 0);
    assert_eq!(owner.active_track, Some(1));
    owner.read_stock_with_budget(1, || false).unwrap();
    let mut payload = vec![];
    while let Some((r, _, repair)) = owner.g1.cache.next(1) {
        payload.extend_from_slice(&r.body);
        owner.g1.cache.accepted(&r, repair).unwrap();
    }
    assert_eq!(payload, idr[12..]);
    owner.retire(Error::Retired);
    assert!(owner.cleanup().unwrap().complete);
}
