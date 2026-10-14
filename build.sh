#!/bin/bash
# 药时 App 构建脚本（主 App）
# 源码在 iCloud 文稿区，构建产物一律放 /tmp，避免 fileproviderd 打 xattr 破坏签名
set -e

ROOTDIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOTDIR/Sources"
PARTNER_DIR="$ROOTDIR/Shared/PartnerSync"
BUILD="${YAOSHI_BUILD_DIR:-/tmp/yaoshi-build}"
APP="$BUILD/药时.app"
BUNDLE_ID="com.richardhuo.yaoshi.archive.v21012r3"
PROFILE_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
IDENTITY="${YAOSHI_SIGNING_IDENTITY:?请设置 YAOSHI_SIGNING_IDENTITY 为本机 Apple Development 签名身份}"

if [ -f "$APP/药时" ]; then
  echo "已有构建产物，请用 YAOSHI_BUILD_DIR 指定新的空目录。"
  exit 1
fi
mkdir -p "$APP"

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
echo "SDK: $SDK"

source "$ROOTDIR/scripts/extract_app_intents.sh"
prepare_app_intents "$BUILD/app-intents" "$SRC"/*.swift "$PARTNER_DIR"/*.swift "$ROOTDIR/Shared/TV/"*.swift

echo "==> 编译主 App"
xcrun -sdk iphoneos swiftc \
  -D YAOSHI_APP -module-name 药时 "${YAOSHI_INTENTS_FLAGS[@]}" \
  -target arm64-apple-ios17.0 \
  -sdk "$SDK" \
  -O -whole-module-optimization \
  -o "$APP/药时" \
  "$SRC"/*.swift "$PARTNER_DIR"/*.swift "$ROOTDIR/Shared/TV/"*.swift

extract_app_intents "$APP" 药时 "$SDK" arm64-apple-ios17.0

echo "==> 写 Info.plist"
cat > "$APP/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleDisplayName</key><string>药时后台·R3</string>
  <key>CFBundleName</key><string>药时</string>
  <key>CFBundleExecutable</key><string>药时</string>
  <key>CFBundleIdentifier</key><string>com.richardhuo.yaoshi.archive.v21012r3</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>NSLocalNetworkUsageDescription</key><string>经你确认后，与同一网络的 Apple TV 配对并发送曲线数据。</string>
  <key>NSBonjourServices</key><array><string>_yaoshi-tv-v1._tcp</string></array>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>MinimumOSVersion</key><string>17.0</string>
  <key>UILaunchScreen</key>
  <dict><key>UIColorName</key><string></string></dict>
  <key>UIRequiredDeviceCapabilities</key><array><string>arm64</string></array>
  <key>UISupportedInterfaceOrientations</key>
  <array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
  </array>
  <key>UISupportedInterfaceOrientations~ipad</key>
  <array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationPortraitUpsideDown</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
  </array>
  <key>UIUserInterfaceStyle</key><string>Dark</string>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key><string>com.richardhuo.yaoshi.archive.v21012r3</string>
      <key>CFBundleURLSchemes</key><array><string>yaoshi-21012r3</string><string>yaoshi-21012r3-partner</string></array>
    </dict>
  </array>
  <key>NSSupportsLiveActivities</key><true/>
  <key>NSSupportsLiveActivitiesFrequentUpdates</key><true/>
</dict>
</plist>
PLIST
if [ "${YAOSHI_BACKGROUND_LOCATION_EXPERIMENT:-1}" = "1" ]; then
  python3 - "$APP/Info.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as f: info = plistlib.load(f)
info['UIBackgroundModes'] = ['location']
info['NSLocationWhenInUseUsageDescription'] = '使用定位服务持续进行后台浓度刷新；不保存或上传坐标，可在设置中关闭。'
info['NSLocationAlwaysAndWhenInUseUsageDescription'] = '允许药时在后台使用定位服务持续刷新浓度；不保存或上传坐标，可在设置中关闭。实际运行受系统调度影响。'
info['YaoShiBackgroundLocationExperiment'] = True
with open(path, 'wb') as f: plistlib.dump(info, f)
PY
fi
python3 "$ROOTDIR/scripts/stamp_version.py" "$APP/Info.plist"

echo "==> 编译并嵌入图标"
ICONWORK="$BUILD/iconwork"
mkdir -p "$ICONWORK"
xcrun actool "$ROOTDIR/icon/YSAssets.xcassets" --compile "$APP" \
  --platform iphoneos --minimum-deployment-target 17.0 \
  --app-icon AppIcon --output-partial-info-plist "$ICONWORK/partial.plist" >/dev/null 2>&1
if [ -f "$ICONWORK/partial.plist" ]; then
  python3 - "$APP/Info.plist" "$ICONWORK/partial.plist" <<'PY'
import plistlib, sys
info=plistlib.load(open(sys.argv[1],'rb'))
part=plistlib.load(open(sys.argv[2],'rb'))
info.update(part)
plistlib.dump(info, open(sys.argv[1],'wb'), fmt=plistlib.FMT_BINARY)
print("  图标键已并入 Info.plist:", ", ".join(part.keys()))
PY
fi

echo "==> 检查签名描述文件"
PROFILE_ARGS=("P272ZF8FA9.$BUNDLE_ID")
if [ "${YAOSHI_REQUIRE_PUSH:-0}" = "1" ]; then PROFILE_ARGS+=(--require-push); fi
if [ -n "${YAOSHI_APP_PROFILE:-}" ]; then PROFILE_ARGS+=(--profile "$YAOSHI_APP_PROFILE"); fi
APP_PROFILE=$(python3 "$ROOTDIR/scripts/select_profile.py" "${PROFILE_ARGS[@]}")
echo "使用: $(basename "$APP_PROFILE")"
cp "$APP_PROFILE" "$APP/embedded.mobileprovision"

echo "==> 生成 entitlements"
security cms -D -i "$APP_PROFILE" > "$BUILD/profile.plist"
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$BUILD/profile.plist" > "$BUILD/ent.plist"
plutil -replace application-identifier -string "P272ZF8FA9.$BUNDLE_ID" "$BUILD/ent.plist"
# 描述文件的通配符表示签名许可，安装包必须声明实际使用的具体共享组。
plutil -replace keychain-access-groups -json '["P272ZF8FA9.com.richardhuo.yaoshi.archive.v21012r3","P272ZF8FA9.com.richardhuo.yaoshi.archive.v21012r3.shared","P272ZF8FA9.com.richardhuo.yaoshi.archive.v21012r3.partner.owner"]' "$BUILD/ent.plist"


echo "==> 清 xattr 并签名"
xattr -cr "$APP"
codesign --force --sign "$IDENTITY" --entitlements "$BUILD/ent.plist" --timestamp=none "$APP"
codesign --verify --verbose "$APP" && echo "签名校验通过"

echo "==> 产物: $APP"
du -sh "$APP"
