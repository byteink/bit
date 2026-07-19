//! Runtime-pin cycle gate (#1367): no ported runtime symbol may call the ABI
//! name it is going to become.
//!
//! ---------------------------------------------------------------------------
//! THE DEFECT THIS EXISTS TO CATCH, AND WHY NOTHING ELSE CAN SEE IT
//! ---------------------------------------------------------------------------
//!
//! The Stage-2 runtime port defines each ABI function under a placeholder name
//! (`bit_rt_root_floor`) because `runtime/root.zig` is still linked into every
//! binary and already owns the real one (`bit_rt_floor`) — claiming it now fails
//! every link with `DuplicateSymbol`. #1369 retires `root.zig` and drops the
//! `_root` infix, at which point placeholder and real name become one symbol.
//!
//! That rename is where the defect detonates. Almost every ABI function this
//! port still has to cover has a *Bit primitive* that looks like a ready-made
//! implementation of it:
//!
//!     export @symbol("bit_rt_root_floor") function rtFloor(x: f64): f64 {
//!       return ffloor(x)          // looks like a one-line port
//!     }
//!
//! It is not one. `ffloor` is not lowered to a hardware instruction — it is
//! `ir.RtFn.floor`, which `seed/codegen/{arm64,x64}.zig` emit as a **call to
//! `bit_rt_floor`** (`rtSymbol`). So the body above compiles to "call the Zig
//! runtime", and after #1369's rename it compiles to **a call to itself**:
//! unbounded recursion, discovered as a stack overflow in a shipped binary.
//!
//! Every stage in between reads green, which is the whole problem:
//!
//!   - it builds, because the two names are still distinct;
//!   - it links, for the same reason;
//!   - it *runs correctly*, because the call lands on the working Zig;
//!   - `--freestanding` does not refuse it — the reference is pinned, and
//!     `refuseUnpinnedImports` checks pinning, not identity;
//!   - the differential gates compare check/type/IR dumps, and this is a
//!     property of the emitted object's symbols, not of any dump.
//!
//! There is no point before the rename at which reading the source tells you.
//! Hence this gate: it performs the rename *symbolically*, on an object the
//! compiler has actually emitted, and asks whether any definition would then
//! reference itself.
//!
//! ---------------------------------------------------------------------------
//! WHY IT READS AN OBJECT INSTEAD OF SCANNING SOURCE
//! ---------------------------------------------------------------------------
//!
//! Because the source does not contain the answer. `return ffloor(x)` names no
//! `bit_rt_*` symbol anywhere; the call target is invented by codegen out of an
//! `RtFn` tag. A grep-based guard would have to re-derive the whole primitive ->
//! RtFn -> symbol table and would silently rot the moment one entry moved. The
//! emitted object is the oracle, and it is the *same* oracle the linker uses.
//!
//! ---------------------------------------------------------------------------
//! WHY IT EMITS FOR x86_64-linux ON EVERY HOST
//! ---------------------------------------------------------------------------
//!
//! The property is target-independent — an `RtFn` becomes a call on every
//! backend — but the *reader* is not: only ELF has one here. Emitting ELF
//! regardless of host makes this gate fail identically on macOS and Linux,
//! which is the pattern #1421 established after a module-state alignment bug
//! that was correct on aarch64-macOS and wrong on ELF passed the entire
//! host-native golden suite.
//!
//! Nothing is linked or executed, so no `libbitrt.a` is needed and the gate has
//! no skip path: it runs on every host, always.

const std = @import("std");
const bit = @import("bit");
const build_options = @import("build_options");

const testing = std.testing;
const Io = std.Io;

/// The placeholder prefix the Stage-2 port pins its ABI functions under, and
/// the prefix #1369 rewrites it to. Keep both spellings here: when #1369 lands,
/// `placeholder` becomes `""` and this gate keeps working unchanged, now
/// checking plain self-reference.
const placeholder = "bit_rt_root_";
const real = "bit_rt_";

/// Runtime modules built from Bit that define pinned ABI symbols. Each is a
/// module directory (SPEC §17.1) emitted on its own, exactly as #1369 will
/// assemble the archive.
///
/// The platform providers are listed explicitly rather than discovered: a
/// `linux/` module cannot be emitted for a Darwin target and vice versa (the
/// checker refuses `syscall` targeting Darwin and `extern function` targeting
/// Linux, even on an uncalled declaration), so the set is a property of the
/// chosen emit target, not of the directory tree.
const modules = [_][]const u8{
    "runtime/root",
    "runtime/root/linux",
};

/// Upper bound on symbols in one object — keeps every walk below provably
/// bounded (Power of 10 rule 2). Two orders of magnitude above today's ~120.
const max_symbols = 16384;

test "no ported runtime pin calls the ABI name it becomes" {
    const io = Io.Threaded.global_single_threaded.io();

    // An arena for the reader's output, exactly as `link.zig` reads objects:
    // `elf_reader.read` returns borrowed and freshly-allocated slices mixed
    // together and has no matching deinit, so lifetime is the caller's arena.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    var found_any = false;
    for (modules) |rel| {
        const abs = try std.fs.path.join(gpa, &.{ build_options.repo_root, rel });

        const obj = try emitElfObject(gpa, io, abs, rel);

        const module = bit.elf_reader.read(gpa, .x86_64, rel, obj) catch |e| {
            std.debug.print("rootpins: cannot read emitted object for '{s}': {s}\n", .{ rel, @errorName(e) });
            return e;
        };

        found_any = try checkModule(gpa, rel, module) or found_any;
    }

    // A vacuous pass is the failure mode this gate is most exposed to: if the
    // emit path changed shape and produced objects with no pinned definitions
    // at all, every check below would trivially hold. Require that at least one
    // module actually contributed a pinned ABI definition to examine.
    try testing.expect(found_any);
}

/// Emits `dir_abs` as a relocatable ELF object for x86-64. Not freestanding:
/// `--freestanding` additionally refuses unpinned imports and managed metadata,
/// which several of these modules still trip (#1434, #1421) — and none of that
/// is what this gate is about. An ordinary object carries the same relocations.
fn emitElfObject(gpa: std.mem.Allocator, io: Io, dir_abs: []const u8, name: []const u8) ![]u8 {
    var diags: Io.Writer.Allocating = .init(gpa);
    defer diags.deinit();

    const obj = (try bit.buildProject(
        gpa,
        io,
        dir_abs,
        null,
        build_options.stdlib_dir,
        name,
        "", // no archive: emit_obj never links
        .x86_64_linux,
        &diags.writer,
        null,
        true, // emit_obj
        false, // freestanding
    )) orelse {
        std.debug.print("rootpins: '{s}' failed to compile:\n{s}\n", .{ name, diags.written() });
        return error.RuntimeModuleCompileFailed;
    };
    return obj;
}

/// True if `module` defined at least one pinned ABI symbol. Fails the test on
/// any post-rename self-reference.
///
/// THE CONDITION IS SELF-REFERENCE, NOT "REFERENCES SOMETHING THIS OBJECT
/// DEFINES", and the distinction is the difference between a gate and a nuisance.
/// A first cut checked the latter and reported `m0$println -> bit_rt_string_concat`
/// alongside the real findings. That one is correct code: the prelude calling
/// into the runtime is the entire point of a runtime, and after the rename it
/// simply lands on the Bit implementation instead of the Zig one. So is one
/// runtime function calling another (`bit_rt_map_set` -> `bit_rt_string_concat`).
/// Only a definition reaching *itself* is unconditionally a defect, and
/// narrowing to it took the finding from four symbols to the two that are real.
fn checkModule(gpa: std.mem.Allocator, name: []const u8, module: anytype) !bool {
    var pinned_abi: usize = 0;
    var failures: usize = 0;
    var scanned: usize = 0;
    for (module.atoms) |atom| {
        scanned += 1;
        if (scanned > max_symbols) return error.TooManySymbols;
        if (atom.binding != .global) continue;
        if (!std.mem.startsWith(u8, atom.name, placeholder)) continue;
        pinned_abi += 1;

        // What this definition will be called after #1369 drops the `_root`
        // infix. Any outbound reference to this exact name is a call to itself.
        // Built, not sliced: `bit_rt_` and `float_bits` are not contiguous in
        // `bit_rt_root_float_bits`, and a slice that looked right on one prefix
        // pair would silently mis-derive on another.
        const renamed = try renameOf(gpa, atom.name);

        // `SymbolRef.global` is the linker's own view of the call target — the
        // name codegen actually emitted, not the name the source spelled —
        // which is what makes this gate see through the primitive -> RtFn ->
        // symbol indirection that no source scan can follow.
        for (atom.relocs) |r| {
            scanned += 1;
            if (scanned > max_symbols * 64) return error.TooManyRelocs;
            const target = switch (r.target) {
                .global => |g| g,
                .local => continue,
            };
            if (!std.mem.eql(u8, target, renamed)) continue;

            // `atom.name` is the placeholder spelling; report both so the fix
            // site and the collision are each named.
            std.debug.print(
                \\rootpins: {s}: '{s}' references '{s}'.
                \\  After #1369 renames '{s}' -> '{s}' these are ONE symbol and the
                \\  call becomes unbounded self-recursion. The reference is almost
                \\  certainly a Bit primitive that lowers to this RtFn (see
                \\  seed/lower.zig's primitive table and codegen's rtSymbol): the
                \\  primitive IS the Zig runtime function, so it cannot implement it.
                \\
            , .{ name, atom.name, target, atom.name, target });
            failures += 1;
        }
    }
    if (failures != 0) return error.RuntimePinCycle;
    return pinned_abi != 0;
}

/// `bit_rt_root_floor` -> `bit_rt_floor`; anything else unchanged.
fn renameOf(gpa: std.mem.Allocator, sym: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, sym, placeholder)) return sym;
    return std.fmt.allocPrint(gpa, "{s}{s}", .{ real, sym[placeholder.len..] });
}
