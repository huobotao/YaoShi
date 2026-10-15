import Foundation

@main
struct StandaloneModelTests {
    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let at = now.addingTimeInterval(-3.8 * 3600)
        let one = StandaloneDose(id: UUID(), at: at, mg: 50, food: "unknown")
        let data = StandaloneImport(schema: 1, sourceCapturedAt: now,
                                    exportedAt: now, sourceSHA256: String(repeating: "a", count: 64),
                                    peakHours: 3.8, halfLifeHours: 10.5, doses: [one])
        try data.validate(now: now)
        assert(abs(StandaloneCurve.level(data, at: now) - 1) < 1e-8)
        assert(StandaloneCurve.level(data, at: at) == 0)
        let two = StandaloneImport(schema: 1, sourceCapturedAt: now, exportedAt: now,
                                    sourceSHA256: String(repeating: "a", count: 64),
                                    peakHours: 3.8, halfLifeHours: 10.5,
                                    doses: [one, StandaloneDose(id: UUID(), at: at, mg: 50, food: "unknown")])
        assert(abs(StandaloneCurve.level(two, at: now) - 2) < 1e-8)
        let fed = StandaloneImport(schema: 1, sourceCapturedAt: now, exportedAt: now,
                                    sourceSHA256: String(repeating: "a", count: 64),
                                    peakHours: 3.8, halfLifeHours: 10.5,
                                    doses: [StandaloneDose(id: UUID(), at: at, mg: 50, food: "withFood")])
        assert(StandaloneCurve.level(fed, at: now) < StandaloneCurve.level(data, at: now))
        let duplicate = StandaloneImport(schema: 1, sourceCapturedAt: now, exportedAt: now,
                                        sourceSHA256: String(repeating: "a", count: 64),
                                        peakHours: 3.8, halfLifeHours: 10.5, doses: [one, one])
        assert((try? duplicate.validate(now: now)) == nil)
        print("Standalone model tests passed")
    }
}
