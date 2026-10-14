import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var s = SyncedSettings()
    @State private var loaded = false
    @State private var showTVPresentation = false

    var body: some View {
        NavigationStack {
            Form {
                recordingSection
                plasmaCurveSection
                syncSection
                #if os(iOS) && !targetEnvironment(macCatalyst)
                if Bundle.main.object(forInfoDictionaryKey: "YaoShiBackgroundLocationExperiment") as? Bool == true {
                    BackgroundRefreshExperimentSection()
                }
                #endif
                tvPresentationSection
                PartnerSharingSettingsSection(app: .yaoShi)
                Section {
                    NavigationLink("位置共享") { LocationSharingView() }
                }
                storageSection
                aboutSection
            }
            .scrollContentBackground(.hidden)
            .background(YS.bg)
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(isPresented: $showTVPresentation) {
                TVPresentationView().environmentObject(store)
            }
            .onAppear {
                if !loaded { s = store.settings; loaded = true }
            }
            .onChange(of: store.settings) { old, new in
                if s == old { s = new }
            }
        }
    }

    private var tvPresentationSection: some View {
        Section {
            Button { showTVPresentation = true } label: {
                Label("打开电视大屏展示", systemImage: "tv")
                    .foregroundStyle(YS.teal)
            }
            .accessibilityIdentifier("openTVPresentation")
            NavigationLink("连接 Apple TV 原生版") { TVLinkSettingsView() }
        } header: {
            Text("Apple TV 与大屏")
        } footer: {
            Text("先在控制中心打开「屏幕镜像」，选择你的 Apple TV，再打开此横向展示页。画面会包含本机记录；查值、移动时间和缩放仍在 iPhone、iPad 或 Mac 上操作。安静展示保留时钟和当前曲线；展示页处于前台时保持亮屏，退出或进入后台后恢复原设置。")
                .font(.system(size: 11))
        }
    }

    // MARK: 血浆曲线

    private var plasmaCurveSection: some View {
        Section {
            Stepper("达峰时间 \(String(format: "%.1f", Double(s.plasmaPeakTenthHours) / 10)) 小时",
                    value: Binding(
                        get: { s.plasmaPeakTenthHours },
                        set: { value in
                            s.plasmaPeakTenthHours = value
                            store.updateSettings(s)
                        }),
                    in: 10...120, step: 1)
                .accessibilityIdentifier("plasmaPeakTime")

            Stepper("半衰期 \(String(format: "%.1f", Double(s.plasmaHalfLifeTenthHours) / 10)) 小时",
                    value: Binding(
                        get: { s.plasmaHalfLifeTenthHours },
                        set: { value in
                            s.plasmaHalfLifeTenthHours = value
                            store.updateSettings(s)
                        }),
                    in: 20...300, step: 1)
                .accessibilityIdentifier("plasmaHalfLife")

            Button("恢复说明书参考值") {
                s.plasmaPeakTenthHoursOverride = nil
                s.plasmaHalfLifeTenthHoursOverride = nil
                store.updateSettings(s)
            }
            .foregroundStyle(YS.teal)
        } header: {
            Text("血浆曲线参数")
        } footer: {
            Text("按活性成分右苯丙胺调整。默认达峰 3.8 小时（成人空腹胶囊）；半衰期 10.7 小时是成人公开范围 10–11.3 小时的代表值。模型据此反推吸收速度，固定保留 0.5 小时时滞和现有随餐延迟假设。设置会同步到你的其他 iPhone。图线是归一化模型估算，不是个人实测血药浓度；只影响浓度曲线与 0.2 倍预测，不改变药效阶段，也不能用于判断是否再次服药。")
                .font(.system(size: 11))
        }
    }

    // MARK: 记录与显示

    private var recordingSection: some View {
        Section {
            Stepper("每粒剂量 \(s.defaultMg) 毫克", value: $s.defaultMg, in: 5...140, step: 5)
                .onChange(of: s.defaultMg) { _, _ in store.updateSettings(s) }

            Stepper("记录分波间隔 \(s.newRoundGapHours) 小时", value: Binding(
                get: { s.newRoundGapHours },
                set: { value in
                    s.newRoundGapHours = value
                    store.updateSettings(s)
                }
            ), in: 1...720)
            .accessibilityIdentifier("newRoundGapHours")

            DatePicker("参考就寝时间",
                       selection: Binding(
                        get: {
                            Calendar.current.date(bySettingHour: s.bedtimeHour,
                                                  minute: s.bedtimeMinute, second: 0, of: Date()) ?? Date()
                        },
                        set: { d in
                            let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                            s.bedtimeHour = c.hour ?? 23
                            s.bedtimeMinute = c.minute ?? 0
                            store.updateSettings(s)
                        }),
                       displayedComponents: .hourAndMinute)
                .environment(\.locale, Locale(identifier: "zh_CN"))

            #if !targetEnvironment(macCatalyst)
            Toggle("锁屏和灵动岛常驻显示", isOn: $s.liveActivityEnabled)
                .onChange(of: s.liveActivityEnabled) { _, _ in store.updateSettings(s) }
            #endif
        } header: {
            Text("记录与显示")
        } footer: {
            Text("按实际需要记录服药，不设每日服药目标，也不会给你发送服药、余量或配药提醒。每粒剂量用于按粒记录和模拟；修改设置不会改写已有服药记录。相邻两次实记服药间隔超过此时长时，后一笔按记录时间归入新一波；启用伴侣共享后，妻子会收到每条新记录、分波间隔到达和之后每日的状态通知。这里的分波间隔只用于记录分组，不代表药效持续、药物已代谢完或是否适合再次服药。")
                .font(.system(size: 11))
        }
    }

    // MARK: 同步

    private var syncSection: some View {
        Section {
            #if targetEnvironment(macCatalyst)
            if Bundle.main.object(forInfoDictionaryKey: "YaoShiCloudSyncEnabled") as? Bool != true {
                Text("当前为 Mac 本地版：记录保存在这台 Mac。跨设备同步和伴侣共享需要包含共享钥匙串权限的 Mac 签名配置，尚未启用。")
                    .font(.callout).foregroundStyle(YS.dim)
            }
            #endif
            HStack {
                Text("状态")
                Spacer()
                Text(store.syncStatusLine).font(.system(size: 13))
                    .foregroundStyle(YS.dim).multilineTextAlignment(.trailing)
            }
            Button {
                store.syncNow()
            } label: {
                Label(store.syncing ? "正在同步…" : "立即同步", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(YS.teal)
            }
            .disabled(store.syncing)
        } header: {
            Text("跨设备同步")
        } footer: {
            Text("使用同一签名团队且获准访问共享钥匙串的设备须登录同一个 Apple ID，并开启 iCloud 的「密码与钥匙串」。首次对齐请在各台设备上打开药时并联网；前台每 15 秒检查一次。系统传送可能延迟；只有收到另一台设备的回执才显示接收确认。")
                .font(.system(size: 11))
        }
    }

    // MARK: 存储自检

    private var storageSection: some View {
        Section {
            ForEach(store.storageReport, id: \.0) { k, v in
                HStack {
                    Text(k)
                    Spacer()
                    Text(v).foregroundStyle(store.storageOK ? YS.dim : YS.red)
                        .font(.system(size: 13)).multilineTextAlignment(.trailing)
                }
            }
        } header: {
            Text("存储自检")
        } footer: {
            Text("每次记录都会立刻写盘、回读校验，并留一份备份。这里的条数和写盘时间就是证据——按一下记录，条数应该马上变。")
                .font(.system(size: 11))
        }
    }

    private var appVersionLabel: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    private var aboutSection: some View {
        Section("关于") {
            HStack { Text("版本"); Spacer(); Text(appVersionLabel).foregroundStyle(YS.dim) }
            HStack {
                Text("代码版本")
                Spacer()
                Text(sourceRevisionLabel).font(.system(.caption, design: .monospaced)).foregroundStyle(YS.dim)
                    .textSelection(.enabled)
            }
            HStack { Text("制作"); Spacer(); Text("Claude").foregroundStyle(YS.dim) }
            Text("笔记和记录保存在本机，并使用同一 Apple ID 的 iCloud 钥匙串在你的设备间同步。曲线基于公开药代数据估算，不是你个人实测的血药浓度，也不能精确预测入睡、食欲或工作效率。")
                .font(.system(size: 11)).foregroundStyle(YS.dim)
        }
    }

    private var sourceRevisionLabel: String {
        let revision = Bundle.main.object(forInfoDictionaryKey: "YaoShiSourceRevision") as? String ?? "未标记"
        let dirty = Bundle.main.object(forInfoDictionaryKey: "YaoShiSourceDirty") as? Bool ?? false
        return revision + (dirty ? " · 本地修改" : "")
    }
}
