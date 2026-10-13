import SwiftUI
import UIKit

/// A local presentation surface. Screen mirroring is started by the user in Control Center.
struct TVPresentationView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var ambient = true
    @State private var previousIdleTimerDisabled: Bool?

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.periodic(from: .now, by: 15)) { context in
                let episode = DoseEpisode(doses: store.doses, selection: store.doseEpisode, now: context.date,
                                          newRoundGapHours: store.settings.newRoundGapHours)
                let model = DoseCurveModel(doses: store.doses, now: context.date,
                                           curve: store.settings.plasmaCurve)
                VStack(spacing: 12) {
                    header
                    if ambient {
                        ambientDashboard(model: model, size: geometry.size)
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("在本机拖动查值、移动时间与缩放；电视同步显示画面。")
                                    .font(.callout).foregroundStyle(YS.dim)
                                DoseCurve(model: model, phase: store.status.phase,
                                          height: max(170, geometry.size.height * 0.4),
                                          annotations: store.effects.filter { !$0.note.isEmpty },
                                          lifeEvents: store.lifeEvents, expanded: true, episode: episode)
                            }
                            .padding(18)
                            .background(YS.card, in: RoundedRectangle(cornerRadius: 24))
                        }
                    }
                }
                .padding(.horizontal, geometry.size.width > 900 ? 40 : 20)
                .padding(.vertical, 12)
            }
        }
        .background(YS.bg.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear {
            previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            updateIdleTimer(active: scenePhase == .active)
            AppDelegate.setCurveAnalysisPresented(true)
            AppDelegate.setCurveLandscape(true)
        }
        .onChange(of: scenePhase) { _, phase in updateIdleTimer(active: phase == .active) }
        .onDisappear {
            updateIdleTimer(active: false)
            AppDelegate.setCurveAnalysisPresented(false)
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Label("药时 · 大屏", systemImage: "tv")
                .font(.headline).foregroundStyle(YS.dim)
            Spacer()
            Button(ambient ? "查看曲线" : "安静展示") { ambient.toggle() }
                .accessibilityIdentifier("tvPresentationMode")
            Button("退出") { dismiss() }
                .accessibilityIdentifier("closeTVPresentation")
        }
        .font(.system(size: 16, weight: .semibold))
        .buttonStyle(.bordered)
        .tint(YS.teal)
    }

    private func ambientDashboard(model: DoseCurveModel, size: CGSize) -> some View {
        let wide = size.width > size.height
        let numberSize = min(112, max(38, wide ? size.height * 0.15 : size.width * 0.14))
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 24) {
                Text(Fmt.hm(model.now))
                    .font(.system(size: numberSize, weight: .light, design: .rounded))
                    .monospacedDigit().foregroundStyle(YS.text)
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(DoseCurveModel.levelText(model.currentLevel))
                        .font(.system(size: numberSize * 0.68, weight: .semibold, design: .rounded))
                        .monospacedDigit().foregroundStyle(YS.teal)
                        .minimumScaleFactor(0.5).lineLimit(1)
                    Text("现在相对浓度 · 模型估算")
                        .font(.system(size: max(13, numberSize * 0.19)))
                        .foregroundStyle(YS.dim)
                }
            }
            ambientCurve(model)
                .frame(maxHeight: .infinity)
            HStack {
                Text(Fmt.mdhm(model.start))
                Spacer()
                Text(Fmt.mdhm(model.end))
            }
            .font(.system(size: 13, design: .rounded)).foregroundStyle(YS.dim)
            Text("实线为过去，虚线为未来估算 · 非实测血药浓度，也不是药效倍数")
                .font(.system(size: 12)).foregroundStyle(YS.dim)
            if store.doses.isEmpty {
                Text("本机尚无服药记录").font(.callout).foregroundStyle(YS.amber)
            }
        }
    }

    private func ambientCurve(_ model: DoseCurveModel) -> some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let height = max(1, geometry.size.height - 22)
            let x: (Date) -> CGFloat = { CGFloat(model.fraction(at: $0)) * width }
            let y: (Double) -> CGFloat = { height - CGFloat($0 / model.upperLevel) * max(1, height - 16) }
            ZStack(alignment: .topLeading) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: y(1)))
                    path.addLine(to: CGPoint(x: width, y: y(1)))
                }
                .stroke(YS.dim.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                Text("1.0 倍").font(.caption).foregroundStyle(YS.dim).offset(y: y(1) - 18)
                curvePath(model.samples.filter { $0.at <= model.now }, x: x, y: y)
                    .stroke(YS.teal, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                curvePath(model.samples.filter { $0.at >= model.now }, x: x, y: y)
                    .stroke(YS.teal.opacity(0.65), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [7, 6]))
                Path { path in
                    path.move(to: CGPoint(x: x(model.now), y: 0))
                    path.addLine(to: CGPoint(x: x(model.now), y: height))
                }
                .stroke(YS.dim, style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                Circle().fill(YS.text).frame(width: 10, height: 10)
                    .position(x: x(model.now), y: y(model.currentLevel))
                Text("现在").font(.caption).foregroundStyle(YS.text)
                    .position(x: x(model.now), y: height + 12)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("相对浓度估算曲线")
        .accessibilityValue("现在 \(DoseCurveModel.levelText(model.currentLevel))，\(Fmt.mdhm(model.now))")
    }

    private func curvePath(_ samples: [DoseCurveModel.Sample], x: (Date) -> CGFloat,
                           y: (Double) -> CGFloat) -> Path {
        Path { path in
            for (index, sample) in samples.enumerated() {
                let point = CGPoint(x: x(sample.at), y: y(sample.level))
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
        }
    }

    private func updateIdleTimer(active: Bool) {
        guard let previousIdleTimerDisabled else { return }
        UIApplication.shared.isIdleTimerDisabled = active ? true : previousIdleTimerDisabled
    }
}
