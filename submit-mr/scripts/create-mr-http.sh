#!/usr/bin/env bash
# create-mr-http.sh — 用 HTTP(/HTTPS,由探活决定)调 GitLab API 创建 MR。
#
# 设计目标:
#   - 在 winchannel 内网(HTTPS EOF)环境下走 HTTP 也能工作
#   - 不 echo $GITLAB_TOKEN 真实值
#   - 不打印任何 cookie / refresh_token / access_token 到 stdout 或文件
#   - 失败时把诊断写到 stderr,exit 非 0
#
# 必需环境变量(skill 提供):
#   PROJECT_PATH  — 例 "datascience/win_ontology/win_brain"
#   SOURCE_BRANCH — 当前 worktree 的分支名
#   TARGET_BRANCH — 通常是 "main"
#   TITLE         — MR 标题(一般取 MR_BODY.md 首行)
#   BODY_FILE     — MR body 文件路径(UTF-8 markdown)
#
# 可选:
#   SUBMIT_MR_PROTO — "HTTPS" 或 "HTTP"(默认 "HTTP",winchannel 默认工作模式)
#   GITLAB_HOST     — 默认从当前 git remote 反推,可手动覆盖
#
# 必需:env $GITLAB_TOKEN
#
# 输出(stdout,简洁键值,便于父进程 grep):
#   MR_IID=<int>
#   MR_WEB_URL=<url>
#
# 用法示例:
#   SUBMIT_MR_PROTO=HTTP \
#   PROJECT_PATH="datascience/win_ontology/win_brain" \
#   SOURCE_BRANCH="worktree-foo" \
#   TARGET_BRANCH=main \
#   TITLE="feat(graph-plane): ..." \
#   BODY_FILE=".agent/pr-assets/MR_BODY.md" \
#   bash create-mr-http.sh
#
set -u

# ---------- 1. 参数检查 ----------
: "${PROJECT_PATH:?PROJECT_PATH required, e.g. datascience/win_ontology/win_brain}"
: "${SOURCE_BRANCH:?SOURCE_BRANCH required}"
: "${TARGET_BRANCH:=main}"
: "${TITLE:?TITLE required}"
: "${BODY_FILE:?BODY_FILE required}"
: "${GITLAB_TOKEN:?GITLAB_TOKEN env var required (not echoed)}"

if [ ! -f "$BODY_FILE" ]; then
  echo "create-mr-http: BODY_FILE not found: $BODY_FILE" >&2
  exit 64
fi

# ---------- 2. 推断 host + scheme ----------
PROTO="${SUBMIT_MR_PROTO:-HTTP}"
case "$PROTO" in
  HTTPS) SCHEME=https ;;
  HTTP)  SCHEME=http  ;;
  *)
    echo "create-mr-http: invalid SUBMIT_MR_PROTO='$PROTO' (want HTTPS or HTTP)" >&2
    exit 64
    ;;
esac

if [ -z "${GITLAB_HOST:-}" ]; then
  REMOTE=$(git remote get-url origin 2>/dev/null || true)
  GITLAB_HOST=$(printf '%s\n' "$REMOTE" \
    | sed -E 's#^(ssh://)?(git@)?([^:/@]+).*#\3#' \
    | sed -E 's#^https?://([^/]+).*#\1#')
fi
if [ -z "${GITLAB_HOST:-}" ]; then
  echo "create-mr-http: cannot infer GITLAB_HOST (set it explicitly)" >&2
  exit 65
fi

API="${SCHEME}://${GITLAB_HOST}/api/v4"

# ---------- 3. URL-encode project path (slash → %2F) ----------
encoded_path=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$PROJECT_PATH")

# ---------- 4. 取 project_id ----------
proj_resp=$(curl -sS --max-time 10 \
  -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  "${API}/projects/${encoded_path}" 2>/dev/null) || {
  echo "create-mr-http: project lookup failed (curl error)" >&2
  exit 66
}

PROJECT_ID=$(printf '%s' "$proj_resp" \
  | python3 -c "import json,sys
try:
  d = json.loads(sys.stdin.read())
  print(d.get('id', ''))
except Exception:
  print('')" 2>/dev/null)

if [ -z "$PROJECT_ID" ]; then
  # 再尝试一次 search(若 path 模糊)
  search_resp=$(curl -sS --max-time 10 \
    -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
    "${API}/projects?search=$(basename "$PROJECT_PATH")&membership=true" 2>/dev/null)
  PROJECT_ID=$(printf '%s' "$search_resp" \
    | python3 -c "import json,sys
try:
  arr = json.loads(sys.stdin.read())
  for p in arr:
    if p.get('path_with_namespace') == '$PROJECT_PATH':
      print(p['id']); break
except Exception:
  pass" 2>/dev/null)
fi

if [ -z "$PROJECT_ID" ]; then
  echo "create-mr-http: cannot resolve project_id for PROJECT_PATH=$PROJECT_PATH" >&2
  echo "  response head: $(printf '%s' "$proj_resp" | head -c 200 | sed 's/[\"]/_/g')" >&2
  exit 67
fi

# ---------- 5. 构造 payload,POST 创建 MR ----------
# 用 python json.dumps 转义 body,避免 quoting 出岔
PAYLOAD=$(python3 - <<PY
import json, os, pathlib
body = pathlib.Path(os.environ['BODY_FILE']).read_text(encoding='utf-8')
print(json.dumps({
  "source_branch": os.environ['SOURCE_BRANCH'],
  "target_branch": os.environ['TARGET_BRANCH'],
  "title":         os.environ['TITLE'],
  "description":   body,
  "remove_source_branch": False,
  "squash":               False,
}, ensure_ascii=False))
PY
)

create_resp=$(curl -sS --max-time 20 -X POST \
  -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "${API}/projects/${PROJECT_ID}/merge_requests" 2>/dev/null) || {
  echo "create-mr-http: MR create POST failed (curl error)" >&2
  exit 68
}

# ---------- 6. 解析 iid / web_url(同时容忍"已存在的同分支 MR") ----------
parsed=$(printf '%s' "$create_resp" | python3 - <<'PY'
import json, sys
d = json.loads(sys.stdin.read())
if isinstance(d, dict) and d.get('iid'):
    print(f"MR_IID={d['iid']}")
    print(f"MR_WEB_URL={d.get('web_url','')}")
elif isinstance(d, dict) and d.get('message'):
    # GitLab 报错(如 source branch 已有 open MR)
    print(f"ERROR={json.dumps(d['message'], ensure_ascii=False)}")
else:
    print("ERROR=unparseable")
PY
)

case "$parsed" in
  ERROR=*)
    msg=${parsed#ERROR=}
    echo "create-mr-http: server error: $msg" >&2
    # 同分支已有 open MR → 当成 idempotent 成功,去查回 iid
    if printf '%s' "$msg" | grep -qi "already exists"; then
      echo "  trying lookup existing open MR for source_branch=$SOURCE_BRANCH" >&2
      lookup=$(curl -sS --max-time 10 \
        -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
        "${API}/projects/${PROJECT_ID}/merge_requests?state=opened&source_branch=$(python3 -c 'import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))' "$SOURCE_BRANCH")")
      parsed2=$(printf '%s' "$lookup" | python3 - <<'PY'
import json, sys
arr = json.loads(sys.stdin.read())
if arr:
    print(f"MR_IID={arr[0]['iid']}")
    print(f"MR_WEB_URL={arr[0].get('web_url','')}")
PY
)
      if [ -n "$parsed2" ]; then
        printf '%s\n' "$parsed2"
        exit 0
      fi
    fi
    exit 69
    ;;
esac

# 正常路径
printf '%s\n' "$parsed"
exit 0
