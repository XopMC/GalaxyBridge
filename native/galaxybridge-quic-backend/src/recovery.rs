//! Per-attempt publication mapping. Android BOOTTIME is never Rust Instant.
use crate::{bulk::Record, Error};
use galaxybridge_quic_media::StockPublication;
/// Fixed numeric-only record. Eleven maximal decimal u64 fields fit 237 bytes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct TraceLine(pub [u64; 11]);
/// One origin-owned media-endpoint sample. Direction/role: 1 host-media,
/// 2 peer-media. Each maximal-u64 line is 490 bytes, below the 1024 byte cap.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct SendStageLine(pub [u64; 23]);
impl SendStageLine {
    pub fn encode(self) -> Vec<u8> {
        let mut out = String::with_capacity(490);
        out.push_str("GBQD1");
        for v in self.0 {
            use std::fmt::Write;
            write!(&mut out, " {v}").unwrap();
        }
        out.push('\n');
        assert!(out.len() <= 490);
        out.into_bytes()
    }
    fn decode(bytes: &[u8], generation: u64, last: u64) -> Option<Self> {
        let text = std::str::from_utf8(bytes.strip_prefix(b"GBQD1 ")?).ok()?;
        let mut words = text.split(' ');
        let mut v = [0; 23];
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
            || v[2] > 16
            || !matches!(v[4], 1..=4)
            || v[16] > 7
        {
            return None;
        }
        Some(Self(v))
    }
}
pub(crate) struct Encoded {
    bytes: [u8; 256],
    len: usize,
}
impl Encoded {
    pub fn as_slice(&self) -> &[u8] {
        &self.bytes[..self.len]
    }
}
impl std::fmt::Write for Encoded {
    fn write_str(&mut self, s: &str) -> std::fmt::Result {
        if s.len() > 256 - self.len {
            return Err(std::fmt::Error);
        }
        self.bytes[self.len..self.len + s.len()].copy_from_slice(s.as_bytes());
        self.len += s.len();
        Ok(())
    }
}
impl TraceLine {
    pub fn encode(self) -> Encoded {
        use std::fmt::Write;
        let mut out = Encoded {
            bytes: [0; 256],
            len: 0,
        };
        out.write_str("GBQR1").unwrap();
        for value in self.0 {
            write!(&mut out, " {value}").unwrap();
        }
        out.write_str("\n").unwrap();
        out
    }
    fn decode(bytes: &[u8], generation: u64, last: u64) -> Option<Self> {
        if bytes.len() > 255 || !bytes.starts_with(b"GBQR1 ") {
            return None;
        }
        let text = std::str::from_utf8(&bytes[6..]).ok()?;
        let mut words = text.split(' ');
        let mut out = [0; 11];
        for n in &mut out {
            let word = words.next()?;
            if word.is_empty() || !word.bytes().all(|v| v.is_ascii_digit()) {
                return None;
            }
            *n = word.parse().ok()?;
        }
        if words.next().is_some()
            || out[0] != generation
            || generation == 0
            || out[1] != 2
            || out[2] <= last
            || !matches!(out[3],0..=13|20..=25|30)
            || out[3] != 30 && out[4] > 2
            || out[5] > u32::MAX as u64
            || out[6] > u32::MAX as u64
        {
            return None;
        }
        // The peer's scalar-only input breadcrumb shares this bounded pipe.
        // Accept only authenticated control receive (2) and completed local
        // scrcpy-socket write (3); host-only stages and widened payloads stay
        // outside the exact-child diagnostic grammar.
        if out[3] == 30
            && (!matches!(out[4], 2 | 3)
                || out[5..=8].iter().any(|value| *value != 0)
                || out[9] == 0
                || out[10] == 0)
        {
            return None;
        }
        if out[3] == 13
            && (out[4] != 1
                || out[5..=8].contains(&0)
                || !matches!(
                    (out[9], out[10]),
                    (0, 120_000) | (1, 250_000) | (1, 500_000)
                ))
        {
            return None;
        }
        Some(Self(out))
    }
}
pub(crate) struct TraceParser {
    bytes: [u8; 1024],
    used: usize,
    discard: bool,
    last: u64,
    pub rejected: u64,
    pub accepted: u64,
    reported: (u64, u64),
    stage_last: u64,
    stage_final: bool,
    stages: std::collections::VecDeque<SendStageLine>,
    progress_last: u64,
    progress: [Option<crate::progress::Line>; 6],
}
impl Default for TraceParser {
    fn default() -> Self {
        Self {
            bytes: [0; 1024],
            used: 0,
            discard: false,
            last: 0,
            rejected: 0,
            accepted: 0,
            reported: (0, 0),
            stage_last: 0,
            stage_final: false,
            stages: std::collections::VecDeque::new(),
            progress_last: 0,
            progress: [None; 6],
        }
    }
}
impl TraceParser {
    pub fn take_progress(&mut self) -> Option<crate::progress::Line> {
        let i = self.progress.iter().position(Option::is_some)?;
        self.progress[i].take()
    }
    pub fn take_stage(&mut self) -> Option<SendStageLine> {
        self.stages.pop_front()
    }
    pub fn byte(&mut self, b: u8, generation: u64) -> Option<TraceLine> {
        if b != b'\n' {
            if self.used < 1023 && !self.discard {
                self.bytes[self.used] = b;
                self.used += 1;
            } else {
                self.discard = true;
            }
            return None;
        }
        if self.bytes[..self.used].starts_with(b"GBQD1 ") {
            let result = if self.discard || self.stage_final {
                None
            } else {
                SendStageLine::decode(&self.bytes[..self.used], generation, self.stage_last)
            };
            if let Some(line) = result {
                self.stage_last = line.0[2];
                self.stage_final = line.0[4] == 4;
                self.stages.push_back(line);
            } else {
                self.rejected = self.rejected.saturating_add(1);
            }
            self.used = 0;
            self.discard = false;
            return None;
        }
        if self.bytes[..self.used].starts_with(b"GBQP2 ") {
            let line = (!self.discard)
                .then(|| {
                    crate::progress::Line::decode(
                        &self.bytes[..self.used],
                        generation,
                        self.progress_last,
                    )
                })
                .flatten();
            if let Some(line) = line {
                self.progress_last = line.0[2];
                self.progress[line.0[3] as usize] = Some(line);
            } else {
                self.rejected = self.rejected.saturating_add(1);
            }
            self.used = 0;
            self.discard = false;
            return None;
        }
        let result = if self.discard || self.accepted >= 512 {
            None
        } else {
            TraceLine::decode(&self.bytes[..self.used], generation, self.last)
        };
        if let Some(r) = result {
            self.last = r.0[2];
            self.accepted += 1;
        } else {
            self.rejected = self.rejected.saturating_add(1);
        }
        self.used = 0;
        self.discard = false;
        result
    }
    pub fn finish(&mut self) {
        if self.used != 0 || self.discard {
            self.rejected = self.rejected.saturating_add(1);
            self.used = 0;
            self.discard = false;
        }
    }
    pub fn changed_rejections(&mut self) -> Option<(u64, u64)> {
        let counts = (self.accepted, self.rejected);
        if self.rejected == 0 || self.reported == counts {
            return None;
        }
        self.reported = counts;
        Some(counts)
    }
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Request {
    pub bytes: [u8; 33],
    pub deadline: u64,
    pub id: u64,
    pub(crate) identity: (u32, u32, u64),
    admitted: u64,
    rate_window_reserved: bool,
}
const RECOVERY_WINDOW_NS: u64 = 100_000_000;
const RATE_THEN_RECOVERY_WINDOW_NS: u64 = 250_000_000;
const SYNC_PUBLICATION_WINDOW_NS: u64 = 500_000_000;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecoveryAdmission {
    Queued,
    Coalesced,
    IgnoredSupersededRequest,
}
#[derive(Default)]
pub struct ProducerMap {
    epoch: u64,
    ordinal: u64,
    g1_epoch: u32,
    g1_config: u32,
    high: u64,
    // CaptureControl has one lifetime-wide high-water mark. Receiver request
    // IDs and sender-local loss IDs are separate namespaces, not codec IDs.
    producer_high: u64,
    pending: Option<Request>,
    awaiting_sync_frame: bool,
    awaiting_sync_deadline: u64,
}
impl ProducerMap {
    pub(crate) fn identity(&self) -> Option<(u64, u64)> {
        if self.epoch > 0 && self.ordinal > 0 {
            Some((self.epoch, self.ordinal))
        } else {
            None
        }
    }
    pub(crate) fn pending_observation(&self) -> Option<(u64, u64, u32, u32, u64)> {
        self.pending
            .as_ref()
            .map(|r| (r.id, r.deadline, r.identity.0, r.identity.1, r.identity.2))
    }
    pub(crate) fn is_current(&self, request: &Request) -> bool {
        self.epoch != 0
            && self.ordinal != 0
            && request.bytes[1..9] == self.epoch.to_be_bytes()
            && request.bytes[9..17] == self.ordinal.to_be_bytes()
    }
    pub fn pending(&self) -> bool {
        self.pending.is_some()
    }
    pub(crate) fn active(&self) -> bool {
        self.pending.is_some() || self.awaiting_sync_frame
    }
    /// Returns true only for the first independently decodable frame published
    /// after the current sync request reached the owned producer boundary.
    pub fn publication(&mut self, p: StockPublication) -> Result<bool, Error> {
        if p.track != 1 {
            return Ok(false);
        }
        let mut recovery = false;
        match p.kind {
            3 => {
                self.epoch = self.epoch.checked_add(1).ok_or(Error::Capacity)?;
                self.ordinal = 0;
                self.g1_epoch = p.epoch;
                self.g1_config = 0;
                self.pending = None;
                self.awaiting_sync_frame = false;
                self.awaiting_sync_deadline = 0;
            }
            4 => {
                self.ordinal = self.ordinal.checked_add(1).ok_or(Error::Capacity)?;
                self.g1_config = p.config;
                self.pending = None;
                self.awaiting_sync_frame = false;
                self.awaiting_sync_deadline = 0;
            }
            5 if p.independent && self.awaiting_sync_frame => {
                self.awaiting_sync_frame = false;
                self.awaiting_sync_deadline = 0;
                recovery = true;
            }
            _ => {}
        }
        Ok(recovery)
    }
    pub fn admit(&mut self, r: &Record, boottime: u64) -> Result<RecoveryAdmission, Error> {
        r.encode(crate::Role::Media, crate::Side::Host)?;
        if r.id <= self.high {
            return Err(Error::Protocol);
        }
        if r.id > i64::MAX as u64 {
            return Err(Error::Clock);
        }
        let epoch = crate::bulk::u32_at(&r.body, 0);
        let config = crate::bulk::u32_at(&r.body, 4);
        if self.epoch != 0
            && self.ordinal != 0
            && epoch != 0
            && config != 0
            && (epoch < self.g1_epoch || epoch == self.g1_epoch && config < self.g1_config)
        {
            self.high = r.id;
            return Ok(RecoveryAdmission::IgnoredSupersededRequest);
        }
        let result = self.queue(
            epoch,
            config,
            crate::bulk::u64_at(&r.body, 8),
            r.id,
            boottime,
        )?;
        self.high = r.id;
        Ok(result)
    }
    /// Sender-local recovery avoids waiting for the receiver round trip after
    /// this process proves that an accepted video fragment expired before UDP.
    pub(crate) fn request_local(
        &mut self,
        epoch: u32,
        config: u32,
        sequence: u64,
        id: u64,
        boottime: u64,
    ) -> Result<RecoveryAdmission, Error> {
        self.queue(epoch, config, sequence, id, boottime)
    }
    fn queue(
        &mut self,
        epoch: u32,
        config: u32,
        sequence: u64,
        id: u64,
        boottime: u64,
    ) -> Result<RecoveryAdmission, Error> {
        if self.epoch == 0
            || self.ordinal == 0
            || self.g1_epoch != epoch
            || self.g1_config != config
        {
            return Err(Error::Retired);
        }
        let cutoff = boottime
            .checked_add(RECOVERY_WINDOW_NS)
            .ok_or(Error::Clock)?;
        if boottime == 0
            || cutoff > i64::MAX as u64
            || self.epoch > i64::MAX as u64
            || self.ordinal > i64::MAX as u64
            || id == 0
            || id > i64::MAX as u64
            || sequence == 0
        {
            return Err(Error::Clock);
        }
        if self
            .pending
            .as_ref()
            .is_some_and(|pending| boottime >= pending.deadline)
        {
            self.pending = None;
        }
        if self.awaiting_sync_frame && boottime >= self.awaiting_sync_deadline {
            self.awaiting_sync_frame = false;
            self.awaiting_sync_deadline = 0;
        }
        if self.active() {
            return Ok(RecoveryAdmission::Coalesced);
        }
        let producer_id = self.producer_high.checked_add(1).ok_or(Error::Clock)?;
        if producer_id > i64::MAX as u64 {
            return Err(Error::Clock);
        }
        let mut bytes = [0; 33];
        bytes[0] = 23;
        for (index, value) in [self.epoch, self.ordinal, producer_id, cutoff]
            .into_iter()
            .enumerate()
        {
            bytes[1 + 8 * index..9 + 8 * index].copy_from_slice(&value.to_be_bytes());
        }
        self.pending = Some(Request {
            bytes,
            deadline: cutoff,
            id,
            identity: (epoch, config, sequence),
            admitted: boottime,
            rate_window_reserved: false,
        });
        self.producer_high = producer_id;
        Ok(RecoveryAdmission::Queued)
    }
    /// A receiver-loss recovery may first lower the producer bitrate so that
    /// the replacement IDR fits the congested path. That preceding command is
    /// part of one bounded operation, not a reason to renew recovery forever.
    pub(crate) fn reserve_preceding_rate_window(&mut self) -> Result<(), Error> {
        let request = self.pending.as_mut().ok_or(Error::Protocol)?;
        if request.rate_window_reserved {
            return Ok(());
        }
        let combined = request
            .admitted
            .checked_add(RATE_THEN_RECOVERY_WINDOW_NS)
            .ok_or(Error::Clock)?;
        if combined > i64::MAX as u64 {
            return Err(Error::Clock);
        }
        request.deadline = combined;
        request.bytes[25..33].copy_from_slice(&combined.to_be_bytes());
        request.rate_window_reserved = true;
        Ok(())
    }
    pub fn take(&mut self, now: u64) -> Option<Request> {
        if self.pending.as_ref().is_some_and(|p| now >= p.deadline) {
            self.pending = None;
        }
        let mut request = self.pending.take()?;
        // The combined operation can wait for its preceding rate write, but
        // Java only accepts a sync command with <=100 ms remaining. Finalize
        // once before any bytes are written, without extending the original
        // operation deadline or renewing a partially written command.
        request.deadline = request.deadline.min(now.checked_add(RECOVERY_WINDOW_NS)?);
        request.bytes[25..33].copy_from_slice(&request.deadline.to_be_bytes());
        Some(request)
    }
    pub(crate) fn sync_submitted(&mut self, request: &Request, now: u64) -> Result<(), Error> {
        if !self.is_current(request) {
            return Err(Error::Retired);
        }
        let deadline = now
            .checked_add(SYNC_PUBLICATION_WINDOW_NS)
            .ok_or(Error::Clock)?;
        if now == 0 || deadline > i64::MAX as u64 {
            return Err(Error::Clock);
        }
        self.awaiting_sync_frame = true;
        self.awaiting_sync_deadline = deadline;
        Ok(())
    }
    pub fn clear(&mut self) {
        self.pending = None;
        self.awaiting_sync_frame = false;
        self.awaiting_sync_deadline = 0;
        self.epoch = 0;
        self.ordinal = 0;
        self.g1_epoch = 0;
        self.g1_config = 0;
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn send_stage_observation_accepts_bounded_numeric_peer_record() {
        let line = b"GBQD1 9 2 1 100 1 10 8 8 2 0 0 0 0 3 0 0 3 90 30 2 24000 0 0\n";
        let mut parser = TraceParser::default();
        for &b in line {
            parser.byte(b, 9);
        }
        parser.finish();
        assert_eq!(
            parser.rejected, 0,
            "valid opted-in peer send-stage record must survive existing exact-child parsing"
        );
        let record = parser.take_stage().unwrap();
        assert_eq!(
            record.0,
            [9, 2, 1, 100, 1, 10, 8, 8, 2, 0, 0, 0, 0, 3, 0, 0, 3, 90, 30, 2, 24000, 0, 0]
        );
        assert!(parser.take_stage().is_none());
        assert_eq!(
            (parser.accepted, parser.last),
            (0, 0),
            "independent quota must not consume legacy trace slots"
        );
    }
    #[test]
    fn progress_fragmented_bounded_parser_survives_legacy_trace_budget() {
        let mut p = TraceParser::default();
        p.accepted = 512;
        let mut line = crate::progress::Line::without_pressure([
            9,
            2,
            1,
            3,
            1,
            200_000_001,
            1,
            11,
            10,
            10,
            10,
            0,
            0,
        ]);
        for serial in 1..=crate::progress::LIMIT {
            line.0[2] = serial;
            for b in line.encode() {
                assert!(p.byte(b, 9).is_none());
            }
        }
        assert_eq!(p.rejected, 0);
        assert_eq!(p.take_progress(), Some(line));
        assert!(p.take_progress().is_none());
        for bad in [
            line.encode(),
            b"GBQP2 9 2 4097 3 1 200000001 1 11 10 10 10 0 0 0 0\n".to_vec(),
            b"GBQP2 content\n".to_vec(),
            [vec![b'9'; 1100], vec![b'\n']].concat(),
        ] {
            for b in bad {
                p.byte(b, 9);
            }
        }
        assert_eq!(p.rejected, 4);
        assert!(p.take_progress().is_none());
        for b in b"GBQP2 9 2" {
            p.byte(*b, 9);
        }
        p.finish();
        assert_eq!(p.rejected, 5);
    }
    #[test]
    fn send_stage_observation_identity_cap_terminal_and_format_bounds() {
        assert!(SendStageLine([u64::MAX; 23]).encode().len() <= 490);
        assert!(16 * 490 <= 16 * 1024 && 32 * 490 <= 32 * 1024);
        let mut base = [0; 23];
        base[0] = 9;
        base[1] = 2;
        base[2] = 1;
        base[4] = 1;
        for (field, value) in [(0, 10), (1, 1), (2, 0), (2, 17), (4, 0), (4, 5), (16, 8)] {
            let mut bad = base;
            bad[field] = value;
            let mut p = TraceParser::default();
            for b in SendStageLine(bad).encode() {
                p.byte(b, 9);
            }
            assert!(p.take_stage().is_none());
            assert_eq!(p.rejected, 1);
        }
        let mut p = TraceParser::default();
        for id in 1..=17 {
            let mut r = base;
            r[2] = id;
            for b in SendStageLine(r).encode() {
                p.byte(b, 9);
            }
        }
        assert_eq!(p.stages.len(), 16);
        assert_eq!(p.rejected, 1);
        for b in SendStageLine(base).encode() {
            p.byte(b, 9);
        }
        assert_eq!(p.rejected, 2);
        let mut p = TraceParser::default();
        let mut r = base;
        r[4] = 4;
        for b in SendStageLine(r).encode() {
            p.byte(b, 9);
        }
        r[2] = 2;
        r[4] = 1;
        for b in SendStageLine(r).encode() {
            p.byte(b, 9);
        }
        assert_eq!(p.stages.len(), 1);
        assert_eq!(p.rejected, 1);
        for _ in 0..1025 {
            p.byte(b'9', 9);
        }
        p.byte(b'\n', 9);
        assert_eq!(p.rejected, 2);
        for b in b"GBQD1 9 2 3" {
            p.byte(*b, 9);
        }
        p.finish();
        assert_eq!(p.rejected, 3);
    }
    #[test]
    fn recovery_observation_source_class_strict_parser() {
        for (key, budget) in [(0, 120_000), (1, 250_000), (1, 500_000)] {
            let line = TraceLine([9, 2, 1, 13, 1, 1, 1, 17, 3, key, budget]);
            let mut parser = TraceParser::default();
            let mut out = None;
            for &b in line.encode().as_slice() {
                out = parser.byte(b, 9);
            }
            assert_eq!(
                out,
                Some(line),
                "valid selected source class must cross exact-child parser"
            );
        }
        for (key, budget) in [
            (0, 250_000),
            (1, 120_000),
            (2, 250_000),
            (1, 200_000),
            (1, u64::MAX),
        ] {
            let line = TraceLine([9, 2, 1, 13, 1, 1, 1, 17, 3, key, budget]);
            let mut parser = TraceParser::default();
            for &b in line.encode().as_slice() {
                assert_eq!(parser.byte(b, 9), None);
            }
            assert_eq!(parser.rejected, 1);
        }
        for field in 4..=8 {
            let mut line = TraceLine([9, 2, 1, 13, 1, 1, 1, 17, 3, 1, 250_000]);
            line.0[field] = 0;
            let mut parser = TraceParser::default();
            for &b in line.encode().as_slice() {
                assert_eq!(parser.byte(b, 9), None);
            }
            assert_eq!(
                parser.rejected, 1,
                "source class requires video and positive immutable identity"
            );
        }
    }
    #[test]
    fn recovery_observation_accepts_only_peer_control_receive_and_stock_write_stages() {
        for stage in [2, 3] {
            let line = TraceLine([9, 2, stage - 1, 30, stage, 0, 0, 0, 0, 41, 1_000]);
            let mut parser = TraceParser::default();
            let mut out = None;
            for &byte in line.encode().as_slice() {
                out = parser.byte(byte, 9).or(out);
            }
            assert_eq!(out, Some(line));
        }
        for line in [
            TraceLine([9, 2, 3, 30, 1, 0, 0, 0, 0, 41, 1_000]),
            TraceLine([9, 2, 4, 30, 4, 0, 0, 0, 0, 41, 1_000]),
            TraceLine([9, 2, 5, 30, 2, 1, 0, 0, 0, 41, 1_000]),
            TraceLine([9, 2, 6, 30, 2, 0, 0, 0, 0, 0, 1_000]),
        ] {
            let mut parser = TraceParser::default();
            for &byte in line.encode().as_slice() {
                assert_eq!(parser.byte(byte, 9), None);
            }
            assert_eq!(parser.rejected, 1);
        }
    }
    #[test]
    fn recovery_observation_strict_scalar_partial_and_identity_parser() {
        let line = TraceLine([9, 2, 1, 7, 1, 1, 1, 8, 3, 1, 100]);
        let encoded = line.encode();
        assert!(encoded.as_slice().len() <= 256);
        assert!(TraceLine([u64::MAX; 11]).encode().as_slice().len() <= 256);
        let mut parser = TraceParser::default();
        for &b in &encoded.as_slice()[..encoded.as_slice().len() - 1] {
            assert_eq!(parser.byte(b, 9), None);
        }
        assert_eq!(parser.byte(b'\n', 9), Some(line));
        for bad in [
            b"private arbitrary stderr\n".as_slice(),
            b"GBQR1 9 2 2 7 1 1 1 8 3 1 -1\n",
            b"GBQR1 9 2 2 7 1 1 1 8 3 1 2 extra\n",
        ] {
            for &b in bad {
                assert_eq!(parser.byte(b, 9), None);
            }
        }
        for &b in encoded.as_slice() {
            assert_eq!(parser.byte(b, 9), None, "duplicate must not replay");
        }
        for &b in TraceLine([10, 2, 2, 7, 1, 1, 1, 8, 3, 1, 100])
            .encode()
            .as_slice()
        {
            assert_eq!(parser.byte(b, 9), None, "other child generation");
        }
        for &b in TraceLine([9, 1, 2, 7, 1, 1, 1, 8, 3, 1, 100])
            .encode()
            .as_slice()
        {
            assert_eq!(parser.byte(b, 9), None, "host line is not peer provenance");
        }
        for _ in 0..300 {
            assert_eq!(parser.byte(b'9', 9), None);
        }
        assert_eq!(parser.byte(b'\n', 9), None);
        let final_line = TraceLine([9, 2, 3, 9, 1, 1, 1, 8, 3, 1, 100]);
        let mut out = None;
        for &b in final_line.encode().as_slice() {
            out = parser.byte(b, 9);
        }
        assert_eq!(out, Some(final_line));
        assert_eq!(parser.rejected, 7);
        parser.byte(b'G', 9);
        parser.finish();
        parser.finish();
        assert_eq!(parser.rejected, 8);
        let mut bounded = TraceParser::default();
        for ordinal in 1..=513 {
            let line = TraceLine([9, 2, ordinal, 9, 1, 1, 1, 8, 3, 1, 100]);
            let mut result = None;
            for &b in line.encode().as_slice() {
                result = bounded.byte(b, 9);
            }
            assert_eq!(result, if ordinal <= 512 { Some(line) } else { None });
        }
        assert_eq!((bounded.accepted, bounded.rejected), (512, 1));
        assert_eq!(bounded.changed_rejections(), Some((512, 1)));
        assert_eq!(bounded.changed_rejections(), None);
    }
    #[test]
    fn media_policy_pending_expiry_coalescing_and_superseded_identity() {
        let mut map = ProducerMap::default();
        let mut p = StockPublication {
            kind: 3,
            track: 1,
            epoch: 1,
            config: 0,
            sequence: 1,
            started: 0,
            independent: false,
        };
        map.publication(p).unwrap();
        p.kind = 4;
        p.config = 1;
        map.publication(p).unwrap();
        let mut body = 1u32.to_be_bytes().to_vec();
        body.extend(1u32.to_be_bytes());
        body.extend(1u64.to_be_bytes());
        let mut r = Record {
            kind: 4,
            purpose: 3,
            generation: 1,
            id: 1,
            barrier: 0,
            total: 16,
            offset: 0,
            age_us: 0,
            body,
        };
        assert_eq!(map.admit(&r, 1), Ok(RecoveryAdmission::Queued));
        r.id = 2;
        assert_eq!(map.admit(&r, 100_000_000), Ok(RecoveryAdmission::Coalesced));
        let old = map.take(100_000_000).unwrap();
        assert_eq!((old.id, old.deadline), (1, 100_000_001));
        r.id = 3;
        map.admit(&r, 200_000_000).unwrap();
        r.id = 4;
        assert_eq!(map.admit(&r, 300_000_000), Ok(RecoveryAdmission::Queued));
        assert_eq!(map.take(300_000_001).unwrap().id, 4);
        p.config = 2;
        map.publication(p).unwrap();
        r.id = 5;
        assert_eq!(
            map.admit(&r, 400_000_000),
            Ok(RecoveryAdmission::IgnoredSupersededRequest)
        );
        assert!(!map.pending());
        assert_eq!(map.admit(&r, 400_000_001), Err(Error::Protocol));
        r.id = 6;
        r.body[4..8].copy_from_slice(&3u32.to_be_bytes());
        assert_eq!(map.admit(&r, 400_000_001), Err(Error::Retired));
        r.body[4..8].copy_from_slice(&1u32.to_be_bytes());
        r.id = u64::MAX;
        assert_eq!(map.admit(&r, 400_000_001), Err(Error::Clock));
        r.id = 6;
        r.body.pop();
        assert!(map.admit(&r, 400_000_001).is_err());
    }

    #[test]
    fn local_and_remote_recovery_ids_share_one_monotonic_producer_namespace() {
        let mut map = ProducerMap::default();
        let mut p = StockPublication {
            kind: 3,
            track: 1,
            epoch: 1,
            config: 0,
            sequence: 1,
            started: 0,
            independent: false,
        };
        map.publication(p).unwrap();
        p.kind = 4;
        p.config = 1;
        map.publication(p).unwrap();
        let mut last_producer_id = 0;
        for (index, local) in [true, false, true, false].into_iter().enumerate() {
            let origin_id = index as u64 / 2 + 1;
            let now = (index as u64 + 1) * 1_000_000_000;
            if local {
                map.request_local(1, 1, 7, origin_id, now).unwrap();
            } else {
                let mut body = 1u32.to_be_bytes().to_vec();
                body.extend(1u32.to_be_bytes());
                body.extend(7u64.to_be_bytes());
                map.admit(
                    &Record {
                        kind: 4,
                        purpose: 3,
                        generation: 1,
                        id: origin_id,
                        barrier: 0,
                        total: 16,
                        offset: 0,
                        age_us: 0,
                        body,
                    },
                    now,
                )
                .unwrap();
            }
            let request = map.take(now).unwrap();
            assert_eq!(request.id, origin_id, "keep origin correlation separate");
            let producer_id = u64::from_be_bytes(request.bytes[17..25].try_into().unwrap());
            assert!(
                producer_id > last_producer_id,
                "producer rejects reused local/remote command ID {producer_id}"
            );
            last_producer_id = producer_id;
            map.sync_submitted(&request, now).unwrap();
            p.kind = 5;
            p.independent = true;
            assert!(map.publication(p).unwrap());
        }
        // Publication/reset invalidates pending capture work, not the codec
        // controller's lifetime-wide command high-water mark.
        map.clear();
        p.kind = 3;
        p.epoch = 2;
        p.config = 0;
        map.publication(p).unwrap();
        p.kind = 4;
        p.config = 1;
        map.publication(p).unwrap();
        map.request_local(2, 1, 8, 1, 6_000_000_000).unwrap();
        let request = map.take(6_000_000_000).unwrap();
        assert!(u64::from_be_bytes(request.bytes[17..25].try_into().unwrap()) > last_producer_id);
    }
    #[test]
    fn rate_then_sync_serializes_the_producer_window_not_the_combined_budget() {
        // The Java CaptureControl command accepts at most 100 ms remaining.
        // Its enclosing rate+sync operation may wait up to 250 ms, but that
        // operation budget must never be serialized as the codec command TTL.
        let admitted = 1_000_000_000;
        for delay_ms in [0, 1, 99, 100, 149, 150, 249, 250] {
            let mut map = ProducerMap::default();
            let mut p = StockPublication {
                kind: 3,
                track: 1,
                epoch: 1,
                config: 0,
                sequence: 1,
                started: 0,
                independent: false,
            };
            map.publication(p).unwrap();
            p.kind = 4;
            p.config = 1;
            map.publication(p).unwrap();
            map.request_local(1, 1, 7, 1, admitted).unwrap();
            map.reserve_preceding_rate_window().unwrap();
            map.reserve_preceding_rate_window().unwrap();
            let selected = admitted + delay_ms * 1_000_000;
            let request = map.take(selected);
            if delay_ms == 250 {
                assert!(
                    request.is_none(),
                    "expired combined operation cannot be renewed"
                );
                continue;
            }
            let request = request.unwrap();
            let wire_deadline = u64::from_be_bytes(request.bytes[25..33].try_into().unwrap());
            assert_eq!(wire_deadline, request.deadline);
            assert!(wire_deadline > selected);
            assert!(
                wire_deadline - selected <= RECOVERY_WINDOW_NS,
                "producer rejects command selected after {delay_ms} ms: remaining {} ns",
                wire_deadline - selected
            );
            assert_eq!(
                wire_deadline,
                (selected + RECOVERY_WINDOW_NS).min(admitted + RATE_THEN_RECOVERY_WINDOW_NS)
            );
            assert!(!map.pending());
        }
    }
    #[test]
    fn rate_before_recovery_gets_one_bounded_combined_deadline() {
        let mut map = ProducerMap::default();
        let mut publication = StockPublication {
            kind: 3,
            track: 1,
            epoch: 1,
            config: 0,
            sequence: 1,
            started: 0,
            independent: false,
        };
        map.publication(publication).unwrap();
        publication.kind = 4;
        publication.config = 1;
        map.publication(publication).unwrap();

        let mut body = 1u32.to_be_bytes().to_vec();
        body.extend(1u32.to_be_bytes());
        body.extend(7u64.to_be_bytes());
        let record = Record {
            kind: 4,
            purpose: 3,
            generation: 1,
            id: 1,
            barrier: 0,
            total: 16,
            offset: 0,
            age_us: 0,
            body,
        };
        let admitted = 1_000_000_000;
        assert_eq!(map.admit(&record, admitted), Ok(RecoveryAdmission::Queued));
        map.reserve_preceding_rate_window().unwrap();

        assert!(
            map.take(admitted + 100_000_000).is_some(),
            "the recovery must remain selectable after its preceding rate write consumes the original window"
        );

        map.admit(&Record { id: 2, ..record }, admitted + 300_000_000)
            .unwrap();
        map.reserve_preceding_rate_window().unwrap();
        let (_, deadline, ..) = map.pending_observation().unwrap();
        assert_eq!(
            deadline,
            admitted + 550_000_000,
            "the combined rate-plus-recovery budget is fixed at 250 ms from admission"
        );
        map.reserve_preceding_rate_window().unwrap();
        assert_eq!(
            map.pending_observation().unwrap().1,
            deadline,
            "repeated calls must not renew the bounded deadline"
        );
        assert!(map.take(deadline).is_none());
    }
    #[test]
    fn issued_request_is_revoked_by_publication_and_clear() {
        let mut map = ProducerMap::default();
        let mut p = StockPublication {
            kind: 3,
            track: 1,
            epoch: 1,
            config: 0,
            sequence: 1,
            started: 0,
            independent: false,
        };
        map.publication(p).unwrap();
        p.kind = 4;
        p.config = 1;
        map.publication(p).unwrap();
        let mut body = 1u32.to_be_bytes().to_vec();
        body.extend(1u32.to_be_bytes());
        body.extend(1u64.to_be_bytes());
        let r = Record {
            kind: 4,
            purpose: 3,
            generation: 1,
            id: 1,
            barrier: 0,
            total: 16,
            offset: 0,
            age_us: 0,
            body,
        };
        map.admit(&r, 1).unwrap();
        let request = map.take(2).unwrap();
        assert!(map.is_current(&request));
        p.config = 2;
        map.publication(p).unwrap();
        assert!(!map.is_current(&request));
        map.clear();
        assert!(!map.is_current(&request));
    }

    #[test]
    fn sender_local_expiry_requests_one_sync_until_independent_publication() {
        let mut map = ProducerMap::default();
        let mut publication = StockPublication {
            kind: 3,
            track: 1,
            epoch: 7,
            config: 0,
            sequence: 0,
            started: 0,
            independent: false,
        };
        map.publication(publication).unwrap();
        publication.kind = 4;
        publication.config = 9;
        map.publication(publication).unwrap();

        assert_eq!(
            map.request_local(7, 9, 31, 1, 1),
            Ok(RecoveryAdmission::Queued)
        );
        assert!(map.active());
        assert_eq!(
            map.request_local(7, 9, 32, 2, 2),
            Ok(RecoveryAdmission::Coalesced)
        );
        let request = map.take(3).unwrap();
        assert_eq!(request.identity, (7, 9, 31));
        map.sync_submitted(&request, 3).unwrap();
        assert_eq!(
            map.request_local(7, 9, 33, 3, 4),
            Ok(RecoveryAdmission::Coalesced)
        );
        publication.kind = 5;
        publication.sequence = 34;
        publication.independent = false;
        assert!(!map.publication(publication).unwrap());
        assert!(map.active());
        publication.sequence = 35;
        publication.independent = true;
        assert!(map.publication(publication).unwrap());
        assert!(!map.active());
    }

    #[test]
    fn submitted_sync_request_marks_only_the_next_qualified_key_as_recovery() {
        let mut map = ProducerMap::default();
        let mut publication = StockPublication {
            kind: 3,
            track: 1,
            epoch: 1,
            config: 0,
            sequence: 0,
            started: 0,
            independent: false,
        };
        assert!(!map.publication(publication).unwrap());
        publication.kind = 4;
        publication.config = 1;
        assert!(!map.publication(publication).unwrap());
        let mut body = 1u32.to_be_bytes().to_vec();
        body.extend(1u32.to_be_bytes());
        body.extend(7u64.to_be_bytes());
        let request_record = Record {
            kind: 4,
            purpose: 3,
            generation: 1,
            id: 1,
            barrier: 0,
            total: 16,
            offset: 0,
            age_us: 0,
            body,
        };
        map.admit(&request_record, 1).unwrap();
        let request = map.take(2).unwrap();
        map.sync_submitted(&request, 3).unwrap();

        publication.kind = 5;
        publication.sequence = 8;
        publication.independent = false;
        assert!(!map.publication(publication).unwrap());
        publication.sequence = 9;
        publication.independent = true;
        assert!(map.publication(publication).unwrap());
        publication.sequence = 10;
        assert!(!map.publication(publication).unwrap());
    }

    #[test]
    fn missing_independent_frame_reopens_recovery_after_a_bounded_wait() {
        let mut map = ProducerMap::default();
        let mut publication = StockPublication {
            kind: 3,
            track: 1,
            epoch: 7,
            config: 0,
            sequence: 0,
            started: 0,
            independent: false,
        };
        map.publication(publication).unwrap();
        publication.kind = 4;
        publication.config = 9;
        map.publication(publication).unwrap();

        assert_eq!(
            map.request_local(7, 9, 31, 1, 1_000_000_000),
            Ok(RecoveryAdmission::Queued)
        );
        let request = map.take(1_000_000_001).unwrap();
        let submitted = 1_000_000_002;
        map.sync_submitted(&request, submitted).unwrap();
        assert_eq!(
            map.request_local(7, 9, 32, 2, submitted + 499_999_999),
            Ok(RecoveryAdmission::Coalesced),
            "a late duplicate must not create an IDR storm"
        );
        assert_eq!(
            map.request_local(7, 9, 33, 3, submitted + 500_000_000),
            Ok(RecoveryAdmission::Queued),
            "a lost replacement IDR must not fence recovery forever"
        );
        assert_eq!(
            map.take(submitted + 500_000_001).unwrap().identity,
            (7, 9, 33)
        );
    }
}
pub fn boottime_ns() -> Result<u64, Error> {
    #[cfg(target_os = "android")]
    {
        let mut ts = libc::timespec {
            tv_sec: 0,
            tv_nsec: 0,
        };
        if unsafe { libc::clock_gettime(libc::CLOCK_BOOTTIME, &mut ts) } != 0 {
            return Err(Error::Clock);
        }
        return checked_timespec(ts.tv_sec as i64, ts.tv_nsec as i64);
    }
    #[cfg(not(target_os = "android"))]
    {
        Err(Error::Unsupported)
    }
}
pub fn checked_timespec(seconds: i64, nanos: i64) -> Result<u64, Error> {
    if seconds < 0 || !(0..1_000_000_000).contains(&nanos) {
        return Err(Error::Clock);
    }
    let n = seconds
        .checked_mul(1_000_000_000)
        .and_then(|s| s.checked_add(nanos))
        .ok_or(Error::Clock)?;
    if n <= 0 {
        return Err(Error::Clock);
    }
    Ok(n as u64)
}
