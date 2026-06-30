import Combine
import Foundation
import NoctweaveCore
import Network
#if canImport(Security)
import Security
#endif
#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
#endif

enum RelayStorageMode: String, CaseIterable, Identifiable, Codable {
    case disk
    case memory

    var id: String { rawValue }
}

enum RelayAttachmentStorageBackend: String, CaseIterable, Identifiable, Codable {
    case inline
    case ipfs

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .inline:
            return "Inline"
        case .ipfs:
            return "IPFS"
        }
    }

    var advertisedName: String? {
        switch self {
        case .inline:
            return nil
        case .ipfs:
            return rawValue
        }
    }
}

private final class RelayIPFSAttachmentBlobStore: AttachmentBlobStore {
    let backendName = "ipfs"

    private let apiEndpoint: URL
    private let gatewayEndpoint: URL
    private let timeoutSeconds: TimeInterval

    init(apiEndpoint: URL, gatewayEndpoint: URL? = nil, timeoutSeconds: TimeInterval = 10) {
        self.apiEndpoint = apiEndpoint
        self.gatewayEndpoint = gatewayEndpoint ?? apiEndpoint
        self.timeoutSeconds = max(1, timeoutSeconds)
    }

    func put(_ data: Data, attachmentId: UUID, chunkIndex: Int, expiresAt: Date) throws -> AttachmentExternalRecord {
        let boundary = "noctyra-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(attachmentId.uuidString)-\(chunkIndex).bin\"\r\n".utf8))
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: apiURL(path: "/api/v0/add", queryItems: [
            URLQueryItem(name: "pin", value: "true"),
            URLQueryItem(name: "cid-version", value: "1"),
            URLQueryItem(name: "raw-leaves", value: "true"),
            URLQueryItem(name: "quiet", value: "true")
        ]))
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let responseData = try send(request)
        guard let cid = decodeCID(from: responseData), !cid.isEmpty else {
            throw AttachmentBlobStoreError.uploadFailed("IPFS add response did not contain a CID")
        }
        return AttachmentExternalRecord(
            backend: backendName,
            locator: cid,
            byteCount: data.count,
            sha256Hex: AttachmentBlobDigest.sha256Hex(data),
            expiresAt: expiresAt
        )
    }

    func get(_ record: AttachmentExternalRecord) throws -> Data {
        let data = try fetch(locator: record.locator)
        guard data.count == record.byteCount,
              AttachmentBlobDigest.sha256Hex(data) == record.sha256Hex else {
            throw AttachmentBlobStoreError.digestMismatch
        }
        return data
    }

    func delete(_ record: AttachmentExternalRecord) {
        var request = URLRequest(url: apiURL(path: "/api/v0/pin/rm", queryItems: [
            URLQueryItem(name: "arg", value: record.locator)
        ]))
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        _ = try? send(request)
    }

    private func fetch(locator: String) throws -> Data {
        var catRequest = URLRequest(url: apiURL(path: "/api/v0/cat", queryItems: [
            URLQueryItem(name: "arg", value: locator)
        ]))
        catRequest.httpMethod = "POST"
        catRequest.timeoutInterval = timeoutSeconds
        if let data = try? send(catRequest) {
            return data
        }

        var gatewayURL = gatewayEndpoint
        gatewayURL.appendPathComponent("ipfs")
        gatewayURL.appendPathComponent(locator)
        var gatewayRequest = URLRequest(url: gatewayURL)
        gatewayRequest.timeoutInterval = timeoutSeconds
        return try send(gatewayRequest)
    }

    private func apiURL(path: String, queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents(url: apiEndpoint, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.queryItems = queryItems
        return components?.url ?? apiEndpoint
    }

    private func send(_ request: URLRequest) throws -> Data {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: Result<Data, Error>?
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            let nextResult: Result<Data, Error>
            if let error {
                nextResult = .failure(error)
            } else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                if (200..<300).contains(status) {
                    nextResult = .success(data ?? Data())
                } else {
                    nextResult = .failure(AttachmentBlobStoreError.fetchFailed("HTTP \(status)"))
                }
            }
            lock.lock()
            result = nextResult
            lock.unlock()
        }.resume()

        let timeout = DispatchTime.now() + timeoutSeconds + 1
        guard semaphore.wait(timeout: timeout) == .success else {
            throw AttachmentBlobStoreError.fetchFailed("Request timed out")
        }
        lock.lock()
        let finalResult = result
        lock.unlock()
        switch finalResult {
        case .success(let data):
            return data
        case .failure(let error):
            throw error
        case .none:
            throw AttachmentBlobStoreError.fetchFailed("No response")
        }
    }

    private func decodeCID(from data: Data) -> String? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let hash = object["Hash"] as? String {
            return hash
        }
        let lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
        for line in lines.reversed() {
            if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let hash = object["Hash"] as? String {
                return hash
            }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }
}

enum RelayTransportSecurityMode: String, CaseIterable, Identifiable, Codable {
    case plainTCP
    case relayManagedTLS
    case reverseProxyTLS

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .plainTCP:
            return "No TLS"
        case .relayManagedTLS:
            return "Relay TLS"
        case .reverseProxyTLS:
            return "Proxy TLS"
        }
    }

    var usesRelayTLS: Bool {
        self == .relayManagedTLS
    }

    var advertisesTLS: Bool {
        self == .relayManagedTLS || self == .reverseProxyTLS
    }
}

enum RelayCommunicationMode: String, CaseIterable, Identifiable, Codable {
    case tcp
    case http

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .tcp:
            return "TCP Frames"
        case .http:
            return "HTTP API"
        }
    }

    var relayTransport: RelayEndpointTransport {
        switch self {
        case .tcp:
            return .tcp
        case .http:
            return .http
        }
    }
}

enum RelayTemporalBucketMode: String, CaseIterable, Identifiable, Codable {
    case disabled
    case single
    case multi

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .disabled:
            return "Off"
        case .single:
            return "Single"
        case .multi:
            return "Multi"
        }
    }
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
            return "Store path points to a directory. Choose a file path (for example relay_store.sqlite)."
        case .storeDirectoryNotWritable(let path):
            return "Store directory is not writable: \(path)"
        case .storeFileNotWritable(let path):
            return "Store file is not writable: \(path)"
        }
    }
}

private enum RelayAttachmentStorageValidationError: LocalizedError {
    case invalidIPFSAPIEndpoint
    case invalidIPFSGatewayEndpoint
    case invalidIPFSTimeout

    var errorDescription: String? {
        switch self {
        case .invalidIPFSAPIEndpoint:
            return "IPFS attachment storage requires a valid HTTP or HTTPS API endpoint."
        case .invalidIPFSGatewayEndpoint:
            return "IPFS gateway endpoint must be a valid HTTP or HTTPS URL."
        case .invalidIPFSTimeout:
            return "IPFS timeout must be at least 1 second."
        }
    }
}

enum StartupPermissionStatus: String {
    case idle
    case requesting
    case granted
    case denied
    case failed

    var displayTitle: String {
        switch self {
        case .idle:
            return "Not requested"
        case .requesting:
            return "Requesting"
        case .granted:
            return "Granted"
        case .denied:
            return "Denied"
        case .failed:
            return "Failed"
        }
    }
}

private final class PermissionProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var resolved = false

    nonisolated func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resolved else { return false }
        resolved = true
        return true
    }
}

#if canImport(Security)
private enum RelaySecretStore {
    enum Account: String {
        case relayPassword = "relay-password"
        case coordinatorRegistrationToken = "coordinator-registration-token"
        case federationForwardingAuthToken = "federation-forwarding-auth-token"
        case tlsIdentityPassword = "tls-identity-password"
        case coordinatorDirectorySigningKey = "coordinator-directory-signing-key"
    }

    private static let service = "com.noctyra.relay.configuration"

    static func load(account: Account) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw RelaySecretStoreError.keychain(status)
        }
        return value
    }

    static func save(_ value: String, account: Account) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        guard !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw RelaySecretStoreError.keychain(status)
            }
            return
        }

        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw RelaySecretStoreError.keychain(updateStatus)
        }

        var attributes = query
        attributes[kSecValueData as String] = data
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw RelaySecretStoreError.keychain(addStatus)
        }
    }
}

private enum RelaySecretStoreError: LocalizedError {
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "Unable to access relay secrets in Keychain (status \(status))."
        }
    }
}
#else
private enum RelaySecretStore {
    enum Account {
        case relayPassword
        case coordinatorRegistrationToken
        case federationForwardingAuthToken
        case tlsIdentityPassword
    }

    static func load(account: Account) throws -> String? { nil }
    static func save(_ value: String, account: Account) throws {}
}
#endif

@MainActor
final class ServerViewModel: ObservableObject {
    @Published var host: String = "0.0.0.0"
    @Published var port: String = "9339"
    @Published var relayKind: RelayKind = .standard
    @Published var federationMode: FederationMode = .solo
    @Published var federationName: String = ""
    @Published var federationDescription: String = ""
    @Published var federationAllowList: String = ""
    @Published var federationCoordinatorList: String = ""
    @Published var federationCoordinatorPublicKeys: String = ""
    @Published var coordinatorHeartbeatSeconds: String = "45"
    @Published var coordinatorDirectoryMaxStalenessSeconds: String = "300"
    @Published var curatedStrictPolicyEnabled: Bool = true
    @Published var curatedCoordinatorQuorum: String = "1"
    @Published var curatedRequireSignedDirectory: Bool = true
    @Published var allowPrivateFederationEndpoints: Bool = false
    @Published var openFederationDHTEnabled: Bool = false
    @Published var openFederationDHTMaxRecords: String = "256"
    @Published var openFederationDHTMaxRecordsPerHost: String = "4"
    @Published var openFederationDHTMaxQueryRecords: String = "256"
    @Published var relayPeerExchangeLimit: String = "12"
    @Published var advertisedEndpoint: String = ""
    @Published var federationSourceURL: String = ""
    @Published var federationSourceStatus: String?
    @Published var federationSourceLastUpdated: Date?
    @Published var temporalBucketMode: RelayTemporalBucketMode = .single
    @Published var temporalBucketMinutes: String = "5"
    @Published var temporalBucketScheduleMinutes: String = ""
    @Published var attachmentDefaultTTLMinutes: String = "60"
    @Published var attachmentMaxTTLMinutes: String = "360"
    @Published var attachmentsEnabled: Bool = true
    @Published var attachmentStorageBackend: RelayAttachmentStorageBackend = .inline
    @Published var ipfsAPIEndpoint: String = "http://127.0.0.1:5001"
    @Published var ipfsGatewayEndpoint: String = ""
    @Published var ipfsTimeoutSeconds: String = "10"
    @Published var hiddenRetrievalEnabled: Bool = false
    @Published var hiddenRetrievalMode: HiddenRetrievalMode = .coverQuery
    @Published var hiddenRetrievalCoverSize: String = "8"
    @Published var hiddenRetrievalMaxCoverSize: String = "32"
    @Published var onionTransportEnabled: Bool = false
    @Published var onionTransportMaxHops: String = "3"
    @Published var onionTransportRequiresFixedSizePackets: Bool = true
    @Published var mixnetTransportEnabled: Bool = false
    @Published var mixnetBatchIntervalSeconds: String = "30"
    @Published var mixnetMinBatchSize: String = "8"
    @Published var mixnetCoverPacketsPerBatch: String = "2"
    @Published var mixnetMaxDelaySeconds: String = "120"
    @Published var wakeModeEnabled: Bool = false
    @Published var wakeMode: DecentralizedWakeMode = .pullOnly
    @Published var wakeMinPollSeconds: String = "60"
    @Published var wakeMaxPollSeconds: String = "300"
    @Published var wakeJitterPermille: String = "250"
    @Published var wakeLongPollTimeoutSeconds: String = "60"
    @Published var relayName: String = ""
    @Published var operatorNote: String = ""
    @Published var groupCreationMode: GroupCreationMode = .allowed
    @Published var groupSecurityModel: GroupSecurityModel = .relayBackedPairwise
    @Published var storageMode: RelayStorageMode = .disk
    @Published var storePath: String = ""
    @Published var maxInboxMessages: String = "1000"
    @Published var relayPassword: String = ""
    @Published var relayPasswordConfirmation: String = ""
    @Published var coordinatorRegistrationToken: String = ""
    @Published var federationForwardingAuthToken: String = ""
    @Published var communicationMode: RelayCommunicationMode = .tcp
    @Published var transportSecurityMode: RelayTransportSecurityMode = .plainTCP
    @Published var tlsIdentityPKCS12Path: String = ""
    @Published var tlsIdentityPassword: String = ""
    @Published var isRunning = false
    @Published var logs: [String] = []
    @Published var lastError: String?
    @Published var localNetworkPermissionStatus: StartupPermissionStatus = .idle
    @Published var incomingConnectionPermissionStatus: StartupPermissionStatus = .idle
    @Published var permissionProbeMessage: String?
    @Published var permissionProbeRunning = false
    @Published var permissionProbeHasRun = false

    private let defaultStoreURL: URL
    private let settingsURL: URL
    private var store: RelayStore
    private var server: RelayServer
    let softwareVersion: String
    private let defaultRelayPort: UInt16 = 9339
    private var settingsCancellables: Set<AnyCancellable> = []
    private var isApplyingPersistedSettings = false

    var effectiveTLSEnabled: Bool {
        transportSecurityMode.advertisesTLS
    }

    var permissionPreflightReady: Bool {
        permissionProbeHasRun
    }

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoctyraRelay", isDirectory: true)
        let storeURL = directory.appendingPathComponent("relay_store.sqlite")
        self.defaultStoreURL = storeURL
        self.settingsURL = directory.appendingPathComponent("relay_settings.json")
        self.storePath = storeURL.path
        self.softwareVersion = Self.makeSoftwareVersion()
        let bootstrapConfiguration = RelayConfiguration()
        self.store = RelayStore(
            storeURL: storeURL,
            temporalBucketSeconds: bootstrapConfiguration.temporalBucketSeconds,
            temporalBucketScheduleSeconds: bootstrapConfiguration.temporalBucketScheduleSeconds,
            attachmentBlobStore: nil,
            maxInboxMessages: 1_000
        )
        self.server = RelayServer(store: store, configuration: bootstrapConfiguration)
        server.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event: event)
            }
        }
        loadPersistedSettingsIfAvailable()
        rebuildRuntimeWithCurrentSettings()
        bindSettingsPersistence()
        persistSettings()
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
        if transportSecurityMode.usesRelayTLS {
            guard !trimmedTLSPath.isEmpty else {
                lastError = "Relay TLS is enabled. Choose a PKCS#12 certificate identity (.p12/.pfx)."
                return
            }
            let expandedPath = (trimmedTLSPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expandedPath) else {
                lastError = "TLS certificate file not found at \(expandedPath)."
                return
            }
        } else if transportSecurityMode == .reverseProxyTLS {
            guard let advertised = parseEndpoint(advertisedEndpoint) else {
                lastError = "Proxy TLS mode requires an advertised endpoint (for example tls://relay.example.org:443)."
                return
            }
            guard advertised.useTLS else {
                lastError = "Advertised endpoint must be TLS-enabled in Proxy TLS mode (use tls:// or https://)."
                return
            }
            guard advertised.transport == communicationMode.relayTransport else {
                let requiredScheme = communicationMode == .http ? "https://" : "tls://"
                lastError = "Advertised endpoint must match communication mode. Use \(requiredScheme) for Proxy TLS."
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
        if federationMode == .manual {
            guard relayKind == .standard else {
                lastError = "Manual federation uses standard relays only. Set Relay Kind to Standard."
                return
            }
            guard !configuration.federationAllowList.isEmpty else {
                lastError = "Manual federation requires at least one node in the federated node list."
                return
            }
        }
        let attachmentBlobStore: AttachmentBlobStore?
        do {
            attachmentBlobStore = try makeAttachmentBlobStore()
        } catch {
            lastError = error.localizedDescription
            return
        }
        store = RelayStore(
            storeURL: resolvedStoreURL,
            temporalBucketSeconds: configuration.temporalBucketSeconds,
            temporalBucketScheduleSeconds: configuration.temporalBucketScheduleSeconds,
            attachmentBlobStore: attachmentBlobStore,
            maxInboxMessages: parsedMaxInboxMessages
        )
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

    func runStartupPermissionProbe() {
        guard !permissionProbeRunning else { return }
        permissionProbeRunning = true
        localNetworkPermissionStatus = .requesting
        incomingConnectionPermissionStatus = .requesting
        permissionProbeMessage = "Requesting local network and incoming listener permissions..."
        Task {
            let localResult = await Self.probeLocalNetworkPermission()
            let incomingResult = await Self.probeIncomingConnectionPermission()
            await MainActor.run {
                localNetworkPermissionStatus = localResult.status
                incomingConnectionPermissionStatus = incomingResult.status
                permissionProbeRunning = false
                permissionProbeHasRun = true
                let summaries = [localResult.message, incomingResult.message].compactMap { $0 }
                permissionProbeMessage = summaries.joined(separator: "\n")
            }
        }
    }

    private func handle(event: RelayServer.Event) {
        switch event {
        case .started(let port):
            logs.append("Server started on \(host):\(port)")
        case .stopped:
            logs.append("Server stopped")
        case .delivered(_, let storedCount):
            logs.append("Accepted encrypted delivery (\(storedCount) queued)")
        case .fetched(_, let count):
            logs.append("Returned \(count) encrypted envelope(s)")
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
        let registrationToken = coordinatorRegistrationToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let forwardingToken = federationForwardingAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let tlsPath = tlsIdentityPKCS12Path.trimmingCharacters(in: .whitespacesAndNewlines)
        let tlsPassword = tlsIdentityPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let minutes = max(1, Int(temporalBucketMinutes) ?? 5)
        let singleBucketSeconds = minutes * 60
        let scheduleSeconds = parseBucketScheduleMinutes(temporalBucketScheduleMinutes)
        let activeScheduleSeconds: [Int]
        let effectiveBucketSeconds: Int
        switch temporalBucketMode {
        case .disabled:
            activeScheduleSeconds = []
            effectiveBucketSeconds = 0
        case .single:
            activeScheduleSeconds = []
            effectiveBucketSeconds = singleBucketSeconds
        case .multi:
            let defaultSchedule = [singleBucketSeconds]
            activeScheduleSeconds = scheduleSeconds.isEmpty ? defaultSchedule : scheduleSeconds
            effectiveBucketSeconds = activeScheduleSeconds.first ?? singleBucketSeconds
        }
        let defaultAttachmentTTLSeconds = max(1, Int(attachmentDefaultTTLMinutes) ?? 60) * 60
        let maxAttachmentTTLSeconds = max(1, Int(attachmentMaxTTLMinutes) ?? 360) * 60
        let hiddenRetrieval = hiddenRetrievalEnabled
            ? HiddenRetrievalSupport(
                mode: hiddenRetrievalMode,
                defaultCoverSetSize: max(1, Int(hiddenRetrievalCoverSize) ?? 8),
                maxCoverSetSize: max(1, Int(hiddenRetrievalMaxCoverSize) ?? 32)
            )
            : nil
        let onionTransport = onionTransportEnabled
            ? OnionTransportSupport(
                enabled: true,
                maxHops: Int(onionTransportMaxHops) ?? 3,
                requiresFixedSizePackets: onionTransportRequiresFixedSizePackets
            )
            : nil
        let mixnetTransport = mixnetTransportEnabled
            ? MixnetTransportSupport(
                enabled: true,
                batchIntervalSeconds: Int(mixnetBatchIntervalSeconds) ?? 30,
                minBatchSize: Int(mixnetMinBatchSize) ?? 8,
                coverPacketsPerBatch: Int(mixnetCoverPacketsPerBatch) ?? 2,
                maxDelaySeconds: Int(mixnetMaxDelaySeconds) ?? 120
            )
            : nil
        let wakeSupport = wakeModeEnabled
            ? DecentralizedWakeSupport(
                mode: wakeMode,
                minPollIntervalSeconds: max(5, Int(wakeMinPollSeconds) ?? 60),
                maxPollIntervalSeconds: max(5, Int(wakeMaxPollSeconds) ?? 300),
                jitterPermille: min(max(0, Int(wakeJitterPermille) ?? 250), 1_000),
                longPollTimeoutSeconds: wakeMode == .longPoll ? max(5, Int(wakeLongPollTimeoutSeconds) ?? 60) : nil
            )
            : nil
        let allowList = parseAllowList(federationAllowList)
        let coordinators = parseCoordinatorEndpoints(
            endpointsValue: federationCoordinatorList,
            publicKeysValue: federationCoordinatorPublicKeys
        )
        let heartbeatSeconds = max(15, Int(coordinatorHeartbeatSeconds) ?? 45)
        let directoryMaxStalenessSeconds = max(30, Int(coordinatorDirectoryMaxStalenessSeconds) ?? 300)
        let curatedQuorum = max(1, Int(curatedCoordinatorQuorum) ?? 1)
        let advertisedRelayEndpoint = parseEndpoint(advertisedEndpoint)
        let federation = FederationDescriptor(
            mode: federationMode,
            name: trimmedName.isEmpty ? nil : trimmedName,
            description: trimmedDescription.isEmpty ? nil : trimmedDescription
        )
        return RelayConfiguration(
            kind: relayKind,
            federation: federation,
            temporalBucketSeconds: effectiveBucketSeconds,
            temporalBucketScheduleSeconds: activeScheduleSeconds.isEmpty ? nil : activeScheduleSeconds,
            attachmentDefaultTTLSeconds: defaultAttachmentTTLSeconds,
            attachmentMaxTTLSeconds: maxAttachmentTTLSeconds,
            attachmentsEnabled: attachmentsEnabled,
            attachmentStorageBackend: attachmentsEnabled ? attachmentStorageBackend.advertisedName : nil,
            hiddenRetrieval: hiddenRetrieval,
            onionTransport: onionTransport,
            mixnetTransport: mixnetTransport,
            wakeSupport: wakeSupport,
            relayName: trimmedRelayName.isEmpty ? nil : trimmedRelayName,
            operatorNote: note.isEmpty ? nil : note,
            softwareVersion: softwareVersion,
            groupCreationMode: groupCreationMode,
            groupSecurityModel: groupSecurityModel,
            accessPassword: password.isEmpty ? nil : password,
            coordinatorRegistrationToken: registrationToken.isEmpty ? nil : registrationToken,
            federationForwardingAuthToken: forwardingToken.isEmpty ? nil : forwardingToken,
            tlsEnabled: transportSecurityMode.usesRelayTLS,
            advertisedTLSEnabled: transportSecurityMode == .reverseProxyTLS ? true : nil,
            transport: communicationMode.relayTransport,
            tlsIdentityPKCS12Path: transportSecurityMode.usesRelayTLS && !tlsPath.isEmpty ? tlsPath : nil,
            tlsIdentityPassword: transportSecurityMode.usesRelayTLS && !tlsPassword.isEmpty ? tlsPassword : nil,
            federationCoordinatorEndpoints: coordinators.isEmpty ? nil : coordinators,
            coordinatorHeartbeatSeconds: heartbeatSeconds,
            coordinatorDirectoryMaxStalenessSeconds: directoryMaxStalenessSeconds,
            relayPeerExchangeLimit: max(0, Int(relayPeerExchangeLimit) ?? 12),
            openFederationDHTEnabled: openFederationDHTEnabled,
            openFederationDHTMaxRecords: max(1, Int(openFederationDHTMaxRecords) ?? 256),
            openFederationDHTMaxRecordsPerHost: max(1, Int(openFederationDHTMaxRecordsPerHost) ?? 4),
            openFederationDHTMaxQueryRecords: max(1, Int(openFederationDHTMaxQueryRecords) ?? 256),
            coordinatorDirectorySigningPrivateKey: coordinatorDirectorySigningKey(),
            curatedStrictPolicyEnabled: curatedStrictPolicyEnabled,
            curatedCoordinatorQuorum: curatedQuorum,
            curatedRequireSignedDirectory: curatedRequireSignedDirectory,
            advertisedEndpoint: advertisedRelayEndpoint,
            federationAllowList: allowList,
            allowPrivateFederationEndpoints: allowPrivateFederationEndpoints
        )
    }

    private func coordinatorDirectorySigningKey() -> Data? {
        guard relayKind == .coordinator else {
            return nil
        }
        if let encoded = try? RelaySecretStore.load(account: .coordinatorDirectorySigningKey),
           let existing = Data(base64Encoded: encoded),
           existing.count == 32 {
            return existing
        }
        let generated = FederationDirectorySignature.privateKeyData(from: nil)
        do {
            try RelaySecretStore.save(
                generated.base64EncodedString(),
                account: .coordinatorDirectorySigningKey
            )
        } catch {
            logs.append("Failed to persist coordinator signing key: \(error.localizedDescription)")
        }
        return generated
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
            return normalizedSQLiteURL(URL(fileURLWithPath: expanded))
        }
    }

    private func makeAttachmentBlobStore() throws -> AttachmentBlobStore? {
        guard attachmentsEnabled, attachmentStorageBackend == .ipfs else {
            return nil
        }
        guard let apiEndpoint = validatedHTTPURL(ipfsAPIEndpoint) else {
            throw RelayAttachmentStorageValidationError.invalidIPFSAPIEndpoint
        }
        let gatewayEndpoint: URL?
        let trimmedGateway = ipfsGatewayEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedGateway.isEmpty {
            gatewayEndpoint = nil
        } else {
            guard let endpoint = validatedHTTPURL(trimmedGateway) else {
                throw RelayAttachmentStorageValidationError.invalidIPFSGatewayEndpoint
            }
            gatewayEndpoint = endpoint
        }
        guard let timeoutSeconds = TimeInterval(ipfsTimeoutSeconds.trimmingCharacters(in: .whitespacesAndNewlines)),
              timeoutSeconds >= 1 else {
            throw RelayAttachmentStorageValidationError.invalidIPFSTimeout
        }
        return RelayIPFSAttachmentBlobStore(
            apiEndpoint: apiEndpoint,
            gatewayEndpoint: gatewayEndpoint,
            timeoutSeconds: timeoutSeconds
        )
    }

    private func validatedHTTPURL(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else {
            return nil
        }
        return url
    }

    private func normalizedSQLiteURL(_ url: URL) -> URL {
        let ext = url.pathExtension.lowercased()
        if ext == "sqlite" || ext == "db" {
            return url
        }
        let base = url.pathExtension.isEmpty ? url : url.deletingPathExtension()
        return base.appendingPathExtension("sqlite")
    }

    private func parseBucketScheduleMinutes(_ value: String) -> [Int] {
        Array(
            Set(
                value
            .split(separator: ",")
            .compactMap { component in
                let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let minutes = Int(trimmed), minutes > 0 else { return nil }
                return minutes * 60
            }
            )
        ).sorted()
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

    private var parsedMaxInboxMessages: Int {
        max(1, Int(maxInboxMessages.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1_000)
    }

    var attachmentStorageDescription: String {
        guard attachmentsEnabled else {
            return "Attachments are disabled; blob storage is unused."
        }
        switch attachmentStorageBackend {
        case .inline:
            return "Encrypted attachment chunks stay inside the relay state store."
        case .ipfs:
            return "Encrypted chunks are pinned through the IPFS API; the relay stores only verified metadata and TTL records."
        }
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
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
        panel.prompt = "Select"
        panel.message = "Choose where relay data should be stored on disk."
        let trimmed = storePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialPath = trimmed.isEmpty ? defaultStoreURL.path : trimmed
        let initialURL = URL(fileURLWithPath: (initialPath as NSString).expandingTildeInPath)
        panel.directoryURL = initialURL.deletingLastPathComponent()
        panel.nameFieldStringValue = initialURL.lastPathComponent.isEmpty ? "relay_store.sqlite" : initialURL.lastPathComponent
        if panel.runModal() == .OK, let url = panel.url {
            storePath = normalizedSQLiteURL(url).path
        }
#endif
    }

    private struct FederationSourceDocument: Decodable {
        struct CoordinatorEntry: Decodable {
            var endpoint: String
            var directorySigningPublicKey: String?
        }

        var name: String?
        var description: String?
        var mode: String?
        var allowlist: [String]?
        var coordinators: [String]?
        var coordinatorEntries: [CoordinatorEntry]?
        var coordinatorPublicKeys: [String]?
        var coordinatorHeartbeatSeconds: Int?
        var coordinatorDirectoryMaxStalenessSeconds: Int?
        var curatedStrictPolicyEnabled: Bool?
        var curatedCoordinatorQuorum: Int?
        var curatedRequireSignedDirectory: Bool?
        var allowPrivateFederationEndpoints: Bool?
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
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                federationSourceStatus = nil
                lastError = "Federation fetch failed with HTTP \(http.statusCode)."
                return
            }
            guard data.count <= 1_000_000 else {
                federationSourceStatus = nil
                lastError = "Federation document exceeds the 1 MB limit."
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
            if let coordinators = document.coordinators, !coordinators.isEmpty {
                federationCoordinatorList = coordinators.joined(separator: ", ")
            }
            if let coordinatorEntries = document.coordinatorEntries, !coordinatorEntries.isEmpty {
                federationCoordinatorList = coordinatorEntries.map(\.endpoint).joined(separator: ", ")
                federationCoordinatorPublicKeys = coordinatorEntries.compactMap(\.directorySigningPublicKey).joined(separator: ", ")
            } else if let coordinatorPublicKeys = document.coordinatorPublicKeys, !coordinatorPublicKeys.isEmpty {
                federationCoordinatorPublicKeys = coordinatorPublicKeys.joined(separator: ", ")
            }
            if let heartbeatSeconds = document.coordinatorHeartbeatSeconds, heartbeatSeconds > 0 {
                coordinatorHeartbeatSeconds = String(max(15, heartbeatSeconds))
            }
            if let maxStalenessSeconds = document.coordinatorDirectoryMaxStalenessSeconds, maxStalenessSeconds > 0 {
                coordinatorDirectoryMaxStalenessSeconds = String(max(30, maxStalenessSeconds))
            }
            if let strict = document.curatedStrictPolicyEnabled {
                curatedStrictPolicyEnabled = strict
            }
            if let quorum = document.curatedCoordinatorQuorum, quorum > 0 {
                curatedCoordinatorQuorum = String(max(1, quorum))
            }
            if let requireSigned = document.curatedRequireSignedDirectory {
                curatedRequireSignedDirectory = requireSigned
            }
            if let allowPrivate = document.allowPrivateFederationEndpoints {
                allowPrivateFederationEndpoints = allowPrivate
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

    private func parseCoordinatorEndpoints(
        endpointsValue: String,
        publicKeysValue: String
    ) -> [RelayEndpoint] {
        let endpoints = parseAllowList(endpointsValue)
        let publicKeys = publicKeysValue
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .map { Data(base64Encoded: String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
        return endpoints.enumerated().map { index, endpoint in
            var endpoint = endpoint
            if index < publicKeys.count {
                endpoint.directorySigningPublicKey = publicKeys[index]
            }
            return endpoint
        }
    }

    private func parseFederationMode(_ value: String) -> FederationMode? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return FederationMode(rawValue: trimmed)
    }

    private func parseEndpoint(_ value: String) -> RelayEndpoint? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URLComponents(string: trimmed), let scheme = url.scheme {
            guard let host = url.host else { return nil }
            let loweredScheme = scheme.lowercased()
            let defaultPort: UInt16
            switch loweredScheme {
            case "https", "wss":
                defaultPort = 443
            case "http", "ws":
                defaultPort = 80
            default:
                defaultPort = defaultRelayPort
            }
            let port = UInt16(url.port ?? Int(defaultPort))
            switch loweredScheme {
            case "https":
                return RelayEndpoint(host: host, port: port, useTLS: true, transport: .http)
            case "http":
                return RelayEndpoint(host: host, port: port, useTLS: false, transport: .http)
            case "tls":
                return RelayEndpoint(host: host, port: port, useTLS: true, transport: .tcp)
            case "tcp":
                return RelayEndpoint(host: host, port: port, useTLS: false, transport: .tcp)
            case "wss":
                return RelayEndpoint(host: host, port: port, useTLS: true, transport: .websocket)
            case "ws":
                return RelayEndpoint(host: host, port: port, useTLS: false, transport: .websocket)
            default:
                return nil
            }
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

    private func rebuildRuntimeWithCurrentSettings() {
        let configuration = buildConfiguration()
        store = RelayStore(
            storeURL: resolvedStoreURL(),
            temporalBucketSeconds: configuration.temporalBucketSeconds,
            temporalBucketScheduleSeconds: configuration.temporalBucketScheduleSeconds,
            maxInboxMessages: parsedMaxInboxMessages
        )
        server = RelayServer(store: store, configuration: configuration)
        server.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event: event)
            }
        }
    }

    private struct PersistedSettings: Codable {
        var host: String
        var port: String
        var relayKind: RelayKind
        var federationMode: FederationMode
        var federationName: String
        var federationDescription: String
        var federationAllowList: String
        var federationCoordinatorList: String
        var federationCoordinatorPublicKeys: String?
        var coordinatorHeartbeatSeconds: String
        var coordinatorDirectoryMaxStalenessSeconds: String?
        var curatedStrictPolicyEnabled: Bool
        var curatedCoordinatorQuorum: String
        var curatedRequireSignedDirectory: Bool
        var allowPrivateFederationEndpoints: Bool?
        var openFederationDHTEnabled: Bool?
        var openFederationDHTMaxRecords: String?
        var openFederationDHTMaxRecordsPerHost: String?
        var openFederationDHTMaxQueryRecords: String?
        var relayPeerExchangeLimit: String?
        var advertisedEndpoint: String
        var federationSourceURL: String
        var temporalBucketMode: RelayTemporalBucketMode?
        var temporalBucketMinutes: String
        var temporalBucketScheduleMinutes: String
        var attachmentDefaultTTLMinutes: String
        var attachmentMaxTTLMinutes: String
        var attachmentsEnabled: Bool?
        var attachmentStorageBackend: RelayAttachmentStorageBackend?
        var ipfsAPIEndpoint: String?
        var ipfsGatewayEndpoint: String?
        var ipfsTimeoutSeconds: String?
        var hiddenRetrievalEnabled: Bool?
        var hiddenRetrievalMode: HiddenRetrievalMode?
        var hiddenRetrievalCoverSize: String?
        var hiddenRetrievalMaxCoverSize: String?
        var onionTransportEnabled: Bool?
        var onionTransportMaxHops: String?
        var onionTransportRequiresFixedSizePackets: Bool?
        var mixnetTransportEnabled: Bool?
        var mixnetBatchIntervalSeconds: String?
        var mixnetMinBatchSize: String?
        var mixnetCoverPacketsPerBatch: String?
        var mixnetMaxDelaySeconds: String?
        var wakeModeEnabled: Bool?
        var wakeMode: DecentralizedWakeMode?
        var wakeMinPollSeconds: String?
        var wakeMaxPollSeconds: String?
        var wakeJitterPermille: String?
        var wakeLongPollTimeoutSeconds: String?
        var relayName: String
        var operatorNote: String
        var groupCreationMode: GroupCreationMode
        var groupSecurityModel: GroupSecurityModel?
        var storageMode: RelayStorageMode
        var storePath: String
        var maxInboxMessages: String?
        var communicationMode: RelayCommunicationMode
        var transportSecurityMode: RelayTransportSecurityMode
        var tlsIdentityPKCS12Path: String
    }

    private func bindSettingsPersistence() {
        let observed: [AnyPublisher<Void, Never>] = [
            $host.map { _ in () }.eraseToAnyPublisher(),
            $port.map { _ in () }.eraseToAnyPublisher(),
            $relayKind.map { _ in () }.eraseToAnyPublisher(),
            $federationMode.map { _ in () }.eraseToAnyPublisher(),
            $federationName.map { _ in () }.eraseToAnyPublisher(),
            $federationDescription.map { _ in () }.eraseToAnyPublisher(),
            $federationAllowList.map { _ in () }.eraseToAnyPublisher(),
            $federationCoordinatorList.map { _ in () }.eraseToAnyPublisher(),
            $federationCoordinatorPublicKeys.map { _ in () }.eraseToAnyPublisher(),
            $coordinatorHeartbeatSeconds.map { _ in () }.eraseToAnyPublisher(),
            $coordinatorDirectoryMaxStalenessSeconds.map { _ in () }.eraseToAnyPublisher(),
            $curatedStrictPolicyEnabled.map { _ in () }.eraseToAnyPublisher(),
            $curatedCoordinatorQuorum.map { _ in () }.eraseToAnyPublisher(),
            $curatedRequireSignedDirectory.map { _ in () }.eraseToAnyPublisher(),
            $allowPrivateFederationEndpoints.map { _ in () }.eraseToAnyPublisher(),
            $openFederationDHTEnabled.map { _ in () }.eraseToAnyPublisher(),
            $openFederationDHTMaxRecords.map { _ in () }.eraseToAnyPublisher(),
            $openFederationDHTMaxRecordsPerHost.map { _ in () }.eraseToAnyPublisher(),
            $openFederationDHTMaxQueryRecords.map { _ in () }.eraseToAnyPublisher(),
            $relayPeerExchangeLimit.map { _ in () }.eraseToAnyPublisher(),
            $advertisedEndpoint.map { _ in () }.eraseToAnyPublisher(),
            $federationSourceURL.map { _ in () }.eraseToAnyPublisher(),
            $temporalBucketMode.map { _ in () }.eraseToAnyPublisher(),
            $temporalBucketMinutes.map { _ in () }.eraseToAnyPublisher(),
            $temporalBucketScheduleMinutes.map { _ in () }.eraseToAnyPublisher(),
            $attachmentDefaultTTLMinutes.map { _ in () }.eraseToAnyPublisher(),
            $attachmentMaxTTLMinutes.map { _ in () }.eraseToAnyPublisher(),
            $attachmentsEnabled.map { _ in () }.eraseToAnyPublisher(),
            $attachmentStorageBackend.map { _ in () }.eraseToAnyPublisher(),
            $ipfsAPIEndpoint.map { _ in () }.eraseToAnyPublisher(),
            $ipfsGatewayEndpoint.map { _ in () }.eraseToAnyPublisher(),
            $ipfsTimeoutSeconds.map { _ in () }.eraseToAnyPublisher(),
            $hiddenRetrievalEnabled.map { _ in () }.eraseToAnyPublisher(),
            $hiddenRetrievalMode.map { _ in () }.eraseToAnyPublisher(),
            $hiddenRetrievalCoverSize.map { _ in () }.eraseToAnyPublisher(),
            $hiddenRetrievalMaxCoverSize.map { _ in () }.eraseToAnyPublisher(),
            $onionTransportEnabled.map { _ in () }.eraseToAnyPublisher(),
            $onionTransportMaxHops.map { _ in () }.eraseToAnyPublisher(),
            $onionTransportRequiresFixedSizePackets.map { _ in () }.eraseToAnyPublisher(),
            $mixnetTransportEnabled.map { _ in () }.eraseToAnyPublisher(),
            $mixnetBatchIntervalSeconds.map { _ in () }.eraseToAnyPublisher(),
            $mixnetMinBatchSize.map { _ in () }.eraseToAnyPublisher(),
            $mixnetCoverPacketsPerBatch.map { _ in () }.eraseToAnyPublisher(),
            $mixnetMaxDelaySeconds.map { _ in () }.eraseToAnyPublisher(),
            $wakeModeEnabled.map { _ in () }.eraseToAnyPublisher(),
            $wakeMode.map { _ in () }.eraseToAnyPublisher(),
            $wakeMinPollSeconds.map { _ in () }.eraseToAnyPublisher(),
            $wakeMaxPollSeconds.map { _ in () }.eraseToAnyPublisher(),
            $wakeJitterPermille.map { _ in () }.eraseToAnyPublisher(),
            $wakeLongPollTimeoutSeconds.map { _ in () }.eraseToAnyPublisher(),
            $relayName.map { _ in () }.eraseToAnyPublisher(),
            $operatorNote.map { _ in () }.eraseToAnyPublisher(),
            $groupCreationMode.map { _ in () }.eraseToAnyPublisher(),
            $groupSecurityModel.map { _ in () }.eraseToAnyPublisher(),
            $storageMode.map { _ in () }.eraseToAnyPublisher(),
            $storePath.map { _ in () }.eraseToAnyPublisher(),
            $maxInboxMessages.map { _ in () }.eraseToAnyPublisher(),
            $relayPassword.map { _ in () }.eraseToAnyPublisher(),
            $relayPasswordConfirmation.map { _ in () }.eraseToAnyPublisher(),
            $coordinatorRegistrationToken.map { _ in () }.eraseToAnyPublisher(),
            $federationForwardingAuthToken.map { _ in () }.eraseToAnyPublisher(),
            $communicationMode.map { _ in () }.eraseToAnyPublisher(),
            $transportSecurityMode.map { _ in () }.eraseToAnyPublisher(),
            $tlsIdentityPKCS12Path.map { _ in () }.eraseToAnyPublisher(),
            $tlsIdentityPassword.map { _ in () }.eraseToAnyPublisher()
        ]

        Publishers.MergeMany(observed)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                if self.isApplyingPersistedSettings {
                    return
                }
                self.persistSettings()
            }
            .store(in: &settingsCancellables)
    }

    private func makePersistedSettings() -> PersistedSettings {
        PersistedSettings(
            host: host,
            port: port,
            relayKind: relayKind,
            federationMode: federationMode,
            federationName: federationName,
            federationDescription: federationDescription,
            federationAllowList: federationAllowList,
            federationCoordinatorList: federationCoordinatorList,
            federationCoordinatorPublicKeys: federationCoordinatorPublicKeys,
            coordinatorHeartbeatSeconds: coordinatorHeartbeatSeconds,
            coordinatorDirectoryMaxStalenessSeconds: coordinatorDirectoryMaxStalenessSeconds,
            curatedStrictPolicyEnabled: curatedStrictPolicyEnabled,
            curatedCoordinatorQuorum: curatedCoordinatorQuorum,
            curatedRequireSignedDirectory: curatedRequireSignedDirectory,
            allowPrivateFederationEndpoints: allowPrivateFederationEndpoints,
            openFederationDHTEnabled: openFederationDHTEnabled,
            openFederationDHTMaxRecords: openFederationDHTMaxRecords,
            openFederationDHTMaxRecordsPerHost: openFederationDHTMaxRecordsPerHost,
            openFederationDHTMaxQueryRecords: openFederationDHTMaxQueryRecords,
            relayPeerExchangeLimit: relayPeerExchangeLimit,
            advertisedEndpoint: advertisedEndpoint,
            federationSourceURL: federationSourceURL,
            temporalBucketMode: temporalBucketMode,
            temporalBucketMinutes: temporalBucketMinutes,
            temporalBucketScheduleMinutes: temporalBucketScheduleMinutes,
            attachmentDefaultTTLMinutes: attachmentDefaultTTLMinutes,
            attachmentMaxTTLMinutes: attachmentMaxTTLMinutes,
            attachmentsEnabled: attachmentsEnabled,
            attachmentStorageBackend: attachmentStorageBackend,
            ipfsAPIEndpoint: ipfsAPIEndpoint,
            ipfsGatewayEndpoint: ipfsGatewayEndpoint,
            ipfsTimeoutSeconds: ipfsTimeoutSeconds,
            hiddenRetrievalEnabled: hiddenRetrievalEnabled,
            hiddenRetrievalMode: hiddenRetrievalMode,
            hiddenRetrievalCoverSize: hiddenRetrievalCoverSize,
            hiddenRetrievalMaxCoverSize: hiddenRetrievalMaxCoverSize,
            onionTransportEnabled: onionTransportEnabled,
            onionTransportMaxHops: onionTransportMaxHops,
            onionTransportRequiresFixedSizePackets: onionTransportRequiresFixedSizePackets,
            mixnetTransportEnabled: mixnetTransportEnabled,
            mixnetBatchIntervalSeconds: mixnetBatchIntervalSeconds,
            mixnetMinBatchSize: mixnetMinBatchSize,
            mixnetCoverPacketsPerBatch: mixnetCoverPacketsPerBatch,
            mixnetMaxDelaySeconds: mixnetMaxDelaySeconds,
            wakeModeEnabled: wakeModeEnabled,
            wakeMode: wakeMode,
            wakeMinPollSeconds: wakeMinPollSeconds,
            wakeMaxPollSeconds: wakeMaxPollSeconds,
            wakeJitterPermille: wakeJitterPermille,
            wakeLongPollTimeoutSeconds: wakeLongPollTimeoutSeconds,
            relayName: relayName,
            operatorNote: operatorNote,
            groupCreationMode: groupCreationMode,
            groupSecurityModel: groupSecurityModel,
            storageMode: storageMode,
            storePath: storePath,
            maxInboxMessages: maxInboxMessages,
            communicationMode: communicationMode,
            transportSecurityMode: transportSecurityMode,
            tlsIdentityPKCS12Path: tlsIdentityPKCS12Path
        )
    }

    private func persistSettings() {
        let settings = makePersistedSettings()
        do {
            try RelaySecretStore.save(relayPassword, account: .relayPassword)
            try RelaySecretStore.save(coordinatorRegistrationToken, account: .coordinatorRegistrationToken)
            try RelaySecretStore.save(federationForwardingAuthToken, account: .federationForwardingAuthToken)
            try RelaySecretStore.save(tlsIdentityPassword, account: .tlsIdentityPassword)
            let directory = settingsURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let data = try JSONEncoder().encode(settings)
            try data.write(to: settingsURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: settingsURL.path
            )
        } catch {
            // Keep runtime functional even if settings cannot be written.
            logs.append("Settings persistence failed: \(error.localizedDescription)")
            if logs.count > 200 {
                logs.removeFirst(logs.count - 200)
            }
        }
    }

    private func loadPersistedSettingsIfAvailable() {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else {
            return
        }
        do {
            let data = try Data(contentsOf: settingsURL)
            let persisted = try JSONDecoder().decode(PersistedSettings.self, from: data)
            isApplyingPersistedSettings = true
            host = persisted.host
            port = persisted.port
            relayKind = persisted.relayKind
            federationMode = persisted.federationMode
            federationName = persisted.federationName
            federationDescription = persisted.federationDescription
            federationAllowList = persisted.federationAllowList
            federationCoordinatorList = persisted.federationCoordinatorList
            federationCoordinatorPublicKeys = persisted.federationCoordinatorPublicKeys ?? ""
            coordinatorHeartbeatSeconds = persisted.coordinatorHeartbeatSeconds
            coordinatorDirectoryMaxStalenessSeconds = persisted.coordinatorDirectoryMaxStalenessSeconds ?? "300"
            curatedStrictPolicyEnabled = persisted.curatedStrictPolicyEnabled
            curatedCoordinatorQuorum = persisted.curatedCoordinatorQuorum
            curatedRequireSignedDirectory = persisted.curatedRequireSignedDirectory
            allowPrivateFederationEndpoints = persisted.allowPrivateFederationEndpoints ?? false
            openFederationDHTEnabled = persisted.openFederationDHTEnabled ?? false
            openFederationDHTMaxRecords = persisted.openFederationDHTMaxRecords ?? "256"
            openFederationDHTMaxRecordsPerHost = persisted.openFederationDHTMaxRecordsPerHost ?? "4"
            openFederationDHTMaxQueryRecords = persisted.openFederationDHTMaxQueryRecords ?? "256"
            relayPeerExchangeLimit = persisted.relayPeerExchangeLimit ?? "12"
            advertisedEndpoint = persisted.advertisedEndpoint
            federationSourceURL = persisted.federationSourceURL
            temporalBucketMinutes = persisted.temporalBucketMinutes
            temporalBucketScheduleMinutes = persisted.temporalBucketScheduleMinutes
            if let persistedMode = persisted.temporalBucketMode {
                temporalBucketMode = persistedMode
            } else {
                temporalBucketMode = parseBucketScheduleMinutes(temporalBucketScheduleMinutes).isEmpty ? .single : .multi
            }
            attachmentDefaultTTLMinutes = persisted.attachmentDefaultTTLMinutes
            attachmentMaxTTLMinutes = persisted.attachmentMaxTTLMinutes
            attachmentsEnabled = persisted.attachmentsEnabled ?? true
            attachmentStorageBackend = persisted.attachmentStorageBackend ?? .inline
            ipfsAPIEndpoint = persisted.ipfsAPIEndpoint ?? "http://127.0.0.1:5001"
            ipfsGatewayEndpoint = persisted.ipfsGatewayEndpoint ?? ""
            ipfsTimeoutSeconds = persisted.ipfsTimeoutSeconds ?? "10"
            hiddenRetrievalEnabled = persisted.hiddenRetrievalEnabled ?? false
            hiddenRetrievalMode = persisted.hiddenRetrievalMode ?? .coverQuery
            hiddenRetrievalCoverSize = persisted.hiddenRetrievalCoverSize ?? "8"
            hiddenRetrievalMaxCoverSize = persisted.hiddenRetrievalMaxCoverSize ?? "32"
            onionTransportEnabled = persisted.onionTransportEnabled ?? false
            onionTransportMaxHops = persisted.onionTransportMaxHops ?? "3"
            onionTransportRequiresFixedSizePackets = persisted.onionTransportRequiresFixedSizePackets ?? true
            mixnetTransportEnabled = persisted.mixnetTransportEnabled ?? false
            mixnetBatchIntervalSeconds = persisted.mixnetBatchIntervalSeconds ?? "30"
            mixnetMinBatchSize = persisted.mixnetMinBatchSize ?? "8"
            mixnetCoverPacketsPerBatch = persisted.mixnetCoverPacketsPerBatch ?? "2"
            mixnetMaxDelaySeconds = persisted.mixnetMaxDelaySeconds ?? "120"
            wakeModeEnabled = persisted.wakeModeEnabled ?? false
            wakeMode = persisted.wakeMode ?? .pullOnly
            wakeMinPollSeconds = persisted.wakeMinPollSeconds ?? "60"
            wakeMaxPollSeconds = persisted.wakeMaxPollSeconds ?? "300"
            wakeJitterPermille = persisted.wakeJitterPermille ?? "250"
            wakeLongPollTimeoutSeconds = persisted.wakeLongPollTimeoutSeconds ?? "60"
            relayName = persisted.relayName
            operatorNote = persisted.operatorNote
            groupCreationMode = persisted.groupCreationMode
            groupSecurityModel = persisted.groupSecurityModel ?? .relayBackedPairwise
            storageMode = persisted.storageMode
            storePath = persisted.storePath
            maxInboxMessages = persisted.maxInboxMessages ?? "1000"
            relayPassword = (try? RelaySecretStore.load(account: .relayPassword)) ?? ""
            relayPasswordConfirmation = relayPassword
            coordinatorRegistrationToken = (try? RelaySecretStore.load(account: .coordinatorRegistrationToken)) ?? ""
            federationForwardingAuthToken = (try? RelaySecretStore.load(account: .federationForwardingAuthToken)) ?? ""
            communicationMode = persisted.communicationMode
            transportSecurityMode = persisted.transportSecurityMode
            tlsIdentityPKCS12Path = persisted.tlsIdentityPKCS12Path
            tlsIdentityPassword = (try? RelaySecretStore.load(account: .tlsIdentityPassword)) ?? ""
            isApplyingPersistedSettings = false
        } catch {
            isApplyingPersistedSettings = false
            logs.append("Failed to load persisted settings: \(error.localizedDescription)")
            if logs.count > 200 {
                logs.removeFirst(logs.count - 200)
            }
        }
    }

    private struct PermissionProbeResult {
        let status: StartupPermissionStatus
        let message: String?
    }

    private static func probeLocalNetworkPermission(timeoutSeconds: TimeInterval = 4.0) async -> PermissionProbeResult {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "NoctyraRelay.LocalNetworkPermission")
            let descriptor = NWBrowser.Descriptor.bonjour(type: "_noctyra._tcp", domain: nil)
            let browser = NWBrowser(for: descriptor, using: .tcp)
            let gate = PermissionProbeGate()

            @Sendable func finish(_ result: PermissionProbeResult) {
                guard gate.claim() else { return }
                browser.cancel()
                continuation.resume(returning: result)
            }

            browser.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(
                        PermissionProbeResult(
                            status: .granted,
                            message: "Local network access is available."
                        )
                    )
                case .failed(let error):
                    finish(
                        PermissionProbeResult(
                            status: .failed,
                            message: "Local network probe failed: \(error.localizedDescription)"
                        )
                    )
                case .waiting(let error):
                    let status: StartupPermissionStatus
                    if case .posix(let code) = error, code == .EPERM {
                        status = .denied
                    } else {
                        status = .failed
                    }
                    finish(
                        PermissionProbeResult(
                            status: status,
                            message: "Local network waiting: \(error.localizedDescription)"
                        )
                    )
                case .cancelled:
                    break
                default:
                    break
                }
            }
            browser.browseResultsChangedHandler = { _, _ in
                // A result callback indicates browse permissions are functioning.
                finish(
                    PermissionProbeResult(
                        status: .granted,
                        message: "Local network access is available."
                    )
                )
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                finish(
                    PermissionProbeResult(
                        status: .failed,
                        message: "Local network permission probe timed out."
                    )
                )
            }
        }
    }

    private static func probeIncomingConnectionPermission(timeoutSeconds: TimeInterval = 3.0) async -> PermissionProbeResult {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "NoctyraRelay.IncomingPermission")
            let gate = PermissionProbeGate()
            let listener: NWListener
            do {
                listener = try NWListener(using: .tcp, on: .any)
            } catch {
                continuation.resume(
                    returning: PermissionProbeResult(
                        status: .failed,
                        message: "Incoming connection probe failed to start: \(error.localizedDescription)"
                    )
                )
                return
            }

            @Sendable func finish(_ result: PermissionProbeResult) {
                guard gate.claim() else { return }
                listener.cancel()
                continuation.resume(returning: result)
            }

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(
                        PermissionProbeResult(
                            status: .granted,
                            message: "Incoming listener access is available."
                        )
                    )
                case .failed(let error):
                    finish(
                        PermissionProbeResult(
                            status: .failed,
                            message: "Incoming listener probe failed: \(error.localizedDescription)"
                        )
                    )
                case .waiting(let error):
                    finish(
                        PermissionProbeResult(
                            status: .denied,
                            message: "Incoming listener waiting: \(error.localizedDescription)"
                        )
                    )
                case .cancelled:
                    break
                default:
                    break
                }
            }
            listener.newConnectionHandler = { connection in
                connection.cancel()
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeoutSeconds) {
                finish(
                    PermissionProbeResult(
                        status: .failed,
                        message: "Incoming listener permission probe timed out."
                    )
                )
            }
        }
    }
}
