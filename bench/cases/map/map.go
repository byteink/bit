// Matches map.bit, using Go's built-in map.
// #4064: pre-sized for n entries with make(map[int64]int64, n), matching
// map.bit's map<i64,i64>(n) capacity hint and map.c's calloc-to-capacity, so
// none of the three pays for growth+rehash that the others do not.
package main

import "fmt"

func main() {
	n := int64(1500000)
	m := make(map[int64]int64, n)
	for i := int64(0); i < n; i++ {
		m[i] = i * 7
	}

	var sum1 int64
	for i := int64(0); i < n; i++ {
		sum1 += m[i]
	}

	for i := int64(0); i < n; i++ {
		if i%4 == 0 {
			delete(m, i)
		}
	}

	var sum2, remaining int64
	for i := int64(0); i < n; i++ {
		if v, ok := m[i]; ok {
			sum2 += v
			remaining++
		}
	}

	fmt.Printf("%d %d %d %d\n", sum1, remaining, sum2, int64(len(m)))
}
