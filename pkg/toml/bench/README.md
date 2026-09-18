# pkg/toml/bench

The parse-throughput comparison published in [`../README.md`](../README.md)
between the BENCH markers: pkg/toml against `github.com/BurntSushi/toml` and
`github.com/pelletier/go-toml/v2`, the two Go TOML libraries in wide use.

```
./run.sh               build, verify, measure, publish
./run.sh --verify-only build + verify agreement, stop before timing
./run.sh --report      re-render from out/ as it stands, no rebuild
```

Needs `docker` (to cross-compile the two Go competitors without installing a
Go toolchain on this machine) and a `bit-out/bin/bit` already built at the
repo root (`./make selfhost`). Everything runs on this machine - unlike
`pkg/web/bench`, nothing here needs a remote Linux host: pkg/toml's own
binary builds locally, and the two Go competitors are cross-compiled for
this host's OS/arch and then run natively, never from inside the container.

Exclusive: dispatch alone, nothing else running - `./run.sh`'s timed section
is a wall-clock measurement like every other bench harness in this repo.

## What is compared, and how it is proven safe to compare

`data/fixture.toml` is a Cargo-manifest shape scaled past 1 MB (so process
startup does not dominate what is timed): tables, arrays of tables, inline
tables, dotted keys, all four TOML 1.0.0 date-time forms, and multi-line
strings, both basic and literal. Checked in, never regenerated at run time -
a benchmark whose input changes per run cannot be compared across commits.

Each of `apps/bit`, `apps/burntsushi` and `apps/gotoml` builds to a CLI with
two modes:

```
<binary> parse <file>      read + parse once, print an entry count
<binary> checksum <file>   read + parse once, print an entry count and a hash
```

`run.sh` calls `checksum` once per side and refuses to time anything unless
all three lines match byte for byte - the same "prove identical responses
before timing anything" contract `pkg/web/bench/remote.sh` holds for HTTP
responses, here for a parsed document. The checksum is CRC-32C, folded over
every table (entries sorted by key, since both Go libraries decode a table
into a Go map with no defined iteration order - sorting is the only order
every side can agree on) and array (left in source order, which a Go slice
preserves), with every temporal value folded as its own zero-padded
`YYYY-MM-DD`/`HH:MM:SS.nnnnnnnnn` components rather than a library's own
`String()`, so a formatting difference between three independent time
libraries can never register as a mismatch. `parse` mode never computes this
- folding and sorting the whole tree on every timed run would measure
parse+hash throughput, not parse throughput - so the 15 timed runs `run.sh`
takes per side only ever call `parse`.

## Reading the numbers

Same estimator as every other `bench/run.sh` in this repository: a trimmed
mean (drop the slowest fifth of the runs, mean what is left) of wall clock
and of `/usr/bin/time -l`'s peak RSS, both over one process invocation per
run - see `bench/run.sh:34-59` at the repo root (#4040) for why trimming
beats a plain minimum once a language runtime is in the mix.

`out/` is generated and gitignored: `<name>.rs`/`<name>.ms` are every timed
run's wall-clock seconds and peak-RSS bytes, `bin/` the three built binaries,
`cache/` the Go build/module caches (kept between runs so a re-measure does
not re-download either competitor).
