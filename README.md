# tuikit

A TUI testing toolkit for programmatic interaction with terminal applications. Built in Zig on [Ghostty's](https://github.com/ghostty-org/ghostty) `ghostty-vt` terminal emulation core.

Developed specifically to test [Bubble Tea](https://github.com/charmbracelet/bubbletea) interfaces agentically — letting AI agents spawn, drive, and assert against TUI applications through MCP without needing a display.

## Platforms

- macOS (aarch64, x86_64)
- Linux (x86_64)

## Quick Start

### Install from release

```bash
# macOS (Apple Silicon)
curl -fsSL https://github.com/hegner123/tuikit/releases/latest/download/tuikit-v0.2.0-macos-aarch64.tar.gz | tar xz
mv tuikit /usr/local/bin/

# Linux (x86_64)
curl -fsSL https://github.com/hegner123/tuikit/releases/latest/download/tuikit-v0.2.0-linux-x86_64.tar.gz | tar xz
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
| `tui_start` | Start a TUI program and return initial screen state. Params: `command` (required), `args`, `cols` (default 80), `rows` (default 24), `region`. Returns `session_id`, `text`, `cursor_row`, `cursor_col`, `cols`, `rows`. |
| `tui_send` | Send input and return screen state. Params: `session_id` (required), `keys` (array of key tokens), `settle_ms` (default 50), `region`. Legacy: `text`, `key`, `mods`. Returns `text`, `cursor_row`, `cursor_col`, `cols`, `rows`. |
| `tui_screen` | Get screen content. Params: `session_id` (required), `region`. Returns `text`, `cursor_row`, `cursor_col`, `cols`, `rows`. |
| `tui_cell` | Inspect a single cell. Params: `session_id`, `row`, `col` (all required). Returns `char`, `bold`, `italic`, `underline`, `strikethrough`, `dim`, `fg`, `bg`. |
| `tui_wait` | Wait for a condition and return screen state. Params: `session_id` (required), plus one of: `text`, `stable_ms`, `cursor_row`+`cursor_col`. Optional `timeout_ms` (default 5000, max 30000), `region`. Returns `matched`, `text`, `cursor_row`, `cursor_col`, `cols`, `rows`. |
| `tui_resize` | Resize terminal and return screen state. Params: `session_id`, `cols`, `rows` (all required), `region`. Returns `text`, `cursor_row`, `cursor_col`, `cols`, `rows`. |
| `tui_snapshot` | Capture screen snapshot. Params: `session_id` (required), `golden_path` (optional — compares against baseline if provided, creates it if missing). |
| `tui_stop` | Stop session and get exit code. Params: `session_id` (required). Returns `exit_code`. |
| `tui_record_start` | Start recording tool calls to a JSONL file. Params: `path` (required). |
| `tui_record_stop` | Stop recording and close the file. No params. |

### Replay

```bash
tuikit replay test.jsonl
```

Replays a recorded JSONL session and reports pass/fail for each entry. Action tools (`tui_start`, `tui_send`, `tui_screen`, `tui_cell`, `tui_resize`) are re-executed without comparison. Assertion tools (`tui_wait`, `tui_stop`, `tui_snapshot`) compare key result fields against the recorded values.

Exits 0 if all assertions pass, 1 if any fail. Single-session recordings only (one `tui_start` per file).

JSONL format — one JSON object per line:

```jsonl
{"tool":"tui_start","args":{"command":"myapp"},"result":{"session_id":0,"text":"..."}}
{"tool":"tui_send","args":{"session_id":0,"keys":["down*3","enter"]},"result":{"text":"..."}}
{"tool":"tui_wait","args":{"session_id":0,"text":"Settings"},"result":{"matched":true,"text":"..."}}
{"tool":"tui_stop","args":{"session_id":0},"result":{"exit_code":0}}
```

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

## Features

- **Real terminal emulation** — Ghostty's VT parser handles SGR, cursor movement, alternate screen buffer, scrollback
- **PTY-based** — programs run in a real pseudo-terminal, behaving exactly as they would in a real terminal
- **Cell-level inspection** — query individual cell attributes: character, bold, italic, underline, strikethrough, dim, foreground/background color (default, palette, RGB)
- **Wait conditions** — poll until text appears, screen stabilizes, cursor reaches a position, or process exits
- **Golden file snapshots** — capture screen state to disk, diff against a baseline on future runs
- **Session pool** — manage up to 16 concurrent terminal sessions
- **Keyboard input** — send named keys (enter, tab, escape, arrows, F1-F12) with modifier combinations (ctrl, alt, shift)
- **Key batching** — send multiple keystrokes in a single MCP call with the `keys` array: `["down*5", "enter"]`
- **Auto-screen** — `tui_start`, `tui_send`, `tui_wait`, and `tui_resize` return screen state in every response
- **Region cropping** — return only a portion of the screen with the `region` parameter to reduce token usage
- **Resize** — change terminal dimensions mid-session, delivering SIGWINCH to the child process
- **Record/replay** — record an agent's MCP tool calls to JSONL, replay them as a repeatable test suite with `tuikit replay`

### Key Token Syntax

The `keys` parameter on `tui_send` accepts an array of string tokens:

| Token | Meaning |
|-------|---------|
| `"enter"` | Single key press |
| `"ctrl+c"` | Modified key (ctrl, alt, shift) |
| `"down*5"` | Repeat key 5 times (max 99) |
| `"ctrl+shift+up"` | Multiple modifiers |
| `"text:hello world"` | Send literal text |
| `"text:*"` | Send literal `*` (since `*` is the repeat operator) |

The `text:` prefix is reserved. Max 64 tokens per call, max 99 repeats.

### Region Parameter

Tools that return screen content accept an optional `region` object to crop the output:

```json
{"region": {"row": 2, "col": 0, "width": 40, "height": 10}}
```

All fields are optional (defaults: row=0, col=0, width=terminal cols, height=terminal rows). Values are clamped to terminal bounds.

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
| `record.zig` | JSONL recorder for tool call capture |
| `replay.zig` | Replay engine: load, execute, compare, report |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT License. See [LICENSE](LICENSE).
