// gin's side of the tier 1-2 comparison (#5418). Both routes set the exact
// Content-Type pkg/web sets and serialize with encoding/json, so the bodies
// and the header are byte-identical across all six servers.
package main

import (
	"encoding/json"
	"github.com/gin-gonic/gin"
)

type message struct {
	Message string `json:"message"`
}

func main() {
	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	body := []byte("Hello, World!")
	r.GET("/plaintext", func(c *gin.Context) {
		c.Data(200, "text/plain; charset=utf-8", body)
	})
	r.GET("/json", func(c *gin.Context) {
		b, err := json.Marshal(message{Message: "Hello, World!"})
		if err != nil {
			c.Status(500)
			return
		}
		c.Data(200, "application/json", b)
	})
	if err := r.Run("0.0.0.0:8082"); err != nil {
		panic(err)
	}
}
