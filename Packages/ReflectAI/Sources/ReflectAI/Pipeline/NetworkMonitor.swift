// Connectivity source for the offline-aware queue (AC-025): the app hands
// `isOnline` to the orchestrator and kicks it when the path comes back.
import Foundation
import Network

public final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = true
    private var onReconnect: (@Sendable () -> Void)?

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let nowOnline = path.status == .satisfied
            lock.lock()
            let wasOnline = online
            online = nowOnline
            let callback = onReconnect
            lock.unlock()
            if nowOnline && !wasOnline {
                callback?()
            }
        }
        monitor.start(queue: DispatchQueue(label: "reflect.network-monitor"))
    }

    public var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return online
    }

    /// Called once each time connectivity returns after an offline stretch.
    public func setOnReconnect(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        onReconnect = handler
        lock.unlock()
    }
}
