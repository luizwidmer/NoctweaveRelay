import XCTest
@testable import Noctweave_Relay

final class RelayRuntimePolicyTests: XCTestCase {
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
