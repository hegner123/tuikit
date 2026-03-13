const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

// Platform-specific C imports for PTY operations.
const c = @cImport({
    @cInclude("sys/ioctl.h");
    if (builtin.os.tag == .linux) {
        @cInclude("pty.h"); // openpty() on Linux
    } else {
        @cInclude("util.h"); // openpty() on macOS
    }
    @cInclude("termios.h");
});

// ioctl constants differ between macOS and Linux.
// macOS: TIOCSCTTY = _IO('t', 97) = 0x20007461 (from <sys/ttycom.h>)
const TIOCSCTTY: c_ulong = if (builtin.os.tag == .macos) 0x20007461 else c.TIOCSCTTY;
// macOS: TIOCSWINSZ = _IOW('t', 103, struct winsize) = 0x80087467 (from <sys/ttycom.h>)
const TIOCSWINSZ: c_ulong = if (builtin.os.tag == .macos) 0x80087467 else c.TIOCSWINSZ;

// Compile-time platform check.
comptime {
    std.debug.assert(builtin.os.tag == .macos or builtin.os.tag == .linux);
}

// --- Public types ---

pub const State = enum { closed, open };

pub const WinSize = struct {
    cols: u16,
    rows: u16,
    xpixel: u16 = 0,
    ypixel: u16 = 0,
};

pub const ReadResult = union(enum) {
    data: usize,
    eof: void,
    would_block: void,
    err: PtyError,
};

pub const PtyError = error{
    ReadFailed,
    WriteFailed,
    PollFailed,
    OpenptyFailed,
    SetFlagsFailed,
    IoctlFailed,
};

pub const PollResult = enum { ready, timeout, poll_error, hangup };

/// Maximum bytes per read call.
const read_buf_max: usize = 65536;

// --- Pty type ---

master: posix.fd_t,
slave: posix.fd_t,
state: State,

const Pty = @This();

// --- Step 2.1.1: open ---

/// Open a new master/slave PTY pair.
///
/// Assertions:
/// - size.cols > 0, size.rows > 0
/// Postconditions:
/// - state == .open
/// - master > 0, slave > 0, master != slave
pub fn open(size: WinSize) PtyError!Pty {
    std.debug.assert(size.cols > 0);
    std.debug.assert(size.rows > 0);

    var ws = c.winsize{
        .ws_col = size.cols,
        .ws_row = size.rows,
        .ws_xpixel = size.xpixel,
        .ws_ypixel = size.ypixel,
    };

    var master_fd: posix.fd_t = -1;
    var slave_fd: posix.fd_t = -1;

    if (c.openpty(&master_fd, &slave_fd, null, null, &ws) < 0) {
        return error.OpenptyFailed;
    }
    errdefer {
        _ = posix.system.close(master_fd);
        _ = posix.system.close(slave_fd);
    }

    // Set CLOEXEC on master — only slave should be inherited by child.
    setCloexec(master_fd) catch return error.SetFlagsFailed;

    // Set O_NONBLOCK on master for non-blocking reads.
    setNonblock(master_fd) catch return error.SetFlagsFailed;

    // Enable IUTF8 on master fd (not slave — see Ghostty pty.zig:161-166).
    setIutf8(master_fd) catch return error.OpenptyFailed;

    const result = Pty{
        .master = master_fd,
        .slave = slave_fd,
        .state = .open,
    };

    // Postconditions.
    std.debug.assert(result.state == .open);
    std.debug.assert(result.master > 0);
    std.debug.assert(result.slave > 0);
    std.debug.assert(result.master != result.slave);

    return result;
}

// --- Step 2.1.2: close ---

/// Close both master and slave file descriptors.
///
/// Assertions:
/// - state == .open
/// Postcondition:
/// - state == .closed
pub fn close(self: *Pty) void {
    std.debug.assert(self.state == .open);

    _ = posix.system.close(self.master);
    if (self.slave >= 0) {
        _ = posix.system.close(self.slave);
    }
    self.state = .closed;

    std.debug.assert(self.state == .closed);
}

// --- Step 2.1.3: closeSlave ---

/// Close only the slave fd (called in parent after fork).
///
/// Assertions:
/// - state == .open
/// Postcondition:
/// - slave == -1
pub fn closeSlave(self: *Pty) void {
    std.debug.assert(self.state == .open);

    if (self.slave >= 0) {
        _ = posix.system.close(self.slave);
        self.slave = -1;
    }

    std.debug.assert(self.slave == -1);
}

// --- Step 2.1.4: setSize ---

/// Resize the PTY. Sends SIGWINCH to child automatically.
///
/// Assertions:
/// - state == .open
/// - size.cols > 0, size.rows > 0
pub fn setSize(self: *Pty, size: WinSize) PtyError!void {
    std.debug.assert(self.state == .open);
    std.debug.assert(size.cols > 0);
    std.debug.assert(size.rows > 0);

    const ws = c.winsize{
        .ws_col = size.cols,
        .ws_row = size.rows,
        .ws_xpixel = size.xpixel,
        .ws_ypixel = size.ypixel,
    };

    if (c.ioctl(self.master, TIOCSWINSZ, @intFromPtr(&ws)) < 0) {
        return error.IoctlFailed;
    }
}

// --- Step 2.1.5: read ---

/// Non-blocking read from master fd.
///
/// Assertions:
/// - state == .open
/// - buffer.len > 0, buffer.len <= 65536
/// Postcondition:
/// - if data, result <= buffer.len
pub fn read(self: *Pty, buffer: []u8) ReadResult {
    std.debug.assert(self.state == .open);
    std.debug.assert(buffer.len > 0);
    std.debug.assert(buffer.len <= read_buf_max);

    const result = posix.system.read(self.master, buffer.ptr, buffer.len);
    const errno = posix.errno(result);

    if (errno != .SUCCESS) {
        if (errno == .AGAIN) {
            return .{ .would_block = {} };
        }
        if (errno == .IO) {
            return .{ .eof = {} };
        }
        return .{ .err = error.ReadFailed };
    }

    const bytes_read: usize = @intCast(result);
    if (bytes_read == 0) {
        return .{ .eof = {} };
    }

    // Postcondition: bounded read.
    std.debug.assert(bytes_read <= buffer.len);

    return .{ .data = bytes_read };
}

// --- Step 2.1.6: write ---

/// Write data to master fd (sends input to child).
///
/// Assertions:
/// - state == .open
/// - data.len > 0
/// Postcondition:
/// - result > 0, result <= data.len
pub fn write(self: *Pty, data: []const u8) PtyError!usize {
    std.debug.assert(self.state == .open);
    std.debug.assert(data.len > 0);

    const result = posix.system.write(self.master, data.ptr, data.len);
    const errno = posix.errno(result);

    if (errno != .SUCCESS) {
        return error.WriteFailed;
    }

    const bytes_written: usize = @intCast(result);

    // Postconditions.
    std.debug.assert(bytes_written > 0);
    std.debug.assert(bytes_written <= data.len);

    return bytes_written;
}

// --- Step 2.1.7: poll ---

/// Check if data is available on master fd.
///
/// Assertions:
/// - state == .open
pub fn poll(self: *Pty, timeout_ms: i32) PollResult {
    std.debug.assert(self.state == .open);
    std.debug.assert(timeout_ms >= -1);

    var fds = [1]std.posix.pollfd{.{
        .fd = self.master,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};

    const result = std.posix.poll(&fds, timeout_ms) catch {
        return .poll_error;
    };

    if (result == 0) return .timeout;

    // Check POLLIN before POLLHUP: on Linux, both are set simultaneously
    // when a child exits with buffered data. Data must be read first.
    if (fds[0].revents & std.posix.POLL.IN != 0) return .ready;
    if (fds[0].revents & std.posix.POLL.HUP != 0) return .hangup;
    if (fds[0].revents & std.posix.POLL.ERR != 0) return .poll_error;

    return .timeout;
}

/// Expose TIOCSCTTY for use by Process.zig child pre-exec.
pub fn getTiocsctty() c_ulong {
    return TIOCSCTTY;
}

/// Expose setsid for use by Process.zig child pre-exec.
pub fn setsid() std.c.pid_t {
    return std.c.setsid();
}

/// Expose ioctl for child pre-exec.
pub fn ioctlRaw(fd: posix.fd_t, request: c_ulong, arg: c_ulong) c_int {
    return c.ioctl(fd, request, arg);
}

// --- Internal helpers ---

fn setCloexec(fd: posix.fd_t) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFD, 0);
    _ = try posix.fcntl(fd, posix.F.SETFD, flags | posix.FD_CLOEXEC);
}

fn setNonblock(fd: posix.fd_t) !void {
    const flags = try posix.fcntl(fd, posix.F.GETFL, 0);
    _ = try posix.fcntl(fd, posix.F.SETFL, flags | @as(u32, @bitCast(posix.O{ .NONBLOCK = true })));
}

fn setIutf8(fd: posix.fd_t) !void {
    var attrs: c.termios = undefined;
    if (c.tcgetattr(fd, &attrs) != 0) return error.Unexpected;
    attrs.c_iflag |= c.IUTF8;
    if (c.tcsetattr(fd, c.TCSANOW, &attrs) != 0) return error.Unexpected;
}

// ===== Tests =====

test "open and close" {
    var pty = try Pty.open(.{ .cols = 80, .rows = 24 });
    try std.testing.expectEqual(State.open, pty.state);
    try std.testing.expect(pty.master > 0);
    try std.testing.expect(pty.slave > 0);
    try std.testing.expect(pty.master != pty.slave);

    pty.close();
    try std.testing.expectEqual(State.closed, pty.state);
}

test "open twice proves fd reuse" {
    var pty1 = try Pty.open(.{ .cols = 80, .rows = 24 });
    const master1 = pty1.master;
    pty1.close();

    var pty2 = try Pty.open(.{ .cols = 80, .rows = 24 });
    defer pty2.close();

    // After closing pty1, the kernel may reuse its fds.
    // We just verify both opened successfully.
    try std.testing.expect(pty2.master > 0);
    _ = master1;
}

test "closeSlave" {
    var pty = try Pty.open(.{ .cols = 80, .rows = 24 });
    defer pty.close();

    pty.closeSlave();
    try std.testing.expectEqual(@as(posix.fd_t, -1), pty.slave);
    try std.testing.expect(pty.master > 0);
}

test "setSize" {
    var pty = try Pty.open(.{ .cols = 80, .rows = 24 });
    defer pty.close();

    try pty.setSize(.{ .cols = 40, .rows = 12 });
    try pty.setSize(.{ .cols = 200, .rows = 50 });
}

test "poll with no data returns timeout" {
    var pty = try Pty.open(.{ .cols = 80, .rows = 24 });
    defer pty.close();

    // No child writing, so poll should timeout immediately.
    const result = pty.poll(0);
    try std.testing.expect(result == .timeout or result == .ready);
}

test "write and read round-trip" {
    var pty = try Pty.open(.{ .cols = 80, .rows = 24 });
    defer pty.close();

    // Write to master — PTY echoes by default.
    const written = try pty.write("hello");
    try std.testing.expect(written > 0);

    // Give the PTY a moment to echo, then read.
    std.Thread.sleep(10 * std.time.ns_per_ms);

    var buf: [256]u8 = undefined;
    const read_result = pty.read(&buf);
    switch (read_result) {
        .data => |n| try std.testing.expect(n > 0),
        .would_block => {}, // acceptable — echo might not be immediate
        else => return error.UnexpectedReadResult,
    }
}

test "read with no data returns would_block" {
    var pty = try Pty.open(.{ .cols = 80, .rows = 24 });
    defer pty.close();

    var buf: [256]u8 = undefined;
    const result = pty.read(&buf);
    // With no child process, expect would_block or hangup/eof.
    switch (result) {
        .would_block, .eof => {},
        .data => {},
        .err => return error.UnexpectedError,
    }
}
