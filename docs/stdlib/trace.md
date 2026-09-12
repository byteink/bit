# std/trace

Distributed tracing on the OpenTelemetry wire format: spans, W3C Trace
Context propagation, head-based sampling, and an OTLP/HTTP JSON exporter.
Metrics (`std/metrics`) tell you a rate changed; a trace tells you why one
specific request took 4 seconds, span by span, across every service it
crossed.

A `Tracer` is held explicitly by whatever code creates spans — the same
shape `std/metrics`' `Registry` uses (Bit's module-level `let` cannot hold a
class, SPEC §11.11, so there is no hidden default tracer). What is
**implicit** is the parent/child link between spans on the same task: it is
carried through `std/runtime`'s task-local storage slot (`taskLocalGet`/
`taskLocalSet`, see [runtime](runtime.md) and
`docs/context-propagation.md`), so a function three calls deep never needs a
`Tracer` parameter threaded through its signature just to nest correctly
under whatever span its caller opened.

```bit
import { newTracer } from "std/trace"

fn main() {
  let tr = newTracer("http://localhost:4318/v1/traces", "my-service", 1.0)

  let parent = tr.startSpan("handle-request")
  parent.setAttribute("http.method", "GET")

  let child = tr.startSpan("db.query") // nests under `parent` automatically
  child.end()

  parent.end()
  tr.shutdown() // flushes every queued span before the process exits
}
```

Export never blocks or fails the caller that records a span: it runs on a
background task, batches, and drops with a counted self-report
(`Tracer.droppedSpans()`) when its queue is full — a tracing library that can
take down the service it observes is worse than no tracing at all.

## Spans

### `Attribute`

One span attribute: a `key`/`value` string pair.

### `maxAttributes: int`

The most attributes one span may carry. `Span.setAttribute` past this count
increments `Span.droppedAttributes` instead of growing the span further — the
same cardinality posture as `std/metrics`' label cap.

### `maxAttributeValueLen: int`

The longest an attribute value may be. A longer value is truncated, which
does not count as a drop.

### `SpanStatus`

A span's final outcome: `Unset`, `Ok`, or `Error`. Maps directly to OTLP's
`Status.StatusCode`.

### `Span`

One unit of work inside a trace: a name, a time range measured on the
monotonic clock, a parent/child link, and a bounded attribute set. Construct
only through `Tracer.startSpan`/`Tracer.startSpanFromHeader` — never a bare
`Span{...}` literal, which would skip the sampling decision and the
task-local context push those methods perform.

### `Span.setAttribute(key: string, value: string)`

Attaches `key`/`value` to this span. A no-op once the span has ended.

### `Span.setStatus(status: SpanStatus)`

Sets this span's final status. A no-op once the span has ended. Left unset,
`Span.end()` defaults a span to `SpanStatus.Ok`.

### `Span.end()`

Ends this span: records its duration from the monotonic clock, restores the
task's ambient context to whatever it was before this span started (so a
sibling span started afterward is not misattributed as this span's child),
and hands it to the owning `Tracer` for export if it was sampled. A second
call is a no-op.

## W3C Trace Context

### `TraceParent`

A parsed (or freshly minted) `traceparent` header value: which trace, which
span is the immediate parent, and whether the trace is sampled.

### `parseTraceParent(header: string): Option<TraceParent>`

Parses a `traceparent` header
(https://www.w3.org/TR/trace-context/#traceparent-header). Returns `None` on
*any* deviation from the spec — a version other than `00`, a field count
other than 4, a field of the wrong length, an uppercase or non-hex
character, or an all-zero trace id or parent id (both reserved-invalid).
Never fails and never panics: the header is attacker-controlled, and a
malformed one must start a fresh trace rather than reject the request.

### `formatTraceParent(traceHi: uint, traceLo: uint, spanId: uint, sampled: bool): string`

Formats a `traceparent` header value (version `00`) for an outgoing request.

## Sampling

### `Sampler`

A head-based ratio sampler. Construct with `newSampler`, never directly.

### `Sampler.shouldSample(): bool`

Draws a fresh sampling decision. Only ever called for the root of a new
trace — a span whose parent context already carries a decision (an incoming
valid `traceparent`, or a same-process parent span) inherits it instead, so
every service on a trace agrees.

### `newSampler(ratio: f64): Sampler`

A `Sampler` that samples the fraction `ratio` of fresh traces, clamped to
`[0, 1]`. `0` samples nothing; `1` samples everything, exactly (not merely
with overwhelming probability).

## The Tracer

### `Tracer`

Holds the sampler, the OTLP export queue and its background task, and the
set of currently-open sampled spans (needed so `shutdown` can force-close
and export any left unfinished). Construct with `newTracer`.

### `newTracer(endpoint: string, scopeName: string, ratio: f64): Tracer`

A `Tracer` exporting OTLP/HTTP JSON to `endpoint` (e.g.
`"http://localhost:4318/v1/traces"`) at sampling ratio `ratio`. `scopeName`
names the instrumentation scope OTLP attaches to every span this tracer
exports. Spawns the background exporter task immediately.

### `Tracer.startSpan(name: string): Span`

Starts a span, a child of this task's ambient context if one is set
(`std/runtime`'s task-local slot), or the root of a fresh trace — with a new
sampling decision — otherwise.

### `Tracer.startSpanFromHeader(name: string, traceparent: string): Span`

Starts a span from an incoming `traceparent` header: continues that trace
when the header is valid, or starts a fresh root trace when it is malformed.
Never errors — see `parseTraceParent`.

### `Tracer.currentTraceParent(): Option<string>`

The `traceparent` header value to attach to an outgoing request, built from
this task's ambient context. `None` when no span is open on this task.

### `Tracer.droppedSpans(): i64`

The count of spans dropped because the export queue was full at
`Span.end()` time.

### `Tracer.shutdown()`

Flushes every queued span, force-closes (with `SpanStatus.Error`) and
exports every span still open, then stops the background exporter. Call
once, at process shutdown — an unfinished span is exported, never silently
dropped.

## Low-level pieces

These are exported for `pkg/web`'s tracing middleware and similar callers
that need the raw primitives; most code only needs `Tracer` and `Span`
above.

### `SpanContext`

The current task's ambient trace context: which trace, and which span is
the parent of the next span this task starts.

### `isEmptyContext(c: SpanContext): bool`

True for the zero context — no ambient trace on this task, directly or by
inheritance.

### `currentContext(): SpanContext`

The calling task's ambient span context (`std/runtime`'s task-local slot,
per `docs/context-propagation.md`), or the zero context if none is set.

### `setCurrentContext(c: SpanContext): int`

Sets the calling task's ambient span context. Returns the previous raw
task-local word, to be passed to `restoreContextWord` later.

### `restoreContextWord(prev: int)`

Restores the calling task's task-local word to a value `setCurrentContext`
previously returned.

### `hexEncodeU64(v: uint): string`

`v` as 16 lowercase hex characters, most significant byte first — the wire
form a W3C trace/span id field and an OTLP JSON id string both use.

### `isLowerHex(s: string, n: int): bool`

True iff `s` is exactly `n` lowercase hex characters.

### `hexDecodeU64(s: string): uint!`

Parses exactly 16 lowercase hex characters into a `uint`. Fails on a wrong
length, an uppercase letter, or any non-hex byte.

### `newTraceId(): (uint, uint)`

A fresh 128-bit trace id from the CSPRNG, as `(high, low)` `uint` halves.
Never all-zero (W3C reserves that value).

### `newSpanId(): uint`

A fresh 64-bit span id from the CSPRNG. Never zero (W3C reserves that
value).

### `encodeOtlpBatch(spans: []Span, scopeName: string): string`

The OTLP/HTTP `ExportTraceServiceRequest` JSON body for one batch of spans.
