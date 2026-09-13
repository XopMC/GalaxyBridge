use crate::{
    bulk::{u32_at, u64_at},
    Error,
};
use galaxybridge_quic::{
    bootstrap::{Reply, Request},
    tls::Identity,
};
use galaxybridge_quic_media::Context;
use std::net::IpAddr;
use std::{
    net::SocketAddr,
    time::{Duration, Instant},
};
pub const VERSION: &str = "4.1-gb-sync.1";
/// Closed status frame on the authenticated media role (not GQM1/GQB1).
/// Original peer binding is repeated and checked; raw stdout is never carried.
pub fn encode_display(
    binding: &Binding,
    status: crate::process::DisplayStatus,
) -> Result<Vec<u8>, Error> {
    binding.validate()?;
    status.validate()?;
    if binding.context.capture_kind != 1 {
        return Err(Error::Protocol);
    }
    let mut bytes = b"GDS1".to_vec();
    bytes.extend([1, status.kind, 0, 0]);
    bytes.extend(binding.context.generation.to_be_bytes());
    bytes.extend(binding.context.scid.to_be_bytes());
    bytes.extend(binding.context.display_id.to_be_bytes());
    bytes.extend(binding.context.target_token.to_be_bytes());
    for n in [status.width, status.height, status.density, status.display] {
        bytes.extend(n.to_be_bytes());
    }
    Ok(bytes)
}
pub fn decode_display(
    binding: &Binding,
    bytes: &[u8],
) -> Result<crate::process::DisplayStatus, Error> {
    if bytes.len() != 48
        || &bytes[..4] != b"GDS1"
        || bytes[4] != 1
        || bytes[6..8] != [0, 0]
        || binding.context.capture_kind != 1
        || u64_at(bytes, 8) != binding.context.generation
        || u32_at(bytes, 16) != binding.context.scid
        || u32_at(bytes, 20) != binding.context.display_id
        || u64_at(bytes, 24) != binding.context.target_token
    {
        return Err(Error::Protocol);
    }
    crate::process::DisplayStatus {
        kind: bytes[5],
        width: u32_at(bytes, 32),
        height: u32_at(bytes, 36),
        density: u32_at(bytes, 40),
        display: u32_at(bytes, 44),
    }
    .validate()
}
// Compiled into the backend from the exact source-built producer artifact.
include!(concat!(env!("OUT_DIR"), "/producer_pin.rs"));
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Binding {
    pub nonce: [u8; 32],
    pub context: Context,
    pub sidecar_sha: [u8; 32],
}
impl Binding {
    pub fn validate(&self) -> Result<(), Error> {
        galaxybridge_quic_media::Core::new(self.context.clone(), 0)?;
        if self.nonce == [0; 32] || self.sidecar_sha == [0; 32] || self.context.scid > 0x7fffffff {
            return Err(Error::Protocol);
        }
        Ok(())
    }
    fn bytes(&self) -> Result<Vec<u8>, Error> {
        self.validate()?;
        let c = &self.context;
        let mut b = self.nonce.to_vec();
        b.extend(c.generation.to_be_bytes());
        b.extend(c.scid.to_be_bytes());
        b.extend([c.capture_kind, c.enabled, 0, 0]);
        b.extend(c.display_id.to_be_bytes());
        b.extend(c.target_token.to_be_bytes());
        b.extend(self.sidecar_sha);
        b.extend(PRODUCER_SHA);
        b.push(VERSION.len() as u8);
        b.extend(VERSION.as_bytes());
        Ok(b)
    }
    fn decode(b: &[u8]) -> Result<Self, Error> {
        if b.len() != 125 + VERSION.len()
            || b[46..48] != [0, 0]
            || b[92..124] != PRODUCER_SHA
            || b[124] as usize != VERSION.len()
            || &b[125..] != VERSION.as_bytes()
        {
            return Err(Error::Protocol);
        }
        let binding = Self {
            nonce: b[..32].try_into().unwrap(),
            context: Context {
                session: [0; 32],
                generation: u64_at(b, 32),
                scid: u32_at(b, 40),
                capture_kind: b[44],
                enabled: b[45],
                display_id: u32_at(b, 48),
                target_token: u64_at(b, 52),
            },
            sidecar_sha: b[60..92].try_into().unwrap(),
        };
        binding.validate()?;
        Ok(binding)
    }
}
const ROLE_COUNT: usize = 3;

pub struct Requests {
    pub binding: Binding,
    pub roles: [Request; ROLE_COUNT],
}
pub struct Replies {
    pub binding: Binding,
    pub roles: [Reply; ROLE_COUNT],
}
impl Requests {
    pub fn fresh(
        mut binding: Binding,
        expected_ip: IpAddr,
    ) -> Result<(Self, [Identity; ROLE_COUNT]), Error> {
        let identities = [
            Identity::generate().map_err(|_| Error::Authentication)?,
            Identity::generate().map_err(|_| Error::Authentication)?,
            Identity::generate().map_err(|_| Error::Authentication)?,
        ];
        let sessions = [
            galaxybridge_quic::tls::random_session().map_err(|_| Error::Authentication)?,
            galaxybridge_quic::tls::random_session().map_err(|_| Error::Authentication)?,
            galaxybridge_quic::tls::random_session().map_err(|_| Error::Authentication)?,
        ];
        binding.context.session = sessions[0];
        Ok((
            Self {
                binding,
                roles: std::array::from_fn(|i| Request {
                    session: sessions[i],
                    fingerprint: identities[i].fingerprint(),
                    expected_ip,
                }),
            },
            identities,
        ))
    }
    pub fn encode(&self) -> Result<Vec<u8>, Error> {
        if !request_roles_valid(&self.roles) {
            return Err(Error::Protocol);
        }
        let parts = [
            self.roles[0].encode().map_err(|_| Error::Protocol)?,
            self.roles[1].encode().map_err(|_| Error::Protocol)?,
            self.roles[2].encode().map_err(|_| Error::Protocol)?,
        ];
        bundle(1, &self.binding, parts)
    }
    pub fn decode(bytes: &[u8]) -> Result<Self, Error> {
        let (mut binding, parts) = unbundle(bytes, 1)?;
        let roles = [
            Request::decode(parts[0]).map_err(|_| Error::Protocol)?,
            Request::decode(parts[1]).map_err(|_| Error::Protocol)?,
            Request::decode(parts[2]).map_err(|_| Error::Protocol)?,
        ];
        if !request_roles_valid(&roles) {
            return Err(Error::Protocol);
        }
        binding.context.session = roles[0].session;
        Ok(Self { binding, roles })
    }
}
impl Replies {
    pub fn encode(&self) -> Result<Vec<u8>, Error> {
        if !reply_roles_valid(&self.roles) {
            return Err(Error::Protocol);
        }
        let parts = [
            self.roles[0].encode().map_err(|_| Error::Protocol)?,
            self.roles[1].encode().map_err(|_| Error::Protocol)?,
            self.roles[2].encode().map_err(|_| Error::Protocol)?,
        ];
        bundle(2, &self.binding, parts)
    }
    pub fn decode(bytes: &[u8], request: &Requests) -> Result<Self, Error> {
        let (mut binding, p) = unbundle(bytes, 2)?;
        if binding.bytes()? != request.binding.bytes()? {
            return Err(Error::Authentication);
        }
        let roles = [
            Reply::decode(p[0], &request.roles[0].session).map_err(|_| Error::Authentication)?,
            Reply::decode(p[1], &request.roles[1].session).map_err(|_| Error::Authentication)?,
            Reply::decode(p[2], &request.roles[2].session).map_err(|_| Error::Authentication)?,
        ];
        if !reply_roles_valid(&roles) {
            return Err(Error::Authentication);
        }
        binding.context.session = roles[0].session;
        Ok(Self { binding, roles })
    }
}
fn request_roles_valid(roles: &[Request; ROLE_COUNT]) -> bool {
    roles.iter().all(|r| {
        r.session != [0; 32] && r.fingerprint != [0; 32] && r.expected_ip == roles[0].expected_ip
    }) && (0..ROLE_COUNT).all(|i| {
        (i + 1..ROLE_COUNT).all(|j| {
            roles[i].session != roles[j].session && roles[i].fingerprint != roles[j].fingerprint
        })
    })
}
fn reply_roles_valid(roles: &[Reply; ROLE_COUNT]) -> bool {
    roles
        .iter()
        .all(|r| r.fingerprint != [0; 32] && r.port != 0)
        && (0..ROLE_COUNT).all(|i| {
            (i + 1..ROLE_COUNT).all(|j| {
                roles[i].fingerprint != roles[j].fingerprint && roles[i].port != roles[j].port
            })
        })
}
fn bundle(
    direction: u8,
    binding: &Binding,
    parts: [Vec<u8>; ROLE_COUNT],
) -> Result<Vec<u8>, Error> {
    let c = binding.bytes()?;
    let mut b = b"GBP3".to_vec();
    b.extend([direction, 0]);
    b.extend((c.len() as u16).to_be_bytes());
    b.extend(c);
    for (i, p) in parts.into_iter().enumerate() {
        b.extend([i as u8 + 1, 0]);
        b.extend((p.len() as u16).to_be_bytes());
        b.extend(p);
    }
    if b.len() > 4096 {
        return Err(Error::Capacity);
    }
    let mut framed = (b.len() as u32).to_be_bytes().to_vec();
    framed.extend(b);
    Ok(framed)
}
fn unbundle(bytes: &[u8], direction: u8) -> Result<(Binding, [&[u8]; ROLE_COUNT]), Error> {
    if bytes.len() < 12
        || bytes.len() > 4100
        || u32_at(bytes, 0) as usize != bytes.len() - 4
        || &bytes[4..8] != b"GBP3"
        || bytes[8] != direction
        || bytes[9] != 0
    {
        return Err(Error::Protocol);
    }
    let n = u16::from_be_bytes([bytes[10], bytes[11]]) as usize;
    if n > bytes.len() - 12 {
        return Err(Error::Protocol);
    }
    let binding = Binding::decode(&bytes[12..12 + n])?;
    let mut at = 12 + n;
    let mut parts = [&bytes[0..0]; ROLE_COUNT];
    for (i, part) in parts.iter_mut().enumerate() {
        if at + 4 > bytes.len() || bytes[at] != i as u8 + 1 || bytes[at + 1] != 0 {
            return Err(Error::Protocol);
        }
        let n = u16::from_be_bytes([bytes[at + 2], bytes[at + 3]]) as usize;
        at += 4;
        if n > bytes.len() - at {
            return Err(Error::Protocol);
        }
        *part = &bytes[at..at + n];
        at += n;
    }
    if at != bytes.len() {
        return Err(Error::Protocol);
    }
    Ok((binding, parts))
}
/// Reads one bounded frame without an unbounded pipe reader thread.
#[derive(Default)]
pub struct Frame {
    bytes: Vec<u8>,
    total: Option<usize>,
}
impl Frame {
    pub fn push(&mut self, b: &[u8]) -> Result<usize, Error> {
        let limit = self.total.unwrap_or(4);
        let n = b.len().min(limit - self.bytes.len());
        self.bytes.extend_from_slice(&b[..n]);
        if self.total.is_none() && self.bytes.len() == 4 {
            let n = u32_at(&self.bytes, 0) as usize;
            if n == 0 || n > 4096 {
                return Err(Error::Protocol);
            }
            self.total = Some(n + 4);
            self.bytes.reserve_exact(n);
        }
        Ok(n)
    }
    pub fn complete(&self) -> bool {
        self.total == Some(self.bytes.len())
    }
    pub fn bytes(&self) -> &[u8] {
        &self.bytes
    }
}

pub fn accept_stdio() -> Result<(Binding, [galaxybridge_quic::Endpoint; ROLE_COUNT]), Error> {
    accept_stdio_with_media_max_pacing_rate(None)
}
pub fn accept_stdio_with_media_max_pacing_rate(
    max_pacing_rate: Option<u64>,
) -> Result<(Binding, [galaxybridge_quic::Endpoint; ROLE_COUNT]), Error> {
    accept_stdio_inner(None, 0, max_pacing_rate)
}
pub fn accept_stdio_until(
    whole: Option<Instant>,
) -> Result<(Binding, [galaxybridge_quic::Endpoint; ROLE_COUNT]), Error> {
    accept_stdio_inner(whole, 0, None)
}
#[cfg(feature = "qa")]
pub fn accept_stdio_fault(
    fault: u8,
) -> Result<(Binding, [galaxybridge_quic::Endpoint; ROLE_COUNT]), Error> {
    if !(1..=3).contains(&fault) {
        return Err(Error::Protocol);
    }
    accept_stdio_inner(None, fault, None)
}
fn accept_stdio_inner(
    whole: Option<Instant>,
    _fault: u8,
    media_max_pacing_rate: Option<u64>,
) -> Result<(Binding, [galaxybridge_quic::Endpoint; ROLE_COUNT]), Error> {
    crate::process::nonblocking(0)?;
    crate::process::nonblocking(1)?;
    let started = Instant::now();
    let deadline = whole
        .unwrap_or(started + Duration::from_secs(5))
        .min(started + Duration::from_secs(5));
    let mut frame = Frame::default();
    let mut b = [0; 4096];
    while !frame.complete() {
        if Instant::now() >= deadline {
            return Err(Error::Deadline);
        }
        let n = unsafe { libc::read(0, b.as_mut_ptr().cast(), b.len()) };
        if n == 0 {
            return Err(Error::Retired);
        }
        if n < 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::WouldBlock {
                std::thread::sleep(Duration::from_millis(1));
                continue;
            }
            return Err(Error::Io);
        }
        let mut at = 0;
        while at < n as usize {
            if frame.complete() {
                return Err(Error::Protocol);
            }
            at += frame.push(&b[at..n as usize])?;
        }
    }
    let request = Requests::decode(frame.bytes())?;
    let mut endpoints = Vec::with_capacity(ROLE_COUNT);
    let mut replies = Vec::with_capacity(ROLE_COUNT);
    for (_index, role) in request.roles.iter().enumerate() {
        let identity = Identity::generate().map_err(|_| Error::Authentication)?;
        let fingerprint = identity.fingerprint();
        let bind = SocketAddr::new(
            if role.expected_ip.is_ipv4() {
                "0.0.0.0".parse().unwrap()
            } else {
                "::".parse().unwrap()
            },
            0,
        );
        let (session, fingerprint_expected) = {
            #[cfg(feature = "qa")]
            {
                let mut session = role.session;
                if _index == 1 && _fault == 2 {
                    session[0] ^= 1;
                }
                (session, role.fingerprint)
            }
            #[cfg(not(feature = "qa"))]
            {
                (role.session, role.fingerprint)
            }
        };
        let mut endpoint = galaxybridge_quic::Endpoint::listen_with_transport_options(
            bind,
            role.expected_ip,
            session,
            identity,
            fingerprint_expected,
            if _index == 0 {
                galaxybridge_quic::CongestionControl::Bbr2
            } else {
                galaxybridge_quic::CongestionControl::Cubic
            },
            if _index == 0 {
                media_max_pacing_rate
            } else {
                None
            },
            // The dedicated input connection must not inherit QUIC's 25 ms
            // delayed-ACK profile.  One millisecond remains RFC-visible and
            // keeps sparse click/key traffic below the interactive budget.
            (_index == 2).then_some(1),
            // Input is sparse and already bounded by its independent CUBIC
            // window. Do not delay it behind the media packet pacer.
            _index != 2,
        )
        .map_err(|_| Error::Authentication)?;
        if _index == 0 {
            endpoint.preserve_committed_datagrams();
        }
        let reply_pin = {
            #[cfg(feature = "qa")]
            {
                let mut pin = fingerprint;
                if _index == 1 && _fault == 1 {
                    pin[0] ^= 1;
                }
                pin
            }
            #[cfg(not(feature = "qa"))]
            {
                fingerprint
            }
        };
        replies.push(Reply {
            session: role.session,
            fingerprint: reply_pin,
            port: endpoint.local_addr().map_err(|_| Error::Io)?.port(),
        });
        endpoints.push(endpoint);
    }
    let reply_binding = {
        #[cfg(feature = "qa")]
        {
            let mut binding = request.binding.clone();
            if _fault == 3 {
                binding.context.target_token = binding
                    .context
                    .target_token
                    .checked_add(1)
                    .ok_or(Error::Capacity)?;
            }
            binding
        }
        #[cfg(not(feature = "qa"))]
        {
            request.binding.clone()
        }
    };
    let replies = Replies {
        binding: reply_binding,
        roles: replies.try_into().ok().ok_or(Error::Protocol)?,
    }
    .encode()?;
    let mut at = 0;
    while at < replies.len() {
        if Instant::now() >= deadline {
            return Err(Error::Deadline);
        }
        let n = unsafe { libc::write(1, replies[at..].as_ptr().cast(), replies.len() - at) };
        if n > 0 {
            at += n as usize;
        } else if n < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::WouldBlock
        {
            std::thread::sleep(Duration::from_millis(1));
        } else {
            return Err(Error::Io);
        }
    }
    Ok((
        request.binding,
        endpoints.try_into().ok().ok_or(Error::Protocol)?,
    ))
}
pub fn lifetime_eof() -> Result<bool, Error> {
    let mut b = [0; 1];
    let n = unsafe { libc::read(0, b.as_mut_ptr().cast(), 1) };
    if n == 0 {
        Ok(true)
    } else if n < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::WouldBlock {
        Ok(false)
    } else {
        Err(Error::Protocol)
    }
}
