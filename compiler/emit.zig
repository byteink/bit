//! Back-end adapter (task #347): turns a lowered `ir.Module` into relocatable
//! object bytes. Codegen's per-function `FuncCode` (machine code + call/abs
//! relocations) is concatenated into `.text`; the module's string pool becomes
//! `.rodata` (`{ptr,len}` headers + bytes, the v1 static-string layout); a
//! `bit_main` entry trampoline calls the user's `main` and yields its `i32`
//! (or 0 for a `void` main) as the process exit code the runtime's `_start`
//! expects (runtime/ABI.md). Every relocation target the object does not itself
//! define (runtime `bit_rt_*` symbols) is emitted as an undefined external so
//! the object writer accepts it and the linker resolves it against `libbitrt.a`.
//!
//! x86-64 only for now; the ARM64 path joins when its Mach-O writer lands.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ir = @import("ir.zig");
const x64 = @import("codegen/x64.zig");
const obj_elf = @import("obj/elf.zig");

pub const Error = error{NoMain} || x64.CodegenError || obj_elf.Error || Allocator.Error;

/// Emits `module` as an x86-64 ELF relocatable object. The returned bytes are
/// owned by `gpa`; the module's `main` becomes the runtime entry.
pub fn emitObject(gpa: Allocator, module: *const ir.Module) Error![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var code: std.ArrayList(u8) = .empty;
    var rodata: std.ArrayList(u8) = .empty;
    var symbols: std.ArrayList(obj_elf.Symbol) = .empty;
    var relocs: std.ArrayList(obj_elf.Relocation) = .empty;
    var defined = std.StringHashMapUnmanaged(void){};

    // ---- every function -> one .text symbol + its relocations -------------
    var main_void = false;
    var have_main = false;
    for (module.funcs.items) |*f| {
        var fc = try x64.compileFunction(gpa, module, f, .sysv);
        defer fc.deinit();
        const off: u64 = code.items.len;
        try code.appendSlice(a, fc.code);
        try symbols.append(a, .{ .name = try a.dupe(u8, f.name), .section = .text, .offset = off, .size = fc.code.len, .binding = .global, .kind = .func });
        try defined.put(a, f.name, {});
        for (fc.relocs) |r| try relocs.append(a, .{
            .section = .text,
            .offset = off + r.offset,
            .symbol = try a.dupe(u8, r.symbol),
            .kind = switch (r.kind) {
                .call => .pc32,
                .abs64 => .abs64,
            },
            .addend = switch (r.kind) {
                .call => -4,
                .abs64 => 0,
            },
        });
        if (std.mem.eql(u8, f.name, "main")) {
            have_main = true;
            main_void = module.ctx.typeOf(f.result) == .void;
        }
    }
    if (!have_main) return error.NoMain;

    // ---- bit_main entry trampoline ----------------------------------------
    // On entry rsp%16==8 (the call into bit_main pushed a return address); a
    // single `sub rsp,8` re-aligns it so the SysV call below is 16-aligned.
    //   sub rsp,8 ; call main ; [xor eax,eax if void] ; add rsp,8 ; ret
    const tramp: u64 = code.items.len;
    try code.appendSlice(a, &.{ 0x48, 0x83, 0xEC, 0x08 });
    try code.append(a, 0xE8);
    const call_field: u64 = code.items.len;
    try code.appendSlice(a, &.{ 0, 0, 0, 0 });
    try relocs.append(a, .{ .section = .text, .offset = call_field, .symbol = "main", .kind = .pc32, .addend = -4 });
    if (main_void) try code.appendSlice(a, &.{ 0x31, 0xC0 }); // void main -> exit 0
    try code.appendSlice(a, &.{ 0x48, 0x83, 0xC4, 0x08, 0xC3 });
    try symbols.append(a, .{ .name = "bit_main", .section = .text, .offset = tramp, .size = code.items.len - tramp, .binding = .global, .kind = .func });
    try defined.put(a, "bit_main", {});

    // ---- string pool -> .rodata headers + bytes ---------------------------
    for (module.string_pool.items, 0..) |s, i| {
        const data_off: u64 = rodata.items.len;
        try rodata.appendSlice(a, s);
        const data_name = try std.fmt.allocPrint(a, "__bitstr_{d}_data", .{i});
        try symbols.append(a, .{ .name = data_name, .section = .rodata, .offset = data_off, .size = s.len, .binding = .local, .kind = .object });
        try defined.put(a, data_name, {});

        while (rodata.items.len % 8 != 0) try rodata.append(a, 0);
        const hdr_off: u64 = rodata.items.len;
        try rodata.appendSlice(a, &(.{0} ** 8)); // ptr — filled by the reloc below
        var lenbuf: [8]u8 = undefined;
        std.mem.writeInt(u64, &lenbuf, s.len, .little);
        try rodata.appendSlice(a, &lenbuf); // len
        const hdr_name = try std.fmt.allocPrint(a, "__bitstr_{d}", .{i});
        try symbols.append(a, .{ .name = hdr_name, .section = .rodata, .offset = hdr_off, .size = 16, .binding = .global, .kind = .object });
        try defined.put(a, hdr_name, {});
        try relocs.append(a, .{ .section = .rodata, .offset = hdr_off, .symbol = data_name, .kind = .abs64, .addend = 0 });
    }

    // ---- undefined externals for everything the object references but does
    //      not define (runtime `bit_rt_*` symbols) --------------------------
    var externs = std.StringHashMapUnmanaged(void){};
    for (relocs.items) |r| {
        if (defined.contains(r.symbol) or externs.contains(r.symbol)) continue;
        try externs.put(a, r.symbol, {});
        try symbols.append(a, .{ .name = r.symbol, .section = null, .binding = .global, .kind = .notype });
    }

    var sections: std.ArrayList(obj_elf.Section) = .empty;
    try sections.append(a, .{ .kind = .text, .data = code.items, .alignment = 16 });
    if (rodata.items.len > 0) try sections.append(a, .{ .kind = .rodata, .data = rodata.items, .alignment = 8 });

    return obj_elf.write(gpa, .x86_64, .{ .sections = sections.items, .symbols = symbols.items, .relocations = relocs.items });
}
