#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD="$(mktemp -d /tmp/yaoshi-sync-regression.XXXXXX)"
trap 'rm -rf "$TEST_BUILD"' EXIT
# Keep Store's external partner-sharing effects out of local sync regressions.
cat > "$TEST_BUILD/MedicationShareTestStub.swift" <<'SWIFT'
import Foundation
@MainActor final class MedicationShareRepository {
    static let shared = MedicationShareRepository()
    func publishNewDose(_ dose: Dose, roundGapHours: Int, previousDoseAt: Date?) {}
    func publishIfShared(_ dose: Dose, roundGapHours: Int) {}
    func removeIfShared(_ doseID: UUID) {}
}
SWIFT
xcrun swiftc -D SYNC_TESTING -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Sources/DoseEngine.swift" "$ROOT/Sources/DoseEpisode.swift" \
  "$ROOT/Sources/Sync.swift" "$ROOT/Sources/Clonidine.swift" "$ROOT/Sources/Store.swift" \
  "$TEST_BUILD/MedicationShareTestStub.swift" "$ROOT/tests/SyncRegressionTests.swift" -o "$TEST_BUILD/sync-tests"
"$TEST_BUILD/sync-tests"
xcrun swiftc -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Sources/DoseEpisode.swift" \
  "$ROOT/tests/DoseEpisodeTests.swift" -o "$TEST_BUILD/episode-tests"
"$TEST_BUILD/episode-tests"

xcrun swiftc -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Sources/DoseEngine.swift" "$ROOT/Sources/DoseCurveModel.swift" \
  "$ROOT/tests/DoseCurveTests.swift" -o "$TEST_BUILD/curve-tests"
"$TEST_BUILD/curve-tests"

xcrun swiftc -parse-as-library \
  "$ROOT/Sources/Models.swift" "$ROOT/Sources/LifeTimeline.swift" \
  "$ROOT/tests/LifeTimelineTests.swift" -o "$TEST_BUILD/life-tests"
"$TEST_BUILD/life-tests"
