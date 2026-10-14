#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD="$(mktemp -d /tmp/yaoshi-decay-regression.XXXXXX)"
trap 'rm -rf "$TEST_BUILD"' EXIT
xcrun swiftc -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Sources/DoseEngine.swift" \
  "$ROOT/tests/DecayMilestoneTests.swift" -o "$TEST_BUILD/decay-tests"
"$TEST_BUILD/decay-tests"
