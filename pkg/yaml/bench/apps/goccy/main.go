// github.com/goccy/go-yaml's side of pkg/yaml's parse-throughput comparison
// (#5501).
//
// Reads the fixture path from argv[1], parses it once with UseOrderedMap()
// (a plain interface{} decode loses key order via Go's unordered map, which
// would make the checksum below non-comparable to pkg/yaml's []YamlEntry),
// and prints "docs=<N> nodes=<N> crc=<u32>" — the same line
// bench/apps/bit/main.bit and bench/apps/yamlv3/main.go print, encoded by
// the same canonicalWalk algorithm. run.sh refuses to time anything until
// all three checksums match.
package main

import (
	"fmt"
	"hash/crc32"
	"io"
	"os"
	"strings"

	goccy "github.com/goccy/go-yaml"
)

// canonicalWalk must stay byte-for-byte identical to bench/apps/bit/main.bit's
// canonicalWalk and bench/apps/yamlv3/main.go's — see that file's header for
// why. goccy's UseOrderedMap decode already resolves scalars to native Go
// types (string/bool/int64/uint64/float64/nil) with anchors expanded, so
// this walk is a plain type switch — no extra reflection beyond the one
// decode call every implementation here pays.
func canonicalWalk(v interface{}, b *strings.Builder) int64 {
	switch x := v.(type) {
	case goccy.MapSlice:
		count := int64(1)
		fmt.Fprintf(b, "M%d;", len(x))
		for _, it := range x {
			count += canonicalWalk(it.Key, b)
			count += canonicalWalk(it.Value, b)
		}
		return count
	case []interface{}:
		count := int64(1)
		fmt.Fprintf(b, "Q%d;", len(x))
		for _, it := range x {
			count += canonicalWalk(it, b)
		}
		return count
	case string:
		fmt.Fprintf(b, "S%d:%s;", len(x), x)
		return 1
	case bool:
		if x {
			b.WriteString("Bt;")
		} else {
			b.WriteString("Bf;")
		}
		return 1
	case int64:
		fmt.Fprintf(b, "I%d;", x)
		return 1
	case uint64:
		fmt.Fprintf(b, "I%d;", x)
		return 1
	case float64:
		fmt.Fprintf(b, "F%v;", x)
		return 1
	case nil:
		b.WriteString("N;")
		return 1
	default:
		fatalf("unexpected decoded type %T", v)
		return 0
	}
}

func fatalf(format string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, "goccybench: "+format+"\n", args...)
	os.Exit(1)
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: goccybench <path-to-yaml-file>")
		os.Exit(2)
	}
	f, err := os.Open(os.Args[1])
	if err != nil {
		fatalf("open: %v", err)
	}
	defer f.Close()

	var docs []interface{}
	dec := goccy.NewDecoder(f, goccy.UseOrderedMap())
	for {
		var v interface{}
		err := dec.Decode(&v)
		if err == io.EOF {
			break
		}
		if err != nil {
			fatalf("decode: %v", err)
		}
		docs = append(docs, v)
	}

	var b strings.Builder
	nodes := int64(0)
	for _, d := range docs {
		nodes += canonicalWalk(d, &b)
	}
	sum := crc32.Checksum([]byte(b.String()), crc32.MakeTable(crc32.Castagnoli))
	fmt.Printf("docs=%d nodes=%d crc=%d\n", len(docs), nodes, sum)
}
