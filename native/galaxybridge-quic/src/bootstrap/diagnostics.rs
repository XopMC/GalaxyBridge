//! Fixed-size local timing evidence, never transport policy.
/// Only local roles; no peer-controlled text enters the terminal scalar schema.
#[derive(Clone, Copy)]
pub enum Role {
    Client,
    Peer,
}
impl Role {
    fn label(self) -> &'static str {
        match self {
            Self::Client => "client",
            Self::Peer => "peer",
        }
    }
}
/// Terminal-only I/O. Failure is diagnostic, never a transport decision.
pub fn write_terminal(
    mut out: impl std::io::Write,
    role: Role,
    stats: crate::Stats,
    owner: OwnerSummary,
) -> std::io::Result<()> {
    let role = role.label();
    macro_rules! scalar {
        ($key:expr,$value:expr) => {
            writeln!(out, "{role}_{}={}", $key, $value)?
        };
    }
    let p = stats.pressure;
    scalar!("pressure_valid", u8::from(p.valid));
    scalar!("generated_cap_stops", p.generated_cap_stops);
    scalar!("quiche_done_pending_dg", p.quiche_done_pending_dg);
    scalar!("future_send_stops", p.future_send_stops);
    scalar!("udp_attempts", p.udp_attempts);
    scalar!("udp_would_block", p.udp_would_block);
    scalar!("udp_would_block_due", p.udp_would_block_due);
    scalar!("udp_success", p.udp_success);
    scalar!("udp_errors", p.udp_errors);
    scalar!("udp_short", p.udp_short);
    scalar!("expiry_submission", p.expiry_submission);
    scalar!("expiry_queued", p.expiry_queued);
    scalar!("expiry_generated", p.expiry_generated);
    scalar!("wrapper_record_stops", p.wrapper_record_stops);
    scalar!("wrapper_byte_stops", p.wrapper_byte_stops);
    scalar!("dg_budget_stops", p.dg_budget_stops);
    scalar!("retained_intake_pauses", p.retained_intake_pauses);
    scalar!("udp_saturated_turns", p.udp_saturated_turns);
    fn metric(
        out: &mut impl std::io::Write,
        role: &str,
        name: &str,
        m: Metric,
    ) -> std::io::Result<()> {
        writeln!(out,"{role}_{name}_count={} {role}_{name}_total_ns={} {role}_{name}_max_ns={} {role}_{name}_valid={}",m.count,m.total_ns,m.max_ns,u8::from(m.valid))
    }
    metric(&mut out, role, "generated_write_age", p.generated_write_age)?;
    for (name, s) in [("write_blocked", p.write_blocked), ("retained", p.retained)] {
        metric(&mut out, role, name, s.duration)?;
        writeln!(
            out,
            "{role}_{name}_active={} {role}_{name}_active_ns={}",
            u8::from(s.active),
            s.active_ns
        )?;
    }
    let p = stats.path;
    scalar!("path_terminal", u8::from(p.terminal));
    scalar!("path_samples", p.samples);
    scalar!("path_unavailable_samples", p.unavailable_samples);
    scalar!("path_valid", u8::from(p.valid));
    scalar!("path_available", u8::from(p.available));
    scalar!("path_rtt_available", u8::from(p.rtt_available));
    scalar!(
        "path_delivery_rate_available",
        u8::from(p.delivery_rate_available)
    );
    scalar!(
        "path_max_bandwidth_available",
        u8::from(p.max_bandwidth_available)
    );
    scalar!("path_sample_at_ns", p.sample_at_ns);
    scalar!("path_rtt_ns", p.rtt_ns);
    scalar!("path_min_rtt_ns", p.min_rtt_ns);
    scalar!("path_max_rtt_ns", p.max_rtt_ns);
    scalar!("path_rttvar_ns", p.rttvar_ns);
    scalar!("path_cwnd_bytes", p.cwnd_bytes);
    scalar!("path_cwnd_min_bytes", p.cwnd_min_bytes);
    scalar!("path_cwnd_max_bytes", p.cwnd_max_bytes);
    scalar!("path_lost_packets", p.lost_packets);
    scalar!("path_retrans_packets", p.retrans_packets);
    scalar!("path_pto_count", p.pto_count);
    scalar!("path_lost_dg_frames", p.lost_dg_frames);
    scalar!("path_stream_retrans_bytes", p.stream_retrans_bytes);
    scalar!(
        "path_delivery_rate_bytes_per_second",
        p.delivery_rate_bytes_per_second
    );
    scalar!(
        "path_delivery_rate_max_bytes_per_second",
        p.delivery_rate_max_bytes_per_second
    );
    scalar!("path_pmtu_bytes", p.pmtu_bytes);
    scalar!(
        "path_max_bandwidth_bytes_per_second",
        p.max_bandwidth_bytes_per_second
    );
    for (name, s) in [
        ("send", stats.socket_buffers.send),
        ("receive", stats.socket_buffers.receive),
    ] {
        writeln!(out,"{role}_socket_{name}_available={} {role}_socket_{name}_bytes={} {role}_socket_{name}_errno={}",u8::from(s.available),s.bytes,s.errno)?;
    }
    scalar!("owner_turns", owner.turns);
    scalar!("owner_zero_sleep", owner.zero_sleep);
    scalar!("owner_retired_step_skips", owner.retired_step_skips);
    scalar!("owner_valid", u8::from(owner.valid));
    for (name, m) in [
        ("owner_poll", owner.poll),
        ("owner_step", owner.step),
        ("owner_service_gap", owner.service_gap),
        ("owner_requested_sleep", owner.requested_sleep),
        ("owner_actual_sleep", owner.actual_sleep),
        ("owner_overshoot", owner.overshoot),
    ] {
        metric(&mut out, role, name, m)?;
    }
    Ok(())
}
use std::{
    cell::Cell,
    time::{Duration, Instant},
};

#[derive(Clone, Copy, Debug)]
pub struct Metric {
    pub count: u64,
    pub total_ns: u64,
    pub max_ns: u64,
    pub valid: bool,
}
impl Default for Metric {
    fn default() -> Self {
        Self {
            count: 0,
            total_ns: 0,
            max_ns: 0,
            valid: true,
        }
    }
}
impl Metric {
    pub fn record(&mut self, value: Option<u64>) {
        let Some((count, total, v)) = value
            .and_then(|v| Some((self.count.checked_add(1)?, self.total_ns.checked_add(v)?, v)))
        else {
            self.valid = false;
            return;
        };
        self.count = count;
        self.total_ns = total;
        self.max_ns = self.max_ns.max(v);
    }
    pub fn interval(&mut self, before: Instant, after: Instant) {
        self.record(elapsed(before, after));
    }
}
pub fn elapsed(before: Instant, after: Instant) -> Option<u64> {
    u64::try_from(after.checked_duration_since(before)?.as_nanos()).ok()
}
pub fn increment(value: &mut u64, valid: &mut bool) {
    add(value, 1, valid);
}
pub fn add(value: &mut u64, amount: u64, valid: &mut bool) {
    if let Some(next) = value.checked_add(amount) {
        *value = next;
    } else {
        *valid = false;
    }
}
#[derive(Clone, Copy, Debug, Default)]
pub struct SpanSummary {
    pub duration: Metric,
    pub active: bool,
    pub active_ns: u64,
}
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct Span {
    start: Option<Instant>,
    closed: Metric,
}
impl Span {
    pub fn start(&mut self, now: Instant) {
        self.start.get_or_insert(now);
    }
    pub fn close(&mut self, now: Instant) {
        if let Some(start) = self.start.take() {
            self.closed.interval(start, now);
        }
    }
    pub fn snapshot(&self, now: Instant) -> SpanSummary {
        let mut result = SpanSummary {
            duration: self.closed,
            ..SpanSummary::default()
        };
        if let Some(start) = self.start {
            result.active = true;
            let age = elapsed(start, now);
            result.duration.record(age);
            result.active_ns = age.unwrap_or(0);
        }
        result
    }
}
#[derive(Clone, Copy, Debug)]
pub struct OwnerSummary {
    pub turns: u64,
    pub zero_sleep: u64,
    pub retired_step_skips: u64,
    pub valid: bool,
    pub poll: Metric,
    pub step: Metric,
    pub service_gap: Metric,
    pub requested_sleep: Metric,
    pub actual_sleep: Metric,
    pub overshoot: Metric,
}
impl Default for OwnerSummary {
    fn default() -> Self {
        Self {
            turns: 0,
            zero_sleep: 0,
            retired_step_skips: 0,
            valid: false,
            poll: Metric::default(),
            step: Metric::default(),
            service_gap: Metric::default(),
            requested_sleep: Metric::default(),
            actual_sleep: Metric::default(),
            overshoot: Metric::default(),
        }
    }
}
pub struct OwnerTiming {
    summary: Cell<OwnerSummary>,
    last_turn: Cell<Option<Instant>>,
}
impl Default for OwnerTiming {
    fn default() -> Self {
        Self {
            summary: Cell::new(OwnerSummary {
                valid: true,
                ..OwnerSummary::default()
            }),
            last_turn: Cell::new(None),
        }
    }
}
impl OwnerTiming {
    pub fn turn(&self, now: Instant) {
        let mut s = self.summary.get();
        s.valid &= s.retired_step_skips == 0;
        increment(&mut s.turns, &mut s.valid);
        if let Some(before) = self.last_turn.replace(Some(now)) {
            s.service_gap.interval(before, now);
        }
        self.summary.set(s);
    }
    pub fn poll<T>(&self, mut clock: impl FnMut() -> Instant, call: impl FnOnce() -> T) -> T {
        let before = clock();
        let value = call();
        let after = clock();
        let mut s = self.summary.get();
        s.poll.interval(before, after);
        self.summary.set(s);
        value
    }
    pub fn step<T>(&self, mut clock: impl FnMut() -> Instant, call: impl FnOnce() -> T) -> T {
        let before = clock();
        let value = call();
        let after = clock();
        let mut s = self.summary.get();
        s.step.interval(before, after);
        self.summary.set(s);
        value
    }
    /// The existing rate owner skips work after a ready poll retires, but
    /// still performs its real final sleep. This is not a fabricated step.
    pub fn retired_step_skipped(&self, endpoint_retired: bool) {
        let mut s = self.summary.get();
        s.valid &= endpoint_retired
            && s.retired_step_skips == 0
            && s.poll.count == s.turns
            && s.step.count.checked_add(1) == Some(s.poll.count)
            && s.actual_sleep.count == s.step.count;
        increment(&mut s.retired_step_skips, &mut s.valid);
        self.summary.set(s);
    }
    pub fn sleep(
        &self,
        requested: Duration,
        mut clock: impl FnMut() -> Instant,
        call: impl FnOnce(Duration),
    ) {
        let before = clock();
        call(requested);
        let after = clock();
        let mut s = self.summary.get();
        let r = u64::try_from(requested.as_nanos()).ok();
        let a = elapsed(before, after);
        s.requested_sleep.record(r);
        s.actual_sleep.record(a);
        s.overshoot
            .record(r.zip(a).map(|(r, a)| a.saturating_sub(r)));
        if requested.is_zero() {
            increment(&mut s.zero_sleep, &mut s.valid);
        }
        self.summary.set(s);
    }
    pub fn snapshot(&self) -> OwnerSummary {
        let mut s = self.summary.get();
        let covered_steps = s.step.count.checked_add(s.retired_step_skips);
        s.valid &= s.turns > 0
            && s.poll.count == s.turns
            && s.step.count <= s.poll.count
            && s.poll.count - s.step.count <= 1
            && s.service_gap.count == s.turns.saturating_sub(1)
            && s.requested_sleep.count == s.actual_sleep.count
            && s.actual_sleep.count == s.overshoot.count
            && covered_steps.is_some_and(|covered| {
                covered <= s.poll.count
                    && s.actual_sleep.count <= covered
                    && covered - s.actual_sleep.count <= 1
            })
            && [
                s.poll,
                s.step,
                s.service_gap,
                s.requested_sleep,
                s.actual_sleep,
                s.overshoot,
            ]
            .iter()
            .all(|m| m.valid);
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn owner_observation_retired_skip_requires_the_exact_final_phase() {
        let t = Instant::now();
        let final_turn = |marked: Option<bool>| {
            let o = OwnerTiming::default();
            o.turn(t);
            o.poll(clock(t, t), || ());
            o.step(clock(t, t), || ());
            o.sleep(Duration::ZERO, clock(t, t), |_| ());
            o.turn(t);
            o.poll(clock(t, t), || ());
            if let Some(retired) = marked {
                o.retired_step_skipped(retired);
            }
            o.sleep(Duration::ZERO, clock(t, t), |_| ());
            o
        };
        let o = final_turn(Some(true));
        let s = o.snapshot();
        assert!(s.valid);
        assert_eq!(s.retired_step_skips, 1);
        assert_eq!(s.step.count, 1);
        assert_eq!(s.actual_sleep.count, 2);
        assert!(
            !final_turn(None).snapshot().valid,
            "missing explicit skip hook remains invalid"
        );
        assert!(
            !final_turn(Some(false)).snapshot().valid,
            "nonretired work omission cannot be excused"
        );
        o.retired_step_skipped(true);
        assert!(!o.snapshot().valid, "duplicate marker");
        let o = final_turn(Some(true));
        o.turn(t);
        o.poll(clock(t, t), || ());
        o.step(clock(t, t), || ());
        assert!(!o.snapshot().valid, "marked skip must be final");
        let o = OwnerTiming::default();
        o.turn(t);
        o.retired_step_skipped(true);
        o.sleep(Duration::ZERO, clock(t, t), |_| ());
        assert!(!o.snapshot().valid, "missing actual poll hook");
    }
    fn clock(start: Instant, end: Instant) -> impl FnMut() -> Instant {
        let mut times = [start, end].into_iter();
        move || times.next().unwrap()
    }
    #[test]
    fn owner_observation_exact_boundaries_and_missing_evidence() {
        let t = Instant::now();
        let o = OwnerTiming::default();
        assert!(!o.snapshot().valid);
        o.turn(t);
        assert!(!o.snapshot().valid, "missing real poll");
        assert_eq!(o.poll(clock(t, t), || 7), 7);
        o.step(clock(t, t + Duration::from_nanos(2)), || ());
        o.sleep(Duration::ZERO, clock(t, t), |requested| {
            assert!(requested.is_zero())
        });
        o.turn(t + Duration::from_nanos(10));
        o.poll(clock(t, t + Duration::from_nanos(3)), || Err::<(), _>(9))
            .unwrap_err();
        o.step(clock(t, t + Duration::from_nanos(4)), || ());
        o.sleep(
            Duration::from_nanos(5),
            clock(t, t + Duration::from_nanos(8)),
            |r| assert_eq!(r.as_nanos(), 5),
        );
        let s = o.snapshot();
        assert!(s.valid);
        assert_eq!(s.turns, 2);
        assert_eq!(s.zero_sleep, 1);
        assert_eq!((s.poll.count, s.poll.total_ns, s.poll.max_ns), (2, 3, 3));
        assert_eq!((s.step.count, s.step.total_ns, s.step.max_ns), (2, 6, 4));
        assert_eq!((s.service_gap.count, s.service_gap.max_ns), (1, 10));
        assert_eq!(
            (
                s.requested_sleep.total_ns,
                s.actual_sleep.total_ns,
                s.overshoot.total_ns
            ),
            (5, 8, 3)
        );
        o.turn(t);
        o.poll(clock(t, t), || ());
        assert!(!o.snapshot().valid, "backwards turn clock");
        let m = OwnerTiming::default();
        m.turn(t);
        m.poll(clock(t + Duration::from_nanos(1), t), || ());
        assert!(!m.snapshot().valid);
    }
    #[test]
    fn owner_observation_overflow_and_diagnostic_output_failure_are_explicit() {
        let mut m = Metric {
            count: u64::MAX,
            ..Metric::default()
        };
        m.record(Some(1));
        assert!(!m.valid);
        assert_eq!(m.count, u64::MAX);
        let mut m = Metric {
            total_ns: u64::MAX,
            ..Metric::default()
        };
        m.record(Some(1));
        assert!(!m.valid);
        let mut n = u64::MAX;
        let mut valid = true;
        increment(&mut n, &mut valid);
        assert!(!valid);
        assert_eq!(n, u64::MAX);
        let t = Instant::now();
        let o = OwnerTiming::default();
        o.turn(t);
        o.poll(clock(t, t), || ());
        o.sleep(Duration::MAX, clock(t, t), |_| ());
        assert!(!o.snapshot().valid);
        struct Broken;
        impl std::io::Write for Broken {
            fn write(&mut self, _: &[u8]) -> std::io::Result<usize> {
                Err(std::io::ErrorKind::BrokenPipe.into())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        assert!(
            write_terminal(Broken, Role::Client, crate::Stats::default(), o.snapshot()).is_err()
        );
    }
}
