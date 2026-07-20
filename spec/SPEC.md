# Bit Language Specification

**Version:** 0.1 (draft)
**Status:** Authoritative. Compiler, docs, TextMate grammar, and tests derive from this document. Any change discovered during implementation is made here first.
**Date:** 2026-07-03

Bit is a systems programming language with TypeScript-flavored syntax and Go-like
semantics. It compiles to a single static native binary with no runtime
dependency for the end user. The primary design goal is **easy to write**:
minimal ceremony, strong type inference, one obvious way to do a thing.

This document defines the lexical grammar, syntactic grammar (EBNF), type system,
memory model, concurrency model, module system, and error model. It is written so
that an engineer can hand-derive the complete token set and write a conforming
parser from this document alone.

---

## 1. Notation

Grammar is given in EBNF with the following meta-notation:

| Form            | Meaning                                    |
| --------------- | ------------------------------------------ |
| `=`             | rule definition                            |
| `\|`            | alternation                                |
| `( ... )`       | grouping                                   |
| `[ ... ]`       | optional (zero or one)                     |
| `{ ... }`       | repetition (zero or more)                  |
| `"abc"`         | terminal (literal text)                    |
| `'a'`           | terminal (single character)                |
| `A .. B`        | character range (inclusive)                |
| `UPPERCASE`     | lexical (token) rule                        |
| `lowercase`     | syntactic (grammar) rule                    |
| `(* ... *)`     | comment                                    |

Two grammars are defined:

1. **Lexical grammar** (§4–§6): maps source bytes to a token stream. Whitespace
   and comments are consumed here; semicolons are synthesized here (§7).
2. **Syntactic grammar** (§9 onward): maps the token stream to an AST. It never
   sees raw whitespace, comments, or newlines — only tokens, including the
   synthesized `";"`.

Source text is UTF-8. Identifiers and string contents may contain any Unicode
scalar value; all keywords and operators are ASCII.

---

## 2. Design Pillars (settled — not open for relitigation)

- **Syntax:** TypeScript-flavored — `let`/`const`, `function`, arrow functions,
  `interface`, `<>` generics, optional semicolons.
- **Semantics:** Go-like — tracing garbage collector, green threads (`spawn`),
  typed channels, structural interfaces, value/reference type split.
- **Output:** one static native binary. No interpreter, no VM, no libc
  dependency, no external toolchain.
- **Ease of writing is priority #1.** Where two designs are equally sound, the one
  with less ceremony wins.

---

## 3. Source Model

- A **source file** has extension `.bit` and is UTF-8 encoded.
- A **module** is a directory. Every `.bit` file directly inside that directory
  belongs to the same module and shares one flat declaration namespace (§17).
- The byte order mark `U+FEFF`, if present as the first character, is ignored.
- Line terminators: `LF` (`U+000A`) or `CR LF` (`U+000D U+000A`). A lone `CR` is a
  line terminator too. Internally the lexer normalizes all three to a single
  newline for the semicolon rule (§7).

---

## 4. Lexical Elements

### 4.1 Whitespace and Comments

```
WS       = ' ' | '\t' | '\r' | '\n' | '\v' | '\f' .
COMMENT  = LINE_COMMENT | BLOCK_COMMENT .
LINE_COMMENT  = "//" { any_char_except_newline } .
BLOCK_COMMENT = "/*" { any_char } "*/" .        (* does not nest *)
```

Whitespace separates tokens and is otherwise discarded. A comment behaves as
whitespace, **except** that a comment is treated as containing a newline for the
semicolon rule if and only if it actually spans or ends a line (see §7). Block
comments do not nest; the first `*/` closes.

### 4.2 Tokens

The lexer produces exactly these token kinds:

```
token = IDENT | KEYWORD | literal | operator | ";" .
literal = INT_LIT | FLOAT_LIT | STRING_LIT | RAW_STRING_LIT | RUNE_LIT | BOOL_LIT | NIL_LIT .
```

The lexer is **maximal-munch**: at each position it matches the longest valid
token. `<<=` is one token, not `<<` then `=`; `>=` is one token, not `>` then `=`.

---

## 5. Identifiers, Keywords, and Literals

### 5.1 Identifiers

```
IDENT       = IDENT_START { IDENT_CONT } .
IDENT_START = 'A'..'Z' | 'a'..'z' | '_' | unicode_letter .
IDENT_CONT  = IDENT_START | '0'..'9' | unicode_digit .
```

Identifiers are case-sensitive. `_` alone is the **blank identifier**: it may be
assigned to but never read; it discards a value (e.g. `let (_, ok) = <-c`).

### 5.2 Keywords

Reserved; may not be used as identifiers:

```
as       break     case      catch     chan      const
continue default   defer     else      enum      export
fail     false     for       from      function  if
import   in        interface let       map       match
nil      of        return    select    spawn     struct
switch   true      type      while
```

`assert` is *not* reserved: like `panic` and `len` it is a predeclared builtin
function (§5.3, §16), so it must be an identifier for `assert(cond)` to parse as
a call.

`match` selects on an enum value and binds its payload (§13.8).

### 5.3 Predeclared Identifiers (not keywords)

These are ordinary identifiers bound in the universe scope. They may be shadowed
by user declarations (doing so is discouraged and lints as a warning):

- Types: `i8 i16 i32 i64  u8 u16 u32 u64  f32 f64  int uint  byte rune  bool string  error`
- Constants: none beyond the `true`/`false`/`nil` literals.
- Builtin functions: `len cap append delete close panic assert` (§16).

`int` is an alias for `i64`; `uint` for `u64`; `byte` for `u8`; `rune` for `i32`.
Sizes are fixed on every target for deterministic behavior (this is not Go's
platform-dependent `int`).

### 5.4 Integer Literals

```
INT_LIT  = DEC_LIT | HEX_LIT | OCT_LIT | BIN_LIT .
DEC_LIT  = ('1'..'9') { ['_'] DIGIT } | '0' .
HEX_LIT  = '0' ('x'|'X') HEX_DIGIT { ['_'] HEX_DIGIT } .
OCT_LIT  = '0' ('o'|'O') OCT_DIGIT { ['_'] OCT_DIGIT } .
BIN_LIT  = '0' ('b'|'B') BIN_DIGIT { ['_'] BIN_DIGIT } .
DIGIT     = '0'..'9' .
HEX_DIGIT = '0'..'9' | 'a'..'f' | 'A'..'F' .
OCT_DIGIT = '0'..'7' .
BIN_DIGIT = '0' | '1' .
```

`_` is a digit separator; it may appear between digits only, never leading,
trailing, or doubled. A leading `0` followed by a decimal digit is illegal
(prevents C-style octal confusion; use `0o`).

### 5.5 Float Literals

```
FLOAT_LIT = DEC_FLOAT | HEX_FLOAT .
DEC_FLOAT = DIGITS "." [ DIGITS ] [ EXP ]
          | DIGITS EXP
          | "." DIGITS [ EXP ] .
EXP       = ('e'|'E') [ '+' | '-' ] DIGITS .
DIGITS    = DIGIT { ['_'] DIGIT } .
HEX_FLOAT = '0' ('x'|'X') HEX_DIGITS [ "." [ HEX_DIGITS ] ] ('p'|'P') [ '+' | '-' ] DIGITS .
HEX_DIGITS= HEX_DIGIT { ['_'] HEX_DIGIT } .
```

A float literal must contain a `.`, an exponent, or (for hex) a `p` exponent, so
it is never confused with an integer literal.

### 5.6 Rune Literals

```
RUNE_LIT = "'" ( unicode_char_except_quote_backslash | ESCAPE ) "'" .
ESCAPE   = "\\" ( "n" | "r" | "t" | "\\" | "'" | '"' | "0"
                | "x" HEX_DIGIT HEX_DIGIT
                | "u" "{" HEX_DIGIT { HEX_DIGIT } "}" ) .
```

A rune literal denotes a Unicode scalar value; its type is `rune` (`i32`).

### 5.7 String Literals

Two forms.

**Interpreted string** — double-quoted, single line, supports escapes and
interpolation:

```
STRING_LIT = '"' { STR_ELEM } '"' .
STR_ELEM   = str_char_except_quote_backslash_newline | ESCAPE | INTERP .
INTERP     = "${" expression "}" .
```

Interpolation embeds an expression whose value is converted to `string` (the
value's type must have a `string` conversion; all primitives do, and any type
implementing `interface Show { show(): string }` does — anything else, a slice,
map, channel, function value, or a type without `show`, is a compile error,
`E0073`). `${` and `}` nest
correctly: the lexer tracks brace depth inside an interpolation, and string
literals inside the embedded expression are lexed recursively. To emit a literal
`$`, write `\$`; `${` without a matching `}` on the same logical token is an
error.

**Raw string** — backtick-quoted, may span lines, no escapes, no interpolation:

```
RAW_STRING_LIT = "`" { any_char_except_backtick } "`" .
```

A raw string's bytes are taken verbatim (a `CR LF` inside is normalized to `LF`).

### 5.8 Boolean and Nil Literals

```
BOOL_LIT = "true" | "false" .
NIL_LIT  = "nil" .
```

`nil` is the zero value of every reference type (§13.3).

---

## 6. Operators and Delimiters

All operator/delimiter tokens (matched maximal-munch):

```
+    -    *    /    %
&    |    ^    <<   >>   ~
&&   ||   !
==   !=   <    <=   >    >=
=    +=   -=   *=   /=   %=
&=   |=   ^=   <<=  >>=
++   --
(    )    [    ]    {    }
,    ;    :    .    ...
=>   ?    !    <-
```

Notes on overloaded glyphs, disambiguated by grammar position:

- `!` is unary logical-NOT in expression position and the **fallible marker** when
  it immediately follows a type in type position (`T!`, `T!E`) (§18).
- `?` is the **error-propagation** postfix operator in expression position (§18).
  It has no other meaning; there are no optional types in v0.1.
- `<-` is channel send (as the binary form `ch <- v`, a statement) or channel
  receive (as the unary prefix form `<- ch`, an expression) (§16).
- `&` and `|` and `^` and `~` are bitwise; `&&` and `||` and `!` are logical.
  There is no address-of operator (Bit has no pointers, §13).
- `...` marks a variadic parameter and performs spread in a call.
- Maximal munch takes `>>`, `>>=` and `>=` as single tokens, but a run of `>` also
  closes nested generic argument lists (`chan<map<string, int>>`). Where the
  grammar requires a `>`, the parser **splits** such a token: it takes the leading
  `>` and leaves the remainder (`>>` leaves `>`, `>>=` leaves `>=`, `>=` leaves
  `=`) as the next token. Splitting repeats, so `Opt<Opt<i64>>= v` parses. Nothing
  is split where a `>` is not required, so `a >> b` and `a >= b` are unaffected.

---

## 7. Automatic Semicolons

Bit statements are terminated by `";"`, but source rarely writes them. The lexer
**synthesizes** semicolons using a deterministic rule adapted from Go. This rule
is the sole mechanism resolving statement boundaries; there is no other
newline-sensitivity in the grammar.

**Rule.** When a newline is about to be consumed as whitespace, the lexer inserts
a `";"` token into the stream **if and only if** the last non-whitespace,
non-comment token emitted on the line is one of the **terminator tokens**:

- an `IDENT`;
- any literal (`INT_LIT`, `FLOAT_LIT`, `STRING_LIT`, `RAW_STRING_LIT`, `RUNE_LIT`,
  `BOOL_LIT`, `NIL_LIT`);
- one of the keywords `return`, `break`, `continue`, `fail`;
- one of the closing delimiters `)`, `]`, `}`;
- `>` or `>>` — the closers of a generic argument list (`map<K, V>`,
  `chan<map<K, V>>`; `>>>` and deeper lex down to these). This is the one place
  a token's closer role and its comparison/shift-operator role diverge: a
  trailing `>`/`>>` meant to *continue* a comparison must be parenthesized.
  `>=` and `>>=` are **not** terminators — they never close a generic, so they
  stay pure operators;
- one of the postfix operators `++`, `--`;
- the error-propagation operator `?`.

Additionally:

- A `";"` is inserted before a `}` that closes a block, if not already present
  (so the last statement in a block needs no explicit terminator).
- A `";"` is inserted at end of file if the last token is a terminator.
- Consecutive synthesized/explicit semicolons collapse to one; empty statements
  are allowed and ignored.

Because `>`/`>>` terminate, a declaration or field whose type ends in a generic
close needs no explicit separator: `type Ids = map<string, int>`, a
`headers: map<string, string>` struct field, and an interface method returning
`Opt<T>` all end their line naturally.

**Consequence — line continuation.** A line that must continue onto the next line
must end with a token that is **not** a terminator. In practice: leave a binary
operator, a comma, an opening bracket, `=`, `=>`, `.`, or `<-` at the end of the
line. Examples:

```
// Continues: line ends with '+', not a terminator.
let total = a +
            b + c

// Continues: line ends with '.', not a terminator.
let n = items
          .filter(isActive)
          .length()

// Does NOT continue: 'x' is an IDENT (terminator) -> ';' inserted after it.
let x = 1
let y = 2        // two separate statements, no explicit ';' needed
```

**Pitfall (documented, matches Go).** Because insertion depends only on the last
token of the line, an opening brace must sit on the same line as the construct it
opens:

```
if (cond) {      // correct
  ...
}

if (cond)        // WRONG: ';' inserted after ')', 'if' has empty body,
{                //        then a stray block begins
  ...
}
```

**Wrapping a long condition.** Insertion depends only on the last token of the
line, and **being inside an unclosed `(` does not suppress it**. A wrapped `if`,
`while`, or call argument list therefore obeys this section unchanged — there is
no bracket-depth rule. These two forms are **rejected**:

```
if (a == 1
    && b == 2) { ... }     // ';' inserted after '1' -> "expected ')'"

if (a == 1 && b == 2
   ) { ... }               // ';' inserted after '2' -> "expected ')'"
```

The spellings that work end every broken line on a non-terminator — the operator
trailing, or the `(` itself:

```
if (a == 1 &&
    b == 2) { ... }

if (
  a == 1 && b == 2) { ... }
```

Suppressing insertion inside brackets would require the lexer to track bracket
depth, which is exactly the newline-sensitivity this section rules out — so the
restriction is deliberate, and identical to the one §17.2 documents for a wrapped
`import`. A parse error on a synthesized `";"` carries a hint naming this rule,
since the offending token appears nowhere in the source.

A conforming lexer implements this with one token of state (the previously emitted
token kind) and a per-line "saw newline" flag. No lookahead beyond the current
character is required.

---

## 8. Token Set Summary (derivation target)

An implementer can produce the complete token enumeration directly from §5–§7:

- **Keywords:** the 34 words in §5.2.
- **Literals:** `INT_LIT`, `FLOAT_LIT`, `STRING_LIT`, `RAW_STRING_LIT`,
  `RUNE_LIT`, `BOOL_LIT`, `NIL_LIT`.
- **Identifier:** `IDENT`.
- **Operators/delimiters:** the 46 symbols in §6.
- **Synthetic:** `";"` (only ever produced by §7; source `;` is also accepted).

No other token kinds exist. Predeclared type/function names (§5.3) are lexed as
`IDENT` and resolved during semantic analysis, not lexing.

---

## 9. Syntactic Grammar — Program Structure

```
program      = { ";" } { top_decl ";" } EOF .

top_decl     = import_decl
             | [ "export" ] value_decl
             | [ "export" ] func_decl
             | [ "export" ] struct_decl
             | [ "export" ] interface_decl
             | [ "export" ] enum_decl
             | [ "export" ] type_alias
             | method_decl .            (* export follows the receiver type *)
```

Top-level declarations may appear in any order within a module; forward
references across declarations in the same module are permitted (the checker is
not single-pass over declarations). Statements at top level are not allowed;
executable code lives in function bodies. `import_decl`s, if present, are
conventionally first but may appear anywhere at top level.

---

## 10. Declarations

### 10.1 Value Declarations

```
value_decl = ( "let" | "const" ) binding { "," binding } .
binding    = ( IDENT | tuple_pat ) [ ":" type ] [ "=" expression ] .
tuple_pat  = "(" pat { "," pat } ")" .
pat        = IDENT | "_" | tuple_pat .
```

- `const` bindings must have an initializer and are immutable; their value must be
  a **compile-time constant expression** (§15.4) at top level, or any expression
  inside a function (a function-local `const` is an immutable single-assignment
  binding, not required to be compile-time constant).
- `let` bindings are mutable. A `let` without an initializer is set to the **zero
  value** (§13.4) of its declared type; the type annotation is then required.
- If both `:` type and `=` initializer are present, the initializer must be
  assignable (§14.5) to the type. If only `=` is present, the binding's type is
  **inferred** from the initializer (§15).
- `tuple_pat` destructures a tuple-typed initializer positionally.

### 10.2 Type Aliases

```
type_alias = "type" IDENT [ generic_params ] "=" type .
```

A type alias introduces a new spelling for a type. Aliases are **transparent**:
the alias and its target are identical types (structural identity, §14). There
are no nominal newtypes in v0.1.

### 10.3 Function Declarations

```
func_decl     = [ attr_list ] "function" IDENT [ generic_params ] signature block .
signature     = "(" [ params ] ")" [ ":" result_type ] .
params        = param { "," param } [ "," ] .
param         = [ "..." ] IDENT ":" type .
result_type   = type .            (* may carry the fallible marker, §18 *)
```

- The return type is written after `:`. If omitted, the function returns nothing
  (its result type is the empty tuple `()`, i.e. "void").
- Named `function` declarations **require** type annotations on every parameter
  and (unless void) on the result. This keeps checking modular and diagnostics
  precise. Type inference applies to `let`/`const` initializers and to arrow
  function bodies (§12.8), not to named-function signatures.
- A variadic parameter (`...name: T`) must be last; inside the body it has type
  `[]T`. At a call site the caller passes zero or more `T` arguments, or spreads a
  `[]T` with `...` (§12.4).

#### 10.3.1 Function Attributes

An attribute constrains how a function is compiled. Attributes precede
`function` and attach to function declarations only:

```
attr_list     = attr { attr } .
attr          = "@" IDENT [ "(" string_lit ")" ] .
```

`export` stays outermost: `export @naked function f() {}`. An attribute list may
also sit on its own line above the declaration it modifies; the semicolon
automatic insertion would place there (§7) is not meaningful, because an
attribute list is only ever followed by another attribute or `function`.

Three attributes are recognized; any other name is an error (**E0076**
`unknown_attribute`). Only `@symbol` (§11.9) takes an argument — giving one to
`@naked` or `@nosplit` is **E0079** `symbol_attr_invalid`. All three exist for
the unmanaged subset the runtime is written against — ordinary Bit code should
not need them.

**`@naked`** — the function gets no prologue and no epilogue, and returns
through a bare machine `ret`. It runs on its caller's frame, so it must need no
frame of its own (**E0074** `naked_fn_invalid` otherwise):

- no receiver, no generic parameters, and no parameters;
- the result is void or a scalar (integer, float, or bool) — a reference result
  would need a GC-walkable frame at the return;
- the body contains only `return` statements. There is no prologue, so a local
  or a spilled temporary has nowhere defined to live.

A `@naked` function must return explicitly on every path, *including* a void
one: no implicit `ret` is synthesized for it, so falling off the end would emit
a function containing no `ret` at all (**E0055** `missing_return`).

**`@nosplit`** — the function takes no safepoint and allocates nothing, so the
collector can never run inside it. This is what lets code that *implements* the
allocator and collector call it safely. A `@nosplit` body is restricted to
provably non-allocating forms — arithmetic and comparison, name and literal
reads, field access on a value in hand, `if`/`while`/`for`, assignment,
`break`/`continue`, and `return` — plus calls to other `@nosplit` functions,
to the **atomic builtins** (§11.5), to **`ptrOf`** (§11.5) and **`entryOf`**
(§11.10), and **conversions between numeric prims** (§12.9), all of which lower
to inline machine instructions rather than a call
and so can neither allocate nor reach a safepoint. A numeric conversion covers
the integer and float prims and their aliases (`int`, `uint`, `byte`, `rune`),
and includes `int(p)` — a raw pointer's address (§11.4), the one bridge the
unmanaged subset has from a pointer back to an integer. A declared function
shadows a builtin of the same name here as everywhere else.

`ptrOf` is admitted in **both** its forms, on proof rather than assertion.
On module state (§11.11) it is a link-time constant address materialized
inline — the same shape as `entryOf`. On a slice it is two field reads and an
add, and field access on a value in hand plus arithmetic are already admitted
above in their own right. The atomics would otherwise be unreachable here:
they take a `*T`, and `ptrOf` is the only bridge to one (Bit has no `&`), so
admitting the atomics while refusing `ptrOf` would carve out an operation that
could never be called. Admission covers the address computation only — the
**argument expression is still checked** against this allowlist, exactly as an
`asm` operand is, so `ptrOf` applied to an allocating expression such as a
slice literal remains E0075.

Anything else is **E0075** `nosplit_calls_allocating`, including composite,
slice and map construction, indexing, `append`, `spawn`, closures, channel
operations, string interpolation, every other builtin, and any call through a
value or interface (whose target is not knowable statically). `string(x)` is
**not** admitted by the conversion rule: it copies into a fresh managed object,
so it allocates.

An **`asm` block (§11.6) is permitted**, and is the one construct here admitted
on assertion rather than on proof. Everything else on the allowlist is *proved*
non-allocating by inspection — the atomics because they lower to inline
instructions, a `@nosplit` callee because the same rule was enforced on its
body. An `asm` payload is pre-encoded machine code, opaque to every compiler
pass, so no such proof is possible: nothing stops the bytes from being a call
into the allocator. The compiler accepts it because **the author has already
asserted raw machine semantics by writing `asm` at all** — §11.6 exists solely
for the handful of runtime sites that cannot be written in the language, and an
author hand-encoding instructions is necessarily reasoning about what those
instructions do. Requiring a *second* marker on the block would gate nothing the
compiler can verify: an author willing to hide a call inside the payload would
equally write the marker. It would be ceremony, not enforcement — so the rule is
unconditional, with no per-block opt-in. This matches how Go admits assembly
into `//go:nosplit` and how Rust admits `asm!` under `no_std`.

The assertion is deliberately narrow. **Operand expressions are still checked**:
an `input`'s value is ordinary Bit code the compiler *can* inspect, so it is
subject to the same allowlist as any other expression, and an allocating call
there is still E0075. Only the opaque payload is taken on trust — the trusted
surface is exactly the part that cannot be reasoned about, and no larger.

Without this rule the unmanaged subset would contradict itself: the GC's
register snapshot and the scheduler's context switch are both `@nosplit` by
nature *and* irreducibly `asm`, so the attribute could not be applied to the two
functions it most exists for.

Safety is transitive by induction rather than by whole-program analysis: each
call site requires only that its own callee is `@nosplit`, and the same rule
holds for that callee in turn. Attributes are collected before any body is
checked, so mutual recursion between `@nosplit` functions is accepted in either
declaration order. Green-thread stacks are fixed-size and guarded (§20), so
`@nosplit` removes only the safepoint poll — there is no stack-growth check.

```
@naked function two(): int {
  return 2
}

@nosplit function doubled(x: int): int {
  return x + x
}
```

### 10.4 Method Declarations

Methods attach a named function to a struct or type-alias target via an explicit
receiver placed before the method name:

```
method_decl = [ "export" ] "function" "(" receiver ")" IDENT [ generic_params ] signature block .
receiver    = IDENT ":" type_name .
```

Example:

```
struct Point { x: f64; y: f64 }

function (p: Point) norm(): f64 {
  return sqrt(p.x * p.x + p.y * p.y)
}
```

- The receiver type must be a struct or type-alias declared in the **same
  module**. Methods can only be declared for locally-declared types.
- Because structs are **reference types** (§13.3), a method mutating a receiver
  field mutates the caller's value; no pointer receiver syntax is needed.
- Methods participate in structural interface satisfaction (§14.3).

### 10.5 Struct Declarations

```
struct_decl = "struct" IDENT [ generic_params ] "{" [ field { ( ";" | "," ) field } [ ";" | "," ] ] "}" .
field       = [ "export" ] IDENT ":" type .
```

- A field marked `export` is visible outside the module; otherwise it is
  module-private (§17.3). The struct type itself is exported via the leading
  `export` on the declaration.
- Fields are ordered; that order is the composite-literal positional order and the
  memory layout order (subject to the compiler's alignment padding).
- Structs are reference types with reference semantics on assignment (§13.3).

### 10.6 Interface Declarations

```
interface_decl = "interface" IDENT [ generic_params ] "{" [ method_sig { ( ";" | "," ) method_sig } [ ";" | "," ] ] "}" .
method_sig     = IDENT signature .
enum_decl      = "enum" IDENT [ generic_params ] "{" [ enum_variant { ( ";" | "," ) enum_variant } [ ";" | "," ] ] "}" .
enum_variant   = IDENT [ "(" type { "," type } ")" ] .   (* optional payload; §14.7 *)
```

Interfaces are **structural** (§14.3): a type satisfies an interface if it has all
the interface's methods with matching signatures. There is no `implements`
clause. Interface values are references (§13.3); the zero value is `nil`.

The predeclared `error` interface is:

```
interface error { message(): string }
```

---

## 11. Types

```
type = type_name
     | slice_type
     | array_type
     | map_type
     | tuple_type
     | func_type
     | chan_type
     | generic_inst
     | "(" type ")" .

type_name    = IDENT .                          (* primitive, struct, interface, alias, or type param *)
slice_type   = "[" "]" type .                   (* []T   dynamic, reference *)
array_type   = "[" INT_LIT "]" type .           (* [N]T  fixed, value *)
map_type     = "map" "<" type "," type ">" .    (* map<K,V> reference *)
tuple_type   = "(" type "," type { "," type } ")" .   (* at least 2 elements *)
func_type    = "(" [ type { "," type } ] ")" "=>" result_type .
chan_type    = "chan" "<" type ">" .
generic_inst = IDENT "<" type { "," type } ">" .      (* Foo<T,U> *)
result_type  = type [ "!" [ type ] ] .          (* fallible marker, §18 *)
```

Note: a bare `"(" type ")"` is a parenthesized type; a tuple type needs **two or
more** elements. The **void (unit) result** is normally written as an omitted
result type; the one place it must be spelled is when it carries `!` and so
cannot be omitted, written `()` — chiefly `()!`, "returns nothing or an error"
(§18.2). A bare `()` is thus a valid type only in result position.

There is deliberately **no tuple literal expression**. `(a, b)` in expression
position is a syntax error, not a tuple — `"(" expression ")"` is grouping (§12),
and making it conditionally a constructor would make the meaning of parentheses
depend on their contents. A tuple value is produced by a multi-value `return`
(§13.1), which is the use case tuples exist for; anything that wants a named,
constructible, mutable aggregate wants a struct.

### 11.1 Primitive Types

- Signed integers: `i8 i16 i32 i64` (two's complement, defined wrap on overflow in
  release builds, trap in debug builds — see §13.5).
- Unsigned integers: `u8 u16 u32 u64` (modular arithmetic).
- Floats: `f32 f64` (IEEE-754 binary32 / binary64).
- `bool` (`true` / `false`).
- `string`: immutable, UTF-8 byte sequence; indexing yields a `byte`; `len(s)` is
  the byte length. Strings are reference types but deeply immutable.
- Aliases: `int=i64`, `uint=u64`, `byte=u8`, `rune=i32`.

### 11.2 Composite Types

- **Slice** `[]T`: growable view over a backing array; reference type; `len`/`cap`;
  built with `[]T(n)` (length `n`, zeroed) or `[]T(n, m)` (length `n`, cap `m`), or
  a slice literal (§12.3). Slicing: `s[lo:hi]`.
- **Array** `[N]T`: fixed length `N` (a compile-time constant), value type, copied
  on assignment. Built with an array literal or zero-valued via `let a: [N]T`.
- **Map** `map<K,V>`: hash map; reference type; `K` must be a comparable type
  (§14.6). Built with `map<K,V>()` or a map literal. Absent keys read as the zero
  value of `V`; use the two-result index form to test presence (§12.6).
- **Tuple** `(T1, T2, ...)`: fixed heterogeneous group; value type; used for
  grouped returns and destructuring. Accessed by destructuring or `.0`, `.1`, …
- **Function** `(P...) => R`: first-class function value; reference type.
- **Channel** `chan<T>`: typed synchronization primitive (§16); reference type.

### 11.3 Generics

```
generic_params = "<" generic_param { "," generic_param } ">" .
generic_param  = IDENT [ ":" constraint ] .
constraint     = type_name { "&" type_name } .   (* one or more interface bounds *)
```

- Type parameters may constrain to one or more interfaces with `&`. An unbounded
  parameter (`<T>`) admits any type and permits only operations valid for all
  types (assignment, passing, equality only if used at a comparable-constrained
  site).
- Generics are resolved by **monomorphization** at compile time (§13.6); there is
  no runtime type erasure and no boxing of type parameters.
- Call-site type arguments are usually inferred (§15.3); explicit arguments use
  `f<T>(...)` and are disambiguated per §12.7.

Example:

```
interface Ord { less(other: Self): bool }   (* Self = the implementing type *)

function max<T: Ord>(a: T, b: T): T {
  if (a.less(b)) { return b }
  return a
}
```

`Self` is a predeclared type name inside an interface body denoting the concrete
implementing type; it may appear in method signatures only.

### 11.4 Raw Pointers (unmanaged subset)

- **Raw pointer** `*T`: a single machine word holding the address of a `T`. It is
  a **reference type** (nilable; its zero value is the null pointer `nil`), but
  unlike every other reference type it is **not traced by the garbage collector** —
  the collector never follows a `*T`, and a `*T`-typed struct field or slice
  element is omitted from the object's pointer map. This is what makes it *unsafe*:
  the pointee's lifetime is not tracked, and dereferencing a dangling or
  fabricated pointer is undefined behavior.
- `*T` exists for the **unmanaged subset** — the low-level code (the runtime,
  including the garbage collector's own metadata) that must manage memory it
  deliberately keeps outside the managed heap, so the collector must not walk it.
  It is not needed by, and should be avoided in, ordinary code: slices, maps, and
  structs are the safe, traced references (§11.2).
- Operations:
  - **Dereference** `*p` — loads the pointee (`T`). `*p = x` stores `x` through it.
    The operand must be a `*T`.
  - **Pointer arithmetic** `p + n` / `p - n` (`n` an integer) — advances the
    address by `n * sizeOf(T)` bytes and yields a `*T`.
  - **Address as integer** `int(p)` (or any integer conversion) — the raw address
    as an integer; the inverse of pointer arithmetic off the null pointer.
  - **Comparison** `p == q` / `p == nil` — pointer identity by address.

```
let p: *i64 = nil          // the null pointer
let q = p + 8              // address 8 * sizeOf(i64)
let addr: int = int(q)     // 64 — the raw address
```

### 11.5 Atomics (unmanaged subset)

Predeclared builtin functions provide lock-free atomic operations on an integer
memory location named by a raw pointer `*T` (§11.4). Like `*T`, they are for the
**unmanaged subset** (the runtime's own run queue, channels, and refcounts) and
should be avoided in ordinary code, where channels are the safe concurrency
primitive. `T` must be an integer prim (`i8`…`u64`).

- `atomicLoad(p: *T): T` — atomically read `*p`.
- `atomicStore(p: *T, v: T)` — atomically write `v` to `*p`.
- `atomicCmpxchg(p: *T, old: T, new: T): bool` — if `*p == old`, store `new` and
  return `true`; otherwise leave `*p` unchanged and return `false` (Go-style).
- `atomicAdd` / `atomicSub` / `atomicAnd` / `atomicOr` / `atomicXchg(p: *T, v: T): T`
  — atomically apply the operation to `*p`, returning the **previous** value
  (fetch-and-op; `atomicXchg` just swaps `v` in).

All operations use the **strongest ordering** (sequential consistency); a weaker
ordering is not yet exposed. Every operation lowers to inline machine
instructions — a `lock`-prefixed op on x86-64, an `LDAXR`/`STLXR` retry loop on
ARM64 — never an out-of-line call, so a spin/CAS loop stays call-free.

A `*T` for these ops comes from `ptrOf(s: []T): *T` — the address of slice `s`'s
first element — the one bridge from traced memory to a raw pointer (Bit has no
`&`). The slice keeps its backing storage alive, so the pointer stays valid for
as long as the slice is reachable.

```
let cell = []i64(1)                        // one shared word, kept alive here
let p = ptrOf(cell)
atomicStore(p, 0)
let old = atomicAdd(p, 1)                   // old == 0, *p == 1
if (atomicCmpxchg(p, 1, 42)) {              // *p was 1 -> now 42, true
  // swapped
}
```

### 11.6 Inline Assembly (unmanaged subset)

`asm` embeds machine instructions directly in a function. Like `*T` and the
atomics it exists only for the **unmanaged subset** — the handful of runtime
sites (context switch, the GC's register snapshot, `_start`, a compiler barrier)
that cannot be written in the language at all — and has no place in ordinary
code.

`asm` is an **expression**: it yields its `result` operand's value, or `()` when
it declares none (so a bare `asm { … }` is a valid statement).

```
asm [volatile] {
  x64     { <byte>, ... }              // pre-encoded machine code
  arm64   { <word>, ... }
  result  arm64 <reg> x64 <reg> : T    // at most one
  input   arm64 <reg> x64 <reg> = expr // zero or more
  clobber x64   { <reg>, ... }
  clobber arm64 { <reg>, ... }
}
```

Directives may appear in any order, each at most once except `input`.
`x64`/`arm64`/`input`/`result`/`clobber`/`volatile` are **contextual** keywords —
ordinary identifiers everywhere else. Only `asm` itself is reserved.

- **Both targets live on the one block.** Bit has no arch-conditional
  compilation, and the checker and lowering run once for every target, so a
  single `asm` carries an `x64` sub-block *and* an `arm64` sub-block. Each
  backend reads only its own arch's, so the same source compiles for either.
- **The payload is pre-encoded bytes (x64) / 32-bit instruction words (arm64),
  not mnemonic text.** The backends are instruction-selection only — there is no
  text assembler anywhere in the compiler — so emission is a verbatim
  passthrough. The author hand-encodes each instruction (verified against a
  disassembler) exactly once.
- **Operands pin literal physical registers.** `input` moves the value of `expr`
  into the named register before the block; `result` reads the named register
  out after it. There are no flexible "any register" classes.
- **Register names** are the architecture's own: `rax`…`r15` (x64) and
  `x0`…`x30`, `sp`, `xzr` (arm64). `memory` is accepted in a `clobber` list as a
  compiler barrier; it names no register.
- Every register named by `input`, `result`, or `clobber` is **excluded from the
  register allocator for the whole enclosing function**, so no value can be
  parked in a register the block overwrites.
- `volatile` is accepted and documented for parity with the source being ported;
  an `asm` block is never dropped, hoisted, or deduplicated regardless.
- An `input` value must be a register-width integer or a raw pointer (§11.4).
- An `asm` block is permitted inside a `@nosplit` function (§10.3.1). Because
  the payload is opaque, that admission rests on the author's assertion — the
  block must genuinely neither allocate nor reach a safepoint. Its `input`
  expressions remain subject to the `@nosplit` allowlist.

```
// x0 = x1 + x2 on arm64; rax = rax + rcx on x64.
function addAsm(a: int, b: int): int {
  return asm {
    arm64 { 0x8B020020 }              // add x0, x1, x2
    x64   { 0x48, 0x01, 0xC8 }        // add rax, rcx
    result arm64 x0 x64 rax : int
    input  arm64 x1 x64 rax = a
    input  arm64 x2 x64 rcx = b
  }
}
```

There are **no block-local labels** — the payload is pre-encoded machine code, so
there is no assembler holding a symbol table to resolve a symbolic branch target
against. That is a gap in *notation*, not in capability. A backend emits a
block's words (arm64) or bytes (x64) contiguously and unmodified, in source
order, and no later pass reorders, relaxes, or pads them, so a branch **within
one block** is expressible today: the author hand-computes its PC-relative
displacement, exactly as every other instruction in the payload is hand-encoded.
A context switch's internal loop needs nothing beyond this.

```
// Multiply by repeated addition — the back edge is a displacement, not a label.
// arm64: add x2, x2, x1 ; subs x0, x0, #1 ; b.ne -8   (back two words)
arm64 { 0x8B010042, 0xF1000400, 0x54FFFFC1 }
// x64:   add rdx, rcx   ; dec rax         ; jne -8    (back eight bytes)
x64   { 0x48, 0x01, 0xCA, 0x48, 0xFF, 0xC8, 0x75, 0xF8 }
```

The displacement is the author's responsibility and is **not checked**: nothing
verifies that it lands on an instruction boundary, or that it stays inside the
block at all. This is the same bargain the rest of `asm` already strikes — the
payload is opaque to every compiler pass (§10.3.1), and an author hand-encoding
instructions is necessarily reasoning about what they do.

Branching *out* of a block is the part that genuinely does not work: a target in
another block, in surrounding Bit code, or in another function would need a
relocation the compiler does not emit, and there is no supported way to spell
one. Reaching other code from `asm` is what a `call` to a pinned symbol (§11.9)
or an `extern function` (§11.7) is for.

### 11.7 External Functions (unmanaged subset)

`extern function` binds a Bit name to an external symbol resolved at **link
time** from a dynamic library. Like `*T`, the atomics and `asm`, it exists for
the **unmanaged subset** the runtime is written against — on macOS the runtime
must reach the kernel through libSystem, because Apple does not guarantee stable
syscall numbers and reserves the right to renumber them.

```
extern_fn_decl = "extern" "function" IDENT signature .
```

- `extern` is a **contextual** keyword — an ordinary identifier everywhere else.
  It is unambiguous here because an identifier can never begin a declaration.
- There is **no body**, no receiver, no generic parameters, and no variadic
  parameter (a variadic C function needs per-call ABI classification this path
  does not implement). **E0077** `extern_fn_invalid` otherwise.
- The declaration may be `export`ed like any other, and calls to it type-check
  against the declared signature exactly like a normal function's.

```
extern function getpid(): i32
extern function getentropy(buf: *u8, n: i64): i32

function main() {
  print("${getpid()}\n")
}
```

**The ABI is C.** These are plain `callconv(.c)` calls, emitted through the same
path and the same argument marshalling as the runtime primitives in
`runtime/ABI.md` — a Bit direct call and a runtime call already share one
emitter, and an extern call is that same emitter given a raw symbol name.

**Only C-representable types cross the boundary.** Every parameter and the
result must be a scalar (integer, float, or bool) or a raw pointer (§11.4); the
result may also be void. Every other Bit type is either GC-managed (`string`,
slices, maps, interfaces, closures) or has a layout C does not share, and
nothing on this path marshals — the value would be handed over raw and misread.
**E0077** otherwise. `ptrOf` (§11.5) is the bridge from a slice to a `*T`.

**The symbol is never module-qualified.** An ordinary function is emitted as
`m<id>$name` so two modules cannot collide; an extern's name *is* the symbol the
linker must find, so it is used verbatim (with the platform's own decoration —
Mach-O's leading underscore, so `getpid` links against `_getpid`).

**macOS binds against a dylib; Linux binds against the linked archive.** The
Mach-O output is a normal dynamically-linked image and its linker already binds
any still-undefined global as a libSystem import, so an extern needs no new
linker machinery and any symbol name is admissible there. The ELF output is
deliberately the opposite: a fully static binary with no interpreter, no dynamic
symbol table and no libc. There is no load-time resolution at all — but that is
not the same as *no resolution*. The static link already merges the runtime
archive (`libbitrt.a`), and a symbol **defined inside that archive** resolves
exactly like any other cross-module reference, through the same global symbol
table and the same dead-strip reachability the runtime's own calls use.

The rule is therefore archive membership, not the platform:

- Targeting `aarch64-macos`: always accepted.
- Targeting a Linux triple, symbol **defined in the linked `libbitrt.a`**:
  accepted. The reference is resolved statically at link time.
- Targeting a Linux triple, symbol **absent** from that archive: rejected with
  **E0078** `extern_unsupported_target`, naming the symbol. A fully static ELF
  has nothing to resolve it against, so this would otherwise fail deep inside
  the linker.
- Targeting a Linux triple with **no archive in the link** (`bit build-obj`,
  which emits a bare relocatable and reads no archive): rejected. Membership is
  undecidable there, and an undecided case must fall back to rejection — an
  accept-on-unknown would convert a compile error into a link error or a silent
  crash.

The decision is made where the target and the AST are both in hand, after
checking and before lowering; the archive path is a pure function of the target,
so the predicate is decidable exactly where the diagnostic already fired.

Bit has no arch-conditional compilation, so a program needing a *libc* symbol on
both platforms still uses `extern function` for Darwin and a raw syscall for
Linux, not one source form. A **runtime** symbol (`bit_rt_*`) is the case this
rule admits: it is present in the archive on every target, so one source form
does work for it.

### 11.8 Raw Syscalls (unmanaged subset)

`syscall` traps directly into the operating system kernel. Like `*T`, the
atomics, and `asm`, it belongs to the **unmanaged subset**: it exists so the
runtime can reach the kernel without a C library, and has no place in ordinary
code — the stdlib's `fs`, `net`, and `time` modules are the supported surface.

```
syscall(nr)                       // -> i64
syscall(nr, a0)
...
syscall(nr, a0, a1, a2, a3, a4, a5)
```

- **Linux only.** Compiling a `syscall` for a Darwin target is an error: Apple
  publishes no stable syscall numbers and reserves the right to renumber them,
  so there is nothing to encode against. Darwin's supported path is a call into
  libSystem. The diagnostic is raised at object-emission time, since the
  checker and lowering run once for every target.
- **Variable arity**: the syscall number plus zero to six arguments, so 1 to 7
  arguments in total. Every argument and the result are `i64`.
- The result is the kernel's **raw return value**, including a negative errno
  on failure. `syscall` never panics, never sets an error, and never
  interprets what it returns — the caller does.
- **Syscall numbers are per-architecture** and are not part of this
  specification. Bit has no arch-conditional compilation, so a program that
  targets both architectures selects the number itself at run time (see
  `hostTarget()`).
- A `syscall` is never dropped, hoisted, or deduplicated, even when its result
  is unused: its effect belongs to the kernel, outside the compiler's view.
- Pointer arguments are ordinary integers here. A raw pointer (§11.4) reaches
  one via `i64(p)`; `ptrOf` (§11.5) is the bridge from a slice to such a
  pointer. Note that a slice stores one **8-byte word per element**, so
  `ptrOf` on a `[]u8` does not address packed bytes.

The compiler emits the kernel trap inline — never a call to a runtime symbol —
using each platform's kernel ABI, which is **not** its C ABI:

| Target        | Number | Arguments        | Result | Trap             |
| ------------- | ------ | ---------------- | ------ | ---------------- |
| x86-64 Linux  | `rax`  | `rdi rsi rdx r10 r8 r9` | `rax` | `syscall` (`0F 05`) |
| AArch64 Linux | `x8`   | `x0`–`x5`        | `x0`   | `svc #0` (`0xD4000001`) |

On x86-64 the fourth argument travels in `r10`, not the C ABI's `rcx`, because
the `syscall` instruction overwrites `rcx` with the return address (and `r11`
with the saved flags). Every register named above is excluded from the register
allocator for the whole enclosing function, exactly as an `asm` block's operands
are (§11.6).

```
// write(1, buf, 6) on either Linux architecture.
function sysWrite(): int {
  if (hostTarget() == 0) { return 1 }  // x86_64-linux
  return 64                            // aarch64-linux
}

function writeLine(buf: []int, n: int): int {
  return syscall(sysWrite(), 1, i64(ptrOf(buf)), n)
}
```

### 11.9 Pinned Symbols (unmanaged subset)

The `@symbol("name")` attribute (§10.3.1) pins the exact link-level symbol a
function definition emits, and constrains its signature to the C ABI. It is the
mirror of `extern function` (§11.7): that one **consumes** an external symbol,
this one **produces** one.

```
export @symbol("bit_rt_alloc")
function alloc(size: i64): *byte { ... }
```

Ordinarily a function's emitted symbol carries its module's `m<id>$` prefix
(§17), where `<id>` is an ordinal assigned by whichever build imports the module.
That is fine for Bit-to-Bit calls, which resolve through the declaration, but it
means an exported function has **no stable external name**. Code generation emits
calls to the runtime by fixed name (`bit_rt_alloc`, `bit_rt_safepoint`, … — see
`runtime/ABI.md`), so a runtime written in Bit could not define the symbols the
compiler calls. A pinned symbol bypasses module qualification entirely and is
emitted verbatim.

Rules — **E0079** `symbol_attr_invalid` unless all hold:

- the argument is a single string literal naming a **C identifier**: a letter or
  `_` followed by letters, digits or `_`. Nothing else is portable across the
  object formats, and `$` is how this compiler spells its own mangling;
- it applies to a **free function** — not a method, not a type or a constant,
  and not a generic function (each instantiation would need its own name);
- the signature must cross the C ABI: every parameter and the result is a scalar
  or a raw pointer (`*T`), and the function is not variadic. A fallible result
  (`T!E`) returns through the thread-local error slot rather than the C return
  register, so it is rejected too. This is the same restriction §11.7 applies in
  the consuming direction, and for the same reason — one shared marshaller,
  which marshals nothing else.

Two declarations pinning the same name is **E0080** `duplicate_symbol`: both
would define it, and the link would either fail or silently pick one.

`@symbol` and `export` are independent and may be combined. `export` controls
Bit-level visibility — whether another Bit module may import the name — while
`@symbol` controls the link-level name; neither implies the other. The symbol is
emitted with global binding into the object file either way, spelled per the
platform's convention for a C symbol (Mach-O prefixes a leading underscore, so
`@symbol("bit_rt_alloc")` appears as `_bit_rt_alloc`). As with any function, an
executable's linker still dead-strips a definition nothing references; what is
pinned is the name, not its retention.

### 11.10 Function Entry Address (unmanaged subset)

`entryOf(f): *byte` is the address of `f`'s first instruction. Like `*T`, the
atomics, `asm`, and `syscall` it belongs to the **unmanaged subset**: it is the
one construct that names machine code as data, and ordinary code has no use for
it — a function is called, not addressed. It is `ptrOf`'s sibling (§11.5): that
one bridges traced memory to a raw pointer, this one bridges a function
declaration to one.

It exists for the scheduler. Starting a green thread means building a task's
saved register context and setting its `pc`, and there is otherwise no expression
in the language that yields a code address. Converting a function *value* is not
a substitute: a function value is a `(code, env)` pair on the heap, so `int(f)`
yields that object's address — a different number on every run.

```
// The shape a context switch needs: the entry written into a saved pc slot.
function initialContext(entry: *byte): []i64 {
  let ctx = []i64(4)
  ctx[0] = int(entry)
  return ctx
}

let ctx = initialContext(entryOf(taskBody))
```

The result is a raw pointer (§11.4), so it is not traced by the collector and
`int(...)` converts it to an integer by the ordinary rule. It addresses code, not
data: dereferencing it is meaningless, and writing through it is undefined.

**The operand must reference a named function declaration directly** — anything
else is **E0081** `entry_of_invalid`, reported by the checker rather than left to
fail during lowering. This is a restriction on what an entry address can *mean*,
not on what the compiler could emit:

- a **closure** is a `(code, env)` pair, and the captured environment is exactly
  what makes calling it meaningful. Its code address alone would run against
  somebody else's environment, or none, so there is no honest value to return.
  This covers an arrow function, a binding holding a function value, a parameter
  of function type, and a function-typed field;
- a **generic** function has no single body until it is instantiated, so no one
  address exists to name;
- an **`extern` function**'s body lives in another image; only a call to it is
  expressible, and only where §11.7 permits one;
- a **method** is not nameable as a bare identifier, so it never reaches here.

A local binding shadows a declaration as it does everywhere else, so `entryOf`
applied to the shadowing name is rejected on the same footing as any other value.

`entryOf` is permitted inside a `@nosplit` function (§10.3.1), on the same
footing as the atomic builtins and for the same reason: it lowers to a single
inline address materialization against a link-time constant, so it can neither
allocate nor reach a safepoint. Unlike an `asm` block, which is admitted on the
author's assertion, this one is admitted on proof. The rule matters because the
caller it exists for — a scheduler's `initialContext` — is nosplit by nature.

**Absolute stability depends on the output format, and the difference between two
entries never does.** Bit's ELF output is a fully static, non-relocated image, so
an address there is identical on every run. The Mach-O output is position
independent, so the loader slides the whole image and absolute addresses differ
between runs. In both, `entryOf(f)` is invariant *within* a run and
`int(entryOf(g)) - int(entryOf(f))` is invariant *across* runs.

### 11.11 Module-Level State (unmanaged subset)

A `let` at module scope declares **mutable state that outlives every call**:

```
let liveBytes: i64 = 0        // one cell for the whole program
let freeHeads: [37]*u8        // zero-valued; an inline array of raw pointers
let lockWord: i32 = 0         // addressable: ptrOf(lockWord) is a *i32
```

This is the storage the runtime is built out of — the collector's heap counters,
the allocator's free-list heads, the scheduler's run queue. `const` at module
scope is unrelated: a `const` is a compile-time value inlined at each use and has
no address, whereas a `let` is a real cell with a stable address.

**The collector never scans module state.** That is the central decision, and
these are the rules that make it sound:

1. **The type must be untraced**: an integer, float, or bool; a raw pointer `*T`
   (§11.4); or a fixed array `[N]U` of those. Anything the collector would trace
   — `string`, `[]T`, `map`, `chan`, a struct, an interface, a payload-carrying
   enum, a function value — is a **compile error**, not a silent hazard.
2. **The initializer must be a compile-time constant** (§15.4), or absent, in
   which case the cell is zero-valued (§13.4). An array-typed `let` takes no
   initializer at all.
3. **The binding is a single name.** Destructuring has no meaning for a
   statically laid out cell.

Every module-level cell is **16-byte aligned**, whatever its type. This is a
guarantee, not an artifact of layout: rule 1 admits a fixed array `[N]U` so the
runtime can carve its own memory out of one, and a green-thread stack is exactly
that use. Both supported ABIs require a 16-byte-aligned stack pointer — AAPCS64
faults on a misaligned `sp`, SysV x86-64 requires it at call boundaries — so
aligning to the element type instead would place an array at `addr % 16 == 8`
for some declaration orders and not others, making the fault depend on the order
of unrelated declarations. That is the silent, order-dependent hazard rule 1
exists to rule out, so the alignment is uniform rather than natural. The cost is
at most 8 bytes of padding per cell.

Rule 1 is what makes not scanning correct rather than merely cheap. The obvious
alternative — trace module state as a GC root — is *actively wrong* for the first
real consumers: the allocator's free-list heads point into unmanaged `mmap` span
memory that carries no object header, and the scheduler's run queue holds
runtime-owned `Task` pointers. Walking either as an object reference would decode
arbitrary bytes as a header. The collector's own bookkeeping cannot be traced by
the collector either, without circularity. So module state is defined as the
place references *cannot* go, and the checker enforces it.

Loosening rule 1 later is a pure relaxation: any program valid today stays valid
if a traced module-state form is ever added. It would have to be **explicitly**
marked as traced, never traced by default, for the reason above.

Module state is **private to the module that declares it**, even when `export`ed:
a `const` has a cross-module form because it is a value inlined at each use, but
a `let` is one cell, and another module cannot name it. Referencing one from
outside its module is a compile error. Expose it through exported functions
instead — which is how the runtime is structured anyway, and works today:

```
// counters.bit
let hits: i64 = 0
export function recordHit(): i64 {
  hits = hits + 1
  return hits
}
```

Because the initial value is a constant, each cell ships as a static byte image
in the object file. There is **no run-time initialization pass**, and therefore no
initialization-order question: every cell holds its declared value before `main`
begins, whatever order the declarations appear in, across modules. Initializers
cannot call functions or run arbitrary code — that is what makes this true.

Reaching module state is **pure address arithmetic** — no load of a descriptor, no
allocation, no safepoint — so it is legal inside a `@nosplit` body (§10.3.1), and
`ptrOf` (§11.5) yields its address for the atomic builtins. Those two properties
are what the free lists and the run queue actually require.

#### Storage classes

Module state is a *storage class*, not a single feature. Three are specified:

| Form                    | Copies                | Writable | Status                       |
| ----------------------- | --------------------- | -------- | ---------------------------- |
| `let x: T = c`          | one per **process**   | yes      | implemented, every target    |
| `@threadlocal let x: T` | one per **OS thread** | yes      | implemented on ELF; Mach-O is rejected at emission |
| read-only static data   | one per **process**   | **no**   | mechanism implemented, every target; no surface syntax yet |

Rules 1–3 apply identically to all three — the type and initializer restrictions
come from "the collector does not scan this cell", which is equally true
per-thread. They differ in how many cells exist, whether the loader maps them
writable, and how the address is materialized: process-wide state is a plain data
symbol, per-thread state needs a thread-local section and TLS relocations, and
read-only state is a plain symbol in a non-writable section.

**The read-only class** places one image for the program in `.rodata` (ELF) or
`__TEXT,__const` (Mach-O), so the loader maps it without write permission. It
exists for **static tables** — SHA round constants, AES S-boxes, SHA-3 round
constants — which otherwise have to be spelled as a private function returning a
literal, costing one GC allocation on every call, i.e. per hash block.

Not scanning it is sound for a second, simpler reason than rules 1–3: a read-only
image cannot be mutated, so it can never come to hold a pointer to a moved
object. This is the one class that may carry **link-time relocations**, and only
one kind: a 64-bit absolute pointer, which is what a `[]T` slice header's `buf`
word needs, since the payload's address is known only to the linker. A `[N]T`
fixed array needs none at all — its value *is* its own base address.

The address is materialized exactly as for the process-wide class, by pure
address arithmetic, so a read-only read is call-free and legal inside a
`@nosplit` body. `ptrOf` on one yields a pointer into non-writable memory;
storing through it faults. The class is currently reachable only from the
compiler's own IR — there is no surface syntax yet, and adding one is a separate
change.

`@threadlocal` attaches to a module-level `let` only. It is the sole attribute a
`let` accepts, it takes no argument, and it is rejected on a local `let`, on a
`const`, and on anything else.

The access sequence is where the two classes stop being symmetric, and the
difference is normative. Process-wide state is reached by pure address
arithmetic. Per-thread state is reached by adding a link-time-known offset to the
thread pointer:

| target        | sequence                                              | call-free |
| ------------- | ----------------------------------------------------- | --------- |
| aarch64 ELF   | `mrs TPIDR_EL0` + a `tprel_hi12`/`tprel_lo12_nc` `ADD` pair | yes  |
| x86-64 ELF    | `mov fs:[0]` + `ADD` of a `TPOFF32` displacement      | yes       |
| Mach-O        | load a TLV descriptor and **call its resolver thunk** | **no**    |

So a `@threadlocal` read is *not* guaranteed call-free on every target: the
`@nosplit` guarantee above holds unconditionally for the process-wide class and,
on ELF only, for the per-thread class. Mach-O per-thread state is therefore
**rejected at emission** (`UnsupportedTlsStorage`) rather than silently placed in
`__data`, which would be one process-wide cell wearing a per-thread name. That
refusal is a deliberate seam, not an oversight — implementing it requires
modelling the thunk call as clobbering caller-saved registers in both register
allocators, which is a correctness change to codegen rather than an addition to
it.

The *linker* half is already done on every target — `PT_TLS` and local-exec
relocations on both ELF arches, TLV descriptors on Mach-O — and the runtime
boots a thread pointer for the main thread.

A per-thread cell obeys rules 1–3 above, so it likewise ships as a static byte
image: the image is the *template* every thread's copy is initialized from, which
is why the initializer must still be a compile-time constant. A thread created
outside the runtime's own spawn path gets a correct copy only if its thread
pointer was installed; a raw `clone(2)` without `CLONE_SETTLS` inherits its
parent's, and therefore shares — not copies — its parent's cells.

---

## 12. Expressions

Precedence, highest to lowest. All binary operators are **left-associative**.

| Level | Operators                                   | Kind             |
| ----- | ------------------------------------------- | ---------------- |
| 8     | `f(...)` `a[i]` `a[lo:hi]` `a.b` `x?`        | postfix / primary |
| 7     | `!x` `-x` `+x` `~x` `<-c`                    | unary prefix     |
| 6     | `*` `/` `%` `<<` `>>` `&`                    | multiplicative   |
| 5     | `+` `-` `\|` `^`                             | additive         |
| 4     | `==` `!=` `<` `<=` `>` `>=`                  | comparison       |
| 3     | `&&`                                         | logical and      |
| 2     | `\|\|`                                       | logical or       |
| 1     | `=>` (arrow function)                        | lowest           |

Assignment is a **statement**, not an expression (§13.2), so `=` never appears
inside an expression. There is no ternary `?:` operator in v0.1; use an `if`
statement. `&&` and `||` short-circuit.

```
expression   = arrow_fn | binary .
binary       = unary { binop unary } .          (* shaped by the precedence table *)
binop        = "*" | "/" | "%" | "<<" | ">>" | "&"
             | "+" | "-" | "|" | "^"
             | "==" | "!=" | "<" | "<=" | ">" | ">="
             | "&&" | "||" .
unary        = ( "!" | "-" | "+" | "~" | "<-" ) unary | postfix .
postfix      = primary { call | index | slice | member | "?" } .
call         = "[" type_args "]"  ... (* see §12.7 for the generic-call form *)
             | "(" [ arguments ] ")" .
index        = "[" expression "]" .
slice        = "[" [ expression ] ":" [ expression ] "]" .
member       = "." ( IDENT | INT_LIT ) .        (* INT_LIT selects a tuple element *)
arguments    = arg { "," arg } [ "," ] .
arg          = [ "..." ] expression .           (* '...' spreads a slice, §12.4 *)

primary      = literal
             | IDENT
             | "(" expression ")"
             | composite_lit
             | "[" arguments "]"                 (* slice literal, element list *)
             | block_expr .                      (* only where an expression block is allowed; see §12.8 *)
```

### 12.1 Literals and Identifiers

An `IDENT` in expression position resolves to a value binding, function, or a type
used as a constructor/converter (§12.9). Literals are as in §5.

### 12.2 Struct Composite Literals

```
composite_lit = type_name [ "<" type_args ">" ] "{" [ field_inits ] "}"
              | slice_type   "{" [ arguments ] "}"
              | array_type   "{" [ arguments ] "}"
              | map_type     "{" [ map_entries ] "}" .
field_inits   = field_init { "," field_init } [ "," ] .
field_init    = IDENT ":" expression .           (* keyed; order-independent *)
map_entries   = map_entry { "," map_entry } [ "," ] .
map_entry     = expression ":" expression .
type_args     = type { "," type } .
```

A struct literal is **always** prefixed by its type name: `Point{ x: 1.0, y: 2.0 }`.
This is the rule that removes the block-versus-object-literal ambiguity — a bare
`{` in statement position is **always** a block (§13.1), never a struct or map
literal. Struct literals are keyed; any field omitted from the literal takes its
zero value (§13.4). Fields not visible to the current module (unexported fields of
a foreign struct) may not appear.

### 12.3 Slice, Array, and Map Literals

```
[]int{1, 2, 3}                 // slice literal
[3]int{1, 2, 3}                // array literal (length must match)
map<string, int>{ "a": 1, "b": 2 }
[1, 2, 3]                      // bare element list: slice literal whose element
                               //   type is inferred from context (§15)
```

A bare `[ ... ]` element list is a slice literal; its element type comes from the
expected type or the join of element types (§15.2). Map and typed slice/array
literals carry an explicit type prefix and are therefore unambiguous even in
statement position.

A bare element list is a slice literal **in every context, including where an
array type is expected**. It is therefore ill-typed against an `[N]T`
annotation, parameter, or result — `let a: [2]f32 = [4.5, 4.5]` is an error
(E0041, `expected '[2]f32', found '[]f64'`), not an array literal. An array
value is constructed only by the type-prefixed form `[N]T{...}`, whose element
count must equal `N` (E0050), or left zero-valued by `let a: [N]T` (§11.2).
There is no implicit slice-to-array conversion; §22 keeps arrays-as-values
otherwise deferred for v0.1.

This was previously left implicit, and the two compilers disagreed: the seed
rejected the bare form while the self-hosted checker accepted it and
miscompiled, storing an `f64` into an `f32`-wide element so that `a[0] == 4.5`
was false, and admitting a length mismatch that read uninitialized memory. The
rule is stated here so the two cannot drift again (see
tests/cases/check_array_literal.bit and run_array_value.bit).

**Diagnostic order inside a composite literal is normative.** A literal is
checked slot by slot in source order; the literal's own whole-literal rule (the
E0050 length mismatch of `[N]T{...}`) is reported first, and for each slot the
slot's *expression* is checked to completion — reporting everything nested
inside it — before that slot's assignability to the declared slot type. A map
entry interleaves at slot granularity: key expression, key assignability, value
expression, value assignability. So in

```
Outer{ x: Inner{ a: "s" } }     // Outer.x is an int
```

the `a: "s"` mismatch is reported before the `x:` one, even though `x:` starts
earlier in the source. Order is user-facing, and the two compilers must render
byte-identical output, so it is fixed here rather than left to whichever
traversal each implementation happens to use (#1489;
tests/cases/check_composite_order.bit).

### 12.4 Calls, Variadics, Spread

```
f(a, b)
sum(1, 2, 3)          // variadic: individual args
sum(...xs)            // spread a []int into the variadic slot
```

Exactly one `...spread` argument is permitted and only into a variadic parameter,
as the final argument. Mixing individual args and a spread in the same call is a
compile error.

### 12.5 Member Access

`a.b` selects a struct field or a method value. `t.0`, `t.1`, … select tuple
elements by index (the index is an `INT_LIT`, checked against the tuple arity).
Method values are closures bound to their receiver.

**Tuple elements are read-only.** `t.0` may be read but never assigned, so `t.0 =
x` (and `t.0++`, `t.0 += x`) is a compile error. A tuple is a fixed group of
values produced whole — by a multi-value `return` (§13.1) — and read whole or by
element; to vary a member, build a new tuple or use a struct, which is what
structs are for. This restriction is what lets tuples be a value type (§13.3)
while being represented as a shared box.

### 12.6 Index and Slice

- `s[i]` indexes a slice/array (`i` must be an integer; out-of-range **panics**,
  §18.4) or a string (yielding `byte`).
- `m[k]` indexes a map; a missing key yields the zero value of the value type. The
  two-result form `let (v, ok) = m[k]` also reports presence (`ok: bool`). The
  two-result form is only valid as the sole right-hand side of a value declaration
  or assignment.
- `s[lo:hi]` slices; `lo` defaults to `0`, `hi` to `len(s)`. Violation panics.
  On a `[]T` the result is a view sharing the backing buffer (`0 <= lo <= hi <=
  cap(s)`). On a `string` the result is a fresh string copying bytes `[lo, hi)`
  (`0 <= lo <= hi <= len(s)`) — string headers hold interior pointers, so a
  shared view could not keep the backing alive. Re-slicing a `[N]T` array is not
  yet supported (§21).

### 12.7 Generic Call Disambiguation (`<`)

When the parser sees `IDENT <` in expression position it must decide between a
generic instantiation `f<T>(...)` and a comparison `a < b`. The rule is
deterministic and requires bounded speculative parsing:

1. Speculatively parse a **type-argument list**: `<` `type` { `,` `type` } `>`.
2. Commit to a generic call **only if** the closing `>` is immediately followed by
   `(` (a call) or `{` (a generic composite literal). Otherwise, discard the
   speculative parse and treat `<` as the comparison operator.

Because a type-argument list is a closed, finite grammar, the speculation is
bounded and cannot span statements. Chained comparisons without parentheses
(`a < b < c`) are rejected by the grammar anyway (comparison is non-associative in
practice — the checker rejects a `bool` operand to `<`), so no real ambiguity
remains. When in doubt, write `(a) < (b)` or provide explicit parentheses.

### 12.8 Arrow Functions

```
arrow_fn   = arrow_params "=>" ( expression | block ) .
arrow_params = IDENT
             | "(" [ arrow_p { "," arrow_p } [ "," ] ] ")" .
arrow_p    = IDENT [ ":" type ] .
```

- A single un-parenthesized identifier is allowed only when its type is inferable
  from context: `xs.map(x => x * 2)`.
- Parameter types and the return type are inferred from the expected function type
  (§15.3) when omitted, or written explicitly.
- A `=> expression` body returns that expression; a `=> block` body uses `return`.
- With no expected function type, the result is inferred from the body: the
  expression body's own type, or the first `return`'s expression type in a block
  body, in each case with an untyped constant taken at its default type (§15.4).
  A block body with no value-returning `return` has result `()`.
- To disambiguate from a parenthesized expression, the parser commits to an arrow
  function when a `)` is immediately followed by `=>`. This is one token of
  lookahead after the matching `)`.

### 12.9 Type Conversions and Constructors

A type used in call position converts or constructs:

```
i32(x)            // numeric conversion (explicit; no implicit narrowing)
f64(n)            // int -> float
string(b)         // []byte -> string (copy)
[]byte(s)         // string -> []byte (copy)
[]int(n)          // allocate a length-n zeroed slice
[]int(n, m)       // length n, capacity m
map<string,int>() // empty map
chan<int>()       // unbuffered channel
chan<int>(16)     // buffered channel, capacity 16
int(tag)          // C-like enum -> its integer tag
```

`string(b)` and `[]byte(s)` copy bytes verbatim: a `[]byte` is the raw byte
view of a string and round-trips through it. The rune-oriented conversions
(`string(rune)`, `string([]rune)`, `[]rune(s)`) require UTF-8 encode/decode and
are deferred until rune iteration lands (§21).

Numeric conversions are always explicit. There are **no** implicit numeric
conversions between distinct numeric types (including `i32`→`i64`); this is a
deliberate safety choice. Untyped constant literals are the only exception and
adapt to context (§15.4). Integer conversions sign- or zero-extend / truncate to
the destination width; float→int truncates toward zero. *(v1 limit: converting a
`u64` whose top bit is set to or from a float uses the signed path, so such a
value is out of range — fixed when a full unsigned float path lands.)*

---

## 13. Statements, Memory, and Types Semantics

### 13.1 Statements

```
statement = value_decl
          | assign_stmt
          | expr_stmt
          | inc_dec_stmt
          | if_stmt
          | for_stmt
          | while_stmt
          | switch_stmt
          | match_stmt
          | select_stmt
          | return_stmt
          | fail_stmt
          | break_stmt
          | continue_stmt
          | spawn_stmt
          | defer_stmt
          | send_stmt
          | block
          | ";" .                                (* empty statement *)

block      = "{" { statement ";" } "}" .
```

A statement list is a sequence of statements each terminated by `";"` (usually
synthesized, §7). A bare `{ ... }` is a **block** and introduces a new lexical
scope. Because struct/map literals are type-prefixed (§12.2), a leading `{` is
never a literal.

```
assign_stmt   = lhs { "," lhs } assign_op expression { "," expression } .
lhs           = IDENT | index | member | tuple_pat .
assign_op     = "=" | "+=" | "-=" | "*=" | "/=" | "%="
              | "&=" | "|=" | "^=" | "<<=" | ">>=" .
inc_dec_stmt  = lhs ( "++" | "--" ) .
expr_stmt     = expression .                     (* call, receive, ? chain, or catch *)
send_stmt     = expression "<-" expression .     (* ch <- v *)
return_stmt   = "return" [ expression { "," expression } ] .
fail_stmt     = "fail" expression .
break_stmt    = "break" .
continue_stmt = "continue" .
spawn_stmt    = "spawn" call_expression .        (* argument must be a call *)
defer_stmt    = "defer" call_expression .
```

- Multi-assignment `a, b = b, a` evaluates all right-hand sides before assigning
  (simultaneous). Compound assignment operators require a single lhs and rhs.
- An `expr_stmt` is legal only if the expression has a side effect that can stand
  alone: a function call, a channel receive, an error-propagation chain (`?`), or
  a `catch` (deliberate error handling — its ok value is intentionally discarded,
  or is `void`; §18.3). A bare `a + b` statement is a compile error (guards
  against mistakes).
- `return` with multiple expressions constructs a tuple result matching the tuple
  result type. The tuple is built as a single value and returned as one (see
  `runtime/ABI.md` §1.1); the arity and element types must match the declared
  result type exactly.
- A `member` lhs must select a **struct field**. A tuple element (`t.0`) is
  read-only (§12.5) and is not a valid assignment target.
- A `tuple_pat` lhs destructures a tuple-typed right-hand side positionally, or
  reads one of the two-result forms (`m[k]`, `<- c`, `iface.(T)`, §12.6/§16/§14.7).
  Its arity must match: a two-result form binds exactly two names, and a
  tuple-typed rhs binds exactly the tuple's arity. `_` discards an element.

### 13.2 Assignment vs Declaration

`let`/`const` **declare**; `=` **assigns** to an existing binding or lvalue. There
is no `:=`. Shadowing in an inner scope requires a new `let`/`const`.

### 13.3 Value vs Reference Types

Bit has **no pointers** and no address-of operator. The value/reference split
determines copy semantics and is fixed:

| Category   | Types                                                        | Assignment / arg passing |
| ---------- | ----------------------------------------------------------- | ------------------------ |
| Value      | all numeric, `bool`, `[N]T` arrays, tuples                   | deep copy of the value   |
| Reference  | `string`, `[]T` slices, `map<K,V>`, `struct`, `interface`, `chan<T>`, function values | copy of the reference (shared underlying data) |

`string` is a reference type but is deeply immutable, so sharing is unobservable.
The same argument covers tuples from the other side: a tuple is a value type, but
because its elements are read-only (§12.5) an implementation may share one heap
box between copies without that being observable. The reference implementation
does exactly that — see `runtime/ABI.md` §1.1, which also fixes the multi-value
return ABI: `return a, b` builds one boxed tuple and returns a single handle.
Structs are reference types (like TypeScript objects): assigning a struct copies
the handle, and mutations through either handle are visible to both. To obtain an
independent copy, define and call a `clone()` method. The zero value of every
reference type is `nil`.

Rationale: making structs references removes the need for pointers, `&`/`*`, and
value-vs-pointer receiver rules, which is a large ceremony saving (priority #1)
while keeping the GC model simple.

### 13.4 Zero Values

Every declared binding without an initializer is deterministically zero-valued:

- numeric → `0`; `bool` → `false`; `string` → `""`.
- `[N]T` array → all elements zero-valued; tuple → each element zero-valued.
- `struct` → a live instance with each field zero-valued (structs are references,
  so `let p: Point` yields a usable zeroed `Point`, not `nil`).
- slice, map, `chan`, function, interface → `nil`. Reading a `nil` map yields zero
  values; **writing** a `nil` map, sending on a `nil` channel, or calling a `nil`
  function **panics** (§18.4). Use the constructor forms (§12.9) to allocate.

### 13.5 Arithmetic and Overflow

- Unsigned integer arithmetic is modular (wraps).
- Signed integer overflow **traps (panics) in debug builds** and **wraps with
  two's-complement semantics in release builds**. The build mode is a compiler
  flag; the default `bit build` is release, `bit build --debug` is debug. This
  makes overflow deterministic and testable rather than undefined.
- Integer division or remainder by zero **panics**.
- Float arithmetic follows IEEE-754; division by zero yields ±∞ or NaN (no panic).
- Shifts: the shift count is taken modulo the operand bit width.

### 13.6 Memory Model (GC)

- Bit is **garbage collected** by a tracing collector linked into every binary.
  There is no manual `free`, no use-after-free, no double-free. Allocation is
  implicit (composite literals, constructors, `append` growth, closures, boxing of
  interface values).
- The collector is precise (uses stack maps and safepoints defined in
  `runtime/ABI.md`). Object headers and the exact collector algorithm are an
  implementation detail of the runtime, not part of this language spec; only the
  observable guarantees below are normative.
- **Observable guarantees:** every reachable object stays live; unreachable objects
  are eventually reclaimed; finalizers are **not** provided in v0.1 (deterministic
  cleanup uses `defer`, §18.5). Object identity is stable for the object's
  lifetime.
- Generic instantiations are **monomorphized**: each distinct set of type
  arguments produces a specialized copy at compile time. There is no runtime type
  erasure. This bounds code size statically and keeps dispatch direct.

### 13.7 Concurrency Memory Model (happens-before)

For programs using channels correctly, Bit provides a sequentially-consistent view
via these happens-before edges (mirrors Go's model):

1. A `spawn f(...)` statement **happens-before** the spawned function begins.
2. A send on a channel **happens-before** the corresponding receive completes.
3. The close of a channel **happens-before** a receive that observes the channel is
   closed.
4. On an **unbuffered** channel, a receive **happens-before** the send completes.
5. The `k`-th receive on a channel with capacity `C` happens-before the
   `(k+C)`-th send completes.

Program order holds within a single green thread. Access to shared **mutable**
memory (e.g. a struct or slice) from multiple threads **without** an ordering edge
established through channels is a **data race** and its result is unspecified.
v0.1 provides channels as the only synchronization primitive; higher-level
synchronization (mutex, atomics) is deferred to the standard library in a later
release. The recommended discipline: *do not communicate by sharing memory; share
memory by communicating.*

### 13.8 Match

`match` dispatches on an enum value (§14.7):

```
match_stmt  = "match" "(" expression ")" "{" { match_arm [ "," | ";" ] } "}" .
match_arm   = variant_pat "=>" ( statement | expression ) .
variant_pat = IDENT [ "(" IDENT { "," IDENT } ")" ] .   (* name + payload binders *)
```

The subject expression must be an enum type. Each arm names one of the enum's
variants (bare, unqualified — the subject's type disambiguates) and runs its
body when the value is that variant. A payload variant's arm binds its payload:
`Circle(r) => …` binds `r` to the `f64` inside; the binder count must match the
variant's payload arity. A `match` is:

- **Exhaustive** — every variant of the enum must have an arm; a missing variant
  is a compile error (`E0071`). This is `match`'s central guarantee: adding a
  variant to an enum turns every `match` that forgot it into a compile error.
- **Non-overlapping** — a variant may appear in at most one arm (a duplicate is
  a compile error).

Arms do not fall through. `break`/`continue` inside an arm target the enclosing
loop, not the `match`.

`match` is both a **statement** and an **expression**. In statement position each
arm body is a statement (a block or a single statement). In expression position
(`let x = match (…) { … }`, a `return`, an operand, a string interpolation) each
arm body is an *expression* and the whole `match` yields their common type: the
expected type when one is imposed by the context, otherwise the first arm's type,
to which the remaining arms must be assignable (a mismatch is `E0041`, like a
`return`). Arms separate on `,` or a newline.

---

## 14. Type System

### 14.1 Type Identity

Types are compared **structurally**, not by name. Two types are identical if:

- they are the same primitive; or
- both are `[]T` / `[N]T` / `map<K,V>` / `chan<T>` / tuple / function types with
  identical components (arrays also require equal `N`); or
- both are struct types with the same ordered field list (same names, same field
  types, same export visibility); or
- both are interface types with the same method set (names + signatures); or
- one is a type alias whose transparent target is identical to the other (aliases
  are transparent, §10.2).

Because identity is structural, a `type` alias never creates a distinct type.

### 14.2 Assignability

A value of type `S` is assignable to a location of type `T` if:

- `S` and `T` are identical; or
- `T` is an interface and `S` satisfies `T` (§14.3); or
- `S` is an untyped constant (§15.4) representable in `T`; or
- `S` is `nil` and `T` is a reference type.

No implicit numeric conversions and no implicit interface-to-interface widening
beyond structural satisfaction. Everything else needs an explicit conversion.

### 14.3 Structural Interface Satisfaction

A type `S` **satisfies** interface `I` if, for every method `m` in `I`, `S` has a
method named `m` whose signature is identical to `I`'s (with `Self` bound to `S`).
Method sets:

- The method set of a struct/alias type is the set of methods declared with a
  receiver of that type in its home module.
- Interfaces may not declare fields; only method signatures.
- `S` must be a **struct** type (or another interface, or `nil`). An interface
  value *is* the receiver's object pointer — there is no boxed scalar — so only a
  type that is already a reference (§13.3) can sit behind one. Storing anything
  else would leave a non-pointer in a word the collector traces as a root and a
  type assertion (§14.4) reads as an object header. This is a rule about the
  value's representation, not its method set: a method may be declared on a type
  alias (§10.4), and an alias to a scalar is transparently that scalar (§14.1),
  so a scalar can carry methods yet still not be storable in an interface.
- `nil` is assignable to *any* interface, empty or not, and satisfaction is never
  consulted for it: `nil` has no method set, so testing it against `I`'s methods
  would reject it out of every non-empty interface and leave such a location's
  zero value (§13.4) unspellable.
- Satisfaction is checked at assignment/passing sites; there is no declaration of
  intent. Assigning a satisfying `S` into an `I`-typed location carries `S`'s
  dynamic type and method table with the pointer (its `TypeInfo`).

### 14.4 Type Assertions

An interface value may be narrowed:

```
let (c, ok) = iface.(Circle)     // ok=false instead of panicking if mismatch
let c2      = iface.(Circle)     // panics on mismatch
```

Grammar:

```
type_assert = postfix "." "(" type ")" .
```

The two-result form is valid only as the sole right-hand side of a declaration or
assignment (like the map/channel two-result forms).

- The target must be a **struct** type. Only structs carry methods (§10.4), so
  only a struct can be the dynamic type behind an interface value.
- A target that cannot satisfy the interface is a **compile-time error**: the
  assertion could never succeed, so it is rejected rather than left to report
  `false` forever.
- On a mismatch the two-result form yields `(nil, false)` — `nil`, not the
  un-narrowed receiver. The value is typed as the target, so returning the
  receiver would let a caller that ignores `ok` read one concrete type as
  another. This is the same reason `ok` guards a reference-element channel
  receive (§16.2).

### 14.5 Constants and Untyped Literals

See §15.4.

### 14.6 Comparability

- Numeric, `bool`, `string`, `rune` values compare with `==`/`!=` and (numerics,
  strings) with ordering operators.
- Arrays and tuples are comparable if their element types are; structs are
  comparable if all fields are comparable (field-wise).
- A C-like enum (all variants payload-free) compares with `==`/`!=` by tag, and
  may be a map key. A payload-carrying enum is not comparable — use `match`.
- Slices, maps, and functions are **not** comparable except against `nil`.
- Interface values are comparable; two are equal if their dynamic types are
  identical and their dynamic values are equal (panics if the dynamic type is not
  comparable — a documented runtime condition).
- Map keys (`K`) must be a comparable type; a non-comparable key type is a compile
  error.

### 14.7 Enum Types

An enum is a nominal type whose values are one of a fixed, named set of variants:

```
enum_decl    = "enum" IDENT [ generic_params ] "{" { enum_variant [ "," ] } "}" .
enum_variant = IDENT [ "(" type { "," type } ")" ] .   (* optional payload *)
```

```
enum Color { Red, Green, Blue }
let c = Color.Green            // no-payload variant: EnumName.Variant

enum Shape { Circle(f64), Rect(f64, f64), Unit }
let s = Shape.Rect(3.0, 4.0)   // payload variant: construct with arguments
```

- **Nominal identity** (unlike structs/interfaces, §14.1): two enums with the same
  variant names are still distinct types. A bare `Color` is a type, not a value;
  a value is written `Color.Variant`.
- A variant may carry an ordered **payload** (`Circle(f64)`), making the enum a
  tagged union / sum type. A payload variant is constructed by calling it with
  arguments (`Shape.Rect(3.0, 4.0)`); the argument types and count must match the
  declaration. A no-payload variant is written bare (`Shape.Unit`).
- Enum values are consumed by `match` (§13.8), which is exhaustive over the
  variants and binds a variant's payload in its arm. Enums are not ordered and not
  `==`-comparable in v0.1 — use `match`.
- An enum may be **generic** (`enum Option<T> { Some(T), None }`), monomorphized
  per instantiation like a generic struct (§14.1, §15). A construction's type
  arguments are usually inferred: from the payload argument (`Option.Some(5)`
  gives `Option<i64>`), from the expected type when no argument constrains a
  parameter — a bare `None`, or the `E` in `Result.Ok(v)` (`let o: Option<i64> =
  Option.None`, a function's declared return type) — and, for a nested
  construction, from a parameter an earlier argument already fixed (the tail of
  `List.Cons(1, List.Cons(2, List.Nil))` needs no annotation). When inference has
  nothing to go on, spell the arguments explicitly with a **turbofish** at the
  variant site: `Option<i64>.None`, `Result<i64, string>.Ok(v)`. A parameter left
  unfixed with no turbofish is an error. The prelude (§17) defines `Option<T>` and
  `Result<T, E>` this way.

Representation (non-normative): a no-payload-only enum is a bare tag word; an
enum with any payload is a boxed `{tag, payloadPtr}` object whose payload is a
separately allocated, GC-traced record. Inline (unboxed) payload layout is a
future optimization.

---

## 15. Type Inference

Inference is local and bidirectional (Hindley-Milner-lite with expected types); it
never crosses a named-function signature boundary.

### 15.1 Local Variable Inference

`let x = e` gives `x` the type of `e`. `const` likewise. If `e` is an untyped
constant, its **default type** applies (§15.4) unless an annotation forces another.

### 15.2 Composite Literal Inference

For a bare `[e1, e2, ...]` slice literal with no expected type, the element type is
the common type of the elements: they must all be identical, or all be untyped
constants sharing a default type. With an expected type `[]T`, each element is
checked against `T`.

### 15.3 Call and Generic Inference

- Argument expressions are checked against the parameter types (an expected type
  flows inward, enabling bare arrow parameters and untyped-constant adaptation).
- For a generic call `f(args)` without explicit type arguments, each type
  parameter is inferred by unifying parameter types with argument types. If any
  type parameter cannot be inferred, the call is an error and explicit type
  arguments are required (`f<T>(args)`, §12.7).

### 15.4 Untyped Constants

Integer, float, rune, string, and bool **literals** (and `const` expressions over
them) are *untyped constants* with arbitrary precision until placed in a typed
context. Each has a **default type** used when no other type is implied:

| Constant kind | default type |
| ------------- | ------------ |
| integer       | `int` (`i64`) |
| float         | `f64`        |
| rune          | `rune` (`i32`) |
| string        | `string`     |
| bool          | `bool`       |

A constant is usable in any type in which it is **representable** (e.g. `200` is
usable as `u8`, `300` is not — compile error). Constant expressions are evaluated
at compile time with no overflow (overflow of the *final* target type is the
representability error). This is the sole implicit-conversion path.

---

## 16. Concurrency

### 16.1 Green Threads

```
spawn f(args)
```

`spawn` starts `f(args)` on a new green thread (goroutine-equivalent) scheduled by
the runtime over a pool of OS threads. The argument **must be a call
expression**; its arguments are evaluated in the current thread before the new
thread starts (establishing the happens-before edge, §13.7). `spawn` returns
nothing; there is no thread handle in v0.1 (coordinate via channels).

The number of OS worker threads is chosen by the runtime at startup and is fixed
thereafter (no unbounded thread creation, per the resource-predictability rule).

### 16.2 Channels

```
let c = chan<int>()      // unbuffered (synchronous)
let b = chan<int>(16)    // buffered, capacity 16
```

Operations:

- **Send** (statement): `c <- v`. Blocks until a receiver is ready (unbuffered) or
  buffer space exists (buffered). Sending on a closed channel **panics**. Sending
  on a `nil` channel blocks forever.
- **Receive** (expression): `<- c`. Blocks until a value is available. Two-result
  form `let (v, ok) = <- c` sets `ok=false` when the channel is closed and drained
  (then `v` is the zero value). Receiving from a `nil` channel blocks forever.
- **Close**: `close(c)` (builtin). Marks the channel closed; subsequent sends
  panic, receives drain remaining buffered values then yield `(zero, false)`.
  Closing a `nil` or already-closed channel panics. Only the sending side should
  close.
- **Range**: `for v of c { ... }` receives until the channel is closed and drained.

### 16.3 Select

```
select_stmt = "select" "{" { comm_clause } "}" .
comm_clause = "case" ( send_stmt | recv_bind ) ":" { statement ";" }
            | "default" ":" { statement ";" } .
recv_bind   = [ ( IDENT | tuple_pat ) "=" ] "<-" expression .
```

`select` blocks until exactly one of its `case` communications can proceed, chooses
one **uniformly at random** among those ready, and runs that clause. A `default`
clause, if present, runs when no case is immediately ready (making the select
non-blocking). Example:

```
select {
  case v = <- in:      handle(v)
  case out <- next:    advance()
  default:             idle()
}
```

An empty `select {}` blocks forever. `case` communications are evaluated (channel
operands and, for sends, the sent value) once, at entry to the select.

---

## 17. Modules and Visibility

### 17.1 Modules

A module is a directory of `.bit` files sharing one declaration namespace. There is
no per-file `package` clause; membership is by directory. Circular imports between
modules are an error.

A single `.bit` file named directly on the command line (`bit run hello.bit`) is a
module of exactly that one file. Its siblings in the same directory are *not* part
of it — naming a file selects that file, naming a directory selects all of it. It
is a module like any other: it gets the prelude (§17.5) and may import (§17.2).

### 17.2 Imports

```
import_decl = "import" import_body "from" STRING_LIT .
import_body = IDENT                              (* namespace binding *)
            | "*" "as" IDENT                     (* explicit namespace *)
            | "{" import_item { "," import_item } [ "," ] "}" .
import_item = IDENT [ "as" IDENT ] .
```

The string is a **module path**: `"std/io"`, `"std/net/http"` for standard-library
modules, or a relative path `"./util"`, `"../shared"` for project-local modules.

- `import io from "std/io"` binds the namespace `io`; members accessed as
  `io.println(...)`.
- `import * as io from "std/io"` is the explicit spelling of the same.
- `import { println, printf } from "std/io"` binds the named members directly.
- `import { println as say } from "std/io"` renames on import.

Only **exported** members (§17.3) are importable. Import cycles are rejected.

**Wrapping a long import.** An `import` is an ordinary statement, so §7's semicolon
insertion applies to it unchanged — there is no import-specific newline rule. A
line break is therefore only legal where the line does **not** end in a terminator
token. `}` and IDENT are terminators, so these two forms are **rejected**:

```
import { f, g }
  from "./util"      // ';' inserted after '}' -> "expected 'from'"

import {
  f,
  g                  // ';' inserted after 'g' -> "expected '}'"
} from "./util"
```

The wrapped spelling that works ends every broken line on `{` or `,`, neither of
which is a terminator — that is, the usual trailing-comma style:

```
import {
  f,
  g,
} from "./util"
```

A single-line `import` needs no trailing comma. This is the same rule that governs
every other statement, applied without exception; §7's line-continuation guidance
is the general form of it.

### 17.3 Visibility

Visibility is by the explicit `export` keyword, not by identifier casing:

- A top-level declaration marked `export` is visible to importing modules.
- A struct **field** marked `export` is readable/writable outside the module; an
  unexported field is module-private (and may not appear in a foreign composite
  literal or be selected outside the module).
- A method is exported by placing `export` before its `function` keyword (§10.4);
  an exported type may still have unexported methods (they do not contribute to
  satisfaction of an interface used across module boundaries only if the interface
  is also foreign — normally satisfaction is checked where the value is used).
- Unmarked declarations are module-private.

### 17.4 Entry Point

The executable module is the **root module** of a build (the directory passed to
`bit build`). It must declare exactly one function named `main`. Permitted
signatures:

```
function main() { ... }          // exit code 0 on normal return
function main(): int { ... }     // returned int is the process exit code
function main(): ()! { ... }     // a returned error prints to stderr, exit code 1
```

`main` takes no parameters; command-line arguments and environment are read via
the standard library (`std/os`). A non-executable (library) module has no `main`.

`bit build --emit-obj` (`-c`) stops at a **relocatable object** instead of an
executable. An object is not a program, so it requires no `main` and gets no
entry trampoline; a module without one is built this way. `bit ar <out.a>
<obj...>` bundles such objects into an `ar` archive, using the target's own name
encoding (BSD for Mach-O, GNU/System V for ELF). Neither command reads the
runtime archive, and neither links. An object destined for an archive is
normally emitted `--freestanding` (§17.6).

### 17.5 Prelude

Every module implicitly imports the exports of `std/core` — the **prelude** — as
if by `import { ... } from "std/core"`, with no `import` line. A name the module
declares or explicitly imports shadows the prelude name. The prelude provides the
handful of names a program is expected to reach for unqualified: `println`,
`newError`, the generic enums `Option<T>` and `Result<T, E>` (§14.7), and their
helpers — `unwrap`/`unwrapOr`/`isSome`/`isNone` for `Option`, and
`unwrapOk`/`okOr`/`isOk`/`isErr` for `Result` (the `unwrap*` forms panic on the
empty case). A build without a standard-library checkout simply has no prelude.

### 17.6 Freestanding Objects

`bit build <src> --emit-obj --freestanding` compiles a module as a **member of a
runtime archive** rather than as part of a program. It is the mode a Bit-sourced
`libbitrt.a` is built in, and it is only meaningful with `--emit-obj` (there is
no freestanding executable — nothing would boot it), so the two are required
together.

It makes exactly two guarantees, both about what the object does *not* contain.

**No prelude.** The stdlib root is withheld, so §17.5's implicit `std/core`
import does not happen and no `std/*` import resolves. A module that reaches for
`println` fails with the ordinary undefined-name diagnostic (**E0040**), because
the name genuinely is not in scope. The managed/unmanaged boundary is therefore
enforced by absence, not by a list of forbidden names — a runtime module cannot
depend on managed code by accident, only by writing an import that fails.

**Module-scoped emission.** An ordinary build lowers the root module *and every
module it imports* into one object. Two such objects share every imported
module's code, so archiving them is an immediate duplicate-symbol error. A
freestanding object holds only the functions the **root module itself**
declares; a call into an imported module stays an undefined relocation, resolved
at link against that module's own object, exactly as a call to an `extern
function` (§11.7) is.

Because a cross-module reference now has to survive as a *name*, and an
unpinned name carries the `m<id>$` prefix that whichever build imports the
module assigns, **every runtime function another module calls must pin its
symbol with `@symbol` (§11.9)**. Without a pin the defining object and the
referencing object spell the same function differently and never link.

This is **enforced, not merely required**: a freestanding emit is refused if the
object would reference any symbol it does not define whose name is not a valid
pin — a compiler-mangled name (one containing `$`) can only have come from this
build's own module numbering, so no sibling object can ever define it. The
refusal names the offending symbol. It has to happen here because nothing
downstream reports it near its cause: an undefined symbol in an archive member
nothing references is dead-stripped rather than diagnosed, and on Darwin an
unresolved reference falls through to a libSystem import and aborts at dynamic
load. A `bit_rt_*` runtime symbol and a §11.7 `extern` both pass this test for
the same reason a pin does — their names carry no `$`.

A freestanding object also carries none of the whole-program tables a managed
program's object does, since exactly one object per link may define each:

- **no GC type descriptors.** Needing one means the module allocates on the
  managed heap, which the runtime — the code that *implements* that heap —
  must not do. Refused, rather than emitted without the descriptor.
- **no whole-program `bit_stack_maps` table** — but this is *not* a restriction
  on what the member's functions may do. Each member emits its **own** GC
  stack-map entries into a dedicated section, and the linker concatenates every
  member's entries into one table bounded by the two symbols it defines itself
  (`runtime/ABI.md` §4). A member's frames are therefore fully scannable, so its
  functions may allocate nothing but may otherwise reach safepoints freely.

  Earlier drafts of this section required every function in a freestanding
  object to be `@nosplit` or `@naked`, on the sound argument that an absent
  stack map is only safe for a frame no collection can begin beneath. That
  requirement is **deleted**, because it made the scheduler unrepresentable: a
  worker loop must reach safepoints — that is how it yields to a stop-the-world
  rendezvous — so it cannot be `@nosplit`, and neither can a member that
  legitimately contains an `asm` barrier or an indirect call. Per-member tables
  remove the premise rather than carve out exceptions to it.
- **string literals are local**, not global. Nothing outside the object names
  them, so two members' literals cannot collide.

---

## 18. Error Handling

### 18.1 Model Decision and Rationale

Bit uses **Result-style error values with explicit propagation**, not exceptions.

*Justification (one paragraph).* Exceptions (`try`/`catch` with stack unwinding)
introduce hidden, non-local control-flow paths — the exact thing the project's
Power-of-10 rules forbid ("no hidden or non-local execution paths"). Go's
alternative — returning `(T, error)` tuples and writing `if err != nil` after
every call — is explicit but verbose, which conflicts with the #1 goal of being
easy to write. Bit takes the middle path proven by Rust and Swift: fallible
functions return a result value, propagation is a single explicit postfix operator
(`?`), and handling is a local expression (`catch`). Control flow stays visible and
statically analyzable (every early exit is a `?` or `fail` you can see), while the
common path stays terse. Truly unrecoverable conditions (bugs: index out of range,
nil dereference, failed assertion) use `panic` (§18.4), which aborts the program
rather than being silently caught.

### 18.2 Fallible Functions

A function whose result type carries the `!` marker is **fallible**:

```
function readAll(path: string): string! { ... }        // returns string OR error
function fetch(u: string): Response ! HttpError { ... } // custom error type E
function run(): ()! { ... }                             // returns nothing OR error
```

`T!` is shorthand for `T ! error` (the default error type is the predeclared
`error` interface, §10.6). `T ! E` names a concrete error type. The value of a
fallible function is a built-in result carrying either an **ok** value of `T` or an
**err** value of `E`; it is not a general union and cannot be constructed by hand
except via `return`/`fail`.

### 18.3 Producing, Propagating, Handling

- **Produce ok:** `return v` inside a fallible function wraps `v` (assignable to
  `T`) as the ok result. `return` alone in a `()!` function returns ok-void.
- **Produce err:** `fail e` returns the err result carrying `e` (assignable to
  `E`). `fail` is a terminating statement, like `return`.
- **Propagate:** postfix `expr?` evaluates a fallible `expr`; if it is err, the
  enclosing function immediately returns that err (its `E` must be assignable to
  the enclosing function's error type); if ok, `expr?` evaluates to the unwrapped
  `T`. `?` is only legal inside a fallible function.
- **Handle:** the `catch` expression consumes a fallible value locally:

```
catch_expr = binary [ "catch" ( expression | IDENT block ) ] .
```

  - `expr catch default` — evaluates to the ok value, or to `default` (of type `T`)
    if err. The err value is discarded.
  - `expr catch e { ... }` — binds the err value to `e` in the block; the block
    must either produce a `T` (its final expression) or divert control
    (`return` / `fail` / `panic` / `break` / `continue`). This is the full-handling
    form.

Example:

```
function loadConfig(path: string): Config! {
  let text = readAll(path)?              // propagate a read error upward
  let cfg  = parse(text) catch e {
    log("bad config: ${e.message()}")
    return defaults()                    // recover with a default Config
  }
  if (!cfg.valid()) { fail newError("config failed validation") }
  return cfg
}
```

The predeclared **`newError(msg: string): error`** (core prelude, §17) builds a
basic error whose `message()` returns `msg` — the ordinary way to produce an
`error` when no richer error type is warranted. A program that needs structured
errors instead defines its own type with a `message(): string` method (any such
type satisfies the `error` interface structurally, §10.6) and `fail`s a value of
it. `error` is a type name, so the constructor cannot itself be named `error`
(value and type names share one namespace, §17.1).

### 18.4 Panics

A **panic** is an immediate, unrecoverable abort of the program with a message and
a stack trace to stderr, and a non-zero exit code. Panics are for programmer
errors and broken invariants, never for expected failures. Sources of panic:

- index/slice out of range; integer divide-by-zero; signed overflow in debug
  builds (§13.5);
- write to a `nil` map; send/close on a `nil` or closed channel; call of a `nil`
  function; type assertion mismatch (single-result form);
- explicit `panic(msg)` builtin;
- a failed `assert(cond)` / `assert(cond, msg)` builtin.

There is **no `recover`** in v0.1: panics are fatal by design, keeping control flow
free of hidden unwinding. Recoverable conditions must use the Result model.

### 18.5 Deferred Cleanup

```
defer close(f)
defer conn.release()
```

`defer call` schedules a call to run when the enclosing **function** returns, by any
path (normal `return`, `fail`, or propagation `?`), in **last-in-first-out** order.
Deferred calls also run while a panic unwinds to the program's top (so cleanup
happens before abort), but they cannot stop the panic. Deferred call arguments are
evaluated at the `defer` statement, not at execution time. `defer` gives
deterministic resource release without finalizers.

---

## 19. Testing

A **test** is a top-level function whose name begins with `test_`, taking no
parameters and returning nothing:

```
function test_addition() {
  assert(1 + 1 == 2)
}

function test_concat() {
  assert("ab" + "c" == "abc", "string concat")
}
```

- No new syntax: a test is an ordinary function, so `test` is not a reserved
  word (§5.2) and a test may call any function in its module.
- `bit test <file.bit|dir>` discovers every `test_` function in the **root**
  module (never in an imported one), runs each, and prints `ok`/`FAIL` per test
  plus a summary. It exits `0` iff every test passed, `1` otherwise.
- A test fails when it panics — which a failed `assert` (§18.4) does. Each test
  therefore runs in its own process, so one failure neither hides the others nor
  aborts the run.
- Tests are ordinary unreferenced functions to `bit build`/`bit run`, so the
  linker's dead-strip drops them from a normal program's binary.
- Test execution order is the order of declaration; tests must not depend on it.

Richer assertions with value diffs live in `std/testing`, layered on this runner.

---

## 20. Worked Example

A complete, conforming program exercising the major features:

```
import { println } from "std/io"
import { readAll } from "std/fs"

interface Shape { area(): f64 }

struct Circle { export r: f64 }
struct Rect   { export w: f64; export h: f64 }

function (c: Circle) area(): f64 { return 3.14159265358979 * c.r * c.r }
function (r: Rect)   area(): f64 { return r.w * r.h }

// Generic: works for any Shape (structural satisfaction).
function totalArea<T: Shape>(shapes: []T): f64 {
  let sum = 0.0
  for s of shapes {
    sum += s.area()
  }
  return sum
}

// Fallible: parse an f64 count from a file, default to a computed value on error.
function loadCount(path: string): int! {
  let text = readAll(path)?           // propagate fs errors
  return parseInt(text)?              // propagate parse errors
}

// Concurrency: fan work out to green threads, collect over a channel.
function sumSquares(n: int): int {
  let results = chan<int>(n)
  for (let i = 1; i <= n; i++) {
    spawn worker(i, results)
  }
  let total = 0
  for (let k = 0; k < n; k++) {
    total += <- results
  }
  return total
}

function worker(x: int, out: chan<int>) {
  out <- x * x
}

function main(): ()! {
  let shapes: []Shape = [Circle{ r: 1.0 }, Rect{ w: 2.0, h: 3.0 }]
  println("area = ${totalArea(shapes)}")
  println("sum  = ${sumSquares(4)}")
  let count = loadCount("count.txt") catch 0
  println("count = ${count}")
  return
}
```

---

## 21. Reserved for Future Versions (non-normative)

Intentionally **not** in v0.1, to keep the surface minimal:

- General union and optional types; `null` (absence is modeled by `nil` zero
  values and the Result model).
- The address-of operator `&` and value-vs-pointer receivers. (The raw untraced
  pointer type `*T` and its dereference `*p` *are* specified — see §11.4 — for the
  unmanaged subset; only taking the address of a value with `&` remains reserved.)
- Operator overloading; user-defined implicit conversions.
- `recover`; catchable panics.
- Mutexes and `sync`-style primitives (channels are the safe concurrency
  primitive in v0.1). Lock-free **atomics** on a raw `*T` *are* specified — see
  §11.5 — for the unmanaged subset; only their weaker memory orderings (a
  seq-cst-only surface ships now) remain reserved.
- Nominal newtypes (all `type` aliases are transparent in v0.1).
- Thread handles / structured concurrency for `spawn`.
- UTF-8 rune conversions (`string(rune)`, `string([]rune)`, `[]rune(s)`) and
  rune iteration (`for r of s`); byte-level `string`/`[]byte` conversion (§12.9)
  and byte indexing (§12.6) are available now.
- Re-slicing a fixed-size array `[N]T` (arrays are not yet constructible as
  values); `[]T` and `string` re-slicing (§12.6) are available now.

These are recorded so downstream tooling (grammar, checker, docs) knows the
boundaries of v0.1 and does not accidentally depend on unspecified behavior.

---

## Appendix A — Consolidated EBNF

*(Lexical rules are in §4–§7; this appendix collects the syntactic grammar. The
token `";"` below is produced per §7.)*

```
program       = { ";" } { top_decl ";" } EOF .

top_decl      = import_decl
              | [ "export" ] value_decl
              | [ "export" ] func_decl
              | [ "export" ] struct_decl
              | [ "export" ] interface_decl
              | [ "export" ] enum_decl
              | [ "export" ] type_alias
              | method_decl .

import_decl   = "import" import_body "from" STRING_LIT .
import_body   = IDENT | "*" "as" IDENT
              | "{" import_item { "," import_item } [ "," ] "}" .
import_item   = IDENT [ "as" IDENT ] .

value_decl    = ( "let" | "const" ) binding { "," binding } .
binding       = ( IDENT | tuple_pat ) [ ":" type ] [ "=" expression ] .
tuple_pat     = "(" pat { "," pat } ")" .
pat           = IDENT | "_" | tuple_pat .

type_alias    = "type" IDENT [ generic_params ] "=" type .

func_decl     = [ attr_list ] "function" IDENT [ generic_params ] signature block .
attr_list     = attr { attr } .
attr          = "@" IDENT .
method_decl   = [ "export" ] "function" "(" receiver ")" IDENT [ generic_params ] signature block .
receiver      = IDENT ":" type_name .
signature     = "(" [ params ] ")" [ ":" result_type ] .
params        = param { "," param } [ "," ] .
param         = [ "..." ] IDENT ":" type .

struct_decl   = "struct" IDENT [ generic_params ] "{" [ field { fsep field } [ fsep ] ] "}" .
field         = [ "export" ] IDENT ":" type .
interface_decl= "interface" IDENT [ generic_params ] "{" [ method_sig { fsep method_sig } [ fsep ] ] "}" .
method_sig    = IDENT signature .
fsep          = ";" | "," .

generic_params= "<" generic_param { "," generic_param } ">" .
generic_param = IDENT [ ":" constraint ] .
constraint    = type_name { "&" type_name } .

type          = type_name | slice_type | array_type | map_type | tuple_type
              | func_type | chan_type | generic_inst | "(" type ")" .
type_name     = IDENT .
slice_type    = "[" "]" type .
array_type    = "[" INT_LIT "]" type .
map_type      = "map" "<" type "," type ">" .
tuple_type    = "(" type "," type { "," type } ")" .
func_type     = "(" [ type { "," type } ] ")" "=>" result_type .
chan_type     = "chan" "<" type ">" .
generic_inst  = IDENT "<" type { "," type } ">" .
result_type   = type [ "!" [ type ] ] .

block         = "{" { statement ";" } "}" .
statement     = value_decl | assign_stmt | inc_dec_stmt | expr_stmt
              | if_stmt | for_stmt | while_stmt | switch_stmt | select_stmt
              | return_stmt | fail_stmt | break_stmt | continue_stmt
              | spawn_stmt | defer_stmt | send_stmt | block | ";" .

assign_stmt   = lhs { "," lhs } assign_op expression { "," expression } .
lhs           = IDENT | index | member | tuple_pat .
assign_op     = "=" | "+=" | "-=" | "*=" | "/=" | "%="
              | "&=" | "|=" | "^=" | "<<=" | ">>=" .
inc_dec_stmt  = lhs ( "++" | "--" ) .
expr_stmt     = expression .
send_stmt     = expression "<-" expression .
return_stmt   = "return" [ expression { "," expression } ] .
fail_stmt     = "fail" expression .
break_stmt    = "break" .
continue_stmt = "continue" .
spawn_stmt    = "spawn" postfix .          (* postfix must be a call *)
defer_stmt    = "defer" postfix .          (* postfix must be a call *)

if_stmt       = "if" "(" expression ")" block [ "else" ( if_stmt | block ) ] .
while_stmt    = "while" "(" expression ")" block .
for_stmt      = "for" ( for_c | for_of | for_in | (* empty -> infinite *) ) block .
for_c         = "(" [ value_decl | assign_stmt ] ";" [ expression ] ";" [ inc_dec_stmt | assign_stmt ] ")" .
for_of        = ( IDENT | "(" pat "," pat ")" ) "of" expression .
for_in        = IDENT "in" expression .
switch_stmt   = "switch" [ "(" expression ")" ] "{" { switch_case } "}" .
switch_case   = "case" expression { "," expression } ":" { statement ";" }
              | "default" ":" { statement ";" } .
match_stmt    = "match" "(" expression ")" "{" { match_arm [ ";" ] } "}" .
match_arm     = variant_pat "=>" statement .
variant_pat   = IDENT [ "(" IDENT { "," IDENT } ")" ] .   (* name + payload binders; §13.8 *)
select_stmt   = "select" "{" { comm_clause } "}" .
comm_clause   = "case" ( send_stmt | recv_bind ) ":" { statement ";" }
              | "default" ":" { statement ";" } .
recv_bind     = [ ( IDENT | tuple_pat ) "=" ] "<-" expression .

expression    = arrow_fn | catch_expr .
catch_expr    = binary [ "catch" ( expression | IDENT block ) ] .
arrow_fn      = arrow_params "=>" ( expression | block ) .
arrow_params  = IDENT | "(" [ arrow_p { "," arrow_p } [ "," ] ] ")" .
arrow_p       = IDENT [ ":" type ] .

binary        = unary { binop unary } .    (* disambiguated by §12 precedence table *)
binop         = "*" | "/" | "%" | "<<" | ">>" | "&"
              | "+" | "-" | "|" | "^"
              | "==" | "!=" | "<" | "<=" | ">" | ">="
              | "&&" | "||" .
unary         = ( "!" | "-" | "+" | "~" | "<-" ) unary | postfix .
postfix       = primary { call | index | slice | member | type_assert | "?" } .
call          = [ "<" type { "," type } ">" ] "(" [ arguments ] ")" .   (* §12.7 *)
index         = "[" expression "]" .
slice         = "[" [ expression ] ":" [ expression ] "]" .
member        = "." ( IDENT | INT_LIT ) .
type_assert   = "." "(" type ")" .
arguments     = arg { "," arg } [ "," ] .
arg           = [ "..." ] expression .

primary       = literal | IDENT | "(" expression ")" | composite_lit
              | "[" [ arguments ] "]" .    (* bare slice literal *)
composite_lit = type_name [ "<" type { "," type } ">" ] "{" [ field_inits ] "}"
              | slice_type "{" [ arguments ] "}"
              | array_type "{" [ arguments ] "}"
              | map_type   "{" [ map_entries ] "}" .
field_inits   = field_init { "," field_init } [ "," ] .
field_init    = IDENT ":" expression .
map_entries   = map_entry { "," map_entry } [ "," ] .
map_entry     = expression ":" expression .

literal       = INT_LIT | FLOAT_LIT | STRING_LIT | RAW_STRING_LIT
              | RUNE_LIT | BOOL_LIT | NIL_LIT .
```

**End of Bit Language Specification v0.1.**
