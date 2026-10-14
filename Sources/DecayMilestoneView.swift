import SwiftUI

/// Forecast crossings refresh once a minute or when records/model parameters change.
/// The surrounding elapsed-time display can continue updating every second.
struct DecayMilestoneView: View {
    let doses: [Dose]
    let now: Date
    let curve: PlasmaCurveConfiguration
    @State private var milestones: [PlasmaDecayMilestone]?

    private struct Request: Hashable {
        let doses: [Dose]
        let curve: PlasmaCurveConfiguration
        let minute: Int
    }

    private var request: Request {
        Request(doses: doses, curve: curve, minute: Int(now.timeIntervalSince1970 / 60))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("如果之后不再服药")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(YS.text)
                Text("预计下降时间 · 模型估算")
                    .font(.caption).foregroundStyle(YS.dim)
            }

            if doses.isEmpty || milestones?.isEmpty == true {
                Text("暂无已发生的服药记录，无法估算下降时间。")
                    .font(.caption).foregroundStyle(YS.dim)
            } else if let milestones {
                ForEach(milestones, id: \.target) { milestone in
                    milestoneRow(milestone)
                }
            } else {
                Text("正在计算下降时间…")
                    .font(.caption).foregroundStyle(YS.dim)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(YS.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("decayMilestones")
        .task(id: request) {
            milestones = DoseEngine.decayMilestones(doses, from: now, curve: curve)
        }
    }

    private func milestoneRow(_ milestone: PlasmaDecayMilestone) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                targetLabel(milestone.target)
                Spacer(minLength: 0)
                timingLabel(milestone, alignment: .trailing)
                    .fixedSize(horizontal: true, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                targetLabel(milestone.target)
                timingLabel(milestone, alignment: .leading)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private func targetLabel(_ target: Double) -> some View {
        Text("\(target.formatted(.number.precision(.fractionLength(0...1)))) 倍")
            .font(.system(.subheadline, design: .rounded, weight: .semibold))
            .foregroundStyle(YS.teal)
            .monospacedDigit()
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityLabel("目标 \(target.formatted()) 倍")
    }

    @ViewBuilder
    private func timingLabel(_ milestone: PlasmaDecayMilestone,
                             alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            if milestone.alreadyBelow {
                Text("目前已低于此值")
                    .foregroundStyle(YS.dim)
            } else if let at = milestone.at {
                Text(remainingText(until: at))
                    .foregroundStyle(YS.text)
                    .monospacedDigit()
                Text("预计 \(Fmt.mdhm(at))")
                    .font(.caption2).foregroundStyle(YS.dim)
                    .monospacedDigit()
            } else {
                Text("暂无法估算")
                    .foregroundStyle(YS.dim)
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func remainingText(until at: Date) -> String {
        let seconds = at.timeIntervalSince(now)
        if seconds <= 0 { return "预计已到达" }
        if seconds < 60 { return "预计不足 1 分钟" }
        // Round up to avoid displaying zero minutes before the crossing occurs.
        return "约还需 " + Fmt.elapsed(ceil(seconds / 60) * 60)
    }
}
