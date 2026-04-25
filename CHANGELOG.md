# Changelog

All notable changes to this project will be documented in this file.

## [0.18.1] — 2026-04-25

### Added
- `ghostel-plain-link-detection-delay` user option (default 0.1s)
  controls how long ghostel waits after a redraw before scanning for
  plain-text URLs and file paths.  Set to 0 to restore the previous
  synchronous behavior
  ([671d3ee](https://github.com/dakra/ghostel/commit/671d3ee)).

### Changed
- Plain-text link detection is now deferred off the redraw path and
  coalesced via a single timer, so bursts of redraws collapse into one
  scan instead of running detection on every dirty redraw.  Native
  OSC-8 hyperlink spans continue to be handled inside the renderer.
  The process sentinel cancels the pending detection timer so it
  cannot fire against a buffer that is about to be killed
  ([671d3ee](https://github.com/dakra/ghostel/commit/671d3ee)).
- Scrollback rotation detection now snapshots the first scrollback
  row directly (`std.mem.eql` over all `term.cols` cells) instead of
  hashing the first 16 cells with FNV-1a.  Removes a small collision
  probability and the arbitrary 16-cell sample that could miss
  rotation when two rows shared the same opening cells; the
  cached-read optimisation that skips the end-of-redraw round trip is
  preserved
  ([4b1a0ba](https://github.com/dakra/ghostel/commit/4b1a0ba)).

## [0.18.0] — 2026-04-24

### Breaking
- Repository layout reorganized.  Elisp sources now live under `lisp/`
  (the `ghostel` package) and `extensions/` (independent `evil-ghostel`
  package); vendored headers moved from `include/` to `vendor/`; the
  bundled compiled terminfo moved from `terminfo/` to `etc/terminfo/`;
  shell-integration assets restructured into `etc/shell/ghostel.{bash,
  fish,zsh}` (user-sourced rc files) and `etc/shell/bootstrap/` (env-
  hook shims for local auto-injection)
  ([266e3e9](https://github.com/dakra/ghostel/commit/266e3e9)).
- Users who source ghostel's shell rc files manually from their own
  shell configuration must update the path: `etc/ghostel.{bash,zsh,
  fish}` → `etc/shell/ghostel.{bash,zsh,fish}`.
- `evil-ghostel` is now published as a separate MELPA package.  Users
  who relied on installing `ghostel` alone and getting evil integration
  for free must now install `evil-ghostel` separately.  In return,
  `package-vc-install ghostel` no longer pulls `evil` in as a
  transitive dependency of the single-repo scan.
- Removed the `ghostel-evil` compatibility shim that was deprecated in
  0.13.0.  Replace any `(require 'ghostel-evil)` with `(require
  'evil-ghostel)` and any `ghostel-evil-mode` calls with
  `evil-ghostel-mode`.

### Added
- `ghostel-environment` user option (mirrors `vterm-environment`):
  list of `KEY=VALUE` strings prepended to `process-environment`
  before spawning the shell.  Honors `.dir-locals.el` via
  `hack-dir-local-variables`, propagates to TRAMP remote shells, and
  applies to both shell spawns and `ghostel-compile` spawns.  User
  entries take precedence over ghostel's own `TERM`/`INSIDE_EMACS`.
  Closes [#176](https://github.com/dakra/ghostel/issues/176)
  ([87c99e5](https://github.com/dakra/ghostel/commit/87c99e5)).
- `ghostel-default` face (inherits `default`) as the per-buffer
  customization point for terminal foreground/background, allowing
  e.g. a dark terminal inside a light Emacs without resorting to
  `defadvice`.  Closes
  [#178](https://github.com/dakra/ghostel/issues/178)
  ([7c3fa5b](https://github.com/dakra/ghostel/commit/7c3fa5b)).

### Changed
- `ghostel` and `ghostel-project` now explicitly return the buffer
  they create or switch to, so callers can use the buffer
  programmatically without relying on `pop-to-buffer` side effects.
  Closes [#185](https://github.com/dakra/ghostel/issues/185)
  ([fdfb68f](https://github.com/dakra/ghostel/commit/fdfb68f)).
- ANSI color faces now inherit from `ansi-color-*` instead of
  `term-color-*`.  Themes (notably modus) deliberately remap
  `term-color-black` / `term-color-white` to bright palette entries
  to keep them distinct from `term.el`'s buffer face — that
  accommodation made e.g. htop's status bar render gray-on-green and
  unreadable.  `ansi-color-*` is the canonical ANSI face family
  since Emacs 28.1 and themes customize it to the proper palette.
  Closes [#175](https://github.com/dakra/ghostel/issues/175)
  ([a27f2fa](https://github.com/dakra/ghostel/commit/a27f2fa)).

### Fixed
- Scrollback no longer leaves stale rows after `CSI 3J`
  (clear-scrollback) followed by enough new output to restore the
  same scrollback depth.  A unified `rebuild_pending` flag now
  tracks all scrollback-validity signals (resize, CSI 3J, rotation
  hash mismatch); the surgical-trim fallback that misbehaved on
  reflow is replaced with a single full-erase path.  Closes
  [#160](https://github.com/dakra/ghostel/issues/160)
  ([f5524ef](https://github.com/dakra/ghostel/commit/f5524ef)).
- A ghostel buffer that received output while hidden no longer
  shows a stale pre-hide screen on re-show.  A per-window snap list
  populated via `window-buffer-change-functions` forces the next
  redraw to anchor to the latest output.  Closes
  [#177](https://github.com/dakra/ghostel/issues/177)
  ([63e008f](https://github.com/dakra/ghostel/commit/63e008f)).
- The first ghostel buffer in a session now respects
  `display-buffer-alist`.  Fixes
  [#179](https://github.com/dakra/ghostel/issues/179)
  ([d33052d](https://github.com/dakra/ghostel/commit/d33052d)).
- `ghostel` and `ghostel-project` reuse an existing terminal buffer
  even after `ghostel--set-title-default` has renamed it.  Buffers
  now carry a sticky `ghostel--buffer-identity` set at creation
  time, and lookup matches on identity rather than current buffer
  name.  Fixes
  [#168](https://github.com/dakra/ghostel/issues/168)
  ([465030e](https://github.com/dakra/ghostel/commit/465030e)).
- Bind `[xterm-paste]` to a ghostel-aware handler so clipboard
  pastes delivered by the host terminal (TTY Emacs with bracketed
  paste) reach the inferior shell instead of being inserted into
  the renderer-owned buffer and wiped on the next redraw.  Fixes
  [#172](https://github.com/dakra/ghostel/issues/172)
  ([5546b97](https://github.com/dakra/ghostel/commit/5546b97)).
- Meta-modified keys (`M-x`, `M-DEL`, …) now reach the terminal in
  TTY Emacs.  TTY Emacs delivers `M-<key>` as an ESC prefix that
  consumes the meta modifier before the binding fires; the dispatch
  path now detects the `esc-map` lookup via
  `this-command-keys-vector` and re-injects meta.  Follow-up to
  [43220db](https://github.com/dakra/ghostel/commit/43220db); fixes
  [#48](https://github.com/dakra/ghostel/issues/48)
  ([c42451e](https://github.com/dakra/ghostel/commit/c42451e)).
- Fish auto-inject now installs `xterm-ghostty` terminfo on remote
  hosts via the `ssh` wrapper (parity with bash/zsh), and no longer
  leaks fish's internal vendor-conf `xdg_data_dirs` (with `/fish`
  appended) into `XDG_DATA_DIRS` for every spawned subprocess.  The
  vendor-conf shim now chains to `etc/ghostel.fish` instead of
  carrying a drifting inline copy
  ([d9fd009](https://github.com/dakra/ghostel/commit/d9fd009)).
- `package-vc-install` on Emacs 30.x no longer fails byte-compiling
  `test/`, `bench/`, and `extensions/`.  A `.elpaignore` scopes
  recompilation to the package's lisp directory via
  `byte-compile-ignore-files`.  Emacs 31 fixed this upstream
  ([573acd97](https://cgit.git.savannah.gnu.org/cgit/emacs.git/commit/?id=573acd97e54ceead6d11b330909ffb8e744247cc));
  the `.elpaignore` covers the un-backported case
  ([bcba725](https://github.com/dakra/ghostel/commit/bcba725)).

## [0.17.0] — 2026-04-21

### Added
- `evil-ghostel-initial-state` defcustom controls the initial evil state
  in ghostel buffers (default `insert`). Replaces a hard-coded
  `evil-set-initial-state` call that fired on every ghostel buffer
  creation and silently clobbered user overrides. `:set` re-applies the
  value on change, and the `setq-before-require` path is honoured on
  load
  ([5fcbb19](https://github.com/dakra/ghostel/commit/5fcbb19)).

### Changed
- Replaced `ghostel-enable-title-tracking` (boolean) with
  `ghostel-set-title-function`.  The new option holds the function
  invoked on OSC 2 title changes; set to nil to disable title tracking,
  or to a custom function to fully override the rename behaviour
  ([5bd67f1](https://github.com/dakra/ghostel/commit/5bd67f1)).

### Fixed
- `mark` now survives native redraws. The full-redraw path
  (`eraseBuffer`) previously snapped every marker to `point-min`, and
  the partial-redraw path drifted markers asymmetrically by
  insertion-type — so `C-SPC`-set marks or normal-state region commands
  lost their anchor on every frame
  ([4816ece](https://github.com/dakra/ghostel/commit/4816ece)).
- Evil visual selections no longer stretch to a multi-row phantom
  region in a buffer that is streaming output. The `around-redraw`
  advice now saves and restores `evil-visual-beginning` /
  `evil-visual-end` while in visual state, in addition to `point`
  ([606ec4d](https://github.com/dakra/ghostel/commit/606ec4d)).
- Removed the `evil-ghostel` normal-state-entry hook that corrupted
  point after operator commands — `yy`, `v..y`, and `v..<escape>` could
  discard the motion and land point on the TUI cursor row. Evil's own
  operator/visual machinery places point correctly without the extra
  snap
  ([b955dbb](https://github.com/dakra/ghostel/commit/b955dbb)).

## [0.16.3] — 2026-04-20

### Fixed
- Block cursor no longer drifts up a row when a TUI parks it on an
  empty last row via absolute positioning (CUP). The `window-point`
  clamp from 0.16.1 is broadened via a new
  `ghostel--cursor-on-empty-row-p` native predicate so the clamp fires
  on both pending-wrap and empty-trailing-row conditions. Closes
  [#157](https://github.com/dakra/ghostel/issues/157)
  ([d4fdc8e](https://github.com/dakra/ghostel/commit/d4fdc8e)).
- The bundled `ssh` wrapper in `ghostel.bash` / `ghostel.zsh` no longer
  fails with a parse error when the user has `alias ssh=…` set before
  sourcing the integration. Uses `function ssh { … }` form to sidestep
  alias expansion. Fixes
  [#155](https://github.com/dakra/ghostel/issues/155)
  ([44aaf67](https://github.com/dakra/ghostel/commit/44aaf67)).

## [0.16.2] — 2026-04-20

### Added
- Bundled `xterm-ghostty` terminfo under `terminfo/` (both Linux and
  macOS hashed-dir layouts). Terminal sessions now set
  `TERM=xterm-ghostty` + `TERMINFO=<bundled>` + `TERM_PROGRAM=ghostty`
  so TUI apps that consult terminfo see ghostel's real capabilities —
  most notably DEC 2026 (`Sync`), which Claude Code needs to avoid
  cascading unsynchronised redraws on `M-x` with large scrollback.
  TRAMP pushes terminfo to a remote temp dir over the existing
  connection; outbound `ssh` from a local buffer is shadowed with a
  wrapper that installs terminfo on the remote via `tic` on first use
  (cached per-host under `$XDG_CACHE_HOME/ghostel/`, invalidated on
  libghostty bumps).  New options: `ghostel-term`,
  `ghostel-ssh-install-terminfo`, `M-x ghostel-ssh-clear-terminfo-cache`
  ([2c92f68](https://github.com/dakra/ghostel/commit/2c92f68)).

### Fixed
- Minibuffer activation (M-x, vertico, consult) no longer repaints the
  shell prompt or forces full TUI redraws. Shrinks caused by the
  minibuffer stealing window space are treated as viewport crops
  instead of real resizes, suppressing the spurious SIGWINCH. Apps on
  the alternate screen (vim, htop, less, Claude Code) still receive
  SIGWINCH because they own the full viewport; selecting the ghostel
  window while the minibuffer is open commits the cropped size
  ([3e8d9c7](https://github.com/dakra/ghostel/commit/3e8d9c7)).
- `ghostel-compile` header and early output no longer wrap at the
  wrong column when the compile buffer lands in a smaller window than
  the selected one.  The VT is now reconciled to the output window's
  dimensions before rendering the header and before spawning the
  process
  ([dcbbf1d](https://github.com/dakra/ghostel/commit/dcbbf1d)).
- `M-x kill-compilation` now finds and terminates a live
  `ghostel-compile` run. `compilation-locs` is declared buffer-locally
  during the run so `compilation-buffer-internal-p` recognises the
  buffer
  ([dcbbf1d](https://github.com/dakra/ghostel/commit/dcbbf1d)).

## [0.16.1] — 2026-04-20

### Fixed
- Block cursor no longer draws on top of the last character while the
  user is typing at a shell prompt. The `window-point` clamp introduced
  in 0.16.0 is narrowed to fire only when libghostty reports the cursor
  in pending-wrap state, exposed via a new
  `ghostel--cursor-pending-wrap-p` native function. Fixes
  [#146](https://github.com/dakra/ghostel/issues/146)
  ([ad8536e](https://github.com/dakra/ghostel/commit/ad8536e)).

## [0.16.0] — 2026-04-19

### Added
- Desktop notifications via OSC 9 (iTerm2) and OSC 777 (rxvt `notify`),
  plus ConEmu OSC 9;4 progress reports. Notifications route through
  `ghostel-notification-function` (default uses `notifications-notify`
  with a `message` fallback, dispatched via `run-at-time` so a slow
  DBus broker can't stall the VT parser); progress routes through
  `ghostel-progress-function` (default shows `[42%]` / `[...]` /
  `[err]` / `[paused]` in the mode line). OSC 9;9 CWD reports are
  handled the same way as OSC 7. Closes
  [#141](https://github.com/dakra/ghostel/issues/141)
  ([4f7b1cd](https://github.com/dakra/ghostel/commit/4f7b1cd)).
- `ghostel-compile-global-mode`: opt-in global minor mode that advises
  `compilation-start` so every caller (`compile`, `recompile`,
  `project-compile`, ...) automatically runs in a ghostel buffer.
  Falls through to the stock implementation for `grep-mode`, comint,
  and `continue=non-nil`; excluded set is customisable via
  `ghostel-compile-global-mode-excluded-modes`
  ([e7164ec](https://github.com/dakra/ghostel/commit/e7164ec)).
- `ghostel-send-string` and `ghostel-send-key` public API for external
  packages (agent integrations, custom keymaps) to drive a ghostel
  buffer without reaching into `ghostel--` internals. The old internal
  `ghostel--send-key` is kept as an obsolete alias; the raw-byte
  primitive is now `ghostel--send-string`
  ([5453c22](https://github.com/dakra/ghostel/commit/5453c22)).
- `<XF86Paste>` and `<XF86Copy>` media keys are now bound to
  `ghostel-yank` and `kill-ring-save`. Previously they fell through to
  the global commands and got overpainted by the next redraw
  ([65932e6](https://github.com/dakra/ghostel/commit/65932e6)).

### Changed
- `ghostel-compile` no longer types its command into an interactive
  shell. Each invocation spawns `shell-file-name -c COMMAND` directly
  via `make-process` through a PTY owned by the ghostel renderer.
  Multi-line scripts with embedded newlines now pass through verbatim
  (the old type-into-shell path interpreted each newline as RET), exit
  status comes from the process sentinel, and shell integration is no
  longer required. The banner is written to the VT before spawn so it
  appears live; interactive programs like `htop`, `less`, and `read`
  prompts keep working because the buffer stays in `ghostel-mode`
  during the run
  ([e7164ec](https://github.com/dakra/ghostel/commit/e7164ec)).
- `ghostel-recompile` now re-runs into the current buffer when it
  holds a local `ghostel-compile--command`, so pressing `g` in a
  `*compilation*` buffer produced by `ghostel-compile-global-mode`
  reuses the buffer and window instead of opening a second one
  ([e7164ec](https://github.com/dakra/ghostel/commit/e7164ec)).
- `ghostel-compile` opens its buffer in a non-selected window, matching
  `M-x compile` exactly.  Respects `display-buffer-alist`, keeps focus
  on the caller, and `quit-window` disposes of the window the way users
  expect. Closes [#122](https://github.com/dakra/ghostel/issues/122)
  ([9846c64](https://github.com/dakra/ghostel/commit/9846c64)).
- `evil-ghostel` point now tracks the terminal cursor in
  `evil-emacs-state`, not just `insert-state` — emacs-state is evil's
  vanilla-Emacs escape hatch and should behave like a normal terminal
  ([f05e0db](https://github.com/dakra/ghostel/commit/f05e0db)).
- Large TUI redraws (Claude Code, post-resize frames) now stream in a
  single filter call. `process-adaptive-read-buffering` is disabled and
  `read-process-output-max` raised to at least 1 MB for ghostel PTYs;
  pre-Emacs 31 this collapses a 570 KB post-resize frame from ~9 filter
  calls to 1 — a ~15-second cascading repaint becomes instant. Mirrors
  what vterm does for the same reason. Fixes
  [#85](https://github.com/dakra/ghostel/issues/85)
  ([bcf2f0c](https://github.com/dakra/ghostel/commit/bcf2f0c)).

### Fixed
- Child programs that enable focus reporting (Claude Code, btop, vim)
  now see focus-out when the user selects a different window inside
  Emacs, not only when the whole frame blurs. Adds hooks on
  `window-selection-change-functions` and
  `window-buffer-change-functions` in addition to frame focus. Closes
  [#140](https://github.com/dakra/ghostel/issues/140)
  ([ddaefbc](https://github.com/dakra/ghostel/commit/ddaefbc)).
- Process sentinel no longer removes the focus-reporting hook
  globally on exit, which had broken focus reports for every other
  live ghostel buffer
  ([ddaefbc](https://github.com/dakra/ghostel/commit/ddaefbc)).
- TUI cursor no longer disappears on the last viewport row when it
  lands in pending-wrap state. Clamps `window-point` back by one when
  `pt` equals `point-max` so Emacs redisplay stops shifting
  `window-start` up by a row to "make it visible." Closes
  [#138](https://github.com/dakra/ghostel/issues/138)
  ([17fc791](https://github.com/dakra/ghostel/commit/17fc791)).
- Viewport no longer snaps to the prompt when the minibuffer opens
  (and the ghostel window shrinks) in a scrolled-up TUI. During a
  resize-triggered redraw, windows that were auto-following before
  the resize are treated as still anchored rather than as a user
  scroll. Closes [#127](https://github.com/dakra/ghostel/issues/127)
  ([aa4912d](https://github.com/dakra/ghostel/commit/aa4912d)).
- Per-cell face properties (colours from SGR sequences) now survive
  when `font-lock-mode` is force-enabled in a ghostel buffer — e.g.
  Doom Emacs sets `font-lock-defaults` globally, which reactivates
  font-lock after `ghostel-mode`'s `(font-lock-mode -1)`. A
  buffer-local `font-lock-unfontify-region-function` neutralises the
  unfontify pass in both `ghostel-mode` and `ghostel-compile-view-mode`
  ([28f5071](https://github.com/dakra/ghostel/commit/28f5071)).
- `evil-ghostel`: entering normal state in a buffer with any
  scrollback no longer snaps point to row N of the scrollback region
  instead of row N of the visible viewport — the row offset now
  accounts for scrollback line count
  ([69d4b0d](https://github.com/dakra/ghostel/commit/69d4b0d)).

## [0.15.0] — 2026-04-17

### Added
- `ghostel-compile` and `ghostel-recompile`: `M-x compile`-style
  workflow backed by a real PTY, so commands that need a terminal
  (colour output, progress bars, curses tools) work normally. Finished
  buffers support `next-error` navigation and share `compile-command` /
  `compile-history` with `M-x compile`; `g` recompiles in the original
  directory, `C-u g` prompts to edit the command
  ([5280db2](https://github.com/dakra/ghostel/commit/5280db2),
  [d72751e](https://github.com/dakra/ghostel/commit/d72751e)).
- `ghostel-eshell-visual-command-mode`: overrides `eshell-exec-visual`
  so TUI programs invoked from eshell (vim, htop, less, top) run in a
  dedicated ghostel buffer instead of the default `term-mode`
  fallback. Adds `ghostel-exec` as the public primitive for running an
  arbitrary program in a ghostel buffer and an `eshell/ghostel` builtin
  ([8df9fc7](https://github.com/dakra/ghostel/commit/8df9fc7)).
- `ghostel-next-hyperlink` / `ghostel-previous-hyperlink` navigate OSC
  8 hyperlinks, auto-detected URLs, and file:line references via `C-c
  C-n` / `C-c C-p`; prompt navigation moves to `C-c M-n` / `C-c M-p`
  ([895e55b](https://github.com/dakra/ghostel/commit/895e55b)).
- `ghostel-debug-info` command collects Emacs version, system info,
  native module version (with mismatch warning), terminal state, and
  settings into `*ghostel-debug*` for pasting into bug reports. Resize
  and redraw events are now logged when `ghostel-debug-start` is active
  ([b5d7b4d](https://github.com/dakra/ghostel/commit/b5d7b4d)).
- `ghostel-ignore-cursor-change` option ignores terminal requests that
  change cursor shape or visibility; useful when editor-owned cursor
  behaviour should take precedence
  ([c901c02](https://github.com/dakra/ghostel/commit/c901c02)).
- `M-y` with no preceding yank now opens a `completing-read` browser
  over the kill ring (works with consult/vertico) instead of signalling
  an error
  ([e1e1896](https://github.com/dakra/ghostel/commit/e1e1896)).

### Changed
- `C-g` is now sent to the terminal instead of triggering
  `keyboard-quit`; in copy mode it still exits copy mode
  ([057fb1f](https://github.com/dakra/ghostel/commit/057fb1f)).
- Linkified file paths in terminal output now also match bare relative
  paths (e.g. `src/foo.rs:43:4`), paths wrapped in punctuation (Python
  tracebacks, backticks, brackets), and an optional `:column` after the
  line number. Configurable via `ghostel-file-detection-regex`. Closes
  [#107](https://github.com/dakra/ghostel/issues/107)
  ([ed17efb](https://github.com/dakra/ghostel/commit/ed17efb)).
- Module auto-download now works on systems that report `amd64`/`arm64`
  in `system-configuration`
  ([27dcec0](https://github.com/dakra/ghostel/commit/27dcec0)).
- OSC dispatch rewritten to scan each PTY write once instead of five
  times. A single `OscIterator` yields `(code, payload, terminator)`
  and one `dispatchPostWriteOscs` handles codes 7/51/52/133 in
  document order. Engine micro-benchmarks improve ~20–28% on bulk
  input
  ([819098f](https://github.com/dakra/ghostel/commit/819098f),
  [1729f24](https://github.com/dakra/ghostel/commit/1729f24)).
- CRLF normalisation is now zero-allocation and zero-copy. The old
  path allocated up to 131 KB of scratch (with heap fallback and a
  silent-truncation failure mode) and walked the input twice; the new
  path streams raw segments into libghostty's VT parser and emits
  `\r\n` inline at each bare `\n`. State is persisted across calls so
  a CRLF pair split between two writes isn't double-normalised
  ([42092e7](https://github.com/dakra/ghostel/commit/42092e7),
  [1729f24](https://github.com/dakra/ghostel/commit/1729f24)).
- Module loader unified into a single helper. Load-time and
  interactive-command paths no longer diverge in guard checks,
  directory resolution, or failure mode
  ([bbe1c41](https://github.com/dakra/ghostel/commit/bbe1c41)).
- `evil-ghostel` now included in `make checkdoc`
  ([0a9faa1](https://github.com/dakra/ghostel/commit/0a9faa1)).

### Fixed
- Top line no longer renders clipped after a terminal redraw when
  `pixel-scroll-precision-mode` had left a partial pixel offset. Closes
  [#105](https://github.com/dakra/ghostel/issues/105)
  ([bfb6e7c](https://github.com/dakra/ghostel/commit/bfb6e7c)).
- Scroll position preserved across window resizes (M-x, vertico
  open/close, window splits). A pre-redraw classifier tags windows as
  auto-follow vs. user-scrolled via multi-line content keys that
  survive scrollback eviction, full-redraw erase, and viewport
  rewrite — so scrolling up to read history and pressing `M-x` no
  longer yanks the view back to the prompt. Also eliminates a 1-row
  per-keystroke flicker seen in Claude Code's TUI. Closes
  [#115](https://github.com/dakra/ghostel/issues/115)
  ([2efecf2](https://github.com/dakra/ghostel/commit/2efecf2)).
- Backspace now works in terminal mode (`emacs -nw`). The event
  arrives as integer 127 and is now normalised to `"backspace"` at
  the Emacs-event boundary before key-name dispatch. Fixes
  [#114](https://github.com/dakra/ghostel/issues/114)
  ([c5b38d5](https://github.com/dakra/ghostel/commit/c5b38d5)).
- Typing or pasting while point is in scrollback (after mouse wheel,
  M-v, pixel-scroll) now jumps the viewport to the terminal prompt as
  intended. Fixes
  [#113](https://github.com/dakra/ghostel/issues/113)
  ([31bdc9c](https://github.com/dakra/ghostel/commit/31bdc9c)).
- Wheel events on an unselected ghostel window no longer hang Emacs.
  The scroll intercept was running in the selected window's buffer
  instead of the event window's, so the re-dispatched event hit the
  intercept again — infinite loop, recoverable only via `C-g`. Fixes
  [#119](https://github.com/dakra/ghostel/issues/119)
  ([305eacd](https://github.com/dakra/ghostel/commit/305eacd)).
- `ghostel-compile` no longer leaves ~24 blank rows between the output
  and the footer on short commands. Trailing blank grid rows from the
  VT render are trimmed on finalise. Fixes
  [#111](https://github.com/dakra/ghostel/issues/111)
  ([60ab84f](https://github.com/dakra/ghostel/commit/60ab84f)).
- OSC iterator no longer cannibalises the next OSC's bytes when a
  preceding OSC is missing its terminator — a new `\e]` introducer
  now ends the current payload
  ([1729f24](https://github.com/dakra/ghostel/commit/1729f24)).

## [0.14.0] — 2026-04-13

### Added
- `C-c C-l` binding in copy mode ([156a714](https://github.com/dakra/ghostel/commit/156a714)).

### Changed
- Decouple module downloads from package version ([36a1ad5](https://github.com/dakra/ghostel/commit/36a1ad5)).
- Disable XON/XOFF flow control so `C-q` and `C-s` reach the shell ([a8a3034](https://github.com/dakra/ghostel/commit/a8a3034)).
- Speed up test suite with early-return polling and parallel execution ([2d3bda7](https://github.com/dakra/ghostel/commit/2d3bda7)).
- Wheel events now fall through to third-party scroll packages
  (ultra-scroll, `pixel-scroll-precision-mode`, `mwheel`) when terminal
  mouse tracking is inactive. Fixes
  [#97](https://github.com/dakra/ghostel/issues/97)
  ([3b6c980](https://github.com/dakra/ghostel/commit/3b6c980)).

### Removed
- Dead scroll commands ([156a714](https://github.com/dakra/ghostel/commit/156a714)).

### Fixed
- Blank first page of scrollback after initial output burst ([f01de74](https://github.com/dakra/ghostel/commit/f01de74)).
- Keystrokes are now visible from the first character in bash sessions
  (previously invisible on old bash, notably macOS `/bin/bash` 3.2).
  Fixes [#101](https://github.com/dakra/ghostel/issues/101)
  ([51705bd](https://github.com/dakra/ghostel/commit/51705bd)).

## [0.13.0] — 2026-04-13

### Added
- VT log callback ([a3d043a](https://github.com/dakra/ghostel/commit/a3d043a)).

### Changed
- Build with Zig and vendored Emacs header ([4ca5770](https://github.com/dakra/ghostel/commit/4ca5770)).
- Use env vars for Emacs header override ([cdcfa76](https://github.com/dakra/ghostel/commit/cdcfa76)).
- Replace ghostty git submodule with Zig URL dependency ([b32308c](https://github.com/dakra/ghostel/commit/b32308c)).
- Use `_get_multi` for render state queries ([a3d043a](https://github.com/dakra/ghostel/commit/a3d043a)).
- Remove `zig build check` step and clean up stale references ([f19409e](https://github.com/dakra/ghostel/commit/f19409e)).

### Fixed
- musl cross-compilation; release builds now pass `-Dcpu=baseline` ([3e0776d](https://github.com/dakra/ghostel/commit/3e0776d)).

## [0.12.2] — 2026-04-12

### Changed
- Rename `ghostel-evil` to `evil-ghostel` ([1c37fef](https://github.com/dakra/ghostel/commit/1c37fef)).

### Fixed
- Blank screen after idle when buffer gets out of sync ([0f60388](https://github.com/dakra/ghostel/commit/0f60388)).

## [0.12.1] — 2026-04-12

### Fixed
- Cursor lands on the correct character for box-drawing and other glyphs
  where Emacs' width calculation disagrees with the terminal (seen on
  CJK/pgtk). Fixes [#86](https://github.com/dakra/ghostel/issues/86)
  ([fcb8d3b](https://github.com/dakra/ghostel/commit/fcb8d3b)).

## [0.12.0] — 2026-04-12

### Added
- `ghostel-enable-title-tracking` defcustom ([0102ad9](https://github.com/dakra/ghostel/commit/0102ad9)).

### Changed
- Defer buffer erasure on resize to eliminate blank flash ([5966043](https://github.com/dakra/ghostel/commit/5966043)).
- Redraw synchronously on resize and anchor `window-start` ([6728ffc](https://github.com/dakra/ghostel/commit/6728ffc)).

### Fixed
- Stale horizontal scroll after window resize ([cc48ae3](https://github.com/dakra/ghostel/commit/cc48ae3)).

## [0.11.0] — 2026-04-11

### Added
- Materialize libghostty scrollback into the Emacs buffer (vterm parity) ([34645e2](https://github.com/dakra/ghostel/commit/34645e2)).
- Detect cap rotation via first-row hash to keep scrollback fresh ([9ed2a76](https://github.com/dakra/ghostel/commit/9ed2a76)).

### Changed
- Always insert trailing newline in `insertScrollbackRange` ([d3acea1](https://github.com/dakra/ghostel/commit/d3acea1)).
- Trim trailing blank cells when rendering rows ([b3e86b5](https://github.com/dakra/ghostel/commit/b3e86b5)).
- Update benchmark numbers after trailing-whitespace trim ([1a31d37](https://github.com/dakra/ghostel/commit/1a31d37)).

### Fixed
- OSC 51;E eval no longer crashes the process filter when the executed
  command switches buffers, signals an error, or deselects the ghostel
  window. Fixes [#82](https://github.com/dakra/ghostel/issues/82)
  ([20cce42](https://github.com/dakra/ghostel/commit/20cce42)).

## [0.10.1] — 2026-04-11

### Added
- Configurable TRAMP method for OSC 7 directory tracking ([1159a5b](https://github.com/dakra/ghostel/commit/1159a5b)).

### Changed
- Pass `-Dcpu=baseline` for native x86_64 builds ([11df11b](https://github.com/dakra/ghostel/commit/11df11b)).
- Harden Claude review workflow for fork PRs ([f16d7b8](https://github.com/dakra/ghostel/commit/f16d7b8)).

## [0.10.0] — 2026-04-11

### Added
- `evil-mode` integration: normal-mode navigation works in terminal
  buffers with the cursor kept in sync on state transitions. Closes
  [#52](https://github.com/dakra/ghostel/issues/52)
  ([21d8439](https://github.com/dakra/ghostel/commit/21d8439)).
- OSC 4/10/11 color query responses ([c57f281](https://github.com/dakra/ghostel/commit/c57f281), fixes [#75](https://github.com/dakra/ghostel/issues/75)).
- SIGWINCH delivery tests for PTY resize ([500d978](https://github.com/dakra/ghostel/commit/500d978)).

### Changed
- Use per-process property for window resize handler ([dc102eb](https://github.com/dakra/ghostel/commit/dc102eb)).
- Track `.elc` files as proper Make targets ([144c9ba](https://github.com/dakra/ghostel/commit/144c9ba)).
- Use `executable-find` to locate bash in SIGWINCH tests ([ae06f8e](https://github.com/dakra/ghostel/commit/ae06f8e)).

### Fixed
- Remote zsh temp directory leak during session startup ([519f063](https://github.com/dakra/ghostel/commit/519f063)).
- ncurses apps (htop, etc.) now redraw at the correct size after a
  window resize instead of being frozen at their start-up dimensions.
  Fixes [#67](https://github.com/dakra/ghostel/issues/67)
  ([83d90f7](https://github.com/dakra/ghostel/commit/83d90f7)).
- SIGWINCH baseline tests on Linux by using bash explicitly ([e5582d5](https://github.com/dakra/ghostel/commit/e5582d5)).
- `wrong-number-of-arguments` in `ghostel-evil--around-delete` ([79a6b86](https://github.com/dakra/ghostel/commit/79a6b86)).

## [0.9.0] — 2026-04-09

### Added
- TRAMP integration for remote shell spawning and directory tracking ([512a4db](https://github.com/dakra/ghostel/commit/512a4db)).
- Scroll wheel inside TUI apps with mouse tracking (htop, less, etc.)
  is now forwarded to the application; it still scrolls the viewport
  when mouse tracking is off. Fixes
  [#60](https://github.com/dakra/ghostel/issues/60)
  ([a46c784](https://github.com/dakra/ghostel/commit/a46c784)).

### Fixed
- `ghostel-send-next-key` now works with prefix keys (`C-x`, `C-h`) and
  Meta-modified keys (`M-x`). Fixes
  [#62](https://github.com/dakra/ghostel/issues/62)
  ([f9e7fc0](https://github.com/dakra/ghostel/commit/f9e7fc0)).
- `claude-code-review` workflow write permissions ([63f5550](https://github.com/dakra/ghostel/commit/63f5550)).
- Wide-char pixel overflow compensation for emoji ([4c191c3](https://github.com/dakra/ghostel/commit/4c191c3)).
- Cursor visibility preserved in copy mode during redraws ([5d7be51](https://github.com/dakra/ghostel/commit/5d7be51)).

## [0.8.0] — 2026-04-08

### Added
- `ghostel-project` function ([560776f](https://github.com/dakra/ghostel/commit/560776f)).
- `ghostel-scroll-on-input` to jump to bottom on typing ([cabb939](https://github.com/dakra/ghostel/commit/cabb939)).
- `ghostel--cursor-position` to query terminal cursor location ([e3852d8](https://github.com/dakra/ghostel/commit/e3852d8)).
- `ghostel-copy-mode-recenter` (`C-l`) for copy mode ([6075b64](https://github.com/dakra/ghostel/commit/6075b64)).
- Full scrollback copy mode and copy-all command ([d07f509](https://github.com/dakra/ghostel/commit/d07f509)).
- `ghostel-copy-mode-auto-load-scrollback` option ([fc7fc94](https://github.com/dakra/ghostel/commit/fc7fc94)).

### Changed
- Bump minimum Emacs version for CI test to 28.2 ([cd3031d](https://github.com/dakra/ghostel/commit/cd3031d)).
- Preserve manual ghostel buffer renames ([c6eb801](https://github.com/dakra/ghostel/commit/c6eb801)).
- Rework how ghostel buffers are created ([cd7c043](https://github.com/dakra/ghostel/commit/cd7c043)).
- Ignore byte-compiled elisp files ([cfb0112](https://github.com/dakra/ghostel/commit/cfb0112)).
- Move `ghostel--suppress-interfering-modes` call inside `ghostel-mode` ([59b6928](https://github.com/dakra/ghostel/commit/59b6928)).
- Display lint errors when checking locally ([628ecae](https://github.com/dakra/ghostel/commit/628ecae)).
- Terminal buffers now respect `display-buffer-alist` rules (e.g.
  `(derived-mode . ghostel-mode)`). Fixes
  [#56](https://github.com/dakra/ghostel/issues/56)
  ([85b3e5f](https://github.com/dakra/ghostel/commit/85b3e5f)).
- Preserve column position when scrolling in copy mode ([0e7f904](https://github.com/dakra/ghostel/commit/0e7f904)).

### Fixed
- Lint warnings (and add test) ([20586fd](https://github.com/dakra/ghostel/commit/20586fd)).
- Meta key combinations not forwarded to terminal ([43220db](https://github.com/dakra/ghostel/commit/43220db)).

## [0.7.1] — 2026-04-06

### Added
- Prebuilt binaries for x86_64-macos and aarch64-linux (in addition to
  the existing x86_64-linux and aarch64-macos). Closes
  [#43](https://github.com/dakra/ghostel/issues/43)
  ([d04afa6](https://github.com/dakra/ghostel/commit/d04afa6)).
- MELPA installation instructions and source build notes ([c1d0daf](https://github.com/dakra/ghostel/commit/c1d0daf)).

### Changed
- Address MELPA review feedback ([416cf7a](https://github.com/dakra/ghostel/commit/416cf7a)).

### Fixed
- Build on musl-based distros (Alpine Linux) ([204164f](https://github.com/dakra/ghostel/commit/204164f)).
- Scrollback defaults treated as bytes and not lines ([21abb3d](https://github.com/dakra/ghostel/commit/21abb3d)).
- Module download URL when installed from MELPA ([cb74461](https://github.com/dakra/ghostel/commit/cb74461)).
- Mouse scroll when `pixel-scroll-precision-mode` is enabled ([067af25](https://github.com/dakra/ghostel/commit/067af25)).
- `ghostel-test-package-version` failure with stale `.elc` ([beb72d5](https://github.com/dakra/ghostel/commit/beb72d5)).

## [0.7.0] — 2026-04-05

### Changed
- Use `grid_ref` API for hyperlink detection instead of HTML formatter ([23aa22a](https://github.com/dakra/ghostel/commit/23aa22a)).
- Optimize release binaries: strip symbols and enable dead-code elimination ([f6f3ba3](https://github.com/dakra/ghostel/commit/f6f3ba3)).

## [0.6.0] — 2026-04-05

### Changed
- Change ghostty submodule from ssh to https ([607beae](https://github.com/dakra/ghostel/commit/607beae)).

### Fixed
- `C-t` and other control keys not being sent to the terminal ([d4ac858](https://github.com/dakra/ghostel/commit/d4ac858)).

## [0.5] — 2026-04-05

### Added
- Bind `s-v` (Cmd-V) to `ghostel-yank` on macOS ([4e43d38](https://github.com/dakra/ghostel/commit/4e43d38)).

### Changed
- Improve typing responsiveness with immediate redraw and input coalescing ([a30b53a](https://github.com/dakra/ghostel/commit/a30b53a)).

### Fixed
- Clicking ghostel buffer not switching window focus ([d030cbb](https://github.com/dakra/ghostel/commit/d030cbb)).
- `struct_timespec` opaque type error on some Linux systems ([5e1660b](https://github.com/dakra/ghostel/commit/5e1660b)).
- Dim/faint text (SGR 2) is now rendered by dimming the foreground
  colour (previously used `:weight light`, which most monospace fonts
  ignore). Closes [#27](https://github.com/dakra/ghostel/issues/27)
  ([a644834](https://github.com/dakra/ghostel/commit/a644834)).
- Backspace not working in fish shell ([36433fd](https://github.com/dakra/ghostel/commit/36433fd)).

## [0.4] — 2026-04-04

### Added
- Claude Code GitHub Actions workflows ([23b7caa](https://github.com/dakra/ghostel/commit/23b7caa)).
- Prompt to install native module when `ghostel` command is called ([57c6352](https://github.com/dakra/ghostel/commit/57c6352)).

### Changed
- Set default terminal fg/bg from Emacs theme colors ([e66a57d](https://github.com/dakra/ghostel/commit/e66a57d)).

## [0.3] — 2026-04-04

### Added
- Module version check to detect stale native modules ([be5c399](https://github.com/dakra/ghostel/commit/be5c399)).
- Shrink terminal when tall glyphs push content off-screen ([d913076](https://github.com/dakra/ghostel/commit/d913076)).

### Changed
- Compensate for wide-char pixel overflow by hiding trailing spaces ([e87d820](https://github.com/dakra/ghostel/commit/e87d820)).
- Skip wide-character spacer cells to fix emoji line overflow ([40b23e1](https://github.com/dakra/ghostel/commit/40b23e1)).
- Skip wide-char compensation when no wide characters are present ([691a752](https://github.com/dakra/ghostel/commit/691a752)).
- Revert overflow detection — keep only viewport pinning ([d335346](https://github.com/dakra/ghostel/commit/d335346)).
- Fix melpazoid warning ([ff6dc1b](https://github.com/dakra/ghostel/commit/ff6dc1b)).

### Removed
- `ghostel--pin-window-start` (caused emoji clipping) ([f029fbf](https://github.com/dakra/ghostel/commit/f029fbf)).

### Fixed
- Drag-and-drop by extracting drop data from correct event position ([794b5c8](https://github.com/dakra/ghostel/commit/794b5c8)).

## [0.2] — 2026-04-02

### Added
- Automatic theme color synchronization ([eb545fa](https://github.com/dakra/ghostel/commit/eb545fa)).
- ERT test for `ghostel-sync-theme` ([9668724](https://github.com/dakra/ghostel/commit/9668724)).
- Performance benchmark suite comparing ghostel, vterm, and eat ([a184e34](https://github.com/dakra/ghostel/commit/a184e34)).
- Emacs built-in `term` added to benchmark suite; README performance section ([2c86fb5](https://github.com/dakra/ghostel/commit/2c86fb5)).
- Ghostel vs. vterm comparison section in README ([3c71314](https://github.com/dakra/ghostel/commit/3c71314)).
- OSC 51 elisp eval from shell ([b3094b7](https://github.com/dakra/ghostel/commit/b3094b7)).
- Table of contents in README ([ece4a52](https://github.com/dakra/ghostel/commit/ece4a52)).
- `ghostel-full-redraw` option and force `window-start` pin ([1f299df](https://github.com/dakra/ghostel/commit/1f299df)).
- Multi-version byte-compile job; warnings treated as errors ([97258ef](https://github.com/dakra/ghostel/commit/97258ef)).
- Makefile ([835d878](https://github.com/dakra/ghostel/commit/835d878)).

### Changed
- Migrate test suite from custom framework to ERT ([bb986a2](https://github.com/dakra/ghostel/commit/bb986a2)).
- Build with `ReleaseFast` for production performance ([7393e64](https://github.com/dakra/ghostel/commit/7393e64)).
- Replace manual lint CI with melpazoid ([ede8f76](https://github.com/dakra/ghostel/commit/ede8f76)).
- Remove `Package-Requires` from secondary file ([c47662c](https://github.com/dakra/ghostel/commit/c47662c)).
- Fix melpazoid lint warnings ([9e0f076](https://github.com/dakra/ghostel/commit/9e0f076)).
- Filter libghostty info log spam from benchmark output ([ae0e9b9](https://github.com/dakra/ghostel/commit/ae0e9b9)).
- Overhaul README: installation, features, configuration ([1649771](https://github.com/dakra/ghostel/commit/1649771)).
- Exit copy mode on normal key press ([2ee9d3b](https://github.com/dakra/ghostel/commit/2ee9d3b)).
- Show cursor in copy-mode even when terminal app hid it ([c78b290](https://github.com/dakra/ghostel/commit/c78b290)).
- Suppress `hl-line-mode` in terminal buffer to prevent prompt flicker ([a9a07f1](https://github.com/dakra/ghostel/commit/a9a07f1)).
- Byte-compile warnings treated as errors in CI ([56ef155](https://github.com/dakra/ghostel/commit/56ef155)).

### Fixed
- Bottom lines cut off when TUI apps fill the screen ([f276f2d](https://github.com/dakra/ghostel/commit/f276f2d)).
- `extractString` silently dropping data >= 64KB ([1f88bed](https://github.com/dakra/ghostel/commit/1f88bed)).
- Missing `errdefer` for `mouse_encoder` in `Terminal.init` ([04ca152](https://github.com/dakra/ghostel/commit/04ca152)).
- Heap fallback for HTML formatter buffer in `scanHyperlinks` ([08e2649](https://github.com/dakra/ghostel/commit/08e2649)).
- `ghostel-dir` falling back to `default-directory` in `start-process` ([6d45a0d](https://github.com/dakra/ghostel/commit/6d45a0d)).
- Missing double-quote escaping in zsh `ghostel_cmd` ([d398fec](https://github.com/dakra/ghostel/commit/d398fec)).
- Copy-mode `M->` landing at bottom-right and exit not scrolling back ([4a9eb59](https://github.com/dakra/ghostel/commit/4a9eb59)).
- `ghostel-clear` and `ghostel-clear-scrollback` ([6ac0ba2](https://github.com/dakra/ghostel/commit/6ac0ba2)).

## [0.1] — 2026-03-31

Initial tagged release.

### Added
- Initial skeleton: Emacs terminal module powered by libghostty-vt ([d0e0ee3](https://github.com/dakra/ghostel/commit/d0e0ee3)).
- Styled rendering with colors, bold, italic, underline, etc. ([150e9e2](https://github.com/dakra/ghostel/commit/150e9e2)).
- Key encoding via `GhosttyKeyEncoder` ([a8ad51b](https://github.com/dakra/ghostel/commit/a8ad51b)).
- Scrollback, cursor style, and resize improvements ([f23290e](https://github.com/dakra/ghostel/commit/f23290e)).
- Mouse input, paste, copy mode, directory tracking ([de8d2c7](https://github.com/dakra/ghostel/commit/de8d2c7)).
- Test suite (61 tests) ([6be06f7](https://github.com/dakra/ghostel/commit/6be06f7)).
- Incremental redraw using `DIRTY_PARTIAL` ([c8024ed](https://github.com/dakra/ghostel/commit/c8024ed)).
- Focus event support gated by DEC mode 1004 ([3855df9](https://github.com/dakra/ghostel/commit/3855df9)).
- ANSI 16-color palette customization ([b42321f](https://github.com/dakra/ghostel/commit/b42321f)).
- Use face inheritance for ANSI color palette ([e75f897](https://github.com/dakra/ghostel/commit/e75f897)).
- `INSIDE_EMACS=ghostel` in shell environment ([a496249](https://github.com/dakra/ghostel/commit/a496249)).
- `ghostel-kill-buffer-on-exit` option ([6d31a99](https://github.com/dakra/ghostel/commit/6d31a99)).
- Shell integration scripts for bash, zsh, and fish ([eddc7d8](https://github.com/dakra/ghostel/commit/eddc7d8)).
- Auto-inject shell integration without requiring .bashrc changes ([593af8e](https://github.com/dakra/ghostel/commit/593af8e)).
- Clear scrollback and clear screen commands ([f8c9a80](https://github.com/dakra/ghostel/commit/f8c9a80)).
- `ghostel-send-next-key` escape hatch ([aa9207b](https://github.com/dakra/ghostel/commit/aa9207b)).
- `ghostel-yank` and `ghostel-yank-pop` for kill-ring cycling ([6eaa60b](https://github.com/dakra/ghostel/commit/6eaa60b)).
- `ghostel-exit-functions` hook ([0b5de44](https://github.com/dakra/ghostel/commit/0b5de44)).
- OSC 52 clipboard support ([a7eb78a](https://github.com/dakra/ghostel/commit/a7eb78a)).
- OSC 8 hyperlink support with click-to-open ([58f92e3](https://github.com/dakra/ghostel/commit/58f92e3)).
- OSC 133 semantic prompt markers for prompt navigation ([052c3d7](https://github.com/dakra/ghostel/commit/052c3d7)).
- URL auto-detection and `file://` link support ([b0d143c](https://github.com/dakra/ghostel/commit/b0d143c)).
- Detect file:line references and open them in Emacs on click ([454b794](https://github.com/dakra/ghostel/commit/454b794)).
- Separate defcustom for file:line detection ([457977b](https://github.com/dakra/ghostel/commit/457977b)).
- Bracketed paste conditional on terminal mode 2004 ([e209445](https://github.com/dakra/ghostel/commit/e209445)).
- Cache frequently-used Emacs symbols as global refs ([7103a56](https://github.com/dakra/ghostel/commit/7103a56)).
- Synchronized output support and debounced resize ([0a2eb85](https://github.com/dakra/ghostel/commit/0a2eb85)).
- Keyboard scrolling in copy mode ([83b7f44](https://github.com/dakra/ghostel/commit/83b7f44)).
- `M-<` / `M->` to jump to top/bottom of scrollback in copy mode ([ea4353f](https://github.com/dakra/ghostel/commit/ea4353f)).
- `C-e` in copy mode to stop at last non-whitespace character ([c2328dc](https://github.com/dakra/ghostel/commit/c2328dc)).
- Preserve column position during `C-n`/`C-p` in copy mode ([7a04588](https://github.com/dakra/ghostel/commit/7a04588)).
- Strip trailing whitespace from copied text in copy mode ([7d0de0f](https://github.com/dakra/ghostel/commit/7d0de0f)).
- Filter soft-wrapped newlines in copy mode ([f384746](https://github.com/dakra/ghostel/commit/f384746)).
- `ghostel-module-compile` command ([d75d9d1](https://github.com/dakra/ghostel/commit/d75d9d1)).
- Cross-platform build support and module auto-download ([a734e8e](https://github.com/dakra/ghostel/commit/a734e8e)).
- Rework module installation with interactive choice and defcustom ([f95fd8a](https://github.com/dakra/ghostel/commit/f95fd8a)).
- Full native build in CI and add release workflow ([20bf1f6](https://github.com/dakra/ghostel/commit/20bf1f6)).
- GitHub Actions CI with linting and tests ([3a190e3](https://github.com/dakra/ghostel/commit/3a190e3)).
- Improve code quality, adaptive redraw, and CI coverage ([ebe6f8b](https://github.com/dakra/ghostel/commit/ebe6f8b)).
- GPL3 license and expanded commentary section ([1d676df](https://github.com/dakra/ghostel/commit/1d676df)).
- README with build instructions, features, and configuration ([c43bf6a](https://github.com/dakra/ghostel/commit/c43bf6a)).

[0.18.0]: https://github.com/dakra/ghostel/compare/v0.17.0...v0.18.0
[0.17.0]: https://github.com/dakra/ghostel/compare/v0.16.3...v0.17.0
[0.16.3]: https://github.com/dakra/ghostel/compare/v0.16.2...v0.16.3
[0.16.2]: https://github.com/dakra/ghostel/compare/v0.16.1...v0.16.2
[0.16.1]: https://github.com/dakra/ghostel/compare/v0.16.0...v0.16.1
[0.16.0]: https://github.com/dakra/ghostel/compare/v0.15.0...v0.16.0
[0.15.0]: https://github.com/dakra/ghostel/compare/v0.14.0...v0.15.0
[0.14.0]: https://github.com/dakra/ghostel/compare/v0.13.0...v0.14.0
[0.13.0]: https://github.com/dakra/ghostel/compare/v0.12.2...v0.13.0
[0.12.2]: https://github.com/dakra/ghostel/compare/v0.12.1...v0.12.2
[0.12.1]: https://github.com/dakra/ghostel/compare/v0.12.0...v0.12.1
[0.12.0]: https://github.com/dakra/ghostel/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/dakra/ghostel/compare/v0.10.1...v0.11.0
[0.10.1]: https://github.com/dakra/ghostel/compare/v0.10.0...v0.10.1
[0.10.0]: https://github.com/dakra/ghostel/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/dakra/ghostel/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/dakra/ghostel/compare/v0.7.1...v0.8.0
[0.7.1]: https://github.com/dakra/ghostel/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/dakra/ghostel/compare/v0.6.0...v0.7.0
[0.6.0]: https://github.com/dakra/ghostel/compare/v0.5...v0.6.0
[0.5]: https://github.com/dakra/ghostel/compare/v0.4...v0.5
[0.4]: https://github.com/dakra/ghostel/compare/v0.3...v0.4
[0.3]: https://github.com/dakra/ghostel/compare/v0.2...v0.3
[0.2]: https://github.com/dakra/ghostel/compare/v0.1...v0.2
[0.1]: https://github.com/dakra/ghostel/releases/tag/v0.1
