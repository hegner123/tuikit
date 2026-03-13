const std = @import("std");
const ghostty_vt = @import("ghostty-vt");

// --- Re-export Ghostty types for convenience ---

const GhosttyKey = ghostty_vt.input.Key;
const GhosttyMods = ghostty_vt.input.KeyMods;
const GhosttyEvent = ghostty_vt.input.KeyEvent;
const GhosttyOpts = ghostty_vt.input.KeyEncodeOptions;
const ghosttyEncode = ghostty_vt.input.encodeKey;

// --- Public types ---

/// Simplified key codes for TUI testing.
/// Maps to Ghostty's input.Key internally.
pub const KeyCode = enum {
    enter,
    tab,
    escape,
    backspace,
    delete,
    space,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    insert,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    // Letters for ctrl+letter combos.
    a,
    b,
    c,
    d,
    e,
    f,
    g,
    h,
    i,
    j,
    k,
    l,
    m,
    n,
    o,
    p,
    q,
    r,
    s,
    t,
    u,
    v,
    w,
    x,
    y,
    z,
};

/// Simplified modifier set for TUI testing.
pub const Modifiers = packed struct {
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
    _padding: u5 = 0,
};

// --- Constants ---

/// Minimum buffer size for encoding.
const min_buf_size: usize = 32;

// --- Step 4.2.1: encodeKey ---

/// Encode a key press using Ghostty's key encoder (legacy xterm mode).
///
/// Assertions:
/// - buffer.len >= 32
/// Postcondition:
/// - returned slice.len > 0
pub fn encodeKey(key: KeyCode, mods: Modifiers, buffer: []u8) ![]const u8 {
    std.debug.assert(buffer.len >= min_buf_size);

    const ghostty_key = mapKey(key);
    const ghostty_mods = mapMods(mods);

    // Build utf8 text for character keys with no modifiers.
    const utf8 = keyToUtf8(key, mods);

    const event = GhosttyEvent{
        .key = ghostty_key,
        .mods = ghostty_mods,
        .utf8 = utf8,
    };

    const opts = GhosttyOpts{
        // Legacy xterm mode — maximum compatibility.
        .kitty_flags = .disabled,
        .cursor_key_application = false,
        .keypad_key_application = false,
        .alt_esc_prefix = true,
    };

    var writer: std.Io.Writer = .fixed(buffer);
    try ghosttyEncode(&writer, event, opts);
    const result = writer.buffered();

    // Postcondition: something was encoded.
    std.debug.assert(result.len > 0);

    return result;
}

// --- Internal mappings ---

fn mapKey(key: KeyCode) GhosttyKey {
    return switch (key) {
        .enter => .enter,
        .tab => .tab,
        .escape => .escape,
        .backspace => .backspace,
        .delete => .delete,
        .space => .space,
        .up => .arrow_up,
        .down => .arrow_down,
        .left => .arrow_left,
        .right => .arrow_right,
        .home => .home,
        .end => .end,
        .page_up => .page_up,
        .page_down => .page_down,
        .insert => .insert,
        .f1 => .f1,
        .f2 => .f2,
        .f3 => .f3,
        .f4 => .f4,
        .f5 => .f5,
        .f6 => .f6,
        .f7 => .f7,
        .f8 => .f8,
        .f9 => .f9,
        .f10 => .f10,
        .f11 => .f11,
        .f12 => .f12,
        .a => .key_a,
        .b => .key_b,
        .c => .key_c,
        .d => .key_d,
        .e => .key_e,
        .f => .key_f,
        .g => .key_g,
        .h => .key_h,
        .i => .key_i,
        .j => .key_j,
        .k => .key_k,
        .l => .key_l,
        .m => .key_m,
        .n => .key_n,
        .o => .key_o,
        .p => .key_p,
        .q => .key_q,
        .r => .key_r,
        .s => .key_s,
        .t => .key_t,
        .u => .key_u,
        .v => .key_v,
        .w => .key_w,
        .x => .key_x,
        .y => .key_y,
        .z => .key_z,
    };
}

fn mapMods(mods: Modifiers) GhosttyMods {
    return .{
        .ctrl = mods.ctrl,
        .alt = mods.alt,
        .shift = mods.shift,
    };
}

/// Generate UTF-8 text for character keys when unmodified or shift-only.
fn keyToUtf8(key: KeyCode, mods: Modifiers) []const u8 {
    // Only provide utf8 for unmodified or shift-only presses.
    if (mods.ctrl or mods.alt) return "";

    if (mods.shift) {
        return switch (key) {
            .a => "A",
            .b => "B",
            .c => "C",
            .d => "D",
            .e => "E",
            .f => "F",
            .g => "G",
            .h => "H",
            .i => "I",
            .j => "J",
            .k => "K",
            .l => "L",
            .m => "M",
            .n => "N",
            .o => "O",
            .p => "P",
            .q => "Q",
            .r => "R",
            .s => "S",
            .t => "T",
            .u => "U",
            .v => "V",
            .w => "W",
            .x => "X",
            .y => "Y",
            .z => "Z",
            .space => " ",
            else => "",
        };
    }

    return switch (key) {
        .a => "a",
        .b => "b",
        .c => "c",
        .d => "d",
        .e => "e",
        .f => "f",
        .g => "g",
        .h => "h",
        .i => "i",
        .j => "j",
        .k => "k",
        .l => "l",
        .m => "m",
        .n => "n",
        .o => "o",
        .p => "p",
        .q => "q",
        .r => "r",
        .s => "s",
        .t => "t",
        .u => "u",
        .v => "v",
        .w => "w",
        .x => "x",
        .y => "y",
        .z => "z",
        .space => " ",
        .enter => "\r",
        .tab => "\t",
        .backspace => "\x7f",
        else => "",
    };
}

// ===== Tests =====

test "encodeKey enter" {
    var buf: [32]u8 = undefined;
    const result = try encodeKey(.enter, .{}, &buf);
    try std.testing.expect(result.len > 0);
    // Enter should encode as CR (\r = 0x0D).
    try std.testing.expectEqual(@as(u8, 0x0D), result[0]);
}

test "encodeKey escape" {
    var buf: [32]u8 = undefined;
    const result = try encodeKey(.escape, .{}, &buf);
    try std.testing.expect(result.len > 0);
    // Escape should encode as ESC (0x1B).
    try std.testing.expectEqual(@as(u8, 0x1B), result[0]);
}

test "encodeKey arrows" {
    var buf: [32]u8 = undefined;

    const up = try encodeKey(.up, .{}, &buf);
    try std.testing.expectEqualStrings("\x1b[A", up);

    const down = try encodeKey(.down, .{}, &buf);
    try std.testing.expectEqualStrings("\x1b[B", down);

    const right = try encodeKey(.right, .{}, &buf);
    try std.testing.expectEqualStrings("\x1b[C", right);

    const left = try encodeKey(.left, .{}, &buf);
    try std.testing.expectEqualStrings("\x1b[D", left);
}

test "encodeKey ctrl+c" {
    var buf: [32]u8 = undefined;
    const result = try encodeKey(.c, .{ .ctrl = true }, &buf);
    try std.testing.expect(result.len > 0);
    // Ctrl+C should produce ETX (0x03).
    try std.testing.expectEqual(@as(u8, 0x03), result[0]);
}

test "encodeKey f1" {
    var buf: [32]u8 = undefined;
    const result = try encodeKey(.f1, .{}, &buf);
    try std.testing.expect(result.len > 0);
    // F1 in legacy mode is ESC O P.
    try std.testing.expectEqualStrings("\x1bOP", result);
}

test "encodeKey shift+up" {
    var buf: [32]u8 = undefined;
    const result = try encodeKey(.up, .{ .shift = true }, &buf);
    try std.testing.expect(result.len > 0);
    // Shift+Up in xterm legacy: ESC[1;2A
    try std.testing.expectEqualStrings("\x1b[1;2A", result);
}
