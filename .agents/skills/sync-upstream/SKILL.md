---
name: sync-upstream
description: Use when replaying or rebasing the Ghostel fork onto upstream/main, especially when upstream touched files also changed by the local workflow-cleanup, Zig build, Windows ConPTY, dynamic-loader, performance-tuning, or no-title commits.
---

# Sync Upstream

## Overview

Treat Ghostel as the commit stack that actually exists on `main`, not as an invented topic stack. The fork topics below are a semantic checklist for conflict resolution, but they do **not** require splitting commits when `main` intentionally keeps them squashed (for example, a workflow/skills commit plus one mega commit).

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

Preserve those topics while also preserving new upstream behavior. Use them to audit what must survive the sync, not to force extra commits that are not present on `main`.

## Update Workflow

1. Start from a clean throwaway branch or worktree based on `upstream/main`; keep the old branch untouched as the reference stack.
2. Inspect the old stack with `git log --oneline --reverse upstream/main..main`.
3. Replay the commits in that exact order and shape. If `main` has 2 commits, the new replay should also have 2 commits unless the user explicitly asks to rewrite history differently.
4. The commit currently being replayed owns the conflict. Resolve by reading the new upstream file first, then reapplying only the minimal fork delta that still belongs to that old commit. Never solve a conflict by taking an old fork file wholesale.
5. If upstream already covers an old commit completely, drop it. If only part of the old commit still belongs, keep the remainder in the same replayed commit when practical. Only split a commit when `main` already split it or the user explicitly asked for that rewrite.
6. After every replayed commit, run the required checks for that commit class before moving on.
7. After the full replay, diff the key files (`module.zig`, `render.zig`, `ghostel.el`, `test/ghostel-test.el`) between the old fork tip and the new replay tip. Any fork-only additions that disappeared are regressions that must be restored before pushing.
8. Compare the old and new stacks with `git range-diff <old-base>..<old-head> <new-base>..<new-head>` and confirm both the commit shape and the fork-only behavior still match `main` unless the user asked for a different history.

## Validation Matrix

| Commit type | Required check |
| --- | --- |
| intermediate replayed commits | not required to build individually; supplementary changes from later topics are allowed |
| final rewritten stack | `zig build -Doptimize=ReleaseFast`, byte-compile (`emacs --batch -f batch-byte-compile ghostel.el`), full `ghostel-test-run-elisp` pass, and native module `ghostel-test-run-native` pass; `zig build test` if Zig sources changed |

**ALWAYS run the full test suite after every rebase before pushing.** A rebase that introduces parse errors, duplicate test definitions, or mismatched parentheses from conflict resolution is worse than no rebase at all. At minimum:
1. Byte-compile `ghostel.el` — catches parse errors immediately.
2. Run `ghostel-test-run-elisp` — catches duplicate test names and pure Elisp regressions.
3. Run `ghostel-test-run-native` — catches native module integration regressions.

Intermediate commits do not need to build individually. Supplementary changes (e.g. submodule added early, functions from later topics included as stubs) are acceptable as long as the final stack builds and passes tests.

## Conflict Rules That Matter In This Repo

- **Default to fork content in conflicts.** The fork's files contain the working runtime (dyn-loader ABI, ConPTY, performance, readonly rendering). When a conflict block has fork-only content on one side, that content must be preserved unless upstream explicitly obsoleted it. "Taking HEAD" in a conflict block that contains fork-only functions, export tables, or runtime helpers silently drops working behavior.
- **module.zig owns the dyn-loader ABI.** The fork replaces upstream's direct `env.bindFunction` registration with a loader export table (`ExportId` enum, export manifest array, loader dispatch switch). This is the entire point of the dyn-loader topic. Never resolve a module.zig conflict by keeping the upstream registration style.
- **render.zig owns readonly-safe rendering.** The fork wraps buffer mutations in `(let ((inhibit-read-only t)) ...)` and adds `ghostel-full-redraw` support. These are the readonly and scrollback-viewport features. Never drop them during a conflict.
- **ghostel.el owns ConPTY coalescing and runtime helpers.** The fork adds `ghostel--conpty-active-p`, `conpty--read-pending`, `ghostel--coalesce-*`, and the loader bootstrap chain. These are not optional — they are the Windows runtime.
- Workflow files: keep the fork's workflow removal intentionally, but do not delete new upstream workflow behavior unless the fork still means to remove it.
- Shared test files: keep newer upstream tests and helper changes, then reapply the fork delta. Old whole-file resolutions are how upstream-safe tests get regressed.
- Performance work should stay with the commit that owns it on `main`. If `main` keeps it inside a mega commit, preserve it there.
- ConPTY and dyn-loader changes must stay functional, but they do not need to be split into separate replay commits when `main` keeps them together.
- Native module bootstrap and load paths must keep going through `ghostel--effective-module-dir`; do not reintroduce `locate-library` or package-root fallbacks in command-time startup.
- `ghostel.el` must keep the fork's one-column process width buffer (`window-max-chars-per-line - 1`) for terminal creation, startup, and resize so Emacs does not clip terminal text at the right edge.
- The no-title behavior stays owned by the final title-related fix, not by earlier replay noise.
- **render.zig trailing-newline strip is incremental-only.** The fork strips trailing newlines in the incremental redraw path only (not full redraw). Full redraw already produces correct `row_count - 1` newlines. Stripping unconditionally breaks upstream's scroll-preservation tests that rely on blank-line content keys.

## CI Monitoring After Rebase

After every rebase and force push, **monitor CI until green**:

1. `gh run list --limit 3` — find the CI run ID.
2. `gh run watch <id> --exit-status` — wait for completion.
3. If failed: `gh run view <id> --log-failed | Select-String 'FAILED|condition:|:form'` — identify the failing test and assertion.
4. Common post-rebase failures:
   - **New upstream tests referencing `(1- width)` or `(1- height)`** — our fork removed the width/height buffer; update expected values to identity.
   - **New upstream tests expecting trailing newlines in buffer** — our incremental-path strip may interfere; ensure the strip is incremental-only.
   - **Test names in `ghostel-test--elisp-tests` list** — new upstream tests must be added to the list if they are elisp-only.
   - **Conflict resolution dropping upstream test definitions** — always diff the test list after rebase.
5. Fix, amend, force push, re-verify. Do not claim green without fresh `gh run watch` evidence.

## Common Mistakes

- exploding a small `main` stack into topic micro-commits when `main` intentionally keeps those changes squashed
- taking `--ours` or `--theirs` for an entire conflicted file without checking both sides
- defaulting to "take HEAD" in conflict blocks that contain fork-only functions, export tables, or runtime helpers
- fixing a replay mistake in a later commit instead of the commit that introduced it
- preserving the fork stack while accidentally removing new upstream code or tests
- treating intermediate replay breakage as a blocker when only the final rewritten stack must validate
- folding performance tuning into Windows support or dyn-loader commits
