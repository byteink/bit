# std/process

A build script shells out to `wc -l` to see how many lines a generated file
has, so it can decide whether the generator actually ran. `std/os`'s `run`
starts the child with its stdout and stderr wired straight to this process's
own, exactly like typing the command at a terminal yourself: you see what it
printed, but your program never gets that text back as a value, only the
exit code. `std/process`'s `output` runs the child the same way but hands
you its stdout, its stderr and its exit code back as a `RunResult`, so the
script can actually read what `wc` said.

<!-- doctest: per-block -->

## The simplest call

### `output(path: string, args: []string, timeoutMs: int = 0): RunResult`

```bit
import { output } from "std/process"

fn main() {
  let r = output("/bin/echo", ["hello", "from", "output"])
  print("stdout: ${r.stdout}")
  print("stderr empty: ${len(r.stderr) == 0}\n")
  print("exit: ${r.exitCode} truncated: ${r.truncated}\n")
}
```

```
stdout: hello from output
stderr empty: true
exit: 0 truncated: false
```

`output(path, args)` runs `path` exactly the way `run` does (no shell, `args`
is the argument vector, `path` itself is never resolved against `PATH` so it
has to be an absolute path or a path relative to the current directory) and
waits for it to finish.

### `RunResult`

The value `output` returns, carrying everything the child produced:
`stdout` and `stderr` as the bytes the child wrote to each stream,
`exitCode` as its exit status, and `truncated` as whether either stream was
cut off (below).

## Building on it: reporting why a command failed

A script that only prints "wc failed" is not much better than `run`'s bare
exit code. `wc` itself already says what went wrong on stderr, so read it
back and show it:

```bit
import { output } from "std/process"
import { trimSpace } from "std/strings"

fn countLines(path: string): int {
  let r = output("/usr/bin/wc", ["-l", path], 5000)
  if (r.exitCode != 0) {
    print("wc failed on ${path} (exit ${r.exitCode}): ${trimSpace(r.stderr)}\n")
    return -1
  }
  if (r.truncated) {
    print("warning: wc's own output was truncated\n")
  }
  print("wc says: ${trimSpace(r.stdout)}\n")
  return 0
}

fn main() {
  countLines("/etc/hosts")
  countLines("/no/such/file")
}
```

```
wc says: 9 /etc/hosts
wc failed on /no/such/file (exit 1): wc: /no/such/file: open: No such file or directory
```

(The line count depends on the machine this runs on; the failure message
does not.)

`countLines` passes `5000` as `timeoutMs`: a build script that shells out
should never be able to hang the build forever on a child that never exits.
`timeoutMs` defaults to `0`, which does not mean "unbounded" - there is no
unbounded form of this call - it means "no deadline of my own", so the
runtime's own ceiling of 100 minutes applies instead. Pass a real number
whenever you have one.

## Sharp edges

```bit
import { output } from "std/process"

fn main() {
  let timedOut = output("/bin/sleep", ["2"], 100)
  print("timeout case: exit=${timedOut.exitCode}\n")

  let missing = output("/no/such/program", []string(0))
  print("missing case: exit=${missing.exitCode}\n")
}
```

```
timeout case: exit=-2
missing case: exit=127
```

**Timeout kills the whole process group.** If the child (and anything it
spawned) is still running when `timeoutMs` elapses, `output` kills the
group and reports `exitCode` as `-2`. `stdout`/`stderr` still hold whatever
the child had written before it was killed.

**A program that cannot be run exits `127`, not a negative number.** This is
the same convention a shell uses for "command not found": the child process
starts, `exec` fails inside it, and it exits `127`, which `output` reports
like any other normal exit. A negative `exitCode` (other than `-2`, timeout)
means the *runtime* itself could not fork or wait for the child at all,
which is rare and not something a missing path triggers.

**Each stream is capped at 4 MiB.** A child that writes more than that to
stdout or stderr on its own has the excess silently dropped from the
`RunResult`, not stored and not delivered some other way, and `truncated`
is set to `true`. Both streams are still drained to keep the child from
blocking on a full pipe, so a chatty child cannot deadlock `output` - it
just loses the bytes past the cap. Reach for `run` instead when you expect
output that large.

## When not to use `output`

If the point is for a human to watch the child's output as it happens, for
example a long build or an interactive prompt, use `run`: `output` buffers
everything in memory and hands it back only after the child exits, so
nothing appears until the very end. This is the same split as Rust's
`Command::status()` versus `Command::output()`, or Go's `exec.Cmd.Run()`
versus `.Output()`.

`run` is unaffected by any of this - it still just streams and returns the
exit code - so existing callers of `run` need no changes.

## Where next

- [`std/os`](os.md) for `run`, the process's arguments, its environment, and
  how it exits.

Specification: `runtime/ABI.md` §19.
