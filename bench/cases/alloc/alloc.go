package main

import "fmt"

type Node struct{ x, y int64 }

func main() {
	batches, per := 2000, 5000
	var total int64 = 0
	for b := 0; b < batches; b++ {
		batch := make([]*Node, 0, per)
		for k := 0; k < per; k++ {
			batch = append(batch, &Node{x: int64(b + k), y: int64(k + 1)})
		}
		for _, nd := range batch {
			total += nd.x + nd.y
		}
	}
	fmt.Printf("%d\n", total)
}
