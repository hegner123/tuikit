# tuikit — Quick Start

## What It Is

A Zig-native TUI testing toolkit that spawns programs in a PTY, feeds output through Ghostty's terminal emulator, and exposes structured screen state. Available as both a Zig library and an MCP server.

## Prerequisites

- Zig 0.15.2
- Ghostty source at `/Users/home/Documents/Code/ghostty/` (for `ghostty-vt` dependency)
- macOS (Linux planned)

## Build & Test

```bash
zig build          # Build library + executable
zig build test     # Run all tests (~90 tests)
zig build run      # Run MCP server (stdin/stdout JSON-RPC)
```

## Architecture

```
[TUI Process] <--PTY--> [Session]
                            |
                            v  raw bytes
                    [ghostty-vt Terminal]
                            |
                            v  structured state
                       [Screen API]
                            |
                +-----------+-----------+
                |                       |
           [MCP Server]           [Zig Library]
         (JSON-RPC stdio)       (direct import)
```

**Data flow:** Process spawns on PTY slave fd. Master fd output drains into Ghostty terminal emulator. Screen queries read the emulated terminal state.

**Threading:** Single-threaded, explicit drain. No background threads.

## MCP Server Usage

The executable runs as an MCP server by default (stdio transport):

```json
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"tui_start","arguments":{"command":"htop"}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"tui_screen","arguments":{"session_id":0}}}
{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"tui_stop","arguments":{"session_id":0}}}
```

## CLI Mode

```bash
zig build run -- --cli --command htop --screen
zig build run -- --cli --command "cat" --send "hello" --wait-for "hello" --screen
```

## Zig Library Usage

```zig
const tuikit = @import("tuikit");

var sess = try tuikit.Session.create(allocator, 0, .{
    .argv = &[_][]const u8{"htop"},
});
defer sess.destroy();

_ = sess.drainFor(2000);
const text = try sess.getScreen(allocator);
defer allocator.free(text);
```

## Key Modules

| Module | Purpose |
|--------|---------|
| `Session.zig` | Core: PTY + Process + Terminal combined |
| `SessionPool.zig` | Pool of up to 16 concurrent sessions |
| `Terminal.zig` | Ghostty terminal wrapper |
| `Pty.zig` | PTY open/close/read/write/poll |
| `Process.zig` | Fork/exec process management |
| `screen.zig` | Cell queries, text search, region extraction |
| `wait.zig` | Polling wait conditions (text, stable, cursor, exit) |
| `input.zig` | Key encoding via Ghostty encoder |
| `snapshot.zig` | Screen capture, diff, golden file testing |
| `mcp.zig` | JSON-RPC message handling |
| `tools.zig` | MCP tool definitions and dispatch |

## MCP Tools

| Tool | Description |
|------|-------------|
| `tui_start` | Start a TUI session with a command |
| `tui_send` | Send text or keys to a session |
| `tui_screen` | Get current screen text |
| `tui_cell` | Inspect a single cell (char, color, style) |
| `tui_wait` | Wait for text, stability, cursor position, or exit |
| `tui_resize` | Resize the terminal |
| `tui_snapshot` | Capture or compare screen snapshots |
| `tui_stop` | Stop a session |

## TigerStyle

All code follows TigerStyle: >=2 assertions per function, 70-line limit, no recursion, static allocation, explicit error handling.
