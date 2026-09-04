# Bit Language Specification

**Version:** 0.1 (draft)
**Status:** Authoritative. Compiler, docs, TextMate grammar, and tests derive from this document. Any change discovered during implementation is made here first.
**Date:** 2026-07-03

<!-- doctest: per-block -->

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

- **Syntax:** TypeScript-flavored — `let`/`const`, `fn`, arrow functions,
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
as     asm     break     case     catch      chan
class  const   continue  default  defer      else
enum   export  fail      false    fn         for
from   if      import    in       interface  let
map    match   nil       of       return     select
spawn  switch  this      trait    true       type
while
```

`struct` is not a keyword. Pre-0.1.24 code that declared types with `struct` is
rejected with `error[E0102]: 'struct' is not a keyword`, naming `class` as the
replacement (§10.5). The rename (#3425) is mechanical: only the keyword changes
— field access, method syntax, and reference semantics are identical either way.

`assert` is *not* reserved: like `panic` and `len` it is a predeclared builtin
function (§5.3, §16), so it must be an identifier for `assert(cond)` to parse as
a call.

`match` selects on an enum value and binds its payload (§13.8).

`this` is the implicit receiver of a method declared inside a class body
(§10.4); it is never written at the declaration site and names nothing outside
a method body.

`trait` declares a trait (§10.7). `use` and `Self` are **not** keywords:
`use` lexes as an ordinary identifier and is recognized only where a class or
trait body expects a member and sees `use` followed by another identifier — a
field or method literally named `use` is always followed by `:`, `(`, or `<`
instead, so there is no ambiguity. `Self` is likewise an ordinary identifier,
predeclared as a type name only inside a trait or interface body (§10.7,
§11.3); anywhere else it is simply undefined.

### 5.3 Predeclared Identifiers (not keywords)

These are ordinary identifiers bound in the universe scope. They may be shadowed
by user declarations (doing so is discouraged and lints as a warning, **E0048**)
— with one exception: a **root-module** function whose bare name also names a
symbol the linked runtime resolves externally is rejected outright (**E0096**,
§11.7), because shadowing it there does not merely change name resolution, it
changes what the linker binds the runtime's own call to. Every other module is
unaffected, since only the root module's link names are left bare.

- Types: `i8 i16 i32 i64  u8 u16 u32 u64  f32 f64  int uint  byte rune  bool string  error`
- Constants: none beyond the `true`/`false`/`nil` literals.
- Builtin functions: `len cap append delete close panic assert` (§16),
  and `parseFloat` (below).

`int` is an alias for `i64`; `uint` for `u64`; `byte` for `u8`; `rune` for `i32`.
Sizes are fixed on every target for deterministic behavior (this is not Go's
platform-dependent `int`).

**`parseFloat(s: string) -> f64`** converts decimal or hexadecimal float text to
the nearest `f64`. The accepted text is an optional leading `+` or `-` followed
by either `FLOAT_LIT` (§5.5) or a bare `DIGITS` sequence (§5.5) with no `.` and
no exponent — `parseFloat` is a strict superset of the token grammar `FLOAT_LIT`
itself defines, since a caller handing it arbitrary text (a config value, a JSON
number, a form field) has no reason to spell an integer with a trailing `.0`
first: `parseFloat("42") == 42.0`. Hex text is not loosened this way — the `p`
exponent §5.5 makes mandatory for `HEX_FLOAT` is still mandatory here, so
`parseFloat("0x1.8")` (no exponent) is a failed parse, not `1.5`.

`_` digit separators are accepted throughout, but only exactly where §5.4
allows them: between two digits of the group they separate, never leading,
trailing, or doubled, checked independently for the integer part, the
fraction, an exponent, and (hex) each side of the mantissa's `.` — so
`parseFloat("4_2")` is `42.0`, but `parseFloat("1__0")`, `parseFloat("_1")`,
and `parseFloat("1_")` are all failed parses (§5.4's three forbidden shapes,
doubled/leading/trailing, applied to the one digit group each of those strings
has). The conversion is correctly rounded (round-to-nearest-even on the exact
value, never an approximation), so a given text always denotes the same `f64`
on every target.

**Text it cannot parse yields a quiet NaN**, so a failed conversion is
distinguishable from every successful one — `parseFloat("nonsense")` is not
`parseFloat("0")`. Callers test the result with `v != v`, which is true only for
NaN. `parseFloat` does not panic and is not fallible: the value *is* the report.
Only the failure is specified, not a particular NaN payload or sign, and a NaN is
therefore not a legal successful result — the text `"nan"` is not a `FLOAT_LIT`
and does not parse.

Rationale for the NaN rather than a `f64!` or a `(f64, bool)`: `parseFloat` is
predeclared, so its signature is part of every program's scope and cannot change
without breaking every caller, and NaN is already the IEEE 754 value reserved for
"not a number". Returning `0.0` — which earlier implementations did — made a bad
parse indistinguishable from a good one, silently turning every malformed numeric
field into zero.

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

A raw string's bytes are taken verbatim (a `CR LF` inside is normalized to `LF`);
this is not changing. A raw string containing a well-formed `${` … `}` pair
lints as a warning (`${` is literal text here, never interpolation — the
inverse of the interpreted string above, and the exact syntax an author
arriving from a language where backtick strings interpolate is likely to write
by mistake), **E0098**. A bare `$`, a `$foo`-shaped reference, or an unmatched
`${` do not warn — those are ordinary raw-string content (a shell snippet, a
Makefile fragment, another language's template).

### 5.8 Boolean and Nil Literals

```
BOOL_LIT = "true" | "false" .
NIL_LIT  = "nil" .
```

`nil` is the zero value of a reference type that has no live zero — a map,
channel, function, or interface. `string`, `class`, and `[]T` have usable zero
values instead (§13.4).

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
`headers: map<string, string>` class field, and an interface method returning
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

- **Keywords:** the 36 words in §5.2.
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
             | [ "export" ] class_decl
             | [ "export" ] interface_decl
             | [ "export" ] trait_decl
             | [ "export" ] enum_decl
             | [ "export" ] type_alias
             | [ "export" ] extern_fn_decl .
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
  binding, not required to be compile-time constant). A top-level `const` may also
  bind a **constant `[N]T` composite literal** (`[N]T{...}` whose every element is
  a compile-time constant scalar); it is materialized once into the read-only
  class (§11.11) — a `.rodata` image, not a per-reference allocation — and, being
  read-only, a write through it (`K[i] = v`) is rejected.
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
func_decl     = [ attr_list ] "fn" IDENT [ generic_params ] signature block .
signature     = "(" [ params ] ")" [ ":" result_type ] .
params        = param { "," param } [ "," ] .
param         = [ "..." ] IDENT ":" type .
result_type   = type .            (* may carry the fallible marker, §18 *)
```

- The return type is written after `:`. If omitted, the function returns nothing
  (its result type is the empty tuple `()`, i.e. "void").
- Named `fn` declarations **require** type annotations on every parameter
  and (unless void) on the result. This keeps checking modular and diagnostics
  precise. Type inference applies to `let`/`const` initializers and to arrow
  function bodies (§12.8), not to named-function signatures.
- A variadic parameter (`...name: T`) must be last; inside the body it has type
  `[]T`. At a call site the caller passes zero or more `T` arguments, or spreads a
  `[]T` with `...` (§12.4).

#### 10.3.1 Function Attributes

An attribute constrains how a function is compiled. Attributes precede
`fn` and attach to function declarations only:

```
attr_list     = attr { attr } .
attr          = "@" IDENT [ "(" STRING_LIT ")" ] .
```

`export` stays outermost: `export @naked fn f() {}`. An attribute list may
also sit on its own line above the declaration it modifies; the semicolon
automatic insertion would place there (§7) is not meaningful, because an
attribute list is only ever followed by another attribute or `fn`.

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
to the **atomic builtins** (§11.5), to **`ptrOf`** (§11.5), **`entryOf`**
(§11.10) and **`stackMapsBegin`/`stackMapsEnd`** (§11.12), a raw **`syscall`**
(§11.8), **`len`/`cap` over a fixed-size array** (§11.2), a **provably
in-range index into a fixed-size array** (§12.6), and **conversions
between numeric prims** (§12.9), all of which lower
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

`len`/`cap` are admitted **only** when the argument's type is a fixed-size
array `[N]T` (§11.2): `N` is a compile-time constant, so both builtins lower
to that constant directly and the argument expression is not evaluated at
all — no field read, no call, no allocation, no safepoint. This is a
type-conditional admission of the *operand*, not of the builtin name:
`len`/`cap` on a slice or a string still lower to a field read of the slice
header, and on a map to an allocating runtime call, so all three remain
**E0075** under the "anything else" rule below.

**Indexing** (§12.6) a **fixed-size array** `[N]T` (§11.2) is admitted **only**
when the index is **provably in range at compile time** — a bare literal
already inside `[0, N)`, or that literal masked with `& m` where `m < N`
(`x & m` is always in `[0, m]` for any `x`, since ANDing with a non-negative
literal clears the sign bit and can only clear bits `m` itself has cleared —
this is the shape a hash-table style lookup `TAB[i & 3]` uses to stay in
range with no data-dependent branch at all). Only then does `a[i]` lower to a
bare `index_get`, a scaled register-offset load against a static base, with
no bounds-check branch, no call, no allocation and no safepoint.
An index that is **not** provably in range this way — a bare variable, or an
expression the compiler cannot bound — is refused, for the identical reason a
slice index already is: `index_get` for such an index now compiles to a
bounds-check branch whose out-of-range edge calls `bit_rt_panic` with a
materialized message, and this allowlist judges a construct by every edge it
can take, not by its likely one. This is a type-and-value-conditional
admission, not of indexing in general — the base, the index expression, and
(when the check does run) the runtime path it takes are irrelevant to the
proof; only a statically bounded index counts. A **slice** base is refused
unconditionally, since its length is a runtime field and no compile-time
proof of "in range" is possible for it at all, and a **map** base is a
runtime call outright — both remain **E0075** under the "anything else" rule
below.

A **`syscall` (§11.8)** is admitted on the strongest proof on that list: it is
not a call at all. Both backends emit the kernel trap *inline* — `syscall` on
x86-64, `svc #0` on AArch64 — so it references no symbol, takes no stack-map
entry, and allocates nothing. The kernel returns to the instruction after the
trap and Bit expresses no signal handler, so there is no path back into Bit code
from it. The rule is load-bearing rather than convenient: the Linux output is
fully static with no libc, so a raw syscall is the *only* way to reach the
kernel, and the allocator and collector — `@nosplit` in their entirety — could
otherwise never obtain a page from the OS.

Anything else is **E0075** `nosplit_calls_allocating`, including composite,
slice and map construction, slice or map indexing (or an array index that is
not provably in range, above), `append`, `spawn`, closures, channel
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

A call to an **`extern fn` (§11.7) is permitted**, and is the *second* and
last construct here admitted on assertion rather than on proof — on exactly the
`asm` footing, for exactly the `asm` reason. The callee's body lives in another
image, so it is opaque to every compiler pass and no proof about it is possible.
`extern fn` is already the unmanaged-subset marker for that boundary
(§11.7 exists solely for the runtime's libSystem path, which is Darwin's
counterpart to Linux's raw `syscall`), so requiring a second marker on the
declaration would gate nothing an author willing to misuse it would not simply
write. There is therefore **no `@nosplit` attribute on an `extern fn`
declaration** — the grammar of §11.7 admits none, and the permission attaches to
the *call site*, which is the smaller surface.

What the compiler emits for such a call *is* proved, and is what the rule rests
on: a plain C-ABI call, with no allocation and no safepoint poll. The boundary
is narrow by construction — §11.7 admits only scalars and raw pointers across
it, so no `string`, slice, map, interface or closure can reach the callee, and
the managed heap is unreachable from the other side except through an address
the author passed deliberately. That residual is the identical one `asm`
already carries, and this site is in fact strictly safer than `asm`: a call is a
**safepoint site** in the stack map whether or not the enclosing function is
`@nosplit` (only the *back-edge* poll is suppressed by the attribute), so the
frame stays walkable at the return address even in the case the assertion covers.

**Argument expressions are still checked**, as an `asm` operand's are: only the
callee's body is taken on trust, and an allocating argument stays E0075.

Without this rule the unmanaged subset would contradict itself a second time, in
the same place as `asm` does. Darwin publishes no stable syscall numbers, so an
`extern` call into libSystem is its *only* route to the kernel (§11.7); the
allocator and the collector are `@nosplit` in their entirety and must be, so
without this a Bit runtime could never map a page on macOS at all.

Safety is transitive by induction rather than by whole-program analysis: each
call site requires only that its own callee is `@nosplit`, and the same rule
holds for that callee in turn. Attributes are collected before any body is
checked, so mutual recursion between `@nosplit` functions is accepted in either
declaration order. Green-thread stacks are fixed-size and guarded (§20), so
`@nosplit` removes only the safepoint poll — there is no stack-growth check.

```
@naked fn two(): int {
  return 2
}

@nosplit fn doubled(x: int): int {
  return x + x
}
```

### 10.4 Method Declarations

```
method_decl = [ "export" ] IDENT [ generic_params ] signature block .
```

A method attaches a named function to a class, declared **in the class
body**, using the reserved receiver `this`:

```
class Point {
  x: f64
  y: f64

  norm(): f64 {
    return sqrt(this.x * this.x + this.y * this.y)
  }
}
```

`this` is typed as the enclosing class; no `fn` keyword and no receiver clause
are written. A method may still declare its own `generic_params`
(`scaled<T>(...)`), independently of any the class itself declares.

- The receiver's type is always the class the method is declared in — methods
  can only be declared for a class in the **same module**, and only by
  writing them inside that class's body. (Prior to 0.2.0, a method could also
  be declared outside the class body with an explicit `fn (recv: Type)
  name()` clause, and that clause could name a type-alias to a class or to a
  primitive. That form is retired; a type-alias VALUE can still call a
  method declared on its underlying class — aliases are transparent, §14.1 —
  but a primitive can no longer have a method at all.)
- Because classes are **reference types** (§13.3), a method mutating a receiver
  field mutates the caller's value; no pointer receiver syntax is needed.
- Methods participate in structural interface satisfaction (§14.3).

**Constructors (`init`).** A class may declare at most one `init`, in the
class body:

```
init_decl = "init" "(" [ params ] ")" [ "!" [ type ] ] block .
```

```
class Account {
  balance: i64

  init(opening: i64)! {
    if (opening < 0) { fail newError("negative opening balance") }
    this.balance = opening
  }
}

let a = Account(500)?
```

- `init` is called through the class's own name: `Account(500)` allocates a
  zero-valued `Account`, runs `init` on it with `this` bound to the new
  value, and yields that value. There is no `new` keyword — allocation is
  already implicit, and `T(...)` is the same construction shape `[]int(n)`
  and every other type conversion already use (§12.9).
- `init` declares no result type of its own; it may only be marked
  **fallible** (`init(...)!` / `init(...)!E`), the same `!`/`!E` shape a
  function's own result carries (§18.2) but written directly after the
  parameter list, since there is no ok type to write one before. A call to a
  fallible `init` is handled like any other fallible call — `?` or `catch`
  at the call site (§18.3).
- One `init` per class; a second is a compile error. Bit has no constructor
  overloading.
- **A class declaring `init` may not be built with a composite literal
  outside its defining module** — see §12.2.

### 10.5 Class Declarations

```
class_decl  = "class" IDENT [ generic_params ] "{" [ member { ( ";" | "," ) member } [ ";" | "," ] ] "}" .
member      = field | method_decl .    (* method_decl, §10.4 *)
field       = [ "export" ] [ "readonly" ] IDENT ":" type .
```

- `struct` is not a keyword (§5.2): the compiler rejects it with `E0102`,
  naming `class`. Pre-0.1.24 code needs only the keyword replaced — nothing
  else about the declaration changes.
- A field marked `export` is visible outside the module; otherwise it is
  module-private (§17.3). The class type itself is exported via the leading
  `export` on the declaration.
- A field marked `readonly` may be assigned only in a composite
  literal (§12.2) or inside the declaring class's own `init` (§10.4); any
  other assignment — including from within the declaring module itself — is
  `E0114`. `readonly` is orthogonal to `export`: an unexported `readonly`
  field is legal and meaningful, and stops even the declaring module from
  reassigning it. `readonly` is **shallow** — it forbids rebinding the field
  itself, never mutating the value it refers to. This is Java's `final` or
  TypeScript's `readonly`: given `class Wrapper { export readonly inner:
  Box }`, `w.inner.x = 1` is unaffected; only `w.inner = otherBox` is
  rejected. `readonly` is a contextual keyword, not reserved (§5.2) — it
  parses as an ordinary identifier everywhere outside the `[export]
  readonly IDENT ":"` field position.
- Fields are ordered; that order is the memory layout order (subject to the
  compiler's alignment padding). A method interleaved between fields does
  not affect this order or count as a field itself.
- Classes are reference types with reference semantics on assignment (§13.3).

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

### 10.7 Trait Declarations

```
trait_decl   = "trait" IDENT "{" { trait_member } "}" .
trait_member = use_stmt | trait_method | trait_field .
use_stmt     = "use" IDENT { "," IDENT } .
trait_method = IDENT [ generic_params ] signature [ block ] .
trait_field  = [ "export" ] IDENT ":" type .    (* no `readonly` — §10.5 is class-only *)
```

A trait declares methods to be **injected into a class at check time** by a
`use` statement in that class's body, and may also declare **fields**,
injected into the using class's own layout and GC pointer map exactly like a
field the class declared itself:

```
trait Damageable {
  hp: i64                                 // FIELD: injected into layout

  hurt(n: i64)                            // REQUIRED: signature, no body
  dead(): bool { return this.hp <= 0 }    // PROVIDED: has a body
}

class Enemy {
  use Damageable
  use Serializable, Poolable              // `use` is its own statement

  name: string
  hurt(n: i64) { this.hp = this.hp - n }  // supplies the required method
}
```

`use` is a statement inside the class body, never mixed into the field list —
`use A, B, x: f64` would give no way to see where the traits end and the fields
begin.

**Field order is deterministic**: the using class's own declared fields
first, then each `use`d trait's fields in `use` order (and, within one trait,
in its own source order, including transitively through that trait's own
`use` of another). This never depends on map or declaration-table iteration
order — two builds of the same source always agree on layout.

**A field name collision is always a compile error**, naming both sources —
trait/trait (two `use`d traits declaring the same field name) or trait/class
(the class itself also declares that name). Unlike a method conflict, there
is **no override**: the class declaring a field of the same name a trait
provides does not silently win, regardless of whether the two types agree.

A trait field whose type is a class has no zero value (§13.4) the same way a
hand-written one does, so it may not be omitted from a composite literal
constructing the using class — `E0083`, exactly as for a declared field.

A trait member is either **required** (a signature with no body — the using
class must supply it itself, or get it from another `use`d trait) or
**provided** (has a body). A provided method's body may use `this` (§10.4's
in-body form) once injected, but is never independently checked as part of the
trait declaration: `this` has no concrete type until a real class injects the
method, so each use site is checked on its own copy.

Injection rules:

- A provided method a using class does not declare itself is copied into that
  class **as if declared there**, with `this` typed as the class and every
  `Self` (below) resolved to it. The injected method participates in structural
  interface satisfaction (§14.3) exactly like a method the class wrote itself.
- If the class **itself** declares a method with the same name, that
  declaration wins silently — there is no `insteadof`/`as` conflict syntax.
- Two `use`d traits (directly, or transitively through a trait's own `use`)
  providing the same method name, with neither overridden by the class itself,
  is a compile error naming both.
- A required method neither supplied by the class nor provided by any `use`d
  trait is a compile error naming the trait and the method.
- A trait may `use` another trait; a cycle is a compile error.
- Injection is compile-time only: no vtable, no subtyping, no runtime dispatch,
  and nothing left over at runtime beyond the injected method's own code.

A trait is **never a type**: it cannot appear as a variable's type, a
parameter, a return type, a field type, a type-assertion target, or a generic
argument. A function needing "anything with these methods" declares a
structural interface (§14.3) instead — a trait supplies method *bodies* to a
class; an interface describes a method *set* a value can be checked against.

**`Self`** is a predeclared type name, legal **only inside a trait body**, and
**only as a parameter or result type** of a trait method — never a local
variable's type, a field type, or anywhere inside an interface. It denotes the
class that ends up `use`ing the trait, resolved once, at injection:

```
trait Buildable {
  withHp(n: i64): Self { this.hp = n; return this }   // fluent chaining
}

trait Comparable {
  equals(other: Self): bool                            // another instance of me
}
```

In `class Enemy { use Buildable }`, `withHp(n: i64): Self` is injected as the
ordinary, concrete `withHp(n: i64): Enemy` — there is no abstract "Self type"
left at runtime. This is a narrower name than the interface `Self` of §11.3:
that one stays abstract until a value is checked against the interface, because
many types may satisfy the same interface; a trait's `Self` is a single
class, fixed the moment `use` names it.

---

## 11. Types

```
type = type_name
     | qual_type_name
     | slice_type
     | array_type
     | map_type
     | tuple_type
     | func_type
     | chan_type
     | generic_inst
     | "(" type ")" .

type_name     = IDENT .                         (* primitive, class, interface, alias, or type param *)
qual_type_name = IDENT "." IDENT .              (* a type exported by a namespace import, §17.2 *)
slice_type   = "[" "]" type .                   (* []T   dynamic, reference *)
array_type   = "[" const_expr "]" type .        (* [N]T  fixed, value *)
const_expr   = expression .                     (* folded at compile time; see below *)
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

`(a, b)` in expression position is a **tuple literal** (§12.10), constructing a
tuple value directly — the third spelling of one representation, alongside this
section's type and §10.1's destructuring pattern. It is not a special case of
parenthesized grouping conditional on its contents: the two forms are
distinguished by the same fixed arity rule as `tuple_type` above, never by what
the parentheses contain. `"(" expression ")"` (§12) stays grouping with any
single expression, including one that itself happens to produce a tuple. A
multi-value `return` (§13.1) remains the other way to build a tuple value;
anything that wants a named, constructible, mutable aggregate still wants a
class.

A `qual_type_name` (`io.Writer`) names a type exported by a namespace-imported
module (`import io from "std/io"`, §17.2) — the same `ns.member` spelling already
used in expression position (`io.stdout()`), extended to type position:

```
import io from "std/io"

fn emit(w: io.Writer) {
  w.writeLine("hi")
}
```

The qualifier must name a bound namespace import, and the member must be a type
**exported** (§17.3) by that module; naming a type that does not exist, or one
that exists but is not exported, is rejected the same way an unexported *value*
import is (`E0046`). A `qual_type_name` cannot itself take generic arguments
(`io.Box<T>` is not valid syntax) — the receiver type of a method (§10.4) and an
interface bound's `constraint` (§11.3) are also unaffected, since both still take
a bare `type_name`, not this production: a method may only be declared on a
locally-declared type regardless, and a generic bound naming an imported
interface is a separate extension this section does not make.

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
  a slice literal (§12.3). Slicing: `s[lo:hi]`. Those are the only two arities:
  the constructor is **not** an element list, so `[]u8()` and
  `[]u8(127, 69, 76, 70)` are both **E0050** rather than an empty slice and a
  127-byte one. Write elements as `[]T{...}` and bytes as `[]byte("...")`.
- **Array** `[N]T`: fixed length `N` (a compile-time constant), value type, copied
  on assignment. Built with an array literal or zero-valued via `let a: [N]T`.
  `N` is a `const_expr`: an integer literal, a module-level `const` of integer
  type, or an expression over those (`[rows * cols]i64`). It is folded at compile
  time; a length that does not fold to a non-negative integer is E0064, and a
  function-local `let` is not a constant however evident its value. Note the
  type-prefixed literal form `[N]T{...}` (§12.3) still requires a literal length,
  because `[x]` there is ambiguous with a one-element slice literal.
- **Map** `map<K,V>`: hash map; reference type; `K` must be a comparable type
  (§14.6). Built with `map<K,V>()`, `map<K,V>(n)` (a capacity hint for about n
  entries, ADVISORY: it never changes the map's contents or behavior, only how
  it is pre-sized — an `n <= 0` is a no-op, not an error), or a map literal.
  Absent keys read as the zero value of `V`; use the two-result index form to
  test presence (§12.6).
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

fn max<T: Ord>(a: T, b: T): T {
  if (a.less(b)) { return b }
  return a
}
```

`Self` is a predeclared type name inside an interface body denoting the concrete
implementing type; it may appear in method signatures only. A trait body has
its own, narrower `Self` (§10.7): the same spelling, but resolved once, at
`use` time, to the single class that names the trait — not left abstract for
every future implementer the way an interface's is.

### 11.4 Raw Pointers (unmanaged subset)

- **Raw pointer** `*T`: a single machine word holding the address of a `T`. It is
  a **reference type** (nilable; its zero value is the null pointer `nil`), but
  unlike every other reference type it is **not traced by the garbage collector** —
  the collector never follows a `*T`, and a `*T`-typed class field or slice
  element is omitted from the object's pointer map. This is what makes it *unsafe*:
  the pointee's lifetime is not tracked, and dereferencing a dangling or
  fabricated pointer is undefined behavior.
- `*T` exists for the **unmanaged subset** — the low-level code (the runtime,
  including the garbage collector's own metadata) that must manage memory it
  deliberately keeps outside the managed heap, so the collector must not walk it.
  It is not needed by, and should be avoided in, ordinary code: slices, maps, and
  classes are the safe, traced references (§11.2).
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
fn addAsm(a: int, b: int): int {
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
or an `extern fn` (§11.7) is for.

### 11.7 External Functions (unmanaged subset)

`extern fn` binds a Bit name to an external symbol resolved at **link
time** from a dynamic library. Like `*T`, the atomics and `asm`, it exists for
the **unmanaged subset** the runtime is written against — on macOS the runtime
must reach the kernel through libSystem, because Apple does not guarantee stable
syscall numbers and reserves the right to renumber them.

```
extern_fn_decl = "extern" "fn" IDENT signature .
```

- `extern` is a **contextual** keyword — an ordinary identifier everywhere else.
  It is unambiguous here because an identifier can never begin a declaration.
- There is **no body**, no receiver, no generic parameters, and no variadic
  parameter (a variadic C function needs per-call ABI classification this path
  does not implement). **E0077** `extern_fn_invalid` otherwise.
- The declaration may be `export`ed like any other, and calls to it type-check
  against the declared signature exactly like a normal function's.

```
extern fn getpid(): i32
extern fn getentropy(buf: *u8, n: i64): i32

fn main() {
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

**macOS binds against a dylib as well as the archive; Linux binds against the
archive alone.** The Mach-O output is a normal dynamically-linked image: its
linker binds a still-undefined global as a libSystem import, so an extern needs
no new linker machinery there. The ELF output is deliberately the opposite: a
fully static binary with no interpreter, no dynamic symbol table and no libc.
There is no load-time resolution at all — but that is not the same as *no
resolution*. The static link already merges the runtime archive (`libbitrt.a`),
and a symbol **defined inside that archive** resolves exactly like any other
cross-module reference, through the same global symbol table and the same
dead-strip reachability the runtime's own calls use.

So the rule is where a symbol may legitimately come from, not the platform:

- Targeting `aarch64-macos`, symbol **defined in the linked `libbitrt.a`** or
  **exported by libSystem**: accepted. Those are the image's two sources — the
  merged archive and the `LC_LOAD_DYLIB` dyld binds at load.
- Targeting `aarch64-macos`, symbol in **neither**: rejected with **E0078**
  `extern_unsupported_target`, naming the symbol. Darwin does not fail such a
  link: it falls through to a libSystem import and the process aborts at dyld
  load instead, far from the declaration that caused it. The compiler therefore
  has to decide it, which is the one thing accepting everything cannot do.
- Targeting a Linux triple, symbol **defined in the linked `libbitrt.a`, or
  defined by this build's own modules under a §11.9 `@symbol` pin**: accepted.
  The archive case resolves statically at link time; the pinned case resolves
  the same way — out of the program's own object, exactly as `bit_main` always
  has — so a static link has something to resolve it against either way.
- Targeting a Linux triple, symbol **absent** from that archive **and unpinned**:
  rejected with **E0078**, naming the symbol. A fully static ELF has nothing to
  resolve it against, so this would otherwise fail deep inside the linker.
- In a build whose archive **cannot be read**: rejected on either platform.
  Membership is undecidable there, and an undecided case must fall back to
  rejection — an accept-on-unknown would convert a compile error into a link
  error or a silent crash.

The admitted libSystem surface is a **table the compiler carries** (both
compilers carry the same one), not a query against the host. It has to be, for
the same reason the whole predicate is decided here: the answer must be a pure
function of the target, so that `--target aarch64-macos` decides identically on
a Linux CI box and on a Mac. macOS itself offers nothing else to consult —
`/usr/lib/libSystem.B.dylib` has not been a file on disk since macOS 11, only a
host-architecture dyld shared cache. A genuinely exported name the table lacks
is a one-line addition to both compilers, and until then it is a compile-time
diagnostic rather than a crash at launch.

The decision is made where the target and the AST are both in hand, after
checking and before lowering; the archive path is a pure function of the target,
so the predicate is decidable exactly where the diagnostic already fired.

**The rule is a property of the link, so an object emit is outside it.** `bit
build --emit-obj` produces a relocatable and performs no link, so it poses no
membership question and E0078 does not apply: every extern is emitted as an
undefined relocation, exactly as §17.6 already says a freestanding object's
cross-module calls are. An object is by definition an incomplete link, and
undefined symbols in one are normal — they are resolved by whatever link later
consumes it, which is the only place the answer exists (an object's future
archive-mates are not knowable at emit time). This is not accept-on-unknown:
nothing is accepted, the question is deferred to the two gates that *do* see a
whole link. The build that links applies the bullets above to the program's own
externs, and a static ELF link that cannot resolve a reference fails outright
rather than producing a binary. An object emit that consulted an archive would
also be circular, since the archive being built is made **of** these objects.

Bit has no arch-conditional compilation, so a program needing a *libc* symbol on
both platforms still uses `extern fn` for Darwin and a raw syscall for
Linux, not one source form. A **runtime** symbol (`bit_rt_*`) is the case this
rule admits: it is present in the archive on every target, so one source form
does work for it.

**An ordinary function's name can collide with this same boundary, from the
other side.** Every top-level declaration in the **root module** keeps its bare
source name as its link-level symbol — `main` stays `main`, and a
single-module build's object is byte-identical to what it would be without
module numbering. Every other module's top-level names carry an `m<id>$`
prefix so two modules' same-named declarations cannot collide in the object's
flat symbol namespace (§17.1); only the root is exempt. A root-module
function's bare name is therefore indistinguishable, at the symbol table, from
an `extern fn`'s own verbatim name or a name the platform C library exports —
and the final link resolves a still-undefined reference to *whichever*
definition it finds, silently binding the runtime's own extern call to the
user's function instead of to the library. This is not always a crash: a root
`fn write` shadowing the runtime's own `extern fn write` used for stdout makes
every `println` print nothing, at exit 0.

**E0096** `root_name_collision` rejects a root-module function whose bare name
matches any symbol the program's linked runtime archive resolves externally —
derived from the archive's own actual undefined-symbol set for the build's
target, never a fixed list of C names, so the check can neither miss a
collision this exact runtime creates nor false-positive on a name that merely
looks like a C function. The check only applies where a link actually happens:
`bit build --emit-obj` performs no link and poses no membership question, the
same carve-out §11.7 makes for E0078 above. This is a **hard error, not a
warning**, and it is the one exception to §5.3's "predeclared names may be
freely shadowed": a predeclared name that also names a linked extern (`close`,
for instance — §16's `close(chan)` is also `runtime/root/darwin/fs.bit`'s
`extern fn close`) may still be shadowed everywhere *except* by a bare
root-module declaration, where E0096 fires instead of the ordinary
`shadows_predeclared` warning (**E0048**, §5.3).

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
  pointer. A slice stores one **8-byte word per element**, except a `[]u8`,
  which is byte-packed — so `ptrOf` on a `[]u8` addresses packed bytes, and
  `ptrOf` on any other element type addresses word-strided ones.

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
fn sysWrite(): int {
  if (hostTarget() == 0) { return 1 }  // x86_64-linux
  return 64                            // aarch64-linux
}

fn writeLine(buf: []int, n: int): int {
  return syscall(sysWrite(), 1, i64(ptrOf(buf)), n)
}
```

### 11.9 Pinned Symbols (unmanaged subset)

The `@symbol("name")` attribute (§10.3.1) pins the exact link-level symbol a
function definition emits, and constrains its signature to the C ABI. It is the
mirror of `extern fn` (§11.7): that one **consumes** an external symbol,
this one **produces** one.

```
export @symbol("bit_rt_alloc")
fn alloc(size: i64): *byte { ... }
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
fn initialContext(entry: *byte): []i64 {
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
   — `string`, `[]T`, `map`, `chan`, a class, an interface, a payload-carrying
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
export fn recordHit(): i64 {
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

### 11.12 Stack-Map Table Bounds (unmanaged subset)

`stackMapsBegin(): *byte` and `stackMapsEnd(): *byte` are the half-open extent
`[begin, end)` of the **stack-map table** the compiler emits (ABI.md §4). Both
take no arguments: a link produces exactly one table, so there is nothing to
select — passing an argument is **E0050**.

```
// The shape a precise root walk needs: the merged table, as bytes.
@nosplit fn stackMapBytes(): int {
  return int(stackMapsEnd()) - int(stackMapsBegin())
}
```

They belong to the **unmanaged subset** for the same reason `entryOf` (§11.10)
does — ordinary code has no use for a table describing its own frames — and they
exist for one consumer: the collector cannot enumerate a thread's roots without
walking this table, and no other expression in the language yields its address.

**Why a builtin rather than a declaration.** These are the only names in the
language that denote a *data* symbol the **linker** defines and no object may
claim. The table is the concatenation of every contributing object's stack-map
atoms, so no single object knows the total and any object that defined the bounds
would collide with its siblings. §11.7's `extern fn` is the wrong tool
twice over: it binds a *function*, and it binds one resolved from a dynamic
library, which is not what a statically linker-defined symbol is. Spelling this
as a builtin keeps the set of names a program can leave undefined closed and
compiler-owned, rather than opening an arbitrary-symbol escape hatch whose typos
become link errors instead of compile errors.

Each call lowers to **one inline address materialization** — the same symbol
relocation `entryOf` and a module-state reference already emit — so like them
both are permitted inside a `@nosplit` function (§10.3.1), on proof rather than
assertion: no load, no call, no allocation, and no safepoint. That permission is
not a convenience. The only caller that can exist is a root walk reached from a
safepoint poll, which is nosplit by construction, so refusing them there would
carve out an operation reachable from nowhere.

The results are raw pointers (§11.4): not traced by the collector, and `int(...)`
converts either to an integer by the ordinary rule. They address a table, not
objects; nothing in the table is a GC reference.

**Guarantees.** `end >= begin` always, and the extent is empty exactly when the
image contains no safepoint at all. Like `entryOf`, each is invariant *within* a
run, and their difference is invariant *across* runs; the absolute values are
stable across runs only for the static ELF output, since the Mach-O output is
position independent and slides.

**A program that never links against the runtime still compiles.** The reference
is emitted as an undefined external and resolved at link, so the failure mode for
a build that somehow omits the table is a link error naming the symbol, not
silent zeroes.

**`debugLinesBegin(): *byte` and `debugLinesEnd(): *byte` (#3285)** are the
identical shape, over a second, independent linker-merged table: the debug-info
line table (ABI.md §4.2) `bit_rt_panic`'s own trace walker symbolizes a return
address against. Same rules throughout — unmanaged subset, zero arity (E0050 on
any argument), `@nosplit`-legal on the identical proof (one relocation, no load,
no call), `end >= begin` always, empty exactly when the image carries no
debug-info entry at all, and a build that omits the table fails at link with the
symbol named, not silently.

---

## 12. Expressions

Precedence, highest to lowest. All binary operators are **left-associative**;
the one exception is the conditional expression at level 2, which is
**right-associative** (below).

| Level | Operators                                   | Kind             |
| ----- | ------------------------------------------- | ---------------- |
| 9     | `f(...)` `a[i]` `a[lo:hi]` `a.b` `x?`        | postfix / primary |
| 8     | `!x` `-x` `+x` `~x` `<-c`                    | unary prefix     |
| 7     | `*` `/` `%` `<<` `>>` `&`                    | multiplicative   |
| 6     | `+` `-` `\|` `^`                             | additive         |
| 5     | `==` `!=` `<` `<=` `>` `>=`                  | comparison       |
| 4     | `&&`                                         | logical and      |
| 3     | `\|\|`                                       | logical or       |
| 2     | `? :` (conditional)                          | ternary, right-assoc |
| 1     | `=>` (arrow function)                        | lowest           |

Assignment is a **statement**, not an expression (§13.2), so `=` never appears
inside an expression. `&&` and `||` short-circuit.

**Conditional expression** `cond ? a : b` (#3941): `cond` must be `bool` — no
truthiness — and `a`/`b` must meet at one type under the untyped-constant rules
of §15.4; the result is that common type. Right-associative, so
`a ? b : c ? d : e` reads `a ? b : (c ? d : e)`, and looser than every binary
operator, so `a || b ? c : d` reads `(a || b) ? c : d`.

The postfix `?` (error propagation, level 9) uses the identical token and
binds tighter, so it is tried first at every position `binary` can end on —
not only at the very end of `cond` as a whole. Nothing at parse time knows
whether an operand is fallible (that is a checker fact, E0116), so a bare,
unparenthesized `cond ? a : b` is disambiguated by a bounded, rolled-back
speculative parse: try `<then> :` from the `?`, and only treat it as
propagation if that fails. `f()? ? a : b` takes the first `?` as propagation
(nothing valid follows it as a `then`) and the second as the conditional's own.

```
expression   = arrow_fn | conditional .         (* catch_expr, §18.3 *)
conditional  = catch_expr [ "?" expression ":" conditional ] .
binary       = unary { binop unary } .          (* shaped by the precedence table *)
binop        = "*" | "/" | "%" | "<<" | ">>" | "&"
             | "+" | "-" | "|" | "^"
             | "==" | "!=" | "<" | "<=" | ">" | ">="
             | "&&" | "||" .
unary        = ( "!" | "-" | "+" | "~" | "<-" ) unary | postfix .
postfix      = primary { call | index | slice | member | type_assert | "?" } .
call         = [ "<" type { "," type } ">" ] "(" [ arguments ] ")" .   (* §12.7 *)
index        = "[" expression "]" .
slice        = "[" [ expression ] ":" [ expression ] "]" .
member       = "." ( IDENT | INT_LIT ) .        (* INT_LIT selects a tuple element *)
type_assert  = "." "(" type ")" .               (* §14.4 *)
arguments    = arg { "," arg } [ "," ] .
arg          = [ "..." ] expression .           (* '...' spreads a slice, §12.4 *)

primary      = literal
             | IDENT
             | "(" expression ")"
             | tuple_lit
             | composite_lit
             | "[" [ arguments ] "]" .           (* bare slice literal, possibly empty *)
```

### 12.1 Literals and Identifiers

An `IDENT` in expression position resolves to a value binding, function, or a type
used as a constructor/converter (§12.9). Literals are as in §5.

### 12.2 Class Composite Literals

```
composite_lit = type_name [ "<" type_args ">" ] "{" [ field_inits ] "}"
              | slice_type   "{" [ arguments ] "}"
              | array_type   "{" [ arguments ] "}"
              | map_type     "{" [ map_entries ] "}" .
field_inits   = field_init { "," field_init } [ "," ] .
field_init    = IDENT [ ( ":" | "=" ) expression ] .       (* keyed; order-independent; bare IDENT is shorthand for IDENT "=" IDENT *)
map_entries   = map_entry { "," map_entry } [ "," ] .
map_entry     = expression ":" expression .
type_args     = type { "," type } .
```

`field_init` accepts both `:` and `=` for one release (#3840): `Point{ x: 1.0 }`
and `Point{ x = 1.0 }` are equivalent, and the two spellings may be freely mixed
within one literal. **`=` is the target spelling** — `:` means "has type", `=`
means "gets value", and `:` here is the one inconsistent use of `:` in the
language. The formatter still emits `:` regardless of which spelling the source
used; existing source is not rewritten by this release. A later release removes
the `:` spelling from the grammar and flips the formatter to emit `=`.
`map_entry` is unaffected and keeps `:` permanently — its left side is a key
*expression*, not a field name, so the "has type" vs. "gets value" distinction
does not apply.

A class literal is **always** prefixed by its type name: `Point{ x: 1.0, y: 2.0 }`.
This is the rule that removes the block-versus-object-literal ambiguity — a bare
`{` in statement position is **always** a block (§13.1), never a class or map
literal. Class literals are keyed; any field omitted from the literal takes its
zero value (§13.4). A field whose own type is a **class** has no zero value and
therefore may **not** be omitted — leaving it out is **E0083**. Fields not visible
to the current module (unexported fields of a foreign class) may not appear.

A `field_init` with no `: expression` is **shorthand**: `Point{ x, y }` means
`Point{ x: x, y: y }` — the field name doubles as the name of a binding already
in scope. Shorthand and keyed fields may be freely mixed in one literal
(`Point{ x, y: 2.0 }`), and field order stays irrelevant either way. There is no
positional form: `Point{ 1.0, 2.0 }` is rejected (a bare number cannot start a
`field_init`), which is what keeps a bare `IDENT` unambiguous — it can only mean
the shorthand, never a position. A shorthand field is two independent things
that can each fail on their own: the field name (`x`) is resolved against the
class's own fields, exactly as the keyed form's key is, and a name the class does
not declare is **E0057**, unaffected by which spelling was used; the implied
value (the second `x`) is resolved as an ordinary identifier reference against
the enclosing scope, and a name with no binding in scope is **E0040 undefined
name** — not a field diagnostic, since the mistake is a missing variable, not a
missing field.

**A class declaring `init` (§10.4) seals its composite literal.** `Point{ x:
1.0, y: 2.0 }` is unaffected — the rule bites only a class that declares a
constructor. `Account{ balance: -500 }` is legal **inside** the module that
declares `Account`, where the literal form is how `init` itself (and any
other code in that module) builds the value; from **any other module** it is
a compile error naming the constructor, `Account(...)`. Without this an
exported `init` would guarantee nothing: every field would stay reachable by
the literal form from anywhere the fields themselves are visible, defeating
the one reason to declare a constructor at all.

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
_tests_/cases/check_array_literal.bit and run_array_value.bit).

**Diagnostic order inside a composite literal is normative** — this is the
general post-order rule of §14.8, spelled out for the literal forms. A literal is
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
_tests_/cases/check_composite_order.bit).

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

`a.b` selects a class field or a method value. `t.0`, `t.1`, … select tuple
elements by index (the index is an `INT_LIT`, checked against the tuple arity).
Method values are closures bound to their receiver.

**Tuple elements are read-only.** `t.0` may be read but never assigned, so `t.0 =
x` (and `t.0++`, `t.0 += x`) is a compile error. A tuple is a fixed group of
values produced whole — by a multi-value `return` (§13.1) — and read whole or by
element; to vary a member, build a new tuple or use a class, which is what
classes are for. This restriction is what lets tuples be a value type (§13.3)
while being represented as a shared box.

### 12.6 Index and Slice

- `s[i]` indexes a slice/array (`i` must be an integer; out-of-range
  **panics**, §18.4) or a string (yielding `byte`). On a fixed-size array
  `[N]T` (§11.2), an `i` that is a compile-time-constant literal is checked at
  compile time instead: an out-of-range literal is a compile error
  (**E0122**) rather than a runtime panic, since it costs nothing to reject
  before the program ever runs. A non-constant `i` still panics at runtime on
  either type, with the identical message and exit code (§18.4) — a slice and
  an array are indistinguishable out-of-range failure modes to a caller.
- `m[k]` indexes a map; a missing key yields the zero value of the value type
  (§13.4) — for a slice, string, or class V that is a usable empty/zero object,
  never a null reference. The
  two-result form `let (v, ok) = m[k]` also reports presence (`ok: bool`). The
  two-result form is only valid as the sole right-hand side of a value declaration
  or assignment.

  A value type with **no zero value** (a class with a class-typed field,
  §13.4) has nothing to yield on a miss, and the two forms differ there:

  - `m[k]` **panics** (§18.4), naming the type. There is no value to return
    and the caller had no way to know, so it fails at the read rather than
    handing back a reference that faults later.
  - `let (v, ok) = m[k]` does **not** panic: `ok` is `false` and `v` must not
    be read. This form exists to ask whether a key is present, and making it
    panic would leave such a map unreadable by any means.

  Every other operation on such a map — insert, `for (k, v) of m`, `delete`,
  `len` — is unaffected, since none of them needs a zero value.
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

**Scope.** Each parameter of an arrow function is a new binding in the arrow's
own scope. The parameter hides any binding of the same name from an enclosing
scope, for the whole body of the arrow:

```bit
const v = "hello"

fn main() {
  let g: (int) => int = (v) => v + 1
  print("${g(1)} ${v}")
}
```

This prints `2 hello`: the arrow's `v` has the type `int`, inferred from `g`'s
parameter type (§15.3), and is a distinct binding from the module-level `v`,
which the call to `g` does not touch.

**Capture.** An arrow function may refer to variables declared in an enclosing
function or block. Those variables are **shared** between the enclosing scope and
every arrow function that refers to them, and they live as long as any of the
three is reachable — the arrow function outliving the frame that declared them is
not a special case:

```bit
fn counter(): () => int {
  let n = 0
  return () => {
    n = n + 1
    return n
  } // one n, shared with the closure
}

fn main() {
  let c = counter()
  print("${c()} ${c()} ${c()}") // 1 2 3
}
```

Sharing runs in both directions and between siblings. A write through one arrow
function is visible to the enclosing scope and to every other arrow function over
the same variable, and a write the enclosing scope makes **after** the arrow
function was created is visible to it:

```bit
fn main() {
  let n = 0
  let peek = () => n
  n = 41
  print("${peek()}") // 41 — not the value at creation
}
```

Capture is not a copy, so §13.3's value/reference split does not apply to it: a
captured `int` is shared exactly as a captured `class` is. A parameter is a local
variable and is captured on the same terms. What each activation captures is its
own variable, so two calls to the same function yield closures over separate
variables.

An arrow function that only **reads** a variable no one writes cannot tell sharing
from copying, so an implementation may represent that case either way.

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
map<string,int>(1000) // empty map, pre-sized for ~1000 entries (advisory hint)
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

### 12.10 Tuple Literals

```
tuple_lit = "(" expression "," expression { "," expression } ")" .   (* at least 2 elements *)
```

A tuple literal `(a, b, ...)` constructs a tuple value directly, element-wise
matching the tuple type `(T1, T2, ...)` of §11: element `i`'s type is element
`i`'s own (defaulted) type under the untyped-constant rules of §15.4, exactly
as a multi-value `return`'s values are typed — or, where the literal is checked
against a declared or expected tuple type (a `let`/`const` annotation, a
`return`, an argument), the corresponding element type instead, so an untyped
element widens to it rather than being compared against its own bare default.

A single parenthesized expression `(x)` is never a tuple: `tuple_type` and
`tuple_pat` both require **two or more** elements (§11), and `tuple_lit` takes
the identical rule — the parser commits to a tuple literal only once a `,`
appears before the matching `)`; with none, `(x)` is ordinary grouping (§12).
This keeps parentheses' meaning fixed by arity alone, never by what the
contents happen to be.

`t.0`, `t.1`, … read a tuple literal's elements exactly as they read any other
tuple value (§12.5) — read-only, like every tuple element. A tuple literal is
otherwise an ordinary expression and may appear anywhere a value is expected:
a `let`/`const` initializer, an argument, a slice/array/map element, a
`return` value, or the right-hand side of a `tuple_pat` destructure (§13.1).

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
scope. Because class/map literals are type-prefixed (§12.2), a leading `{` is
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
spawn_stmt    = "spawn" postfix .                (* postfix must be a call *)
defer_stmt    = "defer" postfix .                (* postfix must be a call *)
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
- A `member` lhs must select a **class field**. A tuple element (`t.0`) is
  read-only (§12.5) and is not a valid assignment target.
- A `switch` with a subject runs the first case one of whose labels **compares
  equal to the subject with `==`** — the operator of §14.6, not an identity test.
  So a `string` label matches by byte contents, a class label field-wise, a
  tuple label element-wise, and a float label with float equality; the subject
  type must be comparable, and every label must be assignable to it. Cases are
  tested in source order and their labels left to right; a label is evaluated only
  if no earlier one matched. A subject-less `switch` instead tests each label as a
  `bool` condition. Unmatched, control goes to `default` if present.
- A `tuple_pat` lhs destructures a tuple-typed right-hand side positionally, or
  reads one of the two-result forms (`m[k]`, `<- c`, `iface.(T)`, §12.6/§16/§14.7).
  Its arity must match: a two-result form binds exactly two names, and a
  tuple-typed rhs binds exactly the tuple's arity. `_` discards an element.

**Iteration (`for_of` / `for_in`).** The two forms share one set of legal
iterables — slice, array, map, and (`for_of` only) `chan<T>` — and differ in
what the binder receives:

| iterable      | `for x of it` binds                     | `for x in it` binds | binder type |
| ------------- | ---------------------------------------- | -------------------- | ----------- |
| `[]T` / `[N]T`| the element                              | the **index**         | `int`       |
| `map<K,V>`    | `(k, v)` pair: key and value             | the **key**           | `K`         |
| `string`      | out of scope for v0.1 (§21)              | **rejected**          | —           |
| `chan<T>`     | the received value, until closed (§16.2) | **rejected**          | —           |
| anything else | **rejected**                             | **rejected**          | —           |

A pair binder over `for_of`'s slice/array row is legal too, not only over a
map: `for (i, x) of xs` binds `i` to the **index** (`int`) and `x` to the
**element** (`T`) — the same two values the row's two single-binder forms give
separately (`for x of xs` the element, `for x in xs` the index), joined into
one binder. This is the `( IDENT | "(" pat "," pat ")" )` alternative in
`for_of`'s own grammar, the same production a map's `(k, v)` pair binder uses.

A single (non-pair) binder over a map is rejected for `for_of` too (§12.6): one
binder cannot say whether it means the key or the value, and neither guess is
recoverable once shipped. `for_in` rejects everything that is not a slice,
array, or map for the same reason in the other direction — there is no index
or key to give a `string`, a `chan<T>` (a stream, not a container, so it has no
keys), or anything else. A `(k, v)` pair binder over `for_in` is rejected too,
and is not even grammatical: Appendix A's `for_in` production takes one
`IDENT`, unlike `for_of`'s `( IDENT | "(" pat "," pat ")" )`.

**Field-pattern binder (#4106).** `for_of`'s binder also accepts a `field_pat`
— `for { a, b, ... } of xs`, legal only when `xs`'s element is a class. Each
name binds a local of the same name to that field's value, the for-of analogue
of composite-literal shorthand's `Point{ x, y }` (§12.2). Order in the pattern
is irrelevant, unlike the positional pair binder above — every name is looked
up by the class's own field name, not by position — and a name the class does
not declare is a compile error, never a parse error and never a silent
`invalid`-typed binding. `field_pat` is never nested: each item is a plain
`IDENT`, not a `pat`.

**Loop-variable scope.** A loop variable a `for` statement itself declares is a
**new variable each iteration**: the `for_c` variables declared by the init clause,
and the `for_of`/`for_in` binders. The first iteration uses the variable the init
clause (or the first binding) declares; each later iteration's variable is declared
before the post clause runs and initialised from the previous iteration's value at
that moment. This is only observable through capture (§12.8), and it is what makes
the common idiom mean what it reads as:

```bit
fn main() {
  let fs = []() => int(0)
  for (let i = 0; i < 3; i = i + 1) {
    fs = append(fs, () => i) // each closure keeps its OWN i
  }
  print("${fs[0]()} ${fs[1]()} ${fs[2]()}") // 0 1 2
}
```

A `while` loop declares nothing, so a variable it counts is **one** variable and
every closure over it shares that one:

```bit
fn main() {
  let gs = []() => int(0)
  let j = 0
  while (j < 3) {
    gs = append(gs, () => j)
    j = j + 1
  }
  print("${gs[0]()} ${gs[1]()} ${gs[2]()}") // 3 3 3
}
```

### 13.2 Assignment vs Declaration

`let`/`const` **declare**; `=` **assigns** to an existing binding or lvalue. There
is no `:=`. Shadowing in an inner scope requires a new `let`/`const`.

### 13.3 Value vs Reference Types

Bit has **no pointers** and no address-of operator. The value/reference split
determines copy semantics and is fixed:

| Category   | Types                                                        | Assignment / arg passing |
| ---------- | ----------------------------------------------------------- | ------------------------ |
| Value      | all numeric, `bool`, `[N]T` arrays, tuples                   | deep copy of the value   |
| Reference  | `string`, `[]T` slices, `map<K,V>`, `class`, `interface`, `chan<T>`, function values | copy of the reference (shared underlying data) |

`string` is a reference type but is deeply immutable, so sharing is unobservable.
The same argument covers tuples from the other side: a tuple is a value type, but
because its elements are read-only (§12.5) an implementation may share one heap
box between copies without that being observable. The reference implementation
does exactly that — see `runtime/ABI.md` §1.1, which also fixes the multi-value
return ABI: `return a, b` builds one boxed tuple and returns a single handle.
Classes are reference types (like TypeScript objects): assigning a class copies
the handle, and mutations through either handle are visible to both. To obtain an
independent copy, define and call a `clone()` method. Zero values of reference
types are given in §13.4: `nil` for a map, channel, function, or interface, and a
live empty value for `string`, `class`, and `[]T`.

Rationale: making classes references removes the need for pointers, `&`/`*`, and
value-vs-pointer receiver rules, which is a large ceremony saving (priority #1)
while keeping the GC model simple.

**A class-typed field may not participate in a cycle of any length**, because a
class has no `nil` (§13.4): such a field can be neither omitted (`E0083`) nor
filled with nothing, so filling one obliges filling one more and the chain never
terminates. `class Node { next: Node }` and the equivalent `A → B → A` and
`P → Q → R → P` are all rejected at the declaration with `E0047`, naming the
cycle. This is not a layout restriction — a class field is a single handle, so
the layout is finite either way — it is that no value of the type can be built.

Break a cycle with any type that has an empty or `nil` state. `Option<T>` is the
idiomatic one and gives the ordinary recursive structures:

```bit
class Node { v: int, next: Option<Node> } // linked list
class Tree { v: int, kids: []Tree }       // slice also terminates
class Trie { next: map<rune, Trie> }      // so does a map
```

A cycle passing through a generic instantiation is not diagnosed here, since
whether it closes depends on the type argument; `E0083` reports it at the
construction site instead.

### 13.4 Zero Values

Every declared binding without an initializer is deterministically zero-valued:

- numeric → `0`; `bool` → `false`; `string` → `""`.
- `[N]T` array → all elements zero-valued; tuple → each element zero-valued.
- `class` → a live instance with each field zero-valued (classes are references,
  so `let p: Point` yields a usable zeroed `Point`, not `nil`) — **provided every
  field has a zero value**. A class type with a **class-typed field** has no
  zero value at all: see below.
- `[]T` slice → the **empty slice**: `len` and `cap` are `0`, `append` allocates,
  iteration yields nothing, and indexing panics (§18.4). A slice cannot be
  compared to `nil` (§14.6), so an empty slice is indistinguishable from the
  `nil` slice Go names, and a zero slice is always usable rather than a header
  that faults on the first `len`.
- map, `chan`, function, interface → `nil`. Reading a `nil` map yields zero
  values; **writing** a `nil` map, or calling a `nil` function, **panics**
  (§18.4); sending on a `nil` channel blocks forever instead (§16.2). Use the
  constructor forms (§12.9) to allocate.
- `enum` (§14.7) → its declaration-order **first** variant, at that variant's
  tag — **provided that variant carries no payload**. An enum whose first
  variant carries a payload has no zero value at all: see below. A no-payload
  enum's first variant is always safe (its tag is a bare word, nothing to
  materialize); a payload-carrying enum's first variant is safe only when that
  one variant itself carries no payload — `enum Shape { Unit, Circle(f64) }`'s
  zero value is `Shape.Unit` even though `Circle` carries one.

Every context that produces a zero value produces the *same* zero value: a
declaration without an initializer, a missing map key (§12.6), a receive from a
closed channel (§16.2), and the ok-value of a failed fallible call (§18.2).

**A class type with a class-typed field has no zero value and cannot be
default-constructed.** Both forms that would ask for one are **E0083**:

```
class Inner { xs: []u32 }
class Outer { a: int, b: Inner }

let o = Outer{ a: 1 }          // E0083 — omits the class-typed `b`
let p: Outer                   // E0083 — no initializer at all
let s = []Outer(2)             // E0083 — `[]T(n)` means n zero values (§12.9)
let q = Outer{ a: 1, b: Inner{} }   // ok; `Inner` has no class-typed field
let e = []Outer(0)             // ok; asks for no zero values at all
```

`[]T(n)` is reported only when `n` is a constant above zero. A run-time `n` is
checked where it is known — the allocation **panics** if it is above zero, and
does nothing if it is zero.

A `map<K,V>` whose `V` has no zero value stays legal, because inserting,
iterating, deleting and `len` never need one. Only a read of a missing key does,
and §12.6 gives the rule: `m[k]` panics, `let (v, ok) = m[k]` does not.

The reason is that a class is a *reference* (§13.3). Zero bits in a class-typed
field is a **null**, not a live instance, so the promise above cannot be kept for
it: reading through such a field would fault, and a field left holding a
plausible-looking address is a false root for the collector. Filling it with a
fresh instance instead is not an option either, because class types may form
reference cycles and the fill would not terminate.

Only a **class-typed** field is affected. Scalars, `string`, slices, maps,
channels, functions and interfaces all have a zero value that is literally zero
bits, and an inline `[N]T` field lives in the class's own storage, so all of
them stay omittable and `let p: Inner` above is still valid.

**An enum whose declaration-order first variant carries a payload has no zero
value, for the same reason a class with a class-typed field does not.** A
payload-carrying enum's variant construction is a boxed, heap-allocated
reference (§14.7); its first variant is the one that would materialize with no
arguments given, and a variant with a payload has none to give. Both forms
that would ask for one are **E0083**, the identical surfaces as the
class-typed-field rule above:

```
enum Option<T> { None, Some(T) }       // the prelude's own declaration (§17.5)
enum Result<T, E> { Ok(T), Err(E) }    // likewise

let a: Option<int>                     // ok; None (tag 0) carries no payload
let b = []Option<int>(2)               // ok; both elements zero to None

let c: Result<int, string>             // E0083 — Ok (tag 0) carries a payload
let d = []Result<int, string>(2)       // E0083 — same reason
class Box { r: Result<int, string> }
let e = Box{}                          // E0083 — omits the payload-first field
```

This is why the prelude declares `Option<T>` as `{ None, Some(T) }` rather than
`{ Some(T), None }`: ordering the empty variant first gives `Option<T>` a real
zero value, which is what makes a self-referential field like `next:
Option<Node>` omittable and lets `Option<T>` serve as §13.3's cycle-breaking
alternative to a bare class-to-class field (a cycle of class-typed fields is
rejected outright, `E0047`). `Result<T, E>` has no such rescue — both `Ok` and
`Err` carry a payload — and correctly has no zero value at all.

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

This section was written for a single-worker runtime, where every interleaving
was sequentially consistent by construction (ABI.md §9). The runtime now
schedules green threads over **N** OS worker threads — real parallelism, not
just concurrency — so two green threads can execute Bit instructions at the
literal same instant, and this section is what keeps a correctly-synchronized
program deterministic anyway.

Bit provides a sequentially-consistent view **only across these
happens-before edges** (mirrors Go's memory model):

1. A `spawn f(...)` statement **happens-before** the spawned function begins
   (§16.1) — `f`'s arguments are fully evaluated on the spawning thread first.
2. A send on a channel **happens-before** the corresponding receive completes
   (§16.2).
3. The close of a channel **happens-before** a receive that observes the
   channel is closed (§16.2).
4. On an **unbuffered** channel, a receive **happens-before** the send
   completes.
5. The `k`-th receive on a channel with capacity `C` happens-before the
   `(k+C)`-th send completes.
6. A `std/sync` `Mutex`/`RWMutex` unlock **happens-before** the next
   successful lock that acquires the same mutex.
7. `std/sync`'s `Once.do(f)` runs `f` at most once; `f` returning
   **happens-before** every `Once.do` call (on any thread, including the one
   that ran `f`) returns.
8. A `std/sync` `WaitGroup`'s final `Done()` call (the one that brings the
   counter to 0) **happens-before** the `Wait()` call it unblocks returns.
9. A `std/sync` atomic **release** operation on a location **happens-before**
   the first **acquire** operation on that location that observes it
   (§13.7.1).

Program order holds within a single green thread, and happens-before is
transitive. Everything else — ordering between two green threads absent one of
the edges above — is exactly what the next paragraph defines.

**Data race.** Two accesses to the same memory location from different green
threads, at least one a write, with no happens-before edge between them, race.
Bit picks a **defined, not undefined**, outcome, because the language stays
memory-safe (GC, bounds-checked, no manual `free`) even when a program is
buggy:

- A racing access to a value that fits in **one machine word** (any integer
  width, `bool`, `f64`, a single pointer/reference, a `chan`/`func` value) is
  guaranteed **not to tear**: every read observes some value some write
  actually stored there, never a fabricated bit pattern. *Which* writer's
  value a racing reader sees is unspecified — that is the race itself, and the
  fix is always one of the edges above, not this guarantee.
- A racing access to a value **wider than one word** — a class assigned as a
  whole, a slice header `{ptr, len, cap}`, a `string` header `{ptr, len}`, an
  interface value `{type, data}`, or a multi-return tuple — **can tear**: a
  reader can observe a mix of words from different writes (e.g. one write's
  `ptr` paired with another write's `len`). A torn ordinary value is a **logic
  bug** (wrong length, wrong bounds-check outcome, a stale-but-well-typed
  field) — Bit's usual safety nets (bounds checks, `nil` checks) still run
  against whatever was actually read, so this alone does not corrupt memory.
- The one exception: if a torn **GC-traced** multiword value (a slice, string,
  interface, or reference-holding class) is what a root scan observes live in
  a stack slot or register at a safepoint (ABI.md §5), the collector trusts
  that slot's declared shape — a `data` pointer paired with a mismatched
  `type` tag from a torn interface, or a `ptr` paired with a mismatched `len`,
  can violate the collector's precision. This is the one way a race in
  otherwise-safe Bit code can reach real memory-unsafety. It is rare (a
  safepoint must land inside the torn window) but real, exactly as in Go, and
  it is why a race on a shared composite value is never "just a data bug to
  shrug off."

Channels and `std/sync` (`Mutex`, `RWMutex`, `WaitGroup`, `Once`, atomics) are
the race-free coordination tools; the raw `*T` pointer and its atomic builtins
(§11.5) are the unmanaged-subset escape hatch and carry their own, stricter
contract (no GC safety net at all). The recommended discipline is unchanged:
*do not communicate by sharing memory; share memory by communicating* — reach
for `std/sync` only for a shared-memory hot path a channel would make
needlessly slow.

**Race-free** (edges 1 and 2/5 above: each worker owns its own state; the only
cross-thread contact is the value it sends):

```
fn worker(id: int, results: chan<int>) {
  results <- id * id
}

fn main() {
  let n = 4
  let results = chan<int>(n)
  for (let i = 0; i < n; i++) {
    spawn worker(i, results)
  }
  let total = 0
  for (let i = 0; i < n; i++) {
    total = total + <- results
  }
  print("total=${total}\n") // deterministic: 0+1+4+9 = 14
}
```

**Racy** (what the race gate flags, not a pattern to copy): two green threads
write `total` with no happens-before edge between the writes themselves —
only their *completion* is ordered, by the unrelated `done` channel, which
does not help:

```
let total = 0

fn bump(done: chan<int>) {
  total = total + 1 // read-modify-write, no edge vs. the other bump()
  done <- 0
}

fn main() {
  let done = chan<int>(0)
  spawn bump(done)
  spawn bump(done)
  <- done
  <- done
  print("total=${total}\n") // races: 2 today, but not guaranteed
}
```

#### 13.7.1 Atomic Orderings (`std/sync`)

`std/sync`'s atomic operations (`Atomic<T>` and the free `Add` /
`CompareAndSwap` / `Load` / `Store` / `Swap` functions) take an explicit
ordering, independent of the raw `*T` builtins in §11.5 (which stay
sequentially consistent only — no weaker mode is exposed there):

- **`SeqCst`** (the default when no ordering is given) — every `SeqCst`
  operation, across every location, is seen in one global total order by every
  thread. Safest, and what to reach for first.
- **`Release`** (store-side) paired with **`Acquire`** (load-side) — a
  `Release` store happens-before every `Acquire` load that observes it (edge 9
  above), without requiring a single global order across unrelated locations.
  This is the publish-through-a-flag pattern: write the payload with plain
  stores, then `Store(flag, 1, Release)`; the reader spins
  `Load(flag, Acquire)` until it observes `1`, only then reads the payload.
- **`Relaxed`** — atomicity only (no torn reads/writes, per the single-word
  guarantee above), no ordering guarantee relative to any other memory access.
  Correct only when nothing else depends on the access's relative order (e.g.
  a counter nobody reads-to-act-on).

Mixing orderings on the same location is allowed (e.g. `Relaxed` increments,
one final `Acquire` load to publish the total) — the guarantee attaches to
each operation, not to the location as a whole.

### 13.8 Match

`match` dispatches on an enum value (§14.7):

```
match_stmt  = "match" "(" expression ")" "{" { match_arm [ "," | ";" ] } "}" .
match_arm   = variant_pat "=>" ( statement | expression )
            | "_" "=>" ( statement | expression ) .
variant_pat = IDENT [ "(" IDENT { "," IDENT } ")" ] .   (* name + payload binders *)
```

The subject expression must be an enum type. Each arm names one of the enum's
variants (bare, unqualified — the subject's type disambiguates) and runs its
body when the value is that variant. A payload variant's arm binds its payload:
`Circle(r) => …` binds `r` to the `f64` inside; the binder count must match the
variant's payload arity. A `match` is:

- **Exhaustive** — every variant of the enum must have an arm, or the arms
  that do not name one are covered by a trailing `_` (below); a missing
  variant with no `_` is a compile error (`E0071`). This is `match`'s central
  guarantee: adding a variant to an enum turns every `match` that forgot it —
  and did not write `_` — into a compile error.
- **Non-overlapping** — a variant may appear in at most one arm (a duplicate is
  a compile error).

Arms do not fall through. `break`/`continue` inside an arm target the enclosing
loop, not the `match`.

**Wildcard arm.** `_` matches any variant the earlier arms did not already
name — the same escape from exhaustiveness `switch`'s `default` gives a
`switch`, for a `match` over a wide enum that only cares about a few variants.
It binds nothing: there is no payload to name, so `_(a, b)` is rejected the
same way any other unknown variant is (`_` can never be a real variant name).
Two rules keep it from weakening exhaustiveness for matches that do not need
it:

- It must be the **last** arm (`E0100`); it cannot be followed by a named
  variant arm.
- It is rejected when it discharges nothing — a `match` that already names
  every variant (`E0101`). Accepting a no-op `_` there would silently disable
  `E0071` for that `match` forever: the next variant added to the enum would
  fall into the redundant `_` instead of raising a diagnostic. `_` trades
  exhaustiveness only for the variants it actually covers, never for free.

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
- both are class types with the same ordered field list (same names, same field
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

- The method set of a class type is the set of methods declared in its body
  (§10.4), in its home module, plus any method injected into it by a `use`
  statement (§10.7) — an injected method is indistinguishable from a declared
  one for this purpose. A type alias has no method set of its own — aliases
  are transparent (§14.1), so a value typed through one satisfies an
  interface exactly as its underlying class would.
- Interfaces may not declare fields; only method signatures.
- `S` must be a **class** type (or another interface, or `nil`). An interface
  value *is* the receiver's object pointer — there is no boxed scalar — so only a
  type that is already a reference (§13.3) can sit behind one. Storing anything
  else would leave a non-pointer in a word the collector traces as a root and a
  type assertion (§14.4) reads as an object header. This is a rule about the
  value's representation, not its method set — though since a scalar can never
  have a method at all (§10.4: methods are declared only in a class body), the
  two rules are never actually in tension for a scalar; the empty interface
  `interface {}` is what isolates the representation rule from a method-set
  check, since every value's (trivially empty) method set satisfies it.
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

Grammar (a `postfix` suffix alongside `call`/`index`/`slice`/`member`, §12):

```
type_assert = "." "(" type ")" .
```

The two-result form is valid only as the sole right-hand side of a declaration or
assignment (like the map/channel two-result forms).

- The target must be a **class** type. Only classes carry methods (§10.4), so
  only a class can be the dynamic type behind an interface value.
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
- String ordering (`<`, `<=`, `>`, `>=`) is **lexicographic on the byte
  contents**, never on the backing address: bytes compare as UNSIGNED values,
  and when one operand is a prefix of the other the shorter one is less. The
  empty string is less than every other string, and a NUL byte is an ordinary
  byte with no terminating meaning. Because Bit strings are UTF-8 (§5.6), this
  byte order is also code-point order.
- Arrays and tuples are comparable if their element types are; classes are
  comparable if all fields are comparable (field-wise).
- A C-like enum (all variants payload-free) compares with `==`/`!=` by tag, and
  may be a map key. A payload-carrying enum is not comparable — use `match`.
- Maps and functions are **not** comparable except against `nil`. A slice is not
  comparable at all, `nil` included: its zero value is the empty slice (§13.4),
  so there is no `nil` slice to distinguish an empty one from.
- Interface values are comparable; two are equal if their dynamic types are
  identical and their dynamic values are equal (panics if the dynamic type is not
  comparable — a documented runtime condition).
- Map keys (`K`) must be a comparable type; a non-comparable key type is a compile
  error.

### 14.7 Enum Types

An enum is a nominal type whose values are one of a fixed, named set of
variants. Its grammar (`enum_decl`/`enum_variant`) is given in §10.6.

```
enum Color { Red, Green, Blue }
let c = Color.Green            // no-payload variant: EnumName.Variant

enum Shape { Circle(f64), Rect(f64, f64), Unit }
let s = Shape.Rect(3.0, 4.0)   // payload variant: construct with arguments
```

- **Nominal identity** (unlike classes/interfaces, §14.1): two enums with the same
  variant names are still distinct types. A bare `Color` is a type, not a value;
  a value is written `Color.Variant`.
- A variant may carry an ordered **payload** (`Circle(f64)`), making the enum a
  tagged union / sum type. A payload variant is constructed by calling it with
  arguments (`Shape.Rect(3.0, 4.0)`); the argument types and count must match the
  declaration. A no-payload variant is written bare (`Shape.Unit`).
- Enum values are consumed by `match` (§13.8), which is exhaustive over the
  variants and binds a variant's payload in its arm. Enums are not ordered and not
  `==`-comparable in v0.1 — use `match`.
- An enum may be **generic** (`enum Option<T> { None, Some(T) }`), monomorphized
  per instantiation like a generic class (§14.1, §15). A construction's type
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

Representation (non-normative): an enum with no payload-carrying variant is a
bare tag word. An enum with any payload-carrying variant is boxed: every
construction of it — including a no-payload variant of that same enum — is one
heap-allocated `{ tag: i64 @0, ... }` object, with payload argument words
stored inline starting at offset 8 (`8 + 8*argc` bytes total); there is no
intermediate payload pointer or second allocation. A no-payload construction is
the same 16-byte shape with the payload word zeroed. See `runtime/ABI.md`
§1.2 for the byte layout.

### 14.8 Diagnostic Order

**The order in which diagnostics are reported is normative.** A conforming
implementation checks a declaration by walking its tree in source order and
emitting each node's own verdict **after** every verdict from that node's
subtree — post-order. Equivalently: a node is judged only once its children have
been judged.

This is not a stylistic choice. A node's verdict generally *depends* on its
children's types — assignability cannot be decided before the type of the value
being assigned is known — so any single recursive checker produces this order
naturally. Fixing it here means an implementation matches by having the right
traversal, not by sorting at the output boundary; sorting would in fact have to
undo the inner-before-outer nesting the rule requires.

Three consequences, each of which has caused the two compilers to diverge:

- A nested type reports **inner-first**. In `map<[]int, map<[]int, int>>` the
  inner key is reported before the outer one; likewise `[2][2]string`.
- A type node embedded in an expression reports **in its source position among
  that expression's other diagnostics**, not hoisted ahead of them. In
  `g(1) + len([2]string{})` the bad argument to `g` is reported first.
- A binding reports its annotation's own diagnostics, then everything nested in
  its initializer, then last its own assignability verdict — the order
  `let w: map<[]int, int> = g(1)` requires.

Order is user-facing, and the two compilers must render byte-identical output,
so this is fixed rather than left to whichever traversal each implementation
happens to use (#1489, #1521; _tests_/cases/check_typenode_order.bit).

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

An unconstrained non-negative integer literal that does not fit in the signed
default (`i64`) — one whose value needs bit 63, e.g. `0xFFFFFFFFFFFFFFFF` or
`18446744073709551615` — takes `u64` instead. A negative literal (`-1`) keeps
the signed default regardless of magnitude.

---

## 16. Concurrency

This section defines `spawn`, channels, and `select`. The ordering guarantees
they provide across threads — and `std/sync`'s — are §13.7's job, not this
section's; read §13.7 for what is and is not safe to share across a `spawn`.

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
  `io.stdout()` in expression position, or `io.Writer` in type position
  (`qual_type_name`, §11).
- `import * as io from "std/io"` is the explicit spelling of the same.
- `import { stdout, writer } from "std/io"` binds the named members directly.
- `import { stdout as out } from "std/io"` renames on import.

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
- A class **field** marked `export` is readable outside the module, and
  writable there too unless it is also marked `readonly` (§10.5); an
  unexported field is module-private (and may not appear in a foreign
  composite literal or be selected outside the module). `readonly` is
  orthogonal to `export` — an unexported `readonly` field still forbids the
  declaring module itself from reassigning it.
- A method is exported by placing `export` before its `fn` keyword (§10.4);
  an exported type may still have unexported methods (they do not contribute to
  satisfaction of an interface used across module boundaries only if the interface
  is also foreign — normally satisfaction is checked where the value is used).
- Unmarked declarations are module-private.

### 17.4 Entry Point

The executable module is the **root module** of a build (the directory passed to
`bit build`). It must declare exactly one function named `main`. Permitted
signatures:

```
fn main() { ... }          // exit code 0 on normal return
fn main(): int { ... }     // returned int is the process exit code
fn main(): ()! { ... }     // a returned error prints to stderr, exit code 1
fn main(): int! { ... }    // on ok the int is the exit code; on error, as above
```

`main` takes no parameters; command-line arguments and environment are read via
the standard library (`std/os`). A non-executable (library) module has no `main`.

These four are the **only** permitted signatures, and the rule is enforced at
check time: a `main` that declares a parameter, or whose result type is anything
but `int` or nothing (with or without `!`), is rejected with **E0085**. Since
`int` is `i64` (§5.3), `main(): i64` is the same declaration as `main(): int`;
`uint`, `i32`, `f64`, `bool` and `string` are not among the permitted forms. The
rule applies to the root module's own `main` only — a method named `main`, a
`main` in a library module, and a `main` whose symbol is pinned elsewhere with
`@symbol` (§11.9) are ordinary functions and are not entry points.

`bit build --emit-obj` (`-c`) stops at a **relocatable object** instead of an
executable. An object is not a program, so it requires no `main` and gets no
entry trampoline; a module without one is built this way. `bit ar <out.a>
<obj...>` bundles such objects into an `ar` archive, using the target's own name
encoding (BSD for Mach-O, GNU/System V for ELF). Neither command reads the
runtime archive, and neither links. An object destined for an archive is
normally emitted `--freestanding` (§17.6).

`bit ar` is how the toolchain builds its own `libbitrt.a`; it is not a
packaging mechanism for user code. Nothing consumes its output today —
`bit build` has no link-input flag and `bit.json` has no field naming an
archive to link — and an `extern fn` (§11.7)/`@symbol` (§11.9) pin would be
needed to call into one even if it did, since every other Bit type is
GC-managed and cannot cross that boundary. `bit add` (§17.7) — source, not a
prebuilt archive — is the supported way to ship or consume Bit code.

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
fn` (§11.7) is.

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
  must not do. Refused, rather than emitted without the descriptor. A
  multi-value `return` is therefore unavailable in a freestanding module:
  §13.1 builds its tuple as a boxed managed record (`runtime/ABI.md` §1.1).
  Return a class, or an encoded scalar, instead.
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

### 17.7 Package Manager

A project's `bit.json` may declare third-party module dependencies alongside
its other project metadata:

```
dependency_map   = '"dependencies"' ':' '{' [ dependency_entry { ',' dependency_entry } ] '}' .
dependency_entry = STRING_LIT ':' STRING_LIT .   (* name : "gitHost/owner/repo@ref" *)
```

Each value is a single string of the form `gitHost/owner/repo@ref` — for
example:

```json
{
  "dependencies": {
    "quicwire": "github.com/byteink/quicwire@^1.4.2",
    "http2util": "github.com/byteink/http2util@main",
    "scratch": "github.com/byteink/scratch@a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2"
  }
}
```

`ref` is exactly one of:

- a **version constraint**, resolved against the target repository's git
  tags — see **Version constraints**, below;
- a branch name (e.g. `main`), resolved to that branch's current tip at
  resolution time; or
- a bare commit SHA (full 40-character hex), resolved to exactly that commit.

**A branch pin is validated once, at resolution time.** Resolving a branch
ref — the second form above — dereferences it to its current tip only during
`bit add` or `bit up`; a subsequent build never repeats that step. `bit.lock`
records only the resolved `commit` (below), never the branch name itself, so
once resolution is over nothing on disk remembers the pin was a branch at
all: `bit build`/`run`/`test`/`check` read that commit and never re-query the
remote, and a branch that has moved since resolution is not reported. A
project that wants a dependency to be reproducible, or its drift checkable,
pins a version constraint or a bare commit SHA instead — either is fully
determined by what `bit.lock` already records.

**Version constraints.** A version constraint names a plain
`MAJOR.MINOR.PATCH` — no `v` prefix — under exactly one of three forms:

```
version    = DIGITS "." DIGITS "." DIGITS .
constraint = version | "^" version | "~" version .
```

- `MAJOR.MINOR.PATCH` (bare) — **exact**: matches that version only.
- `^MAJOR.MINOR.PATCH` — matches every version reachable without a breaking
  change, npm's "caret" rule:
  - `^1.2.3` = `>=1.2.3 <2.0.0`
  - `^0.1.2` = `>=0.1.2 <0.2.0` — below `1.0.0`, MAJOR `0` carries no
    compatibility promise, so caret treats MINOR as the breaking boundary
    instead.
  - `^0.0.3` = `>=0.0.3 <0.0.4` — below `0.1.0`, PATCH carries no
    compatibility promise either, so caret pins to that exact version.
- `~MAJOR.MINOR.PATCH` — matches every version up to (but excluding) the
  next MINOR:
  - `~1.2.3` = `>=1.2.3 <1.3.0`
  - `~0.1.2` = `>=0.1.2 <0.2.0`

  `^0.1.2` and `~0.1.2` are the same range. This is intentional, not a
  transcription error: below `1.0.0`, caret's breaking boundary and tilde's
  MINOR boundary are the same boundary, so the two operators coincide for
  every 0.x MINOR release — they diverge only at `1.0.0` and above. Since
  every Bit package starts at `0.x`, this coincidence is the constraint form
  a reader meets first, not an edge case.

No other operator exists: `>=`, `<`, `*`, `||`, hyphen ranges
(`1.2.3 - 1.4.0`), and every other npm/semver spelling beyond the two above
are rejected at parse time. A dependency names exactly one of the three
forms above; there is no broader range grammar to pick from.

**No `v` prefix.** A version in `bit.json` — bare or under `^`/`~` — is
written as plain semver; the previous `vMAJOR.MINOR.PATCH` form is gone.
`bit add` accepts either spelling on its command line and writes the `v`-less
form into `bit.json`; a `bit.json` containing a `v`-prefixed version is
rejected at parse time, the same as any other malformed constraint.

**Git tag matching.** A version constraint is resolved against the target
repository's git tags: `MAJOR.MINOR.PATCH` matches a tag spelled either
`vMAJOR.MINOR.PATCH` or `MAJOR.MINOR.PATCH` — third-party repositories use
both conventions, so resolution tries both rather than requiring one. If a
repository tags the same version both ways, on different commits,
`vMAJOR.MINOR.PATCH` takes precedence.

**Vanity import resolution.** The leading path of a dependency value
(everything before the final `@ref`) is either a **direct** git host spec or
a **vanity** name. The decision is made on the path's first segment — the
host — and never on how many segments the path has: `bitlang.org/pkg/http`
is three slash-separated segments, exactly the shape of `gitHost/owner/repo`,
so a segment-count rule would misread it as a direct spec and derive
`https://bitlang.org/pkg/http.git`, never performing a vanity lookup.

The first segment is checked against a fixed list of known git hosts:

```
github.com, gitlab.com, codeberg.org, bitbucket.org, git.sr.ht
```

If it is one of these, resolution is **direct** and behaves exactly as
specified above: the path must be `host/owner/repo` (three segments) and the
fetch URL is `https://<host>/<owner>/<repo>.git`. Any other first segment
makes the whole path — not just its first segment — a **vanity** name that
must be looked up. First-party Bit packages are vanity names of the form
`bitlang.org/pkg/<name>`; the `/pkg/` prefix is required because the
generated site already serves `docs`, `examples`, `get-started.html`, and
`install.sh` at the apex, and an unprefixed name would collide with a real
page. For example:

```json
{
  "dependencies": {
    "http": "bitlang.org/pkg/http@^2.0.1"
  }
}
```

**Vanity document format.** Resolving a vanity name `<name>` is a single
HTTPS GET of `https://<name>` (Transport, below, bounds the request). The
response body, served as `text/plain`, is exactly one line:

```
bit-import: <name> git <gitURL>
```

- The literal tokens `bit-import:` and `git`, and `<name>` and `<gitURL>`,
  are separated by exactly one space each.
- `<name>` MUST be byte-for-byte identical to the vanity name that was
  requested; if it is not, resolution fails. This is the whole trust
  boundary — it is what stops `bitlang.org/pkg/http`'s document from also
  claiming `bitlang.org/pkg/json`, and what stops any other host from
  claiming a name it was never asked to resolve.
- `<gitURL>` is an `https://` git remote URL, used exactly as a direct
  spec's derived URL would be — fetched with the same git client, no
  special-casing.
- Any content after `<gitURL>` on the line is one or more additional
  space-separated fields, ignored by this version of the resolver. This is
  the format's sole extension point: a future field is appended after the
  existing ones, and an older compiler still parses the line correctly by
  reading the first three tokens and discarding the rest.
- One such field is defined today: `dir <path>`, naming the subdirectory of
  the fetched repository that is the package's own root — for a package
  that lives in a subfolder of a larger repository rather than at the
  repository's own root (for example, a first-party package living at
  `pkg/<name>/` inside the `bit` compiler repository itself). `<path>` is a
  `/`-separated path relative to the repository root: each segment must be
  non-empty and neither `.` nor `..`, and `<path>` itself must not begin
  with `/`. It is recognized only immediately after `<gitURL>` — the
  literal token `dir` as the fifth space-separated token, followed by a
  sixth holding `<path>` — exactly the shape the extension point already
  guarantees an older compiler skips harmlessly; any further content after
  `<path>` is itself still the unconsumed extension point. A document
  naming no `dir` field resolves the package at the repository root,
  exactly as before this field existed.
- A document that does not start with the literal `bit-import:` token, is
  missing the literal `git` token, has no `<gitURL>`, or names a `dir`
  field whose `<path>` fails the segment rule above, is a resolution
  failure.

**No subpaths in v1.** A vanity name is matched exactly; there is no prefix
rule. `bitlang.org/pkg/http` and `bitlang.org/pkg/http/client` are two
independent names — each must serve its own `bit-import:` document at its
own URL. Resolution never walks up parent path segments looking for a
document that claims to own a longer name.

**Vanity entries in `bit.lock`.** A dependency resolved through this path
records one field beyond `url`/`commit`/`requires` (`bit.lock`, below):
`vanity`, the exact vanity path as written in `bit.json` (without `@ref`).
`url` still records the resolved `<gitURL>` read from the `bit-import:`
document, so the entry is fully self-describing:

```json
{
  "http": {
    "vanity": "bitlang.org/pkg/http",
    "url": "https://github.com/byteink/http.git",
    "commit": "9f8e7d6c5b4a3928170695e4d3c2b1a0f9e8d7c",
    "requires": {}
  }
}
```

A dependency whose `bit-import:` document named a `dir` field records that
field too, as `dir`, so the entry stays self-describing about where inside
the fetched repository the package actually lives:

```json
{
  "toml": {
    "vanity": "bitlang.org/pkg/toml",
    "url": "https://github.com/byteink/bit.git",
    "dir": "pkg/toml",
    "commit": "9f8e7d6c5b4a3928170695e4d3c2b1a0f9e8d7c",
    "requires": {}
  }
}
```

A dependency resolved from a document with no `dir` field omits the `dir`
key entirely, the same "omit rather than write empty" rule `vanity` already
follows for a direct git-host entry.

A direct git-host dependency's entry omits `vanity` entirely. If `bit up`
(or any later resolution of the same vanity name) fetches a `bit-import:`
document whose `<gitURL>` differs from the `url` already recorded in
`bit.lock` for that name, resolution is a **hard error** naming both URLs
(the one already recorded and the newly resolved one) — never a silent
switch to the new URL. Moving a vanity name to a different git remote
requires removing the dependency and re-adding it.

**Transport.** Vanity resolution is HTTPS only:

- Plaintext `http://` is never fetched, whether as the initial request or as
  a redirect target — a redirect whose `Location` scheme is not `https` is a
  hard failure.
- The response body is capped at 4096 bytes; a document exceeding the cap
  before the single line completes is a hard failure, not a truncation.
- The request carries a 5000 ms wall-clock deadline, separate from the
  30000 ms budget used for the subsequent git fetch of the resolved
  `<gitURL>` — a static single-line GET has no reason to share a git
  clone's budget.

**Resolution: one version per package per build.** Bit links with a flat
symbol namespace, so a build resolves each package named anywhere in the
transitive dependency graph — root and every transitive `bit.json`'s
`dependencies` — to exactly **one** version. Two versions of the same
package would define the same symbols twice, which is a duplicate-symbol
failure at link time; Bit never resolves this the way npm does, by nesting a
second copy so both versions coexist — a flat namespace has no place to put
a second copy.

For each package, the resolved version is the one satisfying every
constraint stated against that package anywhere in the graph. A branch name
or a commit SHA is not a version and is never weighed against a version
constraint: a package reachable only through such a ref resolves to exactly
that ref, and every other requirer of the same package must name that
identical ref, or resolution fails as described next.

If no single version satisfies every constraint stated against some
package, resolution is a **hard error** naming that package and every
conflicting requirement — each requiring package together with the
constraint it stated. There is no fallback and no partial resolution: an
unsatisfiable constraint set stops the build.

**`bit.lock`.** Resolution output is written to `bit.lock`, a plain-JSON file
(no comments, no trailing commas — unlike `bit.json`'s JSONC) in the project
root. It is entirely machine-owned: hand edits are not a supported workflow,
and it is fully regenerated on every `bit add`, `bit up`, and `bit remove`.
Per resolved dependency it records:

```json
{
  "quicwire": {
    "url": "https://github.com/byteink/quicwire.git",
    "commit": "9f8e7d6c5b4a3928170695e4d3c2b1a0f9e8d7c",
    "version": "1.7.0",
    "requires": {
      "streambuf": "github.com/byteink/streambuf@^0.9.0"
    }
  }
}
```

- `url` — the git URL the module was fetched from.
- `commit` — the exact resolved commit SHA (a tag or branch ref is dereferenced
  to its commit before being recorded; `bit.lock` never stores a mutable ref).
- `version` — the resolved `MAJOR.MINOR.PATCH`, no `v` prefix, present only
  when the manifest's ref was a version constraint (bare, `^`, or `~`) and
  resolution matched it to a git tag; omitted for a branch pin, a bare commit
  SHA, or a local-path dependency. This is the version resolution actually
  picked, never the constraint string `bit.json` records — a `^1.2.0`
  constraint can resolve to `1.4.7`. Optional: a lock file written before
  this field existed omits the key entirely, reads back as if unresolved, and
  is rewritten unchanged on the next resolution — no error, no forced relock.
- `requires` — that dependency's own transitive requirement list, verbatim
  from its `bit.json`, so resolution can re-run from the lockfile alone
  without re-fetching every transitive dependency's manifest.

**No install-time code execution.** Fetching a dependency reads only its
`bit.json` and source tree. There is no build script, no postinstall hook,
and no field in `bit.json` that names one — a fetched manifest is never
scanned for, or permitted to run, arbitrary code during `add`/`up`/`remove`
or any other resolution step.

### 17.8 Documentation

`bit doc [--json] [--fields] <module-dir>` prints a module's exported surface,
derived from the same export table and inferred signatures the checker builds —
never from a hand-maintained page. The operand must be a **directory**; naming a
single `.bit` file is rejected (`bit doc: not a module: <path>`, exit 1), unlike
`bit build`/`bit run`, which accept the single-file module of §17.1. The module
must resolve and typecheck cleanly before any symbol is printed: exit code is
`0` on success; on failure `bit doc` prints diagnostics to stderr, exactly as
`bit build`/`bit check` do, and prints no symbols at all.

Only **exported** symbols (§17.3) appear — an exported type's unexported methods
are omitted. Symbols are sorted by name, bytewise, in one global order: a
method's name, for both sorting and printing, is `Recv.member`, so it
interleaves with types, functions and consts rather than being grouped under
its receiver.

Each symbol's `kind` is one of `function`, `method`, `const`, `class`, `enum`,
`interface`, `type`. `params` is the symbol's own written generic parameter
list — angle-bracketed, `", "`-separated (`<T>`, `<T, E>`) — or empty when it
declares none; a method's `params` is always empty, since its receiver's own
line already carries the receiver's parameters.

A symbol's **doc comment** is the run of `//` line comments ending immediately
above its declaration: each comment must stand alone on its own source line (a
`/* */` block comment, or a `//` trailing a previous statement's code on that
same line, is never part of the run), and at most one newline may separate a
comment from the next one below it, or from the declaration itself — a blank
line breaks the run, so a comment separated from its declaration by a blank
line is attached to nothing. A symbol with no such run has no doc comment.

**Plain form** (the default) prints one line per symbol, preceded — when the
symbol has a doc comment — by that comment's lines, each printed verbatim
(leading `//` and all) on its own line directly above. A named-type
declaration (`class`/`interface`/`type`) prints `<kind> <name><params>`; an
`enum` instead prints its own variant list, braced —
`enum <name><params> { <variant>, <variant>(<payload>, ...), ... }` — since the
variant list is the type's entire meaning; every other symbol prints
`<kind> <name><params> <type>`:

```
// Option<T> is present (Some) or absent (None).
enum Option<T> { None, Some(T) }
class Point
class Reader
method Reader.readAll () => string
const pi f64
// unwrapOr returns the payload, or `d` when the option is None.
function unwrapOr<T> (Option<T>, T) => T
```

**`--json`** prints a `[ ... ]` array, one object per line, with keys in this
exact order: `name`, `kind`, `params`, `type`, `variants`, `doc`. `variants` is
`[]` for every kind but `enum`, whose own entries carry that variant's `name`
and its `payload` type list (`[]` for a payload-free variant). `doc` is the
symbol's doc comment lines, `"\n"`-joined, or `""` when it has none:

```json
[
  {"name": "Option", "kind": "enum", "params": "<T>", "type": "Option<T>", "variants": [{"name": "Some", "payload": ["T"]}, {"name": "None", "payload": []}], "doc": "// Option<T> is present (Some) or absent (None)."},
  {"name": "Point", "kind": "class", "params": "", "type": "Point", "variants": [], "doc": ""},
  {"name": "unwrapOr", "kind": "function", "params": "<T>", "type": "(Option<T>, T) => T", "variants": [], "doc": "// unwrapOr returns the payload, or `d` when the option is None."}
]
```

`name` never carries the parameter list; it is the bare declared name or
`Recv.member`, with `params` reported as its own key.

**`--fields`** (off by default) additionally reports each exported class's own
fields, in declaration order, as the extra kind `field` with name `Recv.field`
(for example `Point.x`); it changes neither form's shape for a module whose
classes report no fields this way.

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
fn readAll(path: string): string! { ... }        // returns string OR error
fn fetch(u: string): Response ! HttpError { ... } // custom error type E
fn run(): ()! { ... }                             // returns nothing OR error
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
- **Operand must be fallible:** `expr`'s own type must be a fallible `T!E`. `?`
  applied to a non-fallible operand is a compile error naming the operand's
  type, distinct from the enclosing-function requirement above — one rejects
  the context `?` appears in, the other rejects what it is applied to.
- **Handle:** the `catch` expression consumes a fallible value locally:

```
catch_expr = binary [ "catch" ( expression | IDENT block ) ] .
```

  - `expr catch default` — evaluates to the ok value, or to `default` (of type `T`)
    if err. The err value is discarded.
  - `expr catch e { ... }` — binds the err value to `e` in the block; the block
    must either produce a `T` (its final expression) or divert control
    (`return` / `fail` / `panic` / `break` / `continue`). This is the full-handling
    form. **Exception when `T` is `()`** (the operand is void-fallible, `()!`):
    no expression can produce `()` (§11 makes a bare `()` a type only in result
    position), so the block need not end in a value expression — falling off
    the end, including an empty block, already yields `()`, the same way a
    `=> block` arrow body with no value-returning `return` defaults to `()`
    (§12.8). A non-void `T` still requires a value or diverted control.

Example:

```
fn loadConfig(path: string): Config! {
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
a stack trace to stderr (§18.6), and a non-zero exit code. Panics are for
programmer errors and broken invariants, never for expected failures. Sources of
panic:

- index/slice out of range; integer divide-by-zero; signed overflow in debug
  builds (§13.5);
- write to a `nil` map; close of a `nil` channel; send or close on a closed
  channel; call of a `nil` function; type assertion mismatch (single-result
  form);
- explicit `panic(msg)` builtin;
- a failed `assert(cond)` / `assert(cond, msg)` builtin.

There is **no `recover`** in v0.1: panics are fatal by design, keeping control flow
free of hidden unwinding. Recoverable conditions must use the Result model.

A test may still assert that a panic happens, without `recover`. `bit test` (§19)
treats a discovered test named with the `testpanic_` prefix as expected to
panic — a VERDICT modifier on an already-discovered test, not a second
discovery mechanism, so it applies exactly like any other name to any
function `bit test` finds in a `.test.bit` file. It runs a `testpanic_`
function in its own child process the same way as any other test, passes it
when that process exits with the panic status (2), and fails it when the
process returns normally or exits with any other status. This is a
convention owned by the test runner, not a language feature — `panic` itself
is unchanged and `recover` remains absent from the language.

### 18.5 Deferred Cleanup

```
defer close(f)
defer conn.release()
```

`defer call` schedules a call to run when the enclosing **function** returns, by any
path (normal `return`, `fail`, or propagation `?`), in **last-in-first-out** order.
Deferred calls do **not** run on a panic path: a panic (§18.4) aborts the process
immediately, with no unwinding of any kind, deferred or otherwise. Cleanup that
must happen before the process can die — releasing a lock, deleting a temp file —
has to run explicitly, before the call that may panic. Deferred call arguments are
evaluated at the `defer` statement, not at execution time. `defer` gives
deterministic resource release without finalizers on every path that returns.

### 18.6 Caller Location and Stack Traces (#2905)

No mechanism exists in v0.1 for a callee to learn its call site's `file:line`,
and a panic today reports nothing beyond its message. **Decision: v1 will get
caller location and full stack traces from debug info emitted by both object
writers, read back by a runtime stack walk at panic time.** This entry records
the decision and its cost; it does not implement it — parser, checker, IR,
codegen, both object writers, and the runtime walker are all separate,
follow-on tickets, and none of them lands here.

**This reverses a documented v1 position, and says so rather than superseding
it silently.** `runtime/ABI.md` §12 ("Panics") stated, at the time of this
decision, verbatim:
*"There is no `recover` (SPEC.md §18.4) and v1 emits no stack trace — codegen
has made no frame-pointer-chain promise this runtime could walk, and there is
no debug-info format yet to symbolize one if it did."* Both halves of that
sentence are now deliberately becoming false: codegen will make that promise,
and a debug-info format will exist to symbolize a walk with. `runtime/ABI.md`
itself is not edited here — this ticket's own constraints keep it out of
`runtime/` — so that document read as it did until #3286 updated it (§12 now
describes the opt-in `BIT_BACKTRACE=1` walk, #3285/#3820); this entry is what
authorized that update. §18.4 above already claims "a message and a stack
trace to stderr" for every panic; until this decision, that clause named no
reachable implementation and flatly contradicted `runtime/ABI.md`'s own text
at the time. This is what committed to making it true.

**What this costs**, stated up front because choosing this shape over the
narrower ones requires saying so:

- **A debug-info format** (DWARF, or a minimal custom format — left to the
  implementation ticket) and its emission in **both** object writers
  (`emitmacho.bit`, `emitelf.bit`). Bit already carries one bespoke,
  non-strippable section pair for a structurally similar job — `.bit_gc` /
  `__DATA,__bit_gc`, walked via `bit_stack_maps` / `bit_stack_maps_end`
  (`runtime/ABI.md` §4) — the closest existing precedent for a second,
  address-keyed side table, though nothing here mandates reusing that exact
  format.
- **Source-location tracking through IR that does not carry it today.**
  `IrInstr` (`compiler/ir.bit:180-195`) has no span or line field on any of
  its fields. Every instruction's originating source position is discarded
  once lowering emits it (`cn.span` is read only for `fcFail` diagnostics in
  `compiler/lowercall.bit`, e.g. lines 61/72/94, and never stored on the
  `Op.RtCall` it emits for `panic`/`assert`); a debug-info emitter needs that
  position recovered and carried through to codegen.
- **A wider frame-pointer-chain promise from codegen than exists today** —
  not a promise invented from nothing. Codegen already builds a frame-pointer
  chain for the GC's stack-map walker: `runtime/ABI.md` §4 ("Frame chain")
  states *"Both backends establish an identical frame record: `*(fp)` is the
  caller's frame pointer and `*(fp+8)` is the return address."* But that
  promise is not universal today. `#2929`'s `frameless` optimization
  (`compiler/arm64compile.bit:506-525`) elides the frame record entirely for
  any function that makes no call and closes no loop back-edge, and its own
  comment says why that is sound *today*: "this backend's panic path never
  walks a frame chain at all," quoting the `bit_rt_panic` doc comment as it
  then read in `runtime/root/darwin/io.bit` and `runtime/root/linux/io.bit`
  (both since rewritten by #3285/#3820 to describe the `BIT_BACKTRACE=1`
  walk — neither file still carries this text, so no current line citation
  applies): *"No stack trace: codegen makes no frame-pointer-chain
  promise..."*). A frameless leaf can still contain one of §12.1's
  backend-injected, argument-free panics (`bit_rt_panic_div_zero`,
  `bit_rt_panic_nil_call`, `bit_rt_panic_nil_iface`), which are deliberately
  excluded from `hasSafepoints` on that same reasoning. Once a walk exists,
  the reasoning is gone: this decision requires revisiting `#2929` for the
  panic-reachable subset of frameless functions, which is a real codegen
  change, not a no-op.
- **Symbolization that still works on a binary a user has run `strip` on.**
  Nothing in the current release pipeline strips (`dist/release.sh`,
  `tools/build/` invoke no `strip`), so this is a forward design constraint,
  not a fix to an existing gap: like `.bit_gc`, the new debug-info section
  must not be ordinary native symbol-table data, or an end user's own `strip`
  silently blinds the walker with no error and no diagnostic.
- **Handling for inlined frames** — see below.

**The four required questions:**

1. **Across a non-inlined call boundary:** straightforward, and it is exactly
   what the frame-pointer chain already exists to support. When
   `bit_rt_panic` or `bit_rt_assert` runs, the runtime captures the return
   address and frame pointer of the frame that called it — the same
   "snapshot" shape `bit_rt_safepoint` already uses (`runtime/ABI.md` §4,
   "Snapshot") — then steps `*(fp)` / `*(fp+8)` outward, converting each
   return address to a `file:line` through the debug-info table, exactly as
   the stack-map walker already converts a `pc` to a function's code range.
   The walk ends where §4's already does: "`pc` leaving every function's
   range ends the Bit portion of the stack."
2. **Through two levels of helper:** this is where a stack walk is strictly
   better than every rejected alternative. The trace names every physical
   frame from the panic site outward — the failing assertion, the helper
   that called it, the helper that called that, the test function, on to
   `main` — with **no per-function annotation required anywhere in the
   chain**. An implicit-parameter shape (`@caller_location`, rejected below)
   only reaches as far as whichever function is explicitly marked; an
   unmarked intermediate helper reports itself as the "caller" instead of
   forwarding its own caller — the exact failure mode Rust's
   `#[track_caller]` has, which is why Rust requires re-annotating every hop
   to keep working through helpers. This design has no such failure mode: a
   walk needs no per-function opt-in at all.
3. **Check time versus runtime:** **runtime only.** There is no
   constant-folded location anywhere in this design — the compiler cannot
   know, at check time, which call chain will be live when a given function
   panics, since the same function can be reached from many call sites. This
   is a real difference from the rejected `@caller_location` shape, which
   resolves per call site and could have been baked into the call as a
   compile-time literal. Do not assume this decision gives that; it does
   not. A Bit stack trace's contents are only knowable by running the
   program to the point of failure.
4. **Frozen ABI signatures: unchanged — confirmed by reading, not assumed.**
   `bit_rt_panic(msg: *const RtBytes) -> noreturn` and
   `bit_rt_assert(cond: bool, msg: *const RtBytes) -> void`
   (`runtime/ABI.md` §12, table entries and detail rows; both `@nosplit` —
   `runtime/root/darwin/io.bit:283,291`, `runtime/root/linux/io.bit:325,333`)
   take no location parameter today and need none under this design: the
   walk starts from the panic call's own frame, discovered by the runtime
   from the stack it is already standing on when it runs, not passed in as
   an argument. **This is not an ABI change.** If a future implementation
   ticket ever needs to widen either signature after all, that is the moment
   to say so explicitly in `runtime/ABI.md`, per that document's own rule
   that a frozen signature never changes silently.

**Inlined frames — the question this decision creates and must answer.**
`maxInlineDepth()` is 2 and splicing is recursive (`compiler/optinline.bit:10-44`,
#3163): level 1 splices the callee's body whole into the caller; level 2
splices a call already inside that spliced body the same way. A call the
source shows as two or three frames deep can exist as **one** physical frame
at runtime, because the optimizer flattened it before codegen ever built a
frame for it. A stack walk can only report frames that physically exist —
**an inlined call contributes no frame of its own to the trace**, the same way
an inlined function contributes no frame to a walked C stack trace. That is
not a defect; it is what "the emitted code" means. What this decision commits
to: the trace's *innermost* entry must still report the correct source
`file:line` for the instruction that actually panicked, even when that
instruction originated inside a callee whose call was inlined away — which
requires the debug-info emitter to retain each spliced instruction's
**original** source span rather than relabeling it with the splice site's
span, a distinction that does not exist yet (`IrInstr` carries no span at all,
spliced or otherwise — see cost above). Getting the leaf line right and
getting one frame per syntactic call are different guarantees; this decision
commits to the first and explicitly not to the second. A trace can therefore
be shorter than the source's call nesting suggests, with nothing in the trace
itself distinguishing "inlined away" from "never a separate call" — whether to
add such a marker is left to the implementation ticket.

**Rejected alternatives, and why:**

- **A `@caller_location`-style implicit parameter** (Rust's `#[track_caller]`
  shape). This needs less new machinery than the chosen shape — a parser
  attribute, a checker rule (§10.3.1, Function Attributes), and lowering to
  thread one implicit argument per attributed call — but it only ever reports
  the immediate, explicitly marked caller (point 2 above), it requires every
  function on a reporting path to opt in, and it would have served
  `std/testing` alone rather than also giving every Bit program real stack
  traces on any panic. The owner was shown both shapes and their costs and
  chose the general one on purpose.
- **A predeclared `__LINE__`/`__FILE__`-style identifier.** §5.3's
  predeclared-identifier list is exhaustive (the primitive types, the
  `true`/`false`/`nil` literals, the builtin functions, `parseFloat`) and
  names nothing of the kind. There is no slot in the language for a token
  whose value depends on where it is written, and even if there were, it
  would report only its *own* location, not a caller's — it does not solve
  this problem even in principle.
- **Default arguments evaluated at the call site**, plus predeclared `file`/
  `line` defaults (how Swift's `#file`/`#line` parameter defaults work). Bit
  has **no default-argument feature at all**: §10.3's function-declaration
  grammar (`param = [ "..." ] IDENT ":" type .`) has no default-value
  production for any parameter, of any type. This route does not exist even
  in principle without first shipping default arguments as their own,
  unrelated, larger language feature — layering a whole feature onto the
  back of one diagnostics fix was rejected as disproportionate.
- **Passing a location down explicitly**, as an ordinary string argument. The
  only option available to a library today with no compiler change at all,
  and it fails on its own terms: with no `__LINE__` equivalent the caller
  must hand-type `"foo_test.bit:11"`, and nothing enforces that the literal
  matches the call site — it is wrong the moment a line moves. A confidently
  wrong `file:line` is worse than today's honest absence of one, so this was
  never a candidate worth shipping.
- **Wontfix for v1.** Rejected: the owner explicitly preferred the general
  mechanism over declaring this permanently out of scope. `std/testing`
  assertion failures staying unlocatable, and every Bit panic staying
  trace-free indefinitely, was judged an unacceptable permanent gap once a
  real, general fix was on the table.

**Consequence for #2252 and #2266.** Both stay blocked — this entry lands the
decision, not the mechanism — but the shape of their eventual fix changes.
Under the rejected `@caller_location` shape, `std/testing` would have received
a location as an ordinary parameter threaded through its assertion helpers.
Under this decision it instead asks the runtime for a trace once the walk and
its symbolization exist. Whoever implements those tickets must build the
runtime-trace consumer, not the parameter-passing version either ticket was
filed expecting.

### 18.6.1 Debug-info format: decision (#3281)

**Decision: a bespoke, non-strippable, address-keyed side table — not
DWARF.** Wire format: `runtime/ABI.md` §4.2. This entry is the *why*; it does
not repeat the *what* ABI.md already states precisely enough for two
independent object-writer implementations (`emitmacho.bit`, `emitelf.bit`) to
converge without re-deciding anything.

**The disqualifying constraint, confirmed rather than assumed.** Epic #1905:
*"a static Bit binary with no libc must symbolize its own panic ... no
external debugger, no external symbolization tool."* A DWARF
`.debug_info`/`.debug_line` pair is, by definition and by every shipping
`strip`'s default behavior, debug metadata: macOS `strip` and GNU/LLVM
`strip` both specifically recognize and remove `__DWARF`/`.debug_*` sections
with no flag telling them to. Choosing DWARF for the table `bit_rt_panic`
itself must read means the one constraint the epic states as
**non-negotiable** — surviving an end user's own `strip` — fails on the most
ordinary invocation of that tool. This is not a matter of emitting DWARF
carefully; it is disqualified by what the format *is*.

**Verified, not merely argued: the bespoke shape already in this tree
survives this way, for a reason worth stating precisely.** `.bit_gc`
(`runtime/ABI.md` §4) is the existing precedent, and inspecting a real linked
binary shows *why* it survives `strip` — the mechanism is stronger than "it
isn't named a debug section":

```
$ otool -l bit-out/bin/bit | grep -c sectname
6                    # __text __stubs __const __got __data __bss — no __bit_gc
$ otool -l bit-out/bin/bit | grep -A5 LC_SYMTAB
     cmd LC_SYMTAB
   nsyms 49           # every one an undefined libc import (open, write, ...)
```

Bit's own final linker (`compiler/strip.bit`) resolves every internal
cross-reference — including `bit_stack_maps` itself — to a concrete address
at link time and writes **no symbol-table entry at all** for any internally
defined name; the 49 entries in the shipped compiler's own `LC_SYMTAB` are
exactly the libc imports dyld must still bind. `.bit_gc`'s bytes end up
folded into ordinary `__data`, indistinguishable from any other global's
storage, with nothing named `bit_stack_maps` for a generic `strip` invocation
to find. A section a stripper cannot even locate cannot be a target of its
default behavior — a structural consequence of how Bit links, not a naming
convention this decision has to invent and hope holds. Reproduced identically
against a `bit build`-compiled program (`examples/staticserver`), not just
the compiler's own binary. The new debug-info table gets this survival
property for free by using the identical mechanism (ABI.md §4.2): a second
per-function side table referenced only by two extent symbols the runtime
resolves internally, never surfaced to anything an external `strip`
recognizes as debug data.

**A related finding, filed separately rather than assumed away here
(#3387):** the epic's second acceptance criterion — *"`sample <pid>` ...
resolves frames to function names instead of raw offsets"* — is **not
achievable by picking a debug-info format at all**, bespoke or DWARF, while
the final linker emits zero local symbol-table entries (measured above:
`nsyms 49`, all undefined). `sample`/`atos`/most profilers resolve a
function's *name* primarily from `nlist` entries; DWARF's own DIEs can
substitute in principle (a stripped-binary-plus-dSYM workflow works precisely
because DWARF is address-range-keyed, not `nlist`-keyed), but nothing in this
tree emits a DIE tree either, and whether `sample` specifically falls back to
embedded DWARF with no `nlist` present was not tested here — #3387 owns
settling it. Either way this is a **linker gap**, independent of and prior to
this decision; the panic-trace mechanism this ticket specifies does not
depend on it and is not blocked by it.

**Measured size, against the real precedent, not asserted.** `.bit_gc` in the
current `libbitrt-aarch64-macos.a` (`580c65e8`):

```
23 of the archive's object files carry a __bit_gc section
total __bit_gc bytes:  59,384   (archive: 505,760 bytes -> 11.7%)
total __text bytes (same 23 objects): 319,012   (.bit_gc / __text = 18.6%)
824 __bitsm_ (one per function) local symbols across those objects
```

`bit-out/bin/bit`'s whole `__text` is 4,406,220 bytes. Extrapolating the
runtime's own per-function averages (387 bytes code, 72 bytes stack-map data
per function) to the whole binary gives roughly **11,400 functions**. The
debug-info table's per-function cost is 24 bytes of header (16 originally;
#3662 added an 8-byte per-entry function-name field) plus 16 bytes per
line-table row (ABI.md §4.2); **the row count per function cannot be
measured before #3283 exists** — there is no emitter to measure — so what
follows is stated as an estimate, not a fact: at an assumed 8 rows/function
(a function of the compiler's own average size, ~387 bytes, touching perhaps
8-15 distinct source lines), the table costs roughly 152 bytes/function,
**~1.7 MB total, ~26% of the current 6.5 MB dev binary**. #3283 should
replace the 8-rows assumption with a measured figure the first time a real
emitter exists, and revise this number rather than repeat it.

**DWARF's cost, measured rather than remembered**, via `clang -g
-gline-tables-only` (the closest DWARF mode to what this table carries — no
type DIEs, no variable locations) against two synthetic `.c` files standing in
for small and Bit-average-sized functions respectively (no DWARF emitter
exists in Bit to measure directly):

| functions | avg size | `__text` | line-tables-only DWARF | of which `__debug_line` alone |
|---|---|---|---|---|
| 2000 tiny | 26 B | 51,892 B | 121,166 B (**233%**) | 30,084 B (58%) |
| 300 larger | 232 B | 69,600 B | 37,368 B (**54%**) | 23,484 B (34%) |

Even in `-gline-tables-only` mode — the leanest DWARF gets — 20-38% of that
overhead is `__debug_info`/`__debug_str`/`__debug_str_offs`/`__debug_addr`/
`__debug_names`: DIE trees and a name index the runtime walker has no use for
at all, since it only ever asks "what file:line is this address," never
"list every function." A full `-g` build (types, variable locations) on the
same tiny-function file balloons to **425%** of `__text`. The bespoke table's
16-bytes/row is less compact than DWARF's delta-encoded opcode stream, but it
carries none of DWARF's indexing/naming infrastructure and needs no decoder
loop beyond fixed-offset reads — the trade this decision makes explicitly:
give up DWARF's per-row density and its free `lldb`/`gdb`/external-tool
support, in exchange for a format the panic path can read with zero
allocation and that survives `strip` structurally rather than by convention.

**Rejected: DWARF as the primary (or only) format.** Disqualified above by
the strip-survival constraint alone; the ecosystem cost (no `lldb`, no `gdb`,
no third-party profiler support) is accepted as the price, not hidden.

**Rejected, for now: emit DWARF *in addition*, as a separate opt-in output
for external tools** — the "third shape" this ticket was asked to weigh
rather than assume away. Not disqualified in principle: DWARF's address-range
keying means it does not need `nlist` either, so it is not blocked by #3387
the way `sample`'s current failure mode is. Rejected from *this* ticket's
scope because it is a materially different, larger feature: a `.debug_line`
state-machine encoder, DIE emission, and a decision on whether it ships
inside the binary (reintroducing the exact strip hazard this decision exists
to avoid) or as a separate artifact (a dSYM-equivalent bundle, with its own
distribution and `dist/release.sh` questions). Filing it as future work
rather than deciding it here keeps this ticket's deliverable to what #1905
actually requires: self-symbolization with no external tool. Whoever picks
this up next should file it as its own ticket against #1905, not fold it
into #3283.

**Rejected: reusing `.bit_gc` itself rather than a second table.** Considered
because it is the existing precedent and avoids a second section entirely.
Rejected because the two tables answer different questions at different
granularity (stack maps: per-safepoint register/slot liveness; line table:
potentially several rows per function, keyed finer than any safepoint) and
because independence is a real property worth keeping: a debug-info entry
must carry an *inlined* callee's original span on rows spliced into a
caller's list (below), which the stack-map table has no reason to ever do to
its own per-safepoint entries. Coupling the two would make a future change to
either format's cost model — retention, alignment, or a #3189-style version
stamp — a change to both.

**Inlined frames: this ticket does not reopen §18.6's decision above, and
confirms the format satisfies it.** §18.6 already committed to *one physical
frame, correct leaf `file:line`, not one frame per syntactic call* — an
inlined call contributes no frame of its own, but the innermost row must
still name the original callee's file and line. This format satisfies that
by construction: each row's `(file_hdr_ptr, line)` is independent per `pc`
range, so a splice that flattens a callee's body into its caller's code can
still carry the callee's *original* source position on the rows that came
from it, provided #3282 keeps that original span on the spliced `IrInstr`
rather than relabeling it to the splice site (§18.6's own stated requirement
on that ticket). Nothing here asks for a synthesized "logical" frame, and
nothing here needs one.

**Why not defer the whole decision.** A hedge here (leave DWARF-vs-bespoke
open, let #3283 pick) is exactly the failure mode this ticket's acceptance
guards against: #3283, #3284, and #3285 all need the same answer to converge
independently, and "TBD" would mean the first implementer re-litigates this
research under a code-review deadline instead of a design one.

---

## 19. Testing

A **test** is a `test "name" { ... }` declaration in a file named
`<name>.test.bit`. `test` is a *contextual* keyword (§5.2, like `extern` and
`readonly`): it lexes as an ordinary identifier and is recognized as a
declaration only in the exact position `IDENT("test") STRING '{'` at the top
level of a module, so it introduces no new reserved word and costs no
existing identifier named `test`.

```
test "addition" {
  assert(1 + 1 == 2)
}

test "concat" {
  assert("ab" + "c" == "abc", "string concat")
}
```

- No parameters, no return type, no receiver, no generics — the grammar admits
  none of them. A test's body is an ordinary statement list and may call any
  function in its module, including a private one declared in a sibling file:
  a module's files are simply its `*.bit` entries concatenated in one flat
  scope (§14.8), so a `.test.bit` file sits in the same module as the code it
  tests and needs no import to reach it.
- The declaration's STRING is its name, shown by `ok`/`FAIL` lines and matched
  by `--run`'s substring filter (below) — never an identifier, so it may
  contain spaces, punctuation, anything a string literal can hold.
- `test "..." { }` outside a `.test.bit` file is E0115: "'test' declarations
  are only allowed in a '.test.bit' file", reported on the declaration's head.
- **`test "name" { }` is the ONLY discovery shape.** A bare top-level
  function — no parameters, no return type — inside a `.test.bit` file is
  E0117: "a bare 'fn' with no parameters and no return type is not allowed
  in a '.test.bit' file", reported on the declaration's head, with a hint to
  write a `test "..." { }` declaration instead. A differently-shaped
  function (one that takes a parameter, or returns a value) is an ordinary
  helper, not an error — it is excluded by its shape, exactly as before.
  `main` is excluded from E0117 regardless of shape: `bit test` renames
  whatever `main` it finds before synthesizing its own entry point (§17.4),
  so a user's `fn main(){}` in a `.test.bit` file is an ordinary function,
  never flagged. A `test` declaration can never collide with `main` — its
  own name is a string, never a symbol. (A shape-based legacy form —
  discovered with no `test` keyword at all — existed here from #3786 until
  #4148 removed it; this file no longer describes that form because it no
  longer exists.)
- Tests live in one of two places: beside the file they test, as
  `<name>.test.bit`, or grouped under a `_tests_/` subdirectory for
  black-box tests that exercise only a module's exported surface. A
  `_tests_/` directory is an ordinary directory — its `*.bit` files form
  their own module and reach the parent's exported names through an
  ordinary relative import, `import { publicName } from "../"`.
- A plain `.bit` file is never scanned for tests, wherever it sits — including
  inside a `_tests_/` directory. Helper code that is not itself a test (a fake
  server, fixture builders) belongs in a plain `.bit` file there and is never
  mistaken for a test regardless of its own functions' shapes.
- `bit test <file.bit|dir>` discovers every test in the module a file names,
  or in every module beneath a directory — never in a module reached only by
  importing it from outside that directory. It runs each, prints `ok`/`FAIL`
  per test (by its string name) plus a summary, and exits `0` iff every test
  passed, `1` otherwise. `--run <pattern>` narrows the run to tests whose name
  contains `pattern` as a literal substring; a pattern that matches nothing is
  an error, not a silent zero-test pass.
- A test fails when it panics — which a failed `assert` (§18.4) does. Each test
  therefore runs in its own process, so one failure neither hides the others nor
  aborts the run.
- **No `t.Run(name, fn)` subtest form is provided, deliberately.** Subtests
  share their parent's process by construction, so one subtest's panic would
  end its siblings — trading away the one-process-per-test guarantee above.
  The benefit subtests are usually reached for, naming the failing row of a
  table-driven test, is delivered instead by the `label` parameter every
  `std/testing` assertion requires (`stdlib/testing/testing.bit`): it is a
  positional, non-optional parameter — §10.3's `param = [ "..." ] IDENT ":"
  type .` grammar has no default-value production for any parameter — so the
  row a failure came from can never go unnamed.
- Tests are ordinary unreferenced declarations to `bit build`/`bit run`, so the
  linker's dead-strip drops them from a normal program's binary — every
  test or test-shaped function in a `.test.bit` file, whichever form it uses.
- Test execution order is the order of declaration, both forms interleaved
  exactly as written; tests must not depend on it.

Richer assertions with value diffs live in `std/testing`, layered on this runner.

---

## 20. Worked Example

A complete, conforming program exercising the major features:

```
import { readFile } from "std/fs"
import { parseInt } from "std/strings"

interface Shape { area(): f64 }

class Circle {
  export r: f64
  area(): f64 { return 3.14159265358979 * this.r * this.r }
}
class Rect {
  export w: f64
  export h: f64
  area(): f64 { return this.w * this.h }
}

// Generic: works for any Shape (structural satisfaction).
fn totalArea<T: Shape>(shapes: []T): f64 {
  let sum = 0.0
  for s of shapes {
    sum += s.area()
  }
  return sum
}

// Fallible: parse an f64 count from a file, default to a computed value on error.
fn loadCount(path: string): int! {
  let text = readFile(path)? // propagate fs errors
  return parseInt(text)?     // propagate parse errors
}

// Concurrency: fan work out to green threads, collect over a channel.
fn sumSquares(n: int): int {
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

fn worker(x: int, out: chan<int>) {
  out <- x * x
}

fn main(): ()! {
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
- Weaker memory orderings on the raw `*T` unmanaged-subset atomics (§11.5) — a
  seq-cst-only surface ships there; `std/sync`'s `Atomic<T>` (§13.7.1) is
  where `Relaxed`/`Release`/`Acquire` live instead. `std/sync` itself
  (`Mutex`, `RWMutex`, `WaitGroup`, `Once`) is no longer reserved — see §13.7.
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
              | [ "export" ] class_decl
              | [ "export" ] interface_decl
              | [ "export" ] trait_decl
              | [ "export" ] enum_decl
              | [ "export" ] type_alias
              | [ "export" ] extern_fn_decl .

import_decl   = "import" import_body "from" STRING_LIT .
import_body   = IDENT | "*" "as" IDENT
              | "{" import_item { "," import_item } [ "," ] "}" .
import_item   = IDENT [ "as" IDENT ] .

value_decl    = ( "let" | "const" ) binding { "," binding } .
binding       = ( IDENT | tuple_pat ) [ ":" type ] [ "=" expression ] .
tuple_pat     = "(" pat { "," pat } ")" .
pat           = IDENT | "_" | tuple_pat .

type_alias    = "type" IDENT [ generic_params ] "=" type .

func_decl     = [ attr_list ] "fn" IDENT [ generic_params ] signature block .
attr_list     = attr { attr } .
attr          = "@" IDENT [ "(" STRING_LIT ")" ] .
signature     = "(" [ params ] ")" [ ":" result_type ] .
params        = param { "," param } [ "," ] .
param         = [ "..." ] IDENT ":" type .
extern_fn_decl = "extern" "fn" IDENT signature .

class_decl    = "class" IDENT [ generic_params ] "{" [ member { fsep member } [ fsep ] ] "}" .
member        = field | method_decl .
field         = [ "export" ] [ "readonly" ] IDENT ":" type .
method_decl   = [ "export" ] IDENT [ generic_params ] signature block .
interface_decl= "interface" IDENT [ generic_params ] "{" [ method_sig { fsep method_sig } [ fsep ] ] "}" .
method_sig    = IDENT signature .
fsep          = ";" | "," .
trait_decl    = "trait" IDENT "{" { trait_member } "}" .
trait_member  = use_stmt | trait_method | trait_field .
use_stmt      = "use" IDENT { "," IDENT } .
trait_method  = IDENT [ generic_params ] signature [ block ] .
trait_field   = [ "export" ] IDENT ":" type .
enum_decl     = "enum" IDENT [ generic_params ] "{" [ enum_variant { fsep enum_variant } [ fsep ] ] "}" .
enum_variant  = IDENT [ "(" type { "," type } ")" ] .

generic_params= "<" generic_param { "," generic_param } ">" .
generic_param = IDENT [ ":" constraint ] .
constraint    = type_name { "&" type_name } .

type          = type_name | qual_type_name | slice_type | array_type | map_type
              | tuple_type | func_type | chan_type | generic_inst | "(" type ")" .
type_name     = IDENT .
qual_type_name = IDENT "." IDENT .
slice_type    = "[" "]" type .
array_type    = "[" const_expr "]" type .
const_expr    = expression .
map_type      = "map" "<" type "," type ">" .
tuple_type    = "(" type "," type { "," type } ")" .
func_type     = "(" [ type { "," type } ] ")" "=>" result_type .
chan_type     = "chan" "<" type ">" .
generic_inst  = IDENT "<" type { "," type } ">" .
result_type   = type [ "!" [ type ] ] .

block         = "{" { statement ";" } "}" .
statement     = value_decl | assign_stmt | inc_dec_stmt | expr_stmt
              | if_stmt | for_stmt | while_stmt | switch_stmt | match_stmt
              | select_stmt | return_stmt | fail_stmt | break_stmt
              | continue_stmt | spawn_stmt | defer_stmt | send_stmt | block
              | ";" .

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
for_of        = ( IDENT | "(" pat "," pat ")" | field_pat ) "of" expression .
for_in        = IDENT "in" expression .
field_pat     = "{" IDENT { "," IDENT } "}" .   (* for-of field-name binder; §12.6 *)
switch_stmt   = "switch" [ "(" expression ")" ] "{" { switch_case } "}" .
switch_case   = "case" expression { "," expression } ":" { statement ";" }
              | "default" ":" { statement ";" } .
match_stmt    = "match" "(" expression ")" "{" { match_arm [ "," | ";" ] } "}" .
match_arm     = variant_pat "=>" ( statement | expression )
              | "_" "=>" ( statement | expression ) .        (* §13.8 *)
variant_pat   = IDENT [ "(" IDENT { "," IDENT } ")" ] .   (* name + payload binders; §13.8 *)
select_stmt   = "select" "{" { comm_clause } "}" .
comm_clause   = "case" ( send_stmt | recv_bind ) ":" { statement ";" }
              | "default" ":" { statement ";" } .
recv_bind     = [ ( IDENT | tuple_pat ) "=" ] "<-" expression .

expression    = arrow_fn | conditional .
conditional   = catch_expr [ "?" expression ":" conditional ] .   (* §12, right-assoc *)
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

primary       = literal | IDENT | "(" expression ")" | tuple_lit | composite_lit
              | "[" [ arguments ] "]" .    (* bare slice literal *)
tuple_lit     = "(" expression "," expression { "," expression } ")" .   (* §12.10, at least 2 elements *)
composite_lit = type_name [ "<" type { "," type } ">" ] "{" [ field_inits ] "}"
              | slice_type "{" [ arguments ] "}"
              | array_type "{" [ arguments ] "}"
              | map_type   "{" [ map_entries ] "}" .
field_inits   = field_init { "," field_init } [ "," ] .
field_init    = IDENT [ ( ":" | "=" ) expression ] .
map_entries   = map_entry { "," map_entry } [ "," ] .
map_entry     = expression ":" expression .

literal       = INT_LIT | FLOAT_LIT | STRING_LIT | RAW_STRING_LIT
              | RUNE_LIT | BOOL_LIT | NIL_LIT .
```

**End of Bit Language Specification v0.1.**
