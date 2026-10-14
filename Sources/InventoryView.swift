import SwiftUI

struct InventoryCard: View {
    @EnvironmentObject var store: Store
    @State private var showingRecount = false

    var body: some View {
        Card(title: "剩余库存", systemImage: "pills") {
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(store.supply.pillsLeft)")
                        .font(.system(size: 36, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("粒").font(.headline)
                }
                .foregroundStyle(YS.text)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("剩余库存 \(store.supply.pillsLeft) 粒")
                .accessibilityIdentifier("inventoryCount")
                Spacer()
                Button("清点修改") { showingRecount = true }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(YS.teal)
                    .accessibilityIdentifier("inventoryRecountButton")
            }
            Text("手动清点 · 服药暂不自动扣减")
                .font(.caption)
                .foregroundStyle(YS.dim)
            if store.inventoryNeedsReview {
                Label("设备间库存有差异，请清点核对", systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(YS.amber)
            }
        }
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
