// saphyr's side of pkg/yaml's parse-throughput comparison (#6049).
//
// Reads the fixture named by argv[1], loads every document into saphyr's
// order-preserving `Yaml` tree through the zero-copy `&str` parser
// (saphyr_parser::Parser::new_from_str; `load_from_str` would go through a
// char iterator instead), then walks them and prints
// "docs=<N> nodes=<N> crc=<u32>", encoded by ../canon/canon.rs exactly as
// ../bit/main.bit encodes it. saphyr's loader expands an alias into a clone
// of its anchored node, so the walk never sees one. run.sh times the whole
// process.
//
// TYPING RUNS IN THE WALK, NOT THE LOADER (early_parse(false)), for one
// reason: saphyr 0.1.0 types an EMPTY plain scalar (`key:` with no value) as
// the string "", where the YAML 1.2 core schema and every other side here
// (yaml-rust2, by the same author, included) read null. After the loader has
// typed it, a plain "" and a quoted "" are indistinguishable, so the walk
// takes the untyped representation, maps plain-and-empty to null, and hands
// everything else to saphyr's own resolver - the same function, the same
// cost, called one step later than the loader would.
#[path = "../../canon/canon.rs"]
mod canon;

use canon::{Canon, crc32c, fatal};
use saphyr::{Scalar, ScalarStyle, Yaml, YamlLoader};

fn scalar(s: Scalar, c: &mut Canon) -> i64 {
    match s {
        Scalar::Null => c.null(),
        Scalar::Boolean(b) => c.boolean(b),
        Scalar::Integer(i) => c.num(b'I', i),
        Scalar::String(s) => c.string(&s),
        other => fatal(&format!("no canonical spelling for {other:?}")),
    }
    1
}

fn walk(y: Yaml, c: &mut Canon) -> i64 {
    match y {
        Yaml::Mapping(m) => {
            c.num(b'M', m.len() as i64);
            m.into_iter().map(|(k, v)| walk(k, c) + walk(v, c)).sum::<i64>() + 1
        }
        Yaml::Sequence(s) => {
            c.num(b'Q', s.len() as i64);
            s.into_iter().map(|v| walk(v, c)).sum::<i64>() + 1
        }
        Yaml::Representation(v, style, tag) => {
            if style == ScalarStyle::Plain && v.is_empty() {
                return scalar(Scalar::Null, c);
            }
            let s = Scalar::parse_from_cow_and_metadata(v, style, tag.as_ref());
            scalar(s.unwrap_or_else(|| fatal("unresolvable tagged scalar")), c)
        }
        Yaml::Value(s) => scalar(s, c),
        other => fatal(&format!("no canonical spelling for {other:?}")),
    }
}

fn main() {
    let path = std::env::args().nth(1).unwrap_or_else(|| {
        eprintln!("usage: saphyrbench <path-to-yaml-file>");
        std::process::exit(2)
    });
    let src = std::fs::read_to_string(&path).unwrap_or_else(|e| fatal(&format!("read {path}: {e}")));
    let mut loader: YamlLoader<Yaml> = YamlLoader::default();
    loader.early_parse(false);
    let mut parser = saphyr_parser::Parser::new_from_str(&src);
    parser.load(&mut loader, true).unwrap_or_else(|e| fatal(&format!("parse: {e}")));
    let docs = loader.into_documents();

    let mut c = Canon::new();
    let ndocs = docs.len();
    let nodes: i64 = docs.into_iter().map(|d| walk(d, &mut c)).sum();
    println!("docs={} nodes={} crc={}", ndocs, nodes, crc32c(&c.buf));
}
