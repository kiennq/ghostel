EMACS ?= emacs

XDG_CACHE_HOME ?= $(HOME)/.cache
MELPAZOID_DIR  ?= $(XDG_CACHE_HOME)/melpazoid

.PHONY: all build check test lint melpazoid byte-compile bench bench-quick clean

all: build test lint

build:
	./build.sh

check:
	zig build check

test:
	$(EMACS) --batch -Q -L . -l ert -l test/ghostel-test.el -f ghostel-test-run-elisp

lint: byte-compile package-lint checkdoc

package-lint:
	$(EMACS) --batch -Q \
		--eval "(package-initialize)" \
		--eval "(require 'package-lint)" \
		-f package-lint-batch-and-exit \
		ghostel.el

checkdoc:
	$(EMACS) --batch -Q \
		--eval "(require 'checkdoc)" \
		--eval "(let ((sentence-end-double-space nil) \
		              (checkdoc-proper-noun-list nil) \
		              (checkdoc-verb-check-experimental-flag nil) \
		              (ok t)) \
		  (dolist (f '(\"ghostel.el\" \"ghostel-debug.el\")) \
		    (ignore-errors (kill-buffer \"*Warnings*\")) \
		    (let ((inhibit-message t)) \
		      (checkdoc-file f)) \
		    (when (get-buffer \"*Warnings*\") \
		      (setq ok nil) \
		      (with-current-buffer \"*Warnings*\" \
		        (message \"%s\" (buffer-string))))) \
		  (unless ok (kill-emacs 1)))"

melpazoid:
	@if [ ! -d "$(MELPAZOID_DIR)" ]; then \
		git clone https://github.com/riscy/melpazoid.git "$(MELPAZOID_DIR)"; \
	fi
	RECIPE='(ghostel :fetcher github :repo "dakra/ghostel")' \
		LOCAL_REPO=$(CURDIR) \
		make -C "$(MELPAZOID_DIR)"

byte-compile:
	$(EMACS) --batch -Q -L . --eval "(setq byte-compile-error-on-warn t)" -f batch-byte-compile ghostel.el ghostel-debug.el

bench:
	bash bench/run-bench.sh

bench-quick:
	bash bench/run-bench.sh --quick

clean:
	rm -f ghostel-module.dylib ghostel-module.so
	rm -f ghostel.elc ghostel-debug.elc
	rm -rf zig-out .zig-cache
