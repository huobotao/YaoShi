import SwiftUI
import WatchKit

final class YaoShiWatchDelegate: NSObject, WKApplicationDelegate {
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        Task { @MainActor in
            for task in backgroundTasks {
                if let connectivity = task as? WKWatchConnectivityRefreshBackgroundTask {
                    YaoShiWatchLink.shared.retainBackgroundTask(connectivity)
                } else if let snapshot = task as? WKSnapshotRefreshBackgroundTask {
                    snapshot.setTaskCompleted(restoredDefaultState: true, estimatedSnapshotExpiration: .distantFuture, userInfo: nil)
                } else { task.setTaskCompletedWithSnapshot(false) }
            }
        }
    }
}

@main
struct YaoShiWatchApp: App {
    @WKApplicationDelegateAdaptor(YaoShiWatchDelegate.self) private var delegate
    @StateObject private var link = YaoShiWatchLink.shared
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            WatchCurveView().environmentObject(link)
                .tint(.mint)
                .onAppear { link.setActive(phase == .active) }
                .onChange(of: phase) { _, phase in link.setActive(phase == .active) }
        }
    }
}

private struct DoseConfirmation: Identifiable {
    let id = UUID()
    let mg: Int
    let med: String
}

private struct WatchNoteDraft: Identifiable {
    let id = UUID()
    let at = Date()
}

struct WatchDoseView: View {
    @EnvironmentObject private var link: YaoShiWatchLink
    @State private var confirmation: DoseConfirmation?
    @State private var noteDraft: WatchNoteDraft?

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                // State-driven redraws can happen between ticks, immediately after saving a note.
                let now = max(context.date, Date())
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Button { noteDraft = WatchNoteDraft() } label: {
                            Label("添加笔记", systemImage: "square.and.pencil")
                                .font(.system(size: 16, weight: .semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!link.storageReady || link.state.pendingNotes.count >= 100)
                        latest(at: now)
                        Button {
                            if let settings = link.state.snapshot {
                                confirmation = .init(mg: settings.defaultMg, med: settings.defaultMed)
                            }
                        } label: {
                            Label("记下刚刚服药", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!link.storageReady || link.state.snapshot?.allowsRecording != true || link.state.pending.count >= 100)
                        todayNotes(at: now)
                        today(at: now)
                        syncStatus
                    }.padding(.horizontal, 3).padding(.bottom, 12)
                }
            }
            .navigationTitle("药时")
            .sheet(item: $confirmation) { draft in
                confirmationView(draft)
            }
            .sheet(item: $noteDraft) { draft in
                WatchNoteEditor(draft: draft).environmentObject(link)
            }
        }
    }

    @ViewBuilder private func latest(at now: Date) -> some View {
        let last = link.state.records.first { $0.at <= now }
        VStack(alignment: .leading, spacing: 4) {
            Label("距上次服药", systemImage: "pills.fill")
                .font(.caption).foregroundStyle(.mint)
            if let last {
                Text(elapsed(since: last.at, now: now))
                    .font(.system(size: 29, weight: .semibold, design: .rounded))
                    .monospacedDigit().minimumScaleFactor(0.65).lineLimit(1)
                Text("\(last.med) · \(last.mg) 毫克").font(.caption)
                Text(last.at.formatted(.dateTime.month().day().hour().minute()))
                    .font(.caption2).foregroundStyle(.secondary)
                if link.state.pending.contains(where: { $0.id == last.id }) {
                    Text("已存手表 · 等待手机确认").font(.caption2).foregroundStyle(.orange)
                }
            } else {
                Text(link.state.snapshot == nil ? "先连接手机" : "还没有记录")
                    .font(.title3.weight(.semibold))
                Text(link.state.snapshot == nil ? "在配对的 iPhone 打开药时，同步现有记录和默认剂量。" : "仅记录你已经实际服用的药。")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func today(at now: Date) -> some View {
        let rows = link.state.records.filter { Calendar.current.isDate($0.at, inSameDayAs: now) && $0.at <= now }
        return VStack(alignment: .leading, spacing: 7) {
            Text("今日记录 · \(rows.count) 次").font(.headline)
            if rows.isEmpty {
                Text("暂无已收到的记录").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                HStack(alignment: .top) {
                    Text(row.at.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                    Spacer(minLength: 4)
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("\(row.mg) 毫克")
                        if link.state.pending.contains(where: { $0.id == row.id }) {
                            Text("待同步").font(.system(size: 10)).foregroundStyle(.orange)
                        }
                    }
                }.font(.caption)
            }
        }
    }

    private func todayNotes(at now: Date) -> some View {
        let rows = link.state.notes.filter { Calendar.current.isDate($0.at, inSameDayAs: now) && $0.at <= now }
        return VStack(alignment: .leading, spacing: 8) {
            Text("今日笔记 · \(rows.count) 条").font(.headline)
            if rows.isEmpty {
                Text("记下此时此刻的感受").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                NavigationLink {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(row.at.formatted(.dateTime.month().day().hour().minute()))
                                .font(.caption).foregroundStyle(.mint)
                            Text(row.note).frame(maxWidth: .infinity, alignment: .leading)
                            if link.state.pendingNotes.contains(where: { $0.id == row.id }) {
                                Text("已存手表 · 等待手机确认").font(.caption2).foregroundStyle(.orange)
                            }
                        }
                    }.navigationTitle("此刻感受")
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(row.at.formatted(date: .omitted, time: .shortened)).monospacedDigit()
                            if link.state.pendingNotes.contains(where: { $0.id == row.id }) {
                                Text("待同步").foregroundStyle(.orange)
                            }
                        }.font(.caption2)
                        Text(row.note).font(.caption).lineLimit(3)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if rows.count >= 12 { Text("更多笔记可在手机查看").font(.caption2).foregroundStyle(.secondary) }
        }
    }

    private var syncStatus: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !link.state.pending.isEmpty || !link.state.pendingNotes.isEmpty {
                Label("\(link.state.pending.count + link.state.pendingNotes.count) 条已存手表，等待手机确认", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange)
            }
            if !link.state.pendingNotes.isEmpty, let snapshot = link.state.snapshot, snapshot.supportsNotes != true {
                Text("笔记已保存在手表，请在配对的 iPhone 更新并打开药时以同步。").foregroundStyle(.orange)
            }
            if link.state.pendingNotes.count >= 100 { Text("待同步笔记已满，请先连接手机同步。").foregroundStyle(.orange) }
            if let snapshot = link.state.snapshot {
                Text("手机数据更新：\(snapshot.generatedAt.formatted(.dateTime.month().day().hour().minute()))")
                    .foregroundStyle(.secondary)
            }
            if let issue = link.issue { Text(issue).foregroundStyle(.orange) }
            Button("刷新与重试") { link.refresh() }.font(.caption)
            Text("误记可在手机的「记录」页删除。")
                .foregroundStyle(.secondary)
        }.font(.caption2)
    }

    private func confirmationView(_ draft: DoseConfirmation) -> some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Image(systemName: "pills.fill").font(.title).foregroundStyle(.mint)
                    Text("\(draft.med)\n\(draft.mg) 毫克")
                        .font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                    Text("来自手机设置的默认剂量。确认你刚刚已实际服用，再保存记录。")
                        .font(.caption2).foregroundStyle(.secondary)
                    if let latest = link.state.records.first {
                        Text("上一条：\(latest.at.formatted(.dateTime.month().day().hour().minute()))，\(latest.mg) 毫克")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                    Button("确认已服用并记录") {
                        if link.record(id: draft.id, mg: draft.mg, med: draft.med) { confirmation = nil }
                    }.buttonStyle(.borderedProminent).disabled(!link.storageReady)
                    if let issue = link.issue { Text(issue).font(.caption2).foregroundStyle(.orange) }
                }.padding(.horizontal, 3)
            }
            .navigationTitle("确认记录")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { confirmation = nil } } }
        }
    }

    private func elapsed(since date: Date, now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        if minutes < 1 { return "刚刚" }
        if minutes < 60 { return "\(minutes) 分钟前" }
        if minutes < 1440 { return "\(minutes / 60) 小时 \(minutes % 60) 分" }
        return "\(minutes / 1440) 天 \((minutes % 1440) / 60) 小时 \(minutes % 60) 分"
    }
}

private struct WatchNoteEditor: View {
    let draft: WatchNoteDraft
    @EnvironmentObject private var link: YaoShiWatchLink
    @Environment(\.dismiss) private var dismiss
    @State private var note = ""
    @State private var saveFailed = false

    private var text: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool {
        !text.isEmpty && text.count <= WatchNoteEvent.maxCharacters && text.utf8.count <= WatchNoteEvent.maxUTF8Bytes
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(draft.at.formatted(.dateTime.month().day().hour().minute()))
                        .font(.caption).foregroundStyle(.mint)
                    TextField("此时此刻感觉如何？", text: $note, axis: .vertical)
                    Text("点输入框，可用手表听写。\n例如：现在药效挺好，做事很专注。")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text("\(text.count)/\(WatchNoteEvent.maxCharacters) 字")
                        .font(.caption2).foregroundStyle(valid || text.isEmpty ? Color.secondary : Color.orange)
                    Button("保存笔记") {
                        if link.recordNote(id: draft.id, at: draft.at, note: text) { dismiss() }
                        else { saveFailed = true }
                    }.buttonStyle(.borderedProminent)
                        .disabled(!valid || !link.storageReady || link.state.pendingNotes.count >= 100)
                    Text("离线也能保存，连接手机后自动同步。")
                        .font(.caption2).foregroundStyle(.secondary)
                    if saveFailed || !link.storageReady {
                        Text(link.issue ?? "尚未保存成功，请重试。文字仍保留在这里。")
                            .font(.caption2).foregroundStyle(.orange)
                    }
                }.padding(.horizontal, 3)
            }
            .navigationTitle("添加笔记")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}
