import SwiftUI
import UIKit
import UserNotifications

#if YAOSHI_PARTNER
final class YaoShiPartnerAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
#if YAOSHI_REMOTE_PUSH
        Task { @MainActor in await requestRemoteNotificationsIfConnected(application) }
#endif
        return true
    }

    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        guard url.scheme == "yaoshi-partner" else { return false }
        Task { @MainActor in
            await PartnerSharingCoordinator.shared.acceptInvite(url)
#if YAOSHI_REMOTE_PUSH
            await requestRemoteNotificationsIfConnected(app)
#endif
        }
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

#if YAOSHI_REMOTE_PUSH
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        let environment = Bundle.main.object(forInfoDictionaryKey: "APNsEnvironment") as? String ?? "development"
        Task { @MainActor in
            await PartnerSharingCoordinator.shared.registerPushToken(
                app: .yaoShi, deviceToken: token, environment: environment)
        }
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        UserDefaults.standard.set(false, forKey: "yaoshi.partner.pushRegistered")
    }

    @MainActor
    private func requestRemoteNotificationsIfConnected(_ application: UIApplication) async {
        let savedCredentials: PartnerSpaceCredentials?
        do { savedCredentials = try PartnerCredentialVault.load(app: .yaoShi) }
        catch { return }
        guard savedCredentials?.role == .partner else { return }
        let center = UNUserNotificationCenter.current()
        var settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            settings = await center.notificationSettings()
        }
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            UserDefaults.standard.set(false, forKey: "yaoshi.partner.pushRegistered")
            return
        }
        application.registerForRemoteNotifications()
    }
#endif
}

@main
struct YaoShiPartnerApp: App {
    @UIApplicationDelegateAdaptor(YaoShiPartnerAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            YaoShiPartnerView()
                .preferredColorScheme(.dark)
                .tint(.teal)
                .task {
                    LocationSharingManager.shared.foreground()
                    await MedicationShareRepository.shared.sync()
                    await PartnerMedicationNotificationPlanner.shared.refreshStatusNotifications(
                        doses: MedicationShareRepository.shared.doses)
                    while !Task.isCancelled {
                        if phase == .active { await MedicationShareRepository.shared.sync() }
                        try? await Task.sleep(nanoseconds: 15_000_000_000)
                    }
                }
                .onChange(of: phase) { _, new in
                    if new == .active {
                        LocationSharingManager.shared.foreground()
                        Task { await MedicationShareRepository.shared.sync() }
                    }
                }
        }
    }
}
#endif
