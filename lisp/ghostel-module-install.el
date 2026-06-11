;;; ghostel-module-install.el --- Native module download/compile/load for ghostel -*- lexical-binding: t; -*-

;; Author: Daniel Kraus <daniel@kraus.my>
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Provisioning for Ghostel's native module runtime bundle: downloading a
;; pre-built archive from GitHub releases, compiling from source via `zig build',
;; writing dyn-loader manifests, and loading/reloading the runtime.  The embedded
;; `ghostel--module-version' exported by the loaded target module is the only
;; version authority.
;;
;; `ghostel.el' requires this file and calls `ghostel--load-module' at load time.

;;; Code:

(require 'cl-lib)
(require 'compat)
(require 'json)
(require 'seq)
(require 'url-parse)

(declare-function dyn-loader-load-manifest "dyn-loader-module" (manifest-path))
(declare-function dyn-loader-reload "dyn-loader-module" (module-id))
(declare-function ghostel--module-version "ghostel-module")


;;; Customization

(defcustom ghostel-module-directory nil
  "Directory holding the ghostel native module.
When nil (the default), the module is read from and written to the
ghostel package directory.  Set this to a path outside your package
manager's tree (for example, \"~/.config/emacs/ghostel/\") so that
rebuilds or re-installs by the package manager do not delete or
overwrite the module file while Emacs has it loaded."
  :type '(choice (const :tag "Use package directory" nil)
                 (directory :tag "Custom directory"))
  :group 'ghostel)

(defcustom ghostel-module-dir nil
  "If non-nil, load and download native modules from this directory.

When nil, Ghostel uses the package directory.  Source builds from
`ghostel-module-compile' still build in the package directory first,
then copy the finished modules here."
  :type '(choice (const :tag "Use package directory" nil)
                 directory)
  :group 'ghostel)

(defcustom ghostel-module-auto-install 'ask
  "What to do when the native module is missing at first interactive use.
This setting is consulted only when the user invokes an interactive
entry point such as `\\[ghostel]', not when `ghostel.el' is loaded
or byte-compiled - loading the file never prompts or downloads.
\\=`ask'      - prompt with a choice to download, compile, or skip (default).
\\=`download' - download a pre-built binary from GitHub releases.
\\=`compile'  - build from source via `ghostel-module-compile'.
nil        - do nothing; the user must install the module manually."
  :type '(choice (const :tag "Ask interactively" ask)
                 (const :tag "Download pre-built binary" download)
                 (const :tag "Compile from source" compile)
                 (const :tag "Do nothing" nil))
  :group 'ghostel)

(defcustom ghostel-github-release-url
  "https://github.com/dakra/ghostel/releases"
  "Base URL for Ghostel GitHub releases.
Customize this when downloading pre-built modules from a fork or mirror."
  :type 'string
  :group 'ghostel)


;;; Automatic download and compilation of native module

(defconst ghostel--minimum-module-version "0.39.0"
  "Minimum native module version required by this Elisp version.
Bump this only when the Elisp code requires a newer native module
\(e.g. new Zig-exported function or changed calling convention).")

(defun ghostel--package-dir ()
  "Return the Ghostel resource root directory."
  (or (ghostel--resource-root)
      (file-name-directory (or load-file-name
                               (locate-library "ghostel")
                               buffer-file-name))))

(defun ghostel--effective-module-dir (&optional dir)
  "Return the directory Ghostel should use for native module lookup.
DIR is the fallback when no custom directory is configured."
  (file-name-as-directory
   (expand-file-name
    (or dir ghostel-module-dir ghostel-module-directory (ghostel--package-dir)))))

(defun ghostel--loader-module-file-path (&optional dir)
  "Return the stable dyn-loader-module path in DIR."
  (expand-file-name
   (concat "dyn-loader-module" module-file-suffix)
   (ghostel--effective-module-dir dir)))

(defun ghostel--target-module-file-path (&optional dir)
  "Return the stable ghostel target module path in DIR."
  (expand-file-name
   (concat "ghostel-module" module-file-suffix)
   (ghostel--effective-module-dir dir)))

(defconst ghostel--loader-api-version 1
  "Ghostel API version the loader module is built against.
Must stay in sync with the native module ABI.")

(defconst ghostel--module-id "ghostel"
  "Stable module id exported by the Ghostel target module.")

(defconst ghostel--native-runtime-required-functions
  '(ghostel--new
    ghostel--write-vt
    ghostel--set-size
    ghostel--redraw
    ghostel--scroll
    ghostel--scroll-top
    ghostel--scroll-bottom
    ghostel--encode-key
    ghostel--encode-paste
    ghostel--mouse-event
    ghostel--focus-event
    ghostel--set-palette
    ghostel--set-default-colors
    ghostel--mode-enabled
    ghostel--debug-state
    ghostel--debug-feed
    ghostel--module-version
    ghostel--cursor-position
    ghostel--redraw-full-scrollback
    ghostel--copy-all-text
    ghostel--enable-vt-log
    ghostel--disable-vt-log
    ghostel--get-title
    ghostel--get-pwd
    ghostel--cursor-pending-wrap-p
    ghostel--alt-screen-p
    ghostel--cursor-on-empty-row-p
    ghostel--native-uri-at
    ghostel--cursor-row-char-offset
    ghostel--pty-password-input-p
    ghostel--set-bold-config
    ghostel--comint-make-state
    ghostel--comint-filter
    ghostel--comint-set-palette
    ghostel--comint-set-default-colors
    ghostel--write-pty
    ghostel--spawn-native-process
    ghostel--kill-native-process
    ghostel--set-process-pid)
  "Ghostel dyn-loader exports required for a complete native runtime.")

(defun ghostel--loader-metadata-path (manifest-file &optional dir)
  "Return the path to MANIFEST-FILE in DIR."
  (expand-file-name manifest-file
                    (ghostel--effective-module-dir dir)))

(defun ghostel--native-runtime-specs (&optional dir)
  "Return loader-managed runtime specs for DIR."
  (let ((dir (ghostel--effective-module-dir dir)))
    (list (list :id ghostel--module-id
                :manifest (ghostel--loader-metadata-path "ghostel-module.json" dir)
                :file (ghostel--target-module-file-path dir)))))

(defvar ghostel--term)
(defvar ghostel--process)
(defvar ghostel--pending-output)
(defvar ghostel--last-send-time)
(defvar ghostel--redraw-timer)

(defun ghostel--live-buffers ()
  "Return `ghostel-mode' buffers whose `ghostel--term' handle is non-nil."
  (seq-filter
   (lambda (buf)
     (with-current-buffer buf
       (and (derived-mode-p 'ghostel-mode) ghostel--term)))
   (buffer-list)))
(defun ghostel--module-platform-tag ()
  "Return platform tag for the current system, e.g. \"x86_64-linux\".
Returns nil if the platform is not recognized."
  (let* ((raw-arch (car (split-string system-configuration "-")))
         (arch (pcase raw-arch
                 ("amd64" "x86_64")
                 ("arm64" "aarch64")
                 (_ raw-arch)))
         (os (cond
                ((eq system-type 'darwin) "macos")
                ((eq system-type 'gnu/linux) "linux")
                ((eq system-type 'windows-nt) "windows")
                (t nil))))
    (when os
      (format "%s-%s" arch os))))

(defun ghostel--module-asset-name ()
  "Return the expected release asset file name for the current platform."
  (let ((tag (ghostel--module-platform-tag)))
    (when tag
      (format "ghostel-module-%s.tar.xz" tag))))

(defun ghostel--module-download-url (&optional version)
  "Return the download URL for the current platform's pre-built module.
When VERSION is nil, use the latest release download URL."
  (let ((asset-name (ghostel--module-asset-name)))
    (when asset-name
      (if version
          (format "%s/download/v%s/%s"
                  ghostel-github-release-url version asset-name)
        (format "%s/latest/download/%s"
                ghostel-github-release-url asset-name)))))

(defun ghostel--same-path-p (left right)
  "Return non-nil when LEFT and RIGHT name the same path."
  (string-equal (downcase (expand-file-name left))
                (downcase (expand-file-name right))))

(defun ghostel--loader-metadata-alist (target-module)
  "Build loader metadata for TARGET-MODULE."
  `((loader_abi . ,ghostel--loader-api-version)
    (module_path . ,target-module)))

(defun ghostel--native-runtime-metadata-specs (&optional dir)
  "Return manifest metadata specs for the native runtime bundle in DIR."
  (let ((dir (ghostel--effective-module-dir dir)))
    (list (list :manifest-file "ghostel-module.json"
                :metadata (ghostel--loader-metadata-alist
                           (file-name-nondirectory
                            (ghostel--target-module-file-path dir)))))))

(defun ghostel--loader-load-manifest (manifest-path)
  "Ask dyn-loader-module to load MANIFEST-PATH."
  (dyn-loader-load-manifest manifest-path))

(defun ghostel--loader-reload (module-id)
  "Ask dyn-loader-module to reload MODULE-ID from its stored manifest."
  (dyn-loader-reload module-id))

(defun ghostel--loader-loaded-modules ()
  "Return module IDs currently registered with dyn-loader."
  (and (boundp 'dyn-loader-loaded-modules)
       (symbol-value 'dyn-loader-loaded-modules)))

(defun ghostel--native-runtime-missing-specs ()
  "Return native runtime specs missing from dyn-loader's registry."
  (let ((loaded-modules (ghostel--loader-loaded-modules)))
    (cl-loop for spec in (ghostel--native-runtime-specs)
             for module-id = (plist-get spec :id)
             unless (member module-id loaded-modules)
             collect spec)))

(defun ghostel--native-runtime-missing-module-ids ()
  "Return native runtime module IDs missing from dyn-loader's registry."
  (mapcar (lambda (spec) (plist-get spec :id))
          (ghostel--native-runtime-missing-specs)))

(defun ghostel--native-runtime-reloadable-p ()
  "Return non-nil when dyn-loader can reload every native runtime module."
  (and (featurep 'dyn-loader-module)
       (fboundp 'dyn-loader-reload)
       (null (ghostel--native-runtime-missing-module-ids))))

(defun ghostel--recover-native-runtime-registrations ()
  "Load missing native runtime manifests through dyn-loader."
  (when (and (featurep 'dyn-loader-module)
             (fboundp 'dyn-loader-load-manifest))
    (dolist (spec (ghostel--native-runtime-missing-specs))
      (ghostel--loader-load-manifest (plist-get spec :manifest)))))

(defun ghostel--native-runtime-reload-error-message ()
  "Return a diagnostic explaining why the native runtime cannot reload."
  (cond
   ((not (featurep 'dyn-loader-module))
    "Ghostel native runtime is loaded without dyn-loader; restart Emacs to load the downloaded version")
   ((not (fboundp 'dyn-loader-reload))
    "Ghostel dyn-loader runtime does not support reload; restart Emacs to load the downloaded version")
   (t
    (let ((missing (ghostel--native-runtime-missing-module-ids))
          (loaded (ghostel--loader-loaded-modules)))
      (if missing
          (format "Ghostel native runtime is not registered with dyn-loader for: %s (registered: %s); restart Emacs to load the downloaded version"
                  (mapconcat #'identity missing ", ")
                  (if loaded
                      (mapconcat (lambda (module-id)
                                   (format "%s" module-id))
                                 loaded ", ")
                    "none"))
        "Ghostel native runtime cannot be reloaded; restart Emacs to load the downloaded version")))))

(defun ghostel--reload-native-runtime (&optional close-live)
  "Reload every loader-managed native runtime module from disk.
Terminate live Ghostel terminals first.  CLOSE-LIVE is accepted
for compatibility with older callers and is otherwise ignored."
  (ignore close-live)
  (unless (ghostel--native-runtime-reloadable-p)
    (ghostel--recover-native-runtime-registrations))
  (unless (ghostel--native-runtime-reloadable-p)
    (user-error "%s" (ghostel--native-runtime-reload-error-message)))
  (let ((live-buffers (ghostel--live-buffers)))
    (when live-buffers
      (ghostel--close-live-buffers live-buffers)))
  ;; Let already-dead terminal finalizers run before dyn-loader swaps DLLs.
  ;; Old DLLs are retired, not unloaded, so any remaining finalizers stay safe.
  (garbage-collect)
  (dolist (spec (ghostel--native-runtime-specs))
    (ghostel--loader-reload (plist-get spec :id))))

(defun ghostel-reload-module (&optional close-live)
  "Reload the loader-managed Ghostel runtime bundle from disk.

Live Ghostel terminals are terminated first.  CLOSE-LIVE is
accepted for compatibility with older callers and is otherwise
ignored."
  (interactive "P")
  (ghostel--reload-native-runtime close-live)
  (message "ghostel: native runtime reloaded successfully"))

(defun ghostel--write-loader-metadata-atomically (manifest-file dir metadata)
  "Write loader METADATA for MANIFEST-FILE into DIR atomically."
  (let* ((dir (ghostel--effective-module-dir dir))
         (path (ghostel--loader-metadata-path manifest-file dir))
         (temp (make-temp-file (expand-file-name ".ghostel-module." dir)
                               nil ".json")))
    (unwind-protect
        (progn
          (with-temp-file temp
            (set-buffer-multibyte nil)
            (insert (json-encode metadata)))
          (rename-file temp path t))
       (when (file-exists-p temp)
         (delete-file temp)))))

(defun ghostel--write-native-runtime-manifests (&optional dir)
  "Write every loader manifest for the native runtime bundle in DIR."
  (dolist (spec (ghostel--native-runtime-metadata-specs dir))
    (ghostel--write-loader-metadata-atomically
     (plist-get spec :manifest-file)
     dir
     (plist-get spec :metadata))))

(defun ghostel--read-loader-metadata (&optional dir)
  "Read and validate loader metadata JSON from DIR."
  (let ((path (ghostel--loader-metadata-path "ghostel-module.json" dir)))
    (unless (file-exists-p path)
      (error "Ghostel loader metadata is missing: %s" path))
    (with-temp-buffer
      (insert-file-contents path)
      (let* ((raw (json-parse-buffer :object-type 'alist
                                     :array-type 'list
                                     :null-object nil
                                     :false-object nil))
             (metadata (mapcar (lambda (entry)
                                 (cons (if (symbolp (car entry))
                                           (car entry)
                                         (intern (car entry)))
                                       (cdr entry)))
                               raw)))
        (dolist (field '(loader_abi module_path))
          (unless (alist-get field metadata nil nil)
            (error "Ghostel loader metadata is missing %s in %s" field path)))
        metadata))))

(defun ghostel--resolve-target-module-path (metadata &optional dir)
  "Resolve the target module file from METADATA in DIR."
  (let* ((module-dir (ghostel--effective-module-dir dir))
         (target-module (alist-get 'module_path metadata)))
    (unless (stringp target-module)
      (error "Ghostel loader metadata has invalid module_path entry"))
    (let ((target-path (expand-file-name target-module module-dir)))
      (unless (file-exists-p target-path)
        (error "Ghostel target module is missing: %s" target-path))
      target-path)))

(defun ghostel--next-module-backup-path (path)
  "Return a fresh backup path for PATH that will not clobber older backups."
  (let ((candidate (concat path ".bak"))
        (index 1))
    (while (file-exists-p candidate)
      (setq candidate (format "%s.%d.bak" path index)
            index (1+ index)))
    candidate))

(defun ghostel--replace-module-file (src dest)
  "Copy SRC to DEST, deleting it first and rotating to a fresh backup on failure."
  (unless (ghostel--same-path-p src dest)
    (when (file-exists-p dest)
      (condition-case nil
          (delete-file dest)
        (file-error
         (rename-file dest (ghostel--next-module-backup-path dest) t))))
    (copy-file src dest t)))

(defun ghostel--extract-module-archive (archive dest-dir)
  "Extract Ghostel ARCHIVE into DEST-DIR."
  (unless (eq 0 (process-file "tar" nil "*ghostel-download*" nil
                              "xJf" archive "-C" dest-dir))
    (error "Ghostel archive extraction failed for %s" archive)))

(defun ghostel--publish-downloaded-module-archive (archive dir)
  "Extract ARCHIVE and publish loader and target modules into DIR."
  (let ((staging (make-temp-file "ghostel-download-" t)))
    (unwind-protect
        (progn
          (ghostel--extract-module-archive archive staging)
          (ghostel--publish-built-module-artifacts staging dir))
      (when (file-directory-p staging)
        (delete-directory staging t)))))

(defun ghostel--publish-built-module-artifacts (source-dir &optional dest-dir)
  "Publish loader, target module, and metadata from SOURCE-DIR.
When DEST-DIR is non-nil, publish the artifacts there."
  (let* ((source-dir (ghostel--effective-module-dir source-dir))
         (dest-dir (ghostel--effective-module-dir dest-dir))
          (loader-src (ghostel--loader-module-file-path source-dir))
          (loader-dest (ghostel--loader-module-file-path dest-dir))
          (target-src (ghostel--target-module-file-path source-dir))
          (target-dest (ghostel--target-module-file-path dest-dir))
          (target-file (file-name-nondirectory target-dest)))
    (unless (file-exists-p loader-src)
      (error "Built Ghostel loader is missing: %s" loader-src))
    (unless (file-exists-p target-src)
      (error "Built Ghostel target module is missing: %s" target-src))
    (unless (file-directory-p dest-dir)
      (make-directory dest-dir t))
    (ghostel--replace-module-file loader-src loader-dest)
    (ghostel--replace-module-file target-src target-dest)
    (ghostel--write-native-runtime-manifests dest-dir)
    target-file))

(defun ghostel--ensure-loader-loaded (loader-path)
  "Load the stable loader module from LOADER-PATH when needed."
  (unless (featurep 'dyn-loader-module)
    (module-load loader-path)))

(defun ghostel--bootstrap-native-runtime (&optional dir)
  "Load every manifest in the native runtime bundle for DIR."
  (dolist (spec (ghostel--native-runtime-specs dir))
    (ghostel--loader-load-manifest (plist-get spec :manifest))))

(defun ghostel--bootstrap-module (&optional dir)
  "Validate metadata in DIR and activate the matching target module."
  (ghostel--bootstrap-native-runtime dir))

(defun ghostel--close-live-buffers (buffers)
  "Terminate Ghostel BUFFERS and kill them."
  (dolist (buf buffers)
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (when (process-live-p ghostel--process)
          (delete-process ghostel--process)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(defun ghostel--download-module (dir &optional version latest-release)
  "Download a pre-built module into DIR.
When VERSION is non-nil, download that release tag.
When LATEST-RELEASE is non-nil, use the latest release asset URL.
Returns non-nil on success."
  (condition-case err
      (let* ((dir (ghostel--effective-module-dir dir))
             (requested-version (unless latest-release
                                  (or version ghostel--minimum-module-version)))
             (url (ghostel--module-download-url requested-version)))
        (when url
          (unless (string-prefix-p "https://" url)
            (error "Refusing non-HTTPS download URL: %s" url))
          (make-directory dir t)
          (let ((dest (expand-file-name (file-name-nondirectory url) dir)))
            (message "ghostel: downloading native module from %s..." url)
            (when (ghostel--download-file url dest)
              (ghostel--publish-downloaded-module-archive dest dir)
              (ignore-errors (delete-file dest))
              (message "ghostel: native module downloaded successfully")
              t))))
    (error
     (message "ghostel: download failed: %s" (error-message-string err))
     nil)))

(defun ghostel--compile-module (dest-dir)
  "Compile the native module from source and install it in DEST-DIR.
The build runs in `ghostel--resource-root' (which holds build.zig);
on success the produced module bundle is moved into DEST-DIR."
  (let* ((source-dir (ghostel--resource-root))
         (default-directory source-dir))
    (message "ghostel: compiling native module with zig build%s..."
             (if (or ghostel-module-dir ghostel-module-directory)
                 (format " (will copy to %s)"
                         dest-dir)
               " (this may take a moment)"))
    (condition-case err
        (let ((ret (process-file "zig" nil "*ghostel-build*" nil
                                 "build" "-Doptimize=ReleaseFast" "-Dcpu=baseline"))
              (build-output-dir (expand-file-name "zig-out/bin" source-dir)))
          (if (eq ret 0)
              (progn
                (ghostel--publish-built-module-artifacts
                 build-output-dir
                 dest-dir)
                (message "ghostel: native module compiled successfully")
                t)
            (display-warning 'ghostel
                             "Module compilation failed.  See *ghostel-build* buffer for details.")
            nil))
      (file-missing
       (display-warning 'ghostel
                         (format "zig executable not found while compiling in %s" source-dir)))
      (error
       (display-warning 'ghostel
                         (error-message-string err))
       nil))))

(defun ghostel--ensure-module (dir)
  "Ensure the native module exists in DIR.
Behavior is controlled by `ghostel-module-auto-install'."
  (let ((action ghostel-module-auto-install))
    (when (eq action 'ask)
      (setq action (ghostel--ask-install-action dir)))
    (pcase action
      ('download (ghostel--download-module dir))
      ('compile  (ghostel--compile-module dir))
      (_         nil))))

(defun ghostel--read-module-download-version ()
  "Prompt for a release tag to download, or nil for the latest release."
  (let ((version (read-string
                  (format "Ghostel module version (>= %s, empty for latest): "
                          ghostel--minimum-module-version))))
    (unless (string= version "")
      (when (version< version ghostel--minimum-module-version)
        (user-error "Version %s is older than minimum supported version %s"
                    version ghostel--minimum-module-version))
      version)))

(defun ghostel--ask-install-action (_dir)
  "Prompt the user to choose how to install the missing native module.
Returns \\='download, \\='compile, or nil."
  (let* ((url (or (ghostel--module-download-url ghostel--minimum-module-version)
                  "GitHub releases"))
         (choice (read-char-choice
                  (format "Ghostel native module not found.

  [d] Download pre-built binary from:
      %s
  [c] Compile from source via build.sh
  [s] Skip — install manually later

Choice: " url)
                  '(?d ?c ?s))))
    (pcase choice
      (?d 'download)
      (?c 'compile)
      (?s nil))))

(defun ghostel--download-file (url dest)
  "Download URL to DEST atomically.  Return the final URL on success, else nil.
The returned URL reflects any HTTP redirects followed during the
fetch, which lets callers resolve a `latest' alias to the actual
release tag.  Writes to a sibling temp file in the same directory
and renames it into place once the download succeeds.  Renaming
swaps the directory entry to a new inode, so any process (notably
a running Emacs) that has the previous DEST file mmap'd keeps a
valid mapping to the old file content.  Writing to DEST directly
would truncate the existing inode and corrupt that mapping."
  (let* ((url-request-method "GET")
         (url-show-status nil)
         (tmp (make-temp-name (concat dest ".tmp.")))
         (final-url nil))
    (unwind-protect
        (let ((buf (url-retrieve-synchronously url t t 30)))
          (when buf
            (unwind-protect
                (with-current-buffer buf
                  (set-buffer-multibyte nil)
                  (goto-char (point-min))
                  (when (re-search-forward "^HTTP/[0-9.]+ 200" nil t)
                    (when (re-search-forward "\r?\n\r?\n" nil t)
                      (let ((coding-system-for-write 'binary)
                            (start (point)))
                        (when (< start (point-max))
                          (write-region start (point-max) tmp nil 'silent)
                          (set-file-modes tmp #o755)
                          (rename-file tmp dest t)
                          ;; `url-current-object' tracks the URL of the
                          ;; final response after redirect-following, so
                          ;; latest-asset URLs resolve to /download/vX.Y.Z/.
                          (setq final-url
                                (or (and (boundp 'url-current-object)
                                         url-current-object
                                         (url-recreate-url url-current-object))
                                    url)))))))
              (when (buffer-live-p buf)
                (kill-buffer buf)))))
      (unless final-url
        (when (file-exists-p tmp)
          (ignore-errors (delete-file tmp)))))
    final-url))

(defun ghostel--package-directory ()
  "Return the directory ghostel is loaded from, or nil."
  (let ((src (or (locate-library "ghostel")
                 load-file-name buffer-file-name)))
    (and src (file-name-directory src))))

(defun ghostel--resource-root ()
  "Return the root directory holding shipped resources (etc/, vendor/).
Prefers whichever layout is actually on disk:
- dev / `package-vc-install': ghostel.el lives under `lisp/', so the
  resource root is the parent of the Lisp directory.
- MELPA-style flat install: `:files' flattens sources into the
  package root, so the resource root equals the Lisp directory.
Falls back to the Lisp directory itself when neither layout is
 detectable (e.g. a standalone ghostel.el on `load-path' without the
 shipped resources), so callers always get a sensible
 `default-directory' to work in."
  (when-let* ((lisp-dir (ghostel--package-directory)))
    (or (and (file-directory-p (expand-file-name "etc" lisp-dir)) lisp-dir)
        (let ((parent (file-name-as-directory
                       (expand-file-name ".." lisp-dir))))
          (and (file-directory-p (expand-file-name "etc" parent)) parent))
        lisp-dir)))

(defun ghostel--module-directory ()
  "Return the absolute directory where the native module lives.
Honours `ghostel-module-dir' and `ghostel-module-directory' before
falling back to the shipped resource root."
  (ghostel--effective-module-dir))

(defun ghostel--load-module-if-available (&optional dir prompt-user)
  "Load the native module from DIR when it exists.
When PROMPT-USER is non-nil, stale modules may trigger installation."
  (let* ((module-dir (ghostel--effective-module-dir dir))
         (loader-path (ghostel--loader-module-file-path module-dir))
         (runtime-specs (ghostel--native-runtime-specs module-dir))
         (runtime-bundle-files
          (append (mapcar (lambda (spec) (plist-get spec :manifest))
                          runtime-specs)
                  (delq nil (mapcar (lambda (spec) (plist-get spec :file))
                                    runtime-specs)))))
    (when (and (file-exists-p loader-path)
               (cl-every #'file-exists-p runtime-bundle-files))
      (ghostel--ensure-loader-loaded loader-path)
      (ghostel--bootstrap-native-runtime module-dir)
      (unless prompt-user
        (ghostel--check-module-version module-dir nil))
      t)))

;;;###autoload
(defun ghostel-download-module (&optional prompt-for-version)
  "Interactively download the pre-built native module for this platform.
With PROMPT-FOR-VERSION, prompt for a release tag to download.
Leaving the prompt empty downloads the latest release."
  (interactive "P")
  (let* ((dir (ghostel--effective-module-dir))
         (mod (ghostel--loader-module-file-path dir))
         (version (when prompt-for-version
                     (ghostel--read-module-download-version)))
         (latest-release (and prompt-for-version (null version))))
    (when (and (file-exists-p mod)
               (not (yes-or-no-p "Module already exists.  Re-download? ")))
      (user-error "Cancelled"))
    (if (ghostel--download-module dir version latest-release)
        (if (ghostel--native-runtime-ready-p)
            (progn
              (ghostel--reload-native-runtime)
              (ghostel--check-module-version dir)
              (message "ghostel: module loaded successfully"))
          (ghostel--ensure-loader-loaded mod)
          (ghostel--bootstrap-native-runtime dir)
          (ghostel--check-module-version dir)
          (message "ghostel: module loaded successfully"))
      (user-error "Download failed.  Try M-x ghostel-module-compile to build from source"))))

(defun ghostel--install-built-module-on-finish (compile-buf source-dir dest-dir)
  "Publish built native runtime artifacts when COMPILE-BUF finishes.
Registers a one-shot `compilation-finish-functions' handler that
filters on COMPILE-BUF and removes itself on first match.  Runtime
artifacts are read from SOURCE-DIR and published into DEST-DIR."
  (let (handler)
    (setq handler
          (lambda (buf status)
            (when (eq buf compile-buf)
              (remove-hook 'compilation-finish-functions handler)
              (when (string-match-p "finished" status)
                (condition-case err
                    (progn
                      (ghostel--publish-built-module-artifacts
                       (expand-file-name "zig-out/bin" source-dir)
                       dest-dir)
                      (message "ghostel: module installed at %s" dest-dir))
                  (error
                   (display-warning
                     'ghostel
                     (format "Build succeeded but publishing native runtime to %s failed: %s"
                             dest-dir (error-message-string err)))))))))
    (add-hook 'compilation-finish-functions handler)))

(defun ghostel-module-compile ()
  "Compile the ghostel native module by running zig build.
The output is shown in a `*compilation*' buffer.  When
`ghostel-module-directory' points outside the package tree, the
produced module is moved into that directory once the build
finishes."
  (interactive)
  (let* ((source-dir (ghostel--resource-root))
         (dest-dir (ghostel--effective-module-dir))
         (default-directory source-dir)
         (compile-buf (compile "zig build -Doptimize=ReleaseFast -Dcpu=baseline" t)))
    (unless (equal (file-name-as-directory (expand-file-name source-dir))
                   (file-name-as-directory (expand-file-name dest-dir)))
      (ghostel--install-built-module-on-finish compile-buf source-dir dest-dir))))


(defun ghostel--check-module-version (dir &optional prompt-user)
  "Check if the loaded module is older than required.
When the module version is below `ghostel--minimum-module-version',
warn unconditionally and, when PROMPT-USER is non-nil, offer to
update using `ghostel-module-auto-install'.  DIR is the module
directory.  At load time PROMPT-USER is nil so a stale module never
triggers an interactive prompt."
  (let ((mod-ver (and (fboundp 'ghostel--module-version)
                      (ghostel--module-version))))
    (when (or (null mod-ver)
              (version< mod-ver ghostel--minimum-module-version))
      (display-warning 'ghostel
                       (format "Module version %s is older than required %s"
                               (or mod-ver "unknown")
                               ghostel--minimum-module-version))
      (when prompt-user
        (ghostel--ensure-module dir)))))

(defun ghostel--initialize-native-modules (&optional prompt-user)
  "Load or refresh the native modules for the current Ghostel install.
When PROMPT-USER is non-nil, failures signal `user-error'."
  (let* ((dir (ghostel--effective-module-dir))
         (mod (ghostel--loader-module-file-path dir))
         (runtime-specs (ghostel--native-runtime-specs dir))
         (runtime-manifests (mapcar (lambda (spec) (plist-get spec :manifest))
                                    runtime-specs))
         (runtime-files (delq nil (mapcar (lambda (spec) (plist-get spec :file))
                                          runtime-specs)))
         (runtime-bundle-files (append runtime-manifests runtime-files)))
    (unless (or (and (file-exists-p mod)
                     (cl-every #'file-exists-p runtime-bundle-files))
                (not prompt-user)
                noninteractive)
      (ghostel--ensure-module dir))
    (if (and (file-exists-p mod)
             (cl-every #'file-exists-p runtime-bundle-files))
        (condition-case err
            (if (featurep 'dyn-loader-module)
                (if (ghostel--live-buffers)
                    (display-warning
                     'ghostel
                     "Ghostel native module is already loaded with live buffers; restart Emacs or reload the native module after closing Ghostel terminals")
                  (ghostel-reload-module))
              (ghostel--load-module-if-available dir prompt-user))
          (error
           (let ((msg
                  (if ghostel-module-dir
                      (format "Failed to load native module: %s\nCheck or replace the module in %s"
                              (error-message-string err)
                              dir)
                    (format "Failed to load native module: %s\nTry M-x ghostel-module-compile to rebuild"
                            (error-message-string err)))))
             (if prompt-user
                 (user-error "%s" msg)
               (display-warning 'ghostel msg)))))
      (let* ((missing-bundle-file
              (cl-find-if (lambda (path)
                            (not (file-exists-p path)))
                          runtime-bundle-files))
             (msg
              (if ghostel-module-dir
                  (if (file-exists-p mod)
                      (if (member missing-bundle-file runtime-manifests)
                          (concat "Native module metadata not found: " missing-bundle-file
                                  "\nRun M-x ghostel-download-module or install/copy the module there")
                        (concat "Native runtime file not found: " missing-bundle-file
                                "\nRun M-x ghostel-download-module or install/copy the module there"))
                    (concat "Native module not found: " mod
                            "\nRun M-x ghostel-download-module or install/copy the module there"))
                (if (file-exists-p mod)
                    (if (member missing-bundle-file runtime-manifests)
                        (concat "Native module metadata not found: " missing-bundle-file
                                "\nRun M-x ghostel-download-module or M-x ghostel-module-compile")
                      (concat "Native runtime file not found: " missing-bundle-file
                              "\nRun M-x ghostel-download-module or M-x ghostel-module-compile"))
                  (concat "Native module not found: " mod
                          "\nRun M-x ghostel-download-module or M-x ghostel-module-compile")))))
        (if prompt-user
            (user-error "%s" msg)
          (display-warning 'ghostel msg))))))

(defun ghostel--load-module (&optional prompt-user)
  "Ensure the ghostel native module is loaded.
When PROMPT-USER is non-nil (called from an interactive command like
`ghostel'), missing or stale modules trigger
`ghostel-module-auto-install' and load failures signal `user-error'
so the calling flow aborts.  Otherwise (load time, including
byte-compilation and Emacs 31's `user-lisp/' auto-compile), this
function never prompts, downloads, or compiles - it only loads an
existing module file and warns if one is missing or stale.  Module
installation only happens on an explicit user action: `M-x ghostel',
`M-x ghostel-download-module', or `M-x ghostel-module-compile'.

The guard also honours `ghostel--new' being already `fboundp', which
covers the pure-Elisp test path where `cl-letf' stubs the native
entry points so tests run without the module present."
  (let ((dir (ghostel--effective-module-dir))
        (stubbed-runtime
         (and (fboundp 'ghostel--new)
              (not (or (featurep 'ghostel-module)
                       (featurep 'dyn-loader-module))))))
    (unless (or (ghostel--native-runtime-ready-p) stubbed-runtime)
      (ghostel--initialize-native-modules prompt-user))
    ;; Surface stale live runtimes at interactive entry.
    (when (and prompt-user
               (ghostel--native-runtime-ready-p)
               (not stubbed-runtime))
      (ghostel--check-module-version dir t))
    (when (and prompt-user
               (not (or (ghostel--native-runtime-ready-p) stubbed-runtime)))
      (user-error "Ghostel native module not available"))))


(defun ghostel--native-runtime-ready-p ()
  "Return non-nil when Ghostel's dyn-loader-managed runtime is ready."
  (and (cl-every #'fboundp ghostel--native-runtime-required-functions)
       (ghostel--native-runtime-reloadable-p)))

(provide 'ghostel-module-install)
;;; ghostel-module-install.el ends here
