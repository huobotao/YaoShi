#!/bin/bash
# R7 Watch app and WidgetKit complication; always use an isolated build directory.
# Simulator: YAOSHI_WATCH_SIMULATOR=1 YAOSHI_BUILD_DIR=/tmp/yaoshi-r7-watch bash build_watch.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${YAOSHI_BUILD_DIR:-/tmp/yaoshi-r7-build}"
PHONE="$BUILD/药时.app"
SIM="${YAOSHI_WATCH_SIMULATOR:-0}"
WATCH_ID="com.richardhuo.yaoshi.archive.v21012r7.watchkitapp"
COMP_ID="$WATCH_ID.complication"
PHONE_ID="com.richardhuo.yaoshi.archive.v21012r7"
GROUP="group.com.richardhuo.yaoshi.archive.v21012r7.watch"
if [ "$SIM" = 1 ]; then
  SDK=watchsimulator
  WAPP="$BUILD/YaoShiWatchR7.app"
  TARGETS=(arm64-apple-watchos10.0-simulator)
else
  : "${YAOSHI_SIGNING_IDENTITY:?需要 Apple Development 签名身份}"
  [ -f "$PHONE/Info.plist" ] && [ -f "$BUILD/ent.plist" ] || { echo '先在同一独立目录构建 R7 iPhone App'; exit 1; }
  ACTUAL_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PHONE/Info.plist")
  [ "$ACTUAL_ID" = "$PHONE_ID" ] || { echo "拒绝嵌入非 R7 主 App: $ACTUAL_ID"; exit 1; }
  SDK=watchos
  WAPP="$PHONE/Watch/YaoShiWatchR7.app"
  TARGETS=(arm64-apple-watchos10.0 arm64_32-apple-watchos10.0)
fi
EXT="$WAPP/PlugIns/YaoShiWatchComplication.appex"
mkdir -p "$WAPP" "$EXT"
WSDK=$(xcrun --sdk "$SDK" --show-sdk-path)
compile() {
  local name="$1" output="$2"; shift 2
  local sources=("$@") binaries=()
  for target in "${TARGETS[@]}"; do
    local arch=${target%%-*}
    local binary="$BUILD/$name-$arch"
    xcrun --sdk "$SDK" swiftc -target "$target" -sdk "$WSDK" -parse-as-library -O -whole-module-optimization \
      "${sources[@]}" -o "$binary"
    binaries+=("$binary")
  done
  if [ ${#binaries[@]} -eq 1 ]; then cp "${binaries[0]}" "$output"
  else lipo -create "${binaries[@]}" -output "$output"; fi
}
compile watch "$WAPP/YaoShiWatchR7" "$ROOT"/Watch/*.swift "$ROOT/Sources/WatchProtocol.swift"
# WidgetKit extensions require the extension process entry point.
if [ "$SIM" = 1 ]; then
  xcrun --sdk "$SDK" swiftc -target "${TARGETS[0]}" -sdk "$WSDK" -parse-as-library \
    -application-extension -Xlinker -e -Xlinker _NSExtensionMain -O -whole-module-optimization \
    "$ROOT"/WatchComplication/*.swift "$ROOT/Watch/WatchCurveSharedStore.swift" "$ROOT/Sources/WatchProtocol.swift" \
    -o "$EXT/YaoShiWatchComplication"
else
  bins=()
  for target in "${TARGETS[@]}"; do
    arch=${target%%-*}
    binary="$BUILD/complication-$arch"
    xcrun --sdk "$SDK" swiftc -target "$target" -sdk "$WSDK" -parse-as-library \
      -application-extension -Xlinker -e -Xlinker _NSExtensionMain -O -whole-module-optimization \
      "$ROOT"/WatchComplication/*.swift "$ROOT/Watch/WatchCurveSharedStore.swift" "$ROOT/Sources/WatchProtocol.swift" \
      -o "$binary"
    bins+=("$binary")
  done
  lipo -create "${bins[@]}" -output "$EXT/YaoShiWatchComplication"
fi
python3 - "$WAPP/Info.plist" "$EXT/Info.plist" "$WATCH_ID" "$COMP_ID" "$PHONE_ID" <<'PY'
import plistlib, sys
wpath, epath, wid, eid, pid = sys.argv[1:]
w = {'CFBundleDevelopmentRegion':'zh_CN','CFBundleDisplayName':'药时手表·R7',
     'CFBundleName':'YaoShiWatchR7','CFBundleExecutable':'YaoShiWatchR7',
     'CFBundleIdentifier':wid,'CFBundleInfoDictionaryVersion':'6.0','CFBundlePackageType':'APPL',
     'MinimumOSVersion':'10.0','UIDeviceFamily':[4],'WKApplication':True,
     'WKCompanionAppBundleIdentifier':pid,'WKRunsIndependentlyOfCompanionApp':False}
e = {'CFBundleDevelopmentRegion':'zh_CN','CFBundleDisplayName':'药时浓度曲线·R7',
     'CFBundleName':'YaoShiWatchComplication','CFBundleExecutable':'YaoShiWatchComplication',
     'CFBundleIdentifier':eid,'CFBundleInfoDictionaryVersion':'6.0','CFBundlePackageType':'XPC!',
     'MinimumOSVersion':'10.0','UIDeviceFamily':[4],
     'NSExtension':{'NSExtensionPointIdentifier':'com.apple.widgetkit-extension'}}
for path, value in [(wpath,w),(epath,e)]:
    with open(path,'wb') as f: plistlib.dump(value,f,fmt=plistlib.FMT_BINARY)
PY
if [ "$SIM" = 1 ]; then
  python3 "$ROOT/scripts/stamp_version.py" "$WAPP/Info.plist"
  python3 "$ROOT/scripts/stamp_version.py" "$EXT/Info.plist" --parent "$WAPP/Info.plist"
else
  python3 "$ROOT/scripts/stamp_version.py" "$WAPP/Info.plist" --parent "$PHONE/Info.plist"
  python3 "$ROOT/scripts/stamp_version.py" "$EXT/Info.plist" --parent "$WAPP/Info.plist"
fi
ICONWORK="$BUILD/watch-iconwork"
mkdir -p "$ICONWORK"
xcrun actool "$ROOT/icon/WatchAssets.xcassets" --compile "$WAPP" --platform "$SDK" \
  --target-device watch --minimum-deployment-target 10.0 --app-icon AppIcon \
  --output-partial-info-plist "$ICONWORK/partial.plist" \
  --warnings --errors --notices --output-format human-readable-text
python3 - "$WAPP/Info.plist" "$ICONWORK/partial.plist" <<'PY'
import plistlib,sys
with open(sys.argv[1],'rb') as f: info=plistlib.load(f)
with open(sys.argv[2],'rb') as f: partial=plistlib.load(f)
assert partial.get('CFBundleIcons',{}).get('CFBundlePrimaryIcon',{}).get('CFBundleIconName') == 'AppIcon'
info.update(partial)
with open(sys.argv[1],'wb') as f: plistlib.dump(info,f,fmt=plistlib.FMT_BINARY)
PY
xcrun assetutil --validate-file "$WAPP/Assets.car"
if [ "$SIM" = 1 ]; then
  cat > "$BUILD/watch-r7-sim-entitlements.plist" <<EOF
<?xml version="1.0"?><plist version="1.0"><dict><key>com.apple.security.application-groups</key><array><string>$GROUP</string></array></dict></plist>
EOF
  xattr -cr "$WAPP"
  codesign --force --sign - --entitlements "$BUILD/watch-r7-sim-entitlements.plist" --timestamp=none "$EXT"
  codesign --force --sign - --entitlements "$BUILD/watch-r7-sim-entitlements.plist" --timestamp=none "$WAPP"
else
  for spec in "$COMP_ID:$EXT" "$WATCH_ID:$WAPP"; do
    bid=${spec%%:*}; bundle=${spec#*:}
    profile=$(python3 "$ROOT/scripts/select_profile.py" "P272ZF8FA9.$bid")
    security cms -D -i "$profile" > "$BUILD/profile-${bid##*.}.plist"
    /usr/libexec/PlistBuddy -x -c 'Print :Entitlements' "$BUILD/profile-${bid##*.}.plist" > "$BUILD/ent-${bid##*.}.plist"
    python3 - "$BUILD/ent-${bid##*.}.plist" "$GROUP" "$bid" <<'PY'
import plistlib,sys
with open(sys.argv[1],'rb') as f: e=plistlib.load(f)
if sys.argv[2] not in e.get('com.apple.security.application-groups',[]):
    raise SystemExit('R7 Watch App Group 未在签名配置中启用；拒绝生成无法共享曲线的安装包')
if e.get('application-identifier') != 'P272ZF8FA9.'+sys.argv[3]:
    raise SystemExit('Watch 签名配置与独立 Bundle ID 不匹配')
PY
    cp "$profile" "$bundle/embedded.mobileprovision"
    xattr -cr "$bundle"
    codesign --force --sign "$YAOSHI_SIGNING_IDENTITY" --entitlements "$BUILD/ent-${bid##*.}.plist" --timestamp=none "$bundle"
  done
  xattr -cr "$PHONE"
  codesign --force --sign "$YAOSHI_SIGNING_IDENTITY" --entitlements "$BUILD/ent.plist" --timestamp=none "$PHONE"
  codesign --verify --deep --strict --verbose=1 "$PHONE"
fi
codesign --verify --deep --strict --verbose=1 "$WAPP"
echo "R7 Watch/complication 构建完成：$WAPP"
