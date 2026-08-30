package main

import (
	"fmt"
	"os"
	"runtime"
)

type Batch struct{ id int64 }

type Node struct {
	x, y  int64
	owner *Batch
}

func main() {
	batches, per := 2000, 5000
	var total int64 = 0
	for b := 0; b < batches; b++ {
		owner := &Batch{id: int64(b)}
		nodes := make([]*Node, 0, per)
		for k := 0; k < per; k++ {
			nodes = append(nodes, &Node{x: int64(b + k), y: int64(k + 1), owner: owner})
		}
		for _, nd := range nodes {
			total += nd.x + nd.y + nd.owner.id
		}
	}
	fmt.Printf("%d\n", total)
	reportAllocs()
}

// BENCH_ALLOC_STATS=1 prints this run's heap allocation count on stderr, so
// bench/run.sh can compare it against the Bit and C sides of the same case
// (#3934: the three sources drifted into different data structures and the
// row went on comparing them for a day). Off by default and after all timed
// work, so a measured run pays nothing for it.
func reportAllocs() {
	if os.Getenv("BENCH_ALLOC_STATS") == "" {
		return
	}
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	fmt.Fprintf(os.Stderr, "[allocs] %d\n", ms.Mallocs)
}
