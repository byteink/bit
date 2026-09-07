package main

import (
	"fmt"
	"os"
	"runtime"
)

func collatz(start int64) int64 {
	n, steps := start, int64(0)
	for n != 1 {
		if n%2 == 0 {
			n = n / 2
		} else {
			n = 3*n + 1
		}
		steps++
	}
	return steps
}

func main() {
	best := int64(0)
	for i := int64(1); i < 1000000; i++ {
		if s := collatz(i); s > best {
			best = s
		}
	}
	fmt.Printf("%d\n", best)
	reportAllocs()
}

// BENCH_ALLOC_STATS=1 prints this run's heap allocation count on stderr, so
// bench/run.sh can compare it against the Bit and C sides of the same case
// (#3934). Off by default and after all timed work, so a measured run pays
// nothing for it.
func reportAllocs() {
	if os.Getenv("BENCH_ALLOC_STATS") == "" {
		return
	}
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	fmt.Fprintf(os.Stderr, "[allocs] %d\n", ms.Mallocs)
}
