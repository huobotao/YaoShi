import SwiftUI

/// 只记录实际发生的进食、入睡和醒来；可以补记、改正日期与时间。
struct LifeEventEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var event: LifeEvent
    private let onSave: (LifeEvent) -> Bool
    private let onDelete: ((LifeEvent) -> Bool)?
    @State private var activeAlert: EditorAlert?
    @State private var storageError: String?

    init(event: LifeEvent,
         onSave: @escaping (LifeEvent) -> Bool,
         onDelete: ((LifeEvent) -> Bool)? = nil) {
        _event = State(initialValue: event)
        self.onSave = onSave
        self.onDelete = onDelete
    }

    private var isNew: Bool { onDelete == nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("记录什么", selection: $event.kind) {
                        Label(LifeEventKind.food.label, systemImage: LifeEventKind.food.symbol)
                            .tag(LifeEventKind.food)
                        Label(LifeEventKind.sleep.label, systemImage: LifeEventKind.sleep.symbol)
                            .tag(LifeEventKind.sleep)
                        Label(LifeEventKind.wake.label, systemImage: LifeEventKind.wake.symbol)
                            .tag(LifeEventKind.wake)
                    }
                    .accessibilityIdentifier("lifeEventKind")
                } header: {
                    Text("实际发生的事")
                } footer: {
                    Text(kindHint)
                }

                Section {
                    DatePicker("日期与时间", selection: $event.at, in: ...Date(),
                               displayedComponents: [.date, .hourAndMinute])
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                        .accessibilityIdentifier("lifeEventDate")
                } header: {
                    Text("发生时刻")
                } footer: {
                    Text("可以补记前几天的记录。请选实际发生的时间，不能记录未来时刻。")
                }

                Section("备注（可不填）") {
                    TextField(notePlaceholder, text: $event.note, axis: .vertical)
                        .lineLimit(3...6)
                        .accessibilityIdentifier("lifeEventNote")
                }

                if let storageError {
                    Section {
                        Label(storageError, systemImage: "exclamationmark.circle")
                            .foregroundStyle(YS.orange)
                            .accessibilityIdentifier("lifeEventStorageError")
                    }
                }

                if !isNew {
                    Section {
                        Button(role: .destructive) { activeAlert = .confirmDelete } label: {
                            Label("删除这条记录", systemImage: "trash")
                        }
                        .accessibilityIdentifier("deleteLifeEvent")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(YS.bg)
            .navigationTitle(isNew ? "记录\(event.kind.label)" : "修改生活记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: save)
                        .fontWeight(.semibold)
                        .accessibilityIdentifier("saveLifeEvent")
                }
            }
            .interactiveDismissDisabled()
            .alert(item: $activeAlert) { alert in
                switch alert {
                case .confirmDelete:
                    return Alert(
                        title: Text("删除这条\(event.kind.label)记录？"),
                        message: Text("相关计时会根据剩余记录重新计算。"),
                        primaryButton: .destructive(Text("删除")) {
                            guard let onDelete else { return }
                            if onDelete(event) {
                                dismiss()
                            } else {
                                storageError = "删除失败，记录仍然保留。请稍后重试。"
                                activeAlert = .deleteFailed
                            }
                        },
                        secondaryButton: .cancel(Text("取消"))
                    )
                case .futureDate:
                    return Alert(title: Text("发生时间不能在未来"),
                                 message: Text("请选择实际发生的日期与时间后再保存。"),
                                 dismissButton: .default(Text("好")))
                case .saveFailed:
                    return Alert(title: Text("暂时无法保存"),
                                 message: Text("内容仍保留在本页，请稍后重试。"),
                                 dismissButton: .default(Text("好")))
                case .deleteFailed:
                    return Alert(title: Text("暂时无法删除"),
                                 message: Text("这条记录仍然保留，请稍后重试。"),
                                 dismissButton: .default(Text("好")))
                }
            }
        }
    }

    private func save() {
        guard event.at <= Date() else {
            activeAlert = .futureDate
            return
        }
        var saved = event
        saved.note = saved.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if onSave(saved) {
            dismiss()
        } else {
            storageError = "保存失败，内容仍保留在本页。请稍后重试。"
            activeAlert = .saveFailed
        }
    }

    private var kindHint: String {
        switch event.kind {
        case .food:
            return "只要吃了东西就算，哪怕只吃一点或一口零食；每次进食都会重新开始计时。"
        case .sleep:
            return "记录实际开始睡着的时间，可以醒来后补记。准备上床或打算睡觉，不算已经入睡。"
        case .wake:
            return "记录实际醒来的时间，用来计算已经清醒多久；也可以之后补记。"
        }
    }

    private var notePlaceholder: String {
        switch event.kind {
        case .food: return "比如：吃了几口面包"
        case .sleep: return "比如：大约这个时间睡着"
        case .wake: return "比如：睡醒后的感受"
        }
    }

    private enum EditorAlert: String, Identifiable {
        case confirmDelete, futureDate, saveFailed, deleteFailed
        var id: String { rawValue }
    }
}
