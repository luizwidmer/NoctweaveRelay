import XCTest
@testable import Noctweave_Relay

final class RelayRuntimePolicyTests: XCTestCase {
    func testMinuteSettingsRejectOverflowAndPreserveOrdinaryValues() {
        XCTAssertEqual(RelayRuntimePolicy.seconds(fromPositiveMinutes: 5), 300)
        XCTAssertEqual(RelayRuntimePolicy.seconds(fromPositiveMinutes: Int.max / 60), (Int.max / 60) * 60)
        XCTAssertNil(RelayRuntimePolicy.seconds(fromPositiveMinutes: Int.max / 60 + 1))
        XCTAssertNil(RelayRuntimePolicy.seconds(fromPositiveMinutes: Int.max))
        XCTAssertNil(RelayRuntimePolicy.seconds(fromPositiveMinutes: 0))
        XCTAssertNil(RelayRuntimePolicy.seconds(fromPositiveMinutes: Int.min))
        XCTAssertEqual(RelayRuntimePolicy.minuteSettingSeconds(String(Int.max), fallbackSeconds: 300), 300)
        XCTAssertEqual(RelayRuntimePolicy.minuteSettingSeconds("not a number", fallbackSeconds: 3_600), 3_600)
        XCTAssertEqual(RelayRuntimePolicy.minuteSettingSeconds("0", fallbackSeconds: 300), 60)
        XCTAssertEqual(RelayRuntimePolicy.minuteSettingSeconds("-2", fallbackSeconds: 300), 60)
        XCTAssertEqual(RelayRuntimePolicy.minuteSettingSeconds("60", fallbackSeconds: 300), 3_600)
    }

    func testRendezvousDefaultsToDisabled() {
        XCTAssertFalse(RelayRuntimePolicy.defaultRendezvousTransportEnabled)
    }

    func testNativeRuntimeReportsNoctwebHostingBoundaryClearly() {
        XCTAssertTrue(RelayRuntimePolicy.nativeNoctwebHostingAvailable)
        XCTAssertTrue(RelayRuntimePolicy.noctwebAvailabilityDescription.contains("nw.net-host@1"))
        XCTAssertTrue(
            RelayRuntimePolicy.noctwebAvailabilityDescription
                .contains("trusted TLS reverse proxy")
        )
    }

    func testRemotePlaintextNeverMakesRendezvousEffective() {
        XCTAssertFalse(
            RelayRuntimePolicy.effectiveRendezvousTransportEnabled(
                configured: true,
                securityMode: .plainTCP
            )
        )
        XCTAssertTrue(
            RelayRuntimePolicy.rendezvousAvailabilityDescription(
                configured: true,
                securityMode: .plainTCP
            ).contains("unavailable over remote plaintext TCP")
        )
    }

    func testTrustedReverseProxyIsConfidentialWithoutLocalTLS() {
        XCTAssertTrue(
            RelayRuntimePolicy.effectiveRendezvousTransportEnabled(
                configured: true,
                securityMode: .reverseProxyTLS
            )
        )
        XCTAssertTrue(RelayRuntimePolicy.trustedProxyConfidentialitySignal(.reverseProxyTLS))
        XCTAssertFalse(RelayRuntimePolicy.localListenerUsesTLS(.reverseProxyTLS))
    }

    func testRelayManagedTLSUsesLocalTLSAndEnablesRendezvous() {
        XCTAssertTrue(RelayRuntimePolicy.localListenerUsesTLS(.relayManagedTLS))
        XCTAssertTrue(
            RelayRuntimePolicy.effectiveRendezvousTransportEnabled(
                configured: true,
                securityMode: .relayManagedTLS
            )
        )
    }
}
