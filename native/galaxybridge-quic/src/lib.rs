pub mod bootstrap;
pub mod endpoint;
pub mod rate_probe;
pub mod tls;
pub mod wire;
pub use endpoint::{Endpoint, Stats};

#[derive(Debug)]
pub enum Error {
    InvalidConfiguration,
    Identity,
    Transport,
    Io(std::io::Error),
}
impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Self::Io(e)
    }
}
impl From<boring::error::ErrorStack> for Error {
    fn from(_: boring::error::ErrorStack) -> Self {
        Self::Identity
    }
}
impl From<quiche::Error> for Error {
    fn from(_: quiche::Error) -> Self {
        Self::Transport
    }
}

pub type SessionId = [u8; 32];
pub type CertificateFingerprint = [u8; 32];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Lane {
    Datagram,
    Reliable,
}
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum CongestionControl {
    #[default]
    Cubic,
    Bbr2,
}
#[derive(Debug, PartialEq, Eq)]
pub struct Message {
    pub lane: Lane,
    pub sequence: u64,
    pub payload: Vec<u8>,
}
#[derive(Debug, PartialEq, Eq)]
pub struct Received {
    pub lane: Lane,
    pub sequence: u64,
    pub payload: Vec<u8>,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Admission {
    Accepted,
    Backpressured,
    TooLarge,
    Expired,
    Retired,
}
#[derive(Debug, PartialEq, Eq)]
pub struct InvalidRecord;
