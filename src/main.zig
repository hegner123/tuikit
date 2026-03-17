const std = @import("std");
const builtin = @import("builtin");
const mcp_mod = @import("mcp.zig");
const tools_mod = @import("tools.zig");
const SessionPool = @import("SessionPool.zig");
const Session = @import("Session.zig");
const record_mod = @import("record.zig");
const replay_mod = @import("replay.zig");
const wait_mod = @import("wait.zig");

pub fn main() !void {
    // DebugAllocator for debug builds (leak detection); page_allocator for release.
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer if (builtin.mode == .Debug) {
        _ = debug_allocator.deinit();
    };
    const base_alloc: std.mem.Allocator = if (builtin.mode == .Debug)
        debug_allocator.allocator()
    else
        std.heap.page_allocator;

    const args = try std.process.argsAlloc(base_alloc);
    defer std.process.argsFree(base_alloc, args);

    if (args.len > 1) {
        const arg = args[1];

        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            return printVersion();
        }

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return printHelp();
        }

        if (std.mem.eql(u8, arg, "replay") and args.len > 2) {
            const exit_code = try runReplay(base_alloc, args[2]);
            if (exit_code != 0) std.process.exit(exit_code);
            return;
        }

        if (std.mem.eql(u8, arg, "--cli")) {
            return runCli(base_alloc, args[2..]);
        }
    }

    // Default: MCP server mode.
    return runMcpServer(base_alloc);
}

const version = "0.3.0";

fn printVersion() void {
    var out_buf: [256]u8 = undefined;
    var out_writer = std.fs.File.stdout().writer(&out_buf);
    const stdout = &out_writer.interface;
    stdout.print("tuikit {s}\n", .{version}) catch {};
    stdout.flush() catch {};
}

fn printHelp() void {
    var out_buf: [4096]u8 = undefined;
    var out_writer = std.fs.File.stdout().writer(&out_buf);
    const stdout = &out_writer.interface;
    stdout.writeAll(
        \\tuikit — TUI testing toolkit
        \\
        \\Usage:
        \\  tuikit                                    Start MCP server (stdin/stdout)
        \\  tuikit replay <file.jsonl>                Replay a recorded session
        \\  tuikit --cli --command <cmd> [options]    Run a single CLI test
        \\
        \\Options:
        \\  -h, --help       Show this help
        \\  -v, --version    Show version
        \\
        \\CLI options:
        \\  --command <cmd>    Program to run (required)
        \\  --send <text>      Text to send to stdin
        \\  --wait-for <text>  Wait until text appears (5s timeout)
        \\  --screen           Print screen content to stdout
        \\
    ) catch {};
    stdout.flush() catch {};
}

// --- Step 6.4.1: MCP server mode ---

fn runMcpServer(base_alloc: std.mem.Allocator) !void {
    const pool = try SessionPool.init(base_alloc);
    defer {
        pool.destroyAll();
        pool.deinit();
    }
    var recording_state = record_mod.initState();

    // 64KB buffer for stdin — large enough for most MCP requests.
    // Static allocation per TigerStyle.
    var stdin_buf: [64 * 1024]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    const stdin = &stdin_reader.interface;
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buf);
    const stdout = &stdout_writer.interface;

    while (true) {
        // Per-request arena for JSON allocations.
        var arena = std.heap.ArenaAllocator.init(base_alloc);
        defer arena.deinit();
        const alloc = arena.allocator();

        // Read request line (newline-delimited JSON-RPC).
        const line_or_null = stdin.takeDelimiter('\n') catch {
            return; // Read error — client disconnected.
        };
        const line = line_or_null orelse return; // EOF.

        // Dupe into arena so line survives past next read.
        const owned_line = alloc.dupe(u8, line) catch {
            const err_resp = mcp_mod.errorResponse(null, mcp_mod.err_internal, "allocation failed");
            const bytes = mcp_mod.serializeResponse(alloc, err_resp) catch continue;
            stdout.writeAll(bytes) catch return;
            stdout.flush() catch return;
            continue;
        };

        const req = mcp_mod.parseRequest(alloc, owned_line) catch {
            const err_resp = mcp_mod.errorResponse(null, mcp_mod.err_parse, "parse error");
            const bytes = mcp_mod.serializeResponse(alloc, err_resp) catch continue;
            stdout.writeAll(bytes) catch return;
            stdout.flush() catch return;
            continue;
        };

        // JSON-RPC notifications have no id — silently ignore per spec.
        if (req.id == null) continue;

        // Route request.
        const response = routeRequest(pool, &recording_state, alloc, req) catch {
            const err_resp = mcp_mod.errorResponse(req.id, mcp_mod.err_internal, "internal error");
            const bytes = mcp_mod.serializeResponse(alloc, err_resp) catch continue;
            stdout.writeAll(bytes) catch return;
            stdout.flush() catch return;
            continue;
        };

        const bytes = mcp_mod.serializeResponse(alloc, response) catch continue;
        stdout.writeAll(bytes) catch return;
        stdout.flush() catch return;
    }
}

fn routeRequest(
    pool: *SessionPool,
    recording_state: *record_mod.RecordingState,
    alloc: std.mem.Allocator,
    req: mcp_mod.Request,
) !mcp_mod.Response {
    std.debug.assert(req.method.len > 0);
    std.debug.assert(std.mem.eql(u8, req.jsonrpc, "2.0"));

    if (std.mem.eql(u8, req.method, "initialize")) {
        return mcp_mod.handleInitialize(alloc, req);
    }

    if (std.mem.eql(u8, req.method, "tools/list")) {
        const result = try tools_mod.toolList(alloc);
        return mcp_mod.successResponse(req.id, result);
    }

    if (std.mem.eql(u8, req.method, "tools/call")) {
        return handleToolCall(pool, recording_state, alloc, req);
    }

    if (std.mem.eql(u8, req.method, "ping")) {
        return mcp_mod.successResponse(req.id, .{ .object = .init(alloc) });
    }

    return mcp_mod.errorResponse(req.id, mcp_mod.err_method_not_found, "unknown method");
}

fn handleToolCall(
    pool: *SessionPool,
    recording_state: *record_mod.RecordingState,
    alloc: std.mem.Allocator,
    req: mcp_mod.Request,
) !mcp_mod.Response {
    const params = req.params orelse
        return mcp_mod.errorResponse(req.id, mcp_mod.err_invalid_params, "missing params");

    if (params != .object)
        return mcp_mod.errorResponse(req.id, mcp_mod.err_invalid_params, "params must be object");

    const tool_name = if (params.object.get("name")) |v| switch (v) {
        .string => |s| s,
        else => return mcp_mod.errorResponse(req.id, mcp_mod.err_invalid_params, "name must be string"),
    } else return mcp_mod.errorResponse(req.id, mcp_mod.err_invalid_params, "missing name");

    const args = params.object.get("arguments") orelse .null;

    const result = try tools_mod.dispatch(pool, recording_state, alloc, tool_name, args);

    // Record successful tool calls (skip the recording tools themselves).
    if (!isRecordTool(tool_name)) {
        record_mod.recordEntry(recording_state, alloc, tool_name, args, result);
    }

    // Wrap in MCP content format.
    var content_obj = std.json.ObjectMap.init(alloc);
    try content_obj.put("type", .{ .string = "text" });

    const text_bytes = try std.json.Stringify.valueAlloc(alloc, result, .{});
    try content_obj.put("text", .{ .string = text_bytes });

    var content_arr = std.json.Array.init(alloc);
    try content_arr.append(.{ .object = content_obj });

    var resp_result = std.json.ObjectMap.init(alloc);
    try resp_result.put("content", .{ .array = content_arr });

    return mcp_mod.successResponse(req.id, .{ .object = resp_result });
}

fn isRecordTool(name: []const u8) bool {
    std.debug.assert(name.len > 0);
    return std.mem.eql(u8, name, "tui_record_start") or
        std.mem.eql(u8, name, "tui_record_stop");
}

// --- Step 4.1: Replay mode ---

fn runReplay(base_alloc: std.mem.Allocator, path: []const u8) !u8 {
    std.debug.assert(path.len > 0);

    var arena = std.heap.ArenaAllocator.init(base_alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    const entries = replay_mod.loadRecording(alloc, path) catch |err| {
        var err_buf: [4096]u8 = undefined;
        var err_writer = std.fs.File.stderr().writer(&err_buf);
        const stderr = &err_writer.interface;
        stderr.print("ERROR: failed to load {s}: {any}\n", .{ path, err }) catch {};
        stderr.flush() catch {};
        return 1;
    };

    const pool = try SessionPool.init(base_alloc);
    defer {
        pool.destroyAll();
        pool.deinit();
    }

    var err_buf: [4096]u8 = undefined;
    var err_writer = std.fs.File.stderr().writer(&err_buf);
    const stderr = &err_writer.interface;
    stderr.print("REPLAY: {s}\n", .{path}) catch {};
    stderr.flush() catch {};

    var out_buf: [4096]u8 = undefined;
    var out_writer = std.fs.File.stdout().writer(&out_buf);
    const stdout = &out_writer.interface;

    const summary = try replay_mod.replayAll(pool, alloc, entries);

    for (summary.results) |r| {
        const line = try replay_mod.formatResult(alloc, r);
        stdout.writeAll(line) catch {};
        stdout.writeAll("\n") catch {};
    }

    const summary_line = try replay_mod.formatSummary(alloc, summary);
    stdout.writeAll(summary_line) catch {};
    stdout.writeAll("\n") catch {};
    stdout.flush() catch {};

    if (summary.failed > 0) return 1;
    return 0;
}

// --- Step 6.4.2: CLI mode ---

fn runCli(alloc: std.mem.Allocator, args: []const []const u8) !void {
    var out_buf: [4096]u8 = undefined;
    var out_writer = std.fs.File.stdout().writer(&out_buf);
    const stdout = &out_writer.interface;

    if (args.len == 0) {
        try stdout.writeAll("Usage: tuikit --cli --command <cmd> [--send <text>] [--screen] [--wait-for <text>]\n");
        return;
    }

    // Parse CLI args.
    var command: ?[]const u8 = null;
    var send_text: ?[]const u8 = null;
    var wait_for: ?[]const u8 = null;
    var show_screen = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--command") and i + 1 < args.len) {
            i += 1;
            command = args[i];
        } else if (std.mem.eql(u8, args[i], "--send") and i + 1 < args.len) {
            i += 1;
            send_text = args[i];
        } else if (std.mem.eql(u8, args[i], "--wait-for") and i + 1 < args.len) {
            i += 1;
            wait_for = args[i];
        } else if (std.mem.eql(u8, args[i], "--screen")) {
            show_screen = true;
        }
    }

    const cmd = command orelse {
        try stdout.writeAll("Error: --command is required\n");
        return;
    };

    var sess = try Session.create(alloc, 0, .{
        .argv = &[_][]const u8{cmd},
    });
    defer sess.destroy();
    sess.terminal.initStream();

    if (send_text) |text| {
        try sess.sendText(text);
    }

    if (wait_for) |needle| {
        const found = try wait_mod.waitForText(&sess, alloc, needle, 5000);
        if (!found) {
            try stdout.writeAll("Timeout waiting for text\n");
            return;
        }
    }

    if (show_screen) {
        const drain_result = sess.drainFor(1000);
        if (drain_result.eof) {
            // Process exited before screen capture — output may be partial.
        }
        const text = try sess.terminal.plainText(alloc);
        defer alloc.free(text);
        try stdout.print("{s}\n", .{text});
    }
}

test "main smoke test" {
    const ghostty_vt = @import("ghostty-vt");
    const alloc = std.testing.allocator;

    var terminal: ghostty_vt.Terminal = try .init(alloc, .{
        .cols = 80,
        .rows = 24,
    });
    defer terminal.deinit(alloc);

    try terminal.printString("hello tuikit");

    const screen_text = try terminal.plainString(alloc);
    defer alloc.free(screen_text);

    try std.testing.expect(std.mem.indexOf(u8, screen_text, "hello tuikit") != null);
}

test "isRecordTool identifies record tools" {
    try std.testing.expect(isRecordTool("tui_record_start"));
    try std.testing.expect(isRecordTool("tui_record_stop"));
    try std.testing.expect(!isRecordTool("tui_send"));
    try std.testing.expect(!isRecordTool("tui_start"));
}
