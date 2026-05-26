;;; ghostel-bench-test.el --- Pure ERT tests for ghostel-bench helpers -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for the Windows ConPTY benchmark shell spec.
;; These are pure unit tests: no native module and no subprocesses.

;;; Code:

(require 'ert)
(require 'cl-lib)

;; Load bench/ghostel-bench.el without its runtime dependencies by stubbing
;; the symbols it forward-declares from the ghostel native module.
(defvar ghostel-enable-file-detection nil)
(defvar ghostel-enable-url-detection nil)
(defvar ghostel-exit-functions nil)
(defvar ghostel-full-redraw nil)
(defvar ghostel-kill-buffer-on-exit nil)
(defvar ghostel-plain-link-detection-delay 0)
(defvar ghostel-shell nil)
(defvar ghostel-shell-integration nil)

(let* ((this-file (or load-file-name buffer-file-name
                     (expand-file-name "test/ghostel-bench-test.el")))
       (repo-root (file-name-directory (directory-file-name
                                        (file-name-directory this-file))))
       (bench-file (expand-file-name "bench/ghostel-bench.el" repo-root)))
  (unless (featurep 'ghostel-bench)
    (load bench-file nil t)))

;; ---------------------------------------------------------------------------
;; Helper: simulate a data-file path with no actual file needed
;; ---------------------------------------------------------------------------

(defconst ghostel-bench-test--data-file "/c/tmp/test-data.bin"
  "Synthetic data-file argument used across tests.")

;; ---------------------------------------------------------------------------
;; Windows cat shell spec
;; ---------------------------------------------------------------------------

(ert-deftest ghostel-bench-test-cat-spec ()
  "Cat spec starts with cat (or found path) and passes the data file."
  (let ((spec (ghostel-bench--windows-output-shell
               ghostel-bench-test--data-file)))
    (should (stringp (car spec)))
    (should (string-match-p "cat" (car spec)))
    (should (cl-some (lambda (s)
                       (and (stringp s)
                            (string-match-p "test-data\\.bin" s)))
                     (cdr spec)))))

(ert-deftest ghostel-bench-test-cat-spec-finds-git-cat ()
  "Cat spec falls back to Git for Windows when cat is not on variable `exec-path'."
  (let* ((program-files (make-temp-file "ghostel-bench-program-files-" t))
         (cat-dir (expand-file-name "Git/usr/bin" program-files))
         (expected (expand-file-name "cat.exe" cat-dir))
         (process-environment (cons (format "ProgramFiles=%s" program-files)
                                    process-environment)))
    (unwind-protect
        (progn
          (make-directory cat-dir t)
          (write-region "" nil expected nil 'silent)
          (cl-letf (((symbol-function 'executable-find)
                     (lambda (_) nil)))
            (should (equal (car (ghostel-bench--windows-output-shell
                                 ghostel-bench-test--data-file))
                           expected))))
      (delete-directory program-files t))))

(ert-deftest ghostel-bench-test-cat-spec-errors-when-cat-is-missing ()
  "Cat spec fails fast instead of starting a missing command."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (_) nil))
            ((symbol-function 'ghostel-bench--windows-cat-candidates)
             (lambda () nil)))
    (should-error
     (ghostel-bench--windows-output-shell ghostel-bench-test--data-file)
     :type 'error)))

;;; ghostel-bench-test.el ends here
