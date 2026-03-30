;;; ghostel.el --- Terminal emulator powered by libghostty -*- lexical-binding: t; -*-

;; Author: Daniel Kraus
;; Version: 0.1.0
;; Package-Requires: ((emacs "25.1"))
;; Keywords: terminals
;; URL: https://github.com/dakra/ghostel

;;; Commentary:

;; Ghostel is an Emacs terminal emulator that uses libghostty-vt
;; (from the Ghostty project) for terminal emulation.  It follows the
;; same architecture as emacs-libvterm: a native dynamic module handles
;; terminal state and rendering, while Elisp manages the shell process,
;; keymap, and buffer.

;;; Code:

(require 'cl-lib)

;; Load the native module
(unless (featurep 'ghostel-module)
  (module-load
   (expand-file-name
    (concat "ghostel-module" module-file-suffix)
    (file-name-directory (or load-file-name buffer-file-name)))))

;;; Customization

(defgroup ghostel nil
  "Terminal emulator powered by libghostty."
  :group 'terminals
  :prefix "ghostel-")

(defcustom ghostel-shell (or (getenv "SHELL") "/bin/sh")
  "Shell program to run in the terminal."
  :type 'string
  :group 'ghostel)

(defcustom ghostel-max-scrollback 10000
  "Maximum number of scrollback lines."
  :type 'integer
  :group 'ghostel)

(defcustom ghostel-timer-delay 0.033
  "Delay in seconds before redrawing after output (roughly 30fps)."
  :type 'number
  :group 'ghostel)

(defcustom ghostel-buffer-name "*ghostel*"
  "Default buffer name for ghostel terminals."
  :type 'string
  :group 'ghostel)

(defcustom ghostel-keymap-exceptions
  '("C-c" "C-x" "C-u" "C-h" "C-g" "M-x" "M-o" "M-:" "C-\\")
  "Key sequences that should not be sent to the terminal.
These keys pass through to Emacs instead."
  :type '(repeat string)
  :group 'ghostel)

;;; Internal variables

(defvar-local ghostel--term nil
  "Handle to the native terminal instance.")

(defvar-local ghostel--process nil
  "The shell process.")

(defvar-local ghostel--redraw-timer nil
  "Timer for delayed redraw.")

;;; Keymap

(defvar ghostel-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Self-insert characters
    (define-key map [remap self-insert-command] #'ghostel--self-insert)
    ;; Special keys
    (define-key map (kbd "RET")       #'ghostel--send-return)
    (define-key map (kbd "TAB")       #'ghostel--send-tab)
    (define-key map (kbd "DEL")       #'ghostel--send-backspace)
    (define-key map (kbd "<backspace>") #'ghostel--send-backspace)
    ;; Control keys
    (define-key map (kbd "C-d")       (lambda () (interactive) (ghostel--send-encoded "d" "ctrl")))
    (define-key map (kbd "C-a")       (lambda () (interactive) (ghostel--send-encoded "a" "ctrl")))
    (define-key map (kbd "C-e")       (lambda () (interactive) (ghostel--send-encoded "e" "ctrl")))
    (define-key map (kbd "C-k")       (lambda () (interactive) (ghostel--send-encoded "k" "ctrl")))
    (define-key map (kbd "C-l")       (lambda () (interactive) (ghostel--send-encoded "l" "ctrl")))
    (define-key map (kbd "C-n")       (lambda () (interactive) (ghostel--send-encoded "n" "ctrl")))
    (define-key map (kbd "C-p")       (lambda () (interactive) (ghostel--send-encoded "p" "ctrl")))
    (define-key map (kbd "C-r")       (lambda () (interactive) (ghostel--send-encoded "r" "ctrl")))
    (define-key map (kbd "C-w")       (lambda () (interactive) (ghostel--send-encoded "w" "ctrl")))
    (define-key map (kbd "C-y")       (lambda () (interactive) (ghostel--send-encoded "y" "ctrl")))
    (define-key map (kbd "C-z")       (lambda () (interactive) (ghostel--send-encoded "z" "ctrl")))
    ;; Special keys (encoded via GhosttyKeyEncoder)
    (define-key map (kbd "<escape>")  (lambda () (interactive) (ghostel--send-encoded "escape" "")))
    (define-key map (kbd "<up>")      (lambda () (interactive) (ghostel--send-encoded "up" "")))
    (define-key map (kbd "<down>")    (lambda () (interactive) (ghostel--send-encoded "down" "")))
    (define-key map (kbd "<right>")   (lambda () (interactive) (ghostel--send-encoded "right" "")))
    (define-key map (kbd "<left>")    (lambda () (interactive) (ghostel--send-encoded "left" "")))
    (define-key map (kbd "<home>")    (lambda () (interactive) (ghostel--send-encoded "home" "")))
    (define-key map (kbd "<end>")     (lambda () (interactive) (ghostel--send-encoded "end" "")))
    (define-key map (kbd "<prior>")   (lambda () (interactive) (ghostel--send-encoded "prior" "")))
    (define-key map (kbd "<next>")    (lambda () (interactive) (ghostel--send-encoded "next" "")))
    (define-key map (kbd "<deletechar>") (lambda () (interactive) (ghostel--send-encoded "delete" "")))
    (define-key map (kbd "<insert>")  (lambda () (interactive) (ghostel--send-encoded "insert" "")))
    ;; Function keys
    (define-key map (kbd "<f1>")      (lambda () (interactive) (ghostel--send-encoded "f1" "")))
    (define-key map (kbd "<f2>")      (lambda () (interactive) (ghostel--send-encoded "f2" "")))
    (define-key map (kbd "<f3>")      (lambda () (interactive) (ghostel--send-encoded "f3" "")))
    (define-key map (kbd "<f4>")      (lambda () (interactive) (ghostel--send-encoded "f4" "")))
    (define-key map (kbd "<f5>")      (lambda () (interactive) (ghostel--send-encoded "f5" "")))
    (define-key map (kbd "<f6>")      (lambda () (interactive) (ghostel--send-encoded "f6" "")))
    (define-key map (kbd "<f7>")      (lambda () (interactive) (ghostel--send-encoded "f7" "")))
    (define-key map (kbd "<f8>")      (lambda () (interactive) (ghostel--send-encoded "f8" "")))
    (define-key map (kbd "<f9>")      (lambda () (interactive) (ghostel--send-encoded "f9" "")))
    (define-key map (kbd "<f10>")     (lambda () (interactive) (ghostel--send-encoded "f10" "")))
    (define-key map (kbd "<f11>")     (lambda () (interactive) (ghostel--send-encoded "f11" "")))
    (define-key map (kbd "<f12>")     (lambda () (interactive) (ghostel--send-encoded "f12" "")))
    ;; Shifted arrow keys
    (define-key map (kbd "S-<up>")    (lambda () (interactive) (ghostel--send-encoded "up" "shift")))
    (define-key map (kbd "S-<down>")  (lambda () (interactive) (ghostel--send-encoded "down" "shift")))
    (define-key map (kbd "S-<right>") (lambda () (interactive) (ghostel--send-encoded "right" "shift")))
    (define-key map (kbd "S-<left>")  (lambda () (interactive) (ghostel--send-encoded "left" "shift")))
    ;; Mouse wheel for scrollback
    (define-key map (kbd "<mouse-4>")       #'ghostel--scroll-up)
    (define-key map (kbd "<mouse-5>")       #'ghostel--scroll-down)
    (define-key map (kbd "<wheel-up>")      #'ghostel--scroll-up)
    (define-key map (kbd "<wheel-down>")    #'ghostel--scroll-down)
    map)
  "Keymap for `ghostel-mode'.")

;;; Key sending

(defun ghostel--send-key (key)
  "Send KEY string to the terminal process."
  (when (and ghostel--process (process-live-p ghostel--process))
    (process-send-string ghostel--process key)))

(defun ghostel--send-encoded (key-name mods &optional utf8)
  "Encode KEY-NAME with MODS via the terminal's key encoder and send.
KEY-NAME is a string like \"a\", \"return\", \"up\".
MODS is a string like \"ctrl\", \"shift,ctrl\", or \"\".
UTF8 is optional text generated by the key."
  (when ghostel--term
    (ghostel--encode-key ghostel--term key-name mods utf8)))

(defun ghostel--self-insert ()
  "Send the last typed character to the terminal."
  (interactive)
  (let* ((keys (this-command-keys))
         (char (aref keys (1- (length keys)))))
    (if (and (characterp char) (< char 128))
        ;; ASCII: send directly for simplicity
        (ghostel--send-key (string char))
      ;; Non-ASCII: encode as UTF-8 and send
      (ghostel--send-key (encode-coding-string (string char) 'utf-8)))))

(defun ghostel--send-return ()
  "Send return to the terminal."
  (interactive)
  (ghostel--send-encoded "return" ""))

(defun ghostel--send-tab ()
  "Send tab to the terminal."
  (interactive)
  (ghostel--send-encoded "tab" ""))

(defun ghostel--send-backspace ()
  "Send backspace to the terminal."
  (interactive)
  (ghostel--send-encoded "backspace" ""))

;;; Scrollback

(defun ghostel--scroll-up (&optional _event)
  "Scroll the terminal viewport up (into scrollback)."
  (interactive "e")
  (when ghostel--term
    (ghostel--scroll ghostel--term -3)
    (ghostel--invalidate)))

(defun ghostel--scroll-down (&optional _event)
  "Scroll the terminal viewport down."
  (interactive "e")
  (when ghostel--term
    (ghostel--scroll ghostel--term 3)
    (ghostel--invalidate)))

;;; Callbacks from native module

(defun ghostel--flush-output (data)
  "Write DATA back to the shell process (response from terminal)."
  (when (and ghostel--process (process-live-p ghostel--process))
    (process-send-string ghostel--process data)))

(defvar-local ghostel--face-cookie nil
  "Cookie from `face-remap-add-relative' for the terminal default face.")

(defun ghostel--set-buffer-face (fg bg)
  "Set the buffer's default face to FG foreground and BG background.
This ensures terminal text is visible regardless of the Emacs theme."
  (when ghostel--face-cookie
    (face-remap-remove-relative ghostel--face-cookie))
  (setq ghostel--face-cookie
        (face-remap-add-relative 'default
                                 :foreground fg
                                 :background bg)))

(defun ghostel--set-title (title)
  "Update the buffer name with TITLE from the terminal."
  (rename-buffer (format "*ghostel: %s*" title) t))

(defun ghostel--set-cursor-style (style visible)
  "Set the cursor style based on terminal state.
STYLE is one of: 0=bar, 1=block, 2=underline, 3=hollow-block.
VISIBLE is t or nil."
  (setq cursor-type
        (if visible
            (pcase style
              (0 '(bar . 2))       ; bar
              (1 'box)             ; block
              (2 '(hbar . 2))      ; underline
              (3 'hollow)          ; hollow block
              (_ 'box))
          nil)))

;;; Process management

(defun ghostel--filter (process output)
  "Process filter: feed PTY output to the terminal.
PROCESS is the shell process, OUTPUT is the raw byte string."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (when ghostel--term
        ;; Emacs PTYs lack ONLCR, so \n arrives without \r.
        ;; Normalize: ensure every \n is preceded by \r.
        (let ((data (replace-regexp-in-string "\r?\n" "\r\n" output)))
          (ghostel--write-input ghostel--term data))
        ;; Schedule redraw
        (ghostel--invalidate)))))

(defun ghostel--sentinel (process _event)
  "Process sentinel: clean up when shell exits.
PROCESS is the shell process."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (when ghostel--redraw-timer
        (cancel-timer ghostel--redraw-timer)
        (setq ghostel--redraw-timer nil))
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert "\n[Process exited]\n")))))

(defun ghostel--start-process ()
  "Start the shell process with a PTY."
  (let* ((height (max 1 (window-body-height)))
         (width (max 1 (window-max-chars-per-line)))
         (process-environment
          (append
           (list
            (format "TERM=%s" "xterm-256color")
            (format "COLUMNS=%d" width)
            (format "LINES=%d" height))
           process-environment))
         (proc (make-process
                :name "ghostel"
                :buffer (current-buffer)
                :command (list ghostel-shell)
                :connection-type 'pty
                :filter #'ghostel--filter
                :sentinel #'ghostel--sentinel)))
    (setq ghostel--process proc)
    ;; Raw binary I/O — no encoding/decoding by Emacs
    (set-process-coding-system proc 'binary 'binary)
    ;; Set the PTY's actual window size (ioctl TIOCSWINSZ) so that
    ;; the shell's line editor (readline/ZLE) can render properly.
    (set-process-window-size proc height width)
    (set-process-query-on-exit-flag proc nil)
    proc))

;;; Rendering

(defun ghostel--invalidate ()
  "Schedule a redraw after a short delay."
  (unless ghostel--redraw-timer
    (setq ghostel--redraw-timer
          (run-with-timer ghostel-timer-delay nil
                          #'ghostel--delayed-redraw
                          (current-buffer)))))

(defun ghostel--delayed-redraw (buffer)
  "Perform the actual redraw in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq ghostel--redraw-timer nil)
      (when ghostel--term
        (let ((inhibit-read-only t))
          (ghostel--redraw ghostel--term))))))

;;; Window resize

(defun ghostel--window-adjust-process-window-size (process windows)
  "Resize the terminal when the Emacs window changes size.
PROCESS is the shell process, WINDOWS is the list of windows."
  (let* ((window (car windows))
         (width (window-max-chars-per-line window))
         (height (window-body-height window)))
    (when ghostel--term
      (ghostel--set-size ghostel--term height width)
      ;; Update PTY dimensions (sends SIGWINCH to the shell)
      (when (process-live-p process)
        (set-process-window-size process height width))
      (ghostel--invalidate))
    (cons width height)))

;;; Major mode

(define-derived-mode ghostel-mode fundamental-mode "Ghostel"
  "Major mode for Ghostel terminal emulator."
  (buffer-disable-undo)
  (setq buffer-read-only nil)
  (setq-local scroll-margin 0)
  (setq-local hscroll-margin 0)
  (setq-local truncate-lines t)
  (setq-local scroll-conservatively 101)
  (setq-local window-adjust-process-window-size-function
              #'ghostel--window-adjust-process-window-size))

;;; Entry point

;;;###autoload
(defun ghostel ()
  "Create a new Ghostel terminal buffer."
  (interactive)
  (let ((buffer (generate-new-buffer ghostel-buffer-name)))
    (with-current-buffer buffer
      (ghostel-mode)
      (let* ((height (window-body-height))
             (width (window-max-chars-per-line)))
        (setq ghostel--term
              (ghostel--new height width ghostel-max-scrollback)))
      (ghostel--start-process))
    (switch-to-buffer buffer)))

(provide 'ghostel)

;;; ghostel.el ends here
