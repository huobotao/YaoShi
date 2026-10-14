import SwiftUI

/// Shared by both builds; starting is always an explicit action on this device.
struct LocationSharingView: View {
    @ObservedObject private var manager = LocationSharingManager.shared
    @ObservedObject private var sharing = PartnerSharingCoordinator.shared
    @State private var confirmStart = false
    @Environment(\.openURL) private var openURL

    private var credentials: PartnerSpaceCredentials? { sharing.credentials[.yaoShi] }
    private var newestReceived: (sample: LocationSample, receivedAt: Date, author: String)? {
        manager.received.flatMap { item in
            item.batch.samples.map { (sample: $0, receivedAt: item.receivedAt, author: item.author) }
        }.max { $0.sample.sampledAt < $1.sample.sampledAt }
    }

    var body: some View {
        List {
            Section {
                Text(manager.enabled ? "本机位置共享已开启" : "本机位置共享已关闭")
                    .font(.headline)
                Text(manager.status).font(.callout).foregroundStyle(.secondary)
                if let credentials {
                    LabeledContent("共享对象", value: "当前共享空间的伴侣")
                    Text("持有效邀请加入此空间的人可接收位置；此页面不能确认对方是否已加入或正在查看。")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("服务地址", value: credentials.baseURL.absoluteString)
                        .font(.caption).textSelection(.enabled)
                } else {
                    Text("请先通过伴侣共享连接共享空间。连接完成前不能开启位置共享。")
                }
                NavigationLink("管理伴侣共享") {
                    Form { PartnerSharingSettingsSection(app: .yaoShi) }
                        .scrollContentBackground(.hidden).background(Color.black)
                        .navigationTitle("伴侣共享")
                }
                #if targetEnvironment(macCatalyst)
                Text("Mac 版仅查看已收到的位置；请在 iPhone 上开启采集。")
                    .font(.caption).foregroundStyle(.secondary)
                #else
                if manager.enabled {
                    Button("停止本机位置共享", role: .destructive) { manager.stopSharing() }
                } else {
                    Button("开启本机位置共享") { confirmStart = true }
                        .disabled(credentials == nil)
                }
                #endif
            } footer: {
                Text("只共享本机的位置。停止后不再采集或发送，尚未发送的缓存会丢弃；对方已收到的位置不会因此撤回。")
            }
            Section {
                LabeledContent("定位权限", value: manager.authorizationText)
                #if !targetEnvironment(macCatalyst)
                Button("申请始终允许定位") { manager.requestAlwaysPermission() }
                    .disabled(!manager.enabled)
                Button("打开系统权限设置") {
                    if let url = URL(string: "app-settings:") { openURL(url) }
                }
                #endif
                LabeledContent("待发送位置点", value: "\(manager.pendingCount)")
                LabeledContent("最近上传成功", value: dateText(manager.lastUploadAt))
                if manager.discardedSampleCount > 0 {
                    Text("因停止、保存期限或容量限制，累计丢弃 \(manager.discardedSampleCount) 个未发送位置点。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button(manager.isWorking ? "正在刷新…" : "刷新位置共享") {
                    Task {
                        await manager.refresh()
                    }
                }.disabled(manager.isWorking)
            } header: {
                Text("权限与发送")
            } footer: {
                Text("采集到的位置先保存在本机，目标每五分钟批量上传。系统调度、权限、网络或关闭 App 可能造成延迟或中断，不能保证准点或连续定位。系统定位提示会保留，本功能不发送位置通知。")
            }
            Section("本机最后采集的位置") {
                if let sample = manager.lastSample { sampleView(sample) }
                else { Text("尚未采集到位置").foregroundStyle(.secondary) }
            }
            Section {
                if let latest = newestReceived {
                    LabeledContent("来源", value: latest.author == PartnerBuildConfiguration.role.rawValue ? "我的其他设备" : "共享空间的伴侣")
                    sampleView(latest.sample)
                    LabeledContent("本机收到时间", value: dateText(latest.receivedAt))
                } else { Text("尚未收到对方位置").foregroundStyle(.secondary) }
            } header: {
                Text("最新共享位置（已接收缓存）")
            } footer: {
                Text("补传的旧位置不会变成实时位置。请检查采样时间与误差；有位置不代表人身安全。第一步暂不包含失联告警或位置规则。位置缓存最多保存七天，并有容量限制。")
            }
            Section("位置附带信息") {
                Text("记录时间、经纬度、定位精度，以及系统提供的高度、速度和方向；附带当前网络连接类型（如 Wi‑Fi 或蜂窝）。")
                Text("不扫描附近蓝牙设备或 Wi‑Fi 列表，不记录 Wi‑Fi 名称。网络类型不表示此次定位来自哪一种信号。")
                    .foregroundStyle(.secondary)
            }.font(.caption)
        }
        .scrollContentBackground(.hidden)
        .background(Color.black)
        .preferredColorScheme(.dark)
        .navigationTitle("位置共享")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            manager.foreground()
            await MedicationShareRepository.shared.sync()
        }
        .confirmationDialog("开启本机持续位置共享？", isPresented: $confirmStart, titleVisibility: .visible) {
            Button("同意并开启共享") { manager.startSharing() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将本机位置、时间、精度及网络类型经当前服务发送给共享空间的伴侣，直到你停止共享。目标每五分钟批量上传，可能延迟或中断。系统定位权限和提示仍会显示。")
        }
    }

    @ViewBuilder private func sampleView(_ sample: LocationSample) -> some View {
        LabeledContent("采样时间", value: dateText(sample.sampledAt))
        LabeledContent("估计水平误差", value: "约 \(sample.horizontalAccuracy.formatted(.number.precision(.fractionLength(0)))) 米")
        Text(String(format: "%.6f, %.6f", sample.latitude, sample.longitude))
            .font(.caption.monospaced()).textSelection(.enabled)
        LabeledContent("网络类型", value: networkText(sample.networkTransport))
        if let url = URL(string: "https://maps.apple.com/?ll=\(sample.latitude),\(sample.longitude)&q=\(sample.latitude),\(sample.longitude)") {
            Link("在地图查看此采样点", destination: url)
        }
    }

    private func dateText(_ date: Date?) -> String {
        date?.formatted(date: .abbreviated, time: .standard) ?? "尚无记录"
    }
    private func networkText(_ value: String) -> String {
        switch value {
        case "wifi": return "Wi‑Fi"
        case "cellular": return "蜂窝网络"
        case "ethernet": return "有线网络"
        case "offline": return "离线"
        case "other": return "其他网络"
        default: return value == "unknown" ? "未知" : value
        }
    }
}
