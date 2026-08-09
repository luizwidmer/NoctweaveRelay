import Combine
import Darwin
import Foundation

enum CallTraversalDeploymentMode: String, CaseIterable, Identifiable, Codable {
    case managed
    case external

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .managed: return "Managed"
        case .external: return "External"
        }
    }
}

enum ManagedCoturnState: Equatable {
    case stopped
    case starting
    case running(processIdentifier: Int32)
    case unavailable(String)
    case failed(String)

    var title: String {
        switch self {
        case .stopped: return "Ready to start"
        case .starting: return "Starting"
        case .running: return "Running"
        case .unavailable: return "Unavailable"
        case .failed: return "Needs attention"
        }
    }

    var detail: String? {
        switch self {
        case .stopped:
            return "Starts and stops with the Noctweave relay."
        case .starting:
            return "Preparing private TURN credentials and listeners."
        case .running(let processIdentifier):
            return "Managed coturn process \(processIdentifier) is active."
        case .unavailable(let message), .failed(let message):
            return message
        }
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

struct ManagedCoturnConfiguration: Equatable {
    let advertisedHost: String
    let externalIPAddress: String?
    let realm: String
    let sharedSecret: String
    let listeningPort: UInt16
    let minimumRelayPort: UInt16
    let maximumRelayPort: UInt16

    init(
        advertisedHost: String,
        externalIPAddress: String? = nil,
        realm: String,
        sharedSecret: String,
        listeningPort: UInt16 = 3478,
        minimumRelayPort: UInt16 = 49_160,
        maximumRelayPort: UInt16 = 49_200
    ) throws {
        let host = advertisedHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let externalIP = externalIPAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedRealm = realm.trimmingCharacters(in: .whitespacesAndNewlines)

        guard Self.isValidAdvertisedHost(host) else {
            throw ManagedCoturnError.invalidAdvertisedHost
        }
        if let externalIP, !externalIP.isEmpty,
           !Self.isValidIPAddressLiteral(externalIP) {
            throw ManagedCoturnError.invalidExternalIPAddress
        }
        guard Self.isSafeSingleLine(normalizedRealm, maximumUTF8Bytes: 255) else {
            throw ManagedCoturnError.invalidRealm
        }
        guard sharedSecret == sharedSecret.trimmingCharacters(in: .whitespacesAndNewlines),
              Self.isSafeSingleLine(sharedSecret, maximumUTF8Bytes: 4_096),
              sharedSecret.utf8.count >= 16 else {
            throw ManagedCoturnError.invalidSharedSecret
        }
        guard listeningPort > 0,
              minimumRelayPort > 0,
              maximumRelayPort >= minimumRelayPort else {
            throw ManagedCoturnError.invalidPortRange
        }

        self.advertisedHost = host
        self.externalIPAddress = externalIP?.isEmpty == false ? externalIP : nil
        self.realm = normalizedRealm
        self.sharedSecret = sharedSecret
        self.listeningPort = listeningPort
        self.minimumRelayPort = minimumRelayPort
        self.maximumRelayPort = maximumRelayPort
    }

    var iceURLs: [String] {
        let host = advertisedHost.contains(":") && !advertisedHost.hasPrefix("[")
            ? "[\(advertisedHost)]"
            : advertisedHost
        return [
            "stun:\(host):\(listeningPort)",
            "turn:\(host):\(listeningPort)?transport=udp",
            "turn:\(host):\(listeningPort)?transport=tcp"
        ]
    }

    var configurationText: String {
        var lines = [
            "listening-port=\(listeningPort)",
            "fingerprint",
            "use-auth-secret",
            "static-auth-secret=\(sharedSecret)",
            "realm=\(realm)",
            "server-name=\(realm)",
            "min-port=\(minimumRelayPort)",
            "max-port=\(maximumRelayPort)",
            "stale-nonce=600",
            "no-cli",
            "no-tls",
            "no-dtls",
            "no-multicast-peers",
            "user-quota=12",
            "total-quota=1200",
            "log-file=stdout",
            "simple-log"
        ]
        if let externalIPAddress {
            lines.append("external-ip=\(externalIPAddress)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func isValidAdvertisedHost(_ value: String) -> Bool {
        guard isSafeSingleLine(value, maximumUTF8Bytes: 255),
              !value.contains("/"),
              !value.contains("?") else {
            return false
        }
        let unwrapped = value.hasPrefix("[") && value.hasSuffix("]")
            ? String(value.dropFirst().dropLast())
            : value
        if isValidIPAddressLiteral(unwrapped) {
            return true
        }
        guard !value.contains(":"), value.utf8.count <= 253 else {
            return false
        }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard !label.isEmpty,
                  label.utf8.count <= 63,
                  label.first?.isLetter == true || label.first?.isNumber == true,
                  label.last?.isLetter == true || label.last?.isNumber == true else {
                return false
            }
            return label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }

    static func isValidIPAddressLiteral(_ value: String) -> Bool {
        guard isSafeSingleLine(value, maximumUTF8Bytes: 64) else { return false }
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return true
        }
        var ipv6 = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
    }

    private static func isSafeSingleLine(
        _ value: String,
        maximumUTF8Bytes: Int
    ) -> Bool {
        guard !value.isEmpty,
              value.utf8.count <= maximumUTF8Bytes,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return false
        }
        return true
    }
}

enum ManagedCoturnError: LocalizedError {
    case helperUnavailable
    case invalidAdvertisedHost
    case invalidExternalIPAddress
    case invalidRealm
    case invalidSharedSecret
    case invalidPortRange
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .helperUnavailable:
            return "The bundled coturn service is unavailable in this build."
        case .invalidAdvertisedHost:
            return "Enter a hostname or IP address without a scheme or port."
        case .invalidExternalIPAddress:
            return "The advanced external address must be an IPv4 or IPv6 literal."
        case .invalidRealm:
            return "The TURN realm is invalid."
        case .invalidSharedSecret:
            return "The managed TURN credential key is invalid."
        case .invalidPortRange:
            return "The managed TURN port range is invalid."
        case .launchFailed(let detail):
            return detail
        }
    }
}

@MainActor
final class ManagedCoturnService: ObservableObject {
    static let shared = ManagedCoturnService()

    @Published private(set) var state: ManagedCoturnState = .stopped
    @Published private(set) var recentLog: String = ""

    private var process: Process?
    private var outputPipe: Pipe?
    private var requestedStop = false
    private var activeSecret = ""

    private init() {}

    func start(configuration: ManagedCoturnConfiguration) async throws {
        if process?.isRunning == true {
            state = .running(processIdentifier: process?.processIdentifier ?? 0)
            return
        }

        guard let executableURL = Self.bundledExecutableURL(),
              FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            state = .unavailable(ManagedCoturnError.helperUnavailable.localizedDescription)
            throw ManagedCoturnError.helperUnavailable
        }

        state = .starting
        recentLog = ""
        activeSecret = configuration.sharedSecret
        requestedStop = false

        let configurationURL = try writePrivateConfiguration(configuration)
        let outputPipe = Pipe()
        self.outputPipe = outputPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self,
                  !data.isEmpty,
                  let text = String(data: data, encoding: .utf8) else {
                return
            }
            Task { @MainActor [self] in
                self.record(text)
            }
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-c", configurationURL.path]
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        process.currentDirectoryURL = configurationURL.deletingLastPathComponent()
        process.terminationHandler = { [weak self] terminated in
            guard let self else { return }
            Task { @MainActor [self] in
                guard self.process === terminated else { return }
                self.outputPipe?.fileHandleForReading.readabilityHandler = nil
                self.outputPipe = nil
                self.process = nil
                self.activeSecret = ""
                if self.requestedStop {
                    self.state = .stopped
                } else {
                    let detail = self.recentLog
                        .split(separator: "\n")
                        .last
                        .map(String.init) ?? "Managed coturn exited unexpectedly."
                    self.state = .failed(detail)
                }
            }
        }

        do {
            try process.run()
            self.process = process
            try await Task.sleep(for: .milliseconds(350))
            guard process.isRunning else {
                throw ManagedCoturnError.launchFailed(
                    recentLog.isEmpty
                        ? "Managed coturn could not open its network ports."
                        : recentLog.split(separator: "\n").last.map(String.init) ?? "Managed coturn failed."
                )
            }
            try? FileManager.default.removeItem(at: configurationURL)
            state = .running(processIdentifier: process.processIdentifier)
        } catch {
            try? FileManager.default.removeItem(at: configurationURL)
            outputPipe.fileHandleForReading.readabilityHandler = nil
            self.outputPipe = nil
            self.process = nil
            activeSecret = ""
            let message = error.localizedDescription
            state = .failed(message)
            throw error
        }
    }

    func stop() {
        requestedStop = true
        guard let process else {
            activeSecret = ""
            state = .stopped
            return
        }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            process.terminate()
        } else {
            self.process = nil
            outputPipe = nil
            state = .stopped
        }
    }

    private func writePrivateConfiguration(
        _ configuration: ManagedCoturnConfiguration
    ) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoctweaveRelay", isDirectory: true)
            .appendingPathComponent("ManagedCoturn", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let url = base.appendingPathComponent("turnserver.conf")
        try Data(configuration.configurationText.utf8).write(
            to: url,
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return url
    }

    private func record(_ rawText: String) {
        let redacted = activeSecret.isEmpty
            ? rawText
            : rawText.replacingOccurrences(of: activeSecret, with: "[redacted]")
        recentLog = String((recentLog + redacted).suffix(8_192))
    }

    private static func bundledExecutableURL() -> URL? {
        let bundleURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent("ManagedCoturn.bundle", isDirectory: true)
        guard let helperBundle = Bundle(url: bundleURL) else {
            return nil
        }
        return helperBundle.executableURL
    }
}
