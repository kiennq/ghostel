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
    (define-key map (kbd "C-d")       (lambda () (interactive) (ghostel--send-key "\C-d")))
    (define-key map (kbd "C-a")       (lambda () (interactive) (ghostel--send-key "\C-a")))
    (define-key map (kbd "C-e")       (lambda () (interactive) (ghostel--send-key "\C-e")))
    (define-key map (kbd "C-k")       (lambda () (interactive) (ghostel--send-key "\C-k")))
    (define-key map (kbd "C-l")       (lambda () (interactive) (ghostel--send-key "\C-l")))
    (define-key map (kbd "C-n")       (lambda () (interactive) (ghostel--send-key "\C-n")))
    (define-key map (kbd "C-p")       (lambda () (interactive) (ghostel--send-key "\C-p")))
    (define-key map (kbd "C-r")       (lambda () (interactive) (ghostel--send-key "\C-r")))
    (define-key map (kbd "C-w")       (lambda () (interactive) (ghostel--send-key "\C-w")))
    (define-key map (kbd "C-y")       (lambda () (interactive) (ghostel--send-key "\C-y")))
    (define-key map (kbd "C-z")       (lambda () (interactive) (ghostel--send-key "\C-z")))
    (define-key map (kbd "<escape>")  (lambda () (interactive) (ghostel--send-key "\e")))
    (define-key map (kbd "<up>")      (lambda () (interactive) (ghostel--send-key "\e[A")))
    (define-key map (kbd "<down>")    (lambda () (interactive) (ghostel--send-key "\e[B")))
    (define-key map (kbd "<right>")   (lambda () (interactive) (ghostel--send-key "\e[C")))
    (define-key map (kbd "<left>")    (lambda () (interactive) (ghostel--send-key "\e[D")))
    (define-key map (kbd "<home>")    (lambda () (interactive) (ghostel--send-key "\e[H")))
    (define-key map (kbd "<end>")     (lambda () (interactive) (ghostel--send-key "\e[F")))
    (define-key map (kbd "<prior>")   (lambda () (interactive) (ghostel--send-key "\e[5~")))
    (define-key map (kbd "<next>")    (lambda () (interactive) (ghostel--send-key "\e[6~")))
    (define-key map (kbd "<deletechar>") (lambda () (interactive) (ghostel--send-key "\e[3~")))
    (define-key map (kbd "<insert>")  (lambda () (interactive) (ghostel--send-key "\e[2~")))
    map)
  "Keymap for `ghostel-mode'.")

;;; Key sending

(defun ghostel--send-key (key)
  "Send KEY string to the terminal process."
  (when (and ghostel--process (process-live-p ghostel--process))
    (process-send-string ghostel--process key)))

(defun ghostel--self-insert ()
  "Send the last typed character to the terminal."
  (interactive)
  (let ((char (this-command-keys)))
    (ghostel--send-key char)))

(defun ghostel--send-return ()
  "Send return to the terminal."
  (interactive)
  (ghostel--send-key "\r"))

(defun ghostel--send-tab ()
  "Send tab to the terminal."
  (interactive)
  (ghostel--send-key "\t"))

(defun ghostel--send-backspace ()
  "Send backspace to the terminal."
  (interactive)
  (ghostel--send-key "\x7f"))

;;; Callbacks from native module

(defun ghostel--flush-output (data)
  "Write DATA back to the shell process (response from terminal)."
  (when (and ghostel--process (process-live-p ghostel--process))
    (process-send-string ghostel--process data)))

(defun ghostel--set-title (title)
  "Update the buffer name with TITLE from the terminal."
  (rename-buffer (format "*ghostel: %s*" title) t))

;;; Process management

(defun ghostel--filter (process output)
  "Process filter: feed PTY output to the terminal.
PROCESS is the shell process, OUTPUT is the raw byte string."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (when ghostel--term
        ;; Feed bytes to native module (callbacks fire synchronously)
        (ghostel--write-input ghostel--term output)
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
  (let* ((process-environment
          (append
           (list
            (format "TERM=%s" "xterm-256color")
            (format "COLUMNS=%d" (window-max-chars-per-line))
            (format "LINES=%d" (window-body-height)))
           process-environment))
         (proc (make-process
                :name "ghostel"
                :buffer (current-buffer)
                :command (list ghostel-shell)
                :connection-type 'pty
                :filter #'ghostel--filter
                :sentinel #'ghostel--sentinel)))
    (setq ghostel--process proc)
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

(defun ghostel--window-adjust-process-window-size (_process windows)
  "Resize the terminal when the Emacs window changes size.
WINDOWS is the list of windows displaying the process buffer."
  (let* ((window (car windows))
         (width (window-max-chars-per-line window))
         (height (window-body-height window)))
    (when ghostel--term
      (ghostel--set-size ghostel--term height width)
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
