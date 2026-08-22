# std/io

Buffered streams over file descriptors. `println` (from the prelude) issues one
write syscall per line; a `Writer` batches many writes into one.

A `Writer` and a `Reader` are classes, so they are reference types: their methods
mutate the stream in place. **Nothing flushes for you** - a `Writer` that goes
out of scope unflushed loses whatever it still holds.

<!-- doctest: per-block -->

## Standard descriptors

### `Stdin: i64`

`0` - the process's standard input.

### `Stdout: i64`

`1` - standard output.

### `Stderr: i64`

`2` - standard error.

## Writing

### `Writer`

A buffered output stream. Writes accumulate until the buffer fills or `flush` is
called.

### `writer(fd: i64): Writer`

A `Writer` over an already-open descriptor.

### `stdout(): Writer`

A `Writer` over `Stdout`.

### `stderr(): Writer`

A `Writer` over `Stderr`.

### `Writer.write(s: string)`

Buffers `s`, flushing on its own once the buffer is full.

### `Writer.writeLine(s: string)`

Buffers `s` and a newline.

### `Writer.flush()`

Writes everything buffered to the descriptor. A no-op when nothing is pending.

```bit
import { stdout, stderr } from "std/io"

// One syscall for the whole report, not one per line.
fn report(lines: []string) {
  let w = stdout()
  for line of lines {
    w.writeLine(line)
  }
  w.flush()
}

fn warn(msg: string) {
  let w = stderr()
  w.writeLine("warning: ${msg}")
  w.flush()
}
```

## Reading

### `Reader`

A buffered input stream, refilled from its descriptor a chunk at a time.

### `reader(fd: i64): Reader`

A `Reader` over an already-open descriptor.

### `stdin(): Reader`

A `Reader` over `Stdin`.

### `Reader.readLine(): Option<string>`

The next line without its trailing newline, or `None` at end of input. A final
line with no newline of its own is still returned.

### `Reader.readAll(): string`

Everything still unread, to end of input.

```bit
import { stdin, stdout } from "std/io"

// `None` means end of input - the only way the loop terminates.
fn echoLines() {
  let r = stdin()
  let w = stdout()
  while (true) {
    match (r.readLine()) {
      Some(line) => { w.writeLine(line) }
      None => {
        w.flush()
        return
      }
    }
  }
}

fn slurp(): string {
  return stdin().readAll()
}
```

### `Reader.readBytes(n: int): string`

Exactly `n` bytes, or fewer only when the input truly ends first. Bytes already
buffered by a prior `readLine` are consumed before any refill, so `readBytes`
composes with `readLine` on the same `Reader` - the basis for length-framed
protocols such as LSP's `Content-Length`. `n <= 0` reads nothing and touches no
input.

```bit
import { Reader } from "std/io"

// The integer after "Content-Length: " in an LSP header line.
fn parseLen(line: string): int {
  let n = 0
  let i = len("Content-Length: ")
  while (i < len(line) && line[i] >= '0' && line[i] <= '9') {
    n = n * 10 + int(line[i] - '0')
    i = i + 1
  }
  return n
}

// One LSP-style frame: header line, blank line, then exactly the body's bytes.
fn readFrame(r: Reader): string {
  let n = 0
  match (r.readLine()) {
    Some(h) => { n = parseLen(h) }
    None => { return "" }
  }
  r.readLine() // blank separator line
  return r.readBytes(n)
}
```
