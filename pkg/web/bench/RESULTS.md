# pkg/web benchmark: full numbers and method

The short version is in the [pkg/web README](../README.md#benchmarks). This file holds every table and the method behind it.

## Benchmarks

TechEmpower's test types 1 and 2, the same two every framework here
already publishes a number for. Types 3 to 5 need a database-backed
endpoint, and none of the six apps under `bench/apps/` has one, so there
is no Bit side to compare yet.

pkg/web's requests per second divided by each peer's: above 1.00x,
pkg/web serves more.

| pkg/web / peer, req/s | pkg/web req/s | gin | express | bun | Spring Boot | ASP.NET Core |
|---|--:|--:|--:|--:|--:|--:|
| plaintext c=1 | 21,214 | 1.62x | 3.49x | 1.20x | 2.01x | 1.38x |
| plaintext c=64 | 60,864 | 1.59x | 9.53x | 1.17x | 2.70x | 0.92x |
| json c=1 | 20,691 | 1.64x | 3.16x | 1.16x | 1.90x | 1.37x |
| json c=64 | 57,283 | 1.54x | 8.83x | 1.15x | 2.52x | 0.95x |

### Plaintext, `text/plain`, 13 bytes, c=1

| Framework | req/s | req/min | spread | CPU us/req | p50 ms | p99 ms | oha cores, peak | pkg/web / this: req/s | CPU | p50 | p99 |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| pkg/web | 21,214 | 1,272,828 | 3.2% | 47.2 | 0.04 | 0.08 | 0.77 | 1.00x | 1.00x | 1.00x | 1.00x |
| gin | 13,102 | 786,090 | 5.4% | 78.1 | 0.07 | 0.12 | 0.57 | 1.62x | 0.60x | 0.58x | 0.66x |
| express | 6,070 | 364,218 | 2.6% | 187.4 | 0.14 | 0.41 | 0.38 | 3.49x | 0.25x | 0.30x | 0.20x |
| bun | 17,628 | 1,057,692 | 2.8% | 40.2 | 0.05 | 0.09 | 0.68 | 1.20x | 1.17x | 0.82x | 0.86x |
| Spring Boot | 10,542 | 632,496 | 4.6% | 98.6 | 0.09 | 0.18 | 0.50 | 2.01x | 0.48x | 0.47x | 0.45x |
| ASP.NET Core | 15,385 | 923,118 | 1.7% | 129.6 | 0.06 | 0.10 | 0.71 | 1.38x | 0.36x | 0.68x | 0.79x |

### Plaintext, `text/plain`, 13 bytes, c=64

| Framework | req/s | req/min | spread | CPU us/req | p50 ms | p99 ms | oha cores, peak | pkg/web / this: req/s | CPU | p50 | p99 |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| pkg/web | 60,864 | 3,651,840 | 2.4% | 32.7 | 1.03 | 2.19 | 2.19 | 1.00x | 1.00x | 1.00x | 1.00x |
| gin | 38,394 | 2,303,646 | 1.3% | 51.5 | 1.45 | 4.72 | 1.51 | 1.59x | 0.63x | 0.71x | 0.46x |
| express | 6,388 | 383,292 | 2.4% | 169.0 | 9.28 | 17.09 | 0.39 | 9.53x | 0.19x | 0.11x | 0.13x |
| bun | 51,849 | 3,110,958 | 2.8% | 19.5 | 1.15 | 2.54 | 1.59 | 1.17x | 1.68x | 0.89x | 0.86x |
| Spring Boot | 22,551 | 1,353,060 | 0.3% | 87.8 | 2.78 | 6.12 | 0.99 | 2.70x | 0.37x | 0.37x | 0.36x |
| ASP.NET Core | 65,804 | 3,948,240 | 14.6% | 30.2 | 0.93 | 1.72 | 2.22 | 0.92x | 1.08x | 1.11x | 1.27x |

### JSON, one object serialized per request, 27 bytes, c=1

| Framework | req/s | req/min | spread | CPU us/req | p50 ms | p99 ms | oha cores, peak | pkg/web / this: req/s | CPU | p50 | p99 |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| pkg/web | 20,691 | 1,241,466 | 5.5% | 48.4 | 0.04 | 0.08 | 0.83 | 1.00x | 1.00x | 1.00x | 1.00x |
| gin | 12,590 | 755,418 | 1.9% | 82.7 | 0.07 | 0.13 | 0.57 | 1.64x | 0.59x | 0.57x | 0.65x |
| express | 6,543 | 392,586 | 0.5% | 164.1 | 0.14 | 0.30 | 0.39 | 3.16x | 0.29x | 0.31x | 0.28x |
| bun | 17,797 | 1,067,808 | 2.4% | 41.4 | 0.05 | 0.10 | 0.71 | 1.16x | 1.17x | 0.84x | 0.87x |
| Spring Boot | 10,892 | 653,526 | 2.3% | 92.3 | 0.09 | 0.17 | 0.53 | 1.90x | 0.52x | 0.49x | 0.48x |
| ASP.NET Core | 15,112 | 906,702 | 1.1% | 131.7 | 0.06 | 0.10 | 0.65 | 1.37x | 0.37x | 0.70x | 0.80x |

### JSON, one object serialized per request, 27 bytes, c=64

| Framework | req/s | req/min | spread | CPU us/req | p50 ms | p99 ms | oha cores, peak | pkg/web / this: req/s | CPU | p50 | p99 |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| pkg/web | 57,283 | 3,436,962 | 1.1% | 34.7 | 1.09 | 2.29 | 2.02 | 1.00x | 1.00x | 1.00x | 1.00x |
| gin | 37,124 | 2,227,416 | 1.3% | 53.2 | 1.49 | 4.92 | 1.51 | 1.54x | 0.65x | 0.73x | 0.47x |
| express | 6,486 | 389,154 | 1.9% | 165.2 | 9.31 | 16.63 | 0.40 | 8.83x | 0.21x | 0.12x | 0.14x |
| bun | 49,670 | 2,980,224 | 3.5% | 20.3 | 1.22 | 2.57 | 1.59 | 1.15x | 1.71x | 0.89x | 0.89x |
| Spring Boot | 22,776 | 1,366,554 | 1.2% | 85.5 | 2.71 | 6.32 | 1.05 | 2.52x | 0.41x | 0.40x | 0.36x |
| ASP.NET Core | 60,292 | 3,617,544 | 10.1% | 33.0 | 0.97 | 2.15 | 2.05 | 0.95x | 1.05x | 1.12x | 1.07x |

> Every figure is the median of reps 2-4 of 5 measured reps of 5 seconds each, after one 10-second warmup per server that is never counted. The first and last reps are measured but not counted: the first follows the warmup's decaying load, and dropping the last as well keeps the counted window in the middle of the run. `spread` is half the min-to-max range of the counted reps as a percent of their median. `c` is the number of concurrent keep-alive connections the load generator held open. `CPU us/req` is the server's own user plus system CPU time over the rep, divided by the requests it answered.
> `pkg/web / this` divides pkg/web's median by that row's: above 1.00x is better for pkg/web on req/s, below 1.00x is better for pkg/web on CPU, p50 and p99.
> No row is load-bound: in every counted rep the load generator stayed under 3.6 of its 4 CPUs (`oha cores, peak`), so each req/s is the server's ceiling, not oha's.
> Identical responses were PROVEN before anything was timed, not assumed: all six servers answer the same body byte for byte (sha256 of each body compared against pkg/web's), the same Content-Type, a Content-Length equal to that body, and no chunked framing. Keep-alive is on for all six and is checked the same way: two requests, one TCP connection. The run refuses to measure when either proof fails.
> Round-robin, not one framework at a time. Every rep visits all six servers, rotating which goes first, and all six stay up for the whole run. The box was checked quiet before every rep and after the last: no container running that the benchmark did not start, CPU pressure (PSI) under 1 over 10 s, and under 1% of a 5 s window stalled. This run: 6 quiet checks (before every rep and after the last), 2 retries.
> Hardware: Intel(R) Core(TM) i7-6700 CPU @ 3.40GHz, 4 cores / 8 threads, Linux 7.0.14-19-pve. Each server ran on ONE physical core (2 hardware threads, CPUs 2,6); the load generator, oha, on 4 other hardware threads (CPUs 3-5,7) sharing no core with it. Both sets were read back from `/proc/<pid>/status` `Cpus_allowed_list` of the running processes, not taken on trust from the flag. The machine is a container with no CPU quota on a shared host, so read these figures as a comparison taken under one shared load, not as absolute throughput. During this run: 1-3 process(es) blocked on disk, 61.2-67.5 MB/s read, 14-14% iowait.
> Versions: Bit 920274f8d (compiler and runtime built from that commit), gin v1.12.0, Go go1.27.1, express 5.2.1, Node v22.23.2, bun 1.4.2, Spring Boot 3.5.16, JVM 21.0.12, ASP.NET Core on .NET SDK 9.0.318, load generator oha 1.16.0.
> Generated by `pkg/web/bench/run.sh` from Bit `920274f8d` on 2026-09-27T19:26:09Z. Do not edit by hand.

## Verification, exactly as it ran

```
=== byte-identical response proof, taken before any timing
--- plaintext: reference is pkg/web, 13 bytes, dffd6021bb2bd5b0
    body: Hello, World!
    bit        13 bytes  sha dffd6021bb2bd5b0  Content-Type: text/plain; charset=utf-8
    gin        13 bytes  sha dffd6021bb2bd5b0  Content-Type: text/plain; charset=utf-8
    express    13 bytes  sha dffd6021bb2bd5b0  Content-Type: text/plain; charset=utf-8
    bun        13 bytes  sha dffd6021bb2bd5b0  Content-Type: text/plain; charset=utf-8
    spring     13 bytes  sha dffd6021bb2bd5b0  Content-Type: text/plain;charset=utf-8
    aspnet     13 bytes  sha dffd6021bb2bd5b0  Content-Type: text/plain; charset=utf-8
--- json: reference is pkg/web, 27 bytes, 8811a6f55cb434d1
    body: {"message":"Hello, World!"}
    bit        27 bytes  sha 8811a6f55cb434d1  Content-Type: application/json
    gin        27 bytes  sha 8811a6f55cb434d1  Content-Type: application/json
    express    27 bytes  sha 8811a6f55cb434d1  Content-Type: application/json
    bun        27 bytes  sha 8811a6f55cb434d1  Content-Type: application/json
    spring     27 bytes  sha 8811a6f55cb434d1  Content-Type: application/json
    aspnet     27 bytes  sha 8811a6f55cb434d1  Content-Type: application/json
=== keep-alive, two requests down one connection
    bit      2 requests, 1 TCP connect(s)
    gin      2 requests, 1 TCP connect(s)
    express  2 requests, 1 TCP connect(s)
    bun      2 requests, 1 TCP connect(s)
    spring   2 requests, 1 TCP connect(s)
    aspnet   2 requests, 1 TCP connect(s)
=== CPU affinity, read back from /proc of the running processes
    bit      server pid 2824142 Cpus_allowed_list=2,6
    gin      server pid 2824209 Cpus_allowed_list=2,6
    express  server pid 2824280 Cpus_allowed_list=2,6
    bun      server pid 2824352 Cpus_allowed_list=2,6
    spring   server pid 2824422 Cpus_allowed_list=2,6
    aspnet   server pid 2824506 Cpus_allowed_list=2,6
    oha      load   pid 2825128 Cpus_allowed_list=3-5,7
=== servers pinned 2,6, load generator 3-5,7, disjoint
```

## Quiet checks, exactly as they ran

```
rep1-pre try 1: NOT quiet (foreign containers 0, cpu some avg10 5.87, 5 s stall 0.10%)
rep1-pre try 2: quiet (foreign containers 0, cpu some avg10 0.43, 5 s stall 0.10%)
rep2-pre try 1: quiet (foreign containers 0, cpu some avg10 0.50, 5 s stall 0.08%)
rep3-pre try 1: quiet (foreign containers 0, cpu some avg10 0.46, 5 s stall 0.08%)
rep4-pre try 1: quiet (foreign containers 0, cpu some avg10 0.24, 5 s stall 0.13%)
rep5-pre try 1: quiet (foreign containers 0, cpu some avg10 0.08, 5 s stall 0.10%)
rep5-post try 1: NOT quiet (foreign containers 0, cpu some avg10 3.97, 5 s stall 0.09%)
rep5-post try 2: quiet (foreign containers 0, cpu some avg10 0.29, 5 s stall 0.11%)
```
