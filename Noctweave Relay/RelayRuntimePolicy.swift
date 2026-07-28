import Foundation

enum RelayRuntimePolicy {
    static let defaultRendezvousTransportEnabled = false
    static let nativeNoctwebHostingAvailable = false

    static let noctwebAvailabilityDescription =
        "This native control plane uses the lightweight relay runtime and does not serve nw.net-host@1. " +
        "Run the full NoctweaveRelayServer or Docker Relay to host Noctweb pages and use its built-in Publisher / Lab."

    static func effectiveRendezvousTransportEnabled(
        configured: Bool,
        securityMode: RelayTransportSecurityMode
    ) -> Bool {
        configured && securityMode != .plainTCP
    }

    static func localListenerUsesTLS(_ securityMode: RelayTransportSecurityMode) -> Bool {
        securityMode == .relayManagedTLS
    }

    static func trustedProxyConfidentialitySignal(
        _ securityMode: RelayTransportSecurityMode
    ) -> Bool {
        securityMode == .reverseProxyTLS
    }

    static func rendezvousAvailabilityDescription(
        configured: Bool,
        securityMode: RelayTransportSecurityMode
    ) -> String {
        guard configured else {
            return "Relay Pairing is disabled. Direct / Offline Pairing remains available."
        }
        guard effectiveRendezvousTransportEnabled(configured: true, securityMode: securityMode) else {
            return "Relay Pairing is unavailable over remote plaintext TCP. Use Relay TLS or a trusted TLS reverse proxy."
        }
        if securityMode == .reverseProxyTLS {
            return "Relay Pairing is advertised through the trusted TLS reverse proxy; the local listener remains plain. Direct / Offline Pairing does not require this service."
        }
        return "Relay Pairing is advertised over the relay's native TLS listener. Direct / Offline Pairing does not require this service."
    }
}
