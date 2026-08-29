#!/bin/sh
# sync-upstream.sh —— 安全同步上游 workbuddy2api 更新（POSIX sh，兼容 BusyBox ash）
#
# 背景：本仓库与上游无共同祖先，直接 merge 会全冲突。策略：按文件定向覆盖。
# 本地定制 = 前端 pure-static 方案，与上游交集仅 main.go 的 LOCAL PATCH（3 行）。
#
# 用法：
#   sh sync-upstream.sh          预览模式：只看差异，不改文件
#   sh sync-upstream.sh --apply  执行：覆盖安全文件 + 自动重放 LOCAL PATCH
set -eu

cd "$(dirname "$0")"
# 从脚本位置向上查找仓库根（脚本可放仓库根或 scripts/ 下）
while [ ! -d .git ] && [ "$(pwd)" != "/" ]; do cd ..; done

# 本地新增文件/目录（上游没有），空格分隔，永不触碰
LOCAL_ONLY="internal/server/web internal/server/web_extra.go scripts"

# 含 LOCAL PATCH 的文件（自动覆盖上游后重放补丁）
AUTO_PATCH="cmd/server/main.go"
# 需手工合并的文件（无补丁逻辑）
PROTECTED=""

APPLY=0
if [ "${1:-}" = "--apply" ]; then APPLY=1; fi

echo "=== 1. 拉取上游最新 ==="
git -c http.sslVerify=false fetch upstream 2>&1 | tail -3

echo ""
echo "=== 2. 上游相对本仓库的改动 ==="
# 无共同祖先：必须用两点语法直接比较两棵树
CHANGED=$(git diff --name-only HEAD upstream/master)
if [ -z "$CHANGED" ]; then
  echo "无差异：已是上游最新。"
  exit 0
fi
echo "$CHANGED"
echo "--- 共 $(echo "$CHANGED" | wc -l | tr -d ' ') 个文件 ---"

echo ""
echo "=== 3. 分类 ==="
SAFE=""
MANUAL=""
SKIP=""
PATCH_FILES=""  # AUTO_PATCH 文件列表（覆盖后需重放补丁）
for f in $CHANGED; do
  hit=0
  for loc in $LOCAL_ONLY; do
    case "$f" in
      "$loc"|"$loc"/*) hit=1; break ;;
    esac
  done
  if [ $hit -eq 1 ]; then
    SKIP="$SKIP $f"
    continue
  fi
  # AUTO_PATCH 文件归入自动覆盖（覆盖后自动重放 LOCAL PATCH）
  hit=0
  for p in $AUTO_PATCH; do
    if [ "$f" = "$p" ]; then hit=1; break; fi
  done
  if [ $hit -eq 1 ]; then
    SAFE="$SAFE $f"
    PATCH_FILES="$PATCH_FILES $f"
    continue
  fi
  hit=0
  for p in $PROTECTED; do
    if [ "$f" = "$p" ]; then hit=1; break; fi
  done
  if [ $hit -eq 1 ]; then
    MANUAL="$MANUAL $f"
  else
    SAFE="$SAFE $f"
  fi
done

echo "[自动覆盖 · 安全]"
if [ -n "$SAFE" ]; then
  for s in $SAFE; do
    # 跳过 AUTO_PATCH 文件（单独显示）
    is_patch=0
    for p in $PATCH_FILES; do [ "$s" = "$p" ] && is_patch=1; done
    [ $is_patch -eq 0 ] && echo "  $s"
  done
else
  echo "  (无)"
fi
if [ -n "$PATCH_FILES" ]; then
  echo ""
  echo "[自动覆盖 + 重放补丁]"
  for p in $PATCH_FILES; do echo "  $p"; done
fi
echo ""
echo "[手工合并 · 含 LOCAL PATCH]"
if [ -n "$MANUAL" ]; then for m in $MANUAL; do echo "  $m"; done; else echo "  (无)"; fi
if [ -n "$SKIP" ]; then
  echo ""
  echo "[跳过 · 本地新增]"
  for k in $SKIP; do echo "  $k"; done
fi

if [ $APPLY -eq 0 ]; then
  echo ""
  echo "=== 预览模式结束（未修改任何文件）==="
  echo "确认无误后执行： sh $(basename "$0") --apply"
  exit 0
fi

echo ""
echo "=== 4. 执行覆盖 ==="
if [ -n "$SAFE" ]; then
  git checkout upstream/master -- $SAFE
  echo "已覆盖 $(echo $SAFE | wc -w | tr -d ' ') 个安全文件"
else
  echo "无安全文件需要覆盖。"
fi

# 自动重放 LOCAL PATCH（AUTO_PATCH 文件覆盖后补丁丢失，需重新插入）
if [ -n "$PATCH_FILES" ]; then
  echo ""
  echo "=== 5. 自动重放 LOCAL PATCH ==="
  for pf in $PATCH_FILES; do
    python3 - "$pf" << 'PYEOF'
import sys
p = sys.argv[1]
try:
    s = open(p, encoding="utf-8").read()
except FileNotFoundError:
    print(f"SKIP: {p} 不存在"); raise SystemExit(0)

if "LOCAL PATCH" in s:
    print(f"{p}: 已存在 LOCAL PATCH，跳过"); raise SystemExit(0)

anchor = '''\tsrv := &http.Server{
\t\tAddr:              cfg.Listen,
\t\tHandler:           h,'''
patch = '''\t// ── LOCAL PATCH: 内置前端（由 sync-upstream.sh 自动重放；WEB_DISABLED=1 可关闭）----
\tvar handler http.Handler = server.WrapWeb(h, os.Getenv("WEB_DISABLED") != "1")

\tsrv := &http.Server{
\t\tAddr:              cfg.Listen,
\t\tHandler:           handler,'''
if s.count(anchor) == 1:
    s = s.replace(anchor, patch, 1)
    open(p, "w", encoding="utf-8").write(s)
    print(f"{p}: LOCAL PATCH 已重放")
else:
    print(f"WARN: {p} 锚点未找到，需手工检查")
PYEOF
  done
fi

echo ""
echo "=== 6. 验证编译 ==="
echo "docker build -t workbuddy2api:test . 2>&1 | tail -5"

echo ""
echo "=== 7. 提交 ==="
echo "git add -A && git commit -m 'sync upstream: <说明>'"
