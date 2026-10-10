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
list, so they can never drift apart. `@json` alone needs no import from
`"std/json"` at all: the class below imports only what its own code calls.

```bit
import { jsonParse, jsonDecode, jsonEncode } from "std/json"

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

A field of type `Json` holds any JSON value untouched: an object a plugin
attached to a draft, a string, a number, `null`. It is written and read back
verbatim, with no shape of its own to check, and a document that leaves its
key out decodes to `JsonNull` instead of failing, because `Json` already
has a null. `[]Json`, `map<string, Json>` and `Option<Json>` work like the
other element types (an `Option<Json>` reads `null` as `None`):

```bit
import { Json, jsonIsNull, jsonParse, jsonDecode, jsonEncode } from "std/json"

@json class DraftExtras {
  id: string,
  extras: Json,
}

fn roundTrip(): string! {
  let d = jsonDecode<DraftExtras>(jsonParse("{\"id\":\"d1\",\"extras\":{\"pinned\":true}}")?)?
  return jsonEncode(d.toJson())
}

fn withoutExtras(): bool! {
  let d = jsonDecode<DraftExtras>(jsonParse("{\"id\":\"d2\"}")?)?
  return jsonIsNull(d.extras)
}
```

Every decode failure names the field by its full path from the root -
`addr.city`, `tags[3]` - through one of four causes: a required key is
missing, a value is the wrong JSON kind, the document has a key no field
claims, or it nests past the depth limit. Catch it and branch when you need
to:

```bit
import { jsonParse, jsonDecode, JsonDecodeError } from "std/json"

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
import { jsonDecodeText } from "std/json"

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
import { jsonSchema, jsonEncode } from "std/json"

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

## The value type

### `JsonEntry`

One `key`/`value` pair of a `JsonObject`, in source order.

### `Json`

A JSON value: `JsonNull`, `JsonBool(bool)`, `JsonInt(i64)`, `JsonFloat(f64)`,
`JsonString(string)`, `JsonArray([]Json)`, or `JsonObject([]JsonEntry)`.

### `Json.toJson(): Json`

Returns the value itself. A `@json` class has the same method, so code that
asks for `toJson(): Json` accepts a class instance or a hand-built `Json`
alike:

```bit
import { Json, JsonEntry, jsonEncode } from "std/json"

fn linkDoc(code: string): string {
  let doc = Json.JsonObject(
    []JsonEntry{ JsonEntry{ key = "code", value = Json.JsonString(code) } },
  )
  return jsonEncode(doc.toJson())
}
```

## Checking and reading a value

### `jsonIsNull(j: Json): bool`

Whether `j` is `JsonNull`.

### `jsonIsBool(j: Json): bool`

Whether `j` is a `JsonBool`.

### `jsonIsInt(j: Json): bool`

Whether `j` is a `JsonInt`.

### `jsonIsFloat(j: Json): bool`

Whether `j` is a `JsonFloat`.

### `jsonIsNumber(j: Json): bool`

Whether `j` is a `JsonInt` or a `JsonFloat`. JSON has one number type, so this
is true for either spelling.

### `jsonIsString(j: Json): bool`

Whether `j` is a `JsonString`.

### `jsonIsArray(j: Json): bool`

Whether `j` is a `JsonArray`.

### `jsonIsObject(j: Json): bool`

Whether `j` is a `JsonObject`.

### `jsonAsBool(j: Json): Option<bool>`

The payload as `Some` when `j` is a `JsonBool`, else `None`.

### `jsonAsInt(j: Json): Option<i64>`

The payload as `Some` when `j` is a `JsonInt`, else `None`.

### `jsonAsFloat(j: Json): Option<f64>`

The payload as `Some` when `j` is a `JsonFloat`, else `None`.

### `jsonAsNumber(j: Json): Option<f64>`

The payload widened to `f64` when `j` is a `JsonInt` or a `JsonFloat`, else
`None`. `3` and `3.0` are the same document to every producer on the wire, so
use this when you want an `f64` regardless of which spelling arrived;
`jsonAsFloat` alone rejects the integral spelling.

### `jsonAsString(j: Json): Option<string>`

The payload as `Some` when `j` is a `JsonString`, else `None`.

### `jsonAsArray(j: Json): Option<[]Json>`

The payload as `Some` when `j` is a `JsonArray`, else `None`.

### `jsonAsObject(j: Json): Option<[]JsonEntry>`

The object's own entries, in source order with duplicate keys kept, as `Some`
when `j` is a `JsonObject`, else `None`. Use this to walk every key of an
object whose key set you do not know ahead of time; `jsonGet` only answers
one known key at a time.

### `jsonGet(o: Json, key: string): Option<Json>`

Looks up `key` in `o`. `None` when `o` is not a `JsonObject` or `key` is
absent. On a duplicate key, returns the last matching entry.

## Parsing

A recursive-descent parser that builds a `Json` tree. Strict RFC 8259 only:
no comments, no trailing commas (see JSONC below for that). Malformed input
is a parse error through the fallible return, never a panic. An integral
literal that fits `i64` decodes to `JsonInt`; anything wider, or with a
`.`/`e`/`E`, decodes to `JsonFloat`. A duplicate object key keeps every
entry; `jsonGet`'s last-key-wins policy is what resolves it later.

Every parse error's `message()` names where it happened: a byte offset and a
1-based line:column, both counted in bytes, so a parser error and a human
reader agree on the same position.

### `jsonParse(source: string): Json!`

Parses `source` as one JSON value, optionally surrounded by whitespace and
nothing else.

### `jsoncParse(source: string): Json!`

Parses `source` as JSONC: everything `jsonParse` accepts, plus `//`/`/* */`
comments and one trailing comma before `}`/`]`. Nothing else JSON5 allows:
no unquoted keys, no hex numbers, no single-quoted strings.

## Encoding

The plain-value encoder: turns a `Json` tree into text. No formatting is
kept; see the CST section below for an editor that keeps comments and
indentation.

### `jsonEncode(j: Json): string`

The compact form: no whitespace, `,`/`:` with no padding. A non-finite float
(`inf`, `-inf`, `nan`) encodes as `null`, matching `JSON.stringify`, because
JSON has no literal for either. An integral value keeps its `.0` (`"3.0"`,
not `"3"`), which is what tells a `JsonFloat` apart from a `JsonInt` when the
text is parsed back in.

### `jsonEncodePretty(j: Json, indent: string): string`

The pretty form: one object/array element per line, `indent` repeated once
per nesting level, `": "` after each key. No trailing newline, matching the
shape of `JSON.stringify(v, null, 2)`.

### `jsonAppendRaw(out: []byte, s: string): []byte`

Appends `s` onto `out` verbatim, with no escaping, for text that is already
valid JSON, such as a nested value's own encoded bytes.

### `jsonAppendKey(out: []byte, key: string, first: bool): []byte`

Appends one object entry's separator and key onto `out`: `,` unless `first`
is `true`, then `key` escaped and quoted, then `:`.

### `jsonAppendString(out: []byte, s: string): []byte`

Appends `s` as an escaped, quoted JSON string, the same bytes `jsonEncode`
would write for `Json.JsonString(s)`.

### `jsonAppendInt(out: []byte, v: i64): []byte`

Appends `v` as a JSON number, the same bytes `jsonEncode` would write for
`Json.JsonInt(v)`.

### `jsonAppendFloat(out: []byte, v: f64): []byte`

Appends `v` as a JSON number, reshaped the same way `jsonEncode` reshapes a
`JsonFloat`.

### `jsonAppendBool(out: []byte, v: bool): []byte`

Appends `true` or `false`.

### `jsonAppendNull(out: []byte): []byte`

Appends the literal `null`.

### `jsonAppendValue(out: []byte, j: Json): []byte`

Appends the whole of `j`, the same bytes `jsonEncode(j)` returns, without
building the intermediate string. It is what `@json`'s generated encoder
calls for a field of type `Json`.

Use the `jsonAppend*` functions together when you are already writing into a
`[]byte` and want to skip building a `Json` tree first, such as generated
code that streams a document one field at a time.

## Typed decoding

### `jsonDecode<T>(j: Json): T!`

Decodes `j` into `T`, which must be a class carrying `@json`. Every failure
names the field by its full dotted path from the decoded root (`addr.city`,
`tags[3]`) and carries one of four causes: a required key is missing, a
value is the wrong JSON kind, the document has a key no field claims, or it
nests past the depth limit.

### `jsonSchema<T>(): Json`

A JSON Schema 2020-12 document describing `T` (the same dialect OpenAPI 3.1
uses for a request or response body), built from the same field list
`toJson()` uses. A scalar field maps to its `type`; `[]T` maps to `items`; a
payload-free `enum` maps to `type: "string"` plus its declared names; a
nested `@json` class maps to a reference into a shared definitions block.

### `jsonDecodeLenient<T>(j: Json): T!`

The same decode as `jsonDecode`, but ignoring keys no field of `T` claims
instead of failing on them. Reach for it only where the sender is not under
your control and a field a newer client added must not break your server; a
dropped field and an accepted one otherwise look the same to whoever sent
the document, which is why `jsonDecode` is the default.

### `jsonDecodeText<T>(src: string): T!`

Decodes the JSON text `src` straight into `T`, without building a `Json`
tree first. Reports the same four causes as `jsonDecode`, with one
difference: reading forward, it stops at the first fault it reaches in
document order, where `jsonDecode` reads the whole object first and always
reports a missing key before a type mismatch.

### `JsonDecodeCause`

Which of the four things went wrong: `MissingKey`, `TypeMismatch`,
`UnknownKey`, or `MaxDepth`.

### `JsonDecodeError`

The error every `jsonDecode<T>` failure produces: `cause`, `path` (empty for
the root value itself), and `expected`/`found`, filled in for `TypeMismatch`
and empty otherwise. Reach the fields with `e.(JsonDecodeError)`.

### `JsonDecodeError.message`

The same one-sentence summary the caught `error` reports, callable on the
narrowed value too.

### `jsonMaxDecodeDepth`

How deep a decode may recurse, 128, before it fails with `MaxDepth` instead
of exhausting the stack. A `@json` class may refer to itself, so how deep a
decode actually goes is decided by the input document, not by the class.

## Decoding building blocks

What the compiler's generated decoder calls for a `@json` class, and a
usable set of functions for a hand-written decoder over a shape `@json`
cannot cover on its own. Each scalar reader comes in three forms: the base
form takes an already-built `path`; the `...Key`/`...Index` forms take the
containing value's path plus one step, and build the joined path only when
they are about to fail.

### `jsonDecPath(path: string, key: string): string`

`path` extended by object key `key` (`addr.city`).

### `jsonDecIndex(path: string, i: i64): string`

`path` extended by array index `i` (`tags[3]`).

### `jsonDecObject(j: Json, path: string, depth: i64): []JsonEntry!`

The entries of the object at `path`, failing with `TypeMismatch` when `j` is
not an object and with `MaxDepth` past `jsonMaxDecodeDepth`.

### `jsonDecUnknown(entries: []JsonEntry, path: string, known: []string): ()!`

Fails with `UnknownKey` on the first key of `entries` that is not in
`known`.

### `jsonDecMember(entries: []JsonEntry, path: string, key: string): Json!`

The value a required field's key must carry, failing with `MissingKey` when
the key is absent or explicitly `null`.

### `jsonDecOptMember(entries: []JsonEntry, key: string): Option<Json>`

The value an optional field's key carries, or `None` when the key is absent
or present as `null`.

### `jsonDecJson(entries: []JsonEntry, key: string): Json`

The value a `Json` field's key carries, as it stands, or `JsonNull` when the
key is absent. It never fails: a field that accepts any value has no
`MissingKey`.

### `jsonDecInt(j: Json, path: string): i64!`

The integer at `path`.

### `jsonDecIntKey(j: Json, path: string, key: string): i64!`

The integer at `key` of the object at `path`.

### `jsonDecIntIndex(j: Json, path: string, i: i64): i64!`

The integer at element `i` of the array at `path`.

### `jsonDecFloat(j: Json, path: string): f64!`

The number at `path`. Accepts both numeric variants, since `3` and `3.0` are
the same document to every producer on the wire.

### `jsonDecFloatKey(j: Json, path: string, key: string): f64!`

The number at `key` of the object at `path`.

### `jsonDecFloatIndex(j: Json, path: string, i: i64): f64!`

The number at element `i` of the array at `path`.

### `jsonDecBool(j: Json, path: string): bool!`

The boolean at `path`.

### `jsonDecBoolKey(j: Json, path: string, key: string): bool!`

The boolean at `key` of the object at `path`.

### `jsonDecBoolIndex(j: Json, path: string, i: i64): bool!`

The boolean at element `i` of the array at `path`.

### `jsonDecString(j: Json, path: string): string!`

The string at `path`.

### `jsonDecStringKey(j: Json, path: string, key: string): string!`

The string at `key` of the object at `path`.

### `jsonDecStringIndex(j: Json, path: string, i: i64): string!`

The string at element `i` of the array at `path`.

### `jsonDecEnumKey(j: Json, path: string, key: string, allowed: []string): string!`

The variant name at `key` of the object at `path`, for a payload-free `enum`
field, rejecting any value not in `allowed`.

### `jsonDecEnumIndex(j: Json, path: string, i: i64, allowed: []string): string!`

The same, for element `i` of the array at `path`.

### `jsonDecArray(j: Json, path: string, depth: i64): []Json!`

The elements of the array at `path`, with the same depth bound the object
reader uses: a `[]T` counts as one level of nesting whether or not `T` is a
class.

### `jsonDecEntries(j: Json, path: string, depth: i64): []JsonEntry!`

The entries of a `map<string, T>` field's object. Distinct from
`jsonDecObject` only in intent: a map has no known key set, so nothing
checks its keys against one.

## Text-decoding building blocks

What `jsonDecodeText<T>`'s generated decoder calls: a forward cursor
(`JsonReader`) over the source text, so a key with no escape sequence is
never turned into its own string.

### `JsonReader`

The forward cursor over one document. Build one with `jsonTextReader`.

### `jsonTextReader(src: string): JsonReader`

A reader positioned on `src`'s first token.

### `jsonTextFinish(r: JsonReader): ()!`

Fails unless nothing but whitespace follows the decoded value.

### `jsonTextObject(r: JsonReader, path: string, depth: i64): ()!`

Enters the object under the cursor, failing with `TypeMismatch` when the
value is not an object and with `MaxDepth` past `jsonMaxDecodeDepth`.

### `jsonTextArray(r: JsonReader, path: string, depth: i64): ()!`

The same for an array.

### `jsonTextKey(r: JsonReader, n: i64): bool!`

Advances to the `n`th member's value and records its key on the reader;
`false` once the object has closed.

### `jsonTextItem(r: JsonReader, i: i64): bool!`

Advances to the next array element; `false` once the array has closed.

### `jsonTextKeyIs(r: JsonReader, key: string): bool`

Whether the current member's key is `key`, comparing source bytes in place
so trying several field names in turn allocates nothing.

### `jsonTextKeyText(r: JsonReader): string`

The current member's key as a string. Use this only where the key itself is
data, such as a `map<string, T>`'s key.

### `jsonTextUnknown(r: JsonReader, path: string): ()!`

Fails with `UnknownKey` naming the current member's key.

### `jsonTextNull(r: JsonReader): bool`

Consumes an explicit `null` under the cursor and reports whether it found
one.

### `jsonTextValue(r: JsonReader): Json!`

The whole value under the cursor (object, array or scalar) as a `Json`,
consumed. It is how a `Json` field is read off the text; a malformed value
fails with the same positional error `jsonParse` gives.

### `jsonTextEnumKey(r: JsonReader, path: string, key: string, allowed: []string): string!`

The variant name under the cursor, consumed and checked against `allowed`.
An unknown name fails exactly as `jsonDecEnumKey` does, with the field's path
and the full list, so decoding from text and from a `Json` tree agree.

### `jsonTextEnumIndex(r: JsonReader, path: string, i: i64, allowed: []string): string!`

The same, for an array element.

### `jsonTextNeed(seen: bool, path: string, key: string): ()!`

Fails with `MissingKey` at `path`.`key` when `seen` is `false`. This is the
check a required field owes once the whole object has been walked, since a
forward reader cannot know a key never appeared until the object closes.

### `jsonTextIntKey(r: JsonReader, path: string, key: string): i64!`

The integer under the cursor, consumed.

### `jsonTextIntIndex(r: JsonReader, path: string, i: i64): i64!`

The same, for an array element.

### `jsonTextFloatKey(r: JsonReader, path: string, key: string): f64!`

The number under the cursor, consumed. Accepts an integer literal too.

### `jsonTextFloatIndex(r: JsonReader, path: string, i: i64): f64!`

The same, for an array element.

### `jsonTextBoolKey(r: JsonReader, path: string, key: string): bool!`

The boolean under the cursor, consumed.

### `jsonTextBoolIndex(r: JsonReader, path: string, i: i64): bool!`

The same, for an array element.

### `jsonTextStringKey(r: JsonReader, path: string, key: string): string!`

The string under the cursor, consumed, with every escape decoded.

### `jsonTextStringIndex(r: JsonReader, path: string, i: i64): string!`

The same, for an array element.

## The lexer

A hand-written flat lexer over JSON text, used by the parser and the CST
layer below it. No regular expressions and no recursion: brace/bracket
nesting is tracked with a counter, so a pathologically deep input yields an
`Invalid` token instead of a stack overflow.

### `TokenKind`

The lexical categories a token can be: `LBrace`, `RBrace`, `LBracket`,
`RBracket`, `Colon`, `Comma`, `StringTok`, `NumberTok`, `TrueTok`,
`FalseTok`, `NullTok`, `Eof`, `Invalid`, `Comment`. `Comment` is only ever
produced by `lexCst`.

### `Token`

One token: its `kind`, and its `[start, end)` byte span in the source.

### `jsonMaxDepth`

The combined `{`/`[` nesting limit: 128 levels. Opening a 129th level yields
an `Invalid` token rather than tracking it.

### `lex(source: string): []Token`

The full token stream for `source`, ending with one `Eof`.

### `lexCst(source: string): []Token`

The same scanner and grammar as `lex`, JSONC mode, except a `//`/`/* */`
comment comes back as a `Comment` token instead of being skipped.

## The CST (concrete syntax tree)

A tree shaped like `Json`, but every node also carries the comments and
blank lines around it, so an editing layer can change one value and print
the rest of the document back out byte-identical.

### `Trivia`

`leading`/`trailing`: verbatim source text (comments and whitespace
together) before and after the root node's own text. Empty on every
non-root node, since a non-root node's surrounding formatting belongs to
its parent container instead.

### `CstEntry`

One key/value pair of a `CstObject`, in source order: `keyText` is the raw
source text of the key including its quotes; `key` is the decoded key
string, for lookups; `midGap` is the verbatim text between the key's
closing quote and the value's first token.

### `CstNode`

A `Json` value together with the `Trivia` around it: `CstNull(Trivia)`,
`CstBool(bool, Trivia)`, `CstNumber(rawText: string, Trivia)`,
`CstString(rawText: string, Trivia)`, `CstArray([]CstNode, gaps:
[]Option<string>, Trivia)`, or `CstObject([]CstEntry, gaps:
[]Option<string>, Trivia)`. A container's `gaps` holds one raw-text boundary
per child plus one, for the comments, indentation and commas between them.

### `cstParse(source: string): CstNode!`

Parses `source` as JSONC into the tree above, losslessly: every byte of
formatting, comments, indentation, blank lines and comma placement,
survives the round trip.

### `cstGet(root: CstNode, path: []string): Option<CstNode>`

Read-only lookup of `path` under `root`, mirroring `jsonGet` but over the
CST. `None` as soon as an intermediate segment is not a `CstObject` or a key
is missing, never a panic on an absent path.

### `cstSetString(root: CstNode, path: []string, value: string): CstNode!`

Sets the string value at `path` to `value`. If `path` resolves to an
existing string entry, only its raw text is replaced. Fails if the value at
the final key is not a string, or any intermediate segment is not an
object; this function never creates an intermediate object.

### `cstSetStringPath(root: CstNode, path: []string, value: string): CstNode!`

The same as `cstSetString`, except a missing intermediate object along
`path` is created instead of failing, for a first-ever entry under a key
that does not exist yet.

### `cstDeleteKey(root: CstNode, path: []string): CstNode!`

Removes the entry at `path` from its parent's entries. Every sibling entry
keeps its own value and relative order unchanged. Fails if any path segment
does not exist, or an intermediate segment is not an object.

### `cstPrint(n: CstNode): string`

Serializes `n` back to JSONC source text. For any node an edit function did
not touch, this reproduces the original input byte-for-byte; for a node an
edit function replaced, only the new text takes the old one's place, with
everything around it unchanged.

### `cstToJson(n: CstNode): Json`

Strips every `Trivia` and decodes each raw span, turning a CST into a plain
`Json` tree. Cannot fail, since every span it decodes was already validated
once when `cstParse` built the tree. Use this when a caller only wants the
values and does not need the CST shape at all: parse with `cstParse`,
project with `cstToJson`, then read the result with `jsonGet`/`jsonAsX`
like any other document.
