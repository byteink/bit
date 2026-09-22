package main

import (
	"fmt"
	"os"
	"runtime"
	"sync"
)

// The Go side of bench/cases/allocpar: allocpar.bit's program with goroutines
// where it has `spawn`, allocating per node exactly as alloc.go does. Worker
// count is the same literal in all three sources and is never read from
// runtime.NumCPU -- see allocpar.bit's header for why.
const (
	workers          = 8
	batchesPerWorker = 250
	per              = 5000
)

type Batch struct{ id int64 }

type Node struct {
	x, y  int64
	owner *Batch
}

// Publishes into its own slot of `totals`, so nothing on the measured path
// synchronizes beyond the WaitGroup's own join.
func allocWorker(w int, totals []int64, wg *sync.WaitGroup) {
	defer wg.Done()
	var total int64 = 0
	lo, hi := w*batchesPerWorker, (w+1)*batchesPerWorker
	for b := lo; b < hi; b++ {
		owner := &Batch{id: int64(b)}
		nodes := make([]*Node, 0, per)
		for k := 0; k < per; k++ {
			nodes = append(nodes, &Node{x: int64(b + k), y: int64(k + 1), owner: owner})
		}
		for _, nd := range nodes {
			total += nd.x + nd.y + nd.owner.id
		}
	}
	totals[w] = total
}

func main() {
	totals := make([]int64, workers)
	var wg sync.WaitGroup
	wg.Add(workers)
	for w := 0; w < workers; w++ {
		go allocWorker(w, totals, &wg)
	}
	wg.Wait()
	var total int64 = 0
	for _, t := range totals {
		total += t
	}
	fmt.Printf("%d\n", total)
	reportAllocs()
}

// BENCH_ALLOC_STATS=1 prints this run's heap allocation count on stderr, as
// alloc.go does. Off by default and after all timed work, so a measured run
// pays nothing for it.
func reportAllocs() {
	if os.Getenv("BENCH_ALLOC_STATS") == "" {
		return
	}
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	fmt.Fprintf(os.Stderr, "[allocs] %d\n", ms.Mallocs)
}
