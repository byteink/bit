// yaml-rust2's side of pkg/yaml's parse-throughput comparison (#6049).
//
// Reads the fixture named by argv[1], loads every document into yaml-rust2's
// order-preserving `Yaml` tree (YamlLoader::load_from_str), then walks them
// and prints "docs=<N> nodes=<N> crc=<u32>", encoded by ../canon/canon.rs
// exactly as ../bit/main.bit encodes it. The loader expands an alias into a
// clone of its anchored node, so the walk never sees one. run.sh times the
// whole process.
#[path = "../../canon/canon.rs"]
mod canon;

use canon::{Canon, crc32c, fatal};
use yaml_rust2::{Yaml, YamlLoader};

fn walk(y: &Yaml, c: &mut Canon) -> i64 {
    match y {
        Yaml::Hash(m) => {
            c.num(b'M', m.len() as i64);
            m.iter().map(|(k, v)| walk(k, c) + walk(v, c)).sum::<i64>() + 1
        }
        Yaml::Array(s) => {
            c.num(b'Q', s.len() as i64);
            s.iter().map(|v| walk(v, c)).sum::<i64>() + 1
        }
        Yaml::Null => {
            c.null();
            1
        }
        Yaml::Boolean(b) => {
            c.boolean(*b);
            1
        }
        Yaml::Integer(i) => {
            c.num(b'I', *i);
            1
        }
        Yaml::String(s) => {
            c.string(s);
            1
        }
        other => fatal(&format!("no canonical spelling for {other:?}")),
    }
}

fn main() {
    let path = std::env::args().nth(1).unwrap_or_else(|| {
        eprintln!("usage: yamlrust2bench <path-to-yaml-file>");
        std::process::exit(2)
    });
    let src = std::fs::read_to_string(&path).unwrap_or_else(|e| fatal(&format!("read {path}: {e}")));
    let docs = YamlLoader::load_from_str(&src).unwrap_or_else(|e| fatal(&format!("parse: {e}")));

    let mut c = Canon::new();
    let nodes: i64 = docs.iter().map(|d| walk(d, &mut c)).sum();
    println!("docs={} nodes={} crc={}", docs.len(), nodes, crc32c(&c.buf));
}
