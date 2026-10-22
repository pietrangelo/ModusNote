//! Big-endian, bounds-checked reading, as `WireReader` in Dart: any short,
//! long or unknown input is [`Malformed`] and nothing else.

/// Bytes that are not a value of the format.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Malformed(pub &'static str);

#[derive(Debug)]
pub struct Reader<'a> {
    bytes: &'a [u8],
    offset: usize,
}

impl<'a> Reader<'a> {
    pub fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, offset: 0 }
    }

    pub fn offset(&self) -> usize {
        self.offset
    }

    pub fn remaining(&self) -> usize {
        self.bytes.len() - self.offset
    }

    pub fn take(&mut self, length: usize) -> Result<&'a [u8], Malformed> {
        if length > self.remaining() {
            return Err(Malformed("truncated"));
        }
        let piece = &self.bytes[self.offset..self.offset + length];
        self.offset += length;
        Ok(piece)
    }

    pub fn array<const N: usize>(&mut self) -> Result<[u8; N], Malformed> {
        let mut out = [0; N];
        out.copy_from_slice(self.take(N)?);
        Ok(out)
    }

    pub fn u8(&mut self) -> Result<u8, Malformed> {
        Ok(self.array::<1>()?[0])
    }

    pub fn u16(&mut self) -> Result<u16, Malformed> {
        Ok(u16::from_be_bytes(self.array()?))
    }

    pub fn u32(&mut self) -> Result<u32, Malformed> {
        Ok(u32::from_be_bytes(self.array()?))
    }

    pub fn finish(&self) -> Result<(), Malformed> {
        if self.remaining() == 0 { Ok(()) } else { Err(Malformed("trailing bytes")) }
    }
}
