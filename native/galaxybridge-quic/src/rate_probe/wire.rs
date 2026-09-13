use super::{schedule::Slot, RateShape};
use crate::InvalidRecord;
pub(super) fn data(shape: RateShape, slot: Slot) -> Vec<u8> {
    let size = if slot.kind == 1 { 1000 } else { 320 };
    let mut bytes = Vec::with_capacity(24 + size);
    bytes.extend_from_slice(b"GQR1");
    bytes.extend_from_slice(&[1, slot.kind, shape as u8, 0]);
    for value in [
        slot.ordinal,
        slot.frame,
        size as u32,
        if slot.kind == 1 { 30_000 } else { 600 },
    ] {
        bytes.extend_from_slice(&value.to_be_bytes());
    }
    bytes.extend((0..size).map(|i| (slot.kind as u32 * 17 + slot.ordinal * 31 + i as u32) as u8));
    bytes
}
pub(super) fn parse_data(
    shape: RateShape,
    sequence: u64,
    bytes: &[u8],
) -> Result<Slot, InvalidRecord> {
    if bytes.len() < 24
        || &bytes[..4] != b"GQR1"
        || bytes[4] != 1
        || bytes[6] != shape as u8
        || bytes[7] != 0
    {
        return Err(InvalidRecord);
    }
    let value = |offset| u32::from_be_bytes(bytes[offset..offset + 4].try_into().unwrap());
    let slot = super::schedule::slot(shape, bytes[5], value(8)).ok_or(InvalidRecord)?;
    let size = if slot.kind == 1 { 1000 } else { 320 };
    if sequence != slot.sequence
        || value(12) != slot.frame
        || value(16) != size
        || value(20) != if slot.kind == 1 { 30_000 } else { 600 }
        || bytes.len() != 24 + size as usize
    {
        return Err(InvalidRecord);
    }
    if bytes[24..]
        .iter()
        .enumerate()
        .any(|(i, b)| *b != (slot.kind as u32 * 17 + slot.ordinal * 31 + i as u32) as u8)
    {
        return Err(InvalidRecord);
    }
    Ok(slot)
}
pub(super) fn control(shape: RateShape, kind: u8, id: u32, active: bool) -> Vec<u8> {
    let mut bytes = vec![0; 32];
    bytes[..4].copy_from_slice(b"GQS1");
    bytes[4..8].copy_from_slice(&[1, kind, shape as u8, u8::from(active)]);
    bytes[8..12].copy_from_slice(&id.to_be_bytes());
    if kind == 1 {
        for (chunk, n) in bytes[12..]
            .chunks_exact_mut(4)
            .zip([12000u32, 30000, 600, 500, 200])
        {
            chunk.copy_from_slice(&n.to_be_bytes());
        }
    }
    bytes
}
pub(super) fn parse_control(
    shape: RateShape,
    bytes: &[u8],
) -> Result<(u8, u32, bool), InvalidRecord> {
    if bytes.len() != 32 || &bytes[..4] != b"GQS1" || bytes[4] != 1 || bytes[6] != shape as u8 {
        return Err(InvalidRecord);
    }
    let kind = bytes[5];
    let id = u32::from_be_bytes(bytes[8..12].try_into().unwrap());
    if !(1..=6).contains(&kind)
        || bytes[7] > u8::from(kind == 5)
        || (if kind == 4 || kind == 5 {
            id >= 500
        } else {
            id != 0
        })
    {
        return Err(InvalidRecord);
    }
    let want = if kind == 1 {
        [12000u32, 30000, 600, 500, 200]
    } else {
        [0; 5]
    };
    if bytes[12..]
        .chunks_exact(4)
        .zip(want)
        .any(|(chunk, w)| u32::from_be_bytes(chunk.try_into().unwrap()) != w)
    {
        return Err(InvalidRecord);
    }
    Ok((kind, id, bytes[7] != 0))
}
fn chunk_size(kind: u8, index: usize) -> Option<(usize, usize)> {
    match (kind, index) {
        (7, 0) => Some((1, 384)),
        (8, 0..=2) => Some((4, 1000)),
        (8, 3) => Some((4, 825)),
        (9, 0..=14) => Some((15, 320)),
        _ => None,
    }
}
pub(super) fn chunk(shape: RateShape, kind: u8, index: usize, body: &[u8]) -> Vec<u8> {
    let (count, size) = chunk_size(kind, index).expect("fixed local chunk");
    assert_eq!(body.len(), size);
    let mut out = Vec::with_capacity(16 + size);
    out.extend_from_slice(b"GQS1");
    out.extend_from_slice(&[1, kind, shape as u8, 0]);
    out.extend_from_slice(&(index as u16).to_be_bytes());
    out.extend_from_slice(&(count as u16).to_be_bytes());
    out.extend_from_slice(&(size as u32).to_be_bytes());
    out.extend_from_slice(body);
    out
}
pub(super) fn parse_chunk(
    shape: RateShape,
    bytes: &[u8],
) -> Result<(u8, usize, &[u8]), InvalidRecord> {
    if bytes.len() < 16
        || &bytes[..4] != b"GQS1"
        || bytes[4] != 1
        || bytes[6] != shape as u8
        || bytes[7] != 0
    {
        return Err(InvalidRecord);
    }
    let index = u16::from_be_bytes(bytes[8..10].try_into().unwrap()) as usize;
    let (count, size) = chunk_size(bytes[5], index).ok_or(InvalidRecord)?;
    if u16::from_be_bytes(bytes[10..12].try_into().unwrap()) as usize != count
        || u32::from_be_bytes(bytes[12..16].try_into().unwrap()) as usize != size
        || bytes.len() != 16 + size
    {
        return Err(InvalidRecord);
    }
    Ok((bytes[5], index, &bytes[16..]))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn terminal_chunks_have_independent_bounded_layout() {
        let mut literal = vec![71, 81, 83, 49, 1, 8, 0, 0, 0, 3, 0, 4, 0, 0, 3, 57];
        literal.extend_from_slice(&[0x55; 825]);
        assert_eq!(chunk(RateShape::Constant, 8, 3, &[0x55; 825]), literal);
        assert_eq!(
            parse_chunk(RateShape::Constant, &literal),
            Ok((8, 3, &literal[16..]))
        );
        for n in 0..literal.len() {
            assert!(parse_chunk(RateShape::Constant, &literal[..n]).is_err());
        }
        for i in [4, 6, 7, 8, 10, 12, 15] {
            let mut bad = literal.clone();
            bad[i] ^= 1;
            assert!(parse_chunk(RateShape::Constant, &bad).is_err());
        }
        for (kind, index, size) in [(7, 0, 384), (9, 14, 320), (8, 0, 1000)] {
            let mut bytes = vec![
                71,
                81,
                83,
                49,
                1,
                kind,
                1,
                0,
                0,
                index,
                0,
                if kind == 7 {
                    1
                } else if kind == 8 {
                    4
                } else {
                    15
                },
            ];
            bytes.extend_from_slice(&(size as u32).to_be_bytes());
            bytes.resize(16 + size, 0);
            assert_eq!(
                chunk(RateShape::FrameBurst, kind, index as usize, &vec![0; size]),
                bytes
            );
            assert!(parse_chunk(RateShape::FrameBurst, &bytes).is_ok());
            bytes.push(0);
            assert!(parse_chunk(RateShape::FrameBurst, &bytes).is_err());
        }
    }
    #[test]
    fn literal_data_and_control_wire_with_hostile_lengths() {
        let s = Slot {
            sequence: 0,
            kind: 1,
            ordinal: 0,
            frame: u32::MAX,
            due_ns: 0,
        };
        let mut literal = vec![
            0x47, 0x51, 0x52, 0x31, 1, 1, 0, 0, 0, 0, 0, 0, 255, 255, 255, 255, 0, 0, 3, 232, 0, 0,
            117, 48,
        ];
        literal.extend((0..1000).map(|i| ((17 + i) % 256) as u8));
        assert_eq!(data(RateShape::Constant, s), literal);
        assert_eq!(parse_data(RateShape::Constant, 0, &literal), Ok(s));
        for n in 0..literal.len() {
            assert!(parse_data(RateShape::Constant, 0, &literal[..n]).is_err());
        }
        for index in [0, 4, 5, 6, 7, 11, 15, 19, 23, 100] {
            let mut bad = literal.clone();
            bad[index] ^= 1;
            assert!(
                parse_data(RateShape::Constant, 0, &bad).is_err(),
                "byte {index}"
            );
        }
        assert!(parse_data(RateShape::Constant, 1, &literal).is_err());
        literal.push(0);
        assert!(parse_data(RateShape::Constant, 0, &literal).is_err());
        let recipe = [
            0x47, 0x51, 0x53, 0x31, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 46, 224, 0, 0, 117, 48, 0, 0, 2,
            88, 0, 0, 1, 244, 0, 0, 0, 200,
        ];
        assert_eq!(control(RateShape::FrameBurst, 1, 0, false), recipe);
        assert_eq!(
            parse_control(RateShape::FrameBurst, &recipe),
            Ok((1, 0, false))
        );
        let echo = [
            0x47, 0x51, 0x53, 0x31, 1, 5, 0, 1, 0, 0, 1, 243, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
        ];
        assert_eq!(control(RateShape::Constant, 5, 499, true), echo);
        assert_eq!(
            parse_control(RateShape::Constant, &echo),
            Ok((5, 499, true))
        );
        for n in 0..32 {
            assert!(parse_control(RateShape::Constant, &echo[..n]).is_err());
        }
        for index in [0, 4, 6, 7, 8, 12, 31] {
            let mut bad = echo;
            bad[index] ^= 2;
            assert!(
                parse_control(RateShape::Constant, &bad).is_err(),
                "byte {index}"
            );
        }
    }
}
