# std/csv

RFC 4180 CSV, in and out. Two functions, symmetric with `std/json`:
`csvParse` reads text into `[][]string`, `csvFormat` writes `[][]string`
back to text. Both agree on the quoting rules everyone gets right, and on
the one everyone gets wrong quietly: a newline inside a quoted field is
data, not a record boundary, so a note field that happens to contain one
does not shift every later row.

A field is quoted, with any `"` inside it doubled, when it contains a
comma, a quote, or a newline (`\n` or `\r`); an ordinary field is written
bare. A record may end `\r\n` or `\n`, and the last record in the input may
have no terminator at all - `csvParse` handles both without complaint.
`csvFormat` always writes `\n`.

Deliberately out of scope: a configurable delimiter, header-to-struct
mapping, choosing the output terminator, and a streaming `io.Reader`
variant. Every input is read as a single in-memory `string`.

<!-- doctest: per-block -->

## Parsing

### `csvParse(source: string): [][]string!`

Parses `source` into records, each a slice of field values. Fails only on
an unterminated quoted field - an opening `"` with no matching close
before the end of input.

```bit
import { csvParse } from "std/csv"

fn parseExample(): int! {
  let records = csvParse("name,note\nAda,\"met at RC,\ntwice\"\n")?
  let note = records[1][1]
  return len(note)
}
```

## Formatting

### `csvFormat(records: [][]string): string`

Formats `records` as CSV text: comma-separated fields, one record per
line, each terminated with `\n`. Quotes only the fields that need it.

```bit
import { csvFormat } from "std/csv"

fn formatExample(): string {
  let rows = [][]string{ []string{ "name", "note" }, []string{ "Ada", "met at RC, twice" } }
  return csvFormat(rows)
}
```

## Round-tripping

`csvParse(csvFormat(records))` reproduces `records` field-for-field. The
converse holds for any input `csvParse` accepts, up to the one choice this
module does not make: `csvFormat` always writes `\n`, so a source that used
`\r\n` re-formats with a different terminator even though every field value
is unchanged.

```bit
import { csvParse, csvFormat } from "std/csv"

fn roundTrips(): bool! {
  let source = "a,\"b,c\",\"say \"\"hi\"\"\",\"line1\nline2\"\r\n"
  let records = csvParse(source)?
  let back = csvParse(csvFormat(records))?
  return len(records) == len(back) && len(records[0]) == len(back[0])
}
```
