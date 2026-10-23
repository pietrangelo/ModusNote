//! The values of the formats, with the lengths of the Dart domain.

use core::fmt;

use super::wire::{Malformed, Reader};

pub const WORKSPACE_ID_LENGTH: usize = 16;
pub const KEY_LENGTH: usize = 32;
pub const SIGNATURE_LENGTH: usize = 64;
/// X-Wing (ML-KEM-768 + X25519).
pub const ENCRYPTION_KEY_LENGTH: usize = 1216;
pub const IDENTITY_LENGTH: usize = KEY_LENGTH + ENCRYPTION_KEY_LENGTH;
/// X-Wing ciphertext, then an envelope: version, 24-byte nonce, a 32-byte
/// key and its 16-byte tag.
pub const SEALED_KEY_LENGTH: usize = 1120 + 1 + 24 + 32 + 16;
const ENVELOPE_VERSION_AT: usize = 1120;
const ENVELOPE_VERSION: u8 = 1;

/// Opaque, random workspace identifier; the only workspace data the server
/// sees in clear.
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct WorkspaceId(pub [u8; WORKSPACE_ID_LENGTH]);

impl WorkspaceId {
    /// Only 32 lower-case hex digits, as `WorkspaceId.parse`.
    pub fn parse_hex(text: &str) -> Option<Self> {
        decode_hex(text).map(Self)
    }

    pub fn to_hex(&self) -> String {
        encode_hex(&self.0)
    }
}

impl fmt::Debug for WorkspaceId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "WorkspaceId({})", self.to_hex())
    }
}

/// A member is its Ed25519 public key, so the server cannot remap who is who.
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct MemberKey(pub [u8; KEY_LENGTH]);

impl MemberKey {
    pub fn parse_hex(text: &str) -> Option<Self> {
        decode_hex(text).map(Self)
    }

    pub fn to_hex(&self) -> String {
        encode_hex(&self.0)
    }
}

impl fmt::Debug for MemberKey {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "MemberKey({})", self.to_hex())
    }
}

#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Signature(pub [u8; SIGNATURE_LENGTH]);

impl fmt::Debug for Signature {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Signature({}…)", encode_hex(&self.0[..8]))
    }
}

/// A device's signing key and X-Wing encryption key, as one value.
#[derive(Clone, PartialEq, Eq)]
pub struct PublicIdentity(Box<[u8; IDENTITY_LENGTH]>);

impl PublicIdentity {
    pub fn read(reader: &mut Reader<'_>) -> Result<Self, Malformed> {
        Ok(Self(Box::new(reader.array()?)))
    }

    pub fn key(&self) -> MemberKey {
        let mut key = [0; KEY_LENGTH];
        key.copy_from_slice(&self.0[..KEY_LENGTH]);
        MemberKey(key)
    }

    pub fn bytes(&self) -> &[u8] {
        &self.0[..]
    }
}

impl fmt::Debug for PublicIdentity {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "PublicIdentity({:?})", self.key())
    }
}

/// What a member may do. The codes are the signed ones (`Role.wireCode`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    Owner,
    Editor,
    Viewer,
}

impl Role {
    pub fn from_wire(code: u8) -> Option<Self> {
        match code {
            1 => Some(Self::Owner),
            2 => Some(Self::Editor),
            3 => Some(Self::Viewer),
            _ => None,
        }
    }

    pub fn wire(self) -> u8 {
        match self {
            Self::Owner => 1,
            Self::Editor => 2,
            Self::Viewer => 3,
        }
    }

    /// Adds records to the log and key bundles.
    pub fn manages_members(self) -> bool {
        self == Self::Owner
    }

    /// Adds rows and changes blobs.
    pub fn writes_content(self) -> bool {
        self != Self::Viewer
    }
}

/// Checks a sealed key the way `SealedKey.parse` does: its length is fixed,
/// and its envelope must be of the one known version.
pub fn check_sealed_key(bytes: &[u8]) -> Result<(), Malformed> {
    if bytes.len() != SEALED_KEY_LENGTH || bytes[ENVELOPE_VERSION_AT] != ENVELOPE_VERSION {
        return Err(Malformed("malformed sealed key"));
    }
    Ok(())
}

pub fn encode_hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push(DIGITS[usize::from(byte >> 4)] as char);
        out.push(DIGITS[usize::from(byte & 0xf)] as char);
    }
    out
}

/// Lower-case hex of exactly `N` bytes.
pub fn decode_hex<const N: usize>(text: &str) -> Option<[u8; N]> {
    let digits = text.as_bytes();
    if digits.len() != N * 2 {
        return None;
    }
    let value = |digit: u8| match digit {
        b'0'..=b'9' => Some(digit - b'0'),
        b'a'..=b'f' => Some(digit - b'a' + 10),
        _ => None,
    };
    let mut out = [0; N];
    for (i, [high, low]) in digits.as_chunks::<2>().0.iter().enumerate() {
        out[i] = value(*high)? << 4 | value(*low)?;
    }
    Some(out)
}
