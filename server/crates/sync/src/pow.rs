//! Proof of work: what founding a workspace or answering a code costs a
//! device, a second or two, instead of an email address. It binds the
//! purpose, the target and the day, so work done for one cannot be spent on
//! another or saved up.

use crate::Hasher;

const LABEL: &[u8] = b"modusnote.pow.v1";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PowPurpose {
    Found,
    Answer,
}

impl PowPurpose {
    fn code(self) -> u8 {
        match self {
            Self::Found => 1,
            Self::Answer => 2,
        }
    }
}

/// Whether BLAKE2b-256 of `label | purpose | target | day | nonce` starts
/// with `bits` zero bits. `day` is days since the Unix epoch, UTC; the
/// caller accepts today's and yesterday's.
pub fn pow_satisfied(
    hasher: &impl Hasher,
    purpose: PowPurpose,
    target: &[u8],
    day: u32,
    nonce: &[u8; 16],
    bits: u32,
) -> bool {
    let mut message = Vec::with_capacity(LABEL.len() + 1 + 1 + target.len() + 4 + 16);
    message.extend_from_slice(LABEL);
    message.push(purpose.code());
    message.push(target.len() as u8);
    message.extend_from_slice(target);
    message.extend_from_slice(&day.to_be_bytes());
    message.extend_from_slice(nonce);
    leading_zero_bits(&hasher.blake2b_256(&message)) >= bits
}

fn leading_zero_bits(digest: &[u8; 32]) -> u32 {
    let mut bits = 0;
    for byte in digest {
        if *byte == 0 {
            bits += 8;
        } else {
            return bits + byte.leading_zeros();
        }
    }
    bits
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_leading_zero_bits() {
        let mut digest = [0xff; 32];
        assert_eq!(leading_zero_bits(&digest), 0);
        digest[0] = 0;
        digest[1] = 0x1f;
        assert_eq!(leading_zero_bits(&digest), 11);
        assert_eq!(leading_zero_bits(&[0; 32]), 256);
    }
}
