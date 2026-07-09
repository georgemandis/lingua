// LSP server for lingua: JSON-RPC framing, dispatch, and diagnostics.
const std = @import("std");

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
