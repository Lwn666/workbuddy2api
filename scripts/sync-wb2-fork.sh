#!/bin/sh
# sync-wb2-fork.sh —— 同步上游 + 重放 LOCAL PATCH + 保留本地功能
# 策略: 整树同步上游, 然后恢复 fork 独有文件
# 用法:
#   sh sync-wb2-fork.sh              # 本地
#   sh sync-wb2-fork.sh --ci         # CI 模式: 失败时 exit 1, 输出 SYNC_NO_CHANGE/SYNC_CHANGED
set -eu
cd "$(dirname "$0")/.."

CI=0; [ "${1:-}" = "--ci" ] && CI=1
HAS_ERROR=0
err() { echo "✗ $*" >&2; HAS_ERROR=1; [ "$CI" = "1" ] && exit 1; }

# 1. 确认本地功能文件存在
for f in internal/server/web_extra.go internal/server/local_api.go internal/login/login.go internal/server/web/index.html; do
  [ -f "$f" ] || { echo "MISSING $f"; exit 1; }
done
echo "✓ 本地功能文件齐备"

# 2. 拉取上游最新
if git remote get-url upstr >/dev/null 2>&1; then
  git -c http.sslVerify=false fetch --quiet upstr master 2>&1 | tail -1 || true
  UPREF="upstr/master"
else
  git -c http.sslVerify=false fetch --quiet https://github.com/Sliverkiss/workbuddy2api.git master 2>&1 | tail -1 || true
  UPREF="FETCH_HEAD"
fi

# 3. 整树同步上游（用 . 覆盖所有文件，包含新文件）
echo "=== 同步上游整树 ==="
git checkout "$UPREF" -- .
echo "✓ 上游文件已同步"

# 4. 恢复 fork 独有文件（不被上游覆盖）
echo "=== 恢复 fork 本地文件 ==="
RESTORE="
.github/
Dockerfile
README.md
.dockerignore
.gitignore
credit.sh
login.sh
signin.sh
docker-compose.yml
internal/server/web/
internal/server/web_extra.go
internal/server/local_api.go
internal/login/
scripts/
wb2api-fpk/
wb2api-fpk-arm/
workbuddy2api-*.fpk
"
for p in $RESTORE; do
  case "$p" in
    scripts/)
      # 只恢复上游也有的 scripts 文件，避免覆盖正在运行的自身
      for sf in sync-upstream.sh sync-auths.sh; do
        git checkout HEAD -- "scripts/$sf" 2>/dev/null || true
      done
      ;;
    *) git checkout HEAD -- "$p" 2>/dev/null || true ;;
  esac
done
# 恢复后确保关键文件存在
[ -f internal/server/web_extra.go ] || err "web_extra.go 恢复失败"
[ -f internal/server/local_api.go ] || err "local_api.go 恢复失败"
echo "✓ fork 本地文件已恢复"

# 5. 重放 LOCAL PATCH
echo "=== 重放 LOCAL PATCH ==="
python3 - cmd/server/main.go << 'PYEOF' || exit 1
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
if "NewLocalAPI" in s:
    print("✓ 已含最新 LOCAL PATCH，跳过")
    raise SystemExit(0)
anchor = '\tsrv := &http.Server{\n\t\tAddr:              cfg.Listen,\n\t\tHandler:           h,'
patch = '\t// ── LOCAL PATCH: 内置前端 + 本地API(签到/扫码登录)（由 sync-upstream.sh 自动重放；WEB_DISABLED=1 可关闭）----\n\tlocalAPI := server.NewLocalAPI(p, up, func() { go sch.RunCheckinNow() }, cfg.AuthDir, os.Getenv("LOGIN_DISABLED") != "1")\n\tvar handler http.Handler = server.WrapWeb(h, os.Getenv("WEB_DISABLED") != "1", localAPI)\n\n' + anchor.replace('Handler:           h,', 'Handler:           handler,')
if s.count(anchor) == 1:
    s = s.replace(anchor, patch, 1)
    open(p, "w", encoding="utf-8").write(s)
    print("✓ LOCAL PATCH 已重放")
else:
    print("WARN: 锚点未找到(" + str(s.count(anchor)) + ")，需手工检查 main.go")
    raise SystemExit(1)
PYEOF

# 6. 检查 fork 依赖的上游符号
echo "=== 核对上游符号 ==="
check_sym() {
  git show "$UPREF:$1" | grep -qE "$2" && echo "✓ $1 保留 $2" || err "$1 缺少 $2"
}
check_sym internal/pool/pool.go "func \(p \*Pool\) Add\(a \*auth.Auth\)"
check_sym internal/pool/pool.go "func \(p \*Pool\) SetCredits\(uid string, credits int64\)"
check_sym internal/upstream/client.go "func \(c \*Client\) UserResource"
check_sym internal/scheduler/scheduler.go "func \(s \*Scheduler\) RunCheckinNow"
check_sym cmd/server/config.go "AuthDir"
echo "--- 核对补丁变量作用域 ---"
grep -qE "^\tp := pool.New\(" cmd/server/main.go || err "main.go 缺 p"
grep -qE "^\tup := upstream.New\(\)" cmd/server/main.go || err "main.go 缺 up"
grep -qE "^\tsch := scheduler.New\(" cmd/server/main.go || err "main.go 缺 sch"
grep -qE "^\th := server.NewHandler\(" cmd/server/main.go || err "main.go 缺 h"
grep -qE "NewLocalAPI" cmd/server/main.go || err "main.go 缺 NewLocalAPI 补丁"

# 7. CI 输出
if [ "$CI" = "1" ]; then
  if git diff --quiet HEAD; then
    echo "SYNC_NO_CHANGE=1"
    echo "已是最新，无变更。"
  else
    echo "SYNC_CHANGED=1"
    echo "上游有更新，工作区已同步。"
  fi
fi

[ "$HAS_ERROR" = "0" ] || exit 1
echo ""
echo "=== 同步完成 ==="