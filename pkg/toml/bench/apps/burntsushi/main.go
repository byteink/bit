// BurntSushi/toml's side of the parse-throughput comparison against
// pkg/toml and pelletier/go-toml/v2 (#5488). Mirrors ../bit/main.bit and
// ../gotoml/main.go exactly: same two modes, same canonical checksum, so
// run.sh can diff all three sides' stdout byte for byte.
package main

import (
	"fmt"
	"hash/crc32"
	"os"
	"sort"
	"time"

	"github.com/BurntSushi/toml"
)

var castagnoli = crc32.MakeTable(crc32.Castagnoli)

// Matches pkg/toml/bench/apps/bit/main.bit's `foldStr`: std/hash's
// crc32cUpdate is the zlib streaming convention (seed 0 is a fresh
// checksum), which is exactly what Go's crc32.Update implements over the
// same Castagnoli polynomial — no independent hash implementation here.
func foldStr(seed uint32, s string) uint32 {
	return crc32.Update(seed, castagnoli, []byte(s))
}

func pad(n int, width int) string {
	s := fmt.Sprintf("%d", n)
	for len(s) < width {
		s = "0" + s
	}
	return s
}

func canonDate(y, m, d int) string {
	return pad(y, 4) + "-" + pad(m, 2) + "-" + pad(d, 2)
}

func canonTime(h, mi, s, ns int) string {
	return pad(h, 2) + ":" + pad(mi, 2) + ":" + pad(s, 2) + "." + pad(ns, 9)
}

// Seconds-east-of-UTC offset, "+HH:MM" / "-HH:MM" — the same fixed-width
// component format ../bit/main.bit's canonOffset builds from DateTime's own
// accessors, built here from time.Time.Zone()'s offset seconds so neither
// side ever depends on a library's own RFC 3339 rendering.
func canonOffsetSuffix(offSec int) string {
	sign := "+"
	mag := offSec
	if offSec < 0 {
		sign = "-"
		mag = -offSec
	}
	return sign + pad(mag/3600, 2) + ":" + pad((mag%3600)/60, 2)
}

// Counts every key/value pair in the tree, matching main.bit's countEntries:
// each map entry counts once, plus its value's own count; array elements
// are walked but never counted themselves.
func countEntries(v interface{}) int64 {
	switch t := v.(type) {
	case map[string]interface{}:
		var total int64 = int64(len(t))
		for _, val := range t {
			total += countEntries(val)
		}
		return total
	case []interface{}:
		var total int64
		for _, item := range t {
			total += countEntries(item)
		}
		return total
	default:
		return 0
	}
}

// hashValue mirrors main.bit's hashValue/hashScalar exactly: same tag
// bytes, same canonical temporal text, same key-sorted table fold (Go's
// map iteration order is undefined, so sorting is the only order both
// sides of every comparison can agree on).
func hashValue(seed uint32, v interface{}) uint32 {
	switch t := v.(type) {
	case map[string]interface{}:
		return hashTable(seed, t)
	case []interface{}:
		return hashArray(seed, t)
	case localDateValue:
		return foldStr(seed, "D"+canonDate(t.year, t.month, t.day)+";")
	case localTimeValue:
		return foldStr(seed, "M"+canonTime(t.hour, t.minute, t.second, t.nanosecond)+";")
	case localDateTimeValue:
		return foldStr(seed, "N"+canonDate(t.year, t.month, t.day)+"T"+
			canonTime(t.hour, t.minute, t.second, t.nanosecond)+";")
	default:
		return hashScalar(seed, v)
	}
}

func hashScalar(seed uint32, v interface{}) uint32 {
	switch t := v.(type) {
	case string:
		return foldStr(seed, fmt.Sprintf("S%d:%s", len(t), t))
	case int64:
		return foldStr(seed, fmt.Sprintf("I%d;", t))
	case float64:
		return foldStr(seed, "F;")
	case bool:
		if t {
			return foldStr(seed, "Bt;")
		}
		return foldStr(seed, "Bf;")
	case timeValue:
		return foldStr(seed, "O"+canonDate(t.year, t.month, t.day)+"T"+
			canonTime(t.hour, t.minute, t.second, t.nanosecond)+canonOffsetSuffix(t.offsetSec)+";")
	default:
		return seed
	}
}

// BurntSushi/toml decodes every one of the four TOML date-time forms as
// time.Time (its own doc comment: "TOML datetimes correspond to
// time.Time"). The three LOCAL forms carry no offset, so the library tags
// them by giving each a distinct sentinel time.FixedZone name —
// "date-local" / "time-local" / "datetime-local" (internal/tz.go) — instead
// of the ordinary UTC/numeric zone an OFFSET date-time gets. wrapTimes
// below reads that name back out, which is the only way to recover which
// of the four forms a given time.Time came from once decoded into
// interface{} rather than a typed struct field.
type localDateValue struct{ year, month, day int }
type localTimeValue struct{ hour, minute, second, nanosecond int }
type localDateTimeValue struct{ year, month, day, hour, minute, second, nanosecond int }
type timeValue struct {
	year, month, day, hour, minute, second, nanosecond, offsetSec int
}

func hashTable(seed uint32, t map[string]interface{}) uint32 {
	keys := make([]string, 0, len(t))
	for k := range t {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	h := foldStr(seed, fmt.Sprintf("T%d:", len(keys)))
	for _, k := range keys {
		h = foldStr(h, fmt.Sprintf("K%d:%s=", len(k), k))
		h = hashValue(h, t[k])
	}
	return foldStr(h, "}")
}

func hashArray(seed uint32, items []interface{}) uint32 {
	h := foldStr(seed, fmt.Sprintf("A%d:", len(items)))
	for _, item := range items {
		h = hashValue(h, item)
	}
	return foldStr(h, "]")
}

// Rewrites every time.Time the decoder produced into one of the four
// value-only structs above, classified by its zone name (see the comment on
// those types), so hashValue/hashScalar can switch on the actual TOML form
// like any other leaf instead of importing "time" into their case lists.
func wrapTimes(v interface{}) interface{} {
	switch t := v.(type) {
	case time.Time:
		switch t.Location().String() {
		case "date-local":
			return localDateValue{year: t.Year(), month: int(t.Month()), day: t.Day()}
		case "time-local":
			return localTimeValue{hour: t.Hour(), minute: t.Minute(), second: t.Second(), nanosecond: t.Nanosecond()}
		case "datetime-local":
			return localDateTimeValue{
				year: t.Year(), month: int(t.Month()), day: t.Day(),
				hour: t.Hour(), minute: t.Minute(), second: t.Second(), nanosecond: t.Nanosecond(),
			}
		default:
			_, offset := t.Zone()
			return timeValue{
				year: t.Year(), month: int(t.Month()), day: t.Day(),
				hour: t.Hour(), minute: t.Minute(), second: t.Second(),
				nanosecond: t.Nanosecond(), offsetSec: offset,
			}
		}
	case map[string]interface{}:
		out := make(map[string]interface{}, len(t))
		for k, val := range t {
			out[k] = wrapTimes(val)
		}
		return out
	case []interface{}:
		out := make([]interface{}, len(t))
		for i, item := range t {
			out[i] = wrapTimes(item)
		}
		return out
	// An array of TABLES decodes as []map[string]interface{}, not the
	// []interface{} every other TOML array gets — BurntSushi's decoder
	// special-cases that one shape, unlike go-toml/v2 and pkg/toml, which
	// both give every array the same element type regardless of what is
	// inside it. Normalized to []interface{} here, the only place that has
	// to know about the difference, so countEntries/hashValue never do.
	case []map[string]interface{}:
		out := make([]interface{}, len(t))
		for i, item := range t {
			out[i] = wrapTimes(item)
		}
		return out
	default:
		return v
	}
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: burntsushibench <parse|checksum> <file.toml>")
		os.Exit(1)
	}
	mode, path := os.Args[1], os.Args[2]

	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	var doc interface{}
	if err := toml.Unmarshal(data, &doc); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	doc = wrapTimes(doc)

	n := countEntries(doc)
	if mode == "checksum" {
		h := hashValue(0, doc)
		fmt.Printf("entries=%d hash=%d\n", n, h)
		return
	}
	fmt.Printf("entries=%d\n", n)
}
