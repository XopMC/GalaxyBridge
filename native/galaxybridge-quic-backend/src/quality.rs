//! Sender-local requested bitrate policy. No transport clock or deadline changes.
use crate::{Error, MS};
use galaxybridge_quic::endpoint::Stats;

#[derive(Clone, Copy)]
struct Sample {
    at: u64,
    video: u64,
    admitted: u64,
    queued: u64,
    generated: u64,
}
pub(crate) struct Controller {
    pub target: u32,
    ceiling: u32,
    previous: Option<Sample>,
    streak: u8,
    clean: Option<u64>,
    changed: Option<u64>,
    raised: Option<u64>,
}
impl Controller {
    pub fn ceiling(&self) -> u32 {
        self.ceiling
    }
    #[cfg(any(target_os = "android", test))]
    pub fn new(ceiling: u32) -> Result<Self, Error> {
        if ceiling == 0 || ceiling > i32::MAX as u32 {
            return Err(Error::Protocol);
        }
        Ok(Self {
            target: ceiling,
            ceiling,
            previous: None,
            streak: 0,
            clean: None,
            changed: None,
            raised: None,
        })
    }
    pub fn discontinuity(&mut self) {
        self.previous = None;
        self.streak = 0;
        self.clean = None;
    }
    /// A recovery request accepted from the receiver is direct evidence that
    /// an access unit was lost after it left this sender.  Apply the same
    /// bounded reduction immediately so the replacement keyframe is encoded
    /// below the rate that just failed.
    pub fn receiver_recovery(&mut self, now: u64) -> Option<u32> {
        let floor = 2_000_000.min(self.ceiling);
        let target = (((self.target as u64 * 3) / 4) as u32).max(floor);
        self.previous = None;
        self.streak = 0;
        self.clean = None;
        if target == self.target {
            return None;
        }
        self.target = target;
        self.changed = Some(now);
        Some(target)
    }
    pub fn sample(&mut self, now: u64, video: u64, s: Stats) -> Option<u32> {
        let next = Sample {
            at: now,
            video,
            admitted: s.datagrams_admitted,
            queued: s.pressure.expiry_queued,
            generated: s.pressure.expiry_generated,
        };
        if self
            .previous
            .is_some_and(|p| now >= p.at && now - p.at < 250 * MS)
        {
            return None;
        }
        let previous = self.previous.replace(next);
        let Some(p) = previous else {
            return None;
        };
        // No catch-up or idle credit: a service gap longer than one second is discontinuous.
        let valid = s.authenticated
            && s.application_ready
            && !s.retired
            && s.path.valid
            && s.path.available
            && now > p.at
            && now - p.at <= 1_000 * MS
            && video > p.video
            && s.datagrams_admitted > p.admitted
            && s.pressure.expiry_queued >= p.queued
            && s.pressure.expiry_generated >= p.generated;
        if !valid {
            self.streak = 0;
            self.clean = None;
            return None;
        }
        let admitted = s.datagrams_admitted - p.admitted;
        let queued = s.pressure.expiry_queued - p.queued;
        let generated = s.pressure.expiry_generated - p.generated;
        // Both counters are sender-owned proof that fresh media missed its
        // deadline.  In particular, a datagram can leave the wrapper queue,
        // become an encrypted paced packet, and expire there.  Ignoring that
        // second boundary kept the encoder at an unsustainable rate while the
        // receiver was already losing complete access units.
        let expired = queued.saturating_add(generated);
        let transport_backlog = s.datagram_queue_records.saturating_add(s.generated_packets);
        let overloaded =
            expired > 0 && (expired as u128) * 100 >= admitted as u128 && transport_backlog >= 16;
        self.streak = if overloaded {
            self.streak.saturating_add(1).min(2)
        } else {
            0
        };
        let cooldown = self
            .changed
            .is_none_or(|t| now >= t && now - t >= 2_000 * MS);
        let selected = if self.streak >= 2 && cooldown {
            self.clean = None;
            Some(((self.target as u64 * 3) / 4) as u32).map(|n| n.max(2_000_000.min(self.ceiling)))
        } else if queued == 0 && generated == 0 && s.datagram_queue_records < 8 {
            let since = *self.clean.get_or_insert(p.at);
            if now - since >= 5_000 * MS
                && cooldown
                && self
                    .raised
                    .is_none_or(|t| now >= t && now - t >= 5_000 * MS)
            {
                Some((self.target as u64 + self.target as u64 / 10).min(self.ceiling as u64) as u32)
            } else {
                None
            }
        } else {
            self.clean = None;
            None
        };
        if let Some(target) = selected.filter(|n| *n != self.target) {
            if target > self.target {
                self.raised = Some(now);
            }
            self.target = target;
            self.changed = Some(now);
            self.clean = None;
            self.streak = 0;
            return Some(target);
        }
        None
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Request {
    pub bytes: [u8; 37],
    pub deadline: u64,
    pub target: u32,
}
impl Request {
    pub fn new(
        epoch: u64,
        config: u64,
        id: u64,
        now: u64,
        target: u32,
        ceiling: u32,
    ) -> Result<Self, Error> {
        let deadline = now.checked_add(100 * MS).ok_or(Error::Clock)?;
        if [epoch, config, id, now, deadline]
            .iter()
            .any(|n| *n == 0 || *n > i64::MAX as u64)
            || target == 0
            || target > ceiling
            || ceiling > i32::MAX as u32
        {
            return Err(Error::Protocol);
        }
        let mut bytes = [0; 37];
        bytes[0] = 24;
        for (i, n) in [epoch, config, id, deadline].into_iter().enumerate() {
            bytes[1 + i * 8..9 + i * 8].copy_from_slice(&n.to_be_bytes());
        }
        bytes[33..37].copy_from_slice(&target.to_be_bytes());
        Ok(Self {
            bytes,
            deadline,
            target,
        })
    }
    pub fn current(&self, identity: Option<(u64, u64)>) -> bool {
        identity.is_some_and(|(e, c)| {
            self.bytes[1..9] == e.to_be_bytes() && self.bytes[9..17] == c.to_be_bytes()
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn sample(c: &mut Controller, n: u64, loss: u64, queue: usize) -> Option<u32> {
        let mut s = Stats::default();
        s.authenticated = true;
        s.application_ready = true;
        s.path.valid = true;
        s.path.available = true;
        s.datagrams_admitted = n * 100;
        s.pressure.expiry_queued = loss;
        s.datagram_queue_records = queue;
        c.sample(n * 250 * MS, n, s)
    }
    #[test]
    fn bitrate_two_windows_cooldown_floor_and_clean_recovery() {
        let mut c = Controller::new(20_000_000).unwrap();
        assert_eq!(sample(&mut c, 1, 0, 32), None);
        assert_eq!(sample(&mut c, 2, 1, 32), None);
        assert_eq!(sample(&mut c, 3, 2, 32), Some(15_000_000));
        for n in 4..11 {
            assert_eq!(sample(&mut c, n, n - 1, 32), None);
        }
        assert_eq!(sample(&mut c, 11, 10, 32), Some(11_250_000));
        for n in 12..31 {
            assert_eq!(sample(&mut c, n, 10, 0), None);
        }
        assert_eq!(sample(&mut c, 31, 10, 0), Some(12_375_000));
        for n in 32..51 {
            assert_eq!(sample(&mut c, n, 10, 0), None);
        }
        assert_eq!(sample(&mut c, 51, 10, 0), Some(13_612_500));
        let mut c = Controller::new(1_000_000).unwrap();
        for n in 1..100 {
            assert_eq!(sample(&mut c, n, n, 32), None);
        }
        assert_eq!(c.target, 1_000_000);
        let mut c = Controller::new(2_100_000).unwrap();
        sample(&mut c, 1, 0, 32);
        sample(&mut c, 2, 1, 32);
        assert_eq!(sample(&mut c, 3, 2, 32), Some(2_000_000));
        for n in 4..100 {
            assert_eq!(sample(&mut c, n, n, 32), None);
        }
    }
    #[test]
    fn bitrate_invalid_idle_audio_regression_and_overflow_are_not_load() {
        for mode in 0..6 {
            let mut c = Controller::new(20_000_000).unwrap();
            sample(&mut c, 1, 0, 32);
            sample(&mut c, 2, 1, 32);
            let mut s = Stats::default();
            s.authenticated = true;
            s.application_ready = true;
            s.path.valid = true;
            s.path.available = true;
            s.datagrams_admitted = 300;
            s.pressure.expiry_queued = 2;
            s.datagram_queue_records = 32;
            let mut video = 3;
            let mut at = 750 * MS;
            match mode {
                0 => s.path.valid = false,
                1 => video = 2,
                2 => s.datagrams_admitted = 200,
                3 => s.pressure.expiry_queued = 0,
                4 => at = 1,
                5 => at = 5_000 * MS,
                _ => unreachable!(),
            }
            assert_eq!(c.sample(at, video, s), None);
            assert_eq!(c.streak, 0);
            assert_eq!(c.clean, None);
        }
        let mut c = Controller::new(i32::MAX as u32).unwrap();
        let mut s = Stats::default();
        s.authenticated = true;
        s.application_ready = true;
        s.path.valid = true;
        s.path.available = true;
        c.sample(1, 1, s);
        s.datagrams_admitted = u64::MAX;
        s.pressure.expiry_queued = u64::MAX;
        s.datagram_queue_records = 32;
        assert_eq!(c.sample(250 * MS + 1, 2, s), None);
        assert_eq!(c.streak, 1);
        assert!(Controller::new(0).is_err());
        assert!(Controller::new(u32::MAX).is_err());
    }
    #[test]
    fn bitrate_literal_identity_deadline_and_integer_bounds() {
        let r = Request::new(1, 2, 3, 1, 15_000_000, 20_000_000).unwrap();
        assert_eq!(
            r.bytes,
            [
                24, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0,
                0, 0, 5, 245, 225, 1, 0, 228, 225, 192
            ]
        );
        assert_eq!(r.deadline, 100_000_001);
        assert!(r.current(Some((1, 2))));
        assert!(!r.current(Some((2, 2))));
        assert!(!r.current(None));
        for target in [0, 20_000_001, u32::MAX] {
            assert!(Request::new(1, 2, 3, 1, target, 20_000_000).is_err());
        }
        assert!(Request::new(1, 2, 0, 1, 1, 2).is_err());
        assert!(Request::new(1, 2, 3, u64::MAX, 1, 2).is_err());
    }
    #[test]
    fn bitrate_one_second_gap_boundary_and_generated_expiry_triggers_backoff() {
        let mut c = Controller::new(20_000_000).unwrap();
        sample(&mut c, 1, 0, 32);
        sample(&mut c, 2, 1, 32);
        let mut s = Stats::default();
        s.authenticated = true;
        s.application_ready = true;
        s.path.valid = true;
        s.path.available = true;
        s.datagrams_admitted = 300;
        s.pressure.expiry_queued = 2;
        s.datagram_queue_records = 32;
        assert_eq!(
            c.sample(1_500 * MS, 3, s),
            Some(15_000_000),
            "exact one-second window remains valid"
        );
        s.datagrams_admitted = 400;
        s.pressure.expiry_queued = 2;
        s.datagram_queue_records = 0;
        assert_eq!(c.sample(6_501 * MS, 4, s), None);
        assert_eq!(c.clean, None);
        for n in 1..=2 {
            s.datagrams_admitted += 100;
            s.pressure.expiry_generated += 1;
            s.datagram_queue_records = 0;
            s.generated_packets = 16;
            assert_eq!(
                c.sample(6_501 * MS + n * 250 * MS, 4 + n, s),
                if n == 2 { Some(11_250_000) } else { None }
            );
        }
        assert_eq!(c.target, 11_250_000);
    }
    #[test]
    fn receiver_recovery_is_immediate_congestion_proof_with_a_floor() {
        let mut c = Controller::new(8_000_000).unwrap();
        assert_eq!(c.receiver_recovery(1), Some(6_000_000));
        assert_eq!(c.target, 6_000_000);
        assert_eq!(c.receiver_recovery(2), Some(4_500_000));
        assert_eq!(c.receiver_recovery(3), Some(3_375_000));
        assert_eq!(c.receiver_recovery(4), Some(2_531_250));
        assert_eq!(c.receiver_recovery(5), Some(2_000_000));
        assert_eq!(c.receiver_recovery(6), None);
        assert_eq!(c.target, 2_000_000);
    }
}
