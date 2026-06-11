# Reference patterns for per-worktree self-hosting

These are **good examples** of the techniques a per-worktree launcher needs.
They are NOT a template to copy verbatim. The user-level skill reads them
as inspiration and uses `/skill-creator:skill-creator` to generate a
per-project launcher tailored to the actual stack.

## Files

| File | What it shows | When to reach for it |
|---|---|---|
| `01-port-derivation.sh.example` | FNV-1a hash → port triple, with a +1 walk to handle TOCTOU races | Every project needs ports. Pick a strategy (hash, hand-pinned, or both). |
| `02-scoped-pidfile-stop.sh.example` | Per-worktree pidfiles in `.run/`, scoped TERM/KILL | Every project that starts >1 service needs this. Avoids killing sibling worktrees. |
| `03-config-template.py.example` | Mustache-style templating with explicit whitelist | For nginx, supervisord, systemd, caddy, traefik — any reverse proxy or process manager. |
| `04-env-loader.py.example` | Safe .env parser (handles `(` in passwords) | If the project reads `.env` and the password might contain shell metachars. |
| `05-detect-stack.sh.example` | Scan the repo to decide what to launch | Always do this FIRST. The launcher can't be stack-agnostic — it has to know whether to run `uv sync` or `pnpm install` or `go build`. |

## Why these are patterns, not a complete skill

The win_brain project has a full implementation at
`~/Documents/win-brain-contribute/.claude/skills/worktree-self-host/`
(15 shell/python files, ~600 lines). It targets ONE specific stack:
FastAPI + Next.js + nginx. Other stacks (Go + Postgres, Rails + sidekiq,
Rust + nginx, etc.) need different launchers.

The pattern above is the **WHY** behind the implementation. Read these
to understand:

- How a deterministic port triple is derived and why (collision-free across
  30+ worktrees without hand-config)
- Why pidfile scoping beats `pkill -f` (sibling worktrees)
- Why mustache + explicit-whitelist beats envsubst (no shell-syntax
  collisions with nginx/systemd/whatever)
- Why a custom .env parser beats `set -a; source` (shell metachars in
  passwords break bash parsing)
- Why you must detect the stack before launching (a launcher that assumes
  `uv sync` will fail in a Go project)

Then write a launcher for the user's actual project.

## One full implementation as reference (not as a copy target)

`~/Documents/win-brain-contribute/.claude/skills/worktree-self-host/`
is a complete worked example for a FastAPI + Next.js + nginx stack. Look
at it to see how the patterns compose into a real launcher. Do NOT `cp -R`
it into other projects — its REPO_ROOT detection, `backend/uv.lock`
check, and `docker/nginx/` paths are all win_brain-specific.
