// Matches matrix.bit exactly: same data, same i-k-j loop order, same 6
// trials.
package main

import (
	"fmt"
	"os"
	"runtime"
)

func main() {
	n, trials := 512, 6
	var grandSum, grandTrace, lastFirst, lastLast int64
	a := make([]float64, n*n)
	b := make([]float64, n*n)
	c := make([]float64, n*n)

	for t := 0; t < trials; t++ {
		for i := range c {
			c[i] = 0.0
		}

		for i := 0; i < n; i++ {
			for j := 0; j < n; j++ {
				a[i*n+j] = float64((i + j + t) % 13)
				b[i*n+j] = float64((i*2 + j*3 + t) % 17)
			}
		}

		for i := 0; i < n; i++ {
			for k := 0; k < n; k++ {
				aik := a[i*n+k]
				for j := 0; j < n; j++ {
					c[i*n+j] += aik * b[k*n+j]
				}
			}
		}

		var sum, trace float64
		for i := 0; i < n*n; i++ {
			sum += c[i]
		}
		for d := 0; d < n; d++ {
			trace += c[d*n+d]
		}

		grandSum += int64(sum)
		grandTrace += int64(trace)
		lastFirst = int64(c[0])
		lastLast = int64(c[n*n-1])
	}

	fmt.Printf("%d %d %d %d\n", grandSum, grandTrace, lastFirst, lastLast)
	reportAllocs()
}

// See bench/cases/alloc/alloc.go's copy: BENCH_ALLOC_STATS=1 prints this
// run's heap allocation count on stderr for bench/run.sh's cross-language
// comparison (#3934), off by default and after all timed work. Added by
// #4056: without it this case's allocation row printed "—" for Go and C, so
// nothing could see the Bit side allocating 18 matrices to their 3.
func reportAllocs() {
	if os.Getenv("BENCH_ALLOC_STATS") == "" {
		return
	}
	var ms runtime.MemStats
	runtime.ReadMemStats(&ms)
	fmt.Fprintf(os.Stderr, "[allocs] %d\n", ms.Mallocs)
}
