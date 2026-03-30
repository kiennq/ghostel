# Ghostel

Emacs terminal emulator powered by [libghostty-vt](https://ghostty.org/) — the
same VT engine that drives the Ghostty terminal.

Ghostel is inspired by
[emacs-libvterm](https://github.com/akermu/emacs-libvterm): a native dynamic
module handles terminal state and rendering, while Elisp manages the shell
process, keymap, and buffer.

## Requirements

- Emacs 25.1+ with dynamic module support
- [Zig](https://ziglang.org/) 0.14+
- macOS or Linux

## Building

```sh
# Clone with submodule
git clone --recurse-submodules https://github.com/dakra/ghostel.git
cd ghostel

# Build everything (libghostty-vt + ghostel module)
./build.sh
```

If you already have the repo, initialize the submodule and build:

```sh
git submodule update --init vendor/ghostty
./build.sh
```

## Installation

Add to your Emacs config:

```elisp
(add-to-list 'load-path "/path/to/ghostel")
(require 'ghostel)
```

Then `M-x ghostel` to open a terminal.

## Shell Integration

For directory tracking and other features, source the appropriate shell
integration script. Ghostel sets `INSIDE_EMACS=ghostel` and
`EMACS_GHOSTEL_PATH` in the shell environment.

**bash** — add to `~/.bashrc`:
```bash
[[ "$INSIDE_EMACS" = 'ghostel' ]] && source "$EMACS_GHOSTEL_PATH/etc/ghostel.bash"
```

**zsh** — add to `~/.zshrc`:
```zsh
[[ "$INSIDE_EMACS" = 'ghostel' ]] && source "$EMACS_GHOSTEL_PATH/etc/ghostel.zsh"
```

**fish** — add to `~/.config/fish/config.fish`:
```fish
test "$INSIDE_EMACS" = 'ghostel'; and source "$EMACS_GHOSTEL_PATH/etc/ghostel.fish"
```

## Key Bindings

### Terminal mode

| Key         | Action                                 |
|-------------|----------------------------------------|
| Most keys   | Sent directly to the terminal          |
| `C-c C-c`   | Send interrupt (C-c)                   |
| `C-c C-z`   | Send suspend (C-z)                     |
| `C-c C-d`   | Send EOF (C-d)                         |
| `C-c C-\`   | Send quit (C-\)                        |
| `C-c C-k`   | Enter copy mode                        |
| `C-y`       | Yank from kill ring (bracketed paste)  |
| `M-y`       | Yank-pop (cycle through kill ring)     |
| `C-c C-y`   | Paste from kill ring                   |
| `C-c C-l`   | Clear scrollback                       |
| `C-c C-q`   | Send next key literally (escape hatch) |
| Mouse wheel | Scroll through scrollback              |

Keys listed in `ghostel-keymap-exceptions` (default: `C-c`, `C-x`, `C-u`,
`C-h`, `C-g`, `M-x`, `M-o`, `M-:`, `C-\`) pass through to Emacs.

### Copy mode

Enter with `C-c C-k`. Standard Emacs navigation works.

| Key           | Action                  |
|---------------|-------------------------|
| `C-SPC`       | Set mark                |
| `M-w` / `C-w` | Copy selection and exit |
| `q`           | Exit without copying    |

Soft-wrapped newlines are automatically stripped from copied text.

## Features

### Terminal Emulation
- Full VT terminal emulation via libghostty-vt
- 256-color and RGB color support
- Text attributes: bold, italic, faint, underline (single/double/curly/dotted/dashed with color), strikethrough, inverse
- Cursor styles: block, bar, underline, hollow block
- Alternate screen buffer (for TUI apps like htop, vim, etc.)
- Scrollback buffer (configurable, default 10,000 lines)

### Rendering
- Incremental redraw — only dirty rows are re-rendered
- Timer-based batched updates (~30fps) to avoid flicker
- Cursor position updates even without cell changes

### Input
- Full keyboard input with GhosttyKeyEncoder (respects terminal modes)
- Mouse tracking with GhosttyMouseEncoder (press, release, drag)
- Focus events gated by DEC mode 1004
- Bracketed paste
- Drag-and-drop (file paths and text)

### Shell Integration
- Directory tracking via OSC 7
- Title tracking (buffer renamed from OSC 2)
- OSC 52 clipboard support (opt-in, for remote sessions)
- `INSIDE_EMACS` and `EMACS_GHOSTEL_PATH` environment variables

### Color Palette

The 16 ANSI colors are defined as Emacs faces inheriting from `term-color-*`:

```
ghostel-color-black         ghostel-color-bright-black
ghostel-color-red           ghostel-color-bright-red
ghostel-color-green         ghostel-color-bright-green
ghostel-color-yellow        ghostel-color-bright-yellow
ghostel-color-blue          ghostel-color-bright-blue
ghostel-color-magenta       ghostel-color-bright-magenta
ghostel-color-cyan          ghostel-color-bright-cyan
ghostel-color-white         ghostel-color-bright-white
```

Themes that customize `term-color-*` faces automatically apply. Customize
individual faces with `M-x customize-face`.

## Configuration

| Variable                      | Default             | Description                            |
|-------------------------------|---------------------|----------------------------------------|
| `ghostel-shell`               | `$SHELL`            | Shell program to run                   |
| `ghostel-buffer-name`         | `"*ghostel*"`       | Default buffer name                    |
| `ghostel-max-scrollback`      | `10000`             | Maximum scrollback lines               |
| `ghostel-timer-delay`         | `0.033`             | Redraw delay in seconds (~30fps)       |
| `ghostel-kill-buffer-on-exit` | `t`                 | Kill buffer when shell exits           |
| `ghostel-enable-osc52`        | `nil`               | Allow apps to set clipboard via OSC 52 |
| `ghostel-keymap-exceptions`   | `("C-c" "C-x" ...)` | Keys passed through to Emacs           |
| `ghostel-exit-functions`      | `nil`               | Hook run when the shell process exits  |

## Commands

| Command                        | Description                           |
|--------------------------------|---------------------------------------|
| `M-x ghostel`                  | Open a new terminal                   |
| `M-x ghostel-other`            | Switch to next terminal or create one |
| `M-x ghostel-clear`            | Clear screen and scrollback           |
| `M-x ghostel-clear-scrollback` | Clear scrollback only                 |
| `M-x ghostel-copy-mode`        | Enter copy mode                       |
| `M-x ghostel-paste`            | Paste from kill ring                  |
| `M-x ghostel-send-next-key`    | Send next key literally               |
| `M-x ghostel-force-redraw`     | Force a full terminal redraw          |

## Running Tests

```sh
emacs --batch -Q -L . -l test/ghostel-test.el -f ghostel-test-run
```

## Architecture

```
ghostel.el          Elisp: keymap, process management, mode, commands
src/module.zig      Entry point: emacs_module_init, function registration
src/terminal.zig    Terminal struct wrapping ghostty handles
src/render.zig      RenderState → Emacs buffer with styled text
src/input.zig       Key and mouse encoding via ghostty encoders
src/emacs.zig       Zig wrapper for the Emacs module C API
src/ghostty.zig     Re-exports and constants for the ghostty C API
```

## License

GPL-3.0-or-later
