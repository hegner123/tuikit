const ghostty_vt = @import("ghostty-vt");

// tuikit — TUI testing toolkit built on ghostty-vt.
// This is the library root. All public API is re-exported from here.

// Verify ghostty-vt linkage at compile time.
comptime {
    // Terminal type must exist and be a struct.
    const terminal_info = @typeInfo(ghostty_vt.Terminal);
    if (terminal_info != .@"struct") @compileError("ghostty_vt.Terminal is not a struct");

    // Screen type must exist — used for cursor and cell access.
    const screen_info = @typeInfo(ghostty_vt.Screen);
    if (screen_info != .@"struct") @compileError("ghostty_vt.Screen is not a struct");
}

// Public API re-exports.
pub const Terminal = @import("Terminal.zig");
pub const screen = @import("screen.zig");
pub const Pty = @import("Pty.zig");
pub const Process = @import("Process.zig");
pub const Session = @import("Session.zig");
pub const SessionPool = @import("SessionPool.zig");
pub const wait = @import("wait.zig");
pub const input = @import("input.zig");
pub const snapshot = @import("snapshot.zig");
pub const mcp = @import("mcp.zig");
pub const tools = @import("tools.zig");

// Re-export testing helpers for test discovery.
pub const testing_helpers = @import("testing_helpers.zig");
pub const integration_tests = @import("integration_tests.zig");

test "ghostty-vt linkage" {
    const std = @import("std");
    // Verify Terminal and ReadonlyStream types are accessible.
    try std.testing.expect(@sizeOf(ghostty_vt.Terminal) > 0);
    try std.testing.expect(@sizeOf(ghostty_vt.Screen) > 0);
}

test {
    // Pull in tests from all submodules.
    @import("std").testing.refAllDecls(@This());
}
