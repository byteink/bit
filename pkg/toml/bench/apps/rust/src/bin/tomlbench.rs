//! `toml` crate side of pkg/toml/bench (#6048): parse into toml::Table.
use tomlbench_rust::{Crc, run};
use toml::{Table, Value};

fn count(v: &Value) -> i64 {
    match v {
        Value::Table(t) => count_table(t),
        Value::Array(a) => a.iter().map(count).sum(),
        _ => 0,
    }
}

fn count_table(t: &Table) -> i64 {
    t.len() as i64 + t.values().map(count).sum::<i64>()
}

fn hash_table(c: &Crc, h: u32, t: &Table) -> u32 {
    let mut keys: Vec<&String> = t.keys().collect();
    keys.sort_unstable_by(|a, b| a.as_bytes().cmp(b.as_bytes()));
    let mut h = c.fold_str(h, &format!("T{}:", keys.len()));
    for k in keys {
        h = c.fold_str(h, &format!("K{}:{}=", k.len(), k));
        h = hash_value(c, h, &t[k.as_str()]);
    }
    c.fold_str(h, "}")
}

fn hash_value(c: &Crc, h: u32, v: &Value) -> u32 {
    match v {
        Value::Table(t) => hash_table(c, h, t),
        Value::Array(a) => {
            let mut h = c.fold_str(h, &format!("A{}:", a.len()));
            for x in a {
                h = hash_value(c, h, x);
            }
            c.fold_str(h, "]")
        }
        Value::String(s) => c.fold_str(h, &format!("S{}:{}", s.len(), s)),
        Value::Integer(n) => c.fold_str(h, &format!("I{n};")),
        Value::Float(_) => c.fold_str(h, "F;"),
        Value::Boolean(b) => c.fold_str(h, if *b { "Bt;" } else { "Bf;" }),
        Value::Datetime(d) => c.datetime(h, d),
    }
}

fn main() {
    run("tomlbench", |src| {
        let doc: Table = src.parse().unwrap_or_else(|e| {
            eprintln!("{e}");
            std::process::exit(1)
        });
        let n = count_table(&doc);
        (n, Box::new(move |c: &Crc| hash_table(c, 0, &doc)))
    });
}
