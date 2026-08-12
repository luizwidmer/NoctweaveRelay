import Foundation
import NoctweaveCore
import XCTest
@testable import Noctweave_Relay

final class OpaqueRouteSnapshotVaultTests: XCTestCase {
    func testEncryptedSnapshotRoundTripsAndRejectsTampering() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoctweaveRelayVaultTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("opaque-routes.nwstate")
        let key = Data(repeating: 0xA7, count: 32)
        let snapshot = try OpaqueRouteRelayStateSnapshotV2(
            cursorKey: Data(repeating: 0x5C, count: 32),
            routes: []
        )
        let vault = try RelayOpaqueRouteSnapshotVault(fileURL: fileURL, keyData: key)

        try await vault.save(snapshot)
        let restored = try await vault.load()
        XCTAssertEqual(restored, snapshot)

        let stored = try Data(contentsOf: fileURL)
        let plaintext = try NoctweaveCoder.encode(snapshot, sortedKeys: true)
        XCTAssertNil(stored.range(of: plaintext))

        var tampered = stored
        tampered[tampered.index(before: tampered.endIndex)] ^= 0x01
        try tampered.write(to: fileURL, options: [.atomic])
        do {
            _ = try await vault.load()
            XCTFail("Tampered snapshot must not load")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    func testSnapshotVaultRejectsSymlinkedState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoctweaveRelayVaultSymlink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let realURL = directory.appendingPathComponent("real.nwstate")
        try Data([0x01]).write(to: realURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: realURL.path)
        let linkedURL = directory.appendingPathComponent("opaque-routes.nwstate")
        try FileManager.default.createSymbolicLink(at: linkedURL, withDestinationURL: realURL)
        let vault = try RelayOpaqueRouteSnapshotVault(
            fileURL: linkedURL,
            keyData: Data(repeating: 0xA7, count: 32)
        )

        do {
            _ = try await vault.load()
            XCTFail("Symlinked snapshot state must not load")
        } catch {
            XCTAssertNotNil(error)
        }
    }
}
