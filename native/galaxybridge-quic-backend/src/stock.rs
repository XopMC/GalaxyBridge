//! Original stock framing and one nonblocking sink. No ADB media transport.
use crate::{
    bulk::{u32_at, Blob, BlobPool},
    Error,
};
use std::{
    io::{Read, Write},
    os::unix::net::UnixStream,
};
pub fn validate_bulk_command(b: &[u8]) -> Result<(), Error> {
    if b.is_empty() || b.len() > 262144 {
        return Err(Error::Protocol);
    }
    let good = match b[0] {
        1 => {
            b.len() >= 5
                && u32_at(b, 1) as usize <= 300
                && b.len() == 5 + u32_at(b, 1) as usize
                && std::str::from_utf8(&b[5..]).is_ok()
        }
        8 => b.len() == 2 && b[1] <= 2,
        9 => {
            b.len() >= 14
                && b[9] <= 1
                && b.len() == 14 + u32_at(b, 10) as usize
                && std::str::from_utf8(&b[14..]).is_ok()
        }
        12 => {
            b.len() >= 10
                && b[7] <= 127
                && b.len() >= 10 + b[7] as usize
                && b.len()
                    == 10
                        + b[7] as usize
                        + u16::from_be_bytes([b[8 + b[7] as usize], b[9 + b[7] as usize]]) as usize
        }
        13 => b.len() >= 5 && b.len() == 5 + u16::from_be_bytes([b[3], b[4]]) as usize,
        _ => false,
    };
    if good {
        Ok(())
    } else {
        Err(Error::Protocol)
    }
}
pub fn validate_device(b: &[u8]) -> Result<(), Error> {
    if b.is_empty() || b.len() > 262144 {
        return Err(Error::Protocol);
    }
    let good = match b[0] {
        0 => {
            b.len() >= 5
                && b.len() == 5 + u32_at(b, 1) as usize
                && std::str::from_utf8(&b[5..]).is_ok()
        }
        1 => b.len() == 9,
        2 => b.len() >= 5 && b.len() == 5 + u16::from_be_bytes([b[3], b[4]]) as usize,
        _ => false,
    };
    if good {
        Ok(())
    } else {
        Err(Error::Protocol)
    }
}
pub struct DeviceParser {
    header: [u8; 9],
    used: usize,
    blob: Option<Blob>,
    filled: usize,
    pub started: Option<u64>,
}
impl Default for DeviceParser {
    fn default() -> Self {
        Self {
            header: [0; 9],
            used: 0,
            blob: None,
            filled: 0,
            started: None,
        }
    }
}
impl DeviceParser {
    pub fn push_with_pools(
        &mut self,
        b: &[u8],
        bulk: &BlobPool,
        small: &BlobPool,
        acks: &BlobPool,
        now: u64,
    ) -> Result<(usize, Option<Blob>), Error> {
        self.push_inner(b, bulk, small, acks, now)
    }
    pub fn push(
        &mut self,
        b: &[u8],
        pool: &BlobPool,
        now: u64,
    ) -> Result<(usize, Option<Blob>), Error> {
        self.push_inner(b, pool, pool, pool, now)
    }
    fn push_inner(
        &mut self,
        b: &[u8],
        pool: &BlobPool,
        small: &BlobPool,
        acks: &BlobPool,
        now: u64,
    ) -> Result<(usize, Option<Blob>), Error> {
        if b.is_empty() {
            return Ok((0, None));
        }
        let start = *self.started.get_or_insert(now);
        if now < start {
            return Err(Error::Clock);
        }
        if now - start >= crate::BULK_LIFETIME {
            return Err(Error::Deadline);
        }
        let mut n = 0;
        if self.blob.is_none() {
            if self.used == 0 {
                self.header[0] = b[0];
                self.used = 1;
                n = 1;
            }
            let h = match self.header[0] {
                0 | 2 => 5,
                1 => 9,
                _ => return Err(Error::Protocol),
            };
            let copy = (h - self.used).min(b.len() - n);
            self.header[self.used..self.used + copy].copy_from_slice(&b[n..n + copy]);
            self.used += copy;
            n += copy;
            if self.used < h {
                return Ok((n, None));
            }
            let total = match self.header[0] {
                0 => 5usize
                    .checked_add(u32_at(&self.header, 1) as usize)
                    .ok_or(Error::Protocol)?,
                1 => 9,
                _ => 5 + u16::from_be_bytes([self.header[3], self.header[4]]) as usize,
            };
            let selected = if self.header[0] == 1 {
                acks
            } else if self.header[0] == 2 && total <= 976 {
                small
            } else {
                pool
            };
            let mut blob = selected.allocate(total)?;
            blob.write(0, &self.header[..h])?;
            self.filled = h;
            self.blob = Some(blob);
        }
        let blob = self.blob.as_mut().unwrap();
        let copy = (blob.len() - self.filled).min(b.len() - n);
        blob.write(self.filled, &b[n..n + copy])?;
        self.filled += copy;
        n += copy;
        if self.filled == blob.len() {
            validate_device(blob.as_slice())?;
            let blob = self.blob.take();
            self.used = 0;
            self.started = None;
            return Ok((n, blob));
        }
        Ok((n, None))
    }
}
pub struct SocketGroup {
    pub video: Option<UnixStream>,
    pub audio: Option<UnixStream>,
    pub control: Option<UnixStream>,
    preamble: usize,
    first: u8,
}

/// QA-only, preloaded original stock records. Ordinary HostConfig has no such
/// source selection. The file and its bounded index are accounted together.
#[cfg(feature = "qa")]
pub struct PreparedFixture {
    bytes: Vec<u8>,
    entries: [FixtureEntry; 768],
    count: usize,
    video_keys: [usize; 768],
    video_key_count: usize,
    started: Option<std::time::Instant>,
    access_units: [u32; 2],
    recovery_requests: u64,
    controls: FixtureControl,
}
#[cfg(feature = "qa")]
#[derive(Default)]
struct FixtureControl {
    partial: Vec<u8>,
    responses: std::collections::VecDeque<Vec<u8>>,
    response_offset: usize,
    response_bytes: usize,
    clipboard: Vec<u8>,
    commands: u32,
    observed: u32,
    recovery_commands: u64,
}
#[cfg(feature = "qa")]
impl FixtureControl {
    fn observe(&mut self, kind: u64, bytes: &[u8]) {
        // QA-only exact prepared sink: bounded digests, never raw commands.
        if self.observed == 64 {
            return;
        }
        self.observed += 1;
        let digest = boring::sha::sha256(bytes);
        let words: Vec<_> = digest
            .chunks_exact(8)
            .map(|b| u64::from_be_bytes(b.try_into().unwrap()))
            .collect();
        static ORIGIN: std::sync::OnceLock<std::time::Instant> = std::sync::OnceLock::new();
        let elapsed = ORIGIN
            .get_or_init(std::time::Instant::now)
            .elapsed()
            .as_nanos() as u64
            + 1;
        eprintln!(
            "GBQC1 {} {} {} {} {} {} {} {}",
            self.observed,
            kind,
            bytes.len(),
            elapsed,
            words[0],
            words[1],
            words[2],
            words[3]
        );
    }
    fn queue(&mut self, bytes: Vec<u8>) -> Result<(), Error> {
        if self.responses.len() >= 64
            || self.partial.len() + self.clipboard.len() + self.response_bytes + bytes.len()
                > 524288
        {
            return Err(Error::Capacity);
        }
        self.response_bytes += bytes.len();
        self.responses.push_back(bytes);
        Ok(())
    }
    fn write(&mut self, bytes: &[u8]) -> Result<usize, Error> {
        if self.partial.len() + bytes.len() > 262144
            || self.partial.len() + self.clipboard.len() + self.response_bytes + bytes.len()
                > 524288
        {
            return Err(Error::Capacity);
        }
        self.partial.extend_from_slice(bytes);
        loop {
            let b = &self.partial;
            let Some(&kind) = b.first() else {
                break;
            };
            let length = match kind {
                0 => 14,
                2 => 32,
                3 => 21,
                4 | 8 | 10 => 2,
                5..=7 | 11 | 15 => 1,
                14 => 3,
                21 => 5,
                23 => 33,
                1 if b.len() >= 5 => 5 + u32_at(b, 1) as usize,
                9 if b.len() >= 14 => 14 + u32_at(b, 10) as usize,
                12 if b.len() >= 8 && b.len() >= 10 + b[7] as usize => {
                    10 + b[7] as usize
                        + u16::from_be_bytes([b[8 + b[7] as usize], b[9 + b[7] as usize]]) as usize
                }
                13 if b.len() >= 5 => 5 + u16::from_be_bytes([b[3], b[4]]) as usize,
                16 if b.len() >= 2 => 2 + b[1] as usize,
                1 | 9 | 12 | 13 | 16 => break,
                _ => return Err(Error::Protocol),
            };
            if length > 262144 {
                return Err(Error::Capacity);
            }
            if b.len() < length {
                break;
            }
            let command = self.partial[..length].to_vec();
            if matches!(kind, 8 | 9) || matches!(kind, 12 | 13) && length > 924 {
                validate_bulk_command(&command)?;
            } else if kind == 23 {
                /* already produced by the actual typed recovery mapper */
                self.recovery_commands = self
                    .recovery_commands
                    .checked_add(1)
                    .ok_or(Error::Capacity)?;
            } else if kind == 2 && command[1] == 2 {
                if command[18..20] == [0, 0] || command[20..22] == [0, 0] {
                    return Err(Error::Protocol);
                }
            } else {
                let class = match kind {
                    0 => 4,
                    2 => {
                        if command[1] == 0 {
                            1
                        } else if command[1] == 1 {
                            2
                        } else {
                            3
                        }
                    }
                    3 => 8,
                    12..=14 => 5,
                    16 => 7,
                    21 => 6,
                    _ => 9,
                };
                galaxybridge_quic_media::control::validate(class, &command)?;
            }
            self.commands = self.commands.checked_add(1).ok_or(Error::Capacity)?;
            if self.commands > 4096 {
                return Err(Error::Capacity);
            }
            self.partial.drain(..length);
            self.observe(1, &command);
            match kind {
                9 => {
                    let value = command[14..].to_vec();
                    if self.partial.len() + self.response_bytes + value.len() + 9 > 524288 {
                        return Err(Error::Capacity);
                    }
                    self.clipboard = value;
                    let mut ack = vec![1];
                    ack.extend_from_slice(&command[1..9]);
                    self.queue(ack)?;
                }
                8 => {
                    let mut reply = vec![0];
                    reply.extend((self.clipboard.len() as u32).to_be_bytes());
                    reply.extend_from_slice(&self.clipboard);
                    self.queue(reply)?;
                }
                12 => {
                    self.queue(vec![2, command[1], command[2], 0, 1, 0])?;
                }
                _ => {}
            }
        }
        Ok(bytes.len())
    }
    fn read(&mut self, bytes: &mut [u8]) -> Option<usize> {
        let front = self.responses.front()?;
        let n = bytes.len().min(front.len() - self.response_offset);
        bytes[..n].copy_from_slice(&front[self.response_offset..self.response_offset + n]);
        self.response_offset += n;
        self.response_bytes -= n;
        if self.response_offset == front.len() {
            let response = self.responses.pop_front().unwrap();
            self.response_offset = 0;
            self.observe(2, &response);
        }
        Some(n)
    }
}
#[cfg(all(test, feature = "qa"))]
mod fixture_control_tests {
    use super::*;
    #[test]
    fn fragmented_initial_uhid_and_clipboard_preserve_response_order() {
        let mut sink = FixtureControl::default();
        let mut commands = vec![12, 0, 7, 0, 0, 0, 0, 0, 0, 1, 0, 9];
        commands.extend(91u64.to_be_bytes());
        commands.extend([0, 0, 0, 0, 1, b'x', 8, 1]);
        for chunk in commands.chunks(3) {
            sink.write(chunk).unwrap();
        }
        let mut output = [0; 64];
        for expected in [
            vec![2, 0, 7, 0, 1, 0],
            vec![1, 0, 0, 0, 0, 0, 0, 0, 91],
            vec![0, 0, 0, 0, 1, b'x'],
        ] {
            assert_eq!(sink.read(&mut output), Some(expected.len()));
            assert_eq!(&output[..expected.len()], expected);
        }
        assert_eq!(sink.read(&mut output), None);
    }
    #[test]
    fn full_original_set_precedes_true_stock_ack_and_clipboard_response() {
        let mut sink = FixtureControl::default();
        let mut set = vec![9];
        set.extend(91u64.to_be_bytes());
        set.extend([0, 0, 0, 0, 1, b'x']);
        let mut out = [0; 64];
        assert_eq!(sink.write(&set[..14]).unwrap(), 14);
        assert_eq!(
            sink.read(&mut out),
            None,
            "partial command cannot acknowledge"
        );
        sink.write(&set[14..]).unwrap();
        assert_eq!(sink.read(&mut out), Some(9));
        assert_eq!(&out[..9], &[1, 0, 0, 0, 0, 0, 0, 0, 91]);
        sink.write(&[8, 1]).unwrap();
        assert_eq!(sink.read(&mut out), Some(6));
        assert_eq!(&out[..6], &[0, 0, 0, 0, 1, b'x']);
        assert_eq!(sink.read(&mut out), None);
        assert!(sink.write(&[255]).is_err());
        let mut sink = FixtureControl::default();
        for _ in 0..64 {
            sink.write(&[8, 0]).unwrap();
        }
        assert!(
            sink.write(&[8, 0]).is_err(),
            "response slots remain bounded"
        );
    }
    #[test]
    fn fragmented_recovery_command_is_counted_only_after_complete_parse() {
        let mut sink = FixtureControl::default();
        let mut recovery = vec![0; 33];
        recovery[0] = 23;
        for chunk in recovery.chunks(4) {
            sink.write(chunk).unwrap();
        }
        assert_eq!(sink.commands, 1);
        assert_eq!(sink.recovery_commands, 1);
    }
}
#[cfg(feature = "qa")]
#[derive(Clone, Copy, Default)]
struct FixtureEntry {
    due: u64,
    track: u8,
    begin: usize,
    offset: usize,
    end: usize,
}
#[cfg(feature = "qa")]
impl PreparedFixture {
    pub const LIMIT: usize = 16 * 1024 * 1024;
    pub fn load(path: &std::path::Path, expected: [u8; 32]) -> Result<Self, Error> {
        let mut file = std::fs::File::open(path)?;
        let size = file.metadata()?;
        if !size.is_file()
            || size.len() as u128 + std::mem::size_of::<Self>() as u128 > Self::LIMIT as u128
        {
            return Err(Error::Capacity);
        }
        let mut bytes = vec![0; size.len() as usize];
        file.read_exact(&mut bytes)?;
        let mut extra = [0];
        if file.read(&mut extra)? != 0 {
            return Err(Error::Protocol);
        }
        Self::from_bytes(bytes, expected)
    }
    pub fn from_bytes(bytes: Vec<u8>, expected: [u8; 32]) -> Result<Self, Error> {
        if bytes.capacity() > Self::LIMIT - std::mem::size_of::<Self>() {
            return Err(Error::Capacity);
        }
        if boring::sha::sha256(&bytes) != expected {
            return Err(Error::Authentication);
        }
        if bytes.len() < 12
            || &bytes[..4] != b"GBF1"
            || bytes[4] == 0
            || bytes[4] & !7 != 0
            || bytes[5..8] != [0; 3]
        {
            return Err(Error::Protocol);
        }
        let count = u32_at(&bytes, 8) as usize;
        if count == 0 || count > 768 {
            return Err(Error::Capacity);
        }
        let mut entries = [FixtureEntry::default(); 768];
        let mut at = 12usize;
        let mut last = 0;
        let mut readers = [
            galaxybridge_quic_media::stock::Reader::new(true, false),
            galaxybridge_quic_media::stock::Reader::new(false, false),
        ];
        let mut codecs = [None, None];
        let mut configs = [None, None];
        let mut access_units = [0u32; 2];
        let mut seen = [false; 2];
        let mut video_keys = [0usize; 768];
        let mut video_key_count = 0usize;
        for (entry_index, entry) in entries[..count].iter_mut().enumerate() {
            if bytes.len() - at < 16 {
                return Err(Error::Protocol);
            }
            let due = crate::bulk::u64_at(&bytes, at);
            let track = bytes[at + 8];
            let size = u32_at(&bytes, at + 12) as usize;
            if due < last
                || due >= 30_000_000_000
                || !matches!(track, 1 | 2)
                || bytes[4] & (1 << (track - 1)) == 0
                || bytes[at + 9..at + 12] != [0; 3]
                || size == 0
            {
                return Err(Error::Protocol);
            }
            at += 16;
            let end = at.checked_add(size).ok_or(Error::Capacity)?;
            if end > bytes.len() {
                return Err(Error::Protocol);
            }
            *entry = FixtureEntry {
                due,
                track,
                begin: at,
                offset: at,
                end,
            };
            last = due;
            let index = (track - 1) as usize;
            seen[index] = true;
            let mut entry_independent = false;
            while at < end {
                let (n, event) = readers[index].push(&bytes[at..end], 0)?;
                if n == 0 {
                    return Err(Error::Protocol);
                }
                at += n;
                use galaxybridge_quic_media::{
                    codec::{Codec, Configuration},
                    stock::Event,
                };
                match event {
                    Some(Event::Codec(code)) => {
                        codecs[index] = Some(match &code {
                            b"h264" => Codec::H264,
                            b"h265" => Codec::H265,
                            _ => Codec::Aac,
                        })
                    }
                    Some(Event::VideoSession(_)) => configs[index] = None,
                    Some(Event::Configuration(b)) => {
                        configs[index] = Some(Configuration::parse(
                            codecs[index].ok_or(Error::Protocol)?,
                            &b,
                        )?)
                    }
                    Some(Event::Packet { bytes, key, .. }) => {
                        let independent = configs[index]
                            .as_ref()
                            .ok_or(Error::Protocol)?
                            .independent(&bytes, key)?;
                        entry_independent |= independent;
                        access_units[index] =
                            access_units[index].checked_add(1).ok_or(Error::Capacity)?;
                    }
                    _ => {}
                }
            }
            // Every index entry ends on an original stock boundary; no
            // framing or allocation work is deferred into the scored interval.
            readers[index].eof()?;
            if track == 1 && entry_independent {
                if video_key_count == video_keys.len() {
                    return Err(Error::Capacity);
                }
                video_keys[video_key_count] = entry_index;
                video_key_count += 1;
            }
        }
        if at != bytes.len() {
            return Err(Error::Protocol);
        }
        for i in 0..2 {
            if bytes[4] & (1 << i) != 0 && !seen[i] {
                return Err(Error::Protocol);
            }
        }
        Ok(Self {
            bytes,
            entries,
            count,
            video_keys,
            video_key_count,
            started: None,
            access_units,
            recovery_requests: 0,
            controls: Default::default(),
        })
    }
    pub fn enabled(&self) -> u8 {
        self.bytes[4]
    }
    pub fn access_units(&self) -> [u32; 2] {
        self.access_units
    }
    /// A prepared QA producer must honor the same sync-frame request as the
    /// Android encoder. Drop only not-yet-read video deltas before the next
    /// independently decodable AU and make that AU immediately available.
    /// Audio timing and all original encoded bytes/PTS remain unchanged.
    fn request_recovery(&mut self) {
        let Some(key_index) = self.video_keys[..self.video_key_count]
            .iter()
            .copied()
            .find(|&index| {
                let entry = self.entries[index];
                entry.offset == entry.begin && entry.offset < entry.end
            })
        else {
            return;
        };
        for entry in &mut self.entries[..key_index] {
            if entry.track == 1 && entry.offset < entry.end {
                entry.offset = entry.end;
            }
        }
        let start = *self.started.get_or_insert_with(std::time::Instant::now);
        self.entries[key_index].due = start.elapsed().as_nanos().min(u64::MAX as u128) as u64;
    }
    fn read(&mut self, track: u8, output: &mut [u8]) -> Result<Option<usize>, Error> {
        if track == 3 {
            return Ok(self.controls.read(output));
        }
        let start = *self.started.get_or_insert_with(std::time::Instant::now);
        let Some(entry) = self.entries[..self.count]
            .iter_mut()
            .find(|e| e.track == track && e.offset < e.end)
        else {
            return Ok(None);
        };
        if start.elapsed().as_nanos() < entry.due as u128 {
            return Ok(None);
        }
        let n = output.len().min(entry.end - entry.offset);
        output[..n].copy_from_slice(&self.bytes[entry.offset..entry.offset + n]);
        entry.offset += n;
        Ok(Some(n))
    }
}

pub(crate) enum Source {
    LiveStock(SocketGroup),
    #[cfg(feature = "qa")]
    PreparedFixture(PreparedFixture),
}
impl Source {
    #[cfg(feature = "qa")]
    pub fn recovery_requests(&self) -> u64 {
        match self {
            Self::PreparedFixture(s) => s.recovery_requests,
            _ => 0,
        }
    }
    pub fn consume_preamble(&mut self) -> Result<bool, Error> {
        match self {
            Self::LiveStock(s) => s.consume_preamble(),
            #[cfg(feature = "qa")]
            Self::PreparedFixture(_) => Ok(true),
        }
    }
    pub fn read(&mut self, track: u8, bytes: &mut [u8]) -> Result<Option<usize>, Error> {
        match self {
            Self::LiveStock(s) => s.read(track, bytes),
            #[cfg(feature = "qa")]
            Self::PreparedFixture(s) => s.read(track, bytes),
        }
    }
    pub fn write(&mut self, bytes: &[u8]) -> Result<usize, Error> {
        match self {
            Self::LiveStock(s) => s.write(bytes),
            #[cfg(feature = "qa")]
            Self::PreparedFixture(s) => {
                let before = s.controls.recovery_commands;
                let written = s.controls.write(bytes)?;
                let completed = s.controls.recovery_commands - before;
                for _ in 0..completed {
                    s.recovery_requests =
                        s.recovery_requests.checked_add(1).ok_or(Error::Capacity)?;
                    s.request_recovery();
                }
                Ok(written)
            }
        }
    }
}

#[derive(Clone, Debug)]
pub struct ProducerLaunch {
    pub jar: std::path::PathBuf,
    pub hevc: bool,
    pub max_size: u16,
    pub max_fps: u16,
    pub video_bit_rate: u32,
    pub audio_bit_rate: u32,
    /// Periodic independently decodable frames bound recovery even when a
    /// device codec ignores a later runtime sync-frame request.
    pub key_frame_interval_seconds: Option<u16>,
    pub new_display: Option<(u16, u16)>,
}
/// Closed existing Galaxy Bridge launch policies. None preserves the original
/// standalone backend defaults; no arbitrary producer arguments are accepted.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LaunchPolicy {
    Primary,
    Application { density: Option<u16> },
    VirtualDesktop { density: Option<u16> },
    PrimaryCleanup { cleanup: bool },
    ApplicationCleanup { density: Option<u16>, cleanup: bool },
    VirtualDesktopCleanup { density: Option<u16>, cleanup: bool },
}
impl LaunchPolicy {
    pub fn with_cleanup(self, cleanup: bool) -> Self {
        match self {
            Self::Primary | Self::PrimaryCleanup { .. } => Self::PrimaryCleanup { cleanup },
            Self::Application { density } | Self::ApplicationCleanup { density, .. } => {
                Self::ApplicationCleanup { density, cleanup }
            }
            Self::VirtualDesktop { density } | Self::VirtualDesktopCleanup { density, .. } => {
                Self::VirtualDesktopCleanup { density, cleanup }
            }
        }
    }
    fn split_cleanup(self) -> (Self, Option<bool>) {
        match self {
            Self::PrimaryCleanup { cleanup } => (Self::Primary, Some(cleanup)),
            Self::ApplicationCleanup { density, cleanup } => {
                (Self::Application { density }, Some(cleanup))
            }
            Self::VirtualDesktopCleanup { density, cleanup } => {
                (Self::VirtualDesktop { density }, Some(cleanup))
            }
            other => (other, None),
        }
    }
}
impl ProducerLaunch {
    pub fn command(
        &self,
        binding: &crate::bootstrap::Binding,
    ) -> Result<crate::process::OwnedCommand, Error> {
        self.command_with_policy(binding, None)
    }
    pub fn command_with_policy(
        &self,
        binding: &crate::bootstrap::Binding,
        policy: Option<LaunchPolicy>,
    ) -> Result<crate::process::OwnedCommand, Error> {
        let (policy, cleanup) = match policy {
            Some(value) => {
                let (base, cleanup) = value.split_cleanup();
                (Some(base), cleanup)
            }
            None => (None, None),
        };
        if !self.jar.is_absolute()
            || self.jar == std::path::Path::new("/data/local/tmp/scrcpy-server.jar")
            || self
                .jar
                .components()
                .any(|c| matches!(c, std::path::Component::ParentDir))
            || self.max_size == 0
            || self.max_fps == 0
            || self.video_bit_rate == 0
            || self.audio_bit_rate == 0
        {
            return Err(Error::Protocol);
        }
        binding.validate()?;
        let density = match policy {
            Some(LaunchPolicy::Primary) if binding.context.capture_kind != 0 => {
                return Err(Error::Protocol)
            }
            Some(
                LaunchPolicy::Application { density } | LaunchPolicy::VirtualDesktop { density },
            ) => {
                if binding.context.capture_kind != 1 || density == Some(0) {
                    return Err(Error::Protocol);
                }
                density
            }
            _ => None,
        };
        let mut args: Vec<std::ffi::OsString> = vec![
            "/".into(),
            "com.genymobile.scrcpy.Server".into(),
            crate::bootstrap::VERSION.into(),
            format!("scid={:08x}", binding.context.scid).into(),
            if policy.is_some() {
                "log_level=info"
            } else {
                "log_level=warn"
            }
            .into(),
            "tunnel_forward=true".into(),
            format!(
                "cleanup={}",
                cleanup.unwrap_or(!matches!(policy, Some(LaunchPolicy::Application { .. })))
            )
            .into(),
            format!("control={}", binding.context.enabled & 4 != 0).into(),
            "send_device_meta=true".into(),
            "send_dummy_byte=true".into(),
            "send_frame_meta=true".into(),
            "send_stream_meta=true".into(),
            format!("video={}", binding.context.enabled & 1 != 0).into(),
            format!("audio={}", binding.context.enabled & 2 != 0).into(),
            format!("video_codec={}", if self.hevc { "h265" } else { "h264" }).into(),
            "audio_codec=aac".into(),
            format!("max_size={}", self.max_size).into(),
            format!("max_fps={}", self.max_fps).into(),
            format!("video_bit_rate={}", self.video_bit_rate).into(),
            format!("audio_bit_rate={}", self.audio_bit_rate).into(),
        ];
        let mut video_codec_options = Vec::with_capacity(3);
        if let Some(seconds) = self.key_frame_interval_seconds {
            if seconds == 0 {
                return Err(Error::Protocol);
            }
            video_codec_options.push(format!("i-frame-interval={seconds}"));
        }
        // Every producer launched by this backend is the interactive Wi-Fi
        // path. Keep the same real-time/zero-buffer encoder requests as the
        // stock Wireless ADB path instead of silently dropping them at the
        // closed QUIC launch boundary.
        video_codec_options.extend(["priority=0".into(), "latency=0".into()]);
        args.push(format!("video_codec_options={}", video_codec_options.join(",")).into());
        if policy.is_some() {
            args.extend(
                [
                    "clipboard_autosync=false",
                    "power_on=false",
                    "keep_active=true",
                    "display_ime_policy=hide",
                ]
                .map(Into::into),
            );
        }
        if binding.context.capture_kind == 1 {
            let (w, h) = self.new_display.ok_or(Error::Protocol)?;
            if w == 0 || h == 0 {
                return Err(Error::Protocol);
            }
            let density = density.map(|d| format!("/{d}")).unwrap_or_default();
            args.push(format!("new_display={w}x{h}{density}").into());
            if policy.is_some() {
                args.push("vd_destroy_content=true".into());
                args.push(
                    if matches!(policy, Some(LaunchPolicy::Application { .. })) {
                        "vd_system_decorations=false"
                    } else {
                        "vd_system_decorations=true"
                    }
                    .into(),
                );
                if matches!(policy, Some(LaunchPolicy::Application { .. })) {
                    args.push("flex_display=true".into());
                }
            }
        } else {
            if self.new_display.is_some() {
                return Err(Error::Protocol);
            }
            args.push(format!("display_id={}", binding.context.display_id).into());
        }
        let command = crate::process::OwnedCommand {
            program: "/system/bin/app_process".into(),
            args,
        };
        command.validate()?;
        Ok(command)
    }
    pub fn verify_artifact(&self) -> Result<(), Error> {
        let mut file = std::fs::File::open(&self.jar)?;
        if file.metadata()?.len() > 32 * 1024 * 1024 {
            return Err(Error::Capacity);
        }
        let mut sha = boring::sha::Sha256::new();
        let mut b = [0; 8192];
        loop {
            let n = file.read(&mut b)?;
            if n == 0 {
                break;
            }
            sha.update(&b[..n]);
        }
        if sha.finish() != crate::bootstrap::PRODUCER_SHA {
            return Err(Error::Authentication);
        }
        Ok(())
    }
}

pub struct Connector {
    scid: u32,
    producer_pid: u32,
    enabled: u8,
    next: u8,
    video: Option<UnixStream>,
    audio: Option<UnixStream>,
    control: Option<UnixStream>,
}
impl Connector {
    pub fn new(scid: u32, enabled: u8, producer_pid: u32) -> Self {
        Self {
            scid,
            producer_pid,
            enabled,
            next: 1,
            video: None,
            audio: None,
            control: None,
        }
    }
    pub fn poll(&mut self) -> Result<Option<SocketGroup>, Error> {
        while self.next <= 3 {
            if self.enabled & (1 << (self.next - 1)) == 0 {
                self.next += 1;
                continue;
            }
            let Some(socket) = connect_abstract(self.scid, self.producer_pid)? else {
                return Ok(None);
            };
            match self.next {
                1 => self.video = Some(socket),
                2 => self.audio = Some(socket),
                _ => self.control = Some(socket),
            }
            self.next += 1;
        }
        if self.next == 4 {
            self.next = 5;
            return Ok(Some(SocketGroup::connected_optional(
                self.video.take(),
                self.audio.take(),
                self.control.take(),
            )?));
        }
        Ok(None)
    }
}
fn connect_abstract(scid: u32, producer_pid: u32) -> Result<Option<UnixStream>, Error> {
    #[cfg(target_os = "android")]
    {
        use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
        let fd = unsafe {
            libc::socket(
                libc::AF_UNIX,
                libc::SOCK_STREAM | libc::SOCK_NONBLOCK | libc::SOCK_CLOEXEC,
                0,
            )
        };
        if fd < 0 {
            return Err(Error::Io);
        }
        let fd = unsafe { OwnedFd::from_raw_fd(fd) };
        let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
        address.sun_family = libc::AF_UNIX as _;
        let name = format!("scrcpy_{scid:08x}");
        for (i, b) in name.bytes().enumerate() {
            address.sun_path[i + 1] = b as _;
        }
        let length =
            (std::mem::size_of_val(&address.sun_family) + 1 + name.len()) as libc::socklen_t;
        let result = unsafe {
            libc::connect(
                fd.as_raw_fd(),
                (&address as *const libc::sockaddr_un).cast(),
                length,
            )
        };
        if result == 0 {
            // The abstract name is not authentication: bind every connected
            // channel to the exact app_process child and this shell identity.
            let mut credential: libc::ucred = unsafe { std::mem::zeroed() };
            let mut size = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
            if unsafe {
                libc::getsockopt(
                    fd.as_raw_fd(),
                    libc::SOL_SOCKET,
                    libc::SO_PEERCRED,
                    (&mut credential as *mut libc::ucred).cast(),
                    &mut size,
                )
            } != 0
                || size as usize != std::mem::size_of::<libc::ucred>()
                || credential.pid <= 0
                || credential.pid as u32 != producer_pid
                || credential.uid != unsafe { libc::geteuid() }
            {
                return Err(Error::Authentication);
            }
            return Ok(Some(UnixStream::from(fd)));
        }
        let error = std::io::Error::last_os_error().raw_os_error();
        if matches!(
            error,
            Some(libc::ECONNREFUSED) | Some(libc::ENOENT) | Some(libc::EAGAIN)
        ) {
            return Ok(None);
        }
        Err(Error::Io)
    }
    #[cfg(not(target_os = "android"))]
    {
        let _ = (scid, producer_pid);
        Err(Error::Unsupported)
    }
}
impl SocketGroup {
    pub fn connected(
        video: Option<UnixStream>,
        audio: Option<UnixStream>,
        control: UnixStream,
    ) -> Result<Self, Error> {
        Self::connected_optional(video, audio, Some(control))
    }
    pub fn connected_optional(
        video: Option<UnixStream>,
        audio: Option<UnixStream>,
        control: Option<UnixStream>,
    ) -> Result<Self, Error> {
        if video.is_none() && audio.is_none() && control.is_none() {
            return Err(Error::Protocol);
        }
        for s in video.iter().chain(audio.iter()).chain(control.iter()) {
            s.set_nonblocking(true)?;
            use std::os::fd::AsRawFd;
            crate::process::nonblocking(s.as_raw_fd())?;
        }
        let first = if video.is_some() {
            1
        } else if audio.is_some() {
            2
        } else {
            3
        };
        Ok(Self {
            video,
            audio,
            control,
            preamble: 65,
            first,
        })
    }
    pub fn consume_preamble(&mut self) -> Result<bool, Error> {
        if self.preamble == 0 {
            return Ok(true);
        }
        let s = match self.first {
            1 => self.video.as_mut().unwrap(),
            2 => self.audio.as_mut().unwrap(),
            _ => self.control.as_mut().ok_or(Error::Protocol)?,
        };
        let mut b = [0; 65];
        match s.read(&mut b[..self.preamble]) {
            Ok(0) => Err(Error::Retired),
            Ok(n) => {
                if self.preamble == 65 && b[0] != 0 {
                    return Err(Error::Protocol);
                }
                self.preamble -= n;
                Ok(self.preamble == 0)
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => Ok(false),
            Err(_) => Err(Error::Io),
        }
    }
    pub fn read(&mut self, track: u8, b: &mut [u8]) -> Result<Option<usize>, Error> {
        let s = match track {
            1 => self.video.as_mut().ok_or(Error::Protocol)?,
            2 => self.audio.as_mut().ok_or(Error::Protocol)?,
            _ => self.control.as_mut().ok_or(Error::Protocol)?,
        };
        match s.read(b) {
            Ok(0) => Err(Error::Retired),
            Ok(n) => Ok(Some(n)),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => Ok(None),
            Err(_) => Err(Error::Io),
        }
    }
    pub fn write(&mut self, b: &[u8]) -> Result<usize, Error> {
        match self.control.as_mut().ok_or(Error::Protocol)?.write(b) {
            Ok(0) => Err(Error::Io),
            Ok(n) => Ok(n),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => Ok(0),
            Err(_) => Err(Error::Io),
        }
    }
}
