# Self-host language readiness (#1331)

**Verdict: green light for Stage 1.** The Bit language can express the compiler.

## Evidence

Two independent proofs:

1. **The crypto/TLS/QUIC/HTTP stack** — thousands of lines of Bit already exercise
   every construct a compiler needs: structs, sum-type enums with payloads,
   structural interfaces + dynamic dispatch, generics (functions and types),
   native maps, growable slices (`append`), error handling, closures, `match`,
   UTF-8/byte manipulation, and file I/O. A compiler is not harder than TLS.

2. **A lexer spike** — [`tests/imports/selfhostlex/`](../tests/imports/selfhostlex/)
   ports a representative slice of the real lexer to Bit: the `Kind` sum-type
   enum, a `Token` struct, byte-level scanning over `s[i]`, char-literal
   comparisons (`c >= '0'`), string slicing, a growable `[]Token` via `append`,
   whitespace + `//`-comment skipping, and a `match` dispatch. It compiles and
   runs under the seed `bitc` and produces byte-correct output. **Zero language
   gaps were hit** writing idiomatic lexer code. Gated by the imports harness.

## Language gaps and their status

None of these blocks the port; each has a verified workaround, and the spike did
not need any of them.

| Gap | Status | Port strategy |
|-----|--------|---------------|
| Interface method values `let f = x.m` (#1260) | **FIXED** (e985ad3) | use directly |
| Cross-module methods (#1261) | **works** (verified stale) | use directly |
| Enum `==`/`!=` (was E0053, a Stage-1 deferral) | **FIXED** (37959ff) | compare tags directly; surfaced porting the AST arena |
| Methods on generic structs `function (s: Stack<T>) m()` (#1325) | open (doesn't parse) | free functions: `m(s)` — verified. This is how the Zig compiler is already written. |
| Tuple values / grouped return (#1326) | open (types but doesn't lower) | 2-field structs — verified. |
| Arg-spread `f(...args)` | not surveyed | avoid; enumerate args, or slice-forward |

## Conventions the port follows

- **Directory = module** (Go-style): sibling `.bit` files in one directory share
  a namespace with no import between them; cross-module means a subdirectory or a
  `std/*` import.
- **Free-function containers**: `push(list, x)` / `size(list)` over generic
  structs, not methods on them, until #1325 lands.
- **Structs for pairs**, not tuples, until #1326 lands.

Stage 1 (frontend port: #1333 ast+diagnostics → #1334 lexer → #1335 parser)
may begin.
