//! Build-only test anchor for the PE/COFF object writer (task #344,
//! generalized under #1103).
//!
//! `pe.zig` has no imports outside `std` (the generalized writer is
//! decoupled from `codegen/x64.zig`, unlike its original scope), so nothing
//! here strictly needs the wider root — but `main.zig`'s `unit_tests` still
//! does not import `obj/pe.zig`, so this anchor keeps its tests collected by
//! `zig build test`. Mirrors `codegen_x64_test.zig`'s anchor for the same
//! "nothing else roots this file" reason.
test {
    _ = @import("obj/pe.zig");
}
