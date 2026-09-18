# pkg/yaml/bench

The parse-throughput comparison published in [`../README.md`](../README.md)
between the `BENCH` markers: pkg/yaml against `github.com/goccy/go-yaml` and
`gopkg.in/yaml.v3`, both pure Go.

```
./pkg/yaml/bench/run.sh            build, verify, measure, publish
./pkg/yaml/bench/run.sh --verify   build + prove all three sides agree, no timing
./pkg/yaml/bench/run.sh --report   re-render from out/ as it stands
```

Runs entirely on the developer machine, no remote host: `bit` is built once
by `./make selfhost` and run natively; the two Go competitors are
cross-compiled for this host's OS/arch inside a throwaway `golang` docker
container (`CGO_ENABLED=0`, both are pure Go, so no cgo toolchain is needed)
and then also run natively - Go is never installed on the machine itself.
`BENCH_RUNS` overrides the run count (default 15).

## What is compared, and what is not

All three parse [`data/k8s-manifests.yaml`](data/k8s-manifests.yaml), a
checked-in, deterministically generated (`data/generate.py`), 1+ MiB
multi-document Kubernetes-manifest-shaped fixture: block mappings, block
sequences, anchors and aliases (a shared `labels` block reused via `&`/`*`,
well inside the package's alias-expansion and node-count budgets), a literal
block scalar (each container's entrypoint script) and quoted scalars
(annotations with embedded `"` and `\n`). The fixture is checked in rather
than generated at run time - a benchmark whose input changes per run cannot
be compared across commits.

**The sides are proven to agree before anything is timed.** Each binary
parses the fixture once and prints `docs=<N> nodes=<N> crc=<u32>`: the
document count, the total node count, and a CRC-32C over a canonical,
order-preserving encoding of every key and scalar value in the document
(`canonicalWalk` in each `apps/*/main.{bit,go}` - the three copies must stay
byte-for-byte identical, and each file says so). `run.sh` aborts with a named
`CHECKSUM MISMATCH` error before it measures anything if any of the three
disagree, proven in [`RESULTS.md`](RESULTS.md) by a temporary one-line
mutation on the yaml.v3 side. This matters more for YAML than most formats:
implicit-typing rules differ subtly between libraries (`no` as a string vs. a
YAML 1.1 boolean is the classic case), and a throughput number over a
disagreement measures nothing.

Both Go competitors decode into their library's order-preserving
representation (`yaml.Node` for yaml.v3, `MapSlice` under `UseOrderedMap()`
for goccy) rather than a plain `map[string]interface{}` - Go's built-in maps
have no defined iteration order, which would make the checksum
non-reproducible even when the parse itself is correct.

## Reading the numbers

Each figure is a trimmed mean over `BENCH_RUNS` (default 15) single-process
runs, timed end to end with `/usr/bin/time -l` (macOS) - the same technique
[`bench/run.sh`](../../../bench/run.sh) uses for the top-level language
benchmarks, including the interleaved run order and the reasoning in that
file's `trimmean` comment for why a trimmed mean beats a bare minimum or
median here. MB/s is the fixture's byte size divided by that trimmed wall
time; peak RSS is the trimmed mean of `/usr/bin/time -l`'s own maximum
resident set size. The checksum computation runs inside the timed region on
every side (not just the untimed `--verify` proof), so all three are timed on
comparable work rather than the Go sides being penalized for an extra pass
Bit's own driver does not pay.
