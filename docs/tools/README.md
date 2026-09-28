# Tools

The `bit` command is the whole toolchain: one binary compiles, runs, tests,
formats, lints and manages dependencies. No separate build system, no
separate package manager, no separate formatter to install.

| Tool | What it's for |
| --- | --- |
| [Build and run](build-and-run.md) | `bit run` for developing, `bit build` for shipping a binary |
| [Test](test.md) | `bit test`, table-driven checks, tests that should panic |
| [Format](fmt.md) | `bit fmt` rewrites every file to the one canonical layout |
| [Lint](lint.md) | `bit lint` finds dead code, oversized functions, and a handful of footguns |
| [Packages](packages.md) | `bit init`/`add`/`up`/`remove`, `bit.json` and `bit.lock` |

New to Bit? [Get started](../get-started.md) installs it and runs your first
program before you need any of these.
