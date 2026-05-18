;;; ghostel-render-test.el --- Tests for ghostel: render -*- lexical-binding: t; -*-

;;; Commentary:

;; SGR styling, dim, face props, multibyte / wide-char, title, CRLF, ANSI color
;; palette, theme sync, hyperlinks & URL detection.

;;; Code:

(require 'ghostel-test-helpers)

(ert-deftest ghostel-test-sgr ()
  "Test SGR escape sequences set cell styles."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "\e[1;31mHELLO\e[0m normal")
    (should (equal "HELLO normal" (ghostel-test--row0 term))))) ; styled text content

(ert-deftest ghostel-test-dim-text ()
  "Test that SGR 2 (faint) produces a dimmed foreground color, not :weight light."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-dim*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            ;; Set a known palette so we can predict the dimmed color.
            ;; Default FG=#ffffff, default BG=#000000, red=#ff0000.
            (let ((rest (apply #'concat (make-list 14 "#000000"))))
              (ghostel--set-palette term
                                    (concat "#000000" "#ff0000" rest
                                            "#ffffff" "#000000")))
            ;; Dim text with default foreground
            (ghostel--write-input term "\e[2mDIM\e[0m ok")
            (ghostel--redraw term)
            (goto-char (point-min))
            (let ((face (get-text-property (point) 'face)))
              (should face)                                   ; face property exists
              (when face
                ;; Should have a :foreground (dimmed color), not :weight light
                (should (plist-get face :foreground))         ; dimmed :foreground set
                (should-not (eq 'light (plist-get face :weight)))))))  ; no :weight light
      (kill-buffer buf))))

(ert-deftest ghostel-test-face-props-survive-font-lock ()
  "Regression: per-cell face text-properties must survive a font-lock pass.
User configs that force `font-lock-defaults' on (notably Doom Emacs,
which sets `(nil t)' globally) cause `font-lock-mode' to activate in
ghostel buffers despite the mode body disabling it.  JIT-lock's
fontify pass then calls `font-lock-unfontify-region' which, without
the buffer-local override installed by `ghostel-mode', strips every
`face' property the native module wrote."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-fl*")))
    (unwind-protect
        (with-current-buffer buf
          ;; Activate `ghostel-mode' so the fix under test (buffer-local
          ;; `font-lock-unfontify-region-function' override) is installed.
          (ghostel-mode)
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            (setq-local ghostel--term term)
            ;; Known palette so the red SGR resolves predictably.
            (let ((rest (apply #'concat (make-list 14 "#000000"))))
              (ghostel--set-palette term
                                    (concat "#000000" "#ff0000" rest
                                            "#ffffff" "#000000")))
            (ghostel--write-input term "\e[31mRED\e[0m normal")
            (ghostel--redraw term t)
            (goto-char (point-min))
            (let ((face-before (get-text-property (point) 'face)))
              (should face-before)
              (should (plist-get face-before :foreground))
              ;; Simulate a user config that force-enables font-lock.
              ;; Without the buffer-local unfontify override installed
              ;; by `ghostel-mode', the fontify pass would strip face
              ;; props across the buffer.
              (setq-local font-lock-defaults '(nil t))
              (font-lock-mode 1)
              (font-lock-ensure (point-min) (point-max))
              ;; Face property for the coloured cell must still be there.
              (goto-char (point-min))
              (let ((face-after (get-text-property (point) 'face)))
                (should face-after)
                (should (plist-get face-after :foreground))
                (should (equal (plist-get face-before :foreground)
                               (plist-get face-after :foreground)))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-set-buffer-face-uses-default-face-colors ()
  "Regression: New terminal colors should not flicker.
ghostel--set-buffer-face must only ever receive ghostel-default face colors in
new terminal. Regression guard against color flickering."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-face-colors*"))
        (calls nil))
    (unwind-protect
        (let ((expected-fg (ghostel--face-hex-color 'ghostel-default :foreground))
              (expected-bg (ghostel--face-hex-color 'ghostel-default :background)))
          (cl-letf (((symbol-function 'ghostel--start-process) (lambda () nil))
                    ((symbol-function 'ghostel--set-buffer-face)
                     (lambda (fg bg) (push (list fg bg) calls))))
            (ghostel--init-buffer buf)
            (with-current-buffer buf
              (let ((inhibit-read-only t))
                (ghostel--write-input ghostel--term "hello")
                (ghostel--redraw ghostel--term t))))
          (should calls)
          (dolist (call calls)
            (should (equal expected-fg (car call)))
            (should (equal expected-bg (cadr call)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-multibyte-rendering ()
  "Test that styled multi-byte text renders without args-out-of-range."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-mb*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            (ghostel--write-input term "\e[32m┌──┐\e[0m text")
            (ghostel--redraw term)
            (let ((content (buffer-substring-no-properties (point-min) (point-max))))
              (should (string-match-p "┌──┐" content))    ; box drawing rendered
              (should (string-match-p "text" content)))    ; text after box drawing
            (goto-char (point-min))
            (should (get-text-property (point) 'face))))   ; multibyte face property
      (kill-buffer buf))))

(ert-deftest ghostel-test-wide-char-no-overflow ()
  "Test that wide characters (emoji) don't make rendered lines overflow.
A 2-cell-wide emoji should not produce an extra space for the spacer
cell, so the visual line width must equal the emoji width (2).  The
renderer trims trailing blank cells, so we compare against 2 rather
than the full terminal `cols'."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-wide*"))
        (cols 40))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 cols 100))
                 (inhibit-read-only t))
            ;; Feed a wide emoji — occupies 2 terminal cells
            (ghostel--write-input term "🟢")
            (ghostel--redraw term t)
            ;; First rendered line should have visual width 2 (the
            ;; emoji) and no trailing padding from the spacer cell.
            (goto-char (point-min))
            (let* ((line (buffer-substring (line-beginning-position)
                                           (line-end-position)))
                   (width (string-width line)))
              (should (equal 2 width))
              ;; And the line must NOT exceed the terminal width.
              (should (<= width cols)))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-title ()
  "Test OSC 2 title change."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "\e]2;My Title\e\\")
    (should (equal "My Title" (ghostel--get-title term))))) ; title set via OSC 2

(ert-deftest ghostel-test-title-does-not-overwrite-manual-rename ()
  "Test that title updates do not overwrite a manual buffer rename."
  (let (buf)
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--new)
                   (lambda (&rest _args) 'fake-term))
                  ((symbol-function 'ghostel--set-size) #'ignore)
                  ((symbol-function 'ghostel--apply-palette)
                   (lambda (&rest _args) nil))
                  ((symbol-function 'ghostel--start-process)
                   (lambda () nil)))
          (ghostel)
          (setq buf (current-buffer))
          (with-current-buffer buf
            (should (equal "*ghostel*" (buffer-name)))
            (should (equal "*ghostel*" ghostel--managed-buffer-name))
            (ghostel--set-title "Title A")
            (should (equal "*ghostel: Title A*" (buffer-name)))
            (should (equal "*ghostel: Title A*" ghostel--managed-buffer-name))
            (ghostel--set-title "Title A2")
            (should (equal "*ghostel: Title A2*" (buffer-name)))
            (should (equal "*ghostel: Title A2*" ghostel--managed-buffer-name))
            (rename-buffer "ghostel manual title test" t)
            (ghostel--set-title "Title B")
            (should (equal "ghostel manual title test" (buffer-name)))
            (should (equal "*ghostel: Title A2*" ghostel--managed-buffer-name))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ghostel-test-title-tracking-disabled ()
  "Test that title updates are ignored when `ghostel-set-title-function' is nil."
  (let (buf)
    (unwind-protect
        (cl-letf (((symbol-function 'ghostel--new)
                   (lambda (&rest _args) 'fake-term))
                  ((symbol-function 'ghostel--set-size) #'ignore)
                  ((symbol-function 'ghostel--apply-palette)
                   (lambda (&rest _args) nil))
                  ((symbol-function 'ghostel--start-process)
                   (lambda () nil)))
          (let ((ghostel-set-title-function nil))
            (ghostel)
            (setq buf (current-buffer))
            (with-current-buffer buf
              (should (equal "*ghostel*" (buffer-name)))
              (ghostel--set-title "Ignored Title")
              (should (equal "*ghostel*" (buffer-name)))
              (should (equal "*ghostel*" ghostel--managed-buffer-name)))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ghostel-test-crlf ()
  "Test that bare LF is normalized to CRLF by the Zig module."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000)))
    (ghostel--write-input term "first\nsecond")
    (let ((state (ghostel--copy-all-text term)))
      (should (string-match-p "first" state))              ; first line
      (should (string-match-p "second" state)))             ; second line
    (let ((cur (ghostel-test--cursor term)))
      (should (equal 6 (car cur)))                          ; cursor col after LF
      (should (> (cdr cur) 0)))))                           ; cursor moved to row 1+

(ert-deftest ghostel-test-crlf-split-across-writes ()
  "CRLF pair split across two write-input calls must not double-insert \\r.
Chunk A ends with \\r, chunk B starts with \\n.  Without cross-call
state the normalizer would treat the leading \\n as bare and emit
\\r\\r\\n to libghostty.  Visible effect: cursor lands on row 1 col 6
after \"first\\r\" + \"\\nsecond\", exactly as if the pair were sent in
one call; a bug would leave it on row 2 or otherwise desynced."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000))
        (term-single (ghostel--new 25 80 1000)))
    (ghostel--write-input term "first\r")
    (ghostel--write-input term "\nsecond")
    (ghostel--write-input term-single "first\r\nsecond")
    (should (equal (ghostel-test--cursor term)
                   (ghostel-test--cursor term-single)))))

(ert-deftest ghostel-test-crlf-split-with-empty-chunk ()
  "An empty write between \\r and \\n preserves the cross-call CR flag.
Regression guard for a naive implementation that resets `last_input_was_cr'
on every entry rather than only when input was consumed."
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000))
        (term-single (ghostel--new 25 80 1000)))
    (ghostel--write-input term "first\r")
    (ghostel--write-input term "")          ; empty chunk must not clear flag
    (ghostel--write-input term "\nsecond")
    (ghostel--write-input term-single "first\r\nsecond")
    (should (equal (ghostel-test--cursor term)
                   (ghostel-test--cursor term-single)))))

(ert-deftest ghostel-test-crlf-standalone-cr-then-crlf ()
  "A lone CR followed by a complete CRLF stays two logical line-endings.
The normalizer must not collapse the trailing CR of write A and the
leading \\r of write B's \\r\\n into a single sequence: the input
\"a\\r\" + \"\\r\\nb\" is equivalent to sending \"a\\r\\r\\nb\" in one
call.  (Bare \\n comes from Emacs PTYs lacking ONLCR; bare \\r from
programs that explicitly emit a carriage return — both must be passed
through without cross-call munging.)"
  :tags '(native)
  (let ((term (ghostel--new 25 80 1000))
        (term-single (ghostel--new 25 80 1000)))
    (ghostel--write-input term "a\r")
    (ghostel--write-input term "\r\nb")
    (ghostel--write-input term-single "a\r\r\nb")
    (should (equal (ghostel-test--cursor term)
                   (ghostel-test--cursor term-single)))))

(ert-deftest ghostel-test-color-palette ()
  "Test setting a custom ANSI color palette via faces."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-palette*")))
    (unwind-protect
        (with-current-buffer buf
          (let* ((term (ghostel--new 5 40 100))
                 (inhibit-read-only t))
            ;; Set palette index 1 (red) to a known color via set-palette
            (let ((rest (apply #'concat (make-list 14 "#000000"))))
              (ghostel--set-palette term
                                    (concat "#000000" "#ff0000" rest)))
            ;; Write red text (SGR 31 = ANSI red = palette index 1)
            (ghostel--write-input term "\e[31mRED\e[0m")
            (ghostel--redraw term)
            (should (string-match-p "RED"                  ; red text rendered
                                    (buffer-substring-no-properties
                                     (point-min) (point-max))))
            ;; Check that the face property uses our custom red
            (goto-char (point-min))
            (let ((face (get-text-property (point) 'face)))
              (should face)                                ; face property exists
              (when face
                (let ((fg (plist-get face :foreground)))
                  (should (and fg (string= fg "#ff0000"))))))))  ; foreground is custom red
      (kill-buffer buf))))

(ert-deftest ghostel-test-apply-palette ()
  "Test the face-based apply-palette helper."
  :tags '(native)
  (let ((term (ghostel--new 5 40 100)))
    (should (ghostel--apply-palette term)))                ; apply-palette succeeds

  ;; Test face-hex-color extraction
  (let ((color (ghostel--face-hex-color 'ghostel-color-red :foreground)))
    (should (and (stringp color)                           ; face color is hex string
                 (string-prefix-p "#" color)
                 (= (length color) 7)))))

(ert-deftest ghostel-test-hyperlinks ()
  "Test hyperlink keymap and helpers."
  :tags '(native)
  (should (keymapp ghostel-link-map))                      ; ghostel-link-map is a keymap
  (should (lookup-key ghostel-link-map [mouse-1]))         ; mouse-1 bound in link map
  (should (lookup-key ghostel-link-map [mouse-2]))         ; mouse-2 bound in link map
  ;; RET is intentionally NOT bound in the text-property link map: a
  ;; binding there outranks the local map and hijacks RET away from the
  ;; PTY when a typed substring is misdetected as a link.  The
  ;; RET-follows-link affordance lives in the read-only and line-mode
  ;; maps so it works in copy, Emacs, and line modes without
  ;; intercepting RET in semi-char/char.
  (should (null (lookup-key ghostel-link-map (kbd "RET"))))
  (should (eq #'ghostel-open-link-at-point
              (lookup-key ghostel-readonly-mode-map (kbd "RET"))))
  (should (eq #'ghostel-open-link-at-point
              (lookup-key ghostel-readonly-mode-map (kbd "<return>"))))
  (should (eq #'ghostel-line-mode-send-or-open-link
              (lookup-key ghostel-line-mode-map (kbd "RET"))))
  (should (eq #'ghostel-line-mode-send-or-open-link
              (lookup-key ghostel-line-mode-map (kbd "<return>"))))
  (should (commandp #'ghostel-open-link-at-point))         ; open-link-at-point is interactive
  (should (null (ghostel--open-link nil)))                 ; open-link returns nil for empty
  (should (null (ghostel--open-link 42))))                 ; open-link returns nil for non-string

(ert-deftest ghostel-test-uri-at-pos-prefers-string-help-echo ()
  "`ghostel--uri-at-pos' returns a string `help-echo' without calling native.
Plain-text link detection stores URIs as strings; the native path must
not be reached when the property is already a string."
  (with-temp-buffer
    (insert "click here")
    (put-text-property 1 11 'help-echo "https://static.example.com")
    (goto-char 5)
    (let (native-called)
      (cl-letf (((symbol-function 'ghostel--native-uri-at-pos)
                 (lambda (_) (setq native-called t) "should-not-reach")))
        (should (equal "https://static.example.com"
                       (ghostel--uri-at-pos (point))))
        (should-not native-called)))))

(ert-deftest ghostel-test-uri-at-pos-calls-native-for-function-help-echo ()
  "`ghostel--uri-at-pos' delegates to native when `help-echo' is a function.
OSC8 links set `help-echo' to the symbol `ghostel--native-link-help-echo';
`ghostel--uri-at-pos' must call `ghostel--native-uri-at-pos' in that case."
  (with-temp-buffer
    (insert "click here")
    (put-text-property 1 11 'help-echo #'ghostel--native-link-help-echo)
    (goto-char 5)
    (cl-letf (((symbol-function 'ghostel--native-uri-at-pos)
               (lambda (_pos) "native-uri")))
      (should (equal "native-uri" (ghostel--uri-at-pos (point)))))))

(ert-deftest ghostel-test-native-link-help-echo-calls-uri-at-pos ()
  "`ghostel--native-link-help-echo' delegates to `ghostel--native-uri-at-pos'.
The help-echo handler stored on OSC8 link text-properties must call the
native URI lookup when Emacs invokes it for tooltip display or clicking."
  (let ((buf (generate-new-buffer " *ghostel-test-echo-handler*"))
        (orig-buf (window-buffer (selected-window))))
    (unwind-protect
        (progn
          (set-window-buffer (selected-window) buf)
          (with-current-buffer buf
            (insert "test content")
            (cl-letf (((symbol-function 'ghostel--native-uri-at-pos)
                       (lambda (pos) (format "uri-at-%d" pos))))
              (should (equal "uri-at-1"
                             (ghostel--native-link-help-echo
                              (selected-window) nil 1))))))
      (when (buffer-live-p orig-buf)
        (set-window-buffer (selected-window) orig-buf))
      (kill-buffer buf))))

(ert-deftest ghostel-test-url-detection ()
  "Test automatic URL detection in plain text."
  ;; Test buffers add a trailing newline so point lands on an empty line
  ;; below the test content; the cursor-row skip in `ghostel--detect-urls'
  ;; then leaves the test content untouched.
  ;; Basic URL detection
  (with-temp-buffer
    (insert "Visit https://example.com for info\n")
    (let ((ghostel-enable-url-detection t))
      (ghostel--detect-urls))
    (should (equal "https://example.com"                   ; url help-echo
                   (get-text-property 7 'help-echo)))
    (should (get-text-property 7 'mouse-face))             ; url mouse-face
    (should (get-text-property 7 'keymap)))                ; url keymap
  ;; Disabled detection
  (with-temp-buffer
    (insert "Visit https://example.com for info\n")
    (let ((ghostel-enable-url-detection nil))
      (ghostel--detect-urls))
    (should (null (get-text-property 7 'help-echo))))      ; url detection disabled
  ;; Skips existing OSC 8 links (help-echo is the native handler function symbol)
  (with-temp-buffer
    (insert "Visit https://other.com for info\n")
    (put-text-property 7 26 'help-echo #'ghostel--native-link-help-echo)
    (let ((ghostel-enable-url-detection t))
      (ghostel--detect-urls))
    (should (eq #'ghostel--native-link-help-echo           ; osc8 handler not overwritten
                (get-text-property 7 'help-echo))))
  ;; URL not ending in punctuation
  (with-temp-buffer
    (insert "See https://example.com/path.\n")
    (let ((ghostel-enable-url-detection t))
      (ghostel--detect-urls))
    (should (equal "https://example.com/path"              ; url strips trailing dot
                   (get-text-property 5 'help-echo))))
  ;; File:line detection with absolute path
  (unless (eq system-type 'windows-nt)
    (let ((test-file (locate-library "ghostel")))
    (with-temp-buffer
      (insert (format "Error at %s:42 bad\n" test-file))
      (let ((ghostel-enable-url-detection t))
        (ghostel--detect-urls))
      (let ((he (get-text-property 10 'help-echo)))
        (should (and he (string-prefix-p "fileref:" he)))  ; file:line help-echo set
        (should (and he (string-suffix-p ":42" he)))))     ; file:line contains line number
    ;; File detection is pattern-only; non-existent files still produce links.
    (with-temp-buffer
      (insert "Error at /no/such/file.el:10 bad\n")
      (let ((ghostel-enable-url-detection t))
        (ghostel--detect-urls))
      (should (equal (concat "fileref:"
                             (expand-file-name "/no/such/file.el")
                             ":10")
                     (get-text-property 10 'help-echo))))
    ;; File detection disabled
    (with-temp-buffer
      (insert (format "Error at %s:42 bad\n" test-file))
      (let ((ghostel-enable-url-detection t)
            (ghostel-enable-file-detection nil))
        (ghostel--detect-urls))
      (should (null (get-text-property 10 'help-echo))))   ; file detection disabled
    ;; ghostel--open-link dispatches fileref:
    (let ((opened nil))
      (cl-letf (((symbol-function 'find-file-other-window)
                 (lambda (f) (setq opened f))))
        (ghostel--open-link (format "fileref:%s:10" test-file)))
      (should (equal test-file opened)))                   ; fileref opens correct file
    ;; Helper: find the first fileref help-echo anywhere in the buffer.
    (cl-flet ((find-fileref ()
                (save-excursion
                  (let ((pos (point-min)) found)
                    (while (and (not found) pos (< pos (point-max)))
                      (let ((he (get-text-property pos 'help-echo)))
                        (when (and he (string-prefix-p "fileref:" he))
                          (setq found he)))
                      (setq pos (next-single-property-change
                                 pos 'help-echo nil (point-max))))
                    found))))
      ;; Bare relative path (Rust/Go/TS compiler output)
      (let ((dir (file-name-directory test-file))
            (rel "ghostel.el"))
        ;; Pattern-only bare relative path: linkified without stat'ing it.
        (with-temp-buffer
          (setq default-directory dir)
          (insert (format "   --> wrapped/%s:43\n" rel))
          (let ((ghostel-enable-url-detection t))
            (ghostel--detect-urls))
          (should (equal (concat "fileref:"
                                 (expand-file-name (format "wrapped/%s" rel)
                                                   dir)
                                 ":43")
                         (find-fileref))))
        ;; Existing bare relative path: linkified with line AND column preserved
        (with-temp-buffer
          (setq default-directory (file-name-directory (directory-file-name dir)))
          (insert (format "  --> %s/%s:43:4\n"
                          (file-name-nondirectory (directory-file-name dir))
                          rel))
          (let ((ghostel-enable-url-detection t))
            (ghostel--detect-urls))
          (let ((he (find-fileref)))
            (should (and he (string-prefix-p "fileref:" he)))
            (should (and he (string-suffix-p ":43:4" he)))))) ; col preserved
      ;; Path embedded in punctuation (Python traceback style) must match
      (with-temp-buffer
        (insert (format "  at foo (%s:10:5)\n" test-file))
        (let ((ghostel-enable-url-detection t))
          (ghostel--detect-urls))
        (let ((he (find-fileref)))
          (should (and he (string-prefix-p "fileref:" he)))   ; paren-wrapped path matched
          (should (and he (string-suffix-p ":10:5" he)))
          ;; Trailing `)' must NOT be absorbed into the path
          (should (and he (not (string-suffix-p ")" he))))))
      ;; Wrapper chars (backtick, paren, bracket, brace, quotes) around a
      ;; path-only reference must not bleed into the match.
      (dolist (wrap '(("`" . "`") ("(" . ")") ("[" . "]") ("{" . "}")
                      ("'" . "'") ("\"" . "\"")))
        (with-temp-buffer
          (insert (format "see %s%s%s here\n" (car wrap) test-file (cdr wrap)))
          (let ((ghostel-enable-url-detection t))
            (ghostel--detect-urls))
          (let ((he (find-fileref)))
            (should (and he (string-prefix-p "fileref:" he)))
            (should (and he (string-suffix-p test-file he)))    ; no wrapper tail
            (should (and he (not (string-suffix-p (cdr wrap) he)))))))
      ;; Tilde-prefixed paths are detected and linkified.
      (let* ((tilde-path "~/.emacs.d/init.el:42")
             (tilde-file (expand-file-name ".emacs.d/init.el" (expand-file-name "~"))))
        ;; Existing tilde path is linkified.
        (with-temp-buffer
          (insert (format "Error at %s bad\n" tilde-path))
          (cl-letf (((symbol-function 'file-exists-p)
                     (lambda (f) (equal f tilde-file))))
            (let ((ghostel-enable-url-detection t))
              (ghostel--detect-urls))
            (let ((he (find-fileref)))
              (should (and he (string-prefix-p "fileref:" he)))
              (should (and he (string-suffix-p ":42" he)))))))
      ;; Bare filename without a slash must NOT match (avoids FS stat storms)
      (with-temp-buffer
        (setq default-directory (file-name-directory test-file))
        (insert "main.go:12:5: undefined: foo\n")
        (let ((ghostel-enable-url-detection t))
          (ghostel--detect-urls))
        (should (null (find-fileref))))            ; bare filename skipped
      ;; TRAMP `default-directory' is safe because scanning is pattern-only.
      (with-temp-buffer
        (setq default-directory "/ssh:example.com:/tmp/")
        (insert (format "see %s here\n" test-file))
        (let ((ghostel-enable-url-detection t))
          (ghostel--detect-urls))
        (should (equal (concat "fileref:" test-file)
                       (find-fileref))))
      ;; Custom path regex can opt into broader matching (bare filenames)
      (with-temp-buffer
        (setq default-directory (file-name-directory test-file))
        (insert "ghostel.el:42 here\n")
        (let ((ghostel-enable-url-detection t)
              (ghostel-file-detection-path-regex
               "[[:alnum:]_.][^ \t\n\r:\"<>]*"))
          (ghostel--detect-urls))
        (should (find-fileref)))                   ; custom path regex opts in
      ;; Path-only reference (no `:line' suffix): /absolute and ./relative
      ;; both linkify when the file exists.
      (with-temp-buffer
        (insert (format "see %s here\n" test-file))
        (let ((ghostel-enable-url-detection t))
          (ghostel--detect-urls))
        (let ((he (find-fileref)))
          (should (and he (string-prefix-p "fileref:" he)))
          (should (and he (not (string-match-p ":[0-9]+\\'" he)))))) ; no line
      ;; Pattern-only path references are linkified without stat'ing them.
      (with-temp-buffer
        (insert "see /no/such/path/exists here\n")
        (let ((ghostel-enable-url-detection t))
          (ghostel--detect-urls))
        (should (equal (concat "fileref:"
                               (expand-file-name "/no/such/path/exists"))
                       (find-fileref))))
      ;; ghostel--open-link with :line:col positions the cursor
      (let ((opened nil) (col-arg nil))
        (cl-letf (((symbol-function 'find-file-other-window)
                   (lambda (f) (setq opened f)))
                  ((symbol-function 'move-to-column)
                   (lambda (c &optional _force) (setq col-arg c))))
          (ghostel--open-link (format "fileref:%s:10:7" test-file)))
        (should (equal test-file opened))
        (should (equal 6 col-arg)))                  ; :col 7 → column 6 (0-indexed)
      ;; ghostel--open-link with path-only fileref opens the file without
      ;; moving point past `point-min'.
      (let ((opened nil) (moved nil))
        (cl-letf (((symbol-function 'find-file-other-window)
                   (lambda (f) (setq opened f)))
                  ((symbol-function 'forward-line)
                   (lambda (&rest _) (setq moved t))))
          (ghostel--open-link (format "fileref:%s" test-file)))
        (should (equal test-file opened))
        (should (null moved)))))))                   ; no line → no forward-line

(ert-deftest ghostel-test-detect-urls-skips-active-input ()
  "Link detection rules around prompts and user input (issue #199).
- `ghostel-prompt' (shell-generated decoration): never linkified.
- The cursor's line (active typing): not linkified — in tty Emacs RET
  on a linkified cell hijacks the keystroke, and the cursor-row skip
  works for both OSC 133 shells and markerless REPLs (Gemini CLI etc).
- Other lines (historical typed commands, output): linkified, so users
  can follow paths in past commands and program output."
  :tags '(native)
  (let ((test-file (locate-library "ghostel")))
    ;; History line → both file ref and URL linkified.  Active line
    ;; (cursor's line) → both skipped, regardless of whether the cells
    ;; carry `ghostel-input' or not.
    (with-temp-buffer
      (let ((default-directory (file-name-directory test-file)))
        (insert (format "$ ls %s https://hist.example\n" test-file)) ; line 1: history
        (insert (format "$ cat %s https://live.example" test-file))  ; line 2: active
        (put-text-property (point-min) (point-max) 'ghostel-input t)
        (goto-char (point-max))                                       ; cursor on line 2
        (let ((ghostel-enable-url-detection t)
              (ghostel-enable-file-detection t))
          (ghostel--detect-urls))
        (goto-char (point-min))
        (search-forward test-file nil t)
        (let ((he (get-text-property (match-beginning 0) 'help-echo)))
          (should (and he (string-prefix-p "fileref:" he)))) ; history file → linked
        (search-forward "https://hist.example")
        (should (equal "https://hist.example"
                       (get-text-property (match-beginning 0) 'help-echo))) ; history URL → linked
        (search-forward test-file nil t)
        (should (null (get-text-property (match-beginning 0) 'help-echo))) ; active file → skipped
        (search-forward "https://live.example")
        (should (null (get-text-property (match-beginning 0) 'help-echo))))) ; active URL → skipped
    ;; Cursor-row skip is unconditional: a URL on the cursor's line is
    ;; not linkified even when no `ghostel-input' marker covers it.  This
    ;; is what protects RET in REPLs like Gemini CLI or raw shells that
    ;; emit no OSC 133 sequences.  No trailing newline — cursor stays on
    ;; the typed line.
    (with-temp-buffer
      (insert "out https://before.example mid https://typed.example tail")
      (goto-char (point-max))                                           ; cursor on line 1
      (let ((ghostel-enable-url-detection t)
            (ghostel-enable-file-detection nil))
        (ghostel--detect-urls))
      (goto-char (point-min))
      (search-forward "https://before.example")
      (should (null (get-text-property (match-beginning 0) 'help-echo))) ; cursor row → skipped
      (search-forward "https://typed.example")
      (should (null (get-text-property (match-beginning 0) 'help-echo)))) ; cursor row → skipped
    ;; No OSC 133 markers at all (e.g. Gemini CLI prompt or a raw shell):
    ;; output on previous lines is still linkified, only the cursor row
    ;; is protected.
    (with-temp-buffer
      (insert "history https://past.example\n") ; line 1: previous output
      (insert "> https://typed.example tail")   ; line 2: REPL prompt with cursor
      (goto-char (point-max))                   ; cursor on line 2
      (let ((ghostel-enable-url-detection t)
            (ghostel-enable-file-detection nil))
        (ghostel--detect-urls))
      (goto-char (point-min))
      (search-forward "https://past.example")
      (should (equal "https://past.example"
                     (get-text-property (match-beginning 0) 'help-echo))) ; history → linked
      (search-forward "https://typed.example")
      (should (null (get-text-property (match-beginning 0) 'help-echo)))) ; cursor row → skipped
    ;; `ghostel-prompt' (prompt prefix) is never linkified — neither on
    ;; the active line nor in scrollback.  Path appears in the prompt's
    ;; cwd display; output below is plain text and stays linkifiable.
    (with-temp-buffer
      (let ((default-directory (file-name-directory test-file)))
        (insert (format "%s λ ls\n" test-file))           ; line 1: prompt prefix
        (insert (format "%s\n" test-file))                ; line 2: output
        (insert (format "%s λ " test-file))               ; line 3: live prompt
        ;; Prompt rows carry `ghostel-prompt' on the prefix; output does not.
        (save-excursion
          (goto-char (point-min))
          (let ((eol (line-end-position)))
            (put-text-property (point-min) eol 'ghostel-prompt t))
          (forward-line 2)
          (put-text-property (point) (point-max) 'ghostel-prompt t))
        (goto-char (point-max))
        (let ((ghostel-enable-url-detection nil)
              (ghostel-enable-file-detection t))
          (ghostel--detect-urls))
        (goto-char (point-min))
        (search-forward test-file nil t)                  ; line 1: prompt prefix
        (should (null (get-text-property (match-beginning 0) 'help-echo)))
        (search-forward test-file nil t)                  ; line 2: output
        (should (get-text-property (match-beginning 0) 'help-echo))
        (search-forward test-file nil t)                  ; line 3: live prompt prefix
        (should (null (get-text-property (match-beginning 0) 'help-echo)))))))

(ert-deftest ghostel-test-delayed-redraw-defers-plain-link-detection ()
  "Redraw-triggered plain-text link detection should run after redraw."
  (let ((buf (generate-new-buffer " *ghostel-test-delayed-link*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--term t)
                (ghostel-enable-url-detection t)
                (ghostel-enable-file-detection nil)
                (scheduled-count 0)
                timer-delay timer-repeat timer-fn timer-args)
            ;; FIXME: `ghostel--redraw' is stubbed because `ghostel--term'
            ;; here is the placeholder symbol `t', not a real native handle,
            ;; so the real renderer would crash.  The test still observes the
            ;; intended side effect (link-detection timer scheduling) via the
            ;; `run-with-timer' mock below.  A cleaner rewrite would require
            ;; spinning up a real terminal fixture.
            (cl-letf (((symbol-function 'run-with-timer)
                       (lambda (delay repeat fn &rest args)
                         (setq scheduled-count (1+ scheduled-count)
                               timer-delay delay
                               timer-repeat repeat
                               timer-fn fn
                               timer-args args)
                         'ghostel-test-link-timer))
                      ((symbol-function 'ghostel--flush-pending-output) #'ignore)
                      ((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--correct-mangled-scroll-positions)
                       #'ignore)
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--viewport-start)
                       (lambda () nil))
                      ((symbol-function 'get-buffer-window-list)
                       (lambda (&rest _) nil)))
              (let ((inhibit-read-only t))
                (insert "see https://example.com here\n"))
              (ghostel--delayed-redraw buf)
              (goto-char (point-min))
              (let* ((url "https://example.com")
                     (url-end (search-forward url nil t))
                     (url-beg (- url-end (length url))))
                (should url-end)
                (should (null (get-text-property url-beg 'help-echo)))
                (should (= scheduled-count 1))
                (should (numberp timer-delay))
                (should (> timer-delay 0))
                (should (null timer-repeat))
                (should timer-fn)
                ;; Move point off the URL line so the cursor-row skip in
                ;; `ghostel--detect-urls' doesn't mask the URL when the
                ;; queued detection runs.
                (goto-char (point-max))
                (apply timer-fn timer-args)
                (should (equal url
                               (get-text-property url-beg 'help-echo)))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-delayed-redraw-coalesces-plain-link-detection ()
  "Multiple redraws before the timer fires should share one detection pass."
  (let ((buf (generate-new-buffer " *ghostel-test-coalesced-link*")))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((ghostel--term t)
                (ghostel-enable-url-detection t)
                (ghostel-enable-file-detection nil)
                (scheduled-count 0)
                timer-repeat timer-fn timer-args)
            (cl-letf (((symbol-function 'run-with-timer)
                       (lambda (_delay repeat fn &rest args)
                         (setq scheduled-count (1+ scheduled-count)
                               timer-repeat repeat
                               timer-fn fn
                               timer-args args)
                         'ghostel-test-link-timer))
                      ((symbol-function 'ghostel--flush-pending-output) #'ignore)
                      ((symbol-function 'ghostel--mode-enabled)
                       (lambda (&rest _) nil))
                      ((symbol-function 'ghostel--correct-mangled-scroll-positions)
                       #'ignore)
                      ((symbol-function 'ghostel--redraw) #'ignore)
                      ((symbol-function 'ghostel--viewport-start)
                       (lambda () nil))
                      ((symbol-function 'get-buffer-window-list)
                       (lambda (&rest _) nil)))
              (let ((inhibit-read-only t))
                (insert "first https://first.example\n"))
              (ghostel--delayed-redraw buf)
              (let ((inhibit-read-only t))
                (goto-char (point-max))
                (insert "second https://second.example\n"))
              (ghostel--delayed-redraw buf)
              (goto-char (point-min))
              (let* ((first-url "https://first.example")
                     (first-end (search-forward first-url nil t))
                     (first-beg (- first-end (length first-url)))
                     (second-url "https://second.example")
                     (second-end (search-forward second-url nil t))
                     (second-beg (- second-end (length second-url))))
                (should first-end)
                (should second-end)
                (should (null (get-text-property first-beg 'help-echo)))
                (should (null (get-text-property second-beg 'help-echo)))
                (should (= scheduled-count 1))
                (should (null timer-repeat))
                (should timer-fn)
                ;; Move point off the URL lines so the cursor-row skip in
                ;; `ghostel--detect-urls' doesn't mask either URL when the
                ;; queued detection runs.
                (goto-char (point-max))
                (apply timer-fn timer-args)
                (should (equal first-url
                               (get-text-property first-beg 'help-echo)))
                (should (equal second-url
                               (get-text-property second-beg 'help-echo)))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-detect-urls-allows-read-only-buffers ()
  "Plain-text link detection should still work in read-only buffers."
  (let* ((root (ghostel--resource-root))
         (test-file (file-relative-name
                     (expand-file-name "lisp/ghostel.el" root)
                     root)))
    (with-temp-buffer
      (let ((default-directory root))
        (insert (format "see %s:1 for details\n" test-file))
        (setq buffer-read-only t)
        (let ((ghostel-enable-url-detection nil)
              (ghostel-enable-file-detection t))
          (should (eq 'ok
                      (ignore-errors
                        (ghostel--detect-urls)
                        'ok)))
          (should (string-prefix-p
                   "fileref:"
                   (get-text-property 5 'help-echo))))))))

(ert-deftest ghostel-test-zero-delay-runs-plain-link-detection-synchronously ()
  "With delay set to 0, plain-link detection runs without scheduling a timer."
  (let ((buf (generate-new-buffer " *ghostel-test-zero-delay-link*")))
    (unwind-protect
        (with-current-buffer buf
          (let ((ghostel-enable-url-detection t)
                (ghostel-enable-file-detection nil)
                (ghostel-plain-link-detection-delay 0)
                (timer-scheduled nil)
                (inhibit-read-only t))
            (cl-letf (((symbol-function 'run-with-timer)
                       (lambda (&rest _)
                         (setq timer-scheduled t)
                         'ghostel-test-zero-delay-timer)))
              (insert "see https://example.com here\n")
              (ghostel--queue-plain-link-detection (point-min) (point-max))
              (should-not timer-scheduled)
              (should-not ghostel--plain-link-detection-timer)
              (goto-char (point-min))
              (let* ((url "https://example.com")
                     (url-end (search-forward url nil t))
                     (url-beg (- url-end (length url))))
                (should url-end)
                (should (equal url
                               (get-text-property url-beg 'help-echo)))))))
      (kill-buffer buf))))

(ert-deftest ghostel-test-sentinel-cancels-plain-link-detection-timer ()
  "Process exit should cancel queued plain-text link detection timers."
  (let ((buf (generate-new-buffer " *ghostel-test-sentinel-links*")))
    (unwind-protect
        (let ((proc (make-pipe-process :name "ghostel-test-sentinel-links"
                                       :buffer buf
                                       :noquery t)))
          (with-current-buffer buf
            (setq ghostel-kill-buffer-on-exit nil
                  ghostel--plain-link-detection-timer
                  (run-with-timer 60 nil #'ignore))
            (ghostel--sentinel proc "finished\n")
            (should-not ghostel--plain-link-detection-timer))
          (when (process-live-p proc)
            (delete-process proc)))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (when ghostel--plain-link-detection-timer
            (cancel-timer ghostel--plain-link-detection-timer)))
        (kill-buffer buf)))))

(ert-deftest ghostel-test-hyperlink-navigation ()
  "Test `ghostel-next-hyperlink' / `ghostel-previous-hyperlink' search."
  :tags '(native)
  ;; Buffer layout (1-indexed positions):
  ;;   "AAA [LINK1] BBB [LINK2] CCC"
  ;;    123 4      5 6 7      8 9...
  (cl-flet ((setup ()
              (let ((buf (generate-new-buffer " *hyperlink-nav-test*")))
                (with-current-buffer buf
                  (insert "AAA ")                    ; 1..4
                  (let ((l1 (point)))                ; 5
                    (insert "LINK1")                 ; 5..9
                    (put-text-property l1 (point) 'help-echo "https://one"))
                  (insert " BBB ")                   ; 10..14
                  (let ((l2 (point)))                ; 15
                    (insert "LINK2")                 ; 15..19
                    (put-text-property l2 (point) 'help-echo "https://two"))
                  (insert " CCC"))                   ; 20..23
                buf)))
    ;; Forward from before any link lands on first link.
    (let ((buf (setup)))
      (unwind-protect
          (with-current-buffer buf
            (should (equal 5 (ghostel--find-next-link (point-min))))
            (should (equal 5 (ghostel--find-next-link 2)))
            ;; From inside link1, skip to link2.
            (should (equal 15 (ghostel--find-next-link 5)))
            (should (equal 15 (ghostel--find-next-link 7)))
            ;; From inside link2, nothing after.
            (should (null (ghostel--find-next-link 15)))
            (should (null (ghostel--find-next-link 17)))
            (should (null (ghostel--find-next-link (point-max)))))
        (kill-buffer buf)))
    ;; Backward.
    (let ((buf (setup)))
      (unwind-protect
          (with-current-buffer buf
            (should (equal 15 (ghostel--find-previous-link (point-max))))
            (should (equal 15 (ghostel--find-previous-link 22)))
            ;; From inside link2, find link1.
            (should (equal 5 (ghostel--find-previous-link 15)))
            (should (equal 5 (ghostel--find-previous-link 17)))
            ;; From inside link1, nothing before.
            (should (null (ghostel--find-previous-link 5)))
            (should (null (ghostel--find-previous-link 7)))
            (should (null (ghostel--find-previous-link (point-min)))))
        (kill-buffer buf)))
    ;; Empty buffer: no links at all.
    (with-temp-buffer
      (should (null (ghostel--find-next-link (point-min))))
      (should (null (ghostel--find-previous-link (point-max)))))
    ;; Buffer with no links but some text.
    (with-temp-buffer
      (insert "just some text with no links")
      (should (null (ghostel--find-next-link (point-min))))
      (should (null (ghostel--find-previous-link (point-max)))))
    ;; Commands are interactive.
    (should (commandp #'ghostel-next-hyperlink))
    (should (commandp #'ghostel-previous-hyperlink))))

(ert-deftest ghostel-test-hyperlink-navigation-wrap ()
  "Test that `ghostel--goto-hyperlink' wraps and errors cleanly."
  :tags '(native)
  ;; Wrap: from past the last link, next jumps back to first.
  (with-temp-buffer
    (insert "AAA LINK1 BBB LINK2 CCC")
    (put-text-property 5 10 'help-echo "https://one")
    (put-text-property 15 20 'help-echo "https://two")
    (goto-char (point-max))
    ;; No link after point — wraps to link1.
    (let ((inhibit-message t))
      (ghostel--goto-hyperlink 'next))
    (should (equal 5 (point)))
    ;; At point-min, going backward wraps to the last link.
    (goto-char (point-min))
    (let ((inhibit-message t))
      (ghostel--goto-hyperlink 'previous))
    (should (equal 15 (point))))
  ;; No links at all → user-error.
  (with-temp-buffer
    (insert "no links here at all")
    (should-error (ghostel--goto-hyperlink 'next) :type 'user-error)
    (should-error (ghostel--goto-hyperlink 'previous) :type 'user-error)))

(ert-deftest ghostel-test-sync-theme ()
  "Test that ghostel-sync-theme reapplies palette and redraw post-processing."
  (let ((palette-calls nil)
        (redraw-calls nil)
        (post-process-calls 0))
    (cl-letf (((symbol-function 'ghostel--apply-palette)
               (lambda (term) (push term palette-calls)))
              ((symbol-function 'ghostel--redraw)
               (lambda (term _) (push term redraw-calls)))
              ((symbol-function 'ghostel--schedule-link-detection)
               (lambda (&rest _args)
                 (setq post-process-calls (1+ post-process-calls)))))
      (let ((buf (generate-new-buffer " *ghostel-test-theme*"))
            (other (generate-new-buffer " *ghostel-test-other*")))
        (unwind-protect
            (cl-letf (((symbol-function 'buffer-list)
                       (lambda (&rest _) (list buf other))))
              ;; Set up a ghostel-mode buffer with a fake terminal.
              (with-current-buffer buf
                (ghostel-mode)
                (setq ghostel--term 'fake-term)
                (setq ghostel--input-mode 'semi-char)
                (setq ghostel-enable-url-detection t))
              (set-window-buffer (selected-window) buf)
              ;; `other' is not a ghostel buffer and should be ignored.
              (ghostel-sync-theme)
              (should (memq 'fake-term palette-calls))
              (should (memq 'fake-term redraw-calls))
              (should (= post-process-calls 1))

              ;; Verify copy mode (frozen) skips redraw
              (setq palette-calls nil
                    redraw-calls nil
                    post-process-calls 0)
              (with-current-buffer buf
                (setq ghostel--input-mode 'copy))
              (ghostel-sync-theme)
              (should (memq 'fake-term palette-calls))    ; palette still applied in copy mode
              (should-not (memq 'fake-term redraw-calls)) ; redraw skipped in copy mode
              (should (= post-process-calls 0))

              ;; Verify emacs mode (unfrozen) still redraws
              (setq palette-calls nil
                    redraw-calls nil
                    post-process-calls 0)
              (with-current-buffer buf
                (setq ghostel--input-mode 'emacs))
              (ghostel-sync-theme)
              (should (memq 'fake-term palette-calls))
              (should (memq 'fake-term redraw-calls))     ; redraw runs in emacs mode
              (should (= post-process-calls 1)))
          (kill-buffer buf)
          (kill-buffer other))))))

(ert-deftest ghostel-test-apply-palette-default-colors ()
  "Test that ghostel--apply-palette sets default fg/bg from the Emacs default face."
  (let ((default-colors-calls nil)
        (palette-calls nil))
    (cl-letf (((symbol-function 'ghostel--set-default-colors)
               (lambda (term fg bg)
                 (push (list term fg bg) default-colors-calls)))
              ((symbol-function 'ghostel--set-palette)
               (lambda (term colors) (push (list term colors) palette-calls))))
      ;; With a fake terminal, apply-palette should call set-default-colors
      (ghostel--apply-palette 'fake-term)
      (should (= 1 (length default-colors-calls)))
      (should (eq 'fake-term (car (car default-colors-calls))))
      ;; fg and bg should be hex color strings from the default face
      (let ((fg (nth 1 (car default-colors-calls)))
            (bg (nth 2 (car default-colors-calls))))
        (should (string-prefix-p "#" fg))
        (should (string-prefix-p "#" bg)))
      ;; Palette should also be set
      (should (= 1 (length palette-calls)))
      ;; With nil term, nothing should be called
      (setq default-colors-calls nil palette-calls nil)
      (ghostel--apply-palette nil)
      (should-not default-colors-calls)
      (should-not palette-calls))))

(ert-deftest ghostel-test-apply-palette-ghostel-default-face ()
  "`ghostel--apply-palette' reads default fg/bg from `ghostel-default', not `default'."
  (let ((looked-up nil)
        (default-colors-calls nil))
    (cl-letf (((symbol-function 'ghostel--set-default-colors)
               (lambda (term fg bg)
                 (push (list term fg bg) default-colors-calls)))
              ((symbol-function 'ghostel--set-palette) #'ignore)
              ((symbol-function 'ghostel--face-hex-color)
               (lambda (face _attr)
                 (push face looked-up)
                 "#abcdef")))
      (ghostel--apply-palette 'fake-term)
      ;; The two default-color lookups must target `ghostel-default',
      ;; never `default' directly — otherwise buffer-local customization
      ;; of the terminal's fg/bg is impossible (issue #178).
      (should (memq 'ghostel-default looked-up))
      (should-not (memq 'default looked-up))
      ;; The mocked color must reach `ghostel--set-default-colors',
      ;; proving the function used the lookup result rather than a
      ;; hardcoded value.
      (should (= 1 (length default-colors-calls)))
      (should (equal (list 'fake-term "#abcdef" "#abcdef")
                     (car default-colors-calls))))))



(ert-deftest ghostel-test-title-callback-renames-buffer ()
  "Test OSC 2 title change renames the current Ghostel buffer."
  :tags '(native)
  (let ((buf (generate-new-buffer " *ghostel-test-title*"))
        (title (format "Native Callback %s" (gensym))))
    (unwind-protect
        (with-current-buffer buf
          (ghostel-mode)
          (let ((term (ghostel--new 25 80 1000)))
            (setq-local ghostel--term term)
            (ghostel--write-input term (format "\e]2;%s\e\\" title))
            (should (equal title (ghostel--get-title term)))
            (should (equal (format "*ghostel: %s*" title) (buffer-name)))
            (should (equal (buffer-name) ghostel--managed-buffer-name))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest ghostel-test-file-detection-is-pattern-only ()
  "Plain file detection should not stat matching paths during redraw."
  (skip-unless (not (eq system-type 'windows-nt)))
  (with-temp-buffer
    (insert "see /tmp/ghostel-missing-file.txt:12 for details\n")
    (let ((ghostel-enable-url-detection nil)
          (ghostel-enable-file-detection t)
          (file-exists-called nil))
      (cl-letf (((symbol-function 'file-exists-p)
                 (lambda (&rest _args)
                   (setq file-exists-called t)
                   nil)))
        (ghostel--detect-plain-links))
      (should-not file-exists-called)
      (goto-char (point-min))
      (search-forward "/tmp/ghostel-missing-file.txt")
      (should (string-prefix-p "fileref:"
                               (get-text-property (match-beginning 0)
                                                  'help-echo))))))

(ert-deftest ghostel-test-plain-link-detection-allows-read-only-buffers ()
  "Deferred plain link detection can annotate read-only Ghostel buffers."
  (with-temp-buffer
    (let ((inhibit-read-only t))
      (insert "see https://example.com for details\n"))
    (setq buffer-read-only t)
    (let ((ghostel-enable-url-detection t)
          (ghostel-enable-file-detection nil))
      (ghostel--detect-plain-links (point-min) (point-max)))
    (goto-char (point-min))
    (search-forward "https://example.com")
    (should (equal "https://example.com"
                   (get-text-property (match-beginning 0) 'help-echo)))))

(ert-deftest ghostel-test-queue-link-detection-coalesces-redraw-work ()
  "Redraw-triggered link detection should be deferred and coalesced."
  (with-temp-buffer
    (let ((ghostel-plain-link-detection-delay 0.25)
          (scheduled-count 0)
          timer-delay timer-repeat timer-fn timer-args
          detect-calls)
      (cl-letf (((symbol-function 'run-with-timer)
                 (lambda (delay repeat fn &rest args)
                   (setq scheduled-count (1+ scheduled-count)
                         timer-delay delay
                         timer-repeat repeat
                         timer-fn fn
                         timer-args args)
                   'ghostel-test-link-timer))
                ((symbol-function 'ghostel--detect-plain-links)
                 (lambda (begin end)
                   (push (list begin end) detect-calls))))
        (ghostel--queue-plain-link-detection 10 20)
        (ghostel--queue-plain-link-detection 5 25)
        (should (= scheduled-count 1))
        (should (= timer-delay 0.25))
        (should (null timer-repeat))
        (should (eq ghostel--plain-link-detection-timer 'ghostel-test-link-timer))
        (should (= ghostel--plain-link-detection-begin 5))
        (should (= ghostel--plain-link-detection-end 25))
        (apply timer-fn timer-args)
        (should (equal '((5 25)) detect-calls))
        (should (null ghostel--plain-link-detection-timer))
        (should (null ghostel--plain-link-detection-begin))
        (should (null ghostel--plain-link-detection-end))))))

(ert-deftest ghostel-test-url-detection-respects-bounds ()
  "Test that URL detection can be restricted to a region."
  (with-temp-buffer
    (insert "before https://before.example\n"
            "middle https://middle.example\n"
            "after https://after.example")
    (let ((ghostel-enable-url-detection t))
      (save-excursion
        (goto-char (point-min))
        (forward-line 1)
        (let ((begin (line-beginning-position))
              (end (line-end-position)))
          (goto-char (point-max))
          (ghostel--detect-plain-links begin end))))
    (should-not (get-text-property 8 'help-echo))
    (save-excursion
      (goto-char (point-min))
      (forward-line 1)
      (should (equal "https://middle.example"
                     (get-text-property (+ (line-beginning-position) 8) 'help-echo))))
    (save-excursion
      (goto-char (point-min))
      (forward-line 2)
      (should-not (get-text-property (+ (line-beginning-position) 7) 'help-echo)))))

(ert-deftest ghostel-test-set-buffer-face-skips-unchanged-colors ()
  "Test that repeated identical default colors do not remap again."
  (with-temp-buffer
    (let ((ghostel--face-cookie nil)
          (added 0)
          (removed 0))
      (cl-letf (((symbol-function 'face-remap-add-relative)
                 (lambda (&rest _)
                   (setq added (1+ added))
                   'cookie))
                ((symbol-function 'face-remap-remove-relative)
                 (lambda (&rest _)
                   (setq removed (1+ removed)))))
        (ghostel--set-buffer-face "#112233" "#445566")
        (ghostel--set-buffer-face "#112233" "#445566")
        (should (= added 1))
        (should (= removed 0))))))

(ert-deftest ghostel-test-immediate-redraw-cancels-link-detection ()
  "Immediate redraw should cancel any pending deferred link detection."
  (with-temp-buffer
    (let ((buf (current-buffer))
          (ghostel--term 'fake)
          (ghostel--pending-output nil)
          (ghostel--redraw-timer nil)
          (ghostel--plain-link-detection-timer 'pending-link-timer)
          (ghostel--plain-link-detection-begin 10)
          (ghostel--plain-link-detection-end 20)
          (ghostel--last-send-time nil)
          (ghostel-immediate-redraw-threshold 256)
          (ghostel-immediate-redraw-interval 0.05)
          (cancelled nil)
          (immediate-called nil))
      (let ((comp-enable-subr-trampolines nil)
            (native-comp-enable-subr-trampolines nil))
        (cl-letf (((symbol-function 'process-buffer) (lambda (_) buf))
                  ((symbol-function 'ghostel--delayed-redraw)
                   (lambda (_buf) (setq immediate-called t)))
                  ((symbol-function 'ghostel--invalidate) #'ignore)
                  ((symbol-function 'cancel-timer)
                   (lambda (timer) (push timer cancelled))))
          (setq ghostel--last-send-time (current-time))
          (ghostel--filter 'fake-proc "a")
          (should immediate-called)
          (should (equal '(pending-link-timer) cancelled))
          (should (null ghostel--plain-link-detection-timer))
          (should (null ghostel--plain-link-detection-begin))
          (should (null ghostel--plain-link-detection-end)))))))

(ert-deftest ghostel-test-commit-cropped-size-on-focus ()
  "Focus return to a cropped ghostel window commits size and SIGWINCH."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--process 'fake-proc)
          (ghostel--term-rows 40)
          (ghostel--term-cols 120)
          (ghostel--force-next-redraw nil)
          (set-size-args nil)
          (swsize-args nil)
          (redraw-called nil))
      ;; Pass a real `(selected-window)' rather than a fake symbol so
      ;; `with-selected-window' works without stubbing implementation
      ;; internals (which differ across the supported Emacs versions).
      (cl-letf (((symbol-function 'ghostel--set-size)
                 (lambda (_term h w &rest _) (setq set-size-args (list h w))))
                ((symbol-function 'ghostel--delayed-redraw)
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
                ((symbol-function 'window-max-chars-per-line) (lambda (&rest _) 120))
                ((symbol-function 'minibuffer-depth) (lambda () 1)))
        (ghostel--commit-cropped-size (selected-window))
        (should (equal '(25 120) set-size-args))
        (should (equal '(25 120) swsize-args))
        (should (eql ghostel--term-rows 25))
        (should (eql ghostel--term-cols 120))
        (should ghostel--force-next-redraw)
        (should redraw-called)))))

(ert-deftest ghostel-test-commit-cropped-size-cancels-link-detection ()
  "Resize-triggered redraw should cancel pending deferred link detection."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--process 'fake-proc)
          (ghostel--term-rows 40)
          (ghostel--term-cols 120)
          (ghostel--plain-link-detection-timer 'pending-link-timer)
          (ghostel--plain-link-detection-begin 11)
          (ghostel--plain-link-detection-end 22)
          (cancelled nil)
          (redraw-called nil))
      (cl-letf (((symbol-function 'ghostel--set-size)
                 (lambda (&rest _) nil))
                ((symbol-function 'ghostel--delayed-redraw)
                  (lambda (_buf) (setq redraw-called t)))
                ((symbol-function 'process-live-p) (lambda (_p) t))
                ((symbol-function 'ghostel--process-set-window-size)
                  (lambda (&rest _) nil))
                ;; Regression guard for #192/#focus-resize: commit through the
                ;; real selected window and size by `window-screen-lines'.
                ((symbol-function 'window-body-height) (lambda (&rest _) 99))
                ((symbol-function 'window-screen-lines) (lambda () 25.0))
                ((symbol-function 'window-max-chars-per-line) (lambda (&rest _) 120))
                ((symbol-function 'minibuffer-depth) (lambda () 1))
                ((symbol-function 'cancel-timer)
                  (lambda (timer) (push timer cancelled))))
        (ghostel--commit-cropped-size (selected-window))
        (should redraw-called)
        (should (equal '(pending-link-timer) cancelled))
        (should (null ghostel--plain-link-detection-timer))
        (should (null ghostel--plain-link-detection-begin))
        (should (null ghostel--plain-link-detection-end))))))

(ert-deftest ghostel-test-commit-cropped-size-noop-outside-minibuffer ()
  "Focus change outside the minibuffer does not resize."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--process 'fake-proc)
          (ghostel--term-rows 40)
          (ghostel--term-cols 120)
          (set-size-called nil)
          (swsize-called nil))
      (cl-letf (((symbol-function 'ghostel--set-size)
                 (lambda (_term _h _w &rest _) (setq set-size-called t)))
                ((symbol-function 'ghostel--delayed-redraw) #'ignore)
                ((symbol-function 'ghostel--process-set-window-size)
                 (lambda (_p _h _w) (setq swsize-called t)))
                ((symbol-function 'minibuffer-depth) (lambda () 0)))
        (ghostel--commit-cropped-size 'test-win)
        (should-not set-size-called)
        (should-not swsize-called)))))

(ert-deftest ghostel-test-commit-cropped-size-noop-on-deselect ()
  "Hook firing on WINDOW deselection does not resize."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--process 'fake-proc)
          (ghostel--term-rows 40)
          (ghostel--term-cols 120)
          (set-size-called nil)
          (swsize-called nil))
      (cl-letf (((symbol-function 'ghostel--set-size)
                 (lambda (_term _h _w &rest _) (setq set-size-called t)))
                ((symbol-function 'ghostel--delayed-redraw) #'ignore)
                ((symbol-function 'process-live-p) (lambda (_p) t))
                ((symbol-function 'ghostel--process-set-window-size)
                 (lambda (_p _h _w) (setq swsize-called t)))
                ((symbol-function 'window-live-p) (lambda (_w) t))
                ((symbol-function 'window-frame) (lambda (_w) 'test-frame))
                ;; Selected window is *not* our window — we're being deselected.
                ((symbol-function 'frame-selected-window)
                 (lambda (_f) 'other-win))
                ((symbol-function 'minibuffer-depth) (lambda () 1)))
        (ghostel--commit-cropped-size 'test-win)
        (should-not set-size-called)
        (should-not swsize-called)))))

(ert-deftest ghostel-test-commit-cropped-size-noop-when-matched ()
  "If the window already matches the committed size, do nothing."
  (with-temp-buffer
    (let ((ghostel--term 'fake)
          (ghostel--process 'fake-proc)
          (ghostel--term-rows 40)
          (ghostel--term-cols 120)
          (set-size-called nil)
          (swsize-called nil))
      (cl-letf (((symbol-function 'ghostel--set-size)
                 (lambda (_term _h _w &rest _) (setq set-size-called t)))
                ((symbol-function 'ghostel--delayed-redraw) #'ignore)
                ((symbol-function 'process-live-p) (lambda (_p) t))
                ((symbol-function 'ghostel--process-set-window-size)
                 (lambda (_p _h _w) (setq swsize-called t)))
                ((symbol-function 'window-screen-lines) (lambda () 40.0))
                ((symbol-function 'window-max-chars-per-line) (lambda (&rest _) 120))
                ((symbol-function 'minibuffer-depth) (lambda () 1)))
        (ghostel--commit-cropped-size (selected-window))
        (should-not set-size-called)
        (should-not swsize-called)))))

(provide 'ghostel-render-test)
;;; ghostel-render-test.el ends here
