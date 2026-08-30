package main

import (
	"fmt"
	"os"
	"runtime"
)

type Node struct{ x, y, id int64 }

func main() {
	batches, per := 2000, 5000
	var total int64 = 0
	for b := 0; b < batches; b++ {
		nodes := make([]Node, 0, per)
		for k := 0; k < per; k++ {
			nodes = append(nodes, Node{x: int64(b + k), y: int64(k + 1), id: int64(b)})
		}
		for i := range nodes {
			total += nodes[i].x + nodes[i].y + nodes[i].id
		}
	}
	fmt.Printf("%d\n", total)
	reportAllocs()
}

// See bench/cases/alloc/alloc.go's copy: BENCH_ALLOC_STATS=1 prints this
// run's heap allocation count on stderr for bench/run.sh's cross-language
// comparison (#3934), off by default and after all timed work.
func reportAllocs() {
	if os.Getenv("BENCH_ALLOC_STATS") == "" {
		return
	}
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	fmt.Fprintf(os.Stderr, "[allocs] %d\n", ms.Mallocs)
}
