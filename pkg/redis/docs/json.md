# Articles as JSON documents

<!-- doctest: per-block -->

Inkwell autosaves an article every few seconds. The article is a small document:
a title, an author, tags, sections. Stored as one string, every autosave
writes all of it, and bumping the view counter or adding a tag means reading
the whole article, changing it in your program and writing it back, while
another request does the same and one of the two edits is lost.

Redis can keep the document as JSON and edit it in place. `r.json(key)` is a
cheap value, `{runner, key}`, like every other handle: you can call it again
any time you need the same key. A JSON key is its own type (`TYPE` says
`ReJSON-RL`), so the string and hash commands do not work on it, and these do
not work on a string.

```bit
import { open } from "redis"
import { Json, JsonEntry } from "std/json"

@json class Author {
  name: string,
  handle: string,
}

@json class Section {
  heading: string,
  words: i64,
}

@json class Article {
  id: string,
  title: string,
  author: Author,
  tags: []string,
  sections: []Section,
  rating: f64,
  published: bool,
  subtitle: Option<string>,
}

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let article = Article{
    id = "a41",
    title = "Why Inkwell is small",
    author = Author{ name = "Ana", handle = "ana" },
    tags = ["essay", "bit"],
    sections = [
      Section{ heading = "Start", words = 320 },
      Section{ heading = "Grow", words = 540 },
    ],
    rating = 4.5,
    published = false,
    subtitle = Option.None,
  }

  r.json("inkwell:article:a41").set(article)?

  match (r.json("inkwell:article:a41").get<Article>()?) {
    Some(back) => println("${back.title} by ${back.author.name}") // Why Inkwell is small by Ana
    None => println("no such article")
  }
  r.close()
  return
}
```

`set(value)` takes any class marked `@json`, and `get<T>()` reads the whole
document back into a `T`, which must be a `@json` class: nested classes,
arrays of classes, `Option` fields, enums and floats come back as `std/json`
defines them. The `@json` mark needs `Json` and `JsonEntry` imported from
`std/json`; the compiler says so (`E0142`) when they are missing.

`get<T>()` is `None` when the key does not exist. A document that does not
fit `T` fails `RedisError.Unexpected`, and the message carries the decoder's
own path to the field, so an article saved by an older version of Inkwell tells
you which field it lacks:

```text
redis: JSON.GET: unexpected reply, cannot decode into the requested class: ...
```

## Paths

Everything below works on a part of the document. A path is a JSONPath: `$`
is the root, `$.author.name` a member, `$.tags[0]` an array element,
`$.sections[*].words` every element's member, and `$..words` every `words`
at any depth. Every method takes the path as a string and defaults to `$`.

A path can match nothing, one place or many, so the answer to a path is
always a list with **one slot per match, in document order**. Where a match is
not the kind of value the command works on (asking the length of an array at a
place that holds a string) its slot is `None`, and a path that matches
nothing is an empty list. Only JSONPath (starting with `$`) is understood; the
older dotted form (`.author.name`) answers in a different shape and fails
`RedisError.Unexpected` with a message that says so.

`getAt<T>(path)` is `JSON.GET` of one path, every match decoded as a `T`.
`getPaths(...paths)` asks for several paths in one round trip and hands back
the trees, a `JsonMatch` per path in the order you asked, each with its
`path` and the `values` that matched:

```bit
import { open } from "redis"
import { Json, JsonEntry, jsonEncode } from "std/json"

@json class Section {
  heading: string,
  words: i64,
}

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let article = r.json("inkwell:article:a41")

  let sections = article.getAt<Section>("$.sections[*]")?
  for s of sections {
    println("${s.heading}: ${s.words} words")
  }

  let found = article.getPaths("$.author.name", "$.tags[0]", "$.nothing")?
  for m of found {
    println("${m.path}: ${len(m.values)} match(es)")
  }
  println(jsonEncode(found[0].values[0])) // "Ana"
  r.close()
  return
}
```

## Writing a part

`set(value, path, opts)` puts a value at a path; with no path it replaces the
whole document. It answers `true` when it wrote and `false` when it did not:
the path's parent is missing, or `JsonSetOptions` said no. `nx = true` writes
only where the path matches nothing, `xx = true` only where it matches
something, which makes "create the article if nobody has" and "update it only
if it exists" one call each. A key that does not exist can only be created at
the root; setting `$.title` on it is the server's error.

The value is a `@json` class, or a `Json` value from `std/json` for a bare
number, string or bool (`Json.JsonInt(3)`, `Json.JsonString("x")`,
`Json.JsonBool(true)`). `merge`, `mset` and the array commands below take the
same two kinds.

`fpha` is the third option. Redis stores an array of numbers compactly when
they are all floats, and `JsonFloatType` (`Auto`, `Fp16`, `Bf16`, `Fp32`,
`Fp64`) picks the width it uses; leave it on `Auto` unless you store vectors.
`JsonFloatType.text()` is the word the server expects.

`merge(value, path)` folds an object into what is there: keys it names are
added or replaced, a key set to `null` is deleted, and everything else stays.
That is the autosave: send what changed. `mset` sets several places, in several
keys, in one atomic command; its first value goes to the handle's own key and
the rest are `JsonTarget`s.

```bit
import { open, JsonSetOptions, JsonTarget } from "redis"
import { Json, JsonEntry, jsonParse } from "std/json"

@json class Author {
  name: string,
  handle: string,
}

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let article = r.json("inkwell:article:a41")

  // A class replaces just that part of the document.
  article.set(Author{ name = "Ana Reis", handle = "ana" }, "$.author")?

  // Only the first writer wins.
  let first = article.set(Json.JsonString("Untitled"), "$.title", JsonSetOptions{ nx = true })?
  println("${first}") // false, the title is already there

  // Update the subtitle, then change just that part of the document.
  article.set(Json.JsonString("A short history"), "$.subtitle")?
  article.merge(jsonParse("{\"published\": true, \"subtitle\": null}")?)?

  // The article and its newsletter entry change together, or not at all.
  article.mset(
    Json.JsonFloat(4.8), "$.rating",
    JsonTarget{ key = "inkwell:newsletter", path = "$.next", value = Json.JsonString("a41") },
  )?
  r.close()
  return
}
```

## Counters and flags in place

The edit that cost a read-modify-write is now one command that cannot race.
`numIncrBy(by, path)` adds to every number at the path and `numMultBy(by,
path)` multiplies, each answering the new numbers as `f64`, one per match.
`strAppend(text, path)` appends to every string and answers the new lengths,
`strLen(path)` reads them. `toggle(path)` flips a boolean and answers the new
value.

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let article = r.json("inkwell:article:a41")

  // Every section grows by 10 words: two matches, two numbers.
  let words = article.numIncrBy(10.0, "$.sections[*].words")?
  println("${unwrap(words[0])} ${unwrap(words[1])}") // 330 550

  article.numMultBy(0.5, "$.rating")?

  article.strAppend(" (revised)", "$.title")?
  let sizes = article.strLen("$.title")?
  println("title is ${unwrap(sizes[0])} characters")

  let now = article.toggle("$.published")?
  println("published: ${unwrap(now[0])}")

  // A string is not a number: the slot is None, nothing changes.
  let wrong = article.numIncrBy(1.0, "$.title")?
  println("${isNone(wrong[0])}") // true
  r.close()
  return
}
```

`by` must be a finite number; `NaN` and infinity fail `RedisError.Invalid`
before anything is sent. The answers are `f64`, so an integer above 2^53 loses
its low digits in the answer, though not in the stored document.

## Tags: arrays

`arrAppend(path, ...values)` adds to the end of every array at the path and
`arrInsert(path, index, ...values)` before `index` (negative counts from the
end). Both answer the new lengths. `arrLen(path)` reads them, `arrIndex(path,
value, start, stop)` finds the first element equal to `value` (-1 when there
is none; `stop = 0` reads to the end), `arrPop(path, index)` removes and
returns the element at `index`, the last by default, and `arrTrim(path,
start, stop)` keeps only that range.

```bit
import { open } from "redis"
import { Json, JsonEntry } from "std/json"

@json class Section {
  heading: string,
  words: i64,
}

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let article = r.json("inkwell:article:a41")

  // A new section goes on the end as a class.
  article.arrAppend("$.sections", Section{ heading = "Ship", words = 210 })?

  article.arrAppend("$.tags", Json.JsonString("wip"), Json.JsonString("v2"))?
  article.arrInsert("$.tags", 0, Json.JsonString("featured"))?
  println("${unwrap(article.arrLen("$.tags")?[0])} tags") // 5

  let at = article.arrIndex("$.tags", Json.JsonString("wip"))?
  println("wip is tag number ${unwrap(at[0])}") // 3

  // Take the newest tag back off, then keep only the first three.
  let popped = article.arrPop("$.tags")?
  println("popped ${isSome(popped[0])}") // true
  article.arrTrim("$.tags", 0, 2)?
  r.close()
  return
}
```

`arrPop` answers the removed value as a `Json` tree, and `None` for an array
that was already empty.

## What is in there

`typeOf(path)` names the type of every match: `object`, `array`, `string`,
`integer`, `number`, `boolean` or `null`. `objKeys(path)` lists an object's
member names and `objLen(path)` counts them. `del(path)` removes every match
and says how many; deleting the root deletes the key. `clear(path)` empties
arrays and objects and zeroes numbers, leaving the members where they are.

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let article = r.json("inkwell:article:a41")

  // One type per match: "object", then "string" for the second heading.
  println(article.typeOf("$.author")?[0])
  println(article.typeOf("$.sections[*].heading")?[1])
  println("${unwrap(article.objLen("$.author")?[0])} members") // 2
  for name of unwrap(article.objKeys("$.author")?[0]) {
    println(name) // name, handle
  }

  let cleared = article.clear("$.sections[*].words")?
  println("${cleared} numbers zeroed") // 2
  let removed = article.del("$.subtitle")?
  println("${removed} removed")
  r.close()
  return
}
```

Asking `arrLen`, `strLen`, `objKeys`, `toggle` or `clear` of a key that does
not exist is the server's own error, `RedisError.Server`; `typeOf` and `del`
answer an empty list and `0`, and `get` answers `None`. A JSON command on a
key that holds a string, or a string command on a JSON key, fails with the
server's wrong-type message.

## Several articles at once

`mget<T>(others, path)` reads the same path from this key and from `others` in
one round trip. It answers a slot per key, this key first, holding the first
match of the path decoded as a `T`, or `None` for a key that does not exist or
a path that matches nothing. That is the front page: the title and author of
twenty articles in one call.

```bit
import { open } from "redis"
import { Json, JsonEntry } from "std/json"

@json class Author {
  name: string,
  handle: string,
}

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let first = r.json("inkwell:article:a41")

  let authors = first.mget<Author>(["inkwell:article:a42", "inkwell:article:gone"], "$.author")?
  for slot of authors {
    match (slot) {
      Some(a) => println(a.name)
      None => println("(missing)")
    }
  }
  r.close()
  return
}
```

## Pipelines and transactions

`JsonBatch` is the same set of methods returning a `Future`, for
`r.pipeline()` and for a transaction body. `p.json(key)` and `tx.json(key)`
both return it, and the command is written once.

```bit
import { open, Future, JsonBatch } from "redis"
import { Json } from "std/json"

fn main(): ()! {
  let r = open("redis://localhost:6379")?

  // Publish: flip the flag and count the view, atomically.
  let views = r.transaction<Future<[]Option<f64>>>(["inkwell:article:a41"], (tx) => {
    let q: JsonBatch = tx.json("inkwell:article:a41")
    q.set(Json.JsonBool(true), "$.published")
    return q.numIncrBy(1.0, "$.views")
  })?
  println("${unwrap(views.get()?[0])} views")

  // Two articles' types in one round trip.
  let p = r.pipeline()
  let a = p.json("inkwell:article:a41").typeOf()
  let b = p.json("inkwell:article:a42").typeOf()
  p.exec()?
  println(a.get()?[0]) // object
  println(b.get()?[0]) // object
  r.close()
  return
}
```

## Reading an article inside a transaction

`tx.json(key)` only queues, so it cannot answer "is this article published?"
before you decide what to write. `tx.read.json(key)` is the immediate view of
the same key, run now on the transaction's own connection, between `WATCH` and
`MULTI`. If another client changes a watched key first, the transaction
retries and your body runs again with fresh reads:

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let key = "inkwell:article:a41"
  r.transaction<()>([key], (tx) => {
    let kinds = tx.read.json(key).typeOf("$.views")?
    if (len(kinds) == 1 && kinds[0] == "integer") {
      tx.json(key).numIncrBy(1.0, "$.views")
    }
    return
  })?
  r.close()
  return
}
```

The reads (`get`, `getAt`, `getPaths`, `mget`, `typeOf`, `strLen`, `arrLen`,
`arrIndex`, `objKeys`, `objLen`) work through `tx.read`. A write such as
`tx.read.json(key).set(...)` would run immediately, outside the transaction's
`MULTI`/`EXEC`, so it fails with `RedisError.Invalid`; queue it with
`tx.json(key)`.

## When not to use it

If you only ever write the whole article and read the whole article back, a plain
string with `r.set` is smaller and faster; the document store earns its place
when you edit or read part of a value. If the parts are flat fields, a hash
([Hashes](hashes.md)) is simpler still. If you need to query articles by what is
inside them, that is a search index, not a key.

Next: [Sorted sets](sorted-sets.md) for ranking the articles, or
[Strings and keys](strings-and-keys.md) for expiring them.
