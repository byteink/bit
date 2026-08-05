# std/fs

Files and directories. Every operation that can fail returns `T!`, so failure is
visible at the call site: propagate with `?`, or handle with `catch`.

<!-- doctest: per-block -->

## Whole files

Reach for these first. They open, transfer, and close in one call.

### `readFile(path: string): string!`

The entire contents of `path`.

### `writeFile(path: string, content: string): ()!`

Writes `content` to `path`, creating it or truncating what was there.

### `appendFile(path: string, content: string): ()!`

Appends `content` to `path`, creating it if absent.

```bit
import { readFile, writeFile, appendFile } from "std/fs"

function logLine(path: string, line: string): ()! {
  appendFile(path, line + "\n")?
  return
}

function copy(src: string, dst: string): ()! {
  writeFile(dst, readFile(src)?)?
  return
}
```

## Streaming a file

### `File`

An open file handle. Close it when done; nothing closes it for you.

### `open(path: string): File!`

Opens `path` for reading.

### `create(path: string): File!`

Creates or truncates `path` for writing.

### `openAppend(path: string): File!`

Opens `path` for writing at the end, creating it if absent.

### `File.read(max: int): string`

Up to `max` bytes. A shorter result than `max` - including `""` - means end of
file.

### `File.readAll(): string`

Everything left in the file.

### `File.write(s: string): ()!`

Writes `s`.

### `File.close()`

Releases the handle. Safe to call once; do not use the `File` afterwards.

```bit
import { create, open } from "std/fs"

function writeGreeting(path: string): ()! {
  let f = create(path)?
  f.write("hello")?
  f.close()
  return
}

function head(path: string, n: int): string! {
  let f = open(path)?
  let chunk = f.read(n)
  f.close()
  return chunk
}
```

## Inspecting

### `exists(path: string): bool`

Whether anything exists at `path`. Never fails: an unreadable parent reads as
absent.

### `isDir(path: string): bool`

Whether `path` exists and is a directory.

```bit
import { exists, isDir } from "std/fs"

function kind(path: string): string {
  if (!exists(path)) {
    return "missing"
  }
  if (isDir(path)) {
    return "directory"
  }
  return "file"
}
```

## Directories

### `mkdir(path: string): ()!`

Creates a directory. Fails if the parent does not exist or the name is taken.

### `remove(path: string): ()!`

Removes a file, or an **empty** directory.

### `readDir(path: string): []string!`

The names directly inside `path`, without `.` or `..`, in no guaranteed order.

### `walk(root: string): []string!`

Every file below `root`, recursively, as paths joined onto `root`. Directories
themselves are not included.

```bit
import { mkdir, readDir, walk, remove } from "std/fs"
import { join } from "std/strings"

function listing(dir: string): string! {
  return join(readDir(dir)?, "\n")
}

function fileCount(root: string): int! {
  return len(walk(root)?)
}

function scratch(path: string): ()! {
  mkdir(path)?
  remove(path)?
  return
}
```
