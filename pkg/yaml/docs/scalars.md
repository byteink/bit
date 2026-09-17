# Scalars

<!-- doctest: per-block -->

Every value in `waypoint.yaml` ([Parsing](parsing.md)) so far has been a
single line. YAML has four more ways to write a scalar - two quoting
styles and two block-scalar styles - each solving a different problem:
escaping a character the plain form can't hold, or keeping a paragraph's
own line breaks through a config file.

## Single- and double-quoted

Say an operator needs to record a release note that contains a literal
apostrophe, and a path that contains a real backslash and a real newline.
Single-quoted has exactly one escape - `''` for a literal `'` - and no
backslash escapes at all; double-quoted is the only style with backslash
escapes:

```bit
import { yamlAsString, yamlParse } from "yaml"

fn main(): ()! {
  let single = yamlParse("'it''s fine'")?
  assert(unwrap(yamlAsString(single)) == "it's fine", "'' inside single quotes is one literal '")

  let double = yamlParse("\"first line\\nsecond line\"")?
  assert(
    unwrap(yamlAsString(double)) == "first line\nsecond line",
    "\\n inside double quotes is a real newline",
  )
  return
}
```

Neither style is typed by [Types](types.md)'s rules - a quoted `'no'` or
`"true"` is always a `YamlString`, regardless of what its text looks like.
That is the whole reason those two styles exist alongside plain scalars.

## Block scalars: literal and folded

A release description is usually more than one line, and the two block
styles are for exactly that: `|` (literal) keeps every line break the
source wrote; `>` (folded) turns a single line break between two content
lines into a space, so a paragraph wrapped for readability in the file
reads back as one unwrapped line:

```bit
import { yamlAsString, yamlParse } from "yaml"

fn main(): ()! {
  let literal = yamlParse("key: |\n  first line\n  second line\n")?
  let l = unwrap(yamlAsString(literal))
  assert(l == "first line\nsecond line\n", "| keeps the line break")

  let folded = yamlParse("key: >\n  first line\n  second line\n")?
  let f = unwrap(yamlAsString(folded))
  assert(f == "first line second line\n", "> folds the break into a space")
  return
}
```

`waypoint.yaml` could carry its own changelog entry this way:

```yaml
notes: |
  Bumped the connection pool.
  No config changes required.
```

## Chomping: what happens to the trailing newline

Every block scalar ends with a **chomping indicator** deciding what to do
with its trailing line break: clip (the default, no indicator) keeps
exactly one; strip (`-`) removes it entirely; keep (`+`) keeps every
trailing blank line the source had. Clip is what you want almost always -
one clean trailing newline, matching how the rest of the file's lines end:

```bit
import { yamlAsString, yamlParse } from "yaml"

fn main(): ()! {
  let clipped = unwrap(yamlAsString(yamlParse("key: |\n  a\n  b\n")?))
  assert(clipped == "a\nb\n", "clip (default) keeps exactly one trailing newline")

  let stripped = unwrap(yamlAsString(yamlParse("key: |-\n  a\n  b\n")?))
  assert(stripped == "a\nb", "strip (-) removes it entirely")
  return
}
```

## Under the hood: decoding one span directly

`yamlParse` calls `yamlDecodeScalar` and `yamlDecodeBlockScalar` once per
scalar token it reads, in exactly the shapes below. Both are exported for a
caller who already has a raw span - from `scan` (see [Parsing](parsing.md)),
not from `yamlParse` - and wants it decoded without building a whole
document around it:

```bit
import { TokenKind, scan, yamlDecodeScalar, yamlDefaultLimits } from "yaml"

fn firstScalarText(src: string): string! {
  for t of scan(src, yamlDefaultLimits())? {
    if (t.kind == TokenKind.PlainScalar ||
      t.kind == TokenKind.SingleQuoted ||
      t.kind == TokenKind.DoubleQuoted) {
      return yamlDecodeScalar(src, t.kind, t.start, t.end)?
    }
  }
  fail newError("no scalar token found")
}

fn main(): ()! {
  let text = firstScalarText("\"a\\nb\"")?
  assert(text == "a\nb", "yamlDecodeScalar decoded the escape on its own")
  return
}
```

```bit
import { TokenKind, scan, yamlDecodeBlockScalar, yamlDefaultLimits } from "yaml"

fn firstBlockScalarText(src: string): string! {
  for t of scan(src, yamlDefaultLimits())? {
    if (t.kind == TokenKind.BlockScalarHeader) {
      let (text, _) = yamlDecodeBlockScalar(src, t.start, t.end, 0)?
      return text
    }
  }
  fail newError("no block scalar header found")
}

fn main(): ()! {
  let text = firstBlockScalarText("key: |\n  first line\n  second line\n")?
  assert(text == "first line\nsecond line\n", "yamlDecodeBlockScalar resolved the body on its own")
  return
}
```

`yamlDecodeBlockScalar` takes the header's own `[start, end)` span - exactly
what `scan`'s `BlockScalarHeader` token gives you - plus the indentation of
the node the block scalar is a value of, and returns the decoded text
together with the byte offset just past the block, so a caller resuming a
hand-rolled scan does not have to re-read anything this call already read.

Next: [Anchors](anchors.md), for reusing a value more than once in the same
document, and the budget that keeps that reuse from being exploited.
