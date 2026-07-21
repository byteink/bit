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
//! WHY IT PINS A TARGET PER MODULE INSTEAD OF USING THE HOST'S
//! ---------------------------------------------------------------------------
//!
//! The property is target-independent — an `RtFn` becomes a call on every
//! backend — but the *modules* are not: a `linux/` provider cannot be emitted
//! for Darwin nor a `darwin/` one for Linux (the checker refuses `syscall` and
//! `extern function` respectively, even on an uncalled declaration). So each
//! module names the target it can be built for and is read back with that
//! format's reader.
//!
//! Fixing the target per module rather than following the host is also what
//! makes this gate fail *identically everywhere*, the pattern #1421 established
//! after a module-state alignment bug that was correct on aarch64-macOS and
//! wrong on ELF passed the entire host-native golden suite.
//!
//! Nothing is linked or executed, so no `libbitrt.a` is needed and the gate has
//! no skip path: it runs on every host, always.
//!
//! ---------------------------------------------------------------------------
//! WHAT MUTATION TESTING CHANGED ABOUT THIS FILE
//! ---------------------------------------------------------------------------
//!
//! Three defects, none visible by inspection, all found by mutating code the
//! gate was supposed to protect:
//!
//!   - The Darwin half examined NOTHING. Mach-O spells symbols with a leading
//!     underscore and `macho_reader` passes them through verbatim, so every
//!     Darwin name failed the `bit_rt_root_` prefix test. Reading green the
//!     whole time. (`Module.symPrefix`.)
//!   - The vacuity check was GLOBAL ("at least one module contributed"), which
//!     the two working modules satisfied while the third checked nothing. It is
//!     per-module now.
//!   - Emptying `modules` still passed, because a per-module check cannot fire
//!     for a module that is never visited. Hence the comptime length assert.

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

/// Runtime modules built from Bit that define pinned ABI symbols, each with the
/// target it must be emitted for. Each is a module directory (SPEC §17.1)
/// emitted on its own, exactly as #1369 will assemble the archive.
///
/// The platform providers are listed explicitly rather than discovered, and
/// carry their own target: a `linux/` module cannot be emitted for a Darwin
/// target and vice versa (the checker refuses `syscall` targeting Darwin and
/// `extern function` targeting Linux, even on an uncalled declaration). So the
/// buildable set is a property of the chosen target, not of the directory tree,
/// and covering both platform halves means emitting — and reading back — both
/// object formats.
///
/// `runtime/root*` and `runtime/net/{linux,darwin}` appear here, the complete
/// at-risk set rather than an arbitrary subset: the cycle is created by #1369's
/// rename, and `bit_rt_root_` is the only prefix that rename touches (SEAM 1 pins
/// its net wrappers under it too, #1574/#1600). `runtime/alloc`'s
/// `bit_rt_heap_*` and `runtime/gc`'s `bit_rt_port_*` pins are not ABI names
/// (ABI.md names no allocator symbol), so no rename will ever collide them with
/// an RtFn target. Add a module here the moment it starts pinning ABI names.
const Module = struct {
    path: []const u8,
    target: bit.BuildTarget,

    /// Mach-O carries the C leading underscore in the symbol table verbatim
    /// (`_bit_rt_root_print`), ELF does not. `macho_reader` hands names through
    /// unchanged, so the gate has to normalise or every Darwin name silently
    /// fails the `bit_rt_root_` prefix test and the whole platform half becomes
    /// a vacuous pass — which is exactly what it was until a Darwin-targeted
    /// mutation SURVIVED and said so.
    fn symPrefix(self: Module) []const u8 {
        return switch (self.target) {
            .aarch64_macos => "_",
            else => "",
        };
    }
};

const modules = [_]Module{
    .{ .path = "runtime/root", .target = .x86_64_linux },
    .{ .path = "runtime/root/linux", .target = .x86_64_linux },
    .{ .path = "runtime/root/darwin", .target = .aarch64_macos },
    // SEAM 1 (#1574, reshaped by #1600): the 12 `bit_rt_root_net_*` wrappers moved
    // OUT of the platform-free parent (`runtime/net`) and INTO the per-platform
    // providers `net/{linux,darwin}` — the fs.bit shape (#1606) — because the
    // parent form reached the socket engine by `extern function`, which a Linux
    // `--emit-obj` rejects (E0078) and G3 (#1584) would have hit. So `runtime/net`
    // no longer pins any `bit_rt_root_` name (net.bit keeps only the port-internal
    // `bit_rt_port_net_*`), and BOTH providers are listed instead, each on the
    // target its socket engine is written for (Linux `syscall`, Darwin libSystem).
    // The wrappers reach the engine as module-scoped SIBLINGS (`bit_rt_port_net_*`,
    // never renamed), so no reference to a post-rename `bit_rt_net_*` can exist —
    // which is what this gate proves per symbol.
    .{ .path = "runtime/net/linux", .target = .x86_64_linux },
    .{ .path = "runtime/net/darwin", .target = .aarch64_macos },
    // SEAM 2 (#1575): `runtime/gc`'s `gcworld.bit` pins the four
    // `bit_rt_root_gc_thread_enter/thread_exit/blocking_begin/blocking_end`
    // wrappers over the World/Mutator registry, so it joins the at-risk set — its
    // other pins (`bit_rt_port_gc_*`) are port-internal and never renamed, but
    // the four `bit_rt_root_gc_*` become bare ABI names at G2 (#1583). The module
    // is platform-free (no `syscall`/`extern function`), so the target is
    // arbitrary; aarch64-macos matches `runtime/net`. The wrappers reach the
    // registry only through `bit_rt_port_gc_world_*`, so no reference to a
    // post-rename `bit_rt_gc_*` name can exist — which is exactly what this gate
    // proves per symbol.
    .{ .path = "runtime/gc", .target = .aarch64_macos },
    // SEAM 7 (#1581): `runtime/chan`'s `chanwrap.bit` pins the five
    // allocation-free channel/select ABI wrappers (`bit_rt_root_chan_send/recv/
    // close` and `bit_rt_root_select`), which become bare ABI names at G2
    // (#1583). Its other pins (`bit_rt_port_chan_*`) are port-internal and never
    // renamed. The module is platform-free (no `syscall`/`extern function`), so
    // the target is arbitrary; aarch64-macos matches its siblings. The wrappers
    // reach the scheduler and the blocking operations only through
    // `bit_rt_port_sched_*` and same-module helpers, so no reference to a
    // post-rename `bit_rt_chan_*` name can exist — which is what this gate proves
    // per symbol.
    .{ .path = "runtime/chan", .target = .aarch64_macos },
    // #1626: the three crypto/test ABI pins. `runtime/rand` (rand.bit) pins the
    // platform-free `bit_rt_root_secure_zero` and is buildable for either target;
    // aarch64-macos matches its siblings. `runtime/rand/{linux,darwin}` each pin
    // `bit_rt_root_random_bytes` over their own `entropyFill`, so both halves are
    // listed on the target their entropy source is written for (Linux `syscall`,
    // Darwin `extern`) — the net-provider shape. The random_bytes wrappers do call
    // the `panic` builtin (which becomes `bit_rt_panic`), and that is precisely the
    // reference this gate has to adjudicate: neither module DEFINES
    // `bit_rt_root_panic`, so the rename cannot make it self-referential.
    // `bit_rt_root_test_index` needs no new entry — it lives in `runtime/root`,
    // already the first module listed.
    .{ .path = "runtime/rand", .target = .aarch64_macos },
    .{ .path = "runtime/rand/linux", .target = .x86_64_linux },
    .{ .path = "runtime/rand/darwin", .target = .aarch64_macos },
};

/// Upper bound on symbols in one object — keeps every walk below provably
/// bounded (Power of 10 rule 2). Two orders of magnitude above today's ~120.
const max_symbols = 16384;

test "no ported runtime pin calls the ABI name it becomes" {
    // An empty list makes the loop below a no-op and the whole gate a green
    // no-op with it. Caught by mutation: emptying `modules` passed, because the
    // per-module vacuity check can only fire for a module that is actually
    // visited. Every "did this examine anything" guard needs its own outer
    // guard at the level above.
    comptime std.debug.assert(modules.len != 0);

    const io = Io.Threaded.global_single_threaded.io();

    // An arena for the reader's output, exactly as `link.zig` reads objects:
    // `elf_reader.read` returns borrowed and freshly-allocated slices mixed
    // together and has no matching deinit, so lifetime is the caller's arena.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();

    for (modules) |m| {
        const abs = try std.fs.path.join(gpa, &.{ build_options.repo_root, m.path });

        const obj = try emitObject(gpa, io, abs, m);

        const module = switch (m.target) {
            .x86_64_linux => bit.elf_reader.read(gpa, .x86_64, m.path, obj),
            .aarch64_linux => bit.elf_reader.read(gpa, .aarch64, m.path, obj),
            .aarch64_macos => bit.macho_reader.read(gpa, m.path, obj),
        } catch |e| {
            std.debug.print("rootpins: cannot read emitted object for '{s}': {s}\n", .{ m.path, @errorName(e) });
            return e;
        };

        const examined = try checkModule(gpa, m, module);

        // PER MODULE, not once for the whole run — and that distinction is not
        // theoretical. A vacuous pass is the failure mode this gate is most
        // exposed to (nothing is asserted about a module whose names never match
        // the prefix), and a global "at least one module contributed" check is
        // satisfied by the other two while a third silently examines nothing.
        // That is precisely what happened: `runtime/root/darwin` matched zero
        // symbols for months of nothing, because Mach-O spells them with a
        // leading underscore, and the global check stayed green throughout. A
        // Darwin-targeted mutation SURVIVED and exposed it.
        if (!examined) {
            std.debug.print(
                "rootpins: '{s}' contributed no pinned ABI definitions — the gate " ++
                    "examined nothing. Either the module stopped pinning ABI names " ++
                    "(remove it from `modules`) or symbol spelling changed and the " ++
                    "prefix test no longer matches (see Module.symPrefix).\n",
                .{m.path},
            );
            return error.VacuousModuleCheck;
        }
    }
}

/// Emits `dir_abs` as a relocatable object for its module's target. Not
/// freestanding: `--freestanding` additionally refuses unpinned imports and
/// managed metadata, which several of these modules still trip (#1434, #1421) —
/// and none of that is what this gate is about. An ordinary object carries the
/// same relocations.
fn emitObject(gpa: std.mem.Allocator, io: Io, dir_abs: []const u8, m: Module) ![]u8 {
    const name = m.path;
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
        m.target,
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
fn checkModule(gpa: std.mem.Allocator, m: Module, module: anytype) !bool {
    const name = m.path;
    const sp = m.symPrefix();
    var pinned_abi: usize = 0;
    var failures: usize = 0;
    var scanned: usize = 0;
    for (module.atoms) |atom| {
        scanned += 1;
        if (scanned > max_symbols) return error.TooManySymbols;
        if (atom.binding != .global) continue;
        if (!std.mem.startsWith(u8, atom.name, sp)) continue;
        const bare = atom.name[sp.len..];
        if (!std.mem.startsWith(u8, bare, placeholder)) continue;
        pinned_abi += 1;

        // What this definition will be called after #1369 drops the `_root`
        // infix. Any outbound reference to this exact name is a call to itself.
        // Built, not sliced: `bit_rt_` and `float_bits` are not contiguous in
        // `bit_rt_root_float_bits`, and a slice that looked right on one prefix
        // pair would silently mis-derive on another.
        // Re-prefixed for the format being read, so it compares against the
        // relocation targets in their own spelling.
        const renamed = try renameOf(gpa, sp, bare);

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

/// `bit_rt_root_floor` -> `<sp>bit_rt_floor`, where `sp` is the object format's
/// symbol prefix (`_` on Mach-O). `bare` must already have that prefix stripped.
fn renameOf(gpa: std.mem.Allocator, sp: []const u8, bare: []const u8) ![]const u8 {
    std.debug.assert(std.mem.startsWith(u8, bare, placeholder));
    return std.fmt.allocPrint(gpa, "{s}{s}{s}", .{ sp, real, bare[placeholder.len..] });
}
