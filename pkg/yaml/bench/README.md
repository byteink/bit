# pkg/yaml/bench

The parse-throughput comparison published in [`../README.md`](../README.md)
between the `BENCH` markers: pkg/yaml against `go.yaml.in/yaml/v3` (the
maintained continuation of `gopkg.in/yaml.v3`) and `github.com/goccy/go-yaml`
in Go, libyaml in C, rapidyaml in C++ (parsing in place, and copying into its
arena first), and saphyr and yaml-rust2 in Rust.

```
./pkg/yaml/bench/run.sh             build, verify, measure, publish
./pkg/yaml/bench/run.sh --verify    build + prove every side agrees, no timing
./pkg/yaml/bench/run.sh --measure   build, verify, measure; publish nothing
./pkg/yaml/bench/run.sh --report    re-render from out/ as it stands
```

`--measure` accepts a development compiler (`BIT=./bit-out/bin/bit`), because
it writes nothing but `out/`; the publishing modes refuse one.

Runs entirely on the developer machine, no remote host: `bit` is built once
by `./make selfhost` and run natively; the two Go competitors are
cross-compiled for this host's OS/arch inside a throwaway
`${BENCH_GO_IMAGE:-golang:1.25}` docker container (`CGO_ENABLED=0`, both are
pure Go, so no cgo toolchain is needed) and then also run natively - Go is
never installed on the machine itself. The C, C++ and Rust competitors are
built the same way inside one throwaway `${BENCH_ZB_IMAGE:-ghcr.io/rust-cross/cargo-zigbuild:0.23.4}` container
(cargo-zigbuild: `zig cc`/`zig c++` at `-O3 -DNDEBUG`, and `cargo zigbuild`
with fat LTO and one codegen unit), so no C, C++ or Rust toolchain is
installed either. `BENCH_RUNS` overrides the run count (default 15).

## Versioning policy

Every competitor is pinned: `apps/yamlv3/go.{mod,sum}`,
`apps/goccy/go.{mod,sum}` and both Rust apps' `Cargo.{toml,lock}` are
committed (`cargo --locked`, and `build_go` never runs `go get`), libyaml and
rapidyaml are fetched from their official release by version and sha256
(`LIBYAML_*`, `RYML_*` in `run.sh`), and the Rust toolchain is
`${BENCH_RUST_TOOLCHAIN:-1.98.1}`. This matches the policy `pkg/toml/bench` was
converted to, not `pkg/web/bench/apps/gin`'s bare `go.mod`: a published
figure that cannot be reproduced next month, against whatever goccy/go-yaml
or yaml.v3 happened to resolve to on the day it ran, is worse than no figure.
The pinned version is read back out of `go.mod` and published in
the block's `Versions:` line, never resolved separately from what was
actually built. Bumping either pin is a deliberate, reviewed change to this
repo, the same as any other dependency version bump.

The Go image is `${BENCH_GO_IMAGE:-golang:1.25}` - same env var name and
same default tag as `pkg/toml/bench/run.sh`, so the two sibling harnesses'
Go-comparison numbers are read against the same toolchain.

## What is compared, and what is not

Every side parses two fixtures. The first is
[`data/k8s-manifests.yaml`](data/k8s-manifests.yaml), a
checked-in, deterministically generated (`data/generate.py`), 1+ MiB
multi-document Kubernetes-manifest-shaped fixture: block mappings, block
sequences, anchors and aliases (a shared `labels` block reused via `&`/`*`,
well inside the package's alias-expansion and node-count budgets), a literal
block scalar (each container's entrypoint script) and quoted scalars
(annotations with embedded `"` and `\n`). The fixture is checked in rather
than generated at run time - a benchmark whose input changes per run cannot
be compared across commits. The second,
[`data/yaml-features.yaml`](data/yaml-features.yaml) (`generate.py features`),
leans on the syntax the first barely touches: per-document anchors reused by
aliases on scalars, mappings and sequences in block and flow context, every
block scalar header (`|`, `|-`, `>`, `>-`), nested and empty flow
collections, single-quoted `''` escapes, double-quoted `\t \n \" \\ \x \u`
escapes and a multi-line double-quoted fold.

**The sides are proven to agree before anything is timed.** Each binary
parses the fixture once and prints `docs=<N> nodes=<N> crc=<u32>`: the
document count, the total node count, and a CRC-32C over a canonical,
order-preserving encoding of every key and scalar value in the document
(`canonicalWalk` in `apps/bit/main.bit` and both Go apps, `apps/canon/canon.h`
for C and C++, `apps/canon/canon.rs` for Rust - every copy must stay
byte-for-byte the same encoding, and each file says so). `run.sh` aborts with
a named `CHECKSUM MISMATCH` error before it measures anything if any two
sides disagree on either fixture, proven in [`RESULTS.md`](RESULTS.md) by a temporary one-line
mutation on the yaml.v3 side. This matters more for YAML than most formats:
implicit-typing rules differ subtly between libraries (`no` as a string vs. a
YAML 1.1 boolean is the classic case), and a throughput number over a
disagreement measures nothing.

Both Go competitors decode into their library's order-preserving
representation (`yaml.Node` for yaml.v3, `MapSlice` under `UseOrderedMap()`
for goccy) rather than a plain `map[string]interface{}` - Go's built-in maps
have no defined iteration order, which would make the checksum
non-reproducible even when the parse itself is correct. Every other side
also builds its library's full tree of the whole stream before walking it:
libyaml's document API, rapidyaml's `Tree` (aliases expanded by
`Tree::resolve()`), and saphyr's and yaml-rust2's `Yaml`. libyaml and
rapidyaml do not type scalars, so `canon.h` applies the YAML 1.2 core schema
to plain scalars exactly as pkg/yaml does. saphyr types scalars in the walk
rather than its loader (`apps/saphyr/src/main.rs` says why: it reads an empty
plain scalar as `""`, where the core schema and every other side read null).

## Reading the numbers

Each figure is a trimmed mean over `BENCH_RUNS` (default 15) single-process
runs, timed end to end by `run.sh`'s `time_run`: a microsecond wall clock
around fork, exec and wait, with `/usr/bin/time -l` (macOS) in the chain for
the peak RSS (its own `real` line has 10 ms resolution, too coarse for the
C and C++ peers). The interleaved run order and the estimator are
[`bench/run.sh`](../../../bench/run.sh)'s, with the reasoning in that file's
`trimmean` comment for why a trimmed mean beats a bare minimum or median
here. MB/s is the fixture's byte size divided by that trimmed wall
time; peak RSS is the trimmed mean of `/usr/bin/time -l`'s own maximum
resident set size. The checksum computation runs inside the timed region on
every side (not just the untimed `--verify` proof), so every side is timed on
comparable work rather than one being penalized for an extra pass another's
driver does not pay.

`out/` is generated and gitignored. The Go build/module caches, the Rust
toolchain, the crate registry and the fetched C/C++ sources live outside
the repo tree entirely - `${BENCH_CACHE_DIR:-$TMPDIR/bit-bench-gomod/yaml}` -
because Go writes module-cache files mode 0444, and a cache under `out/`
survives into `git worktree remove`, which then fails with Permission
denied.
