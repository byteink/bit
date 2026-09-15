# The response

A handler returns a `Res`, built only through `Ctx`'s helpers or the `Node`
tree below - never by literal. This chapter covers both, plus the escaping
that keeps a `Node` tree safe to render.

## Building a Res

```bit
import { Ctx, Res } from "web"

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

There is no template engine - a component is a plain Bit function that
returns a `Node`. Write it with JSX, the same tag syntax HTML already taught
you:

```bit
import { Node, render, elem, attr, frag, text } from "web"

fn navLinks(): Node {
  return <>
    <a href="/">home</a>
    <a href="/about">about</a>
  </>
}

fn Page(title: string): Node {
  return <div class="card">
    <h1>{text(title)}</h1>
    {navLinks()}
  </div>
}

fn homePage(c: Ctx): Res! {
  return c.html(<Page title="Users" />)
}
```

A lowercase tag (`<div>`, `<a>`) desugars to a call to `elem`; an attribute
(`class="card"`) desugars to a call to `attr`; a fragment (`<>...</>`)
desugars to a call to `frag`. None of the three is compiler magic - they are
ordinary functions this package exports, resolved by the same scope rules
as any other call, so the import line above must name all three even
though your own source never spells `elem`, `attr` or `frag`. Leave one out
and every tag in the file becomes an "undefined name" error naming a word
you never wrote.

A tag whose name starts uppercase, like `<Page title="Users" />` above,
calls a function instead of building an element - its attributes become
named arguments, exactly as `Page(title = "Users")` would if you called it
yourself.

`render(n: Node): string` is what `c.html` calls to flatten a tree into HTML,
appending into one growable buffer rather than concatenating - a component
tree is exactly the shape that turns a concatenating renderer into hundreds
of allocations for one page.

JSX is sugar over building the same tree by hand with `el(tag, ...kids)` and
the two named conveniences `div`/`a`. Attributes and children share one
list: an `Attr` node interleaved among the real children becomes part of
the opening tag, in the order it appears among the other attributes;
everything else becomes the body, in the order it appears among the other
children.

```bit
import { div, a } from "web"

fn page(c: Ctx): Res! {
  let body = div(
    a(Node.Attr("href", "/"), text("home")),
  )
  return c.html(body)
}
```

## Escaping

`text(s)` is the only way to put a string into element content and have it
escaped: `text("<script>")` renders as the literal characters `&lt;script&gt;`,
never a live tag. `raw(s)` is the one deliberate escape hatch - unescaped,
byte-for-byte, never reachable through `text()`. An `Attr`'s value is escaped
unconditionally by `render` itself, since neither `Node.Attr` built by hand
nor `attr()` built by JSX escapes it at construction time.

```bit
import { raw, safeUrl, js } from "web"

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
