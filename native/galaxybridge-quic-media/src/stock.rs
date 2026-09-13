use crate::{
    wire::{u32_at, u64_at, SMALL_OBJECT, VIDEO_AU},
    Failure, AU_LIFETIME,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Admission {
    Incomplete,
    Metadata(u64),
    AccessUnit { sequence: u64 },
    DroppedAccessUnit { sequence: u64, reason: Failure },
}
pub(crate) struct Source {
    pub reader: Reader,
    pub codec: Option<crate::codec::Codec>,
    pub parsed: Option<crate::codec::Configuration>,
    pub epoch: u32,
    pub version: u32,
    pub next: u64,
    pub watermark: u64,
    pub watermark_due: Option<u64>,
}
impl Source {
    pub fn new(video: bool) -> Self {
        Self {
            reader: Reader::new(video, false),
            codec: None,
            parsed: None,
            epoch: 0,
            version: 0,
            next: 1,
            watermark: 0,
            watermark_due: None,
        }
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum Event {
    Codec([u8; 4]),
    Disabled([u8; 4]),
    VideoSession([u8; 12]),
    Configuration(Vec<u8>),
    Packet { pts: u64, key: bool, bytes: Vec<u8> },
}

pub struct Reader {
    video: bool,
    preamble: usize,
    codec: bool,
    session: bool,
    disabled: bool,
    header: [u8; 12],
    used: usize,
    body: Vec<u8>,
    length: usize,
    started: Option<u64>,
    last: u64,
    failed: Option<Failure>,
}
impl Reader {
    pub fn new(video: bool, preamble: bool) -> Self {
        Self {
            video,
            preamble: if preamble { 65 } else { 0 },
            codec: false,
            session: false,
            disabled: false,
            header: [0; 12],
            used: 0,
            body: vec![],
            length: 0,
            started: None,
            last: 0,
            failed: None,
        }
    }
    pub fn retained(&self) -> usize {
        self.body.capacity()
    }
    pub fn deadline(&self) -> Option<u64> {
        self.started.and_then(|t| t.checked_add(AU_LIFETIME))
    }
    pub fn push(&mut self, bytes: &[u8], now: u64) -> Result<(usize, Option<Event>), Failure> {
        let result = self.read(bytes, now);
        if let Err(e) = result {
            self.failed = Some(e);
            self.body = vec![];
        }
        result
    }
    fn read(&mut self, bytes: &[u8], now: u64) -> Result<(usize, Option<Event>), Failure> {
        if let Some(e) = self.failed {
            return Err(e);
        }
        if now < self.last {
            return Err(Failure::Clock);
        }
        self.last = now;
        if self.deadline().is_some_and(|d| now >= d) {
            return Err(Failure::Deadline);
        }
        if bytes.is_empty() {
            return Ok((0, None));
        }
        if self.disabled {
            return Err(Failure::Protocol);
        }
        now.checked_add(AU_LIFETIME).ok_or(Failure::Clock)?;
        self.started.get_or_insert(now);
        let mut n = 0;
        while n < bytes.len() {
            if self.preamble > 0 {
                if self.preamble == 65 && bytes[n] != 0 {
                    return Err(Failure::Protocol);
                }
                self.preamble -= 1;
                n += 1;
                continue;
            }
            let needed = if self.codec { 12 } else { 4 };
            if self.used < needed {
                let count = (needed - self.used).min(bytes.len() - n);
                self.header[self.used..self.used + count].copy_from_slice(&bytes[n..n + count]);
                self.used += count;
                n += count;
                if self.used < needed {
                    continue;
                }
                if !self.codec {
                    let code: u32 = u32_at(&self.header, 0);
                    let body = self.header[..4].try_into().unwrap();
                    self.codec = true;
                    self.used = 0;
                    self.started = None;
                    if code <= 1 {
                        self.disabled = true;
                        return Ok((n, Some(Event::Disabled(body))));
                    }
                    if (self.video && !matches!(code, 0x68323634 | 0x68323635))
                        || (!self.video && code != 0x00616163)
                    {
                        return Err(Failure::Unsupported);
                    }
                    return Ok((n, Some(Event::Codec(body))));
                }
                if self.header[0] & 0x80 != 0 {
                    if !self.video
                        || u32_at(&self.header, 0) & !0x80000001 != 0
                        || u32_at(&self.header, 4) == 0
                        || u32_at(&self.header, 8) == 0
                    {
                        return Err(Failure::Protocol);
                    }
                    self.session = true;
                    self.used = 0;
                    self.started = None;
                    return Ok((n, Some(Event::VideoSession(self.header))));
                }
                if self.video && !self.session {
                    return Err(Failure::Protocol);
                }
                let flags = u64_at(&self.header, 0);
                self.length = u32_at(&self.header, 8) as usize;
                let cap = if !self.video || flags & (1 << 62) != 0 {
                    SMALL_OBJECT
                } else {
                    VIDEO_AU
                };
                if self.length == 0 || self.length > cap {
                    return Err(Failure::Capacity);
                }
                if flags & (1 << 62) != 0 && flags & ((1u64 << 62) - 1) != 0 {
                    return Err(Failure::Protocol);
                }
                self.body = Vec::with_capacity(self.length);
            }
            let count = (self.length - self.body.len()).min(bytes.len() - n);
            self.body.extend_from_slice(&bytes[n..n + count]);
            n += count;
            if self.body.len() == self.length {
                let bytes = std::mem::take(&mut self.body);
                let flags = u64_at(&self.header, 0);
                self.used = 0;
                self.length = 0;
                self.started = None;
                return Ok((
                    n,
                    Some(if flags & (1 << 62) != 0 {
                        Event::Configuration(bytes)
                    } else {
                        Event::Packet {
                            pts: flags & ((1 << 61) - 1),
                            key: flags & (1 << 61) != 0,
                            bytes,
                        }
                    }),
                ));
            }
        }
        Ok((n, None))
    }
    pub fn eof(&self) -> Result<(), Failure> {
        if let Some(e) = self.failed {
            Err(e)
        } else if self.used != 0 || !self.body.is_empty() || self.preamble != 0 || !self.codec {
            Err(Failure::Protocol)
        } else {
            Ok(())
        }
    }
}
