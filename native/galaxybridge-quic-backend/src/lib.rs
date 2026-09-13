//! Paired application owner. G0 remains the sole UDP/QUIC engine.
pub mod bootstrap;
pub mod bulk;
pub mod ffi;
pub mod owner;
pub mod process;
mod progress;
mod quality;
pub mod recovery;
pub mod stock;
pub use owner::Backend;
pub const MS: u64 = 1_000_000;
pub const BULK_LIFETIME: u64 = 500 * MS;
pub const PHASE_LIFETIME: u64 = 5_000 * MS;
pub const CLIPBOARD_LIFETIME: u64 = 2_000 * MS;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Error {
    Protocol,
    Capacity,
    Deadline,
    Clock,
    Authentication,
    Io,
    Retired,
    Unsupported,
    WrongThread,
    InvalidHandle,
    Cleanup,
    /// Original stock clipboard ACK is missing; paste outcome is unknown.
    ClipboardAckMissing,
    Codec,
    UnrecoverableVideoGap,
    ConnectTimeout,
    PeerIdle,
    ReliableStall,
}
impl From<galaxybridge_quic_media::Failure> for Error {
    fn from(f: galaxybridge_quic_media::Failure) -> Self {
        use galaxybridge_quic_media::Failure;
        match f {
            Failure::Capacity => Self::Capacity,
            Failure::Deadline => Self::Deadline,
            Failure::Clock => Self::Clock,
            Failure::Retired => Self::Retired,
            Failure::Unsupported => Self::Unsupported,
            Failure::Codec => Self::Codec,
            Failure::UnrecoverableVideoGap => Self::UnrecoverableVideoGap,
            _ => Self::Protocol,
        }
    }
}
impl From<std::io::Error> for Error {
    fn from(_: std::io::Error) -> Self {
        Self::Io
    }
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    Media,
    Bulk,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Side {
    Host,
    Peer,
}
impl Side {
    pub fn opposite(self) -> Self {
        if self == Self::Host {
            Self::Peer
        } else {
            Self::Host
        }
    }
}
pub(crate) fn deadline(now: u64, lifetime: u64) -> Result<u64, Error> {
    now.checked_add(lifetime).ok_or(Error::Clock)
}
