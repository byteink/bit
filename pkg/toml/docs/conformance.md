# Conformance

"Parses TOML" is not a claim this package makes without a number behind it.
This chapter is that number, how it is produced, and every case that is
deliberately not counted.

## The pinned version

This package implements **TOML 1.0.0** — the version `pkg/toml/lex.bit` and
`pkg/toml/parse.bit`'s own headers name throughout, and the one every
grammar reference in [Values](values.md) and [Tables](tables.md) cites. TOML
has not released a version past 1.0.0 as of this writing; when it does,
conformance against it is a separate, explicitly versioned claim, not an
automatic upgrade of this one.

## The corpus

Conformance is measured against the upstream
[toml-test](https://github.com/toml-lang/toml-test) suite, vendored at
`_tests_/corpus/toml-test/` and pinned to one commit (recorded, with the
retrieval date, in that directory's own `README.md`). It is not
hand-written: a hand-rolled set of "TOML I thought of" cases proves nothing
about the spec's actual edge cases, which is the entire reason an
independent, third-party corpus exists.

The corpus has two halves:

* `valid/` — files that must parse, each with a sibling `.json` giving the
  expected value in toml-test's own tagged encoding. The harness compares
  the parsed value against that file, not just against "did not error" —
  a parser that silently returns an empty table for everything would pass
  an error-only check and fail this one.
* `invalid/` — files that must be rejected. A parser that accepts one of
  these has the defect this half exists to catch.

## How it runs

`pkg/toml/corpus.test.bit` is a normal package test, picked up by
`./make test-package-toml` like any other `*.test.bit` file in this module
— nothing about it needs separate registration. It reports one line:

```
PLACEHOLDER (filled at merge, see #5487): toml-test: valid P/N, invalid P/N
```

Both `P` (passed) and `N` (total) count individual files across both
halves. A regression in either number fails the test.

## Exclusions

Any corpus case this package deliberately does not attempt is named here
with its reason — an unexplained skip is indistinguishable from a silently
broken case, so nothing is excluded without one:

```
PLACEHOLDER (filled at merge, see #5487): exclusion list not yet available
```

That is the whole of this chapter's job: not "TOML 1.0.0 compliant" as a
sentence, but a version, a pinned corpus, a pass count, and a reason for
every case not in it.
