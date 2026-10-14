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

source "$ROOT/scripts/extract_app_intents.sh"
prepare_app_intents "$BUILD/app-intents" "$SRC"/*.swift "$PARTNER_DIR"/*.swift "$ROOT/Shared/TV/"*.swift

echo "==> 编译主 App（模拟器）"
xcrun -sdk iphonesimulator swiftc -D YAOSHI_APP -module-name 药时 -whole-module-optimization "${YAOSHI_INTENTS_FLAGS[@]}" -target ${ARCH}-apple-ios17.0-simulator -sdk "$SDK" \
  -o "$APP/药时" "$SRC"/*.swift "$PARTNER_DIR"/*.swift "$ROOT/Shared/TV/"*.swift

extract_app_intents "$APP" 药时 "$SDK" "${ARCH}-apple-ios17.0-simulator"

WIDGET_SOURCES=("$WSRC/Widget.swift" "$SRC/Models.swift" "$SRC/SharedStore.swift" "$SRC/DoseEngine.swift" "$SRC/DoseCurveModel.swift" "$SRC/LiveActivity.swift" "$SRC/RefreshLiveActivityIntent.swift")
prepare_app_intents "$BUILD/widget-intents" "${WIDGET_SOURCES[@]}"

echo "==> 编译 Widget（模拟器）"
xcrun -sdk iphonesimulator swiftc -module-name YaoShiWidget -whole-module-optimization "${YAOSHI_INTENTS_FLAGS[@]}" -target ${ARCH}-apple-ios17.0-simulator -sdk "$SDK" \
  -application-extension -Xlinker -e -Xlinker _NSExtensionMain \
  -o "$EXT/YaoShiWidget" \
  "${WIDGET_SOURCES[@]}"

extract_app_intents "$EXT" YaoShiWidget "$SDK" "${ARCH}-apple-ios17.0-simulator"

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
 "NSLocalNetworkUsageDescription":"经你确认后，与 Apple TV 配对并发送曲线数据。",
 "NSBonjourServices":["_yaoshi-tv-v1._tcp"],
 "NSSupportsLiveActivities":True,"NSSupportsLiveActivitiesFrequentUpdates":True,
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

if [ "${YAOSHI_BACKGROUND_LOCATION_EXPERIMENT:-0}" = "1" ]; then
  python3 - "$APP/Info.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as f: info = plistlib.load(f)
info['UIBackgroundModes'] = ['location']
info['NSLocationWhenInUseUsageDescription'] = '经你选择，使用定位服务进行最长15分钟的后台浓度刷新实验；不保存或上传坐标，可随时停止。'
info['NSLocationAlwaysAndWhenInUseUsageDescription'] = '经你选择，允许药时在后台使用定位服务，进行手动开启的最长15分钟浓度刷新实验；不保存或上传坐标，可随时停止。始终授权不代表永久运行。'
info['YaoShiBackgroundLocationExperiment'] = True
with open(path, 'wb') as f: plistlib.dump(info, f)
PY
fi
python3 "$ROOT/scripts/stamp_version.py" "$APP/Info.plist"
python3 "$ROOT/scripts/stamp_version.py" "$EXT/Info.plist" --parent "$APP/Info.plist"

xattr -cr "$APP"
codesign --force --sign - --generate-entitlement-der "$EXT"
codesign --force --sign - --generate-entitlement-der "$APP"
echo "==> 产物 $APP"
