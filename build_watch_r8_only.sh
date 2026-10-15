#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${YAOSHI_BUILD_DIR:-/tmp/yaoshi-r8-watch-only}"
WAPP="$BUILD/YaoShiWatchR8.app"
PHONE_ID='com.richardhuo.yaoshi.archive.v21012r8'
WATCH_ID="$PHONE_ID.watchkitapp"
IDENTITY="${YAOSHI_SIGNING_IDENTITY:?Set YAOSHI_SIGNING_IDENTITY to the Apple Development signing identity}"
PROFILE=$(python3 "$ROOT/scripts/select_profile.py" "P272ZF8FA9.$WATCH_ID")
mkdir -p "$WAPP" "$BUILD/iconwork"
SDK=$(xcrun --sdk watchos --show-sdk-path)
for ARCH in arm64 arm64_32; do
  xcrun --sdk watchos swiftc -target "$ARCH-apple-watchos10.0" -sdk "$SDK" \
    -parse-as-library -O -whole-module-optimization \
    "$ROOT"/Watch/*.swift "$ROOT/Sources/WatchProtocol.swift" -o "$BUILD/watch-$ARCH"
done
lipo -create "$BUILD/watch-arm64" "$BUILD/watch-arm64_32" -output "$WAPP/YaoShiWatchR8"
python3 - "$WAPP/Info.plist" "$WATCH_ID" "$PHONE_ID" <<'PY'
import plistlib,sys
path,wid,pid=sys.argv[1:]
info={'CFBundleDevelopmentRegion':'zh_CN','CFBundleDisplayName':'药时手表·R8',
      'CFBundleName':'YaoShiWatchR8','CFBundleExecutable':'YaoShiWatchR8',
      'CFBundleIdentifier':wid,'CFBundleInfoDictionaryVersion':'6.0','CFBundlePackageType':'APPL',
      'MinimumOSVersion':'10.0','UIDeviceFamily':[4],'WKApplication':True,
      'WKCompanionAppBundleIdentifier':pid,'WKRunsIndependentlyOfCompanionApp':False}
with open(path,'wb') as f:plistlib.dump(info,f,fmt=plistlib.FMT_BINARY)
PY
python3 "$ROOT/scripts/stamp_version.py" "$WAPP/Info.plist"
xcrun actool "$ROOT/icon/WatchAssets.xcassets" --compile "$WAPP" --platform watchos \
  --target-device watch --minimum-deployment-target 10.0 --app-icon AppIcon \
  --output-partial-info-plist "$BUILD/iconwork/partial.plist" --warnings --errors --notices --output-format human-readable-text
python3 - "$WAPP/Info.plist" "$BUILD/iconwork/partial.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],'rb') as f:info=plistlib.load(f)
with open(sys.argv[2],'rb') as f:partial=plistlib.load(f)
info.update(partial)
with open(sys.argv[1],'wb') as f:plistlib.dump(info,f,fmt=plistlib.FMT_BINARY)
PY
cp "$PROFILE" "$WAPP/embedded.mobileprovision"
security cms -D -i "$PROFILE" > "$BUILD/profile.plist"
/usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$BUILD/profile.plist" > "$BUILD/ent-watch.plist"
plutil -replace application-identifier -string "P272ZF8FA9.$WATCH_ID" "$BUILD/ent-watch.plist"
plutil -replace keychain-access-groups -json "[\"P272ZF8FA9.$WATCH_ID\"]" "$BUILD/ent-watch.plist"
xattr -cr "$WAPP"
codesign --force --sign "$IDENTITY" --entitlements "$BUILD/ent-watch.plist" --timestamp=none "$WAPP"
codesign --verify --strict --verbose=1 "$WAPP"
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$WAPP/Info.plist"
/usr/libexec/PlistBuddy -c 'Print :WKCompanionAppBundleIdentifier' "$WAPP/Info.plist"
echo "$WAPP"
