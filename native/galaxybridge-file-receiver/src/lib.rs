//! Private, descriptor-relative staging with durable checkpoints and exclusive
//! publication. Not a generic SAF backend; unsupported filesystem semantics fail.
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::ffi::CString;
use std::fs::{File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::Path;

pub const MAX_SIZE: u64 = 10 * 1024 * 1024 * 1024;
pub const CHUNK_SIZE: usize = 1024 * 1024;
type Result<T> = std::result::Result<T, Failure>;
#[derive(Debug)]
pub struct Failure(pub &'static str);
impl From<io::Error> for Failure {
    fn from(_: io::Error) -> Self {
        Self("storage_unavailable")
    }
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Manifest {
    pub transfer_id: String,
    pub owner: String,
    pub name: String,
    pub size: u64,
    pub sha256: String,
}
impl Manifest {
    pub fn validate(&self) -> Result<()> {
        if !hexadecimal(&self.transfer_id, 32)
            || !hexadecimal(&self.owner, 64)
            || !hexadecimal(&self.sha256, 64)
            || self.size > MAX_SIZE
            || self.name.is_empty()
            || self.name.len() > 240
            || self.name == "."
            || self.name == ".."
            || self.name.contains('/')
            || self.name.contains('\\')
            || self.name.chars().any(char::is_control)
            || self.name.starts_with(".galaxybridge-")
        {
            return Err(Failure("invalid_manifest"));
        }
        Ok(())
    }
}
pub fn hexadecimal(value: &str, length: usize) -> bool {
    value.len() == length
        && value
            .bytes()
            .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c))
}
pub fn digest_hex(digest: &Sha256) -> String {
    format!("{:x}", digest.clone().finalize())
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
struct Identity {
    device: u64,
    inode: u64,
}
impl Identity {
    fn of(file: &File) -> Result<Self> {
        let m = file.metadata()?;
        Ok(Self {
            device: m.dev(),
            inode: m.ino(),
        })
    }
}
#[derive(Clone, Copy, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
enum Phase {
    Receiving,
    Verified,
    Completed,
    Cancelled,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Journal {
    version: u32,
    manifest: Manifest,
    destination: Identity,
    staging: Identity,
    file: Identity,
    offset: u64,
    prefix_sha256: String,
    phase: Phase,
}
#[derive(Debug, Clone, Serialize)]
pub struct Status {
    pub offset: u64,
    pub prefix_sha256: String,
    pub complete: bool,
    pub cancelled: bool,
}

struct Directory(File);
impl Directory {
    fn open(path: &Path, private: bool) -> Result<Self> {
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)?;
        let result = Self(file);
        result.validate(private)?;
        Ok(result)
    }
    fn validate(&self, private: bool) -> Result<()> {
        let m = self.0.metadata()?;
        if !m.is_dir()
            || (private && (m.uid() != unsafe { libc::geteuid() } || m.mode() & 0o077 != 0))
        {
            return Err(Failure("private_staging_unsupported"));
        }
        Ok(())
    }
    fn child(&self, name: &str, private: bool) -> Result<Self> {
        let file = self.open_file(name, libc::O_RDONLY | libc::O_DIRECTORY, 0)?;
        let result = Self(file);
        result.validate(private)?;
        Ok(result)
    }
    fn mkdir(&self, name: &str) -> Result<()> {
        let name = cstring(name)?;
        if unsafe { libc::mkdirat(self.0.as_raw_fd(), name.as_ptr(), 0o700) } != 0 {
            return Err(Failure("transfer_exists"));
        }
        self.sync()
    }
    fn open_file(&self, name: &str, flags: i32, mode: u32) -> Result<File> {
        let name = cstring(name)?;
        let fd = unsafe {
            libc::openat(
                self.0.as_raw_fd(),
                name.as_ptr(),
                flags | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                mode as libc::c_uint,
            )
        };
        if fd < 0 {
            return Err(Failure("owned_object_unavailable"));
        }
        Ok(unsafe { File::from_raw_fd(fd) })
    }
    fn exists(&self, name: &str) -> Result<bool> {
        let name = cstring(name)?;
        let mut stat = std::mem::MaybeUninit::<libc::stat>::uninit();
        if unsafe {
            libc::fstatat(
                self.0.as_raw_fd(),
                name.as_ptr(),
                stat.as_mut_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        } == 0
        {
            return Ok(true);
        }
        if io::Error::last_os_error().raw_os_error() == Some(libc::ENOENT) {
            Ok(false)
        } else {
            Err(Failure("lookup_failed"))
        }
    }
    fn unlink_owned(&self, name: &str, identity: Identity) -> Result<()> {
        if !self.exists(name)? {
            return Ok(());
        }
        let file = self.open_file(name, libc::O_RDONLY, 0)?;
        if Identity::of(&file)? != identity || !file.metadata()?.is_file() {
            return Err(Failure("ownership_lost"));
        }
        let name = cstring(name)?;
        if unsafe { libc::unlinkat(self.0.as_raw_fd(), name.as_ptr(), 0) } != 0 {
            return Err(Failure("cleanup_failed"));
        }
        self.sync()
    }
    fn sync(&self) -> Result<()> {
        self.0.sync_all().map_err(Into::into)
    }
}
fn cstring(s: &str) -> Result<CString> {
    CString::new(s).map_err(|_| Failure("invalid_name"))
}

/// A process owns the flock until drop. All append/status/commit commands are
/// serialized through this object. Other receiver processes fail with busy.
pub struct Receiver {
    destination: Directory,
    staging: Directory,
    journal: Journal,
    file: Option<File>,
    _lock: File,
    digest: Sha256,
}
impl Receiver {
    pub fn begin(
        destination: &Path,
        state: &Path,
        manifest: Manifest,
        progress: &mut dyn FnMut(u64) -> Result<()>,
    ) -> Result<Self> {
        manifest.validate()?;
        let destination = Directory::open(destination, false)?;
        let state = Directory::open(state, true)?;
        // State/staging must share the destination filesystem; no hidden copy
        // or unsafe ordinary-rename fallback is permitted for large files.
        if Identity::of(&state.0)?.device != Identity::of(&destination.0)?.device {
            return Err(Failure("atomic_publication_unsupported"));
        }
        let is_new = !state.exists(&manifest.transfer_id)?;
        if is_new {
            state.mkdir(&manifest.transfer_id)?;
        }
        let staging = state.child(&manifest.transfer_id, true)?;
        let lock = staging.open_file("writer.lock", libc::O_RDWR | libc::O_CREAT, 0o600)?;
        if !lock.metadata()?.is_file()
            || unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0
        {
            return Err(Failure("writer_busy"));
        }
        let journal = if is_new {
            // Probe this exact mount, under the lock and private owned directory.
            // A failure preserves staging for explicit recovery; never mv -n.
            probe_exclusive_rename(&staging)?;
            if destination.exists(&manifest.name)? {
                return Err(Failure("destination_exists"));
            }
            let file = staging.open_file(
                "payload.part",
                libc::O_RDWR | libc::O_CREAT | libc::O_EXCL,
                0o600,
            )?;
            file.sync_all()?;
            Journal {
                version: 1,
                manifest,
                destination: Identity::of(&destination.0)?,
                staging: Identity::of(&staging.0)?,
                file: Identity::of(&file)?,
                offset: 0,
                prefix_sha256: digest_hex(&Sha256::new()),
                phase: Phase::Receiving,
            }
        } else {
            let file = staging.open_file("journal.json", libc::O_RDONLY, 0)?;
            let mut bytes = Vec::new();
            file.take(8193).read_to_end(&mut bytes)?;
            if bytes.len() > 8192 {
                return Err(Failure("invalid_journal"));
            }
            let journal: Journal =
                serde_json::from_slice(&bytes).map_err(|_| Failure("invalid_journal"))?;
            if journal.version != 1
                || journal.manifest != manifest
                || journal.offset > manifest.size
                || !hexadecimal(&journal.prefix_sha256, 64)
                || journal.destination != Identity::of(&destination.0)?
                || journal.staging != Identity::of(&staging.0)?
            {
                return Err(Failure("ownership_or_manifest_mismatch"));
            }
            journal
        };
        let mut receiver = Self {
            destination,
            staging,
            journal,
            file: None,
            _lock: lock,
            digest: Sha256::new(),
        };
        if is_new {
            receiver.persist()?;
        }
        receiver.recover(progress)?;
        Ok(receiver)
    }
    fn persist(&self) -> Result<()> {
        let mut random = [0u8; 16];
        File::open("/dev/urandom")?.read_exact(&mut random)?;
        let name = format!(
            "journal-{}.tmp",
            random
                .iter()
                .map(|x| format!("{x:02x}"))
                .collect::<String>()
        );
        let mut file =
            self.staging
                .open_file(&name, libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL, 0o600)?;
        let bytes = serde_json::to_vec(&self.journal).map_err(|_| Failure("journal_encode"))?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        let old = cstring(&name)?;
        let new = cstring("journal.json")?;
        if unsafe {
            libc::renameat(
                self.staging.0.as_raw_fd(),
                old.as_ptr(),
                self.staging.0.as_raw_fd(),
                new.as_ptr(),
            )
        } != 0
        {
            return Err(Failure("checkpoint_failed"));
        }
        self.staging.sync()
    }
    fn checked_file(&self, published: bool) -> Result<File> {
        let file = if published {
            self.destination
                .open_file(&self.journal.manifest.name, libc::O_RDONLY, 0)?
        } else {
            self.staging.open_file("payload.part", libc::O_RDWR, 0)?
        };
        if Identity::of(&file)? != self.journal.file
            || !file.metadata()?.is_file()
            || file.metadata()?.nlink() != 1
        {
            return Err(Failure("ownership_lost"));
        }
        Ok(file)
    }
    fn recover(&mut self, progress: &mut dyn FnMut(u64) -> Result<()>) -> Result<()> {
        match self.journal.phase {
            Phase::Completed => return Ok(()), // Durable receipt; not a same-name guess.
            Phase::Cancelled => {
                self.staging
                    .unlink_owned("payload.part", self.journal.file)?;
                return Ok(());
            }
            _ => {}
        }
        if self.journal.phase == Phase::Verified && !self.staging.exists("payload.part")? {
            let mut final_file = self.checked_file(true)?;
            if final_file.metadata()?.len() != self.journal.manifest.size {
                return Err(Failure("published_outcome_unknown"));
            }
            let digest = hash_prefix(&mut final_file, self.journal.manifest.size, progress)?;
            if digest_hex(&digest) != self.journal.manifest.sha256 {
                return Err(Failure("published_outcome_unknown"));
            }
            self.destination.sync()?;
            self.journal.phase = Phase::Completed;
            self.persist()?;
            return Ok(());
        }
        let mut file = self.checked_file(false)?;
        if file.metadata()?.len() < self.journal.offset {
            return Err(Failure("checkpoint_corrupt"));
        }
        self.digest = hash_prefix(&mut file, self.journal.offset, progress)?;
        if digest_hex(&self.digest) != self.journal.prefix_sha256 {
            return Err(Failure("checkpoint_corrupt"));
        }
        // Only proven-owned bytes beyond the durable checkpoint may be removed.
        if file.metadata()?.len() > self.journal.offset {
            file.set_len(self.journal.offset)?;
            file.sync_all()?;
        }
        self.file = Some(file);
        Ok(())
    }
    pub fn status(&self) -> Status {
        Status {
            offset: self.journal.offset,
            prefix_sha256: self.journal.prefix_sha256.clone(),
            complete: self.journal.phase == Phase::Completed,
            cancelled: self.journal.phase == Phase::Cancelled,
        }
    }
    pub fn append(&mut self, offset: u64, bytes: &[u8], sha256: &str) -> Result<Status> {
        if self.journal.phase != Phase::Receiving
            || bytes.is_empty()
            || bytes.len() > CHUNK_SIZE
            || offset
                .checked_add(bytes.len() as u64)
                .is_none_or(|end| end > self.journal.manifest.size)
            || format!("{:x}", Sha256::digest(bytes)) != sha256
        {
            return Err(Failure("invalid_chunk"));
        }
        let mut file = self.checked_file(false)?;
        if offset < self.journal.offset {
            if offset + bytes.len() as u64 > self.journal.offset {
                return Err(Failure("conflicting_replay"));
            }
            file.seek(SeekFrom::Start(offset))?;
            let mut stored = vec![0u8; bytes.len()];
            file.read_exact(&mut stored)?;
            if stored != bytes {
                return Err(Failure("conflicting_replay"));
            }
            return Ok(self.status());
        }
        if offset != self.journal.offset || file.metadata()?.len() != offset {
            return Err(Failure("reconcile_required"));
        }
        file.seek(SeekFrom::Start(offset))?;
        file.write_all(bytes)?;
        file.sync_all()?;
        let mut next_digest = self.digest.clone();
        next_digest.update(bytes);
        let previous = self.journal.clone();
        self.journal.offset += bytes.len() as u64;
        self.journal.prefix_sha256 = digest_hex(&next_digest);
        if let Err(error) = self.persist() {
            self.journal = previous;
            return Err(error);
        }
        self.digest = next_digest;
        Ok(self.status())
    }
    pub fn commit(&mut self, progress: &mut dyn FnMut(u64) -> Result<()>) -> Result<Status> {
        if self.journal.phase == Phase::Completed {
            return Ok(self.status());
        }
        if self.journal.phase == Phase::Cancelled
            || self.journal.offset != self.journal.manifest.size
        {
            return Err(Failure("incomplete"));
        }
        let mut file = self.checked_file(false)?;
        if file.metadata()?.len() != self.journal.manifest.size {
            return Err(Failure("size_mismatch"));
        }
        let full_hash = hash_prefix(&mut file, self.journal.manifest.size, progress)?;
        if digest_hex(&full_hash) != self.journal.manifest.sha256 {
            return Err(Failure("hash_mismatch"));
        }
        file.sync_all()?;
        self.journal.phase = Phase::Verified;
        self.persist()?;
        // Descriptor identity is checked again after verification and immediately
        // before publication. Private staging prevents other UIDs replacing it.
        self.checked_file(false)?;
        exclusive_rename(
            &self.staging,
            "payload.part",
            &self.destination,
            &self.journal.manifest.name,
        )?;
        self.destination.sync()?;
        self.staging.sync()?;
        self.journal.phase = Phase::Completed;
        self.persist()?;
        self.file = None;
        Ok(self.status())
    }
    pub fn cancel(&mut self, _progress: &mut dyn FnMut(u64) -> Result<()>) -> Result<Status> {
        // begin already reconciled a rename that won before a lost ACK.
        // Never rehash a large prefix merely to cancel an owned partial.
        if self.journal.phase == Phase::Completed {
            return Ok(self.status());
        }
        self.journal.phase = Phase::Cancelled;
        self.persist()?;
        self.staging
            .unlink_owned("payload.part", self.journal.file)?;
        self.file = None;
        Ok(self.status())
    }
}
fn hash_prefix(
    file: &mut File,
    length: u64,
    progress: &mut dyn FnMut(u64) -> Result<()>,
) -> Result<Sha256> {
    file.seek(SeekFrom::Start(0))?;
    let mut buffer = vec![0u8; CHUNK_SIZE];
    let mut offset = 0u64;
    let mut digest = Sha256::new();
    progress(0)?;
    while offset < length {
        let count = usize::try_from((length - offset).min(buffer.len() as u64))
            .map_err(|_| Failure("invalid_size"))?;
        file.read_exact(&mut buffer[..count])?;
        digest.update(&buffer[..count]);
        offset += count as u64;
        // Progress has no absolute 10-second deadline. A closed transport causes
        // the caller to abort promptly and preserves the last durable state.
        if offset % (16 * CHUNK_SIZE as u64) == 0 || offset == length {
            progress(offset)?;
        }
    }
    Ok(digest)
}
fn exclusive_rename(
    source: &Directory,
    old: &str,
    destination: &Directory,
    new: &str,
) -> Result<()> {
    let old = cstring(old)?;
    let new = cstring(new)?;
    #[cfg(any(target_os = "linux", target_os = "android"))]
    let result = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            source.0.as_raw_fd(),
            old.as_ptr(),
            destination.0.as_raw_fd(),
            new.as_ptr(),
            1u32,
        )
    };
    #[cfg(target_os = "macos")]
    let result = unsafe {
        libc::renameatx_np(
            source.0.as_raw_fd(),
            old.as_ptr(),
            destination.0.as_raw_fd(),
            new.as_ptr(),
            libc::RENAME_EXCL,
        )
    };
    if result != 0 {
        return Err(Failure(
            if io::Error::last_os_error().raw_os_error() == Some(libc::EEXIST) {
                "destination_exists"
            } else {
                "atomic_publication_unsupported"
            },
        ));
    }
    Ok(())
}
/// Harmless capability probe; callers provide a newly created, exact owned QA
/// directory. This establishes atomic rename support, not private staging.
pub fn probe_atomic_publication(path: &Path) -> Result<()> {
    probe_exclusive_rename(&Directory::open(path, false)?)
}

fn probe_exclusive_rename(directory: &Directory) -> Result<()> {
    let a = directory.open_file(
        "probe-a",
        libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL,
        0o600,
    )?;
    let b = directory.open_file(
        "probe-b",
        libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL,
        0o600,
    )?;
    if !matches!(
        exclusive_rename(directory, "probe-a", directory, "probe-b"),
        Err(Failure("destination_exists"))
    ) {
        return Err(Failure("atomic_publication_unsupported"));
    }
    exclusive_rename(directory, "probe-a", directory, "probe-c")?;
    directory.unlink_owned("probe-c", Identity::of(&a)?)?;
    directory.unlink_owned("probe-b", Identity::of(&b)?)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::atomic::{AtomicU64, Ordering};
    static NUMBER: AtomicU64 = AtomicU64::new(0);
    struct Fixture {
        root: std::path::PathBuf,
        destination: std::path::PathBuf,
        state: std::path::PathBuf,
    }
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "gb-file-fixture-{}-{}",
                std::process::id(),
                NUMBER.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir(&root).unwrap();
            fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
            let destination = root.join("destination");
            let state = root.join("state");
            fs::create_dir(&destination).unwrap();
            fs::create_dir(&state).unwrap();
            fs::set_permissions(&state, fs::Permissions::from_mode(0o700)).unwrap();
            Self {
                root,
                destination,
                state,
            }
        }
        fn manifest(&self, id: u8, data: &[u8]) -> Manifest {
            Manifest {
                transfer_id: format!("{id:032x}"),
                owner: "a".repeat(64),
                name: "result.bin".into(),
                size: data.len() as u64,
                sha256: format!("{:x}", Sha256::digest(data)),
            }
        }
        fn begin(&self, manifest: Manifest) -> Receiver {
            Receiver::begin(&self.destination, &self.state, manifest, &mut |_| Ok(())).unwrap()
        }
        fn part(&self, manifest: &Manifest) -> std::path::PathBuf {
            self.state.join(&manifest.transfer_id).join("payload.part")
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.root);
        }
    }
    fn append(receiver: &mut Receiver, offset: u64, bytes: &[u8]) -> Result<Status> {
        receiver.append(offset, bytes, &format!("{:x}", Sha256::digest(bytes)))
    }
    #[test]
    fn interrupted_tail_recovery_and_duplicate_ack() {
        let f = Fixture::new();
        let m = f.manifest(1, b"hello world");
        let mut r = f.begin(m.clone());
        append(&mut r, 0, b"hello ").unwrap();
        drop(r);
        OpenOptions::new()
            .append(true)
            .open(f.part(&m))
            .unwrap()
            .write_all(b"uncommitted")
            .unwrap();
        let mut r = f.begin(m.clone());
        assert_eq!(r.status().offset, 6);
        assert_eq!(fs::metadata(f.part(&m)).unwrap().len(), 6);
        assert_eq!(append(&mut r, 0, b"hello ").unwrap().offset, 6);
        assert!(matches!(
            append(&mut r, 0, b"WRONG!"),
            Err(Failure("conflicting_replay"))
        ));
        append(&mut r, 6, b"world").unwrap();
        assert!(!f.destination.join(&m.name).exists());
        assert!(r.commit(&mut |_| Ok(())).unwrap().complete);
        drop(r);
        assert_eq!(
            fs::read(f.destination.join(&m.name)).unwrap(),
            b"hello world"
        );
        assert!(f.begin(m).status().complete); // lost final ACK is idempotent
    }
    #[test]
    fn mutated_prefix_and_replaced_inode_are_never_adopted() {
        let f = Fixture::new();
        let m = f.manifest(2, b"abcdef");
        let mut r = f.begin(m.clone());
        append(&mut r, 0, b"abc").unwrap();
        drop(r);
        fs::write(f.part(&m), b"BAD").unwrap();
        assert!(matches!(
            Receiver::begin(&f.destination, &f.state, m.clone(), &mut |_| Ok(())),
            Err(Failure("checkpoint_corrupt"))
        ));
        fs::rename(f.part(&m), f.root.join("old-owned-inode")).unwrap();
        fs::write(f.part(&m), b"abc").unwrap();
        assert!(matches!(
            Receiver::begin(&f.destination, &f.state, m, &mut |_| Ok(())),
            Err(Failure("ownership_lost"))
        ));
    }
    #[test]
    fn hash_mismatch_never_publishes() {
        let f = Fixture::new();
        let m = f.manifest(3, b"correct");
        let mut r = f.begin(m.clone());
        append(&mut r, 0, b"corrupt").unwrap();
        assert!(matches!(
            r.commit(&mut |_| Ok(())),
            Err(Failure("hash_mismatch"))
        ));
        assert!(!f.destination.join(m.name).exists());
    }
    #[test]
    fn final_collision_is_atomic_and_preserves_both_payloads() {
        let f = Fixture::new();
        let a = f.manifest(4, b"first");
        let b = f.manifest(5, b"second");
        let mut one = f.begin(a.clone());
        let mut two = f.begin(b.clone());
        append(&mut one, 0, b"first").unwrap();
        append(&mut two, 0, b"second").unwrap();
        one.commit(&mut |_| Ok(())).unwrap();
        assert!(matches!(
            two.commit(&mut |_| Ok(())),
            Err(Failure("destination_exists"))
        ));
        assert_eq!(fs::read(f.destination.join(&a.name)).unwrap(), b"first");
        assert_eq!(fs::read(f.part(&b)).unwrap(), b"second");
    }
    #[test]
    fn rename_wins_before_receipt_crash_and_cancel_preserves_final() {
        let f = Fixture::new();
        let m = f.manifest(6, b"verified");
        let mut r = f.begin(m.clone());
        append(&mut r, 0, b"verified").unwrap();
        r.journal.phase = Phase::Verified;
        r.persist().unwrap();
        exclusive_rename(&r.staging, "payload.part", &r.destination, &m.name).unwrap();
        drop(r);
        let mut recovered = f.begin(m.clone());
        assert!(recovered.status().complete);
        assert!(recovered.cancel(&mut |_| Ok(())).unwrap().complete);
        assert_eq!(fs::read(f.destination.join(m.name)).unwrap(), b"verified");
    }
    #[test]
    fn unknown_publication_cannot_adopt_unrelated_final() {
        let f = Fixture::new();
        let m = f.manifest(7, b"verified");
        let mut r = f.begin(m.clone());
        append(&mut r, 0, b"verified").unwrap();
        r.journal.phase = Phase::Verified;
        r.persist().unwrap();
        drop(r);
        // Retain the owned inode elsewhere so the unrelated file cannot reuse it.
        fs::rename(f.part(&m), f.root.join("retained-owned")).unwrap();
        fs::write(f.destination.join(&m.name), b"verified").unwrap();
        assert!(matches!(
            Receiver::begin(&f.destination, &f.state, m, &mut |_| Ok(())),
            Err(Failure("ownership_lost"))
        ));
    }
    #[test]
    fn cancellation_only_removes_exact_owned_partial() {
        let f = Fixture::new();
        let m = f.manifest(8, b"abc");
        let sentinel = f.destination.join(".galaxybridge-foreign.part");
        fs::write(&sentinel, b"keep").unwrap();
        let mut r = f.begin(m.clone());
        append(&mut r, 0, b"a").unwrap();
        assert!(r.cancel(&mut |_| Ok(())).unwrap().cancelled);
        drop(r);
        assert!(f.begin(m.clone()).status().cancelled);
        assert!(!f.part(&m).exists());
        assert_eq!(fs::read(sentinel).unwrap(), b"keep");
    }
    #[test]
    fn writer_lock_and_manifest_owner_fence() {
        let f = Fixture::new();
        let m = f.manifest(9, b"abc");
        let r = f.begin(m.clone());
        assert!(matches!(
            Receiver::begin(&f.destination, &f.state, m.clone(), &mut |_| Ok(())),
            Err(Failure("writer_busy"))
        ));
        drop(r);
        let mut wrong = m;
        wrong.owner = "b".repeat(64);
        assert!(matches!(
            Receiver::begin(&f.destination, &f.state, wrong, &mut |_| Ok(())),
            Err(Failure("ownership_or_manifest_mismatch"))
        ));
    }
    #[test]
    fn verification_is_cooperatively_interruptible_without_short_wall_deadline() {
        let f = Fixture::new();
        let bytes = vec![0u8; CHUNK_SIZE];
        let m = f.manifest(10, &bytes);
        let mut r = f.begin(m.clone());
        append(&mut r, 0, &bytes).unwrap();
        assert!(matches!(
            r.commit(&mut |_| Err(Failure("transport_closed"))),
            Err(Failure("transport_closed"))
        ));
        assert!(!f.destination.join(&m.name).exists());
        drop(r);
        assert!(f.begin(m).commit(&mut |_| Ok(())).unwrap().complete);
    }
    #[test]
    fn journal_failure_never_acknowledges_uncheckpointed_bytes() {
        let f = Fixture::new();
        let m = f.manifest(12, b"abcdef");
        let mut r = f.begin(m.clone());
        append(&mut r, 0, b"abc").unwrap();
        let transaction = f.state.join(&m.transfer_id);
        fs::rename(
            transaction.join("journal.json"),
            transaction.join("saved-journal.json"),
        )
        .unwrap();
        fs::create_dir(transaction.join("journal.json")).unwrap(); // force atomic checkpoint publication failure
        assert!(matches!(
            append(&mut r, 3, b"def"),
            Err(Failure("checkpoint_failed"))
        ));
        assert_eq!(r.status().offset, 3);
        fs::remove_dir(transaction.join("journal.json")).unwrap();
        fs::rename(
            transaction.join("saved-journal.json"),
            transaction.join("journal.json"),
        )
        .unwrap();
        drop(r);
        let recovered = f.begin(m.clone());
        assert_eq!(recovered.status().offset, 3);
        assert_eq!(fs::read(f.part(&m)).unwrap(), b"abc");
    }
    #[test]
    fn public_staging_and_symlink_payload_fail_closed() {
        let f = Fixture::new();
        let m = f.manifest(13, b"abc");
        fs::set_permissions(&f.state, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(matches!(
            Receiver::begin(&f.destination, &f.state, m.clone(), &mut |_| Ok(())),
            Err(Failure("private_staging_unsupported"))
        ));
        fs::set_permissions(&f.state, fs::Permissions::from_mode(0o700)).unwrap();
        let r = f.begin(m.clone());
        drop(r);
        fs::rename(f.part(&m), f.root.join("retained-part")).unwrap();
        let sentinel = f.root.join("sentinel");
        fs::write(&sentinel, b"keep").unwrap();
        std::os::unix::fs::symlink(&sentinel, f.part(&m)).unwrap();
        assert!(Receiver::begin(&f.destination, &f.state, m, &mut |_| Ok(())).is_err());
        assert_eq!(fs::read(sentinel).unwrap(), b"keep");
    }
    #[test]
    fn maximum_manifest_is_64_bit_and_chunk_window_remains_bounded() {
        let f = Fixture::new();
        let mut m = f.manifest(11, b"");
        m.size = MAX_SIZE;
        let mut r = f.begin(m.clone());
        assert_eq!(r.journal.manifest.size, 10_737_418_240);
        assert!(matches!(
            r.append(u64::MAX, b"x", ""),
            Err(Failure("invalid_chunk"))
        ));
        assert!(matches!(
            r.append(0, &vec![0; CHUNK_SIZE + 1], ""),
            Err(Failure("invalid_chunk"))
        ));
        assert!(matches!(
            append(&mut r, 4_294_967_296, b"x"),
            Err(Failure("reconcile_required"))
        ));
    }
}
