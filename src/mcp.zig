const std = @import("std");
const Allocator = std.mem.Allocator;
const json = std.json;

// --- Public types ---

pub const JsonValue = json.Value;

pub const Request = struct {
    jsonrpc: []const u8,
    id: ?JsonValue,
    method: []const u8,
    params: ?JsonValue,
};

pub const ErrorObj = struct {
    code: i32,
    message: []const u8,
    data: ?JsonValue,
};

pub const Response = struct {
    jsonrpc: []const u8 = "2.0",
    id: ?JsonValue,
    result: ?JsonValue = null,
    @"error": ?ErrorObj = null,
};

// --- Constants ---

/// Standard JSON-RPC error codes.
pub const err_parse: i32 = -32700;
pub const err_invalid_request: i32 = -32600;
pub const err_method_not_found: i32 = -32601;
pub const err_invalid_params: i32 = -32602;
pub const err_internal: i32 = -32603;

/// Maximum request line length (1MB).
const max_line_len: usize = 1024 * 1024;

// --- Step 6.1.1: Message serialization ---

/// Serialize a Response to JSON bytes.
///
/// Assertions:
/// - response.jsonrpc is "2.0"
/// Postcondition:
/// - returned bytes are valid JSON
pub fn serializeResponse(alloc: Allocator, response: Response) ![]const u8 {
    std.debug.assert(std.mem.eql(u8, response.jsonrpc, "2.0"));

    var obj = json.ObjectMap.init(alloc);
    defer obj.deinit();

    try obj.put("jsonrpc", .{ .string = "2.0" });

    if (response.id) |id| {
        try obj.put("id", id);
    } else {
        try obj.put("id", .null);
    }

    if (response.result) |result| {
        try obj.put("result", result);
    }

    if (response.@"error") |err| {
        var err_obj = json.ObjectMap.init(alloc);
        try err_obj.put("code", .{ .integer = err.code });
        try err_obj.put("message", .{ .string = err.message });
        if (err.data) |data| {
            try err_obj.put("data", data);
        }
        try obj.put("error", .{ .object = err_obj });
    }

    const val: json.Value = .{ .object = obj };
    const bytes = try json.Stringify.valueAlloc(alloc, val, .{});
    // Append newline.
    const result = try alloc.alloc(u8, bytes.len + 1);
    @memcpy(result[0..bytes.len], bytes);
    result[bytes.len] = '\n';
    alloc.free(bytes);

    return result;
}

// --- Step 6.1.2: readRequest ---

/// Read a JSON-RPC request from a reader (newline-delimited).
///
/// Postcondition:
/// - returned request has jsonrpc == "2.0"
pub fn readRequest(alloc: Allocator, reader: anytype) !Request {
    const line = reader.readUntilDelimiterAlloc(alloc, '\n', max_line_len) catch |err| {
        return switch (err) {
            error.EndOfStream => error.EndOfStream,
            else => error.OutOfMemory,
        };
    };
    defer alloc.free(line);

    return parseRequest(alloc, line);
}

/// Parse a JSON string into a Request.
///
/// Assertions:
/// - line.len > 0
/// Postconditions:
/// - returned request has jsonrpc == "2.0"
/// - returned request has method.len > 0
pub fn parseRequest(alloc: Allocator, line: []const u8) !Request {
    std.debug.assert(line.len > 0);

    const tree = json.parseFromSlice(json.Value, alloc, line, .{}) catch
        return error.ParseFailed;
    // Free the parse tree on validation errors. On success, the Request
    // holds slices into the tree's arena — freed when the caller's arena ends.
    errdefer tree.deinit();

    const root = tree.value;
    if (root != .object) return error.ParseFailed;

    const obj = root.object;

    const jsonrpc = if (obj.get("jsonrpc")) |v| switch (v) {
        .string => |s| s,
        else => return error.ParseFailed,
    } else return error.ParseFailed;

    if (!std.mem.eql(u8, jsonrpc, "2.0")) return error.ParseFailed;

    const method = if (obj.get("method")) |v| switch (v) {
        .string => |s| s,
        else => return error.ParseFailed,
    } else return error.ParseFailed;

    const id = obj.get("id");
    const params = obj.get("params");

    // Postconditions.
    std.debug.assert(std.mem.eql(u8, jsonrpc, "2.0"));
    std.debug.assert(method.len > 0);

    return .{
        .jsonrpc = jsonrpc,
        .id = id,
        .method = method,
        .params = params,
    };
}

// --- Step 6.1.3: writeResponse ---

/// Write a JSON-RPC response to a writer.
///
/// Assertions:
/// - response.jsonrpc is "2.0"
pub fn writeResponse(alloc: Allocator, writer: anytype, response: Response) !void {
    std.debug.assert(std.mem.eql(u8, response.jsonrpc, "2.0"));

    const bytes = try serializeResponse(alloc, response);
    defer alloc.free(bytes);

    try writer.writeAll(bytes);
}

// --- Step 6.1.4: handleInitialize ---

/// Handle the MCP initialize request.
///
/// Returns the server info and capabilities.
pub fn handleInitialize(alloc: Allocator, req: Request) !Response {
    var caps = json.ObjectMap.init(alloc);
    var tools_cap = json.ObjectMap.init(alloc);
    try tools_cap.put("listChanged", .{ .bool = false });
    try caps.put("tools", .{ .object = tools_cap });

    var server_info = json.ObjectMap.init(alloc);
    try server_info.put("name", .{ .string = "tui-test-ghost" });
    try server_info.put("version", .{ .string = "0.3.0" });

    var result = json.ObjectMap.init(alloc);
    try result.put("protocolVersion", .{ .string = "2024-11-05" });
    try result.put("capabilities", .{ .object = caps });
    try result.put("serverInfo", .{ .object = server_info });

    return .{
        .id = req.id,
        .result = .{ .object = result },
    };
}

/// Create an error response.
pub fn errorResponse(id: ?JsonValue, code: i32, message: []const u8) Response {
    return .{
        .id = id,
        .@"error" = .{
            .code = code,
            .message = message,
            .data = null,
        },
    };
}

/// Create a success response.
pub fn successResponse(id: ?JsonValue, result: JsonValue) Response {
    return .{
        .id = id,
        .result = result,
    };
}

// ===== Tests =====

test "serializeResponse basic" {
    // Use arena — json.ObjectMap is managed and won't be individually freed.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const response = Response{
        .id = .{ .integer = 1 },
        .result = .{ .string = "ok" },
    };

    const bytes = try serializeResponse(alloc, response);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"jsonrpc\":\"2.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"result\":\"ok\"") != null);
}

test "serializeResponse error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const response = errorResponse(.{ .integer = 2 }, err_method_not_found, "not found");

    const bytes = try serializeResponse(alloc, response);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "not found") != null);
}

test "parseRequest valid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const line =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
    ;

    const req = try parseRequest(alloc, line);

    try std.testing.expectEqualStrings("2.0", req.jsonrpc);
    try std.testing.expectEqualStrings("initialize", req.method);
}

test "handleInitialize response" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const req = Request{
        .jsonrpc = "2.0",
        .id = .{ .integer = 1 },
        .method = "initialize",
        .params = null,
    };

    const response = try handleInitialize(alloc, req);
    const bytes = try serializeResponse(alloc, response);

    try std.testing.expect(std.mem.indexOf(u8, bytes, "tui-test-ghost") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "protocolVersion") != null);
}
