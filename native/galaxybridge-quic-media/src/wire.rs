use galaxybridge_quic::Lane;

pub const HEADER: usize = 64;
pub const BODY: usize = 960;
pub const VIDEO_AU: usize = 4 * 1024 * 1024;
pub const SMALL_OBJECT: usize = 64 * 1024;
/// Private negotiated marker: only an independently decodable video AU that
/// answers an active recovery request may use the bounded reliable media lane.
pub const RELIABLE_RECOVERY_FLAG: u16 = 4;
pub const XOR_PARITY_KIND: u8 = 15;

/// CRC-16/CCITT-FALSE is only a deterministic corruption guard for the parity
/// body. QUIC AEAD remains the authenticity and in-flight integrity boundary.
pub fn parity_checksum(bytes: &[u8]) -> u16 {
    let mut crc = 0xffffu16;
    for byte in bytes {
        crc ^= (*byte as u16) << 8;
        for _ in 0..8 {
            crc = if crc & 0x8000 != 0 {
                (crc << 1) ^ 0x1021
            } else {
                crc << 1
            };
        }
    }
    crc
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Invalid;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Record {
    pub kind: u8,
    pub track: u8,
    pub flags: u16,
    pub generation: u64,
    pub epoch: u32,
    pub config: u32,
    pub sequence: u64,
    pub pts: u64,
    pub total: u32,
    pub index: u16,
    pub count: u16,
    pub age_us: u32,
    pub lifetime_us: u32,
    pub body: Vec<u8>,
}

impl Record {
    pub fn with_body(&self, body: Vec<u8>) -> Self {
        Self {
            kind: self.kind,
            track: self.track,
            flags: self.flags,
            generation: self.generation,
            epoch: self.epoch,
            config: self.config,
            sequence: self.sequence,
            pts: self.pts,
            total: self.total,
            index: self.index,
            count: self.count,
            age_us: self.age_us,
            lifetime_us: self.lifetime_us,
            body,
        }
    }
    pub fn lane(&self) -> Lane {
        if (self.kind == 5 && self.flags & RELIABLE_RECOVERY_FLAG == 0)
            || self.kind == XOR_PARITY_KIND
            || self.kind == 13
            || (self.kind == 14 && self.body.first() == Some(&13))
            || self.kind == 9
        {
            Lane::Datagram
        } else {
            Lane::Reliable
        }
    }
    pub fn decode(lane: Lane, b: &[u8]) -> Result<Self, Invalid> {
        if b.len() < HEADER
            || b.len() > HEADER + BODY
            || &b[..4] != b"GQM1"
            || b[50..52] != [0, 0]
            || b[60..64] != [0; 4]
        {
            return Err(Invalid);
        }
        let r = Self {
            kind: b[4],
            track: b[5],
            flags: u16_at(b, 6),
            generation: u64_at(b, 8),
            epoch: u32_at(b, 16),
            config: u32_at(b, 20),
            sequence: u64_at(b, 24),
            pts: u64_at(b, 32),
            total: u32_at(b, 40),
            index: u16_at(b, 44),
            count: u16_at(b, 46),
            age_us: u32_at(b, 52),
            lifetime_us: u32_at(b, 56),
            body: b[64..].to_vec(),
        };
        if r.lane() != lane || u16_at(b, 48) as usize != r.body.len() {
            return Err(Invalid);
        }
        r.validate()?;
        Ok(r)
    }
    pub fn encode(&self) -> Result<Vec<u8>, Invalid> {
        self.validate()?;
        let mut b = vec![0; HEADER + self.body.len()];
        b[..4].copy_from_slice(b"GQM1");
        b[4] = self.kind;
        b[5] = self.track;
        b[6..8].copy_from_slice(&self.flags.to_be_bytes());
        b[8..16].copy_from_slice(&self.generation.to_be_bytes());
        b[16..20].copy_from_slice(&self.epoch.to_be_bytes());
        b[20..24].copy_from_slice(&self.config.to_be_bytes());
        b[24..32].copy_from_slice(&self.sequence.to_be_bytes());
        b[32..40].copy_from_slice(&self.pts.to_be_bytes());
        b[40..44].copy_from_slice(&self.total.to_be_bytes());
        b[44..46].copy_from_slice(&self.index.to_be_bytes());
        b[46..48].copy_from_slice(&self.count.to_be_bytes());
        b[48..50].copy_from_slice(&(self.body.len() as u16).to_be_bytes());
        b[52..56].copy_from_slice(&self.age_us.to_be_bytes());
        b[56..60].copy_from_slice(&self.lifetime_us.to_be_bytes());
        b[64..].copy_from_slice(&self.body);
        Ok(b)
    }
    pub fn validate(&self) -> Result<(), Invalid> {
        let r = self;
        if !(1..=XOR_PARITY_KIND).contains(&r.kind)
            || r.track > 2
            || r.generation == 0
            || r.body.len() > BODY
        {
            return Err(Invalid);
        }
        let media = matches!(r.kind, 2..=7 | 12 | 13 | XOR_PARITY_KIND);
        if media && r.track == 0 || matches!(r.kind, 1 | 8..=11) && r.track != 0 {
            return Err(Invalid);
        }
        if r.kind == 3 && r.track != 1 {
            return Err(Invalid);
        }
        if matches!(r.kind, 5 | XOR_PARITY_KIND) {
            if r.flags & !(3 | RELIABLE_RECOVERY_FLAG) != 0
                || r.flags & 2 == 0
                || (r.flags & RELIABLE_RECOVERY_FLAG != 0
                    && (r.kind != 5 || r.track != 1 || r.flags & 1 == 0))
                || (r.kind == XOR_PARITY_KIND
                    && (r.track != 1 || r.flags & RELIABLE_RECOVERY_FLAG != 0))
            {
                return Err(Invalid);
            }
        } else if r.flags != 0 || r.pts != 0 {
            return Err(Invalid);
        }
        let lifetime = match r.kind {
            1..=4 | 8 | 12 | 13 => 500_000,
            // Matched peers may grant a bounded independent candidate budget.
            // Old120ms records remain valid, including old key AUs. The key
            // flag grants no decode/commit permission: Receiver qualifies VCL.
            5 if r.track == 1
                && r.flags & RELIABLE_RECOVERY_FLAG != 0
                && r.lifetime_us == (crate::RELIABLE_RECOVERY_AU_LIFETIME / 1000) as u32 =>
            {
                r.lifetime_us
            }
            5 | XOR_PARITY_KIND
                if r.track == 1
                    && r.flags & 1 != 0
                    && matches!(r.lifetime_us, 250_000 | 500_000) =>
            {
                r.lifetime_us
            }
            5 | XOR_PARITY_KIND => 120_000,
            9 => 40_000,
            _ => 0,
        };
        if r.lifetime_us != lifetime
            || (lifetime == 0 && r.age_us != 0)
            || (lifetime > 0 && r.age_us >= lifetime)
        {
            return Err(Invalid);
        }
        if matches!(r.kind, 1 | 2 | 12) && (r.epoch != 0 || r.config != 0 || r.sequence != 0) {
            return Err(Invalid);
        }
        if matches!(r.kind, 3..=10 | 13) && (r.epoch == 0 || r.sequence == 0) {
            return Err(Invalid);
        }
        if matches!(r.kind, 4..=7 | 13 | XOR_PARITY_KIND) && r.config == 0 {
            return Err(Invalid);
        }
        if matches!(r.kind, 3 | 8..=12) && r.config != 0 {
            return Err(Invalid);
        }
        if r.kind == 11 && (r.epoch != 0 || r.sequence != 0) {
            return Err(Invalid);
        }
        let max = if matches!(r.kind, 5 | XOR_PARITY_KIND) && r.track == 1 {
            VIDEO_AU
        } else {
            SMALL_OBJECT
        };
        match r.kind {
            XOR_PARITY_KIND => {
                if r.track != 1
                    || r.total as usize <= BODY
                    || r.total as usize > VIDEO_AU
                    || r.count as usize != (r.total as usize).div_ceil(BODY)
                    || r.body.len() != BODY
                    || r.index != parity_checksum(&r.body)
                {
                    return Err(Invalid);
                }
            }
            6 => {
                if r.index != 0 {
                    return Err(Invalid);
                }
                if r.total == 0 {
                    if r.count != 0 || !r.body.is_empty() {
                        return Err(Invalid);
                    }
                } else {
                    let cap = if r.track == 1 { VIDEO_AU } else { SMALL_OBJECT };
                    if r.total as usize > cap
                        || r.count as usize != (r.total as usize).div_ceil(BODY)
                        || r.body.len() != (r.count as usize).div_ceil(8)
                    {
                        return Err(Invalid);
                    }
                    if r.count % 8 != 0 && r.body.last().copied().unwrap_or(0) >> (r.count % 8) != 0
                    {
                        return Err(Invalid);
                    }
                    if r.body.iter().all(|b| *b == 0) {
                        return Err(Invalid);
                    }
                }
            }
            7 | 10 | 13 | 14 => {
                if r.total != 0 || r.index != 0 || r.count != 0 {
                    return Err(Invalid);
                }
                if r.kind == 14 {
                    if r.body.len() != 4
                        || !matches!(r.body[0], 1..=4 | 12 | 13)
                        || r.body[1..] != [0; 3]
                    {
                        return Err(Invalid);
                    }
                    if r.body[0] == 1 {
                        if r.track != 0 || r.epoch != 0 || r.config != 0 || r.sequence != 0 {
                            return Err(Invalid);
                        }
                    } else if r.track == 0 {
                        return Err(Invalid);
                    }
                    match r.body[0] {
                        2 | 12 => {
                            if r.epoch != 0 || r.config != 0 || r.sequence != 0 {
                                return Err(Invalid);
                            }
                        }
                        3 => {
                            if r.track != 1 || r.epoch == 0 || r.config != 0 || r.sequence == 0 {
                                return Err(Invalid);
                            }
                        }
                        4 | 13 => {
                            if r.epoch == 0 || r.config == 0 || r.sequence == 0 {
                                return Err(Invalid);
                            }
                        }
                        _ => {}
                    }
                } else if !r.body.is_empty() {
                    return Err(Invalid);
                }
            }
            _ => {
                if r.total == 0
                    || r.total as usize > max
                    || r.count as usize != (r.total as usize).div_ceil(BODY)
                    || r.index >= r.count
                {
                    return Err(Invalid);
                }
                let remaining = r.total as usize - r.index as usize * BODY;
                if r.body.len() != remaining.min(BODY) {
                    return Err(Invalid);
                }
                if !matches!(r.kind, 4 | 5) && (r.count != 1 || r.index != 0) {
                    return Err(Invalid);
                }
                let valid = match r.kind {
                    1 => {
                        r.body.len() == 20
                            && r.body[4] <= 1
                            && r.body[5] & !(7 | crate::FEATURE_XOR_PARITY) == 0
                            && r.body[5] != 0
                            && r.body[6..8] == [0; 2]
                            && u64_at(&r.body, 12) > 0
                            && (r.body[4] != 1 || u32_at(&r.body, 8) == u32::MAX)
                    }
                    2 | 12 | 11 => r.body.len() == 4 && (r.kind != 11 || r.body[2..] == [0; 2]),
                    3 => r.body.len() == 12,
                    8 => {
                        r.body.len() >= 36
                            && r.body[1..8] == [0; 7]
                            && u32_at(&r.body, 32) as usize == r.body.len() - 36
                    }
                    9 => r.body.len() >= 28 && u32_at(&r.body, 24) as usize == r.body.len() - 28,
                    _ => true,
                };
                if !valid {
                    return Err(Invalid);
                }
            }
        }
        Ok(())
    }
}

pub(crate) fn u16_at(b: &[u8], i: usize) -> u16 {
    u16::from_be_bytes(b[i..i + 2].try_into().unwrap())
}
pub(crate) fn u32_at(b: &[u8], i: usize) -> u32 {
    u32::from_be_bytes(b[i..i + 4].try_into().unwrap())
}
pub(crate) fn u64_at(b: &[u8], i: usize) -> u64 {
    u64::from_be_bytes(b[i..i + 8].try_into().unwrap())
}
