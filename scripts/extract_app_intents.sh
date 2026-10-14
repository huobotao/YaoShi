#!/bin/bash
# Source this helper before direct swiftc builds. AppIntents needs both compiler
# constant extraction and a Metadata.appintents bundle, just like an Xcode build.
prepare_app_intents() {
  local work="$1"
  shift
  mkdir -p "$work"
  YAOSHI_INTENTS_WORK="$work"
  YAOSHI_INTENTS_TOOLCHAIN="$(dirname "$(dirname "$(xcrun --find swiftc)")")"
  python3 - "$YAOSHI_INTENTS_TOOLCHAIN/share/swift/SwiftConstantValues/AppIntents.json" "$work/protocols.json" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    protocols = json.load(source)
if isinstance(protocols, dict):
    protocols = protocols['constValueProtocols']
with open(sys.argv[2], 'w') as destination:
    json.dump(protocols, destination)
PY
  printf '%s\n' "$@" > "$work/sources.list"
  printf '%s\n' "$work/module.swiftconstvalues" > "$work/const-values.list"
  YAOSHI_INTENTS_FLAGS=(-emit-const-values-path "$work/module.swiftconstvalues"
    -const-gather-protocols-list "$work/protocols.json")
}

extract_app_intents() {
  local bundle="$1" module="$2" sdk="$3" target="$4"
  xcrun appintentsmetadataprocessor \
    --output "$bundle" \
    --toolchain-dir "$YAOSHI_INTENTS_TOOLCHAIN" \
    --module-name "$module" --sdk-root "$sdk" \
    --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
    --platform-family iOS --deployment-target 17.0 --target-triple "$target" \
    --source-file-list "$YAOSHI_INTENTS_WORK/sources.list" \
    --swift-const-vals-list "$YAOSHI_INTENTS_WORK/const-values.list"
  # Fail the build if a tool silently skipped extraction; a button without its
  # intent metadata can compile and render but cannot be dispatched correctly.
  test -s "$bundle/Metadata.appintents/extract.actionsdata"
  python3 - "$bundle/Metadata.appintents/extract.actionsdata" "$module" <<'PY'
import json, sys
with open(sys.argv[1]) as source:
    actions = json.load(source)['actions']
intent = actions.get('RefreshDoseActivityIntent')
if not intent or intent.get('fullyQualifiedTypeName') != sys.argv[2] + '.RefreshDoseActivityIntent':
    raise SystemExit('Missing RefreshDoseActivityIntent metadata for ' + sys.argv[2])
if intent.get('openAppWhenRun') is not False:
    raise SystemExit('Refresh intent must run without opening the app')
print('Verified RefreshDoseActivityIntent metadata in ' + sys.argv[2])
PY
}
