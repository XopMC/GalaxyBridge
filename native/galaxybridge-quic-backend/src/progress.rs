//! Opt-in, whole-attempt observations, never a recovery or quality policy.
//! Times are local owner observations, not cross-machine latency measurements.
const KINDS: usize = 6;
pub(crate) const LIMIT: u64 = 4096;
const OBSERVATION_FLOOR_NS: u64 = 100_000_000;

/// generation, side, serial, kind, start/end ns, before/after counter,
/// admission/generated/sent/raw-UDP/received-datagram deltas in that interval.
/// Kind 0 is owner cadence; 1..5 follow those five endpoint counters.
/// Final fields: retained-intake duration delta ns, generated-expiry delta.
/// u64::MAX means unavailable/invalid, never zero pressure. GBQP2 is private
/// diagnostic grammar; it is not negotiated media/control protocol.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Line(pub [u64; 15]);
impl Line {
    #[cfg(test)]
    pub fn without_pressure(values: [u64; 13]) -> Self {
        let mut row = [u64::MAX; 15];
        row[..13].copy_from_slice(&values);
        Self(row)
    }
    pub fn encode(self) -> Vec<u8> {
        use std::fmt::Write;
        let mut out = String::with_capacity(320);
        out.push_str("GBQP2");
        for v in self.0 {
            write!(&mut out, " {v}").unwrap();
        }
        out.push('\n');
        out.into_bytes()
    }
    pub fn decode(bytes: &[u8], generation: u64, last: u64) -> Option<Self> {
        let mut words = std::str::from_utf8(bytes.strip_prefix(b"GBQP2 ")?)
            .ok()?
            .split(' ');
        let mut v = [0; 15];
        for n in &mut v {
            let w = words.next()?;
            if w.is_empty() || !w.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            *n = w.parse().ok()?;
        }
        if words.next().is_some()
            || generation == 0
            || v[0] != generation
            || v[1] != 2
            || v[2] <= last
            || v[2] > LIMIT
            || v[3] >= KINDS as u64
            || v[5].checked_sub(v[4])? < OBSERVATION_FLOOR_NS
            || v[7] <= v[6]
            || (v[3] != 0 && v[7] - v[6] != v[7 + v[3] as usize])
        {
            return None;
        }
        Some(Self(v))
    }
}

#[derive(Clone, Copy)]
struct Snapshot {
    at: u64,
    values: [u64; 6],
    pressure: [Option<u64>; 2],
}
#[derive(Default)]
pub(crate) struct Observer {
    previous: [Option<Snapshot>; KINDS],
    maxima: [u64; KINDS],
    pub pending: [Option<Line>; KINDS],
    maxima_lines: [Option<Line>; KINDS],
    turns: u64,
    serial: u64,
    next_kind: usize,
}
impl Observer {
    #[cfg(test)]
    pub fn sample(&mut self, generation: u64, side: u64, at: u64, counters: [u64; 5]) {
        self.sample_with_pressure(generation, side, at, counters, [None; 2]);
    }
    pub fn sample_with_pressure(
        &mut self,
        generation: u64,
        side: u64,
        at: u64,
        counters: [u64; 5],
        pressure: [Option<u64>; 2],
    ) {
        // No handshake/unused-endpoint interval is reported as a media pause.
        if self.turns == 0 && counters[0] == 0 && counters[4] == 0 {
            return;
        }
        self.turns = self.turns.saturating_add(1);
        let now = Snapshot {
            at,
            pressure,
            values: [
                self.turns,
                counters[0],
                counters[1],
                counters[2],
                counters[3],
                counters[4],
            ],
        };
        for kind in 0..KINDS {
            if now.values[kind] == 0 {
                continue;
            }
            let old = self.previous[kind];
            if old.is_some_and(|p| p.values[kind] == now.values[kind]) {
                continue;
            }
            self.previous[kind] = Some(now);
            let Some(old) = old else {
                continue;
            };
            let Some(gap) = at.checked_sub(old.at) else {
                continue;
            };
            if gap < OBSERVATION_FLOOR_NS
                || gap <= self.maxima[kind]
                || now.values.iter().zip(old.values).any(|(a, b)| *a < b)
            {
                continue;
            }
            self.maxima[kind] = gap;
            self.pending[kind] = Some(Line([
                generation,
                side,
                0,
                kind as u64,
                old.at,
                at,
                old.values[kind],
                now.values[kind],
                counters[0] - old.values[1],
                counters[1] - old.values[2],
                counters[2] - old.values[3],
                counters[3] - old.values[4],
                counters[4] - old.values[5],
                pressure[0]
                    .zip(old.pressure[0])
                    .and_then(|(a, b)| a.checked_sub(b))
                    .unwrap_or(u64::MAX),
                pressure[1]
                    .zip(old.pressure[1])
                    .and_then(|(a, b)| a.checked_sub(b))
                    .unwrap_or(u64::MAX),
            ]));
            self.maxima_lines[kind] = self.pending[kind];
        }
    }
    pub fn offer(&mut self, mut sink: impl FnMut(Line) -> bool) -> bool {
        if self.serial >= LIMIT - KINDS as u64 {
            return false;
        }
        let Some(index) = (0..KINDS)
            .map(|n| (self.next_kind + n) % KINDS)
            .find(|&n| self.pending[n].is_some())
        else {
            return false;
        };
        let mut line = self.pending[index].unwrap();
        line.0[2] = self.serial + 1;
        if !sink(line) {
            return false;
        }
        self.serial += 1;
        self.pending[index] = None;
        self.next_kind = (index + 1) % KINDS;
        true
    }
    pub fn finish(&mut self) -> [Option<Line>; KINDS] {
        let mut lines = self.maxima_lines;
        for line in lines.iter_mut().flatten() {
            self.serial += 1;
            line.0[2] = self.serial;
        }
        self.pending = [None; KINDS];
        self.maxima_lines = [None; KINDS];
        lines
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn whole_run_late_gap_retains_upstream_progress_without_startup_or_idle_guess() {
        let mut o = Observer::default();
        o.sample(17, 2, 1, [0; 5]);
        o.sample(17, 2, 120_000_000_000, [1; 5]);
        assert!(o.pending.iter().all(Option::is_none));
        // Owner and source keep progressing while UDP send and receive stop.
        for tick in 1..=100 {
            o.sample(
                17,
                2,
                120_000_000_000 + tick * 10_000_000,
                [tick + 1, tick + 1, 1, 1, 1],
            );
        }
        o.sample(17, 2, 121_010_000_000, [102; 5]);
        assert!(o.pending[..3].iter().all(Option::is_none));
        let row = o.pending[3].unwrap().0;
        assert_eq!(
            &row[4..13],
            &[
                120_000_000_000,
                121_010_000_000,
                1,
                102,
                101,
                101,
                101,
                101,
                101
            ]
        );
        assert!(!o.offer(|_| false));
        assert_eq!(o.serial, 0);
        assert!(o.offer(|line| {
            assert_eq!(line.0[2], 1);
            true
        }));
    }
    #[test]
    fn bounded_coalescing_and_origin_grammar() {
        let mut o = Observer::default();
        o.sample(17, 2, 1, [1; 5]);
        let mut at = 1;
        for tick in 2..10_000 {
            at += tick * 100_000_000;
            o.sample(17, 2, at, [tick; 5]);
        }
        assert_eq!(o.pending.iter().flatten().count(), KINDS);
        assert!(std::mem::size_of::<Observer>() < 3072);
        o.offer(|line| {
            let bytes = line.encode();
            assert!(bytes.len() < 320);
            assert_eq!(Line::decode(&bytes[..bytes.len() - 1], 17, 0), Some(line));
            assert!(Line::decode(&bytes[..bytes.len() - 1], 18, 0).is_none());
            assert!(Line::decode(&bytes[..bytes.len() - 1], 17, 1).is_none());
            true
        });
        let mut row = o.pending[1].unwrap();
        row.0[2] = 2;
        for (i, v) in [(1, 1), (2, LIMIT + 1), (3, 6), (5, 0), (7, 0), (8, 0)] {
            let mut bad = row;
            bad.0[i] = v;
            let b = bad.encode();
            assert!(Line::decode(&b[..b.len() - 1], 17, 1).is_none());
        }
    }
    #[test]
    fn progress_handshake_is_not_media_and_each_pending_kind_gets_a_turn() {
        let mut o = Observer::default();
        o.sample(9, 2, 1, [0, 0, 0, 1, 0]);
        o.sample(9, 2, 2_000_000_001, [0, 0, 0, 2, 0]);
        assert!(o.pending.iter().all(Option::is_none));
        o.sample(9, 2, 3_000_000_000, [1; 5]);
        o.sample(9, 2, 4_000_000_000, [2; 5]);
        let replenished = o.pending[0].unwrap();
        let mut kinds = vec![];
        for _ in 0..6 {
            o.pending[0] = Some(replenished);
            assert!(o.offer(|r| {
                kinds.push(r.0[3]);
                true
            }));
        }
        assert_eq!(kinds, vec![0, 1, 2, 3, 4, 5]);
        assert_eq!(o.maxima[4], 1_000_000_000);
    }
    #[test]
    fn progress_terminal_snapshot_keeps_already_offered_and_pending_maxima_in_order() {
        let mut o = Observer::default();
        o.sample(9, 2, 1, [1; 5]);
        o.sample(9, 2, 1_000_000_001, [2; 5]);
        assert!(o.offer(|_| true));
        let rows = o.finish();
        assert_eq!(rows.iter().flatten().count(), 6);
        for (i, row) in rows.into_iter().enumerate() {
            assert_eq!(row.unwrap().0[2], i as u64 + 2);
        }
        assert!(o.finish().iter().all(Option::is_none));
    }
    #[test]
    fn pressure_is_measured_over_the_same_gap_and_survives_terminal_handoff() {
        let mut o = Observer::default();
        o.sample_with_pressure(7, 2, 1, [1; 5], [Some(10), Some(4)]);
        // Raw socket has no progress. Pressure is sampled, but its baseline
        // must remain at the start of that socket gap, not the preceding turn.
        o.sample_with_pressure(
            7,
            2,
            50_000_001,
            [2, 2, 2, 1, 1],
            [Some(40_000_010), Some(7)],
        );
        o.sample_with_pressure(7, 2, 250_000_001, [3; 5], [Some(200_000_010), Some(11)]);
        let row = o.pending[4].unwrap();
        assert_eq!(&row.0[13..], &[200_000_000, 7]);
        assert_eq!(row.0[5] - row.0[4], 250_000_000);
        assert_eq!(&o.finish()[4].unwrap().0[13..], &[200_000_000, 7]);
        let mut o = Observer::default();
        o.sample_with_pressure(7, 2, 1, [1; 5], [Some(10), None]);
        o.sample_with_pressure(7, 2, 200_000_001, [2; 5], [Some(9), Some(0)]);
        assert_eq!(&o.pending[4].unwrap().0[13..], &[u64::MAX; 2]);
    }
}
