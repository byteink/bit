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

- **Syntax** is TypeScript-flavored (`let`/`const`, `fn`, arrows,
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
   diff can affect. A cross-cutting change (`tools/build/`, `runtime/`, a mix
   of areas, or anything else it cannot confidently scope) makes it refuse
   instead of guessing - exit 3, nothing run, printing what to do next - except
   a `stdlib/**` change paired only with its own mandatory
   `docs/stdlib/<mod>.md` page, which stays scoped rather than forcing full
   (#3055 - `tests/bit/stdlibdocs.bit` makes that page mandatory, so an
   ordinary stdlib-export change always spans both). Run `scripts/gate.sh
   --full` or `./make test` directly (every gate, 18-18.5 min) to actually
   verify a change like that. Do not skip a red step - a hang counts as a
   failure, not a stall.
3. **The differentials agree.** The pinned previous release is the oracle: this
   tree's compiler must produce byte-identical AST/type/IR dumps over the corpus
   (`scripts/selfhost-diff*.sh`). A divergence is a change that is not finished
   -- except when a real behaviour change outruns the pinned stage0: a
   temporary, exact, named STAGE0-PINLAG accept list may be introduced for
   it, and it is deleted at the next stage0 repin, not amended. There is no
   live entry today; the mechanism exists for the next time this happens.
4. **Files stay under 800 lines** (target ~500). Split by moving top-level
   blocks into sibling `.bit` files in the same directory - not into
   subdirectories, which would make a new module.
5. **A benchmark win keeps its baseline.** A change that improves a
   `bench/cases/*` benchmark is not finished until the case's entry in
   `tests/bit/benchgate/baselines.bit` is re-recorded in the same commit -
   see [`docs/development.md`](docs/development.md)'s Testing conventions
   section for the command and why the gate cannot do this for you.

[`docs/development.md`](docs/development.md) documents the traps that a green
build will not catch - silent line loss when splitting a file, inlining changes
from filename sort order, and what the differentials can and cannot prove. Read
it before a large refactor.

## No GitHub Actions

**This project does not use GitHub Actions, and is not planning to.** There is no
`.github/workflows/` directory; it was deleted deliberately, not lost. Do not add
one, and do not "fix" a missing CI badge by wiring a workflow back up.

Verification happens on machines that can actually prove things:

- `scripts/gate.sh` reads your diff and runs only the steps it can affect,
  refusing (exit 3, nothing run) rather than falling back to the full
  `./make test` when the change is cross-cutting - run `scripts/gate.sh --full`
  or `./make test` directly to verify one of those yourself (#2872).
- `scripts/arm64gate.sh` and `scripts/x64gate.sh` run the suite on real
  aarch64-linux and real x86-64 Linux. The x86-64 host is resolved by
  `scripts/x64host.sh` from a machine-local list, never hardcoded - an emulated
  x86-64 pass is not a pass (a red-zone scheduler bug was only settled on real
  hardware).
- `dist/release.sh <version>` cuts a release: builds all three targets,
  smoke-tests each UNPACKED artifact by compiling and running a program on
  hardware that matches it, writes SHA256SUMS, renders notes from conventional
  commits, and creates a DRAFT release. `--dry-run` verifies without publishing.

Why: Actions minutes are billed to the project owner, and every check worth
running needs either the real x86-64 box or a container image that already exists
locally. A hosted runner adds cost and a second, weaker definition of "green".

## No per-file license headers

Apache-2.0 recommends a header in each source file; this project deliberately
does not use them. Stamping thousands of `.bit` files buries every
real diff under boilerplate, and `LICENSE` plus `NOTICE` already state the terms
for the whole tree. Please do not add them.

## The name

The code is Apache-2.0, which grants no trademark rights. Fork and modify the
compiler and it gets a different name - see `TRADEMARK.md`. Forking is fine and
stays fine.

## Reporting a security issue

Do not open a public issue. See `SECURITY.md`.
