# toml-test corpus (vendored)

Source: https://github.com/toml-lang/toml-test
Upstream commit: `ff49d109861c1ad25af53f687f2aef19ab650600`
Retrieved: 2026-09-17

`pkg/toml` implements TOML 1.0.0 only (see `pkg/toml/encode.bit`'s header),
so this vendors exactly the files upstream's own `tests/files-toml-1.0.0`
list names — not the full `tests/valid`/`tests/invalid` trees, which also
carry `spec-1.1.0/` fixtures for language features this package does not
implement. Re-deriving the file list against a newer upstream commit:

```
git clone https://github.com/toml-lang/toml-test.git
cd toml-test
grep '^valid/'   tests/files-toml-1.0.0 | sed -E 's/\.(toml|json)$//' | sort -u
grep '^invalid/' tests/files-toml-1.0.0 | sed -E 's/\.toml$//'        | sort -u
```

Each name in the first list has both a `.toml` fixture and a `.json` file
giving the expected value in toml-test's own tagged encoding; each name in
the second list has only a `.toml` fixture, which `pkg/toml/corpus.test.bit`
asserts is rejected.

`valid/`: 208 fixture pairs. `invalid/`: 501 fixtures. `LICENSE` is
toml-test's own (MIT).

Exclusions, meaning cases this package cannot pass without a change to
`pkg/toml/*.bit`, are enumerated in `pkg/toml/corpus.test.bit` rather than
here.
