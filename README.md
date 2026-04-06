# Ghostel

Emacs terminal emulator powered by [libghostty-vt](https://ghostty.org/) — the
same VT engine that drives the Ghostty terminal.

Ghostel is inspired by
[emacs-libvterm](https://github.com/akermu/emacs-libvterm): a native dynamic
module handles terminal state and rendering, while Elisp manages the shell
process, keymap, and buffer.

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Building from source](#building-from-source)
- [Shell Integration](#shell-integration)
- [Key Bindings](#key-bindings)
- [Features](#features)
- [Configuration](#configuration)
- [Commands](#commands)
- [Running Tests](#running-tests)
- [Performance](#performance)
- [Ghostel vs vterm](#ghostel-vs-vterm)
- [Architecture](#architecture)
- [License](#license)

## Requirements

- Emacs 27.1+ with dynamic module support
- macOS or Linux

The native module is **automatically downloaded** on first use.  Pre-built
binaries are available for:

- `aarch64-macos` (Apple Silicon)
- `x86_64-macos` (Intel Mac)
- `x86_64-linux`
- `aarch64-linux`

If you prefer to build from source or need a different platform, you'll also
need [Zig](https://ziglang.org/) 0.14+ and the ghostty submodule (see
[Building from source](#building-from-source)).

## Installation

### MELPA

```elisp
(use-package ghostel
  :ensure t)
```

### use-package with vc (Emacs 30+)

```elisp
(use-package ghostel
  :vc (:url "https://github.com/dakra/ghostel" :rev :newest))
```

### use-package with load-path

```elisp
(use-package ghostel
  :load-path "/path/to/ghostel")
```

### Manual

```elisp
(add-to-list 'load-path "/path/to/ghostel")
(require 'ghostel)
```

Then `M-x ghostel` to open a terminal.

### Native module

When the native module is missing, Ghostel will offer to **download a
pre-built binary** or **compile from source** (controlled by
`ghostel-module-auto-install`, default `ask`).  You can also trigger these
manually:

- `M-x ghostel-download-module` — download a pre-built binary from GitHub releases
- `M-x ghostel-module-compile` — build from source via `build.sh`

## Building from source

Building is only needed if you don't want to use the pre-built binaries.

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

### Building from source (MELPA install)

MELPA packages only include `.el` files — the build script, Zig sources, and
ghostty submodule are not included.  This means `M-x ghostel-module-compile`
is not available when installed from MELPA.

The recommended approach is to download a **pre-built binary** via
`M-x ghostel-download-module` (this works regardless of install method).

If you prefer to compile from source, clone the repository, build, and copy
the resulting module into your MELPA package directory:

```sh
git clone --recurse-submodules https://github.com/dakra/ghostel.git
cd ghostel
./build.sh

# Copy the module into your MELPA package directory
# (adjust the path to match your Emacs package directory and ghostel version)
cp ghostel-module.dylib ~/.emacs.d/elpa/ghostel-*/    # macOS
cp ghostel-module.so    ~/.emacs.d/elpa/ghostel-*/    # Linux
```

## Shell Integration

Shell integration (directory tracking via OSC 7, prompt navigation via OSC 133,
etc.) is **automatic** for bash, zsh, and fish.  No changes to your shell
configuration files are needed.

This is controlled by `ghostel-shell-integration` (default `t`).  Set it to
`nil` to disable auto-injection and source the scripts manually instead:

<details>
<summary>Manual shell integration</summary>

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
</details>

## Key Bindings

### Terminal mode

| Key         | Action                                 |
|-------------|----------------------------------------|
| Most keys   | Sent directly to the terminal          |
| `C-c C-c`   | Send interrupt (C-c)                   |
| `C-c C-z`   | Send suspend (C-z)                     |
| `C-c C-d`   | Send EOF (C-d)                         |
| `C-c C-\`   | Send quit (C-\)                        |
| `C-c C-t`   | Enter copy mode                        |
| `C-y`       | Yank from kill ring (bracketed paste)  |
| `M-y`       | Yank-pop (cycle through kill ring)     |
| `C-c C-y`   | Paste from kill ring                   |
| `C-c C-l`   | Clear scrollback                       |
| `C-c C-n`   | Jump to next prompt                    |
| `C-c C-p`   | Jump to previous prompt                |
| `C-c C-q`   | Send next key literally (escape hatch) |
| Mouse wheel | Scroll through scrollback              |

Keys listed in `ghostel-keymap-exceptions` (default: `C-c`, `C-x`, `C-u`,
`C-h`, `C-g`, `M-x`, `M-o`, `M-:`, `C-\`) pass through to Emacs.

### Copy mode

Enter with `C-c C-t`. Standard Emacs navigation works.
Normal letter keys exit copy mode and send the key to the terminal.

| Key           | Action                          |
|---------------|---------------------------------|
| `C-SPC`       | Set mark                        |
| `M-w` / `C-w` | Copy selection and exit         |
| `C-n` / `C-p` | Move line (scrolls at edges)    |
| `M-v` / `C-v` | Scroll page up / down           |
| `M-<` / `M->` | Jump to top / bottom of buffer  |
| `C-c C-n`     | Jump to next prompt             |
| `C-c C-p`     | Jump to previous prompt         |
| `C-c C-t`     | Exit without copying            |
| `a`–`z`       | Exit and send key to terminal   |

Soft-wrapped newlines are automatically stripped from copied text.

## Features

### Terminal Emulation
- Full VT terminal emulation via libghostty-vt
- 256-color and RGB (24-bit true color) support
- Text attributes: bold, italic, faint, underline (single/double/curly/dotted/dashed with color), strikethrough, inverse
- Cursor styles: block, bar, underline, hollow block
- Alternate screen buffer (for TUI apps like htop, vim, etc.)
- Scrollback buffer (configurable, default 20MB (~10,000 lines))

### Links and File Detection
- **OSC 8 hyperlinks** — clickable URLs emitted by terminal programs (click or `RET` to open)
- **Plain-text URL detection** — automatically linkifies `http://` and `https://` URLs even without OSC 8 (toggle with `ghostel-enable-url-detection`)
- **File path detection** — patterns like `/path/to/file.el:42` become clickable, opening the file at the given line (toggle with `ghostel-enable-file-detection`)

### Clipboard
- **OSC 52 clipboard** — terminal programs can set the Emacs kill ring and system clipboard (opt-in via `ghostel-enable-osc52`, useful for remote SSH sessions)
- **Bracketed paste** — yank from kill ring sends text as a bracketed paste so shells handle it correctly

### Input
- Full keyboard input with Ghostty key encoder (respects terminal modes, Kitty keyboard protocol)
- Mouse tracking (press, release, drag) via SGR mouse protocol — TUI apps receive full mouse input
- Focus events gated by DEC mode 1004
- Drag-and-drop (file paths and text)

### Shell Integration
- Automatic injection for bash, zsh, and fish — no shell RC edits needed
- **OSC 7** — directory tracking (`default-directory` follows the shell's cwd)
- **OSC 133** — semantic prompt markers, enabling prompt-to-prompt navigation with `C-c C-n` / `C-c C-p`
- **OSC 2** — title tracking (buffer is renamed from the terminal title)
- **OSC 51** — call whitelisted Emacs functions from shell scripts (see [Calling Elisp from the Shell](#calling-elisp-from-the-shell))
- **OSC 52** — clipboard support (opt-in, for remote sessions)
- `INSIDE_EMACS` and `EMACS_GHOSTEL_PATH` environment variables

### Rendering
- Incremental redraw — only dirty rows are re-rendered
- Timer-based batched updates with adaptive frame rate
- **Immediate redraw** for interactive typing echo — small PTY output arriving shortly after a keystroke bypasses the timer, eliminating 16–33ms of latency per keypress
- **Input coalescing** — rapid keystrokes are batched into a single PTY write to reduce syscall overhead
- Cursor position updates even without cell changes
- Theme-aware color palette (syncs with Emacs theme via `ghostel-sync-theme`)

### Calling Elisp from the Shell

Shell scripts running inside ghostel can call whitelisted Elisp functions
via the `ghostel_cmd` helper (provided by the shell integration scripts):

```sh
ghostel_cmd find-file "/path/to/file"
ghostel_cmd message "Hello from the shell"
```

This uses OSC 51 escape sequences (the same protocol as vterm).  Only
functions listed in `ghostel-eval-cmds` are allowed.

Default whitelisted commands:

`find-file`, `find-file-other-window`, `dired`, `dired-other-window`, `message`.

Add your own with:

```elisp
(add-to-list 'ghostel-eval-cmds '("magit-status-setup-buffer" magit-status-setup-buffer))
```

Example shell aliases (add to your `.bashrc` / `.zshrc`):

```sh
if [[ "$INSIDE_EMACS" = 'ghostel' ]]; then
    # Open a file in Emacs from the terminal
    e()   { ghostel_cmd find-file-other-window "$@"; }

    # Open dired in another window
    dow() { ghostel_cmd dired-other-window "$@"; }

    # Open magit for the current directory
    gst() { ghostel_cmd magit-status-setup-buffer "$(pwd)"; }
fi
```

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

| Variable                         | Default              | Description                                              |
|----------------------------------|----------------------|----------------------------------------------------------|
| `ghostel-module-auto-install`    | `ask`                | What to do when native module is missing (`ask`, `download`, `compile`, `nil`) |
| `ghostel-shell`                  | `$SHELL`             | Shell program to run                                     |
| `ghostel-shell-integration`      | `t`                  | Auto-inject shell integration                            |
| `ghostel-buffer-name`            | `"*ghostel*"`        | Default buffer name                                      |
| `ghostel-max-scrollback`         | `10000`              | Maximum scrollback lines                                 |
| `ghostel-timer-delay`            | `0.033`              | Base redraw delay in seconds (~30fps)                    |
| `ghostel-adaptive-fps`           | `t`                  | Adaptive frame rate (shorter delay after idle, stop timer when idle) |
| `ghostel-immediate-redraw-threshold` | `256`            | Max output bytes to trigger immediate redraw (0 to disable) |
| `ghostel-immediate-redraw-interval`  | `0.05`           | Max seconds since last keystroke for immediate redraw    |
| `ghostel-input-coalesce-delay`   | `0.003`              | Seconds to buffer rapid keystrokes before sending (0 to disable) |
| `ghostel-full-redraw`            | `nil`                | Always do full redraws instead of incremental updates    |
| `ghostel-kill-buffer-on-exit`    | `t`                  | Kill buffer when shell exits                             |
| `ghostel-eval-cmds`              | `(see above)`        | Whitelisted functions for OSC 51 eval                    |
| `ghostel-enable-osc52`           | `nil`                | Allow apps to set clipboard via OSC 52                   |
| `ghostel-enable-url-detection`   | `t`                  | Linkify plain-text URLs in terminal output               |
| `ghostel-enable-file-detection`  | `t`                  | Linkify file:line references in terminal output          |
| `ghostel-keymap-exceptions`      | `("C-c" "C-x" ...)` | Keys passed through to Emacs                             |
| `ghostel-exit-functions`         | `nil`                | Hook run when the shell process exits                    |

## Commands

| Command                        | Description                                  |
|--------------------------------|----------------------------------------------|
| `M-x ghostel`                  | Open a new terminal                          |
| `M-x ghostel-project`          | Open a terminal in the current project root  |
| `M-x ghostel-other`            | Switch to next terminal or create one        |
| `M-x ghostel-clear`            | Clear screen and scrollback                  |
| `M-x ghostel-clear-scrollback` | Clear scrollback only                        |
| `M-x ghostel-copy-mode`        | Enter copy mode                              |
| `M-x ghostel-paste`            | Paste from kill ring                         |
| `M-x ghostel-send-next-key`    | Send next key literally                      |
| `M-x ghostel-next-prompt`      | Jump to next shell prompt                    |
| `M-x ghostel-previous-prompt`  | Jump to previous shell prompt                |
| `M-x ghostel-force-redraw`     | Force a full terminal redraw                 |
| `M-x ghostel-debug-typing-latency` | Measure per-keystroke typing latency     |
| `M-x ghostel-sync-theme`       | Re-sync color palette after theme change     |
| `M-x ghostel-download-module`  | Download pre-built native module             |
| `M-x ghostel-module-compile`   | Compile native module from source            |

### Project integration

`ghostel-project` opens a terminal in the current project's root directory
with a project-prefixed buffer name.  To make it available from
`project-switch-project` (`C-x p p`):

```elisp
(add-to-list 'project-switch-commands '(ghostel-project "Ghostel") t)
```

## Running Tests

Tests use ERT.  The Makefile provides convenient targets:

```sh
make test        # pure Elisp tests (no native module required)
make all         # build + test + lint
make bench-quick # quick benchmark sanity check
```

You can also run tests directly:

```sh
# Pure Elisp tests (no native module required)
emacs --batch -Q -L . -l ert -l test/ghostel-test.el -f ghostel-test-run-elisp

# Full test suite (requires built native module)
emacs --batch -Q -L . -l ert -l test/ghostel-test.el -f ghostel-test-run
```

## Performance

Ghostel includes a benchmark suite comparing throughput against other Emacs
terminal emulators: [vterm](https://github.com/akermu/emacs-libvterm) (native
module), [eat](https://codeberg.org/akib/emacs-eat) (pure Elisp), and Emacs
built-in `term`.

The primary benchmark streams 1 MB of data through a real process pipe,
matching actual terminal usage.  Results on Apple M4 Max, Emacs 31.0.50:

| Backend              | Plain ASCII | URL-heavy |
|----------------------|------------:|----------:|
| ghostel              |    72 MB/s  |  26 MB/s  |
| ghostel (no detect)  |    74 MB/s  |  74 MB/s  |
| vterm                |    33 MB/s  |  27 MB/s  |
| eat                  |   4.4 MB/s  | 3.4 MB/s  |
| term                 |   5.4 MB/s  | 4.6 MB/s  |

Ghostel scans terminal output for URLs and file paths, making them clickable.
The "no detect" row shows throughput with this detection disabled
(`ghostel-enable-url-detection` / `ghostel-enable-file-detection`).  The other
emulators do not have this feature, so their numbers are comparable to the "no
detect" row.

### Typing latency

Interactive keystrokes are optimized separately from bulk throughput.  When
you type a character, the PTY echo is detected and rendered immediately
(bypassing the 33ms redraw timer), so the character appears on screen with
minimal delay.  Use `M-x ghostel-debug-typing-latency` to measure the
end-to-end latency on your system — it reports per-keystroke PTY, render,
and total latency with min/median/p99/max statistics.

Run the benchmarks yourself:

```sh
bench/run-bench.sh              # full suite (throughput)
bench/run-bench.sh --quick      # quick sanity check
```

The typing latency benchmark can be run from Elisp:

```elisp
(require 'ghostel-debug)
M-x ghostel-debug-typing-latency    ; interactive measurement
```

## Ghostel vs vterm

Both ghostel and [vterm](https://github.com/akermu/emacs-libvterm) are native
module terminal emulators for Emacs.  Ghostel uses
[libghostty-vt](https://ghostty.org/) (Zig) as its VT engine; vterm uses
[libvterm](https://www.leonerd.org.uk/code/libvterm/) (C), the same library
powering Neovim's built-in terminal.

### Feature comparison

| Feature                       | ghostel   | vterm   |
|-------------------------------|-----------|---------|
| True color (24-bit)           | Yes       | Yes     |
| Bold / italic / faint         | Yes       | Yes     |
| Underline styles (5 types)    | Yes       | No      |
| Underline color               | Yes       | No      |
| Strikethrough                 | Yes       | Yes     |
| Cursor styles                 | 4 types   | 3 types |
| OSC 8 hyperlinks              | Yes       | No      |
| Plain-text URL/file detection | Yes       | No      |
| Kitty keyboard protocol       | Yes       | No      |
| Mouse passthrough (SGR)       | Yes       | No      |
| Bracketed paste               | Yes       | Yes     |
| Alternate screen              | Yes       | Yes     |
| Shell integration auto-inject | Yes       | No      |
| Prompt navigation (OSC 133)   | Yes       | Yes     |
| Elisp eval from shell         | Yes       | Yes     |
| Tramp-aware directory         | No        | Yes     |
| OSC 52 clipboard              | Yes       | Yes     |
| Copy mode                     | Yes       | Yes     |
| Drag-and-drop                 | Yes       | No      |
| Auto module download          | Yes       | No      |
| Scrollback default            | ~10,000   | 1,000   |
| PTY throughput (plain ASCII)  | 72 MB/s   | 33 MB/s |
| Default redraw rate           | ~30 fps   | ~10 fps |

### Key differences

**Terminal engine.**  libghostty-vt comes from
[Ghostty](https://ghostty.org/), a modern GPU-accelerated terminal, and
supports Kitty keyboard/mouse protocols, rich underline styles, and OSC 8
hyperlinks.  libvterm targets VT220/xterm emulation and is more conservative
in protocol support.

**Mouse handling.**  Ghostel encodes mouse events (press, release, drag) and
passes them through to the terminal via SGR mouse protocol.  TUI apps like
htop or lazygit receive full mouse input.  vterm intercepts mouse clicks for
Emacs point movement and does not forward them to the terminal.

**Rendering.**  Both use text properties (not overlays) and batch consecutive
cells with identical styles.  Ghostel's engine provides three-level dirty
tracking (none / partial / full) with per-row granularity.  vterm uses
damage-rectangle callbacks and redraws entire invalidated rows.  Ghostel
defaults to ~30 fps redraw; vterm defaults to ~10 fps.

**Shell integration.**  Ghostel auto-injects shell integration scripts for
bash, zsh, and fish — no shell RC changes needed.  vterm requires manually
sourcing scripts in your shell configuration.  vterm's shell integration is
more featureful: it supports executing Elisp from the shell (`vterm_cmd`) and
Tramp-aware remote directory tracking.

**Performance.**  In PTY throughput benchmarks (1 MB streamed through `cat`),
ghostel is roughly 2x faster than vterm on plain ASCII data (72 vs 33 MB/s).
On URL-heavy output the gap narrows as ghostel's link detection adds overhead,
but with detection disabled ghostel reaches 74 MB/s.  See the
[Performance](#performance) section above for full numbers and how to run the
benchmark suite yourself.

**Installation.**  Ghostel can automatically download a pre-built native
module or compile from source with [Zig](https://ziglang.org/).  vterm uses
CMake with a single C dependency (libvterm) and can auto-compile on first
load from Elisp.

For a detailed architectural comparison, see [design.org](design.org).

## Architecture

```
ghostel.el          Elisp: keymap, process management, mode, commands
src/module.zig      Entry point: emacs_module_init, function registration
src/terminal.zig    Terminal struct wrapping ghostty handles
src/render.zig      RenderState -> Emacs buffer with styled text
src/input.zig       Key and mouse encoding via ghostty encoders
src/emacs.zig       Zig wrapper for the Emacs module C API
src/ghostty.zig     Re-exports and constants for the ghostty C API
```

## License

GPL-3.0-or-later
