;;; ghostel-tramp-test.el --- Tests for ghostel: tramp -*- lexical-binding: t; -*-

;;; Commentary:

;; TRAMP integration, login wrap, remote start-process, environment plumbing,
;; window-size SIGWINCH, real-process resize.

;;; Code:

(require 'ghostel-test-helpers)

(defmacro ghostel-test--with-spawn-capture (capture &rest body)
  "Bind CAPTURE to the (PROGRAM . ARGS) cons passed to `ghostel--spawn-pty'.
Stubs out `ghostel--spawn-pty' so no real process is spawned.  BODY
runs with the stub in place."
  (declare (indent 1))
  `(let (,capture)
     (cl-letf (((symbol-function 'ghostel--spawn-pty)
                (lambda (program args &rest _)
                  (setq ,capture (cons program args))
                  nil)))
       ,@body)))

(defconst ghostel-test--bash (executable-find "bash")
  "Absolute path to bash, or nil if not found.
The baseline SIGWINCH tests explicitly use bash because trap-on-signal
behavior for an idle shell reading stdin differs across implementations
\(bash delivers immediately; dash defers until the next input line\).")

;;; Rendering / resize pipeline tests moved to `ghostel-render-test.el`.


(ert-deftest ghostel-test-local-host-p ()
  "Test local hostname detection."
  (should (ghostel--local-host-p nil))
  (should (ghostel--local-host-p ""))
  (should (ghostel--local-host-p "localhost"))
  (should (ghostel--local-host-p (system-name)))
  (should (ghostel--local-host-p (car (split-string (system-name) "\\."))))
  (should-not (ghostel--local-host-p "remote-server.example.com")))

(ert-deftest ghostel-test-get-shell-local ()
  "Test that local shell resolution returns `ghostel-shell'."
  (let ((default-directory "/tmp/")
        (ghostel-shell "/bin/zsh"))
    (should (equal "/bin/zsh" (ghostel--get-shell)))))

(ert-deftest ghostel-test-shell-program-and-args-string ()
  "String SPEC splits into (PROGRAM . nil)."
  (should (equal '("/bin/zsh") (ghostel--shell-program-and-args "/bin/zsh"))))

(ert-deftest ghostel-test-shell-program-and-args-list ()
  "List SPEC splits into (PROGRAM . ARGS)."
  (let ((split (ghostel--shell-program-and-args '("/bin/zsh" "--login" "-i"))))
    (should (equal "/bin/zsh" (car split)))
    (should (equal '("--login" "-i") (cdr split)))))

(ert-deftest ghostel-test-shell-program-and-args-invalid ()
  "Invalid SPEC signals an error."
  (should-error (ghostel--shell-program-and-args 42))
  (should-error (ghostel--shell-program-and-args nil))
  (should-error (ghostel--shell-program-and-args '()))
  (should-error (ghostel--shell-program-and-args '(nil "foo"))))

(ert-deftest ghostel-test-get-shell-local-returns-program-from-list ()
  "When `ghostel-shell' is a list, `ghostel--get-shell' returns just the program."
  (let ((default-directory "/tmp/")
        (ghostel-shell '("/bin/zsh" "--login")))
    (should (equal "/bin/zsh" (ghostel--get-shell)))))

(ert-deftest ghostel-test-macos-login-wrap-basic ()
  "Login wrap produces /usr/bin/login + bash shim with exec -l <prog>."
  (cl-letf (((symbol-function 'user-login-name) (lambda () "alice"))
            ((symbol-function 'file-exists-p) (lambda (_) nil)))
    (let* ((wrap (ghostel--macos-login-wrap "/bin/zsh" nil))
           (program (car wrap))
           (args (cdr wrap)))
      (should (equal "/usr/bin/login" program))
      ;; No -q without hushlogin.
      (should-not (member "-q" args))
      (should (equal "-flp" (nth 0 args)))
      (should (equal "alice" (nth 1 args)))
      (should (equal "/bin/bash" (nth 2 args)))
      (should (equal "--noprofile" (nth 3 args)))
      (should (equal "--norc" (nth 4 args)))
      (should (equal "-c" (nth 5 args)))
      ;; exec -l <quoted-program>; no extra args.
      (should (equal "exec -l /bin/zsh" (nth 6 args))))))

(ert-deftest ghostel-test-macos-login-wrap-hushlogin ()
  "When ~/.hushlogin exists, -q is prepended."
  (let ((hush-path (expand-file-name "~/.hushlogin")))
    (cl-letf (((symbol-function 'user-login-name) (lambda () "alice"))
              ((symbol-function 'file-exists-p)
               (lambda (p) (equal p hush-path))))
      (let* ((wrap (ghostel--macos-login-wrap "/bin/zsh" nil))
             (args (cdr wrap)))
        (should (equal "-q" (nth 0 args)))
        (should (equal "-flp" (nth 1 args)))
        (should (equal "alice" (nth 2 args)))))))

(ert-deftest ghostel-test-macos-login-wrap-extra-args ()
  "Extra ARGS are shell-quoted into the `exec -l' command string."
  (cl-letf (((symbol-function 'user-login-name) (lambda () "alice"))
            ((symbol-function 'file-exists-p) (lambda (_) nil)))
    (let* ((wrap (ghostel--macos-login-wrap "/bin/bash" '("--login" "--posix")))
           (cmd (nth 6 (cdr wrap))))
      (should (equal "exec -l /bin/bash --login --posix" cmd)))))

(ert-deftest ghostel-test-start-process-darwin-login-wrap ()
  "On darwin with `ghostel-macos-login-shell', wrap shell via `/usr/bin/login'."
  (cl-letf (((symbol-function 'user-login-name) (lambda () "alice"))
            ((symbol-function 'file-exists-p) (lambda (_) nil)))
    (ghostel-test--with-spawn-capture spawn
      (with-temp-buffer
        (setq-local ghostel--term-rows 24
                    ghostel--term-cols 80)
        (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
               (ghostel-shell "/bin/zsh")
               (ghostel-shell-integration nil)
               (ghostel-macos-login-shell t)
               (system-type 'darwin)
               (default-directory "/tmp/"))
          (ghostel--start-process)
          (should (equal "/usr/bin/login" (car spawn)))
          (let ((args (cdr spawn)))
            (should-not (member "-q" args))
            (should (equal '("-flp" "alice"
                             "/bin/bash" "--noprofile" "--norc"
                             "-c" "exec -l /bin/zsh")
                           args))))))))

(ert-deftest ghostel-test-start-process-darwin-login-wrap-opt-out ()
  "Setting `ghostel-macos-login-shell' to nil disables the wrap on darwin."
  (ghostel-test--with-spawn-capture spawn
    (with-temp-buffer
      (setq-local ghostel--term-rows 24
                  ghostel--term-cols 80)
      (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
             (ghostel-shell "/bin/zsh")
             (ghostel-shell-integration nil)
             (ghostel-macos-login-shell nil)
             (system-type 'darwin)
             (default-directory "/tmp/"))
        (ghostel--start-process)
        (should (equal "/bin/zsh" (car spawn)))
        (should (null (cdr spawn)))))))

(ert-deftest ghostel-test-start-process-non-darwin-no-login-wrap ()
  "Login wrap is not applied on non-Darwin platforms even when opted in."
  (ghostel-test--with-spawn-capture spawn
    (with-temp-buffer
      (setq-local ghostel--term-rows 24
                  ghostel--term-cols 80)
      (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
             (ghostel-shell "/bin/zsh")
             (ghostel-shell-integration nil)
             (ghostel-macos-login-shell t)
             (system-type 'gnu/linux)
             (default-directory "/tmp/"))
        (ghostel--start-process)
        (should (equal "/bin/zsh" (car spawn)))
        (should (null (cdr spawn)))))))

(ert-deftest ghostel-test-start-process-list-shell-passes-args ()
  "When `ghostel-shell' is a list, extra args reach `ghostel--spawn-pty'."
  (ghostel-test--with-spawn-capture spawn
    (with-temp-buffer
      (setq-local ghostel--term-rows 24
                  ghostel--term-cols 80)
      (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
             (ghostel-shell '("/bin/zsh" "--login"))
             (ghostel-shell-integration nil)
             (ghostel-macos-login-shell nil)
             (system-type 'gnu/linux)
             (default-directory "/tmp/"))
        (ghostel--start-process)
        (should (equal "/bin/zsh" (car spawn)))
        (should (equal '("--login") (cdr spawn)))))))

(ert-deftest ghostel-test-start-process-list-shell-combines-with-integration ()
  "List shell args combine with bash integration's `--posix' arg."
  (ghostel-test--with-spawn-capture spawn
    (with-temp-buffer
      (setq-local ghostel--term-rows 24
                  ghostel--term-cols 80)
      (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
             (ghostel-shell '("/bin/bash" "--login"))
             (ghostel-shell-integration t)
             (ghostel-macos-login-shell nil)
             (system-type 'gnu/linux)
             (default-directory "/tmp/"))
        (ghostel--start-process)
        (should (equal "/bin/bash" (car spawn)))
        ;; Extra args precede integration args.
        (should (equal '("--login" "--posix") (cdr spawn)))))))

(ert-deftest ghostel-test-start-process-darwin-login-wrap-with-integration ()
  "Wrap + list shell + bash integration: all three layers compose correctly."
  (cl-letf (((symbol-function 'user-login-name) (lambda () "alice"))
            ((symbol-function 'file-exists-p) (lambda (_) nil)))
    (ghostel-test--with-spawn-capture spawn
      (with-temp-buffer
        (setq-local ghostel--term-rows 24
                    ghostel--term-cols 80)
        (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
               (ghostel-shell '("/bin/bash" "--login"))
               (ghostel-shell-integration t)
               (ghostel-macos-login-shell t)
               (system-type 'darwin)
               (default-directory "/tmp/"))
          (ghostel--start-process)
          (should (equal "/usr/bin/login" (car spawn)))
          (should (equal '("-flp" "alice"
                           "/bin/bash" "--noprofile" "--norc"
                           "-c" "exec -l /bin/bash --login --posix")
                         (cdr spawn))))))))

(ert-deftest ghostel-test-start-process-sets-size-via-stty-not-env ()
  "Initial terminal size must be baked into the `stty' wrapper, not env vars.
Setting `LINES'/`COLUMNS' env vars freezes ncurses apps like htop at
start-up size and breaks live resize."
  :tags '(native)
  (skip-unless (not (eq system-type 'windows-nt)))
  (let ((captured-env nil)
        (orig-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest plist)
                 (setq captured-env process-environment)
                 (apply orig-make-process plist))))
      (with-temp-buffer
        (setq-local ghostel--term-rows 43
                    ghostel--term-cols 137)
        (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
               (ghostel-shell "/bin/sh")
               (ghostel-shell-integration nil)
               (default-directory "/tmp/")
               (proc (ghostel--start-process)))
          (unwind-protect
              (let ((cmd (process-command proc)))
                (should (equal #'ghostel--window-adjust-process-window-size
                               (process-get proc 'adjust-window-size-function)))
                (should (equal '("/bin/sh" "-c") (seq-take cmd 2)))
                (should (string-match-p "stty .* rows 43 columns 137"
                                        (nth 2 cmd)))
                (should (string-match-p "-ixon" (nth 2 cmd)))
                (should-not (seq-some (lambda (s) (string-prefix-p "LINES=" s))
                                      captured-env))
                (should-not (seq-some (lambda (s) (string-prefix-p "COLUMNS=" s))
                                      captured-env))
                (should (member "TERM=xterm-ghostty" captured-env))
                (should (member "TERM_PROGRAM=ghostty" captured-env))
                ;; Match by regex so version bumps don't break the test —
                ;; the contract is "exported and parseable as semver",
                ;; not a literal string.
                (should (seq-some (lambda (s)
                                    (string-match-p
                                     "\\`TERM_PROGRAM_VERSION=[0-9]+\\.[0-9]+\\.[0-9]+\\'"
                                     s))
                                  captured-env))
                (should (seq-some (lambda (s) (string-prefix-p "TERMINFO=" s))
                                  captured-env))
                (should (member "COLORTERM=truecolor" captured-env)))
            (when (process-live-p proc)
              (delete-process proc))))))))

(ert-deftest ghostel-test-start-process-respects-ghostel-term-opt-out ()
  "Setting `ghostel-term' to xterm-256color drops the Ghostty advertisement.
TERMINFO and TERM_PROGRAM must not leak through when the user opts
out — otherwise outbound `ssh' (or any consumer of those vars) would
falsely conclude that ghostty is the controlling terminal."
  :tags '(native)
  (skip-unless (not (eq system-type 'windows-nt)))
  (let ((captured-env nil)
        (orig-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest plist)
                 (setq captured-env process-environment)
                 (apply orig-make-process plist))))
      (with-temp-buffer
        (setq-local ghostel--term-rows 25
                    ghostel--term-cols 80)
        (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
               (ghostel-shell "/bin/sh")
               (ghostel-shell-integration nil)
               (ghostel-term "xterm-256color")
               (default-directory "/tmp/")
               (proc (ghostel--start-process)))
          (unwind-protect
              (progn
                (should (member "TERM=xterm-256color" captured-env))
                (should (member "COLORTERM=truecolor" captured-env))
                (should-not (seq-some (lambda (s) (string-prefix-p "TERMINFO=" s))
                                      captured-env))
                (should-not (member "TERM_PROGRAM=ghostty" captured-env))
                (should-not (seq-some (lambda (s)
                                        (string-prefix-p "TERM_PROGRAM_VERSION=" s))
                                      captured-env)))
            (when (process-live-p proc)
              (delete-process proc))))))))

(ert-deftest ghostel-test-start-process-ssh-install-exports-env ()
  "`ghostel-ssh-install-terminfo' must export GHOSTEL_SSH_INSTALL_TERMINFO=1.
The bundled bash/zsh/fish integration scripts gate the outbound
`ssh' install-and-cache wrapper on this env var, so the elisp custom
is the single source of truth.

The `auto' default follows `ghostel-tramp-shell-integration': enabled
when that's non-nil, off otherwise.  Setting it to t forces on,
setting it to nil forces off."
  :tags '(native)
  (skip-unless (not (eq system-type 'windows-nt)))
  (let ((captured-env nil)
        (orig-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest plist)
                 (setq captured-env process-environment)
                 (apply orig-make-process plist))))
      (with-temp-buffer
        (setq-local ghostel--term-rows 25
                    ghostel--term-cols 80)
        (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
               (ghostel-shell "/bin/sh")
               (ghostel-shell-integration nil)
               ;; Without this, the per-iteration `delete-process' fires
               ;; the sentinel which kills our `with-temp-buffer' buffer,
               ;; flipping `current-buffer' (and its `default-directory')
               ;; for subsequent iterations.
               (ghostel-kill-buffer-on-exit nil)
               (default-directory "/tmp/"))
          ;; auto + tramp-shell-integration nil → not exported.
          (setq captured-env nil)
          (let* ((ghostel-ssh-install-terminfo 'auto)
                 (ghostel-tramp-shell-integration nil)
                 (proc (ghostel--start-process)))
            (unwind-protect
                (should-not (member "GHOSTEL_SSH_INSTALL_TERMINFO=1"
                                    captured-env))
              (when (process-live-p proc) (delete-process proc))))
          ;; auto + tramp-shell-integration t → exported.
          (setq captured-env nil)
          (let* ((ghostel-ssh-install-terminfo 'auto)
                 (ghostel-tramp-shell-integration t)
                 (proc (ghostel--start-process)))
            (unwind-protect
                (should (member "GHOSTEL_SSH_INSTALL_TERMINFO=1"
                                captured-env))
              (when (process-live-p proc) (delete-process proc))))
          ;; Forced on.
          (setq captured-env nil)
          (let* ((ghostel-ssh-install-terminfo t)
                 (ghostel-tramp-shell-integration nil)
                 (proc (ghostel--start-process)))
            (unwind-protect
                (should (member "GHOSTEL_SSH_INSTALL_TERMINFO=1"
                                captured-env))
              (when (process-live-p proc) (delete-process proc))))
          ;; Forced off (overrides tramp-shell-integration).
          (setq captured-env nil)
          (let* ((ghostel-ssh-install-terminfo nil)
                 (ghostel-tramp-shell-integration t)
                 (proc (ghostel--start-process)))
            (unwind-protect
                (should-not (member "GHOSTEL_SSH_INSTALL_TERMINFO=1"
                                    captured-env))
              (when (process-live-p proc) (delete-process proc))))
          ;; Local TERM opt-out (`ghostel-term' /= xterm-ghostty)
          ;; suppresses the SSH-install advertisement even when forced
          ;; on — otherwise outbound ssh would falsely claim ghostty
          ;; while the local buffer is plain xterm-256color.
          (setq captured-env nil)
          (let* ((ghostel-term "xterm-256color")
                 (ghostel-ssh-install-terminfo t)
                 (ghostel-tramp-shell-integration t)
                 (proc (ghostel--start-process)))
            (unwind-protect
                (should-not (member "GHOSTEL_SSH_INSTALL_TERMINFO=1"
                                    captured-env))
              (when (process-live-p proc) (delete-process proc))))
          ;; Bundled terminfo missing (e.g. broken install): the env
          ;; helper falls back to TERM=xterm-256color *and* must
          ;; suppress GHOSTEL_SSH_INSTALL_TERMINFO so the wrapper
          ;; doesn't try to advertise xterm-ghostty over ssh.
          (setq captured-env nil)
          (cl-letf (((symbol-function #'ghostel--terminfo-directory)
                     (lambda () nil))
                    ;; Suppress the one-shot fallback warning during
                    ;; the test so it doesn't pollute output.
                    (ghostel--terminfo-warned t))
            (let* ((ghostel-term "xterm-ghostty")
                   (ghostel-ssh-install-terminfo t)
                   (ghostel-tramp-shell-integration t)
                   (proc (ghostel--start-process)))
              (unwind-protect
                  (progn
                    (should (member "TERM=xterm-256color" captured-env))
                    (should-not (member "GHOSTEL_SSH_INSTALL_TERMINFO=1"
                                        captured-env)))
                (when (process-live-p proc) (delete-process proc))))))))))

(ert-deftest ghostel-test-remote-term-preamble ()
  "`ghostel--remote-term-preamble' embeds an `infocmp' probe.
The probe runs *on the remote* (inside the per-spawn wrapper), so
TERM is decided after env propagation — sidestepping
`tramp-local-environment-variable-p', which would otherwise strip
`TERM=' entries that match the local default top-level
`process-environment' and leave the remote shell to inherit
TERM=dumb (issue #224).

A single probe path covers every case: auto-integration (TERMINFO=
already in env, points at the pushed terminfo dir),
manually-installed (system, `~/.terminfo', or co-located with the
shell-integration scripts under `~/.local/share/ghostel/terminfo'),
and absent (fall back to `xterm-256color' so echo works)."
  (let* ((ghostel-term "xterm-ghostty")
         (preamble (ghostel--remote-term-preamble)))
    ;; Default value for the case infocmp fails.
    (should (string-match-p "\\bTERM=\"?xterm-256color\"?;" preamble))
    ;; Probe and conditional upgrade.
    (should (string-match-p "infocmp xterm-ghostty" preamble))
    (should (string-match-p "\\bTERM=\"?xterm-ghostty\"?;" preamble))
    (should (string-match-p "TERM_PROGRAM=ghostty;" preamble))
    (should (string-match-p "TERM_PROGRAM_VERSION=" preamble))
    ;; Co-located bundle gets prepended to TERMINFO_DIRS — so a
    ;; user can `scp` the terminfo dir alongside the shell
    ;; scripts and the probe finds it without `tic` or
    ;; ~/.terminfo gymnastics.
    (should (string-match-p
             "~/\\.local/share/ghostel/terminfo/x/xterm-ghostty"
             preamble))
    (should (string-match-p
             "~/\\.local/share/ghostel/terminfo/78/xterm-ghostty"
             preamble))
    (should (string-match-p
             (regexp-quote
              "TERMINFO_DIRS=~/.local/share/ghostel/terminfo")
             preamble))
    ;; Existing TERMINFO_DIRS must be preserved (prepend, not
    ;; replace) so a system-configured search list still works.
    (should (string-match-p (regexp-quote "${TERMINFO_DIRS:+:$TERMINFO_DIRS}")
                            preamble))
    ;; Order is load-bearing: the TERMINFO_DIRS prepend must run
    ;; BEFORE the `infocmp' probe, otherwise ncurses won't find the
    ;; co-located bundle and the probe falls back to xterm-256color.
    (should (< (string-match (regexp-quote
                              "TERMINFO_DIRS=~/.local/share/ghostel/terminfo")
                             preamble)
               (string-match "infocmp xterm-ghostty" preamble)))
    ;; Always exported.
    (should (string-match-p "COLORTERM=truecolor" preamble))
    (should (string-match-p "export TERM COLORTERM" preamble)))
  ;; Customized `ghostel-term' is honored verbatim — no probe, no
  ;; ghostty advertisement, no TERMINFO_DIRS munging.
  (let* ((ghostel-term "xterm-256color")
         (preamble (ghostel--remote-term-preamble)))
    (should-not (string-match-p "infocmp" preamble))
    (should-not (string-match-p "TERM_PROGRAM=ghostty" preamble))
    (should-not (string-match-p "TERMINFO_DIRS" preamble))
    (should (string-match-p "TERM=\"?xterm-256color\"?" preamble))
    (should (string-match-p "COLORTERM=truecolor" preamble)))
  (let* ((ghostel-term "screen-256color")
         (preamble (ghostel--remote-term-preamble)))
    (should-not (string-match-p "infocmp" preamble))
    (should (string-match-p "TERM=\"?screen-256color\"?" preamble))))

(ert-deftest ghostel-test-spawn-pty-uses-remote-term-preamble ()
  "`ghostel--spawn-pty' embeds the remote preamble in the wrapper script.
The preamble runs on the remote, so TERM is set after TRAMP's
env propagation — sidestepping `tramp-local-environment-variable-p'
which would otherwise strip `TERM=' entries that match the local
default toplevel and leave the remote shell with TERM=dumb (#224).

Local spawns must not get the preamble; their TERM still rides in
`process-environment' via `ghostel--terminal-env'."
  ;; First cl-letf of `make-process' in a fresh Emacs would trigger
  ;; native-comp of a subr trampoline; disable to keep the test
  ;; portable across machines without a working gccjit toolchain.
  (let ((native-comp-enable-subr-trampolines nil))
    (with-temp-buffer
      (setq-local ghostel--term-rows 25 ghostel--term-cols 80
                  ;; The wrapped `make-process' below still calls the
                  ;; real one via apply; needs a directory it can chdir
                  ;; into.  /tmp is the safe default already used by
                  ;; sibling tests.
                  default-directory "/tmp/")
      (let ((ghostel-term "xterm-ghostty")
            (ghostel-kill-buffer-on-exit nil)
            (orig-make-process (symbol-function #'make-process)))
        ;; Remote spawn → preamble in wrapper, TERM/TERMINFO not
        ;; added by ghostel.  Use a clean `process-environment' so
        ;; the assertion is about ghostel's contribution, not the
        ;; test runner's ambient env.
        (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
               (captured-env nil)
               (captured-cmd nil))
          (cl-letf (((symbol-function #'make-process)
                     (lambda (&rest plist)
                       (setq captured-env process-environment)
                       (setq captured-cmd (plist-get plist :command))
                       (apply orig-make-process plist))))
            (let ((proc (ghostel--spawn-pty
                         "/bin/sh" nil 25 80 "-ixon" nil t)))
              (unwind-protect
                  (let ((script (nth 2 captured-cmd)))
                    (should (string-match-p "infocmp xterm-ghostty" script))
                    (should (string-match-p "export TERM COLORTERM" script))
                    ;; Ghostel must not push the local TERMINFO path —
                    ;; it points at a dir the remote can't read and
                    ;; (per terminfo(5)) suppresses system lookups.
                    (should-not (seq-some
                                 (lambda (s) (string-prefix-p "TERMINFO=" s))
                                 captured-env))
                    ;; TERM also stays out of env — wrapper handles it.
                    (should-not (member "TERM=xterm-ghostty" captured-env)))
                (when (process-live-p proc) (delete-process proc))))))
        ;; Local spawn → no preamble, env-driven TERM.
        (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
               (captured-env nil)
               (captured-cmd nil))
          (cl-letf (((symbol-function #'make-process)
                     (lambda (&rest plist)
                       (setq captured-env process-environment)
                       (setq captured-cmd (plist-get plist :command))
                       (apply orig-make-process plist))))
            (let ((proc (ghostel--spawn-pty
                         "/bin/sh" nil 25 80 "-ixon" nil nil)))
              (unwind-protect
                  (let ((script (nth 2 captured-cmd)))
                    (should-not (string-match-p "infocmp" script))
                    (should (member "TERM=xterm-ghostty" captured-env)))
                (when (process-live-p proc) (delete-process proc))))))))))

(ert-deftest ghostel-test-tramp-inside-emacs-preserves-ghostel-prefix ()
  "TRAMP rewrites INSIDE_EMACS but must preserve the user-set prefix.
The README's manual remote-integration gate
  [[ \"${INSIDE_EMACS%%,*}\" = \\='ghostel\\=' ]]
relies on `tramp-inside-emacs' appending `,tramp:VER' to the
existing `INSIDE_EMACS' value rather than wholly overwriting it.
If TRAMP ever changes that contract, the gate silently stops
matching on TRAMP-launched ghostel remotes — this canary catches it."
  (require 'tramp)
  (let ((process-environment
         (cons "INSIDE_EMACS=ghostel" process-environment)))
    (let ((rewritten (tramp-inside-emacs)))
      (should (string-prefix-p "ghostel," rewritten))
      (should (string-match-p ",tramp:" rewritten)))))

(ert-deftest ghostel-test-environment-precedes-internal-env ()
  "`ghostel-environment' entries must come before ghostel's own env vars.
When a user sets TERM via `ghostel-environment', it must win over the
internal `TERM=xterm-ghostty' so a `process-environment' lookup (which
returns the first match) resolves to the user's value."
  (let ((captured-env nil)
        (orig-make-pipe-process (symbol-function #'make-pipe-process))
        (default-dir (file-name-as-directory temporary-file-directory)))
    (cl-letf (((symbol-function #'window-body-height)
               (lambda (&optional _w) 25))
              ((symbol-function #'window-max-chars-per-line)
               (lambda (&optional _w) 80))
              ((symbol-function #'make-process)
               (lambda (&rest plist)
                 (setq captured-env process-environment)
                 (ignore plist)
                 (make-pipe-process :name "ghostel-test-fake"
                                    :buffer (current-buffer)
                                    :noquery t
                                    :filter #'ignore
                                    :sentinel #'ignore)))
              ((symbol-function #'make-pipe-process)
               (lambda (&rest plist)
                 (setq captured-env process-environment)
                 (apply orig-make-pipe-process plist)))
              ((symbol-function #'set-process-window-size) #'ignore)
              ((symbol-function #'set-process-coding-system) #'ignore)
              ((symbol-function #'set-process-query-on-exit-flag) #'ignore)
              ((symbol-function #'process-put) (lambda (&rest _) nil))
              ((symbol-function #'conpty--init)
               (lambda (&rest _)
                 (setq captured-env process-environment)
                 t)))
      (with-temp-buffer
        ;; `ghostel--start-process' reads dims from these buffer-locals
        ;; (set by `ghostel--init-buffer' in the real flow).
        (setq-local ghostel--term-rows 25
                    ghostel--term-cols 80)
        (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
               (ghostel-shell "/bin/sh")
               (ghostel-shell-integration nil)
               (ghostel-environment '("TERM=dumb" "MY_VAR=42"))
               (default-directory default-dir)
               (proc (ghostel--start-process)))
          (unwind-protect
              (let* ((term-idx (seq-position captured-env "TERM=dumb"))
                     (default-term-idx
                      (and term-idx
                           (cl-position-if
                            (lambda (entry)
                              (and (string-prefix-p "TERM=" entry)
                                   (not (equal entry "TERM=dumb"))))
                            captured-env
                            :start (1+ term-idx)))))
                (should (member "MY_VAR=42" captured-env))
                (should term-idx)
                (should default-term-idx)
                (should (< term-idx default-term-idx)))
            (when (process-live-p proc) (delete-process proc))))))))

(ert-deftest ghostel-test-environment-applies-to-compile ()
  "`ghostel-compile--spawn' must prepend `ghostel-environment'.
The splice lives in the compile spawn (separate from `ghostel--spawn-pty'),
so this path needs its own coverage — without it, users setting
`CC=clang' would see it take effect in shells but silently miss for
compile jobs.  Also pins the position: `compilation-environment'
entries must precede `ghostel-environment', and both must precede
ghostel's own `INSIDE_EMACS=...,compile' marker."
  (let ((captured-env nil)
        (orig-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest plist)
                 (setq captured-env process-environment)
                 (apply orig-make-process plist))))
      (with-temp-buffer
        (let* ((default-directory "/tmp/")
               (compilation-environment '("COMPENV=first"))
               (ghostel-environment '("CC=clang"))
               (proc (ghostel-compile--spawn "true" (current-buffer) 24 80)))
          (unwind-protect
              (let ((compenv-idx (seq-position captured-env "COMPENV=first"))
                    (cc-idx      (seq-position captured-env "CC=clang"))
                    (inside-idx  (cl-position-if
                                  (lambda (s)
                                    (string-prefix-p "INSIDE_EMACS=" s))
                                  captured-env)))
                (should compenv-idx)
                (should cc-idx)
                (should inside-idx)
                (should (< compenv-idx cc-idx))
                (should (< cc-idx inside-idx)))
            (when (process-live-p proc) (delete-process proc))))))))

(ert-deftest ghostel-test-environment-honors-dir-locals ()
  "End-to-end: a real `.dir-locals.el' populates `ghostel-environment'.
Covers the whole pipeline (`hack-dir-local-variables' reading the
file, the safety gate, and buffer-local assignment) — not just the
final `setq-local'."
  (let* ((dir (file-name-as-directory (make-temp-file "ghostel-dl-" t)))
         (dl  (expand-file-name ".dir-locals.el" dir))
         (buf (generate-new-buffer " *ghostel-dl-test*")))
    (unwind-protect
        (progn
          (with-temp-file dl
            (insert
             "((ghostel-mode . ((ghostel-environment . (\"FOO=1\" \"BAR=2\")))))"))
          (with-current-buffer buf
            (setq-local default-directory dir)
            (ghostel-mode)
            (should (local-variable-p 'ghostel-environment))
            (should (equal ghostel-environment '("FOO=1" "BAR=2")))))
      (when (buffer-live-p buf) (kill-buffer buf))
      (when (file-exists-p dir)
        (delete-directory dir t)))))

(ert-deftest ghostel-test-environment-rejects-unsafe-dir-locals ()
  "An unsafe `ghostel-environment' value in dir-locals must be rejected.
Guards against a malicious `.dir-locals.el' that tries to smuggle a
non-list/non-string value past the usual `safe-local-variable-p'
machinery."
  (let ((buf (generate-new-buffer " *ghostel-unsafe-test*")))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'hack-dir-local-variables)
                     (lambda ()
                       (setq-local dir-local-variables-alist
                                   '((ghostel-environment . "not-a-list"))))))
            (ghostel-mode))
          (should-not (local-variable-p 'ghostel-environment)))
      (kill-buffer buf))))

(ert-deftest ghostel-test-terminfo-directory-finds-bundled ()
  "`ghostel--terminfo-directory' must locate the bundled compiled entries.
The package ships compiled terminfo for both macOS (78/) and Linux (x/)
layouts; if neither is present after install, the lookup must return
nil so the fallback warning fires."
  (let ((dir (ghostel--terminfo-directory)))
    (should dir)
    (should (file-directory-p dir))
    (should (or (file-readable-p (expand-file-name "78/xterm-ghostty" dir))
                (file-readable-p (expand-file-name "x/xterm-ghostty" dir))))))

(ert-deftest ghostel-test-start-process-local-bash-integration-keeps-early-echo ()
  "Local bash integration must keep `stty echo' in the wrapper.
Old bash versions can initialize readline before the ENV-injected
integration script runs, so input echo must be enabled before exec.
`sane' in `ghostel--default-stty' is what guarantees echo here."
  :tags '(native)
  (skip-unless (not (eq system-type 'windows-nt)))
  (let ((captured-env nil)
        (orig-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest plist)
                 (setq captured-env process-environment)
                 (apply orig-make-process plist))))
      (with-temp-buffer
        (setq-local ghostel--term-rows 25
                    ghostel--term-cols 80)
        (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
               (ghostel-shell "/bin/bash")
               (ghostel-shell-integration t)
               ;; Pin the wrap off so the assertion targets the un-nested
               ;; `exec /bin/bash --posix' form.  Login-wrap behavior is
               ;; covered by its own dedicated tests.
               (ghostel-macos-login-shell nil)
               (default-directory "/tmp/")
               (proc (ghostel--start-process)))
          (unwind-protect
              (let ((cmd (process-command proc)))
                (should (equal '("/bin/sh" "-c") (seq-take cmd 2)))
                (should (string-match-p
                         (concat "stty " (regexp-quote ghostel--default-stty))
                         (nth 2 cmd)))
                (should (string-match-p "\\bsane\\b" (nth 2 cmd)))
                (should (string-match-p "exec /bin/bash --posix" (nth 2 cmd)))
                (should (member "GHOSTEL_BASH_INJECT=1" captured-env))
                (should (seq-some (lambda (s) (string-prefix-p "ENV=" s))
                                  captured-env)))
            (when (process-live-p proc)
              (delete-process proc))))))))

(ert-deftest ghostel-test-spawn-pty-disables-adaptive-read-buffering ()
  "`ghostel--spawn-pty' must disable adaptive read buffering.
It must also raise `read-process-output-max'.  Before Emacs 31 the
former defaulted to t and throttled bursty TUI redraws."
  :tags '(native)
  (skip-unless (not (eq system-type 'windows-nt)))
  (let ((captured-adaptive 'unset)
        (captured-max nil)
        (orig-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest plist)
                 (setq captured-adaptive process-adaptive-read-buffering
                       captured-max read-process-output-max)
                 (apply orig-make-process plist))))
      (with-temp-buffer
        (let ((proc (ghostel--spawn-pty "/bin/sh" nil 24 80
                                        "-ixon" nil nil)))
          (unwind-protect
              (progn
                (should (null captured-adaptive))
                (should (>= captured-max (* 1024 1024))))
            (when (process-live-p proc)
              (delete-process proc))))))))

(ert-deftest ghostel-test-sigwinch-reaches-shell-basic ()
  "Verify `set-process-window-size' delivers SIGWINCH to a PTY shell.
This is the baseline: if this fails, the Emacs PTY mechanism itself
is broken on this system."
  (skip-unless (not (eq system-type 'windows-nt)))
  (skip-unless ghostel-test--bash)
  (let* ((buf (generate-new-buffer " *sigwinch-basic*"))
         (output "")
         (proc nil))
    (unwind-protect
        (progn
          (setq proc
                (make-process
                 :name "sigwinch-basic"
                 :buffer buf
                 :command (list ghostel-test--bash)
                 :connection-type 'pty
                 :noquery t
                 :coding 'binary
                 :filter (lambda (_p s) (setq output (concat output s)))))
          (set-process-window-size proc 24 80)
          ;; Install a SIGWINCH trap that prints a marker to stdout.
          (process-send-string
           proc "trap 'printf \"__WINCH__\\n\"' WINCH\n")
          ;; Wait for shell to start and consume the trap command.
          ;; Bash with readline needs more startup time than /bin/sh.
          (sleep-for 0.5)
          ;; Clear output so we only see post-resize output.
          (setq output "")
          ;; Now trigger a resize — this is what Emacs does after
          ;; adjust-window-size-function returns a (width . height).
          (set-process-window-size proc 30 120)
          ;; Wait up to 2 seconds for trap to fire.
          (ghostel-test--wait-for
           proc (lambda () (string-match-p "__WINCH__" output)) 2.0)
          (should (string-match-p "__WINCH__" output)))
      (when (and proc (process-live-p proc))
        (delete-process proc))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ghostel-test-sigwinch-reaches-shell-ghostel-style ()
  "Verify SIGWINCH delivery using ghostel's exact shell-invocation pattern.
Ghostel starts the shell via `/bin/sh -c \"stty ...; exec <shell>\"',
which could affect process group setup and SIGWINCH delivery."
  (skip-unless (not (eq system-type 'windows-nt)))
  (skip-unless ghostel-test--bash)
  (let* ((buf (generate-new-buffer " *sigwinch-ghostel*"))
         (output "")
         (proc nil))
    (unwind-protect
        (progn
          (setq proc
                (make-process
                 :name "sigwinch-ghostel"
                 :buffer buf
                 :command (list "/bin/sh" "-c"
                                (format "stty erase '^?' iutf8 2>/dev/null; \
printf '\\033[H\\033[2J'; exec %s"
                                        ghostel-test--bash))
                 :connection-type 'pty
                 :noquery t
                 :coding 'binary
                 :filter (lambda (_p s) (setq output (concat output s)))))
          (set-process-window-size proc 24 80)
          ;; Wait for the exec to complete and shell to be ready.
          (sleep-for 0.5)
          (process-send-string
           proc "trap 'printf \"__WINCH__\\n\"' WINCH\n")
          (sleep-for 0.3)
          (setq output "")
          (set-process-window-size proc 30 120)
          (ghostel-test--wait-for
           proc (lambda () (string-match-p "__WINCH__" output)) 2.0)
          (should (string-match-p "__WINCH__" output)))
      (when (and proc (process-live-p proc))
        (delete-process proc))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ghostel-test-sigwinch-via-ghostel-resize-handler ()
  "SIGWINCH reaches child processes via the resize handler.
Exercises `ghostel--window-adjust-process-window-size', the full
path Emacs takes: call the adjust-window-size-function, get
\(width . height), then call `set-process-window-size'."
  (skip-unless (not (eq system-type 'windows-nt)))
  (skip-unless (file-executable-p "/bin/sh"))
  (let* ((buf (generate-new-buffer " *sigwinch-gh-handler*"))
         (output "")
         (proc nil))
    (unwind-protect
        (progn
          (setq proc
                (make-process
                 :name "sigwinch-gh-handler"
                 :buffer buf
                 :command '("/bin/sh" "-c"
                            "stty erase '^?' iutf8 2>/dev/null; \
printf '\\033[H\\033[2J'; exec /bin/sh")
                 :connection-type 'pty
                 :noquery t
                 :coding 'binary
                 :filter (lambda (_p s) (setq output (concat output s)))))
          (set-process-window-size proc 24 80)
          (sleep-for 0.5)
          (setq output "")
          ;; Start a foreground child that traps SIGWINCH (simulates htop).
          (process-send-string
           proc "/bin/sh -c 'trap \"printf __CHILD_WINCH__\\\\n\" WINCH; \
while :; do sleep 0.1; done'\n")
          (sleep-for 0.5)
          ;; Now simulate Emacs's window--adjust-process-windows path:
          ;; register the adjust-window-size-function and trigger the handler.
          (process-put proc 'adjust-window-size-function
                       #'ghostel--window-adjust-process-window-size)
          (with-current-buffer buf
            ;; FIXME: `ghostel--term' is bound to a symbol and the
            ;; set-size call is mocked, so the VT-resize half isn't
            ;; truly exercised — the SIGWINCH-delivery half (asserted
            ;; by the __CHILD_WINCH__ match below) is the real test.
            (let ((ghostel--term 'fake-term))
              (cl-letf (((symbol-function 'ghostel--set-size-with-cell-dims)
                         (lambda (_t _h _w) nil))
                        ((symbol-function 'ghostel--redraw-now) #'ignore)
                        ((default-value 'window-adjust-process-window-size-function)
                         (lambda (_p _w) (cons 120 30))))
                ;; Invoke the handler as Emacs would.
                (let ((size (ghostel--window-adjust-process-window-size
                             proc (list))))
                  ;; Returned size must be a usable cons for
                  ;; `set-process-window-size'.
                  (should (consp size))
                  (set-process-window-size proc (cdr size) (car size))))))
          (ghostel-test--wait-for
           proc (lambda () (string-match-p "__CHILD_WINCH__" output)) 2.0)
          (should (string-match-p "__CHILD_WINCH__" output)))
      (when (and proc (process-live-p proc))
        (delete-process proc))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ghostel-test-sigwinch-reaches-child-process ()
  "Verify SIGWINCH reaches a foreground child of the shell (mimicking htop).
When htop runs, it is a child process of the shell.  Since ghostel's
shell is non-interactive (no job control), the child inherits the
shell's process group and should receive SIGWINCH sent to the PTY's
foreground process group."
  (skip-unless (not (eq system-type 'windows-nt)))
  (skip-unless (file-executable-p "/bin/sh"))
  (let* ((buf (generate-new-buffer " *sigwinch-child*"))
         (output "")
         (proc nil))
    (unwind-protect
        (progn
          (setq proc
                (make-process
                 :name "sigwinch-child"
                 :buffer buf
                 :command '("/bin/sh" "-c" "exec /bin/sh")
                 :connection-type 'pty
                 :noquery t
                 :coding 'binary
                 :filter (lambda (_p s) (setq output (concat output s)))))
          (set-process-window-size proc 24 80)
          (sleep-for 0.3)
          (setq output "")
          ;; Start a child sh in the foreground with its own SIGWINCH trap,
          ;; sleeping forever.  This child simulates htop waiting for SIGWINCH.
          ;; We can't send more commands after this because the outer shell
          ;; is blocked on wait() for the child — but that's fine, we only
          ;; need the resize to fire and the child's trap to print the marker.
          (process-send-string
           proc "/bin/sh -c 'trap \"printf __CHILD_WINCH__\\\\n\" WINCH; \
while :; do sleep 0.1; done'\n")
          (sleep-for 0.5)
          (set-process-window-size proc 30 120)
          (ghostel-test--wait-for
           proc (lambda () (string-match-p "__CHILD_WINCH__" output)) 2.0)
          (should (string-match-p "__CHILD_WINCH__" output)))
      (when (and proc (process-live-p proc))
        (delete-process proc))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ghostel-test-exec-calls-spawn-pty-with-expected-args ()
  "`ghostel-exec' forwards PROGRAM, ARGS, size, stty flags, and remote-p."
  (let ((buf (generate-new-buffer " *ghostel-exec-test*"))
        captured)
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--load-module) #'ignore)
                  ((symbol-function 'ghostel--new)
                   (lambda (&rest _) 'fake-term))
                  ((symbol-function 'ghostel--set-size-with-cell-dims) #'ignore)
                  ((symbol-function 'ghostel--apply-palette) #'ignore)
                  ((symbol-function 'ghostel--spawn-pty)
                   (lambda (&rest args) (setq captured args) 'fake-proc)))
          (ghostel-exec buf "less" '("/etc/hosts"))
          ;; Signature: program args height width stty-flags extra-env remote-p
          (should (equal (nth 0 captured) "less"))
          (should (equal (nth 1 captured) '("/etc/hosts")))
          (should (numberp (nth 2 captured)))
          (should (numberp (nth 3 captured)))
          (should (equal (nth 4 captured) ghostel--default-stty))
          (should (null (nth 5 captured)))
          ;; Local default-directory — no TRAMP — so remote-p must be nil.
          (should (null (nth 6 captured))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-pre-spawn-hook-injects-into-process-environment ()
  "Hook `setenv' calls reach the spawned process via `process-environment'.
`ghostel-pre-spawn-hook' fires with `process-environment' dynamically
bound to the about-to-be-spawned env, so hook functions that call
`setenv' inject entries the child process actually inherits.

Contract relied on by integrations like with-editor: drive a real
`/bin/sh' through `ghostel--start-process', have the hook `setenv' a
sentinel value, and verify the value reached `make-process'.  Also
verifies the hook fires in the spawning buffer with `default-directory'
intact (with-editor's `with-editor--setup' reads `default-directory')."
  :tags '(native)
  (skip-unless (not (eq system-type 'windows-nt)))
  (let ((captured-env nil)
        captured-buffer
        captured-default-directory
        (orig-make-process (symbol-function #'make-process)))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest plist)
                 (setq captured-env process-environment)
                 (apply orig-make-process plist))))
      (with-temp-buffer
        (setq-local ghostel--term-rows 24
                    ghostel--term-cols 80)
        (let* ((process-environment '("PATH=/usr/bin:/bin" "HOME=/tmp"))
               (ghostel-shell "/bin/sh")
               (ghostel-shell-integration nil)
               (default-directory "/tmp/")
               (test-buffer (current-buffer))
               (ghostel-pre-spawn-hook
                (list (lambda ()
                        (setq captured-buffer (current-buffer))
                        (setq captured-default-directory default-directory)
                        (setenv "GHOSTEL_PRE_SPAWN_TEST" "ok"))))
               (proc (ghostel--start-process)))
          (unwind-protect
              (progn
                (should (eq captured-buffer test-buffer))
                (should (equal captured-default-directory "/tmp/"))
                (should (member "GHOSTEL_PRE_SPAWN_TEST=ok" captured-env)))
            (when (process-live-p proc)
              (delete-process proc))))))))

(ert-deftest ghostel-test-debug-ghostel-installs-spawn-pty-advice ()
  "`ghostel-debug-ghostel' wires up self-removing advice on `ghostel--spawn-pty'.
Confirms the around-advice fires (capturing arguments into a buffer-
local plist) and that it removes itself after the spawn so subsequent
plain `ghostel' calls aren't instrumented.  Stubs out `make-process'
  so no actual shell is spawned."
  (let ((native-comp-enable-subr-trampolines nil)
        (display-buffer-overriding-action '(display-buffer-no-window))
        (inhibit-message t)
        (executed-command '("ghostel-test-process")))
    (cl-letf (((symbol-function #'make-process)
               (lambda (&rest plist)
                 ;; Return a dummy process object so the advice still
                 ;; records :executed-command from (process-command proc).
                 (make-pipe-process :name (plist-get plist :name)
                                    :buffer (plist-get plist :buffer)
                                    :noquery t
                                    :filter #'ignore
                                    :sentinel #'ignore)))
              ((symbol-function #'process-command)
               (lambda (_proc) executed-command)))
      (let* ((buf (generate-new-buffer " *ghostel-test-debug-ghostel*"))
             ;; Stub `ghostel' to call `ghostel--spawn-pty' synchronously
             ;; in `buf' — mimics the path through `ghostel--start-process'
             ;; without dragging in module load, buffer init, etc.
             (calls 0))
        (cl-letf (((symbol-function #'ghostel)
                   (lambda (&rest _arg)
                     (with-current-buffer buf
                       (setq-local ghostel--term-rows 24)
                       (setq-local ghostel--term-cols 80)
                       (cl-incf calls)
                       (ghostel--spawn-pty "/bin/sh" nil 24 80
                                           "-ixon" nil nil)))))
          (unwind-protect
              (progn
                (ghostel-debug-ghostel)
                ;; Both advices should have removed themselves (or been
                ;; stripped by the unwind-protect cleanup if they never
                ;; fired — either way they must not linger).
                (should-not (advice-member-p
                             #'ghostel-debug--capture-spawn-pty
                             'ghostel--spawn-pty))
                (should-not (advice-member-p
                             #'ghostel-debug--capture-start-process
                             'ghostel--start-process))
                ;; And the buffer-local capture should be populated.
                (let ((cap (buffer-local-value
                            'ghostel-debug--spawn-capture buf)))
                  (should cap)
                  (should (eq 24 (plist-get cap :height)))
                  (should (eq 80 (plist-get cap :width)))
                  (should (equal "/bin/sh" (plist-get cap :program)))
                  ;; :command is the wrapper ghostel passed to make-process,
                  ;; captured before any process-command view of the result.
                  (let ((cmd (plist-get cap :command)))
                    (should (consp cmd))
                    (should (equal "/bin/sh" (car cmd)))
                    (should (equal "-c" (cadr cmd))))
                  ;; :executed-command is what process-command returns.
                  (should (equal executed-command
                                 (plist-get cap :executed-command)))))
            (when (buffer-live-p buf)
              (let ((p (buffer-local-value 'ghostel--process buf)))
                (when (processp p) (delete-process p)))
              (kill-buffer buf))))))))

(ert-deftest ghostel-test-debug-capture-start-process-records-time ()
  "`ghostel-debug--capture-start-process' stashes its entry time and self-removes.
The stashed value is consumed by `ghostel-debug--capture-spawn-pty'
and folded into the capture as `:start-process-time'.  Without that
two-step, the spawn-capture would have no baseline for the elisp-prep
delta in the phase timings section."
  (let ((buf (generate-new-buffer " *ghostel-test-start-proc-cap*"))
        (orig (lambda (&rest _) 'fake-result)))
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--start-process) orig))
          (advice-add 'ghostel--start-process :around
                      #'ghostel-debug--capture-start-process)
          (with-current-buffer buf
            (let ((t-before (current-time)))
              (ghostel--start-process)
              ;; Advice removed itself after one call.
              (should-not
               (advice-member-p
                #'ghostel-debug--capture-start-process
                'ghostel--start-process))
              ;; Buffer-local stash holds a timestamp at or after t-before.
              (let ((stashed ghostel-debug--pending-start-process-time))
                (should stashed)
                (should-not (time-less-p stashed t-before))))))
      (advice-remove 'ghostel--start-process
                     #'ghostel-debug--capture-start-process)
      (kill-buffer buf))))



(ert-deftest ghostel-test-start-process-state-remote-uses-remote-terminfo ()
  "Remote startup state must not leak the local bundled terminfo path."
  (let ((default-directory "/ssh:test@host:/tmp/")
        (ghostel-shell-integration t)
        (ghostel-tramp-shell-integration t)
        (ghostel-term "xterm-ghostty"))
    (cl-letf (((symbol-function #'window-body-height)
               (lambda (&optional _w) 25))
              ((symbol-function #'window-max-chars-per-line)
               (lambda (&optional _w) 80))
              ((symbol-function #'ghostel--get-shell)
               (lambda () "/bin/bash"))
              ((symbol-function #'ghostel--detect-shell)
               (lambda (_shell) 'bash))
              ((symbol-function #'ghostel--setup-remote-integration)
               (lambda (_shell-type)
                 '(:env ("TERMINFO=/remote/tinfo")
                   :args nil
                   :stty "erase '^?' iutf8 -ixon"
                   :temp-files nil
                   :temp-dirs nil)))
              ((symbol-function #'ghostel--terminal-env)
               (lambda ()
                 '("TERM=xterm-ghostty"
                   "TERMINFO=/local/tinfo"
                   "TERM_PROGRAM=ghostty"
                   "COLORTERM=truecolor"
                   "GHOSTEL_SSH_INSTALL_TERMINFO=1"))))
      (let* ((state (ghostel--start-process-state))
             (env (plist-get state :env-overrides)))
        (should (member "TERM=xterm-ghostty" env))
        (should (member "TERMINFO=/remote/tinfo" env))
        (should-not (member "TERMINFO=/local/tinfo" env))
        (should (member "TERM_PROGRAM=ghostty" env))
        (should (member "GHOSTEL_SSH_INSTALL_TERMINFO=1" env))))))

(ert-deftest ghostel-test-start-process-state-remote-without-terminfo-falls-back-to-xterm-256color ()
  "Remote startup without prepared terminfo must keep a generic TERM."
  (let ((default-directory "/ssh:test@host:/tmp/")
        (ghostel-shell-integration t)
        (ghostel-tramp-shell-integration nil)
        (ghostel-term "xterm-ghostty"))
    (cl-letf (((symbol-function #'window-body-height)
               (lambda (&optional _w) 25))
              ((symbol-function #'window-max-chars-per-line)
               (lambda (&optional _w) 80))
              ((symbol-function #'ghostel--get-shell)
               (lambda () "/bin/bash"))
              ((symbol-function #'ghostel--detect-shell)
               (lambda (_shell) 'bash)))
      (let ((env (plist-get (ghostel--start-process-state) :env-overrides)))
        (should (member "TERM=xterm-256color" env))
        (should-not (member "TERM=xterm-ghostty" env))
        (should-not (member "TERM_PROGRAM=ghostty" env))
        (should-not (seq-some (lambda (entry)
                                (string-prefix-p "TERMINFO=" entry))
                              env))))))

(ert-deftest ghostel-test-resize-window-adjust-filters-to-selected-window ()
  "Window adjust computes size from only the selected Ghostel window when enabled."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel-resize-only-when-selected-window t)
          (set-size-args nil)
          (selected-window 'selected-window)
          (other-window 'other-window)
          (adjust-windows nil))
      (let ((cur-buf (current-buffer)))
        (cl-letf (((symbol-function 'ghostel--set-size)
                   (lambda (_term h w &rest _) (setq set-size-args (list h w))))
                  ((symbol-function 'ghostel--redraw-now)
                   (lambda (&rest _args)))
                  ((symbol-function 'selected-window)
                   (lambda () selected-window))
                  ((symbol-function 'window-buffer)
                   (lambda (win)
                     (when (memq win (list selected-window other-window))
                       cur-buf)))
                  ((symbol-function 'process-buffer)
                   (lambda (_proc) cur-buf))
                  ((default-value 'window-adjust-process-window-size-function)
                   (lambda (_proc wins)
                     (setq adjust-windows wins)
                     (if (equal wins (list selected-window))
                         '(80 . 24)
                       '(120 . 40)))))
           (let ((result (ghostel--window-adjust-process-window-size
                          'fake-proc (list selected-window other-window))))
             (should (equal (list selected-window) adjust-windows))
             (should (equal '(80 . 24) result))
             (should (equal '(24 80) set-size-args))))))))

(ert-deftest ghostel-test-resize-window-adjust-keeps-legacy-window-set-by-default ()
  "Window adjust forwards incoming windows by default."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (set-size-args nil)
          (selected-window 'selected-window)
          (other-window 'other-window)
          (incoming-windows nil)
          (redraw-called nil))
      (let ((cur-buf (current-buffer)))
        (cl-letf (((symbol-function 'ghostel--set-size)
                   (lambda (_term h w &rest _) (setq set-size-args (list h w))))
                  ((symbol-function 'ghostel--redraw-now)
                   (lambda (&rest _args) (setq redraw-called t)))
                  ((symbol-function 'selected-window)
                   (lambda () selected-window))
                  ((symbol-function 'window-buffer)
                   (lambda (win)
                     (when (memq win (list selected-window other-window))
                       cur-buf)))
                  ((symbol-function 'process-buffer)
                   (lambda (_proc) cur-buf))
                  ((default-value 'window-adjust-process-window-size-function)
                   (lambda (_proc wins)
                     (setq incoming-windows wins)
                     '(120 . 40))))
          (let ((result (ghostel--window-adjust-process-window-size
                         'fake-proc (list other-window))))
            (should (equal (list other-window) incoming-windows))
            (should (equal '(120 . 40) result))
            (should (equal '(40 120) set-size-args))
            (should redraw-called)))))))

(ert-deftest ghostel-test-resize-window-adjust-ignores-unselected-window ()
  "Window adjust ignores unselected Ghostel windows when enabled."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel-resize-only-when-selected-window t)
          (set-size-called nil)
          (redraw-called nil)
          (selected-window 'selected-window)
          (other-window 'other-window))
      (let ((cur-buf (current-buffer)))
        (cl-letf (((symbol-function 'ghostel--set-size)
                   (lambda (&rest _args) (setq set-size-called t)))
                  ((symbol-function 'ghostel--redraw-now)
                   (lambda (&rest _args) (setq redraw-called t)))
                  ((symbol-function 'selected-window)
                   (lambda () selected-window))
                  ((symbol-function 'window-buffer)
                   (lambda (win)
                     (when (memq win (list selected-window other-window))
                       cur-buf)))
                  ((symbol-function 'process-buffer)
                   (lambda (_proc) cur-buf))
                  ((default-value 'window-adjust-process-window-size-function)
                   (lambda (_proc _wins) '(120 . 40))))
          (let ((result (ghostel--window-adjust-process-window-size
                         'fake-proc (list other-window))))
            (should (null result))
            (should-not set-size-called)
            (should-not redraw-called)))))))

(ert-deftest ghostel-test-resize-minibuffer-crop ()
  "Minibuffer-induced height shrink on primary screen is cropped (nil)."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--term-rows 40)
          (ghostel--term-cols 120)
          (set-size-called nil))
      (let ((cur-buf (current-buffer)))
        (cl-letf (((symbol-function 'ghostel--set-size)
                   (lambda (_term _h _w &rest _) (setq set-size-called t)))
                  ((symbol-function 'ghostel--redraw-now) #'ignore)
                  ((symbol-function 'ghostel--alt-screen-p) (lambda (_t) nil))
                  ((symbol-function 'minibuffer-depth) (lambda () 1))
                  ((symbol-function 'process-buffer)
                   (lambda (_proc) cur-buf))
                  ((default-value 'window-adjust-process-window-size-function)
                   (lambda (_proc _wins) '(120 . 25))))
          (let ((result (ghostel--window-adjust-process-window-size
                         'fake-proc '(fake-win))))
            (should (null result))
            (should-not set-size-called)))))))

(ert-deftest ghostel-test-resize-minibuffer-alt-screen-commits ()
  "Alt-screen apps (htop/vim) skip the crop path and resize normally."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--term-rows 40)
          (ghostel--term-cols 120)
          (set-size-args nil))
      (let ((cur-buf (current-buffer)))
        (cl-letf (((symbol-function 'ghostel--set-size)
                   (lambda (_term h w &rest _) (setq set-size-args (list h w))))
                  ((symbol-function 'ghostel--redraw-now) #'ignore)
                  ((symbol-function 'ghostel--alt-screen-p) (lambda (_t) t))
                  ((symbol-function 'minibuffer-depth) (lambda () 1))
                  ((symbol-function 'process-buffer)
                   (lambda (_proc) cur-buf))
                  ((default-value 'window-adjust-process-window-size-function)
                   (lambda (_proc _wins) '(120 . 25))))
          (let ((result (ghostel--window-adjust-process-window-size
                         'fake-proc '(fake-win))))
            (should (equal '(120 . 25) result))
            (should (equal '(25 120) set-size-args))
            (should (eql ghostel--term-rows 25))))))))

(ert-deftest ghostel-test-resize-minibuffer-width-only-shrink-commits ()
  "Width-only shrink with minibuffer open skips the crop and resizes."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--term-rows 40)
          (ghostel--term-cols 120)
          (set-size-args nil))
      (let ((cur-buf (current-buffer)))
        (cl-letf (((symbol-function 'ghostel--set-size)
                   (lambda (_term h w &rest _) (setq set-size-args (list h w))))
                  ((symbol-function 'ghostel--redraw-now) #'ignore)
                  ((symbol-function 'ghostel--alt-screen-p) (lambda (_t) nil))
                  ((symbol-function 'minibuffer-depth) (lambda () 1))
                  ((symbol-function 'process-buffer)
                   (lambda (_proc) cur-buf))
                  ;; width 100 < 120, height unchanged.
                  ((default-value 'window-adjust-process-window-size-function)
                   (lambda (_proc _wins) '(100 . 40))))
           (let ((result (ghostel--window-adjust-process-window-size
                          'fake-proc '(fake-win))))
             (should (equal '(100 . 40) result))
             (should (equal '(40 100) set-size-args))))))))

(ert-deftest ghostel-test-selected-window-resize-catches-up-on-selection ()
  "Selecting a Ghostel window commits a deferred selected-window-only resize."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--process 'fake-proc)
          (ghostel-resize-only-when-selected-window t)
          (ghostel--term-rows 40)
          (ghostel--term-cols 120)
          (ghostel--force-next-redraw nil)
          (set-size-args nil)
          (swsize-args nil)
          (redraw-called nil)
          (ghostel-window (selected-window)))
      (let ((cur-buf (current-buffer)))
        (cl-letf (((symbol-function 'selected-window)
                   (lambda () 'other-window))
                  ((symbol-function 'window-buffer)
                   (lambda (win)
                     (when (eq win ghostel-window)
                       cur-buf)))
                  ((symbol-function 'process-buffer)
                   (lambda (_proc) cur-buf))
                  ((symbol-function 'minibuffer-depth) (lambda () 0)))
          (let ((result (ghostel--window-adjust-process-window-size
                         'fake-proc (list ghostel-window))))
            (should (null result))
            (should (equal ghostel--term-rows 40))
            (should (equal ghostel--term-cols 120))
            (should-not set-size-args)
            (should-not redraw-called))
          (cl-letf (((symbol-function 'ghostel--set-size)
                     (lambda (_term h w &rest _) (setq set-size-args (list h w))))
                    ((symbol-function 'ghostel--redraw-now)
                     (lambda (_buf) (setq redraw-called t)))
                    ((symbol-function 'process-live-p) (lambda (_p) t))
                    ((symbol-function 'ghostel--process-set-window-size)
                     (lambda (_p h w) (setq swsize-args (list h w))))
                    ;; Regression guard for #192: if the function ever
                    ;; reverts to `window-body-height' instead of
                    ;; `window-screen-lines', the assertions below fail
                    ;; because 99 ≠ 25.
                    ((symbol-function 'window-body-height) (lambda (&rest _) 99))
                    ((symbol-function 'window-screen-lines) (lambda () 25.0))
                    ((symbol-function 'window-max-chars-per-line)
                     (lambda (&rest _) 100)))
          (ghostel--commit-cropped-size ghostel-window)
          (should (equal '(25 100) set-size-args))
          (should (equal '(25 100) swsize-args))
          (should (equal ghostel--term-rows 25))
          (should (equal ghostel--term-cols 100))
          (should ghostel--force-next-redraw)
          (should redraw-called)))))))

(provide 'ghostel-tramp-test)
;;; ghostel-tramp-test.el ends here
