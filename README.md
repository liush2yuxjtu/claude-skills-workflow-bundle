# claude-skills-workflow-bundle

A bundled drop-in of four Claude Code skills that wire together the
**worktree → QA → MR** pipeline for any project. Each skill is a
self-contained folder with its own `SKILL.md` (Claude Code reads that
file's YAML frontmatter `description` to decide when to trigger the
skill).

## What's inside

```
.
├── worktree-self-host/    # scaffold a per-worktree dev launcher (port-isolated)
├── worktree-qa/           # diff → host → playwright-test → handoff
├── pre-mr/                # 4-gate pre-MR self-check (QA / e2e / diff / visual-evidence)
└── submit-mr/             # one-shot: worktree → pushed branch → opened GitLab MR
```

The four compose into a chain:

```
worktree-self-host   ← isolates your dev stack by worktree (per-port pidfiles)
       │
       ▼
worktree-qa          ← enumerates diff, exercises the app via playwright-cli
       │
       ▼
pre-mr               ← 4-gate gate: QA / e2e / diff / visual evidence quality
       │
       ▼
submit-mr            ← rebase + force-push + GitLab MR (HTTPS → HTTP → OAuth fallback)
```

## The skills

### `worktree-self-host`
Run any project's dev stack on a per-worktree port triple so multiple
worktrees of the same repo can run side-by-side without colliding on
canonical ports. Meta-skill: detects the project stack (FastAPI,
Next.js, Go binary, Rails, Rust, …) and uses `skill-creator` to
generate a fresh, project-specific launcher. See
`worktree-self-host/SKILL.md` for the contract.

### `worktree-qa`
Four-phase QA pipeline: `git diff` → `worktree-self-host` →
`playwright-cli` exercises every old + new feature → pops the app
open in Chrome for manual sign-off. Emits a test report. Trigger with
`/worktree-qa`.

### `pre-mr`
Four hard gates before opening an MR — and the default behavior is
**fix in place, not file a follow-up MR**:
1. **QA gate** — was a test pass run? Fix on the spot if not.
2. **e2e gate** — does the diff break the live app? Fix on the spot.
3. **diff gate** — show code in full, docs as summary.
4. **visual-evidence gate** — when MR body references a video / PNG /
   draft workflow, review whether a reviewer can sign off in 5 s.

Triggers on `/pre-mr`, "准备 MR", "开 MR 前", "ship MR", etc.

### `submit-mr`
The last mile: worktree → rebase → force-push with lease → open a
GitLab MR. Three-stage GitLab protocol probe
(HTTPS → HTTP → OAuth) with a silent fallback to HTTP +
`$GITLAB_TOKEN` for the winchannel internal GitLab
(`gitlab008.its.winchannel.net`) where HTTPS API often returns EOF.
Triggers on `/submit-mr`, "提个 MR", "push 我这条分支", "open the MR",
"ship it", etc.

## Install (drop into your Claude Code skills folder)

```bash
git clone https://github.com/liush2yuxjtu/claude-skills-workflow-bundle.git
cp -R claude-skills-workflow-bundle/{worktree-self-host,worktree-qa,pre-mr,submit-mr} \
      ~/.claude/skills/
```

The skills take effect on the next Claude Code session in any project
inside that worktree. The `description:` frontmatter on each `SKILL.md`
is what Claude reads to decide when to auto-trigger.

## Repo layout

Each skill folder is a **portable, self-contained Claude Code skill**:
* `SKILL.md` — required. The `name:` and `description:` frontmatter
  drive triggering; the body is the prompt Claude executes.
* `references/` — optional. Long-form rationale and templates that
  Claude can pull on demand.
* `evals/` — optional. Triggering eval fixtures (JSON scenarios).
* `scripts/` — optional. Bash helpers the skill executes.

You can copy **one** skill or **all four** — they have no inter-skill
file dependencies at the file-system level. The chain in the diagram
above is a runtime / handoff relationship, not a code import.

## License

MIT — see `LICENSE`.
