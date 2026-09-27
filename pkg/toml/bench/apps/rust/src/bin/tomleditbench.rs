//! `toml_edit` side of pkg/toml/bench (#6048): parse into DocumentMut.
use tomlbench_rust::{Crc, run};
use toml_edit::{DocumentMut, InlineTable, Item, Table, Value};

fn count_item(i: &Item) -> i64 {
    match i {
        Item::Table(t) => count_table(t),
        Item::ArrayOfTables(a) => a.iter().map(count_table).sum(),
        Item::Value(v) => count_value(v),
        Item::None => 0,
    }
}

fn count_table(t: &Table) -> i64 {
    t.iter().map(|(_, i)| 1 + count_item(i)).sum()
}

fn count_inline(t: &InlineTable) -> i64 {
    t.iter().map(|(_, v)| 1 + count_value(v)).sum()
}

fn count_value(v: &Value) -> i64 {
    match v {
        Value::InlineTable(t) => count_inline(t),
        Value::Array(a) => a.iter().map(count_value).sum(),
        _ => 0,
    }
}

fn fold_entries<'a, T: 'a>(
    c: &Crc,
    h: u32,
    it: impl Iterator<Item = (&'a str, T)>,
    each: impl Fn(&Crc, u32, T) -> u32,
) -> u32 {
    let mut kv: Vec<(&str, T)> = it.collect();
    kv.sort_unstable_by(|a, b| a.0.as_bytes().cmp(b.0.as_bytes()));
    let mut h = c.fold_str(h, &format!("T{}:", kv.len()));
    for (k, v) in kv {
        h = c.fold_str(h, &format!("K{}:{}=", k.len(), k));
        h = each(c, h, v);
    }
    c.fold_str(h, "}")
}

fn hash_table(c: &Crc, h: u32, t: &Table) -> u32 {
    fold_entries(c, h, t.iter(), hash_item)
}

fn hash_item(c: &Crc, h: u32, i: &Item) -> u32 {
    match i {
        Item::Table(t) => hash_table(c, h, t),
        Item::ArrayOfTables(a) => {
            let mut h = c.fold_str(h, &format!("A{}:", a.len()));
            for t in a.iter() {
                h = hash_table(c, h, t);
            }
            c.fold_str(h, "]")
        }
        Item::Value(v) => hash_value(c, h, v),
        Item::None => h,
    }
}

fn hash_value(c: &Crc, h: u32, v: &Value) -> u32 {
    match v {
        Value::InlineTable(t) => fold_entries(c, h, t.iter(), hash_value),
        Value::Array(a) => {
            let mut h = c.fold_str(h, &format!("A{}:", a.len()));
            for x in a.iter() {
                h = hash_value(c, h, x);
            }
            c.fold_str(h, "]")
        }
        Value::String(s) => {
            let s = s.value();
            c.fold_str(h, &format!("S{}:{}", s.len(), s))
        }
        Value::Integer(n) => c.fold_str(h, &format!("I{};", n.value())),
        Value::Float(_) => c.fold_str(h, "F;"),
        Value::Boolean(b) => c.fold_str(h, if *b.value() { "Bt;" } else { "Bf;" }),
        Value::Datetime(d) => c.datetime(h, d.value()),
    }
}

fn main() {
    run("tomleditbench", |src| {
        let doc: DocumentMut = src.parse().unwrap_or_else(|e| {
            eprintln!("{e}");
            std::process::exit(1)
        });
        let n = count_table(doc.as_table());
        (n, Box::new(move |c: &Crc| hash_table(c, 0, doc.as_table())))
    });
}
