import Foundation
import Network

/// Tracks whether the Mac has a usable network path. Drives the offline mode:
/// actions are queued instead of sent while `isOnline` is false, and going back
/// online triggers a sync (`onReconnect`).
@MainActor
@Observable
final class NetworkMonitor {
    private(set) var isOnline = true
    @ObservationIgnored var onReconnect: (() -> Void)?
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
                if online { self.onReconnect?() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "newmail.network-monitor"))
    }

    /// Whether `error` means the server couldn't be reached (as opposed to the
    /// server refusing the request). Such failures are retried later instead
    /// of being reported and rolled back.
    static func isConnectivityError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff,
                 .dataNotAllowed, .secureConnectionFailed:
                return true
            default:
                return false
            }
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return isConnectivityError(URLError(URLError.Code(rawValue: ns.code)))
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error {
            return isConnectivityError(underlying)
        }
        return false
    }
}
