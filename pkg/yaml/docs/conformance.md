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
yaml-test-suite: parse P/N, error P/N, excluded E/N
```

<!-- PLACEHOLDER: the real P/N counts land with #5500, which vendors the
corpus and writes pkg/yaml/corpus.test.bit in a parallel worktree. Do not
invent a number here - replace this block with the actual reported line
the moment that harness exists and has run. -->

## Exclusions

Any corpus case this package deliberately does not attempt is named here
with its reason - an unexplained skip is indistinguishable from a silently
broken case, so nothing is excluded without one. Two exclusions are
already known from this package's own scope decisions, ahead of the corpus
landing:

* Every case exercising a merge key (`<<`) - out of scope by decision, not
  a bug (see [Errors](errors.md)).
* Every case exercising the YAML 1.1 schema's implicit typing
  (`yes`/`no`/`on`/`off`/`y`/`n` as booleans, or an unprefixed leading-zero
  literal as octal) - this package pins the 1.2 core schema on purpose
  (see [Types](types.md)); a case that expects the 1.1 reading is testing a
  schema this package does not implement, not a defect in the one it does.

<!-- PLACEHOLDER: the full excluded-case-ID list, with a reason per entry,
lands with #5500 in pkg/yaml/corpus.test.bit's corpusExclusionList(). Once
that exists, replace this block with the grouped summary the way this
chapter's toml equivalent does, and delete this note. -->

That is the whole of this chapter's job: not "YAML 1.2 compliant" as a
sentence, but a version, a pinned schema, a pinned corpus, a pass count,
and a reason for every case not in it.
