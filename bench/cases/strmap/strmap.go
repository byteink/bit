// Matches strmap.bit, using Go's built-in map[string]int64.
// Key set, phase order and printed answer are identical; see strmap.bit for
// why the case exists and how it is sized.
package main

import (
	"fmt"
	"os"
	"runtime"
)

func mix(i int64) int64 { return ((i + 1) * 2654435761) % 2147483647 }

func main() {
	n := int64(200000)
	total := n * 2
	width := int64(16)
	reps := int64(30)

	blob := make([]byte, total*width)
	for i := int64(0); i < total; i++ {
		q := i
		j := int64(0)
		for ; j < 4; j++ {
			blob[i*width+j] = byte(97 + q%26)
			q /= 26
		}
		for ; j < width; j++ {
			blob[i*width+j] = byte(97 + mix(i*37+j+1)%26)
		}
	}

	keys := make([]string, total)
	for i := int64(0); i < total; i++ {
		keys[i] = string(blob[i*width : i*width+width])
	}

	m := make(map[string]int64, n)
	for i := int64(0); i < n; i++ {
		m[keys[i]] = i * 7
	}

	var hits int64
	for r := int64(0); r < reps; r++ {
		for i := int64(0); i < n; i++ {
			hits += m[keys[i]]
		}
	}

	var misses int64
	for r := int64(0); r < reps; r++ {
		for i := n; i < total; i++ {
			if _, ok := m[keys[i]]; !ok {
				misses++
			}
		}
	}

	for i := int64(0); i < n; i++ {
		if i%4 == 0 {
			delete(m, keys[i])
		}
	}

	var sum2, remaining int64
	for i := int64(0); i < n; i++ {
		if v, ok := m[keys[i]]; ok {
			sum2 += v
			remaining++
		}
	}

	fmt.Printf("%d %d %d %d %d\n", hits, misses, remaining, sum2, int64(len(m)))
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
