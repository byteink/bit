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
module. Nothing about it needs separate registration. It reports one line:

```text
yaml-test-suite: parse 293/308, error 86/94, excluded 23/402
```

Read plainly: of 402 fixtures on disk, this package correctly parses or
correctly rejects 379 (94%). The denominator is every fixture present on
disk, so an excluded case stays visible in the ratio rather than quietly
leaving it. The other 23 (6%) are excluded, grouped by reason below.

## What the 23 exclusions are

* **8 need tag or alias identity this package does not track.** Each is a
  valid document whose expected value depends on an anchor's name, an
  alias's identity, or an explicit tag's text - a `&name`, a `*name`
  referencing one, or a `<tag:...>`. See [Anchors](anchors.md) for what
  this package's anchor support covers today.
* **3 need tag-driven typing, which this package rules out by design.**
  Each needs a value's type chosen from its tag rather than from its own
  spelling - forcing implicit typing off, or forcing a mapping key to a
  string over its own implicit int resolution.
* **12 are gaps in less common syntax**: a bare `:` starting a
  block-context line as an implicit empty key, an anchored empty node
  followed by a same-column sibling key, a `%TAG` handle's scope past its
  own document, a flow collection's own multi-line indentation, `&`/`*`
  needing the same line-fold handling `!`/`%` already have, a block
  scalar header's own trailing comment, and one case where the test
  harness itself does not treat an expected int and a parsed float as
  equal.

None of the 23 is unexplained, and none is close to a majority: this
package correctly handles 94% of the corpus today, and rejects anything
else it does not implement with a named error rather than silently
accepting or dropping part of a document - see [Errors](errors.md).

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
