import CryptoKit
import Foundation
import XCTest
@testable import Noctweave_Relay

final class RelayEncryptedLocalFileTests: XCTestCase {
    @MainActor
    func testSettingsSurviveReopenAndCorruptionBlocksStartup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoctweaveRelaySettings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("relay_settings.json")
        let relayName = "private-relay-name-\(UUID().uuidString)"

        let first = ServerViewModel(storageDirectory: directory)
        first.relayName = relayName
        try await Task.sleep(for: .milliseconds(600))

        var stored = try Data(contentsOf: settingsURL)
        XCTAssertTrue(stored.starts(with: Data("NWRF1".utf8)))
        XCTAssertNil(stored.range(of: Data(relayName.utf8)))

        let reopened = ServerViewModel(storageDirectory: directory)
        XCTAssertEqual(reopened.relayName, relayName)

        stored = try Data(contentsOf: settingsURL)
        stored[stored.index(before: stored.endIndex)] ^= 0x01
        try stored.write(to: settingsURL, options: [.atomic])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)

        let corrupted = ServerViewModel(storageDirectory: directory)
        corrupted.start()
        XCTAssertFalse(corrupted.isRunning)
        XCTAssertTrue(corrupted.lastError?.contains("could not be decrypted") == true)
    }

    func testCiphertextHidesSettingsAndRejectsWrongKeyDomainAndTampering() throws {
        let key = SymmetricKey(data: Data(repeating: 0xA1, count: 32))
        let wrong = SymmetricKey(data: Data(repeating: 0xB2, count: 32))
        var plaintext = Data("private-relay-name-canary".utf8)
        defer { plaintext.resetBytes(in: plaintext.startIndex..<plaintext.endIndex) }
        let sealed = try RelayEncryptedLocalFile.seal(
            plaintext,
            using: key,
            domain: RelayEncryptedLocalFile.settingsDomain
        )
        XCTAssertNil(sealed.range(of: plaintext))
        XCTAssertEqual(
            try RelayEncryptedLocalFile.open(
                sealed,
                using: key,
                domain: RelayEncryptedLocalFile.settingsDomain
            ),
            plaintext
        )
        XCTAssertThrowsError(try RelayEncryptedLocalFile.open(
            sealed, using: wrong, domain: RelayEncryptedLocalFile.settingsDomain
        ))
        XCTAssertThrowsError(try RelayEncryptedLocalFile.open(
            sealed, using: key, domain: RelayEncryptedLocalFile.namespaceDomain
        ))
        XCTAssertThrowsError(try RelayEncryptedLocalFile.open(
            plaintext, using: key, domain: RelayEncryptedLocalFile.settingsDomain
        ))
        var tampered = sealed
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        XCTAssertThrowsError(try RelayEncryptedLocalFile.open(
            tampered, using: key, domain: RelayEncryptedLocalFile.settingsDomain
        ))
    }
}
