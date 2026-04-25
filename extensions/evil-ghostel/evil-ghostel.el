;;; evil-ghostel.el --- Evil-mode integration for ghostel -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Daniel Kraus <daniel@kraus.my>

;; Author: Daniel Kraus <daniel@kraus.my>
;; URL: https://github.com/dakra/ghostel
;; Version: 0.18.1
;; Package-Requires: ((emacs "28.1") (evil "1.0") (ghostel "0.8.0"))
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is NOT part of GNU Emacs.

;;; Commentary:

;; Provides evil-mode compatibility for the ghostel terminal emulator.
;; Synchronizes the terminal cursor with Emacs point during evil state
;; transitions so that normal-mode navigation works correctly.
;;
;; Enable by adding to your init:
;;
;;   (use-package evil-ghostel
;;     :after (ghostel evil)
;;     :hook (ghostel-mode . evil-ghostel-mode))

;;; Code:

(require 'evil)
(require 'ghostel)

;; ---------------------------------------------------------------------------
;; Customization
;; ---------------------------------------------------------------------------

(defgroup evil-ghostel nil
  "Evil-mode integration for ghostel."
  :group 'ghostel
  :prefix "evil-ghostel-")

(defcustom evil-ghostel-initial-state 'insert
  "Initial evil state for new `ghostel-mode' buffers.
Setting this option via `customize-set-variable', `setopt', or the
Customize UI calls `evil-set-initial-state' so the change takes effect
immediately.  Users who prefer the raw API can call
`evil-set-initial-state' directly from their config — the registry is
last-writer-wins."
  :type '(choice (const :tag "Emacs" emacs)
                 (const :tag "Insert" insert)
                 (const :tag "Normal" normal)
                 (symbol :tag "Other state"))
  :set (lambda (sym val)
         (set-default-toplevel-value sym val)
         (evil-set-initial-state 'ghostel-mode val)))

;; Apply the current value at load.  Covers the case where the user set
;; the variable with plain `setq' before loading the package — in that
;; path `defcustom' preserves the value without invoking `:set'.
(evil-set-initial-state 'ghostel-mode evil-ghostel-initial-state)

;; ---------------------------------------------------------------------------
;; Guard predicate
;; ---------------------------------------------------------------------------

(defun evil-ghostel--active-p ()
  "Return non-nil when evil-ghostel editing should intercept."
  (and evil-ghostel-mode
       ghostel--term
       (not (ghostel--mode-enabled ghostel--term 1049))
       (not ghostel--copy-mode-active)))

;; ---------------------------------------------------------------------------
;; Cursor synchronization
;; ---------------------------------------------------------------------------

(defun evil-ghostel--reset-cursor-point ()
  "Move Emacs point to the terminal cursor position.
`ghostel--cursor-position' returns row relative to the viewport
\(the last `ghostel--term-rows' lines of the buffer), so the row
must be offset by the scrollback line count.  Mirrors the
placement math the native module performs in `src/render.zig'."
  (when (and ghostel--term ghostel--term-rows)
    (let ((pos (ghostel--cursor-position ghostel--term)))
      (when pos
        (let ((scrollback (max 0 (- (line-number-at-pos (point-max))
                                    ghostel--term-rows))))
          (goto-char (point-min))
          (forward-line (+ scrollback (cdr pos)))
          (move-to-column (car pos)))))))

(defun evil-ghostel--cursor-to-point ()
  "Move the terminal cursor to Emacs point by sending arrow keys."
  (when ghostel--term
    (let* ((tpos (ghostel--cursor-position ghostel--term))
           (tcol (car tpos))
           (trow (cdr tpos))
           (ecol (current-column))
           (erow (- (line-number-at-pos (point) t) 1))
           (dy (- erow trow))
           (dx (- ecol tcol)))
      (cond ((> dy 0) (dotimes (_ dy) (ghostel--send-encoded "down" "")))
            ((< dy 0) (dotimes (_ (abs dy)) (ghostel--send-encoded "up" ""))))
      (cond ((> dx 0) (dotimes (_ dx) (ghostel--send-encoded "right" "")))
            ((< dx 0) (dotimes (_ (abs dx)) (ghostel--send-encoded "left" "")))))))

;; ---------------------------------------------------------------------------
;; Redraw: preserve point and evil visual markers across the native call
;; ---------------------------------------------------------------------------

(defun evil-ghostel--around-redraw (orig-fn term &optional full)
  "Preserve point and evil visual markers across the native redraw call.
Native `ghostel--redraw' in `src/render.zig' rewrites the viewport
region, moving every marker in the buffer.  `point' (non-terminal
states) and the evil-specific visual range markers are restored here;
`mark' is preserved by the native module itself and needs no handling
at this layer.

  - `point' in non-terminal states.  In `insert' and `emacs' point
    intentionally follows the TUI cursor.
  - `evil-visual-beginning' and `evil-visual-end' in `visual' state.

ORIG-FN is the advised `ghostel--redraw' called with TERM and FULL.
Skipped when the terminal is in alt-screen mode (1049); apps there
own the screen and drive their own redraw cycle."
  (if (and evil-ghostel-mode
           (not (ghostel--mode-enabled term 1049)))
      (let* ((preserve-point (not (memq evil-state '(insert emacs))))
             (visual-p (eq evil-state 'visual))
             (saved-point (and preserve-point (point)))
             (saved-vb (and visual-p (bound-and-true-p evil-visual-beginning)
                            (marker-position evil-visual-beginning)))
             (saved-ve (and visual-p (bound-and-true-p evil-visual-end)
                            (marker-position evil-visual-end))))
        (funcall orig-fn term full)
        (when preserve-point
          (goto-char (min saved-point (point-max))))
        (when visual-p
          (let ((pmax (point-max)))
            (when saved-vb
              (set-marker evil-visual-beginning (min saved-vb pmax)))
            (when saved-ve
              (set-marker evil-visual-end (min saved-ve pmax))))))
    (funcall orig-fn term full)))

;; ---------------------------------------------------------------------------
;; Cursor style: let evil control cursor shape
;; ---------------------------------------------------------------------------

(defun evil-ghostel--override-cursor-style (orig-fn style visible)
  "Let evil control cursor shape instead of the terminal.
ORIG-FN is the advised setter called with STYLE and VISIBLE.
In alt-screen mode, defer to the terminal's cursor style."
  (if (and evil-ghostel-mode
           ghostel--term
           (not (ghostel--mode-enabled ghostel--term 1049)))
      (evil-refresh-cursor)
    (funcall orig-fn style visible)))

;; ---------------------------------------------------------------------------
;; Evil state hooks
;; ---------------------------------------------------------------------------

(defvar evil-ghostel--sync-inhibit nil
  "When non-nil, skip arrow-key sync in the insert-state-entry hook.
Set by the `I'/`A' advice which send Home/End directly.")

(defun evil-ghostel--insert-state-entry ()
  "Sync terminal cursor to Emacs point when entering `emacs-state'.
Skipped when `evil-ghostel--sync-inhibit' is set (by I/A advice
which already sent Ctrl-a/Ctrl-e).
When point is on a different row from the terminal cursor, snap
back to the terminal cursor instead of sending up/down arrows
which the shell would interpret as history navigation."
  (when (derived-mode-p 'ghostel-mode)
    (if evil-ghostel--sync-inhibit
        (setq evil-ghostel--sync-inhibit nil)
      (when ghostel--term
        (let* ((tpos (ghostel--cursor-position ghostel--term))
               (trow (cdr tpos))
               (erow (- (line-number-at-pos (point) t) 1)))
          (if (= erow trow)
              (evil-ghostel--cursor-to-point)
            (evil-ghostel--reset-cursor-point)))))))

(defun evil-ghostel--escape-stay ()
  "Disable `evil-move-cursor-back' in ghostel buffers.
Moving the cursor back on ESC desynchronizes point from the terminal
cursor."
  (setq-local evil-move-cursor-back nil))

;; ---------------------------------------------------------------------------
;; Advice for evil insert-line / append-line
;; ---------------------------------------------------------------------------

(defun evil-ghostel--before-insert-line (&rest _)
  "Send Ctrl-a to move terminal cursor to start of input."
  (when (and evil-ghostel-mode ghostel--term)
    (ghostel--send-encoded "a" "ctrl")
    (setq evil-ghostel--sync-inhibit t)))

(defun evil-ghostel--before-append-line (&rest _)
  "Send Ctrl-e to move terminal cursor to end of input."
  (when (and evil-ghostel-mode ghostel--term)
    (ghostel--send-encoded "e" "ctrl")
    (setq evil-ghostel--sync-inhibit t)))

;; ---------------------------------------------------------------------------
;; Editing primitives
;; ---------------------------------------------------------------------------

(defun evil-ghostel--delete-region (beg end)
  "Delete text between BEG and END via the terminal PTY.
Moves terminal cursor to END, then sends backspace keys.
Uses backspace rather than forward-delete because the Delete key
escape sequence is not bound in all shell configurations."
  (let ((count (- end beg)))
    (when (> count 0)
      (goto-char end)
      (evil-ghostel--cursor-to-point)
      (dotimes (_ count)
        (ghostel--send-encoded "backspace" ""))
      (goto-char beg))))

;; ---------------------------------------------------------------------------
;; Advice for evil editing operators
;; ---------------------------------------------------------------------------

(defun evil-ghostel--around-delete
    (orig-fn beg end &optional type register yank-handler)
  "Intercept `evil-delete' in ghostel buffers.
ORIG-FN is the advised `evil-delete' called with BEG, END, TYPE,
REGISTER, and YANK-HANDLER.
Yanks text to REGISTER, then deletes via PTY.
Covers d, dd, D, x, X."
  (if (evil-ghostel--active-p)
      (progn
        (unless register
          (let ((text (filter-buffer-substring beg end)))
            (unless (string-match-p "\n" text)
              (evil-set-register ?- text))))
        (let ((evil-was-yanked-without-register nil))
          (evil-yank beg end type register yank-handler))
        (if (eq type 'line)
            ;; For line-type (dd): clear the input line
            (progn
              (ghostel--send-encoded "e" "ctrl")
              (ghostel--send-encoded "u" "ctrl"))
          (evil-ghostel--delete-region beg end)))
    (funcall orig-fn beg end type register yank-handler)))

(defun evil-ghostel--around-change
    (orig-fn beg end type register yank-handler &optional delete-func)
  "Intercept `evil-change' in ghostel buffers.
ORIG-FN is the advised `evil-change' called with BEG, END, TYPE,
REGISTER, YANK-HANDLER, and DELETE-FUNC.
Deletes via PTY, then enters insert state.
Covers c, cc, C, s, S."
  (if (evil-ghostel--active-p)
      (progn
        (let ((evil-was-yanked-without-register nil))
          (evil-yank beg end type register yank-handler))
        (if (eq type 'line)
            (progn
              (ghostel--send-encoded "e" "ctrl")
              (ghostel--send-encoded "u" "ctrl"))
          (evil-ghostel--delete-region beg end))
        (setq evil-ghostel--sync-inhibit t)
        (evil-insert 1))
    (funcall orig-fn beg end type register yank-handler delete-func)))

(defun evil-ghostel--around-replace (orig-fn beg end type char)
  "Intercept `evil-replace' in ghostel buffers.
ORIG-FN is the advised `evil-replace' called with BEG, END, TYPE,
and CHAR.
Deletes the range, then inserts replacement characters."
  (if (evil-ghostel--active-p)
      (when char
        (let ((count (- end beg)))
          (evil-ghostel--delete-region beg end)
          (ghostel--paste-text (make-string count char))))
    (funcall orig-fn beg end type char)))

(defun evil-ghostel--around-paste-after
    (orig-fn count &optional register yank-handler)
  "Intercept `evil-paste-after' in ghostel buffers.
ORIG-FN is the advised `evil-paste-after' called with COUNT,
REGISTER, and YANK-HANDLER.
Pastes from REGISTER via the terminal PTY."
  (if (evil-ghostel--active-p)
      (let ((text (if register
                      (evil-get-register register)
                    (current-kill 0)))
            (count (prefix-numeric-value count)))
        (when text
          (evil-ghostel--cursor-to-point)
          (ghostel--send-encoded "right" "")
          (dotimes (_ count)
            (ghostel--paste-text text))))
    (funcall orig-fn count register yank-handler)))

(defun evil-ghostel--around-paste-before
    (orig-fn count &optional register yank-handler)
  "Intercept `evil-paste-before' in ghostel buffers.
ORIG-FN is the advised `evil-paste-before' called with COUNT,
REGISTER, and YANK-HANDLER.
Pastes from REGISTER via the terminal PTY."
  (if (evil-ghostel--active-p)
      (let ((text (if register
                      (evil-get-register register)
                    (current-kill 0)))
            (count (prefix-numeric-value count)))
        (when text
          (evil-ghostel--cursor-to-point)
          (dotimes (_ count)
            (ghostel--paste-text text))))
    (funcall orig-fn count register yank-handler)))

;; ---------------------------------------------------------------------------
;; Insert-state Ctrl key passthrough
;; ---------------------------------------------------------------------------

(defvar evil-ghostel-mode-map (make-sparse-keymap)
  "Keymap for `evil-ghostel-mode'.
Insert-state Ctrl key bindings are set up via `evil-define-key*'.")

(defconst evil-ghostel--ctrl-passthrough-keys
  '("a" "d" "e" "k" "n" "p" "r" "t" "u" "w" "y")
  "Ctrl+key combinations to pass through to the terminal in insert state.
These keys all have standard readline/zle bindings (C-a beginning-of-line,
C-d EOF, C-e end-of-line, C-k kill-line, etc.) that would otherwise be
intercepted by evil's insert-state commands.")

(defun evil-ghostel--passthrough-ctrl (key)
  "Send Ctrl+KEY to the terminal PTY, or fall back to evil's binding.
Used for insert-state Ctrl keys that have readline/zle equivalents."
  (if (evil-ghostel--active-p)
      (ghostel--send-encoded key "ctrl")
    (let ((cmd (lookup-key evil-insert-state-map (kbd (concat "C-" key)))))
      (when (commandp cmd)
        (call-interactively cmd)))))

(dolist (key evil-ghostel--ctrl-passthrough-keys)
  (let ((k key))
    (evil-define-key* 'insert evil-ghostel-mode-map
                      (kbd (concat "C-" k))
                      (defalias (intern (format "evil-ghostel--passthrough-ctrl-%s" k))
                        (lambda ()
                          (interactive)
                          (evil-ghostel--passthrough-ctrl k))
                        (format "Send C-%s to the terminal or fall back to evil." k)))))

(defun evil-ghostel--around-undo (orig-fn count)
  "Intercept `evil-undo' in ghostel buffers.
ORIG-FN is the advised `evil-undo' called with COUNT.
Sends Ctrl+_ (readline undo) COUNT times."
  (if (evil-ghostel--active-p)
      (dotimes (_ (or count 1))
        (ghostel--send-encoded "_" "ctrl"))
    (funcall orig-fn count)))

(defun evil-ghostel--around-redo (orig-fn count)
  "Intercept `evil-redo' in ghostel buffers.
ORIG-FN is the advised `evil-redo' called with COUNT."
  (if (evil-ghostel--active-p)
      (message "Redo not supported in terminal")
    (funcall orig-fn count)))

;; ---------------------------------------------------------------------------
;; Minor mode
;; ---------------------------------------------------------------------------

;;;###autoload
(define-minor-mode evil-ghostel-mode
  "Minor mode for evil integration in ghostel terminal buffers.
Synchronizes the terminal cursor with Emacs point during evil
state transitions."
  :lighter nil
  :keymap evil-ghostel-mode-map
  (if evil-ghostel-mode
      (progn
        (evil-ghostel--escape-stay)
        (add-hook 'evil-insert-state-entry-hook
                  #'evil-ghostel--insert-state-entry nil t)
        ;; Reuse the insert-state sync when entering emacs-state — both
        ;; states expect point to follow the terminal cursor.
        (add-hook 'evil-emacs-state-entry-hook
                  #'evil-ghostel--insert-state-entry nil t)
        (advice-add 'evil-insert-line :before #'evil-ghostel--before-insert-line)
        (advice-add 'evil-append-line :before #'evil-ghostel--before-append-line)
        (advice-add 'evil-delete :around #'evil-ghostel--around-delete)
        (advice-add 'evil-change :around #'evil-ghostel--around-change)
        (advice-add 'evil-replace :around #'evil-ghostel--around-replace)
        (advice-add 'evil-paste-after :around #'evil-ghostel--around-paste-after)
        (advice-add 'evil-paste-before :around #'evil-ghostel--around-paste-before)
        (advice-add 'evil-undo :around #'evil-ghostel--around-undo)
        (advice-add 'evil-redo :around #'evil-ghostel--around-redo)
        (advice-add 'ghostel--redraw :around #'evil-ghostel--around-redraw)
        (advice-add 'ghostel--set-cursor-style :around
                    #'evil-ghostel--override-cursor-style)
        (evil-refresh-cursor))
    (remove-hook 'evil-insert-state-entry-hook
                 #'evil-ghostel--insert-state-entry t)
    (remove-hook 'evil-emacs-state-entry-hook
                 #'evil-ghostel--insert-state-entry t)
    (advice-remove 'evil-insert-line #'evil-ghostel--before-insert-line)
    (advice-remove 'evil-append-line #'evil-ghostel--before-append-line)
    (advice-remove 'evil-delete #'evil-ghostel--around-delete)
    (advice-remove 'evil-change #'evil-ghostel--around-change)
    (advice-remove 'evil-replace #'evil-ghostel--around-replace)
    (advice-remove 'evil-paste-after #'evil-ghostel--around-paste-after)
    (advice-remove 'evil-paste-before #'evil-ghostel--around-paste-before)
    (advice-remove 'evil-undo #'evil-ghostel--around-undo)
    (advice-remove 'evil-redo #'evil-ghostel--around-redo)
    (advice-remove 'ghostel--redraw #'evil-ghostel--around-redraw)
    (advice-remove 'ghostel--set-cursor-style
                   #'evil-ghostel--override-cursor-style)))

(provide 'evil-ghostel)
;;; evil-ghostel.el ends here
