# std/metrics

Counters, gauges and histograms, exposed as Prometheus text-format
exposition (`# HELP`/`# TYPE` plus one line per series). This is a
production-observability primitive, not a profiler: for CPU sampling see
`std/prof` instead.

Metrics are held in an explicit `Registry` rather than a hidden global one:
Bit's module-level `let` may hold only untraced scalars, fixed arrays of
them, or raw pointers, never a class, slice or map (SPEC section 11.11), so
there is no cell a default registry could live in. Construct one, keep it,
and call its methods — the same shape `std/sync`'s `Mutex`, `WaitGroup` and
`std/rand`'s `Rand` already use.

```bit
import { newRegistry } from "std/metrics"

fn main() {
  let reg = newRegistry(1000) // max distinct label-value combinations PER metric
  let hits = reg.counter("http_requests_total", "Total HTTP requests.", ["method", "code"])
  hits.inc(["GET", "200"])
  print(reg.exposition())
}
```

Registration (`counter`/`gauge`/`histogram`) is a startup-time act: an
invalid metric or label name, or registering the same metric name twice,
panics immediately rather than producing a corrupt scrape later. Recording
a value (`inc`/`add`/`set`/`observe`) never panics on caller-supplied label
values — an unbounded label (a user id, a raw request path) is the failure
mode this module exists to prevent, not to reproduce. Each metric's
distinct label-value combinations are capped at the registry's own
`capMax`; past the cap, the new series is silently dropped, every existing
series is left untouched, and the registry's own
`bit_metrics_dropped_series_total` counter (rendered in every exposition,
alongside your own metrics) increments by one.

## The registry

### `Registry`

Holds every metric registered on it and renders them as one Prometheus
text-format exposition body.

### `newRegistry(capMax: i64): Registry`

A fresh, empty registry. `capMax` bounds the number of distinct
label-value combinations EACH metric registered on it may accumulate, and
is reserved memory, not just an enforcement ceiling: every Counter/Gauge
preallocates `capMax` value cells, and every Histogram preallocates
`capMax * (len(buckets)+1)` bucket-count cells, at registration time - so
none of them ever grows after construction. Size it to the cardinality you
actually expect. Panics if `capMax <= 0`.

### `Registry.counter(name: string, help: string, labels: []string): Counter`

Registers and returns a new counter. `labels` names the label
DIMENSIONS (e.g. `["method", "code"]`), not values - values are supplied
per call to `Counter.inc`/`Counter.add`. Panics if `name` or any label name
violates the Prometheus name grammar, or if `name` is already registered
on this registry (by any metric kind).

### `Registry.gauge(name: string, help: string, labels: []string): Gauge`

Registers and returns a new gauge. Same name/label rules as
`Registry.counter`.

### `Registry.histogram(name: string, help: string, labels: []string, buckets: []f64): Histogram`

Registers and returns a new histogram. `buckets` are the finite bucket
upper bounds, strictly increasing and non-empty (`defaultBuckets()` below
is a ready-made latency ladder); the "+Inf" bucket is implicit and always
rendered last. Panics on an invalid name/label, a duplicate name, or an
empty or non-increasing `buckets`.

### `Registry.exposition(): string`

Renders every metric on this registry as a Prometheus text-format
exposition body - `# HELP`/`# TYPE` plus one line per series - followed by
this registry's own `bit_metrics_dropped_series_total` series. Safe to call
concurrently with recording (`inc`/`add`/`set`/`observe`) on any metric.

## Counter

A monotonically non-decreasing value, reset only by process restart -
request counts, error counts, bytes served.

### `Counter.inc(labelValues: []string)`

Adds 1 to the series identified by `labelValues`, which must have exactly
as many entries as this Counter's declared labels, in the same order. Pass
`[]string(0)` for a Counter with no labels.

### `Counter.add(delta: f64, labelValues: []string)`

Adds `delta` to the series identified by `labelValues`. Panics if `delta`
is negative - a Counter never decreases; use `Gauge` for a value that can.

## Gauge

A value that can go up or down - an in-flight request count, a queue
depth, a temperature.

### `Gauge.set(value: f64, labelValues: []string)`

Overwrites the series identified by `labelValues` with `value`.

### `Gauge.add(delta: f64, labelValues: []string)`

Adds `delta` (positive or negative) to the series identified by
`labelValues`.

### `Gauge.inc(labelValues: []string)`

Adds 1 to the series identified by `labelValues`.

### `Gauge.dec(labelValues: []string)`

Subtracts 1 from the series identified by `labelValues`.

## Histogram

Buckets observations into a cumulative `le` ladder plus a running sum and
count - the shape Prometheus's `histogram_quantile()` and rate-of-sum
queries expect.

### `Histogram.observe(value: f64, labelValues: []string)`

Records one observation of `value` for the series identified by
`labelValues`.

### `defaultBuckets(): []f64`

The default bucket boundaries, in seconds, suitable for request/RPC
latency - the same values as Prometheus's own client library's default
histogram buckets: `0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10`.
