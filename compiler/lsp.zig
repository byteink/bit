//! `bit lsp` — the Bit language server (task #337). Speaks LSP over stdio,
//! reusing the lexer/parser/checker exactly as `bitc check` does: a directory
//! of `.bit` files is one module (spec/SPEC.md §17.1, `resolve.zig`'s own
//! docs), so "goto-definition crosses files" for free — no import statement
//! needed to reference a sibling file's declaration.
//!
//! ## Architecture
//!
//! One `Snapshot` per directory: every `.bit` file in that directory, parsed,
//! resolved, and type-checked together, with open documents' unsaved buffers
//! (`Server.overlays`) substituted for their on-disk contents. A snapshot is
//! rebuilt from scratch on every `didOpen`/`didChange`/`didClose` — whole-
//! module recheck per change, exactly as this task's scope note allows.
//! `// ponytail: whole-module recheck per change; incremental checking is the
//! upgrade path once real projects show >100ms round-trips.`
//!
//! Hover, goto-definition, and document-symbols all read a cached snapshot.
//! Dot-completion is the one operation that needs a document mid-edit (the
//! text right after a bare `.` doesn't parse — there's no member name yet):
//! it splices a throwaway identifier at the cursor before reparsing, so the
//! receiver expression before the `.` still parses and the checker can type
//! it. This "dummy identifier" trick is the standard way LSPs answer
//! completion without teaching the parser to guess at incomplete input.
//!
//! Every stage below assumes a syntactically valid tree before it runs (the
//! same contract `main.zig`'s `compileReport` documents for `resolve`/
//! `check`): a file with a parse error gets diagnostics but no hover/
//! goto-def/completion until it parses cleanly again.
//! `// ponytail: scope completion lists module.all_names (top-level names)
//! only; resolve.zig doesn't expose block scopes publicly (see its own doc
//! comment), so local-variable completion is the upgrade path.`

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const json = std.json;

const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const parser = @import("parser.zig");
const diagnostics = @import("diagnostics.zig");
const resolve = @import("resolve.zig");
const check = @import("check.zig");
const fmt = @import("fmt.zig");

const Span = diagnostics.Span;

// ============================================================================
// Entry point
// ============================================================================

pub fn run(gpa: Allocator, io: Io) !void {
    var in_buf: [1 << 16]u8 = undefined;
    var stdin_reader: Io.File.Reader = .init(.stdin(), io, &in_buf);
    var out_buf: [1 << 16]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &out_buf);

    var server = Server.init(gpa, io);
    defer server.deinit();

    while (true) {
        const body = readMessage(gpa, &stdin_reader.interface) catch |err| switch (err) {
            error.EndOfStream => return,
            else => return err,
        };
        defer gpa.free(body);
        try server.handleMessage(body, &stdout_writer.interface);
    }
}

// ============================================================================
// JSON-RPC framing (`Content-Length: N\r\n\r\n<body>`)
// ============================================================================

const max_header_lines = 32;
const max_message_bytes = 64 << 20; // 64 MiB: generous, still bounded

fn readMessage(gpa: Allocator, r: *Io.Reader) ![]u8 {
    var content_length: ?usize = null;
    var lines: u32 = 0;
    while (lines < max_header_lines) : (lines += 1) {
        const raw_line = try r.takeDelimiterExclusive('\n');
        // `takeDelimiterExclusive` leaves the delimiter itself unconsumed
        // (only the bytes before it are tossed) — skip over it here so the
        // next call starts past this line, not immediately back on the '\n'.
        // A failed peek here (any real I/O error, not just EOF) still
        // surfaces on the next real read (the header line or body itself).
        if (r.peekByte() catch null) |b| {
            if (b == '\n') r.toss(1);
        }
        const line = if (std.mem.endsWith(u8, raw_line, "\r")) raw_line[0 .. raw_line.len - 1] else raw_line;
        if (line.len == 0) break; // blank line ends the header block
        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const value = std.mem.trim(u8, line["content-length:".len..], " \t");
            content_length = try std.fmt.parseInt(usize, value, 10);
        }
        // Other headers (e.g. Content-Type) are accepted and ignored.
    }
    const len = content_length orelse return error.MissingContentLength;
    if (len > max_message_bytes) return error.MessageTooLarge;
    return r.readAlloc(gpa, len);
}

fn writeFramed(w: *Io.Writer, body: []const u8) !void {
    try w.print("Content-Length: {d}\r\n\r\n", .{body.len});
    try w.writeAll(body);
    try w.flush();
}

// ============================================================================
// Server state
// ============================================================================

const Server = struct {
    gpa: Allocator,
    io: Io,
    /// Absolute file path -> owned unsaved-buffer text, for every currently
    /// open document. Read by `buildSnapshot` in place of disk contents.
    overlays: std.StringHashMapUnmanaged([]u8) = .{},
    /// Absolute directory path -> its last-built `Snapshot`.
    snapshots: std.StringHashMapUnmanaged(Snapshot) = .{},
    shutting_down: bool = false,

    fn init(gpa: Allocator, io: Io) Server {
        return .{ .gpa = gpa, .io = io };
    }

    fn deinit(self: *Server) void {
        var oit = self.overlays.iterator();
        while (oit.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            self.gpa.free(e.value_ptr.*);
        }
        self.overlays.deinit(self.gpa);

        var sit = self.snapshots.iterator();
        while (sit.next()) |e| {
            self.gpa.free(e.key_ptr.*);
            e.value_ptr.deinit();
        }
        self.snapshots.deinit(self.gpa);
        self.* = undefined;
    }

    fn handleMessage(self: *Server, body: []const u8, out: *Io.Writer) !void {
        const parsed = json.parseFromSlice(json.Value, self.gpa, body, .{}) catch |err| {
            std.log.err("bitls: malformed JSON-RPC message: {s}", .{@errorName(err)});
            return;
        };
        defer parsed.deinit();
        const root = switch (parsed.value) {
            .object => |o| o,
            else => return,
        };
        const method = switch (root.get("method") orelse return) {
            .string => |s| s,
            else => return,
        };
        const params = root.get("params") orelse json.Value.null;

        if (root.get("id")) |id| {
            self.handleRequest(method, params, id, out) catch |err| {
                respondError(self.gpa, out, id, -32603, @errorName(err)) catch {};
            };
        } else {
            self.handleNotification(method, params, out) catch |err| {
                std.log.err("bitls: notification '{s}' failed: {s}", .{ method, @errorName(err) });
            };
        }
    }

    fn handleRequest(self: *Server, method: []const u8, params: json.Value, id: json.Value, out: *Io.Writer) !void {
        if (std.mem.eql(u8, method, "initialize")) return self.onInitialize(params, id, out);
        if (std.mem.eql(u8, method, "shutdown")) {
            self.shutting_down = true;
            return respondRaw(self.gpa, out, id, "null");
        }
        if (std.mem.eql(u8, method, "textDocument/hover")) return self.onHover(params, id, out);
        if (std.mem.eql(u8, method, "textDocument/definition")) return self.onDefinition(params, id, out);
        if (std.mem.eql(u8, method, "textDocument/completion")) return self.onCompletion(params, id, out);
        if (std.mem.eql(u8, method, "textDocument/documentSymbol")) return self.onDocumentSymbol(params, id, out);
        // Unknown method: JSON-RPC "method not found".
        try respondError(self.gpa, out, id, -32601, "method not found");
    }

    fn handleNotification(self: *Server, method: []const u8, params: json.Value, out: *Io.Writer) !void {
        if (std.mem.eql(u8, method, "textDocument/didOpen")) return self.onDidOpen(params, out);
        if (std.mem.eql(u8, method, "textDocument/didChange")) return self.onDidChange(params, out);
        if (std.mem.eql(u8, method, "textDocument/didClose")) return self.onDidClose(params, out);
        // initialized, didSave, $/cancelRequest, exit, and anything else:
        // no state to update; notifications never get a reply either way.
    }

    // ---- lifecycle ----------------------------------------------------------

    fn onInitialize(self: *Server, params: json.Value, id: json.Value, out: *Io.Writer) !void {
        _ = params;
        const result = InitializeResult{};
        try respondValue(self.gpa, out, id, result);
    }

    // ---- document sync --------------------------------------------------------

    fn onDidOpen(self: *Server, params: json.Value, out: *Io.Writer) !void {
        const doc = objField(params, "textDocument") orelse return;
        const uri = strField(doc, "uri") orelse return;
        const text = strField(doc, "text") orelse return;
        const path = try uriToPath(self.gpa, uri);
        try self.setOverlay(path, text);
        try self.recheckAndPublish(std.fs.path.dirname(path) orelse path, out);
    }

    fn onDidChange(self: *Server, params: json.Value, out: *Io.Writer) !void {
        const doc = objField(params, "textDocument") orelse return;
        const uri = strField(doc, "uri") orelse return;
        const changes = switch (objGet(params, "contentChanges") orelse return) {
            .array => |a| a.items,
            else => return,
        };
        if (changes.len == 0) return;
        // Full sync (`textDocumentSync = 1`): the last entry's `text` is the
        // whole new document.
        const text = strField(changes[changes.len - 1], "text") orelse return;
        const path = try uriToPath(self.gpa, uri);
        try self.setOverlay(path, text);
        try self.recheckAndPublish(std.fs.path.dirname(path) orelse path, out);
    }

    fn onDidClose(self: *Server, params: json.Value, out: *Io.Writer) !void {
        const doc = objField(params, "textDocument") orelse return;
        const uri = strField(doc, "uri") orelse return;
        const path = try uriToPath(self.gpa, uri);
        defer self.gpa.free(path);
        if (self.overlays.fetchRemove(path)) |kv| {
            self.gpa.free(kv.key);
            self.gpa.free(kv.value);
        }
        try self.recheckAndPublish(std.fs.path.dirname(path) orelse path, out);
    }

    /// Replaces (or inserts) the overlay for `path` (already-owned, consumed
    /// by this call) with a copy of `text` (borrowed).
    fn setOverlay(self: *Server, path: []u8, text: []const u8) !void {
        if (self.overlays.fetchRemove(path)) |kv| {
            self.gpa.free(kv.key);
            self.gpa.free(kv.value);
        }
        const owned_text = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(owned_text);
        try self.overlays.put(self.gpa, path, owned_text);
    }

    // ---- snapshot cache -------------------------------------------------------

    /// Rebuilds `dir`'s snapshot and publishes `textDocument/publishDiagnostics`
    /// for every file it contains. Errors from the rebuild (a vanished
    /// directory, an OOM) propagate to the notification handler, which only
    /// logs them — a bad recheck must never take the server down.
    fn recheckAndPublish(self: *Server, dir: []const u8, out: *Io.Writer) !void {
        var new_snap = buildSnapshot(self.gpa, self.io, dir, &self.overlays, null) catch |err| {
            std.log.err("bitls: rechecking '{s}' failed: {s}", .{ dir, @errorName(err) });
            return;
        };
        errdefer new_snap.deinit();

        if (self.snapshots.fetchRemove(dir)) |kv| {
            self.gpa.free(kv.key);
            var old = kv.value;
            old.deinit();
        }
        const key = try self.gpa.dupe(u8, dir);
        try self.snapshots.put(self.gpa, key, new_snap);

        try self.publishDiagnostics(self.snapshots.getPtr(key).?, out);
    }

    fn ensureSnapshot(self: *Server, dir: []const u8) !*Snapshot {
        if (self.snapshots.getPtr(dir)) |s| return s;
        const snap = try buildSnapshot(self.gpa, self.io, dir, &self.overlays, null);
        errdefer {
            var s = snap;
            s.deinit();
        }
        const key = try self.gpa.dupe(u8, dir);
        try self.snapshots.put(self.gpa, key, snap);
        return self.snapshots.getPtr(key).?;
    }

    /// Publishes diagnostics for the *root* module's files only — the prelude
    /// and stdlib modules are loaded for name resolution, but the user never
    /// opened them, so their (absent) diagnostics must not be sprayed onto
    /// their URIs. Diagnostics are keyed by `FileId` (global across all loaded
    /// modules), not by root-file index.
    fn publishDiagnostics(self: *Server, snap: *const Snapshot, out: *Io.Writer) !void {
        for (snap.rootFiles(), 0..) |mf, file_idx| {
            var body: Io.Writer.Allocating = .init(self.gpa);
            defer body.deinit();
            const uri = try pathToUri(self.gpa, snap.paths[file_idx]);
            defer self.gpa.free(uri);

            try body.writer.writeAll("{\"uri\":");
            try json.Stringify.encodeJsonString(uri, .{}, &body.writer);
            try body.writer.writeAll(",\"diagnostics\":[");
            var first = true;
            for (snap.diags.list.items) |d| {
                if (d.span.file != mf.file) continue;
                if (!first) try body.writer.writeByte(',');
                first = false;
                try writeLspDiagnostic(&body.writer, mf.source, d);
            }
            try body.writer.writeAll("]}");
            try self.notify("textDocument/publishDiagnostics", body.written(), out);
        }
    }

    fn notify(self: *Server, method: []const u8, params_json: []const u8, out: *Io.Writer) !void {
        var msg: Io.Writer.Allocating = .init(self.gpa);
        defer msg.deinit();
        try msg.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":");
        try json.Stringify.encodeJsonString(method, .{}, &msg.writer);
        try msg.writer.writeAll(",\"params\":");
        try msg.writer.writeAll(params_json);
        try msg.writer.writeAll("}");
        try writeFramed(out, msg.written());
    }

    // ---- requests ---------------------------------------------------------

    fn onHover(self: *Server, params: json.Value, id: json.Value, out: *Io.Writer) !void {
        const tdp = parseTextDocumentPosition(params) orelse return respondRaw(self.gpa, out, id, "null");
        const path = try uriToPath(self.gpa, tdp.uri);
        defer self.gpa.free(path);
        const dir = std.fs.path.dirname(path) orelse return respondRaw(self.gpa, out, id, "null");
        const snap = self.ensureSnapshot(dir) catch return respondRaw(self.gpa, out, id, "null");
        const file_idx = findFileIndex(snap, path) orelse return respondRaw(self.gpa, out, id, "null");

        const source = snap.srcOf(file_idx);
        const offset = utf16ToByteOffset(source, tdp.pos);
        const node = nodeAt(snap.treeOf(file_idx), offset);
        if (node == ast.none) return respondRaw(self.gpa, out, id, "null");

        const text = try hoverText(self.gpa, snap, file_idx, node) orelse return respondRaw(self.gpa, out, id, "null");
        defer self.gpa.free(text);

        const hover = Hover{ .contents = .{ .value = text } };
        try respondValue(self.gpa, out, id, hover);
    }

    fn onDefinition(self: *Server, params: json.Value, id: json.Value, out: *Io.Writer) !void {
        const tdp = parseTextDocumentPosition(params) orelse return respondRaw(self.gpa, out, id, "null");
        const path = try uriToPath(self.gpa, tdp.uri);
        defer self.gpa.free(path);
        const dir = std.fs.path.dirname(path) orelse return respondRaw(self.gpa, out, id, "null");
        const snap = self.ensureSnapshot(dir) catch return respondRaw(self.gpa, out, id, "null");
        const file_idx = findFileIndex(snap, path) orelse return respondRaw(self.gpa, out, id, "null");
        const offset = utf16ToByteOffset(snap.srcOf(file_idx), tdp.pos);
        const node = nodeAt(snap.treeOf(file_idx), offset);
        const sym_id = snap.rootModule().node_symbols[file_idx][node];
        if (sym_id == .none) return respondRaw(self.gpa, out, id, "null");
        const sym = snap.rootModule().symbols.items[@intFromEnum(sym_id)];
        // `decl == none` covers prelude/imported symbols (they declare nothing
        // in this module); `file_idx` then indexes another module, so jumping
        // to it here would mis-index the root module's files. Same-module
        // symbols carry a real `decl` and a `file_idx` within the root module.
        if (sym.decl == ast.none or sym.file_idx >= snap.rootFiles().len) return respondRaw(self.gpa, out, id, "null");

        const target_idx = sym.file_idx;
        const name_span = defNameSpan(snap.treeOf(target_idx), sym.decl);
        const uri = try pathToUri(self.gpa, snap.paths[target_idx]);
        defer self.gpa.free(uri);
        const loc = Location{ .uri = uri, .range = spanToRange(snap.srcOf(target_idx), name_span) };
        try respondValue(self.gpa, out, id, loc);
    }

    fn onDocumentSymbol(self: *Server, params: json.Value, id: json.Value, out: *Io.Writer) !void {
        const doc = objField(params, "textDocument") orelse return respondRaw(self.gpa, out, id, "[]");
        const uri = strField(doc, "uri") orelse return respondRaw(self.gpa, out, id, "[]");
        const path = try uriToPath(self.gpa, uri);
        defer self.gpa.free(path);
        const dir = std.fs.path.dirname(path) orelse return respondRaw(self.gpa, out, id, "[]");
        const snap = self.ensureSnapshot(dir) catch return respondRaw(self.gpa, out, id, "[]");
        const file_idx = findFileIndex(snap, path) orelse return respondRaw(self.gpa, out, id, "[]");

        var syms: std.ArrayList(SymbolInformation) = .empty;
        defer syms.deinit(self.gpa);
        try collectDocumentSymbols(self.gpa, snap.treeOf(file_idx), snap.srcOf(file_idx), uri, &syms);
        try respondValue(self.gpa, out, id, syms.items);
    }

    fn onCompletion(self: *Server, params: json.Value, id: json.Value, out: *Io.Writer) !void {
        const empty = CompletionList{ .items = &.{} };
        const tdp = parseTextDocumentPosition(params) orelse return respondValue(self.gpa, out, id, empty);
        const path = try uriToPath(self.gpa, tdp.uri);
        defer self.gpa.free(path);
        const dir = std.fs.path.dirname(path) orelse return respondValue(self.gpa, out, id, empty);

        const text = self.overlays.get(path) orelse return respondValue(self.gpa, out, id, empty);
        const offset = utf16ToByteOffset(text, tdp.pos);
        const dot_before = offset > 0 and text[offset - 1] == '.';

        if (!dot_before) return self.scopeCompletion(dir, id, out);
        return self.dotCompletion(dir, path, text, offset, id, out);
    }

    fn scopeCompletion(self: *Server, dir: []const u8, id: json.Value, out: *Io.Writer) !void {
        const empty = CompletionList{ .items = &.{} };
        const snap = self.ensureSnapshot(dir) catch return respondValue(self.gpa, out, id, empty);
        var items: std.ArrayList(CompletionItem) = .empty;
        defer items.deinit(self.gpa);
        var it = snap.rootModule().all_names.iterator();
        while (it.next()) |e| {
            const sym = snap.rootModule().symbols.items[@intFromEnum(e.value_ptr.*)];
            try items.append(self.gpa, .{ .label = e.key_ptr.*, .kind = completionKind(sym.kind) });
        }
        try respondValue(self.gpa, out, id, CompletionList{ .items = items.items });
    }

    /// `.`-triggered completion: splices a throwaway identifier at `offset`
    /// (right after the `.`) so the receiver expression parses even though
    /// nothing follows the dot yet, reparses just this file with the splice,
    /// and lists the receiver type's fields/methods. See the module doc
    /// comment for why this is the standard technique rather than a parser
    /// change.
    fn dotCompletion(self: *Server, dir: []const u8, path: []const u8, text: []const u8, offset: u32, id: json.Value, out: *Io.Writer) !void {
        const empty = CompletionList{ .items = &.{} };
        const marker = "zqx";
        const spliced = try self.gpa.alloc(u8, text.len + marker.len);
        defer self.gpa.free(spliced);
        @memcpy(spliced[0..offset], text[0..offset]);
        @memcpy(spliced[offset .. offset + marker.len], marker);
        @memcpy(spliced[offset + marker.len ..], text[offset..]);

        var snap = buildSnapshot(self.gpa, self.io, dir, &self.overlays, .{ .path = path, .text = spliced }) catch return respondValue(self.gpa, out, id, empty);
        defer snap.deinit();
        if (!snap.checked_ok) return respondValue(self.gpa, out, id, empty);
        const file_idx = findFileIndex(&snap, path) orelse return respondValue(self.gpa, out, id, empty);

        var path_stack: std.ArrayList(ast.Index) = .empty;
        defer path_stack.deinit(self.gpa);
        try nodePath(snap.treeOf(file_idx), offset, &path_stack, self.gpa);
        if (path_stack.items.len < 2) return respondValue(self.gpa, out, id, empty);
        const marker_node = path_stack.items[path_stack.items.len - 1];
        const parent_node = path_stack.items[path_stack.items.len - 2];
        const tree = snap.treeOf(file_idx);
        if (tree.get(parent_node).tag != .member) return respondValue(self.gpa, out, id, empty);
        const member_kids = tree.kids(parent_node);
        if (member_kids[1] != marker_node) return respondValue(self.gpa, out, id, empty);

        const recv_ty = snap.rootChecked().typeOf(file_idx, member_kids[0]);
        const nc = check.NameCtx{ .gpa = self.gpa, .ctx = &snap.ctx, .module_id = snap.root_id, .module = snap.rootModule(), .all_modules = snap.project.modules.items };

        var items: std.ArrayList(CompletionItem) = .empty;
        defer {
            for (items.items) |it2| if (it2.detail) |d| self.gpa.free(d);
            items.deinit(self.gpa);
        }
        switch (snap.ctx.typeOf(recv_ty)) {
            .@"struct" => |fields| for (fields) |f| {
                const detail = try check.describeType(nc, f.ty);
                try items.append(self.gpa, .{ .label = f.name, .kind = completion_kind_field, .detail = detail });
            },
            .interface => |methods| for (methods) |m| {
                const detail = try funcSignature(self.gpa, nc, m.params, m.result);
                try items.append(self.gpa, .{ .label = m.name, .kind = completion_kind_method, .detail = detail });
            },
            else => {},
        }
        if (snap.ctx.methodsOf(recv_ty)) |bucket| {
            var mit = bucket.iterator();
            while (mit.next()) |e| {
                const detail = try funcSignature(self.gpa, nc, e.value_ptr.params, e.value_ptr.result);
                try items.append(self.gpa, .{ .label = e.key_ptr.*, .kind = completion_kind_method, .detail = detail });
            }
        }
        try respondValue(self.gpa, out, id, CompletionList{ .items = items.items });
    }
};

fn funcSignature(gpa: Allocator, nc: check.NameCtx, params: []const check.TypeId, result: check.TypeId) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try buf.append(gpa, '(');
    for (params, 0..) |p, i| {
        if (i != 0) try buf.appendSlice(gpa, ", ");
        const t = try check.describeType(nc, p);
        defer gpa.free(t);
        try buf.appendSlice(gpa, t);
    }
    try buf.appendSlice(gpa, ") => ");
    const rt = try check.describeType(nc, result);
    defer gpa.free(rt);
    try buf.appendSlice(gpa, rt);
    return buf.toOwnedSlice(gpa);
}

// ============================================================================
// Snapshot: one directory's worth of parsed/resolved/checked files
// ============================================================================

const max_files_per_dir = 4096;
const max_file_bytes = 1 << 20;
const max_ancestors = 64;

/// One directory's snapshot, built as a *whole project* — the edited directory
/// (`root_id`) plus the prelude (`std/core`) and every module it imports
/// (`std/*` and relative) — so prelude names (`println`) and stdlib imports
/// resolve exactly as a real `bit build` does, instead of squiggling as
/// undefined. `resolve.loadProject` does the loading; unsaved buffers are fed
/// in as overlays. All per-file operations index the *root* module.
/// `// ponytail: reloads + rechecks the whole stdlib on every keystroke;
/// caching the unchanged std modules across snapshots is the upgrade path once
/// the stdlib is big enough for it to matter.`
const Snapshot = struct {
    gpa: Allocator,
    dir: []u8,
    /// Absolute paths of the *root* module's files, parallel to its
    /// `ModuleFile` slice — for URI mapping and `findFileIndex`.
    paths: [][]u8,
    /// Heap-allocated so `Diagnostics.sources`'s pointer into it stays valid
    /// no matter how many times this `Snapshot` itself is copied (returned by
    /// value, moved into `Server.snapshots`, ...).
    sm: *diagnostics.SourceManager,
    diags: diagnostics.Diagnostics,
    /// Owns every module's trees/sources/symbol tables.
    project: resolve.LoadedProject,
    root_id: resolve.ModuleId,
    ctx: check.TypeContext,
    /// One `CheckedModule` per module, parallel to `project.modules`; empty
    /// until `checked_ok`.
    checked: []check.CheckedModule,
    /// True once `ctx`/`checked` were assigned (no parse/resolve errors).
    checked_ok: bool,

    fn deinit(self: *Snapshot) void {
        if (self.checked_ok) {
            for (self.checked) |*c| c.deinit();
            self.gpa.free(self.checked);
            self.ctx.deinit();
        }
        self.project.deinit();
        self.diags.deinit();
        self.sm.deinit();
        self.gpa.destroy(self.sm);
        for (self.paths) |p| self.gpa.free(p);
        self.gpa.free(self.paths);
        self.gpa.free(self.dir);
        self.* = undefined;
    }

    /// The edited directory's files (the module all per-file ops index into).
    fn rootFiles(self: *const Snapshot) []const resolve.ModuleFile {
        return self.project.module_files.items[@intFromEnum(self.root_id)];
    }
    fn rootModule(self: *const Snapshot) *const resolve.Module {
        return &self.project.modules.items[@intFromEnum(self.root_id)];
    }
    fn rootChecked(self: *const Snapshot) *const check.CheckedModule {
        return &self.checked[@intFromEnum(self.root_id)];
    }
    fn srcOf(self: *const Snapshot, file_idx: usize) []const u8 {
        return self.rootFiles()[file_idx].source;
    }
    fn treeOf(self: *const Snapshot, file_idx: usize) *const ast.Tree {
        return self.rootFiles()[file_idx].tree;
    }
};

fn findFileIndex(snap: *const Snapshot, path: []const u8) ?usize {
    for (snap.paths, 0..) |p, i| {
        if (std.mem.eql(u8, p, path)) return i;
    }
    return null;
}

/// Walks up from `start_dir` (absolute) for the first ancestor holding a
/// `stdlib/core` directory — the shipped Bit stdlib — and returns that
/// `stdlib` path (owned). Null when none is found (a std-less checkout), which
/// makes `std/*` imports resolve as not-found and drops the prelude, exactly
/// as the CLI does without a stdlib. Bounded walk (Power of 10).
fn findStdRoot(gpa: Allocator, io: Io, start_dir: []const u8) !?[]u8 {
    var cur = start_dir;
    var i: u32 = 0;
    while (i < max_ancestors) : (i += 1) {
        const core = try std.fs.path.join(gpa, &.{ cur, "stdlib", "core" });
        defer gpa.free(core);
        if (Io.Dir.openDirAbsolute(io, core, .{})) |d| {
            var dd = d;
            dd.close(io);
            return try std.fs.path.join(gpa, &.{ cur, "stdlib" });
        } else |_| {}
        const parent = std.fs.path.dirname(cur) orelse break;
        if (parent.len >= cur.len) break;
        cur = parent;
    }
    return null;
}

/// Bounded (Power of 10): directory listings never exceed `max_files_per_dir`.
fn insertionSort(items: [][]u8) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const key = items[i];
        var j = i;
        while (j > 0 and std.mem.order(u8, items[j - 1], key) == .gt) : (j -= 1) items[j] = items[j - 1];
        items[j] = key;
    }
}

/// Loads `dir_abs` as a whole project — the edited directory plus the prelude
/// and every module it imports — with `overlays` (open documents' unsaved
/// buffers) and `override` (a single mid-edit splice) substituted for disk
/// contents. All per-file operations then index the *root* module (the edited
/// directory). Always builds a `project` (the parser recovers from syntax
/// errors); `checked_ok` reports whether type info is available, mirroring
/// `main.zig`'s `buildProject` gating (no check when parse/resolve errored).
fn buildSnapshot(gpa: Allocator, io: Io, dir_abs: []const u8, overlays: *const std.StringHashMapUnmanaged([]u8), override: ?resolve.Overlay) !Snapshot {
    const sm = try gpa.create(diagnostics.SourceManager);
    sm.* = diagnostics.SourceManager.init(gpa);
    errdefer {
        sm.deinit();
        gpa.destroy(sm);
    }
    var diags = diagnostics.Diagnostics.init(gpa, sm);
    errdefer diags.deinit();

    // Best-effort: a checkout without a stdlib still works — `std/*` imports
    // then error cleanly and there is no prelude, same as the CLI.
    const std_root = try findStdRoot(gpa, io, dir_abs);
    defer if (std_root) |s| gpa.free(s);

    var project = try resolve.loadProject(gpa, io, &diags, sm, dir_abs, std_root, .{ .map = overlays, .one = override });
    errdefer project.deinit();

    // Owned absolute paths of the root module's files, for URI mapping.
    const root_files = project.module_files.items[@intFromEnum(project.root)];
    const paths = try gpa.alloc([]u8, root_files.len);
    var paths_built: usize = 0;
    errdefer {
        for (paths[0..paths_built]) |p| gpa.free(p);
        gpa.free(paths);
    }
    for (root_files, 0..) |mf, i| {
        paths[i] = try gpa.dupe(u8, sm.path(mf.file));
        paths_built = i + 1;
    }

    var snap = Snapshot{
        .gpa = gpa,
        .dir = try gpa.dupe(u8, dir_abs),
        .paths = paths,
        .sm = sm,
        .diags = diags,
        .project = project,
        .root_id = project.root,
        .ctx = undefined,
        .checked = &.{},
        .checked_ok = false,
    };
    if (snap.diags.hasErrors()) return snap;

    snap.ctx = try check.TypeContext.init(gpa);
    errdefer snap.ctx.deinit();

    const n = project.modules.items.len;
    const checked = try gpa.alloc(check.CheckedModule, n);
    var checked_built: usize = 0;
    errdefer {
        for (checked[0..checked_built]) |*c| c.deinit();
        gpa.free(checked);
    }
    // Check every module in dependency order (imports loaded first, so index
    // order suffices) into one shared context — the same contract
    // `main.zig`'s `buildProject` relies on.
    for (0..n) |i| {
        checked[i] = try check.checkModule(gpa, &snap.diags, &snap.ctx, project.module_files.items[i], &project.modules.items[i], @enumFromInt(i), project.modules.items, false);
        checked_built += 1;
    }
    snap.checked = checked;
    snap.checked_ok = true;
    return snap;
}

// ============================================================================
// AST position lookup
// ============================================================================

const max_walk_depth = 256; // mirrors ast.dump's own recursion cap

/// Smallest node whose span contains `offset` ("touching" semantics: a
/// cursor sitting exactly at a token's end still matches that token, the
/// usual LSP hover/goto-def convention).
fn nodeAt(tree: *const ast.Tree, offset: u32) ast.Index {
    var current: ast.Index = tree.root;
    var depth: u32 = 0;
    while (depth < max_walk_depth) : (depth += 1) {
        var next: ?ast.Index = null;
        for (tree.kids(current)) |child| {
            if (child == ast.none) continue;
            const s = tree.get(child).span;
            if (offset >= s.start and offset <= s.end) {
                next = child;
                break;
            }
        }
        if (next) |nxt| current = nxt else break;
    }
    return current;
}

/// Same walk as `nodeAt`, but records every ancestor from the root down to
/// the smallest containing node — dot-completion needs the immediate parent
/// of the spliced marker identifier to find the enclosing `member` node.
fn nodePath(tree: *const ast.Tree, offset: u32, out: *std.ArrayList(ast.Index), gpa: Allocator) !void {
    var current: ast.Index = tree.root;
    try out.append(gpa, current);
    var depth: u32 = 0;
    while (depth < max_walk_depth) : (depth += 1) {
        var next: ?ast.Index = null;
        for (tree.kids(current)) |child| {
            if (child == ast.none) continue;
            const s = tree.get(child).span;
            if (offset >= s.start and offset <= s.end) {
                next = child;
                break;
            }
        }
        const nxt = next orelse break;
        try out.append(gpa, nxt);
        current = nxt;
    }
}

/// The identifier span to highlight for a symbol's declaring node: the name
/// child for the declaration shapes whose `Symbol.decl` is the whole
/// construct (func/struct/interface/type_alias — see `resolve.zig`'s
/// `collectTopLevel`), or the node's own span otherwise (let/const bindings,
/// params, receivers, generics, imports already point straight at the name).
fn defNameSpan(tree: *const ast.Tree, decl: ast.Index) Span {
    const n = tree.get(decl);
    return switch (n.tag) {
        .func_decl => tree.get(tree.kids(decl)[1]).span,
        .struct_decl, .interface_decl, .type_alias => tree.get(tree.kids(decl)[0]).span,
        else => n.span,
    };
}

// ============================================================================
// Hover
// ============================================================================

fn symbolKindLabel(k: resolve.SymbolKind) []const u8 {
    return switch (k) {
        .let_binding => "let",
        .const_binding => "const",
        .param => "param",
        .receiver => "receiver",
        .generic_param => "type param",
        .func => "func",
        .type_alias => "type",
        .struct_type => "struct",
        .interface_type => "interface",
        .enum_type => "enum",
        .import_namespace, .import_item => "import",
        .builtin_type => "type",
        .builtin_func => "func",
        .poison => "?",
    };
}

/// Builds hover markdown for `node` in the root module's `file_idx`: `kind name`
/// from the symbol it resolves to (if any), `: type` from the checker's own
/// per-node type map (if any), and the nearest doc comment above the
/// *declaring* node (if any). Returns `null` when neither is available (an
/// unresolved/untyped node, or a snapshot that never got that far).
fn hoverText(gpa: Allocator, snap: *const Snapshot, file_idx: usize, node: ast.Index) !?[]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);

    const sym_id = snap.rootModule().node_symbols[file_idx][node];
    const sym: ?resolve.Symbol = if (sym_id != .none) snap.rootModule().symbols.items[@intFromEnum(sym_id)] else null;

    if (sym) |s| {
        try buf.appendSlice(gpa, symbolKindLabel(s.kind));
        try buf.appendSlice(gpa, " ");
        try buf.appendSlice(gpa, s.name);
    }

    if (snap.checked_ok) {
        const ty = snap.rootChecked().typeOf(file_idx, node);
        if (ty != .invalid) {
            const nc = check.NameCtx{ .gpa = gpa, .ctx = &snap.ctx, .module_id = snap.root_id, .module = snap.rootModule(), .all_modules = snap.project.modules.items };
            const type_text = try check.describeType(nc, ty);
            defer gpa.free(type_text);
            if (buf.items.len == 0) {
                const src = snap.srcOf(file_idx);
                const span = snap.treeOf(file_idx).get(node).span;
                try buf.appendSlice(gpa, src[span.start..span.end]);
            }
            try buf.appendSlice(gpa, ": ");
            try buf.appendSlice(gpa, type_text);
        }
    }

    if (buf.items.len == 0) {
        buf.deinit(gpa);
        return null;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "```bit\n");
    try out.appendSlice(gpa, buf.items);
    try out.appendSlice(gpa, "\n```");
    buf.deinit(gpa);

    if (sym) |s| {
        // A real `decl` within the root module carries a doc comment; prelude/
        // imported symbols have `decl == none` (their `file_idx` belongs to
        // another module), so they're skipped rather than mis-indexed.
        if (s.decl != ast.none and s.file_idx < snap.rootFiles().len) {
            if (try docCommentFor(gpa, snap.srcOf(s.file_idx), snap.treeOf(s.file_idx).get(s.decl).span.start)) |doc| {
                defer gpa.free(doc);
                try out.appendSlice(gpa, "\n\n");
                try out.appendSlice(gpa, doc);
            }
        }
    }
    return try out.toOwnedSlice(gpa);
}

/// Nearest comment immediately above `decl_start` (no blank line in
/// between), merging contiguous `//` lines upward into one block. `null` if
/// there is none. Re-derives comments via `fmt.collectComments` since the
/// lexer treats them as pure trivia (never tokenized, per its own tests).
fn docCommentFor(gpa: Allocator, source: []const u8, decl_start: u32) !?[]u8 {
    const comments = try fmt.collectComments(gpa, source);
    defer gpa.free(comments);
    if (comments.len == 0) return null;

    var last: ?usize = null;
    for (comments, 0..) |c, i| {
        if (c.span.end > decl_start) break;
        if (noBlankLineBetween(source, c.span.end, decl_start)) last = i;
    }
    const anchor = last orelse return null;

    var first_idx = anchor;
    while (first_idx > 0 and comments[first_idx].kind == .line and comments[anchor].kind == .line and
        noBlankLineBetween(source, comments[first_idx - 1].span.end, comments[first_idx].span.start))
    {
        first_idx -= 1;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (comments[first_idx .. anchor + 1], 0..) |c, i| {
        if (i != 0) try out.appendSlice(gpa, "\n");
        try out.appendSlice(gpa, std.mem.trim(u8, commentBody(source, c), " \t"));
    }
    return try out.toOwnedSlice(gpa);
}

fn commentBody(source: []const u8, c: anytype) []const u8 {
    const text = source[c.span.start..c.span.end];
    return switch (c.kind) {
        .line => std.mem.trim(u8, text[2..], " \t"),
        .block => std.mem.trim(u8, text[2 .. text.len - @min(@as(usize, 2), text.len - 2)], " \t\n"),
    };
}

fn noBlankLineBetween(source: []const u8, a: u32, b: u32) bool {
    if (b <= a) return true;
    var newlines: u32 = 0;
    for (source[a..b]) |c| {
        if (c == '\n') newlines += 1;
        if (newlines > 1) return false;
    }
    return true;
}

// ============================================================================
// Document symbols
// ============================================================================

fn completionKind(k: resolve.SymbolKind) u32 {
    return switch (k) {
        .func, .builtin_func => 3, // Function
        .struct_type => 22, // Struct
        .interface_type => 8, // Interface
        .type_alias, .builtin_type => 7, // Class
        .const_binding => 21, // Constant
        .import_namespace, .import_item => 9, // Module
        else => 6, // Variable
    };
}

const completion_kind_field = 5; // Field
const completion_kind_method = 2; // Method

fn symbolInfoKind(tag: ast.Tag, has_receiver: bool) u32 {
    return switch (tag) {
        .func_decl => if (has_receiver) @as(u32, 6) else @as(u32, 12), // Method : Function
        .struct_decl => 23, // Struct
        .interface_decl => 11, // Interface
        .type_alias => 5, // Class
        .const_decl => 14, // Constant
        else => 13, // Variable
    };
}

fn collectDocumentSymbols(gpa: Allocator, tree: *const ast.Tree, source: []const u8, uri: []const u8, out: *std.ArrayList(SymbolInformation)) !void {
    for (tree.kids(tree.root)) |decl| try addTopSymbol(gpa, tree, source, uri, decl, out);
}

fn addTopSymbol(gpa: Allocator, tree: *const ast.Tree, source: []const u8, uri: []const u8, node_in: ast.Index, out: *std.ArrayList(SymbolInformation)) !void {
    if (node_in == ast.none) return;
    var node = node_in;
    if (tree.get(node).tag == .@"export") {
        node = tree.kids(node)[0];
        if (node == ast.none) return;
    }
    const n = tree.get(node);
    switch (n.tag) {
        .func_decl => {
            const kids = tree.kids(node);
            try appendSymbol(gpa, tree, source, uri, kids[1], symbolInfoKind(.func_decl, kids[0] != ast.none), out);
        },
        .struct_decl => try appendSymbol(gpa, tree, source, uri, tree.kids(node)[0], symbolInfoKind(.struct_decl, false), out),
        .interface_decl => try appendSymbol(gpa, tree, source, uri, tree.kids(node)[0], symbolInfoKind(.interface_decl, false), out),
        .type_alias => try appendSymbol(gpa, tree, source, uri, tree.kids(node)[0], symbolInfoKind(.type_alias, false), out),
        .let_decl, .const_decl => {
            const kind = symbolInfoKind(n.tag, false);
            for (tree.kids(node)) |binding| {
                if (binding == ast.none) continue;
                try appendPatternSymbols(gpa, tree, source, uri, tree.kids(binding)[0], kind, out);
            }
        },
        else => {},
    }
}

fn appendPatternSymbols(gpa: Allocator, tree: *const ast.Tree, source: []const u8, uri: []const u8, pat: ast.Index, kind: u32, out: *std.ArrayList(SymbolInformation)) !void {
    if (pat == ast.none) return;
    if (tree.get(pat).tag == .tuple_pat) {
        for (tree.kids(pat)) |sub| try appendPatternSymbols(gpa, tree, source, uri, sub, kind, out);
        return;
    }
    try appendSymbol(gpa, tree, source, uri, pat, kind, out);
}

fn appendSymbol(gpa: Allocator, tree: *const ast.Tree, source: []const u8, uri: []const u8, name_node: ast.Index, kind: u32, out: *std.ArrayList(SymbolInformation)) !void {
    if (name_node == ast.none) return;
    const span = tree.get(name_node).span;
    const name = source[span.start..span.end];
    if (std.mem.eql(u8, name, "_")) return;
    try out.append(gpa, .{
        .name = name,
        .kind = kind,
        .location = .{ .uri = uri, .range = spanToRange(source, span) },
    });
}

// ============================================================================
// Diagnostics
// ============================================================================

fn writeLspDiagnostic(w: *Io.Writer, source: []const u8, d: diagnostics.Diagnostic) !void {
    const range = spanToRange(source, d.span);
    var code_buf: [5]u8 = undefined;
    try w.print("{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"severity\":{d},\"code\":", .{
        range.start.line, range.start.character, range.end.line, range.end.character, lspSeverity(d.severity),
    });
    try json.Stringify.encodeJsonString(d.code.string(&code_buf), .{}, w);
    try w.writeAll(",\"source\":\"bitls\",\"message\":");
    try json.Stringify.encodeJsonString(d.message, .{}, w);
    try w.writeAll("}");
}

fn lspSeverity(s: diagnostics.Severity) u32 {
    return switch (s) {
        .err => 1,
        .warning => 2,
        .note => 4, // Hint
    };
}

// ============================================================================
// Position <-> byte-offset conversion (UTF-16 code units, per LSP)
// ============================================================================

fn byteOffsetToUtf16Position(source: []const u8, offset: u32) Position {
    var line: u32 = 0;
    var line_start: u32 = 0;
    var i: u32 = 0;
    while (i < offset) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    var character: u32 = 0;
    var j = line_start;
    while (j < offset) {
        const len = std.unicode.utf8ByteSequenceLength(source[j]) catch 1;
        const clamped: u32 = @min(len, offset - j);
        const cp = std.unicode.utf8Decode(source[j .. j + clamped]) catch null;
        character += if (cp != null and cp.? > 0xFFFF) 2 else 1;
        j += clamped;
    }
    return .{ .line = line, .character = character };
}

fn utf16ToByteOffset(source: []const u8, pos: Position) u32 {
    var line: u32 = 0;
    var i: u32 = 0;
    while (line < pos.line and i < source.len) : (i += 1) {
        if (source[i] == '\n') line += 1;
    }
    var character: u32 = 0;
    while (character < pos.character and i < source.len and source[i] != '\n') {
        const len = std.unicode.utf8ByteSequenceLength(source[i]) catch 1;
        const clamped: u32 = @min(len, @as(u32, @intCast(source.len)) - i);
        const cp = std.unicode.utf8Decode(source[i .. i + clamped]) catch null;
        character += if (cp != null and cp.? > 0xFFFF) 2 else 1;
        i += clamped;
    }
    return i;
}

fn spanToRange(source: []const u8, span: Span) Range {
    return .{ .start = byteOffsetToUtf16Position(source, span.start), .end = byteOffsetToUtf16Position(source, span.end) };
}

// ============================================================================
// URI <-> filesystem path
// ============================================================================

fn uriToPath(gpa: Allocator, uri: []const u8) ![]u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return error.UnsupportedUriScheme;
    return percentDecode(gpa, uri[prefix.len..]);
}

fn pathToUri(gpa: Allocator, path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "file://");
    for (path) |c| {
        if (isUnreservedUriByte(c)) {
            try out.append(gpa, c);
        } else {
            const hex = "0123456789ABCDEF";
            try out.append(gpa, '%');
            try out.append(gpa, hex[c >> 4]);
            try out.append(gpa, hex[c & 0xF]);
        }
    }
    return out.toOwnedSlice(gpa);
}

fn isUnreservedUriByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or switch (c) {
        '-', '.', '_', '~', '/' => true,
        else => false,
    };
}

fn percentDecode(gpa: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch null;
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch null;
            if (hi != null and lo != null) {
                try out.append(gpa, (hi.? << 4) | lo.?);
                i += 3;
                continue;
            }
        }
        try out.append(gpa, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

// ============================================================================
// JSON-RPC value helpers (parsing loosely-typed `params`)
// ============================================================================

fn objGet(v: json.Value, key: []const u8) ?json.Value {
    return switch (v) {
        .object => |o| o.get(key),
        else => null,
    };
}

fn objField(v: json.Value, key: []const u8) ?json.Value {
    return objGet(v, key);
}

fn strField(v: json.Value, key: []const u8) ?[]const u8 {
    const f = objGet(v, key) orelse return null;
    return switch (f) {
        .string => |s| s,
        else => null,
    };
}

fn intField(v: json.Value, key: []const u8) ?i64 {
    const f = objGet(v, key) orelse return null;
    return switch (f) {
        .integer => |n| n,
        .float => |f2| @intFromFloat(f2),
        else => null,
    };
}

fn parsePosition(v: json.Value) ?Position {
    const line = intField(v, "line") orelse return null;
    const character = intField(v, "character") orelse return null;
    if (line < 0 or character < 0) return null;
    return .{ .line = @intCast(line), .character = @intCast(character) };
}

const TextDocumentPosition = struct { uri: []const u8, pos: Position };

fn parseTextDocumentPosition(params: json.Value) ?TextDocumentPosition {
    const doc = objField(params, "textDocument") orelse return null;
    const uri = strField(doc, "uri") orelse return null;
    const pos_v = objField(params, "position") orelse return null;
    const pos = parsePosition(pos_v) orelse return null;
    return .{ .uri = uri, .pos = pos };
}

// ============================================================================
// JSON-RPC response helpers and output shapes
// ============================================================================

fn respondRaw(gpa: Allocator, out: *Io.Writer, id: json.Value, result_json: []const u8) !void {
    var msg: Io.Writer.Allocating = .init(gpa);
    defer msg.deinit();
    try msg.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try json.Stringify.value(id, .{}, &msg.writer);
    try msg.writer.writeAll(",\"result\":");
    try msg.writer.writeAll(result_json);
    try msg.writer.writeAll("}");
    try writeFramed(out, msg.written());
}

fn respondValue(gpa: Allocator, out: *Io.Writer, id: json.Value, result: anytype) !void {
    var msg: Io.Writer.Allocating = .init(gpa);
    defer msg.deinit();
    try msg.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try json.Stringify.value(id, .{}, &msg.writer);
    try msg.writer.writeAll(",\"result\":");
    try json.Stringify.value(result, .{ .emit_null_optional_fields = false }, &msg.writer);
    try msg.writer.writeAll("}");
    try writeFramed(out, msg.written());
}

fn respondError(gpa: Allocator, out: *Io.Writer, id: json.Value, code: i32, message: []const u8) !void {
    var msg: Io.Writer.Allocating = .init(gpa);
    defer msg.deinit();
    try msg.writer.writeAll("{\"jsonrpc\":\"2.0\",\"id\":");
    try json.Stringify.value(id, .{}, &msg.writer);
    try msg.writer.print(",\"error\":{{\"code\":{d},\"message\":", .{code});
    try json.Stringify.encodeJsonString(message, .{}, &msg.writer);
    try msg.writer.writeAll("}}");
    try writeFramed(out, msg.written());
}

const Position = struct { line: u32, character: u32 };
const Range = struct { start: Position, end: Position };
const Location = struct { uri: []const u8, range: Range };
const MarkupContent = struct { kind: []const u8 = "markdown", value: []const u8 };
const Hover = struct { contents: MarkupContent };
const SymbolInformation = struct { name: []const u8, kind: u32, location: Location };
const CompletionItem = struct { label: []const u8, kind: u32, detail: ?[]const u8 = null };
const CompletionList = struct { isIncomplete: bool = false, items: []const CompletionItem };

const ServerCapabilities = struct {
    textDocumentSync: u32 = 1, // Full
    hoverProvider: bool = true,
    definitionProvider: bool = true,
    documentSymbolProvider: bool = true,
    completionProvider: struct { triggerCharacters: []const []const u8 = &.{"."} } = .{},
};
const ServerInfo = struct { name: []const u8 = "bitls", version: []const u8 = "0.0.0" };
const InitializeResult = struct {
    capabilities: ServerCapabilities = .{},
    serverInfo: ServerInfo = .{},
};

// ============================================================================
// Tests: scripted JSON-RPC sessions over a real temp directory
// ============================================================================

const testing = std.testing;

/// A `Server` wired directly to an in-memory output buffer instead of real
/// stdio — lets a test drive a full request/response/notification sequence
/// (`open doc -> diagnostic arrives`, `hover -> type string`, ...) without a
/// subprocess. `notify`'s real target (`writeOut`) is bypassed here; tests
/// call the request/notification handlers directly with this session's `out`.
const TestSession = struct {
    gpa: Allocator,
    io: Io,
    server: Server,
    out: Io.Writer.Allocating,

    fn init(gpa: Allocator, io: Io) TestSession {
        return .{ .gpa = gpa, .io = io, .server = Server.init(gpa, io), .out = .init(gpa) };
    }

    fn deinit(self: *TestSession) void {
        self.server.deinit();
        self.out.deinit();
    }

    /// Sends one JSON-RPC message (already-built body) through the exact
    /// `handleMessage` entry point the real stdio loop uses, appending any
    /// framed replies to `self.out`.
    fn send(self: *TestSession, body: []const u8) !void {
        try self.server.handleMessage(body, &self.out.writer);
    }

    /// Pops every complete framed message currently in `self.out` and clears
    /// it, so each assertion only sees what the most recent `send` produced.
    fn drain(self: *TestSession) ![][]u8 {
        var msgs: std.ArrayList([]u8) = .empty;
        defer msgs.deinit(self.gpa);
        var pos: usize = 0;
        const buf = self.out.written();
        while (pos < buf.len) {
            const header_end = std.mem.indexOfPos(u8, buf, pos, "\r\n\r\n") orelse break;
            const header = buf[pos..header_end];
            const prefix = "Content-Length: ";
            std.debug.assert(std.mem.startsWith(u8, header, prefix));
            const len = try std.fmt.parseInt(usize, header[prefix.len..], 10);
            const body_start = header_end + 4;
            try msgs.append(self.gpa, try self.gpa.dupe(u8, buf[body_start .. body_start + len]));
            pos = body_start + len;
        }
        self.out.clearRetainingCapacity();
        return msgs.toOwnedSlice(self.gpa);
    }
};

fn freeMsgs(gpa: Allocator, msgs: [][]u8) void {
    for (msgs) |m| gpa.free(m);
    gpa.free(msgs);
}

/// Creates an absolute temp directory under the build's own cache dir (never
/// touches the real filesystem outside it) and returns its absolute path
/// (owned) plus an `Io.Dir` handle open on it.
fn makeTestDir(gpa: Allocator, io: Io, name: []const u8) !struct { abs: []u8, dir: Io.Dir } {
    const rel = try std.fs.path.join(gpa, &.{ ".zig-cache", "tmp", name });
    defer gpa.free(rel);
    try Io.Dir.cwd().createDirPath(io, rel);
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try Io.Dir.cwd().realPathFile(io, rel, &buf);
    const abs = try gpa.dupe(u8, buf[0..len]);
    const dir = try Io.Dir.openDirAbsolute(io, abs, .{ .iterate = true });
    return .{ .abs = abs, .dir = dir };
}

fn writeTestFile(io: Io, dir: Io.Dir, name: []const u8, contents: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = name, .data = contents });
}

test "readMessage parses Content-Length framing" {
    const gpa = testing.allocator;
    const raw = "Content-Length: 13\r\n\r\n{\"a\":\"body!\"}";
    var reader_state: Io.Reader = .fixed(raw);
    const body = try readMessage(gpa, &reader_state);
    defer gpa.free(body);
    try testing.expectEqualStrings("{\"a\":\"body!\"}", body);
}

test "utf16 position <-> byte offset round-trips ASCII" {
    const source = "let x = 1\nlet yy = 2\n";
    const pos = byteOffsetToUtf16Position(source, 14); // 'y' of "yy"
    try testing.expectEqual(@as(u32, 1), pos.line);
    try testing.expectEqual(@as(u32, 4), pos.character);
    try testing.expectEqual(@as(u32, 14), utf16ToByteOffset(source, pos));
}

test "uriToPath / pathToUri round-trip" {
    const gpa = testing.allocator;
    const path = try uriToPath(gpa, "file:///tmp/a%20b/x.bit");
    defer gpa.free(path);
    try testing.expectEqualStrings("/tmp/a b/x.bit", path);
    const uri = try pathToUri(gpa, path);
    defer gpa.free(uri);
    try testing.expectEqualStrings("file:///tmp/a%20b/x.bit", uri);
}

test "session: open a doc with a type error, get a diagnostic" {
    const gpa = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    var tmp = try makeTestDir(gpa, io, "bitls_diag");
    defer gpa.free(tmp.abs);
    defer tmp.dir.close(io);
    try writeTestFile(io, tmp.dir, "main.bit", "let x: i32 = \"nope\"\n");

    var session = TestSession.init(gpa, io);
    defer session.deinit();

    const main_path = try std.fs.path.join(gpa, &.{ tmp.abs, "main.bit" });
    defer gpa.free(main_path);
    const uri = try pathToUri(gpa, main_path);
    defer gpa.free(uri);

    var body: Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try body.writer.print(
        "{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{{\"textDocument\":{{\"uri\":\"{s}\",\"text\":\"let x: i32 = \\\"nope\\\"\\n\"}}}}}}",
        .{uri},
    );
    try session.send(body.written());

    const msgs = try session.drain();
    defer freeMsgs(gpa, msgs);
    try testing.expectEqual(@as(usize, 1), msgs.len);
    try testing.expect(std.mem.indexOf(u8, msgs[0], "publishDiagnostics") != null);
    try testing.expect(std.mem.indexOf(u8, msgs[0], "\"severity\":1") != null);
}

/// Sends `textDocument/didOpen` and discards its `publishDiagnostics`
/// notification, so callers only see the reply to whatever they send next.
fn didOpen(gpa: Allocator, session: *TestSession, uri: []const u8, text: []const u8) !void {
    var body: Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try body.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":");
    try json.Stringify.encodeJsonString(uri, .{}, &body.writer);
    try body.writer.writeAll(",\"text\":");
    try json.Stringify.encodeJsonString(text, .{}, &body.writer);
    try body.writer.writeAll("}}}");
    try session.send(body.written());
    freeMsgs(gpa, try session.drain());
}

/// Sends one JSON-RPC request (`params_json` is a pre-built fragment) and
/// returns its framed reply message(s).
fn request(gpa: Allocator, session: *TestSession, id: i64, method: []const u8, params_json: []const u8) ![][]u8 {
    var body: Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try body.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":", .{id});
    try json.Stringify.encodeJsonString(method, .{}, &body.writer);
    try body.writer.writeAll(",\"params\":");
    try body.writer.writeAll(params_json);
    try body.writer.writeAll("}");
    try session.send(body.written());
    return session.drain();
}

/// `{"textDocument":{"uri":...},"position":{"line":L,"character":C}}` for
/// the 0-based UTF-16 position of byte `offset` in `text`.
fn positionParams(gpa: Allocator, uri: []const u8, text: []const u8, offset: u32) ![]u8 {
    const pos = byteOffsetToUtf16Position(text, offset);
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll("{\"textDocument\":{\"uri\":");
    try json.Stringify.encodeJsonString(uri, .{}, &out.writer);
    try out.writer.print("}},\"position\":{{\"line\":{d},\"character\":{d}}}}}", .{ pos.line, pos.character });
    return try out.toOwnedSlice();
}

test "session: prelude names and std imports resolve without false errors" {
    // Regression: the server used to check each file in isolation (no prelude,
    // no imports), so `println` and `std/*` imports squiggled as undefined.
    // Loading the whole project (prelude + stdlib) clears them. Anchored to the
    // repo's real `stdlib/`, discovered by walking up from the temp dir.
    const gpa = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    var tmp = try makeTestDir(gpa, io, "bitls_prelude");
    defer gpa.free(tmp.abs);
    defer tmp.dir.close(io);
    const text =
        \\import { sqrt } from "std/math"
        \\function main() {
        \\  let d = sqrt(9.0)
        \\  println("d = ${d}")
        \\}
        \\
    ;
    try writeTestFile(io, tmp.dir, "main.bit", text);

    var session = TestSession.init(gpa, io);
    defer session.deinit();
    const main_path = try std.fs.path.join(gpa, &.{ tmp.abs, "main.bit" });
    defer gpa.free(main_path);
    const uri = try pathToUri(gpa, main_path);
    defer gpa.free(uri);

    var body: Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    try body.writer.writeAll("{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/didOpen\",\"params\":{\"textDocument\":{\"uri\":");
    try json.Stringify.encodeJsonString(uri, .{}, &body.writer);
    try body.writer.writeAll(",\"text\":");
    try json.Stringify.encodeJsonString(text, .{}, &body.writer);
    try body.writer.writeAll("}}}");
    try session.send(body.written());

    const msgs = try session.drain();
    defer freeMsgs(gpa, msgs);
    // Exactly one publishDiagnostics (for main.bit — never for the stdlib
    // files), carrying an empty diagnostics array.
    try testing.expectEqual(@as(usize, 1), msgs.len);
    try testing.expect(std.mem.indexOf(u8, msgs[0], "publishDiagnostics") != null);
    try testing.expect(std.mem.indexOf(u8, msgs[0], "\"diagnostics\":[]") != null);
}

test "session: scope completion includes prelude names" {
    const gpa = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    var tmp = try makeTestDir(gpa, io, "bitls_scope_completion");
    defer gpa.free(tmp.abs);
    defer tmp.dir.close(io);
    const text = "function main() {\n  \n}\n";
    try writeTestFile(io, tmp.dir, "main.bit", text);

    var session = TestSession.init(gpa, io);
    defer session.deinit();
    const main_path = try std.fs.path.join(gpa, &.{ tmp.abs, "main.bit" });
    defer gpa.free(main_path);
    const uri = try pathToUri(gpa, main_path);
    defer gpa.free(uri);
    try didOpen(gpa, &session, uri, text);

    // A non-`.` completion inside the function body lists module scope, which
    // now includes the auto-imported prelude (`println`).
    const offset: u32 = @intCast(std.mem.indexOf(u8, text, "  \n").? + 2);
    const params = try positionParams(gpa, uri, text, offset);
    defer gpa.free(params);

    const msgs = try request(gpa, &session, 4, "textDocument/completion", params);
    defer freeMsgs(gpa, msgs);
    try testing.expectEqual(@as(usize, 1), msgs.len);
    try testing.expect(std.mem.indexOf(u8, msgs[0], "\"println\"") != null);
}

test "session: hover on an inferred let shows its type" {
    const gpa = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    var tmp = try makeTestDir(gpa, io, "bitls_hover");
    defer gpa.free(tmp.abs);
    defer tmp.dir.close(io);
    const text = "let x = 5\n";
    try writeTestFile(io, tmp.dir, "main.bit", text);

    var session = TestSession.init(gpa, io);
    defer session.deinit();
    const main_path = try std.fs.path.join(gpa, &.{ tmp.abs, "main.bit" });
    defer gpa.free(main_path);
    const uri = try pathToUri(gpa, main_path);
    defer gpa.free(uri);
    try didOpen(gpa, &session, uri, text);

    const offset: u32 = @intCast(std.mem.indexOf(u8, text, "x").?);
    const params = try positionParams(gpa, uri, text, offset);
    defer gpa.free(params);

    const msgs = try request(gpa, &session, 1, "textDocument/hover", params);
    defer freeMsgs(gpa, msgs);
    try testing.expectEqual(@as(usize, 1), msgs.len);
    // §15.4: an untyped integer constant's default type is `int` (`i64`).
    try testing.expect(std.mem.indexOf(u8, msgs[0], "let x: i64") != null);
}

test "session: goto-definition crosses files in the same directory" {
    const gpa = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    var tmp = try makeTestDir(gpa, io, "bitls_def");
    defer gpa.free(tmp.abs);
    defer tmp.dir.close(io);
    try writeTestFile(io, tmp.dir, "a.bit", "function greet(): string {\n  return \"hi\"\n}\n");
    const b_text = "let msg = greet()\n";
    try writeTestFile(io, tmp.dir, "b.bit", b_text);

    var session = TestSession.init(gpa, io);
    defer session.deinit();
    const a_path = try std.fs.path.join(gpa, &.{ tmp.abs, "a.bit" });
    defer gpa.free(a_path);
    const a_uri = try pathToUri(gpa, a_path);
    defer gpa.free(a_uri);
    const b_path = try std.fs.path.join(gpa, &.{ tmp.abs, "b.bit" });
    defer gpa.free(b_path);
    const b_uri = try pathToUri(gpa, b_path);
    defer gpa.free(b_uri);
    try didOpen(gpa, &session, b_uri, b_text);

    const offset: u32 = @intCast(std.mem.indexOf(u8, b_text, "greet").?);
    const params = try positionParams(gpa, b_uri, b_text, offset);
    defer gpa.free(params);

    const msgs = try request(gpa, &session, 2, "textDocument/definition", params);
    defer freeMsgs(gpa, msgs);
    try testing.expectEqual(@as(usize, 1), msgs.len);
    try testing.expect(std.mem.indexOf(u8, msgs[0], a_uri) != null);
}

test "session: completion after '.' lists interface methods" {
    const gpa = testing.allocator;
    const io = Io.Threaded.global_single_threaded.io();
    var tmp = try makeTestDir(gpa, io, "bitls_completion");
    defer gpa.free(tmp.abs);
    defer tmp.dir.close(io);
    const text =
        \\interface Greeter {
        \\  greet(): string
        \\  wave(): string
        \\}
        \\struct Bot { name: string }
        \\function (b: Bot) greet(): string { return b.name }
        \\function (b: Bot) wave(): string { return b.name }
        \\let g: Greeter = Bot{name: "Ada"}
        \\let y = g.
    ;
    try writeTestFile(io, tmp.dir, "main.bit", text);

    var session = TestSession.init(gpa, io);
    defer session.deinit();
    const main_path = try std.fs.path.join(gpa, &.{ tmp.abs, "main.bit" });
    defer gpa.free(main_path);
    const uri = try pathToUri(gpa, main_path);
    defer gpa.free(uri);
    try didOpen(gpa, &session, uri, text);

    const dot = std.mem.lastIndexOfScalar(u8, text, '.').?;
    const params = try positionParams(gpa, uri, text, @intCast(dot + 1));
    defer gpa.free(params);

    const msgs = try request(gpa, &session, 3, "textDocument/completion", params);
    defer freeMsgs(gpa, msgs);
    try testing.expectEqual(@as(usize, 1), msgs.len);
    try testing.expect(std.mem.indexOf(u8, msgs[0], "\"greet\"") != null);
    try testing.expect(std.mem.indexOf(u8, msgs[0], "\"wave\"") != null);
}
