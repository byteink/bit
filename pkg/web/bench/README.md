# pkg/web/bench

The throughput comparison published in [`../README.md`](../README.md) between
the BENCH markers: pkg/web against gin, express, bun, Spring Boot and ASP.NET
Core on TechEmpower's test types 1 (plaintext) and 2 (JSON).

```
./pkg/web/bench/run.sh            ship, build, measure, publish
./pkg/web/bench/run.sh --reuse    measure against the tree already on the box
./pkg/web/bench/run.sh --report   re-render from the last results.csv
```

`run.sh` runs on a developer machine and needs an x86-64 Linux host with
docker, resolved by `scripts/x64host.sh`. `remote.sh` is the half that runs
over there: it builds the six servers, proves they answer identical responses,
reads back what cores each process actually got, and measures.

## What is compared, and what is not

Every server under `apps/` answers `/plaintext` and `/json` with the same body
byte for byte, the same Content-Type, a Content-Length equal to that body and
no chunked framing. `remote.sh` proves that on every run, before it times
anything, and refuses to measure when it fails. Three of the six needed a
change to get there and each one is commented where it was made: express's
`res.set` appends the mime database's default charset, Spring streams Jackson
chunked unless the handler declares a length, and Kestrel frames chunked
unless `ContentLength` is set.

Types 3 to 5 need a database. `pkg/postgres`'s type codecs are not implemented yet,
so they are not measured and the published block says so rather than leaving
the gap to be rediscovered.

## Reading the numbers

Two concurrency levels are published, c=1 and c=64, because on this hardware
they do not move together for every framework. Each figure is the median of
five 5-second reps taken round-robin across all six servers, with the spread
beside it. The box is an unquota'd LXC container sharing six cores with
neighbours that are invisible from inside it, so the ranking is the result and
the absolute rates are not comparable to bare-metal published figures.

`out/` is generated and gitignored: `results.csv` is every rep, `verify.txt`
the identical-response and affinity proof, `env.txt` the box as measured at
run time, `versions.txt` what each framework resolved to.
