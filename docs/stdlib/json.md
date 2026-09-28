# std/json

Inkwell needs JSON in three places: a settings file, a backup that exports
drafts and imports them again, and the body of an HTTP request or response
once Inkwell goes online. `std/json` covers all three - a value type you can
inspect by hand, a typed decoder for when you already know the shape, and a
schema generator for documenting or validating it.

The core type is `Json`, one value: a null, a bool, a number, a string, an
array, or an object. `JsonObject` is `[]JsonEntry`, not `map<string, Json>` -
it keeps entries in source order and allows duplicate keys, which a `map`
would erase. Looking up a duplicate key (`jsonGet`, `cstGet`) always returns
the **last** matching entry, the policy every JSON decoder converges on.

<!-- doctest: per-block -->

## The simplest thing: read a value, write it back

`jsonParse` turns text into a `Json` tree; `jsonEncode` turns it back into
text. Reading one field out of a small settings document needs nothing more:

```bit
import { jsonParse, jsonGet, jsonAsString } from "std/json"

fn readTheme(source: string): string! {
  let doc = jsonParse(source)?
  match (jsonGet(doc, "theme")) {
    Some(v) => {
      match (jsonAsString(v)) {
        Some(s) => return s
        None => fail newError("theme is not a string")
      }
    }
    None => fail newError("missing key 'theme'")
  }
}
```

`jsonGet`/`jsonAsX` return `Option`, never panic, so a document that does not
match what you expected is an ordinary value to handle, not a crash. Writing
a document back out is the same shape in reverse:

```bit
import { Json, JsonEntry, jsonEncode, jsonEncodePretty } from "std/json"

fn settingsDoc(theme: string, retries: i64): string {
  let doc = Json.JsonObject(
    []JsonEntry{
      JsonEntry{ key = "theme", value = Json.JsonString(theme) },
      JsonEntry{ key = "retries", value = Json.JsonInt(retries) },
    },
  )
  return jsonEncodePretty(doc, "  ")
}
```

`jsonEncode` writes the compact form; `jsonEncodePretty` adds one indent per
nesting level and a `": "` after each key, the shape `JSON.stringify(v, null,
2)` produces. Building a tree by hand like this works for a handful of
fields. For anything with more than a few, or for data you want to move in
and out of a class, keep reading.

## Inspecting a document you did not shape

A webhook payload or a third-party API response often has a shape you only
partly control. `jsonIsX`/`jsonAsX` check and unwrap one variant at a time,
and `jsonAsObject` walks every key when you do not know them ahead of time:

```bit
import { Json, jsonAsArray, jsonGet } from "std/json"

// Counts the tags on an imported draft, however the sender ordered its keys.
fn tagCount(entry: Json): i64! {
  match (jsonGet(entry, "tags")) {
    Some(v) => {
      match (jsonAsArray(v)) {
        Some(items) => return len(items)
        None => fail newError("tags is not an array")
      }
    }
    None => return 0
  }
}
```

`jsonAsObject` is the same shape for walking every key of an object whose
key set is not known ahead of time; `jsonAsArray`/`jsonAsString`/`jsonAsBool`
follow the same pattern for the other variants.

That is enough for a one-off read. A program that imports drafts by the
thousand wants the next section instead: decode straight into a class.

## The shape you actually want: typed decode

Mark a class `@json` and it gains a `toJson()` method; pass a parsed
document to `jsonDecode<T>` and you get the class back, with every field
checked against the document. The two are generated from the same field
list, so they can never drift apart.

```bit
import { jsonParse, jsonDecode, jsonEncode, Json, JsonEntry } from "std/json"

enum Status { Draft, Published, Archived }

@json class ExportedDraft {
  id: string
  title: string
  tags: []string
  status: Status
  @key("word_count")
  wordCount: Option<i64>
}

fn importDraft(body: string): ExportedDraft! {
  return jsonDecode<ExportedDraft>(jsonParse(body)?)?
}

fn exportDraft(d: ExportedDraft): string {
  return jsonEncode(d.toJson())
}
```

A payload-free `enum` field like `status` round-trips as its variant's own
name (`"Published"`), validated against the declared list either way. `@key`
overrides the JSON name for one field, for a payload written by something
else. An absent `Option<T>` field decodes to `None` whether the key is
missing or explicitly `null` - `toJson()` always writes the explicit form, so
what Inkwell exports always decodes back the same way it went out.

Every decode failure names the field by its full path from the root -
`addr.city`, `tags[3]` - through one of four causes: a required key is
missing, a value is the wrong JSON kind, the document has a key no field
claims, or it nests past the depth limit. Catch it and branch when you need
to:

```bit
import { jsonParse, jsonDecode, JsonDecodeError, Json, JsonEntry } from "std/json"

@json class ExportedDraft2 {
  id: string,
}

fn importOrExplain(body: string): string {
  let doc = jsonParse(body) catch e {
    return "invalid JSON: ${e.message()}"
  }
  let d = jsonDecode<ExportedDraft2>(doc) catch e {
    let de = e.(JsonDecodeError)
    return "rejected '${de.path}': ${de.message()}"
  }
  return "imported ${d.id}"
}
```

**Reading an HTTP request body** is the same decode with no `Json` step in
between. `jsonDecodeText<T>` reads the class's fields straight off the raw
text - on 50,000 one-record decodes it costs 6 objects against 45 for
`jsonParse` then `jsonDecode`, because no `Json` tree is ever built:

```bit
import { jsonDecodeText, Json, JsonEntry } from "std/json"

@json class NewDraft {
  title: string,
  body: string,
}

fn createDraft(requestBody: string): NewDraft! {
  return jsonDecodeText<NewDraft>(requestBody)?
}
```

It reports the same errors, with one difference: reading forward, it stops
at the first fault it reaches in document order, where `jsonDecode` reads
the whole object first and always reports missing keys before type
mismatches. Given a document with two faults, either path names a real one -
they can just name a different one.

## Documenting and validating: `jsonSchema<T>()`

Every `@json` class already carries its own shape. `jsonSchema<T>()` turns
that into a JSON Schema 2020-12 document - the same dialect OpenAPI 3.1 uses
for a request or response body - with no second description to keep in
sync:

```bit
import { Json, JsonEntry, jsonSchema, jsonEncode } from "std/json"

@json class DraftSettings {
  autosaveSeconds: i64,
  spellcheck: Option<bool>,
}

fn openApiSchema(): string {
  return jsonEncode(jsonSchema<DraftSettings>())
}
```

A scalar field maps to its `type`; `[]T` to `items`; `map<string, T>` to
`additionalProperties`; a payload-free `enum` to `type: "string"` plus its
declared names; a nested `@json` class to a `$ref` into a top-level
`"$defs"` (one entry per reachable class, deduplicated, so a shared or
self-referential class is not duplicated). `Option<T>` folds `"null"` into
`T`'s own fragment. `required` always lists every field, because `toJson()`
never omits a key.

## Sharp edges

- **Unknown keys are rejected by default.** `jsonDecode<T>` fails
  `UnknownKey` on a document field no class field claims - a silently
  dropped field is invisible to whoever sent it. `jsonDecodeLenient<T>`
  drops the check instead of failing, for one case only: a public endpoint
  that must keep accepting documents a newer client already sends. Do not
  reach for it by default; a caller that wants the strict form gets it by
  writing the shorter name, `jsonDecode`.
- **JSON has one number type.** `jsonAsFloat` only matches a literal that
  was written with a `.`/`e`/`E`; `jsonAsNumber` widens either spelling to
  `f64` and is almost always the one you want when decoding into an `f64`
  field by hand.
- **Nesting past 128 levels fails, not crashes.** `jsonMaxDecodeDepth` bounds
  `jsonDecode<T>`/`jsonDecodeText<T>` independently of whatever limit a
  parser applied, because a `@json` class can be self-referential and a
  `Json` value built in code never went through a parser at all.
- **A non-finite float encodes as `null`.** JSON has no literal for
  infinity or NaN, so `jsonEncode`/`jsonEncodePretty` write `null` for one,
  matching `JSON.stringify`.
- **Comments need JSONC, on purpose.** `jsonParse` is strict RFC 8259 and
  rejects `//`/`/* */` comments and trailing commas outright.
  `jsoncParse` accepts both, plus one trailing comma before `}`/`]` - and
  nothing else JSON5 allows (no unquoted keys, no hex numbers).

## Editing a JSON file without losing its comments

`bit.json` is the one JSON document in this repo people hand-edit and expect
tooling to leave alone: comments, indentation, even a trailing comma should
survive a machine-made change untouched. `jsonParse` cannot help here - it
throws formatting away - so the edit layer parses into a **CST** (concrete
syntax tree) with `cstParse`, edits by path, and prints back with `cstPrint`:

```bit
import { cstParse, cstSetStringPath, cstPrint } from "std/json"

fn addDependency(configText: string, name: string, version: string): string! {
  let root = cstParse(configText)?
  let updated = cstSetStringPath(root, []string{ "dependencies", name }, version)?
  return cstPrint(updated)
}
```

`cstSetStringPath` creates a missing intermediate object (a project's first
dependency, when `"dependencies"` does not exist yet); `cstSetString` is the
stricter sibling that never does. `cstDeleteKey` removes one entry.
Everything an edit function did not touch reproduces the original bytes
exactly - `cstParse` keeps every comment and blank line as raw text instead
of decoding it, so printing an untouched subtree is concatenation, not
re-encoding. A read-only consumer that just wants the values can skip the
CST shape with `cstToJson`, then read the result with `jsonGet`/`jsonAsX`
like any other document.

## When not to use std/json

- **A document larger than memory, or streamed over a slow connection.**
  Every entry point here reads a complete `string` or a complete `Json`
  tree first; there is no incremental parser that returns partial results
  as bytes arrive.
- **Hand-building JSON text with string concatenation.** Every quote,
  backslash and control byte in a string field has to be escaped or the
  output is not valid JSON - build a `Json` tree and call `jsonEncode`, or
  use the `jsonAppend*` functions (reference below) if you are already
  writing into a `[]byte` and want to skip the tree.

## Where to go next

- [std/sql](/std/sql) - to store what you decoded.
- [Attributes](/language/attributes) - the full rules for `@json`, `@key`
  and `@table`.
- [The Book, chapter 8](/book/08-import-and-export) - Inkwell's own
  import/export walkthrough.

## Reference

### The value type

| Symbol | What it is |
| --- | --- |
| `JsonEntry` | One `key`/`value` pair of a `JsonObject`, in source order. |
| `Json` | `JsonNull \| JsonBool(bool) \| JsonInt(i64) \| JsonFloat(f64) \| JsonString(string) \| JsonArray([]Json) \| JsonObject([]JsonEntry)`. |

### Inspecting a `Json` value

| Symbol | Signature | What it does |
| --- | --- | --- |
| `jsonIsNull` .. `jsonIsObject` | `(j: Json): bool` | One check per variant (`jsonIsNull`, `jsonIsBool`, `jsonIsInt`, `jsonIsFloat`, `jsonIsNumber` - int or float, `jsonIsString`, `jsonIsArray`, `jsonIsObject`). |
| `jsonAsBool` .. `jsonAsObject` | `(j: Json): Option<T>` | One unwrap per variant (`jsonAsBool`, `jsonAsInt`, `jsonAsFloat`, `jsonAsNumber` - int or float widened to `f64`, `jsonAsString`, `jsonAsArray`, `jsonAsObject`), `None` on any other shape. |
| `jsonGet` | `(o: Json, key: string): Option<Json>` | Looks up `key`; `None` if `o` is not an object or `key` is absent; last-key-wins on a duplicate. |

### Parsing

| Symbol | Signature | What it does |
| --- | --- | --- |
| `jsonParse` | `(source: string): Json!` | Strict RFC 8259: no comments, no trailing commas. |
| `jsoncParse` | `(source: string): Json!` | `jsonParse` plus `//`/`/* */` comments and one trailing comma. |

Every parse error's `message()` names where it happened: byte offset and
1-based line:column, both counted in bytes.

### Encoding

| Symbol | Signature | What it does |
| --- | --- | --- |
| `jsonEncode` | `(j: Json): string` | Compact form, no whitespace. |
| `jsonEncodePretty` | `(j: Json, indent: string): string` | One element per line, `indent` per nesting level. |
| `jsonAppendRaw` | `(out: []byte, s: string): []byte` | Appends `s` verbatim, no escaping. |
| `jsonAppendKey` | `(out: []byte, key: string, first: bool): []byte` | Appends `,` (unless `first`) then the quoted key then `:`. |
| `jsonAppendString` | `(out: []byte, s: string): []byte` | Appends `s` as an escaped, quoted string. |
| `jsonAppendInt` | `(out: []byte, v: i64): []byte` | Appends `v` as a JSON number. |
| `jsonAppendFloat` | `(out: []byte, v: f64): []byte` | Appends `v` as a JSON number, reshaped like `jsonEncode` does. |
| `jsonAppendBool` | `(out: []byte, v: bool): []byte` | Appends `true`/`false`. |
| `jsonAppendNull` | `(out: []byte): []byte` | Appends `null`. |

### Typed decode

| Symbol | Signature | What it does |
| --- | --- | --- |
| `jsonDecode<T>` | `(j: Json): T!` | Decodes `j` into `@json` class `T`. |
| `jsonDecodeText<T>` | `(src: string): T!` | Same decode, straight off JSON text, no `Json` built. |
| `jsonDecodeLenient<T>` | `(j: Json): T!` | Same decode, dropping unclaimed keys instead of failing. |
| `jsonSchema<T>` | `(): Json` | A JSON Schema 2020-12 document describing `T`. |
| `JsonDecodeCause` | enum | `MissingKey \| TypeMismatch \| UnknownKey \| MaxDepth`. |
| `JsonDecodeError` | class | `cause`, `path`, `expected`, `found`, `message()`. Reach it with `e.(JsonDecodeError)`. |
| `jsonMaxDecodeDepth` | `const = 128` | The recursion limit `MaxDepth` fires past. |

### Decode building blocks

What the compiler's generated decoder calls, and a usable API for a
hand-written one over a shape `@json` does not cover. Each of the four
scalar extractors comes in three forms: the base form takes an already-built
`path`; `...Key`/`...Index` take the containing value's path plus one step,
joining them only inside the failure message.

| Symbol | Signature | What it does |
| --- | --- | --- |
| `jsonDecPath` | `(path: string, key: string): string` | `path` plus object key `key` (`addr.city`). |
| `jsonDecIndex` | `(path: string, i: i64): string` | `path` plus array index `i` (`tags[3]`). |
| `jsonDecObject` | `(j: Json, path: string, depth: i64): []JsonEntry!` | The object's entries at `path`, or `TypeMismatch`/`MaxDepth`. |
| `jsonDecEntries` | `(j: Json, path: string, depth: i64): []JsonEntry!` | Same as `jsonDecObject`, named separately for a `map<string, T>` field. |
| `jsonDecUnknown` | `(entries: []JsonEntry, path: string, known: []string): ()!` | Fails `UnknownKey` on the first entry not in `known`. |
| `jsonDecMember` | `(entries: []JsonEntry, path: string, key: string): Json!` | The required member `key`, or `MissingKey`. |
| `jsonDecOptMember` | `(entries: []JsonEntry, key: string): Option<Json>` | The member `key`, or `None`. |
| `jsonDecInt`/`jsonDecIntKey`/`jsonDecIntIndex` | `(...): i64!` | The int at `path`/`key`/`i`. |
| `jsonDecFloat`/`jsonDecFloatKey`/`jsonDecFloatIndex` | `(...): f64!` | The float at `path`/`key`/`i`. |
| `jsonDecBool`/`jsonDecBoolKey`/`jsonDecBoolIndex` | `(...): bool!` | The bool at `path`/`key`/`i`. |
| `jsonDecString`/`jsonDecStringKey`/`jsonDecStringIndex` | `(...): string!` | The string at `path`/`key`/`i`. |
| `jsonDecEnumKey`/`jsonDecEnumIndex` | `(..., allowed: []string): string!` | A payload-free enum's variant name, validated against `allowed`. |
| `jsonDecArray` | `(j: Json, path: string, depth: i64): []Json!` | The array's elements at `path`. |

### Text-decode building blocks

What `jsonDecodeText<T>`'s generated decoder calls: a forward cursor
(`JsonReader`) over the source text, so a key with no escape is never
materialised as its own string.

| Symbol | Signature | What it does |
| --- | --- | --- |
| `JsonReader` | class | The cursor `jsonTextReader` builds and every function below drives. |
| `jsonTextReader` | `(src: string): JsonReader` | Starts a cursor over `src`. |
| `jsonTextFinish` | `(r: JsonReader): ()!` | Confirms nothing but whitespace follows the decoded value. |
| `jsonTextObject`/`jsonTextArray` | `(r, path: string, depth: i64): ()!` | Enters an object/array, checking the depth limit. |
| `jsonTextKey` | `(r: JsonReader, n: i64): bool!` | Advances to the next object key; `false` at `}`. |
| `jsonTextItem` | `(r: JsonReader, i: i64): bool!` | Advances to the next array element; `false` at `]`. |
| `jsonTextKeyIs` | `(r: JsonReader, key: string): bool` | Whether the current key's source bytes equal `key`. |
| `jsonTextKeyText` | `(r: JsonReader): string` | The current key, decoded. |
| `jsonTextUnknown` | `(r: JsonReader, path: string): ()!` | Fails `UnknownKey` for the current key. |
| `jsonTextNull` | `(r: JsonReader): bool` | Whether the current value is `null`. |
| `jsonTextNeed` | `(seen: bool, path: string, key: string): ()!` | Fails `MissingKey` if `seen` is `false`. |
| `jsonTextIntKey`/`jsonTextIntIndex` | `(...): i64!` | The int at the current key/index. |
| `jsonTextFloatKey`/`jsonTextFloatIndex` | `(...): f64!` | The float at the current key/index. |
| `jsonTextBoolKey`/`jsonTextBoolIndex` | `(...): bool!` | The bool at the current key/index. |
| `jsonTextStringKey`/`jsonTextStringIndex` | `(...): string!` | The string at the current key/index. |

### Lexer

A hand-written flat lexer over JSON text, used by the parser and the CST
layer below it.

| Symbol | What it is |
| --- | --- |
| `TokenKind` | `LBrace \| RBrace \| LBracket \| RBracket \| Colon \| Comma \| StringTok \| NumberTok \| TrueTok \| FalseTok \| NullTok \| Eof \| Invalid \| Comment`. |
| `Token` | One token: `kind` and its `[start, end)` byte span. |
| `jsonMaxDepth` | `const = 128` - the lexer's own `{`/`[` nesting limit. |
| `lex(source: string): []Token` | The full strict-JSON token stream, ending with `Eof`. |
| `lexCst(source: string): []Token` | Same scan, JSONC mode, with comments returned as `Comment` tokens instead of skipped. |

### The CST (concrete syntax tree)

| Symbol | What it is |
| --- | --- |
| `Trivia` | `leading`/`trailing`: verbatim text around the root node only. |
| `CstEntry` | One object entry: `keyText` (raw), `key` (decoded), `value`, `midGap` (the text between the key and the value). |
| `CstNode` | `Json` shaped, with formatting attached: `CstNull(Trivia) \| CstBool(bool, Trivia) \| CstNumber(rawText: string, Trivia) \| CstString(rawText: string, Trivia) \| CstArray([]CstNode, gaps: []Option<string>, Trivia) \| CstObject([]CstEntry, gaps: []Option<string>, Trivia)`. |
| `cstParse(source: string): CstNode!` | Parses JSONC into a `CstNode`, keeping every byte of formatting. |
| `cstGet(root: CstNode, path: []string): Option<CstNode>` | Read-only lookup, mirroring `jsonGet`. |
| `cstSetString(root, path: []string, value: string): CstNode!` | Sets a string leaf; fails if any path segment is missing or not an object. |
| `cstSetStringPath(root, path: []string, value: string): CstNode!` | Same, creating missing intermediate objects instead of failing. |
| `cstDeleteKey(root: CstNode, path: []string): CstNode!` | Removes one entry; every sibling is unchanged. |
| `cstPrint(n: CstNode): string` | Serializes back to JSONC text, byte-identical where nothing was edited. |
| `cstToJson(n: CstNode): Json` | Drops all `Trivia`, producing a plain `Json` tree. Total, never fails. |
