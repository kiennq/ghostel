;;; ghostel-bench.el --- Performance benchmarks for ghostel -*- lexical-binding: t; -*-

;;; Commentary:

;; Compare terminal emulator performance: ghostel (incremental & full
;; redraw), vterm, eat, and Emacs built-in term.
;;
;; The primary benchmark spawns a real `cat' process through each
;; terminal's PTY and measures wall-clock time — this matches what
;; users actually experience.  Synthetic micro-benchmarks follow for
;; isolating bottlenecks.
;;
;; Run via:  bench/run-bench.sh          (recommended)
;;       or: emacs --batch -Q -L . -L ../vterm -L ../eat \
;;             -l bench/ghostel-bench.el \
;;             --eval '(ghostel-bench-run-all)'

;;; Code:

(require 'cl-lib)

;; ---------------------------------------------------------------------------
;; Configuration
;; ---------------------------------------------------------------------------

(defvar ghostel-bench-data-size (* 1024 1024)
  "Size of test data in bytes (default 1 MB).")

(defvar ghostel-bench-iterations 3
  "Number of iterations per benchmark.")

(defvar ghostel-bench-terminal-sizes '((24 . 80) (40 . 120))
  "List of (ROWS . COLS) to benchmark.")

(defvar ghostel-bench-scrollback 1000
  "Scrollback lines for terminal creation.")

(defvar ghostel-bench-include-vterm t
  "When non-nil, include vterm in benchmarks.")

(defvar ghostel-bench-include-eat t
  "When non-nil, include eat in benchmarks.")

(defvar ghostel-bench-include-term t
  "When non-nil, include Emacs built-in term in benchmarks.
Always available since term is built into Emacs.")

(defvar ghostel-bench-chunk-size 4096
  "Chunk size for streaming benchmarks.")

;; ---------------------------------------------------------------------------
;; Results accumulator
;; ---------------------------------------------------------------------------

(defvar ghostel-bench--results nil
  "List of result plists from benchmark runs.")

;; ---------------------------------------------------------------------------
;; Data generators
;; ---------------------------------------------------------------------------

(defun ghostel-bench--gen-plain-ascii (size)
  "Generate SIZE bytes of printable ASCII with CRLF every 80 chars."
  (let* ((line (concat (make-string 78 ?A) "\r\n"))
         (line-len (length line))
         (repeats (/ size line-len))
         (parts (make-list repeats line)))
    (apply #'concat parts)))

(defun ghostel-bench--gen-sgr-styled (size)
  "Generate ~SIZE bytes with SGR color escapes every ~10 chars."
  (let ((parts nil)
        (total 0))
    (while (< total size)
      (let* ((color (% (/ total 10) 256))
             (esc (format "\e[38;5;%dm" color))
             (text "abcdefghij")
             (chunk (concat esc text)))
        (push chunk parts)
        (setq total (+ total (length chunk)))))
    (let ((result (apply #'concat (nreverse parts))))
      (substring result 0 (min (length result) size)))))

(defun ghostel-bench--gen-unicode (size)
  "Generate ~SIZE bytes of CJK UTF-8 text as a multibyte string."
  (let* ((chars-needed (/ size 3))
         (line-chars 26)
         (lines (/ chars-needed line-chars))
         (parts nil))
    (dotimes (l lines)
      (dotimes (c line-chars)
        (push (string (+ #x4e00 (% (+ (* l 7) c) 256))) parts))
      (push "\r\n" parts))
    (apply #'concat (nreverse parts))))

(defun ghostel-bench--gen-scroll-lines (size cols)
  "Generate ~SIZE bytes of COLS-wide short lines with CRLF."
  (let* ((text-width (max 10 (min 40 (- cols 2))))
         (line (concat (make-string text-width ?#) "\r\n"))
         (line-len (length line))
         (repeats (/ size line-len))
         (parts (make-list repeats line)))
    (apply #'concat parts)))

(defun ghostel-bench--gen-urls-and-paths (size)
  "Generate ~SIZE bytes of output containing URLs and file:line refs.
Simulates compiler output or build logs with linkifiable content."
  (let ((lines '("/usr/src/app/main.c:42: error: undeclared identifier\r\n"
                 "  at Object.<anonymous> (/home/user/project/index.js:17:5)\r\n"
                 "See https://example.com/docs/errors/E0042 for details\r\n"
                 "PASS ./tests/test_utils.py:88 test_parse_url\r\n"
                 "warning: unused variable at ./src/render.zig:156:13\r\n"
                 "Download: https://cdn.example.org/releases/v2.1.0/pkg.tar.gz\r\n"
                 "  File \"/opt/lib/python3/site.py\", line 73, in main\r\n"
                 "More info: https://github.com/user/repo/issues/42\r\n"))
        (parts nil)
        (total 0))
    (while (< total size)
      (let ((line (nth (% (/ total 60) (length lines)) lines)))
        (push line parts)
        (setq total (+ total (length line)))))
    (apply #'concat (nreverse parts))))

(defun ghostel-bench--gen-tui-frame (rows cols)
  "Generate a single TUI-style frame: clear + fill ROWS x COLS."
  (let ((parts (list "\e[2J\e[H")))
    (dotimes (r rows)
      (push (format "\e[%d;1H" (1+ r)) parts)
      (push (format "\e[%sm" (if (cl-evenp r) "44" "42")) parts)
      (push (make-string cols (if (cl-evenp r) ?- ?=)) parts))
    (push "\e[0m" parts)
    (apply #'concat (nreverse parts))))

;; ---------------------------------------------------------------------------
;; Data encoding helper
;; ---------------------------------------------------------------------------

(defun ghostel-bench--encode-for-backend (data backend)
  "Encode DATA for BACKEND.
Native backends (ghostel, vterm) and term need unibyte strings.
Eat works with multibyte strings directly."
  (if (eq backend 'eat)
      (if (multibyte-string-p data) data
        (decode-coding-string data 'utf-8))
    (if (multibyte-string-p data)
        (encode-coding-string data 'utf-8)
      data)))

;; ---------------------------------------------------------------------------
;; Timing harness
;; ---------------------------------------------------------------------------

(defun ghostel-bench--measure (name data-size iterations body-fn)
  "Run BODY-FN ITERATIONS times, record results under NAME.
DATA-SIZE is the byte count processed per iteration (for MB/s).
Automatically increases iterations if the operation is too fast
for reliable measurement."
  (garbage-collect)
  (funcall body-fn)  ; warm up
  (garbage-collect)
  (let ((actual-iters iterations))
    ;; Auto-scale fast operations
    (let ((trial-start (float-time)))
      (dotimes (_ (min 3 iterations))
        (funcall body-fn))
      (let ((trial-time (- (float-time) trial-start)))
        (when (< trial-time 0.01)
          (setq actual-iters (max iterations
                                  (* 10 (ceiling (/ 0.5 (max trial-time 1e-6)))))))))
    (garbage-collect)
    (let ((start (float-time)))
      (dotimes (_ actual-iters)
        (funcall body-fn))
      (let* ((elapsed (- (float-time) start))
             (per-iter (/ elapsed actual-iters))
             (throughput (if (> elapsed 0)
                             (/ (* data-size actual-iters) elapsed (expt 1024.0 2))
                           0.0))
             (result (list :name name
                           :iterations actual-iters
                           :total-time elapsed
                           :per-iter-ms (* per-iter 1000.0)
                           :data-size data-size
                           :throughput-mbs throughput)))
        (push result ghostel-bench--results)
        (message "  %-50s %5d  %8.3f  %10.2f  %8.1f"
                 name actual-iters elapsed (* per-iter 1000.0) throughput)
        result))))

;; ---------------------------------------------------------------------------
;; Terminal creation helpers
;; ---------------------------------------------------------------------------

(defun ghostel-bench--make-ghostel (rows cols)
  "Create a ghostel terminal for benchmarking."
  (ghostel--new rows cols ghostel-bench-scrollback))

(defun ghostel-bench--make-vterm (rows cols)
  "Create a vterm terminal for benchmarking."
  (vterm--new rows cols ghostel-bench-scrollback nil nil nil nil nil))

(defun ghostel-bench--make-eat (rows cols)
  "Create an eat terminal at point in current buffer for benchmarking."
  (let ((term (eat-term-make (current-buffer) (point))))
    (eat-term-resize term cols rows)
    (eat-term-set-parameter term 'input-function (lambda (_term _str)))
    term))

(defun ghostel-bench--make-term (rows cols)
  "Set up current buffer for term-mode benchmarking.
Returns a dummy `cat' process for use with `term-emulate-terminal'.
The caller must call `delete-process' when done."
  (term-mode)
  (setq term-width cols)
  (setq term-height rows)
  (setq term-buffer-maximum-size ghostel-bench-scrollback)
  (let ((proc (start-process "term-bench" (current-buffer) "cat")))
    (set-process-query-on-exit-flag proc nil)
    proc))

;; =========================================================================
;; SECTION 1: PTY benchmark — the real-world test
;; =========================================================================

(defun ghostel-bench--write-data-file (gen-fn)
  "Write data from GEN-FN to a temp file, return path."
  (let ((file (make-temp-file "ghostel-bench-" nil ".bin")))
    (with-temp-file file
      (set-buffer-multibyte nil)
      (insert (funcall gen-fn ghostel-bench-data-size)))
    file))

(defun ghostel-bench--pty-ghostel (data-file full-redraw &optional no-detect)
  "Benchmark ghostel processing `cat DATA-FILE' through a real PTY.
FULL-REDRAW controls `ghostel-full-redraw'.
When NO-DETECT is non-nil, disable URL and file detection."
  (with-temp-buffer
    (let* ((rows 24) (cols 80)
           (term (ghostel-bench--make-ghostel rows cols))
           (ghostel-enable-url-detection (not no-detect))
           (ghostel-enable-file-detection (not no-detect))
           (inhibit-read-only t)
           (redraw-timer nil)
           (pending nil)
           (done nil)
           ;; Wire up the same filter/timer loop as real ghostel-mode,
           ;; batching writes to reduce per-call VT parser overhead.
           (proc (make-process
                  :name "ghostel-bench"
                  :buffer (current-buffer)
                  :command (list "cat" (expand-file-name data-file))
                  :connection-type 'pipe
                  :coding 'binary
                  :noquery t
                  :filter (lambda (_proc output)
                            (push output pending)
                            (unless redraw-timer
                              (setq redraw-timer
                                    (run-with-timer
                                     0.033 nil
                                     (lambda ()
                                       (setq redraw-timer nil)
                                       (let ((inhibit-read-only t))
                                         (when pending
                                           (ghostel--write-input
                                            term
                                            (apply #'concat (nreverse pending)))
                                           (setq pending nil))
                                         (ghostel--redraw term full-redraw)))))))
                  :sentinel (lambda (_proc _event)
                              (setq done t)))))
      (set-process-window-size proc rows cols)
      ;; Run Emacs event loop until process exits
      (while (not done)
        (accept-process-output proc 30))
      ;; Flush any pending output and redraw
      (when redraw-timer (cancel-timer redraw-timer))
      (when pending
        (ghostel--write-input term (apply #'concat (nreverse pending)))
        (setq pending nil))
      (ghostel--redraw term full-redraw))))

(defun ghostel-bench--pty-vterm (data-file)
  "Benchmark vterm processing `cat DATA-FILE' through a real PTY."
  (with-temp-buffer
    (let* ((rows 24) (cols 80)
           (term (ghostel-bench--make-vterm rows cols))
           (redraw-timer nil)
           (done nil)
           (proc (make-process
                  :name "vterm-bench"
                  :buffer (current-buffer)
                  :command (list "cat" (expand-file-name data-file))
                  :connection-type 'pipe
                  :coding 'binary
                  :noquery t
                  :filter (lambda (_proc output)
                            (vterm--write-input term output)
                            (unless redraw-timer
                              (setq redraw-timer
                                    (run-with-timer
                                     0.033 nil
                                     (lambda ()
                                       (setq redraw-timer nil)
                                       (vterm--redraw term))))))
                  :sentinel (lambda (_proc _event)
                              (setq done t)))))
      (set-process-window-size proc rows cols)
      (while (not done)
        (accept-process-output proc 30))
      (when redraw-timer (cancel-timer redraw-timer))
      (vterm--redraw term))))

(defun ghostel-bench--pty-eat (data-file)
  "Benchmark eat processing `cat DATA-FILE' through a real PTY."
  (with-temp-buffer
    (let* ((rows 24) (cols 80)
           (term (ghostel-bench--make-eat rows cols))
           (inhibit-read-only t)
           (redraw-timer nil)
           (done nil)
           (proc (make-process
                  :name "eat-bench"
                  :buffer (current-buffer)
                  :command (list "cat" (expand-file-name data-file))
                  :connection-type 'pipe
                  :coding 'binary
                  :noquery t
                  :filter (lambda (_proc output)
                            (let ((inhibit-read-only t))
                              (eat-term-process-output
                               term
                               (decode-coding-string output 'utf-8)))
                            (unless redraw-timer
                              (setq redraw-timer
                                    (run-with-timer
                                     0.033 nil
                                     (lambda ()
                                       (setq redraw-timer nil)
                                       (let ((inhibit-read-only t))
                                         (eat-term-redisplay term)))))))
                  :sentinel (lambda (_proc _event)
                              (setq done t)))))
      (set-process-window-size proc rows cols)
      (while (not done)
        (accept-process-output proc 30))
      (when redraw-timer (cancel-timer redraw-timer))
      (eat-term-redisplay term)
      (eat-term-delete term))))

(defun ghostel-bench--pty-term (data-file)
  "Benchmark Emacs built-in term processing `cat DATA-FILE' through a pipe.
Uses `term-emulate-terminal' directly as the process filter, which is
how real `M-x term' works — no timer batching since term does parse
and render in a single call."
  (with-temp-buffer
    (term-mode)
    (setq term-width 80 term-height 24)
    (setq term-buffer-maximum-size ghostel-bench-scrollback)
    (let* ((inhibit-read-only t)
           (done nil)
           (proc (make-process
                  :name "term-bench"
                  :buffer (current-buffer)
                  :command (list "cat" (expand-file-name data-file))
                  :connection-type 'pipe
                  :coding 'binary
                  :noquery t
                  :filter #'term-emulate-terminal
                  :sentinel (lambda (_proc _event)
                              (setq done t)))))
      (set-process-window-size proc 24 80)
      (while (not done)
        (accept-process-output proc 30)))))

(defun ghostel-bench--run-pty-scenarios ()
  "Run real PTY benchmarks — the most representative test."
  (message "\n--- Real-World PTY Benchmark (cat %s through process pipe) ---"
           (ghostel-bench--human-size ghostel-bench-data-size))
  (message "  Uses the same filter + timer redraw loop as actual terminal usage.")
  (message "  %-50s %5s  %8s  %10s  %8s" "SCENARIO" "ITERS" "TOTAL(s)" "ITER(ms)" "MB/s")
  (message "  %s" (make-string 90 ?-))
  ;; --- Plain ASCII data ---
  (let ((data-file (ghostel-bench--write-data-file
                    #'ghostel-bench--gen-plain-ascii)))
    (unwind-protect
        (progn
          (message "  [plain ASCII data]")
          ;; ghostel incremental
          (ghostel-bench--measure
           "pty/plain/ghostel-incr" ghostel-bench-data-size ghostel-bench-iterations
           (lambda () (ghostel-bench--pty-ghostel data-file nil)))
          ;; ghostel full
          (ghostel-bench--measure
           "pty/plain/ghostel-full" ghostel-bench-data-size ghostel-bench-iterations
           (lambda () (ghostel-bench--pty-ghostel data-file t)))
          ;; ghostel default, no URL/file detection
          (ghostel-bench--measure
           "pty/plain/ghostel-nodetect" ghostel-bench-data-size ghostel-bench-iterations
           (lambda () (ghostel-bench--pty-ghostel data-file ghostel-full-redraw t)))
          ;; vterm
          (when ghostel-bench-include-vterm
            (ghostel-bench--measure
             "pty/plain/vterm" ghostel-bench-data-size ghostel-bench-iterations
             (lambda () (ghostel-bench--pty-vterm data-file))))
          ;; eat
          (when ghostel-bench-include-eat
            (ghostel-bench--measure
             "pty/plain/eat" ghostel-bench-data-size ghostel-bench-iterations
             (lambda () (ghostel-bench--pty-eat data-file))))
          ;; term
          (when ghostel-bench-include-term
            (ghostel-bench--measure
             "pty/plain/term" ghostel-bench-data-size ghostel-bench-iterations
             (lambda () (ghostel-bench--pty-term data-file)))))
      (delete-file data-file)))
  ;; --- URL/path-heavy data ---
  (let ((data-file (ghostel-bench--write-data-file
                    #'ghostel-bench--gen-urls-and-paths)))
    (unwind-protect
        (progn
          (message "  [URL & file-path heavy data]")
          ;; ghostel default (detection on)
          (ghostel-bench--measure
           "pty/urls/ghostel" ghostel-bench-data-size ghostel-bench-iterations
           (lambda () (ghostel-bench--pty-ghostel data-file ghostel-full-redraw)))
          ;; ghostel no detection
          (ghostel-bench--measure
           "pty/urls/ghostel-nodetect" ghostel-bench-data-size ghostel-bench-iterations
           (lambda () (ghostel-bench--pty-ghostel data-file ghostel-full-redraw t)))
          ;; vterm (baseline)
          (when ghostel-bench-include-vterm
            (ghostel-bench--measure
             "pty/urls/vterm" ghostel-bench-data-size ghostel-bench-iterations
             (lambda () (ghostel-bench--pty-vterm data-file))))
          ;; eat (baseline)
          (when ghostel-bench-include-eat
            (ghostel-bench--measure
             "pty/urls/eat" ghostel-bench-data-size ghostel-bench-iterations
             (lambda () (ghostel-bench--pty-eat data-file))))
          ;; term (baseline)
          (when ghostel-bench-include-term
            (ghostel-bench--measure
             "pty/urls/term" ghostel-bench-data-size ghostel-bench-iterations
             (lambda () (ghostel-bench--pty-term data-file)))))
      (delete-file data-file))))

;; =========================================================================
;; SECTION 2: Streaming benchmark — chunked write + periodic redraw
;; =========================================================================

(defun ghostel-bench--run-stream-scenarios ()
  "Run streaming benchmarks (chunked input with periodic redraws).
Simulates how data flows in practice: many small writes to the
terminal engine with periodic redraws, all in a tight loop."
  (message "\n--- Streaming (chunked write + periodic redraw, no PTY) ---")
  (message "  4KB chunks, redraw every 16 chunks (~64KB)")
  (message "  %-50s %5s  %8s  %10s  %8s" "SCENARIO" "ITERS" "TOTAL(s)" "ITER(ms)" "MB/s")
  (message "  %s" (make-string 90 ?-))
  (let* ((raw-data (ghostel-bench--gen-plain-ascii ghostel-bench-data-size))
         (chunk-size ghostel-bench-chunk-size)
         (redraw-every 16))
    ;; ghostel incremental
    (with-temp-buffer
      (let* ((data (ghostel-bench--encode-for-backend raw-data 'ghostel))
             (data-len (length data))
             (term (ghostel-bench--make-ghostel 24 80))
             (inhibit-read-only t))
        (ghostel-bench--measure
         "stream/ghostel-incr" (string-bytes data) ghostel-bench-iterations
         (lambda ()
           (let ((offset 0) (chunk-count 0))
             (while (< offset data-len)
               (let ((end (min (+ offset chunk-size) data-len)))
                 (ghostel--write-input term (substring data offset end))
                 (setq offset end)
                 (cl-incf chunk-count)
                 (when (zerop (% chunk-count redraw-every))
                   (ghostel--redraw term nil)))))))))
    ;; ghostel full
    (with-temp-buffer
      (let* ((data (ghostel-bench--encode-for-backend raw-data 'ghostel))
             (data-len (length data))
             (term (ghostel-bench--make-ghostel 24 80))
             (inhibit-read-only t))
        (ghostel-bench--measure
         "stream/ghostel-full" (string-bytes data) ghostel-bench-iterations
         (lambda ()
           (let ((offset 0) (chunk-count 0))
             (while (< offset data-len)
               (let ((end (min (+ offset chunk-size) data-len)))
                 (ghostel--write-input term (substring data offset end))
                 (setq offset end)
                 (cl-incf chunk-count)
                 (when (zerop (% chunk-count redraw-every))
                   (ghostel--redraw term t)))))))))
    ;; ghostel default, no detection
    (with-temp-buffer
      (let* ((data (ghostel-bench--encode-for-backend raw-data 'ghostel))
             (data-len (length data))
             (term (ghostel-bench--make-ghostel 24 80))
             (ghostel-enable-url-detection nil)
             (ghostel-enable-file-detection nil)
             (inhibit-read-only t))
        (ghostel-bench--measure
         "stream/ghostel-nodetect" (string-bytes data) ghostel-bench-iterations
         (lambda ()
           (let ((offset 0) (chunk-count 0))
             (while (< offset data-len)
               (let ((end (min (+ offset chunk-size) data-len)))
                 (ghostel--write-input term (substring data offset end))
                 (setq offset end)
                 (cl-incf chunk-count)
                 (when (zerop (% chunk-count redraw-every))
                   (ghostel--redraw term ghostel-full-redraw)))))))))
    ;; vterm
    (when ghostel-bench-include-vterm
      (with-temp-buffer
        (let* ((data (ghostel-bench--encode-for-backend raw-data 'vterm))
               (data-len (length data))
               (term (ghostel-bench--make-vterm 24 80)))
          (ghostel-bench--measure
           "stream/vterm" (string-bytes data) ghostel-bench-iterations
           (lambda ()
             (let ((offset 0) (chunk-count 0))
               (while (< offset data-len)
                 (let ((end (min (+ offset chunk-size) data-len)))
                   (vterm--write-input term (substring data offset end))
                   (setq offset end)
                   (cl-incf chunk-count)
                   (when (zerop (% chunk-count redraw-every))
                     (vterm--redraw term))))))))))
    ;; eat
    (when ghostel-bench-include-eat
      (with-temp-buffer
        (let* ((data (ghostel-bench--encode-for-backend raw-data 'eat))
               (data-len (length data))
               (term (ghostel-bench--make-eat 24 80))
               (inhibit-read-only t))
          (ghostel-bench--measure
           "stream/eat" (string-bytes data) ghostel-bench-iterations
           (lambda ()
             (let ((offset 0) (chunk-count 0))
               (while (< offset data-len)
                 (let ((end (min (+ offset chunk-size) data-len)))
                   (eat-term-process-output term (substring data offset end))
                   (setq offset end)
                   (cl-incf chunk-count)
                   (when (zerop (% chunk-count redraw-every))
                     (eat-term-redisplay term)))))))
          (eat-term-delete term))))
    ;; term
    (when ghostel-bench-include-term
      (with-temp-buffer
        (let* ((data (ghostel-bench--encode-for-backend raw-data 'term))
               (data-len (length data))
               (proc (ghostel-bench--make-term 24 80))
               (inhibit-read-only t))
          (ghostel-bench--measure
           "stream/term" (string-bytes data) ghostel-bench-iterations
           (lambda ()
             (let ((offset 0))
               (while (< offset data-len)
                 (let ((end (min (+ offset chunk-size) data-len)))
                   (term-emulate-terminal proc (substring data offset end))
                   (setq offset end))))))
          (delete-process proc))))))

;; =========================================================================
;; SECTION 3: TUI frame benchmark (full-screen rewrites)
;; =========================================================================

(defun ghostel-bench--run-tui-scenarios ()
  "Benchmark TUI-style full-screen rewrites.
Measures how fast each backend can update a full screen of styled
content — relevant for apps like htop, vim, claude-code."
  (message "\n--- TUI Frame Rendering (full-screen rewrites) ---")
  (message "  %-50s %5s  %8s  %10s  %8s" "SCENARIO" "ITERS" "TOTAL(s)" "ITER(ms)" "fps")
  (message "  %s" (make-string 90 ?-))
  (let ((tui-iterations (* ghostel-bench-iterations 20)))
    (dolist (size ghostel-bench-terminal-sizes)
      (let* ((rows (car size))
             (cols (cdr size))
             (raw-frame (ghostel-bench--gen-tui-frame rows cols))
             (label (format "%dx%d" rows cols)))
        ;; ghostel incremental
        (with-temp-buffer
          (let ((frame (ghostel-bench--encode-for-backend raw-frame 'ghostel))
                (term (ghostel-bench--make-ghostel rows cols))
                (inhibit-read-only t))
            (let ((result
                   (ghostel-bench--measure
                    (format "tui-frame/ghostel-incr/%s" label)
                    (string-bytes frame) tui-iterations
                    (lambda ()
                      (ghostel--write-input term frame)
                      (ghostel--redraw term nil)))))
              (message "    ^ %.0f fps" (/ 1000.0 (plist-get result :per-iter-ms))))))
        ;; ghostel full
        (with-temp-buffer
          (let ((frame (ghostel-bench--encode-for-backend raw-frame 'ghostel))
                (term (ghostel-bench--make-ghostel rows cols))
                (inhibit-read-only t))
            (let ((result
                   (ghostel-bench--measure
                    (format "tui-frame/ghostel-full/%s" label)
                    (string-bytes frame) tui-iterations
                    (lambda ()
                      (ghostel--write-input term frame)
                      (ghostel--redraw term t)))))
              (message "    ^ %.0f fps" (/ 1000.0 (plist-get result :per-iter-ms))))))
        ;; vterm
        (when ghostel-bench-include-vterm
          (with-temp-buffer
            (let ((frame (ghostel-bench--encode-for-backend raw-frame 'vterm))
                  (term (ghostel-bench--make-vterm rows cols)))
              (let ((result
                     (ghostel-bench--measure
                      (format "tui-frame/vterm/%s" label)
                      (string-bytes frame) tui-iterations
                      (lambda ()
                        (vterm--write-input term frame)
                        (vterm--redraw term)))))
                (message "    ^ %.0f fps" (/ 1000.0 (plist-get result :per-iter-ms)))))))
        ;; eat
        (when ghostel-bench-include-eat
          (with-temp-buffer
            (let ((frame (ghostel-bench--encode-for-backend raw-frame 'eat))
                  (term (ghostel-bench--make-eat rows cols))
                  (inhibit-read-only t))
              (let ((result
                     (ghostel-bench--measure
                      (format "tui-frame/eat/%s" label)
                      (string-bytes frame) tui-iterations
                      (lambda ()
                        (eat-term-process-output term frame)
                        (eat-term-redisplay term)))))
                (message "    ^ %.0f fps" (/ 1000.0 (plist-get result :per-iter-ms))))
              (eat-term-delete term))))
        ;; term
        (when ghostel-bench-include-term
          (with-temp-buffer
            (let* ((frame (ghostel-bench--encode-for-backend raw-frame 'term))
                   (proc (ghostel-bench--make-term rows cols))
                   (inhibit-read-only t))
              (let ((result
                     (ghostel-bench--measure
                      (format "tui-frame/term/%s" label)
                      (string-bytes frame) tui-iterations
                      (lambda ()
                        (term-emulate-terminal proc frame)))))
                (message "    ^ %.0f fps" (/ 1000.0 (plist-get result :per-iter-ms))))
              (delete-process proc))))))))

;; =========================================================================
;; SECTION 4: Engine micro-benchmarks (bulk parse/render, single call)
;; =========================================================================

(defun ghostel-bench--run-for-backends (name raw-data rows cols iters render-p)
  "Run benchmark NAME with RAW-DATA on all backends.
ROWS and COLS specify terminal size.  ITERS is iteration count.
When RENDER-P is non-nil, also call redraw after write-input."
  (let ((label (format "%dx%d" rows cols)))
    ;; When rendering, prefix each iteration with a unique line so that
    ;; dirty tracking cannot optimize away the redraw.
    ;; ghostel incremental
    (with-temp-buffer
      (let ((data (ghostel-bench--encode-for-backend raw-data 'ghostel))
            (term (ghostel-bench--make-ghostel rows cols))
            (inhibit-read-only t)
            (counter 0))
        (ghostel-bench--measure
         (format "%s/ghostel-incr/%s" name label)
         (string-bytes data) iters
         (if render-p
             (lambda ()
               (setq counter (1+ counter))
               (ghostel--write-input term (format "\e[H%d\r\n" counter))
               (ghostel--write-input term data)
               (ghostel--redraw term nil))
           (lambda () (ghostel--write-input term data))))))
    ;; ghostel full
    (when render-p
      (with-temp-buffer
        (let ((data (ghostel-bench--encode-for-backend raw-data 'ghostel))
              (term (ghostel-bench--make-ghostel rows cols))
              (inhibit-read-only t)
              (counter 0))
          (ghostel-bench--measure
           (format "%s/ghostel-full/%s" name label)
           (string-bytes data) iters
           (lambda ()
             (setq counter (1+ counter))
             (ghostel--write-input term (format "\e[H%d\r\n" counter))
             (ghostel--write-input term data)
             (ghostel--redraw term t))))))
    ;; vterm
    (when ghostel-bench-include-vterm
      (with-temp-buffer
        (let ((data (ghostel-bench--encode-for-backend raw-data 'vterm))
              (term (ghostel-bench--make-vterm rows cols))
              (counter 0))
          (ghostel-bench--measure
           (format "%s/vterm/%s" name label)
           (string-bytes data) iters
           (if render-p
               (lambda ()
                 (setq counter (1+ counter))
                 (vterm--write-input term (format "\e[H%d\r\n" counter))
                 (vterm--write-input term data)
                 (vterm--redraw term))
             (lambda () (vterm--write-input term data)))))))
    ;; eat
    (when ghostel-bench-include-eat
      (with-temp-buffer
        (let ((data (ghostel-bench--encode-for-backend raw-data 'eat))
              (term (ghostel-bench--make-eat rows cols))
              (inhibit-read-only t)
              (counter 0))
          (ghostel-bench--measure
           (format "%s/eat/%s" name label)
           (string-bytes data) iters
           (if render-p
               (lambda ()
                 (setq counter (1+ counter))
                 (eat-term-process-output
                  term (decode-coding-string
                        (format "\e[H%d\r\n" counter) 'utf-8))
                 (eat-term-process-output term data)
                 (eat-term-redisplay term))
             (lambda () (eat-term-process-output term data))))
          (eat-term-delete term))))
    ;; term
    (when ghostel-bench-include-term
      (with-temp-buffer
        (let* ((data (ghostel-bench--encode-for-backend raw-data 'term))
               (proc (ghostel-bench--make-term rows cols))
               (inhibit-read-only t)
               (counter 0))
          (ghostel-bench--measure
           (format "%s/term/%s" name label)
           (string-bytes data) iters
           (if render-p
               (lambda ()
                 (setq counter (1+ counter))
                 (term-emulate-terminal proc (format "\e[H%d\r\n" counter))
                 (term-emulate-terminal proc data))
             (lambda () (term-emulate-terminal proc data))))
          (delete-process proc))))))

(defun ghostel-bench--run-engine-scenarios ()
  "Run engine micro-benchmarks.
These dump all data in a single write-input call and do one redraw.
Useful for isolating engine overhead but NOT representative of
real-world performance (see PTY and streaming benchmarks for that)."
  (message "\n--- Engine Micro-Benchmarks (single bulk call, NOT real-world) ---")
  (message "  NOTE: These show per-call engine cost.  For real-world performance,")
  (message "  see the PTY and Streaming results above.")
  (message "  %-50s %5s  %8s  %10s  %8s" "SCENARIO" "ITERS" "TOTAL(s)" "ITER(ms)" "MB/s")
  (message "  %s" (make-string 90 ?-))
  (let ((scenarios
         `(("plain"   . ghostel-bench--gen-plain-ascii)
           ("styled"  . ghostel-bench--gen-sgr-styled)
           ("unicode" . ghostel-bench--gen-unicode))))
    (dolist (scenario scenarios)
      (let* ((name (car scenario))
             (gen-fn (cdr scenario))
             (raw-data (funcall gen-fn ghostel-bench-data-size)))
        (ghostel-bench--run-for-backends
         (format "engine/%s" name) raw-data 24 80
         ghostel-bench-iterations t)))))

;; ---------------------------------------------------------------------------
;; Header / summary
;; ---------------------------------------------------------------------------

(defun ghostel-bench--human-size (bytes)
  "Format BYTES as a human-readable string."
  (cond
   ((>= bytes (* 1024 1024)) (format "%.1f MB" (/ bytes (expt 1024.0 2))))
   ((>= bytes 1024) (format "%.0f KB" (/ bytes 1024.0)))
   (t (format "%d B" bytes))))

(defun ghostel-bench--print-header ()
  "Print benchmark header."
  (message "")
  (message "=== Ghostel Performance Benchmark Suite ===")
  (message "")
  (message "  Date:       %s" (format-time-string "%Y-%m-%d %H:%M:%S"))
  (message "  Emacs:      %s" emacs-version)
  (message "  Data size:  %s" (ghostel-bench--human-size ghostel-bench-data-size))
  (message "  Iterations: %d" ghostel-bench-iterations)
  (message "  Scrollback: %d" ghostel-bench-scrollback)
  (message "  Backends:   ghostel-incr, ghostel-full%s%s%s"
           (if ghostel-bench-include-vterm ", vterm" "")
           (if ghostel-bench-include-eat ", eat" "")
           (if ghostel-bench-include-term ", term" ""))
  (message ""))

(defun ghostel-bench--print-summary ()
  "Print summary with PTY results highlighted."
  (message "\n=== Summary ===")
  (let ((pty-results
         (cl-remove-if-not
          (lambda (r) (string-prefix-p "pty/" (plist-get r :name)))
          ghostel-bench--results)))
    (when pty-results
      (message "\n  Real-world PTY throughput (cat %s):"
               (ghostel-bench--human-size ghostel-bench-data-size))
      (dolist (r (sort (copy-sequence pty-results)
                       (lambda (a b) (string< (plist-get a :name)
                                              (plist-get b :name)))))
        (message "    %-40s %8.0f ms  %6.1f MB/s"
                 (plist-get r :name)
                 (plist-get r :per-iter-ms)
                 (plist-get r :throughput-mbs)))))
  (message "\nDone."))

;; ---------------------------------------------------------------------------
;; Entry points
;; ---------------------------------------------------------------------------

(defun ghostel-bench--load-backends ()
  "Load available backends, adjusting include flags."
  (require 'ghostel)
  (when ghostel-bench-include-vterm
    (condition-case err
        (require 'vterm)
      (error
       (message "WARNING: vterm not available, skipping (%s)" (error-message-string err))
       (setq ghostel-bench-include-vterm nil))))
  (when ghostel-bench-include-eat
    (condition-case err
        (require 'eat)
      (error
       (message "WARNING: eat not available, skipping (%s)" (error-message-string err))
       (setq ghostel-bench-include-eat nil))))
  (when ghostel-bench-include-term
    (condition-case err
        (require 'term)
      (error
       (message "WARNING: term not available, skipping (%s)" (error-message-string err))
       (setq ghostel-bench-include-term nil)))))

(defun ghostel-bench-run-all ()
  "Run all benchmarks and print results."
  (ghostel-bench--load-backends)
  (setq ghostel-bench--results nil)
  (ghostel-bench--print-header)
  (ghostel-bench--run-pty-scenarios)
  (ghostel-bench--run-stream-scenarios)
  (ghostel-bench--run-tui-scenarios)
  (ghostel-bench--run-engine-scenarios)
  (ghostel-bench--print-summary))

(defun ghostel-bench-run-quick ()
  "Run a quick subset: smaller data, fewer iterations, single size."
  (setq ghostel-bench-data-size (* 100 1024))  ; 100 KB
  (setq ghostel-bench-iterations 2)
  (setq ghostel-bench-terminal-sizes '((24 . 80)))
  (ghostel-bench-run-all))

(provide 'ghostel-bench)

;;; ghostel-bench.el ends here
