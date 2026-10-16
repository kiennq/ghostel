;;; ghostel-reload-test.el --- Tests for ghostel renderer reload -*- lexical-binding: t; -*-

;;; Commentary:

;; In-process renderer handoff while native PTY sessions stay alive.

;;; Code:

(require 'ghostel-test-helpers)

(defun ghostel-test-reload--count (needle text)
  "Count occurrences of NEEDLE in TEXT."
  (let ((start 0)
        (count 0))
    (while (string-match (regexp-quote needle) text start)
      (setq count (1+ count)
            start (match-end 0)))
    count))

(defun ghostel-test-reload--wait-for-text (buffer process needle &optional count)
  "Wait for NEEDLE in BUFFER's native terminal text through PROCESS.
COUNT is the minimum number of occurrences, defaulting to one."
  (ghostel-test--wait-for
   process
   (lambda ()
     (>= (ghostel-test-reload--count
          needle (ghostel-test--terminal-text buffer))
         (or count 1)))
   5))

(defun ghostel-test-reload--cleanup (buffer process)
  "Stop BUFFER's native reader and PROCESS without changing test assertions."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((term (or (and (boundp 'ghostel--native-transport-term)
                           ghostel--native-transport-term)
                      ghostel--term)))
        (when (and term (fboundp 'ghostel--kill-native-process))
          (ignore-errors (ghostel--kill-native-process term))))))
  (when (and process (process-live-p process))
    (ignore-errors (delete-process process))))

(ert-deftest ghostel-test-native-handoff-api-probes-v1-and-propagates-quit ()
  "A bound handoff function is insufficient without protocol version one."
  (let ((ghostel--native-handoff-functions '(ghostel--handoff-version))
        (version 2))
    (cl-letf (((symbol-function 'ghostel--handoff-version)
               (lambda (_term)
                 (pcase version
                    ('loader-error (error "Stale handoff export"))
                   ('quit (signal 'quit nil))
                   (_ version)))))
      (should-not (ghostel--native-handoff-api-p))
      (setq version 1)
      (should (ghostel--native-handoff-api-p))
      (setq version 'loader-error)
      (should-not (ghostel--native-handoff-api-p))
      (setq version 'quit)
      (should (condition-case nil
                  (progn (ghostel--native-handoff-api-p) nil)
                (quit t))))
    (let ((ghostel--native-handoff-functions
           '(ghostel--handoff-version ghostel--handoff-missing-export)))
      (setq version 1)
      (should-not (ghostel--native-handoff-api-p)))))

(ert-deftest ghostel-test-reload-snapshot-validates-color-scheme ()
  "V1 snapshots carry a valid host-assigned light/dark scheme."
  (should (ghostel--renderer-reload-snapshot-p
           '("bytes" 24 80 8 16 1 light)))
  (should-not (ghostel--renderer-reload-snapshot-p
               '("bytes" 24 80 8 16 1)))
  (should-not (ghostel--renderer-reload-snapshot-p
               '("bytes" 24 80 8 16 1 auto))))

(ert-deftest ghostel-test-native-handoff-stale-generations-skip-snapshot ()
  "A stale renderer or transport generation cannot reach snapshot or commit."
  (let ((buffer (generate-new-buffer " *ghostel-reload-stale-generation*"))
        pipe
        (snapshot-calls 0)
        (commit-calls 0)
        invalid-handle)
    (unwind-protect
        (progn
          (setq pipe (make-pipe-process
                      :name "ghostel-reload-stale-generation"
                      :buffer buffer
                      :noquery t
                      :sentinel #'ignore))
          (process-put pipe 'ghostel-native-pty t)
          (process-put pipe 'ghostel--native-pid 4242)
          (with-current-buffer buffer
            (ghostel-mode)
            (setq-local ghostel--process pipe
                        ghostel--pid 4242
                        ghostel--term 'stale-renderer
                        ghostel--native-transport-term nil
                        ghostel--pty-out-function nil))
          (cl-letf (((symbol-function 'ghostel--live-buffers)
                     (lambda () (list buffer)))
                    ((symbol-function 'ghostel--native-handoff-api-p)
                     (lambda () t))
                    ((symbol-function 'ghostel--native-handoff-version-p)
                     (lambda (term) (not (eq term invalid-handle))))
                    ((symbol-function 'ghostel--native-transport-term-for-process)
                     (lambda () t))
                    ((symbol-function 'ghostel--renderer-reload-settings)
                     (lambda () nil))
                    ((symbol-function 'ghostel--handoff-snapshot)
                     (lambda (&rest _)
                       (setq snapshot-calls (1+ snapshot-calls))
                       nil))
                    ((symbol-function 'ghostel--handoff-commit)
                     (lambda (&rest _)
                       (setq commit-calls (1+ commit-calls))
                       t)))
            (setq invalid-handle 'stale-renderer)
            (let* ((result (ghostel--reload-renderer-sessions #'ignore))
                   (reason (cdar (cdr result))))
              (should (string-match-p "renderer generation" reason))
              (should (= (car result) 0))
              (should (= snapshot-calls 0))
              (should (= commit-calls 0)))

            (with-current-buffer buffer
              (setq-local ghostel--term 'current-renderer
                          ghostel--native-transport-term 'stale-transport
                          ghostel--pty-out-function
                          #'ghostel--native-transport-write))
            (setq invalid-handle 'stale-transport)
            (let* ((result (ghostel--reload-renderer-sessions #'ignore))
                   (reason (cdar (cdr result))))
              (should (string-match-p "transport generation" reason))
              (should (= (car result) 0))
              (should (= snapshot-calls 0))
              (should (= commit-calls 0)))))
      (when (and pipe (process-live-p pipe))
        (delete-process pipe))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (setq ghostel--term nil
                ghostel--native-transport-term nil
                ghostel--pty-out-function nil))
        (kill-buffer buffer)))))

(ert-deftest ghostel-test-native-handoff-version-change-prevents-commit ()
  "An unsupported active generation after reload cancels staged sessions."
  (let ((buffer (generate-new-buffer " *ghostel-reload-version-change*"))
        (ghostel--native-handoff-functions '(ghostel--handoff-version))
        (version 1)
        (snapshot-calls 0)
        (commit-calls 0)
        (cancel-calls 0))
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--live-buffers)
                   (lambda () (list buffer)))
                  ((symbol-function 'ghostel--renderer-reload-session-info)
                   (lambda (_buffer)
                     (list :buffer buffer
                           :pipe 'pipe
                           :pid 4242
                           :term 'source-term
                           :old-transport nil
                           :transport 'source-term
                           :capture t
                           :pty-out nil
                           :settings nil)))
                  ((symbol-function 'ghostel--handoff-version)
                   (lambda (_term) version))
                  ((symbol-function 'ghostel--handoff-snapshot)
                   (lambda (&rest _)
                     (setq snapshot-calls (1+ snapshot-calls))
                     (list "bytes" 24 80 8 16 1 'dark)))
                  ((symbol-function 'ghostel--handoff-cancel)
                   (lambda (_term)
                     (setq cancel-calls (1+ cancel-calls))
                     t))
                  ((symbol-function 'ghostel--renderer-reload-one)
                   (lambda (_plan)
                     (setq commit-calls (1+ commit-calls))
                     nil)))
          (let ((result (ghostel--reload-renderer-sessions
                         (lambda () (setq version 2)))))
            (should (= (car result) 0))
            (should (= snapshot-calls 1))
            (should (= commit-calls 0))
            (should (= cancel-calls 1))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ghostel-test-native-handoff-rejects-unsupported-candidate ()
  "A candidate from a non-v1 generation is rejected before restore or commit."
  (let ((buffer (generate-new-buffer " *ghostel-reload-candidate-generation*"))
        (restore-calls 0)
        (commit-calls 0)
        (plan (list :snapshot (list "bytes" 24 80 8 16 1 'dark)
                    :settings nil
                    :buffer nil
                    :term 'source-term
                    :capture t
                    :transport 'source-term
                    :pty-out nil)))
    (setf (plist-get plan :buffer) buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--new)
                   (lambda (&rest _) 'candidate-term))
                  ((symbol-function 'ghostel--native-handoff-version-p)
                   (lambda (term) (not (eq term 'candidate-term))))
                  ((symbol-function 'ghostel--handoff-restore)
                   (lambda (&rest _)
                     (setq restore-calls (1+ restore-calls))
                     t))
                  ((symbol-function 'ghostel--handoff-commit)
                   (lambda (&rest _)
                     (setq commit-calls (1+ commit-calls))
                     t))
                  ((symbol-function 'ghostel--renderer-reload-session-guard-p)
                   (lambda (_plan) t))
                  ((symbol-function 'ghostel--renderer-reload-local-state)
                   (lambda (_scratch) '(nil nil nil nil nil nil)))
                  ((symbol-function 'ghostel--renderer-reload-after-swap)
                   #'ignore))
          (let ((reason (ghostel--renderer-reload-one plan)))
            (should (string-match-p "generation" reason))
            (should (= restore-calls 0))
            (should (= commit-calls 0))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ghostel-test-commit-frame-fallback-keeps-repair-until-success ()
  "The cold redraw fallback is full and clears repair only after success."
  (let ((buffer (generate-new-buffer " *ghostel-commit-frame-repair*"))
        (redraw-result nil)
        full-argument)
    (unwind-protect
        (with-current-buffer buffer
          (setq-local ghostel--term 'fake-term
                      ghostel--pending-redraw t
                      ghostel--force-next-redraw nil
                      ghostel--repair-pending t
                      ghostel--input-mode 'char
                      ghostel-full-redraw nil)
          (cl-letf (((symbol-function 'ghostel--redraw-now)
                     (lambda (&rest _) nil))
                    ((symbol-function 'ghostel--get-render-window)
                     (lambda (_buffer) nil))
                    ((symbol-function 'ghostel--redraw)
                     (lambda (_term full _force-sync)
                       (setq full-argument full)
                       redraw-result))
                    ((symbol-function 'ghostel--schedule-link-detection)
                     #'ignore))
            (ghostel--commit-frame buffer)
            (should (eq full-argument t))
            (should ghostel--repair-pending)
            (should ghostel--pending-redraw)
            (setq redraw-result t)
            (ghostel--commit-frame buffer)
            (should (eq full-argument t))
            (should-not ghostel--repair-pending)
            (should-not ghostel--pending-redraw)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ghostel-test-reload-snapshot-validates-scheme-metadata ()
  "V1 snapshots carry seven fields and a light/dark host scheme."
  (should (ghostel--renderer-reload-snapshot-p
           '("bytes" 24 80 8 16 1 light)))
  (should (ghostel--renderer-reload-snapshot-p
           '("bytes" 24 80 8 16 1 dark)))
  (should-not (ghostel--renderer-reload-snapshot-p
               '("bytes" 24 80 8 16 1)))
  (should-not (ghostel--renderer-reload-snapshot-p
               '("bytes" 24 80 8 16 1 auto))))

(ert-deftest ghostel-test-reload-module-preflight-before-reload ()
  "Missing handoff support fails before reload without closing a session."
  (let ((buffer (generate-new-buffer " *ghostel-reload-preflight*"))
        pipe
        reloaded)
    (unwind-protect
        (progn
          (setq pipe (make-pipe-process
                      :name "ghostel-reload-preflight"
                      :buffer buffer
                      :noquery t))
          (process-put pipe 'ghostel-native-pty t)
          (process-put pipe 'ghostel--native-pid 4242)
          (with-current-buffer buffer
            (ghostel-mode)
            (setq-local ghostel--term 'fake-native-term
                        ghostel--process pipe
                        ghostel--pid 4242))
          (cl-letf (((symbol-function 'ghostel--native-runtime-reloadable-p)
                     (lambda () t))
                    ((symbol-function 'ghostel--native-handoff-api-p)
                     (lambda () nil))
                    ((symbol-function 'ghostel--loader-reload)
                     (lambda (&rest _)
                       (setq reloaded t))))
            (let ((current-prefix-arg nil))
              (should-error (call-interactively #'ghostel-reload-module)
                            :type 'user-error))
            (should-not reloaded)
            (should (buffer-live-p buffer))
            (should (process-live-p pipe))))
      (when (and pipe (process-live-p pipe))
        (delete-process pipe))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ghostel-test-native-transport-output-decodes-full-handoff-frame ()
  "A full 4 MiB staged frame decodes without a whole-payload regexp."
  (let* ((buffer (generate-new-buffer " *ghostel-transport-frame*"))
         (payload (encode-coding-string
                   (make-string (* 4 1024 1024) ?x) 'binary))
         (encoded (base64-encode-string payload t))
         (calls 0)
         received
         pipe)
    (unwind-protect
        (progn
          (setq pipe (make-pipe-process
                      :name "ghostel-transport-frame"
                      :buffer buffer
                      :noquery t))
          (process-put pipe 'ghostel-native-pty t)
          (process-put pipe 'ghostel--native-pid 4243)
          (with-current-buffer buffer
            (ghostel-mode)
            (setq-local ghostel--process pipe
                        ghostel--pid 4243
                        ghostel--native-transport-term 'test-transport)
            (cl-letf (((symbol-function 'ghostel-write-output)
                       (lambda (bytes &optional _no-reply)
                         (setq calls (1+ calls)
                               received bytes)))
                      ((symbol-function 'ghostel--invalidate) #'ignore))
              (should (ghostel--native-transport-output 4243 encoded))
              (should (= calls 1))
              (should (= (length received) (length payload)))
              (should (= (aref received 0) ?x))
              (should (= (aref received (1- (length received))) ?x)))))
      (when (and pipe (process-live-p pipe))
        (delete-process pipe))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ghostel-test-reload-module-preserves-native-pty ()
  "Download and manual reload keep one native child and route its output once."
  :tags '(native)
  (let ((ghostel-use-native-pty t))
    (ghostel-test--with-raw-echo-buffer (buffer process)
      (unwind-protect
          (let* ((original-term ghostel--term)
                 (pid ghostel--pid)
                 (size (ghostel-terminal-size))
                 (prior-bytes
                  (encode-coding-string
                   "\e[31mGHOSTEL_RELOAD_PRIOR\e[0m" 'utf-8))
                 ;; The Windows echo fixture uses the console code page.
                 (post-marker (if (ghostel-test--windows-p)
                                  "GHOSTEL_RELOAD_POST"
                                "GHOSTEL_RELOAD_POST-λ"))
                 (post-bytes (encode-coding-string post-marker 'utf-8)))
            (should (fboundp 'ghostel--handoff-snapshot))
            (should (= 1 (ghostel--handoff-version original-term)))
            (let ((child (process-get process 'ghostel--native-child)))
              (should child)
              (should-not (ghostel--handoff-version child)))
            ;; Resolve the constructor's initial size before asking for a
            ;; ground-state snapshot; the native API correctly rejects a
            ;; renderer with an uncommitted resize.
            (ghostel-test--wait-until
             (lambda () (ghostel-test--redraw original-term t))
             process 5)
            ;; The host scheme is not terminal snapshot state.  Set light
            ;; while reporting is off, then enable reports to catch a restore
            ;; that accidentally uses the live, report-producing setter.
            (ghostel--set-default-colors
             original-term "#ffffff" "#000000" 'light)
            (ghostel--write-vt
             original-term (encode-coding-string "\e[?2031h" 'binary))
            (ghostel--write-pty original-term prior-bytes)
            (ghostel-test-reload--wait-for-text
             buffer process "GHOSTEL_RELOAD_PRIOR")
            (let ((prior-state (ghostel-test--terminal-text buffer))
                  (prior-buffer (with-current-buffer buffer
                                  (buffer-string))))
              (let (restore-replies)
                (cl-letf (((symbol-function 'yes-or-no-p) #'always)
                          ((symbol-function 'ghostel--download-module) #'always)
                          ((symbol-function 'ghostel--pty-out)
                           (lambda (bytes) (push bytes restore-replies))))
                  (let ((current-prefix-arg '(4)))
                    (call-interactively #'ghostel-download-module)))
                (should (buffer-live-p buffer))
                (should-not restore-replies))
              (let ((first-term (buffer-local-value 'ghostel--term buffer))
                    (transport-term
                     (buffer-local-value 'ghostel--native-transport-term buffer)))
                (should (not (eq original-term first-term)))
                (should (= 1 (ghostel--handoff-version first-term)))
                (should (= 1 (ghostel--handoff-version original-term)))
                (should (eq original-term transport-term))
                (should (eq process (buffer-local-value 'ghostel--process buffer)))
                (should (process-live-p process))
                (should (equal pid (buffer-local-value 'ghostel--pid buffer)))
                (should (equal pid (process-get process 'ghostel--native-pid)))
                (should (equal size (buffer-local-value 'ghostel--given-size buffer)))
                (should (equal prior-state (ghostel-test--terminal-text buffer)))
                (should (equal prior-buffer
                               (with-current-buffer buffer (buffer-string))))
                (should (eq 'light
                            (nth 6 (ghostel--handoff-snapshot first-term nil))))
                (let (transport-replies)
                  (cl-letf (((symbol-function 'ghostel--handoff-reply)
                             (lambda (transport bytes)
                               (push (cons transport bytes) transport-replies)
                               t)))
                    (ghostel--write-vt
                     first-term (encode-coding-string "\e[?996n" 'binary)))
                  (should
                   (equal (nreverse transport-replies)
                          (list
                           (cons original-term
                                 (encode-coding-string "\e[?997;2n" 'binary))))))
                (should-error (ghostel--handoff-snapshot first-term t))
                (ghostel--write-pty first-term post-bytes)
                (ghostel-test-reload--wait-for-text buffer process post-marker)
                (accept-process-output process 0.1)
                (should (= 1
                           (ghostel-test-reload--count
                            post-marker
                            (ghostel-test--terminal-text buffer))))
                (let ((current-prefix-arg nil))
                  (should (= 1 (call-interactively #'ghostel-reload-module))))
                (let ((second-term
                       (buffer-local-value 'ghostel--term buffer)))
                  (should (not (eq first-term second-term)))
                  (should (eq original-term
                              (buffer-local-value
                               'ghostel--native-transport-term buffer)))
                  (should (eq process
                              (buffer-local-value 'ghostel--process buffer)))
                  (should (process-live-p process))
                  (should (equal pid
                                 (buffer-local-value 'ghostel--pid buffer)))
                  (should (equal pid
                                 (process-get process 'ghostel--native-pid)))
                  (should (= 1 (ghostel--handoff-version second-term)))
                  (let ((snapshot (ghostel--handoff-snapshot second-term nil)))
                    (should (consp snapshot))
                    (should (eq 'light (nth 6 snapshot))))
                  (should-error (ghostel--handoff-snapshot second-term t))
                  (ghostel--native-transport-output
                   (1+ pid)
                   (base64-encode-string
                    (encode-coding-string "GHOSTEL_STALE_RAW" 'utf-8) t))
                  (should-not
                   (string-match-p
                    "GHOSTEL_STALE_RAW"
                    (ghostel-test--terminal-text buffer)))
                  (ghostel--write-pty second-term post-bytes)
                  (ghostel-test-reload--wait-for-text
                   buffer process post-marker 2)
                  (accept-process-output process 0.1)
                  (should (= 2
                             (ghostel-test-reload--count
                              post-marker
                              (ghostel-test--terminal-text buffer))))
                  ;; Stop the old transport explicitly; its sentinel flushes
                  ;; final output through the current renderer before cleanup.
                  (ghostel--kill-native-process original-term)
                  (ghostel-test--wait-for
                   process (lambda () (not (process-live-p process))) 5)
                  (should-not
                   (buffer-local-value
                    'ghostel--native-transport-term buffer))
                  (should-not
                   (buffer-local-value 'ghostel--pty-out-function buffer))))))
        (ghostel-test-reload--cleanup buffer process)))))

(ert-deftest ghostel-test-reload-module-loader-failure-rolls-back ()
  "A loader failure cancels staging and resumes the same native process."
  :tags '(native)
  (let ((ghostel-use-native-pty t))
    (ghostel-test--with-raw-echo-buffer (buffer process)
      (unwind-protect
          (let* ((original-term ghostel--term)
                 (pid ghostel--pid)
                 (before nil)
                 (probe (encode-coding-string "GHOSTEL_RELOAD_ROLLBACK" 'utf-8)))
            (ghostel-test--wait-until
             (lambda () (ghostel-test--redraw original-term t))
             process 5)
            (setq before (ghostel-test--terminal-text buffer))
            (should-error
             (ghostel--reload-renderer-sessions
              (lambda () (error "Injected loader failure"))))
            (should (eq original-term
                        (buffer-local-value 'ghostel--term buffer)))
            (should-not
             (buffer-local-value 'ghostel--native-transport-term buffer))
            (should (equal before (ghostel-test--terminal-text buffer)))
            (should (eq process
                        (buffer-local-value 'ghostel--process buffer)))
            (should (process-live-p process))
            (should (equal pid (process-get process 'ghostel--native-pid)))
            (ghostel--native-transport-output
             pid
             (base64-encode-string
              (encode-coding-string "GHOSTEL_UNTRACKED_RAW" 'utf-8) t))
            (should-not
             (string-match-p "GHOSTEL_UNTRACKED_RAW"
                             (ghostel-test--terminal-text buffer)))
            (ghostel--write-pty original-term probe)
            (ghostel-test-reload--wait-for-text
             buffer process "GHOSTEL_RELOAD_ROLLBACK")
            (should (process-live-p process)))
        (ghostel-test-reload--cleanup buffer process)))))

(provide 'ghostel-reload-test)

;;; ghostel-reload-test.el ends here
