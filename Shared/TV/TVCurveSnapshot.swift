import Foundation

/// No record identifiers, notes, symptoms, reasons, device names, or settings unrelated to plotting.
struct TVCurveSnapshot: Codable {
    struct Point: Codable {
        let at: Date
        let mg: Int
        let food: FoodState
    }
    let doses: [Point]
    let peakHours: Double
    let halfLifeHours: Double
    let generatedAt: Date

    init(doses: [Dose], curve: PlasmaCurveConfiguration, now: Date = Date()) {
        self.doses = doses.filter { $0.at <= now }.map { Point(at: $0.at, mg: $0.mg, food: $0.food) }
        peakHours = curve.peakTimeHours
        halfLifeHours = curve.halfLifeHours
        generatedAt = now
    }
    var isValid: Bool {
        doses.count <= 20_000 && generatedAt.timeIntervalSinceReferenceDate.isFinite &&
        peakHours.isFinite && (1...12).contains(peakHours) &&
        halfLifeHours.isFinite && (2...30).contains(halfLifeHours) &&
        doses.allSatisfy { $0.at.timeIntervalSinceReferenceDate.isFinite && (1...10_000).contains($0.mg) }
    }
    var records: [Dose] { doses.map { Dose(at: $0.at, mg: $0.mg, food: $0.food) } }
    var curve: PlasmaCurveConfiguration {
        PlasmaCurveConfiguration(peakTimeHours: peakHours, halfLifeHours: halfLifeHours)
    }
}

