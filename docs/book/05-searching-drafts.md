# Searching drafts

`ink list` (chapter 2) shows every draft. Once you have more than a
handful, you want `ink search <word>` to show only the ones that matter
right now.

## Looping over a slice

`tags` (chapter 3) is a `[]string`: a **slice**, an ordered, growable list.
`for x of xs` walks one, giving you each element in order - the same
`for` chapter 2's `listDrafts` used to read every file in a directory.
This is the real [`docs/book/ink/search.bit`](ink/search.bit), against the
same `Draft` and `Status` from [chapter 3](03-what-is-a-draft.md):

```bit
export enum Status {
  Draft,
  Published,
  Archived,
}

export class Draft {
  export id: string,
  export title: string,
  export body: string,
  export tags: []string,
  export status: Status,
  export created: i64,
  export updated: i64,
}
```

```bit
import { contains, toLower } from "std/strings"

export fn search(drafts: []Draft, query: string): []Draft {
  let q = toLower(query)
  let out = []Draft(0)
  for d of drafts {
    if (matchesQuery(d, q)) {
      out = append(out, d)
    }
  }
  return out
}

fn matchesQuery(d: Draft, q: string): bool {
  if (contains(toLower(d.title), q)) {
    return true
  }
  if (contains(toLower(d.body), q)) {
    return true
  }
  for t of d.tags {
    if (contains(toLower(t), q)) {
      return true
    }
  }
  return false
}
```

`search` builds a fresh `[]Draft` and appends every draft that matches -
never mutates `drafts` itself. `matchesQuery` loops over `d.tags` the same
way, an inner `for` inside the outer one: a draft matches if the word
shows up in its title, its body, or any one of its tags. `toLower` and
`contains` (`std/strings`) are what make the search case-insensitive: `"
Coffee"` and `"coffee"` compare equal once both sides are lowered.

## A map, revisited

[chapter 2](02-saving-drafts.md)'s `decode` already used a **map**,
`map<string, string>()`, to
hold a draft file's header fields by name before turning them into a
`Draft`. A slice keeps things in order and lets you have the same value
twice; a map looks things up by key and never has two entries with the
same one - `fields["title"]` is unambiguous in a way `tags[2]` naming "the
third tag" is not. `search` above does not need one; `decode` does,
because a header's fields can arrive in any order.

## Matching a pattern, not just a word

A plain substring search cannot tell you "every tag that looks like
`note-<number>`." For that, Inkwell reaches for `std/regex`, a **regular
expression**: a small pattern language for describing a shape a string
should have, rather than one exact string to find.

```bit
import { compile, Regex } from "std/regex"

export fn searchTagPattern(drafts: []Draft, pattern: string): []Draft! {
  let re = compile(pattern)?
  let out = []Draft(0)
  for d of drafts {
    if (matchesAnyTag(d, re)) {
      out = append(out, d)
    }
  }
  return out
}

fn matchesAnyTag(d: Draft, re: Regex): bool {
  for t of d.tags {
    if (re.matches(t)) {
      return true
    }
  }
  return false
}
```

`compile(pattern)` turns a pattern string like `"^note-\\d+$"` into a
`Regex`, or fails if the pattern is malformed - `?` sends that failure up,
same as chapter 4. `re.matches(t)` is `true` if `t` matches the pattern
anywhere; `^` and `$` anchor it to the whole tag, and `\d+` means "one or
more digits." `searchTagPattern` finds every draft with at least one tag
matching that shape.

## Try it

```bit
fn main(): ()! {
  let drafts = [
    Draft{
      id = "1", title = "Morning routine", body = "wake, stretch, coffee",
      tags = []string{ "habits" }, status = Status.Draft, created = 0, updated = 0,
    },
    Draft{
      id = "2", title = "Recipe", body = "flour, water, salt",
      tags = []string{ "note-1" }, status = Status.Draft, created = 0, updated = 0,
    },
  ]
  for d of search(drafts, "coffee") {
    println(d.title) // Morning routine
  }
  for d of searchTagPattern(drafts, "^note-\\d+$")? {
    println(d.title) // Recipe
  }
}
```

## What you built

`search` walks a `[]Draft` with `for` and builds a new one with `append`;
`searchTagPattern` does the same with a compiled `std/regex` pattern
instead of a plain substring. Both read, neither ever changes, the slice
you hand them.

Next: [chapter 6, testing](06-testing.md), where you check that `search`
and `searchTagPattern` actually do what this chapter claims.
