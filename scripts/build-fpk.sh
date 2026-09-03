#!/bin/sh
# build-fpk.sh —— 从源码构建 wb2api 交叉二进制 + 组装 fnOS fpk 包
# 用法:
#   sh scripts/build-fpk.sh              # 版本号自动 +0.0.1，输出 dist/
#   sh scripts/build-fpk.sh --ci         # CI 模式
#   sh scripts/build-fpk.sh 2.0.0        # 指定版本号
set -eu
cd "$(dirname "$0")/.."

VERSION=""
for a in "$@"; do
  case "$a" in
    --ci) ;;
    *) VERSION="$a" ;;
  esac
done

# --- 版本号：默认读取 manifest 并递增 patch ---
if [ -z "$VERSION" ]; then
  CUR=$(grep '^version=' wb2api-fpk/manifest | cut -d= -f2)
  VERSION=$(echo "$CUR" | awk -F. '{printf "%d.%d.%d", $1, $2, $3+1}')
fi
echo "=== 构建版本: $VERSION ==="
mkdir -p dist

# --- 1. 交叉编译两架构二进制（已存在 dist 产物则跳过） ---
NEED_GO=0
for arch in x86 arm; do
  [ -f "dist/wb2api-$arch" ] || NEED_GO=1
done
if [ "$NEED_GO" = "1" ]; then
  if ! command -v go >/dev/null 2>&1; then
    echo "✗ 未找到 go 工具链且 dist/ 无现成二进制"; exit 1
  fi
  echo "=== 编译 x86_64 ==="
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags="-s -w" -o dist/wb2api-x86 ./cmd/server
  echo "=== 编译 arm64 ==="
  CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags="-s -w" -o dist/wb2api-arm ./cmd/server
else
  echo "=== 使用 dist/ 现成二进制（跳过编译） ==="
fi
ls -la dist/wb2api-x86 dist/wb2api-arm

# --- 2. 更新 manifest 版本 + 替换二进制 ---
for arch in x86 arm; do
  dir="wb2api-fpk"; [ "$arch" = "arm" ] && dir="wb2api-fpk-arm"
  sed -i "s/^version=.*/version=$VERSION/" "$dir/manifest"
  echo "✓ $dir/manifest -> version=$VERSION"
  cp "dist/wb2api-$arch" "$dir/app/server/wb2api"
  chmod 755 "$dir/app/server/wb2api"
  echo "✓ $dir/app/server/wb2api 已更新 ($(stat -c%s "$dir/app/server/wb2api") bytes)"
done

# --- 3. 组装 fpk（纯 tar+gzip，与 fnpack 产物结构一致） ---
build_one() {  # $1 工程目录  $2 输出文件名
  pkgdir="$1"; out="$2"
  tmp=$(mktemp -d)
  # 复制工程根内容（排除内嵌旧 fpk）
  tar -C "$pkgdir" -cf - --exclude='./workbuddy2api.fpk' manifest cmd config wizard ICON.PNG ICON_256.PNG app 2>/dev/null | tar -C "$tmp" -xf -
  # 组装 app.tgz：server/ ui/ 来自 app/，config/ 冗余并入根 config/（复刻 fnpack）
  # 注意: iSH workspace 丢权限位，wb2api 二进制单独 tar 强制 755，其余正常 644
  mkdir -p "$tmp/inner/server"
  cp "$tmp/app/server/wb2api" "$tmp/inner/server/wb2api"
  cp -r "$tmp/app/ui" "$tmp/inner/ui"
  cp -r "$tmp/config" "$tmp/inner/config"
  # 目录统一 755、普通文件 644、wb2api 二进制 755
  find "$tmp/inner" -type d -exec chmod 755 {} +
  find "$tmp/inner" -type f ! -name wb2api -exec chmod 644 {} +
  chmod 755 "$tmp/inner/server/wb2api"
  (cd "$tmp/inner" && tar -czf "$tmp/app.tgz" server ui config)
  rm -rf "$tmp/inner" "$tmp/app"
  # 外层 gzip：根为 manifest cmd config wizard ICON*.PNG app.tgz
  absout="$(pwd)/$out"
  (cd "$tmp" && tar -czf "$absout" manifest cmd config wizard ICON.PNG ICON_256.PNG app.tgz)
  rm -rf "$tmp"
  echo "✓ 生成 $out ($(stat -c%s "$out") bytes)"
}

build_one wb2api-fpk     "dist/workbuddy2api-$VERSION-x86.fpk"
build_one wb2api-fpk-arm "dist/workbuddy2api-$VERSION-arm.fpk"

echo ""
echo "=== 打包完成 ==="
ls -la dist/*.fpk
echo "VERSION=$VERSION"
