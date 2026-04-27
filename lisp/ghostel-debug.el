;;; ghostel-debug.el --- Diagnostic logging for ghostel -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Daniel Kraus <daniel@kraus.my>

;; Author: Daniel Kraus <daniel@kraus.my>
;; URL: https://github.com/dakra/ghostel
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; Diagnostic logging for ghostel.  Use `ghostel-debug-start' to begin
;; logging filter calls, key sends, and encoded key events to the
;; *ghostel-debug* buffer.  Use `ghostel-debug-stop' to stop.

;;; Code:

(require 'cl-lib)
(require 'lisp-mnt)
(require 'ghostel)

(declare-function ghostel--alt-screen-p "ghostel-module")
(declare-function ghostel--mode-enabled "ghostel-module")
(declare-function ghostel--module-version "ghostel-module")

(defvar ghostel-debug--log-buffer nil
  "Buffer used for ghostel debug logging.")

;;;###autoload
(defun ghostel-debug-start ()
  "Start logging ghostel events to *ghostel-debug* buffer.
Logs filter calls, key sends, resize events, redraw decisions
\(including DEC 2026 skip/force), and `window-start' anchoring."
  (interactive)
  (setq ghostel-debug--log-buffer (get-buffer-create "*ghostel-debug*"))
  (with-current-buffer ghostel-debug--log-buffer
    ;; `ghostel-debug-info' leaves the buffer in `special-mode' (read-only).
    ;; Reset to a writable state so logging advice can append freely.
    (fundamental-mode)
    (setq buffer-read-only nil)
    (erase-buffer)
    (insert "=== Ghostel Debug Log ===\n\n"))
  ;; Data path
  (advice-add 'ghostel--filter :before #'ghostel-debug--log-filter)
  (advice-add 'ghostel--send-string :before #'ghostel-debug--log-send)
  (advice-add 'ghostel--send-encoded :before #'ghostel-debug--log-encoded)
  ;; Render path
  (advice-add 'ghostel--delayed-redraw :around #'ghostel-debug--log-redraw)
  (advice-add 'ghostel--window-adjust-process-window-size
              :around #'ghostel-debug--log-resize)
  (when (fboundp 'ghostel--enable-vt-log)
    (ghostel--enable-vt-log))
  (message "ghostel-debug: logging started, check *ghostel-debug* buffer"))

(defun ghostel-debug-stop ()
  "Stop logging."
  (interactive)
  (advice-remove 'ghostel--filter #'ghostel-debug--log-filter)
  (advice-remove 'ghostel--send-string #'ghostel-debug--log-send)
  (advice-remove 'ghostel--send-encoded #'ghostel-debug--log-encoded)
  (advice-remove 'ghostel--delayed-redraw #'ghostel-debug--log-redraw)
  (advice-remove 'ghostel--window-adjust-process-window-size
                 #'ghostel-debug--log-resize)
  (when (fboundp 'ghostel--disable-vt-log)
    (ghostel--disable-vt-log))
  ;; Logging is done — flip the buffer to read-only so the captured log
  ;; can't be edited by accident.  `ghostel-debug-start' resets the mode
  ;; before erasing.
  (when (buffer-live-p ghostel-debug--log-buffer)
    (with-current-buffer ghostel-debug--log-buffer
      (special-mode)))
  (message "ghostel-debug: logging stopped"))

(defun ghostel--debug-log-vt (level scope message)
  "Log a libghostty-vt internal message.
LEVEL is the severity (error/warning/info/debug).
SCOPE is the subsystem name.  MESSAGE is the log text.
Called from the native module's log callback."
  (when ghostel-debug--log-buffer
    (with-current-buffer ghostel-debug--log-buffer
      (goto-char (point-max))
      (insert (format "[%s] VT [%s](%s): %s\n"
                      (format-time-string "%T.%3N")
                      level scope message)))))

(defun ghostel-debug--log-filter (_proc output)
  "Log process filter call with OUTPUT length and preview.
_PROC is ignored."
  (when ghostel-debug--log-buffer
    (with-current-buffer ghostel-debug--log-buffer
      (goto-char (point-max))
      (insert (format "[%s] FILTER: %d bytes: %S\n"
                      (format-time-string "%T.%3N")
                      (length output)
                      (if (> (length output) 80)
                          (concat (substring output 0 80) "...")
                        output))))))

(defun ghostel-debug--log-send (key)
  "Log KEY sent to terminal."
  (when ghostel-debug--log-buffer
    (with-current-buffer ghostel-debug--log-buffer
      (goto-char (point-max))
      (insert (format "[%s] SEND-KEY: %S (bytes: %S)\n"
                      (format-time-string "%T.%3N")
                      key
                      (mapcar #'identity key))))))

(defun ghostel-debug--log-encoded (key-name mods &optional utf8)
  "Log encoded key event with KEY-NAME, MODS and optional UTF8."
  (when ghostel-debug--log-buffer
    (with-current-buffer ghostel-debug--log-buffer
      (goto-char (point-max))
      (insert (format "[%s] SEND-ENCODED: key=%S mods=%S utf8=%S\n"
                      (format-time-string "%T.%3N")
                      key-name mods utf8)))))

(defun ghostel-debug--snapshot (buffer)
  "Return a plist of redraw-relevant state for BUFFER, or nil.
Captures DEC 2026, force flag, buffer size, trailing-byte flag,
point, `ghostel--term-rows', `ghostel--last-anchor-position',
computed viewport-start, and per-window ws/we/wp/body-height."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let* ((pm (point-max))
             (cb (and (> pm 1) (char-before pm)))
             (wins (get-buffer-window-list buffer nil t)))
        (list :sync (and ghostel--term
                         (ghostel--mode-enabled ghostel--term 2026))
              :force ghostel--force-next-redraw
              :snap ghostel--snap-requested
              :buf-size (buffer-size)
              :trailing-nl (eq cb ?\n)
              :point (point)
              :term-rows ghostel--term-rows
              :anchor-pos ghostel--last-anchor-position
              :vs (ghostel--viewport-start)
              :wins (mapcar (lambda (w)
                              (list :w w
                                    :ws (window-start w)
                                    :we (window-end w t)
                                    :wp (window-point w)
                                    :body (window-body-height w)))
                            wins))))))

(defun ghostel-debug--fmt-wins (wins)
  "Format per-window entries WINS for the redraw log line."
  (mapconcat
   (lambda (w) (format "ws=%d we=%d wp=%d body=%d"
                       (plist-get w :ws) (plist-get w :we)
                       (plist-get w :wp) (plist-get w :body)))
   wins " | "))

(defun ghostel-debug--log-redraw (orig-fn buffer)
  "Log redraw decisions: skip vs execute, DEC 2026 state, timing.
ORIG-FN is `ghostel--delayed-redraw', BUFFER is the target buffer."
  (when ghostel-debug--log-buffer
    (let ((before (ghostel-debug--snapshot buffer))
          (t0 (current-time)))
      (funcall orig-fn buffer)
      (let* ((elapsed (* 1000 (float-time (time-subtract (current-time) t0))))
             (after (ghostel-debug--snapshot buffer)))
        (with-current-buffer ghostel-debug--log-buffer
          (goto-char (point-max))
          (if (and (plist-get before :sync) (not (plist-get before :force)))
              (insert (format "[%s] REDRAW: SKIPPED (DEC2026 active, force=nil)\n"
                              (format-time-string "%T.%3N")))
            (insert (format "[%s] REDRAW: %.1fms force=%s→%s snap=%s→%s dec2026=%s buf=%d→%d trailNL=%s→%s pt=%d→%d rows=%s vs=%s→%s anchor=%s→%s\n"
                            (format-time-string "%T.%3N")
                            elapsed
                            (plist-get before :force) (plist-get after :force)
                            (plist-get before :snap) (plist-get after :snap)
                            (plist-get before :sync)
                            (plist-get before :buf-size) (plist-get after :buf-size)
                            (plist-get before :trailing-nl) (plist-get after :trailing-nl)
                            (plist-get before :point) (plist-get after :point)
                            (plist-get after :term-rows)
                            (plist-get before :vs) (plist-get after :vs)
                            (plist-get before :anchor-pos) (plist-get after :anchor-pos)))
            (insert (format "           wins-before: %s\n"
                            (ghostel-debug--fmt-wins (plist-get before :wins))))
            (insert (format "           wins-after:  %s\n"
                            (ghostel-debug--fmt-wins (plist-get after :wins))))))))))

(defun ghostel-debug--log-resize (orig-fn process windows)
  "Log resize events with old/new dimensions and timing.
ORIG-FN is `ghostel--window-adjust-process-window-size'.
PROCESS and WINDOWS are passed through."
  (let* ((old-rows (when (buffer-live-p (process-buffer process))
                     (buffer-local-value 'ghostel--term-rows (process-buffer process))))
         (t0 (current-time))
         (size (funcall orig-fn process windows))
         (elapsed (* 1000 (float-time (time-subtract (current-time) t0)))))
    (when ghostel-debug--log-buffer
      (with-current-buffer ghostel-debug--log-buffer
        (goto-char (point-max))
        (insert (format "[%s] RESIZE: %sx%s → %sx%s (%.1fms)\n"
                        (format-time-string "%T.%3N")
                        (and old-rows (cdr size)) old-rows
                        (car size) (cdr size)
                        elapsed))))
    size))


;;; Typing latency measurement

(defvar ghostel-debug--latency-log nil
  "List of (SEND-TIME ECHO-TIME RENDER-TIME) entries for latency analysis.")

(defvar ghostel-debug--latency-send-time nil
  "High-resolution time of the last send-key during latency measurement.")

(defvar ghostel-debug--latency-active nil
  "Non-nil when typing latency measurement is active.")

(defun ghostel-debug-typing-latency (&optional count)
  "Measure per-keystroke typing latency.
Instruments the send→echo→render pipeline with high-resolution
timestamps and logs a summary after COUNT keystrokes (default 20).
Call this interactively in a ghostel buffer, then type normally.
Results are displayed in *ghostel-debug* when complete.

The latency breakdown shows:
- PTY latency: time from send-key to process filter receiving echo
- Render latency: time from echo receipt to redraw completion
- Total latency: end-to-end from keystroke to visible update"
  (interactive "p")
  (unless (derived-mode-p 'ghostel-mode)
    (user-error "Must be called from a ghostel buffer"))
  (let ((n (or count 20)))
    (setq ghostel-debug--latency-log nil)
    (setq ghostel-debug--latency-active n)
    (setq ghostel-debug--log-buffer (get-buffer-create "*ghostel-debug*"))
    (with-current-buffer ghostel-debug--log-buffer
      ;; Reset `special-mode' (set by `ghostel-debug-info') so subsequent
      ;; latency log inserts don't trip `buffer-read-only'.
      (fundamental-mode)
      (setq buffer-read-only nil)
      (erase-buffer)
      (insert "=== Ghostel Typing Latency Measurement ===\n")
      (insert (format "Type %d characters to collect measurements...\n\n" n)))
    (advice-add 'ghostel--send-string :before #'ghostel-debug--latency-on-send)
    (advice-add 'ghostel--filter :before #'ghostel-debug--latency-on-echo)
    (advice-add 'ghostel--delayed-redraw :after #'ghostel-debug--latency-on-render)
    (message "ghostel-debug: type %d characters to measure latency" n)))

(defun ghostel-debug--latency-on-send (_key)
  "Record send time for latency measurement."
  (when ghostel-debug--latency-active
    (setq ghostel-debug--latency-send-time (current-time))))

(defun ghostel-debug--latency-on-echo (_proc _output)
  "Record echo-receipt time for latency measurement."
  (when (and ghostel-debug--latency-active ghostel-debug--latency-send-time)
    ;; Store echo time on the send-time entry (will be completed on render)
    (let ((echo-time (current-time)))
      ;; Push partial entry: (send-time echo-time nil)
      (push (list ghostel-debug--latency-send-time echo-time nil)
            ghostel-debug--latency-log)
      (setq ghostel-debug--latency-send-time nil))))

(defun ghostel-debug--latency-on-render (_buffer)
  "Record render-completion time and finalize latency entry."
  (when ghostel-debug--latency-active
    (let ((render-time (current-time)))
      ;; Complete the most recent entry that has no render time
      (catch 'done
        (dolist (entry ghostel-debug--latency-log)
          (when (and (nth 1 entry) (null (nth 2 entry)))
            (setf (nth 2 entry) render-time)
            (cl-decf ghostel-debug--latency-active)
            (when (<= ghostel-debug--latency-active 0)
              (ghostel-debug--latency-report))
            (throw 'done nil)))))))

(defun ghostel-debug--latency-report ()
  "Generate and display the latency report."
  (advice-remove 'ghostel--send-string #'ghostel-debug--latency-on-send)
  (advice-remove 'ghostel--filter #'ghostel-debug--latency-on-echo)
  (advice-remove 'ghostel--delayed-redraw #'ghostel-debug--latency-on-render)
  (setq ghostel-debug--latency-active nil)
  (let* ((complete (cl-remove-if-not (lambda (e) (nth 2 e))
                                     ghostel-debug--latency-log))
         (pty-times (mapcar (lambda (e)
                              (* 1000 (float-time
                                       (time-subtract (nth 1 e) (nth 0 e)))))
                            complete))
         (render-times (mapcar (lambda (e)
                                 (* 1000 (float-time
                                          (time-subtract (nth 2 e) (nth 1 e)))))
                               complete))
         (total-times (mapcar (lambda (e)
                                (* 1000 (float-time
                                         (time-subtract (nth 2 e) (nth 0 e)))))
                              complete)))
    (when ghostel-debug--log-buffer
      (with-current-buffer ghostel-debug--log-buffer
        (goto-char (point-max))
        (insert (format "\n=== Results (%d samples) ===\n\n" (length complete)))
        (insert (format "%-20s %8s %8s %8s %8s\n"
                        "Phase" "Min" "Median" "P99" "Max"))
        (insert (make-string 56 ?-) "\n")
        (dolist (row `(("PTY latency" ,pty-times)
                       ("Render latency" ,render-times)
                       ("Total (end-to-end)" ,total-times)))
          (let* ((name (car row))
                 (vals (sort (cadr row) #'<))
                 (n (length vals)))
            (when (> n 0)
              (insert (format "%-20s %7.2fms %7.2fms %7.2fms %7.2fms\n"
                              name
                              (car vals)
                              (nth (/ n 2) vals)
                              (nth (min (1- n) (floor (* n 0.99))) vals)
                              (car (last vals)))))))
        (insert "\nPer-keystroke detail:\n")
        (dolist (e (reverse complete))
          (let ((pty (float-time (time-subtract (nth 1 e) (nth 0 e))))
                (rnd (float-time (time-subtract (nth 2 e) (nth 1 e))))
                (tot (float-time (time-subtract (nth 2 e) (nth 0 e)))))
            (insert (format "  pty=%.2fms render=%.2fms total=%.2fms\n"
                            (* 1000 pty) (* 1000 rnd) (* 1000 tot)))))
        (insert "\n")
        ;; Measurement is done — flip to read-only.
        (special-mode)))
    (message "ghostel-debug: latency report ready in *ghostel-debug*")))


;;; Environment diagnostics

;;;###autoload
(defun ghostel-debug-info ()
  "Display diagnostic info about the ghostel environment.
Collects Emacs version, system info, native module state, frame and
window geometry, terminal state, process info, and any non-default
ghostel settings into *ghostel-debug* for pasting into bug reports."
  (interactive)
  (let ((out (get-buffer-create "*ghostel-debug*"))
        (ghostel-buf (when (derived-mode-p 'ghostel-mode) (current-buffer))))
    (with-current-buffer out
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "=== ghostel-debug-info ===\n\n")
        ;; System
        (insert "--- System ---\n")
        (insert (format "Emacs version:       %s\n" emacs-version))
        (insert (format "System type:         %s\n" system-type))
        (insert (format "System config:       %s\n" system-configuration))
        (insert (format "Window system:       %s\n" (or window-system "terminal")))
        (when (display-graphic-p)
          (insert (format "Display pixel size:  %sx%s\n"
                          (display-pixel-width) (display-pixel-height)))
          (insert (format "Char size:           %dx%d px\n"
                          (frame-char-width) (frame-char-height))))
        (insert (format "Native comp:         %s\n"
                        (if (and (fboundp 'native-comp-available-p)
                                 (native-comp-available-p))
                            "yes" "no")))
        ;; Ghostel
        (insert "\n--- Ghostel ---\n")
        (let* ((lib (locate-library "ghostel"))
               (root (ghostel--resource-root)))
          (insert (format "Package version:     %s\n"
                          (condition-case nil
                              (lm-version (locate-library "ghostel.el" t))
                            (error "Unknown"))))
          (insert (format "Min module version:  %s\n" ghostel--minimum-module-version))
          (insert (format "Library path:        %s\n" (or lib "not found")))
          (insert (format "Resource root:       %s\n" (or root "not found")))
          (let ((mod-loaded (fboundp 'ghostel--module-version)))
            (insert (format "Module loaded:       %s\n" (if mod-loaded "yes" "no")))
            (when mod-loaded
              (let ((mod-ver (ghostel--module-version)))
                (insert (format "Module version:      %s\n" mod-ver))
                (unless (string= mod-ver ghostel--minimum-module-version)
                  (insert (format "  *** VERSION MISMATCH: elisp expects >= %s, module is %s ***\n"
                                  ghostel--minimum-module-version mod-ver)))))
            (when root
              (let ((mod-file (expand-file-name
                               (concat "ghostel-module" module-file-suffix) root)))
                (if (file-exists-p mod-file)
                    (let ((attrs (file-attributes mod-file)))
                      (insert (format "Module file:         %s\n" mod-file))
                      (insert (format "Module size:         %s bytes\n"
                                      (file-attribute-size attrs)))
                      (insert (format "Module modified:     %s\n"
                                      (format-time-string
                                       "%F %T"
                                       (file-attribute-modification-time attrs)))))
                  (insert (format "Module file:         NOT FOUND in %s\n" root)))))))
        ;; Frame
        (insert "\n--- Frame ---\n")
        (let ((frame (or (and ghostel-buf
                              (window-live-p (get-buffer-window ghostel-buf))
                              (window-frame (get-buffer-window ghostel-buf)))
                         (selected-frame))))
          (insert (format "Frame size:          %dx%d (cols x rows)\n"
                          (frame-width frame) (frame-height frame)))
          (when (display-graphic-p frame)
            (insert (format "Frame pixel size:    %dx%d\n"
                            (frame-pixel-width frame) (frame-pixel-height frame))))
          (insert (format "Tab-bar lines:       %s%s\n"
                          (or (frame-parameter frame 'tab-bar-lines) 0)
                          (if (bound-and-true-p tab-bar-mode) " (tab-bar-mode on)" "")))
          (insert (format "Tool-bar lines:      %s%s\n"
                          (or (frame-parameter frame 'tool-bar-lines) 0)
                          (if (bound-and-true-p tool-bar-mode) " (tool-bar-mode on)" "")))
          (insert (format "Menu-bar lines:      %s%s\n"
                          (or (frame-parameter frame 'menu-bar-lines) 0)
                          (if (bound-and-true-p menu-bar-mode) " (menu-bar-mode on)" "")))
          (insert (format "Internal border:     %s px\n"
                          (or (frame-parameter frame 'internal-border-width) 0)))
          (insert (format "Background mode:     %s\n"
                          (frame-parameter frame 'background-mode)))
          (insert (format "Enabled themes:      %s\n"
                          (or custom-enabled-themes "(none)"))))
        ;; Buffer / Process / Window / Terminal — only when in a ghostel buffer.
        ;; Capture buffer-local state into locals first, then insert in `out';
        ;; doing inserts inside `with-current-buffer ghostel-buf' would write
        ;; them to the wrong buffer.
        (if (not ghostel-buf)
            (insert "\n(not in a ghostel buffer — buffer/process/window/terminal sections skipped)\n")
          (let (buf-name maj-mode dir remote modes
                proc cmd shell shell-integ tramp-integ detected
                term term-rows term-cols force pending timer copy
                buf-size buf-lines pt dec2026 alt-scr
                dln-on dln-style)
            (with-current-buffer ghostel-buf
              (setq buf-name (buffer-name)
                    maj-mode major-mode
                    dir default-directory
                    remote (file-remote-p default-directory)
                    modes (cl-loop for m in minor-mode-list
                                   when (and (boundp m) (symbol-value m))
                                   collect (symbol-name m))
                    proc ghostel--process
                    cmd (and proc (process-live-p proc)
                             (mapconcat (lambda (s) (format "%s" s))
                                        (process-command proc) " "))
                    shell ghostel-shell
                    shell-integ ghostel-shell-integration
                    tramp-integ ghostel-tramp-shell-integration
                    detected (ghostel--detect-shell ghostel-shell)
                    term ghostel--term
                    term-rows ghostel--term-rows
                    term-cols ghostel--term-cols
                    force ghostel--force-next-redraw
                    pending (length ghostel--pending-output)
                    timer (and ghostel--redraw-timer t)
                    copy ghostel--copy-mode-active
                    buf-size (buffer-size)
                    buf-lines (count-lines (point-min) (point-max))
                    pt (point)
                    dec2026 (and term (ghostel--mode-enabled term 2026))
                    alt-scr (and term (ghostel--alt-screen-p term))
                    dln-on (bound-and-true-p display-line-numbers-mode)
                    dln-style display-line-numbers))
            (let ((win (get-buffer-window ghostel-buf)))
              ;; Buffer
              (insert "\n--- Buffer ---\n")
              (insert (format "Buffer name:         %s\n" buf-name))
              (insert (format "Major mode:          %s\n" maj-mode))
              (insert (format "Default directory:   %s\n" dir))
              (insert (format "Remote:              %s\n" (or remote "no")))
              (when remote
                (insert (format "TRAMP method:        %s\n"
                                (file-remote-p dir 'method))))
              (insert (format "Active minor modes:  %s\n"
                              (if modes
                                  (mapconcat #'identity (sort modes #'string<) " ")
                                "(none)")))
              ;; Process
              (insert "\n--- Process ---\n")
              (cond
               ((null proc)
                (insert "Process:             nil\n"))
               ((not (process-live-p proc))
                (insert (format "Process:             dead (status: %s)\n"
                                (process-status proc))))
               (t
                (insert (format "PID:                 %s\n" (process-id proc)))
                (insert (format "Status:              %s\n" (process-status proc)))
                (insert (format "Command:             %s\n" cmd))
                (insert (format "TTY:                 %s\n"
                                (or (process-tty-name proc) "(none)")))))
              (insert (format "Configured shell:    %s\n" shell))
              (insert (format "Detected shell type: %s\n" (or detected "(unknown)")))
              (insert (format "Shell integration:   %s\n" shell-integ))
              (when remote
                (insert (format "TRAMP integration:   %s\n" tramp-integ)))
              ;; Window
              (insert "\n--- Window ---\n")
              (if (window-live-p win)
                  (progn
                    (insert (format "Window body:         %dx%d (cols x rows)\n"
                                    (window-body-width win) (window-body-height win)))
                    (insert (format "Max chars per line:  %d\n"
                                    (window-max-chars-per-line win)))
                    (insert (format "Window start:        %d\n" (window-start win)))
                    (insert (format "Window end:          %d\n" (window-end win t)))
                    (let ((fr (window-fringes win)))
                      (insert (format "Fringes:             left=%spx right=%spx outside-margins=%s\n"
                                      (nth 0 fr) (nth 1 fr) (nth 2 fr))))
                    (let ((mg (window-margins win)))
                      (insert (format "Margins:             left=%s right=%s\n"
                                      (or (car mg) 0) (or (cdr mg) 0))))
                    (insert (format "Line numbers:        %s\n"
                                    (if dln-on (format "%s" dln-style) "off")))
                    (insert (format "Buffer windows:      %d\n"
                                    (length (get-buffer-window-list
                                             ghostel-buf nil t)))))
                (insert "Window:              not displayed in current frame\n"))
              ;; Terminal
              (insert "\n--- Terminal ---\n")
              (if term
                  (progn
                    (insert (format "Term size:           %sx%s (cols x rows)\n"
                                    term-cols term-rows))
                    (insert (format "Buffer size:         %d chars, %d lines\n"
                                    buf-size buf-lines))
                    (insert (format "Point:               %d\n" pt))
                    (insert (format "DEC 2026 (sync):     %s\n"
                                    (if dec2026 "ACTIVE" "off")))
                    (insert (format "Alt screen:          %s\n"
                                    (if alt-scr "yes" "no")))
                    (insert (format "Force next redraw:   %s\n" force))
                    (insert (format "Pending output:      %d chunks\n" pending))
                    (insert (format "Redraw timer:        %s\n"
                                    (if timer "pending" "none")))
                    (insert (format "Copy mode:           %s\n"
                                    (if copy "active" "off"))))
                (insert "Term handle:         nil (no terminal)\n")))))
        ;; Non-default ghostel settings
        (insert "\n--- Non-default ghostel settings ---\n")
        (let (changed)
          (mapatoms
           (lambda (sym)
             (when (and (boundp sym)
                        (string-match-p "ghostel" (symbol-name sym))
                        (get sym 'standard-value)
                        ;; Skip minor-mode toggle vars — they show up
                        ;; in the "Active minor modes" list already and
                        ;; aren't user-tunable settings.
                        (not (memq sym minor-mode-list)))
               (let* ((std (get sym 'standard-value))
                      (default (condition-case nil
                                   (eval (car std) t)
                                 (error :eval-error)))
                      (current (symbol-value sym)))
                 (unless (equal current default)
                   (push (list sym current default) changed))))))
          (if (null changed)
              (insert "(all settings at defaults)\n")
            (setq changed (sort changed
                                (lambda (a b)
                                  (string< (symbol-name (car a))
                                           (symbol-name (car b))))))
            (dolist (entry changed)
              (insert (format "%s: %S\n  default: %S\n"
                              (car entry) (nth 1 entry) (nth 2 entry))))))
        (goto-char (point-min)))
      ;; Read-only with `q' to quit (matches *Help*-style buffers).
      ;; `ghostel-debug-start' / `ghostel-debug-typing-latency' reset to
      ;; `fundamental-mode' before they erase, so this doesn't trap them.
      (special-mode))
    (display-buffer out)
    (message "Debug info written to *ghostel-debug*")))

(provide 'ghostel-debug)
;;; ghostel-debug.el ends here
