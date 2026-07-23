# std/json

The `Json` value: a sum type over the seven shapes RFC 8259 §3 defines, plus
`JsonEntry`, one object key/value pair. This is the primitive the rest of the
json epic (#1479) — parser, encoder — builds on. Nothing here parses or
encodes JSON text; these are pure constructors and accessors over an
already-built `Json` value.

`JsonObject` is `[]JsonEntry`, not `map<string, Json>`: it keeps entries in
source order and allows duplicate keys, both of which a `map` would erase.
`jsonGet` resolves a duplicate key by returning the **last** matching entry —
the same policy most JSON decoders apply.

<!-- doctest: per-block -->

## The value type

### `JsonEntry`

One `key`/`value` pair of a `JsonObject`, in source order.

### `Json`

A JSON value: `JsonNull`, `JsonBool(bool)`, `JsonInt(i64)`, `JsonFloat(f64)`,
`JsonString(string)`, `JsonArray([]Json)`, or `JsonObject([]JsonEntry)`.

## Variant checks

### `jsonIsNull(j: Json): bool`

Whether `j` is `JsonNull`.

### `jsonIsBool(j: Json): bool`

Whether `j` is a `JsonBool`.

### `jsonIsInt(j: Json): bool`

Whether `j` is a `JsonInt`.

### `jsonIsFloat(j: Json): bool`

Whether `j` is a `JsonFloat`.

### `jsonIsString(j: Json): bool`

Whether `j` is a `JsonString`.

### `jsonIsArray(j: Json): bool`

Whether `j` is a `JsonArray`.

### `jsonIsObject(j: Json): bool`

Whether `j` is a `JsonObject`.

## Accessors

Each of these unwraps the matching variant's payload, or reports `None` on any
other shape — a caller decoding untrusted JSON handles a shape mismatch as
data, never a crash.

### `jsonAsBool(j: Json): Option<bool>`

`Some` of the payload when `j` is a `JsonBool`, else `None`.

### `jsonAsInt(j: Json): Option<i64>`

`Some` of the payload when `j` is a `JsonInt`, else `None`.

### `jsonAsFloat(j: Json): Option<f64>`

`Some` of the payload when `j` is a `JsonFloat`, else `None`.

### `jsonAsString(j: Json): Option<string>`

`Some` of the payload when `j` is a `JsonString`, else `None`.

### `jsonAsArray(j: Json): Option<[]Json>`

`Some` of the payload when `j` is a `JsonArray`, else `None`.

### `jsonGet(o: Json, key: string): Option<Json>`

Looks up `key` in `o`. `None` when `o` is not a `JsonObject` or `key` is
absent. On a duplicate key, returns the **last** matching entry.

## Lexer

A hand-written flat lexer over JSON text (strict RFC 8259, no comments — that
is JSONC, a separate layer). No regex, no generated tables, no recursion:
`{`/`[` nesting is tracked with a push/pop counter, not a call stack, so a
pathologically deep input yields `Invalid` instead of a stack overflow.

Tokens carry raw byte spans, not decoded values: a `StringTok` spans the
source including its quotes with escapes left raw, and a `NumberTok` spans
the literal exactly as written. Decoding and numeric-grammar validation are
the parser task's job, not this layer's — so a later CST layer can echo an
untouched literal back byte-for-byte.

### `TokenKind`

The lexical categories a token can be: `LBrace`, `RBrace`, `LBracket`,
`RBracket`, `Colon`, `Comma`, `StringTok`, `NumberTok`, `TrueTok`, `FalseTok`,
`NullTok`, `Eof`, `Invalid`, `Comment`. `Comment` is only ever produced by
`lexCst`; `lex` and the JSONC-strict-value scan both skip comments as
whitespace instead of tokenizing them.

### `Token`

One token: `kind`, and its `[start, end)` byte span in the source.

### `jsonMaxDepth`

The combined `{`/`[` nesting limit: 64 levels. Opening a 65th level yields an
`Invalid` token instead of tracking it.

### `lex(source: string): []Token`

The full token stream for `source`, ending with one `Eof`.

### `lexCst(source: string): []Token`

Same scanner and grammar as `lex`, JSONC mode, except a `//`/`/* */` comment
comes back as a `Comment` token (verbatim span, delimiters included) instead
of being skipped as whitespace. The CST parser (`cstParse`, below) uses this
to collect comments into `Trivia` without a second implementation of
string/number/word scanning.

```bit
import { Json, JsonEntry, jsonGet, jsonAsInt } from "std/json"

// Last-key-wins: two entries named "a", jsonGet returns the second (2).
function lastWins(): i64 {
  let obj = Json.JsonObject([]JsonEntry{
    JsonEntry{ key: "a", value: Json.JsonInt(1) },
    JsonEntry{ key: "a", value: Json.JsonInt(2) },
  })
  match (jsonGet(obj, "a")) {
    Some(v) => {
      match (jsonAsInt(v)) {
        Some(i) => return i
        None => return -1
      }
    }
    None => return -1
  }
}
```

## Encoding

The plain-value encoder: serializes a `Json` tree to text. No trivia, no
comments — the CST printer the edit layer needs is a separate, later task.

### `jsonEncode(j: Json): string`

Compact form: no whitespace, `,`/`:` with no padding. Keys and strings are
JSON-escaped per RFC 8259 §7 (`"`, `\`, and control bytes < 0x20 — `\n`, `\t`,
`\r`, `\b`, `\f` as their short escapes, anything else as `\u00XX`). Bytes
`>= 0x20` pass through as-is, since JSON strings are UTF-8.

### `jsonEncodePretty(j: Json, indent: string): string`

Pretty form: each object/array element on its own line, `indent` repeated
once per nesting depth, `": "` after each key. No trailing newline — matches
the shape of `JSON.stringify(v, null, 2)`.

```bit
import { Json, JsonEntry, jsonEncode, jsonEncodePretty } from "std/json"

function encodeExample(): string {
  let obj = Json.JsonObject([]JsonEntry{
    JsonEntry{ key: "name", value: Json.JsonString("bit\n") },
    JsonEntry{ key: "count", value: Json.JsonInt(2) },
  })
  return jsonEncode(obj) + "\n" + jsonEncodePretty(obj, "  ")
}
```

## Parsing

A recursive-descent parser over the lexer's token stream, building a `Json`
tree. Strict RFC 8259 only — no comments, no trailing commas; JSONC is a
separate layer on top. Malformed input (bad token sequence, an invalid
escape, a number that doesn't match the grammar, or exceeding the lexer's
64-level nesting cap) is a parse error via the fallible return, never a
panic. An integral literal that fits `i64` decodes to `JsonInt`; anything
wider, or with a `.`/`e`/`E`, decodes to `JsonFloat` via the runtime's own
`parseFloat`. A duplicate object key keeps every entry — `jsonGet`'s
last-key-wins policy is what resolves it.

### `jsonParse(source: string): Json!`

Parses `source` as one JSON value, optionally surrounded by whitespace and
nothing else.

```bit
import { jsonParse, jsonGet, jsonAsInt } from "std/json"

function parseExample(): i64 {
  let v = jsonParse("{\"a\": 1, \"a\": 2}") catch e {
    return -1
  }
  match (jsonGet(v, "a")) {
    Some(inner) => {
      match (jsonAsInt(inner)) {
        Some(i) => return i
        None => return -1
      }
    }
    None => return -1
  }
}
```

## JSONC

A narrow, explicit extension over strict JSON — deliberately **not** JSON5.
The grammar (also documented as the authoritative source in
stdlib/json/parse.bit's header comment):

- `//` line comments: from `//` to end of line, anywhere whitespace is
  currently allowed.
- `/* */` block comments: non-nesting, anywhere whitespace is currently
  allowed. An unterminated `/*` is a parse error.
- Trailing commas: a single trailing `,` is allowed before `}` or `]`
  (`[1, 2,]` and `{"a": 1,}` are valid). More than one trailing comma, or a
  leading comma, is still a parse error.

Explicitly out of scope: unquoted object keys, single-quoted strings, hex
numbers, `NaN`/`Infinity`, or any other JSON5 leniency.

### `jsoncParse(source: string): Json!`

Parses `source` as JSONC: everything `jsonParse` accepts, plus comments and
one trailing comma. `jsonParse` stays strict RFC 8259 so a caller that wants
to reject comments still can.

```bit
import { jsoncParse, jsonGet, jsonAsInt } from "std/json"

function jsoncExample(): i64 {
  let v = jsoncParse("{\n  // a comment\n  \"a\": 1,\n}") catch e {
    return -1
  }
  match (jsonGet(v, "a")) {
    Some(inner) => {
      match (jsonAsInt(inner)) {
        Some(i) => return i
        None => return -1
      }
    }
    None => return -1
  }
}
```

## The CST types

A concrete syntax tree shaped like `Json`, but every node also carries the
comments/blank lines around it, so a later edit-layer task (#1479) can mutate
one value and re-serialize the rest of the document byte-identical modulo the
edit. Types only — no parser, no printer, no mutation yet.

Bit enum variants take positional payloads only (no named payload fields), so
`CstNode`'s multi-field variants are documented by argument order below.

### `Trivia`

The comment/blank-line tokens immediately around one CST node, verbatim
source text (including `//` / `/* */` delimiters): `leading` is zero or more
tokens before the node, in source order; `trailing` is an optional same-line
comment after the node's own text, before the next comma/newline (or, for a
container, before its close — see `CstArray`/`CstObject` below).

### `CstEntry`

One key/value pair of a `CstObject`, in source order: `keyText` is the raw
source text of the key, including quotes, exactly as written; `key` is the
decoded key string, for lookups.

### `CstNode`

A `Json` value together with the `Trivia` around it: `CstNull(Trivia)`,
`CstBool(bool, Trivia)`, `CstNumber(rawText: string, Trivia)` (exact source
span, e.g. `"1.50000"`), `CstString(rawText: string, Trivia)` (exact source
span, including quotes), `CstArray([]CstNode, Trivia)`, or
`CstObject([]CstEntry, Trivia)`. A comment on its own line right before an
array/object's closing `]`/`}` is folded into that container's own
`Trivia.trailing`, rather than a separate `closeTrivia` field.

## CST parsing

`cstParse` parses JSONC into the CST above, losslessly: every comment and
each number/string's exact raw span survive, unlike `jsonParse`/`jsoncParse`
above, which discard both. This is the parser a later edit-layer task
mutates the output of.

A leading comment run attaches to the following node's `Trivia.leading`, one
entry per comment, in source order — never concatenated. A comment on the
same source line as a value, before that value's own trailing comma, attaches
to that value's `Trivia.trailing` (`1 /* like this */,` counts, `1, /* not
this */` does not — that one becomes the next node's leading instead). No
`hadTrailingComma` flag is stored on `CstArray`/`CstObject`: a printer
re-derives comma placement from the array/object's own length and each
entry's index.

### `cstParse(source: string): CstNode!`

Parses `source` as JSONC (same grammar as `jsoncParse`) into a trivia-carrying
CST rather than a plain `Json` value. Malformed input is a parse error via the
fallible return, never a panic.

```bit
import { cstParse, CstNode } from "std/json"

function cstExample(): string {
  let root = cstParse("{\n  // a comment\n  \"a\": 1,\n}") catch e {
    return "error"
  }
  match (root) {
    CstObject(entries, trivia) => return entries[0].trivia.leading[0]
    CstNull(t) => return "null"
    CstBool(b, t) => return "bool"
    CstNumber(r, t) => return "number"
    CstString(s, t) => return "string"
    CstArray(a, t) => return "array"
  }
}
```

## Editing the CST

The path-based edit layer `bit add` (#1480, the package-manager epic) calls
to change `bit.json` without disturbing anything it didn't touch — the json
epic's namesake "edit layer". A path is `[]string` of object keys only
(array-index paths are out of scope; `bit.json`'s dependency map is
object-keyed). Every function mutates and returns its `root` — struct and
slice writes along the path are visible in place, but an append or a
deletion changes a slice's length, and a `CstNode`'s payload can't be
reassigned in place, so that one node is rebuilt and returned; always use
the return value rather than assuming the original `root` already reflects
the edit.

On a duplicate key, all three functions below resolve the **last** matching
entry, the same policy `jsonGet` documents above.

### `cstGet(root: CstNode, path: []string): Option<CstNode>`

Read-only lookup of `path` under `root`, mirroring `jsonGet` but over the
CST. `None` as soon as an intermediate segment isn't a `CstObject` or a key
is missing — never a panic on an absent path.

```bit
import { cstParse, cstGet, CstNode } from "std/json"

function cstGetExample(): string {
  let root = cstParse("{\"a\": {\"b\": \"c\"}}") catch e {
    return "error"
  }
  match (cstGet(root, []string{ "a", "b" })) {
    Some(node) => {
      match (node) {
        CstString(raw, t) => return raw
        CstNull(t) => return "null"
        CstBool(b, t) => return "bool"
        CstNumber(r, t) => return "number"
        CstArray(a, t) => return "array"
        CstObject(es, t) => return "object"
      }
    }
    None => return "missing"
  }
}
```

### `cstSetString(root: CstNode, path: []string, value: string): CstNode!`

Sets the string value at `path` to `value` (JSON-quoted and escaped). If
`path` resolves to an existing `CstString` entry, only its `rawText` is
replaced — that entry's `keyText` and `Trivia` are untouched. If the final
key is absent but its parent object exists, a new `CstEntry` is appended
(empty `Trivia`, no comment invented). Fails if the existing value at the
final key isn't a `CstString`, or any intermediate segment doesn't resolve
to a `CstObject` — this function never creates an intermediate object.

```bit
import { cstParse, cstSetString, cstGet, CstNode } from "std/json"

function cstSetStringExample(): string {
  let root = cstParse("{\"a\": \"old\"}") catch e {
    return "error"
  }
  let updated = cstSetString(root, []string{ "a" }, "new") catch e {
    return "error"
  }
  match (cstGet(updated, []string{ "a" })) {
    Some(node) => {
      match (node) {
        CstString(raw, t) => return raw
        CstNull(t) => return "null"
        CstBool(b, t) => return "bool"
        CstNumber(r, t) => return "number"
        CstArray(a, t) => return "array"
        CstObject(es, t) => return "object"
      }
    }
    None => return "missing"
  }
}
```

### `cstDeleteKey(root: CstNode, path: []string): CstNode!`

Removes the `CstEntry` at `path` from its parent's entries. Every sibling
entry keeps its own `Trivia`, `rawText`, and relative order unchanged. The
deleted entry's own `Trivia.leading` comments are dropped with it — the one
case where a comment can legitimately disappear, and only that entry's own
leading comments, never a sibling's. Fails if any path segment doesn't
exist, or an intermediate segment doesn't resolve to a `CstObject`.

```bit
import { cstParse, cstDeleteKey, cstGet } from "std/json"

function cstDeleteKeyExample(): string {
  let root = cstParse("{\"a\": 1, \"b\": 2}") catch e {
    return "error"
  }
  let updated = cstDeleteKey(root, []string{ "a" }) catch e {
    return "error"
  }
  match (cstGet(updated, []string{ "a" })) {
    Some(node) => return "still-present"
    None => return "deleted"
  }
}
```
