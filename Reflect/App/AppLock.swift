// Optional app lock (FR-014): when `security.app_lock` is on, the journal
// stays veiled until Touch ID (or the account password) succeeds. Content
// is not rendered behind the lock.
import LocalAuthentication
import SwiftUI

@Observable
@MainActor
final class AppLock {
    private(set) var isLocked: Bool
    private(set) var lastError: String?

    init() {
        isLocked = (try? AppServices.settings.getBool(.appLock)) ?? false
    }

    func unlock() {
        let context = LAContext()
        context.localizedReason = "unlock your journal"
        var policyError: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthentication, error: &policyError)
        else {
            // No auth available on this machine — fail open rather than
            // locking the user out of their own journal.
            lastError = policyError?.localizedDescription
            isLocked = false
            return
        }
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: "unlock your journal"
        ) { success, error in
            Task { @MainActor in
                if success {
                    self.isLocked = false
                    self.lastError = nil
                } else {
                    self.lastError = error?.localizedDescription
                }
            }
        }
    }
}

struct LockView: View {
    let lock: AppLock

    var body: some View {
        VStack(spacing: 26) {
            Text("Reflect")
                .font(Typography.serif(34, weight: .medium))
                .foregroundStyle(Theme.ink)
            Text("This journal is locked.")
                .font(Typography.serifItalic(17))
                .foregroundStyle(Theme.ink2)
            Button(action: { lock.unlock() }) {
                HStack(spacing: 8) {
                    Image(systemName: "touchid")
                        .font(.system(size: 13))
                    Text("Unlock")
                        .font(Typography.sans(13, weight: .medium))
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 18)
                .padding(.vertical, 9)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.cornerRadius)
                        .stroke(Theme.accent, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let error = lock.lastError {
                Text(error)
                    .font(Typography.sans(11))
                    .foregroundStyle(Theme.ink4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.paper)
        .onAppear { lock.unlock() }
    }
}
