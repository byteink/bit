//! Build-only test anchor for the Mach-O linker driver (`link/macho.zig`).
//!
//! Needed for two independent reasons, both of which had silently kept that
//! file's tests from ever running under `zig build test` (#1445):
//!
//!   - `link.zig` is the ELF driver and never imports `link/macho.zig`, and
//!     `unit_tests` is rooted at `main.zig`, which does not collect tests from
//!     files it merely imports. So no existing test root reached it — not even
//!     its end-to-end "boots on macOS" test.
//!   - Rooting a module at `seed/link/` directly makes `../obj/macho.zig`
//!     escape the module root, which Zig rejects. The undefined-symbol test
//!     needs that import to build a real object and drive it through `link()`.
//!
//! Anchoring at `seed/` fixes both. Mirrors `obj_pe_test.zig` and
//! `codegen_x64_test.zig`, which exist for the same relative-import reason.
test {
    _ = @import("link/macho.zig");
}
