//! # Crypto
//!
//! Adapters for the ledger's ports, on RustCrypto: Ed25519 verification as
//! strict as libsodium's, and BLAKE2b-256 as `crypto_generichash`.

use blake2::Blake2b;
use blake2::digest::Digest;
use blake2::digest::consts::U32;
use curve25519_dalek::edwards::CompressedEdwardsY;
use ed25519_dalek::{Signature as DalekSignature, VerifyingKey};
use ledger::{MemberKey, Signature, SignatureCheck};

/// Ed25519 that refuses everything libsodium's `crypto_sign_verify_detached`
/// refuses: a key that is not the canonical encoding of a point, a key or R
/// of small order, an S that is not reduced. `verify_strict` covers the
/// last two; the first is checked here, because decompression alone also
/// accepts y ≥ p.
#[derive(Clone, Copy, Debug, Default)]
pub struct StrictEd25519;

impl SignatureCheck for StrictEd25519 {
    fn verifies(&self, key: &MemberKey, message: &[u8], signature: &Signature) -> bool {
        let compressed = CompressedEdwardsY(key.0);
        let Some(point) = compressed.decompress() else { return false };
        if point.compress() != compressed {
            return false;
        }
        let Ok(key) = VerifyingKey::from_bytes(&key.0) else { return false };
        key.verify_strict(message, &DalekSignature::from_bytes(&signature.0)).is_ok()
    }
}

/// BLAKE2b with a 32-byte output and no key: `crypto_generichash`, the
/// digest a device signs for a request body.
pub fn blake2b_256(bytes: &[u8]) -> [u8; 32] {
    Blake2b::<U32>::digest(bytes).into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blake2b_256_is_libsodiums_generichash() {
        // crypto_generichash(32) of the empty string, from libsodium.
        assert_eq!(
            blake2b_256(b""),
            [
                0x0e, 0x57, 0x51, 0xc0, 0x26, 0xe5, 0x43, 0xb2, 0xe8, 0xab, 0x2e, 0xb0, 0x60, 0x99, 0xda, 0xa1, 0xd1,
                0xe5, 0xdf, 0x47, 0x77, 0x8f, 0x77, 0x87, 0xfa, 0xab, 0x45, 0xcd, 0xf1, 0x2f, 0xe3, 0xa8,
            ]
        );
    }
}
