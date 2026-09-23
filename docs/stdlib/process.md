# std/process

Running a child process and capturing what it printed. `std/os`'s `run`
streams a child's stdout/stderr straight to this process's own — this module
captures them into memory instead.

Kept separate from `std/os` on purpose: `compiler/` and `tools/build` import
`std/os`, and are built by the pinned stage0 release, which predates the
runtime capture symbols this module needs.

### `RunResult`

The result of `output` below: `stdout`/`stderr` are the captured streams,
`exitCode` is the child's exit code (the same encoding `std/os`'s `run`
returns, plus `-2` for "timed out"), and `truncated` is set if either stream
was cut off at the 4 MiB capture cap.

### `output(path: string, args: []string, timeoutMs: int): RunResult`

Run `path` as a child process with `args` as its argument vector, exactly as
`std/os`'s `run` does, but capture its stdout and stderr into memory instead
of leaving them attached to this process's own file descriptors. Blocks up
to `timeoutMs` milliseconds, then kills the child's process group and
reports `-2`; there is no unbounded form of this call.

Each stream is capped at 4 MiB; content past the cap is still read (so the
child is never left blocked writing to a full pipe) but discarded, and
`truncated` reports whether either stream hit its cap.

```bit
import { output } from "std/process"

fn main() {
  let r = output("/bin/echo", ["hello", "from", "output"], 5000)
  print("${r.stdout}") // "hello from output\n"
  print("exit=${r.exitCode} truncated=${r.truncated}\n")
}
```
