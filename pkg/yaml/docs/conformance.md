# Conformance

"Parses YAML" is not a claim this package makes without a number behind
it. This chapter is that number, how it is produced, and every case that
is deliberately not counted.

## The pinned version and schema

This package implements **YAML 1.2**, pinned to its **core schema**
(spec.yaml.org, 10.3.2) for implicit typing - see [Types](types.md) for
exactly what that does and does not type. It is a documented subset, not
the full specification: merge keys (`<<`) are YAML 1.1 and out of scope by
decision, and this package's own error for one names that explicitly
rather than mis-parsing it as an ordinary key (see [Errors](errors.md)).
Anything else this parser does not implement fails with a named error
rather than silently accepting or silently dropping part of the document.

## The corpus

Conformance is measured against the upstream
[yaml-test-suite](https://github.com/yaml/yaml-test-suite), vendored at
`_tests_/corpus/yaml-test-suite/` and pinned to one commit (recorded, with
the retrieval date, in that directory's own `README.md`). It is not
hand-written: a hand-rolled set of "YAML I thought of" cases proves
nothing about the spec's actual edge cases, which is the entire reason an
independent, third-party corpus exists.

Each case is a directory holding `in.yaml` plus either `in.json` (the
expected value, for a case that must parse) or an `error` marker file (a
case that must be rejected). The harness compares a parsed document
against `in.json`, not just against "did not error" - a parser that
silently returns an empty mapping for everything would pass an
error-only check and fail this one. The error-marked half is what catches
a parser that accepts too much, and it is the more valuable half.

## How it runs

`pkg/yaml/corpus.test.bit` is a normal package test, picked up by
`./make test-package-yaml` like any other `*.test.bit` file in this
module. Nothing about it needs separate registration. It reports one
line, re-derived here by running
`BIT_REPO="$PWD" ./bit-out/bin/bit test pkg/yaml` on commit `d92ed35d`:

```text
yaml-test-suite: parse 284/308, error 81/94, excluded 37/402
```

Read plainly: of 402 fixtures on disk, 37 (9%) are excluded, and the
other 365 (91%) either parse correctly or are correctly rejected. The
denominator is every fixture present on disk, so an excluded case stays
visible in the ratio rather than quietly leaving it.

## What the 37 exclusions are

Every excluded fixture is named individually, with its own reason, in
`corpusExclusionList()` in `pkg/yaml/corpusexclusions.test.bit`. That
list is what the harness actually reads; this section groups it for a
reader by which file owes the fix, since that is what stays current as
fixtures move between groups. Fixing any of these means deleting its
entry there, which moves the counts above - re-derive them from a run
rather than quoting this page.

* **8 need an owner decision, not a parser fix.** Each is a valid
  document whose expected value depends on an anchor's name, an alias's
  identity, or an explicit tag's text - a `&name`, a `*name` referencing
  one, or a `<tag:...>` (including the bare `!` non-specific tag). `Yaml`
  (`value.bit`) has no field for any of that today: it resolves an
  anchored or aliased node straight through to its plain value and drops
  the decoration, so there is nothing for this suite's own oracle to
  compare against. Reproducing the decoration instead of dropping it
  would need a `value.bit` change; decision **#5548** is still open on
  whether `Yaml` should carry that information at all, and these 8 stay
  excluded until it answers one way or the other - this is not
  engineering work waiting on a queue, it cannot proceed without that
  answer. See [Anchors](anchors.md) for what this package's anchor
  support covers today, independent of how #5548 resolves.
* **29 are open gaps that route through `pkg/yaml/parse.bit`** - 20 of
  them in `parse.bit` alone, 5 jointly with `scan.bit`, 4 jointly with
  `flow.bit`. Examples: an implicit block-mapping key spanning more than
  one physical line; a colon chain (`a: b: c: d`) accepted as nested
  mappings where the spec does not define that shorthand; a malformed
  `%TAG` handle whose scope outlives its own document; content accepted
  after a construct that should already be closed (a flow collection, a
  quoted scalar, a `...` marker). Epic **#5524** tracks closing this
  area; its child list shows most of it already closed, with `#5546`
  (thread a flow collection's own enclosing block indentation into
  `yamlParseFlow`) the one open child naming a specific mechanism today.
  The rest are grouped by construct in
  `pkg/yaml/corpusexclusions.test.bit`'s own `corpusExclusions*`
  functions, each recording the exact fixture IDs and the `parse.bit`
  site a fix needs.

Neither group is a majority, and neither is unexplained: this package
still rejects anything else it does not implement with a named error
rather than silently accepting or dropping part of a document - see
[Errors](errors.md).

## Mapping equality does not depend on key order

Running this corpus surfaced a fact about YAML itself, not about the
harness: two mappings with the same keys and values in a different order
are the same YAML value. The `RR7F` fixture proves upstream's own `in.json`
does not preserve source order either - its YAML writes `a` before the
explicit `? d` / `: 23` pair, and its `in.json` lists `d` before `a`. A
comparison that required the parsed order to match `in.json`'s order would
fail a case that is actually correct, so `pkg/yaml/corpus.test.bit`
compares a mapping by key lookup rather than position, and a sequence
positionally - sequence order IS significant in YAML, mapping order is
not. [Parsing](parsing.md) covers why `YamlEntry` still preserves the
source order it was written in: preserving it is about fidelity to what a
caller wrote, not about two mappings' equality.

That is the whole of this chapter's job: not "YAML 1.2 compliant" as a
sentence, but a version, a pinned schema, a pinned corpus, a pass count,
and a reason for every case not in it.
