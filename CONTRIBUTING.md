# Contributing to Bit

## Licensing of contributions

Inbound equals outbound: a contribution you submit is licensed under
Apache-2.0, the same license as the project (this is Apache-2.0 section 5, and
it is why there is **no CLA to sign**). You keep the copyright on what you
wrote.

## Who decides

byteink maintains Bit and has the final say on what lands. That is not a
formality - a language whose semantics drift by committee stops being
predictable, and predictability is the product. Expect a real review, and
expect some good patches to be declined on scope rather than quality.

## Settled decisions

These were decided in planning and are **not open for relitigation**. A PR
arguing one of them will be closed with a link to this section:

- **Syntax** is TypeScript-flavored (`let`/`const`, `function`, arrows,
  `interface`, `<>` generics, optional semicolons). "Easy to write" is the
  number one design goal.
- **Semantics** are Go-like: garbage collected, green threads (`spawn`), typed
  channels, structural interfaces.
- **Output** is a single static native binary. No interpreter, no VM, no libc
  dependency.
- **Zero external toolchain.** Bit owns its lexer, parser, checker, SSA IR,
  codegen, object writers and linker. No LLVM, no system assembler, no system
  linker.

`spec/SPEC.md` is the authority on syntax and semantics. A change in behaviour
changes the spec **in the same commit**, not afterwards.

## The bar for a change

1. **A test that fails without your change.** Golden cases live in
   `tests/cases/*.bit` with a sibling `.expected`; line 1 selects the mode
   (`// run`, `// panic`, `// error`, `// fmt`, `// types`, `// lint`).
2. **`scripts/gate.sh` green.** It reads your diff and runs only the steps that
   diff can affect; it falls back to the full suite when the change is
   cross-cutting. Do not skip a red step - a hang counts as a failure, not a
   stall.
3. **Both compilers agree.** The Zig seed is the oracle: the self-hosted
   compiler must produce byte-identical AST/type/IR dumps over the corpus
   (`scripts/selfhost-diff*.sh`). A change to one that diverges from the other
   is incomplete.
4. **Files stay under 800 lines** (target ~500). Split by moving top-level
   blocks into sibling `.bit` files in the same directory - not into
   subdirectories, which would make a new module.

`CLAUDE.md` documents the traps that a green build will not catch - silent line
loss when splitting a file, inlining changes from filename sort order, the
prelude difference between golden cases and directory projects. Read it before a
large refactor.

## No per-file license headers

Apache-2.0 recommends a header in each source file; this project deliberately
does not use them. Stamping thousands of `.bit` and `.zig` files buries every
real diff under boilerplate, and `LICENSE` plus `NOTICE` already state the terms
for the whole tree. Please do not add them.

## The name

The code is Apache-2.0, which grants no trademark rights. Fork and modify the
compiler and it gets a different name - see `TRADEMARK.md`. Forking is fine and
stays fine.

## Reporting a security issue

Do not open a public issue. See `SECURITY.md`.
