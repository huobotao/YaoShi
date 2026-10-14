#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD="$(mktemp -d /tmp/yaoshi-location-tests.XXXXXX)"
trap 'rm -rf "$TEST_BUILD"' EXIT
xcrun swiftc "$ROOT/Sources/LocationSharingModel.swift" \
  "$ROOT/tests/LocationSharingTests.swift" -o "$TEST_BUILD/model-tests"
"$TEST_BUILD/model-tests"
xcrun swiftc "$ROOT/Sources/LocationSharingModel.swift" \
  "$ROOT/Shared/PartnerSync/PartnerSyncCore.swift" \
  "$ROOT/tests/LocationSharingTransportTests.swift" -o "$TEST_BUILD/transport-tests"
"$TEST_BUILD/transport-tests"
