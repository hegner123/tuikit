# tui-test-ghost — TUI Testing Toolkit

## Overview

A Zig-native TUI testing toolkit built on Ghostty's terminal emulation core (`ghostty-vt`). Spawns TUI programs in a pseudo-terminal, feeds their output through a production-grade VTE, and exposes structured screen state for programmatic assertion. Delivered as both a Zig library and an MCP server for AI agent interaction.

## Architecture

```
[TUI Process] <--PTY master/slave--> [Pty]
                                       |
                                       v  raw bytes from master fd
                                   [Session]
                                       |
                                       v  feed to ghostty-vt
                              [ReadonlyStream + Terminal]
                                       |
                                       v  structured screen state
                                  [Screen API]
                                       |
                          +------------+------------+
                          |                         |
                     [MCP Server]              [Zig Library]
                   (JSON-RPC stdio)         (direct import)
```

### Data Flow

1. `Pty.open()` creates master/slave fd pair
2. Child process spawned on slave fd via fork/exec
3. Parent reads bytes from master fd
4. Bytes fed to `ghostty_vt.Terminal` via `ReadonlyStream.nextSlice()`
5. Terminal state queried: `plainString()`, cell access, cursor position
6. Input sent to child via `write()` on master fd (raw text or encoded keys)

### Threading Model

**Single-threaded with explicit drain.** Every operation that reads terminal state first drains all pending bytes from the PTY master fd. No background threads. This follows TigerStyle: no hidden control flow, run at your own pace.

The drain cycle:
1. `poll(master_fd, POLLIN, timeout=0)` — check if bytes available
2. `read(master_fd, buf)` — read available bytes
3. `stream.nextSlice(buf)` — feed to terminal
4. Repeat until `poll` returns no data
5. Now terminal state is current — safe to query

### Key Design Decisions

- **Static allocation for session pool.** Max 16 concurrent sessions. Pool is heap-allocated (1MB+ inline buffers exceed safe stack size). Allocated once at startup via the provided allocator.
- **Bounded read buffer.** 64KB per drain cycle. Matches Ghostty's fuzz test buffer size.
- **No recursion.** All loops bounded. All queues bounded.
- **Assertions in production.** ReleaseSafe mode for all builds.
- **libc linkage.** Required for `openpty()` and Ghostty SIMD. Acceptable cost.
- **Ghostty dependency pinning.** Use a path dependency during development, but record the Ghostty commit hash in build.zig.zon comments. Before any release, switch to a URL dependency with hash for reproducible builds.
- **Active screen buffer.** All screen query functions operate on `terminal.screens.active`, which automatically reflects whichever screen buffer the TUI program is using (primary or alternate).
- **Session cleanup.** When the MCP server reads EOF on stdin (client disconnect), `SessionPool.destroyAll()` runs before exit. A per-session inactivity timeout (default 5 minutes) reaps abandoned sessions during normal operation.

---

## Documentation References

Agents MUST have access to these before implementing any step:

| Resource | Location | When Needed |
|----------|----------|-------------|
| Ghostty source | `/Users/home/Documents/Code/ghostty/` | All milestones |
| Ghostty Terminal API | `/Users/home/Documents/Code/ghostty/src/terminal/Terminal.zig` | M1, M3, M4 |
| Ghostty ReadonlyStream | `/Users/home/Documents/Code/ghostty/src/terminal/stream_readonly.zig` | M1, M2 |
| Ghostty Page/Cell | `/Users/home/Documents/Code/ghostty/src/terminal/page.zig` | M3 |
| Ghostty Style | `/Users/home/Documents/Code/ghostty/src/terminal/style.zig` | M3 |
| Ghostty PTY | `/Users/home/Documents/Code/ghostty/src/pty.zig` | M2 |
| Ghostty Command | `/Users/home/Documents/Code/ghostty/src/Command.zig` | M2 |
| Ghostty Key Input | `/Users/home/Documents/Code/ghostty/src/input/` | M4 |
| Ghostty example | `/Users/home/Documents/Code/ghostty/example/zig-vt/` | M0, M1 |
| Ghostty fuzz stream | `/Users/home/Documents/Code/ghostty/test/fuzz-libghostty/fuzz_stream.zig` | M1, M2 |
| Ghostty inline tests | `/Users/home/Documents/Code/ghostty/src/terminal/Terminal.zig:3111+` | M1, M3 |
| Zig std.posix | `/Users/home/Documents/Code/Zig/0.15.2/lib/zig/std/posix.zig` | M2 |
| Zig std.json | `/Users/home/Documents/Code/Zig/0.15.2/lib/zig/std/json.zig` | M5 |
| Zig IO docs | `~/.claude/zig/IO_DOCUMENTATION.md` | M2, M5 |
| Zig MEM docs | `~/.claude/zig/MEM_DOCUMENTATION.md` | All |
| Zig HEAP docs | `~/.claude/zig/HEAP_DOCUMENTATION.md` | M0, M1 |
| Zig FMT docs | `~/.claude/zig/FMT_DOCUMENTATION.md` | M3, M5 |
| Zig JSON docs | `~/.claude/zig/JSON_DOCUMENTATION.md` | M5 |
| TigerStyle guide | https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md | All |

### Agent Configuration

| Agent | File | Use |
|-------|------|-----|
| `tui-test-ghost-implementer` | `~/.claude/agents-mh/tui-test-ghost-implementer.md` | Primary: step implementation (reads step def, loads refs, implements, tests) |
| `zig-tiger-style-developer` | `~/.claude/agents-mh/zig-tiger-style-developer.md` | Fallback: general Zig implementation |
| `zig-specialist` | `~/.claude/agents-mh/zig-specialist.md` | Review |

---

## TigerStyle Constraints (Enforced at Every Step)

These are non-negotiable. Every function, every step.

1. **>=2 assertions per function.** Pre/postconditions. Paired assertions at call site AND definition site.
2. **70-line function limit.** Extract helpers if approaching. Push `if`s up, `for`s down.
3. **No recursion.** All iteration via bounded loops.
4. **Static allocation.** All memory allocated at init. No allocation after startup (exception: Ghostty's Terminal.init uses its own allocator — we pass one and trust it).
5. **Explicitly-sized types.** `u16`, `u32`, `u64`. Avoid `usize` except where Zig stdlib requires it.
6. **Named arguments via options struct** when parameters could be confused.
7. **No hidden control flow.** No callbacks that fire asynchronously. Explicit drain-then-query model.
8. **Errors are handled.** No `_` for error ignoring. Wrap with context.
9. **Compile-time assertions** for constant relationships (buffer sizes, max values).
10. **`defer` for postconditions** where applicable.

---

## File Structure

```
tui-test-ghost/
├── build.zig                 -- Build configuration
├── build.zig.zon             -- Dependencies (ghostty-vt)
├── PLAN.md                   -- This file
├── START.md                  -- Onboarding guide (M6)
├── CLAUDE.md                 -- Project-specific agent instructions
├── justfile                  -- Build/test/install commands
├── src/
│   ├── main.zig              -- Entry point: MCP server + CLI dispatch
│   ├── root.zig              -- Library root (public API re-exports)
│   ├── Pty.zig               -- PTY open/close/resize/read/write
│   ├── Process.zig           -- Fork/exec child process on PTY
│   ├── Terminal.zig          -- Wrapper around ghostty-vt Terminal
│   ├── Session.zig           -- Session lifecycle (PTY + Terminal + state)
│   ├── SessionPool.zig       -- Bounded pool of sessions
│   ├── screen.zig            -- Screen query functions
│   ├── input.zig             -- Key encoding and text input
│   ├── wait.zig              -- Wait condition polling
│   ├── snapshot.zig          -- Screen snapshot capture and diff
│   ├── mcp.zig               -- MCP JSON-RPC protocol handler
│   ├── tools.zig             -- MCP tool definitions and dispatch
│   └── testing_helpers.zig   -- Shared test utilities
└── ai/
    └── GHOSTTY_API.md        -- Extracted API reference for agents
```

---

## Milestones

### Milestone 0: Project Bootstrap

**Goal:** Working build that imports ghostty-vt and proves the dependency works.

#### Phase 0.1: Scaffold

**Step 0.1.1: Create build.zig.zon**
- Objective: Declare project metadata and ghostty-vt dependency
- Pattern: Copy from `/Users/home/Documents/Code/ghostty/example/zig-vt/build.zig.zon`
- Use path dependency: `.ghostty = .{ .path = "/Users/home/Documents/Code/ghostty" }`
- Add a comment above the dependency with the current Ghostty commit hash for reproducibility
- Before any release: switch to URL dependency with hash (see Ghostty example for format)
- Test: `zig build` succeeds without errors

**Step 0.1.2: Create build.zig**
- Objective: Build configuration with library + executable + test targets
- Pattern: Based on Ghostty example, extended with library target
- Targets: `lib` (static library), `exe` (MCP server + CLI), `test` (unit tests)
- Import `ghostty-vt` module via `b.lazyDependency("ghostty", .{})`
- Test: `zig build` compiles; `zig build test` runs (even if no tests yet)

**Step 0.1.3: Create src/root.zig (library root)**
- Objective: Empty library root that imports ghostty-vt to prove linkage
- Content: `pub const ghostty_vt = @import("ghostty-vt");` + a trivial `comptime` assertion
- Test: `zig build test` passes

**Step 0.1.4: Create src/main.zig (entry point)**
- Objective: Minimal main that creates a ghostty-vt Terminal, prints a string, dumps plainString
- Exact pattern from Ghostty example: init Terminal(80, 24) → printString → plainString → print to stderr
- Test: `zig build run` produces expected output

#### Phase 0.2: Documentation Extraction

**Step 0.2.1: Create ai/GHOSTTY_API.md**
- Objective: Extract and document the ghostty-vt API surface relevant to tui-test-ghost
- Content:
  - Terminal: init, deinit, vtStream, printString, plainString, resize, fullReset, setAttribute, setCursorPos
  - ReadonlyStream: construction via vtStream(), nextSlice() for feeding bytes
  - Screen: cursor access (screens.active.cursor.x/y), dumpStringAlloc
  - Cell: content_tag, codepoint access, style_id, wide, protected
  - Style: fg_color, bg_color, underline_color, flags (bold, italic, faint, etc.)
  - Row: wrap, dirty, semantic_prompt
  - Color: none/palette(u8)/rgb(RGB) variants
  - Page navigation: how to iterate rows and cells
- Source: Read directly from Ghostty source files listed in Documentation References table
- This document is the PRIMARY reference agents use instead of reading Ghostty source every time

**Step 0.2.2: Create CLAUDE.md**
- Objective: Project-specific instructions for agents working on tui-test-ghost
- Content: TigerStyle enforcement, file structure, build commands, test commands, documentation pointers, step-by-step workflow instructions
- Include: "Before implementing any step, read the step definition in PLAN.md AND the referenced source files"

#### Phase 0.3: Project Infrastructure

**Step 0.3.1: Create justfile**
- Objective: Standard build/test/install commands
- Commands:
  - `build` — `zig build`
  - `test` — `zig build test`
  - `run` — `zig build run`
  - `fmt` — `zig fmt src/`
  - `install` — build + codesign + copy to /usr/local/bin/tui-test-ghost
  - `clean` — `rm -rf zig-out .zig-cache`
- Test: `just build` and `just test` work

**Step 0.3.2: Create src/testing_helpers.zig**
- Objective: Shared test utilities used across all test files
- Functions:
  - `createTestTerminal(cols: u16, rows: u16) -> Terminal` — init with testing.allocator
  - `feedBytes(terminal: *Terminal, stream: *ReadonlyStream, bytes: []const u8) -> void` — feed VT data
  - `expectScreenContains(terminal: *Terminal, needle: []const u8) -> !void` — assert text on screen
- Assertions: >=2 per function (parameter validation + postcondition)
- Test: Inline tests exercise each helper

---

### Milestone 1: Terminal Wrapper

**Goal:** A tui-test-ghost-owned Terminal type that wraps ghostty-vt with our query API and TigerStyle assertions.

#### Phase 1.1: Terminal Type

**Step 1.1.1: Create src/Terminal.zig — Type definition and init**
- Objective: Wrapper struct around ghostty-vt Terminal with explicit lifecycle
- Fields:
  ```
  inner: ghostty_vt.Terminal       -- the ghostty terminal
  stream: ReadonlyStream           -- VT byte processing stream
  cols: u16                        -- terminal width
  rows: u16                        -- terminal height
  bytes_fed: u64                   -- total bytes processed (diagnostic)
  state: enum { uninitialized, ready, closed }
  ```
- Functions:
  - `init(alloc: Allocator, opts: Options) !Terminal`
    - Options: `cols: u16, rows: u16, max_scrollback: usize = 10_000`
    - NOTE: Ghostty's `Terminal.Options` uses `size.CellCountInt` (which is `u16`) for cols/rows, `usize` for max_scrollback. Our wrapper accepts the same types.
    - Assertions: cols > 0, rows > 0, cols <= 500, rows <= 500 (bounded)
    - Postcondition: state == .ready, bytes_fed == 0
  - `deinit(self: *Terminal, alloc: Allocator) void`
    - Assertion: state == .ready (not double-free)
    - Postcondition: state == .closed
- Refs: Ghostty Terminal.zig:207-249 (Options struct at line 207, init at line 219), example/zig-vt/src/main.zig
- **VERIFY:** Agent MUST read Terminal.zig Options struct and confirm the exact parameter names and types before implementing. Do not trust this plan's signatures blindly — the Ghostty API is alpha and may have changed.
- Test: Create terminal, verify state, deinit, verify closed. Test invalid sizes assert.

**Step 1.1.2: Terminal.feed — Process raw VT bytes**
- Objective: Feed raw bytes into the terminal's ReadonlyStream
- Function: `feed(self: *Terminal, data: []const u8) void`
  - Assertion: state == .ready
  - Assertion: data.len <= 65536 (bounded input per call)
  - Calls `self.stream.nextSlice(data)`
  - Updates `self.bytes_fed += data.len`
  - Postcondition: bytes_fed increased by exactly data.len
- Refs: Ghostty stream_readonly.zig, fuzz_stream.zig
- Test: Feed "hello" bytes, verify bytes_fed == 5. Feed ESC sequences, no crash.

**Step 1.1.3: Terminal.plainText — Get viewport as string**
- Objective: Return the current screen content as a plain text string
- Function: `plainText(self: *Terminal, alloc: Allocator) ![]const u8`
  - Assertion: state == .ready
  - Calls `self.inner.plainString(alloc)`
  - Postcondition: returned slice length > 0 or terminal is blank (length >= 0)
- Refs: Ghostty Terminal.zig:3058-3067
- Test: Feed "hello\r\nworld", verify plainText contains both lines.

**Step 1.1.4: Terminal.cursorPosition — Get cursor location**
- Objective: Return current cursor row and column
- Function: `cursorPosition(self: *Terminal) CursorPos`
  - CursorPos: `struct { row: u16, col: u16 }`
  - Assertion: state == .ready
  - Access: `self.inner.screens.active.cursor.x` and `.y`
  - Postcondition: row < self.rows, col < self.cols
- Refs: Ghostty Screen.zig cursor struct
- Test: Fresh terminal cursor at (0,0). Feed "AB\r\n", cursor at (1,0). Feed "X", cursor at (1,1).

**Step 1.1.5: Terminal.resize — Change terminal dimensions**
- Objective: Resize the terminal grid
- Function: `resize(self: *Terminal, alloc: Allocator, new_cols: u16, new_rows: u16) !void`
  - Assertions: state == .ready, new_cols > 0, new_rows > 0, bounded <= 500
  - Calls `self.inner.resize(alloc, new_cols, new_rows)` — NOTE: Ghostty's resize takes separate cols, rows args, NOT an options struct
  - Updates self.cols, self.rows
  - Postcondition: self.cols == new_cols, self.rows == new_rows
- Refs: Ghostty Terminal.zig:2820-2867
- Test: Create 80x24, resize to 40x12, verify dimensions. Feed text before resize, verify reflow.

#### Phase 1.2: Screen Query Functions

**Step 1.2.1: Create src/screen.zig — cellAt**
- Objective: Read a single cell's content and attributes
- Types:
  ```
  CellInfo = struct {
      char: u21,           -- Unicode codepoint (0 for empty)
      fg: ColorInfo,       -- foreground color
      bg: ColorInfo,       -- background color
      bold: bool,
      italic: bool,
      underline: bool,
      strikethrough: bool,
      dim: bool,
      wide: enum { narrow, wide, spacer },
  };
  ColorInfo = union(enum) {
      default: void,
      palette: u8,
      rgb: struct { r: u8, g: u8, b: u8 },
  };
  ```
- Function: `cellAt(terminal: *const Terminal, row: u16, col: u16) CellInfo`
  - Assertions: row < terminal.rows, col < terminal.cols, terminal.state == .ready
  - Navigate page structure: get pin for (row, col), read Cell, resolve style via style_id
  - Postcondition: returned CellInfo has valid char (or 0 for empty)
- Refs: Ghostty page.zig Cell struct (line 2055+), style.zig Style struct
- Test: Feed colored text (ESC[31m = red fg), verify cellAt returns correct char and fg color.
- **NOTE:** This step requires careful study of Ghostty's page navigation. The agent MUST read:
  - `page.zig` Cell type definition
  - `Screen.zig` cursor and pin navigation
  - `style.zig` Style and StyleSet for resolving style_id → Style
- **ACTIVE SCREEN:** Always use `terminal.inner.screens.active` to access the screen. This automatically reflects whichever buffer the TUI program is using (primary or alternate). TUI programs like vim and htop switch to the alternate screen buffer — our code must not assume primary screen only.

**Step 1.2.2: screen.rowText — Extract text from a single row**
- Function: `rowText(terminal: *const Terminal, alloc: Allocator, row: u16) ![]const u8`
  - Assertion: row < terminal.rows
  - Iterate cells in row, collect codepoints, trim trailing whitespace
  - Postcondition: result.len <= terminal.cols * 4 (max UTF-8 bytes per cell)
- Test: Feed "hello   " (with trailing spaces), verify rowText trims them. Feed wide chars, verify correct.

**Step 1.2.3: screen.regionText — Extract rectangular region**
- Function: `regionText(terminal: *const Terminal, alloc: Allocator, opts: RegionOpts) ![]const u8`
  - RegionOpts: `{ top: u16, left: u16, height: u16, width: u16 }`
  - Assertions: top + height <= terminal.rows, left + width <= terminal.cols
  - Extract text from the rectangular region, newline-separated rows
  - Postcondition: result contains exactly `height` lines (or fewer if trailing blank)
- Test: Feed a 5x5 grid of letters, extract 3x3 sub-region, verify correct content.

**Step 1.2.4: screen.findText — Search for text on screen**
- Function: `findText(terminal: *const Terminal, alloc: Allocator, needle: []const u8) ![]Match`
  - Match: `struct { row: u16, col: u16 }`
  - Assertion: needle.len > 0, needle.len <= terminal.cols (single-line search)
  - Search each row for the needle substring
  - Postcondition: all matches have row < terminal.rows, col < terminal.cols
  - Return bounded: max 256 matches (static array, no unbounded allocation)
- Test: Feed text with repeated pattern, verify all occurrences found. Feed no match, verify empty.

**Step 1.2.5: screen.containsText — Boolean text search**
- Function: `containsText(terminal: *const Terminal, alloc: Allocator, needle: []const u8) !bool`
  - Short-circuit search: iterate rows, return true on first match. Do NOT call findText (which collects all matches — wasteful for a boolean check).
  - Assertion: needle.len > 0
  - Postcondition: if true, needle exists somewhere on screen
- Test: Feed "hello world", containsText("world") == true, containsText("xyz") == false.

---

### Milestone 2: PTY Engine

**Goal:** Open PTY, spawn a child process, read/write the master fd.

#### Phase 2.1: PTY Management

**Step 2.1.1: Create src/Pty.zig — Type definition and open**
- Objective: Open a master/slave PTY pair
- Fields:
  ```
  master: std.posix.fd_t    -- master fd (parent reads/writes this)
  slave: std.posix.fd_t     -- slave fd (child's stdin/stdout/stderr)
  state: enum { closed, open }
  ```
- Function: `open(size: WinSize) !Pty`
  - WinSize: `struct { cols: u16, rows: u16, xpixel: u16 = 0, ypixel: u16 = 0 }`
  - Assertions: size.cols > 0, size.rows > 0
  - Implementation: Call C `openpty(&master, &slave, null, null, &ws)` via `@cImport`
  - Set `FD_CLOEXEC` on master fd (not slave — child needs it)
  - Set `IUTF8` flag via `tcgetattr`/`tcsetattr` on **master** fd (NOT slave — Ghostty sets it on master, see pty.zig:161-166)
  - errdefer: close both fds on failure
  - Postcondition: state == .open, master > 0, slave > 0, master != slave
- Refs: Ghostty pty.zig lines 86-172
- Test: Open PTY, verify fds are valid, close. Open with various sizes.
- **Platform:** macOS first. `@cImport` from `<util.h>` for `openpty`.

**Step 2.1.2: Pty.close — Clean shutdown**
- Function: `close(self: *Pty) void`
  - Assertion: state == .open
  - Close master fd, close slave fd (if not already closed)
  - Postcondition: state == .closed
- Test: Open + close, verify no fd leak (open twice in sequence to prove fds are reused).

**Step 2.1.3: Pty.closeSlave — Close slave in parent after fork**
- Function: `closeSlave(self: *Pty) void`
  - Assertion: state == .open
  - Close only the slave fd. Set slave to -1 sentinel.
  - This is called in the parent process after fork, since parent only needs master.
- Test: Open PTY, closeSlave, verify slave == -1, master still valid.

**Step 2.1.4: Pty.setSize — Resize PTY**
- Function: `setSize(self: *Pty, size: WinSize) !void`
  - Assertion: state == .open
  - `ioctl(self.master, TIOCSWINSZ, &winsize)`
  - Sends SIGWINCH to child process automatically (kernel does this)
- Refs: Ghostty pty.zig line 207
- Test: Open PTY, setSize to various dimensions, verify no error.

**Step 2.1.5: Pty.read — Non-blocking read from master**
- Function: `read(self: *Pty, buf: []u8) ReadResult`
  - ReadResult: `union(enum) { data: usize, eof: void, would_block: void, err: PtyError }`
  - NOTE: Use explicit `PtyError` error set, NOT `anyerror` (TigerStyle requires explicit error sets)
  - Assertion: state == .open, buf.len > 0, buf.len <= 65536
  - Use `std.posix.read(self.master, buf)` with O_NONBLOCK
  - Postcondition: if data, result <= buf.len
- Test: Open PTY, write to slave side, read from master, verify round-trip.

**Step 2.1.6: Pty.write — Write to master (send input to child)**
- Function: `write(self: *Pty, data: []const u8) !usize`
  - Assertion: state == .open, data.len > 0
  - `std.posix.write(self.master, data)`
  - Postcondition: result <= data.len, result > 0
- Test: Open PTY, write data, read back echo (PTY echoes by default unless raw mode).

**Step 2.1.7: Pty.poll — Check if data available**
- Function: `poll(self: *Pty, timeout_ms: i32) PollResult`
  - PollResult: `enum { ready, timeout, error, hangup }`
  - Assertion: state == .open
  - Use `std.posix.poll()` on master fd with POLLIN
  - Postcondition: result is one of the four states
- Test: Open PTY, poll with timeout=0 (no data yet), verify timeout. Write data, poll, verify ready.

#### Phase 2.2: Process Management

**Step 2.2.1: Create src/Process.zig — Type definition and spawn**
- Objective: Fork and exec a child process on a PTY slave
- Fields:
  ```
  pid: std.posix.pid_t       -- child PID (0 if not running)
  state: enum { idle, running, exited }
  exit_code: ?u8             -- set after waitpid
  ```
- Function: `spawn(pty: *Pty, argv: []const []const u8, env: ?[*:null]const ?[*:0]const u8) !Process`
  - Assertions: argv.len > 0, pty.state == .open
  - Implementation:
    1. `std.posix.fork()`
    2. Parent: store pid, closeSlave on pty, return
    3. Child: reset signals, setsid, ioctl TIOCSCTTY, dup2 slave to 0/1/2, close master+slave, execvpe
  - Postcondition: state == .running, pid > 0
- Refs: Ghostty Command.zig:189-257, pty.zig:215-251
- Test: Spawn `/bin/echo hello`, read output from PTY master, verify "hello\r\n".
- **CRITICAL POST-FORK SAFETY — ALL OF THESE ARE MANDATORY:**
  1. **ZERO allocation between fork and exec.** On macOS, fork() without exec() is undefined behavior if you touch anything that isn't async-signal-safe. No `std.debug.print`, no allocator calls, no string formatting. Only raw syscalls.
  2. **Use `posix.exit()` (which is `_exit()`), NEVER `return`** in the child process on any failure. Returning from the child causes two copies of the parent to run. Every error path in the child must call `posix.exit(1)`.
  3. **Only async-signal-safe functions** between fork and exec: `setsid`, `ioctl`, `dup2`, `close`, `execvpe`, `_exit`. No `malloc`, no `printf`, no `std.log`.
  4. **Signal reset before exec:** Reset SIGABRT, SIGALRM, SIGBUS, SIGCHLD, SIGFPE, SIGHUP, SIGILL, SIGINT, SIGPIPE, SIGSEGV, SIGTRAP, SIGTERM, SIGQUIT to SIG_DFL using `posix.sigaction()`.
  5. **Child sequence:** reset signals → `setsid()` → `ioctl(slave, TIOCSCTTY, 0)` → `dup2(slave, 0/1/2)` → `close(master)` → `close(slave)` → `execvpeZ()`
  - Read Ghostty's `childPreExec` (pty.zig:215-251) and `Command.zig:189-257` line by line before implementing.

**Step 2.2.2: Process.isAlive — Check if child is still running**
- Function: `isAlive(self: *Process) bool`
  - Non-blocking `waitpid(self.pid, WNOHANG)`
  - If exited, set state = .exited, store exit_code
  - Assertion: state != .idle
- Test: Spawn `sleep 10`, isAlive == true. Spawn `true`, wait briefly, isAlive == false.

**Step 2.2.3: Process.terminate — Send signal to child**
- Function: `terminate(self: *Process) !void`
  - Assertion: state == .running
  - Send SIGTERM. Set state to .exited after successful kill.
  - For graceful shutdown: SIGTERM first, caller can escalate to SIGKILL.
- Test: Spawn `sleep 100`, terminate, verify isAlive == false.

**Step 2.2.4: Process.wait — Block until child exits**
- Function: `wait(self: *Process, timeout_ms: u32) !WaitResult`
  - WaitResult: `union(enum) { exited: u8, signaled: u8, timeout: void }`
  - Assertion: state == .running
  - Poll-wait loop with bounded timeout
  - Postcondition: if not timeout, state == .exited
- Test: Spawn `true`, wait, verify exited(0). Spawn `false`, wait, verify exited(1).

---

### Milestone 3: Session — The Core Abstraction

**Goal:** A Session combines PTY + Process + Terminal into a single unit with drain-then-query semantics.

#### Phase 3.1: Session Type

**Step 3.1.1: Create src/Session.zig — Type definition and create**
- Objective: The unified handle for a TUI test session
- Fields:
  ```
  id: u8                         -- session ID (0-15)
  pty: Pty                       -- PTY pair
  process: Process               -- child process
  terminal: Terminal             -- ghostty-vt wrapper
  read_buf: [65536]u8            -- static read buffer for drain
  state: enum { idle, active, stopped }
  alloc: Allocator               -- for terminal operations that need allocation
  ```
- Function: `create(alloc: Allocator, id: u8, opts: CreateOpts) !Session`
  - CreateOpts:
    ```
    cols: u16 = 80,
    rows: u16 = 24,
    argv: []const []const u8,
    env: ?[*:null]const ?[*:0]const u8 = null,
    max_scrollback: usize = 1000,
    ```
  - Assertions: id < 16, opts.argv.len > 0, cols and rows bounded
  - Steps: init Terminal → open Pty → spawn Process → closeSlave
  - errdefer: clean up in reverse order on any failure
  - Postcondition: state == .active
- Refs: All previous types
- Test: Create session with `/bin/echo test`, verify state == .active.

**Step 3.1.2: Session.destroy — Clean shutdown**
- Function: `destroy(self: *Session) void`
  - If process running: terminate, wait(1000ms), then SIGKILL if still alive
  - Close PTY
  - Deinit Terminal
  - Set state = .stopped
  - Assertion: state == .active before call
  - Postcondition: state == .stopped
- Test: Create session with `sleep 100`, destroy, verify clean shutdown.

#### Phase 3.2: Drain and Query

**Step 3.2.1: Session.drain — Sync PTY output to terminal state**
- Objective: Read all pending bytes from PTY and feed to terminal
- Function: `drain(self: *Session) DrainResult`
  - DrainResult: `struct { bytes_read: u32, eof: bool }`
  - Assertion: state == .active
  - Loop:
    1. poll(master, timeout=0) — any data?
    2. If ready: read into read_buf, feed to terminal
    3. If would_block or timeout: break
    4. If eof or hangup: set eof flag, break
  - Loop bound: max 256 iterations per drain call (prevent infinite loop on fast producer)
  - Postcondition: bytes_read is cumulative bytes fed this drain cycle
- Test: Create session with `echo hello`, drain, verify bytes_read > 0. Drain again, verify eof.

**Step 3.2.2: Session.drainFor — Drain with timeout**
- Function: `drainFor(self: *Session, timeout_ms: u32) DrainResult`
  - Like drain, but polls with the given timeout on first iteration
  - This allows waiting for the child to produce output
  - Assertion: timeout_ms <= 30_000 (bounded to 30 seconds)
- Test: Create session with `sleep 0.1 && echo done`, drainFor(500), verify "done" appears.

**Step 3.2.3: Session.screen — Get current screen text (drain + query)**
- Function: `screen(self: *Session, alloc: Allocator) ![]const u8`
  - Drains first, then calls terminal.plainText
  - This is the high-level "what's on screen right now?" query
  - Assertion: state == .active
- Test: Create session with `echo hello`, screen() contains "hello".

**Step 3.2.4: Session.sendText — Write raw text to PTY**
- Function: `sendText(self: *Session, text: []const u8) !void`
  - Assertion: state == .active, text.len > 0, text.len <= 4096
  - Write text to PTY master
- Test: Create session with `cat`, sendText("hello\n"), drain, verify "hello" on screen.

**Step 3.2.5: Session.sendKey — Write encoded key to PTY**
- Function: `sendKey(self: *Session, key: KeyCode, mods: Modifiers) !void`
  - KeyCode: enum with common keys (enter, tab, escape, up, down, left, right, backspace, delete, f1-f12, etc.)
  - Modifiers: packed struct { ctrl: bool, alt: bool, shift: bool }
  - Encode using standard ANSI escape sequences (not Kitty protocol — use legacy for maximum compatibility)
  - Assertion: state == .active
  - Write encoded bytes to PTY master
- Refs: Standard VT100/xterm key encoding tables
- Test: Create session with `cat`, sendKey(.enter), drain, verify newline on screen.

#### Phase 3.3: Session Pool

**Step 3.3.1: Create src/SessionPool.zig — Bounded pool**
- Objective: Manage up to 16 concurrent sessions
- **IMPORTANT:** SessionPool MUST be heap-allocated, not stack-allocated. Each Session contains a 65KB read_buf inline. 16 sessions = ~1MB+ which exceeds safe stack size (default 8MB, but fragile). Allocate the pool itself via the provided allocator in init.
- Fields:
  ```
  sessions: [16]?Session    -- fixed array, null = empty slot
  count: u8                 -- active session count
  alloc: Allocator
  last_activity: [16]i64    -- timestamp of last operation per session (for timeout reaping)
  ```
- Functions:
  - `init(alloc: Allocator) !*SessionPool` — heap-allocates the pool, returns pointer
  - `create(opts: Session.CreateOpts) !u8` — returns session ID
    - Assertion: count < 16 (pool not full)
    - Find first null slot, create session with that ID
    - Postcondition: count incremented
  - `get(id: u8) !*Session` — get session by ID
    - Assertion: id < 16
    - Return error if slot is null
  - `destroy(id: u8) !void` — destroy session
    - Assertion: id < 16, slot is not null
    - Postcondition: count decremented, slot is null
  - `destroyAll() void` — shutdown all sessions
- Test: Create 3 sessions, verify count == 3. Destroy one, verify count == 2. Get by ID works.

---

### Milestone 4: Wait Conditions and Advanced Input

**Goal:** Polling-based wait conditions and full keyboard input encoding.

#### Phase 4.1: Wait Conditions

**Step 4.1.1: Create src/wait.zig — waitForText**
- Function: `waitForText(session: *Session, alloc: Allocator, needle: []const u8, timeout_ms: u32) !bool`
  - Assertions: needle.len > 0, timeout_ms <= 30_000, session.state == .active
  - Loop (bounded by timeout):
    1. drain session
    2. check if screen contains needle
    3. if found: return true
    4. if eof or timeout: return false
    5. sleep 10ms (bounded poll interval)
  - Postcondition: if true returned, screen definitely contains needle
- Test: Spawn `sleep 0.1 && echo READY`, waitForText("READY", 2000) == true. waitForText("NEVER", 100) == false.

**Step 4.1.2: wait.waitForStable — Screen stops changing**
- Function: `waitForStable(session: *Session, stability_ms: u32, timeout_ms: u32) !bool`
  - "Stable" means no new bytes arrived from the PTY for stability_ms milliseconds
  - Uses `terminal.bytes_fed` delta (NOT screen text hashing — hashing has a race window where content could change and revert within the window, falsely appearing stable)
  - Assertions: stability_ms <= timeout_ms, timeout_ms <= 30_000
  - Loop:
    1. Record `bytes_fed_before = session.terminal.bytes_fed`
    2. `drainFor(stability_ms)` — poll with timeout
    3. Record `bytes_fed_after = session.terminal.bytes_fed`
    4. If `bytes_fed_after == bytes_fed_before`: no new data arrived, screen is stable, return true
    5. If total elapsed > timeout_ms: return false
    6. Repeat
  - Postcondition: if true, no bytes were received for at least stability_ms
- Test: Spawn program with fast output then idle, waitForStable detects idle state.

**Step 4.1.3: wait.waitForCursor — Cursor reaches position**
- Function: `waitForCursor(session: *Session, row: u16, col: u16, timeout_ms: u32) !bool`
  - Assertions: row < session.terminal.rows, col < session.terminal.cols
  - Same polling pattern as waitForText but checks cursor position
- Test: Spawn program that moves cursor, wait for expected position.

**Step 4.1.4: wait.waitForExit — Process exits**
- Function: `waitForExit(session: *Session, timeout_ms: u32) !?u8`
  - Returns exit code if process exits within timeout, null if timeout
  - Drains remaining PTY output before returning
  - Assertion: timeout_ms <= 60_000
- Test: Spawn `true`, waitForExit returns 0. Spawn `false`, returns 1. Spawn `sleep 100`, timeout returns null.

#### Phase 4.2: Input Encoding

**Step 4.2.1: input.encodeKey — Thin wrapper around Ghostty's key encoder**
- Objective: Provide a simplified key encoding API using Ghostty's exported `input.encodeKey`
- **DO NOT hand-roll ANSI key encoding.** Ghostty's `ghostty-vt` exports a full key encoder at `input.encodeKey` (see `lib_vt.zig:100`). It supports both legacy xterm and Kitty keyboard protocol, handles all edge cases, and is battle-tested. Use it.
- Types exported by ghostty-vt:
  ```
  input.Key          -- key code enum (from input/key.zig)
  input.KeyAction    -- press/release/repeat
  input.KeyEvent     -- full event struct
  input.KeyMods      -- modifier bitmask
  input.KeyEncodeOptions -- encoding options (kitty_flags, cursor_key_application, etc.)
  input.encodeKey    -- fn(writer, event, opts) !void
  ```
- Function: `encodeKey(key: KeyCode, mods: Modifiers, buffer: []u8) ![]const u8`
  - Our `KeyCode` enum maps to Ghostty's `input.Key`
  - Our `Modifiers` maps to Ghostty's `input.KeyMods`
  - Creates a `KeyEvent` and `KeyEncodeOptions` (with `kitty_flags = 0` for legacy mode)
  - Writes to a fixed buffer writer wrapping `buffer`
  - Assertions: buffer.len >= 32 (sufficient for any key sequence)
  - Postcondition: returned slice.len > 0
- Refs: Ghostty lib_vt.zig:80-101, input/key_encode.zig:75-90, input/key.zig
- **VERIFY:** Agent MUST read `input/key.zig` to understand the `Key` enum values and `KeyEvent` struct fields before implementing the mapping.
- Test: Table-driven tests for common keys. Verify Enter, Ctrl+C, arrows, F-keys, Shift+Up all produce correct sequences.

**Step 4.2.2: Integrate encodeKey into Session.sendKey**
- Objective: Wire encodeKey into the Session.sendKey function from Step 3.2.5
- This may be done during 3.2.5 or deferred here depending on order of execution
- Test: Full round-trip — sendKey → drain → verify screen change

---

### Milestone 5: Snapshots

**Goal:** Capture, save, compare, and diff terminal screen states for golden file testing.

#### Phase 5.1: Snapshot Capture

**Step 5.1.1: Create src/snapshot.zig — Snapshot type and capture**
- Types:
  ```
  Snapshot = struct {
      cols: u16,
      rows: u16,
      cursor_row: u16,
      cursor_col: u16,
      text: []const u8,        -- plain text representation, newline-separated rows
      // Future: cell-level data with styles
  };
  ```
- Function: `capture(session: *Session, alloc: Allocator) !Snapshot`
  - Drains session first
  - Captures text + cursor position
  - Assertion: session.state == .active
  - Postcondition: snapshot.rows == session.terminal.rows
- Test: Spawn `echo hello`, capture snapshot, verify text contains "hello".

**Step 5.1.2: snapshot.diff — Compare two snapshots**
- Function: `diff(a: Snapshot, b: Snapshot, alloc: Allocator) ![]const u8`
  - Returns human-readable diff string (line-by-line comparison)
  - If identical: returns empty string
  - Assertion: a.cols == b.cols and a.rows == b.rows (same dimensions)
- Test: Two identical snapshots → empty diff. Different snapshots → non-empty diff.

**Step 5.1.3: snapshot.save and snapshot.load — Golden file I/O**
- Functions:
  - `save(snap: Snapshot, path: []const u8) !void` — write to file
  - `load(alloc: Allocator, path: []const u8) !Snapshot` — read from file
- Format: Simple text format with header line (`# tui-test-ghost snapshot cols=80 rows=24 cursor=0,0`) followed by raw text
- Assertion: path.len > 0
- Test: Capture → save → load → compare with original, verify identical.

**Step 5.1.4: snapshot.expectMatch — Assert snapshot matches golden file**
- Function: `expectMatch(session: *Session, alloc: Allocator, golden_path: []const u8) !void`
  - Capture current snapshot, load golden file, diff
  - If diff non-empty: return error with diff content for diagnostic
  - If golden file doesn't exist: save current as golden (first-run behavior)
- Test: Integration test with golden file creation and verification.

---

### Milestone 6: MCP Server

**Goal:** Expose tui-test-ghost as an MCP server over stdio for AI agent consumption.

#### Phase 6.1: JSON-RPC Transport

**Step 6.1.1: Create src/mcp.zig — Message types**
- Types:
  ```
  Request = struct {
      jsonrpc: []const u8,    -- must be "2.0"
      id: ?JsonValue,         -- request ID
      method: []const u8,     -- method name
      params: ?JsonValue,     -- parameters
  };
  Response = struct {
      jsonrpc: []const u8,
      id: ?JsonValue,
      result: ?JsonValue,
      @"error": ?ErrorObj,
  };
  ErrorObj = struct {
      code: i32,
      message: []const u8,
      data: ?JsonValue,
  };
  ```
- Refs: Zig JSON docs, MCP protocol specification
- Test: Serialize/deserialize request and response types.

**Step 6.1.2: mcp.readRequest — Read JSON-RPC from stdin**
- Function: `readRequest(alloc: Allocator, reader: anytype) !Request`
  - Read line from stdin (MCP uses newline-delimited JSON)
  - Parse as JSON, extract fields
  - Assertion: jsonrpc == "2.0"
- Test: Feed JSON string to reader, verify parsed request.

**Step 6.1.3: mcp.writeResponse — Write JSON-RPC to stdout**
- Function: `writeResponse(writer: anytype, response: Response) !void`
  - Serialize Response as JSON, write to stdout with newline
  - Assertion: response.jsonrpc is "2.0"
- Test: Write response, verify JSON format.

**Step 6.1.4: mcp.handleInitialize — MCP handshake**
- Function: `handleInitialize(req: Request) Response`
  - Return server info, capabilities, tool list
  - Capabilities: `{ tools: { listChanged: false } }`
- Test: Send initialize request, verify response has correct protocol version and capabilities.

#### Phase 6.2: Tool Definitions

**Step 6.2.1: Create src/tools.zig — Tool registry**
- Objective: Define all MCP tools with their JSON schemas
- Tools:
  ```
  tui_start:    { command: string, args?: string[], cols?: int, rows?: int } -> { session_id: int }
  tui_send:     { session_id: int, text?: string, key?: string, mods?: string[] } -> { ok: bool }
  tui_screen:   { session_id: int } -> { text: string, cursor_row: int, cursor_col: int, cols: int, rows: int }
  tui_cell:     { session_id: int, row: int, col: int } -> { char: string, fg: string, bg: string, bold: bool, ... }
  tui_wait:     { session_id: int, text?: string, stable_ms?: int, cursor_row?: int, cursor_col?: int, timeout_ms?: int } -> { matched: bool }
  tui_resize:   { session_id: int, cols: int, rows: int } -> { ok: bool }
  tui_snapshot: { session_id: int, golden_path?: string } -> { text: string, diff?: string }
  tui_stop:     { session_id: int } -> { exit_code?: int }
  ```
- Function: `toolList() []const ToolDef` — return tool definitions for tools/list response
- Each tool has: name, description, inputSchema (JSON Schema)
- Test: Verify tool list serializes correctly.

**Step 6.2.2: tools.dispatch — Route tool calls**
- Function: `dispatch(pool: *SessionPool, alloc: Allocator, tool_name: []const u8, args: JsonValue) !JsonValue`
  - Match tool_name, extract args, call appropriate handler, return result
  - Assertion: tool_name matches a known tool
- Test: Dispatch each tool name with valid args, verify correct handler called.

#### Phase 6.3: Tool Handlers

**Step 6.3.1: tools.handleStart**
- Parse args, create session via pool
- Return session_id
- Test: MCP call with command="echo hello", verify session created.

**Step 6.3.2: tools.handleSend**
- Parse args (text or key+mods), call session.sendText or session.sendKey
- Test: Start session, send text, verify delivery.

**Step 6.3.3: tools.handleScreen**
- Drain session, capture text + cursor
- Return structured response
- Test: Start session with echo, get screen, verify text.

**Step 6.3.4: tools.handleCell**
- Drain session, call screen.cellAt
- Return cell attributes as JSON
- Test: Start session with colored output, get cell, verify color.

**Step 6.3.5: tools.handleWait**
- Parse condition type (text/stable/cursor), call appropriate wait function
- Return matched: true/false
- Test: Start slow program, wait for text, verify match.

**Step 6.3.6: tools.handleResize**
- Call session resize + pty setSize
- Test: Start session, resize, verify new dimensions.

**Step 6.3.7: tools.handleSnapshot**
- Capture snapshot, optionally compare with golden file
- Return text + optional diff
- Test: End-to-end snapshot flow.

**Step 6.3.8: tools.handleStop**
- Destroy session, return exit code
- Test: Start and stop session, verify cleanup.

#### Phase 6.4: Server Loop

**Step 6.4.1: main.zig — MCP server mode**
- Objective: Main event loop reading requests from stdin, dispatching, writing responses
- Loop:
  1. Read request from stdin
  2. Route to handler (initialize, tools/list, tools/call)
  3. Write response to stdout
  4. Repeat until EOF
- **On EOF (client disconnect):** Call `pool.destroyAll()` to clean up all sessions, PTYs, and child processes before exiting. This prevents orphaned processes when an AI agent crashes or disconnects.
- **Session timeout reaping:** On each request, check `last_activity` timestamps. Destroy sessions inactive for >5 minutes (configurable via `tui_start` option). This prevents resource leaks from abandoned sessions.
- Assertion: every request gets exactly one response
- Test: Integration test: pipe JSON requests in, verify JSON responses out.

**Step 6.4.2: main.zig — CLI mode**
- Objective: Direct CLI usage without MCP protocol
- Flags: `tui-test-ghost --cli --command "..." --send "text" --screen --wait-for "text"`
- Simpler interface for shell scripting
- Test: `tui-test-ghost --cli --command "echo hello" --screen` prints screen content.

---

### Milestone 7: Integration and Hardening

**Goal:** End-to-end testing, error handling, documentation.

#### Phase 7.1: Integration Tests

**Step 7.1.1: Test with real TUI — htop**
- Spawn htop (if available), wait for stable, verify screen has CPU/MEM columns
- Tests resize handling, complex escape sequences, alternate screen buffer

**Step 7.1.2: Test with real TUI — vim/nvim**
- Spawn `nvim --clean`, send `:q\n`, verify exit
- Tests alternate screen, cursor positioning, mode switching

**Step 7.1.3: Test with Bubble Tea app**
- If a Bubble Tea example binary is available, test interaction
- Tests modern TUI framework output

**Step 7.1.4: Stress test — rapid input/output**
- Spawn `yes` (infinite output), drain with bounded iterations, verify no hang or OOM
- Spawn `cat`, send 10000 chars rapidly, verify all arrive

#### Phase 7.2: Error Handling

**Step 7.2.1: Handle child crash gracefully**
- Spawn program that segfaults, verify session detects exit, no parent crash
- Test: `kill -SEGV` of child, session reports signaled exit

**Step 7.2.2: Handle PTY EOF**
- Child exits normally, subsequent drain returns eof
- Subsequent sendText returns error (PTY closed)

**Step 7.2.3: Handle invalid MCP requests**
- Malformed JSON, unknown tools, missing args
- Return proper JSON-RPC error responses

#### Phase 7.3: Documentation

**Step 7.3.1: Create START.md**
- Quick start guide: install, run, example MCP session
- Architecture overview diagram

**Step 7.3.2: Create MCP tool documentation**
- Detailed description of each tool with examples
- For inclusion in MCP tool documentation tables

**Step 7.3.3: Update terse-mcp README**
- Add tui-test-ghost to the tool inventory

---

## Execution Guidelines

### For the orchestrating user

1. Execute milestones in order (0 → 7). Phases within a milestone can sometimes parallelize.
2. Each step is assigned to the `tui-test-ghost-implementer` agent with:
   - The step definition from this plan
   - Pointers to all referenced documentation files
   - The current state of the codebase
3. After each step, optionally run `zig-specialist` agent for review.
4. Run `zig build test` after every step. Never proceed with failing tests.
5. Steps that say "Read X carefully" — the agent MUST read those files before writing code.

### For implementation agents

1. **Read before write.** Read all referenced source files before writing any code.
2. **Single function per step.** Do not implement beyond what the step defines.
3. **Tests are mandatory.** Every step has a test specification. Write the test.
4. **TigerStyle is law.** >=2 assertions per function, 70-line limit, no recursion, bounded loops.
5. **Compile-time assertions** for all constant relationships (buffer sizes, max values, enum completeness).
6. **Error wrapping.** All errors returned with context: `return error.PtyOpenFailed`.
7. **No `_` for errors.** If an error truly cannot be handled, comment must explain why.
8. **Run `zig fmt`** after editing .zig files.
9. **Do not guess Ghostty API.** If unsure about a type or function, read the source file. The paths are in the Documentation References table.

### For review agents

1. Check TigerStyle compliance: assertion count, function length, no recursion.
2. Verify paired assertions: definition site AND call site.
3. Check error handling: no ignored errors, all paths covered.
4. Verify bounds: all loops bounded, all buffers bounded, all pools bounded.
5. Check platform assumptions: macOS-specific code marked clearly.
