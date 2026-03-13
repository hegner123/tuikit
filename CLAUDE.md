# tuikit — TUI Testing Toolkit

## What This Is

A Zig-native TUI testing toolkit built on Ghostty's `ghostty-vt` terminal emulation core. Tests TUI applications by spawning them in a PTY, feeding output through a real terminal emulator, and exposing structured screen state for programmatic assertion.

## Build Commands

```bash
zig build          # Build library + executable
zig build test     # Run all tests
zig build run      # Run MCP server / CLI
just build         # Same via justfile
just test          # Same via justfile
just fmt           # Run zig fmt
```

## Architecture

See [PLAN.md](PLAN.md) for full architecture, milestones, and step definitions.

**Data flow:** TUI Process → PTY → ReadonlyStream → ghostty-vt Terminal → Screen Query API → MCP/CLI

**Threading:** Single-threaded with explicit drain. No background threads.

## TigerStyle (Mandatory)

Every function in this codebase MUST follow TigerStyle:

1. **>=2 assertions per function** — pre/postconditions, paired at call+definition sites
2. **70-line function limit** — extract helpers, push `if`s up and `for`s down
3. **No recursion** — all iteration via bounded loops
4. **Static allocation** — all memory allocated at init, no dynamic allocation after startup
5. **Explicitly-sized types** — `u16`, `u32`, `u64`, not `usize` (except where Zig stdlib demands it)
6. **Named arguments via options struct** when parameters could be confused
7. **No hidden control flow** — no async callbacks, no background goroutines
8. **All errors handled** — no `_` for errors, wrap with context
9. **Compile-time assertions** for constant relationships
10. **`defer` for postconditions** where applicable

Reference: https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md

## Key Dependencies

| Dependency | Location | What It Provides |
|------------|----------|-----------------|
| ghostty-vt | `/Users/home/Documents/Code/ghostty/` | Terminal emulation core |
| Zig 0.15.2 | `/Users/home/Documents/Code/Zig/0.15.2/` | Compiler + stdlib |

## Documentation for Agents

Before implementing ANY step, agents must read:

- **Step definition** in [PLAN.md](PLAN.md) — what to implement, signature, assertions, test spec
- **Referenced source files** — paths listed in the step's Refs field
- **ai/GHOSTTY_API.md** — extracted Ghostty API reference (once created in Step 0.2.1)

### Key Ghostty Source Files

| File | What It Contains |
|------|-----------------|
| `ghostty/src/terminal/Terminal.zig` | Main terminal type — init, print, resize, plainString |
| `ghostty/src/terminal/stream_readonly.zig` | ReadonlyStream — headless VT byte processing |
| `ghostty/src/terminal/page.zig` | Cell, Row, Page types — screen grid structure |
| `ghostty/src/terminal/style.zig` | Style type — colors, bold, italic, underline |
| `ghostty/src/terminal/Screen.zig` | Screen type — cursor, selection, page navigation |
| `ghostty/src/terminal/color.zig` | Color types — palette, RGB, named colors |
| `ghostty/src/terminal/sgr.zig` | SGR attribute parsing |
| `ghostty/src/pty.zig` | PTY open/close/resize (platform-specific) |
| `ghostty/src/Command.zig` | Fork/exec pattern |
| `ghostty/example/zig-vt/` | Example: how to use ghostty-vt as dependency |
| `ghostty/test/fuzz-libghostty/fuzz_stream.zig` | Example: headless terminal usage |

### Zig Stdlib Documentation

Located at `~/.claude/zig/`:
- `MEM_DOCUMENTATION.md` — std.mem module
- `IO_DOCUMENTATION.md` — std.io module
- `HEAP_DOCUMENTATION.md` — std.heap module
- `FMT_DOCUMENTATION.md` — std.fmt module
- `JSON_DOCUMENTATION.md` — std.json module
- `FS_DOCUMENTATION.md` — std.fs module

Full stdlib source: `/Users/home/Documents/Code/Zig/0.15.2/lib/zig/std/`

## Development Workflow

1. Check current milestone/phase/step in PLAN.md
2. Read all referenced documentation
3. Implement the single function defined in the step
4. Write the test defined in the step
5. Run `zig build test` — must pass
6. Run `zig fmt src/` — must be clean
7. Proceed to next step only after passing

## Platform

- macOS first (darwin). Linux support planned but not in initial milestones.
- Links libc (required for `openpty()` and Ghostty SIMD).

## Agents

| Agent | File | When to Use |
|-------|------|-------------|
| `tuikit-implementer` | `~/.claude/agents-mh/tuikit-implementer.md` | Primary: implementing plan steps (reads step def, loads refs, implements, tests) |
| `zig-tiger-style-developer` | `~/.claude/agents-mh/zig-tiger-style-developer.md` | Fallback: general Zig implementation outside the plan |
| `zig-specialist` | `~/.claude/agents-mh/zig-specialist.md` | Reviewing completed steps |

## Critical API Notes (from skeptic review)

- **Ghostty API is alpha.** Always verify signatures against source before implementing. Do not trust PLAN.md signatures blindly.
- **Terminal.init Options:** `cols`/`rows` are `size.CellCountInt` (u16), `max_scrollback` is `usize`
- **Terminal.resize:** Takes separate `cols, rows` args, NOT an options struct
- **IUTF8:** Set on master fd, not slave (see Ghostty pty.zig:161-166)
- **Post-fork:** Zero allocation between fork and exec. Use `posix.exit()` not `return` in child. Async-signal-safe calls only.
- **Key encoding:** Use Ghostty's exported `input.encodeKey`, do not hand-roll
- **Screen queries:** Always use `terminal.inner.screens.active` (handles alternate screen buffer)
- **SessionPool:** Must be heap-allocated (1MB+ inline buffers exceed safe stack size)
