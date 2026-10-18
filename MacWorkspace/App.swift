import AppKit
import SwiftUI
import Charts

@MainActor final class Selection: ObservableObject {
    @Published var hours = 48.0
    @Published var selected = Date()
    @Published var followNow = true
}

struct WorkspaceView: View {
    @ObservedObject var store: WorkspaceStore
    @ObservedObject var selection: Selection
    let role: Int
    var title: String { ["曲线与睡眠", "记录与笔记", "工作台控制中心"][role] }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("药时 / MAC WORKSPACE · R1").font(.caption).foregroundStyle(.mint)
                    Text(title).font(.system(size: 30, weight: .semibold))
                }
                Spacer()
                Text("只读备份 · 未连接实时同步").font(.callout).foregroundStyle(.orange)
            }
            Divider()
            if let error = store.error { Text(error).foregroundStyle(.orange).textSelection(.enabled) }
            if role == 0 { curve }
            else if role == 1 { records }
            else { controls }
        }
        .padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 0.035, green: 0.047, blue: 0.065))
        .preferredColorScheme(.dark)
    }
    var curve: some View {
        VStack(alignment: .leading, spacing: 16) {
            TimelineView(.periodic(from: .now, by: 30)) { tick in
                HStack(alignment: .firstTextBaseline, spacing: 28) {
                    Text(String(format: "%.2f×", store.level(at: tick.date)))
                        .font(.system(size: 64, weight: .medium, design: .rounded)).foregroundStyle(.mint).monospacedDigit()
                    VStack(alignment: .leading) {
                        Text("当前模型估算").font(.title3)
                        Text("基于已导入记录；不是血液检测值").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(tick.date, style: .time).font(.title2).monospacedDigit()
                }
                plot(now: tick.date)
            }
            HStack {
                Text("时间范围")
                Picker("时间范围", selection: $selection.hours) {
                    Text("24 小时").tag(24.0); Text("48 小时").tag(48.0); Text("7 天").tag(168.0)
                }.pickerStyle(.segmented).frame(width: 320)
                Spacer()
                Button("回到现在") { selection.followNow = true; selection.selected = Date() }
            }
            Text("拖动曲线选择时间，记录窗口同步定位。蓝色竖线表示睡眠记录，黄色竖线表示醒来记录。").font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("选中：\(selection.selected.formatted(date: .abbreviated, time: .shortened))")
                Text(String(format: "模型估算 %.2f×", store.level(at: selection.selected))).foregroundStyle(.mint)
            }
        }
    }
    func plot(now: Date) -> some View {
        let start = now.addingTimeInterval(-selection.hours * 0.75 * 3600)
        let end = now.addingTimeInterval(selection.hours * 0.25 * 3600)
        let samples = (0...400).map { start.addingTimeInterval(Double($0) / 400 * selection.hours * 3600) }
        return Chart {
            ForEach(samples, id: \.self) { date in
                LineMark(x: .value("时间", date), y: .value("相对浓度", store.level(at: date)))
                    .foregroundStyle(.mint).lineStyle(StrokeStyle(lineWidth: 2.5))
            }
            ForEach(store.events.filter { $0.at >= start && $0.at <= end }) { event in
                RuleMark(x: .value("时间", event.at)).foregroundStyle(event.kind == "sleep" ? Color.blue.opacity(0.5) : Color.yellow.opacity(0.5))
            }
            RuleMark(x: .value("现在", now)).foregroundStyle(.white.opacity(0.5)).lineStyle(StrokeStyle(dash: [4,4]))
            RuleMark(x: .value("选中", selection.selected)).foregroundStyle(.orange)
        }.chartXScale(domain: start...end).chartYAxisLabel("相对浓度 ×")
         .chartXSelection(value: Binding<Date?>(get: { selection.selected }, set: { if let d = $0 { selection.selected = d; selection.followNow = false } }))
         .frame(minHeight: 240, maxHeight: .infinity)
    }
    var records: some View {
        HSplitView {
            VStack(alignment: .leading) {
                Text("服药记录 · \(store.doses.count)").font(.title2)
                List(store.doses.sorted { $0.at > $1.at }) { dose in
                    Button { selection.selected = dose.at; selection.followNow = false } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(dose.at.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                            Text("\(dose.mg) mg").foregroundStyle(.mint)
                            if !dose.note.isEmpty { Text(dose.note).font(.callout).foregroundStyle(.secondary) }
                        }.padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                    }.buttonStyle(.plain)
                }.scrollContentBackground(.hidden)
            }.frame(minWidth: 250)
            VStack(alignment: .leading) {
                Text("笔记 · 距选中时间由近到远").font(.title2)
                List(store.notes.sorted { abs($0.at.timeIntervalSince(selection.selected)) < abs($1.at.timeIntervalSince(selection.selected)) }) { note in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(note.at.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.mint)
                        Text(note.note).textSelection(.enabled)
                    }.padding(.vertical, 10)
                }.scrollContentBackground(.hidden)
            }.frame(minWidth: 300)
        }
    }
    var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("三屏工作布局").font(.title2)
                Text("外接屏 1：曲线与睡眠\n外接屏 2：服药记录与笔记\n内置屏：数据来源与工作台控制").lineSpacing(10)
                HStack {
                    Button("打开 / 排列三个窗口") { WindowManager.shared.arrange() }
                    Button("重新读取本地副本") { store.reload() }
                }
                Divider()
                Text("数据来源").font(.title2)
                if let captured = store.capturedAt { Text("源数据更新时间：\(captured.formatted(date: .complete, time: .standard))") }
                Text("\(store.doses.count) 条服药 · \(store.notes.count) 条笔记 · \(store.events.count) 条生活事件")
                Text(store.sourcePath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("当前仅读取电脑上的独立副本。没有写入手机、iCloud 或原始备份。尚未启用实时同步及自动备份。").foregroundStyle(.orange)
                Divider()
                Text("屏幕与窗口").font(.title2)
                ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { item in
                    Text("\(item.element.localizedName) · \(Int(item.element.frame.width)) × \(Int(item.element.frame.height)) 逻辑点")
                }
                Text("窗口可以自由拖动、缩放和全屏。外接屏断开时会重新排列到可用屏幕；可随时通过控制中心重新排列窗口。5K 使用逻辑点排版，保留清晰可读字号。").foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor final class WindowManager: NSObject, NSApplicationDelegate {
    static let shared = WindowManager()
    let store = WorkspaceStore()
    let selection = Selection()
    var windows: [NSWindow] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(); let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appMenu.addItem(withTitle: "退出药时工作台", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); appItem.submenu = appMenu
        let windowItem = NSMenuItem(); menu.addItem(windowItem)
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "排列工作台", action: #selector(arrangeMenu), keyEquivalent: "1").target = self
        windowMenu.addItem(withTitle: "新增曲线窗口", action: #selector(addCurve), keyEquivalent: "n").target = self
        windowItem.submenu = windowMenu
        NSApplication.shared.mainMenu = menu
        arrange()
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    @objc func screenChanged() { arrange() }
    @objc func arrangeMenu() { arrange() }
    @objc func addCurve() {
        let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1100, height: 760), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
        w.title = "药时 R1 · 扩展曲线窗口"
        w.contentView = NSHostingView(rootView: WorkspaceView(store: store, selection: selection, role: 0))
        w.isReleasedWhenClosed = false
        windows.append(w); w.makeKeyAndOrderFront(nil)
    }
    func arrange() {
        if windows.isEmpty {
            for role in 0...2 {
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760), styleMask: [.titled,.closable,.miniaturizable,.resizable], backing: .buffered, defer: false)
                w.title = ["药时 R1 · 曲线与睡眠", "药时 R1 · 记录与笔记", "药时 R1 · 控制中心"][role]
                w.contentView = NSHostingView(rootView: WorkspaceView(store: store, selection: selection, role: role))
                w.minSize = NSSize(width: role == 1 ? 700 : 580, height: 500)
                w.isReleasedWhenClosed = false
                w.setFrameAutosaveName("YaoShiWorkspaceR1-\(role)")
                windows.append(w)
            }
        }
        let screens = NSScreen.screens
        guard let first = screens.first else { return }
        let external = screens.filter { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return CGDisplayIsBuiltin(id) == 0
        }
        let internalScreen = screens.first { !external.contains($0) } ?? first
        for (i,w) in windows.enumerated() {
            let screen = i < 2 && external.count > i ? external[i] : internalScreen
            var frame = screen.visibleFrame.insetBy(dx: 16, dy: 16)
            if screens.count < 3 { frame = frame.insetBy(dx: CGFloat(i)*20, dy: CGFloat(i)*20) }
            w.setFrame(frame, display: true); w.makeKeyAndOrderFront(nil)
        }
        windows[0].makeKeyAndOrderFront(nil)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct Entry {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = WindowManager.shared
        app.run()
    }
}
