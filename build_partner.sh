#!/bin/bash
# Build the separate, read-only spouse app and its encrypted push service extension.
set -euo pipefail

ROOTDIR="$(cd "$(dirname "$0")" && pwd)"
PARTNER_DIR="$ROOTDIR/Shared/PartnerSync"
BUILD="${YAOSHI_PARTNER_BUILD_DIR:-/tmp/yaoshi-partner-build}"
APP="$BUILD/药时伴侣.app"
EXT="$APP/PlugIns/YaoShiNotificationService.appex"
BUNDLE_ID="com.richardhuio.yaoshi.partner"
EXT_BUNDLE_ID="$BUNDLE_ID.notifications"
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
IDENTITY="${YAOSHI_SIGNING_IDENTITY:?请设置 YAOSHI_SIGNING_IDENTITY 为本机 Apple Development 签名身份}"
KEYCHAIN_GROUP="P272ZF8FA9.com.richardhuo.yaoshi.partner.partner"

if [ -f "$APP/药时伴侣" ]; then
  echo "已有构建产物，请用 YAOSHI_PARTNER_BUILD_DIR 指定新的空目录。"
  exit 1
fi
mkdir -p "$APP" "$EXT"
SDK=$(xcrun --sdk iphoneos --show-sdk-path)

echo "==> 查找签名描述文件"
WILDCARD=""
PUSH_PROFILE=""
for f in "$PROFILE_DIR"/*.mobileprovision; do
  [ -f "$f" ] || continue
  appid=$(security cms -D -i "$f" 2>/dev/null | plutil -extract Entitlements.application-identifier raw - 2>/dev/null || true)
  aps=$(security cms -D -i "$f" 2>/dev/null | plutil -extract Entitlements.aps-environment raw - 2>/dev/null || true)
  if [ "$appid" = "P272ZF8FA9.*" ] && [ -z "$WILDCARD" ]; then WILDCARD="$f"; fi
  if [ "$appid" = "P272ZF8FA9.$BUNDLE_ID" ] && [ "$aps" = "development" ]; then PUSH_PROFILE="$f"; fi
done
[ -z "$WILDCARD" ] && { echo "找不到通配描述文件"; exit 1; }

PUSH_ENABLED=0
PUSH_ENVIRONMENT=""
APP_PROFILE="$WILDCARD"
if [ -n "$PUSH_PROFILE" ]; then
  PUSH_ENABLED=1
  PUSH_ENVIRONMENT="development"
  APP_PROFILE="$PUSH_PROFILE"
  echo "找到开发推送描述文件：$(basename "$PUSH_PROFILE")"
else
  echo "没有含 aps-environment 的显式开发描述文件；本次构建可检查界面，远程推送会保持关闭。"
fi

echo "==> 编译只读伴侣 App"
compile_partner_app() {
  xcrun -sdk iphoneos swiftc \
  -D YAOSHI_PARTNER "$@" \
  -target arm64-apple-ios17.0 \
  -sdk "$SDK" \
  -O -whole-module-optimization \
  -o "$APP/药时伴侣" \
  "$ROOTDIR/Sources/Models.swift" \
  "$ROOTDIR/Sources/PartnerMedication.swift" \
  "$ROOTDIR/Sources/YaoShiPartnerApp.swift" \
  "$PARTNER_DIR/PartnerSyncCore.swift" \
  "$PARTNER_DIR/PartnerSharingSettingsView.swift"
}
if [ "$PUSH_ENABLED" = "1" ]; then
  compile_partner_app -D YAOSHI_REMOTE_PUSH
else
  compile_partner_app
fi

cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleDisplayName</key><string>药时共享</string>
  <key>CFBundleName</key><string>药时共享</string>
  <key>CFBundleExecutable</key><string>药时伴侣</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>MinimumOSVersion</key><string>17.0</string>
  <key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
  <key>UISupportedInterfaceOrientations</key><array><string>UIInterfaceOrientationPortrait</string></array>
  <key>UIUserInterfaceStyle</key><string>Dark</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
    <key>CFBundleURLSchemes</key><array><string>yaoshi-partner</string></array>
  </dict></array>
</dict>
</plist>
PLIST
if [ "$PUSH_ENABLED" = "1" ]; then
  /usr/libexec/PlistBuddy -c "Add :APNsEnvironment string $PUSH_ENVIRONMENT" "$APP/Info.plist"
fi
/usr/bin/plutil -convert binary1 "$APP/Info.plist"

echo "==> 编译加密通知扩展"
xcrun -sdk iphoneos swiftc \
  -D YAOSHI_PARTNER \
  -target arm64-apple-ios17.0 \
  -sdk "$SDK" \
  -O -whole-module-optimization \
  -module-name YaoShiPartnerNotificationService \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$EXT/YaoShiNotificationService" \
  "$ROOTDIR/NotificationService/NotificationService.swift" \
  "$PARTNER_DIR/PartnerSyncCore.swift"

cat > "$EXT/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleDisplayName</key><string>药时共享通知</string>
  <key>CFBundleExecutable</key><string>YaoShiNotificationService</string>
  <key>CFBundleIdentifier</key><string>$EXT_BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>YaoShiNotificationService</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>MinimumOSVersion</key><string>17.0</string>
  <key>NSExtension</key><dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.usernotifications.service</string>
    <key>NSExtensionPrincipalClass</key><string>YaoShiPartnerNotificationService.NotificationService</string>
  </dict>
</dict>
</plist>
PLIST
/usr/bin/plutil -convert binary1 "$EXT/Info.plist"

echo "==> 嵌入图标"
ICONWORK="$BUILD/iconwork"
mkdir -p "$ICONWORK"
xcrun actool "$ROOTDIR/icon/YSAssets.xcassets" --compile "$APP" \
  --platform iphoneos --minimum-deployment-target 17.0 \
  --app-icon AppIcon --output-partial-info-plist "$ICONWORK/partial.plist" >/dev/null 2>&1
python3 - "$APP/Info.plist" "$ICONWORK/partial.plist" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as f: info = plistlib.load(f)
with open(sys.argv[2], 'rb') as f: partial = plistlib.load(f)
info.update(partial)
with open(sys.argv[1], 'wb') as f: plistlib.dump(info, f, fmt=plistlib.FMT_BINARY)
PY

sign_bundle() {
  local bundle="$1" bundle_id="$2" profile="$3" entitlements_path="$4"
  cp "$profile" "$bundle/embedded.mobileprovision"
  security cms -D -i "$profile" > "$BUILD/profile.plist"
  python3 - "$BUILD/profile.plist" "$KEYCHAIN_GROUP" "$bundle_id" <<'PY'
import fnmatch, plistlib, sys
with open(sys.argv[1], 'rb') as f:
    profile = plistlib.load(f)
entitlements = profile.get('Entitlements', {})
groups = entitlements.get('keychain-access-groups', [])
if not any(fnmatch.fnmatchcase(sys.argv[2], allowed) for allowed in groups):
    raise SystemExit(f"描述文件不允许 Keychain group {sys.argv[2]}；请在 Apple Developer 配置 Keychain Sharing 后重新下载 profile。")
app_id = entitlements.get('application-identifier', '')
if not fnmatch.fnmatchcase(f"P272ZF8FA9.{sys.argv[3]}", app_id):
    raise SystemExit(f"描述文件的 application-identifier 不匹配 {sys.argv[3]}。")
PY
  /usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$BUILD/profile.plist" > "$entitlements_path"
  plutil -replace application-identifier -string "P272ZF8FA9.$bundle_id" "$entitlements_path"
  plutil -replace keychain-access-groups -json "[\"$KEYCHAIN_GROUP\"]" "$entitlements_path"
  xattr -cr "$bundle"
  codesign --force --sign "$IDENTITY" --entitlements "$entitlements_path" --timestamp=none "$bundle"
}

python3 "$ROOTDIR/scripts/stamp_version.py" "$APP/Info.plist" --component partner
python3 "$ROOTDIR/scripts/stamp_version.py" "$EXT/Info.plist" --component partner --parent "$APP/Info.plist"

echo "==> 签名通知扩展与伴侣 App"
sign_bundle "$EXT" "$EXT_BUNDLE_ID" "$WILDCARD" "$BUILD/extension-entitlements.plist"
sign_bundle "$APP" "$BUNDLE_ID" "$APP_PROFILE" "$BUILD/app-entitlements.plist"
codesign --verify --deep --verbose "$APP"
echo "==> 产物: $APP"
du -sh "$APP"
