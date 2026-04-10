Plan: Record/Replay for TUI Test Sessions

 Context

 tui-test-ghost lets AI agents test Bubble Tea apps via MCP tools. The agent's testing session is ephemeral — once the conversation ends, the test is gone. Record/replay captures the agent's tool
 calls to a JSONL file, then replays them as a repeatable test suite. The agent becomes the test author.

 Workflow:
 1. Agent calls tui_record_start { path: "test.jsonl" }
 2. Agent tests the app normally (tui_start, tui_send, tui_wait, etc.)
 3. Every tool call is logged to the JSONL file
 4. Agent calls tui_record_stop
 5. Later: tui-test-ghost replay test.jsonl re-runs the session and reports pass/fail

 Constraint: Recordings are single-session only. One tui_start, one tui_stop. Multi-session recordings are not supported in v1.

 File Format

 JSONL — one JSON object per line, flushed immediately (crash-safe):

 {"tool":"tui_start","args":{"command":"myapp"},"result":{"session_id":0,"text":"..."}}
 {"tool":"tui_send","args":{"session_id":0,"keys":["down*3","enter"]},"result":{"text":"..."}}
 {"tool":"tui_wait","args":{"session_id":0,"text":"Settings"},"result":{"matched":true,"text":"..."}}
 {"tool":"tui_stop","args":{"session_id":0},"result":{"exit_code":0}}

 Assertion Model

 During replay, tool calls split into actions and assertions:

 - Actions (execute only, do not compare results): tui_start, tui_send, tui_resize, tui_screen, tui_cell
 - Assertions (execute AND compare key result fields):
   - tui_wait — compare matched field. If recorded matched: true but replay gets matched: false, that's a failure.
   - tui_stop — compare exit_code field. Different exit code = failure. If exit_code is absent in actual result (process still running), treat as failure with "exit_code missing in result".
   - tui_snapshot — uses golden file comparison internally (already has its own diff).

 Screen text is NOT compared for actions — it's timing-dependent and would cause false failures.

 ---
 Phase 1: Recorder Core (src/record.zig)

 New file. Handles file creation, JSONL serialization, and entry writing. No module-level state — the Recorder is owned explicitly by the caller and passed through the call chain.

 Step 1.1 — Constants, types, and init

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

 pub const Recorder = struct {
     file: std.fs.File,
     bytes_written: u32,
     entry_count: u16,
     active: bool,
 };

 pub fn init(path: []const u8) RecordError!Recorder

 - Opens file via std.fs.cwd().createFile(path, .{}). Returns WriteFailed on failure.
 - Assertions: path.len > 0, path.len <= max_path_len; post: active == true, bytes_written == 0, entry_count == 0
 - Tests: init with valid path creates file and returns active recorder; init with "/nonexistent/dir/file" returns WriteFailed

 Step 1.2 — writeEntry

 pub fn writeEntry(
     self: *Recorder,
     alloc: Allocator,
     tool_name: []const u8,
     args: JsonValue,
     result: JsonValue,
 ) RecordError!void

 - Construct entry as:
   var entry = json.ObjectMap.init(alloc);
   entry.put("tool", .{ .string = tool_name }) catch return RecordError.WriteFailed;
   entry.put("args", args) catch return RecordError.WriteFailed;
   entry.put("result", result) catch return RecordError.WriteFailed;
 - Serialize via: const bytes = std.json.Stringify.valueAlloc(alloc, .{ .object = entry }, .{}) catch return RecordError.WriteFailed;
 - Write bytes + '\n' to self.file: self.file.writeAll(bytes) catch return RecordError.WriteFailed; self.file.writeAll("\n") catch return RecordError.WriteFailed;
 - Do NOT use `try` — the upstream error sets (error{OutOfMemory}, File.WriteError) are not subsets of RecordError. Use explicit `catch return` as shown above.
 - Check self.bytes_written + bytes.len + 1 > max_file_size before writing — return FileSizeLimitExceeded if exceeded.
 - Check self.entry_count >= max_entries before writing — return EntryLimitExceeded if exceeded.
 - Increment bytes_written and entry_count after successful write.
 - Note: alloc is the per-request arena from main.zig's MCP loop. The serialized bytes are written to the file and discarded within the same arena lifetime. Do not move this call to after the arena is freed.
 - Assertions: self.active == true, tool_name.len > 0; post: entry_count incremented by 1
 - Tests: write 3 entries, read file, verify 3 lines each with valid JSON containing tool/args/result keys

 Step 1.3 — close

 fn close(self: *Recorder) void

 - Close self.file, set self.active = false.
 - Not pub — only called via stopRecording, which guards against double invocation.
 - Assertions: self.active == true; post: self.active == false
 - Tests: tested indirectly via stopRecording (close is private)

 Step 1.4 — RecordingState (explicit, caller-owned)

 No module-level mutable state. The recording state is owned by main.zig and passed explicitly to every function that needs it. This satisfies TigerStyle's "no hidden control flow" — recording is never an invisible side effect.

 pub const RecordingState = struct {
     recorder: ?Recorder,
 };

 pub fn initState() RecordingState

 - Returns RecordingState{ .recorder = null }.

 pub fn startRecording(state: *RecordingState, path: []const u8) RecordError!void
 pub fn stopRecording(state: *RecordingState) RecordError!void
 pub fn isRecording(state: *const RecordingState) bool
 pub fn recordEntry(state: *RecordingState, alloc: Allocator, tool_name: []const u8, args: JsonValue, result: JsonValue) void

 - startRecording: return AlreadyRecording if state.recorder != null. Call init(path), assign to state.recorder.
 - stopRecording: return NotRecording if state.recorder == null. Call state.recorder.?.close(), set to null.
 - isRecording: return state.recorder != null.
 - recordEntry: no-op if state.recorder == null. If active, call writeEntry and catch the RecordError return: `state.recorder.?.writeEntry(...) catch {};`. Assertions inside writeEntry remain active (they are programming errors that panic, not runtime failures). Only the error return is swallowed. Recording errors are non-fatal — never break the agent's session.
 - Assertions: startRecording pre: state.recorder == null; post: state.recorder != null. stopRecording pre: state.recorder != null; post: state.recorder == null.
 - Tests: startRecording -> isRecording() true; stopRecording -> isRecording() false; double startRecording -> AlreadyRecording; stopRecording when not recording -> NotRecording. Each test creates its own RecordingState — no shared mutable state between tests.

 ---
 Phase 2: MCP Tool Registration

 Step 2.1 — Add tool definitions and schemas

 File: src/tools.zig

 Add to tool_defs array:
 .{ .name = "tui_record_start", .description = "Start recording tool calls to a JSONL file" },
 .{ .name = "tui_record_stop", .description = "Stop recording and close the file" },

 Add inputSchema cases:
 - tui_record_start: required param path (string, "File path for JSONL recording")
 - tui_record_stop: no params, required: [] (empty)

 Update toolList test: change expected count from 8 to 10 (adding tui_record_start and tui_record_stop).

 Step 2.2 — Add dispatch routes and handlers

 File: src/tools.zig

 The dispatch function signature gains a recording_state parameter:
 pub fn dispatch(pool: *SessionPool, recording_state: *record_mod.RecordingState, alloc: Allocator, tool_name: []const u8, args: JsonValue) !JsonValue

 The recording_state parameter is used only by handleRecordStart and handleRecordStop dispatch branches. Do not modify existing handler function signatures — they continue to take (pool, alloc, args) as before. Update the call site in handleToolCall (main.zig) to pass &recording_state as the second argument.

 Add dispatch branches:
 if (std.mem.eql(u8, tool_name, "tui_record_start")) return handleRecordStart(recording_state, alloc, args);
 if (std.mem.eql(u8, tool_name, "tui_record_stop")) return handleRecordStop(recording_state, alloc);

 handleRecordStart(state, alloc, args):
 1. Extract path string from args object. Return error if missing or not string.
 2. Call record_mod.startRecording(state, path).
 3. On success: return {"ok": true, "path": "<path>"}.
 4. On AlreadyRecording: return {"error": "already recording — call tui_record_stop first"}.
 5. On WriteFailed: return {"error": "failed to create recording file"}.

 handleRecordStop(state, alloc):
 1. Call record_mod.stopRecording(state).
 2. On success: return {"ok": true}.
 3. On NotRecording: return {"error": "not recording"}.

 Add const record_mod = @import("record.zig"); to tools.zig imports.

 - Update the existing test named "dispatch unknown tool" in tools.zig to pass a RecordingState as the new second argument to dispatch.
 - Tests: dispatch "tui_record_start" with valid path -> ok. dispatch "tui_record_stop" when not recording -> error.

 Step 2.3 — Add recording hook to handleToolCall

 File: src/main.zig

 Create RecordingState at server startup (alongside SessionPool):
 var recording_state = record_mod.initState();

 Pass &recording_state to dispatch:
 const result = try tools_mod.dispatch(pool, &recording_state, alloc, tool_name, args);

 After dispatch returns successfully, record if active — skip the recording tools themselves. Only successful dispatch results are recorded. If dispatch returns an error, it propagates via `try` before reaching the recording line, so the entry is not logged:
 if (!isRecordTool(tool_name)) {
     record_mod.recordEntry(&recording_state, alloc, tool_name, args, result);
 }

 Helper (private to main.zig):
 fn isRecordTool(name: []const u8) bool {
     return std.mem.eql(u8, name, "tui_record_start") or
            std.mem.eql(u8, name, "tui_record_stop");
 }

 Add const record_mod = @import("record.zig"); to main.zig imports.

 - Assertions: tool_name.len > 0
 - Tests: isRecordTool("tui_record_start") == true, isRecordTool("tui_send") == false

 ---
 Phase 3: Replay Engine (src/replay.zig)

 New file. Reads JSONL recordings and re-executes them.

 Step 3.1 — Entry type and parseEntry

 pub const Entry = struct {
     tool: []const u8,
     args: JsonValue,
     result: JsonValue,
 };

 const max_entries: u16 = 10_000;
 const max_file_size: usize = 10 * 1024 * 1024; // usize required by readFileAlloc

 const record_tools = [_][]const u8{ "tui_record_start", "tui_record_stop" };

 pub const ParseError = error{ MissingField, InvalidJson };

 pub fn parseEntry(alloc: Allocator, line: []const u8) ParseError!Entry

 - Parse JSON from line via std.json.parseFromSlice. Extract "tool" (must be string), "args" (any value), "result" (any value). If JSON parsing fails, return ParseError.InvalidJson. If "tool", "args", or "result" keys are missing, return ParseError.MissingField.
 - Assertions: line.len > 0; post: result.tool.len > 0
 - Tests: valid JSONL line parses correctly; missing "tool" key returns error; invalid JSON returns error

 Step 3.2 — loadRecording

 pub const LoadError = error{
     TooManyEntries,
     EmptyRecording,
     MultipleSessionsNotSupported,
     ContainsRecordTools,
 };

 pub fn loadRecording(alloc: Allocator, path: []const u8) ![]Entry

 - Read file (max 10MB) via std.fs.cwd().readFileAlloc(alloc, path, max_file_size).
 - Split using std.mem.tokenizeScalar(u8, content, '\n') to iterate non-empty lines. Parse each via parseEntry.
 - Validation (reject invalid recordings at load time, not at replay time):
   - Return TooManyEntries if count exceeds max_entries.
   - Return EmptyRecording if file is empty or has zero valid entries.
   - Return ContainsRecordTools if any entry's tool name is "tui_record_start" or "tui_record_stop". These are never recorded by the hook (isRecordTool filters them), so their presence indicates a hand-edited or corrupted file.
   - Return MultipleSessionsNotSupported if more than one entry has tool == "tui_start". V1 constraint: single-session recordings only.
 - Assertions: path.len > 0; post: result.len > 0, result.len <= max_entries
 - Tests: write 3-line JSONL file, load it, verify 3 entries; empty file returns EmptyRecording; file with tui_record_start entry returns ContainsRecordTools; file with 2 tui_start entries returns MultipleSessionsNotSupported

 Step 3.3 — isAssertionTool and compareResult

 pub fn isAssertionTool(tool_name: []const u8) bool

 pub const CompareResult = struct {
     passed: bool,
     message: []const u8,
 };

 pub fn compareResult(
     alloc: Allocator,
     tool_name: []const u8,
     expected: JsonValue,
     actual: JsonValue,
 ) !CompareResult

 - isAssertionTool returns true for: tui_wait, tui_stop, tui_snapshot.
 - compareResult:
   - tui_wait: extract "matched" bool from both. If key is missing in either, fail with "matched field missing". If key is present but not a bool type, fail with "matched field has wrong type". If expected=true, actual=false -> fail with "expected text match but timed out". If expected=false, actual=true -> pass (better than expected is fine).
   - tui_stop: extract "exit_code" integer from both. If exit_code key is absent in actual -> fail with "exit_code missing in result". If exit_code key is absent in expected -> fail with "exit_code missing in recording". If values differ -> fail with "expected exit_code=N, got exit_code=M".
   - tui_snapshot: if actual has non-empty "diff" key -> fail with diff text. Otherwise pass.
   - Non-assertion tools: always return {.passed = true, .message = "ok"}.
 - Assertions: tool_name.len > 0; post: message.len > 0
 - Tests: matching wait (both matched=true) -> pass; mismatching wait (expected true, got false) -> fail; wait with missing matched key -> fail; matching stop exit codes -> pass; differing exit codes -> fail; stop with missing exit_code -> fail; non-assertion tool -> always pass

 Step 3.4 — replayAll

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
 ) !ReplaySummary

 - Iterate entries (bounded by len <= max_entries).
 - Create a dummy RecordingState with .recorder = null before the loop: var dummy_state = record_mod.initState();
 - For each: call tools_mod.dispatch(pool, &dummy_state, alloc, entry.tool, entry.args).
   The dummy state has .recorder = null, so recordEntry is a no-op during replay. Record tools are rejected at load time (ContainsRecordTools), so they cannot reach dispatch.
 - Session ID assumption: replay creates a fresh SessionPool, so the first tui_start receives session_id 0, matching the recorded value. This holds because recordings are single-session (enforced by loadRecording). If multi-session support is added later, session_id remapping will be required.
 - If dispatch errors: mark as failed with "dispatch error".
 - If dispatch succeeds: call compareResult for assertion tools. For action tools, mark as passed.
 - Collect EntryResult array, compute summary counts.
 - Assertions: entries.len > 0, entries.len <= max_entries; post: summary.total == entries.len, summary.passed + summary.failed == summary.total
 - Tests: replay 2-entry recording (tui_start + tui_stop with /bin/echo) -> both pass, summary.passed == 2

 Step 3.5 — formatResult and formatSummary

 pub fn formatResult(alloc: Allocator, r: EntryResult) ![]const u8
 pub fn formatSummary(alloc: Allocator, summary: ReplaySummary) ![]const u8

 - formatResult: "  [1] tui_start ... ok" or "  [3] tui_wait ... FAIL (expected text match but timed out)"
 - formatSummary: "RESULT: 4/5 passed, 1 failed"
 - Assertions: post: result.len > 0
 - Tests: format passing result contains "ok"; format failing result contains "FAIL"; format summary with 4/5 matches expected string

 ---
 Phase 4: CLI Replay Mode

 Step 4.1 — runReplay in main.zig

 Add branch in main() before --cli:
 if (args.len > 2 and std.mem.eql(u8, args[1], "replay")) {
     const exit_code = try runReplay(base_alloc, args[2]);
     if (exit_code != 0) std.process.exit(exit_code);
     return;
 }

 fn runReplay(alloc: Allocator, path: []const u8) !u8

 1. Load recording via replay_mod.loadRecording(alloc, path)
 2. Create SessionPool
 3. Print "REPLAY: {path}" to stderr
 4. Call replay_mod.replayAll(pool, alloc, entries)
 5. For each result: format and print to stdout
 6. Print summary to stdout
 7. Destroy all sessions, deinit pool (via defer — runs before return)
 8. Return 1 if summary.failed > 0, else return 0

 The caller in main() uses the return value as the process exit code. Do NOT call std.process.exit inside runReplay — that skips defers and leaks child processes. Instead, return the exit code and let main() call std.process.exit after all defers have run.

 - Assertions: path.len > 0; post: pool cleaned up (via defer)
 - Tests: integration test in Phase 5

 Step 4.2 — Add module exports to root.zig

 Add to root.zig:
 pub const record = @import("record.zig");
 pub const replay = @import("replay.zig");

 This enables test discovery via refAllDecls(@This()).

 ---
 Phase 5: Integration Tests

 Step 5.1 — Record round-trip test

 File: src/record.zig test section

 1. Create a local RecordingState via initState()
 2. const path = "/tmp/tui-test-ghost_test_record.jsonl";
 3. defer std.fs.cwd().deleteFile(path) catch {};
 4. startRecording(&state, path)
 5. Build 3 entries with JSON args/results, call recordEntry(&state, ...) for each
 6. stopRecording(&state)
 7. Read file, verify 3 lines, each valid JSON with tool/args/result keys

 Step 5.2 — Replay with echo test

 File: src/replay.zig test section

 1. Write JSONL file with: tui_start (command: "/bin/echo", args: ["hello"]), tui_wait (text: "hello", recorded result matched: true), tui_stop (recorded result exit_code: 0)
 2. Load recording
 3. Create real SessionPool
 4. Call replayAll
 5. Verify all 3 pass, summary.failed == 0

 Step 5.3 — Replay assertion failure test

 File: src/replay.zig test section

 1. Write JSONL with tui_start + tui_wait where recorded result has matched: true but wait text is "NEVER_APPEARS"
 2. Replay against /bin/echo "hello"
 3. The tui_wait will timeout (matched: false) but expected was matched: true
 4. Verify summary.failed == 1

 ---
 Phase 6: Documentation

 Step 6.1 — Update README.md

 - Add tui_record_start and tui_record_stop to MCP tools table
 - Add "Record/Replay" to features list
 - Add tui-test-ghost replay <file.jsonl> to CLI section
 - Add JSONL format example
 - Document assertion vs action tool categories
 - Document single-session constraint

 ---
 Files Modified

 | File | Changes |
 |------|---------|
 | src/record.zig | NEW — Recorder type, RecordingState, writeEntry, startRecording/stopRecording (explicit state, no module-level vars) |
 | src/replay.zig | NEW — Entry parser, loadRecording (with validation), compareResult, replayAll, formatters |
 | src/tools.zig | Add tui_record_start/stop defs, schemas, dispatch routes, handlers; dispatch gains recording_state param |
 | src/main.zig | Create RecordingState, pass to dispatch, add recording hook, add replay CLI branch |
 | src/root.zig | Add record and replay module re-exports |
 | README.md | Document new tools, replay CLI, JSONL format, single-session constraint |

 Files NOT Modified

 | File | Why |
 |------|-----|
 | src/Session.zig | Replay uses dispatch -> handlers -> Session (same path as MCP) |
 | src/SessionPool.zig | Replay creates a real pool, no changes needed |
 | src/screen.zig | No changes |
 | src/mcp.zig | No changes |

 Verification

 1. zig build test — all tests pass including new record/replay tests
 2. zig build — clean build
 3. Manual record test: start MCP server, call tui_record_start, do some tool calls, call tui_record_stop, verify JSONL file
 4. Manual replay test: tui-test-ghost replay test.jsonl — verify pass/fail output and exit code
 5. CI replay test: record a session against /bin/echo, replay it, verify exit code 0
