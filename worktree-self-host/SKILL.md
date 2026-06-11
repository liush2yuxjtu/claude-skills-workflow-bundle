---
name: worktree-self-host
description: Run the project's dev stack on a per-worktree port triple, so multiple git worktrees of the same repo can run side-by-side without colliding on the canonical ports. This is a **meta-skill**: it doesn't ship a hardcoded launcher — instead it detects the project's stack (FastAPI + Next.js? Go binary? Rails + sidekiq? Rust + nginx?) and uses `/skill-creator:skill-creator` to **generate a fresh, project-specific** `.claude/skills/worktree-self-host/` tailored to that stack. The pattern library at `references/patterns/` is the **inspiration** (FNV-1a port derivation, scoped pidfile stop, mustache config templating, safe .env loader, stack detection) — NOT a copy target. Use this skill whenever the user types `/worktree-self-host`, says "launch this worktree", "per-worktree ports", "isolated dev stack", "stop this worktree's services", "status of this worktree", or mentions port collisions between worktrees — even if they don't explicitly say "per-worktree". Works for any future repo (DeerFlow-style, monorepo, single-binary Go, Rails, etc.) by scaffolding a tailored launcher on first invoke. NOT for production deploy (use `make up`), Docker compose (use `make docker-start`), or the canonical single-worktree `make dev` (which is fine when port collision is impossible).
---

# /worktree-self-host

Generate a per-worktree dev launcher for the current project, on first invoke. Subsequent invocations just run the generated launcher.

## First invoke (no project-level skill yet)

When the user types `/worktree-self-host` in a project that doesn't already have `.claude/skills/worktree-self-host/`, scaffold it:

1. **Detect the stack** so you know what to launch. Read `references/patterns/05-detect-stack.sh.example` for the heuristics, then apply them. Common signals:
   - `backend/{uv.lock,pyproject.toml}` → Python service (FastAPI / Flask / Django)
   - `backend/package.json` or `frontend/package.json` → Node service (Express / Next.js / NestJS)
   - `go.mod` → Go binary (often a single `cmd/server/main.go`)
   - `Cargo.toml` → Rust binary (`cargo run` or `cargo build --release`)
   - `Gemfile` + `config/application.rb` → Rails
   - `docker/nginx/` or top-level `nginx.conf` → reverse proxy to wire up
   - `docker-compose.yml` → additional services (postgres, redis, sidekiq)
   - `.env` with `DATABASE_URL=postgresql://...` → likely needs asyncpg / pg client

2. **Read the pattern library** at `references/patterns/`. These are short, stack-agnostic — FNV-1a port derivation, scoped pidfile stop, mustache config templating, safe .env loader, stack detection. They are the *techniques*, not the implementation.

3. **Generate a fresh project-level skill** at `<REPO>/.claude/skills/worktree-self-host/` using the **Write** tool (and the **Bash** tool for any helpers you need to verify). The skill's structure should follow the standard Claude Code skill layout:
   ```
   <REPO>/.claude/skills/worktree-self-host/
   ├── SKILL.md
   └── scripts/
       ├── launch.sh        — start the per-worktree stack
       ├── stop.sh          — scoped TERM/KILL via .run/*.pid
       ├── status.sh        — health probe
       ├── allocate-ports.sh — port derivation (from pattern 01)
       ├── render-config.sh  — if there's a reverse proxy to template (pattern 03)
       ├── write-env.sh      — emit per-worktree .env (uses pattern 04)
       └── lib/{log,pidfile}.sh — shared helpers (from pattern 02)
   ```
   Adapt the script bodies to the detected stack. Do not `cp -R` anything from `references/patterns/` — they are inspiration, not templates. Re-write each script tailored to the actual project commands (`uv run uvicorn …` for FastAPI, `go run ./cmd/server` for Go, `pnpm dev` for Next.js, `rails s -p $PORT` for Rails, etc.).

4. **Update the project's `.gitignore`** to include the runtime-state paths your launcher writes to. Common entries:
   ```
   /.run/
   /temp/
   /.env.worktree
   /<your-nginx-config>.worktree.conf
   ```
   If the project also ignores `.claude/` broadly, narrow it to specific subdirs (e.g. `.claude/workpert-agents/`, `.claude/worktrees/`) so `.claude/skills/` stays tracked.

5. **Smoke-test** by running the generated `launch.sh` and verifying all services are up (or, if the user's project is heavy, just generate the skill and tell them how to run it).

6. Tell the user what was generated and how to invoke it.

## Subsequent invocations (project-level skill already present)

If `<REPO>/.claude/skills/worktree-self-host/scripts/launch.sh` exists, just point the user at it:

```bash
bash .claude/skills/worktree-self-host/scripts/launch.sh    # start
bash .claude/skills/worktree-self-host/scripts/stop.sh      # stop
bash .claude/skills/worktree-self-host/scripts/status.sh    # health
```

You do not need to re-scaffold. The user-level skill's only job is first-time scaffolding; afterward, the project-level skill is the source of truth.

## When NOT to use this

- The user wants to deploy, not develop → use `make up` or whatever the project's prod-deploy command is.
- Only one worktree is ever active, no port collision possible → just `make dev` / `pnpm dev` / `go run` / etc.
- The user wants a per-worktree DB schema migration, not a launcher → this skill is about *services*, not schema isolation.

## Reference

- `references/README.md` — index of the pattern library and how to use it
- `references/patterns/01-port-derivation.sh.example` — FNV-1a hash → port triple, with a +1 walk
- `references/patterns/02-scoped-pidfile-stop.sh.example` — per-worktree pidfiles in `.run/`, scoped TERM/KILL
- `references/patterns/03-config-template.py.example` — mustache-style templating with explicit whitelist
- `references/patterns/04-env-loader.py.example` — safe .env parser (handles `(` in passwords)
- `references/patterns/05-detect-stack.sh.example` — stack detection heuristics

For one full worked implementation as a reference (not as a copy target),
look at the project-level skill at
`~/Documents/win-brain-contribute/.claude/skills/worktree-self-host/`
in the win_brain-contribute repo. It targets FastAPI + Next.js + nginx.
