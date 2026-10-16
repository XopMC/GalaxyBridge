use super::*;

#[test]
fn real_bbr2_future_head_does_not_commit_the_remaining_burst() {
    let (mut sender, mut receiver) =
        tests::ready_pair_with_pacing_cap(32, CongestionControl::Bbr2, Some(750_000));
    sender.preserve_committed_datagrams();
    let start = Instant::now();
    let mut next_receive = start;
    let mut sequence = 1;
    let mut received = Vec::new();
    let mut high = 0;
    let mut maximum_future = Duration::ZERO;
    while received.len() < 256 && start.elapsed() < Duration::from_secs(4) {
        while sequence <= 256 {
            if sender.send(
                Message {
                    lane: Lane::Datagram,
                    sequence,
                    payload: vec![sequence as u8; 1_000],
                },
                start + Duration::from_secs(4),
            ) != Admission::Accepted
            {
                break;
            }
            sequence += 1;
        }
        sender.poll().unwrap();
        if let Some(front) = sender.generated.front() {
            let now = Instant::now();
            if front.at > now {
                high = high.max(sender.generated.len());
                maximum_future = maximum_future.max(
                    sender
                        .generated
                        .back()
                        .unwrap()
                        .at
                        .saturating_duration_since(now),
                );
            }
        }
        // A real bounded receive/ACK cadence, without fabricated transport
        // timestamps, congestion windows, or acknowledgements.
        if Instant::now() >= next_receive {
            receiver.poll().unwrap();
            while let Some(message) = receiver.receive() {
                received.push(message.sequence);
            }
            next_receive = Instant::now() + Duration::from_millis(40);
        }
        assert!(!sender.stats().retired && !receiver.stats().retired);
        std::thread::sleep(sender.next_wakeup().min(Duration::from_millis(1)));
    }
    let stats = sender.stats();
    sender.close();
    receiver.close();
    println!("real paced burst: received={} generated_high={} future_tail_us={} generated_write_age_us={} rtt_us={}",
        received.len(), high, maximum_future.as_micros(), stats.pressure.generated_write_age.max_ns / 1000, stats.path.rtt_ns / 1000);
    assert_eq!(received, (1..=256).collect::<Vec<_>>());
    assert!(
        high > 0,
        "fixture must encounter a real future pacing deadline"
    );
    assert!(
        high <= 3,
        "paced commitments need bounded lookahead, got {high}"
    );
}

fn exercise_media_and_reliable_progress(receiver_cadence: Duration, use_wakeup: bool) -> f64 {
    // QUIC wire cap includes encryption/record overhead; allow enough wire
    // bandwidth for a 750kB/s encoded-video payload without changing quality.
    let (mut sender, mut receiver) =
        tests::ready_pair_with_pacing_cap(32, CongestionControl::Bbr2, Some(1_000_000));
    sender.preserve_committed_datagrams();
    let start = Instant::now();
    let mut next_receive = start;
    let mut sequence = 1;
    let mut received = 0;
    let mut measure = None;
    let mut high = 0;
    let mut reliable = None;
    let mut reliable_at = None;
    while received < 2048 && start.elapsed() < Duration::from_secs(6) {
        while sequence <= 2048 {
            if sender.send(
                Message {
                    lane: Lane::Datagram,
                    sequence,
                    payload: vec![sequence as u8; 1_000],
                },
                start + Duration::from_secs(6),
            ) != Admission::Accepted
            {
                break;
            }
            sequence += 1;
        }
        if received >= 512 && reliable.is_none() {
            let now = Instant::now();
            assert_eq!(
                sender.send(
                    Message {
                        lane: Lane::Reliable,
                        sequence: 10_000,
                        payload: b"control-progress".to_vec()
                    },
                    now + Duration::from_secs(1)
                ),
                Admission::Accepted
            );
            reliable = Some(now);
        }
        sender.poll().unwrap();
        high = high.max(sender.generated.len());
        if Instant::now() >= next_receive {
            receiver.poll().unwrap();
            while let Some(message) = receiver.receive() {
                if message.lane == Lane::Reliable {
                    assert_eq!(message.payload, b"control-progress");
                    reliable_at = Some(Instant::now());
                } else {
                    received += 1;
                    assert_eq!(message.sequence, received);
                    assert_eq!(message.payload, vec![received as u8; 1_000]);
                    if received == 256 {
                        measure = Some(Instant::now());
                    }
                }
            }
            next_receive = Instant::now() + receiver_cadence;
        }
        assert!(!sender.stats().retired && !receiver.stats().retired);
        std::thread::sleep(if use_wakeup {
            sender.next_wakeup().min(Duration::from_millis(1))
        } else {
            Duration::from_millis(1)
        });
    }
    let elapsed = measure.unwrap().elapsed();
    let payload_rate = (received - 256) as f64 * 1000.0 / elapsed.as_secs_f64();
    let control_delay = reliable_at.unwrap().duration_since(reliable.unwrap());
    println!("steady payload cadence_ms={} wakeup={} bytes_per_second={:.0} generated_high={} reliable_ms={} elapsed_ms={}",
        receiver_cadence.as_millis(), use_wakeup, payload_rate, high, control_delay.as_millis(), start.elapsed().as_millis());
    sender.close();
    receiver.close();
    assert_eq!(received, 2048);
    assert!(
        control_delay < Duration::from_millis(200),
        "reliable progress cannot starve behind media"
    );
    assert!(high <= 3);
    payload_rate
}

#[test]
fn bounded_horizon_sustains_six_megabit_payload_normal_ack_cadence() {
    let payload_rate = exercise_media_and_reliable_progress(Duration::ZERO, true);
    assert!(
        payload_rate >= 750_000.0,
        "6Mbps encoded payload must remain sustainable, got {payload_rate}"
    );
}

#[test]
fn bounded_horizon_preserves_delivery_and_reliable_fairness_during_receiver_stalls() {
    // This deliberately stops all receiver intake for 40 ms per turn, rather
    // than modelling ACK delay alone. Both original and bounded generation
    // fall below 6Mbps here. Assert delivery, ownership bounds and reliable
    // fairness; throughput under this adversarial stall is diagnostic only.
    exercise_media_and_reliable_progress(Duration::from_millis(40), true);
}

#[test]
fn bounded_horizon_sustains_six_megabit_payload_one_ms_owner_quantization() {
    let payload_rate = exercise_media_and_reliable_progress(Duration::ZERO, false);
    assert!(
        payload_rate >= 750_000.0,
        "6Mbps encoded payload must remain sustainable, got {payload_rate}"
    );
}
