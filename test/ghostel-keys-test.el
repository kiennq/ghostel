;;; ghostel-keys-test.el --- Tests for ghostel: keys -*- lexical-binding: t; -*-

;;; Commentary:

;; Key encoding, send-event, raw key fallback, control/meta/special key
;; bindings, send-encoded, send-next-key, public send-string/-key/-paste API,
;; immediate redraw.

;;; Code:

(require 'ghostel-test-helpers)

(defmacro ghostel-test--with-native-pty-write-capture (capture &rest body)
  "Bind CAPTURE to bytes written by the native PTY write path while running BODY."
  (declare (indent 1))
  `(let (,capture)
     (cl-letf (((symbol-function 'process-send-string)
                (lambda (_process data) (setq ,capture data)))
               ((symbol-function 'ghostel--process-send)
                (lambda (&rest args)
                  (ert-fail
                   (format "unexpected ghostel--process-send: %S" args)))))
       ,@body)))

(ert-deftest ghostel-test-raw-key-sequences ()
  "Test the Elisp raw key sequence builder."
  ;; Basic keys
  (should (equal "\x7f" (ghostel--raw-key-sequence "backspace" "")))  ; backspace
  (should (equal "\r" (ghostel--raw-key-sequence "return" "")))       ; return
  (should (equal "\t" (ghostel--raw-key-sequence "tab" "")))          ; tab
  (should (equal "\e" (ghostel--raw-key-sequence "escape" "")))       ; escape
  ;; Cursor keys
  (should (equal "\e[A" (ghostel--raw-key-sequence "up" "")))         ; up
  (should (equal "\e[B" (ghostel--raw-key-sequence "down" "")))       ; down
  (should (equal "\e[C" (ghostel--raw-key-sequence "right" "")))      ; right
  (should (equal "\e[D" (ghostel--raw-key-sequence "left" "")))       ; left
  ;; Shift+arrow
  (should (equal "\e[1;2A" (ghostel--raw-key-sequence "up" "shift"))) ; shift-up
  ;; Ctrl+letter
  (should (equal "\x01" (ghostel--raw-key-sequence "a" "ctrl")))      ; ctrl-a
  (should (equal "\x03" (ghostel--raw-key-sequence "c" "ctrl")))      ; ctrl-c
  (should (equal "\x1a" (ghostel--raw-key-sequence "z" "ctrl")))      ; ctrl-z
  ;; Ctrl + C0 symbol chars (@ A-Z [ \ ] ^ _) fold to (char & #x1f)
  (should (equal "\x1f" (ghostel--raw-key-sequence "_" "ctrl")))      ; ctrl-_ (undo)
  (should (equal "\x1e" (ghostel--raw-key-sequence "^" "ctrl")))      ; ctrl-^
  (should (equal "\x00" (ghostel--raw-key-sequence "@" "ctrl")))      ; ctrl-@ (NUL)
  ;; Function keys
  (should (equal "\eOP" (ghostel--raw-key-sequence "f1" "")))         ; f1
  (should (equal "\e[15~" (ghostel--raw-key-sequence "f5" "")))       ; f5
  (should (equal "\e[24~" (ghostel--raw-key-sequence "f12" "")))      ; f12
  ;; Tilde keys
  (should (equal "\e[2~" (ghostel--raw-key-sequence "insert" "")))    ; insert
  (should (equal "\e[3~" (ghostel--raw-key-sequence "delete" "")))    ; delete
  (should (equal "\e[5~" (ghostel--raw-key-sequence "prior" "")))     ; pgup
  ;; Unknown key
  (should (equal nil (ghostel--raw-key-sequence "xyzzy" ""))))        ; unknown

(ert-deftest ghostel-test-raw-key-meta-printable ()
  "Meta + any printable ASCII char encodes as ESC followed by that char.
Covers punctuation, digits, uppercase, space, and lowercase letters."
  (should (equal "\e." (ghostel--raw-key-sequence "." "meta")))
  (should (equal "\e," (ghostel--raw-key-sequence "," "meta")))
  (should (equal "\e1" (ghostel--raw-key-sequence "1" "meta")))
  (should (equal "\eA" (ghostel--raw-key-sequence "A" "meta")))
  (should (equal "\e " (ghostel--raw-key-sequence " " "meta")))
  ;; Lowercase letters still work (existing behavior)
  (should (equal "\eb" (ghostel--raw-key-sequence "b" "meta"))))

(ert-deftest ghostel-test-modifier-number ()
  "Test modifier bitmask parsing."
  (should (equal 0 (ghostel--modifier-number "")))            ; no mods
  (should (equal 1 (ghostel--modifier-number "shift")))       ; shift
  (should (equal 4 (ghostel--modifier-number "ctrl")))        ; ctrl
  (should (equal 2 (ghostel--modifier-number "alt")))         ; alt
  (should (equal 2 (ghostel--modifier-number "meta")))        ; meta
  (should (equal 5 (ghostel--modifier-number "shift,ctrl")))  ; shift,ctrl
  (should (equal 4 (ghostel--modifier-number "control"))))    ; control

(ert-deftest ghostel-test-send-event ()
  "Test that ghostel--send-event extracts key names and modifiers correctly."
  (let (captured-key captured-mods)
    (cl-letf (((symbol-function 'ghostel--send-encoded)
               (lambda (key mods &optional _utf8)
                 (setq captured-key key captured-mods mods))))
      (cl-flet ((sim (event expected-key expected-mods)
                  (setq captured-key nil captured-mods nil)
                  (let ((last-command-event event))
                    (ghostel--send-event))
                  (should (equal expected-key captured-key))
                  (should (equal expected-mods captured-mods))))
        ;; Unmodified special keys
        (sim (aref (kbd "<return>") 0)    "return"    "")
        (sim (aref (kbd "<tab>") 0)       "tab"       "")
        (sim (aref (kbd "<backspace>") 0) "backspace" "")
        ;; Terminal mode sends ASCII 127 for backspace
        (sim ?\d                          "backspace" "")
        (sim (aref (kbd "<escape>") 0)    "escape"    "")
        (sim (aref (kbd "<up>") 0)        "up"        "")
        (sim (aref (kbd "<f1>") 0)        "f1"        "")
        (sim (aref (kbd "<deletechar>") 0) "delete"   "")
        ;; Modified special keys
        (sim (aref (kbd "S-<return>") 0)  "return"    "shift")
        (sim (aref (kbd "C-<return>") 0)  "return"    "ctrl")
        (sim (aref (kbd "M-<return>") 0)  "return"    "meta")
        (sim (aref (kbd "C-<up>") 0)      "up"        "ctrl")
        (sim (aref (kbd "M-<left>") 0)    "left"      "meta")
        (sim (aref (kbd "S-<f5>") 0)      "f5"        "shift")
        (sim (aref (kbd "C-S-<return>") 0) "return"   "ctrl,shift")
        (sim (aref (kbd "M-.") 0)  "."  "meta")
        (sim (aref (kbd "M-1") 0)  "1"  "meta")
        ;; Control + non-letter punctuation decomposes to base + ctrl.
        (sim ?\C-]      "]" "ctrl")
        (sim ?\M-\C-]   "]" "ctrl,meta")
        ;; backtab (Emacs's name for S-TAB)
        (sim (aref (kbd "<backtab>") 0)   "tab"       "shift")))))

(ert-deftest ghostel-test-send-event-encoded-specials-use-direct-native-transport ()
  "`ghostel--send-event' special keys must use the direct native transport."
  :tags '(native)
  (with-temp-buffer
    (let* ((term (ghostel--new 25 80 1000))
           (ghostel--term term)
           (ghostel--process 'fake-process)
           (ghostel-scroll-on-input nil))
      (ghostel-test--with-native-pty-write-capture sent
        (pcase-dolist (`(,event ,bytes) '((return "\r")
                                          (backspace "\x7f")))
          (let ((last-command-event event))
            (ghostel--send-event))
          (should (equal bytes sent)))))))

(ert-deftest ghostel-test-raw-key-modified-specials ()
  "Test raw fallback produces CSI u encoding for modified specials."
  (should (equal "\e[13;2u"                                       ; shift-return
                 (ghostel--raw-key-sequence "return" "shift")))
  (should (equal "\e[9;5u"                                        ; ctrl-tab
                 (ghostel--raw-key-sequence "tab" "ctrl")))
  (should (equal "\e[127;3u"                                      ; meta-backspace
                 (ghostel--raw-key-sequence "backspace" "meta")))
  (should (equal "\e[27;6u"                                       ; ctrl-shift-escape
                 (ghostel--raw-key-sequence "escape" "shift,ctrl")))
  ;; Unmodified still produce raw bytes
  (should (equal "\r" (ghostel--raw-key-sequence "return" "")))   ; plain return
  (should (equal "\t" (ghostel--raw-key-sequence "tab" ""))))     ; plain tab

(ert-deftest ghostel-test-encode-key-kitty-backspace ()
  "Test that backspace is correctly encoded when kitty keyboard mode is active."
  :tags '(native)
  (let* ((term (ghostel--new 25 80 1000))
         (ghostel--term term)
         (ghostel--process 'fake)
         (sent-bytes nil))
    ;; Activate kitty keyboard protocol (flags=5: disambiguate + report-alternates)
    ;; by feeding CSI = 5 u to the terminal
    (ghostel--write-vt term "\e[=5u")
    ;; Capture what the native encoder writes through the direct native transport.
    (ghostel-test--with-native-pty-write-capture sent-bytes
      ;; Encode backspace — should succeed and send \x7f
      (should (ghostel--encode-key term "backspace" ""))
      (should sent-bytes)
      (should (equal "\x7f" sent-bytes)))))

(ert-deftest ghostel-test-encode-key-legacy-backspace ()
  "Test that backspace is correctly encoded in legacy mode (no kitty)."
  :tags '(native)
  (let* ((term (ghostel--new 25 80 1000))
         (ghostel--term term)
         (ghostel--process 'fake)
         (sent-bytes nil))
    ;; No kitty mode set — legacy encoding
    (ghostel-test--with-native-pty-write-capture sent-bytes
      (should (ghostel--encode-key term "backspace" ""))
      (should sent-bytes)
      (should (equal "\x7f" sent-bytes)))))

(ert-deftest ghostel-test-immediate-redraw-triggers-on-small-echo ()
  "Small output after recent send-key triggers immediate redraw."
  (with-temp-buffer
    (let ((buf (current-buffer))
          (ghostel--term 'fake)
          (ghostel--redraw-timer nil)
          (ghostel--last-send-time nil)
          (ghostel-immediate-redraw-threshold 256)
          (ghostel-immediate-redraw-interval 0.05)
          (written nil)
          (immediate-called nil)
          (invalidate-called nil))
      ;; Stub out process-buffer, native input, redraw, and invalidate.
      (cl-letf (((symbol-function 'process-buffer) (lambda (_) buf))
                ((symbol-function 'ghostel--write-vt)
                 (lambda (_term data) (setq written data)))
                ((symbol-function 'ghostel--redraw-now)
                 (lambda (_buf) (setq immediate-called t)))
                ((symbol-function 'ghostel--invalidate)
                 (lambda () (setq invalidate-called t))))
        ;; Simulate recent keystroke
        (setq ghostel--last-send-time (current-time))
        ;; Simulate small echo arriving
        (ghostel--filter 'fake-proc "a")
        (should (equal "a" written))
        (should immediate-called)
        (should-not invalidate-called)))))

(ert-deftest ghostel-test-immediate-redraw-skips-large-output ()
  "Large output is written immediately and rendered by timer."
  (with-temp-buffer
    (let ((buf (current-buffer))
          (ghostel--term 'fake)
          (ghostel--redraw-timer nil)
          (ghostel--last-send-time (current-time))
          (ghostel-immediate-redraw-threshold 256)
          (ghostel-immediate-redraw-interval 0.05)
          (written nil)
          (immediate-called nil)
          (invalidate-called nil))
      (cl-letf (((symbol-function 'process-buffer) (lambda (_) buf))
                ((symbol-function 'ghostel--write-vt)
                 (lambda (_term data) (setq written data)))
                ((symbol-function 'ghostel--redraw-now)
                 (lambda (_buf) (setq immediate-called t)))
                ((symbol-function 'ghostel--invalidate)
                 (lambda () (setq invalidate-called t))))
        ;; Large output is fed to the terminal now; rendering is scheduled.
        (ghostel--filter 'fake-proc (make-string 500 ?x))
        (should (= 500 (length written)))
        (should-not immediate-called)
        (should invalidate-called)))))

(ert-deftest ghostel-test-immediate-redraw-skips-stale-send ()
  "Output arriving long after last keystroke schedules timer redraw."
  (with-temp-buffer
    (let ((buf (current-buffer))
          (ghostel--term 'fake)
          (ghostel--redraw-timer nil)
          (ghostel--last-send-time (time-subtract (current-time) 1))
          (ghostel-immediate-redraw-threshold 256)
          (ghostel-immediate-redraw-interval 0.05)
          (written nil)
          (immediate-called nil)
          (invalidate-called nil))
      (cl-letf (((symbol-function 'process-buffer) (lambda (_) buf))
                ((symbol-function 'ghostel--write-vt)
                 (lambda (_term data) (setq written data)))
                ((symbol-function 'ghostel--redraw-now)
                 (lambda (_buf) (setq immediate-called t)))
                ((symbol-function 'ghostel--invalidate)
                 (lambda () (setq invalidate-called t))))
        (ghostel--filter 'fake-proc "a")
        (should (equal "a" written))
        (should-not immediate-called)
        (should invalidate-called)))))

(ert-deftest ghostel-test-immediate-redraw-disabled-when-zero ()
  "Immediate redraw is disabled when threshold is 0."
  (with-temp-buffer
    (let ((buf (current-buffer))
          (ghostel--term 'fake)
          (ghostel--redraw-timer nil)
          (ghostel--last-send-time (current-time))
          (ghostel-immediate-redraw-threshold 0)
          (ghostel-immediate-redraw-interval 0.05)
          (written nil)
          (immediate-called nil)
          (invalidate-called nil))
      (cl-letf (((symbol-function 'process-buffer) (lambda (_) buf))
                ((symbol-function 'ghostel--write-vt)
                 (lambda (_term data) (setq written data)))
                ((symbol-function 'ghostel--redraw-now)
                 (lambda (_buf) (setq immediate-called t)))
                ((symbol-function 'ghostel--invalidate)
                 (lambda () (setq invalidate-called t))))
        (ghostel--filter 'fake-proc "a")
        (should (equal "a" written))
        (should-not immediate-called)
        (should invalidate-called)))))

(ert-deftest ghostel-test-typing-redraw-delay-during-recent-input ()
  "Recent input uses the typing redraw delay for timer-rendered output."
  (with-temp-buffer
    (let ((ghostel-adaptive-fps t)
          (ghostel-timer-delay 0.033)
          (ghostel-typing-redraw-delay 0.004)
          (ghostel-typing-redraw-window 0.08)
          (ghostel--last-send-time (current-time))
          (ghostel--last-output-time nil)
          (ghostel--redraw-timer nil)
          (ghostel--redraw-timer-deadline nil)
          scheduled-delay)
      (cl-letf (((symbol-function 'run-with-timer)
                 (lambda (delay _repeat _fn &rest _args)
                   (setq scheduled-delay delay)
                   'ghostel-test-timer)))
        (ghostel--invalidate)
        (should (equal scheduled-delay 0.004))
        (should (eq ghostel--redraw-timer 'ghostel-test-timer))
        (should ghostel--redraw-timer-deadline)))))

(ert-deftest ghostel-test-typing-redraw-keeps-existing-adaptive-idle-delay ()
  "Without recent input, adaptive FPS keeps its existing idle first-frame delay."
  (with-temp-buffer
    (let ((ghostel-adaptive-fps t)
          (ghostel-timer-delay 0.033)
          (ghostel-typing-redraw-delay 0.004)
          (ghostel-typing-redraw-window 0.08)
          (ghostel--last-send-time nil)
          (ghostel--last-output-time (time-subtract (current-time) 1))
          (ghostel--redraw-timer nil)
          (ghostel--redraw-timer-deadline nil)
          scheduled-delay)
      (cl-letf (((symbol-function 'run-with-timer)
                 (lambda (delay _repeat _fn &rest _args)
                   (setq scheduled-delay delay)
                   'ghostel-test-timer)))
        (ghostel--invalidate)
        (should (equal scheduled-delay 0.016))))))

(ert-deftest ghostel-test-typing-redraw-disabled-with-fixed-fps ()
  "When adaptive FPS is disabled, typing boost does not override the fixed delay."
  (with-temp-buffer
    (let ((ghostel-adaptive-fps nil)
          (ghostel-timer-delay 0.033)
          (ghostel-typing-redraw-delay 0.004)
          (ghostel-typing-redraw-window 0.08)
          (ghostel--last-send-time (current-time))
          (ghostel--last-output-time nil)
          (ghostel--redraw-timer nil)
          (ghostel--redraw-timer-deadline nil)
          scheduled-delay)
      (cl-letf (((symbol-function 'run-with-timer)
                 (lambda (delay _repeat _fn &rest _args)
                   (setq scheduled-delay delay)
                   'ghostel-test-timer)))
        (ghostel--invalidate)
        (should (equal scheduled-delay 0.033))))))

(ert-deftest ghostel-test-typing-redraw-reschedules-slower-timer-earlier ()
  "Typing output can replace an existing slower redraw timer."
  (with-temp-buffer
    (let* ((fixed-now (current-time))
           (ghostel-adaptive-fps t)
           (ghostel-timer-delay 0.033)
           (ghostel-typing-redraw-delay 0.004)
           (ghostel-typing-redraw-window 0.08)
           (ghostel--last-send-time fixed-now)
           (ghostel--last-output-time fixed-now)
           (ghostel--redraw-timer 'slow-timer)
           (ghostel--redraw-timer-deadline (time-add fixed-now 0.033))
           cancelled
           scheduled-delay)
      (cl-letf (((symbol-function 'current-time)
                 (lambda () fixed-now))
                ((symbol-function 'cancel-timer)
                 (lambda (timer) (push timer cancelled)))
                ((symbol-function 'run-with-timer)
                 (lambda (delay _repeat _fn &rest _args)
                   (setq scheduled-delay delay)
                   'fast-timer)))
        (ghostel--invalidate)
        (should (equal cancelled '(slow-timer)))
        (should (equal scheduled-delay 0.004))
        (should (eq ghostel--redraw-timer 'fast-timer))
        (should ghostel--redraw-timer-deadline)))))

(ert-deftest ghostel-test-typing-redraw-keeps-faster-existing-timer ()
  "Typing boost must not delay a redraw timer that is already earlier."
  (with-temp-buffer
    (let* ((now (current-time))
           (ghostel-adaptive-fps t)
           (ghostel-timer-delay 0.033)
           (ghostel-typing-redraw-delay 0.004)
           (ghostel-typing-redraw-window 0.08)
           (ghostel--last-send-time now)
           (ghostel--last-output-time now)
           (ghostel--redraw-timer 'fast-timer)
           (ghostel--redraw-timer-deadline (time-add now 0.001))
           cancelled
           scheduled-delay)
      (cl-letf (((symbol-function 'cancel-timer)
                 (lambda (timer) (push timer cancelled)))
                ((symbol-function 'run-with-timer)
                 (lambda (delay _repeat _fn &rest _args)
                   (setq scheduled-delay delay)
                   'slower-timer)))
        (ghostel--invalidate)
        (should-not cancelled)
        (should-not scheduled-delay)
        (should (eq ghostel--redraw-timer 'fast-timer))))))

(ert-deftest ghostel-test-typing-redraw-timer-does-not-redraw-copy-mode ()
  "A typing-boosted timer still respects copy mode's frozen terminal."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--input-mode 'copy)
          (ghostel--redraw-timer 'ghostel-test-timer)
          (ghostel--redraw-timer-deadline (time-add (current-time) 0.004))
          (redraw-called nil))
      (cl-letf (((symbol-function 'cancel-timer) #'ignore)
                ((symbol-function 'ghostel--redraw)
                 (lambda (&rest _args) (setq redraw-called t))))
        (ghostel--redraw-now (current-buffer))
        (should-not redraw-called)
        (should-not ghostel--redraw-timer)
        (should-not ghostel--redraw-timer-deadline)))))

(ert-deftest ghostel-test-synchronized-output-timeout-schedules-redraw ()
  "A redraw blocked by DECSET 2026 schedules the timeout fallback."
  (with-temp-buffer
    (let* ((now (current-time))
           (expected-deadline (time-add now 0.25))
           (ghostel--term 'fake)
           (ghostel--redraw-timer nil)
           (ghostel--redraw-timer-deadline nil)
           (ghostel--synchronized-output-redraw-deadline nil)
           (ghostel--force-next-redraw nil)
           (ghostel-synchronized-output-timeout 0.25)
           scheduled-delay
           scheduled-timer
           scheduled-callback
           scheduled-args
           rendered)
      (cl-letf (((symbol-function 'current-time) (lambda () now))
                ((symbol-function 'ghostel--terminal-live-p) (lambda () t))
                ((symbol-function 'ghostel--maybe-defer-redraw) (lambda (_buffer) nil))
                ((symbol-function 'ghostel--flush-pending-output) #'ignore)
                ((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term mode) (= mode 2026)))
                ((symbol-function 'run-with-timer)
                 (lambda (delay _repeat fn &rest args)
                   (setq scheduled-delay delay
                         scheduled-callback fn
                         scheduled-args args
                         scheduled-timer (list :timer delay
                                               :callback fn
                                               :args args))
                   scheduled-timer))
                ((symbol-function 'ghostel--redraw)
                 (lambda (&rest _args) (setq rendered t))))
        (ghostel--redraw-now (current-buffer))
        (should-not rendered)
        (should (equal scheduled-delay 0.25))
        (should (eq ghostel--redraw-timer scheduled-timer))
        (should (equal ghostel--synchronized-output-redraw-deadline
                       expected-deadline))
        (should (equal ghostel--redraw-timer-deadline expected-deadline))
        (should (eq scheduled-callback #'ghostel--redraw-now))
        (should (equal scheduled-args (list (current-buffer))))))))

(ert-deftest ghostel-test-synchronized-output-timeout-skips-before-deadline ()
  "A synchronized-output redraw before the deadline is still skipped."
  (with-temp-buffer
    (let* ((now (current-time))
           (deadline (time-add now 0.1))
           (ghostel--term 'fake)
           (ghostel--redraw-timer 'expired-redraw-timer)
           (ghostel--redraw-timer-deadline now)
           (ghostel--synchronized-output-redraw-deadline deadline)
           (ghostel--force-next-redraw nil)
           (ghostel-synchronized-output-timeout 0.25)
           cancelled
           scheduled-delay
           scheduled-timer
           scheduled-callback
           scheduled-args
           rendered)
      (cl-letf (((symbol-function 'current-time) (lambda () now))
                ((symbol-function 'cancel-timer) (lambda (timer) (push timer cancelled)))
                ((symbol-function 'ghostel--terminal-live-p) (lambda () t))
                ((symbol-function 'ghostel--maybe-defer-redraw) (lambda (_buffer) nil))
                ((symbol-function 'ghostel--flush-pending-output) #'ignore)
                ((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term mode) (= mode 2026)))
                ((symbol-function 'run-with-timer)
                 (lambda (delay _repeat fn &rest args)
                   (setq scheduled-delay delay
                         scheduled-callback fn
                         scheduled-args args
                         scheduled-timer (list :timer delay
                                               :callback fn
                                               :args args))
                   scheduled-timer))
                ((symbol-function 'ghostel--redraw)
                 (lambda (&rest _args) (setq rendered t))))
        (ghostel--redraw-now (current-buffer))
        (should (equal cancelled '(expired-redraw-timer)))
        (should-not rendered)
        (should (< (abs (- scheduled-delay 0.1)) 0.0001))
        (should (eq ghostel--redraw-timer scheduled-timer))
        (should (equal ghostel--redraw-timer-deadline deadline))
        (should (eq scheduled-callback #'ghostel--redraw-now))
        (should (equal scheduled-args (list (current-buffer))))
        (should (equal ghostel--synchronized-output-redraw-deadline deadline))))))

(ert-deftest ghostel-test-synchronized-output-timeout-forces-redraw-after-deadline ()
  "A broken DECSET 2026 session is rendered once the deadline passes."
  (with-temp-buffer
    (set-window-buffer (selected-window) (current-buffer))
    (let* ((deadline (current-time))
           (now (time-add deadline 0.001))
           (ghostel--term 'fake)
           (ghostel--redraw-timer 'expired-redraw-timer)
           (ghostel--redraw-timer-deadline deadline)
           (ghostel--synchronized-output-redraw-deadline deadline)
           (ghostel--force-next-redraw nil)
           (ghostel-synchronized-output-timeout 0.25)
           cancelled
           rendered)
      (cl-letf (((symbol-function 'current-time) (lambda () now))
                ((symbol-function 'cancel-timer) (lambda (timer) (push timer cancelled)))
                ((symbol-function 'ghostel--terminal-live-p) (lambda () t))
                ((symbol-function 'ghostel--maybe-defer-redraw) (lambda (_buffer) nil))
                ((symbol-function 'ghostel--flush-pending-output) #'ignore)
                ((symbol-function 'ghostel--mode-enabled)
                 (lambda (_term mode) (= mode 2026)))
                ((symbol-function 'ghostel--line-mode-pre-redraw) #'ignore)
                ((symbol-function 'ghostel--line-mode-post-redraw) #'ignore)
                ((symbol-function 'ghostel--redraw)
                 (lambda (_term &optional _full) (setq rendered t)))
                ((symbol-function 'ghostel--schedule-link-detection) #'ignore)
                ((symbol-function 'ghostel--detect-password-prompt) #'ignore))
        (ghostel--redraw-now (current-buffer))
        (should rendered)
        (should (equal cancelled '(expired-redraw-timer)))
        (should-not ghostel--redraw-timer)
        (should-not ghostel--redraw-timer-deadline)
        (should-not ghostel--force-next-redraw)
        (should-not ghostel--synchronized-output-redraw-deadline)))))

(ert-deftest ghostel-test-synchronized-output-timeout-disabled-preserves-skip ()
  "Nil or zero timeout keeps the old synchronized-output skip behavior."
  (dolist (timeout '(nil 0))
    (with-temp-buffer
      (let ((ghostel--term 'fake)
            (ghostel--redraw-timer nil)
            (ghostel--redraw-timer-deadline nil)
            (ghostel--synchronized-output-redraw-deadline nil)
            (ghostel--force-next-redraw nil)
            (ghostel-synchronized-output-timeout timeout)
            scheduled-delay
            rendered)
        (cl-letf (((symbol-function 'ghostel--terminal-live-p) (lambda () t))
                  ((symbol-function 'ghostel--maybe-defer-redraw) (lambda (_buffer) nil))
                  ((symbol-function 'ghostel--flush-pending-output) #'ignore)
                  ((symbol-function 'ghostel--mode-enabled)
                   (lambda (_term mode) (= mode 2026)))
                  ((symbol-function 'run-with-timer)
                   (lambda (delay _repeat fn &rest args)
                     (setq scheduled-delay delay)
                     (list :timer delay fn args)))
                  ((symbol-function 'ghostel--redraw)
                   (lambda (&rest _args) (setq rendered t))))
          (ghostel--redraw-now (current-buffer))
          (should-not rendered)
          (should-not scheduled-delay)
          (should-not ghostel--synchronized-output-redraw-deadline))))))

(ert-deftest ghostel-test-synchronized-output-timeout-clears-after-normal-redraw ()
  "A normal ESU/forced redraw clears stale synchronized-output deadline state."
  (with-temp-buffer
    (set-window-buffer (selected-window) (current-buffer))
    (let ((ghostel--term 'fake)
          (ghostel--redraw-timer 'stale-redraw-timer)
          (ghostel--redraw-timer-deadline (current-time))
          (ghostel--synchronized-output-redraw-deadline (current-time))
          (ghostel--force-next-redraw nil)
          cancelled
          rendered)
      (cl-letf (((symbol-function 'cancel-timer) (lambda (timer) (push timer cancelled)))
                ((symbol-function 'ghostel--terminal-live-p) (lambda () t))
                ((symbol-function 'ghostel--maybe-defer-redraw) (lambda (_buffer) nil))
                ((symbol-function 'ghostel--flush-pending-output) #'ignore)
                ((symbol-function 'ghostel--mode-enabled) (lambda (&rest _args) nil))
                ((symbol-function 'ghostel--line-mode-pre-redraw) #'ignore)
                ((symbol-function 'ghostel--line-mode-post-redraw) #'ignore)
                ((symbol-function 'ghostel--redraw)
                 (lambda (_term &optional _full) (setq rendered t)))
                ((symbol-function 'ghostel--schedule-link-detection) #'ignore)
                ((symbol-function 'ghostel--detect-password-prompt) #'ignore))
        (ghostel--redraw-now (current-buffer))
        (should rendered)
        (should (equal cancelled '(stale-redraw-timer)))
        (should-not ghostel--redraw-timer)
        (should-not ghostel--redraw-timer-deadline)
        (should-not ghostel--synchronized-output-redraw-deadline)))))

(ert-deftest ghostel-test-synchronized-output-timeout-rejects-invalid-value ()
  "Invalid synchronized-output timeout values signal instead of falling back."
  (let ((ghostel-synchronized-output-timeout -1))
    (should-error (ghostel--synchronized-output-timeout-delay)
                  :type 'user-error)))

(ert-deftest ghostel-test-write-pty-uses-direct-native-transport ()
  "`ghostel--write-pty' writes through the direct native transport.
The native module should not bounce direct PTY writes back through
`ghostel--process-send'."
  :tags '(native)
  (with-temp-buffer
    (let ((ghostel--term (ghostel--new 25 80 1000))
          (ghostel--process 'fake))
      (ghostel-test--with-native-pty-write-capture sent
        (ghostel--write-pty ghostel--term "\r")
        (should (equal sent "\r"))))))

(ert-deftest ghostel-test-send-encoded-sets-send-time ()
  "When the native encoder succeeds, last-send-time is updated."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--last-send-time nil))
      ;; Stub encode-key to return non-nil (success)
      (cl-letf (((symbol-function 'ghostel--encode-key)
                 (lambda (_term _key _mods &optional _utf8) t)))
        (ghostel--send-encoded "backspace" "")
        (should ghostel--last-send-time)))))

(ert-deftest ghostel-test-send-encoded-no-send-time-on-fallback ()
  "When the encoder fails, last-send-time is set by send-key, not send-encoded."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--process nil)
          (ghostel--last-send-time nil))
      ;; Stub encode-key to return nil (failure) — triggers raw fallback
      (cl-letf (((symbol-function 'ghostel--encode-key)
                 (lambda (_term _key _mods &optional _utf8) nil))
                ((symbol-function 'ghostel--process-live-p) (lambda (&optional _process) t))
                ((symbol-function 'ghostel--write-pty)
                 (lambda (_term _str) nil)))
        (setq ghostel--process 'fake)
        (ghostel--send-encoded "backspace" "")
        ;; send-key sets last-send-time via the fallback path
        (should ghostel--last-send-time)))))

(ert-deftest ghostel-test-control-key-bindings ()
  "All non-exception C-<letter> keys should be bound in semi-char-mode-map."
  (dolist (c (number-sequence ?a ?z))
    (let* ((key-str (format "C-%c" c))
           (key-vec (kbd key-str))
           (binding (lookup-key ghostel-semi-char-mode-map key-vec)))
      ;; Skip exceptions (may have sub-keymaps like C-c C-c)
      (unless (member key-str ghostel-keymap-exceptions)
        ;; Must be an actual command (interactive function or symbol),
        ;; not just non-nil — `(should binding)' would have accepted a
        ;; sub-keymap or numeric prefix-arg too.
        (should (commandp binding)))))
  ;; C-@ should also be bound (sends NUL).
  (should (commandp (lookup-key ghostel-semi-char-mode-map (kbd "C-@")))))

(ert-deftest ghostel-test-c-g-binding ()
  "`ghostel-mode-map' binds the quit key to a dedicated send handler."
  (should (eq (lookup-key ghostel-mode-map (kbd "C-g"))
              #'ghostel-send-C-g)))

(ert-deftest ghostel-test-c-g-exits-copy-mode ()
  "The quit key is bound in the fast-exit map to exit read-only mode."
  (should (eq (lookup-key ghostel-readonly-fast-exit-mode-map (kbd "C-g"))
              #'ghostel-readonly-exit)))

(ert-deftest ghostel-test-c-c-fast-exits-before-sending ()
  "The interrupt prefix exits copy/Emacs mode before forwarding."
  (let ((call-order nil)
        (send-args nil)
        (ghostel--input-mode 'copy)
        (ghostel-readonly-fast-exit t))
    (cl-letf (((symbol-function 'ghostel-readonly-exit)
               (lambda () (push 'exit call-order)))
              ((symbol-function 'ghostel--send-encoded)
               (lambda (key mods &rest _)
                 (setq send-args (list key mods))
                 (push 'send call-order))))
      (ghostel-send-C-c)
      (should (equal '(send exit) call-order))
      (should (equal '("c" "ctrl") send-args)))))

(ert-deftest ghostel-test-c-c-no-fast-exit-stays-readonly ()
  "The interrupt prefix stays in copy/Emacs mode when fast exit is off."
  (let ((exit-called nil)
        (ghostel--input-mode 'copy)
        (ghostel-readonly-fast-exit nil))
    (cl-letf (((symbol-function 'ghostel-readonly-exit)
               (lambda () (setq exit-called t)))
              ((symbol-function 'ghostel--send-encoded) #'ignore))
      (ghostel-send-C-c)
      (should-not exit-called))))

(ert-deftest ghostel-test-c-c-fast-exit-binding ()
  "The fast-exit map still routes the interrupt prefix through its command."
  (should (eq (lookup-key ghostel-readonly-fast-exit-mode-map (kbd "C-c C-c"))
              #'ghostel-send-C-c)))

(ert-deftest ghostel-test-inhibit-quit ()
  "`ghostel-mode' should set `inhibit-quit' buffer-locally."
  (let ((buf (generate-new-buffer " *ghostel-test-inhibit-quit*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (should (eq inhibit-quit t))
          (should (local-variable-p 'inhibit-quit)))
      (kill-buffer buf))))

(ert-deftest ghostel-test-c-g-deactivates-mark ()
  "The quit-key send handler clears an active region and `quit-flag'.
`keyboard-quit' is bypassed because `inhibit-quit' is set, so both
side effects have to happen explicitly inside the command."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-c-g-mark*"))
        (sent nil)
        ;; `region-active-p' and `deactivate-mark' both gate on
        ;; `transient-mark-mode', which is off in batch mode by default.
        (transient-mark-mode t))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((inhibit-read-only t))
            (insert "hello world"))
          (goto-char (point-min))
          (set-mark (point))
          (goto-char (point-max))
          (should (region-active-p))
          (setq quit-flag t)
          (cl-letf (((symbol-function 'ghostel--send-string)
                     (lambda (s) (push s sent))))
            (ghostel-send-C-g))
          (should-not (region-active-p))
          (should-not quit-flag)
          (should (equal sent (list (string 7)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-c-g-binding-routes-through-send-handler ()
  "Quit binding must route through the quit handler in both live input modes.
`ghostel--define-terminal-keys' binds every control-letter to a
lambda that sends the raw control code.  Without skipping the
quit binding, that lambda shadows the parent `ghostel-mode-map'
override and the function `deactivate-mark' plus the `quit-flag'
clear vanish on real keypresses (regression of #200 introduced
by the input-mode refactor)."
  :tags '(native)
  (should (eq (lookup-key ghostel-semi-char-mode-map (kbd "C-g"))
              #'ghostel-send-C-g))
  (should (eq (lookup-key ghostel-char-mode-map (kbd "C-g"))
              #'ghostel-send-C-g)))

(ert-deftest ghostel-test-meta-key-bindings ()
  "All non-exception M-<printable ASCII> keys should be bound in semi-char-mode.
Covers digits (M-1..M-9), punctuation (M-., M-,, M-/, ...), uppercase, and
lowercase letters.  Regression test for issue #314: only M-<a-z> was bound,
so M-<punct>/M-<digit> fell through to Emacs commands like
`xref-find-definitions'."
  (dolist (c (number-sequence ?! ?~))
    ;; ?y = ghostel-yank-pop; ?\[ and ?O are escape-sequence prefixes
    ;; intentionally not bound (would clobber TTY input decoding).
    (unless (memq c '(?y ?\[ ?O))
      (let* ((key-str (format "M-%c" c))
             (key-vec (ignore-errors (kbd key-str)))
             (binding (and key-vec
                           (lookup-key ghostel-semi-char-mode-map key-vec))))
        (when key-vec
          (if (member key-str ghostel-keymap-exceptions)
              (should-not (eq binding #'ghostel--send-event))
            (should (eq binding #'ghostel--send-event)))))))
  ;; Explicit regression guards for the keys called out in issue #314.
  (dolist (key-str '("M-." "M-," "M-/" "M-;" "M-1" "M-9" "M-!" "M-A" "M-Z"))
    (should (eq (lookup-key ghostel-semi-char-mode-map (kbd key-str))
                #'ghostel--send-event)))
  ;; M-SPC: source binds this explicitly because `(kbd "M- ")' won't parse.
  (should (eq (lookup-key ghostel-semi-char-mode-map (kbd "M-SPC"))
              #'ghostel--send-event))
  ;; Default exceptions (M-x, M-o, M-:) must still fall through to Emacs.
  (dolist (key-str '("M-x" "M-:"))
    (should-not (eq (lookup-key ghostel-semi-char-mode-map (kbd key-str))
                    #'ghostel--send-event)))
  (should (eq (lookup-key ghostel-semi-char-mode-map (kbd "M-y")) #'ghostel-yank-pop))
  ;; M-DEL must be bound so TTY Alt-Backspace ([27 127]) routes through
  ;; ghostel--send-event instead of global backward-kill-word.
  (should (eq (lookup-key ghostel-semi-char-mode-map (kbd "M-DEL")) #'ghostel--send-event)))

(ert-deftest ghostel-test-control-meta-key-bindings ()
  "Every non-exception Control-Meta letter chord routes to `ghostel--send-event'.
Regression test for issue #239: these chords must reach the shell as ESC +
control byte so readline `.inputrc' rules like \"\\e\\<C-letter>\" can fire,
instead of running Emacs commands like `forward-sexp'."
  (dolist (c (number-sequence ?a ?z))
    (let* ((key-str (format "C-M-%c" c))
           (binding (lookup-key ghostel-semi-char-mode-map (kbd key-str))))
      (if (member key-str ghostel-keymap-exceptions)
          (should-not (eq binding #'ghostel--send-event))
        (should (eq binding #'ghostel--send-event))))))

(ert-deftest ghostel-test-control-punct-key-bindings ()
  "Control + non-letter keys route to `ghostel--send-event' in semi-char.
C-] and C-/ previously fell through to Emacs (C-] = `abort-recursive-edit',
C-/ = `undo') instead of reaching the shell/readline.  Only the keys that
the ghostty encoder maps to a terminal byte are forwarded."
  (dolist (key-str '("C-]" "C-/"))
    (should (eq (lookup-key ghostel-semi-char-mode-map (kbd key-str))
                #'ghostel--send-event)))
  ;; Deliberately NOT forwarded (no terminal byte / would shadow Emacs):
  ;; C-^ / C-_ aren't encodable; C-,/C-. have no C0 byte; C-0..C-9 are
  ;; `digit-argument'.  These must keep their non-send-event resolution.
  (dolist (key-str '("C-^" "C-_" "C-," "C-." "C-0" "C-9"))
    (should-not (eq (lookup-key ghostel-semi-char-mode-map (kbd key-str))
                    #'ghostel--send-event)))
  ;; C-\ stays a default exception in semi-char (falls through to Emacs).
  (should-not (eq (lookup-key ghostel-semi-char-mode-map (kbd "C-\\"))
                  #'ghostel--send-event))
  ;; C-@ keeps its explicit NUL lambda (not send-event).
  (should (commandp (lookup-key ghostel-semi-char-mode-map (kbd "C-@"))))
  ;; ESC (C-[) must NOT be hijacked or TTY escape decoding breaks.
  (should-not (eq (lookup-key ghostel-semi-char-mode-map (kbd "C-["))
                  #'ghostel--send-event))
  ;; The ESC-prefix CSI/SS3 forms (ESC [ and ESC O) used by TTY input
  ;; decoding for arrows/function keys must stay unbound here.
  (should-not (eq (lookup-key ghostel-semi-char-mode-map [27 ?\[])
                  #'ghostel--send-event))
  (should-not (eq (lookup-key ghostel-semi-char-mode-map [27 ?O])
                  #'ghostel--send-event))
  ;; M-# (and the rest of the M-<punct> sweep) keeps working.
  (should (eq (lookup-key ghostel-semi-char-mode-map (kbd "M-#"))
              #'ghostel--send-event)))

(ert-deftest ghostel-test-control-meta-punct-key-bindings ()
  "Control-Meta + non-letter keys route to `ghostel--send-event'."
  (dolist (key-str '("C-M-]" "C-M-/"))
    (should (eq (lookup-key ghostel-semi-char-mode-map (kbd key-str))
                #'ghostel--send-event))))

(ert-deftest ghostel-test-control-punct-char-mode ()
  "Char mode forwards C-]/C-/ but keeps the explicit C-\\ lambda."
  (dolist (key-str '("C-]" "C-/" "C-M-]" "C-M-/"))
    (should (eq (lookup-key ghostel-char-mode-map (kbd key-str))
                #'ghostel--send-event)))
  ;; C-\ in char mode keeps its explicit \x1c lambda (not send-event).
  (should (commandp (lookup-key ghostel-char-mode-map (kbd "C-\\"))))
  (should-not (eq (lookup-key ghostel-char-mode-map (kbd "C-\\"))
                  #'ghostel--send-event))
  ;; ESC still must not be hijacked in char mode either.
  (should-not (eq (lookup-key ghostel-char-mode-map (kbd "C-["))
                  #'ghostel--send-event)))

(ert-deftest ghostel-test-encode-key-legacy-control-meta ()
  "Control-Meta letter chords encode to ESC + control byte in legacy mode.
Regression test for issue #239: these byte sequences match readline
`.inputrc' rules of the form \"\\e\\<C-letter>\"."
  :tags '(native)
  (let* ((term (ghostel--new 25 80 1000))
         (ghostel--term term)
         (ghostel--process 'fake)
         (sent nil))
    (ghostel-test--with-native-pty-write-capture sent
      (setq sent nil)
      (should (ghostel--encode-key term "f" "ctrl,meta" nil))
      (should (equal "\e\x06" sent))
      (setq sent nil)
      (should (ghostel--encode-key term "v" "ctrl,meta" nil))
      (should (equal "\e\x16" sent)))))

(ert-deftest ghostel-test-encode-key-legacy-control-punct ()
  "Control punctuation encodes to the correct C0 byte in legacy mode.
C-] is the headline case (-> 0x1d); C-/ -> 0x1f.  Control-Meta prepends
ESC, matching the bytes eat sends.  (Only the punctuation the ghostty
encoder recognizes is forwarded; see `ghostel--define-terminal-keys'.)"
  :tags '(native)
  (let* ((term (ghostel--new 25 80 1000))
         (ghostel--term term)
         (ghostel--process 'fake)
         (sent nil))
    (ghostel-test--with-native-pty-write-capture sent
      (pcase-dolist (`(,name ,bytes) '(("]" "\x1d") ("/" "\x1f")))
        (setq sent nil)
        (should (ghostel--encode-key term name "ctrl" nil))
        (should (equal bytes sent)))
      ;; Control-Meta prepends ESC: C-M-] -> 0x1b 0x1d, C-M-/ -> 0x1b 0x1f.
      (pcase-dolist (`(,name ,bytes) '(("]" "\e\x1d") ("/" "\e\x1f")))
        (setq sent nil)
        (should (ghostel--encode-key term name "ctrl,meta" nil))
        (should (equal bytes sent))))))

(ert-deftest ghostel-test-send-encoded-meta-period ()
  "M-. sends ESC + period via raw fallback (legacy alt encoding)."
  (let ((ghostel--term 'fake-term)
        (ghostel--process 'fake-process)
        sent)
    (cl-letf (((symbol-function 'ghostel--encode-key)
               (lambda (&rest _args) nil))
              ((symbol-function 'ghostel--process-live-p)
               (lambda (&optional _process) t))
              ((symbol-function 'ghostel--write-pty)
               (lambda (_term data) (setq sent data))))
      (ghostel--send-encoded "." "meta")
      (should (equal "\e." sent)))))

(ert-deftest ghostel-test-special-key-modifier-bindings ()
  "Modified special keys are bound unless in `ghostel-keymap-exceptions'.
Covers e.g. C-<return>, C-M-<down>, S-<f1>.
Bindings live on `ghostel-semi-char-mode-map' (not `ghostel-mode-map').
`S-<insert>' is the documented exception — bound to `ghostel-yank'."
  (dolist (key '("<return>" "<tab>" "<backspace>" "<escape>"
                 "<up>" "<down>" "<right>" "<left>"
                 "<home>" "<end>" "<prior>" "<next>"
                 "<deletechar>" "<insert>"
                 "<f1>" "<f2>" "<f3>" "<f4>" "<f5>" "<f6>"
                 "<f7>" "<f8>" "<f9>" "<f10>" "<f11>" "<f12>"))
    (dolist (mod '("" "S-" "C-" "M-" "C-S-" "M-S-" "C-M-"))
      (let* ((key-str (concat mod key))
             (binding (ignore-errors
                        (lookup-key ghostel-semi-char-mode-map (kbd key-str)))))
        (cond
         ((member key-str ghostel-keymap-exceptions)
          (should-not (eq binding #'ghostel--send-event)))
         ((equal key-str "S-<insert>")
          (should (eq binding #'ghostel-yank)))
         (t
          (should (eq binding #'ghostel--send-event))))))))

(ert-deftest ghostel-test-special-key-exceptions-honored ()
  "Keymap construction honors `ghostel-keymap-exceptions' for special keys.
Regression test for issue #210."
  (let ((ghostel-keymap-exceptions '("C-<return>" "C-M-<down>" "<f1>"))
        (map (make-sparse-keymap)))
    (dolist (key '("<return>" "<f1>" "<down>"))
      (unless (member key ghostel-keymap-exceptions)
        (define-key map (kbd key) #'ghostel--send-event))
      (dolist (mod '("C-" "C-M-"))
        (let ((key-str (concat mod key)))
          (unless (member key-str ghostel-keymap-exceptions)
            (ignore-errors
              (define-key map (kbd key-str) #'ghostel--send-event))))))
    ;; Exceptions should not be bound to ghostel--send-event
    (should-not (eq (lookup-key map (kbd "C-<return>")) #'ghostel--send-event))
    (should-not (eq (lookup-key map (kbd "C-M-<down>")) #'ghostel--send-event))
    (should-not (eq (lookup-key map (kbd "<f1>")) #'ghostel--send-event))
    ;; Non-exceptions should remain bound
    (should (eq (lookup-key map (kbd "<return>")) #'ghostel--send-event))
    (should (eq (lookup-key map (kbd "C-M-<return>")) #'ghostel--send-event))
    (should (eq (lookup-key map (kbd "C-<f1>")) #'ghostel--send-event))
    (should (eq (lookup-key map (kbd "C-<down>")) #'ghostel--send-event))))

(ert-deftest ghostel-test-send-event-tty-esc-prefix ()
  "Re-inject meta when the key arrives via ESC prefix (TTY Emacs).
In TTY Emacs, M-<key> is delivered as two events ([27 KEY]) via
`esc-map'.  `last-command-event' is just KEY with no meta modifier,
but `this-command-keys-vector' retains the ESC prefix."
  (let (captured-key captured-mods)
    (cl-letf (((symbol-function 'ghostel--send-encoded)
               (lambda (key mods &optional _utf8)
                 (setq captured-key key captured-mods mods))))
      (cl-flet ((sim-tty (keys-vec event expected-key expected-mods)
                  (setq captured-key nil captured-mods nil)
                  (cl-letf (((symbol-function 'this-command-keys-vector)
                             (lambda () keys-vec)))
                    (let ((last-command-event event))
                      (ghostel--send-event)))
                  (should (equal expected-key captured-key))
                  (should (equal expected-mods captured-mods))))
        ;; M-b in TTY: ESC then b → re-inject meta
        (sim-tty (vector 27 ?b)   ?b  "b" "meta")
        (sim-tty (vector 27 ?f)   ?f  "f" "meta")
        (sim-tty (vector 27 ?d)   ?d  "d" "meta")
        (sim-tty (vector 27 ?.)  ?.  "." "meta")
        (sim-tty (vector 27 ?1)  ?1  "1" "meta")
        ;; M-DEL in TTY: ESC then 127 → backspace + meta
        (sim-tty (vector 27 127)  127 "backspace" "meta")
        ;; Already-meta event (shouldn't double-add meta)
        (sim-tty (vector 27 ?b)   (aref (kbd "M-b") 0) "b" "meta")))))

(ert-deftest ghostel-test-char-mode-key-bindings ()
  "Char mode map should bind even keys in `ghostel-keymap-exceptions'."
  ;; Every C-<letter>, M-<letter>, and C-M-<letter> is bound in char
  ;; mode, including ones that semi-char mode reserves for Emacs.
  (dolist (c (number-sequence ?a ?z))
    (unless (memq c '(?i ?m))  ; C-i = TAB, C-m = RET handled separately
      (should (lookup-key ghostel-char-mode-map (kbd (format "C-%c" c))))))
  (dolist (c (number-sequence ?a ?z))
    (should (lookup-key ghostel-char-mode-map (kbd (format "M-%c" c))))
    (unless (eq c ?m)  ; C-M-m is the escape hatch (asserted below)
      (should (eq (lookup-key ghostel-char-mode-map (kbd (format "C-M-%c" c)))
                  #'ghostel--send-event))))
  ;; The escape hatch is M-RET / C-M-m → semi-char.
  (should (eq (lookup-key ghostel-char-mode-map (kbd "M-RET"))
              #'ghostel-semi-char-mode))
  (should (eq (lookup-key ghostel-char-mode-map (kbd "C-M-m"))
              #'ghostel-semi-char-mode)))

(ert-deftest ghostel-test-keymap-rebuild-on-exception-change ()
  "The custom setter for `ghostel-keymap-exceptions' rebuilds input maps.
Adding a key removes it from `ghostel-semi-char-mode-map' so the
global Emacs binding takes over; char mode binds every key
regardless of exceptions."
  (let ((orig (default-value 'ghostel-keymap-exceptions)))
    (unwind-protect
        (progn
          ;; Baseline: M-o is bound in semi-char (not an exception).
          (should (eq (lookup-key ghostel-semi-char-mode-map (kbd "M-o"))
                      #'ghostel--send-event))
          (customize-set-variable 'ghostel-keymap-exceptions
                                  (append orig '("M-o")))
          (should-not (lookup-key ghostel-semi-char-mode-map (kbd "M-o")))
          ;; Char mode is unaffected — it captures everything.
          (should (eq (lookup-key ghostel-char-mode-map (kbd "M-o"))
                      #'ghostel--send-event)))
      (customize-set-variable 'ghostel-keymap-exceptions orig))))

(ert-deftest ghostel-test-keymap-rebuild-preserves-object-identity ()
  "Rebuilding mutates `ghostel-semi-char-mode-map' in place.
Buffer-local references to the keymap need `eq'-identity to
survive a rebuild."
  (let ((orig (default-value 'ghostel-keymap-exceptions))
        (semi-id ghostel-semi-char-mode-map))
    (unwind-protect
        (progn
          (customize-set-variable 'ghostel-keymap-exceptions
                                  (append orig '("M-o")))
          (should (eq ghostel-semi-char-mode-map semi-id)))
      (customize-set-variable 'ghostel-keymap-exceptions orig))))

(ert-deftest ghostel-test-send-next-key-control-x ()
  "Send-next-key sends the prefix key as raw byte 24 (not intercepted by Emacs)."
  (let (sent-key)
    (cl-letf (((symbol-function 'ghostel--send-string)
               (lambda (str) (setq sent-key str))))
      (let ((unread-command-events (list ?\C-x)))
        (ghostel-send-next-key))
      (should (equal (string 24) sent-key)))))

(ert-deftest ghostel-test-send-next-key-control-h ()
  "Send-next-key sends the help key as raw byte 8."
  (let (sent-key)
    (cl-letf (((symbol-function 'ghostel--send-string)
               (lambda (str) (setq sent-key str))))
      (let ((unread-command-events (list ?\C-h)))
        (ghostel-send-next-key))
      (should (equal (string 8) sent-key)))))

(ert-deftest ghostel-test-send-next-key-regular-char ()
  "Send-next-key sends a regular character as-is."
  (let (sent-key)
    (cl-letf (((symbol-function 'ghostel--send-string)
               (lambda (str) (setq sent-key str))))
      (let ((unread-command-events (list ?a)))
        (ghostel-send-next-key))
      (should (equal "a" sent-key)))))

(ert-deftest ghostel-test-send-next-key-meta-x ()
  "Send-next-key routes meta-x through the encoder with meta modifier."
  (let (captured-key captured-mods
                     (ghostel--term 'fake))
    (cl-letf (((symbol-function 'ghostel--send-encoded)
               (lambda (key mods &optional _utf8)
                 (setq captured-key key captured-mods mods))))
      (let ((unread-command-events (list ?\M-x)))
        (ghostel-send-next-key))
      (should (equal "x" captured-key))
      (should (equal "meta" captured-mods)))))

(ert-deftest ghostel-test-send-next-key-function-key ()
  "Send-next-key routes function keys through the encoder."
  (let (captured-key captured-mods
                     (ghostel--term 'fake))
    (cl-letf (((symbol-function 'ghostel--send-encoded)
               (lambda (key mods &optional _utf8)
                 (setq captured-key key captured-mods mods))))
      (let ((unread-command-events (list 'up)))
        (ghostel-send-next-key))
      (should (equal "up" captured-key))
      (should (equal "" captured-mods)))))

(ert-deftest ghostel-test-send-string-routes-to-send-string ()
  "`ghostel-send-string' forwards its argument to `ghostel--send-string'."
  (with-temp-buffer
    (ghostel-mode)
    (let (sent)
      (cl-letf (((symbol-function 'ghostel--send-string)
                 (lambda (str) (setq sent str))))
        (ghostel-send-string "hello")
        (should (equal sent "hello"))))))

(ert-deftest ghostel-test-send-string-errors-outside-ghostel-buffer ()
  "`ghostel-send-string' signals `user-error' when not in a ghostel buffer."
  (with-temp-buffer
    (should-error (ghostel-send-string "x") :type 'user-error)))

(ert-deftest ghostel-test-send-key-routes-to-send-encoded ()
  "`ghostel-send-key' forwards key-name and mods to `ghostel--send-encoded'."
  (with-temp-buffer
    (ghostel-mode)
    (let (captured-key captured-mods)
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (key mods &optional _utf8)
                   (setq captured-key key captured-mods mods))))
        (ghostel-send-key "return" "ctrl")
        (should (equal captured-key "return"))
        (should (equal captured-mods "ctrl"))))))

(ert-deftest ghostel-test-send-key-nil-mods-becomes-empty-string ()
  "`ghostel-send-key' passes an empty string when MODS is omitted."
  (with-temp-buffer
    (ghostel-mode)
    (let (captured-mods)
      (cl-letf (((symbol-function 'ghostel--send-encoded)
                 (lambda (_key mods &optional _utf8)
                   (setq captured-mods mods))))
        (ghostel-send-key "up")
        (should (equal captured-mods ""))))))

(ert-deftest ghostel-test-send-key-errors-outside-ghostel-buffer ()
  "`ghostel-send-key' signals `user-error' when not in a ghostel buffer."
  (with-temp-buffer
    (should-error (ghostel-send-key "a") :type 'user-error)))

(ert-deftest ghostel-test-send-key-obsolete-alias-still-works ()
  "The obsolete `ghostel--send-key' alias routes to `ghostel--send-string'.
External packages may still call the old internal name."
  (let (sent)
    (cl-letf (((symbol-function 'ghostel--send-string)
               (lambda (str) (setq sent str))))
      (with-no-warnings
        (ghostel--send-key "payload"))
      (should (equal sent "payload")))))

(ert-deftest ghostel-test-paste-string-routes-to-paste-text ()
  "`ghostel-paste-string' forwards its argument to `ghostel--paste-text'."
  (with-temp-buffer
    (ghostel-mode)
    (let (received)
      (cl-letf (((symbol-function 'ghostel--paste-text)
                 (lambda (str) (setq received str))))
        (ghostel-paste-string "hello world")
        (should (equal received "hello world"))))))

(ert-deftest ghostel-test-paste-string-errors-outside-ghostel-buffer ()
  "`ghostel-paste-string' signals `user-error' when not in a ghostel buffer."
  (with-temp-buffer
    (should-error (ghostel-paste-string "x") :type 'user-error)))



(ert-deftest ghostel-test-send-key-dispatches-through-module-pty-writer ()
  "Immediate key sends should dispatch through the module PTY writer."
  (with-temp-buffer
    (let* ((ghostel--process 'fake-process)
           (ghostel--term 'fake-term)
           (ghostel--last-send-time nil)
           (sent nil))
      (let ((comp-enable-subr-trampolines nil)
            (native-comp-enable-subr-trampolines nil))
        (cl-letf (((symbol-function 'ghostel--process-live-p) (lambda (&optional _process) t))
                  ((symbol-function 'ghostel--write-pty)
                   (lambda (term str)
                     (setq sent (cons term str))))
                  ((symbol-function 'process-send-string)
                   (lambda (&rest args)
                     (ert-fail
                      (format "unexpected direct process-send-string: %S"
                              args)))))
           (ghostel--send-key "a")
           (should (equal '(fake-term . "a") sent)))))))

(ert-deftest ghostel-test-control-key-bindings-cover-upstream-range ()
  "Ghostel binds the upstream control-key range plus C-@ passthrough."
  (let ((sent nil))
    (cl-letf (((symbol-function 'ghostel--send-string)
               (lambda (key)
                 (setq sent key))))
      (dolist (entry '(("C-t" . "\x14")
                       ("C-v" . "\x16")
                       ("C-@" . "\x00")))
        (setq sent nil)
         (let ((binding (lookup-key ghostel-semi-char-mode-map (kbd (car entry)))))
           (should binding)
           (funcall binding)
           (should (equal (cdr entry) sent)))))))

(ert-deftest ghostel-test-meta-key-bindings-reach-terminal ()
  "Meta-letter bindings stay routed to the terminal."
  (dolist (key '("M-a" "M-z"))
    (should (eq #'ghostel--send-event
                (lookup-key ghostel-semi-char-mode-map (kbd key))))))

(ert-deftest ghostel-test-window-resize-updates-terminal-and-returns-size ()
  "Resize should update the native terminal and return the requested PTY size."
  (with-temp-buffer
    (let ((ghostel--term 'fake-term)
          (ghostel--resize-timer nil)
          (ghostel--force-next-redraw nil)
          (size-call nil)
          (redraw-called nil)
          (window 'fake-window)
          (cur-buf (current-buffer)))
      (let ((comp-enable-subr-trampolines nil)
            (native-comp-enable-subr-trampolines nil))
        (cl-letf (((default-value 'window-adjust-process-window-size-function)
                   (lambda (_proc _wins) '(80 . 25)))
                  ((symbol-function 'ghostel--mode-enabled)
                   (lambda (&rest _) nil))
                  ((symbol-function 'process-live-p) (lambda (_) t))
                  ((symbol-function 'selected-window) (lambda () window))
                  ((symbol-function 'window-buffer)
                  (lambda (win)
                     (when (eq win window)
                       cur-buf)))
                  ((symbol-function 'process-buffer) (lambda (_) cur-buf))
                  ((symbol-function 'buffer-live-p) (lambda (_) t))
                  ((symbol-function 'ghostel--alt-screen-p) (lambda (&rest _) nil))
                  ((symbol-function 'ghostel--set-size-with-cell-dims)
                   (lambda (term height width)
                     (setq size-call (list term height width))))
                  ((symbol-function 'ghostel--cancel-plain-link-detection) #'ignore)
                  ((symbol-function 'ghostel--redraw-now)
                   (lambda (buf)
                     (setq redraw-called buf)))
                  ((symbol-function 'set-process-window-size)
                   (lambda (&rest args)
                     (ert-fail
                      (format "unexpected direct set-process-window-size: %S"
                              args)))))
          (should (equal '(80 . 25)
                         (ghostel--window-adjust-process-window-size
                          'fake-process (list window))))
          (should (equal '(fake-term 25 80) size-call))
          (should (eq cur-buf redraw-called)))))))

(provide 'ghostel-keys-test)
(ert-deftest ghostel-test-filter-writes-vt-and-invalidates ()
  "`ghostel--filter' feeds output to the terminal and triggers a redraw.
The redraw-timing decision lives in `ghostel--invalidate'; the filter
only feeds bytes and invalidates."
  (with-temp-buffer
    (let ((buf (current-buffer))
          (ghostel--term 'fake)
          (written nil)
          (invalidated nil))
      (cl-letf (((symbol-function 'process-buffer) (lambda (_) buf))
                ((symbol-function 'ghostel--write-vt)
                 (lambda (_term data) (setq written data)))
                ((symbol-function 'ghostel--invalidate)
                 (lambda () (setq invalidated t))))
        (ghostel--filter 'fake-proc "hello")
        (should (equal "hello" written))
        (should invalidated)))))

(ert-deftest ghostel-test-invalidate-schedules-timer-when-send-stale ()
  "With no recent keystroke, redraw is deferred to the coalescing timer.
Bulk output (nothing sent within `ghostel-immediate-redraw-interval')
must not redraw synchronously."
  (with-temp-buffer
    (let ((ghostel--last-send-time (time-subtract (current-time) 1))
          (ghostel-immediate-redraw-interval 0.05)
          (ghostel-adaptive-fps nil)
          (ghostel--redraw-timer nil)
          (redraw-now-called nil)
          (timer-scheduled nil))
      (cl-letf (((symbol-function 'ghostel--redraw-now)
                 (lambda (_buf) (setq redraw-now-called t)))
                ((symbol-function 'run-with-timer)
                 (lambda (&rest _) (setq timer-scheduled t) 'fake-timer)))
        (ghostel--invalidate)
        (should-not redraw-now-called)
        (should timer-scheduled)
        (should (eq ghostel--redraw-timer 'fake-timer))))))

(ert-deftest ghostel-test-invalidate-keeps-earlier-pending-timer ()
  "A pending earlier redraw timer is reused, not delayed."
  (with-temp-buffer
    (let* ((now (current-time))
           (ghostel--last-send-time (time-subtract now 1))
           (ghostel-adaptive-fps nil)
           (ghostel--redraw-timer 'existing-timer)
           (ghostel--redraw-timer-deadline (time-add now 0.001))
           cancelled
           timer-scheduled)
      (cl-letf (((symbol-function 'current-time)
                 (lambda () now))
                ((symbol-function 'cancel-timer)
                 (lambda (timer) (push timer cancelled)))
                ((symbol-function 'run-with-timer)
                 (lambda (&rest _) (setq timer-scheduled t) 'fake-timer)))
        (ghostel--invalidate)
        (should-not cancelled)
        (should-not timer-scheduled)
        (should (eq ghostel--redraw-timer 'existing-timer))))))

(ert-deftest ghostel-test-send-string-writes-to-pty-and-records-send-time ()
  "`ghostel--send-string' writes through the module PTY boundary."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--process 'fake-proc)
          (ghostel--last-send-time nil)
          sent)
      (cl-letf (((symbol-function 'ghostel--process-live-p) (lambda (&optional _p) t))
                ((symbol-function 'ghostel--write-pty)
                 (lambda (term str) (setq sent (list term str))))
                ((symbol-function 'process-send-string)
                 (lambda (&rest args)
                   (ert-fail
                    (format "unexpected process-send-string: %S" args)))))
        (ghostel--send-string "a")
        (should (equal sent '(fake "a")))
        (should ghostel--last-send-time)))))

(ert-deftest ghostel-test-send-encoded-fallback-writes-raw-key ()
  "When native encoding fails, raw fallback writes through `ghostel--write-pty'."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--process 'fake-proc)
          sent)
      (cl-letf (((symbol-function 'ghostel--encode-key)
                 (lambda (_term _key _mods &optional _utf8) nil))
                ((symbol-function 'ghostel--process-live-p) (lambda (&optional _p) t))
                ((symbol-function 'ghostel--write-pty)
                 (lambda (_term str) (push str sent))))
        (ghostel--send-encoded "backspace" "")
        (should (equal sent '("\x7f")))))))

(ert-deftest ghostel-test-send-encoded-fallback-records-send-time ()
  "Fallback key sends also record send time."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--process 'fake-proc)
          (ghostel--last-send-time nil))
      ;; Stub encode-key to return nil (failure) — triggers raw fallback.
      (cl-letf (((symbol-function 'ghostel--encode-key)
                 (lambda (_term _key _mods &optional _utf8) nil))
                ((symbol-function 'ghostel--process-live-p) (lambda (&optional _p) t))
                ((symbol-function 'ghostel--write-pty) #'ignore))
        (ghostel--send-encoded "backspace" "")
        (should ghostel--last-send-time)))))

;;; ghostel-keys-test.el ends here
