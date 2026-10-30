import XCTest
@testable import Noctweave_Relay

final class ManagedCoturnConfigurationTests: XCTestCase {
    private let secret = "0123456789abcdef0123456789abcdef"

    func testManagedLogRedactsSecretAcrossEveryChunkBoundary() {
        for split in 1..<secret.count {
            let prefix = String(secret.prefix(split))
            let suffix = String(secret.dropFirst(split))
            var redactor = ManagedCoturnLogRedactor(secret: secret)
            let first = redactor.append("before " + prefix)
            let second = redactor.append(suffix + " after\n")
            XCTAssertEqual(first + second, "before [redacted] after\n", "split \(split)")
        }

        var redactor = ManagedCoturnLogRedactor(secret: secret)
        let chunks = ["prefix 0123", "0123456789abcdef0123456789abcdef", " suffix\n"]
        XCTAssertEqual(chunks.map { redactor.append($0) }.joined(),
                       "prefix 0123[redacted] suffix\n")

        var overlapping = ManagedCoturnLogRedactor(secret: "ababac")
        XCTAssertEqual(["ababa", "babac!"].map { overlapping.append($0) }.joined(),
                       "abab[redacted]!")

        var unicode = ManagedCoturnLogRedactor(secret: "e\u{301}abc")
        XCTAssertEqual(["before e", "\u{301}abc after\n"].map { unicode.append($0) }.joined(),
                       "before [redacted] after\n")

        let bytes = Array("before e\u{301}abc after\n".utf8)
        for split in 1..<bytes.count {
            var byteRedactor = ManagedCoturnLogRedactor(secret: "e\u{301}abc")
            let first = byteRedactor.append(Data(bytes[..<split]))
            let second = byteRedactor.append(Data(bytes[split...]))
            XCTAssertEqual(first + second, "before [redacted] after\n", "byte split \(split)")
        }
    }

    func testManagedConfigurationCreatesClientDiscoveryURLs() throws {
        let configuration = try ManagedCoturnConfiguration(
            advertisedHost: "calls.example.org",
            realm: "noctweave",
            sharedSecret: secret
        )

        XCTAssertEqual(
            configuration.iceURLs,
            [
                "stun:calls.example.org:3478",
                "turn:calls.example.org:3478?transport=udp",
                "turn:calls.example.org:3478?transport=tcp"
            ]
        )
    }

    func testManagedConfigurationUsesBoundedPrivateDefaults() throws {
        let configuration = try ManagedCoturnConfiguration(
            advertisedHost: "192.0.2.10",
            externalIPAddress: "203.0.113.25",
            realm: "noctweave",
            sharedSecret: secret,
            listeningPort: 3479,
            minimumRelayPort: 50_000,
            maximumRelayPort: 50_020
        )

        let text = configuration.configurationText
        XCTAssertTrue(text.contains("use-auth-secret"))
        XCTAssertTrue(text.contains("static-auth-secret=\(secret)"))
        XCTAssertTrue(text.contains("external-ip=203.0.113.25"))
        XCTAssertTrue(text.contains("listening-port=3479"))
        XCTAssertTrue(text.contains("min-port=50000"))
        XCTAssertTrue(text.contains("max-port=50020"))
        XCTAssertTrue(text.contains("cli=0"))
        XCTAssertTrue(text.contains("no-tls"))
        XCTAssertFalse(text.contains("no-dtls"))
    }

    func testManagedConfigurationRejectsPrivatePeerDestinations() throws {
        let configuration = try ManagedCoturnConfiguration(
            advertisedHost: "calls.example.org", realm: "noctweave", sharedSecret: secret
        )
        let directives = Set(configuration.configurationText.split(separator: "\n").map(String.init))
        for range in ["10.0.0.0-10.255.255.255", "172.16.0.0-172.31.255.255",
                      "192.168.0.0-192.168.255.255", "100.64.0.0-100.127.255.255",
                      "169.254.0.0-169.254.255.255", "127.0.0.0-127.255.255.255",
                      "fc00::-fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff",
                      "fe80::-feff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"] {
            XCTAssertTrue(directives.contains("denied-peer-ip=\(range)"), range)
        }
        XCTAssertFalse(directives.contains(where: { $0.hasPrefix("allowed-peer-ip=") }))
    }

    func testConfigurationRejectsInjectionAndMalformedHosts() {
        XCTAssertThrowsError(
            try ManagedCoturnConfiguration(
                advertisedHost: "relay.example.org\nno-auth",
                realm: "noctweave",
                sharedSecret: secret
            )
        )
        XCTAssertThrowsError(
            try ManagedCoturnConfiguration(
                advertisedHost: "https://relay.example.org",
                realm: "noctweave",
                sharedSecret: secret
            )
        )
        XCTAssertThrowsError(
            try ManagedCoturnConfiguration(
                advertisedHost: "relay..example.org",
                realm: "noctweave",
                sharedSecret: secret
            )
        )
        XCTAssertThrowsError(
            try ManagedCoturnConfiguration(
                advertisedHost: "relay.example.org",
                realm: "noctweave\nno-auth",
                sharedSecret: secret
            )
        )
    }

    func testConfigurationRejectsInvalidExternalAddressAndPortRange() {
        XCTAssertThrowsError(
            try ManagedCoturnConfiguration(
                advertisedHost: "relay.example.org",
                externalIPAddress: "999.999.999.999",
                realm: "noctweave",
                sharedSecret: secret
            )
        )
        XCTAssertThrowsError(
            try ManagedCoturnConfiguration(
                advertisedHost: "relay.example.org",
                realm: "noctweave",
                sharedSecret: secret,
                minimumRelayPort: 50_100,
                maximumRelayPort: 50_000
            )
        )
    }

    func testIPv6DiscoveryURLsAreBracketed() throws {
        let configuration = try ManagedCoturnConfiguration(
            advertisedHost: "2001:db8::10",
            realm: "noctweave",
            sharedSecret: secret
        )

        XCTAssertEqual(configuration.iceURLs.first, "stun:[2001:db8::10]:3478")
    }

    @MainActor
    func testBundledManagedServiceCanLaunch() async throws {
        // This helper has sandbox-inheritance entitlements. Run this test with
        // normal app signing; an unsigned test host traps before coturn runs.
        let service = ManagedCoturnService.shared
        service.stop()
        let configuration = try ManagedCoturnConfiguration(
            advertisedHost: "127.0.0.1",
            realm: "noctweave-tests",
            sharedSecret: secret,
            listeningPort: 53_478,
            minimumRelayPort: 55_000,
            maximumRelayPort: 55_004
        )

        try await service.start(configuration: configuration)
        defer { service.stop() }

        try await Task.sleep(for: .seconds(10))
        XCTAssertTrue(service.state.isRunning)
        let transientRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoctweaveRelay/ManagedCoturn", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(
            at: transientRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(entries.isEmpty)
    }

    @MainActor
    func testCancellingManagedStartupStopsLaunchedHelper() async throws {
        let service = ManagedCoturnService.shared
        try await service.stopAndRemoveConfiguration()
        let configuration = try ManagedCoturnConfiguration(
            advertisedHost: "127.0.0.1",
            realm: "noctweave-cancellation-test",
            sharedSecret: secret,
            listeningPort: 53_479,
            minimumRelayPort: 55_005,
            maximumRelayPort: 55_009
        )
        var helper: Process?
        let startup = Task {
            try await service.start(configuration: configuration) { process in
                helper = process
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do {
            try await startup.value
            XCTFail("Cancelled startup completed successfully")
        } catch is CancellationError {
        } catch {
            XCTFail("Cancelled startup returned \(error)")
        }
        defer {
            if helper?.isRunning == true { helper?.terminate() }
            service.stop()
        }
        XCTAssertNotNil(helper)
        XCTAssertFalse(helper?.isRunning ?? true, "Cancelled startup left the TURN helper running")
        try await service.stopAndRemoveConfiguration()
    }
}
