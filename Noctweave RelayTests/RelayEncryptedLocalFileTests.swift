import CryptoKit
import Foundation
import XCTest
@testable import Noctweave_Relay

final class RelayEncryptedLocalFileTests: XCTestCase {
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
