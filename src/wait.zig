const std = @import("std");
const Allocator = std.mem.Allocator;
const Session = @import("Session.zig");
const screen_mod = @import("screen.zig");

// --- Constants ---

/// Maximum wait timeout (30 seconds).
const wait_timeout_max: u32 = 30_000;

/// Maximum exit wait timeout (60 seconds).
const exit_timeout_max: u32 = 60_000;

/// Poll interval between checks (10ms).
const poll_interval_ns: u64 = 10 * std.time.ns_per_ms;

/// Maximum iterations for wait loops (timeout_ms / 10ms + margin).
const max_wait_iterations: u32 = 100_000;

// --- Step 4.1.1: waitForText ---

/// Poll until screen contains the needle text.
///
/// Assertions:
/// - needle.len > 0
/// - timeout_ms <= 30_000
/// - session.state == .active
/// Postcondition:
/// - if true, screen definitely contains needle
pub fn waitForText(
    session: *Session,
    alloc: Allocator,
    needle: []const u8,
    timeout_ms: u32,
) !bool {
    std.debug.assert(needle.len > 0);
    std.debug.assert(timeout_ms <= wait_timeout_max);
    std.debug.assert(session.state == .active);

    const start = std.time.milliTimestamp();
    const deadline = start + @as(i64, timeout_ms);
    var iterations: u32 = 0;

    while (iterations < max_wait_iterations) : (iterations += 1) {
        const now = std.time.milliTimestamp();
        if (now >= deadline) return false;

        // Drain pending output.
        const drain_result = session.drain();

        // Check if screen contains needle.
        if (try screen_mod.containsText(&session.terminal, alloc, needle)) {
            return true;
        }

        // EOF — no more output coming.
        if (drain_result.eof) return false;

        // Sleep before next poll.
        std.Thread.sleep(poll_interval_ns);
    }

    return false;
}

// --- Step 4.1.2: waitForStable ---

/// Wait until no new bytes arrive for stability_ms milliseconds.
///
/// Assertions:
/// - stability_ms <= timeout_ms
/// - timeout_ms <= 30_000
/// - session.state == .active
/// Postcondition:
/// - if true, no bytes received for at least stability_ms
pub fn waitForStable(
    session: *Session,
    stability_ms: u32,
    timeout_ms: u32,
) !bool {
    std.debug.assert(stability_ms <= timeout_ms);
    std.debug.assert(timeout_ms <= wait_timeout_max);
    std.debug.assert(session.state == .active);

    const start = std.time.milliTimestamp();
    const deadline = start + @as(i64, timeout_ms);
    var iterations: u32 = 0;

    while (iterations < max_wait_iterations) : (iterations += 1) {
        const now = std.time.milliTimestamp();
        if (now >= deadline) return false;

        const bytes_before = session.terminal.bytes_fed;

        // Drain with stability_ms timeout.
        _ = session.drainFor(stability_ms);

        const bytes_after = session.terminal.bytes_fed;

        // No new bytes arrived during the stability window.
        if (bytes_after == bytes_before) return true;
    }

    return false;
}

// --- Step 4.1.3: waitForCursor ---

/// Wait until cursor reaches the given position.
///
/// Assertions:
/// - row < session.terminal.rows
/// - col < session.terminal.cols
/// - timeout_ms <= 30_000
/// - session.state == .active
pub fn waitForCursor(
    session: *Session,
    row: u16,
    col: u16,
    timeout_ms: u32,
) !bool {
    std.debug.assert(row < session.terminal.rows);
    std.debug.assert(col < session.terminal.cols);
    std.debug.assert(timeout_ms <= wait_timeout_max);
    std.debug.assert(session.state == .active);

    const start = std.time.milliTimestamp();
    const deadline = start + @as(i64, timeout_ms);
    var iterations: u32 = 0;

    while (iterations < max_wait_iterations) : (iterations += 1) {
        const now = std.time.milliTimestamp();
        if (now >= deadline) return false;

        const drain_result = session.drain();

        const pos = session.terminal.cursorPosition();
        if (pos.row == row and pos.col == col) return true;

        if (drain_result.eof) return false;

        std.Thread.sleep(poll_interval_ns);
    }

    return false;
}

// --- Step 4.1.4: waitForExit ---

/// Wait until the process exits. Returns exit code or null on timeout.
/// Drains remaining PTY output before returning.
///
/// Assertions:
/// - timeout_ms <= 60_000
/// - session.state == .active
pub fn waitForExit(
    session: *Session,
    timeout_ms: u32,
) !?u8 {
    std.debug.assert(timeout_ms <= exit_timeout_max);
    std.debug.assert(session.state == .active);

    const start = std.time.milliTimestamp();
    const deadline = start + @as(i64, timeout_ms);
    var iterations: u32 = 0;

    while (iterations < max_wait_iterations) : (iterations += 1) {
        const now = std.time.milliTimestamp();
        if (now >= deadline) return null;

        // Drain output.
        _ = session.drain();

        // Check if process exited.
        if (!session.process.isAlive()) {
            // Drain any remaining output after exit.
            _ = session.drain();
            return session.process.exit_code;
        }

        std.Thread.sleep(poll_interval_ns);
    }

    return null;
}

// ===== Tests =====

test "waitForText finds text" {
    const alloc = std.testing.allocator;

    var sess = try Session.create(alloc, 0, .{
        .argv = &[_][]const u8{ "/bin/sh", "-c", "sleep 0.1 && echo READY" },
    });
    defer sess.destroy();
    sess.terminal.initStream();

    const found = try waitForText(&sess, alloc, "READY", 2000);
    try std.testing.expect(found);
}

test "waitForText timeout on missing text" {
    const alloc = std.testing.allocator;

    var sess = try Session.create(alloc, 1, .{
        .argv = &[_][]const u8{ "/bin/echo", "hello" },
    });
    defer sess.destroy();
    sess.terminal.initStream();

    const found = try waitForText(&sess, alloc, "NEVER", 200);
    try std.testing.expect(!found);
}

test "waitForStable detects idle" {
    const alloc = std.testing.allocator;

    var sess = try Session.create(alloc, 2, .{
        .argv = &[_][]const u8{ "/bin/echo", "done" },
    });
    defer sess.destroy();
    sess.terminal.initStream();

    // Wait for echo to finish and output to stabilize.
    const stable = try waitForStable(&sess, 200, 2000);
    try std.testing.expect(stable);
}

test "waitForExit returns exit code 0" {
    const alloc = std.testing.allocator;

    var sess = try Session.create(alloc, 3, .{
        .argv = &[_][]const u8{"/usr/bin/true"},
    });
    defer sess.destroy();
    sess.terminal.initStream();

    const code = try waitForExit(&sess, 2000);
    try std.testing.expectEqual(@as(?u8, 0), code);
}

test "waitForExit returns exit code 1" {
    const alloc = std.testing.allocator;

    var sess = try Session.create(alloc, 4, .{
        .argv = &[_][]const u8{"/usr/bin/false"},
    });
    defer sess.destroy();
    sess.terminal.initStream();

    const code = try waitForExit(&sess, 2000);
    try std.testing.expectEqual(@as(?u8, 1), code);
}

test "waitForExit timeout returns null" {
    const alloc = std.testing.allocator;

    var sess = try Session.create(alloc, 5, .{
        .argv = &[_][]const u8{ "/bin/sleep", "100" },
    });
    defer sess.destroy();
    sess.terminal.initStream();

    const code = try waitForExit(&sess, 200);
    try std.testing.expectEqual(@as(?u8, null), code);
}
