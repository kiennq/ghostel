;;; ghostel-scrollback-test.el --- Tests for ghostel: scrollback -*- lexical-binding: t; -*-

;;; Commentary:

;; Scrollback materialization & eviction, clear-screen / clear-scrollback,
;; dirty-row reuse, soft-wraps, redraw scroll / anchor preservation,
;; hidden-buffer deferral.

;;; Code:

(require 'ghostel-test-helpers)

(defvar x-preedit-overlay)
(defvar pgtk-preedit-overlay)

(defun ghostel-test--mark-all-lines-clean ()
  "Mark every line in the current buffer with `ghostel-test-clean' property.
Used with `ghostel-test--line-clean-p' to detect whether the redrawer
rebuilt a line: a rebuild calls `delete-region' on the line, stripping
all text properties including this sentinel."
  (let ((inhibit-read-only t))
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (put-text-property (point) (1+ (point)) 'ghostel-test-clean t)
        (forward-line 1)))))

(defun ghostel-test--line-clean-p (n)
  "Return non-nil if line N (0-indexed from `point-min') was not rebuilt.
The `ghostel-test-clean' property is placed by
`ghostel-test--mark-all-lines-clean' and is stripped by the redrawer's
`delete-region' call when a line is rebuilt."
  (save-excursion
    (goto-char (point-min))
    (forward-line n)
    (get-text-property (point) 'ghostel-test-clean)))

(ert-deftest ghostel-test-redraw-preserves-mark ()
  "`ghostel--redraw' must keep `mark' stable across the destructive ops.
Full redraws call `eraseBuffer' and partial redraws `deleteRegion',
either of which would snap every marker in the buffer to `point-min'."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-mark*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 1000))
                 (inhibit-read-only t))
            (ghostel--write-input term "line one\r\nline two\r\nline three")
            (ghostel--redraw term t)
            ;; Anchor mark to "two" so its position sits well past point-min.
            (goto-char (point-min))
            (search-forward "two")
            (let ((target (point)))
              (set-marker (mark-marker) target)
              ;; Trigger a full redraw (erase-buffer path).
              (ghostel--write-input term " more")
              (ghostel--redraw term t)
              (should (= target (marker-position (mark-marker)))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-scrollback-in-buffer ()
  "After overflowing the viewport, scrolled-off rows live in the Emacs buffer.
This is the vterm-style growing-buffer model that lets `isearch' and
`consult-line' search history without entering copy mode."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-sb-buffer*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t))
            ;; Write 12 lines into a 5-row terminal — 7 should scroll off.
            (dotimes (i 12)
              (ghostel--write-input term (format "row-%02d\r\n" i)))
            (ghostel--redraw term t)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              ;; Earliest row that scrolled off must now live in the buffer.
              (should (string-match-p "row-00" content))
              ;; A middle row that scrolled off must also be present.
              (should (string-match-p "row-05" content))
              ;; The most recent row is on the active screen.
              (should (string-match-p "row-11" content)))
            ;; 12 distinct rows made it into the buffer + trailing newline
            (should (= 13 (count-lines (point-min) (point-max))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-scrollback-bootstrap-not-blank ()
  "First-time scrollback materialization must contain actual content.
Regression test: when the initial (mostly empty) viewport was rendered
and then a burst of output overflowed the screen, the promotion
optimisation incorrectly kept the stale empty rows as scrollback
instead of fetching the real content from libghostty."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-sb-bootstrap*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t))
            ;; Render the initial (nearly empty) viewport so the buffer
            ;; has 5 rows of stale content — simulates a fresh terminal.
            (ghostel--write-input term "$ \r\n")
            (ghostel--redraw term t)
            ;; Now a burst of output overflows the viewport.
            (dotimes (i 15)
              (ghostel--write-input term (format "line-%02d\r\n" i)))
            (ghostel--redraw term t)
            ;; The scrollback region (above the viewport) must contain
            ;; the actual output, not blank lines from the old viewport.
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "\\$ " content))   ; prompt survived
              (should (string-match-p "line-00" content)) ; first output line
              (should (string-match-p "line-05" content)) ; middle output line
              ;; No blank lines in the scrollback region: every line
              ;; before the viewport should have visible content.
              (goto-char (point-min))
              (let ((blank-count 0))
                (while (and (not (eobp))
                            (< (line-number-at-pos) (- (line-number-at-pos (point-max)) 4)))
                  (when (looking-at-p "^$")
                    (setq blank-count (1+ blank-count)))
                  (forward-line 1))
                (should (= 0 blank-count))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-render-trims-trailing-whitespace ()
  "Rendered rows do not carry libghostty's full-width padding.
The renderer should only keep cells the terminal actually wrote to,
so a short line in a 40-column terminal shows up as the written
content plus no trailing space padding.  Shell-written spaces
\(e.g. the trailing space in a \\='$ \\=' prompt or `%-80s' layout)
are retained — only unwritten padding cells are trimmed."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-trim-ws*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 3 40 100))
                 (inhibit-read-only t))
            ;; Write `hi` at the top-left and redraw.
            (ghostel--write-input term "\e[H\e[2Jhi")
            (ghostel--redraw term t)
            (let ((lines (split-string (buffer-substring-no-properties
                                        (point-min) (point-max))
                                       "\n")))
              ;; First row is trimmed to "hi" (no trailing spaces).
              (should (equal "hi" (car lines)))
              ;; Remaining rows are empty (not rows of 40 spaces).
              (dolist (row (cdr lines))
                (should (string-empty-p row))))
            ;; Shell-written trailing space is preserved.
            (ghostel--write-input term "\e[H\e[2J$ ")
            (ghostel--redraw term t)
            (let ((lines (split-string (buffer-substring-no-properties
                                        (point-min) (point-max))
                                       "\n")))
              (should (equal "$ " (car lines))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-scrollback-preserves-url-properties ()
  "Verify delayed plain-link properties survive scrollback promotion.
When libghostty pushes a row into scrollback, the redraw promotes the
existing buffer text instead of fetching a fresh copy from libghostty,
so any text properties the row earned while it was the viewport stay
attached."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-sb-url*")))
    (unwind-protect
        (with-current-buffer buf
          (set-window-buffer (selected-window) (current-buffer))
          (ghostel-mode)
          (let* ((term (ghostel--new 5 80 1000))
                 (ghostel--term term)
                 (ghostel--term-rows 5)
                 (ghostel-plain-link-detection-delay 0)
                 (inhibit-read-only t)
                 (ghostel-enable-url-detection t)
                 (ghostel-enable-file-detection nil))
            ;; Write a row with a URL while it's in the viewport.
            (ghostel--write-input term "see https://example.com here\r\n")
            ;; Run the supported redraw path; zero delay keeps the deferred
            ;; post-processing deterministic while still exercising it.
            (ghostel--delayed-redraw buf)
            ;; Sanity: delayed plain-link detection applied a help-echo while
            ;; the row is visible.
            (goto-char (point-min))
            (let ((url-pos (search-forward "https://example.com" nil t)))
              (should url-pos)
              (should (equal "https://example.com"
                             (get-text-property (- url-pos 19) 'help-echo))))
            ;; Now scroll the URL row off the active screen.
            (dotimes (_ 6) (ghostel--write-input term "filler\r\n"))
            (ghostel--delayed-redraw buf)
            ;; The URL row now lives in the scrollback region of the buffer.
            (goto-char (point-min))
            (let ((url-pos (search-forward "https://example.com" nil t)))
              (should url-pos)
              ;; The clickable text properties survived the scroll because
              ;; promotion preserved the buffer text instead of re-fetching
              ;; from libghostty.
              (should (equal "https://example.com"
                             (get-text-property (- url-pos 19) 'help-echo))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-scrollback-grows-incrementally ()
  "Successive redraws append newly-scrolled-off rows without losing history."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-sb-incr*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t))
            ;; First batch: write 8 lines, redraw.
            (dotimes (i 8)
              (ghostel--write-input term (format "first-%02d\r\n" i)))
            (ghostel--redraw term t)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "first-00" content))
              (should (string-match-p "first-07" content)))
            ;; Second batch: write more lines, redraw again.
            (dotimes (i 6)
              (ghostel--write-input term (format "second-%02d\r\n" i)))
            (ghostel--redraw term t)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              ;; All earlier scrollback rows survive the second redraw.
              (should (string-match-p "first-00" content))
              (should (string-match-p "first-07" content))
              (should (string-match-p "second-00" content))
              (should (string-match-p "second-05" content)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-delayed-redraw-skips-native-redraw-without-window ()
  "When the buffer has no window, `ghostel--delayed-redraw' must not call \
`ghostel--redraw'."
  (let ((buf (generate-new-buffer " *ghostel-test-no-window-redraw*"))
        (ghostel-detect-password-prompts nil))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          ;; The buffer from `generate-new-buffer' is not displayed in
          ;; any window, so `ghostel--get-render-window' returns nil
          ;; naturally — no need to stub `get-buffer-window-list'.
          (let ((ghostel--term t)
                (redraw-called nil))
            (cl-letf (((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--redraw)
                       (lambda (&rest _) (setq redraw-called t))))
              (ghostel--delayed-redraw buf)
              (should-not redraw-called))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-defers-redraw-while-hidden ()
  "Buffer is not redrawn while hidden.
When the buffer reappears, it is immediately redrawn."
  :tags '(native)
  (let* ((win (selected-window))
         (orig-buf (window-buffer win))
         (buf (generate-new-buffer " *ghostel-test-hidden-defer*")))
    (unwind-protect
        (progn
          (set-window-buffer win buf)
          (with-current-buffer buf
            (ghostel-mode)
            (let* ((term (ghostel--new 5 40 100))
                   (ghostel--term term)
                   (ghostel--term-rows 5)
                   (inhibit-read-only t))
              (ghostel--write-input term "initial\r\n")
              (ghostel--redraw term t)
              (should (string-match-p "initial" (buffer-string)))

              ;; Hide the buffer.
              (set-window-buffer win orig-buf)

              ;; Output arrives while hidden but does not appear; make
              ;; run-with-timer fire synchronously so no sleep is needed.
              (ghostel--write-input term "while-hidden\r\n")
              (cl-letf (((symbol-function 'run-with-timer)
                         (lambda (_delay _repeat fn &rest args)
                           (apply fn args) nil)))
                (ghostel--invalidate))

              ;; Redraw blocked: buffer still shows the old content.
              (should-not (string-match-p "while-hidden" (buffer-string)))

              ;; Reshow the buffer; hook calls ghostel--invalidate again.
              (set-window-buffer win buf)
              (cl-letf (((symbol-function 'run-with-timer)
                         (lambda (_delay _repeat fn &rest args)
                           (apply fn args) nil)))
                (run-hook-with-args 'window-buffer-change-functions win))

              (should (string-match-p "while-hidden" (buffer-string))))))
      (set-window-buffer win orig-buf)
      (kill-buffer buf))))

(ert-deftest ghostel-test-pty-output-is-processed-when-buffer-is-hidden ()
  "Output is processed but not drawn while the buffer is hidden.
When the buffer reappears, it is immediately redrawn."
  :tags '(native)
  (let* ((win (selected-window))
         (orig-buf (window-buffer win))
         (buf (generate-new-buffer " *ghostel-test-hidden-defer*")))
    (unwind-protect
        (progn
          (set-window-buffer win buf)
          (with-current-buffer buf
            (ghostel-mode)
            (let* ((term (ghostel--new 5 40 100))
                   (ghostel--term term)
                   (ghostel--term-rows 5)
                   (inhibit-read-only t))
              (ghostel--write-input term "initial\r\n")
              (ghostel--redraw term t)
              (should (string-match-p "initial" (buffer-string)))

              ;; Hide the buffer.
              (set-window-buffer win orig-buf)

              ;; Simulate process output; make run-with-timer fire
              ;; synchronously so no sleep is needed.
              (cl-letf (((symbol-function 'run-with-timer)
                         (lambda (_delay _repeat fn &rest args)
                           (apply fn args) nil))
                        ((symbol-function 'process-buffer)
                         (lambda (_) buf)))
                (ghostel--filter nil "while-hidden\r\n"))
              (should-not (string-match-p "while-hidden" (buffer-string)))

              ;; Output should have been processed so force redrawing should
              ;; show it:
              (ghostel--redraw term)
              (should (string-match-p "while-hidden" (buffer-string))))))
      (set-window-buffer win orig-buf)
      (kill-buffer buf))))

(ert-deftest ghostel-test-clear-screen ()
  "Test that ghostel-clear clears the visible screen but preserves scrollback.
With the growing-buffer model the scrollback is always materialized into
the Emacs buffer, so we just check the buffer text directly instead of
scrolling libghostty's viewport."
  :tags '(native)
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
            (ghostel-test--wait-for proc
                                    (lambda () ghostel--pending-output) 10)
            (ghostel--flush-pending-output)
            (let ((inhibit-read-only t)) (ghostel--redraw ghostel--term t))
            ;; Generate scrollback
            (dotimes (i 15)
              (process-send-string proc (format "echo clear-test-%d\n" i)))
            (ghostel-test--wait-for proc
                                    (lambda ()
                                      (cl-some (lambda (s) (string-match-p "clear-test-14" s))
                                               ghostel--pending-output))
                                    10)
            ;; Do NOT manually flush — let ghostel-clear handle it
            (should (> (length ghostel--pending-output) 0))    ; pending output exists
            ;; Clear screen
            (ghostel-clear)
            ;; Simulate what delayed-redraw does
            (ghostel--flush-pending-output)
            (let ((inhibit-read-only t)) (ghostel--redraw ghostel--term t))
            ;; Scrollback rows live in the buffer above the cleared
            ;; viewport — search for any clear-test echo to confirm.
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "clear-test-[0-9]+" content)))
            (delete-process proc)))
      (kill-buffer buf))))

(ert-deftest ghostel-test-scrollback-eviction-chunked ()
  "Scrollback eviction works for chunked writes with interleaved renders.
Writes a small batch, renders, then writes a large batch across many
small writes interspersed with renders.  The accumulated scrollback
from the second phase must evict the first phase from the Emacs
buffer."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-sb-evict*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 6 80 1024))
                 (inhibit-read-only t))
            ;; Write a small initial batch
            (dotimes (i 20)
              (ghostel--write-input term (format "early-%05d\r\n" i)))
            (ghostel--redraw term t)
            ;; Write a large batch in many small chunks with renders in between
            (dotimes (x 200)
              (dotimes (i 100)
                (ghostel--write-input term (format "late-%05d\r\n" i)))
              (ghostel--redraw term t))
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "late-" content))
              (should-not (string-match-p "early-" content)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-scrollback-eviction-bulk ()
  "Scrollback eviction works for a single large bulk write.
Writes a small batch, renders, then writes a massive amount in one go
that pushes all rows out of libghostty's scrollback cap at once.  The
second redraw must evict the first-batch rows from the Emacs buffer."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-sb-evict*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 6 80 1024))
                 (inhibit-read-only t))
            ;; Write a small initial batch
            (dotimes (i 20)
              (ghostel--write-input term (format "early-%05d\r\n" i)))
            (ghostel--redraw term t)
            ;; Write a huge amount in one shot
            (dotimes (i 200000)
              (ghostel--write-input term (format "late-%05d\r\n" i)))
            (ghostel--redraw term t)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "late-" content))
              (should-not (string-match-p "early-" content)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-no-stale-lines-in-scrollback ()
  "Rows modified and scrolled out in one write must not leak stale text.
A row that has been materialized in a previous render and is then
modified and scrolled out in a single write should not scroll out the
stale row."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-sb-buffer*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t))
            (ghostel--write-input term "wrong\r\n")
            (ghostel--redraw term t)
            (ghostel--write-input term "\e[Hfoobar\e[5;0Hyolo\r\n")
            (ghostel--redraw term t)
            (goto-char (point-min))
            (let ((line (buffer-substring-no-properties (line-beginning-position)
                                                        (line-end-position))))
              ;; Should now equal "foobar", not "wrong"
              (should (string= line "foobar")))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-clear-scrollback ()
  "Test that ghostel-clear-scrollback clears both screen and scrollback."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-clear-sb*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--term (ghostel--new 5 80 100))
          (let ((inhibit-read-only t))
            ;; Fill screen + scrollback with 10 lines
            (dotimes (i 10)
              (ghostel--write-input ghostel--term (format "line %d\r\n" i)))
            (ghostel--redraw ghostel--term t)
            ;; Verify lines materialized in the buffer
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "line 0" content))
              (should (string-match-p "line 9" content)))
            ;; Clear scrollback (sends CSI 3J to libghostty)
            (ghostel-clear-scrollback)
            (ghostel--redraw ghostel--term t)
            ;; Screen and scrollback should be empty
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should-not (string-match-p "line [0-9]" content)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-scrollback-csi3j-then-refill ()
  "CSI 3 J must not leave stale pre-clear rows in the buffer.

Scenario (5-row terminal, 10 before-* rows, CSI 3J, 5 after-* rows,
single redraw):
  - After the first redraw: before-00..before-05 are in scrollback (6
    rows scrolled off), before-06..before-09 fill the viewport.  The
    redraw parks libghostty's viewport at `max_offset - 1'.
  - CSI 3J clears libghostty's scrollback, which snaps the viewport
    back to the bottom (`offset + len == total').
  - Five new after-* rows scroll before-06..before-09 and after-00 into
    libghostty's freshly-cleared scrollback (5 rows); after-01..after-04
    are left in the viewport.
  - At the next redraw, the viewport-snap signal (`offset + len ==
    total' rather than the parked `max - 1') tells the renderer that
    libghostty cleared its scrollback, triggering an erase + full
    rebuild from the current libghostty state."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-csi3j-refill*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t))
            ;; Phase 1: fill scrollback with 10 "before" rows and redraw.
            (dotimes (i 10)
              (ghostel--write-input term (format "before-%02d\r\n" i)))
            (ghostel--redraw term t)
            ;; Confirm before-00..before-05 are now in the buffer's scrollback
            ;; and before-06..before-09 are in the viewport.
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "before-00" content))
              (should (string-match-p "before-05" content))
              (should (string-match-p "before-09" content)))
            ;; Phase 2: CSI 3 J (erase scrollback only) then immediately
            ;; write 5 "after" rows — no redraw in between.  before-06..before-09
            ;; scroll off into libghostty's freshly-cleared scrollback as the
            ;; after-* rows push through the viewport.
            (ghostel--write-input term "\e[3J")
            (dotimes (i 5)
              (ghostel--write-input term (format "after-%02d\r\n" i)))
            ;; Phase 3: single redraw — must rebuild from libghostty.
            (ghostel--redraw term t)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              ;; Rows that were in scrollback when CSI 3J fired are gone.
              (should-not (string-match-p "before-00" content))
              (should-not (string-match-p "before-05" content))
              ;; Rows that were in the viewport during CSI 3J are now in
              ;; libghostty's new scrollback and must be present.
              (should (string-match-p "before-06" content))
              (should (string-match-p "before-09" content))
              ;; after-00 scrolled into scrollback; after-01..after-04 in viewport.
              (should (string-match-p "after-00" content))
              (should (string-match-p "after-04" content)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-scrollback-not-rebuilt-on-shrink ()
  "Scrollback rows survive a vertical-only viewport shrink without rerendering.
A column-only or full resize erases and rebuilds the buffer, but shrinking
only the row count must leave existing scrollback lines untouched."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-sb-shrink*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t))
            ;; 8 rows into a 5-row terminal → lines 0-2 scroll into scrollback.
            (dotimes (i 8)
              (ghostel--write-input term (format "row-%02d\r\n" i)))
            (ghostel--redraw term t)
            ;; Stamp every line with the sentinel after the initial full render.
            (ghostel-test--mark-all-lines-clean)
            ;; Shrink rows only — columns are unchanged so the buffer is not erased.
            (ghostel--set-size term 3 80)
            (ghostel--redraw term)
            ;; The 3 original scrollback lines must not have been rebuilt.
            (should (ghostel-test--line-clean-p 0))
            (should (ghostel-test--line-clean-p 1))
            (should (ghostel-test--line-clean-p 2))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-scrollback-not-rebuilt-on-expand ()
  "Scrollback rows above the new active area survive a vertical viewport expand.
Expanding the row count pulls some scrollback rows back into the viewport,
but rows that remain in scrollback must not be rerendered."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-sb-expand*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t))
            ;; 20 rows into a 5-row terminal → 15 scrollback rows in the buffer.
            (dotimes (i 20)
              (ghostel--write-input term (format "row-%02d\r\n" i)))
            (ghostel--redraw term t)
            (ghostel-test--mark-all-lines-clean)
            ;; Expand to 8 rows.  The resize render re-renders the last 8 lines,
            ;; so lines 0-11 stay in scrollback and must remain untouched.
            (ghostel--set-size term 8 80)
            (ghostel--redraw term)
            (dotimes (i 12)
              (should (ghostel-test--line-clean-p i)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-content-preserved-across-vertical-resizes ()
  "Buffer content survives expand then shrink without loss or duplication.
Expands from the initial size (staying within the available scrollback so
no rows are pulled back) then shrinks below the original size.  No
assumption is made about which lines are rebuilt; the full buffer text
must be identical after each resize."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-resize-roundtrip*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t))
            ;; Write 20 rows into a 5-row terminal → 15 rows in scrollback.
            (dotimes (i 20)
              (ghostel--write-input term (format "row-%02d\r\n" i)))
            (ghostel--redraw term t)
            (let ((baseline (buffer-substring-no-properties (point-min) (point-max))))
              ;; Expand to 8 rows — within the 15-row scrollback, so no
              ;; rows are exhausted from libghostty's scrollback cap.
              (ghostel--set-size term 8 80)
              (ghostel--redraw term)
              (should (equal baseline (buffer-substring-no-properties (point-min) (point-max))))
              ;; Shrink to 3 rows — smaller than the original 5.
              (ghostel--set-size term 3 80)
              (ghostel--redraw term)
              (should (equal baseline (buffer-substring-no-properties (point-min) (point-max)))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-shrink-line-count-and-content ()
  "After a vertical shrink the buffer contracts to the new viewport row count.
With no scrollback the content fits entirely within the smaller viewport, so
the buffer must have exactly as many lines as the new row count — no phantom
rows left over from the previous larger size.  The first line must contain
the written content; all remaining lines must be empty."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-shrink-lines*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t))
            (ghostel--write-input term "hello\r\n")
            (ghostel--redraw term t)
            (ghostel--set-size term 3 80)
            (ghostel--redraw term)
            (should (= 3 (count-lines (point-min) (point-max))))
            (goto-char (point-min))
            (should (equal "hello"
                           (buffer-substring-no-properties
                            (line-beginning-position) (line-end-position))))
            (dotimes (_ 2)
              (forward-line 1)
              (should (equal ""
                             (buffer-substring-no-properties
                              (line-beginning-position) (line-end-position)))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-scrollback-not-rebuilt-on-new-row ()
  "Adding a row to a full viewport does not recreate existing scrollback rows.
When a new row pushes the top viewport row into scrollback, the rows
already in scrollback must remain untouched."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-sb-newrow*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t))
            ;; 8 rows → lines 0-2 are scrollback after the initial render.
            (dotimes (i 8)
              (ghostel--write-input term (format "first-%02d\r\n" i)))
            (ghostel--redraw term t)
            (ghostel-test--mark-all-lines-clean)
            ;; One more row scrolls through the viewport.
            (ghostel--write-input term "extra\r\n")
            (ghostel--redraw term)
            ;; The 3 pre-existing scrollback rows must not have been rebuilt.
            (should (ghostel-test--line-clean-p 0))
            (should (ghostel-test--line-clean-p 1))
            (should (ghostel-test--line-clean-p 2))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-partial-redraw-only-dirty-row-rebuilt ()
  "Modifying one active row rebuilds only that row; unchanged rows are preserved.
The incremental dirty-row path calls `delete-region' + re-insert for dirty rows
and `forward-line' for clean ones.  Only the dirty row loses the sentinel."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-partial-dirty*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 1000))
                 (inhibit-read-only t))
            ;; Fill the viewport and park the cursor on row 2 before the
            ;; initial draw.  This avoids dirtying row 4 on the second
            ;; render: a cursor move from row 4 → row 2 would dirty both
            ;; rows, breaking the single-dirty-row assertion below.
            (ghostel--write-input term "row-0\r\nrow-1\r\nrow-2\r\nrow-3\r\nrow-4\e[3;1H")
            (ghostel--redraw term t)
            (ghostel-test--mark-all-lines-clean)
            ;; Cursor is already on row 2; overwrite it in place.
            (ghostel--write-input term "modified")
            (ghostel--redraw term)
            ;; Row 2 was dirty and must have been rebuilt (sentinel gone).
            (should-not (ghostel-test--line-clean-p 2))
            ;; The remaining rows were clean and must not have been rebuilt.
            (should (ghostel-test--line-clean-p 0))
            (should (ghostel-test--line-clean-p 1))
            (should (ghostel-test--line-clean-p 3))
            (should (ghostel-test--line-clean-p 4))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-incremental-redraw ()
  "Test that incremental redraw correctly updates dirty rows."
  :tags '(native)
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

            (should (equal 5 (count-lines (point-min) (point-max))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-soft-wrap-copy ()
  "Test that soft-wrapped newlines are filtered during copy."
  :tags '(native)
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

(ert-deftest ghostel-test-resize-no-blank-flash ()
  "Buffer keeps old content after resize; redraw replaces it atomically.
Regression test: fnSetSize used to call `erase-buffer' synchronously,
leaving the buffer visibly empty until the next timer-driven redraw.
Now the erasure is deferred into redraw() under `inhibit-redisplay'."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-resize-no-blank*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 100))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            ;; Fill the viewport with identifiable content.
            (dotimes (i 10)
              (ghostel--write-input term (format "LINE-%02d\r\n" i)))
            (ghostel--redraw term t)
            (let ((pre-content (buffer-substring-no-properties
                                (point-min) (point-max))))
              (should (string-match-p "LINE-00" pre-content))
              (should (string-match-p "LINE-09" pre-content))

              ;; Resize — old content must survive in the buffer.
              (ghostel--set-size term 6 40)
              (setq ghostel--term-rows 6)
              (let ((mid-content (buffer-substring-no-properties
                                  (point-min) (point-max))))
                (should (> (length mid-content) 0))
                (should (string-match-p "LINE-" mid-content)))

              ;; Redraw rebuilds the buffer from the new terminal state.
              (ghostel--redraw term t)
              (let ((post-content (buffer-substring-no-properties
                                   (point-min) (point-max))))
                (should (> (length post-content) 0))
                ;; Viewport should have the new row count; extra lines
                ;; above are scrollback from the old viewport rows.
                (should (>= (count-lines (point-min) (point-max)) 6))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-resize-redraw-anchors-window-start ()
  "After resize + redraw, `window-start' is at the viewport origin.
Without explicit anchoring, erase+rebuild inside redraw() clamps
`window-start' to 1 (top of scrollback), causing a visible jump when
Emacs auto-scrolls to make point visible."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-resize-anchor*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (ghostel--force-next-redraw nil)
                 (inhibit-read-only t))
            ;; Build up scrollback so the viewport is not at buffer start.
            (dotimes (i 30)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--write-input term "prompt> ")
            (ghostel--redraw term t)
            (should (> (line-number-at-pos (point-max)) 10))

            ;; Display in a real window so we can test window-start.
            (set-window-buffer (selected-window) buf)
            ;; Simulate the pre-resize steady state: window was
            ;; following the viewport (auto-follow), and a prior
            ;; redraw anchored `window-start' at the viewport.
            (let ((vp-before (save-excursion
                               (goto-char (point-max))
                               (forward-line -10)
                               (line-beginning-position))))
              (set-window-start (selected-window) vp-before t))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)

            ;; Resize + redraw via delayed-redraw (simulates the real path).
            (ghostel--set-size term 6 40)
            (setq ghostel--term-rows 6)
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)

            ;; window-start should be at the viewport, not at buffer start.
            (let* ((ws (window-start (selected-window)))
                   (wp (window-point (selected-window)))
                   (vp-start (save-excursion
                               (goto-char (point-max))
                               (forward-line -6)
                               (line-beginning-position))))
              (should (= ws vp-start))
              (should (>= wp vp-start)))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-resets-vscroll ()
  "Redraw resets `window-vscroll' when point is in the viewport.
Regression for issue #105: with `pixel-scroll-precision-mode',
a non-zero pixel vscroll left on the window clips the top line
after a redraw (e.g. `clear').  Anchoring `window-start' alone is
not enough; the pixel offset must also be cleared."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-vscroll*"))
        (orig-buf (window-buffer (selected-window)))
        ;; Simulated pixel vscroll state per window.  Batch-mode
        ;; `window-vscroll' always returns 0, so we track the value
        ;; ourselves via a mocked `set-window-vscroll'.
        (vscroll-by-window (make-hash-table :test 'eq)))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--write-input term "prompt> ")
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            ;; Window was showing the viewport before the redraw — this
            ;; is the auto-follow case where vscroll must be reset.
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (let ((vp-before (save-excursion
                               (goto-char (point-max))
                               (forward-line -9)
                               (line-beginning-position))))
              (set-window-start (selected-window) vp-before t))
            ;; Seed a non-zero pixel vscroll (simulating what
            ;; `pixel-scroll-precision-mode' leaves behind).
            (puthash (selected-window) 7 vscroll-by-window)
            (cl-letf (((symbol-function 'set-window-vscroll)
                       (lambda (win vscroll &optional pixels-p &rest _)
                         (should (eq pixels-p t))
                         (puthash win vscroll vscroll-by-window))))
              (ghostel--delayed-redraw buf))
            (should (= 0 (gethash (selected-window) vscroll-by-window)))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-resets-vscroll-all-windows ()
  "Redraw resets `window-vscroll' on every window showing the buffer.
`ghostel--delayed-redraw' iterates `get-buffer-window-list' so both
windows must be anchored."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-vscroll-multi*"))
        (orig-config (current-window-configuration))
        (vscroll-by-window (make-hash-table :test 'eq)))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--write-input term "prompt> ")
            (ghostel--redraw term t)
            (goto-char (point-max))
            (delete-other-windows)
            (set-window-buffer (selected-window) buf)
            (let ((w1 (selected-window))
                  (w2 (split-window-vertically))
                  (vp-before (save-excursion
                               (goto-char (point-max))
                               (forward-line -9)
                               (line-beginning-position))))
              (set-window-buffer w2 buf)
              (set-window-point w1 (point-max))
              (set-window-point w2 (point-max))
              ;; Both windows were at the viewport pre-redraw.
              (set-window-start w1 vp-before t)
              (set-window-start w2 vp-before t)
              (puthash w1 7 vscroll-by-window)
              (puthash w2 4 vscroll-by-window)
              (cl-letf (((symbol-function 'set-window-vscroll)
                         (lambda (win vscroll &optional pixels-p &rest _)
                           (should (eq pixels-p t))
                           (puthash win vscroll vscroll-by-window))))
                (ghostel--delayed-redraw buf))
              (should (= 0 (gethash w1 vscroll-by-window)))
              (should (= 0 (gethash w2 vscroll-by-window))))))
      (set-window-configuration orig-config)
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-preserves-vscroll-in-scrollback ()
  "Redraw leaves `window-vscroll' alone when point is in scrollback.
The vscroll reset is gated on the same condition as `set-window-start':
a user reading history should not be pulled around by live redraws."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-vscroll-scrollback*"))
        (orig-buf (window-buffer (selected-window)))
        (vscroll-called nil))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            ;; Seed the anchor by running a prior redraw so subsequent
            ;; scroll-preservation logic is in steady state.
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (let ((vp (save-excursion
                        (goto-char (point-max))
                        (forward-line -9)
                        (line-beginning-position))))
              (set-window-start (selected-window) vp t))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)
            ;; Simulate the user scrolling into scrollback: both
            ;; window-start and point move above the viewport (that's
            ;; what real Emacs scrollers — pixel-scroll-precision,
            ;; mouse-wheel, scroll-up-command — produce).
            (goto-char (point-min))
            (set-window-point (selected-window) (point-min))
            (set-window-start (selected-window) (point-min) t)
            (cl-letf (((symbol-function 'set-window-vscroll)
                       (lambda (&rest _) (setq vscroll-called t))))
              (ghostel--delayed-redraw buf))
            (should-not vscroll-called)))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-captures-scrollback-on-first-non-anchored ()
  "First non-anchored redraw captures `window-start' / `window-point'.
Simulates wheel/pixel-scroll that moves `window-start' above the
viewport before any scroll-positions entry has been recorded.  The
redraw must not yank ws back to the viewport (no snap) and must
capture the new scrollback state so subsequent redraws can preserve
it through mangling."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-ws-scrollback*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (ghostel--snap-requested nil)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            ;; Seed the anchor via a prior redraw so we're in steady
            ;; auto-follow state before simulating the wheel-up.
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (let ((vp (save-excursion
                        (goto-char (point-max))
                        (forward-line -9)
                        (line-beginning-position))))
              (set-window-start (selected-window) vp t))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)
            ;; Simulate a scroller that moves window-start without moving
            ;; point (unusual but possible — e.g., pixel-scroll-precision
            ;; on a scroll that's small enough to keep point on-screen).
            (set-window-start (selected-window) (point-min) t)
            (let ((ws-before (window-start (selected-window)))
                  (wp-before (window-point (selected-window))))
              ;; No scroll-positions entry for this window yet, so the
              ;; pre-redraw restore is a no-op; this exercises capture,
              ;; not restoration.
              (should-not ghostel--scroll-positions)
              (ghostel--delayed-redraw buf)
              (should (= ws-before (window-start (selected-window))))
              (should (= wp-before (window-point (selected-window))))
              ;; And now scroll-positions has the captured entry.
              (should ghostel--scroll-positions))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-hidden-buffer-snaps-on-reshow ()
  "Buffer re-shown after output-while-hidden snaps to the viewport (issue #177).
Dispatches through `window-buffer-change-functions' so the hook
wiring — not just `ghostel--reshow-snap' in isolation — is exercised."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-177-snap*"))
        (other (get-buffer-create "*ghostel-test-177-other*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t)
                 (win (selected-window)))
            (dotimes (i 30)
              (ghostel--write-input term (format "pre-%02d\r\n" i)))
            (ghostel--write-input term "prompt> ")
            (ghostel--redraw term t)
            (set-window-buffer win buf)
            (goto-char (point-max))
            (set-window-point win (point-max))
            (set-window-start win (ghostel--viewport-start) t)
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)
            (let ((pre-hide-ws (window-start win)))
              ;; Hide; output arrives while hidden so the anchor advances.
              (set-window-buffer win other)
              (dotimes (i 30)
                (ghostel--write-input term (format "hidden-%02d\r\n" i)))
              (setq ghostel--force-next-redraw t)
              (ghostel--delayed-redraw buf)
              ;; Re-show with the stale pre-hide `window-start', then
              ;; dispatch the hook the way redisplay would.
              (set-window-buffer win buf)
              (set-window-start win pre-hide-ws t)
              (run-hook-with-args 'window-buffer-change-functions win)
              (setq ghostel--force-next-redraw t)
              (ghostel--delayed-redraw buf)
              (should (= (window-start win) (ghostel--viewport-start)))
              ;; The snap entry was consumed and cleared.
              (should-not ghostel--windows-needing-snap))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf)
      (when (buffer-live-p other) (kill-buffer other)))))

(ert-deftest ghostel-test-second-window-does-not-disturb-scrollback ()
  "Opening a second window on a ghostel buffer does not yank peer windows.
Issue #177 regression guard for the multi-window case: a window
already scrolled back for reading history must stay put when a new
window opens on the same buffer."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-177-multi*"))
        (orig-config (current-window-configuration))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t)
                 (win-a (selected-window)))
            (dotimes (i 30)
              (ghostel--write-input term (format "pre-%02d\r\n" i)))
            (ghostel--write-input term "prompt> ")
            (ghostel--redraw term t)
            (set-window-buffer win-a buf)
            (set-window-start win-a (ghostel--viewport-start) t)
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)
            ;; Scroll win-a into the scrollback.
            (set-window-start win-a (point-min) t)
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)
            (let ((scrollback-ws (window-start win-a))
                  (win-b (split-window win-a)))
              (set-window-buffer win-b buf)
              (set-window-start win-b (point-min) t)
              ;; Simulate the callback redisplay fires for the new window.
              (run-hook-with-args 'window-buffer-change-functions win-b)
              (setq ghostel--force-next-redraw t)
              (ghostel--delayed-redraw buf)
              ;; win-b snapped; win-a's scrollback is untouched.
              (should (= (window-start win-b) (ghostel--viewport-start)))
              (should (= (window-start win-a) scrollback-ws))
              (should-not ghostel--windows-needing-snap))))
      (set-window-configuration orig-config)
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-preserves-scroll-during-live-output ()
  "Scrollback view is preserved when live PTY output triggers a redraw.
Before the fix, any redraw timer firing while the user was reading
scrollback yanked `window-start' and cursor back to the viewport.  With
the fix, live output grows the buffer without disturbing the scrolled-up
view or the user's cursor position."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-live-output-scroll*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            ;; Auto-follow steady state.
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (let ((vp (save-excursion
                        (goto-char (point-max))
                        (forward-line -9)
                        (line-beginning-position))))
              (set-window-start (selected-window) vp t))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)

            ;; User scrolls into scrollback (ws and point both move).
            (set-window-start (selected-window) (point-min) t)
            (goto-char (point-min))
            (set-window-point (selected-window) (point-min))
            (let ((ws-before (window-start (selected-window)))
                  (wp-before (window-point (selected-window))))

              ;; More PTY output arrives and the redraw timer fires.
              (ghostel--write-input term "extra-line\r\n")
              (setq ghostel--force-next-redraw t)
              (ghostel--delayed-redraw buf)

              (should (= ws-before (window-start (selected-window))))
              (should (= wp-before (window-point (selected-window)))))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-preserves-scroll-across-window-resize ()
  "Window resize (e.g. `M-x' opening the minibuffer) keeps scrollback view.
Reproduces the reported bug: user scrolls up with the mouse wheel and
presses `M-x'; the minibuffer opens and shrinks the ghostel window,
which calls `ghostel--window-adjust-process-window-size' → delayed
redraw.  Before the fix, that redraw yanked `window-start' back to the
viewport.  After the fix, the scrolled-up view is preserved."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-resize-preserve*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            ;; Steady-state auto-follow: window was at the viewport
            ;; and a prior redraw established `last-anchor-position'.
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (let ((vp (save-excursion
                        (goto-char (point-max))
                        (forward-line -9)
                        (line-beginning-position))))
              (set-window-start (selected-window) vp t))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)

            ;; Simulate wheel-up that moves both window-start and point
            ;; into the scrollback (as `pixel-scroll-precision-mode'
            ;; does when point would otherwise fall off-screen).
            (set-window-start (selected-window) (point-min) t)
            (goto-char (point-min))
            (set-window-point (selected-window) (point-min))
            ;; Real-world flow: some PTY output arrives between the
            ;; wheel-up and `M-x', so an output-driven redraw captures
            ;; the scrolled window into `ghostel--scroll-positions'
            ;; before the resize fires.  Without this intermediate
            ;; capture the resize redraw's drift heuristic would
            ;; (correctly, by that heuristic) classify this window as
            ;; drifted-but-anchored and snap it back.
            (ghostel--delayed-redraw buf)
            (should (assq (selected-window) ghostel--scroll-positions))
            (let ((ws-before (window-start (selected-window)))
                  (wp-before (window-point (selected-window))))

              ;; Simulate the M-x minibuffer resize path.  `cl-letf' on
              ;; the default adjust-fn returns a smaller size, so the
              ;; real handler runs `ghostel--set-size' and
              ;; `ghostel--delayed-redraw'.
              (cl-letf (((default-value 'window-adjust-process-window-size-function)
                         (lambda (&rest _) (cons 40 6)))
                        ;; The real handler reads process-buffer.  A
                        ;; throwaway pipe process with this buffer is
                        ;; enough; we clean it up below without letting
                        ;; the sentinel insert any status text.
                        ((symbol-function 'set-process-window-size) #'ignore))
                (setq ghostel--process
                      (make-pipe-process :name "ghostel-test-fake"
                                         :buffer buf
                                         :noquery t
                                         :filter #'ignore
                                         :sentinel #'ignore))
                (unwind-protect
                    (ghostel--window-adjust-process-window-size
                     ghostel--process
                     (list (selected-window)))
                  (delete-process ghostel--process)
                  (setq ghostel--process nil)))

              ;; The user's scrolled-up view must be preserved.
              (should (= ws-before (window-start (selected-window))))
              (should (= wp-before (window-point (selected-window)))))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-resize-preserves-anchor-when-emacs-drifts-ws ()
  "Resize keeps the window anchored when Emacs drifted `window-start' below it.
Regression test for issue #127: in TUIs whose cursor sits above the
viewport bottom, opening the minibuffer shrinks the window body and
Emacs's `keep-point-visible' moves `window-start' forward so the TUI
cursor stays on screen.  The resulting `ws < anchor' looked identical
to a real user scroll, so the force redraw captured a blank-row key,
found it at `point-min', and jumped `window-start' to 1.

With the fix, a force redraw classifies a window as anchored when it
wasn't recorded in `ghostel--scroll-positions' at the prior redraw —
so an Emacs-driven drift is treated as drift, not a scroll."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-resize-anchor-drift*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            ;; Write enough blank-terminated lines that a drifted
            ;; ws-key would ambiguously match near `point-min'.
            (dotimes (i 30)
              (ghostel--write-input term (format "row-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            ;; Steady-state auto-follow; prior redraw seeds the anchor.
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (let ((vp (save-excursion
                        (goto-char (point-max))
                        (forward-line -9)
                        (line-beginning-position))))
              (set-window-start (selected-window) vp t))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)
            (should ghostel--last-anchor-position)
            (should-not ghostel--scroll-positions)

            ;; Simulate Emacs drift: `keep-point-visible' on a
            ;; minibuffer-triggered resize slides `window-start' a
            ;; couple rows below the anchor.  Point stays in the live
            ;; viewport (TUI cursor on a row above the bottom).
            (let ((drifted-ws (save-excursion
                                (goto-char ghostel--last-anchor-position)
                                (forward-line -2)
                                (line-beginning-position))))
              (should (< drifted-ws ghostel--last-anchor-position))
              (set-window-start (selected-window) drifted-ws t))
            ;; Window is NOT in `ghostel--scroll-positions' — it was
            ;; auto-following, not user-scrolled.
            (should-not ghostel--scroll-positions)

            ;; Resize path (same harness as the scrolled-view test).
            (cl-letf (((default-value 'window-adjust-process-window-size-function)
                       (lambda (&rest _) (cons 40 6)))
                      ((symbol-function 'set-process-window-size) #'ignore))
              (setq ghostel--process
                    (make-pipe-process :name "ghostel-test-fake"
                                       :buffer buf
                                       :noquery t
                                       :filter #'ignore
                                       :sentinel #'ignore))
              (unwind-protect
                  (ghostel--window-adjust-process-window-size
                   ghostel--process
                   (list (selected-window)))
                (delete-process ghostel--process)
                (setq ghostel--process nil)))

            ;; Window must be re-anchored to the live viewport, NOT
            ;; yanked to `point-min'.
            (should (= (ghostel--viewport-start)
                       (window-start (selected-window))))
            (should (> (window-start (selected-window)) 1))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-resize-preserves-scrollback-jump ()
  "Resize redraw must NOT re-anchor a window whose point is in scrollback.
Regression test: consult-line / consult-imenu / plain `goto-char' jumps in
line mode opened a minibuffer that resized the body twice.  The second
resize fired with `ghostel--scroll-positions' empty (no scroll-tracking
redraw ran while the minibuffer was open) and the predicate's
resize-active branch classified the window as anchored, yanking
`window-point' back to the live cursor.

The fix is a `window-point' >= anchor guard on the resize branch:
it preserves the drifted-ws case (`window-point' still in the live
viewport) but rejects this case (`window-point' moved into scrollback)."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-resize-scrollback-jump*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-input term (format "row-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            ;; Steady-state: cursor at live viewport, window anchored.
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (let ((vp (save-excursion
                        (goto-char (point-max))
                        (forward-line -9)
                        (line-beginning-position))))
              (set-window-start (selected-window) vp t))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)
            (should ghostel--last-anchor-position)
            (should-not ghostel--scroll-positions)

            ;; Simulate consult-line jumping point into scrollback.
            (let ((target (save-excursion
                            (goto-char (point-min))
                            (forward-line 5)
                            (line-beginning-position))))
              (should (< target ghostel--last-anchor-position))
              (set-window-point (selected-window) target)
              (set-window-start (selected-window) target t)
              (goto-char target)
              ;; No plain redraw runs while the minibuffer is open, so
              ;; `ghostel--scroll-positions' stays empty — exactly the
              ;; state the resize-active branch used to misclassify.
              (should-not ghostel--scroll-positions)

              ;; Resize fires when the minibuffer closes.
              (cl-letf (((default-value 'window-adjust-process-window-size-function)
                         (lambda (&rest _) (cons 40 6)))
                        ((symbol-function 'set-process-window-size) #'ignore))
                (setq ghostel--process
                      (make-pipe-process :name "ghostel-test-fake"
                                         :buffer buf
                                         :noquery t
                                         :filter #'ignore
                                         :sentinel #'ignore))
                (unwind-protect
                    (ghostel--window-adjust-process-window-size
                     ghostel--process
                     (list (selected-window)))
                  (delete-process ghostel--process)
                  (setq ghostel--process nil)))

              ;; Window-point must still be in scrollback, not yanked
              ;; back to the live viewport.
              (should (< (window-point (selected-window))
                         (ghostel--viewport-start))))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-viewport-start-skips-trailing-newline ()
  "`ghostel--viewport-start' must not be off-by-one on a trailing \\n.
Partial redraws can leave the buffer ending with \\n (e.g. after
trimming excess rows).  Emacs then counts an empty phantom line
past `point-max'; a naive `forward-line (- (1- tr))' lands one line
too deep and the anchored window clips the bottom content row.
The fix must return the start of row 1, covering exactly TR content
rows in the viewport — with or without the trailing newline."
  (with-temp-buffer
    (let ((tr 5))
      (dotimes (i tr)
        (insert (format "row-%d" (1+ i)))
        (when (< i (1- tr)) (insert "\n")))
      (let* ((ghostel--term-rows tr)
             (vs-no-nl (ghostel--viewport-start)))
        (should (= 1 vs-no-nl))
        (insert "\n")
        (let ((vs-nl (ghostel--viewport-start)))
          (should (= 1 vs-nl))
          (should (= tr (count-lines vs-nl (save-excursion
                                             (goto-char (point-max))
                                             (skip-chars-backward "\n")
                                             (point))))))))))

(ert-deftest ghostel-test-anchor-window-no-clamp-without-pending-wrap ()
  "`ghostel--anchor-window' must leave `window-point' at PT outside pending-wrap.
Regression test for #146: PR #139 originally clamped unconditionally
whenever PT equalled `point-max', which pulled the block cursor onto
the last character of a normal shell prompt (the cursor is legitimately
at `point-max' right after typing).  The clamp must only fire for the
#138 scenario where the terminal is genuinely in pending-wrap state.

This pure-elisp test leaves `ghostel--term' nil; the helper must then
skip the clamp entirely regardless of where PT sits."
  (let ((buf (generate-new-buffer " *ghostel-test-anchor-no-clamp*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert "row-1\nrow-2\n$ ls"))
          (set-window-buffer (selected-window) buf)
          (let ((win (selected-window))
                (pmax (with-current-buffer buf (point-max))))
            ;; pt at point-max, no term: window-point stays put (#146).
            (with-current-buffer buf
              (setq-local ghostel--term nil)
              (ghostel--anchor-window win (point-min) pmax))
            (should (= pmax (window-point win)))
            ;; pt inside the buffer: window-point is left alone.
            (with-current-buffer buf
              (ghostel--anchor-window win (point-min) (- pmax 3)))
            (should (= (- pmax 3) (window-point win))))
          ;; Empty buffer: no underflow when pt == point-min == point-max.
          (let ((empty-buf (generate-new-buffer " *ghostel-test-anchor-empty*")))
            (unwind-protect
                (progn
                  (set-window-buffer (selected-window) empty-buf)
                  (with-current-buffer empty-buf
                    (setq-local ghostel--term nil)
                    (ghostel--anchor-window (selected-window)
                                            (point-min) (point-max)))
                  (should (= (point-min)
                             (window-point (selected-window)))))
              (kill-buffer empty-buf))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-delayed-redraw-preserves-preedit-anchor ()
  "Active GUI preedit text keeps its point anchor across redraws.
GTK/PGTK input-method candidate windows are anchored to the preedit
overlay at point.  During streaming TUI output, native redraws move
point to the terminal cursor; while preedit text is visible, the
composing window must instead keep the overlay and `window-point' at
the same viewport row and column.
FIXME: `ghostel--term' is bound to a placeholder rather than a real
native handle, and `ghostel--redraw' is stubbed to simulate the
destructive renderer behavior.  A clean rewrite would need a real
terminal fixture with a preedit overlay that survives the renderer's
buffer rewrite at the right viewport row — non-trivial fixture work."
  (let ((buf (generate-new-buffer " *ghostel-test-preedit-anchor*"))
        (orig-buf (window-buffer (selected-window)))
        (old-bound (boundp 'x-preedit-overlay))
        (old-value (and (boundp 'x-preedit-overlay) x-preedit-overlay))
        overlay)
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) buf)
          (with-current-buffer buf
            (ghostel-mode)
            (setq-local ghostel--term 'fake-term
                        ghostel--term-rows 5
                        ghostel--force-next-redraw nil
                        ghostel-enable-url-detection nil
                        ghostel-enable-file-detection nil)
            (let ((inhibit-read-only t))
              (insert "old-0\nold-1\nold-2\nold-3\nold-4")
              (goto-char (point-max)))
            (setq overlay (make-overlay (point) (point) buf))
            (overlay-put overlay 'before-string "ni")
            (overlay-put overlay 'window (selected-window))
            (setq x-preedit-overlay overlay)
            (set-window-start (selected-window) (point-min) t)
            (set-window-point (selected-window) (point)))
          (cl-letf (((symbol-function 'ghostel--mode-enabled)
                     (lambda (&rest _) nil))
                    ((symbol-function 'ghostel--redraw)
                      (lambda (&rest _)
                        ;; Simulate a destructive native redraw that leaves
                        ;; point at the terminal cursor on a different row.
                        (let ((inhibit-read-only t))
                          (erase-buffer)
                          (insert "new-0\nnew-1\nnew-2\nnew-3\nnew-4")
                          (goto-char (point-min))
                          (forward-line 1))))
                    ((symbol-function 'ghostel--cursor-pending-wrap-p)
                     (lambda (&rest _)
                       (error "Preedit anchor should bypass clamp checks")))
                    ((symbol-function 'ghostel--cursor-on-empty-row-p)
                     (lambda (&rest _)
                       (error "Preedit anchor should bypass clamp checks"))))
            (ghostel--delayed-redraw buf))
          (with-current-buffer buf
            (let ((expected (save-excursion
                              (goto-char (point-min))
                              (forward-line 4)
                              (move-to-column 5)
                              (point))))
              (should (= expected (overlay-start overlay)))
              (should (= expected (window-point (selected-window))))
              (should (= expected (point))))))
      (if old-bound
          (setq x-preedit-overlay old-value)
        (makunbound 'x-preedit-overlay))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (when (and overlay (overlayp overlay))
        (delete-overlay overlay))
      (kill-buffer buf))))

(ert-deftest ghostel-test-preedit-window-fallback ()
  "Verify the `selected-window' fallback in `ghostel--preedit-window'.
This covers the pgtk-preedit-overlay shape, which has no `window'
overlay property."
  (let ((buf (generate-new-buffer " *ghostel-test-preedit-window*"))
        (orig-buf (window-buffer (selected-window)))
        overlay)
    (unwind-protect
        (with-current-buffer buf
          (setq overlay (make-overlay (point-min) (point-min) buf))
          ;; No 'window property — selected-window must show the buffer.
          (set-window-buffer (selected-window) buf)
          (should (eq (ghostel--preedit-window overlay) (selected-window)))
          ;; Explicit 'window wins over the fallback.
          (overlay-put overlay 'window (selected-window))
          (should (eq (ghostel--preedit-window overlay) (selected-window)))
          ;; Selected window showing some other buffer and no 'window
          ;; property: nothing usable, return nil.
          (overlay-put overlay 'window nil)
          (when (buffer-live-p orig-buf)
            (set-window-buffer (selected-window) orig-buf))
          (should (null (ghostel--preedit-window overlay))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (when (and overlay (overlayp overlay))
        (delete-overlay overlay))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-anchors-window-start-on-snap-request ()
  "Redraw anchors `window-start' to the viewport when snap is requested.
`ghostel--snap-to-input' sets `ghostel--snap-requested' on typing/paste/
yank/drop.  The next redraw must override a scrolled-up `window-start'
and pull it back to the viewport, then clear the flag."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-ws-snap*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (ghostel--snap-requested t)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (set-window-start (selected-window) (point-min) t)
            (ghostel--delayed-redraw buf)
            (let ((viewport-start (ghostel--viewport-start)))
              (should (= viewport-start (window-start (selected-window))))
              (should-not ghostel--snap-requested))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-scroll-preserved-across-blank-lines ()
  "Scroll preservation disambiguates blank / repeated lines.
Ghostel's content-based scroll restoration uses a multi-line key (not a
single line's text) so that a window scrolled to a blank line isn't
yanked to the first blank line in the buffer when a redraw rebuilds
scrollback positions."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-blank-line*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            ;; Lots of blank-line separators mixed with content so the
            ;; first match of "" is near the top.
            (dotimes (i 30)
              (ghostel--write-input term (format "line-%02d\r\n\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            ;; Seed auto-follow.
            (let ((vp (save-excursion
                        (goto-char (point-max))
                        (forward-line -9)
                        (line-beginning-position))))
              (set-window-start (selected-window) vp t))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)

            ;; Scroll so window-start is on a blank line in the middle
            ;; (not the first blank line in the buffer).
            (let ((target (save-excursion
                            (goto-char (point-max))
                            (forward-line -26)
                            (line-beginning-position))))
              (set-window-start (selected-window) target t)
              (let ((pre-key (ghostel--line-key target)))
                ;; Sanity: the line we're on is blank.
                (should (equal "" (car pre-key)))
                ;; Non-anchored redraw to capture scroll-positions.
                (setq ghostel--force-next-redraw t)
                (ghostel--delayed-redraw buf)
                ;; Simulate Emacs mangling window-start to 1.
                (set-window-start (selected-window) (point-min) t)
                ;; Next redraw restores via multi-line key match.
                (setq ghostel--force-next-redraw t)
                (ghostel--delayed-redraw buf)
                ;; Window-start must be back on the user's blank-line
                ;; row, NOT at the first blank line in the buffer.
                (should (equal pre-key
                               (ghostel--line-key
                                (window-start (selected-window)))))
                (should (> (window-start (selected-window)) 1))))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-anchored-and-scrolled-multi-window ()
  "Anchored and scrolled windows showing the same buffer coexist.
Two windows show the ghostel buffer: one follows the viewport, the
other is pinned to scrollback.  A redraw must anchor the first and
preserve the second."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-multi*"))
        (orig-config (current-window-configuration)))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            (goto-char (point-max))
            (delete-other-windows)
            (set-window-buffer (selected-window) buf)
            (let* ((w1 (selected-window))
                   (w2 (split-window-vertically))
                   (vp (ghostel--viewport-start)))
              (set-window-buffer w2 buf)
              ;; w1 follows viewport; w2 will be scrolled to scrollback
              ;; top *after* the seed redraw (the first-ever redraw
              ;; treats every window as anchored).
              (set-window-start w1 vp t)
              (set-window-point w1 (point-max))
              (setq ghostel--force-next-redraw t)
              (ghostel--delayed-redraw buf)
              (set-window-start w2 (point-min) t)
              (set-window-point w2 (point-min))
              (let* ((w2-ws-before (window-start w2)))
                ;; A redraw that appends more output should anchor w1
                ;; to the new viewport and leave w2 where it is.
                (ghostel--write-input term "extra-line\r\n")
                (setq ghostel--force-next-redraw t)
                (ghostel--delayed-redraw buf)
                ;; w1 anchored to new viewport.
                (let ((new-vp (ghostel--viewport-start)))
                  (should (= new-vp (window-start w1))))
                ;; w2 still in scrollback (same line content).
                (should (equal (ghostel--line-key w2-ws-before)
                               (ghostel--line-key (window-start w2))))))))
      (set-window-configuration orig-config)
      (kill-buffer buf))))

(ert-deftest ghostel-test-clear-scrollback-resets-scroll-state ()
  "`ghostel-clear-scrollback' drops recorded scroll positions.
After the buffer is wiped, the old content no longer exists, so the
next redraw must anchor fresh to the new viewport rather than trying
to restore to a missing line."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-clear-reset*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            ;; Pretend scroll state was recorded (e.g. user was reading
            ;; history when scrollback gets cleared).
            (setq ghostel--scroll-positions
                  (list (cons (selected-window)
                              (list '("scroll-10") '("scroll-11") 0))))
            (setq ghostel--last-anchor-position 42)
            (setq ghostel--process nil)
            (ghostel-clear-scrollback)
            ;; `ghostel--invalidate' schedules a redraw timer that
            ;; would otherwise fire after the buffer is killed.
            (when (timerp ghostel--redraw-timer)
              (cancel-timer ghostel--redraw-timer)
              (setq ghostel--redraw-timer nil))
            (should-not ghostel--scroll-positions)
            (should-not ghostel--last-anchor-position)))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-copy-mode-exit-resets-scroll-state ()
  "Exiting copy mode drops stale scroll-positions.
Delayed-redraw is short-circuited during copy mode; on exit, whatever
`ghostel--scroll-positions' held is stale.  The exit handler drops it
and requests a snap so the next redraw lands at the live viewport."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-copy-exit*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (setq ghostel--input-mode 'copy)
          (setq ghostel--scroll-positions
                (list (cons (selected-window)
                            (list '("stale") '("stale") 0))))
          (setq ghostel--snap-requested nil)
          (setq ghostel--force-next-redraw nil)
          (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore)
                    ((symbol-function 'message) #'ignore))
            (ghostel-readonly-exit))
          (should-not ghostel--scroll-positions)
          (should ghostel--snap-requested)
          ;; `force-next-redraw' must also be set so the snap fires
          ;; even when DEC 2026 synchronized output is active.
          (should ghostel--force-next-redraw))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-syncs-window-point-to-cursor ()
  "Anchored redraw syncs `window-point' to the terminal cursor.
When an OSC 51;E callback moved selection elsewhere and left the
ghostel window's `window-point' stale, the next redraw (which is
anchored because the window is at the viewport) must update it."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-wp-sync*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (let ((vp (save-excursion
                        (goto-char (point-max))
                        (forward-line -9)
                        (line-beginning-position))))
              (set-window-start (selected-window) vp t))
            ;; Simulate OSC 51;E leaving window-point stale.
            (set-window-point (selected-window) (point-min))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)
            ;; Anchored window's window-point follows the cursor
            ;; (buffer-point after native redraw), not the stale value.
            (should (= (window-point (selected-window)) (point)))
            (should (> (window-point (selected-window)) 1))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-respects-user-rescroll ()
  "A second scroll + redraw respects the NEW scroll position.
Reproduces the bug where `ghostel--scroll-positions' goes stale across
redraws: user scrolls to A, triggers a redraw (captures A), scrolls
to B, triggers another redraw — the pre-redraw restore must detect
that the user moved ws to a new valid position and refresh the saved
key to B, rather than yanking ws back to A."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-rescroll*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 50)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (let ((vp (save-excursion
                        (goto-char (point-max))
                        (forward-line -9)
                        (line-beginning-position))))
              (set-window-start (selected-window) vp t))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)

            ;; Scroll #1: to an early (but non-point-min) line.
            (let* ((target-a (save-excursion
                               (goto-char (point-min))
                               (forward-line 5)
                               (line-beginning-position)))
                   (key-a (ghostel--line-key target-a)))
              (set-window-start (selected-window) target-a t)
              (set-window-point (selected-window) target-a)
              ;; Redraw #1 (simulates M-x triggering delayed-redraw).
              (setq ghostel--force-next-redraw t)
              (ghostel--delayed-redraw buf)
              (should (equal key-a
                             (ghostel--line-key
                              (window-start (selected-window)))))

              ;; Scroll #2: to a DIFFERENT non-point-min line.  The
              ;; pre-redraw restore must leave ws alone (only
              ;; point-min looks mangled); the post-redraw capture
              ;; rebuilds `ghostel--scroll-positions' from the
              ;; window's live ws/wp, so the saved key picks up B.
              (let* ((target-b (save-excursion
                                 (goto-char (point-min))
                                 (forward-line 15)
                                 (line-beginning-position)))
                     (key-b (ghostel--line-key target-b)))
                (should-not (equal key-a key-b))
                (set-window-start (selected-window) target-b t)
                (set-window-point (selected-window) target-b)
                ;; Redraw #2.
                (setq ghostel--force-next-redraw t)
                (ghostel--delayed-redraw buf)
                ;; Must land on target-b (user's current intent),
                ;; NOT target-a.
                (should (equal key-b
                               (ghostel--line-key
                                (window-start (selected-window)))))))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-restores-from-mangled-point-min ()
  "When Emacs clamps `window-start' to `point-min', redraw restores.
This is the signature behavior used to distinguish Emacs-side ws
mangling (from window resize etc.) from a legitimate user scroll.
If ws is clamped to point-min but the saved key points elsewhere,
the pre-redraw restore searches for the saved key and moves ws back."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-mangled*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 50)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (let ((vp (save-excursion
                        (goto-char (point-max))
                        (forward-line -9)
                        (line-beginning-position))))
              (set-window-start (selected-window) vp t))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)

            (let* ((target (save-excursion
                             (goto-char (point-min))
                             (forward-line 15)
                             (line-beginning-position)))
                   (key (ghostel--line-key target)))
              (set-window-start (selected-window) target t)
              (set-window-point (selected-window) target)
              (setq ghostel--force-next-redraw t)
              (ghostel--delayed-redraw buf)

              ;; Simulate Emacs clamping ws to point-min (mangling).
              (set-window-start (selected-window) (point-min) t)
              (setq ghostel--force-next-redraw t)
              (ghostel--delayed-redraw buf)
              ;; Must restore ws to the saved key's line content.
              (should (equal key
                             (ghostel--line-key
                              (window-start (selected-window))))))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-restores-wp-mangled-independently ()
  "`window-point' mangled to point-min is restored even when ws isn't.
The wp restore path is decoupled from ws restore.  Emacs can in
principle reset wp without touching ws (e.g. when the selected window
changes and the previous buffer's point gets reset); verify the
restore still fires."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-wp-mangled*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 50)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (let ((vp (save-excursion
                        (goto-char (point-max))
                        (forward-line -9)
                        (line-beginning-position))))
              (set-window-start (selected-window) vp t))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)

            (let* ((ws-target (save-excursion
                                (goto-char (point-min))
                                (forward-line 15)
                                (line-beginning-position)))
                   (wp-target (save-excursion
                                (goto-char (point-min))
                                (forward-line 18)
                                (line-beginning-position)))
                   (wp-key (ghostel--line-key wp-target)))
              (set-window-start (selected-window) ws-target t)
              (set-window-point (selected-window) wp-target)
              (setq ghostel--force-next-redraw t)
              (ghostel--delayed-redraw buf)

              ;; Mangle only wp — ws stays at the same content.
              (set-window-point (selected-window) (point-min))
              (setq ghostel--force-next-redraw t)
              (ghostel--delayed-redraw buf)
              (should (equal wp-key
                             (ghostel--line-key
                              (window-point (selected-window))))))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-false-negative-mangle-refreshes-saved-key ()
  "Non-point-min mangling is indistinguishable from user scroll.
Document and lock in the known limitation of the no-post-command-hook
heuristic: if Emacs moves `window-start' to a non-point-min position
that doesn't match the saved key (e.g. programmatic `recenter',
`follow-mode'), the pre-redraw pass treats it as a user scroll and
refreshes the saved key rather than restoring.  The original scroll
intent is lost."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-false-neg*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 50)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            (goto-char (point-max))
            (set-window-point (selected-window) (point-max))
            (let ((vp (save-excursion
                        (goto-char (point-max))
                        (forward-line -9)
                        (line-beginning-position))))
              (set-window-start (selected-window) vp t))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)

            (let* ((saved (save-excursion
                            (goto-char (point-min))
                            (forward-line 10)
                            (line-beginning-position)))
                   (hijacked (save-excursion
                               (goto-char (point-min))
                               (forward-line 20)
                               (line-beginning-position)))
                   (hijacked-key (ghostel--line-key hijacked)))
              (set-window-start (selected-window) saved t)
              (set-window-point (selected-window) saved)
              (setq ghostel--force-next-redraw t)
              (ghostel--delayed-redraw buf)

              ;; Move ws to a different VALID position (not point-min).
              ;; The heuristic can't tell this from a user scroll.
              (set-window-start (selected-window) hijacked t)
              (setq ghostel--force-next-redraw t)
              (ghostel--delayed-redraw buf)
              ;; Known limitation: ws is accepted as the new intent.
              (should (equal hijacked-key
                             (ghostel--line-key
                              (window-start (selected-window)))))
              ;; scroll-positions has the new key, not the original.
              (let* ((entry (assq (selected-window)
                                  ghostel--scroll-positions))
                     (saved-ws-key (nth 0 (cdr entry))))
                (should (equal hijacked-key saved-ws-key))))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-redraw-first-call-anchors-fresh-buffer ()
  "First-ever redraw anchors the window to the viewport.
`ghostel--last-anchor-position' is nil on the first delayed-redraw; my
code treats every window as anchored in that case so the fresh buffer
pins to the viewport.  This guards the bootstrap path."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-first-redraw*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let* ((term (ghostel--new 10 40 200))
                 (ghostel--term term)
                 (ghostel--term-rows 10)
                 (inhibit-read-only t))
            (dotimes (i 30)
              (ghostel--write-input term (format "scroll-%02d\r\n" i)))
            (ghostel--redraw term t)
            (set-window-buffer (selected-window) buf)
            ;; Fresh state.
            (setq ghostel--last-anchor-position nil
                  ghostel--scroll-positions nil
                  ghostel--snap-requested nil)
            (goto-char (point-max))
            (setq ghostel--force-next-redraw t)
            (ghostel--delayed-redraw buf)
            ;; Anchor fired: window-start pinned to viewport.
            (let ((vs (ghostel--viewport-start)))
              (should (= vs (window-start (selected-window))))
              (should (= vs ghostel--last-anchor-position)))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))



(ert-deftest ghostel-test-scrollback-rotation-rebuild ()
  "Verify cap rotation triggers a rebuild so the buffer reflects libghostty.
The test fills libghostty past its scrollback cap with EARLY markers,
redraws once so the buffer matches the current libghostty state, then
writes a much bigger batch of LATE markers (without an intervening
redraw).  When the next redraw runs, libghostty's `total_rows' is
plateaued at the cap so the normal delta-detection sees nothing to do
— the rotation-detect path must kick in, notice the first scrollback
row's hash has changed, erase the buffer, and let the bootstrap fetch
re-sync from libghostty so the buffer reflects the LATE rows."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-sb-rotate*")))
    (unwind-protect
        (with-current-buffer buf
          (let* (;; 4 KB cap empirically holds ~920 rows of short content
                 ;; in libghostty's compact storage.
                 (term (ghostel--new 5 80 (* 4 1024)))
                 (inhibit-read-only t))
            ;; Phase 1: write 5000 EARLY rows. libghostty's scrollback
            ;; saturates at ~920 rows so the surviving rows are
            ;; early-04080..early-04999 (the most recent 920 of 5000).
            (dotimes (i 5000)
              (ghostel--write-input term (format "early-%05d\r\n" i)))
            (ghostel--redraw term t)
            ;; After this redraw, buffer's scrollback_in_buffer matches
            ;; libghostty's count (~920) and contains those high-numbered
            ;; early rows.
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "early-04999" content)))
            ;; Phase 2: write 5000 LATE rows WITHOUT redrawing in
            ;; between. libghostty rotates: every new write evicts an
            ;; early row and pushes a late row. After 5000 writes, all
            ;; survivors are late-* (since 5000 > 920 cap).
            (dotimes (i 5000)
              (ghostel--write-input term (format "late-%05d\r\n" i)))
            ;; Final redraw: total_rows hasn't changed (libghostty is
            ;; still at the cap) but the content has fully rotated.
            ;; Without rotation-detect this would be a no-op and the
            ;; buffer would still show early-* rows.
            (ghostel--redraw term t)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              ;; Late rows must be present (libghostty kept the most
              ;; recent ones, the rebuild fetched them into the buffer).
              (should (string-match-p "late-04999" content))
              ;; Early rows must NOT be present anywhere — libghostty
              ;; evicted them AND the rebuild flushed our stale copy.
              (should-not (string-match-p "early-" content)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-scrollback ()
  "Test scrollback by overflowing visible rows."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-scrollback*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 80 100))
                 (inhibit-read-only t))
            (dotimes (i 10)
              (ghostel--write-input term (format "line %d\r\n" i)))
            (ghostel--redraw term t)
            (let ((state (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "line [6-9]" state)))       ; recent lines visible
            (ghostel--scroll term -5)
            (ghostel--redraw term t)
            (let ((state (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "line [0-4]" state)))))     ; scrollback shows earlier lines
      (kill-buffer buf))))

(provide 'ghostel-scrollback-test)
;;; ghostel-scrollback-test.el ends here
