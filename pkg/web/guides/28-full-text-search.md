# Find articles by their words

<!-- doctest: deps orm postgres -->

A reader remembers a word from an article but has forgotten its title.
Exact title filters cannot help them. Inkwell lets them search the title
and body together through `GET /articles?q=...`.

## Try the existing search

Start the [finished app](README.md#run-the-finished-app) with its migrations
applied. Publish an article containing a distinctive word through the
[article route](08-querying-and-crud.md), then search for that word:

```text
curl -i --get http://127.0.0.1:8080/articles --data-urlencode 'q=PostgreSQL'
```

The request needs no session. The result uses the same list-item fields as
ordinary article lists, inside the response envelope. A search with no matches
returns an empty list.

## Let PostgreSQL maintain the searchable words

A generated `search_vector` column keeps the search data in step with each
insert and edit. This is the complete migration from
[`AddArticleSearchVector`](inkwell/migrations/2026_01_04_000001_add_article_search_vector.bit):

```bit
import { Schema } from "orm"

export class AddArticleSearchVector {
  up(s: Schema): ()! {
    s.table("articles", (t) => {
      t.raw(
        "alter table articles add column if not exists search_vector tsvector generated always as (to_tsvector('english', coalesce(title, '') || ' ' || coalesce(body, ''))) stored",
      )
      t.raw(
        "create index if not exists articles_search_vector_idx on articles using gin (search_vector)",
      )
    })?
  }

  down(s: Schema): ()! {
    s.table("articles", (t) => {
      t.raw("drop index if exists articles_search_vector_idx")
      t.raw("alter table articles drop column if exists search_vector")
    })?
  }
}
```

The expression joins the title and body with a space and uses English word
rules. `coalesce` treats a null input as an empty string. Both fields have the
same weight. The GIN index lets PostgreSQL find matching words without reading
every article body.

This migration uses raw PostgreSQL DDL through `t.raw`. It does not use the
schema builder's full-text helpers. Keep the migration and query on the same
text-search configuration; Inkwell uses `'english'` in both.

## Bind the search text and rank the matches

This is the complete `searchArticles` function from
[`articles.bit`](inkwell/articles.bit). The model declarations it needs are
included at the end of this page; the Bit blocks on this page form one module.

```bit
import { Db } from "orm"
import { Value } from "std/sql"

fn searchArticles(db: Db, q: string, limit: int): []Article! {
  let sqlText = "select * from articles where deleted_at is null " +
    "and search_vector @@ plainto_tsquery('english', ?) " +
    "order by ts_rank(search_vector, plainto_tsquery('english', ?)) desc limit ?"
  return db.query<Article>(sqlText, q, q, limit)?
}
```

`plainto_tsquery` interprets the input as ordinary search words. It does not
accept the operator syntax of `to_tsquery`. Matching words use PostgreSQL's
English normalization, so this is neither a substring search nor an exact
phrase search.

The `?` placeholders bind the text twice and the result limit once. User text
never becomes SQL syntax. `ts_rank` puts stronger matches first; the query
adds no second ordering rule for ties.

Raw SQL does not inherit a repository's soft-delete filter. The explicit
`deleted_at is null` keeps removed articles out of these results.

## Connect it to the article list

At the start of `listArticles`, the real handler takes this branch. This is
an excerpt inside that function, shown as text because it uses the app's
`c`, `db`, list-item converter and constants:

```text
  let searchTerm = c.query("q")
  if (len(searchTerm) > 0) {
    let matches = searchArticles(db, searchTerm, defaultLimit)?
    let out = []ArticleListItem(0)
    for a of matches {
      out = append(out, toListItem(a))
    }
    return page(out, len(out), defaultLimit, "")
  }
```

A non-empty `q` selects search before the normal list code runs. The app passes
`defaultLimit`, which is 20. Search therefore returns at most 20 matches and
ignores `author`, `sort`, `page` and `limit`. The response total is the number
returned, not the count of all matches. Its cursor is empty.

An absent or empty `q` uses the usual
[pagination and filters](14-pagination-filtering-and-sorting.md). A value
containing only spaces still enters the search branch.

## Keep the model used by the query

The search returns real `Article` values. These declarations come from
[`articles.bit`](inkwell/articles.bit), [`users.bit`](inkwell/users.bit) and
[`tags.bit`](inkwell/tags.bit). The related classes keep the same shape as
in the app; there is no second search-only model.

```bit
@table("articles") @timestamps @softDelete class Article {
  id: i64
  title: string
  slug: string
  body: string
  authorId: i64
  @belongsTo("authorId")
  author: User
  @manyToMany("article_tags")
  tags: []Tag
  createdAt: i64
  updatedAt: i64
  deletedAt: Option<i64>
  @version
  version: i64
}

@table("users") @timestamps class User {
  id: i64,
  username: string,
  email: string,
  passwordHash: string,
  role: string,
  createdAt: i64,
  updatedAt: i64,
}

@table("tags") class Tag {
  id: i64,
  name: string,
}
```

## Check the behavior

The test named `GET /articles?q= runs a full-text search and returns the matching article`
in [`app.test.bit`](inkwell/app.test.bit) publishes an article with a unique
term, searches for it, and checks the response contains that term. Run the
app tests against the migrated PostgreSQL database from
[Testing the API](16-testing-the-api.md):

```text
bit test pkg/web/guides/inkwell
```

## Sharp edges

This path depends on PostgreSQL's `tsvector`, `plainto_tsquery`, `ts_rank`
and GIN index. Changing the connection to another database does not make
these statements portable. English rules also do not suit every language.

Keep this search for word-based discovery across titles and bodies. Use
ordinary filters for an exact author or slug. Use a different search design
when you need phrase syntax, typo tolerance, another language, or more than
this bounded first group of matches.

Previous: [Operations](17-operations.md).
Next: [Keep deleted articles recoverable](29-soft-deletes.md).
