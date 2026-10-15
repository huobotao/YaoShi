import SwiftUI
import UIKit

/// 小组件点击传进来的 URL 走这里。
/// SwiftUI 的 .onOpenURL 在当前 SDK 上没有接到 simctl/小组件发来的事件，
/// 所以用 UIApplicationDelegate 这条更底层、行为确定的入口，
/// 转成通知发给界面层。
final class AppDelegate: NSObject, UIApplicationDelegate {
    static let takeNotification = Notification.Name("YaoShiQuickTake")

    @MainActor private static var curveAnalysisPresented = false
    @MainActor private static var curveLandscapeRequested = false

    @MainActor
    static func setCurveAnalysisPresented(_ presented: Bool) {
        curveAnalysisPresented = presented
        if !presented { curveLandscapeRequested = false }
        let mask: UIInterfaceOrientationMask = UIDevice.current.userInterfaceIdiom == .pad ? .all : (presented ? .allButUpsideDown : .portrait)
        requestOrientation(mask)
    }

    @MainActor
    static func setCurveLandscape(_ enabled: Bool) {
        curveLandscapeRequested = enabled
        requestOrientation(enabled ? .landscape : .allButUpsideDown)
    }

    @MainActor
    private static func requestOrientation(_ mask: UIInterfaceOrientationMask) {
        #if !targetEnvironment(macCatalyst)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }
        #endif
    }

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad { return .all }
        if Self.curveAnalysisPresented {
            return Self.curveLandscapeRequested ? .landscape : .allButUpsideDown
        }
        return .portrait
    }

    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        guard !LiveActivityReadback.requested else { return false }
        if url.scheme == "yaoshi-21012r8-partner" {
            Task { @MainActor in await PartnerSharingCoordinator.shared.acceptInvite(url) }
            return true
        }
        guard url.scheme == "yaoshi-21012r8" else { return false }
        let action = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if action == "take" {
            NotificationCenter.default.post(name: Self.takeNotification, object: nil)
            return true
        }
        return false
    }
}

/// Optional Store ownership lets a diagnostic launch avoid all Store side effects.
@MainActor
private final class YaoShiLaunchContext: ObservableObject {
    let store: Store?
    init(store: Store?) { self.store = store }
}

@main
struct YaoShiApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase
    @StateObject private var launch: YaoShiLaunchContext

    init() {
        if LiveActivityReadback.requested {
            _launch = StateObject(wrappedValue: YaoShiLaunchContext(store: nil))
            LiveActivityReadback.capture()
            return
        }
        let store = Store()
        // Explicit maintenance only; ordinary launches do not rewrite dose history.
        if let requested = ProcessInfo.processInfo.environment["YAOSHI_CORRECT_40MG_IDS"] {
            let ids = Set(requested.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
            if !ids.isEmpty { _ = store.correctLegacy40mgDoses(ids: ids) }
        }
        _launch = StateObject(wrappedValue: YaoShiLaunchContext(store: store))
        PhoneWatchLink.shared.start(store: store)
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if Bundle.main.object(forInfoDictionaryKey: "YaoShiBackgroundLocationExperiment") as? Bool == true {
            BackgroundRefreshExperiment.shared.configure { [weak store] in store?.publish() }
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            if let store = launch.store {
                RootView()
                    .environmentObject(store)
                    .preferredColorScheme(.dark)
                    .tint(YS.teal)
                    .onAppear {
                        Notifier.configure()
                        // 自检：只在带 YAOSHI_SELFTEST=1 的调试启动时跑一次，
                        // 用来证明"按一下 → 真的写进磁盘"这条链路是通的。真机日常使用不会触发。
                        if ProcessInfo.processInfo.environment["YAOSHI_SELFTEST"] == "1" {
                            store.quickTake()
                        }
                        Notifier.reschedule(store)
                    }
                    .task {
                        while !Task.isCancelled {
                            if phase == .active {
                                await MedicationShareRepository.shared.sync()
                            }
                            try? await Task.sleep(nanoseconds: 15_000_000_000)
                        }
                    }
                    .task(id: phase) {
                        guard phase == .active else { return }
                        while !Task.isCancelled {
                            do { try await Task.sleep(nanoseconds: 30_000_000_000) }
                            catch { return }
                            guard !Task.isCancelled, phase == .active else { return }
                            store.publish()
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(
                        for: UIApplication.didBecomeActiveNotification)) { _ in
                        #if os(iOS) && !targetEnvironment(macCatalyst)
                        if Bundle.main.object(forInfoDictionaryKey: "YaoShiBackgroundLocationExperiment") as? Bool == true {
                            BackgroundRefreshExperiment.shared.ensureLifecycle()
                        }
                        #endif
                        // Scene phase may be active before UIKit permits Activity.request.
                        // Publish again once UIKit confirms foreground execution.
                        store.publish()
                    }
                    .onReceive(NotificationCenter.default.publisher(
                        for: AppDelegate.takeNotification)) { _ in
                        let d = store.quickTake()
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        Task {
                            try? await Task.sleep(nanoseconds: 12_000_000_000)
                            if store.lastQuickAdded?.id == d.id { store.lastQuickAdded = nil }
                        }
                    }
            } else {
                Color.black.ignoresSafeArea()
            }
        }
        .onChange(of: phase) { _, new in
            guard let store = launch.store else { return }
            #if os(iOS) && !targetEnvironment(macCatalyst)
            if Bundle.main.object(forInfoDictionaryKey: "YaoShiBackgroundLocationExperiment") as? Bool == true {
                BackgroundRefreshExperiment.shared.ensureLifecycle()
            }
            #endif
            // iCloud 钥匙串没有变更回调，只能在回到前台这个时机对齐
            if new == .active {
                store.sync()
                Task { await MedicationShareRepository.shared.sync() }
                store.publish()
                PhoneWatchLink.shared.publishSnapshot()
                Notifier.reschedule(store)
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        // 截图核对用：直接打开叠加试算页。真机不会走这条。
        if ProcessInfo.processInfo.environment["YAOSHI_PREVIEW_STACK"] == "1" {
            StackPreview()
        } else {
            tabs
        }
    }

    private var tabs: some View {
        TabView {
            TodayView()
                .tabItem { Label("今天", systemImage: "clock.fill") }
            CalendarPage()
                .tabItem { Label("日历", systemImage: "calendar") }
            RecordsView()
                .tabItem { Label("记录", systemImage: "list.bullet") }
            StatsView()
                .tabItem { Label("统计", systemImage: "chart.bar.fill") }
            SettingsView()
                .tabItem { Label("我的", systemImage: "gearshape.fill") }
            YaoShiOwnerSharingView()
                .environmentObject(store)
                .tabItem { Label("伴侣", systemImage: "person.2.fill") }
        }
    }
}
