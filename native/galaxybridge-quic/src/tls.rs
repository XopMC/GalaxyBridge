use crate::{CertificateFingerprint, Error, SessionId};
use boring::{
    asn1::Asn1Time,
    bn::BigNum,
    ec::{EcGroup, EcKey},
    hash::MessageDigest,
    nid::Nid,
    pkey::{PKey, Private},
    ssl::{
        SslAlert, SslContextBuilder, SslMethod, SslOptions, SslSessionCacheMode, SslVerifyError,
        SslVerifyMode,
    },
    x509::{X509NameBuilder, X509},
};

pub const ALPN: &[u8] = b"galaxybridge-quic/1";
pub(crate) const IDLE_TIMEOUT_MS: u64 = 5000;
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
#[repr(u8)]
pub enum VerificationFailure {
    #[default]
    None,
    MissingCertificate,
    PinMismatch,
    NotYetValid,
    Expired,
    VerificationError,
}
impl VerificationFailure {
    pub(crate) fn load(value: &std::sync::atomic::AtomicU8) -> Self {
        use std::sync::atomic::Ordering;
        match value.load(Ordering::Relaxed) {
            0 => Self::None,
            1 => Self::MissingCertificate,
            2 => Self::PinMismatch,
            3 => Self::NotYetValid,
            4 => Self::Expired,
            _ => Self::VerificationError,
        }
    }
}
/// One attempt's private key remains exclusively in BoringSSL-managed memory.
pub struct Identity {
    certificate: X509,
    key: PKey<Private>,
    fingerprint: CertificateFingerprint,
}
impl Identity {
    pub fn generate() -> Result<Self, Error> {
        Self::generate_with_clock(std::time::SystemTime::now)
    }
    fn generate_with_clock(clock: impl FnOnce() -> std::time::SystemTime) -> Result<Self, Error> {
        let captured = clock()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| Error::Identity)?
            .as_secs();
        Self::generate_at(captured)
    }
    pub(crate) fn generate_at(captured: u64) -> Result<Self, Error> {
        let now = i64::try_from(captured).map_err(|_| Error::Identity)?;
        let before = Asn1Time::from_unix(now.checked_sub(120).ok_or(Error::Identity)?)?;
        let after = Asn1Time::from_unix(now.checked_add(3480).ok_or(Error::Identity)?)?;
        let group = EcGroup::from_curve_name(Nid::X9_62_PRIME256V1)?;
        let key = PKey::from_ec_key(EcKey::generate(&group)?)?;
        let mut name = X509NameBuilder::new()?;
        name.append_entry_by_text("CN", "Galaxy Bridge ephemeral attempt")?;
        let name = name.build();
        let mut builder = X509::builder()?;
        builder.set_version(2)?;
        let mut serial = [0u8; 16];
        boring::rand::rand_bytes(&mut serial)?;
        serial[0] &= 0x7f;
        serial[0] |= 1;
        let serial = BigNum::from_slice(&serial)?.to_asn1_integer()?;
        builder.set_serial_number(&serial)?;
        builder.set_subject_name(&name)?;
        builder.set_issuer_name(&name)?;
        builder.set_pubkey(&key)?;
        builder.set_not_before(&before)?;
        builder.set_not_after(&after)?;
        builder.sign(&key, MessageDigest::sha256())?;
        let certificate = builder.build();
        let fingerprint = boring::sha::sha256(&certificate.to_der()?);
        Ok(Self {
            certificate,
            key,
            fingerprint,
        })
    }
    pub fn fingerprint(&self) -> CertificateFingerprint {
        self.fingerprint
    }
    pub fn certificate_der(&self) -> Result<Vec<u8>, Error> {
        Ok(self.certificate.to_der()?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, UNIX_EPOCH};

    #[test]
    fn pacing_byte_rate_conversion_is_bounded_and_never_rounds_up() {
        for (bytes, megabits) in [
            (125_000, 1),
            (249_999, 1),
            (1_000_000, 8),
            (1_124_999, 8),
            (2_000_000, 16),
            (20_000_000, 160),
        ] {
            assert_eq!(quiche_pacing_megabits_per_second(bytes).unwrap(), megabits);
            assert!(megabits * 125_000 <= bytes);
        }
        for bytes in [0, 1, 124_999, u64::MAX] {
            assert!(matches!(
                quiche_pacing_megabits_per_second(bytes),
                Err(Error::InvalidConfiguration)
            ));
        }
        let largest = (u64::MAX / 1_000_000) * 125_000;
        assert_eq!(
            quiche_pacing_megabits_per_second(largest).unwrap(),
            u64::MAX / 1_000_000
        );
        assert!(quiche_pacing_megabits_per_second(largest + 125_000).is_err());
    }

    #[test]
    fn issuance_der_uses_one_captured_second_and_exact_one_hour_window() {
        let calls = std::cell::Cell::new(0);
        let identity = Identity::generate_with_clock(|| {
            calls.set(calls.get() + 1);
            UNIX_EPOCH + Duration::new(1_800_000_000, 999_999_999)
        })
        .unwrap();
        let certificate = X509::from_der(&identity.certificate_der().unwrap()).unwrap();
        assert_eq!(calls.get(), 1);
        assert_eq!(
            certificate.not_before(),
            Asn1Time::from_unix(1_799_999_880).unwrap().as_ref()
        );
        assert_eq!(
            certificate.not_after(),
            Asn1Time::from_unix(1_800_003_480).unwrap().as_ref()
        );
        let span = certificate
            .not_before()
            .diff(certificate.not_after())
            .unwrap();
        assert_eq!((span.days, span.secs), (0, 3600));
    }

    #[test]
    fn issuance_invalid_time_fails_without_panic_or_wrapped_dates() {
        assert!(Identity::generate_with_clock(|| UNIX_EPOCH - Duration::from_secs(1)).is_err());
        for seconds in [
            u64::MAX,
            i64::MAX as u64,
            i64::MAX as u64 - 3479,
            253_402_300_799,
        ] {
            let result = std::panic::catch_unwind(|| Identity::generate_at(seconds));
            assert!(
                matches!(result, Ok(Err(_))),
                "invalid issuance time must fail without panicking"
            );
        }
    }
    #[test]
    fn issuance_der_margins_keep_existing_inclusive_verification_boundaries() {
        let identity = Identity::generate_at(1_800_000_000).unwrap();
        let certificate = X509::from_der(&identity.certificate_der().unwrap()).unwrap();
        for (now, expected) in [
            (1_799_999_879, Err(VerificationFailure::NotYetValid)),
            (1_799_999_880, Ok(())),
            (1_799_999_881, Ok(())),
            (1_800_003_479, Ok(())),
            (1_800_003_480, Ok(())),
            (1_800_003_481, Err(VerificationFailure::Expired)),
        ] {
            assert_eq!(
                verify_dates(&certificate, Asn1Time::from_unix(now).unwrap().as_ref()),
                expected
            );
        }
    }
}

fn verify_dates(
    certificate: &X509,
    now: &boring::asn1::Asn1TimeRef,
) -> Result<(), VerificationFailure> {
    if certificate.not_before() > now {
        return Err(VerificationFailure::NotYetValid);
    }
    if certificate.not_after() < now {
        return Err(VerificationFailure::Expired);
    }
    Ok(())
}
pub fn random_session() -> Result<SessionId, Error> {
    let mut session = [0; 32];
    boring::rand::rand_bytes(&mut session)?;
    Ok(session)
}
fn quiche_pacing_megabits_per_second(bytes_per_second: u64) -> Result<u64, Error> {
    // quiche 0.29.3's BBR2 constructs Bandwidth::from_mbits_per_second
    // from Config::max_pacing_rate. Our launch/API contract is bytes/s.
    // Integer Mbps granularity: round down so the requested ceiling is never
    // exceeded. Reject sub-Mbps/overflow instead of disabling or wrapping it.
    let megabits = bytes_per_second / 125_000;
    if megabits == 0 || megabits.checked_mul(1_000_000).is_none() {
        return Err(Error::InvalidConfiguration);
    }
    Ok(megabits)
}
pub(crate) fn config(
    identity: &Identity,
    pin: CertificateFingerprint,
    failure: std::sync::Arc<std::sync::atomic::AtomicU8>,
    congestion_control: crate::CongestionControl,
    max_pacing_rate: Option<u64>,
    max_ack_delay_ms: Option<u64>,
    pacing_enabled: bool,
) -> Result<quiche::Config, Error> {
    let mut ctx = SslContextBuilder::new(SslMethod::tls())?;
    ctx.set_certificate(&identity.certificate)?;
    ctx.set_private_key(&identity.key)?;
    ctx.check_private_key()?;
    ctx.set_options(SslOptions::NO_TICKET);
    ctx.set_session_cache_mode(SslSessionCacheMode::OFF);
    ctx.set_custom_verify_callback(
        SslVerifyMode::PEER | SslVerifyMode::FAIL_IF_NO_PEER_CERT,
        move |ssl| {
            let reject = |reason: VerificationFailure| {
                failure.store(reason as u8, std::sync::atomic::Ordering::Relaxed);
                SslVerifyError::Invalid(SslAlert::BAD_CERTIFICATE)
            };
            let certificate = ssl
                .peer_certificate()
                .ok_or_else(|| reject(VerificationFailure::MissingCertificate))?;
            let der = certificate
                .to_der()
                .map_err(|_| reject(VerificationFailure::VerificationError))?;
            if !boring::memcmp::eq(&boring::sha::sha256(&der), &pin) {
                return Err(reject(VerificationFailure::PinMismatch));
            }
            let now = Asn1Time::days_from_now(0)
                .map_err(|_| reject(VerificationFailure::VerificationError))?;
            verify_dates(&certificate, now.as_ref()).map_err(reject)?;
            Ok(())
        },
    );
    let mut config = quiche::Config::with_boring_ssl_ctx_builder(quiche::PROTOCOL_VERSION, ctx)?;
    config.set_application_protos(&[ALPN])?;
    config.set_max_idle_timeout(IDLE_TIMEOUT_MS);
    config.set_max_recv_udp_payload_size(1200);
    config.set_max_send_udp_payload_size(1200);
    config.discover_pmtu(false);
    config.set_initial_max_data(256 * 1024);
    config.set_max_connection_window(256 * 1024);
    config.set_initial_max_stream_data_bidi_local(64 * 1024);
    config.set_initial_max_stream_data_bidi_remote(64 * 1024);
    config.set_max_stream_window(64 * 1024);
    config.set_initial_max_stream_data_uni(0);
    config.set_initial_max_streams_bidi(1);
    config.set_initial_max_streams_uni(0);
    config.set_disable_active_migration(true);
    config.enable_dgram(true, 32, 32);
    config.enable_pacing(pacing_enabled);
    if let Some(milliseconds) = max_ack_delay_ms {
        config.set_max_ack_delay(milliseconds);
    }
    if let Some(bytes_per_second) = max_pacing_rate {
        config.set_max_pacing_rate(quiche_pacing_megabits_per_second(bytes_per_second)?);
    }
    config.set_initial_congestion_window_packets(20);
    config.set_cc_algorithm(match congestion_control {
        crate::CongestionControl::Cubic => quiche::CongestionControlAlgorithm::CUBIC,
        crate::CongestionControl::Bbr2 => quiche::CongestionControlAlgorithm::Bbr2Gcongestion,
    });
    // Early data is never enabled, and sessions/tickets are never exported or reused.
    Ok(config)
}
