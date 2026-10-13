import Foundation

/// 只决定显示的时间范围，不截断参与浓度计算的历史记录。
/// 主 App、小组件和回归测试共用；「现在」始终是一个精确采样点。
struct DoseCurveModel {
    struct Sample {
        let at: Date
        let level: Double
    }

    let start: Date
    let end: Date
    let now: Date
    let currentLevel: Double
    let samples: [Sample]
    let visibleDoses: [Dose]
    let historyDoses: [Dose]
    let hypotheticalDoseID: UUID?
    let upperLevel: Double
    /// 全部记录的分析视图使用统一纵轴，放大和平移时不会改变 1.0 倍基准。
    let analysisUpperLevel: Double
    let curve: PlasmaCurveConfiguration

    init(doses: [Dose], now: Date, hypotheticalDoseID: UUID? = nil,
         curve: PlasmaCurveConfiguration = .standard) {
        self.now = now
        self.hypotheticalDoseID = hypotheticalDoseID
        self.curve = curve
        // 试算仅允许「假设此刻」；误记到未来的实记不能进入当前预测。
        let history = doses.filter { $0.at <= now && $0.at.timeIntervalSinceReferenceDate.isFinite }
        self.historyDoses = history
        let historyLimit = now.addingTimeInterval(-72 * 3600)
        let recent = history.filter { $0.at >= historyLimit }
        let earliest = recent.map(\.at).min()
        let proposedStart = earliest?.addingTimeInterval(-3600) ?? now.addingTimeInterval(-16 * 3600)
        let start = max(historyLimit, min(now.addingTimeInterval(-4 * 3600), proposedStart))
        self.start = start
        // 试算的新一剂也属于输入，所以它和后续达峰不会落到图外。
        let end = now.addingTimeInterval(12 * 3600)
        self.end = end
        let visibleDoses = history.filter { $0.at >= start && $0.at <= end }.sorted { $0.at < $1.at }
        self.visibleDoses = visibleDoses
        let currentLevel = DoseEngine.totalPlasma(history, at: now, curve: curve)
        self.currentLevel = currentLevel

        let defaultRange = start...end
        let samples = Self.makeSamples(doses: history, curve: curve, range: defaultRange,
                                       now: now, count: 240, currentLevel: currentLevel)
        self.samples = samples
        // 即使当前很低，也保留 1.0 基准，不把低浓度自动放大成满屏。
        self.upperLevel = max(1.15, (samples.map(\.level).max() ?? 0) * 1.12)

        // 详细视图可回看完整剂量历史；把每次记录的时刻、吸收起点和峰值时刻加入
        // 纵轴取样点，避免长时间范围的普通网格漏掉窄峰。
        let analysisStart = history.map(\.at).min() ?? start
        let analysisRange = analysisStart...end
        let analysisSamples = Self.makeSamples(doses: history, curve: curve,
                                               range: analysisRange, now: now,
                                               count: 480, currentLevel: currentLevel)
        self.analysisUpperLevel = max(1.15, (analysisSamples.map(\.level).max() ?? 0) * 1.12)
    }

    func fraction(at date: Date) -> Double {
        date.timeIntervalSince(start) / end.timeIntervalSince(start)
    }

    func level(at date: Date) -> Double {
        DoseEngine.totalPlasma(historyDoses, at: date, curve: curve)
    }

    /// 按当前缩放窗口重新取样，放大时仍能看到连续曲线，而不是拉伸旧的低分辨率图。
    func samples(in range: ClosedRange<Date>, count: Int = 320) -> [Sample] {
        Self.makeSamples(doses: historyDoses, curve: curve, range: range,
                         now: now, count: count, currentLevel: currentLevel)
    }

    var axisDates: [Date] { [start, start.addingTimeInterval(end.timeIntervalSince(start) / 2), end] }

    static func levelText(_ level: Double) -> String {
        level < 0.01 ? "<0.01 倍" : String(format: "%.2f 倍", level)
    }

    private static func makeSamples(doses: [Dose], curve: PlasmaCurveConfiguration,
                                    range: ClosedRange<Date>, now: Date,
                                    count: Int, currentLevel: Double) -> [Sample] {
        let lower = range.lowerBound
        let upper = range.upperBound
        let span = max(0.001, upper.timeIntervalSince(lower))
        let steps = max(2, min(600, count))
        var dates = (0...steps).map {
            lower.addingTimeInterval(span * Double($0) / Double(steps))
        }
        if now >= lower && now <= upper { dates.append(now) }

        for dose in doses {
            if dose.at >= lower && dose.at <= upper { dates.append(dose.at) }
            let lag = curve.lag(for: dose.food)
            let absorption = dose.at.addingTimeInterval(lag * 3600)
            if absorption >= lower && absorption <= upper { dates.append(absorption) }
            let foodShift = dose.food == .withFood ? PlasmaCurveConfiguration.foodDelayHours : 0
            let peak = dose.at.addingTimeInterval((curve.peakTimeHours + foodShift) * 3600)
            if peak >= lower && peak <= upper { dates.append(peak) }
        }

        return Array(Set(dates)).sorted().map { date in
            Sample(at: date,
                   level: date == now ? currentLevel : DoseEngine.totalPlasma(doses, at: date, curve: curve))
        }
    }
}
