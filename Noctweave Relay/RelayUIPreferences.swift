import Combine
import Foundation

/// All retained shell choices live in the device-only relay Keychain item.
/// Unreleased plaintext UserDefaults records require an explicit purge.
@MainActor
final class RelayUIPreferences: ObservableObject {
    static let shared = RelayUIPreferences()

    @Published var acceptedPrivacyPolicy = false { didSet { persist() } }
    @Published var acceptedTermsOfUse = false { didSet { persist() } }
    @Published var completedPermissionPreflight = false { didSet { persist() } }
    @Published var hasSeenSetupGuide = false { didSet { persist() } }
    @Published var appearanceRaw = NoctweaveAppearanceMode.system.rawValue {
        didSet { persist() }
    }
    @Published private(set) var protectionError: String?

    private struct Record: Codable {
        let version: Int
        let acceptedPrivacyPolicy: Bool
        let acceptedTermsOfUse: Bool
        let completedPermissionPreflight: Bool
        let hasSeenSetupGuide: Bool
        let appearanceRaw: String
    }

    private let oldKeys = [
        "noctweave.server.acceptedPrivacyPolicy.v1",
        "noctweave.server.acceptedTermsOfUse.v1",
        "noctweave.server.permissions.preflight.v1",
        "noctweave.server.setupGuide.seen.v1",
        "noctweave.relay.appearance"
    ]
    private var suspendPersistence = false
    private var loadFailed = false

    private init() {
        reload()
    }

    func reload() {
        if oldKeys.contains(where: { UserDefaults.standard.object(forKey: $0) != nil }) {
            loadFailed = true
            protectionError = "Legacy plaintext relay preferences were found. Purge and reset local data before using this unreleased build."
            return
        }
        do {
            if let encoded = try RelaySecretStore.load(account: .uiPreferences) {
                guard encoded.utf8.count <= 16 * 1024,
                      var data = encoded.data(using: .utf8) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
                let record = try JSONDecoder().decode(Record.self, from: data)
                guard record.version == 1,
                      NoctweaveAppearanceMode(rawValue: record.appearanceRaw) != nil else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                suspendPersistence = true
                acceptedPrivacyPolicy = record.acceptedPrivacyPolicy
                acceptedTermsOfUse = record.acceptedTermsOfUse
                completedPermissionPreflight = record.completedPermissionPreflight
                hasSeenSetupGuide = record.hasSeenSetupGuide
                appearanceRaw = record.appearanceRaw
                suspendPersistence = false
            } else {
                suspendPersistence = true
                acceptedPrivacyPolicy = false
                acceptedTermsOfUse = false
                completedPermissionPreflight = false
                hasSeenSetupGuide = false
                appearanceRaw = NoctweaveAppearanceMode.system.rawValue
                suspendPersistence = false
            }
            loadFailed = false
            protectionError = nil
        } catch {
            suspendPersistence = false
            loadFailed = true
            protectionError = "Protected relay preferences are unavailable. Restore Keychain access or purge and reset local data."
        }
    }

    func resetInMemory() {
        suspendPersistence = true
        acceptedPrivacyPolicy = false
        acceptedTermsOfUse = false
        completedPermissionPreflight = false
        hasSeenSetupGuide = false
        appearanceRaw = NoctweaveAppearanceMode.system.rawValue
        protectionError = nil
        loadFailed = false
        suspendPersistence = false
    }

    private func persist() {
        guard !suspendPersistence, !loadFailed else { return }
        let record = Record(
            version: 1,
            acceptedPrivacyPolicy: acceptedPrivacyPolicy,
            acceptedTermsOfUse: acceptedTermsOfUse,
            completedPermissionPreflight: completedPermissionPreflight,
            hasSeenSetupGuide: hasSeenSetupGuide,
            appearanceRaw: appearanceRaw
        )
        do {
            var data = try JSONEncoder().encode(record)
            defer { data.resetBytes(in: data.startIndex..<data.endIndex) }
            guard data.count <= 16 * 1024,
                  let encoded = String(data: data, encoding: .utf8) else {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try RelaySecretStore.save(encoded, account: .uiPreferences)
            protectionError = nil
        } catch {
            loadFailed = true
            protectionError = "Protected relay preferences could not be saved. Restore Keychain access before continuing."
        }
    }
}
