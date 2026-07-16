package main

import "fmt"

type Node struct{ x, y int64 }

func main() {
	var n int64 = 20000000
	var sum int64 = 0
	for i := int64(0); i < n; i++ {
		p := &Node{x: i, y: i + 1}
		sum += p.x + p.y
	}
	fmt.Printf("%d\n", sum)
}
