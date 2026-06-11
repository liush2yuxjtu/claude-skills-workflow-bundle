#!/usr/bin/env bash
# probe-gitlab.sh — 在 winchannel 内网 GitLab(或任意 GitLab)上做协议探活。
#
# 输入:
#   $1 = remote URL(`git remote get-url origin` 的输出)
#        - 支持 ssh://git@host:port/...  /  git@host:path  /  https://host/...  /  http://host/...
# 输出(stdout):HTTPS | HTTP | OAUTH
# 退出码:0 = 探到一条可用路径;非 0 = 都不通,把诊断写到 stderr
#
# 安全:
#   - 只读 $GITLAB_TOKEN 做"是否带 token"的存在性测试,**不 echo 真实 token**
#   - 若 $GITLAB_TOKEN 不在 env,只做匿名 200 探测(/api/v4/version),不强制要 token
#
# 决策依据(本 skill §7 的工作模式):
#   - winchannel 内网 gitlab008.its.winchannel.net 的 HTTPS 端口经常 EOF / timeout
#   - HTTP 端口通,且 PRIVATE-TOKEN 走 HTTP 也接受(确认过)
#   - 都不通才退到 OAuth(本脚本不发起 OAuth,只回退标识让 skill 走 MCP / playwright)
set -u

REMOTE="${1:-}"
if [ -z "$REMOTE" ]; then
  echo "usage: probe-gitlab.sh <remote_url>" >&2
  exit 64
fi

# 从 remote URL 抽 host(去掉 scheme / user / path / .git 后缀)
host=$(printf '%s\n' "$REMOTE" \
  | sed -E 's#^(ssh://)?(git@)?([^:/@]+).*#\3#' \
  | sed -E 's#^https?://([^/]+).*#\1#')

if [ -z "$host" ]; then
  echo "probe-gitlab: cannot extract host from REMOTE='$REMOTE'" >&2
  exit 65
fi

# 是否带 token:仅看变量是否非空,**不打印值**
if [ -n "${GITLAB_TOKEN:-}" ]; then
  AUTH_ARG=(-H "PRIVATE-TOKEN: ${GITLAB_TOKEN}")
else
  AUTH_ARG=()
fi

# 探一条 URL 是否"可用"(200 / 401 都算通,403 同理):
#   - 200 = 匿名可读
#   - 401 = 服务在,但要凭据(后续脚本会带 PRIVATE-TOKEN)
#   - 403 = 服务在,但权限不够(同上)
#   - 其它 / 超时 / EOF / conn refused → 不通
probe() {
  local url="$1"
  local code
  code=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' \
    "${AUTH_ARG[@]}" "$url" 2>/dev/null) || code=000
  case "$code" in
    200|401|403) return 0 ;;
    *) return 1 ;;
  esac
}

# 1) HTTPS
if probe "https://$host/api/v4/version"; then
  echo HTTPS
  exit 0
fi

# 2) HTTP(winchannel 内网默认工作路径)
if probe "http://$host/api/v4/version"; then
  echo HTTP
  exit 0
fi

# 3) 都不通 → 让 skill 上层退化到 OAuth MCP / playwright
echo OAUTH
echo "probe-gitlab: HTTPS + HTTP API both unreachable for host=$host; falling back to OAuth" >&2
exit 0
