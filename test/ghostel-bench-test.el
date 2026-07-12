;;; ghostel-bench-test.el --- Pure ERT tests for ghostel-bench helpers -*- lexical-binding: t; -*-

;;; Commentary:

;; Pure unit tests for benchmark helpers: no native module or subprocesses.

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

(ert-deftest ghostel-bench-test-windows-output-driver-is-persistent ()
  "The Windows producer preloads data and serves repeated requests."
  (cl-letf (((symbol-function 'executable-find)
            (lambda (program)
              (and (string= program "powershell") "powershell.exe"))))
    (let ((spec (ghostel-bench--windows-output-driver)))
     (should (equal (car spec) "powershell.exe"))
     (should (member "-NoProfile" spec))
     (should (string-match-p
              "ReadAllBytes.*while.*ReadLine"
              (car (last spec)))))))

(ert-deftest ghostel-bench-test-windows-e2e-reuses-one-native-pty ()
  "Windows E2E timing runs inside one persistent native PTY."
  (let ((setup-count 0)
       (run-count 0))
    (cl-letf (((symbol-function 'ghostel-bench--windows-p)
              (lambda () t))
             ((symbol-function 'ghostel-bench--with-persistent-output)
              (lambda (_data-file native-p detect-p body-fn)
                (cl-incf setup-count)
                (should native-p)
                (should detect-p)
                (funcall body-fn (lambda () (cl-incf run-count)))))
             ((symbol-function 'ghostel-bench--measure)
              (lambda (_name _size _iterations body-fn)
                (funcall body-fn)
                (funcall body-fn))))
     (ghostel-bench--measure-e2e-ghostel "case" "data" t)
     (should (= setup-count 1))
     (should (= run-count 2)))))

;;; ghostel-bench-test.el ends here
