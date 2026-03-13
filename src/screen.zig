const std = @import("std");
const Allocator = std.mem.Allocator;
const ghostty_vt = @import("ghostty-vt");
const Terminal = @import("Terminal.zig");

// --- Public types ---

/// Information about a single terminal cell.
pub const CellInfo = struct {
    char: u21,
    fg: ColorInfo,
    bg: ColorInfo,
    bold: bool,
    italic: bool,
    underline: bool,
    strikethrough: bool,
    dim: bool,
    wide: WideKind,
};

/// Color information extracted from a cell's style.
pub const ColorInfo = union(enum) {
    default: void,
    palette: u8,
    rgb: struct { r: u8, g: u8, b: u8 },
};

/// Simplified wide character classification.
pub const WideKind = enum { narrow, wide, spacer };

/// A text match location on screen.
pub const Match = struct {
    row: u16,
    col: u16,
};

/// Options for rectangular region extraction.
pub const RegionOpts = struct {
    top: u16,
    left: u16,
    height: u16,
    width: u16,
};

/// Maximum number of matches returned by findText.
const find_text_matches_max: u16 = 256;

// --- Step 1.2.1: cellAt ---

/// Read a single cell's content and attributes at the given position.
///
/// Assertions:
/// - terminal.state == .ready
/// - row < terminal.rows, col < terminal.cols
/// Postcondition:
/// - returned CellInfo has valid char (or 0 for empty)
pub fn cellAt(terminal: *const Terminal, row: u16, col: u16) CellInfo {
    std.debug.assert(terminal.state == .ready);
    std.debug.assert(row < terminal.rows);
    std.debug.assert(col < terminal.cols);

    const screen = terminal.inner.screens.active;
    const cell_result = screen.pages.getCell(.{
        .viewport = .{ .x = col, .y = row },
    });

    if (cell_result) |cell_data| {
        return extractCellInfo(cell_data);
    }

    // Cell not found — return empty cell.
    return emptyCellInfo();
}

// --- Step 1.2.2: rowText ---

/// Extract text from a single row, trimming trailing whitespace.
///
/// Assertions:
/// - terminal.state == .ready
/// - row < terminal.rows
/// Postcondition:
/// - result.len <= terminal.cols * 4 (max UTF-8 bytes per cell)
pub fn rowText(
    terminal: *const Terminal,
    alloc: Allocator,
    row: u16,
) ![]const u8 {
    std.debug.assert(terminal.state == .ready);
    std.debug.assert(row < terminal.rows);

    const cols = terminal.cols;
    const max_bytes: usize = @as(usize, cols) * 4;

    var buffer: std.ArrayList(u8) = try .initCapacity(alloc, max_bytes);
    defer buffer.deinit(alloc);

    var col: u16 = 0;
    while (col < cols) : (col += 1) {
        const info = cellAt(terminal, row, col);
        if (info.char != 0) {
            var utf8_buf: [4]u8 = undefined;
            // Invalid codepoint from terminal — skip rather than crash.
            const len = std.unicode.utf8Encode(info.char, &utf8_buf) catch 0;
            if (len > 0) {
                buffer.appendSliceAssumeCapacity(utf8_buf[0..len]);
            }
        } else {
            buffer.appendAssumeCapacity(' ');
        }
    }

    // Trim trailing whitespace.
    var trimmed_len = buffer.items.len;
    while (trimmed_len > 0 and buffer.items[trimmed_len - 1] == ' ') {
        trimmed_len -= 1;
    }

    // Postcondition: bounded output.
    std.debug.assert(trimmed_len <= max_bytes);

    const owned = try alloc.dupe(u8, buffer.items[0..trimmed_len]);
    return owned;
}

// --- Step 1.2.3: regionText ---

/// Extract text from a rectangular region, newline-separated rows.
///
/// Assertions:
/// - terminal.state == .ready
/// - top + height <= terminal.rows
/// - left + width <= terminal.cols
/// Postcondition:
/// - result contains at most `height` lines
pub fn regionText(
    terminal: *const Terminal,
    alloc: Allocator,
    opts: RegionOpts,
) ![]const u8 {
    std.debug.assert(terminal.state == .ready);
    std.debug.assert(@as(u32, opts.top) + @as(u32, opts.height) <= terminal.rows);
    std.debug.assert(@as(u32, opts.left) + @as(u32, opts.width) <= terminal.cols);

    const max_bytes: usize = @as(usize, opts.height) *
        (@as(usize, opts.width) * 4 + 1);

    var buffer: std.ArrayList(u8) = try .initCapacity(alloc, max_bytes);
    defer buffer.deinit(alloc);

    var row_idx: u16 = 0;
    while (row_idx < opts.height) : (row_idx += 1) {
        if (row_idx > 0) {
            try buffer.append(alloc, '\n');
        }

        const actual_row = opts.top + row_idx;
        const line_start = buffer.items.len;

        var col_idx: u16 = 0;
        while (col_idx < opts.width) : (col_idx += 1) {
            const actual_col = opts.left + col_idx;
            const info = cellAt(terminal, actual_row, actual_col);

            if (info.char != 0) {
                var utf8_buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(
                    info.char,
                    &utf8_buf,
                ) catch 0;
                if (len > 0) {
                    try buffer.appendSlice(alloc, utf8_buf[0..len]);
                } else {
                    try buffer.append(alloc, ' ');
                }
            } else {
                try buffer.append(alloc, ' ');
            }
        }

        // Trim trailing spaces from this row.
        while (buffer.items.len > line_start and
            buffer.items[buffer.items.len - 1] == ' ')
        {
            buffer.items.len -= 1;
        }
    }

    // Postcondition: bounded output.
    std.debug.assert(buffer.items.len <= max_bytes);

    return try buffer.toOwnedSlice(alloc);
}

// --- Step 1.2.4: findText ---

/// Search each row for the needle substring. Returns up to 256 matches.
///
/// Assertions:
/// - needle.len > 0
/// - needle.len <= terminal.cols
/// - terminal.state == .ready
/// Postcondition:
/// - all matches have row < terminal.rows, col < terminal.cols
pub fn findText(
    terminal: *const Terminal,
    alloc: Allocator,
    needle: []const u8,
) ![]Match {
    std.debug.assert(needle.len > 0);
    std.debug.assert(needle.len <= terminal.cols);
    std.debug.assert(terminal.state == .ready);

    var matches: std.ArrayList(Match) = try .initCapacity(alloc, find_text_matches_max);
    defer matches.deinit(alloc);

    var row: u16 = 0;
    while (row < terminal.rows) : (row += 1) {
        if (matches.items.len >= find_text_matches_max) break;

        const row_content = try rowText(terminal, alloc, row);
        defer alloc.free(row_content);

        try findInRow(alloc, row_content, needle, row, &matches);
    }

    // Postcondition: all matches are within bounds.
    for (matches.items) |m| {
        std.debug.assert(m.row < terminal.rows);
        std.debug.assert(m.col < terminal.cols);
    }

    return try matches.toOwnedSlice(alloc);
}

// --- Step 1.2.5: containsText ---

/// Short-circuit boolean text search. Returns true on first match.
///
/// Assertions:
/// - needle.len > 0
/// - terminal.state == .ready
/// Postcondition:
/// - if true, needle exists somewhere on screen
pub fn containsText(
    terminal: *const Terminal,
    alloc: Allocator,
    needle: []const u8,
) !bool {
    std.debug.assert(needle.len > 0);
    std.debug.assert(terminal.state == .ready);

    var row: u16 = 0;
    while (row < terminal.rows) : (row += 1) {
        const row_content = try rowText(terminal, alloc, row);
        defer alloc.free(row_content);

        if (std.mem.indexOf(u8, row_content, needle) != null) {
            return true;
        }
    }

    return false;
}

// --- Internal helpers ---

/// Find all occurrences of needle in a row string, appending to matches.
fn findInRow(
    alloc: Allocator,
    row_content: []const u8,
    needle: []const u8,
    row: u16,
    matches: *std.ArrayList(Match),
) !void {
    std.debug.assert(needle.len > 0);
    const count_before = matches.items.len;

    var start: usize = 0;
    while (start + needle.len <= row_content.len) {
        if (matches.items.len >= find_text_matches_max) break;

        if (std.mem.indexOf(u8, row_content[start..], needle)) |pos| {
            const col: u16 = @intCast(start + pos);
            try matches.append(alloc, .{ .row = row, .col = col });
            start = start + pos + 1;
        } else {
            break;
        }
    }

    // Postcondition: did not exceed match limit.
    std.debug.assert(matches.items.len <= find_text_matches_max);
    std.debug.assert(matches.items.len >= count_before);
}

/// Extract CellInfo from a Ghostty PageList.Cell result.
fn extractCellInfo(cell_data: ghostty_vt.PageList.Cell) CellInfo {
    const cell = cell_data.cell;
    const cp = cell.codepoint();
    const sty = cell_data.style();

    const fg = convertColor(sty.fg_color);
    const bg = convertColor(sty.bg_color);

    const wide_kind: WideKind = switch (cell.wide) {
        .narrow => .narrow,
        .wide => .wide,
        .spacer_tail, .spacer_head => .spacer,
    };

    return .{
        .char = cp,
        .fg = fg,
        .bg = bg,
        .bold = sty.flags.bold,
        .italic = sty.flags.italic,
        .underline = sty.flags.underline != .none,
        .strikethrough = sty.flags.strikethrough,
        .dim = sty.flags.faint,
        .wide = wide_kind,
    };
}

/// Convert a Ghostty Style.Color to our ColorInfo.
fn convertColor(color: ghostty_vt.Style.Color) ColorInfo {
    return switch (color) {
        .none => .{ .default = {} },
        .palette => |p| .{ .palette = p },
        .rgb => |rgb| .{ .rgb = .{ .r = rgb.r, .g = rgb.g, .b = rgb.b } },
    };
}

/// Return an empty CellInfo for cells that don't exist.
fn emptyCellInfo() CellInfo {
    return .{
        .char = 0,
        .fg = .{ .default = {} },
        .bg = .{ .default = {} },
        .bold = false,
        .italic = false,
        .underline = false,
        .strikethrough = false,
        .dim = false,
        .wide = .narrow,
    };
}

// ===== Tests =====

test "cellAt reads character" {
    const alloc = std.testing.allocator;

    var terminal = try Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(alloc);
    terminal.initStream();

    terminal.feed("Hello");

    const cell_h = cellAt(&terminal, 0, 0);
    try std.testing.expectEqual(@as(u21, 'H'), cell_h.char);

    const cell_e = cellAt(&terminal, 0, 1);
    try std.testing.expectEqual(@as(u21, 'e'), cell_e.char);
}

test "cellAt reads colored text" {
    const alloc = std.testing.allocator;

    var terminal = try Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(alloc);
    terminal.initStream();

    // ESC[31m = red foreground, then "A", then ESC[0m = reset.
    terminal.feed("\x1b[31mA\x1b[0m");

    const cell = cellAt(&terminal, 0, 0);
    try std.testing.expectEqual(@as(u21, 'A'), cell.char);

    // Red foreground is palette index 1.
    switch (cell.fg) {
        .palette => |p| try std.testing.expectEqual(@as(u8, 1), p),
        else => return error.UnexpectedColor,
    }
}

test "cellAt reads bold attribute" {
    const alloc = std.testing.allocator;

    var terminal = try Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(alloc);
    terminal.initStream();

    // ESC[1m = bold.
    terminal.feed("\x1b[1mB\x1b[0m");

    const cell = cellAt(&terminal, 0, 0);
    try std.testing.expectEqual(@as(u21, 'B'), cell.char);
    try std.testing.expect(cell.bold);
}

test "cellAt empty cell" {
    const alloc = std.testing.allocator;

    var terminal = try Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(alloc);

    // No text fed — cell at (0,0) should be empty.
    const cell = cellAt(&terminal, 0, 0);
    try std.testing.expectEqual(@as(u21, 0), cell.char);
    try std.testing.expect(!cell.bold);
}

test "rowText extracts and trims" {
    const alloc = std.testing.allocator;

    var terminal = try Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(alloc);
    terminal.initStream();

    terminal.feed("hello");

    const text = try rowText(&terminal, alloc, 0);
    defer alloc.free(text);

    try std.testing.expectEqualStrings("hello", text);
}

test "rowText empty row" {
    const alloc = std.testing.allocator;

    var terminal = try Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(alloc);

    const text = try rowText(&terminal, alloc, 5);
    defer alloc.free(text);

    try std.testing.expectEqualStrings("", text);
}

test "regionText extracts sub-region" {
    const alloc = std.testing.allocator;

    var terminal = try Terminal.init(alloc, .{ .cols = 10, .rows = 5 });
    defer terminal.deinit(alloc);
    terminal.initStream();

    // Fill rows with identifiable text.
    terminal.feed("ABCDEFGHIJ\r\n");
    terminal.feed("KLMNOPQRST\r\n");
    terminal.feed("UVWXYZ0123\r\n");

    // Extract 3x3 region starting at row 0, col 2.
    const text = try regionText(&terminal, alloc, .{
        .top = 0,
        .left = 2,
        .height = 3,
        .width = 3,
    });
    defer alloc.free(text);

    // Should get CDE, MNO, WXY (columns 2-4 of rows 0-2).
    try std.testing.expect(std.mem.indexOf(u8, text, "CDE") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "MNO") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "WXY") != null);
}

test "findText finds occurrences" {
    const alloc = std.testing.allocator;

    var terminal = try Terminal.init(alloc, .{ .cols = 40, .rows = 5 });
    defer terminal.deinit(alloc);
    terminal.initStream();

    terminal.feed("hello world\r\n");
    terminal.feed("say hello\r\n");

    const matches = try findText(&terminal, alloc, "hello");
    defer alloc.free(matches);

    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqual(@as(u16, 0), matches[0].row);
    try std.testing.expectEqual(@as(u16, 0), matches[0].col);
    try std.testing.expectEqual(@as(u16, 1), matches[1].row);
    try std.testing.expectEqual(@as(u16, 4), matches[1].col);
}

test "findText no match returns empty" {
    const alloc = std.testing.allocator;

    var terminal = try Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(alloc);
    terminal.initStream();

    terminal.feed("hello world");

    const matches = try findText(&terminal, alloc, "xyz");
    defer alloc.free(matches);

    try std.testing.expectEqual(@as(usize, 0), matches.len);
}

test "containsText true" {
    const alloc = std.testing.allocator;

    var terminal = try Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(alloc);
    terminal.initStream();

    terminal.feed("hello world");

    try std.testing.expect(try containsText(&terminal, alloc, "world"));
}

test "containsText false" {
    const alloc = std.testing.allocator;

    var terminal = try Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(alloc);
    terminal.initStream();

    terminal.feed("hello world");

    try std.testing.expect(!try containsText(&terminal, alloc, "xyz"));
}
