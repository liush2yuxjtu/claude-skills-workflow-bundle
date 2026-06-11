---
name: pre-mr
description: >
  MR 提交前 4 段式自检 + 默认就地修复:QA → e2e 默认改源码(不 defer 到 follow-up MR)→
  diff 展示(代码全量 / 文档仅摘要)→ 冲突默认按 safe-category + intent 自动解(撞模糊才升用户)→
  MR body 引用了未跟踪的视觉证据(mp4 / webm / PNG / 草稿 workflow)并对该证据做"能不能
  让 reviewer 一眼接受"的质量复盘。**默认行为是动手修,不是报告遗留**。
  Use this skill whenever the user says any of: "pre-mr", "/pre-mr", "pre-MR",
  "prepare merge request", "准备 MR", "MR 前检查", "开 MR 前", "ready to push",
  "ship MR", "合并前检查", "MR checklist", "push 前自检", "MR 提交流程",
  "before I push", "before opening MR", or asks to verify a branch is ready
  to merge into origin/main with diff, conflict, visual-evidence, and
  evidence-quality gates.
  Do NOT trigger for plain "diff" or "merge" requests — those are too broad
  and don't imply the full 4-gate pre-MR pipeline.
allowed-tools: [Bash, Read, Glob, Grep]
---

# /pre-mr

MR 提交前 4 段式自检:每段都 hard-gate,上一步不过直接停,不进入下一步。

## Why this skill exists

打开 MR 之前,作者通常漏 4 件事:
1. 没跑过 QA(就 push 上去,reviewer 才发现 bug)。
2. 把整页 `.md` / `config.yaml` 改动塞进 diff,reviewer 看不清真正的代码变化。
3. MR body 写了几段文字但没视觉证据(截图/录屏/草稿 workflow),reviewer
   只能盲审,review 周期拉长。
4. **视觉证据是凑数的**(放一张 logo / 一张无关截图 / 一段黑屏录屏),reviewer
   看完还是不接受。证据不仅要"有",还要"能让 reviewer 一眼通过"。

这个 skill 把这 4 件事做成 hard gate —— 任一不过就不输出 "READY TO PUSH"。

---

## §1 启动前:resume 检测

```bash
STATE_FILE="<worktree>/.pre-mr.state.json"
[ -f "$STATE_FILE" ] && echo "RESUME: $STATE_FILE" && cat "$STATE_FILE"
```

如果存在,从记录的 phase 继续(跳到对应 phase 起点)。完成后删除 `STATE_FILE`。
不存在则从 Phase 1 开始。

每次进 phase 之前写 `STATE_FILE`:

```bash
echo "{\"phase\": <N>, \"status\": \"running\", \"ts\": \"$(date -u +%FT%TZ)\"}" > "$STATE_FILE"
```

---

## §2 Phase 1 — QA gate

**Goal**: 24h 内有过 QA 跑通的证据(`/worktree-qa` 之类)。

### 步骤

1. 找证据文件(任一命中即通过):
   - 工作区根的 marker:`MR_QA_PASSED`、`.qa-passed`、`.qa-done` 之一
   - 24h 内修改的 QA 产物:
     - `.agent/**/qa*`、`.agent/**/QA*`
     - `.agent/pr-assets/**`(同 24h)
     - `pr-build/**/qa*`
     - `artifacts/**/qa*`
     - `docs/qa/**`

   ```bash
   find .agent pr-build artifacts docs/qa \
     -type f \( -iname '*qa*' -o -path '*/pr-assets/*' \) \
     -mtime -1 2>/dev/null
   test -f MR_QA_PASSED -o -f .qa-passed -o -f .qa-done
   ```

2. **未命中 → 立即停**:
   ```
   ✗ QA gate: 没找到 24h 内 QA 产物。
   → 先跑 /worktree-qa(diff → host → test → handoff),产物落 .agent/pr-assets/。
   → 跑完后再 /pre-mr。
   ```
   写 `STATE_FILE` 记录 phase=1 status=blocked,**不要**往下走。

3. 命中:打印 `✓ QA gate: <evidence path> (mtime < 24h)`,更新 state,进 **§2.5
   e2e 自动修复**(e2e 失败默认就地修,AP-15 反例)。

### Phase 1 豁免:docs-only / skills-only MR

如果 `git diff --name-only origin/main...HEAD` 的扩展名**全部命中 docs/config 桶**
(无 `.ts/.tsx/.js/.py/.go/.rs/.sh/...` 等代码文件,且**无** config 家族以外的 `.yaml`),
QA gate 自动降级为:

```
✓ QA gate: SKIPPED (docs-only MR,无运行时改动)
  → review focus:文字准确性 + 链接可用性 + 截图是否真能渲染
```

这种情况 MR body 必须在 §Why 段显式标注 "docs-only,无运行时改动,QA 不适用"。

---

## §2.5 Phase 1.5 — e2e 默认就地修

**Goal**: Phase 1 拿到的 QA 产物里**任何 e2e 失败默认就地修**(AP-15 反例:
不能 defer 到独立 follow-up MR、不能写"建议开 brand-sync MR")。源码能修
就修源码,断言本身写错才修测试;真正缺业务上下文才升用户。

### 步骤

1. **读失败清单**。Phase 1 命中的 QA 产物里挑这些(任一存在即用):
   ```bash
   find .agent pr-build artifacts docs/qa \
     -type f \( -iname 'summary.json' -o -iname 'junit*.xml' \
              -o -iname '*qa*.log' -o -iname '*qa*.md' \) \
     -mtime -1 2>/dev/null
   ```
   解析失败 case(按格式):
   - **JUnit XML**:`<testcase classname=... name=...>` 含 `<failure>` 子节点
   - **pytest**:`FAILED <file>::<test_name>` 行 + `--tb=short` 上下文
   - **playwright**:`<n>) [chromium] › <path>:<line>:<col>` 块
   - **jest/vitest**:`✕ <test name>` + 后面 stack trace

2. **归类失败来源**。对每个失败的 case 拿 `(file_under_test,
   test_file)`:
   ```bash
   # pytest 例子:FAILED tests/foo/test_bar.py::test_baz → test=tests/foo/test_bar.py, src 反查 conftest / import
   # playwright 例子:tests/e2e/canvas.spec.ts:42 → test=tests/e2e/canvas.spec.ts, src 由 selector / url 反查
   ```
   落到 3 类:
   - **本 MR 改的源码引起的失败** → 必修
   - **本 MR 改的测试本身的断言错** → 修测试
   - **pre-existing 失败,本 MR 完全不碰**(文件 diff 不重叠)→ 仍要修(AP-15),
     因为 §用户已经要求「不再 defer」;若修不动再升用户

3. **修源码 / 修测试的选择**(AP-15 期望的 source-side 优先):
   - **默认改源码**。读失败 assertion + 测试期望值,定位 prod code 该改的位置
   - **仅当**测试断言本身写错(过期常量 / 删过的 API / 错 mock)才改测试
   - 每修一个 case 在 log 写一行 `<case-id>: 改 <file>:<lines> 因为 <reason>`

4. **定向 e2e 验证**(项目自身的 filter 命令,不要跑全套):
   ```bash
   # pytest
   pytest <test_file>::<test_name> -xvs
   # playwright
   npx playwright test <spec> -g "<case title>"
   # jest/vitest
   npx vitest run <test_file> -t "<test name>"
   ```
   绿了 → 下一个 case;还红 → 二次修复,3 轮修不动就升用户(5)。

5. **domain knowledge 缺口 → 升用户**(不是 defer):
   ```
   ⚠ needs human review: <case-id> 涉及 <模块> 业务规则
     (例: 区域定价 / 库存分配 / 角色权限矩阵)
     我没有上下文继续改。修这条,剩下的我继续。
   ```
   一次性把这种 case 全部列出,**不静默跳过**,修完用户接手的部分后回到
   step 4 重跑。

6. **完成态**:
   - 全部 case 绿 → 打 `✓ e2e auto-fix: N failed → 0 failed (fixed K cases)`,
     进 Phase 2
   - 仍有失败但全部升用户 → 打 `✓ e2e auto-fix: K fixed, M need-human-review
     (see §已知遗留)`,**这些 M 条留 §已知遗留 但 §已知遗留 必须含每个 case 的
     具体原因,不是泛泛一句 "defer to brand-sync MR"**(AP-15 反例)

### Phase 1 命中但 e2e 全部 pass

跳过本节,直接 `✓ e2e auto-fix: no-op (Phase 1 报告无失败)`,进 Phase 2。

---

## §3 Phase 2 — Diff display

**Goal**: 相对 `origin/main` 的改动,代码全量 + 文档仅摘要。

### 步骤

1. 刷新:
   ```bash
   git fetch origin
   BASE=$(git rev-parse origin/main)
   HEAD_SHA=$(git rev-parse HEAD)
   ```
   `origin/main` 不存在(没有该远端)→ 报"未配置 origin/main,请先 `git remote add`"并停。

2. **无变更**:
   ```bash
   [ "$HEAD_SHA" = "$BASE" ] && echo "无变更,无需 MR" && exit 0
   ```

3. 先打 stat 表(scope 预览):
   ```bash
   git diff --stat "$BASE...$HEAD_SHA"
   ```

4. 拿所有变更文件,按扩展名分桶:
   ```bash
   git diff --name-only "$BASE...$HEAD_SHA" > /tmp/.pre-mr.files
   ```

   **CODE 桶**(全量 diff + 文件头):
   `.ts .tsx .js .jsx .mjs .cjs .py .go .rs .java .kt .swift .c .cc .cpp .h .hpp .sql .sh .bash .zsh .css .scss .vue .svelte`
   + `Dockerfile` + `docker-compose*.yml` + `Makefile`
   + `.yaml` / `.json` **但**排除下列锁定/配置白名单
     → 用 grep 反向排除:`config*.yaml`、`*.local.yaml`、`config.yaml`、`config.example.yaml`、`config.local.yaml`、`config.yaml.md`、`config.local.yaml`、`*.lock`、`package-lock.json`、`yarn.lock`、`pnpm-lock.yaml`、`poetry.lock`、`Cargo.lock`、`go.sum`

   **DOCS / CONFIG 桶**(仅摘要):
   `.md .mdx`、`LICENSE`、`config.yaml.md`、`.gitignore`、`.gitattributes`、`.pre-commit-config.yaml`、`.editorconfig`、`config*.yaml`(全家族)、`config.local.yaml`、`.env*`、所有 lockfile、`.json` 锁文件(同上)。

5. **CODE 桶**:逐文件 `git diff "$BASE...$HEAD_SHA" -- <file>`,完整 `+`/`-` 行,带 `diff --git` 头。

6. **DOCS 桶**:只打三列:`path | +N -M | <first hunk "@@ ..." 后首行>`:
   ```bash
   for f in $(cat /tmp/.pre-mr.docs); do
     stat_line=$(git diff --shortstat "$BASE...$HEAD_SHA" -- "$f")
     first_hunk=$(git diff "$BASE...$HEAD_SHA" -- "$f" \
       | awk '/^@@/{getline; print; exit}')
     printf '%-50s | %s | %s\n' "$f" "$stat_line" "$first_hunk"
   done
   ```

7. **二进制文件**:`git diff --numstat` 显示 `-\t-\t`(全 tab),打 `(binary, +N −M, not shown)`。

8. 顺序固定:`stat table → CODE diffs → DOCS summary`。中间不打空行 banner。

---

## §4 Phase 3 — Conflict resolve (默认就地解决)

**Goal**: 当前分支可以干净地并入 `origin/main`。**默认行为是动手解决 —
不是"报告 divergence + 撞冲突就停"**(AP-14 / AP-16 反例)。

### 步骤

1. 算 merge-base:
   ```bash
   BASE_COMMIT=$(git merge-base HEAD origin/main)
   AHEAD=$(git rev-list --count HEAD ^origin/main)
   BEHIND=$(git rev-list --count origin/main ^HEAD)
   echo "divergence: +$AHEAD ahead / -$BEHIND behind origin/main"
   ```

2. **BEHIND > 0 → 默认就地拉齐**(AP-14 反例:不能只报 "−N behind" 塞 §已知遗留):
   ```bash
   git fetch origin
   # 先试 fast-forward(线性历史最干净)
   if git merge --ff-only origin/main 2>/dev/null; then
     echo "✓ ff-merged origin/main: $(git rev-list --count HEAD ^origin/main) ahead"
   else
     # ff 失败 → rebase(本仓库约定)。先 stash 兜底(AP-11)
     git stash push -u -m "pre-mr-phase3-pre-rebase-$$" 2>/dev/null || true
     if git rebase origin/main; then
       git stash pop 2>/dev/null || true
       echo "✓ rebased onto origin/main: rewritten $(git rev-list --count origin/main..HEAD) commits"
     else
       # rebase 撞冲突 → 不要 abort,进 step 3 自动解决
       echo "⚠ rebase hit conflicts, entering auto-resolve"
     fi
   fi
   ```
   其他备选(仅在用户明确要求时用):
   - `git merge origin/main` — 保留分支身份、产生 merge commit,适合"我分支有 30+ 个
     commit 不希望被打散"
   - 手工 cherry-pick / 重组 commits — 当 rebase 会把 feature commit 拆碎时
   - **不要在主分支上 `git pull` 然后 `git merge`**(无意义 merge commit,AP-2)

3. **冲突自动解决**(默认行为,AP-16 反例:不能"推荐 rebase + 手工 add" 打发):
   `git status` 出现 `both modified` / `deleted by us|them` / `added by us|them`
   时按 3 类处理:

   - **3a. 已知安全类别**(直接采纳,记一行日志):
     - **仅空白差异**(整行只有 `+/-` 后跟空白 / 行尾换行差异)→
       `git checkout --theirs <file>` + `git add <file>`
     - **锁文件**(`*.lock`、`package-lock.json`、`yarn.lock`、`pnpm-lock.yaml`、
       `poetry.lock`、`Cargo.lock`、`go.sum`、`.git/index.lock`)→
       `git checkout --theirs <file>`(由 theirs 重新生成)
     - **`.gitignore` 顺序调整 / 新增行** → 合并两边的 `+` 行,保留 `-` 不动;
       如果是删行冲突,采纳 `--ours`(本 MR 自己的 .gitignore 决定保留啥)
     - **生成文件**(`dist/`、`build/`、`.next/`、`__pycache__/`、
       `*.generated.*`、`*_pb2.py`、`*.pb.go`、`*.min.js`、`coverage/`)→
       `git checkout --theirs <file>`(跑 build 重新生成,不要手编)
     - **lockfile 内的版本号 bump** → 采纳 `--theirs`,依赖文件本身
       会在后续 e2e 跑时被验证(§2.5)

   - **3b. 语义冲突**(按 MR intent 解析):
     - 读 MR title + MR body §本 MR 的关键设计决策(若 MR_BODY.md 已存在)或
       §Why 段,得到 1-3 句 intent
     - 对每个 unmerged 文件,在 `git show :2:<file>` (ours) 和
       `git show :3:<file>` (theirs) 各自抽冲突区段(+/- 行)
     - 哪一侧的 diff 与 intent 描述一致就采纳哪一侧;若两侧都部分一致,人工
       合成(只挑与 intent 相关的行)+ 写 `// resolved per MR intent` 注释
     - `git add <resolved>`,每条决议在 log 写
       `<file>: picked <ours|theirs|merged> because <reason>`

   - **3c. 模糊**(两侧改同一段代码、intent 判断不出来、business rule
     决定哪条胜出)→ **停下,列给用户**:
     ```
     ⚠ 冲突需要人判:
       <file>:
         ours  (<our_commit_sha>): <N 行变更>
         theirs (<their_commit_sha>): <M 行变更>
       两侧均改 <function/region>,MR intent 未涵盖此段。
       请选: 1) ours  2) theirs  3) 给我合并指引
     ```
     **不要静默猜**(AP-16 核心反例)。

4. **dry-run 合并** 作最终校验(git ≥ 2.38):
   ```bash
   git merge-tree "$BASE_COMMIT" HEAD origin/main > /tmp/.pre-mr.mergetree
   ```
   旧版 git:`git merge-tree $(git merge-base HEAD origin/main) HEAD origin/main`。
   ```bash
   if grep -qE '^(<{7}|={7}|>{7})( |$)' /tmp/.pre-mr.mergetree; then
     echo "✗ CONFLICT still present after auto-resolve"
     grep -E '^(<{7}|={7}|>{7})' /tmp/.pre-mr.mergetree
     git diff --name-only --diff-filter=U "$BASE_COMMIT" origin/main
     exit 1
   fi
   ```

5. **clean test-merge**(non-destructive,与原版一致):
   ```bash
   SCRATCH="_pre_mr_scratch_$$"
   git checkout -b "$SCRATCH"
   if git merge --no-commit --no-ff origin/main >/dev/null 2>&1; then
     git merge --abort
     git checkout -  >/dev/null
     git branch -D "$SCRATCH" >/dev/null
     echo "✓ conflict-resolve: merge-clean"
   else
     git merge --abort 2>/dev/null
     git checkout -  >/dev/null
     git branch -D "$SCRATCH" >/dev/null
     echo "✗ test-merge failed in scratch branch(可能本地有未提交改动?)"
     exit 1
   fi
   ```

6. **边界**:`AHEAD=0 && BEHIND=0` 时,跳过 step 2-5,直接打
   `✓ conflict-resolve: no-op (HEAD == origin/main)`;`AHEAD>0 && BEHIND=0`
   时只跑 step 4-5 确认没有"反向"冲突(罕见,但自己改的文件被 force-push 改过时
   会出)。

---

## §3.5 Phase 2.5 — Commits clean gate (新增)

**Goal**: 分支上的 commits 干净 —— 没有 WIP / fixup / squash 残留,没有明显调试代码
混进 commit,格式符合 conventional commit,**handoff 给 reviewer 前最后一次自检**。

### 步骤

1. 列出分支相对 base 的所有 commits:
   ```bash
   git log --oneline origin/main...HEAD
   ```
2. 抓每个 commit 的 subject + body + stat:
   ```bash
   for sha in $(git rev-list origin/main...HEAD); do
     echo "=== $sha ==="
     git log -1 --format='%s%n%n%b' "$sha"
     git show --stat --format='' "$sha"
   done
   ```
3. 按下列清单逐项打勾,**任一不过 → 停**:

   - [ ] **无 WIP 残留**:subject 行不匹配 `^WIP[: ]` / `^wip[: ]` / `^tmp` / `^scratch`
   - [ ] **无 fixup/squash 残留**:subject 行不匹配 `^fixup!` / `^squash!` / `^amend!`
   - [ ] **conventional commit 格式**(推荐,非硬性):subject 匹配
         `^(feat|fix|chore|docs|refactor|perf|test|build|ci)(\([\w-]+\))?!?: `
   - [ ] **无调试代码**:`git show` 输出不含 `console.log(` / `print(` / `XXX` /
         `FIXME` / `// debug` / `import pdb` / `breakpoint()` 之类
         (允许的例外:examples / tests / debug-tools 自身)
   - [ ] **无空 commit**:`git log --oneline origin/main...HEAD | wc -l` 应与有效
         commit 数一致
   - [ ] **有 trailer**(推荐):commit body 含 `Co-Authored-By:` trailer(多人协作 / AI 协助)
   - [ ] **无 merge commit 污染**(推荐):线性历史,`git log --merges origin/main...HEAD`
         输出为空;若有 merge commit,确认是用户有意为之
4. 失败输出:
   ```
   ✗ commits-clean: <sha> <subject> 命中 <AP-13 / AP-14>
   → 修法:git rebase -i origin/main → squash / reword / drop
   ```
5. 全过 → 打 `✓ commits-clean: N commits, all clean`,进 Phase 3。

### 为什么放在 Phase 2 之后

Phase 2 已经把 diff 列出来,reviewer 看完 diff 通常会问"这堆 commit 怎么组织的"。
2.5 这一步把"commit 卫生"也先管掉,免得 reviewer 反手打回"先把 WIP 干掉"。

---

**Goal**: MR body 引用了视觉证据,**且该证据能说服 reviewer 一眼接受**。两个 sub-gate,
都要过。

### §5.1 Existence + Untracked sub-gate

1. 找 MR body(按这个顺序,首个命中即用):
   - `.agent/pr-assets/MR_BODY.md`(**推荐:未跟踪路径,本仓库约定**)
   - `.agent/MR_BODY.md`
   - `MR_BODY.md`、`MR.md`(worktree 根,**仅当文件未 git 跟踪时**)
   - `pr-build/MR_BODY.md`、`pr-build/MR.md`
   - 都没有 → 停,告诉用户"先写 MR_BODY.md(默认放 `.agent/pr-assets/MR_BODY.md`,不进 git 跟踪)"。

   **MR_BODY.md 必须未 git 跟踪** —— 这是硬规则(AP-12)。找到文件后立刻跑
   `git ls-files --error-unmatch <path>`,**必须报错**(文件不在 index 里)。
   任何命中的搜索路径(包括 worktree 根的 `MR_BODY.md`),若文件被 git 跟踪,
   都按 AP-12 报"MR body 不应进 git 跟踪"并停。

2. **zh-CN 强制**:MR body 的自然语言段落必须是中文(团队工作语言)。代码、路径、
   commit subject、API 名、URL 保留英文。判定规则(任一不满足 → 停):
   - **硬规则**:`#` (H1 title) 和所有 `##` / `###` (H2/H3) 标题必须以中文开头
   - **软规则**:去掉 fenced code block + 行内 `code` + 完整 markdown link `[text](url)`
     之后,CJK 字符占总字符比例 ≥ **20%**(技术表格里的路径 / 命令会拉低比例,20%
     是 Chinese-dominant + technical 体的合理下限)
   - 启发式(python 优先,awk 在没有 python 的环境 fallback):
     ```python
     import re
     txt = open(MR_BODY).read()
     no_code = re.sub(r'```.*?```', '', txt, flags=re.S)
     no_code = re.sub(r'`[^`]*`', '', no_code)
     no_code = re.sub(r'\[[^\]]*\]\([^)]*\)', '', no_code)
     cjk = sum(1 for c in no_code if '一' <= c <= '鿿' or '㐀' <= c <= '䶿')
     ratio = cjk / max(len(no_code), 1)
     ```
   失败:
   ```
   ✗ zh-CN gate: <理由>
   → 团队工作语言是中文,自然语言段必须中文。代码/路径/链接保留英文。
   ```

3. 抽取证据引用 —— 用 python 解析 markdown link,只取 URL 部分,**不要贪婪吞 `](` 之类**:
   ```python
   import re
   txt = open(MR_BODY).read()
   # (1) markdown links: [text](url)  →  url
   links = re.findall(r'\[[^\]]*\]\(([^)]+)\)', txt)
   # (2) bare autolinks: <url>  →  url
   links += re.findall(r'<\s*([^<>]+\.(?:mp4|webm|mov|gif|png|jpg|jpeg|md|yaml|yml|json))\s*>', txt)
   # (3) bare paths that look like assets (e.g. `.agent/pr-assets/foo.md`)
   links += re.findall(r'(?<![\w/])([.\w/-]+/(?:pr-assets|workflows|screenshots)/\S+\.(?:md|yaml|yml|json|mp4|webm|mov|gif|png|jpg|jpeg))', txt)
   assets = sorted(set(l.strip() for l in links if l))
   ```
   资产类型映射:
   - `.mp4/.webm/.mov/.gif` → 视频
   - `.png/.jpg/.jpeg` → 截图
   - `/workflows/` 路径 或 `.workflow.md/.workflow.yaml` 后缀 → 草稿 workflow
   - `.agent/pr-assets/*.md` 含 mermaid / flowchart → 草稿 workflow(按 4.4 子评分表打勾)

   抽出来之后,每个 asset 跑 5.2 步骤 4 的未跟踪校验,以及 5.2 子评分。
   任何一步失败 → 报"哪个 asset 不过 + 怎么改"。

4. **路径白名单**(必须落在):
   - `.agent/pr-assets/`
   - `artifacts/`
   - `pr-build/`
   - `docs/qa/screenshots/`
   - `tmp/`、`/tmp/`

   绝对路径(`/Users/...` 或 `/tmp/...`)也接受,只要前缀落在白名单内或 `git check-ignore` 命中。

5. **未跟踪验证**(二选一):
   ```bash
   # 方案 A:git ls-files 必须报 not tracked
   git ls-files --error-unmatch <abs_path> 2>/dev/null && TRACKED=1 || TRACKED=0

   # 方案 B:git check-ignore 必须 exit 0
   git check-ignore <abs_path> 2>/dev/null
   ```
   接受条件:TRACKED=0 **或** check-ignore exit 0。两个都失败 → 报"`X` 被 git 跟踪,不算视觉证据"。

6. **0 引用 → 停**:"MR body 没引用任何视觉证据。MR 必须有至少一项:mp4 / webm / PNG / 草稿 workflow"。

7. **任一被跟踪 → 停**:"`X` 是 git 跟踪文件,不算视觉证据。挪到 `.agent/pr-assets/` 之类未跟踪目录"。

### §5.2 Quality sub-gate — 视觉证据能不能让 reviewer 一眼接受

**这是 v2 新增的子阶段**。Existence + Untracked 只是"有证据",quality 才是"有说服力的证据"。

对每个被引用的资产,**Read 它**(≤ 200 行直接读,> 200 行抽样读首 50 + 末 50 + 抽一个中段),
按下面的清单逐项打勾。打勾**有任一不过** → 停,告诉用户具体哪一项不过、要怎么改。

#### 5.2.1 草稿 workflow(`*.workflow.md` / `*.md` 含 mermaid / 状态机)

- [ ] **角色明确**:开头说"这个 workflow 是给谁看的"(reviewer / 维护者 / 未来自己)。
- [ ] **入口清晰**:第一段用一句话讲清"这个 skill 干啥、解决啥痛点"。
- [ ] **状态机/Mermaid 完整**:每个 phase 都有入口、决策点、出口,**没有"打哪个 phase 跳过"歧义**。
- [ ] **失败路径可读**:每个 gate 的失败提示都列在图旁边,不是埋在脚注里。
- [ ] **anti-pattern 在文末独立成段**,不是塞在 prose 里。

#### 5.2.2 截图(`*.png` / `*.jpg`)

- [ ] **聚焦改动点**:截图裁到 feature 本身,不要全页 chrome 占了 80%。
- [ ] **before/after 配对**(若适用):同尺寸、同视角、不同状态。
- [ ] **关键 UI 元素可读**:不糊,字号 ≥ 12 px @1x。
- [ ] **图说**:`MR_BODY.md` 里引用时附 1 行说明("展示 X 触发后 Y 出现")。

#### 5.2.3 视频(`*.mp4` / `*.webm`)

- [ ] **前 3 秒就说清"这是个啥"**:第一帧是带标题/光标定位的画面,不是空白屏。
- [ ] **演示路径单一**:不要在 30 秒里同时演示 3 个 feature。
- [ ] **关键操作慢放或加红框**:鼠标点击 / 滚动等可观察。
- [ ] **音频/字幕**:**不要依赖音频讲事**,关掉声音也能看懂。
- [ ] **时长 ≤ 60 秒**(若需要更长,拆成多段)。
- [ ] **格式可内嵌**:`<video controls>` 直接放在 MR body(GitLab 支持)或相对路径
      `<source src=".agent/pr-assets/demo.mp4">`。

#### 5.2.4 整体说服力

- [ ] **有人 30 秒内能讲清这个 MR 干了啥**(grep evidence + body,模拟 reviewer 第一遍扫)。
- [ ] **没有"截图其实是无关图"**、**"workflow 图是空模板"**、**"视频打不开"** 之类凑数迹象。
- [ ] **链接可点**:在 markdown 渲染器里能跳。

### §5.3 Phase 4 PASS 输出

四个 sub-gate 全过 → 打 "READY TO PUSH" 块:

```
✓ READY TO PUSH

  branch:     <HEAD 分支名>
  base:       origin/main
  divergence: +<ahead> / -<behind>
  files:      <code_count> code + <docs_count> docs/config
  evidence:   <逐行列出所有证据文件绝对路径>
  evidence-quality:  <PASS|FAIL — 4-项子评分>
  mr title:   <从 MR_BODY.md 第一行 # / ## 抽,或从分支名去掉前缀生成>
  body lang:  zh-CN (CJK ratio: <num>)

  下一步: git push -u origin <branch>  →  在 GitLab/GitHub 打开 MR
```

清掉 `STATE_FILE`。

---

## §6 Anti-patterns

- **AP-1** 文档 / 配置文件打全量 diff(违背用户"summary only"要求,reviewer 看不清代码)
- **AP-2** 静默 `git merge origin/main` 进用户分支(必须 non-destructive,用 scratch branch)
- **AP-3** 把 git 跟踪的 PNG 当视觉证据(必须在 `.agent/pr-assets/` 等未跟踪路径)
- **AP-4** 跳过 QA gate 直接打 diff(Phase 1 不过就该停;docs-only 例外见 §2)
- **AP-5** merge-tree 输出含 `<<<<<<<` 还报"clean"(必须 grep 显式判定)
- **AP-6** diff 一坨全塞(必须 CODE / DOCS 分桶,stat → code → docs 顺序)
- **AP-7** **凑数证据**:logo / 通用截图 / 黑屏视频 / 模板空 workflow / 404 链接 —
  视觉证据必须**真的能演示改动**,否则比没证据更糟
- **AP-8** **语言错配**:团队工作语言是 zh-CN,MR body 却用英文 prose 写
- **AP-9** **证据坏了不验**:引用了 `.png` 但没 Read / `file` 验过大小,推到 MR 才发现
  404。Phase 4 必须 Read 每个证据文件确认至少 1 KB + Mime 匹配后缀
- **AP-10** **冲突解决时无脑 `git pull` + `git merge`**:本仓库约定默认走
  `git rebase origin/main` 拿干净线性历史,merge 仅在用户明确要求时才用
- **AP-11** **stash 现场跑 rebase**:本地有未提交改动时 `git rebase` 会失败并
  报"uncommitted changes"。必须先 `git stash push -u`,rebase 完再 `git stash pop`,
  否则丢失工作
- **AP-12** **MR_BODY.md 进 git 跟踪**:MR body 是给 reviewer 看的"未跟踪证据"——
  放 `.agent/pr-assets/MR_BODY.md` 之类,推到 GitLab 用 API PUT,绝不放仓库。
  仓库里的 `MR_BODY.md` 会污染 reviewer 的 clone 工作区,且每次 amend 都要 re-PUT
- **AP-13** **WIP / fixup / squash 残留**:subject 行匹配 `^WIP[: ]` / `^fixup!` /
  `^squash!` / `^amend!` / `^tmp` 之一 → 提交前必须 `git rebase -i origin/main` 清理
- **AP-14** **"base behind N" 报告即放过**:Phase 3 看到 `−N behind` 就写
  "跟本 MR 无关"塞 §已知遗留。**默认应该 `git merge --ff-only origin/main`
  优先,失败再 `git rebase origin/main`;rebase 撞冲突进 §4 step 3 自动解决**(§4 step 2)
- **AP-15** **e2e 失败 defer 到 follow-up MR**:Phase 1.5 拿到的失败 case 不修,
  输出 "建议开独立 follow-up MR:# failing-case-file-list" 或 "defer to
  brand-sync MR"。**默认应该读失败清单、改源码(优先)/ 改测试(断言错),
  定向 e2e 验证,绿了继续;只有真正缺业务上下文的 case 才升用户**(§2.5)
- **AP-16** **冲突靠用户手工解决**:Phase 3 撞 `<<<<<<<` 时只"推荐 rebase +
  手工 add" / 写"需要用户解决冲突"就停。**默认应该先按 safe-category
  启发式(whitespace / 锁文件 / .gitignore 顺序 / 生成文件)自动解,再按
  MR intent 解析语义冲突;只有两侧改同一段代码且意图模糊才升用户**(§4 step 3)

---

## §7 References

- **`/worktree-qa`** — Phase 1 期望它的产物(diff → host → test → handoff)。它的 evidence
  通常落在 `.agent/pr-assets/`。
- **`winchannel-dev-standards`** — 本仓库的代码规范,reviewer 会按它卡。
- **`git merge-tree`** 三参数语法要求 git ≥ 2.38。低于该版本老语法 `git merge-tree A B`
  只会给文本差异,不能可靠判冲突,Phase 3 直接报"git 版本过低,请升级"。
- **GitLab Mermaid 渲染**:在 `.md` 文件里用 ` ```mermaid ` fenced block,GitLab 自动
  渲染成 SVG。`.agent/pr-assets/*.md` 同理。

## §8 Output style

zh-CN 简短。统计数字 / 命令输出 / 代码块 / 文件路径保留原始英文。
banner 用 `✓` / `✗` 前缀,不要花框。错误停在第一个失败 phase,不继续。
CJK 比例数、CJK 抽 awk 脚本见 §5.1 step 2。
