---
name: sync-upstream
description: Use when replaying or rebasing the Ghostel fork onto upstream/main, especially when upstream touched files also changed by the local workflow-cleanup, Zig build, Windows ConPTY, dynamic-loader, performance-tuning, or no-title commits.
---

# Sync Upstream

## Overview

Treat Ghostel as a small topic stack on top of `upstream/main`, not as a single merge blob. Rebuild that stack on top of new upstream, make the currently replayed commit own its conflict resolution, and always start from the new upstream file shape so new upstream behavior is not dropped by accident.

## When to Use

- syncing `main` with `upstream/main`
- refreshing stacked PR branches after upstream moved
- resolving conflicts in files touched by both upstream and fork commits
- checking that fork-only logic survived a replay

## Fork Topics To Preserve Intentionally

1. remove extra workflows
2. build with Zig and the vendored Emacs header
3. decouple module downloads from package version
4. Windows ConPTY via `emacs-util-mods`
5. performance tuning
6. dynamic loader support
7. do not use terminal titles

Preserve those topics while also preserving new upstream behavior. Never solve a conflict by taking an old fork file wholesale.

## Update Workflow

1. Start from a clean throwaway branch or worktree based on `upstream/main`; keep the old branch untouched as the reference stack.
2. Inspect the old stack with `git log --oneline --reverse upstream/main..main`.
3. Replay the stack in topic order. If a commit mixes multiple topics, split it before or during replay.
4. The commit currently being replayed owns the conflict. Resolve by reading the new upstream file first, then reapplying only the minimal fork delta that still belongs to that commit.
5. If upstream already covers the intent, drop the commit or shrink it. If only part of the commit still belongs, split it and keep each resulting commit clean.
6. After every replayed commit, run the required checks for that commit class before moving on.
7. After the full replay, compare the old and new stacks with `git range-diff <old-base>..<old-head> <new-base>..<new-head>` and confirm both upstream changes and fork-only topics are still present.

## Validation Matrix

| Commit type | Required check |
| --- | --- |
| any replayed commit | run the smallest relevant tests before continuing |
| touches `*.zig`, `build.zig`, or `build.zig.zon` | `zig build -Doptimize=ReleaseFast` at that commit |
| changes runtime or test-sensitive Elisp | `emacs -Q --batch --eval "(setq load-prefer-newer t native-comp-jit-compilation nil native-comp-enable-subr-trampolines nil comp-enable-subr-trampolines nil)" -L . -l test/ghostel-test.el -f ghostel-test-run-elisp` or a focused ERT slice first |
| final rewritten stack | `zig build test` and the full `ghostel-test-run-elisp` pass |

If a Zig-touching commit does not build, stop and fix that commit before replaying anything else.

## Conflict Rules That Matter In This Repo

- Workflow files: keep the fork's workflow removal intentionally, but do not delete new upstream workflow behavior unless the fork still means to remove it.
- Shared test files: keep newer upstream tests and helper changes, then reapply the fork delta. Old whole-file resolutions are how upstream-safe tests get regressed.
- Performance work stays in the performance commit unless upstream made it obsolete.
- ConPTY and dyn-loader changes stay functional as separate fork topics; do not smear their fallout into unrelated commits.
- Native module bootstrap and load paths must keep going through `ghostel--effective-module-dir`; do not reintroduce `locate-library` or package-root fallbacks in command-time startup.
- `ghostel.el` must keep the fork's one-column process width buffer (`window-max-chars-per-line - 1`) for terminal creation, startup, and resize so Emacs does not clip terminal text at the right edge.
- The no-title behavior stays owned by the final title-related fix, not by earlier replay noise.

## Common Mistakes

- taking `--ours` or `--theirs` for an entire conflicted file
- fixing a replay mistake in a later commit instead of the commit that introduced it
- preserving the fork stack while accidentally removing new upstream code or tests
- leaving Zig-touching commits unbuildable in the middle of the replay
- folding performance tuning into Windows support or dyn-loader commits
