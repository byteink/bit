// The Rust half of canon.h (#6049): the canonical walk's token encoding and
// CRC-32C, shared by ../saphyr and ../yamlrust2 through `#[path]`. Both
// libraries type scalars themselves (YAML 1.2 core schema), so only the
// writer lives here, not canon.h's resolver. Must stay byte-for-byte the
// encoding ../bit/main.bit writes; canon.h's header lists the tokens.
use std::io::Write;

pub struct Canon {
    pub buf: Vec<u8>,
}

impl Canon {
    pub fn new() -> Canon {
        Canon { buf: Vec::with_capacity(1 << 20) }
    }

    // `tag`, then v in decimal, then ';' - "M<n>;", "Q<n>;" and "I<v>;".
    pub fn num(&mut self, tag: u8, v: i64) {
        self.buf.push(tag);
        write!(self.buf, "{v};").expect("write to Vec cannot fail");
    }

    pub fn string(&mut self, s: &str) {
        write!(self.buf, "S{}:", s.len()).expect("write to Vec cannot fail");
        self.buf.extend_from_slice(s.as_bytes());
        self.buf.push(b';');
    }

    pub fn null(&mut self) {
        self.buf.extend_from_slice(b"N;");
    }

    pub fn boolean(&mut self, v: bool) {
        self.buf.extend_from_slice(if v { b"Bt;" } else { b"Bf;" });
    }
}

pub fn fatal(what: &str) -> ! {
    eprintln!("canon: {what}");
    std::process::exit(1)
}

// CRC-32C (Castagnoli), hardware instructions on aarch64 as canon.h does.
pub fn crc32c(data: &[u8]) -> u32 {
    let mut c: u32 = !0;
    #[cfg(target_arch = "aarch64")]
    {
        use std::arch::aarch64::{__crc32cb, __crc32cd};
        let mut words = data.chunks_exact(8);
        for w in &mut words {
            // SAFETY: the crc feature is baseline on every aarch64-apple-darwin CPU.
            c = unsafe { __crc32cd(c, u64::from_le_bytes(w.try_into().unwrap())) };
        }
        for &b in words.remainder() {
            // SAFETY: as above.
            c = unsafe { __crc32cb(c, b) };
        }
    }
    #[cfg(not(target_arch = "aarch64"))]
    for &b in data {
        c ^= b as u32;
        for _ in 0..8 {
            c = (c >> 1) ^ (0x82f6_3b78 & (c & 1).wrapping_neg());
        }
    }
    !c
}
