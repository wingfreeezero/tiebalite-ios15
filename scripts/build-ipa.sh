#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# TiebaLite iOS 15 · 一条命令出未签名 IPA（在 macOS 上跑）
#
#   bash scripts/build-ipa.sh                 # Release（默认）
#   bash scripts/build-ipa.sh debug           # Debug
#
# 需要：macOS + Xcode 26（SDK 26 才能编过 iOS 26 的液态玻璃分支，部署底线又是 15.0）
#      Homebrew（缺 bazelisk 时自动装）
#
# 产物：dist/TiebaLite-<版本>-iOS15.ipa（ad-hoc 签名 = 无签名口径）
#      装：TrollStore 直接导入；或 Sidekick(SideStore) / AltStore / Sideloadly 用自己 Apple ID 重签。
#
# 脚本里没有任何 Apple 账号/证书依赖：设备构建要的 provisioning_profile 是现场生成的占位件
# （rules_apple 在 --ios_signing_cert_name=- 时不拿它签名，见 codesigning_support.bzl:528）。
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

MODE_INPUT="${1:-release}"
case "$MODE_INPUT" in
  debug|Debug)   MODE=debug ;;
  *)             MODE=release ;;
esac

DEPLOYMENT_TARGET="15.0"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' TiebaLite/Info.plist)"
IPA_NAME="TiebaLite-${VERSION}-iOS15.ipa"
OUT_DIR="$REPO_ROOT/dist"

say() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

# ── 0. 环境 ──────────────────────────────────────────────────────────────────
say "0/6 环境检查"
[ "$(uname -s)" = "Darwin" ] || die "这条路只能在 macOS 上跑（要 xcodebuild / Apple 的 arm64 链接器）。"
command -v xcodebuild >/dev/null || die "没找到 xcodebuild：请装 Xcode 26 并 sudo xcode-select -s /Applications/Xcode.app"
xcodebuild -version
SDK_VER="$(xcrun --sdk iphoneos --show-sdk-version)"
echo "iPhoneOS SDK: $SDK_VER"

command -v bazel >/dev/null || {
  command -v brew >/dev/null || die "没找到 bazel，也没有 Homebrew：先装 https://brew.sh"
  say "安装 bazelisk"
  brew install bazelisk
}

# ── 1. 部署底线静态自检 ─────────────────────────────────────────────────────
say "1/6 部署底线自检（配置层必须是 15.0）"
grep -q 'ios_minimum_os=15.0' .bazelrc                      || die ".bazelrc 的 --ios_minimum_os 不是 15.0"
grep -q 'minimum_os_version = "15.0"' BUILD.bazel          || die "BUILD.bazel 的 minimum_os_version 不是 15.0"
if grep -q 'extensions = \[' BUILD.bazel; then
  die "BUILD.bazel 仍内嵌 appex —— iOS 15 上会装不上"
fi
/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' TiebaLite/Info.plist | grep -qx '15.0' \
  || die "TiebaLite/Info.plist 的 LSMinimumSystemVersion 不是 15.0"
echo "OK：三处配置 + Info.plist 都是 15.0，且没有内嵌 appex"

# ── 2. Bazel 缓存 ───────────────────────────────────────────────────────────
say "2/6 Bazel 磁盘/仓库缓存"
if [ ! -f .bazelrc.user ]; then
  cat > .bazelrc.user <<EOF
build --disk_cache=$HOME/.bazel_cache/disk
build --repository_cache=$HOME/.bazel_cache/repository
EOF
  echo "已写 .bazelrc.user（本机私有、已 gitignore）"
else
  echo "沿用已有 .bazelrc.user"
fi

# ── 3. 占位描述文件 ─────────────────────────────────────────────────────────
say "3/6 provisioning_profile 占位件"
mkdir -p Signing
keep=0
for out in Signing/app.mobileprovision Signing/ext.mobileprovision; do
  if [ -f "$out" ] && [ "$(wc -c < "$out" | tr -d ' ')" -gt 4096 ]; then keep=1; fi
done
if [ "$keep" = "1" ]; then
  echo "检测到已有的描述文件，保留不动"
else
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  cat > "$tmp/profile.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>AppIDName</key><string>BuildPlaceholder</string>
<key>ApplicationIdentifierPrefix</key><array><string>0000000000</string></array>
<key>CreationDate</key><date>2026-01-01T00:00:00Z</date>
<key>Platform</key><array><string>iOS</string></array>
<key>Entitlements</key><dict/>
<key>ExpirationDate</key><date>2040-01-01T00:00:00Z</date>
<key>Name</key><string>BuildPlaceholder</string>
<key>TeamIdentifier</key><array><string>0000000000</string></array>
<key>TeamName</key><string>BuildPlaceholder</string>
<key>TimeToLive</key><integer>3650</integer>
<key>UUID</key><string>00000000-0000-0000-0000-000000000000</string>
<key>Version</key><integer>1</integer>
</dict></plist>
PLIST
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/key.pem" -out "$tmp/cert.pem" \
    -days 3650 -subj "/CN=BuildPlaceholder" 2>/dev/null
  for out in Signing/app.mobileprovision Signing/ext.mobileprovision; do
    openssl smime -sign -in "$tmp/profile.plist" -signer "$tmp/cert.pem" -inkey "$tmp/key.pem" \
      -nodetach -outform der -out "$out" 2>/dev/null
    echo "wrote $out ($(wc -c < "$out" | tr -d ' ') bytes)"
  done
fi

# ── 4. 编译 ─────────────────────────────────────────────────────────────────
say "4/6 bazel build //:AppStripped --config=ci --config=$MODE"
bazel --version
bazel build //:AppStripped --config=ci --config="$MODE"

# ── 5. 打包 ─────────────────────────────────────────────────────────────────
say "5/6 打包 IPA"
rm -rf build && mkdir -p build "$OUT_DIR"
unzip -q bazel-bin/AppStripped.ipa -d build
( cd build && zip -qry "$IPA_NAME" Payload )
cp "build/$IPA_NAME" "$OUT_DIR/$IPA_NAME"
ls -lh "$OUT_DIR/$IPA_NAME"

# ── 6. 产物层自检 ───────────────────────────────────────────────────────────
say "6/6 产物自检（iOS 15 三道硬门槛）"
app="$(ls -d build/Payload/*.app)"
bin="$app/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Info.plist")"

min="$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$app/Info.plist")"
echo "Info.plist MinimumOSVersion = $min"
[ "$min" = "$DEPLOYMENT_TARGET" ] || die "MinimumOSVersion=$min，期望 $DEPLOYMENT_TARGET"

echo "Mach-O LC_BUILD_VERSION："
xcrun vtool -show-build "$bin" | sed -n '1,12p'
xcrun vtool -show-build "$bin" | grep -q "minos $DEPLOYMENT_TARGET" \
  || die "主二进制 minos 不是 $DEPLOYMENT_TARGET（iOS 15 装不上/起不来）"

if otool -L "$bin" | grep -q 'ActivityKit'; then
  die "主二进制仍链接 ActivityKit.framework —— iOS 15 的 dyld 会直接拒绝启动"
fi
if [ -d "$app/PlugIns" ]; then
  die "产物里仍有 PlugIns/（appex），iOS 15 装不上"
fi

cat <<EOF

✔ 完成
  产物： $OUT_DIR/$IPA_NAME
  版本： $VERSION   部署底线： iOS $DEPLOYMENT_TARGET   配置： $MODE
  安装： TrollStore 直接导入；或 SideStore / AltStore / Sideloadly 用自己的 Apple ID 重签
        （免费 Apple ID：签名 7 天有效、最多 3 个 App、无推送/App Groups）
EOF
