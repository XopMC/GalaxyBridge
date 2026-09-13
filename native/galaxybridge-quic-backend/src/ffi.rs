//! ABI1. Pointer readability is the caller's obligation, never guessed here.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Header {
    pub abi: u32,
    pub size: u32,
    pub reserved: [u64; 2],
}
#[repr(C)]
#[derive(Clone, Copy)]
pub struct Slice {
    pub data: *const u8,
    pub length: usize,
}
#[repr(C)]
pub struct Config {
    pub h: Header,
    pub generation: u64,
    pub target_token: u64,
    pub scid: u32,
    pub display_id: u32,
    pub capture_kind: u8,
    pub enabled: u8,
    pub reserved0: u16,
    pub sidecar_sha: [u8; 32],
    pub peer_ip: Slice,
    pub program: Slice,
    pub args: *const Slice,
    pub argc: u32,
    pub reserved1: u32,
}
#[repr(C)]
pub struct Poll {
    pub h: Header,
    pub phase: u32,
    pub cleanup: u32,
    pub forced: u32,
    pub terminal: u32,
    pub now_ns: u64,
    pub cleanup_failed: u32,
}
#[repr(C)]
pub struct Input {
    pub h: Header,
    pub kind: u32,
    pub reserved: u32,
    pub received_ns: u64,
    pub bytes: Slice,
}
#[repr(C)]
pub struct DeviceEligibility {
    pub h: Header,
    pub effective_ns: u64,
    pub reverse_ns: u64,
    pub clipboard_ns: u64,
}
#[repr(C)]
pub struct Event {
    pub h: Header,
    pub kind: u32,
    pub code: u32,
    pub handle: u64,
    pub ticket: u64,
    pub ordinal: u64,
    pub track: u32,
    pub epoch: u32,
    pub config: u32,
    pub record_kind: u32,
    pub pts: u64,
    pub deadline_ns: u64,
    pub bytes: Slice,
    pub configuration: Slice,
    pub sequence: u64,
    pub receiver_owner: u64,
    pub generation: u64,
    pub target_token: u64,
    pub scid: u32,
    pub display_id: u32,
    pub flags: u32,
    pub capture_kind: u32,
    pub enabled: u32,
    pub session: [u8; 32],
}
use crate::{
    bootstrap::Binding,
    owner::{CopyLease, HostConfig, OwnerSlot},
    process::OwnedCommand,
    Backend, Error,
};
use galaxybridge_quic_media::media::OutputLease;
use std::{
    collections::{BTreeMap, BTreeSet},
    ffi::OsString,
    os::unix::ffi::OsStringExt,
    sync::{
        atomic::{AtomicU64, Ordering},
        Mutex, OnceLock,
    },
    thread::ThreadId,
};
enum Retained {
    Media {
        local: u64,
        lease: OutputLease,
    },
    Device {
        local: u64,
        _bytes: crate::bulk::Blob,
    },
    Scalar,
}
struct Entry {
    id: u64,
    thread: ThreadId,
    backend: Option<Backend>,
    _slot: OwnerSlot,
    leases: BTreeMap<u64, Retained>,
    copies: BTreeMap<u64, CopyLease>,
    pending: BTreeSet<(u32, u64)>,
    destroyed: bool,
    retirement_requested: bool,
    diagnostic_enabled: bool,
    diagnostic_reported: bool,
    diagnostic_identity: (u64, u64),
    #[cfg(test)]
    diagnostic_emitter: Option<std::sync::Arc<DiagnosticEmitter>>,
}
impl Entry {
    fn affinity(&self) -> Result<(), Error> {
        if self.thread != std::thread::current().id() {
            Err(Error::WrongThread)
        } else {
            Ok(())
        }
    }
    fn backend(&mut self) -> Result<&mut Backend, Error> {
        if self.destroyed {
            return Err(Error::Retired);
        }
        self.backend.as_mut().ok_or(Error::Retired)
    }
    fn reserve(&self, completion: bool) -> Result<(), Error> {
        if self.leases.len() + self.copies.len() + self.pending.len()
            >= if completion { 128 } else { 96 }
        {
            galaxybridge_quic_media::media::first_error::reject(
                4,
                line!(),
                self.leases.len() + self.copies.len() + self.pending.len(),
                if completion { 128 } else { 96 },
                1,
                0,
                0,
            );
            Err(Error::Capacity)
        } else {
            Ok(())
        }
    }
    fn reserve_progress(&self) -> Result<(), Error> {
        if self.leases.len() + self.copies.len() + self.pending.len() >= 112 {
            galaxybridge_quic_media::media::first_error::reject(
                4,
                line!(),
                self.leases.len() + self.copies.len() + self.pending.len(),
                112,
                1,
                0,
                0,
            );
            Err(Error::Capacity)
        } else {
            Ok(())
        }
    }
}
static REGISTRY: OnceLock<Mutex<Vec<Entry>>> = OnceLock::new();
static NEXT: AtomicU64 = AtomicU64::new(1);
#[cfg(feature = "qa")]
#[no_mangle]
pub extern "C" fn gb_backend_qa_time(owner: u64, ns: u64, cleanup: u32) -> u32 {
    boundary(|| {
        with_owner(owner, true, |e| {
            match cleanup {
                0 => e.backend()?.qa_local_time(ns)?,
                1 => e.backend()?.qa_cleanup_elapsed(ns)?,
                _ => return Err(Error::Protocol),
            }
            Ok(0)
        })
    })
}
#[cfg(feature = "qa")]
#[no_mangle]
pub extern "C" fn gb_backend_qa_component(
    owner: u64,
    duration_ms: u32,
    mode: u32,
    sequence: u64,
    index: u32,
) -> u32 {
    boundary(|| {
        let index: u16 = index.try_into().map_err(|_| Error::Protocol)?;
        with_owner(owner, true, |e| {
            e.backend()?
                .qa_component(duration_ms, mode, sequence, index)?;
            Ok(0)
        })
    })
}
#[cfg(feature = "qa")]
#[no_mangle]
pub unsafe extern "C" fn gb_backend_qa_dropped(owner: u64, dropped: *mut u64) -> u32 {
    boundary(|| {
        let dropped = output(dropped)?;
        with_owner(owner, true, |e| {
            *dropped = e.backend()?.qa_dropped();
            Ok(0)
        })
    })
}
fn registry() -> &'static Mutex<Vec<Entry>> {
    REGISTRY.get_or_init(|| Mutex::new(Vec::with_capacity(16)))
}
#[cfg(feature = "qa")]
#[no_mangle]
pub unsafe extern "C" fn gb_backend_qa_control_observation(owner: u64, values: *mut u64) -> u32 {
    boundary(|| {
        if values.is_null() {
            return Err(Error::Protocol);
        }
        with_owner(owner, true, |e| {
            if let Some(result) = e.backend()?.qa_control_observation() {
                std::ptr::copy_nonoverlapping(result.as_ptr(), values, result.len());
                Ok(0)
            } else {
                Ok(1)
            }
        })
    })
}
#[cfg(feature = "qa")]
#[no_mangle]
pub unsafe extern "C" fn gb_backend_qa_pools(owner: u64, values: *mut u64) -> u32 {
    boundary(|| {
        if values.is_null() {
            return Err(Error::Protocol);
        }
        with_owner(owner, true, |e| {
            let ((au_slots, au_bytes), (meta_slots, meta_bytes)) = e.backend()?.g1.receiver.usage();
            let mut result = [
                au_slots as u64,
                au_bytes as u64,
                meta_slots as u64,
                meta_bytes as u64,
                0,
                0,
                0,
                0,
            ];
            for copy in e.copies.values() {
                if let Some((au, bytes)) = copy.payload_shape {
                    let at = if au { 4 } else { 6 };
                    result[at] += 1;
                    result[at + 1] += bytes as u64;
                }
            }
            std::ptr::copy_nonoverlapping(result.as_ptr(), values, result.len());
            Ok(0)
        })
    })
}
fn id() -> Result<u64, Error> {
    allocate_id(&NEXT)
}
#[cfg(feature = "qa")]
#[no_mangle]
pub unsafe extern "C" fn gb_backend_qa_transfer_usage(owner: u64, values: *mut u64) -> u32 {
    boundary(|| {
        if values.is_null() {
            return Err(Error::Protocol);
        }
        with_owner(owner, true, |e| {
            let counts = e.backend()?.g1.receiver.payload_copy_usage();
            *values = counts[0] as u64;
            *values.add(1) = counts[1] as u64;
            Ok(0)
        })
    })
}
fn allocate_id(counter: &AtomicU64) -> Result<u64, Error> {
    counter
        .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| n.checked_add(1))
        .map_err(|_| Error::Capacity)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn explicit_retirement_cleanup_is_not_a_first_cause() {
        assert!(!should_emit_first_cause(0, false));
        assert!(!should_emit_first_cause(status(Error::Retired), true));
        assert!(should_emit_first_cause(status(Error::Retired), false));
        assert!(should_emit_first_cause(status(Error::Io), true));
    }
    fn actual_trace_poll(
        slot: std::sync::Arc<OnceLock<DiagnosticEmitter>>,
        entered: Option<std::sync::mpsc::SyncSender<()>>,
    ) -> (u32, u64) {
        let endpoints = std::array::from_fn(|i| {
            let mut endpoint = galaxybridge_quic::Endpoint::listen(
                "127.0.0.1:0".parse().unwrap(),
                "127.0.0.1".parse().unwrap(),
                [i as u8 + 7; 32],
                galaxybridge_quic::tls::Identity::generate().unwrap(),
                [1; 32],
            )
            .unwrap();
            endpoint.close();
            endpoint
        });
        let binding = Binding {
            nonce: [3; 32],
            sidecar_sha: [4; 32],
            context: galaxybridge_quic_media::Context {
                session: [7; 32],
                generation: 701,
                scid: 1,
                capture_kind: 0,
                display_id: 0,
                target_token: 702,
                enabled: 6,
            },
        };
        let mut backend = Backend::from_channels(
            OwnerSlot::acquire().unwrap(),
            crate::Side::Host,
            binding,
            endpoints,
            None,
        )
        .unwrap();
        backend.g1.receiver.recovery_trace = Some(Box::default());
        backend.g1.receiver.recovery_trace.as_mut().unwrap().push(
            galaxybridge_quic_media::media::recovery_trace::Event([6, 1, 1, 1, 1, 1, 0, 0]),
        );
        let owner = id().unwrap();
        let owner_slot = backend.slot.clone();
        registry().lock().unwrap().push(Entry {
            id: owner,
            thread: std::thread::current().id(),
            backend: Some(backend),
            _slot: owner_slot,
            leases: BTreeMap::new(),
            copies: BTreeMap::new(),
            pending: BTreeSet::new(),
            destroyed: false,
            retirement_requested: false,
            diagnostic_enabled: false,
            diagnostic_reported: false,
            diagnostic_identity: (701, 702),
            diagnostic_emitter: None,
        });
        TEST_TRACE_EMITTER.with(|s| *s.borrow_mut() = Some(slot));
        if let Some(entered) = entered {
            entered.send(()).unwrap();
        }
        let mut out = Poll {
            h: Header {
                abi: 1,
                size: std::mem::size_of::<Poll>() as u32,
                reserved: [0; 2],
            },
            phase: 0,
            cleanup: 0,
            forced: 0,
            terminal: 0,
            now_ns: 0,
            cleanup_failed: 0,
        };
        let result = unsafe { gb_backend_poll(owner, &mut out) };
        let suppressed = with_owner(owner, true, |e| {
            Ok(e.backend()?
                .g1
                .receiver
                .recovery_trace
                .as_ref()
                .unwrap()
                .suppressed as u32)
        })
        .unwrap();
        assert_eq!((result, out.terminal, out.cleanup), (107, 107, 1));
        assert_eq!(unsafe { gb_backend_destroy(owner) }, 0);
        TEST_TRACE_EMITTER.with(|s| *s.borrow_mut() = None);
        (result, suppressed as u64)
    }
    #[test]
    fn recovery_observation_actual_c_owner_cold_emitter_never_initializes() {
        let slot = std::sync::Arc::new(OnceLock::new());
        let (_, suppressed) = actual_trace_poll(slot.clone(), None);
        assert!(
            slot.get().is_none(),
            "cold hot-path trace must not create a worker under actual registry ownership"
        );
        assert!(suppressed > 0);
    }
    #[test]
    fn recovery_observation_actual_c_owner_does_not_wait_for_in_progress_emitter() {
        use std::sync::{mpsc, Arc};
        use std::time::Duration;
        let slot = Arc::new(OnceLock::new());
        let (ready, ready_rx) = mpsc::sync_channel(1);
        let (release, release_rx) = mpsc::sync_channel(1);
        let initializing = slot.clone();
        let worker = std::thread::spawn(move || {
            initializing.get_or_init(|| {
                ready.send(()).unwrap();
                release_rx.recv_timeout(Duration::from_secs(2)).unwrap();
                DiagnosticEmitter::start(Box::new(std::io::sink())).0
            });
        });
        ready_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let (entered, entered_rx) = mpsc::sync_channel(1);
        let (done, done_rx) = mpsc::sync_channel(1);
        let owner = std::thread::spawn(move || {
            done.send(actual_trace_poll(slot, Some(entered))).unwrap();
        });
        entered_rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let result = done_rx.recv_timeout(Duration::from_millis(100));
        let registry_available = registry().try_lock().is_ok();
        release.send(()).unwrap();
        worker.join().unwrap();
        owner.join().unwrap();
        assert!(result.is_ok(),"actual C poll waited for an in-progress diagnostic initializer; registry_available={registry_available}");
        assert!(registry_available);
        assert!(result.unwrap().1 > 0);
    }
    #[test]
    fn exhausted_ids_never_wrap_reuse_or_become_zero() {
        let counter = AtomicU64::new(u64::MAX - 1);
        assert_eq!(allocate_id(&counter).unwrap(), u64::MAX - 1);
        assert_eq!(allocate_id(&counter), Err(Error::Capacity));
        assert_eq!(allocate_id(&counter), Err(Error::Capacity));
        assert_eq!(counter.load(Ordering::SeqCst), u64::MAX);
    }
    #[test]
    fn actual_registry_quota_counts_all_retained_handle_classes() {
        let mut e = Entry {
            id: 1,
            thread: std::thread::current().id(),
            backend: None,
            _slot: OwnerSlot::acquire().unwrap(),
            leases: BTreeMap::new(),
            copies: BTreeMap::new(),
            pending: BTreeSet::new(),
            destroyed: true,
            retirement_requested: false,
            diagnostic_enabled: false,
            diagnostic_reported: false,
            diagnostic_identity: (0, 0),
            diagnostic_emitter: None,
        };
        for i in 0..96 {
            e.reserve(false).unwrap();
            e.leases.insert(i, Retained::Scalar);
        }
        assert_eq!(e.reserve(false), Err(Error::Capacity));
        for i in 96..112 {
            e.reserve_progress().unwrap();
            e.pending.insert((1, i));
        }
        assert_eq!(e.reserve_progress(), Err(Error::Capacity));
        for i in 112..128 {
            e.reserve(true).unwrap();
            e.leases.insert(i, Retained::Scalar);
        }
        assert_eq!(e.reserve(true), Err(Error::Capacity));
        assert!(e.leases.remove(&0).is_some());
        assert!(e.leases.remove(&0).is_none());
        e.reserve(true).unwrap();
        assert_eq!(e.reserve_progress(), Err(Error::Capacity));
    }

    #[test]
    fn first_error_actual_owner_latches_capacity_once() {
        let owner = id().unwrap();
        let entry = Entry {
            id: owner,
            thread: std::thread::current().id(),
            backend: None,
            _slot: OwnerSlot::acquire().unwrap(),
            leases: BTreeMap::new(),
            copies: BTreeMap::new(),
            pending: (0..96).map(|n| (1, n)).collect(),
            destroyed: false,
            retirement_requested: false,
            diagnostic_enabled: true,
            diagnostic_reported: false,
            diagnostic_identity: (701, 702),
            diagnostic_emitter: None,
        };
        registry().lock().unwrap().push(entry);
        assert_eq!(
            with_owner(owner, true, |e| {
                e.reserve(false)?;
                Ok(0)
            }),
            Err(Error::Capacity)
        );
        assert!(
            registry()
                .lock()
                .unwrap()
                .iter()
                .find(|e| e.id == owner)
                .unwrap()
                .diagnostic_reported
        );
        // A later different error and a successful cleanup cannot emit again.
        assert_eq!(
            with_owner(owner, true, |_| Err(Error::Protocol)),
            Err(Error::Protocol)
        );
        with_owner(owner, true, |e| {
            e.pending.clear();
            e.destroyed = true;
            Ok(0)
        })
        .unwrap();
        assert!(!registry().lock().unwrap().iter().any(|e| e.id == owner));
    }

    #[test]
    fn full_diagnostic_sink_cannot_delay_actual_owner_return() {
        use std::io::{Read, Write};
        use std::os::unix::net::UnixStream;
        use std::sync::{mpsc, Arc};
        use std::time::Duration;
        let (mut writer, mut reader) = UnixStream::pair().unwrap();
        writer.set_nonblocking(true).unwrap();
        let fill = [0; 4096];
        let mut filled = 0;
        loop {
            match writer.write(&fill) {
                Ok(n) => {
                    assert!(n > 0);
                    filled += n;
                    assert!(filled < 1024 * 1024);
                }
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                Err(e) => panic!("test sink fill: {e}"),
            }
        }
        assert!(filled > 0);
        writer.set_nonblocking(false).unwrap();
        let (emitter, worker) = DiagnosticEmitter::start(Box::new(writer));
        let emitter = Arc::new(emitter);
        let owner_emitter = emitter.clone();
        let (tx, rx) = mpsc::sync_channel(1);
        let thread = std::thread::spawn(move || {
            let owner = id().unwrap();
            registry().lock().unwrap().push(Entry {
                id: owner,
                thread: std::thread::current().id(),
                backend: None,
                _slot: OwnerSlot::acquire().unwrap(),
                leases: BTreeMap::new(),
                copies: BTreeMap::new(),
                pending: (0..96).map(|n| (1, n)).collect(),
                destroyed: false,
                retirement_requested: false,
                diagnostic_enabled: true,
                diagnostic_reported: false,
                diagnostic_identity: (801, 802),
                diagnostic_emitter: Some(owner_emitter),
            });
            let result = with_owner(owner, true, |e| {
                e.reserve(false)?;
                Ok(0)
            });
            tx.send(result).unwrap();
            with_owner(owner, true, |e| {
                e.pending.clear();
                e.destroyed = true;
                Ok(0)
            })
            .unwrap();
        });
        let before = rx.recv_timeout(Duration::from_millis(250));
        // Drain the exact owned full socket before any assertion can unwind.
        let mut drain = vec![0; filled];
        reader.read_exact(&mut drain).unwrap();
        let result = match before {
            Ok(r) => r,
            Err(_) => rx.recv_timeout(Duration::from_secs(2)).unwrap(),
        };
        thread.join().unwrap();
        drop(emitter);
        worker.unwrap().join().unwrap();
        assert_eq!(result, Err(Error::Capacity));
        assert!(
            before.is_ok(),
            "original C owner result waited for a diagnostic sink drain"
        );
    }

    #[test]
    fn diagnostic_handoff_full_and_unavailable_drop_without_retry() {
        let (sender, receiver) = std::sync::mpsc::sync_channel(1);
        let emitter = DiagnosticEmitter {
            sender,
            trace: std::sync::Arc::new(std::sync::Mutex::new(None)),
            alive: std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true)),
            wake: None,
        };
        assert!(emitter.offer(DiagnosticRecord([0; 13])));
        assert!(!emitter.offer(DiagnosticRecord([1; 13])));
        assert!(
            matches!(receiver.try_recv().unwrap(),HighDiagnostic::First(DiagnosticRecord(v)) if v==[0;13])
        );
        drop(receiver);
        assert!(!emitter.offer(DiagnosticRecord([2; 13])));
    }
    #[test]
    fn recovery_observation_wakes_idle_sink_without_a_first_error() {
        use std::sync::mpsc;
        use std::time::Duration;
        struct Sink(mpsc::SyncSender<Vec<u8>>);
        impl std::io::Write for Sink {
            fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
                self.0.send(bytes.to_vec()).unwrap();
                Ok(bytes.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let (sent, received) = mpsc::sync_channel(1);
        let (emitter, worker) = DiagnosticEmitter::start(Box::new(Sink(sent)));
        assert!(emitter.offer_trace([9, 1, 1, 1, 1, 1, 1, 20, 1, 2, 0]));
        // No high-priority error or terminal is sent: admitting a ready trace
        // must itself wake the writer, not wait for its 500 ms idle timeout.
        let observation = received.recv_timeout(Duration::from_millis(200));
        drop(emitter);
        worker.unwrap().join().unwrap();
        assert!(observation.is_ok(), "ready recovery trace waited for the idle timeout");
        assert!(observation.unwrap().starts_with(b"GBQR1 9 1 1 1 "));
    }
    #[test]
    fn recovery_and_progress_wake_across_the_empty_check_park_boundary() {
        use std::sync::{mpsc, Arc, atomic::{AtomicU64, Ordering}};
        use std::time::{Duration, Instant};
        struct Sink(mpsc::SyncSender<Vec<u8>>);
        impl std::io::Write for Sink {
            fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
                self.0.send(bytes.to_vec()).unwrap();
                Ok(bytes.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let (sent, received) = mpsc::sync_channel(1);
        let at_idle_boundary = Arc::new(AtomicU64::new(0));
        let idle = at_idle_boundary.clone();
        let (emitter, worker) = DiagnosticEmitter::start_observing_idle(
            Box::new(Sink(sent)),
            move || { idle.fetch_add(1, Ordering::Release); },
        );
        let wait_for_idle = |count| {
            let deadline = Instant::now() + Duration::from_secs(1);
            while at_idle_boundary.load(Ordering::Acquire) < count {
                assert!(Instant::now() < deadline, "writer did not become idle");
                std::thread::yield_now();
            }
        };
        wait_for_idle(1);
        let trace_accepted = emitter.offer_trace([9, 1, 1, 1, 1, 1, 1, 20, 1, 2, 0]);
        let trace = received.recv_timeout(Duration::from_millis(200));
        // Observe after both queues were checked empty without parking inside
        // the observer itself, which would consume the thread's unpark token.
        let (progress_accepted, progress) = if trace.is_ok() {
            wait_for_idle(2);
            let accepted = emitter.offer_low(LowDiagnostic::SendStage(
                crate::recovery::SendStageLine([2; 23]),
            ));
            (accepted, received.recv_timeout(Duration::from_millis(200)))
        } else {
            (false, Err(mpsc::RecvTimeoutError::Timeout))
        };
        drop(emitter);
        drop(at_idle_boundary);
        worker.unwrap().join().unwrap();
        assert!(trace_accepted && trace.is_ok(), "trace did not wake parked writer");
        assert!(progress_accepted && progress.is_ok(), "progress did not wake parked writer");
        assert!(trace.unwrap().starts_with(b"GBQR1 9 1 1 1 "));
        assert!(progress.unwrap().starts_with(b"GBQD1 2 "));
    }
    #[test]
    fn recovery_observation_saturated_low_sink_preserves_first_error_admission() {
        use std::sync::{mpsc, Arc, Mutex};
        use std::time::{Duration, Instant};
        struct Sink {
            entered: mpsc::SyncSender<()>,
            release: mpsc::Receiver<()>,
            first: bool,
            bytes: Arc<Mutex<Vec<u8>>>,
        }
        impl std::io::Write for Sink {
            fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
                if self.first {
                    self.first = false;
                    self.entered.send(()).unwrap();
                    self.release.recv_timeout(Duration::from_secs(2)).unwrap();
                }
                self.bytes.lock().unwrap().extend_from_slice(b);
                Ok(b.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let (entered, rx) = mpsc::sync_channel(1);
        let (release, gate) = mpsc::sync_channel(1);
        let bytes = Arc::new(Mutex::new(vec![]));
        let (emitter, worker) = DiagnosticEmitter::start(Box::new(Sink {
            entered,
            release: gate,
            first: true,
            bytes: bytes.clone(),
        }));
        assert!(emitter.offer_trace([1; 11]));
        rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let before = Instant::now();
        assert!(
            emitter.offer_low(LowDiagnostic::SendStage(crate::recovery::SendStageLine(
                [2; 23]
            )))
        );
        assert!(!emitter.offer_trace([3; 11]));
        assert!(emitter.offer(DiagnosticRecord([4; 13])));
        assert!(!emitter.offer(DiagnosticRecord([5; 13])));
        assert!(
            before.elapsed() < Duration::from_millis(100),
            "blocked trace sink cannot block owner offers"
        );
        release.send(()).unwrap();
        drop(emitter);
        worker.unwrap().join().unwrap();
        let result = String::from_utf8(bytes.lock().unwrap().clone()).unwrap();
        let lines: Vec<_> = result.lines().collect();
        assert_eq!(lines.len(), 3);
        assert!(lines[0].starts_with("GBQR1 1 "));
        assert!(lines[1].starts_with("GBQF1 R 4 "));
        assert!(lines[2].starts_with("GBQD1 2 "));
    }
    #[test]
    fn recovery_trace_keeps_one_bounded_flush_batch_through_slow_sink() {
        use std::sync::{mpsc, Arc, Mutex};
        use std::time::{Duration, Instant};
        struct Sink {
            entered: mpsc::SyncSender<()>,
            release: mpsc::Receiver<()>,
            first: bool,
            bytes: Arc<Mutex<Vec<u8>>>,
        }
        impl std::io::Write for Sink {
            fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
                if self.first {
                    self.first = false;
                    self.entered.send(()).unwrap();
                    self.release.recv_timeout(Duration::from_secs(2)).unwrap();
                }
                self.bytes.lock().unwrap().extend_from_slice(b);
                Ok(b.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let (entered, rx) = mpsc::sync_channel(1);
        let (release, gate) = mpsc::sync_channel(1);
        let bytes = Arc::new(Mutex::new(vec![]));
        let (emitter, worker) = DiagnosticEmitter::start(Box::new(Sink {
            entered,
            release: gate,
            first: true,
            bytes: bytes.clone(),
        }));
        assert!(emitter.offer(DiagnosticRecord([90; 13])));
        rx.recv_timeout(Duration::from_secs(1)).unwrap();
        let started = Instant::now();
        let mut accepted = 0;
        for ordinal in 1..=60 {
            accepted += usize::from(emitter.offer_trace([9, 2, ordinal, 9, 1, 1, 1, 8, 3, 1, 100]));
        }
        let full = !emitter.offer_trace([9, 2, 61, 9, 1, 1, 1, 8, 3, 1, 100]);
        let high = emitter.offer(DiagnosticRecord([91; 13]));
        let nonblocking = started.elapsed() < Duration::from_millis(100);
        // Release and join even when the predecessor accepts only one record.
        release.send(()).unwrap();
        drop(emitter);
        worker.unwrap().join().unwrap();
        assert_eq!(
            accepted, 60,
            "one flush must preserve its bounded causal batch"
        );
        assert!(full && high && nonblocking);
        let result = String::from_utf8(bytes.lock().unwrap().clone()).unwrap();
        let lines: Vec<_> = result.lines().collect();
        assert_eq!(lines.len(), 62);
        assert!(lines[0].starts_with("GBQF1 R 90 "));
        assert!(lines[1].starts_with("GBQF1 R 91 "));
        let mut parser = crate::recovery::TraceParser::default();
        for ordinal in 1..=60 {
            let mut decoded = None;
            for b in lines[ordinal + 1].bytes().chain(std::iter::once(b'\n')) {
                decoded = decoded.or_else(|| parser.byte(b, 9));
            }
            assert_eq!(decoded.unwrap().0[2], ordinal as u64);
        }
        assert_eq!((parser.accepted, parser.rejected), (60, 0));
    }

    #[test]
    fn recovery_batch_yields_to_terminal_arriving_after_first_low_line() {
        use std::sync::{atomic::Ordering, mpsc, Arc, Mutex};
        use std::time::Duration;
        struct Sink {
            entered: mpsc::SyncSender<u8>,
            release: mpsc::Receiver<()>,
            high: bool,
            low: bool,
            bytes: Arc<Mutex<Vec<u8>>>,
        }
        impl std::io::Write for Sink {
            fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
                let stage = if self.high {
                    self.high = false;
                    Some(1)
                } else if self.low && b.starts_with(b"GBQR1") {
                    self.low = false;
                    Some(2)
                } else {
                    None
                };
                if let Some(stage) = stage {
                    self.entered.send(stage).unwrap();
                    self.release.recv_timeout(Duration::from_secs(2)).unwrap();
                }
                self.bytes.lock().unwrap().extend_from_slice(b);
                Ok(b.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let (entered, rx) = mpsc::sync_channel(1);
        let (release, gate) = mpsc::sync_channel(1);
        let bytes = Arc::new(Mutex::new(vec![]));
        let (emitter, worker) = DiagnosticEmitter::start(Box::new(Sink {
            entered,
            release: gate,
            high: true,
            low: true,
            bytes: bytes.clone(),
        }));
        assert!(emitter.offer(DiagnosticRecord([90; 13])));
        assert_eq!(rx.recv_timeout(Duration::from_secs(1)).unwrap(), 1);
        for ordinal in 1..=60 {
            assert!(emitter.offer_trace([9, 2, ordinal, 9, 1, 1, 1, 8, 3, 1, 100]));
        }
        release.send(()).unwrap();
        assert_eq!(rx.recv_timeout(Duration::from_secs(1)).unwrap(), 2);
        let ticket = emitter
            .offer_terminal(TerminalRecord {
                exits: [Some([9, 2, 1, 0]), None],
                ..Default::default()
            })
            .unwrap();
        release.send(()).unwrap();
        drop(emitter);
        worker.unwrap().join().unwrap();
        assert!(ticket.load(Ordering::Acquire));
        let result = String::from_utf8(bytes.lock().unwrap().clone()).unwrap();
        let lines: Vec<_> = result.lines().collect();
        assert_eq!(lines.len(), 62);
        assert!(lines[1].starts_with("GBQR1 9 2 1 "));
        assert_eq!(
            lines[2], "GBQX1 9 2 1 0",
            "late terminal precedes the next low record"
        );
        assert!(lines[3].starts_with("GBQR1 9 2 2 "));
    }

    #[test]
    fn progress_bounded_emitter_exports_numeric_line_and_rejects_busy_slot() {
        use std::sync::{Arc, Mutex};
        struct Sink(Arc<Mutex<Vec<u8>>>);
        impl std::io::Write for Sink {
            fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
                self.0.lock().unwrap().extend_from_slice(b);
                Ok(b.len())
            }
            fn flush(&mut self) -> std::io::Result<()> {
                Ok(())
            }
        }
        let bytes = Arc::new(Mutex::new(vec![]));
        let (emitter, worker) = DiagnosticEmitter::start(Box::new(Sink(bytes.clone())));
        let line = crate::progress::Line::without_pressure([
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
        let guard = emitter.trace.lock().unwrap();
        assert!(
            !emitter.offer_low(LowDiagnostic::Progress(line)),
            "owner uses try_lock"
        );
        drop(guard);
        assert!(emitter.offer_low(LowDiagnostic::Progress(line)));
        let until = std::time::Instant::now() + std::time::Duration::from_secs(2);
        while bytes.lock().unwrap().is_empty() {
            assert!(std::time::Instant::now() < until);
            std::thread::sleep(std::time::Duration::from_millis(1));
        }
        drop(emitter);
        worker.unwrap().join().unwrap();
        assert_eq!(*bytes.lock().unwrap(), line.encode());
    }
}
#[track_caller]
fn with_owner(
    owner: u64,
    affinity: bool,
    f: impl FnOnce(&mut Entry) -> Result<u32, Error>,
) -> Result<u32, Error> {
    let mut entries = registry().lock().map_err(|_| Error::Retired)?;
    let e = entries
        .iter_mut()
        .find(|e| e.id == owner)
        .ok_or(Error::InvalidHandle)?;
    if affinity {
        e.affinity()?;
    }
    use galaxybridge_quic_media::media::first_error;
    let scope = first_error::Scope::begin(e.diagnostic_enabled && !e.diagnostic_reported);
    let result = f(e);
    if let Err(error) = result {
        first_error::error(status(error));
    }
    // Polling an explicitly retired owner is part of the required cleanup
    // contract. Keep status 107 as the public return value, but do not let
    // that expected cleanup poll consume the one-shot first-cause record.
    let requested_retirement = e.retirement_requested;
    let observed = scope
        .observation()
        .filter(|o| should_emit_first_cause(o.status, requested_retirement));
    let identity = e.diagnostic_identity;
    #[cfg(test)]
    let test_emitter = e.diagnostic_emitter.clone();
    if observed.is_some() {
        e.diagnostic_reported = true;
    }
    drop(scope);
    entries.retain(|e| !(e.destroyed && e.leases.is_empty() && e.copies.is_empty()));
    drop(entries);
    if let Some(o) = observed {
        let record = first_error_record(owner, identity, std::panic::Location::caller().line(), o);
        #[cfg(test)]
        if let Some(emitter) = test_emitter {
            emitter.offer(record);
            return result;
        }
        diagnostic_emitter().offer(record);
    }
    result
}
fn should_emit_first_cause(observed_status: u32, retirement_requested: bool) -> bool {
    observed_status != 0 && !(retirement_requested && observed_status == status(Error::Retired))
}
#[derive(Clone, Copy)]
struct DiagnosticRecord([u64; 13]);
impl DiagnosticRecord {
    fn write(&self, sink: &mut dyn std::io::Write) -> std::io::Result<()> {
        let v = self.0;
        let line = format!(
            "GBQF1 R {} {} {} {} {} {} {} {} {} {} {} {} {}\n",
            v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10], v[11], v[12]
        );
        sink.write_all(line.as_bytes())
    }
}
struct DiagnosticEmitter {
    sender: std::sync::mpsc::SyncSender<HighDiagnostic>,
    trace: std::sync::Arc<std::sync::Mutex<Option<LowDiagnostic>>>,
    alive: std::sync::Arc<std::sync::atomic::AtomicBool>,
    wake: Option<std::thread::Thread>,
}
#[derive(Clone, Copy)]
enum LowDiagnostic {
    Recovery(RecoveryBatch),
    SendStage(crate::recovery::SendStageLine),
    Progress(crate::progress::Line),
}
/// At most one ring-sized numeric batch queued and one in service. No media
/// references, heap growth, additional worker or change to the 512-line cap.
#[derive(Clone, Copy)]
struct RecoveryBatch {
    records: [[u64; 11]; 60],
    used: usize,
}
#[derive(Clone, Copy, Debug, Default)]
pub(crate) struct TerminalRecord {
    pub first: Option<[u64; 13]>,
    pub source: Option<[u64; 8]>,
    pub exits: [Option<[u64; 4]>; 2],
    pub progress: [Option<crate::progress::Line>; 12],
}
impl TerminalRecord {
    fn write(&self, sink: &mut dyn std::io::Write) -> std::io::Result<()> {
        if let Some(v) = self.first {
            DiagnosticRecord(v).write(sink)?;
        }
        if let Some(v) = self.source {
            writeln!(
                sink,
                "GBQS1 {} {} {} {} {} {} {} {}",
                v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]
            )?;
        }
        for v in self.exits.into_iter().flatten() {
            writeln!(sink, "GBQX1 {} {} {} {}", v[0], v[1], v[2], v[3])?;
        }
        for line in self.progress.into_iter().flatten() {
            sink.write_all(&line.encode())?;
        }
        Ok(())
    }
}
pub(crate) type TerminalTicket = std::sync::Arc<std::sync::atomic::AtomicBool>;
enum HighDiagnostic {
    First(DiagnosticRecord),
    Terminal(TerminalRecord, TerminalTicket),
}
impl HighDiagnostic {
    fn write(self, sink: &mut dyn std::io::Write) {
        match self {
            Self::First(r) => {
                let _ = r.write(sink);
            }
            Self::Terminal(r, done) => {
                let _ = r.write(sink);
                done.store(true, std::sync::atomic::Ordering::Release);
            }
        }
    }
}
impl DiagnosticEmitter {
    fn start(
        sink: Box<dyn std::io::Write + Send>,
    ) -> (Self, Option<std::thread::JoinHandle<()>>) {
        Self::start_observing_idle(sink, || {})
    }
    fn start_observing_idle(
        mut sink: Box<dyn std::io::Write + Send>,
        mut on_idle: impl FnMut() + Send + 'static,
    ) -> (Self, Option<std::thread::JoinHandle<()>>) {
        // One process-wide worker, one queued and one in-service fixed scalar
        // envelope. Recovery groups at most one 60-record owner flush instead
        // of losing all but its first line while the sink worker is asleep.
        // Terminal/first-cause priority and the one low slot stay unchanged.
        let (sender, receiver) = std::sync::mpsc::sync_channel::<HighDiagnostic>(1);
        let trace = std::sync::Arc::new(std::sync::Mutex::new(None::<LowDiagnostic>));
        let low = trace.clone();
        let alive = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(true));
        let running = alive.clone();
        let worker = std::thread::Builder::new()
            .name("gb-first-error".into())
            .spawn(move || {
                struct Running(std::sync::Arc<std::sync::atomic::AtomicBool>);
                impl Drop for Running {
                    fn drop(&mut self) {
                        self.0.store(false, std::sync::atomic::Ordering::Release);
                    }
                }
                let _running = Running(running);
                loop {
                    let disconnected = loop {
                        match receiver.try_recv() {
                            Ok(record) => record.write(sink.as_mut()),
                            Err(std::sync::mpsc::TryRecvError::Empty) => break false,
                            Err(std::sync::mpsc::TryRecvError::Disconnected) => break true,
                        }
                    };
                    let record = low.lock().unwrap().take();
                    let Some(record) = record else {
                        if disconnected {
                            break;
                        }
                        // Both queues wake this worker. An unpark token persists
                        // across the empty-check/park race; no media owner waits
                        // for the sink or spends a high-priority queue slot on it.
                        on_idle();
                        std::thread::park_timeout(std::time::Duration::from_millis(500));
                        continue;
                    };
                    match record {
                        LowDiagnostic::Recovery(batch) => {
                            for record in &batch.records[..batch.used] {
                                // A late first-cause/terminal keeps priority
                                // over every remaining low-priority line.
                                while let Ok(high) = receiver.try_recv() {
                                    high.write(sink.as_mut());
                                }
                                let line = crate::recovery::TraceLine(*record).encode();
                                if sink.write_all(line.as_slice()).is_err() {
                                    break;
                                }
                            }
                        }
                        LowDiagnostic::SendStage(record) => {
                            let _ = sink.write_all(&record.encode());
                        }
                        LowDiagnostic::Progress(record) => {
                            let _ = sink.write_all(&record.encode());
                        }
                    }
                }
            })
            .ok();
        // Spawn failure disconnects the receiver: subsequent offers drop.
        if worker.is_none() {
            alive.store(false, std::sync::atomic::Ordering::Release);
        }
        (
            Self {
                sender,
                trace,
                alive,
                wake: worker.as_ref().map(|worker| worker.thread().clone()),
            },
            worker,
        )
    }
    fn offer(&self, record: DiagnosticRecord) -> bool {
        // Full or unavailable sink consumes the already-claimed observation;
        // never retry, block the C result, or grow another queue/worker.
        let accepted = self.sender.try_send(HighDiagnostic::First(record)).is_ok();
        if accepted {
            self.wake();
        }
        accepted
    }
    fn offer_terminal(&self, record: TerminalRecord) -> Option<TerminalTicket> {
        let done = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        self.sender
            .try_send(HighDiagnostic::Terminal(record, done.clone()))
            .ok()?;
        self.wake();
        Some(done)
    }
    fn offer_trace(&self, record: [u64; 11]) -> bool {
        if !self.alive.load(std::sync::atomic::Ordering::Acquire) {
            return false;
        }
        let Ok(mut slot) = self.trace.try_lock() else {
            return false;
        };
        let accepted = match slot.as_mut() {
            Some(LowDiagnostic::Recovery(batch)) if batch.used < batch.records.len() => {
                batch.records[batch.used] = record;
                batch.used += 1;
                true
            }
            Some(_) => false,
            None => {
                let mut batch = RecoveryBatch {
                    records: [[0; 11]; 60],
                    used: 1,
                };
                batch.records[0] = record;
                *slot = Some(LowDiagnostic::Recovery(batch));
                true
            }
        };
        drop(slot);
        if accepted {
            self.wake();
        }
        accepted
    }
    fn offer_low(&self, record: LowDiagnostic) -> bool {
        if !self.alive.load(std::sync::atomic::Ordering::Acquire) {
            return false;
        }
        let Ok(mut slot) = self.trace.try_lock() else {
            return false;
        };
        if slot.is_some() {
            return false;
        }
        *slot = Some(record);
        drop(slot);
        self.wake();
        true
    }
    fn wake(&self) {
        if let Some(worker) = &self.wake {
            worker.unpark();
        }
    }
}
static EMITTER: OnceLock<DiagnosticEmitter> = OnceLock::new();
#[cfg(test)]
thread_local! { static TEST_TRACE_EMITTER: std::cell::RefCell<Option<std::sync::Arc<OnceLock<DiagnosticEmitter>>>> = const {std::cell::RefCell::new(None)}; }
fn trace_offer_in(slot: &OnceLock<DiagnosticEmitter>, record: [u64; 11]) -> bool {
    // Called under the real registry/media owner: cold or initializing means
    // unavailable, never initialize or wait here. Owner retains/counts deferral.
    slot.get()
        .is_some_and(|emitter| emitter.offer_trace(record))
}
pub(crate) fn recovery_trace_offer(record: [u64; 11]) -> bool {
    #[cfg(test)]
    if let Some(result) = TEST_TRACE_EMITTER.with(|slot| {
        slot.borrow()
            .as_ref()
            .map(|slot| trace_offer_in(slot, record))
    }) {
        return result;
    }
    trace_offer_in(&EMITTER, record)
}
pub(crate) fn send_stage_offer(record: crate::recovery::SendStageLine) -> bool {
    EMITTER
        .get()
        .is_some_and(|emitter| emitter.offer_low(LowDiagnostic::SendStage(record)))
}
pub(crate) fn progress_offer(record: crate::progress::Line) -> bool {
    EMITTER
        .get()
        .is_some_and(|emitter| emitter.offer_low(LowDiagnostic::Progress(record)))
}
pub(crate) fn terminal_offer(record: TerminalRecord) -> Option<TerminalTicket> {
    EMITTER.get()?.offer_terminal(record)
}
fn diagnostic_emitter() -> &'static DiagnosticEmitter {
    EMITTER.get_or_init(|| DiagnosticEmitter::start(Box::new(std::io::stderr())).0)
}
pub(crate) fn prepare_recovery_diagnostics() {
    // Construction only, before an owner exists or enters the C registry.
    if std::env::var_os("GB_QUIC_RECOVERY_DIAGNOSTICS").is_some_and(|v| v == "1")
        || first_cause_enabled()
    {
        let _ = diagnostic_emitter();
    }
}
pub(crate) fn first_cause_enabled() -> bool {
    std::env::var_os("GB_QUIC_FIRST_ERROR_DIAGNOSTICS").is_some_and(|v| v == "1")
}
#[cfg(test)]
#[test]
fn first_cause_terminal_offer_is_bounded_under_held_sink_and_failure() {
    use std::sync::{atomic::Ordering, mpsc, Arc, Mutex};
    use std::time::{Duration, Instant};
    struct Sink {
        entered: mpsc::SyncSender<()>,
        gate: mpsc::Receiver<()>,
        held: bool,
        bytes: Arc<Mutex<Vec<u8>>>,
    }
    impl std::io::Write for Sink {
        fn write(&mut self, b: &[u8]) -> std::io::Result<usize> {
            if !self.held {
                self.held = true;
                self.entered.send(()).unwrap();
                self.gate.recv_timeout(Duration::from_secs(2)).unwrap();
            }
            self.bytes.lock().unwrap().extend_from_slice(b);
            Ok(b.len())
        }
        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
    let (entered, rx) = mpsc::sync_channel(1);
    let (release, gate) = mpsc::sync_channel(1);
    let bytes = Arc::new(Mutex::new(vec![]));
    let (emitter, worker) = DiagnosticEmitter::start(Box::new(Sink {
        entered,
        gate,
        held: false,
        bytes: bytes.clone(),
    }));
    assert!(emitter.offer_trace([1; 11]));
    rx.recv_timeout(Duration::from_secs(1)).unwrap();
    let record = TerminalRecord {
        first: Some([0, 771, 9, 12, 34, 101, 8, 56, 0, 0, 0, 0, 0]),
        source: Some([101, 1, 0, 0, 0, 0, 0, 0]),
        exits: [Some([771, 2, 2, 1]), None],
        progress: std::array::from_fn(|i| {
            Some(crate::progress::Line::without_pressure([
                771,
                if i < 6 { 1 } else { 2 },
                i as u64 + 1,
                (i % 6) as u64,
                1,
                200_000_001,
                1,
                11,
                10,
                10,
                10,
                10,
                10,
            ]))
        }),
    };
    let start = Instant::now();
    let ticket = emitter.offer_terminal(record).unwrap();
    assert!(!ticket.load(Ordering::Acquire));
    assert!(emitter.offer_terminal(record).is_none());
    assert!(start.elapsed() < Duration::from_millis(100));
    release.send(()).unwrap();
    drop(emitter);
    worker.unwrap().join().unwrap();
    assert!(ticket.load(Ordering::Acquire));
    let output = String::from_utf8(bytes.lock().unwrap().clone()).unwrap();
    assert!(output.contains(
        "GBQF1 R 0 771 9 12 34 101 8 56 0 0 0 0 0\nGBQS1 101 1 0 0 0 0 0 0\nGBQX1 771 2 2 1\n"
    ));
    assert_eq!(
        output.lines().filter(|l| l.starts_with("GBQP2 ")).count(),
        12
    );
    let (sender, receiver) = mpsc::sync_channel(1);
    drop(receiver);
    let emitter = DiagnosticEmitter {
        sender,
        trace: Arc::new(Mutex::new(None)),
        alive: Arc::new(std::sync::atomic::AtomicBool::new(false)),
        wake: None,
    };
    assert!(emitter.offer_terminal(record).is_none());
    let mut maximum = vec![];
    TerminalRecord {
        first: Some([u64::MAX; 13]),
        source: Some([u64::MAX; 8]),
        exits: [Some([u64::MAX; 4]); 2],
        progress: [Some(crate::progress::Line([
            u64::MAX,
            2,
            crate::progress::LIMIT,
            5,
            0,
            u64::MAX,
            0,
            u64::MAX,
            u64::MAX,
            u64::MAX,
            u64::MAX,
            u64::MAX,
            u64::MAX,
            u64::MAX,
            u64::MAX,
        ])); 12],
    }
    .write(&mut maximum)
    .unwrap();
    assert!(
        maximum.len() < 4096,
        "whole fixed terminal envelope fits bounded grammar"
    );
}
fn first_error_record(
    owner: u64,
    identity: (u64, u64),
    operation: u32,
    o: galaxybridge_quic_media::media::first_error::Observation,
) -> DiagnosticRecord {
    let r = o.rejection.unwrap_or_default();
    DiagnosticRecord([
        owner,
        identity.0,
        identity.1,
        operation as u64,
        o.stage as u64,
        o.status as u64,
        r.module as u64,
        r.site as u64,
        r.used,
        r.limit,
        r.requested,
        r.bytes,
        r.byte_limit,
    ])
}
pub(crate) fn status(error: Error) -> u32 {
    match error {
        Error::Protocol => 101,
        Error::Capacity => 102,
        Error::Deadline => 103,
        Error::Clock => 104,
        Error::Authentication => 105,
        Error::Io => 106,
        Error::Retired => 107,
        Error::Unsupported => 108,
        Error::WrongThread => 109,
        Error::InvalidHandle => 110,
        Error::Cleanup => 111,
        Error::ClipboardAckMissing => 112,
        Error::Codec => 113,
        Error::UnrecoverableVideoGap => 114,
        Error::ConnectTimeout => 115,
        Error::PeerIdle => 116,
        Error::ReliableStall => 117,
    }
}
fn boundary(f: impl FnOnce() -> Result<u32, Error>) -> u32 {
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)) {
        Ok(Ok(s)) => s,
        Ok(Err(e)) => status(e),
        Err(_) => status(Error::Protocol),
    }
}
impl Header {
    fn check<T>(&self) -> Result<(), Error> {
        if self.abi != 1
            || self.size as usize != std::mem::size_of::<T>()
            || self.reserved != [0; 2]
        {
            Err(Error::Protocol)
        } else {
            Ok(())
        }
    }
}
unsafe fn input<'a, T>(p: *const T) -> Result<&'a T, Error> {
    if p.is_null() || (p as usize) % std::mem::align_of::<T>() != 0 {
        return Err(Error::Protocol);
    }
    Ok(&*p)
}
unsafe fn output<'a, T>(p: *mut T) -> Result<&'a mut T, Error> {
    if p.is_null() || (p as usize) % std::mem::align_of::<T>() != 0 {
        return Err(Error::Protocol);
    }
    Ok(&mut *p)
}
unsafe fn bytes<'a>(b: Slice, cap: usize) -> Result<&'a [u8], Error> {
    if b.length > cap {
        return Err(Error::Capacity);
    }
    if b.length == 0 {
        return Ok(&[]);
    }
    if b.data.is_null() {
        return Err(Error::Protocol);
    }
    Ok(std::slice::from_raw_parts(b.data, b.length))
}
fn slice(b: &[u8]) -> Slice {
    Slice {
        data: b.as_ptr(),
        length: b.len(),
    }
}
impl Event {
    fn empty(h: Header) -> Self {
        Self {
            h,
            kind: 0,
            code: 0,
            handle: 0,
            ticket: 0,
            ordinal: 0,
            track: 0,
            epoch: 0,
            config: 0,
            record_kind: 0,
            pts: 0,
            deadline_ns: 0,
            bytes: Slice {
                data: std::ptr::null(),
                length: 0,
            },
            configuration: Slice {
                data: std::ptr::null(),
                length: 0,
            },
            sequence: 0,
            receiver_owner: 0,
            generation: 0,
            target_token: 0,
            scid: 0,
            display_id: 0,
            flags: 0,
            capture_kind: 0,
            enabled: 0,
            session: [0; 32],
        }
    }
}
fn media_view(
    out: &mut Event,
    handle: u64,
    l: &OutputLease,
    context: &galaxybridge_quic_media::Context,
) {
    out.kind = 2;
    out.handle = handle;
    out.track = l.record.track as u32;
    out.epoch = l.record.epoch;
    out.config = l.record.config;
    out.record_kind = l.record.kind as u32;
    out.pts = l.record.pts;
    out.deadline_ns = l.deadline;
    out.sequence = l.record.sequence;
    out.flags = l.record.flags as u32;
    out.receiver_owner = l.owner;
    out.generation = context.generation;
    out.target_token = context.target_token;
    out.scid = context.scid;
    out.display_id = context.display_id;
    out.capture_kind = context.capture_kind as u32;
    out.enabled = context.enabled as u32;
    out.session = context.session;
    out.bytes = slice(l.bytes.as_slice());
    out.configuration = l
        .configuration
        .as_ref()
        .map(|b| slice(b.as_slice()))
        .unwrap_or(Slice {
            data: std::ptr::null(),
            length: 0,
        });
}

#[no_mangle]
pub unsafe extern "C" fn gb_backend_create(config: *const Config, out: *mut u64) -> u32 {
    boundary(|| {
        let c = input(config)?;
        c.h.check::<Config>()?;
        let out = output(out)?;
        *out = 0;
        if c.reserved0 != 0 || c.reserved1 != 0 || c.argc > 63 {
            return Err(Error::Protocol);
        }
        let program = bytes(c.program, 8192)?;
        let ip = std::str::from_utf8(bytes(c.peer_ip, 64)?)
            .map_err(|_| Error::Protocol)?
            .parse()
            .map_err(|_| Error::Protocol)?;
        let mut args = Vec::with_capacity(c.argc as usize);
        let mut total = program.len() + 1;
        if c.argc > 0 {
            input(c.args)?;
            for n in 0..c.argc as usize {
                let b = bytes(*c.args.add(n), 8192)?;
                total = total.checked_add(b.len() + 1).ok_or(Error::Capacity)?;
                if total > 8192 {
                    return Err(Error::Capacity);
                }
                args.push(OsString::from_vec(b.to_vec()));
            }
        }
        let nonce = galaxybridge_quic::tls::random_session().map_err(|_| Error::Authentication)?;
        let binding = Binding {
            nonce,
            sidecar_sha: c.sidecar_sha,
            context: galaxybridge_quic_media::Context {
                session: [0; 32],
                generation: c.generation,
                scid: c.scid,
                capture_kind: c.capture_kind,
                display_id: c.display_id,
                target_token: c.target_token,
                enabled: c.enabled,
            },
        };
        let backend = Backend::spawn_host(
            HostConfig {
                binding,
                peer_ip: ip,
            },
            OwnedCommand {
                program: OsString::from_vec(program.to_vec()),
                args,
            },
        )?;
        let owner = id()?;
        let slot = backend.slot.clone();
        let mut entries = registry().lock().map_err(|_| Error::Retired)?;
        if entries.len() >= 16 {
            return Err(Error::Capacity);
        }
        entries.push(Entry {
            id: owner,
            thread: std::thread::current().id(),
            backend: Some(backend),
            _slot: slot,
            leases: BTreeMap::new(),
            copies: BTreeMap::new(),
            pending: BTreeSet::new(),
            destroyed: false,
            retirement_requested: false,
            diagnostic_enabled: std::env::var_os("GB_QUIC_FIRST_ERROR_DIAGNOSTICS")
                .is_some_and(|v| v == "1"),
            diagnostic_reported: false,
            diagnostic_identity: (c.generation, c.target_token),
            #[cfg(test)]
            diagnostic_emitter: None,
        });
        *out = owner;
        Ok(0)
    })
}
#[no_mangle]
pub unsafe extern "C" fn gb_backend_poll(owner: u64, out: *mut Poll) -> u32 {
    boundary(|| {
        let out = output(out)?;
        out.h.check::<Poll>()?;
        with_owner(owner, true, |e| {
            let b = e.backend()?;
            let result = b.poll();
            out.phase = b.phase();
            out.now_ns = b.now_ns()?;
            out.terminal = b.terminal().map(status).unwrap_or(0);
            out.cleanup = 0;
            out.forced = 0;
            out.cleanup_failed = 0;
            if b.terminal().is_some() {
                let cleanup_result = b.cleanup();
                let cleanup = b.cleanup_report();
                out.cleanup = u32::from(cleanup.complete);
                out.forced = u32::from(cleanup.forced);
                out.cleanup_failed = u32::from(cleanup.failed);
                if cleanup.complete {
                    out.phase = 5;
                }
                cleanup_result?;
                if cleanup.failed {
                    return Err(Error::Cleanup);
                }
            }
            result.map(|_| 0)
        })
    })
}
#[no_mangle]
pub unsafe extern "C" fn gb_backend_now_ns(owner: u64, out: *mut u64) -> u32 {
    boundary(|| {
        let out = output(out)?;
        with_owner(owner, true, |e| {
            *out = e.backend()?.now_ns()?;
            Ok(0)
        })
    })
}
#[no_mangle]
pub unsafe extern "C" fn gb_backend_next_wakeup_ns(owner: u64, out: *mut u64) -> u32 {
    boundary(|| {
        let out = output(out)?;
        with_owner(owner, true, |e| {
            *out = e
                .backend()?
                .next_wakeup()
                .as_nanos()
                .try_into()
                .map_err(|_| Error::Clock)?;
            Ok(0)
        })
    })
}
#[no_mangle]
pub unsafe extern "C" fn gb_backend_submit(owner: u64, value: *const Input, out: *mut u64) -> u32 {
    boundary(|| {
        let v = input(value)?;
        v.h.check::<Input>()?;
        if v.reserved != 0 {
            return Err(Error::Protocol);
        }
        let out = output(out)?;
        *out = 0;
        let raw = bytes(v.bytes, 262144)?;
        let mut decoded = match v.kind {
            1 => Some(
                galaxybridge_quic_media::wire::Record::decode(
                    galaxybridge_quic::Lane::Reliable,
                    raw,
                )
                .map_err(|_| Error::Protocol)?,
            ),
            2 => Some(
                galaxybridge_quic_media::wire::Record::decode(
                    galaxybridge_quic::Lane::Datagram,
                    raw,
                )
                .map_err(|_| Error::Protocol)?,
            ),
            _ => None,
        };
        with_owner(owner, true, |e| {
            if decoded.as_ref().is_some_and(crate::owner::semantic_release) {
                e.reserve_progress()?;
            } else {
                e.reserve(false)?;
            }
            let b = e.backend()?;
            let token = match v.kind {
                1 => {
                    let r = decoded.take().ok_or(Error::Protocol)?;
                    if r.kind != 8 {
                        return Err(Error::Protocol);
                    }
                    b.queue_critical(r, v.received_ns)?
                }
                2 => {
                    let r = decoded.take().ok_or(Error::Protocol)?;
                    if r.kind != 9 {
                        return Err(Error::Protocol);
                    }
                    let a = b.replace_move(r, v.received_ns)?;
                    // Move coalescing is a successful admission decision. The
                    // C return value is reserved for GB_* failures; exposing a
                    // replace/stale/expiry disposition there made Swift retire
                    // a healthy transport during an ordinary gesture burst.
                    *out = match a {
                        galaxybridge_quic_media::control::MoveAdmission::Queued => 0,
                        galaxybridge_quic_media::control::MoveAdmission::Replaced => 2,
                        galaxybridge_quic_media::control::MoveAdmission::Stale => 3,
                        galaxybridge_quic_media::control::MoveAdmission::Expired => 4,
                    };
                    return Ok(0);
                }
                3 => b.queue_bulk(raw, v.received_ns)?,
                _ => return Err(Error::Protocol),
            };
            e.pending.insert((v.kind, token));
            *out = token;
            Ok(0)
        })
    })
}
#[no_mangle]
pub unsafe extern "C" fn gb_backend_next_event(owner: u64, out: *mut Event) -> u32 {
    boundary(|| {
        let out = output(out)?;
        out.h.check::<Event>()?;
        *out = Event::empty(out.h);
        with_owner(owner, true, |e| {
            let progress = {
                let backend = e.backend()?;
                backend
                    .peek_event()
                    .is_some_and(|event| backend.event_is_stock_ack(event))
            };
            let (promise, completion) = match e.backend()?.peek_event() {
                Some(crate::owner::Event::BulkComplete(c)) => (Some((3, c.id)), true),
                Some(crate::owner::Event::Transaction(c)) => (Some((1, c.token)), true),
                Some(crate::owner::Event::Retired(_)) => (None, true),
                Some(_) => (None, false),
                None => return Ok(1),
            };
            if !promise.is_some_and(|p| e.pending.contains(&p)) {
                if progress {
                    e.reserve_progress()?;
                } else {
                    e.reserve(completion)?;
                }
            }
            let Some(event) = e.backend()?.next_event() else {
                return Ok(1);
            };
            let handle = id()?;
            out.handle = handle;
            let retained = match event {
                crate::owner::Event::Ready => {
                    out.kind = 1;
                    Retained::Scalar
                }
                crate::owner::Event::Display(status) => {
                    let c = e.backend()?.context();
                    out.kind = 7;
                    out.code = status.kind as u32;
                    out.track = status.width;
                    out.epoch = status.height;
                    out.config = status.density;
                    out.display_id = status.display;
                    out.generation = c.generation;
                    out.target_token = c.target_token;
                    out.scid = c.scid;
                    out.capture_kind = c.capture_kind as u32;
                    out.enabled = c.enabled as u32;
                    out.session = c.session;
                    Retained::Scalar
                }
                crate::owner::Event::Media { handle: local } => {
                    let lease = e.backend()?.retain_media(local)?;
                    media_view(out, handle, &lease, e.backend()?.context());
                    Retained::Media { local, lease }
                }
                crate::owner::Event::Device {
                    handle: local,
                    ordinal,
                } => {
                    let b = e.backend()?.retain_device(local)?;
                    out.kind = 3;
                    out.ordinal = ordinal;
                    out.bytes = slice(b.as_slice());
                    Retained::Device { local, _bytes: b }
                }
                crate::owner::Event::BulkComplete(c) => {
                    out.kind = 4;
                    out.ticket = c.id;
                    out.code = match c.outcome {
                        crate::bulk::Outcome::Applied => 0,
                        crate::bulk::Outcome::NotDispatched => 1,
                        crate::bulk::Outcome::UnknownRemoteOutcome => 2,
                    };
                    e.pending.remove(&(3, c.id));
                    Retained::Scalar
                }
                crate::owner::Event::Transaction(c) => {
                    out.kind = 5;
                    out.ticket = c.token;
                    out.code = match c.outcome {
                        galaxybridge_quic_media::Outcome::PeerBoundaryConfirmed(_) => 0,
                        galaxybridge_quic_media::Outcome::NotDispatched(_) => 1,
                        galaxybridge_quic_media::Outcome::UnknownRemoteOutcome(_) => 2,
                        galaxybridge_quic_media::Outcome::SupersededBeforeDispatch => 3,
                    };
                    e.pending.remove(&(1, c.token));
                    Retained::Scalar
                }
                crate::owner::Event::Retired(error) => {
                    out.kind = 6;
                    out.code = status(error);
                    Retained::Scalar
                }
            };
            e.leases.insert(handle, retained);
            Ok(0)
        })
    })
}
#[no_mangle]
pub unsafe extern "C" fn gb_backend_media_check(owner: u64, handle: u64, out: *mut Event) -> u32 {
    media_check(owner, handle, out, false)
}
#[no_mangle]
pub unsafe extern "C" fn gb_backend_media_admission_check(
    owner: u64,
    handle: u64,
    out: *mut Event,
) -> u32 {
    media_check(owner, handle, out, true)
}
fn media_status(outcome: galaxybridge_quic_media::media::MediaOutcome) -> u32 {
    use galaxybridge_quic_media::media::MediaOutcome;
    match outcome {
        MediaOutcome::Admitted => 0,
        MediaOutcome::DeclinedPressure => 119,
        MediaOutcome::DeclinedExpired => 120,
        MediaOutcome::SkippedDependent => 121,
    }
}
unsafe fn media_check(owner: u64, handle: u64, out: *mut Event, policy: bool) -> u32 {
    boundary(|| {
        let out = output(out)?;
        out.h.check::<Event>()?;
        *out = Event::empty(out.h);
        with_owner(owner, true, |e| {
            let Some(Retained::Media { local, lease }) = e.leases.get(&handle) else {
                return Err(Error::InvalidHandle);
            };
            if e.destroyed {
                return Err(Error::Retired);
            }
            let result = if policy {
                media_status(
                    e.backend
                        .as_mut()
                        .ok_or(Error::Retired)?
                        .media_eligibility(*local)?,
                )
            } else {
                e.backend
                    .as_mut()
                    .ok_or(Error::Retired)?
                    .check_media(*local)?;
                0
            };
            media_view(
                out,
                handle,
                lease,
                e.backend.as_ref().ok_or(Error::Retired)?.context(),
            );
            Ok(result)
        })
    })
}
#[no_mangle]
pub unsafe extern "C" fn gb_backend_media_commit(owner: u64, handle: u64) -> u32 {
    boundary(|| {
        with_owner(owner, true, |e| {
            let Some(Retained::Media { local, .. }) = e.leases.get(&handle) else {
                return Err(Error::InvalidHandle);
            };
            let local = *local;
            e.backend()?.commit_media(local)?;
            Ok(0)
        })
    })
}
#[no_mangle]
pub unsafe extern "C" fn gb_backend_native_copy_commit(owner: u64, handle: u64, copy: u64) -> u32 {
    boundary(|| {
        with_owner(owner, true, |e| {
            if e.destroyed {
                return Err(Error::Retired);
            }
            let Some(Retained::Media { local, .. }) = e.leases.get(&handle) else {
                return Err(Error::InvalidHandle);
            };
            let ticket = e.copies.get_mut(&copy).ok_or(Error::InvalidHandle)?;
            Ok(media_status(
                e.backend
                    .as_mut()
                    .ok_or(Error::Retired)?
                    .commit_native_copy(*local, ticket)?,
            ))
        })
    })
}
#[no_mangle]
pub unsafe extern "C" fn gb_backend_device_eligibility(
    owner: u64,
    handle: u64,
    out: *mut DeviceEligibility,
) -> u32 {
    boundary(|| {
        let out = output(out)?;
        out.h.check::<DeviceEligibility>()?;
        out.effective_ns = 0;
        out.reverse_ns = 0;
        out.clipboard_ns = 0;
        with_owner(owner, true, |e| {
            let Some(Retained::Device { local, .. }) = e.leases.get(&handle) else {
                return Err(Error::InvalidHandle);
            };
            let local = *local;
            let cutoffs = e.backend()?.device_cutoffs(local)?;
            out.effective_ns = cutoffs.effective();
            out.reverse_ns = cutoffs.reverse;
            out.clipboard_ns = cutoffs.clipboard.unwrap_or(0);
            Ok(0)
        })
    })
}
#[no_mangle]
pub unsafe extern "C" fn gb_backend_device_commit(owner: u64, handle: u64) -> u32 {
    boundary(|| {
        with_owner(owner, true, |e| {
            let Some(Retained::Device { local, .. }) = e.leases.get(&handle) else {
                return Err(Error::InvalidHandle);
            };
            let local = *local;
            e.backend()?.consume_device(local)?;
            Ok(0)
        })
    })
}
#[no_mangle]
pub unsafe extern "C" fn gb_backend_copy_reserve(owner: u64, handle: u64, out: *mut u64) -> u32 {
    copy_reserve(owner, handle, out, false)
}
#[no_mangle]
pub unsafe extern "C" fn gb_backend_payload_copy_reserve(
    owner: u64,
    handle: u64,
    out: *mut u64,
) -> u32 {
    copy_reserve(owner, handle, out, true)
}
#[no_mangle]
pub unsafe extern "C" fn gb_backend_media_copy_reserve(
    owner: u64,
    handle: u64,
    out: *mut u64,
) -> u32 {
    boundary(|| {
        let out = output(out)?;
        *out = 0;
        with_owner(owner, true, |e| {
            let Some(Retained::Media { local, lease }) = e.leases.get(&handle) else {
                return Err(Error::InvalidHandle);
            };
            if lease.record.kind != 5 {
                return Err(Error::Protocol);
            }
            let local = *local;
            let result = media_status(e.backend()?.native_copy_preflight(local, None)?);
            if result != 0 {
                return Ok(result);
            }
            e.reserve(false)?;
            let (outcome, copy) = e.backend()?.reserve_native_payload(local)?;
            let Some(copy) = copy else {
                return Ok(media_status(outcome));
            };
            let token = id()?;
            e.copies.insert(token, copy);
            *out = token;
            Ok(0)
        })
    })
}
#[no_mangle]
pub unsafe extern "C" fn gb_backend_media_decline(owner: u64, handle: u64, reason: u32) -> u32 {
    boundary(|| {
        with_owner(owner, true, |e| {
            use galaxybridge_quic_media::media::MediaDeclineReason;
            let reason = match reason {
                1 => MediaDeclineReason::Pressure,
                2 => MediaDeclineReason::Expired,
                _ => return Err(Error::Protocol),
            };
            let Some(Retained::Media { local, .. }) = e.leases.get(&handle) else {
                return Err(Error::InvalidHandle);
            };
            let local = *local;
            e.backend()?.decline_media(local, reason)?;
            Ok(0)
        })
    })
}
#[repr(C)]
pub struct MediaHealth {
    pub h: Header,
    pub track: u32,
    pub state: u32,
    pub reason: u32,
    pub epoch: u32,
    pub config: u32,
    pub attempt: u32,
    pub revision: u64,
    pub episode: u64,
    pub next_deadline_ns: u64,
    pub admitted_sequence: u64,
    pub declined: u64,
    pub skipped: u64,
    pub admitted_input_dropped: u64,
    pub output_dropped: u64,
    pub output_pressure: u32,
    pub reserved0: u32,
}
#[no_mangle]
pub unsafe extern "C" fn gb_backend_media_health(
    owner: u64,
    track: u32,
    out: *mut MediaHealth,
) -> u32 {
    boundary(|| {
        let out = output(out)?;
        out.h.check::<MediaHealth>()?;
        if out.reserved0 != 0 || !matches!(track, 1 | 2) {
            return Err(Error::Protocol);
        };
        with_owner(owner, true, |e| {
            let v = e.backend()?.g1.receiver.media_health(track as u8)?;
            *out = MediaHealth {
                h: out.h,
                track: v.track,
                state: v.state,
                reason: v.reason,
                epoch: v.epoch,
                config: v.config,
                attempt: v.attempt,
                revision: v.revision,
                episode: v.episode,
                next_deadline_ns: v.next_deadline,
                admitted_sequence: v.admitted_sequence,
                declined: v.declined,
                skipped: v.skipped,
                admitted_input_dropped: v.admitted_input_dropped,
                output_dropped: v.output_dropped,
                output_pressure: v.output_pressure,
                reserved0: 0,
            };
            Ok(0)
        })
    })
}
#[no_mangle]
pub unsafe extern "C" fn gb_backend_media_retry(owner: u64, episode: u64) -> u32 {
    boundary(|| {
        with_owner(owner, true, |e| {
            e.backend()?.retry_media(episode)?;
            Ok(0)
        })
    })
}
#[no_mangle]
pub unsafe extern "C" fn gb_backend_media_native_status(
    owner: u64,
    identity: *const Event,
    input_loss: u64,
    input_drops: u64,
    output_sequence: u64,
    pressure: u32,
    drops: u64,
) -> u32 {
    boundary(|| {
        let v = identity.as_ref().ok_or(Error::Protocol)?;
        v.h.check::<Event>()?;
        if pressure > 1 || !matches!(v.track, 1 | 2) {
            return Err(Error::Protocol);
        };
        with_owner(owner, true, |e| {
            let b = e.backend()?;
            let c = b.context();
            if v.receiver_owner != b.g1.receiver.owner_id()
                || v.generation != c.generation
                || v.target_token != c.target_token
                || v.scid != c.scid
                || v.display_id != c.display_id
                || v.capture_kind != c.capture_kind as u32
                || v.enabled != c.enabled as u32
                || v.session != c.session
            {
                return Err(Error::Protocol);
            };
            b.native_media_status(
                v.track as u8,
                v.epoch,
                v.config,
                input_loss,
                input_drops,
                output_sequence,
                pressure == 1,
                drops,
            )?;
            Ok(0)
        })
    })
}
unsafe fn copy_reserve(owner: u64, handle: u64, out: *mut u64, payload_only: bool) -> u32 {
    boundary(|| {
        let out = output(out)?;
        *out = 0;
        with_owner(owner, true, |e| {
            e.reserve(false)?;
            let Some(Retained::Media { local, .. }) = e.leases.get(&handle) else {
                return Err(Error::InvalidHandle);
            };
            let local = *local;
            let copy = if payload_only {
                e.backend()?.reserve_payload_copy(local)?
            } else {
                e.backend()?.reserve_copy(local)?
            };
            let token = id()?;
            e.copies.insert(token, copy);
            *out = token;
            Ok(0)
        })
    })
}
#[no_mangle]
pub unsafe extern "C" fn gb_backend_event_release(owner: u64, handle: u64) -> u32 {
    boundary(|| {
        with_owner(owner, false, |e| {
            let retained = e.leases.remove(&handle).ok_or(Error::InvalidHandle)?;
            let local = match &retained {
                Retained::Media { local, .. } | Retained::Device { local, .. } => Some(*local),
                _ => None,
            };
            if let (Some(local), Some(b)) = (local, e.backend.as_mut()) {
                b.release_event(local)?;
            }
            drop(retained);
            Ok(0)
        })
    })
}
#[no_mangle]
pub unsafe extern "C" fn gb_backend_copy_release(owner: u64, handle: u64) -> u32 {
    boundary(|| {
        with_owner(owner, false, |e| {
            drop(e.copies.remove(&handle).ok_or(Error::InvalidHandle)?);
            Ok(0)
        })
    })
}
#[no_mangle]
pub unsafe extern "C" fn gb_backend_retire(owner: u64) -> u32 {
    boundary(|| {
        with_owner(owner, true, |e| {
            e.backend()?.retire(Error::Retired);
            e.retirement_requested = true;
            Ok(0)
        })
    })
}
#[no_mangle]
pub unsafe extern "C" fn gb_backend_destroy(owner: u64) -> u32 {
    boundary(|| {
        with_owner(owner, true, |e| {
            let b = e.backend()?;
            if b.terminal().is_none() {
                return Ok(118);
            }
            let result = b.cleanup();
            let cleanup = b.cleanup_report();
            if !cleanup.complete {
                return Ok(118);
            }
            result?;
            e.destroyed = true;
            e.pending.clear();
            e.backend = None;
            if cleanup.failed {
                Err(Error::Cleanup)
            } else {
                Ok(0)
            }
        })
    })
}
