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
`BIT_REPO="$PWD" ./bit-out/bin/bit test pkg/yaml` on commit `cab1d7e2`:

```text
yaml-test-suite: parse 293/308, error 86/94, excluded 23/402
```

Read plainly: of 402 fixtures on disk, this package correctly parses or
correctly rejects 379 (94%). The denominator is every fixture present on
disk, so an excluded case stays visible in the ratio rather than quietly
leaving it. The other 23 (6%) are excluded, each named below with the
file that owes it.

## What the 23 exclusions are

Every excluded fixture is named individually, with its own reason, in
`corpusExclusionList()` in `pkg/yaml/corpusexclusions.test.bit`. That
list is what the harness actually reads; this section groups it for a
reader. Fixing any of these means deleting its entry there, which moves
the counts above - re-derive them from a run rather than quoting this
page.

* **8 are pending implementation, not excluded by design.** Each is a
  valid document whose expected value depends on an anchor's name, an
  alias's identity, or an explicit tag's text - a `&name`, a `*name`
  referencing one, or a `<tag:...>`. `Yaml` (`value.bit`) does not carry
  any of that today. Whether it should was an open question; it is
  settled now - YAML 1.2.2 makes a tag part of what a node is (3.2.1.1)
  and an alias the same node, not merely an equal one (3.2.2, 7.1), so
  `Yaml`'s value model will carry anchor identity and tag text. These 8
  close once that change lands, the same way any other open gap here
  does. See [Anchors](anchors.md) for what this package's anchor support
  covers today.
* **3 are permanent: tag-driven typing.** `S4JQ` needs the bare `!` tag
  to force implicit typing off; `74H7` needs an explicit `!!str` to force
  a mapping key to a string over its own implicit int resolution; `LE5A`
  needs the same for an untagged-looking empty scalar. All three need
  this package to choose a value's type from its tag rather than from its
  own spelling, which this package rules out by design. These do not move;
  nothing here is pending.
* **12 are open gaps spread across six files.** `parse.bit` owns four,
  each its own mechanism: a bare `:` starting a block-context line as an
  implicit empty key; an anchored empty node followed by a same-column
  sibling key; a `%TAG` handle's scope not tracked past its own document;
  a flow collection's own multi-line minimum indentation not threaded
  through block context. `flow.bit` owns four: a flow sequence's own
  indentation floor, a flow mapping's key or entries split across lines,
  and `---`/`...` used as flow content. `scan.bit` owns one: `&`/`*` need
  the same fold-sensitive dispatch `!`/`%` already got. `scalar.bit` owns one
  jointly with `parse.bit` and `flow.bit`: a multi-line quoted value's
  own minimum indentation, which none of the three currently threads
  through. `block.bit` owns one: a block scalar header's own trailing
  comment. The last is not a parser gap at all - the harness's own
  float-equality check in `corpus.test.bit`/`value.bit` never coerces an
  expected int to compare against a parsed float. Two of the twelve (the
  sibling-key one and the flow-indentation one) already record one
  attempt tried and reverted after it regressed other, previously-passing
  fixtures - not unattempted, just not yet solved.

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
