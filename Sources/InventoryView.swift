import SwiftUI

/// A compact entry point beside the elapsed-time value, without a separate card.
struct InventoryInlineButton: View {
    @EnvironmentObject var store: Store
    @State private var showingRecount = false

    var body: some View {
        Button { showingRecount = true } label: {
            HStack(spacing: 4) {
                Text("库存 \(store.supply.pillsLeft) 粒")
                    .monospacedDigit()
                    .accessibilityIdentifier("inventoryCount")
                if store.inventoryNeedsReview {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(YS.amber)
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(YS.teal)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("剩余库存 \(store.supply.pillsLeft) 粒")
        .accessibilityValue(store.inventoryNeedsReview ? "设备间库存有差异，请清点核对" : "手动清点库存")
        .accessibilityHint("轻点清点修改，服药暂不自动扣减")
        .accessibilityIdentifier("inventoryRecountButton")
        .sheet(isPresented: $showingRecount) {
            InventoryRecountView(initialCount: store.supply.pillsLeft)
                .environmentObject(store)
        }
    }
}

private struct InventoryRecountView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    @State private var countText: String

    init(initialCount: Int) {
        _countText = State(initialValue: String(initialCount))
    }

    private var validCount: Int? {
        let text = countText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let count = Int(text), count >= 0 else { return nil }
        return count
    }

    var body: some View {
        NavigationStack {
            Form {
                if store.inventoryNeedsReview {
                    Label("设备间库存有差异，请清点核对", systemImage: "exclamationmark.circle")
                        .foregroundStyle(YS.amber)
                }
                Section {
                    HStack {
                        Text("实际剩余")
                        TextField("粒数", text: $countText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                            .accessibilityLabel("实际剩余粒数")
                            .accessibilityIdentifier("inventoryCountField")
                        Text("粒")
                    }
                } footer: {
                    Text("输入现在清点的总粒数。保存会替换库存数量，不修改服药记录。服药记录暂不自动扣减库存。")
                }
                if validCount == nil {
                    Text("请输入 0 或更大的整数")
                        .foregroundStyle(YS.amber)
                }
            }
            .scrollContentBackground(.hidden)
            .background(YS.bg)
            .navigationTitle("清点库存")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard let count = validCount else { return }
                        var supply = store.supply
                        supply.pillsLeft = count
                        store.updateSupply(supply, resolvesConflict: true)
                        dismiss()
                    }
                    .disabled(validCount == nil)
                    .accessibilityIdentifier("inventorySaveButton")
                }
            }
        }
        .tint(YS.teal)
    }
}
