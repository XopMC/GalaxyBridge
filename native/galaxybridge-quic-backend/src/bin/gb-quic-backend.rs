#[cfg(feature = "qa")]
use std::io::Read;
fn main() {
    let Ok(args): Result<Vec<_>, _> = std::env::args_os().map(|a| a.into_string()).collect() else {
        eprintln!("backend: invalid arguments");
        std::process::exit(2);
    };
    if args.len() > 64 || args.iter().map(|a| a.len() + 1).sum::<usize>() > 8192 {
        eprintln!("backend: invalid arguments");
        std::process::exit(2);
    }
    match args.get(1).map(String::as_str) {
        Some("--version") => println!("gb-quic-backend 0.1.0 GBP3 GQB1"),
        Some("--stdio-peer") => {
            let result = parse_peer(&args[2..]).and_then(run_peer);
            if result.is_err() {
                eprintln!("backend: peer failed");
                std::process::exit(1);
            }
        }
        #[cfg(feature = "qa")]
        Some("--stdio-fixture") => {
            if run_fixture(&args[2..]).is_err() {
                eprintln!("backend: component failed");
                std::process::exit(1);
            }
        }
        #[cfg(feature = "qa")]
        Some("--test-child-eof") => {
            let mut b = [0; 32];
            while let Ok(n) = std::io::stdin().read(&mut b) {
                if n == 0 {
                    break;
                }
            }
        }
        #[cfg(feature = "qa")]
        Some("--test-child-stall") => {
            std::thread::sleep(std::time::Duration::from_secs(10));
        }
        #[cfg(feature = "qa")]
        Some(
            mode @ ("--test-peer"
            | "--test-peer-identity"
            | "--test-peer-delayed-ack"
            | "--test-peer-source-failure"
            | "--test-peer-normal-eof"),
        ) => {
            if test_peer(mode).is_err() {
                eprintln!("backend: peer failed");
                std::process::exit(1);
            }
        }
        #[cfg(feature = "qa")]
        Some("--test-pair-fault") if args.len() == 3 => {
            let result = args[2]
                .parse::<u8>()
                .map_err(|_| galaxybridge_quic_backend::Error::Protocol)
                .and_then(test_pair_fault);
            if result.is_err() {
                eprintln!("backend: expected test peer terminal");
                std::process::exit(1);
            }
        }
        #[cfg(feature = "qa")]
        Some("--test-private-partial") if args.len() == 2 => {
            use std::io::Write;
            let mut out = std::io::stdout();
            let _ = out.write_all(&4096u32.to_be_bytes());
            for _ in 0..10 {
                let _ = out.write_all(&[0]);
                let _ = out.flush();
                std::thread::sleep(std::time::Duration::from_secs(1));
            }
        }
        _ => {
            eprintln!("backend: invalid arguments");
            std::process::exit(2);
        }
    }
}
#[cfg(feature = "qa")]
fn test_pair_fault(fault: u8) -> Result<(), galaxybridge_quic_backend::Error> {
    use galaxybridge_quic_backend::{bootstrap, owner::OwnerSlot, Backend, Error, Side};
    let slot = OwnerSlot::acquire()?;
    if fault > 4 {
        return Err(Error::Protocol);
    }
    let (binding, endpoints) = if matches!(fault, 1..=3) {
        bootstrap::accept_stdio_fault(fault)?
    } else {
        bootstrap::accept_stdio()?
    };
    let peer = Backend::from_channels(slot, Side::Peer, binding, endpoints, None)?;
    if fault == 0 {
        let until = std::time::Instant::now() + std::time::Duration::from_secs(10);
        while std::time::Instant::now() < until {
            if bootstrap::lifetime_eof()? {
                return Ok(());
            }
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        return Err(Error::Deadline);
    }
    run_owner(peer)
}

fn parse_launch(
    args: &[String],
) -> Result<
    (
        galaxybridge_quic_backend::stock::ProducerLaunch,
        Option<galaxybridge_quic_backend::stock::LaunchPolicy>,
    ),
    galaxybridge_quic_backend::Error,
> {
    use galaxybridge_quic_backend::{
        stock::{LaunchPolicy, ProducerLaunch},
        Error,
    };
    let (args, cleanup) = if args.len() >= 2 && args[args.len() - 2] == "--cleanup" {
        let value = match args.last().map(String::as_str) {
            Some("true") => true,
            Some("false") => false,
            _ => return Err(Error::Protocol),
        };
        (&args[..args.len() - 2], Some(value))
    } else {
        (args, None)
    };
    let (args, policy_args) = match args.iter().position(|s| s == "--launch-policy") {
        Some(at) => (&args[..at], &args[at..]),
        None => (args, &[][..]),
    };
    let policy = if policy_args.is_empty() {
        None
    } else {
        if !matches!(policy_args.len(), 2 | 4) {
            return Err(Error::Protocol);
        }
        let density = if policy_args.len() == 4 {
            if policy_args[2] != "--density"
                || policy_args[3].is_empty()
                || !policy_args[3].bytes().all(|b| b.is_ascii_digit())
            {
                return Err(Error::Protocol);
            }
            let n: u16 = policy_args[3].parse().map_err(|_| Error::Protocol)?;
            if n == 0 {
                return Err(Error::Protocol);
            }
            Some(n)
        } else {
            None
        };
        Some(match policy_args[1].as_str() {
            "primary" if density.is_none() => LaunchPolicy::Primary,
            "application" => LaunchPolicy::Application { density },
            "virtual-desktop" => LaunchPolicy::VirtualDesktop { density },
            _ => return Err(Error::Protocol),
        })
    };
    let policy = match (policy, cleanup) {
        (Some(policy), Some(cleanup)) => Some(policy.with_cleanup(cleanup)),
        (None, Some(_)) => return Err(Error::Protocol),
        (policy, None) => policy,
    };
    if args.len() < 12 || args.len() > 16 || args.len() % 2 != 0 {
        return Err(Error::Protocol);
    }
    for (i, key) in [
        "--producer",
        "--video-codec",
        "--max-size",
        "--max-fps",
        "--video-bit-rate",
        "--audio-bit-rate",
    ]
    .iter()
    .enumerate()
    {
        if args[i * 2] != *key {
            return Err(Error::Protocol);
        }
    }
    let positive = |s: &str| -> Result<u32, Error> {
        if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
            return Err(Error::Protocol);
        }
        let n = s.parse().map_err(|_| Error::Protocol)?;
        if n == 0 {
            return Err(Error::Protocol);
        }
        Ok(n)
    };
    let jar = std::path::PathBuf::from(&args[1]);
    if !jar.is_absolute()
        || jar == std::path::Path::new("/data/local/tmp/scrcpy-server.jar")
        || jar
            .components()
            .any(|c| matches!(c, std::path::Component::ParentDir))
    {
        return Err(Error::Protocol);
    }
    let hevc = match args[3].as_str() {
        "h264" => false,
        "h265" => true,
        _ => return Err(Error::Protocol),
    };
    let mut cursor = 12;
    let key_frame_interval_seconds =
        if args.get(cursor).map(String::as_str) == Some("--video-key-frame-interval-seconds") {
            let seconds: u16 = positive(args.get(cursor + 1).ok_or(Error::Protocol)?)?
                .try_into()
                .map_err(|_| Error::Protocol)?;
            cursor += 2;
            Some(seconds)
        } else {
            None
        };
    let new_display = if cursor < args.len() {
        if args.get(cursor).map(String::as_str) != Some("--new-display") {
            return Err(Error::Protocol);
        }
        let value = args.get(cursor + 1).ok_or(Error::Protocol)?;
        let (w, h) = value.split_once('x').ok_or(Error::Protocol)?;
        cursor += 2;
        Some((
            positive(w)?.try_into().map_err(|_| Error::Protocol)?,
            positive(h)?.try_into().map_err(|_| Error::Protocol)?,
        ))
    } else {
        None
    };
    if cursor != args.len() {
        return Err(Error::Protocol);
    }
    Ok((
        ProducerLaunch {
            jar,
            hevc,
            max_size: positive(&args[5])?
                .try_into()
                .map_err(|_| Error::Protocol)?,
            max_fps: positive(&args[7])?
                .try_into()
                .map_err(|_| Error::Protocol)?,
            video_bit_rate: positive(&args[9])?,
            audio_bit_rate: positive(&args[11])?,
            key_frame_interval_seconds,
            new_display,
        },
        policy,
    ))
}

fn parse_peer(
    args: &[String],
) -> Result<
    (
        galaxybridge_quic_backend::stock::ProducerLaunch,
        Option<galaxybridge_quic_backend::stock::LaunchPolicy>,
        Option<u64>,
    ),
    galaxybridge_quic_backend::Error,
> {
    use galaxybridge_quic_backend::Error;
    let (args, max_pacing_rate) =
        if args.first().map(String::as_str) == Some("--media-max-pacing-bytes-per-second") {
            let value = args.get(1).ok_or(Error::Protocol)?;
            if value.is_empty() || !value.bytes().all(|byte| byte.is_ascii_digit()) {
                return Err(Error::Protocol);
            }
            let rate = value.parse::<u64>().map_err(|_| Error::Protocol)?;
            if !(1_000_000..=20_000_000).contains(&rate) {
                return Err(Error::Protocol);
            }
            (&args[2..], Some(rate))
        } else {
            (args, None)
        };
    let (launch, policy) = parse_launch(args)?;
    Ok((launch, policy, max_pacing_rate))
}

#[cfg(test)]
mod launch_cleanup_tests {
    use super::*;
    fn args(tail: &[&str]) -> Vec<String> {
        [
            "--producer",
            "/data/local/tmp/approved.jar",
            "--video-codec",
            "h264",
            "--max-size",
            "1920",
            "--max-fps",
            "60",
            "--video-bit-rate",
            "20000000",
            "--audio-bit-rate",
            "128000",
        ]
        .into_iter()
        .chain(tail.iter().copied())
        .map(str::to_owned)
        .collect()
    }
    #[test]
    fn typed_cleanup_launch_accepts_both_values_and_rejects_other_tokens() {
        assert!(parse_launch(&args(&[])).is_ok());
        assert!(parse_launch(&args(&["--launch-policy", "primary"])).is_ok());
        let (periodic, _) = parse_launch(&args(&[
            "--video-key-frame-interval-seconds",
            "1",
            "--launch-policy",
            "primary",
        ]))
        .expect("typed periodic key-frame interval");
        assert_eq!(periodic.key_frame_interval_seconds, Some(1));
        assert!(parse_launch(&args(&[
            "--video-key-frame-interval-seconds",
            "0",
            "--launch-policy",
            "primary",
        ]))
        .is_err());
        for value in ["true", "false"] {
            assert!(
                parse_launch(&args(&["--launch-policy", "primary", "--cleanup", value])).is_ok(),
                "explicit cleanup={value}"
            );
        }
        for value in ["1", "0", "TRUE", "", "false extra"] {
            assert!(
                parse_launch(&args(&["--launch-policy", "primary", "--cleanup", value])).is_err()
            );
        }
        assert!(parse_launch(&args(&["--cleanup", "false"])).is_err());
        assert!(parse_launch(&args(&[
            "--launch-policy",
            "primary",
            "--cleanup",
            "false",
            "--cleanup",
            "true"
        ]))
        .is_err());
    }

    #[test]
    fn peer_media_pacing_is_optional_bounded_and_only_accepted_before_producer() {
        let base = args(&[]);
        let (_, _, pacing) = parse_peer(&base).expect("default peer");
        assert_eq!(pacing, None);

        let paced = [
            "--media-max-pacing-bytes-per-second".to_owned(),
            "2000000".to_owned(),
        ]
        .into_iter()
        .chain(base.clone())
        .collect::<Vec<_>>();
        let (_, _, pacing) = parse_peer(&paced).expect("paced peer");
        assert_eq!(pacing, Some(2_000_000));

        for invalid in ["", "999999", "20000001", "2mbps", "-1"] {
            let candidate = [
                "--media-max-pacing-bytes-per-second".to_owned(),
                invalid.to_owned(),
            ]
            .into_iter()
            .chain(base.clone())
            .collect::<Vec<_>>();
            assert!(parse_peer(&candidate).is_err(), "invalid rate={invalid}");
        }
        let misplaced = base
            .into_iter()
            .chain([
                "--media-max-pacing-bytes-per-second".to_owned(),
                "2000000".to_owned(),
            ])
            .collect::<Vec<_>>();
        assert!(parse_peer(&misplaced).is_err());
    }
}
fn run_peer(
    (launch, policy, max_pacing_rate): (
        galaxybridge_quic_backend::stock::ProducerLaunch,
        Option<galaxybridge_quic_backend::stock::LaunchPolicy>,
        Option<u64>,
    ),
) -> Result<(), galaxybridge_quic_backend::Error> {
    run_owner(
        galaxybridge_quic_backend::Backend::stdio_peer_with_policy_and_media_max_pacing_rate(
            launch,
            policy,
            max_pacing_rate,
        )?,
    )
}
#[cfg(feature = "qa")]
fn run_fixture(args: &[String]) -> Result<(), galaxybridge_quic_backend::Error> {
    use galaxybridge_quic_backend::{stock::PreparedFixture, Backend, Error};
    let started = std::time::Instant::now();
    if !matches!(args.len(), 6 | 8)
        || args[0] != "--fixture"
        || args[2] != "--sha256"
        || args[4] != "--duration-ms"
        || args[3].len() != 64
    {
        return Err(Error::Protocol);
    }
    let mut hash = [0; 32];
    for (i, pair) in args[3].as_bytes().chunks_exact(2).enumerate() {
        let s = std::str::from_utf8(pair).map_err(|_| Error::Protocol)?;
        hash[i] = u8::from_str_radix(s, 16).map_err(|_| Error::Protocol)?;
    }
    if !args[5].bytes().all(|b| b.is_ascii_digit()) {
        return Err(Error::Protocol);
    }
    let duration: u64 = args[5].parse().map_err(|_| Error::Protocol)?;
    if !(1..=30000).contains(&duration) {
        return Err(Error::Protocol);
    }
    let fixture = PreparedFixture::load(std::path::Path::new(&args[1]), hash)?;
    for (i, n) in fixture.access_units().into_iter().enumerate() {
        if fixture.enabled() & (1 << i) != 0 && n == 0 {
            return Err(Error::Protocol);
        }
    }
    let deadline = started
        .checked_add(std::time::Duration::from_millis(duration))
        .ok_or(Error::Clock)?;
    let scenario = if args.len() == 8 {
        if args[6] != "--display-scenario" {
            return Err(Error::Protocol);
        }
        Some(galaxybridge_quic_backend::owner::QaDisplayScenario::parse(
            &args[7],
        )?)
    } else {
        None
    };
    let mut owner = Backend::stdio_fixture(fixture, deadline)?;
    if let Some(scenario) = scenario {
        owner.qa_display_scenario(scenario)?;
    }
    run_owner(owner)
}
fn run_owner(
    mut peer: galaxybridge_quic_backend::Backend,
) -> Result<(), galaxybridge_quic_backend::Error> {
    use galaxybridge_quic_backend::{bootstrap, Error};
    use std::time::{Duration, Instant};
    let result = loop {
        match bootstrap::lifetime_eof() {
            Ok(true) => {
                peer.observe_lifetime_eof();
                break Ok(());
            }
            Ok(false) => {}
            Err(e) => break Err(e),
        }
        if let Err(e) = peer.poll() {
            break Err(e);
        }
        while peer.next_event().is_some() {}
        std::thread::sleep(peer.next_wakeup().min(Duration::from_millis(1)));
    };
    peer.retire(result.as_ref().err().copied().unwrap_or(Error::Retired));
    let cleanup_started = Instant::now();
    loop {
        if peer.cleanup()?.complete {
            if !terminal_drain_pending(peer.first_cause_pending(), cleanup_started.elapsed()) {
                return result;
            }
            // Diagnostic-only drain within the same original cutoff, after physical cleanup.
            std::thread::sleep(Duration::from_millis(1));
            continue;
        }
        if cleanup_started.elapsed() >= Duration::from_secs(2) {
            return Err(Error::Cleanup);
        }
        std::thread::sleep(Duration::from_millis(1));
    }
}
fn terminal_drain_pending(accepted_pending: bool, elapsed: std::time::Duration) -> bool {
    accepted_pending && elapsed < std::time::Duration::from_secs(2)
}
#[test]
fn first_cause_cleanup_drain_uses_original_cutoff_and_only_accepted_pending() {
    use std::time::Duration;
    for elapsed in [0, 1_999_999_999, 2_000_000_000, 2_000_000_001] {
        assert_eq!(
            terminal_drain_pending(true, Duration::from_nanos(elapsed)),
            elapsed < 2_000_000_000
        );
        assert!(!terminal_drain_pending(
            false,
            Duration::from_nanos(elapsed)
        ));
    }
}

#[cfg(feature = "qa")]
fn test_peer(mode: &str) -> Result<(), galaxybridge_quic_backend::Error> {
    use galaxybridge_quic_backend::{
        bootstrap, owner::OwnerSlot, stock::SocketGroup, Backend, Error, Side,
    };
    use std::{
        io::Write,
        os::unix::net::UnixStream,
        time::{Duration, Instant},
    };
    let slot = OwnerSlot::acquire()?;
    let (binding, endpoints) = bootstrap::accept_stdio()?;
    let (audio, mut producer_audio) = UnixStream::pair()?;
    let (control, mut producer_control) = UnixStream::pair()?;
    producer_control.set_nonblocking(true)?;
    let stock = SocketGroup::connected(None, Some(audio), control)?;
    if binding.context.enabled & 7 != 6 {
        return Err(Error::Unsupported);
    }
    let mut peer = Backend::from_channels(slot, Side::Peer, binding, endpoints, Some(stock))?;
    producer_audio.write_all(&[0; 65])?;
    producer_audio.write_all(&[
        0, 97, 97, 99, 64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0x11, 0x90, 0, 0, 0, 0, 0, 0, 0, 42, 0,
        0, 0, 3, 0x21, 0x10, 0x55,
    ])?;
    if mode == "--test-peer-source-failure" {
        // A real malformed stock reverse record fails the ordinary source service.
        // Neither a fabricated error return nor a diagnostic-only printf child.
        producer_control.write_all(&[255])?;
        return run_owner(peer);
    }
    if mode == "--test-peer-normal-eof" {
        return run_owner(peer);
    }
    let started = Instant::now();
    let mut pending = Vec::new();
    let mut ack_due = None;
    let mut second_config = false;
    while started.elapsed() < Duration::from_secs(10) {
        if bootstrap::lifetime_eof()? {
            peer.retire(Error::Retired);
            return Ok(());
        }
        peer.poll()?;
        while peer.next_event().is_some() {}
        if mode == "--test-peer-identity"
            && !second_config
            && started.elapsed() >= Duration::from_millis(300)
        {
            producer_audio.write_all(&[
                64, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0x11, 0x90, 0, 0, 0, 0, 0, 0, 0, 84, 0, 0, 0,
                3, 0x21, 0x10, 0x66,
            ])?;
            second_config = true;
        }
        let mut b = [0; 8192];
        match producer_control.read(&mut b) {
            Ok(0) => return Err(Error::Retired),
            Ok(n) => {
                if pending.len() + n > 262144 {
                    return Err(Error::Capacity);
                }
                pending.extend_from_slice(&b[..n]);
            }
            Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
            Err(_) => return Err(Error::Io),
        }
        if pending.len() >= 14 && pending[0] == 9 {
            let n = u32::from_be_bytes(pending[10..14].try_into().unwrap()) as usize + 14;
            if n > 262144 {
                return Err(Error::Protocol);
            }
            if pending.len() >= n {
                let due = *ack_due.get_or_insert_with(|| {
                    Instant::now()
                        + if mode == "--test-peer-delayed-ack" {
                            Duration::from_millis(1900)
                        } else {
                            Duration::ZERO
                        }
                });
                if Instant::now() < due {
                    std::thread::sleep(Duration::from_millis(1));
                    continue;
                }
                let mut ack = vec![1];
                ack.extend_from_slice(&pending[1..9]);
                producer_control.write_all(&ack)?;
                pending.drain(..n);
                ack_due = None;
            }
        }
        std::thread::sleep(peer.next_wakeup().min(Duration::from_millis(1)));
    }
    peer.retire(Error::Deadline);
    Err(Error::Deadline)
}
