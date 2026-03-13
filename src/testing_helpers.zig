const std = @import("std");
const ghostty_vt = @import("ghostty-vt");
const Terminal = ghostty_vt.Terminal;
const ReadonlyStream = ghostty_vt.ReadonlyStream;

/// A test terminal with its associated ReadonlyStream, ready for byte feeding.
/// IMPORTANT: The stream holds a pointer to the terminal. Do not move this
/// struct after calling initStream(). Use as a `var` local only.
pub const TestTerminal = struct {
    terminal: Terminal,
    stream: ReadonlyStream = undefined,
    stream_initialized: bool = false,

    /// Initialize the ReadonlyStream. Must be called after the struct is in
    /// its final memory location (i.e., after var assignment).
    ///
    /// Assertions:
    /// - Stream must not already be initialized (no double-init)
    /// - Postcondition: stream_initialized is true
    pub fn initStream(self: *TestTerminal) void {
        std.debug.assert(!self.stream_initialized);

        self.stream = self.terminal.vtStream();
        self.stream_initialized = true;

        std.debug.assert(self.stream_initialized);
    }

    pub fn deinit(self: *TestTerminal) void {
        if (self.stream_initialized) {
            self.stream.deinit();
        }
        self.terminal.deinit(std.testing.allocator);
    }
};

/// Create a Terminal for testing. Caller must call initStream() on the
/// result before feeding bytes.
/// Uses std.testing.allocator for leak detection.
///
/// Assertions:
/// - cols > 0 and rows > 0 (valid dimensions)
/// - Postcondition: returned terminal is initialized
pub fn createTestTerminal(cols: u16, rows: u16) TestTerminal {
    std.debug.assert(cols > 0);
    std.debug.assert(rows > 0);

    const alloc = std.testing.allocator;
    const terminal: Terminal = Terminal.init(alloc, .{
        .cols = cols,
        .rows = rows,
        .max_scrollback = 100,
    }) catch @panic("failed to init test terminal");

    // Postcondition: terminal is initialized with requested dimensions.
    std.debug.assert(terminal.cols == cols);
    std.debug.assert(terminal.rows == rows);

    return .{ .terminal = terminal };
}

/// Feed raw VT bytes into a test terminal's stream.
///
/// Assertions:
/// - data.len <= 65536 (bounded input per call, matching Ghostty fuzz buffer)
/// - stream must be initialized
/// - Postcondition: bytes were processed without error
pub fn feedBytes(stream: *ReadonlyStream, data: []const u8) void {
    std.debug.assert(data.len <= 65536);

    stream.nextSlice(data) catch |err| {
        std.debug.panic("feedBytes failed: {}", .{err});
    };
}

/// Assert that the terminal screen contains the given needle text.
///
/// Assertions:
/// - needle.len > 0 (meaningful search)
/// - Postcondition: needle found in screen text
pub fn expectScreenContains(terminal: *Terminal, needle: []const u8) !void {
    std.debug.assert(needle.len > 0);

    const alloc = std.testing.allocator;
    const screen_text = try terminal.plainString(alloc);
    defer alloc.free(screen_text);

    if (std.mem.indexOf(u8, screen_text, needle) == null) {
        return error.TextNotFound;
    }
}

// --- Tests ---

test "createTestTerminal returns valid terminal" {
    var tt = createTestTerminal(80, 24);
    defer tt.deinit();

    // Terminal should be usable — feed a simple string.
    try tt.terminal.printString("test");
    const text = try tt.terminal.plainString(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "test") != null);
}

test "feedBytes processes VT data" {
    var tt = createTestTerminal(80, 24);
    defer tt.deinit();
    tt.initStream();

    // Feed raw bytes through the stream (not printString).
    feedBytes(&tt.stream, "hello via stream");

    const text = try tt.terminal.plainString(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "hello via stream") != null);
}

test "expectScreenContains succeeds on match" {
    var tt = createTestTerminal(80, 24);
    defer tt.deinit();

    try tt.terminal.printString("the quick brown fox");
    try expectScreenContains(&tt.terminal, "quick brown");
}

test "expectScreenContains fails on no match" {
    var tt = createTestTerminal(80, 24);
    defer tt.deinit();

    try tt.terminal.printString("hello world");
    const result = expectScreenContains(&tt.terminal, "goodbye");
    try std.testing.expectError(error.TextNotFound, result);
}

test "feedBytes with ESC sequences does not crash" {
    var tt = createTestTerminal(80, 24);
    defer tt.deinit();
    tt.initStream();

    // SGR bold + text + SGR reset.
    feedBytes(&tt.stream, "\x1b[1mbold text\x1b[0m");

    const text = try tt.terminal.plainString(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "bold text") != null);
}
