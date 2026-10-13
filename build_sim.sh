#!/bin/bash
# 模拟器核对版：只构建；安装与启动请使用 xcrun simctl
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
SRC="$ROOT/Sources"; WSRC="$ROOT/Widget"
PARTNER_DIR="$ROOT/Shared/PartnerSync"
BUILD="${YAOSHI_SIM_DIR:-/tmp/yaoshi-sim}"
APP="$BUILD/药时.app"
EXT="$APP/PlugIns/YaoShiWidget.appex"
SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
ARCH=$(uname -m)
mkdir -p "$APP" "$EXT"

echo "==> 编译主 App（模拟器）"
xcrun -sdk iphonesimulator swiftc -D YAOSHI_APP -target ${ARCH}-apple-ios17.0-simulator -sdk "$SDK" \
  -o "$APP/药时" "$SRC"/*.swift "$PARTNER_DIR"/*.swift

echo "==> 编译 Widget（模拟器）"
xcrun -sdk iphonesimulator swiftc -target ${ARCH}-apple-ios17.0-simulator -sdk "$SDK" \
  -application-extension -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$EXT/YaoShiWidget" \
  "$WSRC/Widget.swift" "$SRC/Models.swift" "$SRC/SharedStore.swift" "$SRC/DoseEngine.swift" "$SRC/DoseCurveModel.swift" "$SRC/LiveActivity.swift"

python3 - "$APP/Info.plist" <<'PY'
import plistlib,sys
plistlib.dump({
 "CFBundleDevelopmentRegion":"zh_CN","CFBundleDisplayName":"药时","CFBundleName":"药时",
 "CFBundleExecutable":"药时","CFBundleIdentifier":"com.richardhuo.yaoshi",
 "CFBundleInfoDictionaryVersion":"6.0","CFBundlePackageType":"APPL",
 "MinimumOSVersion":"17.0",
 "UILaunchScreen":{},"UIUserInterfaceStyle":"Dark",
 "UISupportedInterfaceOrientations":["UIInterfaceOrientationPortrait","UIInterfaceOrientationLandscapeLeft","UIInterfaceOrientationLandscapeRight"],
 "UISupportedInterfaceOrientations~ipad":["UIInterfaceOrientationPortrait","UIInterfaceOrientationPortraitUpsideDown","UIInterfaceOrientationLandscapeLeft","UIInterfaceOrientationLandscapeRight"],
 "NSSupportsLiveActivities":True,
 "CFBundleURLTypes":[{"CFBundleURLName":"com.richardhuo.yaoshi","CFBundleURLSchemes":["yaoshi"]}],"CFBundleSupportedPlatforms":["iPhoneSimulator"],
 "UIDeviceFamily":[1,2],
}, open(sys.argv[1],'wb'))
PY
python3 - "$EXT/Info.plist" <<'PY'
import plistlib,sys
plistlib.dump({
 "CFBundleDevelopmentRegion":"zh_CN","CFBundleDisplayName":"药时","CFBundleName":"YaoShiWidget",
 "CFBundleExecutable":"YaoShiWidget","CFBundleIdentifier":"com.richardhuo.yaoshi.widget",
 "CFBundleInfoDictionaryVersion":"6.0","CFBundlePackageType":"XPC!",
 "MinimumOSVersion":"17.0",
 "CFBundleSupportedPlatforms":["iPhoneSimulator"],"UIDeviceFamily":[1,2],
 "NSExtension":{"NSExtensionPointIdentifier":"com.apple.widgetkit-extension"},
}, open(sys.argv[1],'wb'))
PY

python3 "$ROOT/scripts/stamp_version.py" "$APP/Info.plist"
python3 "$ROOT/scripts/stamp_version.py" "$EXT/Info.plist" --parent "$APP/Info.plist"

xattr -cr "$APP"
codesign --force --sign - --generate-entitlement-der "$EXT"
codesign --force --sign - --generate-entitlement-der "$APP"
echo "==> 产物 $APP"
