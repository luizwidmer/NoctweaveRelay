import Combine
import Foundation
import PICCPCore
#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
#endif

enum RelayStorageMode: String, CaseIterable, Identifiable {
    case disk
    case memory

    var id: String { rawValue }
}

private enum RelayStorePathValidationError: LocalizedError {
    case invalidStorePath
    case storePathIsDirectory
    case storeDirectoryNotWritable(String)
    case storeFileNotWritable(String)

    var errorDescription: String? {
        switch self {
        case .invalidStorePath:
            return "Choose a valid file path for relay storage."
        case .storePathIsDirectory:
            return "Store path points to a directory. Choose a file path (for example relay_store.json)."
        case .storeDirectoryNotWritable(let path):
            return "Store directory is not writable: \(path)"
        case .storeFileNotWritable(let path):
            return "Store file is not writable: \(path)"
        }
    }
}

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
    @Published var storageMode: RelayStorageMode = .disk
    @Published var storePath: String = ""
    @Published var relayPassword: String = ""
    @Published var relayPasswordConfirmation: String = ""
    @Published var tlsEnabled: Bool = false
    @Published var tlsIdentityPKCS12Path: String = ""
    @Published var tlsIdentityPassword: String = ""
    @Published var isRunning = false
    @Published var logs: [String] = []
    @Published var lastError: String?

    private let defaultStoreURL: URL
    private var store: RelayStore
    private var server: RelayServer
    let softwareVersion: String
    private let defaultRelayPort: UInt16 = 9339

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PICCPServer", isDirectory: true)
        let storeURL = directory.appendingPathComponent("relay_store.json")
        self.defaultStoreURL = storeURL
        self.storePath = storeURL.path
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
        let trimmedPassword = relayPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPassword.isEmpty {
            guard trimmedPassword.count >= 8 else {
                lastError = "Relay password must have at least 8 characters."
                return
            }
            guard trimmedPassword == relayPasswordConfirmation else {
                lastError = "Relay password confirmation does not match."
                return
            }
        }
        let trimmedTLSPath = tlsIdentityPKCS12Path.trimmingCharacters(in: .whitespacesAndNewlines)
        if tlsEnabled {
            guard !trimmedTLSPath.isEmpty else {
                lastError = "TLS is enabled. Choose a PKCS#12 certificate identity (.p12/.pfx)."
                return
            }
            let expandedPath = (trimmedTLSPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expandedPath) else {
                lastError = "TLS certificate file not found at \(expandedPath)."
                return
            }
        }
        let resolvedStoreURL: URL?
        do {
            resolvedStoreURL = try validatedStoreURL()
        } catch {
            lastError = error.localizedDescription
            return
        }
        let configuration = buildConfiguration()
        store = RelayStore(storeURL: resolvedStoreURL, temporalBucketSeconds: configuration.temporalBucketSeconds)
        server = RelayServer(store: store, configuration: configuration)
        server.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event: event)
            }
        }
        Task {
            do {
                if resolvedStoreURL != nil {
                    try await store.loadFromDisk()
                }
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
        let password = relayPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let tlsPath = tlsIdentityPKCS12Path.trimmingCharacters(in: .whitespacesAndNewlines)
        let tlsPassword = tlsIdentityPassword.trimmingCharacters(in: .whitespacesAndNewlines)
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
            accessPassword: password.isEmpty ? nil : password,
            tlsEnabled: tlsEnabled,
            tlsIdentityPKCS12Path: tlsPath.isEmpty ? nil : tlsPath,
            tlsIdentityPassword: tlsPassword.isEmpty ? nil : tlsPassword,
            federationAllowList: allowList
        )
    }

    private func resolvedStoreURL() -> URL? {
        switch storageMode {
        case .memory:
            return nil
        case .disk:
            let trimmed = storePath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return defaultStoreURL
            }
            let expanded = (trimmed as NSString).expandingTildeInPath
            return URL(fileURLWithPath: expanded)
        }
    }

    var storageLocationDescription: String {
        guard storageMode == .disk else {
            return "RAM mode keeps all relay data in memory only."
        }
        let url = resolvedStoreURL() ?? defaultStoreURL
        let volumeName = (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
            ?? "Unknown Volume"
        return "Volume: \(volumeName) | File: \(url.path)"
    }

    private func validatedStoreURL() throws -> URL? {
        guard storageMode == .disk else {
            return nil
        }
        guard let storeURL = resolvedStoreURL() else {
            throw RelayStorePathValidationError.invalidStorePath
        }
        let fileManager = FileManager.default
        let directory = storeURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard fileManager.isWritableFile(atPath: directory.path) else {
            throw RelayStorePathValidationError.storeDirectoryNotWritable(directory.path)
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: storeURL.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                throw RelayStorePathValidationError.storePathIsDirectory
            }
            guard fileManager.isWritableFile(atPath: storeURL.path) else {
                throw RelayStorePathValidationError.storeFileNotWritable(storeURL.path)
            }
        }
        return storeURL
    }

    func resetStorePathToDefault() {
        storePath = defaultStoreURL.path
    }

    func chooseStorePath() {
#if canImport(AppKit)
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType.json]
        panel.prompt = "Select"
        panel.message = "Choose where relay data should be stored on disk."
        let trimmed = storePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialPath = trimmed.isEmpty ? defaultStoreURL.path : trimmed
        let initialURL = URL(fileURLWithPath: (initialPath as NSString).expandingTildeInPath)
        panel.directoryURL = initialURL.deletingLastPathComponent()
        panel.nameFieldStringValue = initialURL.lastPathComponent.isEmpty ? "relay_store.json" : initialURL.lastPathComponent
        if panel.runModal() == .OK, let url = panel.url {
            storePath = url.path
        }
#endif
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
            return RelayEndpoint(host: host, port: port, useTLS: scheme.lowercased() == "https")
        }
        let base = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
        if base.hasPrefix("["), let close = base.firstIndex(of: "]") {
            let host = String(base[base.index(after: base.startIndex)..<close])
            let portStart = base.index(after: close)
            let portString = base[portStart...].trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard let port = UInt16(portString) else { return nil }
            return RelayEndpoint(host: host, port: port, useTLS: false)
        }
        guard let separator = base.lastIndex(of: ":") else { return nil }
        let host = String(base[..<separator])
        let portString = String(base[base.index(after: separator)...])
        guard let port = UInt16(portString) else { return nil }
        return RelayEndpoint(host: host, port: port, useTLS: false)
    }

    func chooseTLSIdentityPath() {
#if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType.pkcs12]
        panel.prompt = "Select"
        panel.message = "Choose a PKCS#12 identity file (.p12/.pfx) for TLS."
        if panel.runModal() == .OK, let url = panel.url {
            tlsIdentityPKCS12Path = url.path
        }
#endif
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
