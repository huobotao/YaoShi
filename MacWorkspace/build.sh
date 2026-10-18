#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
OUT="${YAOSHI_WORKSPACE_OUTPUT:?Set a new output directory}"
APP="$OUT/药时工作台 R1.app"
[ ! -e "$APP" ] || { echo 'Refusing to overwrite existing app'; exit 1; }
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -parse-as-library -O -target arm64-apple-macosx14.0 "$ROOT/Model.swift" "$ROOT/App.swift" -o "$APP/Contents/MacOS/YaoShiWorkspace"
python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib,sys
plistlib.dump(dict(CFBundleIdentifier='com.richardhuo.yaoshi.mac.workspace.r1',CFBundleName='药时工作台 R1',CFBundleDisplayName='药时工作台 R1',CFBundleExecutable='YaoShiWorkspace',CFBundlePackageType='APPL',CFBundleShortVersionString='0.1.0',CFBundleVersion='1',LSMinimumSystemVersion='14.0',NSHighResolutionCapable=True),open(sys.argv[1],'wb'))
PY
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
printf '%s\n' "$APP"
