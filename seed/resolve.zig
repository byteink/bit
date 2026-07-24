//! Symbol resolution (spec/SPEC.md §17): scope tree construction, name binding
//! for every declaration, import resolution across files/modules, and
//! duplicate/undefined/shadowing diagnostics.
//!
//! A **module** is a directory of `.bit` files sharing one flat declaration
//! namespace (§17.1) — value and type names collide in the same namespace,
//! Go-style, so one lookup mechanism serves both value expressions and type
//! expressions. That symmetry is exploited below: `resolveNode` walks both
//! kinds of position with the same recursive default, special-casing only the
//! handful of node shapes that declare a name or open a new scope.
//!
//! Two passes per module, order-independent like Go/TS (§9): `collectTopLevel`
//! registers every top-level declaration and import binding first (so forward
//! references across declarations work), then `resolveBodies` walks function
//! bodies, type expressions, and initializers, binding every identifier node to
//! a `SymbolId` in `node_symbols`. Local (block-scoped) declarations are NOT
//! order-independent: `prescanBlockNames` records what a block will declare so
//! an early reference reports `use_before_init` (like JS's temporal dead zone)
//! instead of a misleading `undefined_name`.
//!
//! Cross-module resolution is deliberately split in two:
//!   * `resolveModule` is the pure core — given already-parsed files and a
//!     precomputed `ImportTable` (import-path-string -> resolution), it never
//!     touches the filesystem. This is what's unit-tested directly.
//!   * `loadProject` is the filesystem shell: it walks directories, parses
//!     `.bit` files, recurses into imported directories (detecting cycles via
//!     the in-flight `loading` set), and calls `resolveModule` per module in
//!     dependency order so every import target is fully resolved before the
//!     module that imports it.

const std = @import("std");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const diagnostics = @import("diagnostics.zig");

const Allocator = std.mem.Allocator;
const Io = std.Io;
const Diagnostics = diagnostics.Diagnostics;
const Code = diagnostics.Code;

/// The `Resolver`'s methods are mutually recursive (`resolveNode` <->
/// `resolveBlockScope` and friends); Zig can't infer an error set across a
/// recursive cycle, so every one of them is annotated with this explicit set.
/// It's exact: every fallible operation inside `Resolver` bottoms out in an
/// allocator call (`ArrayList`/`HashMap` growth, `Diagnostics.report`/`warn`
/// duplicating the message) — never a wider I/O or parse error.
const Error = Allocator.Error;

// ============================================================================
// Symbols
// ============================================================================

/// Symbol handle. `none` (index 0) is the unresolved/absent sentinel, mirroring
/// `ast.none` — index 0 in `Resolver.symbols` is a reserved dummy entry.
pub const SymbolId = enum(u32) { none = 0, _ };

/// Handle to a fully resolved module, indexing `resolveModule`'s `all_modules`
/// slice (the loader keeps every dependency alive for the whole project run).
pub const ModuleId = enum(u32) { _ };

pub const SymbolKind = enum {
    let_binding,
    const_binding,
    param,
    receiver,
    generic_param,
    func,
    type_alias,
    struct_type,
    interface_type,
    enum_type,
    import_namespace,
    import_item,
    builtin_type,
    builtin_func,
    /// Bound in place of a failed import so downstream references to it don't
    /// cascade into a second, misleading `undefined_name` diagnostic.
    poison,
};

pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    /// Declaring node; `ast.none` for universe/poison symbols.
    decl: ast.Index = ast.none,
    /// Index into the `files` slice `decl` belongs to; meaningless if `decl == ast.none`.
    file_idx: u32 = 0,
    exported: bool = false,
    /// True for symbols declared in the module scope itself, as opposed to any
    /// nested block/function scope. Only `insertModuleSymbol` sets it. The
    /// distinction matters for `let_binding`, which is the kind of *both* a
    /// module-level `let` (§11.11, a static cell) and every local `let` (an SSA
    /// value) — nothing else in the symbol table separates the two.
    module_scoped: bool = false,
    /// Set for `.import_item`: the concrete symbol it aliases in another module.
    imported_from: ?struct { module: ModuleId, symbol: SymbolId } = null,
    /// Set for `.import_namespace`: the module it namespaces (null if the
    /// import target itself failed to resolve).
    namespace_module: ?ModuleId = null,
};

/// One parsed file belonging to a module. `source` and `tree` are borrowed —
/// the caller (unit test or `loadProject`) keeps them alive for at least the
/// lifetime of the returned `Module`.
pub const ModuleFile = struct {
    file: diagnostics.FileId,
    source: []const u8,
    tree: *const ast.Tree,
};

/// A single in-memory source substitution: `text` is used for the file at
/// absolute `path` instead of its disk contents. The LSP's dot-completion
/// splices a marker into one open file and reparses via this.
pub const Overlay = struct { path: []const u8, text: []const u8 };

/// In-memory source substitutions for `loadProject`. An editor (the LSP)
/// passes unsaved buffers here so the loaded project reflects live edits
/// instead of stale disk contents; files not named here read from disk as
/// usual. Both members are borrowed and must outlive the load.
pub const SourceOverrides = struct {
    /// Absolute file path -> unsaved buffer text.
    map: ?*const std.StringHashMapUnmanaged([]u8) = null,
    /// A single extra override that wins over `map` and disk.
    one: ?Overlay = null,

    fn lookup(self: SourceOverrides, path: []const u8) ?[]const u8 {
        if (self.one) |o| if (std.mem.eql(u8, o.path, path)) return o.text;
        if (self.map) |m| if (m.get(path)) |t| return t;
        return null;
    }
};

/// Outcome of resolving one `import ... from "path"` string against the
/// module graph. Computed by the caller (`loadProject`, or a test's stub
/// table) *before* calling `resolveModule`, so the pure core never touches
/// the filesystem.
pub const ImportResolution = union(enum) {
    ok: ModuleId,
    cycle,
    not_found,
};

/// Import path string (as written, quotes stripped) -> its resolution. A
/// module's files may repeat the same path; keying by the string itself
/// (rather than by AST node) avoids any ordering coupling with `resolveModule`'s
/// own traversal.
pub const ImportTable = std.StringHashMapUnmanaged(ImportResolution);

/// Result of resolving one module: every symbol it declares or imports, the
/// subset of top-level names it exports, and the identifier -> symbol side
/// table (one slice per input file, same order as the `files` argument).
pub const Module = struct {
    gpa: Allocator,
    symbols: std.ArrayList(Symbol),
    all_names: std.StringHashMapUnmanaged(SymbolId),
    exports: std.StringHashMapUnmanaged(SymbolId),
    node_symbols: [][]SymbolId,

    pub fn deinit(self: *Module) void {
        self.symbols.deinit(self.gpa);
        self.all_names.deinit(self.gpa);
        self.exports.deinit(self.gpa);
        for (self.node_symbols) |ns| self.gpa.free(ns);
        self.gpa.free(self.node_symbols);
        self.* = undefined;
    }
};

// ============================================================================
// Predeclared identifiers (spec §5.3) — the universe scope
// ============================================================================

const predeclared_types = [_][]const u8{
    "i8",    "i16",  "i32",  "i64",
    "u8",    "u16",  "u32",  "u64",
    "f32",   "f64",  "int",  "uint",
    "byte",  "rune", "bool", "string",
    "error",
};
const predeclared_funcs = [_][]const u8{
    "len",            "cap",               "append",           "delete",           "close",            "panic",       "assert",      "print",      "eprint",
    // Low-level filesystem primitives (ABI.md §14); the ergonomic File/open/
    // readFile layer wraps these in std/fs.
    "fsOpen",         "fsReadAll",         "fsWrite",          "fsClose",          "fsAppend",         "fsRead",      "fsExists",    "fsIsDir",    "fsMkdir",
    "fsRemove",       "fsListDir",         "fsChmod",
    // Non-blocking TCP primitives (ABI.md §20); std/net wraps these. Any of them
    // may park the calling green thread on the netpoller. `fsClose` closes a
    // socket too, so there is no `netClose`.
             "netListen",        "netLocalPort",     "netAccept",   "netDial",     "netRead",    "netWrite",
    "netUdpBind",     "netUdpSend",        "netUdpRecv",       "netUdpSenderHost", "netUdpSenderPort", "netResolve",
    // Float primitives (ABI.md §17); std/math re-exports them under plain names.
     "fsqrt",       "ffloor",     "fceil",
    "fround",         "ftrunc",            "fpow",             "fatan2",           "flog",             "flog2",       "flog10",
    // Clock + green-thread sleep (ABI.md §18); std/time wraps these.
         "timeMonoNs", "timeUnixNs",
    "timeSleepNs",
    // Process environment (ABI.md §19); std/os wraps these.
       "osArgc",            "osArgAt",          "osEnv",            "osSelfExe",        "osExit",      "osRun",       "osRunTest",  "hostTarget",
    "auxv",         "osRunBounded",      "osRunTestBounded",
    // Crypto boundary primitives (ABI.md §21); std/crypto wraps these.
              "cryptoRandomBytes", "cryptoSecureZero",
    // Float-literal parsing, for the self-hosted compiler's `FloatLit` lowering.
    "parseFloat",
    // Float bit patterns, for the self-hosted compiler's `const_float` codegen.
          "floatBits",        "float32Bits",
    // The inverse, `bitsToFloat(v: u64) -> f64`, for the transcendental ports.
    "bitsToFloat",
    // Atomics (§11.5) — inline lock-free ops on a raw `*T` (Stage-2 subset).
    "atomicLoad", "atomicStore",
    "atomicCmpxchg",  "atomicAdd",         "atomicSub",        "atomicAnd",        "atomicOr",         "atomicXchg",
    // Raw OS syscall (§11.8) — Linux only, variable arity (nr + up to 6 args).
     "syscall",
    // `ptrOf(s: []T): *T` — address of a slice's element 0, the one bridge from
    // traced memory to a raw `*T` (there is no `&`); lets atomics target a live,
    // GC-kept buffer.
        "ptrOf",
    // `entryOf(f): *byte` (§11.10) — the code entry address of a named
    // function, the one way to name machine code as data. `ptrOf`'s sibling:
    // that one bridges traced memory to a raw pointer, this one bridges a
    // function declaration to one.
         "entryOf",
    // `stackMapsBegin()`/`stackMapsEnd(): *byte` (§11.12) — the half-open extent
    // of the compiler-emitted stack-map table (ABI.md §4). The only spelling for
    // a data symbol the LINKER defines and no object may claim.
    "stackMapsBegin", "stackMapsEnd",
};

// ============================================================================
// Scopes (internal — never exposed past this file)
// ============================================================================

const Scope = struct {
    parent: ?u32,
    names: std.StringHashMapUnmanaged(SymbolId) = .{},
    /// Names this scope will declare later in program order (populated by
    /// `prescanBlockNames`); a reference that resolves here instead of
    /// `names` is a use-before-init, not an undefined name.
    pending: std.StringHashMapUnmanaged(void) = .{},
};

const Severity = enum { err, warn };

// ============================================================================
// Resolver — pass 1 + pass 2 over one module
// ============================================================================

const Resolver = struct {
    gpa: Allocator,
    diags: *Diagnostics,
    files: []const ModuleFile,
    imports: *const ImportTable,
    all_modules: []const Module,
    /// The prelude module whose exports are auto-imported into this module
    /// (`std/core`), or null when there is none / this *is* the prelude.
    prelude: ?ModuleId,

    symbols: std.ArrayList(Symbol) = .empty,
    scopes: std.ArrayList(Scope) = .empty,
    exports: std.StringHashMapUnmanaged(SymbolId) = .{},
    node_symbols: [][]SymbolId = &.{},
    universe: u32 = 0,
    module_scope: u32 = 0,

    fn init(
        gpa: Allocator,
        diags: *Diagnostics,
        files: []const ModuleFile,
        imports: *const ImportTable,
        all_modules: []const Module,
        prelude: ?ModuleId,
    ) Error!Resolver {
        var r = Resolver{ .gpa = gpa, .diags = diags, .files = files, .imports = imports, .all_modules = all_modules, .prelude = prelude };
        // Index 0 is the reserved `.none` sentinel, matching `ast.Tree`.
        try r.symbols.append(gpa, .{ .name = "", .kind = .poison });

        const node_symbols = try gpa.alloc([]SymbolId, files.len);
        var built: usize = 0;
        errdefer {
            for (node_symbols[0..built]) |s| gpa.free(s);
            gpa.free(node_symbols);
        }
        for (files, 0..) |mf, i| {
            const arr = try gpa.alloc(SymbolId, mf.tree.nodes.len);
            @memset(arr, .none);
            node_symbols[i] = arr;
            built += 1;
        }
        r.node_symbols = node_symbols;

        r.universe = try r.pushScope(null);
        for (predeclared_types) |name| try r.injectImplicitSymbol(r.universe, name, .builtin_type);
        for (predeclared_funcs) |name| try r.injectImplicitSymbol(r.universe, name, .builtin_func);
        r.module_scope = try r.pushScope(r.universe);
        return r;
    }

    /// Frees every scope's internal maps. Must run *after* `intoModule` has
    /// moved `module_scope`'s `names` out (reset to `.{}` there), so this
    /// doesn't double-free it.
    fn deinitTemp(self: *Resolver) void {
        for (self.scopes.items) |*sc| {
            sc.names.deinit(self.gpa);
            sc.pending.deinit(self.gpa);
        }
        self.scopes.deinit(self.gpa);
    }

    fn intoModule(self: *Resolver) Module {
        const all_names = self.scope(self.module_scope).names;
        self.scope(self.module_scope).names = .{};
        return .{
            .gpa = self.gpa,
            .symbols = self.symbols,
            .all_names = all_names,
            .exports = self.exports,
            .node_symbols = self.node_symbols,
        };
    }

    // ---- small helpers ------------------------------------------------------

    fn scope(self: *Resolver, id: u32) *Scope {
        return &self.scopes.items[id];
    }

    fn pushScope(self: *Resolver, parent: ?u32) Error!u32 {
        const id: u32 = @intCast(self.scopes.items.len);
        try self.scopes.append(self.gpa, .{ .parent = parent });
        return id;
    }

    fn newSymbol(self: *Resolver, sym: Symbol) Error!SymbolId {
        const id: u32 = @intCast(self.symbols.items.len);
        try self.symbols.append(self.gpa, sym);
        return @enumFromInt(id);
    }

    fn symbolOf(self: *Resolver, id: SymbolId) Symbol {
        return self.symbols.items[@intFromEnum(id)];
    }

    fn setNodeSymbol(self: *Resolver, file_idx: usize, node: ast.Index, id: SymbolId) void {
        self.node_symbols[file_idx][node] = id;
    }

    /// A symbol with no declaring source node (predeclared identifiers, and
    /// the implicit `Self` bound inside interface bodies, §14.3).
    fn injectImplicitSymbol(self: *Resolver, scope_id: u32, name: []const u8, kind: SymbolKind) Error!void {
        const id = try self.newSymbol(.{ .name = name, .kind = kind });
        try self.scope(scope_id).names.put(self.gpa, name, id);
    }

    fn unwrapExport(mf: ModuleFile, idx: ast.Index) ast.Index {
        return if (mf.tree.get(idx).tag == .@"export") mf.tree.kids(idx)[0] else idx;
    }

    /// Auto-imports the prelude module's exports into this module's flat scope
    /// (SPEC §17 — a prelude), as if each were an explicit `import { name } from
    /// "std/core"`. Runs after the module's own top-level declarations, so a
    /// name the user declares (or explicitly imports) shadows the prelude rather
    /// than colliding with it — the injected binding is simply skipped. No-op
    /// when there is no prelude (the prelude module itself, or a std-less build).
    fn injectPrelude(self: *Resolver) Error!void {
        const pid = self.prelude orelse return;
        const pmod = self.all_modules[@intFromEnum(pid)];
        var it = pmod.exports.iterator();
        while (it.next()) |e| {
            const name = e.key_ptr.*;
            if (self.scope(self.module_scope).names.contains(name)) continue; // user name wins
            const id = try self.newSymbol(.{
                .name = name,
                .kind = .import_item,
                .imported_from = .{ .module = pid, .symbol = e.value_ptr.* },
            });
            try self.scope(self.module_scope).names.put(self.gpa, name, id);
        }
    }

    fn emit(
        self: *Resolver,
        severity: Severity,
        mf: ModuleFile,
        node: ast.Index,
        code: Code,
        comptime fmt: []const u8,
        args: anytype,
        hint: ?[]const u8,
    ) Error!void {
        const span = mf.tree.get(node).span;
        var buf: [200]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch fmt;
        switch (severity) {
            .err => try self.diags.report(code, span, msg, hint),
            .warn => try self.diags.warn(code, span, msg, hint),
        }
    }

    fn reportDuplicate(self: *Resolver, mf: ModuleFile, node: ast.Index, name: []const u8) Error!void {
        try self.emit(.err, mf, node, .duplicate_declaration, "'{s}' is already declared in this scope", .{name}, "rename or remove one of the declarations");
    }

    fn checkShadowsPredeclared(self: *Resolver, mf: ModuleFile, node: ast.Index, name: []const u8) Error!void {
        if (self.scope(self.universe).names.contains(name)) {
            try self.emit(.warn, mf, node, .shadows_predeclared, "'{s}' shadows a predeclared identifier", .{name}, "shadowing predeclared names is discouraged");
        }
    }

    /// Declares `name_node` as a symbol in the module's flat scope (top-level
    /// declarations and import bindings). Reports `duplicate_declaration` if
    /// the name already exists there; the blank identifier `_` never binds.
    fn insertModuleSymbol(self: *Resolver, file_idx: usize, name_node: ast.Index, sym: Symbol) Error!SymbolId {
        const mf = self.files[file_idx];
        if (std.mem.eql(u8, sym.name, "_")) {
            self.setNodeSymbol(file_idx, name_node, .none);
            return .none;
        }
        if (self.scope(self.module_scope).names.get(sym.name)) |_| {
            try self.reportDuplicate(mf, name_node, sym.name);
            self.setNodeSymbol(file_idx, name_node, .none);
            return .none;
        }
        var msym = sym;
        msym.module_scoped = true;
        const id = try self.newSymbol(msym);
        try self.scope(self.module_scope).names.put(self.gpa, sym.name, id);
        if (sym.exported) try self.exports.put(self.gpa, sym.name, id);
        try self.checkShadowsPredeclared(mf, name_node, sym.name);
        self.setNodeSymbol(file_idx, name_node, id);
        return id;
    }

    /// Declares a local symbol (param, receiver, generic param, loop/catch
    /// binder, or a block-local `let`/`const` being activated). Reports
    /// `duplicate_declaration` against symbols already active in `scope_id`;
    /// clears any pending (TDZ) entry for the name so later same-scope
    /// references resolve normally.
    fn activateLocal(self: *Resolver, file_idx: usize, name_node: ast.Index, kind: SymbolKind, scope_id: u32) Error!SymbolId {
        const mf = self.files[file_idx];
        const name = identText(mf, name_node);
        if (std.mem.eql(u8, name, "_")) {
            self.setNodeSymbol(file_idx, name_node, .none);
            return .none;
        }
        var sc = self.scope(scope_id);
        if (sc.names.get(name)) |_| {
            try self.reportDuplicate(mf, name_node, name);
            self.setNodeSymbol(file_idx, name_node, .none);
            return .none;
        }
        const id = try self.newSymbol(.{ .name = name, .kind = kind, .decl = name_node, .file_idx = @intCast(file_idx) });
        _ = sc.pending.remove(name);
        try sc.names.put(self.gpa, name, id);
        try self.checkShadowsPredeclared(mf, name_node, name);
        self.setNodeSymbol(file_idx, name_node, id);
        return id;
    }

    /// Resolves an identifier reference: walks `scope_id`'s parent chain,
    /// preferring an already-active binding, falling back to a pending
    /// (not-yet-declared) one to report `use_before_init` instead of a
    /// misleading `undefined_name`. The blank identifier never resolves and
    /// never errors (write-only, §5.1).
    fn resolveIdentRef(self: *Resolver, file_idx: usize, node: ast.Index, scope_id: u32) Error!void {
        const mf = self.files[file_idx];
        const name = identText(mf, node);
        if (std.mem.eql(u8, name, "_")) {
            self.setNodeSymbol(file_idx, node, .none);
            return;
        }
        var cur: ?u32 = scope_id;
        while (cur) |sid| {
            const sc = self.scope(sid);
            if (sc.names.get(name)) |found| {
                self.setNodeSymbol(file_idx, node, found);
                return;
            }
            if (sc.pending.contains(name)) {
                try self.emit(.err, mf, node, .use_before_init, "'{s}' is used before it is declared", .{name}, "move this reference after the declaration");
                self.setNodeSymbol(file_idx, node, .none);
                return;
            }
            cur = sc.parent;
        }
        try self.emit(.err, mf, node, .undefined_name, "undefined name '{s}'", .{name}, null);
        self.setNodeSymbol(file_idx, node, .none);
    }

    // ---- pass 1: collect top-level symbols (order-independent, §9) ---------

    fn collectTopLevel(self: *Resolver) Error!void {
        for (self.files, 0..) |mf, file_idx| {
            for (mf.tree.kids(mf.tree.root)) |decl_idx| {
                if (decl_idx == ast.none) continue;
                try self.collectTopDecl(file_idx, decl_idx, false);
            }
        }
    }

    fn collectTopDecl(self: *Resolver, file_idx: usize, idx: ast.Index, forced_export: bool) Error!void {
        const mf = self.files[file_idx];
        const n = mf.tree.get(idx);
        switch (n.tag) {
            .@"export" => try self.collectTopDecl(file_idx, mf.tree.kids(idx)[0], true),
            .import_decl => try self.collectImport(file_idx, idx),
            .let_decl, .const_decl => {
                const kind: SymbolKind = if (n.tag == .let_decl) .let_binding else .const_binding;
                for (mf.tree.kids(idx)) |binding_idx| {
                    const pat = mf.tree.kids(binding_idx)[0];
                    try self.declarePattern(file_idx, pat, kind, forced_export);
                }
            },
            .type_alias => {
                const name = mf.tree.kids(idx)[0];
                _ = try self.insertModuleSymbol(file_idx, name, .{ .name = identText(mf, name), .kind = .type_alias, .decl = idx, .file_idx = @intCast(file_idx), .exported = forced_export });
            },
            .func_decl => {
                const kids = mf.tree.kids(idx); // [recv, name, generics, params, result, body]
                // Methods (a receiver is present) do not join the flat
                // namespace — different types may each declare a method with
                // the same name (§10.4); they're reached via `recv.name(...)`,
                // never a bare scope lookup.
                if (kids[0] == ast.none) {
                    const name = kids[1];
                    _ = try self.insertModuleSymbol(file_idx, name, .{ .name = identText(mf, name), .kind = .func, .decl = idx, .file_idx = @intCast(file_idx), .exported = forced_export });
                }
            },
            // §11.7: an external symbol binding. It joins the flat namespace as
            // an ordinary callable — only its lowering differs.
            .extern_fn_decl => {
                const name = mf.tree.kids(idx)[0];
                _ = try self.insertModuleSymbol(file_idx, name, .{ .name = identText(mf, name), .kind = .func, .decl = idx, .file_idx = @intCast(file_idx), .exported = forced_export });
            },
            .struct_decl => {
                const name = mf.tree.kids(idx)[0];
                _ = try self.insertModuleSymbol(file_idx, name, .{ .name = identText(mf, name), .kind = .struct_type, .decl = idx, .file_idx = @intCast(file_idx), .exported = forced_export });
            },
            .interface_decl => {
                const name = mf.tree.kids(idx)[0];
                _ = try self.insertModuleSymbol(file_idx, name, .{ .name = identText(mf, name), .kind = .interface_type, .decl = idx, .file_idx = @intCast(file_idx), .exported = forced_export });
            },
            .enum_decl => {
                const name = mf.tree.kids(idx)[0];
                _ = try self.insertModuleSymbol(file_idx, name, .{ .name = identText(mf, name), .kind = .enum_type, .decl = idx, .file_idx = @intCast(file_idx), .exported = forced_export });
            },
            else => {}, // a poisoned decl from parser error recovery
        }
    }

    fn declarePattern(self: *Resolver, file_idx: usize, pat_idx: ast.Index, kind: SymbolKind, exported: bool) Error!void {
        const mf = self.files[file_idx];
        if (mf.tree.get(pat_idx).tag == .tuple_pat) {
            for (mf.tree.kids(pat_idx)) |sub| try self.declarePattern(file_idx, sub, kind, exported);
            return;
        }
        _ = try self.insertModuleSymbol(file_idx, pat_idx, .{ .name = identText(mf, pat_idx), .kind = kind, .decl = pat_idx, .file_idx = @intCast(file_idx), .exported = exported });
    }

    fn collectImport(self: *Resolver, file_idx: usize, idx: ast.Index) Error!void {
        const mf = self.files[file_idx];
        const kids = mf.tree.kids(idx); // [body, path_string]
        const body = kids[0];
        const path_node = kids[1];
        const path_text = stringLitText(mf, path_node);
        const resolution = self.imports.get(path_text) orelse .not_found;
        // A path the parser could not read is `none`, which carries no span. The
        // parser already said "expected a string literal", so a second error here
        // is a cascade — and one that renders against whatever file happens to
        // hold offset 0 (the prelude, in a project build), blaming a file the user
        // never touched. Bind the names as unresolved and stay quiet.
        const target: ?ModuleId = if (path_node == ast.none) null else switch (resolution) {
            .ok => |m| m,
            .cycle => blk: {
                try self.emit(.err, mf, path_node, .import_cycle, "import cycle: module \"{s}\" depends on itself", .{path_text}, null);
                break :blk null;
            },
            .not_found => blk: {
                try self.emit(.err, mf, path_node, .import_not_found, "cannot find module \"{s}\"", .{path_text}, "relative paths must start with './' or '../'; standard-library modules aren't available yet");
                break :blk null;
            },
        };

        const body_n = mf.tree.get(body);
        switch (body_n.tag) {
            .import_ns, .import_star => {
                const name_node = mf.tree.kids(body)[0];
                try self.declareImportNamespace(file_idx, name_node, target);
            },
            .import_group => {
                for (mf.tree.kids(body)) |item_idx| {
                    const item_kids = mf.tree.kids(item_idx); // [name, alias_or_none]
                    const bind_node = if (item_kids[1] != ast.none) item_kids[1] else item_kids[0];
                    try self.declareImportItem(file_idx, item_kids[0], bind_node, target);
                }
            },
            else => {},
        }
    }

    fn declareImportNamespace(self: *Resolver, file_idx: usize, name_node: ast.Index, target: ?ModuleId) Error!void {
        const mf = self.files[file_idx];
        const sym = Symbol{
            .name = identText(mf, name_node),
            .kind = .import_namespace,
            .decl = name_node,
            .file_idx = @intCast(file_idx),
            .namespace_module = target,
        };
        _ = try self.insertModuleSymbol(file_idx, name_node, sym);
    }

    fn declareImportItem(self: *Resolver, file_idx: usize, src_name_node: ast.Index, bind_name_node: ast.Index, target: ?ModuleId) Error!void {
        const mf = self.files[file_idx];
        var sym = Symbol{
            .name = identText(mf, bind_name_node),
            .kind = .poison,
            .decl = bind_name_node,
            .file_idx = @intCast(file_idx),
        };
        if (target) |mod_id| {
            const src_name = identText(mf, src_name_node);
            const dep = self.all_modules[@intFromEnum(mod_id)];
            if (dep.exports.get(src_name)) |target_id| {
                sym.kind = .import_item;
                sym.imported_from = .{ .module = mod_id, .symbol = target_id };
            } else {
                try self.emit(.err, mf, src_name_node, .unexported_name, "'{s}' is not exported by this module", .{src_name}, "add 'export' to its declaration in the source module, or check the spelling");
            }
        }
        _ = try self.insertModuleSymbol(file_idx, bind_name_node, sym);
    }

    // ---- type-definition cycles (§17.1 mirrors the import-cycle check) -----
    //
    // Only `type_alias` substitution and `array_type`/`tuple_type` element
    // types embed a value directly (fixed byte layout at every nesting
    // level); struct/interface names, slices, maps, and chans are reference
    // types (§13.3) — a fixed-size handle regardless of what they point to —
    // so a reference through any of those breaks the cycle and is safe.

    fn checkTypeCycles(self: *Resolver) Error!void {
        if (self.symbols.items.len <= 1) return;
        const visiting = try self.gpa.alloc(bool, self.symbols.items.len);
        defer self.gpa.free(visiting);

        var i: usize = 1;
        while (i < self.symbols.items.len) : (i += 1) {
            const sym = self.symbols.items[i];
            const start: SymbolId = @enumFromInt(i);
            switch (sym.kind) {
                .type_alias => {
                    @memset(visiting, false);
                    const mf = self.files[sym.file_idx];
                    const ty = mf.tree.kids(sym.decl)[2];
                    _ = try self.embedsSelf(start, ty, sym.file_idx, visiting);
                },
                .struct_type => {
                    @memset(visiting, false);
                    const mf = self.files[sym.file_idx];
                    const field_list = mf.tree.kids(sym.decl)[2];
                    for (mf.tree.kids(field_list)) |item| {
                        const field_idx = unwrapExport(mf, item);
                        const field_ty = mf.tree.kids(field_idx)[1];
                        if (try self.embedsSelf(start, field_ty, sym.file_idx, visiting)) break;
                    }
                },
                else => {},
            }
        }
    }

    fn embedsSelf(self: *Resolver, start: SymbolId, node: ast.Index, file_idx: u32, visiting: []bool) Error!bool {
        if (node == ast.none) return false;
        const mf = self.files[file_idx];
        const n = mf.tree.get(node);
        switch (n.tag) {
            .array_type => return self.embedsSelf(start, mf.tree.kids(node)[1], file_idx, visiting),
            .tuple_type => {
                for (mf.tree.kids(node)) |elem| {
                    if (try self.embedsSelf(start, elem, file_idx, visiting)) return true;
                }
                return false;
            },
            .ident, .generic_inst => {
                const name_node = if (n.tag == .generic_inst) mf.tree.kids(node)[0] else node;
                const name = identText(mf, name_node);
                const found = self.scope(self.module_scope).names.get(name) orelse return false;
                if (found == start) {
                    try self.emit(.err, mf, name_node, .type_cycle, "'{s}' cannot embed itself without indirection", .{self.symbolOf(start).name}, "use a slice, map, or a struct/interface reference to break the cycle");
                    return true;
                }
                const target = self.symbolOf(found);
                if (target.kind != .type_alias) return false; // struct/interface/builtin: a safe reference boundary
                const target_idx: usize = @intFromEnum(found);
                if (visiting[target_idx]) return false; // an unrelated cycle; it's reported when that alias is `start`
                visiting[target_idx] = true;
                defer visiting[target_idx] = false;
                const target_mf = self.files[target.file_idx];
                return self.embedsSelf(start, target_mf.tree.kids(target.decl)[2], target.file_idx, visiting);
            },
            else => return false, // slice/map/chan/func_type: also a safe reference boundary
        }
    }

    // ---- pass 2: resolve bodies, type expressions, and initializers --------

    fn resolveBodies(self: *Resolver) Error!void {
        for (self.files, 0..) |mf, file_idx| {
            for (mf.tree.kids(mf.tree.root)) |decl_idx| {
                if (decl_idx == ast.none) continue;
                try self.resolveTopDeclBody(file_idx, unwrapExport(mf, decl_idx));
            }
        }
    }

    fn resolveTopDeclBody(self: *Resolver, file_idx: usize, idx: ast.Index) Error!void {
        const mf = self.files[file_idx];
        switch (mf.tree.get(idx).tag) {
            .let_decl, .const_decl => {
                for (mf.tree.kids(idx)) |binding_idx| {
                    const bk = mf.tree.kids(binding_idx); // [pattern, type_or_none, init_or_none]
                    if (bk[1] != ast.none) try self.resolveNode(file_idx, bk[1], self.module_scope);
                    if (bk[2] != ast.none) try self.resolveNode(file_idx, bk[2], self.module_scope);
                }
            },
            .type_alias => {
                const k = mf.tree.kids(idx); // [name, generics, ty]
                const scope_id = try self.pushGenericsScope(file_idx, k[1], self.module_scope);
                try self.resolveNode(file_idx, k[2], scope_id);
            },
            .func_decl => try self.resolveFuncDecl(file_idx, idx),
            .extern_fn_decl => try self.resolveExternFnDecl(file_idx, idx),
            .struct_decl => try self.resolveStructDecl(file_idx, idx),
            .interface_decl => try self.resolveInterfaceDecl(file_idx, idx),
            .enum_decl => try self.resolveEnumDecl(file_idx, idx),
            else => {},
        }
    }

    fn pushGenericsScope(self: *Resolver, file_idx: usize, generics_idx: ast.Index, parent: u32) Error!u32 {
        if (generics_idx == ast.none) return parent;
        const mf = self.files[file_idx];
        const scope_id = try self.pushScope(parent);
        for (mf.tree.kids(generics_idx)) |gp_idx| {
            const gk = mf.tree.kids(gp_idx); // [name, constraint_or_none]
            _ = try self.activateLocal(file_idx, gk[0], .generic_param, scope_id);
            if (gk[1] != ast.none) try self.resolveNode(file_idx, gk[1], scope_id);
        }
        return scope_id;
    }

    fn resolveFuncDecl(self: *Resolver, file_idx: usize, idx: ast.Index) Error!void {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(idx); // [recv, name, generics, params, result, body]
        const generics_scope = try self.pushGenericsScope(file_idx, k[2], self.module_scope);
        const fn_scope = try self.pushScope(generics_scope);

        if (k[0] != ast.none) {
            const rk = mf.tree.kids(k[0]); // receiver: [name, type_name]
            try self.resolveNode(file_idx, rk[1], fn_scope);
            _ = try self.activateLocal(file_idx, rk[0], .receiver, fn_scope);
        }
        for (mf.tree.kids(k[3])) |p_idx| {
            const pk = mf.tree.kids(p_idx); // param | param_rest: [name, type]
            try self.resolveNode(file_idx, pk[1], fn_scope);
            _ = try self.activateLocal(file_idx, pk[0], .param, fn_scope);
        }
        if (k[4] != ast.none) try self.resolveNode(file_idx, k[4], fn_scope);
        try self.resolveNode(file_idx, k[5], fn_scope);
    }

    /// §11.7: only the signature's type nodes need resolving — there is no body,
    /// and the parameter names are documentation, never referenced.
    fn resolveExternFnDecl(self: *Resolver, file_idx: usize, idx: ast.Index) Error!void {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(idx); // [name, params, result_or_none]
        for (mf.tree.kids(k[1])) |p_idx| {
            try self.resolveNode(file_idx, mf.tree.kids(p_idx)[1], self.module_scope);
        }
        if (k[2] != ast.none) try self.resolveNode(file_idx, k[2], self.module_scope);
    }

    fn resolveStructDecl(self: *Resolver, file_idx: usize, idx: ast.Index) Error!void {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(idx); // [name, generics, field_list]
        const scope_id = try self.pushGenericsScope(file_idx, k[1], self.module_scope);

        var seen: std.StringHashMapUnmanaged(void) = .{};
        defer seen.deinit(self.gpa);
        for (mf.tree.kids(k[2])) |item| {
            const field_idx = unwrapExport(mf, item);
            const fk = mf.tree.kids(field_idx); // [name, type]
            try self.resolveNode(file_idx, fk[1], scope_id);
            const fname = identText(mf, fk[0]);
            if (seen.contains(fname)) {
                try self.reportDuplicate(mf, fk[0], fname);
            } else {
                try seen.put(self.gpa, fname, {});
            }
        }
    }

    /// Resolves a `match`: the subject expression, then each arm's body in its
    /// own scope. A `variant_pat`'s name is NOT a scope lookup — the checker
    /// resolves it against the subject's enum type — so it is skipped here.
    /// The per-arm scope is where Stage 2's payload binders will activate.
    fn resolveMatch(self: *Resolver, file_idx: usize, idx: ast.Index, scope_id: u32) Error!void {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(idx); // [subject, arm_list]
        try self.resolveNode(file_idx, k[0], scope_id);
        for (mf.tree.kids(k[1])) |arm_idx| {
            const ak = mf.tree.kids(arm_idx); // [variant_pat, body]
            const arm_scope = try self.pushScope(scope_id);
            const vk = mf.tree.kids(ak[0]); // variant_pat: [name, binders_or_none]
            if (vk[1] != ast.none) {
                for (mf.tree.kids(vk[1])) |b| _ = try self.activateLocal(file_idx, b, .let_binding, arm_scope);
            }
            try self.resolveNode(file_idx, ak[1], arm_scope);
        }
    }

    fn resolveEnumDecl(self: *Resolver, file_idx: usize, idx: ast.Index) Error!void {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(idx); // [name, generics, variant_list]
        const scope_id = try self.pushGenericsScope(file_idx, k[1], self.module_scope);

        var seen: std.StringHashMapUnmanaged(void) = .{};
        defer seen.deinit(self.gpa);
        for (mf.tree.kids(k[2])) |v_idx| {
            const vk = mf.tree.kids(v_idx); // [name, payload_or_none]
            if (vk[1] != ast.none) {
                for (mf.tree.kids(vk[1])) |ty| try self.resolveNode(file_idx, ty, scope_id);
            }
            const vname = identText(mf, vk[0]);
            if (seen.contains(vname)) {
                try self.reportDuplicate(mf, vk[0], vname);
            } else {
                try seen.put(self.gpa, vname, {});
            }
        }
    }

    fn resolveInterfaceDecl(self: *Resolver, file_idx: usize, idx: ast.Index) Error!void {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(idx); // [name, generics, method_sig_list]
        const generics_scope = try self.pushGenericsScope(file_idx, k[1], self.module_scope);
        const scope_id = try self.pushScope(generics_scope);
        // `Self` (§14.3) stands for whatever type ends up satisfying the
        // interface; it's only meaningful inside method signatures.
        try self.injectImplicitSymbol(scope_id, "Self", .generic_param);

        var seen: std.StringHashMapUnmanaged(void) = .{};
        defer seen.deinit(self.gpa);
        for (mf.tree.kids(k[2])) |sig_idx| {
            const sk = mf.tree.kids(sig_idx); // [name, params, result_or_none]
            const sname = identText(mf, sk[0]);
            if (seen.contains(sname)) {
                try self.reportDuplicate(mf, sk[0], sname);
            } else {
                try seen.put(self.gpa, sname, {});
            }
            for (mf.tree.kids(sk[1])) |p_idx| {
                const pk = mf.tree.kids(p_idx); // [name, type] — no body, so params don't need binding
                try self.resolveNode(file_idx, pk[1], scope_id);
            }
            if (sk[2] != ast.none) try self.resolveNode(file_idx, sk[2], scope_id);
        }
    }

    // ---- blocks: prescan for use-before-init, then resolve sequentially ----

    fn resolveBlockScope(self: *Resolver, file_idx: usize, block_idx: ast.Index, parent: u32) Error!void {
        const mf = self.files[file_idx];
        const stmts = mf.tree.kids(block_idx);
        const scope_id = try self.pushScope(parent);
        try self.prescanBlockNames(file_idx, stmts, scope_id);
        for (stmts) |st| try self.resolveNode(file_idx, st, scope_id);
    }

    fn prescanBlockNames(self: *Resolver, file_idx: usize, stmts: []const ast.Index, scope_id: u32) Error!void {
        const mf = self.files[file_idx];
        for (stmts) |st| {
            if (mf.tree.get(st).tag != .let_decl and mf.tree.get(st).tag != .const_decl) continue;
            for (mf.tree.kids(st)) |binding_idx| {
                try self.prescanPattern(file_idx, mf.tree.kids(binding_idx)[0], scope_id);
            }
        }
    }

    fn prescanPattern(self: *Resolver, file_idx: usize, pat_idx: ast.Index, scope_id: u32) Error!void {
        const mf = self.files[file_idx];
        if (mf.tree.get(pat_idx).tag == .tuple_pat) {
            for (mf.tree.kids(pat_idx)) |sub| try self.prescanPattern(file_idx, sub, scope_id);
            return;
        }
        const name = identText(mf, pat_idx);
        if (std.mem.eql(u8, name, "_")) return;
        try self.scope(scope_id).pending.put(self.gpa, name, {});
    }

    fn activatePattern(self: *Resolver, file_idx: usize, pat_idx: ast.Index, kind: SymbolKind, scope_id: u32) Error!void {
        const mf = self.files[file_idx];
        if (mf.tree.get(pat_idx).tag == .tuple_pat) {
            for (mf.tree.kids(pat_idx)) |sub| try self.activatePattern(file_idx, sub, kind, scope_id);
            return;
        }
        _ = try self.activateLocal(file_idx, pat_idx, kind, scope_id);
    }

    /// Case/clause bodies share the enclosing scope rather than opening their
    /// own (`stmt_list`'s doc comment in ast.zig): a `case`'s own prescan still
    /// runs, so declarations inside one case are visible to a later reference
    /// in the *same* case, and colliding with a sibling case's declaration is
    /// a duplicate in the shared scope, matching that design.
    fn resolveCaseBody(self: *Resolver, file_idx: usize, stmt_list_idx: ast.Index, scope_id: u32) Error!void {
        const mf = self.files[file_idx];
        const stmts = mf.tree.kids(stmt_list_idx);
        try self.prescanBlockNames(file_idx, stmts, scope_id);
        for (stmts) |st| try self.resolveNode(file_idx, st, scope_id);
    }

    fn resolveForC(self: *Resolver, file_idx: usize, idx: ast.Index, scope_id: u32) Error!void {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(idx); // [init_or_none, cond_or_none, post_or_none, body]
        const loop_scope = try self.pushScope(scope_id);
        if (k[0] != ast.none) try self.resolveNode(file_idx, k[0], loop_scope);
        if (k[1] != ast.none) try self.resolveNode(file_idx, k[1], loop_scope);
        if (k[2] != ast.none) try self.resolveNode(file_idx, k[2], loop_scope);
        try self.resolveNode(file_idx, k[3], loop_scope);
    }

    fn resolveForOf(self: *Resolver, file_idx: usize, idx: ast.Index, scope_id: u32) Error!void {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(idx); // [binder, iter_expr, body]
        try self.resolveNode(file_idx, k[1], scope_id); // the iterable can't see the loop variable
        const loop_scope = try self.pushScope(scope_id);
        try self.activatePattern(file_idx, k[0], .let_binding, loop_scope);
        try self.resolveNode(file_idx, k[2], loop_scope);
    }

    fn resolveForIn(self: *Resolver, file_idx: usize, idx: ast.Index, scope_id: u32) Error!void {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(idx); // [name_ident, iter_expr, body]
        try self.resolveNode(file_idx, k[1], scope_id);
        const loop_scope = try self.pushScope(scope_id);
        _ = try self.activateLocal(file_idx, k[0], .let_binding, loop_scope);
        try self.resolveNode(file_idx, k[2], loop_scope);
    }

    fn resolveSwitch(self: *Resolver, file_idx: usize, idx: ast.Index, scope_id: u32) Error!void {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(idx); // [subject_or_none, case_list]
        if (k[0] != ast.none) try self.resolveNode(file_idx, k[0], scope_id);
        for (mf.tree.kids(k[1])) |case_idx| {
            switch (mf.tree.get(case_idx).tag) {
                .switch_case => {
                    const ck = mf.tree.kids(case_idx); // [expr_list, stmt_list]
                    for (mf.tree.kids(ck[0])) |e| try self.resolveNode(file_idx, e, scope_id);
                    try self.resolveCaseBody(file_idx, ck[1], scope_id);
                },
                .switch_default => try self.resolveCaseBody(file_idx, mf.tree.kids(case_idx)[0], scope_id),
                else => {},
            }
        }
    }

    fn resolveSelect(self: *Resolver, file_idx: usize, idx: ast.Index, scope_id: u32) Error!void {
        const mf = self.files[file_idx];
        for (mf.tree.kids(idx)) |clause_idx| {
            switch (mf.tree.get(clause_idx).tag) {
                .comm_case => {
                    const ck = mf.tree.kids(clause_idx); // [comm, stmt_list]
                    const comm_scope = try self.pushScope(scope_id);
                    try self.resolveComm(file_idx, ck[0], comm_scope);
                    try self.resolveCaseBody(file_idx, ck[1], comm_scope);
                },
                .comm_default => try self.resolveCaseBody(file_idx, mf.tree.kids(clause_idx)[0], scope_id),
                else => {},
            }
        }
    }

    fn resolveComm(self: *Resolver, file_idx: usize, idx: ast.Index, scope_id: u32) Error!void {
        const mf = self.files[file_idx];
        switch (mf.tree.get(idx).tag) {
            .send_stmt => {
                const k = mf.tree.kids(idx);
                try self.resolveNode(file_idx, k[0], scope_id);
                try self.resolveNode(file_idx, k[1], scope_id);
            },
            .recv_bind => {
                const k = mf.tree.kids(idx); // [binder_or_none, chan_expr]
                try self.resolveNode(file_idx, k[1], scope_id);
                if (k[0] != ast.none) try self.activatePattern(file_idx, k[0], .let_binding, scope_id);
            },
            else => {},
        }
    }

    /// The unified expression/statement/type walker. Because value and type
    /// names share one flat namespace, a type-shaped node (`generic_inst`,
    /// `array_type`, ...) resolves correctly through the exact same recursion
    /// as an expression: leaves have no kids (a no-op), and the only positions
    /// that must NOT recurse as plain references are struct/composite member
    /// names, handled below. Scope-opening and name-declaring constructs
    /// (`block`, `let_decl`, loops, `switch`/`select`, `catch_bind`,
    /// `arrow_fn`) get their own case; everything else falls through to the
    /// default "resolve every child" recursion.
    fn resolveNode(self: *Resolver, file_idx: usize, idx: ast.Index, scope_id: u32) Error!void {
        if (idx == ast.none) return;
        const mf = self.files[file_idx];
        const n = mf.tree.get(idx);
        switch (n.tag) {
            .ident => try self.resolveIdentRef(file_idx, idx, scope_id),
            // `.name` is a member/field name, resolved later against a type,
            // not a scope lookup — only the receiver/base is a reference.
            .member => try self.resolveNode(file_idx, mf.tree.kids(idx)[0], scope_id),
            .field_init => try self.resolveNode(file_idx, mf.tree.kids(idx)[1], scope_id),

            .block => try self.resolveBlockScope(file_idx, idx, scope_id),
            .let_decl, .const_decl => {
                const kind: SymbolKind = if (n.tag == .let_decl) .let_binding else .const_binding;
                for (mf.tree.kids(idx)) |binding_idx| {
                    const bk = mf.tree.kids(binding_idx); // [pattern, type_or_none, init_or_none]
                    if (bk[1] != ast.none) try self.resolveNode(file_idx, bk[1], scope_id);
                    if (bk[2] != ast.none) try self.resolveNode(file_idx, bk[2], scope_id);
                    try self.activatePattern(file_idx, bk[0], kind, scope_id);
                }
            },
            .for_c => try self.resolveForC(file_idx, idx, scope_id),
            .for_of => try self.resolveForOf(file_idx, idx, scope_id),
            .for_in => try self.resolveForIn(file_idx, idx, scope_id),
            .switch_stmt => try self.resolveSwitch(file_idx, idx, scope_id),
            .match_stmt => try self.resolveMatch(file_idx, idx, scope_id),
            .select_stmt => try self.resolveSelect(file_idx, idx, scope_id),
            .catch_bind => {
                const k = mf.tree.kids(idx); // [expr, err_ident, block]
                try self.resolveNode(file_idx, k[0], scope_id);
                const catch_scope = try self.pushScope(scope_id);
                _ = try self.activateLocal(file_idx, k[1], .let_binding, catch_scope);
                try self.resolveNode(file_idx, k[2], catch_scope);
            },
            .arrow_fn => {
                const k = mf.tree.kids(idx); // [arrow_params, body]
                const arrow_scope = try self.pushScope(scope_id);
                for (mf.tree.kids(k[0])) |p_idx| {
                    const pk = mf.tree.kids(p_idx); // [name, type_or_none]
                    if (pk[1] != ast.none) try self.resolveNode(file_idx, pk[1], arrow_scope);
                    _ = try self.activateLocal(file_idx, pk[0], .param, arrow_scope);
                }
                try self.resolveNode(file_idx, k[1], arrow_scope);
            },

            .asm_stmt => try self.resolveAsm(file_idx, idx, scope_id),

            else => for (mf.tree.kids(idx)) |k| try self.resolveNode(file_idx, k, scope_id),
        }
    }

    /// `asm` (§11.6): register-name and byte/word leaves are literal payload,
    /// never scope references — only the `result` type and each `input`'s value
    /// expression resolve. The default "resolve every child" recursion would
    /// wrongly look up `x0`/`rax` as variables, so `asm` needs its own walk.
    fn resolveAsm(self: *Resolver, file_idx: usize, idx: ast.Index, scope_id: u32) Error!void {
        const mf = self.files[file_idx];
        const k = mf.tree.kids(idx); // [x64_code, arm64_code, result?, clob_x64, clob_arm64, input...]
        if (k[2] != ast.none) try self.resolveNode(file_idx, mf.tree.kids(k[2])[2], scope_id); // result type
        for (k[5..]) |in_idx| try self.resolveNode(file_idx, mf.tree.kids(in_idx)[2], scope_id); // input value
    }
};

fn identText(mf: ModuleFile, node: ast.Index) []const u8 {
    const span = mf.tree.get(node).span;
    return mf.source[span.start..span.end];
}

/// Strips the surrounding `"`s from a `string_lit` leaf's raw source text.
/// Import paths are plain strings (the grammar requires `.string_lit`, never
/// an interpolated one); real escape decoding is left to the lexer if a
/// module path ever needs one, which none of ours do.
fn stringLitText(mf: ModuleFile, node: ast.Index) []const u8 {
    const raw = identText(mf, node);
    if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"') return raw[1 .. raw.len - 1];
    return raw;
}

/// Resolves one module: `files` must all belong to the same directory (they
/// share the flat namespace being built) and `imports` must already carry the
/// resolution of every distinct import path string those files reference.
/// `all_modules` is every dependency this module might import from, already
/// fully resolved (indexed by the `ModuleId`s inside `imports`).
pub fn resolveModule(
    gpa: Allocator,
    diags: *Diagnostics,
    files: []const ModuleFile,
    imports: *const ImportTable,
    all_modules: []const Module,
    prelude: ?ModuleId,
) !Module {
    var r = try Resolver.init(gpa, diags, files, imports, all_modules, prelude);
    defer r.deinitTemp();
    try r.collectTopLevel();
    try r.injectPrelude(); // after the module's own decls, so user names shadow it
    try r.checkTypeCycles();
    try r.resolveBodies();
    return r.intoModule();
}

// ============================================================================
// Filesystem project loader
// ============================================================================

/// Every module resolved for one `bit build`-style invocation, plus the parsed
/// trees/sources/paths they borrow — all owned here and freed together.
pub const LoadedProject = struct {
    gpa: Allocator,
    path_arena: std.heap.ArenaAllocator,
    trees: std.ArrayList(*ast.Tree) = .empty,
    sources: std.ArrayList([]u8) = .empty,
    modules: std.ArrayList(Module) = .empty,
    /// The `ModuleFile` list of each module, parallel to `modules` (indexed by
    /// `ModuleId`) — the check/lower stages need them after resolution. Each
    /// slice is owned here; its `source`/`tree` members point into
    /// `sources`/`trees`.
    module_files: std.ArrayList([]ModuleFile) = .empty,
    /// The module `bit build` was invoked on — its `main` is the entry point.
    /// Modules load in dependency order (imports first), so the root is loaded
    /// last and is not necessarily module 0.
    root: ModuleId = @enumFromInt(0),

    pub fn deinit(self: *LoadedProject) void {
        for (self.modules.items) |*m| m.deinit();
        self.modules.deinit(self.gpa);
        for (self.module_files.items) |mf| self.gpa.free(mf);
        self.module_files.deinit(self.gpa);
        for (self.trees.items) |t| {
            t.deinit();
            self.gpa.destroy(t);
        }
        self.trees.deinit(self.gpa);
        for (self.sources.items) |s| self.gpa.free(s);
        self.sources.deinit(self.gpa);
        self.path_arena.deinit();
        self.* = undefined;
    }
};

/// Upper bounds so directory/import-graph walks stay provably bounded
/// (Power of 10). Real projects never approach these.
const max_files_per_module = 4096;
const max_file_bytes = 1 << 20;
const max_modules = 4096;

const LoadOutcome = union(enum) { id: ModuleId, cycle, not_found };

const Loader = struct {
    gpa: Allocator,
    io: Io,
    diags: *Diagnostics,
    sm: *diagnostics.SourceManager,
    project: *LoadedProject,
    /// Absolute directory the `std/*` import prefix maps into (the shipped
    /// stdlib root), or null when no stdlib is available — then `std/*` imports
    /// resolve as `not_found`, same as before a stdlib existed.
    std_root: ?[]const u8 = null,
    /// The prelude module (`std/core`) once loaded, whose exports every
    /// subsequently-loaded module auto-imports. Null while loading the prelude
    /// itself (so it doesn't import itself) and when no stdlib is present.
    prelude: ?ModuleId = null,
    /// In-memory source substitutions (unsaved editor buffers); empty for a
    /// normal disk build.
    overrides: SourceOverrides = .{},
    /// Canonical directory path -> its fully resolved module.
    resolved: std.StringHashMapUnmanaged(ModuleId) = .{},
    /// Canonical directory paths currently being loaded (the recursion
    /// stack); a re-entrant `loadModule` call on one of these is a cycle.
    loading: std.StringHashMapUnmanaged(void) = .{},

    fn deinit(self: *Loader) void {
        self.resolved.deinit(self.gpa);
        self.loading.deinit(self.gpa);
    }

    // `loadModule` and `resolveImportPath` are mutually recursive, and their
    // real error surface spans `Allocator.Error`, directory/file I/O errors,
    // and the parser's own inferred set — `anyerror` breaks the inference
    // cycle without hand-enumerating every OS error variant. Nothing here is
    // ever silently swallowed; every error still propagates via `try`.
    /// Loads the module rooted at `dir_abs`. `only` names the single `.bit` file
    /// to take instead of scanning the directory — that is how a lone
    /// `bit run hello.bit` becomes a module of exactly one file (SPEC §17.1).
    /// It deliberately does NOT sweep in siblings: naming a file selects that
    /// file, naming a directory selects all of it. Everything downstream — the
    /// prelude, imports, checking — is identical either way, which is the whole
    /// point: a lone file is a module like any other, not a lesser thing.
    fn loadModule(self: *Loader, dir_abs: []const u8, only: ?[]const u8) anyerror!LoadOutcome {
        if (self.project.modules.items.len >= max_modules) return error.TooManyModules;
        const arena = self.project.path_arena.allocator();
        const canon = try std.fs.path.resolve(arena, &.{dir_abs});
        if (self.resolved.get(canon)) |id| return .{ .id = id };
        if (self.loading.contains(canon)) return .cycle;

        var dir = Io.Dir.openDirAbsolute(self.io, canon, .{ .iterate = true }) catch return .not_found;
        defer dir.close(self.io);

        try self.loading.put(self.gpa, canon, {});
        defer _ = self.loading.remove(canon);

        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(self.gpa);
        if (only) |name| {
            try names.append(self.gpa, try arena.dupe(u8, name));
        } else {
            var it = dir.iterate();
            var guard: u32 = 0;
            while (guard < max_files_per_module) : (guard += 1) {
                const entry = (try it.next(self.io)) orelse break;
                if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".bit")) continue;
                try names.append(self.gpa, try arena.dupe(u8, entry.name));
            }
            std.debug.assert(guard < max_files_per_module);
            insertionSort(names.items);
        }

        var files: std.ArrayList(ModuleFile) = .empty;
        defer files.deinit(self.gpa);
        for (names.items) |name| {
            const full_path = try std.fs.path.join(arena, &.{ canon, name });
            // An unsaved editor buffer (LSP overlay) wins over disk; a normal
            // build has no overrides and always reads disk.
            const source = if (self.overrides.lookup(full_path)) |text|
                try self.gpa.dupe(u8, text)
            else
                try dir.readFileAlloc(self.io, name, self.gpa, .limited(max_file_bytes));
            try self.project.sources.append(self.gpa, source);
            const file_id = try self.sm.addFile(full_path, source);

            const tree = try self.gpa.create(ast.Tree);
            tree.* = try ast.Tree.init(self.gpa);
            try self.project.trees.append(self.gpa, tree);
            try parser.parse(self.gpa, tree, self.diags, file_id, source);

            try files.append(self.gpa, .{ .file = file_id, .source = source, .tree = tree });
        }

        var import_table: ImportTable = .{};
        defer import_table.deinit(self.gpa);
        for (files.items) |mf| {
            for (mf.tree.kids(mf.tree.root)) |decl_idx| {
                if (decl_idx == ast.none or mf.tree.get(decl_idx).tag != .import_decl) continue;
                const path_node = mf.tree.kids(decl_idx)[1];
                const path_text = stringLitText(mf, path_node);
                if (import_table.contains(path_text)) continue;
                try import_table.put(self.gpa, path_text, try self.resolveImportPath(canon, path_text));
            }
        }

        const result = try resolveModule(self.gpa, self.diags, files.items, &import_table, self.project.modules.items, self.prelude);
        const id: ModuleId = @enumFromInt(self.project.modules.items.len);
        try self.project.modules.append(self.gpa, result);
        // Store this module's files parallel to `modules` (same index) so the
        // check/lower stages can reach them by `ModuleId`. Ownership moves here.
        std.debug.assert(self.project.module_files.items.len == @intFromEnum(id));
        try self.project.module_files.append(self.gpa, try files.toOwnedSlice(self.gpa));
        try self.resolved.put(self.gpa, canon, id);
        return .{ .id = id };
    }

    /// Resolves an import path string to a module directory and loads it. A
    /// `std/<pkg>` path maps into the shipped stdlib root (`std_root`); a `./`
    /// or `../` path is project-relative to the importing module's directory.
    /// Anything else (a bare package name with no std root) is `not_found`.
    fn resolveImportPath(self: *Loader, from_dir: []const u8, path_text: []const u8) anyerror!ImportResolution {
        const arena = self.project.path_arena.allocator();
        var target_dir: []const u8 = undefined;
        if (std.mem.startsWith(u8, path_text, "std/")) {
            const std_root = self.std_root orelse return .not_found;
            target_dir = try std.fs.path.join(arena, &.{ std_root, path_text["std/".len..] });
        } else if (std.mem.startsWith(u8, path_text, "./") or std.mem.startsWith(u8, path_text, "../")) {
            target_dir = try std.fs.path.join(arena, &.{ from_dir, path_text });
        } else {
            return .not_found;
        }
        return switch (try self.loadModule(target_dir, null)) {
            .id => |m| .{ .ok = m },
            .cycle => .cycle,
            .not_found => .not_found,
        };
    }
};

/// Insertion sort over a small, bounded slice (module directories realistically
/// hold a handful of files) — avoids depending on a particular `std.sort` entry
/// point while keeping directory-iteration order (unspecified by the OS)
/// deterministic for golden tests.
fn insertionSort(items: [][]const u8) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const key = items[i];
        var j = i;
        while (j > 0 and std.mem.order(u8, items[j - 1], key) == .gt) : (j -= 1) items[j] = items[j - 1];
        items[j] = key;
    }
}

/// Loads and resolves every module reachable from `root_dir_abs` (an absolute
/// path), recursing into relatively-imported directories in dependency order.
/// Diagnostics from every stage (lex/parse/resolve) accumulate in `diags`.
/// `std_root` (absolute) is where `std/*` imports resolve; pass null when no
/// stdlib ships with this build (then `std/*` imports are `not_found`).
/// `overrides` substitutes in-memory buffers for named files (the LSP's
/// unsaved edits); pass `.{}` for a plain disk build.
/// Loads the module at `root_dir_abs` and everything it imports, plus the
/// prelude. `root_only` names the root's single `.bit` file when the CLI was
/// handed a file rather than a directory (SPEC §17.1); null takes the whole
/// directory. Only the ROOT can be a lone file — an imported module is always a
/// directory, since an import names a module, not a file.
pub fn loadProject(
    gpa: Allocator,
    io: Io,
    diags: *Diagnostics,
    sm: *diagnostics.SourceManager,
    root_dir_abs: []const u8,
    root_only: ?[]const u8,
    std_root: ?[]const u8,
    overrides: SourceOverrides,
) !LoadedProject {
    var project = LoadedProject{ .gpa = gpa, .path_arena = std.heap.ArenaAllocator.init(gpa) };
    errdefer project.deinit();
    var loader = Loader{ .gpa = gpa, .io = io, .diags = diags, .sm = sm, .project = &project, .std_root = std_root, .overrides = overrides };
    defer loader.deinit();

    // Load the prelude module (`std/core`) first, if a stdlib is present, so its
    // exports auto-import into every module loaded afterward. Its own load sees
    // `loader.prelude == null`, so it does not import itself. A missing prelude
    // is not an error — programs then only see the builtins.
    if (std_root) |sr| {
        const core_dir = try std.fs.path.join(project.path_arena.allocator(), &.{ sr, "core" });
        switch (try loader.loadModule(core_dir, null)) {
            .id => |m| loader.prelude = m,
            .cycle, .not_found => {},
        }
    }

    switch (try loader.loadModule(root_dir_abs, root_only)) {
        .id => |m| project.root = m,
        .cycle, .not_found => {}, // diagnostics already emitted; root stays 0
    }
    return project;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

/// Parses `source` as a single-file module (no imports reach it) and returns
/// its rendered diagnostics (human format, ANSI off) plus whether any
/// error-severity diagnostic fired.
fn resolveSource(gpa: Allocator, source: []const u8) !struct { text: []u8, failed: bool } {
    var sm = diagnostics.SourceManager.init(gpa);
    defer sm.deinit();
    const file = try sm.addFile("t.bit", source);
    var diags = Diagnostics.init(gpa, &sm);
    defer diags.deinit();
    var tree = try ast.Tree.init(gpa);
    defer tree.deinit();
    try parser.parse(gpa, &tree, &diags, file, source);

    var imports: ImportTable = .{};
    defer imports.deinit(gpa);
    const files = [_]ModuleFile{.{ .file = file, .source = source, .tree = &tree }};
    var mod = try resolveModule(gpa, &diags, &files, &imports, &.{}, null);
    defer mod.deinit();

    var rendered: Io.Writer.Allocating = .init(gpa);
    defer rendered.deinit();
    try diags.renderAll(&rendered.writer);
    return .{ .text = try gpa.dupe(u8, rendered.written()), .failed = diags.hasErrors() };
}

fn expectClean(source: []const u8) !void {
    const gpa = testing.allocator;
    const r = try resolveSource(gpa, source);
    defer gpa.free(r.text);
    if (r.failed) std.debug.print("unexpected diagnostics for {s}:\n{s}\n", .{ source, r.text });
    try testing.expect(!r.failed);
}

fn expectCode(source: []const u8, code: Code) !void {
    const gpa = testing.allocator;
    const r = try resolveSource(gpa, source);
    defer gpa.free(r.text);
    var code_buf: [5]u8 = undefined;
    const needle = code.string(&code_buf);
    if (std.mem.indexOf(u8, r.text, needle) == null) {
        std.debug.print("expected {s} in diagnostics for {s}, got:\n{s}\n", .{ needle, source, r.text });
    }
    try testing.expect(std.mem.indexOf(u8, r.text, needle) != null);
}

test "clean program: forward references and shadowing across scopes resolve" {
    try expectClean(
        \\function main(): i32 {
        \\  return helper(1)
        \\}
        \\function helper(x: i32): i32 {
        \\  let y = x + 1
        \\  { let y = x * 2; return y }
        \\  return y
        \\}
    );
}

test "undefined name" {
    try expectCode("function f(): i32 { return missing }", .undefined_name);
}

test "duplicate declaration at module level" {
    try expectCode("let x = 1\nlet x = 2\n", .duplicate_declaration);
}

test "duplicate declaration in a block" {
    try expectCode("function f() {\n  let x = 1\n  let x = 2\n}\n", .duplicate_declaration);
}

test "use before init in the same scope" {
    try expectCode("function f(): i32 {\n  let y = x\n  let x = 1\n  return y\n}\n", .use_before_init);
}

test "shadowing a predeclared identifier warns" {
    try expectCode("let int = 1\n", .shadows_predeclared);
}

test "duplicate struct field" {
    try expectCode("struct P { x: i32, x: i32 }", .duplicate_declaration);
}

test "type alias self-cycle is rejected" {
    try expectCode("type A = A", .type_cycle);
}

test "mutual type alias cycle is rejected" {
    try expectCode("type A = B\ntype B = A", .type_cycle);
}

test "array-embedding struct cycle is rejected" {
    try expectCode("struct Node { items: [3]Node }", .type_cycle);
}

test "struct self-reference through a slice is not a cycle" {
    try expectClean("struct Node { next: []Node }");
}

test "struct field of another struct type is not a cycle" {
    try expectClean("struct A { b: B }\nstruct B { x: i32 }");
}

test "import with no project context reports not found" {
    try expectCode("import { thing } from \"./util\"\nfunction f() { return thing() }", .import_not_found);
}

test "cross-module import resolves an exported symbol" {
    const gpa = testing.allocator;

    var sm = diagnostics.SourceManager.init(gpa);
    defer sm.deinit();
    var diags = Diagnostics.init(gpa, &sm);
    defer diags.deinit();

    const util_src = "export function add(a: i32, b: i32): i32 { return a + b }\n";
    const util_file = try sm.addFile("util.bit", util_src);
    var util_tree = try ast.Tree.init(gpa);
    defer util_tree.deinit();
    try parser.parse(gpa, &util_tree, &diags, util_file, util_src);

    var no_imports: ImportTable = .{};
    defer no_imports.deinit(gpa);
    const util_files = [_]ModuleFile{.{ .file = util_file, .source = util_src, .tree = &util_tree }};
    var util_mod = try resolveModule(gpa, &diags, &util_files, &no_imports, &.{}, null);
    defer util_mod.deinit();
    try testing.expect(!diags.hasErrors());
    try testing.expect(util_mod.exports.contains("add"));

    const all_modules = [_]Module{util_mod};

    const main_src = "import { add } from \"./util\"\nfunction main(): i32 { return add(1, 2) }\n";
    const main_file = try sm.addFile("main.bit", main_src);
    var main_tree = try ast.Tree.init(gpa);
    defer main_tree.deinit();
    try parser.parse(gpa, &main_tree, &diags, main_file, main_src);

    var imports: ImportTable = .{};
    defer imports.deinit(gpa);
    try imports.put(gpa, "./util", .{ .ok = @enumFromInt(0) });
    const main_files = [_]ModuleFile{.{ .file = main_file, .source = main_src, .tree = &main_tree }};
    var main_mod = try resolveModule(gpa, &diags, &main_files, &imports, &all_modules, null);
    defer main_mod.deinit();

    try testing.expect(!diags.hasErrors());
}

test "importing an unexported name is rejected" {
    const gpa = testing.allocator;

    var sm = diagnostics.SourceManager.init(gpa);
    defer sm.deinit();
    var diags = Diagnostics.init(gpa, &sm);
    defer diags.deinit();

    const util_src = "function helper(): i32 { return 1 }\n"; // not exported
    const util_file = try sm.addFile("util.bit", util_src);
    var util_tree = try ast.Tree.init(gpa);
    defer util_tree.deinit();
    try parser.parse(gpa, &util_tree, &diags, util_file, util_src);

    var no_imports: ImportTable = .{};
    defer no_imports.deinit(gpa);
    const util_files = [_]ModuleFile{.{ .file = util_file, .source = util_src, .tree = &util_tree }};
    var util_mod = try resolveModule(gpa, &diags, &util_files, &no_imports, &.{}, null);
    defer util_mod.deinit();

    const all_modules = [_]Module{util_mod};
    const main_src = "import { helper } from \"./util\"\n";
    const main_file = try sm.addFile("main.bit", main_src);
    var main_tree = try ast.Tree.init(gpa);
    defer main_tree.deinit();
    try parser.parse(gpa, &main_tree, &diags, main_file, main_src);

    var imports: ImportTable = .{};
    defer imports.deinit(gpa);
    try imports.put(gpa, "./util", .{ .ok = @enumFromInt(0) });
    const main_files = [_]ModuleFile{.{ .file = main_file, .source = main_src, .tree = &main_tree }};
    var main_mod = try resolveModule(gpa, &diags, &main_files, &imports, &all_modules, null);
    defer main_mod.deinit();

    try testing.expect(diags.hasErrors());
    var rendered: Io.Writer.Allocating = .init(gpa);
    defer rendered.deinit();
    try diags.renderAll(&rendered.writer);
    var code_buf: [5]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, rendered.written(), Code.unexported_name.string(&code_buf)) != null);
}

test "an import cycle is reported, not an infinite loop" {
    const gpa = testing.allocator;

    var sm = diagnostics.SourceManager.init(gpa);
    defer sm.deinit();
    var diags = Diagnostics.init(gpa, &sm);
    defer diags.deinit();

    const src = "import x from \"./self\"\n";
    const file = try sm.addFile("self.bit", src);
    var tree = try ast.Tree.init(gpa);
    defer tree.deinit();
    try parser.parse(gpa, &tree, &diags, file, src);

    var imports: ImportTable = .{};
    defer imports.deinit(gpa);
    try imports.put(gpa, "./self", .cycle);
    const files = [_]ModuleFile{.{ .file = file, .source = src, .tree = &tree }};
    var mod = try resolveModule(gpa, &diags, &files, &imports, &.{}, null);
    defer mod.deinit();

    try testing.expect(diags.hasErrors());
    var rendered: Io.Writer.Allocating = .init(gpa);
    defer rendered.deinit();
    try diags.renderAll(&rendered.writer);
    var code_buf: [5]u8 = undefined;
    try testing.expect(std.mem.indexOf(u8, rendered.written(), Code.import_cycle.string(&code_buf)) != null);
}
