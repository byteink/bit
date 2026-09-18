// pelletier/go-toml/v2's side of the parse-throughput comparison against
// pkg/toml and BurntSushi/toml (#5488). Mirrors ../bit/main.bit and
// ../burntsushi/main.go exactly: same two modes, same canonical checksum,
// so run.sh can diff all three sides' stdout byte for byte.
package main

import (
	"fmt"
	"hash/crc32"
	"os"
	"sort"
	"time"

	"github.com/pelletier/go-toml/v2"
)

var castagnoli = crc32.MakeTable(crc32.Castagnoli)

// Matches pkg/toml/bench/apps/bit/main.bit's `foldStr` and
// ../burntsushi/main.go's copy of it — see that file's comment; the three
// drivers deliberately keep this function textually identical.
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

func canonOffsetSuffix(offSec int) string {
	sign := "+"
	mag := offSec
	if offSec < 0 {
		sign = "-"
		mag = -offSec
	}
	return sign + pad(mag/3600, 2) + ":" + pad((mag%3600)/60, 2)
}

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

func hashValue(seed uint32, v interface{}) uint32 {
	switch t := v.(type) {
	case map[string]interface{}:
		return hashTable(seed, t)
	case []interface{}:
		return hashArray(seed, t)
	case toml.LocalDate:
		return foldStr(seed, "D"+canonDate(t.Year, t.Month, t.Day)+";")
	case toml.LocalTime:
		return foldStr(seed, "M"+canonTime(t.Hour, t.Minute, t.Second, t.Nanosecond)+";")
	case toml.LocalDateTime:
		return foldStr(seed, "N"+canonDate(t.LocalDate.Year, t.LocalDate.Month, t.LocalDate.Day)+"T"+
			canonTime(t.LocalTime.Hour, t.LocalTime.Minute, t.LocalTime.Second, t.LocalTime.Nanosecond)+";")
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

// go-toml/v2 decodes an offset date-time as time.Time, which this package
// cannot switch on directly in hashScalar without importing "time" into
// that switch's case list twice; unwrapped once here instead.
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

// Rewrites every time.Time the decoder produced (offset date-times only —
// go-toml/v2 already gives local forms their own LocalDate/LocalTime/
// LocalDateTime types) into timeValue, so hashScalar can switch on it like
// any other leaf instead of importing "time" into two files' case lists.
func wrapTimes(v interface{}) interface{} {
	switch t := v.(type) {
	case time.Time:
		_, offset := t.Zone()
		return timeValue{
			year: t.Year(), month: int(t.Month()), day: t.Day(),
			hour: t.Hour(), minute: t.Minute(), second: t.Second(),
			nanosecond: t.Nanosecond(), offsetSec: offset,
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
	default:
		return v
	}
}

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: gotomlbench <parse|checksum> <file.toml>")
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
