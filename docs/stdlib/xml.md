# std/xml

Inkwell imports drafts from an Atom feed, and the feed comes from a server
you do not control. Reading it with string searches works until a title
holds `&amp;` or a CDATA section, and a real XML parser that follows
`<!DOCTYPE` references can be made to read local files or to eat all your
memory with a few hundred bytes of nested entities. `std/xml` is a pull
tokenizer for XML 1.0 that has neither problem: it decodes what documents
legitimately contain, and it refuses the rest, loudly, with the position.

You create a `Tokenizer` over the document bytes and call `next()` until it
returns `Eof`. Each call gives you one `Token`: a start tag, an empty tag,
an end tag, a run of text, or a CDATA section. Comments and processing
instructions are read and dropped. The five predefined entities
(`&lt;` `&gt;` `&amp;` `&quot;` `&apos;`) and numeric character references
(`&#65;`, `&#x41;`) are already decoded in the text and attribute values you
get back.

<!-- doctest: per-block -->

## The simplest thing: collect the titles

```bit
import { Tokenizer, Token } from "std/xml"

fn titles(feed: string): []string! {
  let tz = Tokenizer([]byte(feed))?
  let out = []string(0)
  let inTitle = false
  let done = false
  while (!done) {
    let t = tz.next()?
    match (t) {
      Start(tag) => inTitle = tag.name == "title"
      End(name) => inTitle = false
      Text(s) => {
        if (inTitle) {
          out = append(out, s)
        }
      }
      Eof => done = true
      _ => {}
    }
  }
  return out
}
```

`titles("<feed><entry><title>Tea &amp; toast</title></entry></feed>")`
returns `["Tea & toast"]`. The `?` after `next()` matters: the first
malformed byte ends the loop with an error instead of a half-read feed.

## Attributes

A start or empty tag carries a `Tag`: the element `name` and its `attrs`,
a list of `Attr` with `name` and `value`, in document order. Values are
decoded, and white space inside them is normalised the way XML says: a
literal tab, line feed or carriage return becomes one space, while a
character reference such as `&#10;` stays a line feed.

```bit
import { Tokenizer, Token, Tag, Attr } from "std/xml"

fn attribute(doc: string, element: string, name: string): string! {
  let tz = Tokenizer([]byte(doc))?
  let done = false
  while (!done) {
    let t = tz.next()?
    match (t) {
      Start(tag) => {
        let found = findAttr(tag, element, name)
        if (found != "") {
          return found
        }
      }
      Empty(tag) => {
        let found = findAttr(tag, element, name)
        if (found != "") {
          return found
        }
      }
      Eof => done = true
      _ => {}
    }
  }
  return ""
}

fn findAttr(tag: Tag, element: string, name: string): string {
  if (tag.name != element) {
    return ""
  }
  let i = 0
  while (i < len(tag.attrs)) {
    let a: Attr = tag.attrs[i]
    if (a.name == name) {
      return a.value
    }
    i = i + 1
  }
  return ""
}
```

Names are not split on `:`. `s3:Foo` is the name `s3:Foo`, and `xmlns:s3` is
an ordinary attribute.

## Text, CDATA and white space

`Text` is character data with its references decoded and its line ends read
as a single line feed (`\r\n` and a lone `\r` both become `\n`). A
`<![CDATA[...]]>` section comes back as a separate `CData` token, verbatim,
because nothing inside it is markup. Text between elements, such as the
indentation in a pretty-printed document, is delivered as `Text` too: the
tokenizer cannot know whether it matters to you.

Only a character reference produces a carriage return. A key stored as
`a&#13;b` reads back as `a`, CR, `b`; a literal CR in the document would have
read as a line feed.

## Hostile documents

A document from the network is hostile until proven otherwise, and the
tokenizer is built so that it does not matter:

- `<!DOCTYPE` is refused the moment it is seen, with `XmlErrorKind.Doctype`.
  There is no DTD support to switch off, so a document cannot make the
  tokenizer open a file or a URL (the external-entity attack) or expand an
  entity into other entities (the billion-laughs attack). An `&name;` that is
  not one of the five predefined entities fails with `BadReference`.
- Nothing is repaired. A mismatched tag, an unclosed element, a duplicate
  attribute, an unquoted attribute value, `--` inside a comment, `]]>` in
  text, a control character, or a character reference to a character XML
  forbids (`&#0;`, a surrogate) ends the document with an error.
- After the first error, every later `next()` returns that same error. A
  caller that ignores a failure cannot go on to read a partial document as a
  whole one.
- Depth, attributes per element and input size are bounded. The options of
  `Tokenizer(...)` set them: `maxDepth` (default 256), `maxAttrs` (default
  256) and `maxInput` (default 64 MiB). A document over a bound fails with
  `TooDeep`, `TooManyAttributes` or `TooLarge`; a bound below 1 fails
  construction with `BadLimit`.
- A document whose bytes the tokenizer would misread is refused rather than
  guessed at: an XML declaration for a version other than 1.0, an encoding
  other than UTF-8 or US-ASCII, or a UTF-16 byte-order mark all fail with
  `Unsupported`.

```bit
import { Tokenizer, Token, XmlError, XmlErrorKind } from "std/xml"

fn firstProblem(doc: string): string {
  let tz = Tokenizer([]byte(doc)) catch err {
    return err.message()
  }
  let done = false
  while (!done) {
    let t = tz.next() catch err {
      let (e, ok) = err.(XmlError)
      if (ok) {
        match (e.kind) {
          Doctype => return "refused: DOCTYPE at byte ${e.offset}"
          _ => return e.message()
        }
      }
      return err.message()
    }
    match (t) {
      Eof => done = true
      _ => {}
    }
  }
  return "ok"
}
```

`firstProblem("<!DOCTYPE a [<!ENTITY x SYSTEM \"file:///etc/passwd\">]><a>&x;</a>")`
is `"refused: DOCTYPE at byte 0"`. A document that nests `<a>` 257 deep gives
`xml: elements nest deeper than the limit of 256 at line 1, column 769`.

## Sharp edges

- **Every error message starts with `xml:`** and ends with `at line L, column
  C`, counting bytes. `xml: end tag </a> does not close <b> at line 1, column
  7` means an `</a>` arrived while `<b>` was the open element.
- **The whole document is in memory.** `Tokenizer` takes the bytes of a
  document you already hold, up to `maxInput`. It is not a streaming reader.
- **There is no schema, no namespace resolution and no validation.** A
  document that is well formed is accepted whatever its element names.

## When not to use std/xml

If you want a tree you can ask for `child("Name")` and `text()`, build it on
top of the tokens; this module is the layer below that. For JSON use
[std/json](json.md).

## Where to go next

[std/json](json.md) is the sibling data format; [std/strings](strings.md)
covers the text helpers you will use on the values you get back.

## Reference

### `Tokenizer`

`Tokenizer(src: []byte, maxDepth: int = 256, maxAttrs: int = 256, maxInput:
int = 67108864)` reads the document `src`. Fails with `BadLimit` for a limit
below 1 and `TooLarge` for an input longer than `maxInput`, before reading
anything. Call it with `?` or `catch`.

### `Tokenizer.next`

`next(): Token!` returns the next token, `Eof` once the root element has
closed and the input is spent (and on every call after that), or an
`XmlError`. After an error, returns that same error every time.

### `Token`

One unit of a document: `Start(Tag)`, `Empty(Tag)` (an `<a/>` with no `End`
after it), `End(string)` (the element name), `Text(string)`,
`CData(string)`, and `Eof`.

### `Tag`

The element `name` and its `attrs`, a list of `Attr` in document order with
no duplicate names.

### `Attr`

One attribute: `name` and `value`, the value decoded and normalised.

### `XmlErrorKind`

Why a document was refused: `Doctype`, `UnexpectedEof`, `MismatchedTag`,
`BadName`, `BadAttribute`, `DuplicateAttribute`, `BadReference`,
`BadComment`, `BadChar`, `Syntax`, `TooDeep`, `TooManyAttributes`,
`TooLarge`, `Unsupported` and `BadLimit`.

### `XmlError`

The error every failure produces: `kind`, `offset` (byte offset of the
construct that failed), `line` and `column` (1-based, columns count bytes),
and `reason`, one phrase saying what was wrong. Reach the fields with
`e.(XmlError)`.

### `XmlError.message`

The one-sentence summary the caught `error` reports, callable on the
narrowed value too.
