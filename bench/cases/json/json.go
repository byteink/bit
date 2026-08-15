// Matches json.bit's data and output, NOT its code shape -- see json.bit's
// header for why. Decodes straight into a typed []Record via encoding/json,
// the idiomatic Go choice for a known schema.
package main

import (
	"encoding/json"
	"fmt"
	"strings"
)

type Record struct {
	Id     int64   `json:"id"`
	Name   string  `json:"name"`
	Active bool    `json:"active"`
	Tags   []int64 `json:"tags"`
}

func main() {
	recs := 30000
	var sb strings.Builder
	sb.WriteByte('[')
	for i := 0; i < recs; i++ {
		if i > 0 {
			sb.WriteByte(',')
		}
		active := "false"
		if i%2 == 0 {
			active = "true"
		}
		fmt.Fprintf(&sb, "{\"id\":%d,\"name\":\"user%d\",\"active\":%s,\"tags\":[%d,%d,%d]}",
			i, i, active, i%7, i%11, i%13)
	}
	sb.WriteByte(']')
	src := sb.String()

	var items []Record
	if err := json.Unmarshal([]byte(src), &items); err != nil {
		fmt.Printf("parse failed: %v\n", err)
		return
	}

	var idSum, tagSum, activeCount, nameLenSum int64
	for _, it := range items {
		idSum += it.Id
		if it.Active {
			activeCount++
		}
		nameLenSum += int64(len(it.Name))
		for _, t := range it.Tags {
			tagSum += t
		}
	}

	fmt.Printf("%d %d %d %d\n", idSum, tagSum, activeCount, nameLenSum)
}
