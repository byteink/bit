//! Build-only test anchor for the PE/COFF object writer (task #344).
//!
//! `pe.zig` lives under `compiler/obj/` and reaches `x64.zig` via
//! `../codegen/x64.zig`, which in turn reaches `../ir.zig`/`../check.zig`/
//! `../regalloc.zig`. Those relative imports are only valid within a module
//! rooted at `compiler/` (their real position once wired into `link.zig`,
//! task #345) — a module rooted at `compiler/obj/` itself would have them
//! escape its root, which Zig rejects. This file just anchors that wider
//! root for `zig build test` ahead of that wiring; it has no runtime
//! purpose. Mirrors `codegen_x64_test.zig`'s anchor for the same reason.
test {
    _ = @import("obj/pe.zig");
}
