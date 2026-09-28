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
docker, resolved by `scripts/x64host.sh`. It builds the pkg/web server itself,
with this tree's compiler and a runtime built by that same compiler, then
`bit build --target x86_64-linux`, refusing when the compiler, runtime,
stdlib or pkg/web sources have uncommitted changes, so the table names the
commit it measured.
`remote.sh` is the half that runs over there: it takes the box's
`/tmp/benchlock` directory lock for the whole run, builds the five peers,
proves all six answer identical responses, reads back what cores each process
actually got, and measures.

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
they do not move together for every framework. Every server runs on one
physical core (both of its hardware threads) and the load generator on every
other CPU the container has, so at c=64 the server, not oha, is the ceiling;
a row where oha reached 90% of its CPUs in any counted rep is flagged. After
one 10-second warmup per server, five 5-second reps are taken round-robin
across all six servers, rotating which goes first, and each figure is the
median of reps 2-4 with the spread beside it. Before every rep and after the
last, the box must be quiet: no container the run did not start, CPU pressure
(PSI) under 1 over 10 s, and under 1% of a 5-second window stalled; a check
retries a bounded number of times and the run stops rather than time a noisy
box. Every ratio is pkg/web divided by one peer. The box is an unquota'd
container on a shared host, so the absolute rates are not comparable to
bare-metal published figures.

`out/` is generated and gitignored: `results.csv` is every rep, `verify.txt`
the identical-response and affinity proof, `quiet.txt` every quiet check,
`env.txt` the box as measured at run time, `versions.txt` what each framework
resolved to. `RESULTS.md` carries the published block with `verify.txt` and
`quiet.txt` beneath it.
