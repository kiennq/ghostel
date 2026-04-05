;;; ghostel-debug.el --- Diagnostic logging for ghostel -*- lexical-binding: t; -*-

;; Copyright (c) 2026 Daniel Kraus <daniel@kraus.my>

;; Author: Daniel Kraus <daniel@kraus.my>
;; URL: https://github.com/dakra/ghostel
;; Version: 0.2.50
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

(defvar ghostel-debug--log-buffer nil
  "Buffer used for ghostel debug logging.")

(defun ghostel-debug-start ()
  "Start logging ghostel filter calls to *ghostel-debug* buffer."
  (interactive)
  (setq ghostel-debug--log-buffer (get-buffer-create "*ghostel-debug*"))
  (with-current-buffer ghostel-debug--log-buffer
    (erase-buffer)
    (insert "=== Ghostel Debug Log ===\n\n"))
  (advice-add 'ghostel--filter :before #'ghostel-debug--log-filter)
  (advice-add 'ghostel--send-key :before #'ghostel-debug--log-send)
  (advice-add 'ghostel--send-encoded :before #'ghostel-debug--log-encoded)
  (message "ghostel-debug: logging started, check *ghostel-debug* buffer"))

(defun ghostel-debug-stop ()
  "Stop logging."
  (interactive)
  (advice-remove 'ghostel--filter #'ghostel-debug--log-filter)
  (advice-remove 'ghostel--send-key #'ghostel-debug--log-send)
  (advice-remove 'ghostel--send-encoded #'ghostel-debug--log-encoded)
  (message "ghostel-debug: logging stopped"))

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
      (erase-buffer)
      (insert "=== Ghostel Typing Latency Measurement ===\n")
      (insert (format "Type %d characters to collect measurements...\n\n" n)))
    (advice-add 'ghostel--send-key :before #'ghostel-debug--latency-on-send)
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
  (advice-remove 'ghostel--send-key #'ghostel-debug--latency-on-send)
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
        (insert "\n")))
    (message "ghostel-debug: latency report ready in *ghostel-debug*")))

(provide 'ghostel-debug)
;;; ghostel-debug.el ends here
