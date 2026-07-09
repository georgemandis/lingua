// LSP server for lingua: JSON-RPC framing, dispatch, and diagnostics.
const std = @import("std");
const nlp = @import("nlp");

// ---------------------------------------------------------------------------
// Offset conversion (UTF-16 code units -> LSP line/character)
// ---------------------------------------------------------------------------

pub const Position = struct {
    line: u32,
    character: u32,
};

/// Maps absolute UTF-16 code-unit offsets to LSP line/character positions.
/// Lines split on '\n'; characters count UTF-16 code units (LSP default).
pub const LineIndex = struct {
    /// UTF-16 offset at which each line starts. starts[0] is always 0.
    starts: []u32,
    /// Total document length in UTF-16 code units.
    total: u32,

    pub fn build(allocator: std.mem.Allocator, text: []const u8) !LineIndex {
        var starts: std.ArrayList(u32) = .empty;
        errdefer starts.deinit(allocator);
        try starts.append(allocator, 0);

        var utf16: u32 = 0;
        var i: usize = 0;
        while (i < text.len) {
            const b = text[i];
            if (b == '\n') {
                utf16 += 1;
                i += 1;
                try starts.append(allocator, utf16);
                continue;
            }
            // UTF-8 sequence length from the lead byte; invalid bytes count
            // as one unit so bad input never crashes the server.
            const seq_len: usize = if (b < 0x80) 1 else if (b >= 0xF0) 4 else if (b >= 0xE0) 3 else if (b >= 0xC0) 2 else 1;
            // Code points >= U+10000 (exactly the 4-byte UTF-8 sequences)
            // take two UTF-16 code units; everything else takes one.
            utf16 += if (seq_len == 4) 2 else 1;
            i += @min(seq_len, text.len - i);
        }

        return .{ .starts = try starts.toOwnedSlice(allocator), .total = utf16 };
    }

    pub fn deinit(self: *LineIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.starts);
    }

    /// Convert an absolute UTF-16 offset to a position. Offsets past the
    /// end of the document clamp to the final position.
    pub fn position(self: LineIndex, offset: u32) Position {
        const off = @min(offset, self.total);
        // Binary search: last line start <= off.
        var lo: usize = 0;
        var hi: usize = self.starts.len;
        while (hi - lo > 1) {
            const mid = lo + (hi - lo) / 2;
            if (self.starts[mid] <= off) lo = mid else hi = mid;
        }
        return .{ .line = @intCast(lo), .character = off - self.starts[lo] };
    }
};

test "LineIndex: ascii multi-line" {
    const allocator = std.testing.allocator;
    var idx = try LineIndex.build(allocator, "abc\ndef\nghi");
    defer idx.deinit(allocator);
    try std.testing.expectEqual(Position{ .line = 0, .character = 0 }, idx.position(0));
    try std.testing.expectEqual(Position{ .line = 0, .character = 2 }, idx.position(2));
    try std.testing.expectEqual(Position{ .line = 1, .character = 0 }, idx.position(4));
    try std.testing.expectEqual(Position{ .line = 2, .character = 2 }, idx.position(10));
}

test "LineIndex: crlf line endings" {
    const allocator = std.testing.allocator;
    var idx = try LineIndex.build(allocator, "ab\r\ncd");
    defer idx.deinit(allocator);
    // \r is one UTF-16 unit inside line 0; \n ends the line.
    try std.testing.expectEqual(Position{ .line = 0, .character = 2 }, idx.position(2));
    try std.testing.expectEqual(Position{ .line = 1, .character = 0 }, idx.position(4));
    try std.testing.expectEqual(Position{ .line = 1, .character = 1 }, idx.position(5));
}

test "LineIndex: emoji before offset on same line" {
    const allocator = std.testing.allocator;
    // U+1F389 is 4 bytes UTF-8 but 2 UTF-16 units.
    var idx = try LineIndex.build(allocator, "\u{1F389} recieve");
    defer idx.deinit(allocator);
    try std.testing.expectEqual(Position{ .line = 0, .character = 3 }, idx.position(3));
}

test "LineIndex: emoji on an earlier line" {
    const allocator = std.testing.allocator;
    var idx = try LineIndex.build(allocator, "\u{1F389}\nrecieve");
    defer idx.deinit(allocator);
    try std.testing.expectEqual(Position{ .line = 1, .character = 0 }, idx.position(3));
    try std.testing.expectEqual(Position{ .line = 1, .character = 4 }, idx.position(7));
}

test "LineIndex: offset at exact line start and past EOF clamps" {
    const allocator = std.testing.allocator;
    var idx = try LineIndex.build(allocator, "abc\nd");
    defer idx.deinit(allocator);
    try std.testing.expectEqual(Position{ .line = 1, .character = 0 }, idx.position(4));
    try std.testing.expectEqual(Position{ .line = 1, .character = 1 }, idx.position(999));
}

// ---------------------------------------------------------------------------
// Content-Length framing (LSP base protocol)
// ---------------------------------------------------------------------------

/// Parse a header line (trailing \r allowed). Returns the length for a
/// Content-Length header, null for any other header or a malformed value.
pub fn parseContentLength(line: []const u8) ?usize {
    const trimmed = std.mem.trimEnd(u8, line, "\r");
    const prefix = "Content-Length:";
    if (!std.ascii.startsWithIgnoreCase(trimmed, prefix)) return null;
    const value = std.mem.trim(u8, trimmed[prefix.len..], " \t");
    return std.fmt.parseInt(usize, value, 10) catch null;
}

/// Read one framed message. Returns the owned body, or null on clean EOF
/// at a message boundary. Unknown headers and stray blank lines before the
/// headers are skipped.
pub fn readMessage(allocator: std.mem.Allocator, reader: *std.Io.Reader) !?[]u8 {
    var content_length: ?usize = null;
    while (true) {
        const line = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => return null,
            else => return err,
        };
        // takeDelimiterExclusive leaves the reader positioned before the '\n',
        // so we must consume it with discardDelimiterInclusive.
        _ = reader.discardDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        };
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (trimmed.len == 0) {
            if (content_length != null) break;
            continue; // stray blank line before any headers
        }
        if (parseContentLength(trimmed)) |len| content_length = len;
    }
    const body = try allocator.alloc(u8, content_length.?);
    errdefer allocator.free(body);
    try reader.readSliceAll(body);
    return body;
}

test "parseContentLength: valid, case-insensitive, and invalid" {
    try std.testing.expectEqual(@as(?usize, 42), parseContentLength("Content-Length: 42"));
    try std.testing.expectEqual(@as(?usize, 7), parseContentLength("content-length:7\r"));
    try std.testing.expectEqual(@as(?usize, null), parseContentLength("Content-Type: application/json"));
    try std.testing.expectEqual(@as(?usize, null), parseContentLength("Content-Length: banana"));
}

test "readMessage: single framed message" {
    const allocator = std.testing.allocator;
    var r = std.Io.Reader.fixed("Content-Length: 7\r\n\r\n{\"a\":1}");
    const body = (try readMessage(allocator, &r)).?;
    defer allocator.free(body);
    try std.testing.expectEqualStrings("{\"a\":1}", body);
}

test "readMessage: two messages back-to-back, then EOF" {
    const allocator = std.testing.allocator;
    var r = std.Io.Reader.fixed("Content-Length: 2\r\n\r\nhiContent-Length: 3\r\n\r\nbye");
    const first = (try readMessage(allocator, &r)).?;
    defer allocator.free(first);
    try std.testing.expectEqualStrings("hi", first);
    const second = (try readMessage(allocator, &r)).?;
    defer allocator.free(second);
    try std.testing.expectEqualStrings("bye", second);
    try std.testing.expectEqual(@as(?[]u8, null), try readMessage(allocator, &r));
}

test "readMessage: extra headers and stray blank lines are tolerated" {
    const allocator = std.testing.allocator;
    var r = std.Io.Reader.fixed("\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\nok");
    const body = (try readMessage(allocator, &r)).?;
    defer allocator.free(body);
    try std.testing.expectEqualStrings("ok", body);
}

test "readMessage: EOF with no message returns null" {
    const allocator = std.testing.allocator;
    var r = std.Io.Reader.fixed("");
    try std.testing.expectEqual(@as(?[]u8, null), try readMessage(allocator, &r));
}

// ---------------------------------------------------------------------------
// JSON output helpers
// ---------------------------------------------------------------------------

pub fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.print("\\\"", .{}),
            '\\' => try writer.print("\\\\", .{}),
            '\n' => try writer.print("\\n", .{}),
            '\r' => try writer.print("\\r", .{}),
            '\t' => try writer.print("\\t", .{}),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => try writer.print("\\u{X:0>4}", .{c}),
            else => try writer.print("{c}", .{c}),
        }
    }
}

fn writeIdValue(writer: *std.Io.Writer, id: std.json.Value) !void {
    switch (id) {
        .integer => |n| try writer.print("{d}", .{n}),
        .string => |s| {
            try writer.print("\"", .{});
            try writeJsonString(writer, s);
            try writer.print("\"", .{});
        },
        else => try writer.print("null", .{}),
    }
}

/// Fetch a member of a JSON object value; null if not an object or missing.
fn getMember(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

pub const Diagnostic = struct {
    start: Position,
    end: Position,
    severity: u8, // 1 = Error (spelling), 2 = Warning (grammar)
    message: []const u8,
    corrections: [][]const u8,
};

const Server = struct {
    allocator: std.mem.Allocator,
    out: *std.Io.Writer,
    version: []const u8,
    initialized: bool = false,
    shutdown_requested: bool = false,
    exit_code: ?u8 = null,
    documents: std.StringHashMap([]const u8),
    stored_diags: std.StringHashMap([]Diagnostic),

    fn deinit(self: *Server) void {
        var doc_it = self.documents.iterator();
        while (doc_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.documents.deinit();
        var diag_it = self.stored_diags.iterator();
        while (diag_it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            freeDiagnostics(self.allocator, entry.value_ptr.*);
        }
        self.stored_diags.deinit();
    }

    fn sendBody(self: *Server, json_body: []const u8) !void {
        try self.out.print("Content-Length: {d}\r\n\r\n{s}", .{ json_body.len, json_body });
    }

    fn respondResult(self: *Server, id: std.json.Value, result_json: []const u8) !void {
        var body: std.Io.Writer.Allocating = .init(self.allocator);
        defer body.deinit();
        try body.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":", .{});
        try writeIdValue(&body.writer, id);
        try body.writer.print(",\"result\":{s}}}", .{result_json});
        try self.sendBody(body.written());
    }

    fn respondError(self: *Server, id: ?std.json.Value, code: i64, message: []const u8) !void {
        var body: std.Io.Writer.Allocating = .init(self.allocator);
        defer body.deinit();
        try body.writer.print("{{\"jsonrpc\":\"2.0\",\"id\":", .{});
        if (id) |i| try writeIdValue(&body.writer, i) else try body.writer.print("null", .{});
        try body.writer.print(",\"error\":{{\"code\":{d},\"message\":\"", .{code});
        try writeJsonString(&body.writer, message);
        try body.writer.print("\"}}}}", .{});
        try self.sendBody(body.written());
    }

    fn handleMessage(self: *Server, body: []const u8) !void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, body, .{}) catch {
            std.debug.print("lingua lsp: malformed JSON, skipping\n", .{});
            return;
        };
        defer parsed.deinit();

        const method_val = getMember(parsed.value, "method") orelse return; // client responses: ignore
        if (method_val != .string) return;
        const method = method_val.string;
        const id = getMember(parsed.value, "id");
        const params = getMember(parsed.value, "params") orelse .null;

        if (std.mem.eql(u8, method, "exit")) {
            self.exit_code = if (self.shutdown_requested) 0 else 1;
            return;
        }

        if (!self.initialized and !std.mem.eql(u8, method, "initialize")) {
            if (id) |i| try self.respondError(i, -32002, "server not initialized");
            return;
        }

        if (std.mem.eql(u8, method, "initialize")) {
            const rid = id orelse return; // initialize is always a request
            self.initialized = true;
            var result: std.Io.Writer.Allocating = .init(self.allocator);
            defer result.deinit();
            try result.writer.print(
                "{{\"capabilities\":{{\"textDocumentSync\":1,\"codeActionProvider\":true,\"positionEncoding\":\"utf-16\"}},\"serverInfo\":{{\"name\":\"lingua\",\"version\":\"{s}\"}}}}",
                .{self.version},
            );
            try self.respondResult(rid, result.written());
        } else if (std.mem.eql(u8, method, "initialized")) {
            // no-op
        } else if (std.mem.eql(u8, method, "shutdown")) {
            const rid = id orelse return;
            self.shutdown_requested = true;
            try self.respondResult(rid, "null");
        } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
            try self.handleDidOpen(params);
        } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
            try self.handleDidChange(params);
        } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
            try self.handleDidClose(params);
        } else if (std.mem.eql(u8, method, "textDocument/codeAction")) {
            if (id) |i| try self.handleCodeAction(i, params);
        } else if (id) |i| {
            try self.respondError(i, -32601, "method not found");
        }
        // Unknown notifications: ignored.
    }

    fn handleDidOpen(self: *Server, params: std.json.Value) !void {
        const td = getMember(params, "textDocument") orelse return;
        const uri_val = getMember(td, "uri") orelse return;
        const text_val = getMember(td, "text") orelse return;
        if (uri_val != .string or text_val != .string) return;
        try self.setDocument(uri_val.string, text_val.string);
        try self.checkAndPublish(uri_val.string);
    }

    fn handleDidChange(self: *Server, params: std.json.Value) !void {
        const td = getMember(params, "textDocument") orelse return;
        const uri_val = getMember(td, "uri") orelse return;
        if (uri_val != .string) return;
        const changes = getMember(params, "contentChanges") orelse return;
        if (changes != .array or changes.array.items.len == 0) return;
        // Full sync: the last change carries the complete new text.
        const last = changes.array.items[changes.array.items.len - 1];
        const text_val = getMember(last, "text") orelse return;
        if (text_val != .string) return;
        try self.setDocument(uri_val.string, text_val.string);
        try self.checkAndPublish(uri_val.string);
    }

    fn handleDidClose(self: *Server, params: std.json.Value) !void {
        const td = getMember(params, "textDocument") orelse return;
        const uri_val = getMember(td, "uri") orelse return;
        if (uri_val != .string) return;
        if (self.documents.fetchRemove(uri_val.string)) |entry| {
            self.allocator.free(entry.key);
            self.allocator.free(entry.value);
        }
        if (self.stored_diags.fetchRemove(uri_val.string)) |entry| {
            self.allocator.free(entry.key);
            freeDiagnostics(self.allocator, entry.value);
        }
        try self.publishDiagnostics(uri_val.string, &.{});
    }

    /// Store (or replace) a document's full text. Keys and values are owned.
    fn setDocument(self: *Server, uri: []const u8, text: []const u8) !void {
        const text_copy = try self.allocator.dupe(u8, text);
        if (self.documents.getEntry(uri)) |entry| {
            self.allocator.free(entry.value_ptr.*);
            entry.value_ptr.* = text_copy;
        } else {
            const key_copy = try self.allocator.dupe(u8, uri);
            try self.documents.put(key_copy, text_copy);
        }
    }

    fn checkAndPublish(self: *Server, uri: []const u8) !void {
        const text = self.documents.get(uri) orelse return;

        const spelling = nlp.checkSpelling(self.allocator, text, null) catch |err| {
            std.debug.print("lingua lsp: spell check failed: {s}\n", .{@errorName(err)});
            try self.storeDiagnosticsOwned(uri, try self.allocator.alloc(Diagnostic, 0));
            return self.publishStored(uri);
        };
        defer nlp.freeSpellingIssues(self.allocator, spelling);
        const grammar = nlp.checkGrammar(self.allocator, text, null) catch |err| {
            std.debug.print("lingua lsp: grammar check failed: {s}\n", .{@errorName(err)});
            try self.storeDiagnosticsOwned(uri, try self.allocator.alloc(Diagnostic, 0));
            return self.publishStored(uri);
        };
        defer nlp.freeGrammarIssues(self.allocator, grammar);

        var idx = try LineIndex.build(self.allocator, text);
        defer idx.deinit(self.allocator);

        var diags: std.ArrayList(Diagnostic) = .empty;
        errdefer {
            for (diags.items) |d| {
                self.allocator.free(d.message);
                for (d.corrections) |c| self.allocator.free(c);
                self.allocator.free(d.corrections);
            }
            diags.deinit(self.allocator);
        }

        for (spelling) |issue| {
            const msg = try std.fmt.allocPrint(self.allocator, "Possibly misspelled: '{s}'", .{issue.word});
            try diags.append(self.allocator, .{
                .start = idx.position(@intCast(issue.range_start)),
                .end = idx.position(@intCast(issue.range_start + issue.range_length)),
                .severity = 1,
                .message = msg,
                .corrections = try dupeStrings(self.allocator, issue.guesses),
            });
        }
        for (grammar) |issue| {
            try diags.append(self.allocator, .{
                .start = idx.position(@intCast(issue.range_start)),
                .end = idx.position(@intCast(issue.range_start + issue.range_length)),
                .severity = 2,
                .message = try self.allocator.dupe(u8, issue.description),
                .corrections = try dupeStrings(self.allocator, issue.corrections),
            });
        }

        const owned = try diags.toOwnedSlice(self.allocator);
        try self.storeDiagnosticsOwned(uri, owned);
        try self.publishStored(uri);
    }

    fn storeDiagnosticsOwned(self: *Server, uri: []const u8, diags: []Diagnostic) !void {
        if (self.stored_diags.getEntry(uri)) |entry| {
            freeDiagnostics(self.allocator, entry.value_ptr.*);
            entry.value_ptr.* = diags;
        } else {
            const key_copy = try self.allocator.dupe(u8, uri);
            try self.stored_diags.put(key_copy, diags);
        }
    }

    fn publishStored(self: *Server, uri: []const u8) !void {
        const diags: []const Diagnostic = self.stored_diags.get(uri) orelse &.{};
        try self.publishDiagnostics(uri, diags);
    }

    fn publishDiagnostics(self: *Server, uri: []const u8, diags: []const Diagnostic) !void {
        var body: std.Io.Writer.Allocating = .init(self.allocator);
        defer body.deinit();
        const w = &body.writer;
        try w.print("{{\"jsonrpc\":\"2.0\",\"method\":\"textDocument/publishDiagnostics\",\"params\":{{\"uri\":\"", .{});
        try writeJsonString(w, uri);
        try w.print("\",\"diagnostics\":[", .{});
        for (diags, 0..) |d, i| {
            if (i > 0) try w.print(",", .{});
            try writeDiagnosticJson(w, d);
        }
        try w.print("]}}}}", .{});
        try self.sendBody(body.written());
    }

    fn handleCodeAction(self: *Server, id: std.json.Value, params: std.json.Value) !void {
        // Malformed params on a request -> InvalidParams, per spec.
        const td = getMember(params, "textDocument") orelse return self.respondError(id, -32602, "invalid params");
        const uri_val = getMember(td, "uri") orelse return self.respondError(id, -32602, "invalid params");
        const range = getMember(params, "range") orelse return self.respondError(id, -32602, "invalid params");
        if (uri_val != .string) return self.respondError(id, -32602, "invalid params");
        const req_start = parsePosition(getMember(range, "start")) orelse return self.respondError(id, -32602, "invalid params");
        const req_end = parsePosition(getMember(range, "end")) orelse return self.respondError(id, -32602, "invalid params");

        const diags = self.stored_diags.get(uri_val.string) orelse return self.respondResult(id, "[]");

        var body: std.Io.Writer.Allocating = .init(self.allocator);
        defer body.deinit();
        const w = &body.writer;
        try w.print("[", .{});
        var first = true;
        for (diags) |d| {
            // Overlap: diagnostic start <= request end AND request start <= diagnostic end.
            if (!posLessEq(d.start, req_end) or !posLessEq(req_start, d.end)) continue;
            for (d.corrections) |correction| {
                if (!first) try w.print(",", .{});
                first = false;
                try w.print("{{\"title\":\"Change to '", .{});
                try writeJsonString(w, correction);
                try w.print("'\",\"kind\":\"quickfix\",\"diagnostics\":[", .{});
                try writeDiagnosticJson(w, d);
                try w.print("],\"edit\":{{\"changes\":{{\"", .{});
                try writeJsonString(w, uri_val.string);
                try w.print("\":[{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"newText\":\"", .{
                    d.start.line, d.start.character, d.end.line, d.end.character,
                });
                try writeJsonString(w, correction);
                try w.print("\"}}]}}}}}}", .{});
            }
        }
        try w.print("]", .{});
        try self.respondResult(id, body.written());
    }
};

fn posLessEq(a: Position, b: Position) bool {
    if (a.line != b.line) return a.line < b.line;
    return a.character <= b.character;
}

fn parsePosition(v: ?std.json.Value) ?Position {
    const pos = v orelse return null;
    const line = getMember(pos, "line") orelse return null;
    const character = getMember(pos, "character") orelse return null;
    if (line != .integer or character != .integer) return null;
    const line_u32 = std.math.cast(u32, line.integer) orelse return null;
    const character_u32 = std.math.cast(u32, character.integer) orelse return null;
    return .{ .line = line_u32, .character = character_u32 };
}

pub fn freeDiagnostics(allocator: std.mem.Allocator, diags: []Diagnostic) void {
    for (diags) |d| {
        allocator.free(d.message);
        for (d.corrections) |c| allocator.free(c);
        allocator.free(d.corrections);
    }
    allocator.free(diags);
}

fn dupeStrings(allocator: std.mem.Allocator, strings: []const []const u8) ![][]const u8 {
    const out = try allocator.alloc([]const u8, strings.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |s| allocator.free(s);
        allocator.free(out);
    }
    for (strings, 0..) |s, i| {
        out[i] = try allocator.dupe(u8, s);
        filled = i + 1;
    }
    return out;
}

pub fn writeDiagnosticJson(w: *std.Io.Writer, d: Diagnostic) !void {
    try w.print("{{\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}},\"end\":{{\"line\":{d},\"character\":{d}}}}},\"severity\":{d},\"source\":\"lingua\",\"message\":\"", .{
        d.start.line, d.start.character, d.end.line, d.end.character, d.severity,
    });
    try writeJsonString(w, d.message);
    try w.print("\",\"data\":{{\"corrections\":[", .{});
    for (d.corrections, 0..) |c, i| {
        if (i > 0) try w.print(",", .{});
        try w.print("\"", .{});
        try writeJsonString(w, c);
        try w.print("\"", .{});
    }
    try w.print("]}}}}", .{});
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn run(allocator: std.mem.Allocator, init: std.process.Init, version: []const u8) !void {
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(init.io, &stdin_buf);
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);

    var server = Server{
        .allocator = allocator,
        .out = &stdout_writer.interface,
        .version = version,
        .documents = std.StringHashMap([]const u8).init(allocator),
        .stored_diags = std.StringHashMap([]Diagnostic).init(allocator),
    };
    defer server.deinit();

    while (server.exit_code == null) {
        const maybe_body = readMessage(allocator, &stdin_reader.interface) catch |err| blk: {
            std.debug.print("lingua lsp: read error: {s}\n", .{@errorName(err)});
            break :blk null;
        };
        const body = maybe_body orelse break; // EOF -> clean exit 0
        defer allocator.free(body);
        server.handleMessage(body) catch |err| {
            std.debug.print("lingua lsp: error handling message: {s}\n", .{@errorName(err)});
        };
        try server.out.flush();
    }
    try server.out.flush();
    std.process.exit(server.exit_code orelse 0);
}
