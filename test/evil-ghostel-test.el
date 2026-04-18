;;; evil-ghostel-test.el --- Tests for evil-ghostel -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs --batch -Q -L ~/.emacs.d/lib/evil -L . \
;;     -l ert -l test/evil-ghostel-test.el -f evil-ghostel-test-run

;;; Code:

(require 'ert)
(require 'evil)
(require 'ghostel)
(require 'evil-ghostel)

;; -----------------------------------------------------------------------
;; Helper: set up a ghostel buffer with evil
;; -----------------------------------------------------------------------

(defmacro evil-ghostel-test--with-buffer (rows cols text &rest body)
  "Create a ghostel buffer with ROWS x COLS, feed TEXT, render, then run BODY.
The buffer has evil-mode and evil-ghostel-mode active.
The variable `term' is bound to the terminal handle.
Requires the native module."
  (declare (indent 3) (debug t))
  `(let ((term (ghostel--new ,rows ,cols 100)))
     (ghostel--write-input term ,text)
     (with-temp-buffer
       (ghostel-mode)
       (setq-local ghostel--term term)
       ;; Production wires `ghostel--term-rows' via `ghostel--resize';
       ;; tests that drive the module directly must set it themselves so
       ;; viewport-aware helpers (e.g. `evil-ghostel--reset-cursor-point')
       ;; can translate viewport rows into buffer lines.
       (setq-local ghostel--term-rows ,rows)
       (evil-local-mode 1)
       (evil-ghostel-mode 1)
       (let ((inhibit-read-only t))
         (ghostel--redraw term t))
       ,@body)))

(defmacro evil-ghostel-test--with-evil-buffer (&rest body)
  "Set up a ghostel buffer with evil-mode active (no native module).
Uses mocks for native functions."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (ghostel-mode)
     ;; Mock tests don't go through `ghostel--resize', so
     ;; `ghostel--term-rows' stays nil by default.  Pick a value large
     ;; enough that the viewport covers whatever text a mock test
     ;; `insert's — the scrollback-offset computation then collapses to
     ;; zero and matches pre-scrollback-fix behaviour.
     (setq-local ghostel--term-rows 100)
     (evil-local-mode 1)
     (evil-ghostel-mode 1)
     ,@body))

;; -----------------------------------------------------------------------
;; Test: mode activation
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-mode-activation ()
  "Test that `evil-ghostel-mode' activates correctly."
  (evil-ghostel-test--with-evil-buffer
   (should evil-ghostel-mode)
   (should (memq 'evil-ghostel--normal-state-entry
                 evil-normal-state-entry-hook))
   (should (memq 'evil-ghostel--insert-state-entry
                 evil-insert-state-entry-hook))
   (should (advice--p (advice--symbol-function 'evil-insert-line)))
   (should (advice--p (advice--symbol-function 'ghostel--redraw)))
   (should (advice--p (advice--symbol-function 'ghostel--set-cursor-style)))))

(ert-deftest evil-ghostel-test-mode-deactivation ()
  "Test that `evil-ghostel-mode' cleans up on deactivation."
  (evil-ghostel-test--with-evil-buffer
   (evil-ghostel-mode -1)
   (should-not evil-ghostel-mode)
   (should-not (memq 'evil-ghostel--normal-state-entry
                     evil-normal-state-entry-hook))
   (should-not (memq 'evil-ghostel--insert-state-entry
                     evil-insert-state-entry-hook))))

;; -----------------------------------------------------------------------
;; Test: escape-stay (evil-move-cursor-back disabled)
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-escape-stay ()
  "Test that `evil-move-cursor-back' is disabled in ghostel buffers."
  (evil-ghostel-test--with-evil-buffer
   (should-not evil-move-cursor-back)))

;; -----------------------------------------------------------------------
;; Test: reset-cursor-point
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-reset-cursor-point ()
  "Test that `evil-ghostel--reset-cursor-point' moves point to terminal cursor."
  (evil-ghostel-test--with-buffer 5 40 "hello world"
                                  ;; Terminal cursor is at col 11, row 0
                                  (should (equal '(11 . 0) (ghostel--cursor-position term)))
                                  ;; Move point somewhere else
                                  (goto-char (point-min))
                                  (should (= 0 (current-column)))
                                  ;; Reset should snap back to terminal cursor
                                  (evil-ghostel--reset-cursor-point)
                                  (should (= 11 (current-column)))
                                  (should (= 1 (line-number-at-pos)))))

(ert-deftest evil-ghostel-test-reset-cursor-point-multiline ()
  "Test cursor reset with text on multiple lines."
  (evil-ghostel-test--with-buffer 5 40 "line1\nline2-text"
                                  ;; Cursor should be on row 1 (second line)
                                  (let ((pos (ghostel--cursor-position term)))
                                    (should (= 1 (cdr pos))))
                                  (goto-char (point-min))
                                  (evil-ghostel--reset-cursor-point)
                                  (should (= 2 (line-number-at-pos)))))

(ert-deftest evil-ghostel-test-reset-cursor-point-with-scrollback ()
  "Regression: reset-cursor-point must anchor to the viewport, not point-min.
`ghostel--cursor-position' returns the row within the viewport (the
last `ghostel--term-rows' lines of the buffer).  With scrollback
present, interpreting the row as an offset from `point-min' lands
point in the scrollback region instead of the visible viewport."
  (let ((term (ghostel--new 5 40 1000)))
    ;; Overflow a 5-row viewport with 12 lines so 7 scroll off.  The
    ;; final row ("last-11") is in the viewport; earlier rows live in
    ;; scrollback above.
    (dotimes (i 12)
      (ghostel--write-input term (format "row-%02d\r\n" i)))
    (ghostel--write-input term "last-11")
    (with-temp-buffer
      (ghostel-mode)
      (setq-local ghostel--term term)
      (setq-local ghostel--term-rows 5)
      (evil-local-mode 1)
      (evil-ghostel-mode 1)
      (let ((inhibit-read-only t))
        (ghostel--redraw term t))
      ;; Walk point back into the scrollback region.
      (goto-char (point-min))
      (should (string-match-p "row-00" (buffer-substring-no-properties
                                         (line-beginning-position)
                                         (line-end-position))))
      ;; Reset must snap point into the viewport, not to scrollback row N.
      (evil-ghostel--reset-cursor-point)
      ;; The landing line is the one that contains the terminal cursor —
      ;; "last-11" (the last written row before the trailing cursor).
      (let ((line-text (buffer-substring-no-properties
                        (line-beginning-position)
                        (line-end-position))))
        (should (string-match-p "last-11" line-text)))
      ;; And the landing column matches the terminal cursor column.
      (should (= (car (ghostel--cursor-position term))
                 (current-column))))))

;; -----------------------------------------------------------------------
;; Test: cursor-to-point (arrow key sending)
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-cursor-to-point ()
  "Test that `evil-ghostel--cursor-to-point' sends correct arrow keys."
  (evil-ghostel-test--with-buffer 5 40 "$ echo hello world"
                                  ;; Terminal cursor at col 18, row 0
                                  (should (equal '(18 . 0) (ghostel--cursor-position term)))
                                  ;; Move point to col 7 (start of "hello")
                                  (goto-char (point-min))
                                  (move-to-column 7)
                                  ;; Track what keys are sent
                                  (let ((keys-sent '()))
                                    (cl-letf (((symbol-function 'ghostel--send-encoded)
                                               (lambda (key _mods &rest _)
                                                 (push key keys-sent))))
                                      (evil-ghostel--cursor-to-point))
                                    ;; Should send 11 LEFT arrows (18 - 7 = 11)
                                    (should (= 11 (length keys-sent)))
                                    (should (cl-every (lambda (k) (equal k "left")) keys-sent)))))

(ert-deftest evil-ghostel-test-cursor-to-point-right ()
  "Test arrow key sending when point is to the right of terminal cursor."
  (evil-ghostel-test--with-buffer 5 40 "hello"
                                  ;; Terminal cursor at col 5
                                  ;; Move cursor left in terminal, then move point right of it
                                  (ghostel--write-input term "\e[3D") ; cursor left 3 → col 2
                                  (goto-char (point-min))
                                  (move-to-column 4) ; point at col 4
                                  (let ((keys-sent '()))
                                    (cl-letf (((symbol-function 'ghostel--send-encoded)
                                               (lambda (key _mods &rest _)
                                                 (push key keys-sent))))
                                      (evil-ghostel--cursor-to-point))
                                    ;; Should send 2 RIGHT arrows (4 - 2 = 2)
                                    (should (= 2 (length keys-sent)))
                                    (should (cl-every (lambda (k) (equal k "right")) keys-sent)))))

(ert-deftest evil-ghostel-test-cursor-to-point-no-op ()
  "Test that no arrows are sent when point matches terminal cursor."
  (evil-ghostel-test--with-buffer 5 40 "hello"
                                  ;; Point is already at terminal cursor after redraw
                                  (let ((keys-sent '()))
                                    (cl-letf (((symbol-function 'ghostel--send-encoded)
                                               (lambda (key _mods &rest _)
                                                 (push key keys-sent))))
                                      (evil-ghostel--cursor-to-point))
                                    (should (= 0 (length keys-sent))))))

;; -----------------------------------------------------------------------
;; Test: redraw preserves point in normal state
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-redraw-preserves-point-normal ()
  "Test that redraws preserve point in evil normal state."
  (evil-ghostel-test--with-buffer 5 40 "hello world"
                                  (evil-normal-state)
                                  ;; Move point to col 5 (between "hello" and "world")
                                  (goto-char (point-min))
                                  (move-to-column 5)
                                  (should (= 5 (current-column)))
                                  ;; Redraw — should NOT move point back to terminal cursor
                                  (let ((inhibit-read-only t))
                                    (ghostel--redraw term t))
                                  (should (= 5 (current-column)))))

(ert-deftest evil-ghostel-test-redraw-moves-point-insert ()
  "Test that redraws move point to terminal cursor in insert state."
  (evil-ghostel-test--with-buffer 5 40 "hello world"
                                  (evil-insert-state)
                                  ;; Move point away from terminal cursor
                                  (goto-char (point-min))
                                  ;; Redraw — should snap point to terminal cursor (col 11)
                                  (let ((inhibit-read-only t))
                                    (ghostel--redraw term t))
                                  (should (= 11 (current-column)))))

(ert-deftest evil-ghostel-test-redraw-moves-point-emacs-state ()
  "Test that redraws follow terminal cursor in evil emacs-state.
Emacs-state is evil's vanilla-Emacs escape hatch; point should track
the terminal cursor there just like in insert-state.  Otherwise the
cursor freezes wherever it was on state entry while TUIs keep
redrawing elsewhere."
  (evil-ghostel-test--with-buffer 5 40 "hello world"
                                  (evil-emacs-state)
                                  ;; Move point away from terminal cursor
                                  (goto-char (point-min))
                                  ;; Redraw — should snap point to terminal cursor (col 11)
                                  (let ((inhibit-read-only t))
                                    (ghostel--redraw term t))
                                  (should (= 11 (current-column)))))

;; -----------------------------------------------------------------------
;; Test: advice fires on evil-insert / evil-append
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-advice-on-insert ()
  "Test that `evil-ghostel--before-insert' fires on `evil-insert'."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0))))
     (evil-normal-state)
     (let ((sync-called nil))
       (cl-letf (((symbol-function 'evil-ghostel--cursor-to-point)
                  (lambda () (setq sync-called t))))
         (evil-insert 1))
       (should sync-called)))))

(ert-deftest evil-ghostel-test-advice-on-append ()
  "Test that `evil-ghostel--before-append' fires on `evil-append'."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello")
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(5 . 0))))
     (evil-normal-state)
     (goto-char (point-min))
     (move-to-column 2)
     (let ((sync-called nil))
       (cl-letf (((symbol-function 'evil-ghostel--cursor-to-point)
                  (lambda () (setq sync-called t))))
         (evil-append 1))
       (should sync-called)))))

(ert-deftest evil-ghostel-test-advice-insert-line-sends-home ()
  "Test that `evil-insert-line' sends C-a and inhibits hook sync."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0))))
     (evil-normal-state)
     (let ((keys-sent '()))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _)
                    (push key keys-sent))))
         (evil-insert-line 1))
       (should (member "a" keys-sent))
       ;; Hook should NOT have sent additional arrow keys
       (should-not (member "left" keys-sent))
       (should-not (member "right" keys-sent))))))

(ert-deftest evil-ghostel-test-advice-append-line-sends-end ()
  "Test that `evil-append-line' sends C-e and inhibits hook sync."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0))))
     (evil-normal-state)
     (let ((keys-sent '()))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _)
                    (push key keys-sent))))
         (evil-append-line 1))
       (should (member "e" keys-sent))
       ;; Hook should NOT have sent additional arrow keys
       (should-not (member "left" keys-sent))
       (should-not (member "right" keys-sent))))))

;; -----------------------------------------------------------------------
;; Test: advice is no-op outside ghostel buffers
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-advice-no-op-outside-ghostel ()
  "Test that advice does nothing when `evil-ghostel-mode' is nil."
  (with-temp-buffer
    (evil-local-mode 1)
    (evil-normal-state)
    (let ((sync-called nil))
      (cl-letf (((symbol-function 'evil-ghostel--cursor-to-point)
                 (lambda () (setq sync-called t))))
        (evil-insert 1))
      (should-not sync-called))))

;; -----------------------------------------------------------------------
;; Test: cursor style override
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-cursor-style-override ()
  "Test that `ghostel--set-cursor-style' defers to evil."
  (evil-ghostel-test--with-buffer 5 40 "hello"
                                  (evil-normal-state)
                                  (let ((evil-called nil)
                                        (orig-called nil))
                                    (cl-letf (((symbol-function 'evil-refresh-cursor)
                                               (lambda (&rest _) (setq evil-called t))))
                                      (ghostel--set-cursor-style 0 t)
                                      (should evil-called)))))

;; -----------------------------------------------------------------------
;; Test: normal-state-entry hook
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-normal-entry-snaps-point ()
  "Test that entering normal state snaps point to terminal cursor."
  (evil-ghostel-test--with-buffer 5 40 "hello world"
                                  (evil-insert-state)
                                  ;; Move point away
                                  (goto-char (point-min))
                                  ;; Enter normal state — should snap to terminal cursor
                                  (evil-normal-state)
                                  (should (= 11 (current-column)))))

;; -----------------------------------------------------------------------
;; Test: delete-region primitive
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-delete-region ()
  "Test that `evil-ghostel--delete-region' sends correct keys."
  (evil-ghostel-test--with-buffer 5 40 "$ echo hello"
                                  ;; Delete "hello" (col 7-12)
                                  (let ((keys-sent '()))
                                    (cl-letf (((symbol-function 'ghostel--send-encoded)
                                               (lambda (key _mods &rest _)
                                                 (push key keys-sent))))
                                      (evil-ghostel--delete-region 8 13))
                                    ;; Should send arrow keys to move cursor, then 5 backspaces
                                    (should (= 5 (cl-count "backspace" keys-sent :test #'equal))))))

;; -----------------------------------------------------------------------
;; Test: evil-delete advice
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-delete-sends-backspace-keys ()
  "Test that `evil-delete' advice sends backspace keys via PTY."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello world")
   (goto-char (point-min))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0)))
             ((symbol-function 'evil-ghostel--cursor-to-point) #'ignore))
     (evil-normal-state)
     (let ((bs-count 0))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _)
                    (when (equal key "backspace")
                      (cl-incf bs-count)))))
         ;; Delete 5 chars (simulates dw on "hello")
         (evil-delete 1 6 'inclusive nil nil))
       (should (= 5 bs-count))))))

(ert-deftest evil-ghostel-test-delete-line-sends-ctrl-u ()
  "Test that line-type `evil-delete' sends Ctrl+U to clear line."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello world")
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0))))
     (evil-normal-state)
     (let ((keys-sent '()))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key mods &rest _)
                    (push (cons key mods) keys-sent))))
         (evil-delete (point-min) (point-max) 'line nil nil))
       ;; Should have sent C-e and Ctrl+U
       (should (cl-find '("u" . "ctrl") keys-sent :test #'equal))
       (should (cl-find '("e" . "ctrl") keys-sent :test #'equal))))))

(ert-deftest evil-ghostel-test-delete-char ()
  "Test that `evil-delete-char' (x) works without error.
Regression: yank-handler arg was not optional in advice signature,
so calls from `evil-delete-char' (which passes only 4 args to
`evil-delete') raised `wrong-number-of-arguments'."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello")
   (goto-char (point-min))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0)))
             ((symbol-function 'evil-ghostel--cursor-to-point) #'ignore)
             ((symbol-function 'ghostel--send-encoded) #'ignore))
     (evil-normal-state)
     ;; evil-delete-char calls evil-delete without yank-handler
     (evil-delete-char 1 2 'exclusive nil)
     (should (eq evil-state 'normal)))))

;; -----------------------------------------------------------------------
;; Test: evil-change advice
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-change-deletes-and-inserts ()
  "Test that `evil-change' advice deletes via PTY and enters insert state."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello world")
   (goto-char (point-min))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0)))
             ((symbol-function 'evil-ghostel--cursor-to-point) #'ignore))
     (evil-normal-state)
     (let ((bs-count 0))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _)
                    (when (equal key "backspace")
                      (cl-incf bs-count)))))
         (evil-change 1 6 'inclusive nil nil nil))
       (should (= 5 bs-count))
       (should (eq evil-state 'insert))))))

(ert-deftest evil-ghostel-test-change-whole-line ()
  "Test that `evil-change-whole-line' (cc/S) works without error.
Regression: delete-func arg was not optional in advice signature."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello world")
   (goto-char (point-min))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0)))
             ((symbol-function 'ghostel--send-encoded) #'ignore))
     (evil-normal-state)
     ;; evil-change-whole-line calls evil-change without delete-func
     (evil-change-whole-line 1 12 nil nil)
     (should (eq evil-state 'insert)))))

;; -----------------------------------------------------------------------
;; Test: evil-replace advice
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-replace-deletes-and-inserts ()
  "Test that `evil-replace' deletes then inserts replacement text."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello")
   (goto-char (point-min))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0)))
             ((symbol-function 'evil-ghostel--cursor-to-point) #'ignore))
     (evil-normal-state)
     (let ((bs-count 0)
           (pasted nil))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _)
                    (when (equal key "backspace")
                      (cl-incf bs-count))))
                 ((symbol-function 'ghostel--paste-text)
                  (lambda (text) (setq pasted text))))
         (evil-replace 1 4 'inclusive ?X))
       (should (= 3 bs-count))
       (should (equal "XXX" pasted))))))

;; -----------------------------------------------------------------------
;; Test: evil-paste advice
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-paste-after ()
  "Test that `evil-paste-after' pastes via PTY."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello")
   (kill-new "world")
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0)))
             ((symbol-function 'evil-ghostel--cursor-to-point) #'ignore))
     (evil-normal-state)
     (let ((pasted nil))
       (cl-letf (((symbol-function 'ghostel--paste-text)
                  (lambda (text) (setq pasted text)))
                 ((symbol-function 'ghostel--send-encoded) #'ignore))
         (evil-paste-after 1))
       (should (equal "world" pasted))))))

;; -----------------------------------------------------------------------
;; Test: insert-state Ctrl key passthrough
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-ctrl-passthrough-sends-to-terminal ()
  "Test that Ctrl keys in insert state are sent to the terminal."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello world")
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(11 . 0))))
     (evil-insert-state)
     ;; Test a sample of keys from evil-ghostel--ctrl-passthrough-keys
     (dolist (key '("a" "d" "e" "k" "r" "u" "w" "y"))
       (let ((keys-sent '()))
         (cl-letf (((symbol-function 'ghostel--send-encoded)
                    (lambda (k mods &rest _)
                      (push (cons k mods) keys-sent))))
           (evil-ghostel--passthrough-ctrl key))
         (should (cl-find (cons key "ctrl") keys-sent :test #'equal)))))))

;; -----------------------------------------------------------------------
;; Test: insert-state entry skips vertical sync
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-insert-entry-no-vertical-sync ()
  "Test that entering insert from a different row snaps to terminal cursor.
Prevents up/down arrows being sent as history navigation."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "line one\nline two\nline three")
   ;; Terminal cursor on row 2 (last line), col 5
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(5 . 2))))
     (evil-normal-state)
     ;; Move point to row 0 (first line) simulating `kk`
     (goto-char (point-min))
     (let ((keys-sent '()))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key mods &rest _)
                    (push key keys-sent))))
         (evil-insert-state))
       ;; Should NOT have sent up/down arrows
       (should-not (member "up" keys-sent))
       (should-not (member "down" keys-sent))
       ;; Point should have snapped to terminal cursor row
       (should (= (line-number-at-pos (point) t) 3))))))

;; -----------------------------------------------------------------------
;; Test: insert-state entry syncs column on same row
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-insert-entry-syncs-column-same-row ()
  "Test that entering insert on the same row syncs column position."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello world")
   ;; Terminal cursor on row 0, col 0
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0))))
     (evil-normal-state)
     ;; Move point to col 5 on the same row
     (goto-char (point-min))
     (move-to-column 5)
     (let ((keys-sent '()))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _)
                    (push key keys-sent))))
         (evil-insert-state))
       ;; Should have sent right arrows to sync column
       (should (member "right" keys-sent))
       ;; Should NOT have sent vertical arrows
       (should-not (member "up" keys-sent))
       (should-not (member "down" keys-sent))))))

;; -----------------------------------------------------------------------
;; Test: evil-undo advice
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-undo-sends-ctrl-underscore ()
  "Test that `evil-undo' sends Ctrl+_ to the terminal."
  (evil-ghostel-test--with-evil-buffer
   (setq-local ghostel--term t)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0))))
     (evil-normal-state)
     (let ((keys-sent '()))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key mods &rest _)
                    (push (cons key mods) keys-sent))))
         (evil-undo 3))
       (should (= 3 (cl-count '("_" . "ctrl") keys-sent :test #'equal)))))))

;; -----------------------------------------------------------------------
;; Test: advice is no-op outside ghostel
;; -----------------------------------------------------------------------

(ert-deftest evil-ghostel-test-delete-no-op-outside-ghostel ()
  "Test that delete advice falls through when not in ghostel."
  (with-temp-buffer
    (evil-local-mode 1)
    (evil-normal-state)
    (insert "hello world")
    (goto-char (point-min))
    ;; evil-delete should work normally (modify buffer)
    (evil-delete 1 6 'inclusive nil nil)
    (should (equal " world" (buffer-string)))))

;; -----------------------------------------------------------------------
;; Runner
;; -----------------------------------------------------------------------

(defconst evil-ghostel-test--elisp-tests
  '(evil-ghostel-test-mode-activation
    evil-ghostel-test-mode-deactivation
    evil-ghostel-test-escape-stay
    evil-ghostel-test-advice-on-insert
    evil-ghostel-test-advice-on-append
    evil-ghostel-test-advice-insert-line-sends-home
    evil-ghostel-test-advice-append-line-sends-end
    evil-ghostel-test-advice-no-op-outside-ghostel
    evil-ghostel-test-delete-sends-backspace-keys
    evil-ghostel-test-delete-line-sends-ctrl-u
    evil-ghostel-test-delete-char
    evil-ghostel-test-change-deletes-and-inserts
    evil-ghostel-test-replace-deletes-and-inserts
    evil-ghostel-test-paste-after
    evil-ghostel-test-undo-sends-ctrl-underscore
    evil-ghostel-test-change-whole-line
    evil-ghostel-test-delete-no-op-outside-ghostel)
  "Tests that require only Elisp (no native module).")

(defun evil-ghostel-test-run-elisp ()
  "Run only pure Elisp tests (no native module required)."
  (ert-run-tests-batch-and-exit
   `(member ,@evil-ghostel-test--elisp-tests)))

(defun evil-ghostel-test-run ()
  "Run all evil-ghostel tests."
  (ert-run-tests-batch-and-exit "^evil-ghostel-test-"))

;;; evil-ghostel-test.el ends here
