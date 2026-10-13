#!/bin/bash
# Mac Catalyst, using the same SwiftUI screens and durable record storage as iOS.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${YAOSHI_MAC_BUILD_DIR:-/tmp/yaoshi-mac}"
APP="$BUILD/药时 Mac.app"
BUNDLE_ID="${YAOSHI_MAC_BUNDLE_ID:-com.richardhuo.yaoshi.mac}"
IDENTITY="${YAOSHI_MAC_SIGNING_IDENTITY:--}"
PROFILE="${YAOSHI_MAC_PROFILE:-}"
ARCH="${YAOSHI_MAC_ARCH:-$(uname -m)}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
[ ! -e "$APP" ] || { echo "Use a fresh YAOSHI_MAC_BUILD_DIR; existing app is preserved."; exit 1; }
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun --sdk macosx swiftc -D YAOSHI_APP \
  -target "$ARCH-apple-ios17.0-macabi" -sdk "$SDK" \
  -F "$SDK/System/iOSSupport/System/Library/Frameworks" \
  -I "$SDK/System/iOSSupport/usr/include" -O -whole-module-optimization \
  -o "$APP/Contents/MacOS/药时" "$ROOT/Sources/"*.swift "$ROOT/Shared/PartnerSync/"*.swift
python3 - "$APP/Contents/Info.plist" "$BUNDLE_ID" "$PROFILE" <<'PY'
import plistlib,sys
plistlib.dump({
 'CFBundleDevelopmentRegion':'zh_CN', 'CFBundleDisplayName':'药时 Mac', 'CFBundleName':'药时 Mac',
 'CFBundleExecutable':'药时', 'CFBundleIdentifier':sys.argv[2],
 'CFBundleInfoDictionaryVersion':'6.0', 'CFBundlePackageType':'APPL',
 'CFBundleSupportedPlatforms':['MacOSX'], 'LSMinimumSystemVersion':'14.0',
 'LSApplicationCategoryType':'public.app-category.healthcare-fitness',
 'YaoShiCloudSyncEnabled':bool(sys.argv[3]), 'UIDeviceFamily':[2], 'UIUserInterfaceStyle':'Dark', 'NSHighResolutionCapable':True,
 'CFBundleIconFile':'YaoShi.icns',
 'CFBundleURLTypes':[{'CFBundleURLName':sys.argv[2], 'CFBundleURLSchemes':['yaoshi','yaoshi-partner']}],
},open(sys.argv[1],'wb'))
PY
python3 "$ROOT/scripts/stamp_version.py" "$APP/Contents/Info.plist"
ICONSET="$BUILD/YaoShi.iconset"
mkdir -p "$ICONSET"
for n in 16 32 128 256 512; do
  sips -z "$n" "$n" "$ROOT/icon/icon_1024.png" --out "$ICONSET/icon_${n}x${n}.png" >/dev/null
  twice=$((n * 2))
  sips -z "$twice" "$twice" "$ROOT/icon/icon_1024.png" --out "$ICONSET/icon_${n}x${n}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/YaoShi.icns"
# A local ad-hoc app is sandboxed and cannot access the iPhone signing team's keychain.
# A provisioned team build requires an actual Mac profile; never embed an iOS profile.
if [ -n "$PROFILE" ]; then
  [ "$IDENTITY" != '-' ] || { echo "A Mac profile requires YAOSHI_MAC_SIGNING_IDENTITY."; exit 1; }
  security cms -D -i "$PROFILE" > "$BUILD/mac-profile.plist"
fi
python3 - "$BUILD/entitlements.plist" "$BUILD/mac-profile.plist" "$PROFILE" "$BUNDLE_ID" <<'PY'
import plistlib,sys
ent={'com.apple.security.app-sandbox':True,'com.apple.security.network.client':True,
     'com.apple.security.files.user-selected.read-write':True}
if sys.argv[3]:
    p=plistlib.load(open(sys.argv[2],'rb'))
    if 'OSX' not in p.get('Platform',[]) and 'macOS' not in p.get('Platform',[]):
        raise SystemExit('Expected a Mac provisioning profile, not an iOS profile.')
    source=p['Entitlements']; team=p['TeamIdentifier'][0]; appid=team+'.'+sys.argv[4]
    allowed=source.get('com.apple.application-identifier','')
    if allowed != appid and not (allowed.endswith('.*') and appid.startswith(allowed[:-1])):
        raise SystemExit('Mac profile does not authorize this bundle ID.')
    ent.update(source)
    ent['com.apple.application-identifier']=appid
    # Explicit groups must be authorized by the supplied provisioning profile.
    groups=[team+'.com.richardhuo.yaoshi.shared',team+'.com.richardhuo.yaoshi.partner.owner']
    allowed_groups=source.get('keychain-access-groups',[])
    if not all(any(g==a or (a.endswith('.*') and g.startswith(a[:-1])) for a in allowed_groups) for g in groups):
        raise SystemExit('Mac profile does not authorize the shared medication keychain groups.')
    ent['keychain-access-groups']=[appid,*groups]
plistlib.dump(ent,open(sys.argv[1],'wb'))
PY
if [ -n "$PROFILE" ]; then cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"; fi
xattr -cr "$APP"
codesign --force --sign "$IDENTITY" --entitlements "$BUILD/entitlements.plist" --timestamp=none "$APP"
codesign --verify --strict --verbose "$APP"
echo "Built: $APP"
if [ -z "$PROFILE" ]; then echo "Local Mac build: shared iCloud Keychain requires a matching Mac provisioning profile."; fi
