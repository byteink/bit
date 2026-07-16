package main

import "fmt"

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
}
