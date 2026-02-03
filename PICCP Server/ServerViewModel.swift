import Combine
import Foundation
import PICCPCore

@MainActor
final class ServerViewModel: ObservableObject {
    @Published var host: String = "0.0.0.0"
    @Published var port: String = "9339"
    @Published var relayKind: RelayKind = .standard
    @Published var federationMode: FederationMode = .solo
    @Published var federationName: String = ""
    @Published var federationDescription: String = ""
    @Published var federationAllowList: String = ""
    @Published var federationSourceURL: String = ""
    @Published var federationSourceStatus: String?
    @Published var federationSourceLastUpdated: Date?
    @Published var temporalBucketMinutes: String = "5"
    @Published var relayName: String = ""
    @Published var operatorNote: String = ""
    @Published var isRunning = false
    @Published var logs: [String] = []
    @Published var lastError: String?

    private let storeURL: URL
    private var store: RelayStore
    private var server: RelayServer
    let softwareVersion: String
    private let defaultRelayPort: UInt16 = 9339

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PICCPServer", isDirectory: true)
        self.storeURL = directory.appendingPathComponent("relay_store.json")
        let configuration = RelayConfiguration()
        self.store = RelayStore(storeURL: storeURL, temporalBucketSeconds: configuration.temporalBucketSeconds)
        self.server = RelayServer(store: store, configuration: configuration)
        self.softwareVersion = Self.makeSoftwareVersion()
        server.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event: event)
            }
        }
    }

    func start() {
        guard let portValue = UInt16(port) else {
            lastError = "Invalid port."
            return
        }
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            lastError = "Invalid host."
            return
        }
        let configuration = buildConfiguration()
        store = RelayStore(storeURL: storeURL, temporalBucketSeconds: configuration.temporalBucketSeconds)
        server = RelayServer(store: store, configuration: configuration)
        server.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event: event)
            }
        }
        Task {
            do {
                try await store.loadFromDisk()
                try server.start(host: trimmedHost, port: portValue)
                isRunning = true
            } catch {
                lastError = "Failed to start server: \(error.localizedDescription)"
            }
        }
    }

    func stop() {
        server.stop()
        isRunning = false
    }

    func fetchFederationSource() {
        Task {
            await loadFederationSource()
        }
    }

    private func handle(event: RelayServer.Event) {
        switch event {
        case .started(let port):
            logs.append("Server started on \(host):\(port)")
        case .stopped:
            logs.append("Server stopped")
        case .delivered(let inboxId, let storedCount):
            logs.append("Delivered to \(inboxId.prefix(8))... (\(storedCount) total)")
        case .fetched(let inboxId, let count):
            logs.append("Fetched \(count) from \(inboxId.prefix(8))...")
        case .error(let message):
            logs.append("Error: \(message)")
        }
        if logs.count > 200 {
            logs.removeFirst(logs.count - 200)
        }
    }

    private func buildConfiguration() -> RelayConfiguration {
        let trimmedName = federationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = federationDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRelayName = relayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = operatorNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let minutes = Int(temporalBucketMinutes) ?? 5
        let bucketSeconds = max(0, minutes) * 60
        let allowList = parseAllowList(federationAllowList)
        let federation = FederationDescriptor(
            mode: federationMode,
            name: trimmedName.isEmpty ? nil : trimmedName,
            description: trimmedDescription.isEmpty ? nil : trimmedDescription
        )
        return RelayConfiguration(
            kind: relayKind,
            federation: federation,
            temporalBucketSeconds: bucketSeconds,
            relayName: trimmedRelayName.isEmpty ? nil : trimmedRelayName,
            operatorNote: note.isEmpty ? nil : note,
            softwareVersion: softwareVersion,
            federationAllowList: allowList
        )
    }

    private struct FederationSourceDocument: Decodable {
        var name: String?
        var description: String?
        var mode: String?
        var allowlist: [String]?
    }

    private func loadFederationSource() async {
        let trimmed = federationSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "Federation URL is required."
            return
        }
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https" else {
            lastError = "Federation URL must be a valid https URL."
            return
        }
        federationSourceStatus = "Fetching..."
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                federationSourceStatus = nil
                lastError = "Federation fetch failed with HTTP \(http.statusCode)."
                return
            }
            let document = try JSONDecoder().decode(FederationSourceDocument.self, from: data)
            if let name = document.name {
                federationName = name
            }
            if let description = document.description {
                federationDescription = description
            }
            if let modeValue = document.mode, let mode = parseFederationMode(modeValue) {
                federationMode = mode
            }
            if let allowlist = document.allowlist, !allowlist.isEmpty {
                federationAllowList = allowlist.joined(separator: ", ")
            }
            federationSourceLastUpdated = Date()
            federationSourceStatus = "Loaded \(document.allowlist?.count ?? 0) allowlist entries."
        } catch {
            federationSourceStatus = nil
            lastError = "Failed to fetch federation: \(error.localizedDescription)"
        }
    }

    private func parseAllowList(_ value: String) -> [RelayEndpoint] {
        value
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .compactMap { parseEndpoint(String($0)) }
    }

    private func parseFederationMode(_ value: String) -> FederationMode? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return FederationMode(rawValue: trimmed)
    }

    private func parseEndpoint(_ value: String) -> RelayEndpoint? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URLComponents(string: trimmed), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) {
            guard let host = url.host else { return nil }
            let port = UInt16(url.port ?? Int(defaultRelayPort))
            return RelayEndpoint(host: host, port: port)
        }
        let base = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
        if base.hasPrefix("["), let close = base.firstIndex(of: "]") {
            let host = String(base[base.index(after: base.startIndex)..<close])
            let portStart = base.index(after: close)
            let portString = base[portStart...].trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard let port = UInt16(portString) else { return nil }
            return RelayEndpoint(host: host, port: port)
        }
        guard let separator = base.lastIndex(of: ":") else { return nil }
        let host = String(base[..<separator])
        let portString = String(base[base.index(after: separator)...])
        guard let port = UInt16(portString) else { return nil }
        return RelayEndpoint(host: host, port: port)
    }

    private static func makeSoftwareVersion() -> String {
        let base = "Noctyra Relay"
        guard let info = Bundle.main.infoDictionary else {
            return base
        }
        let short = info["CFBundleShortVersionString"] as? String
        let build = info["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?) where short != build:
            return "\(base) \(short) (\(build))"
        case let (short?, _):
            return "\(base) \(short)"
        case let (_, build?):
            return "\(base) \(build)"
        default:
            return base
        }
    }
}
