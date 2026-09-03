#!/bin/sh
# sync-wb2-fork.sh —— 在本地工作副本中同步上游 + 重放 LOCAL PATCH
# 用法: sh sync-wb2-fork.sh
set -eu
cd "$(dirname "$0")/.."

# 1. 同步前先确认本地功能文件存在且未被 .gitignore 屏蔽
for f in internal/server/web_extra.go internal/server/local_api.go internal/login/login.go internal/server/web/index.html; do
  [ -f "$f" ] || { echo "MISSING 本地文件: $f"; exit 1; }
done
echo "✓ 本地功能文件齐备（web_extra/local_api/login/web assets）"

# 2. 拉取上游最新（upstr remote 不存在则临时用 URL fetch 到 FETCH_HEAD）
if git remote get-url upstr >/dev/null 2>&1; then
  git -c http.sslVerify=false fetch --quiet upstr master 2>&1 | tail -1 || true
  UPREF="upstr/master"
else
  git -c http.sslVerify=false fetch --quiet https://github.com/Sliverkiss/workbuddy2api.git master 2>&1 | tail -1 || true
  UPREF="FETCH_HEAD"
fi

# 3. 需要同步的 SAFE 文件（精确白名单，不含 fpk / 本地文件）
FILES="README.md cmd/server/config.go cmd/server/config_test.go config.example.json go.mod go.sum internal/pool/bench_test.go internal/pool/pool.go internal/pool/pool_test.go internal/redisstore/redisstore.go internal/redisstore/redisstore_test.go internal/server/handler.go internal/server/handler_test.go internal/session/session.go internal/session/session_test.go internal/upstream/client.go cmd/server/main.go"
MISSING=$(for f in $FILES; do git cat-file -e "$UPREF:$f" 2>/dev/null || echo "$f"; done)
[ -z "$MISSING" ] || { echo "上游缺少文件: $MISSING"; exit 1; }

git checkout "$UPREF" -- $FILES
echo "✓ 已同步 $(echo $FILES | wc -w | tr -d ' ') 个上游文件（fpk/本地文件保留）"

# 4. 重放 LOCAL PATCH（main.go 被覆盖后补丁丢失，重新插入）
python3 - cmd/server/main.go << 'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
if "NewLocalAPI" in s:
    print("✓ main.go 已含最新 LOCAL PATCH，跳过")
    raise SystemExit(0)
if "LOCAL PATCH" in s:
    for ln in s.split("\n"):
        if "LOCAL PATCH" in ln or "WrapWeb(h," in ln or "var handler http.Handler" in ln:
            s = s.replace(ln + "\n", "", 1)
anchor = '''\tsrv := &http.Server{
\t\tAddr:              cfg.Listen,
\t\tHandler:           h,'''
patch = '''\t// ── LOCAL PATCH: 内置前端 + 本地API(签到/扫码登录)（由 sync-upstream.sh 自动重放；WEB_DISABLED=1 可关闭）----
\tlocalAPI := server.NewLocalAPI(p, up, func() { go sch.RunCheckinNow() }, cfg.AuthDir, os.Getenv("LOGIN_DISABLED") != "1")
\tvar handler http.Handler = server.WrapWeb(h, os.Getenv("WEB_DISABLED") != "1", localAPI)

\tsrv := &http.Server{
\t\tAddr:              cfg.Listen,
\t\tHandler:           handler,'''
if s.count(anchor) == 1:
    open(p, "w", encoding="utf-8").write(s.replace(anchor, patch, 1))
    print("✓ LOCAL PATCH 已重放")
else:
    print("WARN: 锚点未找到(" + str(s.count(anchor)) + ")，需手工检查 main.go")
PYEOF

# 5. 检查 fork 依赖的上游符号是否仍存在（编译兜底）
echo "--- 核对 fork 本地代码依赖的上游符号 ---"
check_sym() {  # $1 文件 $2 正则
  git show "$UPREF:$1" | grep -qE "$2" && echo "✓ $1 保留 $2" || echo "✗ $1 缺少 $2"
}
check_sym internal/pool/pool.go "func \(p \*Pool\) Add\(a \*auth.Auth\)"
check_sym internal/pool/pool.go "func \(p \*Pool\) SetCredits\(uid string, credits int64\)"
check_sym internal/upstream/client.go "func \(c \*Client\) UserResource"
check_sym internal/scheduler/scheduler.go "func \(s \*Scheduler\) RunCheckinNow"
check_sym cmd/server/config.go "AuthDir"
echo "--- 核对 main.go 补丁变量作用域 ---"
grep -qE "^\tp := pool.New\(" cmd/server/main.go && echo "✓ p"
grep -qE "^\tup := upstream.New\(\)" cmd/server/main.go && echo "✓ up"
grep -qE "^\tsch := scheduler.New\(" cmd/server/main.go && echo "✓ sch"
grep -qE "^\th := server.NewHandler\(" cmd/server/main.go && echo "✓ h"
grep -qE "^\tgo sch.Run\(ctx\)" cmd/server/main.go && echo "✓ go sch.Run(ctx)"

echo ""
echo "=== 同步完成。下一步: 编译验证 x86/arm 交叉构建 + fnpack 打包 ==="
