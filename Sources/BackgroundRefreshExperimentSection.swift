#if os(iOS) && !targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

/// Local, explicit test control; deliberately has no SyncedSettings binding.
struct BackgroundRefreshExperimentSection: View {
    @ObservedObject private var experiment = BackgroundRefreshExperiment.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            LabeledContent("状态") {
                Text(experiment.statusText)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("backgroundRefreshExperimentStatus")
            }
            if let end = experiment.endsAt, experiment.isRunning {
                LabeledContent("自动停止") {
                    Text(end, style: .time).monospacedDigit()
                }
            }
            if experiment.isRunning {
                Button(role: .destructive) {
                    experiment.stop()
                } label: {
                    Label("立即停止实验", systemImage: "stop.circle")
                }
                .accessibilityIdentifier("stopBackgroundRefreshExperiment")
            } else {
                Button {
                    experiment.start()
                } label: {
                    Label("开始 15 分钟实验", systemImage: "location.circle")
                }
                .disabled(experiment.needsSettings)
                .accessibilityIdentifier("startBackgroundRefreshExperiment")
            }
            if experiment.needsSettings {
                Button("打开系统设置查看定位权限") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                }
                .accessibilityIdentifier("backgroundRefreshExperimentSettings")
            }
        } header: {
            Text("后台刷新实验（定位）")
        } footer: {
            Text("仅在本机手动开启，15 分钟后自动停止。实验使用后台定位运行机会尝试更新浓度，不保存或上传位置，可能增加耗电；系统可能显示定位指示。它不保证持续刷新，退出实验后不会自动重启，也不会同步到其他设备。")
                .font(.system(size: 11))
        }
        .onAppear { experiment.ensureLifecycle() }
    }
}
#endif
