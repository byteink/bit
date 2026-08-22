# std/json

The `Json` value: a sum type over the seven shapes RFC 8259 §3 defines, plus
`JsonEntry`, one object key/value pair. This is the primitive the rest of the
json module - parser, encoder - builds on. Nothing here parses or
encodes JSON text; these are pure constructors and accessors over an
already-built `Json` value.

`JsonObject` is `[]JsonEntry`, not `map<string, Json>`: it keeps entries in
source order and allows duplicate keys, both of which a `map` would erase.
`jsonGet` resolves a duplicate key by returning the **last** matching entry -
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
other shape - a caller decoding untrusted JSON handles a shape mismatch as
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

### `jsonAsObject(j: Json): Option<[]JsonEntry>`

`Some` of the payload when `j` is a `JsonObject`, else `None`. The returned
slice is the object's own entries, in source order, with duplicate keys kept
- the same shape `JsonObject` stores internally, not a copy. Use this to
enumerate an object's keys; `jsonGet` only answers one known key at a time.

```bit
import { Json, JsonEntry, jsonAsObject } from "std/json"

// Two entries named "a": jsonAsObject keeps both, in source order.
fn countKeys(): int {
  let obj = Json.JsonObject([]JsonEntry{
    JsonEntry{ key: "a", value: Json.JsonInt(1) },
    JsonEntry{ key: "a", value: Json.JsonInt(2) },
  })
  match (jsonAsObject(obj)) {
    Some(entries) => return len(entries)
    None => return -1
  }
}
```

### `jsonGet(o: Json, key: string): Option<Json>`

Looks up `key` in `o`. `None` when `o` is not a `JsonObject` or `key` is
absent. On a duplicate key, returns the **last** matching entry.

## Lexer

A hand-written flat lexer over JSON text (strict RFC 8259, no comments - that
is JSONC, a separate layer). No regex, no generated tables, no recursion:
`{`/`[` nesting is tracked with a push/pop counter, not a call stack, so a
pathologically deep input yields `Invalid` instead of a stack overflow.

Tokens carry raw byte spans, not decoded values: a `StringTok` spans the
source including its quotes with escapes left raw, and a `NumberTok` spans
the literal exactly as written. Decoding and numeric-grammar validation are
the parser task's job, not this layer's - so a later CST layer can echo an
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

The combined `{`/`[` nesting limit: 128 levels. Opening a 129th level
yields an `Invalid` token instead of tracking it. Raised from 64 (#2256,
too low in practice) but deliberately not raised to 1000 (#2345, reverted:
a green thread's smaller stack overflowed inside `spawn` around depth 250,
so a higher cap gave a false sense of headroom that crashed the process
instead of erroring cleanly).

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
fn lastWins(): i64 {
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
comments - the CST printer the edit layer needs is a separate, later task.

### `jsonEncode(j: Json): string`

Compact form: no whitespace, `,`/`:` with no padding. Keys and strings are
JSON-escaped per RFC 8259 §7 (`"`, `\`, and control bytes < 0x20 - `\n`, `\t`,
`\r`, `\b`, `\f` as their short escapes, anything else as `\u00XX`). Bytes
`>= 0x20` pass through as-is, since JSON strings are UTF-8.

A `JsonFloat` is formatted so that `jsonParse(jsonEncode(j))` always
reproduces `j`, or - for the one shape JSON cannot represent - still
produces text `jsonParse` accepts:

- A non-finite value (`inf`, `-inf`, `nan`) encodes as `null`, matching
  `JSON.stringify`/serde_json. JSON has no non-finite literal, and the
  runtime's own `inf`/`-inf`/`nan` spelling is not valid JSON.
- An integral value (`3.0`) keeps its `.0` (`"3.0"`, not `"3"`), and `-0.0`
  keeps its sign (`"-0.0"`, not `"-0"`) - both are what distinguish a
  `JsonFloat` from a `JsonInt` on the way back in, since a literal with no
  `.`/`e`/`E` decodes to `JsonInt` (see Parsing, below).
- A value outside roughly `1e-6 .. 1e21` in magnitude is written in
  exponent form (`5e-324`, `1.7976931348623157e+308`) rather than a
  positional expansion, matching where JS `Number#toString` and Go's
  `strconv` switch. The digits are unchanged either way - this only
  reshapes how they're written.

### `jsonEncodePretty(j: Json, indent: string): string`

Pretty form: each object/array element on its own line, `indent` repeated
once per nesting depth, `": "` after each key. No trailing newline - matches
the shape of `JSON.stringify(v, null, 2)`.

```bit
import { Json, JsonEntry, jsonEncode, jsonEncodePretty } from "std/json"

fn encodeExample(): string {
  let obj = Json.JsonObject([]JsonEntry{
    JsonEntry{ key: "name", value: Json.JsonString("bit\n") },
    JsonEntry{ key: "count", value: Json.JsonInt(2) },
  })
  return jsonEncode(obj) + "\n" + jsonEncodePretty(obj, "  ")
}
```

## Parsing

A recursive-descent parser over the lexer's token stream, building a `Json`
tree. Strict RFC 8259 only - no comments, no trailing commas; JSONC is a
separate layer on top. Malformed input (bad token sequence, an invalid
escape, a number that doesn't match the grammar, or exceeding the lexer's
`jsonMaxDepth` nesting cap) is a parse error via the fallible return, never a
panic. An integral literal that fits `i64` - including `i64` MIN,
`-9223372036854775808` - decodes to `JsonInt`; anything wider, or with a
`.`/`e`/`E`, decodes to `JsonFloat` via the runtime's own `parseFloat`. A
duplicate object key keeps every entry - `jsonGet`'s last-key-wins policy is
what resolves it.

Every parse error's `message()` carries where it happened, not just what went
wrong: `"json: expected ',' or '}' in object at byte 7 (line 1, column 8)"`.
The byte offset is what a program slices or seeks with; line:column is what a
human reads - 1-based, matching the compiler's own `--> file:LINE:COL`
numbering. Both count bytes, not Unicode runes, so a column after a
multi-byte UTF-8 character counts each of its bytes; a `\r\n` line ending
counts as one line break. An error at end-of-input reports the position just
past the last byte (never an out-of-range value or a silent zero) - the
correct place to point at when there's no next character to blame.

### `jsonParse(source: string): Json!`

Parses `source` as one JSON value, optionally surrounded by whitespace and
nothing else.

```bit
import { jsonParse, jsonGet, jsonAsInt } from "std/json"

fn parseExample(): i64 {
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

A narrow, explicit extension over strict JSON - deliberately **not** JSON5.
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

fn jsoncExample(): i64 {
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
comments/blank lines around it, so the edit layer can mutate
one value and re-serialize the rest of the document byte-identical modulo the
edit. Types only - no parser, no printer, no mutation yet.

Bit enum variants take positional payloads only (no named payload fields), so
`CstNode`'s multi-field variants are documented by argument order below.

`Trivia.leading`/`.trailing` are only ever populated on the root node
returned by `cstParse` (a comment or blank line before the document's first
token, or after its last) - every other node's own `Trivia` is empty,
because its surrounding formatting is owned by its parent container's `gaps`
or by its `CstEntry.midGap` instead. The CST printer found that a
comment-only `Trivia` couldn't reproduce a document's plain whitespace
(indentation, blank lines) or comma placement - this shape closes that gap by
making every boundary between structural tokens a single verbatim raw-text
field.

### `Trivia`

`leading`/`trailing`: verbatim source text (comments and whitespace
together, exactly as written) before/after the root node's own text. Empty
on every non-root node.

### `CstEntry`

One key/value pair of a `CstObject`, in source order: `keyText` is the raw
source text of the key, including quotes, exactly as written; `key` is the
decoded key string, for lookups; `midGap` is the verbatim text between the
key's closing quote and the value's first token (the `:` plus any
surrounding whitespace or comments).

### `CstNode`

A `Json` value together with the `Trivia` around it: `CstNull(Trivia)`,
`CstBool(bool, Trivia)`, `CstNumber(rawText: string, Trivia)` (exact source
span, e.g. `"1.50000"`), `CstString(rawText: string, Trivia)` (exact source
span, including quotes), `CstArray([]CstNode, gaps: []Option<string>,
Trivia)`, or `CstObject([]CstEntry, gaps: []Option<string>, Trivia)`.

A container's `gaps` holds one verbatim raw-text boundary per child plus one:
`gaps[i]` is the text before child `i` (comments, indentation, and - for
`i > 0` - the comma that ended child `i - 1`); `gaps[len(children)]` is the
text after the last child, before the closing `}`/`]` (including an optional
trailing comma). `gaps[i]` is `Option<string>.None` only for an entry
appended by `cstSetString` after the original parse - there is no original
formatting to echo; `cstPrint` (below) synthesizes it from the preceding
sibling's own indentation instead of guessing a hardcoded style. Every gap
`cstParse` produces is `Some`.

## CST parsing

`cstParse` parses JSONC into the CST above, losslessly: every byte of
formatting - comments, indentation, blank lines, and comma placement -
survives, unlike `jsonParse`/`jsoncParse` above, which discard all of it.
This is the parser a later edit-layer task mutates the output of.

No `hadTrailingComma` flag is stored on `CstArray`/`CstObject`: a trailing
comma, if present, is simply part of the container's own `gaps` raw text,
recovered the same way as any other gap.

### `cstParse(source: string): CstNode!`

Parses `source` as JSONC (same grammar as `jsoncParse`) into a trivia-carrying
CST rather than a plain `Json` value. Malformed input is a parse error via the
fallible return, never a panic.

Like `jsonParse`/`jsoncParse` above, every `cstParse` error's `message()`
carries where it happened: `"json: expected ',' or '}' in object at byte 7
(line 1, column 8)"`. Same convention, same helper (`posError`/`jsonLocate`,
shared across this module) - see `jsonParse` above for the full rules on byte
vs. rune columns, `\r\n`, and end-of-input.

```bit
import { cstParse, CstNode } from "std/json"

fn cstExample(): string {
  let root = cstParse("{\n  // a comment\n  \"a\": 1,\n}") catch e {
    return "error"
  }
  match (root) {
    CstObject(entries, gaps, trivia) => return entries[0].midGap
    CstNull(t) => return "null"
    CstBool(b, t) => return "bool"
    CstNumber(r, t) => return "number"
    CstString(s, t) => return "string"
    CstArray(a, g, t) => return "array"
  }
}
```

## Editing the CST

The path-based edit layer `bit add` (the package manager) calls
to change `bit.json` without disturbing anything it didn't touch - the json
epic's namesake "edit layer". A path is `[]string` of object keys only
(array-index paths are out of scope; `bit.json`'s dependency map is
object-keyed). Every function mutates and returns its `root` - struct and
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
is missing - never a panic on an absent path.

```bit
import { cstParse, cstGet, CstNode } from "std/json"

fn cstGetExample(): string {
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
        CstArray(a, g, t) => return "array"
        CstObject(es, g, t) => return "object"
      }
    }
    None => return "missing"
  }
}
```

### `cstSetString(root: CstNode, path: []string, value: string): CstNode!`

Sets the string value at `path` to `value` (JSON-quoted and escaped). If
`path` resolves to an existing `CstString` entry, only its `rawText` is
replaced - that entry's `keyText` and the value's own `Trivia` are untouched.
If the final key is absent but its parent object exists, a new `CstEntry` is
appended with no comment invented; the gap immediately before it is `None`,
so `cstPrint` synthesizes formatting for it from the preceding sibling's own
indentation rather than a hardcoded style. Fails if the existing value at the
final key isn't a `CstString`, or any intermediate segment doesn't resolve
to a `CstObject` - this function never creates an intermediate object.

```bit
import { cstParse, cstSetString, cstGet, CstNode } from "std/json"

fn cstSetStringExample(): string {
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
        CstArray(a, g, t) => return "array"
        CstObject(es, g, t) => return "object"
      }
    }
    None => return "missing"
  }
}
```

### `cstSetStringPath(root: CstNode, path: []string, value: string): CstNode!`

Same contract as `cstSetString`, except a missing INTERMEDIATE object along
`path` is created (recursively, empty except for the one path being set)
rather than failing - `bit add`'s own need: a project's first-ever
dependency add when `bit.json` has no `"dependencies"` object yet at all.

```bit
import { cstParse, cstSetStringPath, cstGet, CstNode } from "std/json"

fn cstSetStringPathExample(): string {
  let root = cstParse("{}") catch e {
    return "error"
  }
  let updated = cstSetStringPath(root, []string{ "dependencies", "quicwire" }, "github.com/byteink/quicwire@v1.4.2") catch e {
    return "error"
  }
  match (cstGet(updated, []string{ "dependencies", "quicwire" })) {
    Some(node) => {
      match (node) {
        CstString(raw, t) => return raw
        CstNull(t) => return "null"
        CstBool(b, t) => return "bool"
        CstNumber(r, t) => return "number"
        CstArray(a, g, t) => return "array"
        CstObject(es, g, t) => return "object"
      }
    }
    None => return "missing"
  }
}
```

### `cstDeleteKey(root: CstNode, path: []string): CstNode!`

Removes the `CstEntry` at `path` from its parent's entries. Every sibling
entry keeps its own value and relative order unchanged. The deleted entry's
own leading gap (its comments/indentation) is dropped with it - the one case
where a comment can legitimately disappear, and only that entry's own
leading gap, never a sibling's. Fails if any path segment doesn't exist, or
an intermediate segment doesn't resolve to a `CstObject`.

```bit
import { cstParse, cstDeleteKey, cstGet } from "std/json"

fn cstDeleteKeyExample(): string {
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

## Printing the CST

`cstPrint` is the other side of `cstParse`: it turns a CST back into JSONC
source text. For any node an edit function (above) did not touch, it
reproduces `cstParse`'s original input byte-for-byte - every `rawText`
verbatim, every comment in its original form, and the surrounding structural
whitespace, indentation, and comma placement - because `cstParse` already
captured all of that as opaque raw text instead of decoding it; printing an
untouched subtree is concatenation, never re-encoding. For a value
`cstSetString` replaced, the fresh `rawText` takes the old one's place with
everything else around it unchanged. For an entry `cstSetString` appended,
`cstPrint` synthesizes its one new line (`,` + a newline + indentation) by
reading the indentation off the immediately preceding sibling's own gap,
rather than a hardcoded style.

### `cstPrint(n: CstNode): string`

Serializes `n` to JSONC source text.

```bit
import { cstParse, cstSetString, cstPrint } from "std/json"

fn cstPrintRoundTrip(): string {
  let source = "{\n  // keep\n  \"a\": 1\n}"
  let root = cstParse(source) catch e {
    return "parse-error"
  }
  return cstPrint(root)
}

fn cstPrintAfterEdit(): string {
  let root = cstParse("{\"a\": \"old\"}") catch e {
    return "parse-error"
  }
  let updated = cstSetString(root, []string{ "a" }, "new") catch e {
    return "edit-error"
  }
  return cstPrint(updated)
}
```

## CST-to-Json projection

A read-only consumer that only wants a JSONC document's values (e.g. `bit lsp`
inspecting a config) does not need to know the CST shape at all: parse with
`cstParse`, project with `cstToJson`, then read the result with the same
`jsonGet`/`jsonAsX` accessors a plain-JSON caller uses.

### `cstToJson(n: CstNode): Json`

Strips every `Trivia` and decodes each `CstNumber`/`CstString`'s raw source
span, turning a CST into a plain `Json` tree. Pure and total - unlike
`cstParse`, it cannot fail, since every span it decodes was already validated
once when `cstParse` built the CST. Comments make no difference to the result:
projecting `cstParse(source)` and calling `jsoncParse(source)` directly always
agree, for any JSONC `source`.

```bit
import { cstParse, cstToJson, jsonGet, jsonAsInt } from "std/json"

fn cstToJsonExample(): i64 {
  let root = cstParse("{\n  // a comment\n  \"a\": 1,\n}") catch e {
    return -1
  }
  match (jsonGet(cstToJson(root), "a")) {
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
