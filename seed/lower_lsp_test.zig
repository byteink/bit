//! Build-only test anchor for the lowering pass (`lower.zig`) and the language
//! server (`lsp.zig`) — the two `seed/` files whose tests ran under no test root
//! at all (#1453). Between them that was 23 tests: 14 covering the lowering
//! pass, one of the largest modules in the seed, and the entire LSP.
//!
//! Both files sit at `seed/` and root cleanly on their own, so unlike
//! `codegen_x64_test.zig` / `link_macho_test.zig` this anchor is not here to fix
//! a relative-import escape. It exists to make one compilation cover both, and
//! to give `build.zig` a single entry to hang the namespace filter on.
//!
//! **The filter is load-bearing, and so is the guard that watches it.** Rooting
//! a module at `lower.zig` collects 100 tests and at `lsp.zig` 104 — but only 14
//! and 9 of those are the files' own. The rest are `lexer`/`parser`/`resolve`/
//! `check`/`fmt`/`ir` tests that already execute under their own roots, so an
//! unfiltered entry here would add ~160 duplicate executions to an already-slow
//! suite. `build.zig` therefore restricts this artifact to the `lower.test.` and
//! `lsp.test.` namespaces.
//!
//! That filter has a failure mode of its own: rename either file and the filter
//! silently matches nothing, leaving an entry that runs zero tests — precisely
//! the vacuous guard this task existed to remove. `tests/testroots.zig` closes
//! that loop by *measuring* which namespaces the wired roots actually collect
//! and failing the build when a test-bearing file is reachable from none of
//! them. A stale filter here shows up there as an orphan, not as silence.
test {
    _ = @import("lower.zig");
    _ = @import("lsp.zig");
}
