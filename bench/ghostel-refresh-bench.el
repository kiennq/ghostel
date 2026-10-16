;;; ghostel-refresh-bench.el --- Native background-output benchmark -*- lexical-binding: t; -*-

;;; Commentary:

;; Driven by run-refresh-bench.ps1.  Each trial uses a real native PTY,
;; identical paced output, and the production event filter.  The producer
;; remains alive after its final output so resuming cannot depend on exit
;; handling or another byte arriving.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'ghostel)

(declare-function ghostel--module-version "dyn-loader-module" ())
(declare-function ghostel--write-pty "dyn-loader-module" (term data))

(defconst ghostel-refresh-bench--producer
  (string-join
   '("import os, sys, time"
     "sys.path.insert(0, sys.argv[4])"
     "from pty_setup import set_raw_stdio"
     "set_raw_stdio()"
     "chunks, size, pause = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3])"
     "def wait_command():"
     "    while True:"
     "        ch = os.read(sys.stdin.fileno(), 1)"
     "        if not ch: sys.exit(0)"
     "        if ch in (b'\\r', b'\\n'): return"
     "out = sys.stdout.buffer"
     "out.write(b'\\x1b]2;GHOSTEL_REFRESH_READY\\x07'); out.flush()"
     "wait_command()"
     "data = b'x' * (size - 1) + b'\\r'"
     "for _ in range(chunks):"
     "    out.write(data); out.flush()"
     "    if pause: time.sleep(pause)"
     "out.write(b'\\r\\nGHOSTEL_REFRESH_FINAL\\r\\n\\x1b]2;GHOSTEL_REFRESH_DONE\\x07'); out.flush()"
     "wait_command()")
   "\n")
  "Paced producer with OSC title readiness and completion signals.")

(defun ghostel-refresh-bench--write-json (path value)
  "Write VALUE as JSON to PATH."
  (let ((coding-system-for-write 'utf-8-unix))
    (with-temp-file path
      (insert (json-encode value)))))

(defun ghostel-refresh-bench--wait (predicate description)
  "Wait up to 60 seconds for PREDICATE, otherwise report DESCRIPTION."
  (let ((deadline (+ (float-time) 60)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output nil 0.01))
    (unless (funcall predicate)
      (error "Refresh benchmark timed out: %s" description))))

(defun ghostel-refresh-bench-run ()
  "Run one native-output trial configured through environment variables."
  (let* ((mode (intern (getenv "GHOSTEL_REFRESH_BENCH_MODE")))
         (chunks (string-to-number (getenv "GHOSTEL_REFRESH_BENCH_CHUNKS")))
         (size (string-to-number (getenv "GHOSTEL_REFRESH_BENCH_BYTES")))
         (pause (getenv "GHOSTEL_REFRESH_BENCH_PAUSE"))
         (prefix (getenv "GHOSTEL_REFRESH_BENCH_PREFIX"))
         (python (or (executable-find "python3") (executable-find "python")
                     (error "Python 3 is required")))
         (buffer (generate-new-buffer " *ghostel-refresh-bench*"))
         (other (generate-new-buffer " *ghostel-refresh-bench-other*"))
         (ghostel-use-native-pty t)
         (ghostel-shell-integration nil)
         (ghostel-kill-buffer-on-exit nil)
         (ghostel-buffer-name-function nil)
         (ghostel-detect-password-prompts nil)
         (ghostel-enable-file-detection nil)
         (ghostel-enable-url-detection nil)
         (filter-calls 0)
         (pipe-bytes 0)
         (filter-seconds 0.0)
         (invalidations 0)
         (redraws 0)
         (measuring nil)
         result)
    (unless (memq mode '(active hidden unselected copy))
      (error "Unknown refresh benchmark mode: %S" mode))
    (let ((filter-advice
           (lambda (original pipe output)
             (if (not measuring)
                 (funcall original pipe output)
               (let ((start (float-time)))
                 (cl-incf filter-calls)
                 (cl-incf pipe-bytes (string-bytes output))
                 (unwind-protect
                     (funcall original pipe output)
                   (cl-incf filter-seconds (- (float-time) start)))))))
          (invalidate-advice
           (lambda (&rest _)
             (when measuring (cl-incf invalidations))))
          (redraw-advice
           (lambda (&rest _)
             (when measuring (cl-incf redraws)))))
      (advice-add 'ghostel--events-filter :around filter-advice)
      (advice-add 'ghostel--invalidate :before invalidate-advice)
      (advice-add 'ghostel--redraw-now :before redraw-advice)
      (unwind-protect
          (save-window-excursion
            (delete-other-windows)
            (set-window-buffer (selected-window) buffer)
            (ghostel-exec buffer python
                          (list "-u" "-c" ghostel-refresh-bench--producer
                                (number-to-string chunks)
                                (number-to-string size) pause
                                (expand-file-name "test/fixtures"
                                                  default-directory)))
            (with-current-buffer buffer
              (ghostel-refresh-bench--wait
               (lambda () (equal ghostel-title "GHOSTEL_REFRESH_READY"))
               "producer readiness")
              (pcase mode
                ('hidden (set-window-buffer (selected-window) other))
                ('unselected
                 (let ((background (selected-window)))
                   (select-window (split-window background nil 'below))
                   (set-window-buffer (selected-window) other)))
                ('copy (ghostel-copy-mode)))
              ;; Batch mode does not automatically redisplay window changes.
              ;; Run the same production transition handlers explicitly.
              (ghostel--focus-change)
              (when (memq mode '(active copy))
                (ghostel--pre-redisplay (selected-window)))
              (accept-process-output nil 0.1)
              (garbage-collect)
              (ghostel-refresh-bench--write-json
               (concat prefix ".ready")
               `((pid . ,(emacs-pid))
                 (module_version . ,(ghostel--module-version))))
              (ghostel-refresh-bench--wait
               (lambda () (file-exists-p (concat prefix ".go")))
               "measurement start")
              (let ((start (float-time))
                    (gc-start gcs-done)
                    (gc-time-start gc-elapsed))
                (setq measuring t)
                (ghostel--write-pty ghostel--term "run\r")
                (ghostel-refresh-bench--wait
                 (lambda () (equal ghostel-title "GHOSTEL_REFRESH_DONE"))
                 "OSC completion callback while paused")
                (setq measuring nil)
                (setq result
                      `((mode . ,(symbol-name mode))
                        (bytes . ,(* chunks size))
                        (wall_seconds . ,(- (float-time) start))
                        (filter_calls . ,filter-calls)
                        (event_pipe_bytes . ,pipe-bytes)
                        (filter_wall_ms . ,(* 1000 filter-seconds))
                        (invalidations . ,invalidations)
                        (redraw_calls . ,redraws)
                        (gc_count . ,(- gcs-done gc-start))
                        (gc_seconds . ,(- gc-elapsed gc-time-start)))))
              ;; The external driver stops its main-thread CPU sample here.
              (ghostel-refresh-bench--write-json (concat prefix ".timed") result)
              (ghostel-refresh-bench--wait
               (lambda () (file-exists-p (concat prefix ".sampled")))
               "main-thread CPU sample")
              (let ((start (float-time)))
                (set-window-buffer (selected-window) buffer)
                (when (eq mode 'copy) (ghostel-readonly-exit))
                (ghostel--focus-change)
                (ghostel--pre-redisplay (selected-window))
                (ghostel-refresh-bench--wait
                 (lambda () (string-match-p "GHOSTEL_REFRESH_FINAL"
                                            (buffer-string)))
                 "quiet-child catch-up redraw")
                (push (cons 'catchup_ms (* 1000 (- (float-time) start))) result)
                (push (cons 'catchup_ok t) result))
              (ghostel-refresh-bench--write-json (concat prefix ".json") result)
              (ghostel--write-pty ghostel--term "quit\r")))
        (advice-remove 'ghostel--events-filter filter-advice)
        (advice-remove 'ghostel--invalidate invalidate-advice)
        (advice-remove 'ghostel--redraw-now redraw-advice)
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (when (buffer-live-p other) (kill-buffer other))))))

(provide 'ghostel-refresh-bench)
;;; ghostel-refresh-bench.el ends here
