use galaxybridge_quic::Lane;
use galaxybridge_quic_media::wire::Record;

// Real QUIC recovery uses datagrams: a small dependent AU can complete before
// the final fragment of the preceding IDR. Source admission order is not
// network completion order (S24 owner-spans trace: IDR3380, then delta3381).
fn awaiting_fragmented_datagram_idr() -> (galaxybridge_quic_media::media::Receiver, Vec<Record>) {
    use galaxybridge_quic_media::MS;
    let mut r = receiver_configured();
    r.ingest(video_au(1, true), 0).unwrap();
    drop(commit_next(&mut r, 0));
    r.ingest(video_au(3, false), 0).unwrap();
    r.tick(120 * MS).unwrap();
    assert!(r.next_output(120 * MS).unwrap().is_none());
    let mut idr = video_au(4, true);
    idr.lifetime_us = 250_000;
    idr.body.resize(1_900, 0x55);
    let fragments: Vec<_> = idr
        .body
        .chunks(960)
        .enumerate()
        .map(|(index, body)| {
            let mut fragment = idr.with_body(body.to_vec());
            fragment.total = idr.body.len() as u32;
            fragment.count = 2;
            fragment.index = index as u16;
            fragment
        })
        .collect();
    r.ingest(fragments[0].clone(), 121 * MS).unwrap();
    (r, fragments)
}

#[test]
fn datagram_idr_survives_later_complete_dependent_during_recovery() {
    use galaxybridge_quic_media::MS;
    let (mut r, fragments) = awaiting_fragmented_datagram_idr();
    r.ingest(video_au(5, false), 122 * MS).unwrap();
    assert!(r.next_output(122 * MS).unwrap().is_none());
    r.ingest(fragments[1].clone(), 123 * MS).unwrap();
    let config = commit_next(&mut r, 123 * MS);
    assert_eq!(config.record.kind, 4);
    drop(config);
    let idr = commit_next(&mut r, 123 * MS);
    assert_eq!((idr.record.kind, idr.record.sequence), (5, 4));
    drop(idr);
    let delta = commit_next(&mut r, 123 * MS);
    assert_eq!((delta.record.kind, delta.record.sequence), (5, 5));
    drop(delta);
    assert_eq!(r.media_health(1).unwrap().state, 1);
    assert_eq!(r.terminal(), None);
}

#[test]
fn datagram_idr_survives_later_dependent_expiry_during_recovery() {
    use galaxybridge_quic_media::MS;
    let (mut r, fragments) = awaiting_fragmented_datagram_idr();
    let mut delta = video_au(5, false);
    delta.total = 961;
    delta.count = 2;
    delta.body.resize(960, 0x55);
    r.ingest(delta, 122 * MS).unwrap();
    r.tick(242 * MS).unwrap();
    let declined = r.media_health(1).unwrap().declined;
    r.ingest(fragments[1].clone(), 243 * MS).unwrap();
    let config = commit_next(&mut r, 243 * MS);
    assert_eq!(config.record.kind, 4);
    drop(config);
    let idr = commit_next(&mut r, 243 * MS);
    assert_eq!((idr.record.kind, idr.record.sequence), (5, 4));
    drop(idr);
    // IDR4 is valid, but its already lost successor must immediately request
    // recovery rather than gaining another placeholder lifetime.
    assert_eq!(r.media_health(1).unwrap().state, 2);
    assert_eq!(r.media_health(1).unwrap().declined, declined);
}

#[test]
fn datagram_idr_fence_does_not_resurrect_expired_successor() {
    use galaxybridge_quic_media::MS;
    let (mut r, fragments) = awaiting_fragmented_datagram_idr();
    let mut delta = video_au(5, false);
    delta.total = 961;
    delta.count = 2;
    delta.body.resize(960, 0x55);
    let mut tail = delta.with_body(vec![0x55]);
    tail.index = 1;
    r.ingest(delta.clone(), 122 * MS).unwrap();
    r.tick(242 * MS).unwrap();
    r.ingest(tail, 243 * MS).unwrap();
    r.ingest(delta, 244 * MS).unwrap();
    r.ingest(fragments[1].clone(), 245 * MS).unwrap();
    drop(commit_next(&mut r, 245 * MS));
    let idr = commit_next(&mut r, 245 * MS);
    assert_eq!(idr.record.sequence, 4);
    drop(idr);
    assert!(
        r.next_output(245 * MS).unwrap().is_none(),
        "expired AU5 must never get a new receive deadline"
    );
    r.retire(galaxybridge_quic_media::Failure::Retired);
    assert_eq!(r.usage(), ((0, 0), (0, 0)));
}

#[test]
fn datagram_idr_fence_accepts_newer_codec_idr_without_key_hint() {
    use galaxybridge_quic_media::MS;
    let (mut r, _) = awaiting_fragmented_datagram_idr();
    let mut newer = video_au(6, true);
    newer.flags &= !1;
    newer.lifetime_us = 120_000;
    r.ingest(newer, 122 * MS).unwrap();
    drop(commit_next(&mut r, 122 * MS));
    let idr = commit_next(&mut r, 122 * MS);
    assert_eq!(idr.record.sequence, 6);
    drop(idr);
    r.retire(galaxybridge_quic_media::Failure::Retired);
    assert_eq!(r.usage(), ((0, 0), (0, 0)));
}

#[test]
fn datagram_idr_fence_protects_unhinted_qualified_handoff() {
    use galaxybridge_quic_media::MS;
    for held in [false, true] {
        let (mut r, _) = awaiting_fragmented_datagram_idr();
        let mut delta = video_au(7, false);
        delta.total = 961;
        delta.count = 2;
        delta.body.resize(960, 0x55);
        r.ingest(delta, 202 * MS).unwrap();
        let mut newer = video_au(6, true);
        newer.flags &= !1;
        newer.lifetime_us = 120_000;
        r.ingest(newer, 320 * MS).unwrap();
        drop(commit_next(&mut r, 320 * MS));
        let pending = held.then(|| r.next_output(320 * MS).unwrap().unwrap());
        r.tick(321 * MS).unwrap();
        r.tick(322 * MS).unwrap();
        let idr = pending.unwrap_or_else(|| r.next_output(322 * MS).unwrap().unwrap());
        assert_eq!(idr.record.sequence, 6);
        r.consumer_commit(&idr, 322 * MS).unwrap();
        r.release_output(&idr, 322 * MS).unwrap();
        drop(idr);
        assert_eq!(r.media_health(1).unwrap().state, 2);
        r.retire(galaxybridge_quic_media::Failure::Retired);
        assert_eq!(r.usage(), ((0, 0), (0, 0)));
    }
}

#[test]
fn datagram_idr_fence_counts_live_hole_first_expiry_once() {
    use galaxybridge_quic_media::MS;
    let (mut r, _) = awaiting_fragmented_datagram_idr();
    for (sequence, at) in [(5, 122), (9, 123), (7, 200)] {
        let mut delta = video_au(sequence, false);
        delta.total = 961;
        delta.count = 2;
        delta.body.resize(960, 0x55);
        r.ingest(delta, at * MS).unwrap();
    }
    r.ingest(video_au(6, true), 201 * MS).unwrap();
    r.tick(243 * MS).unwrap();
    drop(commit_next(&mut r, 244 * MS));
    let idr = commit_next(&mut r, 244 * MS);
    assert_eq!(idr.record.sequence, 6);
    drop(idr);
    let before = r.media_health(1).unwrap().declined;
    r.tick(320 * MS).unwrap();
    assert_eq!(r.media_health(1).unwrap().declined, before + 1);
    r.tick(321 * MS).unwrap();
    assert_eq!(r.media_health(1).unwrap().declined, before + 1);
    r.retire(galaxybridge_quic_media::Failure::Retired);
    assert_eq!(r.usage(), ((0, 0), (0, 0)));
}

#[test]
fn datagram_idr_fence_preserves_resident_idr_between_retired_successors() {
    use galaxybridge_quic_media::MS;
    let (mut r, first) = awaiting_fragmented_datagram_idr();
    let mut second = first.clone();
    for fragment in &mut second {
        fragment.sequence = 6;
        fragment.pts = 6 * 16_667;
    }
    for (sequence, at) in [(5, 122), (7, 124)] {
        let mut delta = video_au(sequence, false);
        delta.total = 961;
        delta.count = 2;
        delta.body.resize(960, 0x55);
        r.ingest(delta, at * MS).unwrap();
        if sequence == 5 {
            r.ingest(second[0].clone(), 123 * MS).unwrap();
        }
    }
    r.tick(244 * MS).unwrap();
    r.ingest(first[1].clone(), 245 * MS).unwrap();
    drop(commit_next(&mut r, 245 * MS));
    let first = commit_next(&mut r, 245 * MS);
    assert_eq!(first.record.sequence, 4);
    drop(first);
    assert_eq!(r.media_health(1).unwrap().state, 2);
    r.ingest(second[1].clone(), 246 * MS).unwrap();
    drop(commit_next(&mut r, 246 * MS));
    let second = commit_next(&mut r, 246 * MS);
    assert_eq!(second.record.sequence, 6);
    drop(second);
    assert_eq!(r.media_health(1).unwrap().state, 2);
    r.ingest(video_au(8, true), 247 * MS).unwrap();
    drop(commit_next(&mut r, 247 * MS));
    let last = commit_next(&mut r, 247 * MS);
    assert_eq!(last.record.sequence, 8);
    drop(last);
    assert_eq!(r.media_health(1).unwrap().state, 1);
    r.retire(galaxybridge_quic_media::Failure::Retired);
    assert_eq!(r.usage(), ((0, 0), (0, 0)));
}

#[test]
fn datagram_idr_fence_bounds_long_pressure_burst_without_retirement() {
    use galaxybridge_quic_media::{media::MediaOutcome, MS};
    let (mut r, fragments) = awaiting_fragmented_datagram_idr();
    for sequence in 5..12 {
        let mut delta = video_au(sequence, false);
        delta.total = 961;
        delta.count = 2;
        delta.body.resize(960, 0x55);
        r.ingest(delta, 122 * MS).unwrap();
    }
    for sequence in 12..1012 {
        assert_eq!(
            r.ingest_classified(video_au(sequence, false), 123 * MS)
                .unwrap(),
            MediaOutcome::DeclinedPressure
        );
    }
    assert_eq!(r.terminal(), None);
    r.tick(242 * MS).unwrap();
    r.ingest(fragments[1].clone(), 243 * MS).unwrap();
    drop(commit_next(&mut r, 243 * MS));
    let idr = commit_next(&mut r, 243 * MS);
    assert_eq!(idr.record.sequence, 4);
    drop(idr);
    let declined = r.media_health(1).unwrap().declined;
    for sequence in 5..1012 {
        assert_eq!(
            r.ingest_classified(video_au(sequence, false), 244 * MS)
                .unwrap(),
            MediaOutcome::SkippedDependent
        );
    }
    assert_eq!(r.media_health(1).unwrap().declined, declined);
    r.ingest(video_au(1012, true), 245 * MS).unwrap();
    drop(commit_next(&mut r, 245 * MS));
    let idr = commit_next(&mut r, 245 * MS);
    assert_eq!(idr.record.sequence, 1012);
    drop(idr);
    assert_eq!(r.media_health(1).unwrap().state, 1);
    assert_eq!(r.terminal(), None);
    r.retire(galaxybridge_quic_media::Failure::Retired);
    assert_eq!(r.usage(), ((0, 0), (0, 0)));
}

#[test]
fn datagram_idr_recovery_admits_new_key_under_dependent_pressure() {
    use galaxybridge_quic_media::{media::MediaOutcome, MS};
    for occupied in [7, 8] {
        for fragmented in [false, true] {
            for hinted in [false, true] {
                if fragmented && !hinted {
                    continue;
                }
                let (mut r, _) = awaiting_fragmented_datagram_idr();
                // All eight assembly slots are occupied. These seven incomplete deltas
                // cannot restore the decoder while IDR4 remains incomplete. A new IDR
                // must not be thrown away merely to retain that dependent backlog.
                for sequence in 5..(4 + occupied) {
                    let mut delta = video_au(sequence, false);
                    delta.total = 961;
                    delta.count = 2;
                    delta.body.resize(960, 0x55);
                    r.ingest(delta, 122 * MS).unwrap();
                }
                let mut key = video_au(12, true);
                if !hinted {
                    key.flags &= !1;
                }
                if fragmented {
                    key.body.resize(1_900, 0x55);
                }
                let mut fragments: Vec<_> = key
                    .body
                    .chunks(960)
                    .enumerate()
                    .map(|(index, body)| {
                        let mut part = key.with_body(body.to_vec());
                        part.total = key.body.len() as u32;
                        part.count = key.body.len().div_ceil(960) as u16;
                        part.index = index as u16;
                        part
                    })
                    .collect();
                // Priority must work before the NAL prefix arrives, too. The hint does
                // not become proof of decodability merely because it won admission.
                fragments.reverse();
                for part in fragments {
                    assert_eq!(
        r.ingest_classified(part, 123 * MS).unwrap(),
        MediaOutcome::Admitted,
        "new recovery IDR must displace unusable dependent backlog, not await expiry"
    );
                }
                assert!(r.usage().0 .0 <= 8);
                drop(commit_next(&mut r, 123 * MS));
                let idr = commit_next(&mut r, 123 * MS);
                assert_eq!((idr.record.kind, idr.record.sequence), (5, 12));
                drop(idr);
                assert_eq!(r.media_health(1).unwrap().state, 1);
                assert_eq!(r.terminal(), None);
                r.retire(galaxybridge_quic_media::Failure::Retired);
                assert_eq!(r.usage(), ((0, 0), (0, 0)));
            }
        }
    }
}

#[test]
fn datagram_idr_recovery_priority_preserves_existing_keys_and_late_loss() {
    use galaxybridge_quic_media::{media::MediaOutcome, MS};
    let (mut r, old) = awaiting_fragmented_datagram_idr();
    // Seven more actual incomplete IDRs: no dependent victim exists.
    for sequence in 5..12 {
        let mut key = old[0].clone();
        key.sequence = sequence;
        key.pts = sequence * 16_667;
        r.ingest(key, 122 * MS).unwrap();
    }
    assert_eq!(
        r.ingest_classified(video_au(12, true), 123 * MS).unwrap(),
        MediaOutcome::DeclinedPressure
    );
    r.ingest(old[1].clone(), 124 * MS).unwrap();
    drop(commit_next(&mut r, 124 * MS));
    let idr = commit_next(&mut r, 124 * MS);
    assert_eq!(idr.record.sequence, 4);
    drop(idr);
    assert_eq!(r.terminal(), None);
    r.retire(galaxybridge_quic_media::Failure::Retired);
    assert_eq!(r.usage(), ((0, 0), (0, 0)));
}

#[test]
fn datagram_idr_recovery_priority_preserves_staged_and_leased_unhinted_key() {
    use galaxybridge_quic_media::{media::MediaOutcome, MS};
    for leased in [false, true] {
        let (mut r, fragments) = awaiting_fragmented_datagram_idr();
        let mut original = fragments.clone();
        for fragment in &mut original {
            fragment.sequence = 6;
            fragment.pts = 6 * 16_667;
            fragment.flags &= !1;
            fragment.lifetime_us = 120_000;
            r.ingest(fragment.clone(), 122 * MS).unwrap();
        }
        drop(commit_next(&mut r, 122 * MS));
        let pending = leased.then(|| r.next_output(122 * MS).unwrap().unwrap());
        // A duplicate fragment assembly must not alias/decline the already
        // qualified unhinted IDR owned by the handoff or its consumer lease.
        r.ingest(original[0].clone(), 123 * MS).unwrap();
        for sequence in 7..12 {
            let mut delta = video_au(sequence, false);
            delta.total = 961;
            delta.count = 2;
            delta.body.resize(960, 0x55);
            r.ingest(delta, 123 * MS).unwrap();
        }
        assert_eq!(r.usage().0 .0, 8);
        assert_eq!(
            r.ingest_classified(video_au(12, true), 124 * MS).unwrap(),
            MediaOutcome::Admitted
        );
        let idr = pending.unwrap_or_else(|| r.next_output(124 * MS).unwrap().unwrap());
        assert_eq!(idr.record.sequence, 6);
        r.consumer_commit(&idr, 124 * MS).unwrap();
        r.release_output(&idr, 124 * MS).unwrap();
        drop(idr);
        assert_eq!(r.terminal(), None);
        r.retire(galaxybridge_quic_media::Failure::Retired);
        assert_eq!(r.usage(), ((0, 0), (0, 0)));
    }
}

#[test]
fn datagram_idr_recovery_priority_without_fence_keeps_pressure_outcome() {
    use galaxybridge_quic_media::media::MediaOutcome;
    let mut r = receiver_configured();
    for sequence in 1..=8 {
        let mut delta = video_au(sequence, false);
        delta.total = 961;
        delta.count = 2;
        delta.body.resize(960, 0x55);
        r.ingest(delta, 0).unwrap();
    }
    let mut malformed = video_au(9, false);
    malformed.body = vec![0xff];
    malformed.total = 1;
    assert_eq!(
        r.ingest_classified(malformed, 0).unwrap(),
        MediaOutcome::DeclinedPressure
    );
    assert_eq!(r.terminal(), None);
    r.retire(galaxybridge_quic_media::Failure::Retired);
    assert_eq!(r.usage(), ((0, 0), (0, 0)));
}

#[test]
fn datagram_idr_recovery_priority_keeps_complete_unhinted_independent() {
    use galaxybridge_quic_media::{media::MediaOutcome, MS};
    let (mut r, old) = awaiting_fragmented_datagram_idr();
    let mut unhinted = video_au(5, true);
    unhinted.flags &= !1;
    r.ingest(unhinted, 122 * MS).unwrap();
    for sequence in 6..12 {
        let mut key = old[0].clone();
        key.sequence = sequence;
        key.pts = sequence * 16_667;
        r.ingest(key, 122 * MS).unwrap();
    }
    assert_eq!(
        r.ingest_classified(video_au(12, true), 123 * MS).unwrap(),
        MediaOutcome::DeclinedPressure
    );
    drop(commit_next(&mut r, 123 * MS));
    let key = commit_next(&mut r, 123 * MS);
    assert_eq!(key.record.sequence, 5);
    drop(key);
    r.retire(galaxybridge_quic_media::Failure::Retired);
    assert_eq!(r.usage(), ((0, 0), (0, 0)));
}

#[test]
fn datagram_idr_recovery_priority_never_recreates_evicted_or_qualifies_forged_key() {
    use galaxybridge_quic_media::{media::MediaOutcome, MS};
    for forged in [false, true] {
        let (mut r, old) = awaiting_fragmented_datagram_idr();
        for sequence in 5..12 {
            let mut delta = video_au(sequence, false);
            delta.total = 961;
            delta.count = 2;
            delta.body.resize(960, 0x55);
            r.ingest(delta, 122 * MS).unwrap();
        }
        let mut new = old[0].clone();
        new.sequence = 12;
        new.pts = 12 * 16_667;
        if forged {
            new.body[4] = 0x41;
        }
        assert_eq!(
            r.ingest_classified(new, 123 * MS).unwrap(),
            MediaOutcome::Admitted
        );
        // The evicted AU5 cannot steal its slot back during reassembly.
        assert_eq!(
            r.ingest_classified(video_au(5, false), 124 * MS).unwrap(),
            MediaOutcome::SkippedDependent
        );
        let mut tail = old[1].clone();
        tail.sequence = 12;
        tail.pts = 12 * 16_667;
        r.ingest(tail, 125 * MS).unwrap();
        if forged {
            assert!(r.next_output(125 * MS).is_err());
            assert!(r.terminal().is_some());
        } else {
            drop(commit_next(&mut r, 125 * MS));
            let idr = commit_next(&mut r, 125 * MS);
            assert_eq!(idr.record.sequence, 12);
            drop(idr);
            assert_eq!(r.media_health(1).unwrap().state, 1);
            r.retire(galaxybridge_quic_media::Failure::Retired);
        }
        assert_eq!(r.usage(), ((0, 0), (0, 0)));
    }
}

#[test]
fn datagram_idr_fence_loss_memory_resets_only_with_new_publication() {
    use galaxybridge_quic_media::MS;
    for epoch in [1, 2] {
        let (mut r, old) = awaiting_fragmented_datagram_idr();
        let mut delta = video_au(5, false);
        delta.total = 961;
        delta.count = 2;
        delta.body.resize(960, 0x55);
        r.ingest(delta, 122 * MS).unwrap();
        r.tick(242 * MS).unwrap();
        fix1_replace(&mut r, 1, epoch, 5, 243 * MS);
        r.ingest(old[1].clone(), 244 * MS).unwrap();
        r.ingest(fix1_au(1, epoch, 2, 5, 5 * 16_667), 245 * MS)
            .unwrap();
        let idr = commit_next(&mut r, 245 * MS);
        assert_eq!(
            (idr.record.sequence, idr.record.epoch, idr.record.config),
            (5, epoch, 2)
        );
        drop(idr);
        assert_eq!(r.media_health(1).unwrap().state, 1);
        r.retire(galaxybridge_quic_media::Failure::Retired);
        assert_eq!(r.usage(), ((0, 0), (0, 0)));
    }
}

#[test]
fn datagram_idr_fence_expires_at_original_deadline() {
    use galaxybridge_quic_media::MS;
    let (mut r, fragments) = awaiting_fragmented_datagram_idr();
    r.ingest(video_au(5, false), 122 * MS).unwrap();
    assert!(r.next_output(122 * MS).unwrap().is_none());
    // Independent receive lifetime is still 200 ms from first receipt.
    r.tick(321 * MS).unwrap();
    r.ingest(fragments[1].clone(), 321 * MS).unwrap();
    assert!(r.next_output(321 * MS).unwrap().is_none());
    r.ingest(video_au(6, true), 322 * MS).unwrap();
    drop(commit_next(&mut r, 322 * MS));
    let idr = commit_next(&mut r, 322 * MS);
    assert_eq!(idr.record.sequence, 6);
    drop(idr);
    r.retire(galaxybridge_quic_media::Failure::Retired);
    assert_eq!(r.usage(), ((0, 0), (0, 0)));
}

#[test]
fn datagram_idr_fence_does_not_delay_newer_complete_independent() {
    use galaxybridge_quic_media::MS;
    let (mut r, _) = awaiting_fragmented_datagram_idr();
    r.ingest(video_au(6, true), 122 * MS).unwrap();
    drop(commit_next(&mut r, 122 * MS));
    let idr = commit_next(&mut r, 122 * MS);
    assert_eq!(idr.record.sequence, 6);
    drop(idr);
    r.retire(galaxybridge_quic_media::Failure::Retired);
    assert_eq!(r.usage(), ((0, 0), (0, 0)));
}

#[test]
fn datagram_idr_fence_never_qualifies_a_forged_key_flag() {
    use galaxybridge_quic_media::MS;
    let (mut r, _) = awaiting_fragmented_datagram_idr();
    let mut false_key = video_au(6, false);
    false_key.flags |= 1;
    r.ingest(false_key, 122 * MS).unwrap();
    assert!(r.next_output(122 * MS).is_err());
    assert!(r.terminal().is_some());
    assert_eq!(r.usage(), ((0, 0), (0, 0)));
}

#[test]
fn datagram_idr_fence_covers_configuration_and_consumer_handoff() {
    use galaxybridge_quic_media::MS;
    for held_au in [false, true] {
        let (mut r, fragments) = awaiting_fragmented_datagram_idr();
        let mut delta = video_au(5, false);
        delta.total = 961;
        delta.count = 2;
        delta.body.resize(960, 0x55);
        r.ingest(delta, 122 * MS).unwrap();
        r.ingest(fragments[1].clone(), 123 * MS).unwrap();
        let configuration = commit_next(&mut r, 123 * MS);
        assert_eq!(configuration.record.kind, 4);
        drop(configuration);
        let pending = held_au.then(|| r.next_output(123 * MS).unwrap().unwrap());
        r.tick(242 * MS).unwrap();
        let idr = pending.unwrap_or_else(|| r.next_output(242 * MS).unwrap().unwrap());
        assert_eq!((idr.record.kind, idr.record.sequence), (5, 4));
        r.consumer_commit(&idr, 242 * MS).unwrap();
        r.release_output(&idr, 242 * MS).unwrap();
        drop(idr);
        assert_eq!(r.media_health(1).unwrap().state, 2);
        r.retire(galaxybridge_quic_media::Failure::Retired);
        assert_eq!(r.usage(), ((0, 0), (0, 0)));
    }
}

#[test]
fn first_error_tick_classifies_transaction_and_receiver_deadlines() {
    use galaxybridge_quic_media::{media::first_error, Failure, Owner, MS};

    let mut transaction = Owner::new(context(), 0).unwrap();
    transaction.queue_start(0).unwrap();
    let dispatch = transaction.next_transport_record(0, true).unwrap();
    transaction
        .transport_admission(
            dispatch.record_token,
            galaxybridge_quic::Admission::Accepted,
            0,
        )
        .unwrap();
    let transaction_scope = first_error::Scope::begin(true);
    assert_eq!(transaction.tick(500 * MS), Err(Failure::Deadline));
    let transaction_observation = transaction_scope.observation().unwrap();
    let transaction_stage = transaction_observation.stage;
    let transaction_rejection = transaction_observation
        .rejection
        .expect("expired reliable transaction must identify its record and progress");
    assert_eq!(transaction_rejection.module, 2);
    assert_ne!(transaction_rejection.site, 0);
    assert_eq!(
        transaction_rejection.used, 0,
        "non-control record has no control class"
    );
    assert_eq!(
        transaction_rejection.limit, 0,
        "non-control record has no raw control type"
    );
    assert_eq!(transaction_rejection.requested, 0, "record sequence");
    assert_eq!(transaction_rejection.bytes, 20, "bounded body length only");
    assert_eq!(
        transaction_rejection.byte_limit, 3,
        "accepted and complete bits"
    );
    drop(transaction_scope);

    let mut receiver = Owner::new(context(), 0).unwrap();
    receiver.receiver.ingest(record(1), 0).unwrap();
    let mut codec = record(2);
    codec.track = 1;
    codec.epoch = 0;
    codec.config = 0;
    codec.sequence = 0;
    codec.body = b"h264".to_vec();
    receiver.receiver.ingest(codec, 0).unwrap();
    let receiver_scope = first_error::Scope::begin(true);
    assert_eq!(receiver.tick(500 * MS), Err(Failure::Deadline));
    let receiver_stage = receiver_scope.observation().unwrap().stage;
    drop(receiver_scope);

    let mut source = Owner::new(context(), 0).unwrap();
    assert_eq!(source.ingest_stock(1, b"h", 0).unwrap().0, 1);
    let source_scope = first_error::Scope::begin(true);
    assert_eq!(source.tick(120 * MS), Err(Failure::Deadline));
    let source_stage = source_scope.observation().unwrap().stage;

    assert_ne!(
        transaction_stage, 0,
        "transaction deadline must identify its tick branch"
    );
    assert_ne!(
        receiver_stage, 0,
        "receiver deadline must identify its tick branch"
    );
    assert_ne!(
        source_stage, 0,
        "source deadline must identify its tick branch"
    );
    assert_ne!(
        transaction_stage, receiver_stage,
        "distinct deadline owners must not collapse to one stage"
    );
    assert_ne!(
        transaction_stage, source_stage,
        "transaction and source deadlines must remain distinct"
    );
    assert_ne!(
        receiver_stage, source_stage,
        "receiver and source deadlines must remain distinct"
    );
}
#[test]
fn fragmented_source_sixteen_slots_shared_bytes_ack_and_expiry() {
    use galaxybridge_quic_media::{media::Cache, Failure, AU_LIFETIME};
    let mut cache = Cache::new();
    for sequence in 1..=16 {
        let mut r = record(5);
        r.sequence = sequence;
        r.track = if sequence % 2 == 0 { 2 } else { 1 };
        r.body = vec![1];
        cache.insert(r, 0).unwrap();
    }
    let mut next = record(5);
    next.sequence = 17;
    next.body = vec![1];
    assert_eq!(cache.insert(next.clone(), 0), Err(Failure::Capacity));
    assert_eq!(cache.usage(), (16, 16));
    let mut ack = record(7);
    ack.sequence = 1;
    ack.epoch += 1;
    cache.ack(&ack).unwrap();
    assert_eq!(cache.usage(), (16, 16));
    ack.epoch -= 1;
    cache.ack(&ack).unwrap();
    assert_eq!(cache.usage(), (15, 15));
    cache.insert(next, 0).unwrap();
    cache.expire(AU_LIFETIME - 1);
    assert_eq!(cache.usage(), (16, 16));
    cache.expire(AU_LIFETIME);
    assert_eq!(cache.usage(), (0, 0));
    for sequence in 1..=4 {
        let mut r = record(5);
        r.sequence = sequence;
        r.body = vec![1; 4 * 1024 * 1024];
        cache.insert(r, 0).unwrap();
    }
    let mut over = record(5);
    over.sequence = 5;
    over.body = vec![1];
    assert_eq!(cache.insert(over, 0), Err(Failure::Capacity));
    assert_eq!(cache.usage(), (4, 16 * 1024 * 1024));
    cache.clear();
    assert_eq!(cache.usage(), (0, 0));
}
#[test]
fn fragmented_source_mixed_residency_before_real_ack_window() {
    use galaxybridge_quic_media::{media::Cache, MS};
    let mut cache = Cache::new();
    // Concrete19 window: one199745B key + four16KiB P + three6B AAC,
    // then two new P before the matching key/P ACKs arrive. No lifetime
    // relaxation or simulated ACK is used to free capacity for admission.
    for sequence in 1..=5 {
        let mut r = record(5);
        r.sequence = sequence;
        r.body = vec![7; if sequence == 1 { 199_745 } else { 16_384 }];
        cache.insert(r, 0).unwrap();
    }
    for sequence in 1..=3 {
        let mut r = record(5);
        r.track = 2;
        r.sequence = sequence;
        r.body = vec![1; 6];
        cache.insert(r, 0).unwrap();
    }
    assert_eq!(cache.usage(), (8, 265_299));
    for sequence in 6..=7 {
        let mut r = record(5);
        r.sequence = sequence;
        r.body = vec![7; 16_384];
        assert_eq!(
            cache.insert(r, 73 * MS),
            Ok(()),
            "valid mixed residency must not source-drop a new dependent before the actual87ms ACK"
        );
    }
    assert_eq!(cache.usage(), (10, 298_067));
    let mut ack = record(7);
    ack.sequence = 1;
    cache.ack(&ack).unwrap();
    assert_eq!(
        cache.usage(),
        (9, 98_322),
        "matching ACK releases immediately, not at expiry"
    );
    cache.expire(193 * MS);
    assert_eq!(cache.usage(), (0, 0));
}
#[test]
fn fragmented_watermark_ranges_do_not_backdate_new_successors() {
    use galaxybridge_quic_media::MS;
    let mut r = receiver_configured();
    let mut au = video_au(1, true);
    au.lifetime_us = 250_000;
    r.ingest(au, 0).unwrap();
    let held = r.next_output(0).unwrap().unwrap();
    let mut watermark = record(13);
    watermark.sequence = 4;
    r.ingest(watermark.clone(), 10 * MS).unwrap();
    // Duplicate evidence neither refreshes the old range nor consumes a slot.
    r.ingest(watermark.clone(), 50 * MS).unwrap();
    watermark.sequence = 8;
    r.ingest(watermark, 100 * MS).unwrap();
    r.consumer_commit(&held, 150 * MS).unwrap();
    r.release_output(&held, 150 * MS).unwrap();
    drop(held);
    assert_eq!(r.media_health(1).unwrap().reason, 4);
    let mut recovery = video_au(5, true);
    recovery.lifetime_us = 250_000;
    r.ingest(recovery, 151 * MS).unwrap();
    drop(commit_next(&mut r, 151 * MS));
    drop(commit_next(&mut r, 151 * MS));
    r.tick(219 * MS).unwrap();
    assert_eq!(
        r.media_health(1).unwrap().state,
        1,
        "range6–8 was first known100ms, not10ms"
    );
    r.tick(220 * MS).unwrap();
    assert_eq!(
        r.media_health(1).unwrap().reason,
        4,
        "commit did not renew known range6–8"
    );
}
#[test]
fn fragmented_watermark_ranges_coalesce_the_tail_at_the_thirty_two_bound() {
    use galaxybridge_quic_media::{Failure, MS};
    let mut r = receiver_configured();
    let mut au = video_au(1, true);
    au.lifetime_us = 250_000;
    r.ingest(au, 0).unwrap();
    let held = r.next_output(0).unwrap().unwrap();
    for n in 1..=32 {
        let mut watermark = record(13);
        watermark.sequence = n + 1;
        r.ingest(watermark.clone(), n * MS).unwrap();
        r.ingest(watermark, n * MS).unwrap();
        while r.next_feedback(n * MS).is_some() {
            r.feedback_accepted();
        }
    }
    let mut overflow = record(13);
    overflow.sequence = 34;
    assert_eq!(r.ingest(overflow, 33 * MS), Ok(()));
    assert_eq!(r.terminal(), None);
    assert!(r.next_output(33 * MS).unwrap().is_none());
    assert_eq!(
        r.usage().0 .0,
        1,
        "bounded progress evidence cannot free real borrowed output"
    );
    r.retire(Failure::Retired);
    drop(held);
    assert_eq!(r.usage().0, (0, 0));
}
#[test]
fn fragmented_commit_reconciles_already_received_successor_watermark() {
    use galaxybridge_quic_media::MS;
    let mut receiver = receiver_configured();
    let mut au = video_au(1, true);
    au.lifetime_us = 250_000;
    receiver.ingest(au, 0).unwrap();
    let held = receiver.next_output(0).unwrap().unwrap();
    let mut watermark = record(13);
    watermark.sequence = 4;
    receiver.ingest(watermark, 10 * MS).unwrap();
    receiver.consumer_commit(&held, 150 * MS).unwrap();
    receiver.release_output(&held, 150 * MS).unwrap();
    drop(held);
    receiver.tick(210 * MS).unwrap();
    assert_eq!(
        receiver.media_health(1).unwrap().reason,
        4,
        "known absent successor cannot remain falsely Live after the earlier AU commits"
    );
    assert!(receiver.publish_recovery(210 * MS).unwrap().is_some());
}
#[test]
fn stall_repair_successor_recovers_lost_tail_with_original_source_deadline() {
    use galaxybridge_quic_media::{
        media::{Cache, Reassembler},
        MS,
    };
    let mut source = Cache::new();
    let mut rx = Reassembler::new();
    rx.set_repair_margin(Some(40 * MS));
    let mut au = video_au(1, false);
    au.body = (0..3840).map(|i| (i % 251) as u8).collect();
    let expected = au.body.clone();
    source.insert(au, 0).unwrap();
    // All four fragments finish their initial admission before AU 2. The
    // last two are lost; each direction has a real 20 ms flight.
    for index in 0..4 {
        let (r, deadline, repair) = source.next(0).unwrap();
        assert_eq!((r.index, deadline, repair), (index, 120 * MS, false));
        source.accepted(&r, repair).unwrap();
        if index < 2 {
            rx.ingest(r, 20 * MS).unwrap();
        }
    }
    source.insert(video_au(2, false), 16 * MS).unwrap();
    let (successor, _, repair) = source.next(16 * MS).unwrap();
    source.accepted(&successor, repair).unwrap();
    rx.ingest(successor, 36 * MS).unwrap();
    assert!(rx.next_missing(40 * MS).is_none(), "allow reordering grace");
    assert_eq!(rx.next_wakeup(), Some(41 * MS));
    let missing = rx
        .next_missing(41 * MS)
        .expect("successor proves the lost tail was admitted");
    assert_eq!((missing.sequence, missing.body.clone()), (1, vec![12]));
    source.request(&missing, 61 * MS, Some(40 * MS)).unwrap();
    for index in 2..4 {
        let (r, deadline, repair) = source.next(61 * MS).expect("repair before original expiry");
        assert_eq!((r.index, deadline, repair), (index, 120 * MS, true));
        source.accepted(&r, repair).unwrap();
        rx.ingest(r, 81 * MS).unwrap();
    }
    let completed = rx.take(1, 1, 81 * MS).unwrap();
    assert_eq!(completed.bytes.as_slice(), expected);
    assert_eq!(
        completed.deadline,
        140 * MS,
        "no receiver lifetime extension"
    );
    assert!(rx.next_missing(81 * MS).is_none());
    drop(completed);
    source.clear();
    rx.clear();
    assert_eq!(source.usage(), (0, 0));
    assert_eq!(rx.usage(), (0, 0));
}
#[test]
fn stall_repair_successor_evidence_is_scoped_validated_and_bounded() {
    use galaxybridge_quic_media::{
        media::{Cache, Reassembler},
        wire::RELIABLE_RECOVERY_FLAG,
        MS,
    };
    fn fragments(sequence: u64) -> Vec<Record> {
        let mut source = Cache::new();
        let mut au = video_au(sequence, false);
        au.body = vec![0x55; 3840];
        source.insert(au, 0).unwrap();
        let mut result = vec![];
        for _ in 0..4 {
            let (r, _, repair) = source.next(0).unwrap();
            source.accepted(&r, repair).unwrap();
            result.push(r);
        }
        result
    }
    let original = fragments(10);
    let successor = fragments(11);
    // A different track/generation/epoch/config, older AU, reliable recovery,
    // parity or rejected packet cannot prove this original tail was sent.
    for case in 0..10 {
        let mut rx = Reassembler::new();
        rx.set_repair_margin(Some(40 * MS));
        rx.ingest(original[0].clone(), 20 * MS).unwrap();
        let mut other = successor[0].clone();
        match case {
            0 => other.track = 2,
            1 => other.generation += 1,
            2 => other.epoch += 1,
            3 => other.config += 1,
            4 => other.sequence = 9,
            5 => other.flags |= 1 | RELIABLE_RECOVERY_FLAG,
            6 => {
                other.kind = galaxybridge_quic_media::wire::XOR_PARITY_KIND;
                other.index = galaxybridge_quic_media::wire::parity_checksum(&other.body);
            }
            7 => other.body.clear(),
            8 => {
                // Duplicate successor predates original admission.
                let mut earlier = Reassembler::new();
                earlier.set_repair_margin(Some(40 * MS));
                earlier.ingest(other.clone(), 16 * MS).unwrap();
                earlier.ingest(original[0].clone(), 20 * MS).unwrap();
                rx = earlier;
            }
            _ => {
                for sequence in 20..27 {
                    for mut unrelated in fragments(sequence) {
                        unrelated.track = 2;
                        rx.ingest(unrelated, 25 * MS).unwrap();
                    }
                }
            }
        }
        let result = rx.ingest(other, 36 * MS);
        if case == 7 || case == 9 {
            assert!(result.is_err());
        } else {
            result.unwrap();
        }
        assert!(
            rx.next_missing(41 * MS).is_none(),
            "invalid successor evidence case {case}"
        );
    }
    // Reordered originals arriving inside the existing grace cancel repair.
    let mut rx = Reassembler::new();
    rx.set_repair_margin(Some(40 * MS));
    rx.ingest(original[0].clone(), 20 * MS).unwrap();
    rx.ingest(successor[0].clone(), 36 * MS).unwrap();
    for r in original.iter().skip(1) {
        rx.ingest(r.clone(), 40 * MS).unwrap();
    }
    assert!(rx.next_missing(41 * MS).is_none());
    assert!(rx.take(1, 10, 41 * MS).is_some());
    // Evidence does not extend deadlines, remove margin requirements or lift
    // the two-request cap. New successors must not reset the first evidence.
    let mut rx = Reassembler::new();
    rx.set_repair_margin(Some(20 * MS));
    rx.ingest(original[0].clone(), 20 * MS).unwrap();
    for r in &successor {
        rx.ingest(r.clone(), 26 * MS).unwrap();
    }
    assert_eq!(rx.next_missing(31 * MS).unwrap().sequence, 10);
    assert!(rx.next_missing(32 * MS).is_none());
    assert_eq!(rx.next_missing(51 * MS).unwrap().sequence, 10);
    assert!(rx.next_missing(52 * MS).is_none());
    assert!(rx.next_wakeup().unwrap() > 52 * MS, "no busy wakeup");
    let mut rx = Reassembler::new();
    rx.set_repair_margin(Some(100 * MS));
    rx.ingest(original[0].clone(), 20 * MS).unwrap();
    rx.ingest(successor[0].clone(), 36 * MS).unwrap();
    assert!(
        rx.next_missing(41 * MS).is_none(),
        "insufficient original lifetime"
    );
    assert_eq!(rx.next_wakeup(), Some(140 * MS));
}
#[test]
fn stall_repair_contiguous_prefix_does_not_request_inflight_tail() {
    use galaxybridge_quic_media::{media::Reassembler, MS};
    let mut rx = Reassembler::new();
    let mut first = video_au(1, true);
    rx.set_repair_margin(Some(50 * MS));
    first.lifetime_us = 250_000;
    first.total = 3840;
    first.count = 4;
    first.body.resize(960, 0x55);
    rx.ingest(first, 0).unwrap();
    assert!(
        rx.next_missing(5 * MS).is_none(),
        "contiguous prefix is not an interior loss; its tail can still be in flight"
    );
}
#[test]
fn stall_repair_forty_ms_flights_and_quiet_lost_tail_use_real_source_bytes() {
    use galaxybridge_quic::{Admission, Received};
    use galaxybridge_quic_media::{media::Reassembler, Owner, MS};
    fn source() -> (Owner, Vec<Record>, Vec<u8>) {
        fn frame(flags: u64, body: &[u8]) -> Vec<u8> {
            let mut b = flags.to_be_bytes().to_vec();
            b.extend((body.len() as u32).to_be_bytes());
            b.extend(body);
            b
        }
        let mut o = Owner::new(context(), 0).unwrap();
        o.ingest_stock_observed_deferred(1, b"h264", 0).unwrap();
        let mut session = 0x80000000u32.to_be_bytes().to_vec();
        session.extend(64u32.to_be_bytes());
        session.extend(32u32.to_be_bytes());
        o.ingest_stock_observed_deferred(1, &session, 0).unwrap();
        o.ingest_stock_observed_deferred(1, &frame(1 << 62, &h264_config()), 0)
            .unwrap();
        let mut bytes = h264_slice(0, 0, true);
        bytes.extend([0, 0, 0, 1, 12]);
        bytes.resize(3839, 0xff);
        bytes.push(0x80);
        assert_eq!(
            o.ingest_stock_observed_deferred(1, &frame((1 << 61) | 16667, &bytes), 0)
                .unwrap()
                .1,
            galaxybridge_quic_media::stock::Admission::AccessUnit { sequence: 1 }
        );
        let mut records = vec![];
        for index in 0..4 {
            let d = o.next_transport_record(0, false).unwrap();
            let r = Record::decode(d.message.lane, &d.message.payload).unwrap();
            assert_eq!(
                (r.index, r.count, r.lifetime_us, d.deadline),
                (index, 4, 500_000, 500 * MS)
            );
            assert_eq!(r.flags & 1, 1);
            o.transport_admission(d.record_token, Admission::Accepted, 0)
                .unwrap();
            records.push(r);
        }
        (o, records, bytes)
    }
    for lost in [false, true] {
        for deliver_repair in [false, true] {
            let (mut o, records, bytes) = source();
            let mut rx = Reassembler::new();
            rx.set_repair_margin(Some(50 * MS));
            rx.ingest(records[0].clone(), 0).unwrap();
            assert_eq!(rx.next_wakeup(), Some(50 * MS));
            assert!(rx.next_missing(5 * MS).is_none());
            rx.ingest(records[1].clone(), 40 * MS).unwrap();
            assert_eq!(rx.next_wakeup(), Some(90 * MS));
            for now in [45, 50] {
                assert!(rx.next_missing(now * MS).is_none());
            }
            rx.ingest(records[2].clone(), 80 * MS).unwrap();
            assert_eq!(rx.next_wakeup(), Some(130 * MS));
            for now in [85, 90] {
                assert!(rx.next_missing(now * MS).is_none());
            }
            assert!(
                o.cache.next(90 * MS).is_none(),
                "no prefix-induced source replay"
            );
            if !lost {
                rx.ingest(records[3].clone(), 120 * MS).unwrap();
                assert!(rx.next_missing(125 * MS).is_none());
                let done = rx.take(1, 1, 125 * MS).unwrap();
                assert_eq!(done.bytes.as_slice(), bytes);
                assert_eq!(done.deadline, 450 * MS);
                drop(done);
            } else {
                rx.ingest(records[2].clone(), 129 * MS).unwrap(); // Duplicate is not unique progress.
                assert!(rx.next_missing(129 * MS).is_none());
                assert_eq!(rx.next_wakeup(), Some(130 * MS));
                let missing = rx.next_missing(130 * MS).unwrap();
                assert_eq!(missing.body, vec![8]);
                assert_eq!(
                    rx.next_wakeup(),
                    Some(180 * MS),
                    "startup budget permits one final bounded repair opportunity"
                );
                o.ingest(
                    Received {
                        lane: Lane::Reliable,
                        sequence: 1,
                        payload: missing.encode().unwrap(),
                    },
                    130 * MS,
                    Some(50 * MS),
                )
                .unwrap();
                let (r, deadline, repair) = o.cache.next(130 * MS).unwrap();
                assert_eq!((r.index, repair, deadline), (3, true, 500 * MS));
                let d = o.next_transport_record(130 * MS, false).unwrap();
                o.transport_admission(d.record_token, Admission::Accepted, 130 * MS)
                    .unwrap();
                if deliver_repair {
                    rx.ingest(r, 140 * MS).unwrap();
                    let done = rx.take(1, 1, 140 * MS).unwrap();
                    assert_eq!(done.bytes.as_slice(), bytes);
                    assert_eq!(done.deadline, 450 * MS);
                    drop(done);
                } else {
                    assert_eq!(rx.next_missing(180 * MS).unwrap().body, vec![8]);
                    assert_eq!(rx.next_wakeup(), Some(450 * MS));
                    assert_eq!(rx.expired(450 * MS).len(), 1);
                    assert!(rx.take(1, 1, 450 * MS).is_none());
                }
            }
            o.retire(galaxybridge_quic_media::Failure::Retired);
            rx.clear();
            assert_eq!(o.cache.usage(), (0, 0));
            assert_eq!(rx.usage(), (0, 0));
        }
    }
}
#[test]
fn stall_repair_interior_reserves_second_and_margin_changes_do_not_spin() {
    use galaxybridge_quic_media::{media::Reassembler, MS};
    fn fragment(index: u16) -> Record {
        let mut r = video_au(1, true);
        r.lifetime_us = 250_000;
        r.total = 3840;
        r.count = 4;
        r.index = index;
        r.body.resize(960, 0x55);
        r
    }
    let mut rx = Reassembler::new();
    rx.set_repair_margin(Some(50 * MS));
    rx.ingest(fragment(0), 0).unwrap();
    rx.ingest(fragment(2), MS).unwrap();
    assert_eq!(rx.next_wakeup(), Some(5 * MS));
    assert_eq!(rx.next_missing(5 * MS).unwrap().body, vec![2]);
    assert_eq!(rx.next_wakeup(), Some(55 * MS));
    assert!(rx.next_missing(15 * MS).is_none());
    rx.ingest(fragment(1), 40 * MS).unwrap();
    assert_eq!(rx.next_wakeup(), Some(90 * MS));
    rx.ingest(fragment(1), 89 * MS).unwrap();
    assert!(rx.next_missing(89 * MS).is_none());
    assert_eq!(rx.next_missing(90 * MS).unwrap().body, vec![8]);
    assert_eq!(rx.next_wakeup(), Some(200 * MS));
    assert!(rx.next_missing(150 * MS).is_none());
    let mut rx = Reassembler::new();
    rx.ingest(fragment(0), 0).unwrap();
    for margin in [None, Some(0), Some(u64::MAX), Some(100 * MS)] {
        rx.set_repair_margin(margin);
        assert!(rx.next_missing(5 * MS).is_none());
        assert_eq!(rx.next_wakeup(), Some(200 * MS));
    }
    rx.set_repair_margin(Some(50 * MS));
    assert_eq!(rx.next_wakeup(), Some(50 * MS));
    rx.set_repair_margin(None);
    assert_eq!(rx.next_wakeup(), Some(200 * MS));
    assert!(rx.next_missing(50 * MS).is_none());
    rx.set_repair_margin(Some(60 * MS));
    assert_eq!(rx.next_wakeup(), Some(60 * MS));
    assert_eq!(rx.next_missing(60 * MS).unwrap().body, vec![14]);
    assert_eq!(rx.next_wakeup(), Some(120 * MS));
    rx.set_repair_margin(Some(80 * MS));
    assert_eq!(rx.next_wakeup(), Some(200 * MS));
    rx.set_repair_margin(Some(50 * MS));
    assert_eq!(rx.next_wakeup(), Some(110 * MS));
    assert!(rx.next_missing(109 * MS).is_none());
    assert_eq!(rx.next_missing(110 * MS).unwrap().body, vec![14]);
    assert!(rx.next_missing(160 * MS).is_none());
    assert_eq!(rx.next_wakeup(), Some(200 * MS));
    // If service is late enough that the estimate no longer fits, the old due
    // time must not remain a permanently ready/busy wake.
    let mut rx = Reassembler::new();
    rx.set_repair_margin(Some(50 * MS));
    rx.ingest(fragment(0), 0).unwrap();
    assert!(rx.next_missing(150 * MS).is_none());
    assert_eq!(rx.next_wakeup(), Some(200 * MS));
    let mut rx = Reassembler::new();
    rx.set_repair_margin(Some(50 * MS));
    let mut short = fragment(0);
    short.age_us = 249_000;
    rx.ingest(short, u64::MAX - 2 * MS).unwrap();
    assert!(rx.next_missing(u64::MAX - 2 * MS).is_none());
    assert_eq!(rx.next_wakeup(), Some(u64::MAX - MS));
}
#[test]
fn stall_repair_owner_installs_none_before_ingest_tick_and_preserves_quiet_timer() {
    use galaxybridge_quic::Received;
    use galaxybridge_quic_media::{Owner, MS};
    let mut o = Owner::new(context(), 0).unwrap();
    o.receiver = receiver_configured();
    while let Some(ack) = o.receiver.next_feedback(0) {
        assert!(
            matches!(ack.kind, 10 | 14),
            "only setup metadata ACKs precede partial input"
        );
        o.receiver.feedback_accepted();
    }
    let mut r = video_au(1, true);
    r.total = 3840;
    r.count = 4;
    r.body.resize(960, 0x55);
    r.lifetime_us = 250_000;
    o.set_receiver_repair_margin(Some(50 * MS));
    o.ingest(
        Received {
            lane: Lane::Datagram,
            sequence: 1,
            payload: r.encode().unwrap(),
        },
        0,
        Some(50 * MS),
    )
    .unwrap();
    o.ingest(
        Received {
            lane: Lane::Datagram,
            sequence: 2,
            payload: r.encode().unwrap(),
        },
        50 * MS,
        None,
    )
    .unwrap();
    assert!(
        o.receiver.next_feedback(50 * MS).is_none(),
        "None must clear old eligibility before ingress tick"
    );
    assert_eq!(o.next_wakeup(), Some(200 * MS));
    o.set_receiver_repair_margin(Some(50 * MS));
    o.tick(50 * MS).unwrap();
    let request = o.receiver.next_feedback(50 * MS).unwrap();
    assert_eq!((request.kind, request.body), (6, vec![14]));
    o.receiver.feedback_accepted();
    assert_eq!(o.next_wakeup(), Some(100 * MS));
    o.tick(100 * MS).unwrap();
    let request = o.receiver.next_feedback(100 * MS).unwrap();
    assert_eq!(request.body, vec![14]);
    o.receiver.feedback_accepted();
    assert_eq!(o.next_wakeup(), Some(200 * MS));
    o.retire(galaxybridge_quic_media::Failure::Retired);
}
#[test]
fn repair_order_same_au_finishes_first_pass_with_owner_backpressure_and_audio() {
    use galaxybridge_quic::Admission;
    use galaxybridge_quic_media::{media::Reassembler, Owner, AU_LIFETIME, MS};
    let mut o = Owner::new(context(), 0).unwrap();
    let mut au = record(5);
    au.sequence = 1;
    au.body = (0..3840).map(|i| (i % 251) as u8).collect();
    let expected = au.body.clone();
    o.cache.insert(au.clone(), 0).unwrap();
    let mut rx = Reassembler::new();
    for index in 0..2 {
        let d = o.next_transport_record(0, false).unwrap();
        let r = Record::decode(d.message.lane, &d.message.payload).unwrap();
        assert_eq!((r.sequence, r.index, d.deadline), (1, index, AU_LIFETIME));
        o.transport_admission(d.record_token, Admission::Accepted, 0)
            .unwrap();
        if index == 1 {
            rx.ingest(r, 0).unwrap();
        } // Original0 admitted, not delivered.
    }
    let missing = rx.next_missing(5 * MS).unwrap();
    assert_eq!(missing.body, vec![1]);
    o.cache.request(&missing, 5 * MS, Some(MS)).unwrap();
    o.cache.request(&missing, 5 * MS, Some(MS)).unwrap(); // Coalesces the eligible interior request.
    let mut later_bitmap = missing.clone();
    later_bitmap.body = vec![0b0100];
    o.cache.request(&later_bitmap, 5 * MS, Some(MS)).unwrap(); // Omission cannot cancel pending0.
    let mut newer = au;
    newer.sequence = 2;
    newer.body = vec![9];
    o.cache.insert(newer, 5 * MS).unwrap();
    for index in 2..4 {
        let mut audio = record(5);
        audio.track = 2;
        audio.sequence = index as u64;
        audio.body = vec![index as u8];
        o.cache.insert(audio, 5 * MS).unwrap();
        let d = o.next_transport_record(5 * MS, false).unwrap();
        let a = Record::decode(d.message.lane, &d.message.payload).unwrap();
        assert_eq!((a.track, a.sequence), (2, index as u64));
        o.transport_admission(d.record_token, Admission::Accepted, 5 * MS)
            .unwrap();
        let (r, deadline, repair) = o.cache.next(5 * MS).unwrap();
        assert_eq!(
            (r.sequence, r.index, repair, deadline),
            (1, index, false, AU_LIFETIME),
            "same-AU original tail must precede its admitted-prefix repair"
        );
        let d = o.next_transport_record(5 * MS, false).unwrap();
        let first_payload = d.message.payload.clone();
        assert!(
            o.next_transport_record(5 * MS, false).is_none(),
            "pending dispatch has one owner"
        );
        o.transport_admission(d.record_token, Admission::Backpressured, 5 * MS)
            .unwrap();
        let d = o.next_transport_record(5 * MS, false).unwrap();
        assert_eq!(
            d.message.payload, first_payload,
            "backpressure cannot consume cursor/track/retry"
        );
        assert_eq!(d.deadline, AU_LIFETIME);
        let r = Record::decode(d.message.lane, &d.message.payload).unwrap();
        o.transport_admission(d.record_token, Admission::Accepted, 5 * MS)
            .unwrap();
        rx.ingest(r, 5 * MS).unwrap();
        assert!(
            rx.take(1, 1, 5 * MS).is_none(),
            "admission is not completion; prefix0 still absent"
        );
    }
    // The pending old repair is not displaced by continuously newer original work.
    let (repair, deadline, is_repair) = o.cache.next(6 * MS).unwrap();
    assert_eq!(
        (repair.sequence, repair.index, is_repair, deadline),
        (1, 0, true, AU_LIFETIME)
    );
    let d = o.next_transport_record(6 * MS, false).unwrap();
    o.transport_admission(d.record_token, Admission::Accepted, 6 * MS)
        .unwrap();
    rx.ingest(repair, 6 * MS).unwrap();
    let completed = rx.take(1, 1, 6 * MS).unwrap();
    assert_eq!(completed.bytes.as_slice(), expected);
    assert_eq!(completed.deadline, AU_LIFETIME);
    let (next, _, repair) = o.cache.next(6 * MS).unwrap();
    assert_eq!(
        (next.sequence, next.index, repair),
        (2, 0, false),
        "duplicate pending request coalesced"
    );
    // Re-armed feedback allows only the existing two accepted retries per index.
    let mut prefix = missing;
    prefix.body = vec![1];
    o.cache.request(&prefix, 7 * MS, Some(MS)).unwrap();
    o.cache.request(&prefix, 7 * MS, Some(MS)).unwrap();
    let (retry, _, repair) = o.cache.next(7 * MS).unwrap();
    assert_eq!((retry.sequence, retry.index, repair), (1, 0, true));
    o.cache.accepted(&retry, true).unwrap();
    o.cache.request(&prefix, 8 * MS, Some(MS)).unwrap();
    let (next, _, repair) = o.cache.next(8 * MS).unwrap();
    assert_eq!((next.sequence, next.index, repair), (2, 0, false));
    drop(completed);
    o.retire(galaxybridge_quic_media::Failure::Retired);
    assert_eq!(o.cache.usage(), (0, 0));
    assert_eq!(rx.usage(), (0, 0));
}
#[test]
fn repair_order_two_remaining_opportunities_do_not_renew_cutoff() {
    use galaxybridge_quic_media::{
        media::{Cache, Reassembler},
        AU_LIFETIME, MS,
    };
    let mut c = Cache::new();
    let mut au = record(5);
    au.body = vec![7; 3840];
    c.insert(au, 0).unwrap();
    let mut rx = Reassembler::new();
    for index in 0..2 {
        let (r, _, repair) = c.next(0).unwrap();
        assert!(!repair);
        c.accepted(&r, false).unwrap();
        if index == 1 {
            rx.ingest(r, 0).unwrap();
        }
    }
    let missing = rx.next_missing(5 * MS).unwrap();
    c.request(&missing, 5 * MS, Some(MS)).unwrap();
    // Exactly two successful VIDEO opportunities remain before the original cutoff.
    for (index, now) in [(2, AU_LIFETIME - 2 * MS), (3, AU_LIFETIME - MS)] {
        let (r, deadline, repair) = c.next(now).unwrap();
        assert_eq!((r.index, repair, deadline), (index, false, AU_LIFETIME));
        c.accepted(&r, false).unwrap();
        rx.ingest(r, now).unwrap();
        assert!(rx.take(1, 1, now).is_none());
    }
    c.request(&missing, AU_LIFETIME - MS, Some(MS)).unwrap();
    assert_eq!(c.unavailable, 1);
    assert!(
        c.next(AU_LIFETIME).is_none(),
        "pending repair must expire, never receive a fresh budget"
    );
    assert_eq!(c.usage(), (0, 0));
    assert!(rx.take(1, 1, AU_LIFETIME).is_none());
    rx.clear();
    assert_eq!(rx.usage(), (0, 0));
}
#[test]
fn fragment_dispatch_does_not_repair_originals_not_yet_admitted() {
    let mut cache = galaxybridge_quic_media::media::Cache::new();
    let mut au = record(5);
    au.body = vec![7; 64_193];
    cache.insert(au, 0).unwrap();
    let mut first = None;
    for _ in 0..10 {
        let (r, _, repair) = cache.next(0).unwrap();
        assert!(!repair);
        if first.is_none() {
            first = Some(r.clone());
        }
        cache.accepted(&r, false).unwrap();
    }
    let mut missing = first.unwrap();
    missing.kind = 6;
    missing.flags = 0;
    missing.pts = 0;
    missing.index = 0;
    missing.age_us = 0;
    missing.lifetime_us = 0;
    missing.body = vec![0xff; 9];
    missing.body[0] = 0;
    missing.body[1] = 0xfc;
    missing.body[8] = 7;
    cache.request(&missing, 1, Some(0)).unwrap();
    let (r, deadline, repair) = cache.next(2).unwrap();
    assert_eq!(
        (r.index, repair, deadline),
        (10, false, galaxybridge_quic_media::AU_LIFETIME)
    );
}
#[test]
fn fragment_dispatch_audio_has_bounded_turn_between_video_fragments() {
    let mut cache = galaxybridge_quic_media::media::Cache::new();
    let mut video = record(5);
    video.body = vec![7; 64_193];
    cache.insert(video, 0).unwrap();
    let (first, _, _) = cache.next(0).unwrap();
    cache.accepted(&first, false).unwrap();
    let mut audio = record(5);
    audio.track = 2;
    audio.body = vec![1];
    cache.insert(audio, 0).unwrap();
    let (next, _, repair) = cache.next(1).unwrap();
    assert_eq!(
        (next.track, next.index, repair),
        (2, 0, false),
        "audio cannot wait behind whole video AU/repairs"
    );
    cache.accepted(&next, false).unwrap();
    let (next, _, repair) = cache.next(2).unwrap();
    assert_eq!((next.track, next.index, repair), (1, 1, false));
}
#[test]
fn ordinary_video_residence_uses_source_bound_and_distinct_audio_cutoff() {
    use galaxybridge_quic_media::{media::Reassembler, Failure, MS};
    for (track, cap) in [(1, 120), (2, 60)] {
        let mut r = Reassembler::new();
        let mut au = video_au(1, false);
        au.track = track;
        au.total = 1900;
        au.count = 2;
        au.body.resize(960, 0x55);
        r.ingest(au.clone(), 0).unwrap();
        assert_eq!(r.deadline(track, 1), Some(cap * MS));
        r.ingest(au.clone(), 50 * MS).unwrap();
        assert_eq!(
            r.deadline(track, 1),
            Some(cap * MS),
            "duplicate cannot renew original residence"
        );
        assert_eq!(r.ingest(au, cap * MS), Err(Failure::Deadline));
    }
    let mut r = Reassembler::new();
    let mut au = video_au(1, false);
    au.total = 1900;
    au.count = 2;
    au.body.resize(960, 0x55);
    au.age_us = 70_000;
    r.ingest(au.clone(), 10 * MS).unwrap();
    assert_eq!(
        r.deadline(1, 1),
        Some(60 * MS),
        "source120 minus70ms age bounds video too"
    );
    au.age_us = 110_000;
    r.ingest(au, 20 * MS).unwrap();
    assert_eq!(
        r.deadline(1, 1),
        Some(30 * MS),
        "new inherited age can only shorten"
    );
    let mut r = Reassembler::new();
    let mut au = video_au(1, false);
    au.total = 1900;
    au.count = 2;
    au.body.resize(960, 0x55);
    r.expect_gap(au.with_body(vec![]), 0).unwrap();
    assert_eq!(
        r.deadline(1, 1),
        Some(120 * MS),
        "known video gap uses original120ms observation cutoff"
    );
    r.ingest(au.clone(), 10 * MS).unwrap();
    assert_eq!(
        r.deadline(1, 1),
        Some(120 * MS),
        "live first header classifies original first, not arrival"
    );
    r.ingest(au, 100 * MS).unwrap();
    assert_eq!(r.deadline(1, 1), Some(120 * MS));
    let mut r = Reassembler::new();
    let mut audio = video_au(1, false);
    audio.track = 2;
    audio.total = 1900;
    audio.count = 2;
    audio.body.resize(960, 0x55);
    r.expect_gap(audio.with_body(vec![]), 0).unwrap();
    assert_eq!(r.deadline(2, 1), Some(60 * MS));
    assert_eq!(r.ingest(audio, 60 * MS), Err(Failure::Deadline));
    assert_eq!(r.deadline(2, 1), Some(60 * MS));
    assert_eq!(r.usage(), (0, 0));
}
#[test]
fn independent_placeholder_first_header_at_cutoff_cannot_revive() {
    use galaxybridge_quic_media::{media::Reassembler, Failure, MS};
    let mut r = Reassembler::new();
    let mut au = video_au(1, true);
    au.lifetime_us = 250_000;
    au.total = 1900;
    au.count = 2;
    au.body.resize(960, 0x55);
    r.expect_gap(au.with_body(vec![]), 0).unwrap();
    assert_eq!(r.ingest(au, 120 * MS), Err(Failure::Deadline));
    assert_eq!(r.deadline(1, 1), Some(120 * MS));
    assert_eq!(
        r.usage(),
        (0, 0),
        "rejected header must not allocate AU storage"
    );
}
#[test]
fn independent_placeholder_late_first_header_cannot_revive() {
    use galaxybridge_quic_media::{media::Reassembler, Failure, MS};
    let mut r = Reassembler::new();
    let mut au = video_au(1, true);
    au.lifetime_us = 250_000;
    au.total = 1900;
    au.count = 2;
    au.body.resize(960, 0x55);
    r.expect_gap(au.with_body(vec![]), 0).unwrap();
    assert_eq!(r.ingest(au, 130 * MS), Err(Failure::Deadline));
    assert_eq!(r.deadline(1, 1), Some(120 * MS));
    assert_eq!(r.usage(), (0, 0));
}
#[test]
fn independent_placeholder_wrong_identity_cannot_reclassify() {
    use galaxybridge_quic_media::{media::Reassembler, Failure, MS};
    for field in 0..3 {
        let mut r = Reassembler::new();
        let mut au = video_au(1, true);
        au.lifetime_us = 250_000;
        au.total = 1900;
        au.count = 2;
        au.body.resize(960, 0x55);
        r.expect_gap(au.with_body(vec![]), 0).unwrap();
        match field {
            0 => au.generation += 1,
            1 => au.epoch += 1,
            _ => au.config += 1,
        }
        assert_eq!(r.ingest(au, 10 * MS), Err(Failure::Protocol));
        assert_eq!(
            r.deadline(1, 1),
            Some(120 * MS),
            "rejected identity field {field} cannot change cutoff"
        );
        assert_eq!(r.usage(), (0, 0));
    }
}
#[test]
fn independent_transit_budget_qualifies_source_and_anchors_absent_placeholder() {
    use galaxybridge_quic_media::{media::Reassembler, Owner, MS};
    fn frame(flags: u64, bytes: &[u8]) -> Vec<u8> {
        let mut out = flags.to_be_bytes().to_vec();
        out.extend((bytes.len() as u32).to_be_bytes());
        out.extend(bytes);
        out
    }
    let mut owner = Owner::new(context(), 0).unwrap();
    owner.ingest_stock_observed_deferred(1, b"h264", 0).unwrap();
    let mut session = 0x80000000u32.to_be_bytes().to_vec();
    session.extend(64u32.to_be_bytes());
    session.extend(32u32.to_be_bytes());
    owner
        .ingest_stock_observed_deferred(1, &session, 0)
        .unwrap();
    owner
        .ingest_stock_observed_deferred(1, &frame(1 << 62, &h264_config()), 0)
        .unwrap();
    owner
        .ingest_stock_observed_deferred(1, &frame((1 << 61) | 1, &h264_slice(0, 0, true)), 0)
        .unwrap();
    let (source, deadline, _) = owner.cache.next(121 * MS).unwrap();
    assert_eq!((source.lifetime_us, deadline), (500_000, 500 * MS));
    owner.cache.expire(500 * MS);
    assert_eq!(owner.cache.usage(), (0, 0));
    let mut r = Reassembler::new();
    let mut au = video_au(1, true);
    au.lifetime_us = 250_000;
    au.total = 1900;
    au.count = 2;
    au.body.resize(960, 0x55);
    r.expect_gap(au.with_body(vec![]), 0).unwrap();
    r.ingest(au.clone(), 10 * MS).unwrap();
    assert_eq!(
        r.deadline(1, 1),
        Some(200 * MS),
        "first actual header classifies original placeholder, not a new timer"
    );
    r.ingest(au.clone(), 100 * MS).unwrap();
    assert_eq!(r.deadline(1, 1), Some(200 * MS), "duplicates do not renew");
    au.age_us = 200_000;
    r.ingest(au, 110 * MS).unwrap();
    assert_eq!(
        r.deadline(1, 1),
        Some(160 * MS),
        "original source remaining time can only shorten"
    );
    for (track, flags, lifetime, valid) in [
        (1, 3, 500_000, true),
        (1, 3, 250_000, true),
        (1, 3, 120_000, true),
        (1, 2, 500_000, false),
        (1, 2, 250_000, false),
        (2, 3, 500_000, false),
        (2, 3, 250_000, false),
    ] {
        let mut record = video_au(1, true);
        record.track = track;
        record.flags = flags;
        record.lifetime_us = lifetime;
        assert_eq!(record.validate().is_ok(), valid);
    }
}

#[test]
fn fold_sized_recovery_idr_gets_extended_transit_budget() {
    use galaxybridge_quic_media::{Owner, MS};

    fn frame(flags: u64, bytes: &[u8]) -> Vec<u8> {
        let mut out = flags.to_be_bytes().to_vec();
        out.extend((bytes.len() as u32).to_be_bytes());
        out.extend(bytes);
        out
    }

    let mut owner = Owner::new(context(), 0).unwrap();
    owner.ingest_stock_observed_deferred(1, b"h264", 0).unwrap();
    let mut session = 0x80000000u32.to_be_bytes().to_vec();
    session.extend(1_598u32.to_be_bytes());
    session.extend(1_920u32.to_be_bytes());
    owner
        .ingest_stock_observed_deferred(1, &session, 0)
        .unwrap();
    owner
        .ingest_stock_observed_deferred(1, &frame(1 << 62, &h264_config()), 0)
        .unwrap();
    owner
        .ingest_stock_observed_deferred(1, &frame((1 << 61) | 1, &h264_slice(0, 0, true)), 0)
        .unwrap();
    owner.cache.expire(500 * MS);

    // The captured Fold 5 replacement IDR was 214,861 bytes (224 G1
    // fragments). At the old 250 ms cutoff only 205 fragments arrived.
    let mut recovery = h264_slice(0, 0, true);
    recovery.resize(214_861, 0);
    owner
        .ingest_stock_observed_deferred(1, &frame((1 << 61) | 2, &recovery), MS)
        .unwrap();

    let (source, deadline, _) = owner.cache.next(MS).unwrap();
    assert_eq!(source.sequence, 2);
    assert_eq!(source.lifetime_us, 500_000);
    assert_eq!(deadline, 501 * MS);
}

#[test]
fn requested_recovery_idr_is_reliable_strict_and_restores_live_video() {
    use galaxybridge_quic_media::{
        wire::RELIABLE_RECOVERY_FLAG, Failure, MS, RELIABLE_RECOVERY_AU_LIFETIME,
    };

    let mut receiver = receiver_configured();
    let first = video_au(1, true);
    receiver.ingest(first, 0).unwrap();
    drop(commit_next(&mut receiver, 0));

    // Sequence 2 is absent. A later dependent AU starts one real recovery
    // episode but cannot itself repair the decoder dependency chain.
    receiver.ingest(video_au(3, false), MS).unwrap();
    receiver.tick(121 * MS).unwrap();
    assert!(receiver.publish_recovery(121 * MS).unwrap().is_some());

    let mut recovery = video_au(4, true);
    recovery.body.resize(70 * 960, 0);
    let original = recovery.clone();
    let mut source = galaxybridge_quic_media::Owner::new(context(), 0).unwrap();
    source
        .queue_access_unit(recovery, 122 * MS, 122 * MS)
        .unwrap();
    source
        .mark_source_video_sequence_as_reliable_recovery(1, 4)
        .unwrap();
    let mut now = 122 * MS;
    let mut encoded = vec![];
    let mut fragments = 0;
    while let Some(dispatch) = source.next_transport_record(now, false) {
        assert_eq!(dispatch.message.lane, Lane::Reliable);
        if encoded.is_empty() {
            encoded = dispatch.message.payload.clone();
        }
        let fragment = Record::decode(Lane::Reliable, &dispatch.message.payload).unwrap();
        assert_eq!(
            fragment.flags & RELIABLE_RECOVERY_FLAG,
            RELIABLE_RECOVERY_FLAG
        );
        receiver.ingest(fragment, now).unwrap();
        source
            .transport_admission(
                dispatch.record_token,
                galaxybridge_quic::Admission::Accepted,
                now,
            )
            .unwrap();
        fragments += 1;
        now += 5 * MS;
    }
    assert_eq!(fragments, original.body.len().div_ceil(960));
    assert!(
        now > 242 * MS,
        "the reliable recovery crossed the old 120 ms cutoff"
    );
    let configuration = commit_next(&mut receiver, now);
    assert_eq!(configuration.record.kind, 4);
    let recovered = commit_next(&mut receiver, now);
    assert_eq!((recovered.record.kind, recovered.record.sequence), (5, 4));
    assert_eq!(receiver.media_health(1).unwrap().state, 1);
    assert_eq!(receiver.media_health(1).unwrap().reason, 0);

    // A QUIC retransmission can become visible after this exact IDR has already
    // committed. Its sequence proves that it is stale; it must not turn a
    // recovered live session into a protocol failure.
    let late_recovery_fragment = Record::decode(Lane::Reliable, &encoded).unwrap();
    assert_eq!(
        receiver.ingest_classified(late_recovery_fragment, now),
        Ok(galaxybridge_quic_media::media::MediaOutcome::SkippedDependent)
    );

    // A second response to the same bounded recovery can cross the first
    // response. When it is ahead of `next`, that gap must be classified before
    // the strict reliable-lane check so the IDR can recover the new chain.
    let mut crossed_recovery = video_au(6, true);
    crossed_recovery.flags |= RELIABLE_RECOVERY_FLAG;
    crossed_recovery.lifetime_us = (RELIABLE_RECOVERY_AU_LIFETIME / 1000) as u32;
    assert_eq!(
        receiver.ingest_classified(crossed_recovery, now + MS),
        Ok(galaxybridge_quic_media::media::MediaOutcome::Admitted)
    );
    let crossed_configuration = commit_next(&mut receiver, now + MS);
    assert_eq!(crossed_configuration.record.kind, 4);
    let crossed = commit_next(&mut receiver, now + MS);
    assert_eq!((crossed.record.kind, crossed.record.sequence), (5, 6));
    assert_eq!(receiver.media_health(1).unwrap().state, 1);

    // Hardware can deliver a further response after the episode has committed
    // at exactly the next live sequence.  It remains a requested independent
    // AU and must not terminate the whole session merely because no new gap is
    // present to arm.
    let mut aligned_recovery = video_au(7, true);
    aligned_recovery.flags |= RELIABLE_RECOVERY_FLAG;
    aligned_recovery.lifetime_us = (RELIABLE_RECOVERY_AU_LIFETIME / 1000) as u32;
    assert_eq!(
        receiver.ingest_classified(aligned_recovery, now + 2 * MS),
        Ok(galaxybridge_quic_media::media::MediaOutcome::Admitted)
    );
    let aligned = commit_next(&mut receiver, now + 2 * MS);
    assert_eq!((aligned.record.kind, aligned.record.sequence), (5, 7));
    assert_eq!(receiver.media_health(1).unwrap().state, 1);

    // A progress watermark can reserve the exact next sequence immediately
    // before another producer-correlated recovery IDR reaches the reliable
    // lane.  That unreported placeholder is presence for this same AU, not a
    // conflicting recovery episode.  This is the Fold 5 hardware boundary.
    let mut pending_watermark = record(13);
    pending_watermark.sequence = 8;
    receiver.ingest(pending_watermark, now + 3 * MS).unwrap();
    let mut aligned_with_pending_gap = video_au(8, true);
    aligned_with_pending_gap.flags |= RELIABLE_RECOVERY_FLAG;
    aligned_with_pending_gap.lifetime_us = (RELIABLE_RECOVERY_AU_LIFETIME / 1000) as u32;
    assert_eq!(
        receiver.ingest_classified(aligned_with_pending_gap, now + 3 * MS),
        Ok(galaxybridge_quic_media::media::MediaOutcome::Admitted)
    );
    let pending_gap_recovery = commit_next(&mut receiver, now + 3 * MS);
    assert_eq!(
        (
            pending_gap_recovery.record.kind,
            pending_gap_recovery.record.sequence
        ),
        (5, 8)
    );
    assert_eq!(receiver.media_health(1).unwrap().state, 1);

    // A requested recovery IDR can arrive ahead while the exact current AU is
    // already resident in reassembly. Presence of that current AU means there
    // is no gap to arm yet; the independently decodable future response must
    // remain buffered instead of terminating the session.
    receiver.ingest(video_au(9, false), now + 4 * MS).unwrap();
    let mut future_recovery = video_au(11, true);
    future_recovery.flags |= RELIABLE_RECOVERY_FLAG;
    future_recovery.lifetime_us = (RELIABLE_RECOVERY_AU_LIFETIME / 1000) as u32;
    assert_eq!(
        receiver.ingest_classified(future_recovery, now + 4 * MS),
        Ok(galaxybridge_quic_media::media::MediaOutcome::Admitted)
    );
    let resident = commit_next(&mut receiver, now + 4 * MS);
    assert_eq!((resident.record.kind, resident.record.sequence), (5, 9));
    let mut future_watermark = record(13);
    future_watermark.sequence = 11;
    receiver.ingest(future_watermark, now + 5 * MS).unwrap();
    while receiver.next_feedback(now + 5 * MS).is_some() {
        receiver.feedback_accepted();
    }
    receiver.tick(now + 126 * MS).unwrap();
    let future_configuration = commit_next(&mut receiver, now + 126 * MS);
    assert_eq!(future_configuration.record.kind, 4);
    let future = commit_next(&mut receiver, now + 126 * MS);
    assert_eq!((future.record.kind, future.record.sequence), (5, 11));
    assert_eq!(receiver.media_health(1).unwrap().state, 1);

    let mut expired = video_au(5, true);
    expired.flags |= RELIABLE_RECOVERY_FLAG;
    expired.lifetime_us = (RELIABLE_RECOVERY_AU_LIFETIME / 1000) as u32;
    expired.age_us = expired.lifetime_us;
    assert!(expired.validate().is_err());
    assert!(Record::decode(Lane::Datagram, &encoded).is_err());

    let mut dependent = video_au(5, false);
    dependent.flags |= RELIABLE_RECOVERY_FLAG;
    dependent.lifetime_us = (RELIABLE_RECOVERY_AU_LIFETIME / 1000) as u32;
    assert!(dependent.validate().is_err());

    let mut unsolicited = receiver_configured();
    let mut unsolicited_idr = video_au(1, true);
    unsolicited_idr.flags |= RELIABLE_RECOVERY_FLAG;
    unsolicited_idr.lifetime_us = (RELIABLE_RECOVERY_AU_LIFETIME / 1000) as u32;
    let diagnostic = galaxybridge_quic_media::media::first_error::Scope::begin(true);
    assert_eq!(
        unsolicited.ingest(unsolicited_idr, 0),
        Err(Failure::Protocol)
    );
    let rejection = diagnostic.observation().unwrap().rejection.unwrap();
    assert_eq!(rejection.used, 1 | (1 << 8) | (1 << 10));
    assert_eq!((rejection.limit, rejection.requested), (1, 1));
    assert_eq!((rejection.bytes, rejection.byte_limit), (1, 1));
}

#[test]
fn recovery_discarded_source_video_cannot_accumulate_watermarks() {
    use galaxybridge_quic::Admission;
    use galaxybridge_quic_media::{stock::Admission as StockAdmission, wire::Record, Owner, MS};

    fn frame(flags: u64, bytes: &[u8]) -> Vec<u8> {
        let mut out = flags.to_be_bytes().to_vec();
        out.extend((bytes.len() as u32).to_be_bytes());
        out.extend(bytes);
        out
    }

    let mut owner = Owner::new(context(), 0).unwrap();
    owner.ingest_stock_observed_deferred(1, b"h264", 0).unwrap();
    let mut session = 0x80000000u32.to_be_bytes().to_vec();
    session.extend(64u32.to_be_bytes());
    session.extend(32u32.to_be_bytes());
    owner
        .ingest_stock_observed_deferred(1, &session, 0)
        .unwrap();
    owner
        .ingest_stock_observed_deferred(1, &frame(1 << 62, &h264_config()), 0)
        .unwrap();

    let first = owner
        .ingest_stock_observed_deferred(1, &frame((1 << 61) | 1, &h264_slice(0, 0, true)), 0)
        .unwrap();
    assert_eq!(first.1, StockAdmission::AccessUnit { sequence: 1 });

    // Reproduce the real sender ordering: the watermark becomes queued, then
    // transport expiry invalidates the whole video queue before it dispatches.
    owner.tick(20 * MS).unwrap();
    assert_eq!(owner.discard_source_video_for_recovery(1), None);

    // Dependent AUs continue arriving while the producer prepares one fresh
    // IDR. Their payload and matching watermark observations are intentionally
    // absent, so neither may accumulate at the receiver boundary.
    for sequence in 2..=41 {
        let now = (sequence + 19) * MS;
        let publication = owner
            .ingest_stock_observed_deferred(1, &frame(sequence, &h264_slice(0, 0, false)), now)
            .unwrap();
        assert_eq!(publication.1, StockAdmission::AccessUnit { sequence });
        owner.discard_source_video_sequence_for_recovery(1, sequence);
    }
    assert_eq!(owner.cache.usage(), (0, 0));

    let mut watermarks = 0;
    while let Some(dispatch) = owner.next_transport_record(61 * MS, true) {
        let record = Record::decode(dispatch.message.lane, &dispatch.message.payload).unwrap();
        watermarks += usize::from(record.kind == 13);
        owner
            .transport_admission(dispatch.record_token, Admission::Accepted, 61 * MS)
            .unwrap();
    }
    assert_eq!(
        watermarks, 0,
        "sender must not publish progress for video payload deliberately discarded during recovery"
    );
}

#[test]
fn large_recovery_idr_gets_a_budget_that_can_carry_the_complete_access_unit() {
    use galaxybridge_quic::Lane;
    use galaxybridge_quic_media::{stock::Admission, wire::Record, Owner, MS};
    fn frame(flags: u64, bytes: &[u8]) -> Vec<u8> {
        let mut out = flags.to_be_bytes().to_vec();
        out.extend((bytes.len() as u32).to_be_bytes());
        out.extend(bytes);
        out
    }

    let mut owner = Owner::new(context(), 0).unwrap();
    owner.ingest_stock_observed_deferred(1, b"h264", 0).unwrap();
    let mut session = 0x80000000u32.to_be_bytes().to_vec();
    session.extend(64u32.to_be_bytes());
    session.extend(32u32.to_be_bytes());
    owner
        .ingest_stock_observed_deferred(1, &session, 0)
        .unwrap();
    owner
        .ingest_stock_observed_deferred(1, &frame(1 << 62, &h264_config()), 0)
        .unwrap();

    let small = h264_slice(0, 0, true);
    assert_eq!(
        owner
            .ingest_stock_observed_deferred(1, &frame((1 << 61) | 1, &small), MS)
            .unwrap()
            .1,
        Admission::AccessUnit { sequence: 1 }
    );
    let (startup, _, _) = owner.cache.next(2 * MS).unwrap();
    let startup = Record::decode(Lane::Datagram, &startup.encode().unwrap()).unwrap();
    assert_eq!(startup.lifetime_us, 500_000);
    while let Some((record, _, _)) = owner.cache.next(2 * MS) {
        owner.cache.accepted(&record, false).unwrap();
    }

    let mut large = h264_slice(0, 0, true);
    large.resize(300 * 1024, 0);
    assert_eq!(
        owner
            .ingest_stock_observed_deferred(1, &frame((1 << 61) | 2, &large), 3 * MS)
            .unwrap()
            .1,
        Admission::AccessUnit { sequence: 2 }
    );
    let (large_header, _, _) = owner.cache.next(4 * MS).unwrap();
    let large_header = Record::decode(Lane::Datagram, &large_header.encode().unwrap()).unwrap();
    assert_eq!(large_header.lifetime_us, 500_000);
    while let Some((record, _, _)) = owner.cache.next(4 * MS) {
        owner.cache.accepted(&record, false).unwrap();
    }

    assert_eq!(
        owner
            .ingest_stock_observed_deferred(1, &frame((1 << 61) | 3, &small), 5 * MS)
            .unwrap()
            .1,
        Admission::AccessUnit { sequence: 3 }
    );
    let (small_header, _, _) = owner.cache.next(6 * MS).unwrap();
    let small_header = Record::decode(Lane::Datagram, &small_header.encode().unwrap()).unwrap();
    assert_eq!(small_header.lifetime_us, 250_000);
}
#[test]
fn recovery_observation_source_class_matches_serialized_h264_hevc_budget() {
    use galaxybridge_quic_media::{stock::Admission, wire::Record, Owner, MS};
    for name in ["h264", "hevc"] {
        let path = std::path::PathBuf::from(std::env::var_os("GB_QUIC_TEST_FIXTURES").expect("run scripts/test-quic-media-contract.sh")).join(format!("{name}.stock"));
        let bytes = std::fs::read(path).unwrap();
        let mut frames = Vec::new();
        let mut at = 0;
        while at < bytes.len() {
            let n = u32::from_be_bytes(bytes[at..at + 4].try_into().unwrap()) as usize;
            at += 4;
            frames.push(bytes[at..at + n].to_vec());
            at += n;
        }
        for key in [false, true] {
            let mut parity = Vec::new();
            for enabled in [false, true] {
                let mut o = Owner::new(context(), 0).unwrap();
                if enabled {
                    o.receiver.recovery_trace = Some(Box::default());
                }
                for frame in &frames[..3] {
                    o.ingest_stock_observed_deferred(1, frame, 0).unwrap();
                }
                let mut headers = Vec::new();
                for request in 1..=4 {
                    if let Some(t) = o.receiver.recovery_trace.as_mut() {
                        t.watch(request, 1, 1);
                    }
                    // Dependent input cannot select; the second independent AU
                    // without a new watch cannot repeat the observation.
                    for (offset, original) in [(0, &frames[4]), (1, &frames[3]), (2, &frames[3])] {
                        let sequence = (request - 1) * 3 + 1 + offset;
                        let mut frame = original.clone();
                        let flags = sequence | if offset > 0 && key { 1u64 << 61 } else { 0 };
                        frame[..8].copy_from_slice(&flags.to_be_bytes());
                        assert_eq!(
                            o.ingest_stock_observed_deferred(1, &frame, MS).unwrap().1,
                            Admission::AccessUnit { sequence }
                        );
                        while let Some((r, deadline, repair)) = o.cache.next(2 * MS) {
                            assert!(!repair);
                            let decoded =
                                Record::decode(Lane::Datagram, &r.encode().unwrap()).unwrap();
                            assert_eq!(
                                decoded.lifetime_us,
                                if offset > 0 && key { 250_000 } else { 120_000 }
                            );
                            assert_eq!(deadline, MS + decoded.lifetime_us as u64 * 1000);
                            if decoded.index == 0 {
                                headers.push((
                                    decoded.sequence,
                                    decoded.flags & 1,
                                    decoded.lifetime_us,
                                ));
                            }
                            o.cache.accepted(&r, false).unwrap();
                        }
                    }
                }
                let mut classes = Vec::new();
                if let Some(t) = o.receiver.recovery_trace.as_mut() {
                    while let Some((_, e)) = t.pop() {
                        if e.0[0] == 13 {
                            classes.push(e.0);
                        }
                    }
                }
                if enabled {
                    assert_eq!(
                        classes.len(),
                        3,
                        "exact owner cap and first selected qualified AU: {name}, key={key}"
                    );
                    for (i, e) in classes.iter().enumerate() {
                        let sequence = (i as u64 + 1) * 3 - 1;
                        assert_eq!(
                            *e,
                            [
                                13,
                                1,
                                1,
                                1,
                                sequence,
                                i as u64 + 1,
                                key as u64,
                                if key { 250_000 } else { 120_000 }
                            ]
                        );
                        assert!(headers.contains(&(sequence, e[6] as u16, e[7] as u32)));
                    }
                } else {
                    assert!(classes.is_empty() && o.receiver.recovery_trace.is_none());
                }
                parity.push(headers);
                o.retire(galaxybridge_quic_media::Failure::Retired);
                assert_eq!(o.cache.usage(), (0, 0));
            }
            assert_eq!(
                parity[0], parity[1],
                "diagnostics cannot change serialized media or budgets"
            );
        }
    }
}
#[test]
fn recovery_observation_selected_source_expiry_before_any_dispatch_records_zero() {
    use galaxybridge_quic_media::{stock::Admission, Owner, MS};
    fn frame(flags: u64, b: &[u8]) -> Vec<u8> {
        let mut v = flags.to_be_bytes().to_vec();
        v.extend((b.len() as u32).to_be_bytes());
        v.extend(b);
        v
    }
    let mut o = Owner::new(context(), 0).unwrap();
    o.receiver.recovery_trace = Some(Box::default());
    o.ingest_stock_observed_deferred(1, b"h264", 0).unwrap();
    let mut session = 0x80000000u32.to_be_bytes().to_vec();
    session.extend(64u32.to_be_bytes());
    session.extend(32u32.to_be_bytes());
    o.ingest_stock_observed_deferred(1, &session, 0).unwrap();
    o.ingest_stock_observed_deferred(1, &frame(1 << 62, &h264_config()), 0)
        .unwrap();
    o.receiver.recovery_trace.as_mut().unwrap().watch(7, 1, 1);
    let au = h264_slice(0, 0, true);
    let size = au.len();
    assert_eq!(
        o.ingest_stock_observed_deferred(1, &frame((1 << 61) | 1, &au), MS)
            .unwrap()
            .1,
        Admission::AccessUnit { sequence: 1 }
    );
    assert_eq!(o.cache.usage(), (1, size));
    o.cache.expire(501 * MS);
    assert_eq!(o.cache.usage(), (0, 0));
    let mut events = vec![];
    while let Some((_, e)) = o.receiver.recovery_trace.as_mut().unwrap().pop() {
        events.push(e.0);
    }
    assert!(events.iter().any(|e| e[0] == 10 && e[4] == 1 && e[7] == 1));
    assert!(
        events.iter().any(|e| e[0] == 11
            && e[4] == 1
            && e[5] == 7
            && e[6] == 0
            && e[7] == size.div_ceil(960) as u64),
        "admitted then expired without dispatch must have explicit zero fragment total: {events:?}"
    );
    o.retire(galaxybridge_quic_media::Failure::Retired);
    assert_eq!(o.cache.usage(), (0, 0));
}
#[test]
fn recovery_observation_real_stock_qualified_source_decline_and_idle_clock() {
    use galaxybridge_quic_media::{
        stock::{Admission, Reader},
        Owner, MS,
    };
    fn frame(flags: u64, b: &[u8]) -> Vec<u8> {
        let mut v = flags.to_be_bytes().to_vec();
        v.extend((b.len() as u32).to_be_bytes());
        v.extend(b);
        v
    }
    for pressure in [false, true] {
        for enabled in [false, true] {
            let mut o = Owner::new(context(), 0).unwrap();
            if enabled {
                o.receiver.recovery_trace = Some(Box::default());
            }
            o.ingest_stock_observed_deferred(1, b"h264", 0).unwrap();
            let mut session = 0x80000000u32.to_be_bytes().to_vec();
            session.extend(64u32.to_be_bytes());
            session.extend(32u32.to_be_bytes());
            o.ingest_stock_observed_deferred(1, &session, 0).unwrap();
            o.ingest_stock_observed_deferred(1, &frame(1 << 62, &h264_config()), 0)
                .unwrap();
            if let Some(t) = o.receiver.recovery_trace.as_mut() {
                t.watch(7, 1, 1);
            }
            // A real dependent AU must not consume the diagnostic independent watch.
            o.ingest_stock_observed_deferred(1, &frame(1, &h264_slice(0, 0, false)), 0)
                .unwrap();
            if pressure {
                for n in 100..115 {
                    o.queue_access_unit(video_au(n, true), 0, 0).unwrap();
                }
            }
            let bytes = frame((1 << 61) | 2, &h264_slice(0, 0, true));
            o.ingest_stock_observed_deferred(1, &bytes[..1], MS)
                .unwrap();
            let result = o
                .ingest_stock_observed_deferred(1, &bytes[1..], 2 * MS)
                .unwrap()
                .1;
            assert_eq!(
                result,
                if pressure {
                    Admission::DroppedAccessUnit {
                        sequence: 2,
                        reason: galaxybridge_quic_media::Failure::Capacity,
                    }
                } else {
                    Admission::AccessUnit { sequence: 2 }
                }
            );
            if enabled {
                let t = o.receiver.recovery_trace.as_mut().unwrap();
                let (_, e) = t.pop().unwrap();
                assert_eq!(
                    (e.0[0], e.0[4], e.0[5], e.0[7]),
                    (10, 2, 7, if pressure { 2 } else { 1 })
                );
                let (_, e) = t.pop().unwrap();
                assert_eq!((e.0[0], e.0[6], e.0[7]), (12, MS, 2 * MS));
                let (_, e) = t.pop().unwrap();
                assert_eq!((e.0[0], e.0[4], e.0[6], e.0[7]), (11, 2, 0, 1));
                let (_, e) = t.pop().unwrap();
                assert_eq!((e.0[0], e.0[4], e.0[6], e.0[7]), (13, 2, 1, 250_000));
                assert!(t.pop().is_none());
            }
            o.retire(galaxybridge_quic_media::Failure::Retired);
        }
    }
    let mut reader = Reader::new(false, false);
    reader.push(b"\0aac", 0).unwrap();
    assert_eq!(reader.deadline(), None);
    reader.push(&[], 10_000 * MS).unwrap();
    assert_eq!(
        reader.deadline(),
        None,
        "idle empty read is not AU residence"
    );
    reader.push(&[0], 10_000 * MS + 1).unwrap();
    assert_eq!(reader.deadline(), Some(10_120 * MS + 1));
}
#[test]
fn recovery_observation_expiry_stages_and_disabled_policy_parity() {
    use galaxybridge_quic_media::{media::MediaDeclineReason, MS};
    for enabled in [false, true] {
        for origin in [2, 3, 5, 6] {
            let mut r = receiver_configured();
            if enabled {
                r.recovery_trace = Some(Box::default());
            }
            let mut au = video_au(1, true);
            if origin == 2 {
                au.total = 1900;
                au.count = 2;
                au.body.resize(960, 0x55);
            }
            r.ingest(au, 0).unwrap();
            let output = if origin >= 5 {
                Some(r.next_output(0).unwrap().unwrap())
            } else {
                None
            };
            if origin == 6 {
                r.decline_output(
                    output.as_ref().unwrap(),
                    MediaDeclineReason::Expired,
                    120 * MS,
                )
                .unwrap();
            } else {
                r.tick(120 * MS).unwrap();
            }
            assert_eq!(
                (
                    r.media_health(1).unwrap().reason,
                    r.media_health(1).unwrap().declined
                ),
                (4, 1)
            );
            if enabled {
                let (_, event) = r.recovery_trace.as_mut().unwrap().pop().unwrap();
                assert_eq!(
                    (event.0[0], event.0[4], event.0[6], event.0[7]),
                    (1, 1, origin, 0)
                );
            } else {
                assert!(r.recovery_trace.is_none());
            }
            if let Some(output) = output {
                r.release_output(&output, 120 * MS).unwrap();
                drop(output);
            }
            r.retire(galaxybridge_quic_media::Failure::Retired);
            assert_eq!(r.usage(), ((0, 0), (0, 0)));
        }
    }
}
#[test]
fn recovery_observation_staged_config_qualified_commit_and_no_false_flag() {
    use galaxybridge_quic_media::MS;
    let mut flagged = receiver_configured();
    flagged.recovery_trace = Some(Box::default());
    let mut dependent = video_au(1, false);
    dependent.flags |= 1;
    flagged.ingest(dependent, 0).unwrap();
    assert!(flagged.next_output(0).is_err());
    assert!(
        flagged.recovery_trace.as_mut().unwrap().pop().is_none(),
        "a flag cannot create qualified/committed evidence"
    );
    for expire in [false, true] {
        let mut r = receiver_configured();
        r.recovery_trace = Some(Box::default());
        r.ingest(video_au(1, true), 0).unwrap();
        drop(commit_next(&mut r, 0));
        r.ingest(video_au(3, false), 0).unwrap();
        r.tick(120 * MS).unwrap();
        r.ingest(video_au(4, false), 121 * MS).unwrap();
        assert!(r.next_output(121 * MS).unwrap().is_none());
        r.ingest(video_au(5, true), 122 * MS).unwrap();
        let configuration = r.next_output(122 * MS).unwrap().unwrap();
        assert_eq!(configuration.record.kind, 4);
        r.consumer_commit(&configuration, 122 * MS).unwrap();
        r.release_output(&configuration, 122 * MS).unwrap();
        drop(configuration);
        if expire {
            r.tick(242 * MS).unwrap();
            assert_eq!(r.media_health(1).unwrap().reason, 4);
        } else {
            let output = commit_next(&mut r, 123 * MS);
            assert_eq!(output.record.sequence, 5);
            drop(output);
            assert_eq!(r.media_health(1).unwrap().state, 1);
        }
        let mut events = vec![];
        while let Some((_, e)) = r.recovery_trace.as_mut().unwrap().pop() {
            events.push(e.0);
        }
        assert!(events.iter().any(|e| e[0] == 20 && e[4] == 4 && e[6] == 0));
        assert!(events.iter().any(|e| e[0] == 20 && e[4] == 5 && e[6] == 1));
        assert!(events.iter().any(|e| e[0] == 21 && e[4] == 5));
        if expire {
            assert!(events.iter().any(|e| e[0] == 5 && e[4] == 5 && e[6] == 4));
            assert!(!events.iter().any(|e| e[0] == 23 && e[4] == 5));
        } else {
            assert!(events.iter().any(|e| e[0] == 23 && e[4] == 5));
        }
        r.retire(galaxybridge_quic_media::Failure::Retired);
        assert_eq!(r.usage(), ((0, 0), (0, 0)));
    }
}
#[test]
fn media_policy_delayed_loss_is_superseded_only_by_qualified_independent_commit() {
    for coalesced_output in [0, 5] {
        let mut r = receiver_configured();
        for seq in 1..=4 {
            r.ingest(video_au(seq, seq == 1), 0).unwrap();
            drop(commit_next(&mut r, 0));
        }
        r.ingest(video_au(5, true), 0).unwrap();
        let idr = r.next_output(0).unwrap().unwrap();
        let mut copy = r.reserve_output_payload_copy(&idr, 0).unwrap();
        r.commit_native_media(&idr, &mut copy, 0).unwrap();
        r.release_output(&idr, 0).unwrap();
        drop(idr);
        r.native_media_status(1, 1, 1, 2, 1, coalesced_output, false, 0, 0)
            .unwrap();
        let health = r.media_health(1).unwrap();
        assert_eq!(
            (
                health.episode,
                health.state,
                health.reason,
                health.admitted_input_dropped
            ),
            (0, 1, 0, 1),
            "old loss must remain counted without undoing actual IDR5 commit"
        );
        assert!(r.publish_recovery(0).unwrap().is_none());
        r.native_media_status(1, 1, 1, 2, 1, 5, false, 0, 0)
            .unwrap();
        assert_eq!(r.media_health(1).unwrap().admitted_input_dropped, 1);
        r.ingest(video_au(6, false), 0).unwrap();
        let dependent = commit_next(&mut r, 0);
        assert_eq!(dependent.record.sequence, 6);
        drop(dependent);
        let mut ack = vec![];
        while let Some(v) = r.next_feedback(0) {
            if v.kind == 7 {
                ack.push(v.sequence)
            };
            r.feedback_accepted();
        }
        assert_eq!(ack, [1, 2, 3, 4, 5, 6]);
        assert_eq!(r.payload_copy_usage(), [0, 1]);
        drop(copy);
        r.retire(galaxybridge_quic_media::Failure::Retired);
        assert_eq!(r.usage(), ((0, 0), (0, 0)));
    }
}

#[test]
fn media_policy_output_pressure_reason_stays_in_public_enum() {
    for track in [1, 2] {
        let mut r = fix1_receiver(track);
        r.ingest(fix1_au(track, 1, 1, 1, 16667), 0).unwrap();
        drop(commit_next(&mut r, 0));
        r.native_media_status(track, 1, 1, 0, 0, 1, true, 1, 0)
            .unwrap();
        let h = r.media_health(track).unwrap();
        assert_eq!(
            (h.state, h.reason, h.output_pressure),
            (3, 3, if track == 1 { 6 } else { 7 })
        );
        if track == 1 {
            r.native_media_status(1, 1, 1, 1, 1, 1, true, 1, 0).unwrap();
            assert_eq!(r.media_health(1).unwrap().reason, 3);
            while r.next_feedback(0).is_some() {
                r.feedback_accepted();
            }
            r.publish_recovery(0).unwrap();
            r.tick(1750 * galaxybridge_quic_media::MS).unwrap();
            let h = r.media_health(1).unwrap();
            assert_eq!((h.state, h.reason, h.output_pressure), (3, 5, 6));
        }
    }
}

#[test]
fn media_policy_independent_loss_equal_after_and_publication_remain_recoverable() {
    for loss in [5, 6] {
        let mut r = receiver_configured();
        for seq in 1..=6 {
            r.ingest(video_au(seq, seq == 1 || seq == 5), 0).unwrap();
            drop(commit_next(&mut r, 0));
        }
        r.native_media_status(1, 1, 1, loss, 1, 6, false, 0, 0)
            .unwrap();
        let episode = r.media_health(1).unwrap().episode;
        assert_ne!(episode, 0);
        r.native_media_status(1, 1, 1, loss, 1, 6, false, 0, 0)
            .unwrap();
        let h = r.media_health(1).unwrap();
        assert_eq!((h.episode, h.admitted_input_dropped), (episode, 1));
        let mut config = metadata(4, h264_config());
        config.config = 2;
        config.sequence = 7;
        r.ingest(config, 0).unwrap();
        drop(commit_next(&mut r, 0));
        let mut au = video_au(7, true);
        au.config = 2;
        r.ingest(au, 0).unwrap();
        drop(commit_next(&mut r, 0));
        r.native_media_status(1, 1, 1, loss, 1, 6, false, 0, 0)
            .unwrap();
        assert_eq!(
            r.media_health(1).unwrap().episode,
            0,
            "old publication cannot reopen new configuration"
        );
        r.native_media_status(1, 1, 2, 7, 1, 7, false, 0, 0)
            .unwrap();
        assert_ne!(
            r.media_health(1).unwrap().episode,
            0,
            "new independent AU's own loss is not superseded"
        );
    }
    let mut r = receiver_configured();
    for seq in 1..=4 {
        r.ingest(video_au(seq, seq == 1), 0).unwrap();
        drop(commit_next(&mut r, 0));
    }
    r.ingest(video_au(5, true), 0).unwrap();
    let offered = r.next_output(0).unwrap().unwrap();
    r.native_media_status(1, 1, 1, 2, 1, 0, false, 0, 0)
        .unwrap();
    assert_ne!(
        r.media_health(1).unwrap().episode,
        0,
        "qualified but uncommitted IDR is not a recovery fence"
    );
    r.retire(galaxybridge_quic_media::Failure::Retired);
    drop(offered);
    assert_eq!(r.usage(), ((0, 0), (0, 0)));
}
#[test]
fn media_policy_existing_fragmented_next_survives_full_original_pool() {
    use galaxybridge_quic_media::media::MediaOutcome;
    let mut r = receiver_configured();
    let mut retained = vec![];
    for seq in 1..=7 {
        r.ingest(video_au(seq, true), 0).unwrap();
        retained.push(commit_next(&mut r, 0));
    }
    let mut au = video_au(8, true);
    au.body.resize(1900, 0x55);
    for (index, body) in au.body.chunks(960).enumerate() {
        let mut part = au.with_body(body.to_vec());
        part.total = 1900;
        part.count = 2;
        part.index = index as u16;
        assert_eq!(
            r.ingest_classified(part, 0),
            Ok(MediaOutcome::Admitted),
            "the next AU already owns its eighth slot; no new gap allocation is required"
        );
        assert_eq!(r.usage().0 .0, 8);
    }
    let lease = r.next_output(0).unwrap().unwrap();
    assert_eq!(lease.record.sequence, 8);
    r.consumer_commit(&lease, 0).unwrap();
    r.release_output(&lease, 0).unwrap();
    assert_eq!(r.media_health(1).unwrap().declined, 0);
    assert_eq!(r.media_health(1).unwrap().episode, 0);
    drop(lease);
    drop(retained);
}

#[test]
fn media_policy_declined_and_dependent_ranges_do_not_overlap() {
    use galaxybridge_quic_media::media::MediaDeclineReason;
    let mut r = receiver_configured();
    r.ingest(video_au(1, true), 0).unwrap();
    drop(commit_next(&mut r, 0));
    r.ingest(video_au(2, false), 0).unwrap();
    let lost = r.next_output(0).unwrap().unwrap();
    r.decline_output(&lost, MediaDeclineReason::Pressure, 0)
        .unwrap();
    r.release_output(&lost, 0).unwrap();
    drop(lost);
    r.ingest(video_au(3, false), 0).unwrap();
    assert!(r.next_output(0).unwrap().is_none());
    let h = r.media_health(1).unwrap();
    assert_eq!((h.declined, h.skipped), (1, 1));
    r.ingest(video_au(5, true), 0).unwrap();
    drop(commit_next(&mut r, 0));
    drop(commit_next(&mut r, 0));
    let h = r.media_health(1).unwrap();
    assert_eq!((h.declined, h.skipped), (1, 2));
    assert_eq!(
        2 + h.declined + h.skipped,
        5,
        "two actual admissions plus disjoint loss classes cover the source range"
    );
}

#[test]
fn media_policy_admitted_audio_loss_signals_gap_without_rewinding_admission() {
    use galaxybridge_quic_media::media::Disposition;
    let mut r = fix1_receiver(2);
    for seq in 1..=3 {
        r.ingest(fix1_au(2, 1, 1, seq, seq * 21000), 0).unwrap();
        drop(commit_next(&mut r, 0));
    }
    while r.disposition().is_some() {}
    r.native_media_status(2, 1, 1, 2, 1, 2, true, 0, 0).unwrap();
    assert!(matches!(
        r.disposition(),
        Some(Disposition::AudioGap { sequence: 2 })
    ));
    assert_eq!(r.media_health(2).unwrap().admitted_sequence, 3);
    r.native_media_status(2, 1, 1, 2, 1, 2, true, 0, 0).unwrap();
    assert!(r.disposition().is_none());
    r.ingest(fix1_au(2, 1, 1, 4, 84000), 0).unwrap();
    drop(commit_next(&mut r, 0));
    assert_eq!(r.media_health(2).unwrap().admitted_sequence, 4);
}

#[test]
fn media_policy_original_pressure_keeps_exact_owner_and_watermark_ack_alive() {
    let mut r = receiver_configured();
    let mut retained = Vec::new();
    for sequence in 1..=8 {
        r.ingest(video_au(sequence, true), 0).unwrap();
        retained.push(commit_next(&mut r, 0));
    }
    assert_eq!(r.usage().0 .0, 8);
    let result = r.ingest(video_au(9, false), 0);
    eprintln!(
        "media-policy original pressure: {result:?} terminal={:?}",
        r.terminal()
    );
    assert_eq!(
        result,
        Ok(()),
        "valid AU pressure is decline, not owner retirement"
    );
    assert_eq!(r.terminal(), None);
    let mut watermark = record(13);
    watermark.sequence = 9;
    r.ingest(watermark, 0).unwrap();
    let mut seen = Vec::new();
    while let Some(v) = r.next_feedback(0) {
        seen.push(v);
        r.feedback_accepted();
    }
    assert!(seen
        .iter()
        .any(|v| v.kind == 14 && v.body[0] == 13 && v.sequence == 9));
    assert!(!seen.iter().any(|v| v.kind == 7 && v.sequence == 9));
    assert_eq!(r.usage().0 .0, 8);
    drop(retained);
}

#[test]
fn media_policy_exhausted_gap_is_degraded_not_terminal() {
    use galaxybridge_quic_media::MS;
    let mut r = receiver_configured();
    r.ingest(video_au(1, true), 0).unwrap();
    commit_next(&mut r, 0);
    while r.next_feedback(0).is_some() {
        r.feedback_accepted();
    }
    r.ingest(video_au(3, false), MS).unwrap();
    r.tick(61 * MS).unwrap();
    let result = r.tick(1751 * MS);
    eprintln!(
        "media-policy exhausted recovery: {result:?} terminal={:?}",
        r.terminal()
    );
    assert_eq!(
        result,
        Ok(()),
        "exhaustion ends media recovery timers, not authenticated ownership"
    );
    assert_eq!(r.terminal(), None);
}

#[test]
fn media_policy_three_absolute_opportunities_and_passive_exhaustion() {
    use galaxybridge_quic_media::{media::MediaDeclineReason, Failure, MS};
    let mut r = receiver_configured();
    r.ingest(video_au(1, true), 0).unwrap();
    while r.next_feedback(0).is_some() {
        r.feedback_accepted();
    }
    let lease = r.next_output(0).unwrap().unwrap();
    r.decline_output(&lease, MediaDeclineReason::Pressure, 0)
        .unwrap();
    r.release_output(&lease, 0).unwrap();
    drop(lease);
    let one = r.publish_recovery(0).unwrap().unwrap();
    assert_eq!(one.deadline, 250 * MS);
    assert!(r.publish_recovery(250 * MS - 1).unwrap().is_none());
    assert!(r.publish_recovery(250 * MS).unwrap().is_none());
    assert!(r.publish_recovery(500 * MS - 1).unwrap().is_none());
    assert_eq!(
        r.publish_recovery(500 * MS).unwrap().unwrap().deadline,
        750 * MS
    );
    assert!(r.publish_recovery(750 * MS - 1).unwrap().is_none());
    assert!(r.publish_recovery(750 * MS).unwrap().is_none());
    assert!(r.publish_recovery(1500 * MS - 1).unwrap().is_none());
    assert_eq!(
        r.publish_recovery(1500 * MS).unwrap().unwrap().deadline,
        1750 * MS
    );
    assert!(r.publish_recovery(1750 * MS - 1).unwrap().is_none());
    r.tick(1750 * MS).unwrap();
    let h = r.media_health(1).unwrap();
    assert_eq!((h.state, h.attempt, h.next_deadline), (3, 3, 0));
    assert!(r.publish_recovery(10_000 * MS).unwrap().is_none());
    assert_eq!(r.next_wakeup(), None);
    assert_eq!(
        r.media_retry(h.episode + 1, 10_000 * MS),
        Err(Failure::Protocol)
    );
    r.media_retry(h.episode, 10_000 * MS).unwrap();
    assert_eq!(
        r.media_retry(h.episode, 10_000 * MS),
        Err(Failure::Protocol)
    );
    assert!(r.publish_recovery(10_000 * MS).unwrap().is_some());
}

#[test]
fn media_policy_repeated_exhausted_episodes_remain_bounded_and_recover_in_place() {
    use galaxybridge_quic_media::{media::MediaDeclineReason, Failure, MS};
    let mut r = receiver_configured();
    r.ingest(video_au(1, true), 0).unwrap();
    while r.next_feedback(0).is_some() {
        r.feedback_accepted();
    }
    let lease = r.next_output(0).unwrap().unwrap();
    r.decline_output(&lease, MediaDeclineReason::Pressure, 0)
        .unwrap();
    r.release_output(&lease, 0).unwrap();
    drop(lease);
    let mut previous_episode = 0;
    for cycle in 0..3 {
        let anchor = cycle * 1750 * MS;
        assert_eq!(
            r.publish_recovery(anchor).unwrap().unwrap().deadline,
            anchor + 250 * MS
        );
        // Repeated host polls cannot manufacture additional requests.
        for _ in 0..1000 {
            assert!(r.publish_recovery(anchor).unwrap().is_none());
        }
        // A delayed owner may miss a request window. Exhaustion still occurs
        // at the same native budget, even with fewer than three submissions.
        if cycle != 1 {
            assert!(r.publish_recovery(anchor + 500 * MS).unwrap().is_some());
            assert!(r.publish_recovery(anchor + 1500 * MS).unwrap().is_some());
        }
        r.tick(anchor + 1749 * MS).unwrap();
        assert_ne!(r.media_health(1).unwrap().state, 3);
        let end = anchor + 1750 * MS;
        r.tick(end).unwrap();
        let health = r.media_health(1).unwrap();
        assert_eq!((health.state, health.reason), (3, 5));
        assert_eq!(health.attempt, if cycle == 1 { 2 } else { 3 });
        assert!(health.episode > previous_episode);
        assert_eq!(r.terminal(), None);
        assert!(r.publish_recovery(end).unwrap().is_none());
        r.media_retry(health.episode, end).unwrap();
        assert_eq!(r.media_retry(health.episode, end), Err(Failure::Protocol));
        previous_episode = health.episode;
    }
    // The original receiver and codec context accept a fresh IDR after the
    // third failed cycle. No capture/connection replacement is involved.
    let now = 5250 * MS;
    r.ingest(video_au(2, true), now).unwrap();
    let config = commit_next(&mut r, now);
    assert_eq!(config.record.kind, 4, "recovery republishes the codec first");
    assert_ne!(r.media_health(1).unwrap().state, 1);
    let output = commit_next(&mut r, now);
    assert_eq!(output.record.kind, 5);
    assert_eq!(output.record.sequence, 2);
    let health = r.media_health(1).unwrap();
    assert_eq!((health.state, health.reason, health.episode), (1, 0, 0));
    assert!(r.next_output(now).unwrap().is_none());
    assert!(r.publish_recovery(now).unwrap().is_none());
    assert_eq!(r.terminal(), None);
}

#[test]
fn media_policy_new_committed_publication_supersedes_only_current_episode() {
    use galaxybridge_quic_media::{media::MediaDeclineReason, Failure};
    let mut r = receiver_configured();
    r.ingest(video_au(1, true), 0).unwrap();
    let lease = r.next_output(0).unwrap().unwrap();
    r.decline_output(&lease, MediaDeclineReason::Pressure, 0)
        .unwrap();
    r.release_output(&lease, 0).unwrap();
    drop(lease);
    let old = r.publish_recovery(0).unwrap().unwrap();
    let episode = r.media_health(1).unwrap().episode;
    fix1_replace(&mut r, 1, 2, 2, 0);
    assert_eq!(r.media_health(1).unwrap().episode, 0);
    assert!(!r.recovery_current(old.epoch, old.config, old.sequence));
    assert_eq!(r.media_retry(episode, 0), Err(Failure::Protocol));
    assert!(r.publish_recovery(0).unwrap().is_none());
    r.ingest(fix1_au(1, 2, 2, 2, 2 * 16667), 0).unwrap();
    drop(commit_next(&mut r, 0));
    assert_eq!(r.media_health(1).unwrap().state, 1);
}

#[test]
fn media_policy_decline_release_is_not_commit_or_refund_and_expiry_remains_owned() {
    use galaxybridge_quic_media::{media::MediaDeclineReason, Failure};
    for expired in [false, true] {
        let mut r = receiver_configured();
        r.ingest(video_au(1, true), 0).unwrap();
        let lease = r.next_output(0).unwrap().unwrap();
        let copy = r.reserve_output_payload_copy(&lease, 0).unwrap();
        let bytes = r.usage();
        let now = if expired { lease.deadline } else { 0 };
        assert_eq!(
            r.decline_output(&lease, MediaDeclineReason::Expired, 0),
            Err(Failure::Protocol)
        );
        r.decline_output(
            &lease,
            if expired {
                MediaDeclineReason::Expired
            } else {
                MediaDeclineReason::Pressure
            },
            now,
        )
        .unwrap();
        assert_eq!(r.usage(), bytes);
        assert_eq!(
            r.decline_output(&lease, MediaDeclineReason::Pressure, now),
            Err(Failure::Protocol)
        );
        assert!(r.consumer_commit(&lease, now).is_err());
        r.release_output(&lease, now).unwrap();
        assert!(r.release_output(&lease, now).is_err());
        while let Some(v) = r.next_feedback(now) {
            assert_ne!(v.kind, 7);
            r.feedback_accepted();
        }
        drop(lease);
        assert_eq!(r.payload_copy_usage(), [1, 0]);
        r.retire(Failure::Retired);
        drop(copy);
        assert_eq!(r.usage(), ((0, 0), (0, 0)));
    }
}

#[test]
fn media_policy_native_output_pressure_does_not_break_dependency_or_rewrite_ack() {
    let mut r = receiver_configured();
    for sequence in 1..=3 {
        r.ingest(video_au(sequence, sequence == 1), 0).unwrap();
        drop(commit_next(&mut r, 0));
    }
    r.native_media_status(1, 1, 1, 0, 0, 2, true, 1, 0).unwrap();
    let health = r.media_health(1).unwrap();
    assert_eq!(
        (health.state, health.output_pressure, health.output_dropped),
        (3, 6, 1)
    );
    assert_eq!(health.episode, 0);
    assert!(r.publish_recovery(0).unwrap().is_none());
    r.native_media_status(1, 1, 1, 0, 0, 1, false, 0, 0)
        .unwrap();
    assert_eq!(
        r.media_health(1).unwrap().output_pressure,
        6,
        "older output cannot clear pressure"
    );
    r.native_media_status(1, 1, 1, 0, 0, 3, false, 1, 0)
        .unwrap();
    assert_eq!(r.media_health(1).unwrap().state, 1);
    let mut ack = vec![];
    while let Some(v) = r.next_feedback(0) {
        if v.kind == 7 {
            ack.push(v.sequence)
        };
        r.feedback_accepted();
    }
    assert_eq!(ack, [1, 2, 3]);
    // The same successfully admitted input ACK remains truthful when a later
    // queued input is lost; dependency recovery is a separate outcome.
    r.native_media_status(1, 1, 1, 3, 2, 3, false, 1, 0)
        .unwrap();
    assert_eq!(r.media_health(1).unwrap().admitted_input_dropped, 2);
    let episode = r.media_health(1).unwrap().episode;
    assert_ne!(episode, 0);
    assert!(r.publish_recovery(0).unwrap().is_some());
    r.ingest(video_au(4, false), 0).unwrap();
    assert!(r.next_output(0).unwrap().is_none());
    r.ingest(video_au(5, true), 0).unwrap();
    let config = r.next_output(0).unwrap().unwrap();
    assert_eq!(config.record.kind, 4);
    r.consumer_commit(&config, 0).unwrap();
    r.release_output(&config, 0).unwrap();
    assert_eq!(
        r.media_health(1).unwrap().episode,
        episode,
        "same source configuration republish cannot reset recovery"
    );
    let idr = r.next_output(0).unwrap().unwrap();
    assert_eq!(idr.record.sequence, 5);
    assert_ne!(
        r.media_health(1).unwrap().episode,
        0,
        "receipt is not actual admission"
    );
    let mut copy = r.reserve_output_payload_copy(&idr, 0).unwrap();
    assert_eq!(
        r.commit_native_media(&idr, &mut copy, 0).unwrap(),
        galaxybridge_quic_media::media::MediaOutcome::Admitted
    );
    r.release_output(&idr, 0).unwrap();
    assert_eq!(r.media_health(1).unwrap().episode, 0);
}

#[test]
fn media_policy_copy_pressure_reason_and_skipped_opportunity_are_exact() {
    use galaxybridge_quic_media::{
        media::{MediaDeclineReason, MediaOutcome},
        MS,
    };
    let mut r = receiver_configured();
    r.ingest(video_au(1, true), 0).unwrap();
    let lease = r.next_output(0).unwrap().unwrap();
    let copies: Vec<_> = (0..8)
        .map(|_| r.reserve_output_payload_copy(&lease, 0).unwrap())
        .collect();
    assert_eq!(
        r.native_copy_preflight(&lease, None, 0).unwrap(),
        MediaOutcome::DeclinedPressure
    );
    r.decline_output(&lease, MediaDeclineReason::Pressure, 0)
        .unwrap();
    r.release_output(&lease, 0).unwrap();
    assert_eq!(r.media_health(1).unwrap().reason, 2);
    while r.next_feedback(0).is_some() {
        r.feedback_accepted();
    }
    assert!(r.publish_recovery(0).unwrap().is_some());
    assert!(
        r.publish_recovery(750 * MS).unwrap().is_none(),
        "missed second window is skipped"
    );
    assert_eq!(
        r.publish_recovery(1500 * MS).unwrap().unwrap().deadline,
        1750 * MS
    );
    r.tick(1750 * MS).unwrap();
    assert_eq!(r.next_wakeup(), None);
    drop(copies);
}

#[test]
fn native_transfer_commits_once_preserving_64_storage_8_transfer_and_real_bytes() {
    use galaxybridge_quic_media::Failure;
    let mut r = receiver_configured();
    let mut stored = Vec::new();
    for sequence in 1..=64 {
        r.ingest(video_au(sequence, true), 0).unwrap();
        let lease = r.next_output(0).unwrap().unwrap();
        let mut copy = r.reserve_output_payload_copy(&lease, 0).unwrap();
        let before = r.usage();
        assert_eq!(r.payload_copy_usage(), [1, sequence as usize - 1]);
        r.consumer_commit_payload_copy(&lease, &mut copy, 0)
            .unwrap();
        assert_eq!(r.usage(), before, "transfer allocates/releases no storage");
        assert_eq!(
            r.consumer_commit_payload_copy(&lease, &mut copy, 0),
            Err(Failure::Protocol)
        );
        r.release_output(&lease, 0).unwrap();
        drop(lease);
        while r.next_feedback(0).is_some() {
            r.feedback_accepted();
        }
        stored.push(copy);
    }
    assert_eq!(r.payload_copy_usage(), [0, 64]);
    assert_eq!(r.usage().0 .0, 0);
    r.ingest(video_au(65, true), 0).unwrap();
    let lease = r.next_output(0).unwrap().unwrap();
    let mut pending: Vec<_> = (0..8)
        .map(|_| r.reserve_output_payload_copy(&lease, 0).unwrap())
        .collect();
    assert!(matches!(
        r.reserve_output_payload_copy(&lease, 0),
        Err(Failure::Capacity)
    ));
    let before = r.usage();
    assert_eq!(
        r.consumer_commit_payload_copy(&lease, &mut pending[0], 0),
        Err(Failure::Capacity)
    );
    assert_eq!(r.usage(), before);
    assert_eq!(r.payload_copy_usage(), [8, 64]);
    assert!(
        r.check_output(&lease, 0).is_ok(),
        "capacity did NOT commit the lease"
    );
    assert!(
        r.next_feedback(0).is_none(),
        "no delivered ACK on rejected admission"
    );
    stored.pop();
    r.consumer_commit_payload_copy(&lease, &mut pending[0], 0)
        .unwrap();
    assert_eq!(r.payload_copy_usage(), [7, 64]);
    r.release_output(&lease, 0).unwrap();
    drop(lease);
    r.retire(Failure::Retired);
    assert!(
        r.usage().0 .1 > 0 && r.usage().1 .1 > 0,
        "true copies/config survive retire"
    );
    std::thread::spawn(move || {
        drop(pending);
        drop(stored);
    })
    .join()
    .unwrap();
    assert_eq!(r.payload_copy_usage(), [0, 0]);
    assert_eq!(r.usage(), ((0, 0), (0, 0)));
}

#[test]
fn native_transfer_rejects_foreign_metadata_expired_and_legacy_committed_without_credit_change() {
    use galaxybridge_quic_media::Failure;
    for mode in 0..4 {
        let mut r = receiver_configured();
        r.ingest(video_au(1, true), 0).unwrap();
        let lease = r.next_output(0).unwrap().unwrap();
        let mut copy = r.reserve_output_payload_copy(&lease, 0).unwrap();
        let result = match mode {
            0 => {
                let mut other = receiver_configured();
                other.consumer_commit_payload_copy(&lease, &mut copy, 0)
            }
            1 => {
                r.consumer_commit(&lease, 0).unwrap();
                r.consumer_commit_payload_copy(&lease, &mut copy, 0)
            }
            2 => r.consumer_commit_payload_copy(&lease, &mut copy, lease.deadline),
            _ => {
                r.retire(Failure::Retired);
                r.consumer_commit_payload_copy(&lease, &mut copy, 0)
            }
        };
        assert!(result.is_err());
        assert_eq!(r.payload_copy_usage(), [1, 0]);
        r.retire(Failure::Retired);
        drop(copy);
        drop(lease);
        assert_eq!(r.usage(), ((0, 0), (0, 0)));
    }
    let mut r = receiver_configured();
    let mut config = metadata(4, h264_config());
    config.config = 2;
    config.sequence = 2;
    r.ingest(config, 0).unwrap();
    let lease = r.next_output(0).unwrap().unwrap();
    let mut copy = r.reserve_output_payload_copy(&lease, 0).unwrap();
    let before = r.usage();
    assert_eq!(
        r.consumer_commit_payload_copy(&lease, &mut copy, 0),
        Err(Failure::Protocol)
    );
    assert_eq!(r.usage(), before);
    r.consumer_commit(&lease, 0).unwrap();
    r.release_output(&lease, 0).unwrap();
    r.retire(Failure::Retired);
    drop(copy);
    drop(lease);
    assert_eq!(r.usage(), ((0, 0), (0, 0)));
}

#[test]
fn native_transferred_storage_shares_original_composite_byte_ceiling() {
    use galaxybridge_quic_media::Failure;
    let mut r = receiver_configured();
    let mut retained = Vec::new();
    for sequence in 1..=3 {
        let mut original = video_au(sequence, true);
        original.body.resize(4 * 1024 * 1024, 0x55);
        for (index, bytes) in original.body.chunks(960).enumerate() {
            let mut part = original.with_body(bytes.to_vec());
            part.total = original.body.len() as u32;
            part.count = original.body.len().div_ceil(960) as u16;
            part.index = index as u16;
            r.ingest(part, 0).unwrap();
        }
        let lease = r.next_output(0).unwrap().unwrap();
        let mut copy = r.reserve_output_payload_copy(&lease, 0).unwrap();
        r.consumer_commit_payload_copy(&lease, &mut copy, 0)
            .unwrap();
        r.release_output(&lease, 0).unwrap();
        retained.push(copy);
        while r.next_feedback(0).is_some() {
            r.feedback_accepted();
        }
    }
    assert_eq!(r.payload_copy_usage(), [0, 3]);
    assert_eq!(r.usage().0, (0, 12 * 1024 * 1024));
    r.ingest(video_au(4, true), 0).unwrap();
    let lease = r.next_output(0).unwrap().unwrap();
    let composite = r.reserve_output_copy(&lease, 0).unwrap();
    assert_eq!(
        r.usage().0 .0,
        2,
        "legacy composite still uses original slot"
    );
    let mut copy = r.reserve_output_payload_copy(&lease, 0).unwrap();
    r.consumer_commit_payload_copy(&lease, &mut copy, 0)
        .unwrap();
    assert_eq!(r.payload_copy_usage(), [0, 4]);
    r.release_output(&lease, 0).unwrap();
    drop(lease);
    drop(composite);
    drop(copy);
    let mut big = video_au(5, true);
    big.total = 4 * 1024 * 1024;
    big.count = (4usize * 1024 * 1024).div_ceil(960) as u16;
    big.body = vec![0x55; 960];
    r.ingest(big, 0).unwrap();
    assert_eq!(r.usage().0, (1, 16 * 1024 * 1024));
    // Byte rejection is independent of the new64 storage count.
    assert_eq!(
        r.ingest_classified(video_au(6, true), 0),
        Ok(galaxybridge_quic_media::media::MediaOutcome::DeclinedPressure)
    );
    assert_eq!(r.payload_copy_usage(), [0, 3]);
    assert_eq!(
        r.usage().0,
        (0, 12 * 1024 * 1024),
        "obsolete unadmitted reassembly is shed, real stored copies remain charged"
    );
    assert_eq!(r.terminal(), None);
    r.retire(Failure::Retired);
    drop(retained);
    assert_eq!(r.usage(), ((0, 0), (0, 0)));
}

#[test]
fn held_complete_next_does_not_allocate_duplicate_gap_slot() {
    use galaxybridge_quic_media::media::first_error;
    let mut r = receiver_configured();
    let mut retained = Vec::new();
    for sequence in 1..=7 {
        r.ingest(video_au(sequence, true), 0).unwrap();
        retained.push(commit_next(&mut r, 0));
    }
    r.ingest(video_au(8, true), 0).unwrap();
    let eighth = r.next_output(0).unwrap().unwrap();
    assert_eq!(r.usage().0 .0, 8);
    let mut watermark = record(13);
    watermark.sequence = 8;
    let observation = first_error::Scope::begin(true);
    let result = r.ingest(watermark, 0);
    eprintln!(
        "held-next result={result:?} rejection={:?}",
        observation.observation()
    );
    assert_eq!(
        result,
        Ok(()),
        "complete extracted next is not a missing ninth AU"
    );
    assert_eq!(r.usage().0 .0, 8);
    r.consumer_commit(&eighth, 0).unwrap();
    r.release_output(&eighth, 0).unwrap();
    drop(eighth);
    drop(retained);
    assert_eq!(r.usage().0, (0, 0));
}
#[test]
fn held_presence_preserves_missing_identity_and_exact_expiry() {
    use galaxybridge_quic_media::{media::Disposition, Failure, MS};
    fn feedback(r: &mut galaxybridge_quic_media::media::Receiver, now: u64) -> Vec<Record> {
        let mut all = Vec::new();
        while let Some(record) = r.next_feedback(now) {
            all.push(record);
            r.feedback_accepted();
        }
        all
    }
    let mut missing = receiver_configured();
    missing.ingest(record(13), 0).unwrap();
    let requests = feedback(&mut missing, 5 * MS);
    assert!(requests.iter().any(|r| r.kind == 6 && r.sequence == 1));
    assert_eq!(missing.feedback_deadline(), None);
    {
        let mut r = receiver_configured();
        r.ingest(video_au(1, true), 0).unwrap();
        let held = r.next_output(0).unwrap().unwrap();
        let mut watermark = record(13);
        watermark.generation += 1;
        assert_eq!(
            r.ingest(watermark, 0),
            Err(Failure::Protocol),
            "a foreign session generation remains a protocol violation"
        );
        drop(held);
    }
    for field in 0..2 {
        let mut r = receiver_configured();
        r.ingest(video_au(1, true), 0).unwrap();
        let held = r.next_output(0).unwrap().unwrap();
        let usage = r.usage();
        let mut watermark = record(13);
        if field == 0 {
            watermark.epoch += 1;
        } else {
            watermark.config += 1;
        }
        assert_eq!(
            r.ingest_classified(watermark, 0),
            Ok(galaxybridge_quic_media::media::MediaOutcome::SkippedDependent),
            "a reordered supersedable watermark cannot retire live media"
        );
        assert_eq!(r.usage(), usage, "the held AU remains the only owner");
        assert!(r.disposition().is_none());
        drop(held);
    }
    let mut r = receiver_configured();
    r.ingest(video_au(1, true), 0).unwrap();
    let held = r.next_output(0).unwrap().unwrap();
    r.ingest(record(13), held.deadline - 1).unwrap();
    assert!(feedback(&mut r, held.deadline - 1)
        .iter()
        .all(|r| r.kind != 6));
    assert!(r.disposition().is_none());
    r.tick(held.deadline).unwrap();
    assert!(matches!(
        r.disposition(),
        Some(Disposition::RecoveryRequired {
            track: 1,
            sequence: 1,
            ..
        })
    ));
    assert!(r.check_output(&held, held.deadline).is_err());
    assert_eq!(r.skipped_video(), 1);
}
#[test]
fn original_receipt_valid_deadline_does_not_require_fresh_deadline_capacity() {
    use galaxybridge_quic_media::{Owner, MS};
    let now = u64::MAX - 250 * MS;
    let received = u64::MAX - 700 * MS;
    let mut owner = Owner::new(context(), now).unwrap();
    let mut record = critical(9, 1, vec![5]);
    record.body[8..32].fill(0);
    owner
        .queue_critical_received(record, received, now)
        .expect("valid original deadline must not compute fresh now+500ms");
    assert_eq!(
        owner
            .transactions
            .next_transport_record(now)
            .unwrap()
            .deadline,
        u64::MAX - 200 * MS
    );
}

#[test]
fn metadata_defer_charges_original_prefix_expiry_but_not_ordinary_audio_control() {
    use galaxybridge_quic_media::{stock::Admission, Failure, Owner, MS};
    fn frame(flags: u64, body: &[u8]) -> Vec<u8> {
        let mut bytes = flags.to_be_bytes().to_vec();
        bytes.extend((body.len() as u32).to_be_bytes());
        bytes.extend(body);
        bytes
    }
    let mut owner = Owner::new(context(), 0).unwrap();
    owner.ingest_stock_observed_deferred(1, b"h264", 0).unwrap();
    let mut session = 0x80000000u32.to_be_bytes().to_vec();
    session.extend(64u32.to_be_bytes());
    session.extend(32u32.to_be_bytes());
    owner
        .ingest_stock_observed_deferred(1, &session, 0)
        .unwrap();
    let config = frame(1 << 62, &h264_config());
    owner.ingest_stock_observed_deferred(1, &config, 0).unwrap();
    let au1 = frame((1 << 61) | 16667, &h264_slice(0, 0, true));
    let au2 = frame(33334, &h264_slice(0, 0, false));
    assert!(matches!(
        owner.ingest_stock_observed_deferred(1, &au1, 0).unwrap().1,
        Admission::AccessUnit { sequence: 1 }
    ));
    assert!(
        matches!(
            owner.ingest_stock_observed_deferred(1, &au2, MS).unwrap().1,
            Admission::AccessUnit { sequence: 2 }
        ),
        "watermark interval cannot gate consecutive ordinary AUs"
    );
    let original = 2 * MS;
    assert_eq!(
        owner
            .ingest_stock_observed_deferred(1, &config[..1], original)
            .unwrap()
            .0,
        1
    );
    let before = owner.receiver.usage().1;
    let mut suffix = config[1..].to_vec();
    suffix.extend(&au1);
    let (n, admission, publication) = owner
        .ingest_stock_observed_deferred(1, &suffix, 3 * MS)
        .unwrap();
    assert_eq!(n, config.len() - 1);
    assert_eq!(admission, Admission::Incomplete);
    assert!(publication.is_none());
    assert_eq!(owner.deferred_stock_track(), Some(1));
    let charged = owner.receiver.usage().1;
    assert_eq!(charged.0, before.0 + 1);
    assert_eq!(charged.1, before.1 + config.len() - 12);
    assert_eq!(
        owner
            .ingest_stock_observed_deferred(1, &au1, 4 * MS)
            .unwrap()
            .0,
        0,
        "successor prefix remains unconsumed"
    );
    owner
        .ingest_stock_observed_deferred(2, &[0, 97, 97, 99], 4 * MS)
        .unwrap();
    owner
        .ingest_stock_observed_deferred(2, &frame(1 << 62, &[0x11, 0x90]), 4 * MS)
        .unwrap();
    assert!(matches!(
        owner
            .ingest_stock_observed_deferred(2, &frame(42, &[1, 2, 3]), 4 * MS)
            .unwrap()
            .1,
        Admission::AccessUnit { sequence: 1 }
    ));
    let mut key = critical(9, 1, vec![5]);
    key.body[8..32].fill(0);
    owner.queue_critical(key, 4 * MS).unwrap();
    let mut control_sent = false;
    for _ in 0..16 {
        let Some(d) = owner.next_transport_record(20 * MS, true) else {
            break;
        };
        control_sent |= Record::decode(d.message.lane, &d.message.payload)
            .unwrap()
            .kind
            == 8;
        owner
            .transport_admission(
                d.record_token,
                galaxybridge_quic::Admission::Accepted,
                20 * MS,
            )
            .unwrap();
    }
    assert!(control_sent);
    assert_eq!(
        owner
            .ingest_stock_observed_deferred(1, &au1, 121 * MS)
            .unwrap()
            .0,
        0
    );
    assert_eq!(owner.next_wakeup(), Some(122 * MS));
    assert_eq!(owner.tick(122 * MS), Err(Failure::Deadline));
    assert_eq!(owner.deferred_stock_track(), None);
}

#[test]
fn backend_original_critical_receipt_survives_advanced_service_clock() {
    use galaxybridge_quic_media::{Failure, Owner, MS};
    let mut o = Owner::new(context(), 0).unwrap();
    o.receiver = receiver_configured();
    let mut r = critical(9, 1, vec![5]);
    r.body[8..32].fill(0);
    o.tick(100 * MS).unwrap();
    o.queue_critical_received(r.clone(), 10 * MS, 100 * MS)
        .expect("older valid receipt must not regress service clock");
    let d = o
        .next_transport_record_with_policy(
            100 * MS,
            galaxybridge_quic_media::DispatchPolicy {
                feedback: false,
                ..Default::default()
            },
        )
        .unwrap();
    assert_eq!(
        d.deadline,
        510 * MS,
        "do not replace original deadline by service+500ms"
    );
    assert_eq!(
        Record::decode(d.message.lane, &d.message.payload)
            .unwrap()
            .age_us,
        90000
    );
    for (received, now, expected) in [
        (0, 500 * MS, Failure::Deadline),
        (0, 501 * MS, Failure::Deadline),
        (101 * MS, 100 * MS, Failure::Clock),
        (u64::MAX - 1, u64::MAX - 1, Failure::Clock),
    ] {
        let mut o = Owner::new(context(), 0).unwrap();
        o.receiver = receiver_configured();
        assert_eq!(
            o.queue_critical_received(r.clone(), received, now),
            Err(expected)
        );
        assert!(
            o.transactions.next_transport_record(now).is_none(),
            "invalid receipt cannot admit a transaction"
        );
    }
    let mut o = Owner::new(context(), 0).unwrap();
    o.receiver = receiver_configured();
    o.queue_critical(r, 10 * MS).unwrap();
    assert_eq!(
        o.transactions
            .next_transport_record(10 * MS)
            .unwrap()
            .deadline,
        510 * MS
    );
}

#[test]
fn backend_seam_fence_keeps_predecessor_metadata_and_original_deadline() {
    use galaxybridge_quic_media::{DispatchPolicy, Failure, Owner, MS};
    let mut o = Owner::new(context(), 0).unwrap();
    o.transactions
        .queue_transaction(critical(9, 1, vec![5]), 0)
        .unwrap();
    o.transactions
        .queue_transaction(critical(9, 2, vec![5]), 0)
        .unwrap();
    o.transactions.queue_transaction(record(1), 0).unwrap();
    let policy = DispatchPolicy {
        critical_through: Some(1),
        moves: false,
        ..Default::default()
    };
    let d = o.next_transport_record_with_policy(0, policy).unwrap();
    assert_eq!(
        Record::decode(d.message.lane, &d.message.payload)
            .unwrap()
            .sequence,
        1
    );
    o.transport_admission(d.record_token, galaxybridge_quic::Admission::Accepted, 0)
        .unwrap();
    let d = o.next_transport_record_with_policy(1, policy).unwrap();
    assert_eq!(
        Record::decode(d.message.lane, &d.message.payload)
            .unwrap()
            .kind,
        1,
        "fenced successor must not displace metadata"
    );
    o.transport_admission(d.record_token, galaxybridge_quic::Admission::Accepted, 1)
        .unwrap();
    assert!(o.next_transport_record_with_policy(2, policy).is_none());
    assert_eq!(o.tick(500 * MS), Err(Failure::Deadline));
}

#[test]
fn backend_seam_source_observes_complete_records_and_original_start() {
    use galaxybridge_quic_media::{stock::Admission, Owner};
    let mut o = Owner::new(context(), 0).unwrap();
    assert_eq!(
        o.ingest_stock_observed(2, &[0, 97], 10).unwrap(),
        (2, Admission::Incomplete, None)
    );
    let (_, _, p) = o.ingest_stock_observed(2, &[97, 99], 20).unwrap();
    let p = p.expect("complete codec must publish identity");
    assert_eq!((p.kind, p.track, p.started), (2, 2, 10));
    let config = [64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0x11, 0x90];
    for (n, expected) in [(30, 1), (40, 2)] {
        let p = o.ingest_stock_observed(2, &config, n).unwrap().2.unwrap();
        assert_eq!((p.kind, p.epoch, p.config), (4, 1, expected));
    }
}

#[test]
fn backend_copy_overlap_version_rollback_and_future_config_allocation() {
    use galaxybridge_quic_media::Failure;
    for release_before in [false, true] {
        let mut r = receiver_configured();
        r.ingest(video_au(1, true), 0).unwrap();
        let lease = r.next_output(0).unwrap().unwrap();
        let before = r.usage();
        let copy = r.reserve_output_copy(&lease, 0).unwrap();
        let charged = r.usage();
        assert_eq!(
            charged.0,
            (before.0 .0 + 1, before.0 .1 + lease.bytes.len())
        );
        assert_eq!(
            charged.1,
            (
                before.1 .0 + 1,
                before.1 .1 + lease.configuration.as_ref().unwrap().len()
            )
        );
        assert!(matches!(
            r.reserve_output_copy(&lease, 0),
            Err(Failure::Capacity)
        ));
        assert_eq!(
            r.usage(),
            charged,
            "failed config reservation rolls back the already-reserved AU part"
        );
        r.consumer_commit(&lease, 0).unwrap();
        r.release_output(&lease, 0).unwrap();
        drop(lease);
        let mut next = metadata(4, h264_config());
        next.config = 2;
        next.sequence = 2;
        if release_before {
            drop(copy);
            r.ingest(next, 0).unwrap();
            drop(commit_next(&mut r, 0));
            r.retire(Failure::Retired);
            assert_eq!(r.usage(), ((0, 0), (0, 0)));
        } else {
            assert_eq!(
                r.ingest(next, 0),
                Err(Failure::Capacity),
                "retained copy is the second config version reference"
            );
            assert_eq!(r.usage().1, (1, h264_config().len()));
            assert!(
                r.usage().0 .1 > 0,
                "retirement must not release the actual foreign allocation"
            );
            drop(copy);
            assert_eq!(r.usage(), ((0, 0), (0, 0)));
        }
    }
}

#[test]
fn native_payload_copy_pins_real_versions_and_same_pool_capacity() {
    use galaxybridge_quic_media::Failure;
    let mut r = receiver_configured();
    r.ingest(video_au(1, true), 0).unwrap();
    let lease = r.next_output(0).unwrap().unwrap();
    let original = r.usage();
    let copy = r.reserve_output_payload_copy(&lease, 0).unwrap();
    assert_eq!(
        r.usage().0,
        (original.0 .0, original.0 .1 + lease.bytes.len()),
        "payload-only copies do not consume original AU admission slots"
    );
    assert_eq!(
        r.usage().1,
        original.1,
        "attached config is pinned, not copied"
    );
    r.consumer_commit(&lease, 0).unwrap();
    r.release_output(&lease, 0).unwrap();
    drop(lease);
    let mut second = metadata(4, h264_config());
    second.config = 2;
    second.sequence = 2;
    r.ingest(second, 0).unwrap();
    let config = r.next_output(0).unwrap().unwrap();
    let before = r.usage();
    let config_copy = r.reserve_output_payload_copy(&config, 0).unwrap();
    assert_eq!(
        r.usage().1,
        (before.1 .0 + 1, before.1 .1 + config.bytes.len())
    );
    r.consumer_commit(&config, 0).unwrap();
    r.release_output(&config, 0).unwrap();
    drop(config);
    let mut third = metadata(4, h264_config());
    third.config = 3;
    third.sequence = 2;
    assert_eq!(
        r.ingest(third, 0),
        Err(Failure::Capacity),
        "two REAL versions remain pinned"
    );
    assert!(r.usage().0 .1 > 0 && r.usage().1 .1 > 0);
    drop(copy);
    drop(config_copy);
    assert_eq!(r.usage(), ((0, 0), (0, 0)));

    let mut r = receiver_configured();
    r.ingest(video_au(1, true), 0).unwrap();
    let lease = r.next_output(0).unwrap().unwrap();
    let mut copies = Vec::new();
    for _ in 0..8 {
        copies.push(r.reserve_output_payload_copy(&lease, 0).unwrap());
    }
    assert_eq!(r.usage().0, (1, 9 * lease.bytes.len()));
    assert!(matches!(
        r.reserve_output_payload_copy(&lease, 0),
        Err(Failure::Capacity)
    ));
    r.retire(Failure::Retired);
    drop(lease);
    assert_eq!(
        r.usage().0 .0,
        0,
        "final original ownership is gone; actual copy charges remain"
    );
    assert!(r.usage().0 .1 > 0);
    drop(copies);
    assert_eq!(r.usage(), ((0, 0), (0, 0)));
}

#[test]
fn payload_copy_allowance_keeps_original_slots_composite_and_aggregate_bytes_bounded() {
    use galaxybridge_quic_media::Failure;
    let mut r = receiver_configured();
    let mut copies = Vec::new();
    for sequence in 1..=8 {
        r.ingest(video_au(sequence, true), 0).unwrap();
        let lease = r.next_output(0).unwrap().unwrap();
        copies.push(r.reserve_output_payload_copy(&lease, 0).unwrap());
        r.consumer_commit(&lease, 0).unwrap();
        r.release_output(&lease, 0).unwrap();
    }
    assert_eq!(
        r.usage().0 .0,
        0,
        "event release destroys originals independently of live copies"
    );
    let mut originals = Vec::new();
    for sequence in 9..=16 {
        r.ingest(video_au(sequence, true), 0).unwrap();
        let lease = r.next_output(0).unwrap().unwrap();
        assert!(
            matches!(
                r.reserve_output_payload_copy(&lease, 0),
                Err(Failure::Capacity)
            ),
            "eight copies still reject ninth"
        );
        r.consumer_commit(&lease, 0).unwrap();
        r.release_output(&lease, 0).unwrap();
        originals.push(lease);
    }
    assert_eq!(
        r.ingest_classified(video_au(17, true), 0),
        Ok(galaxybridge_quic_media::media::MediaOutcome::DeclinedPressure),
        "copies do not enlarge eight original admission slots"
    );
    assert_eq!(r.terminal(), None);
    assert_eq!(r.usage().0 .0, 8);
    std::thread::spawn(move || drop(copies)).join().unwrap();
    assert_eq!(
        r.usage().0 .0,
        8,
        "live original buffers retain their own charge"
    );
    drop(originals);
    r.retire(Failure::Retired);
    assert_eq!(r.usage(), ((0, 0), (0, 0)));

    let mut r = receiver_configured();
    r.ingest(video_au(1, true), 0).unwrap();
    let lease = r.next_output(0).unwrap().unwrap();
    let composite = r.reserve_output_copy(&lease, 0).unwrap();
    let before = r.usage();
    let mut copies = Vec::new();
    for _ in 0..8 {
        copies.push(r.reserve_output_payload_copy(&lease, 0).unwrap());
    }
    assert_eq!(r.usage().0 .0, before.0 .0);
    assert_eq!(r.usage().0 .1, before.0 .1 + 8 * lease.bytes.len());
    let full = r.usage();
    assert!(matches!(
        r.reserve_output_payload_copy(&lease, 0),
        Err(Failure::Capacity)
    ));
    assert!(matches!(
        r.reserve_output_copy(&lease, 0),
        Err(Failure::Capacity)
    ));
    assert_eq!(
        r.usage(),
        full,
        "both failed reservations roll back without affecting live tickets"
    );
    r.retire(Failure::Retired);
    drop(lease);
    drop(composite);
    drop(copies);
    assert_eq!(r.usage(), ((0, 0), (0, 0)));

    let mut r = receiver_configured();
    let mut original = video_au(1, true);
    original.body.resize(4 * 1024 * 1024, 0x55);
    for (index, fragment) in original.body.chunks(960).enumerate() {
        let mut packet = original.with_body(fragment.to_vec());
        packet.total = original.body.len() as u32;
        packet.count = original.body.len().div_ceil(960) as u16;
        packet.index = index as u16;
        r.ingest(packet, 0).unwrap();
    }
    let lease = r.next_output(0).unwrap().unwrap();
    let mut copies = Vec::new();
    for _ in 0..3 {
        copies.push(r.reserve_output_payload_copy(&lease, 0).unwrap());
    }
    assert_eq!(r.usage().0, (1, 16 * 1024 * 1024));
    assert!(
        matches!(
            r.reserve_output_payload_copy(&lease, 0),
            Err(Failure::Capacity)
        ),
        "byte limit applies before eight-copy limit"
    );
    assert_eq!(r.usage().0, (1, 16 * 1024 * 1024));
    copies.pop();
    copies.push(r.reserve_output_payload_copy(&lease, 0).unwrap());
    assert_eq!(
        r.usage().0,
        (1, 16 * 1024 * 1024),
        "failed attempt did not leak copy-slot credit"
    );
    r.retire(Failure::Retired);
    drop(lease);
    assert_eq!(r.usage().0, (0, 12 * 1024 * 1024));
    std::thread::spawn(move || drop(copies)).join().unwrap();
    assert_eq!(r.usage(), ((0, 0), (0, 0)));
}

#[test]
fn backend_copy_overlap_metadata_slots_bytes_and_future_shared_sender() {
    use galaxybridge_quic_media::{Failure, Owner};
    let mut o = Owner::new(context(), 0).unwrap();
    o.receiver.ingest(record(1), 0).unwrap();
    o.receiver.ingest(record(2), 0).unwrap();
    let lease = o.receiver.next_output(0).unwrap().unwrap();
    let mut copies = vec![];
    for _ in 0..63 {
        copies.push(o.receiver.reserve_output_copy(&lease, 0).unwrap());
    }
    assert_eq!(o.receiver.usage().1, (64, 256));
    assert!(matches!(
        o.receiver.reserve_output_copy(&lease, 0),
        Err(Failure::Capacity)
    ));
    assert_eq!(o.receiver.usage().1, (64, 256));
    assert_eq!(
        o.transactions.queue_object(record(2), 0),
        Err(Failure::Capacity)
    );
    copies.pop();
    copies.push(o.receiver.reserve_output_copy(&lease, 0).unwrap());
    assert_eq!(o.receiver.usage().1, (64, 256));
    o.retire(Failure::Retired);
    drop(lease);
    assert_eq!(o.receiver.usage().1, (63, 252));
    drop(copies);
    assert_eq!(o.receiver.usage(), ((0, 0), (0, 0)));

    let mut o = Owner::new(context(), 0).unwrap();
    o.receiver.ingest(record(1), 0).unwrap();
    o.receiver.ingest(record(2), 0).unwrap();
    let lease = o.receiver.next_output(0).unwrap().unwrap();
    let copy = o.receiver.reserve_output_copy(&lease, 0).unwrap();
    for (track, version, len) in [(1, 1, 65536), (1, 2, 65536), (2, 1, 65536), (2, 2, 65528)] {
        let mut config = record(4);
        config.track = track;
        config.config = version;
        config.body = vec![0; len];
        o.transactions.queue_object(config, 0).unwrap();
    }
    assert_eq!(o.receiver.usage().1, (6, 262144));
    assert!(matches!(
        o.receiver.reserve_output_copy(&lease, 0),
        Err(Failure::Capacity)
    ));
    assert_eq!(o.receiver.usage().1, (6, 262144));
    assert_eq!(
        o.transactions.queue_object(record(2), 0),
        Err(Failure::Capacity)
    );
    assert_eq!(
        o.receiver.usage().1,
        (6, 262144),
        "retired transactions retain bytes until their result is consumed"
    );
    let mut results = 0;
    while o.transactions.next_transaction_result().is_some() {
        results += 1;
    }
    assert_eq!(results, 4);
    assert_eq!(
        o.receiver.usage().1,
        (2, 8),
        "result consumption cannot release the external copy"
    );
    drop(copy);
    assert_eq!(o.receiver.usage().1, (1, 4));
    o.retire(Failure::Retired);
    drop(lease);
    assert_eq!(o.receiver.usage(), ((0, 0), (0, 0)));
}

#[test]
fn backend_copy_overlap_au_slots_bytes_and_future_receiver_allocation() {
    use galaxybridge_quic_media::Failure;
    for bytes in [32, 4 * 1024 * 1024] {
        let mut r = receiver_configured();
        let mut first = video_au(1, true);
        first.body.resize(bytes, 0x55);
        let count = bytes.div_ceil(960);
        for (index, fragment) in first.body.chunks(960).enumerate() {
            let mut packet = first.with_body(fragment.to_vec());
            packet.total = bytes as u32;
            packet.count = count as u16;
            packet.index = index as u16;
            packet.body = fragment.to_vec();
            r.ingest(packet, 0).unwrap();
        }
        let lease = r.next_output(0).unwrap().unwrap();
        let copy = r.reserve_output_copy(&lease, 0).unwrap();
        r.consumer_commit(&lease, 0).unwrap();
        // These are actual future reassembly allocations, not cloned Bytes
        // or a separately enlarged accounting pool.
        let extra = if bytes == 32 { 6 } else { 2 };
        for seq in 2..=extra + 1 {
            let mut packet = video_au(seq, false);
            packet.total = bytes as u32;
            packet.count = count as u16;
            packet.body = vec![0x55; bytes.min(960)];
            r.ingest(packet, 0).unwrap();
        }
        assert_eq!(
            r.usage().0,
            ((extra + 2) as usize, (extra + 2) as usize * bytes)
        );
        let mut next = video_au(extra + 2, false);
        next.total = bytes as u32;
        next.count = count as u16;
        next.body = vec![0x55; bytes.min(960)];
        assert_eq!(
            r.ingest_classified(next, 0),
            Ok(galaxybridge_quic_media::media::MediaOutcome::DeclinedPressure)
        );
        assert_eq!(r.usage().0,(2,2*bytes),"only obsolete unadmitted reassembly is dropped; committed original and composite stay charged");
        assert_eq!(r.terminal(), None);
        r.release_output(&lease, 0).unwrap();
        drop(lease);
        assert_eq!(r.usage().0, (1, bytes));
        drop(copy);
        r.retire(Failure::Retired);
        assert_eq!(r.usage(), ((0, 0), (0, 0)));
    }
}

#[test]
fn backend_seam_foreign_copy_is_charged_through_retirement() {
    let mut r = receiver_configured();
    r.ingest(video_au(1, true), 0).unwrap();
    let lease = r.next_output(0).unwrap().unwrap();
    let original = r.usage();
    let charge = r
        .reserve_output_copy(&lease, 0)
        .expect("valid output copy reservation");
    assert_eq!(
        r.usage().0,
        (original.0 .0 + 1, original.0 .1 + lease.bytes.len())
    );
    r.retire(galaxybridge_quic_media::Failure::Retired);
    drop(lease);
    assert!(
        r.usage().0 .1 > 0,
        "foreign copy remains real retained storage"
    );
    drop(charge);
    assert_eq!(r.usage(), ((0, 0), (0, 0)));
}

#[test]
fn backend_seam_recovery_context_matches_only_current_episode() {
    use galaxybridge_quic_media::MS;
    let mut r = receiver_configured();
    r.ingest(video_au(1, true), 0).unwrap();
    commit_next(&mut r, 0);
    r.ingest(video_au(3, false), MS).unwrap();
    r.tick(121 * MS).unwrap();
    let d = r.disposition().unwrap();
    let c = r
        .recovery_context(d)
        .expect("current config must be observable");
    assert_eq!((c.track, c.epoch, c.config, c.sequence), (1, 1, 1, 2));
    r.retire(galaxybridge_quic_media::Failure::Retired);
    assert!(r.recovery_context(d).is_err());
}

// Independently specified wire bytes, not output from the codec under test.
fn literal(kind: u8) -> (Lane, Vec<u8>) {
    let mut h = [0u8; 64];
    h[..4].copy_from_slice(b"GQM1");
    h[4] = kind;
    h[15] = 1;
    let body: Vec<u8> = match kind {
        1 => {
            let mut b = vec![0; 20];
            b[3] = 1;
            b[5] = 7;
            b[19] = 9;
            b
        }
        2 => b"h264".to_vec(),
        3 => vec![0, 0, 0, 64, 0, 0, 0, 64, 0, 0, 0, 0],
        4 => vec![0, 0, 0, 1, 0x67],
        5 => vec![0, 0, 0, 1, 0x65],
        6 => vec![3],
        8 => {
            let mut b = vec![0; 37];
            b[0] = 9;
            b[35] = 1;
            b[36] = 17;
            b
        }
        9 => {
            let mut b = vec![0; 29];
            b[7] = 1;
            b[15] = 1;
            b[23] = 1;
            b[27] = 1;
            b[28] = 2;
            b
        }
        11 => vec![0, 1, 0, 0],
        12 => vec![0; 4],
        14 => vec![4, 0, 0, 0],
        _ => vec![],
    };
    if matches!(kind,2..=7|12..=14) {
        h[5] = 1;
    }
    if matches!(kind,3..=7|8..=10|13..=14) {
        h[19] = 1;
        h[31] = 1;
    }
    if matches!(kind,4..=7|13..=14) {
        h[23] = 1;
    }
    if kind == 5 {
        h[7] = 3;
        h[39] = 42;
    }
    if matches!(kind, 1..=4 | 8 | 12 | 13) {
        h[56..60].copy_from_slice(&[0, 7, 161, 32]);
    }
    if kind == 5 {
        h[56..60].copy_from_slice(&[0, 1, 212, 192]);
    }
    if kind == 9 {
        h[56..60].copy_from_slice(&[0, 0, 156, 64]);
    }
    if !matches!(kind, 6 | 7 | 10 | 13 | 14) {
        h[40..44].copy_from_slice(&(body.len() as u32).to_be_bytes());
        h[47] = 1;
    }
    if kind == 6 {
        h[40..44].copy_from_slice(&[0, 0, 3, 193]);
        h[47] = 2;
    }
    h[48..50].copy_from_slice(&(body.len() as u16).to_be_bytes());
    let mut out = h.to_vec();
    out.extend(body);
    (
        if matches!(kind, 5 | 9 | 13) {
            Lane::Datagram
        } else {
            Lane::Reliable
        },
        out,
    )
}

#[test]
fn literal_all_fourteen_kinds_decode() {
    for kind in 1..=14 {
        let (lane, b) = literal(kind);
        let r = Record::decode(lane, &b).unwrap_or_else(|_| panic!("literal kind {kind}"));
        assert_eq!(r.kind, kind);
    }
}

#[test]
fn delivery_watermark_and_its_ack_are_supersedable_datagrams() {
    let watermark = record(13);
    assert_eq!(watermark.lane(), Lane::Datagram);

    let watermark_ack = ack_for(&watermark);
    assert_eq!(watermark_ack.kind, 14);
    assert_eq!(watermark_ack.body, [13, 0, 0, 0]);
    assert_eq!(watermark_ack.lane(), Lane::Datagram);
    let encoded = watermark_ack.encode().unwrap();
    assert_eq!(
        Record::decode(Lane::Datagram, &encoded).unwrap(),
        watermark_ack
    );
    assert!(Record::decode(Lane::Reliable, &encoded).is_err());

    let metadata_ack = record(14);
    assert_eq!(metadata_ack.body, [4, 0, 0, 0]);
    assert_eq!(metadata_ack.lane(), Lane::Reliable);
}

#[test]
fn xor_parity_wire_is_datagram_only_checked_and_bootstrap_opt_in() {
    use galaxybridge_quic_media::{media::Receiver, Core, Failure, FEATURE_XOR_PARITY};

    let body = vec![0x5a; galaxybridge_quic_media::wire::BODY];
    let mut parity = Record {
        kind: galaxybridge_quic_media::wire::XOR_PARITY_KIND,
        track: 1,
        flags: 2,
        generation: 1,
        epoch: 1,
        config: 1,
        sequence: 1,
        pts: 16_667,
        total: (galaxybridge_quic_media::wire::BODY + 1) as u32,
        index: 0,
        count: 2,
        age_us: 0,
        lifetime_us: 120_000,
        body,
    };
    parity.index = galaxybridge_quic_media::wire::parity_checksum(&parity.body);
    let encoded = parity.encode().unwrap();
    assert_eq!(Record::decode(Lane::Datagram, &encoded).unwrap(), parity);
    assert!(Record::decode(Lane::Reliable, &encoded).is_err());
    let mut corrupt = encoded;
    *corrupt.last_mut().unwrap() ^= 1;
    assert!(Record::decode(Lane::Datagram, &corrupt).is_err());

    let mut negotiated = context();
    negotiated.enabled |= FEATURE_XOR_PARITY;
    assert!(Core::new(negotiated.clone(), 0).is_ok());
    let mut unknown = negotiated.clone();
    unknown.enabled |= 1 << 4;
    assert!(matches!(Core::new(unknown, 0), Err(Failure::Protocol)));

    let mut old = Receiver::new(context()).unwrap();
    old.ingest(record(1), 0).unwrap();
    assert_eq!(old.ingest(parity.clone(), 1), Err(Failure::Unsupported));

    let mut matched = Receiver::new(negotiated).unwrap();
    let mut start = record(1);
    start.body[5] |= FEATURE_XOR_PARITY;
    matched.ingest(start, 0).unwrap();
    assert!(matched.ingest(parity, 1).is_ok());
}

#[test]
fn literal_reserved_lengths_lane_and_missing_exceptions() {
    let (lane, b) = literal(1);
    for n in 0..b.len() {
        assert!(Record::decode(lane, &b[..n]).is_err());
    }
    for at in [0, 50, 51, 60, 61, 62, 63] {
        let mut bad = b.clone();
        bad[at] = 255;
        assert!(Record::decode(lane, &bad).is_err());
    }
    let mut extra = b.clone();
    extra.push(0);
    assert!(Record::decode(lane, &extra).is_err());
    let mut wrong_body_length = b.clone();
    wrong_body_length[48] = 0;
    wrong_body_length[49] = 1;
    assert!(
        Record::decode(lane, &wrong_body_length).is_err(),
        "literal body length must equal actual bytes"
    );
    assert!(Record::decode(Lane::Datagram, &b).is_err());
    let (lane, mut missing) = literal(6);
    missing.truncate(64);
    missing[40..50].fill(0);
    assert!(
        Record::decode(lane, &missing).is_ok(),
        "unknown whole AU request allocates no bitmap"
    );
    missing[47] = 1;
    assert!(Record::decode(lane, &missing).is_err());
}

#[test]
fn incremental_stock_preserves_session_flags_pts_and_exact_payload() {
    use galaxybridge_quic_media::stock::{Event, Reader};
    let bytes = [
        104, 50, 54, 52, 128, 0, 0, 1, 0, 0, 0, 64, 0, 0, 0, 32, 64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        2, 103, 104, 32, 0, 0, 0, 0, 0, 0, 42, 0, 0, 0, 3, 0x65, 0x88, 0x80,
    ];
    let mut reader = Reader::new(true, false);
    let mut events = vec![];
    for b in bytes {
        let (n, e) = reader.push(&[b], 0).unwrap();
        assert_eq!(n, 1);
        if let Some(e) = e {
            events.push(e)
        }
    }
    assert_eq!(
        events,
        vec![
            Event::Codec(*b"h264"),
            Event::VideoSession([128, 0, 0, 1, 0, 0, 0, 64, 0, 0, 0, 32]),
            Event::Configuration(vec![103, 104]),
            Event::Packet {
                pts: 42,
                key: true,
                bytes: vec![0x65, 0x88, 0x80]
            }
        ]
    );
    assert!(reader.eof().is_ok());
}

#[test]
fn incomplete_stock_deadline_and_length_fail_before_allocation() {
    use galaxybridge_quic_media::{stock::Reader, Failure, AU_LIFETIME};
    let mut r = Reader::new(false, false);
    assert!(r.push(&[0, 97, 97, 99], 0).is_ok());
    assert!(r.push(&[0], 0).is_ok());
    assert_eq!(r.push(&[0], AU_LIFETIME), Err(Failure::Deadline));
    let mut r = Reader::new(false, false);
    r.push(&[0, 97, 97, 99], 0).unwrap();
    assert_eq!(
        r.push(&[0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 0, 1], 0),
        Err(Failure::Capacity)
    );
}

fn context() -> galaxybridge_quic_media::Context {
    galaxybridge_quic_media::Context {
        session: [7; 32],
        generation: 1,
        scid: 1,
        capture_kind: 0,
        display_id: 0,
        target_token: 9,
        enabled: 7,
    }
}
fn record(kind: u8) -> Record {
    let (l, b) = literal(kind);
    Record::decode(l, &b).unwrap()
}
fn ack_for(r: &Record) -> Record {
    let mut a = record(14);
    a.track = r.track;
    a.epoch = r.epoch;
    a.config = r.config;
    a.sequence = r.sequence;
    a.body[0] = r.kind;
    a
}

#[test]
fn transaction_acceptance_is_not_completion_and_equality_expires() {
    use galaxybridge_quic::Admission;
    use galaxybridge_quic_media::{Core, Failure, Outcome, TRANSACTION_LIFETIME};
    let mut c = Core::new(context(), 0).unwrap();
    let input = record(1);
    let token = c.queue_transaction(input.clone(), 0).unwrap();
    let d = c.next_transport_record(0).unwrap();
    assert_eq!(d.deadline, TRANSACTION_LIFETIME);
    c.transport_admission(d.record_token, Admission::Accepted, 0)
        .unwrap();
    assert_eq!(
        c.next_transaction_result(),
        None,
        "Accepted or empty transport backlog is not ACK"
    );
    c.ingest_ack(ack_for(&input), TRANSACTION_LIFETIME)
        .unwrap_err();
    assert_eq!(
        c.next_transaction_result().unwrap().outcome,
        Outcome::UnknownRemoteOutcome(Failure::Deadline)
    );
    assert!(c.next_transport_record(TRANSACTION_LIFETIME).is_none());
    assert!(token > 0);
}

#[test]
fn transaction_backpressure_preserves_original_deadline_and_on_time_ack() {
    use galaxybridge_quic::Admission;
    use galaxybridge_quic_media::{Confirmation, Core, Failure, Outcome, TRANSACTION_LIFETIME};
    let mut c = Core::new(context(), 0).unwrap();
    let input = record(1);
    c.queue_transaction(input.clone(), 0).unwrap();
    let d = c.next_transport_record(0).unwrap();
    c.transport_admission(d.record_token, Admission::Backpressured, 10)
        .unwrap();
    c.tick(TRANSACTION_LIFETIME);
    assert_eq!(
        c.next_transaction_result().unwrap().outcome,
        Outcome::NotDispatched(Failure::Deadline)
    );
    let mut c = Core::new(context(), 0).unwrap();
    c.queue_transaction(input.clone(), 0).unwrap();
    let d = c.next_transport_record(0).unwrap();
    c.transport_admission(d.record_token, Admission::Accepted, 0)
        .unwrap();
    c.ingest_ack(ack_for(&input), TRANSACTION_LIFETIME - 1)
        .unwrap();
    assert_eq!(
        c.next_transaction_result().unwrap().outcome,
        Outcome::PeerBoundaryConfirmed(Confirmation::MetadataCommit)
    );
}

#[test]
fn accepted_straddling_cutoff_is_unknown_not_undispatched() {
    use galaxybridge_quic_media::{Core, Failure, Outcome, TRANSACTION_LIFETIME};
    let mut c = Core::new(context(), 0).unwrap();
    c.queue_transaction(record(1), 0).unwrap();
    let d = c
        .next_transport_record(TRANSACTION_LIFETIME - 1000)
        .unwrap();
    c.transport_admission(
        d.record_token,
        galaxybridge_quic::Admission::Accepted,
        TRANSACTION_LIFETIME,
    )
    .unwrap_err();
    assert_eq!(
        c.next_transaction_result().unwrap().outcome,
        Outcome::UnknownRemoteOutcome(Failure::Deadline)
    );
}

#[test]
fn budget_is_held_until_final_lease_reference_not_queue_pop() {
    use galaxybridge_quic_media::media::Pool;
    let p = Pool::new(2, 10);
    let a = p.allocate(vec![1; 6]).unwrap();
    let held = a.clone();
    drop(a);
    assert_eq!(p.usage(), (1, 6));
    assert!(p.allocate(vec![2; 5]).is_err());
    let b = p.allocate(vec![2; 4]).unwrap();
    assert_eq!(p.usage(), (2, 10));
    assert!(p.allocate(vec![]).is_err());
    drop(held);
    assert_eq!(p.usage(), (1, 4));
    drop(b);
    assert_eq!(p.usage(), (0, 0));
}

struct BitFixture(Vec<bool>);
impl BitFixture {
    fn bits(&mut self, n: usize, v: u64) {
        for i in (0..n).rev() {
            self.0.push((v >> i) & 1 != 0)
        }
    }
    fn ue(&mut self, v: u64) {
        let n = 64 - (v + 1).leading_zeros() as usize;
        self.bits(n - 1, 0);
        self.bits(n, v + 1)
    }
    fn finish(mut self) -> Vec<u8> {
        self.0.push(true);
        while self.0.len() % 8 != 0 {
            self.0.push(false)
        }
        self.0
            .chunks(8)
            .map(|b| b.iter().fold(0, |a, b| (a << 1) | u8::from(*b)))
            .collect()
    }
}
fn h264_config() -> Vec<u8> {
    let mut s = BitFixture(vec![]);
    s.bits(8, 66);
    s.bits(8, 0);
    s.bits(8, 30);
    s.ue(0);
    s.ue(0);
    s.ue(0);
    s.ue(0);
    s.ue(1);
    s.bits(1, 0);
    s.ue(3);
    s.ue(1);
    s.bits(1, 1);
    s.bits(1, 1);
    s.bits(1, 0);
    s.bits(1, 0);
    let mut p = BitFixture(vec![]);
    p.ue(0);
    p.ue(0);
    p.bits(1, 0);
    p.bits(1, 0);
    p.ue(0);
    p.ue(0);
    p.ue(0);
    p.bits(1, 0);
    p.bits(2, 0);
    p.ue(0);
    p.ue(0);
    p.ue(0);
    p.bits(1, 1);
    p.bits(1, 0);
    p.bits(1, 0);
    let mut bytes = vec![0, 0, 0, 1, 0x67];
    bytes.extend(s.finish());
    bytes.extend([0, 0, 0, 1, 0x68]);
    bytes.extend(p.finish());
    bytes
}
fn h264_slice(first: u64, pps: u64, idr: bool) -> Vec<u8> {
    let mut s = BitFixture(vec![]);
    s.ue(first);
    s.ue(if idr { 2 } else { 0 });
    s.ue(pps);
    s.bits(4, 0);
    if idr {
        s.ue(0)
    }
    s.bits(4, 0);
    s.bits(8, 0x55);
    let mut b = vec![0, 0, 0, 1, if idr { 0x65 } else { 0x41 }];
    b.extend(s.finish());
    b
}

#[test]
fn codec_checks_every_slice_identity_not_first_nal_or_key_claim() {
    use galaxybridge_quic_media::codec::{Codec, Configuration};
    let c = Configuration::parse(Codec::H264, &h264_config()).unwrap();
    let mut au = h264_slice(0, 0, true);
    au.extend(h264_slice(1, 0, true));
    assert_eq!(c.independent(&au, true), Ok(true));
    let mut wrong = h264_slice(0, 0, true);
    wrong.extend(h264_slice(1, 1, true));
    assert!(c.independent(&wrong, true).is_err());
    assert!(c.independent(&h264_slice(0, 0, false), true).is_err());
    let mut truncated = h264_slice(0, 0, true);
    truncated.extend([0, 0, 0, 1, 0x65]);
    assert!(c.independent(&truncated, true).is_err());
}

fn touch(action: u8) -> Vec<u8> {
    vec![
        2, action, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 10, 0, 0, 0, 12, 0, 64, 0, 32, 255, 255, 0, 0,
        0, 0, 0, 0, 0, 1,
    ]
}
fn critical(class: u8, sequence: u64, raw: Vec<u8>) -> Record {
    let mut r = record(8);
    let mut b = vec![class, 0, 0, 0, 0, 0, 0, 0];
    b.extend(1u64.to_be_bytes());
    b.extend(1u64.to_be_bytes());
    b.extend(1u64.to_be_bytes());
    b.extend((raw.len() as u32).to_be_bytes());
    b.extend(raw);
    r.sequence = sequence;
    r.total = b.len() as u32;
    r.body = b;
    r
}
#[test]
fn typed_stock_class_validation_is_not_arbitrary_critical_bytes() {
    use galaxybridge_quic_media::control::Writer;
    let mut w = Writer::new(1);
    assert!(w.ingest(critical(1, 1, touch(0)), 0).is_ok());
    assert!(Writer::new(1).ingest(critical(1, 1, touch(1)), 0).is_err());
    for class in [0, 10, 255] {
        assert!(Writer::new(1)
            .ingest(critical(class, 1, touch(0)), 0)
            .is_err());
    }
    assert!(Writer::new(1)
        .ingest(critical(9, 1, vec![23; 33]), 0)
        .is_err());
    assert!(Writer::new(1)
        .ingest(critical(9, 1, vec![9; 20]), 0)
        .is_err());
}

#[test]
fn reassembly_is_exact_and_complete_lease_keeps_original_deadline() {
    use galaxybridge_quic_media::{media::Reassembler, AU_LIFETIME};
    let mut r = Reassembler::new();
    let mut first = record(5);
    first.total = 961;
    first.count = 2;
    first.body = vec![4; 960];
    let mut last = first.with_body(vec![5]);
    last.index = 1;
    r.ingest(last.clone(), 0).unwrap();
    assert!(r.take(1, 1, 1).is_none());
    r.ingest(first.clone(), 1).unwrap();
    let complete = r.take(1, 1, 2).unwrap();
    assert_eq!(complete.bytes.len(), 961);
    assert_eq!(complete.bytes.as_slice()[960], 5);
    assert_eq!(complete.deadline, AU_LIFETIME);
    let mut r = Reassembler::new();
    r.ingest(first, 0).unwrap();
    r.ingest(last, AU_LIFETIME - 1).unwrap();
    assert!(r.take(1, 1, AU_LIFETIME).is_none());
}

#[test]
fn partial_control_never_interleaves_and_full_late_write_is_not_cancelled() {
    use galaxybridge_quic_media::{
        control::{WriteOutcome, Writer},
        TRANSACTION_LIFETIME,
    };
    let mut w = Writer::new(1);
    w.ingest(critical(1, 1, touch(0)), 0).unwrap();
    let a = w.next_write(0).unwrap();
    assert_eq!(w.write_result(a.token, 1, 0), Ok(WriteOutcome::Progress));
    assert_eq!(w.applied(), 0);
    assert!(w.pointers().is_empty());
    w.ingest(critical(2, 2, touch(1)), 0).unwrap();
    let tail = w.next_write(1).unwrap();
    assert_eq!(tail.token, a.token);
    assert_eq!(tail.offset, 1);
    assert_eq!(
        w.write_result(tail.token, 31, 1),
        Ok(WriteOutcome::Complete {
            sequence: 1,
            epoch: 1
        })
    );
    let up = w.next_write(2).unwrap();
    assert_ne!(up.token, a.token);
    assert_eq!(
        w.write_result(up.token, 32, TRANSACTION_LIFETIME),
        Ok(WriteOutcome::CompletedWriteAfterCutoff)
    );
    assert!(w.terminal().is_some());
    assert_eq!(w.applied(), 1);
    assert!(w.next_write(TRANSACTION_LIFETIME).is_none());
}

#[test]
fn repair_exact_identity_original_expiry_and_final_reference_budget() {
    use galaxybridge_quic_media::{media::Cache, AU_LIFETIME};
    let mut cache = Cache::new();
    let mut au = record(5);
    au.body = vec![7; 961];
    cache.insert(au, 0).unwrap();
    let (first, deadline, repair) = cache.next(0).unwrap();
    assert!(!repair);
    assert_eq!(deadline, AU_LIFETIME);
    cache.accepted(&first, false).unwrap();
    let (last, _, _) = cache.next(0).unwrap();
    cache.accepted(&last, false).unwrap();
    assert!(cache.next(0).is_none());
    let mut request = record(6);
    request.total = 0;
    request.count = 0;
    request.body.clear();
    cache.request(&request, 1, Some(0)).unwrap();
    let (repaired, deadline, is_repair) = cache.next(2).unwrap();
    assert!(is_repair);
    assert_eq!(repaired.body, first.body);
    assert_eq!(deadline, AU_LIFETIME);
    cache.accepted(&repaired, true).unwrap();
    assert!(cache.next(AU_LIFETIME).is_none());
    assert_eq!(cache.usage(), (0, 0));
}

#[test]
fn repair_without_a_measured_margin_is_refused_not_optimistically_sent() {
    use galaxybridge_quic_media::media::{Cache, Reassembler};
    let mut cache = Cache::new();
    let mut au = record(5);
    au.body = vec![7; 961];
    cache.insert(au, 0).unwrap();
    let (first, _, _) = cache.next(0).unwrap();
    cache.accepted(&first, false).unwrap();
    let (last, _, _) = cache.next(0).unwrap();
    cache.accepted(&last, false).unwrap();
    let mut receiver = Reassembler::new();
    receiver.ingest(last, 0).unwrap();
    let missing = receiver.next_missing(5_000_000).unwrap();
    assert_eq!(missing.body, vec![1]);
    cache.request(&missing, 5_000_000, None).unwrap();
    assert!(cache.next(5_000_000).is_none());
    assert_eq!(cache.unavailable, 1);
    cache.request(&missing, 6_000_000, Some(1_000_000)).unwrap();
    let (repaired, deadline, repair) = cache.next(6_000_000).unwrap();
    assert!(repair);
    assert_eq!(repaired.body, first.body);
    assert_eq!(deadline, 120_000_000);
}

fn metadata(kind: u8, body: Vec<u8>) -> Record {
    let mut r = record(kind);
    r.total = body.len() as u32;
    r.body = body;
    r
}
fn video_au(sequence: u64, idr: bool) -> Record {
    let mut r = metadata(5, h264_slice(0, 0, idr));
    r.sequence = sequence;
    r.pts = sequence * 16667;
    r.flags = if idr { 3 } else { 2 };
    r
}
fn commit_next(
    r: &mut galaxybridge_quic_media::media::Receiver,
    now: u64,
) -> galaxybridge_quic_media::media::OutputLease {
    let lease = r.next_output(now).unwrap().expect("ordered output");
    r.consumer_commit(&lease, now).unwrap();
    r.release_output(&lease, now).unwrap();
    lease
}
fn receiver_start() -> galaxybridge_quic_media::media::Receiver {
    let mut r = galaxybridge_quic_media::media::Receiver::new(context()).unwrap();
    r.ingest(record(1), 0).unwrap();
    r
}
fn receiver_configured() -> galaxybridge_quic_media::media::Receiver {
    let mut r = receiver_start();
    r.ingest(record(2), 0).unwrap();
    commit_next(&mut r, 0);
    r.ingest(metadata(3, vec![128, 0, 0, 1, 0, 0, 0, 64, 0, 0, 0, 32]), 0)
        .unwrap();
    commit_next(&mut r, 0);
    r.ingest(metadata(4, h264_config()), 0).unwrap();
    commit_next(&mut r, 0);
    r
}

fn fix1_receiver(track: u8) -> galaxybridge_quic_media::media::Receiver {
    if track == 1 {
        return receiver_configured();
    }
    let mut r = receiver_start();
    let mut codec = metadata(2, vec![0, 97, 97, 99]);
    codec.track = 2;
    r.ingest(codec, 0).unwrap();
    drop(commit_next(&mut r, 0));
    let mut cfg = metadata(4, vec![0x11, 0x90]);
    cfg.track = 2;
    r.ingest(cfg, 0).unwrap();
    drop(commit_next(&mut r, 0));
    r
}
fn fix1_au(track: u8, epoch: u32, config: u32, sequence: u64, pts: u64) -> Record {
    let mut au = if track == 1 {
        video_au(sequence, true)
    } else {
        metadata(5, vec![1, 2, 3])
    };
    au.track = track;
    au.epoch = epoch;
    au.config = config;
    au.sequence = sequence;
    au.pts = pts;
    if track == 2 {
        au.flags = 2;
    }
    au
}
fn fix1_replace(
    r: &mut galaxybridge_quic_media::media::Receiver,
    track: u8,
    epoch: u32,
    sequence: u64,
    now: u64,
) {
    if epoch == 2 {
        let mut session = metadata(3, vec![128, 0, 0, 1, 0, 0, 0, 64, 0, 0, 0, 32]);
        session.epoch = 2;
        session.sequence = sequence;
        r.ingest(session, now).unwrap();
        drop(commit_next(r, now));
    }
    let mut cfg = metadata(
        4,
        if track == 1 {
            h264_config()
        } else {
            vec![0x11, 0x90]
        },
    );
    cfg.track = track;
    cfg.epoch = epoch;
    cfg.config = 2;
    cfg.sequence = sequence;
    r.ingest(cfg, now).unwrap();
    drop(commit_next(r, now));
}
fn fix1_stale_replacement_case(track: u8, epoch: u32) {
    use galaxybridge_quic_media::MS;
    for action in ["check", "commit", "expiry", "release"] {
        let mut r = fix1_receiver(track);
        r.ingest(fix1_au(track, 1, 1, 1, 2000), 0).unwrap();
        let old = r.next_output(0).unwrap().unwrap();
        let external = old.bytes.clone();
        let external_configuration = old.configuration.as_ref().unwrap().clone();
        fix1_replace(&mut r, track, epoch, 1, MS);
        assert_eq!(
            r.usage().0,
            (1, old.bytes.len()),
            "held external bytes remain charged after replacement"
        );
        match action {
            "check" => assert!(
                r.check_output(&old, 2 * MS).is_err(),
                "superseded AU check must reject"
            ),
            "commit" => assert!(
                r.consumer_commit(&old, 2 * MS).is_err(),
                "superseded AU commit must reject"
            ),
            "release" => assert!(
                r.release_output(&old, 2 * MS).is_err(),
                "uncommitted superseded release cannot ACK"
            ),
            _ => {}
        }
        r.tick(61 * MS).unwrap();
        assert_eq!(r.skipped_video(), 0);
        assert!(
            r.disposition().is_none(),
            "old expiry cannot poison the successor"
        );
        assert!(r.check_output(&old, 61 * MS).is_err());
        assert!(r.consumer_commit(&old, 61 * MS).is_err());
        assert!(r.release_output(&old, 61 * MS).is_err());
        r.ingest(fix1_au(track, epoch, 2, 1, 1000), 61 * MS)
            .unwrap();
        let successor = r
            .next_output(61 * MS)
            .unwrap()
            .expect("successor base AU remains eligible");
        assert_eq!(
            (
                successor.record.kind,
                successor.record.epoch,
                successor.record.config,
                successor.record.sequence,
                successor.record.pts
            ),
            (5, epoch, 2, 1, 1000)
        );
        r.consumer_commit(&successor, 61 * MS).unwrap();
        r.release_output(&successor, 61 * MS).unwrap();
        drop(successor);
        drop(old);
        assert_eq!(r.usage().0, (1, external.len()));
        drop(external);
        assert_eq!(r.usage().0, (0, 0));
        assert_eq!(
            r.usage().1 .1,
            h264_config().len() * 2 * (track == 1) as usize + 4 * (track == 2) as usize
        );
        r.retire(galaxybridge_quic_media::Failure::Retired);
        assert_eq!(
            r.usage().1,
            (1, external_configuration.len()),
            "revoked lease's external config remains charged after owner retirement"
        );
        drop(external_configuration);
        assert_eq!(r.usage().1, (0, 0));
    }
}
#[test]
fn fix1_video_epoch_replacement_revokes_uncommitted_au() {
    fix1_stale_replacement_case(1, 2);
}
#[test]
fn fix1_video_config_replacement_revokes_uncommitted_au() {
    fix1_stale_replacement_case(1, 1);
}
#[test]
fn fix1_audio_config_replacement_revokes_uncommitted_au() {
    fix1_stale_replacement_case(2, 1);
}

fn fix1_pts_case(track: u8, pts: u64, epoch: u32) {
    use galaxybridge_quic_media::{Failure, MS};
    let mut r = fix1_receiver(track);
    r.ingest(fix1_au(track, 1, 1, 1, 1000), 0).unwrap();
    drop(commit_next(&mut r, 0));
    fix1_replace(&mut r, track, epoch, 2, MS);
    r.ingest(fix1_au(track, epoch, 2, 2, pts), 2 * MS).unwrap();
    if epoch == 1 && pts <= 1000 {
        assert!(
            matches!(r.next_output(2 * MS), Err(Failure::Protocol)),
            "same-epoch configuration cannot reset PTS watermark"
        );
        assert_eq!(r.terminal(), Some(Failure::Protocol));
    } else {
        let output = r.next_output(2 * MS).unwrap().unwrap();
        assert_eq!(output.record.pts, pts);
        r.consumer_commit(&output, 2 * MS).unwrap();
        r.release_output(&output, 2 * MS).unwrap();
    }
}
#[test]
fn fix1_video_same_epoch_configuration_rejects_regressing_pts() {
    fix1_pts_case(1, 900, 1);
}
#[test]
fn fix1_video_same_epoch_configuration_rejects_equal_pts() {
    fix1_pts_case(1, 1000, 1);
}
#[test]
fn fix1_audio_same_epoch_configuration_rejects_regressing_pts() {
    fix1_pts_case(2, 900, 1);
}
#[test]
fn fix1_audio_same_epoch_configuration_rejects_equal_pts() {
    fix1_pts_case(2, 1000, 1);
}
#[test]
fn fix1_pts_increasing_and_new_video_epoch_controls() {
    fix1_pts_case(1, 1100, 1);
    fix1_pts_case(2, 1100, 1);
    fix1_pts_case(1, 900, 2);
}

#[test]
fn receiver_datagrams_overtaking_metadata_shed_pressure_without_retiring() {
    use galaxybridge_quic_media::media::MediaOutcome;
    let mut r = receiver_start();
    r.ingest(video_au(1, true), 0).unwrap();
    r.ingest(video_au(2, false), 0).unwrap();
    let bounded_usage = r.usage();

    // Datagram and reliable-stream delivery have no cross-lane order. Keeping
    // only two early AUs is valid; retiring a live authenticated session on
    // the third ordinary datagram is not. Nor may overload grow that budget.
    for sequence in 3..100 {
        assert_eq!(
            r.ingest_classified(video_au(sequence, false), 0),
            Ok(MediaOutcome::DeclinedPressure)
        );
        assert_eq!(r.usage(), bounded_usage);
        assert_eq!(r.terminal(), None);
    }

    r.ingest(record(2), 0).unwrap();
    drop(commit_next(&mut r, 0));
    r.ingest(metadata(3, vec![128, 0, 0, 1, 0, 0, 0, 64, 0, 0, 0, 32]), 0)
        .unwrap();
    drop(commit_next(&mut r, 0));
    r.ingest(metadata(4, h264_config()), 0).unwrap();
    drop(commit_next(&mut r, 0));
    assert_eq!(commit_next(&mut r, 0).record.sequence, 1);
    assert_eq!(commit_next(&mut r, 0).record.sequence, 2);
    // A complete retransmission after configuration is now admissible; the
    // declined datagram must not poison the sequence or recreate the receiver.
    r.ingest(video_au(3, false), 0).unwrap();
    assert_eq!(commit_next(&mut r, 0).record.sequence, 3);
    assert_eq!(r.terminal(), None);
}

#[test]
fn receiver_premetadata_au_survives_ordered_metadata_commit() {
    let mut r = receiver_start();
    r.ingest(video_au(1, true), 0).unwrap();
    assert!(r.next_output(0).unwrap().is_none());
    r.ingest(record(2), 0).unwrap();
    commit_next(&mut r, 0);
    r.ingest(metadata(3, vec![128, 0, 0, 1, 0, 0, 0, 64, 0, 0, 0, 32]), 0)
        .unwrap();
    commit_next(&mut r, 0);
    r.ingest(metadata(4, h264_config()), 0).unwrap();
    commit_next(&mut r, 0);
    let au = commit_next(&mut r, 1);
    assert_eq!(au.record.kind, 5);
    assert_eq!(au.bytes.as_slice(), h264_slice(0, 0, true));
}

#[test]
fn receiver_recovery_republishes_matching_configuration_before_idr() {
    use galaxybridge_quic_media::{media::Disposition, MS};
    let mut r = receiver_configured();
    r.ingest(video_au(1, true), 0).unwrap();
    commit_next(&mut r, 0);
    r.ingest(video_au(3, false), MS).unwrap();
    r.tick(121 * MS).unwrap();
    assert_eq!(
        r.disposition(),
        Some(Disposition::RecoveryRequired {
            track: 1,
            epoch: 1,
            sequence: 2
        })
    );
    r.ingest(video_au(4, true), 122 * MS).unwrap();
    let cfg = commit_next(&mut r, 122 * MS);
    assert_eq!(
        cfg.record.kind, 4,
        "recovery must restore matching native configuration before IDR"
    );
    let au = commit_next(&mut r, 122 * MS);
    assert_eq!(au.record.kind, 5);
    assert_eq!(au.record.sequence, 4);
}

#[test]
fn owner_preserves_read_start_in_cache_and_retires_all_owned_state() {
    use galaxybridge_quic_media::{Owner, AU_LIFETIME, MS};
    let mut owner = Owner::new(context(), 0).unwrap();
    owner
        .queue_access_unit(video_au(1, true), 0, 20 * MS)
        .unwrap();
    let (r, deadline, _) = owner.cache.next(20 * MS).unwrap();
    assert_eq!(deadline, AU_LIFETIME);
    assert_eq!(r.age_us, 20000);
    assert!(owner
        .queue_access_unit(video_au(2, true), 0, AU_LIFETIME)
        .is_err());
}

#[test]
fn incremental_owner_stock_is_not_an_unbounded_complete_event_adapter() {
    use galaxybridge_quic_media::{stock::Admission, Owner};
    let mut o = Owner::new(context(), 0).unwrap();
    assert_eq!(
        o.ingest_stock(2, &[0, 97], 0),
        Ok((2, Admission::Incomplete))
    );
    assert!(matches!(
        o.ingest_stock(2, &[97, 99], 1),
        Ok((2, Admission::Metadata(_)))
    ));
    let config = [64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0x11, 0x90];
    assert!(matches!(
        o.ingest_stock(2, &config, 2),
        Ok((14, Admission::Metadata(_)))
    ));
    let au = [0, 0, 0, 0, 0, 0, 0, 42, 0, 0, 0, 3, 1, 2, 3];
    assert_eq!(
        o.ingest_stock(2, &au, 3),
        Ok((15, Admission::AccessUnit { sequence: 1 }))
    );
    let (r, _, _) = o.cache.next(3).unwrap();
    assert_eq!(r.body, [1, 2, 3]);
    assert_eq!(r.pts, 42);
    assert_eq!(r.sequence, 1);
}

#[test]
fn watermark_successor_coalesces_without_refresh_and_never_overtakes_unconfirmed() {
    use galaxybridge_quic::Admission;
    use galaxybridge_quic_media::{Core, Outcome, MS, TRANSACTION_LIFETIME};
    let mut c = Core::new(context(), 0).unwrap();
    let first = record(13);
    c.queue_watermark(first.clone(), 0).unwrap();
    let d = c.next_transport_record(0).unwrap();
    c.transport_admission(d.record_token, Admission::Accepted, 0)
        .unwrap();
    let mut second = first.clone();
    second.sequence = 2;
    c.queue_watermark(second.clone(), MS).unwrap();
    let mut third = second;
    third.sequence = 3;
    c.queue_watermark(third.clone(), 2 * MS).unwrap();
    assert_eq!(
        c.next_transaction_result().unwrap().outcome,
        Outcome::SupersededBeforeDispatch
    );
    assert!(c.next_transport_record(3 * MS).is_none());
    c.ingest_ack(ack_for(&first), 3 * MS).unwrap();
    assert!(matches!(
        c.next_transaction_result().unwrap().outcome,
        Outcome::PeerBoundaryConfirmed(_)
    ));
    let d = c.next_transport_record(4 * MS).unwrap();
    assert_eq!(d.deadline, MS + TRANSACTION_LIFETIME);
    let sent = Record::decode(d.message.lane, &d.message.payload).unwrap();
    assert_eq!(sent.sequence, 3);
    assert_eq!(sent.age_us, 3000);
}

#[test]
fn accepted_watermark_timeout_is_supersedable_and_late_ack_is_harmless() {
    use galaxybridge_quic::Admission;
    use galaxybridge_quic_media::{Confirmation, Core, Failure, Outcome, TRANSACTION_LIFETIME};
    let mut c = Core::new(context(), 0).unwrap();
    let first = record(13);
    c.queue_watermark(first.clone(), 0).unwrap();
    let dispatch = c.next_transport_record(0).unwrap();
    c.transport_admission(dispatch.record_token, Admission::Accepted, 0)
        .unwrap();

    c.tick(TRANSACTION_LIFETIME);
    assert_eq!(
        c.terminal(),
        None,
        "a lost watermark ACK must not retire the media transport"
    );
    assert_eq!(
        c.next_transaction_result().unwrap().outcome,
        Outcome::UnknownRemoteOutcome(Failure::Deadline)
    );
    c.ingest_ack(ack_for(&first), TRANSACTION_LIFETIME + 1)
        .expect("the matching late watermark ACK must be ignored");

    let mut successor = first;
    successor.sequence = 2;
    c.queue_watermark(successor.clone(), TRANSACTION_LIFETIME + 2)
        .unwrap();
    let dispatch = c.next_transport_record(TRANSACTION_LIFETIME + 2).unwrap();
    c.transport_admission(
        dispatch.record_token,
        Admission::Accepted,
        TRANSACTION_LIFETIME + 2,
    )
    .unwrap();
    c.ingest_ack(ack_for(&successor), TRANSACTION_LIFETIME + 3)
        .unwrap();
    assert_eq!(
        c.next_transaction_result().unwrap().outcome,
        Outcome::PeerBoundaryConfirmed(Confirmation::MetadataCommit)
    );
    assert_eq!(c.terminal(), None);
}

#[test]
fn backpressured_watermark_timeout_is_dropped_without_retiring_live_media() {
    use galaxybridge_quic::Admission;
    use galaxybridge_quic_media::{Confirmation, Core, Failure, Outcome, TRANSACTION_LIFETIME};

    let mut core = Core::new(context(), 0).unwrap();
    let first = record(13);
    core.queue_watermark(first.clone(), 0).unwrap();
    let dispatch = core.next_transport_record(0).unwrap();
    core.transport_admission(dispatch.record_token, Admission::Backpressured, 1)
        .unwrap();

    core.tick(TRANSACTION_LIFETIME);
    assert_eq!(
        core.terminal(),
        None,
        "an unseen progress watermark cannot retire a live media session"
    );
    assert_eq!(
        core.next_transaction_result().unwrap().outcome,
        Outcome::NotDispatched(Failure::Deadline)
    );

    let mut successor = first;
    successor.sequence = 2;
    core.queue_watermark(successor.clone(), TRANSACTION_LIFETIME + 1)
        .unwrap();
    let dispatch = core
        .next_transport_record(TRANSACTION_LIFETIME + 1)
        .unwrap();
    core.transport_admission(
        dispatch.record_token,
        Admission::Accepted,
        TRANSACTION_LIFETIME + 1,
    )
    .unwrap();
    core.ingest_ack(ack_for(&successor), TRANSACTION_LIFETIME + 2)
        .unwrap();
    assert_eq!(
        core.next_transaction_result().unwrap().outcome,
        Outcome::PeerBoundaryConfirmed(Confirmation::MetadataCommit)
    );
    assert_eq!(core.terminal(), None);

    let mut strict = Core::new(context(), 0).unwrap();
    strict.queue_transaction(record(1), 0).unwrap();
    let dispatch = strict.next_transport_record(0).unwrap();
    strict
        .transport_admission(dispatch.record_token, Admission::Backpressured, 1)
        .unwrap();
    strict.tick(TRANSACTION_LIFETIME);
    assert_eq!(
        strict.terminal(),
        Some(Failure::Deadline),
        "only progress watermarks may be discarded before admission"
    );

    let mut unresolved = Core::new(context(), 0).unwrap();
    unresolved.queue_watermark(record(13), 0).unwrap();
    let _dispatch = unresolved.next_transport_record(0).unwrap();
    unresolved.tick(TRANSACTION_LIFETIME);
    assert_eq!(
        unresolved.terminal(),
        Some(Failure::Deadline),
        "a watermark with an outstanding admission callback is still owned"
    );
}

#[test]
fn accepted_periodic_get_clipboard_timeout_does_not_retire_media_or_weaken_input() {
    use galaxybridge_quic::Admission;
    use galaxybridge_quic_media::{
        Confirmation, Core, Failure, Outcome, RELIABLE_CONTROL_ACK_LIFETIME, TRANSACTION_LIFETIME,
    };

    let mut core = Core::new(context(), 0).unwrap();
    let get = critical(9, 1, vec![8, 1]);
    core.queue_transaction(get, 0).unwrap();
    let dispatch = core.next_transport_record(0).unwrap();
    core.transport_admission(dispatch.record_token, Admission::Accepted, 0)
        .unwrap();

    core.tick(TRANSACTION_LIFETIME);
    assert_eq!(
        core.terminal(),
        None,
        "an accepted periodic clipboard observation cannot restart live media"
    );
    assert_eq!(
        core.next_transaction_result().unwrap().outcome,
        Outcome::UnknownRemoteOutcome(Failure::Deadline)
    );
    let mut late = record(10);
    late.sequence = 1;
    core.ingest_ack(late, TRANSACTION_LIFETIME + 1)
        .expect("the late cumulative acknowledgement is below the advanced floor");

    let successor = critical(9, 2, vec![5]);
    core.queue_transaction(successor, TRANSACTION_LIFETIME + 2)
        .unwrap();
    let dispatch = core
        .next_transport_record(TRANSACTION_LIFETIME + 2)
        .unwrap();
    core.transport_admission(
        dispatch.record_token,
        Admission::Accepted,
        TRANSACTION_LIFETIME + 2,
    )
    .unwrap();
    let mut ack = record(10);
    ack.sequence = 2;
    core.ingest_ack(ack, TRANSACTION_LIFETIME + 3).unwrap();
    assert_eq!(
        core.next_transaction_result().unwrap().outcome,
        Outcome::PeerBoundaryConfirmed(Confirmation::StockSinkWrite)
    );

    let mut strict = Core::new(context(), 0).unwrap();
    strict
        .queue_transaction(critical(1, 1, touch(0)), 0)
        .unwrap();
    let dispatch = strict.next_transport_record(0).unwrap();
    strict
        .transport_admission(dispatch.record_token, Admission::Accepted, 0)
        .unwrap();
    strict.tick(TRANSACTION_LIFETIME);
    assert_eq!(strict.terminal(), None);
    strict.tick(RELIABLE_CONTROL_ACK_LIFETIME);
    assert_eq!(strict.terminal(), Some(Failure::Deadline));
}

#[test]
fn accepted_touch_gets_a_longer_ack_budget_without_extending_dispatch_freshness() {
    use galaxybridge_quic::Admission;
    use galaxybridge_quic_media::{
        Confirmation, Core, Failure, Outcome, RELIABLE_CONTROL_ACK_LIFETIME, TRANSACTION_LIFETIME,
    };

    let mut accepted = Core::new(context(), 0).unwrap();
    let down = critical(1, 1, touch(0));
    accepted.queue_transaction(down, 0).unwrap();
    let dispatch = accepted.next_transport_record(0).unwrap();
    assert_eq!(dispatch.deadline, TRANSACTION_LIFETIME);
    accepted
        .transport_admission(dispatch.record_token, Admission::Accepted, 0)
        .unwrap();
    accepted.tick(TRANSACTION_LIFETIME);
    assert_eq!(accepted.terminal(), None);
    let mut ack = record(10);
    ack.sequence = 1;
    accepted.ingest_ack(ack, TRANSACTION_LIFETIME + 1).unwrap();
    assert_eq!(
        accepted.next_transaction_result().unwrap().outcome,
        Outcome::PeerBoundaryConfirmed(Confirmation::StockSinkWrite)
    );

    let mut undispatched = Core::new(context(), 0).unwrap();
    undispatched
        .queue_transaction(critical(1, 1, touch(0)), 0)
        .unwrap();
    undispatched.tick(TRANSACTION_LIFETIME);
    assert_eq!(undispatched.terminal(), Some(Failure::Deadline));

    let mut missing = Core::new(context(), 0).unwrap();
    missing
        .queue_transaction(critical(1, 1, touch(0)), 0)
        .unwrap();
    let dispatch = missing.next_transport_record(0).unwrap();
    missing
        .transport_admission(dispatch.record_token, Admission::Accepted, 0)
        .unwrap();
    missing.tick(RELIABLE_CONTROL_ACK_LIFETIME);
    assert_eq!(missing.terminal(), Some(Failure::Deadline));
}

#[test]
fn first_error_critical_timeout_reports_class_and_raw_type_without_payload() {
    use galaxybridge_quic::Admission;
    use galaxybridge_quic_media::{
        media::first_error, Core, Failure, RELIABLE_CONTROL_ACK_LIFETIME,
    };

    let mut core = Core::new(context(), 0).unwrap();
    core.queue_transaction(critical(9, 1, vec![5]), 0).unwrap();
    let dispatch = core.next_transport_record(0).unwrap();
    core.transport_admission(dispatch.record_token, Admission::Accepted, 0)
        .unwrap();
    let scope = first_error::Scope::begin(true);
    core.tick(RELIABLE_CONTROL_ACK_LIFETIME);
    assert_eq!(core.terminal(), Some(Failure::Deadline));
    let rejection = scope.observation().unwrap().rejection.unwrap();
    assert_eq!(rejection.module, 2);
    assert_eq!(rejection.used, 9, "validated control class");
    assert_eq!(rejection.limit, 5, "raw scrcpy control type");
    assert_eq!(rejection.requested, 1, "critical sequence");
    assert_eq!(rejection.bytes, 37, "bounded body length only");
    assert_eq!(rejection.byte_limit, 3, "accepted and complete bits");
}

#[test]
fn source_timeout_cannot_cancel_unseen_accepted_critical_on_live_peer() {
    use galaxybridge_quic_media::{
        control::Writer, Core, Failure, Outcome, RELIABLE_CONTROL_ACK_LIFETIME,
    };
    let mut source = Core::new(context(), 0).unwrap();
    let command = critical(1, 1, touch(0));
    source.queue_transaction(command, 0).unwrap();
    let dispatched = source.next_transport_record(0).unwrap();
    let delayed = Record::decode(dispatched.message.lane, &dispatched.message.payload).unwrap();
    source
        .transport_admission(
            dispatched.record_token,
            galaxybridge_quic::Admission::Accepted,
            0,
        )
        .unwrap();
    source.tick(RELIABLE_CONTROL_ACK_LIFETIME);
    assert_eq!(
        source.next_transaction_result().unwrap().outcome,
        Outcome::UnknownRemoteOutcome(Failure::Deadline)
    );
    // Distinct receiver-local timeline: no subtraction or original-source freshness claim.
    let mut still_live = Writer::new(1);
    still_live.ingest(delayed.clone(), 0).unwrap();
    let lease = still_live.next_write(1).unwrap();
    still_live.write_result(lease.token, 32, 2).unwrap();
    assert_eq!(still_live.applied(), 1);
    let mut learned_retirement = Writer::new(1);
    learned_retirement.retire(Failure::Retired);
    assert!(learned_retirement.ingest(delayed, 0).is_err());
    assert!(learned_retirement.next_write(0).is_none());
}

#[test]
fn first_gap_cutoff_and_retired_lease_are_exact_owner_local() {
    use galaxybridge_quic_media::{Failure, MS};
    let mut old = receiver_configured();
    old.ingest(video_au(1, true), 0).unwrap();
    let held = old.next_output(0).unwrap().unwrap();
    old.retire(Failure::Retired);
    assert_eq!(old.consumer_commit(&held, 1), Err(Failure::Retired));
    let mut replacement = receiver_configured();
    assert_eq!(replacement.consumer_commit(&held, 1), Err(Failure::Retired));
    assert!(replacement.next_output(1).unwrap().is_none());
    let mut r = receiver_configured();
    r.ingest(video_au(1, true), 0).unwrap();
    commit_next(&mut r, 0);
    r.ingest(video_au(3, false), MS).unwrap();
    r.tick(61 * MS).unwrap();
    r.tick(250 * MS).unwrap();
    assert_eq!(r.tick(251 * MS), Ok(()));
    assert!(r.next_output(251 * MS).unwrap().is_none());
    assert_eq!(r.terminal(), None);
}

#[test]
fn incomplete_current_au_arms_first_gap_cutoff_without_sixty_ms_extension() {
    use galaxybridge_quic_media::MS;
    let mut r = receiver_configured();
    r.ingest(video_au(1, true), 0).unwrap();
    commit_next(&mut r, 0);
    let mut partial = video_au(2, false);
    partial.total = 961;
    partial.count = 2;
    partial.index = 1;
    partial.body = vec![7];
    r.ingest(partial, MS).unwrap();
    r.tick(61 * MS).unwrap();
    assert_eq!(r.tick(251 * MS), Ok(()));
    assert_eq!(r.media_health(1).unwrap().state, 2);
}

#[test]
fn stock_clock_overflow_cannot_remove_incomplete_deadline() {
    use galaxybridge_quic_media::{stock::Reader, Failure};
    let mut r = Reader::new(true, false);
    assert_eq!(r.push(&[104], u64::MAX - 1), Err(Failure::Clock));
    assert_eq!(r.retained(), 0);
}

fn move_record(sequence: u64, barrier: u64) -> Record {
    let mut r = record(9);
    r.sequence = sequence;
    let mut body = vec![0; 28];
    body[7] = 1;
    body[15] = 1;
    body[16..24].copy_from_slice(&barrier.to_be_bytes());
    body[27] = 32;
    body.extend(touch(2));
    r.total = body.len() as u32;
    r.body = body;
    r
}
#[test]
fn source_move_keeps_original_deadline_and_up_seals_unsent_slot() {
    use galaxybridge_quic_media::{control::MoveAdmission, Owner, MS};
    let mut o = Owner::new(context(), 0).unwrap();
    o.receiver.ingest(record(1), 0).unwrap();
    o.receiver.ingest(record(2), 0).unwrap();
    commit_next(&mut o.receiver, 0);
    o.receiver
        .ingest(metadata(3, vec![128, 0, 0, 1, 0, 0, 0, 64, 0, 0, 0, 32]), 0)
        .unwrap();
    commit_next(&mut o.receiver, 0);
    while o.receiver.next_feedback(0).is_some() {
        o.receiver.feedback_accepted();
    }
    let mut down = critical(1, 1, touch(0));
    down.body[24..32].fill(0);
    o.queue_critical(down, 0).unwrap();
    assert_eq!(
        o.replace_move(move_record(1, 1), MS, 2 * MS),
        Ok(MoveAdmission::Queued)
    );
    let down = o.next_transport_record(2 * MS, true).unwrap();
    o.transport_admission(
        down.record_token,
        galaxybridge_quic::Admission::Accepted,
        2 * MS,
    )
    .unwrap();
    let mv = o.next_transport_record(3 * MS, true).unwrap();
    assert_eq!(mv.deadline, 41 * MS);
    o.transport_admission(
        mv.record_token,
        galaxybridge_quic::Admission::Backpressured,
        3 * MS,
    )
    .unwrap();
    let mut up = critical(2, 2, touch(1));
    up.body[31] = 1;
    o.queue_critical(up, 4 * MS).unwrap();
    let up = o.next_transport_record(4 * MS, true).unwrap();
    assert_eq!(
        Record::decode(up.message.lane, &up.message.payload)
            .unwrap()
            .kind,
        8
    );
    o.transport_admission(
        up.record_token,
        galaxybridge_quic::Admission::Accepted,
        4 * MS,
    )
    .unwrap();
    assert!(o.next_transport_record(5 * MS, true).is_none());
    assert_eq!(
        o.replace_move(move_record(2, 2), 5 * MS, 5 * MS),
        Ok(MoveAdmission::Stale)
    );
}

#[test]
fn all_nine_critical_classes_have_independent_literal_stock_vectors() {
    use galaxybridge_quic_media::control::validate;
    let vectors: Vec<(u8, Vec<u8>)> = vec![
        (
            1,
            vec![
                2, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 10, 0, 0, 0, 12, 0, 64, 0, 32, 255, 255, 0,
                0, 0, 0, 0, 0, 0, 1,
            ],
        ),
        (
            2,
            vec![
                2, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 10, 0, 0, 0, 12, 0, 64, 0, 32, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0,
            ],
        ),
        (
            3,
            vec![
                2, 3, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 10, 0, 0, 0, 12, 0, 64, 0, 32, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0,
            ],
        ),
        (4, vec![0, 0, 0, 0, 0, 29, 0, 0, 0, 0, 0, 0, 0, 0]),
        (5, vec![14, 0, 7]),
        (6, vec![21, 0, 64, 0, 32]),
        (7, vec![16, 1, 97]),
        (
            8,
            vec![
                3, 0, 0, 0, 10, 0, 0, 0, 12, 0, 64, 0, 32, 0, 1, 0, 0, 0, 0, 0, 0,
            ],
        ),
        (9, vec![5]),
    ];
    for (class, raw) in vectors {
        assert!(validate(class, &raw).is_ok());
        for wrong in 0..=10 {
            if wrong != class {
                assert!(
                    validate(wrong, &raw).is_err(),
                    "class {wrong} accepted literal class {class}"
                );
            }
        }
    }
}

#[test]
fn get_clipboard_is_priority_control_while_set_clipboard_remains_bulk_only() {
    use galaxybridge_quic_media::control::{validate, Class};

    for copy_key in 0..=2 {
        assert_eq!(validate(9, &[8, copy_key]), Ok(Class::Ordinary));
    }
    assert!(validate(9, &[8, 3]).is_err());
    assert_eq!(
        validate(9, &[9, 0, 0, 0, 0, 0, 0, 0, 1]),
        Err(galaxybridge_quic_media::Failure::Unsupported)
    );
}

#[test]
fn critical_release_reservation_and_retained_results_reach_exact_caps() {
    use galaxybridge_quic_media::{Core, Failure};
    let mut c = Core::new(context(), 0).unwrap();
    for sequence in 1..=48 {
        c.queue_transaction(critical(9, sequence, vec![5]), 0)
            .unwrap();
    }
    assert_eq!(
        c.queue_transaction(critical(9, 49, vec![5]), 0),
        Err(Failure::Capacity)
    );
    for sequence in 49..=64 {
        c.queue_transaction(critical(2, sequence, touch(1)), 0)
            .unwrap();
    }
    assert_eq!(
        c.queue_transaction(critical(2, 65, touch(1)), 0),
        Err(Failure::Capacity)
    );
    assert_eq!(c.terminal(), Some(Failure::Capacity));
    let mut results = 0;
    while c.next_transaction_result().is_some() {
        results += 1;
    }
    assert_eq!(results, 64);
    c.retire(Failure::Retired);
    assert!(c.next_transaction_result().is_none());
    let mut c = Core::new(context(), 0).unwrap();
    for seq in 1..=16 {
        let mut r = record(13);
        r.sequence = seq;
        c.queue_object(r, 0).unwrap();
    }
    let mut seventeenth = record(13);
    seventeenth.sequence = 17;
    assert_eq!(c.queue_object(seventeenth, 0), Err(Failure::Capacity));
    let mut results = 0;
    while c.next_transaction_result().is_some() {
        results += 1;
    }
    assert_eq!(results, 16);
}

#[test]
fn receiver_au_slots_and_bytes_include_final_external_clones() {
    use galaxybridge_quic_media::{media::Reassembler, Failure};
    let mut r = Reassembler::new();
    let mut held = vec![];
    for seq in 1..=8 {
        let mut au = record(5);
        au.sequence = seq;
        r.ingest(au, 0).unwrap();
        held.push(r.take(1, seq, 0).unwrap().bytes);
    }
    let mut ninth = record(5);
    ninth.sequence = 9;
    assert_eq!(r.ingest(ninth.clone(), 0), Err(Failure::Capacity));
    let clone = held[0].clone();
    held.remove(0);
    assert_eq!(r.ingest(ninth.clone(), 0), Err(Failure::Capacity));
    drop(clone);
    r.ingest(ninth, 0).unwrap();
    r.clear();
    drop(held);
    assert_eq!(r.usage(), (0, 0));
    let mut r = Reassembler::new();
    for seq in 1..=4 {
        let mut au = record(5);
        au.sequence = seq;
        au.total = 4 * 1024 * 1024;
        au.count = 4370;
        au.body = vec![1; 960];
        r.ingest(au, 0).unwrap();
    }
    assert_eq!(r.usage(), (4, 16 * 1024 * 1024));
    let mut fifth = record(5);
    fifth.sequence = 5;
    assert_eq!(r.ingest(fifth, 0), Err(Failure::Capacity));
    r.clear();
    assert_eq!(r.usage(), (0, 0));
}

#[test]
fn receiver_key_capacity_is_checked_before_any_sixty_fifth_external_write() {
    use galaxybridge_quic_media::{control::Writer, Failure};
    let mut w = Writer::new(1);
    for seq in 1..=64 {
        let mut raw = vec![0; 14];
        raw[5] = seq as u8;
        w.ingest(critical(4, seq, raw), 0).unwrap();
        let l = w.next_write(0).unwrap();
        w.write_result(l.token, 14, 0).unwrap();
    }
    let mut raw = vec![0; 14];
    raw[5] = 65;
    assert_eq!(w.ingest(critical(4, 65, raw), 0), Err(Failure::Capacity));
    assert!(w.next_write(0).is_none());
    assert_eq!(w.written, 64 * 14);
}

#[test]
fn disabled_track_cannot_be_reenabled_by_later_codec_metadata() {
    let mut r = receiver_start();
    r.ingest(record(12), 0).unwrap();
    commit_next(&mut r, 0);
    assert!(r.ingest(record(2), 0).is_err());
}

#[test]
fn control_coordinates_match_committed_video_geometry_not_just_positive_sizes() {
    let mut r = receiver_configured();
    let mut down = critical(1, 1, touch(0));
    down.body[36 + 19] = 63;
    assert!(
        r.ingest(down, 0).is_err(),
        "raw coordinate geometry63x32 cannot enter bound64x32 sink"
    );
}

#[test]
fn remaining_advertised_age_can_shorten_but_never_extend_gap_residence() {
    use galaxybridge_quic_media::{media::Reassembler, MS};
    let mut r = Reassembler::new();
    let mut gap = record(5);
    gap.total = 0;
    gap.count = 0;
    gap.body.clear();
    r.expect_gap(gap, 0).unwrap();
    let mut fragment = record(5);
    fragment.age_us = 119000;
    r.ingest(fragment, MS).unwrap();
    assert_eq!(r.deadline(1, 1), Some(2 * MS));
    assert!(r.take(1, 1, 2 * MS).is_none());
}

#[test]
fn initial_video_binding_does_not_hide_later_owned_pointer_cancellation() {
    use galaxybridge_quic_media::Failure;
    let mut r = receiver_configured();
    r.ingest(critical(1, 1, touch(0)), 0).unwrap();
    let l = r.control.next_write(0).unwrap();
    r.control_write_result(l.token, 32, 0).unwrap();
    r.retire(Failure::Retired);
    let (pointers, _, _) = r.control.cancellation().unwrap();
    assert_eq!(pointers.len(), 1);
    assert_eq!(pointers[0].pointer, 1);
    r.retire(Failure::Retired);
    assert!(r.control.cancellation().is_none());
}

fn initial_uhid(sequence: u64) -> Record {
    let mut r = critical(5, sequence, vec![12, 0, 7, 0, 0, 0, 0, 0, 0, 1, 0]);
    r.body[8..32].fill(0);
    r
}

#[test]
fn first_geometry_preserves_complete_and_partial_initial_uhid_and_deadline() {
    use galaxybridge_quic_media::{control::WriteOutcome, MS, TRANSACTION_LIFETIME};
    for count in [11, 3] {
        let mut r = receiver_start();
        r.ingest(record(2), 0).unwrap();
        drop(commit_next(&mut r, 0));
        r.ingest(initial_uhid(1), MS).unwrap();
        let first = r.control.next_write(MS).unwrap();
        r.control_write_result(first.token, count, MS).unwrap();
        r.ingest(
            metadata(3, vec![128, 0, 0, 1, 0, 0, 0, 64, 0, 0, 0, 32]),
            2 * MS,
        )
        .unwrap();
        drop(commit_next(&mut r, 2 * MS));
        assert!(
            r.control.cancellation().is_none(),
            "same epoch initialization cannot cancel initial UHID"
        );
        if count == 3 {
            let tail = r.control.next_write(3 * MS).unwrap();
            assert_eq!(
                (tail.token, tail.offset, tail.deadline),
                (first.token, 3, MS + TRANSACTION_LIFETIME)
            );
            assert_eq!(tail.bytes.as_slice(), first.bytes.as_slice());
            assert_eq!(
                r.control_write_result(tail.token, 8, 3 * MS).unwrap(),
                WriteOutcome::Complete {
                    sequence: 1,
                    epoch: 1
                }
            );
        }
        assert_eq!(r.control.applied(), 1);
        let mut input = critical(5, 2, vec![13, 0, 7, 0, 1, 9]);
        input.body[8..32].fill(0);
        r.ingest(input, 4 * MS).unwrap();
        let next = r.control.next_write(4 * MS).unwrap();
        r.control_write_result(next.token, 6, 4 * MS).unwrap();
        assert_eq!(r.control.applied(), 2);
        r.retire(galaxybridge_quic_media::Failure::Retired);
        assert_eq!(
            r.control.cancellation().unwrap().2,
            [7],
            "ownership survived first geometry"
        );
    }
}

#[test]
fn first_geometry_does_not_admit_unknown_positional_coordinates() {
    let mut r = receiver_start();
    assert!(r.ingest(critical(1, 1, touch(0)), 0).is_err());
    assert!(r.control.next_write(0).is_none());
}

#[test]
fn different_geometry_epoch_fails_owned_control_explicitly_and_preserves_partial_write() {
    use galaxybridge_quic_media::{control::WriteOutcome, Failure, MS};
    for already_bound in [false, true] {
        for count in [11, 3] {
            let mut r = if already_bound {
                receiver_configured()
            } else {
                let mut r = receiver_start();
                r.ingest(record(2), 0).unwrap();
                drop(commit_next(&mut r, 0));
                r
            };
            r.ingest(initial_uhid(1), MS).unwrap();
            let original = r.control.next_write(MS).unwrap();
            r.control_write_result(original.token, count, MS).unwrap();
            let mut session = metadata(3, vec![128, 0, 0, 1, 0, 0, 0, 64, 0, 0, 0, 32]);
            session.epoch = 2;
            if !already_bound {
                r.ingest(session, 2 * MS).unwrap();
                assert!(
                    matches!(r.next_output(2 * MS), Err(Failure::Protocol)),
                    "different first wire epoch cannot publish as initialization"
                );
                continue;
            }
            r.ingest(session, 2 * MS).unwrap();
            let lease = r.next_output(2 * MS).unwrap().unwrap();
            if count == 11 {
                r.consumer_commit(&lease, 2 * MS).unwrap();
                assert!(
                    r.control.cancellation().is_none(),
                    "clean epoch preserves live UHID"
                );
                let mut input = critical(5, 2, vec![13, 0, 7, 0, 1, 9]);
                input.body[8..32].fill(0);
                input.epoch = 2;
                r.ingest(input, 3 * MS).unwrap();
                let input = r.control.next_write(3 * MS).unwrap();
                r.control_write_result(input.token, 6, 3 * MS).unwrap();
                r.retire(Failure::Retired);
                assert_eq!(r.control.cancellation().unwrap().2, [7]);
                continue;
            }
            assert_eq!(r.consumer_commit(&lease, 2 * MS), Err(Failure::Sink));
            assert_eq!(
                r.terminal(),
                Some(Failure::Sink),
                "never a ready-but-inert receiver"
            );
            assert_eq!(r.control.cancellation().unwrap().2, [7]);
            assert!(r.control.next_write(3 * MS).is_none());
            if count == 3 {
                assert_eq!(
                    original.bytes.as_slice(),
                    &[12, 0, 7, 0, 0, 0, 0, 0, 0, 1, 0]
                );
                assert_eq!(
                    r.control.write_result(original.token, 8, 3 * MS),
                    Ok(WriteOutcome::CompletedWriteAfterCutoff)
                );
                assert_eq!(
                    r.control.applied(),
                    0,
                    "late tail settlement is not applied"
                );
                assert_eq!(r.control.written, 11);
                assert_eq!(r.control.late_written, 8);
            }
            assert_eq!(r.ingest(initial_uhid(2), 3 * MS), Err(Failure::Sink));
        }
    }
}

#[test]
fn actual_geometry_epoch_with_owned_pointer_retires_without_interleaved_tail() {
    use galaxybridge_quic_media::{Failure, MS};
    for count in [32, 1] {
        let mut r = receiver_configured();
        r.ingest(critical(1, 1, touch(0)), MS).unwrap();
        let write = r.control.next_write(MS).unwrap();
        r.control_write_result(write.token, count, MS).unwrap();
        let mut session = metadata(3, vec![128, 0, 0, 1, 0, 0, 0, 64, 0, 0, 0, 32]);
        session.epoch = 2;
        r.ingest(session, 2 * MS).unwrap();
        let lease = r.next_output(2 * MS).unwrap().unwrap();
        assert_eq!(r.consumer_commit(&lease, 2 * MS), Err(Failure::Sink));
        assert_eq!(r.terminal(), Some(Failure::Sink));
        assert_eq!(r.control.cancellation().unwrap().0[0].pointer, 1);
        assert!(r.control.next_write(3 * MS).is_none());
        assert_eq!(write.bytes.as_slice(), touch(0));
    }
}

#[test]
fn resize_drains_pointer_key_before_successor_with_original_deadline_and_no_extra_ack() {
    use galaxybridge_quic_media::{
        control::{WriteOutcome, Writer},
        MS, TRANSACTION_LIFETIME,
    };
    for expire in [false, true] {
        let mut writer = Writer::new(1);
        let mut key = vec![0; 14];
        key[5] = 29;
        key[13] = 1;
        let mut commands = vec![
            critical(1, 1, touch(0)),
            critical(4, 2, key.clone()),
            initial_uhid(3),
        ];
        commands[1].body[8..32].fill(0);
        for command in commands {
            writer.ingest(command, 0).unwrap();
            let write = writer.next_write(0).unwrap();
            writer
                .write_result(write.token, write.bytes.len(), 0)
                .unwrap();
        }
        let mut resize = critical(6, 4, vec![21, 0, 64, 0, 32]);
        resize.body[8..32].fill(0);
        writer.ingest(resize, MS).unwrap();
        let resize = writer.next_write(MS).unwrap();
        writer.write_result(resize.token, 5, 2 * MS).unwrap();
        let mut input = critical(5, 5, vec![13, 0, 7, 0, 1, 9]);
        input.body[8..32].fill(0);
        writer.ingest(input, 3 * MS).unwrap();
        assert!(writer.draining_geometry());
        let release = writer.next_write(3 * MS).unwrap();
        let mut expected = touch(3);
        expected[22..].fill(0);
        assert_eq!(release.bytes.as_slice(), expected);
        assert_eq!(release.deadline, MS + TRANSACTION_LIFETIME);
        writer.write_result(release.token, 3, 3 * MS).unwrap();
        let tail = writer.next_write(4 * MS).unwrap();
        assert_eq!(
            (tail.token, tail.offset, tail.deadline),
            (release.token, 3, release.deadline)
        );
        if expire {
            assert!(writer.next_write(release.deadline).is_none());
            assert_eq!(
                writer.terminal(),
                Some(galaxybridge_quic_media::Failure::Deadline)
            );
            assert_eq!(writer.applied(), 4);
            assert_eq!(writer.cancellation().unwrap().2, [7]);
            continue;
        }
        assert_eq!(
            writer.write_result(tail.token, 29, 4 * MS),
            Ok(WriteOutcome::MoveComplete)
        );
        assert_eq!(
            writer.applied(),
            4,
            "synthetic release cannot acknowledge a new critical sequence"
        );
        let release = writer.next_write(5 * MS).unwrap();
        key[1] = 1;
        key[6..10].fill(0);
        assert_eq!(release.bytes.as_slice(), key);
        assert_eq!(release.deadline, MS + TRANSACTION_LIFETIME);
        writer.write_result(release.token, 14, 5 * MS).unwrap();
        assert!(!writer.draining_geometry());
        let input = writer.next_write(6 * MS).unwrap();
        assert_eq!(input.bytes.as_slice(), &[13, 0, 7, 0, 1, 9]);
        writer.write_result(input.token, 6, 6 * MS).unwrap();
        writer.retire(galaxybridge_quic_media::Failure::Retired);
        let cancelled = writer.cancellation().unwrap();
        assert!(cancelled.0.is_empty() && cancelled.1.is_empty());
        assert_eq!(
            cancelled.2,
            [7],
            "retirement still owns full live UHID teardown"
        );
    }
}

#[test]
fn skipped_video_counts_missing_chain_range_once_without_unbounded_gap_entries() {
    use galaxybridge_quic_media::MS;
    let mut r = receiver_configured();
    r.ingest(video_au(1, true), 0).unwrap();
    commit_next(&mut r, 0);
    r.ingest(video_au(4, false), MS).unwrap();
    r.tick(121 * MS).unwrap();
    assert!(r.next_output(121 * MS).unwrap().is_none());
    assert_eq!(r.skipped_video(), 3);
    r.ingest(video_au(3, false), 122 * MS).unwrap();
    assert!(r.next_output(122 * MS).unwrap().is_none());
    assert_eq!(r.skipped_video(), 3);
    r.ingest(video_au(5, true), 123 * MS).unwrap();
    commit_next(&mut r, 123 * MS);
    commit_next(&mut r, 123 * MS);
    assert_eq!(r.skipped_video(), 3);
}

fn shared_pointer_id_resize_case(release_first_pair: bool) {
    use galaxybridge_quic_media::{control::WriteOutcome, MS, TRANSACTION_LIFETIME};
    let mut receiver = receiver_configured();
    while receiver.next_feedback(0).is_some() {
        receiver.feedback_accepted();
    }
    let mut frames = [touch(0), touch(0)];
    frames[0][10..14].copy_from_slice(&10u32.to_be_bytes());
    frames[0][14..18].copy_from_slice(&12u32.to_be_bytes());
    frames[1][10..14].copy_from_slice(&31u32.to_be_bytes());
    frames[1][14..18].copy_from_slice(&23u32.to_be_bytes());
    let mut sequence = 0;
    for (index, frame) in frames.iter().enumerate() {
        sequence += 1;
        let mut down = critical(1, sequence, frame.clone());
        down.body[8..16].copy_from_slice(&((index + 1) as u64).to_be_bytes());
        down.body[24..32].fill(0);
        receiver.ingest(down, MS).unwrap();
        let write = receiver.control.next_write(MS).unwrap();
        receiver.control_write_result(write.token, 32, MS).unwrap();
    }
    assert_eq!(
        receiver.control.pointers().len(),
        2,
        "both admitted pairs retain ownership"
    );
    if release_first_pair {
        sequence += 1;
        let mut up_frame = frames[0].clone();
        up_frame[1] = 1;
        let mut up = critical(2, sequence, up_frame);
        up.body[24..32].fill(0);
        receiver.ingest(up, 2 * MS).unwrap();
        let write = receiver.control.next_write(2 * MS).unwrap();
        receiver
            .control_write_result(write.token, 32, 2 * MS)
            .unwrap();
        let owned = receiver.control.pointers();
        assert_eq!(owned.len(), 1);
        assert_eq!((owned[0].gesture, owned[0].pointer), (2, 1));
    }
    sequence += 1;
    let resize_sequence = sequence;
    let mut resize = critical(6, sequence, vec![21, 0, 64, 0, 32]);
    resize.body[8..32].fill(0);
    receiver.ingest(resize, 3 * MS).unwrap();
    let write = receiver.control.next_write(3 * MS).unwrap();
    receiver
        .control_write_result(write.token, 5, 3 * MS)
        .unwrap();
    for original in frames.iter().skip(usize::from(release_first_pair)) {
        let write = receiver
            .control
            .next_write(4 * MS)
            .expect("every remaining admitted pair has its own release template");
        let mut expected = original.clone();
        expected[1] = 3;
        expected[22..].fill(0);
        assert_eq!(
            write.bytes.as_slice(),
            expected,
            "release retains this gesture's distinct original coordinates"
        );
        assert_eq!(write.deadline, 3 * MS + TRANSACTION_LIFETIME);
        assert_eq!(
            receiver.control_write_result(write.token, 32, 4 * MS),
            Ok(WriteOutcome::MoveComplete)
        );
        assert_eq!(receiver.control.applied(), resize_sequence);
    }
    assert!(receiver.control.pointers().is_empty());
    assert!(!receiver.control.draining_geometry());
    assert_eq!(receiver.control.terminal(), None);
    sequence += 1;
    let mut later = critical(9, sequence, vec![5]);
    later.body[8..32].fill(0);
    receiver.ingest(later, 5 * MS).unwrap();
    let write = receiver.control.next_write(5 * MS).unwrap();
    assert_eq!(write.bytes.as_slice(), &[5]);
    receiver
        .control_write_result(write.token, 1, 5 * MS)
        .unwrap();
    let mut acknowledgements = vec![];
    while let Some(record) = receiver.next_feedback(5 * MS) {
        assert_eq!(
            record.kind, 10,
            "only actual Critical writes are acknowledged"
        );
        acknowledgements.push(record.sequence);
        receiver.feedback_accepted();
    }
    assert_eq!(acknowledgements, (1..=sequence).collect::<Vec<_>>());
    assert_eq!(receiver.terminal(), None);
}

#[test]
fn resize_shared_pointer_id_preserves_both_gesture_templates() {
    shared_pointer_id_resize_case(false);
}

#[test]
fn resize_shared_pointer_id_first_pair_up_preserves_second_template() {
    shared_pointer_id_resize_case(true);
}

#[test]
fn fragmented_metadata_partial_ack_and_exact_cutoff_cannot_confirm() {
    use galaxybridge_quic_media::{Core, Failure, Outcome, TRANSACTION_LIFETIME};
    let mut config = record(4);
    config.body = vec![7; 961];
    let mut c = Core::new(context(), 0).unwrap();
    c.queue_object(config.clone(), 0).unwrap();
    let first = c.next_transport_record(0).unwrap();
    c.transport_admission(
        first.record_token,
        galaxybridge_quic::Admission::Accepted,
        0,
    )
    .unwrap();
    assert_eq!(c.ingest_ack(ack_for(&config), 1), Err(Failure::Protocol));
    assert_eq!(
        c.next_transaction_result().unwrap().outcome,
        Outcome::UnknownRemoteOutcome(Failure::Protocol)
    );
    for at in [
        TRANSACTION_LIFETIME - 1,
        TRANSACTION_LIFETIME,
        TRANSACTION_LIFETIME + 1,
    ] {
        let mut c = Core::new(context(), 0).unwrap();
        c.queue_object(config.clone(), 0).unwrap();
        for _ in 0..2 {
            let d = c.next_transport_record(0).unwrap();
            c.transport_admission(d.record_token, galaxybridge_quic::Admission::Accepted, 0)
                .unwrap();
        }
        let result = c.ingest_ack(ack_for(&config), at);
        assert_eq!(result.is_ok(), at < TRANSACTION_LIFETIME);
        let outcome = c.next_transaction_result().unwrap().outcome;
        assert_eq!(
            matches!(outcome, Outcome::PeerBoundaryConfirmed(_)),
            at < TRANSACTION_LIFETIME
        );
    }
}

#[test]
fn two_pointer_byte_sink_move_barrier_up_seal_and_late_partial_are_not_interleaved() {
    use galaxybridge_quic_media::{
        control::{WriteOutcome, Writer},
        Failure, MS,
    };
    let mut w = Writer::new(1);
    w.ingest(move_record(1, 1), 0).unwrap();
    assert!(w.next_write(0).is_none());
    let a = critical(1, 1, touch(0));
    let mut b = critical(1, 2, touch(0));
    b.body[23] = 2;
    b.body[45] = 2;
    w.ingest(a.clone(), 0).unwrap();
    w.ingest(b.clone(), 0).unwrap();
    let expected = [a.body[36..].to_vec(), b.body[36..].to_vec()].concat();
    let mut sink = vec![];
    for _ in 0..64 {
        let l = w.next_write(0).unwrap();
        sink.push(l.bytes.as_slice()[l.offset]);
        w.write_result(l.token, 1, 0).unwrap();
    }
    assert_eq!(sink, expected);
    assert_eq!(w.pointers().len(), 2);
    assert_eq!(w.applied(), 2);
    w.ingest(move_record(1, 3), 0).unwrap();
    assert!(w.next_write(0).is_none());
    w.ingest(move_record(2, 2), 0).unwrap();
    let mut bad_up = critical(2, 3, touch(1));
    bad_up.body[31] = 1;
    assert_eq!(
        w.ingest(bad_up, 0),
        Err(Failure::Protocol),
        "final UP cannot seal below latest MOVE"
    );
    let mut up = critical(2, 3, touch(1));
    up.body[31] = 2;
    w.ingest(up, 0).unwrap();
    let l = w.next_write(0).unwrap();
    assert_eq!(l.bytes.as_slice()[1], 1);
    w.write_result(l.token, 32, 0).unwrap();
    assert_eq!(w.pointers().len(), 1);
    assert_eq!(w.pointers()[0].pointer, 2);
    assert!(w.next_write(0).is_none());
    let mut second_move = move_record(1, 3);
    second_move.body[15] = 2;
    second_move.body[37] = 2;
    w.ingest(second_move, MS).unwrap();
    let l = w.next_write(MS).unwrap();
    w.write_result(l.token, 1, MS).unwrap();
    let mut second_up = critical(2, 4, touch(1));
    second_up.body[23] = 2;
    second_up.body[45] = 2;
    w.ingest(second_up, 2 * MS).unwrap();
    let tail = w.next_write(2 * MS).unwrap();
    assert_eq!(tail.token, l.token);
    assert_eq!(tail.offset, 1);
    assert_eq!(
        w.write_result(tail.token, 31, 41 * MS),
        Ok(WriteOutcome::CompletedWriteAfterCutoff)
    );
    assert_eq!(w.applied(), 3);
    assert!(w.next_write(41 * MS).is_none());
    let cancellation = w.cancellation().unwrap();
    assert_eq!(cancellation.0.len(), 1);
    assert_eq!(cancellation.0[0].pointer, 2);
}

#[test]
fn cumulative_control_ack_cannot_cross_an_unaccepted_command_or_wrong_highest_epoch() {
    use galaxybridge_quic_media::{Core, Failure};
    for wrong_epoch in [false, true] {
        let mut c = Core::new(context(), 0).unwrap();
        c.queue_transaction(critical(9, 1, vec![5]), 0).unwrap();
        c.queue_transaction(critical(9, 2, vec![5]), 0).unwrap();
        let first = c.next_transport_record(0).unwrap();
        c.transport_admission(
            first.record_token,
            galaxybridge_quic::Admission::Accepted,
            0,
        )
        .unwrap();
        if wrong_epoch {
            let second = c.next_transport_record(0).unwrap();
            c.transport_admission(
                second.record_token,
                galaxybridge_quic::Admission::Accepted,
                0,
            )
            .unwrap();
        }
        let mut ack = record(10);
        ack.sequence = 2;
        if wrong_epoch {
            ack.epoch = 2;
        }
        assert_eq!(c.ingest_ack(ack, 0), Err(Failure::Protocol));
    }
}

#[test]
fn bidirectional_request_backpressure_never_blocks_reserved_application_ack_progress() {
    use galaxybridge_quic_media::{Failure, Owner, TRANSACTION_LIFETIME};
    let mut owners = [
        Owner::new(context(), 0).unwrap(),
        Owner::new(context(), 0).unwrap(),
    ];
    for owner in &mut owners {
        owner.queue_start(0).unwrap();
        let pending = owner.next_transport_record(0, true).unwrap();
        owner
            .transport_admission(
                pending.record_token,
                galaxybridge_quic::Admission::Backpressured,
                0,
            )
            .unwrap();
        let start = record(1);
        owner
            .ingest(
                galaxybridge_quic::Received {
                    lane: start.lane(),
                    sequence: 1,
                    payload: start.encode().unwrap(),
                },
                0,
                None,
            )
            .unwrap();
        let feedback = owner.next_transport_record(1, true).unwrap();
        assert_eq!(
            Record::decode(feedback.message.lane, &feedback.message.payload)
                .unwrap()
                .kind,
            14
        );
        owner
            .transport_admission(
                feedback.record_token,
                galaxybridge_quic::Admission::Accepted,
                1,
            )
            .unwrap();
        assert_eq!(owner.next_wakeup(), Some(TRANSACTION_LIFETIME));
        assert_eq!(owner.tick(TRANSACTION_LIFETIME), Err(Failure::Deadline));
    }
}

#[test]
fn configuration_budget_is_shared_across_both_directions_of_one_owner() {
    use galaxybridge_quic_media::{Failure, Owner};
    let mut o = Owner::new(context(), 0).unwrap();
    for track in 1..=2 {
        for version in 1..=2 {
            let mut cfg = record(4);
            cfg.track = track;
            cfg.config = version;
            cfg.body = vec![0; 65536];
            o.transactions.queue_object(cfg, 0).unwrap();
        }
    }
    o.receiver.ingest(record(1), 0).unwrap();
    assert_eq!(
        o.receiver.ingest(record(2), 0),
        Err(Failure::Capacity),
        "inbound metadata cannot create another independent 256KiB allowance"
    );
}

#[test]
fn metadata_ack_literal_fields_are_kind_specific_before_owner_mutation() {
    let (lane, bytes) = literal(14);
    for kind in [1, 2, 3, 4, 12, 13] {
        let mut good = bytes.clone();
        good[64] = kind;
        if matches!(kind, 1 | 2 | 12) {
            good[16..32].fill(0)
        }
        if kind == 1 {
            good[5] = 0
        }
        if kind == 3 {
            good[20..24].fill(0)
        }
        let ack_lane = if kind == 13 { Lane::Datagram } else { lane };
        assert!(Record::decode(ack_lane, &good).is_ok());
        let at = if matches!(kind, 1 | 2 | 12) {
            19
        } else if kind == 3 {
            23
        } else {
            19
        };
        let mut bad = good;
        bad[at] = if matches!(kind, 4 | 13) { 0 } else { 9 };
        assert!(
            Record::decode(ack_lane, &bad).is_err(),
            "ACK kind {kind} irrelevant/required field"
        );
    }
}

#[test]
fn configuration_version_slots_include_unconsumed_sender_results() {
    use galaxybridge_quic_media::{Core, Failure};
    let mut c = Core::new(context(), 0).unwrap();
    for version in 1..=2 {
        let mut r = record(4);
        r.config = version;
        c.queue_object(r.clone(), 0).unwrap();
        let d = c.next_transport_record(0).unwrap();
        c.transport_admission(d.record_token, galaxybridge_quic::Admission::Accepted, 0)
            .unwrap();
        c.ingest_ack(ack_for(&r), 0).unwrap();
    }
    let mut third = record(4);
    third.config = 3;
    assert_eq!(
        c.queue_object(third, 0),
        Err(Failure::Capacity),
        "third retained configuration is not hidden inside the larger byte cap"
    );
}

#[test]
fn first_error_actual_pool_reject_is_exact_and_disabled_is_identical() {
    use galaxybridge_quic_media::media::{first_error, Pool};
    let p = Pool::new(1, 8);
    let _held = p.allocate(vec![0; 3]).unwrap();
    {
        let scope = first_error::Scope::begin(false);
        assert_eq!(
            p.allocate(vec![0; 2]).unwrap_err(),
            galaxybridge_quic_media::Failure::Capacity
        );
        assert!(scope.observation().is_none());
        assert_eq!(p.usage(), (1, 3));
    }
    let scope = first_error::Scope::begin(true);
    assert_eq!(
        p.allocate(vec![0; 2]).unwrap_err(),
        galaxybridge_quic_media::Failure::Capacity
    );
    let r = scope
        .observation()
        .unwrap()
        .rejection
        .expect("actual rejecting pool must identify itself");
    assert_eq!(
        (
            r.module,
            r.used,
            r.limit,
            r.requested,
            r.bytes,
            r.byte_limit
        ),
        (1, 1, 1, 2, 3, 8)
    );
    first_error::error(102);
    first_error::reject(99, 99, 99, 99, 99, 99, 99);
    first_error::error(101);
    assert_eq!(scope.observation().unwrap().rejection, Some(r));
    assert_eq!(scope.observation().unwrap().status, 102);
    assert_eq!(p.usage(), (1, 3));
    {
        let nested = first_error::Scope::begin(true);
        assert!(nested.observation().unwrap().rejection.is_none());
    }
    assert_eq!(scope.observation().unwrap().rejection, Some(r));
}
