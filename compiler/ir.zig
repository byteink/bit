//! Typed SSA IR (task #336) — the bridge between the type checker
//! (`check.zig`) and the not-yet-built optimizer/codegen (#338+).
//!
//! Index-based, mirroring `ast.zig`'s house style: no node/instruction
//! pointers, everything is a `u32` index into flat per-function arrays, with
//! variable-length operand lists living in one shared `extra: []u32` pool
//! per function (exactly `ast.Tree.extra`'s shape).
//!
//! ## Phi via block parameters
//!
//! Classic SSA places phi instructions at block heads. This IR instead gives
//! blocks **parameters** (Cranelift/MIR style): a `jump`/`br` terminator
//! passes argument values matching its target block's param list, and that
//! list's values ARE the phi results at the target. This is strictly
//! equivalent to phi nodes but simpler to verify (no separate "which
//! predecessor did this phi operand come from" bookkeeping — the terminator
//! already ties an argument to its origin block) and simpler to build (a
//! loop header's carried values are just its block params).
//!
//! ## Instruction index == ValueId, including block parameters
//!
//! Every value-producing instruction's index within its function's `insts`
//! table IS its `ValueId` — a single 1:1 numbering, no separate value
//! table. Block parameters are represented as real instructions
//! (`Op.block_param`) placed as the leading `param_count` instructions of
//! their block; this keeps "instruction index is ValueId" universally true
//! (including phi/param results) and makes same-block dominance a plain
//! integer comparison (def index < use index). `Function` therefore has no
//! separate `values: []TypeId` table as a literal field — `insts.items(.ty)`
//! already *is* that table; duplicating it would be two sources of truth for
//! one fact. `Function.valueType` is the accessor.

const std = @import("std");
const check = @import("check.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const TypeId = check.TypeId;
const TypeContext = check.TypeContext;
const TypeData = check.TypeData;

/// An SSA value: either an instruction's result or a block parameter (itself
/// represented as an `Op.block_param` instruction — see module doc comment).
pub const ValueId = enum(u32) { _ };
/// A basic block, indexing `Function.blocks`.
pub const BlockId = enum(u32) { _ };
/// A function, indexing `Module.funcs`.
pub const FuncId = enum(u32) { _ };

/// Opaque runtime entry points lowering calls into `runtime/*.zig` symbols by
/// name (task's "until #346 nails the ABI further"). The `map_*` tags back
/// `map<K,V>` (§11.2, §13.5) — the real hash-table protocol, ABI.md §15;
/// `select` backs `select_stmt` (§13.7) — its exact runtime signature is
/// `runtime/chan.zig`'s to define, not lowering's; this tag just names the call
/// site.
pub const RtFn = enum {
    /// Two `string` args -> one fresh `string` (`a` then `b`). Backs `+` on
    /// strings and `str_interp` (§5.7): `lower.zig` converts each non-string
    /// part via `string_from_*` below, then folds the parts left-to-right into
    /// a chain of binary `string_concat`s.
    string_concat,
    /// One arg of any integer-prim type; codegen picks the concrete
    /// conversion from that arg's own recorded `TypeId` (every value is
    /// typed, so no separate width/signedness tag is needed here).
    string_from_int,
    string_from_float,
    string_from_bool,
    /// Two `string` args -> `bool`: byte-wise equality. Backs string `==`/`!=`
    /// (`!=` negates the result). Distinct from integer `icmp_eq`.
    string_eq,
    /// `(string, index) -> u8`: the byte at `index`, bounds-checked (panics on
    /// out-of-range, SPEC §18.4). Backs `s[i]` on a string.
    string_byte,
    /// `(string, lo, hi) -> string`: `s[lo:hi]` (SPEC §12.6) — a fresh string
    /// copying bytes `[lo, hi)`, bounds-checked. Copies rather than sharing: a
    /// string's `ptr` is an interior pointer, so a view can't keep its backing
    /// object GC-alive (unlike a slice, whose header names the buffer base).
    string_slice,
    /// `(string) -> []u8`: `[]byte(s)` (SPEC §12.9) — a fresh `[]u8` with byte
    /// `i` of `s` in element word `i` (slices are word-stored, ABI.md §2).
    bytes_from_string,
    /// `([]u8) -> string`: `string(b)` (SPEC §12.9) — narrows each element word
    /// to its low byte into a fresh string.
    string_from_bytes,
    /// `(f64) -> f64`: square root (hardware `sqrtsd`/`fsqrt`), backs std/math.
    sqrt,
    panic,
    assert,
    /// One `string` arg: writes its bytes to stdout (no trailing newline).
    /// Backs the `print` builtin (SPEC.md); `println` adds the newline in
    /// lowering. v1 takes the string heap-object `{ptr,len}` view directly.
    print,
    /// Fallible-result error channel (SPEC §18, ABI.md §13). `err_set(e)`
    /// stores the pending error (`fail`/`?`-propagate); a nil arg clears it
    /// (ok return / handled `catch`). `err_get() -> error` reads it right
    /// after a fallible call — non-null means the callee failed.
    err_set,
    err_get,
    chan_make,
    chan_send,
    chan_recv,
    chan_close,
    spawn,
    /// Hash map primitives (ABI.md §15), backing `map<K,V>` (§11.2, §13.5).
    /// `map_new(key_is_string, val_is_ref) -> map` — the two flags are compile
    /// constants from K/V. `map_set(m, key, val)`; `map_get(m, key) -> val` (zero
    /// word if absent); `map_has(m, key) -> bool`; `map_delete(m, key)`;
    /// `map_len(m) -> i64`. Iteration is by slot index: `map_iter_init(m) -> i64`
    /// (first live slot or -1), `map_iter_next(m, prev) -> i64`, then
    /// `map_key_at(m, slot)`/`map_val_at(m, slot)` read the pair.
    map_new,
    map_set,
    map_get,
    map_has,
    map_delete,
    map_len,
    map_iter_init,
    map_iter_next,
    map_key_at,
    map_val_at,
    /// `select_alloc(n) -> *desc[n]` reserves a zeroed case-descriptor buffer;
    /// codegen fills `dir`/`chan`/`word` per case, then `select(descs, n,
    /// has_default) -> fired index` (or `n` for the default clause), leaving a
    /// recv case's value in its descriptor `word` (ABI.md §11).
    select_alloc,
    select,
    /// Dynamic `[]T` (ABI.md §2). `slice_new(len, cap, is_ref) -> slice`;
    /// `slice_append(slice, word) -> slice` (grows, returns the header);
    /// `slice_get(slice, index) -> word` and `slice_set(slice, index, word)`
    /// are bounds-checked (SPEC §18.4). Elements are one word each; `len(s)` on
    /// a slice stays the `slice_len` op (a plain header load, not a call).
    slice_new,
    slice_append,
    slice_get,
    slice_set,
    slice_slice,
    /// Filesystem primitives (ABI.md §14), the low-level layer under std/fs.
    /// `fs_open(path, write) -> i64` fd or -1; `fs_read_all(fd) -> string`;
    /// `fs_write(fd, s) -> i64` bytes or -1; `fs_close(fd) -> i64` (always 0).
    fs_open,
    fs_read_all,
    fs_write,
    fs_close,
    /// The rest of the filesystem surface (ABI.md §14), under `std/fs`:
    /// `fs_append(path) -> fd`; `fs_read(fd, max) -> string` (short at EOF, so
    /// it works on pipes and stdin, unlike `fs_read_all`); `fs_exists`/
    /// `fs_is_dir(path) -> bool`; `fs_mkdir`/`fs_remove(path) -> i64`;
    /// `fs_list_dir(path) -> string` (NUL-terminated entry names).
    fs_append,
    fs_read,
    fs_exists,
    fs_is_dir,
    fs_mkdir,
    fs_remove,
    fs_list_dir,
    /// Non-blocking TCP (ABI.md §20), under `std/net`. Any of these may park the
    /// calling green thread on the netpoller; none blocks an OS thread.
    /// `net_listen(host, port) -> fd`; `net_local_port(fd) -> port` (recovers the
    /// kernel's choice after binding port 0); `net_accept(fd) -> fd`;
    /// `net_dial(host, port) -> fd`; `net_read(fd, max) -> string` (empty at end
    /// of stream); `net_write(fd, s) -> i64`. Failure is `-1`, or `""` for a read.
    /// A socket is closed by `fs_close` — `close(2)` does not care what it gets.
    ///
    /// UDP (connectionless): `net_udp_bind(host, port) -> fd`;
    /// `net_udp_send(fd, host, port, data) -> i64`; `net_udp_recv(fd, max) ->
    /// string` records the sender, read back with `net_udp_sender_host() ->
    /// string` and `net_udp_sender_port() -> i64` (port `-1` after a failed recv).
    net_listen,
    net_local_port,
    net_accept,
    net_dial,
    net_read,
    net_write,
    net_udp_bind,
    net_udp_send,
    net_udp_recv,
    net_udp_sender_host,
    net_udp_sender_port,
    net_resolve,
    /// `() -> i64`: which test this process should run (`BIT_TEST_INDEX`, or -1).
    /// Only ever emitted into the synthetic `main` that `compiler/testgen.zig`
    /// appends under `bit test` (ABI.md §16).
    test_index,
    /// Math primitives under `std/math` (ABI.md §17). All `(f64) -> f64` except
    /// `pow`/`atan2`, which take two. `sin`/`cos`/`tan`/`exp` are absent: Zig
    /// exposes them only as libm-lowering builtins, and Bit links no libc.
    floor,
    ceil,
    round,
    trunc,
    pow,
    atan2,
    log,
    log2,
    log10,
    /// Time primitives under `std/time` (ABI.md §18). `time_sleep_ns` parks the
    /// calling green thread on the scheduler's timer queue — it never blocks the
    /// OS thread.
    time_mono_ns,
    time_unix_ns,
    time_sleep_ns,
    /// OS primitives under `std/os` (ABI.md §19). `os_env` yields the empty
    /// string for an unset variable; `os_exit` does not return.
    os_argc,
    os_arg_at,
    os_env,
    os_exit,
    /// Crypto boundary primitives under `std/crypto` (ABI.md §21): the parts
    /// crypto needs from the runtime but that cannot be pure Bit.
    /// `random_bytes(len) -> string` fills `len` bytes from the OS CSPRNG (fatal
    /// on entropy failure — never weak bytes); `secure_zero(b)` wipes a `[]byte`
    /// with an optimizer-proof barrier, for clearing key material.
    random_bytes,
    secure_zero,
};

/// Every instruction opcode. Grouped by operand shape — see `Decoded` and the
/// `push*` builder methods, which are the authority on each op's `extra`
/// layout (documented per group below).
pub const Op = enum {
    // ---- pseudo: block parameter (phi result), see module doc comment -----
    block_param,

    // ---- constants: extra layout in `pushConst*` -----------------------
    const_int,
    const_float,
    const_bool,
    const_string,
    const_nil,

    // ---- arithmetic (binary: extra = [lhs, rhs]) -------------------------
    add,
    sub,
    mul,
    sdiv,
    udiv,
    srem,
    urem,
    fadd,
    fsub,
    fmul,
    fdiv,
    band,
    bor,
    bxor,
    shl,
    ashr,
    lshr,
    // unary: extra = [operand]
    neg,
    fneg,
    bnot,

    // ---- numeric conversion (unary shape: extra = [src]) -----------------
    // `T(x)` (SPEC §12.9): the result type is the target prim, the operand's
    // recorded type is the source; codegen picks trunc/extend (int↔int),
    // cvt-to/from-float (int↔float), or f32↔f64 from those two widths/classes.
    convert,

    // ---- compare (binary: extra = [lhs, rhs]; result type is always bool) -
    icmp_eq,
    icmp_ne,
    icmp_slt,
    icmp_sle,
    icmp_sgt,
    icmp_sge,
    icmp_ult,
    icmp_ule,
    icmp_ugt,
    icmp_uge,
    fcmp_eq,
    fcmp_ne,
    fcmp_lt,
    fcmp_le,
    fcmp_gt,
    fcmp_ge,

    // ---- control (terminators — exactly one, last, per block) -----------
    jump,
    br,
    ret,
    unreachable_,

    // ---- calls ------------------------------------------------------------
    call, // direct: extra = [FuncId, argc, args...]
    // closure/fn-value: extra = [callee, argc, args...]. `callee` is one
    // opaque `.func`-typed value (a `make_closure` result, or any other
    // closure-shaped value flowing through — e.g. a struct field of func
    // type); `args` are exactly the source-level call arguments, nothing
    // more. Unpacking `callee` into its code pointer and env pointer, and
    // threading the env pointer into the physical call as the callee
    // function's own leading parameter, is entirely codegen's job — lowering
    // never needs to (and cannot, since the value is opaque) split it apart.
    call_value,
    call_iface, // dynamic dispatch: extra = [iface_value, method_index, argc, args...]

    // ---- GC / memory (see runtime/ABI.md §1-3) ----------------------------
    gc_alloc, // extra = [size, offc, ptr_offsets...]
    field_get, // extra = [base, offset]
    field_set, // extra = [base, offset, value]  (codegen inserts the write barrier here later)
    index_get, // extra = [base, index]
    index_set, // extra = [base, index, value]
    slice_len, // extra = [base]

    // ---- closures: extra = [FuncId, env] ----------------------------------
    make_closure,

    // ---- raw function address: extra = [FuncId] ---------------------------
    // Materializes a function's code address as a plain pointer value (no env
    // cell, unlike `make_closure`). Codegen emits an absolute relocation to the
    // function's own symbol. Used to hand `bit_rt_spawn` its trampoline (§9).
    func_addr,

    // ---- opaque runtime call: extra = [RtFn, argc, args...] --------------
    rt_call,

    /// Terminators must be the last (and only trailing) instruction of a
    /// block — see `verifyFunction`.
    pub fn isTerminator(self: Op) bool {
        return switch (self) {
            .jump, .br, .ret, .unreachable_ => true,
            else => false,
        };
    }

    pub fn isBinary(self: Op) bool {
        return switch (self) {
            .add, .sub, .mul, .sdiv, .udiv, .srem, .urem, .fadd, .fsub, .fmul, .fdiv, .band, .bor, .bxor, .shl, .ashr, .lshr, .icmp_eq, .icmp_ne, .icmp_slt, .icmp_sle, .icmp_sgt, .icmp_sge, .icmp_ult, .icmp_ule, .icmp_ugt, .icmp_uge, .fcmp_eq, .fcmp_ne, .fcmp_lt, .fcmp_le, .fcmp_gt, .fcmp_ge => true,
            else => false,
        };
    }

    pub fn isCompare(self: Op) bool {
        return switch (self) {
            .icmp_eq, .icmp_ne, .icmp_slt, .icmp_sle, .icmp_sgt, .icmp_sge, .icmp_ult, .icmp_ule, .icmp_ugt, .icmp_uge, .fcmp_eq, .fcmp_ne, .fcmp_lt, .fcmp_le, .fcmp_gt, .fcmp_ge => true,
            else => false,
        };
    }

    pub fn isUnary(self: Op) bool {
        return switch (self) {
            .neg, .fneg, .bnot => true,
            else => false,
        };
    }
};

/// One instruction row. `ty` is the result type (meaningless — left as
/// `.invalid` — for ops with no result, i.e. terminators and `field_set`/
/// `index_set`). `block` names the owning block for verifier convenience
/// (redundant with `BasicBlock.insts_start/len` ranges, but O(1) instead of a
/// range search — cheap to keep in sync since it's only ever written once,
/// at emission). `operands_start`/`operands_len` index into `Function.extra`.
pub const Inst = struct {
    op: Op,
    ty: TypeId,
    block: BlockId,
    operands_start: u32,
    operands_len: u32,
};

/// A block's instructions are `insts[insts_start..insts_start+insts_len]`,
/// always laid out contiguously in emission order (the builder never
/// interleaves two open blocks). Its first `param_count` instructions are
/// `Op.block_param` — the block's phi results (see module doc comment).
pub const BasicBlock = struct {
    insts_start: u32,
    insts_len: u32,
    param_count: u32,

    pub fn paramValue(self: BasicBlock, i: u32) ValueId {
        std.debug.assert(i < self.param_count);
        return @enumFromInt(self.insts_start + i);
    }
};

pub const Function = struct {
    name: []const u8,
    /// Declared parameter types, in order — the entry block's first
    /// `params.len` instructions are exactly these params' `block_param`s.
    param_types: []const TypeId,
    result: TypeId,
    is_fallible: bool,
    err_ty: TypeId,
    blocks: []const BasicBlock,
    entry: BlockId,
    insts: std.MultiArrayList(Inst),
    extra: []const u32,

    pub fn deinit(self: *Function, gpa: Allocator) void {
        gpa.free(self.name);
        gpa.free(self.param_types);
        gpa.free(self.blocks);
        self.insts.deinit(gpa);
        gpa.free(self.extra);
        self.* = undefined;
    }

    pub fn valueType(self: *const Function, v: ValueId) TypeId {
        return self.insts.items(.ty)[@intFromEnum(v)];
    }

    pub fn block(self: *const Function, id: BlockId) BasicBlock {
        return self.blocks[@intFromEnum(id)];
    }

    fn extraSlice(self: *const Function, start: u32, len: u32) []const u32 {
        return self.extra[start .. start + len];
    }

    /// Decodes instruction `idx`'s operands into a typed view. Sub-slices
    /// borrow `Function.extra` directly (no allocation) — the shared
    /// authority `dump`/`verifyFunction` both use instead of duplicating
    /// per-op layout knowledge.
    pub fn decode(self: *const Function, idx: ValueId) Decoded {
        const i: u32 = @intFromEnum(idx);
        const op = self.insts.items(.op)[i];
        const raw = self.extraSlice(self.insts.items(.operands_start)[i], self.insts.items(.operands_len)[i]);
        return switch (op) {
            .block_param => .block_param,
            .const_int => .{ .const_int = @bitCast((@as(u64, raw[1]) << 32) | raw[0]) },
            .const_float => .{ .const_float = @bitCast((@as(u64, raw[1]) << 32) | raw[0]) },
            .const_bool => .{ .const_bool = raw[0] != 0 },
            .const_string => .{ .const_string = raw[0] },
            .const_nil => .const_nil,
            .jump => blk: {
                const argc = raw[1];
                break :blk .{ .jump = .{ .target = @enumFromInt(raw[0]), .args = raw[2 .. 2 + argc] } };
            },
            .br => blk: {
                const then_argc = raw[2];
                const then_end = 3 + then_argc;
                const else_argc = raw[then_end + 1];
                break :blk .{ .br = .{
                    .cond = @enumFromInt(raw[0]),
                    .then_blk = @enumFromInt(raw[1]),
                    .then_args = raw[3..then_end],
                    .else_blk = @enumFromInt(raw[then_end]),
                    .else_args = raw[then_end + 2 .. then_end + 2 + else_argc],
                } };
            },
            .ret => .{ .ret = .{ .vals = raw[1 .. 1 + raw[0]] } },
            .unreachable_ => .unreachable_,
            .call => .{ .call = .{ .func = @enumFromInt(raw[0]), .args = raw[2 .. 2 + raw[1]] } },
            .call_value => .{ .call_value = .{ .callee = @enumFromInt(raw[0]), .args = raw[2 .. 2 + raw[1]] } },
            .call_iface => .{ .call_iface = .{ .iface = @enumFromInt(raw[0]), .method_index = raw[1], .args = raw[3 .. 3 + raw[2]] } },
            .gc_alloc => .{ .gc_alloc = .{ .size = raw[0], .ptr_offsets = raw[2 .. 2 + raw[1]] } },
            .field_get => .{ .field_get = .{ .base = @enumFromInt(raw[0]), .offset = raw[1] } },
            .field_set => .{ .field_set = .{ .base = @enumFromInt(raw[0]), .offset = raw[1], .value = @enumFromInt(raw[2]) } },
            .index_get => .{ .index_get = .{ .base = @enumFromInt(raw[0]), .index = @enumFromInt(raw[1]) } },
            .index_set => .{ .index_set = .{ .base = @enumFromInt(raw[0]), .index = @enumFromInt(raw[1]), .value = @enumFromInt(raw[2]) } },
            .slice_len => .{ .slice_len = .{ .base = @enumFromInt(raw[0]) } },
            .convert => .{ .un = .{ .operand = @enumFromInt(raw[0]) } },
            .make_closure => .{ .make_closure = .{ .func = @enumFromInt(raw[0]), .env = @enumFromInt(raw[1]) } },
            .func_addr => .{ .func_addr = .{ .func = @enumFromInt(raw[0]) } },
            .rt_call => .{ .rt_call = .{ .rt = @enumFromInt(raw[0]), .args = raw[2 .. 2 + raw[1]] } },
            else => if (op.isBinary())
                .{ .bin = .{ .lhs = @enumFromInt(raw[0]), .rhs = @enumFromInt(raw[1]) } }
            else if (op.isUnary())
                .{ .un = .{ .operand = @enumFromInt(raw[0]) } }
            else
                unreachable,
        };
    }
};

/// A decoded instruction's operands, uniform across the whole `Op` space.
/// See `Op`'s per-case doc comments for the raw `extra` layout each variant
/// here decodes.
pub const Decoded = union(enum) {
    block_param,
    const_int: i64,
    const_float: f64,
    const_bool: bool,
    const_string: u32,
    const_nil,
    bin: struct { lhs: ValueId, rhs: ValueId },
    un: struct { operand: ValueId },
    jump: struct { target: BlockId, args: []const u32 },
    br: struct { cond: ValueId, then_blk: BlockId, then_args: []const u32, else_blk: BlockId, else_args: []const u32 },
    ret: struct { vals: []const u32 },
    unreachable_,
    call: struct { func: FuncId, args: []const u32 },
    call_value: struct { callee: ValueId, args: []const u32 },
    call_iface: struct { iface: ValueId, method_index: u32, args: []const u32 },
    gc_alloc: struct { size: u32, ptr_offsets: []const u32 },
    field_get: struct { base: ValueId, offset: u32 },
    field_set: struct { base: ValueId, offset: u32, value: ValueId },
    index_get: struct { base: ValueId, index: ValueId },
    index_set: struct { base: ValueId, index: ValueId, value: ValueId },
    slice_len: struct { base: ValueId },
    make_closure: struct { func: FuncId, env: ValueId },
    func_addr: struct { func: FuncId },
    rt_call: struct { rt: RtFn, args: []const u32 },
};

/// A compiled unit: every lowered function plus the deduped string-literal
/// pool. Struct/interface layout is never duplicated here — it comes
/// straight from `ctx` (the same project-lifetime `check.TypeContext` the
/// checker built), so there is exactly one type system in the compiler.
/// One method of a concrete type, for interface dispatch (ABI.md §2.1).
/// `id` is the global method-name id; `func` is the method's lowered function.
pub const MethodSlot = struct { id: u32, func: FuncId };

/// A concrete type's method table. `type_disc` is the type's discriminator
/// (`@intFromEnum(TypeId)`), matching the discriminator codegen threads into the
/// type's `TypeInfo` symbol so the emitter can attach the table to the right
/// descriptor.
pub const MethodTable = struct { type_disc: u32, methods: []const MethodSlot };

pub const Module = struct {
    gpa: Allocator,
    ctx: *TypeContext,
    funcs: std.ArrayList(Function) = .empty,
    string_pool: std.ArrayList([]const u8) = .empty,
    /// Per-type method tables (ABI.md §2.1), owned by the module. Empty for
    /// programs with no methods.
    method_tables: []const MethodTable = &.{},

    pub fn init(gpa: Allocator, ctx: *TypeContext) Module {
        return .{ .gpa = gpa, .ctx = ctx };
    }

    pub fn deinit(self: *Module) void {
        for (self.funcs.items) |*f| f.deinit(self.gpa);
        self.funcs.deinit(self.gpa);
        for (self.string_pool.items) |str| self.gpa.free(str);
        self.string_pool.deinit(self.gpa);
        for (self.method_tables) |mt| self.gpa.free(mt.methods);
        self.gpa.free(self.method_tables);
        self.* = undefined;
    }

    /// The method table for `type_disc`, or null if the type has no methods.
    pub fn methodTable(self: *const Module, type_disc: u32) ?MethodTable {
        for (self.method_tables) |mt| {
            if (mt.type_disc == type_disc) return mt;
        }
        return null;
    }

    /// Interns `s` into the string pool, deduping by content (bounded linear
    /// scan — a module's distinct string literal count is always small). The
    /// pool owns its copy, so callers keep ownership of `s` (a `.string_lit`
    /// lowers a freshly-unescaped, then-freed buffer through here).
    /// Returns its pool index.
    pub fn internString(self: *Module, s: []const u8) Allocator.Error!u32 {
        for (self.string_pool.items, 0..) |existing, i| {
            if (std.mem.eql(u8, existing, s)) return @intCast(i);
        }
        const idx: u32 = @intCast(self.string_pool.items.len);
        const owned = try self.gpa.dupe(u8, s);
        errdefer self.gpa.free(owned);
        try self.string_pool.append(self.gpa, owned);
        return idx;
    }

    pub fn func(self: *const Module, id: FuncId) *const Function {
        return &self.funcs.items[@intFromEnum(id)];
    }
};

/// Deterministic symbol name for the static `TypeInfo` a `gc_alloc` references.
/// `disc` is the type discriminator (`@intFromEnum(TypeId)` of the allocation's
/// result type): descriptors are now **per type**, not per layout, so a type's
/// method table (ABI.md §2.1) attaches to the right one — two types with the
/// same size/offsets but different methods must not share a `TypeInfo`. Same
/// (disc, size, ptr_offsets) -> same name, so codegen (which references it) and
/// the object emitter (which defines it) agree with no shared index. Caller owns
/// the returned bytes.
pub fn typeInfoSymbol(gpa: Allocator, disc: u32, size: u32, ptr_offsets: []const u32) Allocator.Error![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    var numbuf: [16]u8 = undefined;
    try list.appendSlice(gpa, "__bittype_");
    try list.appendSlice(gpa, std.fmt.bufPrint(&numbuf, "{d}", .{disc}) catch unreachable);
    try list.append(gpa, '_');
    try list.appendSlice(gpa, std.fmt.bufPrint(&numbuf, "{d}", .{size}) catch unreachable);
    for (ptr_offsets) |off| {
        try list.append(gpa, '_');
        try list.appendSlice(gpa, std.fmt.bufPrint(&numbuf, "{d}", .{off}) catch unreachable);
    }
    return list.toOwnedSlice(gpa);
}

// ============================================================================
// Builder
// ============================================================================

/// Incrementally constructs one `Function`. Blocks are reserved up front (so
/// a forward jump target has a stable `BlockId` before it's filled) and
/// finalized one at a time via `beginBlock`/`endBlock` — the builder asserts
/// against interleaving two open blocks, which is what keeps each block's
/// instructions contiguous in `insts` (see `BasicBlock`'s doc comment).
pub const FunctionBuilder = struct {
    gpa: Allocator,
    insts: std.MultiArrayList(Inst) = .{},
    extra: std.ArrayList(u32) = .empty,
    blocks: std.ArrayList(BasicBlock) = .empty,
    cur_block: BlockId = @enumFromInt(0),
    block_open: bool = false,
    block_start_inst: u32 = 0,
    block_param_count: u32 = 0,

    pub fn init(gpa: Allocator) FunctionBuilder {
        return .{ .gpa = gpa };
    }

    /// Frees a builder abandoned before `finish` (e.g. lowering hit an
    /// `error.UnsupportedConstruct` mid-function). `finish` moves these three
    /// allocations into the returned `Function`, so it is never both finished
    /// and deinited — call this only on the error path.
    pub fn deinit(self: *FunctionBuilder, gpa: Allocator) void {
        self.insts.deinit(gpa);
        self.extra.deinit(gpa);
        self.blocks.deinit(gpa);
        self.* = undefined;
    }

    /// Reserves a fresh, empty block and returns its id. Its instruction
    /// range is filled in by a later `beginBlock`/`endBlock` pair.
    pub fn newBlock(self: *FunctionBuilder) Allocator.Error!BlockId {
        const id: BlockId = @enumFromInt(self.blocks.items.len);
        try self.blocks.append(self.gpa, .{ .insts_start = 0, .insts_len = 0, .param_count = 0 });
        return id;
    }

    pub fn beginBlock(self: *FunctionBuilder, id: BlockId) void {
        std.debug.assert(!self.block_open);
        self.cur_block = id;
        self.block_open = true;
        self.block_start_inst = @intCast(self.insts.len);
        self.block_param_count = 0;
    }

    /// Adds a block parameter. Must be called only immediately after
    /// `beginBlock`, before any non-parameter instruction — enforced so a
    /// block's params always occupy its leading instruction slots (see
    /// `BasicBlock.paramValue`).
    pub fn addParam(self: *FunctionBuilder, ty: TypeId) Allocator.Error!ValueId {
        std.debug.assert(self.insts.len - self.block_start_inst == self.block_param_count);
        const id = try self.push(.block_param, ty, &.{});
        self.block_param_count += 1;
        return id;
    }

    /// Closes the current block, recording its final instruction range and
    /// param count. Must be called with the block's terminator already
    /// emitted.
    pub fn endBlock(self: *FunctionBuilder) void {
        std.debug.assert(self.block_open);
        const total: u32 = @intCast(self.insts.len);
        std.debug.assert(total > self.block_start_inst); // at least a terminator
        std.debug.assert(self.insts.items(.op)[total - 1].isTerminator());
        self.blocks.items[@intFromEnum(self.cur_block)] = .{
            .insts_start = self.block_start_inst,
            .insts_len = total - self.block_start_inst,
            .param_count = self.block_param_count,
        };
        self.block_open = false;
    }

    fn push(self: *FunctionBuilder, op: Op, ty: TypeId, extra_vals: []const u32) Allocator.Error!ValueId {
        std.debug.assert(self.block_open);
        const idx: u32 = @intCast(self.insts.len);
        const start: u32 = @intCast(self.extra.items.len);
        try self.extra.appendSlice(self.gpa, extra_vals);
        try self.insts.append(self.gpa, .{ .op = op, .ty = ty, .block = self.cur_block, .operands_start = start, .operands_len = @intCast(extra_vals.len) });
        return @enumFromInt(idx);
    }

    fn vid(v: ValueId) u32 {
        return @intFromEnum(v);
    }

    pub fn constInt(self: *FunctionBuilder, ty: TypeId, val: i64) Allocator.Error!ValueId {
        const bits: u64 = @bitCast(val);
        return self.push(.const_int, ty, &.{ @truncate(bits), @truncate(bits >> 32) });
    }

    pub fn constFloat(self: *FunctionBuilder, ty: TypeId, val: f64) Allocator.Error!ValueId {
        const bits: u64 = @bitCast(val);
        return self.push(.const_float, ty, &.{ @truncate(bits), @truncate(bits >> 32) });
    }

    pub fn constBool(self: *FunctionBuilder, ty: TypeId, val: bool) Allocator.Error!ValueId {
        return self.push(.const_bool, ty, &.{@intFromBool(val)});
    }

    pub fn constString(self: *FunctionBuilder, ty: TypeId, pool_idx: u32) Allocator.Error!ValueId {
        return self.push(.const_string, ty, &.{pool_idx});
    }

    pub fn constNil(self: *FunctionBuilder, ty: TypeId) Allocator.Error!ValueId {
        return self.push(.const_nil, ty, &.{});
    }

    pub fn binary(self: *FunctionBuilder, op: Op, ty: TypeId, lhs: ValueId, rhs: ValueId) Allocator.Error!ValueId {
        std.debug.assert(op.isBinary());
        return self.push(op, ty, &.{ vid(lhs), vid(rhs) });
    }

    pub fn unary(self: *FunctionBuilder, op: Op, ty: TypeId, operand: ValueId) Allocator.Error!ValueId {
        std.debug.assert(op.isUnary());
        return self.push(op, ty, &.{vid(operand)});
    }

    /// Numeric conversion `T(x)` (§12.9): result type `ty` is the target prim,
    /// `src`'s recorded type the source; codegen derives the cast from both.
    pub fn convert(self: *FunctionBuilder, ty: TypeId, src: ValueId) Allocator.Error!ValueId {
        return self.push(.convert, ty, &.{vid(src)});
    }

    /// Terminator: unconditional jump to `target`, passing `args` matching
    /// its declared param types.
    pub fn jump(self: *FunctionBuilder, target: BlockId, args: []const ValueId) Allocator.Error!void {
        var buf = try self.gpa.alloc(u32, 2 + args.len);
        defer self.gpa.free(buf);
        buf[0] = @intFromEnum(target);
        buf[1] = @intCast(args.len);
        for (args, 0..) |a, i| buf[2 + i] = vid(a);
        _ = try self.push(.jump, .invalid, buf);
    }

    /// Terminator: branch on `cond` to `then_blk`(`then_args`) or
    /// `else_blk`(`else_args`).
    pub fn br(self: *FunctionBuilder, cond: ValueId, then_blk: BlockId, then_args: []const ValueId, else_blk: BlockId, else_args: []const ValueId) Allocator.Error!void {
        // Layout: cond, then_blk, then_argc, then_args..., else_blk, else_argc, else_args...
        var buf = try self.gpa.alloc(u32, 5 + then_args.len + else_args.len);
        defer self.gpa.free(buf);
        buf[0] = vid(cond);
        buf[1] = @intFromEnum(then_blk);
        buf[2] = @intCast(then_args.len);
        var i: usize = 3;
        for (then_args) |a| {
            buf[i] = vid(a);
            i += 1;
        }
        buf[i] = @intFromEnum(else_blk);
        buf[i + 1] = @intCast(else_args.len);
        i += 2;
        for (else_args) |a| {
            buf[i] = vid(a);
            i += 1;
        }
        _ = try self.push(.br, .invalid, buf);
    }

    /// Terminator: return `vals` (zero for `void`, one for a plain result;
    /// codegen decides ABI packing for a multi-value tuple return).
    pub fn ret(self: *FunctionBuilder, vals: []const ValueId) Allocator.Error!void {
        var buf = try self.gpa.alloc(u32, 1 + vals.len);
        defer self.gpa.free(buf);
        buf[0] = @intCast(vals.len);
        for (vals, 0..) |v, i| buf[1 + i] = vid(v);
        _ = try self.push(.ret, .invalid, buf);
    }

    /// Terminator: this point never executes (panic paths, `fail`
    /// unwinding out of scope for lowering — see the module doc comment on
    /// `defer`).
    pub fn unreachableInst(self: *FunctionBuilder) Allocator.Error!void {
        _ = try self.push(.unreachable_, .invalid, &.{});
    }

    pub fn call(self: *FunctionBuilder, ty: TypeId, target: FuncId, args: []const ValueId) Allocator.Error!ValueId {
        var buf = try self.gpa.alloc(u32, 2 + args.len);
        defer self.gpa.free(buf);
        buf[0] = @intFromEnum(target);
        buf[1] = @intCast(args.len);
        for (args, 0..) |a, i| buf[2 + i] = vid(a);
        return self.push(.call, ty, buf);
    }

    pub fn callValue(self: *FunctionBuilder, ty: TypeId, callee: ValueId, args: []const ValueId) Allocator.Error!ValueId {
        var buf = try self.gpa.alloc(u32, 2 + args.len);
        defer self.gpa.free(buf);
        buf[0] = vid(callee);
        buf[1] = @intCast(args.len);
        for (args, 0..) |a, i| buf[2 + i] = vid(a);
        return self.push(.call_value, ty, buf);
    }

    pub fn callIface(self: *FunctionBuilder, ty: TypeId, iface_value: ValueId, method_index: u32, args: []const ValueId) Allocator.Error!ValueId {
        var buf = try self.gpa.alloc(u32, 3 + args.len);
        defer self.gpa.free(buf);
        buf[0] = vid(iface_value);
        buf[1] = method_index;
        buf[2] = @intCast(args.len);
        for (args, 0..) |a, i| buf[3 + i] = vid(a);
        return self.push(.call_iface, ty, buf);
    }

    /// Allocates a zeroed `size`-byte GC body whose reference-typed fields
    /// live at `ptr_offsets` (mirrors `runtime/ABI.md` §2's `TypeInfo`;
    /// codegen materializes the actual static `TypeInfo` later).
    pub fn gcAlloc(self: *FunctionBuilder, ty: TypeId, size: u32, ptr_offsets: []const u32) Allocator.Error!ValueId {
        var buf = try self.gpa.alloc(u32, 2 + ptr_offsets.len);
        defer self.gpa.free(buf);
        buf[0] = size;
        buf[1] = @intCast(ptr_offsets.len);
        @memcpy(buf[2..], ptr_offsets);
        return self.push(.gc_alloc, ty, buf);
    }

    pub fn fieldGet(self: *FunctionBuilder, ty: TypeId, base: ValueId, offset: u32) Allocator.Error!ValueId {
        return self.push(.field_get, ty, &.{ vid(base), offset });
    }

    /// Marks a mutation point precisely — one `field_set` per store, never
    /// batched, so codegen can insert the GC write barrier exactly here.
    pub fn fieldSet(self: *FunctionBuilder, base: ValueId, offset: u32, value: ValueId) Allocator.Error!void {
        _ = try self.push(.field_set, .invalid, &.{ vid(base), offset, vid(value) });
    }

    pub fn indexGet(self: *FunctionBuilder, ty: TypeId, base: ValueId, index: ValueId) Allocator.Error!ValueId {
        return self.push(.index_get, ty, &.{ vid(base), vid(index) });
    }

    pub fn indexSet(self: *FunctionBuilder, base: ValueId, index: ValueId, value: ValueId) Allocator.Error!void {
        _ = try self.push(.index_set, .invalid, &.{ vid(base), vid(index), vid(value) });
    }

    pub fn sliceLen(self: *FunctionBuilder, ty: TypeId, base: ValueId) Allocator.Error!ValueId {
        return self.push(.slice_len, ty, &.{vid(base)});
    }

    /// Builds a closure value `(fn_ptr, env_ref)` — see the module doc
    /// comment in `lower.zig` on closure representation. `ty` is the
    /// 2-element `(func_type, env_type)` tuple `TypeId` `call_value` expects
    /// to consume.
    pub fn makeClosure(self: *FunctionBuilder, ty: TypeId, target: FuncId, env: ValueId) Allocator.Error!ValueId {
        return self.push(.make_closure, ty, &.{ @intFromEnum(target), vid(env) });
    }

    /// Materializes `target`'s raw code address as a pointer value (no env
    /// cell) — the trampoline pointer handed to `bit_rt_spawn` (§9).
    pub fn funcAddr(self: *FunctionBuilder, ty: TypeId, target: FuncId) Allocator.Error!ValueId {
        return self.push(.func_addr, ty, &.{@intFromEnum(target)});
    }

    pub fn rtCall(self: *FunctionBuilder, ty: TypeId, rt: RtFn, args: []const ValueId) Allocator.Error!ValueId {
        var buf = try self.gpa.alloc(u32, 2 + args.len);
        defer self.gpa.free(buf);
        buf[0] = @intFromEnum(rt);
        buf[1] = @intCast(args.len);
        for (args, 0..) |a, i| buf[2 + i] = vid(a);
        return self.push(.rt_call, ty, buf);
    }

    /// Finalizes the function. Every reserved block must have been
    /// begun+ended exactly once (asserted via each block's `insts_len > 0`,
    /// since `endBlock` always emits at least a terminator).
    pub fn finish(self: *FunctionBuilder, name: []const u8, param_types: []const TypeId, result: TypeId, is_fallible: bool, err_ty: TypeId, entry: BlockId) Allocator.Error!Function {
        std.debug.assert(!self.block_open);
        for (self.blocks.items) |b| std.debug.assert(b.insts_len > 0);
        const f = Function{
            // Owned: callers pass borrowed slices (source-backed symbol names,
            // freshly-allocated instantiation names freed right after). Dupe so
            // a Function's name always outlives its caller's buffer.
            .name = try self.gpa.dupe(u8, name),
            .param_types = try self.gpa.dupe(TypeId, param_types),
            .result = result,
            .is_fallible = is_fallible,
            .err_ty = err_ty,
            .blocks = try self.blocks.toOwnedSlice(self.gpa),
            .entry = entry,
            .insts = self.insts,
            .extra = try self.extra.toOwnedSlice(self.gpa),
        };
        // Ownership of every allocation has moved into `f`; empty the builder
        // so a defensive `deinit` (the caller's error path) is a safe no-op.
        self.insts = .{};
        return f;
    }
};

// ============================================================================
// Type-name rendering (dump helper)
// ============================================================================

/// Bounded recursion depth for composite type printing — mirrors
/// `check.zig`'s `max_type_depth`; real programs never approach it, and
/// struct/interface types print their display name rather than expanding
/// fields, so this only bounds slice/array/map/tuple/func nesting, which is
/// always finite (Power of 10: bounded).
const max_type_print_depth = 64;

fn writeTypeName(w: *Writer, ctx: *const TypeContext, ty: TypeId, depth: u32) !void {
    if (depth >= max_type_print_depth) {
        try w.writeAll("<...>");
        return;
    }
    switch (ctx.typeOf(ty)) {
        .invalid => try w.writeAll("<invalid>"),
        .void => try w.writeAll("void"),
        .prim => |p| try w.writeAll(@tagName(p)),
        .slice => |e| {
            try w.writeAll("[]");
            try writeTypeName(w, ctx, e, depth + 1);
        },
        .array => |a| {
            try w.print("[{d}]", .{a.len});
            try writeTypeName(w, ctx, a.elem, depth + 1);
        },
        .map => |m| {
            try w.writeAll("map<");
            try writeTypeName(w, ctx, m.key, depth + 1);
            try w.writeAll(", ");
            try writeTypeName(w, ctx, m.val, depth + 1);
            try w.writeAll(">");
        },
        .tuple => |ts| {
            try w.writeAll("(");
            for (ts, 0..) |t, i| {
                if (i > 0) try w.writeAll(", ");
                try writeTypeName(w, ctx, t, depth + 1);
            }
            try w.writeAll(")");
        },
        .func => |f| {
            try w.writeAll("fn(");
            for (f.params, 0..) |p, i| {
                if (i > 0) try w.writeAll(", ");
                try writeTypeName(w, ctx, p, depth + 1);
            }
            try w.writeAll(") ");
            try writeTypeName(w, ctx, f.result, depth + 1);
        },
        .chan => |e| {
            try w.writeAll("chan<");
            try writeTypeName(w, ctx, e, depth + 1);
            try w.writeAll(">");
        },
        .@"struct", .interface, .@"enum" => {
            const name = ctx.display_names.get(@intFromEnum(ty)) orelse "<anon>";
            try w.writeAll(name);
        },
        .type_param => |g| {
            _ = g;
            try w.writeAll("<T>");
        },
        .fallible => |f| {
            try writeTypeName(w, ctx, f.ok, depth + 1);
            try w.writeAll("!");
            try writeTypeName(w, ctx, f.err, depth + 1);
        },
        .untyped_int, .untyped_float, .untyped_rune, .untyped_bool, .untyped_string, .untyped_nil => try w.writeAll("<untyped>"),
    }
}

// ============================================================================
// Textual dump (golden-test target)
// ============================================================================

fn opName(op: Op) []const u8 {
    return @tagName(op);
}

fn dumpFunction(w: *Writer, module: *const Module, f: *const Function) !void {
    try w.print("func {s}(", .{f.name});
    for (f.param_types, 0..) |pt, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("%{d}: ", .{i});
        try writeTypeName(w, module.ctx, pt, 0);
    }
    try w.writeAll(") ");
    try writeTypeName(w, module.ctx, f.result, 0);
    try w.writeAll(" {\n");

    for (f.blocks, 0..) |b, bi| {
        try w.print("bb{d}(", .{bi});
        var p: u32 = 0;
        while (p < b.param_count) : (p += 1) {
            if (p > 0) try w.writeAll(", ");
            const v = b.paramValue(p);
            try w.print("%{d}: ", .{@intFromEnum(v)});
            try writeTypeName(w, module.ctx, f.valueType(v), 0);
        }
        try w.writeAll("):\n");

        var i = b.insts_start + b.param_count;
        const end = b.insts_start + b.insts_len;
        while (i < end) : (i += 1) {
            try dumpInst(w, module, f, @enumFromInt(i));
        }
    }
    try w.writeAll("}\n");
}

fn dumpValList(w: *Writer, vals: []const u32) !void {
    for (vals, 0..) |v, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("%{d}", .{v});
    }
}

fn dumpInst(w: *Writer, module: *const Module, f: *const Function, id: ValueId) !void {
    const i: u32 = @intFromEnum(id);
    const op = f.insts.items(.op)[i];
    const ty = f.insts.items(.ty)[i];
    const d = f.decode(id);
    switch (d) {
        .block_param => unreachable, // never printed as a body line; see dumpFunction
        .const_int => |v| {
            try w.print("  %{d} = const_int ", .{i});
            try writeTypeName(w, module.ctx, ty, 0);
            try w.print(" {d}\n", .{v});
        },
        .const_float => |v| {
            try w.print("  %{d} = const_float ", .{i});
            try writeTypeName(w, module.ctx, ty, 0);
            try w.print(" {d}\n", .{v});
        },
        .const_bool => |v| try w.print("  %{d} = const_bool {}\n", .{ i, v }),
        .const_string => |pool_idx| try w.print("  %{d} = const_string \"{s}\"\n", .{ i, module.string_pool.items[pool_idx] }),
        .const_nil => try w.print("  %{d} = const_nil\n", .{i}),
        .bin => |b| {
            try w.print("  %{d} = {s} ", .{ i, opName(op) });
            try writeTypeName(w, module.ctx, ty, 0);
            try w.print(" %{d}, %{d}\n", .{ @intFromEnum(b.lhs), @intFromEnum(b.rhs) });
        },
        .un => |u| {
            try w.print("  %{d} = {s} ", .{ i, opName(op) });
            try writeTypeName(w, module.ctx, ty, 0);
            try w.print(" %{d}\n", .{@intFromEnum(u.operand)});
        },
        .jump => |j| {
            try w.print("  jump bb{d}(", .{@intFromEnum(j.target)});
            try dumpValList(w, j.args);
            try w.writeAll(")\n");
        },
        .br => |b| {
            try w.print("  br %{d}, bb{d}(", .{ @intFromEnum(b.cond), @intFromEnum(b.then_blk) });
            try dumpValList(w, b.then_args);
            try w.print("), bb{d}(", .{@intFromEnum(b.else_blk)});
            try dumpValList(w, b.else_args);
            try w.writeAll(")\n");
        },
        .ret => |r| {
            try w.writeAll("  ret");
            if (r.vals.len > 0) {
                try w.writeAll(" ");
                try dumpValList(w, r.vals);
            }
            try w.writeAll("\n");
        },
        .unreachable_ => try w.writeAll("  unreachable\n"),
        .call => |c| {
            try w.print("  %{d} = call @{s}(", .{ i, module.func(c.func).name });
            try dumpValList(w, c.args);
            try w.writeAll(") ");
            try writeTypeName(w, module.ctx, ty, 0);
            try w.writeAll("\n");
        },
        .call_value => |c| {
            try w.print("  %{d} = call_value %{d}(", .{ i, @intFromEnum(c.callee) });
            try dumpValList(w, c.args);
            try w.writeAll(") ");
            try writeTypeName(w, module.ctx, ty, 0);
            try w.writeAll("\n");
        },
        .call_iface => |c| {
            try w.print("  %{d} = call_iface %{d}.{d}(", .{ i, @intFromEnum(c.iface), c.method_index });
            try dumpValList(w, c.args);
            try w.writeAll(") ");
            try writeTypeName(w, module.ctx, ty, 0);
            try w.writeAll("\n");
        },
        .gc_alloc => |g| {
            try w.print("  %{d} = gc_alloc size={d} ptrs=[", .{ i, g.size });
            try dumpValList(w, g.ptr_offsets);
            try w.writeAll("] ");
            try writeTypeName(w, module.ctx, ty, 0);
            try w.writeAll("\n");
        },
        .field_get => |fg| {
            try w.print("  %{d} = field_get %{d}[{d}] ", .{ i, @intFromEnum(fg.base), fg.offset });
            try writeTypeName(w, module.ctx, ty, 0);
            try w.writeAll("\n");
        },
        .field_set => |fs| try w.print("  field_set %{d}[{d}] = %{d}\n", .{ @intFromEnum(fs.base), fs.offset, @intFromEnum(fs.value) }),
        .index_get => |ig| {
            try w.print("  %{d} = index_get %{d}[%{d}] ", .{ i, @intFromEnum(ig.base), @intFromEnum(ig.index) });
            try writeTypeName(w, module.ctx, ty, 0);
            try w.writeAll("\n");
        },
        .index_set => |is_| try w.print("  index_set %{d}[%{d}] = %{d}\n", .{ @intFromEnum(is_.base), @intFromEnum(is_.index), @intFromEnum(is_.value) }),
        .slice_len => |sl| try w.print("  %{d} = slice_len %{d}\n", .{ i, @intFromEnum(sl.base) }),
        .make_closure => |mc| try w.print("  %{d} = make_closure @{s}, %{d}\n", .{ i, module.func(mc.func).name, @intFromEnum(mc.env) }),
        .func_addr => |fa| try w.print("  %{d} = func_addr @{s}\n", .{ i, module.func(fa.func).name }),
        .rt_call => |rc| {
            try w.print("  %{d} = rt_call {s}(", .{ i, @tagName(rc.rt) });
            try dumpValList(w, rc.args);
            try w.writeAll(") ");
            try writeTypeName(w, module.ctx, ty, 0);
            try w.writeAll("\n");
        },
    }
}

/// Renders `module` as deterministic text: one function per `func` block,
/// one basic block per `bbN(...)` label, one instruction per line, SSA
/// values as `%N`. The golden-test target for this stage (like `ast.dump`).
pub fn dump(gpa: Allocator, module: *const Module) ![]u8 {
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (module.funcs.items, 0..) |*f, idx| {
        if (idx > 0) try out.writer.writeAll("\n");
        try dumpFunction(&out.writer, module, f);
    }
    return gpa.dupe(u8, out.written());
}

// ============================================================================
// Verifier
// ============================================================================

pub const VerifyError = error{
    MissingTerminator,
    MisplacedTerminator,
    MisplacedBlockParam,
    UndominatedOperand,
    BlockArgMismatch,
    OperandTypeMismatch,
} || Allocator.Error;

/// Dominator sets as a plain `n x n` boolean matrix (`dom[bi][d]` == block
/// `d` dominates block `bi`) rather than a bitset type — simplest possible
/// representation for the small block counts real functions have, and keeps
/// the fixpoint below in ordinary slice operations only.
const DomSets = [][]bool;

/// Bounded worklist cap for the dominance fixpoint (Power of 10): iterates at
/// most `block_count` passes over `block_count` blocks, i.e. `O(n^2)`, which
/// the task brief names explicitly as the acceptable bound for real function
/// sizes — never a recursive/unbounded walk.
fn computeDominators(gpa: Allocator, f: *const Function) Allocator.Error!DomSets {
    const n = f.blocks.len;
    var preds = try gpa.alloc(std.ArrayList(u32), n);
    defer {
        for (preds) |*p| p.deinit(gpa);
        gpa.free(preds);
    }
    for (preds) |*p| p.* = .empty;

    for (f.blocks, 0..) |b, bi| {
        const term_idx = b.insts_start + b.insts_len - 1;
        switch (f.decode(@enumFromInt(term_idx))) {
            .jump => |j| try preds[@intFromEnum(j.target)].append(gpa, @intCast(bi)),
            .br => |br_| {
                try preds[@intFromEnum(br_.then_blk)].append(gpa, @intCast(bi));
                try preds[@intFromEnum(br_.else_blk)].append(gpa, @intCast(bi));
            },
            else => {},
        }
    }

    const dom = try gpa.alloc([]bool, n);
    errdefer {
        for (dom) |row| gpa.free(row);
        gpa.free(dom);
    }
    const entry: u32 = @intFromEnum(f.entry);
    for (dom, 0..) |*row, i| {
        row.* = try gpa.alloc(bool, n);
        @memset(row.*, i != entry); // entry dominated only by itself; everyone else starts "all"
        if (i == entry) row.*[entry] = true;
    }

    var merged = try gpa.alloc(bool, n);
    defer gpa.free(merged);

    var changed = true;
    var pass: usize = 0;
    while (changed and pass <= n) : (pass += 1) {
        changed = false;
        for (0..n) |bi| {
            if (bi == entry) continue;
            if (preds[bi].items.len == 0) continue; // unreachable block: dom set stays "all" (never a valid def-site's block, so this never masks a real violation)
            @memset(merged, true);
            for (preds[bi].items) |p| {
                for (0..n) |d| merged[d] = merged[d] and dom[p][d];
            }
            merged[bi] = true;
            if (!std.mem.eql(bool, merged, dom[bi])) {
                @memcpy(dom[bi], merged);
                changed = true;
            }
        }
    }
    return dom;
}

fn domsDeinit(gpa: Allocator, dom: DomSets) void {
    for (dom) |row| gpa.free(row);
    gpa.free(dom);
}

fn dominatesBlock(dom: DomSets, a: BlockId, b: BlockId) bool {
    return dom[@intFromEnum(b)][@intFromEnum(a)];
}

/// Checks one operand `use` (referenced from block `use_block`, instruction
/// index `use_idx`) is defined by an instruction that dominates it.
fn checkOperandDominance(f: *const Function, dom: DomSets, use_block: BlockId, use_idx: u32, operand: u32) VerifyError!void {
    if (operand >= f.insts.len) return error.UndominatedOperand;
    const def_block = f.insts.items(.block)[operand];
    if (def_block == use_block) {
        if (operand >= use_idx) return error.UndominatedOperand;
        return;
    }
    if (!dominatesBlock(dom, def_block, use_block)) return error.UndominatedOperand;
}

fn checkAllOperands(f: *const Function, dom: DomSets, use_block: BlockId, use_idx: u32, d: Decoded) VerifyError!void {
    switch (d) {
        .block_param, .const_int, .const_float, .const_bool, .const_string, .const_nil, .unreachable_ => {},
        .bin => |b| {
            try checkOperandDominance(f, dom, use_block, use_idx, @intFromEnum(b.lhs));
            try checkOperandDominance(f, dom, use_block, use_idx, @intFromEnum(b.rhs));
        },
        .un => |u| try checkOperandDominance(f, dom, use_block, use_idx, @intFromEnum(u.operand)),
        .jump => |j| for (j.args) |a| try checkOperandDominance(f, dom, use_block, use_idx, a),
        .br => |b| {
            try checkOperandDominance(f, dom, use_block, use_idx, @intFromEnum(b.cond));
            for (b.then_args) |a| try checkOperandDominance(f, dom, use_block, use_idx, a);
            for (b.else_args) |a| try checkOperandDominance(f, dom, use_block, use_idx, a);
        },
        .ret => |r| for (r.vals) |v| try checkOperandDominance(f, dom, use_block, use_idx, v),
        .call => |c| for (c.args) |a| try checkOperandDominance(f, dom, use_block, use_idx, a),
        .call_value => |c| {
            try checkOperandDominance(f, dom, use_block, use_idx, @intFromEnum(c.callee));
            for (c.args) |a| try checkOperandDominance(f, dom, use_block, use_idx, a);
        },
        .call_iface => |c| {
            try checkOperandDominance(f, dom, use_block, use_idx, @intFromEnum(c.iface));
            for (c.args) |a| try checkOperandDominance(f, dom, use_block, use_idx, a);
        },
        .gc_alloc => {},
        .field_get => |fg| try checkOperandDominance(f, dom, use_block, use_idx, @intFromEnum(fg.base)),
        .field_set => |fs| {
            try checkOperandDominance(f, dom, use_block, use_idx, @intFromEnum(fs.base));
            try checkOperandDominance(f, dom, use_block, use_idx, @intFromEnum(fs.value));
        },
        .index_get => |ig| {
            try checkOperandDominance(f, dom, use_block, use_idx, @intFromEnum(ig.base));
            try checkOperandDominance(f, dom, use_block, use_idx, @intFromEnum(ig.index));
        },
        .index_set => |is_| {
            try checkOperandDominance(f, dom, use_block, use_idx, @intFromEnum(is_.base));
            try checkOperandDominance(f, dom, use_block, use_idx, @intFromEnum(is_.index));
            try checkOperandDominance(f, dom, use_block, use_idx, @intFromEnum(is_.value));
        },
        .slice_len => |sl| try checkOperandDominance(f, dom, use_block, use_idx, @intFromEnum(sl.base)),
        .make_closure => |mc| try checkOperandDominance(f, dom, use_block, use_idx, @intFromEnum(mc.env)),
        .func_addr => {}, // references a FuncId, no value operands
        .rt_call => |rc| for (rc.args) |a| try checkOperandDominance(f, dom, use_block, use_idx, a),
    }
}

fn checkBlockArgs(f: *const Function, target: BlockId, args: []const u32) VerifyError!void {
    const b = f.block(target);
    if (args.len != b.param_count) return error.BlockArgMismatch;
    var i: u32 = 0;
    while (i < b.param_count) : (i += 1) {
        const want = f.valueType(b.paramValue(i));
        const got = f.valueType(@enumFromInt(args[i]));
        if (want != got) return error.BlockArgMismatch;
    }
}

fn checkOperandTypes(f: *const Function, op: Op, ty: TypeId, d: Decoded) VerifyError!void {
    switch (d) {
        .bin => |b| {
            const lt = f.valueType(b.lhs);
            const rt = f.valueType(b.rhs);
            if (lt != rt) return error.OperandTypeMismatch;
            if (op.isCompare()) return; // result is bool regardless of operand type; caller checks that below
            if (ty != lt) return error.OperandTypeMismatch;
        },
        .un => |u| {
            // `convert` deliberately changes type (its operand is the source,
            // `ty` the target); every other unary op preserves it.
            if (op != .convert and f.valueType(u.operand) != ty) return error.OperandTypeMismatch;
        },
        else => {},
    }
}

/// Verifies one function: exactly one terminator per block (last
/// instruction, nothing after), block params only as a block's leading
/// instructions, every operand's def dominates its use, every `jump`/`br`
/// target's param count/types match the passed args, and binary/unary ops'
/// operand types are internally consistent. See the module doc comment for
/// why this is safe to run unconditionally in tests (bounded dominance
/// fixpoint) even though the lowering pipeline itself only runs it in
/// debug/safe builds.
pub fn verifyFunction(gpa: Allocator, f: *const Function) VerifyError!void {
    for (f.blocks) |b| {
        var i = b.insts_start;
        const end = b.insts_start + b.insts_len;
        var seen_non_param = false;
        while (i < end) : (i += 1) {
            const op = f.insts.items(.op)[i];
            if (op == .block_param) {
                if (seen_non_param) return error.MisplacedBlockParam;
                continue;
            }
            seen_non_param = true;
            if (op.isTerminator() and i != end - 1) return error.MisplacedTerminator;
            if (!op.isTerminator() and i == end - 1) return error.MissingTerminator;
        }
        if (b.insts_len == b.param_count) return error.MissingTerminator; // no terminator at all
    }

    const dom = try computeDominators(gpa, f);
    defer domsDeinit(gpa, dom);

    for (f.blocks, 0..) |b, bi| {
        var i = b.insts_start + b.param_count;
        const end = b.insts_start + b.insts_len;
        while (i < end) : (i += 1) {
            const id: ValueId = @enumFromInt(i);
            const d = f.decode(id);
            try checkAllOperands(f, dom, @enumFromInt(bi), i, d);
            try checkOperandTypes(f, f.insts.items(.op)[i], f.insts.items(.ty)[i], d);
            switch (d) {
                .jump => |j| try checkBlockArgs(f, j.target, j.args),
                .br => |br_| {
                    try checkBlockArgs(f, br_.then_blk, br_.then_args);
                    try checkBlockArgs(f, br_.else_blk, br_.else_args);
                },
                else => {},
            }
        }
    }
}

/// Verifies every function in `module`.
pub fn verify(gpa: Allocator, module: *const Module) VerifyError!void {
    for (module.funcs.items) |*f| try verifyFunction(gpa, f);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "verifyFunction accepts a minimal add function" {
    const gpa = testing.allocator;
    var ctx = try TypeContext.init(gpa);
    defer ctx.deinit();
    const i64_ty = ctx.prim_ids.get(.i64);

    var b = FunctionBuilder.init(gpa);
    const entry = try b.newBlock();
    b.beginBlock(entry);
    const p0 = try b.addParam(i64_ty);
    const p1 = try b.addParam(i64_ty);
    const sum = try b.binary(.add, i64_ty, p0, p1);
    try b.ret(&.{sum});
    b.endBlock();

    var f = try b.finish("add", &.{ i64_ty, i64_ty }, i64_ty, false, .invalid, entry);
    defer f.deinit(gpa);

    try verifyFunction(gpa, &f);
}

test "verifyFunction rejects a block with two terminators" {
    const gpa = testing.allocator;
    var ctx = try TypeContext.init(gpa);
    defer ctx.deinit();
    const i64_ty = ctx.prim_ids.get(.i64);

    var b = FunctionBuilder.init(gpa);
    const entry = try b.newBlock();
    b.beginBlock(entry);
    // The public `ret`/`jump`/`br` helpers are normally called once per
    // block; `push` is the raw escape hatch used here to build a
    // deliberately malformed block (two terminators) by hand, exercising
    // the verifier's own diagnostic rather than the builder's asserts —
    // `endBlock` only checks that the *last* instruction is a terminator,
    // which still holds here, so it does not itself catch this.
    _ = try b.push(.ret, .invalid, &.{0});
    _ = try b.push(.ret, .invalid, &.{0});
    b.endBlock();

    var f = try b.finish("bad", &.{}, i64_ty, false, .invalid, entry);
    defer f.deinit(gpa);

    try testing.expectError(error.MisplacedTerminator, verifyFunction(gpa, &f));
}

test "verifyFunction rejects a use that does not dominate its definition" {
    const gpa = testing.allocator;
    var ctx = try TypeContext.init(gpa);
    defer ctx.deinit();
    const i64_ty = ctx.prim_ids.get(.i64);

    var b = FunctionBuilder.init(gpa);
    const entry = try b.newBlock();
    b.beginBlock(entry);
    // Reference value index 5 (doesn't exist yet) from instruction 0 — an
    // out-of-order/undominated use built by hand, not via the builder's
    // normal (always-in-order) emission API.
    _ = try b.push(.add, i64_ty, &.{ 5, 5 });
    _ = try b.push(.ret, .invalid, &.{0});
    b.endBlock();

    var f = try b.finish("bad", &.{}, i64_ty, false, .invalid, entry);
    defer f.deinit(gpa);

    try testing.expectError(error.UndominatedOperand, verifyFunction(gpa, &f));
}

test "dump renders a minimal add function" {
    const gpa = testing.allocator;
    var ctx = try TypeContext.init(gpa);
    defer ctx.deinit();
    const i64_ty = ctx.prim_ids.get(.i64);

    var module = Module.init(gpa, &ctx);
    defer module.deinit();

    var b = FunctionBuilder.init(gpa);
    const entry = try b.newBlock();
    b.beginBlock(entry);
    const p0 = try b.addParam(i64_ty);
    const p1 = try b.addParam(i64_ty);
    const sum = try b.binary(.add, i64_ty, p0, p1);
    try b.ret(&.{sum});
    b.endBlock();
    try module.funcs.append(gpa, try b.finish("add", &.{ i64_ty, i64_ty }, i64_ty, false, .invalid, entry));

    const text = try dump(gpa, &module);
    defer gpa.free(text);
    try testing.expectEqualStrings(
        "func add(%0: i64, %1: i64) i64 {\n" ++
            "bb0(%0: i64, %1: i64):\n" ++
            "  %2 = add i64 %0, %1\n" ++
            "  ret %2\n" ++
            "}\n",
        text,
    );
}
