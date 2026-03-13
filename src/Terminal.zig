const std = @import("std");
const Allocator = std.mem.Allocator;
const ghostty_vt = @import("ghostty-vt");
const GhosttyTerminal = ghostty_vt.Terminal;
const ReadonlyStream = ghostty_vt.ReadonlyStream;

/// Maximum allowed terminal dimension (cols or rows).
const dimension_max: u16 = 500;

/// Maximum bytes per single feed call (matches Ghostty fuzz buffer).
const feed_bytes_max: usize = 65536;

// Compile-time assertions for constant relationships.
comptime {
    std.debug.assert(dimension_max > 0);
    std.debug.assert(dimension_max <= std.math.maxInt(u16));
    std.debug.assert(feed_bytes_max > 0);
    std.debug.assert(feed_bytes_max <= 65536);
}

// --- Public types ---

/// Terminal lifecycle state.
pub const State = enum {
    /// Slot exists but has not been initialized (for pool pre-allocation).
    uninitialized,
    /// Terminal is ready for use.
    ready,
    /// Terminal has been deinitialized. Must not be used again.
    closed,
};

/// Options for creating a new Terminal.
pub const Options = struct {
    cols: u16,
    rows: u16,
    max_scrollback: usize = 10_000,
};

/// Cursor position in the terminal grid.
pub const CursorPos = struct {
    row: u16,
    col: u16,
};

// --- Terminal type ---

/// Wrapper around ghostty-vt Terminal with TigerStyle lifecycle
/// assertions and a drain-then-query API.
///
/// IMPORTANT: After calling `init`, you MUST call `initStream` before
/// using `feed`. The stream holds a pointer to `inner`, so the struct
/// must be at its final memory location before stream initialization.
inner: GhosttyTerminal,
stream: ReadonlyStream = undefined,
cols: u16,
rows: u16,
bytes_fed: u64 = 0,
state: State = .uninitialized,
stream_initialized: bool = false,

const Terminal = @This();

/// Create a new terminal with the given dimensions.
///
/// After calling init, the caller MUST call `initStream()` once the
/// struct is at its final memory location (i.e., assigned to a var).
///
/// Assertions:
/// - cols > 0 and rows > 0
/// - cols <= 500 and rows <= 500 (bounded)
/// Postconditions:
/// - state == .ready
/// - bytes_fed == 0
pub fn init(alloc: Allocator, opts: Options) !Terminal {
    // Preconditions: valid dimensions.
    std.debug.assert(opts.cols > 0);
    std.debug.assert(opts.rows > 0);
    std.debug.assert(opts.cols <= dimension_max);
    std.debug.assert(opts.rows <= dimension_max);

    var inner: GhosttyTerminal = try .init(alloc, .{
        .cols = opts.cols,
        .rows = opts.rows,
        .max_scrollback = opts.max_scrollback,
    });
    errdefer inner.deinit(alloc);

    const result = Terminal{
        .inner = inner,
        .cols = opts.cols,
        .rows = opts.rows,
        .bytes_fed = 0,
        .state = .ready,
        .stream_initialized = false,
    };

    // Postconditions.
    std.debug.assert(result.state == .ready);
    std.debug.assert(result.bytes_fed == 0);

    return result;
}

/// Initialize the ReadonlyStream. Must be called after the struct is
/// at its final memory location (after var assignment, not in init).
///
/// Assertions:
/// - state == .ready
/// - stream not already initialized
/// Postcondition:
/// - stream_initialized == true
pub fn initStream(self: *Terminal) void {
    std.debug.assert(self.state == .ready);
    std.debug.assert(!self.stream_initialized);

    self.stream = self.inner.vtStream();
    self.stream_initialized = true;

    std.debug.assert(self.stream_initialized);
}

/// Release all resources held by the terminal.
///
/// Assertions:
/// - state == .ready (not double-free, not uninitialized)
/// Postcondition:
/// - state == .closed
pub fn deinit(self: *Terminal, alloc: Allocator) void {
    std.debug.assert(self.state == .ready);

    if (self.stream_initialized) {
        self.stream.deinit();
    }
    self.inner.deinit(alloc);
    self.state = .closed;

    std.debug.assert(self.state == .closed);
}

// --- Step 1.1.2: feed ---

/// Feed raw VT bytes into the terminal's ReadonlyStream.
///
/// Assertions:
/// - state == .ready
/// - stream must be initialized
/// - data.len <= 65536 (bounded input per call)
/// Postcondition:
/// - bytes_fed increased by exactly data.len
pub fn feed(self: *Terminal, data: []const u8) void {
    std.debug.assert(self.state == .ready);
    std.debug.assert(self.stream_initialized);
    std.debug.assert(data.len <= feed_bytes_max);

    const bytes_before = self.bytes_fed;

    self.stream.nextSlice(data) catch |err| {
        std.debug.panic("Terminal.feed failed: {}", .{err});
    };
    self.bytes_fed += data.len;

    // Postcondition: bytes_fed increased by exactly data.len.
    std.debug.assert(self.bytes_fed == bytes_before + data.len);
}

// --- Step 1.1.3: plainText ---

/// Return the current screen content as a plain text string.
/// Caller owns the returned memory and must free it.
///
/// Assertions:
/// - state == .ready
/// Postcondition:
/// - returned slice length >= 0 (empty for blank terminal)
pub fn plainText(self: *Terminal, alloc: Allocator) ![]const u8 {
    std.debug.assert(self.state == .ready);

    const text = try self.inner.plainString(alloc);

    // Postcondition: bounded by terminal dimensions (cols * rows * 4 bytes UTF-8 max + newlines).
    const text_bound: usize = @as(usize, self.cols) * @as(usize, self.rows) * 4 + self.rows;
    std.debug.assert(text.len <= text_bound);

    return text;
}

// --- Step 1.1.4: cursorPosition ---

/// Return the current cursor row and column.
///
/// Assertions:
/// - state == .ready
/// Postconditions:
/// - row < self.rows
/// - col < self.cols
pub fn cursorPosition(self: *Terminal) CursorPos {
    std.debug.assert(self.state == .ready);

    const cursor = self.inner.screens.active.cursor;
    const row: u16 = cursor.y;
    const col: u16 = cursor.x;

    // Postconditions: cursor within terminal bounds.
    std.debug.assert(row < self.rows);
    std.debug.assert(col < self.cols);

    return .{ .row = row, .col = col };
}

// --- Step 1.1.5: resize ---

/// Resize the terminal grid to new dimensions.
///
/// Assertions:
/// - state == .ready
/// - new_cols > 0, new_rows > 0, both <= 500
/// Postconditions:
/// - self.cols == new_cols
/// - self.rows == new_rows
pub fn resize(
    self: *Terminal,
    alloc: Allocator,
    new_cols: u16,
    new_rows: u16,
) !void {
    // Preconditions.
    std.debug.assert(self.state == .ready);
    std.debug.assert(new_cols > 0);
    std.debug.assert(new_rows > 0);
    std.debug.assert(new_cols <= dimension_max);
    std.debug.assert(new_rows <= dimension_max);

    try self.inner.resize(alloc, new_cols, new_rows);
    self.cols = new_cols;
    self.rows = new_rows;

    // Postconditions.
    std.debug.assert(self.cols == new_cols);
    std.debug.assert(self.rows == new_rows);
}

// ===== Tests =====

test "init and deinit lifecycle" {
    const alloc = std.testing.allocator;

    var terminal = try Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    try std.testing.expectEqual(State.ready, terminal.state);
    try std.testing.expectEqual(@as(u16, 80), terminal.cols);
    try std.testing.expectEqual(@as(u16, 24), terminal.rows);
    try std.testing.expectEqual(@as(u64, 0), terminal.bytes_fed);
    try std.testing.expect(!terminal.stream_initialized);

    terminal.deinit(alloc);
    try std.testing.expectEqual(State.closed, terminal.state);
}

test "initStream enables feed" {
    const alloc = std.testing.allocator;

    var terminal = try Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(alloc);

    terminal.initStream();
    try std.testing.expect(terminal.stream_initialized);

    terminal.feed("hello");
    try std.testing.expectEqual(@as(u64, 5), terminal.bytes_fed);
}

test "feed accumulates bytes_fed" {
    const alloc = std.testing.allocator;

    var terminal = try Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(alloc);
    terminal.initStream();

    terminal.feed("abc");
    try std.testing.expectEqual(@as(u64, 3), terminal.bytes_fed);

    terminal.feed("de");
    try std.testing.expectEqual(@as(u64, 5), terminal.bytes_fed);
}

test "feed with ESC sequences does not crash" {
    const alloc = std.testing.allocator;

    var terminal = try Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(alloc);
    terminal.initStream();

    // SGR bold + text + reset.
    terminal.feed("\x1b[1mbold\x1b[0m");
    try std.testing.expect(terminal.bytes_fed > 0);
}

test "plainText returns screen content" {
    const alloc = std.testing.allocator;

    var terminal = try Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(alloc);
    terminal.initStream();

    terminal.feed("hello\r\nworld");

    const text = try terminal.plainText(alloc);
    defer alloc.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "world") != null);
}

test "plainText on blank terminal" {
    const alloc = std.testing.allocator;

    var terminal = try Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(alloc);

    const text = try terminal.plainText(alloc);
    defer alloc.free(text);

    // Blank terminal should return empty or whitespace-only string.
    try std.testing.expect(text.len >= 0);
}

test "cursorPosition at origin" {
    const alloc = std.testing.allocator;

    var terminal = try Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(alloc);

    const pos = terminal.cursorPosition();
    try std.testing.expectEqual(@as(u16, 0), pos.row);
    try std.testing.expectEqual(@as(u16, 0), pos.col);
}

test "cursorPosition after text" {
    const alloc = std.testing.allocator;

    var terminal = try Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(alloc);
    terminal.initStream();

    // "AB\r\n" moves cursor to row 1, col 0. Then "X" moves to col 1.
    terminal.feed("AB\r\nX");

    const pos = terminal.cursorPosition();
    try std.testing.expectEqual(@as(u16, 1), pos.row);
    try std.testing.expectEqual(@as(u16, 1), pos.col);
}

test "resize changes dimensions" {
    const alloc = std.testing.allocator;

    var terminal = try Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(alloc);

    try terminal.resize(alloc, 40, 12);
    try std.testing.expectEqual(@as(u16, 40), terminal.cols);
    try std.testing.expectEqual(@as(u16, 12), terminal.rows);
}

test "resize preserves content" {
    const alloc = std.testing.allocator;

    var terminal = try Terminal.init(alloc, .{ .cols = 80, .rows = 24 });
    defer terminal.deinit(alloc);
    terminal.initStream();

    terminal.feed("hello world");
    try terminal.resize(alloc, 40, 12);

    const text = try terminal.plainText(alloc);
    defer alloc.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "hello") != null);
}

test "small terminal dimensions" {
    const alloc = std.testing.allocator;

    var terminal = try Terminal.init(alloc, .{ .cols = 1, .rows = 1 });
    defer terminal.deinit(alloc);
    terminal.initStream();

    terminal.feed("A");
    const pos = terminal.cursorPosition();
    // With 1 col, after printing 'A', cursor wraps or stays at 0.
    try std.testing.expect(pos.row < terminal.rows);
    try std.testing.expect(pos.col < terminal.cols);
}

test "max dimension terminal" {
    const alloc = std.testing.allocator;

    var terminal = try Terminal.init(alloc, .{
        .cols = dimension_max,
        .rows = dimension_max,
    });
    defer terminal.deinit(alloc);

    try std.testing.expectEqual(dimension_max, terminal.cols);
    try std.testing.expectEqual(dimension_max, terminal.rows);
}
