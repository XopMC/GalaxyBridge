use crate::{InvalidRecord, Lane, Message, Received, SessionId};
pub const MAX_PAYLOAD: usize = 1024;
pub const HEADER: usize = 47;
pub const MAX_RECORD: usize = HEADER + MAX_PAYLOAD;

pub fn encode(session: &SessionId, message: &Message) -> Result<Vec<u8>, InvalidRecord> {
    if message.payload.len() > MAX_PAYLOAD {
        return Err(InvalidRecord);
    }
    let mut out = Vec::with_capacity(HEADER + message.payload.len());
    out.extend_from_slice(b"GQ01");
    out.extend_from_slice(session);
    out.push(match message.lane {
        Lane::Datagram => 0,
        Lane::Reliable => 1,
    });
    out.extend_from_slice(&message.sequence.to_be_bytes());
    out.extend_from_slice(&(message.payload.len() as u16).to_be_bytes());
    out.extend_from_slice(&message.payload);
    Ok(out)
}

pub fn decode(bytes: &[u8], session: &SessionId, lane: Lane) -> Result<Received, InvalidRecord> {
    if bytes.len() < HEADER
        || bytes.len() > MAX_RECORD
        || &bytes[..4] != b"GQ01"
        || &bytes[4..36] != session
        || bytes[36]
            != match lane {
                Lane::Datagram => 0,
                Lane::Reliable => 1,
            }
    {
        return Err(InvalidRecord);
    }
    let length = u16::from_be_bytes([bytes[45], bytes[46]]) as usize;
    if length > MAX_PAYLOAD || bytes.len() != HEADER + length {
        return Err(InvalidRecord);
    }
    Ok(Received {
        lane,
        sequence: u64::from_be_bytes(bytes[37..45].try_into().map_err(|_| InvalidRecord)?),
        payload: bytes[HEADER..].to_vec(),
    })
}

pub fn encode_reliable(session: &SessionId, message: &Message) -> Result<Vec<u8>, InvalidRecord> {
    if message.lane != Lane::Reliable {
        return Err(InvalidRecord);
    }
    let body = encode(session, message)?;
    let mut out = Vec::with_capacity(4 + body.len());
    out.extend_from_slice(&(body.len() as u32).to_be_bytes());
    out.extend_from_slice(&body);
    Ok(out)
}

pub fn decode_reliable(bytes: &[u8], session: &SessionId) -> Result<Received, InvalidRecord> {
    if bytes.len() < 4 {
        return Err(InvalidRecord);
    }
    let size = u32::from_be_bytes(bytes[..4].try_into().map_err(|_| InvalidRecord)?) as usize;
    if !(HEADER..=MAX_RECORD).contains(&size) || bytes.len() != size + 4 {
        return Err(InvalidRecord);
    }
    decode(&bytes[4..], session, Lane::Reliable)
}
