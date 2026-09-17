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
toml-test: valid 191/208 (17 excluded), invalid 475/501 (26 excluded)
```

The denominator is every fixture present on disk, so an excluded case stays
visible in it rather than quietly leaving the ratio. Read the line as: of
208 valid fixtures, 17 are excluded and the other 191 all pass; of 501
invalid fixtures, 26 are excluded and the other 475 are all correctly
rejected. The test asserts `passed + failed + excluded == present` for each
half, so the three numbers cannot drift apart, and it fails on any non-zero
`failed` — never on the exclusion count itself.

## Exclusions

Any corpus case this package deliberately does not attempt is named here
with its reason — an unexplained skip is indistinguishable from a silently
broken case, so nothing is excluded without one:

All 43 excluded fixtures are open bugs in this package's parser, not cases
judged out of scope. They fall into five independent groups:

* **Quote-boundary lexing in multi-line strings** — 4 valid fixtures. A
  `"""` or `'''` string carrying one extra quote at *both* its opening and
  its closing delimiter fails to parse.
* **Space-separated date-times** — 4 valid fixtures. RFC 3339 permits a
  space where `T` normally goes; the lexer does not read that form as one
  date-time token.
* **Numeric-lexed keys with no fallback to bare-key text** — 6 valid
  fixtures. A bare key the lexer first reads as a number (signed,
  exponent-shaped, dash-joined, or date-shaped) is rejected rather than
  re-read as key text.
* **Decimal float precision** — 3 valid fixtures. Some decimal float
  literals decode to the wrong nearest `f64`, off by roughly 1e-15
  relative.
* **Documents that should be rejected and are not** — 26 invalid fixtures:
  non-adjacent `[ [` / `] ]` accepted as an array-of-tables header,
  reopening a table a dotted key already populated, a control byte other
  than tab inside a comment, and malformed UTF-8 byte sequences.

Every excluded file is named individually, with its reason, in
`corpusExclusionList()` in `pkg/toml/corpus.test.bit`. That list is what the
harness actually reads; this chapter groups it for a reader. Fixing any of
the five groups means deleting its entries there, which moves the counts
above — so re-derive them from a run rather than quoting this page.

That is the whole of this chapter's job: not "TOML 1.0.0 compliant" as a
sentence, but a version, a pinned corpus, a pass count, and a reason for
every case not in it.
