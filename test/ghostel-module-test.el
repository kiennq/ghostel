;;; ghostel-module-test.el --- Tests for ghostel: module -*- lexical-binding: t; -*-

;;; Commentary:

;; Native module download, install, platform tag.

;;; Code:

(require 'ghostel-test-helpers)

(ert-deftest ghostel-test-module-download-url-uses-requested-version ()
  "Requested download versions are decoupled from the package version."
  (let ((ghostel-github-release-url "https://example.invalid/releases"))
    (cl-letf (((symbol-function 'ghostel--module-asset-name)
               (lambda () "ghostel-module-x86_64-linux.so")))
      (should (equal "https://example.invalid/releases/download/v0.7.1/ghostel-module-x86_64-linux.so"
                     (ghostel--module-download-url "0.7.1"))))))

(ert-deftest ghostel-test-module-download-url-uses-latest-release ()
  "A nil download version uses the latest release asset."
  (let ((ghostel-github-release-url "https://example.invalid/releases"))
    (cl-letf (((symbol-function 'ghostel--module-asset-name)
               (lambda () "ghostel-module-x86_64-linux.so")))
      (should (equal "https://example.invalid/releases/latest/download/ghostel-module-x86_64-linux.so"
                     (ghostel--module-download-url nil))))))

(ert-deftest ghostel-test-download-module-defaults-to-latest-release ()
  "Automatic downloads use latest release archives by default."
  (let* ((ghostel--minimum-module-version "0.7.1")
         (captured-version :unset)
         (download-dest nil)
         (published nil)
         (dir (make-temp-file "ghostel-dl-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--module-download-url)
                   (lambda (&optional version)
                     (setq captured-version version)
                     "https://example.invalid/releases/latest/download/ghostel-module-x86_64-linux.tar.xz"))
                   ((symbol-function 'ghostel--download-file)
                    (lambda (_url dest)
                      (setq download-dest dest)
                      t))
                   ((symbol-function 'ghostel--publish-downloaded-module-archive)
                    (lambda (archive publish-dir)
                      (setq published (list archive publish-dir))
                      t))
                   ((symbol-function 'delete-file)
                    (lambda (&rest _) nil))
                   ((symbol-function 'message)
                    (lambda (&rest _))))
          (should (ghostel--download-module dir))
          (should (null captured-version))
          (should (equal (list (downcase download-dest)
                               (downcase (file-name-as-directory
                                          (expand-file-name dir))))
                         (mapcar #'downcase published)))
          (should (equal (downcase (expand-file-name
                                    "ghostel-module-x86_64-linux.tar.xz"
                                    dir))
                         (downcase download-dest))))
      (when (file-exists-p dir)
        (delete-directory dir t)))))

(ert-deftest ghostel-test-download-module-default-uses-requested-version ()
  "Downloads prompt for and pass through a release version by default."
  (let ((ghostel--minimum-module-version "0.7.1")
        (captured-version :unset)
        (captured-latest nil))
    (let ((native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'locate-library)
                 (lambda (_) "/ghostel/ghostel.el"))
                ((symbol-function 'file-exists-p)
                 (lambda (&rest _) nil))
                ((symbol-function 'ghostel--read-module-download-version)
                 (lambda () "0.8.0"))
                ((symbol-function 'ghostel--download-module)
                 (lambda (_dir &optional version latest-release)
                   (setq captured-version version
                         captured-latest latest-release)
                   ;; Bail before `module-load' — its mock can't be
                   ;; intercepted from native-compiled callers in Emacs 31.
                   (throw 'ghostel-test-bail nil)))
                ((symbol-function 'message)
                 (lambda (&rest _))))
        (catch 'ghostel-test-bail
          (ghostel-download-module nil))
        (should (equal "0.8.0" captured-version))
        (should-not captured-latest)))))

(ert-deftest ghostel-test-download-module-prefix-uses-latest ()
  "Prefix downloads the latest release without prompting for a version."
  (let ((captured-version :unset)
        (captured-latest nil))
    (let ((native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'locate-library)
                 (lambda (_) "/ghostel/ghostel.el"))
                ((symbol-function 'file-exists-p)
                 (lambda (&rest _) nil))
                ((symbol-function 'ghostel--read-module-download-version)
                 (lambda ()
                   (ert-fail "Prefix download unexpectedly prompted for a version")))
                ((symbol-function 'ghostel--download-module)
                 (lambda (_dir &optional version latest-release)
                   (setq captured-version version
                         captured-latest latest-release)
                   ;; Bail before `module-load' — its mock can't be
                   ;; intercepted from native-compiled callers in Emacs 31.
                   (throw 'ghostel-test-bail nil)))
                ((symbol-function 'message)
                 (lambda (&rest _))))
        (catch 'ghostel-test-bail
          (ghostel-download-module '(4)))
        (should (null captured-version))
        (should captured-latest)))))

(ert-deftest ghostel-test-download-module-keeps-live-buffers-open-before-prompt ()
  "Interactive downloads do not terminate sessions before prompting."
  (cl-letf (((symbol-function 'ghostel--live-buffers)
             (lambda () '(session-a session-b)))
            ((symbol-function 'ghostel--close-live-buffers)
             (lambda (&rest _)
               (ert-fail "Closed live buffers before the download")))
            ((symbol-function 'ghostel--read-module-download-version)
             (lambda ()
               (throw 'ghostel-test-bail nil))))
    (catch 'ghostel-test-bail
      (ghostel-download-module nil))))

(ert-deftest ghostel-test-download-file-is-atomic ()
  "`ghostel--download-file' writes via a temp sibling and renames into place.
The destination inode must change so any Emacs that has the previous
file mmap'd keeps a valid mapping (issue #247)."
  (let* ((dir (make-temp-file "ghostel-dl-" t))
         (dest (expand-file-name "ghostel-module.so" dir)))
    (unwind-protect
        (progn
          (with-temp-file dest (insert "old-payload"))
          (set-file-modes dest #o644)
          (let ((old-inode (file-attribute-inode-number (file-attributes dest))))
            (cl-letf (((symbol-function 'url-retrieve-synchronously)
                       (lambda (&rest _)
                         (let ((buf (generate-new-buffer " *ghostel-fake-http*")))
                           (with-current-buffer buf
                             (set-buffer-multibyte nil)
                             (insert "HTTP/1.1 200 OK\r\n\r\nnew-payload"))
                           buf))))
              (should (ghostel--download-file "https://example.invalid/x" dest)))
            (should (equal "new-payload"
                           (with-temp-buffer
                             (set-buffer-multibyte nil)
                             (insert-file-contents-literally dest)
                             (buffer-string))))
            (let ((new-inode (file-attribute-inode-number (file-attributes dest))))
              (should-not (equal old-inode new-inode)))
            ;; No stale temp files left behind on success.
            (dolist (f (directory-files dir nil "\\." t))
              (should-not (string-match-p "\\.tmp\\." f)))))
      (when (file-exists-p dir)
        (delete-directory dir t)))))

(ert-deftest ghostel-test-download-module-creates-missing-directory ()
  "`ghostel--download-module' creates DIR before writing the module."
  (let* ((parent (make-temp-file "ghostel-dl-parent-" t))
         (dir (expand-file-name "sub/dir/" parent))
         (asset "ghostel-module-x86_64-linux.tar.xz")
         (download-dest nil)
         (published nil))
    (unwind-protect
        (progn
          (should-not (file-exists-p dir))
           (cl-letf (((symbol-function 'ghostel--module-download-url)
                      (lambda (&optional _version)
                        (format "https://example.invalid/releases/latest/download/%s" asset)))
                     ((symbol-function 'ghostel--download-file)
                      (lambda (_url dest)
                        (setq download-dest dest)
                        (should (file-directory-p (file-name-directory dest)))
                        t))
                     ((symbol-function 'ghostel--publish-downloaded-module-archive)
                      (lambda (archive publish-dir)
                        (setq published (list archive publish-dir))
                        t))
                     ((symbol-function 'delete-file)
                      (lambda (&rest _) nil)))
             (should (ghostel--download-module dir nil t)))
           (should (file-directory-p dir))
           (should (equal (downcase (expand-file-name asset dir))
                          (downcase download-dest)))
           (should (equal (list (downcase download-dest)
                                (downcase (file-name-as-directory
                                           (expand-file-name dir))))
                          (list (downcase (car published))
                                (downcase (cadr published))))))
      (when (file-exists-p parent)
        (delete-directory parent t)))))

(ert-deftest ghostel-test-download-file-cleans-up-on-failure ()
  "A failed HTTP response leaves no stale temp file behind."
  (let* ((dir (make-temp-file "ghostel-dl-" t))
         (dest (expand-file-name "ghostel-module.so" dir)))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'url-retrieve-synchronously)
                     (lambda (&rest _)
                       (let ((buf (generate-new-buffer " *ghostel-fake-http*")))
                         (with-current-buffer buf
                           (set-buffer-multibyte nil)
                           (insert "HTTP/1.1 404 Not Found\r\n\r\nnope"))
                         buf))))
            (should-not (ghostel--download-file "https://example.invalid/x" dest)))
          (should-not (file-exists-p dest))
          (dolist (f (directory-files dir nil "\\." t))
            (should-not (string-match-p "\\.tmp\\." f))))
      (when (file-exists-p dir)
        (delete-directory dir t)))))

(ert-deftest ghostel-test-module-directory-defaults-to-resource-root ()
  "When `ghostel-module-directory' is nil, the resource root is used."
  (let ((ghostel-module-directory nil))
    (cl-letf (((symbol-function 'ghostel--resource-root)
               (lambda () "/pkg/ghostel/")))
      (should (equal (downcase (file-name-as-directory
                                (expand-file-name "/pkg/ghostel/")))
                     (downcase (ghostel--module-directory)))))))

(ert-deftest ghostel-test-module-directory-honours-custom-value ()
  "When set, `ghostel-module-directory' takes precedence."
  (let ((ghostel-module-directory "~/custom/ghostel/"))
    (cl-letf (((symbol-function 'ghostel--resource-root)
               (lambda () "/pkg/ghostel/")))
      (should (equal (downcase (file-name-as-directory
                                (expand-file-name "~/custom/ghostel/")))
                     (downcase (ghostel--module-directory)))))))

(ert-deftest ghostel-test-download-module-targets-custom-directory ()
  "Interactive download writes into `ghostel-module-directory' when set."
  (let ((ghostel-module-directory "/custom/dir/")
        (captured-dir nil))
    (let ((native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'ghostel--resource-root)
                 (lambda () "/pkg/ghostel/"))
                ((symbol-function 'file-exists-p)
                 (lambda (&rest _) nil))
                ((symbol-function 'make-directory)
                 (lambda (&rest _)))
                ((symbol-function 'ghostel--read-module-download-version)
                 (lambda () nil))
                ((symbol-function 'ghostel--download-module)
                 (lambda (dir &optional _v _l)
                   (setq captured-dir dir)
                   (throw 'ghostel-test-bail nil)))
                ((symbol-function 'message)
                 (lambda (&rest _))))
        (catch 'ghostel-test-bail
          (ghostel-download-module nil))
        (should (equal (downcase (file-name-as-directory
                                  (expand-file-name "/custom/dir/")))
                       (downcase captured-dir)))))))

(ert-deftest ghostel-test-load-module-looks-in-custom-directory ()
  "`ghostel--load-module' loads the module from `ghostel-module-directory'."
  (let* ((ghostel-module-directory "/custom/dir/")
         (loaded-path nil)
         (had-feat (featurep 'ghostel-module))
         (saved-new (and (fboundp 'ghostel--new)
                         (symbol-function 'ghostel--new))))
    (unwind-protect
        (progn
          (when had-feat
            (setq features (delq 'ghostel-module features)))
          (when saved-new
            (fmakunbound 'ghostel--new))
          (cl-letf (((symbol-function 'ghostel--resource-root)
                     (lambda () "/pkg/ghostel/"))
                    ((symbol-function 'file-exists-p)
                     (lambda (path)
                       (string-prefix-p (expand-file-name "/custom/dir/") path)))
                    ((symbol-function 'module-load)
                     (lambda (path) (setq loaded-path path)))
                    ((symbol-function 'ghostel--check-module-version)
                     (lambda (&rest _))))
            (ghostel--load-module)))
      (when saved-new
        (fset 'ghostel--new saved-new))
      (when had-feat
        (cl-pushnew 'ghostel-module features)))
    (should loaded-path)
    (should (string-prefix-p (expand-file-name "/custom/dir/")
                             loaded-path))))

(ert-deftest ghostel-test-compile-module-invokes-zig-build-with-prefix ()
  "Source compilation runs zig build against a temporary install prefix."
  (let* ((source-dir (ghostel-test--fixture-dir "ghostel-build"))
         (dest-dir (ghostel-test--fixture-dir "ghostel-modules"))
         (build-dir (file-name-as-directory
                     (expand-file-name ".ghostel-build/" dest-dir)))
         (default-directory nil)
         (messages nil)
         (warnings nil)
         (process-invocation nil))
    (ghostel-test--without-subr-trampolines
      (cl-letf (((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages)))
                ((symbol-function 'display-warning)
                 (lambda (&rest args)
                   (push args warnings)))
                ((symbol-function 'ghostel--resource-root)
                 (lambda () source-dir))
                ((symbol-function 'ghostel--make-module-build-dir)
                 (lambda (_dest-dir) build-dir))
                ((symbol-function 'ghostel--publish-built-module-artifacts)
                 (lambda (&rest _) t))
                ((symbol-function 'process-file)
                 (lambda (program infile buffer display &rest args)
                   (setq process-invocation
                         (list program infile buffer display args default-directory))
                   0)))
        (should (ghostel--compile-module dest-dir))
        (should (equal
                 (list "zig" nil "*ghostel-build*" nil
                       (list "build" "--prefix" build-dir
                             "-Doptimize=ReleaseFast" "-Dcpu=baseline")
                       source-dir)
                 process-invocation))
        (should-not warnings)))))

(ert-deftest ghostel-test-compile-module-moves-to-dest-dir ()
  "Compilation publishes the produced runtime bundle into DEST-DIR."
  (let ((published nil)
        (warnings nil)
        (build-dir "/custom/dir/.ghostel-build/"))
    (ghostel-test--without-subr-trampolines
      (cl-letf (((symbol-function 'ghostel--resource-root)
                (lambda () "/src/ghostel/"))
               ((symbol-function 'ghostel--make-module-build-dir)
                (lambda (_dest-dir) build-dir))
                ((symbol-function 'message) (lambda (&rest _)))
                ((symbol-function 'display-warning)
                 (lambda (type &rest args)
                   (when (eq type 'ghostel)
                     (push args warnings))))
                ((symbol-function 'process-file)
                 (lambda (&rest _) 0))
                ((symbol-function 'ghostel--publish-built-module-artifacts)
                 (lambda (source-dir dest-dir)
                   (setq published (list source-dir dest-dir)))))
        (should (ghostel--compile-module "/custom/dir/"))
        (should-not warnings)
        (should (equal (list (downcase (expand-file-name "bin" build-dir))
                             (downcase "/custom/dir/"))
                       (mapcar #'downcase published)))))))

(ert-deftest ghostel-test-compile-module-warns-when-build-missing ()
  "When the build returns success but no module file appears, warn."
  (let ((warnings nil))
    (let ((native-comp-enable-subr-trampolines t))
      (cl-letf (((symbol-function 'ghostel--resource-root)
                 (lambda () "/src/ghostel/"))
                ((symbol-function 'ghostel--make-module-build-dir)
                 (lambda (_dest-dir) "/src/ghostel/.ghostel-build/"))
                ((symbol-function 'file-exists-p)
                 (lambda (_) nil))
                ((symbol-function 'message) (lambda (&rest _)))
                ((symbol-function 'display-warning)
                 (lambda (type &rest args)
                   (when (eq type 'ghostel)
                     (push args warnings))))
                ((symbol-function 'process-file)
                 (lambda (&rest _) 0)))
        (ghostel--compile-module "/src/ghostel/")
        (should warnings)))))

(ert-deftest ghostel-test-module-compile-command-uses-zig-build-prefix ()
  "Interactive compilation uses zig build with a temporary install prefix."
  (let ((compile-invocation nil)
        (finish-args nil)
        (default-directory nil)
        (ghostel-module-directory nil))
    (let ((native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'ghostel--resource-root)
                 (lambda () "/src/ghostel/"))
                ((symbol-function 'ghostel--make-module-build-dir)
                 (lambda (_dest-dir) "/src/ghostel/.ghostel-build/"))
                ((symbol-function 'ghostel--install-built-module-on-finish)
                 (lambda (buf build-dir dest-dir)
                   (setq finish-args (list buf build-dir dest-dir))))
                ((symbol-function 'compilation-start)
                 (lambda (command &optional mode name-function &rest _)
                   (setq compile-invocation
                         (list command mode name-function default-directory))
                   (current-buffer))))
        (ghostel-module-compile)
        (should (equal (format "zig build --prefix %s -Doptimize=ReleaseFast -Dcpu=baseline"
                               (shell-quote-argument
                                (expand-file-name "/src/ghostel/.ghostel-build/")))
                       (nth 0 compile-invocation)))
        (should (eq #'ghostel-module-compilation-mode (nth 1 compile-invocation)))
        (should (eq #'ghostel--module-compilation-buffer-name
                    (nth 2 compile-invocation)))
        (should (equal "/src/ghostel/" (nth 3 compile-invocation)))
        (should (eq (current-buffer) (nth 0 finish-args)))
        (should (equal "/src/ghostel/.ghostel-build/" (nth 1 finish-args)))
        (should (equal (downcase (expand-file-name "/src/ghostel/"))
                       (downcase (nth 2 finish-args))))))))

(ert-deftest ghostel-test-module-compile-installs-when-dest-differs ()
  "Interactive compile installs the built module into `ghostel-module-directory'.
A buffer-local `compilation-finish-functions' handler publishes the
runtime bundle from the temporary install prefix."
  (let* ((compile-buf (generate-new-buffer " *ghostel-test-compile*"))
         (build-dir "/custom/dir/.ghostel-build/")
         (published nil)
         (default-directory nil)
         (ghostel-module-directory "/custom/dir/"))
    (unwind-protect
        (ghostel-test--without-subr-trampolines
          (cl-letf (((symbol-function 'ghostel--resource-root)
                     (lambda () "/src/ghostel/"))
                    ((symbol-function 'ghostel--make-module-build-dir)
                     (lambda (_dest-dir) build-dir))
                    ((symbol-function 'compilation-start)
                     (lambda (_command mode _name-function &rest _)
                       (with-current-buffer compile-buf
                         (funcall mode))
                       compile-buf))
                    ((symbol-function 'ghostel--publish-built-module-artifacts)
                     (lambda (source-dir dest-dir)
                       (setq published (list source-dir dest-dir))))
                    ((symbol-function 'message) (lambda (&rest _))))
            (ghostel-module-compile)
            (with-current-buffer compile-buf
              (should (local-variable-p 'compilation-finish-functions))
              (should (equal build-dir ghostel--module-compile-build-dir))
              (should (equal (expand-file-name "/custom/dir/")
                             ghostel--module-compile-dest-dir)))
            ;; Simulate compilation completion.
            (ghostel--install-built-module-after-compilation compile-buf "finished\n")
            (should (equal (list (downcase (expand-file-name "bin" build-dir))
                                 (downcase (expand-file-name "/custom/dir/")))
                           (mapcar #'downcase published)))))
      (when (buffer-live-p compile-buf)
        (kill-buffer compile-buf)))))

(ert-deftest ghostel-test-module-compile-records-install-when-dest-is-package-dir ()
  "`ghostel-module-compile' always installs from its temporary prefix."
  (let ((finish-args nil)
        (default-directory nil)
        (ghostel-module-directory nil))
    (let ((native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'ghostel--resource-root)
                 (lambda () "/src/ghostel/"))
                ((symbol-function 'ghostel--make-module-build-dir)
                 (lambda (_dest-dir) "/src/ghostel/.ghostel-build/"))
                ((symbol-function 'ghostel--install-built-module-on-finish)
                 (lambda (buf build-dir dest-dir)
                   (setq finish-args (list buf build-dir dest-dir))))
                ((symbol-function 'compilation-start)
                 (lambda (&rest _) (current-buffer))))
        (ghostel-module-compile)
        (should (eq (current-buffer) (nth 0 finish-args)))
        (should (equal "/src/ghostel/.ghostel-build/" (nth 1 finish-args)))
        (should (equal (downcase (expand-file-name "/src/ghostel/"))
                      (downcase (nth 2 finish-args))))))))

(ert-deftest ghostel-test-module-compile-recompile-installs-built-runtime ()
  "`ghostel-module-compile' installs artifacts again after `recompile'."
  (skip-unless (executable-find "sh"))
  (let* ((root (make-temp-file "ghostel-module-recompile" t))
         (dest-dir (file-name-as-directory (expand-file-name "module" root)))
         (counter (expand-file-name "counter" root))
         (loader-name (concat "dyn-loader-module" module-file-suffix))
         (module-name (concat "ghostel-module" module-file-suffix))
         (final (expand-file-name module-name dest-dir))
         (compile-buffer-name " *ghostel-module-recompile*")
         (script (expand-file-name "write-module.el" root))
         (emacs (expand-file-name invocation-name invocation-directory))
         (compilation-ask-about-save nil)
         (ghostel-module-directory dest-dir)
         (ghostel-module-compile-command
          (format "sh -c %s sh %%s"
                  (shell-quote-argument
                   (format (concat "n=$(($(cat %s 2>/dev/null || echo 0)+1)); "
                                   "printf \"$n\" > %s; "
                                   "mkdir -p \"$1/bin\"; "
                                   "printf '{\"loader_abi\":1,\"module_path\":\"%s\"}' > \"$1/bin/ghostel-module.json\"; "
                                   "printf \"loader-$n\" > \"$1/bin/%s\"; "
                                   "printf \"module-$n\" > \"$1/bin/%s\"")
                           (shell-quote-argument counter)
                           (shell-quote-argument counter)
                           module-name
                           loader-name
                           module-name)))))
    (cl-labels ((read-file (path)
                 (with-temp-buffer
                   (insert-file-contents path)
                   (buffer-string)))
               (wait-for-module (expected)
                 (let ((deadline (+ (float-time) 5.0)))
                   (while (and (< (float-time) deadline)
                               (not (and (file-exists-p final)
                                         (equal expected (read-file final)))))
                     (accept-process-output nil 0.05))
                   (should (file-exists-p final))
                   (should (equal expected (read-file final))))))
      (cl-letf (((symbol-function 'ghostel--resource-root)
                (lambda () root))
               ((symbol-function 'ghostel--module-compilation-buffer-name)
                (lambda (_mode-name) compile-buffer-name)))
        (unwind-protect
           (let ((inhibit-message t))
             (ghostel-module-compile)
             (wait-for-module "module-1")
             (with-current-buffer compile-buffer-name
               (recompile))
             (wait-for-module "module-2"))
          (when-let* ((buf (get-buffer compile-buffer-name)))
            (kill-buffer buf))
          (delete-directory root t))))))

(ert-deftest ghostel-test-module-version-match ()
  "Test that version check does nothing when module meets minimum."
  (let ((warned nil)
        (ghostel--minimum-module-version "0.2.0"))
    (cl-letf (((symbol-function 'ghostel--module-version)
               (lambda () "0.2.0"))
              ((symbol-function 'display-warning)
               (lambda (&rest _) (setq warned t))))
      (ghostel--check-module-version "/tmp")
      (should-not warned))))

(ert-deftest ghostel-test-module-version-mismatch ()
  "Test that version check warns when module is below minimum.
At load time (PROMPT-USER nil) the warning fires but `ghostel--ensure-module'
must NOT be called — that path can prompt or download (issue #231).
At an interactive entry point (PROMPT-USER t) it does run."
  (let ((ghostel--minimum-module-version "0.2.0"))
    (cl-letf (((symbol-function 'ghostel--module-version)
               (lambda () "0.1.0")))
      (let ((warned nil)
            (ensure-called nil))
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (&rest _) (setq warned t)))
                  ((symbol-function 'ghostel--ensure-module)
                   (lambda (dir) (setq ensure-called dir))))
          (ghostel--check-module-version "/tmp")
          (should warned)
          (should-not ensure-called)))
      (let ((warned nil)
            (ensure-called nil))
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (&rest _) (setq warned t)))
                  ((symbol-function 'ghostel--ensure-module)
                   (lambda (dir) (setq ensure-called dir))))
          (ghostel--check-module-version "/tmp" t)
          (should warned)
          (should (equal "/tmp" ensure-called)))))))

(ert-deftest ghostel-test-load-module-no-prompt-at-load-time ()
  "Loading ghostel must never trigger the auto-install path (issue #231).
At load time `ghostel--load-module' must not invoke
`ghostel--ensure-module' or any of its install paths.  Module
installation only happens at interactive entry points
\(`ghostel', `ghostel-download-module', `ghostel-module-compile').

The early-out in `ghostel--load-module' bails when the module is
already loaded, so this test temporarily hides
`ghostel--new' and the `ghostel-module' feature flag to force the
missing-file code path, then restores them."
  (let* ((tmp (make-temp-file "ghostel-test-no-mod" t))
         (ghostel-module-auto-install 'ask)
         (calls '())
         (had-feat (featurep 'ghostel-module))
         (saved-new (and (fboundp 'ghostel--new)
                         (symbol-function 'ghostel--new))))
    (unwind-protect
        (progn
          (when had-feat
            (setq features (delq 'ghostel-module features)))
          (when saved-new
            (fmakunbound 'ghostel--new))
          (cl-letf (((symbol-function 'ghostel--resource-root)
                     (lambda () tmp))
                    ((symbol-function 'ghostel--ensure-module)
                     (lambda (&rest _) (push 'ensure calls)))
                    ((symbol-function 'read-char-choice)
                     (lambda (&rest _) (push 'prompt calls) ?s))
                    ((symbol-function 'ghostel--download-module)
                     (lambda (&rest _) (push 'download calls) nil))
                    ((symbol-function 'ghostel--compile-module)
                     (lambda (&rest _) (push 'compile calls) nil))
                    ((symbol-function 'display-warning)
                     (lambda (&rest _) nil)))
            (ghostel--load-module)
            (ghostel--load-module nil)))
      (delete-directory tmp t)
      (when saved-new
        (fset 'ghostel--new saved-new))
      (when had-feat
        (cl-pushnew 'ghostel-module features)))
    (should (null calls))))

(ert-deftest ghostel-test-module-version-newer-than-minimum ()
  "Test that version check does nothing when module exceeds minimum."
  (let ((warned nil)
        (ghostel--minimum-module-version "0.2.0"))
    (cl-letf (((symbol-function 'ghostel--module-version)
               (lambda () "0.3.0"))
              ((symbol-function 'display-warning)
               (lambda (&rest _) (setq warned t))))
      (ghostel--check-module-version "/tmp")
      (should-not warned))))

(ert-deftest ghostel-test-load-module-prompts-when-loaded-but-stale ()
  "Stale already-loaded module triggers a prompt at interactive entry.
The load-time version check only warns; interactive entry must offer
the install dialog when the embedded module version is too old."
  (let* ((tmp (make-temp-file "ghostel-test-loaded-stale" t))
         (ghostel-module-directory tmp)
         (ghostel--minimum-module-version "0.25.0")
         (system-type 'gnu/linux)
         (warned nil)
         (ensure-calls nil)
         (had-feat (featurep 'ghostel-module))
         (had-dyn-feat (featurep 'dyn-loader-module))
         (runtime-ready t))
    (unwind-protect
        (progn
           ;; Pretend the (stale) module is already loaded.
           (cl-pushnew 'ghostel-module features)
           (cl-pushnew 'dyn-loader-module features)
           (cl-letf (((symbol-function 'ghostel--native-runtime-ready-p)
                      (lambda () runtime-ready))
                     ((symbol-function 'ghostel--module-version)
                      (lambda () "0.20.0"))
                    ((symbol-function 'ghostel--ensure-module)
                     (lambda (dir) (push dir ensure-calls)))
                    ((symbol-function 'display-warning)
                     (lambda (&rest _) (setq warned t))))
            (ghostel--load-module t)
            (should warned)
            (should (equal 1 (length ensure-calls)))))
      (delete-directory tmp t)
      (unless had-feat
        (setq features (delq 'ghostel-module features)))
      (unless had-dyn-feat
        (setq features (delq 'dyn-loader-module features))))))

(ert-deftest ghostel-test-load-module-no-prompt-on-loaded-stale-at-load-time ()
  "Even with a stale loaded module, the load-time call must NOT prompt.
The interactive prompt is gated on PROMPT-USER; load-time
auto-execution (e.g. byte-compile) only warns."
  (let* ((tmp (make-temp-file "ghostel-test-loaded-stale-load" t))
         (ghostel--minimum-module-version "0.25.0")
         (ensure-calls nil)
         (had-feat (featurep 'ghostel-module)))
    (unwind-protect
        (progn
          (cl-pushnew 'ghostel-module features)
          (cl-letf (((symbol-function 'ghostel--module-directory)
                     (lambda () (file-name-as-directory tmp)))
                    ((symbol-function 'ghostel--module-version)
                     (lambda () "0.20.0"))
                    ((symbol-function 'ghostel--ensure-module)
                     (lambda (dir) (push dir ensure-calls)))
                    ((symbol-function 'display-warning)
                     (lambda (&rest _) nil)))
            (ghostel--load-module)
            (should (null ensure-calls))))
      (delete-directory tmp t)
      (unless had-feat
        (setq features (delq 'ghostel-module features))))))

(ert-deftest ghostel-test-platform-tag-normalizes-arch ()
  "Test that amd64/arm64 arch names are normalized in platform tags."
  ;; amd64 -> x86_64
  (let ((system-configuration "amd64-pc-linux-gnu")
        (system-type 'gnu/linux))
    (should (equal (ghostel--module-platform-tag) "x86_64-linux")))
  ;; arm64 -> aarch64
  (let ((system-configuration "arm64-apple-darwin23.1.0")
        (system-type 'darwin))
    (should (equal (ghostel--module-platform-tag) "aarch64-macos")))
  ;; x86_64 unchanged
  (let ((system-configuration "x86_64-pc-linux-gnu")
        (system-type 'gnu/linux))
    (should (equal (ghostel--module-platform-tag) "x86_64-linux")))
  ;; aarch64 unchanged
  (let ((system-configuration "aarch64-unknown-linux-gnu")
        (system-type 'gnu/linux))
    (should (equal (ghostel--module-platform-tag) "aarch64-linux")))
  ;; Windows release tags use the same normalized arch names.
  (let ((system-configuration "amd64-w64-mingw32")
        (system-type 'windows-nt))
    (should (equal (ghostel--module-platform-tag) "x86_64-windows")))
  (let ((system-configuration "arm64-w64-mingw32")
        (system-type 'windows-nt))
    (should (equal (ghostel--module-platform-tag) "aarch64-windows"))))

(ert-deftest ghostel-test-platform-tag-detects-android ()
  "Test that Termux/Android builds get an `android' tag, not `linux'."
  ;; Emacs 30+ sets `system-type' to `android' for *-linux-android hosts.
  (let ((system-configuration "aarch64-linux-android")
        (system-type 'android))
    (should (equal (ghostel--module-platform-tag) "aarch64-android")))
  ;; Older Emacs versions report `gnu/linux' for the same host triple.
  (let ((system-configuration "aarch64-linux-android")
        (system-type 'gnu/linux))
    (should (equal (ghostel--module-platform-tag) "aarch64-android")))
  (let ((system-configuration "x86_64-linux-android")
        (system-type 'android))
    (should (equal (ghostel--module-platform-tag) "x86_64-android")))
  ;; A glibc host must keep the `linux' tag.
  (let ((system-configuration "aarch64-unknown-linux-gnu")
        (system-type 'gnu/linux))
    (should (equal (ghostel--module-platform-tag) "aarch64-linux"))))

(ert-deftest ghostel-test-module-platform-tag-windows ()
  "Windows builds use the release tag format expected by Ghostel assets."
  (let ((system-type 'windows-nt)
        (system-configuration "x86_64-w64-mingw32"))
    (should (equal "x86_64-windows"
                   (ghostel--module-platform-tag)))))

(ert-deftest ghostel-test-module-asset-name-windows ()
  "Windows module assets use the Windows platform tag in their file name."
  (let ((system-type 'windows-nt)
        (system-configuration "x86_64-w64-mingw32")
        (module-file-suffix ".dll"))
    (should (equal "ghostel-module-x86_64-windows.tar.xz"
                   (ghostel--module-asset-name)))))

(ert-deftest ghostel-test-start-process-windows-native-uses-argv ()
  "Windows native PTY startup passes argv directly."
  (with-temp-buffer
    (let ((system-type 'windows-nt)
          (ghostel-shell "cmdproxy.exe")
          (ghostel-shell-integration nil)
          (default-directory "/ghostel/")
          (ghostel--term 'fake-term)
          (ghostel--term-cols nil)
          (ghostel--term-rows nil)
          (captured-command nil))
      (ghostel-test--without-subr-trampolines
        (cl-letf (((symbol-function 'window-body-height)
                   (lambda (&optional _) 33))
                  ((symbol-function 'window-max-chars-per-line)
                   (lambda (&optional _) 80))
                  ((symbol-function 'ghostel--resource-root)
                   (lambda () "/ghostel/"))
                  ((symbol-function 'ghostel--resolve-local-executable)
                   (lambda (program)
                     (cond
                      ((equal "cmdproxy.exe" program)
                       "/Program Files/Emacs/cmdproxy.exe")
                      ((equal "/Program Files/Emacs/cmdproxy.exe" program)
                       program)
                      (t
                       (ert-fail
                        (format "unexpected executable resolution: %S" program))))))
                  ((symbol-function 'ghostel--spawn-via-native)
                   (lambda (command)
                     (setq captured-command command)
                     'fake-proc)))
          (should (eq 'fake-proc (ghostel--start-process)))
          (should (equal '("/Program Files/Emacs/cmdproxy.exe")
                         captured-command)))))))

(ert-deftest ghostel-test-windows-ghostel-starts ()
  "Windows `ghostel' loads the native runtime and starts the native PTY backend."
  :tags '(native)
  (skip-unless (eq system-type 'windows-nt))
  (let ((shell (getenv "SHELL")))
    (skip-unless (not (and shell (string-prefix-p "/" shell)))))
  (let* ((buffer-name (generate-new-buffer-name " *ghostel-startup-test*"))
         (ghostel-buffer-name buffer-name)
         (ghostel-shell (or (getenv "ComSpec") "cmd.exe"))
         (ghostel-shell-integration nil)
         (buf nil))
    (with-timeout (10 (ert-fail "Timed out starting Windows Ghostel"))
      (setq buf (ghostel))
      (should (buffer-live-p buf))
      (with-current-buffer buf
        (should (derived-mode-p 'ghostel-mode))
        (should ghostel--term)
        (should (processp ghostel--process))
        (should (ghostel--native-runtime-ready-p))
        (should (ghostel--native-runtime-reloadable-p))
        (should (featurep 'dyn-loader-module))
        (should (member ghostel--module-id
                        (ghostel--loader-loaded-modules)))
        (should (fboundp 'ghostel--new))
        (should (fboundp 'ghostel--spawn-native-process))))))

(ert-deftest ghostel-test-download-module-default-rejects-too-old-version ()
  "The default version prompt rejects versions below the supported minimum."
  (let ((ghostel--minimum-module-version "0.7.1"))
    (ghostel-test--without-subr-trampolines
      (cl-letf (((symbol-function 'file-exists-p)
                 (lambda (_) nil))
                ((symbol-function 'read-string)
                 (lambda (&rest _) "0.7.0")))
        (should-error (ghostel-download-module nil)
                      :type 'user-error)))))

(ert-deftest ghostel-test-module-file-path-uses-custom-dir ()
  "Custom module directories override the default module path."
  (let* ((module-dir (ghostel-test--fixture-dir "ghostel-modules"))
         (ghostel-module-directory module-dir)
         (module-file-suffix ".dll"))
    (should (equal (downcase (ghostel-test--fixture-path module-dir "ghostel-module.dll"))
                   (downcase (ghostel--target-module-file-path))))))

(ert-deftest ghostel-test-download-module-publishes-downloaded-archive ()
  "Module downloads publish the downloaded archive into the chosen module directory."
  (let* ((module-dir (ghostel-test--fixture-dir "ghostel-modules"))
         (source-dir (ghostel-test--fixture-dir "ghostel-build"))
         (archive (ghostel-test--fixture-path source-dir
                                              "ghostel-module-x86_64-windows.tar.xz"))
         (ghostel-module-directory module-dir)
         (module-file-suffix ".dll")
         (download-dest nil)
         (download-count 0)
         (published nil))
    (cl-letf (((symbol-function 'ghostel--module-download-url)
               (lambda (&optional _version)
                 "https://example.invalid/releases/download/v0.7.1/ghostel-module-x86_64-windows.tar.xz"))
              ((symbol-function 'ghostel--download-file)
               (lambda (_url dest)
                 (cl-incf download-count)
                 (setq download-dest dest)
                 "https://example.invalid/releases/download/v0.7.1/ghostel-module-x86_64-windows.tar.xz"))
              ((symbol-function 'ghostel--publish-downloaded-module-archive)
               (lambda (archive dir)
                 (setq published (list archive dir))
                 t))
              ((symbol-function 'delete-file)
               (lambda (&rest _) nil))
              ((symbol-function 'make-directory)
               (lambda (&rest _) nil))
              ((symbol-function 'message)
               (lambda (&rest _) nil)))
      (should (ghostel--download-module source-dir))
      (should (= 1 download-count))
      (should (equal (downcase archive)
                     (downcase download-dest)))
      (should (equal (list (downcase archive)
                           (downcase source-dir))
                     (list (downcase (car published))
                           (downcase (cadr published))))))))

(ert-deftest ghostel-test-extract-module-archive-uses-tar-xf ()
  "Downloaded module archives are unpacked with `tar xf'."
  (let* ((archive (expand-file-name
                   "ghostel-module-x86_64-windows.tar.xz"
                   temporary-file-directory))
         (staging-dir (make-temp-file "ghostel-extract-" t))
         invocation)
    (unwind-protect
        (ghostel-test--without-subr-trampolines
          (cl-letf (((symbol-function 'call-process)
                     (lambda (program infile destination display &rest args)
                       (setq invocation
                             (list program infile destination display args
                                   default-directory))
                       0)))
            (ghostel--extract-module-archive archive staging-dir)
            (should
             (equal (list "tar" nil t nil (list "xf" archive)
                          (file-name-as-directory staging-dir))
                    invocation))))
      (delete-directory staging-dir t))))

(ert-deftest ghostel-test-extract-module-archive-reports-tar-failure ()
  "Archive extraction reports tar output when `tar xf' fails."
  (let ((staging-dir (make-temp-file "ghostel-extract-" t)))
    (unwind-protect
        (ghostel-test--without-subr-trampolines
          (cl-letf (((symbol-function 'call-process)
                     (lambda (&rest _)
                       (insert "broken archive")
                       2)))
            (let ((case-fold-search nil)
                  (err
                   (should-error
                    (ghostel--extract-module-archive
                     (expand-file-name "broken.tar.xz" temporary-file-directory)
                     staging-dir))))
              (should (string-match-p "Tar failed.*broken archive"
                                      (error-message-string err))))))
      (delete-directory staging-dir t))))

(ert-deftest ghostel-test-publish-downloaded-module-archive-stages-in-module-dir ()
  "Downloaded archives are expanded beside their destination."
  (let* ((archive "/ghostel/ghostel-module-x86_64-windows.tar.xz")
         (module-dir (make-temp-file "ghostel-modules-" t))
         (staging-dir (expand-file-name ".ghostel-download-test" module-dir))
         staging-prefix
         extracted
         published)
    (make-directory staging-dir)
    (unwind-protect
        (cl-letf (((symbol-function 'make-temp-file)
                   (lambda (prefix &optional _dir-flag)
                     (setq staging-prefix prefix)
                     staging-dir))
                  ((symbol-function 'ghostel--extract-module-archive)
                   (lambda (actual-archive actual-dir)
                     (setq extracted (list actual-archive actual-dir))))
                  ((symbol-function 'ghostel--publish-built-module-artifacts)
                   (lambda (source-dir dest-dir)
                     (setq published (list source-dir dest-dir)))))
          (ghostel--publish-downloaded-module-archive archive module-dir)
          (should (equal (expand-file-name ".ghostel-download-" module-dir)
                         staging-prefix))
          (should (equal (list archive staging-dir) extracted))
          (should (equal (list staging-dir
                               (file-name-as-directory module-dir))
                         published)))
      (delete-directory module-dir t))))

(ert-deftest ghostel-test-publish-built-module-artifacts-moves-complete-bundle ()
  "Publishing moves every bundle file and removes all backups."
  (let* ((source-dir (make-temp-file "ghostel-built-" t))
         (module-dir (make-temp-file "ghostel-published-" t))
         (files '("dyn-loader-module.dll"
                  "ghostel-module.dll"
                  "ghostel-module.json"
                  "conpty.dll"
                  "ghostel-module.pdb"
                  "x64/OpenConsole.exe"))
         (backups '("dyn-loader-module.dll.bak"
                   "ghostel-module.dll.1.bak"
                   "x64/unrelated.exe.bak")))
    (ghostel-test--without-subr-trampolines
      (let ((system-type 'windows-nt)
            (module-file-suffix ".dll"))
        (unwind-protect
            (progn
              (dolist (relative files)
                (let ((path (expand-file-name relative source-dir)))
                  (make-directory (file-name-directory path) t)
                  (with-temp-file path
                    (insert "new " relative)))
                (let ((path (expand-file-name relative module-dir)))
                  (make-directory (file-name-directory path) t)
                  (with-temp-file path
                    (insert "old " relative))))
              (dolist (relative backups)
                (let ((path (expand-file-name relative module-dir)))
                  (make-directory (file-name-directory path) t)
                  (with-temp-file path
                    (insert "stale backup"))))
              (should
               (ghostel--publish-built-module-artifacts source-dir module-dir))
              (dolist (relative files)
                (should-not (file-exists-p
                             (expand-file-name relative source-dir)))
                (should (equal (concat "new " relative)
                               (with-temp-buffer
                                 (insert-file-contents
                                  (expand-file-name relative module-dir))
                                 (buffer-string)))))
              (dolist (relative backups)
                (should-not (file-exists-p
                             (expand-file-name relative module-dir)))))
          (delete-directory source-dir t)
          (delete-directory module-dir t))))))

(ert-deftest ghostel-test-publish-built-module-artifacts-logs-move-failure ()
  "Publishing logs a failed move and continues replacing later files."
  (let* ((source-dir (make-temp-file "ghostel-built-" t))
         (module-dir (make-temp-file "ghostel-published-" t))
         (loader-src (expand-file-name "dyn-loader-module.dll" source-dir))
         (target-src (expand-file-name "ghostel-module.dll" source-dir))
         (manifest-src (expand-file-name "ghostel-module.json" source-dir))
         (target-dest (expand-file-name "ghostel-module.dll" module-dir))
         (rename-file-original (symbol-function 'rename-file))
         warnings)
    (unwind-protect
        (progn
          (dolist (path (list loader-src target-src manifest-src))
            (with-temp-file path
              (insert (file-name-nondirectory path))))
          (ghostel-test--without-subr-trampolines
            (let ((system-type 'windows-nt)
                  (module-file-suffix ".dll"))
              (cl-letf (((symbol-function 'rename-file)
                         (lambda (src dest &optional ok-if-already-exists)
                           (if (string-equal src loader-src)
                               (signal 'file-error (list "mapped" src))
                             (funcall rename-file-original
                                      src dest ok-if-already-exists))))
                        ((symbol-function 'display-warning)
                         (lambda (_type message &rest _)
                           (push message warnings))))
                (ghostel--publish-built-module-artifacts
                 source-dir module-dir))))
          (should (cl-some (lambda (message)
                             (string-match-p "mapped" message))
                           warnings))
          (should-not (file-exists-p target-src))
          (should (file-exists-p target-dest)))
      (delete-directory source-dir t)
      (delete-directory module-dir t))))

(ert-deftest ghostel-test-ask-install-action-includes-compile-for-custom-dir ()
  "Missing-module prompts still offer compile for custom module dirs."
  (let ((ghostel-module-directory "/modules/")
        (choice nil))
    (cl-letf (((symbol-function 'read-char-choice)
               (lambda (_prompt chars)
                 (setq choice chars)
                 ?c)))
      (should (eq 'compile (ghostel--ask-install-action "/modules/")))
      (should (equal '(?d ?c ?s) choice)))))

(ert-deftest ghostel-test-load-module-if-available-loads-loader-managed-windows-runtime ()
  "Windows bootstrap loads the Ghostel manifest through dyn-loader."
  (let* ((module-dir (ghostel-test--fixture-dir "ghostel-modules"))
         (loader-path (ghostel-test--fixture-path module-dir "dyn-loader-module.dll"))
         (ghostel-manifest (ghostel-test--fixture-path module-dir "ghostel-module.json"))
         (ghostel-module (ghostel-test--fixture-path module-dir "ghostel-module.dll"))
         (system-type 'windows-nt)
         (ghostel-module-directory module-dir)
         (module-file-suffix ".dll")
         (loaded nil)
         (manifests nil)
         (checked nil))
    (ghostel-test--without-subr-trampolines
      (cl-letf (((symbol-function 'file-exists-p)
                 (lambda (path)
                   (member (downcase path)
                           (list (downcase loader-path)
                                 (downcase ghostel-manifest)
                                 (downcase ghostel-module)))))
                ((symbol-function 'module-load)
                 (lambda (path)
                   (push path loaded)))
                ((symbol-function 'ghostel--loader-load-manifest)
                (lambda (path)
                  (push path manifests)))
                ((symbol-function 'ghostel--check-module-version)
                 (lambda (dir &optional _prompt-user)
                   (setq checked dir))))
        (should (ghostel--load-module-if-available))
        (should (equal (list (downcase loader-path))
                       (mapcar #'downcase (reverse loaded))))
        (should (equal (list (downcase ghostel-manifest))
                       (mapcar #'downcase (reverse manifests))))
        (should (equal (downcase module-dir)
                       (downcase checked)))))))

(ert-deftest ghostel-test-load-module-does-not-accept-direct-loaded-runtime ()
  "Direct-loaded native exports do not satisfy runtime readiness on any OS."
  (dolist (os '(gnu/linux darwin windows-nt))
    (let ((system-type os)
          (initialized nil)
          (original-featurep (symbol-function 'featurep))
          (original-fboundp (symbol-function 'fboundp)))
      (ghostel-test--without-subr-trampolines
        (cl-letf (((symbol-function 'ghostel--new)
                   (lambda (&rest _) nil))
                  ((symbol-function 'fboundp)
                   (lambda (symbol)
                     (or (funcall original-fboundp symbol)
                         (and initialized
                              (memq symbol
                                    ghostel--native-runtime-required-functions)))))
                  ((symbol-function 'featurep)
                   (lambda (feature)
                     (or (eq feature 'ghostel-module)
                         (and (not (eq feature 'dyn-loader-module))
                              (funcall original-featurep feature))))))
          (should-not (ghostel--native-runtime-ready-p))
          (cl-letf (((symbol-function 'ghostel--native-runtime-reloadable-p)
                     (lambda () initialized))
                    ((symbol-function 'ghostel--initialize-native-modules)
                     (lambda (&optional prompt-user)
                       (setq initialized prompt-user)))
                    ((symbol-function 'ghostel--check-module-version)
                     (lambda (&rest _) nil)))
            (ghostel--load-module t)
            (should initialized)))))))

(ert-deftest ghostel-test-native-runtime-ready-requires-all-ghostel-exports ()
  "A loader-registered runtime is incomplete when any Ghostel export is missing."
  (let ((system-type 'gnu/linux))
    (cl-letf (((symbol-function 'fboundp)
               (lambda (symbol)
                 (not (eq symbol 'ghostel--comint-make-state))))
              ((symbol-function 'ghostel--native-runtime-reloadable-p)
               (lambda () t)))
      (should-not (ghostel--native-runtime-ready-p)))))

(ert-deftest ghostel-test-load-module-if-available-requires-windows-ghostel-module ()
  "Windows bootstrap skips loading when ghostel-module.dll is missing."
  (let* ((module-dir (ghostel-test--fixture-dir "ghostel-modules"))
         (loader-path (ghostel-test--fixture-path module-dir "dyn-loader-module.dll"))
         (ghostel-manifest (ghostel-test--fixture-path module-dir "ghostel-module.json"))
         (ghostel-module (ghostel-test--fixture-path module-dir "ghostel-module.dll"))
         (system-type 'windows-nt)
         (ghostel-module-directory module-dir)
         (module-file-suffix ".dll")
         (loaded nil)
         (bootstrapped nil)
         (checked nil))
    (ghostel-test--without-subr-trampolines
      (cl-letf (((symbol-function 'file-exists-p)
                 (lambda (path)
                   (member (downcase path)
                           (list (downcase loader-path)
                                 (downcase ghostel-manifest)))))
                ((symbol-function 'ghostel--ensure-loader-loaded)
                 (lambda (_path)
                   (setq loaded t)))
                ((symbol-function 'ghostel--bootstrap-native-runtime)
                 (lambda (_dir)
                   (setq bootstrapped t)))
                ((symbol-function 'ghostel--check-module-version)
                 (lambda (&rest _)
                   (setq checked t))))
        (should-not (ghostel--load-module-if-available))
        (should-not loaded)
        (should-not bootstrapped)
        (should-not checked)))))

(ert-deftest ghostel-test-initialize-native-modules-requires-windows-ghostel-manifest ()
  "Windows startup requires the loader and Ghostel manifest."
  (let* ((module-dir (ghostel-test--fixture-dir "ghostel-modules"))
         (loader-path (ghostel-test--fixture-path module-dir "dyn-loader-module.dll"))
         (ghostel-manifest (ghostel-test--fixture-path module-dir "ghostel-module.json"))
         (system-type 'windows-nt)
         (ghostel-module-directory module-dir)
         (module-file-suffix ".dll")
         (noninteractive nil)
         (ensured nil)
         (loaded nil)
         (warnings nil))
    (ghostel-test--without-subr-trampolines
      (cl-letf (((symbol-function 'file-exists-p)
                 (lambda (path)
                   (member (downcase path)
                           (list (downcase loader-path)))))
                ((symbol-function 'ghostel--ensure-module)
                 (lambda (dir)
                   (setq ensured dir)
                   nil))
                ((symbol-function 'ghostel--load-module-if-available)
                 (lambda (&rest _)
                   (setq loaded t)
                   t))
                ((symbol-function 'display-warning)
                 (lambda (_type message &rest _args)
                   (push message warnings))))
        (let ((err (should-error (ghostel--initialize-native-modules t)
                                 :type 'user-error)))
          (should (string-match-p (regexp-quote ghostel-manifest)
                                  (error-message-string err))))
        (should (equal (downcase module-dir) (downcase ensured)))
        (should-not loaded)
        (should-not warnings)))))

(ert-deftest ghostel-test-compile-module-publishes-module ()
  "Windows compilation publishes build artifacts into the module directory."
  (let* ((source-dir (ghostel-test--fixture-dir "ghostel-build"))
         (module-dir (ghostel-test--fixture-dir "ghostel-modules"))
         (build-dir (ghostel-test--fixture-path module-dir ".ghostel-build/"))
         (system-type 'windows-nt)
         (ghostel-module-directory module-dir)
         (module-file-suffix ".dll")
         (published nil))
    (ghostel-test--without-subr-trampolines
      (cl-letf (((symbol-function 'process-file)
                 (lambda (&rest _) 0))
                ((symbol-function 'ghostel--resource-root)
                 (lambda () source-dir))
                ((symbol-function 'ghostel--make-module-build-dir)
                 (lambda (_dest-dir) build-dir))
                ((symbol-function 'ghostel--publish-built-module-artifacts)
                 (lambda (src dest)
                   (setq published (list src dest))
                   t))
                ((symbol-function 'message)
                 (lambda (&rest _) nil)))
        (should (ghostel--compile-module module-dir))
        (should (equal (list (expand-file-name "bin" build-dir) module-dir)
                       published))))))

(ert-deftest ghostel-test-load-module-if-available-skips-when-module-missing ()
  "Missing loader and target module leaves the native module unavailable."
  (let ((ghostel-module-directory "/modules/")
        (module-file-suffix ".dll"))
    (ghostel-test--without-subr-trampolines
      (cl-letf (((symbol-function 'file-exists-p)
                 (lambda (_path) nil))
                ((symbol-function 'module-load)
                 (lambda (&rest _)
                   (error "Should not load when the module is missing")))
                ((symbol-function 'ghostel--check-module-version)
                 (lambda (&rest _)
                   (error "Should not check version when the module is missing"))))
        (should-not (ghostel--load-module-if-available))))))

(ert-deftest ghostel-test-reload-module-reloads-windows-runtime-bundle ()
  "Windows reload refreshes the loader-managed Ghostel module id."
  (let ((system-type 'windows-nt)
        (reloaded nil))
    (ghostel-test--without-subr-trampolines
      (cl-letf (((symbol-function 'ghostel--live-buffers) (lambda () nil))
                ((symbol-function 'ghostel--native-runtime-reloadable-p)
                 (lambda () t))
                ((symbol-function 'ghostel--loader-reload)
                 (lambda (module-id)
                   (push module-id reloaded)))
                ((symbol-function 'garbage-collect)
                 (lambda () nil))
                ((symbol-function 'message)
                 (lambda (&rest _) nil)))
        (ghostel-reload-module)
        (should (equal '("ghostel")
                       (reverse reloaded)))))))

(ert-deftest ghostel-test-reload-module-recovers-missing-loader-registration ()
  "Reload loads a missing runtime manifest before refreshing the module id."
  (dolist (case '((("ghostel") nil)
                  (nil ("ghostel-module.json"))))
    (let ((system-type 'windows-nt)
          (module-file-suffix ".dll")
          (ghostel-module-directory "/ghostel/")
          (loaded-modules (copy-sequence (car case)))
          (expected-manifests (cadr case))
          (loaded-manifests nil)
          (reloaded nil)
          (original-featurep (symbol-function 'featurep)))
      (ghostel-test--without-subr-trampolines
        (cl-letf (((symbol-function 'featurep)
                   (lambda (feature)
                     (or (eq feature 'dyn-loader-module)
                         (funcall original-featurep feature))))
                  ((symbol-function 'dyn-loader-reload)
                   (lambda (module-id)
                     (push module-id reloaded)))
                  ((symbol-function 'dyn-loader-load-manifest)
                   (lambda (&rest _) t))
                  ((symbol-function 'ghostel--loader-loaded-modules)
                   (lambda () loaded-modules))
                  ((symbol-function 'ghostel--loader-load-manifest)
                   (lambda (manifest)
                     (push manifest loaded-manifests)
                     (when (string-suffix-p "ghostel-module.json" manifest)
                       (push "ghostel" loaded-modules))))
                  ((symbol-function 'ghostel--live-buffers)
                   (lambda () nil))
                  ((symbol-function 'garbage-collect)
                   (lambda () nil)))
          (ghostel--reload-native-runtime)
          (should (equal (mapcar (lambda (manifest)
                                   (expand-file-name manifest "/ghostel/"))
                                 expected-manifests)
                         (reverse loaded-manifests)))
          (should (equal '("ghostel")
                         (reverse reloaded))))))))

(ert-deftest ghostel-test-reload-module-closes-live-buffers-before-reload ()
  "Reloading closes live terminals and collects finalizers before module reload."
  (let ((system-type 'windows-nt)
        (events nil))
    (ghostel-test--without-subr-trampolines
      (cl-letf (((symbol-function 'ghostel--live-buffers)
                 (lambda () '(live-buffer)))
                ((symbol-function 'ghostel--native-runtime-reloadable-p)
                 (lambda () t))
                ((symbol-function 'ghostel--close-live-buffers)
                 (lambda (buffers)
                   (should (equal '(live-buffer) buffers))
                   (setq events (append events '(close)))))
                ((symbol-function 'garbage-collect)
                 (lambda ()
                   (setq events (append events '(gc)))
                   nil))
                ((symbol-function 'ghostel--loader-reload)
                 (lambda (module-id)
                   (setq events
                         (append events
                                 (list (format "reload:%s" module-id)))))))
        (ghostel--reload-native-runtime)
        (should (equal '(close gc "reload:ghostel")
                       events))))))



(ert-deftest ghostel-test-module-download-url-uses-minimum-version ()
  "Module downloads pin to the minimum supported native module version."
  (let ((ghostel-github-release-url "https://example.invalid/releases")
        (ghostel--minimum-module-version "0.7.1"))
    (cl-letf (((symbol-function 'ghostel--module-asset-name)
               (lambda () "ghostel-module-x86_64-windows.tar.xz")))
      (should (equal "https://example.invalid/releases/download/v0.7.1/ghostel-module-x86_64-windows.tar.xz"
                     (ghostel--module-download-url ghostel--minimum-module-version))))))

(ert-deftest ghostel-test-download-module-reloads-loaded-runtime ()
  "Downloading over a loaded runtime reloads in-process via dyn-loader."
  (let ((system-type 'windows-nt)
        (module-file-suffix ".dll")
        (ghostel-module-directory "/ghostel/")
        (downloaded nil)
        (checked-dir nil)
        (messages nil)
        (reloaded nil))
    (let ((comp-enable-subr-trampolines nil)
          (native-comp-enable-subr-trampolines nil)
          (original-featurep (symbol-function 'featurep)))
      (cl-letf (((symbol-function 'file-exists-p)
                 (lambda (_) nil))
                ((symbol-function 'ghostel--download-module)
                 (lambda (_dir &optional _version _latest-release)
                   (setq downloaded t)
                   t))
                ((symbol-function 'ghostel--native-runtime-ready-p)
                 (lambda () t))
                ((symbol-function 'featurep)
                 (lambda (feature)
                   (or (eq feature 'dyn-loader-module)
                       (funcall original-featurep feature))))
                ((symbol-function 'ghostel--loader-loaded-modules)
                 (lambda () '("ghostel")))
                ((symbol-function 'dyn-loader-reload)
                 (lambda (module-id)
                   (push module-id reloaded)))
                ((symbol-function 'ghostel--check-module-version)
                 (lambda (dir)
                   (setq checked-dir dir)))
                ((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (push (apply #'format format-string args) messages))))
        (ghostel-download-module '(4))
        (should downloaded)
        (should (equal '("ghostel")
                       (reverse reloaded)))
        (should (equal (downcase (expand-file-name "/ghostel/"))
                       (downcase checked-dir)))
        (should-not (cl-some (lambda (msg)
                               (string-match-p "Restart Emacs" msg))
                             messages))
        (should (member "ghostel: module loaded successfully" messages))))))

(ert-deftest ghostel-test-download-module-rejects-non-loader-runtime ()
  "Downloading over a direct-loaded runtime does not try dyn-loader reload."
  (let ((system-type 'windows-nt)
        (module-file-suffix ".dll")
        (ghostel-module-directory "/ghostel/")
        (downloaded nil)
        (checked nil)
        (reloaded nil)
        (original-featurep (symbol-function 'featurep)))
    (ghostel-test--without-subr-trampolines
      (cl-letf (((symbol-function 'file-exists-p)
                 (lambda (_) nil))
                ((symbol-function 'ghostel--download-module)
                 (lambda (_dir &optional _version _latest-release)
                   (setq downloaded t)
                   t))
                ((symbol-function 'ghostel--native-runtime-ready-p)
                 (lambda () t))
                ((symbol-function 'featurep)
                 (lambda (feature)
                   (and (not (eq feature 'dyn-loader-module))
                        (funcall original-featurep feature))))
                ((symbol-function 'ghostel--loader-reload)
                 (lambda (&rest _)
                   (setq reloaded t)))
                ((symbol-function 'ghostel--check-module-version)
                 (lambda (&rest _)
                   (setq checked t)))
                ((symbol-function 'message)
                 (lambda (&rest _) nil)))
        (should-error (ghostel-download-module '(4))
                      :type 'user-error)
        (should downloaded)
        (should-not reloaded)
        (should-not checked)))))

(ert-deftest ghostel-test-download-module-rejects-unregistered-loader-runtime ()
  "Downloading over a runtime not registered with dyn-loader does not reload."
  (let ((system-type 'windows-nt)
        (module-file-suffix ".dll")
        (ghostel-module-directory "/ghostel/")
        (downloaded nil)
        (checked nil)
        (reloaded nil)
        (original-featurep (symbol-function 'featurep)))
    (ghostel-test--without-subr-trampolines
      (cl-letf (((symbol-function 'file-exists-p)
                 (lambda (_) nil))
                ((symbol-function 'ghostel--download-module)
                 (lambda (_dir &optional _version _latest-release)
                   (setq downloaded t)
                   t))
                ((symbol-function 'ghostel--native-runtime-ready-p)
                 (lambda () t))
                ((symbol-function 'featurep)
                 (lambda (feature)
                   (or (eq feature 'dyn-loader-module)
                       (funcall original-featurep feature))))
                ((symbol-function 'ghostel--loader-loaded-modules)
                 (lambda () '("other-module")))
                ((symbol-function 'dyn-loader-reload)
                 (lambda (&rest _)
                   (setq reloaded t)))
                ((symbol-function 'ghostel--check-module-version)
                 (lambda (&rest _)
                   (setq checked t)))
                ((symbol-function 'message)
                 (lambda (&rest _) nil)))
        (should-error (ghostel-download-module '(4))
                      :type 'user-error)
        (should downloaded)
        (should-not reloaded)
        (should-not checked)))))

(ert-deftest ghostel-test-download-module-failure-keeps-live-buffers-open ()
  "A failed download leaves every live Ghostel session running."
  (let (closed)
    (ghostel-test--without-subr-trampolines
      (cl-letf (((symbol-function 'file-exists-p)
                 (lambda (_) nil))
                ((symbol-function 'ghostel--download-module)
                 (lambda (&rest _) nil))
                ((symbol-function 'ghostel--live-buffers)
                 (lambda () '(session-a session-b)))
                ((symbol-function 'ghostel--close-live-buffers)
                 (lambda (buffers)
                   (setq closed buffers))))
        (should-error (ghostel-download-module '(4)) :type 'user-error)
        (should-not closed)))))

(ert-deftest ghostel-test-download-module-closes-all-live-buffers-after-download ()
  "A successful download closes every live session immediately before reload."
  (let ((system-type 'windows-nt)
        (module-file-suffix ".dll")
        (ghostel-module-directory "/ghostel/")
        (events nil)
        (original-featurep (symbol-function 'featurep)))
    (ghostel-test--without-subr-trampolines
      (cl-letf (((symbol-function 'file-exists-p)
                 (lambda (_) nil))
                ((symbol-function 'ghostel--download-module)
                 (lambda (&rest _)
                   (setq events (append events '(download)))
                   t))
                ((symbol-function 'ghostel--native-runtime-ready-p)
                 (lambda () t))
                ((symbol-function 'featurep)
                 (lambda (feature)
                   (or (eq feature 'dyn-loader-module)
                       (funcall original-featurep feature))))
                ((symbol-function 'ghostel--loader-loaded-modules)
                 (lambda () '("ghostel")))
                ((symbol-function 'ghostel--live-buffers)
                 (lambda () '(session-a session-b)))
                ((symbol-function 'ghostel--close-live-buffers)
                 (lambda (buffers)
                   (setq events
                         (append events (list (list 'close buffers))))))
                ((symbol-function 'dyn-loader-reload)
                 (lambda (&rest _)
                   (setq events (append events '(reload)))))
                ((symbol-function 'ghostel--check-module-version)
                 (lambda (&rest _)
                   (setq events (append events '(check)))))
                ((symbol-function 'garbage-collect)
                 (lambda () nil))
                ((symbol-function 'message)
                 (lambda (&rest _) nil)))
        (ghostel-download-module '(4))
        (should (equal '(download
                         (close (session-a session-b))
                         reload
                         check)
                       events))))))

(ert-deftest ghostel-test-module-compile-command-uses-package-dir ()
  "Interactive compilation runs from the Ghostel package directory."
  (let ((source-dir (ghostel-test--fixture-dir "ghostel-build"))
        (build-dir nil)
        (compile-command nil)
        (compile-directory nil)
        (finish-args nil))
    (let ((comp-enable-subr-trampolines nil)
          (native-comp-enable-subr-trampolines nil))
      (cl-letf (((symbol-function 'locate-library)
                 (lambda (_) (ghostel-test--fixture-path source-dir "ghostel.el")))
                ((symbol-function 'ghostel--make-module-build-dir)
                 (lambda (dest-dir)
                   (setq build-dir (file-name-as-directory
                                    (expand-file-name ".ghostel-build/" dest-dir)))))
                ((symbol-function 'ghostel--install-built-module-on-finish)
                 (lambda (buf recorded-build-dir dest-dir)
                   (setq finish-args (list buf recorded-build-dir dest-dir))))
                ((symbol-function 'compilation-start)
                 (lambda (command &optional mode name-function &rest _)
                   (setq compile-command (list command mode name-function))
                   (setq compile-directory default-directory)
                   (current-buffer))))
        (ghostel-module-compile)
        (should (equal
                 (list (format "zig build --prefix %s -Doptimize=ReleaseFast -Dcpu=baseline"
                               (shell-quote-argument (expand-file-name build-dir)))
                       #'ghostel-module-compilation-mode
                       #'ghostel--module-compilation-buffer-name)
                 compile-command))
        (should (equal (downcase source-dir)
                       (downcase compile-directory)))
        (should (equal (list (current-buffer) build-dir source-dir)
                       finish-args))))))

(provide 'ghostel-module-test)
;;; ghostel-module-test.el ends here
