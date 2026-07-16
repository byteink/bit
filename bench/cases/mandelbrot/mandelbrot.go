package main

import "fmt"

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
}
