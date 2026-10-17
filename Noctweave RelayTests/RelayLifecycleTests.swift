import Darwin
import AppKit
import Foundation
import Network
import NoctweaveCore
import SwiftUI
import XCTest
@testable import Noctweave_Relay

@MainActor
final class RelayLifecycleTests: XCTestCase {
    func testOccupiedLoopbackPortDoesNotReportOnline() async throws {
        let (socket, port) = try occupyLoopbackPort()
        defer { Darwin.close(socket) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-bind-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ServerViewModel(storageDirectory: root)
        model.host = "127.0.0.1"
        model.port = String(port)
        model.storageMode = .memory
        model.start()
        let observedFailure = try await waitUntil { model.logs.contains { $0.hasPrefix("Error:") } }

        XCTAssertTrue(observedFailure, "Fixture did not reach the actual listener failure")
        XCTAssertFalse(model.isRunning, "A failed listener must not appear online")
        XCTAssertNotNil(model.lastError, "A failed start must be visible to the operator")
        model.stop()
        let stopped = try await waitUntil { !model.isStopping }
        XCTAssertTrue(stopped)
    }

    func testSuccessfulStartAndMalformedClientKeepCorrectListenerState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-ready-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ServerViewModel(storageDirectory: root)
        model.host = "127.0.0.1"
        model.port = "0"
        model.storageMode = .memory
        model.start()
        XCTAssertTrue(model.isStarting)
        XCTAssertFalse(model.isRunning, "Online must wait for the listener-ready event")
        XCTAssertFalse(model.canEditStoppedConfiguration)
        XCTAssertEqual(model.runtimeStatusTitle, "Starting")
        assertStoppedSettingsCannotChange(model)
        model.start() // Repeated clicks while starting must keep one runtime.
        let ready = try await waitUntil { model.isRunning }
        XCTAssertTrue(ready, model.lastError ?? "Listener did not become ready")
        XCTAssertFalse(model.isStarting)
        XCTAssertEqual(model.logs.filter { $0.hasPrefix("Server started on") }.count, 1)
        let line = try XCTUnwrap(model.logs.first { $0.hasPrefix("Server started on") })
        let port = try XCTUnwrap(line.split(separator: ":").last.flatMap { UInt16($0) })
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        defer { connection.cancel() }
        connection.start(queue: DispatchQueue(label: "RelayLifecycleTests.MalformedClient"))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: Data("{}\n".utf8), completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
        let rejected = try await waitUntil { model.logs.contains { $0.hasPrefix("Error:") } }
        XCTAssertTrue(rejected, "Fixture request did not reach rejection")
        XCTAssertTrue(model.isRunning, "A malformed client request must not stop a healthy listener")
        XCTAssertNil(model.lastError)
        let health = try await RelayClient(endpoint: RelayEndpoint(host: "127.0.0.1", port: port)).send(.health())
        XCTAssertEqual(health.status, .success)
        model.stop()
        XCTAssertFalse(model.canEditStoppedConfiguration)
        XCTAssertEqual(model.runtimeStatusTitle, "Stopping")
        assertStoppedSettingsCannotChange(model)
        let stopped = try await waitUntil { !model.isStopping }
        XCTAssertTrue(stopped)
        XCTAssertFalse(model.isRunning)
        XCTAssertTrue(model.canEditStoppedConfiguration)
    }

    func testStopDuringStartupCannotReviveTheRetiredRuntime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-start-stop-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ServerViewModel(storageDirectory: root)
        model.host = "127.0.0.1"
        model.port = "0"
        model.storageMode = .memory
        model.start()
        model.stop()
        let stopped = try await waitUntil { !model.isStopping }
        XCTAssertTrue(stopped)
        XCTAssertFalse(model.isRunning)
        XCTAssertFalse(model.isStarting)
        XCTAssertFalse(model.logs.contains { $0.hasPrefix("Server started on") })

        model.start()
        let ready = try await waitUntil { model.isRunning }
        XCTAssertTrue(ready, model.lastError ?? "Fresh runtime did not start")
        model.stop()
        let stoppedAgain = try await waitUntil { !model.isStopping }
        XCTAssertTrue(stoppedAgain)
        XCTAssertFalse(model.isRunning)
    }

    func testRenderIsolatedStoppedStartingAndStoppingControls() async throws {
        #if NOCTWEAVE_XCTEST_VOLATILE_KEYCHAIN
        // These are fixture preferences in the process-local test store. No
        // real agreement, permission prompt, Keychain item or relay is used.
        let preferences = RelayUIPreferences.shared
        let original = (preferences.acceptedPrivacyPolicy, preferences.acceptedTermsOfUse,
                        preferences.completedPermissionPreflight, preferences.hasSeenSetupGuide)
        preferences.acceptedPrivacyPolicy = true
        preferences.acceptedTermsOfUse = true
        preferences.completedPermissionPreflight = true
        preferences.hasSeenSetupGuide = true
        defer {
            preferences.acceptedPrivacyPolicy = original.0
            preferences.acceptedTermsOfUse = original.1
            preferences.completedPermissionPreflight = original.2
            preferences.hasSeenSetupGuide = original.3
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("relay-render-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ServerViewModel(storageDirectory: root)
        model.host = "127.0.0.1"
        model.port = "0"
        model.storageMode = .memory
        try captureControls(model, label: "Stopped")
        model.start()
        try captureControls(model, label: "Starting")
        XCTAssertTrue(model.isStarting)
        model.stop()
        try captureControls(model, label: "Stopping")
        XCTAssertTrue(model.isStopping)
        let stopped = try await waitUntil { !model.isStopping }
        XCTAssertTrue(stopped)
        #else
        throw XCTSkip("Rendered fixtures require the volatile test secret store")
        #endif
    }

    private func captureControls(_ model: ServerViewModel, label: String) throws {
        for size in [NSSize(width: 900, height: 600), NSSize(width: 1180, height: 820)] {
            let view = NSHostingView(rootView: ContentView(model: model))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = view
            view.frame = NSRect(origin: .zero, size: size)
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = "Relay \(label) \(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    private func assertStoppedSettingsCannotChange(_ model: ServerViewModel) {
        let before = (model.realtimeRoutesEnabled, model.pairingLobbyEnabled,
                      model.temporalBucketMode, model.iceServiceEnabled, model.callTraversalDeploymentMode)
        model.setNoctCordServicesEnabled(false)
        model.setNoctCordImmediateDelivery(true)
        model.setPairingLobbyEnabled(true)
        model.setCallTraversalEnabled(true)
        model.setCallTraversalDeploymentMode(.external)
        model.applyPrivateMessagingRecommendedProfile()
        model.applyRealtimeCommunityRecommendedProfile()
        XCTAssertEqual(model.realtimeRoutesEnabled, before.0)
        XCTAssertEqual(model.pairingLobbyEnabled, before.1)
        XCTAssertEqual(model.temporalBucketMode, before.2)
        XCTAssertEqual(model.iceServiceEnabled, before.3)
        XCTAssertEqual(model.callTraversalDeploymentMode, before.4)
    }

    private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
        for _ in 0..<250 {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func occupyLoopbackPort() throws -> (Int32, UInt16) {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw POSIXError(.EIO) }
        var succeeded = false
        defer { if !succeeded { Darwin.close(socket) } }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(socket, 1) == 0 else { throw POSIXError(.EIO) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socket, $0, &length)
            }
        }
        guard named == 0 else { throw POSIXError(.EIO) }
        succeeded = true
        return (socket, UInt16(bigEndian: address.sin_port))
    }
}
