import Foundation

struct StandaloneDose: Codable, Identifiable, Equatable {
    let id: UUID
    let at: Date
    let mg: Int
    let food: String
}

struct StandaloneImport: Codable, Equatable {
    let schema: Int
    let sourceCapturedAt: Date
    let exportedAt: Date
    let sourceSHA256: String
    let peakHours: Double
    let halfLifeHours: Double
    let doses: [StandaloneDose]

    func validate(now: Date = Date()) throws {
        guard schema == 1,
              sourceCapturedAt <= now.addingTimeInterval(300),
              exportedAt >= sourceCapturedAt,
              exportedAt <= now.addingTimeInterval(300),
              sourceSHA256.count == 64,
              sourceSHA256.allSatisfy({ $0.isHexDigit }),
              peakHours.isFinite, (1...12).contains(peakHours),
              halfLifeHours.isFinite, (1...48).contains(halfLifeHours),
              !doses.isEmpty, doses.count <= 10_000,
              Set(doses.map(\.id)).count == doses.count else { throw ImportError.invalid }
        for dose in doses {
            guard (5...500).contains(dose.mg), dose.mg % 5 == 0,
                  ["unknown", "withFood", "emptyStomach"].contains(dose.food),
                  dose.at >= Date(timeIntervalSince1970: 946684800),
                  dose.at <= sourceCapturedAt.addingTimeInterval(300) else { throw ImportError.invalid }
        }
    }

    enum ImportError: Error { case invalid }
}

enum StandaloneCurve {
    struct Point { let at: Date; let level: Double }
    static func level(_ data: StandaloneImport, at date: Date) -> Double {
        let ke = log(2) / data.halfLifeHours
        let wanted = max(0.05, data.peakHours - 0.5)
        var low = ke * 1e-9
        var high = ke * 1e9
        for _ in 0..<100 {
            let mid = (low + high) / 2
            let delta = mid - ke
            let time = abs(delta / ke) < 1e-6
                ? 1 / ke - delta / (2 * ke * ke)
                : log1p(delta / ke) / delta
            if time > wanted { low = mid } else { high = mid }
        }
        let ka = (low + high) / 2
        func shape(_ x: Double) -> Double {
            if abs(ka - ke) < max(ka, ke) * 1e-8 { return x * exp(-ke * x) }
            return abs(exp(-ke * x) - exp(-ka * x))
        }
        let peak = shape(wanted)
        guard peak > 0 else { return 0 }
        return data.doses.reduce(0) { sum, dose in
            let lag = dose.food == "withFood" ? 1.4 : 0.5
            let x = date.timeIntervalSince(dose.at) / 3600 - lag
            guard x > 0 else { return sum }
            return sum + max(0, shape(x) / peak) * Double(dose.mg) / 50
        }
    }

    static func points(_ data: StandaloneImport, now: Date) -> [Point] {
        let start = now.addingTimeInterval(-18 * 3600)
        return (0...104).map { n in
            let at = start.addingTimeInterval(Double(n) * 26 * 3600 / 104)
            return Point(at: at, level: level(data, at: at))
        }
    }
}
