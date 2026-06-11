---
name: worktree-qa
description: >
  Full QA loop for the current worktree: diff → host → test → handoff.
  Runs `git diff` to enumerate every new/changed feature, launches the
  per-worktree dev stack via `/worktree-self-host`, exercises all features
  (old + new) through `/playwright-cli`, generates a test report, and finally
  pops the app open in Chrome for manual inspection.
  Use this skill whenever the user says "QA this worktree", "test my changes",
  "smoke test the worktree", "run full QA", "test everything end-to-end",
  "playtest my app", or mentions wanting to both auto-test AND hand-test
  their current worktree changes — even if they don't say "worktree" explicitly.
  Also trigger when the user wants a diff-to-test pipeline, or says something
  like "diff → host → test → let me try it".
---

# /worktree-qa

A four-phase QA pipeline that turns a worktree's diff into a verified,
human-playable application.

## Why this skill exists

Testing a worktree typically means juggling three separate skills:
discovering what changed, standing up the stack, and clicking through
features. Each handoff is a place to lose context or skip steps. This
skill wires them together so nothing falls through the cracks, and ends
with the app live in the user's browser for manual sign-off.

## Phase 1 — Diff & Feature Inventory

Goal: build a complete, human-readable list of everything that changed.

1. Run `git diff main...HEAD` (or `git diff origin/main...HEAD` if on a
   remote-tracking branch). If the worktree was created by
   `EnterWorktree`, the diff is against `main` by convention.
2. Parse the diff into two buckets:
   - **New features** — added routes, pages, components, API endpoints,
     config changes, new scripts.
   - **Modified features** — changed behavior in existing code.
3. For each item, capture:
   - File path(s) involved
   - Short description of the feature (one line)
   - Whether it's a new feature or a modification
4. Present the inventory to the user for confirmation before proceeding.
   If the user says "skip confirmation", just move on.

### How to read the diff

Prefer `git diff --stat` first to scope the changes, then `git diff` on
individual files for details. Look for:

- New files (`--- /dev/null`) → new features
- Added routes or API endpoints → new functionality
- Changed logic in existing files → modified features
- Deleted files → removed features (note these but don't test them)
- New dependencies in `package.json` / `pyproject.toml` → may indicate
  new capabilities

If the diff is enormous (> 100 files), summarize by directory/module
instead of per-file.

## Phase 2 — Host the Stack

Goal: get the app running on per-worktree ports.

1. Invoke `/worktree-self-host` to launch the dev stack.
   - If the project-level skill already exists at
     `.claude/skills/worktree-self-host/scripts/launch.sh`, just run it.
   - If not, the skill will scaffold one on first invoke.
2. Wait for all services to be healthy (use `status.sh` or poll the
   health endpoint).
3. Record the allocated ports (from `.run/ports.env` or the launcher's
   output). You'll need these for Phase 3.

If the stack fails to start, report the error and stop — don't proceed
to testing on a broken stack.

## Phase 3 — Automated Feature Testing

Goal: exercise every feature from the inventory through the browser.

### 3.1 Set up the browser

```bash
playwright-cli open http://localhost:<FRONTEND_PORT>
```

Use the frontend port from Phase 2. If the app has no frontend (pure API),
use `curl`-based tests instead and skip the browser.

### 3.2 Test each feature

For each item in the feature inventory:

1. **New features** — navigate to the relevant page/route, interact with
   the UI, verify the expected behavior.
   - Use `playwright-cli snapshot` to read the page state.
   - Use `playwright-cli click`, `playwright-cli fill`, etc. to interact.
   - Use `playwright-cli screenshot --filename=<feature-name>.png` to
     capture evidence.
   - Check for console errors: `playwright-cli console error`.

2. **Modified features** — exercise the existing flows that touch the
   changed code, verify nothing regressed.
   - Focus on the specific behavior that was modified.
   - Compare against the diff description from Phase 1.

3. **Core old features** — smoke-test the main flows that weren't
   changed but could be affected by shared code changes.
   - Login/logout, primary CRUD, navigation — the happy paths.
   - Not exhaustive; just enough to catch regressions.

### 3.3 Record results

For each feature tested, record:

| Feature | Status | Evidence | Notes |
|---------|--------|----------|-------|
| Feature name | PASS / FAIL / SKIP | screenshot path | Any observations |

### Testing heuristics

- If a feature requires authentication, log in first and save state:
  `playwright-cli state-save auth.json`.
- If a feature depends on data setup (e.g., creating a record), set it
  up before testing.
- If the app is a SPA, use `playwright-cli goto` with hash routes or
  click navigation links.
- If a feature is purely backend (API), test via `curl` or
  `playwright-cli eval "fetch(…)"`.
- Skip features that require external services not available in the
  worktree (note them as SKIP with reason).

## Phase 4 — Handoff to Human

Goal: open the live app so the user can test it by hand.

1. Generate the test report (see format below).
2. Pop open Chrome:

```bash
open -a "Google Chrome" "http://localhost:<FRONTEND_PORT>"
```

If Chrome is already running, this opens a new tab. If you prefer the
default browser, use `open "http://localhost:<FRONTEND_PORT>"` instead.

3. Tell the user what was tested, what passed, what failed, and what
   needs their manual attention.

## Test Report Format

```markdown
# Worktree QA Report

**Worktree:** <name>
**Branch:** <branch>
**Base:** main
**Date:** <date>

## Feature Inventory

### New Features
- [ ] Feature 1 — `path/to/file`
- [ ] Feature 2 — `path/to/file`

### Modified Features
- [ ] Feature 3 — `path/to/file`

## Test Results

| Feature | Status | Evidence | Notes |
|---------|--------|----------|-------|
| Feature 1 | PASS | screenshot1.png | — |
| Feature 2 | FAIL | screenshot2.png | Button not responding |
| Feature 3 | PASS | screenshot3.png | — |
| Login (old) | PASS | screenshot4.png | — |

## Summary

- Total tested: N
- Passed: X
- Failed: Y
- Skipped: Z

## Action Items

- [ ] Fix Feature 2 — button click handler not wired
```

Save the report to `.run/qa-report.md` in the worktree root.

## When NOT to use this skill

- The user just wants to run existing test suites → use the project's
  test runner directly (`pytest`, `vitest`, etc.).
- The user wants to deploy → use `/worktree-self-host` stop sequence
  and then deploy.
- The user only wants a diff summary → just run `git diff --stat`.
- There are no code changes to test → skip directly to Phase 4 if the
  app is already running.

## Dependencies

This skill composes two other skills — it does not re-implement them:

- **`/worktree-self-host`** — launches the per-worktree dev stack.
  See `~/.claude/skills/worktree-self-host/SKILL.md`.
- **`/playwright-cli`** — browser automation for feature testing.
  See `~/.claude/skills/playwright-cli/SKILL.md`.

Both must be available in the session. If either is missing, tell the
user and stop.
