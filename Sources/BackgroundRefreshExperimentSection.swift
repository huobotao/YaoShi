#if os(iOS) && !targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

/// Local background-refresh settings; never synchronized between devices.
struct BackgroundRefreshExperimentSection: View {
    @ObservedObject private var experiment = BackgroundRefreshExperiment.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            LabeledContent("定位权限", value: experiment.authorizationText)
                .accessibilityIdentifier("backgroundRefreshLocationAuthorization")
            if experiment.authorizationStatus != .authorizedAlways {
                Button("申请始终允许定位") {
                    experiment.requestAlwaysAuthorization()
                }
                .disabled(experiment.needsSettings)
                .accessibilityIdentifier("requestAlwaysLocationAuthorization")
            }
            Text(experiment.alwaysAuthorizationMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            LabeledContent("状态") {
                Text(experiment.statusText)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("backgroundRefreshExperimentStatus")
            }
            if experiment.isEnabled {
                Button(role: .destructive) {
                    experiment.stop()
                } label: {
                    Label("关闭后台刷新", systemImage: "stop.circle")
                }
                .accessibilityIdentifier("stopBackgroundRefreshExperiment")
            } else {
                Button {
                    experiment.start()
                } label: {
                    Label("开启后台刷新", systemImage: "location.circle")
                }
                .disabled(experiment.needsSettings)
                .accessibilityIdentifier("startBackgroundRefreshExperiment")
            }
            if experiment.needsSettings || experiment.authorizationStatus != .notDetermined {
                Button("打开系统设置查看定位权限") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    openURL(url)
                }
                .accessibilityIdentifier("backgroundRefreshExperimentSettings")
            }
        } header: {
            Text("后台刷新（定位）")
        } footer: {
            Text("默认开启，没有自动停止时限；打开 App 后自动恢复。使用后台定位机会更新浓度，不保存或上传位置，可能增加耗电；系统可能显示定位指示或暂停运行。开关仅对本机生效。")
                .font(.system(size: 11))
        }
        .onAppear { experiment.ensureLifecycle() }
    }
}
#endif
