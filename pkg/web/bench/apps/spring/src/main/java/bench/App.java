// Spring Boot's side of the tier 1-2 comparison (#5418). Both routes write
// the Content-Type pkg/web writes and declare a Content-Length: returning the
// record straight out of the handler makes Spring stream Jackson's output
// chunked, which is more wire bytes than the other five servers send for the
// same 27-byte body. Jackson still does the encoding, in the handler, exactly
// as gin, express, bun and ASP.NET encode theirs.
package bench;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import java.nio.charset.StandardCharsets;

@SpringBootApplication
@RestController
public class App {
    public record Message(String message) {}

    private final ObjectMapper mapper;

    public App(ObjectMapper mapper) {
        this.mapper = mapper;
    }

    @GetMapping(value = "/plaintext", produces = MediaType.TEXT_PLAIN_VALUE + "; charset=utf-8")
    public String plaintext() {
        return "Hello, World!";
    }

    @GetMapping("/json")
    public ResponseEntity<byte[]> json() throws JsonProcessingException {
        byte[] body = mapper.writeValueAsString(new Message("Hello, World!")).getBytes(StandardCharsets.UTF_8);
        return ResponseEntity.ok()
                .header("Content-Type", MediaType.APPLICATION_JSON_VALUE)
                .contentLength(body.length)
                .body(body);
    }

    public static void main(String[] args) {
        SpringApplication.run(App.class, args);
    }
}
