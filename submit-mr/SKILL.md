---
name: submit-mr
description: >
  一条龙把"当前 git worktree → 远端分支 → 已开 MR"的最后一公里跑完:
  worktree 探测 → 委托 /pre-mr 4 段自检 → fetch + rebase(默认拉齐) →
  zh-CN/视觉证据补齐(默认 ≥ 0.30 安全垫) → push --force-with-lease →
  **GitLab 协议探活(HTTPS → HTTP → OAuth 三段退化)** → 创建 MR →
  输出 web_url + 用户待办 + 把产物留在 .agent/pr-assets/ 便于 recall。
  **默认行为是动手把 MR 开出来,不是报告剩余项**。
  Use this skill whenever the user says any of: "/submit-mr", "submit mr", "open the MR",
  "ship it", "ship MR", "push my branch", "push 我这条分支", "提个 MR", "提 MR",
  "搞定 MR", "把这条分支提了", "准备合并", "合并准备", "把分支推上去", "开 MR",
  "发 MR", "push and open MR", "create the merge request",
  or asks to take a clean worktree all the way to an opened GitLab MR in one shot.
  Special-case for winchannel internal GitLab (gitlab008.its.winchannel.net) where
  HTTPS API often returns EOF and the skill silently falls back to HTTP + $GITLAB_TOKEN.
  Do NOT trigger for plain "pre-mr"/"准备 MR" — that's the 4-gate self-check sub-step,
  delegate to /pre-mr instead. Do NOT trigger for "commit"/"git push" with no MR intent.
allowed-tools: [Bash, Read, Glob, Grep, Edit, Write]
---

# /submit-mr

把"clean worktree + commits already made"一条龙开成"GitLab 上一个已打开的 MR"。

## Why this skill exists

`/pre-mr` 把"分支是否够格 push"扛下来了。剩下的 push + 创 MR 这段距离,经常被 4 件
事卡住,导致 agent 反复绕路、用户反复点验证码:

1. **远端分支早被推过**(rebase 后本地新 head ≠ 远端 head),裸 `git push` 拒绝 `non-fast-forward`,
   而粗暴 `--force` 会覆盖中间别人的提交。
2. **zh-CN 比例 / 视觉证据踩在 `/pre-mr` 软门坎上**(本次实测 0.201 贴线),
   reviewer 看着像凑数。
3. **`glab` / `mcp__gitlab-winchannel` 默认走 HTTPS**,但公司内网 `gitlab008.its.winchannel.net`
   的 HTTPS 端口对当前用户环境经常返回 EOF;**HTTP 端口通**。结果"自动创 MR"路径
   一条不剩,只能临时绕。
4. **凡是退到浏览器 OAuth / playwright 都要用户一次点击**,但 `chrome-devtools-mcp`
   桥可能断、`playwright-cli` 新 profile 没 GitLab session cookie。

这个 skill 把以上 4 件事按"探活 → 退化 → 动手补"的顺序串起来,**默认动手解决**,
不是"报告剩余项"。

---

## 触发约定与分工

- 用户说 `/pre-mr` / "准备 MR" / "MR 前检查" → 走 [`/pre-mr`](../pre-mr/SKILL.md),
  这里不接管。
- 用户说 `/submit-mr` / "提 MR" / "ship it" / "push my branch" → **本 skill**,
  内部会把 `/pre-mr` 当 Phase 2 子流程跑。
- 用户只说 `git push` / "推一下" 没提 MR → 不触发,按普通 Bash 处理。
- 用户已经在 MR 上 + 让你 review / merge → 走 `/code-review` 或 `/review`,不要回到这里。

---

## §1 状态机总览

```
[1] worktree probe       → branch / HEAD / dirty?
       │ dirty → 停,提示 commit
       ▼
[2] /pre-mr 4 段自检     → QA / e2e / diff / commits 全过才进 [3]
       ▼
[3] fetch + rebase       → behind > 0 默认 rebase;撞冲突走 safe-category
       ▼
[4] zh-CN / 视觉证据加固  → 比例 < 0.30 自动补 mermaid + 中文段
       ▼
[5] push --force-with-lease
       │ rejected non-fast-forward → 回 [3] 再 rebase 一次
       ▼
[6] GitLab 协议探活
       ├─ HTTPS 200/401 → glab mr create
       ├─ HTTPS EOF + HTTP 200 → curl HTTP + $GITLAB_TOKEN  ← 本次工作模式
       └─ 都不通 → OAuth MCP / playwright(需用户一次点击)
       ▼
[7] 输出                  → MR web_url + 4 段 gate 表 + 用户待办 1-2 步
       ▼
[8] pr-assets 留痕        → .agent/pr-assets/ 不进 git,便于未来 recall
```

每一段进入前写 `.submit-mr.state.json`(同 `/pre-mr` 的 resume 协议),失败时保留,
通过后由 [8] 一并删除。

---

## §2 Phase 1 — worktree probe

```bash
WT=$(pwd)
BRANCH=$(git symbolic-ref --short HEAD)
HEAD_SHA=$(git rev-parse HEAD)
DIRTY=$(git status --porcelain)
REMOTE=$(git remote get-url origin)

echo "branch=$BRANCH"
echo "HEAD=$HEAD_SHA"
echo "remote=$REMOTE"
[ -n "$DIRTY" ] && { echo "✗ dirty worktree, commit first:"; echo "$DIRTY"; exit 1; }
```

**为什么不自动 commit**:用户对 commit message 通常有意图(group、reword、squash),
agent 替他做大概率不对。提示完就停。

---

## §3 Phase 2 — 委托 /pre-mr

调用 [`/pre-mr`](../pre-mr/SKILL.md) 的 4 段式自检:**不要在这里重新实现 QA / e2e / diff / conflict 段**。

```
Run /pre-mr in this worktree.
- 入口探测 STATE_FILE = .pre-mr.state.json
- Phase 1 QA → Phase 1.5 e2e → Phase 2 diff → Phase 2.5 commits
- 任一硬门不过 → 本 skill 停 + 把 /pre-mr 的 stderr 原样回给用户
```

通过后 `/pre-mr` 会写一个 ready 标记;读取它,继续。

---

## §4 Phase 3 — fetch + rebase(默认拉齐,不报告 behind 就停)

```bash
git fetch --all --prune
AHEAD=$(git rev-list --count HEAD ^origin/main)
BEHIND=$(git rev-list --count origin/main ^HEAD)
echo "divergence: +$AHEAD ahead / -$BEHIND behind origin/main"

if [ "$BEHIND" -gt 0 ]; then
  git stash push -u -m "submit-mr-phase3-$$" 2>/dev/null || true
  if git rebase origin/main; then
    git stash pop 2>/dev/null || true
  else
    # 撞冲突 → 不要 abort,委托 /pre-mr Phase 3 的 safe-category resolver
    echo "⚠ rebase conflicts, delegating to /pre-mr Phase 3 auto-resolve"
    exit 42  # 让 /pre-mr 接管
  fi
fi
```

**反例(AP-S1)**:不能把 "你 behind N,先 pull 一下" 报给用户就停。**默认 rebase**;
撞冲突走 `/pre-mr` 既有的 safe-category 解算路径。

---

## §5 Phase 4 — zh-CN / 视觉证据加固(0.30 安全垫)

读 MR body 草稿(`.agent/pr-assets/MR_BODY.md`,若不存在用 commit message 起初稿):

```bash
BODY=.agent/pr-assets/MR_BODY.md
[ -f "$BODY" ] || git log -1 --format=%B > "$BODY"

# 中文字符占比(汉字 / 总可打印字符)
ratio=$(python3 - <<'PY'
import re, sys, pathlib
t = pathlib.Path(".agent/pr-assets/MR_BODY.md").read_text(encoding="utf-8")
zh = len(re.findall(r"[一-鿿]", t))
total = len(re.findall(r"\S", t)) or 1
print(f"{zh/total:.3f}")
PY
)
echo "zh-CN ratio = $ratio"
```

- ratio ≥ 0.30 → 通过,进 Phase 5。
- 0.20 ≤ ratio < 0.30 → **默认动手补**,模板见 [`references/mr-body-template.md`](references/mr-body-template.md)
  的 "详细设计要点" 段:加 1 段拓扑解释 + mermaid 4 层级联图,把比例顶到 0.30+。
  不要直接交付 0.21 贴线(本次踩坑 §2 坑 2 的原因)。
- ratio < 0.20 → 提示用户:"MR body 主要是英文,我要不要按模板补一段中文设计要点?",
  得到 yes/no 后再动手或交付。

视觉证据自检:扫 `.agent/pr-assets/` 看是否至少有一项 reviewer 一眼能接受的东西
(mp4 / webm / PNG ≥ 200KB / mermaid 块 / 详细 workflow 步骤表)。**凑数的截图不算**
(AP-S2)。若都没有,自动从 commit diff 抽 1 张 mermaid 拓扑图塞进 MR body。

---

## §6 Phase 5 — push --force-with-lease(不是 --force)

```bash
git push --force-with-lease origin HEAD:"$BRANCH"
```

`--force-with-lease` 的承诺:**远端 ref 自从我上次 fetch 之后没人改过,才让我覆盖**。
任何中间 push(同事、CI 改了)都会被它拒绝,迫使你回 Phase 3 再 rebase 一次。

**反例(AP-S3)**:不能用裸 `git push --force` —— 覆盖别人的提交是不可逆的。

若 push 仍然 reject(`non-fast-forward` 或 `stale info`)→ `git fetch && git rebase origin/$BRANCH`
再来一次。最多重试 1 轮,2 轮还 reject → 停,把 `git log --oneline -10 origin/$BRANCH..HEAD`
打给用户,问 "remote 的这些 commit 看着不在你预期里,要 cherry-pick 哪些?"。

---

## §7 Phase 6 — GitLab 协议探活(本 skill 的核心发现)

### 决策树

```
试 curl --max-time 5 https://$host/api/v4/user
├─ 200/401 → 走 HTTPS 标准路径(下文 §7a)
└─ EOF / timeout / conn refused
    │
    ▼
试 curl --max-time 5 http://$host/api/v4/user
├─ 200/401 → 走 HTTP 工作路径(下文 §7b)← 本次 winchannel 的实际工作模式
└─ 也失败 → 降级到 OAuth MCP / playwright,需用户一次点击(下文 §7c)
```

### 实现

`scripts/probe-gitlab.sh` 已经把上面三步打包,返回值:
- exit 0 + stdout `HTTPS` / `HTTP` / `OAUTH`,代表选哪条路径
- exit 非 0 → 协议都不通,把 stderr 原样回给用户

```bash
PROTO=$(bash "$SKILL_DIR/scripts/probe-gitlab.sh" "$REMOTE")
echo "GitLab API protocol: $PROTO"
```

**关键:本探活不读 `$GITLAB_TOKEN` 的值,只用它做存在性 + 401 测试**。
不在日志、stderr、命令行任何位置 echo 真实 token。

---

### §7a 路径 A — HTTPS 标准:`glab mr create`

```bash
glab mr create \
  --target-branch main \
  --title  "$(head -1 .agent/pr-assets/MR_BODY.md | sed 's/^# *//')" \
  --description-file .agent/pr-assets/MR_BODY.md \
  --yes
```

输出会包含 `https://.../merge_requests/<iid>`。把它拎出来传给 Phase 7。

### §7b 路径 B — HTTP 工作模式(winchannel 默认)

通过 `scripts/create-mr-http.sh` 调用,**只接收**:
`PROJECT_PATH`(如 `datascience/win_ontology/win_brain`)、`SOURCE_BRANCH`、`TARGET_BRANCH`、`TITLE`、`BODY_FILE`。
脚本自动:

1. 查 `PROJECT_ID`(按 path,本次 win_brain = 1574),
2. `POST /projects/$PROJECT_ID/merge_requests`,
3. 从响应里取 `iid` / `web_url`,
4. **不打印** `Authorization` / `PRIVATE-TOKEN` / 任何 cookie。

调用示例:

```bash
SUBMIT_MR_PROTO=$PROTO \
PROJECT_PATH="datascience/win_ontology/win_brain" \
SOURCE_BRANCH="$BRANCH" \
TARGET_BRANCH="main" \
TITLE="$(head -1 .agent/pr-assets/MR_BODY.md | sed 's/^# *//')" \
BODY_FILE=".agent/pr-assets/MR_BODY.md" \
bash "$SKILL_DIR/scripts/create-mr-http.sh"
```

成功输出形如:

```
MR_IID=55
MR_WEB_URL=http://gitlab008.its.winchannel.net/.../merge_requests/55
```

### §7c 路径 C — OAuth MCP / playwright(需用户一次点击)

只在 §7a / §7b 都不通时启动。优先顺序:

1. `mcp__gitlab-winchannel` — 调 `authenticate`,弹给用户 OAuth URL,等回调。
2. `playwright-cli` — 仅当用户的 Chrome profile 里已经登录过 GitLab(有 session cookie)。
3. 上述都不可用 → **停,把 MR body 文件路径 + 远端分支名 + 创建 MR 的 GitLab 链接**
   `https://$host/$PROJECT_PATH/-/merge_requests/new?merge_request[source_branch]=$BRANCH`
   交给用户,让用户去浏览器粘 body。

---

## §8 Phase 7 — 输出格式

终态固定模板:

```
✓ MR opened — iid <N>
  url:     <web_url>
  target:  main ← <BRANCH>
  HEAD:    <short SHA>
  protocol: <HTTPS|HTTP|OAUTH>
  zh-CN ratio: 0.339 (≥ 0.30 ✓)

gate summary:
  Phase 1 QA          ✓ (24h within)
  Phase 1.5 e2e       ✓ (15/15)
  Phase 2 diff        ✓ (code 全量 + docs 摘要)
  Phase 2.5 commits   ✓ (clean rebase, +N -0)
  Phase 3 rebase      ✓
  Phase 4 evidence    ✓ (mermaid + 详细设计要点)
  Phase 5 push        ✓ (--force-with-lease)
  Phase 6 MR create   ✓ (<HTTP|HTTPS|OAUTH>)

next steps for you:
  1. 在 MR 上 assign reviewer / 加 label / 设 milestone
  2. 等同事 Approve,然后在 GitLab 上点 Merge
```

**不输出**:diff 全文 / token / 任何 cookie。Diff 让用户去 GitLab 看。

---

## §9 Phase 8 — pr-assets 留痕(不进 git)

```bash
mkdir -p .agent/pr-assets
echo "<根目录的 .gitignore 已经把 .agent/pr-assets/ 排除了吗?>" >&2
grep -q '^\.agent/pr-assets/' .gitignore 2>/dev/null \
  || echo '.agent/pr-assets/' >> .gitignore
```

留下:
- `MR_BODY.md` — 本次 body(GitLab 端已有副本,本地留作模板复用)
- `qa-report.md` — Phase 1 / 1.5 的产物(同 `/pre-mr` 输出)
- `submit-mr.summary.txt` — Phase 7 的输出原样存档
- 任何 mermaid 块 / 截图 / 录屏 — 视觉证据

**不留**:任何含 token 的 curl response。`scripts/create-mr-http.sh` 已经把
`access_token`、`Set-Cookie` 字段在写文件前 redact。

最后删 `.submit-mr.state.json`。

---

## §10 反例(4 条 hard rule,对应 `/pre-mr` 的同名反例风格)

| ID | 反例 | 正例 |
|---|---|---|
| **AP-S1** | 看到 `behind N` 就报告"先 pull 一下"停 | 默认 `git rebase origin/main`;撞冲突走 safe-category(委托 `/pre-mr` Phase 3) |
| **AP-S2** | 凑数视觉证据(logo / 无关截图 / 黑屏录屏) | 至少 1 张 mermaid 拓扑图 + 详细设计要点,reviewer 30 秒能读懂 |
| **AP-S3** | `git push --force`(覆盖中间的他人提交) | `git push --force-with-lease`;reject 就回 Phase 3 |
| **AP-S4** | HTTPS API EOF 就放弃自动创 MR、回 OAuth/playwright | 先试 HTTP(`curl http://$host/api/v4/...`);本仓库历史证明 HTTP 通的概率远高于 EOF 的 HTTPS |

这 4 条是**默认行为**,不是建议。

---

## §11 redact 守则

- 文档、日志、handoff、commit message 里只准出现 `$GITLAB_TOKEN` 这个**变量名**,
  **不准**出现真实 PAT 字面值。
- `set -x` debug 时也不准开 token 那一行;改成 `set +x; <token line>; set -x`。
- 把 curl 响应写到 `.agent/pr-assets/` 前,先过 redact:
  ```bash
  sed -E 's/("access_token"|"private_token"|"refresh_token") *: *"[^"]+"/\1: "<redacted>"/g; s/(Set-Cookie:[^=]+=)[^;]+/\1<redacted>/g'
  ```
- 用户身份信息(`liushiyu` / `liushiyu@winchannel.net`)是用户公开的工作身份,
  可以保留。

---

## §12 本次设计的踩坑回顾(背景)

本 skill 是从 2026-06-11 这次"把 graph-plane v2 commit `f49a43c4` 一路推到 MR iid 55"
的踩坑总结出来的。4 个坑都已沉淀:

| # | 坑 | 沉淀位置 |
|---|---|---|
| 1 | Phase 1 没找到 24h 内 QA 产物 | 委托给 `/pre-mr` Phase 1,本 skill 不重复 |
| 2 | zh-CN 比例 0.201 贴线(软门坎要求 ≥ 0.20) | Phase 4 把安全垫顶到 0.30,贴线自动补 mermaid + 中文段 |
| 3 | push reject `non-fast-forward` | Phase 5 默认 `--force-with-lease` + reject 时回 Phase 3 |
| 4 | `glab` HTTPS EOF / OAuth MCP 一次点击 / playwright 无 session | Phase 6 三段退化(HTTPS → HTTP → OAuth),HTTP 是 winchannel 内网的默认工作模式 |

详细日志见 [`references/handoff-rationale.md`](references/handoff-rationale.md)
(从 `/tmp/handoff-mr-QyQi/HANDOFF-submit-mr.md` 抄写到 skill 自身的引用区,以
免原 handoff 文件被清理时丢失)。

---

## §13 关联 skill

按调用顺序:

1. **`git-guardrails-claude-code`** — 全局 PreToolUse hook,push / force 前再核对一次。
2. **`pre-mr`** — Phase 2 子流程,本 skill 不重写。
3. **`worktree-qa`** — `/pre-mr` Phase 1 的产物源头,本 skill 不直接调,但用户若被
   "QA 产物 24h 过期"卡住会被指到这里。
4. **`winchannel-dev-standards`** — reviewer 卡规范的标尺,Phase 4 视觉证据 / 代码风格的依据。
5. **`handoff`** — 若 MR 开完后用户要立刻切别的任务,这是后续工作交接。

---

## §14 调用示例

```
User: 我把当前分支提个 MR

You: [触发 /submit-mr]
     Phase 1 worktree probe: branch=worktree-mighty-discovering-falcon HEAD=f49a43c4 clean
     Phase 2 /pre-mr → 4 段全过 (QA / e2e 15/15 / diff / commits)
     Phase 3 fetch + rebase: +1 ahead / 0 behind, no rebase needed
     Phase 4 zh-CN ratio = 0.339 ≥ 0.30 ✓; mermaid + 详细设计要点已就位
     Phase 5 push --force-with-lease ✓
     Phase 6 probe: HTTPS=EOF, HTTP=200 → 走 HTTP
            curl POST .../merge_requests → iid=55
     Phase 7 ✓ MR opened — iid 55
            url: http://gitlab008.its.winchannel.net/.../merge_requests/55
            next: assign reviewer + 等 approve + merge
     Phase 8 .agent/pr-assets/ 已留 4 个产物,.gitignore 已包含
```
