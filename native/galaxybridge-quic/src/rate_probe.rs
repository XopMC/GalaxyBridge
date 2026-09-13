//! Finite synthetic rate harness, separate from the ordinary echo probe.
mod schedule;
mod wire;
use crate::{Admission, Endpoint, Lane, Message, Received, Stats};
use schedule::{bin, bit, micros, quantiles, set_bit, Producer, BINS, BITMAP};
pub use schedule::{Bin, ClassCounts, Quantiles};
use std::{
    collections::VecDeque,
    time::{Duration, Instant},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RateShape {
    Constant,
    FrameBurst,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum RateVerdict {
    #[default]
    MeasurementIncomplete,
    Pass,
    DeliveryOrDeadlineFailure,
    TransportOrCleanupFailure,
    InvalidRecipe,
}
#[derive(Clone, Copy, Debug, Default)]
pub struct FailureFlags {
    pub transport: bool,
    pub recipe: bool,
    pub delivery: bool,
    pub measurement: bool,
}
impl FailureFlags {
    fn verdict(self) -> RateVerdict {
        if self.transport {
            RateVerdict::TransportOrCleanupFailure
        } else if self.recipe {
            RateVerdict::InvalidRecipe
        } else if self.delivery {
            RateVerdict::DeliveryOrDeadlineFailure
        } else if self.measurement {
            RateVerdict::MeasurementIncomplete
        } else {
            RateVerdict::Pass
        }
    }
}
#[derive(Clone, Copy, Debug, Default)]
pub struct QueuePeaks {
    pub reliable_bytes: usize,
    pub datagrams: usize,
    pub generated: usize,
    pub received: usize,
    pub received_bytes: usize,
}
impl QueuePeaks {
    fn sample(&mut self, s: Stats) {
        self.reliable_bytes = self.reliable_bytes.max(s.reliable_backlog_bytes);
        self.datagrams = self.datagrams.max(s.datagram_queue_records);
        self.generated = self.generated.max(s.generated_packets);
        self.received = self.received.max(s.receive_queue_records);
        self.received_bytes = self.received_bytes.max(s.receive_queue_bytes);
    }
    fn valid(self) -> bool {
        self.reliable_bytes <= 65536
            && self.datagrams <= 32
            && self.generated <= 32
            && self.received <= 64
            && self.received_bytes <= 65536
    }
}
#[derive(Clone, Debug)]
pub struct SourceReport {
    pub values: [u64; 48],
    pub bins: [Bin; BINS],
}
impl Default for SourceReport {
    fn default() -> Self {
        Self {
            values: [0; 48],
            bins: [Bin::default(); BINS],
        }
    }
}
#[derive(Clone, Debug)]
pub struct RateReport {
    pub shape: RateShape,
    pub verdict: RateVerdict,
    pub flags: FailureFlags,
    pub source: Option<SourceReport>,
    pub received: [u64; 2],
    pub duplicates: u64,
    pub malformed: u64,
    pub late: u64,
    pub pre_begin: u64,
    pub post_end: u64,
    pub probe_offered: u64,
    pub probe_admitted: u64,
    pub probe_received: u64,
    pub probe_late: u64,
    pub probe_inactive: u64,
    pub probe_duplicates: u64,
    pub credit_expired: u64,
    pub credit_blocked: u64,
    pub credit_peak: usize,
    pub backpressured: u64,
    pub admission_delay: Quantiles,
    pub rtt: Quantiles,
    pub response: Quantiles,
    pub largest_no_completion_us: u64,
    pub bins: [Bin; BINS],
    pub queues: QueuePeaks,
    pub bitmap_verified: bool,
    pub exchange_complete: bool,
    pub terminal: crate::bootstrap::ClientDiagnostic,
    pub elapsed_ms: u64,
    pub cleanup: bool,
    pub cleanup_forced: bool,
    pub endpoint_released: bool,
}
impl RateReport {
    pub(crate) fn new(shape: RateShape) -> Self {
        Self {
            shape,
            verdict: RateVerdict::MeasurementIncomplete,
            flags: FailureFlags::default(),
            source: None,
            received: [0; 2],
            duplicates: 0,
            malformed: 0,
            late: 0,
            pre_begin: 0,
            post_end: 0,
            probe_offered: 0,
            probe_admitted: 0,
            probe_received: 0,
            probe_late: 0,
            probe_inactive: 0,
            probe_duplicates: 0,
            credit_expired: 0,
            credit_blocked: 0,
            credit_peak: 0,
            backpressured: 0,
            admission_delay: Quantiles::default(),
            rtt: Quantiles::default(),
            response: Quantiles::default(),
            largest_no_completion_us: 0,
            bins: [Bin::default(); BINS],
            queues: QueuePeaks::default(),
            bitmap_verified: false,
            exchange_complete: false,
            terminal: crate::bootstrap::ClientDiagnostic::default(),
            elapsed_ms: 0,
            cleanup: false,
            cleanup_forced: false,
            endpoint_released: false,
        }
    }
    pub fn datagram_missing(&self) -> u64 {
        30_600 - self.received.iter().sum::<u64>().min(30_600)
    }
    pub fn probe_missing(&self) -> u64 {
        500 - self.probe_received.min(500)
    }
    pub(crate) fn conclude(&mut self) {
        self.flags.transport |= !self.cleanup || self.cleanup_forced || !self.endpoint_released;
        self.flags.delivery |= self.datagram_missing() > 0
            || self.probe_missing() > 0
            || self.duplicates
                + self.malformed
                + self.late
                + self.probe_late
                + self.probe_duplicates
                > 0;
        self.flags.recipe |= self.probe_inactive > 0 || !self.queues.valid();
        self.flags.measurement |=
            !self.bitmap_verified || !self.exchange_complete || self.source.is_none();
        self.flags.measurement |= self.probe_offered != 500
            || self.rtt.samples == 0
            || self.probe_admitted != 500
            || self.rtt.samples != self.probe_received
            || self.response.samples != self.probe_received
            || self.admission_delay.samples != self.probe_admitted;
        self.flags.delivery |=
            self.rtt.p95_us > 50_000 || self.rtt.p99_us > 100_000 || self.response.max_us > 200_000;
        if let Some(s) = &self.source {
            let v = &s.values;
            self.flags.recipe |= v[0] != 30_000 || v[7] != 600;
            for (base, total) in [(0, 30_000), (7, 600)] {
                self.flags.measurement |= v[base + 2] > v[base + 1] || v[base + 1] > v[base];
                self.flags.measurement |=
                    v[base + 2] + v[base + 3] + v[base + 4] + v[base + 5] + v[base + 6] != total;
                self.flags.delivery |= v[base + 3..base + 7].iter().any(|x| *x > 0);
            }
            let admitted = v[2] + v[9];
            let received = self.received.iter().sum::<u64>();
            self.flags.measurement |=
                admitted != v[21] || v[22] > admitted || v[23] > v[22] || received > v[23];
            self.flags.delivery |= admitted != 30_600
                || v[23] != 30_600
                || v[19] > 5_000
                || v[20] > 20_000
                || v[40] > 0;
            self.flags.measurement |= v[16] == 0
                || v[16] != v[1] + v[8]
                || (admitted == 30_600 && v[16] != 30_600)
                || v[36] < 12_200_000;
            self.flags.recipe |= v[36] > 15_000_000 || v[38..41].iter().any(|v| *v > 500);
            self.flags.measurement |= s.bins.iter().map(|b| b.offered).sum::<u64>() != 30_192_000
                || s.bins.iter().map(|b| b.admitted).sum::<u64>() != v[2] * 1000 + v[9] * 320
                || s.bins.iter().map(|b| b.control).sum::<u64>() != v[39]
                || self.bins.iter().map(|b| b.received).sum::<u64>()
                    != self.received[0] * 1000 + self.received[1] * 320
                || self.bins.iter().map(|b| b.control).sum::<u64>() != self.probe_received
                || v[38] != self.probe_admitted
                || v[39] != self.probe_received;
            self.flags.delivery |= v[29] > 0 || v[30] > 0;
            self.flags.recipe |= v[15] > 128
                || v[31] > 65536
                || v[32] > 32
                || v[33] > 32
                || v[34] > 64
                || v[35] > 65536;
            self.flags.transport |= v[37] & 1 != 0;
            self.flags.recipe |= v[37] & 2 != 0;
            self.flags.delivery |= v[37] & 4 != 0;
            self.flags.measurement |= v[37] & 8 != 0;
        }
        self.verdict = self.flags.verdict();
    }
    pub fn print_scalars(&self) {
        eprintln!("rate_verdict={:?} shape={:?} video_received={} audio_received={} datagram_missing={} probe_offered={} probe_admitted={} probe_received={} probe_missing={} duplicates={} malformed={} late={} pre_begin={} post_end={} probe_late={} probe_inactive={} probe_duplicates={} cleanup={} cleanup_forced={} elapsed_ms={} bitmap_verified={} exchange_complete={} transport_flag={} recipe_flag={} delivery_flag={} measurement_flag={}",self.verdict,self.shape,self.received[0],self.received[1],self.datagram_missing(),self.probe_offered,self.probe_admitted,self.probe_received,self.probe_missing(),self.duplicates,self.malformed,self.late,self.pre_begin,self.post_end,self.probe_late,self.probe_inactive,self.probe_duplicates,u8::from(self.cleanup),u8::from(self.cleanup_forced),self.elapsed_ms,u8::from(self.bitmap_verified),u8::from(self.exchange_complete),u8::from(self.flags.transport),u8::from(self.flags.recipe),u8::from(self.flags.delivery),u8::from(self.flags.measurement));
        eprintln!("rate_origin={:?} rate_error={:?} rate_errno={} credit_expired={} credit_blocked={} credit_peak={} control_backpressured={} largest_no_completion_us={} useful_video_bps=20000000 useful_audio_bps=128000 app_dg_bps=20617600 g0_dg_bps=21576400 load_ms=12000 active_budget_ms=15000 sent_class_attribution=unavailable queue_peaks=sampled",self.terminal.origin,self.terminal.error,self.terminal.errno,self.credit_expired,self.credit_blocked,self.credit_peak,self.backpressured,self.largest_no_completion_us);
        for (name, q) in [
            ("admission_delay", self.admission_delay),
            ("rtt", self.rtt),
            ("response", self.response),
        ] {
            if q.samples == 0 {
                eprintln!("metric={name} samples=0 p50_us=unavailable p95_us=unavailable p99_us=unavailable max_us=unavailable");
                continue;
            }
            eprintln!(
                "metric={} samples={} p50_us={} p95_us={} p99_us={} max_us={}",
                name, q.samples, q.p50_us, q.p95_us, q.p99_us, q.max_us
            );
        }
        if let Some(s) = &self.source {
            let v = &s.values;
            eprintln!("source_dg_received={} source_dg_rejected={} source_quic_received={} source_generic_rejected={} source_flags={} source_echo_offered={} source_echo_admitted={} source_echo_dropped={} source_sampled_reliable_bytes={} source_sampled_dg_queue={} source_sampled_generated_queue={} source_sampled_received_queue={} source_sampled_received_bytes={}",v[24],v[25],v[28],v[30],v[37],v[38],v[39],v[40],v[31],v[32],v[33],v[34],v[35]);
            let reconciled = v[21] >= v[23] && v[23] >= self.received.iter().sum::<u64>();
            if !reconciled {
                eprintln!(
                    "aggregate_reconciliation=unavailable not_written_valid=0 sent_missing_valid=0"
                );
            } else {
                eprintln!(
                    "aggregate_reconciliation=available not_written_valid=1 sent_missing_valid=1"
                );
            }
            eprintln!("source_report=present video_offered={} audio_offered={} video_attempted={} audio_attempted={} video_admitted={} audio_admitted={} video_overflow={} audio_overflow={} video_expired={} audio_expired={} video_rejected={} audio_rejected={} video_unfinished={} audio_unfinished={} actual_dg_sent={} dg_generated={} endpoint_dg_admitted={} not_written={} aggregate_sent_missing={} pending_peak={} source_backpressured={} jitter_samples={} jitter_p50_us={} jitter_p95_us={} jitter_p99_us={} jitter_max_us={} source_elapsed_us={} raw_udp_sent={} raw_udp_received={} generic_expired={}",v[0],v[7],v[1],v[8],v[2],v[9],v[3],v[10],v[4],v[11],v[5],v[12],v[6],v[13],v[23],v[22],v[21],observed(v[21].checked_sub(v[23])),observed(v[23].checked_sub(self.received.iter().sum())),v[15],v[14],v[16],observed((v[16]>0).then_some(v[17])),observed((v[16]>0).then_some(v[18])),observed((v[16]>0).then_some(v[19])),observed((v[16]>0).then_some(v[20])),v[36],v[26],v[27],v[29]);
            for (i, b) in s.bins.iter().enumerate() {
                eprintln!("rate_source_bin={} offered_bytes={} admitted_bytes={} received_bytes={} control={}",i,b.offered,b.admitted,b.received,b.control);
            }
        } else {
            eprintln!("source_report=unavailable actual_dg_sent=unavailable");
        }
        for (i, b) in self.bins.iter().enumerate() {
            eprintln!("rate_client_bin={} offered_bytes={} admitted_bytes={} received_bytes={} control={}",i,b.offered,b.admitted,b.received,b.control);
        }
        eprintln!("endpoint_released={} client_sampled_reliable_bytes={} client_sampled_dg_queue={} client_sampled_generated_queue={} client_sampled_received_queue={} client_sampled_received_bytes={}",u8::from(self.endpoint_released),self.queues.reliable_bytes,self.queues.datagrams,self.queues.generated,self.queues.received,self.queues.received_bytes);
    }
}
fn observed(value: Option<u64>) -> String {
    value
        .map(|v| v.to_string())
        .unwrap_or_else(|| "unavailable".into())
}
#[derive(Clone, Debug)]
pub struct RateFailure {
    pub stage: crate::bootstrap::ClientStage,
    pub report: RateReport,
}

#[derive(Clone, Copy, Default)]
struct Sample {
    offered: bool,
    missed: bool,
    admitted: Option<u64>,
    echo: Option<u64>,
    expired: bool,
}
pub(crate) struct RateClient {
    report: RateReport,
    started: Instant,
    begin: Option<Instant>,
    end: Option<Instant>,
    seen: [u8; BITMAP],
    source_bitmap: [u8; BITMAP],
    samples: [Sample; 500],
    next_probe: usize,
    next_send: u64,
    next_receive: u64,
    recipe_sent: bool,
    summary_seen: bool,
    bitmap_chunks: usize,
    bin_chunks: usize,
    ack_sent: bool,
    ack_received: bool,
    exchange_expired: bool,
    last_completion_ns: u64,
}
impl RateClient {
    pub(crate) fn new(shape: RateShape, now: Instant) -> Self {
        Self {
            report: RateReport::new(shape),
            started: now,
            begin: None,
            end: None,
            seen: [0; BITMAP],
            source_bitmap: [0; BITMAP],
            samples: [Sample::default(); 500],
            next_probe: 0,
            next_send: 0,
            next_receive: 0,
            recipe_sent: false,
            summary_seen: false,
            bitmap_chunks: 0,
            bin_chunks: 0,
            ack_sent: false,
            ack_received: false,
            exchange_expired: false,
            last_completion_ns: 0,
        }
    }
    #[cfg(test)]
    fn received(&mut self, record: Received, now: Instant) {
        self.received_timed(record, now, &mut || now);
    }
    fn received_timed(
        &mut self,
        record: Received,
        now: Instant,
        clock: &mut impl FnMut() -> Instant,
    ) {
        if self.expired_at(now) {
            return;
        }
        let shape = self.report.shape;
        if record.lane == Lane::Datagram {
            match wire::parse_data(shape, record.sequence, &record.payload) {
                Err(_) => {
                    self.report.malformed += 1;
                    self.report.flags.delivery = true;
                }
                Ok(s) => {
                    if bit(&self.seen, s.sequence) {
                        self.report.duplicates += 1;
                        return;
                    }
                    if self
                        .end
                        .is_some_and(|end| now >= end + Duration::from_millis(200))
                    {
                        self.report.late += 1;
                        return;
                    }
                    set_bit(&mut self.seen, s.sequence);
                    self.report.received[s.kind as usize - 1] += 1;
                    if self.begin.is_none() {
                        self.report.pre_begin += 1;
                    }
                    if self.end.is_some() {
                        self.report.post_end += 1;
                    }
                    self.report.bins[bin(self.begin.map(|b| ns(now, b)).unwrap_or(0))].received +=
                        s.useful();
                }
            }
            return;
        }
        if record.sequence != self.next_receive {
            self.report.flags.recipe = true;
            return;
        }
        self.next_receive += 1;
        if let Ok((kind, id, active)) = wire::parse_control(shape, &record.payload) {
            match kind {
                2 if self.begin.is_none()
                    && self.end.is_none()
                    && ns(now, self.started) < 1_000_000_000 =>
                {
                    self.begin = Some(now);
                }
                3 if self.begin.is_some() && self.end.is_none() => {
                    self.end = Some(now);
                    if self.next_probe != 500 {
                        self.report.flags.recipe = true;
                    }
                }
                5 if self.begin.is_some() => {
                    let elapsed = ns(now, self.begin.unwrap());
                    let sample = &mut self.samples[id as usize];
                    if sample.admitted.is_none() {
                        self.report.flags.recipe = true;
                        return;
                    }
                    if sample.echo.is_some() {
                        self.report.probe_duplicates += 1;
                        return;
                    }
                    sample.echo = Some(elapsed);
                    self.report.probe_received += 1;
                    let due = 500_000_000 + id as u64 * 20_000_000;
                    if elapsed > due + 200_000_000 {
                        self.report.probe_late += 1;
                    }
                    if !active {
                        self.report.probe_inactive += 1;
                    }
                    self.report.bins[bin(elapsed)].control += 1;
                    self.report.largest_no_completion_us =
                        self.report.largest_no_completion_us.max(micros(
                            elapsed.saturating_sub(self.last_completion_ns.max(500_000_000)),
                        ) as u64);
                    self.last_completion_ns = elapsed;
                }
                6 if self.ack_sent && !self.ack_received => {
                    // Parse/dispatch may itself straddle the immutable cutoff.
                    if !self.expired_at(clock()) {
                        self.ack_received = true;
                    }
                }
                _ => self.report.flags.recipe = true,
            }
            return;
        }
        let Ok((kind, index, body)) = wire::parse_chunk(shape, &record.payload) else {
            self.report.flags.recipe = true;
            return;
        };
        if self.end.is_none() {
            self.report.flags.recipe = true;
            return;
        }
        match kind {
            7 if !self.summary_seen => {
                let mut source = SourceReport::default();
                for (out, chunk) in source.values.iter_mut().zip(body.chunks_exact(8)) {
                    *out = u64::from_be_bytes(chunk.try_into().unwrap());
                }
                let v = &source.values;
                if v[..14].iter().any(|x| *x > 30_600)
                    || v[37] > 15
                    || v[41..].iter().any(|x| *x != 0)
                {
                    self.report.flags.recipe = true;
                    return;
                }
                self.report.source = Some(source);
                self.summary_seen = true;
            }
            8 if self.summary_seen && index == self.bitmap_chunks && self.bin_chunks == 0 => {
                self.source_bitmap[index * 1000..index * 1000 + body.len()].copy_from_slice(body);
                self.bitmap_chunks += 1;
            }
            9 if self.bitmap_chunks == 4 && index == self.bin_chunks => {
                let source = self.report.source.as_mut().unwrap();
                for (b, chunk) in source.bins[index * 10..index * 10 + 10]
                    .iter_mut()
                    .zip(body.chunks_exact(32))
                {
                    let mut v = [0; 4];
                    for (out, c) in v.iter_mut().zip(chunk.chunks_exact(8)) {
                        *out = u64::from_be_bytes(c.try_into().unwrap());
                    }
                    if v[..3].iter().any(|x| *x > 30_192_000) || v[3] > 500 {
                        self.report.flags.recipe = true;
                        return;
                    }
                    *b = Bin {
                        offered: v[0],
                        admitted: v[1],
                        received: v[2],
                        control: v[3],
                    };
                }
                self.bin_chunks += 1;
            }
            _ => self.report.flags.recipe = true,
        }
    }
    #[cfg(test)]
    fn probes(&mut self, now: u64, send: impl FnMut(u32) -> Admission) {
        self.probes_timed(now, || now, send);
    }
    fn probes_timed(
        &mut self,
        now: u64,
        mut clock: impl FnMut() -> u64,
        mut send: impl FnMut(u32) -> Admission,
    ) {
        for (i, s) in self.samples[..self.next_probe].iter_mut().enumerate() {
            if s.echo.is_none()
                && !s.expired
                && now > 500_000_000 + i as u64 * 20_000_000 + 200_000_000
            {
                s.expired = true;
                self.report.credit_expired += 1;
                if s.admitted.is_none() {
                    s.missed = true;
                }
            }
        }
        while self.next_probe < 500 && now >= 500_000_000 + self.next_probe as u64 * 20_000_000 {
            let active = self.samples[..self.next_probe]
                .iter()
                .filter(|s| s.offered && !s.missed && !s.expired && s.echo.is_none())
                .count();
            let s = &mut self.samples[self.next_probe];
            s.offered = true;
            self.report.probe_offered += 1;
            if active >= 16 {
                s.missed = true;
                self.report.credit_blocked += 1;
            }
            if now >= 500_000_000 + self.next_probe as u64 * 20_000_000 + 200_000_000 {
                s.missed = true;
                s.expired = true;
                self.report.credit_expired += 1;
            }
            self.next_probe += 1;
        }
        let mut attempts = 0;
        for s in 0..self.next_probe {
            let sample = &mut self.samples[s];
            if sample.missed || sample.admitted.is_some() {
                continue;
            }
            if clock() >= 500_000_000 + s as u64 * 20_000_000 + 200_000_000 {
                sample.missed = true;
                sample.expired = true;
                self.report.credit_expired += 1;
                continue;
            }
            attempts += 1;
            match send(s as u32) {
                Admission::Accepted => {
                    sample.admitted = Some(clock().max(now));
                    self.report.probe_admitted += 1;
                }
                Admission::Backpressured => {
                    self.report.backpressured += 1;
                    break;
                }
                _ => {
                    sample.missed = true;
                    self.report.flags.delivery = true;
                }
            }
            if attempts == 4 {
                break;
            }
        }
        let active = self
            .samples
            .iter()
            .filter(|s| s.offered && !s.missed && !s.expired && s.echo.is_none())
            .count();
        self.report.credit_peak = self.report.credit_peak.max(active);
    }
    pub(crate) fn step(&mut self, endpoint: &mut Endpoint, now: Instant) -> bool {
        if self.expired_at(now) {
            return true;
        }
        self.report.queues.sample(endpoint.stats());
        self.drain_received(|| endpoint.receive(), Instant::now);
        if self.ack_received || self.exchange_expired {
            return true;
        }
        self.dispatch(endpoint, Instant::now())
    }
    fn drain_received(
        &mut self,
        mut receive: impl FnMut() -> Option<Received>,
        mut clock: impl FnMut() -> Instant,
    ) {
        for _ in 0..64 {
            let Some(record) = receive() else {
                break;
            };
            let received_at = clock();
            // Preserve validation of the bounded batch after a timely ACK,
            // but do not undo a terminal commit made before the hard cutoff.
            if self.ack_received && received_at >= self.started + Duration::from_secs(15) {
                break;
            }
            self.received_timed(record, received_at, &mut clock);
            if self.exchange_expired {
                break;
            }
        }
    }
    fn dispatch(&mut self, endpoint: &mut Endpoint, now: Instant) -> bool {
        if self.expired_at(now) {
            return true;
        }
        if self.report.flags.recipe {
            return true;
        }
        if !self.recipe_sent {
            if ns(now, self.started) >= 1_000_000_000 {
                self.report.flags.recipe = true;
                return true;
            }
            if send_control(
                endpoint,
                &mut self.next_send,
                self.report.shape,
                1,
                0,
                false,
                now,
            ) == Admission::Accepted
            {
                self.recipe_sent = true;
            }
        }
        if self.begin.is_none() && ns(now, self.started) >= 1_000_000_000 {
            self.report.flags.recipe = true;
            return true;
        }
        if let Some(begin) = self.begin {
            let shape = self.report.shape;
            let mut sequence = self.next_send;
            self.probes_timed(
                ns(now, begin),
                || ns(Instant::now(), begin),
                |id| send_control(endpoint, &mut sequence, shape, 4, id, false, now),
            );
            self.next_send = sequence;
        }
        if self.bin_chunks == 15
            && self
                .end
                .is_some_and(|end| now >= end + Duration::from_millis(200))
            && !self.ack_sent
        {
            self.report.bitmap_verified = self
                .seen
                .iter()
                .zip(self.source_bitmap)
                .all(|(received, admitted)| received & !admitted == 0)
                && self
                    .source_bitmap
                    .iter()
                    .map(|x| x.count_ones() as u64)
                    .sum::<u64>()
                    == self
                        .report
                        .source
                        .as_ref()
                        .map(|s| s.values[2] + s.values[9])
                        .unwrap_or(0);
            if !self.report.bitmap_verified {
                self.report.flags.measurement = true;
            }
            if self.expired_at(Instant::now()) {
                return true;
            }
            self.ack_sent = send_control(
                endpoint,
                &mut self.next_send,
                self.report.shape,
                6,
                0,
                false,
                now,
            ) == Admission::Accepted;
        }
        self.ack_received
    }
    pub(crate) fn expire_exchange(&mut self) {
        self.exchange_expired = true;
        self.ack_received = false;
        self.report.flags.delivery = true;
        self.report.flags.measurement = true;
    }
    pub(crate) fn is_expired(&self) -> bool {
        self.exchange_expired
    }
    fn expired_at(&mut self, now: Instant) -> bool {
        if self.exchange_expired || now >= self.started + Duration::from_secs(15) {
            self.expire_exchange();
            true
        } else {
            false
        }
    }
    pub(crate) fn wakeup(&self, now: Instant) -> Duration {
        let mut next = self.started + Duration::from_secs(15);
        if self.begin.is_none() {
            next = next.min(self.started + Duration::from_secs(1));
        }
        if let Some(begin) = self.begin {
            for (i, sample) in self.samples[..self.next_probe].iter().enumerate() {
                if !sample.expired && !sample.missed && sample.echo.is_none() {
                    next =
                        next.min(begin + Duration::from_nanos(700_000_000 + i as u64 * 20_000_000));
                }
            }
            if self.next_probe < 500 {
                next = next.min(
                    begin + Duration::from_nanos(500_000_000 + self.next_probe as u64 * 20_000_000),
                );
            }
        }
        if let Some(end) = self.end {
            if now < end + Duration::from_millis(200) {
                next = next.min(end + Duration::from_millis(200));
            }
        }
        next.saturating_duration_since(now)
            .min(Duration::from_micros(500))
    }
    pub(crate) fn finish(mut self) -> RateReport {
        // Include the trailing part of the fixed central scoring interval,
        // including the whole interval when no response completed.
        self.report.largest_no_completion_us = self.report.largest_no_completion_us.max(micros(
            10_500_000_000u64.saturating_sub(self.last_completion_ns.max(500_000_000)),
        )
            as u64);
        let mut a = [0u32; 500];
        let mut r = [0u32; 500];
        let mut response = [0u32; 500];
        let (mut an, mut rn) = (0, 0);
        for (i, s) in self.samples.iter().enumerate() {
            let due = 500_000_000 + i as u64 * 20_000_000;
            if let Some(admitted) = s.admitted {
                a[an] = micros(admitted.saturating_sub(due));
                an += 1;
                if let Some(echo) = s.echo {
                    r[rn] = micros(echo.saturating_sub(admitted));
                    response[rn] = micros(echo.saturating_sub(due));
                    rn += 1;
                }
            }
        }
        self.report.admission_delay = quantiles(&mut a[..an]);
        self.report.rtt = quantiles(&mut r[..rn]);
        self.report.response = quantiles(&mut response[..rn]);
        self.report.exchange_complete = self.ack_received && !self.exchange_expired;
        self.report
    }
}
fn ns(now: Instant, start: Instant) -> u64 {
    now.saturating_duration_since(start)
        .as_nanos()
        .min(u64::MAX as u128) as u64
}
fn send_control(
    endpoint: &mut Endpoint,
    sequence: &mut u64,
    shape: RateShape,
    kind: u8,
    id: u32,
    active: bool,
    now: Instant,
) -> Admission {
    let result = endpoint.send(
        Message {
            lane: Lane::Reliable,
            sequence: *sequence,
            payload: wire::control(shape, kind, id, active),
        },
        now,
    );
    if result == Admission::Accepted {
        *sequence += 1;
    }
    result
}

/// Step-driven source used only by the existing stdio peer owner. Owns no socket,
/// subprocess or pipe; that owner continues checking EOF and the hard lease.
pub struct RatePeer {
    shape: RateShape,
    ready_at: Option<Instant>,
    start: Option<Instant>,
    baseline: Stats,
    producer: Producer,
    peaks: QueuePeaks,
    next_send: u64,
    next_receive: u64,
    begin_sent: bool,
    end_sent: bool,
    echoes: VecDeque<(u32, bool)>,
    seen_probes: [bool; 500],
    echo_offered: u64,
    echo_admitted: u64,
    echo_dropped: u64,
    summary: Option<SourceReport>,
    terminal_index: usize,
    ack_pending: bool,
    finished: bool,
}
#[derive(Clone, Copy, Debug)]
pub enum RatePeerError {
    Recipe,
    Deadline,
    Admission,
}
impl RatePeer {
    pub fn new(shape: RateShape) -> Self {
        Self {
            shape,
            ready_at: None,
            start: None,
            baseline: Stats::default(),
            producer: Producer::new(shape),
            peaks: QueuePeaks::default(),
            next_send: 0,
            next_receive: 0,
            begin_sent: false,
            end_sent: false,
            echoes: VecDeque::with_capacity(16),
            seen_probes: [false; 500],
            echo_offered: 0,
            echo_admitted: 0,
            echo_dropped: 0,
            summary: None,
            terminal_index: 0,
            ack_pending: false,
            finished: false,
        }
    }
    pub fn step(&mut self, endpoint: &mut Endpoint, now: Instant) -> Result<(), RatePeerError> {
        self.peaks.sample(endpoint.stats());
        if endpoint.stats().application_ready && self.ready_at.is_none() {
            self.ready_at = Some(now);
        }
        if !self.finished && self.ready_at.is_some_and(|r| ns(now, r) >= 15_000_000_000) {
            return Err(RatePeerError::Deadline);
        }
        for _ in 0..64 {
            let Some(record) = endpoint.receive() else {
                break;
            };
            if record.lane != Lane::Reliable || record.sequence != self.next_receive {
                return Err(RatePeerError::Recipe);
            }
            self.next_receive += 1;
            let (kind, id, _) = wire::parse_control(self.shape, &record.payload)
                .map_err(|_| RatePeerError::Recipe)?;
            match kind {
                1 if self.start.is_none() => {
                    if self.ready_at.is_some_and(|r| ns(now, r) >= 1_000_000_000) {
                        return Err(RatePeerError::Deadline);
                    }
                    // The authenticated recipe is GO: the receiver is already armed.
                    self.start = Some(now);
                    self.baseline = endpoint.stats();
                }
                4 if self.start.is_some() => {
                    if self.seen_probes[id as usize] {
                        return Err(RatePeerError::Recipe);
                    }
                    self.seen_probes[id as usize] = true;
                    self.echo_offered += 1;
                    let active = ns(now, self.start.unwrap()) < 12_000_000_000;
                    if self.echoes.len() == 16 {
                        self.echo_dropped += 1;
                    } else {
                        self.echoes.push_back((id, active));
                    }
                }
                6 if self.terminal_index == 20 && !self.ack_pending && !self.finished => {
                    self.ack_pending = true;
                }
                _ => return Err(RatePeerError::Recipe),
            }
        }
        let Some(start) = self.start else {
            if self.ready_at.is_some_and(|r| ns(now, r) >= 1_000_000_000) {
                return Err(RatePeerError::Deadline);
            }
            return Ok(());
        };
        let elapsed = ns(now, start);
        for _ in 0..4 {
            let admission = if !self.begin_sent {
                let a = send_control(endpoint, &mut self.next_send, self.shape, 2, 0, false, now);
                if a == Admission::Accepted {
                    self.begin_sent = true;
                }
                a
            } else if let Some((id, active)) = self.echoes.front().copied() {
                let a = send_control(
                    endpoint,
                    &mut self.next_send,
                    self.shape,
                    5,
                    id,
                    active,
                    now,
                );
                if a == Admission::Accepted {
                    self.echoes.pop_front();
                    self.echo_admitted += 1;
                    self.producer.bins[bin(elapsed)].control += 1;
                }
                a
            } else if elapsed >= 12_000_000_000 && !self.end_sent {
                let a = send_control(endpoint, &mut self.next_send, self.shape, 3, 0, false, now);
                if a == Admission::Accepted {
                    self.end_sent = true;
                }
                a
            } else if self.summary.is_some() && self.terminal_index < 20 {
                let payload = self.terminal_payload();
                let a = endpoint.send(
                    Message {
                        lane: Lane::Reliable,
                        sequence: self.next_send,
                        payload,
                    },
                    now,
                );
                if a == Admission::Accepted {
                    self.next_send += 1;
                    self.terminal_index += 1;
                }
                a
            } else if self.ack_pending {
                let a = send_control(endpoint, &mut self.next_send, self.shape, 6, 0, false, now);
                if a == Admission::Accepted {
                    self.ack_pending = false;
                    self.finished = true;
                }
                a
            } else {
                break;
            };
            if admission == Admission::Backpressured {
                break;
            }
            if admission != Admission::Accepted {
                return Err(RatePeerError::Admission);
            }
        }
        if self.summary.is_none() {
            self.producer.offer(elapsed);
            let shape = self.shape;
            self.producer.submit_timed(
                elapsed,
                || ns(Instant::now(), start),
                |s, deadline| {
                    endpoint.send(
                        Message {
                            lane: Lane::Datagram,
                            sequence: s.sequence,
                            payload: wire::data(shape, s),
                        },
                        start + Duration::from_nanos(deadline),
                    )
                },
            );
            if elapsed >= 12_200_000_000 && self.end_sent {
                self.freeze(endpoint.stats(), elapsed);
            }
        }
        Ok(())
    }
    fn freeze(&mut self, stats: Stats, elapsed: u64) {
        let mut report = SourceReport {
            bins: self.producer.bins,
            ..SourceReport::default()
        };
        let v = &mut report.values;
        for (i, c) in self.producer.counts.iter().enumerate() {
            v[i * 7..i * 7 + 7].copy_from_slice(&[
                c.offered,
                c.first_attempted,
                c.admitted,
                c.overflow,
                c.expired,
                c.rejected,
                c.unfinished,
            ]);
        }
        let q = quantiles(&mut self.producer.jitter);
        v[14..21].copy_from_slice(&[
            self.producer.backpressured,
            self.producer.peak as u64,
            q.samples,
            q.p50_us,
            q.p95_us,
            q.p99_us,
            q.max_us,
        ]);
        let b = self.baseline;
        v[21..31].copy_from_slice(&[
            stats.datagrams_admitted - b.datagrams_admitted,
            stats.datagrams_generated - b.datagrams_generated,
            stats.datagrams_udp_sent - b.datagrams_udp_sent,
            stats.datagrams_received - b.datagrams_received,
            stats.datagrams_rejected - b.datagrams_rejected,
            stats.sent_udp_packets - b.sent_udp_packets,
            stats.udp_socket_received - b.udp_socket_received,
            stats.received_udp_packets - b.received_udp_packets,
            stats.expired - b.expired,
            stats.rejected - b.rejected,
        ]);
        v[31..36].copy_from_slice(&[
            self.peaks.reliable_bytes as u64,
            self.peaks.datagrams as u64,
            self.peaks.generated as u64,
            self.peaks.received as u64,
            self.peaks.received_bytes as u64,
        ]);
        v[36] = micros(elapsed) as u64;
        v[37] = u64::from(!self.peaks.valid()) * 2 + u64::from(self.producer.pending() != 0) * 8;
        v[38..41].copy_from_slice(&[self.echo_offered, self.echo_admitted, self.echo_dropped]);
        self.summary = Some(report);
    }
    fn terminal_payload(&self) -> Vec<u8> {
        let report = self.summary.as_ref().unwrap();
        let index = self.terminal_index;
        if index == 0 {
            let mut body = [0; 384];
            for (c, v) in body.chunks_exact_mut(8).zip(report.values) {
                c.copy_from_slice(&v.to_be_bytes());
            }
            wire::chunk(self.shape, 7, 0, &body)
        } else if index <= 4 {
            let i = index - 1;
            let end = ((i + 1) * 1000).min(BITMAP);
            wire::chunk(self.shape, 8, i, &self.producer.admitted[i * 1000..end])
        } else {
            let i = index - 5;
            let mut body = [0; 320];
            for (chunk, b) in body
                .chunks_exact_mut(32)
                .zip(&report.bins[i * 10..i * 10 + 10])
            {
                for (c, v) in chunk
                    .chunks_exact_mut(8)
                    .zip([b.offered, b.admitted, b.received, b.control])
                {
                    c.copy_from_slice(&v.to_be_bytes());
                }
            }
            wire::chunk(self.shape, 9, i, &body)
        }
    }
    pub fn next_wakeup(&self, now: Instant) -> Duration {
        if self.finished {
            return Duration::from_micros(500);
        }
        if let Some(start) = self.start {
            let mut next = start + Duration::from_secs(15);
            if let Some(due) = self.producer.next_due() {
                next = next.min(start + Duration::from_nanos(due));
            }
            if let Some(deadline) = self.producer.pending_deadline() {
                next = next.min(start + Duration::from_nanos(deadline));
            }
            if !self.end_sent {
                next = next.min(start + Duration::from_secs(12));
            }
            if self.summary.is_none() {
                next = next.min(start + Duration::from_millis(12200));
            }
            next.saturating_duration_since(now)
                .min(Duration::from_micros(100))
        } else {
            Duration::from_micros(500)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn all_retained_harness_capacities_fit_256k_excluding_endpoint_and_owner() {
        let peer = RatePeer::new(RateShape::FrameBurst);
        let source = std::mem::size_of::<RatePeer>()
            + peer.producer.backing_bytes()
            + peer.echoes.capacity() * std::mem::size_of::<(u32, bool)>()
            + std::mem::size_of::<SourceReport>()
            + 4096; // freeze/report construction and one payload
        let receiver =
            std::mem::size_of::<RateClient>() + 2 * std::mem::size_of::<RateReport>() + 6000 + 4096;
        eprintln!("harness_source_capacity_bytes={source} harness_receiver_capacity_bytes={receiver} cap_bytes=262144");
        assert!(source <= 262_144);
        assert!(receiver <= 262_144);
    }
    fn complete_report() -> RateReport {
        let mut r = RateReport::new(RateShape::Constant);
        r.cleanup = true;
        r.endpoint_released = true;
        r.bitmap_verified = true;
        r.exchange_complete = true;
        r.received = [30_000, 600];
        r.probe_offered = 500;
        r.probe_admitted = 500;
        r.probe_received = 500;
        r.admission_delay.samples = 500;
        r.rtt.samples = 500;
        r.response.samples = 500;
        let mut s = SourceReport::default();
        for (base, total) in [(0, 30_000), (7, 600)] {
            s.values[base..base + 3].fill(total);
        }
        s.values[16] = 30_600;
        s.values[21..24].fill(30_600);
        s.values[36] = 12_200_000;
        s.values[38..40].fill(500);
        s.bins[0].offered = 30_192_000;
        s.bins[0].admitted = 30_192_000;
        s.bins[0].control = 500;
        r.bins[0].received = 30_192_000;
        r.bins[0].control = 500;
        r.source = Some(s);
        r
    }
    #[test]
    fn complete_load_requires_all_source_first_attempts_and_jitter_samples() {
        for (video, audio, samples) in [
            (0, 0, 0),
            (29_999, 600, 30_599),
            (30_000, 599, 30_599),
            (30_000, 600, 0),
        ] {
            let mut report = complete_report();
            let source = report.source.as_mut().unwrap();
            source.values[1] = video;
            source.values[8] = audio;
            source.values[16..21].fill(0);
            source.values[16] = samples;
            report.conclude();
            assert_eq!(
                report.verdict,
                RateVerdict::MeasurementIncomplete,
                "source attempts {video}/{audio}, samples {samples}"
            );
            assert!(report.flags.measurement && !report.flags.delivery);
            report.received[0] -= 1;
            report.conclude();
            assert_eq!(report.verdict, RateVerdict::DeliveryOrDeadlineFailure);
            assert!(report.flags.measurement && report.flags.delivery);
        }
    }
    fn complete_client(start: Instant) -> RateClient {
        let mut client = RateClient::new(RateShape::Constant, start);
        client.report = complete_report();
        client.ack_sent = true;
        for (i, sample) in client.samples.iter_mut().enumerate() {
            let due = 500_000_000 + i as u64 * 20_000_000;
            *sample = Sample {
                offered: true,
                admitted: Some(due),
                echo: Some(due + 1_000_000),
                ..Sample::default()
            };
        }
        client
    }
    #[test]
    fn valid_final_ack_before_at_and_after_immutable_cutoff() {
        let start = Instant::now();
        for (offset, complete) in [
            (Duration::from_secs(15) - Duration::from_nanos(1), true),
            (Duration::from_secs(15), false),
            (Duration::from_secs(15) + Duration::from_nanos(1), false),
        ] {
            let mut client = complete_client(start);
            client.received(
                Received {
                    lane: Lane::Reliable,
                    sequence: 0,
                    payload: wire::control(RateShape::Constant, 6, 0, false),
                },
                start + offset,
            );
            let mut report = client.finish();
            report.conclude();
            assert_eq!(report.exchange_complete, complete, "offset {offset:?}");
            assert_eq!(
                report.verdict,
                if complete {
                    RateVerdict::Pass
                } else {
                    RateVerdict::DeliveryOrDeadlineFailure
                }
            );
        }
    }
    #[test]
    fn bounded_receive_and_terminal_commit_straddles_use_fresh_clock() {
        let start = Instant::now();
        let deadline = start + Duration::from_secs(15);
        for (receive_time, commit_time, complete) in [
            (
                deadline - Duration::from_nanos(2),
                deadline - Duration::from_nanos(1),
                true,
            ),
            (deadline - Duration::from_nanos(1), deadline, false),
            (
                deadline - Duration::from_nanos(1),
                deadline + Duration::from_nanos(1),
                false,
            ),
            (deadline, deadline, false),
            (
                deadline + Duration::from_nanos(1),
                deadline + Duration::from_nanos(1),
                false,
            ),
        ] {
            let mut client = complete_client(start);
            let mut calls = 0;
            let mut record = Some(Received {
                lane: Lane::Reliable,
                sequence: 0,
                payload: wire::control(RateShape::Constant, 6, 0, false),
            });
            client.drain_received(
                || record.take(),
                || {
                    calls += 1;
                    if calls == 1 {
                        receive_time
                    } else {
                        commit_time
                    }
                },
            );
            let mut report = client.finish();
            report.conclude();
            assert_eq!(
                report.exchange_complete, complete,
                "receive {receive_time:?}, commit {commit_time:?}"
            );
            assert_eq!(
                report.verdict,
                if complete {
                    RateVerdict::Pass
                } else {
                    RateVerdict::DeliveryOrDeadlineFailure
                }
            );
        }
    }
    #[test]
    fn expired_exchange_cannot_be_upgraded_by_queued_ack_or_stale_dispatch_time() {
        let start = Instant::now();
        let mut client = complete_client(start);
        client.expire_exchange(); // Same terminal transition used by the owner.
        client.received(
            Received {
                lane: Lane::Reliable,
                sequence: 0,
                payload: wire::control(RateShape::Constant, 6, 0, false),
            },
            start + Duration::from_secs(15) - Duration::from_nanos(1),
        );
        client.received(
            Received {
                lane: Lane::Reliable,
                sequence: 0,
                payload: wire::control(RateShape::Constant, 6, 0, false),
            },
            start + Duration::from_secs(15) + Duration::from_nanos(1),
        );
        assert!(client.is_expired());
        assert!(!client.ack_received);
        let mut report = client.finish();
        report.conclude();
        assert!(!report.exchange_complete);
        assert!(report.flags.delivery && report.flags.measurement);
        assert_eq!(report.verdict, RateVerdict::DeliveryOrDeadlineFailure);
    }
    #[test]
    fn timely_terminal_ack_does_not_hide_other_already_queued_records() {
        let start = Instant::now();
        let mut client = complete_client(start);
        let slot = schedule::slot(RateShape::Constant, 1, 0).unwrap();
        set_bit(&mut client.seen, slot.sequence);
        let mut records = [
            Received {
                lane: Lane::Reliable,
                sequence: 0,
                payload: wire::control(RateShape::Constant, 6, 0, false),
            },
            Received {
                lane: Lane::Datagram,
                sequence: slot.sequence,
                payload: wire::data(RateShape::Constant, slot),
            },
        ]
        .into_iter();
        client.drain_received(|| records.next(), || start + Duration::from_secs(14));
        let mut report = client.finish();
        report.conclude();
        assert!(report.exchange_complete);
        assert_eq!(report.duplicates, 1);
        assert_eq!(report.verdict, RateVerdict::DeliveryOrDeadlineFailure);
    }
    #[test]
    fn counter_units_not_raw_udp_and_incomplete_metrics_never_become_pass() {
        let mut good = complete_report();
        good.source.as_mut().unwrap().values[26] = 45_000;
        good.conclude();
        assert_eq!(good.verdict, RateVerdict::Pass);
        let mut missing = good.clone();
        missing.received[0] -= 1;
        missing.conclude();
        assert_eq!(missing.verdict, RateVerdict::DeliveryOrDeadlineFailure);
        let mut inconsistent = good.clone();
        inconsistent.source.as_mut().unwrap().values[23] = 30_601;
        inconsistent.conclude();
        assert!(inconsistent.flags.measurement);
        let mut no_metric = good.clone();
        no_metric.rtt.samples = 0;
        no_metric.conclude();
        assert_eq!(no_metric.verdict, RateVerdict::MeasurementIncomplete);
        let mut no_bins = good.clone();
        no_bins.source.as_mut().unwrap().bins = [Bin::default(); BINS];
        no_bins.conclude();
        assert_eq!(no_bins.verdict, RateVerdict::MeasurementIncomplete);
        let mut hierarchy = missing;
        hierarchy.flags.recipe = true;
        hierarchy.flags.measurement = true;
        hierarchy.conclude();
        assert_eq!(hierarchy.verdict, RateVerdict::InvalidRecipe);
        hierarchy.cleanup = false;
        hierarchy.conclude();
        assert_eq!(hierarchy.verdict, RateVerdict::TransportOrCleanupFailure);
        assert!(hierarchy.flags.delivery && hierarchy.flags.measurement);
    }
    #[test]
    fn explicit_reorder_loss_duplicate_and_drain_preserve_all_missing_ids() {
        let now = Instant::now();
        let mut c = RateClient::new(RateShape::Constant, now);
        c.end = Some(now);
        for (ordinal, ms) in [(3, 0), (1, 0), (3, 1), (0, 199), (2, 200)] {
            let s = schedule::slot(RateShape::Constant, 1, ordinal).unwrap();
            c.received(
                Received {
                    lane: Lane::Datagram,
                    sequence: s.sequence,
                    payload: wire::data(RateShape::Constant, s),
                },
                now + Duration::from_millis(ms),
            );
        }
        assert_eq!(c.report.received[0], 3);
        assert_eq!(c.report.duplicates, 1);
        assert_eq!(c.report.late, 1);
        let mut r = c.finish();
        r.cleanup = true;
        r.endpoint_released = true;
        r.conclude();
        assert_eq!(r.datagram_missing(), 30_597);
        assert_eq!(r.verdict, RateVerdict::DeliveryOrDeadlineFailure);
    }
    #[test]
    fn delayed_echo_is_kept_in_tail_after_credit_expiry_without_readmission() {
        let now = Instant::now();
        let mut c = RateClient::new(RateShape::Constant, now);
        c.begin = Some(now);
        c.probes(500_000_000, |id| {
            assert_eq!(id, 0);
            Admission::Accepted
        });
        c.probes(701_000_000, |id| {
            assert_ne!(id, 0);
            Admission::Backpressured
        });
        c.received(
            Received {
                lane: Lane::Reliable,
                sequence: 0,
                payload: wire::control(RateShape::Constant, 5, 0, true),
            },
            now + Duration::from_millis(702),
        );
        let r = c.finish();
        assert_eq!(r.probe_late, 1);
        assert_eq!(r.credit_expired, 1);
        assert_eq!(r.rtt.max_us, 202_000);
        assert_eq!(r.probe_missing(), 499);
    }
    #[test]
    fn missing_control_keeps_full_window_gap_and_releases_credits_without_retries() {
        let now = Instant::now();
        let mut c = RateClient::new(RateShape::Constant, now);
        c.begin = Some(now);
        let mut attempts = 0;
        for i in 0..=540 {
            c.probes(500_000_000 + i * 20_000_000, |_| {
                attempts += 1;
                Admission::Accepted
            });
        }
        assert_eq!(attempts, 500);
        assert_eq!(c.report.probe_admitted, 500);
        assert!(c.report.credit_peak <= 16);
        assert_eq!(c.report.credit_expired, 500);
        let r = c.finish();
        assert_eq!(r.probe_missing(), 500);
        assert_eq!(r.rtt.samples, 0);
        assert_eq!(r.largest_no_completion_us, 10_000_000);
    }
    #[test]
    fn armed_receiver_counts_datagrams_overtaking_load_begin_then_rejects_duplicates_and_late() {
        let now = Instant::now();
        let mut c = RateClient::new(RateShape::Constant, now);
        let packet = || {
            let s = schedule::slot(RateShape::Constant, 1, 0).unwrap();
            Received {
                lane: Lane::Datagram,
                sequence: s.sequence,
                payload: wire::data(RateShape::Constant, s),
            }
        };
        c.received(packet(), now);
        assert_eq!(c.report.received[0], 1);
        assert_eq!(c.report.pre_begin, 1);
        c.received(
            Received {
                lane: Lane::Reliable,
                sequence: 0,
                payload: wire::control(RateShape::Constant, 2, 0, false),
            },
            now + Duration::from_millis(1),
        );
        c.received(packet(), now + Duration::from_millis(2));
        assert_eq!(c.report.duplicates, 1);
        c.end = Some(now);
        let s = schedule::slot(RateShape::Constant, 1, 1).unwrap();
        c.received(
            Received {
                lane: Lane::Datagram,
                sequence: s.sequence,
                payload: wire::data(RateShape::Constant, s),
            },
            now + Duration::from_millis(200),
        );
        assert_eq!(c.report.received[0], 1);
        assert_eq!(c.report.late, 1);
    }
    #[test]
    fn malformed_terminal_chunk_and_out_of_order_report_cannot_complete() {
        let now = Instant::now();
        let mut c = RateClient::new(RateShape::Constant, now);
        c.received(
            Received {
                lane: Lane::Reliable,
                sequence: 0,
                payload: wire::chunk(RateShape::Constant, 8, 0, &[0; 1000]),
            },
            now,
        );
        assert!(c.report.flags.recipe);
        assert!(!c.report.exchange_complete);
    }
}
