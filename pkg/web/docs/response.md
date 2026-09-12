# The response

A handler returns a `Res`, built only through `Ctx`'s helpers or the `Node`
tree below - never by literal. This chapter covers both, plus the escaping
that keeps a `Node` tree safe to render.

## Building a Res

```bit
import { Ctx, Res } from "bitlang.org/pkg/web"

fn showUser(c: Ctx): Res! {
  return c.text("ok").status(200).header("X-Request-Id", "abc-123")
}
```

The common constructors on `Ctx`: `c.json(v)` for anything satisfying
`Jsonable` (a class carrying `toJson()`, synthesized by `@json`), `c.text(s)`,
`c.html(n)` for a `Node` tree, `c.status(n)` for an empty body, `c.created(id)`
and `c.createdUrl(target)` for a `201` with `Location`, `c.noContent()` for a
`204`, and `c.redirect(target)`. `Res` itself carries `.status(n)`,
`.header(name, value)`, `.wrap(key)` and `.mapValue(f)` for a middleware that
wants to reshape a value response on the way out.

## The Node tree

There is no template engine - a component is a plain Bit function returning
`Node`, built out of `el(tag, ...kids)` and the two named conveniences
`div`/`a`. Attributes and children share one list: an `Attr` node interleaved
among the real children becomes part of the opening tag, in the order it
appears among the other attributes; everything else becomes the body, in the
order it appears among the other children.

```bit
import { Ctx, Res, Node, div, a, text } from "bitlang.org/pkg/web"

fn page(c: Ctx): Res! {
  let body = div(
    a(Node.Attr("href", "/"), text("home")),
  )
  return c.html(body)
}
```

`render(n: Node): string` is what `c.html` calls to flatten a tree into HTML,
appending into one growable buffer rather than concatenating - a component
tree is exactly the shape that turns a concatenating renderer into hundreds
of allocations for one page.

## Escaping

`text(s)` is the only way to put a string into element content and have it
escaped: `text("<script>")` renders as the literal characters `&lt;script&gt;`,
never a live tag. `raw(s)` is the one deliberate escape hatch - unescaped,
byte-for-byte, never reachable through `text()`. An `Attr`'s value is escaped
unconditionally by `render` itself, since there is no `attr()` wrapper to do
it at construction time.

```bit
import { text, raw, safeUrl, js } from "bitlang.org/pkg/web"

fn demo(): ()! {
  let escaped = text("<script>alert(1)</script>")
  let literal = raw("<hr>")
  let href = safeUrl("https://example.com")?
  let inline = js("a</script>b")
}
```

`safeUrl(s)` is for an `href`/`src`/`action` value: it refuses (never strips
or rewrites - a rewrite hides the attack) any scheme outside a fixed
allowlist, and always allows a relative reference (`/path`, `?query`,
`#fragment`). `js(s)` is for embedding a string inside a `<script>` block: it
JSON-encodes and additionally escapes every `<` byte, because an HTML parser
looks for the literal sequence `</script` regardless of JS string-literal
context.

Next: [Middleware](middleware.md), for composing behavior around a request.
