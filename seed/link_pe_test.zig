//! Build-only test anchor for the PE/COFF object reader and the Windows
//! executable linker (task #1103, closing out #345's remaining scope).
//!
//! Needed for the same reason `link_macho_test.zig`/`obj_pe_test.zig` are:
//! `unit_tests` is rooted at `main.zig`, which does not (yet) import either
//! of these files, so no existing root would collect their tests; and
//! rooting a module directly at `seed/link/` makes `pe_reader.zig`'s own
//! `../obj/pe.zig` import (needed for its round-trip tests) escape the
//! module root, which Zig rejects. Anchoring at `seed/` fixes both.
test {
    _ = @import("link/pe_reader.zig");
    _ = @import("link/pe.zig");
}
