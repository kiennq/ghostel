;;; ghostel-test-helpers.el --- Shared helpers + runner for ghostel tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Helpers shared across the per-topic test files (ghostel-*-test.el).
;; Also defines the batch runner functions used by the Makefile:
;; `ghostel-test-run-elisp' and `ghostel-test-run-native' select via the
;; `native' ERT tag (set per-test in files that require the Zig module).

;;; Code:

(require 'ert)
(require 'ghostel)
(require 'ghostel-compile)
(require 'ghostel-debug)
(require 'ghostel-eshell)

(declare-function ghostel--cleanup-temp-paths "ghostel")

(defmacro ghostel-test--without-subr-trampolines (&rest body)
  "Run BODY with native trampolines disabled on supported Emacs versions."
  `(let ((native-comp-enable-subr-trampolines nil)
         (comp-enable-subr-trampolines nil))
     ,@body))

(defun ghostel-test--fixture-dir (name)
  "Return a host-valid absolute test directory named NAME."
  (file-name-as-directory
   (expand-file-name name temporary-file-directory)))

(defun ghostel-test--fixture-path (dir name)
  "Return absolute path for NAME within DIR."
  (expand-file-name name dir))

(defun ghostel-test--ghostel-source-path ()
  "Return the source path for `ghostel.el'."
  (let ((path (locate-library "ghostel")))
    (if (and path (string-suffix-p ".elc" path))
        (substring path 0 -1)
      path)))

(defun ghostel-test--ghostel-source ()
  "Return the contents of `ghostel.el' as a string."
  (with-temp-buffer
    (insert-file-contents (ghostel-test--ghostel-source-path))
    (buffer-string)))

(defun ghostel-test--source-pos (source marker)
  "Return the position of MARKER within SOURCE."
  (string-match-p (regexp-quote marker) source))

(defmacro ghostel-test--with-compile-buffer (var &rest body)
  "Run BODY in a fresh ghostel-mode buffer bound to VAR."
  (declare (indent 1))
  `(let ((,var (generate-new-buffer " *ghostel-test-compile*"))
         (inhibit-message t))
     (unwind-protect
         (with-current-buffer ,var
           (ghostel-mode)
           ,@body)
       (kill-buffer ,var))))

(defun ghostel-test--row0 (term)
  "Return the first row text from TERM's scrollback."
  (let ((text (or (ghostel--copy-all-text term) "")))
    (string-trim-right (car (split-string text "\n")))))

(defun ghostel-test--cursor (term)
  "Return (COL . ROW) cursor position for TERM via redraw."
  (ghostel--redraw term)
  ghostel--cursor-pos)

(defun ghostel-test--wait-for (proc pred &optional timeout)
  "Poll PROC until PRED returns non-nil, or TIMEOUT seconds (default 5).
Signal an ERT failure if TIMEOUT is reached or PROC exits before PRED
succeeds."
  (let* ((timeout (or timeout 5))
         (deadline (+ (float-time) timeout))
         result)
    (while (and (not (setq result (funcall pred)))
                (< (float-time) deadline)
                (process-live-p proc))
      (accept-process-output proc 0.05))
    (unless result
      (ert-fail
       (if (process-live-p proc)
           (format "Timed out after %.1fs waiting for predicate" timeout)
         (format "Process %s exited before predicate succeeded" (process-name proc)))))
    result))

(defun ghostel-test-run-elisp ()
  "Run only pure Elisp tests (no native module required)."
  (ert-run-tests-batch-and-exit '(not (tag native))))

(defun ghostel-test-run-native ()
  "Run only tests that require the native module."
  (ert-run-tests-batch-and-exit '(tag native)))

(defun ghostel-test-run ()
  "Run all ghostel tests."
  (ert-run-tests-batch-and-exit "^ghostel-test-"))

(provide 'ghostel-test-helpers)
;;; ghostel-test-helpers.el ends here
