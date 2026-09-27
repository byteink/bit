//! The canonical checksum shared by both Rust sides, byte for byte the
//! stream ../bit/main.bit folds (see its header): CRC-32C, table keys
//! sorted bytewise, arrays in source order, temporals as components.

pub struct Crc([u32; 256]);

impl Crc {
    pub fn new() -> Crc {
        let mut t = [0u32; 256];
        for (i, e) in t.iter_mut().enumerate() {
            let mut c = i as u32;
            for _ in 0..8 {
                c = if c & 1 != 0 { (c >> 1) ^ 0x82F6_3B78 } else { c >> 1 };
            }
            *e = c;
        }
        Crc(t)
    }

    pub fn fold(&self, h: u32, s: &[u8]) -> u32 {
        let mut c = !h;
        for &b in s {
            c = self.0[((c ^ b as u32) & 0xff) as usize] ^ (c >> 8);
        }
        !c
    }

    pub fn fold_str(&self, h: u32, s: &str) -> u32 {
        self.fold(h, s.as_bytes())
    }

    pub fn datetime(&self, h: u32, d: &toml::value::Datetime) -> u32 {
        use toml::value::Offset;
        let date = d.date.map(|x| format!("{:04}-{:02}-{:02}", x.year, x.month, x.day));
        let time = d.time.map(|t| {
            format!(
                "{:02}:{:02}:{:02}.{:09}",
                t.hour,
                t.minute,
                t.second.unwrap_or(0),
                t.nanosecond.unwrap_or(0)
            )
        });
        let s = match (date, time, d.offset) {
            (Some(a), Some(b), Some(off)) => {
                let m: i32 = match off {
                    Offset::Z => 0,
                    Offset::Custom { minutes } => minutes as i32,
                };
                let sign = if m < 0 { '-' } else { '+' };
                let m = m.abs();
                format!("O{a}T{b}{sign}{:02}:{:02};", m / 60, m % 60)
            }
            (Some(a), Some(b), None) => format!("N{a}T{b};"),
            (Some(a), None, _) => format!("D{a};"),
            (None, Some(b), _) => format!("M{b};"),
            (None, None, _) => String::new(),
        };
        self.fold_str(h, &s)
    }
}

pub fn run(name: &str, parse: impl Fn(&str) -> (i64, Box<dyn Fn(&Crc) -> u32>)) {
    let a: Vec<String> = std::env::args().collect();
    if a.len() < 3 {
        eprintln!("usage: {name} <parse|checksum> <file.toml>");
        std::process::exit(1);
    }
    let src = std::fs::read_to_string(&a[2]).unwrap_or_else(|e| {
        eprintln!("{e}");
        std::process::exit(1)
    });
    let (n, hash) = parse(&src);
    if a[1] == "checksum" {
        println!("entries={n} hash={}", hash(&Crc::new()));
    } else {
        println!("entries={n}");
    }
    // Every other side exits with its tree still live; dropping it here
    // would be a teardown walk only the Rust sides paid for.
    std::mem::forget(hash);
    std::mem::forget(src);
}
