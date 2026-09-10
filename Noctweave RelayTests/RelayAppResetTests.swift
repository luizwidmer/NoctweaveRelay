import Foundation
import XCTest
@testable import Noctweave_Relay

@MainActor
final class RelayAppResetTests: XCTestCase {
    func testModelResetRemovesSettingsAndStartsFresh() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-model-reset-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ServerViewModel(storageDirectory: root)
        let orphan = root.appendingPathComponent("interrupted-write.tmp")
        try Data("fixture".utf8).write(to: orphan)
        model.relayName = "Previous operator"
        var completed = false
        model.onResetCompleted = { completed = true }
        await model.purgeAndReset()
        XCTAssertTrue(completed, model.lastError ?? "Reset did not complete")
        XCTAssertFalse(model.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("relay_settings.json").path))
        let reopened = ServerViewModel(storageDirectory: root)
        XCTAssertEqual(reopened.relayName, "")
        XCTAssertFalse(reopened.resetIsPending)
    }

    func testPurgeIncludesExternalStoreSidecarsButPreservesNeighborFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-reset-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("app")
        let external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let database = external.appendingPathComponent("relay.sqlite")
        let neighbor = external.appendingPathComponent("keep.txt")
        let orphan = external.appendingPathComponent(".relay.opaque-routes.nwstate.\(UUID()).tmp")
        let snapshot = external.appendingPathComponent("relay.opaque-routes.nwstate")
        let host = external.appendingPathComponent("relay-noctweb-host")
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        for file in [database, URL(fileURLWithPath: database.path + "-wal"), snapshot, orphan, neighbor, host.appendingPathComponent("payload")] {
            try Data("fixture".utf8).write(to: file)
        }
        try RelayAppReset.begin(in: support, stores: [database])
        var keysCleared = false
        try RelayAppReset.complete(in: support, clearSecrets: { keysCleared = true }, clearPreferences: {})
        XCTAssertTrue(keysCleared)
        XCTAssertFalse(RelayAppReset.isPending(in: support))
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path + "-wal"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: host.path))
        XCTAssertEqual(try Data(contentsOf: neighbor), Data("fixture".utf8))
    }

    func testKeyDeletionFailureRetainsIntentAndDoesNotClearPreferences() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-reset-failure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try RelayAppReset.begin(in: root, stores: [])
        var preferencesCleared = false
        XCTAssertThrowsError(try RelayAppReset.complete(in: root,
            clearSecrets: { throw CocoaError(.fileWriteNoPermission) },
            clearPreferences: { preferencesCleared = true }))
        XCTAssertTrue(RelayAppReset.isPending(in: root))
        XCTAssertFalse(preferencesCleared)
        try RelayAppReset.complete(in: root, clearSecrets: {}, clearPreferences: {})
        XCTAssertFalse(RelayAppReset.isPending(in: root))
    }
}
