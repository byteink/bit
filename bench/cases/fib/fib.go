package main

import (
	"fmt"
	"os"
	"runtime"
)

func fib(n int64) int64 {
	if n < 2 {
		return n
	}
	return fib(n-1) + fib(n-2)
}

func main() {
	fmt.Printf("%d\n", fib(40))
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
