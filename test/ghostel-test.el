;;; ghostel-test.el --- Tests for ghostel -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with: emacs --batch -Q -L . -l test/ghostel-test.el -f ghostel-test-run

;;; Code:

(require 'ghostel)

(defvar ghostel-test--pass 0)
(defvar ghostel-test--fail 0)
(defvar ghostel-test--errors nil)

(defun ghostel-test--assert (name condition)
  "Assert CONDITION is non-nil for test NAME."
  (if condition
      (progn
        (setq ghostel-test--pass (1+ ghostel-test--pass))
        (message "  PASS %s" name))
    (setq ghostel-test--fail (1+ ghostel-test--fail))
    (push name ghostel-test--errors)
    (message "  FAIL %s" name)))

(defun ghostel-test--assert-equal (name expected actual)
  "Assert EXPECTED equals ACTUAL for test NAME."
  (if (equal expected actual)
      (progn
        (setq ghostel-test--pass (1+ ghostel-test--pass))
        (message "  PASS %s" name))
    (setq ghostel-test--fail (1+ ghostel-test--fail))
    (push (format "%s: expected %S, got %S" name expected actual) ghostel-test--errors)
    (message "  FAIL %s: expected %S, got %S" name expected actual)))

(defun ghostel-test--assert-match (name pattern actual)
  "Assert ACTUAL matches regex PATTERN for test NAME."
  (if (and (stringp actual) (string-match-p pattern actual))
      (progn
        (setq ghostel-test--pass (1+ ghostel-test--pass))
        (message "  PASS %s" name))
    (setq ghostel-test--fail (1+ ghostel-test--fail))
    (push (format "%s: %S !~ %S" name actual pattern) ghostel-test--errors)
    (message "  FAIL %s: %S did not match %S" name actual pattern)))

;;; Helper: read first N rows from render state via debug-state

(defun ghostel-test--row0 (term)
  "Return the first row text from the render state of TERM."
  (let ((state (ghostel--debug-state term)))
    (when (string-match "row0=\"\\([^\"]*\\)\"" state)
      ;; Trim trailing spaces
      (string-trim-right (match-string 1 state)))))

(defun ghostel-test--cursor (term)
  "Return (COL . ROW) cursor position from debug-feed."
  (let ((info (ghostel--debug-feed term "")))
    (when (string-match "cur=(\\([0-9]+\\),\\([0-9]+\\))" info)
      (cons (string-to-number (match-string 1 info))
            (string-to-number (match-string 2 info))))))

;; -----------------------------------------------------------------------
;; Test: terminal creation
;; -----------------------------------------------------------------------

(defun ghostel-test-create ()
  "Test terminal creation and basic properties."
  (message "--- terminal creation ---")
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel-test--assert "create returns non-nil" term)
    ;; Fresh terminal should have empty rows
    (let ((row (ghostel-test--row0 term)))
      (ghostel-test--assert-equal "row0 is blank" "" row))
    ;; Cursor should be at (0,0)
    (let ((cur (ghostel-test--cursor term)))
      (ghostel-test--assert-equal "cursor at origin" '(0 . 0) cur))))

;; -----------------------------------------------------------------------
;; Test: write-input and render state
;; -----------------------------------------------------------------------

(defun ghostel-test-write-input ()
  "Test feeding text to the terminal."
  (message "--- write-input ---")
  (let ((term (ghostel--new 25 80 1000)))
    ;; Simple text
    (ghostel--write-input term "hello")
    (ghostel-test--assert-equal "text appears" "hello" (ghostel-test--row0 term))
    (ghostel-test--assert-equal "cursor after text" '(5 . 0) (ghostel-test--cursor term))

    ;; Newline (CRLF — the Zig module normalizes bare LF)
    (ghostel--write-input term " world\nline2")
    (let ((state (ghostel--debug-state term)))
      (ghostel-test--assert-match "row0 has full first line" "hello world" state)
      (ghostel-test--assert-match "row1 has line2" "line2" state))))

;; -----------------------------------------------------------------------
;; Test: backspace handling
;; -----------------------------------------------------------------------

(defun ghostel-test-backspace ()
  "Test backspace (BS) processing by the terminal."
  (message "--- backspace ---")
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "hello")
    (ghostel-test--assert-equal "before BS" "hello" (ghostel-test--row0 term))

    ;; BS + space + BS erases last character
    (ghostel--write-input term "\b \b")
    (ghostel-test--assert-equal "after 1 BS" "hell" (ghostel-test--row0 term))
    (ghostel-test--assert-equal "cursor after BS" '(4 . 0) (ghostel-test--cursor term))

    ;; Multiple backspaces
    (ghostel--write-input term "\b \b\b \b")
    (ghostel-test--assert-equal "after 3 BS total" "he" (ghostel-test--row0 term))))

;; -----------------------------------------------------------------------
;; Test: cursor movement escape sequences
;; -----------------------------------------------------------------------

(defun ghostel-test-cursor-movement ()
  "Test CSI cursor movement sequences."
  (message "--- cursor movement ---")
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "abcdef")
    ;; Cursor left 3
    (ghostel--write-input term "\e[3D")
    (ghostel-test--assert-equal "cursor left 3" '(3 . 0) (ghostel-test--cursor term))

    ;; Cursor right 1
    (ghostel--write-input term "\e[1C")
    (ghostel-test--assert-equal "cursor right 1" '(4 . 0) (ghostel-test--cursor term))

    ;; Cursor to home
    (ghostel--write-input term "\e[H")
    (ghostel-test--assert-equal "cursor home" '(0 . 0) (ghostel-test--cursor term))

    ;; Cursor to specific position (row 3, col 5 — 1-based in CSI)
    (ghostel--write-input term "\e[4;6H")
    (ghostel-test--assert-equal "cursor to (5,3)" '(5 . 3) (ghostel-test--cursor term))))

;; -----------------------------------------------------------------------
;; Test: erase sequences
;; -----------------------------------------------------------------------

(defun ghostel-test-erase ()
  "Test CSI erase sequences."
  (message "--- erase ---")
  (let ((term (ghostel--new 25 80 1000)))
    ;; Write text, then erase from cursor to end of line
    (ghostel--write-input term "hello world")
    (ghostel--write-input term "\e[6D")   ; cursor left 6 (on 'w')
    (ghostel--write-input term "\e[K")    ; erase to end of line
    (ghostel-test--assert-equal "erase to EOL" "hello" (ghostel-test--row0 term))

    ;; Erase entire line
    (ghostel--write-input term "\e[2K")
    (ghostel-test--assert-equal "erase whole line" "" (ghostel-test--row0 term))))

;; -----------------------------------------------------------------------
;; Test: terminal resize
;; -----------------------------------------------------------------------

(defun ghostel-test-resize ()
  "Test terminal resize."
  (message "--- resize ---")
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "hello")
    ;; Resize to 10 rows, 40 cols
    (ghostel--set-size term 10 40)
    ;; Content should survive
    (ghostel-test--assert-equal "content after resize" "hello" (ghostel-test--row0 term))
    ;; Write long text to verify new width
    (ghostel--write-input term "\r\n")
    (ghostel--write-input term (make-string 40 ?x))
    (let ((state (ghostel--debug-state term)))
      (ghostel-test--assert-match "40 x's on row" "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" state))))

;; -----------------------------------------------------------------------
;; Test: scrollback
;; -----------------------------------------------------------------------

(defun ghostel-test-scrollback ()
  "Test scrollback by overflowing visible rows."
  (message "--- scrollback ---")
  (let ((term (ghostel--new 5 80 100)))
    ;; Write more lines than the terminal height
    (dotimes (i 10)
      (ghostel--write-input term (format "line %d\r\n" i)))
    ;; Last visible lines should be the most recent
    (let ((state (ghostel--debug-state term)))
      (ghostel-test--assert-match "recent lines visible" "line [6-9]" state))
    ;; Scroll up into scrollback
    (ghostel--scroll term -5)
    (let ((state (ghostel--debug-state term)))
      (ghostel-test--assert-match "scrollback shows earlier lines" "line [0-4]" state))))

;; -----------------------------------------------------------------------
;; Test: SGR styling (bold, color, etc.)
;; -----------------------------------------------------------------------

(defun ghostel-test-sgr ()
  "Test SGR escape sequences set cell styles."
  (message "--- SGR styling ---")
  (let ((term (ghostel--new 25 80 1000)))
    ;; Bold + red text
    (ghostel--write-input term "\e[1;31mHELLO\e[0m normal")
    (ghostel-test--assert-equal "styled text content" "HELLO normal"
                                (ghostel-test--row0 term))))

;; -----------------------------------------------------------------------
;; Test: title change (OSC 2)
;; -----------------------------------------------------------------------

(defun ghostel-test-title ()
  "Test OSC 2 title change."
  (message "--- title ---")
  (let ((term (ghostel--new 25 80 1000)))
    ;; OSC 2 ; title ST
    (ghostel--write-input term "\e]2;My Title\e\\")
    (let ((title (ghostel--get-title term)))
      (ghostel-test--assert-equal "title set via OSC 2" "My Title" title))))

;; -----------------------------------------------------------------------
;; Test: CRLF normalization in Zig
;; -----------------------------------------------------------------------

(defun ghostel-test-crlf ()
  "Test that bare LF is normalized to CRLF by the Zig module."
  (message "--- CRLF normalization ---")
  (let ((term (ghostel--new 25 80 1000)))
    ;; Bare LF should be treated as CRLF (cursor returns to column 0)
    (ghostel--write-input term "first\nsecond")
    (let ((state (ghostel--debug-state term)))
      (ghostel-test--assert-match "first line" "first" state)
      (ghostel-test--assert-match "second line" "second" state))
    ;; Cursor should be on second line, after "second"
    (let ((cur (ghostel-test--cursor term)))
      (ghostel-test--assert-equal "cursor col after LF" 6 (car cur))
      (ghostel-test--assert "cursor moved to row 1+" (> (cdr cur) 0)))))

;; -----------------------------------------------------------------------
;; Test: raw key sequence fallback
;; -----------------------------------------------------------------------

(defun ghostel-test-raw-key-sequences ()
  "Test the Elisp raw key sequence builder."
  (message "--- raw key sequences ---")
  ;; Basic keys
  (ghostel-test--assert-equal "backspace" "\x7f" (ghostel--raw-key-sequence "backspace" ""))
  (ghostel-test--assert-equal "return" "\r" (ghostel--raw-key-sequence "return" ""))
  (ghostel-test--assert-equal "tab" "\t" (ghostel--raw-key-sequence "tab" ""))
  (ghostel-test--assert-equal "escape" "\e" (ghostel--raw-key-sequence "escape" ""))
  ;; Cursor keys
  (ghostel-test--assert-equal "up" "\e[A" (ghostel--raw-key-sequence "up" ""))
  (ghostel-test--assert-equal "down" "\e[B" (ghostel--raw-key-sequence "down" ""))
  (ghostel-test--assert-equal "right" "\e[C" (ghostel--raw-key-sequence "right" ""))
  (ghostel-test--assert-equal "left" "\e[D" (ghostel--raw-key-sequence "left" ""))
  ;; Shift+arrow
  (ghostel-test--assert-equal "shift-up" "\e[1;2A" (ghostel--raw-key-sequence "up" "shift"))
  ;; Ctrl+letter
  (ghostel-test--assert-equal "ctrl-a" "\x01" (ghostel--raw-key-sequence "a" "ctrl"))
  (ghostel-test--assert-equal "ctrl-c" "\x03" (ghostel--raw-key-sequence "c" "ctrl"))
  (ghostel-test--assert-equal "ctrl-z" "\x1a" (ghostel--raw-key-sequence "z" "ctrl"))
  ;; Function keys
  (ghostel-test--assert-equal "f1" "\eOP" (ghostel--raw-key-sequence "f1" ""))
  (ghostel-test--assert-equal "f5" "\e[15~" (ghostel--raw-key-sequence "f5" ""))
  (ghostel-test--assert-equal "f12" "\e[24~" (ghostel--raw-key-sequence "f12" ""))
  ;; Tilde keys
  (ghostel-test--assert-equal "insert" "\e[2~" (ghostel--raw-key-sequence "insert" ""))
  (ghostel-test--assert-equal "delete" "\e[3~" (ghostel--raw-key-sequence "delete" ""))
  (ghostel-test--assert-equal "pgup" "\e[5~" (ghostel--raw-key-sequence "prior" ""))
  ;; Unknown key
  (ghostel-test--assert-equal "unknown" nil (ghostel--raw-key-sequence "xyzzy" "")))

;; -----------------------------------------------------------------------
;; Test: modifier number calculation
;; -----------------------------------------------------------------------

(defun ghostel-test-modifier-number ()
  "Test modifier bitmask parsing."
  (message "--- modifier numbers ---")
  (ghostel-test--assert-equal "no mods" 0 (ghostel--modifier-number ""))
  (ghostel-test--assert-equal "shift" 1 (ghostel--modifier-number "shift"))
  (ghostel-test--assert-equal "ctrl" 4 (ghostel--modifier-number "ctrl"))
  (ghostel-test--assert-equal "alt" 2 (ghostel--modifier-number "alt"))
  (ghostel-test--assert-equal "meta" 2 (ghostel--modifier-number "meta"))
  (ghostel-test--assert-equal "shift,ctrl" 5 (ghostel--modifier-number "shift,ctrl"))
  (ghostel-test--assert-equal "control" 4 (ghostel--modifier-number "control")))

;; -----------------------------------------------------------------------
;; Test: shell process integration
;; -----------------------------------------------------------------------

(defun ghostel-test-shell-integration ()
  "Test shell process with echo command."
  (message "--- shell integration ---")
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
            (ghostel-test--assert "shell process alive" (process-live-p proc))

            ;; Run a command
            (process-send-string proc "echo GHOSTEL_TEST_OK\n")
            (dotimes (_ 10) (accept-process-output proc 0.2))
            (let ((state (ghostel--debug-state ghostel--term)))
              (ghostel-test--assert-match "command output visible"
                                          "GHOSTEL_TEST_OK" state))

            ;; Test typing + backspace via PTY echo
            (process-send-string proc "abc")
            (dotimes (_ 5) (accept-process-output proc 0.2))
            (let ((state (ghostel--debug-state ghostel--term)))
              (ghostel-test--assert-match "typed text visible" "abc" state))

            (process-send-string proc "\x7f")
            (dotimes (_ 5) (accept-process-output proc 0.2))
            (let ((state (ghostel--debug-state ghostel--term)))
              ;; After BS, "abc" should become "ab"
              (ghostel-test--assert-match "backspace removed char" "ab" state)
              ;; And "abc" should no longer appear as a complete word
              (ghostel-test--assert "no abc after BS"
                                    (not (string-match-p "abc" state))))

            (delete-process proc)))
      (kill-buffer buf))))

;; -----------------------------------------------------------------------
;; Test: update-directory
;; -----------------------------------------------------------------------

(defun ghostel-test-update-directory ()
  "Test OSC 7 directory tracking helper."
  (message "--- update-directory ---")
  (let ((ghostel--last-directory nil))
    ;; Plain path
    (ghostel--update-directory "/tmp")
    (ghostel-test--assert-equal "plain path" "/tmp/" default-directory)
    ;; file:// URL
    (ghostel--update-directory "file:///usr")
    (ghostel-test--assert-equal "file URL" "/usr/" default-directory)
    ;; Dedup: same path shouldn't re-trigger
    (let ((old ghostel--last-directory))
      (ghostel--update-directory "file:///usr")
      (ghostel-test--assert-equal "dedup" old ghostel--last-directory))))

;; -----------------------------------------------------------------------
;; Test: incremental (partial) redraw
;; -----------------------------------------------------------------------

(defun ghostel-test-incremental-redraw ()
  "Test that incremental redraw correctly updates dirty rows."
  (message "--- incremental redraw ---")
  (let ((buf (generate-new-buffer " *ghostel-test-redraw*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            ;; Write some initial content
            (ghostel--write-input term "line-A\r\nline-B\r\nline-C")
            ;; Full redraw
            (ghostel--redraw term)
            (ghostel-test--assert-match "initial row0" "line-A"
                                        (buffer-substring-no-properties (point-min) (point-max)))
            (ghostel-test--assert-match "initial row1" "line-B"
                                        (buffer-substring-no-properties (point-min) (point-max)))
            (ghostel-test--assert-match "initial row2" "line-C"
                                        (buffer-substring-no-properties (point-min) (point-max)))

            ;; Now write more text on the current line (row 2) — only that row should be dirty
            (ghostel--write-input term " updated")
            ;; This redraw should be incremental (DIRTY_PARTIAL)
            (ghostel--redraw term)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (ghostel-test--assert-match "row0 preserved" "line-A" content)
              (ghostel-test--assert-match "row1 preserved" "line-B" content)
              (ghostel-test--assert-match "row2 updated" "line-C updated" content))

            ;; Verify buffer has proper line structure (5 rows)
            (ghostel-test--assert-equal "line count"
                                        5
                                        (count-lines (point-min) (point-max)))))
      (kill-buffer buf))))

;; -----------------------------------------------------------------------
;; Runner
;; -----------------------------------------------------------------------

(defun ghostel-test-run ()
  "Run all ghostel tests."
  (setq ghostel-test--pass 0
        ghostel-test--fail 0
        ghostel-test--errors nil)
  (message "Running ghostel tests...\n")

  ;; Pure Elisp tests (no native module needed for these)
  (ghostel-test-raw-key-sequences)
  (ghostel-test-modifier-number)
  (ghostel-test-update-directory)

  ;; Native module tests
  (ghostel-test-create)
  (ghostel-test-write-input)
  (ghostel-test-backspace)
  (ghostel-test-cursor-movement)
  (ghostel-test-erase)
  (ghostel-test-resize)
  (ghostel-test-scrollback)
  (ghostel-test-sgr)
  (ghostel-test-title)
  (ghostel-test-crlf)
  (ghostel-test-incremental-redraw)

  ;; Integration test (spawns a real shell)
  (ghostel-test-shell-integration)

  (message "\n========================================")
  (message "Results: %d passed, %d failed" ghostel-test--pass ghostel-test--fail)
  (when ghostel-test--errors
    (message "Failures:")
    (dolist (e (nreverse ghostel-test--errors))
      (message "  - %s" e)))
  (message "========================================")

  (kill-emacs (if (= ghostel-test--fail 0) 0 1)))

;;; ghostel-test.el ends here
