# Searching articles: indexes, queries, vectors and aggregates

<!-- doctest: per-block -->

Inkwell's search box has outgrown `SCAN`. A reader types "redis cache", wants
the articles about it, newest first, only from one author, and "more like this
one" underneath. Scanning every article key and testing each one in your
program is a full read of the data per keystroke.

Redis 8 ships a **Query Engine**: you declare an *index* over hashes or JSON
documents, the server keeps it up to date as they change, and `FT.SEARCH`
answers from the index. `r.search(index)` is one index. The handle is a cheap
value, like every handle in this package; it holds the index name, and the
same name is the key of an autocomplete dictionary (see "Suggestions" below).

The same typed search and aggregation results work with RESP2 and RESP3. Set
`Options.protocol` to `2` or `3` before `connect`; the default is RESP3.
The live tests cover returned fields, scores, IDs, grouped reducers and cursors
under both protocols.

## The smallest index

An index has a **schema**: which fields are searchable and how. `schema()`
starts an empty one; each method adds a field and returns a new schema, so a
base schema can be extended two ways. `create` takes the schema and
`CreateOptions`; `prefixes` limits the index to the keys that start with one.
Here are the articles as hashes, one per key.

```bit
import {
  open, schema, CreateOptions, TextOptions, NumericOptions, qfield, SearchOptions, SortBy, Page, Returned,
} from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  r.hash("article:1").set(
    map<string, string>{
      "title": "Caching with Redis", "author": "ana", "words": "1200",
    },
  )?
  r.hash("article:2").set(
    map<string, string>{
      "title": "Redis streams in practice", "author": "bo", "words": "2400",
    },
  )?

  let articles = r.search("idx:articles")
  articles.create(
    schema().text("title", TextOptions{ weight = 2.0 }).tag("author").numeric(
      "words",
      NumericOptions{ sortable = true },
    ),
    CreateOptions{ prefixes = ["article:"] },
  )?

  let found = articles.find(
    qfield("title").text("redis"),
    SearchOptions{
      sortBy = Option.Some(SortBy{ field = "words", desc = true }),
      page = Option.Some(Page{ offset = 0, num = 10 }),
      returns = [Returned{ field = "title" }, Returned{ field = "words", alias = "length" }],
    },
  )?
  println("${found.total} articles")
  for hit of found.hits {
    println("${hit.id}: ${unwrapOr(hit.field("title"), "")}")
  }
  r.close()
  return
}
```

`create` indexes the keys that already exist, in the background, and every key
written afterwards as it is written. `find` answers a `SearchResult`: `total`
is how many documents match in all, `hits` is this page, best first. A `Hit`
has the key in `id` and the returned fields in `fields`; `field(name)` reads
one. Without `returns` every indexed field comes back; with `Returned`, only
the named ones, `alias` renaming a field on the way out (`RETURN ... AS`).

## Field kinds

Each schema method is one `FT.CREATE` field type, and its options are the
keywords redis.io lists for it, in the same order. The first argument is the
hash field, or the JSON path of a JSON document; `alias` is the name queries
use (`AS`), which a JSON path needs. Each field kind takes a typed options
class; omitting it keeps the defaults.

- `text(name, opts)` is full-text: words are stemmed and stop words dropped.
  `weight` scales its share of the score, `noStem` keeps words as typed,
  `phonetic` (`Phonetic.English`, `French`, `Portuguese`, `Spanish`) finds
  words that sound alike, `suffixTrie` makes `*suffix` and `*infix*` fast,
  `indexEmpty` and `indexMissing` let a query find empty and absent values.
- `tag(name, opts)` is an exact value: an author id, a category. A field holding
  several is split on `separator` (`,` by default); `caseSensitive` keeps case.
- `numeric(name, opts)` supports range queries and sorting; use `NumericOptions`.
- `geo(name, opts)` is a `lon,lat` position, queried by radius; use `GeoOptions`.
- `geoShape(name, opts)` is a WKT point or polygon; `GeoShapeOptions.coords` selects
  `Coords.Spherical` (the default)
  or `Coords.Flat`.
- `vector(name, dim, opts)` is a vector of `dim` numbers. `algo` is `VecAlgo.Hnsw`
  (approximate, fast) or `VecAlgo.Flat` (exact), `metric` is
  `VecMetric.Cosine` (the default), `L2` or `InnerProduct`, `elem` is
  `VecType.Float32` (the default), `Float64`, `Bfloat16` or `Float16`.
  `Hnsw` also takes `m`, `efConstruction`, `efRuntime` and `epsilon`;
  `initialCap` and `blockSize` apply to both.

`sortable` keeps a field's value so `SortBy` and `AGGREGATE` read it without
touching the document; `unf` keeps it un-normalized too; `noIndex` stores it
for sorting and returning only. `schema().size()` says how many fields a
schema holds, and `args()` is its `FT.CREATE` tokens.

`CreateOptions` is the rest of `FT.CREATE`. `over` is `IndexOn.Hash` (the
default) or `IndexOn.Json`. Besides `prefixes` there is `filter` (an
expression over a hash, `@published==1`), `language` and `languageField`,
`score` and `scoreField`, `payloadField`, `maxTextFields`, `temporary` (drop
the index after that many idle seconds), `noOffsets`, `noHl`, `noFields`,
`noFreqs`, `stopwords` (an empty list disables them) and `skipInitialScan`.

```bit
import {
  open, schema, CreateOptions, IndexOn, TextOptions, TagOptions, VectorOptions, Phonetic, VecAlgo,
  VecMetric, VecType, Coords, NumericOptions, GeoOptions, GeoShapeOptions,
} from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let base = schema().text(
    "$.title",
    TextOptions{ alias = "title", weight = 2.0, phonetic = Phonetic.English, sortable = true },
  ).tag("$.tags[*]", TagOptions{ alias = "tags", separator = "|" }).numeric(
    "$.words",
    NumericOptions{ alias = "words", indexMissing = true, sortable = true, noIndex = false },
  )
  let full = base.geo(
    "$.origin",
    GeoOptions{ alias = "origin", indexMissing = true, sortable = true, noIndex = false },
  ).geoShape(
    "$.area",
    GeoShapeOptions{ alias = "area", coords = Coords.Flat, indexMissing = true },
  ).vector(
    "$.embedding",
    384,
    VectorOptions{
      alias = "embedding", algo = VecAlgo.Hnsw, metric = VecMetric.Cosine, elem = VecType.Float32,
      m = 16, efConstruction = 200,
    },
  )
  println("${base.size()} fields in the base, ${full.size()} in the full schema")
  r.search("idx:articles:json").create(
    full,
    CreateOptions{ over = IndexOn.Json, prefixes = ["doc:"], language = Option.Some("english") },
  )?
  r.close()
  return
}
```

## Queries

`find` takes a `Query`. The builder covers the common cases and **escapes
every term you give it**, so a reader's search box can go straight into
`text(..)`:

```text
freeText("redis cache")                       redis cache
qfield("title").text("redis cache")        @title:(redis cache)
qfield("title").phrase("redis cache")      @title:"redis cache"
qfield("title").prefix("cach")             @title:cach*
qfield("title").fuzzy("redis", 2)          @title:%%redis%%
qfield("author").anyOf("ana", "bo")        @author:{ana|bo}
qfield("words").between(500.0, 2000.0)     @words:[500 2000]
qfield("words").gt(500.0)                  @words:[(500 +inf]
qfield("origin").near(2.3, 48.8, 20.0)     @origin:[2.3 48.8 20 km]
qfield("area").shape(ShapeOp.Within, wkt)  @area:[WITHIN $shape_area]
```

The text methods are `text`, `phrase`, `anyWord`, `prefix`, `suffix`, `infix`
and `fuzzy` (1 to 3 edits). The tag method is `anyOf`. The number methods are
`between`, `eq`, `gt`, `ge`, `lt` and `le`. `near` is for a geo field (the unit
is a `GeoUnit`, kilometres by default), `shape(op, wkt)` for a geometry field
(`ShapeOp.Within`, `Contain`, `Intersect` or `Disjoint`, against a WKT point or
polygon) and `missing()` finds documents without the field. `qfield(name)` returns a `QField`, each method a `Query`. Queries combine with `and`, `or`, `not` (`-`), `optional` (`~`: a
match raises the score, no match does not exclude) and `weighted`.
`everything()` is `*`. For syntax the builder does not cover, `rawQuery(expr)`
sends the server's own text as is: escape it yourself.

```bit
import {
  open, qfield, freeText, everything, rawQuery, SearchOptions, NumFilter, GeoFilter,
  Summarize, Highlight, GeoUnit, ShapeOp,
} from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let articles = r.search("idx:articles")

  let q = qfield("title").text("redis cache").and(qfield("author").anyOf("ana", "bo")).and(
    qfield("words").between(500.0, 3000.0),
  ).or(qfield("title").phrase("hot keys").weighted(2.0))
  println(articles.explain(q)?)

  let opts = SearchOptions{
    numeric = [NumFilter{ field = "words", min = 500.0, max = 3000.0 }],
    geo = [
      GeoFilter{
        field = "origin",
        lon = 2.3,
        lat = 48.8,
        radius = 50.0,
        unit = GeoUnit.Kilometers,
      },
    ],
    inFields = ["title"],
    summarize = Option.Some(
      Summarize{ fields = ["title"], frags = Option.Some(1), len = Option.Some(8) },
    ),
    highlight = Option.Some(Highlight{ fields = ["title"], open = "<mark>", close = "</mark>" }),
    withScores = true,
  }
  let hits = articles.find(freeText("redis"), opts)?
  for hit of hits.hits {
    println("${hit.id} ${unwrapOr(hit.score, 0.0)} ${unwrapOr(hit.field("title"), "")}")
  }
  let inParis = articles.find(
    qfield("area").shape(ShapeOp.Within, "POLYGON((2 48, 3 48, 3 49, 2 49, 2 48))"),
  )?
  println("${inParis.total} articles written in the box")
  let anyThing = articles.find(rawQuery("@title:redis -@author:{bo}"))?
  let all = articles.find(everything(), SearchOptions{ noContent = true })?
  println("${anyThing.total} of ${all.total}")
  r.close()
  return
}
```

`SearchOptions` is the rest of `FT.SEARCH`, every field unset by default:
`noContent` (ids only), `verbatim`, `noStopwords`, `withScores`,
`withPayloads`, `withSortKeys` (they fill `Hit.score`, `payload` and
`sortKey`), `numeric` and `geo` filters, `inKeys` and `inFields`, `returns`,
`summarize`, `highlight`, `slop` and `inOrder`, `timeout` (milliseconds),
`language`, `expander`, `scorer`, `explainScore` (fills `Hit.scoreExplain`),
`payload`, `sortBy`, `page` (the server's default page is the first ten),
`params` and `dialect`. `SortBy.withCount` makes `total` count every match,
not only the sorted page.

## JSON articles

For an index `over` `IndexOn.Json` the document comes back as one field, `$`,
and `Hit.doc<T>()` decodes it into a `@json` class:

```bit
import { open, qfield, SearchOptions } from "redis"

@json class Article {
  title: string,
  words: i64,
}

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let found = r.search("idx:articles:json").find(qfield("title").text("redis"))?
  for hit of found.hits {
    let a = hit.doc<Article>()?
    println("${hit.id}: ${a.title}, ${a.words} words")
  }
  r.close()
  return
}
```

`doc<T>(name)` reads another field than `$`, for a `returns` that picked a
sub-document (`Returned{ field = "$.author" }`). A document that does not fit
`T`, or a hit without the field, is a `RedisError`.

## More like this: vector similarity

An article's embedding is a `[]f32`. A vector field stores the raw
little-endian `FLOAT32` bytes (`f32sToLe` from `std/math`); a JSON index takes
a plain number array. `knn(field, vector, k)` is the query for "the `k`
nearest"; the vector goes in `PARAMS` as a blob, which needs dialect 2, and
`find` sends it for you. The distance comes back in the field named by
`score` (`__<field>_score` by default), and a `filter` makes it a **hybrid**
query: the nearest articles among those that match.
`vectorRange(field, vector, radius)` is every article within a distance.

```bit
import { open, knn, vectorRange, qfield, SearchOptions, SortBy } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let articles = r.search("idx:articles")
  let mine: []f32 = [0.12, 0.8, 0.31]

  let similar = articles.find(
    knn("embedding", mine, 5, filter = qfield("author").anyOf("ana"), score = "dist"),
    SearchOptions{ sortBy = Option.Some(SortBy{ field = "dist" }) },
  )?
  for hit of similar.hits {
    println("${hit.id} ${unwrapOr(hit.field("dist"), "?")}")
  }
  let close = articles.find(vectorRange("embedding", mine, 0.1))?
  println("${close.total} within 0.1")
  r.close()
  return
}
```

## Counting and grouping: aggregates

`aggregate(query, steps, opts)` is `FT.AGGREGATE`: the documents matching
`query` flow through the steps of an `agg()` (an `AggPipeline`, immutable
like `Schema`), in order, and the answer is
rows, not documents. `groupBy(fields, reducers)` groups and reduces; a
`Reducer` is a `Reduce` (`Count`, `CountDistinct`, `CountDistinctIsh`, `Sum`,
`Min`, `Max`, `Avg`, `StdDev`, `Quantile`, `ToList`, `FirstValue`,
`FirstValueBy`, `RandomSample`) and the `alias` its result is called.
`apply(expr, alias)` computes a field, `sortBy(field, desc, max)`,
`filter(expr)` and `limit(offset, num)` do what their names say, and
`load(..fields)` / `loadAll()` read fields that are not sortable from the
documents. Fields are written with or without the `@`.

```bit
import {
  open, everything, agg, Reduce, Reducer, AggregateOptions, CursorOptions,
} from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let articles = r.search("idx:articles")

  let steps = agg().groupBy(
    ["author"],
    [
      Reducer{ reduce = Reduce.Count, alias = "articles" },
      Reducer{ reduce = Reduce.Avg("words"), alias = "avgWords" },
      Reducer{ reduce = Reduce.Max("words"), alias = "longest" },
    ],
  ).apply("@avgWords / 200", "minutes").filter("@articles > 1").sortBy(
    "avgWords",
    desc = true,
    max = 10,
  ).limit(0, 10)
  let byAuthor = articles.aggregate(everything(), steps)?
  for row of byAuthor.rows {
    println("${unwrapOr(row.field("author"), "")}: ${unwrapOr(row.num("minutes"), 0.0)} min")
  }

  let paged = articles.aggregate(
    everything(),
    agg().load("title").sortBy("words"),
    AggregateOptions{ cursor = Option.Some(CursorOptions{ count = 100, maxIdle = 30000 }) },
  )?
  let cursor = paged.cursor
  while (cursor != 0) {
    let page = articles.cursorRead(cursor, 100)?
    println("${len(page.rows)} more rows")
    cursor = page.cursor
  }
  r.close()
  return
}
```

An `AggRow` has `field(name)` (text) and `num(name)` (a number, `None` if it
is absent or not one). An `AggResult` has `total`, `rows` and `cursor`.
`CursorOptions` turns on `WITHCURSOR`: the first `count` rows come now and
`cursorRead(cursor, count)` (`FT.CURSOR READ`) fetches the rest until
`cursor` is 0. `cursorDel(cursor)` frees one early; the server forgets an
idle one after `maxIdle` milliseconds. `AggregateOptions` also has `verbatim`,
`timeout`, `params` and `dialect`.

## Looking after an index

```bit
import { open, schema, qfield } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let articles = r.search("idx:articles")

  let info = articles.info()?
  println("${info.name} over ${info.keyType}: ${info.numDocs} documents, ${info.numTerms} terms")
  for f of info.fields {
    println("  ${f.attribute} is ${f.kind}, ${len(f.flags)} flags")
  }
  println("indexing ${info.indexing}, ${info.percentIndexed * 100.0}%, failures ${info.indexingFailures}")

  articles.alter(schema().tag("lang"))?
  for name of articles.list()? {
    println(name)
  }

  articles.addAlias("articles")?
  r.search("idx:articles:v2").moveAlias("articles")?
  articles.removeAlias("articles")?
  println("${len(articles.tagValues("author")?)} authors")
  articles.drop(deleteDocs = false)?
  r.close()
  return
}
```

`info()` is `FT.INFO`: a `SearchInfo` with the fields above plus `maxDocId`
and `numRecords`; `fields` are `IndexField`s. `alter` is `FT.ALTER ... SCHEMA
ADD`: it adds fields, never changes one. `list()` is `FT._LIST` and
`tagValues(field)` is `FT.TAGVALS`. An **alias** is a second name for an
index: `addAlias` adds one, `moveAlias` (`FT.ALIASUPDATE`) points it here from
wherever it was, which is how a rebuilt index replaces the old one without
the readers noticing, and `removeAlias` deletes it. `drop(deleteDocs)` is
`FT.DROPINDEX`; `deleteDocs` also deletes the indexed documents (`DD`).

## Suggestions, spelling and synonyms

Autocomplete has its own dictionary, a key of its own. The handle's name is
that key: `r.search("suggest:titles")`.

```bit
import { open, SuggestOptions, SpellOptions } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let titles = r.search("suggest:titles")
  titles.sugAdd("Caching with Redis", score = 3.0)?
  titles.sugAdd("Redis streams in practice", incr = true, payload = Option.Some("article:2"))?
  let hints = titles.sugGet(
    "red",
    SuggestOptions{ fuzzy = true, max = Option.Some(5), withScores = true, withPayloads = true },
  )?
  for h of hints {
    println("${h.text} ${unwrapOr(h.score, 0.0)} ${unwrapOr(h.payload, "")}")
  }
  let removed = titles.sugDel("Caching with Redis")?
  println("${titles.sugLen()?} suggestions left; removed: ${removed}")

  let articles = r.search("idx:articles")
  articles.synonyms("cache", ["cache", "caching", "memoize"])?
  for s of articles.synonymGroups()? {
    println("${s.term} is in ${len(s.groups)} groups")
  }
  let fixes = articles.spellcheck("rediss streem", SpellOptions{ distance = Option.Some(2) })?
  for m of fixes {
    for c of m.suggestions {
      println("${m.term} -> ${c.member} (${c.score})")
    }
  }
  r.close()
  return
}
```

`sugAdd(text, score, incr, payload)` returns the dictionary's size; `incr`
adds `score` to an existing entry instead of replacing it. `sugGet` answers
best first; `SuggestOptions` has `fuzzy`, `max`, `withScores` and
`withPayloads`. `synonyms(group, terms)` (`FT.SYNUPDATE`) makes the terms
mean the same in searches over that index and `synonymGroups()` (`FT.SYNDUMP`)
lists them. `spellcheck(query, opts)` (`FT.SPELLCHECK`) answers a `Misspelled`
per unknown term with `Scored` suggestions; `SpellOptions` has `distance`,
`include` and `exclude` (dictionaries) and `dialect`.

## Keep spelling terms in a dictionary

Teach spellcheck your product vocabulary before you pass its dictionary name
in `SpellOptions.include`. A spelling dictionary is separate from an index and
from autocomplete: `search(name)` uses that name for all three dictionary calls.

```bit
import { open } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let vocabulary = r.search("spelling:articles")
  let added = vocabulary.dictAdd(["memoization", "prefetch"])?
  for term of vocabulary.dictDump()? {
    println(term)
  }
  let removed = vocabulary.dictDel(["prefetch", "absent"])?
  println("${added} new terms; ${removed} removed")
  let p = r.pipeline()
  let queuedAdd = p.search("spelling:articles").dictAdd(["prefetch"])
  let queuedTerms = p.search("spelling:articles").dictDump()
  let queuedDel = p.search("spelling:articles").dictDel(["prefetch"])
  p.exec()?
  println("${queuedAdd.get()?} added; ${len(queuedTerms.get()?)} terms; ${queuedDel.get()?} removed")
  r.close()
  return
}
```

`dictAdd(terms)` (`FT.DICTADD`) counts new terms; repeated terms do not increase
that count. `dictDel(terms)` (`FT.DICTDEL`) counts terms actually removed.
`dictDump()` (`FT.DICTDUMP`) returns all terms without an ordering guarantee,
accepting the RESP2 array and RESP3 set replies. The same methods on
`SearchBatch` return futures. `tx.read.search(name).dictDump()` is allowed;
queue dictionary writes through `tx.search(name)`.

## In a pipeline and in a transaction

`p.search(index)` and `tx.search(index)` queue the same calls (a
`SearchBatch`) and answer a `Future` each. `tx.read.search(index)` reads inside a transaction body; a
write through it (`create`, `drop`, ...) is refused, queue it with
`tx.search(index)`.

```bit
import { open, qfield, everything, SearchOptions, Future } from "redis"

fn main(): ()! {
  let r = open("redis://localhost:6379")?
  let p = r.pipeline()
  let ana = p.search("idx:articles").find(qfield("author").anyOf("ana"))
  let docs = p.search("idx:articles").info()
  p.exec()?
  let byAna = ana.get()?
  let indexed = docs.get()?
  println("${byAna.total} by ana of ${indexed.numDocs}")

  let total = r.transaction<Future<i64>>(["article:1"], (tx) => {
    let seen = tx.read.search("idx:articles").find(everything(), SearchOptions{ noContent = true })?
    println("${seen.total} indexed right now")
    return tx.search("suggest:titles").sugLen()
  })?
  let n = total.get()?
  println("${n} suggestions")
  r.close()
  return
}
```

## Sharp edges

- **The index is eventually consistent for existing keys.** `create` returns
  at once and scans in the background: `info().indexing` is true until it is
  done. Documents written after `create` are indexed as they are written.
- **Dialect.** Vector queries and `PARAMS` need dialect 2 or later; `find` and
  `aggregate` send 2 for any query that carries params unless `dialect` says
  otherwise. Dialect 1 treats some punctuation differently.
- **A hash vector is a blob, a JSON vector is an array.** Mixing them is the
  server's indexing failure, counted in `indexingFailures`, not an error on
  the write.
- **A missing field in a document** is skipped, not an error, unless the
  field was created with `indexMissing`.
- **`aggregate` with a cursor is not retried** after a connection error: the
  server may already have opened the cursor.
- **The query builder escapes.** `rawQuery` does not.

## When not to use it

For a lookup by a key you already know, or by one field, a hash or a sorted
set is a single command and no index to maintain. A search index costs memory
per indexed field and work per write; index the fields you query.

## Where to go next

[Articles as JSON documents](json.md) covers the documents a JSON index
searches. [Similar players and per-round scores](vectors-and-arrays.md) is
the vector set, for nearest-neighbour search without an index.
[Hashes](hashes.md) covers the documents a hash index searches.
