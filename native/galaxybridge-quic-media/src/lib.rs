//! Standalone G1. No installed routing or producer control integration.
pub mod codec;
pub mod control;
pub mod media;
pub mod stock;
pub mod wire;

pub const MS: u64 = 1_000_000;
pub const AU_LIFETIME: u64 = 120 * MS;
pub const RECEIVE_LIFETIME: u64 = 60 * MS;
pub const INDEPENDENT_AU_LIFETIME: u64 = 250 * MS;
pub const INDEPENDENT_RECEIVE_LIFETIME: u64 = 200 * MS;
// The first IDR crosses a cold QUIC congestion window. A later large IDR also
// needs this bounded budget: a measured 214,861-byte Fold 5 recovery IDR lost
// 19 of 224 fragments at the 250 ms boundary. Delta frames and smaller IDRs
// retain the shorter budgets, so stale video still cannot queue.
pub const STARTUP_INDEPENDENT_AU_LIFETIME: u64 = 500 * MS;
pub const STARTUP_INDEPENDENT_RECEIVE_LIFETIME: u64 = 450 * MS;
// A requested repair IDR is the one frame that repairs a broken datagram
// dependency chain.  It travels over the media endpoint's bounded reliable
// stream, never the input or bulk connection.  Give that finite transfer most
// of the receiver's 1.75 second recovery episode; ordinary video retains its
// realtime 120/250/500 ms datagram deadlines.
pub const RELIABLE_RECOVERY_AU_LIFETIME: u64 = 1_500 * MS;
pub const RELIABLE_RECOVERY_RECEIVE_LIFETIME: u64 = 1_400 * MS;
pub const EXTENDED_INDEPENDENT_AU_MIN_BYTES: usize = 192 * 1024;
pub const TRANSACTION_LIFETIME: u64 = 500 * MS;
// A reliable control object must still enter QUIC within the ordinary 500 ms
// freshness window. Once the complete object has been accepted by QUIC,
// however, its cumulative application ACK may legitimately trail busy video
// processing. This longer boundary is only an acknowledgement budget: it
// cannot make an undispatched gesture wait and become stale input.
pub const RELIABLE_CONTROL_ACK_LIFETIME: u64 = 2_000 * MS;
fn original_deadline(received: u64, now: u64) -> Result<u64, Failure> {
    if received > now {
        return Err(Failure::Clock);
    }
    let cutoff = received
        .checked_add(TRANSACTION_LIFETIME)
        .ok_or(Failure::Clock)?;
    if now >= cutoff {
        return Err(Failure::Deadline);
    }
    Ok(cutoff)
}
pub const MOVE_LIFETIME: u64 = 40 * MS;
pub const RECOVERY_LIFETIME: u64 = 250 * MS;
/// Signed bootstrap capability. Both endpoints must carry this bit in the
/// exact Context binding before kind15 single-loss XOR parity is legal.
pub const FEATURE_XOR_PARITY: u8 = 1 << 3;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Failure {
    Protocol,
    Capacity,
    Deadline,
    Clock,
    Retired,
    Unsupported,
    Codec,
    UnrecoverableVideoGap,
    Sink,
}

use galaxybridge_quic::{Admission, Message};
use std::collections::VecDeque;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Context {
    pub session: [u8; 32],
    pub generation: u64,
    pub scid: u32,
    pub capture_kind: u8,
    pub display_id: u32,
    pub target_token: u64,
    pub enabled: u8,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Confirmation {
    MetadataCommit,
    StockSinkWrite,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    NotDispatched(Failure),
    UnknownRemoteOutcome(Failure),
    PeerBoundaryConfirmed(Confirmation),
    SupersededBeforeDispatch,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TransactionResult {
    pub token: u64,
    pub outcome: Outcome,
}
#[derive(Debug)]
pub struct Dispatch {
    pub record_token: u64,
    pub message: Message,
    pub deadline: u64,
    /// A requested duplicate, not the initial transmission of this fragment.
    /// Local expiry of a repair does not establish a new missing access unit.
    pub media_repair: bool,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
struct Key {
    kind: u8,
    track: u8,
    epoch: u32,
    config: u32,
    sequence: u64,
}
impl Key {
    fn of(r: &wire::Record) -> Self {
        Self {
            kind: r.kind,
            track: r.track,
            epoch: r.epoch,
            config: r.config,
            sequence: r.sequence,
        }
    }
}
struct Transaction {
    token: u64,
    record: wire::Record,
    bytes: media::Bytes,
    queued: u64,
    deadline: u64,
    next: u16,
    accepted: bool,
    result: Option<Outcome>,
}
struct Pending {
    record_token: u64,
    transaction: u64,
}
pub struct Core {
    context: Context,
    transactions: VecDeque<Transaction>,
    pending: Option<Pending>,
    serial: u64,
    last: u64,
    terminal: Option<Failure>,
    metadata_acks: [[Option<Key>; 15]; 3],
    expired_watermarks: [Option<Key>; 3],
    critical_acked: u64,
    critical_queued: u64,
    meta_pool: media::Pool,
    critical_pool: media::Pool,
}

/// Serialized G1 owner. All times are caller-local nanoseconds, never peer timestamps.
enum OwnerPending {
    Transaction(u64),
    Media(wire::Record, bool),
    Move(wire::Record),
    Feedback,
}
pub struct Owner {
    pub transactions: Core,
    pub receiver: media::Receiver,
    pub cache: media::Cache,
    pending: Option<(u64, OwnerPending)>,
    serial: u64,
    sources: [stock::Source; 2],
    active_stock: Option<u8>,
    deferred_stock: Option<DeferredStock>,
    input: control::SourceInput,
}
struct DeferredStock {
    track: u8,
    started: u64,
    event: stock::Event,
    _charge: media::ForeignCopyCharge,
}
/// Selection is checked before issuing a pending transport record.
#[derive(Clone, Copy, Debug)]
pub struct DispatchPolicy {
    pub feedback: bool,
    pub metadata: bool,
    pub critical_through: Option<u64>,
    pub moves: bool,
    pub media: bool,
}
impl Default for DispatchPolicy {
    fn default() -> Self {
        Self {
            feedback: true,
            metadata: true,
            critical_through: None,
            moves: true,
            media: true,
        }
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StockPublication {
    pub kind: u8,
    pub track: u8,
    pub epoch: u32,
    pub config: u32,
    pub sequence: u64,
    pub started: u64,
    pub independent: bool,
}
impl Owner {
    pub fn ingest_stock_observed(
        &mut self,
        track: u8,
        bytes: &[u8],
        now: u64,
    ) -> Result<(usize, stock::Admission, Option<StockPublication>), Failure> {
        self.ingest_stock_inner(track, bytes, now)
    }
    pub fn queue_critical(&mut self, record: wire::Record, now: u64) -> Result<u64, Failure> {
        self.queue_critical_received(record, now, now)
    }
    pub fn queue_critical_received(
        &mut self,
        record: wire::Record,
        received: u64,
        now: u64,
    ) -> Result<u64, Failure> {
        original_deadline(received, now)?;
        self.tick(now)?;
        if self.pending.is_some() {
            media::first_error::reject(2, line!(), 0, 0, 0, 0, 0);
            return Err(Failure::Protocol);
        }
        if self.transactions.context.enabled & 4 == 0
            || record.generation != self.transactions.context.generation
        {
            media::first_error::reject(2, line!(), 0, 0, 0, 0, 0);
            return Err(Failure::Protocol);
        }
        self.receiver.check_control_geometry(&record)?;
        if let Some(epoch) = self.receiver.control_epoch() {
            self.input.sync_epoch(epoch)?;
        }
        let class = self.input.validate_critical(&record)?;
        let token = self
            .transactions
            .queue_transaction_received(record.clone(), received, now)?;
        self.input.admitted_critical(&record, class);
        Ok(token)
    }
    pub fn replace_move(
        &mut self,
        record: wire::Record,
        received: u64,
        now: u64,
    ) -> Result<control::MoveAdmission, Failure> {
        self.tick(now)?;
        if self.pending.is_some()
            || self.transactions.context.enabled & 4 == 0
            || record.generation != self.transactions.context.generation
        {
            media::first_error::reject(2, line!(), 0, 0, 0, 0, 0);
            return Err(Failure::Protocol);
        }
        self.receiver.check_control_geometry(&record)?;
        if let Some(epoch) = self.receiver.control_epoch() {
            self.input.sync_epoch(epoch)?;
        }
        self.input.replace(record, received, now)
    }
    pub fn move_usage(&self) -> (usize, usize) {
        self.input.usage()
    }
    pub fn new(context: Context, now: u64) -> Result<Self, Failure> {
        let pool = media::Pool::new(64, 256 * 1024);
        let xor_parity = context.enabled & FEATURE_XOR_PARITY != 0;
        Ok(Self {
            receiver: media::Receiver::with_pool(context.clone(), pool.clone())?,
            transactions: Core::with_pool(context, now, pool)?,
            cache: media::Cache::with_xor_parity(xor_parity),
            pending: None,
            serial: 0,
            sources: [stock::Source::new(true), stock::Source::new(false)],
            active_stock: None,
            deferred_stock: None,
            input: control::SourceInput::new(),
        })
    }
    pub fn ingest_stock(
        &mut self,
        track: u8,
        bytes: &[u8],
        now: u64,
    ) -> Result<(usize, stock::Admission), Failure> {
        self.ingest_stock_inner(track, bytes, now)
            .map(|(n, a, _)| (n, a))
    }
    fn ingest_stock_inner(
        &mut self,
        track: u8,
        bytes: &[u8],
        now: u64,
    ) -> Result<(usize, stock::Admission, Option<StockPublication>), Failure> {
        self.ingest_stock_mode(track, bytes, now, false)
    }
    /// Opt-in live metadata fence. Consumed bytes belong to this Owner, and
    /// zero consumption on resume never permits skipping successor bytes.
    pub fn ingest_stock_observed_deferred(
        &mut self,
        track: u8,
        bytes: &[u8],
        now: u64,
    ) -> Result<(usize, stock::Admission, Option<StockPublication>), Failure> {
        self.ingest_stock_mode(track, bytes, now, true)
    }
    pub fn deferred_stock_track(&self) -> Option<u8> {
        self.deferred_stock.as_ref().map(|d| d.track)
    }
    fn ingest_stock_mode(
        &mut self,
        track: u8,
        bytes: &[u8],
        now: u64,
        defer: bool,
    ) -> Result<(usize, stock::Admission, Option<StockPublication>), Failure> {
        self.tick(now)?;
        if !matches!(track, 1 | 2) || self.transactions.context.enabled & (1 << (track - 1)) == 0 {
            return Err(Failure::Protocol);
        }
        if self.active_stock.is_some_and(|active| active != track) {
            media::first_error::reject(2, line!(), 1, 1, 1, 0, 0);
            return Err(Failure::Capacity);
        }
        if self
            .deferred_stock
            .as_ref()
            .is_some_and(|d| d.track == track)
        {
            if !defer {
                return Err(Failure::Protocol);
            }
            if self.sources[track as usize - 1].watermark_due.is_some()
                || self.transactions.live_watermark(track)
            {
                return Ok((0, stock::Admission::Incomplete, None));
            }
            let deferred = self.deferred_stock.take().unwrap();
            self.active_stock = None;
            return self.publish_stock_event(track, deferred.event, deferred.started, now, 0);
        }
        let source = &mut self.sources[track as usize - 1];
        let started = source.reader.deadline().map_or(now, |d| d - AU_LIFETIME);
        let (n, event) = match source.reader.push(bytes, now) {
            Ok(v) => v,
            Err(e) => {
                self.retire(e);
                return Err(e);
            }
        };
        self.active_stock = if source.reader.deadline().is_some() {
            Some(track)
        } else {
            None
        };
        let Some(event) = event else {
            return Ok((n, stock::Admission::Incomplete, None));
        };
        if defer
            && matches!(
                event,
                stock::Event::VideoSession(_) | stock::Event::Configuration(_)
            )
            && (source.watermark_due.is_some() || self.transactions.live_watermark(track))
        {
            if self.deferred_stock.is_some() {
                media::first_error::reject(2, line!(), 1, 1, 1, 0, 0);
                self.retire(Failure::Capacity);
                return Err(Failure::Capacity);
            }
            let bytes = match &event {
                stock::Event::Configuration(b) => b.capacity(),
                _ => 12,
            };
            let charge = self
                .transactions
                .meta_pool
                .reserve_pending_metadata(bytes)?;
            self.deferred_stock = Some(DeferredStock {
                track,
                started,
                event,
                _charge: charge,
            });
            return Ok((n, stock::Admission::Incomplete, None));
        }
        self.publish_stock_event(track, event, started, now, n)
    }
    fn publish_stock_event(
        &mut self,
        track: u8,
        event: stock::Event,
        started: u64,
        now: u64,
        n: usize,
    ) -> Result<(usize, stock::Admission, Option<StockPublication>), Failure> {
        let (kind, independent) = match &event {
            stock::Event::Codec(_) => (2, false),
            stock::Event::VideoSession(_) => (3, false),
            stock::Event::Configuration(_) => (4, false),
            stock::Event::Packet { key, .. } => (5, *key),
            stock::Event::Disabled(_) => (12, false),
        };
        let sequence = self.sources[track as usize - 1].next;
        let result = self.source_event(track, event, started, now);
        if let Err(e) = result {
            self.retire(e)
        }
        result.map(|v| {
            let s = &self.sources[track as usize - 1];
            (
                n,
                v,
                Some(StockPublication {
                    kind,
                    track,
                    epoch: s.epoch,
                    config: s.version,
                    sequence,
                    started,
                    independent,
                }),
            )
        })
    }
    fn source_event(
        &mut self,
        track: u8,
        event: stock::Event,
        started: u64,
        now: u64,
    ) -> Result<stock::Admission, Failure> {
        let s = &mut self.sources[track as usize - 1];
        let generation = self.transactions.context.generation;
        let mut r = wire::Record {
            kind: 0,
            track,
            flags: 0,
            generation,
            epoch: s.epoch,
            config: s.version,
            sequence: s.next,
            pts: 0,
            total: 0,
            index: 0,
            count: 1,
            age_us: 0,
            lifetime_us: 500000,
            body: vec![],
        };
        match event {
            stock::Event::Codec(b) => {
                let codec = match &b {
                    b"h264" => codec::Codec::H264,
                    b"h265" => codec::Codec::H265,
                    [0, 97, 97, 99] => codec::Codec::Aac,
                    _ => return Err(Failure::Unsupported),
                };
                if s.codec.is_some() {
                    return Err(Failure::Protocol);
                }
                s.codec = Some(codec);
                r.kind = 2;
                r.epoch = 0;
                r.config = 0;
                r.sequence = 0;
                r.body = b.to_vec();
            }
            stock::Event::Disabled(b) => {
                r.kind = 12;
                r.epoch = 0;
                r.config = 0;
                r.sequence = 0;
                r.body = b.to_vec();
            }
            stock::Event::VideoSession(b) => {
                if s.watermark_due.is_some() || self.transactions.live_watermark(track) {
                    media::first_error::reject(2, line!(), 1, 1, 1, 0, 0);
                    return Err(Failure::Capacity);
                }
                s.epoch = s.epoch.checked_add(1).ok_or(Failure::Capacity)?;
                self.receiver.bind_control_geometry(
                    s.epoch,
                    wire::u32_at(&b, 4),
                    wire::u32_at(&b, 8),
                )?;
                r.epoch = s.epoch;
                r.config = 0;
                r.kind = 3;
                r.body = b.to_vec();
            }
            stock::Event::Configuration(b) => {
                if s.watermark_due.is_some() || self.transactions.live_watermark(track) {
                    media::first_error::reject(2, line!(), 1, 1, 1, 0, 0);
                    return Err(Failure::Capacity);
                }
                let parsed = codec::Configuration::parse(s.codec.ok_or(Failure::Protocol)?, &b)?;
                s.version = s.version.checked_add(1).ok_or(Failure::Capacity)?;
                s.epoch = s.epoch.max(1);
                r.epoch = s.epoch;
                r.config = s.version;
                r.kind = 4;
                r.body = b;
                s.parsed = Some(parsed);
            }
            stock::Event::Packet { pts, key, bytes } => {
                let independent = s
                    .parsed
                    .as_ref()
                    .ok_or(Failure::Protocol)?
                    .independent(&bytes, key)?;
                r.kind = 5;
                r.flags = 2 | u16::from(key);
                r.pts = pts;
                r.body = bytes;
                r.lifetime_us = 120000;
                let sequence = s.next;
                s.next = s.next.checked_add(1).ok_or(Failure::Capacity)?;
                s.watermark = sequence;
                if s.watermark_due.is_none() {
                    s.watermark_due = Some(now.checked_add(20 * MS).ok_or(Failure::Clock)?)
                }
                let observation = self
                    .receiver
                    .recovery_trace
                    .is_some()
                    .then(|| r.with_body(vec![]));
                let size = r.body.len();
                let lifetime = if track == 1
                    && independent
                    && key
                    && (sequence == 1 || size >= EXTENDED_INDEPENDENT_AU_MIN_BYTES)
                {
                    STARTUP_INDEPENDENT_AU_LIFETIME
                } else if track == 1 && independent && key {
                    INDEPENDENT_AU_LIFETIME
                } else {
                    AU_LIFETIME
                };
                let outcome = match self.queue_access_unit_with_lifetime(r, started, now, lifetime)
                {
                    Ok(()) => stock::Admission::AccessUnit { sequence },
                    Err(reason @ (Failure::Capacity | Failure::Deadline)) => {
                        media::first_error::handled();
                        stock::Admission::DroppedAccessUnit { sequence, reason }
                    }
                    Err(e) => return Err(e),
                };
                if let Some(r) = observation {
                    let value = match outcome {
                        stock::Admission::AccessUnit { .. } => 1,
                        stock::Admission::DroppedAccessUnit {
                            reason: Failure::Capacity,
                            ..
                        } => 2,
                        _ => 3,
                    };
                    self.receiver.trace_source_au(
                        &r,
                        independent,
                        size,
                        value,
                        started,
                        now,
                        lifetime,
                    );
                }
                return Ok(outcome);
            }
        }
        r.total = r.body.len() as u32;
        let token = self.transactions.queue_object(r, now)?;
        Ok(stock::Admission::Metadata(token))
    }
    pub fn stock_eof(&mut self, track: u8, now: u64) -> Result<(), Failure> {
        self.tick(now)?;
        if !matches!(track, 1 | 2) {
            return Err(Failure::Protocol);
        }
        if let Err(e) = self.sources[track as usize - 1].reader.eof() {
            self.retire(e);
            return Err(e);
        }
        Ok(())
    }
    pub fn queue_start(&mut self, now: u64) -> Result<u64, Failure> {
        let c = self.transactions.context();
        let mut body = c.scid.to_be_bytes().to_vec();
        body.extend([c.capture_kind, c.enabled, 0, 0]);
        body.extend(c.display_id.to_be_bytes());
        body.extend(c.target_token.to_be_bytes());
        self.transactions.queue_transaction(
            wire::Record {
                kind: 1,
                track: 0,
                flags: 0,
                generation: c.generation,
                epoch: 0,
                config: 0,
                sequence: 0,
                pts: 0,
                total: 20,
                index: 0,
                count: 1,
                age_us: 0,
                lifetime_us: 500000,
                body,
            },
            now,
        )
    }
    pub fn queue_access_unit(
        &mut self,
        record: wire::Record,
        read_started: u64,
        now: u64,
    ) -> Result<(), Failure> {
        self.queue_access_unit_with_lifetime(record, read_started, now, AU_LIFETIME)
    }
    // The longer source budget is selected only after source_event's complete
    // codec qualification. Legacy direct callers keep their original budget.
    fn queue_access_unit_with_lifetime(
        &mut self,
        record: wire::Record,
        read_started: u64,
        now: u64,
        lifetime: u64,
    ) -> Result<(), Failure> {
        self.tick(now)?;
        if read_started > now {
            return Err(Failure::Clock);
        }
        if read_started.checked_add(lifetime).is_none_or(|d| now >= d) {
            return Err(Failure::Deadline);
        }
        if record.generation != self.transactions.context.generation {
            return Err(Failure::Protocol);
        }
        self.cache
            .insert_with_lifetime(record, read_started, lifetime)
    }
    /// Drop sender-owned video after a proven datagram expiry and suppress only
    /// progress metadata that has not crossed the transport boundary. A
    /// receiver must never observe a watermark for payload intentionally
    /// removed here. Already accepted metadata remains transport-owned.
    pub fn discard_source_video_for_recovery(&mut self, lost_sequence: u64) -> Option<u64> {
        let retained = self
            .cache
            .discard_video_before_recovery_key(self.transactions.context.generation, lost_sequence);
        if retained.is_none() || self.sources[0].watermark < retained.unwrap() {
            self.sources[0].watermark_due = None;
        }
        self.transactions
            .cancel_unaccepted_watermarks_before(1, retained);
        retained
    }
    /// Drop one dependent AU while sender-local recovery is active. The stock
    /// sequence continues advancing, but its pending watermark is canceled
    /// when it describes this deliberately absent payload.
    pub fn discard_source_video_sequence_for_recovery(&mut self, generation: u64, sequence: u64) {
        self.cache.discard_video_sequence(generation, sequence);
        if generation == self.transactions.context.generation
            && self.sources[0].watermark == sequence
        {
            self.sources[0].watermark_due = None;
        }
        self.transactions.cancel_unaccepted_watermarks(1);
    }
    /// Promote only the exact independently decodable AU produced for the
    /// current recovery request.  The backend proves that association through
    /// its producer-bound request map before calling this seam.
    pub fn mark_source_video_sequence_as_reliable_recovery(
        &mut self,
        generation: u64,
        sequence: u64,
    ) -> Result<(), Failure> {
        self.cache.mark_reliable_recovery(generation, sequence)
    }
    /// Exact selected recovery IDR that still awaits the receiver's consumer
    /// ACK. The source owner uses this as a cross-lane ordering fence.
    pub fn source_reliable_recovery_fence(&self) -> Option<u64> {
        self.cache
            .reliable_recovery_fence(self.transactions.context.generation)
    }
    pub fn set_receiver_repair_margin(&mut self, margin: Option<u64>) {
        self.receiver.set_repair_margin(margin);
    }
    pub fn ingest(
        &mut self,
        received: galaxybridge_quic::Received,
        now: u64,
        rtt_margin: Option<u64>,
    ) -> Result<(), Failure> {
        self.set_receiver_repair_margin(rtt_margin);
        self.tick(now)?;
        let result = (|| {
            let r = wire::Record::decode(received.lane, &received.payload)
                .map_err(|_| Failure::Protocol)?;
            if r.generation != self.transactions.context.generation {
                return Err(Failure::Protocol);
            }
            match r.kind {
                10 | 14 => self.transactions.ingest_ack(r, now),
                6 => self.cache.request(&r, now, rtt_margin),
                7 => self.cache.ack(&r),
                _ => self.receiver.ingest_classified(r, now).map(|outcome| {
                    // Media-only declines consume this validated record, not
                    // the transport or subsequent reliable control records.
                    match outcome {
                        media::MediaOutcome::Admitted
                        | media::MediaOutcome::DeclinedPressure
                        | media::MediaOutcome::DeclinedExpired
                        | media::MediaOutcome::SkippedDependent => (),
                    }
                }),
            }
        })();
        if let Err(e) = result {
            self.retire(e)
        }
        result
    }
    pub fn tick(&mut self, now: u64) -> Result<(), Failure> {
        if self.deferred_stock.as_ref().is_some_and(|d| {
            d.started
                .checked_add(AU_LIFETIME)
                .is_none_or(|cutoff| now >= cutoff)
        }) {
            media::first_error::stage(line!());
            self.retire(Failure::Deadline);
            return Err(Failure::Deadline);
        }
        self.transactions.tick(now);
        let receiver = self.receiver.tick(now);
        self.cache.expire(now);
        self.input.expire(now);
        if let Some(e) = self.transactions.terminal() {
            media::first_error::stage(line!());
            self.retire(e);
            return Err(e);
        }
        if let Err(e) = receiver {
            media::first_error::stage(line!());
            self.retire(e);
            return Err(e);
        }
        for i in 0..2 {
            let s = &mut self.sources[i];
            if s.reader.deadline().is_some_and(|d| now >= d) {
                media::first_error::stage(line!());
                self.retire(Failure::Deadline);
                return Err(Failure::Deadline);
            }
            if s.watermark_due.is_some_and(|d| now >= d) {
                let r = wire::Record {
                    kind: 13,
                    track: (i + 1) as u8,
                    flags: 0,
                    generation: self.transactions.context.generation,
                    epoch: s.epoch,
                    config: s.version,
                    sequence: s.watermark,
                    pts: 0,
                    total: 0,
                    index: 0,
                    count: 0,
                    age_us: 0,
                    lifetime_us: 500000,
                    body: vec![],
                };
                if let Err(e) = self.transactions.queue_watermark(r, now) {
                    self.retire(e);
                    return Err(e);
                }
                s.watermark_due = None;
            }
        }
        Ok(())
    }
    pub fn next_transport_record(&mut self, now: u64, allow_transaction: bool) -> Option<Dispatch> {
        self.next_transport_record_with_policy(
            now,
            DispatchPolicy {
                feedback: allow_transaction,
                metadata: allow_transaction,
                critical_through: if allow_transaction { None } else { Some(0) },
                moves: true,
                media: true,
            },
        )
    }
    pub fn next_transport_record_with_policy(
        &mut self,
        now: u64,
        policy: DispatchPolicy,
    ) -> Option<Dispatch> {
        self.tick(now).ok()?;
        if self.pending.is_some() {
            return None;
        }
        let item = if let Some(r) = if policy.feedback {
            self.receiver.next_feedback(now)
        } else {
            None
        } {
            let deadline = self.receiver.feedback_deadline()?;
            Some((r, deadline, OwnerPending::Feedback))
        } else {
            self.transactions
                .next_transport_record_with_policy(now, policy)
                .map(|d| {
                    (
                        wire::Record::decode(d.message.lane, &d.message.payload)
                            .expect("Core-generated record"),
                        d.deadline,
                        OwnerPending::Transaction(d.record_token),
                    )
                })
        };
        let (r, deadline, kind) = item
            .or_else(|| {
                if !policy.moves {
                    return None;
                }
                self.input
                    .next(now)
                    .map(|(r, d)| (r.clone(), d, OwnerPending::Move(r)))
            })
            .or_else(|| {
                if !policy.media {
                    return None;
                }
                self.cache
                    .next(now)
                    .map(|(r, d, repair)| (r.clone(), d, OwnerPending::Media(r, repair)))
            })?;
        self.serial = self.serial.checked_add(1)?;
        let record_token = self.serial;
        let dispatch = Dispatch {
            record_token,
            message: Message {
                lane: r.lane(),
                sequence: record_token,
                payload: r.encode().ok()?,
            },
            deadline,
            media_repair: matches!(&kind, OwnerPending::Media(_, true)),
        };
        self.pending = Some((record_token, kind));
        Some(dispatch)
    }
    pub fn transport_admission(
        &mut self,
        token: u64,
        admission: Admission,
        now: u64,
    ) -> Result<(), Failure> {
        let (expected, kind) = self.pending.take().ok_or(Failure::Protocol)?;
        if expected != token {
            self.pending = Some((expected, kind));
            return Err(Failure::Protocol);
        }
        match kind {
            OwnerPending::Transaction(t) => {
                if let Err(e) = self.transactions.transport_admission(t, admission, now) {
                    self.retire(e);
                    return Err(e);
                }
            }
            OwnerPending::Feedback => {
                if admission == Admission::Accepted {
                    self.receiver.feedback_accepted()
                }
            }
            OwnerPending::Media(r, repair) => {
                if admission == Admission::Accepted {
                    self.cache.accepted(&r, repair)?
                }
            }
            OwnerPending::Move(r) => {
                if admission == Admission::Accepted {
                    self.input.accepted(&r)
                }
            }
        }
        if matches!(admission, Admission::TooLarge | Admission::Retired) {
            self.retire(Failure::Retired)
        }
        self.tick(now)
    }
    pub fn next_wakeup(&self) -> Option<u64> {
        self.transactions
            .next_wakeup()
            .into_iter()
            .chain(self.receiver.next_wakeup())
            .chain(self.cache.next_wakeup())
            .chain(self.input.next_wakeup())
            .chain(self.sources.iter().filter_map(|s| s.reader.deadline()))
            .chain(self.sources.iter().filter_map(|s| s.watermark_due))
            .chain(
                self.deferred_stock
                    .as_ref()
                    .and_then(|d| d.started.checked_add(AU_LIFETIME)),
            )
            .min()
    }
    pub fn retire(&mut self, reason: Failure) {
        self.transactions.retire(reason);
        self.receiver.retire(reason);
        self.cache.clear();
        self.input.clear();
        self.pending = None;
        self.sources = [stock::Source::new(true), stock::Source::new(false)];
        self.active_stock = None;
        self.deferred_stock = None;
    }
}

/// The only transport adapter: owns one unchanged authenticated G0 Endpoint.
/// A send and its admission callback execute synchronously without consumer I/O.
pub struct Driver {
    pub owner: Owner,
    endpoint: galaxybridge_quic::Endpoint,
    origin: std::time::Instant,
}
impl Driver {
    pub fn new(
        owner: Owner,
        endpoint: galaxybridge_quic::Endpoint,
        origin: std::time::Instant,
    ) -> Self {
        Self {
            owner,
            endpoint,
            origin,
        }
    }
    pub fn now(&self) -> Result<u64, Failure> {
        self.origin
            .elapsed()
            .as_nanos()
            .try_into()
            .map_err(|_| Failure::Clock)
    }
    pub fn ready(&self) -> bool {
        self.endpoint.stats().application_ready
    }
    pub fn transport_stats(&self) -> galaxybridge_quic::Stats {
        self.endpoint.stats()
    }
    pub fn poll(&mut self) -> Result<(), Failure> {
        let result = self.service();
        if let Err(e) = result {
            self.retire(e)
        }
        result
    }
    fn service(&mut self) -> Result<(), Failure> {
        self.service_filter(&mut |_| true)
    }
    /// Synthetic fixture ingress-loss seam, after authenticated G0 receive.
    /// Returning false discards that record; it does not falsify transport admission.
    pub fn poll_filtered(
        &mut self,
        keep: &mut impl FnMut(&galaxybridge_quic::Received) -> bool,
    ) -> Result<(), Failure> {
        let result = self.service_filter(keep);
        if let Err(e) = result {
            self.retire(e)
        }
        result
    }
    fn service_filter(
        &mut self,
        keep: &mut impl FnMut(&galaxybridge_quic::Received) -> bool,
    ) -> Result<(), Failure> {
        let margin = |p: galaxybridge_quic::endpoint::PathObservation| {
            if p.valid && p.available && p.rtt_available {
                p.rttvar_ns
                    .checked_mul(4)
                    .and_then(|v| p.rtt_ns.checked_add(v))
                    .filter(|m| *m > 0)
            } else {
                None
            }
        };
        self.owner
            .set_receiver_repair_margin(margin(self.endpoint.stats().path));
        self.owner.tick(self.now()?)?;
        self.endpoint.poll().map_err(|_| Failure::Retired)?;
        if self.endpoint.stats().retired {
            return Err(Failure::Retired);
        }
        let margin = margin(self.endpoint.stats().path);
        self.owner.set_receiver_repair_margin(margin);
        for _ in 0..32 {
            let Some(r) = self.endpoint.receive() else {
                break;
            };
            if keep(&r) {
                self.owner.ingest(r, self.now()?, margin)?;
            }
        }
        if !self.ready() {
            return Ok(());
        }
        let mut requests = 0;
        for _ in 0..32 {
            let Some(d) = self.owner.next_transport_record(self.now()?, requests < 4) else {
                break;
            };
            let reliable = d.message.lane == galaxybridge_quic::Lane::Reliable;
            let deadline = self
                .origin
                .checked_add(std::time::Duration::from_nanos(d.deadline))
                .ok_or(Failure::Clock)?;
            let admission = self.endpoint.send(d.message, deadline);
            self.owner
                .transport_admission(d.record_token, admission, self.now()?)?;
            if reliable {
                requests += 1
            }
            if admission == Admission::Backpressured {
                break;
            }
        }
        Ok(())
    }
    pub fn next_wakeup(&self) -> std::time::Duration {
        let transport = self.endpoint.next_wakeup();
        let now = self.now().unwrap_or(u64::MAX);
        self.owner.next_wakeup().map_or(transport, |d| {
            transport.min(std::time::Duration::from_nanos(d.saturating_sub(now)))
        })
    }
    pub fn retire(&mut self, reason: Failure) {
        self.owner.retire(reason);
        self.endpoint.close();
    }
}
impl Drop for Driver {
    fn drop(&mut self) {
        self.retire(Failure::Retired)
    }
}
impl Core {
    fn queue_transaction_received(
        &mut self,
        record: wire::Record,
        received: u64,
        now: u64,
    ) -> Result<u64, Failure> {
        record.validate().map_err(|_| Failure::Protocol)?;
        self.queue_object_received(record, received, now)
    }
    pub fn new(context: Context, now: u64) -> Result<Self, Failure> {
        Self::with_pool(context, now, media::Pool::new(64, 256 * 1024))
    }
    fn with_pool(context: Context, now: u64, meta_pool: media::Pool) -> Result<Self, Failure> {
        if context.generation == 0
            || context.target_token == 0
            || context.capture_kind > 1
            || context.enabled == 0
            || context.enabled & !(7 | FEATURE_XOR_PARITY) != 0
            || context.capture_kind == 1 && context.display_id != u32::MAX
        {
            return Err(Failure::Protocol);
        }
        Ok(Self {
            context,
            transactions: VecDeque::new(),
            pending: None,
            serial: 0,
            last: now,
            terminal: None,
            metadata_acks: [[None; 15]; 3],
            expired_watermarks: [None; 3],
            critical_acked: 0,
            critical_queued: 0,
            meta_pool,
            critical_pool: media::Pool::new(64, 64 * 1024),
        })
    }
    fn token(&mut self) -> Result<u64, Failure> {
        self.serial = self.serial.checked_add(1).ok_or(Failure::Capacity)?;
        Ok(self.serial)
    }
    pub fn terminal(&self) -> Option<Failure> {
        self.terminal
    }
    pub fn context(&self) -> &Context {
        &self.context
    }
    fn live(&mut self, now: u64) -> Result<(), Failure> {
        self.tick(now);
        self.terminal.map_or(Ok(()), Err)
    }
    pub fn queue_transaction(&mut self, record: wire::Record, now: u64) -> Result<u64, Failure> {
        record.validate().map_err(|_| Failure::Protocol)?;
        self.queue_object(record, now)
    }
    fn live_watermark(&self, track: u8) -> bool {
        self.transactions
            .iter()
            .any(|t| t.record.kind == 13 && t.record.track == track && t.result.is_none())
    }
    fn cancel_unaccepted_watermarks(&mut self, track: u8) {
        self.cancel_unaccepted_watermarks_before(track, None);
    }
    fn cancel_unaccepted_watermarks_before(&mut self, track: u8, retain_from: Option<u64>) {
        let pending = self.pending.as_ref().map(|pending| pending.transaction);
        for transaction in &mut self.transactions {
            if transaction.record.kind == 13
                && transaction.record.track == track
                && transaction.result.is_none()
                && !transaction.accepted
                && pending != Some(transaction.token)
                && retain_from.is_none_or(|sequence| transaction.record.sequence < sequence)
            {
                transaction.result = Some(Outcome::SupersededBeforeDispatch);
            }
        }
    }
    pub fn queue_watermark(&mut self, record: wire::Record, now: u64) -> Result<u64, Failure> {
        self.live(now)?;
        record.validate().map_err(|_| Failure::Protocol)?;
        if record.kind != 13 {
            return Err(Failure::Protocol);
        }
        let old = self.transactions.iter().position(|t| {
            t.record.kind == 13
                && t.record.track == record.track
                && t.result.is_none()
                && !t.accepted
                && !self
                    .pending
                    .as_ref()
                    .is_some_and(|p| p.transaction == t.token)
        });
        let mut original = None;
        if let Some(i) = old {
            let t = &mut self.transactions[i];
            if t.record.epoch != record.epoch
                || t.record.config != record.config
                || record.sequence <= t.record.sequence
            {
                return Err(Failure::Protocol);
            }
            original = Some((t.queued, t.deadline));
            t.result = Some(Outcome::SupersededBeforeDispatch);
        }
        let token = self.queue_object(record, now)?;
        if let Some((queued, deadline)) = original {
            let t = self.transactions.back_mut().unwrap();
            t.queued = queued;
            t.deadline = deadline;
        }
        Ok(token)
    }
    /// A complete logical metadata/critical object. Fragmentation is lazy; bytes remain owned here.
    pub fn queue_object(&mut self, record: wire::Record, now: u64) -> Result<u64, Failure> {
        self.queue_object_received(record, now, now)
    }
    fn queue_object_received(
        &mut self,
        mut record: wire::Record,
        received: u64,
        now: u64,
    ) -> Result<u64, Failure> {
        let deadline = original_deadline(received, now)?;
        self.live(now)?;
        if !matches!(record.kind, 1..=4 | 8 | 12 | 13)
            || record.generation != self.context.generation
        {
            media::first_error::reject(2, line!(), 0, 0, 0, 0, 0);
            return Err(Failure::Protocol);
        }
        let critical = record.kind == 8;
        let count = self
            .transactions
            .iter()
            .filter(|t| (t.record.kind == 8) == critical)
            .count();
        let bytes: usize = self
            .transactions
            .iter()
            .filter(|t| (t.record.kind == 8) == critical)
            .map(|t| t.bytes.len())
            .sum();
        let cap: usize = if critical { 64 * 1024 } else { 256 * 1024 };
        if critical {
            if record.body.len() < 36 {
                return Err(Failure::Protocol);
            }
            control::validate(record.body[0], &record.body[36..])?;
        }
        let release = critical
            && (matches!(record.body[0], 2 | 3)
                || record.body[0] == 4 && record.body[37] == 1
                || record.body[0] == 5 && record.body[36] == 14);
        if count
            >= if critical {
                if release {
                    64
                } else {
                    48
                }
            } else {
                16
            }
            || record.body.len() > cap.saturating_sub(bytes)
        {
            media::first_error::reject(
                2,
                line!(),
                count,
                if critical {
                    if release {
                        64
                    } else {
                        48
                    }
                } else {
                    16
                },
                record.body.len(),
                bytes,
                cap,
            );
            if release || !critical {
                self.retire(Failure::Capacity)
            }
            return Err(Failure::Capacity);
        }
        if critical {
            if record.sequence
                != self
                    .critical_queued
                    .checked_add(1)
                    .ok_or(Failure::Capacity)?
            {
                return Err(Failure::Protocol);
            }
        }
        if self
            .transactions
            .iter()
            .any(|t| Key::of(&t.record) == Key::of(&record))
        {
            return Err(Failure::Protocol);
        }
        if record.kind == 1 {
            let b = &record.body;
            let c = &self.context;
            if b.len() != 20
                || wire::u32_at(b, 0) != c.scid
                || b[4] != c.capture_kind
                || b[5] != c.enabled
                || wire::u32_at(b, 8) != c.display_id
                || wire::u64_at(b, 12) != c.target_token
            {
                return Err(Failure::Protocol);
            }
        }
        if record.kind == 4 {
            if record.body.is_empty() || record.body.len() > wire::SMALL_OBJECT {
                media::first_error::reject(
                    2,
                    line!(),
                    0,
                    0,
                    record.body.len(),
                    0,
                    wire::SMALL_OBJECT,
                );
                return Err(Failure::Capacity);
            }
            record.total = record.body.len() as u32;
            record.count = record.body.len().div_ceil(wire::BODY) as u16;
            record.index = 0;
            let first = record.with_body(record.body[..record.body.len().min(wire::BODY)].to_vec());
            first.validate().map_err(|_| Failure::Protocol)?;
        } else {
            record.validate().map_err(|_| Failure::Protocol)?;
        }
        let allocation = if critical {
            self.critical_pool
                .allocate(std::mem::take(&mut record.body))
        } else if record.kind == 4 {
            self.meta_pool
                .allocate_configuration(record.track, std::mem::take(&mut record.body))
        } else {
            self.meta_pool.allocate(std::mem::take(&mut record.body))
        };
        let bytes = match allocation {
            Ok(bytes) => bytes,
            Err(e) => {
                if release || !critical {
                    self.retire(e)
                }
                return Err(e);
            }
        };
        let token = self.token()?;
        if critical {
            self.critical_queued = record.sequence;
        }
        self.transactions.push_back(Transaction {
            token,
            record,
            bytes,
            queued: received,
            deadline,
            next: 0,
            accepted: false,
            result: None,
        });
        Ok(token)
    }
    pub fn next_transport_record(&mut self, now: u64) -> Option<Dispatch> {
        self.next_transport_record_with_policy(now, DispatchPolicy::default())
    }
    fn next_transport_record_with_policy(
        &mut self,
        now: u64,
        policy: DispatchPolicy,
    ) -> Option<Dispatch> {
        self.live(now).ok()?;
        if self.pending.is_some() {
            return None;
        }
        let pos = self.transactions.iter().position(|t| {
            t.result.is_none()
                && if t.record.kind == 8 {
                    policy
                        .critical_through
                        .is_none_or(|limit| t.record.sequence <= limit)
                } else {
                    policy.metadata
                }
                && t.next < t.record.count.max(1)
                && !(t.record.kind == 13
                    && self.transactions.iter().any(|old| {
                        old.record.kind == 13
                            && old.record.track == t.record.track
                            && old.accepted
                            && old.result.is_none()
                    }))
        })?;
        let record_token = self.token().ok()?;
        let t = &self.transactions[pos];
        let start = if t.record.kind == 4 {
            t.next as usize * wire::BODY
        } else {
            0
        };
        let mut record = t
            .record
            .with_body(t.bytes.as_slice()[start..(start + wire::BODY).min(t.bytes.len())].to_vec());
        if record.kind == 4 {
            record.index = t.next;
        }
        record.age_us = (now - t.queued).div_ceil(1000).try_into().ok()?;
        let payload = match record.encode() {
            Ok(b) => b,
            Err(_) => {
                self.retire(Failure::Deadline);
                return None;
            }
        };
        let dispatch = Dispatch {
            record_token,
            message: Message {
                lane: record.lane(),
                sequence: record_token,
                payload,
            },
            deadline: t.deadline,
            media_repair: false,
        };
        self.pending = Some(Pending {
            record_token,
            transaction: t.token,
        });
        Some(dispatch)
    }
    pub fn transport_admission(
        &mut self,
        token: u64,
        admission: Admission,
        now: u64,
    ) -> Result<(), Failure> {
        let p = self.pending.take().ok_or(Failure::Protocol)?;
        if p.record_token != token {
            self.pending = Some(p);
            return Err(Failure::Protocol);
        }
        let t = self
            .transactions
            .iter_mut()
            .find(|t| t.token == p.transaction)
            .ok_or(Failure::Protocol)?;
        if admission == Admission::Accepted {
            t.accepted = true;
            t.next = t.next.checked_add(1).ok_or(Failure::Capacity)?;
            if t.record.kind == 8
                && !(t.bytes.len() == 38
                    && t.bytes.as_slice()[0] == control::Class::Ordinary as u8
                    && t.bytes.as_slice()[36] == 8)
            {
                t.deadline = t
                    .queued
                    .checked_add(RELIABLE_CONTROL_ACK_LIFETIME)
                    .ok_or(Failure::Clock)?;
            }
        }
        self.live(now)?;
        match admission {
            Admission::Accepted | Admission::Backpressured => Ok(()),
            Admission::Expired => {
                self.retire(Failure::Deadline);
                Err(Failure::Deadline)
            }
            Admission::TooLarge => {
                self.retire(Failure::Protocol);
                Err(Failure::Protocol)
            }
            Admission::Retired => {
                self.retire(Failure::Retired);
                Err(Failure::Retired)
            }
        }
    }
    pub fn ingest_ack(&mut self, record: wire::Record, now: u64) -> Result<(), Failure> {
        let result = self.ingest_ack_inner(record, now);
        if let Err(e) = result {
            self.retire(e)
        }
        result
    }
    fn ingest_ack_inner(&mut self, record: wire::Record, now: u64) -> Result<(), Failure> {
        self.live(now)?;
        record.validate().map_err(|_| Failure::Protocol)?;
        if record.generation != self.context.generation {
            return Err(Failure::Protocol);
        }
        if record.kind == 10 {
            if record.sequence <= self.critical_acked {
                return Ok(());
            }
            let valid = self.transactions.iter().any(|t| {
                t.record.kind == 8
                    && t.record.sequence == record.sequence
                    && t.record.epoch == record.epoch
                    && t.accepted
                    && t.next == 1
            });
            if !valid {
                self.retire(Failure::Protocol);
                return Err(Failure::Protocol);
            }
            for t in &mut self.transactions {
                if t.record.kind == 8 && t.record.sequence <= record.sequence && t.result.is_none()
                {
                    if !t.accepted || t.next != 1 {
                        self.retire(Failure::Protocol);
                        return Err(Failure::Protocol);
                    }
                    t.result = Some(Outcome::PeerBoundaryConfirmed(Confirmation::StockSinkWrite));
                }
            }
            self.critical_acked = record.sequence;
            return Ok(());
        }
        if record.kind != 14 {
            return Err(Failure::Protocol);
        }
        let mut key = Key::of(&record);
        key.kind = record.body[0];
        if self.metadata_acks[key.track as usize][key.kind as usize].is_some_and(|old| key <= old) {
            return Ok(());
        }
        if key.kind == 13
            && self.expired_watermarks[key.track as usize].is_some_and(|expired| key <= expired)
        {
            return Ok(());
        }
        let t = self
            .transactions
            .iter_mut()
            .find(|t| Key::of(&t.record) == key)
            .ok_or(Failure::Protocol)?;
        if !t.accepted || t.next < t.record.count.max(1) {
            self.retire(Failure::Protocol);
            return Err(Failure::Protocol);
        }
        if t.result.is_none() {
            t.result = Some(Outcome::PeerBoundaryConfirmed(Confirmation::MetadataCommit));
        }
        self.metadata_acks[key.track as usize][key.kind as usize] = Some(key);
        if key.kind == 13 {
            self.expired_watermarks[key.track as usize] = None;
        }
        Ok(())
    }
    pub fn tick(&mut self, now: u64) {
        if self.terminal.is_some() {
            return;
        }
        if now < self.last {
            self.retire(Failure::Clock);
            return;
        }
        self.last = now;
        let pending = self.pending.as_ref().map(|pending| pending.transaction);
        for t in &mut self.transactions {
            if t.result.is_none() && now >= t.deadline && t.record.kind == 13 {
                if t.accepted && t.next >= t.record.count.max(1) {
                    let key = Key::of(&t.record);
                    let expired = &mut self.expired_watermarks[key.track as usize];
                    if expired.is_none_or(|old| key > old) {
                        *expired = Some(key);
                    }
                    // A watermark is supersedable feedback, not session-critical
                    // state. Once the transport accepted the whole record, a lost
                    // metadata ACK only makes its remote outcome unknown. A newer
                    // watermark can safely replace it without recreating capture.
                    t.result = Some(Outcome::UnknownRemoteOutcome(Failure::Deadline));
                } else if !t.accepted && pending != Some(t.token) {
                    // A source watermark carries only a progress observation. If
                    // QUIC never admitted it, the peer cannot have observed it and
                    // no media or control ownership is ambiguous. Under sustained
                    // motion a brief reliable-stream backpressure window must drop
                    // this stale observation instead of retiring the live capture.
                    // Configuration and input transactions remain strict below.
                    t.result = Some(Outcome::NotDispatched(Failure::Deadline));
                }
            }
        }
        // GET_CLIPBOARD is a periodic, idempotent observation.  The command is
        // carried by the ordered reliable input stream, but its cumulative
        // application acknowledgement can arrive after the 500 ms transaction
        // budget while video is moving.  Once QUIC accepted the complete
        // command, an unknown GET result must not tear down an otherwise live
        // screen session.  Advance the local cumulative floor so the eventual
        // late ACK is harmless.  No mutating command (including pointer/key
        // press or release) is permitted through this path.
        loop {
            let Some(sequence) = self.critical_acked.checked_add(1) else {
                break;
            };
            let Some(index) = self.transactions.iter().position(|t| {
                t.result.is_none()
                    && t.record.kind == 8
                    && t.record.sequence == sequence
                    && now >= t.deadline
            }) else {
                break;
            };
            let clipboard_read = {
                let t = &self.transactions[index];
                let body = t.bytes.as_slice();
                t.accepted
                    && t.next >= t.record.count.max(1)
                    && body.len() == 38
                    && body[0] == control::Class::Ordinary as u8
                    && body[36] == 8
                    && body[37] <= 2
            };
            if !clipboard_read {
                break;
            }
            self.transactions[index].result =
                Some(Outcome::UnknownRemoteOutcome(Failure::Deadline));
            self.critical_acked = sequence;
        }
        if let Some(t) = self
            .transactions
            .iter()
            .find(|t| t.result.is_none() && now >= t.deadline)
        {
            let body = t.bytes.as_slice();
            let class = body.first().copied().unwrap_or(0) as usize;
            let raw_type = body.get(36).copied().unwrap_or(0) as usize;
            // Private opt-in first-cause fields identify the exact reliable
            // record without retaining or emitting its payload: validated
            // control class, raw scrcpy type, sequence, bounded body length,
            // and accepted/complete bits. These scalars distinguish a periodic
            // read from a mutating input without exposing clipboard contents.
            media::first_error::reject(
                2,
                line!(),
                class,
                raw_type,
                t.record.sequence as usize,
                body.len(),
                (t.accepted as usize) | (((t.next >= t.record.count.max(1)) as usize) << 1),
            );
            self.retire(Failure::Deadline)
        }
    }
    pub fn next_wakeup(&self) -> Option<u64> {
        self.transactions
            .iter()
            .filter(|t| t.result.is_none())
            .map(|t| t.deadline)
            .min()
    }
    pub fn retire(&mut self, reason: Failure) {
        if self.terminal.is_some() {
            return;
        }
        self.terminal = Some(reason);
        for t in &mut self.transactions {
            if t.result.is_none() {
                t.result = Some(
                    if t.accepted
                        || self
                            .pending
                            .as_ref()
                            .is_some_and(|p| p.transaction == t.token)
                    {
                        Outcome::UnknownRemoteOutcome(reason)
                    } else {
                        Outcome::NotDispatched(reason)
                    },
                );
            }
        }
    }
    pub fn next_transaction_result(&mut self) -> Option<TransactionResult> {
        let pos = self.transactions.iter().position(|t| t.result.is_some())?;
        let t = self.transactions.remove(pos)?;
        Some(TransactionResult {
            token: t.token,
            outcome: t.result?,
        })
    }
}
