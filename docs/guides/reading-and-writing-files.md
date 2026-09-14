# Read a file, write one safely

Most programs need to get text off disk and back onto it. Bit gives you two
ways in: one call for a whole file, and a buffered stream for one you cannot
hold in memory. Both report failure as a value, not a crash.

<!-- doctest: per-block -->

## The whole file, in one call

If the file is small, read it in one shot and move on.

```bit
import { readFile, writeFile } from "std/fs"

fn main(): ()! {
  writeFile("greeting.txt", "hello from bit\n")?
  let text = readFile("greeting.txt")?
  print(text)
  return
}
```

`writeFile` creates the file if it is missing and truncates it if it exists.
`readFile` returns everything in it as a `string`. Both are `T!`: propagate
the failure with `?`, as above, or handle it locally with `catch`.

## The file does not exist

Run the read against a path nothing has created:

```bit
import { readFile } from "std/fs"

fn main(): ()! {
  let text = readFile("no-such-file.txt")?
  print(text)
  return
}
```

That exits 1 and prints, to stderr:

```
error: cannot open file: no-such-file.txt
```

`open` and `readFile` fail the same way, because `readFile` is `open`, read,
close. Check first with `exists(path)` if a missing file is an expected case
you want to branch on rather than propagate; catch the error if you want a
default instead:

```bit
import { readFile } from "std/fs"

fn loadOrDefault(path: string): string {
  return readFile(path) catch "default text\n"
}

fn main() {
  print(loadOrDefault("no-such-file.txt"))
}
```

## A file too large to hold in memory

`readFile` reads the whole thing. For a file you only need to walk once, open
it and read a line at a time instead - the buffer stays small no matter how
long the file is.

```bit
import { open } from "std/fs"
import { reader } from "std/io"

fn countLines(path: string): int! {
  let f = open(path)?
  defer f.close()
  let r = reader(f.fd)
  let n = 0
  while (true) {
    match (r.readLine()) {
      Some(line) => { n = n + 1 }
      None => { return n }
    }
  }
  return n
}

fn main(): ()! {
  let n = countLines("greeting.txt")?
  println("lines = ${n}")
  return
}
```

`File.fd` is the raw descriptor a `File` wraps; `reader(f.fd)` puts a buffered
`Reader` in front of it. `readLine()` returns `Some(line)` for each line, and
`None` once at end of input - that is the only way the loop ends. The same
`File.fd` also works with `std/io`'s `writer` for buffered output.

## A write left half-finished

`writeFile` opens the target and writes straight into it. If the process dies
midway, whoever reads that path next gets a partial file, because the old
content is already gone and the new content is not all there yet. If a reader
must never see a half-written file, write to a temporary name in the same
directory, flush it to disk, then rename it over the real name. A rename that
replaces an existing file is atomic on the same filesystem: any reader sees
either the whole old file or the whole new one, never a mix.

```bit
import { create, rename, syncDir } from "std/fs"

fn atomicWrite(path: string, content: string): ()! {
  let tmp = path + ".tmp"
  let f = create(tmp)?
  f.write(content)?
  f.sync()?
  f.close()
  rename(tmp, path)?
  syncDir(".")?
  return
}

fn main(): ()! {
  atomicWrite("config.txt", "safe write\n")?
  return
}
```

`f.sync()` forces the new file's contents to disk before the rename points a
name at it. `syncDir(".")` then forces the directory entry itself to disk -
without it, a power failure right after a successful rename can still lose
the fact that the rename happened. Skip both and you still get an atomic
*swap*, just not a durable one across a crash.

## Sharp edges

- A missing parent directory fails the same way a missing file does:
  `writeFile("no/such/dir/out.txt", "x")` fails with
  `cannot create file: no/such/dir/out.txt`, because `create` does not make
  directories for you. Call `mkdir` first.
- `openNoFollow`/`readFileNoFollow` exist for the case where a path must not
  be a symlink at read time, even if it passed a separate check earlier -
  see [std/fs](../stdlib/fs.md#readfilenofollowpath-string-string) for when
  that check matters.
- `File.read(max)` (streaming, unbuffered) can return fewer bytes than `max`
  without that being end of file - only an empty result means end of file.
  `File.readAll()` handles that looping for you when you do want everything.

## What to read next

[std/fs](../stdlib/fs.md) and [std/io](../stdlib/io.md) list every function on
`File`, `Reader` and `Writer`. For what `?` and `catch` are doing above, see
[Handle errors](handle-errors.md).
