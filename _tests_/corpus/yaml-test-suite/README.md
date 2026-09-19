# yaml-test-suite corpus (vendored)

Source: https://github.com/yaml/yaml-test-suite
Upstream commit: `6e6c296ae9c9d2d5c4134b4b64d01b29ac19ff6f` (tag `data-2022-01-17`,
the last tagged release of the `data` branch — the raw `data` branch HEAD is
squashed and force-pushed per upstream's own README and must not be vendored
directly)
Retrieved: 2026-09-18

Upstream ships this corpus two ways: a `main` branch encoding every case as
one YAML file per test ID under `src/`, and a `data` branch exploding each
case into its own directory (one file per artifact) for anyone who wants to
run the suite without upstream's own Perl tooling. This vendors the `data`
form.

## Layout

One directory per 4-character test ID directly under this directory (e.g.
`229Q/`), except 20 IDs that bundle several near-identical sub-cases as
numbered subdirectories instead (e.g. `Y79Y/000/`, `Y79Y/001/`, ...,
`DK95/00/` .. `DK95/08/`). A *leaf* case — the unit `pkg/yaml/corpus.test.bit`
actually runs — is any directory holding `in.yaml` directly, whether that is
a top-level ID or one of its numbered children.

Each leaf case carries a subset of:

- `in.yaml` — the input document (always present).
- `in.json` — the expected value, JSON-encoded (present only when the case's
  value is representable in JSON at all — see "cases with no in.json" below).
- `error` — present (empty file) exactly when `in.yaml` MUST be rejected;
  absent when it must parse.
- `test.event` — upstream's own canonical libyaml-style event stream
  (`+STR`/`+DOC`/`+SEQ`/`+MAP`/`=VAL ...`/`-MAP`/...), the real ground truth
  upstream tests against. Vendored for reference and for the "no in.json"
  cases below; `pkg/yaml/corpus.test.bit` does not parse this format itself
  (building an event-stream comparator is out of this ticket's scope).
- `===` — a one-line human-readable name for the case.

Upstream's own `name/` (a directory of symlinks from human-readable slugs to
test IDs) and `tags/` (symlinks from tag name to test IDs) are navigation
aids over the same 352 top-level directories, not test data, and are not
vendored. `out.yaml` (a re-serialization fixture for round-trip/emit testing)
and `emit.yaml`/`lex.token` (present on a handful of cases) are not vendored
either — nothing in this package's test suite reads them today; re-derive
against the pinned commit above if a future ticket needs them.

## Counts (this pinned commit)

402 leaf cases total: 308 valid (must parse), 94 error (must be rejected).
Of the 308 valid cases, 279 carry `in.json` and are checked against it
structurally; 29 do not (see below) and are checked only for parse success.

## Cases with no `in.json`

29 of the 308 valid cases ship no `in.json` because their value is not
representable in JSON at all: anchors/aliases producing a shared (not just
equal) subtree, non-scalar mapping keys, and other constructs JSON has no
syntax for. This is an upstream corpus property, not a `pkg/yaml` gap — see
each case's own `test.event` for its real expected structure. Re-derive the
list against a newer pin:

```
git clone https://github.com/yaml/yaml-test-suite.git
cd yaml-test-suite
git checkout 6e6c296ae9c9d2d5c4134b4b64d01b29ac19ff6f
for d in $(find . -maxdepth 1 -mindepth 1 -type d ! -name name ! -name tags -printf '%f\n'); do
  if [ -f "$d/in.yaml" ]; then echo "$d";
  else find "$d" -mindepth 1 -maxdepth 1 -type d -printf "$d/%f\n"; fi
done | sort > /tmp/leaves.txt
while read leaf; do
  [ -f "$leaf/error" ] && continue
  [ -f "$leaf/in.json" ] || echo "$leaf"
done < /tmp/leaves.txt
```

`LICENSE` is yaml-test-suite's own (MIT; carried on the `main` branch, not
the `data` branch, so copied in here from `main` at the same retrieval date).

Exclusions this package cannot pass without a change to `pkg/yaml`'s own
`*.bit` files are enumerated, grouped by root cause, in
`pkg/yaml/corpus.test.bit`'s own `corpusExclusionList()`.
