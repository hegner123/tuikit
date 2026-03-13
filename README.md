# tuikit

A Zig-native TUI testing toolkit built on [Ghostty's](https://github.com/ghostty-org/ghostty) terminal emulation core. Spawns TUI applications in a virtual terminal (PTY), feeds output through a real VT emulator, and exposes structured screen state for programmatic assertion.

## Features

- Spawn TUI programs in a headless virtual terminal with configurable dimensions
- Send text input and named key presses (with modifier support) to running sessions
- Query full screen content, individual cell attributes (bold, italic, colors), and cursor position
- Wait for conditions: text appearance, screen stability, cursor position, or process exit
- Capture and diff screen snapshots against golden files
- Resize the virtual terminal mid-session
- Manage up to 16 concurrent sessions via a session pool
- Runs as an MCP server (JSON-RPC over stdio) or standalone CLI

## Prerequisites

- [Zig 0.15.1+](https://ziglang.org/download/)
- [Ghostty](https://github.com/ghostty-org/ghostty) source tree (path dependency at `../../ghostty` relative to this project)
- macOS (darwin) — Linux support planned

## Installation

```bash
git clone https://github.com/<owner>/tuikit.git
cd tuikit
zig build
```

Install to `/usr/local/bin`:

```bash
just install
```

## Usage

### MCP Server

```bash
tuikit
```

Starts a JSON-RPC MCP server on stdin/stdout. Available tools:

| Tool | Description |
|------|-------------|
| `tui_start` | Start a TUI program in a virtual terminal |
| `tui_send` | Send text or key input to a session |
| `tui_screen` | Get the current screen content |
| `tui_cell` | Get a single cell's attributes |
| `tui_wait` | Wait for text, stability, cursor position, or exit |
| `tui_resize` | Resize the terminal |
| `tui_snapshot` | Capture or compare a screen snapshot |
| `tui_stop` | Stop a session and get exit code |

### CLI

```bash
tuikit --cli --command htop --screen
tuikit --cli --command vim --send "ihello" --wait-for "hello" --screen
```

## License

MIT License. See [LICENSE](LICENSE).
