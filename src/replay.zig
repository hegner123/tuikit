const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;
const JsonValue = json.Value;
const tools_mod = @import("tools.zig");
const record_mod = @import("record.zig");
const SessionPool = @import("SessionPool.zig");

// --- Constants ---

const max_entries: u16 = 10_000;
const max_file_size: usize = 10 * 1024 * 1024;

comptime {
    std.debug.assert(max_entries > 0 and max_entries <= 10_000);
    std.debug.assert(max_file_size == 10 * 1024 * 1024);
}

const record_tools = [_][]const u8{ "tui_record_start", "tui_record_stop" };

// --- Step 3.1: Entry type and parseEntry ---

pub const Entry = struct {
    tool: []const u8,
    args: JsonValue,
    result: JsonValue,
};

pub const ParseError = error{ MissingField, InvalidJson };

pub fn parseEntry(alloc: Allocator, line: []const u8) ParseError!Entry {
    std.debug.assert(line.len > 0);

    const parsed = json.parseFromSlice(json.Value, alloc, line, .{}) catch
        return ParseError.InvalidJson;

    if (parsed.value != .object) return ParseError.InvalidJson;
    const obj = parsed.value.object;

    const tool = if (obj.get("tool")) |v| switch (v) {
        .string => |s| s,
        else => return ParseError.MissingField,
    } else return ParseError.MissingField;

    const args = obj.get("args") orelse return ParseError.MissingField;
    const result = obj.get("result") orelse return ParseError.MissingField;

    std.debug.assert(tool.len > 0);

    return Entry{
        .tool = tool,
        .args = args,
        .result = result,
    };
}

// --- Step 3.2: loadRecording ---

pub const LoadError = error{
    TooManyEntries,
    EmptyRecording,
    MultipleSessionsNotSupported,
    ContainsRecordTools,
};

fn isRecordTool(name: []const u8) bool {
    for (record_tools) |rt| {
        if (std.mem.eql(u8, name, rt)) return true;
    }
    return false;
}

pub fn loadRecording(alloc: Allocator, path: []const u8) ![]Entry {
    std.debug.assert(path.len > 0);

    const content = try std.fs.cwd().readFileAlloc(alloc, path, max_file_size);

    var entries: std.ArrayList(Entry) = .{};
    var start_count: u16 = 0;

    var iter = std.mem.tokenizeScalar(u8, content, '\n');
    while (iter.next()) |line| {
        if (entries.items.len >= max_entries) return LoadError.TooManyEntries;

        const entry = parseEntry(alloc, line) catch |err| switch (err) {
            ParseError.InvalidJson => return err,
            ParseError.MissingField => return err,
        };

        if (isRecordTool(entry.tool)) return LoadError.ContainsRecordTools;
        if (std.mem.eql(u8, entry.tool, "tui_start")) start_count += 1;
        if (start_count > 1) return LoadError.MultipleSessionsNotSupported;

        try entries.append(alloc, entry);
    }

    if (entries.items.len == 0) return LoadError.EmptyRecording;

    const result = entries.items;
    std.debug.assert(result.len > 0);
    std.debug.assert(result.len <= max_entries);

    return result;
}

// --- Step 3.3: isAssertionTool and compareResult ---

pub fn isAssertionTool(tool_name: []const u8) bool {
    std.debug.assert(tool_name.len > 0);
    return std.mem.eql(u8, tool_name, "tui_wait") or
        std.mem.eql(u8, tool_name, "tui_stop") or
        std.mem.eql(u8, tool_name, "tui_snapshot");
}

pub const CompareResult = struct {
    passed: bool,
    message: []const u8,
};

pub fn compareResult(
    alloc: Allocator,
    tool_name: []const u8,
    expected: JsonValue,
    actual: JsonValue,
) !CompareResult {
    std.debug.assert(tool_name.len > 0);

    if (std.mem.eql(u8, tool_name, "tui_wait")) {
        return compareWait(expected, actual);
    }
    if (std.mem.eql(u8, tool_name, "tui_stop")) {
        return compareStop(alloc, expected, actual);
    }
    if (std.mem.eql(u8, tool_name, "tui_snapshot")) {
        return compareSnapshot(actual);
    }

    const result = CompareResult{ .passed = true, .message = "ok" };
    std.debug.assert(result.message.len > 0);
    return result;
}

fn compareWait(expected: JsonValue, actual: JsonValue) CompareResult {
    const exp_obj = if (expected == .object) expected.object else return .{ .passed = false, .message = "matched field missing" };
    const act_obj = if (actual == .object) actual.object else return .{ .passed = false, .message = "matched field missing" };

    const exp_val = exp_obj.get("matched") orelse return .{ .passed = false, .message = "matched field missing" };
    const act_val = act_obj.get("matched") orelse return .{ .passed = false, .message = "matched field missing" };

    const exp_matched = if (exp_val == .bool) exp_val.bool else return .{ .passed = false, .message = "matched field has wrong type" };
    const act_matched = if (act_val == .bool) act_val.bool else return .{ .passed = false, .message = "matched field has wrong type" };

    if (exp_matched and !act_matched) {
        return .{ .passed = false, .message = "expected text match but timed out" };
    }

    return .{ .passed = true, .message = "ok" };
}

fn compareStop(alloc: Allocator, expected: JsonValue, actual: JsonValue) !CompareResult {
    const exp_obj = if (expected == .object) expected.object else return .{ .passed = false, .message = "exit_code missing in recording" };
    const act_obj = if (actual == .object) actual.object else return .{ .passed = false, .message = "exit_code missing in result" };

    const exp_val = exp_obj.get("exit_code") orelse return .{ .passed = false, .message = "exit_code missing in recording" };
    const act_val = act_obj.get("exit_code") orelse return .{ .passed = false, .message = "exit_code missing in result" };

    const exp_code = if (exp_val == .integer) exp_val.integer else return .{ .passed = false, .message = "exit_code missing in recording" };
    const act_code = if (act_val == .integer) act_val.integer else return .{ .passed = false, .message = "exit_code missing in result" };

    if (exp_code != act_code) {
        const msg = try std.fmt.allocPrint(alloc, "expected exit_code={d}, got exit_code={d}", .{ exp_code, act_code });
        return .{ .passed = false, .message = msg };
    }

    return .{ .passed = true, .message = "ok" };
}

fn compareSnapshot(actual: JsonValue) CompareResult {
    const act_obj = if (actual == .object) actual.object else return .{ .passed = true, .message = "ok" };

    if (act_obj.get("diff")) |diff_val| {
        if (diff_val == .string and diff_val.string.len > 0) {
            return .{ .passed = false, .message = diff_val.string };
        }
    }

    return .{ .passed = true, .message = "ok" };
}

// --- Step 3.4: replayAll ---

pub const EntryResult = struct {
    index: u16,
    tool: []const u8,
    passed: bool,
    message: []const u8,
};

pub const ReplaySummary = struct {
    results: []EntryResult,
    total: u16,
    passed: u16,
    failed: u16,
};

pub fn replayAll(
    pool: *SessionPool,
    alloc: Allocator,
    entries: []const Entry,
) !ReplaySummary {
    std.debug.assert(entries.len > 0);
    std.debug.assert(entries.len <= max_entries);

    var results: std.ArrayList(EntryResult) = .{};
    var dummy_state = record_mod.initState();
    var passed_count: u16 = 0;
    var failed_count: u16 = 0;

    for (entries, 0..) |entry, i| {
        const idx: u16 = @intCast(i);

        const dispatch_result = tools_mod.dispatch(pool, &dummy_state, alloc, entry.tool, entry.args) catch {
            try results.append(alloc, .{
                .index = idx,
                .tool = entry.tool,
                .passed = false,
                .message = "dispatch error",
            });
            failed_count += 1;
            continue;
        };

        if (isAssertionTool(entry.tool)) {
            const cmp = try compareResult(alloc, entry.tool, entry.result, dispatch_result);
            try results.append(alloc, .{
                .index = idx,
                .tool = entry.tool,
                .passed = cmp.passed,
                .message = cmp.message,
            });
            if (cmp.passed) {
                passed_count += 1;
            } else {
                failed_count += 1;
            }
        } else {
            try results.append(alloc, .{
                .index = idx,
                .tool = entry.tool,
                .passed = true,
                .message = "ok",
            });
            passed_count += 1;
        }
    }

    const total: u16 = @intCast(entries.len);
    std.debug.assert(total == passed_count + failed_count);

    return ReplaySummary{
        .results = results.items,
        .total = total,
        .passed = passed_count,
        .failed = failed_count,
    };
}

// --- Step 3.5: formatResult and formatSummary ---

pub fn formatResult(alloc: Allocator, r: EntryResult) ![]const u8 {
    const status = if (r.passed) "ok" else r.message;
    const prefix = if (r.passed) "ok" else "FAIL";

    const result = try std.fmt.allocPrint(alloc, "  [{d}] {s} ... {s}{s}{s}", .{
        r.index,
        r.tool,
        prefix,
        if (!r.passed) " (" else "",
        if (!r.passed) status else "",
    });

    // For failures, close the paren.
    if (!r.passed) {
        const with_paren = try std.fmt.allocPrint(alloc, "{s})", .{result});
        std.debug.assert(with_paren.len > 0);
        return with_paren;
    }

    std.debug.assert(result.len > 0);
    return result;
}

pub fn formatSummary(alloc: Allocator, summary: ReplaySummary) ![]const u8 {
    const result = try std.fmt.allocPrint(alloc, "RESULT: {d}/{d} passed, {d} failed", .{
        summary.passed,
        summary.total,
        summary.failed,
    });

    std.debug.assert(result.len > 0);
    return result;
}

// ===== Tests =====

test "parseEntry valid line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const line =
        \\{"tool":"tui_start","args":{"command":"myapp"},"result":{"session_id":0}}
    ;

    const entry = try parseEntry(alloc, line);
    try std.testing.expectEqualStrings("tui_start", entry.tool);
    try std.testing.expect(entry.args == .object);
    try std.testing.expect(entry.result == .object);
}

test "parseEntry missing tool key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const line =
        \\{"args":{},"result":{}}
    ;

    const result = parseEntry(alloc, line);
    try std.testing.expectError(ParseError.MissingField, result);
}

test "parseEntry invalid JSON" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const result = parseEntry(alloc, "not json at all");
    try std.testing.expectError(ParseError.InvalidJson, result);
}

test "loadRecording 3-line file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = "/tmp/tui-test-ghost_test_load.jsonl";
    defer std.fs.cwd().deleteFile(path) catch {};

    const content =
        \\{"tool":"tui_start","args":{"command":"app"},"result":{"session_id":0}}
        \\{"tool":"tui_send","args":{"session_id":0},"result":{"text":"hi"}}
        \\{"tool":"tui_stop","args":{"session_id":0},"result":{"exit_code":0}}
    ;

    const file = try std.fs.cwd().createFile(path, .{});
    try file.writeAll(content);
    file.close();

    const entries = try loadRecording(alloc, path);
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("tui_start", entries[0].tool);
    try std.testing.expectEqualStrings("tui_stop", entries[2].tool);
}

test "loadRecording empty file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = "/tmp/tui-test-ghost_test_load_empty.jsonl";
    defer std.fs.cwd().deleteFile(path) catch {};

    const file = try std.fs.cwd().createFile(path, .{});
    file.close();

    const result = loadRecording(alloc, path);
    try std.testing.expectError(LoadError.EmptyRecording, result);
}

test "loadRecording rejects record tools" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = "/tmp/tui-test-ghost_test_load_rectool.jsonl";
    defer std.fs.cwd().deleteFile(path) catch {};

    const content =
        \\{"tool":"tui_record_start","args":{"path":"x"},"result":{"ok":true}}
    ;

    const file = try std.fs.cwd().createFile(path, .{});
    try file.writeAll(content);
    file.close();

    const result = loadRecording(alloc, path);
    try std.testing.expectError(LoadError.ContainsRecordTools, result);
}

test "loadRecording rejects multiple sessions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const path = "/tmp/tui-test-ghost_test_load_multi.jsonl";
    defer std.fs.cwd().deleteFile(path) catch {};

    const content =
        \\{"tool":"tui_start","args":{"command":"a"},"result":{"session_id":0}}
        \\{"tool":"tui_start","args":{"command":"b"},"result":{"session_id":1}}
    ;

    const file = try std.fs.cwd().createFile(path, .{});
    try file.writeAll(content);
    file.close();

    const result = loadRecording(alloc, path);
    try std.testing.expectError(LoadError.MultipleSessionsNotSupported, result);
}

test "compareResult wait matching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var exp = json.ObjectMap.init(alloc);
    try exp.put("matched", .{ .bool = true });
    var act = json.ObjectMap.init(alloc);
    try act.put("matched", .{ .bool = true });

    const cr = try compareResult(alloc, "tui_wait", .{ .object = exp }, .{ .object = act });
    try std.testing.expect(cr.passed);
}

test "compareResult wait mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var exp = json.ObjectMap.init(alloc);
    try exp.put("matched", .{ .bool = true });
    var act = json.ObjectMap.init(alloc);
    try act.put("matched", .{ .bool = false });

    const cr = try compareResult(alloc, "tui_wait", .{ .object = exp }, .{ .object = act });
    try std.testing.expect(!cr.passed);
    try std.testing.expect(std.mem.indexOf(u8, cr.message, "timed out") != null);
}

test "compareResult wait missing matched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const exp = json.ObjectMap.init(alloc);
    const act = json.ObjectMap.init(alloc);

    const cr = try compareResult(alloc, "tui_wait", .{ .object = exp }, .{ .object = act });
    try std.testing.expect(!cr.passed);
    try std.testing.expect(std.mem.indexOf(u8, cr.message, "missing") != null);
}

test "compareResult stop matching exit codes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var exp = json.ObjectMap.init(alloc);
    try exp.put("exit_code", .{ .integer = 0 });
    var act = json.ObjectMap.init(alloc);
    try act.put("exit_code", .{ .integer = 0 });

    const cr = try compareResult(alloc, "tui_stop", .{ .object = exp }, .{ .object = act });
    try std.testing.expect(cr.passed);
}

test "compareResult stop differing exit codes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var exp = json.ObjectMap.init(alloc);
    try exp.put("exit_code", .{ .integer = 0 });
    var act = json.ObjectMap.init(alloc);
    try act.put("exit_code", .{ .integer = 1 });

    const cr = try compareResult(alloc, "tui_stop", .{ .object = exp }, .{ .object = act });
    try std.testing.expect(!cr.passed);
    try std.testing.expect(std.mem.indexOf(u8, cr.message, "exit_code") != null);
}

test "compareResult stop missing exit_code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var exp = json.ObjectMap.init(alloc);
    try exp.put("exit_code", .{ .integer = 0 });
    const act = json.ObjectMap.init(alloc);

    const cr = try compareResult(alloc, "tui_stop", .{ .object = exp }, .{ .object = act });
    try std.testing.expect(!cr.passed);
    try std.testing.expect(std.mem.indexOf(u8, cr.message, "missing") != null);
}

test "compareResult non-assertion tool always passes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cr = try compareResult(alloc, "tui_send", .null, .null);
    try std.testing.expect(cr.passed);
}

test "replayAll dispatches entries and tallies results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Two action tools — tests the replay loop, not process behavior.
    var start_args = json.ObjectMap.init(alloc);
    try start_args.put("command", .{ .string = "/bin/echo" });
    var start_result = json.ObjectMap.init(alloc);
    try start_result.put("session_id", .{ .integer = 0 });

    var screen_args = json.ObjectMap.init(alloc);
    try screen_args.put("session_id", .{ .integer = 0 });
    const screen_result = json.ObjectMap.init(alloc);

    const entries = [_]Entry{
        .{ .tool = "tui_start", .args = .{ .object = start_args }, .result = .{ .object = start_result } },
        .{ .tool = "tui_screen", .args = .{ .object = screen_args }, .result = .{ .object = screen_result } },
    };

    const pool = try SessionPool.init(std.testing.allocator);
    defer {
        pool.destroyAll();
        pool.deinit();
    }

    const summary = try replayAll(pool, alloc, &entries);
    try std.testing.expectEqual(@as(u16, 2), summary.total);
    try std.testing.expectEqual(@as(u16, 2), summary.passed);
    try std.testing.expectEqual(@as(u16, 0), summary.failed);
}

test "formatResult passing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const r = EntryResult{ .index = 1, .tool = "tui_start", .passed = true, .message = "ok" };
    const text = try formatResult(alloc, r);
    try std.testing.expect(std.mem.indexOf(u8, text, "ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[1]") != null);
}

test "formatResult failing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const r = EntryResult{ .index = 3, .tool = "tui_wait", .passed = false, .message = "expected text match but timed out" };
    const text = try formatResult(alloc, r);
    try std.testing.expect(std.mem.indexOf(u8, text, "FAIL") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "timed out") != null);
}

test "formatSummary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const summary = ReplaySummary{
        .results = &.{},
        .total = 5,
        .passed = 4,
        .failed = 1,
    };
    const text = try formatSummary(alloc, summary);
    try std.testing.expect(std.mem.indexOf(u8, text, "4/5") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "1 failed") != null);
}

test "replay assertion failure: tui_wait mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // tui_start: launch /bin/echo hello
    var start_args = json.ObjectMap.init(alloc);
    try start_args.put("command", .{ .string = "/bin/echo" });
    var echo_args_arr = json.Array.init(alloc);
    try echo_args_arr.append(.{ .string = "hello" });
    try start_args.put("args", .{ .array = echo_args_arr });
    var start_result = json.ObjectMap.init(alloc);
    try start_result.put("session_id", .{ .integer = 0 });

    // tui_wait: recorded as matched=true, but text "NEVER_APPEARS" will timeout.
    var wait_args = json.ObjectMap.init(alloc);
    try wait_args.put("session_id", .{ .integer = 0 });
    try wait_args.put("text", .{ .string = "NEVER_APPEARS" });
    try wait_args.put("timeout_ms", .{ .integer = 200 });
    var wait_result = json.ObjectMap.init(alloc);
    try wait_result.put("matched", .{ .bool = true });

    const entries = [_]Entry{
        .{ .tool = "tui_start", .args = .{ .object = start_args }, .result = .{ .object = start_result } },
        .{ .tool = "tui_wait", .args = .{ .object = wait_args }, .result = .{ .object = wait_result } },
    };

    const pool = try SessionPool.init(std.testing.allocator);
    defer {
        pool.destroyAll();
        pool.deinit();
    }

    const summary = try replayAll(pool, alloc, &entries);
    try std.testing.expectEqual(@as(u16, 2), summary.total);
    try std.testing.expectEqual(@as(u16, 1), summary.failed);

    // The failed entry should be the tui_wait.
    try std.testing.expectEqualStrings("tui_wait", summary.results[1].tool);
    try std.testing.expect(!summary.results[1].passed);
}
