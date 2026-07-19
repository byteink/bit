//! Static linker driver + ELF executable writer (task #345). Turns the
//! compiled Bit program's object plus `libbitrt.a` into one standalone,
//! zero-dynamic-linker, zero-libc ELF executable — the "ship one binary like
//! Go/Zig" promise.
//!
//! Pipeline: read every input into the generic object model (`link/object.zig`
//! via `link/elf_reader.zig`/`link/archive.zig`), resolve the whole-link
//! global symbol table and dead-strip from the entry root `_start`
//! (`link/strip.zig`), lay the surviving atoms out into two page-aligned
//! `PT_LOAD` segments (R-X: headers/text/rodata; R-W: data/GOT/TLS-init/bss)
//! plus a `PT_TLS` describing the thread-local image, apply every relocation
//! against the assigned addresses, then emit `Ehdr` + `Phdr`s + segment bytes.
//!
//! Non-PIE `ET_EXEC` at a fixed base: the kernel maps each `PT_LOAD` at its
//! `p_vaddr` and jumps to `e_entry` (= `_start`), which the runtime provides.
//! File layout mirrors memory layout (a segment's file offset equals its
//! vaddr minus the load base), so `.bss`/`.tbss` are the only file-vs-mem size
//! gap. Mach-O (#345 cont.) and PE writers are separate; this file is ELF.

const std = @import("std");
const elf = std.elf;
const Allocator = std.mem.Allocator;

const object = @import("link/object.zig");
const elf_reader = @import("link/elf_reader.zig");
const archive = @import("link/archive.zig");
const strip = @import("link/strip.zig");

pub const Target = enum {
    x86_64_linux,
    aarch64_linux,

    fn readerTarget(self: Target) elf_reader.Target {
        return switch (self) {
            .x86_64_linux => .x86_64,
            .aarch64_linux => .aarch64,
        };
    }

    fn machine(self: Target) elf.EM {
        return switch (self) {
            .x86_64_linux => .X86_64,
            .aarch64_linux => .AARCH64,
        };
    }
};

pub const Input = union(enum) {
    /// A single relocatable ELF object — the compiled Bit program.
    object: []const u8,
    /// An `ar` archive (`libbitrt.a`); every member is read as its own module.
    archive: []const u8,
};

/// Fixed non-PIE load base. Traditional x86-64 `ET_EXEC` value; well clear of
/// the kernel's `mmap_min_addr` and the zero page.
const load_base: u64 = 0x400000;
const page: u64 = 0x1000;
const entry_symbol = "_start";
const got_entry_size: u64 = 8;

fn alignUp(v: u64, a: u64) u64 {
    if (a <= 1) return v;
    return std.mem.alignForward(u64, v, a);
}

/// Links `inputs` into a standalone ELF executable, returned as owned bytes.
pub fn linkExecutable(gpa: Allocator, target: Target, inputs: []const Input) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // ---- ingest: every input becomes one or more generic modules ----------
    var modules: std.ArrayList(object.Module) = .empty;
    for (inputs) |input| switch (input) {
        .object => |bytes| {
            try modules.append(arena, try elf_reader.read(arena, target.readerTarget(), "bit.o", bytes));
        },
        .archive => |bytes| {
            const members = try archive.parse(arena, bytes);
            for (members) |m| try modules.append(arena, try elf_reader.read(arena, target.readerTarget(), m.name, m.data));
        },
    };
    // ABI.md §4: the merged GC stack-map table's bounds are linker-defined, so
    // the boundary symbols enter the link as a synthetic module. It goes in
    // BEFORE `resolveGlobals` so the runtime's `extern` references resolve
    // like any other global, and last so its index is stable.
    const marker_module: u32 = @intCast(modules.items.len);
    try modules.append(arena, try strip.markerModule(arena, ""));
    const mods = modules.items;

    // ---- resolve + dead-strip ---------------------------------------------
    var globals = try strip.resolveGlobals(arena, mods);
    var kept = try strip.deadStrip(arena, mods, &globals, &.{ entry_symbol, strip.stackmaps_start_symbol, strip.stackmaps_end_symbol });
    defer kept.deinit(arena);

    // `-fdata-sections` can emit one variable as several adjacent symbols in a
    // single section (std's TLS `area_desc` is split into `area_desc.0/.1/...`).
    // Dead-stripping the unreferenced pieces would repack the survivors and shift
    // the variable's fields, corrupting it. Keep every mutable-data atom (.data,
    // .bss, and the TLS init/bss) so their in-section layout is preserved; code
    // (.text) and read-only constants (.rodata) are still granularly stripped.
    for (mods, 0..) |mod, mi| {
        for (mod.atoms, 0..) |atom, ai| {
            switch (atom.kind) {
                .data, .bss, .tls_data, .tls_bss => try kept.set.put(arena, (strip.AtomId{ .module = @intCast(mi), .atom = @intCast(ai) }).key(), {}),
                else => {},
            }
        }
    }

    // ---- collect kept atoms, partitioned by output class ------------------
    var text: std.ArrayList(Placed) = .empty;
    var rodata: std.ArrayList(Placed) = .empty;
    var data: std.ArrayList(Placed) = .empty;
    var bss: std.ArrayList(Placed) = .empty;
    var tdata: std.ArrayList(Placed) = .empty;
    var tbss: std.ArrayList(Placed) = .empty;
    for (mods, 0..) |mod, mi| {
        for (mod.atoms, 0..) |atom, ai| {
            const id: strip.AtomId = .{ .module = @intCast(mi), .atom = @intCast(ai) };
            if (!kept.contains(id)) continue;
            const list = switch (atom.kind) {
                .text => &text,
                .rodata => &rodata,
                .data => &data,
                .bss => &bss,
                .tls_data => &tdata,
                .tls_bss => &tbss,
                // Placed as one uninterrupted run below, not here: their order
                // and adjacency are the merged table's whole contract.
                .gc_meta => continue,
                // `.tls_vars` is a macOS `tlv_descriptor` section (§ link/macho.zig);
                // ELF has no equivalent and `elf_reader.zig` never produces it.
                .tls_vars => unreachable,
            };
            try list.append(arena, .{ .id = id });
        }
    }

    // ---- merged GC stack-map group (ABI.md §4) ----------------------------
    // Appended to `rodata` as one contiguous run: the entries are read-only,
    // hold absolute code pointers this non-PIE image never rebases, and must
    // sit between the two boundary markers with nothing interleaved. Appending
    // last means no later atom can land inside the extent.
    for (try strip.mergedStackMapAtoms(arena, mods, &globals, &kept, marker_module)) |id|
        try rodata.append(arena, .{ .id = id });

    // ---- lay out the two PT_LOAD segments ---------------------------------
    // Headers occupy the very start of the R-X segment and are loaded too, so
    // reserve their size before the first text atom. Phdr count is known up
    // front: 2 PT_LOAD + PT_GNU_STACK, plus PT_TLS iff there is any TLS.
    const has_tls = tdata.items.len + tbss.items.len > 0;
    const phnum: u16 = if (has_tls) 4 else 3;
    const headers_size = @sizeOf(elf.Elf64_Ehdr) + @as(u64, phnum) * @sizeOf(elf.Elf64_Phdr);

    var cursor: u64 = load_base + headers_size;
    // R-X segment: text then rodata.
    placeAtoms(mods, text.items, &cursor);
    placeAtoms(mods, rodata.items, &cursor);
    const rx_end = cursor;

    // R-W segment starts on a fresh page. GOT, then data, then the TLS init
    // image (tdata), then bss (no file bytes), then tbss.
    cursor = alignUp(cursor, page);
    const rw_start = cursor;

    // GOT: one slot per distinct target of a GOT-relative relocation.
    var got_index = std.AutoHashMapUnmanaged(u64, u64){}; // AtomId.key() -> slot number
    var got_targets: std.ArrayList(strip.AtomId) = .empty;
    for (mods, 0..) |mod, mi| {
        for (mod.atoms, 0..) |atom, ai| {
            if (!kept.contains(.{ .module = @intCast(mi), .atom = @intCast(ai) })) continue;
            for (atom.relocs) |r| {
                if (!strip.needsGot(r.kind)) continue;
                const tgt = try strip.resolveRef(&globals, @intCast(mi), r.target);
                const gop = try got_index.getOrPut(arena, tgt.key());
                if (!gop.found_existing) {
                    gop.value_ptr.* = got_targets.items.len;
                    try got_targets.append(arena, tgt);
                }
            }
        }
    }
    const got_vaddr = cursor;
    cursor += got_targets.items.len * got_entry_size;

    placeAtoms(mods, data.items, &cursor);

    // TLS init image: tdata gets file bytes, tbss extends memsz only. Track
    // the block's own alignment and total size for the PT_TLS header and the
    // variant-II thread-pointer offsets.
    var tls_align: u64 = 1;
    for (tdata.items) |*p| tls_align = @max(tls_align, mods[p.id.module].atoms[p.id.atom].alignment);
    for (tbss.items) |*p| tls_align = @max(tls_align, mods[p.id.module].atoms[p.id.atom].alignment);
    cursor = alignUp(cursor, tls_align);
    const tls_vaddr = cursor;
    var tls_off: u64 = 0;
    for (tdata.items) |*p| {
        const a = mods[p.id.module].atoms[p.id.atom];
        tls_off = alignUp(tls_off, a.alignment);
        p.tls_offset = tls_off;
        p.vaddr = tls_vaddr + tls_off;
        tls_off += a.size;
    }
    const tdata_filesz = tls_off; // bytes with a file image
    for (tbss.items) |*p| {
        const a = mods[p.id.module].atoms[p.id.atom];
        tls_off = alignUp(tls_off, a.alignment);
        p.tls_offset = tls_off;
        p.vaddr = tls_vaddr + tls_off;
        tls_off += a.size;
    }
    const tls_memsz = tls_off;
    const tls_size_aligned = alignUp(tls_memsz, tls_align);
    cursor = tls_vaddr + tdata_filesz; // only tdata occupies file/mem here; bss/tbss below

    // .bss and .tbss carry no file bytes. .tbss memory already accounted in
    // tls_memsz; place ordinary .bss after the TLS init image.
    const rw_file_end = cursor; // last vaddr backed by file bytes in R-W
    placeAtoms(mods, bss.items, &cursor); // extends memsz only (data is empty)
    const rw_mem_end = cursor;

    // ---- address lookup for every placed atom -----------------------------
    var addr_of = std.AutoHashMapUnmanaged(u64, u64){}; // AtomId.key() -> vaddr
    for ([_][]const Placed{ text.items, rodata.items, data.items, bss.items }) |group| {
        for (group) |p| try addr_of.put(arena, p.id.key(), p.vaddr);
    }
    // TLS atoms resolve to thread-pointer offsets, not vaddrs; keyed separately.
    var tpoff_of = std.AutoHashMapUnmanaged(u64, i64){};
    for ([_][]const Placed{ tdata.items, tbss.items }) |group| {
        for (group) |p| {
            const tpoff: i64 = switch (target) {
                // Variant II (x86-64): the static TLS block sits below the thread
                // pointer, so a symbol at block offset `o` is at TP - (aligned
                // block size) + o.
                .x86_64_linux => @as(i64, @intCast(p.tls_offset)) - @as(i64, @intCast(tls_size_aligned)),
                // Variant I (AArch64): the block sits above the thread pointer,
                // after a 16-byte ABI TCB aligned to the block's own alignment
                // (Zig's `std.os.linux.tls` layout — @sizeOf(AbiTcb)=16), so a
                // symbol at block offset `o` is at TP + alignUp(16, align) + o.
                .aarch64_linux => @intCast(alignUp(16, tls_align) + p.tls_offset),
            };
            try tpoff_of.put(arena, p.id.key(), tpoff);
        }
    }

    const entry_id = globals.get(entry_symbol) orelse return error.MissingEntry;
    const entry_vaddr = addr_of.get(entry_id.key()) orelse return error.MissingEntry;

    // ---- apply relocations into per-atom mutable copies -------------------
    var patched = std.AutoHashMapUnmanaged(u64, []u8){}; // AtomId.key() -> data
    for (mods, 0..) |mod, mi| {
        for (mod.atoms, 0..) |atom, ai| {
            const id: strip.AtomId = .{ .module = @intCast(mi), .atom = @intCast(ai) };
            if (!kept.contains(id) or atom.data.len == 0) continue;
            const buf = try arena.dupe(u8, atom.data);
            const atom_vaddr = addr_of.get(id.key()) orelse 0; // TLS atoms: data patched, addressed via tpoff by others
            for (atom.relocs) |r| {
                const tgt = try strip.resolveRef(&globals, @intCast(mi), r.target);
                const field = buf[r.offset..];
                var vals: strip.Values = .{ .s = 0, .p = atom_vaddr + r.offset };
                if (strip.isTls(r.kind)) {
                    vals.tp_offset = (tpoff_of.get(tgt.key()) orelse return error.UndefinedSymbol) + r.addend;
                } else if (strip.needsGot(r.kind)) {
                    const slot = got_index.get(tgt.key()).?;
                    const slot_addr = got_vaddr + slot * got_entry_size;
                    // The addend (−4 for `REX_GOTPCRELX`) is part of the PC-
                    // relative arithmetic, exactly as for `pc32`; fold it into
                    // the GOT-slot address the field resolves against.
                    vals.got_slot = @bitCast(@as(i64, @bitCast(slot_addr)) + r.addend);
                } else {
                    const tgt_addr = addr_of.get(tgt.key()) orelse return error.UndefinedSymbol;
                    vals.s = @as(u64, @bitCast(@as(i64, @bitCast(tgt_addr)) + r.addend));
                }
                try strip.apply(r.kind, field, vals);
            }
            try patched.put(arena, id.key(), buf);
        }
    }

    // ---- emit the ELF image -----------------------------------------------
    return writeElf(gpa, .{
        .entry = entry_vaddr,
        .phnum = phnum,
        .headers_size = headers_size,
        .rx_end = rx_end,
        .rw_start = rw_start,
        .rw_file_end = rw_file_end,
        .rw_mem_end = rw_mem_end,
        .has_tls = has_tls,
        .tls_vaddr = tls_vaddr,
        .tls_filesz = tdata_filesz,
        .tls_memsz = tls_memsz,
        .tls_align = tls_align,
        .got_vaddr = got_vaddr,
        .got_targets = got_targets.items,
        .addr_of = &addr_of,
        .machine = target.machine(),
    }, .{
        .text = text.items,
        .rodata = rodata.items,
        .data = data.items,
        .tdata = tdata.items,
    }, mods, &patched);
}

fn placeAtoms(mods: []const object.Module, items: anytype, cursor: *u64) void {
    for (items) |*p| {
        const a = mods[p.id.module].atoms[p.id.atom];
        cursor.* = alignUp(cursor.*, a.alignment);
        p.vaddr = cursor.*;
        cursor.* += a.size;
    }
}

const Layout = struct {
    entry: u64,
    phnum: u16,
    headers_size: u64,
    rx_end: u64,
    rw_start: u64,
    rw_file_end: u64,
    rw_mem_end: u64,
    has_tls: bool,
    tls_vaddr: u64,
    tls_filesz: u64,
    tls_memsz: u64,
    tls_align: u64,
    got_vaddr: u64,
    got_targets: []const strip.AtomId,
    addr_of: *std.AutoHashMapUnmanaged(u64, u64),
    machine: elf.EM,
};

const Placed = struct { id: strip.AtomId, vaddr: u64 = 0, tls_offset: u64 = 0 };

const Groups = struct {
    text: []const Placed,
    rodata: []const Placed,
    data: []const Placed,
    tdata: []const Placed,
};

/// Serializes the laid-out image. File offset == vaddr - load_base for every
/// byte-backed region, so the segment tables and section copies share one
/// address arithmetic.
fn writeElf(gpa: Allocator, l: Layout, g: Groups, mods: []const object.Module, patched: *std.AutoHashMapUnmanaged(u64, []u8)) ![]u8 {
    const file_size = l.rw_file_end - load_base;
    const buf = try gpa.alloc(u8, file_size);
    errdefer gpa.free(buf);
    @memset(buf, 0);

    // Copy every byte-backed atom to (vaddr - load_base). BSS/TBSS have no
    // bytes; TLS init bytes (tdata) do get written.
    for ([_][]const Placed{ g.text, g.rodata, g.data, g.tdata }) |group| {
        for (group) |p| {
            const bytes = patched.get(p.id.key()) orelse mods[p.id.module].atoms[p.id.atom].data;
            if (bytes.len == 0) continue;
            const off = p.vaddr - load_base;
            @memcpy(buf[off..][0..bytes.len], bytes);
        }
    }
    // GOT slots: each holds its target's absolute address.
    for (l.got_targets, 0..) |tgt, i| {
        const off = (l.got_vaddr + i * got_entry_size) - load_base;
        const addr = l.addr_of.get(tgt.key()) orelse return error.UndefinedSymbol;
        std.mem.writeInt(u64, buf[off..][0..8], addr, .little);
    }

    // Ehdr.
    var ehdr = std.mem.zeroes(elf.Elf64_Ehdr);
    ehdr.e_ident[0..4].* = elf.MAGIC.*;
    ehdr.e_ident[elf.EI_CLASS] = elf.ELFCLASS64;
    ehdr.e_ident[elf.EI_DATA] = elf.ELFDATA2LSB;
    ehdr.e_ident[elf.EI_VERSION] = 1;
    ehdr.e_type = .EXEC;
    ehdr.e_machine = l.machine;
    ehdr.e_version = 1;
    ehdr.e_entry = l.entry;
    ehdr.e_phoff = @sizeOf(elf.Elf64_Ehdr);
    ehdr.e_ehsize = @sizeOf(elf.Elf64_Ehdr);
    ehdr.e_phentsize = @sizeOf(elf.Elf64_Phdr);
    ehdr.e_phnum = l.phnum;
    @memcpy(buf[0..@sizeOf(elf.Elf64_Ehdr)], std.mem.asBytes(&ehdr));

    // Phdrs.
    var phdrs: std.ArrayList(elf.Elf64_Phdr) = .empty;
    defer phdrs.deinit(gpa);
    // R-X: headers + text + rodata, from load_base to rx_end.
    try phdrs.append(gpa, loadPhdr(0, load_base, l.rx_end - load_base, l.rx_end - load_base, elf.PF_R | elf.PF_X));
    // R-W: rw_start .. rw_mem_end (filesz stops at rw_file_end; the rest is bss).
    try phdrs.append(gpa, loadPhdr(l.rw_start - load_base, l.rw_start, l.rw_file_end - l.rw_start, l.rw_mem_end - l.rw_start, elf.PF_R | elf.PF_W));
    if (l.has_tls) {
        var tls = std.mem.zeroes(elf.Elf64_Phdr);
        tls.p_type = elf.PT_TLS;
        tls.p_flags = elf.PF_R;
        tls.p_offset = l.tls_vaddr - load_base;
        tls.p_vaddr = l.tls_vaddr;
        tls.p_paddr = l.tls_vaddr;
        tls.p_filesz = l.tls_filesz;
        tls.p_memsz = l.tls_memsz;
        tls.p_align = l.tls_align;
        try phdrs.append(gpa, tls);
    }
    // PT_GNU_STACK: non-executable stack, no mapped bytes.
    var gnu_stack = std.mem.zeroes(elf.Elf64_Phdr);
    gnu_stack.p_type = elf.PT_GNU_STACK;
    gnu_stack.p_flags = elf.PF_R | elf.PF_W;
    gnu_stack.p_align = page;
    try phdrs.append(gpa, gnu_stack);

    std.debug.assert(phdrs.items.len == l.phnum);
    const ph_off = @sizeOf(elf.Elf64_Ehdr);
    for (phdrs.items, 0..) |ph, i| {
        @memcpy(buf[ph_off + i * @sizeOf(elf.Elf64_Phdr) ..][0..@sizeOf(elf.Elf64_Phdr)], std.mem.asBytes(&ph));
    }

    return buf;
}

fn loadPhdr(offset: u64, vaddr: u64, filesz: u64, memsz: u64, flags: u32) elf.Elf64_Phdr {
    var ph = std.mem.zeroes(elf.Elf64_Phdr);
    ph.p_type = elf.PT_LOAD;
    ph.p_flags = flags;
    ph.p_offset = offset;
    ph.p_vaddr = vaddr;
    ph.p_paddr = vaddr;
    ph.p_filesz = filesz;
    ph.p_memsz = memsz;
    ph.p_align = page;
    return ph;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
const testing = std.testing;
const builtin = @import("builtin");
const obj_elf = @import("obj/elf.zig");

// The emitted files are x86-64 Linux ELF executables; only a real x86-64 Linux
// host can load and run them (the CI runner this backend targets). Elsewhere
// the execution tests self-skip and only the structural checks run.
const can_exec_native = builtin.cpu.arch == .x86_64 and builtin.os.tag == .linux;

test {
    testing.refAllDecls(@This());
    _ = strip;
}

/// Writes `exe` under `zig-out/`, marks it executable, runs it, and returns
/// the process exit code — the actual "single binary runs on a clean machine"
/// proof the task's verify section calls for.
fn linkAndRun(gpa: Allocator, name: []const u8, exe: []const u8) !u8 {
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // An absolute path under /tmp: always writable and isolated from the build
    // system's `zig-out/` (which it fails to write into under `zig build
    // test`), and `execve`-able directly.
    const sub = try std.fmt.allocPrintSentinel(gpa, "/tmp/bit-{s}", .{name}, 0);
    defer gpa.free(sub);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = sub, .data = exe });
    _ = std.os.linux.fchmodat(std.os.linux.AT.FDCWD, sub, 0o755); // exec bit; caller is x86-64 Linux

    var child = try std.process.spawn(io, .{ .argv = &.{sub} });
    return switch (try child.wait(io)) {
        .exited => |c| c,
        else => error.AbnormalExit,
    };
}

test "links a bit_main object with libbitrt into a running zero-libc executable" {
    const gpa = testing.allocator;

    // `mov eax, 42` (B8 2A 00 00 00) then `ret` (C3): bit_main() -> 42.
    const code = [_]u8{ 0xB8, 0x2A, 0x00, 0x00, 0x00, 0xC3 };
    const sections = [_]obj_elf.Section{.{ .kind = .text, .data = &code, .alignment = 16 }};
    const symbols = [_]obj_elf.Symbol{.{ .name = "bit_main", .section = .text, .offset = 0, .size = code.len, .binding = .global, .kind = .func }};
    const bit_obj = try obj_elf.write(gpa, .x86_64, .{ .sections = &sections, .symbols = &symbols });
    defer gpa.free(bit_obj);

    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const lib = std.Io.Dir.cwd().readFileAlloc(threaded.io(), "zig-out/lib/x86_64-linux/libbitrt.a", gpa, .unlimited) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest, // `zig build libbitrt` not run here
        else => return err,
    };
    defer gpa.free(lib);

    const exe = try linkExecutable(gpa, .x86_64_linux, &.{ .{ .object = bit_obj }, .{ .archive = lib } });
    defer gpa.free(exe);

    try testing.expect(exe.len > @sizeOf(elf.Elf64_Ehdr));
    try testing.expectEqualSlices(u8, elf.MAGIC, exe[0..4]);
    const ehdr = std.mem.bytesToValue(elf.Elf64_Ehdr, exe[0..@sizeOf(elf.Elf64_Ehdr)]);
    try testing.expectEqual(elf.ET.EXEC, ehdr.e_type);
    try testing.expectEqual(elf.EM.X86_64, ehdr.e_machine);
    try testing.expect(ehdr.e_entry >= load_base);

    if (!can_exec_native) return error.SkipZigTest;
    // The runtime boots (TLS, GC, scheduler, a worker thread), runs bit_main as
    // a green thread, and returns its value as the process exit code.
    try testing.expectEqual(@as(u8, 42), try linkAndRun(gpa, "bit-hello", exe));
}

test "links a self-contained _start into a running executable" {
    const gpa = testing.allocator;
    // mov edi,42 ; mov eax,60 (SYS_exit) ; syscall  — no runtime, no TLS, no GOT.
    const code = [_]u8{ 0xBF, 0x2A, 0x00, 0x00, 0x00, 0xB8, 0x3C, 0x00, 0x00, 0x00, 0x0F, 0x05 };
    const sections = [_]obj_elf.Section{.{ .kind = .text, .data = &code, .alignment = 16 }};
    const symbols = [_]obj_elf.Symbol{.{ .name = "_start", .section = .text, .offset = 0, .size = code.len, .binding = .global, .kind = .func }};
    const obj = try obj_elf.write(gpa, .x86_64, .{ .sections = &sections, .symbols = &symbols });
    defer gpa.free(obj);

    const exe = try linkExecutable(gpa, .x86_64_linux, &.{.{ .object = obj }});
    defer gpa.free(exe);
    try testing.expect(exe.len > 0);

    if (!can_exec_native) return error.SkipZigTest;
    try testing.expectEqual(@as(u8, 42), try linkAndRun(gpa, "bit-raw", exe));
}
