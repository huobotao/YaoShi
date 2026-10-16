#!/bin/bash
# 编译 Widget extension（小组件 + 灵动岛/实时活动）并嵌进主 App，然后整体重签
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/Sources"
WSRC="$ROOT/Widget"
BUILD="${YAOSHI_BUILD_DIR:-/tmp/yaoshi-iphone-heart-r1}"
APP="$BUILD/药时.app"
EXT="$APP/PlugIns/YaoShiWidget.appex"
IDENTITY="${YAOSHI_SIGNING_IDENTITY:?请设置 YAOSHI_SIGNING_IDENTITY 为本机 Apple Development 签名身份}"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)

[ -d "$APP" ] || { echo "主 App 还没构建，先跑 build_heart_r1.sh"; exit 1; }
python3 "$ROOT/scripts/prepare_heart_r1_build.py"
mkdir -p "$EXT"

source "$ROOT/scripts/extract_app_intents.sh"
WIDGET_SOURCES=("$WSRC/Widget.swift" "$SRC/Models.swift" "$SRC/SharedStore.swift" "$SRC/DoseEngine.swift" "$SRC/DoseCurveModel.swift" "$SRC/LiveActivity.swift" "$SRC/RefreshLiveActivityIntent.swift")
prepare_app_intents "$BUILD/widget-intents" "${WIDGET_SOURCES[@]}"

echo "==> 编译 Widget extension"
# ⚠️ 入口必须是系统的 _NSExtensionMain（见 BeiYun 2026-09-06 血泪）：
# 不带这个入口时扩展进程一启动就在 ExtensionFoundation 处 SIGTRAP，
# 小组件、锁屏卡、灵动岛全部空白且没有任何界面报错。
xcrun -sdk iphoneos swiftc \
  -target arm64-apple-ios17.0 -sdk "$SDK" \
  -module-name YaoShiWidget "${YAOSHI_INTENTS_FLAGS[@]}" \
  -O -whole-module-optimization -application-extension \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -Xlinker -rpath -Xlinker @executable_path/Frameworks \
  -Xlinker -rpath -Xlinker @executable_path/../../Frameworks \
  -F "$SDK/System/Library/Frameworks" \
  -o "$EXT/YaoShiWidget" \
  "${WIDGET_SOURCES[@]}"

[ -f "$EXT/YaoShiWidget" ] || { echo "Widget 二进制没生成"; exit 1; }

extract_app_intents "$EXT" YaoShiWidget "$SDK" arm64-apple-ios17.0

echo "==> Widget Info.plist"
cat > "$EXT/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleDisplayName</key><string>药时心率·R1</string>
  <key>CFBundleName</key><string>YaoShiWidget</string>
  <key>CFBundleExecutable</key><string>YaoShiWidget</string>
  <key>CFBundleIdentifier</key><string>com.richardhuo.yaoshi.archive.v21012heartr1.widget</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>MinimumOSVersion</key><string>17.0</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
  <key>DTPlatformName</key><string>iphoneos</string>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>NSExtension</key>
  <dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string>
  </dict>
</dict>
</plist>
PLIST
python3 "$ROOT/scripts/stamp_version.py" "$EXT/Info.plist" --parent "$APP/Info.plist"

echo "==> Widget entitlements"
# An explicit push-enabled app profile cannot sign the widget's different ID.
WIDGET_PROFILE_ARGS=("P272ZF8FA9.com.richardhuo.yaoshi.archive.v21012heartr1.widget")
if [ -n "${YAOSHI_WIDGET_PROFILE:-}" ]; then WIDGET_PROFILE_ARGS+=(--profile "$YAOSHI_WIDGET_PROFILE"); fi
WIDGET_PROFILE=$(python3 "$ROOT/scripts/select_profile.py" "${WIDGET_PROFILE_ARGS[@]}")
security cms -D -i "$WIDGET_PROFILE" > "$BUILD/profile-widget.plist"
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$BUILD/profile-widget.plist" > "$BUILD/ent-widget.plist"
plutil -replace application-identifier -string "P272ZF8FA9.com.richardhuo.yaoshi.archive.v21012heartr1.widget" "$BUILD/ent-widget.plist"
plutil -replace keychain-access-groups -json '["P272ZF8FA9.com.richardhuo.yaoshi.archive.v21012heartr1.widget","P272ZF8FA9.com.richardhuo.yaoshi.archive.v21012heartr1.shared"]' "$BUILD/ent-widget.plist"
cp "$WIDGET_PROFILE" "$EXT/embedded.mobileprovision"

echo "==> 签 Widget"
xattr -cr "$EXT"
codesign --force --sign "$IDENTITY" --entitlements "$BUILD/ent-widget.plist" --timestamp=none "$EXT"

echo "==> 重签主 App（包含新加的 PlugIns）"
xattr -cr "$APP"
codesign --force --sign "$IDENTITY" --entitlements "$BUILD/ent.plist" --timestamp=none "$APP"
codesign --verify --deep --verbose=1 "$APP" && echo "整包签名校验通过"
