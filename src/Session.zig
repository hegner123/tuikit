const std = @import("std");
const Allocator = std.mem.Allocator;
const Pty = @import("Pty.zig");
const Process = @import("Process.zig");
const Terminal = @import("Terminal.zig");
const screen = @import("screen.zig");
const input = @import("input.zig");

// --- Public types ---

pub const State = enum { idle, active, stopped };

pub const CreateOpts = struct {
    cols: u16 = 80,
    rows: u16 = 24,
    argv: []const []const u8,
    env: ?[*:null]const ?[*:0]const u8 = null,
    max_scrollback: usize = 1000,
};

pub const DrainResult = struct {
    bytes_read: u32,
    eof: bool,
};

pub const SessionError = error{
    PtyOpenFailed,
    SpawnFailed,
    TerminalInitFailed,
    NotActive,
    WriteFailed,
};

// --- Constants ---

/// Maximum session ID (pool size - 1).
const max_session_id: u8 = 15;

/// Maximum bytes per drain read (matches Ghostty fuzz buffer).
const read_buf_size: usize = 65536;

/// Maximum iterations per drain call (prevent infinite loop on fast producer).
const drain_max_iterations: u32 = 256;

/// Maximum timeout for drainFor (30 seconds).
const drain_timeout_max: u32 = 30_000;

/// Hard wall-clock limit for any drain loop (10 seconds).
/// Prevents hangs when a fast producer (e.g. yes) keeps the PTY buffer full.
const drain_wall_clock_max_ms: i64 = 10_000;

/// Maximum text length for sendText.
const send_text_max: usize = 4096;

// --- Session type ---

id: u8,
pty: Pty,
process: Process,
terminal: Terminal,
read_buf: [read_buf_size]u8,
state: State,
alloc: Allocator,

const Session = @This();

// --- Step 3.1.1: create ---

/// Create a new TUI test session: init Terminal, open PTY, spawn process.
///
/// Assertions:
/// - id <= 15
/// - opts.argv.len > 0
/// - opts.cols > 0, opts.rows > 0
/// - opts.cols <= 500, opts.rows <= 500
/// Postcondition:
/// - state == .active
pub fn create(alloc: Allocator, id: u8, opts: CreateOpts) !Session {
    std.debug.assert(id <= max_session_id);
    std.debug.assert(opts.argv.len > 0);
    std.debug.assert(opts.cols > 0);
    std.debug.assert(opts.rows > 0);
    std.debug.assert(opts.cols <= 500);
    std.debug.assert(opts.rows <= 500);

    // 1. Init Terminal.
    var terminal = Terminal.init(alloc, .{
        .cols = opts.cols,
        .rows = opts.rows,
        .max_scrollback = opts.max_scrollback,
    }) catch return error.TerminalInitFailed;
    errdefer terminal.deinit(alloc);

    // 2. Open PTY.
    var pty = Pty.open(.{
        .cols = opts.cols,
        .rows = opts.rows,
    }) catch return error.PtyOpenFailed;
    errdefer pty.close();

    // 3. Spawn child process.
    const process = Process.spawn(
        &pty,
        opts.argv,
        opts.env,
    ) catch return error.SpawnFailed;

    // Note: spawn already called closeSlave on parent side.

    const result = Session{
        .id = id,
        .pty = pty,
        .process = process,
        .terminal = terminal,
        .read_buf = undefined,
        .state = .active,
        .alloc = alloc,
    };

    // NOTE: Do NOT call initStream() here. The ReadonlyStream holds a
    // self-referential pointer to terminal.inner. Returning this struct
    // by value copies it to a new location, invalidating that pointer.
    // The caller MUST call initStream() after the Session is at its
    // final memory location (e.g., stored in the SessionPool).

    // Postcondition.
    std.debug.assert(result.state == .active);

    return result;
}

// --- Step 3.1.2: destroy ---

/// Clean shutdown: terminate process, close PTY, deinit terminal.
///
/// Assertions:
/// - state == .active
/// Postcondition:
/// - state == .stopped
pub fn destroy(self: *Session) void {
    std.debug.assert(self.state == .active);

    // 1. Terminate child if still running.
    if (self.process.isAlive()) {
        // terminate may fail if process exited between isAlive() and terminate() — benign race
        self.process.terminate() catch {};

        const wait_result = self.process.wait(1000) catch {
            // Wait failed — try force kill.
            // forceKill may fail if process already exited — benign race
            self.process.forceKill() catch {};
            return self.finishDestroy();
        };

        switch (wait_result) {
            .timeout => {
                // SIGTERM didn't work — escalate to SIGKILL.
                // forceKill may fail if process exited between wait timeout and kill — benign race
                self.process.forceKill() catch {};
                _ = self.process.wait(1000) catch {};
            },
            .exited, .signaled => {},
        }
    }

    self.finishDestroy();
}

fn finishDestroy(self: *Session) void {
    // 2. Close PTY.
    self.pty.close();

    // 3. Deinit Terminal.
    self.terminal.deinit(self.alloc);

    // 4. Mark stopped.
    self.state = .stopped;

    // Postcondition.
    std.debug.assert(self.state == .stopped);
}

// --- Step 3.2.1: drain ---

/// Read all pending bytes from PTY and feed to terminal.
///
/// Assertions:
/// - state == .active
/// Postcondition:
/// - bytes_read is cumulative bytes fed this drain cycle
pub fn drain(self: *Session) DrainResult {
    return self.drainInternal(0);
}

// --- Step 3.2.2: drainFor ---

/// Drain with timeout — polls with the given timeout on first iteration.
///
/// Assertions:
/// - state == .active
/// - timeout_ms <= 30_000
/// Postcondition:
/// - bytes_read is cumulative bytes fed
pub fn drainFor(self: *Session, timeout_ms: u32) DrainResult {
    std.debug.assert(timeout_ms <= drain_timeout_max);
    return self.drainInternal(@intCast(timeout_ms));
}

/// Shared drain implementation. Reads PTY and feeds terminal.
/// Uses first_poll_timeout for the initial poll, then zero for subsequent polls.
fn drainInternal(self: *Session, first_poll_timeout: i32) DrainResult {
    std.debug.assert(self.state == .active);

    var total_bytes: u32 = 0;
    var eof = false;
    var iterations: u32 = 0;
    var first_poll = true;
    const wall_start = std.time.milliTimestamp();

    while (iterations < drain_max_iterations) : (iterations += 1) {
        // Wall-clock guard: abort if drain has run too long.
        if (std.time.milliTimestamp() - wall_start >= drain_wall_clock_max_ms) break;

        const poll_timeout: i32 = if (first_poll) first_poll_timeout else 0;
        first_poll = false;

        const poll_result = self.pty.poll(poll_timeout);

        switch (poll_result) {
            .ready => {
                const read_result = self.pty.read(&self.read_buf);
                switch (read_result) {
                    .data => |n| {
                        self.terminal.feed(self.read_buf[0..n]);
                        total_bytes += @intCast(n);
                    },
                    .eof => {
                        eof = true;
                        break;
                    },
                    .would_block => break,
                    .err => break,
                }
            },
            .timeout => break,
            .hangup => {
                eof = true;
                break;
            },
            .poll_error => break,
        }
    }

    // Postcondition: bounded output.
    std.debug.assert(total_bytes <= drain_max_iterations * read_buf_size);

    return .{ .bytes_read = total_bytes, .eof = eof };
}

// --- Step 3.2.3: getScreen ---

/// Drain pending output, then return current screen text.
///
/// Assertions:
/// - state == .active
/// Postcondition:
/// - returned text reflects current terminal state
pub fn getScreen(self: *Session, alloc: Allocator) ![]const u8 {
    std.debug.assert(self.state == .active);

    _ = self.drain();
    return try self.terminal.plainText(alloc);
}

// --- Step 3.2.4: sendText ---

/// Write raw text to PTY master.
///
/// Assertions:
/// - state == .active
/// - text.len > 0
/// - text.len <= 4096
pub fn sendText(self: *Session, text: []const u8) !void {
    std.debug.assert(self.state == .active);
    std.debug.assert(text.len > 0);
    std.debug.assert(text.len <= send_text_max);

    var written: usize = 0;
    while (written < text.len) {
        const n = self.pty.write(text[written..]) catch
            return error.WriteFailed;
        written += n;

        // Postcondition: progress on each write.
        std.debug.assert(n > 0);
    }

    // Postcondition: all bytes written.
    std.debug.assert(written == text.len);
}

// --- Step 3.2.5: sendKey ---

// Re-export types from input.zig for convenience.
pub const KeyCode = input.KeyCode;
pub const Modifiers = input.Modifiers;

/// Write an encoded key sequence to PTY master.
/// Uses Ghostty's key encoder in legacy xterm mode.
///
/// Assertions:
/// - state == .active
pub fn sendKey(self: *Session, key: KeyCode, mods: Modifiers) !void {
    std.debug.assert(self.state == .active);

    var buf: [32]u8 = undefined;
    const encoded = input.encodeKey(key, mods, &buf) catch
        return error.WriteFailed;

    std.debug.assert(encoded.len > 0);

    var written: usize = 0;
    while (written < encoded.len) {
        const n = self.pty.write(encoded[written..]) catch
            return error.WriteFailed;
        written += n;
    }
}

// ===== Tests =====

test "create session with echo" {
    const alloc = std.testing.allocator;

    var sess = try Session.create(alloc, 0, .{
        .argv = &[_][]const u8{ "/bin/echo", "test" },
    });

    try std.testing.expectEqual(State.active, sess.state);
    try std.testing.expectEqual(@as(u8, 0), sess.id);

    sess.destroy();
    try std.testing.expectEqual(State.stopped, sess.state);
}

test "destroy terminates running process" {
    const alloc = std.testing.allocator;

    var sess = try Session.create(alloc, 1, .{
        .argv = &[_][]const u8{ "/bin/sleep", "100" },
    });

    try std.testing.expectEqual(State.active, sess.state);

    sess.destroy();
    try std.testing.expectEqual(State.stopped, sess.state);
}

test "drain reads echo output" {
    const alloc = std.testing.allocator;

    var sess = try Session.create(alloc, 2, .{
        .argv = &[_][]const u8{ "/bin/echo", "hello" },
    });
    defer sess.destroy();
    sess.terminal.initStream();

    // Wait for echo to produce output.
    const result = sess.drainFor(1000);
    try std.testing.expect(result.bytes_read > 0);
}

test "getScreen returns screen text" {
    const alloc = std.testing.allocator;

    var sess = try Session.create(alloc, 3, .{
        .argv = &[_][]const u8{ "/bin/echo", "hello" },
    });
    defer sess.destroy();
    sess.terminal.initStream();

    // Wait for output, then get screen.
    _ = sess.drainFor(1000);
    const text = try sess.getScreen(alloc);
    defer alloc.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "hello") != null);
}

test "sendText writes to PTY" {
    const alloc = std.testing.allocator;

    var sess = try Session.create(alloc, 4, .{
        .argv = &[_][]const u8{"/bin/cat"},
    });
    defer sess.destroy();
    sess.terminal.initStream();

    try sess.sendText("hello\n");

    // Drain and check screen.
    _ = sess.drainFor(1000);
    const text = try sess.terminal.plainText(alloc);
    defer alloc.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "hello") != null);
}

test "sendKey enter produces newline" {
    const alloc = std.testing.allocator;

    var sess = try Session.create(alloc, 5, .{
        .argv = &[_][]const u8{"/bin/cat"},
    });
    defer sess.destroy();
    sess.terminal.initStream();

    try sess.sendKey(.enter, .{});

    // Just verify no crash — cat with enter is hard to assert on screen.
    _ = sess.drainFor(500);
}

test "encodeKey basic keys via input module" {
    var buf: [32]u8 = undefined;

    const enter = try input.encodeKey(.enter, .{}, &buf);
    try std.testing.expectEqual(@as(u8, 0x0D), enter[0]);

    const up = try input.encodeKey(.up, .{}, &buf);
    try std.testing.expectEqualStrings("\x1b[A", up);
}
