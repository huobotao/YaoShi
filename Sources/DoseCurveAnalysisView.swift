import SwiftUI

/// 首页曲线的全屏分析视图。保留原始记录，只让显示窗口延展到完整历史。
struct DoseCurveAnalysisView: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var editingNote: EffectLog?
    @State private var forceLandscape = false

    private var notes: [EffectLog] {
        store.effects.filter { !$0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.at < $1.at }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            GeometryReader { geometry in
                let now = context.date
                let model = DoseCurveModel(doses: store.doses, now: now,
                                           curve: store.settings.plasmaCurve)
                let chartHeight = min(620, max(190, geometry.size.height * (geometry.size.width > geometry.size.height ? 0.42 : 0.52)))

                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 7) {
                                Image(systemName: "waveform.path")
                                    .foregroundStyle(YS.teal)
                                Text("过去与未来可继续移动 · 双指缩放")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(YS.text)
                            }
                            DoseCurve(model: model,
                                      phase: store.status.phase,
                                      height: chartHeight,
                                      annotations: notes,
                                      lifeEvents: store.lifeEvents,
                                      expanded: true,
                                      onEditNote: { editingNote = $0 })
                            Text("曲线是通用参数下的相对浓度模型估算。橙色笔记标记按记录时刻定位；点击可阅读或编辑原笔记。")
                                .font(.system(size: 12))
                                .foregroundStyle(YS.dim)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 12)
                        .padding(.bottom, 28)
                    }
                    .background(YS.bg.ignoresSafeArea())
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { dismiss() } label: {
                                Label("完成", systemImage: "xmark")
                            }
                            .labelStyle(.iconOnly)
                            .accessibilityLabel("关闭曲线分析")
                        }
                        ToolbarItem(placement: .principal) {
                            Text("曲线分析")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(YS.text)
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                forceLandscape.toggle()
                                AppDelegate.setCurveLandscape(forceLandscape)
                            } label: {
                                Label(forceLandscape ? "自动方向" : "横屏",
                                      systemImage: forceLandscape ? "iphone" : "rotate.right")
                            }
                            .labelStyle(.titleAndIcon)
                            .font(.system(size: 12, weight: .semibold))
                            .accessibilityIdentifier("toggleCurveLandscape")
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $editingNote) { log in
            if log.isNoteOnly {
                NoteEditor(log: log, doses: store.doses) { store.saveEffect($0) } onDelete: { store.delete($0) }
            } else {
                EffectEditor(log: log, doses: store.doses) { store.saveEffect($0) } onDelete: { store.delete($0) }
            }
        }
        .onAppear { AppDelegate.setCurveAnalysisPresented(true) }
        .onDisappear { AppDelegate.setCurveAnalysisPresented(false) }
    }
}
