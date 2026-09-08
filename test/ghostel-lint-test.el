;;; ghostel-lint-test.el --- Tests for ghostel lint helpers -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for development-only lint helpers.

;;; Code:

(require 'ghostel-test-helpers)

(let* ((this-file (or load-file-name buffer-file-name
                      (expand-file-name "test/ghostel-lint-test.el")))
       (repo-root (file-name-directory
                   (directory-file-name (file-name-directory this-file)))))
  (load (expand-file-name "tools/ghostel-lint.el" repo-root) nil t))

(ert-deftest ghostel-lint-test-retries-package-install ()
  "Retry dependency installation after a transient archive failure."
  (let ((installed nil)
        (refreshes 0))
    (ghostel-test--without-subr-trampolines
      (cl-letf (((symbol-function 'package-installed-p)
                 (lambda (package &optional _minimum-version)
                   (memq package installed)))
                ((symbol-function 'package-refresh-contents)
                 (lambda (&optional _async)
                   (setq refreshes (1+ refreshes))))
                ((symbol-function 'package-install)
                 (lambda (package &optional _dont-select)
                   (if (and (eq package 'compat) (= refreshes 1))
                       (error "Transient archive failure")
                     (push package installed))))
                ((symbol-function 'sleep-for) #'ignore))
        (ghostel-lint-install-packages 'package-lint 'compat)))
    (should (= refreshes 2))
    (should (memq 'package-lint installed))
    (should (memq 'compat installed))))

(ert-deftest ghostel-lint-test-package-install-exhausts-retries ()
  "Signal the final package error after three failed attempts."
  (let ((refreshes 0))
    (ghostel-test--without-subr-trampolines
      (cl-letf (((symbol-function 'package-installed-p)
                 (lambda (&rest _) nil))
                ((symbol-function 'package-refresh-contents)
                 (lambda (&optional _async)
                   (setq refreshes (1+ refreshes))))
                ((symbol-function 'package-install)
                 (lambda (&rest _) (error "Persistent archive failure")))
                ((symbol-function 'sleep-for) #'ignore))
        (should-error
         (ghostel-lint-install-packages 'package-lint 'compat)
         :type 'error)))
    (should (= refreshes 3))))

(provide 'ghostel-lint-test)
;;; ghostel-lint-test.el ends here
