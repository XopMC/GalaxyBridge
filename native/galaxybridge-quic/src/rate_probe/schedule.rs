use super::RateShape;
use crate::Admission;
use std::collections::VecDeque;

pub const BINS: usize = 150;
pub const BITMAP: usize = 3825;
#[derive(Clone, Copy, Debug, Default)]
pub struct Bin {
    pub offered: u64,
    pub admitted: u64,
    pub received: u64,
    pub control: u64,
}
#[derive(Clone, Copy, Debug, Default)]
pub struct ClassCounts {
    pub offered: u64,
    pub first_attempted: u64,
    pub admitted: u64,
    pub overflow: u64,
    pub expired: u64,
    pub rejected: u64,
    pub unfinished: u64,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Quantiles {
    pub samples: u64,
    pub p50_us: u64,
    pub p95_us: u64,
    pub p99_us: u64,
    pub max_us: u64,
}
pub(super) fn quantiles(samples: &mut [u32]) -> Quantiles {
    if samples.is_empty() {
        return Quantiles::default();
    }
    samples.sort_unstable();
    let rank = |p: usize| samples[(samples.len() * p).div_ceil(100) - 1] as u64;
    Quantiles {
        samples: samples.len() as u64,
        p50_us: rank(50),
        p95_us: rank(95),
        p99_us: rank(99),
        max_us: *samples.last().unwrap() as u64,
    }
}
pub(super) fn micros(ns: u64) -> u32 {
    ns.div_ceil(1000).min(u32::MAX as u64) as u32
}
pub(super) fn bin(ns: u64) -> usize {
    (ns / 100_000_000).min((BINS - 1) as u64) as usize
}
pub(super) fn bit(bitmap: &[u8; BITMAP], seq: u64) -> bool {
    seq < 30_600 && bitmap[seq as usize / 8] & (1 << (seq % 8)) != 0
}
pub(super) fn set_bit(bitmap: &mut [u8; BITMAP], seq: u64) {
    bitmap[seq as usize / 8] |= 1 << (seq % 8);
}
impl Slot {
    pub fn useful(self) -> u64 {
        if self.kind == 1 {
            1000
        } else {
            320
        }
    }
}
#[derive(Clone, Copy)]
struct Pending {
    slot: Slot,
    attempted: bool,
}
pub(super) struct Producer {
    shape: RateShape,
    next: [u32; 2],
    pending: VecDeque<Pending>,
    pub counts: [ClassCounts; 2],
    pub bins: [Bin; BINS],
    pub admitted: [u8; BITMAP],
    pub jitter: Vec<u32>,
    pub backpressured: u64,
    pub peak: usize,
}
impl Producer {
    #[cfg(test)]
    pub(super) fn backing_bytes(&self) -> usize {
        self.pending.capacity() * std::mem::size_of::<Pending>()
            + self.jitter.capacity() * std::mem::size_of::<u32>()
    }
    pub fn new(shape: RateShape) -> Self {
        Self {
            shape,
            next: [0; 2],
            pending: VecDeque::with_capacity(128),
            counts: [ClassCounts::default(); 2],
            bins: [Bin::default(); BINS],
            admitted: [0; BITMAP],
            jitter: Vec::with_capacity(30_600),
            backpressured: 0,
            peak: 0,
        }
    }
    pub fn next_due(&self) -> Option<u64> {
        [
            slot(self.shape, 1, self.next[0]),
            slot(self.shape, 2, self.next[1]),
        ]
        .into_iter()
        .flatten()
        .map(|s| s.due_ns)
        .min()
    }
    pub fn pending(&self) -> usize {
        self.pending.len()
    }
    pub fn pending_deadline(&self) -> Option<u64> {
        self.pending.front().map(|p| p.slot.due_ns + 200_000_000)
    }
    pub fn offer(&mut self, now: u64) {
        loop {
            let next = [
                slot(self.shape, 1, self.next[0]),
                slot(self.shape, 2, self.next[1]),
            ]
            .into_iter()
            .flatten()
            .min_by_key(|s| (s.due_ns, s.kind));
            let Some(s) = next else { break };
            if s.due_ns > now {
                break;
            }
            let index = s.kind as usize - 1;
            self.next[index] += 1;
            let counts = &mut self.counts[index];
            counts.offered += 1;
            self.bins[bin(now)].offered += s.useful();
            if now >= s.due_ns + 200_000_000 {
                counts.expired += 1;
            } else if now >= 12_000_000_000 {
                counts.unfinished += 1;
            } else if self.pending.len() == 128 {
                counts.overflow += 1;
            } else {
                self.pending.push_back(Pending {
                    slot: s,
                    attempted: false,
                });
                self.peak = self.peak.max(self.pending.len());
            }
        }
    }
    #[cfg(test)]
    pub fn submit(&mut self, now: u64, send: impl FnMut(Slot, u64) -> Admission) {
        self.submit_timed(now, || now, send);
    }
    pub fn submit_timed(
        &mut self,
        now: u64,
        mut clock: impl FnMut() -> u64,
        mut send: impl FnMut(Slot, u64) -> Admission,
    ) {
        let now = clock().max(now);
        // Even expiry work is bounded by the fixed128-entry FIFO.
        while self
            .pending
            .front()
            .is_some_and(|p| now >= p.slot.due_ns + 200_000_000)
        {
            let p = self.pending.pop_front().unwrap();
            self.counts[p.slot.kind as usize - 1].expired += 1;
        }
        if now >= 12_000_000_000 {
            for p in self.pending.drain(..) {
                self.counts[p.slot.kind as usize - 1].unfinished += 1;
            }
            return;
        }
        for _ in 0..8 {
            let now = clock().max(now);
            let Some(p) = self.pending.front_mut() else {
                break;
            };
            let counts = &mut self.counts[p.slot.kind as usize - 1];
            if now >= p.slot.due_ns + 200_000_000 {
                counts.expired += 1;
                self.pending.pop_front();
                continue;
            }
            if now >= 12_000_000_000 {
                counts.unfinished += 1;
                self.pending.pop_front();
                continue;
            }
            if !p.attempted {
                counts.first_attempted += 1;
                self.jitter.push(micros(now - p.slot.due_ns));
                p.attempted = true;
            }
            match send(p.slot, p.slot.due_ns + 200_000_000) {
                Admission::Accepted => {
                    counts.admitted += 1;
                    set_bit(&mut self.admitted, p.slot.sequence);
                    self.bins[bin(now)].admitted += p.slot.useful();
                }
                Admission::Backpressured => {
                    self.backpressured += 1;
                    break;
                }
                Admission::Expired => counts.expired += 1,
                _ => counts.rejected += 1,
            }
            self.pending.pop_front();
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct Slot {
    pub sequence: u64,
    pub kind: u8,
    pub ordinal: u32,
    pub frame: u32,
    pub due_ns: u64,
}
pub(super) fn slot(shape: RateShape, kind: u8, ordinal: u32) -> Option<Slot> {
    if (kind == 1 && ordinal >= 30_000) || (kind == 2 && ordinal >= 600) || !(1..=2).contains(&kind)
    {
        return None;
    }
    let (frame, due_ns) = if kind == 2 {
        (u32::MAX, ordinal as u64 * 20_000_000)
    } else if shape == RateShape::Constant {
        (u32::MAX, ordinal as u64 * 400_000)
    } else {
        let within = ordinal % 125;
        let frame = ordinal / 125 * 3
            + if within < 41 {
                0
            } else if within < 83 {
                1
            } else {
                2
            };
        (frame, frame as u64 * 1_000_000_000 / 60)
    };
    let other = if kind == 1 {
        due_ns.div_ceil(20_000_000)
    } else if shape == RateShape::Constant {
        due_ns / 400_000 + 1
    } else {
        let last_frame = ((due_ns + 1) * 60 - 1) / 1_000_000_000;
        last_frame / 3 * 125 + [41, 83, 125][last_frame as usize % 3]
    };
    Some(Slot {
        sequence: ordinal as u64 + other,
        kind,
        ordinal,
        frame,
        due_ns,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn per_attempt_clock_cannot_hide_time_spent_processing_control() {
        let mut p = Producer::new(RateShape::Constant);
        p.offer(0);
        p.submit_timed(
            199_000_000,
            || 200_000_000,
            |_, _| panic!("expired during control work"),
        );
        assert_eq!(p.counts[0].expired, 1);
        assert_eq!(p.counts[1].expired, 1);
    }
    #[test]
    fn finite_virtual_source_both_shapes_conserves_bins_and_eight_attempt_turns() {
        for shape in [RateShape::Constant, RateShape::FrameBurst] {
            let mut p = Producer::new(shape);
            for tick in 0..120_000 {
                let now = tick * 100_000;
                p.offer(now);
                let mut count = 0;
                p.submit(now, |_, _| {
                    count += 1;
                    Admission::Accepted
                });
                assert!(count <= 8);
            }
            p.offer(12_000_000_000);
            p.submit(12_000_000_000, |_, _| panic!("after load"));
            assert_eq!(p.counts[0].admitted, 30_000);
            assert_eq!(p.counts[1].admitted, 600);
            assert_eq!(
                p.admitted.iter().map(|b| b.count_ones()).sum::<u32>(),
                30_600
            );
            assert_eq!(p.bins.iter().map(|b| b.offered).sum::<u64>(), 30_192_000);
            assert_eq!(p.bins.iter().map(|b| b.admitted).sum::<u64>(), 30_192_000);
            assert!(p.pending.capacity() * std::mem::size_of::<Pending>() <= 147_456);
            assert_eq!(p.jitter.capacity(), 30_600);
        }
    }
    #[test]
    fn retained_records_cannot_be_admitted_after_original_load_end() {
        let mut p = Producer::new(RateShape::Constant);
        p.offer(11_999_600_000);
        assert!(p.pending() > 0);
        p.submit(12_000_000_000, |_, _| {
            panic!("no post-load catch-up admission")
        });
        assert_eq!(p.pending(), 0);
        p.offer(12_200_000_000);
        for c in p.counts {
            assert_eq!(
                c.offered,
                c.admitted + c.overflow + c.expired + c.rejected + c.unfinished
            );
        }
    }
    #[test]
    fn backpressure_preserves_deadlines_and_overflow_never_hides_offers() {
        let mut p = Producer::new(RateShape::Constant);
        p.offer(0);
        p.submit(0, |_, deadline| {
            assert_eq!(deadline, 200_000_000);
            Admission::Backpressured
        });
        assert_eq!(p.counts[0].first_attempted, 1);
        p.submit(199_999_999, |_, deadline| {
            assert_eq!(deadline, 200_000_000);
            Admission::Backpressured
        });
        p.submit(200_000_000, |_, _| panic!("expired must never reach sink"));
        assert_eq!(p.counts[0].expired, 1);
        assert_eq!(p.counts[1].expired, 1);
        p.offer(500_000_000);
        assert_eq!(p.counts[0].offered, 1251);
        assert_eq!(p.counts[1].offered, 26);
        assert_eq!(p.peak, 128);
        assert!(p.counts[0].overflow > 0);
        p.offer(12_000_000_000);
        assert_eq!(p.counts[0].offered, 30_000);
        assert_eq!(p.counts[1].offered, 600);
        assert!(p.pending.len() <= 128);
        assert_eq!(p.jitter.len(), 1);
    }
    #[test]
    fn nearest_rank_keeps_slow_tail_and_empty_is_not_zero_latency_evidence() {
        assert_eq!(quantiles(&mut []), Quantiles::default());
        let mut samples = vec![1; 98];
        samples.extend([100_001, 200_001]);
        let q = quantiles(&mut samples);
        assert_eq!(q.samples, 100);
        assert_eq!(q.p95_us, 1);
        assert_eq!(q.p99_us, 100_001);
        assert_eq!(q.max_us, 200_001);
    }
    #[test]
    fn literal_schedule_slots_and_finite_totals() {
        for (shape, kind, ordinal, sequence, due, frame) in [
            (RateShape::Constant, 1, 0, 0, 0, u32::MAX),
            (RateShape::Constant, 2, 0, 1, 0, u32::MAX),
            (RateShape::Constant, 1, 50, 51, 20_000_000, u32::MAX),
            (RateShape::Constant, 2, 1, 52, 20_000_000, u32::MAX),
            (RateShape::FrameBurst, 1, 40, 40, 0, 0),
            (RateShape::FrameBurst, 2, 0, 41, 0, u32::MAX),
            (RateShape::FrameBurst, 1, 41, 42, 16_666_666, 1),
            (RateShape::FrameBurst, 1, 83, 85, 33_333_333, 2),
            (RateShape::FrameBurst, 1, 125, 128, 50_000_000, 3),
        ] {
            assert_eq!(
                slot(shape, kind, ordinal),
                Some(Slot {
                    sequence,
                    kind,
                    ordinal,
                    frame,
                    due_ns: due
                })
            );
        }
        for shape in [RateShape::Constant, RateShape::FrameBurst] {
            let mut seen = vec![false; 30_600];
            for (kind, total) in [(1, 30_000), (2, 600)] {
                for ordinal in 0..total {
                    let s = slot(shape, kind, ordinal).expect("required offered slot");
                    assert!(s.due_ns < 12_000_000_000);
                    assert!(!seen[s.sequence as usize]);
                    seen[s.sequence as usize] = true;
                }
                assert!(slot(shape, kind, total).is_none());
            }
            assert!(seen.into_iter().all(|x| x));
        }
        assert!(slot(RateShape::Constant, 3, 0).is_none());
    }
}
