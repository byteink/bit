// gopkg.in/yaml.v3's side of pkg/yaml's parse-throughput comparison (#5501).
//
// Reads the fixture path from argv[1], parses it once into yaml.Node (the
// library's order-preserving AST — a plain interface{} decode loses key
// order via Go's unordered map, which would make the checksum below
// non-comparable to pkg/yaml's []YamlEntry), and prints
// "docs=<N> nodes=<N> crc=<u32>" — the same line bench/apps/bit/main.bit
// prints, encoded by the same canonicalWalk algorithm. run.sh refuses to
// time anything until both checksums match.
package main

import (
	"fmt"
	"hash/crc32"
	"io"
	"os"
	"strconv"
	"strings"

	yaml "gopkg.in/yaml.v3"
)

// canonicalWalk must stay byte-for-byte identical to bench/apps/bit/main.bit's
// canonicalWalk and bench/apps/goccy/main.go's — see that file's header for
// why (the checksum is the agreement proof this whole benchmark rests on).
// No reflection (n.Decode would pull in the reflect package's cost on every
// scalar): tag-driven manual parsing keeps this walk's cost comparable to
// the other two sides, so the three binaries are timed on comparable work.
func canonicalWalk(n *yaml.Node, b *strings.Builder) int64 {
	if n.Kind == yaml.AliasNode {
		return canonicalWalk(n.Alias, b)
	}
	switch n.Kind {
	case yaml.MappingNode:
		count := int64(1)
		fmt.Fprintf(b, "M%d;", len(n.Content)/2)
		for i := 0; i+1 < len(n.Content); i += 2 {
			count += canonicalWalk(n.Content[i], b)
			count += canonicalWalk(n.Content[i+1], b)
		}
		return count
	case yaml.SequenceNode:
		count := int64(1)
		fmt.Fprintf(b, "Q%d;", len(n.Content))
		for _, c := range n.Content {
			count += canonicalWalk(c, b)
		}
		return count
	case yaml.ScalarNode:
		switch n.ShortTag() {
		case "!!null":
			b.WriteString("N;")
		case "!!bool":
			switch n.Value {
			case "true", "True", "TRUE":
				b.WriteString("Bt;")
			case "false", "False", "FALSE":
				b.WriteString("Bf;")
			default:
				fatalf("unrecognized !!bool spelling %q", n.Value)
			}
		case "!!int":
			v, err := strconv.ParseInt(n.Value, 0, 64)
			if err != nil {
				fatalf("!!int %q: %v", n.Value, err)
			}
			fmt.Fprintf(b, "I%d;", v)
		case "!!float":
			v, err := strconv.ParseFloat(n.Value, 64)
			if err != nil {
				fatalf("!!float %q: %v", n.Value, err)
			}
			fmt.Fprintf(b, "F%v;", v)
		case "!!str":
			fmt.Fprintf(b, "S%d:%s;", len(n.Value), n.Value)
		default:
			b.WriteString("?;")
		}
		return 1
	default:
		fatalf("unexpected node kind %v", n.Kind)
		return 0
	}
}

func fatalf(format string, args ...interface{}) {
	fmt.Fprintf(os.Stderr, "yamlv3bench: "+format+"\n", args...)
	os.Exit(1)
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: yamlv3bench <path-to-yaml-file>")
		os.Exit(2)
	}
	f, err := os.Open(os.Args[1])
	if err != nil {
		fatalf("open: %v", err)
	}
	defer f.Close()

	var docs []*yaml.Node
	dec := yaml.NewDecoder(f)
	for {
		var doc yaml.Node
		err := dec.Decode(&doc)
		if err == io.EOF {
			break
		}
		if err != nil {
			fatalf("decode: %v", err)
		}
		docs = append(docs, &doc)
	}

	var b strings.Builder
	nodes := int64(0)
	for _, d := range docs {
		nodes += canonicalWalk(d.Content[0], &b)
	}
	sum := crc32.Checksum([]byte(b.String()), crc32.MakeTable(crc32.Castagnoli))
	fmt.Printf("docs=%d nodes=%d crc=%d\n", len(docs), nodes, sum)
}
