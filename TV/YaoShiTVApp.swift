import SwiftUI
import UIKit

@main
struct YaoShiTVApp: App {
    @StateObject private var store = TVStore()
    var body: some Scene {
        WindowGroup { TVDashboard().environmentObject(store).preferredColorScheme(.dark) }
    }
}

struct TVDashboard: View {
    @EnvironmentObject private var store: TVStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var ambient = false
    @State private var pairing = false
    @State private var previousIdle = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ZStack {
                Color(red: 0.025, green: 0.035, blue: 0.065).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 25) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("药时").font(.system(size: 40, weight: .bold))
                        Text(context.date, style: .time).font(.system(size: 54, weight: .light, design: .rounded)).monospacedDigit()
                        Spacer()
                        if !ambient { Button("连接手机") { pairing = true }; Button("常显模式") { ambient = true } }
                    }
                    if store.lastReceivedAt == nil {
                        Spacer()
                        Text("把手机上的曲线带到大屏幕")
                            .font(.system(size: 52, weight: .semibold))
                        Text("打开手机药时 → 我的 → 连接 Apple TV。两边确认配对码相同后，电视才会接收曲线数据。")
                            .font(.system(size: 27)).foregroundStyle(.secondary)
                        Button("开始连接") { pairing = true }
                        Spacer()
                    } else if ambient {
                        TVAmbientCurve(doses: store.doses, curve: store.curve, now: context.date)
                        Button("返回互动模式") { ambient = false }.font(.system(size: 20))
                    } else {
                        TVChartView(doses: store.doses, curve: store.curve, now: context.date)
                    }
                    HStack {
                        Text("相对浓度 · 模型估算，非实测血药浓度")
                        Spacer()
                        if let received = store.lastReceivedAt {
                            Text("数据接收：\(received.formatted(date: .abbreviated, time: .shortened))")
                        }
                        Text(store.isConnected ? "手机已连接" : "未连接手机")
                    }.font(.system(size: 19)).foregroundStyle(.secondary)
                }.padding(.horizontal, 70).padding(.vertical, 45)
            }
        }
        .sheet(isPresented: $pairing) { pairingView }
        .onAppear { previousIdle = UIApplication.shared.isIdleTimerDisabled; UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = previousIdle; store.disconnect() }
        .onChange(of: scenePhase) { _, phase in
            UIApplication.shared.isIdleTimerDisabled = phase == .active ? true : previousIdle
            if phase == .background { store.disconnect() }
        }
    }

    private var pairingView: some View {
        VStack(spacing: 28) {
            Text("连接你的手机").font(.largeTitle.bold())
            Text(store.status).multilineTextAlignment(.center)
            if let name = store.invitationName {
                Text("连接请求：\(name)")
                HStack { Button("接受连接") { store.acceptInvitation() }; Button("拒绝") { store.rejectInvitation() } }
            }
            if let code = store.verificationCode {
                Text(code).font(.system(size: 72, weight: .semibold, design: .monospaced))
                Text("请对照手机屏幕上的六位码。只有完全相同，才在两边确认。")
                Button(store.localApproved ? "本机已确认" : "两边代码相同，确认") { store.approveCode() }
                    .disabled(store.localApproved)
            }
            HStack {
                Button("开始配对") { store.startPairing() }
                Button("断开并清除电视数据") { store.disconnect() }
                Button("返回看板") { pairing = false }
            }
        }.padding(70)
    }
}

private struct TVAmbientCurve: View {
    let doses: [Dose]
    let curve: PlasmaCurveConfiguration
    let now: Date
    var body: some View {
        let model = DoseCurveModel(doses: doses, now: now, curve: curve)
        VStack(alignment: .leading, spacing: 20) {
            Text(DoseCurveModel.levelText(model.currentLevel))
                .font(.system(size: 100, weight: .light, design: .rounded)).foregroundStyle(.cyan)
            Canvas { context, size in
                var history = Path(), future = Path()
                for sample in model.samples {
                    let p = CGPoint(x: model.fraction(at: sample.at) * size.width,
                                    y: size.height * (1 - sample.level / model.upperLevel))
                    if sample.at <= now { if history.isEmpty { history.move(to: p) } else { history.addLine(to: p) } }
                    if sample.at >= now { if future.isEmpty { future.move(to: p) } else { future.addLine(to: p) } }
                }
                context.stroke(history, with: .color(.orange), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                context.stroke(future, with: .color(.orange.opacity(0.7)), style: StrokeStyle(lineWidth: 5, dash: [12, 8]))
                let x = model.fraction(at: now) * size.width
                context.stroke(Path { p in p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height)) },
                               with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: 2, dash: [6, 8]))
                context.draw(Text("现在").font(.system(size: 24)).foregroundColor(.white), at: CGPoint(x: x, y: 15))
            }
            HStack { Text(model.start, format: .dateTime.month().day().hour().minute()); Spacer(); Text(model.end, format: .dateTime.month().day().hour().minute()) }
                .font(.system(size: 21)).foregroundStyle(.secondary)
        }
    }
}
