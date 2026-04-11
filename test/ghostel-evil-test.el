;;; ghostel-evil-test.el --- Tests for ghostel-evil -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with:
;;   emacs --batch -Q -L ~/.emacs.d/lib/evil -L . \
;;     -l ert -l test/ghostel-evil-test.el -f ghostel-evil-test-run

;;; Code:

(require 'ert)
(require 'evil)
(require 'ghostel)
(require 'ghostel-evil)

;; -----------------------------------------------------------------------
;; Helper: set up a ghostel buffer with evil
;; -----------------------------------------------------------------------

(defmacro ghostel-evil-test--with-buffer (rows cols text &rest body)
  "Create a ghostel buffer with ROWS x COLS, feed TEXT, render, then run BODY.
The buffer has evil-mode and ghostel-evil-mode active.
The variable `term' is bound to the terminal handle.
Requires the native module."
  (declare (indent 3) (debug t))
  `(let ((term (ghostel--new ,rows ,cols 100)))
     (ghostel--write-input term ,text)
     (with-temp-buffer
       (ghostel-mode)
       (setq-local ghostel--term term)
       (evil-local-mode 1)
       (ghostel-evil-mode 1)
       (let ((inhibit-read-only t))
         (ghostel--redraw term t))
       ,@body)))

(defmacro ghostel-evil-test--with-evil-buffer (&rest body)
  "Set up a ghostel buffer with evil-mode active (no native module).
Uses mocks for native functions."
  (declare (indent 0) (debug t))
  `(with-temp-buffer
     (ghostel-mode)
     (evil-local-mode 1)
     (ghostel-evil-mode 1)
     ,@body))

(defun ghostel-evil-test--insert (&rest strings)
  "Insert STRINGS while bypassing `buffer-read-only' during test setup."
  (let ((inhibit-read-only t))
    (dolist (string strings)
      (insert string))))

;; -----------------------------------------------------------------------
;; Test: mode activation
;; -----------------------------------------------------------------------

(ert-deftest ghostel-evil-test-mode-activation ()
  "Test that `ghostel-evil-mode' activates correctly."
  (ghostel-evil-test--with-evil-buffer
   (should ghostel-evil-mode)
   (should (memq 'ghostel-evil--normal-state-entry
                 evil-normal-state-entry-hook))
   (should (memq 'ghostel-evil--insert-state-entry
                 evil-insert-state-entry-hook))
   (should (advice--p (advice--symbol-function 'evil-insert-line)))
   (should (advice--p (advice--symbol-function 'ghostel--redraw)))
   (should (advice--p (advice--symbol-function 'ghostel--set-cursor-style)))))

(ert-deftest ghostel-evil-test-mode-deactivation ()
  "Test that `ghostel-evil-mode' cleans up on deactivation."
  (ghostel-evil-test--with-evil-buffer
   (ghostel-evil-mode -1)
   (should-not ghostel-evil-mode)
   (should-not (memq 'ghostel-evil--normal-state-entry
                     evil-normal-state-entry-hook))
   (should-not (memq 'ghostel-evil--insert-state-entry
                     evil-insert-state-entry-hook))))

;; -----------------------------------------------------------------------
;; Test: escape-stay (evil-move-cursor-back disabled)
;; -----------------------------------------------------------------------

(ert-deftest ghostel-evil-test-escape-stay ()
  "Test that `evil-move-cursor-back' is disabled in ghostel buffers."
  (ghostel-evil-test--with-evil-buffer
   (should-not evil-move-cursor-back)))

;; -----------------------------------------------------------------------
;; Test: reset-cursor-point
;; -----------------------------------------------------------------------

(ert-deftest ghostel-evil-test-reset-cursor-point ()
  "Test that `ghostel-evil--reset-cursor-point' moves point to terminal cursor."
  (ghostel-evil-test--with-buffer 5 40 "hello world"
                                  ;; Terminal cursor is at col 11, row 0
                                  (should (equal '(11 . 0) (ghostel--cursor-position term)))
                                  ;; Move point somewhere else
                                  (goto-char (point-min))
                                  (should (= 0 (current-column)))
                                  ;; Reset should snap back to terminal cursor
                                  (ghostel-evil--reset-cursor-point)
                                  (should (= 11 (current-column)))
                                  (should (= 1 (line-number-at-pos)))))

(ert-deftest ghostel-evil-test-reset-cursor-point-multiline ()
  "Test cursor reset with text on multiple lines."
  (ghostel-evil-test--with-buffer 5 40 "line1\nline2-text"
                                  ;; Cursor should be on row 1 (second line)
                                  (let ((pos (ghostel--cursor-position term)))
                                    (should (= 1 (cdr pos))))
                                  (goto-char (point-min))
                                  (ghostel-evil--reset-cursor-point)
                                  (should (= 2 (line-number-at-pos)))))

;; -----------------------------------------------------------------------
;; Test: cursor-to-point (arrow key sending)
;; -----------------------------------------------------------------------

(ert-deftest ghostel-evil-test-cursor-to-point ()
  "Test that `ghostel-evil--cursor-to-point' sends correct arrow keys."
  (ghostel-evil-test--with-buffer 5 40 "$ echo hello world"
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
                                      (ghostel-evil--cursor-to-point))
                                    ;; Should send 11 LEFT arrows (18 - 7 = 11)
                                    (should (= 11 (length keys-sent)))
                                    (should (cl-every (lambda (k) (equal k "left")) keys-sent)))))

(ert-deftest ghostel-evil-test-cursor-to-point-right ()
  "Test arrow key sending when point is to the right of terminal cursor."
  (ghostel-evil-test--with-buffer 5 40 "hello"
                                  ;; Terminal cursor at col 5
                                  ;; Move cursor left in terminal, then move point right of it
                                  (ghostel--write-input term "\e[3D") ; cursor left 3 → col 2
                                  (goto-char (point-min))
                                  (move-to-column 4) ; point at col 4
                                  (let ((keys-sent '()))
                                    (cl-letf (((symbol-function 'ghostel--send-encoded)
                                               (lambda (key _mods &rest _)
                                                 (push key keys-sent))))
                                      (ghostel-evil--cursor-to-point))
                                    ;; Should send 2 RIGHT arrows (4 - 2 = 2)
                                    (should (= 2 (length keys-sent)))
                                    (should (cl-every (lambda (k) (equal k "right")) keys-sent)))))

(ert-deftest ghostel-evil-test-cursor-to-point-no-op ()
  "Test that no arrows are sent when point matches terminal cursor."
  (ghostel-evil-test--with-buffer 5 40 "hello"
                                  ;; Point is already at terminal cursor after redraw
                                  (let ((keys-sent '()))
                                    (cl-letf (((symbol-function 'ghostel--send-encoded)
                                               (lambda (key _mods &rest _)
                                                 (push key keys-sent))))
                                      (ghostel-evil--cursor-to-point))
                                    (should (= 0 (length keys-sent))))))

;; -----------------------------------------------------------------------
;; Test: redraw preserves point in normal state
;; -----------------------------------------------------------------------

(ert-deftest ghostel-evil-test-redraw-preserves-point-normal ()
  "Test that redraws preserve point in evil normal state."
  (ghostel-evil-test--with-buffer 5 40 "hello world"
                                  (evil-normal-state)
                                  ;; Move point to col 5 (between "hello" and "world")
                                  (goto-char (point-min))
                                  (move-to-column 5)
                                  (should (= 5 (current-column)))
                                  ;; Redraw — should NOT move point back to terminal cursor
                                  (let ((inhibit-read-only t))
                                    (ghostel--redraw term t))
                                  (should (= 5 (current-column)))))

(ert-deftest ghostel-evil-test-redraw-moves-point-insert ()
  "Test that redraws move point to terminal cursor in insert state."
  (ghostel-evil-test--with-buffer 5 40 "hello world"
                                  (evil-insert-state)
                                  ;; Move point away from terminal cursor
                                  (goto-char (point-min))
                                  ;; Redraw — should snap point to terminal cursor (col 11)
                                  (let ((inhibit-read-only t))
                                    (ghostel--redraw term t))
                                  (should (= 11 (current-column)))))

;; -----------------------------------------------------------------------
;; Test: advice fires on evil-insert / evil-append
;; -----------------------------------------------------------------------

(ert-deftest ghostel-evil-test-advice-on-insert ()
  "Test that `ghostel-evil--before-insert' fires on `evil-insert'."
  (ghostel-evil-test--with-evil-buffer
   (setq-local ghostel--term t)
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0))))
     (evil-normal-state)
     (let ((sync-called nil))
       (cl-letf (((symbol-function 'ghostel-evil--cursor-to-point)
                  (lambda () (setq sync-called t))))
         (evil-insert 1))
       (should sync-called)))))

(ert-deftest ghostel-evil-test-advice-on-append ()
  "Test that `ghostel-evil--before-append' fires on `evil-append'."
  (ghostel-evil-test--with-evil-buffer
   (setq-local ghostel--term t)
   (ghostel-evil-test--insert "hello")
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(5 . 0))))
     (evil-normal-state)
     (goto-char (point-min))
     (move-to-column 2)
     (let ((sync-called nil))
       (cl-letf (((symbol-function 'ghostel-evil--cursor-to-point)
                  (lambda () (setq sync-called t))))
         (evil-append 1))
       (should sync-called)))))

(ert-deftest ghostel-evil-test-advice-insert-line-sends-home ()
  "Test that `evil-insert-line' sends C-a and inhibits hook sync."
  (ghostel-evil-test--with-evil-buffer
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

(ert-deftest ghostel-evil-test-advice-append-line-sends-end ()
  "Test that `evil-append-line' sends C-e and inhibits hook sync."
  (ghostel-evil-test--with-evil-buffer
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

(ert-deftest ghostel-evil-test-advice-no-op-outside-ghostel ()
  "Test that advice does nothing when `ghostel-evil-mode' is nil."
  (with-temp-buffer
    (evil-local-mode 1)
    (evil-normal-state)
    (let ((sync-called nil))
      (cl-letf (((symbol-function 'ghostel-evil--cursor-to-point)
                 (lambda () (setq sync-called t))))
        (evil-insert 1))
      (should-not sync-called))))

;; -----------------------------------------------------------------------
;; Test: cursor style override
;; -----------------------------------------------------------------------

(ert-deftest ghostel-evil-test-cursor-style-override ()
  "Test that `ghostel--set-cursor-style' defers to evil."
  (ghostel-evil-test--with-buffer 5 40 "hello"
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

(ert-deftest ghostel-evil-test-normal-entry-snaps-point ()
  "Test that entering normal state snaps point to terminal cursor."
  (ghostel-evil-test--with-buffer 5 40 "hello world"
                                  (evil-insert-state)
                                  ;; Move point away
                                  (goto-char (point-min))
                                  ;; Enter normal state — should snap to terminal cursor
                                  (evil-normal-state)
                                  (should (= 11 (current-column)))))

;; -----------------------------------------------------------------------
;; Test: delete-region primitive
;; -----------------------------------------------------------------------

(ert-deftest ghostel-evil-test-delete-region ()
  "Test that `ghostel-evil--delete-region' sends correct keys."
  (ghostel-evil-test--with-buffer 5 40 "$ echo hello"
                                  ;; Delete "hello" (col 7-12)
                                  (let ((keys-sent '()))
                                    (cl-letf (((symbol-function 'ghostel--send-encoded)
                                               (lambda (key _mods &rest _)
                                                 (push key keys-sent))))
                                      (ghostel-evil--delete-region 8 13))
                                    ;; Should send arrow keys to move cursor, then 5 backspaces
                                    (should (= 5 (cl-count "backspace" keys-sent :test #'equal))))))

;; -----------------------------------------------------------------------
;; Test: evil-delete advice
;; -----------------------------------------------------------------------

(ert-deftest ghostel-evil-test-delete-sends-backspace-keys ()
  "Test that `evil-delete' advice sends backspace keys via PTY."
  (ghostel-evil-test--with-evil-buffer
   (setq-local ghostel--term t)
   (ghostel-evil-test--insert "hello world")
   (goto-char (point-min))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0)))
             ((symbol-function 'ghostel-evil--cursor-to-point) #'ignore))
     (evil-normal-state)
     (let ((bs-count 0))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _)
                    (when (equal key "backspace")
                      (cl-incf bs-count)))))
         ;; Delete 5 chars (simulates dw on "hello")
         (evil-delete 1 6 'inclusive nil nil))
       (should (= 5 bs-count))))))

(ert-deftest ghostel-evil-test-delete-line-sends-ctrl-u ()
  "Test that line-type `evil-delete' sends Ctrl+U to clear line."
  (ghostel-evil-test--with-evil-buffer
   (setq-local ghostel--term t)
   (ghostel-evil-test--insert "hello world")
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

(ert-deftest ghostel-evil-test-delete-char ()
  "Test that `evil-delete-char' (x) works without error.
Regression: yank-handler arg was not optional in advice signature,
so calls from `evil-delete-char' (which passes only 4 args to
`evil-delete') raised `wrong-number-of-arguments'."
  (ghostel-evil-test--with-evil-buffer
   (setq-local ghostel--term t)
   (insert "hello")
   (goto-char (point-min))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0)))
             ((symbol-function 'ghostel-evil--cursor-to-point) #'ignore)
             ((symbol-function 'ghostel--send-encoded) #'ignore))
     (evil-normal-state)
     ;; evil-delete-char calls evil-delete without yank-handler
     (evil-delete-char 1 2 'exclusive nil)
     (should (eq evil-state 'normal)))))

;; -----------------------------------------------------------------------
;; Test: evil-change advice
;; -----------------------------------------------------------------------

(ert-deftest ghostel-evil-test-change-deletes-and-inserts ()
  "Test that `evil-change' advice deletes via PTY and enters insert state."
  (ghostel-evil-test--with-evil-buffer
   (setq-local ghostel--term t)
   (ghostel-evil-test--insert "hello world")
   (goto-char (point-min))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0)))
             ((symbol-function 'ghostel-evil--cursor-to-point) #'ignore))
     (evil-normal-state)
     (let ((bs-count 0))
       (cl-letf (((symbol-function 'ghostel--send-encoded)
                  (lambda (key _mods &rest _)
                    (when (equal key "backspace")
                      (cl-incf bs-count)))))
         (evil-change 1 6 'inclusive nil nil nil))
       (should (= 5 bs-count))
       (should (eq evil-state 'insert))))))

(ert-deftest ghostel-evil-test-change-whole-line ()
  "Test that `evil-change-whole-line' (cc/S) works without error.
Regression: delete-func arg was not optional in advice signature."
  (ghostel-evil-test--with-evil-buffer
   (setq-local ghostel--term t)
   (ghostel-evil-test--insert "hello world")
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

(ert-deftest ghostel-evil-test-replace-deletes-and-inserts ()
  "Test that `evil-replace' deletes then inserts replacement text."
  (ghostel-evil-test--with-evil-buffer
   (setq-local ghostel--term t)
   (ghostel-evil-test--insert "hello")
   (goto-char (point-min))
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0)))
             ((symbol-function 'ghostel-evil--cursor-to-point) #'ignore))
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

(ert-deftest ghostel-evil-test-paste-after ()
  "Test that `evil-paste-after' pastes via PTY."
  (ghostel-evil-test--with-evil-buffer
   (setq-local ghostel--term t)
   (ghostel-evil-test--insert "hello")
   (kill-new "world")
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(0 . 0)))
             ((symbol-function 'ghostel-evil--cursor-to-point) #'ignore))
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

(ert-deftest ghostel-evil-test-ctrl-passthrough-sends-to-terminal ()
  "Test that Ctrl keys in insert state are sent to the terminal."
  (ghostel-evil-test--with-evil-buffer
   (setq-local ghostel--term t)
   (ghostel-evil-test--insert "hello world")
   (cl-letf (((symbol-function 'ghostel--mode-enabled) (lambda (&rest _) nil))
             ((symbol-function 'ghostel--cursor-position) (lambda (_) '(11 . 0))))
     (evil-insert-state)
     ;; Test a sample of keys from ghostel-evil--ctrl-passthrough-keys
     (dolist (key '("a" "d" "e" "k" "r" "u" "w" "y"))
       (let ((keys-sent '()))
         (cl-letf (((symbol-function 'ghostel--send-encoded)
                    (lambda (k mods &rest _)
                      (push (cons k mods) keys-sent))))
           (ghostel-evil--passthrough-ctrl key))
         (should (cl-find (cons key "ctrl") keys-sent :test #'equal)))))))

;; -----------------------------------------------------------------------
;; Test: insert-state entry skips vertical sync
;; -----------------------------------------------------------------------

(ert-deftest ghostel-evil-test-insert-entry-no-vertical-sync ()
  "Test that entering insert from a different row snaps to terminal cursor.
Prevents up/down arrows being sent as history navigation."
  (ghostel-evil-test--with-evil-buffer
   (setq-local ghostel--term t)
   (ghostel-evil-test--insert "line one\nline two\nline three")
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

(ert-deftest ghostel-evil-test-insert-entry-syncs-column-same-row ()
  "Test that entering insert on the same row syncs column position."
  (ghostel-evil-test--with-evil-buffer
   (setq-local ghostel--term t)
   (ghostel-evil-test--insert "hello world")
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

(ert-deftest ghostel-evil-test-undo-sends-ctrl-underscore ()
  "Test that `evil-undo' sends Ctrl+_ to the terminal."
  (ghostel-evil-test--with-evil-buffer
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

(ert-deftest ghostel-evil-test-delete-no-op-outside-ghostel ()
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

(defconst ghostel-evil-test--elisp-tests
  '(ghostel-evil-test-mode-activation
    ghostel-evil-test-mode-deactivation
    ghostel-evil-test-escape-stay
    ghostel-evil-test-advice-on-insert
    ghostel-evil-test-advice-on-append
    ghostel-evil-test-advice-insert-line-sends-home
    ghostel-evil-test-advice-append-line-sends-end
    ghostel-evil-test-advice-no-op-outside-ghostel
    ghostel-evil-test-delete-sends-backspace-keys
    ghostel-evil-test-delete-line-sends-ctrl-u
    ghostel-evil-test-delete-char
    ghostel-evil-test-change-deletes-and-inserts
    ghostel-evil-test-replace-deletes-and-inserts
    ghostel-evil-test-paste-after
    ghostel-evil-test-undo-sends-ctrl-underscore
    ghostel-evil-test-change-whole-line
    ghostel-evil-test-delete-no-op-outside-ghostel)
  "Tests that require only Elisp (no native module).")

(defun ghostel-evil-test-run-elisp ()
  "Run only pure Elisp tests (no native module required)."
  (ert-run-tests-batch-and-exit
   `(member ,@ghostel-evil-test--elisp-tests)))

(defun ghostel-evil-test-run ()
  "Run all ghostel-evil tests."
  (ert-run-tests-batch-and-exit "^ghostel-evil-test-"))

;;; ghostel-evil-test.el ends here
