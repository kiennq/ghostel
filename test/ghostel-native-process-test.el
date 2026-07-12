;;; ghostel-native-process-test.el --- Tests for ghostel: native process -*- lexical-binding: t; -*-

;;; Commentary:

;; Native PTY event serialization and Elisp event-filter parsing.

;;; Code:

(require 'ghostel-test-helpers)

(defvar ghostel-test-native-process--events nil
  "Events recorded by native process unit-test callbacks.")

(defvar ghostel-test-native-process--evil nil
  "Non-nil if a native process quoting test evaluates injected Lisp.")

(defun ghostel-test-native-process--record (&rest args)
  "Record ARGS for native process event-filter tests."
  (push args ghostel-test-native-process--events))

(ert-deftest ghostel-test-spawn-process-suppresses-built-in-process-resize ()
  "`ghostel--spawn-process' leaves resizing to `ghostel--adjust-size'."
  (let ((pipe nil))
    (unwind-protect
        (ghostel-test--without-subr-trampolines
          (cl-letf (((symbol-function 'ghostel--resolve-local-executable)
                     #'identity)
                    ((symbol-function 'ghostel--spawn-via-native)
                     (lambda (&rest _)
                       (setq pipe (make-pipe-process
                                   :name "ghostel-native-process"
                                   :buffer (current-buffer)
                                   :noquery t))))
                    ((symbol-function 'signal-process)
                     #'ignore)
                    ((symbol-function 'ghostel--kill-native-process)
                     #'ignore))
            (with-temp-buffer
              (let ((ghostel-use-native-pty t)
                    (system-type 'gnu/linux))
                (let ((process (ghostel--spawn-process
                                "sh" nil 24 80 "-ixon" nil)))
                  (should (eq pipe process)))
                (should (process-live-p pipe))
                (should (eq (process-get pipe 'adjust-window-size-function)
                            #'ignore))))))
      (when (and pipe (process-live-p pipe))
        (set-process-sentinel pipe #'ignore)
        (delete-process pipe)))))

(ert-deftest ghostel-test-spawn-via-native-marks-event-pipe ()
  "`ghostel--spawn-via-native' marks its event pipe as native PTY transport."
  (let ((pipe nil))
    (unwind-protect
        (with-temp-buffer
          (let ((ghostel--term 'fake-term)
                (ghostel--pid nil))
            (cl-letf (((symbol-function 'ghostel--spawn-native-process)
                       (lambda (_term _command process)
                         (setq pipe process)
                         1234))
                      ((symbol-function 'signal-process)
                       #'ignore)
                      ((symbol-function 'ghostel--kill-native-process)
                       #'ignore))
              (let ((process (ghostel--spawn-via-native '("cmd.exe"))))
                (should (eq process pipe))
                (should (process-get process 'ghostel-native-pty))
                (should (equal ghostel--pid 1234))))))
      (when (and pipe (process-live-p pipe))
        (set-process-sentinel pipe #'ignore)
        (delete-process pipe)))))

(ert-deftest ghostel-test-process-set-window-size-skips-native-pipe ()
  "`ghostel--process-set-window-size' does not resize native event pipes."
  (let ((pipe nil)
        (resize-args nil))
    (unwind-protect
        (progn
          (setq pipe (make-pipe-process
                      :name "ghostel-native-process"
                      :buffer (current-buffer)
                      :noquery t))
          (cl-letf (((symbol-function 'set-process-window-size)
                     (lambda (&rest args)
                       (setq resize-args args))))
            (process-put pipe 'ghostel-native-pty t)
            (ghostel--process-set-window-size pipe 25 80)
            (should-not resize-args)
            (process-put pipe 'ghostel-native-pty nil)
            (ghostel--process-set-window-size pipe 24 100)
            (should (equal (list pipe 24 100) resize-args))))
      (when (and pipe (process-live-p pipe))
        (delete-process pipe)))))

(defun ghostel-test-native-process--with-events-filter (fn)
  "Call FN with a pipe whose process buffer differs from the current buffer."
  (let ((buffer (generate-new-buffer " *ghostel-test-events-filter*"))
        (caller (generate-new-buffer " *ghostel-test-events-caller*"))
        pipe)
    (unwind-protect
        (progn
          (setq pipe (make-pipe-process
                      :name "ghostel-test-events"
                      :buffer buffer
                      :noquery t))
          (let ((ghostel-test-native-process--events nil)
                (invalidations 0))
            (cl-letf (((symbol-function 'ghostel--invalidate)
                       (lambda () (cl-incf invalidations))))
              (with-current-buffer caller
                (funcall fn pipe buffer
                         (lambda () invalidations))))))
      (when (and pipe (process-live-p pipe))
        (delete-process pipe))
      (when (buffer-live-p caller)
        (kill-buffer caller))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(defun ghostel-test-native-process--command-output (command &optional spawn-wrapper)
  "Spawn COMMAND through the native primitive and return its output.
COMMAND is an argv list.  SPAWN-WRAPPER, when non-nil, is called with
and should call the zero-argument spawn function under any dynamic
bindings needed by the test."
  (ghostel-test--with-terminal-buffer (buf _term 200 32767 2000000)
    (let ((pipe (make-pipe-process
                 :name "ghostel-native-command-test"
                 :buffer (current-buffer)
                 :filter #'ghostel--events-filter
                 :noquery t))
          pid)
      (unwind-protect
          (progn
            (let ((spawn (lambda ()
                           (setq pid (ghostel--spawn-native-process
                                     ghostel--term command pipe))
                           (process-put pipe 'ghostel--native-pid pid))))
              (if spawn-wrapper
                  (funcall spawn-wrapper spawn)
                (funcall spawn)))
            (ghostel-test--wait-until
             (lambda () (not (process-live-p pipe))) pipe 5)
            (ghostel-test--terminal-text))
        (when pid
          (ignore-errors (signal-process pid 9)))
        (ignore-errors (ghostel--kill-native-process ghostel--term))
        (when (process-live-p pipe)
          (delete-process pipe))))))

(ert-deftest ghostel-test-native-process-exit-hook-kills-children ()
  "Emacs exit attempts to kill every recorded native child."
  (let (signals)
    (cl-letf (((symbol-function 'process-list)
               (lambda () '(pipe-a unrelated pipe-b dead-pipe)))
              ((symbol-function 'process-get)
               (lambda (process property)
                 (and (eq property 'ghostel--native-pid)
                      (pcase process
                        ('pipe-a 101)
                        ('pipe-b 202)
                        ('dead-pipe 303)))))
              ((symbol-function 'signal-process)
               (lambda (pid signal)
                 (push (list pid signal) signals))))
      (ghostel--kill-native-processes-on-exit)
      (should (equal (nreverse signals) '((101 9) (202 9) (303 9)))))))

(ert-deftest ghostel-test-native-kill-buffer-hook-cleans-up-dead-process ()
  "Native `kill-buffer' cleanup runs after the event process exits."
  (let ((buffer (generate-new-buffer " *ghostel-test-native-cleanup*"))
        cleaned)
    (unwind-protect
        (with-current-buffer buffer
          (let ((pipe (ghostel-test--dummy-process "ghostel-dead-pipe" buffer))
                (ghostel--term 'term))
            (delete-process pipe)
            (setq ghostel--process pipe)
            (cl-letf (((symbol-function 'ghostel--kill-native-process)
                       (lambda (term) (setq cleaned term))))
              (ghostel--kill-native-process-hook))
            (should (eq cleaned 'term))
            (should-not (process-buffer pipe))))
      (kill-buffer buffer))))

(ert-deftest ghostel-test-events-filter-multiple-events-per-chunk ()
  "Native process event filter evaluates multiple events in one chunk."
  (ghostel-test-native-process--with-events-filter
   (lambda (proc buffer invalidations)
     (ghostel--events-filter
     proc
     "(ghostel-test-native-process--record \"one\")(ghostel-test-native-process--record \"two\" 2)")
     (should (equal '(("two" 2) ("one")) ghostel-test-native-process--events))
     (should (null (process-get proc 'ghostel--event-buf)))
     (should (= 1 (funcall invalidations))))))

(ert-deftest ghostel-test-events-filter-uses-process-buffer-state ()
  "Native event parsing stores partial state on the pipe."
  (let ((buffer (generate-new-buffer " *ghostel-test-events-target*"))
        (caller (generate-new-buffer " *ghostel-test-events-caller*"))
        pipe)
    (unwind-protect
        (progn
          (setq pipe (make-pipe-process
                      :name "ghostel-test-events"
                      :buffer buffer
                      :noquery t))
          (with-current-buffer caller
            (cl-letf (((symbol-function 'ghostel--invalidate) #'ignore))
              (ghostel--events-filter
               pipe "(ghostel-test-native-process--record \"partial")))
          (should (equal (process-get pipe 'ghostel--event-buf)
                         "(ghostel-test-native-process--record \"partial")))
      (when (and pipe (process-live-p pipe))
        (delete-process pipe))
      (when (buffer-live-p caller)
        (kill-buffer caller))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ghostel-test-events-filter-detached-pipe-completes-itself ()
  "Late completion from a detached pipe deletes only that pipe."
  (let ((old-buffer (generate-new-buffer " *ghostel-test-old-events*"))
        (new-buffer (generate-new-buffer " *ghostel-test-new-events*"))
        old-pipe
        new-pipe
        (ghostel-test-native-process--events nil)
        (invalidations 0))
    (unwind-protect
        (progn
          (setq old-pipe (make-pipe-process
                          :name "ghostel-test-old-events"
                          :buffer old-buffer
                          :noquery t)
                new-pipe (make-pipe-process
                          :name "ghostel-test-new-events"
                          :buffer new-buffer
                          :noquery t))
          (set-process-buffer old-pipe nil)
          (process-put old-pipe 'ghostel--native-pid 101)
          (process-put new-pipe 'ghostel--event-buf
                      "(ghostel-test-native-process--record \"new")
          (cl-letf (((symbol-function 'ghostel--invalidate)
                    (lambda () (cl-incf invalidations))))
           (ghostel--events-filter
            old-pipe
            (concat ghostel--native-exit-marker-prefix "101 0\n"))
           (should-not (process-live-p old-pipe)))
          (should (equal (process-get new-pipe 'ghostel--event-buf)
                        "(ghostel-test-native-process--record \"new"))
          (should-not ghostel-test-native-process--events)
          (should (= invalidations 0)))
      (dolist (pipe (list old-pipe new-pipe))
        (when (and pipe (process-live-p pipe))
          (delete-process pipe)))
      (dolist (buffer (list old-buffer new-buffer))
        (when (buffer-live-p buffer)
          (kill-buffer buffer))))))

(ert-deftest ghostel-test-events-filter-ignores-stale-native-exit-marker ()
  "A late reaper marker for an old pid cannot close a restarted pipe."
  (ghostel-test-native-process--with-events-filter
   (lambda (proc buffer invalidations)
     (process-put proc 'ghostel--native-pid 202)
     (ghostel--events-filter
      proc
      (concat ghostel--native-exit-marker-prefix "101 255\n"
              "(ghostel-test-native-process--record \"new\")"))
     (should (process-live-p proc))
     (should (equal '(("new")) ghostel-test-native-process--events))
     (should (null (process-get proc 'ghostel--event-buf)))
     (should (= 1 (funcall invalidations))))))

(ert-deftest ghostel-test-events-filter-buffers-partial-native-exit-marker ()
  "Fragmented native exit markers wait for the newline delimiter."
  (ghostel-test-native-process--with-events-filter
   (lambda (proc buffer _invalidations)
     (process-put proc 'ghostel--native-pid 202)
     (ghostel--events-filter
      proc
      (concat ghostel--native-exit-marker-prefix "101"))
     (should (process-live-p proc))
     (should (equal (concat ghostel--native-exit-marker-prefix "101")
                    (process-get proc 'ghostel--event-buf)))
     (ghostel--events-filter
      proc
      " 255\n(ghostel-test-native-process--record \"new\")")
     (should (process-live-p proc))
     (should (equal '(("new")) ghostel-test-native-process--events))
     (should (null (process-get proc 'ghostel--event-buf))))))

(ert-deftest ghostel-test-events-filter-drops-stale-native-exit-prefix ()
  "A lone stale native marker prefix cannot block later callbacks."
  (ghostel-test-native-process--with-events-filter
   (lambda (proc buffer _invalidations)
     (process-put proc 'ghostel--native-pid 202)
     (ghostel--events-filter proc ghostel--native-exit-marker-prefix)
     (should (equal ghostel--native-exit-marker-prefix
                    (process-get proc 'ghostel--event-buf)))
     (ghostel--events-filter
      proc
      "(ghostel-test-native-process--record \"new\")")
     (should (process-live-p proc))
     (should (equal '(("new")) ghostel-test-native-process--events))
     (should (null (process-get proc 'ghostel--event-buf))))))

(ert-deftest ghostel-test-events-filter-drops-stale-callback-tail ()
  "A stale marker and callback tail cannot poison later callbacks."
  (ghostel-test-native-process--with-events-filter
   (lambda (proc buffer _invalidations)
     (process-put proc 'ghostel--native-pid 202)
     (ghostel--events-filter
      proc
      (concat ghostel--native-exit-marker-prefix
              ")(ghostel-test-native-process--record \"new\")"))
     (should (process-live-p proc))
     (should (equal '(("new")) ghostel-test-native-process--events))
     (should (null (process-get proc 'ghostel--event-buf))))))

(ert-deftest ghostel-test-events-filter-partial-writes-across-chunks ()
  "Native process event filter keeps incomplete events across chunks."
  (ghostel-test-native-process--with-events-filter
   (lambda (proc buffer _invalidations)
     (ghostel--events-filter proc "(ghostel-test-native-process--record \"par")
     (should (equal nil ghostel-test-native-process--events))
     (should (equal "(ghostel-test-native-process--record \"par"
                    (process-get proc 'ghostel--event-buf)))
     (ghostel--events-filter proc "tial\" 42)")
     (should (equal '(("partial" 42)) ghostel-test-native-process--events))
     (should (null (process-get proc 'ghostel--event-buf))))))

(ert-deftest ghostel-test-events-filter-complete-prefix-with-partial-tail ()
  "Native process event filter evaluates complete events before a partial tail."
  (ghostel-test-native-process--with-events-filter
   (lambda (proc buffer _invalidations)
     (ghostel--events-filter
      proc
     "(ghostel-test-native-process--record \"first\")(ghostel-test-native-process--record \"sec")
     (should (equal '(("first")) ghostel-test-native-process--events))
     (should (equal "(ghostel-test-native-process--record \"sec"
                    (process-get proc 'ghostel--event-buf)))
     (ghostel--events-filter proc "ond\")")
     (should (equal '(("second") ("first")) ghostel-test-native-process--events))
     (should (null (process-get proc 'ghostel--event-buf))))))

(ert-deftest ghostel-test-events-filter-reselects-buffer-after-callback ()
  "Callback buffer switches cannot redirect parser state or invalidation."
  (let ((buffer (generate-new-buffer " *ghostel-test-events-target*"))
       (caller (generate-new-buffer " *ghostel-test-events-caller*"))
       (switched (generate-new-buffer " *ghostel-test-events-switched*"))
       invalidated-buffer
       pipe)
    (unwind-protect
       (progn
         (setq pipe (make-pipe-process
                     :name "ghostel-test-events"
                     :buffer buffer
                     :noquery t))
         (cl-letf (((symbol-function 'ghostel--invalidate)
                    (lambda () (setq invalidated-buffer (current-buffer)))))
           (with-current-buffer caller
             (ghostel--events-filter
              pipe
              (format "(set-buffer %S)(ghostel-test-native-process--record \"partial"
                      (buffer-name switched)))))
         (should (equal (process-get pipe 'ghostel--event-buf)
                        "(ghostel-test-native-process--record \"partial"))
         (should (eq invalidated-buffer buffer)))
     (when (and pipe (process-live-p pipe))
       (delete-process pipe))
     (dolist (buf (list caller switched buffer))
       (when (buffer-live-p buf)
         (kill-buffer buf))))))

(ert-deftest ghostel-test-events-filter-failing-event-does-not-poison-next-write ()
  "Native process event filter can process a good write after a failing one.
A well-formed event whose evaluation signals is logged and discarded; it
must not leave `ghostel--event-buf' in a poisoned state."
  (ghostel-test-native-process--with-events-filter
   (lambda (proc buffer _invalidations)
     (ghostel--events-filter proc "(error \"boom\")")
     (should (null (process-get proc 'ghostel--event-buf)))
     (ghostel--events-filter proc "(ghostel-test-native-process--record \"good\")")
     (should (equal '(("good")) ghostel-test-native-process--events))
     (should (null (process-get proc 'ghostel--event-buf))))))

(ert-deftest ghostel-test-events-filter-signalling-event-does-not-lose-tail ()
  "A signalling event is logged but does not abort the rest of the batch."
  (ghostel-test-native-process--with-events-filter
   (lambda (proc buffer invalidations)
     ;; Batch: a good event, an event whose evaluation signals, another good
     ;; event, then a partial tail.  The signal must not propagate out of the
     ;; filter, nor drop the events/tail that follow it.
     (ghostel--events-filter
      proc
      (concat "(ghostel-test-native-process--record \"before\")"
              "(error \"boom\")"
              "(ghostel-test-native-process--record \"after\")"
              "(ghostel-test-native-process--record \"par"))
     (should (equal '(("after") ("before")) ghostel-test-native-process--events))
     (should (equal "(ghostel-test-native-process--record \"par"
                    (process-get proc 'ghostel--event-buf)))
     (should (= 1 (funcall invalidations)))
     (ghostel--events-filter proc "tial\")")
     (should (equal '(("partial") ("after") ("before"))
                    ghostel-test-native-process--events))
     (should (null (process-get proc 'ghostel--event-buf))))))

(ert-deftest ghostel-test-native-pipe-sentinel-forces-final-redraw ()
  "Pipe EOF redraws the fully drained native terminal before cleanup."
  (let ((buffer (generate-new-buffer " *ghostel-test-native-sentinel*"))
        redraw)
    (unwind-protect
        (with-current-buffer buffer
          (setq-local ghostel--term 'term
                      ghostel-kill-buffer-on-exit nil
                      ghostel-exit-functions nil
                      ghostel--redraw-timer nil
                      ghostel--plain-link-detection-timer nil)
          (cl-letf (((symbol-function 'process-buffer)
                     (lambda (_process) buffer))
                    ((symbol-function 'ghostel--redraw-now)
                     (lambda (buf force) (setq redraw (list buf force))))
                    ((symbol-function 'ghostel--cancel-password-confirm-timer) #'ignore)
                    ((symbol-function 'ghostel--spinner-stop) #'ignore)
                    ((symbol-function 'ghostel--fake-cursor-clear) #'ignore))
            (ghostel--sentinel 'pipe "finished\n")
            (should (equal redraw (list buffer t)))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ghostel-test-native-pipe-sentinel-redraw-bypasses-inhibition ()
  "Pipe EOF cannot defer its final redraw to a timer that cleanup cancels."
  (let ((buffer (generate-new-buffer " *ghostel-test-native-sentinel-inhibit*"))
        scheduled
        cancelled
        (rendered 0))
    (unwind-protect
        (save-window-excursion
          (set-window-buffer (selected-window) buffer)
          (with-current-buffer buffer
            (setq-local ghostel--term 'term
                        ghostel-kill-buffer-on-exit nil
                        ghostel-exit-functions nil
                        ghostel--redraw-timer nil
                        ghostel--plain-link-detection-timer nil)
            (add-hook 'ghostel-inhibit-redraw-functions
                      (lambda (_buffer) t) nil t)
            (cl-letf (((symbol-function 'process-buffer)
                       (lambda (_process) buffer))
                      ((symbol-function 'ghostel--terminal-live-p)
                       (lambda () t))
                      ((symbol-function 'ghostel--schedule-redraw)
                       (lambda (&rest _args)
                         (setq scheduled t
                               ghostel--redraw-timer 'deferred)))
                      ((symbol-function 'cancel-timer)
                       (lambda (timer) (push timer cancelled)))
                      ((symbol-function 'ghostel--defer-synchronized-output-redraw-p)
                       (lambda (_buffer) nil))
                      ((symbol-function 'ghostel--line-mode-pre-redraw) #'ignore)
                      ((symbol-function 'ghostel--get-render-window)
                       (lambda (_buffer) (selected-window)))
                      ((symbol-function 'ghostel--anchored-windows)
                       (lambda (&rest _args) nil))
                      ((symbol-function 'ghostel--redraw)
                       (lambda (&rest _args) (cl-incf rendered)))
                      ((symbol-function 'ghostel--apply-cursor-style) #'ignore)
                      ((symbol-function 'ghostel--schedule-link-detection) #'ignore)
                      ((symbol-function 'ghostel--viewport-start) #'point-min)
                      ((symbol-function 'ghostel--line-mode-post-redraw) #'ignore)
                      ((symbol-function 'ghostel--detect-password-prompt) #'ignore)
                      ((symbol-function 'ghostel--cancel-password-confirm-timer) #'ignore)
                      ((symbol-function 'ghostel--spinner-stop) #'ignore)
                      ((symbol-function 'ghostel--fake-cursor-clear) #'ignore))
              (ghostel--sentinel 'pipe "finished\n")
              (should (equal (list scheduled cancelled rendered)
                             '(nil nil 1))))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest ghostel-test-native-process-decodes-windows-unibyte-inputs ()
  "Native spawn decodes Windows unibyte process inputs with the ANSI code page."
  :tags '(native windows)
  (skip-unless (ghostel-test--windows-p))
  (let* ((python (ghostel-test--python))
         (acp-coding-system
          (or (coding-system-from-name (format "cp%d" w32-ansi-code-page))
              (ert-fail (format "No coding system for Windows code page %d"
                                w32-ansi-code-page))))
         (unicode-value
          (or (cl-find-if
               (lambda (candidate)
                 (let ((bytes (encode-coding-string candidate acp-coding-system)))
                   (and (not (multibyte-string-p bytes))
                        (seq-some (lambda (char) (> char 127)) bytes)
                        (equal candidate
                               (decode-coding-string bytes acp-coding-system)))))
               '("â" "Ž" "Ж" "Ω" "İ" "א" "ا" "ก" "あ" "中" "한" "€"))
              (ert-fail (format "No non-ASCII fixture for Windows code page %d"
                                w32-ansi-code-page))))
         (unibyte-value
          (encode-coding-string unicode-value acp-coding-system))
         (unicode-directory
          (file-name-as-directory
           (make-temp-file
            (expand-file-name (format "ghostel-%s-" unicode-value)
                              temporary-file-directory)
            t)))
         (unibyte-directory
          (encode-coding-string unicode-directory acp-coding-system))
         (environment-entry (concat "GHOSTEL_ACP_TEST=" unibyte-value))
         (script
          (concat
           "import os, sys\n"
           "ok = (sys.argv[1] == sys.argv[2] and "
           "os.environ.get('GHOSTEL_ACP_TEST') == sys.argv[2] and "
           "os.path.normcase(os.getcwd()) == os.path.normcase(sys.argv[3]))\n"
           "print('GHOSTEL_ACP_OK' if ok else 'GHOSTEL_ACP_BAD')\n")))
    (unwind-protect
        (progn
          (let* ((process-environment
                  (cons environment-entry
                        (ghostel-test--base-process-environment)))
                 (default-directory (ghostel-test--temp-directory))
                 (text
                  (ghostel-test-native-process--command-output
                   (list python "-c" script unibyte-value unicode-value
                         (directory-file-name unicode-directory))
                   (lambda (spawn)
                     (cl-letf (((symbol-function 'expand-file-name)
                                (lambda (&rest _) unibyte-directory)))
                       (funcall spawn))))))
            (should (ghostel-test--terminal-text-line-p "GHOSTEL_ACP_OK" text))))
      (delete-directory unicode-directory t))))

(ert-deftest ghostel-test-native-process-adds-display-for-graphical-frame ()
  "Native env builder mirrors Emacs' DISPLAY fallback for graphical frames."
  :tags '(native)
  (let ((env-command (ghostel-test--env-command)))
    (skip-unless (car env-command))
    (let* ((process-environment (append '("DISPLAY_FOO=1")
                                        (ghostel-test--base-process-environment)))
           (default-directory (ghostel-test--temp-directory))
           (text (ghostel-test-native-process--command-output
                  env-command
                  (lambda (spawn)
                    (cl-letf (((symbol-function 'display-graphic-p)
                               (lambda (&optional _display) t))
                              ((symbol-function 'getenv)
                               (lambda (variable &optional _frame)
                                 (and (string= variable "DISPLAY") ":99"))))
                      (funcall spawn))))))
      (should (ghostel-test--terminal-text-line-p "DISPLAY=:99" text))
      (should (ghostel-test--terminal-text-line-p "DISPLAY_FOO=1" text)))))

(ert-deftest ghostel-test-native-process-does-not-add-display-for-terminal-frame ()
  "Native env builder does not synthesize DISPLAY for non-graphical frames."
  :tags '(native)
  (let ((env-command (ghostel-test--env-command)))
    (skip-unless (car env-command))
    (let* ((process-environment (ghostel-test--base-process-environment))
           (default-directory (ghostel-test--temp-directory))
           (text (ghostel-test-native-process--command-output
                  env-command
                  (lambda (spawn)
                    (cl-letf (((symbol-function 'display-graphic-p)
                               (lambda (&optional _display) nil))
                              ((symbol-function 'getenv)
                               (lambda (variable &optional _frame)
                                 (and (string= variable "DISPLAY") ":99"))))
                      (funcall spawn))))))
      (should-not (ghostel-test--terminal-text-line-prefix-p "DISPLAY=" text)))))

(ert-deftest ghostel-test-native-process-env-first-entry-wins ()
  "Native env builder follows `process-environment' first-entry semantics."
  :tags '(native)
  (let ((env-command (ghostel-test--env-command)))
    (skip-unless (car env-command))
    (let* ((process-environment (append '("GHOSTEL_ENV_TEST_UNSET"
                                          "GHOSTEL_ENV_TEST_UNSET=later"
                                          "GHOSTEL_ENV_TEST_DUP=first"
                                          "GHOSTEL_ENV_TEST_DUP=later")
                                        (ghostel-test--base-process-environment)))
           (default-directory (ghostel-test--temp-directory))
           (text (ghostel-test-native-process--command-output env-command)))
      (should-not (ghostel-test--terminal-text-line-prefix-p
                   "GHOSTEL_ENV_TEST_UNSET=" text))
      (should (ghostel-test--terminal-text-line-p
               "GHOSTEL_ENV_TEST_DUP=first" text))
      (should-not (ghostel-test--terminal-text-line-p
                   "GHOSTEL_ENV_TEST_DUP=later" text)))))

(ert-deftest ghostel-test-native-process-display-unset-suppresses-fallback ()
  "A bare DISPLAY entry suppresses graphical DISPLAY fallback."
  :tags '(native)
  (let ((env-command (ghostel-test--env-command)))
    (skip-unless (car env-command))
    (let* ((process-environment (cons "DISPLAY"
                                      (ghostel-test--base-process-environment)))
           (default-directory (ghostel-test--temp-directory))
           (text (ghostel-test-native-process--command-output
                  env-command
                  (lambda (spawn)
                    (cl-letf (((symbol-function 'display-graphic-p)
                               (lambda (&optional _display) t))
                              ((symbol-function 'getenv)
                               (lambda (variable &optional _frame)
                                 (and (string= variable "DISPLAY") ":99"))))
                      (funcall spawn))))))
      (should-not (ghostel-test--terminal-text-line-prefix-p "DISPLAY=" text)))))

(ert-deftest ghostel-test-native-process-lisp-string-quoting ()
  "Native process event strings do not escape Lisp quoting."
  :tags '(native)
  (let ((ghostel-use-native-pty t)
        (ghostel-test-native-process--evil nil)
        (titles nil)
        (payloads '("plain title"
                    "quoted \") (setq ghostel-test-native-process--evil 'quote) (\" title"
                    "backslash \\\") (setq ghostel-test-native-process--evil 'backslash) (\" title"
                    "newline\n\")\n(setq ghostel-test-native-process--evil 'newline)\n(\" title")))
    (ghostel-test--with-raw-echo-buffer (buf proc)
      (should ghostel--process)
      (cl-letf (((symbol-function 'ghostel--set-title)
                 (lambda (title) (push title titles))))
        (dolist (payload payloads)
          (ghostel--write-pty ghostel--term (concat "\e]2;" payload "\e\\")))
        (ghostel-test--wait-until
         (lambda () (>= (length titles) (length payloads)))
         proc 5)
        (should-not ghostel-test-native-process--evil)
        (should (equal (mapcar (lambda (title)
                                 (replace-regexp-in-string "\n" "" title))
                               payloads)
                       (reverse titles)))))))

;;; ghostel-native-process-test.el ends here
