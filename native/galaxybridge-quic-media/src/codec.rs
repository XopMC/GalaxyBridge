use crate::Failure;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Codec {
    H264,
    H265,
    Aac,
}
#[derive(Clone, Debug)]
struct H264Sps {
    id: u64,
    frame_bits: usize,
    poc_bits: usize,
    mbs: u64,
}
#[derive(Clone, Debug)]
struct H264Pps {
    id: u64,
    sps: u64,
    bottom: bool,
    redundant: bool,
}
#[derive(Clone, Debug)]
struct HevcSps {
    id: u64,
    vps: u8,
    poc_bits: usize,
    address_bits: usize,
    separate: bool,
    ctbs: u64,
}
#[derive(Clone, Debug)]
struct HevcPps {
    id: u64,
    sps: u64,
    dependent: bool,
    output: bool,
    extra: usize,
}
#[derive(Clone, Debug)]
pub struct Configuration {
    codec: Codec,
    h264_sps: Vec<H264Sps>,
    h264_pps: Vec<H264Pps>,
    hevc_vps: Vec<u8>,
    hevc_sps: Vec<HevcSps>,
    hevc_pps: Vec<HevcPps>,
}
impl Configuration {
    pub fn parse(codec: Codec, bytes: &[u8]) -> Result<Self, Failure> {
        if bytes.is_empty() || bytes.len() > crate::wire::SMALL_OBJECT {
            return Err(Failure::Codec);
        }
        let mut c = Self {
            codec,
            h264_sps: vec![],
            h264_pps: vec![],
            hevc_vps: vec![],
            hevc_sps: vec![],
            hevc_pps: vec![],
        };
        if codec == Codec::Aac {
            // Stock AAC-LC, 48 kHz stereo, 1024-sample GA frame; no SBR/PS/960-frame extension.
            let mut b = Bits::new(bytes);
            if b.take(5)? != 2
                || b.take(4)? != 3
                || b.take(4)? != 2
                || b.take(1)? != 0
                || b.take(1)? != 0
                || b.take(1)? != 0
            {
                return Err(Failure::Unsupported);
            }
            if bytes.len() != 2 {
                return Err(Failure::Unsupported);
            }
            return Ok(c);
        }
        each_nal(bytes, |n| {
            if n[0] & 0x80 != 0 {
                return Err(Failure::Codec);
            }
            match codec {
                Codec::H264 => match n[0] & 31 {
                    7 => {
                        let s = parse_h264_sps(&n[1..])?;
                        if c.h264_sps.iter().any(|v| v.id == s.id) || c.h264_sps.len() >= 32 {
                            return Err(Failure::Codec);
                        }
                        c.h264_sps.push(s);
                    }
                    8 => {
                        let p = parse_h264_pps(&n[1..])?;
                        if c.h264_pps.iter().any(|v| v.id == p.id) || c.h264_pps.len() >= 256 {
                            return Err(Failure::Codec);
                        }
                        c.h264_pps.push(p);
                    }
                    _ => return Err(Failure::Unsupported),
                },
                Codec::H265 => {
                    let kind = hevc_header(n)?;
                    let mut bits = Bits::new(&n[2..]);
                    match kind {
                        32 => {
                            let id = bits.take(4)? as u8;
                            bits.skip(12)?;
                            if c.hevc_vps.contains(&id) {
                                return Err(Failure::Codec);
                            }
                            c.hevc_vps.push(id);
                        }
                        33 => {
                            let s = parse_hevc_sps(&n[2..])?;
                            if c.hevc_sps.iter().any(|v| v.id == s.id) || c.hevc_sps.len() >= 16 {
                                return Err(Failure::Codec);
                            }
                            c.hevc_sps.push(s);
                        }
                        34 => {
                            let p = HevcPps {
                                id: bits.ue()?,
                                sps: bits.ue()?,
                                dependent: bits.take(1)? != 0,
                                output: bits.take(1)? != 0,
                                extra: bits.take(3)? as usize,
                            };
                            if p.id > 63
                                || p.sps > 15
                                || c.hevc_pps.iter().any(|v| v.id == p.id)
                                || c.hevc_pps.len() >= 64
                            {
                                return Err(Failure::Codec);
                            }
                            c.hevc_pps.push(p);
                        }
                        _ => return Err(Failure::Unsupported),
                    }
                }
                Codec::Aac => unreachable!(),
            }
            Ok(())
        })?;
        match codec {
            Codec::H264 => {
                if c.h264_sps.is_empty()
                    || c.h264_pps.is_empty()
                    || c.h264_pps
                        .iter()
                        .any(|p| !c.h264_sps.iter().any(|s| s.id == p.sps))
                {
                    return Err(Failure::Codec);
                }
            }
            Codec::H265 => {
                if c.hevc_sps.is_empty()
                    || c.hevc_pps.is_empty()
                    || c.hevc_sps.iter().any(|s| !c.hevc_vps.contains(&s.vps))
                    || c.hevc_pps
                        .iter()
                        .any(|p| !c.hevc_sps.iter().any(|s| s.id == p.sps))
                {
                    return Err(Failure::Codec);
                }
            }
            Codec::Aac => {}
        }
        Ok(c)
    }
    pub fn codec(&self) -> Codec {
        self.codec
    }
    /// Validates all VCL slice headers needed by the non-reordered IDR policy.
    /// Entropy decoding remains the actual native decoder's responsibility.
    pub fn independent(&self, bytes: &[u8], key: bool) -> Result<bool, Failure> {
        if bytes.is_empty() || bytes.len() > crate::wire::VIDEO_AU {
            return Err(Failure::Codec);
        }
        if self.codec == Codec::Aac {
            return if bytes.len() <= crate::wire::SMALL_OBJECT {
                Ok(true)
            } else {
                Err(Failure::Codec)
            };
        }
        let mut picture: Option<(bool, u64, u64, u64)> = None;
        let mut last_address = 0;
        let mut slices = 0;
        each_nal(bytes, |n| {
            if n[0] & 0x80 != 0 {
                return Err(Failure::Codec);
            }
            let (idr, address, pps_id, frame, poc) = match self.codec {
                Codec::H264 => {
                    let kind = n[0] & 31;
                    if matches!(kind, 6 | 9 | 12) {
                        return Ok(());
                    }
                    if !matches!(kind, 1 | 5) {
                        return Err(Failure::Unsupported);
                    }
                    let idr = kind == 5;
                    if idr && n[0] & 0x60 == 0 {
                        return Err(Failure::Codec);
                    }
                    let mut b = Bits::new(&n[1..]);
                    let address = b.ue()?;
                    let typ = b.ue()?;
                    if typ > 9 {
                        return Err(Failure::Codec);
                    }
                    if !matches!(typ % 5, 0 | 2) || idr && typ % 5 != 2 {
                        return Err(Failure::Unsupported);
                    }
                    let pps_id = b.ue()?;
                    let p = self
                        .h264_pps
                        .iter()
                        .find(|p| p.id == pps_id)
                        .ok_or(Failure::Codec)?;
                    let s = self
                        .h264_sps
                        .iter()
                        .find(|s| s.id == p.sps)
                        .ok_or(Failure::Codec)?;
                    if address >= s.mbs {
                        return Err(Failure::Codec);
                    }
                    let frame = b.take(s.frame_bits)?;
                    let idr_id = if idr { b.ue()? } else { 0 };
                    let poc = if s.poc_bits > 0 {
                        b.take(s.poc_bits)?
                    } else {
                        0
                    };
                    if p.bottom {
                        if b.se()? != 0 {
                            return Err(Failure::Unsupported);
                        }
                    }
                    if p.redundant && b.ue()? != 0 {
                        return Err(Failure::Unsupported);
                    }
                    b.take(1)?;
                    (idr, address, pps_id, (frame << 32) | idr_id, poc)
                }
                Codec::H265 => {
                    let kind = hevc_header(n)?;
                    if matches!(kind, 35 | 39 | 40) {
                        return Ok(());
                    }
                    if !matches!(kind, 0 | 1 | 19 | 20) {
                        return Err(Failure::Unsupported);
                    }
                    let idr = kind == 19 || kind == 20;
                    let mut b = Bits::new(&n[2..]);
                    let first = b.take(1)? != 0;
                    if idr {
                        b.take(1)?;
                    }
                    let pps_id = b.ue()?;
                    let p = self
                        .hevc_pps
                        .iter()
                        .find(|p| p.id == pps_id)
                        .ok_or(Failure::Codec)?;
                    let s = self
                        .hevc_sps
                        .iter()
                        .find(|s| s.id == p.sps)
                        .ok_or(Failure::Codec)?;
                    let address = if first {
                        0
                    } else {
                        if p.dependent && b.take(1)? != 0 {
                            return Err(Failure::Unsupported);
                        }
                        b.take(s.address_bits)?
                    };
                    if address >= s.ctbs {
                        return Err(Failure::Codec);
                    }
                    b.skip(p.extra)?;
                    let typ = b.ue()?;
                    if !matches!(typ, 1 | 2) || idr && typ != 2 {
                        return Err(Failure::Unsupported);
                    }
                    if p.output {
                        b.take(1)?;
                    }
                    if s.separate {
                        b.take(2)?;
                    }
                    let poc = if idr { 0 } else { b.take(s.poc_bits)? };
                    b.take(1)?;
                    (idr, address, pps_id, kind as u64, poc)
                }
                Codec::Aac => unreachable!(),
            };
            let identity = (idr, pps_id, frame, poc);
            if slices == 0 {
                if address != 0 {
                    return Err(Failure::Codec);
                }
                picture = Some(identity)
            } else if picture != Some(identity) || address <= last_address {
                return Err(Failure::Codec);
            }
            slices += 1;
            last_address = address;
            Ok(())
        })?;
        let independent = picture.ok_or(Failure::Codec)?.0;
        if key && !independent {
            return Err(Failure::Codec);
        }
        Ok(independent)
    }
}

fn parse_h264_sps(data: &[u8]) -> Result<H264Sps, Failure> {
    let mut b = Bits::new(data);
    let profile = b.take(8)?;
    b.take(8)?;
    b.take(8)?;
    let id = b.ue()?;
    if id > 31 {
        return Err(Failure::Codec);
    }
    if matches!(
        profile,
        100 | 110 | 122 | 244 | 44 | 83 | 86 | 118 | 128 | 138 | 139 | 134 | 135
    ) {
        if b.ue()? != 1 || b.ue()? != 0 || b.ue()? != 0 {
            return Err(Failure::Unsupported);
        }
        b.take(1)?;
        if b.take(1)? != 0 {
            return Err(Failure::Unsupported);
        }
    } else if !matches!(profile, 66 | 77 | 88) {
        return Err(Failure::Unsupported);
    }
    let frame_bits = b.ue()?.checked_add(4).ok_or(Failure::Codec)? as usize;
    if frame_bits > 16 {
        return Err(Failure::Codec);
    }
    let poc_bits = match b.ue()? {
        0 => {
            let n = b.ue()? + 4;
            if n > 16 {
                return Err(Failure::Codec);
            }
            n as usize
        }
        2 => 0,
        _ => return Err(Failure::Unsupported),
    };
    b.ue()?;
    if b.take(1)? != 0 {
        return Err(Failure::Unsupported);
    }
    let width = b.ue()?.checked_add(1).ok_or(Failure::Codec)?;
    let height = b.ue()?.checked_add(1).ok_or(Failure::Codec)?;
    if b.take(1)? != 1 {
        return Err(Failure::Unsupported);
    }
    b.take(1)?;
    if b.take(1)? != 0 {
        for _ in 0..4 {
            b.ue()?;
        }
    }
    b.take(1)?;
    Ok(H264Sps {
        id,
        frame_bits,
        poc_bits,
        mbs: width.checked_mul(height).ok_or(Failure::Codec)?,
    })
}
fn parse_h264_pps(data: &[u8]) -> Result<H264Pps, Failure> {
    let mut b = Bits::new(data);
    let id = b.ue()?;
    let sps = b.ue()?;
    if id > 255 || sps > 31 {
        return Err(Failure::Codec);
    }
    b.take(1)?;
    let bottom = b.take(1)? != 0;
    if b.ue()? != 0 {
        return Err(Failure::Unsupported);
    }
    b.ue()?;
    b.ue()?;
    b.take(1)?;
    b.take(2)?;
    b.se()?;
    b.se()?;
    b.se()?;
    b.take(1)?;
    b.take(1)?;
    let redundant = b.take(1)? != 0;
    Ok(H264Pps {
        id,
        sps,
        bottom,
        redundant,
    })
}
fn parse_hevc_sps(data: &[u8]) -> Result<HevcSps, Failure> {
    let mut b = Bits::new(data);
    let vps = b.take(4)? as u8;
    let layers = b.take(3)?;
    b.take(1)?;
    // The first profile rejects temporal sublayers rather than guessing their dependency policy.
    if layers != 0 {
        return Err(Failure::Unsupported);
    }
    b.skip(96)?;
    let id = b.ue()?;
    if id > 15 {
        return Err(Failure::Codec);
    }
    let chroma = b.ue()?;
    if chroma > 3 {
        return Err(Failure::Codec);
    }
    let separate = chroma == 3 && b.take(1)? != 0;
    if chroma != 1 {
        return Err(Failure::Unsupported);
    }
    let width = b.ue()?;
    let height = b.ue()?;
    if width == 0 || height == 0 {
        return Err(Failure::Codec);
    }
    if b.take(1)? != 0 {
        for _ in 0..4 {
            b.ue()?;
        }
    }
    if b.ue()? != 0 || b.ue()? != 0 {
        return Err(Failure::Unsupported);
    }
    let poc_bits = (b.ue()? + 4) as usize;
    if poc_bits > 16 {
        return Err(Failure::Codec);
    }
    b.take(1)?;
    b.ue()?;
    if b.ue()? != 0 {
        return Err(Failure::Unsupported);
    }
    b.ue()?;
    let block = b
        .ue()?
        .checked_add(3)
        .and_then(|v| v.checked_add(b.ue().ok()?))
        .ok_or(Failure::Codec)?;
    if !(3..=6).contains(&block) {
        return Err(Failure::Codec);
    }
    let size = 1u64 << block;
    let ctbs = width
        .div_ceil(size)
        .checked_mul(height.div_ceil(size))
        .ok_or(Failure::Codec)?;
    let address_bits = if ctbs <= 1 {
        0
    } else {
        (64 - (ctbs - 1).leading_zeros()) as usize
    };
    Ok(HevcSps {
        id,
        vps,
        poc_bits,
        address_bits,
        separate,
        ctbs,
    })
}
fn hevc_header(n: &[u8]) -> Result<u8, Failure> {
    if n.len() < 3
        || n[0] & 0x80 != 0
        || ((n[0] & 1) as u16 * 32 + (n[1] >> 3) as u16) != 0
        || n[1] & 7 != 1
    {
        return Err(Failure::Unsupported);
    }
    Ok((n[0] >> 1) & 63)
}

fn prefix(b: &[u8], i: usize) -> usize {
    if b.get(i..i + 4) == Some(&[0, 0, 0, 1]) {
        4
    } else if b.get(i..i + 3) == Some(&[0, 0, 1]) {
        3
    } else {
        0
    }
}
fn each_nal(bytes: &[u8], mut f: impl FnMut(&[u8]) -> Result<(), Failure>) -> Result<(), Failure> {
    if bytes.is_empty() {
        return Err(Failure::Codec);
    }
    let mut cursor = 0;
    let mut count = 0;
    while cursor < bytes.len() {
        let p = prefix(bytes, cursor);
        if p == 0 {
            return Err(Failure::Codec);
        }
        let start = cursor + p;
        let mut end = start;
        while end < bytes.len() && prefix(bytes, end) == 0 {
            end += 1
        }
        let next = end;
        while end > start && bytes[end - 1] == 0 {
            end -= 1
        }
        if end == start {
            return Err(Failure::Codec);
        }
        count += 1;
        if count > 4096 {
            return Err(Failure::Capacity);
        }
        f(&bytes[start..end])?;
        cursor = next;
    }
    Ok(())
}
struct Bits<'a> {
    data: &'a [u8],
    at: usize,
    value: u8,
    left: usize,
    zeros: usize,
    reads: usize,
}
impl<'a> Bits<'a> {
    fn new(data: &'a [u8]) -> Self {
        Self {
            data,
            at: 0,
            value: 0,
            left: 0,
            zeros: 0,
            reads: 0,
        }
    }
    fn take(&mut self, n: usize) -> Result<u64, Failure> {
        if n > 64 {
            return Err(Failure::Codec);
        }
        let mut value = 0;
        for _ in 0..n {
            self.reads += 1;
            if self.reads > 8192 {
                return Err(Failure::Unsupported);
            }
            if self.left == 0 {
                let mut byte = *self.data.get(self.at).ok_or(Failure::Codec)?;
                self.at += 1;
                if self.zeros >= 2 && byte == 3 {
                    byte = *self.data.get(self.at).ok_or(Failure::Codec)?;
                    if byte > 3 {
                        return Err(Failure::Codec);
                    }
                    self.at += 1;
                    self.zeros = 0;
                }
                self.zeros = if byte == 0 { self.zeros + 1 } else { 0 };
                self.value = byte;
                self.left = 8;
            }
            self.left -= 1;
            value = (value << 1) | ((self.value >> self.left) & 1) as u64;
        }
        Ok(value)
    }
    fn skip(&mut self, mut n: usize) -> Result<(), Failure> {
        while n > 0 {
            let step = n.min(64);
            self.take(step)?;
            n -= step;
        }
        Ok(())
    }
    fn ue(&mut self) -> Result<u64, Failure> {
        let mut zeros = 0;
        while self.take(1)? == 0 {
            zeros += 1;
            if zeros > 31 {
                return Err(Failure::Codec);
            }
        }
        Ok((1u64 << zeros) - 1 + self.take(zeros)?)
    }
    fn se(&mut self) -> Result<i64, Failure> {
        let code = self.ue()?;
        Ok(if code % 2 == 0 {
            -(code as i64 / 2)
        } else {
            (code as i64 + 1) / 2
        })
    }
}
