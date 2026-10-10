# Requests per minute: time series

<!-- doctest: per-block -->

Inkwell's API wants a chart of requests per minute, per region, for the last
day. The obvious Redis answer is a counter key per minute
(`requests:eu:2026-10-10T14:03`) that you `INCR`, expire after a day, and read
back with 1,440 `GET`s. It works until you want the average over five minutes,
the busiest minute across all regions, or last week.

Redis keeps that data as a time series: a key of timestamped numbers, with
labels you select on and aggregation done by the server. `r.timeseries(key)`
is one series; `r.timeseriesMulti()` is everything that picks series by label.
Both are cheap values, like every handle in this package. A series key is its
own type (`TYPE` says `TSDB-TYPE`), and Redis 8 ships the module built in.

A **timestamp** is unix milliseconds, an `i64`, as the server stores it. A
**duration** (a retention, a bucket) is a nanosecond `int` like everywhere in
this package, so `Minute` and `Hour` from `std/time` work, and is rounded up
to a whole millisecond on the way out.

## One series for one region

`create` makes the series. Its options say how long to keep samples
(`retention`), what a label is, and what to do when two samples share a
timestamp. Every field of `SeriesOptions` is left to the server's default until
you set it, and `labels` is a plain map literal:

```bit
import { open, SeriesOptions, DuplicatePolicy, Encoding, Ignore, Stamp } from "redis"
import { Hour } from "std/time"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let eu = r.timeseries("inkwell:requests:eu")

  eu.create(
    SeriesOptions{
      retention = Option.Some(24 * Hour),
      duplicatePolicy = Option.Some(DuplicatePolicy.Sum),
      encoding = Option.Some(Encoding.Compressed),
      chunkSize = Option.Some(4096),
      ignore = Option.Some(Ignore{ maxTimeDiff = 1000, maxValueDiff = 0.0 }),
      labels = { "region": "eu", "app": "inkwell" },
    },
  )?

  // The server stamps the sample with its own clock.
  let at = eu.add(Stamp.Auto, 1.0)?
  println("stored at ${at}")
  r.close()
  return
}
```

`retention` keeps samples younger than the newest one minus that duration
(`Option.Some(0)` keeps everything). `DuplicatePolicy` decides a sample at an
existing timestamp: `Block` refuses it (the default), `First` and `Last` keep
one, `Min` and `Max` keep the smaller or larger, `Sum` adds them.
`ignore` drops a sample that is within `maxTimeDiff` milliseconds and
`maxValueDiff` of the last one, which keeps a flat reading from filling the
series. `labels` is the `name -> value` pairs the filters below select on; an
empty map sets none. `create` on a key that exists is the server's error.

`add(ts, value)` answers the timestamp it stored at. `Stamp.At(ms)` is an
explicit one, `Stamp.Auto` the server's clock. A third argument,
`SeriesOptions`, creates the series on the fly when the key is new, and a
fourth, `Option.Some(DuplicatePolicy.Sum)`, overrides the series' policy for
that one sample.

## Counting

For requests, you do not want to compute the next value: `incrBy(delta)` adds to
the newest sample and stores the result as a new one, in one command. `decrBy`
subtracts. Each takes a timestamp (default `Stamp.Auto`) and `SeriesOptions`,
and creates the series if the key is new:

```bit
import { open, Stamp } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let eu = r.timeseries("inkwell:requests:eu")

  eu.incrBy(1.0)?
  eu.incrBy(1.0, Stamp.At(1700000061_000))?
  eu.decrBy(0.5, Stamp.At(1700000062_000))?

  match (eu.get()?) {
    Some(s) => println("newest: ${s.value} at ${s.ts}")
    None => println("no samples yet")
  }
  r.close()
  return
}
```

`get()` is the newest sample, `None` for an empty series. `get(true)` also
reports a compaction rule's open bucket (see the last section).

## Reading a window

`range(from, to)` returns the samples from `from` to `to`, both included,
oldest first; `revrange` is newest first. A bound is a `Stamp`: `Stamp.At(ms)`,
or `Stamp.Oldest` and `Stamp.Newest` for the open ends. `RangeOptions` narrows
what comes back:

```bit
import { open, RangeOptions, ValueRange, Stamp } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let eu = r.timeseries("inkwell:requests:eu")

  let all = eu.range(Stamp.Oldest, Stamp.Newest)?
  println("${len(all)} samples")

  let newestThree = eu.revrange(Stamp.Oldest, Stamp.Newest, RangeOptions{ count = 3 })?
  let busy = eu.range(
    Stamp.At(1700000000_000),
    Stamp.At(1700000600_000),
    RangeOptions{ valueRange = Option.Some(ValueRange{ min = 100.0, max = 1000.0 }) },
  )?
  let exact = eu.range(
    Stamp.Oldest,
    Stamp.Newest,
    RangeOptions{ onlyTs = [1700000061_000, 1700000062_000] },
  )?
  println("${len(newestThree)} newest, ${len(busy)} busy, ${len(exact)} exact")
  r.close()
  return
}
```

`count` caps the samples (0 is all), `valueRange` keeps `min <= value <= max`,
`onlyTs` keeps just the samples at those timestamps. `del(from, to)` removes a
window and answers how many samples it removed.

## Requests per minute

Raw samples are one per request. The chart wants one number per minute, and the
server can reduce each minute for you. `Downsample` names the reduction
(`by`, an `Aggregation`) and the bucket length:

```bit
import { open, RangeOptions, Downsample, Aggregation, BucketTs, Stamp } from "redis"
import { Minute } from "std/time"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let eu = r.timeseries("inkwell:requests:eu")

  let perMinute = eu.range(
    Stamp.Oldest,
    Stamp.Newest,
    RangeOptions{
      downsample = Option.Some(Downsample{ by = Aggregation.Sum, bucket = Minute }),
    },
  )?
  for s of perMinute {
    println("${s.ts}: ${s.value} requests")
  }

  // A chart with no gaps: minutes without a sample count 0, and each bucket
  // is labelled by its middle.
  let filled = eu.range(
    Stamp.At(1700000000_000),
    Stamp.At(1700000600_000),
    RangeOptions{
      downsample = Option.Some(
        Downsample{
          by = Aggregation.Count,
          bucket = Minute,
          bucketTs = BucketTs.Mid,
          empty = true,
          align = Option.Some(1700000000_000),
        },
      ),
    },
  )?
  println("${len(filled)} minutes")

  // Average and busiest second in one query: `also` adds aggregators after
  // `by`, and each sample answers `value` for `by`, then `also` in order.
  let shape = eu.range(
    Stamp.Oldest,
    Stamp.Newest,
    RangeOptions{
      downsample = Option.Some(
        Downsample{
          by = Aggregation.Avg,
          also = [Aggregation.Max, Aggregation.Min],
          bucket = Minute,
        },
      ),
    },
  )?
  for s of shape {
    println("${s.ts}: avg ${s.value}, max ${s.also[0]}, min ${s.also[1]}")
  }
  r.close()
  return
}
```

`Aggregation` is every aggregator Redis 8.10 has: `Avg`, `Sum`, `Min`,
`Max`, `Range` (max minus min), `Count`, `First`, `Last`, `StdP` and `StdS`
(population and sample standard deviation), `VarP` and `VarS`, `Twa`
(time-weighted average), `CountNan` (how many samples are NaN) and
`CountAll` (every sample, NaN or not). A bucket with no sample is left out
unless `empty = true`; then `Sum`, `Count` and `CountAll` answer 0, `Last` repeats
the previous value, `Twa` interpolates, and the rest answer NaN.
`also` takes any of them, up to the server's own limit, and a single query then
sends `AGGREGATION avg,max,min`: one pass over the samples instead of three.
`also` works on `range`, `revrange`, `mrange` and `mrevrange`; it is the server
that refuses it together with `groupBy`, and a compaction rule takes exactly one
aggregator.
`bucketTs` says which timestamp a bucket carries: `Start` (the default),
`End` (where the next bucket starts) or `Mid`. Buckets begin at `align` (a
timestamp, default 0) plus whole buckets, which is how a day starts at local
midnight rather than at the epoch.

## Every region at once

Three regions mean three series, and the chart wants them together. Labels
are what the series share, and `label(name)` builds a `Filter` on them:
`eq`, `ne`, `oneOf(...)`, `noneOf(...)`, `exists()` for "has this label at all"
and `absent()` for "does not". A query needs at least one equality among its
filters. `rawFilter("region=eu")` is the server's own text, for anything the
builder does not say.

```bit
import {
  open, label, rawFilter, KeyedSample, LabelsOut, MrangeOptions, RangeOptions, Downsample,
  Aggregation, GroupBy, Stamp,
} from "redis"
import { Minute } from "std/time"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let all = r.timeseriesMulti()

  // One write for samples in several series; a refusal does not stop the rest.
  let results = all.madd(
    [
      KeyedSample{ key = "inkwell:requests:eu", ts = Stamp.At(1700000120_000), value = 12.0 },
      KeyedSample{ key = "inkwell:requests:us", ts = Stamp.At(1700000120_000), value = 30.0 },
    ],
  )?
  for res of results {
    match (res.error) {
      Some(msg) => println("refused: ${msg}")
      None => println("stored at ${res.ts}")
    }
  }

  let keys = all.queryIndex([label("app").eq("inkwell"), label("region").noneOf("test")])?
  println("${len(keys)} series")

  // The newest sample of every inkwell series, with its labels.
  let newest = all.mget([label("app").eq("inkwell")], false, LabelsOut.All)?
  for s of newest {
    println("${s.key} ${s.labels["region"]}")
  }

  // Requests per minute per series, then summed over the regions' hosts.
  let perMinute = MrangeOptions{
    range = RangeOptions{
      downsample = Option.Some(Downsample{ by = Aggregation.Sum, bucket = Minute }),
    },
    labels = LabelsOut.Only(["region"]),
  }
  let series = all.mrange(Stamp.Oldest, Stamp.Newest, [rawFilter("app=inkwell")], perMinute)?
  println("${len(series)} series")

  let byRegion = MrangeOptions{
    range = perMinute.range,
    groupBy = Option.Some(GroupBy{ label = "region", reduce = Aggregation.Sum }),
  }
  let groups = all.mrevrange(Stamp.Oldest, Stamp.Newest, [label("app").eq("inkwell")], byRegion)?
  for g of groups {
    println("${g.key}: ${len(g.sources)} series, ${len(g.samples)} minutes")
  }
  r.close()
  return
}
```

`mget` answers a `SeriesLast` per series (`key`, `labels`, `sample`, `None` for
an empty series). `mrange` and `mrevrange` answer a `SeriesRange` per series:
`key`, `labels`, `samples`, and for a `groupBy` result `key` is `label=value`
and `sources` lists the series merged into it. `LabelsOut` picks which labels
come back: `Omit` (the default), `All`, or `Only([...])`. `mrange`'s
`MrangeOptions` also takes `excludeEmpty`, which leaves empty buckets out of a
grouped result.

## A rollup that keeps itself

A week of per-second samples is large, and nobody charts a week at one-second
resolution. A compaction rule makes the server aggregate as samples arrive: the
source series feeds a destination series that holds one sample per bucket.

```bit
import { open, SeriesOptions, Aggregation, RangeOptions, Stamp } from "redis"
import { Minute, Hour } from "std/time"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let raw = r.timeseries("inkwell:requests:eu")
  let rollup = r.timeseries("inkwell:requests:eu:1m")

  // The destination keeps a month; the source keeps a day.
  rollup.create(SeriesOptions{ retention = Option.Some(30 * 24 * Hour) })?
  raw.createRule("inkwell:requests:eu:1m", Aggregation.Sum, Minute)?

  raw.add(Stamp.Auto, 1.0)?

  // A bucket is written when the first sample of the next one arrives, so
  // `get(true)` and `RangeOptions{ latest = true }` add the open bucket.
  match (rollup.get(true)?) {
    Some(s) => println("open bucket: ${s.value} at ${s.ts}")
    None => println("nothing yet")
  }
  let closed = rollup.range(Stamp.Oldest, Stamp.Newest, RangeOptions{ latest = true })?
  println("${len(closed)} minutes so far")

  let info = raw.info()?
  for rule of info.rules {
    println("${rule.dest}: ${rule.by.text()} every ${rule.bucket / Minute} min")
  }

  raw.deleteRule("inkwell:requests:eu:1m")?
  r.close()
  return
}
```

`createRule(dest, by, bucket, align)` needs a destination that exists and has no
other source; `align` (a timestamp) moves where buckets start. `deleteRule`
stops the feed and the destination keeps what it has.

## Looking at a series, and changing it

`info()` is a typed `SeriesInfo`: `totalSamples`, `memoryUsage`, `firstTimestamp`,
`lastTimestamp`, `retention`, `chunkCount`, `chunkSize`, `encoding`,
`duplicatePolicy` (`None` if the series has none), `labels`, `sourceKey` (set on
a rule's destination), `rules`, and the `ignoreMaxTimeDiff` and
`ignoreMaxValDiff` thresholds. `info(true)` is `TS.INFO .. DEBUG`: the same
`SeriesInfo` with `chunks` filled, a `ChunkInfo` per chunk (`startTimestamp`,
`endTimestamp`, `samples`, `size` in bytes and `bytesPerSample`), which is how
you see what the chunk size and encoding cost; without it `chunks` is empty.

`alter(AlterOptions{...})` changes a series in place. It takes `SeriesOptions`
without `encoding`, which is fixed when the series is created (the server
silently ignores it on `TS.ALTER`, so the type does not offer it). A field you
leave `None` stays as it is. A non-empty `labels` replaces every label,
`clearLabels = true` removes them all, and an empty `labels` leaves them be.

```bit
import { open, AlterOptions, DuplicatePolicy } from "redis"
import { Hour } from "std/time"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let eu = r.timeseries("inkwell:requests:eu")

  eu.alter(
    AlterOptions{
      retention = Option.Some(48 * Hour),
      duplicatePolicy = Option.Some(DuplicatePolicy.Max),
      labels = { "region": "eu", "app": "inkwell", "tier": "web" },
    },
  )?

  let info = eu.info()?
  println("${info.totalSamples} samples, ${info.labels["tier"]}")
  r.close()
  return
}
```

## In a pipeline

`p.timeseries(key)` and `tx.timeseries(key)` return a `TimeSeriesBatch`, the
same commands as `TimeSeries` (`create`, `alter`, `add`, `incrBy`, `decrBy`,
`del`, `get`, `range`, `revrange`, `info`, `createRule`, `deleteRule`), each
answering a `Future`. `p.timeseriesMulti()` and `tx.timeseriesMulti()` return a
`TimeSeriesMultiBatch`, the same as `TimeSeriesMulti` (`madd`, `mget`, `mrange`,
`mrevrange`, `queryIndex`).

```bit
import { open, label, KeyedSample, LabelsOut, Stamp } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let p = r.pipeline()
  let eu = p.timeseries("inkwell:requests:eu")
  let a = eu.incrBy(1.0)
  let n = eu.get()

  let all = p.timeseriesMulti()
  let stored = all.madd(
    [KeyedSample{ key = "inkwell:requests:us", ts = Stamp.Auto, value = 3.0 }],
  )
  let newest = all.mget([label("app").eq("inkwell")], false, LabelsOut.All)
  p.exec()?

  println("stored at ${a.get()?}")
  match (n.get()?) {
    Some(s) => println("newest ${s.value}")
    None => println("empty")
  }
  println("${len(stored.get()?)} points, ${len(newest.get()?)} series")
  r.close()
  return
}
```

## Reading inside a transaction

Inkwell caps a region at 1,000 requests: a request is counted only while the
newest total is under the cap, and the decision must be made on the series as
it is when the transaction commits. `tx.read.timeseries(key)` is the same
`TimeSeries` as `r.timeseries(key)`, bound to the transaction's own connection,
so its reads (`get`, `range`, `revrange`) run now and see the keys the
transaction `WATCH`es. `tx.read.timeseriesMulti()` does the same for `mget`,
`mrange`, `mrevrange` and `queryIndex`. The write goes through
`tx.timeseries(key)`, queued for `EXEC`. If another client changes the series
first, the transaction retries and the body runs again with fresh reads.

```bit
import { open, Future, Stamp } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let key = "inkwell:requests:eu"
  let counted = r.transaction<Future<i64>>([key], (tx) => {
    let used = 0.0
    match (tx.read.timeseries(key).get()?) {
      Some(s) => used = s.value
      None => {}
    }
    let delta = 1.0
    if (used >= 1000.0) {
      delta = 0.0
    }
    return tx.timeseries(key).incrBy(delta, Stamp.Auto)
  })?
  println("stored at ${counted.get()?}")
  r.close()
  return
}
```

`tx.read` is for reads only: `tx.read.timeseries(key).add(...)` or
`tx.read.timeseriesMulti().madd(...)` would run immediately, outside the
transaction's `MULTI`/`EXEC`, so they fail with `RedisError.Invalid`. So does
`tx.read.timeseries(key).info()`, for another reason: the server counts a
`TS.INFO` as touching the key, which would make the transaction's own `EXEC`
conflict on every attempt. Queue it with `tx.timeseries(key).info()` and read it
after the transaction.

## Sharp edges

- A server error reaches you as a `RedisError`: `add` into a series whose
  policy is `Block` at a timestamp it has, `create` on an existing key, a
  filter with no equality, a destination that already has a source.
- `madd` is the one exception: it answers an `AddResult` per point, with the
  server's text in `error`, rather than failing the whole call.
- The decoders read RESP3 replies, which this package negotiates by default;
  against a RESP2-only server they fail `RedisError.Unexpected`.
- A filter value must not contain `(`, `)`, `,` or a space; the server rejects
  it. `rawFilter` sends text as it is.

## Where to go next

[Sorted sets](sorted-sets.md) when you need a leaderboard rather than a
history, [Streams](streams.md) when each event carries more than a number,
[Strings and keys](strings-and-keys.md) for `TTL` and `TYPE` on a series key,
and [Commands](commands.md) for the rest of the method surface.
