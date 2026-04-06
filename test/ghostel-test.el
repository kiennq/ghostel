;;; ghostel-test.el --- Tests for ghostel -*- lexical-binding: t; byte-compile-warnings: (not obsolete); -*-

;;; Commentary:

;; Run with:
;;   emacs --batch -Q -L . -l ert -l test/ghostel-test.el -f ghostel-test-run
;;
;; Pure Elisp tests only (no native module):
;;   emacs --batch -Q -L . -l ert -l test/ghostel-test.el -f ghostel-test-run-elisp

;;; Code:

(require 'ert)
(setq load-prefer-newer t)
(require 'ghostel)

(declare-function conpty--init "conpty-module")
(declare-function conpty--is-alive "conpty-module")
(declare-function conpty--kill "conpty-module")
(declare-function conpty--read-pending "conpty-module")
(declare-function conpty--resize "conpty-module")
(declare-function conpty--write "conpty-module")
(declare-function ghostel--encode-key "dyn-loader-module")
(declare-function ghostel--focus-event "dyn-loader-module")
(declare-function ghostel--mode-enabled "dyn-loader-module")
(declare-function ghostel--new "dyn-loader-module")
(declare-function ghostel--redraw "dyn-loader-module")
(declare-function ghostel--scroll "dyn-loader-module")
(declare-function ghostel--scroll-bottom "dyn-loader-module")
(declare-function ghostel--set-palette "dyn-loader-module")
(declare-function ghostel--set-size "dyn-loader-module")
(declare-function ghostel--write-input "dyn-loader-module")

;;; Helper: inspect rendered terminal content via redraw

(defun ghostel-test--with-rendered-buffer (term fn)
  "Call FN with a temp buffer containing a full redraw of TERM."
  (with-temp-buffer
    (ghostel-mode)
    (setq-local ghostel--term term)
    (setq-local ghostel--copy-mode-active nil)
    (setq-local ghostel-cursor-follow t)
    (let ((inhibit-read-only t))
      (ghostel--redraw term t))
    (funcall fn)))

(defun ghostel-test--rendered-content (term)
  "Return the rendered buffer text for TERM."
  (ghostel-test--with-rendered-buffer
   term
   (lambda ()
     (buffer-substring-no-properties (point-min) (point-max)))))

(defun ghostel-test--row0 (term)
  "Return the first rendered row text for TERM."
  (ghostel-test--with-rendered-buffer
   term
   (lambda ()
     (goto-char (point-min))
     (string-trim-right
      (buffer-substring-no-properties (line-beginning-position)
                                      (line-end-position))))))

(defmacro ghostel-test--without-subr-trampolines (&rest body)
  "Run BODY with native trampolines disabled on supported Emacs versions."
  `(let ((native-comp-enable-subr-trampolines nil)
         (comp-enable-subr-trampolines nil))
     ,@body))

(defun ghostel-test--fixture-dir (name)
  "Return a host-valid absolute test directory named NAME."
  (file-name-as-directory
   (expand-file-name name temporary-file-directory)))

(defun ghostel-test--fixture-path (dir name)
  "Return absolute path for NAME within DIR."
  (expand-file-name name dir))

(defun ghostel-test--repo-root ()
  "Return the Ghostel repository root for the current test file."
  (let ((source (or load-file-name
                    (and (boundp 'byte-compile-current-file)
                         byte-compile-current-file)
                    buffer-file-name
                    default-directory)))
    (or (locate-dominating-file source "ghostel.el")
        (error "Could not locate Ghostel repository root from %s" source))))

(ert-deftest ghostel-test-source-omits-removed-native-hooks ()
  "Removed native debug and metadata hooks stay absent from checked-in sources."
  (let* ((repo (ghostel-test--repo-root))
         (elisp (expand-file-name "ghostel.el" repo))
         (module (expand-file-name "src/module.zig" repo))
         (elisp-content (with-temp-buffer
                          (insert-file-contents elisp)
                          (buffer-string)))
         (module-content (with-temp-buffer
                           (insert-file-contents module)
                           (buffer-string))))
    (dolist (name '("ghostel--get-title"
                    "ghostel--get-pwd"
                    "ghostel--debug-state"
                    "ghostel--debug-feed"))
      (should-not (string-match-p (regexp-quote name) elisp-content)))
    (dolist (name '("ghostel--get-title"
                    "ghostel--get-pwd"))
      (should-not (string-match-p (regexp-quote name) module-content)))
    (dolist (name '("ghostel--debug-state"
                    "ghostel--debug-feed"
                    "fn fnNew("
                    "fn fnWriteInput("))
      (should (string-match-p (regexp-quote name) module-content)))
    (dolist (name '("pub fn ghostelNew("
                    "pub fn ghostelWriteInput("))
      (should-not (string-match-p (regexp-quote name) module-content)))))

(defun ghostel-test--write-dyn-loader-fixture (path module-id lisp-name version)
  "Write a tiny dyn-loader fixture module source to PATH."
  (with-temp-file path
    (insert
     (format
      (concat
       "const c = @cImport({\n"
       "    @cInclude(\"emacs-module.h\");\n"
       "});\n"
       "const ExportDescriptor = extern struct {\n"
       "    export_id: u32,\n"
       "    kind: u32,\n"
       "    lisp_name: [*:0]const u8,\n"
       "    min_arity: i32,\n"
       "    max_arity: i32,\n"
       "    docstring: [*:0]const u8,\n"
       "    flags: u32,\n"
       "};\n"
       "const GenericManifest = extern struct {\n"
       "    loader_abi: u32,\n"
       "    module_id: [*:0]const u8,\n"
       "    module_version: [*:0]const u8,\n"
       "    exports_len: u32,\n"
       "    exports: [*]const ExportDescriptor,\n"
       "    invoke: *const fn (u32, ?*c.emacs_env, isize, [*c]c.emacs_value, ?*anyopaque) callconv(.c) c.emacs_value,\n"
       "    get_variable: *const fn (u32, ?*c.emacs_env, ?*anyopaque) callconv(.c) c.emacs_value,\n"
       "    set_variable: *const fn (u32, ?*c.emacs_env, c.emacs_value, ?*anyopaque) callconv(.c) c.emacs_value,\n"
       "};\n"
       "const exports = [_]ExportDescriptor{.{ .export_id = 1, .kind = 1, .lisp_name = \"%s\", .min_arity = 0, .max_arity = 0, .docstring = \"Return fixture version.\", .flags = 0 }};\n"
       "fn invoke(export_id: u32, raw_env: ?*c.emacs_env, _: isize, _: [*c]c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {\n"
       "    const env = raw_env.?;\n"
       "    return switch (export_id) {\n"
       "        1 => env.make_string.?(env, \"%s\", %d),\n"
       "        else => env.intern.?(env, \"nil\"),\n"
       "    };\n"
       "}\n"
       "fn getVariable(_: u32, raw_env: ?*c.emacs_env, _: ?*anyopaque) callconv(.c) c.emacs_value {\n"
       "    const env = raw_env.?;\n"
       "    return env.intern.?(env, \"nil\");\n"
       "}\n"
       "fn setVariable(_: u32, raw_env: ?*c.emacs_env, _: c.emacs_value, _: ?*anyopaque) callconv(.c) c.emacs_value {\n"
       "    const env = raw_env.?;\n"
       "    return env.intern.?(env, \"nil\");\n"
       "}\n"
       "export fn loader_module_init_generic(out: *GenericManifest) callconv(.c) void {\n"
       "    out.* = .{ .loader_abi = 1, .module_id = \"%s\", .module_version = \"%s\", .exports_len = exports.len, .exports = exports[0..].ptr, .invoke = &invoke, .get_variable = &getVariable, .set_variable = &setVariable };\n"
       "}\n")
      lisp-name version (length version) module-id version))))

(defun ghostel-test--build-dyn-loader-fixture (source output)
  "Compile a dyn-loader fixture from SOURCE to OUTPUT."
  (let ((include-dir (expand-file-name "include" (ghostel-test--repo-root))))
    (with-temp-buffer
      (unless (eq 0 (process-file "zig" nil (current-buffer) nil
                                  "build-lib" "-dynamic" "-lc" "-I" include-dir
                                  source (concat "-femit-bin=" output)))
        (error "Failed to build dyn-loader fixture %s: %s"
               output
               (string-trim (buffer-string)))))))

(defun ghostel-test--write-loader-manifest (path module-file)
  "Write loader metadata at PATH that points at MODULE-FILE."
  (with-temp-file path
    (insert (json-encode `((loader_abi . 1)
                           (module_path . ,module-file))))))

;; -----------------------------------------------------------------------
;; Test: terminal creation
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-create ()
  "Test terminal creation and basic properties."
  (let ((term (ghostel--new 25 80 1000)))
    (should term)                                         ; create returns non-nil
    (should (equal "" (ghostel-test--row0 term)))))       ; row0 is blank

;; -----------------------------------------------------------------------
;; Test: write-input and render state
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-write-input ()
  "Test feeding text to the terminal."
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "hello")
    (should (equal "hello" (ghostel-test--row0 term)))        ; text appears

    ;; Newline (CRLF — the Zig module normalizes bare LF)
    (ghostel--write-input term " world\nline2")
    (let ((state (ghostel-test--rendered-content term)))
      (should (string-match-p "hello world" state))  ; row0 has full first line
      (should (string-match-p "line2" state)))))      ; row1 has line2

;; -----------------------------------------------------------------------
;; Test: backspace handling
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-backspace ()
  "Test backspace (BS) processing by the terminal."
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "hello")
    (should (equal "hello" (ghostel-test--row0 term)))        ; before BS

    ;; BS + space + BS erases last character
    (ghostel--write-input term "\b \b")
    (should (equal "hell" (ghostel-test--row0 term)))         ; after 1 BS

    ;; Multiple backspaces
    (ghostel--write-input term "\b \b\b \b")
    (should (equal "he" (ghostel-test--row0 term)))))         ; after 3 BS total

;; -----------------------------------------------------------------------
;; Test: cursor movement escape sequences
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-cursor-movement ()
  "Test CSI cursor movement sequences."
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "abcdef")
    (ghostel--write-input term "\e[3D")
    (should (equal '(3 . 0) (ghostel-test--cursor term)))     ; cursor left 3

    (ghostel--write-input term "\e[1C")
    (should (equal '(4 . 0) (ghostel-test--cursor term)))     ; cursor right 1

    (ghostel--write-input term "\e[H")
    (should (equal '(0 . 0) (ghostel-test--cursor term)))     ; cursor home

    ;; Cursor to specific position (row 3, col 5 — 1-based in CSI)
    (ghostel--write-input term "\e[4;6H")
    (should (equal '(5 . 3) (ghostel-test--cursor term)))))   ; cursor to (5,3)

;; -----------------------------------------------------------------------
;; Test: cursor-position query
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-cursor-position ()
  "Test `ghostel--cursor-position' returns correct (COL . ROW)."
  (let ((term (ghostel--new 25 80 1000)))
    ;; Origin
    (should (equal '(0 . 0) (ghostel--cursor-position term)))

    ;; After writing text
    (ghostel--write-input term "hello")
    (should (equal '(5 . 0) (ghostel--cursor-position term)))

    ;; After cursor movement
    (ghostel--write-input term "\e[3D")
    (should (equal '(2 . 0) (ghostel--cursor-position term)))

    ;; After newline — cursor on row 1
    (ghostel--write-input term "\nworld")
    (should (equal '(5 . 1) (ghostel--cursor-position term)))

    ;; Absolute positioning
    (ghostel--write-input term "\e[4;6H")
    (should (equal '(5 . 3) (ghostel--cursor-position term)))))

;; -----------------------------------------------------------------------
;; Test: erase sequences
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-erase ()
  "Test CSI erase sequences."
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "hello world")
    (ghostel--write-input term "\e[6D")   ; cursor left 6 (on 'w')
    (ghostel--write-input term "\e[K")    ; erase to end of line
    (should (equal "hello" (ghostel-test--row0 term)))    ; erase to EOL

    (ghostel--write-input term "\e[2K")
    (should (equal "" (ghostel-test--row0 term)))))       ; erase whole line

;; -----------------------------------------------------------------------
;; Test: terminal resize
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-resize ()
  "Test terminal resize."
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "hello")
    (ghostel--set-size term 10 40)
    (should (equal "hello" (ghostel-test--row0 term)))    ; content survives resize
    ;; Write long text to verify new width
    (ghostel--write-input term "\r\n")
    (ghostel--write-input term (make-string 40 ?x))
    (let ((state (ghostel-test--rendered-content term)))
      (should (string-match-p "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" state))))) ; 40 x's on row

;; -----------------------------------------------------------------------
;; Test: scrollback
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-scrollback ()
  "Test scrollback by overflowing visible rows."
  (let ((term (ghostel--new 5 80 100)))
    (dotimes (i 10)
      (ghostel--write-input term (format "line %d\r\n" i)))
    (let ((state (ghostel-test--rendered-content term)))
      (should (string-match-p "line [6-9]" state)))       ; recent lines visible
    (ghostel--scroll term -5)
    (let ((state (ghostel-test--rendered-content term)))
      (should (string-match-p "line [0-4]" state)))))     ; scrollback shows earlier lines

;; -----------------------------------------------------------------------
;; Test: clear screen (ghostel-clear)
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-clear-screen ()
  "Test that ghostel-clear clears the visible screen but preserves scrollback."
  (skip-unless (not (eq system-type 'windows-nt)))
  (let ((buf (generate-new-buffer " *ghostel-test-clear*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--term (ghostel--new 5 80 100))
          (let* ((process-environment
                  (append (list "TERM=xterm-256color" "COLUMNS=80" "LINES=5")
                          process-environment))
                 (proc (make-process
                        :name "ghostel-test-clear"
                        :buffer buf
                        :command '("/bin/zsh" "-f")
                        :connection-type 'pty
                        :filter #'ghostel--filter)))
            (setq ghostel--process proc)
            (set-process-coding-system proc 'binary 'binary)
            (set-process-window-size proc 5 80)
            (set-process-query-on-exit-flag proc nil)
            ;; Wait for shell init
            (dotimes (_ 30) (accept-process-output proc 0.2))
            (ghostel--flush-pending-output)
            (let ((inhibit-read-only t)) (ghostel--redraw ghostel--term t))
            ;; Generate scrollback
            (dotimes (i 15)
              (process-send-string proc (format "echo clear-test-%d\n" i)))
            (dotimes (_ 20) (accept-process-output proc 0.2))
            ;; Do NOT manually flush — let ghostel-clear handle it
            (should (> (length ghostel--pending-output) 0))    ; pending output exists
            ;; Clear screen
            (ghostel-clear)
            ;; Simulate what delayed-redraw does
            (ghostel--flush-pending-output)
            (let ((inhibit-read-only t)) (ghostel--redraw ghostel--term t))
            ;; Scrollback should still exist after screen clear
            (ghostel--scroll ghostel--term -30)
            (let ((inhibit-read-only t)) (ghostel--redraw ghostel--term t))
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "clear-test-0" content))) ; scrollback preserved
            (delete-process proc)))
      (kill-buffer buf))))

;; -----------------------------------------------------------------------
;; Test: clear scrollback (ghostel-clear-scrollback)
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-clear-scrollback ()
  "Test that ghostel-clear-scrollback clears both screen and scrollback."
  (let ((buf (generate-new-buffer " *ghostel-test-clear-sb*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--term (ghostel--new 5 80 100))
          ;; Fill screen + scrollback with 10 lines
          (dotimes (i 10)
            (ghostel--write-input ghostel--term (format "line %d\r\n" i)))
          ;; Verify content on screen and in scrollback
          (let ((state (ghostel-test--rendered-content ghostel--term)))
            (should (string-match-p "line [6-9]" state)))      ; recent lines on screen
          (ghostel--scroll ghostel--term -5)
          (let ((state (ghostel-test--rendered-content ghostel--term)))
            (should (string-match-p "line [0-4]" state)))      ; early lines in scrollback
          ;; Return to bottom and call the actual function
          (ghostel--scroll-bottom ghostel--term)
          (ghostel-clear-scrollback)
          ;; Screen should be empty
          (let ((state (ghostel-test--rendered-content ghostel--term)))
            (should-not (string-match-p "line [6-9]" state)))  ; screen cleared
          ;; Scrollback should also be empty
          (ghostel--scroll ghostel--term -10)
          (let ((state (ghostel-test--rendered-content ghostel--term)))
            (should-not (string-match-p "line [0-4]" state)))) ; scrollback cleared
      (kill-buffer buf))))

;; -----------------------------------------------------------------------
;; Test: SGR styling (bold, color, etc.)
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-sgr ()
  "Test SGR escape sequences set cell styles."
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "\e[1;31mHELLO\e[0m normal")
    (should (equal "HELLO normal" (ghostel-test--row0 term))))) ; styled text content

;; -----------------------------------------------------------------------
;; Test: SGR 2 (dim/faint) renders with dimmed foreground color
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-dim-text ()
  "Test that SGR 2 (faint) produces a dimmed foreground color, not :weight light."
  (let ((buf (generate-new-buffer " *ghostel-test-dim*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            ;; Set a known palette so we can predict the dimmed color.
            ;; Default FG=#ffffff, default BG=#000000, red=#ff0000.
            (let ((rest (apply #'concat (make-list 14 "#000000"))))
              (ghostel--set-palette term
                                    (concat "#000000" "#ff0000" rest
                                            "#ffffff" "#000000")))
            ;; Dim text with default foreground
            (ghostel--write-input term "\e[2mDIM\e[0m ok")
            (ghostel--redraw term)
            (goto-char (point-min))
            (let ((face (get-text-property (point) 'face)))
              (should face)                                   ; face property exists
              (when face
                ;; Should have a :foreground (dimmed color), not :weight light
                (should (plist-get face :foreground))         ; dimmed :foreground set
                (should-not (eq 'light (plist-get face :weight)))))))  ; no :weight light
      (kill-buffer buf))))

;; -----------------------------------------------------------------------
;; Test: multi-byte character rendering (box drawing, Unicode)
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-multibyte-rendering ()
  "Test that styled multi-byte text renders without args-out-of-range."
  (let ((buf (generate-new-buffer " *ghostel-test-mb*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            (ghostel--write-input term "\e[32m┌──┐\e[0m text")
            (ghostel--redraw term)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "┌──┐" content))    ; box drawing rendered
              (should (string-match-p "text" content)))    ; text after box drawing
            (goto-char (point-min))
            (should (get-text-property (point) 'face))))   ; multibyte face property
      (kill-buffer buf))))

;; -----------------------------------------------------------------------
;; Test: wide character (emoji) does not overflow line
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-wide-char-no-overflow ()
  "Test that wide characters (emoji) don't make rendered lines overflow.
A 2-cell-wide emoji should not produce an extra space for the spacer
cell, so the visual line width must equal the terminal column count."
  (let ((buf (generate-new-buffer " *ghostel-test-wide*"))
        (cols 40))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 cols 100))
                 (inhibit-read-only t))
            ;; Feed a wide emoji — occupies 2 terminal cells
            (ghostel--write-input term "🟢")
            (ghostel--redraw term t)
            ;; First rendered line should have visual width == cols
            (goto-char (point-min))
            (let* ((line (buffer-substring (line-beginning-position)
                                           (line-end-position)))
                   (width (string-width line)))
              (should (equal cols width)))))
      (kill-buffer buf))))

;; -----------------------------------------------------------------------
;; Test: CRLF normalization in Zig
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-crlf ()
  "Test that bare LF is normalized to CRLF by the Zig module."
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "first\nsecond")
    (let ((state (ghostel-test--rendered-content term)))
      (should (string-match-p "first" state))              ; first line
      (should (string-match-p "second" state))              ; second line
      (should (string-match-p "\n" state)))))               ; cursor advanced to next row

;; -----------------------------------------------------------------------
;; Test: raw key sequence fallback
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-raw-key-sequences ()
  "Test the Elisp raw key sequence builder."
  ;; Basic keys
  (should (equal "\x7f" (ghostel--raw-key-sequence "backspace" "")))  ; backspace
  (should (equal "\r" (ghostel--raw-key-sequence "return" "")))       ; return
  (should (equal "\t" (ghostel--raw-key-sequence "tab" "")))          ; tab
  (should (equal "\e" (ghostel--raw-key-sequence "escape" "")))       ; escape
  ;; Cursor keys
  (should (equal "\e[A" (ghostel--raw-key-sequence "up" "")))         ; up
  (should (equal "\e[B" (ghostel--raw-key-sequence "down" "")))       ; down
  (should (equal "\e[C" (ghostel--raw-key-sequence "right" "")))      ; right
  (should (equal "\e[D" (ghostel--raw-key-sequence "left" "")))       ; left
  ;; Shift+arrow
  (should (equal "\e[1;2A" (ghostel--raw-key-sequence "up" "shift"))) ; shift-up
  ;; Ctrl+letter
  (should (equal "\x01" (ghostel--raw-key-sequence "a" "ctrl")))      ; ctrl-a
  (should (equal "\x03" (ghostel--raw-key-sequence "c" "ctrl")))      ; ctrl-c
  (should (equal "\x1a" (ghostel--raw-key-sequence "z" "ctrl")))      ; ctrl-z
  ;; Meta+letter
  (should (equal "\ea" (ghostel--raw-key-sequence "a" "meta")))       ; meta-a
  (should (equal "\ez" (ghostel--raw-key-sequence "z" "alt")))        ; alt-z
  ;; Function keys
  (should (equal "\eOP" (ghostel--raw-key-sequence "f1" "")))         ; f1
  (should (equal "\e[15~" (ghostel--raw-key-sequence "f5" "")))       ; f5
  (should (equal "\e[24~" (ghostel--raw-key-sequence "f12" "")))      ; f12
  ;; Tilde keys
  (should (equal "\e[2~" (ghostel--raw-key-sequence "insert" "")))    ; insert
  (should (equal "\e[3~" (ghostel--raw-key-sequence "delete" "")))    ; delete
  (should (equal "\e[5~" (ghostel--raw-key-sequence "prior" "")))     ; pgup
  ;; Unknown key
  (should (equal nil (ghostel--raw-key-sequence "xyzzy" ""))))        ; unknown

;; -----------------------------------------------------------------------
;; Test: modifier number calculation
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-modifier-number ()
  "Test modifier bitmask parsing."
  (should (equal 0 (ghostel--modifier-number "")))            ; no mods
  (should (equal 1 (ghostel--modifier-number "shift")))       ; shift
  (should (equal 4 (ghostel--modifier-number "ctrl")))        ; ctrl
  (should (equal 2 (ghostel--modifier-number "alt")))         ; alt
  (should (equal 2 (ghostel--modifier-number "meta")))        ; meta
  (should (equal 5 (ghostel--modifier-number "shift,ctrl")))  ; shift,ctrl
  (should (equal 4 (ghostel--modifier-number "control"))))    ; control

;; -----------------------------------------------------------------------
;; Test: send-event key extraction
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-send-event ()
  "Test that ghostel--send-event extracts key names and modifiers correctly."
  (let (captured-key captured-mods)
    (cl-letf (((symbol-function 'ghostel--send-encoded)
               (lambda (key mods &optional _utf8)
                 (setq captured-key key
                       captured-mods mods))))
      (cl-flet ((sim (event expected-key expected-mods)
                  (setq captured-key nil
                        captured-mods nil)
                  (let ((last-command-event event))
                    (ghostel--send-event))
                  (should (equal expected-key captured-key))
                  (should (equal expected-mods captured-mods))))
        ;; Unmodified special keys
        (sim (aref (kbd "<return>") 0) "return" "")
        (sim (aref (kbd "<tab>") 0) "tab" "")
        (sim (aref (kbd "<backspace>") 0) "backspace" "")
        (sim (aref (kbd "<escape>") 0) "escape" "")
        (sim (aref (kbd "<up>") 0) "up" "")
        (sim (aref (kbd "<f1>") 0) "f1" "")
        (sim (aref (kbd "<deletechar>") 0) "delete" "")
        ;; Modified special keys
        (sim (aref (kbd "S-<return>") 0) "return" "shift")
        (sim (aref (kbd "C-<return>") 0) "return" "ctrl")
        (sim (aref (kbd "M-<return>") 0) "return" "meta")
        (sim (aref (kbd "C-<up>") 0) "up" "ctrl")
        (sim (aref (kbd "M-<left>") 0) "left" "meta")
        (sim (aref (kbd "S-<f5>") 0) "f5" "shift")
        (sim (aref (kbd "C-S-<return>") 0) "return" "ctrl,shift")
        ;; backtab (Emacs's name for S-TAB)
        (sim (aref (kbd "<backtab>") 0) "tab" "shift")))))

(ert-deftest ghostel-test-scroll-on-input-scrolls-before-key-send ()
  "Typing while scrolled back jumps to the bottom before sending input."
  (with-temp-buffer
    (let ((ghostel-scroll-on-input t)
          (ghostel--term 'fake-term)
          (ghostel--force-next-redraw nil)
          scrolled
          sent-key
          sent-encoded)
      (let ((comp-enable-subr-trampolines nil)
            (native-comp-enable-subr-trampolines nil))
        (cl-letf (((symbol-function 'ghostel--scroll-bottom)
                   (lambda (term)
                     (setq scrolled term)))
                  ((symbol-function 'ghostel--send-key)
                   (lambda (key)
                     (setq sent-key key)))
                  ((symbol-function 'this-command-keys)
                   (lambda () "a")))
          (ghostel--self-insert)
          (should (eq 'fake-term scrolled))
          (should (equal "a" sent-key))
          (should ghostel--force-next-redraw))
        (setq ghostel--force-next-redraw nil
              scrolled nil)
        (cl-letf (((symbol-function 'ghostel--scroll-bottom)
                   (lambda (term)
                     (setq scrolled term)))
                  ((symbol-function 'ghostel--send-encoded)
                   (lambda (key mods &optional _utf8)
                     (setq sent-encoded (list key mods)))))
          (let ((last-command-event (aref (kbd "<up>") 0)))
            (ghostel--send-event))
          (should (eq 'fake-term scrolled))
          (should (equal '("up" "") sent-encoded))
          (should ghostel--force-next-redraw))))))

;; -----------------------------------------------------------------------
;; Test: modified special keys in raw fallback
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-raw-key-modified-specials ()
  "Test raw fallback produces CSI u encoding for modified specials."
  (should (equal "\e[13;2u"                                       ; shift-return
                 (ghostel--raw-key-sequence "return" "shift")))
  (should (equal "\e[9;5u"                                        ; ctrl-tab
                 (ghostel--raw-key-sequence "tab" "ctrl")))
  (should (equal "\e[127;3u"                                      ; meta-backspace
                 (ghostel--raw-key-sequence "backspace" "meta")))
  (should (equal "\e[27;6u"                                       ; ctrl-shift-escape
                 (ghostel--raw-key-sequence "escape" "shift,ctrl")))
  ;; Unmodified still produce raw bytes
  (should (equal "\r" (ghostel--raw-key-sequence "return" "")))   ; plain return
  (should (equal "\t" (ghostel--raw-key-sequence "tab" ""))))     ; plain tab

;; -----------------------------------------------------------------------
;; Test: shell process integration
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-shell-integration ()
  "Test shell process with echo command."
  (skip-unless (not (eq system-type 'windows-nt)))
  (let ((buf (generate-new-buffer " *ghostel-test-shell*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--term (ghostel--new 25 80 1000))
          (let* ((process-environment
                  (append (list "TERM=xterm-256color" "COLUMNS=80" "LINES=25")
                          process-environment))
                 (proc (make-process
                        :name "ghostel-test-sh"
                        :buffer buf
                        :command '("/bin/zsh" "-f")
                        :connection-type 'pty
                        :filter #'ghostel--filter)))
            (setq ghostel--process proc)
            (set-process-coding-system proc 'binary 'binary)
            (set-process-window-size proc 25 80)
            (set-process-query-on-exit-flag proc nil)
            ;; Wait for shell init
            (dotimes (_ 30) (accept-process-output proc 0.2))
            (should (process-live-p proc))                ; shell process alive

            ;; Run a command
            (process-send-string proc "echo GHOSTEL_TEST_OK\n")
            (dotimes (_ 10) (accept-process-output proc 0.2))
            (let ((state (ghostel-test--rendered-content ghostel--term)))
              (should (string-match-p "GHOSTEL_TEST_OK" state))) ; command output visible

            ;; Test typing + backspace via PTY echo
            (process-send-string proc "abc")
            (dotimes (_ 5) (accept-process-output proc 0.2))
            (let ((state (ghostel-test--rendered-content ghostel--term)))
              (should (string-match-p "abc" state)))      ; typed text visible

            (process-send-string proc "\x7f")
            (dotimes (_ 5) (accept-process-output proc 0.2))
            (let ((state (ghostel-test--rendered-content ghostel--term)))
              (should (string-match-p "ab" state))        ; backspace removed char
              (should-not (string-match-p "abc" state)))  ; no abc after BS

            (delete-process proc)))
      (kill-buffer buf))))

;; -----------------------------------------------------------------------
;; Test: encode-key with kitty keyboard protocol active
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-encode-key-kitty-backspace ()
  "Test that backspace is correctly encoded when kitty keyboard mode is active."
  (let* ((term (ghostel--new 25 80 1000))
         (sent-bytes nil))
    ;; Activate kitty keyboard protocol (flags=5: disambiguate + report-alternates)
    ;; by feeding CSI = 5 u to the terminal
    (ghostel--write-input term "\e[=5u")
    ;; Capture what ghostel--flush-output sends
    (cl-letf (((symbol-function 'ghostel--flush-output)
               (lambda (data)
                 (setq sent-bytes data))))
      ;; Encode backspace — should succeed and send \x7f
      (should (ghostel--encode-key term "backspace" ""))
      (should sent-bytes)
      (should (equal "\x7f" sent-bytes)))))

(ert-deftest ghostel-test-encode-key-legacy-backspace ()
  "Test that backspace is correctly encoded in legacy mode (no kitty)."
  (let* ((term (ghostel--new 25 80 1000))
         (sent-bytes nil))
    ;; No kitty mode set — legacy encoding
    (cl-letf (((symbol-function 'ghostel--flush-output)
               (lambda (data)
                 (setq sent-bytes data))))
      (should (ghostel--encode-key term "backspace" ""))
      (should sent-bytes)
      (should (equal "\x7f" sent-bytes)))))

(ert-deftest ghostel-test-da-response ()
  "Test that the terminal responds to DA1 queries."
  (let* ((term (ghostel--new 25 80 1000))
         (sent-bytes nil))
    (cl-letf (((symbol-function 'ghostel--flush-output)
               (lambda (data)
                 (setq sent-bytes (concat sent-bytes data)))))
      ;; Feed DA1 query: CSI c
      (ghostel--write-input term "\e[c")
      ;; Should have responded with DA1 (CSI ? 62 ; 22 c)
      (should sent-bytes)
      (should (string-match-p "\e\\[\\?62;22c" sent-bytes)))))

(ert-deftest ghostel-test-fish-backspace ()
  "Test backspace works with fish shell."
  :tags '(:fish)
  (skip-unless (executable-find "fish"))
  (let ((buf (generate-new-buffer " *ghostel-test-fish*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--term (ghostel--new 25 80 1000))
          (let* ((process-environment
                  (append (list "TERM=xterm-256color"
                                "COLORTERM=truecolor"
                                "COLUMNS=80" "LINES=25")
                          process-environment))
                 (proc (make-process
                        :name "ghostel-test-fish"
                        :buffer buf
                        :command '("/bin/sh" "-c"
                                   "stty erase '^?' 2>/dev/null; exec fish --no-config")
                        :connection-type 'pty
                        :filter #'ghostel--filter)))
            (setq ghostel--process proc)
            (set-process-coding-system proc 'binary 'binary)
            (set-process-window-size proc 25 80)
            (set-process-query-on-exit-flag proc nil)
            ;; Wait for fish init (may need longer for DA query handshake)
            (dotimes (_ 50) (accept-process-output proc 0.2))
            (should (process-live-p proc))

            ;; Type "abc" then backspace
            (process-send-string proc "abc")
            (dotimes (_ 10) (accept-process-output proc 0.2))
            (let ((state (ghostel-test--rendered-content ghostel--term)))
              (should (string-match-p "abc" state)))

            ;; Send backspace (\x7f) and verify it works
            (process-send-string proc "\x7f")
            (dotimes (_ 10) (accept-process-output proc 0.2))
            (ghostel--flush-pending-output)
            (let ((state (ghostel-test--rendered-content ghostel--term)))
              (should (string-match-p "ab" state))
              (should-not (string-match-p "abc" state)))

            (delete-process proc)))
      (kill-buffer buf))))

;; -----------------------------------------------------------------------
;; Test: update-directory
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-update-directory ()
  "Test OSC 7 directory tracking helper."
  (let* ((ghostel--last-directory nil)
         (dir (file-name-as-directory default-directory))
         (file-url
          (concat "file://"
                  (if (eq system-type 'windows-nt)
                      (concat "/" (replace-regexp-in-string "\\\\" "/"
                                                             (directory-file-name dir)))
                    (directory-file-name dir))))
         (default-directory default-directory))
    (ghostel--update-directory dir)
    (should (equal dir default-directory))                ; plain path
    (ghostel--update-directory file-url)
    (should (equal dir default-directory))                ; file URL
    ;; Dedup: same path shouldn't re-trigger
    (let ((old ghostel--last-directory))
      (ghostel--update-directory file-url)
      (should (equal old ghostel--last-directory)))))       ; dedup

;; -----------------------------------------------------------------------
;; Test: OSC 52 clipboard
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-osc52 ()
  "Test OSC 52 clipboard handling."
  (let ((term (ghostel--new 25 80 1000)))
    ;; With osc52 disabled, kill ring should not be modified
    (let ((ghostel-enable-osc52 nil)
          (kill-ring nil))
      (ghostel--write-input term "\e]52;c;aGVsbG8=\e\\")  ; "hello" in base64
      (should (equal nil kill-ring)))                       ; osc52 disabled: no kill

    ;; With osc52 enabled, text should appear in kill ring
    (let ((ghostel-enable-osc52 t)
          (kill-ring nil))
      (ghostel--write-input term "\e]52;c;aGVsbG8=\e\\")
      (should (> (length kill-ring) 0))                     ; kill ring has entry
      (when kill-ring
        (should (equal "hello" (car kill-ring)))))          ; decoded text

    ;; BEL terminator
    (let ((ghostel-enable-osc52 t)
          (kill-ring nil))
      (ghostel--write-input term "\e]52;c;d29ybGQ=\a")
      (when kill-ring
        (should (equal "world" (car kill-ring)))))          ; osc52 BEL terminator

    ;; Query ('?') should be ignored
    (let ((ghostel-enable-osc52 t)
          (kill-ring nil))
      (ghostel--write-input term "\e]52;c;?\e\\")
      (should (equal nil kill-ring)))))                     ; osc52 query ignored

;; -----------------------------------------------------------------------
;; Test: focus events gated by mode 1004
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-focus-events ()
  "Test that focus events are only sent when mode 1004 is enabled."
  (let ((term (ghostel--new 25 80 1000)))
    (should (equal nil (ghostel--focus-event term t)))     ; focus ignored without mode 1004
    ;; Enable mode 1004 via DECSET
    (ghostel--write-input term "\e[?1004h")
    (should (equal t (ghostel--focus-event term t)))       ; focus sent with mode 1004
    (should (equal t (ghostel--focus-event term nil)))     ; focus-out sent with mode 1004
    ;; Disable mode 1004 via DECRST
    (ghostel--write-input term "\e[?1004l")
    (should (equal nil (ghostel--focus-event term t)))))   ; focus ignored after reset

;; -----------------------------------------------------------------------
;; Test: incremental (partial) redraw
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-incremental-redraw ()
  "Test that incremental redraw correctly updates dirty rows."
  (let ((buf (generate-new-buffer " *ghostel-test-redraw*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            (ghostel--write-input term "line-A\r\nline-B\r\nline-C")
            (ghostel--redraw term)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "line-A" content))   ; initial row0
              (should (string-match-p "line-B" content))   ; initial row1
              (should (string-match-p "line-C" content)))  ; initial row2

            ;; Write more text on row 2 — only that row should be dirty
            (ghostel--write-input term " updated")
            (ghostel--redraw term)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "line-A" content))       ; row0 preserved
              (should (string-match-p "line-B" content))       ; row1 preserved
              (should (string-match-p "line-C updated" content))) ; row2 updated

            (should (equal 5 (count-lines (point-min) (point-max)))))) ; line count
      (kill-buffer buf))))

;; -----------------------------------------------------------------------
;; Test: soft-wrap newline filtering in copy mode
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-soft-wrap-copy ()
  "Test that soft-wrapped newlines are filtered during copy."
  (let ((buf (generate-new-buffer " *ghostel-test-wrap*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 20 100))
                 (inhibit-read-only t))
            ;; Write a line longer than 20 columns — should soft-wrap
            (ghostel--write-input term "ABCDEFGHIJKLMNOPQRSTUVWXYZ")
            (ghostel--redraw term)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "ABCDEFGHIJKLMNOPQRST\n" content))) ; wrapped content has newline
            ;; The newline at the wrap point should have ghostel-wrap property
            (goto-char (point-min))
            (let ((nl-pos (search-forward "\n" nil t)))
              (should nl-pos)                              ; wrap newline exists
              (when nl-pos
                (should (get-text-property (1- nl-pos) 'ghostel-wrap)))) ; ghostel-wrap property set
            ;; Test the filter function
            (let* ((raw (buffer-substring (point-min) (point-max)))
                   (filtered (ghostel--filter-soft-wraps raw)))
              (should-not (string-match-p "\n" (substring filtered 0 26)))))) ; filtered has no wrapped newline
      (kill-buffer buf))))

;; -----------------------------------------------------------------------
;; Test: ghostel--filter-soft-wraps pure function
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-filter-soft-wraps ()
  "Test the soft-wrap filter on synthetic propertized strings."
  ;; String with a wrapped newline
  (let ((s (concat "hello" (propertize "\n" 'ghostel-wrap t) "world")))
    (should (equal "helloworld" (ghostel--filter-soft-wraps s)))) ; removes wrapped newline
  ;; String with a real (non-wrapped) newline
  (let ((s "hello\nworld"))
    (should (equal "hello\nworld" (ghostel--filter-soft-wraps s)))) ; keeps real newline
  ;; Mixed
  (let ((s (concat "aaa" (propertize "\n" 'ghostel-wrap t) "bbb\nccc")))
    (should (equal "aaabbb\nccc" (ghostel--filter-soft-wraps s))))) ; mixed newlines

;; -----------------------------------------------------------------------
;; Test: ANSI color palette customization
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-color-palette ()
  "Test setting a custom ANSI color palette via faces."
  (let ((buf (generate-new-buffer " *ghostel-test-palette*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            ;; Set palette index 1 (red) to a known color via set-palette
            (let ((rest (apply #'concat (make-list 14 "#000000"))))
              (ghostel--set-palette term
                                    (concat "#000000" "#ff0000" rest)))
            ;; Write red text (SGR 31 = ANSI red = palette index 1)
            (ghostel--write-input term "\e[31mRED\e[0m")
            (ghostel--redraw term)
            (should (string-match-p "RED"                  ; red text rendered
                                    (buffer-substring-no-properties
                                     (point-min) (point-max))))
            ;; Check that the face property uses our custom red
            (goto-char (point-min))
            (let ((face (get-text-property (point) 'face)))
              (should face)                                ; face property exists
              (when face
                (let ((fg (plist-get face :foreground)))
                  (should (and fg (string= fg "#ff0000"))))))))  ; foreground is custom red
      (kill-buffer buf))))

(ert-deftest ghostel-test-apply-palette ()
  "Test the face-based apply-palette helper."
  (let ((term (ghostel--new 5 40 100)))
    (should (ghostel--apply-palette term)))                ; apply-palette succeeds

  ;; Test face-hex-color extraction
  (let ((color (ghostel--face-hex-color 'ghostel-color-red :foreground)))
    (should (and (stringp color)                           ; face color is hex string
                 (string-prefix-p "#" color)
                 (= (length color) 7)))))

(ert-deftest ghostel-test-hyperlinks ()
  "Test hyperlink keymap and helpers."
  (should (keymapp ghostel-link-map))                      ; ghostel-link-map is a keymap
  (should (lookup-key ghostel-link-map [mouse-1]))         ; mouse-1 bound in link map
  (should (lookup-key ghostel-link-map (kbd "RET")))       ; RET bound in link map
  (should (commandp #'ghostel-open-link-at-point))         ; open-link-at-point is interactive
  ;; Test that help-echo property is read correctly
  (with-temp-buffer
    (insert "click here")
    (put-text-property 1 11 'help-echo "https://example.com")
    (goto-char 5)
    (should (equal "https://example.com"                   ; help-echo at point
                   (get-text-property (point) 'help-echo))))
  (should (null (ghostel--open-link nil)))                 ; open-link returns nil for empty
  (should (null (ghostel--open-link 42))))                 ; open-link returns nil for non-string

(ert-deftest ghostel-test-url-detection ()
  "Test automatic URL detection in plain text."
  ;; Basic URL detection
  (with-temp-buffer
    (insert "Visit https://example.com for info")
    (let ((ghostel-enable-url-detection t))
      (ghostel--detect-urls))
    (should (equal "https://example.com"                   ; url help-echo
                   (get-text-property 7 'help-echo)))
    (should (get-text-property 7 'mouse-face))             ; url mouse-face
    (should (get-text-property 7 'keymap)))                ; url keymap
  ;; Disabled detection
  (with-temp-buffer
    (insert "Visit https://example.com for info")
    (let ((ghostel-enable-url-detection nil))
      (ghostel--detect-urls))
    (should (null (get-text-property 7 'help-echo))))      ; url detection disabled
  ;; Skips existing OSC 8 links
  (with-temp-buffer
    (insert "Visit https://other.com for info")
    (put-text-property 7 26 'help-echo "https://osc8.example.com")
    (let ((ghostel-enable-url-detection t))
      (ghostel--detect-urls))
    (should (equal "https://osc8.example.com"              ; osc8 link preserved
                   (get-text-property 7 'help-echo))))
  ;; URL not ending in punctuation
  (with-temp-buffer
    (insert "See https://example.com/path.")
    (let ((ghostel-enable-url-detection t))
      (ghostel--detect-urls))
    (should (equal "https://example.com/path"              ; url strips trailing dot
                   (get-text-property 5 'help-echo))))
  ;; File:line detection with absolute path
  (let ((test-file (expand-file-name "ghostel.el"
                                     (file-name-directory (or load-file-name default-directory)))))
    (with-temp-buffer
      (insert (format "Error at %s:42 bad" test-file))
      (let ((ghostel-enable-url-detection t))
        (ghostel--detect-urls))
      (let ((he (get-text-property 10 'help-echo)))
        (should (and he (string-prefix-p "fileref:" he)))  ; file:line help-echo set
        (should (and he (string-suffix-p ":42" he)))))     ; file:line contains line number
    ;; File:line for non-existent file produces no link
    (with-temp-buffer
      (insert "Error at /no/such/file.el:10 bad")
      (let ((ghostel-enable-url-detection t))
        (ghostel--detect-urls))
      (should (null (get-text-property 10 'help-echo))))   ; nonexistent file: no help-echo
    ;; File detection disabled
    (with-temp-buffer
      (insert (format "Error at %s:42 bad" test-file))
      (let ((ghostel-enable-url-detection t)
            (ghostel-enable-file-detection nil))
        (ghostel--detect-urls))
      (should (null (get-text-property 10 'help-echo))))   ; file detection disabled
    ;; ghostel--open-link dispatches fileref:
    (let ((opened nil))
        (cl-letf (((symbol-function 'find-file-other-window)
                   (lambda (f) (setq opened f))))
          (ghostel--open-link (format "fileref:%s:10" test-file)))
       (should (equal test-file opened)))))                 ; fileref opens correct file

(ert-deftest ghostel-test-url-detection-respects-bounds ()
  "Test that URL detection can be restricted to a region."
  (with-temp-buffer
    (insert "before https://before.example\n"
            "middle https://middle.example\n"
            "after https://after.example")
    (let ((ghostel-enable-url-detection t))
      (save-excursion
        (goto-char (point-min))
        (forward-line 1)
        (ghostel--detect-urls (line-beginning-position) (line-end-position))))
    (should-not (get-text-property 8 'help-echo))
    (save-excursion
      (goto-char (point-min))
      (forward-line 1)
      (should (equal "https://middle.example"
                     (get-text-property (+ (line-beginning-position) 8) 'help-echo))))
    (save-excursion
      (goto-char (point-min))
      (forward-line 2)
      (should-not (get-text-property (+ (line-beginning-position) 7) 'help-echo)))))

;; -----------------------------------------------------------------------
;; Test: OSC 133 prompt marker parsing
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-osc133-parsing ()
  "Test that OSC 133 sequences are detected and the callback fires."
  (let ((term (ghostel--new 25 80 1000))
        (markers nil))
    (cl-letf (((symbol-function 'ghostel--osc133-marker)
               (lambda (type param) (push (cons type param) markers))))
      (ghostel--write-input term "\e]133;A\e\\")
      (should (assoc "A" markers))                         ; 133;A detected

      (ghostel--write-input term "\e]133;B\a")
      (should (assoc "B" markers))                         ; 133;B detected

      (ghostel--write-input term "\e]133;C\e\\")
      (should (assoc "C" markers))                         ; 133;C detected

      (ghostel--write-input term "\e]133;D;0\e\\")
      (let ((d-entry (assoc "D" markers)))
        (should d-entry)                                   ; 133;D detected
        (should (equal "0" (cdr d-entry))))                ; 133;D param is exit code

      ;; Non-zero exit
      (setq markers nil)
      (ghostel--write-input term "\e]133;D;1\e\\")
      (let ((d-entry (assoc "D" markers)))
        (should (equal "1" (cdr d-entry))))                ; 133;D non-zero exit

      ;; Mixed with other output
      (setq markers nil)
      (ghostel--write-input term "hello\e]133;A\e\\world\e]133;B\e\\")
      (should (assoc "A" markers))                         ; 133;A in mixed stream
      (should (assoc "B" markers)))))                      ; 133;B in mixed stream

;; -----------------------------------------------------------------------
;; Test: OSC 133 prompt text properties
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-osc133-text-properties ()
  "Test that prompt markers set ghostel-prompt text property."
  (let ((buf (generate-new-buffer " *ghostel-test-osc133*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t)
                 (ghostel--prompt-positions nil))
            ;; Simulate a prompt: A, prompt text, B, command, output, D
            (ghostel--write-input term "\e]133;A\e\\")
            (ghostel--write-input term "$ ")
            (ghostel--redraw term)
            (ghostel--write-input term "\e]133;B\e\\")
            (ghostel--write-input term "echo hi\r\n")
            (ghostel--write-input term "hi\r\n")
            (ghostel--write-input term "\e]133;D;0\e\\")
            (ghostel--redraw term)

            (goto-char (point-min))
            (should (text-property-any (point-min) (point-max)
                                       'ghostel-prompt t)) ; ghostel-prompt property set

            ;; Property should survive a full redraw
            (ghostel--redraw term)
            (should (text-property-any (point-min) (point-max)
                                       'ghostel-prompt t)) ; ghostel-prompt survives redraw

            (should (> (length ghostel--prompt-positions) 0)) ; prompt-positions has entry

            ;; Check exit status stored
            (when ghostel--prompt-positions
              (should (equal 0 (cdr (car ghostel--prompt-positions))))))) ; exit status stored
      (kill-buffer buf))))

;; -----------------------------------------------------------------------
;; Test: prompt navigation
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-prompt-navigation ()
  "Test next/previous prompt navigation."
  (with-temp-buffer
    ;; Realistic layout: property covers WHOLE row (row-level fallback),
    ;; prompt text is "my-prompt # " followed by user command.
    (let ((p1 (point)))
      (insert "my-prompt # cmd1\n")
      (put-text-property p1 (1- (point)) 'ghostel-prompt t))
    (insert "output1\n")
    (let ((p2 (point)))
      (insert "my-prompt # cmd2\n")
      (put-text-property p2 (1- (point)) 'ghostel-prompt t))
    (insert "output2\n")
    (let ((p3 (point)))
      (insert "my-prompt # cmd3\n")
      (put-text-property p3 (1- (point)) 'ghostel-prompt t))
    (insert "output3\n")

    (goto-char (point-min))

    (ghostel--navigate-next-prompt 1)
    (should (looking-at "cmd2"))                           ; next-prompt lands on cmd2

    (ghostel--navigate-next-prompt 1)
    (should (looking-at "cmd3"))                           ; next-prompt lands on cmd3

    (ghostel--navigate-previous-prompt 1)
    (should (looking-at "cmd2"))                           ; previous-prompt lands on cmd2

    (goto-char (point-max))
    (ghostel--navigate-previous-prompt 1)
    (should (looking-at "cmd3"))                           ; previous from end lands on cmd3

    ;; From inside a prompt, previous should skip to the prior prompt
    (goto-char (point-min))
    (ghostel--navigate-next-prompt 1)       ; prompt 2
    (ghostel--navigate-next-prompt 1)       ; prompt 3
    (forward-char 1)                       ; inside prompt 3's command
    (ghostel--navigate-previous-prompt 1)
    (should (looking-at "cmd2"))))                         ; previous from inside prompt lands on cmd2

;; -----------------------------------------------------------------------
;; Test: resize during sync output (alt screen)
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-resize-sync ()
  "Test that resize between BSU/ESU cycles gives clean content."
  (let ((buf (generate-new-buffer " *ghostel-test-resize-sync*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 10 40 100))
                 (inhibit-read-only t))
            ;; Enter alt screen, write content, cursor at bottom
            (ghostel--write-input term "\e[?1049h")
            (dotimes (i 9) (ghostel--write-input term (format "line %d\r\n" i)))
            (ghostel--write-input term "prompt> ")
            (should (ghostel--mode-enabled term 1049))     ; alt screen enabled
            ;; Simulate a full BSU/ESU cycle (app redraw)
            (ghostel--write-input term "\e[?2026h\e[H\e[2J")
            (dotimes (i 9) (ghostel--write-input term (format "new %d\r\n" i)))
            (ghostel--write-input term "new prompt> ")
            (ghostel--write-input term "\e[?2026l")
            (should-not (ghostel--mode-enabled term 2026)) ; sync off after ESU
            ;; Resize between cycles (sync OFF) — should get clean content
            (ghostel--set-size term 6 40)
            (ghostel--redraw term)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "new prompt>" content)) ; prompt visible after resize
              (should (> (line-number-at-pos) 1))          ; cursor not at top
              (should (equal 6 (count-lines (point-min) (point-max))))) ; correct line count
            ;; Verify: resize DURING BSU gives garbage (cursor at top)
            (ghostel--write-input term "\e[?2026h\e[H\e[2J")
            (ghostel--write-input term "BANNER\r\n")
            (should (ghostel--mode-enabled term 2026))     ; sync on during BSU
            (ghostel--set-size term 5 40)
            (ghostel--redraw term)
            (should (<= (line-number-at-pos) 2))           ; mid-BSU: cursor near top
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should-not (string-match-p "new prompt>" content))))) ; mid-BSU: no prompt
      (kill-buffer buf))))

;; -----------------------------------------------------------------------
;; Test: theme synchronization
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-sync-theme ()
  "Test that ghostel-sync-theme applies palette and redraws ghostel buffers."
  (let ((palette-calls nil)
        (redraw-calls nil))
    (cl-letf (((symbol-function 'ghostel--apply-palette)
               (lambda (term) (push term palette-calls)))
              ((symbol-function 'ghostel--redraw)
               (lambda (term &optional _full) (push term redraw-calls))))
      (let ((buf (generate-new-buffer " *ghostel-test-theme*"))
            (other (generate-new-buffer " *ghostel-test-other*")))
        (unwind-protect
            (progn
              ;; Set up a ghostel-mode buffer with a fake terminal
              (with-current-buffer buf
                (ghostel-mode)
                (setq ghostel--term 'fake-term)
                (setq ghostel--copy-mode-active nil))
              ;; other buffer is not ghostel-mode
              (ghostel-sync-theme)
              (should (memq 'fake-term palette-calls))    ; palette applied to ghostel buffer
              (should (memq 'fake-term redraw-calls))     ; redraw called for ghostel buffer

              ;; Verify copy-mode skips redraw
              (setq palette-calls nil redraw-calls nil)
              (with-current-buffer buf
                (setq ghostel--copy-mode-active t))
              (ghostel-sync-theme)
              (should (memq 'fake-term palette-calls))    ; palette still applied in copy mode
              (should-not (memq 'fake-term redraw-calls))) ; redraw skipped in copy mode
          (kill-buffer buf)
          (kill-buffer other))))))

;; -----------------------------------------------------------------------
;; Test: apply-palette sets default fg/bg from Emacs default face
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-apply-palette-default-colors ()
  "Test that ghostel--apply-palette sets default fg/bg from the Emacs default face."
  (let ((default-colors-calls nil)
        (palette-calls nil))
    (cl-letf (((symbol-function 'ghostel--set-default-colors)
               (lambda (term fg bg)
                 (push (list term fg bg) default-colors-calls)))
              ((symbol-function 'ghostel--set-palette)
               (lambda (term colors) (push (list term colors) palette-calls))))
      ;; With a fake terminal, apply-palette should call set-default-colors
      (ghostel--apply-palette 'fake-term)
      (should (= 1 (length default-colors-calls)))
      (should (eq 'fake-term (car (car default-colors-calls))))
      ;; fg and bg should be hex color strings from the default face
      (let ((fg (nth 1 (car default-colors-calls)))
            (bg (nth 2 (car default-colors-calls))))
        (should (string-prefix-p "#" fg))
        (should (string-prefix-p "#" bg)))
      ;; Palette should also be set
      (should (= 1 (length palette-calls)))
      ;; With nil term, nothing should be called
      (setq default-colors-calls nil palette-calls nil)
      (ghostel--apply-palette nil)
      (should-not default-colors-calls)
      (should-not palette-calls))))

;; -----------------------------------------------------------------------
;; OSC 51 elisp eval
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-osc51-eval ()
  "Test that OSC 51;E dispatches to whitelisted functions."
  (let* ((called-with nil)
         (ghostel-eval-cmds
          `(("test-fn" ,(lambda (&rest args) (setq called-with args))))))
    (ghostel--osc51-eval "\"test-fn\" \"hello\" \"world\"")
    (should (equal '("hello" "world") called-with))))

(ert-deftest ghostel-test-osc51-eval-unknown ()
  "Test that unknown OSC 51;E commands produce a message."
  (let ((ghostel-eval-cmds nil)
        (messages nil))
    (let ((comp-enable-subr-trampolines nil)
          (native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args) (push (apply #'format fmt args) messages))))
        (ghostel--osc51-eval "\"unknown-fn\" \"arg\"")
        (should (car messages))
        (should (string-match-p "unknown eval command" (car messages)))))))

;; -----------------------------------------------------------------------
;; Test: copy-mode cursor visibility
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-copy-mode-cursor ()
  "Test that copy-mode restores cursor visibility when terminal hid it."
  (let ((buf (generate-new-buffer " *ghostel-test-copy-cursor*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          ;; Simulate a terminal app hiding the cursor
          (ghostel--set-cursor-style 1 nil)
          (should (null cursor-type))                       ; cursor hidden
          ;; Enter copy mode — cursor should become visible
          (let ((ghostel--copy-mode-active nil)
                (ghostel--redraw-timer nil))
            (ghostel-copy-mode)
            (should ghostel--copy-mode-active)              ; in copy mode
            (should cursor-type)                            ; cursor visible
            (should (equal cursor-type (default-value 'cursor-type))) ; uses user default
            ;; Exit copy mode — cursor should be hidden again
            (ghostel-copy-mode-exit)
            (should-not ghostel--copy-mode-active)          ; exited copy mode
            (should (null cursor-type))))                   ; cursor hidden again
      (kill-buffer buf))))

;; -----------------------------------------------------------------------
;; Test: ghostel-ignore-cursor-change option
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-set-cursor-style-ignored-when-configured ()
  "Test that ghostel-ignore-cursor-change prevents cursor-type mutations."
  (with-temp-buffer
    (let ((ghostel-ignore-cursor-change t)
          (cursor-type 'box))
      (ghostel--set-cursor-style 0 nil)
      (should (eq cursor-type 'box)))))

(ert-deftest ghostel-test-set-cursor-style-applies-when-not-ignored ()
  "Test that cursor changes still apply when ghostel-ignore-cursor-change is nil."
  (with-temp-buffer
    (let ((ghostel-ignore-cursor-change nil)
          (cursor-type 'box))
      (ghostel--set-cursor-style 0 nil)
      (should (null cursor-type)))))

(ert-deftest ghostel-test-copy-mode-cursor-overrides-ignored-terminal-cursor ()
  "Test that copy mode still forces a visible cursor even with ignore enabled."
  (let ((buf (generate-new-buffer " *ghostel-test-copy-ignore*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel-ignore-cursor-change t))
            (setq cursor-type 'box)
            (ghostel--set-cursor-style 2 nil)
            (should (eq cursor-type 'box))           ; ignore: still box
            (let ((ghostel--copy-mode-active nil)
                  (ghostel--redraw-timer nil))
              (ghostel-copy-mode)
              (should cursor-type)                   ; copy mode: visible
              (should (equal cursor-type (default-value 'cursor-type))) ; uses user default
              (ghostel-copy-mode-exit)
              (should (eq cursor-type 'box)))))      ; restored to box
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

;; -----------------------------------------------------------------------
;; Test: copy-mode hl-line-mode management
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-copy-mode-hl-line ()
  "Test that global-hl-line-mode is suppressed and hl-line restored in copy-mode."
  (let ((buf (generate-new-buffer " *ghostel-test-hl-line*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (require 'hl-line)
          ;; Simulate global-hl-line-mode being active
          (let ((global-hl-line-mode t))
            (should global-hl-line-mode)
            ;; Suppress should opt this buffer out
            (ghostel--suppress-interfering-modes)
            (should ghostel--saved-hl-line-mode)
            ;; Buffer-local global-hl-line-mode must be nil — this is the
            ;; mechanism that prevents global-hl-line-highlight (on
            ;; post-command-hook) from creating overlays in this buffer.
            (should-not global-hl-line-mode))
          ;; Enter copy mode — local hl-line-mode should be enabled
          (let ((ghostel--copy-mode-active nil)
                (ghostel--redraw-timer nil))
            (ghostel-copy-mode)
            (should (bound-and-true-p hl-line-mode))
            ;; Exit copy mode — local hl-line-mode disabled again
            (ghostel-copy-mode-exit)
            (should-not (bound-and-true-p hl-line-mode))))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (kill-local-variable 'global-hl-line-mode))
        (kill-buffer buf)))))

(ert-deftest ghostel-test-copy-mode-uses-mode-line-process ()
  "Copy mode uses `mode-line-process' instead of mutating `mode-name'."
  (let ((buf (generate-new-buffer " *ghostel-test-mode-line*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--copy-mode-active nil)
                (ghostel--redraw-timer nil))
            (ghostel-copy-mode)
            (should (equal ":Copy" mode-line-process))
            (should (equal "Ghostel" mode-name))
            (ghostel-copy-mode-exit)
            (should-not mode-line-process)
            (should (equal "Ghostel" mode-name))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ghostel-test-suppress-interfering-modes-disables-pixel-scroll ()
  "Ghostel disables pixel-scroll precision in terminal buffers."
  (let ((buf (generate-new-buffer " *ghostel-test-pixel-scroll*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq-local pixel-scroll-precision-mode t)
          (ghostel--suppress-interfering-modes)
          (should-not pixel-scroll-precision-mode))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ghostel-test-ghostel-reuses-default-buffer ()
  "Calling `ghostel' without a prefix reuses the default terminal buffer."
  (let ((ghostel-buffer-name "*ghostel*")
        (displayed nil)
        (started 0)
        (buf (generate-new-buffer "*ghostel*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (ghostel-mode)
            (setq-local ghostel--term 'term-1))
          (cl-letf (((symbol-function 'ghostel--new)
                     (lambda (&rest _) 'unused))
                    ((symbol-function 'ghostel--apply-palette)
                     (lambda (&rest _) nil))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (buffer-or-name &rest _)
                        (setq displayed (get-buffer buffer-or-name))
                        (set-buffer displayed)
                        displayed))
                    ((symbol-function 'ghostel--start-process)
                     (lambda ()
                       (setq started (1+ started)))))
            (ghostel)
            (should (eq buf displayed))
            (should (equal 0 started))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ghostel-test-ghostel-clamps-initial-terminal-size-to-window-max-chars-minus-one ()
  "Initial terminal creation should use one less than `window-max-chars-per-line'."
  (let ((ghostel-buffer-name "*ghostel-size*")
        (created-size nil)
        (buf nil))
    (unwind-protect
        (cl-letf (((symbol-function 'window-body-height)
                   (lambda (&optional _) 33))
                  ((symbol-function 'window-body-width)
                   (lambda (&optional _window _pixelwise) 80))
                  ((symbol-function 'window-max-chars-per-line)
                   (lambda (&optional _) 120))
                  ((symbol-function 'ghostel--new)
                   (lambda (height width _scrollback)
                     (setq created-size (list height width))
                     'fake-term))
                  ((symbol-function 'ghostel--apply-palette)
                   (lambda (&rest _) nil))
                  ((symbol-function 'ghostel--start-process)
                   (lambda () 'fake-proc))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (buffer-or-name &rest _)
                      (setq buf (get-buffer buffer-or-name))
                      (set-buffer buf)
                      buf)))
          (ghostel)
          (should (equal '(32 119) created-size)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ghostel-test-project-buffer-name ()
  "Test that `ghostel-project' derives the buffer name correctly."
  (require 'project)
  (let ((ghostel-buffer-name "*ghostel*")
        result)
    (cl-letf (((symbol-function 'project-current)
               (lambda (_maybe-prompt) '(transient . "/tmp/myproj/")))
              ((symbol-function 'project-root)
               (lambda (proj) (cdr proj)))
              ((symbol-function 'project-prefixed-buffer-name)
               (lambda (name) (format "*myproj-%s*" name)))
              ((symbol-function 'ghostel)
               (lambda (&optional _)
                 (setq result (cons default-directory ghostel-buffer-name)))))
      (ghostel-project)
      (should (equal "/tmp/myproj/" (car result)))
      (should (string-match-p "ghostel" (cdr result)))
      (should-not (string-match-p "\\*\\*" (cdr result))))))

(ert-deftest ghostel-test-project-universal-arg ()
  "Test that `ghostel-project' passes the universal arg to `ghostel'."
  (require 'project)
  (let ((ghostel-buffer-name "*ghostel*")
        (current-prefix-arg '4)
        result)
    (cl-letf (((symbol-function 'project-current)
               (lambda (_maybe-prompt) '(transient . "/tmp/myproj/")))
              ((symbol-function 'project-root)
               (lambda (proj) (cdr proj)))
              ((symbol-function 'project-prefixed-buffer-name)
               (lambda (name) (format "*myproj-%s*" name)))
              ((symbol-function 'ghostel)
               (lambda (&optional arg)
                 (setq result arg))))
      (ghostel-project current-prefix-arg)
      (should (equal '4 result)))))

(ert-deftest ghostel-test-set-buffer-face-skips-unchanged-colors ()
  "Test that repeated identical default colors do not remap again."
  (with-temp-buffer
    (let ((ghostel--face-cookie nil)
          (added 0)
          (removed 0))
      (cl-letf (((symbol-function 'face-remap-add-relative)
                 (lambda (&rest _)
                   (setq added (1+ added))
                   'cookie))
                ((symbol-function 'face-remap-remove-relative)
                 (lambda (&rest _)
                   (setq removed (1+ removed)))))
        (ghostel--set-buffer-face "#112233" "#445566")
        (ghostel--set-buffer-face "#112233" "#445566")
        (should (= added 1))
        (should (= removed 0))))))

;; -----------------------------------------------------------------------
;; Runner
;; -----------------------------------------------------------------------

;; -----------------------------------------------------------------------
;; Test: module version check
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-module-version-match ()
  "Test that version check does nothing when module meets minimum."
  (let ((warned nil)
        (ghostel--minimum-module-version "0.2"))
    (cl-letf (((symbol-function 'ghostel--module-version)
               (lambda () "0.2"))
              ((symbol-function 'display-warning)
               (lambda (&rest _) (setq warned t))))
      (ghostel--check-module-version "/tmp")
      (should-not warned))))

(ert-deftest ghostel-test-module-version-mismatch ()
  "Test that version check warns when module is below minimum."
  (let ((warned nil)
        (ensure-called nil)
        (noninteractive nil)
        (ghostel--minimum-module-version "0.2"))
    (cl-letf (((symbol-function 'ghostel--module-version)
               (lambda () "0.1"))
              ((symbol-function 'display-warning)
               (lambda (&rest _) (setq warned t)))
              ((symbol-function 'ghostel--ensure-module)
               (lambda (dir) (setq ensure-called dir))))
      (ghostel--check-module-version "/tmp")
      (should warned)
      (should (equal "/tmp" ensure-called)))))

(ert-deftest ghostel-test-module-version-newer-than-minimum ()
  "Test that version check does nothing when module exceeds minimum."
  (let ((warned nil)
        (ghostel--minimum-module-version "0.2"))
    (cl-letf (((symbol-function 'ghostel--module-version)
               (lambda () "0.3"))
              ((symbol-function 'display-warning)
               (lambda (&rest _) (setq warned t))))
      (ghostel--check-module-version "/tmp")
      (should-not warned))))

(ert-deftest ghostel-test-module-platform-tag-windows ()
  "Windows builds use the release tag format expected by Ghostel assets."
  (let ((system-type 'windows-nt)
        (system-configuration "x86_64-w64-mingw32"))
    (should (equal "x86_64-windows"
                   (ghostel--module-platform-tag)))))

(ert-deftest ghostel-test-module-asset-name-windows ()
  "Windows module assets use the Windows platform tag in their file name."
  (let ((system-type 'windows-nt)
        (system-configuration "x86_64-w64-mingw32")
        (module-file-suffix ".dll"))
    (should (equal "ghostel-module-x86_64-windows.tar.xz"
                   (ghostel--module-asset-name)))))

(ert-deftest ghostel-test-start-process-windows-conpty-skips-shell-wrapper ()
  "Windows ConPTY startup passes the shell directly."
  (with-temp-buffer
    (let ((system-type 'windows-nt)
          (ghostel-shell "C:/Program Files/Emacs/cmdproxy.exe")
          (ghostel-shell-integration nil)
          (default-directory "C:/ghostel/")
          (ghostel--term 'fake-term)
          (captured-command nil))
      (let ((comp-enable-subr-trampolines nil)
            (native-comp-enable-subr-trampolines nil))
        (cl-letf (((symbol-function 'window-body-height)
                   (lambda (&optional _) 33))
                  ((symbol-function 'window-max-chars-per-line)
                   (lambda (&optional _) 80))
                  ((symbol-function 'locate-library)
                   (lambda (_) "C:/ghostel/ghostel.el"))
                  ((symbol-function 'make-pipe-process)
                   (lambda (&rest _) 'fake-proc))
                  ((symbol-function 'process-put)
                   (lambda (&rest _) nil))
                  ((symbol-function 'set-process-query-on-exit-flag)
                   (lambda (&rest _) nil))
                  ((symbol-function 'conpty--init)
                   (lambda (_term _proc command _rows _cols _cwd _env)
                     (setq captured-command command)
                     t)))
           (should (eq 'fake-proc (ghostel--start-process)))
           (should (equal ghostel-shell captured-command))
           (should-not (string-match-p "/bin/sh" captured-command)))))))

(ert-deftest ghostel-test-start-process-clamps-terminal-size-to-window-max-chars-minus-one ()
  "Process startup should use one less than `window-max-chars-per-line'."
  (with-temp-buffer
    (let ((system-type 'windows-nt)
          (ghostel-shell "C:/Windows/System32/cmd.exe")
          (ghostel-shell-integration nil)
          (default-directory "C:/ghostel/")
          (ghostel--term 'fake-term)
          (captured-size nil))
      (let ((comp-enable-subr-trampolines nil)
            (native-comp-enable-subr-trampolines nil))
        (cl-letf (((symbol-function 'window-body-height)
                   (lambda (&optional _) 33))
                  ((symbol-function 'window-body-width)
                   (lambda (&optional _window _pixelwise) 80))
                  ((symbol-function 'window-max-chars-per-line)
                   (lambda (&optional _) 120))
                  ((symbol-function 'locate-library)
                   (lambda (_) "C:/ghostel/ghostel.el"))
                  ((symbol-function 'make-pipe-process)
                   (lambda (&rest _) 'fake-proc))
                  ((symbol-function 'process-put)
                   (lambda (&rest _) nil))
                  ((symbol-function 'set-process-query-on-exit-flag)
                   (lambda (&rest _) nil))
                  ((symbol-function 'conpty--init)
                   (lambda (_term _proc _command rows cols _cwd _env)
                     (setq captured-size (list rows cols))
                     t)))
          (should (eq 'fake-proc (ghostel--start-process)))
          (should (equal '(32 119) captured-size)))))))

(ert-deftest ghostel-test-conpty-init-keeps-shell-alive-on-windows ()
  "Windows ConPTY init should keep the shell alive long enough to emit a prompt."
  (skip-unless (eq system-type 'windows-nt))
  (unless (fboundp 'conpty--init)
    (should (ghostel--load-module-if-available (ghostel--effective-module-dir))))
  (skip-unless (and (fboundp 'conpty--init)
                    (fboundp 'conpty--is-alive)
                    (fboundp 'conpty--read-pending)))
  (with-temp-buffer
    (let* ((rows 24)
           (cols 80)
           (term (ghostel--new rows cols 1000))
           (proc (make-pipe-process
                  :name "ghostel-test-conpty"
                  :buffer (current-buffer)
                  :filter (lambda (&rest _))
                  :sentinel (lambda (&rest _))
                  :noquery t
                  :coding 'binary))
           (cmd (or (getenv "COMSPEC") shell-file-name))
           (cwd (expand-file-name default-directory)))
      (unwind-protect
          (progn
            (should (conpty--init term proc cmd rows cols cwd nil))
            (should (conpty--is-alive term))
            (sleep-for 0.2)
            (should (conpty--is-alive term))
            (let ((pending (conpty--read-pending term)))
              (should (and pending (> (length pending) 0)))))
        (when (process-live-p proc)
          (delete-process proc))))))

(ert-deftest ghostel-test-module-download-url-uses-minimum-version ()
  "Module downloads pin to the minimum supported native module version."
  (let ((ghostel-github-release-url "https://example.invalid/releases")
        (ghostel--minimum-module-version "0.7.1"))
    (cl-letf (((symbol-function 'ghostel--module-asset-name)
               (lambda () "ghostel-module-x86_64-windows.tar.xz")))
      (should (equal "https://example.invalid/releases/download/v0.7.1/ghostel-module-x86_64-windows.tar.xz"
                     (ghostel--module-download-url ghostel--minimum-module-version))))))

(ert-deftest ghostel-test-download-module-prefix-empty-uses-latest ()
  "Prefix download prompts for a version and treats blank input as latest."
  (let ((captured-version :unset)
        (captured-latest nil)
        (bootstrapped nil))
    (let ((comp-enable-subr-trampolines nil)
          (native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'file-exists-p)
                 (lambda (_) nil))
                ((symbol-function 'read-string)
                 (lambda (&rest _) ""))
                 ((symbol-function 'ghostel--download-module)
                  (lambda (_dir &optional version latest-release)
                    (setq captured-version version)
                    (setq captured-latest latest-release)
                    t))
                 ((symbol-function 'ghostel--bootstrap-module)
                  (lambda (&optional _dir)
                    (setq bootstrapped t)
                    t))
                 ((symbol-function 'ghostel--ensure-loader-loaded)
                  (lambda (&optional _path) t))
                 ((symbol-function 'ghostel--check-module-version)
                  (lambda (&optional _dir) t))
                 ((symbol-function 'message)
                  (lambda (&rest _))))
        (ghostel-download-module '(4))
        (should (null captured-version))
        (should captured-latest)
        (should bootstrapped)))))

(ert-deftest ghostel-test-download-module-prefix-rejects-too-old-version ()
  "Prefix download rejects versions below the minimum supported module version."
  (let ((ghostel--minimum-module-version "0.7.1"))
    (let ((comp-enable-subr-trampolines nil)
          (native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'file-exists-p)
                 (lambda (_) nil))
                ((symbol-function 'read-string)
                 (lambda (&rest _) "0.7.0")))
        (should-error (ghostel-download-module '(4))
                      :type 'user-error)))))

(ert-deftest ghostel-test-target-module-file-path-uses-custom-dir ()
  "Custom module directories override the default target module path."
  (let* ((module-dir (ghostel-test--fixture-dir "ghostel-modules"))
         (ghostel-module-dir module-dir)
         (module-file-suffix ".dll"))
    (should (equal (downcase (ghostel-test--fixture-path module-dir "ghostel-module.dll"))
                   (downcase (ghostel--target-module-file-path))))))

(ert-deftest ghostel-test-download-module-publishes-target-module-path ()
  "Module downloads publish dyn-loader-module, ghostel-module, and loader metadata."
  (let* ((module-dir (ghostel-test--fixture-dir "ghostel-modules"))
         (source-dir (ghostel-test--fixture-dir "ghostel-build"))
         (archive (ghostel-test--fixture-path source-dir "ghostel-module-x86_64-windows.tar.xz"))
         (ghostel-module-dir module-dir)
         (module-file-suffix ".dll")
         (download-dest nil)
         (metadata-writes nil)
         (renamed nil))
    (cl-letf (((symbol-function 'ghostel--module-download-url)
               (lambda (&optional _version)
                  "https://example.invalid/releases/download/v0.7.1/ghostel-module-x86_64-windows.tar.xz"))
               ((symbol-function 'ghostel--download-file)
                (lambda (_url dest)
                   (setq download-dest dest)
                   t))
              ((symbol-function 'ghostel--publish-downloaded-module-archive)
               (lambda (archive dir)
                 (setq renamed (list archive dir))
                  (ghostel--write-loader-metadata-atomically
                   dir
                   '((loader_abi . 1)
                     (module_path . "ghostel-module.dll")))
                  "ghostel-module.dll"))
              ((symbol-function 'ghostel--write-loader-metadata-atomically)
               (lambda (dir metadata)
                 (push (list dir metadata) metadata-writes))))
      (should (ghostel--download-module source-dir))
      (should (equal (downcase archive)
                     (downcase download-dest)))
      (should (equal (list (downcase archive)
                           (downcase source-dir))
                     (list (downcase (car renamed))
                           (downcase (cadr renamed)))))
      (pcase-let ((`(,dir ,metadata) (car metadata-writes)))
        (should (equal (downcase source-dir) (downcase dir)))
        (should (equal 1 (alist-get 'loader_abi metadata)))
        (should (equal "ghostel-module.dll"
                       (alist-get 'module_path metadata)))))))

(ert-deftest ghostel-test-extract-module-archive-uses-tar-xf ()
  "Downloaded module archives are unpacked with tar."
  (let ((invocation nil))
    (cl-letf (((symbol-function 'process-file)
               (lambda (program infile buffer display &rest args)
                 (setq invocation (list program infile buffer display args))
                 0)))
      (ghostel--extract-module-archive "C:/ghostel/ghostel-module-x86_64-windows.tar.xz"
                                       "C:/ghostel/staging/")
      (should (equal '("tar" nil "*ghostel-download*" nil
                       ("xf" "C:/ghostel/ghostel-module-x86_64-windows.tar.xz"
                        "-C" "C:/ghostel/staging/"))
                      invocation)))))

(ert-deftest ghostel-test-replace-module-file-deletes-before-rotating ()
  "Replacement deletes DEST first and only rotates when delete fails."
  (let* ((src "C:/ghostel/build/ghostel-module.dll")
         (dest "C:/ghostel/live/ghostel-module.dll")
         (backup (concat dest ".bak"))
         (deletes nil)
         (renames nil)
         (copies nil)
         (system-type 'gnu/linux))
    (ghostel-test--without-subr-trampolines
      (cl-letf (((symbol-function 'file-exists-p)
                 (lambda (path)
                   (member (downcase path)
                           (list (downcase dest)
                                 (downcase backup)))))
                ((symbol-function 'delete-file)
                 (lambda (path &optional _trash)
                   (push path deletes)
                   (signal 'file-error (list "in use" path))))
                ((symbol-function 'rename-file)
                 (lambda (from to &optional ok-if-already-exists)
                   (push (list from to ok-if-already-exists) renames)))
                ((symbol-function 'copy-file)
                 (lambda (from to &optional ok-if-already-exists)
                   (push (list from to ok-if-already-exists) copies))))
        (ghostel--replace-module-file src dest)
        (should (equal (list dest) deletes))
        (should (equal (list (list dest (concat dest ".1.bak") t)) renames))
        (should (equal (list (list src dest t)) copies))))))

(ert-deftest ghostel-test-publish-downloaded-module-archive-preserves-existing-windows-backups ()
  "Downloading on Windows uses a fresh .bak name when an older backup remains."
  (let* ((archive "C:/ghostel/ghostel-module-x86_64-windows.tar.xz")
         (staging-dir (ghostel-test--fixture-dir "ghostel-staging"))
         (module-dir (ghostel-test--fixture-dir "ghostel-modules"))
         (loader-src (ghostel-test--fixture-path staging-dir "dyn-loader-module.dll"))
         (target-src (ghostel-test--fixture-path staging-dir "ghostel-module.dll"))
         (conpty-src (ghostel-test--fixture-path staging-dir "conpty-module.dll"))
         (loader-dest (ghostel-test--fixture-path module-dir "dyn-loader-module.dll"))
         (target-dest (ghostel-test--fixture-path module-dir "ghostel-module.dll"))
         (conpty-dest (ghostel-test--fixture-path module-dir "conpty-module.dll"))
         (loader-backup (concat loader-dest ".bak"))
         (target-backup (concat target-dest ".bak"))
         (conpty-backup (concat conpty-dest ".bak"))
         (system-type 'windows-nt)
         (ghostel-module-dir module-dir)
         (module-file-suffix ".dll")
         (extracted nil)
         (deletes nil)
         (renames nil)
         (copies nil)
         (metadata-writes nil)
         (cleaned nil))
    (ghostel-test--without-subr-trampolines
      (cl-letf (((symbol-function 'make-temp-file)
                 (lambda (_prefix &optional _dir-flag)
                   staging-dir))
                ((symbol-function 'ghostel--extract-module-archive)
                 (lambda (actual-archive actual-dir)
                   (setq extracted (list actual-archive actual-dir))))
                ((symbol-function 'file-exists-p)
                 (lambda (path)
                   (member (downcase path)
                           (list (downcase loader-src)
                                 (downcase target-src)
                                 (downcase conpty-src)
                                 (downcase loader-dest)
                                 (downcase target-dest)
                                 (downcase conpty-dest)
                                 (downcase loader-backup)
                                 (downcase target-backup)
                                 (downcase conpty-backup)))))
                ((symbol-function 'file-directory-p)
                 (lambda (path)
                   (member (downcase path)
                           (list (downcase staging-dir)
                                 (downcase module-dir)))))
                ((symbol-function 'delete-file)
                 (lambda (path &optional _trash)
                   (push path deletes)
                   (signal 'file-error (list "in use" path))))
                ((symbol-function 'rename-file)
                 (lambda (src dest &optional ok-if-already-exists)
                   (push (list src dest ok-if-already-exists) renames)))
                ((symbol-function 'copy-file)
                 (lambda (src dest &optional ok-if-already-exists)
                   (push (list src dest ok-if-already-exists) copies)))
                ((symbol-function 'ghostel--write-loader-metadata-atomically)
                 (lambda (dir metadata)
                   (push (list dir metadata) metadata-writes)))
                ((symbol-function 'delete-directory)
                 (lambda (path recursive)
                   (setq cleaned (list path recursive)))))
        (should (equal "ghostel-module.dll"
                       (ghostel--publish-downloaded-module-archive archive module-dir)))
        (should (equal (list archive staging-dir) extracted))
        (should (equal (list conpty-dest target-dest loader-dest) deletes))
        (should (member (list loader-dest (concat loader-dest ".1.bak") t) renames))
        (should (member (list target-dest (concat target-dest ".1.bak") t) renames))
        (should (member (list conpty-dest (concat conpty-dest ".1.bak") t) renames))
        (should (equal 3 (length copies)))
        (should (equal (list staging-dir t) cleaned))
        (should (equal "ghostel-module.dll"
                       (alist-get 'module_path (cadar metadata-writes))))))))

(ert-deftest ghostel-test-ask-install-action-includes-compile-for-custom-dir ()
  "Missing-module prompts still offer compile for custom module dirs."
  (let ((ghostel-module-dir "C:/modules/")
        (choice nil))
    (cl-letf (((symbol-function 'read-char-choice)
               (lambda (_prompt chars)
                 (setq choice chars)
                 ?c)))
      (should (eq 'compile (ghostel--ask-install-action "C:/modules/")))
      (should (equal '(?d ?c ?s) choice)))))

(ert-deftest ghostel-test-conpty-module-file-path-uses-custom-dir ()
  "Custom module directories override the default ConPTY module path."
  (let* ((module-dir (ghostel-test--fixture-dir "ghostel-modules"))
         (ghostel-module-dir module-dir)
         (module-file-suffix ".dll"))
    (should (equal (downcase (ghostel-test--fixture-path module-dir "conpty-module.dll"))
                   (downcase (ghostel--conpty-module-file-path))))))

(ert-deftest ghostel-test-load-module-if-available-loads-conpty-module-on-windows ()
  "Windows module loading bootstraps the direct ConPTY module after the loader."
  (let* ((module-dir (ghostel-test--fixture-dir "ghostel-modules"))
         (loader-path (ghostel-test--fixture-path module-dir "dyn-loader-module.dll"))
         (manifest-path (ghostel-test--fixture-path module-dir "ghostel-module.json"))
         (conpty-path (ghostel-test--fixture-path module-dir "conpty-module.dll"))
         (system-type 'windows-nt)
         (ghostel-module-dir module-dir)
        (module-file-suffix ".dll")
        (loaded nil)
        (checked nil)
        (reloaded nil)
        (loader-loaded nil)
        (conpty-loaded nil))
    (ghostel-test--without-subr-trampolines
      (let ((old-featurep (symbol-function 'featurep)))
        (cl-letf (((symbol-function 'file-exists-p)
                   (lambda (path)
                     (member (downcase path)
                             (list (downcase loader-path)
                                   (downcase manifest-path)
                                   (downcase conpty-path)))))
                  ((symbol-function 'featurep)
                   (lambda (feature)
                     (pcase feature
                       ('dyn-loader-module loader-loaded)
                       ('conpty-module conpty-loaded)
                       (_ (funcall old-featurep feature)))))
                  ((symbol-function 'module-load)
                   (lambda (path)
                     (push path loaded)
                     (cond
                      ((string-match-p "dyn-loader-module\\.dll\\'" path)
                       (setq loader-loaded t))
                      ((string-match-p "conpty-module\\.dll\\'" path)
                       (setq conpty-loaded t)))))
                  ((symbol-function 'ghostel--check-module-version)
                   (lambda (dir)
                     (setq checked dir)))
                  ((symbol-function 'ghostel--loader-load-manifest)
                   (lambda (manifest-path)
                    (setq reloaded manifest-path)
                    "ghostel")))
          (should (ghostel--load-module-if-available))
          (should (equal (mapcar #'downcase (reverse loaded))
                         (mapcar #'downcase (list loader-path conpty-path))))
          (should (equal (downcase module-dir)
                         (downcase checked)))
           (should (equal (downcase manifest-path)
                          (downcase reloaded))))))))

(ert-deftest ghostel-test-initialize-native-modules-reloads-already-loaded-module-when-safe ()
  "Load-time init refreshes an already-loaded native module when no terminals are live."
  (let ((ghostel-module-dir "C:/modules/")
        (module-file-suffix ".dll")
        (reloaded nil)
        (loaded nil))
    (ghostel-test--without-subr-trampolines
      (let ((old-featurep (symbol-function 'featurep)))
        (cl-letf (((symbol-function 'featurep)
                   (lambda (feature)
                     (if (eq feature 'dyn-loader-module)
                         t
                       (funcall old-featurep feature))))
                  ((symbol-function 'file-exists-p)
                   (lambda (path)
                     (member (downcase path)
                             (list (downcase "C:/modules/dyn-loader-module.dll")
                                   (downcase "C:/modules/ghostel-module.json")))))
                  ((symbol-function 'ghostel--live-buffers) (lambda () nil))
                  ((symbol-function 'ghostel-reload-module)
                   (lambda (&optional close-live)
                     (setq reloaded close-live)
                     t))
                  ((symbol-function 'ghostel--load-module-if-available)
                   (lambda (&optional dir)
                     (push dir loaded)
                     t)))
          (ghostel--initialize-native-modules)
          (should (eq reloaded nil))
          (should-not loaded))))))

(ert-deftest ghostel-test-initialize-native-modules-warns-when-live-buffers-block-refresh ()
  "Load-time init warns instead of reloading when live Ghostel buffers exist."
  (let ((ghostel-module-dir "C:/modules/")
        (module-file-suffix ".dll")
        (reloaded nil)
        (warnings nil)
        (live (generate-new-buffer " *ghostel-live*")))
    (unwind-protect
        (ghostel-test--without-subr-trampolines
          (let ((old-featurep (symbol-function 'featurep)))
            (cl-letf (((symbol-function 'featurep)
                       (lambda (feature)
                         (if (eq feature 'dyn-loader-module)
                             t
                           (funcall old-featurep feature))))
                      ((symbol-function 'file-exists-p)
                       (lambda (path)
                         (member (downcase path)
                                 (list (downcase "C:/modules/dyn-loader-module.dll")
                                       (downcase "C:/modules/ghostel-module.json")))))
                      ((symbol-function 'ghostel--live-buffers) (lambda () (list live)))
                      ((symbol-function 'ghostel-reload-module)
                       (lambda (&optional close-live)
                         (setq reloaded close-live)
                         t))
                      ((symbol-function 'display-warning)
                       (lambda (&rest args)
                         (push args warnings))))
              (ghostel--initialize-native-modules)
              (should-not reloaded)
              (should (= 1 (length warnings)))
              (should (string-match-p "restart Emacs or reload the native module"
                                      (nth 1 (car warnings)))))))
      (kill-buffer live))))

(ert-deftest ghostel-test-ensure-conpty-loaded-errors-when-module-missing ()
  "Windows bootstrap errors when the direct ConPTY module is unavailable."
  (let* ((module-dir (ghostel-test--fixture-dir "ghostel-modules"))
         (conpty-path (ghostel-test--fixture-path module-dir "conpty-module.dll"))
         (system-type 'windows-nt)
         (ghostel-module-dir module-dir)
        (module-file-suffix ".dll"))
    (ghostel-test--without-subr-trampolines
      (let ((old-featurep (symbol-function 'featurep)))
        (cl-letf (((symbol-function 'featurep)
                   (lambda (feature)
                     (and (not (eq feature 'conpty-module))
                          (funcall old-featurep feature))))
                  ((symbol-function 'file-exists-p)
                   (lambda (_path) nil)))
          (let ((err (should-error (ghostel--ensure-conpty-loaded) :type 'error)))
            (should (string-match-p
                     (regexp-quote (concat "ghostel: missing Windows ConPTY module: " conpty-path))
                     (cadr err)))))))))

(ert-deftest ghostel-test-compile-module-invokes-zig-build ()
  "Source compilation runs zig build directly."
  (let ((source-dir (ghostel-test--fixture-dir "ghostel-build"))
        (default-directory nil)
        (messages nil)
        (warnings nil)
        (process-invocation nil))
    (let ((comp-enable-subr-trampolines nil)
          (native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages)))
                ((symbol-function 'display-warning)
                  (lambda (&rest args)
                    (push args warnings)))
                ((symbol-function 'ghostel--publish-built-module-artifacts)
                 (lambda (&rest _) t))
                ((symbol-function 'process-file)
                  (lambda (program infile buffer display &rest args)
                    (setq process-invocation
                          (list program infile buffer display args default-directory))
                    0)))
        (should (ghostel--compile-module source-dir))
        (should (equal
                 (list "zig" nil "*ghostel-build*" nil
                       '("build" "-Doptimize=ReleaseFast") source-dir)
                  process-invocation))
        (should-not warnings)))))

(ert-deftest ghostel-test-compile-module-publishes-loader-target-and-metadata ()
  "Windows compilation publishes dyn-loader-module, ghostel-module, conpty-module, and metadata."
  (let* ((source-dir (ghostel-test--fixture-dir "ghostel-build"))
         (build-dir (ghostel-test--fixture-path source-dir "zig-out/bin"))
         (module-dir (ghostel-test--fixture-dir "ghostel-modules"))
         (loader-src (ghostel-test--fixture-path build-dir "dyn-loader-module.dll"))
         (target-src (ghostel-test--fixture-path build-dir "ghostel-module.dll"))
         (conpty-src (ghostel-test--fixture-path build-dir "conpty-module.dll"))
         (loader-dest (ghostel-test--fixture-path module-dir "dyn-loader-module.dll"))
         (target-dest (ghostel-test--fixture-path module-dir "ghostel-module.dll"))
         (conpty-dest (ghostel-test--fixture-path module-dir "conpty-module.dll"))
         (system-type 'windows-nt)
         (ghostel-module-dir module-dir)
        (module-file-suffix ".dll")
        (copies nil)
        (metadata-writes nil))
    (let ((comp-enable-subr-trampolines nil)
          (native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'process-file)
                 (lambda (&rest _) 0))
                ((symbol-function 'file-exists-p)
                 (lambda (path)
                     (member (downcase path)
                             (list (downcase loader-src)
                                   (downcase target-src)
                                   (downcase conpty-src)))))
                 ((symbol-function 'copy-file)
                  (lambda (src dest &optional ok-if-already-exists)
                    (push (list src dest ok-if-already-exists) copies)))
                ((symbol-function 'ghostel--write-loader-metadata-atomically)
                 (lambda (dir metadata)
                     (push (list dir metadata) metadata-writes))))
        (should (ghostel--compile-module source-dir))
        (should (equal 3 (length copies)))
        (should (member (list (downcase loader-src)
                              (downcase loader-dest)
                              t)
                        (mapcar (lambda (entry)
                                  (list (downcase (nth 0 entry))
                                        (downcase (nth 1 entry))
                                        (nth 2 entry)))
                                copies)))
        (should (member (list (downcase target-src)
                              (downcase target-dest)
                              t)
                        (mapcar (lambda (entry)
                                  (list (downcase (nth 0 entry))
                                        (downcase (nth 1 entry))
                                        (nth 2 entry)))
                                copies)))
        (should (member (list (downcase conpty-src)
                              (downcase conpty-dest)
                              t)
                        (mapcar (lambda (entry)
                                  (list (downcase (nth 0 entry))
                                        (downcase (nth 1 entry))
                                        (nth 2 entry)))
                                copies)))
        (pcase-let ((`(,dir ,metadata) (car metadata-writes)))
          (should (equal (downcase module-dir) (downcase dir)))
          (should (equal "ghostel-module.dll"
                         (alist-get 'module_path metadata))))))))

(ert-deftest ghostel-test-publish-built-module-artifacts-rotates-existing-windows-modules ()
  "Publishing rotates loaded DLLs to .bak on Windows before copying replacements."
  (let* ((source-dir (ghostel-test--fixture-dir "ghostel-build"))
         (module-dir (ghostel-test--fixture-dir "ghostel-modules"))
         (loader-src (ghostel-test--fixture-path source-dir "dyn-loader-module.dll"))
         (target-src (ghostel-test--fixture-path source-dir "ghostel-module.dll"))
         (conpty-src (ghostel-test--fixture-path source-dir "conpty-module.dll"))
         (loader-dest (ghostel-test--fixture-path module-dir "dyn-loader-module.dll"))
         (target-dest (ghostel-test--fixture-path module-dir "ghostel-module.dll"))
         (conpty-dest (ghostel-test--fixture-path module-dir "conpty-module.dll"))
         (loader-backup (concat loader-dest ".bak"))
         (target-backup (concat target-dest ".bak"))
         (conpty-backup (concat conpty-dest ".bak"))
         (system-type 'windows-nt)
         (ghostel-module-dir module-dir)
         (module-file-suffix ".dll")
         (deletes nil)
         (copies nil)
         (renames nil)
         (metadata-writes nil))
    (let ((comp-enable-subr-trampolines nil)
          (native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'file-exists-p)
                 (lambda (path)
                      (member (downcase path)
                              (list (downcase loader-src)
                                    (downcase target-src)
                                    (downcase conpty-src)
                                    (downcase loader-dest)
                                    (downcase target-dest)
                                    (downcase conpty-dest)
                                    (downcase loader-backup)))))
                ((symbol-function 'delete-file)
                 (lambda (path &optional _trash)
                   (push path deletes)
                   (signal 'file-error (list "in use" path))))
                ((symbol-function 'rename-file)
                 (lambda (src dest &optional ok-if-already-exists)
                   (push (list src dest ok-if-already-exists) renames)))
                ((symbol-function 'copy-file)
                 (lambda (src dest &optional ok-if-already-exists)
                   (push (list src dest ok-if-already-exists) copies)))
                ((symbol-function 'ghostel--write-loader-metadata-atomically)
                 (lambda (dir metadata)
                   (push (list dir metadata) metadata-writes))))
        (should (ghostel--publish-built-module-artifacts source-dir module-dir))
        (should (equal (list conpty-dest target-dest loader-dest) deletes))
        (should (member (list (downcase loader-dest)
                              (downcase (concat loader-dest ".1.bak"))
                              t)
                        (mapcar (lambda (entry)
                                  (list (downcase (nth 0 entry))
                                        (downcase (nth 1 entry))
                                        (nth 2 entry)))
                                renames)))
        (should (member (list (downcase target-dest)
                              (downcase target-backup)
                              t)
                        (mapcar (lambda (entry)
                                  (list (downcase (nth 0 entry))
                                        (downcase (nth 1 entry))
                                        (nth 2 entry)))
                                renames)))
        (should (member (list (downcase conpty-dest)
                              (downcase conpty-backup)
                              t)
                        (mapcar (lambda (entry)
                                  (list (downcase (nth 0 entry))
                                        (downcase (nth 1 entry))
                                        (nth 2 entry)))
                                renames)))
        (should (equal 3 (length copies)))
        (should (equal "ghostel-module.dll"
                       (alist-get 'module_path (cadar metadata-writes))))))))

(ert-deftest ghostel-test-publish-built-module-artifacts-errors-when-conpty-missing ()
  "Windows publishing fails loudly when conpty-module.dll is absent."
  (let* ((source-dir (ghostel-test--fixture-dir "ghostel-build"))
         (module-dir (ghostel-test--fixture-dir "ghostel-modules"))
         (loader-src (ghostel-test--fixture-path source-dir "dyn-loader-module.dll"))
         (target-src (ghostel-test--fixture-path source-dir "ghostel-module.dll"))
         (system-type 'windows-nt)
         (ghostel-module-dir module-dir)
         (module-file-suffix ".dll"))
    (let ((comp-enable-subr-trampolines nil)
          (native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'file-exists-p)
                 (lambda (path)
                   (member (downcase path)
                           (list (downcase loader-src)
                                 (downcase target-src)))))
                ((symbol-function 'file-directory-p)
                 (lambda (_path) t))
                ((symbol-function 'ghostel--replace-module-file)
                 (lambda (&rest _) nil)))
        (let ((err (should-error (ghostel--publish-built-module-artifacts
                                  source-dir module-dir)
                                 :type 'error)))
          (should (string-match-p "Built Windows ConPTY module is missing"
                                  (cadr err))))))))

(ert-deftest ghostel-test-module-compile-command-uses-helper-with-package-dir ()
  "Interactive compilation delegates to the shared compile helper."
  (let ((source-dir (ghostel-test--fixture-dir "ghostel-build"))
        (compiled-dir nil))
    (let ((comp-enable-subr-trampolines nil)
          (native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'locate-library)
                 (lambda (_) (ghostel-test--fixture-path source-dir "ghostel.el")))
                ((symbol-function 'ghostel--compile-module)
                 (lambda (dir)
                   (setq compiled-dir dir)
                   t)))
        (ghostel-module-compile)
        (should (equal (downcase source-dir)
                       (downcase compiled-dir)))))))

(ert-deftest ghostel-test-load-module-if-available-errors-when-metadata-points-to-missing-target-module ()
  "Bootstrap fails when metadata references a missing target module."
  (let* ((module-dir (ghostel-test--fixture-dir "ghostel-modules"))
         (loader-path (ghostel-test--fixture-path module-dir "dyn-loader-module.dll"))
         (manifest-path (ghostel-test--fixture-path module-dir "ghostel-module.json"))
         (target-path (ghostel-test--fixture-path module-dir "ghostel-module.dll"))
         (ghostel-module-dir module-dir)
         (module-file-suffix ".dll"))
    (ghostel-test--without-subr-trampolines
     (cl-letf (((symbol-function 'file-exists-p)
                (lambda (path)
                  (member (downcase path)
                          (list (downcase loader-path)
                                (downcase manifest-path)))))
               ((symbol-function 'module-load) #'ignore)
               ((symbol-function 'ghostel--loader-load-manifest)
                 (lambda (_manifest-path)
                  (error "Ghostel target module is missing: %s" target-path))))
        (should-error (ghostel--load-module-if-available)
                      :type 'error)))))

(ert-deftest ghostel-test-load-module-if-available-skips-when-metadata-missing ()
  "Missing loader metadata leaves the native module unavailable."
  (let ((ghostel-module-dir "C:/modules/")
        (module-file-suffix ".dll")
        (loader-loaded nil)
        (bootstrapped nil)
        (checked nil))
    (ghostel-test--without-subr-trampolines
      (cl-letf (((symbol-function 'file-exists-p)
                 (lambda (path)
                   (equal (downcase path)
                          (downcase "C:/modules/dyn-loader-module.dll"))))
                ((symbol-function 'module-load)
                 (lambda (_path)
                   (setq loader-loaded t)))
                ((symbol-function 'ghostel--loader-load-manifest)
                 (lambda (_manifest-path)
                   (setq bootstrapped t)
                   (error "should not bootstrap without metadata")))
                ((symbol-function 'ghostel--check-module-version)
                 (lambda (_dir)
                   (setq checked t))))
        (should-not (ghostel--load-module-if-available))
        (should-not loader-loaded)
        (should-not bootstrapped)
        (should-not checked)))))

;; -----------------------------------------------------------------------
;; Test: cursor follow toggle
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-delayed-redraw-keeps-point-when-cursor-follow-disabled ()
  "Redraw keeps point stable when cursor following is disabled."
  (with-temp-buffer
    (let ((ghostel--term 'fake-term)
          (ghostel--copy-mode-active nil)
          (ghostel--redraw-timer 'fake-timer)
          (ghostel--pending-output nil)
          (ghostel--force-next-redraw nil)
          (ghostel-full-redraw nil)
          (ghostel-cursor-follow nil))
      (insert "line 1\nline 2\nline 3")
      (goto-char (point-min))
      (forward-line 1)
      (move-to-column 2)
      (let ((original-point (point)))
        (cl-letf (((symbol-function 'ghostel--flush-pending-output) #'ignore)
                  ((symbol-function 'ghostel--mode-enabled)
                   (lambda (&rest _) nil))
                  ((symbol-function 'ghostel--redraw)
                   (lambda (&rest _)
                     (goto-char (point-max)))))
          (ghostel--delayed-redraw (current-buffer))
          (should (equal original-point (point))))))))

;; -----------------------------------------------------------------------
;; Test: immediate redraw for interactive echo
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-immediate-redraw-triggers-on-small-echo ()
  "Small output after recent send-key triggers immediate redraw."
  (with-temp-buffer
    (let ((buf (current-buffer))
          (ghostel--term 'fake)
          (ghostel--pending-output nil)
          (ghostel--redraw-timer nil)
          (ghostel--last-send-time nil)
          (ghostel-immediate-redraw-threshold 256)
          (ghostel-immediate-redraw-interval 0.05)
          (immediate-called nil)
          (invalidate-called nil))
      ;; Stub out process-buffer, delayed-redraw, and invalidate
      (let ((comp-enable-subr-trampolines nil)
            (native-comp-enable-subr-trampolines nil))
        (cl-letf (((symbol-function 'process-buffer) (lambda (_) buf))
                  ((symbol-function 'ghostel--delayed-redraw)
                   (lambda (_buf) (setq immediate-called t)))
                  ((symbol-function 'ghostel--invalidate)
                   (lambda () (setq invalidate-called t))))
          ;; Simulate recent keystroke
          (setq ghostel--last-send-time (current-time))
          ;; Simulate small echo arriving
          (ghostel--filter 'fake-proc "a")
          (should immediate-called)
          (should-not invalidate-called))))))

(ert-deftest ghostel-test-immediate-redraw-skips-large-output ()
  "Large output falls back to timer-based batching."
  (with-temp-buffer
    (let ((buf (current-buffer))
          (ghostel--term 'fake)
          (ghostel--pending-output nil)
          (ghostel--redraw-timer nil)
          (ghostel--last-send-time (current-time))
          (ghostel-immediate-redraw-threshold 256)
          (ghostel-immediate-redraw-interval 0.05)
          (immediate-called nil)
          (invalidate-called nil))
      (let ((comp-enable-subr-trampolines nil)
            (native-comp-enable-subr-trampolines nil))
        (cl-letf (((symbol-function 'process-buffer) (lambda (_) buf))
                  ((symbol-function 'ghostel--delayed-redraw)
                   (lambda (_buf) (setq immediate-called t)))
                  ((symbol-function 'ghostel--invalidate)
                   (lambda () (setq invalidate-called t))))
          ;; Large output should batch
          (ghostel--filter 'fake-proc (make-string 500 ?x))
          (should-not immediate-called)
          (should invalidate-called))))))

(ert-deftest ghostel-test-immediate-redraw-skips-stale-send ()
  "Output arriving long after last keystroke uses timer batching."
  (with-temp-buffer
    (let ((buf (current-buffer))
          (ghostel--term 'fake)
          (ghostel--pending-output nil)
          (ghostel--redraw-timer nil)
          (ghostel--last-send-time (time-subtract (current-time) 1))
          (ghostel-immediate-redraw-threshold 256)
          (ghostel-immediate-redraw-interval 0.05)
          (immediate-called nil)
          (invalidate-called nil))
      (let ((comp-enable-subr-trampolines nil)
            (native-comp-enable-subr-trampolines nil))
        (cl-letf (((symbol-function 'process-buffer) (lambda (_) buf))
                  ((symbol-function 'ghostel--delayed-redraw)
                   (lambda (_buf) (setq immediate-called t)))
                  ((symbol-function 'ghostel--invalidate)
                   (lambda () (setq invalidate-called t))))
          (ghostel--filter 'fake-proc "a")
          (should-not immediate-called)
          (should invalidate-called))))))

(ert-deftest ghostel-test-immediate-redraw-disabled-when-zero ()
  "Immediate redraw is disabled when threshold is 0."
  (with-temp-buffer
    (let ((buf (current-buffer))
          (ghostel--term 'fake)
          (ghostel--pending-output nil)
          (ghostel--redraw-timer nil)
          (ghostel--last-send-time (current-time))
          (ghostel-immediate-redraw-threshold 0)
          (ghostel-immediate-redraw-interval 0.05)
          (immediate-called nil)
          (invalidate-called nil))
      (let ((comp-enable-subr-trampolines nil)
            (native-comp-enable-subr-trampolines nil))
        (cl-letf (((symbol-function 'process-buffer) (lambda (_) buf))
                  ((symbol-function 'ghostel--delayed-redraw)
                   (lambda (_buf) (setq immediate-called t)))
                  ((symbol-function 'ghostel--invalidate)
                   (lambda () (setq invalidate-called t))))
          (ghostel--filter 'fake-proc "a")
          (should-not immediate-called)
          (should invalidate-called))))))

;; -----------------------------------------------------------------------
;; Test: input coalescing
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-input-coalesce-buffers-single-chars ()
  "Single-char sends are buffered when coalescing is enabled."
  (with-temp-buffer
    (let* ((ghostel--process nil)
           (ghostel--input-buffer nil)
           (ghostel--input-timer nil)
           (ghostel--last-send-time nil)
           (ghostel-input-coalesce-delay 0.003)
           (sent nil))
      ;; Create a mock process
      (let ((comp-enable-subr-trampolines nil)
            (native-comp-enable-subr-trampolines nil))
        (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                  ((symbol-function 'process-send-string)
                   (lambda (_proc str) (push str sent)))
                  ((symbol-function 'run-with-timer)
                   (lambda (_delay _repeat _fn &rest _args)
                     ;; Return a fake timer but call function for test
                     'fake-timer)))
          (setq ghostel--process 'fake)
          (ghostel--send-key "a")
          ;; Should be buffered, not sent
          (should (equal ghostel--input-buffer '("a")))
          (should-not sent))))))

(ert-deftest ghostel-test-input-coalesce-disabled ()
  "With coalesce delay 0, characters are sent immediately."
  (with-temp-buffer
    (let* ((ghostel--process nil)
           (ghostel--input-buffer nil)
           (ghostel--input-timer nil)
           (ghostel--last-send-time nil)
           (ghostel-input-coalesce-delay 0)
           (sent nil))
      (let ((comp-enable-subr-trampolines nil)
            (native-comp-enable-subr-trampolines nil))
        (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                  ((symbol-function 'process-send-string)
                   (lambda (_proc str) (push str sent))))
          (setq ghostel--process 'fake)
          (ghostel--send-key "a")
          (should (member "a" sent))
          (should-not ghostel--input-buffer))))))

(ert-deftest ghostel-test-input-flush-sends-buffered ()
  "Flushing input buffer sends concatenated characters."
  (with-temp-buffer
    (let* ((ghostel--process nil)
           (ghostel--input-buffer '("c" "b" "a"))
           (ghostel--input-timer nil)
           (sent nil))
      (let ((comp-enable-subr-trampolines nil)
            (native-comp-enable-subr-trampolines nil))
        (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                  ((symbol-function 'process-send-string)
                   (lambda (_proc str) (push str sent))))
          (setq ghostel--process 'fake)
          (ghostel--flush-input (current-buffer))
          (should (equal sent '("abc")))
          (should-not ghostel--input-buffer))))))

(ert-deftest ghostel-test-send-key-dispatches-through-process-transport ()
  "Immediate key sends should dispatch through the process transport helper."
  (with-temp-buffer
    (let* ((ghostel--process 'fake-process)
           (ghostel--input-buffer nil)
           (ghostel--input-timer nil)
           (ghostel--last-send-time nil)
           (ghostel-input-coalesce-delay 0)
           (transport-send nil))
      (let ((comp-enable-subr-trampolines nil)
            (native-comp-enable-subr-trampolines nil))
        (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                  ((symbol-function 'ghostel--process-send)
                   (lambda (proc str)
                     (setq transport-send (cons proc str))))
                  ((symbol-function 'process-send-string)
                   (lambda (&rest args)
                     (ert-fail
                      (format "unexpected direct process-send-string: %S"
                              args)))))
           (ghostel--send-key "a")
           (should (equal '(fake-process . "a") transport-send)))))))

(ert-deftest ghostel-test-control-key-bindings-cover-upstream-range ()
  "Ghostel binds the upstream control-key range plus C-@ passthrough."
  (let ((sent nil))
    (cl-letf (((symbol-function 'ghostel--send-key)
               (lambda (key)
                 (setq sent key))))
      (dolist (entry '(("C-t" . "\x14")
                       ("C-v" . "\x16")
                       ("C-@" . "\x00")))
        (setq sent nil)
         (let ((binding (lookup-key ghostel-mode-map (kbd (car entry)))))
           (should binding)
           (funcall binding)
           (should (equal (cdr entry) sent)))))))

(ert-deftest ghostel-test-meta-key-bindings-reach-terminal ()
  "Meta-letter bindings stay routed to the terminal."
  (dolist (key '("M-a" "M-z"))
    (should (eq #'ghostel--send-event
                (lookup-key ghostel-mode-map (kbd key))))))

(ert-deftest ghostel-test-mouse-bindings-reach-terminal ()
  "Mouse bindings should route terminal events through ghostel handlers."
  (dolist (entry '(("<down-mouse-1>" . ghostel--mouse-press)
                   ("<mouse-1>" . ghostel--mouse-release)
                   ("<down-mouse-2>" . ghostel--mouse-press)
                   ("<mouse-2>" . ghostel--mouse-release)
                   ("<down-mouse-3>" . ghostel--mouse-press)
                   ("<mouse-3>" . ghostel--mouse-release)
                   ("<drag-mouse-1>" . ghostel--mouse-drag)
                   ("<drag-mouse-2>" . ghostel--mouse-drag)
                   ("<drag-mouse-3>" . ghostel--mouse-drag)
                   ("<mouse-4>" . ghostel--mouse-wheel-up)
                   ("<mouse-5>" . ghostel--mouse-wheel-down)
                   ("<wheel-up>" . ghostel--mouse-wheel-up)
                   ("<wheel-down>" . ghostel--mouse-wheel-down)))
    (should (eq (cdr entry)
                (lookup-key ghostel-mode-map (kbd (car entry)))))))

(ert-deftest ghostel-test-mouse-press-dispatches-terminal-event ()
  "Mouse presses should be translated and forwarded to the terminal."
  (with-temp-buffer
    (let ((ghostel--term 'fake-term)
          (captured nil)
          (selected-window nil))
      (let ((comp-enable-subr-trampolines nil)
            (native-comp-enable-subr-trampolines nil))
        (cl-letf (((symbol-function 'ghostel--process-live-p) (lambda (&optional _) t))
                  ((symbol-function 'event-start) (lambda (_) '(fake-window)))
                  ((symbol-function 'select-window)
                   (lambda (window &rest _) (setq selected-window window)))
                  ((symbol-function 'posn-col-row) (lambda (_) '(7 . 4)))
                  ((symbol-function 'event-basic-type) (lambda (_) 'mouse-3))
                  ((symbol-function 'event-modifiers) (lambda (_) '(control meta)))
                  ((symbol-function 'ghostel--mouse-event)
                   (lambda (&rest args) (setq captured args))))
          (ghostel--mouse-press 'fake-event)
          (should (eq 'fake-window selected-window))
          (should (equal '(fake-term 0 2 4 7 6) captured)))))))

(ert-deftest ghostel-test-mouse-wheel-up-forwards-to-terminal-when-tracking-enabled ()
  "Wheel-up should be forwarded as button 4 when mouse tracking is active."
  (with-temp-buffer
    (let ((ghostel--term 'fake-term)
          (captured nil))
      (let ((comp-enable-subr-trampolines nil)
            (native-comp-enable-subr-trampolines nil))
        (cl-letf (((symbol-function 'ghostel--process-live-p) (lambda (&optional _) t))
                  ((symbol-function 'ghostel--mode-enabled)
                   (lambda (_term mode) (memq mode '(9 1000 1002 1003))))
                  ((symbol-function 'event-start) (lambda (_) 'fake-start))
                  ((symbol-function 'posn-col-row) (lambda (_) '(8 . 5)))
                  ((symbol-function 'event-modifiers) (lambda (_) nil))
                  ((symbol-function 'ghostel--mouse-event)
                   (lambda (&rest args) (setq captured args)))
                  ((symbol-function 'ghostel--scroll-up)
                   (lambda (&rest args)
                     (ert-fail (format "unexpected scroll fallback: %S" args)))))
          (ghostel--mouse-wheel-up 'fake-event)
          (should (equal '(fake-term 0 4 5 8 0) captured)))))))

(ert-deftest ghostel-test-mouse-wheel-up-scrolls-scrollback-when-tracking-disabled ()
  "Wheel-up should keep scrollback behavior when mouse tracking is off."
  (with-temp-buffer
    (let ((ghostel--term 'fake-term)
          (fallback nil))
      (let ((comp-enable-subr-trampolines nil)
            (native-comp-enable-subr-trampolines nil))
        (cl-letf (((symbol-function 'ghostel--process-live-p) (lambda (&optional _) t))
                  ((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
                  ((symbol-function 'ghostel--mouse-event)
                   (lambda (&rest args)
                     (ert-fail (format "unexpected mouse forwarding: %S" args))))
                  ((symbol-function 'ghostel--scroll-up)
                   (lambda (&optional event) (setq fallback event))))
          (ghostel--mouse-wheel-up 'fake-event)
          (should (eq 'fake-event fallback)))))))

(ert-deftest ghostel-test-window-resize-dispatches-through-process-transport ()
  "Resize should use a transport helper instead of the PTY primitive directly."
  (with-temp-buffer
    (let ((ghostel--term 'fake-term)
          (ghostel--resize-timer nil)
          (ghostel--force-next-redraw nil)
          (resize-call nil)
          (invalidate-called nil)
          (window 'fake-window))
      (let ((comp-enable-subr-trampolines nil)
            (native-comp-enable-subr-trampolines nil))
        (cl-letf (((symbol-function 'window-max-chars-per-line)
                   (lambda (_) 120))
                  ((symbol-function 'window-body-width)
                   (lambda (_window &optional _pixelwise) 80))
                  ((symbol-function 'window-body-height) (lambda (_) 25))
                  ((symbol-function 'ghostel--mode-enabled)
                   (lambda (&rest _) nil))
                  ((symbol-function 'process-live-p) (lambda (_) t))
                  ((symbol-function 'ghostel--set-size) #'ignore)
                  ((symbol-function 'ghostel--invalidate)
                   (lambda () (setq invalidate-called t)))
                  ((symbol-function 'ghostel--process-set-window-size)
                   (lambda (proc height width)
                     (setq resize-call (list proc height width))))
                  ((symbol-function 'set-process-window-size)
                   (lambda (&rest args)
                     (ert-fail
                      (format "unexpected direct set-process-window-size: %S"
                              args)))))
          (should (equal '(119 . 24)
                         (ghostel--window-adjust-process-window-size
                          'fake-process (list window))))
          (should (equal '(fake-process 24 119) resize-call))
          (should invalidate-called))))))

(ert-deftest ghostel-test-window-resize-clamps-terminal-size-floor-to-one ()
  "Resize should not shrink below one row or one column."
  (with-temp-buffer
    (let ((ghostel--term 'fake-term)
          (ghostel--resize-timer nil)
          (resize-call nil)
          (window 'fake-window))
      (let ((comp-enable-subr-trampolines nil)
            (native-comp-enable-subr-trampolines nil))
        (cl-letf (((symbol-function 'window-max-chars-per-line)
                   (lambda (_) 1))
                  ((symbol-function 'window-body-width)
                   (lambda (_window &optional _pixelwise) 1))
                  ((symbol-function 'window-body-height)
                   (lambda (_) 1))
                  ((symbol-function 'ghostel--mode-enabled)
                   (lambda (&rest _) nil))
                  ((symbol-function 'process-live-p)
                   (lambda (_) t))
                  ((symbol-function 'ghostel--set-size)
                   (lambda (_term height width)
                     (setq resize-call (list height width))))
                  ((symbol-function 'ghostel--process-set-window-size)
                   #'ignore)
                  ((symbol-function 'ghostel--invalidate)
                   #'ignore))
          (should (equal '(1 . 1)
                         (ghostel--window-adjust-process-window-size
                          'fake-process (list window))))
          (should (equal '(1 1) resize-call)))))))

;; -----------------------------------------------------------------------
;; Test: send-encoded sets last-send-time on encoder success
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-send-encoded-sets-send-time ()
  "When the native encoder succeeds, last-send-time is updated."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--last-send-time nil))
      ;; Stub encode-key to return non-nil (success)
      (cl-letf (((symbol-function 'ghostel--encode-key)
                 (lambda (_term _key _mods &optional _utf8) t)))
        (ghostel--send-encoded "backspace" "")
        (should ghostel--last-send-time)))))

(ert-deftest ghostel-test-send-encoded-no-send-time-on-fallback ()
  "When the encoder fails, last-send-time is set by send-key, not send-encoded."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--process nil)
          (ghostel--last-send-time nil)
          (ghostel--input-buffer nil)
          (ghostel--input-timer nil)
          (ghostel-input-coalesce-delay 0))
      (let ((comp-enable-subr-trampolines nil)
            (native-comp-enable-subr-trampolines nil))
        ;; Stub encode-key to return nil (failure) — triggers raw fallback
        (cl-letf (((symbol-function 'ghostel--encode-key)
                   (lambda (_term _key _mods &optional _utf8) nil))
                  ((symbol-function 'process-live-p) (lambda (_) t))
                  ((symbol-function 'process-send-string)
                   (lambda (_proc _str) nil)))
          (setq ghostel--process 'fake)
          (ghostel--send-encoded "backspace" "")
          ;; send-key sets last-send-time via the fallback path
          (should ghostel--last-send-time))))))

;;; Loader helper scaffolding tests

(ert-deftest ghostel-test-loader-module-file-path-remains-stable ()
  "Loader module path is stable and resolves to the expected file name."
  ;; downcase normalises the path for case-insensitive file systems (Windows/macOS).
  (let* ((module-dir (ghostel-test--fixture-dir "ghostel-modules"))
         (ghostel-module-dir module-dir)
         (module-file-suffix ".dll"))
    (should (equal (downcase (ghostel-test--fixture-path module-dir "dyn-loader-module.dll"))
                   (downcase (ghostel--loader-module-file-path))))))

(ert-deftest ghostel-test-target-module-file-name-is-stable ()
  "The target module path is stable for no-restart reload support."
  (let ((module-file-suffix ".dll"))
    (should (equal "ghostel-module.dll"
                   (file-name-nondirectory (ghostel--target-module-file-path "C:/modules/"))))))

(ert-deftest ghostel-test-loader-metadata-path-uses-module-dir ()
  ;; downcase normalises the path for case-insensitive file systems (Windows/macOS).
  (let* ((module-dir (ghostel-test--fixture-dir "ghostel-modules"))
         (ghostel-module-dir module-dir))
    (should (equal (downcase (ghostel-test--fixture-path module-dir "ghostel-module.json"))
                   (downcase (ghostel--loader-metadata-path))))))

(ert-deftest ghostel-test-dyn-loader-reload-loads-replaced-module-image ()
  "Reloading a replaced target module should update exported function behavior."
  (skip-unless (and (fboundp 'module-load)
                    (executable-find "zig")
                    (require 'comp-run nil t)
                    (boundp 'comp-installed-trampolines-h)))
  (let* ((suffix (format "%x%x" (emacs-pid) (random most-positive-fixnum)))
         (module-id (format "ghostel-test-module-%s" suffix))
         (lisp-name (format "ghostel-test--fixture-version-%s" suffix))
         (fixture-dir (make-temp-file "ghostel-reload-fixture-" t))
         (source-v1 (expand-file-name "sample-v1.zig" fixture-dir))
         (source-v2 (expand-file-name "sample-v2.zig" fixture-dir))
         (ext module-file-suffix)
         (output-v1 (expand-file-name (concat "sample-v1" ext) fixture-dir))
         (output-v2 (expand-file-name (concat "sample-v2" ext) fixture-dir))
         (live-module (expand-file-name (concat "sample-live" ext) fixture-dir))
         (manifest (expand-file-name "sample-module.json" fixture-dir))
         (repo-root (ghostel-test--repo-root))
         (loader-path (or (cl-find-if #'file-exists-p
                                      (list (expand-file-name (concat "zig-out/bin/dyn-loader-module" ext)
                                                              repo-root)
                                            (expand-file-name (concat "dyn-loader-module" ext)
                                                              repo-root)))
                          ""))
         (version-sym (intern lisp-name)))
    (unwind-protect
        (progn
          (skip-unless (file-exists-p loader-path))
          (ghostel-test--write-dyn-loader-fixture source-v1 module-id lisp-name "1.0")
          (ghostel-test--write-dyn-loader-fixture source-v2 module-id lisp-name "2.0")
          (ghostel-test--build-dyn-loader-fixture source-v1 output-v1)
          (ghostel-test--build-dyn-loader-fixture source-v2 output-v2)
          (copy-file output-v1 live-module t)
          (ghostel-test--write-loader-manifest manifest
                                               (file-name-nondirectory live-module))
          (unless (featurep 'dyn-loader-module)
            (module-load loader-path))
          (dyn-loader-load-manifest manifest)
          (should (equal "1.0" (funcall version-sym)))
          (puthash version-sym 'stale-trampoline comp-installed-trampolines-h)
          (rename-file live-module (concat live-module ".bak") t)
          (copy-file output-v2 live-module t)
          (dyn-loader-reload module-id)
          (should (equal "2.0" (funcall version-sym)))
          (should-not (gethash version-sym comp-installed-trampolines-h)))
      (ignore-errors (fmakunbound version-sym))
      (when (file-directory-p fixture-dir)
        (ignore-errors (delete-directory fixture-dir t))))))

(ert-deftest ghostel-test-reload-module-refuses-with-live-terminals ()
  (cl-letf (((symbol-function 'ghostel--live-buffers)
             (lambda () '(live-buffer))))
    (let ((err (should-error (ghostel-reload-module) :type 'user-error)))
      (should (string-match-p "still running" (cadr err))))))

(ert-deftest ghostel-test-close-live-buffers-terminates-conpty-and-process ()
  "Closing live buffers terminates both the ConPTY backend and the process."
  (ghostel-test--without-subr-trampolines
   (let ((killed-terms nil)
         (deleted-procs nil)
         (buf (generate-new-buffer " *ghostel-live*")))
     (unwind-protect
         (progn
           (with-current-buffer buf
             (setq-local ghostel--term 'term-1)
             (setq-local ghostel--process 'proc-1)
             (setq-local ghostel--conpty-notify-pipe t))
           (cl-letf (((symbol-function 'ghostel--conpty-active-p) (lambda () t))
                     ((symbol-function 'conpty--kill)
                      (lambda (term)
                        (push term killed-terms)))
                     ((symbol-function 'process-live-p)
                      (lambda (proc)
                        (eq proc 'proc-1)))
                     ((symbol-function 'delete-process)
                      (lambda (proc)
                        (push proc deleted-procs))))
             (ghostel--close-live-buffers (list buf)))
           (should (equal '(term-1) killed-terms))
           (should (equal '(proc-1) deleted-procs))
            (should-not (buffer-live-p buf)))
        (when (buffer-live-p buf)
          (kill-buffer buf))))))

(ert-deftest ghostel-test-sentinel-kills-conpty-backend-on-exit ()
  "Process exit tears down the ConPTY backend from the sentinel path."
  (ghostel-test--without-subr-trampolines
   (let ((closed-terms nil)
         (hook-call nil)
         (buf (generate-new-buffer " *ghostel-exit-live*")))
     (unwind-protect
         (with-current-buffer buf
           (setq-local ghostel--term 'term-1)
           (setq-local ghostel--process 'proc-1)
           (setq-local ghostel--conpty-notify-pipe t)
            (let ((ghostel-kill-buffer-on-exit nil))
              (cl-letf (((symbol-function 'ghostel--flush-pending-output)
                         (lambda () nil))
                        ((symbol-function 'process-buffer)
                         (lambda (_process) buf))
                        ((symbol-function 'ghostel--conpty-active-p)
                         (lambda () t))
                        ((symbol-function 'conpty--kill)
                         (lambda (term)
                           (push term closed-terms)))
                        ((symbol-function 'remove-function)
                         (lambda (&rest _) nil))
                       ((symbol-function 'run-hook-with-args)
                        (lambda (&rest args)
                          (setq hook-call args))))
               (ghostel--sentinel 'proc-1 "finished\n")
               (should (equal '(term-1) closed-terms))
               (should-not ghostel--process)
               (should-not ghostel--conpty-notify-pipe)
               (should (eq 'ghostel-exit-functions (nth 0 hook-call)))
               (should (eq buf (nth 1 hook-call)))
               (should (equal "finished\n" (nth 2 hook-call))))))
       (when (buffer-live-p buf)
         (kill-buffer buf))))))

(ert-deftest ghostel-test-reload-module-prefix-closes-live-terminals ()
  "Prefix reload closes live terminals before reloading."
  (ghostel-test--without-subr-trampolines
   (let ((message-log nil)
         (reload-call nil)
         (killed-terms nil)
         (deleted-procs nil)
         (buf (generate-new-buffer " *ghostel-reload-live*")))
     (unwind-protect
         (progn
           (with-current-buffer buf
             (setq-local ghostel--term 'term-1)
             (setq-local ghostel--process 'proc-1)
             (setq-local ghostel--conpty-notify-pipe t))
           (cl-letf (((symbol-function 'ghostel--live-buffers)
                      (lambda () (list buf)))
                     ((symbol-function 'ghostel--conpty-active-p)
                      (lambda () t))
                     ((symbol-function 'conpty--kill)
                      (lambda (term)
                        (push term killed-terms)))
                     ((symbol-function 'process-live-p)
                      (lambda (proc)
                        (eq proc 'proc-1)))
                     ((symbol-function 'delete-process)
                      (lambda (proc)
                        (push proc deleted-procs)))
                     ((symbol-function 'ghostel--loader-reload)
                      (lambda (module-id)
                        (setq reload-call module-id)
                        t))
                     ((symbol-function 'message)
                      (lambda (fmt &rest args)
                        (setq message-log (apply #'format fmt args)))))
             (ghostel-reload-module '(4)))
           (should (equal '(term-1) killed-terms))
           (should (equal '(proc-1) deleted-procs))
           (should-not (buffer-live-p buf))
           (should (equal ghostel--module-id reload-call))
           (should (string-match-p "reloaded successfully" message-log)))
       (when (buffer-live-p buf)
         (kill-buffer buf))))))

(ert-deftest ghostel-test-reload-module-swaps-generation-when-safe ()
  "Reload succeeds when no live terminals exist."
  (ghostel-test--without-subr-trampolines
   (let ((message-log nil)
         (reload-call nil))
      (cl-letf (((symbol-function 'ghostel--live-buffers) (lambda () nil))
                ((symbol-function 'ghostel--loader-reload)
                 (lambda (module-id)
                   (setq reload-call module-id)
                   t))
                ((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (setq message-log (apply #'format fmt args)))))
        (ghostel-reload-module)
        (should (equal ghostel--module-id reload-call))
        (should (string-match-p "reloaded successfully" message-log))))))

(ert-deftest ghostel-test-reload-module-keeps-user-state-on-failure ()
  "Reload errors do not emit a success message."
  (ghostel-test--without-subr-trampolines
   (let ((message-log nil)
         (loader-called nil))
      (cl-letf (((symbol-function 'ghostel--live-buffers) (lambda () nil))
                ((symbol-function 'ghostel--loader-reload)
                 (lambda (_module-id)
                   (setq loader-called t)
                   (error "loader ABI mismatch")))
                ((symbol-function 'message)
                (lambda (fmt &rest args)
                  (setq message-log (apply #'format fmt args)))))
       (should-error (ghostel-reload-module) :type 'error)
       (should loader-called)
       (should-not message-log)))))

(ert-deftest ghostel-test-reload-module-surfaces-abi-mismatch ()
  "Reload forwards loader errors to the caller."
  (cl-letf (((symbol-function 'ghostel--live-buffers) (lambda () nil))
            ((symbol-function 'ghostel--loader-reload)
             (lambda (_module-id)
               (error "loader ABI mismatch"))))
    (let ((err (should-error (ghostel-reload-module) :type 'error)))
      (should (string-match-p "loader ABI mismatch" (cadr err))))))

;; -----------------------------------------------------------------------
;; Test: ghostel-copy-mode-recenter
;; -----------------------------------------------------------------------

(ert-deftest ghostel-test-copy-mode-recenter ()
  "Recenter scrolls terminal viewport to center the current line."
  (let ((buf (generate-new-buffer " *ghostel-test-copy-mode-recenter*")))
    (unwind-protect
        (with-current-buffer buf
          (dotimes (i 20) (insert (format "line-%02d" i) (make-string 33 ?x) "\n"))
          (setq ghostel--term 'fake-term)
          (setq ghostel--copy-mode-active t)
          (setq buffer-read-only t)
          (let ((scroll-delta nil)
                (redraw-called nil)
                (recenter-called nil))
            ;; Mock redraw that changes the first line (simulates viewport shift).
            (cl-letf (((symbol-function 'ghostel--scroll)
                       (lambda (_term delta) (setq scroll-delta delta)))
                      ((symbol-function 'ghostel--redraw)
                       (lambda (_term _full)
                         (setq redraw-called t)
                         (save-excursion
                           (goto-char (point-min))
                           (delete-char 1)
                           (insert "!"))))
                      ((symbol-function 'window-body-height)
                       (lambda (&rest _) 20))
                      ((symbol-function 'recenter)
                       (lambda (&rest _) (setq recenter-called t))))
              ;; Point on line 5 (above center 10) → scroll viewport up
              (goto-char (point-min))
              (forward-line 4)
              (ghostel-copy-mode-recenter)
              (should (equal -5 scroll-delta))
              (should redraw-called)
              (should recenter-called))

            ;; Mock redraw that does NOT change buffer (simulates clamped scroll).
            (cl-letf (((symbol-function 'ghostel--scroll)
                       (lambda (_term delta) (setq scroll-delta delta)))
                      ((symbol-function 'ghostel--redraw)
                       (lambda (_term _full) (setq redraw-called t)))
                      ((symbol-function 'window-body-height)
                       (lambda (&rest _) 20))
                      ((symbol-function 'recenter)
                       (lambda (&rest _) (setq recenter-called t))))
              ;; Point on line 15 (below center), scroll clamped → no-op
              (setq scroll-delta nil redraw-called nil recenter-called nil)
              (goto-char (point-min))
              (forward-line 14)
              (ghostel-copy-mode-recenter)
              (should (equal 5 scroll-delta))
              (should redraw-called)
              (should-not recenter-called)
              (should (= 15 (line-number-at-pos)))

              ;; Point on line 10 (at center) → no scroll at all
              (setq scroll-delta nil redraw-called nil recenter-called nil)
              (goto-char (point-min))
              (forward-line 9)
              (ghostel-copy-mode-recenter)
              (should-not scroll-delta)
              (should-not redraw-called)
              (should-not recenter-called))))
      (kill-buffer buf))))

(defconst ghostel-test--elisp-tests
  '(ghostel-test-source-omits-removed-native-hooks
    ghostel-test-raw-key-sequences
    ghostel-test-modifier-number
    ghostel-test-send-event
    ghostel-test-scroll-on-input-scrolls-before-key-send
    ghostel-test-raw-key-modified-specials
    ghostel-test-update-directory
    ghostel-test-filter-soft-wraps
    ghostel-test-prompt-navigation
    ghostel-test-sync-theme
    ghostel-test-apply-palette-default-colors
    ghostel-test-osc51-eval
    ghostel-test-osc51-eval-unknown
    ghostel-test-copy-mode-cursor
    ghostel-test-set-cursor-style-ignored-when-configured
    ghostel-test-set-cursor-style-applies-when-not-ignored
    ghostel-test-copy-mode-cursor-overrides-ignored-terminal-cursor
    ghostel-test-copy-mode-hl-line
    ghostel-test-copy-mode-uses-mode-line-process
    ghostel-test-suppress-interfering-modes-disables-pixel-scroll
    ghostel-test-ghostel-reuses-default-buffer
    ghostel-test-project-buffer-name
    ghostel-test-project-universal-arg
    ghostel-test-module-platform-tag-windows
    ghostel-test-module-asset-name-windows
    ghostel-test-start-process-windows-conpty-skips-shell-wrapper
    ghostel-test-module-download-url-uses-minimum-version
    ghostel-test-download-module-prefix-empty-uses-latest
    ghostel-test-download-module-prefix-rejects-too-old-version
    ghostel-test-compile-module-invokes-zig-build
    ghostel-test-module-compile-command-uses-helper-with-package-dir
    ghostel-test-compile-module-publishes-loader-target-and-metadata
    ghostel-test-replace-module-file-deletes-before-rotating
    ghostel-test-publish-downloaded-module-archive-preserves-existing-windows-backups
    ghostel-test-publish-built-module-artifacts-rotates-existing-windows-modules
    ghostel-test-publish-built-module-artifacts-errors-when-conpty-missing
    ghostel-test-module-version-match
    ghostel-test-module-version-mismatch
    ghostel-test-module-version-newer-than-minimum
    ghostel-test-delayed-redraw-keeps-point-when-cursor-follow-disabled
    ghostel-test-immediate-redraw-triggers-on-small-echo
    ghostel-test-immediate-redraw-skips-large-output
    ghostel-test-immediate-redraw-skips-stale-send
    ghostel-test-immediate-redraw-disabled-when-zero
    ghostel-test-input-coalesce-buffers-single-chars
    ghostel-test-input-coalesce-disabled
    ghostel-test-input-flush-sends-buffered
    ghostel-test-send-encoded-sets-send-time
    ghostel-test-send-encoded-no-send-time-on-fallback
    ghostel-test-send-key-dispatches-through-process-transport
    ghostel-test-control-key-bindings-cover-upstream-range
    ghostel-test-meta-key-bindings-reach-terminal
    ghostel-test-mouse-bindings-reach-terminal
    ghostel-test-mouse-press-dispatches-terminal-event
    ghostel-test-mouse-wheel-up-forwards-to-terminal-when-tracking-enabled
    ghostel-test-mouse-wheel-up-scrolls-scrollback-when-tracking-disabled
    ghostel-test-window-resize-dispatches-through-process-transport
    ghostel-test-loader-module-file-path-remains-stable
    ghostel-test-target-module-file-name-is-stable
    ghostel-test-conpty-module-file-path-uses-custom-dir
    ghostel-test-loader-metadata-path-uses-module-dir
    ghostel-test-download-module-publishes-target-module-path
    ghostel-test-load-module-if-available-loads-conpty-module-on-windows
    ghostel-test-load-module-if-available-errors-when-metadata-points-to-missing-target-module
    ghostel-test-load-module-if-available-skips-when-metadata-missing
    ghostel-test-ensure-conpty-loaded-errors-when-module-missing
    ghostel-test-close-live-buffers-terminates-conpty-and-process
    ghostel-test-sentinel-kills-conpty-backend-on-exit
    ghostel-test-reload-module-refuses-with-live-terminals
    ghostel-test-reload-module-swaps-generation-when-safe
    ghostel-test-reload-module-keeps-user-state-on-failure
    ghostel-test-reload-module-surfaces-abi-mismatch)
  "Tests that require only Elisp (no native module).")

(defun ghostel-test-run-elisp ()
  "Run only pure Elisp tests (no native module required)."
  (ert-run-tests-batch-and-exit
   `(member ,@ghostel-test--elisp-tests)))

(defun ghostel-test-run ()
  "Run all ghostel tests."
  (ert-run-tests-batch-and-exit "^ghostel-test-"))

;;; ghostel-test.el ends here
