import SwiftUI
import UserNotifications
import TessereCore

final class AppDelegate: NSObject, UIApplicationDelegate {
    let notificationDelegate = NotificationDelegate()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = notificationDelegate
        CloudBackupService.registerBackgroundTask()
        MainActor.assumeIsolated {
            _ = AppModel.shared
            // Created at launch so region events (store nearby) are delivered
            // even when iOS relaunches the app in the background.
            LocationService.shared.start()
        }
        return true
    }
}

@main
struct TessereApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared
    @State private var lock = AppLock.shared
    @State private var sync = SyncService.shared
    @State private var location = LocationService.shared
    @State private var cloud = CloudBackupService.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ThemedRoot()
                .environment(model)
                .environment(lock)
                .environment(sync)
                .environment(location)
                .environment(cloud)
                .onOpenURL { model.handle(url: $0) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                model.saveNow()
                BackgroundWork.run("tessere-icloud-backup") {
                    await CloudBackupService.shared.backup(force: false)
                }
                CloudBackupService.scheduleBackgroundRefresh()
                lock.didEnterBackground()
                ScreenBoost.suspend()
            case .inactive:
                lock.willResignActive()
            case .active:
                lock.didBecomeActive()
                ScreenBoost.resume()
                model.didBecomeActive()
            @unknown default:
                break
            }
        }
    }
}

/// Applies the appearance (dark OLED by default), accent and rounded font.
private struct ThemedRoot: View {
    @Environment(AppModel.self) private var model
    @Environment(AppLock.self) private var lock

    private var scheme: ColorScheme? {
        switch model.data.settings.appearance {
        case .dark: return .dark
        case .light: return .light
        case .system: return nil
        }
    }

    var body: some View {
        ZStack {
            RootView()
            if lock.isLocked {
                LockView()
                    .transition(.opacity)
            } else if lock.isObscured {
                PrivacyCover()
            }
        }
        .animation(.easeInOut(duration: 0.2), value: lock.isLocked)
        .tint(Theme.accent)
        .fontDesign(.rounded)
        .preferredColorScheme(scheme)
    }
}
