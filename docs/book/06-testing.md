# Testing

Chapters 2 through 5 built `saveDraft`, `loadDraft`, `search` and
`searchTagPattern` and asked you to trust that they work. This chapter
checks them instead - `bit test` is a whole subcommand for exactly that,
and Inkwell already uses it: [`docs/book/ink/draft.test.bit`](ink/draft.test.bit),
[`store.test.bit`](ink/store.test.bit) and
[`search.test.bit`](ink/search.test.bit) are real files in the real
project, not this chapter's invention.

<!-- doctest: per-block -->

## A test block

A `test` declaration is Bit's only shape for a discoverable test: a string
naming what it checks, and a body that runs like any other function. This
is the real [`docs/book/ink/draft.test.bit`](ink/draft.test.bit):

<!-- doctest: test-file -->
```bit
export enum Status {
  Draft,
  Published,
  Archived,
}

export class Draft {
  export id: string
  export title: string
  export body: string
  export tags: []string
  export status: Status
  export created: i64
  export updated: i64

  export statusLabel(): string {
    return match (this.status) {
      Draft => "draft"
      Published => "published"
      Archived => "archived"
    }
  }
}

test "statusLabel names every Status variant" {
  let d = Draft{
    id = "1", title = "t", body = "b", tags = []string(0),
    status = Status.Draft, created = 0, updated = 0,
  }
  assert(d.statusLabel() == "draft", "want draft, got ${d.statusLabel()}")
  d.status = Status.Published
  assert(d.statusLabel() == "published", "want published, got ${d.statusLabel()}")
  d.status = Status.Archived
  assert(d.statusLabel() == "archived", "want archived, got ${d.statusLabel()}")
}
```

`assert(cond, msg)` is a built-in: it stops the test and prints `msg` if
`cond` is `false`, and does nothing if `cond` is `true`. A `test` file
lives beside the code it checks, in the same directory - `draft.test.bit`
next to `draft.bit` - and only `.test.bit` files may contain a `test`
declaration.

## Running the tests

```text
$ bit test docs/book/ink
docs/book/ink/draft.test.bit
  ok   statusLabel names every Status variant

docs/book/ink/search.test.bit
  ok   search matches title, body and tags, case-insensitively
  ok   searchTagPattern matches a regular expression against tags

docs/book/ink/store.test.bit
  ok   saveDraft then loadDraft returns the same fields
  ok   listDrafts includes a freshly saved draft

discovered 5 tests, ran 5: 5 passed, 0 failed
```

`bit test <dir>` builds every `.bit` file in `<dir>`, including its
`.test.bit` files, and runs every `test` block it finds. A failing
`assert` fails that one test and moves on to the next, rather than
stopping the whole run - `discovered 5 tests, ran 5` at the end tells you
none were skipped.

## Testing a failure path

`search.test.bit` checks `searchTagPattern`'s failure case too, using
`catch` from [chapter 4](04-when-things-go-wrong.md):

<!-- doctest: test-file -->
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

fn searchTagPattern(drafts: []Draft, pattern: string): []Draft! {
  fail newError("bad pattern: ${pattern}")
}

test "searchTagPattern fails on a bad pattern instead of matching nothing" {
  let drafts = []Draft(0)
  let result = searchTagPattern(drafts, "[") catch e {
    return
  }
  panic("want searchTagPattern to fail on an unclosed [, got ${len(result)} result(s)")
}
```

The real `searchTagPattern` (chapter 5) fails through `compile(pattern)?`
whenever `pattern` is not a valid regular expression; this test's stand-in
does the same thing directly, to show the shape without repeating
`std/regex`. A test that only ever calls the happy path never notices a
function that stopped handling its errors correctly.

## What you built

Every function Part 1 added has at least one `test` checking it, and
`bit test docs/book/ink` runs all of them in one command.

Part 1 is done: Inkwell saves, lists, and searches drafts on your laptop,
and you have tests proving it. Part 2 gives it real data, starting with a
settings file.
