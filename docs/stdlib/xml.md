# std/xml

Inkwell imports drafts from an Atom feed, and the feed comes from a server
you do not control. Reading it with string searches works until a title
holds `&amp;` or a CDATA section, and a real XML parser that follows
`<!DOCTYPE` references can be made to read local files or to eat all your
memory with a few hundred bytes of nested entities. `std/xml` is a pull
tokenizer for XML 1.0 that has neither problem: it decodes what documents
legitimately contain, and it refuses the rest, loudly, with the position.
The same module writes XML with a `Writer` that cannot produce a malformed
document, and reads it into an `Element` tree you can ask for
`child("Name")` and `text()`.

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
- Depth, attributes per element, name length and input size are bounded. The
  options of `Tokenizer(...)` set them: `maxDepth` (default 256), `maxAttrs`
  (default 256), `maxInput` (default 64 MiB) and `maxName` (default 1024
  bytes, for an element or attribute name). A document over a bound fails
  with `TooDeep`, `TooManyAttributes`, `TooLarge` or `NameTooLong`; a bound
  below 1 fails construction with `BadLimit`. `TooLarge` is raised by
  `Tokenizer(...)` itself, before a byte is read; the others by the `next()`
  that reaches the offender.
- The bytes must be well-formed UTF-8 and every character in the XML 1.0
  `Char` range. A stray continuation byte, a truncated or overlong sequence,
  a surrogate or a value above U+10FFFF fails with `BadEncoding`; U+FFFE,
  U+FFFF and the control characters other than tab, line feed and carriage
  return fail with `BadChar`. The same check covers text, attribute values,
  comments, CDATA sections, processing instructions and names, and a name's
  non-ASCII characters must be ones XML 1.0 (fifth edition) allows in a name.
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
- **The tokenizer has no schema, no namespace resolution and no validation.**
  A document that is well formed is accepted whatever its element names, and
  `s3:Key` is the name `s3:Key`. Namespaces are resolved by `parse`, below.

## Writing XML

Inkwell also sends XML: a multipart upload to S3 ends with a
`CompleteMultipartUpload` body listing every part. Building that body with
string concatenation works until an ETag or a title holds `&`, `<` or a
control character, and then the server rejects the request, or reads
something other than what you wrote. A `Writer` makes that impossible: it
escapes what must be escaped and refuses what no escape can fix.

You create a `Writer`, open elements with `start`, write character data
with `text`, close with `end`, write an element with no content with
`empty`, and take the bytes from `finish`.

```bit
import { Writer, Attr } from "std/xml"

fn completeBody(etags: []string): string! {
  let w = Writer()?
  let ns = "http://s3.amazonaws.com/doc/2006-03-01/"
  let root = append([]Attr(0), Attr{ name = "xmlns", value = ns })
  w.start("CompleteMultipartUpload", root)?
  let i = 0
  while (i < len(etags)) {
    w.start("Part")?
    w.start("PartNumber")?
    w.text("${i + 1}")?
    w.end()?
    w.start("ETag")?
    w.text(etags[i])?
    w.end()?
    w.end()?
    i = i + 1
  }
  w.end()?
  return string(w.finish()?)
}
```

`completeBody(["\"a54357aff0632cce46d942af68356b38\""])` returns
`<CompleteMultipartUpload xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Part><PartNumber>1</PartNumber><ETag>"a54357aff0632cce46d942af68356b38"</ETag></Part></CompleteMultipartUpload>`.
There is no indentation and no XML declaration: the output is the document
and nothing else, the form a signed request body needs.

### Escaping

Text escapes `&`, `<` and `>` (so `]]>` can never appear) and carriage
return, which a parser would otherwise read as a line feed. An attribute
value also escapes `"`, and writes tab, line feed and carriage return as
`&#9;`, `&#10;` and `&#13;`, because a parser turns a literal one into a
space. What the `Tokenizer` reads back is exactly what you wrote.

### What it refuses

A string with a character XML cannot carry, a NUL or another control
character, `U+FFFE`, or bytes that are not valid UTF-8, fails with
`BadChar`, and nothing of it is written: a character reference cannot carry
those characters either, so there is nothing to escape them to. A name that
is not an XML name fails with `BadName`. `end()` with nothing open fails with
`MismatchedTag`. Text outside the root, or a second root, fails with
`Syntax`. `finish()` while an element is still open, or before a root was
written, fails with `UnexpectedEof`. A repeated attribute fails with
`DuplicateAttribute`.

Like the tokenizer, the first failure is final: every later call returns the
same error, so an ignored failure cannot turn into a finished document.
`offset` in the `XmlError` is the number of bytes written when it happened.

### Namespaces

A namespace declaration is an attribute named `xmlns` or `xmlns:prefix`, in
scope for the element that carries it, its own name and attributes included,
and for everything inside it.

```bit
import { Writer, Attr } from "std/xml"

fn grantee(): string! {
  let w = Writer()?
  let xsi = "http://www.w3.org/2001/XMLSchema-instance"
  let attrs = append([]Attr(0), Attr{ name = "xmlns:xsi", value = xsi })
  attrs = append(attrs, Attr{ name = "xsi:type", value = "Group" })
  w.empty("Grantee", attrs)?
  return string(w.finish()?)
}
```

A prefixed name must use a prefix that is in scope, or the call fails with
`BadName`; `xml` is always in scope. Two attributes with the same namespace
and local name are refused even under different prefixes. The reserved
`xmlns` prefix is never bound, `xml` only to its own namespace, and no
prefix to an empty namespace; those fail with `BadAttribute`.

### Limits

`Writer(maxDepth = 256, maxAttrs = 256)` bounds how deeply elements nest
and how many attributes one element carries; going over fails with `TooDeep`
or `TooManyAttributes`. A limit below 1 fails with `BadLimit`.

## Reading a document as a tree

Inkwell stores its drafts in an S3 bucket and lists them with a
`ListBucketResult`. Pulling tokens and tracking which element you are in is
the wrong shape for that: you want "the `Key` of every `Contents`". `parse`
reads the whole document into an `Element`, with the namespaces resolved and
the entities decoded, and you walk it with `child`, `children` and `text`.

```bit
import { parse, Element } from "std/xml"

fn draftKeys(body: string): []string! {
  let root = parse([]byte(body))?
  let keys = []string(0)
  let items = root.children("Contents")
  let i = 0
  while (i < len(items)) {
    match (items[i].child("Key")) {
      Some(k) => keys = append(keys, k.text())
      None => {}
    }
    i = i + 1
  }
  return keys
}
```

For a body whose root is `<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">`
holding two `<Contents><Key>...</Key></Contents>`, `draftKeys` returns the two
keys. A key stored as `a&#13;b` comes back as `a`, CR, `b`, because the
decoding is the tokenizer's. The default namespace on the root is inherited by
every element under it, and `child("Key")` still finds `Key` there: a name you
pass is a local name, and matches in whatever namespace the child is in.

`parse(src: []byte, maxDepth = 256, maxAttrs = 256, maxInput = 67108864,
maxName = 1024): Element!` takes the same limits as `Tokenizer(...)`, and
refuses everything it refuses, with the same `XmlError` kinds. The tree is
built with a stack, so a deep document costs memory, never call stack.

### What an element holds

An `Element` has the qualified `name` as written (`s3:Key`), its `local` part
(`Key`), the namespace URI `space` the name resolves to (`""` for none), its
`attrs` as written, and its `nodes`: the content in document order, each a
`Node` that is either `Node.Elem(Element)` or `Node.Text(string)`. Comments
and processing instructions are not in `nodes` (an element keeps them on the
side, for `canonicalizeExclusive` below), and a CDATA section is text.
Adjacent text and CDATA are one `Node.Text`. White space between elements is
kept, because only you know whether it matters; `child` and `children` skip
it, and `text()` is the join of an element's own text nodes, so for
`<a>x<b>y</b>z</a>` it is `xz`.

Because `attrs` and `name` are kept as written, an element can be handed back
to a `Writer` and come out as it went in:

```bit
import { parse, Element, Node, Writer } from "std/xml"

fn copyTo(w: Writer, e: Element): ()! {
  w.start(e.name, e.attrs)?
  let i = 0
  while (i < len(e.nodes)) {
    match (e.nodes[i]) {
      Elem(c) => copyTo(w, c)?
      Text(s) => w.text(s)?
    }
    i = i + 1
  }
  w.end()?
}

fn normalise(body: string): string! {
  let w = Writer()?
  copyTo(w, parse([]byte(body))?)?
  return string(w.finish()?)
}
```

`normalise` drops the `<?xml ?>` line and comments and writes an empty element
as `<a></a>`; everything else, the indentation included, comes back byte for
byte. The four S3 bodies the tests pin (`ListBucketResult`, `Error`,
`CompleteMultipartUploadResult`, `LifecycleConfiguration`) do.

### Namespaces and attributes

An element's namespace is the one its prefix is bound to, or the default
namespace (`xmlns="..."`) when it has no prefix, scoped to the element that
declares it and everything inside. `xmlns=""` takes the default away again. An
attribute without a prefix is in no namespace; it does not inherit the default
one. That is why S3's `<Grantee xsi:type="Group">` is read with the namespace
named, and an `id` with none:

```bit
import { parse, Element } from "std/xml"

fn granteeType(body: string): string! {
  let xsi = "http://www.w3.org/2001/XMLSchema-instance"
  let root = parse([]byte(body))?
  match (root.child("Grantee")) {
    Some(g) => {
      match (g.attr("type", xsi)) {
        Some(t) => return t
        None => return unwrapOr(g.attr("id"), "none")
      }
    }
    None => return "no grantee"
  }
}
```

`child(name, space)` and `children(name, space)` take the namespace as a typed
option, the same method either way: `child("Key")` matches any namespace and
`child("Key", Option<string>.Some(uri))` only `uri`, with `Some("")` meaning
no namespace. `attr(name, space = "")` matches the namespace exactly, so
`attr("type")` does not find `xsi:type`. A name that is empty or has a colon
can never be a local name, so `child`, `children` and `attr` panic on one:
that is a mistake in your code, not something a document can cause.

### What `parse` refuses beyond the tokenizer

Namespaces are checked, not assumed. A prefix with no declaration in scope
(`<p:a/>`) fails with `BadName` instead of producing an element in no
namespace; so does a name with two colons or an empty side. Two attributes with
the same namespace and local name fail with `DuplicateAttribute` even under
different prefixes. `xmlns` is never bound, `xml` only to its own namespace,
and no prefix to an empty one; those fail with `BadAttribute`. The `XmlError`
offset is the start of the tag that broke the rule.

## Canonicalizing an element for a signature

Inkwell accepts sign-in assertions from an identity provider as SAML: an XML
document whose `Assertion` element carries an XML signature. The signature is
not over the bytes you received. The provider's proxy may have re-indented the
envelope, added a namespace declaration, or turned `<a/>` into `<a></a>`, and
the signature still has to verify. So both sides first rewrite the signed
element into one canonical byte string, and sign or check a digest of that.
The rewrite is Exclusive XML Canonicalization 1.0, and a verifier that differs
from the signer by one byte rejects a good assertion or, worse, accepts a bad
one. `canonicalizeExclusive` is that rewrite.

```bit
import { parse, Element, C14nOptions, canonicalizeExclusive } from "std/xml"

fn signedBytes(doc: []byte): string! {
  let root = parse(doc)?
  match (root.child("Assertion")) {
    Some(a) => return string(canonicalizeExclusive(a, C14nOptions{})?)
    None => fail newError("no Assertion element")
  }
}
```

For `<Response xmlns:saml="urn:a" xmlns:xs="urn:x"><saml:Assertion ID="_1"
xmlns:saml="urn:a">  <saml:Subject/></saml:Assertion></Response>`, `signedBytes`
is `<saml:Assertion xmlns:saml="urn:a" ID="_1">  <saml:Subject></saml:Subject></saml:Assertion>`.
The element is written standalone, as it would be wherever it sits in its
document: `xmlns:xs` is not there, because nothing in the assertion uses it.
Cut out of its envelope and signed alone, the assertion gives the same bytes,
and that is what "exclusive" buys.

The rules, in the order a verifier trips over them:

- A namespace declaration is written on an element only if that element or one
  of its attributes uses the prefix (the default namespace counts for an element
  with no prefix, never for an attribute), and only if the output does not
  already bind that prefix to that URI. A declaration nothing uses disappears;
  a prefix redeclared to the same URI further down is not repeated; one
  redeclared to a different URI is written again, and `xmlns=""` is written
  where an element in no namespace sits under one in a namespace.
- Declarations come first, the default one first and the rest by prefix, then
  the attributes by namespace URI and then local name, an attribute in no
  namespace first. The order is by bytes, which is code point order, and not by
  prefix: `b:attr` can come before `a:attr`.
- Every element is a start tag and an end tag, there is no XML declaration, and
  white space is never added or removed.
- Attribute values are written in double quotes with `&amp;` `&lt;` `&quot;`
  `&#x9;` `&#xA;` `&#xD;` escaped; text has `&amp;` `&lt;` `&gt;` and `&#xD;`.
  Nothing else is touched. CDATA sections and character references come out as
  the characters they stand for, and a CR LF in the source is one LF.
- `xml:lang` and `xml:space` are written where they are and never copied from
  an ancestor.
- Processing instructions are kept (`<?pi data?>`). Comments are dropped,
  unless `withComments` is set.

Two things in a signature profile change the result, and both are options.
`C14nOptions.withComments` is the `#WithComments` variant of the algorithm.
`C14nOptions.inclusivePrefixes` is the `PrefixList` of the `InclusiveNamespaces`
element: namespaces your signature profile wants written whether or not they
are used, because a value inside the document (a QName in text, an XPath in an
attribute) depends on them.

```bit
import { parse, C14nOptions, canonicalizeExclusive } from "std/xml"

fn withPayloadPrefixes(doc: []byte): string! {
  let root = parse(doc)?
  let opts = C14nOptions{
    inclusivePrefixes = ["xs", "#default"],
    withComments = true,
  }
  return string(canonicalizeExclusive(root, opts)?)
}
```

`#default` is the default namespace. A prefix that is not in scope on an
element is skipped there, and a name that cannot be a prefix is an error.

### Sharp edges

- Only the element is written. A comment or processing instruction before or
  after the root of the document is not inside any element, and `parse` drops
  it, so a signature profile that covers the whole document (an enveloped
  signature over `""`) has to be handled with the element in hand.
- A relative namespace URI (`xmlns:a="../x"`) fails: Canonical XML 1.0 requires
  an implementation to refuse it, because its meaning would depend on a base
  URI the canonical form does not carry.
- `parse` refuses a `DOCTYPE`, so a document that needs a DTD to canonicalize
  (default attributes, entities, ID-typed attribute normalization) never
  reaches this function.
- This is the exclusive algorithm only. Inclusive Canonical XML writes every
  namespace in scope, and is not offered.

## Verifying a signed assertion

Canonical bytes are half of a signature check. Inkwell's sign-in comes back
as a SAML response, and the attack to fear is signature wrapping: the
signature is valid over one element, and the application reads another one.
An attacker keeps the provider's signed assertion, puts it somewhere the
verifier will find it, and writes their own assertion where the application
looks. Every step passes, and the wrong person is signed in.
`verifySignature` closes that by what it returns. It does not say "valid"; it
gives you the element whose bytes were verified, and you read that and never
look anything up in the document again.

```bit
import { parse, verifySignature, DsigKey, DsigOptions, SignedElement } from "std/xml"
import { RsaPublicKey } from "std/crypto"

// The email of the user the identity provider signed in, from the assertion
// the provider's signature covers. `idp` comes from the provider's metadata.
fn signedInUser(body: []byte, idp: RsaPublicKey): string! {
  let doc = parse(body)?
  let opts = DsigOptions{ expectRoot = "{urn:oasis:names:tc:SAML:2.0:assertion}Assertion" }
  let signed: SignedElement = verifySignature(doc, DsigKey.Rsa(idp), opts)?
  match (signed.element.child("Subject")) {
    Some(s) => {
      match (s.child("NameID")) {
        Some(n) => return n.text()
        None => fail newError("assertion ${signed.id} has no NameID")
      }
    }
    None => fail newError("assertion ${signed.id} has no Subject")
  }
}
```

The key is yours. `DsigKey.Rsa` or `DsigKey.Ecdsa` is the provider's public
key from metadata you trust, and the `KeyInfo` in the document is never read:
a document cannot bring the key that verifies it. RSA keys under 2048 bits and
ECDSA keys that are not P-256 are refused.

`expectRoot` names the element the signature must cover, as
`{namespace-uri}local` (or a bare `local` for no namespace). Leave it empty
and the signed element must be `doc` itself, which is how a signed `Response`
is checked. With a name, the signed element may sit anywhere in `doc`, but it
must be the only element with that name: the second `Assertion` that a
wrapping attack has to add is a failure, not something to pick between. A
response that really carries several assertions is checked one assertion at a
time, by passing each `Assertion` element as `doc`.

Everything else in the signature profile is fixed, and anything outside it
fails with the rule that was broken:

- Exactly one `ds:Signature` in `doc`, and one `Reference` in it,
  `URI="#id"`. The element holding the signature is the signed element, and
  its `ID`, `Id` or `id` attribute is that `id`. No ID value occurs twice
  anywhere in `doc` (`ID`, `Id`, `id` and `xml:id` all count).
- Transforms are the enveloped-signature transform, then Exclusive C14N 1.0,
  and nothing else: no XPath, no XSLT, no decryption transform. The
  canonicalization method is Exclusive C14N 1.0, not the inclusive form and
  not `#WithComments`.
- The digest is SHA-256, compared in constant time; SHA-1 only with
  `DsigOptions.allowSha1`, for a provider that has not moved yet. The signature
  method is `rsa-sha256` or `ecdsa-sha256` and must match the kind of key; a
  SHA-1 signature method is never accepted. An ECDSA value is `r || s`, 32
  bytes each, not DER.
- `Signature` holds `SignedInfo`, `SignatureValue` and an optional `KeyInfo`.
  No `Object`, no text between them, no comment or processing instruction
  inside.
- A document within `maxElements` (100000), `maxDepth` (256) and
  `maxSignatureBytes` (1024) in `DsigOptions`.

```bit
import { parse, verifySignature, DsigKey, DsigOptions } from "std/xml"
import { EcdsaPublicKey } from "std/crypto"

// A provider still on SHA-1 digests, signing with an ECDSA key, and a body that
// must stay small.
fn legacyProvider(body: []byte, idp: EcdsaPublicKey): string! {
  let opts = DsigOptions{
    allowSha1 = true,
    maxElements = 5000,
    maxDepth = 64,
    maxSignatureBytes = 128,
  }
  let signed = verifySignature(parse(body)?, DsigKey.Ecdsa(idp), opts)?
  return signed.id
}
```

### Sharp edges

- Read `SignedElement.element`, never `doc`. It is a copy of the signed element
  with the `Signature` child cut out (the enveloped-signature transform), and
  canonicalizing it gives the digested bytes. A lookup in `doc` by ID or name
  can be redirected by whoever built `doc`; this cannot.
- `Element.text()` joins the text of an element and skips comments. The
  signature covers the text with the comments removed, so a value your
  application reads from `element` is the one that was signed; `parse` still
  keeps the comment, which is why `Signature` itself refuses any.
- The verifier checks a signature, not a policy. Issuer, audience,
  `NotOnOrAfter`, replay and the `Destination` are yours to check on
  `element`.
- A failure says which rule broke and is for your log. Do not send it to the
  client.

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

### `Writer`

`Writer(maxDepth: int = 256, maxAttrs: int = 256)` starts an empty document.
Fails with `BadLimit` for a limit below 1.

### `Writer.start`

`start(name: string, attrs: []Attr = [])!` opens the element `name`. The
namespace declarations among `attrs` are in scope for the element itself.

### `Writer.empty`

`empty(name: string, attrs: []Attr = [])!` writes `<name .../>`.

### `Writer.text`

`text(s: string)!` writes `s` as escaped character data inside the open
element.

### `Writer.end`

`end()!` closes the open element.

### `Writer.finish`

`finish(): []byte!` returns the finished document, and takes no more input
afterwards.

### `parse`

`parse(src: []byte, maxDepth: int = 256, maxAttrs: int = 256, maxInput: int =
67108864, maxName: int = 1024): Element!` reads the document `src` into its
root `Element`. Fails with what `Tokenizer(...)` and `Tokenizer.next` fail
with, and with the namespace errors above.

### `Element`

One element: `name`, `local`, `space`, `attrs` (a `[]Attr` as written, `xmlns`
declarations included) and `nodes` (a `[]Node`).

### `Node`

One unit of an element's content: `Elem(Element)` or `Text(string)`.

### `Element.child`

`child(name: string, space: Option<string> = None): Option<Element>` is the
first child element whose local name is `name`, in any namespace when `space`
is `None`. Panics for a `name` that is empty or has a colon.

### `Element.children`

`children(name: string, space: Option<string> = None): []Element` is every
such child in document order; empty when there are none.

### `Element.text`

`text(): string` is the element's own text nodes joined, child elements left
out.

### `Element.attr`

`attr(name: string, space: string = ""): Option<string>` is the value of the
attribute with local name `name` in namespace `space`; the empty `space` means
no namespace.

### `canonicalizeExclusive`

`canonicalizeExclusive(root: Element, opts: C14nOptions = C14nOptions{}):
[]byte!` is `root` and its content in Exclusive XML Canonicalization 1.0 form,
as UTF-8. Fails for a relative namespace URI in the subtree and for an
`inclusivePrefixes` entry that is not `#default` or a prefix. Never panics on
an `Element` that `parse` returned.

### `C14nOptions`

`C14nOptions{ inclusivePrefixes, withComments }`: `inclusivePrefixes` is a
`[]string` of prefixes (`#default` for the default namespace) whose declarations
in scope are written on every element; empty by default. `withComments` is a
`bool`, false by default, that keeps comments.

### `verifySignature`

`verifySignature(doc: Element, key: DsigKey, opts: DsigOptions =
DsigOptions{}): SignedElement!` verifies the enveloped XML signature in `doc`
and returns the signed element. Fails with the rule that broke for anything
outside the profile in "Verifying a signed assertion", for a digest that does
not match and for a signature that does not verify. Never reads `KeyInfo`.

### `DsigKey`

`enum DsigKey { Rsa(RsaPublicKey), Ecdsa(EcdsaPublicKey) }`, the caller's
public key. `Rsa` is for `rsa-sha256` with a modulus of 2048 bits or more,
`Ecdsa` for `ecdsa-sha256` with a P-256 key.

### `DsigOptions`

`DsigOptions{ expectRoot, allowSha1, maxElements, maxDepth, maxSignatureBytes
}`. `expectRoot` is `{namespace-uri}local` or a bare `local`, `""` by default,
meaning the signed element is `doc`. `allowSha1` accepts a SHA-1 digest method,
false by default. `maxElements` is 100000, `maxDepth` 256 and
`maxSignatureBytes` 1024 by default.

### `SignedElement`

`SignedElement{ element, id }`: `element` is the signed element with its
`Signature` child removed, and `id` the ID the `Reference` named. Read
`element`; do not look `id` up in the document again.
