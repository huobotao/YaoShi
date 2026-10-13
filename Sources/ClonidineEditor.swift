import SwiftUI

struct ClonidineEntryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entry: ClonidineEntry
    @State private var mgText: String
    @State private var saveFailed = false
    @State private var confirmDelete = false

    var onSave: (ClonidineEntry) -> Bool
    var onDelete: (ClonidineEntry) -> Bool

    private var isNew: Bool { entry.updatedAt == nil }
    private var parsedMg: Decimal? {
        let raw = mgText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let value = Decimal(string: raw, locale: Locale.current), value > .zero else { return nil }
        return value
    }

    init(entry existing: ClonidineEntry? = nil,
         onSave: @escaping (ClonidineEntry) -> Bool,
         onDelete: @escaping (ClonidineEntry) -> Bool) {
        let initial = existing ?? ClonidineEntry(at: Date(), mg: .zero)
        _entry = State(initialValue: initial)
        _mgText = State(initialValue: existing?.doseText ?? "")
        self.onSave = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("可乐定记录") {
                    DatePicker("服用时间", selection: $entry.at)
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                    HStack {
                        Text("剂量")
                        Spacer()
                        TextField("输入实际剂量", text: $mgText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 132)
                            .accessibilityIdentifier("clonidineDoseField")
                        Text("毫克").foregroundStyle(.secondary)
                    }
                    Text("按实际服用的剂量填写；此记录与主药曲线分开保存。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("备注（可选）") {
                    TextField("补充说明", text: $entry.note, axis: .vertical)
                        .lineLimit(2...5)
                }
                if !isNew {
                    Section {
                        Button("删除这条可乐定记录", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(YS.bg)
            .navigationTitle(isNew ? "记录可乐定" : "修改可乐定记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let parsedMg else { return }
                        entry.mg = parsedMg
                        if onSave(entry) { dismiss() } else { saveFailed = true }
                    }
                    .disabled(parsedMg == nil)
                    .fontWeight(.semibold)
                }
            }
            .alert("未能保存", isPresented: $saveFailed) {
                Button("好", role: .cancel) {}
            } message: {
                Text("输入内容仍在本页。请检查储存状态后重试。")
            }
            .confirmationDialog("删除这条可乐定记录？", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if onDelete(entry) { dismiss() } else { saveFailed = true }
                }
                Button("取消", role: .cancel) {}
            }
        }
    }
}
