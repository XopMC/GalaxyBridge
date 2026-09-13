//! Exact-child ownership. All pipes are nonblocking and close-on-exec.
use crate::{owner::OwnerSlot, Error};
use std::{
    ffi::OsString,
    io::{Read, Write},
    os::{
        fd::AsRawFd,
        unix::{ffi::OsStrExt, process::ExitStatusExt},
    },
    process::{Child, ChildStderr, ChildStdin, ChildStdout, Command, Stdio},
    sync::{Mutex, OnceLock},
    time::{Duration, Instant},
};

fn bitrate_environment(command: &mut Command, producer: bool, opt_in: bool) {
    if producer && opt_in {
        command.env("GB_QUIC_BITRATE_DIAGNOSTICS", "1");
    } else {
        command.env_remove("GB_QUIC_BITRATE_DIAGNOSTICS");
    }
}
#[test]
fn bitrate_observation_exact_producer_opt_in_environment() {
    for producer in [false, true] {
        for opt_in in [false, true] {
            let mut c = Command::new("/not-executed");
            c.env("GB_QUIC_BITRATE_DIAGNOSTICS", "inherited");
            bitrate_environment(&mut c, producer, opt_in);
            let env: Vec<_> = c.get_envs().collect();
            assert_eq!(env.len(), 1);
            assert_eq!(
                env[0].0,
                std::ffi::OsStr::new("GB_QUIC_BITRATE_DIAGNOSTICS")
            );
            assert_eq!(
                env[0].1,
                if producer && opt_in {
                    Some(std::ffi::OsStr::new("1"))
                } else {
                    None
                }
            );
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct DisplayStatus {
    pub kind: u8,
    pub width: u32,
    pub height: u32,
    pub density: u32,
    pub display: u32,
}
impl DisplayStatus {
    pub fn scalar(kind: u8) -> Self {
        Self {
            kind,
            width: 0,
            height: 0,
            density: 0,
            display: 0,
        }
    }
    pub fn validate(self) -> Result<Self, Error> {
        let values = [self.width, self.height, self.density, self.display];
        if self.kind == 1 && values.iter().all(|n| *n > 0 && *n <= i32::MAX as u32)
            || matches!(self.kind, 2 | 3) && values == [0; 4]
        {
            Ok(self)
        } else {
            Err(Error::Protocol)
        }
    }
}
/// Exact producer stdout only. At most1024 partial bytes; unrelated output is
/// discarded. Across the process lifetime only assignment/conflict/end emerge.
pub struct DisplayParser {
    bytes: [u8; 1024],
    used: usize,
    oversize: bool,
    accepted: Option<u32>,
    conflicted: bool,
    ended: bool,
}
impl Default for DisplayParser {
    fn default() -> Self {
        Self {
            bytes: [0; 1024],
            used: 0,
            oversize: false,
            accepted: None,
            conflicted: false,
            ended: false,
        }
    }
}
impl DisplayParser {
    pub fn push(&mut self, bytes: &[u8]) -> Vec<DisplayStatus> {
        let mut events = Vec::with_capacity(2);
        if self.ended {
            return events;
        }
        for byte in bytes {
            if *byte == b'\n' {
                if !self.oversize {
                    if let Some(event) = self.line() {
                        events.push(event);
                    }
                }
                self.used = 0;
                self.oversize = false;
            } else if !self.oversize {
                if self.used == self.bytes.len() {
                    self.used = 0;
                    self.oversize = true;
                } else {
                    self.bytes[self.used] = *byte;
                    self.used += 1;
                }
            }
        }
        events
    }
    pub fn finish(&mut self) -> Vec<DisplayStatus> {
        if self.ended {
            return vec![];
        }
        let event = if !self.oversize && self.used > 0 {
            self.line()
        } else {
            None
        };
        self.used = 0;
        self.oversize = false;
        self.ended = true;
        event
            .into_iter()
            .chain(std::iter::once(DisplayStatus::scalar(3)))
            .collect()
    }
    fn line(&mut self) -> Option<DisplayStatus> {
        if self.conflicted {
            return None;
        }
        let bytes = &self.bytes[..self.used];
        let bytes = bytes.strip_suffix(b"\r").unwrap_or(bytes);
        let text = std::str::from_utf8(bytes).ok()?;
        let text = text
            .strip_prefix("[server] INFO: New display: ")?
            .strip_suffix(')')?;
        let (size, display) = text.split_once(" (id=")?;
        let (width, rest) = size.split_once('x')?;
        let (height, density) = rest.split_once('/')?;
        fn positive(s: &str) -> Option<u32> {
            if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
                return None;
            }
            let n: u32 = s.parse().ok()?;
            (n > 0 && n <= i32::MAX as u32).then_some(n)
        }
        let event = DisplayStatus {
            kind: 1,
            width: positive(width)?,
            height: positive(height)?,
            density: positive(density)?,
            display: positive(display)?,
        };
        if let Some(old) = self.accepted {
            if old == event.display {
                return None;
            }
            self.conflicted = true;
            return Some(DisplayStatus::scalar(2));
        }
        self.accepted = Some(event.display);
        Some(event)
    }
}
#[cfg(test)]
mod display_tests {
    use super::*;
    #[test]
    fn exact_owned_child_stdout_has_assignment_then_end_without_raw_output() {
        let command = OwnedCommand {
            program: "/usr/bin/printf".into(),
            args: vec![
                "unrelated discarded text\n[server] INFO: New display: 640x480/420 (id=7)\n".into(),
            ],
        };
        let mut child = OwnedChild::spawn(&command).unwrap();
        let mut parser = DisplayParser::default();
        let mut events = vec![];
        let end = Instant::now() + Duration::from_secs(1);
        while !events.iter().any(|e: &DisplayStatus| e.kind == 3) {
            events.extend(child.observe_display(&mut parser).unwrap());
            assert!(Instant::now() < end);
            std::thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(
            events,
            [
                DisplayStatus {
                    kind: 1,
                    width: 640,
                    height: 480,
                    density: 420,
                    display: 7
                },
                DisplayStatus::scalar(3)
            ]
        );
        assert!(child.observe_display(&mut parser).unwrap().is_empty());
        assert!(child.cleanup().unwrap().complete);
    }
}

struct Abandoned {
    child: Child,
    _slot: OwnerSlot,
}
static ABANDONED: OnceLock<Mutex<[Option<Abandoned>; 16]>> = OnceLock::new();
/// Nonblocking fallback for a caller that drops without completing cleanup.
/// Retain the exact handle AND its owner slot until try_wait confirms reaping.
/// This never counts as a successful explicit cleanup/destroy.
pub fn poll_abandoned_cleanup() -> usize {
    let mut entries = ABANDONED
        .get_or_init(|| Mutex::new(std::array::from_fn(|_| None)))
        .lock()
        .unwrap();
    for entry in entries.iter_mut() {
        if entry
            .as_mut()
            .is_some_and(|e| matches!(e.child.try_wait(), Ok(Some(_))))
        {
            *entry = None;
        }
    }
    entries.iter().filter(|e| e.is_some()).count()
}
fn abandon(mut child: Child, slot: OwnerSlot) {
    let _ = child.kill();
    if matches!(child.try_wait(), Ok(Some(_))) {
        return;
    }
    let mut entries = ABANDONED
        .get_or_init(|| Mutex::new(std::array::from_fn(|_| None)))
        .lock()
        .unwrap();
    // One exact child at most per admitted slot; callers cannot mint a 17th.
    let vacant = entries
        .iter_mut()
        .find(|e| e.is_none())
        .expect("owner/child capacity invariant");
    *vacant = Some(Abandoned { child, _slot: slot });
}
#[derive(Clone)]
pub struct OwnedCommand {
    pub program: OsString,
    pub args: Vec<OsString>,
}
impl OwnedCommand {
    fn first_cause_helper(&self) -> Self {
        let mut command = self.clone();
        if let Some(i) = command
            .args
            .windows(3)
            .position(|a| a[0] == "shell" && a[1] == "-T")
        {
            if command.args.get(i + 3).is_some_and(|a| a == "--stdio-peer") {
                command
                    .args
                    .insert(i + 2, "GB_QUIC_FIRST_ERROR_DIAGNOSTICS=1".into());
                command.args.insert(i + 2, "env".into());
            }
        }
        command
    }
    fn recovery_helper(&self) -> Self {
        let mut command = self.clone();
        if let Some(i) = command
            .args
            .windows(3)
            .position(|a| a[0] == "shell" && a[1] == "-T")
        {
            if command.args.get(i + 3).is_some_and(|a| a == "--stdio-peer") {
                command
                    .args
                    .insert(i + 2, "GB_QUIC_RECOVERY_DIAGNOSTICS=1".into());
                command.args.insert(i + 2, "env".into());
            }
        }
        command
    }
    pub fn validate(&self) -> Result<(), Error> {
        if self.program.is_empty() || self.args.len() + 1 > 64 {
            return Err(Error::Protocol);
        }
        let mut n = 0usize;
        for a in std::iter::once(&self.program).chain(self.args.iter()) {
            let b = a.as_os_str().as_bytes();
            if b.contains(&0) {
                return Err(Error::Protocol);
            }
            n = n.checked_add(b.len() + 1).ok_or(Error::Capacity)?;
        }
        if n > 8192 {
            return Err(Error::Capacity);
        }
        Ok(())
    }
}
#[test]
fn recovery_observation_exact_owned_helper_environment_only() {
    let make = |args: &[&str]| OwnedCommand {
        program: "adb".into(),
        args: args.iter().map(OsString::from).collect(),
    };
    let helper = make(&[
        "-s",
        "selected",
        "shell",
        "-T",
        "/owned/helper",
        "--stdio-peer",
    ]);
    assert_eq!(
        helper.recovery_helper().args,
        make(&[
            "-s",
            "selected",
            "shell",
            "-T",
            "env",
            "GB_QUIC_RECOVERY_DIAGNOSTICS=1",
            "/owned/helper",
            "--stdio-peer"
        ])
        .args
    );
    assert_eq!(helper.args.len(), 6);
    for args in [
        vec!["shell", "-T", "app_process", "/", "server"],
        vec!["shell", "-T", "other"],
        vec!["--stdio-peer"],
    ] {
        let command = make(&args);
        assert_eq!(command.recovery_helper().args, command.args);
    }
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Cleanup {
    pub complete: bool,
    pub forced: bool,
    pub failed: bool,
    pub exit_code: Option<i32>,
}
pub struct OwnedChild {
    child: Option<Child>,
    slot: OwnerSlot,
    input: Option<ChildStdin>,
    output: ChildStdout,
    error: ChildStderr,
    stopping: Option<Instant>,
    report: Cleanup,
    recovery_generation: u64,
    recovery_parser: Option<Box<crate::recovery::TraceParser>>,
    first_capture: Option<Box<FirstCapture>>,
    first_identity: Option<(u64, u64, u64)>,
    first_record: crate::ffi::TerminalRecord,
    first_emitted: bool,
    #[cfg(feature = "qa")]
    cleanup_clock: Option<Instant>,
    #[cfg(feature = "qa")]
    source_capture: QaSourceCapture,
    #[cfg(feature = "qa")]
    control_capture: QaControlCapture,
}
struct FirstCapture {
    partial: [u8; 512],
    used: usize,
    discard: bool,
}
impl Default for FirstCapture {
    fn default() -> Self {
        Self {
            partial: [0; 512],
            used: 0,
            discard: false,
        }
    }
}
impl FirstCapture {
    fn push(
        &mut self,
        bytes: &[u8],
        identity: (u64, u64, u64),
        record: &mut crate::ffi::TerminalRecord,
    ) {
        for &b in bytes {
            if b != b'\n' {
                if !self.discard && self.used < self.partial.len() {
                    self.partial[self.used] = b;
                    self.used += 1;
                } else {
                    self.used = 0;
                    self.discard = true;
                }
                continue;
            }
            if !self.discard {
                self.line(identity, record);
            }
            self.used = 0;
            self.discard = false;
        }
    }
    fn line(
        &self,
        (generation, target, _): (u64, u64, u64),
        record: &mut crate::ffi::TerminalRecord,
    ) {
        fn numeric<const N: usize>(bytes: &[u8], prefix: &[u8]) -> Option<[u64; N]> {
            let text = std::str::from_utf8(bytes.strip_prefix(prefix)?).ok()?;
            let mut words = text.split(' ');
            let mut values = [0; N];
            for v in &mut values {
                let s = words.next()?;
                if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
                    return None;
                }
                *v = s.parse().ok()?;
            }
            words.next().is_none().then_some(values)
        }
        let line = &self.partial[..self.used];
        if record.first.is_none() {
            if let Some(v) = numeric::<13>(line, b"GBQF1 R ") {
                // Zero is explicitly a peer CLI with no C handle, not a guessed owner id.
                if v[0] == 0
                    && v[1] == generation
                    && v[2] == target
                    && v[3] > 0
                    && v[4] > 0
                    && (101..=117).contains(&v[5])
                    && v[6] <= 8
                {
                    record.first = Some(v);
                }
            }
        }
        if record.source.is_none() && record.first.is_some() {
            if let Some(v) = numeric::<8>(line, b"GBQS1 ") {
                if (101..=117).contains(&v[0]) && v[1] == 1 && record.first.unwrap()[5] == v[0] {
                    record.source = Some(v);
                }
            }
        }
        if record.exits[1].is_none() {
            if let Some(v) = numeric::<4>(line, b"GBQX1 ") {
                if v[0] == generation
                    && v[1] == 2
                    && ((v[2] == 1 && v[3] == 0)
                        || (v[2] == 2 && v[3] <= 255)
                        || (v[2] == 3 && (1..=128).contains(&v[3])))
                {
                    record.exits[1] = Some(v);
                }
            }
        }
    }
}
#[cfg(test)]
mod first_cause_tests {
    use super::*;
    #[test]
    fn first_cause_parser_current_identity_numeric_fragmented_and_once() {
        let text =
            b"GBQF1 R 0 771 9 12 34 101 8 56 0 0 0 0 0\nGBQS1 101 1 0 0 0 0 0 0\nGBQX1 771 2 1 0\n";
        for split in 0..=text.len() {
            let mut p = FirstCapture::default();
            let mut r = crate::ffi::TerminalRecord::default();
            p.push(&text[..split], (771, 9, 1), &mut r);
            p.push(&text[split..], (771, 9, 1), &mut r);
            assert_eq!(r.first.unwrap()[4], 34);
            assert_eq!(r.source.unwrap()[0], 101);
            assert_eq!(r.exits[1], Some([771, 2, 1, 0]));
            p.push(b"GBQF1 R 0 771 9 99 99 107 8 99 0 0 0 0 0\nGBQS1 107 1 0 0 0 0 0 0\nGBQX1 771 2 3 9\n",(771,9,1),&mut r);
            assert_eq!(r.first.unwrap()[4], 34);
            assert_eq!(r.source.unwrap()[0], 101);
            assert_eq!(r.exits[1], Some([771, 2, 1, 0]));
        }
        let mut p = FirstCapture::default();
        let mut r = crate::ffi::TerminalRecord::default();
        for bad in [
            "GBQX1 771 2 1 1\n",
            "GBQX1 771 1 1 0\n",
            "GBQX1 772 2 1 0\n",
            "GBQX1 771 2 3 0\n",
            "GBQX1 771 2 3 -1\n",
            "GBQX1 771 2 2 256\n",
            "GBQX1 771 2 3 129\n",
            "GBQX1 771 2 0 0\n",
            "GBQX1 771 2 2 1 extra\n",
            "GBQX1 771 2 2 18446744073709551616\n",
            "GBQF1 R 0 772 9 12 34 101 8 56 0 0 0 0 0\nGBQS1 101 1 0 0 0 0 0 0\n",
        ] {
            p.push(bad.as_bytes(), (771, 9, 1), &mut r);
        }
        p.push(&[b'x'; 1024], (771, 9, 1), &mut r);
        p.push(b"\n", (771, 9, 1), &mut r);
        assert!(r.first.is_none() && r.source.is_none() && r.exits.iter().all(Option::is_none));
        p.push(b"GBQX1 771 2 3 9", (771, 9, 1), &mut r);
        assert!(r.exits[1].is_none());
        p.push(b"\n", (771, 9, 1), &mut r);
        assert_eq!(r.exits[1], Some([771, 2, 3, 9]));
    }
    #[test]
    fn first_cause_exact_child_exit_signal_and_unavailable() {
        for signal in [false, true] {
            let command = OwnedCommand {
                program: if signal {
                    "/bin/sleep"
                } else {
                    "/usr/bin/true"
                }
                .into(),
                args: if signal { vec!["10".into()] } else { vec![] },
            };
            let mut child = OwnedChild::spawn(&command).unwrap();
            assert_eq!(
                child.first_cause().exits,
                [None; 2],
                "running/unobserved is unavailable, not exit zero"
            );
            child.first_identity = Some((773, 9, 2));
            if signal {
                child.child.as_mut().unwrap().kill().unwrap();
            }
            let until = Instant::now() + Duration::from_secs(1);
            while !child.exited().unwrap() {
                assert!(Instant::now() < until);
                std::thread::sleep(Duration::from_millis(1));
            }
            assert_eq!(
                child.first_cause().exits[0],
                Some(if signal {
                    [773, 2, 3, 9]
                } else {
                    [773, 2, 2, 0]
                })
            );
            assert!(child.cleanup().unwrap().complete);
        }
        let mut child = OwnedChild::spawn(&OwnedCommand {
            program: "/usr/bin/true".into(),
            args: vec![],
        })
        .unwrap();
        let until = Instant::now() + Duration::from_secs(1);
        while !child.exited().unwrap() {
            assert!(Instant::now() < until);
            std::thread::sleep(Duration::from_millis(1));
        }
        assert_eq!(child.first_cause().exits, [None; 2]);
        assert!(child.emit_first_cause().is_none());
        assert!(child.cleanup().unwrap().complete);
    }
    #[test]
    fn first_cause_exact_remote_environment_shape() {
        let helper = OwnedCommand {
            program: "adb".into(),
            args: [
                "-s",
                "selected",
                "shell",
                "-T",
                "/owned/helper",
                "--stdio-peer",
            ]
            .into_iter()
            .map(OsString::from)
            .collect(),
        };
        assert_eq!(
            helper.first_cause_helper().args,
            [
                "-s",
                "selected",
                "shell",
                "-T",
                "env",
                "GB_QUIC_FIRST_ERROR_DIAGNOSTICS=1",
                "/owned/helper",
                "--stdio-peer"
            ]
            .into_iter()
            .map(OsString::from)
            .collect::<Vec<_>>()
        );
        let unrelated = OwnedCommand {
            program: "adb".into(),
            args: ["shell", "-T", "app_process", "/", "server"]
                .into_iter()
                .map(OsString::from)
                .collect(),
        };
        assert_eq!(unrelated.first_cause_helper().args, unrelated.args);
    }
}
#[cfg(feature = "qa")]
#[derive(Default)]
struct QaControlCapture {
    partial: Vec<u8>,
    discard: bool,
    entries: std::collections::VecDeque<[u64; 8]>,
    accepted: u64,
    policy: Option<[u64; 32]>,
    policy_emitted: bool,
}
#[cfg(feature = "qa")]
impl QaControlCapture {
    fn push(&mut self, input: &[u8]) -> Vec<u8> {
        let mut source_lines = Vec::new();
        for &byte in input {
            if byte != b'\n' {
                let limit = if self.partial.starts_with(b"GBQHP1 ") {
                    800
                } else {
                    160
                };
                if !self.discard && self.partial.len() < limit {
                    self.partial.push(byte);
                } else {
                    self.partial.clear();
                    self.discard = true;
                }
                continue;
            }
            if !self.discard && self.policy.is_none() && self.partial.starts_with(b"GBQHP1 ") {
                if let Ok(text) = std::str::from_utf8(&self.partial[7..]) {
                    let mut values = [0u64; 32];
                    let mut words = text.split(' ');
                    let mut valid = true;
                    for value in &mut values {
                        let Some(word) = words.next() else {
                            valid = false;
                            break;
                        };
                        if word.is_empty() || !word.bytes().all(|b| b.is_ascii_digit()) {
                            valid = false;
                            break;
                        }
                        let Ok(n) = word.parse() else {
                            valid = false;
                            break;
                        };
                        *value = n;
                    }
                    if valid && words.next().is_none() {
                        self.policy = Some(values);
                    }
                }
            }
            if !self.discard && self.accepted < 64 && self.partial.starts_with(b"GBQC1 ") {
                if let Ok(text) = std::str::from_utf8(&self.partial[6..]) {
                    let words: Vec<_> = text.split(' ').collect();
                    if words.len() == 8
                        && words
                            .iter()
                            .all(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()))
                    {
                        let values: Option<Vec<u64>> =
                            words.iter().map(|s| s.parse().ok()).collect();
                        if let Some(v) = values {
                            if v[0] == self.accepted + 1
                                && (1..=2).contains(&v[1])
                                && (1..=262144).contains(&v[2])
                                && v[3] > 0
                            {
                                self.entries.push_back(v.try_into().unwrap());
                                self.accepted += 1;
                            }
                        }
                    }
                }
            }
            if !self.discard
                && self.partial.starts_with(b"GBQS1 ")
                && source_lines.len() + self.partial.len() < 2048
            {
                source_lines.extend_from_slice(&self.partial);
                source_lines.push(b'\n');
            }
            self.partial.clear();
            self.discard = false;
        }
        source_lines
    }
}
#[cfg(all(test, feature = "qa"))]
#[test]
fn qa_control_capture_is_ordered_fragmented_and_bounded() {
    let line = b"GBQC1 1 1 32 1 1 2 3 4\n";
    for split in 0..=line.len() {
        let mut capture = QaControlCapture::default();
        capture.push(&line[..split]);
        capture.push(&line[split..]);
        assert_eq!(capture.entries.pop_front(), Some([1, 1, 32, 1, 1, 2, 3, 4]));
        capture.push(line);
        assert!(capture.entries.is_empty());
    }
    let mut capture = QaControlCapture::default();
    capture.push(&vec![b'x'; 1000]);
    capture.push(b"\n");
    for ordinal in 1..=65 {
        capture.push(format!("GBQC1 {ordinal} 2 9 1 0 0 0 0\n").as_bytes());
    }
    assert_eq!(capture.entries.len(), 64);
    assert!(capture.partial.capacity() <= 256);
    let mut bad = QaControlCapture::default();
    for line in [
        "GBQC1 1 0 9 0 0 0 0\n",
        "GBQC1 1 1 0 0 0 0 0\n",
        "GBQC1 1 1 1 -1 0 0 0\n",
        "GBQC1 1 1 1 0 0 0 0 0\n",
    ] {
        bad.push(line.as_bytes());
    }
    assert!(bad.entries.is_empty());
}
#[cfg(all(test, feature = "qa"))]
#[test]
fn qa_policy_terminal_tuple_is_numeric_once_and_bounded() {
    let line = format!(
        "GBQHP1 {}\n",
        [u64::MAX; 32]
            .iter()
            .map(u64::to_string)
            .collect::<Vec<_>>()
            .join(" ")
    );
    assert!(line.len() < 800);
    for split in 0..=line.len() {
        let mut capture = QaControlCapture::default();
        capture.push(&line.as_bytes()[..split]);
        capture.push(&line.as_bytes()[split..]);
        assert_eq!(capture.policy, Some([u64::MAX; 32]));
        capture.push(b"GBQHP1 1\n");
        assert_eq!(capture.policy, Some([u64::MAX; 32]));
        assert!(capture.partial.capacity() <= 1024);
    }
    for bad in [
        line.replace("18446744073709551615", "-1"),
        line.replace("18446744073709551615", "18446744073709551616"),
        format!("{} 1\n", line.trim_end()),
        format!("GBQHP1 {}\n", "1 ".repeat(1000)),
    ] {
        let mut capture = QaControlCapture::default();
        capture.push(bad.as_bytes());
        assert_eq!(capture.policy, None);
    }
    let mut capture = QaControlCapture::default();
    capture.push(line.trim_end().as_bytes());
    assert_eq!(capture.policy, None, "truncation is unknown, never zero");
}
#[cfg(feature = "qa")]
struct QaSourceCapture {
    bytes: [u8; 2048],
    used: usize,
    emitted: bool,
}
#[cfg(feature = "qa")]
impl Default for QaSourceCapture {
    fn default() -> Self {
        Self {
            bytes: [0; 2048],
            used: 0,
            emitted: false,
        }
    }
}
#[cfg(feature = "qa")]
impl QaSourceCapture {
    fn push(&mut self, input: &[u8]) -> Option<[u64; 8]> {
        if self.emitted {
            return None;
        }
        let n = input.len().min(self.bytes.len() - self.used);
        self.bytes[self.used..self.used + n].copy_from_slice(&input[..n]);
        self.used += n;
        for line in self.bytes[..self.used].split_inclusive(|b| *b == b'\n') {
            if line.last() != Some(&b'\n') || !line.starts_with(b"GBQS1 ") {
                continue;
            }
            let Ok(text) = std::str::from_utf8(&line[6..line.len() - 1]) else {
                continue;
            };
            let mut values = [0u64; 8];
            let mut words = text.split(' ');
            let mut valid = true;
            for value in &mut values {
                let Some(word) = words.next() else {
                    valid = false;
                    break;
                };
                if word.is_empty() || !word.bytes().all(|b| b.is_ascii_digit()) {
                    valid = false;
                    break;
                }
                let Ok(parsed) = word.parse() else {
                    valid = false;
                    break;
                };
                *value = parsed;
            }
            if valid && words.next().is_none() && (101..=117).contains(&values[0]) && values[1] == 1
            {
                self.emitted = true;
                return Some(values);
            }
        }
        None
    }
}
#[cfg(all(test, feature = "qa"))]
#[test]
fn qa_source_capture_is_fragmented_numeric_once_and_hard_bounded() {
    let line = b"GBQS1 102 1 8 4096 0 0 2 8\n";
    for split in 0..line.len() {
        let mut capture = QaSourceCapture::default();
        assert_eq!(capture.push(&line[..split]), None);
        assert_eq!(
            capture.push(&line[split..]),
            Some([102, 1, 8, 4096, 0, 0, 2, 8])
        );
        assert_eq!(capture.push(line), None);
    }
    let mut capture = QaSourceCapture::default();
    assert_eq!(
        capture.push(b"GBQS1 102 1 8 -1 0 0 2 8\nGBQS1 102 1 8 1 0 0 2 8 extra\n"),
        None
    );
    assert_eq!(capture.push(&[b'x'; 2048]), None);
    assert_eq!(capture.used, 2048);
    assert_eq!(capture.push(line), None);
}
impl OwnedChild {
    pub fn spawn(command: &OwnedCommand) -> Result<Self, Error> {
        command.validate()?;
        Self::spawn_inner(command, None, OwnerSlot::acquire()?, false, false)
    }
    pub(crate) fn spawn_owned(command: &OwnedCommand, slot: OwnerSlot) -> Result<Self, Error> {
        Self::spawn_inner(command, None, slot, false, false)
    }
    pub(crate) fn spawn_recovery_helper(
        command: &OwnedCommand,
        slot: OwnerSlot,
    ) -> Result<Self, Error> {
        let enabled = std::env::var_os("GB_QUIC_RECOVERY_DIAGNOSTICS").is_some_and(|v| v == "1");
        let first = crate::ffi::first_cause_enabled();
        if !enabled && !first {
            return Self::spawn_owned(command, slot);
        }
        // Only the exact owned remote helper; producer/other children do not
        // inherit this opt-in. Original command validation remains in force.
        // Insert both exact-owned flags before env changes the positional shape.
        let mut transformed = if first {
            command.first_cause_helper()
        } else {
            command.clone()
        };
        if enabled {
            transformed = if first {
                if let Some(i) = transformed
                    .args
                    .iter()
                    .position(|a| a == "GB_QUIC_FIRST_ERROR_DIAGNOSTICS=1")
                {
                    transformed
                        .args
                        .insert(i, "GB_QUIC_RECOVERY_DIAGNOSTICS=1".into());
                }
                transformed
            } else {
                command.recovery_helper()
            };
        }
        let mut child = Self::spawn_inner(&transformed, None, slot, enabled, first)?;
        if first {
            child.first_capture = Some(Box::default());
        }
        Ok(child)
    }
    pub(crate) fn observe_first_cause(&mut self, generation: u64, target: u64, side: u64) {
        if crate::ffi::first_cause_enabled() {
            self.first_identity = Some((generation, target, side));
        }
    }
    pub(crate) fn observe_recovery(&mut self, generation: u64) {
        if std::env::var_os("GB_QUIC_RECOVERY_DIAGNOSTICS").is_some_and(|v| v == "1") {
            self.recovery_generation = generation;
            self.recovery_parser = Some(Box::default());
        }
    }
    pub(crate) fn spawn_producer(
        command: &OwnedCommand,
        jar: &std::path::Path,
        slot: OwnerSlot,
    ) -> Result<Self, Error> {
        Self::spawn_inner(command, Some(jar), slot, false, false)
    }
    fn spawn_inner(
        command: &OwnedCommand,
        classpath: Option<&std::path::Path>,
        slot: OwnerSlot,
        recovery: bool,
        first: bool,
    ) -> Result<Self, Error> {
        command.validate()?;
        let mut command_builder = Command::new(&command.program);
        command_builder
            .args(&command.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if recovery {
            command_builder.env("GB_QUIC_RECOVERY_DIAGNOSTICS", "1");
        } else {
            command_builder.env_remove("GB_QUIC_RECOVERY_DIAGNOSTICS");
        }
        if first {
            command_builder.env("GB_QUIC_FIRST_ERROR_DIAGNOSTICS", "1");
        } else {
            command_builder.env_remove("GB_QUIC_FIRST_ERROR_DIAGNOSTICS");
        }
        bitrate_environment(
            &mut command_builder,
            classpath.is_some(),
            std::env::var_os("GB_QUIC_RECOVERY_DIAGNOSTICS").is_some_and(|v| v == "1"),
        );
        if let Some(path) = classpath {
            command_builder.env("CLASSPATH", path);
        }
        let mut child = command_builder.spawn()?;
        let input = child.stdin.take().ok_or(Error::Io)?;
        let output = child.stdout.take().ok_or(Error::Io)?;
        let error = child.stderr.take().ok_or(Error::Io)?;
        for fd in [input.as_raw_fd(), output.as_raw_fd(), error.as_raw_fd()] {
            if let Err(e) = nonblocking(fd) {
                abandon(child, slot);
                return Err(e);
            }
        }
        Ok(Self {
            child: Some(child),
            slot,
            input: Some(input),
            output,
            error,
            stopping: None,
            report: Cleanup::default(),
            recovery_generation: 0,
            recovery_parser: None,
            first_capture: None,
            first_identity: None,
            first_record: Default::default(),
            first_emitted: false,
            #[cfg(feature = "qa")]
            cleanup_clock: None,
            #[cfg(feature = "qa")]
            source_capture: QaSourceCapture::default(),
            #[cfg(feature = "qa")]
            control_capture: QaControlCapture::default(),
        })
    }
    pub fn id(&self) -> u32 {
        self.child.as_ref().unwrap().id()
    }
    pub fn write(&mut self, b: &[u8]) -> Result<usize, Error> {
        let input = self.input.as_mut().ok_or(Error::Retired)?;
        match input.write(b) {
            Ok(0) => Err(Error::Io),
            Ok(n) => Ok(n),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => Ok(0),
            Err(_) => Err(Error::Io),
        }
    }
    pub fn read(&mut self, b: &mut [u8]) -> Result<Option<usize>, Error> {
        match self.output.read(b) {
            Ok(n) => Ok(Some(n)),
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => Ok(None),
            Err(_) => Err(Error::Io),
        }
    }
    pub fn drain_stderr(&mut self) -> Result<(), Error> {
        self.drain_stderr_observed(None)
    }
    pub(crate) fn take_send_stage(&mut self) -> Option<crate::recovery::SendStageLine> {
        self.recovery_parser.as_mut()?.take_stage()
    }
    pub(crate) fn take_progress(&mut self) -> Option<crate::progress::Line> {
        self.recovery_parser.as_mut()?.take_progress()
    }
    pub(crate) fn drain_stderr_observed(
        &mut self,
        mut trace: Option<&mut galaxybridge_quic_media::media::recovery_trace::Trace>,
    ) -> Result<(), Error> {
        let mut b = [0; 4096];
        for _ in 0..4 {
            match self.error.read(&mut b) {
                Ok(0) => {
                    if let Some(parser) = self.recovery_parser.as_mut() {
                        parser.finish();
                    }
                    break;
                }
                Ok(n) => {
                    if let (Some(parser), Some(identity)) =
                        (self.first_capture.as_mut(), self.first_identity)
                    {
                        parser.push(&b[..n], identity, &mut self.first_record);
                    }
                    if let Some(parser) = self.recovery_parser.as_mut() {
                        for &byte in &b[..n] {
                            if let Some(line) = parser.byte(byte, self.recovery_generation) {
                                let mut event = [0; 8];
                                event.copy_from_slice(&line.0[3..]);
                                if let Some(trace) = trace.as_deref_mut() {
                                    trace.push_foreign(
                                        galaxybridge_quic_media::media::recovery_trace::Event(
                                            event,
                                        ),
                                        line.0[2],
                                    );
                                }
                            }
                        }
                    }
                    #[cfg(feature = "qa")]
                    let source_lines = self.control_capture.push(&b[..n]);
                    #[cfg(feature = "qa")]
                    if !self.control_capture.policy_emitted {
                        if let Some(values) = self.control_capture.policy {
                            self.control_capture.policy_emitted = true;
                            eprintln!(
                                "qa-owned-source-policy {}",
                                values
                                    .iter()
                                    .map(u64::to_string)
                                    .collect::<Vec<_>>()
                                    .join(" ")
                            );
                        }
                    }
                    #[cfg(feature = "qa")]
                    if let Some(v) = self.source_capture.push(&source_lines) {
                        eprintln!("qa-owned-source code={} stage={} cacheAU={} cacheBytes={} receiverAU={} receiverBytes={} metadata={} metadataBytes={}",
                            v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]);
                    }
                    #[cfg(not(feature = "qa"))]
                    let _ = n;
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(_) => return Err(Error::Io),
            }
        }
        if let (Some(parser), Some(trace)) = (self.recovery_parser.as_mut(), trace.as_deref_mut()) {
            if let Some((accepted, rejected)) = parser.changed_rejections() {
                trace.update(galaxybridge_quic_media::media::recovery_trace::Event([
                    0, 0, 0, 0, 0, 1, accepted, rejected,
                ]));
            }
        }
        Ok(())
    }
    pub fn drain_stdout(&mut self) -> Result<(), Error> {
        let mut bytes = [0; 4096];
        for _ in 0..4 {
            match self.read(&mut bytes)? {
                None | Some(0) => break,
                Some(_) => {}
            }
        }
        Ok(())
    }
    #[cfg(feature = "qa")]
    pub fn qa_control_observation(&mut self) -> Option<[u64; 8]> {
        self.control_capture.entries.pop_front()
    }
    pub(crate) fn observe_display(
        &mut self,
        parser: &mut DisplayParser,
    ) -> Result<Vec<DisplayStatus>, Error> {
        let mut events = Vec::with_capacity(3);
        let mut bytes = [0; 4096];
        for _ in 0..4 {
            match self.read(&mut bytes) {
                Ok(None) => break,
                Ok(Some(0)) => {
                    events.extend(parser.finish());
                    break;
                }
                Ok(Some(n)) => events.extend(parser.push(&bytes[..n])),
                Err(error) => {
                    events.extend(parser.finish());
                    return Err(error);
                }
            }
        }
        Ok(events)
    }
    pub fn exited(&mut self) -> Result<bool, Error> {
        if self.report.complete {
            return Ok(true);
        }
        let status = self.child.as_mut().unwrap().try_wait()?;
        // Physical settlement and meeting the original observation ceiling
        // are independent. Never let a late first observation erase failure.
        if self
            .stopping
            .is_some_and(|start| self.cleanup_now().duration_since(start) >= Duration::from_secs(2))
        {
            self.report.failed = true;
        }
        if let Some(s) = status {
            self.report.complete = true;
            self.report.exit_code = s.code();
            if let Some((generation, _, side)) = self.first_identity {
                self.first_record.exits[0] = if let Some(code) = s.code() {
                    Some([generation, side, 2, code as u64])
                } else {
                    s.signal()
                        .map(|signal| [generation, side, 3, signal as u64])
                };
            }
            return Ok(true);
        }
        Ok(false)
    }
    pub fn stop(&mut self) {
        if self.stopping.is_none() {
            self.input = None;
            self.stopping = Some(Instant::now());
        }
    }
    pub fn cleanup(&mut self) -> Result<Cleanup, Error> {
        self.stop();
        let _ = self.drain_stderr();
        if self.exited()? {
            // Observe bytes written immediately before exit even when try_wait
            // becomes ready between the preceding drain and this check.
            let _ = self.drain_stderr();
            return Ok(self.report);
        }
        // Reserve the last half second for observing/reaping SIGKILL, rather
        // than beginning an unbounded wait after the two-second ceiling.
        let elapsed = self.cleanup_now().duration_since(self.stopping.unwrap());
        if elapsed >= Duration::from_millis(1500) && !self.report.forced {
            self.child.as_mut().unwrap().kill()?;
            self.report.forced = true;
        }
        if elapsed >= Duration::from_secs(2) {
            self.report.failed = true;
            return Err(Error::Cleanup);
        }
        Ok(self.report)
    }
    pub fn report(&self) -> Cleanup {
        self.report
    }
    pub(crate) fn first_cause(&self) -> crate::ffi::TerminalRecord {
        self.first_record
    }
    pub(crate) fn emit_first_cause(&mut self) -> Option<crate::ffi::TerminalTicket> {
        if self.first_emitted
            || (self.first_identity.is_none() && self.recovery_parser.is_none())
            || !self.report.complete
        {
            return None;
        }
        if let Some(parser) = self.recovery_parser.as_mut() {
            while let Some(line) = parser.take_progress() {
                self.first_record.progress[6 + line.0[3] as usize] = Some(line);
            }
        }
        let ticket = crate::ffi::terminal_offer(self.first_record);
        self.first_emitted = ticket.is_some();
        ticket
    }
    #[cfg(feature = "qa")]
    pub fn qa_first_source_error(&self) -> Option<[u64; 8]> {
        self.first_record.source.or_else(|| {
            QaSourceCapture::default().push(&self.source_capture.bytes[..self.source_capture.used])
        })
    }
    #[cfg(feature = "qa")]
    pub fn qa_first_cause(&self) -> (Option<[u64; 13]>, [Option<[u64; 4]>; 2]) {
        (self.first_record.first, self.first_record.exits)
    }
    fn cleanup_now(&self) -> Instant {
        #[cfg(feature = "qa")]
        if let Some(now) = self.cleanup_clock {
            return now;
        }
        Instant::now()
    }
    #[cfg(feature = "qa")]
    pub fn qa_cleanup_elapsed(&mut self, ns: u64) -> Result<(), Error> {
        let start = self.stopping.ok_or(Error::Protocol)?;
        let now = start
            .checked_add(Duration::from_nanos(ns))
            .ok_or(Error::Clock)?;
        if self.cleanup_clock.is_some_and(|old| now < old) {
            return Err(Error::Clock);
        }
        self.cleanup_clock = Some(now);
        Ok(())
    }
}
impl Drop for OwnedChild {
    fn drop(&mut self) {
        if self.report.complete {
            return;
        }
        self.input = None;
        if let Some(child) = self.child.take() {
            abandon(child, self.slot.clone());
        }
    }
}
pub(crate) fn nonblocking(fd: i32) -> Result<(), Error> {
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        if flags < 0
            || libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) < 0
            || libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) < 0
        {
            return Err(Error::Io);
        }
    }
    Ok(())
}
