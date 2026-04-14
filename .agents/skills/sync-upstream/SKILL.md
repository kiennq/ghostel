---
name: sync-upstream
description: Use when replaying or rebasing the Ghostel fork onto upstream/main, especially when upstream touched files also changed by the local workflow-cleanup, Zig build, Windows ConPTY, dynamic-loader, performance-tuning, or no-title commits.
---

# Sync Upstream

## Overview

Treat Ghostel as a small topic stack on top of `upstream/main`, not as a single merge blob. The fork carries substantial value — dyn-loader ABI, ConPTY runtime, readonly-safe rendering, performance tuning — that **must survive every resync**. A replay that silently drops fork content is worse than no replay at all.

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
4. **Resolve conflicts by starting from the old fork file** and merging upstream's new additions into it — not the other way around. The fork's content is the known-good behavior; upstream additions are the delta to integrate. Never default to "take HEAD" or "take ours" in a conflict block without verifying the fork side has no unique content.
5. If upstream already covers the intent of a fork commit, drop or shrink it. If only part of the commit still belongs, split it and keep each resulting commit clean.
6. Keep the replay moving; run spot checks only when they help resolve a conflict, and treat the final rewritten stack as the required validation point.
7. **After the full replay, diff every key file** (`module.zig`, `render.zig`, `ghostel.el`, `test/ghostel-test.el`) between the old fork tip and the new replay tip. Any fork-only additions that disappeared are regressions that must be restored before pushing.
8. Compare the old and new stacks with `git range-diff <old-base>..<old-head> <new-base>..<new-head>` and confirm both upstream changes and fork-only topics are still present.

## Validation Matrix

| Commit type | Required check |
| --- | --- |
| intermediate replayed commits | not required to build individually; supplementary changes from later topics are allowed |
| final rewritten stack | `zig build -Doptimize=ReleaseFast` and the full `ghostel-test-run-elisp` pass; `zig build test` if Zig sources changed |

Intermediate commits do not need to build individually. Supplementary changes (e.g. submodule added early, functions from later topics included as stubs) are acceptable as long as the final stack builds and passes tests.

## Conflict Rules That Matter In This Repo

- **Default to fork content in conflicts.** The fork's files contain the working runtime (dyn-loader ABI, ConPTY, performance, readonly rendering). When a conflict block has fork-only content on one side, that content must be preserved unless upstream explicitly obsoleted it. "Taking HEAD" in a conflict block that contains fork-only functions, export tables, or runtime helpers silently drops working behavior.
- **module.zig owns the dyn-loader ABI.** The fork replaces upstream's direct `env.bindFunction` registration with a loader export table (`ExportId` enum, export manifest array, loader dispatch switch). This is the entire point of the dyn-loader topic. Never resolve a module.zig conflict by keeping the upstream registration style.
- **render.zig owns readonly-safe rendering.** The fork wraps buffer mutations in `(let ((inhibit-read-only t)) ...)` and adds `ghostel-full-redraw` support. These are the readonly and scrollback-viewport features. Never drop them during a conflict.
- **ghostel.el owns ConPTY coalescing and runtime helpers.** The fork adds `ghostel--conpty-active-p`, `conpty--read-pending`, `ghostel--coalesce-*`, and the loader bootstrap chain. These are not optional — they are the Windows runtime.
- Workflow files: keep the fork's workflow removal intentionally, but do not delete new upstream workflow behavior unless the fork still means to remove it.
- Shared test files: keep newer upstream tests and helper changes, then reapply the fork delta. Old whole-file resolutions are how upstream-safe tests get regressed.
- Performance work stays in the performance commit unless upstream made it obsolete.
- ConPTY and dyn-loader changes stay functional as separate fork topics; do not smear their fallout into unrelated commits.
- Native module bootstrap and load paths must keep going through `ghostel--effective-module-dir`; do not reintroduce `locate-library` or package-root fallbacks in command-time startup.
- `ghostel.el` must keep the fork's one-column process width buffer (`window-max-chars-per-line - 1`) for terminal creation, startup, and resize so Emacs does not clip terminal text at the right edge.
- The no-title behavior stays owned by the final title-related fix, not by earlier replay noise.

## Common Mistakes

- **Starting from upstream and cherry-picking fork commits** — this inverts the conflict bias and silently drops fork content. Always merge upstream INTO the fork, or if replaying, start from the fork file and merge upstream additions into it.
- taking `--ours` or `--theirs` for an entire conflicted file without checking both sides
- defaulting to "take HEAD" in conflict blocks that contain fork-only functions, export tables, or runtime helpers
- fixing a replay mistake in a later commit instead of the commit that introduced it
- preserving the fork stack while accidentally removing new upstream code or tests
- treating intermediate replay breakage as a blocker when only the final rewritten stack must validate
- folding performance tuning into Windows support or dyn-loader commits
