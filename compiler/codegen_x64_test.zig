//! Build-only test anchor for the x86-64 backend (task #340).
//!
//! `x64.zig` lives under `compiler/codegen/` and reaches sibling compiler
//! passes via `../ir.zig`, `../check.zig`, `../regalloc.zig`. Those relative
//! imports are only valid within a module rooted at `compiler/` (their real
//! position once wired into `main.zig`, task #347) — a module rooted at
//! `compiler/codegen/` itself would have them escape its root, which Zig
//! rejects. This file just anchors that wider root for `zig build test`
//! ahead of that wiring; it has no runtime purpose.
test {
    _ = @import("codegen/x64.zig");
}
