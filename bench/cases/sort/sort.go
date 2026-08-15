// Matches sort.bit, using Go's sort.Slice (typically a pattern-defeating
// quicksort) -- see sort.bit's header for the fairness note on differing
// algorithms.
package main

import (
	"fmt"
	"sort"
)

func mix(i int64) int64 { return ((i + 1) * 2654435761) % 2147483647 }

func main() {
	mod := int64(1000000007)

	n := int64(800000)
	xs := make([]int64, n)
	for i := int64(0); i < n; i++ {
		xs[i] = mix(i)
	}
	sort.Slice(xs, func(i, j int) bool { return xs[i] < xs[j] })

	sortedOk1 := true
	for i := int64(1); i < n; i++ {
		if xs[i] < xs[i-1] {
			sortedOk1 = false
			break
		}
	}

	var checksum1 int64
	for i := int64(0); i < n; i++ {
		checksum1 = (checksum1 + (xs[i]%mod)*(i+1)) % mod
	}

	m := int64(150000)
	ss := make([]string, m)
	for i := int64(0); i < m; i++ {
		tokLen := 3 + mix(i)%12
		buf := make([]byte, tokLen)
		for k := int64(0); k < tokLen; k++ {
			buf[k] = byte(97 + mix(i*37+k+1)%26)
		}
		ss[i] = string(buf)
	}
	sort.Slice(ss, func(i, j int) bool { return ss[i] < ss[j] })

	sortedOk2 := true
	for i := int64(1); i < m; i++ {
		if ss[i] < ss[i-1] {
			sortedOk2 = false
			break
		}
	}

	var checksum2 int64
	for i := int64(0); i < m; i++ {
		var bytesum int64
		for _, c := range []byte(ss[i]) {
			bytesum += int64(c)
		}
		checksum2 = (checksum2 + bytesum*(i+1)) % mod
	}

	fmt.Printf("%d %t %d %t\n", checksum1, sortedOk1, checksum2, sortedOk2)
}
