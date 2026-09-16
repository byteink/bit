# std/decimal

You're totalling a shopping cart. The prices came in as text - typed into a
form, or read out of a database column - and you add them up and show the
customer a total. Do that with `f64` and `19.99 + 0.01` can come out as
`20.009999999999998`: correct IEEE-754 binary floating point, and the wrong
answer for money, because 0.01 has no exact binary representation. A customer
who notices their receipt is a fraction of a cent off does not care why.

`decimal` is Bit's exact base-10 number type (SPEC §11.1): a sign, a scale,
and a 96-bit mantissa, two `i64` words wide with no allocation. `19.99 + 0.01`
is exactly `20.00`, every time, because the value is stored in base 10 to
begin with. `std/decimal` is the text and rounding surface around it: turning
a `decimal` into the text a receipt shows, turning text a user or a database
handed you back into a `decimal`, and rounding to a stated number of places
under a stated rule - because "round to the nearest cent" and "round to the
nearest cent, my way" are different requirements and this module makes you
say which.

<!-- doctest: per-block -->

## Adding decimals

`decimal` has its own literals and its own `+`, `-`, `*`, `/`, so the
simplest correct total is arithmetic on the type itself:

```bit
fn subtotal(): decimal {
  let a: decimal = 19.99
  let b: decimal = 0.01
  return a + b
}
```

`subtotal()` returns exactly `20.00`. String interpolation (`"${subtotal()}"`)
already renders it as text with no extra step.

## Rendering a decimal as text

### `toString(d: decimal): string`

The exact value of `d`, at `d`'s own scale: `.` as the decimal point, no
thousands separator, no currency symbol, no padding. `20.00` renders as
`"20.00"` and not `"20"`, because the scale is part of the value - a price
that arrived with two fractional digits still has two after a round trip.

This is what `"${d}"` calls, so the two are interchangeable and you rarely
need to name it directly. Reach for it where you need the string itself
rather than a string containing it - a `[]string` of rendered rows, a
comparison against text, a value handed to a writer.

Money for a human reader is a separate job: a thousands separator, a
currency symbol and a locale's own decimal point belong at the display
layer, not in a numeric type. See "When not to use it" below.

## Parsing text into a decimal

### `parseDecimal(s: string): decimal!`

The `decimal` that text `s` denotes: an optional sign, digits, an optional
`.` and more digits, and an optional exponent - nothing else. No leading or
trailing whitespace, no thousands separator, no currency symbol: a parser
that tolerates `"1,234"` is how an invoice becomes wrong by three orders of
magnitude, so this one refuses instead of guessing - the same fallible
`T!` idiom `std/strings.parseInt` uses, handled with `?`/`catch` (SPEC
§12.11).

Now the cart total can come from text - the shape a web form or a
database's `numeric` column actually hands you, which is `parseDecimal`'s own
reason to exist:

```bit
import { parseDecimal, toString } from "std/decimal"

fn total(prices: []string): string! {
  let sum: decimal = 0
  let i = 0
  while (i < len(prices)) {
    let price = parseDecimal(prices[i]) catch err {
      fail newError("bad price '${prices[i]}': ${err.message()}")
    }
    sum = sum + price
    i = i + 1
  }
  return toString(sum)
}
```

A price too large for `decimal`'s 96-bit precision fails here too, with a
message naming the problem - never a silently rounded total.

## Rounding

### `round(d: decimal, scale: int, mode: RoundMode): decimal`

`d` rounded to `scale` fractional digits under `mode`. Neither has a default:
a currency fixes the scale (cents means `2`) and a jurisdiction fixes the
mode, so the caller always states both rather than inheriting a guess. A
negative `scale` rounds to tens, hundreds, and so on - `round(d, -2, mode)`
rounds to the nearest hundred.

### `RoundMode`

How a value rounds when the digit being dropped sits exactly halfway:

- `HalfEven` - to the even neighbor (banker's rounding; the type's own
  default for `/`, so repeated rounding does not drift high).
- `HalfUp` - away from zero.
- `HalfDown` - toward zero.
- `Floor` - toward negative infinity, regardless of the halfway digit.
- `Ceiling` - toward positive infinity, regardless of the halfway digit.
- `Truncate` - toward zero always, ignoring every dropped digit.

The real use case: finish the invoice by adding tax, rounded to the cent
under whichever rule the jurisdiction uses:

```bit
import { parseDecimal, toString, round, RoundMode } from "std/decimal"

fn invoiceTotal(prices: []string, taxRate: decimal): string! {
  let subtotal: decimal = 0
  let i = 0
  while (i < len(prices)) {
    let price = parseDecimal(prices[i]) catch err {
      fail newError("bad price '${prices[i]}': ${err.message()}")
    }
    subtotal = subtotal + price
    i = i + 1
  }
  let tax = round(subtotal * taxRate, 2, RoundMode.HalfEven)
  return toString(subtotal + tax)
}
```

The six modes on the same value show why the mode is never a default -
`2.345` rounded to two places sits exactly halfway between `2.34` and `2.35`,
and each mode answers differently:

```bit
import { round, toString, RoundMode } from "std/decimal"

fn allModes(): []string {
  let x: decimal = 2.345
  return []string{
    toString(round(x, 2, RoundMode.HalfEven)), // "2.34" - 4 is even
    toString(round(x, 2, RoundMode.HalfUp)),   // "2.35" - away from zero
    toString(round(x, 2, RoundMode.HalfDown)), // "2.34" - toward zero
    toString(round(x, 2, RoundMode.Floor)),    // "2.34"
    toString(round(x, 2, RoundMode.Ceiling)),  // "2.35"
    toString(round(x, 2, RoundMode.Truncate)), // "2.34"
  }
}
```

Rounding to a coarser unit than the cent works the same way, with a negative
`scale`:

```bit
import { round, RoundMode } from "std/decimal"

fn nearestHundred(amount: decimal): decimal {
  return round(amount, -2, RoundMode.HalfUp)
}
```

## Sharp edges

`parseDecimal` rejects anything a spreadsheet or a careless template might
hand you - test this before trusting user input:

```bit
import { parseDecimal } from "std/decimal"

fn parses(s: string): bool {
  let zero: decimal = 0
  let ok = true
  parseDecimal(s) catch _ {
    ok = false
    zero
  }
  return ok
}

fn rejectsMessyInput(): bool {
  let leadingSpace = !parses(" 19.99") // leading whitespace
  let currency = !parses("$19.99")     // currency symbol
  let thousands = !parses("19,99")     // thousands/decimal-comma separator
  return leadingSpace && currency && thousands
}
```

`round`'s own signature is not fallible - it panics rather than returning an
error, the same "panics rather than wrapping" contract every other decimal
overflow already has (SPEC §11.1) - so a `scale` so extreme that
reconstructing the rounded value would exceed 96-bit precision panics
instead. In practice this only happens at scales far outside anything a real
currency or unit uses.

## When not to use it

`decimal` has no square root, no trigonometry, no exponentials - it is exact
base-10 arithmetic for money and counted quantities, not a general numeric
type. Reach for `f64` and `std/math` for scientific or geometric
computation, where an exact decimal representation buys nothing and the
`decimal`/`f64` conversion is deliberately not provided (SPEC §12.9).

`toString` never adds a thousands separator or a currency symbol, and never
will - that is locale-aware formatting, an `i18n` concern, not this module's.
Format the string `toString` gives you at the display layer.

## Specification

SPEC §11.1 (the type), §12.9 (conversions).
