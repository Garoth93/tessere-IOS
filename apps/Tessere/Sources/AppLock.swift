import SwiftUI
import LocalAuthentication

/// Optional Face ID lock: on launch and when coming back after the app
/// was in background. The app switcher shows a cover instead of the cards.
@MainActor
@Observable
final class AppLock {
    static let shared = AppLock()

    private(set) var isLocked = false
    /// App inactive (switcher): hide the content.
    private(set) var isObscured = false
    private(set) var enabled = false
    private var configured = false
    private var authenticating = false
    @ObservationIgnored private var backgroundAt: Date?

    func configure(enabled: Bool) {
        let first = !configured
        configured = true
        self.enabled = enabled
        if !enabled {
            isLocked = false
        } else if first {
            isLocked = true
            unlock()
        }
    }

    func willResignActive() {
        if enabled { isObscured = true }
    }

    func didEnterBackground() {
        backgroundAt = Date()
        if enabled { isLocked = true }
    }

    func didBecomeActive() {
        isObscured = false
        if enabled && isLocked { unlock() }
    }

    var biometryName: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "codice"
        }
    }

    var biometrySymbol: String {
        let ctx = LAContext()
        _ = ctx.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch ctx.biometryType {
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "faceid"
        }
    }

    /// Checks the user can authenticate before enabling the lock.
    func verifyForEnabling() async -> Bool {
        await evaluate(reason: "Attiva il blocco di Tessere")
    }

    func unlock() {
        guard !authenticating, UIApplication.shared.applicationState != .background else { return }
        authenticating = true
        Task {
            let ok = await evaluate(reason: "Sblocca Tessere")
            authenticating = false
            if ok { isLocked = false }
        }
    }

    private func evaluate(reason: String) async -> Bool {
        let ctx = LAContext()
        ctx.localizedCancelTitle = "Annulla"
        var error: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No passcode set on the device: nothing to protect with.
            return true
        }
        do {
            return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}

struct LockView: View {
    @Environment(AppLock.self) private var lock

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 22) {
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 84, height: 84)
                    .background(Circle().fill(Color.white.opacity(0.08)))
                Text("Tessere è bloccata")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    lock.unlock()
                } label: {
                    Label("Sblocca con \(lock.biometryName)", systemImage: lock.biometrySymbol)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .foregroundStyle(.black)
                        .background(Theme.accent, in: Capsule())
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 40)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// Shown in the app switcher when the lock is on.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(systemName: "creditcard.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.accent)
        }
    }
}
