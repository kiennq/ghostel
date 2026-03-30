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
(require 'url-parse)
(require 'face-remap)

;; Load the native module
(unless (featurep 'ghostel-module)
  (module-load
   (expand-file-name
    (concat "ghostel-module" module-file-suffix)
    (file-name-directory (or load-file-name buffer-file-name)))))

;; Declare native module functions for the byte compiler
(declare-function ghostel--new "ghostel-module")
(declare-function ghostel--write-input "ghostel-module")
(declare-function ghostel--set-size "ghostel-module")
(declare-function ghostel--redraw "ghostel-module")
(declare-function ghostel--scroll "ghostel-module")
(declare-function ghostel--encode-key "ghostel-module")
(declare-function ghostel--mouse-event "ghostel-module")

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

(defvar-local ghostel--last-directory nil
  "Last known working directory from OSC 7, used for dedup.")

(defvar ghostel--buffer-counter 0
  "Counter for generating unique terminal buffer names.")

;;; Keymap

(defvar ghostel-mode-map
  (let ((map (make-sparse-keymap)))
    ;; Self-insert characters
    (define-key map [remap self-insert-command] #'ghostel--self-insert)
    ;; Special keys — send raw bytes + local echo where applicable.
    ;; Local echo is needed because bash's readline output is buffered
    ;; and doesn't reach the process filter until a newline flush.
    (define-key map (kbd "RET")       #'ghostel--send-return)
    (define-key map (kbd "TAB")       (lambda () (interactive) (ghostel--send-key "\t")))
    (define-key map (kbd "DEL")       #'ghostel--send-backspace)
    (define-key map (kbd "<backspace>") #'ghostel--send-backspace)
    ;; Control keys
    (define-key map (kbd "C-d")       (lambda () (interactive) (ghostel--send-key "\x04")))
    (define-key map (kbd "C-a")       (lambda () (interactive) (ghostel--send-key "\x01")))
    (define-key map (kbd "C-e")       (lambda () (interactive) (ghostel--send-key "\x05")))
    (define-key map (kbd "C-k")       (lambda () (interactive) (ghostel--send-key "\x0b")))
    (define-key map (kbd "C-l")       (lambda () (interactive) (ghostel--send-key "\x0c")))
    (define-key map (kbd "C-n")       (lambda () (interactive) (ghostel--send-key "\x0e")))
    (define-key map (kbd "C-p")       (lambda () (interactive) (ghostel--send-key "\x10")))
    (define-key map (kbd "C-r")       (lambda () (interactive) (ghostel--send-key "\x12")))
    (define-key map (kbd "C-w")       (lambda () (interactive) (ghostel--send-key "\x17")))
    (define-key map (kbd "C-y")       (lambda () (interactive) (ghostel--send-key "\x19")))
    (define-key map (kbd "C-z")       (lambda () (interactive) (ghostel--send-key "\x1a")))
    ;; Terminal control via C-c prefix (pass through to Emacs, then handled here)
    (define-key map (kbd "C-c C-c")   #'ghostel-send-C-c)
    (define-key map (kbd "C-c C-z")   #'ghostel-send-C-z)
    (define-key map (kbd "C-c C-\\")  #'ghostel-send-C-backslash)
    (define-key map (kbd "C-c C-d")   #'ghostel-send-C-d)
    (define-key map (kbd "C-c C-k")   #'ghostel-copy-mode)
    (define-key map (kbd "C-c C-y")   #'ghostel-paste)
    ;; Cursor and navigation keys — raw escape sequences
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
    ;; Function keys
    (define-key map (kbd "<f1>")      (lambda () (interactive) (ghostel--send-key "\eOP")))
    (define-key map (kbd "<f2>")      (lambda () (interactive) (ghostel--send-key "\eOQ")))
    (define-key map (kbd "<f3>")      (lambda () (interactive) (ghostel--send-key "\eOR")))
    (define-key map (kbd "<f4>")      (lambda () (interactive) (ghostel--send-key "\eOS")))
    (define-key map (kbd "<f5>")      (lambda () (interactive) (ghostel--send-key "\e[15~")))
    (define-key map (kbd "<f6>")      (lambda () (interactive) (ghostel--send-key "\e[17~")))
    (define-key map (kbd "<f7>")      (lambda () (interactive) (ghostel--send-key "\e[18~")))
    (define-key map (kbd "<f8>")      (lambda () (interactive) (ghostel--send-key "\e[19~")))
    (define-key map (kbd "<f9>")      (lambda () (interactive) (ghostel--send-key "\e[20~")))
    (define-key map (kbd "<f10>")     (lambda () (interactive) (ghostel--send-key "\e[21~")))
    (define-key map (kbd "<f11>")     (lambda () (interactive) (ghostel--send-key "\e[23~")))
    (define-key map (kbd "<f12>")     (lambda () (interactive) (ghostel--send-key "\e[24~")))
    ;; Shifted arrow keys
    (define-key map (kbd "S-<up>")    (lambda () (interactive) (ghostel--send-key "\e[1;2A")))
    (define-key map (kbd "S-<down>")  (lambda () (interactive) (ghostel--send-key "\e[1;2B")))
    (define-key map (kbd "S-<right>") (lambda () (interactive) (ghostel--send-key "\e[1;2C")))
    (define-key map (kbd "S-<left>")  (lambda () (interactive) (ghostel--send-key "\e[1;2D")))
    ;; Mouse wheel for scrollback
    (define-key map (kbd "<mouse-4>")       #'ghostel--scroll-up)
    (define-key map (kbd "<mouse-5>")       #'ghostel--scroll-down)
    (define-key map (kbd "<wheel-up>")      #'ghostel--scroll-up)
    (define-key map (kbd "<wheel-down>")    #'ghostel--scroll-down)
    ;; Mouse click events (for terminal mouse tracking)
    (define-key map (kbd "<down-mouse-1>")  #'ghostel--mouse-press)
    (define-key map (kbd "<mouse-1>")       #'ghostel--mouse-release)
    (define-key map (kbd "<down-mouse-2>")  #'ghostel--mouse-press)
    (define-key map (kbd "<mouse-2>")       #'ghostel--mouse-release)
    (define-key map (kbd "<down-mouse-3>")  #'ghostel--mouse-press)
    (define-key map (kbd "<mouse-3>")       #'ghostel--mouse-release)
    (define-key map (kbd "<drag-mouse-1>")  #'ghostel--mouse-drag)
    (define-key map (kbd "<drag-mouse-2>")  #'ghostel--mouse-drag)
    (define-key map (kbd "<drag-mouse-3>")  #'ghostel--mouse-drag)
    ;; Drag and drop
    (define-key map [drag-n-drop]           #'ghostel--drop)
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
UTF8 is optional text generated by the key.
Falls back to raw escape sequences if the encoder doesn't produce output."
  (when ghostel--term
    (unless (ghostel--encode-key ghostel--term key-name mods utf8)
      (let ((seq (ghostel--raw-key-sequence key-name mods)))
        (when seq (ghostel--send-key seq))))))

(defun ghostel--raw-key-sequence (key-name mods)
  "Build a raw escape sequence for KEY-NAME with MODS.
Returns the sequence string, or nil for unknown keys."
  (let ((mod-num (ghostel--modifier-number mods)))
    (cond
     ;; Ctrl + single letter
     ((and (= (length key-name) 1)
           (<= ?a (aref key-name 0)) (<= (aref key-name 0) ?z)
           (> (logand mod-num 4) 0))        ; ctrl bit
      (string (- (aref key-name 0) 96)))    ; ctrl-a=1, ctrl-z=26
     ;; Simple special keys
     ((string= key-name "backspace") "\x7f")
     ((string= key-name "return") "\r")
     ((string= key-name "tab") "\t")
     ((string= key-name "escape") "\e")
     ((string= key-name "space") " ")
     ;; Cursor keys
     ((string= key-name "up")    (ghostel--csi-letter "A" mod-num))
     ((string= key-name "down")  (ghostel--csi-letter "B" mod-num))
     ((string= key-name "right") (ghostel--csi-letter "C" mod-num))
     ((string= key-name "left")  (ghostel--csi-letter "D" mod-num))
     ((string= key-name "home")  (ghostel--csi-letter "H" mod-num))
     ((string= key-name "end")   (ghostel--csi-letter "F" mod-num))
     ;; Tilde keys
     ((string= key-name "insert") (ghostel--csi-tilde 2 mod-num))
     ((string= key-name "delete") (ghostel--csi-tilde 3 mod-num))
     ((string= key-name "prior")  (ghostel--csi-tilde 5 mod-num))
     ((string= key-name "next")   (ghostel--csi-tilde 6 mod-num))
     ;; Function keys (F1-F4 use SS3, F5-F12 use tilde)
     ((string= key-name "f1")  (if (> mod-num 0) (format "\e[1;%dP" (1+ mod-num)) "\eOP"))
     ((string= key-name "f2")  (if (> mod-num 0) (format "\e[1;%dQ" (1+ mod-num)) "\eOQ"))
     ((string= key-name "f3")  (if (> mod-num 0) (format "\e[1;%dR" (1+ mod-num)) "\eOR"))
     ((string= key-name "f4")  (if (> mod-num 0) (format "\e[1;%dS" (1+ mod-num)) "\eOS"))
     ((string= key-name "f5")  (ghostel--csi-tilde 15 mod-num))
     ((string= key-name "f6")  (ghostel--csi-tilde 17 mod-num))
     ((string= key-name "f7")  (ghostel--csi-tilde 18 mod-num))
     ((string= key-name "f8")  (ghostel--csi-tilde 19 mod-num))
     ((string= key-name "f9")  (ghostel--csi-tilde 20 mod-num))
     ((string= key-name "f10") (ghostel--csi-tilde 21 mod-num))
     ((string= key-name "f11") (ghostel--csi-tilde 23 mod-num))
     ((string= key-name "f12") (ghostel--csi-tilde 24 mod-num))
     (t nil))))

(defun ghostel--modifier-number (mods)
  "Convert MODS string to a bitmask: shift=1, alt=2, ctrl=4."
  (let ((n 0))
    (when (string-match-p "shift" mods) (setq n (logior n 1)))
    (when (string-match-p "alt\\|meta" mods) (setq n (logior n 2)))
    (when (string-match-p "ctrl\\|control" mods) (setq n (logior n 4)))
    n))

(defun ghostel--csi-letter (letter mod-num)
  "Format CSI cursor-key sequence for LETTER with MOD-NUM modifier."
  (if (> mod-num 0)
      (format "\e[1;%d%s" (1+ mod-num) letter)
    (format "\e[%s" letter)))

(defun ghostel--csi-tilde (param mod-num)
  "Format CSI tilde sequence for PARAM with MOD-NUM modifier."
  (if (> mod-num 0)
      (format "\e[%d;%d~" param (1+ mod-num))
    (format "\e[%d~" param)))

(defun ghostel--self-insert ()
  "Send the last typed character to the terminal."
  (interactive)
  (let* ((keys (this-command-keys))
         (char (aref keys (1- (length keys))))
         (str (if (and (characterp char) (< char 128))
                  (string char)
                (encode-coding-string (string char) 'utf-8))))
    (ghostel--send-key str)))

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

;;; Terminal control commands (C-c prefix)

(defun ghostel-send-C-c ()
  "Send interrupt signal to the terminal."
  (interactive)
  (ghostel--send-encoded "c" "ctrl"))

(defun ghostel-send-C-z ()
  "Send suspend signal to the terminal."
  (interactive)
  (ghostel--send-encoded "z" "ctrl"))

(defun ghostel-send-C-backslash ()
  "Send C-\\ (quit) to the terminal."
  (interactive)
  (ghostel--send-key "\x1c"))

(defun ghostel-send-C-d ()
  "Send EOF to the terminal."
  (interactive)
  (ghostel--send-encoded "d" "ctrl"))

;;; Paste

(defun ghostel-paste ()
  "Paste text from the Emacs kill ring into the terminal.
Uses bracketed paste mode so that shells can distinguish
pasted text from typed input."
  (interactive)
  (let ((text (current-kill 0)))
    (when (and text ghostel--process (process-live-p ghostel--process))
      (process-send-string ghostel--process
                           (concat "\e[200~" text "\e[201~")))))

;;; Drag and drop

(defun ghostel--drop (event)
  "Handle a drag-and-drop EVENT into the terminal.
Dropped files insert their path (shell-quoted); dropped text is
pasted using bracketed paste."
  (interactive "e")
  (when (and ghostel--process (process-live-p ghostel--process))
    (let ((payload (car (last (nth 1 event)))))
      (cond
       ;; File drop — payload is a filename string from the drop event
       ((and (stringp payload) (file-exists-p payload))
        (ghostel--send-key (shell-quote-argument payload)))
       ;; URI list (e.g. from file managers that drop file:// URIs)
       ((and (stringp payload) (string-prefix-p "file://" payload))
        (let ((path (url-filename (url-generic-parse-url payload))))
          (ghostel--send-key (shell-quote-argument path))))
       ;; Text drop
       ((stringp payload)
        (process-send-string ghostel--process
                             (concat "\e[200~" payload "\e[201~")))
       ;; dnd-protocol-alist style: list of files
       ((and (listp payload) (cl-every #'stringp payload))
        (ghostel--send-key
         (mapconcat #'shell-quote-argument payload " ")))))))

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

;;; Mouse input

(defun ghostel--mouse-button-number (event)
  "Return the ghostty mouse button number for EVENT."
  (pcase (event-basic-type event)
    ('mouse-1 1)
    ('mouse-2 3)
    ('mouse-3 2)
    (_ 0)))

(defun ghostel--mouse-mods (event)
  "Return ghostty modifier bitmask for mouse EVENT."
  (let ((mods (event-modifiers event))
        (result 0))
    (when (memq 'shift mods) (setq result (logior result 1)))
    (when (memq 'control mods) (setq result (logior result 4)))
    (when (memq 'meta mods) (setq result (logior result 2)))
    result))

(defun ghostel--mouse-press (event)
  "Handle mouse button press EVENT for terminal mouse tracking."
  (interactive "e")
  (when (and ghostel--term ghostel--process (process-live-p ghostel--process))
    (let* ((posn (event-start event))
           (col-row (posn-col-row posn))
           (col (car col-row))
           (row (cdr col-row)))
      (ghostel--mouse-event ghostel--term
                            0  ; press
                            (ghostel--mouse-button-number event)
                            row col
                            (ghostel--mouse-mods event)))))

(defun ghostel--mouse-release (event)
  "Handle mouse button release EVENT for terminal mouse tracking."
  (interactive "e")
  (when (and ghostel--term ghostel--process (process-live-p ghostel--process))
    (let* ((posn (event-end event))
           (col-row (posn-col-row posn))
           (col (car col-row))
           (row (cdr col-row)))
      (ghostel--mouse-event ghostel--term
                            1  ; release
                            (ghostel--mouse-button-number event)
                            row col
                            (ghostel--mouse-mods event)))))

(defun ghostel--mouse-drag (event)
  "Handle mouse drag EVENT as motion for terminal mouse tracking."
  (interactive "e")
  (when (and ghostel--term ghostel--process (process-live-p ghostel--process))
    (let* ((posn (event-end event))
           (col-row (posn-col-row posn))
           (col (car col-row))
           (row (cdr col-row)))
      (ghostel--mouse-event ghostel--term
                            2  ; motion
                            (ghostel--mouse-button-number event)
                            row col
                            (ghostel--mouse-mods event)))))

;;; Copy mode

(defvar ghostel-copy-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "q") #'ghostel-copy-mode-exit)
    (define-key map (kbd "C-c C-k") #'ghostel-copy-mode-exit)
    (define-key map (kbd "M-w") #'ghostel-copy-mode-copy)
    (define-key map (kbd "C-w") #'ghostel-copy-mode-copy)
    map)
  "Keymap for `ghostel-copy-mode'.
Standard Emacs navigation works.
Set mark, navigate to select, then \\[ghostel-copy-mode-copy] to copy.")

(defvar-local ghostel--copy-mode-active nil
  "Non-nil when copy mode is active.")

(defvar-local ghostel--saved-local-map nil
  "Saved keymap before entering copy mode.")

(defun ghostel-copy-mode ()
  "Enter copy mode for selecting and copying terminal text.
The display is frozen and standard Emacs navigation keys work.
Set mark, navigate to select, then \\[ghostel-copy-mode-copy] to copy.
Press \\`q' or \\[ghostel-copy-mode-exit] to exit without copying."
  (interactive)
  (if ghostel--copy-mode-active
      (ghostel-copy-mode-exit)
    ;; Freeze display
    (setq ghostel--copy-mode-active t)
    (when ghostel--redraw-timer
      (cancel-timer ghostel--redraw-timer)
      (setq ghostel--redraw-timer nil))
    ;; Switch to copy mode keymap (standard Emacs keys work by default)
    (setq ghostel--saved-local-map (current-local-map))
    (use-local-map ghostel-copy-mode-map)
    (setq buffer-read-only t)
    (setq mode-name "Ghostel:Copy")
    (force-mode-line-update)
    (message "Copy mode: C-SPC to mark, navigate to select, M-w to copy, q to exit")))

(defun ghostel-copy-mode-exit ()
  "Exit copy mode and return to terminal mode."
  (interactive)
  (when ghostel--copy-mode-active
    (setq ghostel--copy-mode-active nil)
    (deactivate-mark)
    (use-local-map ghostel--saved-local-map)
    (setq buffer-read-only nil)
    (setq mode-name "Ghostel")
    (force-mode-line-update)
    (ghostel--invalidate)
    (message "Copy mode exited")))

(defun ghostel-copy-mode-copy ()
  "Copy the selected region and exit copy mode."
  (interactive)
  (when (use-region-p)
    (kill-ring-save (region-beginning) (region-end))
    (message "Copied to kill ring"))
  (ghostel-copy-mode-exit))

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

(defun ghostel--update-directory (dir)
  "Update `default-directory' from terminal's OSC 7 report.
DIR may be a file:// URL or a plain path."
  (when (and dir (not (equal dir ghostel--last-directory)))
    (setq ghostel--last-directory dir)
    (let ((path (if (string-prefix-p "file://" dir)
                    (url-filename (url-generic-parse-url dir))
                  dir)))
      (when (and path (file-directory-p path))
        (setq default-directory (file-name-as-directory path))))))

;;; Process management

(defun ghostel--filter (process output)
  "Process filter: feed PTY output to the terminal.
PROCESS is the shell process, OUTPUT is the raw byte string."
  (when (buffer-live-p (process-buffer process))
    (with-current-buffer (process-buffer process)
      (when ghostel--term
        ;; Pass raw bytes directly — CRLF normalization is done
        ;; in the Zig module to avoid unibyte→multibyte corruption.
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
    ;; Enable PTY echo.  Shells like bash's readline buffer their own
    ;; echo output so it never reaches our process filter.  Enabling
    ;; PTY-level echo makes the kernel echo input immediately.  Shells
    ;; that manage echo themselves (zsh/ZLE) override this on each prompt.
    (process-send-string proc "stty echo\n")
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
      (when (and ghostel--term (not ghostel--copy-mode-active))
        (let ((inhibit-read-only t)
              (inhibit-redisplay t))
          (ghostel--redraw ghostel--term))))))

(defun ghostel-force-redraw ()
  "Force a full terminal redraw (for debugging)."
  (interactive)
  (when ghostel--term
    (let ((inhibit-read-only t))
      (ghostel--redraw ghostel--term))))

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
              #'ghostel--window-adjust-process-window-size)
  )

;;; Entry point

;;;###autoload
(defun ghostel ()
  "Create a new Ghostel terminal buffer."
  (interactive)
  (let* ((index (cl-incf ghostel--buffer-counter))
         (buf-name (if (= index 1)
                       ghostel-buffer-name
                     (format "%s<%d>" ghostel-buffer-name index)))
         (buffer (generate-new-buffer buf-name)))
    (with-current-buffer buffer
      (ghostel-mode)
      (let* ((height (window-body-height))
             (width (window-max-chars-per-line)))
        (setq ghostel--term
              (ghostel--new height width ghostel-max-scrollback)))
      (ghostel--start-process))
    (switch-to-buffer buffer)))

(defun ghostel-other ()
  "Switch to the next ghostel terminal buffer, or create one."
  (interactive)
  (let* ((bufs (cl-remove-if-not
                (lambda (b)
                  (with-current-buffer b
                    (eq major-mode 'ghostel-mode)))
                (buffer-list)))
         (current (current-buffer))
         (others (cl-remove current bufs)))
    (if others
        (switch-to-buffer (car others))
      (ghostel))))

(provide 'ghostel)

;;; ghostel.el ends here
