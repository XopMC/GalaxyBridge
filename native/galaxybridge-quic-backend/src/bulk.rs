use crate::{Error, Role, Side};
use galaxybridge_quic::Lane;
pub const HEADER: usize = 48;
pub const BODY: usize = 976;
pub const MAX_OBJECT: usize = 262144;
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Record {
    pub kind: u8,
    pub purpose: u8,
    pub generation: u64,
    pub id: u64,
    pub barrier: u64,
    pub total: u32,
    pub offset: u32,
    pub age_us: u32,
    pub body: Vec<u8>,
}
impl Record {
    pub fn decode(
        b: &[u8],
        role: Role,
        sender: Side,
        lane: Lane,
        generation: u64,
    ) -> Result<Self, Error> {
        if b.len() < HEADER
            || b.len() > HEADER + BODY
            || &b[..4] != b"GQB1"
            || lane != Lane::Reliable
            || b[6..8] != [0, 0]
            || b[42..44] != [0, 0]
            || u16::from_be_bytes(b[40..42].try_into().unwrap()) as usize != b.len() - HEADER
        {
            return Err(Error::Protocol);
        }
        let r = Self {
            kind: b[4],
            purpose: b[5],
            generation: u64_at(b, 8),
            id: u64_at(b, 16),
            barrier: u64_at(b, 24),
            total: u32_at(b, 32),
            offset: u32_at(b, 36),
            age_us: u32_at(b, 44),
            body: b[48..].to_vec(),
        };
        if r.generation != generation {
            return Err(Error::Protocol);
        }
        r.validate(role, sender)?;
        Ok(r)
    }
    pub fn encode(&self, role: Role, sender: Side) -> Result<Vec<u8>, Error> {
        self.validate(role, sender)?;
        let mut b = vec![0; HEADER];
        b[..4].copy_from_slice(b"GQB1");
        b[4] = self.kind;
        b[5] = self.purpose;
        for (at, n) in [(8, self.generation), (16, self.id), (24, self.barrier)] {
            b[at..at + 8].copy_from_slice(&n.to_be_bytes());
        }
        for (at, n) in [(32, self.total), (36, self.offset), (44, self.age_us)] {
            b[at..at + 4].copy_from_slice(&n.to_be_bytes());
        }
        b[40..42].copy_from_slice(&(self.body.len() as u16).to_be_bytes());
        b.extend_from_slice(&self.body);
        Ok(b)
    }
    fn validate(&self, role: Role, sender: Side) -> Result<(), Error> {
        if self.generation == 0 || self.id == 0 || self.body.len() > BODY {
            return Err(Error::Protocol);
        }
        let direction = match (self.kind, self.purpose) {
            (1, 1) | (2, 2) | (4, 3) => Side::Host,
            (1, 2) | (2, 1) | (3, 2) => Side::Peer,
            _ => return Err(Error::Protocol),
        };
        if sender != direction
            || role
                != if self.kind <= 2 {
                    Role::Bulk
                } else {
                    Role::Media
                }
        {
            return Err(Error::Protocol);
        }
        if self.purpose == 2 && self.barrier != self.id - 1 {
            return Err(Error::Protocol);
        }
        match self.kind {
            1 => {
                let total = self.total as usize;
                let offset = self.offset as usize;
                if total == 0
                    || total > MAX_OBJECT
                    || offset >= total
                    || offset % BODY != 0
                    || self.body.len() != (total - offset).min(BODY)
                    || self.age_us >= 500000
                {
                    return Err(Error::Protocol);
                }
            }
            2 => {
                if self.total != 0 || self.offset != 0 || self.age_us != 0 || !self.body.is_empty()
                {
                    return Err(Error::Protocol);
                }
            }
            3 => {
                if self.body.is_empty()
                    || self.total as usize != self.body.len()
                    || self.offset != 0
                    || self.age_us != 0
                    || self.body[0] == 0
                {
                    return Err(Error::Protocol);
                }
            }
            4 => {
                if self.body.len() != 16
                    || self.total != 16
                    || self.offset != 0
                    || self.age_us != 0
                    || self.barrier != 0
                    || u32_at(&self.body, 0) == 0
                    || u32_at(&self.body, 4) == 0
                    || u64_at(&self.body, 8) == 0
                {
                    return Err(Error::Protocol);
                }
            }
            _ => return Err(Error::Protocol),
        }
        Ok(())
    }
}
pub(crate) fn u64_at(b: &[u8], at: usize) -> u64 {
    u64::from_be_bytes(b[at..at + 8].try_into().unwrap())
}
pub(crate) fn u32_at(b: &[u8], at: usize) -> u32 {
    u32::from_be_bytes(b[at..at + 4].try_into().unwrap())
}

use std::{
    collections::VecDeque,
    sync::{Arc, Mutex},
};
#[derive(Clone, Debug)]
pub struct Blob(Arc<Storage>);
#[derive(Debug)]
struct Storage {
    bytes: Box<[u8]>,
    used: Arc<Mutex<(usize, usize)>>,
}
impl Drop for Storage {
    fn drop(&mut self) {
        let mut u = self.used.lock().unwrap();
        u.0 -= 1;
        u.1 -= self.bytes.len();
    }
}
impl Blob {
    pub fn as_slice(&self) -> &[u8] {
        &self.0.bytes
    }
    pub fn len(&self) -> usize {
        self.0.bytes.len()
    }
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
    pub(crate) fn write(&mut self, offset: usize, b: &[u8]) -> Result<(), Error> {
        Arc::get_mut(&mut self.0).ok_or(Error::Protocol)?.bytes[offset..offset + b.len()]
            .copy_from_slice(b);
        Ok(())
    }
}
#[derive(Clone)]
pub struct BlobPool {
    used: Arc<Mutex<(usize, usize)>>,
    slots: usize,
    bytes: usize,
    object: usize,
}
impl Default for BlobPool {
    fn default() -> Self {
        Self {
            used: Default::default(),
            slots: 2,
            bytes: 2 * MAX_OBJECT,
            object: MAX_OBJECT,
        }
    }
}
impl BlobPool {
    pub fn small_events() -> Self {
        Self {
            used: Default::default(),
            slots: 16,
            bytes: 16 * 976,
            object: 976,
        }
    }
    pub fn ack_events() -> Self {
        Self {
            used: Default::default(),
            slots: 16,
            bytes: 16 * 9,
            object: 9,
        }
    }
    pub fn usage(&self) -> (usize, usize) {
        *self.used.lock().unwrap()
    }
    pub fn allocate(&self, n: usize) -> Result<Blob, Error> {
        let mut u = self.used.lock().unwrap();
        if n == 0 || n > self.object || u.0 >= self.slots || n > self.bytes - u.1 {
            if n == 0 || n > self.object {
                galaxybridge_quic_media::media::first_error::reject(
                    5,
                    line!(),
                    0,
                    0,
                    n,
                    0,
                    self.object,
                );
            } else {
                galaxybridge_quic_media::media::first_error::reject(
                    5,
                    line!(),
                    u.0,
                    self.slots,
                    n,
                    u.1,
                    self.bytes,
                );
            }
            return Err(Error::Capacity);
        }
        u.0 += 1;
        u.1 += n;
        drop(u);
        Ok(Blob(Arc::new(Storage {
            bytes: vec![0; n].into_boxed_slice(),
            used: self.used.clone(),
        })))
    }
    pub fn copy(&self, b: &[u8]) -> Result<Blob, Error> {
        let mut p = self.allocate(b.len())?;
        p.write(0, b)?;
        Ok(p)
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    Applied,
    NotDispatched,
    UnknownRemoteOutcome,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Completion {
    pub id: u64,
    pub outcome: Outcome,
}
#[derive(Clone, Debug)]
pub struct Object {
    pub id: u64,
    pub purpose: u8,
    pub barrier: u64,
    pub bytes: Blob,
    pub deadline: u64,
}
struct Outgoing {
    object: Object,
    queued: u64,
    next: usize,
    accepted: bool,
}
struct Assembly {
    object: Object,
    next: usize,
}
pub struct Channel {
    side: Side,
    generation: u64,
    pub outgoing_pool: BlobPool,
    pub incoming_pool: BlobPool,
    outgoing: VecDeque<Outgoing>,
    incoming: VecDeque<Object>,
    assembly: Option<Assembly>,
    acks: VecDeque<(Record, u64)>,
    delivery: VecDeque<Object>,
    results: VecDeque<Completion>,
    pending: Option<(bool, u64, usize)>,
    last_out: u64,
    last_in: u64,
    last: u64,
    terminal: bool,
}
impl Channel {
    pub fn new(side: Side, generation: u64) -> Self {
        Self {
            side,
            generation,
            outgoing_pool: BlobPool::default(),
            incoming_pool: BlobPool::default(),
            outgoing: VecDeque::new(),
            incoming: VecDeque::new(),
            assembly: None,
            acks: VecDeque::new(),
            delivery: VecDeque::new(),
            results: VecDeque::new(),
            pending: None,
            last_out: 0,
            last_in: 0,
            last: 0,
            terminal: false,
        }
    }
    pub fn queue(
        &mut self,
        id: u64,
        barrier: u64,
        bytes: &[u8],
        received: u64,
        now: u64,
    ) -> Result<(), Error> {
        self.check_queue(id, barrier, received, now)?;
        let blob = self.outgoing_pool.copy(bytes)?;
        self.queue_blob(id, barrier, blob, received, now)
    }
    fn check_queue(&mut self, id: u64, barrier: u64, received: u64, now: u64) -> Result<(), Error> {
        self.tick(now)?;
        if received > now {
            return Err(Error::Clock);
        }
        if now >= crate::deadline(received, crate::BULK_LIFETIME)? {
            return Err(Error::Deadline);
        }
        if id <= self.last_out || self.pending.is_some() {
            return Err(Error::Protocol);
        }
        if self.outgoing.len() + self.results.len() >= 16 {
            galaxybridge_quic_media::media::first_error::reject(
                5,
                line!(),
                self.outgoing.len() + self.results.len(),
                16,
                1,
                0,
                0,
            );
            return Err(Error::Capacity);
        }
        let purpose = if self.side == Side::Host { 1 } else { 2 };
        if purpose == 2 && barrier != id - 1 {
            return Err(Error::Protocol);
        }
        Ok(())
    }
    pub(crate) fn queue_blob(
        &mut self,
        id: u64,
        barrier: u64,
        blob: Blob,
        received: u64,
        now: u64,
    ) -> Result<(), Error> {
        self.check_queue(id, barrier, received, now)?;
        if !Arc::ptr_eq(&blob.0.used, &self.outgoing_pool.used) {
            return Err(Error::Protocol);
        }
        let purpose = if self.side == Side::Host { 1 } else { 2 };
        self.outgoing.push_back(Outgoing {
            object: Object {
                id,
                purpose,
                barrier,
                bytes: blob,
                deadline: crate::deadline(received, crate::BULK_LIFETIME)?,
            },
            queued: received,
            next: 0,
            accepted: false,
        });
        self.last_out = id;
        Ok(())
    }
    pub fn fence(&self) -> Option<u64> {
        self.outgoing.front().map(|o| o.object.barrier)
    }
    pub fn incoming_barrier(&self) -> Option<u64> {
        self.assembly
            .as_ref()
            .map(|a| a.object.barrier)
            .into_iter()
            .chain(self.incoming.iter().map(|o| o.barrier))
            .chain(self.delivery.iter().map(|o| o.barrier))
            .min()
    }
    pub fn next_record(&mut self, now: u64) -> Result<Option<Record>, Error> {
        self.tick(now)?;
        if self.pending.is_some() {
            return Err(Error::Protocol);
        }
        if let Some((r, _)) = self.acks.front() {
            self.pending = Some((true, r.id, 0));
            return Ok(Some(r.clone()));
        }
        let Some(o) = self.outgoing.iter().find(|o| o.next < o.object.bytes.len()) else {
            return Ok(None);
        };
        // Ceil wire age can exhaust its representation in the last999ns,
        // before the nanosecond cutoff. Preserve admission truth on retirement.
        let age_us = (now - o.queued).div_ceil(1000);
        if age_us >= 500000 {
            self.retire();
            return Err(Error::Deadline);
        }
        let body =
            o.object.bytes.as_slice()[o.next..(o.next + BODY).min(o.object.bytes.len())].to_vec();
        let r = Record {
            kind: 1,
            purpose: o.object.purpose,
            generation: self.generation,
            id: o.object.id,
            barrier: o.object.barrier,
            total: o.object.bytes.len() as u32,
            offset: o.next as u32,
            age_us: age_us.try_into().map_err(|_| Error::Clock)?,
            body,
        };
        self.pending = Some((false, r.id, r.body.len()));
        Ok(Some(r))
    }
    pub fn admission(
        &mut self,
        admission: galaxybridge_quic::Admission,
        now: u64,
    ) -> Result<(), Error> {
        let (ack, id, n) = self.pending.take().ok_or(Error::Protocol)?;
        match admission {
            galaxybridge_quic::Admission::Accepted => {
                if ack {
                    self.acks.pop_front();
                } else {
                    let o = self
                        .outgoing
                        .iter_mut()
                        .find(|o| o.object.id == id)
                        .ok_or(Error::Protocol)?;
                    o.next += n;
                    o.accepted = true;
                }
            }
            galaxybridge_quic::Admission::Backpressured => {}
            _ => {
                self.retire();
                return Err(Error::Retired);
            }
        };
        self.tick(now)
    }
    pub fn ingest(&mut self, r: Record, now: u64) -> Result<(), Error> {
        self.tick(now)?;
        r.validate(Role::Bulk, self.side.opposite())?;
        if r.generation != self.generation {
            return Err(Error::Protocol);
        }
        if r.kind == 2 {
            let o = self.outgoing.front().ok_or(Error::Protocol)?;
            if r.id != o.object.id
                || r.barrier != o.object.barrier
                || r.purpose != o.object.purpose
                || !o.accepted
                || o.next != o.object.bytes.len()
                || now >= o.object.deadline
            {
                return Err(Error::Protocol);
            }
            self.results.push_back(Completion {
                id: r.id,
                outcome: Outcome::Applied,
            });
            self.outgoing.pop_front();
            return Ok(());
        }
        let cutoff = crate::deadline(now, (500000 - r.age_us as u64) * 1000)?;
        if self.assembly.is_none() {
            if r.offset != 0 || r.id <= self.last_in || self.acks.len() + self.incoming.len() >= 16
            {
                return Err(Error::Protocol);
            }
            let blob = self.incoming_pool.allocate(r.total as usize)?;
            self.assembly = Some(Assembly {
                object: Object {
                    id: r.id,
                    purpose: r.purpose,
                    barrier: r.barrier,
                    bytes: blob,
                    deadline: cutoff,
                },
                next: 0,
            });
        }
        let a = self.assembly.as_mut().unwrap();
        if r.id != a.object.id
            || r.purpose != a.object.purpose
            || r.barrier != a.object.barrier
            || r.total as usize != a.object.bytes.len()
            || r.offset as usize != a.next
        {
            return Err(Error::Protocol);
        }
        a.object.deadline = a.object.deadline.min(cutoff);
        a.object.bytes.write(a.next, &r.body)?;
        a.next += r.body.len();
        if a.next == a.object.bytes.len() {
            let a = self.assembly.take().unwrap();
            self.last_in = a.object.id;
            self.incoming.push_back(a.object);
        }
        Ok(())
    }
    pub fn next_object(&mut self, now: u64) -> Result<Option<Object>, Error> {
        self.tick(now)?;
        let result = self.incoming.pop_front();
        if let Some(o) = &result {
            self.delivery.push_back(o.clone());
        }
        Ok(result)
    }
    pub fn applied(&mut self, o: &Object, now: u64) -> Result<(), Error> {
        self.tick(now)?;
        let expected = self.delivery.front().ok_or(Error::Protocol)?;
        if expected.id != o.id
            || expected.purpose != o.purpose
            || expected.barrier != o.barrier
            || expected.deadline != o.deadline
            || !Arc::ptr_eq(&expected.bytes.0, &o.bytes.0)
        {
            return Err(Error::Protocol);
        }
        if now >= o.deadline {
            return Err(Error::Deadline);
        }
        if self.acks.len() >= 16 {
            galaxybridge_quic_media::media::first_error::reject(
                5,
                line!(),
                self.acks.len(),
                16,
                1,
                0,
                0,
            );
            return Err(Error::Capacity);
        }
        self.acks.push_back((
            Record {
                kind: 2,
                purpose: o.purpose,
                generation: self.generation,
                id: o.id,
                barrier: o.barrier,
                total: 0,
                offset: 0,
                age_us: 0,
                body: vec![],
            },
            o.deadline,
        ));
        self.delivery.pop_front();
        Ok(())
    }
    pub fn completion(&mut self) -> Option<Completion> {
        self.results.pop_front()
    }
    pub fn next_deadline(&self) -> Option<u64> {
        self.outgoing
            .iter()
            .map(|o| o.object.deadline)
            .chain(self.incoming.iter().map(|o| o.deadline))
            .chain(self.assembly.iter().map(|a| a.object.deadline))
            .chain(self.delivery.iter().map(|o| o.deadline))
            .chain(self.acks.iter().map(|(_, deadline)| *deadline))
            .min()
    }
    pub fn tick(&mut self, now: u64) -> Result<(), Error> {
        if self.terminal {
            return Err(Error::Retired);
        }
        if now < self.last {
            self.retire();
            return Err(Error::Clock);
        }
        self.last = now;
        if self.next_deadline().is_some_and(|d| now >= d) {
            // Internal first-cause telemetry only: identify which bounded
            // reliable-bulk stage owned the expired original deadline. For an
            // outgoing object, report only protocol metadata: command tag,
            // accepted offset, total length, transport acceptance and purpose.
            // No payload bytes beyond the public command discriminator leave
            // this process.
            if let Some(o) = self.outgoing.iter().find(|o| now >= o.object.deadline) {
                galaxybridge_quic_media::media::first_error::reject(
                    9,
                    line!(),
                    o.object.bytes.as_slice().first().copied().unwrap_or(0) as usize,
                    o.next,
                    o.object.bytes.len(),
                    usize::from(o.accepted),
                    o.object.purpose as usize,
                );
            } else {
                galaxybridge_quic_media::media::first_error::reject(
                    9,
                    line!(),
                    self.incoming.len(),
                    self.delivery.len(),
                    self.acks.len(),
                    usize::from(self.assembly.is_some()),
                    0,
                );
            }
            self.retire();
            return Err(Error::Deadline);
        }
        Ok(())
    }
    pub fn retire(&mut self) {
        if self.terminal {
            return;
        }
        self.terminal = true;
        for o in self.outgoing.drain(..) {
            self.results.push_back(Completion {
                id: o.object.id,
                outcome: if o.accepted {
                    Outcome::UnknownRemoteOutcome
                } else {
                    Outcome::NotDispatched
                },
            });
        }
        self.incoming.clear();
        self.delivery.clear();
        self.assembly = None;
        self.acks.clear();
        self.pending = None;
    }
}
