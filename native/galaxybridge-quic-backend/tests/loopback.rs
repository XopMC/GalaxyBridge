use galaxybridge_quic::{tls::Identity, Endpoint};
use galaxybridge_quic_backend::{
    bootstrap::Binding,
    bulk::Outcome,
    owner::{Event, OwnerSlot},
    stock::SocketGroup,
    Backend, Role, Side,
};
use galaxybridge_quic_media::Context;
use std::{
    io::{Read, Write},
    os::unix::net::UnixStream,
    time::{Duration, Instant},
};
fn pair() -> (Backend, Backend, UnixStream, UnixStream) {
    let (host, peer, _video, audio, control) = pair_tracks(false);
    (host, peer, audio, control)
}
#[test]
fn recovery_observation_actual_pair_request_write_qualified_source_and_commit() {
    let prior = std::env::var_os("GB_QUIC_RECOVERY_DIAGNOSTICS");
    std::env::set_var("GB_QUIC_RECOVERY_DIAGNOSTICS", "1");
    let (mut host, mut peer, video, mut audio, mut control) = pair_tracks(true);
    host.qa_hold_send_stage_output();
    peer.qa_hold_send_stage_output();
    if let Some(v) = prior {
        std::env::set_var("GB_QUIC_RECOVERY_DIAGNOSTICS", v);
    } else {
        std::env::remove_var("GB_QUIC_RECOVERY_DIAGNOSTICS");
    }
    fn clock() -> Result<u64, galaxybridge_quic_backend::Error> {
        static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
        Ok(START.get_or_init(Instant::now).elapsed().as_nanos() as u64 + 1)
    }
    peer.qa_clock(clock).unwrap();
    host.qa_drop_fragment(1, 2, 0, true).unwrap();
    let mut video = video.unwrap();
    let frames = original_stock("h264");
    let audio_frames = original_stock("aac");
    video.write_all(&[0; 65]).unwrap();
    for bytes in &frames[..6] {
        video.write_all(bytes).unwrap();
    }
    for bytes in &audio_frames[..2] {
        audio.write_all(bytes).unwrap();
    }
    let mut host_events = vec![];
    let mut peer_events = vec![];
    let mut control_bytes = vec![];
    let mut sent = false;
    let mut committed = false;
    let start = Instant::now();
    while !committed {
        let scope = galaxybridge_quic_media::media::first_error::Scope::begin(true);
        let result = host.poll();
        assert!(
            result.is_ok(),
            "host {result:?} site={:?} trace={host_events:?} peer={peer_events:?}",
            scope.observation()
        );
        drop(scope);
        let scope = galaxybridge_quic_media::media::first_error::Scope::begin(true);
        let result = peer.poll();
        assert!(
            result.is_ok(),
            "peer {result:?} site={:?} trace={peer_events:?}",
            scope.observation()
        );
        drop(scope);
        while let Some(event) = host.next_event() {
            if let Event::Media { handle } = event {
                let view = host.check_media(handle).unwrap();
                if view.record.kind == 5 {
                    assert!(matches!(view.record.sequence, 1 | 4));
                    committed = view.record.sequence == 4;
                }
                host.commit_media(handle).unwrap();
                host.release_event(handle).unwrap();
            }
        }
        while peer.next_event().is_some() {}
        host_events.extend(host.qa_recovery_observations());
        peer_events.extend(peer.qa_recovery_observations());
        let mut bytes = [0; 64];
        match control.read(&mut bytes) {
            Ok(n) => control_bytes.extend_from_slice(&bytes[..n]),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            e => panic!("control {e:?}"),
        }
        if control_bytes.len() >= 33 && !sent {
            assert_eq!(control_bytes.len(), 33);
            assert_eq!(control_bytes[0], 23);
            let pts = (u64::from_be_bytes(frames[5][..8].try_into().unwrap()) & ((1u64 << 61) - 1))
                + 33333;
            let mut idr = frames[3].clone();
            idr[..8].copy_from_slice(&((1u64 << 61) | pts).to_be_bytes());
            video.write_all(&idr).unwrap();
            sent = true;
        }
        assert!(start.elapsed() < Duration::from_secs(2));
        std::thread::sleep(Duration::from_micros(100));
    }
    // Both original deadlines now use VIDEO120. Source-aged complete AU3 can
    // expire before observation-aged gap2; neither may renew the publication.
    assert!(
        host_events.iter().any(|e| e[0] == 1
            && e[1] == 1
            && e[2] == 1
            && e[3] == 1
            && matches!((e[6], e[4]), (1, 2) | (3, 3))),
        "host recovery trace {host_events:?}"
    );
    assert!(host_events.iter().any(|e| e[0] == 6));
    assert!(host_events.iter().any(|e| e[0] == 8 && e[6] == 1));
    assert!(peer_events.iter().any(|e| e[0] == 7 && e[6] == 1));
    assert!(peer_events.iter().any(|e| e[0] == 9 && e[6] == 1));
    assert!(peer_events
        .iter()
        .any(|e| e[0] == 10 && e[4] == 4 && e[7] == 1));
    assert!(peer_events
        .iter()
        .any(|e| e[0] == 11 && e[4] == 4 && e[6] >= e[7]));
    assert!(host_events.iter().any(|e| e[0] == 23 && e[4] == 4));
    host.retire(galaxybridge_quic_backend::Error::Retired);
    peer.retire(galaxybridge_quic_backend::Error::Retired);
    let peer_stats = peer.stats(Role::Media);
    let peer_stages = peer.qa_send_stage_observations();
    let host_stages = host.qa_send_stage_observations();
    for (side, rows) in [(1, &host_stages), (2, &peer_stages)] {
        assert!(!rows.is_empty() && rows.len() <= 16);
        assert!(rows.iter().all(|r| r[0] == 1 && r[1] == side));
        assert!(rows
            .windows(2)
            .all(|r| r[0][2] < r[1][2] && r[0][3] <= r[1][3]));
        assert_eq!(rows.last().unwrap()[4], 4);
    }
    let terminal = peer_stages.last().unwrap();
    assert_eq!(
        &terminal[5..8],
        &[
            peer_stats.datagrams_admitted,
            peer_stats.datagrams_generated,
            peer_stats.datagrams_udp_sent
        ]
    );
    assert!(terminal[7] > 0 && terminal[7] <= terminal[6] && terminal[6] <= terminal[5]);
    assert!(
        peer_stages.iter().any(|r| r[4] == 2),
        "real qualified source publication samples before terminal"
    );
    println!("send-stage actual pair host={host_stages:?} peer={peer_stages:?}");
    assert!(host.cleanup().unwrap().complete && peer.cleanup().unwrap().complete);
    println!("recovery-observation actual paired request/full-stock-write/qualified-IDR4/commit/cleanup PASS hostRecords={} peerRecords={}",host_events.len(),peer_events.len());
}
fn pair_tracks(
    video_enabled: bool,
) -> (Backend, Backend, Option<UnixStream>, UnixStream, UnixStream) {
    pair_tracks_delayed(video_enabled, None).0
}

// Test-only bounded UDP transit, preserving complete encrypted datagrams and
// real quiche ACKs. No endpoint injection, packet loss, or synthetic ACKs.
struct DelayedRelay {
    socket: std::net::UdpSocket,
    client: std::net::SocketAddr,
    server: std::net::SocketAddr,
    delay: Duration,
    pending: std::collections::VecDeque<(Instant, std::net::SocketAddr, Vec<u8>)>,
    pending_cap: usize,
    pending_peak: usize,
}
impl DelayedRelay {
    fn pump(&mut self) {
        assert!(self.try_pump().is_ok(), "test relay bound");
    }
    fn try_pump(&mut self) -> Result<(), ()> {
        for _ in 0..64 {
            let mut bytes = [0; 1200];
            match self.socket.recv_from(&mut bytes) {
                Ok((n, from)) => {
                    if self.pending.len() >= self.pending_cap {
                        return Err(());
                    }
                    let to = if from == self.server {
                        self.client
                    } else {
                        assert_eq!(from, self.client);
                        self.server
                    };
                    self.pending
                        .push_back((Instant::now() + self.delay, to, bytes[..n].to_vec()));
                    self.pending_peak = self.pending_peak.max(self.pending.len());
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(e) => panic!("relay receive {e}"),
            }
        }
        while self
            .pending
            .front()
            .is_some_and(|(due, _, _)| *due <= Instant::now())
        {
            let (_, to, bytes) = self.pending.pop_front().unwrap();
            assert_eq!(self.socket.send_to(&bytes, to).unwrap(), bytes.len());
        }
        Ok(())
    }
}

fn pair_tracks_delayed(
    video_enabled: bool,
    delay: Option<Duration>,
) -> (
    (Backend, Backend, Option<UnixStream>, UnixStream, UnixStream),
    Vec<DelayedRelay>,
) {
    pair_tracks_delayed_features(video_enabled, 0, delay)
}

fn pair_tracks_delayed_features(
    video_enabled: bool,
    features: u8,
    delay: Option<Duration>,
) -> (
    (Backend, Backend, Option<UnixStream>, UnixStream, UnixStream),
    Vec<DelayedRelay>,
) {
    let a_slot = OwnerSlot::acquire().unwrap();
    let b_slot = OwnerSlot::acquire().unwrap();
    let mut relays = vec![];
    let channels: Vec<_> = (7..=9)
        .map(|session| {
            let a = Identity::generate().unwrap();
            let b = Identity::generate().unwrap();
            let ap = a.fingerprint();
            let bp = b.fingerprint();
            let server = Endpoint::listen(
                "127.0.0.1:0".parse().unwrap(),
                "127.0.0.1".parse().unwrap(),
                [session; 32],
                b,
                ap,
            )
            .unwrap();
            let relay = delay.map(|_| {
                let socket = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
                socket.set_nonblocking(true).unwrap();
                socket
            });
            let client = Endpoint::connect(
                "127.0.0.1:0".parse().unwrap(),
                relay
                    .as_ref()
                    .map_or_else(|| server.local_addr().unwrap(), |r| r.local_addr().unwrap()),
                [session; 32],
                a,
                bp,
            )
            .unwrap();
            if let Some(socket) = relay {
                relays.push(DelayedRelay {
                    socket,
                    client: client.local_addr().unwrap(),
                    server: server.local_addr().unwrap(),
                    delay: delay.unwrap(),
                    pending: Default::default(),
                    pending_cap: 256,
                    pending_peak: 0,
                });
            }
            (client, server)
        })
        .collect();
    let mut a = vec![];
    let mut b = vec![];
    for (client, server) in channels {
        a.push(client);
        b.push(server);
    }
    let context = Context {
        session: [7; 32],
        generation: 1,
        scid: 1,
        capture_kind: 0,
        display_id: 0,
        target_token: 9,
        enabled: (if video_enabled { 7 } else { 6 }) | features,
    };
    let binding = Binding {
        nonce: [3; 32],
        context,
        sidecar_sha: [4; 32],
    };
    let (audio, producer_audio) = UnixStream::pair().unwrap();
    let (video, producer_video) = if video_enabled {
        let (a, b) = UnixStream::pair().unwrap();
        (Some(a), Some(b))
    } else {
        (None, None)
    };
    let (control, producer_control) = UnixStream::pair().unwrap();
    producer_control.set_nonblocking(true).unwrap();
    (
        (
            Backend::from_channels(
                a_slot,
                Side::Host,
                binding.clone(),
                a.try_into().ok().unwrap(),
                None,
            )
            .unwrap(),
            Backend::from_channels(
                b_slot,
                Side::Peer,
                binding,
                b.try_into().ok().unwrap(),
                Some(SocketGroup::connected(video, Some(audio), control).unwrap()),
            )
            .unwrap(),
            producer_video,
            producer_audio,
            producer_control,
        ),
        relays,
    )
}

#[test]
fn fragmented_idr_actual_backend_thirty_ms_rtt_mixed_recovery() {
    let mut failures = vec![];
    for size in [5504usize, 64193, 199745] {
        let prior = std::env::var_os("GB_QUIC_RECOVERY_DIAGNOSTICS");
        std::env::set_var("GB_QUIC_RECOVERY_DIAGNOSTICS", "1");
        let ((mut host, mut peer, video, mut audio, mut control), mut relays) =
            pair_tracks_delayed(true, Some(Duration::from_millis(15)));
        if let Some(v) = prior {
            std::env::set_var("GB_QUIC_RECOVERY_DIAGNOSTICS", v);
        } else {
            std::env::remove_var("GB_QUIC_RECOVERY_DIAGNOSTICS");
        }
        fn clock() -> Result<u64, galaxybridge_quic_backend::Error> {
            static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
            Ok(START.get_or_init(Instant::now).elapsed().as_nanos() as u64 + 1)
        }
        peer.qa_clock(clock).unwrap();
        // Only dependent2 is impaired, never the initial or recovery IDR. The
        // cold209 case can expire it at Source before this filter sees it.
        host.qa_drop_fragment(1, 2, 0, true).unwrap();
        let frames = original_stock("h264");
        let aac = original_stock("aac");
        let mut video = video.unwrap();
        video.write_all(&[0; 65]).unwrap();
        // Original encoded IDR slices are unchanged. A standards-shaped filler
        // NAL supplies realistic transport size, not extra picture complexity.
        let mut idr = frames[3].clone();
        if size > idr.len() - 12 {
            let filler = size - (idr.len() - 12);
            assert!(filler >= 6);
            idr.extend_from_slice(&[0, 0, 0, 1, 12]);
            idr.resize(idr.len() + filler - 6, 0xff);
            idr.push(0x80);
            idr[8..12].copy_from_slice(&(size as u32).to_be_bytes());
        }
        assert_eq!(idr.len() - 12, size);
        let config = galaxybridge_quic_media::codec::Configuration::parse(
            galaxybridge_quic_media::codec::Codec::H264,
            &frames[2][12..],
        )
        .unwrap();
        assert!(config.independent(&idr[12..], true).unwrap());
        for bytes in &frames[..3] {
            video.write_all(bytes).unwrap();
        }
        for bytes in &aac[..2] {
            audio.write_all(bytes).unwrap();
        }
        video.set_nonblocking(true).unwrap();
        let mut pending_video: Option<(Vec<u8>, usize)> = None;
        let start = Instant::now();
        let mut ready = false;
        let mut sent_at = None;
        let mut delivered = vec![];
        let mut audio_count = 0;
        let mut requests = vec![];
        let mut audio_delivered = vec![];
        let mut audio_offered = vec![];
        let mut traces = vec![];
        let mut source_traces = vec![];
        let mut sampled = 0;
        let mut recovery_sent = false;
        let recovery_sequence = 5u64;
        let mut recovery_sequences = vec![];
        let mut recovery_at = None;
        let mut dependents = 0usize;
        let mut recovery_dependents = 0usize;
        let mut audio_sent = 0usize;
        let mut residency_last = [0usize; 10];
        let mut residency_samples = 0usize;
        while start.elapsed() < Duration::from_secs(2) {
            for relay in &mut relays {
                relay.pump();
            }
            host.poll().unwrap();
            peer.poll().unwrap();
            let usage = peer.qa_media_usage();
            if recovery_sent && residency_samples < 96 && usage != residency_last {
                let policy = peer.qa_policy_snapshot();
                println!("fragment-residency size={size} us={} cache_slots={} cache_bytes={} video_admitted={} audio_admitted={} video_dropped={} audio_dropped={} video_ack={} audio_ack={} repair={}",start.elapsed().as_micros(),usage[2],usage[3],policy[0],policy[1],policy[2],policy[3],policy[17],policy[18],policy[19]);
                residency_last = usage;
                residency_samples += 1;
            }
            while let Some(event) = host.next_event() {
                match event {
                    Event::Ready => ready = true,
                    Event::Media { handle } => {
                        let view = match host.check_media(handle) {
                            Ok(view) => view,
                            Err(galaxybridge_quic_backend::Error::Deadline) => {
                                host.release_event(handle).unwrap();
                                continue;
                            }
                            Err(error) => panic!("consumer check {error:?}"),
                        };
                        if view.record.kind == 5 {
                            if view.record.track == 1 {
                                delivered.push((view.record.sequence, start.elapsed().as_micros()));
                            } else {
                                audio_count += 1;
                                audio_delivered.push(view.record.sequence);
                            }
                        }
                        host.commit_media(handle).unwrap();
                        host.release_event(handle).unwrap();
                    }
                    _ => {}
                }
            }
            while peer.next_event().is_some() {}
            if ready && sent_at.is_none() {
                pending_video = Some((idr.clone(), 0));
                sent_at = Some(Instant::now());
            }
            let mut bytes = [0; 128];
            match control.read(&mut bytes) {
                Ok(n) => {
                    assert!(
                        requests.len() + n <= 33 * 6,
                        "finite actual sync request capture"
                    );
                    requests.extend_from_slice(&bytes[..n]);
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                e => panic!("control {e:?}"),
            }
            if requests.len() >= 33 && !recovery_sent {
                assert_eq!(requests[0], 23);
                // Same size qualified recovery, not a tiny substitute success.
                let pts = 1_000_000 + (recovery_sequence - 1) * 16_667;
                let mut fresh = idr.clone();
                fresh[..8].copy_from_slice(&((1u64 << 61) | pts).to_be_bytes());
                assert!(pending_video.is_none());
                pending_video = Some((fresh, 0));
                recovery_sent = true;
                recovery_sequences.push(recovery_sequence);
                recovery_at = Some(Instant::now());
            }
            if recovery_sent
                && requests.len() / 33 > recovery_sequences.len()
                && pending_video.is_none()
            {
                let sequence = recovery_sequence
                    + recovery_dependents as u64
                    + recovery_sequences.len() as u64;
                let pts = 1_000_000 + (sequence - 1) * 16_667;
                let mut fresh = idr.clone();
                fresh[..8].copy_from_slice(&((1u64 << 61) | pts).to_be_bytes());
                pending_video = Some((fresh, 0));
                recovery_sequences.push(sequence);
            }
            if let Some(at) = sent_at {
                if dependents < 3
                    && pending_video.is_none()
                    && at.elapsed().as_micros() >= (dependents as u128 + 1) * 16_667
                {
                    pending_video = Some((frames[4 + dependents].clone(), 0));
                    dependents += 1;
                }
                if audio_sent < 75 && at.elapsed().as_micros() >= audio_sent as u128 * 21_334 {
                    let mut packet = aac[2].clone();
                    let pts =
                        u64::from_be_bytes(packet[..8].try_into().unwrap()) & ((1u64 << 61) - 1);
                    packet[..8].copy_from_slice(&(pts + audio_sent as u64 * 21_334).to_be_bytes());
                    audio.write_all(&packet).unwrap();
                    audio_sent += 1;
                    audio_offered.push((audio_sent as u64, start.elapsed().as_micros()));
                }
            }
            if let Some(at) = recovery_at {
                if recovery_dependents < 60
                    && pending_video.is_none()
                    && at.elapsed().as_micros() >= (recovery_dependents as u128 + 1) * 16_667
                {
                    let mut packet = frames[4 + recovery_dependents % 3].clone();
                    let sequence = recovery_sequence
                        + recovery_dependents as u64
                        + recovery_sequences.len() as u64;
                    let pts = 1_000_000 + (sequence - 1) * 16_667;
                    packet[..8].copy_from_slice(&pts.to_be_bytes());
                    let filler = 16_384 - (packet.len() - 12);
                    packet.extend_from_slice(&[0, 0, 0, 1, 12]);
                    packet.resize(packet.len() + filler - 6, 0xff);
                    packet.push(0x80);
                    packet[8..12].copy_from_slice(&16_384u32.to_be_bytes());
                    assert!(!config.independent(&packet[12..], false).unwrap());
                    pending_video = Some((packet, 0));
                    recovery_dependents += 1;
                }
            }
            if let Some((bytes, at)) = pending_video.as_mut() {
                match video.write(&bytes[*at..]) {
                    Ok(n) => {
                        assert!(n > 0);
                        *at += n;
                        if *at == bytes.len() {
                            pending_video = None;
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                    Err(e) => panic!("bounded producer write {e}"),
                }
            }
            traces.extend(host.qa_recovery_observations());
            for event in peer.qa_recovery_observations() {
                if event[0] == 11 && source_traces.last() == Some(&event) {
                    continue;
                }
                source_traces.push(event);
            }
            if let Some(at) = sent_at {
                let ms = at.elapsed().as_millis();
                if ms / 10 > sampled && ms <= 160 {
                    sampled = ms / 10;
                    let s = peer.stats(Role::Media);
                    let r = host.stats(Role::Media);
                    println!("fragment-sample size={size} ms={ms} admitted={} generated={} udp={} received={} expired={} cwnd={} rtt_ns={}",
                        s.datagrams_admitted,s.datagrams_generated,s.datagrams_udp_sent,r.datagrams_received,s.expired,s.path.cwnd_bytes,s.path.rtt_ns);
                }
            }
            std::thread::sleep(Duration::from_micros(250));
        }
        let s = peer.stats(Role::Media);
        let r = host.stats(Role::Media);
        println!("fragment-result size={size} count={} delivered={delivered:?} audio={audio_count} requests={} admitted={} generated={} udp={} received={} expired={} host={traces:?} source={source_traces:?}",
            size.div_ceil(960),requests.len()/33,s.datagrams_admitted,s.datagrams_generated,s.datagrams_udp_sent,r.datagrams_received,s.expired);
        let source_at = sent_at.unwrap().duration_since(start).as_micros();
        let recovered = delivered
            .iter()
            .find(|(seq, _)| *seq == recovery_sequence)
            .map(|(_, at)| at - source_at);
        let post = (recovery_sequence + 1..=recovery_sequence + 60)
            .filter(|sequence| delivered.iter().any(|(seq, _)| seq == sequence))
            .count();
        let health = host.qa_policy_snapshot();
        let source = peer.qa_policy_snapshot();
        assert_eq!(
            source[31], 0,
            "a recovery IDR must stay on the expiring datagram/FEC path"
        );
        let recovery_delivery = delivered
            .iter()
            .find(|(seq, _)| *seq == recovery_sequence)
            .map(|(_, at)| *at)
            .unwrap_or(u128::MAX);
        let post_audio: Vec<_> = audio_offered
            .iter()
            .filter(|(_, at)| *at >= recovery_delivery)
            .map(|(seq, _)| *seq)
            .collect();
        assert!(!post_audio.is_empty()&&post_audio.iter().all(|seq|audio_delivered.contains(seq)),"all actually offered post-recovery audio must continue: expected={post_audio:?} delivered={audio_delivered:?}");
        let final_recovery = recovery_sequences
            .last()
            .copied()
            .unwrap_or(recovery_sequence);
        let tail = delivered
            .iter()
            .filter(|(sequence, _)| *sequence > final_recovery)
            .count();
        println!("fragment-chain size={size} dependentDrops={} recovered_us={recovered:?} post={post}/60 recovery_sequences={recovery_sequences:?} tail={tail} audio={audio_count}/{audio_sent} requests={} health={health:?} source={source:?}",host.qa_dropped(),requests.len()/33);
        println!("fragment-audio size={size} cold_offered={} cold_delivered={} post_offered={} post_delivered={}",audio_sent-post_audio.len(),audio_delivered.iter().filter(|seq|!post_audio.contains(seq)).count(),post_audio.len(),post_audio.iter().filter(|seq|audio_delivered.contains(seq)).count());
        if !delivered.iter().any(|(seq, _)| *seq == 1)
            || recovered.is_none_or(|t| t > 500_000)
            || !recovery_sequences
                .iter()
                .all(|sequence| delivered.iter().any(|(got, _)| got == sequence))
            || tail == 0
            || requests.len() / 33 != recovery_sequences.len()
            || health[28] != 1
            || health[29] != 0
        {
            failures.push(size);
        }
        assert!(audio_count > 0, "audio contrast");
        host.retire(galaxybridge_quic_backend::Error::Retired);
        peer.retire(galaxybridge_quic_backend::Error::Retired);
        assert!(host.cleanup().unwrap().complete && peer.cleanup().unwrap().complete);
    }
    assert!(
        failures.is_empty(),
        "initial/recovered independent and60P mixed chain failed at30ms RTT: {failures:?}"
    );
}

#[test]
fn motion_chain_ordinary_observed_sizes_after_quiet_thirty_ms_rtt() {
    fn sample(peer: &Backend, start: Instant, phase: u8, sequence: u64, count: &mut usize) {
        assert!(*count < 16, "bounded causal snapshots");
        *count += 1;
        let s = peer.stats(Role::Media);
        let p = s.path;
        let u = peer.qa_media_usage();
        let policy = peer.qa_policy_snapshot();
        println!("motion-pressure n={} phase={phase} seq={sequence} us={} cached_path_ns={} path_samples={} path_valid={} path_available={} rtt_available={} cwnd={} rtt_ns={} rate={} lost={} pto={} dg_queue={} generated_queue={} dg_admitted={} dg_generated={} dg_udp={} done_pending={} future_send={} udp_block={} expiry_submission={} expiry_queued={} expiry_generated={} source_slots={} source_bytes={} video_ack={} audio_ack={}",*count,start.elapsed().as_micros(),p.sample_at_ns,p.samples,p.valid,p.available,p.rtt_available,p.cwnd_bytes,p.rtt_ns,p.delivery_rate_bytes_per_second,p.lost_packets,p.pto_count,s.datagram_queue_records,s.generated_packets,s.datagrams_admitted,s.datagrams_generated,s.datagrams_udp_sent,s.pressure.quiche_done_pending_dg,s.pressure.future_send_stops,s.pressure.udp_would_block,s.pressure.expiry_submission,s.pressure.expiry_queued,s.pressure.expiry_generated,u[2],u[3],policy[17],policy[18]);
    }
    let prior = std::env::var_os("GB_QUIC_RECOVERY_DIAGNOSTICS");
    std::env::set_var("GB_QUIC_RECOVERY_DIAGNOSTICS", "1");
    let ((mut host, mut peer, video, mut audio, mut control), mut relays) =
        pair_tracks_delayed(true, Some(Duration::from_millis(15)));
    if let Some(v) = prior {
        std::env::set_var("GB_QUIC_RECOVERY_DIAGNOSTICS", v);
    } else {
        std::env::remove_var("GB_QUIC_RECOVERY_DIAGNOSTICS");
    }
    fn clock() -> Result<u64, galaxybridge_quic_backend::Error> {
        static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
        Ok(START.get_or_init(Instant::now).elapsed().as_nanos() as u64 + 1)
    }
    peer.qa_clock(clock).unwrap();
    let frames = original_stock("h264");
    let aac = original_stock("aac");
    let config = galaxybridge_quic_media::codec::Configuration::parse(
        galaxybridge_quic_media::codec::Codec::H264,
        &frames[2][12..],
    )
    .unwrap();
    let mut video = video.unwrap();
    video.write_all(&[0; 65]).unwrap();
    for bytes in &frames[..3] {
        video.write_all(bytes).unwrap();
    }
    for bytes in &aac[..2] {
        audio.write_all(bytes).unwrap();
    }
    video.set_nonblocking(true).unwrap();
    // Synthetic transport sizes only; original VCL bytes are unchanged. The
    // six-frame mixture averages13.60024Mbps at60fps, not64KB on every frame.
    let sizes = [50_370usize, 64_183, 6_298, 16_384, 16_384, 16_384];
    let start = Instant::now();
    let mut source_at = None;
    let mut ready = false;
    let mut pending: Option<(Vec<u8>, usize)> = None;
    let mut slots = 0usize;
    let mut ordinary = 0usize;
    let mut audio_sent = 0usize;
    let mut sequence = 0u64;
    let mut responses = 0usize;
    let mut requests = vec![];
    let mut offered = vec![];
    let mut delivered = vec![];
    let mut audio_count = 0;
    let mut traces = vec![];
    let mut source_traces = vec![];
    let mut expired_checks = 0;
    let mut pressure_samples = 0;
    let mut periodic_sample = 0;
    let mut expiry_sample = false;
    while start.elapsed() < Duration::from_secs(2) {
        for relay in &mut relays {
            relay.pump();
        }
        host.poll().unwrap();
        peer.poll().unwrap();
        while let Some(event) = host.next_event() {
            match event {
                Event::Ready => ready = true,
                Event::Media { handle } => {
                    let view = match host.check_media(handle) {
                        Ok(view) => view,
                        Err(galaxybridge_quic_backend::Error::Deadline) => {
                            expired_checks += 1;
                            host.release_event(handle).unwrap();
                            continue;
                        }
                        Err(e) => panic!("consumer check {e:?}"),
                    };
                    if view.record.kind == 5 {
                        if view.record.track == 1 {
                            delivered.push((view.record.sequence, start.elapsed().as_micros()));
                        } else {
                            audio_count += 1;
                        }
                    }
                    host.commit_media(handle).unwrap();
                    host.release_event(handle).unwrap();
                }
                _ => {}
            }
        }
        while peer.next_event().is_some() {}
        if ready && source_at.is_none() {
            source_at = Some(Instant::now());
            sequence = 1;
            pending = Some((frames[3].clone(), 0));
            offered.push((
                sequence,
                frames[3].len() - 12,
                true,
                start.elapsed().as_micros(),
            ));
            sample(&peer, start, 0, sequence, &mut pressure_samples);
        }
        let mut bytes = [0; 128];
        match control.read(&mut bytes) {
            Ok(n) => {
                assert!(requests.len() + n <= 33 * 16);
                requests.extend_from_slice(&bytes[..n]);
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            e => panic!("control {e:?}"),
        }
        if let Some(at) = source_at {
            if audio_sent < 75 && at.elapsed().as_micros() >= audio_sent as u128 * 21_334 {
                let mut packet = aac[2].clone();
                let pts = u64::from_be_bytes(packet[..8].try_into().unwrap()) & ((1u64 << 61) - 1);
                packet[..8].copy_from_slice(&(pts + audio_sent as u64 * 21_334).to_be_bytes());
                audio.write_all(&packet).unwrap();
                audio_sent += 1;
            }
            // Neither initial commit nor recovery commit controls production.
            // After400ms quiet video, ordinary AUs continue at source60fps.
            // A real parsed33-byte sync request replaces the NEXT source slot
            // with an IDR; no immediate fake ACK or receiver-conditioned wait.
            if ordinary < 60
                && pending.is_none()
                && at.elapsed().as_micros() >= 400_000 + slots as u128 * 16_667
            {
                let independent = requests.len() / 33 > responses;
                let mut packet = if independent {
                    responses += 1;
                    frames[3].clone()
                } else {
                    frames[4 + ordinary % 3].clone()
                };
                sequence += 1;
                let pts = 1_000_000 + 400_000 + slots as u64 * 16_667;
                packet[..8].copy_from_slice(
                    &(pts | if independent { 1u64 << 61 } else { 0 }).to_be_bytes(),
                );
                let size = if independent {
                    64_193
                } else {
                    sizes[ordinary % sizes.len()]
                };
                let filler = size - (packet.len() - 12);
                assert!(filler >= 6);
                packet.extend_from_slice(&[0, 0, 0, 1, 12]);
                packet.resize(packet.len() + filler - 6, 0xff);
                packet.push(0x80);
                packet[8..12].copy_from_slice(&(size as u32).to_be_bytes());
                assert_eq!(
                    config.independent(&packet[12..], independent).unwrap(),
                    independent
                );
                offered.push((sequence, size, independent, start.elapsed().as_micros()));
                if sequence <= 3 {
                    sample(&peer, start, 1, sequence, &mut pressure_samples);
                }
                pending = Some((packet, 0));
                slots += 1;
                if !independent {
                    ordinary += 1;
                }
            }
            let burst_us = at.elapsed().as_micros().saturating_sub(400_000);
            if at.elapsed().as_micros() >= 400_000
                && periodic_sample < 8
                && burst_us >= (periodic_sample + 1) * 20_000
            {
                periodic_sample += 1;
                sample(&peer, start, 2, sequence, &mut pressure_samples);
            }
        }
        if let Some((bytes, at)) = pending.as_mut() {
            match video.write(&bytes[*at..]) {
                Ok(n) => {
                    assert!(n > 0);
                    *at += n;
                    if *at == bytes.len() {
                        pending = None;
                    }
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                Err(e) => panic!("producer {e}"),
            }
        }
        let events = host.qa_recovery_observations();
        if !expiry_sample && events.iter().any(|e| e[0] == 1) {
            expiry_sample = true;
            sample(
                &peer,
                start,
                3,
                events.iter().find(|e| e[0] == 1).unwrap()[4],
                &mut pressure_samples,
            );
        }
        traces.extend(events);
        source_traces.extend(peer.qa_recovery_observations());
        assert!(
            traces.len() <= 1024 && source_traces.len() <= 1024,
            "finite content-free fate capture"
        );
        std::thread::sleep(Duration::from_micros(250));
    }
    let health = host.qa_policy_snapshot();
    let source = peer.qa_policy_snapshot();
    sample(&peer, start, 4, sequence, &mut pressure_samples);
    let sent = peer.stats(Role::Media);
    let received = host.stats(Role::Media);
    println!("motion-chain offered={offered:?} delivered={delivered:?} audio={audio_count}/{audio_sent} requests={} responses={responses} expired_checks={expired_checks} health={health:?} source={source:?} generated={} udp={} received={} expired={} host_trace={traces:?} source_trace={source_traces:?}",requests.len()/33,sent.datagrams_generated,sent.datagrams_udp_sent,received.datagrams_received,sent.expired);
    for request in requests.chunks_exact(33) {
        assert_eq!(request[0], 23);
    }
    let first_ordinary_delivered = delivered.iter().any(|(seq, _)| *seq == 2);
    host.retire(galaxybridge_quic_backend::Error::Retired);
    peer.retire(galaxybridge_quic_backend::Error::Retired);
    assert!(host.cleanup().unwrap().complete && peer.cleanup().unwrap().complete);
    assert_eq!(ordinary, 60, "unchanged source cadence must complete");
    assert!(
        audio_count > 0 && delivered.iter().any(|(seq, _)| *seq == 1),
        "actual startup/audio prerequisites"
    );
    assert!(first_ordinary_delivered,"no-loss observed53-fragment ordinary AU2 expired before actual consumer commit; see original-cutoff/source fate above");
    let ordinary_delivered = offered
        .iter()
        .filter(|(seq, _, key, _)| !*key && delivered.iter().any(|(got, _)| got == seq))
        .count();
    assert_eq!(
        ordinary_delivered, 60,
        "all source-paced ordinary video must arrive, not just first burst"
    );
    assert_eq!(
        (audio_count, audio_sent),
        (75, 75),
        "all concurrent audio must arrive"
    );
    assert_eq!(
        (health[28], health[29]),
        (1, 0),
        "final video Live, not recovering/exhausted"
    );
}

#[test]
fn delivery_regression_observed_keys_at_thirty_and_115_ms_rtt() {
    fn sample(peer: &Backend, start: Instant, rtt: u64, phase: u8, seq: u64, count: &mut usize) {
        assert!(*count < 16);
        *count += 1;
        let s = peer.stats(Role::Media);
        let p = s.path;
        let u = peer.qa_media_usage();
        println!("delivery-pressure rtt={rtt} n={} phase={phase} seq={seq} us={} cached_path_ns={} path_samples={} valid={} available={} measured_rtt_ns={} cwnd={} lost={} pto={} dg_queue={} generated_queue={} admitted={} delivered={} reliable_admitted={} reliable_delivered={} reliable_backlog={} received_queue={} received_bytes={} dg_admitted={} generated={} udp={} done={} pacing={} wouldblock={} expiry_submission={} expiry_queued={} expiry_generated={} source_slots={} source_bytes={}",
            *count, start.elapsed().as_micros(), p.sample_at_ns, p.samples, p.valid, p.available,
            p.rtt_ns, p.cwnd_bytes, p.lost_packets, p.pto_count, s.datagram_queue_records,
            s.generated_packets, s.admitted, s.delivered,
            s.admitted.saturating_sub(s.datagrams_admitted),
            s.delivered.saturating_sub(s.datagrams_received), s.reliable_backlog_bytes,
            s.receive_queue_records, s.receive_queue_bytes, s.datagrams_admitted,
            s.datagrams_generated, s.datagrams_udp_sent,
            s.pressure.quiche_done_pending_dg, s.pressure.future_send_stops, s.pressure.udp_would_block,
            s.pressure.expiry_submission, s.pressure.expiry_queued, s.pressure.expiry_generated, u[2], u[3]);
    }
    fn padded(frame: &[u8], size: usize, pts: u64, key: bool) -> Vec<u8> {
        let mut b = frame.to_vec();
        let filler = size - (b.len() - 12);
        assert!(filler >= 6);
        b[..8].copy_from_slice(&(pts | if key { 1u64 << 61 } else { 0 }).to_be_bytes());
        b.extend_from_slice(&[0, 0, 0, 1, 12]);
        b.resize(b.len() + filler - 6, 0xff);
        b.push(0x80);
        b[8..12].copy_from_slice(&(size as u32).to_be_bytes());
        b
    }
    let mut failures = vec![];
    for rtt in [30u64, 115] {
        if let Ok(selected) = std::env::var("GB_DELIVERY_RTT_MS") {
            assert!(
                matches!(selected.as_str(), "30" | "115"),
                "exact controlled case only"
            );
            if selected.parse::<u64>().unwrap() != rtt {
                continue;
            }
        }
        let prior = std::env::var_os("GB_QUIC_RECOVERY_DIAGNOSTICS");
        std::env::set_var("GB_QUIC_RECOVERY_DIAGNOSTICS", "1");
        let ((mut host, mut peer, video, mut audio, mut control), mut relays) =
            pair_tracks_delayed(true, Some(Duration::from_micros(rtt * 500)));
        if rtt == 115 {
            for relay in &mut relays {
                relay.pending_cap = 1024;
            }
        }
        if let Some(v) = prior {
            std::env::set_var("GB_QUIC_RECOVERY_DIAGNOSTICS", v);
        } else {
            std::env::remove_var("GB_QUIC_RECOVERY_DIAGNOSTICS");
        }
        fn clock() -> Result<u64, galaxybridge_quic_backend::Error> {
            static START: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();
            Ok(START.get_or_init(Instant::now).elapsed().as_nanos() as u64 + 1)
        }
        peer.qa_clock(clock).unwrap();
        host.qa_drop_fragment(1, 2, 0, true).unwrap();
        let frames = original_stock("h264");
        let aac = original_stock("aac");
        let config = galaxybridge_quic_media::codec::Configuration::parse(
            galaxybridge_quic_media::codec::Codec::H264,
            &frames[2][12..],
        )
        .unwrap();
        let mut video = video.unwrap();
        video.write_all(&[0; 65]).unwrap();
        for b in &frames[..3] {
            video.write_all(b).unwrap();
        }
        for b in &aac[..2] {
            audio.write_all(b).unwrap();
        }
        video.set_nonblocking(true).unwrap();
        let start = Instant::now();
        let mut source_at = None;
        let mut ready = false;
        let mut pending: Option<(Vec<u8>, usize)> = None;
        let mut requests = vec![];
        let mut request_times = vec![];
        let mut responses = 0;
        let mut sequence = 0;
        let mut ordinary = 0usize;
        let mut slots = 0usize;
        let mut audio_sent = 0usize;
        let mut offered = vec![];
        let mut delivered = vec![];
        let mut audio_got = 0;
        let mut recovered = false;
        let mut consumer_declined = None;
        let mut traces = vec![];
        let mut source_traces = vec![];
        let mut count = 0;
        let mut periodic = 0;
        let mut error = None;
        while start.elapsed() < Duration::from_secs(4) {
            if relays.iter_mut().any(|relay| relay.try_pump().is_err()) {
                error = Some(("test-relay-cap", galaxybridge_quic_backend::Error::Capacity));
                break;
            }
            let host_first = galaxybridge_quic_media::media::first_error::Scope::begin(true);
            if let Err(e) = host.poll() {
                println!(
                    "delivery-host-first rtt={rtt} error={e:?} observation={:?}",
                    host_first.observation()
                );
                error = Some(("host", e));
                break;
            }
            if let Err(e) = peer.poll() {
                error = Some(("peer", e));
                break;
            }
            while let Some(e) = host.next_event() {
                match e {
                    Event::Ready => ready = true,
                    Event::Media { handle } => {
                        match host.check_media(handle) {
                            Ok(v) => {
                                let seq = v.record.sequence;
                                let is_video = v.record.kind == 5 && v.record.track == 1;
                                let is_key = offered.iter().any(|(s, _, key, _)| *s == seq && *key);
                                if is_video && recovered && !is_key && consumer_declined.is_none() {
                                    // A distinct actual consumer-input pressure stimulus, not wire loss.
                                    host.decline_media(handle, galaxybridge_quic_media::media::MediaDeclineReason::Pressure).unwrap();
                                    host.release_event(handle).unwrap();
                                    consumer_declined = Some(seq);
                                    sample(&peer, start, rtt, 3, seq, &mut count);
                                    continue;
                                }
                                if v.record.kind == 5 {
                                    if v.record.track == 1 {
                                        delivered
                                            .push((v.record.sequence, start.elapsed().as_micros()));
                                    } else {
                                        audio_got += 1;
                                    }
                                }
                                host.commit_media(handle).unwrap();
                                if is_video
                                    && offered
                                        .iter()
                                        .any(|(s, size, _, _)| *s == seq && *size == 127349)
                                {
                                    recovered = true;
                                }
                            }
                            Err(galaxybridge_quic_backend::Error::Deadline) => {
                                // check_media() advances expiry first; the receiver has
                                // already declined this held output exactly once.
                            }
                            Err(e) => panic!("consumer {e:?}"),
                        }
                        host.release_event(handle).unwrap();
                    }
                    _ => {}
                }
            }
            while peer.next_event().is_some() {}
            if ready && source_at.is_none() {
                source_at = Some(Instant::now());
                sequence = 1;
                pending = Some((padded(&frames[3], 64193, 1_000_000, true), 0));
                offered.push((1, 64193, true, start.elapsed().as_micros()));
                sample(&peer, start, rtt, 0, 1, &mut count);
            }
            let mut b = [0; 128];
            match control.read(&mut b) {
                Ok(n) => {
                    assert!(requests.len() + n <= 33 * 16);
                    requests.extend_from_slice(&b[..n]);
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                e => panic!("control {e:?}"),
            }
            while request_times.len() < requests.len() / 33 {
                request_times.push(Instant::now());
            }
            if let Some(at) = source_at {
                if audio_sent < 120 && at.elapsed().as_micros() >= audio_sent as u128 * 21_334 {
                    let mut packet = aac[2].clone();
                    packet[..8]
                        .copy_from_slice(&(1_000_000 + audio_sent as u64 * 21_334).to_be_bytes());
                    audio.write_all(&packet).unwrap();
                    audio_sent += 1;
                }
                let response_due = responses < 2
                    && request_times.get(responses).is_some_and(|t| {
                        t.elapsed() >= Duration::from_millis(if responses == 0 { 60 } else { 78 })
                    });
                if pending.is_none()
                    && (response_due
                        || (ordinary < 90
                            && at.elapsed().as_micros() >= 200_000 + slots as u128 * 16_667))
                {
                    let key = response_due;
                    let size = if key {
                        [127349, 149956][responses]
                    } else {
                        [50370, 64183, 6298, 16384, 16384, 16384][ordinary % 6]
                    };
                    sequence += 1;
                    let packet = padded(
                        if key {
                            &frames[3]
                        } else {
                            &frames[4 + ordinary % 3]
                        },
                        size,
                        1_000_000 + at.elapsed().as_micros() as u64,
                        key,
                    );
                    assert_eq!(config.independent(&packet[12..], key).unwrap(), key);
                    if key {
                        responses += 1;
                        sample(&peer, start, rtt, 1, sequence, &mut count);
                    } else {
                        ordinary += 1;
                    }
                    offered.push((sequence, size, key, start.elapsed().as_micros()));
                    pending = Some((packet, 0));
                    slots += 1;
                }
                // At most12 early snapshots; the terminal result owns a reserved slot.
                if periodic < 9 && at.elapsed().as_millis() >= (periodic + 1) * 200 {
                    periodic += 1;
                    sample(&peer, start, rtt, 2, sequence, &mut count);
                }
            }
            if let Some((b, at)) = pending.as_mut() {
                match video.write(&b[*at..]) {
                    Ok(n) => {
                        assert!(n > 0);
                        *at += n;
                        if *at == b.len() {
                            pending = None;
                        }
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                    Err(e) => panic!("producer {e}"),
                }
            }
            traces.extend(host.qa_recovery_observations());
            source_traces.extend(peer.qa_recovery_observations());
            assert!(traces.len() <= 2048 && source_traces.len() <= 2048);
            std::thread::sleep(Duration::from_micros(250));
        }
        sample(&peer, start, rtt, 9, sequence, &mut count);
        println!(
            "delivery-relay rtt={rtt} cap={} peak={:?} pending={:?}",
            relays[0].pending_cap,
            relays.iter().map(|r| r.pending_peak).collect::<Vec<_>>(),
            relays.iter().map(|r| r.pending.len()).collect::<Vec<_>>()
        );
        let health = host.qa_policy_snapshot();
        let source = peer.qa_policy_snapshot();
        let host_media = host.stats(Role::Media);
        let peer_media = peer.stats(Role::Media);
        println!("delivery-endpoint rtt={rtt} host_admitted={} host_delivered={} host_dg_received={} host_reliable_delivered={} host_rejected={} host_expired={} host_receive_queue={} host_receive_bytes={} peer_admitted={} peer_dg_admitted={} peer_reliable_admitted={} peer_reliable_backlog={} peer_rejected={} peer_expired={}",
            host_media.admitted, host_media.delivered, host_media.datagrams_received,
            host_media.delivered.saturating_sub(host_media.datagrams_received), host_media.rejected,
            host_media.expired, host_media.receive_queue_records, host_media.receive_queue_bytes,
            peer_media.admitted, peer_media.datagrams_admitted,
            peer_media.admitted.saturating_sub(peer_media.datagrams_admitted),
            peer_media.reliable_backlog_bytes, peer_media.rejected, peer_media.expired);
        let keys: Vec<_> = offered
            .iter()
            .filter(|(_, _, key, _)| *key)
            .map(|(seq, size, _, _)| (*seq, *size, delivered.iter().any(|(got, _)| got == seq)))
            .collect();
        println!("delivery-terminal rtt={rtt} error={error:?} wire_omitted=2 consumer_pressure_declined={consumer_declined:?} keys={keys:?} audio={audio_got}/{audio_sent} ordinary={ordinary} requests={} responses={responses} snapshots={count} health={health:?} source={source:?} offered={offered:?} delivered={delivered:?} host_trace={traces:?} source_trace={source_traces:?}",requests.len()/33);
        for request in requests.chunks_exact(33) {
            assert_eq!(request[0], 23);
        }
        host.retire(galaxybridge_quic_backend::Error::Retired);
        peer.retire(galaxybridge_quic_backend::Error::Retired);
        assert!(host.cleanup().unwrap().complete && peer.cleanup().unwrap().complete);
        if error.is_some()
            || responses != 2
            || ordinary != 90
            || keys.iter().any(|(_, _, got)| !*got)
        {
            failures.push((rtt, keys, error, responses, ordinary));
        }
    }
    assert!(
        failures.is_empty(),
        "produced unimpeded keyframes did not all commit: {failures:?}"
    );
}

fn stock_frame(flags: u64, body: &[u8]) -> Vec<u8> {
    let mut b = flags.to_be_bytes().to_vec();
    b.extend((body.len() as u32).to_be_bytes());
    b.extend(body);
    b
}
// Independently specified baseline-profile 64x32 SPS/PPS and IDR header.
// Entropy filler is deliberately not a native decoding oracle.
fn video_fixture() -> (Vec<u8>, Vec<u8>) {
    struct Bits(Vec<bool>);
    impl Bits {
        fn n(&mut self, n: usize, v: u64) {
            for i in (0..n).rev() {
                self.0.push((v >> i) & 1 != 0);
            }
        }
        fn ue(&mut self, v: u64) {
            let n = 64 - (v + 1).leading_zeros() as usize;
            self.n(n - 1, 0);
            self.n(n, v + 1);
        }
        fn done(mut self) -> Vec<u8> {
            self.0.push(true);
            while self.0.len() % 8 != 0 {
                self.0.push(false);
            }
            self.0
                .chunks(8)
                .map(|v| v.iter().fold(0, |a, b| (a << 1) | u8::from(*b)))
                .collect()
        }
    }
    let mut s = Bits(vec![]);
    s.n(8, 66);
    s.n(8, 0);
    s.n(8, 30);
    for n in [0, 0, 0, 0, 1] {
        s.ue(n);
    }
    s.n(1, 0);
    s.ue(3);
    s.ue(1);
    s.n(1, 1);
    s.n(1, 1);
    s.n(1, 0);
    s.n(1, 0);
    let mut p = Bits(vec![]);
    p.ue(0);
    p.ue(0);
    p.n(1, 0);
    p.n(1, 0);
    p.ue(0);
    p.ue(0);
    p.ue(0);
    p.n(1, 0);
    p.n(2, 0);
    p.ue(0);
    p.ue(0);
    p.ue(0);
    p.n(1, 1);
    p.n(1, 0);
    p.n(1, 0);
    let mut configuration = vec![0, 0, 0, 1, 0x67];
    configuration.extend(s.done());
    configuration.extend([0, 0, 0, 1, 0x68]);
    configuration.extend(p.done());
    let mut idr = Bits(vec![]);
    idr.ue(0);
    idr.ue(2);
    idr.ue(0);
    idr.n(4, 0);
    idr.ue(0);
    idr.n(4, 0);
    idr.n(8, 0x55);
    let mut au = vec![0, 0, 0, 1, 0x65];
    au.extend(idr.done());
    au.extend([0, 0, 0, 1, 12]);
    au.extend([0x55; 2048]);
    (configuration, au)
}

fn original_stock(name: &str) -> Vec<Vec<u8>> {
    let path=std::path::PathBuf::from(std::env::var_os("GB_QUIC_TEST_FIXTURES").expect("run scripts/test-quic-backend.sh")).join(format!("{name}.stock"));
    let bytes = std::fs::read(&path).unwrap();
    let expected = std::fs::read_to_string(path.with_extension("stock.sha256")).unwrap();
    assert_eq!(
        boring::sha::sha256(&bytes)
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<String>(),
        expected.trim()
    );
    let mut records = vec![];
    let mut at = 0;
    while at < bytes.len() {
        let n = u32::from_be_bytes(bytes[at..at + 4].try_into().unwrap()) as usize;
        at += 4;
        records.push(bytes[at..at + n].to_vec());
        at += n;
    }
    records
}

#[test]
fn uncommitted_media_release_cannot_silently_drop_live_output() {
    use galaxybridge_quic_backend::Error;
    let (mut host, mut peer, mut audio, _control) = pair();
    audio.write_all(&[0; 65]).unwrap();
    audio.write_all(&[0, 97, 97, 99]).unwrap();
    let until = Instant::now() + Duration::from_secs(2);
    loop {
        host.poll().unwrap();
        peer.poll().unwrap();
        while let Some(event) = host.next_event() {
            if let Event::Media { handle } = event {
                assert_eq!(host.release_event(handle), Err(Error::Protocol));
                assert_eq!(host.terminal(), Some(Error::Protocol));
                peer.retire(Error::Retired);
                return;
            }
        }
        assert!(Instant::now() < until);
        std::thread::sleep(Duration::from_millis(1));
    }
}

#[test]
fn reverse_bulk_clipboard_fences_small_ack_uhid_and_keeps_original_expiry() {
    use galaxybridge_quic_backend::Error;
    for expire in [false, true] {
        let (mut host, mut peer, mut audio, mut control) = pair();
        audio.write_all(&[0; 65]).unwrap();
        audio.write_all(&[0, 97, 97, 99]).unwrap();
        let mut clipboard = vec![0];
        clipboard.extend(1000u32.to_be_bytes());
        clipboard.extend(vec![b'x'; 1000]);
        let ack = [1, 0, 0, 0, 0, 0, 0, 0, 91];
        let uhid = [2, 0, 7, 0, 2, 0x12, 0x34];
        let mut stream = clipboard.clone();
        stream.extend(ack);
        stream.extend(uhid);
        let start = Instant::now();
        let mut sent = false;
        let mut first = None;
        let mut ordinals = vec![];
        loop {
            let hr = host.poll();
            let pr = peer.poll();
            if hr.is_err() || pr.is_err() {
                assert!(expire && first.is_some());
                assert!(matches!(hr, Err(Error::Deadline)) || matches!(pr, Err(Error::Deadline)));
                assert_eq!(ordinals, [1], "no callback after the held original expires");
                assert!(start.elapsed() < Duration::from_millis(700));
                host.retire(Error::Deadline);
                assert_eq!(host.consume_device(first.unwrap()), Err(Error::Retired));
                host.release_event(first.unwrap()).unwrap();
                peer.retire(Error::Retired);
                break;
            }
            while let Some(e) = host.next_event() {
                match e {
                    Event::Media { handle } => {
                        host.commit_media(handle).unwrap();
                        host.release_event(handle).unwrap();
                    }
                    Event::Device { handle, ordinal } => {
                        ordinals.push(ordinal);
                        if ordinal == 1 {
                            assert_eq!(host.device(handle).unwrap(), clipboard);
                            assert_eq!(host.consume_device(u64::MAX), Err(Error::InvalidHandle));
                            first = Some(handle);
                        } else {
                            assert!(
                                !expire && first.is_none(),
                                "later lane cannot bypass earlier consumer admission"
                            );
                            assert_eq!(
                                host.device(handle).unwrap(),
                                if ordinal == 2 { &ack[..] } else { &uhid[..] }
                            );
                            host.consume_device(handle).unwrap();
                            assert_eq!(host.consume_device(handle), Err(Error::Protocol));
                            host.release_event(handle).unwrap();
                        }
                    }
                    _ => {}
                }
            }
            if host.ready() && !sent {
                control.write_all(&stream).unwrap();
                sent = true;
            }
            if let Some(handle) = first {
                // Both authenticated lanes continue service while the actual
                // first object remains unconsumed. No forced Applied or ACK.
                if !expire && start.elapsed() >= Duration::from_millis(100) {
                    assert_eq!(ordinals, [1]);
                    host.consume_device(handle).unwrap();
                    assert_eq!(host.consume_device(handle), Err(Error::Protocol));
                    host.release_event(handle).unwrap();
                    first = None;
                }
            }
            if ordinals == [1, 2, 3] {
                assert!(!expire);
                host.retire(Error::Retired);
                peer.retire(Error::Retired);
                break;
            }
            assert!(start.elapsed() < Duration::from_secs(1));
            std::thread::sleep(Duration::from_millis(1));
        }
    }
}

#[test]
fn matching_ack_consumption_checks_original_cutoff_without_another_poll() {
    use galaxybridge_quic_backend::Error;
    for offset in [-1i64, 0, 1] {
        let (mut host, mut peer, mut audio, mut control) = pair();
        audio.write_all(&[0; 65]).unwrap();
        audio.write_all(&[0, 97, 97, 99]).unwrap();
        let until = Instant::now() + Duration::from_secs(3);
        while !host.ready() {
            host.poll().unwrap();
            peer.poll().unwrap();
            while let Some(e) = host.next_event() {
                if let Event::Media { handle } = e {
                    host.commit_media(handle).unwrap();
                    host.release_event(handle).unwrap();
                }
            }
            assert!(Instant::now() < until);
        }
        let received = host.now_ns().unwrap();
        let mut command = vec![9];
        command.extend(91u64.to_be_bytes());
        command.extend([0, 0, 0, 0, 1, b'x']);
        host.queue_bulk(&command, received).unwrap();
        let mut applied = false;
        while !applied {
            host.poll().unwrap();
            peer.poll().unwrap();
            while let Some(e) = host.next_event() {
                applied |= matches!(e, Event::BulkComplete(_));
                if let Event::Media { handle } = e {
                    host.commit_media(handle).unwrap();
                    host.release_event(handle).unwrap();
                }
            }
            assert!(Instant::now() < until);
        }
        // Continue actual endpoint/G1 service to avoid expiring unrelated
        // feedback by jumping the whole service clock. The ACK has a fresh
        // local residence budget, but not a fresh clipboard budget.
        let cutoff = received + 2_000_000_000;
        while host.now_ns().unwrap() < cutoff - 50_000_000 {
            peer.poll().unwrap();
            host.poll().unwrap();
            while let Some(e) = host.next_event() {
                if let Event::Media { handle } = e {
                    host.commit_media(handle).unwrap();
                    host.release_event(handle).unwrap();
                }
            }
            std::thread::sleep(Duration::from_millis(1));
        }
        let mut ack = vec![1];
        ack.extend(91u64.to_be_bytes());
        control.write_all(&ack).unwrap();
        let handle = loop {
            peer.poll().unwrap();
            host.poll().unwrap();
            if let Some(Event::Device { handle, ordinal }) = host.next_event() {
                assert_eq!(ordinal, 1);
                break handle;
            }
            assert!(Instant::now() < until);
        };
        let exported = host.device_cutoffs(handle).unwrap();
        assert_eq!(
            exported.clipboard,
            Some(cutoff),
            "original watch survives the ACK's newer reverse residence cutoff"
        );
        assert!(exported.reverse > cutoff);
        assert_eq!(exported.effective(), cutoff);
        host.qa_local_time((cutoff as i64 + offset) as u64).unwrap();
        let result = host.consume_device(handle);
        if offset < 0 {
            assert_eq!(result, Ok(()));
            assert_eq!(host.terminal(), None);
        } else {
            assert_eq!(result, Err(Error::ClipboardAckMissing));
            assert_eq!(host.terminal(), Some(Error::ClipboardAckMissing));
            assert_eq!(host.consume_device(handle), Err(Error::Retired));
        }
        host.retire(Error::Retired);
        peer.retire(Error::Retired);
    }
}

#[test]
fn wrong_stock_ack_cannot_reset_original_watchdog_or_revive_paste() {
    use galaxybridge_quic_backend::Error;
    let (mut host, mut peer, mut audio, mut control) = pair();
    audio.write_all(&[0; 65]).unwrap();
    audio.write_all(&[0, 97, 97, 99]).unwrap();
    let mut queued = None;
    let mut applied = false;
    let mut wrong = false;
    let mut wrong_sent = false;
    let until = Instant::now() + Duration::from_secs(3);
    loop {
        let result = host.poll();
        if let Err(error) = result {
            assert_eq!(error, Error::ClipboardAckMissing);
            let original = queued.unwrap();
            assert!(host.now_ns().unwrap() >= original + 2_000_000_000);
            assert!(host.now_ns().unwrap() < original + 2_100_000_000);
            assert!(applied && wrong);
            assert!(host.queue_bulk(&[8, 0], host.now_ns().unwrap()).is_err());
            peer.retire(Error::Retired);
            return;
        }
        peer.poll().unwrap();
        while let Some(event) = host.next_event() {
            match event {
                Event::Media { handle } => {
                    host.commit_media(handle).unwrap();
                    host.release_event(handle).unwrap();
                }
                Event::BulkComplete(c) => {
                    assert_eq!(c.outcome, Outcome::Applied);
                    applied = true;
                }
                Event::Device { handle, .. } => {
                    assert_eq!(host.device(handle).unwrap(), [1, 0, 0, 0, 0, 0, 0, 0, 8]);
                    host.consume_device(handle).unwrap();
                    host.release_event(handle).unwrap();
                    wrong = true;
                }
                _ => {}
            }
        }
        if host.ready() && queued.is_none() {
            let now = host.now_ns().unwrap();
            let mut bytes = vec![9];
            bytes.extend(9u64.to_be_bytes());
            bytes.extend([1, 0, 0, 0, 1, b'x']);
            host.queue_bulk(&bytes, now).unwrap();
            queued = Some(now);
        }
        if applied && !wrong_sent {
            control.write_all(&[1, 0, 0, 0, 0, 0, 0, 0, 8]).unwrap();
            wrong_sent = true;
        }
        assert!(Instant::now() < until);
        std::thread::sleep(Duration::from_millis(1));
    }
}

#[test]
fn both_codecs_same_size_epoch_duplicate_config_and_retired_storage() {
    use galaxybridge_quic_backend::Error;
    for name in ["h264", "hevc"] {
        for reset in [false, true] {
            let records = original_stock(name);
            let audio_records = original_stock("aac");
            let (mut host, mut peer, video, mut audio, _control) = pair_tracks(true);
            let mut video = video.unwrap();
            video.write_all(&[0; 65]).unwrap();
            for record in &audio_records[..2] {
                audio.write_all(record).unwrap();
            }
            video.write_all(&records[0]).unwrap();
            let mut held = None;
            for (epoch, config) in [(1, 1), (if reset { 2 } else { 1 }, 2)] {
                let packet = if config == 1 { 3 } else { 7 };
                if config == 1 || reset {
                    video.write_all(&records[1]).unwrap();
                }
                video.write_all(&records[2]).unwrap();
                video.write_all(&records[packet]).unwrap();
                let until = Instant::now() + Duration::from_secs(2);
                let mut got = false;
                while !got {
                    host.poll().unwrap_or_else(|e| {
                        panic!("host codec={name} reset={reset} config={config} error={e:?}")
                    });
                    peer.poll().unwrap_or_else(|e| {
                        panic!("peer codec={name} reset={reset} config={config} error={e:?}")
                    });
                    while let Some(event) = host.next_event() {
                        if let Event::Media { handle } = event {
                            let view = host.check_media(handle).unwrap();
                            let is_video = view.record.kind == 5 && view.record.track == 1;
                            if is_video {
                                assert_eq!(
                                    (view.record.epoch, view.record.config),
                                    (epoch, config)
                                );
                                assert_eq!(view.bytes, &records[packet][12..]);
                                assert_eq!(
                                    view.record.pts,
                                    u64::from_be_bytes(records[packet][..8].try_into().unwrap())
                                        & ((1u64 << 61) - 1)
                                );
                                got = true;
                            }
                            if is_video && config == 2 {
                                held = Some((handle, view.bytes.as_ptr(), view.bytes.len()));
                            }
                            host.commit_media(handle).unwrap();
                            if !(is_video && config == 2) {
                                host.release_event(handle).unwrap();
                            }
                        }
                    }
                    assert!(Instant::now() < until);
                    std::thread::sleep(Duration::from_micros(100));
                }
            }
            let (handle, pointer, len) = held.unwrap();
            host.retire(Error::Retired);
            peer.retire(Error::Retired);
            assert!(host.check_media(handle).is_err());
            assert_eq!(
                unsafe { std::slice::from_raw_parts(pointer, len) },
                &records[7][12..],
                "retirement cannot invalidate a retained immutable allocation"
            );
            host.release_event(handle).unwrap();
            assert!(host.cleanup().unwrap().complete && peer.cleanup().unwrap().complete);
        }
    }
}
fn fixture_bytes(video: &[Vec<u8>], audio: &[Vec<u8>], last_due: u64) -> Vec<u8> {
    let mut records: Vec<(u64, u8, Vec<u8>)> = vec![];
    for (i, record) in video.iter().enumerate() {
        let due = match i {
            0..=2 => 0,
            3 => 10_000_000,
            4 => 40_000_000,
            5 => 60_000_000,
            6 => 80_000_000,
            _ => last_due,
        };
        records.push((due, 1, record.clone()));
    }
    for (i, record) in audio.iter().enumerate() {
        let due = if i < 2 {
            0
        } else {
            10_000_000 + (i as u64 - 2) * 20_000_000
        };
        records.push((due, 2, record.clone()));
    }
    records.sort_by_key(|r| r.0);
    let mut bytes = b"GBF1".to_vec();
    bytes.extend([7, 0, 0, 0]);
    bytes.extend((records.len() as u32).to_be_bytes());
    for (due, track, body) in records {
        bytes.extend(due.to_be_bytes());
        bytes.extend([track, 0, 0, 0]);
        bytes.extend((body.len() as u32).to_be_bytes());
        bytes.extend(body);
    }
    bytes
}

// Real released C ABI plus independently owned copied buffers. No pointer from
// an event is retained after synchronous copy/check/commit/event-release.
#[test]
fn public_c_payload_copies_release_original_allocation_and_overlap() {
    use galaxybridge_quic_backend::ffi as c;
    use std::sync::Arc;
    fn header<T>() -> c::Header {
        c::Header {
            abi: 1,
            size: std::mem::size_of::<T>() as u32,
            reserved: [0; 2],
        }
    }
    fn slice(s: &str) -> c::Slice {
        c::Slice {
            data: s.as_ptr(),
            length: s.len(),
        }
    }
    struct Owner(u64);
    impl Drop for Owner {
        fn drop(&mut self) {
            unsafe {
                assert_eq!(c::gb_backend_retire(self.0), 0);
                let until = Instant::now() + Duration::from_secs(2);
                loop {
                    let mut p: c::Poll = std::mem::zeroed();
                    p.h = header::<c::Poll>();
                    assert_eq!(c::gb_backend_poll(self.0, &mut p), 107);
                    if p.cleanup != 0 {
                        assert_eq!(c::gb_backend_destroy(self.0), 0);
                        break;
                    }
                    assert!(Instant::now() < until, "exact C owner cleanup");
                    std::thread::sleep(Duration::from_millis(1));
                }
            }
        }
    }
    struct Copied {
        owner: u64,
        ticket: u64,
        bytes: Option<Vec<u8>>,
    }
    impl Drop for Copied {
        fn drop(&mut self) {
            drop(self.bytes.take());
            unsafe {
                assert_eq!(c::gb_backend_copy_release(self.owner, self.ticket), 0);
                assert_eq!(c::gb_backend_copy_release(self.owner, self.ticket), 110);
            }
        }
    }
    let audio = original_stock("aac");
    assert!(audio.len() >= 10);
    let mut fixture = fixture_bytes(&[], &audio[..10], 0);
    fixture[4] = 6;
    let path = std::env::temp_dir().join(format!(
        "galaxybridge-qa-capacity-copy-{}.gbf",
        std::process::id()
    ));
    std::fs::write(&path, &fixture).unwrap();
    let hash: String = boring::sha::sha256(&fixture)
        .iter()
        .map(|n| format!("{n:02x}"))
        .collect();
    let strings = [
        "--stdio-fixture".into(),
        "--fixture".into(),
        path.display().to_string(),
        "--sha256".into(),
        hash,
        "--duration-ms".into(),
        "5000".into(),
    ];
    let args: Vec<_> = strings.iter().map(|s| slice(s)).collect();
    let mut config: c::Config = unsafe { std::mem::zeroed() };
    config.h = header::<c::Config>();
    config.generation = 41;
    config.target_token = 9;
    config.scid = 1;
    config.enabled = 6;
    config.sidecar_sha = [4; 32];
    config.peer_ip = slice("127.0.0.1");
    config.program = slice(env!("CARGO_BIN_EXE_gb-quic-backend"));
    config.args = args.as_ptr();
    config.argc = args.len() as u32;
    let mut id = 0;
    assert_eq!(unsafe { c::gb_backend_create(&config, &mut id) }, 0);
    let owner = Owner(id);
    let mut copies = Vec::new();
    let mut copied_bytes = 0;
    let mut at_four = None;
    let mut held_original = None;
    let until = Instant::now() + Duration::from_secs(2);
    'service: loop {
        unsafe {
            let mut p: c::Poll = std::mem::zeroed();
            p.h = header::<c::Poll>();
            assert_eq!(c::gb_backend_poll(id, &mut p), 0);
            loop {
                let mut e: c::Event = std::mem::zeroed();
                e.h = header::<c::Event>();
                let status = c::gb_backend_next_event(id, &mut e);
                if status == 1 {
                    break;
                }
                assert_eq!(status, 0);
                if e.kind == 2 {
                    let mut check: c::Event = std::mem::zeroed();
                    check.h = header::<c::Event>();
                    assert_eq!(c::gb_backend_media_check(id, e.handle, &mut check), 0);
                    if e.record_kind == 5 {
                        assert_eq!(e.sequence as usize, copies.len() + 1);
                        let mut ticket = 0;
                        assert_eq!(
                            c::gb_backend_payload_copy_reserve(id, e.handle, &mut ticket),
                            0
                        );
                        let bytes =
                            std::slice::from_raw_parts(e.bytes.data, e.bytes.length).to_vec();
                        assert_eq!(bytes.as_slice(), &audio[copies.len() + 2][12..]);
                        copied_bytes += bytes.len();
                        copies.push(Arc::new(Copied {
                            owner: id,
                            ticket,
                            bytes: Some(bytes),
                        }));
                        let mut usage = [0; 8];
                        assert_eq!(c::gb_backend_qa_pools(id, usage.as_mut_ptr()), 0);
                        if copies.len() == 1 {
                            held_original = Some(usage);
                        }
                        assert_eq!(c::gb_backend_media_check(id, e.handle, &mut check), 0);
                    }
                    assert_eq!(c::gb_backend_media_commit(id, e.handle), 0);
                }
                assert_eq!(c::gb_backend_event_release(id, e.handle), 0);
                if copies.len() == 4 && at_four.is_none() {
                    let mut usage = [0; 8];
                    assert_eq!(c::gb_backend_qa_pools(id, usage.as_mut_ptr()), 0);
                    at_four = Some(usage);
                    eprintln!("C copied-four pools={usage:?} copied_bytes={copied_bytes}");
                    if usage[0] != 0 {
                        break 'service;
                    }
                    let nonfinal = copies[0].clone();
                    drop(nonfinal);
                    let mut same = [0; 8];
                    assert_eq!(c::gb_backend_qa_pools(id, same.as_mut_ptr()), 0);
                    assert_eq!(
                        same, usage,
                        "nonfinal owned-buffer reference retains copy charge"
                    );
                }
                if copies.len() == 8 {
                    break 'service;
                }
            }
            assert!(Instant::now() < until, "finite C copy overlap");
            std::thread::sleep(Duration::from_millis(1));
        }
    }
    let count = copies.len();
    let before = at_four.unwrap();
    assert_eq!(
        held_original.unwrap()[0],
        1,
        "unreleased event owns actual original allocation"
    );
    std::thread::spawn(move || drop(copies)).join().unwrap();
    let mut final_usage = [0; 8];
    assert_eq!(
        unsafe { c::gb_backend_qa_pools(id, final_usage.as_mut_ptr()) },
        0
    );
    drop(owner);
    assert_eq!(
        before[0], 0,
        "payload ticket must not pin redundant original AU bytes"
    );
    assert_eq!(before[4], 4);
    assert_eq!(before[1], before[5]);
    assert_eq!(
        count, 8,
        "four more valid originals overlap four actual retained copies"
    );
    assert_eq!(
        (
            final_usage[0],
            final_usage[1],
            final_usage[4],
            final_usage[5]
        ),
        (0, 0, 0, 0)
    );
}

#[test]
fn consumer_handoff_precedes_next_queued_complete_au_ingest() {
    let audio = original_stock("aac");
    let (mut host, mut peer, mut producer, _control) = pair();
    producer.write_all(&[0; 65]).unwrap();
    for bytes in &audio[..2] {
        producer.write_all(bytes).unwrap();
    }
    let until = Instant::now() + Duration::from_secs(2);
    let mut metadata = 0;
    while metadata < 2 {
        host.poll().unwrap();
        peer.poll().unwrap();
        while let Some(event) = host.next_event() {
            if let Event::Media { handle } = event {
                host.commit_media(handle).unwrap();
                host.release_event(handle).unwrap();
                metadata += 1;
            }
        }
        assert!(Instant::now() < until);
        std::thread::yield_now();
    }
    let before = host.qa_stage_receive().unwrap();
    for bytes in &audio[2..4] {
        producer.write_all(bytes).unwrap();
    }
    while host.qa_stage_receive().unwrap() < before + 2 {
        peer.poll().unwrap();
        assert!(Instant::now() < until);
        std::thread::yield_now();
    }
    assert_eq!(
        peer.qa_media_usage()[4..6],
        [2, 0],
        "two real Source AUs, no drops"
    );
    host.qa_service_trace();
    host.poll().unwrap();
    let trace = host.qa_service_trace();
    eprintln!("actual two-AU queued service order={trace:?}");
    let first = trace.iter().position(|v| *v == [2, 5, 2, 1]).unwrap();
    let handoff = trace.iter().position(|v| *v == [3, 5, 2, 1]).unwrap();
    let later_ingest = trace[first + 1..]
        .iter()
        .position(|v| v[0] == 1 && v[1] == 0)
        .map(|n| n + first + 1);
    while let Some(event) = host.next_event() {
        if let Event::Media { handle } = event {
            host.commit_media(handle).unwrap();
            host.release_event(handle).unwrap();
        }
    }
    host.retire(galaxybridge_quic_backend::Error::Retired);
    peer.retire(galaxybridge_quic_backend::Error::Retired);
    assert!(host.cleanup().unwrap().complete && peer.cleanup().unwrap().complete);
    assert!(first < handoff);
    assert!(
        later_ingest.is_none(),
        "consumer handoff must precede another media record and end that batch: {trace:?}"
    );
    assert!(
        trace[handoff + 1..].iter().any(|v| v[0] == 4),
        "same-turn sends remain"
    );
    assert_eq!(trace.last().unwrap()[0], 5, "same-turn results remain");
}

#[test]
fn consumer_handoff_24_aus_real_ack_windows_control_bulk_and_expiry() {
    use galaxybridge_quic_backend::Error;
    use std::collections::VecDeque;
    let video = original_stock("h264");
    let audio = original_stock("aac");
    // Existing sustained-fixture interpretation: original encoded bytes/flags,
    // explicit monotonically extended source PTS under ONE configuration.
    let frames: [Vec<Vec<u8>>; 2] = std::array::from_fn(|track| {
        (0..12)
            .map(|i| {
                let source = if track == 0 {
                    &video[3 + i % 5]
                } else {
                    &audio[2 + i % 11]
                };
                let flags = u64::from_be_bytes(source[..8].try_into().unwrap()) & !((1 << 61) - 1);
                stock_frame(
                    flags | (1_000_000 + i as u64 * if track == 0 { 16_667 } else { 21_333 }),
                    &source[12..],
                )
            })
            .collect()
    });
    let (mut host, mut peer, producer_video, mut producer_audio, mut control) = pair_tracks(true);
    let mut producer_video = producer_video.unwrap();
    producer_video.write_all(&[0; 65]).unwrap();
    for bytes in &video[..3] {
        producer_video.write_all(bytes).unwrap();
    }
    for bytes in &audio[..2] {
        producer_audio.write_all(bytes).unwrap();
    }
    let until = Instant::now() + Duration::from_secs(3);
    let mut metadata = 0;
    while metadata < 5 {
        peer.poll().unwrap();
        host.poll().unwrap();
        while let Some(event) = host.next_event() {
            if let Event::Media { handle } = event {
                assert_ne!(host.check_media(handle).unwrap().record.kind, 5);
                host.commit_media(handle).unwrap();
                host.release_event(handle).unwrap();
                metadata += 1;
            }
        }
        while peer.next_event().is_some() {}
        assert!(Instant::now() < until);
        std::thread::yield_now();
    }
    let mut clipboard = vec![0];
    clipboard.extend(1000u32.to_be_bytes());
    clipboard.extend([b'x'; 1000]);
    let uhid = vec![2, 0, 7, 0, 1, 9];
    control.write_all(&clipboard).unwrap();
    control.write_all(&uhid).unwrap();
    let mut set = vec![9];
    set.extend(91u64.to_be_bytes());
    set.push(0);
    set.extend(1u32.to_be_bytes());
    set.push(b'y');
    let mut expected_stock = vec![5];
    expected_stock.extend(&set);
    expected_stock.push(6);
    let mut observed_stock = Vec::new();
    let mut acknowledged = false;
    let mut received = [0usize; 2];
    let mut copies = VecDeque::new();
    let mut peaks = [0usize; 4];
    let mut transactions = 0;
    let mut bulks = 0;
    let mut reverse = Vec::new();
    let mut same_turn_bulk = false;
    let mut same_turn_outbound = false;
    let mut source_peak = 0;
    producer_video.set_nonblocking(true).unwrap();
    producer_audio.set_nonblocking(true).unwrap();
    for window in 0..6 {
        let source_window_start = peer.now_ns().unwrap();
        let bytes: [Vec<u8>; 2] =
            std::array::from_fn(|track| frames[track][window * 2..window * 2 + 2].concat());
        let mut written = [0; 2];
        while written != [bytes[0].len(), bytes[1].len()] {
            for (track, stream) in [&mut producer_video, &mut producer_audio]
                .into_iter()
                .enumerate()
            {
                if written[track] == bytes[track].len() {
                    continue;
                }
                match stream.write(&bytes[track][written[track]..]) {
                    Ok(n) => {
                        assert!(n > 0);
                        written[track] += n;
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                    other => panic!("finite stock producer write {other:?}"),
                }
            }
            peer.poll().unwrap();
            host.qa_stage_receive().unwrap();
            source_peak = source_peak.max(peer.qa_media_usage()[2]);
            assert_eq!(peer.qa_media_usage()[5], 0);
            assert!(Instant::now() < until);
            std::thread::yield_now();
        }
        if window == 0 {
            // Stage the actual endpoint queues, including the complete incoming
            // bulk clipboard. This does not consume or fabricate a G1 record.
            while peer.qa_media_usage()[4] < 4 || host.stats(Role::Bulk).receive_queue_records < 2 {
                peer.poll().unwrap();
                host.qa_stage_receive().unwrap();
                source_peak = source_peak.max(peer.qa_media_usage()[2]);
                assert!(Instant::now() < until);
                std::thread::yield_now();
            }
            let receipt = host.now_ns().unwrap();
            host.queue_critical(critical(1, 5), receipt).unwrap();
            host.queue_bulk(&set, receipt).unwrap();
            host.queue_critical(critical(2, 6), receipt).unwrap();
            host.qa_service_trace();
        }
        loop {
            peer.poll().unwrap();
            let sent_before = [
                host.stats(Role::Media).admitted,
                host.stats(Role::Bulk).admitted,
            ];
            host.poll().unwrap();
            let trace = host.qa_service_trace();
            if let Some(handoff) = trace.iter().position(|v| v[0] == 3) {
                assert!(!trace[handoff + 1..].iter().any(|v| v[0] == 1 && v[1] == 0));
                same_turn_bulk |= trace[handoff + 1..].iter().any(|v| *v == [1, 1, 0, 0]);
                same_turn_outbound |= host.stats(Role::Media).admitted > sent_before[0]
                    && host.stats(Role::Bulk).admitted > sent_before[1];
                assert!(trace[handoff + 1..].iter().any(|v| v[0] == 4));
                assert_eq!(
                    host.next_wakeup(),
                    Duration::ZERO,
                    "queued handoff is actionable"
                );
            }
            peaks[0] = peaks[0].max(host.qa_media_usage()[0]);
            peaks[1] = peaks[1].max(host.qa_media_usage()[1]);
            while let Some(event) = host.next_event() {
                match event {
                    Event::Media { handle } => {
                        let view = host.check_media(handle).unwrap();
                        assert_eq!(view.record.kind, 5);
                        let track = (view.record.track - 1) as usize;
                        assert_eq!(
                            (
                                view.record.generation,
                                view.record.epoch,
                                view.record.config
                            ),
                            (1, 1, 1)
                        );
                        assert_eq!(view.record.sequence as usize, received[track] + 1);
                        let expected = &frames[track][received[track]];
                        assert_eq!(
                            view.record.pts,
                            u64::from_be_bytes(expected[..8].try_into().unwrap()) & ((1 << 61) - 1)
                        );
                        assert_eq!(
                            view.record.flags,
                            2 | ((u64::from_be_bytes(expected[..8].try_into().unwrap()) >> 61) & 1)
                                as u16
                        );
                        let charge = host.reserve_payload_copy(handle).unwrap();
                        let owned = host.check_media(handle).unwrap().bytes.to_vec();
                        assert_eq!(owned, expected[12..]);
                        peaks[1] = peaks[1].max(host.qa_media_usage()[1]);
                        host.commit_media(handle).unwrap();
                        host.release_event(handle).unwrap();
                        received[track] += 1;
                        copies.push_back((charge, owned));
                        peaks[2] = peaks[2].max(copies.len());
                        peaks[3] = peaks[3].max(copies.iter().map(|(_, b)| b.len()).sum());
                        // Two real owned copies persist across later arrivals;
                        // a third exists only until this bounded final release.
                        if copies.len() > 2 {
                            let (charge, bytes) = copies.pop_front().unwrap();
                            drop(bytes);
                            drop(charge);
                        }
                    }
                    Event::Transaction(c) => {
                        assert!(matches!(
                            c.outcome,
                            galaxybridge_quic_media::Outcome::PeerBoundaryConfirmed(_)
                        ));
                        transactions += 1;
                    }
                    Event::BulkComplete(c) => {
                        assert_eq!(c.outcome, Outcome::Applied);
                        bulks += 1;
                    }
                    Event::Device { handle, ordinal } => {
                        assert_eq!(ordinal as usize, reverse.len() + 1);
                        reverse.push(host.device(handle).unwrap().to_vec());
                        host.consume_device(handle).unwrap();
                        host.release_event(handle).unwrap();
                    }
                    Event::Retired(e) => panic!("unexpected retirement {e:?}"),
                    _ => {}
                }
            }
            while peer.next_event().is_some() {}
            let mut bytes = [0; 64];
            match control.read(&mut bytes) {
                Ok(n) => observed_stock.extend_from_slice(&bytes[..n]),
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                other => panic!("actual stock {other:?}"),
            }
            assert!(expected_stock.starts_with(&observed_stock));
            if observed_stock == expected_stock && !acknowledged {
                // Real test producer ACK only after full exact stock command consumption.
                control.write_all(&[1, 0, 0, 0, 0, 0, 0, 0, 91]).unwrap();
                acknowledged = true;
            }
            let source = peer.qa_media_usage();
            source_peak = source_peak.max(source[2]);
            assert_eq!(source[5], 0, "no source-cache or age drop");
            if received == [(window + 1) * 2; 2] && source[2] == 0 {
                assert!(
                    peer.now_ns().unwrap() < source_window_start + 120_000_000,
                    "cache released by actual ACKs, not source expiry"
                );
                assert_eq!(
                    source[8..10],
                    [(window + 1) * 4, 0],
                    "one real AU ACK each; no repair substitution"
                );
                break;
            }
            assert!(
                Instant::now() < until,
                "window={window} received={received:?} source={source:?}"
            );
            std::thread::yield_now();
        }
    }
    // Finish actual control/bulk confirmations without renewing any receipt.
    while transactions != 2 || bulks != 1 || reverse.len() != 3 {
        peer.poll().unwrap();
        host.poll().unwrap();
        while let Some(event) = host.next_event() {
            match event {
                Event::Transaction(c) => {
                    assert!(matches!(
                        c.outcome,
                        galaxybridge_quic_media::Outcome::PeerBoundaryConfirmed(_)
                    ));
                    transactions += 1;
                }
                Event::BulkComplete(c) => {
                    assert_eq!(c.outcome, Outcome::Applied);
                    bulks += 1;
                }
                Event::Device { handle, ordinal } => {
                    assert_eq!(ordinal as usize, reverse.len() + 1);
                    reverse.push(host.device(handle).unwrap().to_vec());
                    host.consume_device(handle).unwrap();
                    host.release_event(handle).unwrap();
                }
                _ => panic!("unexpected final event"),
            }
        }
        assert!(Instant::now() < until);
        std::thread::yield_now();
    }
    assert!(same_turn_bulk && same_turn_outbound);
    assert_eq!(observed_stock, expected_stock);
    assert_eq!(reverse, [clipboard, uhid, vec![1, 0, 0, 0, 0, 0, 0, 0, 91]]);
    assert_eq!(peer.qa_media_usage()[4..6], [24, 0]);
    assert!(source_peak <= 4);
    assert_eq!(host.qa_dropped(), 0);
    assert_eq!(peer.qa_unavailable_repairs(), 0);
    assert_eq!(peer.qa_recovery_requests(), 0);
    while let Some((charge, bytes)) = copies.pop_front() {
        drop(bytes);
        drop(charge);
    }
    assert_eq!(&host.qa_media_usage()[..2], &[0, 0]);
    eprintln!("24-AU handoff received={received:?} source_admitted=24 dropped=0 source_peak={source_peak} consumer_peaks(original,shared_bytes,copies,copy_bytes)={peaks:?} ingest_peaks={:?} actual_ack=24 repair=0 control=2 bulk=1 reverse=3 same_turn_bulk={same_turn_bulk} same_turn_outbound={same_turn_outbound}", &host.qa_media_usage()[6..8]);
    // A real successor AU is deliberately left uncommitted until its ORIGINAL
    // cutoff. Equality cannot be renewed by additional ordinary polls.
    producer_audio
        .write_all(&stock_frame(1_300_000, &audio[2][12..]))
        .unwrap();
    let held = loop {
        peer.poll().unwrap();
        host.poll().unwrap();
        if let Some(Event::Media { handle }) = host.next_event() {
            break handle;
        }
        assert!(Instant::now() < until);
        std::thread::yield_now();
    };
    let cutoff = host.check_media(held).unwrap().deadline;
    host.qa_local_time(cutoff - 1).unwrap();
    host.poll().unwrap();
    assert_eq!(host.check_media(held).unwrap().deadline, cutoff);
    host.qa_local_time(cutoff).unwrap();
    host.poll().unwrap();
    assert!(host.check_media(held).is_err());
    host.retire(Error::Retired);
    host.release_event(held).unwrap();
    peer.retire(Error::Retired);
    assert!(host.cleanup().unwrap().complete && peer.cleanup().unwrap().complete);
    assert_eq!(&host.qa_media_usage()[..2], &[0, 0]);
}

#[test]
fn no_loss_owner_burst_with_real_owned_payload_consumer() {
    use galaxybridge_quic_media::media::first_error;
    let video = original_stock("h264");
    let audio = original_stock("aac");
    let (mut host, mut peer, producer_video, mut producer_audio, _control) = pair_tracks(true);
    host.qa_observation_gate(true).unwrap();
    let mut producer_video = producer_video.unwrap();
    producer_video.write_all(&[0; 65]).unwrap();
    for bytes in &video[..3] {
        producer_video.write_all(bytes).unwrap();
    }
    for bytes in &audio[..2] {
        producer_audio.write_all(bytes).unwrap();
    }
    let until = Instant::now() + Duration::from_secs(2);
    let mut metadata = 0;
    while metadata < 5 {
        host.poll().unwrap();
        peer.poll().unwrap();
        while let Some(event) = host.next_event() {
            if let Event::Media { handle } = event {
                assert_ne!(host.check_media(handle).unwrap().record.kind, 5);
                host.commit_media(handle).unwrap();
                host.release_event(handle).unwrap();
                metadata += 1;
            }
        }
        assert!(Instant::now() < until);
        std::thread::yield_now();
    }
    // Exactly the existing eight-source-AU window, all available before the
    // first consumer handoff. No drop filter, sleep/cap/clock policy change.
    for bytes in &video[3..7] {
        producer_video.write_all(bytes).unwrap();
    }
    for bytes in &audio[2..6] {
        producer_audio.write_all(bytes).unwrap();
    }
    let mut copies = Vec::new();
    let mut sequences = [Vec::new(), Vec::new()];
    let mut failure = None;
    while sequences.iter().map(Vec::len).sum::<usize>() < 8 {
        let observation = first_error::Scope::begin(true);
        if let Err(error) = peer.poll() {
            failure = Some(("peer", error, observation.observation()));
            break;
        }
        if let Err(error) = host.poll() {
            failure = Some(("host", error, observation.observation()));
            break;
        }
        while let Some(event) = host.next_event() {
            if let Event::Media { handle } = event {
                let view = host.check_media(handle).unwrap();
                assert_eq!(view.record.kind, 5);
                let (track, sequence) = (view.record.track, view.record.sequence);
                let charge = host.reserve_payload_copy(handle).unwrap();
                let view = host.check_media(handle).unwrap();
                let owned = view.bytes.to_vec();
                let expected = if track == 1 {
                    &video[sequence as usize + 2]
                } else {
                    &audio[sequence as usize + 1]
                };
                assert_eq!(owned, &expected[12..]);
                host.commit_media(handle).unwrap();
                host.release_event(handle).unwrap();
                copies.push((charge, owned));
                sequences[(track - 1) as usize].push(sequence);
            }
        }
        assert!(Instant::now() < until, "burst count={sequences:?}");
        std::thread::yield_now();
    }
    // Actual owned allocations are destroyed before final charge release.
    for (charge, bytes) in copies {
        drop(bytes);
        drop(charge);
    }
    host.retire(galaxybridge_quic_backend::Error::Retired);
    peer.retire(galaxybridge_quic_backend::Error::Retired);
    assert!(host.cleanup().unwrap().complete && peer.cleanup().unwrap().complete);
    eprintln!("no-loss owner burst sequences={sequences:?} first_failure={failure:?}");
    assert!(
        failure.is_none(),
        "first remaining owner boundary: {failure:?}"
    );
    assert_eq!(sequences, [vec![1, 2, 3, 4], vec![1, 2, 3, 4]]);
}

#[test]
fn prepared_fixture_combines_original_video_aac_and_ordered_session_controls() {
    use galaxybridge_quic_backend::{stock::PreparedFixture, Error};
    fn command(sequence: u64, class: u8, raw: &[u8]) -> galaxybridge_quic_media::wire::Record {
        let mut r = critical(sequence, 5);
        r.body = vec![0; 36];
        r.body[0] = class;
        r.body[32..36].copy_from_slice(&(raw.len() as u32).to_be_bytes());
        r.body.extend_from_slice(raw);
        r.total = r.body.len() as u32;
        r
    }
    for name in ["h264", "hevc"] {
        for write_limit in [8192, 3] {
            let video = original_stock(name);
            let audio = original_stock("aac");
            let bytes = fixture_bytes(&video, &audio, 220_000_000);
            let fixture =
                PreparedFixture::from_bytes(bytes.clone(), boring::sha::sha256(&bytes)).unwrap();
            let (mut host, mut peer, _v, _a, _c) = pair_tracks(true);
            host.qa_observation_gate(true).unwrap();
            peer.qa_fixture(fixture).unwrap();
            peer.qa_stock_write_limit(write_limit).unwrap();
            let until = Instant::now() + Duration::from_secs(3);
            let mut started = false;
            let mut bulk_sent = false;
            let mut remaining_sent = false;
            let mut media = [0; 2];
            let mut critical_done = 0;
            let mut bulk_done = 0;
            let mut reverse = Vec::new();
            loop {
                host.poll().unwrap_or_else(|error| panic!("{name}: host {error:?}, started={started}, remaining={remaining_sent}, media={media:?}, critical={critical_done}, bulk={bulk_done}, reverse={}", reverse.len()));
                peer.poll().unwrap_or_else(|error| panic!("{name}: {error:?}, started={started}, remaining={remaining_sent}, media={media:?}, critical={critical_done}, bulk={bulk_done}, reverse={}", reverse.len()));
                while let Some(event) = host.next_event() {
                    match event {
                        Event::Media { handle } => {
                            let view = host.check_media(handle).unwrap();
                            if view.record.kind == 5 {
                                let stock = if view.record.track == 1 {
                                    &video[view.record.sequence as usize + 2]
                                } else {
                                    &audio[view.record.sequence as usize + 1]
                                };
                                assert_eq!(view.bytes, &stock[12..]);
                                assert_eq!(
                                    view.record.pts,
                                    u64::from_be_bytes(stock[..8].try_into().unwrap())
                                        & ((1 << 61) - 1)
                                );
                                media[(view.record.track - 1) as usize] += 1;
                            }
                            host.commit_media(handle).unwrap();
                            host.release_event(handle).unwrap();
                        }
                        Event::Transaction(c) => {
                            assert!(matches!(
                                c.outcome,
                                galaxybridge_quic_media::Outcome::PeerBoundaryConfirmed(_)
                            ));
                            critical_done += 1;
                        }
                        Event::BulkComplete(c) => {
                            assert_eq!(c.outcome, Outcome::Applied);
                            bulk_done += 1;
                        }
                        Event::Device { handle, ordinal } => {
                            assert_eq!(ordinal as usize, reverse.len() + 1);
                            reverse.push(host.device(handle).unwrap().to_vec());
                            host.consume_device(handle).unwrap();
                            assert_eq!(host.consume_device(handle), Err(Error::Protocol));
                            host.release_event(handle).unwrap();
                        }
                        _ => {}
                    }
                }
                while peer.next_event().is_some() {}
                if host.ready() && !started {
                    host.queue_critical(
                        command(1, 5, &[12, 0, 7, 0, 0, 0, 0, 0, 0, 1, 0]),
                        host.now_ns().unwrap(),
                    )
                    .unwrap();
                    started = true;
                }
                if critical_done == 1 && !bulk_sent {
                    let mut set = vec![9];
                    set.extend(91u64.to_be_bytes());
                    set.extend([0, 0, 0, 0, 1, b'x']);
                    host.queue_bulk(&set, host.now_ns().unwrap()).unwrap();
                    host.queue_bulk(&[8, 1], host.now_ns().unwrap()).unwrap();
                    bulk_sent = true;
                }
                if bulk_done == 2 && media[0] > 0 && media[1] > 0 && !remaining_sent {
                    for (seq, class, raw) in [
                        (2, 9, vec![1, 0, 0, 0, 2, 0xc3, 0xa9]),
                        (3, 7, vec![16, 3, b'a', b'p', b'p']),
                        (4, 6, vec![21, 0, 64, 0, 32]),
                        (5, 5, vec![13, 0, 7, 0, 1, 9]),
                        (6, 5, vec![14, 0, 7]),
                    ] {
                        host.queue_critical(command(seq, class, &raw), host.now_ns().unwrap())
                            .unwrap();
                    }
                    remaining_sent = true;
                }
                if media == [5, 11] && critical_done == 6 && bulk_done == 2 && reverse.len() == 3 {
                    break;
                }
                assert!(Instant::now() < until, "{name} media={media:?}, critical={critical_done}, bulk={bulk_done}, reverse={}", reverse.len());
                std::thread::sleep(Duration::from_micros(100));
            }
            assert_eq!(
                reverse,
                [
                    vec![2, 0, 7, 0, 1, 0],
                    vec![1, 0, 0, 0, 0, 0, 0, 0, 91],
                    vec![0, 0, 0, 0, 1, b'x']
                ]
            );
            host.retire(Error::Retired);
            peer.retire(Error::Retired);
            assert!(host.cleanup().unwrap().complete && peer.cleanup().unwrap().complete);
            assert!(!host.ready() && !peer.ready());
            eprintln!("combined {name} write_limit={write_limit}: media=5/11 critical=6 bulk=2 reverse=3 cleanup=complete");
        }
    }
}

#[test]
fn same_owner_prepared_h264_hevc_aac_clean_repair_hole_and_late_idr() {
    use galaxybridge_quic_backend::{stock::PreparedFixture, Error};
    for hevc in [false, true] {
        let video = original_stock(if hevc { "hevc" } else { "h264" });
        let audio = original_stock("aac");
        assert!(video[3].len() > 960);
        for mode in ["clean", "drop-once", "hole", "late"] {
            eprintln!(
                "prepared codec={} mode={mode}",
                if hevc { "hevc" } else { "h264" }
            );
            let bytes = fixture_bytes(
                &video,
                &audio,
                if mode == "late" {
                    400_000_000
                } else {
                    220_000_000
                },
            );
            let hash = boring::sha::sha256(&bytes);
            let fixture = PreparedFixture::from_bytes(bytes, hash)
                .expect("prevalidated original stock fixture");
            let (mut host, mut peer, _video, _audio, _control) = pair_tracks(true);
            host.qa_observation_gate(true).unwrap();
            peer.qa_fixture(fixture).unwrap();
            peer.qa_clock(|| Ok(1_000_000_000)).unwrap();
            if mode != "clean" {
                host.qa_drop_fragment(
                    1,
                    if mode == "drop-once" { 1 } else { 2 },
                    if mode == "drop-once" { 1 } else { u16::MAX },
                    mode != "drop-once",
                )
                .unwrap();
            }
            let until = Instant::now() + Duration::from_secs(3);
            let mut sequences = vec![];
            let mut audio_count = 0;
            let mut failed = None;
            while Instant::now() < until {
                if let Err(e) = host.poll() {
                    failed = Some(e);
                    break;
                }
                peer.poll().expect("prepared peer service");
                while let Some(event) = host.next_event() {
                    if let Event::Media { handle } = event {
                        let view = host.check_media(handle).unwrap();
                        if view.record.kind == 5 {
                            let track = view.record.track;
                            let stock = if track == 1 {
                                &video[view.record.sequence as usize + 2]
                            } else {
                                &audio[view.record.sequence as usize + 1]
                            };
                            assert_eq!(view.bytes, &stock[12..]);
                            assert_eq!(
                                view.record.pts,
                                u64::from_be_bytes(stock[..8].try_into().unwrap())
                                    & ((1u64 << 61) - 1)
                            );
                            if track == 1 {
                                sequences.push(view.record.sequence);
                            } else {
                                audio_count += 1;
                            }
                        }
                        host.commit_media(handle).unwrap();
                        host.release_event(handle).unwrap();
                    }
                }
                while peer.next_event().is_some() {}
                if sequences.last() == Some(&5) && audio_count == audio.len() - 2 {
                    break;
                }
                std::thread::sleep(Duration::from_micros(100));
            }
            if mode == "late" {
                assert_eq!(
                    failed, None,
                    "late independent admission recovers the same owner"
                );
                assert_eq!(sequences, [1, 5]);
            } else {
                assert_eq!(failed, None);
                eprintln!("repair unavailable={}", peer.qa_unavailable_repairs());
                assert_eq!(
                    sequences,
                    if mode == "hole" {
                        vec![1, 5]
                    } else {
                        vec![1, 2, 3, 4, 5]
                    }
                );
                assert_eq!(audio_count, audio.len() - 2);
            }
            if mode == "clean" {
                assert_eq!(host.qa_dropped(), 0);
            } else {
                assert!(host.qa_dropped() > 0);
            }
            if matches!(mode, "hole" | "late") {
                assert!(
                    peer.qa_recovery_requests() > 0,
                    "actual kind4 traverses paired endpoint and same writer"
                );
            }
            host.retire(Error::Retired);
            peer.retire(Error::Retired);
            assert!(host.cleanup().unwrap().complete && peer.cleanup().unwrap().complete);
        }
    }
}

#[test]
fn actual_same_owner_video_and_aac_preserve_stock_bytes_pts_and_fragments() {
    let (mut host, mut peer, video, mut audio, _control) = pair_tracks(true);
    let mut video = video.unwrap();
    let (configuration, au) = video_fixture();
    assert!(au.len() > 2 * 960);
    video.write_all(&[0; 65]).unwrap();
    video.write_all(b"h264").unwrap();
    video
        .write_all(&[128, 0, 0, 0, 0, 0, 0, 64, 0, 0, 0, 32])
        .unwrap();
    video
        .write_all(&stock_frame(1u64 << 62, &configuration))
        .unwrap();
    video
        .write_all(&stock_frame((1u64 << 61) | 12345, &au))
        .unwrap();
    audio.write_all(&[0, 97, 97, 99]).unwrap();
    audio
        .write_all(&stock_frame(1u64 << 62, &[0x11, 0x90]))
        .unwrap();
    audio
        .write_all(&stock_frame(12340, &[0x21, 0x10, 0x55]))
        .unwrap();
    let until = Instant::now() + Duration::from_secs(3);
    let mut got = [false; 2];
    while Instant::now() < until && !got.iter().all(|x| *x) {
        host.poll().expect("host service");
        peer.poll().expect("peer service");
        while let Some(e) = host.next_event() {
            if let Event::Media { handle } = e {
                let view = host.check_media(handle).unwrap();
                eprintln!(
                    "fixture media kind={} track={} epoch={} config={}",
                    view.record.kind, view.record.track, view.record.epoch, view.record.config
                );
                if view.record.kind == 5 {
                    let track = view.record.track;
                    assert_eq!(view.record.pts, if track == 1 { 12345 } else { 12340 });
                    assert_eq!(
                        view.bytes,
                        if track == 1 {
                            au.as_slice()
                        } else {
                            &[0x21, 0x10, 0x55]
                        }
                    );
                    got[(track - 1) as usize] = true;
                }
                host.commit_media(handle).unwrap();
                host.release_event(handle).unwrap();
            }
        }
        while peer.next_event().is_some() {}
        std::thread::sleep(Duration::from_micros(100));
    }
    assert_eq!(got, [true, true]);
    assert!(
        peer.stats(Role::Media).datagrams_udp_sent >= 4,
        "actual fragmented video and audio share one media endpoint"
    );
}

#[test]
fn actual_backend_negotiated_parity_survives_one_lost_video_fragment_without_recovery_restart() {
    let ((mut host, mut peer, video, mut audio, _control), _relays) =
        pair_tracks_delayed_features(true, galaxybridge_quic_media::FEATURE_XOR_PARITY, None);
    host.qa_drop_fragment(1, 1, 1, false).unwrap();
    let mut video = video.unwrap();
    let (configuration, au) = video_fixture();
    assert!(au.len() > 2 * galaxybridge_quic_media::wire::BODY);
    video.write_all(&[0; 65]).unwrap();
    video.write_all(b"h264").unwrap();
    video
        .write_all(&[128, 0, 0, 0, 0, 0, 0, 64, 0, 0, 0, 32])
        .unwrap();
    video
        .write_all(&stock_frame(1u64 << 62, &configuration))
        .unwrap();
    video
        .write_all(&stock_frame((1u64 << 61) | 12_345, &au))
        .unwrap();
    audio.write_all(&[0, 97, 97, 99]).unwrap();
    audio
        .write_all(&stock_frame(1u64 << 62, &[0x11, 0x90]))
        .unwrap();

    let until = Instant::now() + Duration::from_secs(3);
    let mut video_completed = false;
    while Instant::now() < until && !video_completed {
        host.poll().unwrap();
        peer.poll().unwrap();
        while let Some(event) = host.next_event() {
            if let Event::Media { handle } = event {
                let view = host.check_media(handle).unwrap();
                if view.record.kind == 5 && view.record.track == 1 {
                    assert_eq!(view.bytes, au.as_slice());
                    video_completed = true;
                }
                host.commit_media(handle).unwrap();
                host.release_event(handle).unwrap();
            }
        }
        while peer.next_event().is_some() {}
        std::thread::sleep(Duration::from_micros(100));
    }
    assert!(
        video_completed,
        "the original AU must complete without waiting for a new IDR"
    );
    assert_eq!(host.qa_dropped(), 1);
    assert_eq!(peer.qa_recovery_requests(), 0);
    host.retire(galaxybridge_quic_backend::Error::Retired);
    peer.retire(galaxybridge_quic_backend::Error::Retired);
    assert!(host.cleanup().unwrap().complete && peer.cleanup().unwrap().complete);
}

#[test]
fn actual_pair_stock_aac_and_one_character_clipboard_reverse_ack() {
    let (mut host, mut peer, mut audio, mut control) = pair();
    let mut clip = vec![9];
    clip.extend(1u64.to_be_bytes());
    clip.push(0);
    clip.extend(1u32.to_be_bytes());
    clip.push(b'x');
    assert!(
        host.queue_bulk(&clip, 0).is_err(),
        "no stock input before both authenticated roles and peer Start"
    );
    audio.write_all(&[0; 65]).unwrap();
    audio.write_all(&[0, 97, 97, 99]).unwrap();
    audio
        .write_all(&[64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0x11, 0x90])
        .unwrap();
    audio
        .write_all(&[0, 0, 0, 0, 0, 0, 0, 42, 0, 0, 0, 3, 0x21, 0x10, 0x55])
        .unwrap();
    let until = Instant::now() + Duration::from_secs(3);
    let mut queued = false;
    let mut received = vec![];
    let mut ack_sent = false;
    let mut applied = false;
    let mut stock_ack = false;
    let mut au = false;
    while Instant::now() < until {
        host.poll().unwrap();
        peer.poll().unwrap();
        while let Some(e) = host.next_event() {
            match e {
                Event::Media { handle } => {
                    let lease = host.check_media(handle).unwrap();
                    if lease.record.kind == 5 {
                        assert_eq!(lease.record.pts, 42);
                        assert_eq!(lease.bytes, [0x21, 0x10, 0x55]);
                        au = true;
                    }
                    host.commit_media(handle).unwrap();
                    host.release_event(handle).unwrap();
                }
                Event::Device { handle, ordinal } => {
                    assert_eq!(ordinal, 1);
                    assert_eq!(host.device(handle).unwrap(), [1, 0, 0, 0, 0, 0, 0, 0, 1]);
                    host.consume_device(handle).unwrap();
                    assert!(
                        host.consume_device(handle).is_err(),
                        "reverse stock event admits once, never a duplicate paste/ACK callback"
                    );
                    host.release_event(handle).unwrap();
                    stock_ack = true;
                }
                Event::BulkComplete(c) => {
                    assert_eq!(c.outcome, Outcome::Applied);
                    applied = true;
                }
                _ => {}
            }
        }
        while peer.next_event().is_some() {}
        if host.ready() && !queued {
            host.queue_bulk(&clip, host.now_ns().unwrap()).unwrap();
            queued = true;
        }
        let mut b = [0; 256];
        match control.read(&mut b) {
            Ok(n) => received.extend_from_slice(&b[..n]),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            other => panic!("stock {other:?}"),
        }
        if received.len() == clip.len() && !ack_sent {
            assert_eq!(received, clip);
            control.write_all(&[1, 0, 0, 0, 0, 0, 0, 0, 1]).unwrap();
            ack_sent = true;
        }
        if applied && stock_ack && au {
            break;
        }
        std::thread::sleep(
            host.next_wakeup()
                .min(peer.next_wakeup())
                .min(Duration::from_micros(100)),
        );
    }
    assert!(
        queued && applied && stock_ack && au,
        "actual pair did not complete all boundaries"
    );
    assert!(host.stats(Role::Media).application_ready && host.stats(Role::Bulk).application_ready);
}

#[test]
fn keepalive_three_endpoint_owner_idle_and_independent_busy_roles() {
    use galaxybridge_quic_backend::Error;
    let (mut host, mut peer, video, mut audio, mut control) = pair_tracks(true);
    let mut video = video.unwrap();
    let original_video = original_stock("h264");
    let original_audio = original_stock("aac");
    video.write_all(&[0; 65]).unwrap();
    for bytes in &original_video[..3] {
        video.write_all(bytes).unwrap();
    }
    for bytes in &original_audio[..2] {
        audio.write_all(bytes).unwrap();
    }
    let initial = Instant::now();
    let mut metadata = 0;
    while metadata < 5 || !host.ready() || !peer.ready() {
        host.poll().unwrap();
        peer.poll().unwrap();
        while let Some(event) = host.next_event() {
            if let Event::Media { handle } = event {
                assert_ne!(host.check_media(handle).unwrap().record.kind, 5);
                host.commit_media(handle).unwrap();
                host.release_event(handle).unwrap();
                metadata += 1;
            }
        }
        while peer.next_event().is_some() {}
        assert!(initial.elapsed() < Duration::from_secs(3));
        std::thread::sleep(Duration::from_millis(1));
    }
    let identities = (host.context().clone(), peer.context().clone());
    let quiet = Instant::now();
    let baseline = [
        host.stats(Role::Media).admitted,
        host.stats(Role::Bulk).admitted,
        peer.stats(Role::Media).admitted,
        peer.stats(Role::Bulk).admitted,
    ];
    while quiet.elapsed() < Duration::from_secs(11) {
        host.poll().unwrap();
        peer.poll().unwrap();
        while host.next_event().is_some() {}
        while peer.next_event().is_some() {}
        std::thread::sleep(
            host.next_wakeup()
                .min(peer.next_wakeup())
                .min(Duration::from_millis(1)),
        );
    }
    assert!(host.ready() && peer.ready());
    // Only initial metadata feedback may finish after the baseline. No test
    // input/media is sent during this genuine eleven-second quiet interval.
    println!(
        "owner quiet11s generation={} before={baseline:?} after={:?}",
        identities.0.generation,
        [
            host.stats(Role::Media).admitted,
            host.stats(Role::Bulk).admitted,
            peer.stats(Role::Media).admitted,
            peer.stats(Role::Bulk).admitted
        ]
    );
    video.write_all(&original_video[3]).unwrap();
    audio.write_all(&original_audio[2]).unwrap();
    let mut media = [false; 2];
    let mut critical_sequence = 0;
    let mut applied = 0;
    let mut acks = 0;
    let mut received = Vec::new();
    let mut expected = Vec::new();
    for phase in 0..2 {
        let start = Instant::now();
        let mut opportunities = 0;
        let idle = if phase == 0 { Role::Bulk } else { Role::Media };
        let idle_admissions = (host.stats(idle).admitted, peer.stats(idle).admitted);
        while start.elapsed() < Duration::from_secs(6) || !received.is_empty() {
            if start.elapsed() < Duration::from_secs(6)
                && start.elapsed() >= Duration::from_millis(opportunities * 500)
            {
                if phase == 0 {
                    critical_sequence += 1;
                    let r = critical(critical_sequence, 5);
                    host.queue_critical(r, host.now_ns().unwrap()).unwrap();
                    expected.push(vec![5]);
                } else {
                    // InjectText has no reverse small clipboard ACK on Media.
                    let text = vec![1, 0, 0, 0, 1, b'x'];
                    host.queue_bulk(&text, host.now_ns().unwrap()).unwrap();
                    expected.push(text);
                }
                opportunities += 1;
            }
            host.poll().unwrap();
            peer.poll().unwrap();
            while let Some(event) = host.next_event() {
                match event {
                    Event::Media { handle } => {
                        let v = host.check_media(handle).unwrap();
                        if v.record.kind == 5 {
                            let expected = if v.record.track == 1 {
                                &original_video[3]
                            } else {
                                &original_audio[2]
                            };
                            assert_eq!(v.bytes, &expected[12..]);
                            assert_eq!(
                                v.record.pts,
                                u64::from_be_bytes(expected[..8].try_into().unwrap())
                                    & ((1 << 61) - 1)
                            );
                            media[(v.record.track - 1) as usize] = true;
                        }
                        host.commit_media(handle).unwrap();
                        host.release_event(handle).unwrap();
                    }
                    Event::Device { handle, .. } => {
                        let bytes = host.device(handle).unwrap();
                        assert_eq!(bytes[0], 1);
                        host.consume_device(handle).unwrap();
                        host.release_event(handle).unwrap();
                        acks += 1;
                    }
                    Event::BulkComplete(c) => {
                        assert_eq!(c.outcome, Outcome::Applied);
                        applied += 1;
                    }
                    Event::Retired(e) => panic!("idle owner retired {e:?}"),
                    _ => {}
                }
            }
            while peer.next_event().is_some() {}
            let mut bytes = [0; 256];
            match control.read(&mut bytes) {
                Ok(n) => received.extend_from_slice(&bytes[..n]),
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                other => panic!("stock {other:?}"),
            }
            while expected.first().is_some_and(|e| received.len() >= e.len()) {
                let e = expected.remove(0);
                assert_eq!(received.drain(..e.len()).collect::<Vec<_>>(), e);
                if e[0] == 9 {
                    let mut ack = vec![1];
                    ack.extend_from_slice(&e[1..9]);
                    control.write_all(&ack).unwrap();
                }
            }
            assert!(start.elapsed() < Duration::from_secs(7));
            std::thread::sleep(
                host.next_wakeup()
                    .min(peer.next_wakeup())
                    .min(Duration::from_millis(1)),
            );
        }
        assert_eq!(opportunities, 12);
        assert!(expected.is_empty());
        assert!(host.ready() && peer.ready());
        assert_eq!(
            (host.stats(idle).admitted, peer.stats(idle).admitted),
            idle_admissions,
            "other endpoint must receive no application heartbeat"
        );
        println!(
            "owner phase{phase} six seconds: busy role{} idle role{}, same generation",
            phase,
            1 - phase
        );
    }
    assert_eq!(media, [true, true]);
    assert_eq!((applied, acks), (12, 0));
    // Clipboard is a separate post-idle cross-role progress oracle, not a
    // heartbeat disguising the Bulk-only phase above.
    let clip = vec![9, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, b'x'];
    host.queue_bulk(&clip, host.now_ns().unwrap()).unwrap();
    let start = Instant::now();
    let mut stock_ack = false;
    while applied != 13 || acks != 1 {
        host.poll().unwrap();
        peer.poll().unwrap();
        while let Some(event) = host.next_event() {
            match event {
                Event::BulkComplete(c) => {
                    assert_eq!(c.outcome, Outcome::Applied);
                    applied += 1;
                }
                Event::Device { handle, .. } => {
                    assert_eq!(host.device(handle).unwrap(), [1, 0, 0, 0, 0, 0, 0, 0, 1]);
                    host.consume_device(handle).unwrap();
                    host.release_event(handle).unwrap();
                    acks += 1;
                }
                Event::Retired(e) => panic!("post-idle clipboard {e:?}"),
                _ => {}
            }
        }
        while peer.next_event().is_some() {}
        let mut bytes = [0; 256];
        match control.read(&mut bytes) {
            Ok(n) => received.extend_from_slice(&bytes[..n]),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            other => panic!("stock {other:?}"),
        }
        if received.len() == clip.len() && !stock_ack {
            assert_eq!(received, clip);
            control.write_all(&[1, 0, 0, 0, 0, 0, 0, 0, 1]).unwrap();
            stock_ack = true;
        }
        assert!(start.elapsed() < Duration::from_secs(1));
        std::thread::sleep(Duration::from_micros(100));
    }
    assert!(stock_ack);
    assert_eq!(
        (host.context(), peer.context()),
        (&identities.0, &identities.1)
    );
    host.retire(Error::Retired);
    peer.retire(Error::Retired);
    assert!(host.cleanup().unwrap().complete && peer.cleanup().unwrap().complete);
}

fn critical(sequence: u64, raw: u8) -> galaxybridge_quic_media::wire::Record {
    critical_bytes(sequence, &[raw])
}

fn critical_bytes(sequence: u64, raw: &[u8]) -> galaxybridge_quic_media::wire::Record {
    let mut body = vec![0; 36 + raw.len()];
    body[0] = 9;
    body[32..36].copy_from_slice(&(raw.len() as u32).to_be_bytes());
    body[36..].copy_from_slice(raw);
    galaxybridge_quic_media::wire::Record {
        kind: 8,
        track: 0,
        flags: 0,
        generation: 1,
        epoch: 1,
        config: 0,
        sequence,
        pts: 0,
        total: body.len() as u32,
        index: 0,
        count: 1,
        age_us: 0,
        lifetime_us: 500000,
        body,
    }
}

#[test]
fn priority_get_clipboard_shares_input_endpoint_without_bulk_dependency() {
    let (mut host, mut peer, mut audio, mut control) = pair();
    audio.write_all(&[0; 65]).unwrap();
    audio.write_all(&[0, 97, 97, 99]).unwrap();
    let setup_deadline = Instant::now() + Duration::from_secs(3);
    while !host.ready() || !peer.ready() {
        host.poll().unwrap();
        peer.poll().unwrap();
        while let Some(event) = host.next_event() {
            if let Event::Media { handle } = event {
                host.commit_media(handle).unwrap();
                host.release_event(handle).unwrap();
            }
        }
        while peer.next_event().is_some() {}
        assert!(Instant::now() < setup_deadline);
        std::thread::sleep(Duration::from_micros(100));
    }

    // Begin a bounded trace of the actual endpoint service, then enqueue the
    // hardware failure shape: a gesture burst concurrent with GET_CLIPBOARD.
    // These tiny ordered controls must all use the priority endpoint; bulk is
    // deliberately uninvolved.
    let _ = host.qa_service_trace();
    let _ = peer.qa_service_trace();
    let received = host.now_ns().unwrap();
    for sequence in 1..=12 {
        host.queue_critical(
            critical(sequence, if sequence % 2 == 0 { 6 } else { 5 }),
            received,
        )
        .unwrap();
    }
    host.queue_critical(critical_bytes(13, &[8, 1]), received)
        .unwrap();

    let started = Instant::now();
    let mut bytes = Vec::new();
    let mut peer_trace = Vec::new();
    let mut transactions = 0;
    while transactions != 13 || bytes.len() != 14 {
        host.poll().unwrap();
        peer.poll().unwrap();
        peer_trace.extend(peer.qa_service_trace());
        while let Some(event) = host.next_event() {
            match event {
                Event::Transaction(result) => {
                    assert!(matches!(
                        result.outcome,
                        galaxybridge_quic_media::Outcome::PeerBoundaryConfirmed(_)
                    ));
                    transactions += 1;
                }
                Event::BulkComplete(_) => panic!("priority GET_CLIPBOARD used bulk"),
                Event::Retired(error) => panic!("priority lanes retired: {error:?}"),
                _ => {}
            }
        }
        while peer.next_event().is_some() {}
        let mut chunk = [0; 64];
        match control.read(&mut chunk) {
            Ok(n) => bytes.extend_from_slice(&chunk[..n]),
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {}
            other => panic!("stock read {other:?}"),
        }
        assert!(started.elapsed() < Duration::from_millis(450));
        std::thread::sleep(Duration::from_micros(100));
    }
    assert_eq!(bytes.iter().filter(|byte| **byte == 5).count(), 6);
    assert_eq!(bytes.iter().filter(|byte| **byte == 6).count(), 6);
    assert!(bytes.windows(2).any(|pair| pair == [8, 1]));
    peer_trace.extend(peer.qa_service_trace());
    assert!(peer_trace.iter().any(|row| row[0] == 1 && row[1] == 2));
    assert!(!peer_trace.iter().any(|row| row[0] == 1 && row[1] == 1));
    host.retire(galaxybridge_quic_backend::Error::Retired);
    peer.retire(galaxybridge_quic_backend::Error::Retired);
    assert!(host.cleanup().unwrap().complete && peer.cleanup().unwrap().complete);
}

#[test]
fn actual_partial_stock_writer_preserves_critical_bulk_successor_boundaries() {
    let (mut host, mut peer, mut audio, mut control) = pair();
    peer.qa_stock_write_limit(1).unwrap();
    audio.write_all(&[0; 65]).unwrap();
    audio.write_all(&[0, 97, 97, 99]).unwrap();
    let until = Instant::now() + Duration::from_secs(3);
    let mut queued = false;
    let mut received = vec![];
    let mut completions = 0;
    let mut clip = vec![9];
    clip.extend(1u64.to_be_bytes());
    clip.push(0);
    clip.extend(1u32.to_be_bytes());
    clip.push(b'x');
    let mut expected = vec![5];
    expected.extend(&clip);
    expected.push(6);
    while Instant::now() < until {
        host.poll().unwrap();
        peer.poll().unwrap();
        while let Some(event) = host.next_event() {
            match event {
                Event::Media { handle } => {
                    host.commit_media(handle).unwrap();
                    host.release_event(handle).unwrap();
                }
                Event::Transaction(_) | Event::BulkComplete(_) => completions += 1,
                _ => {}
            }
        }
        while peer.next_event().is_some() {}
        if host.ready() && !queued {
            host.queue_critical(critical(1, 5), host.now_ns().unwrap())
                .unwrap();
            host.queue_bulk(&clip, host.now_ns().unwrap()).unwrap();
            host.queue_critical(critical(2, 6), host.now_ns().unwrap())
                .unwrap();
            queued = true;
        }
        let mut bytes = [0; 32];
        match control.read(&mut bytes) {
            Ok(n) => received.extend(&bytes[..n]),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            other => panic!("stock {other:?}"),
        };
        assert!(
            expected.starts_with(&received),
            "a later header interleaved into the one-byte partial writer"
        );
        if received == expected && completions == 3 {
            break;
        }
        std::thread::sleep(Duration::from_micros(100));
    }
    assert_eq!(received, expected);
    assert_eq!(completions, 3);
}

#[test]
fn resize_key_release_precedes_bulk_and_live_uhid_input_then_actual_destroy() {
    let (mut host, mut peer, mut audio, mut control) = pair();
    peer.qa_stock_write_limit(3).unwrap();
    audio.write_all(&[0; 65]).unwrap();
    audio.write_all(&[0, 97, 97, 99]).unwrap();
    let create = vec![12, 0, 7, 0, 0, 0, 0, 0, 0, 1, 0];
    let mut key = vec![0; 14];
    key[5] = 29;
    let resize = vec![21, 0, 64, 0, 32];
    let mut release = key.clone();
    release[1] = 1;
    let mut set = vec![9];
    set.extend(91u64.to_be_bytes());
    set.extend([0, 0, 0, 0, 1, b'x']);
    let input = vec![13, 0, 7, 0, 1, 9];
    let destroy = vec![14, 0, 7];
    let expected_frames = [
        create.clone(),
        key.clone(),
        resize.clone(),
        release,
        set.clone(),
        input.clone(),
        destroy.clone(),
    ];
    let expected: Vec<u8> = expected_frames.iter().flatten().copied().collect();
    let mut received = Vec::new();
    let mut parsed = 0;
    let mut frame_index = 0;
    let mut live_id = None;
    let mut admitted = false;
    let mut completions = 0;
    let mut stock_ack = false;
    let until = Instant::now() + Duration::from_secs(3);
    while Instant::now() < until {
        host.poll().unwrap();
        peer.poll().unwrap();
        while let Some(event) = host.next_event() {
            match event {
                Event::Media { handle } => {
                    host.commit_media(handle).unwrap();
                    host.release_event(handle).unwrap();
                }
                Event::Transaction(c) => {
                    assert!(matches!(
                        c.outcome,
                        galaxybridge_quic_media::Outcome::PeerBoundaryConfirmed(_)
                    ));
                    completions += 1;
                }
                Event::BulkComplete(c) => {
                    assert_eq!(c.outcome, Outcome::Applied);
                    completions += 1;
                }
                Event::Device { handle, .. } => {
                    assert_eq!(host.device(handle).unwrap(), &[1, 0, 0, 0, 0, 0, 0, 0, 91]);
                    host.consume_device(handle).unwrap();
                    host.release_event(handle).unwrap();
                    stock_ack = true;
                }
                _ => {}
            }
        }
        while peer.next_event().is_some() {}
        if host.ready() && !admitted {
            for (sequence, class, bytes) in [
                (1, 5, create.clone()),
                (2, 4, key.clone()),
                (3, 6, resize.clone()),
            ] {
                let mut r = critical(sequence, 5);
                r.body = vec![0; 36];
                r.body[0] = class;
                r.body[32..36].copy_from_slice(&(bytes.len() as u32).to_be_bytes());
                r.body.extend(bytes);
                r.total = r.body.len() as u32;
                host.queue_critical(r, host.now_ns().unwrap()).unwrap();
            }
            host.queue_bulk(&set, host.now_ns().unwrap()).unwrap();
            for (sequence, bytes) in [(4, input.clone()), (5, destroy.clone())] {
                let mut r = critical(sequence, 5);
                r.body = vec![0; 36];
                r.body[0] = 5;
                r.body[32..36].copy_from_slice(&(bytes.len() as u32).to_be_bytes());
                r.body.extend(bytes);
                r.total = r.body.len() as u32;
                host.queue_critical(r, host.now_ns().unwrap()).unwrap();
            }
            admitted = true;
        }
        let mut bytes = [0; 128];
        match control.read(&mut bytes) {
            Ok(n) => received.extend_from_slice(&bytes[..n]),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            other => panic!("stock read {other:?}"),
        }
        assert!(
            expected.starts_with(&received),
            "release/successor frame order or partial framing changed"
        );
        while frame_index < expected_frames.len()
            && received.len() >= parsed + expected_frames[frame_index].len()
        {
            let frame = &expected_frames[frame_index];
            match frame[0] {
                12 => {
                    assert!(live_id.is_none());
                    live_id = Some([frame[1], frame[2]]);
                }
                13 => assert_eq!(
                    live_id,
                    Some([frame[1], frame[2]]),
                    "post-resize input must target the created live ID"
                ),
                14 => {
                    assert_eq!(live_id, Some([frame[1], frame[2]]));
                    live_id = None;
                }
                9 => control.write_all(&[1, 0, 0, 0, 0, 0, 0, 0, 91]).unwrap(),
                _ => {}
            }
            parsed += frame.len();
            frame_index += 1;
        }
        if frame_index == expected_frames.len() && completions == 6 && stock_ack {
            break;
        }
        std::thread::sleep(Duration::from_micros(100));
    }
    assert_eq!(received, expected);
    assert_eq!(
        completions, 6,
        "internal key release must not create a seventh completion"
    );
    assert!(stock_ack && live_id.is_none());
    host.retire(galaxybridge_quic_backend::Error::Retired);
    peer.retire(galaxybridge_quic_backend::Error::Retired);
    assert!(host.cleanup().unwrap().complete && peer.cleanup().unwrap().complete);
}
