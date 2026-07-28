import Foundation
import Network
import Observation

/// Reports network reachability.
///
/// Used only to decide *when to try* syncing — never to gate a feature. Nothing in the
/// app asks whether the network is up before letting the user study, and this type must
/// not become the thing that makes it possible to.
@MainActor
@Observable
public final class NetworkMonitor {
    /// Starts pessimistic: assuming connectivity and being wrong shows a spurious error,
    /// whereas assuming none and being wrong costs a few seconds until the first update.
    public private(set) var isConnected = false
    /// `true` on cellular, so sync can be deferred when the user asks it to be.
    public private(set) var isExpensive = false
    /// `true` under Low Data Mode.
    public private(set) var isConstrained = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.vocabloop.app.network")
    private var isStarted = false

    public init() {}

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        monitor.pathUpdateHandler = { [weak self] path in
            // NWPathMonitor calls back on its own queue; the observable state is main-actor
            // isolated, so the hop is required rather than cosmetic.
            Task { @MainActor [weak self] in
                self?.isConnected = path.status == .satisfied
                self?.isExpensive = path.isExpensive
                self?.isConstrained = path.isConstrained
            }
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        guard isStarted else { return }
        monitor.cancel()
        isStarted = false
    }

    /// Whether it is reasonable to sync now, honouring the user's cellular preference.
    public func shouldSync(allowCellular: Bool) -> Bool {
        guard isConnected else { return false }
        if isConstrained { return false }
        return allowCellular || !isExpensive
    }
}
