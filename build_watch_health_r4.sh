#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${YAOSHI_BUILD_DIR:-/tmp/yaoshi-watch-health-r4}"
APP="$BUILD/YaoShiWatchHealthR4.app"
EXT="$APP/PlugIns/YaoShiCurveComplication.appex"
APP_ID='com.richardhuo.yaoshi.watch.standalone.airr4.healthr4'
EXT_ID="$APP_ID.widget"
GROUP_ID='group.com.richardhuo.yaoshi.watch.healthr4'
TEAM='P272ZF8FA9'
IDENTITY="${YAOSHI_SIGNING_IDENTITY:?Set YAOSHI_SIGNING_IDENTITY to a valid Apple Development identity}"

APP_PROFILE=$(python3 "$ROOT/scripts/select_profile.py" "$TEAM.$APP_ID")
EXT_PROFILE=$(python3 "$ROOT/scripts/select_profile.py" "$TEAM.$EXT_ID")
mkdir -p "$APP" "$EXT" "$BUILD/iconwork"

verify_profile() {
  local profile="$1" bundle="$2" need_health="$3" output="$4"
  security cms -D -i "$profile" > "$output"
  python3 - "$output" "$TEAM.$bundle" "$GROUP_ID" "$need_health" <<'PY'
import plistlib,sys
path,bundle,group,need_health=sys.argv[1:]
with open(path,'rb') as f: profile=plistlib.load(f)
e=profile.get('Entitlements',{})
assert e.get('application-identifier') == bundle, f'Exact profile required for {bundle}'
assert group in e.get('com.apple.security.application-groups',[]), 'App Group entitlement missing'
if need_health == 'yes':
    assert e.get('com.apple.developer.healthkit') is True, 'HealthKit entitlement missing'
PY
}
verify_profile "$APP_PROFILE" "$APP_ID" yes "$BUILD/profile-app.plist"
verify_profile "$EXT_PROFILE" "$EXT_ID" no "$BUILD/profile-ext.plist"

SDK=$(xcrun --sdk watchos --show-sdk-path)
for ARCH in arm64 arm64_32; do
  xcrun --sdk watchos swiftc -target "$ARCH-apple-watchos10.0" -sdk "$SDK" \
    -parse-as-library -O -whole-module-optimization \
    "$ROOT"/WatchStandalone/*.swift -o "$BUILD/app-$ARCH"
  xcrun --sdk watchos swiftc -target "$ARCH-apple-watchos10.0" -sdk "$SDK" \
    -application-extension -parse-as-library -O -whole-module-optimization \
    "$ROOT/WatchStandalone/StandaloneModel.swift" \
    "$ROOT/WatchStandalone/DoseJournal.swift" \
    "$ROOT/WatchStandalone/ComplicationSnapshot.swift" \
    "$ROOT/WatchComplication/CurveComplication.swift" -o "$BUILD/widget-$ARCH"
done
lipo -create "$BUILD/app-arm64" "$BUILD/app-arm64_32" -output "$APP/YaoShiWatchHealthR4"
lipo -create "$BUILD/widget-arm64" "$BUILD/widget-arm64_32" -output "$EXT/YaoShiCurveComplication"

python3 - "$APP/Info.plist" "$EXT/Info.plist" "$APP_ID" "$EXT_ID" <<'PY'
import plistlib,sys
app_path,ext_path,app_id,ext_id=sys.argv[1:]
base={'CFBundleDevelopmentRegion':'zh_CN','CFBundleInfoDictionaryVersion':'6.0',
      'CFBundleShortVersionString':'2.10.12','CFBundleVersion':'55','MinimumOSVersion':'10.0'}
app=base|{'CFBundleDisplayName':'药时手表·健康 R4','CFBundleName':'YaoShiWatchHealthR4',
          'CFBundleExecutable':'YaoShiWatchHealthR4','CFBundleIdentifier':app_id,
          'CFBundlePackageType':'APPL','UIDeviceFamily':[4],'WKApplication':True,'WKWatchOnly':True,
          'NSHealthShareUsageDescription':'读取心率，在药时手表界面显示最近测量值与所选时段平均值。'}
ext=base|{'CFBundleDisplayName':'药时浓度与曲线','CFBundleName':'YaoShiCurveComplication',
          'CFBundleExecutable':'YaoShiCurveComplication','CFBundleIdentifier':ext_id,
          'CFBundlePackageType':'XPC!','NSExtension':{'NSExtensionPointIdentifier':'com.apple.widgetkit-extension'}}
for path,value in [(app_path,app),(ext_path,ext)]:
    with open(path,'wb') as f:plistlib.dump(value,f,fmt=plistlib.FMT_BINARY)
PY

xcrun actool "$ROOT/icon/WatchAssets.xcassets" --compile "$APP" --platform watchos \
  --target-device watch --minimum-deployment-target 10.0 --app-icon AppIcon \
  --output-partial-info-plist "$BUILD/iconwork/partial.plist" --warnings --errors --notices --output-format human-readable-text
python3 - "$APP/Info.plist" "$BUILD/iconwork/partial.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],'rb') as f:info=plistlib.load(f)
with open(sys.argv[2],'rb') as f:info.update(plistlib.load(f))
with open(sys.argv[1],'wb') as f:plistlib.dump(info,f,fmt=plistlib.FMT_BINARY)
PY

cp "$APP_PROFILE" "$APP/embedded.mobileprovision"
cp "$EXT_PROFILE" "$EXT/embedded.mobileprovision"
python3 - "$BUILD/profile-app.plist" "$BUILD/profile-ext.plist" "$BUILD/ent-app.plist" "$BUILD/ent-ext.plist" <<'PY'
import plistlib,sys
for profile_path,out_path,app in [(sys.argv[1],sys.argv[3],True),(sys.argv[2],sys.argv[4],False)]:
    with open(profile_path,'rb') as f: granted=plistlib.load(f)['Entitlements']
    keys=['application-identifier','com.apple.developer.team-identifier',
          'com.apple.security.application-groups','get-task-allow','keychain-access-groups']
    if app: keys.append('com.apple.developer.healthkit')
    minimal={key:granted[key] for key in keys if key in granted}
    with open(out_path,'wb') as f: plistlib.dump(minimal,f,fmt=plistlib.FMT_XML)
PY
xattr -cr "$APP"
codesign --force --sign "$IDENTITY" --entitlements "$BUILD/ent-ext.plist" --timestamp=none "$EXT"
codesign --force --sign "$IDENTITY" --entitlements "$BUILD/ent-app.plist" --timestamp=none "$APP"
codesign --verify --strict --verbose=1 "$EXT"
codesign --verify --strict --verbose=1 "$APP"
echo "$APP"
