import SwiftUI

/// Shared by the owner and partner builds. It exposes only the controls allowed
/// by the credential role; record-specific sharing stays in each app's UI.
struct PartnerSharingSettingsSection: View {
    let app: PartnerApp

    var body: some View {
        Section {
            PartnerSharingControls(app: app)
        } header: {
            Text("伴侣共享")
        } footer: {
            Text("记录先保存在本机。共享服务暂时不可用时，当前设备仍可继续使用；待发送内容会保留，联网后重试。对方在同步成功前看不到新记录。")
                .font(.system(size: 11))
        }
    }
}

struct PartnerSharingControls: View {
    let app: PartnerApp

    @ObservedObject private var coordinator = PartnerSharingCoordinator.shared
    @State private var serverAddress = ""
    @State private var confirmRevoke = false

    private var credentials: PartnerSpaceCredentials? { coordinator.credentials[app] }
    private var journal: PartnerSyncJournal? { coordinator.journals[app] }
    private var roleText: String {
        switch credentials?.role {
        case .owner: return "你是共享空间创建者"
        case .partner: return "你已加入伴侣共享空间"
        case nil: return "尚未连接伴侣共享空间"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(roleText).font(.system(size: 13, weight: .medium))

            if let status = coordinator.status[app] {
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let journal {
                if !journal.outbox.isEmpty {
                    Label("本机待发送 \(journal.outbox.count) 条", systemImage: "arrow.up.circle")
                        .font(.system(size: 12))
                }
                if !journal.incoming.isEmpty {
                    Label("待写入本机 \(journal.incoming.count) 条", systemImage: "arrow.down.circle")
                        .font(.system(size: 12))
                }
            }

            if credentials != nil {
                Button {
                    Task { await coordinator.sync(app: app) }
                } label: {
                    Label("立即同步", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(coordinator.workingApps.contains(app))
            }

            if credentials?.role == .owner || (credentials == nil && PartnerBuildConfiguration.role == .owner) {
                TextField("共享服务 HTTPS 地址", text: $serverAddress)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()

                Button {
                    Task { await coordinator.createInvite(app: app, serverText: serverAddress) }
                } label: {
                    Label(coordinator.workingApps.contains(app) ? "正在连接…" : "生成配偶邀请", systemImage: "person.badge.plus")
                }
                .disabled(coordinator.workingApps.contains(app) || serverAddress.isEmpty)

                if let link = coordinator.inviteLinks[app] {
                    ShareLink(item: link, preview: SharePreview("加入\(app.displayName)共享")) {
                        Label("分享邀请链接", systemImage: "square.and.arrow.up")
                    }
                }

                Button("撤销配偶访问", role: .destructive) { confirmRevoke = true }
                    .disabled(coordinator.workingApps.contains(app))
            } else if credentials?.role == .partner || PartnerBuildConfiguration.role == .partner {
                Text("共享内容按此 App 的权限显示。你可以在记录下发表评论；服药或试纸等指定操作仍由对应记录者完成。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                Text("配对前不会向伴侣发送任何记录。共享服务恢复前，App 仍可使用本机已有内容；待同步变化会留在本机队列。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("撤销配偶访问？", isPresented: $confirmRevoke, titleVisibility: .visible) {
            Button("撤销访问", role: .destructive) {
                Task { await coordinator.revokePartner(app: app) }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("撤销后对方无法继续同步；已经下载、导出或截图的内容无法远程删除。")
        }
    }
}

private extension PartnerApp {
    var displayName: String { self == .yaoShi ? "药时" : "备孕" }
}
