# Plan: Key Batching, Auto-Screen, and Region Cropping

## Context

tuikit is a TUI testing toolkit for AI agents to drive Bubble Tea apps via MCP. Currently, navigating a list requires one MCP round-trip per keystroke, and reading the screen requires a separate `tui_screen` call after every action. A typical "navigate down 5 items and select" flow takes 8 round-trips. These three features reduce that to 2.

## Changes

All implementation goes in **`src/tools.zig`**. No changes to `Session.zig`, `screen.zig`, `input.zig`, or `mcp.zig`. The existing `screen.regionText()` and `RegionOpts` are reused as-is.

## Reserved Prefixes

`text:` is a reserved prefix in the key token syntax. Tokens starting with `text:` are interpreted as literal text payloads. If a token is exactly `"text:"` (empty payload), return an error. Document this in the schema description and README.

---

## Phase 1: Key Token Parsing (pure functions, no side effects)

### Step 1.1 — `parseRepeatSuffix`

Extract `*N` repeat count from end of token string. The `*` character is only interpreted as a repeat operator when it appears after at least one character AND is followed by one or more digits. `*` alone or `*N` without a preceding base is invalid.

```zig
const RepeatResult = struct { base: []const u8, count: u8 };
fn parseRepeatSuffix(token: []const u8) ?RepeatResult
```

- Uses `std.mem.lastIndexOfScalar(u8, token, '*')`
- Returns null for: `*0`, `*100+`, `*` with no digits, empty base (position 0)
- If no `*` found, returns `{.base = token, .count = 1}`
- The literal `*` character cannot be sent as a key via this syntax. Use `text:*` to send a literal asterisk.
- **Assertions:** token.len > 0, token.len <= 256; post: count 1-99, base.len > 0
- **Tests:** "down" -> count=1, "down*5" -> count=5, "down*99" -> count=99, "down*0" -> null, "down*100" -> null, "*5" -> null (empty base), "down*" -> null (no digits), "ctrl+a*3" -> base="ctrl+a" count=3

### Step 1.2 — `parseModsAndKey`

Split on `+` to extract modifier prefixes and key name.

```zig
const ModKeyResult = struct { key: input.KeyCode, mods: input.Modifiers };
fn parseModsAndKey(base: []const u8) ?ModKeyResult
```

- Uses `std.mem.splitScalar(u8, base, '+')`. Last segment is key name (via existing `parseKeyCode` private function at line 482 of tools.zig — reuse as-is, do not extend), all preceding segments are modifier names ("ctrl"/"alt"/"shift"). Unknown modifier names return null.
- Returns null for: empty key name (trailing `+`), unknown key name, unknown modifier name
- **Assertions:** base.len > 0; post: key is valid KeyCode
- **Tests:** "enter" -> key=enter no mods, "ctrl+c" -> key=c ctrl=true, "shift+tab" -> key=tab shift=true, "ctrl+shift+up" -> key=up ctrl+shift, "ctrl+" -> null (empty key), "unknown" -> null (invalid key name), "foo+enter" -> null (unknown modifier "foo")

### Step 1.3 — `parseKeyToken`

Top-level dispatcher: text literal or key press.

```zig
const KeyAction = union(enum) {
    text: []const u8,
    key_press: struct { key: input.KeyCode, mods: input.Modifiers, count: u8 },
};
fn parseKeyToken(token: []const u8) ?KeyAction
```

- If `std.mem.startsWith(u8, token, "text:")`: extract `token[5..]` as raw text. If suffix is empty (token is exactly `"text:"`), return null.
- Otherwise: call `parseRepeatSuffix(token)`. If null, return null. Then call `parseModsAndKey(result.base)`. If null, return null. Combine into `.key_press`.
- Each `text:` payload is subject to the existing `sendText` limit of 4096 bytes.
- **Assertions:** token.len > 0; for key tokens, token.len <= 256; for `text:` tokens, payload len (`token[5..]`) <= 4096. Post: if text variant, text.len > 0; if key_press variant, count >= 1
- **Tests:** "text:hello world" -> text="hello world", "text:" -> null, "text:*" -> text="*", "down" -> key_press down count=1, "down*5" -> key_press down count=5, "ctrl+c" -> key_press c ctrl count=1, "ctrl+a*3" -> key_press a ctrl count=3, "" -> assertion failure (caller must not pass empty), "invalid" -> null

### Step 1.4 — Constants and compile-time assertions

```zig
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
```

---

## Phase 2: Key Batch Execution

### Step 2.1 — `executeKeyBatch`

Process array of key tokens against a session. On failure, report how many tokens were successfully processed so the caller knows how far the batch got (the PTY state has been mutated by the successful tokens).

```zig
const BatchError = struct {
    message: []const u8,
    processed: u16,
};

fn executeKeyBatch(sess: *Session, keys_array: json.Array, alloc: Allocator) !?BatchError
```

- Returns null on success (all tokens processed). Returns `BatchError` on failure with error message and count of successfully processed tokens.
- Iterates `keys_array.items` (bounded by len <= 64, validated by caller)
- Each item: verify it is a `.string`, verify `string.len > 0` and `string.len <= 256`, call `parseKeyToken`. If null, return `BatchError{.message = "invalid key token", .processed = i}`. If `.text`, call `sess.sendText(text)`. If `.key_press`, loop `count` times (bounded by <= 99) calling `sess.sendKey(key, mods)`.
- PTY write failures (`sendText` or `sendKey` errors) are reported as `BatchError{.message = "send failed", .processed = i}`, not propagated as Zig errors. Only allocation errors (`OutOfMemory`) propagate via the `!` error union.
- Track processed count via `u16` loop variable `i`.
- **Assertions:** items.len > 0, items.len <= keys_max_tokens; post: if null returned, all items.len tokens were dispatched
- **Tests (unit, using /bin/cat session):**
  - Batch of mixed types: `["text:hello", "enter", "down*3"]` -> null (success)
  - Single text token: `["text:world"]` -> null (success)
  - Invalid token mid-sequence: `["down", "INVALID", "enter"]` -> BatchError with processed=1
  - Batch at 64-token limit: 64x `"enter"` -> null (success)
  - Empty text token: `["text:"]` -> BatchError with processed=0

---

## Phase 3: Region Parsing and Screen Helper

### Step 3.1 — `parseRegion`

Extract optional `region` object from JSON args, clamp to terminal bounds. The `region` parameter is a nested JSON object to avoid ambiguity with top-level `row`/`col` params used by `tui_cell`.

```zig
fn parseRegion(obj: json.ObjectMap, terminal_cols: u16, terminal_rows: u16) screen_mod.RegionOpts
```

- If `obj.get("region")` is null or not `.object` -> return full screen: `{.top = 0, .left = 0, .height = terminal_rows, .width = terminal_cols}`
- Three-step sequence (order matters):
  1. Extract integer fields with defaults: `row` (default 0), `col` (default 0), `width` (default terminal_cols), `height` (default terminal_rows)
  2. Clamp origin: `row = @min(row, terminal_rows - 1)`, `col = @min(col, terminal_cols - 1)`
  3. Clamp extent using clamped origin: `height = @min(height, terminal_rows - row)`, `width = @min(width, terminal_cols - col)`
- Map field names: JSON `row` -> RegionOpts `.top`, JSON `col` -> RegionOpts `.left`
- **Assertions:** terminal_cols > 0, terminal_rows > 0; post: top + height <= terminal_rows, left + width <= terminal_cols
- **Tests:** no region key -> full screen (80x24 on 80x24 terminal), `{row:0, col:0, width:80, height:24}` on 80x24 -> full screen, `{row:20, height:10}` on 80x24 -> clamped to top=20 height=4, `{row:100}` on 80x24 -> clamped to top=23 height=1, `{height:0}` -> height=0 (zero-dimension), region value is integer not object -> treated as absent (full screen)

### Step 3.2 — `appendScreenFields`

Drain session and append screen state fields to a JSON result object. Always uses `screen_mod.regionText` for consistent whitespace and wide-character handling (no separate `plainText` path).

```zig
fn appendScreenFields(
    result: *json.ObjectMap,
    sess: *Session,
    alloc: Allocator,
    args_obj: json.ObjectMap,
) !void
```

- Calls `_ = sess.drain()`
- Calls `parseRegion(args_obj, sess.terminal.cols, sess.terminal.rows)` to get region opts
- If region height > 0 and width > 0: call `screen_mod.regionText(&sess.terminal, alloc, opts)` to get text
- If height == 0 or width == 0: use empty string `""`. Zero-dimension regions are valid and return empty text. This is intentional — allows suppressing screen output by passing `height: 0`.
- Get cursor position via `sess.terminal.cursorPosition()`
- Append to result: `"text"` (string), `"cursor_row"` (integer), `"cursor_col"` (integer), `"cols"` (integer, terminal cols), `"rows"` (integer, terminal rows)
- **Assertions:** `std.debug.assert(sess.state == .active)` (Session.State enum, consistent with all other handlers); post: result contains "text" key after call
- **Tests:** tested indirectly through handler modifications in Phase 4, plus direct test with /bin/echo session verifying all 5 fields present

---

## Phase 4: Handler Modifications

### Step 4.1 — Modify `handleSend`

**Current:** processes `text` or `key`+`mods`, returns `{ok: true}`
**New:** if `keys` array present, process via `executeKeyBatch` (skip text/key/mods). After all input processed, call `sess.drainFor(settle_ms)` to let the child process react, then return screen state via `appendScreenFields`.

- If `keys` present: validate len > 0 (else error), validate len <= 64 (else error). Call `executeKeyBatch`. If `BatchError` returned, build error response with `error` message and `processed` count, then return (no screen state on error).
- If `keys` absent: process `text` and `key`+`mods` as before (existing parsing logic preserved). The response shape changes: `{ok: true}` is replaced by screen state fields. This is a deliberate breaking change — all `tui_send` responses now include screen state.
- Parse optional `settle_ms` integer from args (default `default_settle_ms` = 50, clamp to range 0-5000). Call `sess.drainFor(settle_ms)` before `appendScreenFields` to allow child process to react to input.
- Call `appendScreenFields` to append screen state to result.
- If both `keys` and `text`/`key` are present in args, `keys` takes precedence and `text`/`key`/`mods` are ignored.
- **~45 lines** (within 70-line limit since batch logic is in `executeKeyBatch`)
- **Tests (unit, via dispatch with /bin/cat session):**
  - Send `keys: ["text:hello", "enter"]` -> result has "text" field containing "hello", no "error" field, no "ok" field
  - Send `keys: ["INVALID"]` -> result has "error" and "processed: 0"
  - Send `keys: []` (empty) -> result has "error"
  - Send legacy `text: "hello"` (no keys) -> result has "text" field (screen state), no "ok" field
  - Send `keys` with `settle_ms: 0` -> result has "text" field
  - Send `keys` alongside `text` -> keys wins, text ignored

### Step 4.2 — Modify `handleStart`

**Current:** returns `{session_id: N}`
**New:** after creation, call `sess.drainFor(100)` to capture initial render, then call `appendScreenFields` to include screen state. This lets the agent verify the app started correctly from a single message.

- Get the session via `pool.get(id)` after creation
- Call `sess.drainFor(100)` — 100ms gives most CLI apps enough time to render initial frame. The subsequent `drain()` inside `appendScreenFields` is a no-op (nothing left to drain) and is harmless.
- Call `appendScreenFields(&result, sess, alloc, obj)` to append screen fields
- Response includes both `session_id` and screen state (`text`, `cursor_row`, `cursor_col`, `cols`, `rows`)
- **~50 lines**
- **Tests (unit, via dispatch with /bin/echo session):**
  - Start `/bin/echo hello` -> result has "session_id" (integer) AND "text" field containing "hello"
  - Start `/bin/cat` -> result has "session_id" AND "text" field (may be empty, that's valid)

### Step 4.3 — Modify `handleScreen`

**Current:** calls `sess.getScreen(alloc)`, manually builds result with 5 fields
**New:** delegate entirely to `appendScreenFields` (which handles drain + region internally)

- Create `json.ObjectMap`, call `appendScreenFields`, return. Replaces the current `sess.getScreen(alloc)` call (which internally drains + calls plainText) and manual cursor + field construction.
- Region support comes for free via `parseRegion` inside `appendScreenFields`.
- **~15 lines**
- **Tests (unit, via dispatch):**
  - Screen with no region -> result has "text", "cursor_row", "cursor_col", "cols", "rows"
  - Screen with `region: {row: 0, col: 0, width: 5, height: 1}` -> "text" is truncated to 5 chars max

### Step 4.4 — Modify `handleWait`

**Current:** returns `{matched: bool}` via `jsonBool` helper, or `{matched: bool, exit_code: N}` for exit case
**New:** replace `jsonBool` calls with inline `json.ObjectMap` construction. Add `appendScreenFields` call before each return. Screen is returned even on timeout so the agent can see current state.

- The `jsonBool` helper creates its own ObjectMap internally, which cannot be passed to `appendScreenFields`. Replace each `jsonBool(alloc, matched)` call with: create `json.ObjectMap`, put `"matched"` field, call `appendScreenFields`, return.
- Four branches (text, stable, cursor, exit) each get this treatment.
- Exit branch must preserve the `exit_code` field in the response alongside the new screen fields and `matched` field.
- Exit case: session stays `.active` until `destroy()` is called, so `appendScreenFields` works even after process exit.
- **~55 lines total** (refactored return construction adds ~10 lines over current)
- **Tests (unit, via dispatch with /bin/echo session):**
  - Wait for text that exists -> result has "matched: true" AND "text" field with screen content
  - Wait for text with short timeout that won't match -> result has "matched: false" AND "text" field (current screen state)
  - Wait for exit on /bin/echo -> result has "matched: true", "exit_code", AND "text" field

### Step 4.5 — Modify `handleResize`

**Current:** returns `{ok: true}` via `jsonOk` helper
**New:** create `json.ObjectMap`, call `appendScreenFields` to return screen state showing the new layout after resize

- Replace `jsonOk` with inline ObjectMap construction + `appendScreenFields`
- Only `tui_send` exposes `settle_ms` because it is the primary input tool where agents need control over drain timing. `handleStart` uses a fixed 100ms drain. `handleResize`, `handleWait`, and `handleScreen` use the default `drain()` (non-blocking) inside `appendScreenFields`.
- **~28 lines**
- **Tests (unit, via dispatch):**
  - Resize a session -> result has "text", "cols" matching new cols, "rows" matching new rows

---

## Phase 5: Schema Updates

### Step 5.1 — Update `inputSchema`

Add to `tui_send`:
- `keys` (array): "Array of key tokens. Each token is one of: key name (enter, down, tab), modifier+key (ctrl+c, shift+tab), key*N repeat (down*5), or text:literal (text:hello). Prefix text: is reserved."
- `settle_ms` (integer): "Wait ms for child process to react after input (default 50, max 5000, 0 to skip)"

Add `region` (object) to: `tui_screen`, `tui_send`, `tui_start`, `tui_wait`, `tui_resize`
- Description: "Crop screen output to region. Object with optional fields: row (default 0), col (default 0), width (default terminal cols), height (default terminal rows). Clamped to terminal bounds."
- The `region` property requires a nested object schema that `addProp` cannot produce. Build the region schema inline: construct a `json.ObjectMap` with `type: "object"` and a nested `properties` map containing `row`, `col`, `width`, `height` (each `type: "integer"`). Apply this to all 5 tools.

### Step 5.2 — Update tool descriptions

Update `tool_defs` descriptions:
- `tui_start`: "Start a TUI program and return initial screen state"
- `tui_send`: "Send input and return screen state"
- `tui_wait`: "Wait for a condition and return screen state"
- `tui_resize`: "Resize terminal and return screen state"

---

## Phase 6: Documentation

### Step 6.1 — Update README.md

- Update `tui_send` tool description: add `keys` and `settle_ms` parameters
- Add `region` parameter documentation to: `tui_screen`, `tui_send`, `tui_start`, `tui_wait`, `tui_resize`
- Note which tools now return screen state in their response
- Add `keys` syntax reference section with examples:
  - `"enter"` — single key
  - `"ctrl+c"` — modified key
  - `"down*5"` — repeat 5 times
  - `"text:hello world"` — literal text
  - `"text:*"` — literal asterisk (since `*` is the repeat operator)
- Document reserved prefix: `text:` is reserved; tokens starting with `text:` are always interpreted as literal text payloads

---

## Files Modified

| File | Changes |
|------|---------|
| `src/tools.zig` | 5 new types (RepeatResult, ModKeyResult, KeyAction, BatchError, constants), 6 new functions (parseRepeatSuffix, parseModsAndKey, parseKeyToken, executeKeyBatch, parseRegion, appendScreenFields), 5 handler modifications (handleSend, handleStart, handleScreen, handleWait, handleResize), schema updates |
| `README.md` | Updated tool documentation |

## Files NOT Modified (reused as-is)

| File | What We Reuse |
|------|---------------|
| `src/screen.zig` | `regionText()`, `RegionOpts` |
| `src/input.zig` | `KeyCode`, `Modifiers`, `encodeKey()` |
| `src/Session.zig` | `sendText()`, `sendKey()`, `drain()`, `drainFor()`, `getScreen()` |
| `src/mcp.zig` | `JsonValue` |

## Verification

1. `zig build test` — all existing tests pass, all new unit tests pass
2. `zig build` — clean build, no warnings
3. Manual MCP test: start a session with `/bin/cat`, send `keys: ["text:hello", "enter", "text:world"]`, verify response includes `text` field containing "hello" and "world" and `processed` is not present (success case)
4. Manual batch error test: send `keys: ["down", "INVALID"]`, verify response includes `error` and `processed: 1`
5. Manual region test: send `tui_screen` with `region: {row: 0, col: 0, width: 5, height: 1}`, verify truncated output
6. Manual settle test: send `keys: ["text:hello"]` with `settle_ms: 200`, verify screen text contains "hello"
7. Backward compat: send `tui_send` with old `key`/`text` params (no `keys`), verify still works and now includes screen state
8. handleStart test: call `tui_start` with command `/bin/echo test`, verify response includes both `session_id` and `text` containing "test"
