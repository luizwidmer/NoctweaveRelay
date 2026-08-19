import Combine
import CryptoKit
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

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

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

    private static let maximumBlobBytes = 256 * 1024
    private static let maximumControlResponseBytes = 64 * 1024

    private let apiEndpoint: URL
    private let gatewayEndpoint: URL
    private let timeoutSeconds: TimeInterval

    init(apiEndpoint: URL, gatewayEndpoint: URL? = nil, timeoutSeconds: TimeInterval = 10) {
        self.apiEndpoint = apiEndpoint
        self.gatewayEndpoint = gatewayEndpoint ?? apiEndpoint
        self.timeoutSeconds = min(300, max(1, timeoutSeconds))
    }

    func put(_ data: Data, attachmentId: UUID, chunkIndex: Int, expiresAt: Date) throws -> AttachmentExternalRecord {
        guard !data.isEmpty, data.count <= Self.maximumBlobBytes else {
            throw AttachmentBlobStoreError.uploadFailed("Attachment chunk size is invalid")
        }
        let boundary = "noctweave-\(UUID().uuidString)"
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

        let responseData = try send(request, maximumBytes: Self.maximumControlResponseBytes)
        guard let cid = decodeCID(from: responseData), Self.isValidCID(cid) else {
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
        guard Self.isValidCID(record.locator),
              record.byteCount > 0,
              record.byteCount <= Self.maximumBlobBytes else {
            throw AttachmentBlobStoreError.fetchFailed("Attachment record is invalid")
        }
        let data = try fetch(locator: record.locator, maximumBytes: record.byteCount)
        guard data.count == record.byteCount,
              AttachmentBlobDigest.sha256Hex(data) == record.sha256Hex else {
            throw AttachmentBlobStoreError.digestMismatch
        }
        return data
    }

    func delete(_ record: AttachmentExternalRecord) {
        guard Self.isValidCID(record.locator) else { return }
        var request = URLRequest(url: apiURL(path: "/api/v0/pin/rm", queryItems: [
            URLQueryItem(name: "arg", value: record.locator)
        ]))
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        _ = try? send(request, maximumBytes: Self.maximumControlResponseBytes)
    }

    private func fetch(locator: String, maximumBytes: Int) throws -> Data {
        var catRequest = URLRequest(url: apiURL(path: "/api/v0/cat", queryItems: [
            URLQueryItem(name: "arg", value: locator)
        ]))
        catRequest.httpMethod = "POST"
        catRequest.timeoutInterval = timeoutSeconds
        if let data = try? send(catRequest, maximumBytes: maximumBytes) {
            return data
        }

        var gatewayURL = gatewayEndpoint
        gatewayURL.appendPathComponent("ipfs")
        gatewayURL.appendPathComponent(locator)
        var gatewayRequest = URLRequest(url: gatewayURL)
        gatewayRequest.timeoutInterval = timeoutSeconds
        return try send(gatewayRequest, maximumBytes: maximumBytes)
    }

    private func apiURL(path: String, queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents(url: apiEndpoint, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.queryItems = queryItems
        return components?.url ?? apiEndpoint
    }

    private func send(_ request: URLRequest, maximumBytes: Int) throws -> Data {
        let output = try RelayBoundedURLLoader.loadSynchronously(
            request,
            maximumBytes: maximumBytes,
            timeout: timeoutSeconds + 1
        )
        guard let response = output.response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw AttachmentBlobStoreError.fetchFailed("IPFS request was rejected")
        }
        return output.data
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

    private static func isValidCID(_ value: String) -> Bool {
        guard (20...128).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
    }
}

private final class RelayBoundedURLLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Output = (data: Data, response: URLResponse)

    private let maximumBytes: Int
    private let lock = NSLock()
    private var buffer = Data()
    private var response: URLResponse?
    private var completion: ((Result<Output, Error>) -> Void)?
    private var session: URLSession?
    private var isComplete = false

    private init(maximumBytes: Int) {
        self.maximumBytes = max(1, maximumBytes)
    }

    static func loadSynchronously(
        _ request: URLRequest,
        maximumBytes: Int,
        timeout: TimeInterval
    ) throws -> Output {
        let loader = RelayBoundedURLLoader(maximumBytes: maximumBytes)
        let semaphore = DispatchSemaphore(value: 0)
        let resultBox = RelaySynchronousResultBox<Output>()
        loader.start(request) { result in
            resultBox.set(result)
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + max(1, timeout)) == .success else {
            loader.cancel()
            throw AttachmentBlobStoreError.fetchFailed("IPFS request timed out")
        }
        guard let result = resultBox.get() else {
            throw AttachmentBlobStoreError.fetchFailed("IPFS response was unavailable")
        }
        return try result.get()
    }

    private func start(_ request: URLRequest, completion: @escaping (Result<Output, Error>) -> Void) {
        lock.lock()
        guard !isComplete else {
            lock.unlock()
            completion(.failure(CancellationError()))
            return
        }
        self.completion = completion
        lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        lock.lock()
        guard !isComplete else {
            lock.unlock()
            session.invalidateAndCancel()
            return
        }
        self.session = session
        lock.unlock()
        session.dataTask(with: request).resume()
    }

    private func cancel() {
        finish(.failure(CancellationError()))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if response.expectedContentLength > Int64(maximumBytes) {
            completionHandler(.cancel)
            finish(.failure(AttachmentBlobStoreError.fetchFailed("IPFS response exceeded its limit")))
            return
        }
        lock.lock()
        self.response = response
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard !isComplete else {
            lock.unlock()
            return
        }
        let exceedsLimit = data.count > maximumBytes - buffer.count
        if !exceedsLimit {
            buffer.append(data)
        }
        lock.unlock()
        if exceedsLimit {
            dataTask.cancel()
            finish(.failure(AttachmentBlobStoreError.fetchFailed("IPFS response exceeded its limit")))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
            return
        }
        lock.lock()
        let output = response.map { (buffer, $0) }
        lock.unlock()
        guard let output else {
            finish(.failure(AttachmentBlobStoreError.fetchFailed("IPFS response was unavailable")))
            return
        }
        finish(.success(output))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }

    private func finish(_ result: Result<Output, Error>) {
        lock.lock()
        guard !isComplete else {
            lock.unlock()
            return
        }
        isComplete = true
        let completion = self.completion
        self.completion = nil
        let session = self.session
        self.session = nil
        buffer.removeAll(keepingCapacity: false)
        lock.unlock()
        session?.invalidateAndCancel()
        completion?(result)
    }
}

private final class RelaySynchronousResultBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func set(_ result: Result<Value, Error>) {
        lock.lock()
        self.result = result
        lock.unlock()
    }

    func get() -> Result<Value, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return result
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
        case .storeDirectoryNotWritable:
            return "Store directory is not writable."
        case .storeFileNotWritable:
            return "Store file is not writable."
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
            return "IPFS attachment storage requires HTTPS, or HTTP on a strict loopback endpoint."
        case .invalidIPFSGatewayEndpoint:
            return "IPFS gateway endpoint requires HTTPS, or HTTP on a strict loopback endpoint."
        case .invalidIPFSTimeout:
            return "IPFS timeout must be at least 1 second."
        }
    }
}

enum StartupPermissionStatus: String {
    case idle
    case requesting
    case ready
    case denied
    case failed

    var displayTitle: String {
        switch self {
        case .idle:
            return "Not requested"
        case .requesting:
            return "Requesting"
        case .ready:
            return "Check passed"
        case .denied:
            return "Denied"
        case .failed:
            return "Failed"
        }
    }
}

enum FederatedRelayHealthStatus: Equatable {
    case idle
    case checking
    case healthy(latencyMs: Int, checkedAt: Date)
    case failed(message: String, checkedAt: Date)

    var title: String {
        switch self {
        case .idle:
            return "Not checked"
        case .checking:
            return "Checking..."
        case .healthy(let latencyMs, _):
            return "Healthy \(latencyMs) ms"
        case .failed:
            return "Unreachable"
        }
    }

    var detail: String? {
        switch self {
        case .idle, .checking:
            return nil
        case .healthy(_, let checkedAt):
            return "Checked \(Self.timeFormatter.string(from: checkedAt))"
        case .failed(let message, let checkedAt):
            return "\(message) · \(Self.timeFormatter.string(from: checkedAt))"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
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
        case tlsIdentityPassword = "tls-identity-password"
        case coordinatorDirectorySigningKey = "coordinator-directory-signing-key"
        case opaqueRouteSnapshotKey = "opaque-route-snapshot-key-v2"
        case relayIdentityKey = "relay-identity-key-v1"
        case pendingRelayIdentityKey = "relay-identity-key-pending-v1"
        case noctwebHostSigningKey = "noctweb-host-signing-key-v1"
        case turnSharedSecret = "turn-shared-secret-v1"
    }

    private static let service = "com.noctweave.relay.configuration"

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
        case tlsIdentityPassword
        case coordinatorDirectorySigningKey
        case opaqueRouteSnapshotKey
        case relayIdentityKey
        case pendingRelayIdentityKey
        case noctwebHostSigningKey
    }

    static func load(account: Account) throws -> String? { nil }
    static func save(_ value: String, account: Account) throws {}
}
#endif

actor RelayOpaqueRouteSnapshotVault {
    private struct Envelope: Codable {
        let version: Int
        let sealed: Data
    }

    private static let version = 1
    private static let maximumStoredBytes = 128 * 1024 * 1024
    private static let authenticatedData = Data("noctweave.relay.opaque-route-snapshot.v1\0".utf8)

    private let fileURL: URL
    private let key: SymmetricKey

    init(fileURL: URL, keyData: Data) throws {
        guard keyData.count == 32 else { throw CocoaError(.fileReadCorruptFile) }
        self.fileURL = fileURL.standardizedFileURL
        self.key = SymmetricKey(data: keyData)
    }

    func load() throws -> OpaqueRouteRelayStateSnapshotV2? {
        let encoded: Data
        do {
            encoded = try RelaySecureFileIO.read(
                from: fileURL,
                maximumBytes: Self.maximumStoredBytes
            )
        } catch RelaySecureFileIOError.notFound {
            return nil
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: encoded)
        guard envelope.version == Self.version,
              envelope.sealed.count <= Self.maximumStoredBytes,
              let box = try? AES.GCM.SealedBox(combined: envelope.sealed) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var plaintext = try AES.GCM.open(box, using: key, authenticating: Self.authenticatedData)
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        return try NoctweaveCoder.decode(OpaqueRouteRelayStateSnapshotV2.self, from: plaintext)
    }

    func save(_ snapshot: OpaqueRouteRelayStateSnapshotV2) throws {
        guard snapshot.isStructurallyValid else { throw CocoaError(.fileWriteInvalidFileName) }
        var plaintext = try NoctweaveCoder.encode(snapshot, sortedKeys: true)
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: Self.authenticatedData)
        guard let combined = sealed.combined else { throw CocoaError(.fileWriteUnknown) }
        let encoded = try JSONEncoder().encode(Envelope(version: Self.version, sealed: combined))
        guard encoded.count <= Self.maximumStoredBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        try RelaySecureFileIO.writePrivate(
            encoded,
            to: fileURL,
            maximumBytes: Self.maximumStoredBytes
        )
    }
}

nonisolated private struct PersistedNoctwebNamespaceLedger: Codable {
    let version: Int
    let records: [NoctwebNamespaceRecordV1]
}

private final class ServerViewModelWeakReference: @unchecked Sendable {
    weak var value: ServerViewModel?

    init(_ value: ServerViewModel) {
        self.value = value
    }
}

@MainActor
final class ServerViewModel: ObservableObject {
    private enum NoctwebLifecycleError: LocalizedError {
        case relayMustBeStopped
        case identityUnavailable
        case invalidSuffix
        case federatedSuffixRequired
        case hostingSuffixRequired
        case activeSuffixRequired(String)
        case multipleOwnedSuffixes
        case suffixAlreadyOwned
        case suffixTombstoned
        case noActiveSuffix
        case ownershipMismatch
        case sequenceExhausted
        case endpointUnavailable
        case capabilityUnavailable

        var errorDescription: String? {
            switch self {
            case .relayMustBeStopped:
                return "Stop the relay before changing its cryptographic identity or namespace."
            case .identityUnavailable:
                return "The persistent relay identity is unavailable."
            case .invalidSuffix:
                return "Enter a suffix such as .atelier using lowercase letters, numbers, or hyphens."
            case .federatedSuffixRequired:
                return "Federated relays require a permanent Noctweb suffix so peers can authenticate routing and namespace ownership."
            case .hostingSuffixRequired:
                return "Noctweb hosting requires a permanent relay suffix such as .atelier."
            case .activeSuffixRequired(let suffix):
                return "\(suffix) is already assigned to this relay. Release it explicitly before choosing another suffix."
            case .multipleOwnedSuffixes:
                return "This relay identity owns multiple active suffixes. Resolve the namespace ledger before starting."
            case .suffixAlreadyOwned:
                return "That suffix is already owned by another relay identity."
            case .suffixTombstoned:
                return "That suffix was permanently released and can never be registered again."
            case .noActiveSuffix:
                return "This relay does not have an active Noctweb suffix."
            case .ownershipMismatch:
                return "The persisted suffix is not owned by this relay identity."
            case .sequenceExhausted:
                return "The relay identity lifecycle sequence is exhausted."
            case .endpointUnavailable:
                return "Configure a valid listener or advertised endpoint before rotating this relay identity."
            case .capabilityUnavailable:
                return "The relay capability manifest could not be created."
            }
        }
    }

    @Published var host: String = "0.0.0.0"
    @Published var port: String = "9339"
    @Published var relayKind: RelayKind = .standard
    @Published var federationMode: FederationMode = .solo
    @Published var federationName: String = ""
    @Published var federationDescription: String = ""
    @Published var federationAllowList: String = ""
    @Published var manualFederationEndpointDraft: String = ""
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
    @Published var noctwebRelaySuffix: String = ""
    @Published var noctwebHostingEnabled: Bool = false
    @Published var noctwebDataEnabled: Bool = false
    @Published var noctwebDataDatabaseCreationEnabled: Bool = false
    @Published private(set) var claimedNoctwebSuffix: String?
    @Published private(set) var noctwebHostSigningPublicKey: Data?
    @Published private(set) var namespacePropagationStatus: String?
    @Published var federationSourceURL: String = ""
    @Published var federationSourceStatus: String?
    @Published var federationSourceLastUpdated: Date?
    @Published var temporalBucketMode: RelayTemporalBucketMode = .single
    @Published var temporalBucketMinutes: String = "5"
    @Published var temporalBucketScheduleMinutes: String = ""
    @Published var attachmentDefaultTTLMinutes: String = "60"
    @Published var attachmentMaxTTLMinutes: String = "360"
    @Published var attachmentsEnabled: Bool = true
    @Published var realtimeRoutesEnabled: Bool = true
    @Published var sharedLogsEnabled: Bool = true
    @Published var ephemeralPresenceEnabled: Bool = true
    @Published var mediaBlobsEnabled: Bool = true
    @Published var pairingLobbyEnabled: Bool = false
    @Published var rendezvousTransportEnabled: Bool = RelayRuntimePolicy.defaultRendezvousTransportEnabled
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
    @Published var iceServiceEnabled: Bool = false
    @Published var callTraversalDeploymentMode: CallTraversalDeploymentMode = .managed
    @Published var managedTurnHost: String = ""
    @Published var managedTurnExternalIPAddress: String = ""
    @Published var managedTurnListeningPort: String = "3478"
    @Published var managedTurnMinimumRelayPort: String = "49160"
    @Published var managedTurnMaximumRelayPort: String = "49200"
    @Published var iceURLs: String = ""
    @Published var turnRealm: String = "noctweave"
    @Published var turnCredentialLifetimeSeconds: String = "600"
    @Published var turnRelayOnlySupported: Bool = true
    @Published var turnSharedSecret: String = ""
    @Published private(set) var managedCoturnState: ManagedCoturnState = .stopped
    @Published var relayName: String = ""
    @Published var operatorNote: String = ""
    @Published var storageMode: RelayStorageMode = .disk
    @Published var storePath: String = ""
    @Published var relayPassword: String = ""
    @Published var relayPasswordConfirmation: String = ""
    @Published var coordinatorRegistrationToken: String = ""
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
    @Published var manualFederationHealth: [String: FederatedRelayHealthStatus] = [:]

    private let defaultStoreURL: URL
    private let settingsURL: URL
    private let namespaceLedgerURL: URL
    private var store: RelayStore
    private var server: RelayServer
    private var opaqueRouteStore = OpaqueRouteRelayStoreV2()
    private var opaqueRouteSnapshotVault: RelayOpaqueRouteSnapshotVault?
    private var relayIdentityKeyMaterial: RelayIdentityKeyMaterialV1?
    private var noctwebHostStore: RelayNoctwebHostStore?
    private var noctwebDataStore: RelayNoctwebDataStore?
    let softwareVersion: String
    private let defaultRelayPort: UInt16 = 9339
    private var settingsCancellables: Set<AnyCancellable> = []
    private var isApplyingPersistedSettings = false
    private var secretStoreFailure: String?

    var effectiveTLSEnabled: Bool {
        transportSecurityMode.advertisesTLS
    }

    var effectiveRendezvousTransportEnabled: Bool {
        RelayRuntimePolicy.effectiveRendezvousTransportEnabled(
            configured: rendezvousTransportEnabled,
            securityMode: transportSecurityMode
        )
    }

    var trustedProxyConfidentialitySignal: Bool {
        RelayRuntimePolicy.trustedProxyConfidentialitySignal(transportSecurityMode)
    }

    var callTraversalDescription: String {
        guard iceServiceEnabled else {
            return "No STUN or TURN service is advertised to call clients."
        }
        if callTraversalDeploymentMode == .managed {
            if managedCoturnState.isRunning {
                return "Managed coturn is running and short-lived call credentials are issued by this relay."
            }
            guard configuredICEServiceDescriptor() != nil else {
                return "Choose a reachable address so the app can finish managed call setup."
            }
            return "Managed coturn will start automatically with the relay."
        }
        guard let descriptor = configuredICEServiceDescriptor() else {
            return "Complete the external STUN/TURN configuration before starting the relay."
        }
        if descriptor.credentialMode == .turnREST {
            return "Advertises nw.ice-service@1 and issues short-lived credentials for an external coturn service."
        }
        return "Advertises credential-free STUN connectivity through nw.ice-service@1."
    }

    var turnCredentialRequired: Bool {
        if iceServiceEnabled, callTraversalDeploymentMode == .managed {
            return true
        }
        return parsedICEURLs().contains {
            $0.hasPrefix("turn:") || $0.hasPrefix("turns:")
        }
    }

    var managedTurnReachabilityDescription: String {
        let candidate = managedTurnHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            return "A local address will be detected automatically."
        }
        if Self.isLikelyPrivateAddress(candidate) {
            return "Ready for local-network calls. Internet calls still require router forwarding for the displayed ports."
        }
        return "Public address configured. The app will manage coturn; the listed ports must reach this Mac."
    }

    var managedTurnAdvertisedHostDescription: String {
        let candidate = managedTurnHost.trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? "Detected automatically" : candidate
    }

    func setCallTraversalEnabled(_ enabled: Bool) {
        guard !isRunning else { return }
        iceServiceEnabled = enabled
        guard enabled, callTraversalDeploymentMode == .managed else { return }
        do {
            try prepareManagedCoturnConfiguration()
            lastError = nil
        } catch {
            iceServiceEnabled = false
            lastError = error.localizedDescription
        }
    }

    func setCallTraversalDeploymentMode(_ mode: CallTraversalDeploymentMode) {
        guard !isRunning else { return }
        callTraversalDeploymentMode = mode
        guard iceServiceEnabled, mode == .managed else { return }
        do {
            try prepareManagedCoturnConfiguration()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    var noctCordServicesEnabled: Bool {
        realtimeRoutesEnabled
            || sharedLogsEnabled
            || ephemeralPresenceEnabled
            || mediaBlobsEnabled
            || pairingLobbyEnabled
    }

    var noctCordImmediateDeliveryEnabled: Bool {
        temporalBucketMode == .disabled
    }

    var noctCordTransportReady: Bool {
        if transportSecurityMode.advertisesTLS { return true }
        let normalizedHost = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return ["127.0.0.1", "::1", "localhost"].contains(normalizedHost)
    }

    var noctCordReadinessIssues: [String] {
        guard noctCordServicesEnabled else { return [] }
        var issues: [String] = []
        if relayKind != .standard {
            issues.append("Use the Standard relay kind.")
        }
        if !noctCordImmediateDeliveryEnabled {
            issues.append("Disable temporal bucketing for immediate community delivery.")
        }
        if !realtimeRoutesEnabled {
            issues.append("Enable realtime signaling routes.")
        }
        if !noctCordTransportReady {
            issues.append("Configure relay TLS or trusted proxy TLS for remote clients.")
        }
        return issues
    }

    var noctCordServiceTier: String {
        guard noctCordServicesEnabled else { return "Disabled" }
        guard noctCordReadinessIssues.isEmpty else { return "Needs setup" }
        return sharedLogsEnabled ? "Durable community" : "Realtime MVP"
    }

    var noctCordServiceDescription: String {
        if !noctCordServicesEnabled {
            return "No application-neutral community services are advertised."
        }
        if let firstIssue = noctCordReadinessIssues.first {
            return firstIssue
        }
        if sharedLogsEnabled {
            return "Immediate encrypted community delivery and durable opaque logs are advertised."
        }
        return "Immediate encrypted signaling is ready; durable shared logs are disabled."
    }

    func setNoctCordServicesEnabled(_ enabled: Bool) {
        guard !isRunning else { return }
        realtimeRoutesEnabled = enabled
        sharedLogsEnabled = enabled
        ephemeralPresenceEnabled = enabled
        mediaBlobsEnabled = enabled
        if !enabled { pairingLobbyEnabled = false }
    }

    func setNoctCordImmediateDelivery(_ enabled: Bool) {
        guard !isRunning else { return }
        temporalBucketMode = enabled ? .disabled : .single
    }

    func setPairingLobbyEnabled(_ enabled: Bool) {
        guard !isRunning else { return }
        pairingLobbyEnabled = enabled
        if enabled {
            realtimeRoutesEnabled = true
            rendezvousTransportEnabled = true
        }
    }

    func applyNoctCordRecommendedProfile() {
        guard !isRunning else { return }
        relayKind = .standard
        temporalBucketMode = .disabled
        realtimeRoutesEnabled = true
        sharedLogsEnabled = true
        ephemeralPresenceEnabled = true
        mediaBlobsEnabled = true
        attachmentsEnabled = true
    }

    func applyPrivateMessagingRecommendedProfile() {
        guard !isRunning else { return }
        relayKind = .standard
        federationMode = .solo
        temporalBucketMode = .single
        temporalBucketMinutes = "5"
        attachmentsEnabled = true
        rendezvousTransportEnabled = RelayRuntimePolicy.defaultRendezvousTransportEnabled
        realtimeRoutesEnabled = false
        sharedLogsEnabled = false
        ephemeralPresenceEnabled = false
        mediaBlobsEnabled = false
        pairingLobbyEnabled = false
        hiddenRetrievalEnabled = false
        onionTransportEnabled = false
        mixnetTransportEnabled = false
    }

    func applyRealtimeCommunityRecommendedProfile() {
        guard !isRunning else { return }
        federationMode = .solo
        applyNoctCordRecommendedProfile()
    }

    var permissionPreflightReady: Bool {
        permissionProbeHasRun
    }

    var relayIdentityID: String {
        relayIdentityKeyMaterial?.relayID.rawValue ?? "Unavailable"
    }

    var effectiveNoctwebHostingEnabled: Bool {
        relayKind == .host || noctwebHostingEnabled
    }

    var effectiveNoctwebDataEnabled: Bool {
        effectiveNoctwebHostingEnabled && noctwebDataEnabled
    }

    var effectiveNoctwebDataDatabaseCreationEnabled: Bool {
        effectiveNoctwebDataEnabled && noctwebDataDatabaseCreationEnabled
    }

    var noctwebHostSigningIdentity: String {
        guard let noctwebHostSigningPublicKey else {
            return effectiveNoctwebHostingEnabled
                ? "Created securely when the relay starts"
                : "Not configured"
        }
        return noctwebHostSigningPublicKey.base64EncodedString()
    }

    var noctwebHostStorageDescription: String {
        guard effectiveNoctwebHostingEnabled else {
            return "No Noctweb objects are accepted."
        }
        guard let storeURL = resolvedStoreURL() else {
            return "RAM only · cleared when the relay stops."
        }
        return noctwebHostDirectoryURL(for: storeURL).path
    }

    var noctwebDataStorageDescription: String {
        guard effectiveNoctwebDataEnabled else {
            return "Site data collections are disabled."
        }
        guard let storeURL = resolvedStoreURL() else {
            return "RAM only · cleared when the relay stops."
        }
        return "SQLite · \(storeURL.path)"
    }

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoctweaveRelay", isDirectory: true)
        let storeURL = directory.appendingPathComponent("relay_store.sqlite")
        self.defaultStoreURL = storeURL
        self.settingsURL = directory.appendingPathComponent("relay_settings.json")
        self.namespaceLedgerURL = directory.appendingPathComponent(
            "noctweb_namespace_v1.json"
        )
        self.storePath = storeURL.path
        self.softwareVersion = Self.makeSoftwareVersion()
        do {
            self.relayIdentityKeyMaterial = try Self.loadOrCreateRelayIdentity(
                namespaceLedgerURL: namespaceLedgerURL
            )
        } catch {
            self.relayIdentityKeyMaterial = nil
            self.secretStoreFailure =
                "The persistent relay identity could not be loaded from Keychain."
        }
        let bootstrapConfiguration = RelayConfiguration()
        self.store = RelayStore(
            storeURL: storeURL,
            temporalBucketSeconds: bootstrapConfiguration.temporalBucketSeconds,
            temporalBucketScheduleSeconds: bootstrapConfiguration.temporalBucketScheduleSeconds,
            attachmentBlobStore: nil
        )
        self.server = RelayServer(
            store: store,
            configuration: bootstrapConfiguration,
            relayIdentity: relayIdentityKeyMaterial
        )
        server.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event: event)
            }
        }
        ManagedCoturnService.shared.$state
            .sink { [weak self] state in
                self?.managedCoturnState = state
            }
            .store(in: &settingsCancellables)
        configureNamespacePersistence(on: server)
        loadPersistedSettingsIfAvailable()
        refreshClaimedNoctwebSuffixFromDisk()
        rebuildRuntimeWithCurrentSettings()
        bindSettingsPersistence()
        persistSettings()
    }

    func start() {
        guard secretStoreFailure == nil else {
            lastError = "Saved relay secrets could not be read from Keychain. Restart after restoring Keychain access; the relay will not start with empty credentials."
            return
        }
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
            guard trimmedPassword == relayPassword,
                  (12...4_096).contains(trimmedPassword.utf8.count) else {
                lastError = "Relay password must contain 12 to 4096 UTF-8 bytes without surrounding whitespace."
                return
            }
            guard trimmedPassword == relayPasswordConfirmation else {
                lastError = "Relay password confirmation does not match."
                return
            }
        }
        if effectiveNoctwebDataDatabaseCreationEnabled,
           trimmedPassword.isEmpty {
            lastError = "Noctweb database creation requires a relay password and is disabled by default."
            return
        }
        let trimmedTLSPath = tlsIdentityPKCS12Path.trimmingCharacters(in: .whitespacesAndNewlines)
        if transportSecurityMode.usesRelayTLS {
            guard !trimmedTLSPath.isEmpty else {
                lastError = "Relay TLS is enabled. Choose a PKCS#12 certificate identity (.p12/.pfx)."
                return
            }
            let expandedPath = (trimmedTLSPath as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expandedPath) else {
                lastError = "TLS certificate file was not found."
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
        do {
            try prepareNoctwebSuffixForStart()
        } catch {
            lastError = error.localizedDescription
            return
        }
        let resolvedStoreURL: URL?
        do {
            resolvedStoreURL = try validatedStoreURL()
        } catch {
            lastError = redactedRelayAppError(error, fallback: "Relay storage path is not usable.")
            return
        }
        let managedCoturnConfiguration: ManagedCoturnConfiguration?
        do {
            if iceServiceEnabled, callTraversalDeploymentMode == .managed {
                try prepareManagedCoturnConfiguration()
                managedCoturnConfiguration = try makeManagedCoturnConfiguration()
            } else {
                managedCoturnConfiguration = nil
            }
        } catch {
            lastError = error.localizedDescription
            return
        }
        let configuration = buildConfiguration()
        if effectiveNoctwebHostingEnabled,
           relayKind != .standard,
           relayKind != .host {
            lastError = "Noctweb hosting is available on standard or host relays."
            return
        }
        if federationMode == .manual {
            guard relayKind == .standard else {
                lastError = "Manual federation uses standard relays only. Set Relay Kind to Standard."
                return
            }
        }
        if federationMode == .curated,
           !(16...4_096).contains(
                coordinatorRegistrationToken
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .utf8.count
           ) {
            lastError = "Curated federation requires a coordinator registration token of at least 16 bytes."
            return
        }
        if iceServiceEnabled {
            guard relayKind == .standard else {
                lastError = "Call traversal can be advertised only by a standard relay."
                return
            }
            guard let descriptor = configuredICEServiceDescriptor(),
                  descriptor.isStructurallyValid else {
                lastError = "Enter valid, unique STUN/TURN URLs and a TURN lifetime from 60 to 3600 seconds."
                return
            }
            if descriptor.credentialMode == .turnREST,
               makeCoturnCredentialIssuer() == nil {
                lastError = "TURN requires a 16 to 4096 byte shared secret without surrounding whitespace. Use the same secret in coturn."
                return
            }
        }
        let attachmentBlobStore: AttachmentBlobStore?
        do {
            attachmentBlobStore = try makeAttachmentBlobStore()
        } catch {
            lastError = redactedRelayAppError(error, fallback: "Attachment storage configuration is not usable.")
            return
        }
        let snapshotVault: RelayOpaqueRouteSnapshotVault?
        do {
            snapshotVault = try makeOpaqueRouteSnapshotVault(storeURL: resolvedStoreURL)
        } catch {
            lastError = redactedRelayAppError(error, fallback: "Opaque-route storage protection is unavailable.")
            return
        }
        let runtimeNoctwebHostStore: RelayNoctwebHostStore?
        do {
            runtimeNoctwebHostStore = try makeNoctwebHostStore(
                storeURL: resolvedStoreURL
            )
        } catch {
            lastError = redactedRelayAppError(
                error,
                fallback:
                    "Noctweb host storage or its signing identity is unavailable."
            )
            return
        }
        noctwebHostStore = runtimeNoctwebHostStore
        noctwebHostSigningPublicKey =
            runtimeNoctwebHostStore?.signingPublicKey
        let runtimeNoctwebDataStore: RelayNoctwebDataStore?
        do {
            runtimeNoctwebDataStore = try makeNoctwebDataStore(
                storeURL: resolvedStoreURL
            )
        } catch {
            lastError = redactedRelayAppError(
                error,
                fallback: "Noctweb site data storage is unavailable."
            )
            return
        }
        noctwebDataStore = runtimeNoctwebDataStore
        let runtimeOpaqueRouteStore = OpaqueRouteRelayStoreV2()
        opaqueRouteStore = runtimeOpaqueRouteStore
        opaqueRouteSnapshotVault = snapshotVault
        store = RelayStore(
            storeURL: resolvedStoreURL,
            temporalBucketSeconds: configuration.temporalBucketSeconds,
            temporalBucketScheduleSeconds: configuration.temporalBucketScheduleSeconds,
            attachmentBlobStore: attachmentBlobStore
        )
        server = RelayServer(
            store: store,
            opaqueRouteStore: runtimeOpaqueRouteStore,
            configuration: configuration,
            relayIdentity: relayIdentityKeyMaterial,
            noctwebHostStore: runtimeNoctwebHostStore,
            noctwebDataStore: runtimeNoctwebDataStore,
            coturnCredentialIssuer: makeCoturnCredentialIssuer()
        )
        configureNamespacePersistence(on: server)
        if let snapshotVault {
            server.onOpaqueRouteStateSnapshot = { snapshot in
                try await snapshotVault.save(snapshot)
            }
        }
        server.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event: event)
            }
        }
        Task {
            do {
                if let managedCoturnConfiguration {
                    try await ManagedCoturnService.shared.start(
                        configuration: managedCoturnConfiguration
                    )
                }
                if resolvedStoreURL != nil {
                    try await store.loadFromDisk()
                }
                // The primary relay schema must own creation of the shared
                // SQLite file before feature tables are opened.
                try runtimeNoctwebDataStore?.load()
                if let snapshot = try await snapshotVault?.load() {
                    try await runtimeOpaqueRouteStore.restore(snapshot)
                }
                if let namespaceRecords = try Self.loadNamespaceRecords(
                    from: namespaceLedgerURL
                ) {
                    try await server.restoreNoctwebNamespaceRecords(
                        namespaceRecords
                    )
                }
                try server.start(host: trimmedHost, port: portValue)
                isRunning = true
            } catch {
                if managedCoturnConfiguration != nil {
                    ManagedCoturnService.shared.stop()
                }
                lastError = "Failed to start server: \(redactedRelayAppError(error, fallback: "Server startup failed."))"
            }
        }
    }

    func stop() {
        let stoppingServer = server
        let snapshotVault = opaqueRouteSnapshotVault
        Task {
            do {
                if let snapshotVault {
                    try await snapshotVault.save(try await stoppingServer.opaqueRouteStateSnapshot())
                }
                try Self.saveNamespaceRecords(
                    await stoppingServer.noctwebNamespaceRecords(),
                    to: namespaceLedgerURL
                )
            } catch {
                appendRedactedLog(
                    "Failed to persist opaque-route state during shutdown",
                    error: error,
                    fallback: "Opaque-route state could not be saved."
                )
            }
            stoppingServer.stop()
            ManagedCoturnService.shared.stop()
            isRunning = false
        }
    }

    func rotateRelayIdentity() {
        guard !isRunning else {
            lastError = NoctwebLifecycleError.relayMustBeStopped.localizedDescription
            return
        }
        guard let oldIdentity = relayIdentityKeyMaterial else {
            lastError = NoctwebLifecycleError.identityUnavailable.localizedDescription
            return
        }
        do {
            let originalRecords = try Self.loadNamespaceRecords(
                from: namespaceLedgerURL
            ) ?? []
            let owned = activeNamespaceRecords(
                in: originalRecords,
                identity: oldIdentity
            )
            guard owned.count <= 1 else {
                throw NoctwebLifecycleError.multipleOwnedSuffixes
            }

            let newIdentity = try RelayIdentityKeyMaterialV1.generate()
            var propagationRequest: RelayRequest?
            if let active = owned.first {
                guard active.ownershipSequence
                        < RelayIdentityV1.maximumSequence else {
                    throw NoctwebLifecycleError.sequenceExhausted
                }
                noctwebRelaySuffix = active.suffix.rawValue
                let sequence = active.ownershipSequence + 1
                let issuedAt = Date()
                let rotation = try RelayIdentityRotationV1.signed(
                    from: oldIdentity,
                    to: newIdentity,
                    sequence: sequence,
                    issuedAt: issuedAt
                )
                let claim = try makeRelayIdentityClaim(
                    using: newIdentity,
                    suffix: active.suffix,
                    sequence: sequence,
                    issuedAt: rotation.issuedAt
                )
                var ledger = try NoctwebNamespaceLedgerV1(
                    records: originalRecords
                )
                try ledger.rotate(
                    rotation,
                    to: claim,
                    now: rotation.issuedAt
                )

                try Self.saveRelayIdentity(
                    newIdentity,
                    account: .pendingRelayIdentityKey
                )
                do {
                    try Self.saveNamespaceRecords(
                        ledger.records,
                        to: namespaceLedgerURL
                    )
                } catch {
                    try? RelaySecretStore.save(
                        "",
                        account: .pendingRelayIdentityKey
                    )
                    throw error
                }
                try Self.saveRelayIdentity(
                    newIdentity,
                    account: .relayIdentityKey
                )
                try RelaySecretStore.save(
                    "",
                    account: .pendingRelayIdentityKey
                )
                propagationRequest = .rotateNoctwebNamespaceV1(
                    NoctwebNamespaceRotationRequestV1(
                        rotation: rotation,
                        newIdentity: claim
                    )
                )
            } else {
                try Self.saveRelayIdentity(
                    newIdentity,
                    account: .relayIdentityKey
                )
            }

            relayIdentityKeyMaterial = newIdentity
            refreshClaimedNoctwebSuffixFromDisk()
            rebuildRuntimeWithCurrentSettings()
            persistSettings()
            appendLog(
                "Relay identity rotated to \(newIdentity.relayID.rawValue)."
            )
            if let propagationRequest {
                propagateNoctwebLifecycleRequest(propagationRequest)
            }
        } catch {
            lastError =
                "Relay identity rotation failed: \(error.localizedDescription)"
        }
    }

    func releaseNoctwebSuffix() {
        guard !isRunning else {
            lastError = NoctwebLifecycleError.relayMustBeStopped.localizedDescription
            return
        }
        guard let identity = relayIdentityKeyMaterial else {
            lastError = NoctwebLifecycleError.identityUnavailable.localizedDescription
            return
        }
        do {
            let records = try Self.loadNamespaceRecords(
                from: namespaceLedgerURL
            ) ?? []
            let owned = activeNamespaceRecords(
                in: records,
                identity: identity
            )
            guard owned.count <= 1 else {
                throw NoctwebLifecycleError.multipleOwnedSuffixes
            }
            guard let active = owned.first else {
                throw NoctwebLifecycleError.noActiveSuffix
            }
            guard active.ownerRelayID == identity.relayID else {
                throw NoctwebLifecycleError.ownershipMismatch
            }
            guard active.ownershipSequence
                    < RelayIdentityV1.maximumSequence else {
                throw NoctwebLifecycleError.sequenceExhausted
            }
            let release = try NoctwebNamespaceReleaseV1.signed(
                suffix: active.suffix,
                owner: identity,
                sequence: active.ownershipSequence + 1
            )
            var ledger = try NoctwebNamespaceLedgerV1(records: records)
            try ledger.release(release, now: release.issuedAt)
            try Self.saveNamespaceRecords(
                ledger.records,
                to: namespaceLedgerURL
            )
            noctwebRelaySuffix = ""
            claimedNoctwebSuffix = nil
            rebuildRuntimeWithCurrentSettings()
            persistSettings()
            appendLog(
                "Permanently released and tombstoned \(active.suffix.rawValue)."
            )
            propagateNoctwebLifecycleRequest(
                .releaseNoctwebNamespaceV1(release)
            )
        } catch {
            lastError =
                "Noctweb suffix release failed: \(error.localizedDescription)"
        }
    }

    private func propagateNoctwebLifecycleRequest(
        _ request: RelayRequest
    ) {
        let configuration = buildConfiguration()
        let candidates =
            configuration.federationAllowList
                + (configuration.federationCoordinatorEndpoints ?? [])
        let ownEndpointKey = configuration.advertisedEndpoint.map {
            "\($0.host.lowercased()):\($0.port):\($0.useTLS):\($0.transport.rawValue)"
        }
        var seen = Set<String>()
        let endpoints = candidates.filter { endpoint in
            let key =
                "\(endpoint.host.lowercased()):\(endpoint.port):\(endpoint.useTLS):\(endpoint.transport.rawValue)"
            return key != ownEndpointKey && seen.insert(key).inserted
        }
        guard !endpoints.isEmpty else {
            namespacePropagationStatus =
                configuration.federation.mode == .solo
                    ? "Local namespace updated."
                    : "Namespace update retained locally; no configured federation peer was available."
            return
        }
        namespacePropagationStatus =
            "Propagating namespace update to \(endpoints.count) peer(s)…"
        Task {
            var accepted = 0
            for endpoint in endpoints {
                do {
                    let response = try await RelayClient(
                        endpoint: endpoint
                    ).send(request)
                    if response.status == .success {
                        accepted += 1
                    }
                } catch {
                    continue
                }
            }
            await MainActor.run {
                namespacePropagationStatus =
                    "Namespace update accepted by \(accepted) of \(endpoints.count) configured peer(s)."
                if accepted < endpoints.count {
                    appendLog(
                        "Namespace propagation remains pending on \(endpoints.count - accepted) peer(s)."
                    )
                }
            }
        }
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
            appendLog("Server started on \(host):\(port)")
        case .stopped:
            appendLog("Server stopped")
        case .error(let message):
            appendLog("Error: \(redactedRelayMessage(message, fallback: "Relay operation failed."))")
        }
    }

    private func appendLog(_ message: String) {
        logs.append(message)
        if logs.count > 200 {
            logs.removeFirst(logs.count - 200)
        }
    }

    private func appendRedactedLog(_ prefix: String, error: Error, fallback: String) {
        appendLog("\(prefix): \(redactedRelayAppError(error, fallback: fallback))")
    }

    private func redactedRelayAppError(_ error: Error, fallback: String) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "Request timed out."
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return "Network connection failed."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired:
                return "TLS validation failed."
            case .appTransportSecurityRequiresSecureConnection:
                return "Transport is blocked by App Transport Security."
            default:
                return "Network request failed."
            }
        }
        if let nwError = error as? NWError {
            return Self.redactedNetworkError(nwError)
        }
        let description = error.localizedDescription
        return redactedRelayMessage(description, fallback: fallback)
    }

    private func redactedRelayMessage(_ message: String, fallback: String) -> String {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = normalized.lowercased()
        guard !normalized.isEmpty else {
            return fallback
        }
        if lowercased.hasPrefix("relay returned http ") {
            return normalized
        }
        if lowercased.contains("timed out") {
            return "Request timed out."
        }
        if lowercased.contains("tls") || lowercased.contains("certificate") {
            return "TLS validation failed."
        }
        if lowercased.contains("permission") || lowercased.contains("operation not permitted") || lowercased.contains("eperm") {
            return "Permission denied."
        }
        if lowercased.contains("auth") || lowercased.contains("token") || lowercased.contains("proof") || lowercased.contains("signature") || lowercased.contains("unauthorized") || lowercased.contains("forbidden") {
            return "Authentication was rejected."
        }
        if lowercased.contains("rate") && lowercased.contains("limit") {
            return "Rate limit reached."
        }
        if lowercased.contains("policy") || lowercased.contains("not allowed") || lowercased.contains("disabled") {
            return "Policy rejected the request."
        }
        if lowercased.contains("not found") || lowercased.contains("missing") {
            return "Requested item was not found."
        }
        if lowercased.contains("invalid") || lowercased.contains("malformed") || lowercased.contains("bad request") {
            return "Invalid request or response."
        }
        return fallback
    }

    nonisolated private static func redactedNetworkError(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            if code == .EPERM || code == .EACCES {
                return "Permission denied."
            }
            if code == .ECONNREFUSED || code == .ECONNRESET || code == .ENETDOWN || code == .ENETUNREACH || code == .EHOSTUNREACH {
                return "Network connection failed."
            }
            return "Network operation failed."
        case .tls:
            return "TLS validation failed."
        case .dns:
            return "DNS resolution failed."
        case .wifiAware:
            return "Network operation failed."
        @unknown default:
            return "Network operation failed."
        }
    }

    nonisolated private static func redactedPermissionProbeError(_ error: Error) -> String {
        if let nwError = error as? NWError {
            return redactedNetworkError(nwError)
        }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                return "Permission probe timed out."
            case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
                return "Network connection failed."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired:
                return "TLS validation failed."
            default:
                return "Permission probe failed."
            }
        }
        return "Permission probe failed."
    }

    private func buildConfiguration() -> RelayConfiguration {
        let trimmedName = federationName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDescription = federationDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRelayName = relayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = operatorNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = relayPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        let registrationToken = coordinatorRegistrationToken.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let iceService = configuredICEServiceDescriptor()
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
        let openFederationFeaturesEnabled = federationMode == .open
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
            iceService: iceService,
            realtimeRoutesEnabled: realtimeRoutesEnabled,
            sharedLogsEnabled: sharedLogsEnabled,
            ephemeralPresenceEnabled: ephemeralPresenceEnabled,
            mediaBlobsEnabled: mediaBlobsEnabled,
            pairingLobbyEnabled: pairingLobbyEnabled,
            relayName: trimmedRelayName.isEmpty ? nil : trimmedRelayName,
            operatorNote: note.isEmpty ? nil : note,
            softwareVersion: softwareVersion,
            accessPassword: password.isEmpty ? nil : password,
            coordinatorRegistrationToken: registrationToken.isEmpty ? nil : registrationToken,
            tlsEnabled: transportSecurityMode.usesRelayTLS,
            advertisedTLSEnabled: trustedProxyConfidentialitySignal ? true : nil,
            trustedReverseProxyTLS: trustedProxyConfidentialitySignal,
            transport: communicationMode.relayTransport,
            tlsIdentityPKCS12Path: transportSecurityMode.usesRelayTLS && !tlsPath.isEmpty ? tlsPath : nil,
            tlsIdentityPassword: transportSecurityMode.usesRelayTLS && !tlsPassword.isEmpty ? tlsPassword : nil,
            federationCoordinatorEndpoints: coordinators.isEmpty ? nil : coordinators,
            coordinatorHeartbeatSeconds: heartbeatSeconds,
            coordinatorDirectoryMaxStalenessSeconds: directoryMaxStalenessSeconds,
            relayPeerExchangeLimit: openFederationFeaturesEnabled ? max(0, Int(relayPeerExchangeLimit) ?? 12) : 0,
            openFederationDHTEnabled: openFederationFeaturesEnabled ? openFederationDHTEnabled : false,
            openFederationDHTMaxRecords: max(1, Int(openFederationDHTMaxRecords) ?? 256),
            openFederationDHTMaxRecordsPerHost: max(1, Int(openFederationDHTMaxRecordsPerHost) ?? 4),
            openFederationDHTMaxQueryRecords: max(1, Int(openFederationDHTMaxQueryRecords) ?? 256),
            coordinatorDirectorySigningPrivateKey: coordinatorDirectorySigningKey(),
            curatedStrictPolicyEnabled: curatedStrictPolicyEnabled,
            curatedCoordinatorQuorum: curatedQuorum,
            curatedRequireSignedDirectory: curatedRequireSignedDirectory,
            advertisedEndpoint: advertisedRelayEndpoint,
            noctwebRelaySuffix: configuredNoctwebSuffix(),
            netHostEnabled: effectiveNoctwebHostingEnabled,
            noctwebDataEnabled: effectiveNoctwebDataEnabled,
            noctwebDataDatabaseCreationEnabled:
                effectiveNoctwebDataDatabaseCreationEnabled,
            federationAllowList: allowList,
            allowPrivateFederationEndpoints: allowPrivateFederationEndpoints,
            rendezvousTransportEnabled: effectiveRendezvousTransportEnabled
        )
    }

    private func coordinatorDirectorySigningKey() -> Data? {
        guard relayKind == .coordinator else {
            return nil
        }
        if let encoded = try? RelaySecretStore.load(account: .coordinatorDirectorySigningKey),
           let existing = Data(base64Encoded: encoded),
           let validated = try? FederationDirectorySignature.privateKeyDataThrowing(from: existing) {
            return validated
        }
        do {
            let generated = try FederationDirectorySignature.privateKeyDataThrowing(from: nil)
            try RelaySecretStore.save(
                generated.base64EncodedString(),
                account: .coordinatorDirectorySigningKey
            )
            return generated
        } catch {
            appendRedactedLog(
                "Failed to create or persist coordinator signing key",
                error: error,
                fallback: "Secret storage is unavailable."
            )
            return nil
        }
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

    private func makeOpaqueRouteSnapshotVault(
        storeURL: URL?
    ) throws -> RelayOpaqueRouteSnapshotVault? {
        guard let storeURL else { return nil }
        let keyData: Data
        if let encoded = try RelaySecretStore.load(account: .opaqueRouteSnapshotKey),
           let existing = Data(base64Encoded: encoded),
           existing.count == 32 {
            keyData = existing
        } else {
            let key = SymmetricKey(size: .bits256)
            let generated = key.withUnsafeBytes { Data($0) }
            try RelaySecretStore.save(
                generated.base64EncodedString(),
                account: .opaqueRouteSnapshotKey
            )
            keyData = generated
        }
        let snapshotURL = storeURL
            .deletingPathExtension()
            .appendingPathExtension("opaque-routes.nwstate")
        return try RelayOpaqueRouteSnapshotVault(fileURL: snapshotURL, keyData: keyData)
    }

    private func makeNoctwebHostStore(
        storeURL: URL?
    ) throws -> RelayNoctwebHostStore? {
        guard effectiveNoctwebHostingEnabled else {
            return nil
        }
        let keyData: Data
        if let encoded = try RelaySecretStore.load(
            account: .noctwebHostSigningKey
        ),
        let existing = Data(base64Encoded: encoded),
        existing.count == 32 {
            keyData = existing
        } else {
            let generated =
                RelayNoctwebHostStore.generateSigningPrivateKey()
            try RelaySecretStore.save(
                generated.base64EncodedString(),
                account: .noctwebHostSigningKey
            )
            keyData = generated
        }
        let hostStore = try RelayNoctwebHostStore(
            directoryURL: storeURL.map(noctwebHostDirectoryURL(for:)),
            signingPrivateKeyData: keyData
        )
        try hostStore.load()
        return hostStore
    }

    private func makeNoctwebDataStore(
        storeURL: URL?
    ) throws -> RelayNoctwebDataStore? {
        guard effectiveNoctwebDataEnabled else {
            return nil
        }
        let dataStore = RelayNoctwebDataStore(fileURL: storeURL)
        return dataStore
    }

    private func noctwebHostDirectoryURL(
        for storeURL: URL
    ) -> URL {
        let baseName = storeURL
            .deletingPathExtension()
            .lastPathComponent
        return storeURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "\(baseName)-noctweb-host",
                isDirectory: true
            )
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
              (1...300).contains(timeoutSeconds) else {
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
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
              components.port != 0,
              scheme == "https" || Self.isStrictLoopbackHost(components.host ?? ""),
              let url = components.url else {
            return nil
        }
        return url
    }

    nonisolated private static func isStrictLoopbackHost(_ value: String) -> Bool {
        var host = value.lowercased()
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        if host.hasSuffix(".") { host.removeLast() }
        if host == "localhost" || host == "::1" { return true }
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4,
              let first = UInt8(octets[0]),
              first == 127 else {
            return false
        }
        return octets.dropFirst().allSatisfy { UInt8($0) != nil }
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

    var manualFederationNodes: [String] {
        splitFederationEndpointList(federationAllowList)
    }

    var canAddManualFederationNode: Bool {
        !manualFederationEndpointDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func addManualFederationNode() {
        let trimmed = manualFederationEndpointDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard parseEndpoint(trimmed) != nil else {
            lastError = "Enter a valid relay endpoint, for example relay.example.org:9339, tls://relay.example.org:9339, or https://relay.example.org."
            return
        }
        var nodes = manualFederationNodes
        guard !nodes.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            manualFederationEndpointDraft = ""
            return
        }
        nodes.append(trimmed)
        federationAllowList = nodes.joined(separator: ", ")
        manualFederationEndpointDraft = ""
        applyLiveManualFederationAllowList()
    }

    func removeManualFederationNode(at index: Int) {
        var nodes = manualFederationNodes
        guard nodes.indices.contains(index) else { return }
        manualFederationHealth[nodes[index]] = nil
        nodes.remove(at: index)
        federationAllowList = nodes.joined(separator: ", ")
        applyLiveManualFederationAllowList()
    }

    func checkManualFederationNodeHealth(_ endpointValue: String) {
        let trimmed = endpointValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let endpoint = parseEndpoint(trimmed) else {
            manualFederationHealth[trimmed] = .failed(message: "Invalid endpoint", checkedAt: Date())
            return
        }
        manualFederationHealth[trimmed] = .checking
        Task {
            let started = Date()
            do {
                let response = try await RelayClient(endpoint: endpoint)
                .send(.health(), timeout: 5)
                let latencyMs = max(0, Int(Date().timeIntervalSince(started) * 1_000))
                guard response.status == .success else {
                    let message = redactedRelayMessage(
                        response.error?.message ?? "Unexpected response: \(response.status.rawValue)",
                        fallback: "Federated relay returned an unexpected response."
                    )
                    manualFederationHealth[trimmed] = .failed(message: message, checkedAt: Date())
                    appendLog("Federation health failed for \(trimmed): \(message)")
                    return
                }
                manualFederationHealth[trimmed] = .healthy(latencyMs: latencyMs, checkedAt: Date())
                appendLog("Federation health OK for \(trimmed) (\(latencyMs) ms).")
            } catch {
                let message = redactedRelayAppError(error, fallback: "Federation health check failed.")
                manualFederationHealth[trimmed] = .failed(message: message, checkedAt: Date())
                appendLog("Federation health failed for \(trimmed): \(message)")
            }
        }
    }

    private func applyLiveManualFederationAllowList() {
        applyLiveFederationRuntimeSettings(reason: "manual federation list")
    }

    private func applyLiveFederationRuntimeSettings(reason: String = "federation settings") {
        guard isRunning else { return }
        let configuration = buildConfiguration()
        server.updateFederationRuntimeSettings(from: configuration)
        appendLog("Updated live \(reason). Federation mode: \(configuration.federation.mode.rawValue); relays: \(configuration.federationAllowList.count); coordinators: \(configuration.federationCoordinatorEndpoints?.count ?? 0).")
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
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.port != 0,
              let url = components.url else {
            lastError = "Federation URL must be an HTTPS URL without credentials, query data, or a fragment."
            return
        }
        federationSourceStatus = "Fetching..."
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 15
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await BoundedHTTPResponseLoader.load(
                request,
                maximumBytes: 1_000_000
            )
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                federationSourceStatus = nil
                lastError = "Federation fetch failed with HTTP \(http.statusCode)."
                return
            }
            let document = try JSONDecoder().decode(FederationSourceDocument.self, from: data)
            guard (document.allowlist?.count ?? 0) <= 256,
                  (document.coordinators?.count ?? 0) <= 64,
                  (document.coordinatorEntries?.count ?? 0) <= 64,
                  (document.coordinatorPublicKeys?.count ?? 0) <= 64 else {
                throw CocoaError(.fileReadTooLarge)
            }
            if let modeValue = document.mode {
                guard let mode = parseFederationMode(modeValue),
                      mode == federationMode else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
            if document.allowPrivateFederationEndpoints == true,
               !allowPrivateFederationEndpoints {
                throw CocoaError(.fileReadCorruptFile)
            }
            if document.curatedStrictPolicyEnabled == false,
               curatedStrictPolicyEnabled {
                throw CocoaError(.fileReadCorruptFile)
            }
            if document.curatedRequireSignedDirectory == false,
               curatedRequireSignedDirectory {
                throw CocoaError(.fileReadCorruptFile)
            }
            let currentQuorum = Int(curatedCoordinatorQuorum) ?? 1
            if let quorum = document.curatedCoordinatorQuorum,
               quorum < currentQuorum {
                throw CocoaError(.fileReadCorruptFile)
            }
            let currentStaleness = Int(coordinatorDirectoryMaxStalenessSeconds) ?? 300
            if let staleness = document.coordinatorDirectoryMaxStalenessSeconds,
               staleness > currentStaleness {
                throw CocoaError(.fileReadCorruptFile)
            }
            if let name = document.name {
                federationName = name
            }
            if let description = document.description {
                federationDescription = description
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
                curatedStrictPolicyEnabled = curatedStrictPolicyEnabled || strict
            }
            if let quorum = document.curatedCoordinatorQuorum, quorum > 0 {
                curatedCoordinatorQuorum = String(max(1, quorum))
            }
            if let requireSigned = document.curatedRequireSignedDirectory {
                curatedRequireSignedDirectory = curatedRequireSignedDirectory || requireSigned
            }
            if let allowPrivate = document.allowPrivateFederationEndpoints {
                allowPrivateFederationEndpoints = allowPrivateFederationEndpoints && allowPrivate
            }
            federationSourceLastUpdated = Date()
            federationSourceStatus = "Loaded \(document.allowlist?.count ?? 0) allowlist entries."
        } catch {
            federationSourceStatus = nil
            lastError = "Failed to fetch federation: \(redactedRelayAppError(error, fallback: "Federation fetch failed."))"
        }
    }

    private func parseAllowList(_ value: String) -> [RelayEndpoint] {
        splitFederationEndpointList(value)
            .compactMap { parseEndpoint(String($0)) }
    }

    private func splitFederationEndpointList(_ value: String) -> [String] {
        value
            .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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
        try? RelayEndpointParser.parse(value, defaultTCPPort: defaultRelayPort)
    }

    private func configuredNoctwebSuffix() -> NoctwebRelaySuffixV1? {
        let trimmed = noctwebRelaySuffix
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty else { return nil }
        let canonical = trimmed.hasPrefix(".") ? trimmed : ".\(trimmed)"
        return NoctwebRelaySuffixV1(rawValue: canonical)
    }

    private func prepareNoctwebSuffixForStart() throws {
        let trimmed = noctwebRelaySuffix
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let requestedSuffix: NoctwebRelaySuffixV1?
        if trimmed.isEmpty {
            requestedSuffix = nil
        } else {
            guard let parsed = configuredNoctwebSuffix() else {
                throw NoctwebLifecycleError.invalidSuffix
            }
            requestedSuffix = parsed
            noctwebRelaySuffix = parsed.rawValue
        }
        if federationMode != .solo, requestedSuffix == nil {
            throw NoctwebLifecycleError.federatedSuffixRequired
        }
        if effectiveNoctwebHostingEnabled,
           requestedSuffix == nil {
            throw NoctwebLifecycleError.hostingSuffixRequired
        }

        let records = try Self.loadNamespaceRecords(
            from: namespaceLedgerURL
        ) ?? []
        let owned = activeNamespaceRecords(
            in: records,
            identity: relayIdentityKeyMaterial
        )
        guard owned.count <= 1 else {
            throw NoctwebLifecycleError.multipleOwnedSuffixes
        }
        if let active = owned.first {
            claimedNoctwebSuffix = active.suffix.rawValue
            guard requestedSuffix == active.suffix else {
                throw NoctwebLifecycleError.activeSuffixRequired(
                    active.suffix.rawValue
                )
            }
        } else {
            claimedNoctwebSuffix = nil
        }

        if let requestedSuffix,
           let existing = records.first(where: {
               $0.suffix == requestedSuffix
           }) {
            if existing.status == .tombstoned {
                throw NoctwebLifecycleError.suffixTombstoned
            }
            guard existing.ownerRelayID
                    == relayIdentityKeyMaterial?.relayID else {
                throw NoctwebLifecycleError.suffixAlreadyOwned
            }
        }
    }

    private func refreshClaimedNoctwebSuffixFromDisk() {
        do {
            let records = try Self.loadNamespaceRecords(
                from: namespaceLedgerURL
            ) ?? []
            let owned = activeNamespaceRecords(
                in: records,
                identity: relayIdentityKeyMaterial
            )
            guard owned.count <= 1 else {
                claimedNoctwebSuffix = nil
                appendLog(
                    "Noctweb namespace ledger contains multiple active suffixes for this relay identity."
                )
                return
            }
            claimedNoctwebSuffix = owned.first?.suffix.rawValue
            if noctwebRelaySuffix
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty,
               let suffix = claimedNoctwebSuffix {
                noctwebRelaySuffix = suffix
            }
        } catch {
            claimedNoctwebSuffix = nil
            appendRedactedLog(
                "Failed to inspect Noctweb namespace state",
                error: error,
                fallback: "Noctweb namespace state could not be read."
            )
        }
    }

    private func activeNamespaceRecords(
        in records: [NoctwebNamespaceRecordV1],
        identity: RelayIdentityKeyMaterialV1?
    ) -> [NoctwebNamespaceRecordV1] {
        guard let identity else { return [] }
        return records.filter {
            $0.status == .active && $0.ownerRelayID == identity.relayID
        }
    }

    private func makeRelayIdentityClaim(
        using identity: RelayIdentityKeyMaterialV1,
        suffix: NoctwebRelaySuffixV1,
        sequence: Int,
        issuedAt: Date
    ) throws -> SignedRelayIdentityClaimV1 {
        let configuration = buildConfiguration()
        let endpoint: RelayEndpoint
        if let advertised = configuration.advertisedEndpoint {
            endpoint = advertised
        } else {
            guard let portValue = UInt16(port) else {
                throw NoctwebLifecycleError.endpointUnavailable
            }
            let trimmedHost = host
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedHost.isEmpty else {
                throw NoctwebLifecycleError.endpointUnavailable
            }
            let identityHost =
                trimmedHost == "0.0.0.0" || trimmedHost == "::"
                    ? "127.0.0.1"
                    : trimmedHost
            endpoint = RelayEndpoint(
                host: identityHost,
                port: portValue,
                useTLS:
                    configuration.advertisedTLSEnabled
                        ?? configuration.tlsEnabled,
                transport: configuration.transport
            )
        }
        guard let capabilities = configuration.makeInfo(
            now: issuedAt
        ).protocolCapabilities else {
            throw NoctwebLifecycleError.capabilityUnavailable
        }
        return try identity.makeSignedClaim(
            sequence: sequence,
            relayKind: configuration.kind,
            federation: configuration.federation,
            advertisedEndpoints: [endpoint],
            noctwebSuffix: suffix,
            capabilities: capabilities,
            issuedAt: issuedAt
        )
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
        let base = "Noctweave Relay"
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

    private static func loadOrCreateRelayIdentity(
        namespaceLedgerURL: URL
    ) throws -> RelayIdentityKeyMaterialV1 {
        if let pending = try loadRelayIdentity(
            account: .pendingRelayIdentityKey
        ) {
            let records = try loadNamespaceRecords(
                from: namespaceLedgerURL
            ) ?? []
            let ledgerUsesPendingIdentity = records.contains {
                $0.status == .active && $0.ownerRelayID == pending.relayID
            }
            if ledgerUsesPendingIdentity {
                try saveRelayIdentity(pending, account: .relayIdentityKey)
                try RelaySecretStore.save(
                    "",
                    account: .pendingRelayIdentityKey
                )
                return pending
            }
            try RelaySecretStore.save(
                "",
                account: .pendingRelayIdentityKey
            )
        }
        if let existing = try loadRelayIdentity(
            account: .relayIdentityKey
        ) {
            return existing
        }
        let generated = try RelayIdentityKeyMaterialV1.generate()
        try saveRelayIdentity(generated, account: .relayIdentityKey)
        return generated
    }

    private static func loadRelayIdentity(
        account: RelaySecretStore.Account
    ) throws -> RelayIdentityKeyMaterialV1? {
        guard let encoded = try RelaySecretStore.load(account: account),
              let serialized = Data(base64Encoded: encoded) else {
            return nil
        }
        return try NoctweaveCoder.decode(
            RelayIdentityKeyMaterialV1.self,
            from: serialized
        )
    }

    private static func saveRelayIdentity(
        _ identity: RelayIdentityKeyMaterialV1,
        account: RelaySecretStore.Account
    ) throws {
        try RelaySecretStore.save(
            NoctweaveCoder.encode(identity, sortedKeys: true)
                .base64EncodedString(),
            account: account
        )
    }

    private func rebuildRuntimeWithCurrentSettings() {
        let configuration = buildConfiguration()
        store = RelayStore(
            storeURL: resolvedStoreURL(),
            temporalBucketSeconds: configuration.temporalBucketSeconds,
            temporalBucketScheduleSeconds: configuration.temporalBucketScheduleSeconds
        )
        server = RelayServer(
            store: store,
            opaqueRouteStore: opaqueRouteStore,
            configuration: configuration,
            relayIdentity: relayIdentityKeyMaterial,
            coturnCredentialIssuer: makeCoturnCredentialIssuer()
        )
        configureNamespacePersistence(on: server)
        server.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event: event)
            }
        }
    }

    private func parsedICEURLs() -> [String] {
        iceURLs
            .split { $0 == "\n" || $0 == "," }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func configuredICEServiceDescriptor() -> RelayICEServiceDescriptorV1? {
        guard iceServiceEnabled else { return nil }
        let urls: [String]
        if callTraversalDeploymentMode == .managed {
            guard let managed = try? makeManagedCoturnConfiguration() else {
                return nil
            }
            urls = managed.iceURLs
        } else {
            urls = parsedICEURLs()
        }
        let containsTURN = urls.contains {
            $0.hasPrefix("turn:") || $0.hasPrefix("turns:")
        }
        let descriptor = RelayICEServiceDescriptorV1(
            urls: urls,
            credentialMode: containsTURN ? .turnREST : .none,
            credentialLifetimeSeconds: containsTURN
                ? Int(turnCredentialLifetimeSeconds)
                : nil,
            realm: containsTURN
                ? turnRealm.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil,
            relayOnlySupported: turnRelayOnlySupported
        )
        return descriptor.isStructurallyValid ? descriptor : nil
    }

    private func prepareManagedCoturnConfiguration() throws {
        if managedTurnHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            managedTurnHost = suggestedManagedTurnHost()
        }
        if turnRealm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            turnRealm = "noctweave"
        }
        if turnSharedSecret.isEmpty {
            turnSharedSecret = Self.generateManagedTurnSecret()
            try RelaySecretStore.save(turnSharedSecret, account: .turnSharedSecret)
        }
        let configuration = try makeManagedCoturnConfiguration()
        iceURLs = configuration.iceURLs.joined(separator: ", ")
    }

    private func makeManagedCoturnConfiguration() throws -> ManagedCoturnConfiguration {
        guard let listeningPort = UInt16(managedTurnListeningPort),
              let minimumRelayPort = UInt16(managedTurnMinimumRelayPort),
              let maximumRelayPort = UInt16(managedTurnMaximumRelayPort) else {
            throw ManagedCoturnError.invalidPortRange
        }
        return try ManagedCoturnConfiguration(
            advertisedHost: managedTurnHost,
            externalIPAddress: managedTurnExternalIPAddress.nilIfEmpty,
            realm: turnRealm,
            sharedSecret: turnSharedSecret,
            listeningPort: listeningPort,
            minimumRelayPort: minimumRelayPort,
            maximumRelayPort: maximumRelayPort
        )
    }

    private func suggestedManagedTurnHost() -> String {
        let configuredHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredHost.isEmpty,
           !["0.0.0.0", "::", "[::]"].contains(configuredHost),
           ManagedCoturnConfiguration.isValidAdvertisedHost(configuredHost) {
            return configuredHost
        }
        if let localAddress = Host.current().addresses.first(where: {
            $0.contains(".") && !$0.hasPrefix("127.")
        }), ManagedCoturnConfiguration.isValidAdvertisedHost(localAddress) {
            return localAddress
        }
        if let advertised = parseEndpoint(advertisedEndpoint),
           ManagedCoturnConfiguration.isValidAdvertisedHost(advertised.host) {
            return advertised.host
        }
        return "127.0.0.1"
    }

    private static func generateManagedTurnSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32)
            .map { _ in UInt8.random(in: .min ... .max, using: &generator) }
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isLikelyPrivateAddress(_ host: String) -> Bool {
        let value = host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .lowercased()
        if value == "localhost" || value == "::1" || value.hasPrefix("127.") {
            return true
        }
        if value.hasPrefix("10.") || value.hasPrefix("192.168.")
            || value.hasPrefix("fc") || value.hasPrefix("fd")
            || value.hasPrefix("fe80:") {
            return true
        }
        if value.hasPrefix("172."),
           let second = value.split(separator: ".").dropFirst().first,
           let octet = Int(second), (16...31).contains(octet) {
            return true
        }
        return false
    }

    private func makeCoturnCredentialIssuer() -> CoturnCredentialIssuerV1? {
        guard configuredICEServiceDescriptor()?.credentialMode == .turnREST,
              turnSharedSecret == turnSharedSecret.trimmingCharacters(
                in: .whitespacesAndNewlines
              ) else {
            return nil
        }
        return CoturnCredentialIssuerV1(sharedSecret: turnSharedSecret)
    }

    private func configureNamespacePersistence(
        on server: RelayServer
    ) {
        let url = namespaceLedgerURL
        let owner = ServerViewModelWeakReference(self)
        server.onNoctwebNamespaceStateSnapshot = { records in
            do {
                try Self.saveNamespaceRecords(records, to: url)
                await MainActor.run {
                    owner.value?.refreshClaimedNoctwebSuffixFromDisk()
                }
            } catch {
                await MainActor.run {
                    owner.value?.appendRedactedLog(
                        "Failed to persist Noctweb namespace state",
                        error: error,
                        fallback: "Noctweb namespace state could not be saved."
                    )
                }
            }
        }
    }

    nonisolated private static func saveNamespaceRecords(
        _ records: [NoctwebNamespaceRecordV1],
        to url: URL
    ) throws {
        let envelope = PersistedNoctwebNamespaceLedger(
            version: NoctwebNamespaceConsensusV1.version,
            records: records
        )
        let data = try NoctweaveCoder.encode(
            envelope,
            sortedKeys: true
        )
        try RelaySecureFileIO.writePrivate(
            data,
            to: url,
            maximumBytes: 8_000_000
        )
    }

    nonisolated private static func loadNamespaceRecords(
        from url: URL
    ) throws -> [NoctwebNamespaceRecordV1]? {
        let data: Data
        do {
            data = try RelaySecureFileIO.read(
                from: url,
                maximumBytes: 8_000_000
            )
        } catch RelaySecureFileIOError.notFound {
            return nil
        }
        let envelope = try NoctweaveCoder.decode(
            PersistedNoctwebNamespaceLedger.self,
            from: data
        )
        guard envelope.version == NoctwebNamespaceConsensusV1.version else {
            throw CocoaError(.fileReadCorruptFile)
        }
        _ = try NoctwebNamespaceLedgerV1(
            records: envelope.records
        )
        return envelope.records
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
        var noctwebRelaySuffix: String?
        var noctwebHostingEnabled: Bool?
        var noctwebDataEnabled: Bool?
        var noctwebDataDatabaseCreationEnabled: Bool?
        var federationSourceURL: String
        var temporalBucketMode: RelayTemporalBucketMode?
        var temporalBucketMinutes: String
        var temporalBucketScheduleMinutes: String
        var attachmentDefaultTTLMinutes: String
        var attachmentMaxTTLMinutes: String
        var attachmentsEnabled: Bool?
        var realtimeRoutesEnabled: Bool?
        var sharedLogsEnabled: Bool?
        var ephemeralPresenceEnabled: Bool?
        var mediaBlobsEnabled: Bool?
        var pairingLobbyEnabled: Bool?
        var rendezvousTransportEnabled: Bool?
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
        var iceServiceEnabled: Bool?
        var callTraversalDeploymentMode: CallTraversalDeploymentMode?
        var managedTurnHost: String?
        var managedTurnExternalIPAddress: String?
        var managedTurnListeningPort: String?
        var managedTurnMinimumRelayPort: String?
        var managedTurnMaximumRelayPort: String?
        var iceURLs: String?
        var turnRealm: String?
        var turnCredentialLifetimeSeconds: String?
        var turnRelayOnlySupported: Bool?
        var relayName: String
        var operatorNote: String
        var storageMode: RelayStorageMode
        var storePath: String
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
            $noctwebRelaySuffix.map { _ in () }.eraseToAnyPublisher(),
            $noctwebHostingEnabled.map { _ in () }.eraseToAnyPublisher(),
            $noctwebDataEnabled.map { _ in () }.eraseToAnyPublisher(),
            $noctwebDataDatabaseCreationEnabled.map { _ in () }.eraseToAnyPublisher(),
            $federationSourceURL.map { _ in () }.eraseToAnyPublisher(),
            $temporalBucketMode.map { _ in () }.eraseToAnyPublisher(),
            $temporalBucketMinutes.map { _ in () }.eraseToAnyPublisher(),
            $temporalBucketScheduleMinutes.map { _ in () }.eraseToAnyPublisher(),
            $attachmentDefaultTTLMinutes.map { _ in () }.eraseToAnyPublisher(),
            $attachmentMaxTTLMinutes.map { _ in () }.eraseToAnyPublisher(),
            $attachmentsEnabled.map { _ in () }.eraseToAnyPublisher(),
            $realtimeRoutesEnabled.map { _ in () }.eraseToAnyPublisher(),
            $sharedLogsEnabled.map { _ in () }.eraseToAnyPublisher(),
            $ephemeralPresenceEnabled.map { _ in () }.eraseToAnyPublisher(),
            $mediaBlobsEnabled.map { _ in () }.eraseToAnyPublisher(),
            $pairingLobbyEnabled.map { _ in () }.eraseToAnyPublisher(),
            $rendezvousTransportEnabled.map { _ in () }.eraseToAnyPublisher(),
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
            $iceServiceEnabled.map { _ in () }.eraseToAnyPublisher(),
            $callTraversalDeploymentMode.map { _ in () }.eraseToAnyPublisher(),
            $managedTurnHost.map { _ in () }.eraseToAnyPublisher(),
            $managedTurnExternalIPAddress.map { _ in () }.eraseToAnyPublisher(),
            $managedTurnListeningPort.map { _ in () }.eraseToAnyPublisher(),
            $managedTurnMinimumRelayPort.map { _ in () }.eraseToAnyPublisher(),
            $managedTurnMaximumRelayPort.map { _ in () }.eraseToAnyPublisher(),
            $iceURLs.map { _ in () }.eraseToAnyPublisher(),
            $turnRealm.map { _ in () }.eraseToAnyPublisher(),
            $turnCredentialLifetimeSeconds.map { _ in () }.eraseToAnyPublisher(),
            $turnRelayOnlySupported.map { _ in () }.eraseToAnyPublisher(),
            $turnSharedSecret.map { _ in () }.eraseToAnyPublisher(),
            $relayName.map { _ in () }.eraseToAnyPublisher(),
            $operatorNote.map { _ in () }.eraseToAnyPublisher(),
            $storageMode.map { _ in () }.eraseToAnyPublisher(),
            $storePath.map { _ in () }.eraseToAnyPublisher(),
            $relayPassword.map { _ in () }.eraseToAnyPublisher(),
            $relayPasswordConfirmation.map { _ in () }.eraseToAnyPublisher(),
            $coordinatorRegistrationToken.map { _ in () }.eraseToAnyPublisher(),
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

        let federationObserved: [AnyPublisher<Void, Never>] = [
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
            $noctwebRelaySuffix.map { _ in () }.eraseToAnyPublisher(),
            $coordinatorRegistrationToken.map { _ in () }.eraseToAnyPublisher()
        ]

        Publishers.MergeMany(federationObserved)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] in
                guard let self else { return }
                if self.isApplyingPersistedSettings {
                    return
                }
                self.applyLiveFederationRuntimeSettings()
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
            noctwebRelaySuffix: noctwebRelaySuffix,
            noctwebHostingEnabled: noctwebHostingEnabled,
            noctwebDataEnabled: noctwebDataEnabled,
            noctwebDataDatabaseCreationEnabled:
                noctwebDataDatabaseCreationEnabled,
            federationSourceURL: federationSourceURL,
            temporalBucketMode: temporalBucketMode,
            temporalBucketMinutes: temporalBucketMinutes,
            temporalBucketScheduleMinutes: temporalBucketScheduleMinutes,
            attachmentDefaultTTLMinutes: attachmentDefaultTTLMinutes,
            attachmentMaxTTLMinutes: attachmentMaxTTLMinutes,
            attachmentsEnabled: attachmentsEnabled,
            realtimeRoutesEnabled: realtimeRoutesEnabled,
            sharedLogsEnabled: sharedLogsEnabled,
            ephemeralPresenceEnabled: ephemeralPresenceEnabled,
            mediaBlobsEnabled: mediaBlobsEnabled,
            pairingLobbyEnabled: pairingLobbyEnabled,
            rendezvousTransportEnabled: rendezvousTransportEnabled,
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
            iceServiceEnabled: iceServiceEnabled,
            callTraversalDeploymentMode: callTraversalDeploymentMode,
            managedTurnHost: managedTurnHost,
            managedTurnExternalIPAddress: managedTurnExternalIPAddress,
            managedTurnListeningPort: managedTurnListeningPort,
            managedTurnMinimumRelayPort: managedTurnMinimumRelayPort,
            managedTurnMaximumRelayPort: managedTurnMaximumRelayPort,
            iceURLs: iceURLs,
            turnRealm: turnRealm,
            turnCredentialLifetimeSeconds: turnCredentialLifetimeSeconds,
            turnRelayOnlySupported: turnRelayOnlySupported,
            relayName: relayName,
            operatorNote: operatorNote,
            storageMode: storageMode,
            storePath: storePath,
            communicationMode: communicationMode,
            transportSecurityMode: transportSecurityMode,
            tlsIdentityPKCS12Path: tlsIdentityPKCS12Path
        )
    }

    private func persistSettings() {
        guard secretStoreFailure == nil else {
            return
        }
        let settings = makePersistedSettings()
        do {
            try RelaySecretStore.save(relayPassword, account: .relayPassword)
            try RelaySecretStore.save(coordinatorRegistrationToken, account: .coordinatorRegistrationToken)
            try RelaySecretStore.save(tlsIdentityPassword, account: .tlsIdentityPassword)
            try RelaySecretStore.save(turnSharedSecret, account: .turnSharedSecret)
            let data = try JSONEncoder().encode(settings)
            try RelaySecureFileIO.writePrivate(
                data,
                to: settingsURL,
                maximumBytes: 1_048_576
            )
            secretStoreFailure = nil
        } catch {
            // Keep runtime functional even if settings cannot be written.
            logs.append("Settings persistence failed: \(redactedRelayAppError(error, fallback: "Settings could not be written."))")
            if logs.count > 200 {
                logs.removeFirst(logs.count - 200)
            }
        }
    }

    private func loadPersistedSettingsIfAvailable() {
        do {
            let data = try RelaySecureFileIO.read(
                from: settingsURL,
                maximumBytes: 1_048_576
            )
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
            noctwebRelaySuffix = persisted.noctwebRelaySuffix ?? ""
            noctwebHostingEnabled =
                persisted.noctwebHostingEnabled ?? false
            noctwebDataEnabled = persisted.noctwebDataEnabled ?? false
            noctwebDataDatabaseCreationEnabled =
                persisted.noctwebDataDatabaseCreationEnabled ?? false
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
            realtimeRoutesEnabled = persisted.realtimeRoutesEnabled ?? true
            sharedLogsEnabled = persisted.sharedLogsEnabled ?? true
            ephemeralPresenceEnabled = persisted.ephemeralPresenceEnabled ?? true
            mediaBlobsEnabled = persisted.mediaBlobsEnabled ?? true
            pairingLobbyEnabled = persisted.pairingLobbyEnabled ?? false
            rendezvousTransportEnabled = persisted.rendezvousTransportEnabled ?? RelayRuntimePolicy.defaultRendezvousTransportEnabled
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
            iceServiceEnabled = persisted.iceServiceEnabled ?? false
            callTraversalDeploymentMode = persisted.callTraversalDeploymentMode ?? .managed
            managedTurnHost = persisted.managedTurnHost ?? ""
            managedTurnExternalIPAddress = persisted.managedTurnExternalIPAddress ?? ""
            managedTurnListeningPort = persisted.managedTurnListeningPort ?? "3478"
            managedTurnMinimumRelayPort = persisted.managedTurnMinimumRelayPort ?? "49160"
            managedTurnMaximumRelayPort = persisted.managedTurnMaximumRelayPort ?? "49200"
            iceURLs = persisted.iceURLs ?? ""
            turnRealm = persisted.turnRealm ?? "noctweave"
            turnCredentialLifetimeSeconds = persisted.turnCredentialLifetimeSeconds ?? "600"
            turnRelayOnlySupported = persisted.turnRelayOnlySupported ?? true
            relayName = persisted.relayName
            operatorNote = persisted.operatorNote
            storageMode = persisted.storageMode
            storePath = persisted.storePath
            communicationMode = persisted.communicationMode
            transportSecurityMode = persisted.transportSecurityMode
            tlsIdentityPKCS12Path = persisted.tlsIdentityPKCS12Path
            do {
                relayPassword = try RelaySecretStore.load(account: .relayPassword) ?? ""
                relayPasswordConfirmation = relayPassword
                coordinatorRegistrationToken = try RelaySecretStore.load(account: .coordinatorRegistrationToken) ?? ""
                tlsIdentityPassword = try RelaySecretStore.load(account: .tlsIdentityPassword) ?? ""
                turnSharedSecret = try RelaySecretStore.load(account: .turnSharedSecret) ?? ""
                secretStoreFailure = nil
            } catch {
                relayPassword = ""
                relayPasswordConfirmation = ""
                coordinatorRegistrationToken = ""
                tlsIdentityPassword = ""
                turnSharedSecret = ""
                secretStoreFailure = "Saved relay secrets could not be read from Keychain."
                logs.append("Saved relay secrets were not loaded; relay startup is blocked until Keychain access is restored.")
            }
            isApplyingPersistedSettings = false
        } catch RelaySecureFileIOError.notFound {
            return
        } catch {
            isApplyingPersistedSettings = false
            logs.append("Failed to load persisted settings: \(redactedRelayAppError(error, fallback: "Settings could not be loaded."))")
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
            let queue = DispatchQueue(label: "NoctweaveRelay.LocalNetworkPermission")
            let probeServiceName = "Noctweave permission check \(UUID().uuidString)"
            let descriptor = NWBrowser.Descriptor.bonjour(type: "_noctweave._tcp", domain: nil)
            let browser = NWBrowser(for: descriptor, using: .tcp)
            let gate = PermissionProbeGate()
            let listener: NWListener
            do {
                listener = try NWListener(using: .tcp, on: .any)
                listener.service = NWListener.Service(
                    name: probeServiceName,
                    type: "_noctweave._tcp"
                )
            } catch {
                continuation.resume(
                    returning: PermissionProbeResult(
                        status: .failed,
                        message: "Local network probe failed to start: \(Self.redactedPermissionProbeError(error))"
                    )
                )
                return
            }

            @Sendable func finish(_ result: PermissionProbeResult) {
                guard gate.claim() else { return }
                browser.cancel()
                listener.cancel()
                continuation.resume(returning: result)
            }

            listener.stateUpdateHandler = { state in
                switch state {
                case .failed(let error), .waiting(let error):
                    finish(
                        PermissionProbeResult(
                            status: Self.permissionStatus(for: error),
                            message: "Local network advertisement failed: \(Self.redactedPermissionProbeError(error))"
                        )
                    )
                default:
                    break
                }
            }
            listener.newConnectionHandler = { connection in
                connection.cancel()
            }

            browser.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // NWBrowser becoming ready does not prove that macOS granted
                    // local-network access. Wait for a browse result callback or
                    // an explicit failure instead of showing a premature success.
                    break
                case .failed(let error):
                    finish(
                        PermissionProbeResult(
                            status: .failed,
                            message: "Local network probe failed: \(Self.redactedPermissionProbeError(error))"
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
                            message: "Local network waiting: \(Self.redactedPermissionProbeError(error))"
                        )
                    )
                case .cancelled:
                    break
                default:
                    break
                }
            }
            browser.browseResultsChangedHandler = { results, _ in
                let foundProbe = results.contains { result in
                    guard case .service(let name, _, _, _) = result.endpoint else {
                        return false
                    }
                    return name == probeServiceName
                }
                guard foundProbe else { return }
                finish(
                    PermissionProbeResult(
                        status: .ready,
                        message: "Local-network permission was confirmed by advertising and rediscovering a temporary private service."
                    )
                )
            }
            listener.start(queue: queue)
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

    nonisolated private static func permissionStatus(for error: NWError) -> StartupPermissionStatus {
        if case .posix(let code) = error, code == .EPERM {
            return .denied
        }
        return .failed
    }

    private static func probeIncomingConnectionPermission(timeoutSeconds: TimeInterval = 3.0) async -> PermissionProbeResult {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "NoctweaveRelay.IncomingPermission")
            let gate = PermissionProbeGate()
            let listener: NWListener
            do {
                listener = try NWListener(using: .tcp, on: .any)
            } catch {
                continuation.resume(
                    returning: PermissionProbeResult(
                        status: .failed,
                        message: "Incoming connection probe failed to start: \(Self.redactedPermissionProbeError(error))"
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
                            status: .ready,
                            message: "A local listener was created successfully. Confirm inbound reachability from another device after starting the relay."
                        )
                    )
                case .failed(let error):
                    finish(
                        PermissionProbeResult(
                            status: .failed,
                            message: "Incoming listener probe failed: \(Self.redactedPermissionProbeError(error))"
                        )
                    )
                case .waiting(let error):
                    finish(
                        PermissionProbeResult(
                            status: .denied,
                            message: "Incoming listener waiting: \(Self.redactedPermissionProbeError(error))"
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
