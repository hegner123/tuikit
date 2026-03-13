# tuikit

A TUI testing toolkit that lets AI agents and scripts interact with terminal applications programmatically. Built in Zig on [Ghostty's](https://github.com/ghostty-org/ghostty) `ghostty-vt` terminal emulation core — the same VT parser that powers the Ghostty terminal emulator.

tuikit spawns TUI programs inside a real PTY with a real terminal emulator, not a mock. Screen state is always accurate because bytes flow through the same VT processing pipeline that a real terminal uses.

## How It Works

```
TUI Process → PTY → ghostty-vt Terminal Emulator → Screen Query API → MCP / CLI
```

1. A TUI program (htop, vim, your app) runs in a PTY
2. Its output feeds through Ghostty's VT parser — SGR attributes, cursor movement, alternate screen, all of it
3. The resulting screen state is queryable: full text, individual cell attributes, cursor position
4. Input goes back through the PTY: text, key presses with modifiers, resize events

No screen scraping. No regex on ANSI escape codes. The terminal emulator does the parsing.

## Features

- **Real terminal emulation** — Ghostty's VT parser handles SGR, cursor movement, alternate screen buffer, scrollback
- **PTY-based** — programs run in a real pseudo-terminal, not a pipe, so they behave exactly as they would in a real terminal
- **Cell-level inspection** — query individual cell attributes: character, bold, italic, underline, strikethrough, dim, foreground/background color (default, palette, RGB)
- **Wait conditions** — poll until text appears, screen stabilizes, cursor reaches a position, or process exits
- **Golden file snapshots** — capture screen state to disk, diff against a baseline on future runs
- **Session pool** — manage up to 16 concurrent terminal sessions
- **Keyboard input** — send named keys (enter, tab, escape, arrows, F1-F12) with modifier combinations (ctrl, alt, shift)
- **Resize** — change terminal dimensions mid-session, delivering SIGWINCH to the child process
- **MCP server** — JSON-RPC over stdio, compatible with Claude Code and other MCP clients
- **CLI mode** — standalone command-line interface for scripting

## Platforms

- macOS (aarch64, x86_64)
- Linux (x86_64)

## Prerequisites

- [Zig 0.15.1+](https://ziglang.org/download/)

Ghostty is fetched automatically by the Zig build system.

## Installation

### From release binaries

Download the latest release from the [releases page](https://github.com/hegner123/tuikit/releases) and extract the binary:

```bash
tar xzf tuikit-v0.1.0-macos-aarch64.tar.gz
mv tuikit /usr/local/bin/
```

### From source

```bash
git clone https://github.com/hegner123/tuikit.git
cd tuikit
zig build -Doptimize=ReleaseSafe
```

Install to `/usr/local/bin`:

```bash
just install
```

## Usage

### MCP Server

Add to Claude Code:

```bash
claude mcp add tuikit -- tuikit
```

Or run directly:

```bash
tuikit
```

Starts a JSON-RPC MCP server on stdin/stdout with these tools:

| Tool | Description |
|------|-------------|
| `tui_start` | Start a TUI program in a virtual terminal. Params: `command` (required), `args`, `cols` (default 80), `rows` (default 24). Returns `session_id`. |
| `tui_send` | Send input to a session. Params: `session_id` (required), `text`, `key` (named key), `mods` (array of ctrl/alt/shift). |
| `tui_screen` | Get screen content. Params: `session_id` (required). Returns `text`, `cursor_row`, `cursor_col`, `cols`, `rows`. |
| `tui_cell` | Inspect a single cell. Params: `session_id`, `row`, `col` (all required). Returns `char`, `bold`, `italic`, `underline`, `strikethrough`, `dim`, `fg`, `bg`. |
| `tui_wait` | Wait for a condition. Params: `session_id` (required), plus one of: `text`, `stable_ms`, `cursor_row`+`cursor_col`. Optional `timeout_ms` (default 5000, max 30000). |
| `tui_resize` | Resize terminal. Params: `session_id`, `cols`, `rows` (all required). Sends SIGWINCH to child. |
| `tui_snapshot` | Capture screen snapshot. Params: `session_id` (required), `golden_path` (optional — compares against baseline if provided, creates it if missing). |
| `tui_stop` | Stop session and get exit code. Params: `session_id` (required). Returns `exit_code`. |

### CLI

```bash
tuikit --cli --command htop --screen
tuikit --cli --command vim --send "ihello" --wait-for "hello" --screen
```

| Flag | Description |
|------|-------------|
| `--command <cmd>` | Program to run (required) |
| `--send <text>` | Text to send to stdin |
| `--wait-for <text>` | Wait until text appears on screen (5s timeout) |
| `--screen` | Print screen content to stdout |

## Architecture

Single-threaded with explicit drain — no background threads. The caller controls when PTY output is consumed and fed to the terminal emulator.

Key modules:

| Module | Purpose |
|--------|---------|
| `Pty.zig` | PTY open/close/read/write/poll/resize |
| `Process.zig` | Fork/exec, signal handling, wait |
| `Terminal.zig` | Wrapper around ghostty-vt Terminal |
| `Session.zig` | Combines PTY + Process + Terminal into a test session |
| `SessionPool.zig` | Fixed-size pool of up to 16 sessions |
| `screen.zig` | Screen queries: plaintext, cell attributes, cursor position |
| `wait.zig` | Polling wait conditions with timeout |
| `snapshot.zig` | Capture, save, load, and diff screen snapshots |
| `input.zig` | Key encoding using Ghostty's input system |
| `mcp.zig` | JSON-RPC message parsing and serialization |
| `tools.zig` | MCP tool definitions, dispatch, and handlers |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT License. See [LICENSE](LICENSE).
