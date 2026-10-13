#!/bin/bash
# Native read-only TV dashboard. Pairing is local, encrypted and explicitly approved on both screens.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="${YAOSHI_TV_BUILD_DIR:-/tmp/yaoshi-tv}"
APP="$BUILD/YaoShiTV.app"
BUNDLE_ID="${YAOSHI_TV_BUNDLE_ID:-com.richardhuo.yaoshi.tv}"
SIMULATOR="${YAOSHI_TV_SIMULATOR:-1}"
PROFILE="${YAOSHI_TV_PROFILE:-}"
IDENTITY="${YAOSHI_TV_SIGNING_IDENTITY:--}"
[ ! -e "$APP" ] || { echo "Use a fresh YAOSHI_TV_BUILD_DIR; existing app is preserved."; exit 1; }
mkdir -p "$APP"
if [ "$SIMULATOR" = 1 ]; then
  SDK_NAME=appletvsimulator
  TARGET="$(uname -m)-apple-tvos17.0-simulator"
else
  SDK_NAME=appletvos
  TARGET=arm64-apple-tvos17.0
  [ -n "$PROFILE" ] && [ "$IDENTITY" != '-' ] || { echo "Set YAOSHI_TV_PROFILE and YAOSHI_TV_SIGNING_IDENTITY for physical Apple TV."; exit 1; }
  security cms -D -i "$PROFILE" > "$BUILD/profile.plist"
  python3 - "$BUILD/profile.plist" "$BUILD/entitlements.plist" "$BUNDLE_ID" <<'PY'
import plistlib,sys,datetime
p=plistlib.load(open(sys.argv[1],'rb'))
if 'tvOS' not in p.get('Platform',[]): raise SystemExit('Expected a tvOS provisioning profile; iOS profiles cannot sign Apple TV apps.')
if p['ExpirationDate'] < datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None): raise SystemExit('tvOS provisioning profile expired.')
e=p['Entitlements']; prefix=p['ApplicationIdentifierPrefix'][0]; appid=prefix+'.'+sys.argv[3]
a=e.get('application-identifier','')
if a != appid and not (a.endswith('.*') and appid.startswith(a[:-1])): raise SystemExit('Profile does not authorize this tvOS bundle ID.')
e['application-identifier']=appid
if 'keychain-access-groups' in e: e['keychain-access-groups']=[g.replace(prefix+'.*',appid) for g in e['keychain-access-groups']]
plistlib.dump(e,open(sys.argv[2],'wb'))
PY
  cp "$PROFILE" "$APP/embedded.mobileprovision"
fi
SDK="$(xcrun --sdk "$SDK_NAME" --show-sdk-path)"
xcrun --sdk "$SDK_NAME" swiftc -target "$TARGET" -sdk "$SDK" \
  -parse-as-library -O -whole-module-optimization -o "$APP/YaoShiTV" \
  "$ROOT/Sources/Models.swift" "$ROOT/Sources/DoseEngine.swift" "$ROOT/Sources/DoseCurveModel.swift" \
  "$ROOT/Shared/TV/"*.swift "$ROOT/TV/"*.swift
python3 - "$APP/Info.plist" "$BUNDLE_ID" "$SDK_NAME" <<'PY'
import plistlib,sys
plistlib.dump({
 'CFBundleDevelopmentRegion':'zh_CN','CFBundleDisplayName':'药时电视','CFBundleName':'药时电视',
 'CFBundleExecutable':'YaoShiTV','CFBundleIdentifier':sys.argv[2],
 'CFBundleInfoDictionaryVersion':'6.0','CFBundlePackageType':'APPL',
 'CFBundleSupportedPlatforms':['AppleTVSimulator' if sys.argv[3]=='appletvsimulator' else 'AppleTVOS'],
 'MinimumOSVersion':'17.0','UIDeviceFamily':[3], 'UIUserInterfaceStyle':'Dark',
 'NSLocalNetworkUsageDescription':'与您确认配对的手机加密传送药时曲线；仅在双方核对验证码后接收。',
 'NSBonjourServices':['_yaoshi-tv-v1._tcp'],
},open(sys.argv[1],'wb'))
PY
python3 "$ROOT/scripts/stamp_version.py" "$APP/Info.plist"
xattr -cr "$APP"
if [ "$SIMULATOR" = 1 ]; then
  codesign --force --sign - --timestamp=none "$APP"
else
  codesign --force --sign "$IDENTITY" --entitlements "$BUILD/entitlements.plist" --timestamp=none "$APP"
fi
codesign --verify --strict --verbose "$APP"
echo "Built: $APP"
