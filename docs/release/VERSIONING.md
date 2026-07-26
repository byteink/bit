# Versioning

Bit ships one version number (`MAJOR.MINOR.PATCH`, SemVer 2.0.0) but that
number covers four surfaces that break independently:

1. language syntax/semantics (`spec/SPEC.md`)
2. compiler CLI/flags (`bit build/run/test/fmt/lsp`)
3. stdlib API (`stdlib/`)
4. runtime ABI (`libbitrt.a`, `runtime/ABI.md`)

A release's version bump is the MAX across all four surfaces: if any one
surface has a breaking change, the release is MAJOR (or, pre-1.0, MINOR -
see below); if none break but any surface added something, it's MINOR;
otherwise PATCH. Each surface's own classification follows.

## 1. Language syntax/semantics

Source of truth: `spec/SPEC.md`. Classify by whether an existing, spec-legal
`.bit` program can change meaning or stop compiling.

- **Breaking**: removing or renaming a keyword; changing operator precedence
  or associativity; changing evaluation order (e.g. argument evaluation
  left-to-right → unspecified). Example: changing `&&`/`||` from
  short-circuit to eager evaluation - a program relying on short-circuit to
  guard a nil deref now panics.
- **Additive**: a new expression form or syntax that was previously a parse
  error. Example: adding a `for (init; cond; post)` C-style loop form
  alongside the existing `for..of`/`for..in` - no existing program's parse
  tree changes.

## 2. Compiler CLI/flags

Source of truth: `bit build/run/test/fmt/lsp` and their flags.

- **Breaking**: removing a flag; changing a flag's default behavior.
  Example: `bit build` defaulting `-O` from `debug` to `release` - a script
  that relied on the debug default now ships an unstripped/differently
  instrumented binary without asking.
- **Additive**: a new subcommand or a new flag with a default that preserves
  prior behavior. Example: adding `bit build --target=<triple>` with a
  default of the host triple - existing invocations without `--target`
  behave identically.

## 3. Stdlib API

Source of truth: `stdlib/`.

- **Breaking**: removing or renaming an exported function, type, or
  constant; changing an exported function's signature (params, return type,
  or error-ability). Example: changing `strings.split(s: string, sep:
  string): []string` to return `[]string!` (fallible) - every existing call
  site now fails to typecheck.
- **Additive**: a new exported function, type, or constant that doesn't
  alter any existing export. Example: adding `strings.trimPrefix(s: string,
  prefix: string): string` - no existing export changes.

## 4. Runtime ABI

Source of truth: `runtime/ABI.md`. Classify by whether a binary linked
against the old `libbitrt.a` still runs correctly linked against the new
one, without recompiling.

- **Breaking**: changing an object header layout, a stack map encoding, or
  a `spawn`/`chan` call signature. Example: changing the GC object header
  from an 8-byte type-tag word to a 4-byte tag + 4-byte flags split - every
  binary compiled against the old header layout misreads object metadata
  and corrupts on next GC cycle.
- **Additive**: a new runtime entry point that doesn't touch any existing
  header, stack map, or call signature. Example: adding `bit_rt_chan_len`
  as a new exported symbol - existing binaries neither reference nor are
  affected by it.

## 0.x pre-1.0 semantics

Per SemVer §4: during `0.x`, a MINOR bump may carry breaking changes on any
of the four surfaces above - `0.(y+1).0` is not held to the MAJOR-only
breaking-change rule that applies at `1.0+`. PATCH bumps stay fix-only even
pre-1.0. This ends the moment `#366` (v1.0) ships: version freezes to
`1.0.0` and full SemVer (breaking ⇒ MAJOR) applies from then on.
