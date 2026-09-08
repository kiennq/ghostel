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

(ert-deftest ghostel-bench-test-pipeline-payloads-are-real-vt ()
  "Pipeline workloads generate concrete VT writes without GUI assumptions."
  (let ((population (ghostel-bench--gen-pipeline-populated 40 120))
        (workloads '("paired" "row-reemit" "cursor" "styled"
                     "full-frame" "mixed-unicode")))
    (should (string-prefix-p "\e[?1049h" population))
    (should (string-suffix-p "\e[20;41H" population))
    (dolist (workload workloads)
      (let* ((payloads (ghostel-bench--pipeline-payloads
                        workload 40 120))
             (first (car payloads))
             (second (cadr payloads)))
        (should (stringp first))
        (should (> (string-bytes first) 0))
        (if (string= workload "row-reemit")
            (should (= (length payloads) 1))
          (should (= (length payloads) 2))
          (should-not (equal first second)))))
    (should (string-match-p (regexp-quote "\e[20;41H")
                            (ghostel-bench--pipeline-payload
                             "paired" 40 120 0)))))

(ert-deftest ghostel-bench-test-pipeline-scrollback-payloads-are-primary-scroll ()
  "Scrollback uses primary-screen short ASCII CRLF appends."
  (let ((population (ghostel-bench--gen-pipeline-populated 40 120 t))
        (payloads (ghostel-bench--pipeline-scrollback-payloads 40 120)))
    (should-not (string-match-p (regexp-quote "\e[?1049h") population))
    (should (string-suffix-p "\e[40;1H" population))
    (should (= (length payloads) 2))
    (should-not (equal (car payloads) (cadr payloads)))
    (dolist (payload payloads)
      (should (string-match-p (regexp-quote "\e[40;1H") payload))
      (should (string-suffix-p "\r\n" payload))
      (should (< (string-bytes payload)
                 (+ (string-bytes "\e[40;1H") 120 2))))))

(ert-deftest ghostel-bench-test-run-one-dispatches-pipeline-case ()
  "`run-one' dispatches every named pipeline workload."
  (let ((dispatched nil)
        (cases '("paired" "row-reemit" "cursor" "styled"
                 "full-frame" "mixed-unicode" "scrollback")))
    (cl-letf (((symbol-function 'ghostel-bench--print-header) #'ignore)
              ((symbol-function 'ghostel-bench--run-one-pipeline)
               (lambda (workload size &optional primary-p)
                 (push (list workload size primary-p) dispatched))))
      (dolist (workload cases)
        (ghostel-bench-run-one
         (format "pipeline/%s/40x120" workload))))
    (should (equal (nreverse dispatched)
                   (mapcar (lambda (workload)
                             (list workload "40x120"
                                   (and (string= workload "scrollback") t)))
                           cases)))))

(ert-deftest ghostel-bench-test-pipeline-scrollback-uses-primary-setup ()
  "The scrollback runner populates primary screen and budgets enough rows."
  (let ((ghostel-bench-min-duration 0.25)
        (writes nil)
        (measure-duration nil)
        (measure-iterations nil))
    (cl-letf (((symbol-function 'require)
               (lambda (&rest _features) t))
              ((symbol-function 'ghostel-bench--with-pipeline-buffer)
               (lambda (_rows _cols body-fn)
                 (with-temp-buffer
                   (setq-local ghostel--term 'fake-term)
                   (funcall body-fn))))
              ((symbol-function 'ghostel--write-vt)
               (lambda (_term payload)
                 (push payload writes)))
              ((symbol-function 'ghostel--redraw-now) #'ignore)
              ((symbol-function 'ghostel-bench--measure)
               (lambda (_name _size iterations body-fn)
                 (setq measure-duration ghostel-bench-min-duration)
                 (setq measure-iterations iterations)
                 (dotimes (_ 2)
                   (funcall body-fn)))))
      (ghostel-bench--run-one-pipeline "scrollback" "40x120" t))
    (setq writes (nreverse writes))
    (should (zerop measure-duration))
    (should (= ghostel-bench-min-duration 0.25))
    (should (>= measure-iterations 48))
    (should (= (length writes) 3))
    (should-not (string-match-p (regexp-quote "\e[?1049h")
                                (car writes)))
    (should (string-match-p (regexp-quote "\e[40;1H")
                            (car writes)))
    (should (string-suffix-p "\r\n" (nth 1 writes)))
    (should (string-suffix-p "\r\n" (nth 2 writes)))))

(ert-deftest ghostel-bench-test-pipeline-body-selects-precomputed-payloads ()
  "The timed body selects changed encoded payloads without regenerating them."
  (let ((ghostel-bench-min-duration 0.25)
        (build-count 0)
        (measure-duration nil)
        (writes nil)
        (original (symbol-function 'ghostel-bench--pipeline-payloads)))
    (cl-letf (((symbol-function 'require)
               (lambda (&rest _features) t))
              ((symbol-function 'ghostel-bench--pipeline-payloads)
               (lambda (&rest args)
                 (cl-incf build-count)
                 (apply original args)))
              ((symbol-function 'ghostel-bench--with-pipeline-buffer)
               (lambda (_rows _cols body-fn)
                 (with-temp-buffer
                   (setq-local ghostel--term 'fake-term)
                   (funcall body-fn))))
              ((symbol-function 'ghostel--write-vt)
               (lambda (_term payload)
                 (push payload writes)))
              ((symbol-function 'ghostel--redraw-now) #'ignore)
              ((symbol-function 'ghostel-bench--measure)
               (lambda (_name _size _iterations body-fn)
                 (setq measure-duration ghostel-bench-min-duration)
                 (dotimes (_ 3)
                   (funcall body-fn)))))
      (ghostel-bench--run-one-pipeline "full-frame" "40x120"))
    (setq writes (nreverse writes))
    (should (= measure-duration 0.25))
    (should (= ghostel-bench-min-duration 0.25))
    (should (= build-count 1))
    (should (= (length writes) 4))
    (should-not (equal (nth 1 writes) (nth 2 writes)))
    (should (equal (nth 1 writes) (nth 3 writes)))))

;;; ghostel-bench-test.el ends here
