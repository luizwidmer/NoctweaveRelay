import XCTest
@testable import Noctweave_Relay

final class ManagedCoturnConfigurationTests: XCTestCase {
    private let secret = "0123456789abcdef0123456789abcdef"

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
        XCTAssertTrue(text.contains("no-cli"))
        XCTAssertTrue(text.contains("no-tls"))
        XCTAssertTrue(text.contains("no-dtls"))
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

        XCTAssertTrue(service.state.isRunning)
        let transientRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoctweaveRelay/ManagedCoturn", isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(
            at: transientRoot,
            includingPropertiesForKeys: nil
        )
        XCTAssertTrue(entries.isEmpty)
    }
}
