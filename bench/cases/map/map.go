// Matches map.bit, using Go's built-in map.
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
