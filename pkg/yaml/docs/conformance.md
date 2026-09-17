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
yaml-test-suite: parse 144/308, error 48/94, excluded 210/402
```

Read plainly: of 402 fixtures on disk, 210 (52%) are excluded. That is
more than half the suite, and stated here without spin - a reader deciding
whether this package fits a given config file needs to know that up
front, not discover it after something they wrote fails to parse.

## What the excluded half actually is

48 of the 210 are not evidence about this parser either way. 29 fixtures
ship no `in.json` at all - their expected value is not representable as
JSON (two anchors sharing one subtree that JSON has no way to alias, a
non-scalar mapping key, and similar), so there is nothing for the harness
to compare against. 19 more are multi-document streams whose upstream
`in.json` concatenates one JSON value per document with no separator,
which a single `jsonParse` call cannot split back apart. Both are limits
of the corpus's own JSON representation, not something this package got
wrong.

The other 162 are real gaps, grouped here by the YAML construct involved -
which is what matters if you are asking "will my file parse", rather than
by which of this package's own source files would need to change to close
one (the file-by-file breakdown lives on epic **#5524**, filed to track
fixing them):

* **Layout and indentation (30).** An anchor or tag alone on its own line
  with the value starting on the next line; a flow collection (`[...]` or
  `{...}`) as an entire top-level document not starting at column 0;
  compact nested block forms like `- - x` or a mapping value's own nested
  mapping continuing at an inline column; a block scalar whose later lines
  violate the indentation its first line established, which should be
  rejected and currently is not.
* **Tabs as whitespace (20).** A tab used as ordinary separator whitespace
  (after `-`, before `:`, on a blank continuation line, before a block
  scalar header) is not accepted in several positions where the spec
  allows it; a tab in a position the spec explicitly forbids as a
  separator is currently accepted rather than rejected.
* **Scalar text: folding, escaping, and boundaries (60).** A bare
  multi-line plain scalar at the top level does not fold into one value
  (this package's own already-documented gap - see [Parsing](parsing.md));
  multi-line quoted-scalar folding (blank-line folding, backslash line
  continuations) is not implemented; the plain-scalar decoder does not
  trim surrounding whitespace before a following `:`, `,`, `]`, `}` or line
  end; a handful of double-quoted backslash-escape spellings are not
  recognized; a few quoted-scalar boundary rules (telling scalar content
  apart from an adjacent document marker) are not enforced; block scalar
  (`|`/`>`) folding and chomp-indicator handling do not match the spec on
  several fixtures.
* **Tags (6).** Verbatim tag syntax `!<...>`; an explicit `!!tag` or
  custom tag directly prefixing a value; the bare non-specific tag `!`,
  which should force implicit typing off and currently does not.
* **Directives, document markers, and trailing content (23).** A
  malformed, duplicated, or misplaced `%YAML`/`%TAG` directive, or a
  directive with no document after it, is accepted rather than rejected;
  `---`/`...` are sometimes read as document markers even without a
  following separator, misreading a scalar that merely starts with those
  characters; trailing content after a complete construct (a closed flow
  collection or quote, a `...` marker, an unspaced `#`) is not rejected
  the way the spec requires.
* **Flow collections (16).** Several flow-context forms - a comment
  inside a flow collection, a multi-line flow key, an explicit `? key :
  value` pair in flow style, `key:value` with no space, an anchor or tag
  on a nested flow entry - are not handled; a bare `-` is accepted as a
  plain scalar inside a flow collection where the spec forbids it.
* **Anchors and aliases (5).** Two are real bugs, not missing features: an
  alias to a genuinely-defined anchor is sometimes reported as undefined
  (a colon absorbed into the anchor's own name, or an anchor bound to an
  empty/null value that never gets registered - see [Anchors](anchors.md)).
  The other three are constructs the spec rejects - an anchor on an alias,
  an anchor immediately before `-` with no separating space, an anchor on
  a document-root key - that this parser currently accepts.
* **Chained colons (2).** `a: b: c: d` is accepted as a chain of implicit
  nested mappings; the spec does not define that shorthand and expects it
  rejected.

30 + 20 + 60 + 6 + 23 + 16 + 5 + 2 = 162, plus the 48 above, is the full
210. Within that 162, 39 fixtures are the more consequential kind: input
the spec says must be REJECTED that this parser currently ACCEPTS instead
(the indentation, tab, directive/trailing-content, flow, anchor, and
chained-colon items above marked "accepted ... rather than rejected" or
"currently accepts"). The remaining fixtures are constructs this parser
does not yet handle at all, which fails loudly rather than silently.

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
