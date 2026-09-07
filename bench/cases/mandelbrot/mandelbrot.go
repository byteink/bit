package main

import (
	"fmt"
	"os"
	"runtime"
)

func main() {
	w, h, maxIter := 1500, 1500, 500
	var sum int64 = 0
	for py := 0; py < h; py++ {
		y0 := float64(py)/float64(h)*2.5 - 1.25
		for px := 0; px < w; px++ {
			x0 := float64(px)/float64(w)*3.5 - 2.5
			x, y := 0.0, 0.0
			iter := 0
			for iter < maxIter {
				x2 := x * x
				y2 := y * y
				if x2+y2 > 4.0 {
					break
				}
				y = 2.0*x*y + y0
				x = x2 - y2 + x0
				iter++
			}
			sum += int64(iter)
		}
	}
	fmt.Printf("%d\n", sum)
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
