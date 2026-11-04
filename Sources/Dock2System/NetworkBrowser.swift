import Foundation
import Network

/// The file servers the local network announces over Bonjour, for Files' Network. Starting it the first time
/// raises macOS's Local Network prompt.
@MainActor
public final class NetworkBrowser {
    /// `smb://<instance>._smb._tcp.local`, the host a share mounted from one is remounted by.
    public private(set) var servers: [URL] = []
    /// macOS refused Local Network: nothing will be announced.
    public private(set) var isDenied = false
    public var onChange: (() -> Void)?
    private var browser: NWBrowser?

    public init() {}

    public func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_smb._tcp", domain: "local."), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let servers = Set(results.compactMap { result -> URL? in
                guard case .service(let name, let type, let domain, _) = result.endpoint else { return nil }
                let host = [name, type, domain].map { $0.hasSuffix(".") ? String($0.dropLast()) : $0 }.joined(separator: ".")
                return Servers.url(host: host)
            })
            MainActor.assumeIsolated {
                guard let self else { return }
                self.servers = servers.sorted { Servers.name(of: $0).localizedStandardCompare(Servers.name(of: $1)) == .orderedAscending }
                self.onChange?()
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            let denied: Bool
            if case .waiting(let error) = state, case .dns(let code) = error, code == kDNSServiceErr_PolicyDenied { denied = true } else { denied = false }
            MainActor.assumeIsolated {
                guard let self, self.isDenied != denied else { return }
                self.isDenied = denied
                self.onChange?()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    public func stop() {
        browser?.cancel()
        browser = nil
        servers = []
    }
}
