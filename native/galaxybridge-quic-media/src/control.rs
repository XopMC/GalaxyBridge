use crate::{
    media::{Bytes, Pool},
    wire::{u16_at, u32_at, u64_at, Record},
    Failure, MOVE_LIFETIME, TRANSACTION_LIFETIME,
};
use std::collections::VecDeque;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Class {
    Down = 1,
    Up = 2,
    Cancel = 3,
    Key = 4,
    Uhid = 5,
    Resize = 6,
    StartApp = 7,
    Wheel = 8,
    Ordinary = 9,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MoveAdmission {
    Queued,
    Replaced,
    Stale,
    Expired,
}

struct SourcePointer {
    gesture: u64,
    pointer: u64,
    barrier: u64,
    latest: u64,
}
struct SourceMove {
    header: Record,
    bytes: Bytes,
    received: u64,
    deadline: u64,
}
/// Sender-local gesture admission. It does not claim a remote DOWN was applied.
pub(crate) struct SourceInput {
    pointers: Vec<SourcePointer>,
    moves: Vec<SourceMove>,
    pool: Pool,
    highest_gesture: u64,
    critical: u64,
    epoch: u32,
    resize_pending: bool,
}
impl SourceInput {
    pub fn new() -> Self {
        Self {
            pointers: vec![],
            moves: vec![],
            pool: Pool::new(16, 16 * 1024),
            highest_gesture: 0,
            critical: 0,
            epoch: 1,
            resize_pending: false,
        }
    }
    pub fn validate_critical(&self, r: &Record) -> Result<Class, Failure> {
        r.validate().map_err(|_| Failure::Protocol)?;
        if r.kind != 8
            || r.epoch != self.epoch
            || r.sequence != self.critical.checked_add(1).ok_or(Failure::Capacity)?
        {
            crate::media::first_error::reject(6, line!(), 0, 0, 0, 0, 0);
            return Err(Failure::Protocol);
        }
        let class = validate(r.body[0], &r.body[36..])?;
        if self.resize_pending
            && matches!(
                class,
                Class::Down | Class::Up | Class::Cancel | Class::Wheel
            )
        {
            crate::media::first_error::reject(6, line!(), 0, 0, 0, 0, 0);
            return Err(Failure::Protocol);
        }
        let gesture = u64_at(&r.body, 8);
        let pointer = u64_at(&r.body, 16);
        let final_move = u64_at(&r.body, 24);
        if matches!(class, Class::Down | Class::Up | Class::Cancel) {
            if gesture == 0 || pointer != u64_at(&r.body[36..], 2) {
                return Err(Failure::Protocol);
            }
            if class == Class::Down {
                if self.pointers.len() >= 16 {
                    return Err(Failure::Capacity);
                }
                if final_move != 0
                    || gesture < self.highest_gesture
                    || gesture == self.highest_gesture
                        && !self.pointers.iter().any(|p| p.gesture == gesture)
                    || self.pointers.iter().any(|p| p.pointer == pointer)
                {
                    return Err(Failure::Protocol);
                }
            } else {
                let p = self
                    .pointers
                    .iter()
                    .find(|p| p.gesture == gesture && p.pointer == pointer)
                    .ok_or_else(|| {
                        crate::media::first_error::reject(6, line!(), 0, 0, 0, 0, 0);
                        Failure::Protocol
                    })?;
                if final_move < p.latest {
                    crate::media::first_error::reject(6, line!(), 0, 0, 0, 0, 0);
                    return Err(Failure::Protocol);
                }
            }
        } else if gesture != 0 || pointer != 0 || final_move != 0 {
            return Err(Failure::Protocol);
        }
        Ok(class)
    }
    pub fn admitted_critical(&mut self, r: &Record, class: Class) {
        self.critical = r.sequence;
        let gesture = u64_at(&r.body, 8);
        let pointer = u64_at(&r.body, 16);
        match class {
            Class::Down => {
                self.highest_gesture = self.highest_gesture.max(gesture);
                self.pointers.push(SourcePointer {
                    gesture,
                    pointer,
                    barrier: r.sequence,
                    latest: 0,
                });
            }
            Class::Up | Class::Cancel => {
                self.pointers
                    .retain(|p| p.gesture != gesture || p.pointer != pointer);
                self.moves.retain(|m| {
                    u64_at(m.bytes.as_slice(), 0) != gesture
                        || u64_at(m.bytes.as_slice(), 8) != pointer
                });
            }
            Class::Resize => {
                self.pointers.clear();
                self.moves.clear();
                self.resize_pending = true;
            }
            _ => {}
        }
    }
    pub fn replace(
        &mut self,
        r: Record,
        received: u64,
        now: u64,
    ) -> Result<MoveAdmission, Failure> {
        r.validate().map_err(|_| Failure::Protocol)?;
        if r.kind != 9 || r.epoch != self.epoch || received > now {
            crate::media::first_error::reject(6, line!(), 0, 0, 0, 0, 0);
            return Err(Failure::Protocol);
        }
        let deadline = received.checked_add(MOVE_LIFETIME).ok_or(Failure::Clock)?;
        if now >= deadline {
            return Ok(MoveAdmission::Expired);
        }
        let gesture = u64_at(&r.body, 0);
        let pointer = u64_at(&r.body, 8);
        let barrier = u64_at(&r.body, 16);
        let raw = &r.body[28..];
        if raw.len() != 32
            || raw[0] != 2
            || raw[1] != 2
            || u64_at(raw, 2) != pointer
            || u16_at(raw, 18) == 0
            || u16_at(raw, 20) == 0
        {
            return Err(Failure::Protocol);
        }
        let Some(p) = self
            .pointers
            .iter_mut()
            .find(|p| p.gesture == gesture && p.pointer == pointer)
        else {
            return Ok(MoveAdmission::Stale);
        };
        if r.sequence <= p.latest {
            return Ok(MoveAdmission::Stale);
        }
        if barrier < p.barrier || barrier > self.critical {
            crate::media::first_error::reject(6, line!(), 0, 0, 0, 0, 0);
            return Err(Failure::Protocol);
        }
        let at = self.moves.iter().position(|m| {
            u64_at(m.bytes.as_slice(), 0) == gesture && u64_at(m.bytes.as_slice(), 8) == pointer
        });
        let replaced = at.is_some();
        if let Some(at) = at {
            self.moves.remove(at);
        }
        let bytes = self.pool.allocate(r.body.clone())?;
        p.latest = r.sequence;
        self.moves.push(SourceMove {
            header: r.with_body(vec![]),
            bytes,
            received,
            deadline,
        });
        Ok(if replaced {
            MoveAdmission::Replaced
        } else {
            MoveAdmission::Queued
        })
    }
    pub fn expire(&mut self, now: u64) {
        self.moves.retain(|m| now < m.deadline);
    }
    pub fn next(&self, now: u64) -> Option<(Record, u64)> {
        let m = self.moves.first()?;
        if now >= m.deadline {
            return None;
        }
        let mut r = m.header.with_body(m.bytes.as_slice().to_vec());
        r.age_us = (now - m.received).div_ceil(1000).try_into().ok()?;
        if r.age_us >= 40000 {
            return None;
        }
        Some((r, m.deadline))
    }
    pub fn accepted(&mut self, r: &Record) {
        self.moves.retain(|m| {
            m.header.sequence != r.sequence || m.bytes.as_slice()[..16] != r.body[..16]
        });
    }
    pub fn next_wakeup(&self) -> Option<u64> {
        self.moves.iter().map(|m| m.deadline).min()
    }
    pub fn clear(&mut self) {
        self.moves.clear();
        self.pointers.clear();
    }
    pub fn sync_epoch(&mut self, epoch: u32) -> Result<(), Failure> {
        if epoch < self.epoch {
            return Err(Failure::Protocol);
        }
        if epoch > self.epoch {
            self.clear();
            self.epoch = epoch;
            self.resize_pending = false;
        }
        Ok(())
    }
    pub fn usage(&self) -> (usize, usize) {
        self.pool.usage()
    }
}
pub fn validate(class: u8, raw: &[u8]) -> Result<Class, Failure> {
    if raw.is_empty() || raw.len() > 924 {
        return Err(Failure::Unsupported);
    }
    let c = match class {
        1 => Class::Down,
        2 => Class::Up,
        3 => Class::Cancel,
        4 => Class::Key,
        5 => Class::Uhid,
        6 => Class::Resize,
        7 => Class::StartApp,
        8 => Class::Wheel,
        9 => Class::Ordinary,
        _ => return Err(Failure::Protocol),
    };
    let valid = match c {
        Class::Down | Class::Up | Class::Cancel => {
            raw.len() == 32
                && raw[0] == 2
                && raw[1]
                    == match c {
                        Class::Down => 0,
                        Class::Up => 1,
                        _ => 3,
                    }
                && u16_at(raw, 18) > 0
                && u16_at(raw, 20) > 0
        }
        Class::Key => raw.len() == 14 && raw[0] == 0 && raw[1] <= 1,
        Class::Uhid => match raw[0] {
            12 => {
                raw.len() >= 10 && {
                    let n = raw[7] as usize;
                    raw.len() >= 10 + n && raw.len() == 10 + n + u16_at(raw, 8 + n) as usize
                }
            }
            13 => raw.len() >= 5 && raw.len() == 5 + u16_at(raw, 3) as usize,
            14 => raw.len() == 3,
            _ => false,
        },
        Class::Resize => raw.len() == 5 && raw[0] == 21 && u16_at(raw, 1) > 0 && u16_at(raw, 3) > 0,
        Class::StartApp => {
            raw.len() >= 2 && raw[0] == 16 && raw.len() == 2 + raw[1] as usize && raw[1] > 0
        }
        Class::Wheel => raw.len() == 21 && raw[0] == 3 && u16_at(raw, 9) > 0 && u16_at(raw, 11) > 0,
        Class::Ordinary => match raw[0] {
            1 => raw.len() >= 5 && raw.len() == 5 + u32_at(raw, 1) as usize,
            4 => raw.len() == 2 && raw[1] <= 1,
            5..=7 | 11 | 15 => raw.len() == 1,
            // GET_CLIPBOARD is a small ordered control command.  SET_CLIPBOARD
            // remains on the bounded bulk channel because its payload may be
            // hundreds of KiB and has separate clipboard acknowledgement
            // semantics.
            8 => raw.len() == 2 && raw[1] <= 2,
            10 => raw.len() == 2 && raw[1] <= 1,
            _ => false,
        },
    };
    if valid {
        Ok(c)
    } else if matches!(raw[0], 9 | 18..=20 | 22) {
        Err(Failure::Unsupported)
    } else {
        Err(Failure::Protocol)
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Pointer {
    pub gesture: u64,
    pub pointer: u64,
    pub latest_move: u64,
    pub closing: bool,
}
#[derive(Clone, Debug)]
pub struct WriteLease {
    pub token: u64,
    pub bytes: Bytes,
    pub offset: usize,
    pub deadline: u64,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WriteOutcome {
    Progress,
    Complete { sequence: u64, epoch: u32 },
    MoveComplete,
    CompletedWriteAfterCutoff,
}
struct Command {
    token: u64,
    sequence: u64,
    epoch: u32,
    class: Option<Class>,
    gesture: u64,
    pointer: u64,
    final_move: u64,
    bytes: Bytes,
    deadline: u64,
    offset: usize,
    geometry_release: bool,
}
pub struct Writer {
    epoch: u32,
    next: u64,
    applied: u64,
    serial: u64,
    last: u64,
    terminal: Option<Failure>,
    critical: VecDeque<Command>,
    moves: Vec<Command>,
    current: Option<Command>,
    retired_write: Option<(u64, usize)>,
    pool: Pool,
    move_pool: Pool,
    pointers: Vec<Pointer>,
    keys: Vec<u32>,
    uhids: Vec<u16>,
    pointer_releases: Vec<((u64, u64), [u8; 32])>,
    key_releases: Vec<(u32, [u8; 14])>,
    geometry_deadline: Option<u64>,
    highest_gesture: u64,
    cancelled: Option<(Vec<Pointer>, Vec<u32>, Vec<u16>)>,
    pub written: u64,
    pub late_written: u64,
}
impl Writer {
    pub fn new(epoch: u32) -> Self {
        Self {
            epoch,
            next: 1,
            applied: 0,
            serial: 0,
            last: 0,
            terminal: None,
            critical: VecDeque::new(),
            moves: vec![],
            current: None,
            retired_write: None,
            pool: Pool::new(64, 64 * 1024),
            move_pool: Pool::new(16, 16 * 1024),
            pointers: vec![],
            keys: vec![],
            uhids: vec![],
            pointer_releases: vec![],
            key_releases: vec![],
            geometry_deadline: None,
            highest_gesture: 0,
            cancelled: None,
            written: 0,
            late_written: 0,
        }
    }
    pub fn terminal(&self) -> Option<Failure> {
        self.terminal
    }
    pub fn applied(&self) -> u64 {
        self.applied
    }
    pub(crate) fn epoch(&self) -> u32 {
        self.epoch
    }
    pub(crate) fn cancellation_pending(&self) -> bool {
        self.cancelled.is_some()
    }
    /// Geometry release frames precede successor stock frames and retain the
    /// original Resize deadline. They use the same writer and command pool.
    pub fn draining_geometry(&self) -> bool {
        self.geometry_deadline.is_some()
    }
    pub fn usage(&self) -> ((usize, usize), (usize, usize)) {
        (self.pool.usage(), self.move_pool.usage())
    }
    pub fn pointers(&self) -> &[Pointer] {
        &self.pointers
    }
    pub fn cancellation(&mut self) -> Option<(Vec<Pointer>, Vec<u32>, Vec<u16>)> {
        self.cancelled.take()
    }
    pub fn change_epoch(&mut self, epoch: u32) -> Result<(), Failure> {
        if self.current.is_some()
            || !self.critical.is_empty()
            || self.draining_geometry()
            || !self.pointers.is_empty()
            || !self.keys.is_empty()
        {
            self.retire(Failure::Sink);
            return Err(Failure::Sink);
        }
        // A hardware keyboard/gamepad ID is not pixel geometry. Unsafe
        // coordinate/key ownership retires above; a clean epoch preserves UHID.
        self.pointers.clear();
        self.moves.clear();
        self.epoch = epoch;
        Ok(())
    }
    pub fn next_wakeup(&self) -> Option<u64> {
        self.critical
            .iter()
            .chain(self.moves.iter())
            .chain(self.current.iter())
            .map(|c| c.deadline)
            .chain(self.geometry_deadline)
            .min()
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
        if self.critical.iter().any(|c| now >= c.deadline)
            || self.current.as_ref().is_some_and(|c| now >= c.deadline)
            || self
                .geometry_deadline
                .is_some_and(|deadline| now >= deadline)
        {
            self.retire(Failure::Deadline);
            return Err(Failure::Deadline);
        }
        self.moves.retain(|c| now < c.deadline);
        Ok(())
    }
    pub fn ingest(&mut self, r: Record, now: u64) -> Result<(), Failure> {
        self.tick(now)?;
        if self.cancelled.is_some() {
            return Err(Failure::Sink);
        }
        r.validate().map_err(|_| Failure::Protocol)?;
        if r.epoch != self.epoch {
            return Err(Failure::Protocol);
        }
        if r.kind == 9 {
            return self.ingest_move(r, now);
        }
        if r.kind != 8 {
            return Err(Failure::Protocol);
        }
        if r.sequence < self.next {
            return if r.sequence <= self.applied {
                Ok(())
            } else {
                Err(Failure::Protocol)
            };
        }
        if r.sequence != self.next {
            return Err(Failure::Protocol);
        }
        let raw = &r.body[36..];
        let class = validate(r.body[0], raw)?;
        let gesture = u64_at(&r.body, 8);
        let pointer = u64_at(&r.body, 16);
        let final_move = u64_at(&r.body, 24);
        let release = matches!(class, Class::Up | Class::Cancel)
            || class == Class::Key && raw[1] == 1
            || class == Class::Uhid && raw[0] == 14;
        if !release && self.pool.usage().0 >= 48 {
            return Err(Failure::Capacity);
        }
        // Reserve ownership before exposing bytes to the external sink. A
        // queued release is not evidence that its key/device has been released.
        if class == Class::Key && raw[1] == 0 {
            let mut possible = self.keys.clone();
            for command in self.critical.iter().chain(self.current.iter()) {
                if command.class == Some(Class::Key) && command.bytes.as_slice()[1] == 0 {
                    let key = u32_at(command.bytes.as_slice(), 2);
                    if !possible.contains(&key) {
                        possible.push(key);
                    }
                }
            }
            if !possible.contains(&u32_at(raw, 2)) && possible.len() >= 64 {
                return Err(Failure::Capacity);
            }
        }
        if class == Class::Uhid && raw[0] != 14 {
            let mut possible = self.uhids.clone();
            for command in self.critical.iter().chain(self.current.iter()) {
                if command.class == Some(Class::Uhid) && command.bytes.as_slice()[0] != 14 {
                    let id = u16_at(command.bytes.as_slice(), 1);
                    if !possible.contains(&id) {
                        possible.push(id);
                    }
                }
            }
            if !possible.contains(&u16_at(raw, 1)) && possible.len() >= 64 {
                return Err(Failure::Capacity);
            }
        }
        if matches!(class, Class::Down | Class::Up | Class::Cancel) {
            if gesture == 0 || u64_at(raw, 2) != pointer {
                return Err(Failure::Protocol);
            }
            if class == Class::Down {
                let pending_down = self
                    .critical
                    .iter()
                    .chain(self.current.iter())
                    .filter(|c| c.class == Some(Class::Down))
                    .count();
                if self.pointers.len() + pending_down >= 16
                    || gesture < self.highest_gesture
                    || gesture == self.highest_gesture
                        && !self.pointers.iter().any(|p| p.gesture == gesture)
                {
                    return Err(Failure::Protocol);
                }
                if self
                    .pointers
                    .iter()
                    .any(|p| p.gesture == gesture && p.pointer == pointer)
                    || self.critical.iter().chain(self.current.iter()).any(|c| {
                        c.class == Some(Class::Down) && c.gesture == gesture && c.pointer == pointer
                    })
                {
                    return Err(Failure::Protocol);
                }
            } else {
                if !self
                    .pointers
                    .iter()
                    .any(|p| p.gesture == gesture && p.pointer == pointer)
                    && !self.critical.iter().chain(self.current.iter()).any(|c| {
                        c.class == Some(Class::Down) && c.gesture == gesture && c.pointer == pointer
                    })
                {
                    return Err(Failure::Protocol);
                }
                if self.pointers.iter().any(|p| {
                    p.gesture == gesture && p.pointer == pointer && final_move < p.latest_move
                }) {
                    return Err(Failure::Protocol);
                }
            }
        }
        let bytes = match self.pool.allocate(raw.to_vec()) {
            Ok(b) => b,
            Err(e) => {
                if release {
                    self.retire(e)
                }
                return Err(e);
            }
        };
        let deadline = now
            .checked_add(TRANSACTION_LIFETIME - r.age_us as u64 * 1000)
            .ok_or(Failure::Clock)?;
        self.serial = self.serial.checked_add(1).ok_or(Failure::Capacity)?;
        if matches!(class, Class::Up | Class::Cancel) {
            self.moves
                .retain(|m| m.gesture != gesture || m.pointer != pointer);
            if let Some(p) = self
                .pointers
                .iter_mut()
                .find(|p| p.gesture == gesture && p.pointer == pointer)
            {
                p.closing = true;
            }
        }
        self.critical.push_back(Command {
            token: self.serial,
            sequence: r.sequence,
            epoch: r.epoch,
            class: Some(class),
            gesture,
            pointer,
            final_move,
            bytes,
            deadline,
            offset: 0,
            geometry_release: false,
        });
        self.next = self.next.checked_add(1).ok_or(Failure::Capacity)?;
        Ok(())
    }
    fn ingest_move(&mut self, r: Record, now: u64) -> Result<(), Failure> {
        let gesture = u64_at(&r.body, 0);
        let pointer = u64_at(&r.body, 8);
        let barrier = u64_at(&r.body, 16);
        let raw = &r.body[28..];
        if raw.len() != 32
            || raw[0] != 2
            || raw[1] != 2
            || u64_at(raw, 2) != pointer
            || u16_at(raw, 18) == 0
            || u16_at(raw, 20) == 0
        {
            return Err(Failure::Protocol);
        }
        let Some(p) = self
            .pointers
            .iter_mut()
            .find(|p| p.gesture == gesture && p.pointer == pointer)
        else {
            return Ok(());
        };
        if barrier > self.applied || p.closing || r.sequence <= p.latest_move {
            return Ok(());
        }
        self.moves
            .retain(|m| m.gesture != gesture || m.pointer != pointer);
        let bytes = self.move_pool.allocate(raw.to_vec())?;
        p.latest_move = r.sequence;
        self.serial = self.serial.checked_add(1).ok_or(Failure::Capacity)?;
        self.moves.push(Command {
            token: self.serial,
            sequence: r.sequence,
            epoch: r.epoch,
            class: None,
            gesture,
            pointer,
            final_move: 0,
            bytes,
            deadline: now
                .checked_add(MOVE_LIFETIME - r.age_us as u64 * 1000)
                .ok_or(Failure::Clock)?,
            offset: 0,
            geometry_release: false,
        });
        Ok(())
    }
    pub fn next_write(&mut self, now: u64) -> Option<WriteLease> {
        self.tick(now).ok()?;
        if self.cancelled.is_some() {
            return None;
        }
        if self.current.is_none() {
            if let Some(deadline) = self.geometry_deadline {
                let (class, gesture, pointer, raw) = if let Some(p) = self.pointers.first() {
                    let Some((_, raw)) = self
                        .pointer_releases
                        .iter()
                        .find(|(identity, _)| *identity == (p.gesture, p.pointer))
                    else {
                        self.retire(Failure::Sink);
                        return None;
                    };
                    (Class::Cancel, p.gesture, p.pointer, raw.to_vec())
                } else if let Some(key) = self.keys.first() {
                    let Some((_, raw)) = self.key_releases.iter().find(|(id, _)| id == key) else {
                        self.retire(Failure::Sink);
                        return None;
                    };
                    (Class::Key, 0, 0, raw.to_vec())
                } else {
                    self.geometry_deadline = None;
                    return self.next_write(now);
                };
                let bytes = match self.pool.allocate(raw) {
                    Ok(bytes) => bytes,
                    Err(reason) => {
                        self.retire(reason);
                        return None;
                    }
                };
                let Some(token) = self.serial.checked_add(1) else {
                    self.retire(Failure::Capacity);
                    return None;
                };
                self.serial = token;
                self.current = Some(Command {
                    token,
                    sequence: 0,
                    epoch: self.epoch,
                    class: Some(class),
                    gesture,
                    pointer,
                    final_move: 0,
                    bytes,
                    deadline,
                    offset: 0,
                    geometry_release: true,
                });
            } else {
                self.current = self.critical.pop_front().or_else(|| {
                    if self.moves.is_empty() {
                        None
                    } else {
                        Some(self.moves.remove(0))
                    }
                });
            }
        }
        let c = self.current.as_ref()?;
        Some(WriteLease {
            token: c.token,
            bytes: c.bytes.clone(),
            offset: c.offset,
            deadline: c.deadline,
        })
    }
    pub fn write_result(
        &mut self,
        token: u64,
        count: usize,
        now: u64,
    ) -> Result<WriteOutcome, Failure> {
        if self.current.is_none() {
            let (expected, remaining) = self.retired_write.as_mut().ok_or(Failure::Protocol)?;
            if *expected != token || count > *remaining {
                return Err(Failure::Protocol);
            }
            *remaining -= count;
            self.written = self.written.saturating_add(count as u64);
            self.late_written = self.late_written.saturating_add(count as u64);
            if *remaining == 0 {
                self.retired_write = None;
                return Ok(WriteOutcome::CompletedWriteAfterCutoff);
            }
            return Err(Failure::Deadline);
        }
        let c = self.current.as_mut().ok_or(Failure::Protocol)?;
        if c.token != token || count > c.bytes.len() - c.offset {
            return Err(Failure::Protocol);
        }
        c.offset += count;
        self.written = self.written.saturating_add(count as u64);
        let complete = c.offset == c.bytes.len();
        let late = self.terminal.is_some() || now >= c.deadline || now < self.last;
        if late {
            self.late_written = self.late_written.saturating_add(count as u64);
            self.retire(if now < self.last {
                Failure::Clock
            } else {
                Failure::Deadline
            });
            if complete {
                self.current = None;
                return Ok(WriteOutcome::CompletedWriteAfterCutoff);
            }
            return Err(Failure::Deadline);
        }
        self.last = now;
        if !complete {
            return Ok(WriteOutcome::Progress);
        }
        let c = self.current.take().unwrap();
        if let Some(class) = c.class {
            let raw = c.bytes.as_slice();
            match class {
                Class::Down => {
                    if self.pointers.len() >= 16 {
                        self.retire(Failure::Capacity);
                        return Err(Failure::Capacity);
                    }
                    self.highest_gesture = self.highest_gesture.max(c.gesture);
                    self.pointers.push(Pointer {
                        gesture: c.gesture,
                        pointer: c.pointer,
                        latest_move: 0,
                        closing: self.critical.iter().any(|q| {
                            matches!(q.class, Some(Class::Up | Class::Cancel))
                                && q.gesture == c.gesture
                                && q.pointer == c.pointer
                        }),
                    });
                    let mut release: [u8; 32] = raw.try_into().unwrap();
                    release[1] = 3;
                    release[22..].fill(0);
                    self.pointer_releases
                        .push(((c.gesture, c.pointer), release));
                }
                Class::Up | Class::Cancel => {
                    self.pointers
                        .retain(|p| p.gesture != c.gesture || p.pointer != c.pointer);
                    self.moves
                        .retain(|m| m.gesture != c.gesture || m.pointer != c.pointer);
                    let _sealed = c.final_move;
                    self.pointer_releases
                        .retain(|(identity, _)| *identity != (c.gesture, c.pointer));
                }
                Class::Key => {
                    let key = u32_at(raw, 2);
                    if raw[1] == 0 {
                        if !self.keys.contains(&key) {
                            if self.keys.len() >= 64 {
                                self.retire(Failure::Capacity);
                                return Err(Failure::Capacity);
                            }
                            self.keys.push(key)
                        }
                        let mut release: [u8; 14] = raw.try_into().unwrap();
                        release[1] = 1;
                        release[6..10].fill(0);
                        if let Some((_, old)) =
                            self.key_releases.iter_mut().find(|(id, _)| *id == key)
                        {
                            *old = release;
                        } else {
                            self.key_releases.push((key, release));
                        }
                    } else {
                        self.keys.retain(|k| *k != key);
                        self.key_releases.retain(|(id, _)| *id != key);
                    }
                }
                Class::Uhid => {
                    let id = u16_at(raw, 1);
                    if raw[0] == 14 {
                        self.uhids.retain(|v| *v != id)
                    } else if !self.uhids.contains(&id) {
                        if self.uhids.len() >= 64 {
                            self.retire(Failure::Capacity);
                            return Err(Failure::Capacity);
                        }
                        self.uhids.push(id)
                    }
                }
                Class::Resize => {
                    self.moves.clear();
                    if !self.pointers.is_empty() || !self.keys.is_empty() {
                        self.geometry_deadline = Some(c.deadline);
                        for p in &mut self.pointers {
                            p.closing = true;
                        }
                    }
                }
                _ => {}
            }
            if c.geometry_release {
                if self.pointers.is_empty() && self.keys.is_empty() {
                    self.geometry_deadline = None;
                }
                return Ok(WriteOutcome::MoveComplete);
            }
            self.applied = c.sequence;
            Ok(WriteOutcome::Complete {
                sequence: c.sequence,
                epoch: c.epoch,
            })
        } else {
            Ok(WriteOutcome::MoveComplete)
        }
    }
    fn capture_cancellation(&mut self) {
        if self.cancelled.is_some() {
            return;
        }
        let mut pointers = self.pointers.clone();
        let mut keys = self.keys.clone();
        let mut uhids = self.uhids.clone();
        if let Some(c) = &self.current {
            if c.offset > 0 {
                match c.class {
                    Some(Class::Down) => {
                        if pointers.len() < 16
                            && !pointers
                                .iter()
                                .any(|p| p.gesture == c.gesture && p.pointer == c.pointer)
                        {
                            pointers.push(Pointer {
                                gesture: c.gesture,
                                pointer: c.pointer,
                                latest_move: 0,
                                closing: true,
                            })
                        }
                    }
                    Some(Class::Key) => {
                        let r = c.bytes.as_slice();
                        let key = u32_at(r, 2);
                        if r[1] == 0 && keys.len() < 64 && !keys.contains(&key) {
                            keys.push(key)
                        }
                    }
                    Some(Class::Uhid) => {
                        let r = c.bytes.as_slice();
                        let id = u16_at(r, 1);
                        if r[0] != 14 && uhids.len() < 64 && !uhids.contains(&id) {
                            uhids.push(id)
                        }
                    }
                    _ => {}
                }
            }
        }
        self.cancelled = Some((pointers, keys, uhids));
    }
    pub fn retire(&mut self, reason: Failure) {
        if self.terminal.is_some() {
            return;
        }
        self.capture_cancellation();
        self.terminal = Some(reason);
        if let Some(c) = self.current.take() {
            self.retired_write = Some((c.token, c.bytes.len() - c.offset));
        }
        self.critical.clear();
        self.moves.clear();
        self.pointers.clear();
        self.keys.clear();
        self.uhids.clear();
        self.pointer_releases.clear();
        self.key_releases.clear();
        self.geometry_deadline = None;
    }
}
