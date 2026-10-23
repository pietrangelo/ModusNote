//! Signed requests: what a device signs to call the server (`SignedRequest`
//! in Dart) and the `MN1` Authorization header (`RequestCredential`), or the
//! same credential as the live channel's WebSocket subprotocol token.
//!
//! Signed: `modusnote.request.v1 | method length | method | path length |
//! path | millis | nonce | BLAKE2b-256 of the body`.

use super::values::{KEY_LENGTH, MemberKey, SIGNATURE_LENGTH, Signature};

const LABEL: &[u8] = b"modusnote.request.v1";
const SCHEME: &str = "MN1 ";
/// A browser cannot set `Authorization` on a WebSocket, and a subprotocol
/// token has no spaces: the live channel carries `mn1.` and the same parts.
const TOKEN: &str = "mn1.";
pub const NONCE_LENGTH: usize = 16;
pub const MAX_PATH_LENGTH: usize = 2048;
const MAX_MILLIS: u64 = (1 << 53) - 1;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RequestError {
    Method,
    Path,
    Time,
}

/// The bytes a device signed for this request, or why the request is not
/// one a device could have signed.
pub fn signable_request(
    method: &str,
    path: &str,
    millis: u64,
    nonce: &[u8; NONCE_LENGTH],
    body_digest: &[u8; 32],
) -> Result<Vec<u8>, RequestError> {
    if method.is_empty() || method.len() > 16 || !method.bytes().all(|b| b.is_ascii_uppercase()) {
        return Err(RequestError::Method);
    }
    if !path.starts_with("/api/") || path.len() > MAX_PATH_LENGTH || !path.bytes().all(|b| (0x21..=0x7e).contains(&b)) {
        return Err(RequestError::Path);
    }
    if millis > MAX_MILLIS {
        return Err(RequestError::Time);
    }
    let mut out = Vec::with_capacity(LABEL.len() + 1 + method.len() + 2 + path.len() + 8 + 48);
    out.extend_from_slice(LABEL);
    out.push(method.len() as u8);
    out.extend_from_slice(method.as_bytes());
    out.extend_from_slice(&(path.len() as u16).to_be_bytes());
    out.extend_from_slice(path.as_bytes());
    out.extend_from_slice(&millis.to_be_bytes());
    out.extend_from_slice(nonce);
    out.extend_from_slice(body_digest);
    Ok(out)
}

/// `MN1 key.millis.nonce.signature`, binary parts in canonical base64url
/// without padding.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Credential {
    pub key: MemberKey,
    pub millis: u64,
    pub nonce: [u8; NONCE_LENGTH],
    pub signature: Signature,
}

impl Credential {
    /// None for anything that is not exactly such a header.
    pub fn parse(header: &str) -> Option<Self> {
        Self::parse_parts(header.strip_prefix(SCHEME)?)
    }

    /// `mn1.key.millis.nonce.signature`, the live channel's subprotocol
    /// token; None for anything else.
    pub fn parse_token(token: &str) -> Option<Self> {
        Self::parse_parts(token.strip_prefix(TOKEN)?)
    }

    fn parse_parts(rest: &str) -> Option<Self> {
        let mut parts = rest.split('.');
        let (key, millis, nonce, signature) = (parts.next()?, parts.next()?, parts.next()?, parts.next()?);
        if parts.next().is_some() {
            return None;
        }
        Some(Self {
            key: MemberKey(decode::<KEY_LENGTH>(key)?),
            millis: parse_millis(millis)?,
            nonce: decode(nonce)?,
            signature: Signature(decode::<SIGNATURE_LENGTH>(signature)?),
        })
    }
}

fn parse_millis(text: &str) -> Option<u64> {
    let digits = text.as_bytes();
    if digits.is_empty()
        || digits.len() > 16
        || !digits.iter().all(u8::is_ascii_digit)
        || (digits.len() > 1 && digits[0] == b'0')
    {
        return None;
    }
    text.parse().ok().filter(|millis| *millis <= MAX_MILLIS)
}

const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// Exactly `N` bytes in canonical unpadded base64url: no other symbols and
/// no stray bits in the last one, so each value has one spelling.
fn decode<const N: usize>(text: &str) -> Option<[u8; N]> {
    let symbols = text.as_bytes();
    if symbols.len() != (N * 4).div_ceil(3) {
        return None;
    }
    let value = |symbol: u8| ALPHABET.iter().position(|s| *s == symbol).map(|v| v as u32);
    let mut out = [0u8; N];
    let mut bits = 0u32;
    let mut held = 0u32;
    let mut at = 0;
    for symbol in symbols {
        bits = bits << 6 | value(*symbol)?;
        held += 6;
        if held >= 8 {
            held -= 8;
            out[at] = (bits >> held) as u8;
            at += 1;
            bits &= (1 << held) - 1;
        }
    }
    (at == N && bits == 0).then_some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_only_the_canonical_spelling() {
        assert_eq!(decode::<1>("AA"), Some([0]));
        assert_eq!(decode::<1>("_w"), Some([255]));
        assert_eq!(decode::<1>("_x"), None);
        assert_eq!(decode::<1>("AA="), None);
        assert_eq!(decode::<1>("A+"), None);
        assert_eq!(decode::<2>("AAA"), Some([0, 0]));
        assert_eq!(decode::<3>("AAAA"), Some([0, 0, 0]));
    }

    #[test]
    fn millis_are_plain_decimal() {
        assert_eq!(parse_millis("0"), Some(0));
        assert_eq!(parse_millis("1792700000000"), Some(1_792_700_000_000));
        for text in ["", "01", "-1", "+1", "1e3", "9007199254740992", "12345678901234567"] {
            assert_eq!(parse_millis(text), None, "{text}");
        }
    }

    #[test]
    fn the_subprotocol_token_is_the_header_with_a_dot_for_the_space() {
        let key = format!("{}A", "_".repeat(42));
        let nonce = "A".repeat(22);
        let signature = format!("{}A", "B".repeat(85));
        let parts = format!("{key}.1792700000000.{nonce}.{signature}");
        let header = Credential::parse(&format!("MN1 {parts}")).unwrap();

        assert_eq!(Credential::parse_token(&format!("mn1.{parts}")), Some(header));
        for token in [
            format!("MN1 {parts}"),
            format!("MN1.{parts}"),
            format!("mn1 {parts}"),
            format!("mn1.{parts}.x"),
            format!("mn1.{key}.01.{nonce}.{signature}"),
            format!("mn1.{key}.1.{nonce}={signature}"),
            parts.clone(),
        ] {
            assert_eq!(Credential::parse_token(&token), None, "{token}");
        }
        assert_eq!(Credential::parse(&format!("mn1.{parts}")), None, "a header keeps its scheme");
    }

    #[test]
    fn refuses_what_no_device_signs() {
        let nonce = [0; NONCE_LENGTH];
        let digest = [0; 32];
        let sign = |method: &str, path: &str, millis| signable_request(method, path, millis, &nonce, &digest);
        assert!(sign("GET", "/api/info", 0).is_ok());
        assert_eq!(sign("get", "/api/info", 0), Err(RequestError::Method));
        assert_eq!(sign("", "/api/info", 0), Err(RequestError::Method));
        assert_eq!(sign(&"P".repeat(17), "/api/info", 0), Err(RequestError::Method));
        assert_eq!(sign("GET", "/rows", 0), Err(RequestError::Path));
        assert_eq!(sign("GET", "/api/a b", 0), Err(RequestError::Path));
        assert_eq!(sign("GET", "/api/é", 0), Err(RequestError::Path));
        assert_eq!(sign("GET", &format!("/api/{}", "a".repeat(2048)), 0), Err(RequestError::Path));
        assert_eq!(sign("GET", "/api/info", 1 << 53), Err(RequestError::Time));
    }
}
