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
               (ghostel-use-native-pty nil)
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
  (skip-unless (not (eq system-type 'windows-nt)))
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
            (ghostel-use-native-pty nil)
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
               (ghostel-use-native-pty nil)
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
