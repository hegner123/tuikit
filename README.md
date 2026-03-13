# tuikit

A TUI testing toolkit for programmatic interaction with terminal applications. Built in Zig on [Ghostty's](https://github.com/ghostty-org/ghostty) `ghostty-vt` terminal emulation core.

## Quick Start

### Install from release

```bash
# macOS (Apple Silicon)
curl -fsSL https://github.com/hegner123/tuikit/releases/latest/download/tuikit-v0.1.0-macos-aarch64.tar.gz | tar xz
mv tuikit /usr/local/bin/

# Linux (x86_64)
curl -fsSL https://github.com/hegner123/tuikit/releases/latest/download/tuikit-v0.1.0-linux-x86_64.tar.gz | tar xz
mv tuikit /usr/local/bin/
```

### Install from source

Requires [Zig 0.15.1+](https://ziglang.org/download/). Ghostty is fetched automatically.

```bash
git clone https://github.com/hegner123/tuikit.git
cd tuikit
zig build -Doptimize=ReleaseSafe
just install
```

### Add to Claude Code

```bash
claude mcp add tuikit -- tuikit
```

## Usage

### MCP Server

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

## Platforms

- macOS (aarch64, x86_64)
- Linux (x86_64)

## Features

- **Real terminal emulation** — Ghostty's VT parser handles SGR, cursor movement, alternate screen buffer, scrollback
- **PTY-based** — programs run in a real pseudo-terminal, behaving exactly as they would in a real terminal
- **Cell-level inspection** — query individual cell attributes: character, bold, italic, underline, strikethrough, dim, foreground/background color (default, palette, RGB)
- **Wait conditions** — poll until text appears, screen stabilizes, cursor reaches a position, or process exits
- **Golden file snapshots** — capture screen state to disk, diff against a baseline on future runs
- **Session pool** — manage up to 16 concurrent terminal sessions
- **Keyboard input** — send named keys (enter, tab, escape, arrows, F1-F12) with modifier combinations (ctrl, alt, shift)
- **Resize** — change terminal dimensions mid-session, delivering SIGWINCH to the child process

## How It Works

```
TUI Process → PTY → ghostty-vt Terminal Emulator → Screen Query API → MCP / CLI
```

Programs run in a real PTY backed by Ghostty's VT parser, providing accurate screen state including SGR attributes, cursor positioning, and alternate screen buffer support. Single-threaded with explicit drain — the caller controls when PTY output is consumed and fed to the terminal emulator.

## Architecture

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
