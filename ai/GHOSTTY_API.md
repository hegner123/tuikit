# ghostty-vt API Reference for tui-test-ghost

**WARNING:** The ghostty-vt API is alpha and not guaranteed to be stable. Always verify signatures against source before implementing. Do not trust this document blindly.

**Extracted from Ghostty commit:** `d4019fa484c821b8d3a1ef73d42357ae8d86f2b7`

**Import path:** `@import("ghostty-vt")`

---

## Public Re-exports from lib_vt.zig

Everything below is available via `@import("ghostty-vt")`. The most relevant types for tui-test-ghost:

| Export | Type | Source |
|--------|------|--------|
| `Terminal` | struct | `terminal/Terminal.zig` |
| `Screen` | struct | `terminal/Screen.zig` |
| `ScreenSet` | struct | `terminal/ScreenSet.zig` |
| `ReadonlyStream` | `stream.Stream(ReadonlyHandler)` | `terminal/stream_readonly.zig` |
| `ReadonlyHandler` | struct | `terminal/stream_readonly.zig` |
| `Cell` | `packed struct(u64)` | `terminal/page.zig` |
| `Page` | struct | `terminal/page.zig` |
| `PageList` | struct | `terminal/PageList.zig` |
| `Pin` | `PageList.Pin` | `terminal/PageList.zig` |
| `Style` | struct | `terminal/style.zig` |
| `Attribute` | tagged union | `terminal/sgr.zig` (via `Attribute = terminal.Attribute`) |
| `Cursor` | `Screen.Cursor` | `terminal/Screen.zig` |
| `CursorStyle` | `Screen.CursorStyle` | `terminal/cursor.zig` |
| `Selection` | struct | `terminal/Selection.zig` |
| `Point` | struct | `terminal/point.zig` |
| `Coordinate` | struct | `terminal/point.zig` |
| `Mode` | enum | `terminal/modes.zig` |
| `ModePacked` | packed struct | `terminal/modes.zig` |
| `EraseDisplay` | enum | terminal |
| `EraseLine` | enum | terminal |

**Namespace re-exports** (access as e.g. `vt.color`, `vt.page`, `vt.sgr`):

`apc`, `dcs`, `osc`, `point`, `color`, `device_status`, `formatter`, `highlight`, `kitty`, `modes`, `page`, `parse_table`, `search`, `sgr`, `size`, `x11_color`

**Input encoding** (access as `vt.input`):

| Export | Type |
|--------|------|
| `input.Key` | key enum |
| `input.KeyAction` | action enum |
| `input.KeyEvent` | event struct |
| `input.KeyMods` | modifier flags |
| `input.KeyEncodeOptions` | options struct |
| `input.encodeKey` | `fn(*std.Io.Writer, KeyEvent, Options) !void` |

---

## Terminal

**Source:** `terminal/Terminal.zig`

The primary terminal emulation structure. Contains the screen grid, scrollback buffer, modes, and cursor state.

### Key Fields

| Field | Type | Notes |
|-------|------|-------|
| `screens` | `ScreenSet` | Primary + alternate screen. Access active screen via `screens.active` |
| `rows` | `size.CellCountInt` (u16) | Current row count |
| `cols` | `size.CellCountInt` (u16) | Current column count |
| `modes` | `modespkg.ModeState` | Terminal mode flags (wraparound, origin, etc.) |
| `scrolling_region` | `ScrollingRegion` | Current scroll region (top, bottom, left, right -- all u16) |
| `colors` | `Colors` | Foreground, background, cursor, palette colors |
| `flags` | packed struct | Mouse state, dirty flags, focus, etc. |

### Options (for init)

```zig
pub const Options = struct {
    cols: size.CellCountInt,      // u16
    rows: size.CellCountInt,      // u16
    max_scrollback: usize = 10_000,
    colors: Colors = .default,
    default_modes: modespkg.ModePacked = .{},
};
```

### Key Methods

```zig
pub fn init(alloc: Allocator, opts: Options) !Terminal
pub fn deinit(self: *Terminal, alloc: Allocator) void

/// Returns a ReadonlyStream that processes VT byte sequences and updates terminal state.
/// Ignores query/response sequences (device attributes, cursor position reports, etc.).
pub fn vtStream(self: *Terminal) ReadonlyStream

/// Print UTF-8 encoded string directly to terminal (bypasses VT parsing).
pub fn printString(self: *Terminal, str: []const u8) !void

/// Return the visible screen content as a plain string. Caller must free.
pub fn plainString(self: *Terminal, alloc: Allocator) ![]const u8

/// Resize the terminal. Takes separate cols, rows args (NOT an options struct).
pub fn resize(self: *Terminal, alloc: Allocator, cols: size.CellCountInt, rows: size.CellCountInt) !void

/// Set an SGR attribute on the current cursor style.
pub fn setAttribute(self: *Terminal, attr: sgr.Attribute) !void

/// Set cursor position. Row and col are 1-based (VT convention).
pub fn setCursorPos(self: *Terminal, row_req: usize, col_req: usize) void

/// Full terminal reset (RIS). Switches to primary screen, resets modes, cursor, scrolling region.
pub fn fullReset(self: *Terminal) void
```

### Usage Pattern for tui-test-ghost

```zig
const vt = @import("ghostty-vt");

// Create terminal
var term: vt.Terminal = try .init(allocator, .{ .cols = 80, .rows = 24 });
defer term.deinit(allocator);

// Create stream for processing VT output
var stream: vt.ReadonlyStream = .initAlloc(allocator, .init(&term));
defer stream.deinit();

// Feed bytes from PTY into stream
try stream.nextSlice(pty_output_bytes);

// Read screen state
const text = try term.plainString(allocator);
defer allocator.free(text);

// Access cursor
const x = term.screens.active.cursor.x;
const y = term.screens.active.cursor.y;
```

---

## ReadonlyStream

**Source:** `terminal/stream_readonly.zig`

A VT stream processor that updates terminal state from byte sequences. Called "readonly" because it only processes state-modifying actions, ignoring queries that require responses (device attributes, cursor position reports, etc.). This is the correct stream type for tui-test-ghost since we only render output and never respond.

`ReadonlyStream` is `stream.Stream(ReadonlyHandler)`.

### Construction

```zig
// From a Terminal (preferred):
var stream = term.vtStream();

// Or manually:
var stream: ReadonlyStream = .initAlloc(allocator, .init(&term));
defer stream.deinit();
```

### Key Methods

```zig
/// Process a slice of VT byte data, updating the terminal state.
pub fn nextSlice(self: *Self, input: []const u8) !void

pub fn deinit(self: *Self) void
```

### What It Handles

The ReadonlyHandler processes: print, cursor movement, erase operations, scroll, mode set/reset, SGR attributes, charset, alt screen switching, semantic prompts, color operations, full reset, and more.

It ignores: bell, enquiry, device attributes, device status, cursor position reports, clipboard contents, window title reporting, and other query/response sequences.

---

## Screen

**Source:** `terminal/Screen.zig`

Represents one screen buffer (primary or alternate). Access via `terminal.screens.active`.

### Key Fields

| Field | Type | Notes |
|-------|------|-------|
| `alloc` | `Allocator` | Allocator used by this screen |
| `pages` | `PageList` | The list of pages backing the screen |
| `cursor` | `Cursor` | Current cursor position and state |
| `selection` | `?Selection` | Current text selection, if any |
| `kitty_keyboard` | `kitty.KeyFlagStack` | Kitty keyboard protocol state |

### Cursor

```zig
pub const Cursor = struct {
    x: size.CellCountInt = 0,           // u16, column position
    y: size.CellCountInt = 0,           // u16, row position within active area
    cursor_style: CursorStyle = .block,  // block, bar, underline
    pending_wrap: bool = false,          // "last column flag" -- next print forces soft-wrap
    protected: bool = false,             // protected mode for new chars
    style: style.Style = .{},           // active style (concrete value)
    style_id: style.Id = 0,            // style ID for cell writing (0 = default)
    semantic_content: Cell.SemanticContent = .output,  // output, input, or prompt
    page_pin: *PageList.Pin,            // pin into page list
    page_row: *pagepkg.Row,            // pointer to current row
    page_cell: *pagepkg.Cell,          // pointer to current cell
};
```

### CursorStyle

```zig
pub const CursorStyle = enum { block, bar, underline };
```

### Key Methods

```zig
/// Dump visible screen content as string.
pub fn dumpStringAlloc(self: *const Screen, alloc: Allocator, tl: point.Point) ![]const u8
```

---

## ScreenSet

**Source:** `terminal/ScreenSet.zig`

Manages primary and alternate screens.

### Key Fields and Methods

```zig
pub const Key = enum(u1) { primary, alternate };

active_key: Key,       // which screen is active
active: *Screen,       // pointer to active screen

pub fn get(self: *const ScreenSet, key: Key) ?*Screen
pub fn switchTo(self: *ScreenSet, key: Key) void
```

### Usage

```zig
// Access active screen
const screen = terminal.screens.active;

// Check which screen is active
if (terminal.screens.active_key == .alternate) { ... }
```

---

## Cell

**Source:** `terminal/page.zig`

A single terminal grid cell. Packed into 64 bits.

### Fields

| Field | Type | Notes |
|-------|------|-------|
| `content_tag` | `ContentTag` (u2) | Discriminator for content union |
| `content` | packed union | `.codepoint` (u21), `.color_palette` (u8), `.color_rgb` (Cell.RGB) |
| `style_id` | `StyleId` (u16) | Style lookup ID. 0 = default style |
| `wide` | `Wide` (u2) | `.narrow`, `.wide`, `.spacer_tail`, `.spacer_head` |
| `protected` | bool | Protected mode flag |
| `hyperlink` | bool | Whether cell is a hyperlink |
| `semantic_content` | `SemanticContent` (u2) | `.output`, `.input`, `.prompt` |

### ContentTag

```zig
pub const ContentTag = enum(u2) {
    codepoint = 0,          // single codepoint (0 = empty cell)
    codepoint_grapheme = 1, // multi-codepoint grapheme cluster
    bg_color_palette = 2,   // empty cell with palette background
    bg_color_rgb = 3,       // empty cell with RGB background
};
```

### Wide

```zig
pub const Wide = enum(u2) {
    narrow = 0,       // normal width cell
    wide = 1,         // wide character (occupies 2 cells)
    spacer_tail = 2,  // spacer after wide character
    spacer_head = 3,  // spacer at end of soft-wrapped line for wide char continuation
};
```

### Key Methods

```zig
pub fn init(cp: u21) Cell                    // create cell with codepoint
pub fn isZero(self: Cell) bool               // true if cell is zeroed (empty)
pub fn hasText(self: Cell) bool              // true if cell has renderable text
pub fn codepoint(self: Cell) u21             // get the codepoint (0 for bg-only cells)
pub fn gridWidth(self: Cell) u2              // 1 for narrow/spacer, 2 for wide
pub fn hasStyling(self: Cell) bool           // true if style_id != 0
pub fn isEmpty(self: Cell) bool              // no text and no styling
pub fn hasGrapheme(self: Cell) bool          // true if multi-codepoint grapheme
```

---

## Row

**Source:** `terminal/page.zig`

A terminal grid row. Packed into 64 bits.

### Fields

| Field | Type | Notes |
|-------|------|-------|
| `cells` | `Offset(Cell)` | Offset to this row's cell array in the page |
| `wrap` | bool | Row is soft-wrapped (continues on next row) |
| `wrap_continuation` | bool | Row is continuation of previous soft-wrapped row |
| `grapheme` | bool | Any cell has multi-codepoint grapheme data |
| `styled` | bool | Any cell has non-default style (may have false positives) |
| `hyperlink` | bool | Any cell is a hyperlink (may have false positives) |
| `semantic_prompt` | `SemanticPrompt` (u2) | `.none`, `.prompt`, `.prompt_continuation` |
| `dirty` | bool | Row needs redraw |

---

## Style

**Source:** `terminal/style.zig`

Style attributes for a cell. Looked up from a page's style set using `cell.style_id`.

### Fields

```zig
pub const Style = struct {
    fg_color: Color = .none,
    bg_color: Color = .none,
    underline_color: Color = .none,
    flags: Flags = .{},
};
```

### Flags

```zig
const Flags = packed struct(u16) {
    bold: bool = false,
    italic: bool = false,
    faint: bool = false,
    blink: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
    overline: bool = false,
    underline: sgr.Attribute.Underline = .none,  // none, single, double, curly, dotted, dashed
};
```

### Style.Color

```zig
pub const Color = union(Tag) {
    none: void,
    palette: u8,       // 256-color palette index
    rgb: color.RGB,    // direct RGB color

    pub fn eql(self: Color, other: Color) bool
};
```

### Looking Up a Cell's Style

To get the concrete `Style` for a cell with a non-default `style_id`, look it up from the page's style set:

```zig
const cell: *Cell = ...;
if (cell.style_id != 0) {
    const sty = page.styles.get(page.memory, cell.style_id);
    // sty is a Style struct with fg_color, bg_color, flags, etc.
}
```

### Key Methods

```zig
pub fn default(self: Style) bool              // true if style equals default
pub fn eql(self: Style, other: Style) bool    // equality check
```

---

## color.RGB

**Source:** `terminal/color.zig`

```zig
pub const RGB = packed struct(u24) {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
};
```

### color.Name

Standard 8/16 color palette names:

```zig
pub const Name = enum(u8) {
    black = 0, red = 1, green = 2, yellow = 3,
    blue = 4, magenta = 5, cyan = 6, white = 7,
    bright_black = 8, bright_red = 9, bright_green = 10, bright_yellow = 11,
    bright_blue = 12, bright_magenta = 13, bright_cyan = 14, bright_white = 15,
    _, // remaining 256-color palette values
};
```

### color.Palette

`pub const Palette = [256]RGB;`

---

## SGR Attributes

**Source:** `terminal/sgr.zig`

The `Attribute` tagged union represents parsed SGR (Select Graphic Rendition) parameters. Used with `Terminal.setAttribute()`.

### Key Variants

```
unset                    -- reset all attributes (SGR 0)
bold / reset_bold
italic / reset_italic
faint
underline: Underline     -- none, single, double, curly, dotted, dashed
underline_color: RGB
blink / reset_blink
inverse / reset_inverse
invisible / reset_invisible
strikethrough / reset_strikethrough
overline / reset_overline
direct_color_fg: RGB     -- SGR 38;2;r;g;b
direct_color_bg: RGB     -- SGR 48;2;r;g;b
@"8_fg": Name            -- SGR 30-37
@"8_bg": Name            -- SGR 40-47
@"256_fg": u8            -- SGR 38;5;n
@"256_bg": u8            -- SGR 48;5;n
reset_fg / reset_bg
unknown: Unknown
```

---

## size.CellCountInt

**Source:** `terminal/size.zig`

```zig
pub const CellCountInt = u16;
```

This is the integer type used for row/column counts and positions throughout the terminal. All terminal dimensions (cols, rows, cursor x/y, scrolling region bounds) use this type.

---

## Key Encoding (input)

**Source:** `input/key_encode.zig`

Use `vt.input.encodeKey` to encode key events into the terminal's expected format (legacy or Kitty protocol).

```zig
pub fn encode(
    writer: *std.Io.Writer,
    event: key.KeyEvent,
    opts: Options,
) std.Io.Writer.Error!void
```

### Options

```zig
pub const Options = struct {
    cursor_key_application: bool = false,
    keypad_key_application: bool = false,
    ignore_keypad_with_numlock: bool = false,
    alt_esc_prefix: bool = false,
    modify_other_keys_state_2: bool = false,
    kitty_flags: KittyFlags = .disabled,
    macos_option_as_alt: OptionAsAlt = .false,

    /// Initialize from terminal state (does not set macos_option_as_alt).
    pub fn fromTerminal(t: *const Terminal) Options
};
```

### Usage for tui-test-ghost

```zig
// Build key encoding options from terminal state
var opts: vt.input.KeyEncodeOptions = .fromTerminal(&terminal);
opts.macos_option_as_alt = .false; // set manually if needed

// Encode a key event to bytes
var buf: [64]u8 = undefined;
var fbs = std.io.fixedBufferStream(&buf);
try vt.input.encodeKey(&fbs.writer(), key_event, opts);
const encoded = fbs.getWritten();
// Write `encoded` to PTY master fd
```

---

## PageList Cell Access

**Source:** `terminal/PageList.zig`

To access individual cells by screen coordinate:

```zig
pub fn getCell(self: *const PageList, pt: point.Point) ?Cell
```

The returned `Cell` struct contains `.node`, `.row`, `.cell`, `.row_idx`, `.col_idx`.

### Usage

```zig
const cell_info = terminal.screens.active.pages.getCell(.{ .viewport = .{ .x = col, .y = row } });
if (cell_info) |c| {
    const cell: *pagepkg.Cell = c.cell;
    const cp = cell.codepoint();
    // ...
}
```

---

## Critical Notes for tui-test-ghost Implementers

1. **Terminal.init Options:** `cols`/`rows` are `size.CellCountInt` (u16), `max_scrollback` is `usize`.

2. **Terminal.resize:** Takes separate `cols, rows` args, NOT an options struct. Signature: `resize(self, alloc, cols, rows)`.

3. **Screen access:** Always use `terminal.screens.active` to get the current screen. This handles alternate screen buffer correctly.

4. **Style lookup:** Cell `style_id` of 0 means default style (no lookup needed). Non-zero IDs must be looked up from the page's style set.

5. **ReadonlyStream is the right choice:** It processes all state-modifying VT sequences while ignoring query sequences that would need PTY responses. This is exactly what tui-test-ghost needs for headless terminal emulation.

6. **Allocator for ReadonlyStream:** Use `.initAlloc()` (not `.init()`) to enable OSC parsing which requires allocation.

7. **Cell is packed 64-bit:** Do not store pointers to cells across operations that may trigger page reallocation. Always re-fetch cell pointers after any terminal mutation.
