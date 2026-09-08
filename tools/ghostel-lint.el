;;; ghostel-lint.el --- Lint helpers for the ghostel Makefile -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Entry points for the Makefile's lint targets.  Development tooling,
;; not part of the ghostel package.

;;; Code:

(require 'checkdoc)
(require 'package)
(require 'seq)

(defun ghostel-lint-install-packages (&rest packages)
  "Install PACKAGES, retrying transient archive failures up to three times."
  (let ((attempt 0)
        last-error)
    (while (and (< attempt 3)
                (not (seq-every-p #'package-installed-p packages)))
      (setq attempt (1+ attempt))
      (condition-case err
          (progn
            (package-refresh-contents)
            (dolist (package packages)
              (unless (package-installed-p package)
                (package-install package))))
        (error
         (setq last-error err)
         (message "Package setup attempt %d/3 failed: %s"
                  attempt (error-message-string err))))
      (when (and (< attempt 3)
                 (not (seq-every-p #'package-installed-p packages)))
        (sleep-for attempt)))
    (unless (seq-every-p #'package-installed-p packages)
      (if last-error
          (signal (car last-error) (cdr last-error))
        (error "Package setup failed for %S" packages)))))

(defun ghostel-lint--files ()
  "Return and consume the files named on the command line.
Leaving them would make Emacs visit each as a buffer afterwards."
  (prog1 command-line-args-left
    (setq command-line-args-left nil)))

(defun ghostel-lint-checkdoc ()
  "Run checkdoc over the files named on the command line."
  (let ((sentence-end-double-space nil)
        (checkdoc-proper-noun-list nil)
        (checkdoc-verb-check-experimental-flag nil)
        (ok t))
    (dolist (file (ghostel-lint--files))
      ;; checkdoc reports through *Warnings*, not a return value.
      (ignore-errors (kill-buffer "*Warnings*"))
      (let ((inhibit-message t))
        (checkdoc-file file))
      (when (get-buffer "*Warnings*")
        (setq ok nil)
        (with-current-buffer "*Warnings*"
          (message "%s" (buffer-string)))))
    (unless ok (kill-emacs 1))))

(defun ghostel-lint-docquotes ()
  "Check quoting of all-caps words in the files named on the command line.
Back/front quotes are for linking to elisp symbols, not argument names."
  (let ((ok t))
    (dolist (file (ghostel-lint--files))
      (with-temp-buffer
        (insert-file-contents file)
        (setq case-fold-search nil)
        (goto-char (point-min))
        (while (re-search-forward "`[A-Z_]+'" nil t)
          (setq ok nil)
          (message "%s:%d:%d: Only use back/front quotes to link to top-level elisp symbols (%s)"
                   file (line-number-at-pos)
                   (1+ (- (match-beginning 0) (line-beginning-position)))
                   (match-string 0)))))
    (unless ok (kill-emacs 1))))

(provide 'ghostel-lint)
;;; ghostel-lint.el ends here
