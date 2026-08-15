// Matches strings.bit: build via strings.Builder, then window-slice, compare
// and concatenate.
package main

import (
	"fmt"
	"strings"
)

func mix(i int64) int64 { return ((i + 1) * 2654435761) % 2147483647 }

func main() {
	n := int64(3000000)
	var b strings.Builder
	for i := int64(0); i < n; i++ {
		tokLen := 3 + mix(i)%12
		for k := int64(0); k < tokLen; k++ {
			b.WriteByte(byte(97 + mix(i*37+k+1)%26))
		}
		b.WriteByte(' ')
	}
	s := b.String()
	total := int64(len(s))

	width := int64(8)
	windows := total / width
	matches := int64(0)
	for w := int64(0); w < windows-1; w++ {
		a := s[w*width : w*width+width]
		c := s[(w+1)*width : (w+1)*width+width]
		if a == c {
			matches++
		}
	}

	prefix := s[0:5000]
	suffix := s[total-5000 : total]
	joined := prefix + suffix
	joinedLen := int64(len(joined))

	fmt.Printf("%d %d %d\n", total, matches, joinedLen)
}
