# Words and dates

`ink list` shows a title and not much else. Two questions a reader actually
asks before opening a draft are "how long is this" and "when did I last
touch it" - and "when" needs a real answer, not the 1,735,689,600 seconds
Inkwell has been storing. This chapter adds both, on top of the same `Draft`
[chapter 3](/book/03-what-is-a-draft) built:

```bit
export enum Status { Draft, Published, Archived }

export class Draft {
  id: string,
  title: string,
  body: string,
  tags: []string,
  status: Status,
  created: i64,
  updated: i64,
}
```

## Counting words without a library

A word is a run of non-whitespace. `std/regex`, already in Inkwell since
[chapter 5](/book/05-searching-drafts)'s search, splits on exactly that:

```bit
import { trimSpace } from "std/strings"
import { Regex, mustCompile } from "std/regex"

fn wordSplitter(): Regex {
  return mustCompile("\\s+")
}

// Words in `body`, split on runs of whitespace. `mustCompile` panics only on
// a pattern that fails to compile - "\\s+" always compiles, so this never
// panics on the input.
export fn wordCount(body: string): int {
  let trimmed = trimSpace(body)
  if (trimmed == "") {
    return 0
  }
  return len(wordSplitter().split(trimmed, -1))
}
```

`trimSpace` first matters at the edges: without it, `"  hi  "` would split
into `["", "hi", ""]` around the leading and trailing runs of whitespace,
and `wordCount` would answer 3 for a two-word draft.

## Reading time, from a word count and a setting

[Chapter 7](/book/07-settings-file)'s `Settings.wordsPerMinute` is exactly what this needs:

```bit
// Minutes to read `body` at `wordsPerMinute`, rounded up, at least 1 for a
// non-empty draft.
export fn readingMinutes(body: string, wordsPerMinute: int): int {
  let words = wordCount(body)
  if (words == 0) {
    return 0
  }
  let minutes = (words + wordsPerMinute - 1) / wordsPerMinute
  if (minutes < 1) {
    return 1
  }
  return minutes
}
```

`(words + wordsPerMinute - 1) / wordsPerMinute` is integer division rounding
up: 5 words at 200 words/minute is "less than a minute" to a person, and
this reports 1, never 0, for anything with at least one word.

## A date a person can read

`d.updated` is unix seconds - correct for storage, unreadable for a person.
`std/time`'s `Timestamp` turns it into a `DateTime` in a given zone, which
knows how to format itself:

```bit
import { Second, Timestamp, Zone } from "std/time"

// `d.updated` (unix seconds) read in `z` and formatted for a person, e.g.
// "1 September 2026 at 09:30".
export fn updatedAt(d: Draft, z: Zone): string! {
  let instant = Timestamp{ ns = d.updated * Second }
  return instant.inZone(z).format("d MMMM yyyy 'at' HH:mm")?
}
```

`Second` (`std/time`) is nanoseconds-per-second, so `d.updated * Second`
converts the stored unix seconds into the nanoseconds-since-epoch
`Timestamp` actually holds. `inZone` resolves that instant against a `Zone`
- `utc()` for a server, `localZone()` for a laptop showing its own clock -
and `format` renders the LDML pattern `"d MMMM yyyy 'at' HH:mm"` against the
result.

## Wiring it into main.bit

`cmdList` (chapter 2) grows one line, calling both functions above with
`settings.wordsPerMinute` from [chapter 7](/book/07-settings-file) and
`localZone()`:

```text
fn cmdList(): ()! {
  let drafts = listDrafts()?
  let z = localZone()
  for d of drafts {
    let minutes = readingMinutes(d.body, settings.wordsPerMinute)
    let when = updatedAt(d, z)?
    println("${d.id}  ${d.statusLabel()}  ${d.title}  (${minutes} min read, updated ${when})")
  }
}
```

so the listing reads "4 min read, updated 1 September 2026 at 09:30"
instead of a raw integer. A new command, `ink stats`, reports the same two
numbers summed over every draft instead of one at a time:

```text
fn cmdStats(): ()! {
  let drafts = listDrafts()?
  let words = 0
  let minutes = 0
  for d of drafts {
    words = words + wordCount(d.body)
    minutes = minutes + readingMinutes(d.body, settings.wordsPerMinute)
  }
  println("${len(drafts)} draft(s), ${words} word(s), ${minutes} minute(s) total reading time")
}
```

## Sharp edges

`format`'s pattern is LDML, not `strftime` - a stray `%d` produces garbage
silently parsed as literal characters, while an unbalanced `'` (used to
quote literal text like `'at'` above) fails with a pattern error. Reach for
[Standard library: time](/std/time) when a pattern does not render what you
expect.

## What you built

Every draft can now report how long it takes to read and when it was last
touched, in a person's own words - built entirely on `Settings`
([chapter 7](/book/07-settings-file))
and `std/time`, with no new field added to `Draft`.

Next: [A real database](/book/10-a-real-database).
