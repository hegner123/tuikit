const std = @import("std");
const json = std.json;

// --- Constants ---

pub const RecordError = error{
    AlreadyRecording,
    NotRecording,
    WriteFailed,
    FileSizeLimitExceeded,
    EntryLimitExceeded,
};

const max_file_size: u32 = 10 * 1024 * 1024; // 10MB
const max_entries: u16 = 10_000;
const max_path_len: u16 = 4096;

comptime {
    std.debug.assert(max_file_size == 10 * 1024 * 1024);
    std.debug.assert(max_entries > 0 and max_entries <= 10_000);
    std.debug.assert(max_path_len > 0);
}

// --- Step 1.1: Recorder type and init ---

const Allocator = std.mem.Allocator;
const JsonValue = json.Value;

pub const Recorder = struct {
    file: std.fs.File,
    bytes_written: u32,
    entry_count: u16,
    active: bool,

    // --- Step 1.2: writeEntry ---

    pub fn writeEntry(
        self: *Recorder,
        alloc: Allocator,
        tool_name: []const u8,
        args: JsonValue,
        result: JsonValue,
    ) RecordError!void {
        std.debug.assert(self.active);
        std.debug.assert(tool_name.len > 0);

        if (self.entry_count >= max_entries) return RecordError.EntryLimitExceeded;

        var entry = json.ObjectMap.init(alloc);
        entry.put("tool", .{ .string = tool_name }) catch return RecordError.WriteFailed;
        entry.put("args", args) catch return RecordError.WriteFailed;
        entry.put("result", result) catch return RecordError.WriteFailed;

        const val: JsonValue = .{ .object = entry };
        const bytes = json.Stringify.valueAlloc(alloc, val, .{}) catch return RecordError.WriteFailed;

        const write_len: u32 = @intCast(bytes.len + 1);
        if (self.bytes_written + write_len > max_file_size) return RecordError.FileSizeLimitExceeded;

        self.file.writeAll(bytes) catch return RecordError.WriteFailed;
        self.file.writeAll("\n") catch return RecordError.WriteFailed;

        const prev_count = self.entry_count;
        self.bytes_written += write_len;
        self.entry_count += 1;

        std.debug.assert(self.entry_count == prev_count + 1);
    }

    // --- Step 1.3: close ---

    fn close(self: *Recorder) void {
        std.debug.assert(self.active);

        self.file.close();
        self.active = false;

        std.debug.assert(!self.active);
    }
};

pub fn init(path: []const u8) RecordError!Recorder {
    std.debug.assert(path.len > 0);
    std.debug.assert(path.len <= max_path_len);

    const file = std.fs.cwd().createFile(path, .{}) catch return RecordError.WriteFailed;

    const recorder = Recorder{
        .file = file,
        .bytes_written = 0,
        .entry_count = 0,
        .active = true,
    };

    std.debug.assert(recorder.active);
    std.debug.assert(recorder.bytes_written == 0);
    std.debug.assert(recorder.entry_count == 0);

    return recorder;
}

// --- Step 1.4: RecordingState ---

pub const RecordingState = struct {
    recorder: ?Recorder,
};

pub fn initState() RecordingState {
    return RecordingState{ .recorder = null };
}

pub fn startRecording(state: *RecordingState, path: []const u8) RecordError!void {
    std.debug.assert(path.len > 0);

    if (state.recorder != null) return RecordError.AlreadyRecording;

    state.recorder = try init(path);

    std.debug.assert(state.recorder != null);
}

pub fn stopRecording(state: *RecordingState) RecordError!void {
    if (state.recorder == null) return RecordError.NotRecording;

    state.recorder.?.close();
    state.recorder = null;

    std.debug.assert(state.recorder == null);
}

pub fn isRecording(state: *const RecordingState) bool {
    return state.recorder != null;
}

pub fn recordEntry(
    state: *RecordingState,
    alloc: Allocator,
    tool_name: []const u8,
    args: JsonValue,
    result: JsonValue,
) void {
    if (state.recorder == null) return;

    // Recording errors are non-fatal — never break the agent's session.
    state.recorder.?.writeEntry(alloc, tool_name, args, result) catch {};
}

// ===== Tests =====

test "init creates active recorder" {
    const path = "/tmp/tui-test-ghost_test_init.jsonl";
    var recorder = try init(path);
    defer {
        recorder.file.close();
        std.fs.cwd().deleteFile(path) catch {};
    }

    try std.testing.expect(recorder.active);
    try std.testing.expectEqual(@as(u32, 0), recorder.bytes_written);
    try std.testing.expectEqual(@as(u16, 0), recorder.entry_count);
}

test "init with bad path returns WriteFailed" {
    const result = init("/nonexistent/dir/file.jsonl");
    try std.testing.expectError(RecordError.WriteFailed, result);
}

test "writeEntry writes 3 valid JSONL lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = "/tmp/tui-test-ghost_test_write.jsonl";
    var recorder = try init(path);
    defer std.fs.cwd().deleteFile(path) catch {};

    var args1 = json.ObjectMap.init(alloc);
    try args1.put("command", .{ .string = "myapp" });
    var res1 = json.ObjectMap.init(alloc);
    try res1.put("session_id", .{ .integer = 0 });

    try recorder.writeEntry(alloc, "tui_start", .{ .object = args1 }, .{ .object = res1 });
    try recorder.writeEntry(alloc, "tui_screen", .{ .object = args1 }, .{ .object = res1 });
    try recorder.writeEntry(alloc, "tui_stop", .{ .object = args1 }, .{ .object = res1 });

    recorder.file.close();
    recorder.active = false;

    const content = try std.fs.cwd().readFileAlloc(alloc, path, max_file_size);

    var line_count: u16 = 0;
    var iter = std.mem.tokenizeScalar(u8, content, '\n');
    while (iter.next()) |line| {
        const parsed = json.parseFromSlice(json.Value, alloc, line, .{}) catch
            return error.TestUnexpectedResult;
        const obj = parsed.value.object;
        try std.testing.expect(obj.get("tool") != null);
        try std.testing.expect(obj.get("args") != null);
        try std.testing.expect(obj.get("result") != null);
        line_count += 1;
    }
    try std.testing.expectEqual(@as(u16, 3), line_count);
    try std.testing.expectEqual(@as(u16, 3), recorder.entry_count);
}

test "RecordingState lifecycle" {
    const path = "/tmp/tui-test-ghost_test_state.jsonl";
    defer std.fs.cwd().deleteFile(path) catch {};

    var state = initState();

    try std.testing.expect(!isRecording(&state));

    try startRecording(&state, path);
    try std.testing.expect(isRecording(&state));

    try stopRecording(&state);
    try std.testing.expect(!isRecording(&state));
}

test "double startRecording returns AlreadyRecording" {
    const path = "/tmp/tui-test-ghost_test_double_start.jsonl";
    defer std.fs.cwd().deleteFile(path) catch {};

    var state = initState();
    try startRecording(&state, path);

    const result = startRecording(&state, "/tmp/tui-test-ghost_test_double_start2.jsonl");
    try std.testing.expectError(RecordError.AlreadyRecording, result);

    try stopRecording(&state);
}

test "stopRecording when not recording returns NotRecording" {
    var state = initState();
    const result = stopRecording(&state);
    try std.testing.expectError(RecordError.NotRecording, result);
}

test "record round-trip via RecordingState" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = "/tmp/tui-test-ghost_test_record_roundtrip.jsonl";
    defer std.fs.cwd().deleteFile(path) catch {};

    var state = initState();
    try startRecording(&state, path);

    var args1 = json.ObjectMap.init(alloc);
    try args1.put("command", .{ .string = "myapp" });
    var res1 = json.ObjectMap.init(alloc);
    try res1.put("session_id", .{ .integer = 0 });
    recordEntry(&state, alloc, "tui_start", .{ .object = args1 }, .{ .object = res1 });

    var args2 = json.ObjectMap.init(alloc);
    try args2.put("session_id", .{ .integer = 0 });
    var res2 = json.ObjectMap.init(alloc);
    try res2.put("text", .{ .string = "screen" });
    recordEntry(&state, alloc, "tui_send", .{ .object = args2 }, .{ .object = res2 });

    var args3 = json.ObjectMap.init(alloc);
    try args3.put("session_id", .{ .integer = 0 });
    var res3 = json.ObjectMap.init(alloc);
    try res3.put("exit_code", .{ .integer = 0 });
    recordEntry(&state, alloc, "tui_stop", .{ .object = args3 }, .{ .object = res3 });

    try stopRecording(&state);

    // Read file, verify 3 lines each with valid JSON.
    const content = try std.fs.cwd().readFileAlloc(alloc, path, max_file_size);
    var line_count: u16 = 0;
    var iter = std.mem.tokenizeScalar(u8, content, '\n');
    while (iter.next()) |line| {
        const parsed = json.parseFromSlice(json.Value, alloc, line, .{}) catch
            return error.TestUnexpectedResult;
        const obj = parsed.value.object;
        try std.testing.expect(obj.get("tool") != null);
        try std.testing.expect(obj.get("args") != null);
        try std.testing.expect(obj.get("result") != null);
        line_count += 1;
    }
    try std.testing.expectEqual(@as(u16, 3), line_count);
}
