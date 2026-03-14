const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const mcp = @import("mcp.zig");
const SessionPool = @import("SessionPool.zig");
const Session = @import("Session.zig");
const screen_mod = @import("screen.zig");
const wait_mod = @import("wait.zig");
const snapshot_mod = @import("snapshot.zig");
const input = @import("input.zig");
const record_mod = @import("record.zig");
const JsonValue = mcp.JsonValue;

// --- Public types ---

pub const ToolDef = struct {
    name: []const u8,
    description: []const u8,
};

// --- Key batch constants ---

const keys_max_tokens: u16 = 64;
const key_token_max_len: u16 = 256;
const key_repeat_max: u8 = 99;
const default_settle_ms: u32 = 50;

comptime {
    std.debug.assert(keys_max_tokens > 0 and keys_max_tokens <= 64);
    std.debug.assert(key_token_max_len > 0);
    std.debug.assert(key_repeat_max > 0 and key_repeat_max <= 99);
    std.debug.assert(default_settle_ms > 0 and default_settle_ms <= 5000);
}

// --- Key batch types ---

const RepeatResult = struct {
    base: []const u8,
    count: u8,
};

const ModKeyResult = struct {
    key: input.KeyCode,
    mods: input.Modifiers,
};

const KeyAction = union(enum) {
    text: []const u8,
    key_press: struct {
        key: input.KeyCode,
        mods: input.Modifiers,
        count: u8,
    },
};

const BatchError = struct {
    message: []const u8,
    processed: u16,
};

// --- Constants ---

const tool_defs = [_]ToolDef{
    .{ .name = "tui_start", .description = "Start a TUI program and return initial screen state" },
    .{ .name = "tui_send", .description = "Send input and return screen state" },
    .{ .name = "tui_screen", .description = "Get the current screen content" },
    .{ .name = "tui_cell", .description = "Get a single cell's attributes" },
    .{ .name = "tui_wait", .description = "Wait for a condition and return screen state" },
    .{ .name = "tui_resize", .description = "Resize terminal and return screen state" },
    .{ .name = "tui_snapshot", .description = "Capture or compare a screen snapshot" },
    .{ .name = "tui_stop", .description = "Stop a session and get exit code" },
    .{ .name = "tui_record_start", .description = "Start recording tool calls to a JSONL file" },
    .{ .name = "tui_record_stop", .description = "Stop recording and close the file" },
};

// --- Step 6.2.1: toolList ---

/// Return tool definitions for MCP tools/list response.
pub fn toolList(alloc: Allocator) !JsonValue {
    var tools_array = json.Array.init(alloc);

    for (tool_defs) |td| {
        var tool_obj = json.ObjectMap.init(alloc);
        try tool_obj.put("name", .{ .string = td.name });
        try tool_obj.put("description", .{ .string = td.description });
        try tool_obj.put("inputSchema", try inputSchema(alloc, td.name));
        try tools_array.append(.{ .object = tool_obj });
    }

    var result = json.ObjectMap.init(alloc);
    try result.put("tools", .{ .array = tools_array });

    return .{ .object = result };
}

fn inputSchema(alloc: Allocator, tool_name: []const u8) !JsonValue {
    var props = json.ObjectMap.init(alloc);
    var required = json.Array.init(alloc);

    if (std.mem.eql(u8, tool_name, "tui_start")) {
        try addProp(&props, alloc, "command", "string", "Command to run");
        try addProp(&props, alloc, "args", "array", "Command arguments");
        try addProp(&props, alloc, "cols", "integer", "Terminal columns (default 80)");
        try addProp(&props, alloc, "rows", "integer", "Terminal rows (default 24)");
        try addRegionProp(&props, alloc);
        try required.append(.{ .string = "command" });
    } else if (std.mem.eql(u8, tool_name, "tui_send")) {
        try addProp(&props, alloc, "session_id", "integer", "Session ID");
        try addProp(&props, alloc, "keys", "array", "Key tokens: key name, mod+key, key*N, text:literal. Prefix text: is reserved.");
        try addProp(&props, alloc, "settle_ms", "integer", "Wait ms for child to react after input (default 50, max 5000, 0 to skip)");
        try addProp(&props, alloc, "text", "string", "Text to send (legacy, use keys instead)");
        try addProp(&props, alloc, "key", "string", "Key name (legacy, use keys instead)");
        try addProp(&props, alloc, "mods", "array", "Modifier keys [ctrl, alt, shift] (legacy)");
        try addRegionProp(&props, alloc);
        try required.append(.{ .string = "session_id" });
    } else if (std.mem.eql(u8, tool_name, "tui_screen")) {
        try addProp(&props, alloc, "session_id", "integer", "Session ID");
        try addRegionProp(&props, alloc);
        try required.append(.{ .string = "session_id" });
    } else if (std.mem.eql(u8, tool_name, "tui_cell")) {
        try addProp(&props, alloc, "session_id", "integer", "Session ID");
        try addProp(&props, alloc, "row", "integer", "Row number");
        try addProp(&props, alloc, "col", "integer", "Column number");
        try required.append(.{ .string = "session_id" });
        try required.append(.{ .string = "row" });
        try required.append(.{ .string = "col" });
    } else if (std.mem.eql(u8, tool_name, "tui_wait")) {
        try addProp(&props, alloc, "session_id", "integer", "Session ID");
        try addProp(&props, alloc, "text", "string", "Text to wait for");
        try addProp(&props, alloc, "stable_ms", "integer", "Stability duration ms");
        try addProp(&props, alloc, "cursor_row", "integer", "Cursor row to wait for");
        try addProp(&props, alloc, "cursor_col", "integer", "Cursor col to wait for");
        try addProp(&props, alloc, "timeout_ms", "integer", "Timeout in ms (default 5000)");
        try addRegionProp(&props, alloc);
        try required.append(.{ .string = "session_id" });
    } else if (std.mem.eql(u8, tool_name, "tui_resize")) {
        try addProp(&props, alloc, "session_id", "integer", "Session ID");
        try addProp(&props, alloc, "cols", "integer", "New columns");
        try addProp(&props, alloc, "rows", "integer", "New rows");
        try addRegionProp(&props, alloc);
        try required.append(.{ .string = "session_id" });
        try required.append(.{ .string = "cols" });
        try required.append(.{ .string = "rows" });
    } else if (std.mem.eql(u8, tool_name, "tui_snapshot")) {
        try addProp(&props, alloc, "session_id", "integer", "Session ID");
        try addProp(&props, alloc, "golden_path", "string", "Path to golden file");
        try required.append(.{ .string = "session_id" });
    } else if (std.mem.eql(u8, tool_name, "tui_stop")) {
        try addProp(&props, alloc, "session_id", "integer", "Session ID");
        try required.append(.{ .string = "session_id" });
    } else if (std.mem.eql(u8, tool_name, "tui_record_start")) {
        try addProp(&props, alloc, "path", "string", "File path for JSONL recording");
        try required.append(.{ .string = "path" });
    } else if (std.mem.eql(u8, tool_name, "tui_record_stop")) {
        // No params.
    }

    var schema = json.ObjectMap.init(alloc);
    try schema.put("type", .{ .string = "object" });
    try schema.put("properties", .{ .object = props });
    try schema.put("required", .{ .array = required });

    return .{ .object = schema };
}

fn addProp(
    props: *json.ObjectMap,
    alloc: Allocator,
    name: []const u8,
    typ: []const u8,
    desc: []const u8,
) !void {
    var prop = json.ObjectMap.init(alloc);
    try prop.put("type", .{ .string = typ });
    try prop.put("description", .{ .string = desc });
    try props.put(name, .{ .object = prop });
}

fn addRegionProp(props: *json.ObjectMap, alloc: Allocator) !void {
    // Build nested schema: {type: "object", properties: {row, col, width, height}, description: ...}
    var region_props = json.ObjectMap.init(alloc);
    try addProp(&region_props, alloc, "row", "integer", "Top row (default 0)");
    try addProp(&region_props, alloc, "col", "integer", "Left column (default 0)");
    try addProp(&region_props, alloc, "width", "integer", "Region width (default terminal cols)");
    try addProp(&region_props, alloc, "height", "integer", "Region height (default terminal rows)");

    var region_schema = json.ObjectMap.init(alloc);
    try region_schema.put("type", .{ .string = "object" });
    try region_schema.put("description", .{ .string = "Crop screen to region. Clamped to terminal bounds." });
    try region_schema.put("properties", .{ .object = region_props });

    try props.put("region", .{ .object = region_schema });
}

// --- Step 6.2.2: dispatch ---

/// Route a tool call to the appropriate handler.
///
/// Assertions:
/// - tool_name matches a known tool
pub fn dispatch(
    pool: *SessionPool,
    recording_state: *record_mod.RecordingState,
    alloc: Allocator,
    tool_name: []const u8,
    args: JsonValue,
) !JsonValue {
    std.debug.assert(tool_name.len > 0);

    if (std.mem.eql(u8, tool_name, "tui_record_start")) return handleRecordStart(recording_state, alloc, args);
    if (std.mem.eql(u8, tool_name, "tui_record_stop")) return handleRecordStop(recording_state, alloc);
    if (std.mem.eql(u8, tool_name, "tui_start")) return handleStart(pool, alloc, args);
    if (std.mem.eql(u8, tool_name, "tui_send")) return handleSend(pool, alloc, args);
    if (std.mem.eql(u8, tool_name, "tui_screen")) return handleScreen(pool, alloc, args);
    if (std.mem.eql(u8, tool_name, "tui_cell")) return handleCell(pool, alloc, args);
    if (std.mem.eql(u8, tool_name, "tui_wait")) return handleWait(pool, alloc, args);
    if (std.mem.eql(u8, tool_name, "tui_resize")) return handleResize(pool, alloc, args);
    if (std.mem.eql(u8, tool_name, "tui_snapshot")) return handleSnapshot(pool, alloc, args);
    if (std.mem.eql(u8, tool_name, "tui_stop")) return handleStop(pool, alloc, args);

    return jsonError(alloc, "unknown tool");
}

// --- Step 2.2: Record handlers ---

fn handleRecordStart(
    state: *record_mod.RecordingState,
    alloc: Allocator,
    args: JsonValue,
) !JsonValue {
    const obj = if (args == .object) args.object else return jsonError(alloc, "invalid args");

    const path = if (obj.get("path")) |v| switch (v) {
        .string => |s| s,
        else => return jsonError(alloc, "path must be string"),
    } else return jsonError(alloc, "missing path");

    record_mod.startRecording(state, path) catch |err| switch (err) {
        record_mod.RecordError.AlreadyRecording => return jsonError(alloc, "already recording — call tui_record_stop first"),
        record_mod.RecordError.WriteFailed => return jsonError(alloc, "failed to create recording file"),
        else => return jsonError(alloc, "recording error"),
    };

    var result = json.ObjectMap.init(alloc);
    try result.put("ok", .{ .bool = true });
    try result.put("path", .{ .string = path });
    return .{ .object = result };
}

fn handleRecordStop(
    state: *record_mod.RecordingState,
    alloc: Allocator,
) !JsonValue {
    record_mod.stopRecording(state) catch |err| switch (err) {
        record_mod.RecordError.NotRecording => return jsonError(alloc, "not recording"),
        else => return jsonError(alloc, "recording error"),
    };

    var result = json.ObjectMap.init(alloc);
    try result.put("ok", .{ .bool = true });
    return .{ .object = result };
}

// --- Step 6.3.1: handleStart ---

fn handleStart(pool: *SessionPool, alloc: Allocator, args: JsonValue) !JsonValue {
    const obj = if (args == .object) args.object else return jsonError(alloc, "invalid args");

    const command = if (obj.get("command")) |v| switch (v) {
        .string => |s| s,
        else => return jsonError(alloc, "command must be string"),
    } else return jsonError(alloc, "missing command");

    // Build argv.
    var argv_buf: [64][]const u8 = undefined;
    argv_buf[0] = command;
    var argc: usize = 1;

    if (obj.get("args")) |v| {
        if (v == .array) {
            for (v.array.items) |item| {
                if (item == .string and argc < argv_buf.len - 1) {
                    argv_buf[argc] = item.string;
                    argc += 1;
                }
            }
        }
    }

    const cols: u16 = if (obj.get("cols")) |v| switch (v) {
        .integer => |i| @intCast(@min(@max(i, 1), 500)),
        else => 80,
    } else 80;

    const rows: u16 = if (obj.get("rows")) |v| switch (v) {
        .integer => |i| @intCast(@min(@max(i, 1), 500)),
        else => 24,
    } else 24;

    const id = pool.create(.{
        .cols = cols,
        .rows = rows,
        .argv = argv_buf[0..argc],
    }) catch return jsonError(alloc, "failed to create session");

    const sess = pool.get(id) catch return jsonError(alloc, "session not found");
    _ = sess.drainFor(100);

    var result = json.ObjectMap.init(alloc);
    try result.put("session_id", .{ .integer = id });
    try appendScreenFields(&result, sess, alloc, obj);
    return .{ .object = result };
}

// --- Step 6.3.2: handleSend ---

fn handleSend(pool: *SessionPool, alloc: Allocator, args: JsonValue) !JsonValue {
    const obj = if (args == .object) args.object else return jsonError(alloc, "invalid args");

    const session_id = getSessionId(obj) orelse return jsonError(alloc, "missing session_id");
    const sess = pool.get(session_id) catch return jsonError(alloc, "session not found");

    // Keys batch path — takes precedence over legacy text/key.
    if (obj.get("keys")) |kv| {
        if (kv == .array) {
            if (kv.array.items.len == 0) return jsonError(alloc, "keys array is empty");
            if (kv.array.items.len > keys_max_tokens) return jsonError(alloc, "keys array too large");

            if (try executeKeyBatch(sess, kv.array, alloc)) |batch_err| {
                var err_result = json.ObjectMap.init(alloc);
                try err_result.put("error", .{ .string = batch_err.message });
                try err_result.put("processed", .{ .integer = batch_err.processed });
                return .{ .object = err_result };
            }
        }
    } else {
        // Legacy text/key path — parsing preserved, response shape changed.
        if (obj.get("text")) |v| {
            if (v == .string) {
                sess.sendText(v.string) catch return jsonError(alloc, "send failed");
            }
        }
        if (obj.get("key")) |v| {
            if (v == .string) {
                const key = parseKeyCode(v.string) orelse return jsonError(alloc, "unknown key");
                var mods = input.Modifiers{};
                if (obj.get("mods")) |mv| {
                    if (mv == .array) {
                        for (mv.array.items) |item| {
                            if (item == .string) {
                                if (std.mem.eql(u8, item.string, "ctrl")) mods.ctrl = true;
                                if (std.mem.eql(u8, item.string, "alt")) mods.alt = true;
                                if (std.mem.eql(u8, item.string, "shift")) mods.shift = true;
                            }
                        }
                    }
                }
                sess.sendKey(key, mods) catch return jsonError(alloc, "sendKey failed");
            }
        }
    }

    // Settle: let child process react to input.
    const settle_ms: u32 = if (obj.get("settle_ms")) |v| switch (v) {
        .integer => |i| @intCast(@min(@max(i, 0), 5000)),
        else => default_settle_ms,
    } else default_settle_ms;

    _ = sess.drainFor(settle_ms);

    var result = json.ObjectMap.init(alloc);
    try appendScreenFields(&result, sess, alloc, obj);
    return .{ .object = result };
}

// --- Step 6.3.3: handleScreen ---

fn handleScreen(pool: *SessionPool, alloc: Allocator, args: JsonValue) !JsonValue {
    const obj = if (args == .object) args.object else return jsonError(alloc, "invalid args");

    const session_id = getSessionId(obj) orelse return jsonError(alloc, "missing session_id");
    const sess = pool.get(session_id) catch return jsonError(alloc, "session not found");

    var result = json.ObjectMap.init(alloc);
    try appendScreenFields(&result, sess, alloc, obj);
    return .{ .object = result };
}

// --- Step 6.3.4: handleCell ---

fn handleCell(pool: *SessionPool, alloc: Allocator, args: JsonValue) !JsonValue {
    const obj = if (args == .object) args.object else return jsonError(alloc, "invalid args");

    const session_id = getSessionId(obj) orelse return jsonError(alloc, "missing session_id");
    const sess = pool.get(session_id) catch return jsonError(alloc, "session not found");

    _ = sess.drain();

    const row: u16 = if (obj.get("row")) |v| switch (v) {
        .integer => |i| @intCast(@min(@max(i, 0), sess.terminal.rows - 1)),
        else => return jsonError(alloc, "row must be integer"),
    } else return jsonError(alloc, "missing row");

    const col: u16 = if (obj.get("col")) |v| switch (v) {
        .integer => |i| @intCast(@min(@max(i, 0), sess.terminal.cols - 1)),
        else => return jsonError(alloc, "col must be integer"),
    } else return jsonError(alloc, "missing col");

    const cell = screen_mod.cellAt(&sess.terminal, row, col);

    var result = json.ObjectMap.init(alloc);

    // Encode char as string.
    if (cell.char != 0) {
        var char_buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cell.char, &char_buf) catch 0;
        if (len > 0) {
            try result.put("char", .{ .string = try alloc.dupe(u8, char_buf[0..len]) });
        } else {
            try result.put("char", .{ .string = "" });
        }
    } else {
        try result.put("char", .{ .string = "" });
    }

    try result.put("bold", .{ .bool = cell.bold });
    try result.put("italic", .{ .bool = cell.italic });
    try result.put("underline", .{ .bool = cell.underline });
    try result.put("strikethrough", .{ .bool = cell.strikethrough });
    try result.put("dim", .{ .bool = cell.dim });

    // Encode fg/bg.
    try result.put("fg", try colorToJson(alloc, cell.fg));
    try result.put("bg", try colorToJson(alloc, cell.bg));

    return .{ .object = result };
}

fn colorToJson(alloc: Allocator, color: screen_mod.ColorInfo) !JsonValue {
    return switch (color) {
        .default => .{ .string = "default" },
        .palette => |p| blk: {
            const s = try std.fmt.allocPrint(alloc, "palette:{d}", .{p});
            break :blk .{ .string = s };
        },
        .rgb => |rgb| blk: {
            const s = try std.fmt.allocPrint(alloc, "#{x:0>2}{x:0>2}{x:0>2}", .{ rgb.r, rgb.g, rgb.b });
            break :blk .{ .string = s };
        },
    };
}

// --- Step 6.3.5: handleWait ---

fn handleWait(pool: *SessionPool, alloc: Allocator, args: JsonValue) !JsonValue {
    const obj = if (args == .object) args.object else return jsonError(alloc, "invalid args");

    const session_id = getSessionId(obj) orelse return jsonError(alloc, "missing session_id");
    const sess = pool.get(session_id) catch return jsonError(alloc, "session not found");

    const timeout_ms: u32 = if (obj.get("timeout_ms")) |v| switch (v) {
        .integer => |i| @intCast(@min(@max(i, 100), 30_000)),
        else => 5000,
    } else 5000;

    // Determine wait type.
    if (obj.get("text")) |v| {
        if (v == .string) {
            const matched = try wait_mod.waitForText(sess, alloc, v.string, timeout_ms);
            var result = json.ObjectMap.init(alloc);
            try result.put("matched", .{ .bool = matched });
            try appendScreenFields(&result, sess, alloc, obj);
            return .{ .object = result };
        }
    }

    if (obj.get("stable_ms")) |v| {
        if (v == .integer) {
            const stable_ms: u32 = @intCast(@min(@max(v.integer, 10), timeout_ms));
            const matched = try wait_mod.waitForStable(sess, stable_ms, timeout_ms);
            var result = json.ObjectMap.init(alloc);
            try result.put("matched", .{ .bool = matched });
            try appendScreenFields(&result, sess, alloc, obj);
            return .{ .object = result };
        }
    }

    if (obj.get("cursor_row")) |rv| {
        if (obj.get("cursor_col")) |cv| {
            if (rv == .integer and cv == .integer) {
                const row: u16 = @intCast(@min(@max(rv.integer, 0), sess.terminal.rows - 1));
                const col: u16 = @intCast(@min(@max(cv.integer, 0), sess.terminal.cols - 1));
                const matched = try wait_mod.waitForCursor(sess, row, col, timeout_ms);
                var result = json.ObjectMap.init(alloc);
                try result.put("matched", .{ .bool = matched });
                try appendScreenFields(&result, sess, alloc, obj);
                return .{ .object = result };
            }
        }
    }

    // No specific condition — wait for exit.
    const exit_code = try wait_mod.waitForExit(sess, timeout_ms);
    var result = json.ObjectMap.init(alloc);
    try result.put("matched", .{ .bool = exit_code != null });
    if (exit_code) |code| {
        try result.put("exit_code", .{ .integer = code });
    }
    try appendScreenFields(&result, sess, alloc, obj);
    return .{ .object = result };
}

// --- Step 6.3.6: handleResize ---

fn handleResize(pool: *SessionPool, alloc: Allocator, args: JsonValue) !JsonValue {
    const obj = if (args == .object) args.object else return jsonError(alloc, "invalid args");

    const session_id = getSessionId(obj) orelse return jsonError(alloc, "missing session_id");
    const sess = pool.get(session_id) catch return jsonError(alloc, "session not found");

    const cols: u16 = if (obj.get("cols")) |v| switch (v) {
        .integer => |i| @intCast(@min(@max(i, 1), 500)),
        else => return jsonError(alloc, "cols must be integer"),
    } else return jsonError(alloc, "missing cols");

    const rows: u16 = if (obj.get("rows")) |v| switch (v) {
        .integer => |i| @intCast(@min(@max(i, 1), 500)),
        else => return jsonError(alloc, "rows must be integer"),
    } else return jsonError(alloc, "missing rows");

    sess.terminal.resize(alloc, cols, rows) catch
        return jsonError(alloc, "resize failed");

    sess.pty.setSize(.{ .cols = cols, .rows = rows }) catch
        return jsonError(alloc, "pty resize failed");

    var result = json.ObjectMap.init(alloc);
    try appendScreenFields(&result, sess, alloc, obj);
    return .{ .object = result };
}

// --- Step 6.3.7: handleSnapshot ---

fn handleSnapshot(pool: *SessionPool, alloc: Allocator, args: JsonValue) !JsonValue {
    const obj = if (args == .object) args.object else return jsonError(alloc, "invalid args");

    const session_id = getSessionId(obj) orelse return jsonError(alloc, "missing session_id");
    const sess = pool.get(session_id) catch return jsonError(alloc, "session not found");

    var snap = try snapshot_mod.capture(sess, alloc);
    defer snap.deinit(alloc);

    var result = json.ObjectMap.init(alloc);
    try result.put("text", .{ .string = try alloc.dupe(u8, snap.text) });
    try result.put("cols", .{ .integer = snap.cols });
    try result.put("rows", .{ .integer = snap.rows });
    try result.put("cursor_row", .{ .integer = snap.cursor_row });
    try result.put("cursor_col", .{ .integer = snap.cursor_col });

    // Optional golden file comparison.
    if (obj.get("golden_path")) |v| {
        if (v == .string) {
            const golden = snapshot_mod.load(alloc, v.string) catch {
                // Golden doesn't exist — save current.
                snapshot_mod.save(snap, alloc, v.string) catch {};
                try result.put("golden_created", .{ .bool = true });
                return .{ .object = result };
            };
            var golden_mut = golden;
            defer golden_mut.deinit(alloc);

            // Check dimensions before diffing — diff asserts they match.
            if (snap.cols != golden_mut.cols or snap.rows != golden_mut.rows) {
                const dim_msg = try std.fmt.allocPrint(
                    alloc,
                    "dimension mismatch: current {d}x{d} vs golden {d}x{d}",
                    .{ snap.cols, snap.rows, golden_mut.cols, golden_mut.rows },
                );
                try result.put("error", .{ .string = dim_msg });
                return .{ .object = result };
            }

            const diff_text = try snapshot_mod.diff(snap, golden_mut, alloc);
            if (diff_text.len > 0) {
                try result.put("diff", .{ .string = diff_text });
            }
        }
    }

    return .{ .object = result };
}

// --- Step 6.3.8: handleStop ---

fn handleStop(pool: *SessionPool, alloc: Allocator, args: JsonValue) !JsonValue {
    const obj = if (args == .object) args.object else return jsonError(alloc, "invalid args");

    const session_id = getSessionId(obj) orelse return jsonError(alloc, "missing session_id");
    const sess = pool.get(session_id) catch return jsonError(alloc, "session not found");

    // Drain remaining output.
    _ = sess.drain();

    const exit_code = sess.process.exit_code;

    pool.destroy(session_id) catch {};

    var result = json.ObjectMap.init(alloc);
    if (exit_code) |code| {
        try result.put("exit_code", .{ .integer = code });
    }
    return .{ .object = result };
}

// --- Internal helpers ---

fn getSessionId(obj: json.ObjectMap) ?u8 {
    const v = obj.get("session_id") orelse return null;
    return switch (v) {
        .integer => |i| if (i >= 0 and i < 16) @intCast(i) else null,
        else => null,
    };
}

fn parseKeyCode(name: []const u8) ?input.KeyCode {
    const map = .{
        .{ "enter", input.KeyCode.enter },
        .{ "tab", input.KeyCode.tab },
        .{ "escape", input.KeyCode.escape },
        .{ "backspace", input.KeyCode.backspace },
        .{ "delete", input.KeyCode.delete },
        .{ "space", input.KeyCode.space },
        .{ "up", input.KeyCode.up },
        .{ "down", input.KeyCode.down },
        .{ "left", input.KeyCode.left },
        .{ "right", input.KeyCode.right },
        .{ "home", input.KeyCode.home },
        .{ "end", input.KeyCode.end },
        .{ "page_up", input.KeyCode.page_up },
        .{ "page_down", input.KeyCode.page_down },
        .{ "insert", input.KeyCode.insert },
        .{ "f1", input.KeyCode.f1 },
        .{ "f2", input.KeyCode.f2 },
        .{ "f3", input.KeyCode.f3 },
        .{ "f4", input.KeyCode.f4 },
        .{ "f5", input.KeyCode.f5 },
        .{ "f6", input.KeyCode.f6 },
        .{ "f7", input.KeyCode.f7 },
        .{ "f8", input.KeyCode.f8 },
        .{ "f9", input.KeyCode.f9 },
        .{ "f10", input.KeyCode.f10 },
        .{ "f11", input.KeyCode.f11 },
        .{ "f12", input.KeyCode.f12 },
    };

    inline for (map) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }

    // Single letter keys.
    if (name.len == 1 and name[0] >= 'a' and name[0] <= 'z') {
        const offset = name[0] - 'a';
        const key_values = [_]input.KeyCode{
            .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m,
            .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z,
        };
        return key_values[offset];
    }

    return null;
}

// --- Step 1.1: parseRepeatSuffix ---

/// Extract `*N` repeat count from end of token string.
/// Returns null for invalid syntax. Returns count=1 if no `*` found.
///
/// Assertions:
/// - token.len > 0
/// - token.len <= key_token_max_len
/// Postcondition:
/// - result.count >= 1 and result.count <= key_repeat_max
/// - result.base.len > 0
fn parseRepeatSuffix(token: []const u8) ?RepeatResult {
    std.debug.assert(token.len > 0);
    std.debug.assert(token.len <= key_token_max_len);

    const star_pos = std.mem.lastIndexOfScalar(u8, token, '*') orelse {
        return .{ .base = token, .count = 1 };
    };

    // Empty base (star at position 0).
    if (star_pos == 0) return null;

    const digits = token[star_pos + 1 ..];

    // No digits after star.
    if (digits.len == 0) return null;

    const count = std.fmt.parseInt(u8, digits, 10) catch return null;

    // Zero or exceeds max.
    if (count == 0 or count > key_repeat_max) return null;

    const result = RepeatResult{ .base = token[0..star_pos], .count = count };

    std.debug.assert(result.base.len > 0);
    std.debug.assert(result.count >= 1 and result.count <= key_repeat_max);

    return result;
}

// --- Step 1.2: parseModsAndKey ---

/// Split on `+` to extract modifier prefixes and key name.
/// Last segment is key name, preceding segments are modifiers.
///
/// Assertions:
/// - base.len > 0
/// Postcondition:
/// - returned key is a valid KeyCode
fn parseModsAndKey(base: []const u8) ?ModKeyResult {
    std.debug.assert(base.len > 0);

    var mods = input.Modifiers{};
    var last_segment: []const u8 = "";
    var segment_count: u16 = 0;

    var iter = std.mem.splitScalar(u8, base, '+');
    while (iter.next()) |segment| {
        if (segment_count > 0) {
            // Previous segment was a modifier — apply it.
            if (std.mem.eql(u8, last_segment, "ctrl")) {
                mods.ctrl = true;
            } else if (std.mem.eql(u8, last_segment, "alt")) {
                mods.alt = true;
            } else if (std.mem.eql(u8, last_segment, "shift")) {
                mods.shift = true;
            } else {
                return null; // Unknown modifier.
            }
        }
        last_segment = segment;
        segment_count += 1;
    }

    // Last segment is the key name.
    if (last_segment.len == 0) return null;

    const key = parseKeyCode(last_segment) orelse return null;

    return .{ .key = key, .mods = mods };
}

// --- Step 1.3: parseKeyToken ---

/// Top-level token parser: dispatches between text literals and key presses.
///
/// Assertions:
/// - token.len > 0
/// Postcondition:
/// - if text: text.len > 0
/// - if key_press: count >= 1
fn parseKeyToken(token: []const u8) ?KeyAction {
    std.debug.assert(token.len > 0);

    // Text literal path.
    if (std.mem.startsWith(u8, token, "text:")) {
        const payload = token[5..];
        if (payload.len == 0) return null;
        if (payload.len > 4096) return null;
        return .{ .text = payload };
    }

    // Key press path — enforce key token length limit.
    if (token.len > key_token_max_len) return null;

    const repeat = parseRepeatSuffix(token) orelse return null;
    const mod_key = parseModsAndKey(repeat.base) orelse return null;

    return .{ .key_press = .{
        .key = mod_key.key,
        .mods = mod_key.mods,
        .count = repeat.count,
    } };
}

// --- Step 2.1: executeKeyBatch ---

/// Process array of key tokens against a session.
/// Returns null on success, BatchError on parse/send failure.
/// Only OutOfMemory propagates via error union.
///
/// Assertions:
/// - items.len > 0
/// - items.len <= keys_max_tokens
/// Postcondition:
/// - if null returned, all tokens were dispatched
fn executeKeyBatch(
    sess: *Session,
    keys_array: json.Array,
    alloc: Allocator,
) !?BatchError {
    std.debug.assert(keys_array.items.len > 0);
    std.debug.assert(keys_array.items.len <= keys_max_tokens);

    var i: u16 = 0;
    for (keys_array.items) |item| {
        const token = switch (item) {
            .string => |s| s,
            else => return BatchError{ .message = "keys items must be strings", .processed = i },
        };

        if (token.len == 0) {
            return BatchError{ .message = "empty key token", .processed = i };
        }

        const action = parseKeyToken(token) orelse {
            const msg = try std.fmt.allocPrint(alloc, "invalid key token: {s}", .{token});
            return BatchError{ .message = msg, .processed = i };
        };

        switch (action) {
            .text => |text| {
                sess.sendText(text) catch {
                    return BatchError{ .message = "send failed", .processed = i };
                };
            },
            .key_press => |kp| {
                var rep: u8 = 0;
                while (rep < kp.count) : (rep += 1) {
                    sess.sendKey(kp.key, kp.mods) catch {
                        return BatchError{ .message = "send failed", .processed = i };
                    };
                }
            },
        }
        i += 1;
    }

    std.debug.assert(i == @as(u16, @intCast(keys_array.items.len)));
    return null;
}

// --- Step 3.1: parseRegion ---

/// Extract optional region object from JSON args, clamp to terminal bounds.
///
/// Assertions:
/// - terminal_cols > 0
/// - terminal_rows > 0
/// Postcondition:
/// - top + height <= terminal_rows
/// - left + width <= terminal_cols
fn parseRegion(
    obj: json.ObjectMap,
    terminal_cols: u16,
    terminal_rows: u16,
) screen_mod.RegionOpts {
    std.debug.assert(terminal_cols > 0);
    std.debug.assert(terminal_rows > 0);

    const region_val = obj.get("region") orelse {
        return .{ .top = 0, .left = 0, .height = terminal_rows, .width = terminal_cols };
    };

    const r = switch (region_val) {
        .object => |o| o,
        else => return .{ .top = 0, .left = 0, .height = terminal_rows, .width = terminal_cols },
    };

    // Step 1: Extract with defaults.
    var row: u16 = getOptU16(r, "row") orelse 0;
    var col: u16 = getOptU16(r, "col") orelse 0;
    var height: u16 = getOptU16(r, "height") orelse terminal_rows;
    var width: u16 = getOptU16(r, "width") orelse terminal_cols;

    // Step 2: Clamp origin.
    row = @min(row, terminal_rows - 1);
    col = @min(col, terminal_cols - 1);

    // Step 3: Clamp extent using clamped origin.
    height = @min(height, terminal_rows - row);
    width = @min(width, terminal_cols - col);

    const result = screen_mod.RegionOpts{ .top = row, .left = col, .height = height, .width = width };
    std.debug.assert(@as(u32, result.top) + @as(u32, result.height) <= terminal_rows);
    std.debug.assert(@as(u32, result.left) + @as(u32, result.width) <= terminal_cols);

    return result;
}

fn getOptU16(obj: json.ObjectMap, key: []const u8) ?u16 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| if (i >= 0 and i <= 500) @intCast(i) else null,
        else => null,
    };
}

// --- Step 3.2: appendScreenFields ---

/// Drain session and append screen state fields to JSON result.
/// Always uses regionText for consistent output.
///
/// Assertions:
/// - sess.state == .active
/// Postcondition:
/// - result contains "text" key
fn appendScreenFields(
    result: *json.ObjectMap,
    sess: *Session,
    alloc: Allocator,
    args_obj: json.ObjectMap,
) !void {
    std.debug.assert(sess.state == .active);

    _ = sess.drain();

    const opts = parseRegion(args_obj, sess.terminal.cols, sess.terminal.rows);

    const text = if (opts.height > 0 and opts.width > 0)
        try screen_mod.regionText(&sess.terminal, alloc, opts)
    else
        "";

    const pos = sess.terminal.cursorPosition();

    try result.put("text", .{ .string = text });
    try result.put("cursor_row", .{ .integer = pos.row });
    try result.put("cursor_col", .{ .integer = pos.col });
    try result.put("cols", .{ .integer = sess.terminal.cols });
    try result.put("rows", .{ .integer = sess.terminal.rows });
}

// --- JSON response helpers ---

fn jsonOk(alloc: Allocator) !JsonValue {
    var result = json.ObjectMap.init(alloc);
    try result.put("ok", .{ .bool = true });
    return .{ .object = result };
}

fn jsonBool(alloc: Allocator, value: bool) !JsonValue {
    var result = json.ObjectMap.init(alloc);
    try result.put("matched", .{ .bool = value });
    return .{ .object = result };
}

fn jsonError(alloc: Allocator, message: []const u8) !JsonValue {
    var result = json.ObjectMap.init(alloc);
    try result.put("error", .{ .string = message });
    return .{ .object = result };
}

// ===== Tests =====

test "toolList returns all tools" {
    // Use arena — JSON ObjectMaps are managed and would leak with testing allocator.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = try toolList(alloc);
    const tools_val = result.object.get("tools").?.array;

    try std.testing.expectEqual(@as(usize, 10), tools_val.items.len);
}

test "dispatch unknown tool" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pool = try SessionPool.init(alloc);
    defer pool.deinit();
    var rec_state = record_mod.initState();

    const result = try dispatch(pool, &rec_state, alloc, "unknown", .null);
    try std.testing.expect(result.object.get("error") != null);
}

test "dispatch tui_record_start with valid path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pool = try SessionPool.init(alloc);
    defer pool.deinit();
    var rec_state = record_mod.initState();

    const path = "/tmp/tuikit_test_dispatch_rec.jsonl";
    defer std.fs.cwd().deleteFile(path) catch {};

    var args_obj = json.ObjectMap.init(alloc);
    try args_obj.put("path", .{ .string = path });

    const result = try dispatch(pool, &rec_state, alloc, "tui_record_start", .{ .object = args_obj });
    try std.testing.expect(result.object.get("ok") != null);

    // Clean up — stop recording.
    _ = try dispatch(pool, &rec_state, alloc, "tui_record_stop", .null);
}

test "dispatch tui_record_stop when not recording" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const pool = try SessionPool.init(alloc);
    defer pool.deinit();
    var rec_state = record_mod.initState();

    const result = try dispatch(pool, &rec_state, alloc, "tui_record_stop", .null);
    try std.testing.expect(result.object.get("error") != null);
}

test "parseKeyCode valid" {
    try std.testing.expectEqual(input.KeyCode.enter, parseKeyCode("enter").?);
    try std.testing.expectEqual(input.KeyCode.f1, parseKeyCode("f1").?);
    try std.testing.expectEqual(input.KeyCode.c, parseKeyCode("c").?);
}

test "parseKeyCode invalid" {
    try std.testing.expect(parseKeyCode("invalid") == null);
}

// --- Phase 1 tests ---

test "parseRepeatSuffix no star" {
    const r = parseRepeatSuffix("down").?;
    try std.testing.expectEqualStrings("down", r.base);
    try std.testing.expectEqual(@as(u8, 1), r.count);
}

test "parseRepeatSuffix with count" {
    const r = parseRepeatSuffix("down*5").?;
    try std.testing.expectEqualStrings("down", r.base);
    try std.testing.expectEqual(@as(u8, 5), r.count);
}

test "parseRepeatSuffix max count" {
    const r = parseRepeatSuffix("down*99").?;
    try std.testing.expectEqual(@as(u8, 99), r.count);
}

test "parseRepeatSuffix zero count" {
    try std.testing.expect(parseRepeatSuffix("down*0") == null);
}

test "parseRepeatSuffix over max" {
    try std.testing.expect(parseRepeatSuffix("down*100") == null);
}

test "parseRepeatSuffix empty base" {
    try std.testing.expect(parseRepeatSuffix("*5") == null);
}

test "parseRepeatSuffix no digits" {
    try std.testing.expect(parseRepeatSuffix("down*") == null);
}

test "parseRepeatSuffix with mods" {
    const r = parseRepeatSuffix("ctrl+a*3").?;
    try std.testing.expectEqualStrings("ctrl+a", r.base);
    try std.testing.expectEqual(@as(u8, 3), r.count);
}

test "parseModsAndKey plain key" {
    const r = parseModsAndKey("enter").?;
    try std.testing.expectEqual(input.KeyCode.enter, r.key);
    try std.testing.expect(!r.mods.ctrl and !r.mods.alt and !r.mods.shift);
}

test "parseModsAndKey ctrl+c" {
    const r = parseModsAndKey("ctrl+c").?;
    try std.testing.expectEqual(input.KeyCode.c, r.key);
    try std.testing.expect(r.mods.ctrl);
    try std.testing.expect(!r.mods.alt and !r.mods.shift);
}

test "parseModsAndKey shift+tab" {
    const r = parseModsAndKey("shift+tab").?;
    try std.testing.expectEqual(input.KeyCode.tab, r.key);
    try std.testing.expect(r.mods.shift);
}

test "parseModsAndKey ctrl+shift+up" {
    const r = parseModsAndKey("ctrl+shift+up").?;
    try std.testing.expectEqual(input.KeyCode.up, r.key);
    try std.testing.expect(r.mods.ctrl and r.mods.shift);
}

test "parseModsAndKey trailing plus" {
    try std.testing.expect(parseModsAndKey("ctrl+") == null);
}

test "parseModsAndKey unknown key" {
    try std.testing.expect(parseModsAndKey("unknown") == null);
}

test "parseModsAndKey unknown modifier" {
    try std.testing.expect(parseModsAndKey("foo+enter") == null);
}

test "parseKeyToken text literal" {
    const action = parseKeyToken("text:hello world").?;
    switch (action) {
        .text => |t| try std.testing.expectEqualStrings("hello world", t),
        .key_press => return error.TestUnexpectedResult,
    }
}

test "parseKeyToken empty text" {
    try std.testing.expect(parseKeyToken("text:") == null);
}

test "parseKeyToken text asterisk" {
    const action = parseKeyToken("text:*").?;
    switch (action) {
        .text => |t| try std.testing.expectEqualStrings("*", t),
        .key_press => return error.TestUnexpectedResult,
    }
}

test "parseKeyToken plain key" {
    const action = parseKeyToken("down").?;
    switch (action) {
        .key_press => |kp| {
            try std.testing.expectEqual(input.KeyCode.down, kp.key);
            try std.testing.expectEqual(@as(u8, 1), kp.count);
        },
        .text => return error.TestUnexpectedResult,
    }
}

test "parseKeyToken key with repeat" {
    const action = parseKeyToken("down*5").?;
    switch (action) {
        .key_press => |kp| {
            try std.testing.expectEqual(input.KeyCode.down, kp.key);
            try std.testing.expectEqual(@as(u8, 5), kp.count);
        },
        .text => return error.TestUnexpectedResult,
    }
}

test "parseKeyToken ctrl+c" {
    const action = parseKeyToken("ctrl+c").?;
    switch (action) {
        .key_press => |kp| {
            try std.testing.expectEqual(input.KeyCode.c, kp.key);
            try std.testing.expect(kp.mods.ctrl);
            try std.testing.expectEqual(@as(u8, 1), kp.count);
        },
        .text => return error.TestUnexpectedResult,
    }
}

test "parseKeyToken ctrl+a*3" {
    const action = parseKeyToken("ctrl+a*3").?;
    switch (action) {
        .key_press => |kp| {
            try std.testing.expectEqual(input.KeyCode.a, kp.key);
            try std.testing.expect(kp.mods.ctrl);
            try std.testing.expectEqual(@as(u8, 3), kp.count);
        },
        .text => return error.TestUnexpectedResult,
    }
}

test "parseKeyToken invalid key" {
    try std.testing.expect(parseKeyToken("invalid") == null);
}

// --- Phase 3 tests ---

test "parseRegion absent returns full screen" {
    var obj = json.ObjectMap.init(std.testing.allocator);
    defer obj.deinit();

    const r = parseRegion(obj, 80, 24);
    try std.testing.expectEqual(@as(u16, 0), r.top);
    try std.testing.expectEqual(@as(u16, 0), r.left);
    try std.testing.expectEqual(@as(u16, 24), r.height);
    try std.testing.expectEqual(@as(u16, 80), r.width);
}

test "parseRegion full screen explicit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var region = json.ObjectMap.init(alloc);
    try region.put("row", .{ .integer = 0 });
    try region.put("col", .{ .integer = 0 });
    try region.put("width", .{ .integer = 80 });
    try region.put("height", .{ .integer = 24 });

    var obj = json.ObjectMap.init(alloc);
    try obj.put("region", .{ .object = region });

    const r = parseRegion(obj, 80, 24);
    try std.testing.expectEqual(@as(u16, 0), r.top);
    try std.testing.expectEqual(@as(u16, 0), r.left);
    try std.testing.expectEqual(@as(u16, 24), r.height);
    try std.testing.expectEqual(@as(u16, 80), r.width);
}

test "parseRegion overflow clamped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var region = json.ObjectMap.init(alloc);
    try region.put("row", .{ .integer = 20 });
    try region.put("height", .{ .integer = 10 });

    var obj = json.ObjectMap.init(alloc);
    try obj.put("region", .{ .object = region });

    const r = parseRegion(obj, 80, 24);
    try std.testing.expectEqual(@as(u16, 20), r.top);
    try std.testing.expectEqual(@as(u16, 4), r.height);
}

test "parseRegion row beyond bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var region = json.ObjectMap.init(alloc);
    try region.put("row", .{ .integer = 100 });

    var obj = json.ObjectMap.init(alloc);
    try obj.put("region", .{ .object = region });

    const r = parseRegion(obj, 80, 24);
    try std.testing.expectEqual(@as(u16, 23), r.top);
    try std.testing.expectEqual(@as(u16, 1), r.height);
}

test "parseRegion zero height" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var region = json.ObjectMap.init(alloc);
    try region.put("height", .{ .integer = 0 });

    var obj = json.ObjectMap.init(alloc);
    try obj.put("region", .{ .object = region });

    const r = parseRegion(obj, 80, 24);
    try std.testing.expectEqual(@as(u16, 0), r.height);
}

test "parseRegion non-object treated as absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var obj = json.ObjectMap.init(alloc);
    try obj.put("region", .{ .integer = 42 });

    const r = parseRegion(obj, 80, 24);
    try std.testing.expectEqual(@as(u16, 24), r.height);
    try std.testing.expectEqual(@as(u16, 80), r.width);
}
