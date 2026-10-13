import SwiftUI

struct TVLinkSettingsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var link = TVLink(role: .sender)
    var body: some View {
        List {
            Section("连接电视") {
                Text("在 Apple TV 原生药时中按“开始配对”，再搜索电视。双方核对相同的六位验证码后，才允许发送曲线。")
                Button("搜索附近电视") { link.start() }
                ForEach(link.peers) { peer in
                    Button(peer.name) { link.connect(peer) }.disabled(link.isConnected)
                }
                Text(link.status).font(.callout).foregroundStyle(.secondary)
            }
            if let code = link.verificationCode {
                Section("核对两端验证码") {
                    Text(code).font(.system(size: 40, weight: .bold, design: .monospaced))
                    Text("请确认电视上也显示这一组数字。如不一致，请断开；不要确认。")
                    Button(link.localApproved ? "本机已确认，等待电视" : "两端数字完全相同") { link.approveCode() }
                        .disabled(link.localApproved)
                }
            }
            if link.ready {
                Section("发送曲线") {
                    Button("发送最新曲线到电视") {
                        link.sendSnapshot(TVCurveSnapshot(doses: store.doses, curve: store.settings.plasmaCurve))
                    }
                    Text("仅发送服药时间、剂量、进食状态和绘图参数；不发送笔记、感受、原因或身份信息。每次按按钮才更新。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Button("断开连接", role: .destructive) { link.disconnect() }
                Text("离开此页或手机进入后台即断开传送。电视会继续显示本次收到的曲线，直到在电视上清除或退出电视 App；不会写入磁盘。下次连接重新核对验证码。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("连接 Apple TV")
        .onDisappear { link.disconnect() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { link.disconnect() } }
    }
}
