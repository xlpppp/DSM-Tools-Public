#!/usr/bin/env bash
# 在 Mac 上编译 NAS 助手。
#   ./scripts/build.sh            生成未签名 IPA：build/NASHelper-unsigned.ipa
#   ./scripts/build.sh simulator  编译并在 iOS 模拟器中运行（无需证书）
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "未找到 Xcode：请先从 App Store 安装 Xcode 并打开一次。" >&2
  exit 1
fi
if ! command -v xcodegen >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    echo "安装 XcodeGen…"
    brew install xcodegen
  else
    echo "未找到 Homebrew：请先安装 Homebrew，再执行 brew install xcodegen。" >&2
    exit 1
  fi
fi

echo "生成 Xcode 工程…"
xcodegen generate --quiet

mode="${1:-ipa}"

if [[ "$mode" == "simulator" ]]; then
  udid=$(xcrun simctl list devices available | grep -m1 -E "^[[:space:]]+iPhone" | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
  if [[ -z "$udid" ]]; then
    echo "没有可用的 iPhone 模拟器：在 Xcode › Settings › Components 下载 iOS 模拟器。" >&2
    exit 1
  fi
  echo "编译模拟器版本…"
  xcodebuild -project NASHelper.xcodeproj -scheme NASHelper -configuration Debug \
    -destination "id=$udid" -derivedDataPath build/DerivedData \
    -skipPackagePluginValidation -skipMacroValidation -quiet build
  xcrun simctl boot "$udid" 2>/dev/null || true
  open -a Simulator
  xcrun simctl install "$udid" build/DerivedData/Build/Products/Debug-iphonesimulator/NASHelper.app
  xcrun simctl launch "$udid" com.xlpppp.nashelper >/dev/null
  echo "已在模拟器中启动。"
  exit 0
fi

echo "编译真机版本（未签名）…"
xcodebuild -project NASHelper.xcodeproj -scheme NASHelper -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData \
  -skipPackagePluginValidation -skipMacroValidation -quiet \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build

rm -rf build/Payload build/NASHelper-unsigned.ipa
mkdir -p build/Payload
cp -R build/DerivedData/Build/Products/Release-iphoneos/NASHelper.app build/Payload/
(cd build && zip -qry NASHelper-unsigned.ipa Payload)
rm -rf build/Payload
echo "完成：$(pwd)/build/NASHelper-unsigned.ipa"
