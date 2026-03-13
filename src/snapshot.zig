const std = @import("std");
const Allocator = std.mem.Allocator;
const Session = @import("Session.zig");
const screen_mod = @import("screen.zig");

// --- Public types ---

pub const Snapshot = struct {
    cols: u16,
    rows: u16,
    cursor_row: u16,
    cursor_col: u16,
    text: []const u8,

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        alloc.free(self.text);
    }
};

pub const SnapshotError = error{
    InvalidFormat,
    ParseFailed,
    DimensionMismatch,
    SnapshotMismatch,
    WriteFailed,
    ReadFailed,
};

// --- Constants ---

const header_prefix = "# tuikit snapshot";

// --- Step 5.1.1: capture ---

/// Capture the current screen state as a Snapshot.
/// Drains the session first to ensure the screen is current.
///
/// Assertions:
/// - session.state == .active
/// Postcondition:
/// - snapshot.rows == session.terminal.rows
pub fn capture(session: *Session, alloc: Allocator) !Snapshot {
    std.debug.assert(session.state == .active);

    // Drain pending output.
    _ = session.drain();

    const pos = session.terminal.cursorPosition();
    const text = try session.terminal.plainText(alloc);

    const result = Snapshot{
        .cols = session.terminal.cols,
        .rows = session.terminal.rows,
        .cursor_row = pos.row,
        .cursor_col = pos.col,
        .text = text,
    };

    // Postcondition.
    std.debug.assert(result.rows == session.terminal.rows);

    return result;
}

// --- Step 5.1.2: diff ---

/// Compare two snapshots and return a human-readable diff string.
/// Returns empty string if identical.
///
/// Assertions:
/// - a.cols == b.cols and a.rows == b.rows
pub fn diff(a: Snapshot, b: Snapshot, alloc: Allocator) ![]const u8 {
    std.debug.assert(a.cols == b.cols);
    std.debug.assert(a.rows == b.rows);

    // Fast path: identical.
    if (std.mem.eql(u8, a.text, b.text) and
        a.cursor_row == b.cursor_row and
        a.cursor_col == b.cursor_col)
    {
        return try alloc.dupe(u8, "");
    }

    var buf: std.ArrayList(u8) = try .initCapacity(alloc, 1024);
    defer buf.deinit(alloc);

    // Compare cursor.
    if (a.cursor_row != b.cursor_row or a.cursor_col != b.cursor_col) {
        const header = try std.fmt.allocPrint(
            alloc,
            "cursor: ({d},{d}) -> ({d},{d})\n",
            .{ a.cursor_row, a.cursor_col, b.cursor_row, b.cursor_col },
        );
        defer alloc.free(header);
        try buf.appendSlice(alloc, header);
    }

    // Line-by-line text comparison.
    var a_iter = std.mem.splitSequence(u8, a.text, "\n");
    var b_iter = std.mem.splitSequence(u8, b.text, "\n");
    var line_num: u16 = 0;

    while (true) {
        const a_line = a_iter.next();
        const b_line = b_iter.next();

        if (a_line == null and b_line == null) break;

        const al = a_line orelse "";
        const bl = b_line orelse "";

        if (!std.mem.eql(u8, al, bl)) {
            const line_diff = try std.fmt.allocPrint(
                alloc,
                "line {d}:\n  - {s}\n  + {s}\n",
                .{ line_num, al, bl },
            );
            defer alloc.free(line_diff);
            try buf.appendSlice(alloc, line_diff);
        }

        line_num += 1;
    }

    return try buf.toOwnedSlice(alloc);
}

// --- Step 5.1.3: save ---

/// Save a snapshot to a file.
///
/// Assertions:
/// - path.len > 0
pub fn save(snap: Snapshot, alloc: Allocator, path: []const u8) !void {
    std.debug.assert(path.len > 0);

    const header = try std.fmt.allocPrint(
        alloc,
        "{s} cols={d} rows={d} cursor={d},{d}\n",
        .{ header_prefix, snap.cols, snap.rows, snap.cursor_row, snap.cursor_col },
    );
    defer alloc.free(header);

    const file = std.fs.cwd().createFile(path, .{}) catch
        return error.WriteFailed;
    defer file.close();

    file.writeAll(header) catch return error.WriteFailed;
    file.writeAll(snap.text) catch return error.WriteFailed;
}

// --- Step 5.1.3: load ---

/// Load a snapshot from a file.
///
/// Assertions:
/// - path.len > 0
pub fn load(alloc: Allocator, path: []const u8) !Snapshot {
    std.debug.assert(path.len > 0);

    // 4MB limit: 500x500 terminal * 4 bytes/char + header overhead.
    const snapshot_file_max: usize = 4 * 1024 * 1024;
    const content = std.fs.cwd().readFileAlloc(alloc, path, snapshot_file_max) catch
        return error.ReadFailed;
    defer alloc.free(content);

    // Parse header line.
    const newline_idx = std.mem.indexOf(u8, content, "\n") orelse
        return error.InvalidFormat;

    const header_line = content[0..newline_idx];
    const text_content = content[newline_idx + 1 ..];

    // Verify header prefix.
    if (!std.mem.startsWith(u8, header_line, header_prefix)) {
        return error.InvalidFormat;
    }

    // Parse cols, rows, cursor from header.
    const meta = header_line[header_prefix.len..];
    const parsed = parseHeader(meta) orelse return error.ParseFailed;

    return .{
        .cols = parsed.cols,
        .rows = parsed.rows,
        .cursor_row = parsed.cursor_row,
        .cursor_col = parsed.cursor_col,
        .text = try alloc.dupe(u8, text_content),
    };
}

const HeaderFields = struct {
    cols: u16,
    rows: u16,
    cursor_row: u16,
    cursor_col: u16,
};

fn parseHeader(meta: []const u8) ?HeaderFields {
    var cols: ?u16 = null;
    var rows: ?u16 = null;
    var cursor_row: ?u16 = null;
    var cursor_col: ?u16 = null;

    var iter = std.mem.tokenizeScalar(u8, meta, ' ');
    while (iter.next()) |token| {
        if (std.mem.startsWith(u8, token, "cols=")) {
            cols = std.fmt.parseInt(u16, token[5..], 10) catch return null;
        } else if (std.mem.startsWith(u8, token, "rows=")) {
            rows = std.fmt.parseInt(u16, token[5..], 10) catch return null;
        } else if (std.mem.startsWith(u8, token, "cursor=")) {
            const cursor_str = token[7..];
            const comma = std.mem.indexOf(u8, cursor_str, ",") orelse return null;
            cursor_row = std.fmt.parseInt(u16, cursor_str[0..comma], 10) catch return null;
            cursor_col = std.fmt.parseInt(u16, cursor_str[comma + 1 ..], 10) catch return null;
        }
    }

    if (cols == null or rows == null or cursor_row == null or cursor_col == null) return null;

    return .{
        .cols = cols.?,
        .rows = rows.?,
        .cursor_row = cursor_row.?,
        .cursor_col = cursor_col.?,
    };
}

// --- Step 5.1.4: expectMatch ---

/// Assert that the current screen matches a golden file.
/// If the golden file doesn't exist, saves current as golden (first-run).
///
/// Assertions:
/// - session.state == .active
/// - golden_path.len > 0
pub fn expectMatch(
    session: *Session,
    alloc: Allocator,
    golden_path: []const u8,
) !void {
    std.debug.assert(session.state == .active);
    std.debug.assert(golden_path.len > 0);

    var current = try capture(session, alloc);
    defer current.deinit(alloc);

    // Try to load golden file.
    const golden_result = load(alloc, golden_path);

    if (golden_result) |golden| {
        var golden_mut = golden;
        defer golden_mut.deinit(alloc);

        // Check dimensions match.
        if (current.cols != golden_mut.cols or current.rows != golden_mut.rows) {
            return error.DimensionMismatch;
        }

        const diff_text = try diff(current, golden_mut, alloc);
        defer alloc.free(diff_text);

        if (diff_text.len > 0) {
            std.debug.print("Snapshot mismatch:\n{s}\n", .{diff_text});
            return error.SnapshotMismatch;
        }
    } else |_| {
        // Golden file doesn't exist — save current as golden.
        try save(current, alloc, golden_path);
    }
}

// ===== Tests =====

test "capture snapshot" {
    const alloc = std.testing.allocator;

    var sess = try Session.create(alloc, 0, .{
        .argv = &[_][]const u8{ "/bin/echo", "hello" },
    });
    defer sess.destroy();
    sess.terminal.initStream();

    // Wait for output.
    _ = sess.drainFor(1000);

    var snap = try capture(&sess, alloc);
    defer snap.deinit(alloc);

    try std.testing.expect(std.mem.indexOf(u8, snap.text, "hello") != null);
    try std.testing.expectEqual(@as(u16, 80), snap.cols);
    try std.testing.expectEqual(@as(u16, 24), snap.rows);
}

test "diff identical snapshots" {
    const alloc = std.testing.allocator;

    const snap = Snapshot{
        .cols = 80,
        .rows = 24,
        .cursor_row = 0,
        .cursor_col = 0,
        .text = "hello world",
    };

    const result = try diff(snap, snap, alloc);
    defer alloc.free(result);

    try std.testing.expectEqualStrings("", result);
}

test "diff different snapshots" {
    const alloc = std.testing.allocator;

    const a = Snapshot{
        .cols = 80,
        .rows = 24,
        .cursor_row = 0,
        .cursor_col = 0,
        .text = "hello",
    };

    const b = Snapshot{
        .cols = 80,
        .rows = 24,
        .cursor_row = 1,
        .cursor_col = 5,
        .text = "world",
    };

    const result = try diff(a, b, alloc);
    defer alloc.free(result);

    try std.testing.expect(result.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result, "cursor") != null);
}

test "save and load round-trip" {
    const alloc = std.testing.allocator;

    const original = Snapshot{
        .cols = 80,
        .rows = 24,
        .cursor_row = 3,
        .cursor_col = 7,
        .text = "hello\nworld",
    };

    const path = "/tmp/tuikit_test_snapshot.txt";
    try save(original, alloc, path);

    var loaded = try load(alloc, path);
    defer loaded.deinit(alloc);

    try std.testing.expectEqual(original.cols, loaded.cols);
    try std.testing.expectEqual(original.rows, loaded.rows);
    try std.testing.expectEqual(original.cursor_row, loaded.cursor_row);
    try std.testing.expectEqual(original.cursor_col, loaded.cursor_col);
    try std.testing.expectEqualStrings(original.text, loaded.text);

    // Clean up.
    std.fs.cwd().deleteFile(path) catch {};
}

test "parseHeader valid" {
    const result = parseHeader(" cols=80 rows=24 cursor=3,7");
    try std.testing.expect(result != null);
    try std.testing.expectEqual(@as(u16, 80), result.?.cols);
    try std.testing.expectEqual(@as(u16, 24), result.?.rows);
    try std.testing.expectEqual(@as(u16, 3), result.?.cursor_row);
    try std.testing.expectEqual(@as(u16, 7), result.?.cursor_col);
}

test "parseHeader invalid" {
    const result = parseHeader(" cols=80");
    try std.testing.expect(result == null);
}
