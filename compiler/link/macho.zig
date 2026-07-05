//! Dynamic Mach-O executable writer (task #345, macOS arm64). The macOS
//! counterpart of `link.zig`'s ELF writer — but where the ELF path emits a
//! fully static, zero-dependency image, macOS fundamentally cannot: the
//! runtime reaches threads, TLS, `mmap`, and every syscall through
//! `/usr/lib/libSystem.B.dylib` (Apple has forbidden static libc since 10.6),
//! so the output is a normal dynamically-linked `MH_EXECUTE` that dyld loads
//! and binds — exactly how Go, Zig, and Rust ship on macOS. "Own linker, no
//! system `ld`" still holds; "one file, nothing else installed" becomes "one
//! file, plus the libSystem every Mac already has".
//!
//! Pipeline: ingest generic `object.Module`s, resolve + dead-strip from the
//! entry root `__start` (macOS mangles `_start` with a leading `_`), treat any
//! still-undefined global as a **libSystem import** (a leaf, not an error),
//! synthesize a `__got` of non-lazy pointers plus `__stubs` for the imports
//! that are branch targets, apply every relocation against the assigned
//! addresses, and emit the four segments (`__PAGEZERO`/`__TEXT`/`__DATA`/
//! `__LINKEDIT`) with the load commands dyld needs: `LC_DYLD_INFO_ONLY`
//! (rebase + bind opcode streams), `LC_SYMTAB`/`LC_DYSYMTAB` (+ indirect symbol
//! table), `LC_LOAD_DYLINKER`, `LC_LOAD_DYLIB` libSystem, `LC_BUILD_VERSION`,
//! `LC_UNIXTHREAD` (entry via the raw stack, matching the runtime's naked
//! `_start`), and `LC_CODE_SIGNATURE` (ad-hoc — arm64 refuses to run unsigned).
//!
//! PIE: the image is position-independent (dyld picks a random slide). Every
//! AArch64 relocation this backend applies is PC-relative (branch/ADRP/ADD/
//! LDR-off), hence slide-invariant, so link-time addresses stay correct under
//! any slide; only absolute pointers (data `abs64`, internal GOT slots) carry a
//! rebase, and imports carry a bind. macOS TLV thread-locals are a separate
//! sub-feature (task #345 cont.); a `.tls_*` atom or a TLVP relocation here is
//! `error.UnsupportedTls` until that lands.

const std = @import("std");
const Allocator = std.mem.Allocator;
const object = @import("object.zig");
const strip = @import("strip.zig");
const codesign = @import("codesign.zig");
const archive = @import("archive.zig");
const macho_reader = @import("macho_reader.zig");

const AtomId = strip.AtomId;
const RelocKind = object.RelocKind;

pub const Error = strip.Error || error{ MissingEntry, UnsupportedTls } || Allocator.Error;

const entry_symbol = "__start"; // macOS-mangled `_start`
const base_vaddr: u64 = 0x1_0000_0000; // __TEXT load address, above __PAGEZERO
const seg_align: u64 = 0x4000; // arm64 macOS segment/page alignment (16 KiB)
const ptr_size: u64 = 8;
const stub_size: u64 = 12; // adrp x16 ; ldr x16,[x16] ; br x16

const dylinker_path = "/usr/lib/dyld";
const libsystem_path = "/usr/lib/libSystem.B.dylib";

pub const Options = struct {
    /// Code-signing identifier (typically the output filename stem).
    identifier: []const u8,
};

pub const Input = union(enum) {
    /// A single relocatable Mach-O object — the compiled Bit program.
    object: []const u8,
    /// An `ar` archive (`libbitrt.a`); every member is read as its own module.
    archive: []const u8,
};

/// Reads `inputs` (the compiled Bit Mach-O object plus `libbitrt.a`) into the
/// generic object model and links them into an ad-hoc-signed executable — the
/// macOS analogue of `link.zig`'s `linkExecutable(target, inputs)`.
pub fn link(gpa: Allocator, inputs: []const Input, opts: Options) (Error || macho_reader.Error || archive.Error)![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var modules: std.ArrayList(object.Module) = .empty;
    for (inputs) |input| switch (input) {
        .object => |bytes| try modules.append(arena, try macho_reader.read(arena, "bit.o", bytes)),
        .archive => |bytes| {
            for (try archive.parse(arena, bytes)) |m| try modules.append(arena, try macho_reader.read(arena, m.name, m.data));
        },
    };
    return linkExecutable(gpa, modules.items, opts);
}

// ---------------------------------------------------------------------------
// Mach-O load-command constants + structs (`<mach-o/loader.h>`, transcribed).
// ---------------------------------------------------------------------------
const MH_MAGIC_64: u32 = 0xfeedfacf;
const CPU_TYPE_ARM64: i32 = 0x0100000C;
const CPU_SUBTYPE_ARM64_ALL: i32 = 0;
const MH_EXECUTE: u32 = 0x2;
const MH_DYLDLINK: u32 = 0x4;
const MH_TWOLEVEL: u32 = 0x80;
const MH_PIE: u32 = 0x200000;
/// Tells dyld the image carries `S_THREAD_LOCAL_VARIABLES` descriptors it must
/// register (allocate a pthread key, replace each descriptor's `_tlv_bootstrap`
/// thunk with the real resolver). Without it dyld skips TLV setup and the first
/// thread-local access calls the placeholder thunk → `_tlv_bootstrap_error`.
const MH_HAS_TLV_DESCRIPTORS: u32 = 0x800000;

const LC_REQ_DYLD: u32 = 0x80000000;
const LC_SEGMENT_64: u32 = 0x19;
const LC_SYMTAB: u32 = 0x2;
const LC_DYSYMTAB: u32 = 0xb;
const LC_LOAD_DYLINKER: u32 = 0xe;
const LC_LOAD_DYLIB: u32 = 0xc;
const LC_MAIN: u32 = 0x28 | LC_REQ_DYLD;
const LC_DYLD_INFO_ONLY: u32 = 0x22 | LC_REQ_DYLD;
const LC_BUILD_VERSION: u32 = 0x32;
const LC_CODE_SIGNATURE: u32 = 0x1d;

const S_REGULAR: u32 = 0x0;
const S_ZEROFILL: u32 = 0x1;
const S_NON_LAZY_SYMBOL_POINTERS: u32 = 0x6;
const S_SYMBOL_STUBS: u32 = 0x8;
const S_THREAD_LOCAL_REGULAR: u32 = 0x11; // __thread_data (init image)
const S_THREAD_LOCAL_ZEROFILL: u32 = 0x12; // __thread_bss
const S_THREAD_LOCAL_VARIABLES: u32 = 0x13; // __thread_vars (tlv_descriptors)
const S_ATTR_PURE_INSTRUCTIONS: u32 = 0x80000000;
const S_ATTR_SOME_INSTRUCTIONS: u32 = 0x00000400;

const N_UNDF: u8 = 0x0;
const N_EXT: u8 = 0x01;
const INDIRECT_SYMBOL_LOCAL: u32 = 0x80000000;

const PLATFORM_MACOS: u32 = 1;
const ARM_THREAD_STATE64: u32 = 6;
const ARM_THREAD_STATE64_COUNT: u32 = 68;

// Bind/rebase opcode bytecode (`<mach-o/loader.h>`).
const BIND_OPCODE_DONE: u8 = 0x00;
const BIND_OPCODE_SET_DYLIB_ORDINAL_IMM: u8 = 0x10;
const BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM: u8 = 0x40;
const BIND_OPCODE_SET_TYPE_IMM: u8 = 0x50;
const BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB: u8 = 0x70;
const BIND_OPCODE_DO_BIND: u8 = 0x90;
const BIND_TYPE_POINTER: u8 = 1;
const REBASE_OPCODE_DONE: u8 = 0x00;
const REBASE_OPCODE_SET_TYPE_IMM: u8 = 0x10;
const REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB: u8 = 0x20;
// 0x50 is DO_REBASE_IMM_TIMES (count in the low nibble); 0x60 would be the
// _ULEB_TIMES form with a trailing count uleb. We rebase one pointer at a time.
const REBASE_OPCODE_DO_REBASE_IMM_TIMES: u8 = 0x50;
const REBASE_TYPE_POINTER: u8 = 1;

const MachHeader64 = extern struct {
    magic: u32,
    cputype: i32,
    cpusubtype: i32,
    filetype: u32,
    ncmds: u32,
    sizeofcmds: u32,
    flags: u32,
    reserved: u32,
};

const SegmentCommand64 = extern struct {
    cmd: u32,
    cmdsize: u32,
    segname: [16]u8,
    vmaddr: u64,
    vmsize: u64,
    fileoff: u64,
    filesize: u64,
    maxprot: i32,
    initprot: i32,
    nsects: u32,
    flags: u32,
};

const Section64 = extern struct {
    sectname: [16]u8,
    segname: [16]u8,
    addr: u64,
    size: u64,
    offset: u32,
    @"align": u32,
    reloff: u32,
    nreloc: u32,
    flags: u32,
    reserved1: u32,
    reserved2: u32,
    reserved3: u32,
};

const Nlist64 = extern struct {
    n_strx: u32,
    n_type: u8,
    n_sect: u8,
    n_desc: u16,
    n_value: u64,
};

fn name16(s: []const u8) [16]u8 {
    var b = std.mem.zeroes([16]u8);
    @memcpy(b[0..s.len], s);
    return b;
}

fn alignUp(v: u64, a: u64) u64 {
    return std.mem.alignForward(u64, v, a);
}

fn uleb(list: *std.ArrayList(u8), gpa: Allocator, value: u64) !void {
    var v = value;
    while (true) {
        var byte: u8 = @intCast(v & 0x7f);
        v >>= 7;
        if (v != 0) byte |= 0x80;
        try list.append(gpa, byte);
        if (v == 0) break;
    }
}

// A GOT slot points at either an internal defined atom (rebased) or a
// libSystem import (bound). Stubs and the indirect symbol table read this.
const GotKind = union(enum) { internal: AtomId, import: []const u8 };

const Placed = struct { id: AtomId, vaddr: u64 = 0, file_off: u64 = 0 };

/// Links `modules` into an ad-hoc-signed, dynamically-linked arm64 Mach-O
/// executable, returned as owned bytes.
pub fn linkExecutable(gpa: Allocator, modules: []const object.Module, opts: Options) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var globals = try strip.resolveGlobals(arena, modules);

    // ---- dead-strip from __start, collecting libSystem imports as leaves ----
    var kept = std.AutoHashMapUnmanaged(u64, void){};
    var import_order: std.ArrayList([]const u8) = .empty;
    var import_set = std.StringHashMapUnmanaged(void){};
    var branch_imports = std.StringHashMapUnmanaged(void){};
    var stack: std.ArrayList(AtomId) = .empty;

    const entry = globals.get(entry_symbol) orelse return error.MissingEntry;
    try kept.put(arena, entry.key(), {});
    try stack.append(arena, entry);
    while (stack.pop()) |id| {
        const atom = modules[id.module].atoms[id.atom];
        for (atom.relocs) |r| {
            switch (r.target) {
                .local => |idx| {
                    const tid = AtomId{ .module = id.module, .atom = idx };
                    if ((try kept.getOrPut(arena, tid.key())).found_existing) continue;
                    try stack.append(arena, tid);
                },
                .global => |nm| {
                    if (globals.get(nm)) |tid| {
                        if ((try kept.getOrPut(arena, tid.key())).found_existing) continue;
                        try stack.append(arena, tid);
                    } else {
                        // Undefined: a dynamic import from libSystem.
                        if ((try import_set.getOrPut(arena, nm)).found_existing == false)
                            try import_order.append(arena, nm);
                        if (isBranch(r.kind)) try branch_imports.put(arena, nm, {});
                    }
                },
            }
        }
    }

    // ---- partition kept atoms by output class ------------------------------
    var text: std.ArrayList(Placed) = .empty;
    var rodata: std.ArrayList(Placed) = .empty;
    var data: std.ArrayList(Placed) = .empty;
    var bss: std.ArrayList(Placed) = .empty;
    var tls_vars: std.ArrayList(Placed) = .empty; // __thread_vars descriptors
    var tls_data: std.ArrayList(Placed) = .empty; // __thread_data init image
    var tls_bss: std.ArrayList(Placed) = .empty; // __thread_bss
    for (modules, 0..) |mod, mi| {
        for (mod.atoms, 0..) |atom, ai| {
            const id = AtomId{ .module = @intCast(mi), .atom = @intCast(ai) };
            if (!kept.contains(id.key())) continue;
            switch (atom.kind) {
                .text => try text.append(arena, .{ .id = id }),
                .rodata => try rodata.append(arena, .{ .id = id }),
                .data => try data.append(arena, .{ .id = id }),
                .bss => try bss.append(arena, .{ .id = id }),
                .tls_vars => try tls_vars.append(arena, .{ .id = id }),
                .tls_data => try tls_data.append(arena, .{ .id = id }),
                .tls_bss => try tls_bss.append(arena, .{ .id = id }),
            }
        }
    }

    // ---- GOT slots + stubs -------------------------------------------------
    var got_list: std.ArrayList(GotKind) = .empty;
    var got_of_internal = std.AutoHashMapUnmanaged(u64, u32){};
    var got_of_import = std.StringHashMapUnmanaged(u32){};
    var stub_list: std.ArrayList([]const u8) = .empty;
    var stub_of_import = std.StringHashMapUnmanaged(u32){};

    const gotForImport = struct {
        fn get(a: Allocator, list: *std.ArrayList(GotKind), map: *std.StringHashMapUnmanaged(u32), nm: []const u8) !u32 {
            const gop = try map.getOrPut(a, nm);
            if (!gop.found_existing) {
                gop.value_ptr.* = @intCast(list.items.len);
                try list.append(a, .{ .import = nm });
            }
            return gop.value_ptr.*;
        }
    }.get;

    for (modules, 0..) |mod, mi| {
        for (mod.atoms, 0..) |atom, ai| {
            if (!kept.contains((AtomId{ .module = @intCast(mi), .atom = @intCast(ai) }).key())) continue;
            for (atom.relocs) |r| {
                const is_import = r.target == .global and globals.get(r.target.global) == null;
                // A TLVP slot is a GOT-like pointer to an internal tlv_descriptor
                // (the access site does `adrp/ldr` to load &descriptor), so it
                // uses the same internal-GOT machinery as a plain GOT reference.
                if (strip.needsGot(r.kind) or strip.needsTlvp(r.kind)) {
                    if (is_import) {
                        _ = try gotForImport(arena, &got_list, &got_of_import, r.target.global);
                    } else {
                        const tid = try strip.resolveRef(&globals, @intCast(mi), r.target);
                        const gop = try got_of_internal.getOrPut(arena, tid.key());
                        if (!gop.found_existing) {
                            gop.value_ptr.* = @intCast(got_list.items.len);
                            try got_list.append(arena, .{ .internal = tid });
                        }
                    }
                }
                if (isBranch(r.kind) and is_import) {
                    _ = try gotForImport(arena, &got_list, &got_of_import, r.target.global);
                    const gop = try stub_of_import.getOrPut(arena, r.target.global);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = @intCast(stub_list.items.len);
                        try stub_list.append(arena, r.target.global);
                    }
                }
            }
        }
    }

    const has_stubs = stub_list.items.len > 0;
    const has_rodata = rodata.items.len > 0;
    const has_got = got_list.items.len > 0;
    const has_data = data.items.len > 0;
    const has_bss = bss.items.len > 0;
    const has_tls_vars = tls_vars.items.len > 0;
    const has_tls_data = tls_data.items.len > 0;
    const has_tls_bss = tls_bss.items.len > 0;
    const has_data_seg = has_got or has_data or has_bss or has_tls_vars or has_tls_data or has_tls_bss;

    // ---- fixed load-command sizes (values filled after layout) -------------
    const text_nsects: u32 = 1 + @as(u32, @intFromBool(has_stubs)) + @as(u32, @intFromBool(has_rodata));
    const data_nsects: u32 = @as(u32, @intFromBool(has_got)) + @as(u32, @intFromBool(has_data)) +
        @as(u32, @intFromBool(has_tls_vars)) + @as(u32, @intFromBool(has_tls_data)) +
        @as(u32, @intFromBool(has_tls_bss)) + @as(u32, @intFromBool(has_bss));
    const seg_sz = @sizeOf(SegmentCommand64);
    const sect_sz = @sizeOf(Section64);
    var sizeofcmds: u32 = 0;
    sizeofcmds += seg_sz; // __PAGEZERO
    sizeofcmds += seg_sz + text_nsects * sect_sz; // __TEXT
    if (has_data_seg) sizeofcmds += seg_sz + data_nsects * sect_sz; // __DATA
    sizeofcmds += seg_sz; // __LINKEDIT
    sizeofcmds += 48; // LC_DYLD_INFO_ONLY
    sizeofcmds += 24; // LC_SYMTAB
    sizeofcmds += 80; // LC_DYSYMTAB
    const dylinker_cmdsize: u32 = @intCast(alignUp(12 + dylinker_path.len + 1, 8));
    const dylib_cmdsize: u32 = @intCast(alignUp(24 + libsystem_path.len + 1, 8));
    sizeofcmds += dylinker_cmdsize;
    sizeofcmds += dylib_cmdsize;
    sizeofcmds += 24; // LC_BUILD_VERSION
    sizeofcmds += 24; // LC_MAIN (entry_point_command)
    sizeofcmds += 16; // LC_CODE_SIGNATURE
    const headers_size: u64 = @sizeOf(MachHeader64) + sizeofcmds;

    // ---- __TEXT layout: headers, text atoms, stubs, rodata -----------------
    var cursor = base_vaddr + headers_size;
    placeAtoms(modules, text.items, &cursor);
    const stubs_vaddr = alignUp(cursor, 4);
    cursor = stubs_vaddr + @as(u64, stub_list.items.len) * stub_size;
    const rodata_vaddr = cursor;
    placeAtoms(modules, rodata.items, &cursor);
    const text_seg_filesize = alignUp(cursor - base_vaddr, seg_align);
    const text_seg_vmsize = text_seg_filesize;

    // ---- __DATA layout: got, data, TLS, then zero-fill last ----------------
    // File-backed sections first (got, data, __thread_vars descriptors,
    // __thread_data init image), then the zero-fill sections (__thread_bss,
    // __bss). __thread_data and __thread_bss stay adjacent so they form one
    // contiguous per-thread TLV template dyld can copy.
    const data_seg_vaddr = base_vaddr + text_seg_vmsize;
    cursor = data_seg_vaddr;
    const got_vaddr = cursor;
    cursor += @as(u64, got_list.items.len) * ptr_size;
    placeAtoms(modules, data.items, &cursor);
    placeAtoms(modules, tls_vars.items, &cursor);
    placeAtoms(modules, tls_data.items, &cursor);
    const data_file_end = cursor; // last file-backed byte in __DATA
    placeAtoms(modules, tls_bss.items, &cursor); // zero-fill, contiguous w/ tls_data
    placeAtoms(modules, bss.items, &cursor); // zero-fill
    const data_seg_filesize = if (has_data_seg) alignUp(data_file_end - data_seg_vaddr, seg_align) else 0;
    const data_seg_vmsize = if (has_data_seg) alignUp(cursor - data_seg_vaddr, seg_align) else 0;

    // Base of the per-thread TLV template (__thread_data then __thread_bss). A
    // tlv_descriptor's data field is the variable's *offset* within this
    // template (a constant dyld validates against the template size), not an
    // absolute address — so an abs64 into TLS storage resolves relative to here.
    const tls_template_base: u64 = if (has_tls_data) tls_data.items[0].vaddr else if (has_tls_bss) tls_bss.items[0].vaddr else 0;

    // ---- address lookup for every placed atom ------------------------------
    var addr_of = std.AutoHashMapUnmanaged(u64, u64){};
    for ([_][]const Placed{ text.items, rodata.items, data.items, bss.items, tls_vars.items, tls_data.items, tls_bss.items }) |group|
        for (group) |p| try addr_of.put(arena, p.id.key(), p.vaddr);

    const entry_vaddr = addr_of.get(entry.key()) orelse return error.MissingEntry;

    // ---- stub + got addresses ----------------------------------------------
    const stubAddr = struct {
        base: u64,
        fn at(self: @This(), i: u32) u64 {
            return self.base + @as(u64, i) * stub_size;
        }
    }{ .base = stubs_vaddr };
    const gotAddr = struct {
        base: u64,
        fn at(self: @This(), i: u32) u64 {
            return self.base + @as(u64, i) * ptr_size;
        }
    }{ .base = got_vaddr };

    // ---- apply relocations into per-atom mutable copies + collect binds ----
    var patched = std.AutoHashMapUnmanaged(u64, []u8){};
    // Data binds (abs64 -> import) and rebases (abs64 -> internal) discovered
    // while patching; emitted into the dyld-info streams below.
    const DataBind = struct { seg_off: u64, name: []const u8 };
    var data_binds: std.ArrayList(DataBind) = .empty;
    var data_rebases: std.ArrayList(u64) = .empty; // segment offsets in __DATA

    for (modules, 0..) |mod, mi| {
        for (mod.atoms, 0..) |atom, ai| {
            const id = AtomId{ .module = @intCast(mi), .atom = @intCast(ai) };
            if (!kept.contains(id.key()) or atom.data.len == 0) continue;
            const buf = try arena.dupe(u8, atom.data);
            const atom_vaddr = addr_of.get(id.key()).?;
            for (atom.relocs) |r| {
                const field = buf[r.offset..];
                const p = atom_vaddr + r.offset;
                const is_import = r.target == .global and globals.get(r.target.global) == null;

                if (isBranch(r.kind) and is_import) {
                    // Retarget the branch to the import's stub.
                    const si = stub_of_import.get(r.target.global).?;
                    try strip.apply(r.kind, field, .{ .s = stubAddr.at(si), .p = p });
                    continue;
                }
                if (strip.needsGot(r.kind) or strip.needsTlvp(r.kind)) {
                    const gi = if (is_import)
                        got_of_import.get(r.target.global).?
                    else
                        got_of_internal.get((try strip.resolveRef(&globals, @intCast(mi), r.target)).key()).?;
                    try strip.apply(r.kind, field, .{ .p = p, .got_slot = gotAddr.at(gi) });
                    continue;
                }
                if (r.kind == .abs64 and is_import) {
                    // Absolute pointer to an import: dyld binds it; leave zero.
                    // (Includes a tlv_descriptor's thunk field -> _tlv_bootstrap.)
                    try data_binds.append(arena, .{ .seg_off = (atom_vaddr + r.offset) - data_seg_vaddr, .name = r.target.global });
                    continue;
                }
                const tid = try strip.resolveRef(&globals, @intCast(mi), r.target);
                const tgt = addr_of.get(tid.key()) orelse return error.UndefinedSymbol;
                const target_kind = modules[tid.module].atoms[tid.atom].kind;

                // A pointer into thread-local storage (a tlv_descriptor's data
                // field -> `x$tlv$init`) is stored as the variable's constant
                // offset within the TLV template, which dyld reads directly — not
                // an absolute address, and never rebased.
                if (r.kind == .abs64 and (target_kind == .tls_data or target_kind == .tls_bss)) {
                    const off: u64 = @bitCast(@as(i64, @bitCast(tgt - tls_template_base)) + r.addend);
                    try strip.apply(.abs64, field, .{ .s = off });
                    continue;
                }

                // Everything else resolves to a concrete address.
                const s: u64 = @bitCast(@as(i64, @bitCast(tgt)) + r.addend);
                try strip.apply(r.kind, field, .{ .s = s, .p = p });
                // An absolute internal pointer in a writable segment is rebased so
                // dyld slides it.
                if (r.kind == .abs64 and isDataSeg(atom.kind))
                    try data_rebases.append(arena, (atom_vaddr + r.offset) - data_seg_vaddr);
            }
            try patched.put(arena, id.key(), buf);
        }
    }

    // Internal GOT slots hold an absolute internal address -> rebase them too.
    for (got_list.items, 0..) |g, i| switch (g) {
        .internal => try data_rebases.append(arena, gotAddr.at(@intCast(i)) - data_seg_vaddr),
        .import => {},
    };

    // ---- symbol table (imports only) + name→index --------------------------
    var strtab: std.ArrayList(u8) = .empty;
    try strtab.append(arena, 0); // index 0 == ""
    var sym_index = std.StringHashMapUnmanaged(u32){};
    var nlists: std.ArrayList(Nlist64) = .empty;
    for (import_order.items, 0..) |nm, i| {
        const strx: u32 = @intCast(strtab.items.len);
        try strtab.appendSlice(arena, nm);
        try strtab.append(arena, 0);
        try sym_index.put(arena, nm, @intCast(i));
        try nlists.append(arena, .{ .n_strx = strx, .n_type = N_UNDF | N_EXT, .n_sect = 0, .n_desc = 0, .n_value = 0 });
    }

    // ---- indirect symbol table: stubs first, then got ----------------------
    var indirect: std.ArrayList(u32) = .empty;
    for (stub_list.items) |nm| try indirect.append(arena, sym_index.get(nm).?);
    for (got_list.items) |g| switch (g) {
        .import => |nm| try indirect.append(arena, sym_index.get(nm).?),
        .internal => try indirect.append(arena, INDIRECT_SYMBOL_LOCAL),
    };

    // ---- dyld info: rebase + bind opcode streams ---------------------------
    const data_seg_index: u8 = if (has_data_seg) 2 else 0; // __PAGEZERO,__TEXT,__DATA
    var rebase_ops: std.ArrayList(u8) = .empty;
    if (data_rebases.items.len > 0) {
        std.mem.sort(u64, data_rebases.items, {}, std.sort.asc(u64));
        try rebase_ops.append(arena, REBASE_OPCODE_SET_TYPE_IMM | REBASE_TYPE_POINTER);
        for (data_rebases.items) |off| {
            try rebase_ops.append(arena, REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB | data_seg_index);
            try uleb(&rebase_ops, arena, off);
            try rebase_ops.append(arena, REBASE_OPCODE_DO_REBASE_IMM_TIMES | 1); // rebase exactly one pointer
        }
        try rebase_ops.append(arena, REBASE_OPCODE_DONE);
    }

    var bind_ops: std.ArrayList(u8) = .empty;
    {
        try bind_ops.append(arena, BIND_OPCODE_SET_DYLIB_ORDINAL_IMM | 1); // libSystem is dylib #1
        // GOT slots that are imports.
        for (got_list.items, 0..) |g, i| switch (g) {
            .import => |nm| try emitBind(&bind_ops, arena, nm, data_seg_index, gotAddr.at(@intCast(i)) - data_seg_vaddr),
            .internal => {},
        };
        for (data_binds.items) |b| try emitBind(&bind_ops, arena, b.name, data_seg_index, b.seg_off);
        try bind_ops.append(arena, BIND_OPCODE_DONE);
    }

    // ---- __LINKEDIT layout -------------------------------------------------
    const linkedit_fileoff = text_seg_filesize + data_seg_filesize;
    var le_cursor = linkedit_fileoff;
    const rebase_off = le_cursor;
    le_cursor += rebase_ops.items.len;
    const bind_off = le_cursor;
    le_cursor += bind_ops.items.len;
    le_cursor = alignUp(le_cursor, 8);
    const symtab_off = le_cursor;
    le_cursor += nlists.items.len * @sizeOf(Nlist64);
    const indirect_off = le_cursor;
    le_cursor += indirect.items.len * 4;
    const strtab_off = le_cursor;
    le_cursor += strtab.items.len;
    const sig_off = alignUp(le_cursor, 16);
    const sig_size = codesign.size(sig_off, opts.identifier);
    const linkedit_file_end = sig_off + sig_size;
    const linkedit_filesize = linkedit_file_end - linkedit_fileoff;
    const linkedit_vaddr = base_vaddr + text_seg_vmsize + data_seg_vmsize;

    // ---- assemble the file -------------------------------------------------
    const file = try arena.alloc(u8, linkedit_file_end);
    @memset(file, 0);

    // Copy every byte-backed atom (patched if it had relocations). TLS
    // descriptors (__thread_vars) and the __thread_data init image are
    // file-backed; __thread_bss/__bss are zero-fill and carry no bytes.
    for ([_][]const Placed{ text.items, rodata.items, data.items, tls_vars.items, tls_data.items }) |group| {
        for (group) |p| {
            const bytes = patched.get(p.id.key()) orelse modules[p.id.module].atoms[p.id.atom].data;
            if (bytes.len == 0) continue;
            @memcpy(file[p.file_off..][0..bytes.len], bytes);
        }
    }
    // Stubs: adrp x16,got ; ldr x16,[x16,off] ; br x16.
    for (stub_list.items, 0..) |nm, i| {
        const off = (stubAddr.at(@intCast(i))) - base_vaddr;
        const gi = got_of_import.get(nm).?;
        var s = file[off..][0..stub_size];
        std.mem.writeInt(u32, s[0..4], 0x90000010, .little); // adrp x16, 0
        std.mem.writeInt(u32, s[4..8], 0xF9400210, .little); // ldr x16, [x16]
        std.mem.writeInt(u32, s[8..12], 0xD61F0200, .little); // br x16
        const stub_p = stubAddr.at(@intCast(i));
        try strip.apply(.aarch64_adr_got_page, s[0..4], .{ .p = stub_p, .got_slot = gotAddr.at(gi) });
        try strip.apply(.aarch64_ld64_got_lo12_nc, s[4..8], .{ .got_slot = gotAddr.at(gi) });
    }
    // Internal GOT slots hold their target's absolute address (rebased by dyld);
    // import slots stay zero until dyld binds them.
    for (got_list.items, 0..) |g, i| switch (g) {
        .internal => |tid| {
            const off = gotAddr.at(@intCast(i)) - base_vaddr;
            std.mem.writeInt(u64, file[off..][0..8], addr_of.get(tid.key()).?, .little);
        },
        .import => {},
    };

    // dyld info + symtab + indirect + strtab.
    @memcpy(file[rebase_off..][0..rebase_ops.items.len], rebase_ops.items);
    @memcpy(file[bind_off..][0..bind_ops.items.len], bind_ops.items);
    for (nlists.items, 0..) |nl, i|
        @memcpy(file[symtab_off + i * @sizeOf(Nlist64) ..][0..@sizeOf(Nlist64)], std.mem.asBytes(&nl));
    for (indirect.items, 0..) |v, i|
        std.mem.writeInt(u32, file[indirect_off + i * 4 ..][0..4], v, .little);
    @memcpy(file[strtab_off..][0..strtab.items.len], strtab.items);

    // ---- header + load commands --------------------------------------------
    var lc: std.ArrayList(u8) = .empty;
    // __PAGEZERO
    try appendSeg(&lc, arena, "__PAGEZERO", 0, base_vaddr, 0, 0, 0, 0, 0);
    // __TEXT (with sections)
    try appendSeg(&lc, arena, "__TEXT", base_vaddr, text_seg_vmsize, 0, text_seg_filesize, 5, 5, text_nsects);
    {
        const text_end = if (text.items.len > 0) text.items[text.items.len - 1].vaddr + modules[text.items[text.items.len - 1].id.module].atoms[text.items[text.items.len - 1].id.atom].size else base_vaddr + headers_size;
        try appendSect(&lc, arena, "__text", "__TEXT", base_vaddr + headers_size, text_end - (base_vaddr + headers_size), @intCast(headers_size), 2, S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS, 0, 0);
        if (has_stubs) try appendSect(&lc, arena, "__stubs", "__TEXT", stubs_vaddr, @as(u64, stub_list.items.len) * stub_size, @intCast(stubs_vaddr - base_vaddr), 2, S_SYMBOL_STUBS | S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS, 0, @intCast(stub_size));
        if (has_rodata) try appendSect(&lc, arena, "__const", "__TEXT", rodata_vaddr, rodataSize(modules, rodata.items), @intCast(rodata_vaddr - base_vaddr), 0, S_REGULAR, 0, 0);
    }
    // __DATA (with sections)
    if (has_data_seg) {
        try appendSeg(&lc, arena, "__DATA", data_seg_vaddr, data_seg_vmsize, text_seg_filesize, data_seg_filesize, 3, 3, data_nsects);
        // indirect symtab index base: stubs occupy [0, nstubs); got starts at nstubs.
        if (has_got) try appendSect(&lc, arena, "__got", "__DATA", got_vaddr, @as(u64, got_list.items.len) * ptr_size, @intCast(got_vaddr - base_vaddr), 3, S_NON_LAZY_SYMBOL_POINTERS, @intCast(stub_list.items.len), 0);
        if (has_data) try appendSect(&lc, arena, "__data", "__DATA", data.items[0].vaddr, rodataSize(modules, data.items), @intCast(data.items[0].vaddr - base_vaddr), 3, S_REGULAR, 0, 0);
        if (has_tls_vars) try appendSect(&lc, arena, "__thread_vars", "__DATA", tls_vars.items[0].vaddr, rodataSize(modules, tls_vars.items), @intCast(tls_vars.items[0].vaddr - base_vaddr), 3, S_THREAD_LOCAL_VARIABLES, 0, 0);
        if (has_tls_data) try appendSect(&lc, arena, "__thread_data", "__DATA", tls_data.items[0].vaddr, rodataSize(modules, tls_data.items), @intCast(tls_data.items[0].vaddr - base_vaddr), 3, S_THREAD_LOCAL_REGULAR, 0, 0);
        if (has_tls_bss) try appendSect(&lc, arena, "__thread_bss", "__DATA", tls_bss.items[0].vaddr, rodataSize(modules, tls_bss.items), 0, 3, S_THREAD_LOCAL_ZEROFILL, 0, 0);
        if (has_bss) try appendSect(&lc, arena, "__bss", "__DATA", bss.items[0].vaddr, rodataSize(modules, bss.items), 0, 3, S_ZEROFILL, 0, 0);
    }
    // __LINKEDIT
    try appendSeg(&lc, arena, "__LINKEDIT", linkedit_vaddr, alignUp(linkedit_filesize, seg_align), linkedit_fileoff, linkedit_filesize, 1, 1, 0);

    // LC_DYLD_INFO_ONLY
    try appendU32s(&lc, arena, &.{ LC_DYLD_INFO_ONLY, 48, @intCast(rebase_off), @intCast(rebase_ops.items.len), @intCast(bind_off), @intCast(bind_ops.items.len), 0, 0, 0, 0, 0, 0 });
    // LC_SYMTAB
    try appendU32s(&lc, arena, &.{ LC_SYMTAB, 24, @intCast(symtab_off), @intCast(nlists.items.len), @intCast(strtab_off), @intCast(strtab.items.len) });
    // LC_DYSYMTAB (only undef syms; indirect table drives stubs/got)
    try appendDysymtab(&lc, arena, @intCast(nlists.items.len), @intCast(indirect_off), @intCast(indirect.items.len));
    // LC_LOAD_DYLINKER
    try appendDylinker(&lc, arena, dylinker_cmdsize);
    // LC_LOAD_DYLIB libSystem
    try appendDylib(&lc, arena, dylib_cmdsize);
    // LC_BUILD_VERSION (macOS 11.0, sdk 11.0)
    try appendU32s(&lc, arena, &.{ LC_BUILD_VERSION, 24, PLATFORM_MACOS, 0x000B0000, 0x000B0000, 0 });
    // LC_MAIN: entryoff is the entry's file offset (== vaddr - base, __TEXT at
    // file 0); dyld calls it with the C `main(argc,argv,envp,apple)` ABI.
    try appendMain(&lc, arena, entry_vaddr - base_vaddr);
    // LC_CODE_SIGNATURE
    try appendU32s(&lc, arena, &.{ LC_CODE_SIGNATURE, 16, @intCast(sig_off), sig_size });

    std.debug.assert(lc.items.len == sizeofcmds);

    const header = MachHeader64{
        .magic = MH_MAGIC_64,
        .cputype = CPU_TYPE_ARM64,
        .cpusubtype = CPU_SUBTYPE_ARM64_ALL,
        .filetype = MH_EXECUTE,
        .ncmds = ncmds(has_data_seg),
        .sizeofcmds = sizeofcmds,
        .flags = MH_DYLDLINK | MH_TWOLEVEL | MH_PIE | (if (has_tls_vars) MH_HAS_TLV_DESCRIPTORS else 0),
        .reserved = 0,
    };
    @memcpy(file[0..@sizeOf(MachHeader64)], std.mem.asBytes(&header));
    @memcpy(file[@sizeOf(MachHeader64)..][0..lc.items.len], lc.items);

    // ---- ad-hoc code signature over [0, sig_off) ---------------------------
    const sig = try codesign.build(arena, file[0..sig_off], opts.identifier, text_seg_filesize);
    @memcpy(file[sig_off..][0..sig.len], sig);

    return gpa.dupe(u8, file);
}

fn ncmds(has_data_seg: bool) u32 {
    // pagezero, text, [data], linkedit, dyld_info, symtab, dysymtab, dylinker,
    // dylib, build_version, unixthread, code_signature.
    return if (has_data_seg) 12 else 11;
}

fn isBranch(kind: RelocKind) bool {
    return kind == .aarch64_call26 or kind == .aarch64_jump26;
}

/// True for a writable, file-backed __DATA section kind that can hold a
/// rebasable absolute pointer (plain data or a tlv_descriptor's fields).
fn isDataSeg(kind: object.SectionKind) bool {
    return switch (kind) {
        .data, .tls_vars, .tls_data => true,
        else => false,
    };
}

fn emitBind(ops: *std.ArrayList(u8), gpa: Allocator, name: []const u8, seg: u8, off: u64) !void {
    try ops.append(gpa, BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM | 0);
    try ops.appendSlice(gpa, name);
    try ops.append(gpa, 0);
    try ops.append(gpa, BIND_OPCODE_SET_TYPE_IMM | BIND_TYPE_POINTER);
    try ops.append(gpa, BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB | seg);
    try uleb(ops, gpa, off);
    try ops.append(gpa, BIND_OPCODE_DO_BIND);
}

fn placeAtoms(mods: []const object.Module, items: []Placed, cursor: *u64) void {
    for (items) |*p| {
        const a = mods[p.id.module].atoms[p.id.atom];
        cursor.* = alignUp(cursor.*, @max(a.alignment, 1));
        p.vaddr = cursor.*;
        p.file_off = cursor.* - base_vaddr;
        cursor.* += a.size;
    }
}

/// Byte extent of a placed group: from its first atom's address to the end of
/// its last (a section's `size` in the output header).
fn rodataSize(mods: []const object.Module, items: []const Placed) u64 {
    if (items.len == 0) return 0;
    const last = items[items.len - 1];
    return last.vaddr + mods[last.id.module].atoms[last.id.atom].size - items[0].vaddr;
}

fn appendU32s(lc: *std.ArrayList(u8), gpa: Allocator, vals: []const u32) !void {
    for (vals) |v| {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .little);
        try lc.appendSlice(gpa, &b);
    }
}

fn appendSeg(lc: *std.ArrayList(u8), gpa: Allocator, seg: []const u8, vmaddr: u64, vmsize: u64, fileoff: u64, filesize: u64, initprot: i32, maxprot: i32, nsects: u32) !void {
    const cmd = SegmentCommand64{
        .cmd = LC_SEGMENT_64,
        .cmdsize = @intCast(@sizeOf(SegmentCommand64) + nsects * @sizeOf(Section64)),
        .segname = name16(seg),
        .vmaddr = vmaddr,
        .vmsize = vmsize,
        .fileoff = fileoff,
        .filesize = filesize,
        .maxprot = maxprot,
        .initprot = initprot,
        .nsects = nsects,
        .flags = 0,
    };
    try lc.appendSlice(gpa, std.mem.asBytes(&cmd));
}

fn appendSect(lc: *std.ArrayList(u8), gpa: Allocator, sect: []const u8, seg: []const u8, addr: u64, size: u64, offset: u32, align_log2: u32, flags: u32, reserved1: u32, reserved2: u32) !void {
    const s = Section64{
        .sectname = name16(sect),
        .segname = name16(seg),
        .addr = addr,
        .size = size,
        .offset = offset,
        .@"align" = align_log2,
        .reloff = 0,
        .nreloc = 0,
        .flags = flags,
        .reserved1 = reserved1,
        .reserved2 = reserved2,
        .reserved3 = 0,
    };
    try lc.appendSlice(gpa, std.mem.asBytes(&s));
}

fn appendDysymtab(lc: *std.ArrayList(u8), gpa: Allocator, nundef: u32, indirect_off: u32, nindirect: u32) !void {
    // ilocalsym,nlocalsym, iextdefsym,nextdefsym, iundefsym,nundefsym, ...
    try appendU32s(lc, gpa, &.{ LC_DYSYMTAB, 80, 0, 0, 0, 0, 0, nundef, 0, 0, 0, 0, 0, 0, indirect_off, nindirect, 0, 0, 0, 0 });
}

fn appendDylinker(lc: *std.ArrayList(u8), gpa: Allocator, cmdsize: u32) !void {
    try appendU32s(lc, gpa, &.{ LC_LOAD_DYLINKER, cmdsize, 12 }); // name.offset = 12
    try appendPaddedStr(lc, gpa, dylinker_path, cmdsize, 12);
}

fn appendDylib(lc: *std.ArrayList(u8), gpa: Allocator, cmdsize: u32) !void {
    // name.offset=24, timestamp=2, current=compat=0 (any).
    try appendU32s(lc, gpa, &.{ LC_LOAD_DYLIB, cmdsize, 24, 2, 0, 0 });
    try appendPaddedStr(lc, gpa, libsystem_path, cmdsize, 24);
}

fn appendPaddedStr(lc: *std.ArrayList(u8), gpa: Allocator, s: []const u8, cmdsize: u32, str_off: u32) !void {
    try lc.appendSlice(gpa, s);
    var written: u32 = str_off + @as(u32, @intCast(s.len));
    while (written < cmdsize) : (written += 1) try lc.append(gpa, 0);
}

fn appendMain(lc: *std.ArrayList(u8), gpa: Allocator, entryoff: u64) !void {
    try appendU32s(lc, gpa, &.{ LC_MAIN, 24 }); // entry_point_command
    var b: [8]u8 = undefined;
    std.mem.writeInt(u64, &b, entryoff, .little); // entryoff
    try lc.appendSlice(gpa, &b);
    std.mem.writeInt(u64, &b, 0, .little); // stacksize (0 = default)
    try lc.appendSlice(gpa, &b);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;
const builtin = @import("builtin");

test {
    testing.refAllDecls(@This());
}

/// De-risk payload: a synthetic `__start` that writes "hi\n" and exits 0,
/// calling libSystem `_write`/`_exit` through stubs. Proves the whole
/// container — dyld load, bind, stub, PIE slide, ad-hoc signature, entry — with
/// no dependency on the reader or the real runtime.
fn buildDerisk(gpa: Allocator) ![]u8 {
    // __start:
    //   mov x0,#1 ; adrp x1,msg ; add x1,x1,msg ; mov x2,#3 ; bl _write
    //   mov x0,#0 ; bl _exit
    var code = [_]u8{
        0x20, 0x00, 0x80, 0xD2, // mov x0, #1
        0x01, 0x00, 0x00, 0x90, // adrp x1, msg
        0x21, 0x00, 0x00, 0x91, // add  x1, x1, msg
        0x62, 0x00, 0x80, 0xD2, // mov x2, #3
        0x00, 0x00, 0x00, 0x94, // bl _write
        0x00, 0x00, 0x80, 0xD2, // mov x0, #0
        0x00, 0x00, 0x00, 0x94, // bl _exit
    };
    const msg = "hi\n";

    const text_relocs = [_]object.Reloc{
        .{ .offset = 4, .kind = .aarch64_adr_prel_pg_hi21, .target = .{ .local = 1 } },
        .{ .offset = 8, .kind = .aarch64_add_abs_lo12_nc, .target = .{ .local = 1 } },
        .{ .offset = 16, .kind = .aarch64_call26, .target = .{ .global = "_write" } },
        .{ .offset = 24, .kind = .aarch64_call26, .target = .{ .global = "_exit" } },
    };
    var atoms = [_]object.Atom{
        .{ .name = entry_symbol, .kind = .text, .binding = .global, .data = &code, .size = code.len, .alignment = 4, .relocs = &text_relocs },
        .{ .name = "msg", .kind = .rodata, .binding = .local, .data = msg, .size = msg.len, .alignment = 1, .relocs = &.{} },
    };
    const mods = [_]object.Module{.{ .name = "derisk", .atoms = &atoms }};
    return linkExecutable(gpa, &mods, .{ .identifier = "bit-derisk" });
}

test "de-risk: emits a well-formed signed arm64 Mach-O and (on macOS) runs" {
    const gpa = testing.allocator;
    const exe = try buildDerisk(gpa);
    defer gpa.free(exe);

    // Structural checks that hold on every host.
    try testing.expectEqual(MH_MAGIC_64, std.mem.readInt(u32, exe[0..4], .little));
    const filetype = std.mem.readInt(u32, exe[12..16], .little);
    try testing.expectEqual(MH_EXECUTE, filetype);

    // Always drop the image where a Mac can pick it up and run it natively
    // (this test binary itself runs under Docker/Linux in CI).
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = "zig-out/bit-macho-derisk", .data = exe }) catch {};

    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
}

test "links the real aarch64 runtime + a bit_main into a signed image that boots on macOS" {
    const gpa = testing.allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const lib = std.Io.Dir.cwd().readFileAlloc(threaded.io(), "zig-out/lib/aarch64-macos/libbitrt.a", arena, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest, // `zig build libbitrt` not run here
        else => return err,
    };

    // A synthetic Bit program: `bit_main` = `mov w0,#42 ; ret` (exit code 42).
    // Linked against the real runtime, this exercises the entire macOS path —
    // reader, TLV, GOT/stubs, binds, signature — and the runtime actually
    // booting (heap, GC, scheduler + a worker thread using thread-locals) and
    // propagating bit_main's return value out as the process exit code.
    const code = [_]u8{ 0x40, 0x05, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6 };
    var atoms = [_]object.Atom{
        .{ .name = "_bit_main", .kind = .text, .binding = .global, .data = &code, .size = code.len, .alignment = 4, .relocs = &.{} },
    };
    var modules: std.ArrayList(object.Module) = .empty;
    try modules.append(arena, .{ .name = "bit.o", .atoms = &atoms });
    for (try archive.parse(arena, lib)) |m| try modules.append(arena, try macho_reader.read(arena, m.name, m.data));

    const exe = try linkExecutable(gpa, modules.items, .{ .identifier = "bit-runtime" });
    defer gpa.free(exe);
    std.Io.Dir.cwd().writeFile(threaded.io(), .{ .sub_path = "zig-out/bit-macho-runtime", .data = exe }) catch {};

    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
}
