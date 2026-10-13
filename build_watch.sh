#!/bin/bash
# Build the Watch companion and embed it before re-signing the iPhone bundle.
# Simulator: YAOSHI_WATCH_SIMULATOR=1 YAOSHI_BUILD_DIR=/tmp/yaoshi-watch-sim bash build_watch.sh
set -euo pipefail
ROOTDIR="$(cd "$(dirname "$0")" && pwd)"
BUILD="${YAOSHI_BUILD_DIR:-/tmp/yaoshi-build}"
APP="$BUILD/药时.app"
SIMULATOR="${YAOSHI_WATCH_SIMULATOR:-0}"
IDENTITY="${YAOSHI_SIGNING_IDENTITY:-}"
BUNDLE_ID="com.richardhuo.yaoshi.watchkitapp"
mkdir -p "$BUILD"
if [ "$SIMULATOR" = 1 ]; then
  SDK_NAME=watchsimulator
  WAPP="$BUILD/YaoShiWatch.app"
else
  : "${YAOSHI_SIGNING_IDENTITY:?请设置 YAOSHI_SIGNING_IDENTITY 为本机 Apple Development 签名身份}"
  SDK_NAME=watchos
  [ -f "$APP/Info.plist" ] && [ -f "$BUILD/ent.plist" ] || { echo "先在同一 YAOSHI_BUILD_DIR 运行 build.sh"; exit 1; }
  WAPP="$APP/Watch/YaoShiWatch.app"
fi
mkdir -p "$WAPP"
WSDK=$(xcrun --sdk "$SDK_NAME" --show-sdk-path)
SOURCES=("$ROOTDIR/Watch/"*.swift "$ROOTDIR/Sources/WatchProtocol.swift")
if [ "$SIMULATOR" = 1 ]; then
  xcrun --sdk watchsimulator swiftc -target arm64-apple-watchos10.0-simulator -sdk "$WSDK" \
    -parse-as-library -O -whole-module-optimization -o "$WAPP/YaoShiWatch" "${SOURCES[@]}"
else
  for ARCH in arm64 arm64_32; do
    xcrun --sdk watchos swiftc -target "$ARCH-apple-watchos10.0" -sdk "$WSDK" \
      -parse-as-library -O -whole-module-optimization -o "$BUILD/yaoshi_watch_$ARCH" "${SOURCES[@]}"
  done
  lipo -create "$BUILD/yaoshi_watch_arm64" "$BUILD/yaoshi_watch_arm64_32" -output "$WAPP/YaoShiWatch"
fi
python3 - "$WAPP/Info.plist" <<'PY'
import plistlib, sys
info = {
 'CFBundleDevelopmentRegion':'zh_CN', 'CFBundleDisplayName':'药时', 'CFBundleName':'药时',
 'CFBundleExecutable':'YaoShiWatch','CFBundleIdentifier':'com.richardhuo.yaoshi.watchkitapp',
 'CFBundleInfoDictionaryVersion':'6.0','CFBundlePackageType':'APPL',
 'MinimumOSVersion':'10.0','UIDeviceFamily':[4],'WKApplication':True,
 'WKCompanionAppBundleIdentifier':'com.richardhuo.yaoshi',
 'WKRunsIndependentlyOfCompanionApp':False,
}
with open(sys.argv[1],'wb') as f: plistlib.dump(info,f,fmt=plistlib.FMT_BINARY)
PY
if [ "$SIMULATOR" = 1 ]; then
  python3 "$ROOTDIR/scripts/stamp_version.py" "$WAPP/Info.plist"
else
  python3 "$ROOTDIR/scripts/stamp_version.py" "$WAPP/Info.plist" --parent "$APP/Info.plist"
fi
ICONWORK="$BUILD/watch-iconwork"
mkdir -p "$ICONWORK"
xcrun actool "$ROOTDIR/icon/WatchAssets.xcassets" --compile "$WAPP" \
  --platform "$SDK_NAME" --target-device watch --minimum-deployment-target 10.0 \
  --app-icon AppIcon --output-partial-info-plist "$ICONWORK/partial.plist" \
  --warnings --errors --notices --output-format human-readable-text
[ -f "$WAPP/Assets.car" ] && [ -f "$ICONWORK/partial.plist" ] || { echo "Watch 图标产物缺失"; exit 1; }
python3 - "$WAPP/Info.plist" "$ICONWORK/partial.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1],'rb') as f: info=plistlib.load(f)
with open(sys.argv[2],'rb') as f: partial=plistlib.load(f)
assert partial.get('CFBundleIcons',{}).get('CFBundlePrimaryIcon',{}).get('CFBundleIconName') == 'AppIcon', 'Watch 图标键缺失'
info.update(partial)
with open(sys.argv[1],'wb') as f: plistlib.dump(info,f,fmt=plistlib.FMT_BINARY)
PY
xcrun assetutil --validate-file "$WAPP/Assets.car"
xattr -cr "$WAPP"
if [ "$SIMULATOR" = 1 ]; then
  codesign --force --sign - --timestamp=none "$WAPP"
else
  cp "$APP/embedded.mobileprovision" "$WAPP/embedded.mobileprovision"
  cp "$BUILD/ent.plist" "$BUILD/ent-watch.plist"
  plutil -replace application-identifier -string "P272ZF8FA9.$BUNDLE_ID" "$BUILD/ent-watch.plist"
  plutil -replace keychain-access-groups -json '["P272ZF8FA9.com.richardhuo.yaoshi.watchkitapp"]' "$BUILD/ent-watch.plist"
  codesign --force --sign "$IDENTITY" --entitlements "$BUILD/ent-watch.plist" --timestamp=none "$WAPP"
  xattr -cr "$APP"
  codesign --force --sign "$IDENTITY" --entitlements "$BUILD/ent.plist" --timestamp=none "$APP"
  codesign --verify --deep --strict --verbose=1 "$APP"
fi
codesign --verify --strict --verbose=1 "$WAPP"
echo "Watch 构建完成: $WAPP"
