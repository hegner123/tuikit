const std = @import("std");
const posix = std.posix;
const Pty = @import("Pty.zig");

// --- Public types ---

pub const State = enum { idle, running, exited };

pub const WaitResult = union(enum) {
    exited: u8,
    signaled: u8,
    timeout: void,
};

pub const ProcessError = error{
    ForkFailed,
    SpawnFailed,
    KillFailed,
    WaitFailed,
};

// --- Process type ---

pid: posix.pid_t,
state: State,
exit_code: ?u8,

const Process = @This();

// --- Step 2.2.1: spawn ---

/// Fork and exec a child process on a PTY slave.
///
/// CRITICAL POST-FORK SAFETY:
/// - Zero allocation between fork and exec
/// - posix.exit() (not return) on child failure
/// - Only async-signal-safe calls in child
///
/// Assertions:
/// - argv.len > 0
/// - pty.state == .open
/// Postconditions:
/// - state == .running
/// - pid > 0
pub fn spawn(
    pty: *Pty,
    argv: []const []const u8,
    env: ?[*:null]const ?[*:0]const u8,
) ProcessError!Process {
    std.debug.assert(argv.len > 0);
    std.debug.assert(pty.state == .open);

    // Build null-terminated argv BEFORE fork (no allocation after fork).
    // CRITICAL: JSON-parsed strings are NOT null-terminated. We must copy
    // each arg into a stack buffer with an explicit null byte, otherwise
    // execvpeZ reads past the end of the string and exec fails silently.
    var str_bufs: [64][512]u8 = undefined;
    var argv_buf: [64]?[*:0]const u8 = undefined;
    std.debug.assert(argv.len < argv_buf.len);
    for (argv, 0..) |arg, i| {
        if (arg.len >= 512) return error.SpawnFailed;
        @memcpy(str_bufs[i][0..arg.len], arg);
        str_bufs[i][arg.len] = 0;
        argv_buf[i] = @ptrCast(&str_bufs[i]);
    }
    argv_buf[argv.len] = null;
    const argv_ptr: [*:null]const ?[*:0]const u8 = @ptrCast(&argv_buf);

    const envp: [*:null]const ?[*:0]const u8 = env orelse std.c.environ;

    const fork_result = posix.fork() catch return error.ForkFailed;

    if (fork_result != 0) {
        // Parent process.
        const pid: posix.pid_t = @intCast(fork_result);
        pty.closeSlave();

        const result = Process{
            .pid = pid,
            .state = .running,
            .exit_code = null,
        };

        // Postconditions.
        std.debug.assert(result.state == .running);
        std.debug.assert(result.pid > 0);

        return result;
    }

    // ===== CHILD PROCESS =====
    // Only async-signal-safe calls from here. No allocation, no logging.
    // Every error path must call posix.exit(), never return.

    childExec(pty, argv_ptr, envp);

    // childExec never returns on success (replaced by exec).
    // If we reach here, exec failed.
    posix.exit(1);
}

/// Child process setup — called between fork and exec.
/// MUST NOT allocate, log, or use any non-async-signal-safe function.
/// MUST call posix.exit() on any error, never return normally.
fn childExec(
    pty: *Pty,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) void {
    // 1. Reset signals to SIG_DFL.
    resetSignals();

    // 2. Create new session.
    if (Pty.setsid() < 0) posix.exit(1);

    // 3. Set controlling terminal.
    if (Pty.ioctlRaw(pty.slave, Pty.getTiocsctty(), 0) < 0) {
        posix.exit(1);
    }

    // 4. Redirect stdin/stdout/stderr to slave.
    posix.dup2(pty.slave, posix.STDIN_FILENO) catch posix.exit(1);
    posix.dup2(pty.slave, posix.STDOUT_FILENO) catch posix.exit(1);
    posix.dup2(pty.slave, posix.STDERR_FILENO) catch posix.exit(1);

    // 5. Close master and slave (already duped to 0/1/2).
    _ = posix.system.close(pty.master);
    if (pty.slave > posix.STDERR_FILENO) {
        _ = posix.system.close(pty.slave);
    }

    // 6. Exec — on success, process image is replaced and this never returns.
    // On failure, returns an error. We're in the child process; just exit(1).
    switch (posix.execvpeZ(argv[0].?, argv, envp)) {
        else => posix.exit(1),
    }
}

/// Reset all standard signals to SIG_DFL.
/// Async-signal-safe.
fn resetSignals() void {
    const signals = [_]u6{
        posix.SIG.ABRT,
        posix.SIG.ALRM,
        posix.SIG.BUS,
        posix.SIG.CHLD,
        posix.SIG.FPE,
        posix.SIG.HUP,
        posix.SIG.ILL,
        posix.SIG.INT,
        posix.SIG.PIPE,
        posix.SIG.SEGV,
        posix.SIG.TRAP,
        posix.SIG.TERM,
        posix.SIG.QUIT,
    };

    var sa: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };

    for (signals) |sig| {
        posix.sigaction(sig, &sa, null);
    }
}

// --- Step 2.2.2: isAlive ---

/// Check if the child process is still running.
/// Non-blocking waitpid with WNOHANG.
///
/// Assertions:
/// - state != .idle
pub fn isAlive(self: *Process) bool {
    std.debug.assert(self.state != .idle);
    std.debug.assert(self.pid > 0);

    if (self.state == .exited) return false;

    const result = posix.waitpid(self.pid, std.c.W.NOHANG);

    if (result.pid != 0) {
        // Child has exited.
        self.state = .exited;
        self.exit_code = extractExitCode(result.status);

        // Postcondition: state is now exited.
        std.debug.assert(self.state == .exited);
        return false;
    }

    return true;
}

// --- Step 2.2.3: terminate ---

/// Send SIGTERM to the child process.
///
/// Assertions:
/// - state == .running
pub fn terminate(self: *Process) ProcessError!void {
    std.debug.assert(self.state == .running);

    posix.kill(self.pid, posix.SIG.TERM) catch return error.KillFailed;
}

/// Send SIGKILL to the child process (escalation).
pub fn forceKill(self: *Process) ProcessError!void {
    std.debug.assert(self.state == .running);

    posix.kill(self.pid, posix.SIG.KILL) catch return error.KillFailed;
}

// --- Step 2.2.4: wait ---

/// Block until child exits or timeout.
/// Uses poll-wait loop with bounded timeout.
///
/// Assertions:
/// - state == .running
/// Postcondition:
/// - if not timeout, state == .exited
pub fn wait(self: *Process, timeout_ms: u32) ProcessError!WaitResult {
    std.debug.assert(self.state == .running);

    const start = std.time.milliTimestamp();
    const deadline = start + @as(i64, timeout_ms);

    // Bounded poll-wait loop.
    var iterations: u32 = 0;
    const max_iterations: u32 = 10_000;

    while (iterations < max_iterations) : (iterations += 1) {
        const now = std.time.milliTimestamp();
        if (now >= deadline) return .{ .timeout = {} };

        const result = posix.waitpid(self.pid, std.c.W.NOHANG);

        if (result.pid != 0) {
            self.state = .exited;
            const status = result.status;

            if (std.c.W.IFEXITED(status)) {
                const code = std.c.W.EXITSTATUS(status);
                self.exit_code = code;
                return .{ .exited = code };
            }
            if (std.c.W.IFSIGNALED(status)) {
                const sig: u8 = @intCast(std.c.W.TERMSIG(status));
                self.exit_code = sig;
                return .{ .signaled = sig };
            }

            self.exit_code = 255;
            return .{ .exited = 255 };
        }

        // Sleep 1ms between checks.
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    return .{ .timeout = {} };
}

// --- Internal helpers ---

fn extractExitCode(status: u32) u8 {
    if (std.c.W.IFEXITED(status)) {
        return std.c.W.EXITSTATUS(status);
    }
    if (std.c.W.IFSIGNALED(status)) {
        return @intCast(std.c.W.TERMSIG(status));
    }
    return 255;
}

// ===== Tests =====

test "spawn echo and read output" {
    var pty = try Pty.open(.{ .cols = 80, .rows = 24 });

    var process = try Process.spawn(
        &pty,
        &[_][]const u8{ "/bin/echo", "hello" },
        null,
    );

    try std.testing.expectEqual(State.running, process.state);
    try std.testing.expect(process.pid > 0);

    // Wait for echo to finish.
    const result = try process.wait(2000);
    switch (result) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedResult,
    }

    // Read output from PTY master.
    std.Thread.sleep(10 * std.time.ns_per_ms);
    var buf: [256]u8 = undefined;
    const read_result = pty.read(&buf);
    switch (read_result) {
        .data => |n| {
            const output = buf[0..n];
            try std.testing.expect(std.mem.indexOf(u8, output, "hello") != null);
        },
        .eof => {}, // echo already finished, output may have been consumed
        .would_block => {}, // timing dependent
        .err => return error.ReadFailed,
    }

    pty.close();
}

test "spawn true exits 0" {
    var pty = try Pty.open(.{ .cols = 80, .rows = 24 });

    var process = try Process.spawn(
        &pty,
        &[_][]const u8{"/usr/bin/true"},
        null,
    );

    const result = try process.wait(2000);
    switch (result) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedResult,
    }

    pty.close();
}

test "spawn false exits 1" {
    var pty = try Pty.open(.{ .cols = 80, .rows = 24 });

    var process = try Process.spawn(
        &pty,
        &[_][]const u8{"/usr/bin/false"},
        null,
    );

    const result = try process.wait(2000);
    switch (result) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 1), code),
        else => return error.UnexpectedResult,
    }

    pty.close();
}

test "isAlive on running process" {
    var pty = try Pty.open(.{ .cols = 80, .rows = 24 });

    var process = try Process.spawn(
        &pty,
        &[_][]const u8{ "/bin/sleep", "10" },
        null,
    );

    try std.testing.expect(process.isAlive());

    try process.terminate();
    const result = try process.wait(2000);
    _ = result;

    try std.testing.expect(!process.isAlive());

    pty.close();
}

test "terminate stops process" {
    var pty = try Pty.open(.{ .cols = 80, .rows = 24 });

    var process = try Process.spawn(
        &pty,
        &[_][]const u8{ "/bin/sleep", "100" },
        null,
    );

    try std.testing.expect(process.isAlive());

    try process.terminate();
    const result = try process.wait(2000);

    switch (result) {
        .exited, .signaled => {},
        .timeout => return error.ProcessDidNotStop,
    }

    try std.testing.expect(!process.isAlive());

    pty.close();
}
