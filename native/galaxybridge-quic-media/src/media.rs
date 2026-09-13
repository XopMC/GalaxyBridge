use crate::{
    wire::{Record, BODY},
    Failure, AU_LIFETIME, MS, RECEIVE_LIFETIME,
};
use std::sync::{Arc, Mutex};

/// Opt-in scalar-only recovery observations. Sixty resident records leave room
/// for the bounded emitter/partial-parser records; no media reference escapes.
#[doc(hidden)]
pub mod recovery_trace {
    #[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
    pub struct Event(pub [u64; 8]);
    pub struct Trace {
        records: [Option<(u64, Event)>; 60],
        foreign: [u64; 60],
        next: usize,
        pub serial: u64,
        pub overwritten: u64,
        pub suppressed: u64,
        pub loss_episode: u64,
        pub selected: [[u64; 5]; 3], // request, epoch, config, AU, admitted fragments
        pub(super) source_class_records: u8,
    }
    impl Default for Trace {
        fn default() -> Self {
            Self {
                records: [None; 60],
                foreign: [0; 60],
                next: 0,
                serial: 0,
                overwritten: 0,
                suppressed: 0,
                loss_episode: 0,
                selected: [[0; 5]; 3],
                source_class_records: 0,
            }
        }
    }
    impl Trace {
        pub fn push(&mut self, event: Event) {
            let Some(serial) = self.serial.checked_add(1) else {
                self.suppressed = u64::MAX;
                return;
            };
            self.serial = serial;
            if self.records[self.next].is_some() {
                self.overwritten = self.overwritten.saturating_add(1);
            }
            self.foreign[self.next] = 0;
            self.records[self.next] = Some((serial, event));
            self.next = (self.next + 1) % 60;
        }
        pub fn pop(&mut self) -> Option<(u64, Event)> {
            let index = self
                .records
                .iter()
                .enumerate()
                .filter_map(|(i, r)| r.map(|v| (i, v.0)))
                .min_by_key(|v| v.1)?
                .0;
            self.records[index].take()
        }
        pub fn front(&self) -> Option<(u64, Event, u64)> {
            let (i, record) = self
                .records
                .iter()
                .enumerate()
                .filter_map(|(i, r)| r.map(|r| (i, r)))
                .min_by_key(|v| v.1 .0)?;
            Some((record.0, record.1, self.foreign[i]))
        }
        pub fn push_foreign(&mut self, event: Event, serial: u64) {
            let before = self.serial;
            self.push(event);
            if self.serial != before {
                self.foreign[(self.next + 59) % 60] = serial;
            }
        }
        pub fn update(&mut self, event: Event) {
            if let Some(i) = self.records.iter().enumerate().position(|(i, old)| {
                self.foreign[i] == 0 && old.is_some_and(|(_, old)| old.0[..6] == event.0[..6])
            }) {
                self.records[i].as_mut().unwrap().1 = event;
            } else {
                self.push(event);
            }
        }
        pub fn watch(&mut self, id: u64, epoch: u32, config: u32) {
            self.selected.rotate_left(1);
            self.selected[2] = [id, epoch as u64, config as u64, 0, 0];
        }
    }
}

/// Fixed, thread-scoped observation only. No allocation, logging or lock in
/// reject hooks; the host emits after leaving its existing owner/pool locks.
#[doc(hidden)]
pub mod first_error {
    use std::cell::Cell;
    #[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
    pub struct Rejection {
        pub module: u32,
        pub site: u32,
        pub used: u64,
        pub limit: u64,
        pub requested: u64,
        pub bytes: u64,
        pub byte_limit: u64,
    }
    #[derive(Clone, Copy, Debug, Default)]
    pub struct Observation {
        pub stage: u32,
        pub status: u32,
        pub rejection: Option<Rejection>,
    }
    thread_local! { static CURRENT: Cell<Option<Observation>> = const { Cell::new(None) }; }
    pub struct Scope {
        previous: Option<Observation>,
    }
    impl Scope {
        pub fn begin(enabled: bool) -> Self {
            let previous = CURRENT.with(|c| c.replace(enabled.then(Observation::default)));
            Self { previous }
        }
        pub fn observation(&self) -> Option<Observation> {
            CURRENT.with(Cell::get)
        }
    }
    impl Drop for Scope {
        fn drop(&mut self) {
            CURRENT.with(|c| c.set(self.previous));
        }
    }
    pub fn stage(value: u32) {
        CURRENT.with(|c| {
            if let Some(mut o) = c.get() {
                if o.status == 0 {
                    o.stage = value;
                }
                c.set(Some(o));
            }
        });
    }
    pub fn error(status: u32) {
        CURRENT.with(|c| {
            if let Some(mut o) = c.get() {
                if o.status == 0 {
                    o.status = status;
                }
                c.set(Some(o));
            }
        });
    }
    pub fn reject(
        module: u32,
        site: u32,
        used: usize,
        limit: usize,
        requested: usize,
        bytes: usize,
        byte_limit: usize,
    ) {
        CURRENT.with(|c| {
            if let Some(mut o) = c.get() {
                if o.status == 0 && o.rejection.is_none() {
                    o.rejection = Some(Rejection {
                        module,
                        site,
                        used: used as u64,
                        limit: limit as u64,
                        requested: requested as u64,
                        bytes: bytes as u64,
                        byte_limit: byte_limit as u64,
                    });
                }
                c.set(Some(o));
            }
        });
    }
    /// A handled source drop is not the failure returned by this operation.
    pub fn handled() {
        CURRENT.with(|c| {
            if let Some(mut o) = c.get() {
                if o.status == 0 {
                    o.rejection = None;
                }
                c.set(Some(o));
            }
        });
    }
}

#[cfg(test)]
mod first_error_pool_tests {
    use super::*;
    #[test]
    fn actual_copy_and_configuration_rejections_identify_their_independent_limits() {
        let p = Pool::new(8, 64);
        let _original = p.allocate(vec![0; 8]).unwrap();
        let copies: Vec<_> = (0..8)
            .map(|_| p.reserve_payload_au_copy(1).unwrap())
            .collect();
        let scope = first_error::Scope::begin(true);
        assert!(matches!(
            p.reserve_payload_au_copy(1),
            Err(Failure::Capacity)
        ));
        let copy = scope.observation().unwrap().rejection.unwrap();
        assert_eq!(
            (
                copy.used,
                copy.limit,
                copy.requested,
                copy.bytes,
                copy.byte_limit
            ),
            (8, 8, 1, 16, 64)
        );
        drop(scope);
        drop(copies);
        assert_eq!(p.usage(), (1, 8));
        let a = p.allocate_configuration(1, vec![0; 2]).unwrap();
        let b = p.allocate_configuration(1, vec![0; 2]).unwrap();
        let scope = first_error::Scope::begin(true);
        assert!(matches!(
            p.allocate_configuration(1, vec![0; 2]),
            Err(Failure::Capacity)
        ));
        let config = scope.observation().unwrap().rejection.unwrap();
        assert_eq!((config.used, config.limit, config.requested), (2, 2, 1));
        assert_ne!(config.site, copy.site);
        drop(scope);
        drop((a, b));
        let scope = first_error::Scope::begin(true);
        assert!(matches!(p.allocate(vec![0; 57]), Err(Failure::Capacity)));
        let bytes = scope.observation().unwrap().rejection.unwrap();
        assert_eq!(
            (
                bytes.used,
                bytes.limit,
                bytes.requested,
                bytes.bytes,
                bytes.byte_limit
            ),
            (1, 8, 57, 8, 64)
        );
        assert_eq!(p.usage(), (1, 8));
    }
}

#[cfg(test)]
mod feedback_limits {
    use super::*;
    #[test]
    fn recovery_observation_fixed_ring_latest_overflow_and_coalesced_fragment_count() {
        use recovery_trace::{Event, Trace};
        let mut trace = Trace::default();
        for sequence in 1..=200 {
            trace.push(Event([6, 1, 1, 1, sequence, sequence, 0, 0]));
        }
        assert_eq!(trace.overwritten, 140);
        let mut count = 0;
        let mut previous = 140;
        while let Some((serial, e)) = trace.pop() {
            assert_eq!(serial, previous + 1);
            assert_eq!(e.0[4], serial);
            previous = serial;
            count += 1;
        }
        assert_eq!((count, previous), (60, 200));
        trace.push(Event([11, 1, 1, 1, 201, 201, 0, 10]));
        for n in 1..=10 {
            trace.update(Event([11, 1, 1, 1, 201, 201, n, 10]));
        }
        assert_eq!(trace.pop().unwrap().1 .0[6], 10);
        assert!(trace.pop().is_none());
        trace.serial = u64::MAX;
        trace.push(Event([0; 8]));
        assert_eq!(trace.suppressed, u64::MAX);
        assert!(trace.pop().is_none());
        assert!(std::mem::size_of::<Trace>() < 8192);
    }
    fn receiver() -> Receiver {
        Receiver::new(crate::Context {
            session: [7; 32],
            generation: 1,
            scid: 1,
            capture_kind: 0,
            display_id: 0,
            target_token: 9,
            enabled: 7,
        })
        .unwrap()
    }
    fn record(kind: u8, sequence: u64, body: usize) -> Record {
        Record {
            kind,
            track: 1,
            flags: 0,
            generation: 1,
            epoch: 1,
            config: 1,
            sequence,
            pts: 0,
            total: 0,
            index: 0,
            count: 0,
            age_us: 0,
            lifetime_us: 0,
            body: vec![0; body],
        }
    }
    #[test]
    fn recovery_observation_actual_empty_gap_expiry_keeps_original_policy() {
        let mut r = receiver();
        r.recovery_trace = Some(Box::default());
        r.tracks[1].epoch = 1;
        r.tracks[1].version = 1;
        r.tracks[1].next = 1;
        r.gap(1, 1, 1).unwrap();
        assert_eq!(r.media.deadline(1, 1), Some(1 + AU_LIFETIME));
        r.tick(1 + AU_LIFETIME).unwrap();
        assert_eq!(r.media_health(1).unwrap().reason, 4);
        let observed = r.recovery_trace.as_mut().unwrap().pop();
        assert!(
            observed.is_some(),
            "actual original gap expiry must publish its origin"
        );
        assert_eq!(observed.unwrap().1 .0, [1, 1, 1, 1, 1, 1, 1, 0]);
    }
    #[test]
    fn feedback_ack_reservation_counts_inside_sixty_four_and_duplicate_keeps_deadline() {
        let mut r = receiver();
        for n in 1..=48 {
            r.feedback_until(record(7, n, 0), 100).unwrap();
        }
        assert_eq!(
            r.feedback_until(record(7, 49, 0), 100),
            Err(Failure::Capacity)
        );
        for n in 1..=16 {
            r.feedback_until(record(14, n, 4), 100).unwrap();
        }
        assert_eq!(r.feedback.len(), 64);
        assert_eq!(
            r.feedback_until(record(14, 17, 4), 100),
            Err(Failure::Capacity)
        );
        r.feedback_until(record(14, 1, 4), 999).unwrap();
        assert_eq!(r.feedback_deadline(), Some(100));
        assert_eq!(r.feedback.front().unwrap().0.kind, 14);
        r.retire(Failure::Deadline);
        assert!(r.feedback.is_empty());
    }
    #[test]
    fn feedback_bytes_reserve_two_kib_inside_sixteen_kib() {
        let mut r = receiver();
        // Private queue seam isolates retained allocation from wire validity.
        for n in 1..=14 {
            r.feedback_until(record(7, n, 960), 100).unwrap();
        }
        assert_eq!(
            r.feedback_until(record(7, 15, 0), 100),
            Err(Failure::Capacity)
        );
        for n in 1..=16 {
            r.feedback_until(record(14, n, 4), 100).unwrap();
        }
        assert!(
            r.feedback
                .iter()
                .map(|(r, _)| 64 + r.body.capacity())
                .sum::<usize>()
                <= 16384
        );
        assert_eq!(
            r.feedback_until(record(14, 17, 960), 100),
            Err(Failure::Capacity)
        );
    }
}

#[derive(Clone, Debug)]
pub struct Bytes(Arc<Storage>);
impl Bytes {
    pub fn as_slice(&self) -> &[u8] {
        &self.0.bytes
    }
    pub fn len(&self) -> usize {
        self.0.bytes.len()
    }
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}
impl Bytes {
    fn unique_mut(&mut self) -> Result<&mut [u8], Failure> {
        Ok(&mut Arc::get_mut(&mut self.0).ok_or(Failure::Protocol)?.bytes)
    }
}
impl Bytes {
    pub fn references(&self) -> usize {
        Arc::strong_count(&self.0)
    }
}
#[derive(Debug)]
struct Storage {
    bytes: Box<[u8]>,
    pool: Arc<Mutex<(usize, usize)>>,
    configuration: Option<(usize, Arc<Mutex<[usize; 3]>>)>,
}
impl Drop for Storage {
    fn drop(&mut self) {
        {
            let mut used = self.pool.lock().unwrap();
            used.0 -= 1;
            used.1 -= self.bytes.len();
        }
        if let Some((track, counts)) = &self.configuration {
            counts.lock().unwrap()[*track] -= 1;
        }
    }
}
#[derive(Clone)]
pub struct Pool {
    slots: usize,
    bytes: usize,
    used: Arc<Mutex<(usize, usize)>>,
    configurations: Arc<Mutex<[usize; 3]>>,
    payload_copy_slots: Arc<Mutex<[usize; 2]>>,
}
impl Pool {
    pub fn new(slots: usize, bytes: usize) -> Self {
        Self {
            slots,
            bytes,
            used: Arc::new(Mutex::new((0, 0))),
            configurations: Arc::new(Mutex::new([0; 3])),
            payload_copy_slots: Arc::new(Mutex::new([0; 2])),
        }
    }
    pub fn allocate(&self, bytes: Vec<u8>) -> Result<Bytes, Failure> {
        let mut used = self.used.lock().unwrap();
        if used.0 >= self.slots || bytes.len() > self.bytes.saturating_sub(used.1) {
            first_error::reject(
                1,
                line!(),
                used.0,
                self.slots,
                bytes.len(),
                used.1,
                self.bytes,
            );
            return Err(Failure::Capacity);
        }
        // Box conversion discards spare Vec capacity before this allocation is retained.
        let bytes = bytes.into_boxed_slice();
        used.0 += 1;
        used.1 += bytes.len();
        Ok(Bytes(Arc::new(Storage {
            bytes,
            pool: self.used.clone(),
            configuration: None,
        })))
    }
    pub fn allocate_configuration(&self, track: u8, bytes: Vec<u8>) -> Result<Bytes, Failure> {
        if !matches!(track, 1 | 2) {
            return Err(Failure::Protocol);
        }
        let track = track as usize;
        {
            let mut counts = self.configurations.lock().unwrap();
            if counts[track] >= 2 {
                first_error::reject(1, line!(), counts[track], 2, 1, 0, 0);
                return Err(Failure::Capacity);
            }
            counts[track] += 1;
        }
        match self.allocate(bytes) {
            Ok(mut bytes) => {
                Arc::get_mut(&mut bytes.0).unwrap().configuration =
                    Some((track, self.configurations.clone()));
                Ok(bytes)
            }
            Err(e) => {
                self.configurations.lock().unwrap()[track] -= 1;
                Err(e)
            }
        }
    }
    pub fn usage(&self) -> (usize, usize) {
        *self.used.lock().unwrap()
    }
    pub fn available(&self, len: usize) -> bool {
        let used = self.usage();
        used.0 < self.slots && len <= self.bytes.saturating_sub(used.1)
    }
    fn available_or_reject(&self, len: usize, site: u32) -> bool {
        // Same single snapshot/lock as available(), with its original decision.
        let used = self.usage();
        let available = used.0 < self.slots && len <= self.bytes.saturating_sub(used.1);
        if !available {
            first_error::reject(1, site, used.0, self.slots, len, used.1, self.bytes);
        }
        available
    }
}

struct Assembly {
    header: Record,
    bytes: Option<Bytes>,
    parity: Option<Box<[u8; BODY]>>,
    seen: Vec<bool>,
    received: usize,
    first: u64,
    last_unique: u64,
    successor_observed: Option<u64>,
    deadline: u64,
    requests: u8,
    last_request: Option<u64>,
    // A complete, immutable AU may be inspected before extraction to decide
    // whether it can overtake a pending recovery. Cache the classification so
    // polling does not repeatedly parse queued dependent pictures.
    codec_independent: Option<bool>,
}
pub struct Reassembler {
    pool: Pool,
    entries: Vec<Assembly>,
    repair_margin: Option<u64>,
    observed: u64,
}
impl Assembly {
    // The same eligible opportunity drives dispatch and wakeup. A bitmap is
    // only a requested subset, never an acknowledgement of unset positions.
    fn repair_opportunity(&self, margin: Option<u64>, now: u64) -> Option<(u64, bool)> {
        if self.requests >= 2
            || now >= self.deadline
            || self.bytes.is_some() && self.received == self.header.count as usize
        {
            return None;
        }
        let grace = self.first.checked_add(5 * MS)?;
        if self.bytes.is_none() {
            let at = grace
                .max(
                    self.last_request
                        .map_or(Some(grace), |v| v.checked_add(10 * MS))?,
                )
                .max(now);
            return (at < self.deadline).then_some((at, false));
        }
        let highest = self.seen.iter().rposition(|seen| *seen)?;
        let interior = self.requests == 0 && self.seen[..highest].iter().any(|seen| !seen);
        let early = interior
            .then_some(grace.max(now))
            .filter(|at| *at < self.deadline);
        let full = margin.filter(|m| *m > 0).and_then(|m| {
            let quiet = self.last_unique.checked_add(m.max(5 * MS))?;
            // Source admits every original fragment of an ordinary AU before
            // the next AU on this track. A validated successor is therefore
            // evidence of a lost/reordered tail, unlike a contiguous prefix.
            // Keep the existing reordering grace and retry/lifetime bounds.
            let progress = if self.requests == 0 {
                self.successor_observed
                    .and_then(|at| at.max(self.last_unique).checked_add(5 * MS))
                    .map_or(quiet, |at| at.min(quiet))
            } else {
                quiet
            };
            let separation = self
                .last_request
                .map_or(Some(grace), |last| last.checked_add(m.max(10 * MS)))?;
            let at = grace.max(progress).max(separation).max(now);
            (at.checked_add(m)? < self.deadline).then_some(at)
        });
        match (early, full) {
            (Some(a), Some(b)) if b <= a => Some((b, false)),
            (Some(a), _) => Some((a, true)),
            (_, Some(b)) => Some((b, false)),
            _ => None,
        }
    }
}
impl Default for Reassembler {
    fn default() -> Self {
        Self::new()
    }
}
impl Reassembler {
    pub fn new() -> Self {
        Self {
            pool: Pool::new(8, 16 * 1024 * 1024),
            entries: vec![],
            repair_margin: None,
            observed: 0,
        }
    }
    pub fn set_repair_margin(&mut self, margin: Option<u64>) {
        self.repair_margin = margin.filter(|m| *m > 0);
    }
    pub fn usage(&self) -> (usize, usize) {
        self.pool.usage()
    }
    pub fn retained_slots(&self) -> usize {
        self.pool.usage().0 + self.entries.iter().filter(|e| e.bytes.is_none()).count()
    }
    fn admission_pressure(&self, r: &Record) -> bool {
        let entry = self
            .entries
            .iter()
            .find(|e| e.header.track == r.track && e.header.sequence == r.sequence);
        if entry.is_some_and(|e| e.bytes.is_some()) {
            return false;
        }
        let used = self.pool.usage();
        (entry.is_none() && self.retained_slots() >= 8)
            || used.0 >= 8
            || r.total as usize > 16 * 1024 * 1024 - used.1
    }
    fn discard_through(&mut self, track: u8, sequence: u64) {
        self.entries
            .retain(|e| e.header.track != track || e.header.sequence > sequence);
    }
    fn discard_sequence(&mut self, track: u8, sequence: u64) {
        self.entries
            .retain(|entry| entry.header.track != track || entry.header.sequence != sequence);
    }
    fn reliable_recovery_sequence(&self, track: u8) -> Option<u64> {
        self.entries
            .iter()
            .filter(|entry| {
                entry.header.track == track
                    && entry.header.flags & crate::wire::RELIABLE_RECOVERY_FLAG != 0
            })
            .map(|entry| entry.header.sequence)
            .min()
    }
    pub fn contains(&self, track: u8, sequence: u64) -> bool {
        self.entries
            .iter()
            .any(|e| e.header.track == track && e.header.sequence == sequence)
    }
    pub fn deadline(&self, track: u8, sequence: u64) -> Option<u64> {
        self.entries
            .iter()
            .find(|e| e.header.track == track && e.header.sequence == sequence)
            .map(|e| e.deadline)
    }
    pub fn headers(&self) -> impl Iterator<Item = &Record> {
        self.entries.iter().map(|e| &e.header)
    }
    pub fn complete_headers(&self) -> impl Iterator<Item = &Record> {
        self.entries
            .iter()
            .filter(|e| e.bytes.is_some() && e.received == e.header.count as usize)
            .map(|e| &e.header)
    }
    fn recovery_sequence(&mut self, track: &Track, protected: u64) -> Result<Option<u64>, Failure> {
        let mut sequence = None;
        for e in &mut self.entries {
            let h = &e.header;
            if h.track != 1
                || h.epoch != track.epoch
                || h.config != track.version
                || h.sequence < track.next
                || e.bytes.is_none()
                || e.received != h.count as usize
            {
                continue;
            }
            if h.sequence > protected && h.flags & 1 == 0 {
                let independent = match e.codec_independent {
                    Some(value) => value,
                    None => {
                        let config = track
                            .configs
                            .iter()
                            .find(|c| c.epoch == h.epoch && c.version == h.config)
                            .ok_or(Failure::Protocol)?;
                        let value = config
                            .parsed
                            .independent(e.bytes.as_ref().unwrap().as_slice(), false)?;
                        e.codec_independent = Some(value);
                        value
                    }
                };
                if !independent {
                    continue;
                }
            }
            sequence = Some(sequence.map_or(h.sequence, |s: u64| s.min(h.sequence)));
        }
        Ok(sequence)
    }
    pub fn expect_gap(&mut self, mut header: Record, now: u64) -> Result<(), Failure> {
        self.observed = self.observed.max(now);
        if self.contains(header.track, header.sequence) {
            return Ok(());
        }
        let retained = self.retained_slots();
        if retained >= 8 {
            first_error::reject(1, line!(), retained, 8, 1, 0, 0);
            return Err(Failure::Capacity);
        }
        header.kind = 5;
        header.total = 0;
        header.count = 0;
        header.index = 0;
        header.body = vec![];
        let lifetime = if header.track == 1 {
            crate::AU_LIFETIME
        } else {
            RECEIVE_LIFETIME
        };
        self.entries.push(Assembly {
            header,
            bytes: None,
            parity: None,
            seen: vec![],
            received: 0,
            first: now,
            last_unique: now,
            successor_observed: None,
            deadline: now.checked_add(lifetime).ok_or(Failure::Clock)?,
            requests: 0,
            last_request: None,
            codec_independent: None,
        });
        Ok(())
    }
    pub fn ingest(&mut self, r: Record, now: u64) -> Result<(), Failure> {
        self.observed = self.observed.max(now);
        if r.validate().is_err() {
            first_error::reject(
                3,
                line!(),
                r.kind as usize,
                r.track as usize,
                ((r.index as usize) << 16) | r.count as usize,
                r.total as usize,
                r.body.len(),
            );
            return Err(Failure::Protocol);
        }
        if !matches!(r.kind, 5 | crate::wire::XOR_PARITY_KIND) {
            first_error::reject(3, line!(), r.kind as usize, 5, 1, 0, 0);
            return Err(Failure::Protocol);
        }
        let is_parity = r.kind == crate::wire::XOR_PARITY_KIND;
        let key = |e: &Assembly| e.header.track == r.track && e.header.sequence == r.sequence;
        if !self.entries.iter().any(key) {
            let retained = self.retained_slots();
            if retained >= 8 {
                first_error::reject(1, line!(), retained, 8, 1, 0, 0);
                return Err(Failure::Capacity);
            }
            let mut header = r.with_body(vec![]);
            header.kind = 5;
            header.index = 0;
            self.entries.push(Assembly {
                header,
                bytes: None,
                parity: None,
                seen: vec![],
                received: 0,
                first: now,
                last_unique: now,
                successor_observed: None,
                deadline: now
                    .checked_add(
                        (if r.track == 1 && r.flags & crate::wire::RELIABLE_RECOVERY_FLAG != 0 {
                            crate::RELIABLE_RECOVERY_RECEIVE_LIFETIME
                        } else if r.track == 1 && r.flags & 1 != 0 && r.lifetime_us == 500_000 {
                            crate::STARTUP_INDEPENDENT_RECEIVE_LIFETIME
                        } else if r.track == 1 && r.flags & 1 != 0 && r.lifetime_us == 250_000 {
                            crate::INDEPENDENT_RECEIVE_LIFETIME
                        } else if r.track == 1 {
                            crate::AU_LIFETIME
                        } else {
                            RECEIVE_LIFETIME
                        })
                        .min((r.lifetime_us - r.age_us) as u64 * 1000),
                    )
                    .ok_or(Failure::Clock)?,
                requests: 0,
                last_request: None,
                codec_independent: None,
            });
        }
        let e = self
            .entries
            .iter_mut()
            .find(|e| e.header.track == r.track && e.header.sequence == r.sequence)
            .unwrap();
        if now >= e.deadline {
            return Err(Failure::Deadline);
        }
        if e.header.generation != r.generation
            || e.header.epoch != r.epoch
            || e.header.config != r.config
        {
            let mismatch = usize::from(e.header.generation != r.generation)
                | (usize::from(e.header.epoch != r.epoch) << 1)
                | (usize::from(e.header.config != r.config) << 2);
            first_error::reject(
                3,
                line!(),
                mismatch,
                e.header.generation as usize,
                r.generation as usize,
                ((e.header.epoch as usize) << 32) | e.header.config as usize,
                ((r.epoch as usize) << 32) | r.config as usize,
            );
            return Err(Failure::Protocol);
        }
        if e.bytes.is_none() && e.header.count == 0 && r.track == 1 {
            // An absent-sequence placeholder has no AU class yet. Its first
            // actual header classifies that same original residence interval;
            // subsequent fragments/repairs can only shorten the deadline.
            e.deadline = e
                .first
                .checked_add(if r.flags & crate::wire::RELIABLE_RECOVERY_FLAG != 0 {
                    crate::RELIABLE_RECOVERY_RECEIVE_LIFETIME
                } else if r.flags & 1 != 0 && r.lifetime_us == 500_000 {
                    crate::STARTUP_INDEPENDENT_RECEIVE_LIFETIME
                } else if r.flags & 1 != 0 && r.lifetime_us == 250_000 {
                    crate::INDEPENDENT_RECEIVE_LIFETIME
                } else {
                    crate::AU_LIFETIME
                })
                .ok_or(Failure::Clock)?;
        }
        e.deadline = e.deadline.min(
            now.checked_add((r.lifetime_us - r.age_us) as u64 * 1000)
                .ok_or(Failure::Clock)?,
        );
        if e.bytes.is_none() {
            if !self.pool.available_or_reject(r.total as usize, line!()) {
                return Err(Failure::Capacity);
            }
            e.bytes = Some(self.pool.allocate(vec![0; r.total as usize])?);
            e.header = r.with_body(vec![]);
            e.header.kind = 5;
            e.header.index = 0;
            e.seen = vec![false; r.count as usize];
        }
        let mismatch = object_mismatch_mask(&e.header, &r);
        if mismatch != 0 {
            first_error::reject(
                3,
                line!(),
                mismatch,
                ((e.header.flags as usize) << 16) | e.header.count as usize,
                ((r.flags as usize) << 16) | r.count as usize,
                ((e.header.total as usize) << 32) | e.header.lifetime_us as usize,
                ((r.total as usize) << 32) | r.lifetime_us as usize,
            );
            return Err(Failure::Protocol);
        }
        if is_parity {
            if let Some(parity) = &e.parity {
                if parity.as_slice() != r.body.as_slice() {
                    first_error::reject(
                        3,
                        line!(),
                        r.index as usize,
                        e.header.count as usize,
                        r.count as usize,
                        parity.len(),
                        r.body.len(),
                    );
                    return Err(Failure::Protocol);
                }
                return Ok(());
            }
            let parity: [u8; BODY] = match r.body.as_slice().try_into() {
                Ok(parity) => parity,
                Err(_) => {
                    first_error::reject(3, line!(), r.body.len(), BODY, 1, 0, 0);
                    return Err(Failure::Protocol);
                }
            };
            e.parity = Some(Box::new(parity));
            e.last_unique = now;
            Self::recover_one_missing(e)?;
            return Ok(());
        }
        let start = r.index as usize * BODY;
        let bytes = e.bytes.as_mut().unwrap();
        if e.seen[r.index as usize] {
            if bytes.as_slice()[start..start + r.body.len()] != r.body {
                first_error::reject(
                    3,
                    line!(),
                    r.index as usize,
                    e.header.count as usize,
                    1,
                    r.body.len(),
                    bytes.len(),
                );
                return Err(Failure::Protocol);
            }
            return Ok(());
        }
        let byte_references = bytes.references();
        let byte_length = bytes.len();
        let target = match bytes.unique_mut() {
            Ok(target) => target,
            Err(error) => {
                first_error::reject(
                    3,
                    line!(),
                    byte_references,
                    1,
                    r.body.len(),
                    byte_length,
                    r.total as usize,
                );
                return Err(error);
            }
        };
        target[start..start + r.body.len()].copy_from_slice(&r.body);
        e.seen[r.index as usize] = true;
        e.received += 1;
        e.last_unique = now;
        Self::recover_one_missing(e)?;
        if r.flags & crate::wire::RELIABLE_RECOVERY_FLAG == 0 {
            for previous in &mut self.entries {
                if previous.header.track == r.track
                    && previous.header.generation == r.generation
                    && previous.header.epoch == r.epoch
                    && previous.header.config == r.config
                    && previous.header.sequence < r.sequence
                    && previous.header.flags & crate::wire::RELIABLE_RECOVERY_FLAG == 0
                {
                    previous.successor_observed.get_or_insert(now);
                }
            }
        }
        Ok(())
    }
    fn recover_one_missing(e: &mut Assembly) -> Result<(), Failure> {
        if e.bytes.is_none()
            || e.parity.is_none()
            || e.received.checked_add(1) != Some(e.header.count as usize)
        {
            return Ok(());
        }
        let Some(missing) = e.seen.iter().position(|seen| !seen) else {
            return Ok(());
        };
        let mut recovered = **e.parity.as_ref().unwrap();
        let bytes = e.bytes.as_mut().unwrap();
        for (index, seen) in e.seen.iter().copied().enumerate() {
            if !seen {
                continue;
            }
            let start = index * BODY;
            let length = (bytes.len() - start).min(BODY);
            for (target, source) in recovered[..length]
                .iter_mut()
                .zip(&bytes.as_slice()[start..start + length])
            {
                *target ^= *source;
            }
        }
        let start = missing * BODY;
        let length = (bytes.len() - start).min(BODY);
        bytes.unique_mut()?[start..start + length].copy_from_slice(&recovered[..length]);
        e.seen[missing] = true;
        e.received += 1;
        Ok(())
    }
    pub fn take(&mut self, track: u8, sequence: u64, now: u64) -> Option<Completed> {
        let pos = self.entries.iter().position(|e| {
            e.header.track == track
                && e.header.sequence == sequence
                && e.bytes.is_some()
                && e.received == e.header.count as usize
                && now < e.deadline
        })?;
        let e = self.entries.remove(pos);
        Some(Completed {
            record: e.header,
            bytes: e.bytes?,
            deadline: e.deadline,
        })
    }
    pub fn next_missing(&mut self, now: u64) -> Option<Record> {
        self.observed = self.observed.max(now);
        let margin = self.repair_margin;
        let (e, interior_only) = self.entries.iter_mut().find_map(|e| {
            let (at, interior) = e.repair_opportunity(margin, now)?;
            (at <= now).then_some((e, interior))
        })?;
        let mut r = e.header.with_body(vec![]);
        r.kind = 6;
        r.flags = 0;
        r.pts = 0;
        r.index = 0;
        r.age_us = 0;
        r.lifetime_us = 0;
        if e.bytes.is_some() {
            r.body = vec![0; (r.count as usize).div_ceil(8)];
            let end = if interior_only {
                e.seen.iter().rposition(|seen| *seen)?
            } else {
                e.seen.len()
            };
            for (i, seen) in e.seen.iter().enumerate() {
                if i < end && !seen {
                    r.body[i / 8] |= 1 << (i % 8)
                }
            }
        } else {
            r.total = 0;
            r.count = 0;
        }
        e.requests += 1;
        e.last_request = Some(now);
        Some(r)
    }
    pub fn expired(&mut self, now: u64) -> Vec<Record> {
        self.observed = self.observed.max(now);
        let mut out = vec![];
        let mut i = 0;
        while i < self.entries.len() {
            if now >= self.entries[i].deadline {
                out.push(self.entries.remove(i).header)
            } else {
                i += 1
            }
        }
        out
    }
    pub fn discard_track(&mut self, track: u8) {
        self.entries.retain(|e| e.header.track != track)
    }
    pub fn discard_before_epoch(&mut self, track: u8, epoch: u32) {
        self.entries
            .retain(|e| e.header.track != track || e.header.epoch >= epoch)
    }
    pub fn clear(&mut self) {
        self.entries.clear()
    }
    pub fn next_wakeup(&self) -> Option<u64> {
        self.entries
            .iter()
            .flat_map(|e| {
                [
                    Some(e.deadline),
                    e.repair_opportunity(self.repair_margin, self.observed)
                        .map(|(at, _)| at),
                ]
            })
            .flatten()
            .min()
    }
}
pub struct Completed {
    pub record: Record,
    pub bytes: Bytes,
    pub deadline: u64,
}

fn same_object(a: &Record, b: &Record) -> bool {
    object_mismatch_mask(a, b) == 0
}

fn object_mismatch_mask(a: &Record, b: &Record) -> usize {
    usize::from(a.track != b.track)
        | (usize::from(a.generation != b.generation) << 1)
        | (usize::from(a.epoch != b.epoch) << 2)
        | (usize::from(a.config != b.config) << 3)
        | (usize::from(a.sequence != b.sequence) << 4)
        | (usize::from(a.pts != b.pts) << 5)
        | (usize::from(a.flags != b.flags) << 6)
        | (usize::from(a.total != b.total) << 7)
        | (usize::from(a.count != b.count) << 8)
        | (usize::from(a.lifetime_us != b.lifetime_us) << 9)
}
struct Cached {
    header: Record,
    bytes: Bytes,
    queued: u64,
    deadline: u64,
    next: u16,
    retries: Vec<u8>,
    requested: Vec<bool>,
    parity: Option<Box<[u8; BODY]>>,
    parity_sent: bool,
}
pub struct Cache {
    pool: Pool,
    entries: Vec<Cached>,
    next_track: u8,
    xor_parity: bool,
    pub unavailable: u64,
}
impl Default for Cache {
    fn default() -> Self {
        Self::new()
    }
}
impl Cache {
    pub fn new() -> Self {
        Self::with_xor_parity(false)
    }
    pub fn with_xor_parity(xor_parity: bool) -> Self {
        Self {
            // Mixed60fps video/AAC residency includes the real return-ACK
            // flight and a longer independent AU. Bytes remain one16MiB cap;
            // this is only Source originals, never Receiver/native credits.
            pool: Pool::new(16, 16 * 1024 * 1024),
            entries: vec![],
            next_track: 1,
            xor_parity,
            unavailable: 0,
        }
    }
    pub fn usage(&self) -> (usize, usize) {
        self.pool.usage()
    }
    pub fn insert(&mut self, r: Record, queued: u64) -> Result<(), Failure> {
        self.insert_with_lifetime(r, queued, AU_LIFETIME)
    }
    pub(crate) fn insert_with_lifetime(
        &mut self,
        mut r: Record,
        queued: u64,
        lifetime: u64,
    ) -> Result<(), Failure> {
        if lifetime != AU_LIFETIME
            && !(matches!(
                lifetime,
                crate::INDEPENDENT_AU_LIFETIME | crate::STARTUP_INDEPENDENT_AU_LIFETIME
            ) && r.track == 1
                && r.flags & 1 != 0)
        {
            return Err(Failure::Protocol);
        }
        if r.kind != 5
            || r.body.is_empty()
            || r.body.len()
                > if r.track == 1 {
                    crate::wire::VIDEO_AU
                } else {
                    crate::wire::SMALL_OBJECT
                }
        {
            first_error::reject(
                1,
                line!(),
                0,
                0,
                r.body.len(),
                0,
                if r.track == 1 {
                    crate::wire::VIDEO_AU
                } else {
                    crate::wire::SMALL_OBJECT
                },
            );
            return Err(Failure::Capacity);
        }
        if self
            .entries
            .iter()
            .any(|e| e.header.track == r.track && e.header.sequence == r.sequence)
        {
            return Err(Failure::Protocol);
        }
        r.total = r.body.len() as u32;
        r.count = r.body.len().div_ceil(BODY) as u16;
        r.index = 0;
        r.lifetime_us = (lifetime / 1000) as u32;
        r.age_us = 0;
        r.with_body(r.body[..r.body.len().min(BODY)].to_vec())
            .validate()
            .map_err(|_| Failure::Protocol)?;
        let count = r.count as usize;
        let parity = (self.xor_parity && r.track == 1 && count > 1).then(|| {
            let mut parity = Box::new([0u8; BODY]);
            for fragment in r.body.chunks(BODY) {
                for (target, source) in parity.iter_mut().zip(fragment) {
                    *target ^= *source;
                }
            }
            parity
        });
        let bytes = self.pool.allocate(std::mem::take(&mut r.body))?;
        self.entries.push(Cached {
            header: r,
            bytes,
            queued,
            deadline: queued.checked_add(lifetime).ok_or(Failure::Clock)?,
            next: 0,
            retries: vec![0; count],
            requested: vec![false; count],
            parity,
            parity_sent: false,
        });
        Ok(())
    }
    pub fn request(
        &mut self,
        r: &Record,
        now: u64,
        rtt_margin: Option<u64>,
    ) -> Result<(), Failure> {
        r.validate().map_err(|_| Failure::Protocol)?;
        if r.kind != 6 {
            return Err(Failure::Protocol);
        }
        let Some(e) = self.entries.iter_mut().find(|e| {
            e.header.track == r.track
                && e.header.sequence == r.sequence
                && e.header.epoch == r.epoch
                && e.header.config == r.config
                && e.header.generation == r.generation
        }) else {
            self.unavailable = self.unavailable.saturating_add(1);
            return Ok(());
        };
        if now >= e.deadline
            || rtt_margin
                .is_none_or(|margin| now.checked_add(margin).is_none_or(|t| t >= e.deadline))
        {
            self.unavailable = self.unavailable.saturating_add(1);
            return Ok(());
        }
        if r.total != 0 && (r.total != e.header.total || r.count != e.header.count) {
            return Err(Failure::Protocol);
        }
        for i in 0..e.requested.len() {
            if r.total == 0 || r.body[i / 8] & (1 << (i % 8)) != 0 {
                // A receiver can request a hole before its original fragment
                // has reached transport admission. It is still initial work,
                // not an extra repair followed by the same original send.
                if i < e.next as usize && e.retries[i] < 2 {
                    e.requested[i] = true;
                }
            }
        }
        Ok(())
    }
    pub fn next(&mut self, now: u64) -> Option<(Record, u64, bool)> {
        self.expire(now);
        // One accepted fragment per track turn. Preserve each track's original
        // AU order and repair precedence without making audio wait behind an
        // entire fragmented video AU. Backpressure does not consume a turn.
        let pending = |track| {
            self.entries
                .iter()
                .find(|e| e.header.track == track && e.requested.iter().any(|b| *b))
                .or_else(|| {
                    self.entries.iter().find(|e| {
                        e.header.track == track
                            && (e.next < e.header.count || e.parity.is_some() && !e.parity_sent)
                    })
                })
        };
        let e = pending(self.next_track).or_else(|| pending(3 - self.next_track))?;
        // Finish this selected AU's first admission pass before repairing its
        // prefix. Keep requests pending and retain this entry's precedence over
        // newer AUs; an admitted prefix is not evidence its tail was sent.
        let parity = e.next == e.header.count && e.parity.is_some() && !e.parity_sent;
        let repair = (!parity && e.next == e.header.count)
            .then(|| e.requested.iter().position(|b| *b))
            .flatten();
        let mut r = if parity {
            let body = e.parity.as_ref()?.as_slice().to_vec();
            let mut record = e.header.with_body(body);
            record.kind = crate::wire::XOR_PARITY_KIND;
            record.index = crate::wire::parity_checksum(&record.body);
            record
        } else {
            let index = repair.unwrap_or(e.next as usize);
            let start = index * BODY;
            let mut record = e
                .header
                .with_body(e.bytes.as_slice()[start..(start + BODY).min(e.bytes.len())].to_vec());
            record.index = index as u16;
            record
        };
        r.age_us = (now - e.queued).div_ceil(1000).try_into().ok()?;
        if r.age_us >= r.lifetime_us {
            return None;
        }
        Some((r, e.deadline, repair.is_some()))
    }
    pub fn accepted(&mut self, r: &Record, repair: bool) -> Result<(), Failure> {
        let e = self
            .entries
            .iter_mut()
            .find(|e| same_object(&e.header, r))
            .ok_or(Failure::Protocol)?;
        if r.kind == crate::wire::XOR_PARITY_KIND {
            if repair || e.next != e.header.count || e.parity.is_none() || e.parity_sent {
                return Err(Failure::Protocol);
            }
            e.parity_sent = true;
        } else if repair {
            let i = r.index as usize;
            e.requested[i] = false;
            e.retries[i] += 1;
        } else {
            if r.index != e.next {
                return Err(Failure::Protocol);
            }
            e.next += 1;
        }
        self.next_track = 3 - r.track;
        Ok(())
    }
    pub fn ack(&mut self, r: &Record) -> Result<(), Failure> {
        if r.kind != 7 {
            return Err(Failure::Protocol);
        }
        self.entries.retain(|e| {
            !(e.header.generation == r.generation
                && e.header.track == r.track
                && e.header.epoch == r.epoch
                && e.header.config == r.config
                && e.header.sequence == r.sequence)
        });
        Ok(())
    }
    pub fn expire(&mut self, now: u64) {
        self.entries.retain(|e| now < e.deadline)
    }
    pub fn clear(&mut self) {
        self.entries.clear()
    }
    /// Retire complete sender-owned video access units after the transport
    /// proves that one accepted fragment missed its UDP deadline. Audio remains
    /// live on its independent track while the producer supplies a fresh IDR.
    pub fn discard_video(&mut self) {
        self.entries.retain(|entry| entry.header.track != 1);
    }
    /// Drop the broken dependent chain, retaining independent AUs on either
    /// side of the loss (but never the lost AU itself). A shorter-lived delta
    /// can expire while its preceding IDR still has a valid send/repair budget.
    /// Only the first newer IDR makes dependent successors safe to retain.
    /// The caller expires the cache before applying this recovery selection.
    pub fn discard_video_before_recovery_key(
        &mut self,
        generation: u64,
        lost_sequence: u64,
    ) -> Option<u64> {
        let replacement = self
            .entries
            .iter()
            .filter(|entry| {
                entry.header.track == 1
                    && entry.header.generation == generation
                    && entry.header.sequence > lost_sequence
                    && entry.header.flags & 1 != 0
            })
            .map(|entry| entry.header.sequence)
            .min();
        self.entries.retain(|entry| {
            entry.header.track != 1
                || entry.header.generation == generation
                    && (entry.header.flags & 1 != 0 && entry.header.sequence != lost_sequence
                        || replacement.is_some_and(|sequence| entry.header.sequence >= sequence))
        });
        replacement
    }
    /// Exact retained ownership, also used when cancelling accepted plaintext
    /// in the transport. A single sequence frontier cannot represent an older
    /// independent AU plus a separate newer unbroken dependency chain.
    pub fn contains_video_access_unit(&self, record: &Record) -> bool {
        record.track == 1
            && self
                .entries
                .iter()
                .any(|entry| same_object(&entry.header, record))
    }
    /// Drop one newly published dependent AU while an IDR request is active.
    /// The source parser and sequence continue advancing; only stale payload
    /// ownership is removed from the realtime send queue.
    pub fn discard_video_sequence(&mut self, generation: u64, sequence: u64) {
        self.entries.retain(|entry| {
            entry.header.track != 1
                || entry.header.generation != generation
                || entry.header.sequence != sequence
        });
    }
    /// Move the exact, wholly-unsent recovery IDR onto the reliable media
    /// stream.  Refuse dependent, audio, already-admitted, or repair-pending
    /// entries so a peer cannot turn ordinary video into reliable backlog.
    pub(crate) fn mark_reliable_recovery(
        &mut self,
        generation: u64,
        sequence: u64,
    ) -> Result<(), Failure> {
        let entry = self
            .entries
            .iter_mut()
            .find(|entry| {
                entry.header.generation == generation
                    && entry.header.track == 1
                    && entry.header.sequence == sequence
            })
            .ok_or(Failure::Protocol)?;
        if entry.header.kind != 5
            || entry.header.flags & 1 == 0
            || entry.header.flags & crate::wire::RELIABLE_RECOVERY_FLAG != 0
            || entry.next != 0
            || entry.requested.iter().any(|requested| *requested)
        {
            return Err(Failure::Protocol);
        }
        entry.header.flags |= crate::wire::RELIABLE_RECOVERY_FLAG;
        entry.parity = None;
        entry.parity_sent = true;
        entry.header.lifetime_us = (crate::RELIABLE_RECOVERY_AU_LIFETIME / 1000) as u32;
        entry.deadline = entry
            .queued
            .checked_add(crate::RELIABLE_RECOVERY_AU_LIFETIME)
            .ok_or(Failure::Clock)?;
        entry
            .header
            .with_body(entry.bytes.as_slice()[..entry.bytes.len().min(BODY)].to_vec())
            .validate()
            .map_err(|_| Failure::Protocol)
    }
    /// The selected recovery IDR is a cross-lane ordering fence until its
    /// consumer ACK removes the source entry. Newer video must not overtake
    /// it on the datagram lane and invalidate the partial IDR at the receiver.
    pub(crate) fn reliable_recovery_fence(&self, generation: u64) -> Option<u64> {
        self.entries
            .iter()
            .filter(|entry| {
                entry.header.generation == generation
                    && entry.header.track == 1
                    && entry.header.kind == 5
                    && entry.header.flags & crate::wire::RELIABLE_RECOVERY_FLAG != 0
            })
            .map(|entry| entry.header.sequence)
            .min()
    }
    /// Retire only ordinary video work older than a newly published recovery
    /// IDR. An earlier reliable recovery remains source-owned until its exact
    /// consumer ACK; a later recovery request may legitimately be needed for
    /// the dependent gap that accumulated while the first IDR was in flight.
    /// The caller must prove the producer/request association. Already accepted
    /// transport datagrams remain transport-owned.
    #[doc(hidden)]
    pub fn supersede_video_before(&mut self, generation: u64, sequence: u64) {
        self.entries.retain(|e| {
            e.header.track != 1
                || e.header.generation != generation
                || e.header.sequence >= sequence
                || e.header.flags & crate::wire::RELIABLE_RECOVERY_FLAG != 0
        });
    }
    pub fn next_wakeup(&self) -> Option<u64> {
        self.entries.iter().map(|e| e.deadline).min()
    }
}

#[cfg(test)]
mod cache_realtime_tests {
    use super::*;

    fn access_unit(track: u8, sequence: u64, independent: bool, bytes: usize) -> Record {
        Record {
            kind: 5,
            track,
            flags: 2 | u16::from(independent),
            generation: 1,
            epoch: 1,
            config: 1,
            sequence,
            pts: sequence * 16_667,
            total: 0,
            index: 0,
            count: 0,
            age_us: 0,
            lifetime_us: 0,
            body: vec![sequence as u8; bytes],
        }
    }

    #[test]
    fn newer_independent_video_supersedes_unsent_older_video_without_dropping_audio() {
        let mut cache = Cache::new();
        cache
            .insert_with_lifetime(access_unit(1, 1, false, BODY * 3), 1, AU_LIFETIME)
            .unwrap();
        cache
            .insert_with_lifetime(access_unit(2, 1, false, 128), 1, AU_LIFETIME)
            .unwrap();

        let (old, _, repair) = cache.next(2).unwrap();
        assert_eq!(
            (old.track, old.sequence, old.index, repair),
            (1, 1, 0, false)
        );
        cache.accepted(&old, false).unwrap();

        cache
            .insert_with_lifetime(
                access_unit(1, 2, true, BODY * 4),
                3,
                crate::INDEPENDENT_AU_LIFETIME,
            )
            .unwrap();
        cache.supersede_video_before(1, 2);

        assert_eq!(
            cache.usage().0,
            2,
            "the recovery IDR must replace stale video ownership while retaining audio"
        );
        let (audio, _, repair) = cache.next(4).unwrap();
        assert_eq!((audio.track, audio.sequence, repair), (2, 1, false));
        cache.accepted(&audio, false).unwrap();
        let (recovery, _, repair) = cache.next(4).unwrap();
        assert_eq!(
            (recovery.track, recovery.sequence, recovery.index, repair),
            (1, 2, 0, false),
            "obsolete video fragments must not delay the newer independent AU"
        );
    }

    #[test]
    fn transport_loss_discards_whole_video_aus_but_keeps_audio_live() {
        let mut cache = Cache::new();
        for sequence in 1..=3 {
            cache
                .insert_with_lifetime(access_unit(1, sequence, false, BODY * 2), 1, AU_LIFETIME)
                .unwrap();
        }
        cache
            .insert_with_lifetime(access_unit(2, 1, false, 128), 1, AU_LIFETIME)
            .unwrap();

        cache.discard_video();

        assert_eq!(cache.usage().0, 1);
        let (audio, _, repair) = cache.next(2).unwrap();
        assert_eq!((audio.track, audio.sequence, repair), (2, 1, false));
        cache.accepted(&audio, false).unwrap();
        cache
            .insert_with_lifetime(access_unit(1, 4, false, BODY), 3, AU_LIFETIME)
            .unwrap();
        cache.discard_video_sequence(1, 4);
        assert!(cache.entries.iter().all(|entry| entry.header.track == 2));
    }

    #[test]
    fn recovery_preserves_the_first_newer_independent_chain() {
        let mut cache = Cache::new();
        for (sequence, independent) in [(10, false), (11, false), (12, true), (13, false)] {
            cache
                .insert_with_lifetime(
                    access_unit(1, sequence, independent, BODY),
                    1,
                    if independent {
                        crate::INDEPENDENT_AU_LIFETIME
                    } else {
                        AU_LIFETIME
                    },
                )
                .unwrap();
        }
        cache
            .insert_with_lifetime(access_unit(2, 1, false, 128), 1, AU_LIFETIME)
            .unwrap();

        assert_eq!(cache.discard_video_before_recovery_key(1, 10), Some(12));
        assert_eq!(
            cache.usage().0,
            3,
            "key, its dependent successor, and audio remain"
        );
        let (key, _, _) = cache.next(2).unwrap();
        assert_eq!((key.track, key.sequence, key.flags & 1), (1, 12, 1));
    }

    #[test]
    fn successor_loss_preserves_only_independent_prefix_and_newer_valid_chain() {
        let mut cache = Cache::new();
        for (sequence, independent) in [
            (9, true),
            (10, false),
            (11, false),
            (12, false),
            (13, true),
            (14, false),
        ] {
            cache
                .insert_with_lifetime(
                    access_unit(1, sequence, independent, BODY),
                    1,
                    if independent {
                        crate::INDEPENDENT_AU_LIFETIME
                    } else {
                        AU_LIFETIME
                    },
                )
                .unwrap();
        }
        cache
            .insert_with_lifetime(access_unit(2, 1, false, 128), 1, AU_LIFETIME)
            .unwrap();
        cache.expire(2);
        assert_eq!(cache.discard_video_before_recovery_key(1, 11), Some(13));
        let retained: Vec<_> = cache
            .entries
            .iter()
            .map(|e| (e.header.track, e.header.sequence))
            .collect();
        assert_eq!(retained, [(1, 9), (1, 13), (1, 14), (2, 1)]);
        let key = cache.entries[0].header.with_body(vec![]);
        assert!(cache.contains_video_access_unit(&key));
        let mut stale = key.with_body(vec![]);
        stale.epoch += 1;
        assert!(!cache.contains_video_access_unit(&stale));
        cache.discard_video_before_recovery_key(1, 9);
        assert!(
            !cache.contains_video_access_unit(&key),
            "the lost IDR itself is never preserved"
        );
        cache.expire(crate::INDEPENDENT_AU_LIFETIME + 1);
        assert_eq!(
            cache.usage(),
            (0, 0),
            "no deadline is extended by retention"
        );
    }

    #[test]
    fn only_wholly_unsent_requested_idr_uses_bounded_reliable_media_lane() {
        use galaxybridge_quic::Lane;

        let mut cache = Cache::new();
        cache
            .insert_with_lifetime(
                access_unit(1, 20, true, BODY * 70),
                10,
                crate::INDEPENDENT_AU_LIFETIME,
            )
            .unwrap();
        cache.mark_reliable_recovery(1, 20).unwrap();
        let (recovery, deadline, repair) = cache.next(11).unwrap();
        assert_eq!(recovery.lane(), Lane::Reliable);
        assert_eq!(recovery.flags & crate::wire::RELIABLE_RECOVERY_FLAG, 4);
        assert_eq!(recovery.lifetime_us, 1_500_000);
        assert_eq!(deadline, 10 + crate::RELIABLE_RECOVERY_AU_LIFETIME);
        assert!(!repair);

        cache.accepted(&recovery, false).unwrap();
        assert_eq!(
            cache.mark_reliable_recovery(1, 20),
            Err(Failure::Protocol),
            "an AU already admitted to transport cannot change lanes"
        );

        let mut ordinary = Cache::new();
        ordinary
            .insert_with_lifetime(access_unit(1, 21, false, BODY), 10, AU_LIFETIME)
            .unwrap();
        let (delta, _, _) = ordinary.next(11).unwrap();
        assert_eq!(delta.lane(), Lane::Datagram);
        assert_eq!(
            ordinary.mark_reliable_recovery(1, 21),
            Err(Failure::Protocol),
            "a dependent AU must never enter the reliable lane"
        );
    }

    #[test]
    fn reliable_recovery_fence_lives_until_exact_consumer_ack() {
        let mut cache = Cache::new();
        let recovery = access_unit(1, 20, true, BODY + 1);
        cache
            .insert_with_lifetime(recovery.clone(), 10, crate::INDEPENDENT_AU_LIFETIME)
            .unwrap();
        cache.mark_reliable_recovery(1, 20).unwrap();
        assert_eq!(cache.reliable_recovery_fence(1), Some(20));
        assert_eq!(cache.reliable_recovery_fence(2), None);

        let mut ack = recovery;
        ack.kind = 7;
        ack.sequence = 19;
        cache.ack(&ack).unwrap();
        assert_eq!(cache.reliable_recovery_fence(1), Some(20));

        ack.sequence = 20;
        cache.ack(&ack).unwrap();
        assert_eq!(cache.reliable_recovery_fence(1), None);
    }

    #[test]
    fn later_recovery_keeps_earlier_reliable_owner_but_supersedes_ordinary_video() {
        let mut cache = Cache::new();
        for (sequence, independent) in [(20, true), (21, false), (22, true)] {
            let lifetime = if independent {
                crate::INDEPENDENT_AU_LIFETIME
            } else {
                AU_LIFETIME
            };
            cache
                .insert_with_lifetime(
                    access_unit(1, sequence, independent, BODY + 1),
                    10,
                    lifetime,
                )
                .unwrap();
        }
        cache.mark_reliable_recovery(1, 20).unwrap();
        cache.mark_reliable_recovery(1, 22).unwrap();
        cache.supersede_video_before(1, 22);

        assert_eq!(cache.reliable_recovery_fence(1), Some(20));
        assert!(cache
            .entries
            .iter()
            .any(|entry| entry.header.sequence == 20));
        assert!(!cache
            .entries
            .iter()
            .any(|entry| entry.header.sequence == 21));
        assert!(cache
            .entries
            .iter()
            .any(|entry| entry.header.sequence == 22));
    }
}

#[cfg(test)]
mod xor_parity_tests {
    use super::*;
    use galaxybridge_quic::Lane;

    fn access_unit(track: u8, bytes: Vec<u8>) -> Record {
        Record {
            kind: 5,
            track,
            flags: 2,
            generation: 1,
            epoch: 1,
            config: 1,
            sequence: 1,
            pts: 16_667,
            total: 0,
            index: 0,
            count: 0,
            age_us: 0,
            lifetime_us: 0,
            body: bytes,
        }
    }

    fn emitted(cache: &mut Cache) -> Vec<Record> {
        let mut records = vec![];
        while let Some((record, _, repair)) = cache.next(0) {
            assert!(!repair);
            cache.accepted(&record, repair).unwrap();
            records.push(record);
        }
        records
    }

    #[test]
    fn negotiated_video_parity_recovers_one_interior_or_short_final_fragment() {
        let original: Vec<u8> = (0..BODY * 3 - 37).map(|i| (i % 251) as u8).collect();
        let mut cache = Cache::with_xor_parity(true);
        cache.insert(access_unit(1, original.clone()), 0).unwrap();
        let records = emitted(&mut cache);
        assert_eq!(records.len(), 4);
        assert_eq!(
            records[..3].iter().map(|r| r.kind).collect::<Vec<_>>(),
            vec![5; 3]
        );
        assert_eq!(records[3].kind, 15);
        assert_eq!(records[3].lane(), Lane::Datagram);
        assert_eq!(records[3].body.len(), BODY);

        for (lost, parity_first) in [(1usize, false), (2usize, true)] {
            let mut receiver = Reassembler::new();
            if parity_first {
                receiver.ingest(records[3].clone(), 0).unwrap();
            }
            for (index, record) in records[..3].iter().enumerate() {
                if index != lost {
                    receiver.ingest(record.clone(), index as u64 + 1).unwrap();
                }
            }
            if !parity_first {
                receiver.ingest(records[3].clone(), 4).unwrap();
            }
            let completed = receiver
                .take(1, 1, 5)
                .expect("one missing fragment is reconstructed");
            assert_eq!(completed.bytes.as_slice(), original);
            drop(completed);
            receiver.clear();
            assert_eq!(receiver.usage(), (0, 0));
        }
    }

    #[test]
    fn parity_never_false_completes_two_losses_and_rejects_corruption_or_conflict() {
        let mut cache = Cache::with_xor_parity(true);
        cache
            .insert(access_unit(1, vec![0x5a; BODY * 3]), 0)
            .unwrap();
        let records = emitted(&mut cache);
        let mut receiver = Reassembler::new();
        receiver.ingest(records[0].clone(), 0).unwrap();
        receiver.ingest(records[3].clone(), 1).unwrap();
        assert!(
            receiver.take(1, 1, 2).is_none(),
            "two missing fragments are not reconstructable"
        );

        let mut corrupt = records[3].clone();
        corrupt.body[0] ^= 1;
        assert!(
            corrupt.validate().is_err(),
            "parity checksum rejects a corrupted body"
        );

        let mut conflict = records[3].clone();
        conflict.body[0] ^= 1;
        conflict.index = crate::wire::parity_checksum(&conflict.body);
        assert_eq!(receiver.ingest(conflict, 2), Err(Failure::Protocol));
        receiver.clear();
        assert_eq!(receiver.usage(), (0, 0));
    }

    #[test]
    fn reassembly_protocol_diagnostics_are_opt_in_and_identify_the_exact_conflict() {
        let mut cache = Cache::with_xor_parity(true);
        cache
            .insert(access_unit(1, vec![0x3c; BODY + 1]), 0)
            .unwrap();
        let records = emitted(&mut cache);

        let mut receiver = Reassembler::new();
        receiver.ingest(records[0].clone(), 0).unwrap();
        let mut conflicting_header = records[1].clone();
        conflicting_header.pts += 1;
        let scope = first_error::Scope::begin(true);
        assert_eq!(
            receiver.ingest(conflicting_header, 1),
            Err(Failure::Protocol)
        );
        let rejection = scope.observation().unwrap().rejection.unwrap();
        assert_eq!(rejection.module, 3);
        assert_eq!(rejection.used, 1 << 5, "the PTS mismatch bit must be exact");
        drop(scope);

        let mut receiver = Reassembler::new();
        receiver.ingest(records[0].clone(), 0).unwrap();
        let mut conflicting_body = records[0].clone();
        conflicting_body.body[0] ^= 1;
        let scope = first_error::Scope::begin(true);
        assert_eq!(
            receiver.ingest(conflicting_body.clone(), 1),
            Err(Failure::Protocol)
        );
        let rejection = scope.observation().unwrap().rejection.unwrap();
        assert_eq!(rejection.module, 3);
        assert_eq!(
            rejection.used, 0,
            "the duplicate fragment index is preserved"
        );
        assert_eq!(
            rejection.requested, 1,
            "this is a conflicting duplicate body"
        );
        drop(scope);

        let mut receiver = Reassembler::new();
        receiver.ingest(records[0].clone(), 0).unwrap();
        let scope = first_error::Scope::begin(false);
        assert_eq!(receiver.ingest(conflicting_body, 1), Err(Failure::Protocol));
        assert!(scope.observation().is_none());
    }

    #[test]
    fn parity_is_opt_in_video_only_and_never_wraps_reliable_recovery() {
        let mut legacy = Cache::new();
        legacy.insert(access_unit(1, vec![1; BODY + 1]), 0).unwrap();
        assert!(emitted(&mut legacy).iter().all(|record| record.kind == 5));

        let mut audio = Cache::with_xor_parity(true);
        audio.insert(access_unit(2, vec![2; BODY + 1]), 0).unwrap();
        assert!(emitted(&mut audio).iter().all(|record| record.kind == 5));

        let mut recovery = Cache::with_xor_parity(true);
        let mut key = access_unit(1, vec![3; BODY + 1]);
        key.flags |= 1;
        recovery
            .insert_with_lifetime(key, 0, crate::INDEPENDENT_AU_LIFETIME)
            .unwrap();
        recovery.mark_reliable_recovery(1, 1).unwrap();
        let records = emitted(&mut recovery);
        assert!(records.iter().all(|record| {
            record.kind == 5
                && record.flags & crate::wire::RELIABLE_RECOVERY_FLAG != 0
                && record.lane() == Lane::Reliable
        }));
    }

    #[test]
    fn parity_follows_its_au_before_a_newer_video_original() {
        let mut cache = Cache::with_xor_parity(true);
        cache.insert(access_unit(1, vec![1; BODY + 1]), 0).unwrap();
        let mut newer = access_unit(1, vec![2; BODY + 1]);
        newer.sequence = 2;
        cache.insert(newer, 0).unwrap();
        for expected in 0..2 {
            let (record, _, repair) = cache.next(0).unwrap();
            assert_eq!(
                (record.kind, record.sequence, record.index, repair),
                (5, 1, expected, false)
            );
            cache.accepted(&record, repair).unwrap();
        }
        let (parity, _, repair) = cache.next(0).unwrap();
        assert_eq!(
            (parity.kind, parity.sequence, repair),
            (crate::wire::XOR_PARITY_KIND, 1, false)
        );
        cache.accepted(&parity, repair).unwrap();
        let (newer, _, repair) = cache.next(0).unwrap();
        assert_eq!(
            (newer.kind, newer.sequence, newer.index, repair),
            (5, 2, 0, false)
        );
    }
}

#[derive(Clone, Debug)]
pub struct OutputLease {
    pub owner: u64,
    pub token: u64,
    pub record: Record,
    pub bytes: Bytes,
    pub configuration: Option<Bytes>,
    pub deadline: u64,
}
/// Accounting for foreign allocations. Dropping the final ticket is the only
/// release signal; owner retirement cannot make those allocations disappear.
pub struct ForeignCopyCharge {
    _parts: [Option<CopyReservation>; 2],
}
/// One independently owned payload copy. AU original bytes remain owned by
/// the event/borrow, not this ticket. Metadata and real configuration stay pinned.
pub struct PayloadCopyCharge {
    _charge: CopyReservation,
    _original: Option<Bytes>,
    _configuration: Option<Bytes>,
    owner: u64,
    token: u64,
}
struct CopyReservation {
    used: Arc<Mutex<(usize, usize)>>,
    bytes: usize,
    configuration: Option<(usize, Arc<Mutex<[usize; 3]>>)>,
    separate_slot: Option<Arc<Mutex<[usize; 2]>>>,
    transferred: bool,
}
impl Drop for CopyReservation {
    fn drop(&mut self) {
        let mut used = self.used.lock().unwrap();
        if self.separate_slot.is_none() {
            used.0 -= 1;
        }
        used.1 -= self.bytes;
        drop(used);
        if let Some(slots) = &self.separate_slot {
            slots.lock().unwrap()[usize::from(self.transferred)] -= 1;
        }
        if let Some((track, counts)) = &self.configuration {
            counts.lock().unwrap()[*track] -= 1;
        }
    }
}
impl Pool {
    /// Only the new AU payload path has eight separate copy slots. Bytes still
    /// consume this exact pool's shared16MiB; originals/composite copies retain
    /// their original eight admission slots and existing version semantics.
    fn reserve_payload_au_copy(&self, bytes: usize) -> Result<CopyReservation, Failure> {
        let mut slots = self.payload_copy_slots.lock().unwrap();
        let mut used = self.used.lock().unwrap();
        if slots[0] >= 8 || bytes > self.bytes.saturating_sub(used.1) {
            first_error::reject(1, line!(), slots[0], 8, bytes, used.1, self.bytes);
            return Err(Failure::Capacity);
        }
        slots[0] += 1;
        used.1 += bytes;
        Ok(CopyReservation {
            used: self.used.clone(),
            bytes,
            configuration: None,
            separate_slot: Some(self.payload_copy_slots.clone()),
            transferred: false,
        })
    }
    pub(crate) fn reserve_pending_metadata(
        &self,
        bytes: usize,
    ) -> Result<ForeignCopyCharge, Failure> {
        Ok(ForeignCopyCharge {
            _parts: [Some(self.reserve_copy(bytes, None)?), None],
        })
    }
    fn reserve_copy(
        &self,
        bytes: usize,
        configuration: Option<u8>,
    ) -> Result<CopyReservation, Failure> {
        let mut counts = self.configurations.lock().unwrap();
        if let Some(track) = configuration {
            if !matches!(track, 1 | 2) || counts[track as usize] >= 2 {
                first_error::reject(
                    1,
                    line!(),
                    counts.get(track as usize).copied().unwrap_or(0),
                    2,
                    1,
                    0,
                    0,
                );
                return Err(Failure::Capacity);
            }
        }
        let mut used = self.used.lock().unwrap();
        if used.0 >= self.slots || bytes > self.bytes.saturating_sub(used.1) {
            first_error::reject(1, line!(), used.0, self.slots, bytes, used.1, self.bytes);
            return Err(Failure::Capacity);
        }
        used.0 += 1;
        used.1 += bytes;
        if let Some(track) = configuration {
            counts[track as usize] += 1;
        }
        Ok(CopyReservation {
            used: self.used.clone(),
            bytes,
            configuration: configuration.map(|t| (t as usize, self.configurations.clone())),
            separate_slot: None,
            transferred: false,
        })
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RecoveryContext {
    pub track: u8,
    pub epoch: u32,
    pub config: u32,
    pub sequence: u64,
    pub deadline: u64,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Disposition {
    RecoveryRequired {
        track: u8,
        epoch: u32,
        sequence: u64,
    },
    AudioGap {
        sequence: u64,
    },
    Retired(Failure),
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MediaOutcome {
    Admitted,
    DeclinedPressure,
    DeclinedExpired,
    SkippedDependent,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MediaDeclineReason {
    Pressure = 1,
    Expired = 2,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct MediaHealth {
    pub track: u32,
    pub state: u32,
    pub reason: u32,
    pub epoch: u32,
    pub config: u32,
    pub attempt: u32,
    pub revision: u64,
    pub episode: u64,
    pub next_deadline: u64,
    pub admitted_sequence: u64,
    pub declined: u64,
    pub skipped: u64,
    pub admitted_input_dropped: u64,
    pub output_dropped: u64,
    pub output_pressure: u32,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum HeldState {
    Pending,
    Committed,
    Declined,
}
struct Episode {
    id: u64,
    sequence: u64,
    anchor: Option<u64>,
    attempt: u32,
    active_cutoff: Option<u64>,
    exhausted: bool,
}
struct ConfigVersion {
    epoch: u32,
    version: u32,
    bytes: Bytes,
    parsed: crate::codec::Configuration,
}
struct Track {
    codec: Option<crate::codec::Codec>,
    disabled: bool,
    epoch: u32,
    version: u32,
    next: u64,
    configs: Vec<ConfigVersion>,
    await_idr: bool,
    pts: Option<u64>,
    gap: Option<Gap>,
    watermark: u64,
    // Exact early observed ranges plus the newest conservative tail, bounded
    // independently of media bytes. When progress stalls for more than 32
    // watermarks, the tail is replaced instead of retiring a valid session.
    watermark_ranges: std::collections::VecDeque<(u64, u64)>,
    skipped_through: u64,
    discard_through: u64,
    // Loss behind an owned recovery AU cannot advance discard_through over
    // that AU. Remember a conservative interval instead, with holes only for
    // genuinely live resident assemblies. Constant space for any loss burst;
    // removing bytes must never grant a delayed duplicate a fresh deadline.
    deferred_loss: Option<(u64, u64)>,
    health: MediaHealth,
    published_health: MediaHealth,
    episode: Option<Episode>,
    native_input_loss: u64,
    native_output: u64,
    native_counts: [u64; 2],
    // Exact current-publication codec-qualified AU, advanced only on commit.
    // Neither a wire key flag nor merely offered output establishes this fence.
    committed_independent: u64,
}
impl Default for Track {
    fn default() -> Self {
        Self {
            codec: None,
            disabled: false,
            epoch: 0,
            version: 0,
            next: 1,
            configs: vec![],
            await_idr: true,
            pts: None,
            gap: None,
            watermark: 0,
            watermark_ranges: std::collections::VecDeque::with_capacity(32),
            skipped_through: 0,
            discard_through: 0,
            deferred_loss: None,
            health: MediaHealth::default(),
            published_health: MediaHealth::default(),
            episode: None,
            native_input_loss: 0,
            native_output: 0,
            native_counts: [0; 2],
            committed_independent: 0,
        }
    }
}
impl Track {
    fn deferred_loss_contains(&self, sequence: u64) -> bool {
        self.deferred_loss
            .is_some_and(|(first, last)| first <= sequence && sequence <= last)
    }
    fn skip_through(&mut self, sequence: u64) -> u64 {
        if sequence < self.next || sequence <= self.skipped_through {
            return 0;
        }
        let start = self.next.max(self.skipped_through.saturating_add(1));
        self.skipped_through = sequence;
        sequence - start + 1
    }
}
struct Gap {
    sequence: u64,
    cutoff: u64,
    reported: bool,
}
struct Metadata {
    record: Record,
    bytes: Bytes,
    deadline: u64,
}
struct Held {
    lease: OutputLease,
    state: HeldState,
    republished: bool,
    copy_pressure: bool,
    qualified_independent: bool,
}
pub struct Receiver {
    context: crate::Context,
    owner: u64,
    serial: u64,
    last: u64,
    started: bool,
    terminal: Option<Failure>,
    tracks: [Track; 3],
    meta_pool: Pool,
    metadata: std::collections::VecDeque<Metadata>,
    assembly: Option<Assembly>,
    held: Vec<Held>,
    media: Reassembler,
    recovery_au: Option<Completed>,
    feedback: std::collections::VecDeque<(Record, u64)>,
    dispositions: std::collections::VecDeque<Disposition>,
    pub control: crate::control::Writer,
    control_geometry: Option<(u32, u32, u32)>,
    skipped_video: u64,
    episode_serial: u64,
    #[doc(hidden)]
    pub recovery_trace: Option<Box<recovery_trace::Trace>>,
}
static OWNER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
impl Receiver {
    pub fn set_repair_margin(&mut self, margin: Option<u64>) {
        self.media.set_repair_margin(margin);
    }
    #[doc(hidden)]
    pub fn trace_event(&mut self, kind: u64, r: &Record, request: u64, a: u64, b: u64) {
        if let Some(t) = self.recovery_trace.as_mut() {
            t.push(recovery_trace::Event([
                kind,
                r.track as u64,
                r.epoch as u64,
                r.config as u64,
                r.sequence,
                request,
                a,
                b,
            ]));
        }
    }
    fn trace_expiry(
        &mut self,
        r: &Record,
        origin: u64,
        deadline: u64,
        received: u64,
        count: u64,
        now: u64,
    ) {
        if self.recovery_trace.is_none() || r.track != 1 {
            return;
        }
        let track = &self.tracks[1];
        if r.epoch != track.epoch
            || r.config != track.version
            || r.sequence < track.next
            || r.sequence <= track.discard_through
        {
            return;
        }
        let episode = track
            .episode
            .as_ref()
            .map_or(self.episode_serial.saturating_add(1), |e| e.id);
        let first = self.recovery_trace.as_ref().unwrap().loss_episode != episode;
        if first {
            self.recovery_trace.as_mut().unwrap().loss_episode = episode;
            self.trace_event(1, r, episode, origin, now.saturating_sub(deadline));
            self.trace_event(2, r, episode, r.age_us as u64, deadline);
            self.trace_event(3, r, episode, received, count);
            let usage = self.media.usage();
            self.trace_event(4, r, episode, usage.0 as u64, usage.1 as u64);
        } else {
            self.trace_event(5, r, episode, origin, now.saturating_sub(deadline));
        }
    }
    #[doc(hidden)]
    pub fn trace_source_au(
        &mut self,
        r: &Record,
        independent: bool,
        size: usize,
        outcome: u64,
        started: u64,
        now: u64,
        lifetime: u64,
    ) {
        let Some(t) = self.recovery_trace.as_mut() else {
            return;
        };
        if r.track != 1 || !independent {
            return;
        }
        for selected in &mut t.selected {
            if selected[0] != 0
                && selected[1] == r.epoch as u64
                && selected[2] == r.config as u64
                && selected[3] == 0
            {
                selected[3] = r.sequence;
            }
        }
        let ids = t
            .selected
            .map(|s| if s[3] == r.sequence { s[0] } else { 0 });
        for id in ids {
            if id != 0 {
                self.trace_event(10, r, id, size as u64, outcome);
                self.trace_event(12, r, id, started, now);
                self.trace_event(11, r, id, 0, size.div_ceil(BODY) as u64);
                // The pre-cache record still contains its default lifetime. Observe
                // the actual chosen cache budget, at most three times per owner.
                let trace = self.recovery_trace.as_mut().unwrap();
                if trace.source_class_records < 3 {
                    trace.source_class_records += 1;
                    self.trace_event(13, r, id, (r.flags & 1) as u64, lifetime / 1000);
                }
            }
        }
    }
    #[doc(hidden)]
    pub fn trace_fragment_admission(
        &mut self,
        epoch: u32,
        config: u32,
        sequence: u64,
        count: u64,
        accepted: bool,
    ) {
        let Some(t) = self.recovery_trace.as_mut() else {
            return;
        };
        for i in 0..3 {
            let s = &mut t.selected[i];
            if s[0] != 0 && s[1] == epoch as u64 && s[2] == config as u64 && s[3] == sequence {
                if accepted {
                    s[4] = s[4].saturating_add(1);
                }
                let event = recovery_trace::Event([
                    11,
                    1,
                    epoch as u64,
                    config as u64,
                    sequence,
                    s[0],
                    s[4],
                    count,
                ]);
                t.update(event);
            }
        }
    }
    pub fn owner_id(&self) -> u64 {
        self.owner
    }
    pub fn media_eligibility(
        &mut self,
        lease: &OutputLease,
        now: u64,
    ) -> Result<MediaOutcome, Failure> {
        self.tick(now)?;
        if lease.owner != self.owner || !self.current_output(&lease.record) {
            return Err(Failure::Retired);
        }
        if lease.record.kind != 5 {
            self.check_output(lease, now)?;
            return Ok(MediaOutcome::Admitted);
        }
        let Some(h) = self.held.iter().find(|h| h.lease.token == lease.token) else {
            first_error::reject(
                1,
                line!(),
                0,
                1,
                lease.record.kind as usize,
                lease.record.sequence as usize,
                lease.token as usize,
            );
            return Err(Failure::Protocol);
        };
        if h.state == HeldState::Committed {
            first_error::reject(
                1,
                line!(),
                2,
                1,
                lease.record.kind as usize,
                lease.record.sequence as usize,
                lease.token as usize,
            );
            return Err(Failure::Protocol);
        }
        if now >= h.lease.deadline {
            return Ok(MediaOutcome::DeclinedExpired);
        }
        if h.state != HeldState::Pending {
            first_error::reject(
                1,
                line!(),
                3,
                1,
                lease.record.kind as usize,
                lease.record.sequence as usize,
                lease.token as usize,
            );
            return Err(Failure::Protocol);
        }
        Ok(MediaOutcome::Admitted)
    }
    pub fn native_copy_preflight(
        &mut self,
        lease: &OutputLease,
        copy: Option<&PayloadCopyCharge>,
        now: u64,
    ) -> Result<MediaOutcome, Failure> {
        let eligibility = self.media_eligibility(lease, now)?;
        if eligibility != MediaOutcome::Admitted {
            return Ok(eligibility);
        }
        if lease.record.kind != 5 {
            return Err(Failure::Protocol);
        }
        if let Some(copy) = copy {
            if copy.owner != self.owner
                || copy.token != lease.token
                || copy._charge.transferred
                || copy._charge.separate_slot.is_none()
            {
                return Err(Failure::Protocol);
            }
            if self.payload_copy_usage()[1] >= 64 {
                return self.copy_pressure(lease);
            }
        } else {
            let used = self.media.pool.usage();
            if self.payload_copy_usage()[0] >= 8 || lease.bytes.len() > 16 * 1024 * 1024 - used.1 {
                return self.copy_pressure(lease);
            }
        }
        Ok(MediaOutcome::Admitted)
    }
    fn copy_pressure(&mut self, lease: &OutputLease) -> Result<MediaOutcome, Failure> {
        self.held
            .iter_mut()
            .find(|h| h.lease.token == lease.token)
            .ok_or(Failure::Protocol)?
            .copy_pressure = true;
        Ok(MediaOutcome::DeclinedPressure)
    }
    pub fn commit_native_media(
        &mut self,
        lease: &OutputLease,
        copy: &mut PayloadCopyCharge,
        now: u64,
    ) -> Result<MediaOutcome, Failure> {
        let result = self.native_copy_preflight(lease, Some(copy), now)?;
        if result == MediaOutcome::Admitted {
            self.consumer_commit_payload_copy(lease, copy, now)?;
        }
        Ok(result)
    }
    pub fn reserve_native_media_payload(
        &mut self,
        lease: &OutputLease,
        now: u64,
    ) -> Result<(MediaOutcome, Option<PayloadCopyCharge>), Failure> {
        let outcome = self.native_copy_preflight(lease, None, now)?;
        let copy = if outcome == MediaOutcome::Admitted {
            Some(self.reserve_output_payload_copy(lease, now)?)
        } else {
            None
        };
        Ok((outcome, copy))
    }
    pub fn reserve_output_payload_copy(
        &mut self,
        lease: &OutputLease,
        now: u64,
    ) -> Result<PayloadCopyCharge, Failure> {
        self.check_output(lease, now)?;
        let pool = if lease.record.kind == 5 {
            &self.media.pool
        } else {
            &self.meta_pool
        };
        let charge = if lease.record.kind == 5 {
            pool.reserve_payload_au_copy(lease.bytes.len())?
        } else {
            pool.reserve_copy(lease.bytes.len(), None)?
        };
        Ok(PayloadCopyCharge {
            _charge: charge,
            _original: (lease.record.kind != 5).then(|| lease.bytes.clone()),
            _configuration: lease.configuration.clone(),
            owner: self.owner,
            token: lease.token,
        })
    }
    /// Atomic native AU admission: validate destination credit BEFORE the
    /// existing fresh commit. No payload rewrite/allocation or deadline renewal.
    /// Only this exclusive receiver can increase stored tickets; foreign drops
    /// only decrease counts, so capacity cannot worsen between these operations.
    pub fn consumer_commit_payload_copy(
        &mut self,
        lease: &OutputLease,
        copy: &mut PayloadCopyCharge,
        now: u64,
    ) -> Result<(), Failure> {
        if self.terminal.is_some() {
            return Err(Failure::Retired);
        }
        if lease.owner != self.owner
            || copy.owner != self.owner
            || copy.token != lease.token
            || lease.record.kind != 5
            || copy._charge.transferred
        {
            return Err(Failure::Protocol);
        }
        let slots = copy
            ._charge
            .separate_slot
            .as_ref()
            .ok_or(Failure::Protocol)?;
        let stored = slots.lock().unwrap()[1];
        if stored >= 64 {
            first_error::reject(1, line!(), stored, 64, 1, 0, 0);
            return Err(Failure::Capacity);
        }
        self.consumer_commit(lease, now)?;
        let mut counts = slots.lock().unwrap();
        counts[0] -= 1;
        counts[1] += 1;
        copy._charge.transferred = true;
        Ok(())
    }
    pub fn payload_copy_usage(&self) -> [usize; 2] {
        *self.media.pool.payload_copy_slots.lock().unwrap()
    }
    pub fn reserve_output_copy(
        &mut self,
        lease: &OutputLease,
        now: u64,
    ) -> Result<ForeignCopyCharge, Failure> {
        self.check_output(lease, now)?;
        let pool = if lease.record.kind == 5 {
            &self.media.pool
        } else {
            &self.meta_pool
        };
        let primary = pool.reserve_copy(
            lease.bytes.len(),
            (lease.record.kind == 4).then_some(lease.record.track),
        )?;
        let config = if let Some(bytes) = &lease.configuration {
            Some(
                self.meta_pool
                    .reserve_copy(bytes.len(), Some(lease.record.track))?,
            )
        } else {
            None
        };
        Ok(ForeignCopyCharge {
            _parts: [Some(primary), config],
        })
    }
    pub fn recovery_context(&self, disposition: Disposition) -> Result<RecoveryContext, Failure> {
        if self.terminal.is_some() {
            return Err(Failure::Retired);
        }
        let Disposition::RecoveryRequired {
            track: 1,
            epoch,
            sequence,
        } = disposition
        else {
            return Err(Failure::Protocol);
        };
        let t = &self.tracks[1];
        let g = t.gap.as_ref().ok_or(Failure::Retired)?;
        if epoch != t.epoch
            || sequence != g.sequence
            || !g.reported
            || t.version == 0
            || self.last >= g.cutoff
        {
            return Err(Failure::Retired);
        }
        Ok(RecoveryContext {
            track: 1,
            epoch,
            config: t.version,
            sequence,
            deadline: g.cutoff,
        })
    }
    pub fn new(context: crate::Context) -> Result<Self, Failure> {
        Self::with_pool(context, Pool::new(64, 256 * 1024))
    }
    pub(crate) fn with_pool(context: crate::Context, meta_pool: Pool) -> Result<Self, Failure> {
        let owner = OWNER
            .fetch_update(
                std::sync::atomic::Ordering::Relaxed,
                std::sync::atomic::Ordering::Relaxed,
                |v| v.checked_add(1),
            )
            .map_err(|_| Failure::Capacity)?;
        Ok(Self {
            context,
            owner,
            serial: 0,
            last: 0,
            started: false,
            terminal: None,
            tracks: std::array::from_fn(|_| Track::default()),
            meta_pool,
            metadata: std::collections::VecDeque::new(),
            assembly: None,
            held: vec![],
            media: Reassembler::new(),
            recovery_au: None,
            feedback: std::collections::VecDeque::new(),
            dispositions: std::collections::VecDeque::new(),
            control: crate::control::Writer::new(1),
            control_geometry: None,
            skipped_video: 0,
            episode_serial: 0,
            recovery_trace: None,
        })
    }
    pub fn terminal(&self) -> Option<Failure> {
        self.terminal
    }
    pub(crate) fn bind_control_geometry(
        &mut self,
        epoch: u32,
        width: u32,
        height: u32,
    ) -> Result<(), Failure> {
        if epoch == 0 || width == 0 || height == 0 {
            return Err(Failure::Protocol);
        }
        if self.control_geometry == Some((epoch, width, height)) {
            return Ok(());
        }
        if self
            .control_geometry
            .is_some_and(|(old, _, _)| epoch <= old)
        {
            return Err(Failure::Protocol);
        }
        // The control writer already has an epoch before video is known. Its
        // first same-epoch geometry is initialization, not cancellation of
        // valid initial non-positional commands or their outstanding writes.
        let initializing = self.control_geometry.is_none() && self.control.epoch() == epoch;
        if !initializing {
            if let Err(reason) = self.control.change_epoch(epoch) {
                self.retire(reason);
                return Err(reason);
            }
            // No external cancellation drainer is attached to this receiver.
            // Preserve captured ownership but fail explicitly instead of
            // publishing new geometry with a permanently inert control sink.
            if self.control.cancellation_pending() {
                self.retire(Failure::Sink);
                return Err(Failure::Sink);
            }
        }
        self.control_geometry = Some((epoch, width, height));
        Ok(())
    }
    pub(crate) fn control_epoch(&self) -> Option<u32> {
        self.control_geometry.map(|v| v.0)
    }
    pub(crate) fn check_control_geometry(&self, r: &Record) -> Result<(), Failure> {
        r.validate().map_err(|_| Failure::Protocol)?;
        let raw = match r.kind {
            8 => &r.body[36..],
            9 => &r.body[28..],
            _ => return Err(Failure::Protocol),
        };
        let dimensions = match raw.first() {
            Some(2) if raw.len() == 32 => Some((
                crate::wire::u16_at(raw, 18) as u32,
                crate::wire::u16_at(raw, 20) as u32,
            )),
            Some(3) if raw.len() == 21 => Some((
                crate::wire::u16_at(raw, 9) as u32,
                crate::wire::u16_at(raw, 11) as u32,
            )),
            _ => None,
        };
        if let Some((width, height)) = dimensions {
            if self.control_geometry != Some((r.epoch, width, height)) {
                first_error::reject(1, line!(), 0, 0, 0, 0, 0);
                return Err(Failure::Protocol);
            }
        }
        Ok(())
    }
    pub fn usage(&self) -> ((usize, usize), (usize, usize)) {
        (self.media.usage(), self.meta_pool.usage())
    }
    pub fn skipped_video(&self) -> u64 {
        self.skipped_video
    }
    fn refresh_health(&mut self, track: u8) -> Result<(), Failure> {
        let t = &mut self.tracks[track as usize];
        let old = t.published_health;
        t.health.track = track as u32;
        t.health.epoch = t.epoch;
        t.health.config = t.version;
        t.health.episode = t.episode.as_ref().map_or(0, |e| e.id);
        t.health.attempt = t.episode.as_ref().map_or(0, |e| e.attempt);
        t.health.next_deadline = t
            .episode
            .as_ref()
            .and_then(|e| Self::episode_wakeup(e))
            .unwrap_or(0);
        if t.disabled || self.context.enabled & (1 << (track - 1)) == 0 {
            t.health.state = 4;
        } else if let Some(e) = &t.episode {
            t.health.state = if e.exhausted { 3 } else { 2 };
            if e.exhausted {
                t.health.reason = 5;
            }
        } else if t.health.output_pressure != 0 {
            t.health.state = 3;
            t.health.reason = 3;
        }
        if (
            old.state,
            old.reason,
            old.epoch,
            old.config,
            old.attempt,
            old.episode,
            old.output_pressure,
        ) != (
            t.health.state,
            t.health.reason,
            t.health.epoch,
            t.health.config,
            t.health.attempt,
            t.health.episode,
            t.health.output_pressure,
        ) {
            t.health.revision = old.revision.checked_add(1).ok_or(Failure::Clock)?;
        }
        t.published_health = t.health;
        Ok(())
    }
    pub fn media_health(&self, track: u8) -> Result<MediaHealth, Failure> {
        if !matches!(track, 1 | 2) {
            return Err(Failure::Protocol);
        }
        let mut h = self.tracks[track as usize].health;
        h.track = track as u32;
        h.admitted_sequence = self.tracks[track as usize].next.saturating_sub(1);
        if self.context.enabled & (1 << (track - 1)) == 0 {
            h.state = 4;
        }
        Ok(h)
    }
    fn episode_wakeup(e: &Episode) -> Option<u64> {
        if e.exhausted {
            return None;
        }
        if let Some(cutoff) = e.active_cutoff {
            return Some(cutoff);
        }
        e.anchor.map(|anchor| {
            anchor
                + if e.attempt < 2 {
                    500 * crate::MS
                } else {
                    1500 * crate::MS
                }
        })
    }
    fn update_episode(&mut self, now: u64) -> Result<(), Failure> {
        if let Some(e) = &mut self.tracks[1].episode {
            if let Some(anchor) = e.anchor {
                let end = anchor.checked_add(1750 * crate::MS).ok_or(Failure::Clock)?;
                if e.active_cutoff.is_some_and(|d| now >= d) {
                    e.active_cutoff = None;
                }
                if now >= end {
                    e.exhausted = true;
                    e.active_cutoff = None;
                } else if now >= anchor + 750 * crate::MS && e.attempt < 2 {
                    e.attempt = 2;
                }
            }
        }
        self.refresh_health(1)
    }
    /// Called only after the owner has room for its one bounded recovery request.
    pub fn publish_recovery(&mut self, now: u64) -> Result<Option<RecoveryContext>, Failure> {
        self.tick(now)?;
        let t = &mut self.tracks[1];
        let Some(e) = &mut t.episode else {
            return Ok(None);
        };
        if e.exhausted || e.active_cutoff.is_some() {
            return Ok(None);
        }
        let cutoff = if let Some(anchor) = e.anchor {
            let (begin, end, ordinal) = if e.attempt < 2 {
                (500, 750, 2)
            } else {
                (1500, 1750, 3)
            };
            if e.attempt >= 3 || now < anchor + begin * crate::MS || now >= anchor + end * crate::MS
            {
                return Ok(None);
            }
            e.attempt = ordinal;
            anchor + end * crate::MS
        } else {
            now.checked_add(1750 * crate::MS).ok_or(Failure::Clock)?;
            e.anchor = Some(now);
            e.attempt = 1;
            now + 250 * crate::MS
        };
        e.active_cutoff = Some(cutoff);
        let context = RecoveryContext {
            track: 1,
            epoch: t.epoch,
            config: t.version,
            sequence: e.sequence,
            deadline: cutoff,
        };
        self.refresh_health(1)?;
        Ok(Some(context))
    }
    pub fn recovery_current(&self, epoch: u32, config: u32, sequence: u64) -> bool {
        let t = &self.tracks[1];
        t.epoch == epoch
            && t.version == config
            && t.episode.as_ref().is_some_and(|e| e.sequence == sequence)
    }
    pub fn media_retry(&mut self, expected: u64, now: u64) -> Result<(), Failure> {
        self.tick(now)?;
        let t = &mut self.tracks[1];
        let e = t.episode.as_mut().ok_or(Failure::Protocol)?;
        if e.id != expected || !e.exhausted {
            return Err(Failure::Protocol);
        }
        self.episode_serial = self.episode_serial.checked_add(1).ok_or(Failure::Clock)?;
        e.id = self.episode_serial;
        e.anchor = None;
        e.attempt = 0;
        e.exhausted = false;
        e.active_cutoff = None;
        self.refresh_health(1)
    }
    pub fn native_media_status(
        &mut self,
        track: u8,
        epoch: u32,
        config: u32,
        input_loss: u64,
        input_drops: u64,
        output_sequence: u64,
        pressure: bool,
        drops: u64,
        now: u64,
    ) -> Result<(), Failure> {
        self.tick(now)?;
        if !matches!(track, 1 | 2) {
            return Err(Failure::Protocol);
        }
        let t = &mut self.tracks[track as usize];
        if epoch < t.epoch || epoch == t.epoch && config < t.version {
            return Ok(());
        }
        if epoch != t.epoch
            || config != t.version
            || input_loss >= t.next
            || output_sequence >= t.next
        {
            return Err(Failure::Protocol);
        };
        if input_drops > input_loss || drops > output_sequence {
            return Err(Failure::Protocol);
        };
        let lost = input_loss > t.native_input_loss;
        let current_loss = lost && (track != 1 || input_loss >= t.committed_independent);
        if lost {
            t.native_input_loss = input_loss;
            if input_drops < t.native_counts[0] {
                return Err(Failure::Protocol);
            };
            t.health.admitted_input_dropped = t
                .health
                .admitted_input_dropped
                .checked_add(input_drops - t.native_counts[0])
                .ok_or(Failure::Clock)?;
            t.native_counts[0] = input_drops;
            if current_loss {
                t.health.reason = 3;
                t.health.state = 3;
            }
        }
        if output_sequence > t.native_output {
            t.native_output = output_sequence;
            t.health.output_pressure = if pressure {
                if track == 1 {
                    6
                } else {
                    7
                }
            } else {
                0
            };
            if drops < t.native_counts[1] {
                return Err(Failure::Protocol);
            };
            t.health.output_dropped = t
                .health
                .output_dropped
                .checked_add(drops - t.native_counts[1])
                .ok_or(Failure::Clock)?;
            t.native_counts[1] = drops;
            if !pressure && t.episode.is_none() {
                t.health.state = 1;
                t.health.reason = 0;
            }
        }
        if current_loss {
            let r = Record {
                kind: 5,
                track,
                flags: 2,
                generation: self.context.generation,
                epoch,
                config,
                sequence: input_loss,
                pts: 0,
                total: 0,
                index: 0,
                count: 0,
                age_us: 0,
                lifetime_us: 120000,
                body: vec![],
            };
            self.lost_inner(&r, now, true)?;
        }
        self.refresh_health(track)
    }
    pub fn decline_output(
        &mut self,
        lease: &OutputLease,
        reason: MediaDeclineReason,
        now: u64,
    ) -> Result<(), Failure> {
        if self.terminal.is_some() || lease.owner != self.owner {
            return Err(Failure::Retired);
        }
        if lease.record.kind != 5 || !self.current_output(&lease.record) {
            return Err(Failure::Protocol);
        }
        let h = self
            .held
            .iter_mut()
            .find(|h| h.lease.token == lease.token)
            .ok_or(Failure::Protocol)?;
        if h.state != HeldState::Pending {
            return Err(Failure::Protocol);
        }
        if reason == MediaDeclineReason::Expired && now < h.lease.deadline {
            return Err(Failure::Protocol);
        }
        if reason == MediaDeclineReason::Expired {
            self.trace_expiry(
                &lease.record,
                6,
                lease.deadline,
                lease.record.count as u64,
                lease.record.count as u64,
                now,
            );
        }
        let h = self
            .held
            .iter_mut()
            .find(|h| h.lease.token == lease.token)
            .unwrap();
        h.state = HeldState::Declined;
        let pressure = if h.copy_pressure { 2 } else { 3 };
        self.record_loss(
            &lease.record,
            if reason == MediaDeclineReason::Pressure {
                pressure
            } else {
                4
            },
            now,
        )?;
        self.tick(now)
    }
    fn protected_reliable_recovery_sequence(&self) -> Option<u64> {
        self.media
            .reliable_recovery_sequence(1)
            .into_iter()
            .chain(
                self.recovery_au
                    .iter()
                    .filter(|completed| {
                        completed.record.flags & crate::wire::RELIABLE_RECOVERY_FLAG != 0
                    })
                    .map(|completed| completed.record.sequence),
            )
            .chain(
                self.held
                    .iter()
                    .filter(|held| {
                        held.state == HeldState::Pending
                            && held.lease.record.track == 1
                            && held.lease.record.flags & crate::wire::RELIABLE_RECOVERY_FLAG != 0
                    })
                    .map(|held| held.lease.record.sequence),
            )
            .min()
    }
    fn protected_recovery_sequence(&self) -> Option<u64> {
        let t = &self.tracks[1];
        // Datagram completion may be reordered: do not let a smaller, later
        // delta erase an already resident candidate IDR before its remaining
        // fragments arrive. This is only an assembly/order fence, not proof
        // of decodability: next_output still validates the complete codec AU.
        // tick removes expired entries first; no deadline or pool is extended.
        self.protected_reliable_recovery_sequence()
            .into_iter()
            .chain(
                self.media
                    .entries
                    .iter()
                    .map(|entry| {
                        (
                            &entry.header,
                            entry.deadline,
                            entry.header.flags & 1 != 0 || entry.codec_independent == Some(true),
                        )
                    })
                    // Staging occurs only after full codec qualification;
                    // the wire hint is no longer the source of that fact.
                    .chain(
                        self.recovery_au
                            .iter()
                            .map(|completed| (&completed.record, completed.deadline, true)),
                    )
                    .chain(
                        self.held
                            .iter()
                            .filter(|held| {
                                held.state == HeldState::Pending && held.lease.record.kind == 5
                            })
                            .map(|held| {
                                (
                                    &held.lease.record,
                                    held.lease.deadline,
                                    held.qualified_independent || held.lease.record.flags & 1 != 0,
                                )
                            }),
                    )
                    .filter(|(r, deadline, independent)| {
                        t.await_idr
                            && self.last < *deadline
                            && r.track == 1
                            && r.generation == self.context.generation
                            && r.epoch == t.epoch
                            && r.config == t.version
                            && r.sequence >= t.next
                            && r.sequence > t.discard_through
                            && *independent
                    })
                    .map(|(r, _, _)| r.sequence),
            )
            .min()
    }
    fn record_loss(&mut self, r: &Record, reason: u32, now: u64) -> Result<(), Failure> {
        self.record_loss_inner(r, reason, now, true)
    }
    fn admit_recovery_over_backlog(&mut self, r: &Record, now: u64) -> Result<(), Failure> {
        let t = &self.tracks[1];
        if r.track != 1
            || !t.await_idr
            || !self.media.admission_pressure(r)
            || self.protected_recovery_sequence().is_none()
        {
            return Ok(());
        }
        let cfg = t
            .configs
            .iter()
            .find(|c| c.epoch == r.epoch && c.version == r.config)
            .ok_or(Failure::Protocol)?;
        let candidate = r.flags & 1 != 0
            || r.kind == 5 && r.count == 1 && cfg.parsed.independent(&r.body, false)?;
        if !candidate {
            return Ok(());
        }
        // Capacity must not make the recovery frame lose to the dependent
        // backlog it supersedes. Keep the same pool and all original clocks.
        // A key hint grants assembly priority only: complete codec validation
        // remains mandatory before the frame can reach the consumer.
        while self.media.admission_pressure(r) {
            // Use only the point-loss path behind an existing recovery fence.
            // Without that fence record_loss may retire a whole prefix,
            // including an independent AU already leased to the consumer.
            let Some(protected) = self.protected_recovery_sequence() else {
                break;
            };
            let t = &self.tracks[1];
            let cfg = t
                .configs
                .iter()
                .find(|c| c.epoch == r.epoch && c.version == r.config)
                .ok_or(Failure::Protocol)?;
            let mut victim = None;
            for entry in &mut self.media.entries {
                let h = &entry.header;
                if h.track != 1
                    || h.epoch != r.epoch
                    || h.config != r.config
                    || h.sequence <= protected
                    || h.sequence >= r.sequence
                    || h.flags & (1 | crate::wire::RELIABLE_RECOVERY_FLAG) != 0
                    || entry.codec_independent == Some(true)
                    || self
                        .recovery_au
                        .as_ref()
                        .is_some_and(|au| au.record.track == 1 && au.record.sequence == h.sequence)
                    || self.held.iter().any(|held| {
                        held.state == HeldState::Pending
                            && held.lease.record.kind == 5
                            && held.lease.record.track == 1
                            && held.lease.record.sequence == h.sequence
                    })
                {
                    continue;
                }
                if entry.bytes.is_some() && entry.received == h.count as usize {
                    let independent = match entry.codec_independent {
                        Some(value) => value,
                        None => cfg
                            .parsed
                            .independent(entry.bytes.as_ref().unwrap().as_slice(), false)?,
                    };
                    entry.codec_independent = Some(independent);
                    if independent {
                        continue;
                    }
                }
                if victim
                    .as_ref()
                    .is_none_or(|old: &Record| h.sequence < old.sequence)
                {
                    victim = Some(h.clone());
                }
            }
            let Some(victim) = victim else { break };
            // Reuse the loss ledger, including protected-IDR deferred loss,
            // so late fragments cannot recreate the evicted AU or its TTL.
            self.record_loss(&victim, 1, now)?;
        }
        Ok(())
    }
    fn record_loss_inner(
        &mut self,
        r: &Record,
        reason: u32,
        now: u64,
        new_decline: bool,
    ) -> Result<(), Failure> {
        let protected_recovery = (r.track == 1)
            .then(|| self.protected_recovery_sequence())
            .flatten();
        if r.track == 1
            && (protected_recovery.is_some() || r.flags & crate::wire::RELIABLE_RECOVERY_FLAG != 0)
        {
            let discard_through = self.tracks[1].discard_through;
            self.trace_event(
                25,
                r,
                protected_recovery.unwrap_or(0),
                reason as u64,
                discard_through,
            );
        }
        if protected_recovery.is_some_and(|sequence| r.sequence > sequence) {
            let t = &mut self.tracks[1];
            if r.epoch != t.epoch || r.config != t.version {
                return Ok(());
            }
            if new_decline {
                t.health.declined = t.health.declined.checked_add(1).ok_or(Failure::Clock)?;
            }
            t.health.reason = reason;
            t.health.state = 3;
            t.deferred_loss = Some(t.deferred_loss.map_or((r.sequence, r.sequence), |(a, b)| {
                (a.min(r.sequence), b.max(r.sequence))
            }));
            self.media.discard_sequence(1, r.sequence);
            for held in &mut self.held {
                if held.state == HeldState::Pending
                    && held.lease.record.kind == 5
                    && held.lease.record.track == 1
                    && held.lease.record.epoch == r.epoch
                    && held.lease.record.config == r.config
                    && held.lease.record.sequence == r.sequence
                {
                    held.state = HeldState::Declined;
                }
            }
            return self.refresh_health(1);
        }
        let t = &mut self.tracks[r.track as usize];
        if r.sequence < t.next
            || r.sequence <= t.discard_through
            || r.epoch != t.epoch
            || r.config != t.version
        {
            return Ok(());
        }
        if new_decline {
            t.health.declined = t
                .health
                .declined
                .checked_add(r.sequence - t.discard_through.max(t.next.saturating_sub(1)))
                .ok_or(Failure::Clock)?;
        }
        t.discard_through = r.sequence;
        t.health.reason = reason;
        t.health.state = 3;
        self.lost(r, now)?;
        self.media.discard_through(r.track, r.sequence);
        for h in &mut self.held {
            if h.state == HeldState::Pending
                && h.lease.record.kind == 5
                && h.lease.record.track == r.track
                && h.lease.record.epoch == r.epoch
                && h.lease.record.config == r.config
                && h.lease.record.sequence <= r.sequence
            {
                h.state = HeldState::Declined;
            }
        }
        self.refresh_health(r.track)
    }
    /// A response to an earlier recovery request can cross the first response:
    /// the first IDR commits, dependent datagrams advance the source sequence,
    /// and a later producer-correlated IDR then arrives on the reliable lane.
    /// Its sequence proves a new gap, while its private flag proves that the
    /// peer did not promote ordinary video. Arm that already-arriving IDR as
    /// the bounded recovery for the new gap without issuing another request.
    fn arm_crossed_reliable_recovery(&mut self, r: &Record, now: u64) -> Result<(), Failure> {
        let remaining = (r.lifetime_us - r.age_us) as u64 * 1000;
        let active_cutoff = now
            .checked_add(crate::RELIABLE_RECOVERY_RECEIVE_LIFETIME.min(remaining))
            .ok_or(Failure::Clock)?;
        let t = &mut self.tracks[1];
        if r.track != 1
            || r.flags & crate::wire::RELIABLE_RECOVERY_FLAG == 0
            || r.sequence <= t.next
            || t.await_idr
            || t.episode.is_some()
        {
            return Err(Failure::Protocol);
        }
        let gap = t.gap.as_mut().ok_or(Failure::Protocol)?;
        if gap.sequence != t.next || gap.reported {
            return Err(Failure::Protocol);
        }
        gap.reported = true;
        t.await_idr = true;
        self.episode_serial = self.episode_serial.checked_add(1).ok_or(Failure::Clock)?;
        t.episode = Some(Episode {
            id: self.episode_serial,
            sequence: gap.sequence,
            anchor: Some(now),
            attempt: 1,
            active_cutoff: Some(active_cutoff),
            exhausted: false,
        });
        self.refresh_health(1)
    }
    pub fn disposition(&mut self) -> Option<Disposition> {
        self.dispositions.pop_front()
    }
    fn signal(&mut self, d: Disposition) {
        if self.dispositions.len() < 32 {
            self.dispositions.push_back(d)
        } else {
            first_error::reject(1, line!(), self.dispositions.len(), 32, 1, 0, 0);
            self.retire(Failure::Capacity)
        }
    }
    fn feedback(&mut self, r: Record, now: u64) -> Result<(), Failure> {
        let deadline = if r.kind == 6 {
            self.media
                .deadline(r.track, r.sequence)
                .ok_or(Failure::Deadline)?
        } else {
            now.checked_add(crate::TRANSACTION_LIFETIME)
                .ok_or(Failure::Clock)?
        };
        self.feedback_until(r, deadline)
    }
    fn feedback_until(&mut self, r: Record, deadline: u64) -> Result<(), Failure> {
        if self.feedback.iter().any(|(old, _)| old == &r) {
            return Ok(());
        }
        let ack = matches!(r.kind, 10 | 14);
        let count = self.feedback.len();
        let bytes: usize = self
            .feedback
            .iter()
            .map(|(r, _)| 64 + r.body.capacity())
            .sum();
        if count >= if ack { 64 } else { 48 }
            || bytes + 64 + r.body.len() > if ack { 16 * 1024 } else { 14 * 1024 }
        {
            first_error::reject(
                1,
                line!(),
                count,
                if ack { 64 } else { 48 },
                64 + r.body.len(),
                bytes,
                if ack { 16 * 1024 } else { 14 * 1024 },
            );
            return Err(Failure::Capacity);
        }
        if ack {
            let pos = self
                .feedback
                .iter()
                .position(|(r, _)| !matches!(r.kind, 10 | 14))
                .unwrap_or(self.feedback.len());
            self.feedback.insert(pos, (r, deadline))
        } else {
            self.feedback.push_back((r, deadline))
        }
        Ok(())
    }
    fn ack(&mut self, r: &Record, now: u64) -> Result<(), Failure> {
        let mut a = r.with_body(vec![r.kind, 0, 0, 0]);
        a.kind = 14;
        a.flags = 0;
        a.pts = 0;
        a.total = 0;
        a.index = 0;
        a.count = 0;
        a.age_us = 0;
        a.lifetime_us = 0;
        self.feedback(a, now)
    }
    pub fn next_feedback(&mut self, now: u64) -> Option<Record> {
        self.tick(now).ok()?;
        self.feedback.front().map(|(r, _)| r.clone())
    }
    pub fn feedback_deadline(&self) -> Option<u64> {
        self.feedback.front().map(|(_, d)| *d)
    }
    pub fn feedback_accepted(&mut self) {
        self.feedback.pop_front();
    }
    pub fn ingest(&mut self, r: Record, now: u64) -> Result<(), Failure> {
        self.ingest_classified(r, now).map(|_| ())
    }
    pub fn ingest_classified(&mut self, r: Record, now: u64) -> Result<MediaOutcome, Failure> {
        let result = self.ingest_inner(r, now);
        if let Err(e) = result {
            self.retire(e)
        }
        result
    }
    fn ingest_inner(&mut self, r: Record, now: u64) -> Result<MediaOutcome, Failure> {
        self.tick(now)?;
        r.validate().map_err(|_| Failure::Protocol)?;
        if r.generation != self.context.generation {
            return Err(Failure::Protocol);
        }
        if r.kind == 1 {
            let c = &self.context;
            let b = &r.body;
            if self.started
                || crate::wire::u32_at(b, 0) != c.scid
                || b[4] != c.capture_kind
                || b[5] != c.enabled
                || crate::wire::u32_at(b, 8) != c.display_id
                || crate::wire::u64_at(b, 12) != c.target_token
            {
                return Err(Failure::Protocol);
            }
            self.started = true;
            return self.ack(&r, now).map(|_| MediaOutcome::Admitted);
        }
        if !self.started {
            return Err(Failure::Protocol);
        }
        if r.kind == 11 {
            self.retire(Failure::Retired);
            return Err(Failure::Retired);
        }
        if r.track > 0 && self.context.enabled & (1 << (r.track - 1)) == 0 {
            return Err(Failure::Protocol);
        }
        if r.track > 0 && self.tracks[r.track as usize].disabled {
            return Err(Failure::Protocol);
        }
        match r.kind {
            2 | 3 | 4 | 12 => self.ingest_metadata(r, now).map(|_| MediaOutcome::Admitted),
            5 | crate::wire::XOR_PARITY_KIND => {
                if r.kind == crate::wire::XOR_PARITY_KIND
                    && self.context.enabled & crate::FEATURE_XOR_PARITY == 0
                {
                    return Err(Failure::Unsupported);
                }
                if r.kind == 5
                    && r.flags & crate::wire::RELIABLE_RECOVERY_FLAG != 0
                    && (r.index == 0 || r.index + 1 == r.count)
                {
                    let t = &self.tracks[r.track as usize];
                    let episode = t.episode.as_ref().map_or(0, |episode| episode.id);
                    let discard_through = t.discard_through;
                    self.trace_event(
                        24,
                        &r,
                        r.index as u64,
                        ((r.age_us as u64) << 32) | r.lifetime_us as u64,
                        ((discard_through & 0xffff_ffff) << 32) | (episode & 0xffff_ffff),
                    );
                }
                let t = &self.tracks[r.track as usize];
                if r.epoch < t.epoch
                    || r.epoch == t.epoch && r.config < t.version
                    || r.sequence < t.next
                    || r.sequence <= t.discard_through
                {
                    return Ok(MediaOutcome::SkippedDependent);
                }
                let ready = t.epoch == r.epoch && t.version == r.config && t.codec.is_some();
                if ready
                    && t.deferred_loss_contains(r.sequence)
                    && !self.media.entries.iter().any(|entry| {
                        let h = &entry.header;
                        entry.bytes.is_some()
                            && now < entry.deadline
                            && h.generation == r.generation
                            && h.track == r.track
                            && h.epoch == r.epoch
                            && h.config == r.config
                            && h.sequence == r.sequence
                    })
                {
                    return Ok(MediaOutcome::SkippedDependent);
                }
                if !ready
                    && !self.media.contains(r.track, r.sequence)
                    && self
                        .media
                        .headers()
                        .filter(|h| {
                            let s = &self.tracks[h.track as usize];
                            s.epoch != h.epoch || s.version != h.config
                        })
                        .count()
                        >= 2
                {
                    // Ordinary media datagrams may overtake their reliable
                    // configuration. Preserve the two-AU admission bound, but
                    // shed the new datagram instead of retiring the entire
                    // authenticated session for a valid cross-lane reorder.
                    // No future configuration is installed and no existing
                    // AU/consumer ownership or lifetime is changed here.
                    // Private reliable recovery still follows strict failure
                    // semantics; it must never be silently dropped as UDP.
                    if r.lane() == galaxybridge_quic::Lane::Datagram {
                        return Ok(MediaOutcome::DeclinedPressure);
                    }
                    first_error::reject(
                        1,
                        line!(),
                        self.media
                            .headers()
                            .filter(|h| {
                                let s = &self.tracks[h.track as usize];
                                s.epoch != h.epoch || s.version != h.config
                            })
                            .count(),
                        2,
                        1,
                        0,
                        0,
                    );
                    return Err(Failure::Capacity);
                }
                let crossed_reliable_recovery = ready
                    && r.track == 1
                    && r.flags & crate::wire::RELIABLE_RECOVERY_FLAG != 0
                    && r.sequence > t.next
                    && !t.await_idr
                    && t.episode.is_none();
                let current_sequence_resident = crossed_reliable_recovery && {
                    let next = t.next;
                    let epoch = t.epoch;
                    let config = t.version;
                    self.held.iter().any(|held| {
                        held.state == HeldState::Pending
                            && held.lease.record.kind == 5
                            && held.lease.record.track == 1
                            && held.lease.record.epoch == epoch
                            && held.lease.record.config == config
                            && held.lease.record.sequence == next
                    }) || self.recovery_au.as_ref().is_some_and(|completed| {
                        completed.record.track == 1
                            && completed.record.epoch == epoch
                            && completed.record.config == config
                            && completed.record.sequence == next
                    }) || self.media.headers().any(|header| {
                        header.track == 1
                            && header.epoch == epoch
                            && header.config == config
                            && header.sequence == next
                    })
                };
                // A producer-correlated second recovery response may overtake
                // consumer commit while the exact current AU is already owned
                // locally. That is future independent media, not proof of a
                // missing current sequence. Keep it bounded by its original
                // reliable lifetime and normal in-order output. Requiring an
                // earlier owned recovery episode preserves the startup and
                // unsolicited-reliable rejection boundary.
                let future_recovery_behind_resident_current =
                    current_sequence_resident && self.episode_serial > 0;
                // A second response to an already completed recovery can reach
                // the reliable stream exactly when its sequence becomes the
                // next live AU. A preceding progress watermark may already have
                // reserved an unreported placeholder for that exact sequence;
                // it describes the same AU, not a conflicting recovery. Accept
                // only this exact live boundary after this receiver has owned a
                // real recovery episode. A reported/different gap and startup
                // reliable-media remain strict.
                let aligned_gap = t
                    .gap
                    .as_ref()
                    .is_none_or(|gap| gap.sequence == t.next && !gap.reported);
                let aligned_reliable_recovery = ready
                    && r.track == 1
                    && r.flags & crate::wire::RELIABLE_RECOVERY_FLAG != 0
                    && r.sequence == t.next
                    && self.episode_serial > 0
                    && !t.await_idr
                    && t.episode.is_none()
                    && aligned_gap;
                if ready && (r.sequence > t.next || r.sequence == t.next && r.count > 1) {
                    self.gap(r.track, t.next, now)?;
                }
                if crossed_reliable_recovery && !future_recovery_behind_resident_current {
                    self.arm_crossed_reliable_recovery(&r, now)?;
                }
                let t = &self.tracks[r.track as usize];
                if r.flags & crate::wire::RELIABLE_RECOVERY_FLAG != 0
                    && !aligned_reliable_recovery
                    && !future_recovery_behind_resident_current
                    && (r.track != 1 || !t.await_idr || t.episode.is_none())
                {
                    // Internal first-cause diagnostics only.  Keep the record
                    // scalar and compact while distinguishing the predicates
                    // which deliberately gate a private reliable-recovery AU:
                    // low byte=track, bit 8=configuration ready, bit 9=receiver
                    // has owned a recovery episode, bit 10=awaiting IDR,
                    // bit 11=episode present, bit 12=gap present.  The remaining
                    // fields preserve the exact peer/local configuration and
                    // sequence boundary.  This does not alter admission policy.
                    let recovery_state = r.track as usize
                        | (usize::from(ready) << 8)
                        | (usize::from(self.episode_serial > 0) << 9)
                        | (usize::from(t.await_idr) << 10)
                        | (usize::from(t.episode.is_some()) << 11)
                        | (usize::from(t.gap.is_some()) << 12);
                    first_error::reject(
                        1,
                        line!(),
                        recovery_state,
                        r.config as usize,
                        t.version as usize,
                        r.sequence as usize,
                        t.next as usize,
                    );
                    return Err(Failure::Protocol);
                }
                if ready && r.sequence <= self.tracks[r.track as usize].discard_through {
                    return Ok(MediaOutcome::SkippedDependent);
                }
                if ready {
                    self.admit_recovery_over_backlog(&r, now)?;
                }
                if ready && self.media.admission_pressure(&r) {
                    self.record_loss(&r, 1, now)?;
                    return Ok(MediaOutcome::DeclinedPressure);
                }
                self.media.ingest(r, now).map(|_| MediaOutcome::Admitted)
            }
            8 | 9 => {
                self.check_control_geometry(&r)?;
                if self.context.enabled & 4 == 0 {
                    return Err(Failure::Protocol);
                }
                self.control.ingest(r, now).map(|_| MediaOutcome::Admitted)
            }
            13 => {
                let t = &mut self.tracks[r.track as usize];
                if r.epoch != t.epoch || r.config != t.version {
                    // Delivery watermarks are cumulative, supersedable
                    // observations. They intentionally use the expiring
                    // datagram lane so a lost or reordered watermark cannot
                    // head-of-line block live media. A later watermark after
                    // the matching configuration carries all needed progress.
                    return Ok(MediaOutcome::SkippedDependent);
                }
                if r.sequence < t.watermark {
                    return Ok(MediaOutcome::Admitted);
                }
                let progress = t.next.saturating_sub(1).max(t.skipped_through);
                t.watermark_ranges
                    .retain(|(through, _)| *through > progress);
                if r.sequence > t.watermark && r.sequence > progress {
                    if t.watermark_ranges.len() == 32 {
                        // Preserve the 31 oldest exact observations that can
                        // age the current/near successors correctly. Replace
                        // only the farthest tail with the newest watermark and
                        // its real observation time. This may conservatively
                        // delay a far-future gap, but never backdates it and
                        // cannot turn ordinary packet loss into terminal
                        // receiver capacity.
                        t.watermark_ranges.pop_back();
                    }
                    t.watermark_ranges.push_back((r.sequence, now));
                }
                t.watermark = r.sequence;
                let next = t.next;
                if r.sequence >= next && !self.media.contains(r.track, next) {
                    self.gap(r.track, next, now)?;
                }
                self.ack(&r, now).map(|_| MediaOutcome::Admitted)
            }
            _ => Err(Failure::Protocol),
        }
    }
    fn ingest_metadata(&mut self, r: Record, now: u64) -> Result<(), Failure> {
        if self.metadata.len()
            + self
                .held
                .iter()
                .filter(|h| h.lease.record.kind != 5)
                .count()
            >= 16
        {
            first_error::reject(
                1,
                line!(),
                self.metadata.len()
                    + self
                        .held
                        .iter()
                        .filter(|h| h.lease.record.kind != 5)
                        .count(),
                16,
                1,
                0,
                0,
            );
            return Err(Failure::Capacity);
        }
        if r.kind != 4 {
            if self.assembly.is_some() {
                return Err(Failure::Protocol);
            }
            let bytes = self.meta_pool.allocate(r.body.clone())?;
            self.metadata.push_back(Metadata {
                record: r,
                bytes,
                deadline: now
                    .checked_add(crate::TRANSACTION_LIFETIME)
                    .ok_or(Failure::Clock)?,
            });
            let item = self.metadata.back_mut().unwrap();
            item.deadline -= item.record.age_us as u64 * 1000;
            item.record.body = vec![];
            return Ok(());
        }
        if self.assembly.is_none() {
            let t = &mut self.tracks[r.track as usize];
            if t.configs.len() >= 2 {
                let old = &t.configs[0];
                if old.bytes.references() == 1
                    && !self.media.headers().any(|h| {
                        h.track == r.track && h.epoch == old.epoch && h.config == old.version
                    })
                {
                    t.configs.remove(0);
                }
            }
            if !self
                .meta_pool
                .available_or_reject(r.total as usize, line!())
            {
                return Err(Failure::Capacity);
            }
            self.assembly = Some(Assembly {
                header: r.with_body(vec![]),
                bytes: Some(
                    self.meta_pool
                        .allocate_configuration(r.track, vec![0; r.total as usize])?,
                ),
                parity: None,
                seen: vec![false; r.count as usize],
                received: 0,
                first: now,
                last_unique: now,
                successor_observed: None,
                deadline: now
                    .checked_add((r.lifetime_us - r.age_us) as u64 * 1000)
                    .ok_or(Failure::Clock)?,
                requests: 0,
                last_request: None,
                codec_independent: None,
            });
        }
        let a = self.assembly.as_mut().unwrap();
        if !same_object(&a.header, &r) || now >= a.deadline {
            return Err(Failure::Protocol);
        }
        a.deadline = a.deadline.min(
            now.checked_add((r.lifetime_us - r.age_us) as u64 * 1000)
                .ok_or(Failure::Clock)?,
        );
        let start = r.index as usize * BODY;
        let bytes = a.bytes.as_mut().unwrap();
        if a.seen[r.index as usize] {
            if bytes.as_slice()[start..start + r.body.len()] != r.body {
                return Err(Failure::Protocol);
            }
            return Ok(());
        }
        bytes.unique_mut()?[start..start + r.body.len()].copy_from_slice(&r.body);
        a.seen[r.index as usize] = true;
        a.received += 1;
        if a.received == a.header.count as usize {
            let a = self.assembly.take().unwrap();
            self.metadata.push_back(Metadata {
                record: a.header,
                bytes: a.bytes.unwrap(),
                deadline: a.deadline,
            });
        }
        Ok(())
    }
    fn gap(&mut self, track: u8, sequence: u64, now: u64) -> Result<(), Failure> {
        self.gap_observed(track, sequence, now, now)
    }
    fn gap_observed(
        &mut self,
        track: u8,
        sequence: u64,
        observed: u64,
        now: u64,
    ) -> Result<(), Failure> {
        if observed > now {
            return Err(Failure::Clock);
        }
        // Extraction transfers the complete original out of reassembly before
        // consumer commit advances next. That exact live ownership is presence,
        // not another missing-AU reservation.
        let t = &self.tracks[track as usize];
        let matches = |r: &Record, deadline: u64| {
            r.kind == 5
                && r.generation == self.context.generation
                && r.track == track
                && r.epoch == t.epoch
                && r.config == t.version
                && r.sequence == sequence
                // tick owns physical expiry later in this same turn. A live
                // hole that just reached its deadline must be counted there,
                // not removed as a previously counted interval loss here.
                && (now < deadline || t.deferred_loss_contains(sequence))
        };
        if self.held.iter().any(|h| {
            h.lease.owner == self.owner
                && h.state == HeldState::Pending
                && matches(&h.lease.record, h.lease.deadline)
        }) || self
            .recovery_au
            .as_ref()
            .is_some_and(|a| matches(&a.record, a.deadline))
            || self.media.entries.iter().any(|entry| {
                let r = &entry.header;
                r.kind == 5
                    && r.generation == self.context.generation
                    && r.track == track
                    && r.epoch == t.epoch
                    && r.config == t.version
                    && r.sequence == sequence
                    && (!t.deferred_loss_contains(sequence) || entry.bytes.is_some())
            })
        {
            // Existing incomplete/complete reassembly already owns this slot.
            // The capacity branch below is only for a genuinely absent gap.
            return Ok(());
        }
        let t = &mut self.tracks[track as usize];
        if track == 1 && t.gap.is_none() {
            t.gap = Some(Gap {
                sequence,
                cutoff: observed
                    .checked_add(crate::RECOVERY_LIFETIME)
                    .ok_or(Failure::Clock)?,
                reported: false,
            });
        }
        if t.gap.as_ref().is_some_and(|g| g.reported) {
            return Ok(());
        }
        let header = Record {
            kind: 5,
            track,
            flags: 2,
            generation: self.context.generation,
            epoch: t.epoch,
            config: t.version,
            sequence,
            pts: 0,
            total: 0,
            index: 0,
            count: 0,
            age_us: 0,
            lifetime_us: 120000,
            body: vec![],
        };
        if t.deferred_loss_contains(sequence) {
            // This AU was already lost; do not create a new gap residence
            // interval after the preceding IDR commits.
            self.record_loss_inner(&header, 4, now, false)
        } else if self.media.retained_slots() >= 8 {
            self.record_loss(&header, 1, now)
        } else {
            self.media.expect_gap(header, observed)
        }
    }
    pub fn tick(&mut self, now: u64) -> Result<(), Failure> {
        if let Some(e) = self.terminal {
            return Err(e);
        }
        if now < self.last {
            self.retire(Failure::Clock);
            return Err(Failure::Clock);
        }
        self.last = now;
        // A watermark may have arrived while the preceding AU was still owned.
        // Advancing next at successful commit must not require another network
        // message to discover its absent successor. Two tracks, no sequence
        // walk; preserve each unresolved range's original observation age.
        for track in 1..=2 {
            let t = &mut self.tracks[track as usize];
            if t.deferred_loss.is_some_and(|(_, last)| t.next > last) {
                t.deferred_loss = None;
            }
            let progress = t.next.saturating_sub(1).max(t.skipped_through);
            t.watermark_ranges
                .retain(|(through, _)| *through > progress);
            if t.deferred_loss_contains(t.next) && t.next > t.discard_through {
                let next = t.next;
                self.gap_observed(track, next, now, now)?;
            }
            let t = &self.tracks[track as usize];
            if t.watermark >= t.next {
                if let Some(&(_, observed)) = t.watermark_ranges.front() {
                    let next = t.next;
                    self.gap_observed(track, next, observed, now)?;
                }
            }
        }
        self.feedback.retain(|(r, d)| {
            matches!(r.kind, 10 | 14)
                || now < *d && (r.kind != 6 || self.media.contains(r.track, r.sequence))
        });
        if self.metadata.iter().any(|m| now >= m.deadline)
            || self.assembly.as_ref().is_some_and(|a| now >= a.deadline)
            || self.held.iter().any(|h| {
                h.lease.record.kind != 5 && h.state == HeldState::Pending && now >= h.lease.deadline
            })
            || self.feedback.iter().any(|(_, d)| now >= *d)
        {
            self.retire(Failure::Deadline);
            return Err(Failure::Deadline);
        }
        if self.control.tick(now).is_err() {
            let e = self.control.terminal().unwrap_or(Failure::Sink);
            self.retire(e);
            return Err(e);
        }
        if self.recovery_trace.is_some() {
            for i in 0..self.media.entries.len() {
                let e = &self.media.entries[i];
                if now < e.deadline {
                    continue;
                }
                let (r, origin, deadline, received, count) = (
                    e.header.with_body(vec![]),
                    if e.bytes.is_none() {
                        1
                    } else if e.received < e.header.count as usize {
                        2
                    } else {
                        3
                    },
                    e.deadline,
                    e.received as u64,
                    e.header.count as u64,
                );
                self.trace_expiry(&r, origin, deadline, received, count, now);
            }
        }
        let expired = self.media.expired(now);
        for r in expired {
            self.record_loss(&r, 4, now)?;
        }
        if self.recovery_au.as_ref().is_some_and(|a| now >= a.deadline) {
            let a = self.recovery_au.take().unwrap();
            self.trace_expiry(
                &a.record,
                4,
                a.deadline,
                a.record.count as u64,
                a.record.count as u64,
                now,
            );
            self.record_loss(&a.record, 4, now)?;
        }
        let expired_held: Vec<_> = self
            .held
            .iter()
            .filter(|h| {
                h.lease.record.kind == 5 && h.state == HeldState::Pending && now >= h.lease.deadline
            })
            .map(|h| h.lease.record.with_body(vec![]))
            .collect();
        for h in &mut self.held {
            if h.lease.record.kind == 5 && h.state == HeldState::Pending && now >= h.lease.deadline
            {
                h.state = HeldState::Declined;
            }
        }
        for r in expired_held {
            if let Some(h) = self.held.iter().find(|h| {
                h.lease.record.kind == 5
                    && h.lease.record.track == r.track
                    && h.lease.record.sequence == r.sequence
            }) {
                let deadline = h.lease.deadline;
                self.trace_expiry(&r, 5, deadline, r.count as u64, r.count as u64, now);
            }
            self.record_loss(&r, 4, now)?;
        }
        self.update_episode(now)?;
        if let Some(r) = self.media.next_missing(now) {
            if let Err(e) = self.feedback(r, now) {
                self.retire(e);
                return Err(e);
            }
        }
        Ok(())
    }
    fn lost(&mut self, r: &Record, now: u64) -> Result<(), Failure> {
        self.lost_inner(r, now, false)
    }
    fn lost_inner(&mut self, r: &Record, now: u64, admitted: bool) -> Result<(), Failure> {
        let t = &mut self.tracks[r.track as usize];
        if r.epoch != t.epoch || r.config != t.version || (!admitted && r.sequence < t.next) {
            return Ok(());
        }
        if r.track == 2 {
            if !admitted {
                t.next = r.sequence.checked_add(1).ok_or(Failure::Capacity)?;
            }
            // Audio loss is a coalesced latest discontinuity, not one queued
            // control event per discarded AU while the consumer is pressured.
            self.dispositions
                .retain(|d| !matches!(d, Disposition::AudioGap { .. }));
            self.signal(Disposition::AudioGap {
                sequence: r.sequence,
            });
            return Ok(());
        }
        self.skipped_video = self
            .skipped_video
            .checked_add(t.skip_through(r.sequence))
            .ok_or(Failure::Capacity)?;
        if t.gap.is_none() {
            t.gap = Some(Gap {
                sequence: r.sequence,
                cutoff: now
                    .checked_add(crate::RECOVERY_LIFETIME)
                    .ok_or(Failure::Clock)?,
                reported: false,
            });
        }
        t.await_idr = true;
        if t.episode.is_none() {
            self.episode_serial = self.episode_serial.checked_add(1).ok_or(Failure::Clock)?;
            t.episode = Some(Episode {
                id: self.episode_serial,
                sequence: r.sequence,
                anchor: None,
                attempt: 0,
                active_cutoff: None,
                exhausted: false,
            });
        }
        let g = t.gap.as_mut().unwrap();
        if !g.reported {
            g.reported = true;
            let sequence = g.sequence;
            let epoch = t.epoch;
            self.signal(Disposition::RecoveryRequired {
                track: 1,
                epoch,
                sequence,
            });
        }
        self.refresh_health(r.track)?;
        Ok(())
    }
    fn validate_metadata(&self, m: &Metadata) -> Result<(), Failure> {
        let r = &m.record;
        let t = &self.tracks[r.track as usize];
        let b = m.bytes.as_slice();
        match r.kind {
            2 => {
                if t.codec.is_some() {
                    return Err(Failure::Protocol);
                }
                let code = crate::wire::u32_at(b, 0);
                if r.track == 1 && !matches!(code, 0x68323634 | 0x68323635)
                    || r.track == 2 && code != 0x00616163
                {
                    return Err(Failure::Unsupported);
                }
            }
            12 => {
                if t.codec.is_some() || crate::wire::u32_at(b, 0) > 1 {
                    return Err(Failure::Protocol);
                }
            }
            3 => {
                if t.codec.is_none()
                    || r.epoch != t.epoch.checked_add(1).ok_or(Failure::Capacity)?
                    || r.sequence < t.next
                    || crate::wire::u32_at(b, 0) & !0x80000001 != 0
                    || crate::wire::u32_at(b, 4) == 0
                    || crate::wire::u32_at(b, 8) == 0
                {
                    return Err(Failure::Protocol);
                }
            }
            4 => {
                if t.codec.is_none()
                    || r.config != t.version.checked_add(1).ok_or(Failure::Capacity)?
                    || r.sequence < t.next
                    || r.track == 1 && r.epoch != t.epoch
                    || r.track == 2 && r.epoch != t.epoch.max(1)
                {
                    return Err(Failure::Protocol);
                }
                crate::codec::Configuration::parse(t.codec.unwrap(), b)?;
            }
            _ => return Err(Failure::Protocol),
        }
        Ok(())
    }
    pub fn next_output(&mut self, now: u64) -> Result<Option<OutputLease>, Failure> {
        self.tick(now)?;
        if self
            .held
            .iter()
            .any(|h| h.state == HeldState::Pending && h.lease.record.kind != 5)
        {
            return Ok(None);
        }
        if self.held.len() >= 32 {
            first_error::reject(1, line!(), self.held.len(), 32, 1, 0, 0);
            return Err(Failure::Capacity);
        }
        if let Some(m) = self.metadata.pop_front() {
            if let Err(e) = self.validate_metadata(&m) {
                self.retire(e);
                return Err(e);
            }
            self.serial = self.serial.checked_add(1).ok_or(Failure::Capacity)?;
            let lease = OutputLease {
                owner: self.owner,
                token: self.serial,
                record: m.record,
                bytes: m.bytes,
                configuration: None,
                deadline: m.deadline,
            };
            self.held.push(Held {
                lease: lease.clone(),
                state: HeldState::Pending,
                republished: false,
                copy_pressure: false,
                qualified_independent: false,
            });
            return Ok(Some(lease));
        }
        for track in 1..=2u8 {
            if self.held.iter().any(|h| {
                h.state == HeldState::Pending
                    && h.lease.record.kind == 5
                    && h.lease.record.track == track
            }) {
                continue;
            }
            let protected_recovery = (track == 1)
                .then(|| self.protected_recovery_sequence())
                .flatten();
            let t = &self.tracks[track as usize];
            if t.codec.is_none() || t.version == 0 {
                continue;
            }
            let staged = track == 1 && self.recovery_au.is_some();
            let sequence = if track == 1 && t.await_idr && protected_recovery.is_some() {
                match self.media.recovery_sequence(t, protected_recovery.unwrap()) {
                    Ok(sequence) => sequence,
                    Err(error) => {
                        self.retire(error);
                        return Err(error);
                    }
                }
            } else if track == 1 && t.await_idr {
                self.media
                    .complete_headers()
                    .filter(|h| {
                        h.track == track
                            && h.epoch == t.epoch
                            && h.config == t.version
                            && h.sequence >= t.next
                    })
                    .map(|h| h.sequence)
                    .min()
            } else {
                Some(t.next)
            };
            let completed = if staged {
                self.recovery_au.take().unwrap()
            } else {
                let Some(sequence) = sequence else { continue };
                let Some(completed) = self.media.take(track, sequence, now) else {
                    continue;
                };
                completed
            };
            let t = &self.tracks[track as usize];
            let r = &completed.record;
            if r.epoch != t.epoch || r.config != t.version {
                continue;
            }
            let cfg = t
                .configs
                .iter()
                .find(|c| c.epoch == r.epoch && c.version == r.config)
                .ok_or(Failure::Protocol)?;
            let independent = match cfg
                .parsed
                .independent(completed.bytes.as_slice(), r.flags & 1 != 0)
            {
                Ok(v) => v,
                Err(e) => {
                    self.retire(e);
                    return Err(e);
                }
            };
            if track == 1 && t.episode.is_some() {
                if let Some(trace) = self.recovery_trace.as_mut() {
                    trace.push(recovery_trace::Event([
                        20,
                        1,
                        r.epoch as u64,
                        r.config as u64,
                        r.sequence,
                        t.episode.as_ref().unwrap().id,
                        independent as u64,
                        completed.deadline.saturating_sub(now),
                    ]));
                }
            }
            if track == 1 && t.await_idr && !independent {
                let skipped = self.tracks[1].skip_through(r.sequence);
                self.skipped_video = self
                    .skipped_video
                    .checked_add(skipped)
                    .ok_or(Failure::Capacity)?;
                if !protected_recovery.is_some_and(|sequence| r.sequence > sequence) {
                    self.tracks[1].discard_through = self.tracks[1].discard_through.max(r.sequence);
                }
                self.tracks[1].health.skipped = self.tracks[1]
                    .health
                    .skipped
                    .checked_add(skipped)
                    .ok_or(Failure::Clock)?;
                continue;
            }
            if t.pts.is_some_and(|pts| r.pts <= pts) {
                self.retire(Failure::Protocol);
                return Err(Failure::Protocol);
            }
            self.serial = self.serial.checked_add(1).ok_or(Failure::Capacity)?;
            if !staged && track == 1 && t.gap.as_ref().is_some_and(|g| g.reported) {
                let mut configuration = r.with_body(vec![]);
                configuration.kind = 4;
                configuration.flags = 0;
                configuration.pts = 0;
                configuration.total = cfg.bytes.len() as u32;
                configuration.index = 0;
                configuration.count = cfg.bytes.len().div_ceil(BODY) as u16;
                configuration.age_us = 0;
                configuration.lifetime_us = 500000;
                let lease = OutputLease {
                    owner: self.owner,
                    token: self.serial,
                    record: configuration,
                    bytes: cfg.bytes.clone(),
                    configuration: None,
                    deadline: completed.deadline,
                };
                self.recovery_au = Some(completed);
                if let Some(trace) = self.recovery_trace.as_mut() {
                    trace.push(recovery_trace::Event([
                        21,
                        1,
                        lease.record.epoch as u64,
                        lease.record.config as u64,
                        lease.record.sequence,
                        t.episode.as_ref().map_or(0, |e| e.id),
                        now,
                        lease.deadline,
                    ]));
                }
                self.held.push(Held {
                    lease: lease.clone(),
                    state: HeldState::Pending,
                    republished: true,
                    copy_pressure: false,
                    qualified_independent: false,
                });
                return Ok(Some(lease));
            }
            let lease = OutputLease {
                owner: self.owner,
                token: self.serial,
                record: completed.record,
                bytes: completed.bytes,
                configuration: Some(cfg.bytes.clone()),
                deadline: completed.deadline,
            };
            if track == 1 && t.episode.is_some() {
                if let Some(trace) = self.recovery_trace.as_mut() {
                    trace.push(recovery_trace::Event([
                        22,
                        1,
                        lease.record.epoch as u64,
                        lease.record.config as u64,
                        lease.record.sequence,
                        t.episode.as_ref().unwrap().id,
                        now,
                        lease.deadline,
                    ]));
                }
            }
            self.held.push(Held {
                lease: lease.clone(),
                state: HeldState::Pending,
                republished: false,
                copy_pressure: false,
                qualified_independent: independent,
            });
            return Ok(Some(lease));
        }
        Ok(None)
    }
    pub fn consumer_commit(&mut self, lease: &OutputLease, now: u64) -> Result<(), Failure> {
        self.tick(now)?;
        if lease.owner != self.owner || !self.current_output(&lease.record) {
            return Err(Failure::Retired);
        }
        let pos = self
            .held
            .iter()
            .position(|h| h.lease.token == lease.token && h.state == HeldState::Pending)
            .ok_or(Failure::Protocol)?;
        let h = &self.held[pos];
        if now >= h.lease.deadline {
            return Err(Failure::Deadline);
        }
        let r = h.lease.record.with_body(vec![]);
        let bytes = h.lease.bytes.clone();
        let independent = h.qualified_independent;
        if h.republished {
            self.held[pos].state = HeldState::Committed;
            return Ok(());
        }
        let t = &mut self.tracks[r.track as usize];
        match r.kind {
            2 => {
                t.codec = Some(match crate::wire::u32_at(bytes.as_slice(), 0) {
                    0x68323634 => crate::codec::Codec::H264,
                    0x68323635 => crate::codec::Codec::H265,
                    _ => crate::codec::Codec::Aac,
                });
            }
            12 => {
                t.disabled = true;
            }
            3 => {
                t.epoch = r.epoch;
                t.watermark = 0;
                t.watermark_ranges.clear();
                t.next = r.sequence;
                t.await_idr = true;
                t.pts = None;
                t.gap = None;
                t.episode = None;
                t.discard_through = r.sequence.saturating_sub(1);
                t.deferred_loss = None;
                t.health.state = 0;
                t.health.reason = 0;
                self.media.discard_before_epoch(1, r.epoch);
                let width = crate::wire::u32_at(bytes.as_slice(), 4);
                let height = crate::wire::u32_at(bytes.as_slice(), 8);
                self.bind_control_geometry(r.epoch, width, height)?;
            }
            4 => {
                if t.configs.len() >= 2 {
                    let old = &t.configs[0];
                    if old.bytes.references() != 1
                        || self.media.headers().any(|h| {
                            h.track == r.track && h.epoch == old.epoch && h.config == old.version
                        })
                    {
                        first_error::reject(1, line!(), t.configs.len(), 2, 1, 0, 0);
                        return Err(Failure::Capacity);
                    }
                    t.configs.remove(0);
                }
                let parsed = crate::codec::Configuration::parse(
                    t.codec.ok_or(Failure::Protocol)?,
                    bytes.as_slice(),
                )?;
                t.configs.push(ConfigVersion {
                    epoch: r.epoch,
                    version: r.config,
                    bytes,
                    parsed,
                });
                if t.epoch != r.epoch {
                    t.pts = None;
                }
                t.epoch = r.epoch;
                t.version = r.config;
                t.watermark = 0;
                t.watermark_ranges.clear();
                t.next = r.sequence;
                t.await_idr = true;
                t.gap = None;
                t.episode = None;
                t.discard_through = r.sequence.saturating_sub(1);
                t.deferred_loss = None;
                t.health.state = 0;
                t.health.reason = 0;
            }
            5 => {
                if r.track == 1 && t.gap.as_ref().is_some_and(|gap| gap.reported) {
                    let skipped = t.skip_through(r.sequence - 1);
                    self.skipped_video = self
                        .skipped_video
                        .checked_add(skipped)
                        .ok_or(Failure::Capacity)?;
                    t.health.skipped = t
                        .health
                        .skipped
                        .checked_add(skipped)
                        .ok_or(Failure::Clock)?;
                }
                t.next = r.sequence.checked_add(1).ok_or(Failure::Capacity)?;
                t.pts = Some(r.pts);
                t.await_idr = false;
                t.gap = None;
                t.episode = None;
                t.health.state = if t.health.output_pressure == 0 { 1 } else { 3 };
                t.health.reason = 0;
            }
            _ => return Err(Failure::Protocol),
        }
        self.held[pos].state = HeldState::Committed;
        if matches!(r.kind, 3 | 4) {
            let t = &mut self.tracks[r.track as usize];
            t.native_input_loss = 0;
            t.native_output = 0;
            t.native_counts = [0; 2];
            t.health.output_pressure = 0;
            t.committed_independent = 0;
        }
        self.refresh_health(r.track)?;
        if matches!(r.kind, 3 | 4) {
            // Replacement is now effective. Revoke only not-yet-admitted AUs;
            // external shared byte/config references retain their own charges.
            let tracks = &self.tracks;
            self.held.retain(|h| {
                let r = &h.lease.record;
                h.state != HeldState::Pending || r.kind != 5 || {
                    let t = &tracks[r.track as usize];
                    r.epoch == t.epoch && r.config == t.version
                }
            });
            if self
                .recovery_au
                .as_ref()
                .is_some_and(|a| !self.current_output(&a.record))
            {
                self.recovery_au = None;
            }
        }
        if r.kind != 5 {
            self.ack(&r, now)?;
        }
        if r.kind == 5 && r.track == 1 && independent {
            self.tracks[1].committed_independent = r.sequence;
            self.trace_event(23, &r, 0, now, lease.deadline);
        }
        Ok(())
    }
    fn current_output(&self, r: &Record) -> bool {
        if r.kind != 5 {
            return true;
        }
        self.tracks
            .get(r.track as usize)
            .is_some_and(|t| r.epoch == t.epoch && r.config == t.version)
    }
    pub fn check_output(&mut self, lease: &OutputLease, now: u64) -> Result<(), Failure> {
        self.tick(now)?;
        if lease.owner != self.owner || !self.current_output(&lease.record) {
            return Err(Failure::Retired);
        }
        let held = self
            .held
            .iter()
            .find(|h| h.lease.token == lease.token)
            .ok_or(Failure::Retired)?;
        if now >= held.lease.deadline {
            return Err(Failure::Deadline);
        }
        if held.state != HeldState::Pending {
            return Err(Failure::Retired);
        }
        Ok(())
    }
    pub fn release_output(&mut self, lease: &OutputLease, now: u64) -> Result<(), Failure> {
        if lease.owner != self.owner {
            return Err(Failure::Retired);
        }
        self.tick(now)?;
        let pos = self
            .held
            .iter()
            .position(|h| h.lease.token == lease.token && h.state != HeldState::Pending)
            .ok_or(Failure::Protocol)?;
        let h = self.held.remove(pos);
        if h.state == HeldState::Committed
            && h.lease.record.kind == 5
            && self.current_output(&h.lease.record)
            && now < h.lease.deadline
        {
            let mut r = h.lease.record.with_body(vec![]);
            r.kind = 7;
            r.flags = 0;
            r.pts = 0;
            r.total = 0;
            r.index = 0;
            r.count = 0;
            r.age_us = 0;
            r.lifetime_us = 0;
            self.feedback_until(r, h.lease.deadline)?;
        }
        Ok(())
    }
    pub fn control_write_result(
        &mut self,
        token: u64,
        count: usize,
        now: u64,
    ) -> Result<crate::control::WriteOutcome, Failure> {
        let outcome = self.control.write_result(token, count, now)?;
        if let crate::control::WriteOutcome::Complete { sequence, epoch } = outcome {
            self.feedback(
                Record {
                    kind: 10,
                    track: 0,
                    flags: 0,
                    generation: self.context.generation,
                    epoch,
                    config: 0,
                    sequence,
                    pts: 0,
                    total: 0,
                    index: 0,
                    count: 0,
                    age_us: 0,
                    lifetime_us: 0,
                    body: vec![],
                },
                now,
            )?;
        }
        if let Some(e) = self.control.terminal() {
            self.retire(e)
        }
        Ok(outcome)
    }
    pub fn next_wakeup(&self) -> Option<u64> {
        self.media
            .next_wakeup()
            .into_iter()
            .chain(self.metadata.iter().map(|m| m.deadline))
            .chain(self.assembly.iter().map(|a| a.deadline))
            .chain(
                self.held
                    .iter()
                    .filter(|h| h.state == HeldState::Pending)
                    .map(|h| h.lease.deadline),
            )
            .chain(self.feedback.iter().map(|(_, d)| *d))
            .chain(self.control.next_wakeup())
            .chain(
                self.tracks
                    .iter()
                    .filter_map(|t| t.episode.as_ref().and_then(Self::episode_wakeup)),
            )
            .min()
    }
    pub fn retire(&mut self, reason: Failure) {
        if self.terminal.is_some() {
            return;
        }
        self.terminal = Some(reason);
        self.control.retire(reason);
        self.media.clear();
        self.recovery_au = None;
        self.metadata.clear();
        self.assembly = None;
        self.held.clear();
        self.feedback.clear();
        for t in &mut self.tracks {
            t.configs.clear();
        }
        self.dispositions.clear();
        self.dispositions.push_back(Disposition::Retired(reason));
    }
}
