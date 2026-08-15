// Matches matrix.bit exactly: same data, same i-k-j loop order.
package main

import "fmt"

func main() {
	n := 512
	a := make([]float64, n*n)
	b := make([]float64, n*n)
	c := make([]float64, n*n)

	for i := 0; i < n; i++ {
		for j := 0; j < n; j++ {
			a[i*n+j] = float64((i + j) % 13)
			b[i*n+j] = float64((i*2 + j*3) % 17)
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

	fmt.Printf("%d %d %d %d\n", int64(sum), int64(trace), int64(c[0]), int64(c[n*n-1]))
}
