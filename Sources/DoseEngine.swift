import Foundation

// MARK: - 药效阶段

enum DosePhase: String, Codable {
    case none        // 今天还没吃 / 没有任何记录
    case waiting     // 刚吃下，还没起效
    case rising      // 起效中
    case peak        // 高峰
    case fading      // 衰退中
    case tail        // 尾声
    case over        // 基本消退

    var label: String {
        switch self {
        case .none:    return "还没吃"
        case .waiting: return "刚吃下"
        case .rising:  return "起效中"
        case .peak:    return "高峰"
        case .fading:  return "衰退中"
        case .tail:    return "尾声"
        case .over:    return "药效已过"
        }
    }

    var symbol: String {
        switch self {
        case .none:    return "pills"
        case .waiting: return "hourglass"
        case .rising:  return "arrow.up.right"
        case .peak:    return "bolt.fill"
        case .fading:  return "arrow.down.right"
        case .tail:    return "moon.haze.fill"
        case .over:    return "moon.zzz.fill"
        }
    }

    /// 一句话说明现在处在什么状态
    var hint: String {
        switch self {
        case .none:    return "今天还没有服药记录"
        case .waiting: return "药还没开始起作用，通常要一个半小时"
        case .rising:  return "正在起效，专注度会一路往上"
        case .peak:    return "药效最强的时段，重要的事放在现在做"
        case .fading:  return "药效开始往下走，注意力会变散"
        case .tail:    return "只剩尾巴，接近消退，别再补药"
        case .over:    return "药效基本过去了"
        }
    }
}

/// 右苯丙胺血浆曲线的两个可调参考参数。
/// 吸收速率 ka 由达峰时间和半衰期反推；吸收时滞及进食延迟仍是固定模型假设。
struct PlasmaCurveConfiguration: Hashable {
    let peakTimeHours: Double
    let halfLifeHours: Double
    let absorptionRate: Double

    init(peakTimeHours: Double, halfLifeHours: Double) {
        self.peakTimeHours = peakTimeHours
        self.halfLifeHours = halfLifeHours
        self.absorptionRate = Self.solveAbsorptionRate(peakTimeHours: peakTimeHours,
                                                       halfLifeHours: halfLifeHours)
    }

    static let standard = PlasmaCurveConfiguration(peakTimeHours: 3.8, halfLifeHours: 10.7)

    static let lagHours = 0.5
    static let foodDelayHours = 0.9

    var eliminationRate: Double { log(2) / halfLifeHours }

    /// 由 tmax = lag + ln(ka/ke)/(ka-ke) 数值反解吸收速率常数。
    private static func solveAbsorptionRate(peakTimeHours: Double, halfLifeHours: Double) -> Double {
        let ke = log(2) / halfLifeHours
        let wanted = max(0.05, peakTimeHours - lagHours)
        var low = ke * 1e-9
        var high = ke * 1e9

        // 对 ka，达峰时间单调递减；二分法在两侧都适用，包括 ka < ke 的情形。
        for _ in 0..<100 {
            let mid = (low + high) / 2
            let delta = mid - ke
            let relativeDelta = delta / ke
            let time = abs(relativeDelta) < 1e-6
                ? 1 / ke - delta / (2 * ke * ke)
                : log1p(relativeDelta) / delta
            if time > wanted { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }

    var peakLevel: Double {
        let x = max(0.05, peakTimeHours - Self.lagHours)
        return curveShape(x)
    }

    func curveShape(_ hoursAfterLag: Double) -> Double {
        let ka = absorptionRate
        let ke = eliminationRate
        if abs(ka - ke) < max(ka, ke) * 1e-8 {
            return hoursAfterLag * exp(-ke * hoursAfterLag)
        }
        return abs(exp(-ke * hoursAfterLag) - exp(-ka * hoursAfterLag))
    }

    func lag(for food: FoodState) -> Double {
        food == .withFood ? Self.lagHours + Self.foodDelayHours : Self.lagHours
    }
}

/// 在不再新增服药的前提下，模型最后一次下降到指定水平的时刻。
struct PlasmaDecayMilestone {
    let target: Double
    let at: Date?
    /// 当前已低于目标，并且已记录剂量的后续吸收也不会再达到目标。
    let alreadyBelow: Bool
}

// MARK: - 药效引擎
//
// 模型：口服单室一阶吸收-一阶消除。
//   归一化曲线形状 |e^(-ke·t') - e^(-ka·t')|，t' = t - lag（小时），t' <= 0 时为 0
// 参数以 Vyvanse（赖右苯丙胺）转化后的活性成分右苯丙胺为对象：
//   成人空腹胶囊 Tmax 约 3.8 小时、半衰期约 10–11.3 小时、
//   起效约 1.5 小时、有效时长约 13-14 小时。
// 这条曲线只用来画图和分阶段，不是给药建议，也不做剂量换算。

enum DoseEngine {

    // MARK: 药代常量（效应层，不是血药浓度层）
    //
    // ⚠️ 这里用的是"表观药效"参数，不是血药浓度参数。原因：
    // 右苯丙胺的血浆半衰期是 10–11 小时，但主观药效与浓度之间存在顺时针滞后
    // （急性耐受）——浓度还很高的时候，人感觉到的效果已经下来了。
    // 直接拿浓度曲线当药效曲线会得出"服药 14 小时后还剩五成药效"这种荒谬结论。
    // 所以把急性耐受吸收进消除项，用表观效应半衰期 4.78 小时。
    //
    // 标定依据：儿童 13 小时教室研究的 SKAMP 效应量逐时曲线
    // （1.5h 0.47、2.5h 0.98、5h 1.00、7.5h 0.98、10h 0.78、12h 0.54、13h 0.26，
    // 归一化到峰值），成人整体右移并拉长约 1 小时；
    // 成人职场研究证实 14 小时仍显著优于安慰剂。

    /// 吞下到开始吸收的时滞（小时）
    static let lagHours = 0.5
    /// 随餐时额外的延迟。高脂餐把达峰从 3.8 推到 4.7 小时，不改变总吸收量。
    static let foodLagExtra = 0.9
    /// 表观吸收速率常数（/小时）
    static let ka = 0.60
    /// 表观效应消除速率常数（/小时），对应效应半衰期约 4.8 小时
    static let ke = 0.145

    static func lag(for food: FoodState) -> Double {
        food == .withFood ? lagHours + foodLagExtra : lagHours
    }

    /// 达峰时刻（自服药算起，小时）。空腹约 3.6 小时。
    static let tmax: Double = lagHours + log(ka / ke) / (ka - ke)

    static let cmax: Double = rawConcentration(hours: tmax, lag: lagHours)

    private static func rawConcentration(hours t: Double, lag: Double) -> Double {
        let x = t - lag
        guard x > 0 else { return 0 }
        return exp(-ke * x) - exp(-ka * x)
    }

    /// 服药后 t 小时的相对药效强度，0…1（1 = 峰值）。
    /// 这条曲线只用来画形状和分阶段，不是给药建议，也不做剂量换算。
    static func level(hoursSinceDose t: Double, food: FoodState = .unknown) -> Double {
        guard t > 0, cmax > 0 else { return 0 }
        return max(0, min(1, rawConcentration(hours: t, lag: lag(for: food)) / cmax))
    }

    /// 剩余有效时间的比例，0…1，线性到 14 小时归零。
    ///
    /// 进度条一律用这个，不要用 level：level 是强度曲线，
    /// 在"药效已过"的时刻仍有约三成的数值，拿它填进度条会自相矛盾。
    static func remaining(hoursSinceDose t: Double) -> Double {
        max(0, min(1, 1 - t / effectEnd))
    }

    /// "还剩约 3 小时 20 分"；已过则返回 nil
    static func remainingText(hoursSinceDose t: Double) -> String? {
        let left = (effectEnd - t) * 3600
        guard left > 0 else { return nil }
        let h = Int(left) / 3600, m = (Int(left) % 3600) / 60
        return h == 0 ? "还剩约 \(m) 分钟" : "还剩约 \(h) 小时 \(m) 分"
    }

    // MARK: 阶段分界（自服药算起，小时）
    //
    // 顶部是 2–6 小时的宽平台而不是尖峰；6–11 小时是主观"掉档"高发段
    // （效应曲线最陡下降在 6.7 小时）；14 小时是成人研究证实的有效性终点。

    static let onsetStart = 0.5      // 刚吃下 → 起效中
    static let peakStart  = 2.0      // 起效中 → 高峰
    static let peakEnd    = 6.0      // 高峰 → 衰退中
    static let fadeEnd    = 11.0     // 衰退中 → 尾声
    static let effectEnd  = 14.0     // 尾声 → 药效已过

    /// 睡眠友好下限：服药后 14 小时。再往后到 16 小时基本无影响。
    /// 没有任何研究直接测过"服药时刻 → 入睡潜伏期"，这是按效应曲线外推的，
    /// 界面上必须说明是推算而不是实测。
    static let sleepSafeHours = 14.0

    static func phase(hoursSinceDose t: Double) -> DosePhase {
        switch t {
        case ..<onsetStart:  return .waiting
        case ..<peakStart:   return .rising
        case ..<peakEnd:     return .peak
        case ..<fadeEnd:     return .fading
        case ..<effectEnd:   return .tail
        default:             return .over
        }
    }

    // MARK: 体内药量层（可以叠加）
    //
    // 这一层是血浆活性成分右苯丙胺的归一化模型估值；达峰时间与半衰期可在设置中调整，
    // 默认成人空腹胶囊 Tmax 3.8 小时、半衰期取公开的 10–11.3 小时中间参考值 10.7 小时。
    //
    // 为什么这一层可以直接相加：赖右苯丙胺在 50–250 毫克单剂范围内药代线性，
    // 吸收走的 PEPT1 转运体是低亲和力高容量（治疗剂量下离饱和差一个数量级），
    // 红细胞水解在治疗剂量下不饱和，也不经 CYP450、没有自体诱导。
    // 实测的每日给药累积比 1.19–1.34，与线性叠加算出的 1.22–1.33 完全重合。
    //
    // ⚠️ 与之相对，"感受"那一层不能叠加，见下面 MARK: 感受层。

    static let plasmaLag = PlasmaCurveConfiguration.lagHours

    /// First future local maximum after a rising segment, never a distant global maximum.
    /// Minute resolution matches the estimate's displayed precision.
    static func nextLocalPlasmaPeak(doses: [Dose], now: Date, curve: PlasmaCurveConfiguration) -> Date? {
        guard !doses.isEmpty else { return nil }
        var previous = DoseEngine.totalPlasma(doses, at: now, curve: curve)
        var rising = false
        for minute in 1...1440 {
            let at = now.addingTimeInterval(Double(minute) * 60)
            let value = DoseEngine.totalPlasma(doses, at: at, curve: curve)
            if value > previous + 1e-9 { rising = true }
            if rising && value < previous - 1e-9 { return at.addingTimeInterval(-60) }
            previous = value
        }
        return nil
    }

    /// 单片在服药后 t 小时的体内药量，1.0 = 单片 50 毫克的峰值
    static func plasmaLevel(hoursSinceDose t: Double, food: FoodState = .unknown,
                            curve: PlasmaCurveConfiguration = .standard) -> Double {
        let lg = curve.lag(for: food)
        let x = t - lg
        guard x > 0, x.isFinite, curve.peakLevel > 0 else { return 0 }
        return max(0, curve.curveShape(x) / curve.peakLevel)
    }

    /// 剂量权重，以 50 毫克为基准 1.0。
    /// 体内药量与剂量基本成正比（实测 log-log 斜率 1.02–1.11），所以这里就用线性。
    static func doseWeight(_ mg: Int) -> Double {
        guard mg > 0 else { return 0 }
        return Double(mg) / 50.0
    }

    /// 某一时刻的体内总药量：把还有残留的每一片相加。
    /// 1.0 = 平时吃一片 50 毫克时的最高水平；两片叠在一起可以超过 1。
    static func totalPlasma(_ doses: [Dose], at now: Date,
                            curve: PlasmaCurveConfiguration = .standard) -> Double {
        var sum = 0.0
        for d in doses {
            let t = now.timeIntervalSince(d.at) / 3600
            // 显示视窗不能成为药代截断点；每笔历史剂量自然指数衰减。
            guard t > 0, t.isFinite else { continue }
            sum += plasmaLevel(hoursSinceDose: t, food: d.food, curve: curve) * doseWeight(d.mg)
        }
        return sum
    }

    /// 仅使用已经发生的服药记录；求最后一次下降穿越，避免尚未吸收时误报已经回落。
    /// 同一吸收区间内是两个指数项的和，至多有一个极大值；在时滞边界分段寻找极大值，
    /// 因此不会漏掉短于采样步长的回升。最后一笔单剂达峰之后，总和保证单调下降。
    static func decayMilestones(_ doses: [Dose], from now: Date,
                                curve: PlasmaCurveConfiguration = .standard) -> [PlasmaDecayMilestone] {
        let history = doses.filter { $0.at <= now && $0.mg > 0 }
        guard !history.isEmpty else { return [] }
        let targets: [Double] = [3, 2.5, 2, 1, 0.5, 0.1]
        let ka = curve.absorptionRate, ke = curve.eliminationRate
        guard ka.isFinite, ke.isFinite, ka > 0, ke > 0,
              curve.peakLevel.isFinite, curve.peakLevel > 0 else {
            return targets.map { PlasmaDecayMilestone(target: $0, at: nil, alreadyBelow: false) }
        }
        func value(_ seconds: Double) -> Double {
            totalPlasma(history, at: now.addingTimeInterval(seconds), curve: curve)
        }
        func slope(_ seconds: Double) -> Double {
            let at = now.addingTimeInterval(seconds)
            return history.reduce(0) { sum, dose in
                let x = at.timeIntervalSince(dose.at) / 3600 - curve.lag(for: dose.food)
                guard x >= 0 else { return sum }
                let derivative: Double
                if abs(ka - ke) < max(ka, ke) * 1e-8 {
                    derivative = exp(-ke * x) * (1 - ke * x)
                } else {
                    derivative = (ka > ke ? 1.0 : -1.0)
                        * (ka * exp(-ka * x) - ke * exp(-ke * x))
                }
                return sum + derivative / curve.peakLevel * doseWeight(dose.mg)
            }
        }
        let lastPeak = max(0, history.map { dose in
            dose.at.timeIntervalSince(now)
                + (max(0.05, curve.peakTimeHours - PlasmaCurveConfiguration.lagHours)
                   + curve.lag(for: dose.food)) * 3600
        }.max() ?? 0)
        var boundaries = [0.0, lastPeak]
        boundaries += history.map { $0.at.timeIntervalSince(now) + curve.lag(for: $0.food) * 3600 }
            .filter { $0 > 0 && $0 < lastPeak }
        boundaries = Array(Set(boundaries)).sorted()
        var points = boundaries
        for (left, right) in zip(boundaries, boundaries.dropFirst()) where right - left > 0.001 {
            // Evaluate just inside each interval to exclude derivative jumps at absorption starts.
            var lo = left + min(0.0001, (right - left) / 4)
            var hi = right - min(0.0001, (right - left) / 4)
            if slope(lo) > 0 && slope(hi) < 0 {
                while hi - lo > 0.001 {
                    let mid = (lo + hi) / 2
                    if slope(mid) > 0 { lo = mid } else { hi = mid }
                }
                points.append((lo + hi) / 2)
            }
        }
        // Expand the monotonic tail adaptively. The bound permits at least 30 days and
        // extends further for custom slow absorption / elimination models.
        let maxSpan = max(30 * 24 * 3600.0, 64 * 3600 / min(ka, ke))
        var span = 3600.0
        while value(lastPeak + span) >= targets.last! && span < maxSpan {
            span = min(span * 2, maxSpan)
        }
        points.append(lastPeak + span)
        points.sort()
        let samples = points.map { (time: $0, level: value($0)) }
        return targets.map { target in
            guard let lastAbove = samples.lastIndex(where: { $0.level >= target }) else {
                return PlasmaDecayMilestone(target: target, at: now, alreadyBelow: true)
            }
            guard lastAbove + 1 < samples.count else {
                return PlasmaDecayMilestone(target: target, at: nil, alreadyBelow: false)
            }
            var lo = samples[lastAbove].time
            var hi = samples[lastAbove + 1].time
            // Return the below-target side of a subsecond bracket (display precision is minutes).
            while hi - lo > 0.25 {
                let mid = (lo + hi) / 2
                if value(mid) >= target { lo = mid } else { hi = mid }
            }
            return PlasmaDecayMilestone(target: target, at: now.addingTimeInterval(hi), alreadyBelow: false)
        }
    }

    /// 未来峰值后首次降到目标水平的时刻，5 分钟一步，最多从现在往后找 48 小时。
    /// 刚服下尚未吸收时不能把当前低值误报为「已经回落」。
    static func plasmaDropTime(_ doses: [Dose], to target: Double, from now: Date,
                               curve: PlasmaCurveConfiguration = .standard) -> Date? {
        guard target > 0, target.isFinite,
              let peak = upcomingPlasmaPeak(doses, from: now, curve: curve) else { return nil }
        if peak.level < target { return now }
        var t = peak.at
        let step: TimeInterval = 300
        let end = now.addingTimeInterval(48 * 3600)
        while t <= end {
            if totalPlasma(doses, at: t, curve: curve) < target { return t }
            t = t.addingTimeInterval(step)
        }
        return nil
    }

    /// 未来体内药量还会达到的最高值与时刻
    static func upcomingPlasmaPeak(_ doses: [Dose], from now: Date,
                                   curve: PlasmaCurveConfiguration = .standard) -> (level: Double, at: Date)? {
        var best = (level: -1.0, at: now)
        var t = now
        let step: TimeInterval = 300
        for _ in 0..<(24 * 12) {
            let v = totalPlasma(doses, at: t, curve: curve)
            if v > best.level { best = (v, t) }
            t = t.addingTimeInterval(step)
        }
        return best.level >= 0 ? best : nil
    }

    // MARK: 感受层（不能叠加）
    //
    // 上面那条"药效强度"曲线（ka=0.60、ke=0.145）是把急性耐受折算进消除项得到的，
    // 它对单独一片拟合得很好，但正因为耐受被塞进了消除项，两片相加就会算错：
    // 急性耐受不是"药消失得更快"，而是"在已经有药的背景上，新加的药带来的增量更小"，
    // 这是状态依赖的，不是时不变的。直接把两条效应曲线相加，会把第二片的效果
    // 高估 2 到 6 倍（按 Emax 饱和估算，浓度 +80% 对应的效应增量只有 +12% 到 +42%）。
    //
    // 有没有办法给第二片加一个打折系数？查下来是没有：苯丙胺的顺时针滞后只有定性
    // 描述（Brauer 1996、Dolder 2017），没人报过同浓度下上升支与下降支的效应比值；
    // 唯一有完整耐受模型参数的是哌甲酯（Swanson 1999，耐受半衰期约 54 分钟），
    // 缺 S 与 Cant50 两个参数跑不起来；唯一做过"浓度翻倍、效应持平"定量对比的是
    // MDMA，跨药外推不成立。所以这里不编系数，改为把两件事分开显示：
    // 阶段与"还剩多久"按最近一次服药算（新的上升事件主导感受），
    // 体内药量按全部剂量叠加算（这一层才是可加的）。

    /// 一次服药的关键时刻    /// 今天累计吃了多少毫克
    static func todayTotalMg(_ doses: [Dose], now: Date = Date()) -> Int {
        let today = DateOnly(now)
        return doses.filter { $0.dateOnly == today }.reduce(0) { $0 + $1.mg }
    }

    /// 澳洲注册说明书上成人的最大推荐日剂量。
    /// 这是"研究支持的疗效与安全性边界"，不是毒性阈值——新州的处方标准里
    /// 超过 70 毫克存在合法路径（需精神科医生参与并取得卫生部个案批准），
    /// 所以界面上只陈述这个参考值，不做对错判断。
    static let labelMaxDailyMg = 70

    /// 一次服药的关键时刻
    static func onset(of dose: Dose) -> Date { dose.at.addingTimeInterval(peakStart * 3600) }
    static func peakEndTime(of dose: Dose) -> Date { dose.at.addingTimeInterval(peakEnd * 3600) }
    static func endTime(of dose: Dose) -> Date { dose.at.addingTimeInterval(effectEnd * 3600) }

    /// 想几点睡，最晚几点吃。按药效 14 小时倒推。
    static func latestTake(bedtime: Date) -> Date {
        bedtime.addingTimeInterval(-sleepSafeHours * 3600)
    }
}

// MARK: - 当前状态

/// 界面、小组件、灵动岛共用的一份"现在怎么样"
struct DoseStatus: Codable, Hashable {
    var lastDoseAt: Date?
    var lastMg: Int
    var phase: DosePhase
    var level: Double            // 最近一次服药的药效强度 0…1（感受层，只按最后一片算）
    var remaining: Double = 0    // 0…1，最近一次的剩余有效时间比例（进度条用）
    /// 体内总药量，1.0 = 平时一片 50 毫克的最高水平；多片叠加可超过 1
    var plasmaTotal: Double? = nil
    /// 此刻还有几片在体内留着（药量贡献超过 0.02 的）
    var activeCount: Int? = nil
    /// 今天累计吃了多少毫克
    var todayMg: Int? = nil
    /// 体内药量降到两成的预计时刻
    var plasmaLowAt: Date? = nil
    var peakEndAt: Date?         // 高峰结束时刻
    var effectEndAt: Date?       // 药效结束时刻
    var takenToday: Int          // 今天已服几次
    var generatedAt: Date

    var hoursSince: Double? {
        guard let l = lastDoseAt else { return nil }
        return Date().timeIntervalSince(l) / 3600
    }

    static func compute(doses: [Dose], now: Date = Date(),
                        curve: PlasmaCurveConfiguration = .standard) -> DoseStatus {
        let past = doses.filter { $0.at <= now }.sorted { $0.at < $1.at }
        let today = DateOnly(now)
        let takenToday = past.filter { $0.dateOnly == today }.count
        let todayMg = DoseEngine.todayTotalMg(past, now: now)

        guard let last = past.last else {
            return DoseStatus(lastDoseAt: nil, lastMg: 0, phase: .none, level: 0,
                              remaining: 0, plasmaTotal: 0, activeCount: 0, todayMg: 0,
                              plasmaLowAt: nil,
                              peakEndAt: nil, effectEndAt: nil,
                              takenToday: 0, generatedAt: now)
        }

        // 感受层：按最近一次服药算。第二片真正做的事是"再制造一次上升"，
        // 不是把效果翻倍，所以阶段和剩余时间都跟着最后那一片走。
        let t = now.timeIntervalSince(last.at) / 3600

        // 药量层：还有残留的每一片相加，这一层才是可加的
        let plasma = DoseEngine.totalPlasma(past, at: now, curve: curve)
        let active = past.filter { d in
            let h = now.timeIntervalSince(d.at) / 3600
            return h > 0 && DoseEngine.plasmaLevel(hoursSinceDose: h, food: d.food, curve: curve)
                * DoseEngine.doseWeight(d.mg) > 0.02
        }.count

        return DoseStatus(lastDoseAt: last.at,
                          lastMg: last.mg,
                          phase: DoseEngine.phase(hoursSinceDose: t),
                          level: DoseEngine.level(hoursSinceDose: t, food: last.food),
                          remaining: DoseEngine.remaining(hoursSinceDose: t),
                          plasmaTotal: plasma,
                          activeCount: active,
                          todayMg: todayMg,
                          plasmaLowAt: DoseEngine.plasmaDropTime(past, to: 0.2, from: now, curve: curve),
                          peakEndAt: DoseEngine.peakEndTime(of: last),
                          effectEndAt: DoseEngine.endTime(of: last),
                          takenToday: takenToday,
                          generatedAt: now)
    }
}

// MARK: - 统计

struct DoseStats {
    let doses: [Dose]
    let effects: [EffectLog]
    let days: [DayLog]

    /// 近 n 天的服药记录
    func recent(days n: Int, now: Date = Date()) -> [Dose] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -n, to: now) ?? now
        return doses.filter { $0.at >= cutoff && $0.at <= now }
    }

    /// 服药率：近 n 天里有服药记录的天数 ÷ n。
    /// 主动标记为"今天不吃"的日子不算漏服，从分母里剔除。
    func adherence(days n: Int, now: Date = Date()) -> (rate: Double, taken: Int, expected: Int) {
        let cal = Calendar.current
        var takenDays = 0, expected = 0
        for i in 0..<n {
            guard let d = cal.date(byAdding: .day, value: -i, to: now) else { continue }
            let day = DateOnly(d)
            if days.first(where: { $0.date == day })?.skipped == true { continue }
            expected += 1
            if doses.contains(where: { $0.dateOnly == day }) { takenDays += 1 }
        }
        let rate = expected > 0 ? Double(takenDays) / Double(expected) : 0
        return (rate, takenDays, expected)
    }

    /// 服药时刻分布：每小时几次（0…23）
    func hourHistogram(days n: Int = 90) -> [Int] {
        var bins = [Int](repeating: 0, count: 24)
        for d in recent(days: n) {
            let h = Calendar.current.component(.hour, from: d.at)
            bins[min(23, max(0, h))] += 1
        }
        return bins
    }

    /// 平均服药时刻与波动（小时，带小数）。跨午夜的记录会拉偏平均值，
    /// 所以只统计凌晨 4 点之后的记录，凌晨 4 点前的按前一天深夜单列。
    func averageHour(days n: Int = 90) -> (mean: Double, sd: Double, count: Int)? {
        let hs = recent(days: n).map(\.hourOfDay).filter { $0 >= 4 }
        guard hs.count >= 2 else { return nil }
        let mean = hs.reduce(0, +) / Double(hs.count)
        let varsum = hs.reduce(0) { $0 + pow($1 - mean, 2) }
        return (mean, sqrt(varsum / Double(hs.count)), hs.count)
    }

    /// 每次服药与前一次的间隔（小时）
    func intervals(days n: Int = 90) -> [Double] {
        let sorted = recent(days: n).sorted { $0.at < $1.at }
        return zip(sorted, sorted.dropFirst()).map { $1.at.timeIntervalSince($0.at) / 3600 }
    }

    /// 各原因出现次数，按多到少
    func reasonCounts(days n: Int = 90) -> [(DoseReason, Int)] {
        var m: [DoseReason: Int] = [:]
        for d in recent(days: n) { for r in d.reasons { m[r, default: 0] += 1 } }
        return m.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    /// 各副作用出现次数，按多到少
    func sideCounts(days n: Int = 90, now: Date = Date()) -> [(SideEffect, Int)] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -n, to: now) ?? now
        var m: [SideEffect: Int] = [:]
        for e in effects where e.at >= cutoff { for s in e.sides { m[s, default: 0] += 1 } }
        return m.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    /// 专注评分的平均值
    func averageFocus(days n: Int = 90, now: Date = Date()) -> (mean: Double, count: Int)? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -n, to: now) ?? now
        let v = effects.filter { $0.at >= cutoff && $0.focus > 0 }.map { Double($0.focus) }
        guard !v.isEmpty else { return nil }
        return (v.reduce(0, +) / Double(v.count), v.count)
    }

    /// 把每条效果记录换算成"服药后第几小时"，用来看效果和时间的关系
    func focusVsHours(days n: Int = 90, now: Date = Date()) -> [(hours: Double, focus: Int)] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -n, to: now) ?? now
        var out: [(Double, Int)] = []
        for e in effects where e.at >= cutoff && e.focus > 0 {
            // 优先用关联的那次服药，没有就找同一天最近的一次在它之前的服药
            let dose = doses.first { $0.id == e.doseID }
                ?? doses.filter { $0.at <= e.at && e.at.timeIntervalSince($0.at) < 24 * 3600 }
                        .max { $0.at < $1.at }
            guard let d = dose else { continue }
            out.append((e.at.timeIntervalSince(d.at) / 3600, e.focus))
        }
        return out
    }

    /// 每天第一次服药的时刻，用于画"最近这些天都几点吃的"
    func firstDoseByDay(days n: Int = 30, now: Date = Date()) -> [(DateOnly, Double)] {
        let cal = Calendar.current
        var out: [(DateOnly, Double)] = []
        for i in stride(from: n - 1, through: 0, by: -1) {
            guard let d = cal.date(byAdding: .day, value: -i, to: now) else { continue }
            let day = DateOnly(d)
            if let first = doses.filter({ $0.dateOnly == day }).min(by: { $0.at < $1.at }) {
                out.append((day, first.hourOfDay))
            }
        }
        return out
    }
}
