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
as       assert    break     case      catch     chan
const    continue  default   defer     else      enum
export   fail      false     for       from      function
if       import    in        interface let       map
match    nil       of        return    select    spawn
struct   switch    true      type      while
```

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
implementing `interface Show { show(): string }` does). `${` and `}` nest
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
- one of the postfix operators `++`, `--`;
- the error-propagation operator `?`.

Additionally:

- A `";"` is inserted before a `}` that closes a block, if not already present
  (so the last statement in a block needs no explicit terminator).
- A `";"` is inserted at end of file if the last token is a terminator.
- Consecutive synthesized/explicit semicolons collapse to one; empty statements
  are allowed and ignored.

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
func_decl     = "function" IDENT [ generic_params ] signature block .
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
  function bodies (§11.7), not to named-function signatures.
- A variadic parameter (`...name: T`) must be last; inside the body it has type
  `[]T`. At a call site the caller passes zero or more `T` arguments, or spreads a
  `[]T` with `...` (§12.4).

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

### 12.6 Index and Slice

- `s[i]` indexes a slice/array (`i` must be an integer; out-of-range **panics**,
  §18.4) or a string (yielding `byte`).
- `m[k]` indexes a map; a missing key yields the zero value of the value type. The
  two-result form `let (v, ok) = m[k]` also reports presence (`ok: bool`). The
  two-result form is only valid as the sole right-hand side of a value declaration
  or assignment.
- `s[lo:hi]` slices; `lo` defaults to `0`, `hi` to `len(s)`. Indices satisfy
  `0 <= lo <= hi <= cap(s)`; violation panics.

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
- To disambiguate from a parenthesized expression, the parser commits to an arrow
  function when a `)` is immediately followed by `=>`. This is one token of
  lookahead after the matching `)`.

### 12.9 Type Conversions and Constructors

A type used in call position converts or constructs:

```
i32(x)            // numeric conversion (explicit; no implicit narrowing)
f64(n)            // int -> float
string(runeVal)   // rune/[]byte/[]rune -> string
[]byte(s)         // string -> []byte (copy)
[]int(n)          // allocate a length-n zeroed slice
[]int(n, m)       // length n, capacity m
map<string,int>() // empty map
chan<int>()       // unbuffered channel
chan<int>(16)     // buffered channel, capacity 16
```

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
  result type.

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
- Satisfaction is checked at assignment/passing sites; there is no declaration of
  intent. Assigning a satisfying `S` into an `I`-typed location boxes `S` into an
  interface value carrying `S`'s dynamic type and method table.

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

### 14.5 Constants and Untyped Literals

See §15.4.

### 14.6 Comparability

- Numeric, `bool`, `string`, `rune` values compare with `==`/`!=` and (numerics,
  strings) with ordering operators.
- Arrays and tuples are comparable if their element types are; structs are
  comparable if all fields are comparable (field-wise).
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
  per instantiation like a generic struct (§14.1, §15). A construction never
  spells its type arguments: they are inferred from the payload argument
  (`Option.Some(5)` gives `Option<i64>`) or, when no argument constrains a
  parameter — a bare `None`, or the `E` in `Result.Ok(v)` — from the expected type
  (`let o: Option<i64> = Option.None`, or a function's declared return type). A
  parameter that neither source fixes is an error; annotate the target. The
  prelude (§17) defines `Option<T>` and `Result<T, E>` this way.

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

### 17.5 Prelude

Every module implicitly imports the exports of `std/core` — the **prelude** — as
if by `import { ... } from "std/core"`, with no `import` line. A name the module
declares or explicitly imports shadows the prelude name. The prelude provides the
handful of names a program is expected to reach for unqualified: `println`,
`newError`, and the generic enums `Option<T>` and `Result<T, E>` (§14.7). A build
without a standard-library checkout simply has no prelude.

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

## 19. Worked Example

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

## 20. Reserved for Future Versions (non-normative)

Intentionally **not** in v0.1, to keep the surface minimal:

- General union and optional types; `null` (absence is modeled by `nil` zero
  values and the Result model).
- Pointers, `&`/`*`, value-vs-pointer receivers.
- Operator overloading; user-defined implicit conversions.
- `recover`; catchable panics.
- Mutexes, atomics, `sync`-style primitives (channels only in v0.1).
- Nominal newtypes (all `type` aliases are transparent in v0.1).
- Thread handles / structured concurrency for `spawn`.

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

func_decl     = "function" IDENT [ generic_params ] signature block .
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
