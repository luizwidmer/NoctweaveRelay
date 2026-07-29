import Foundation

enum RelayRuntimePolicy {
    static let defaultRendezvousTransportEnabled = false
    static let nativeNoctwebHostingAvailable = true

    static let noctwebAvailabilityDescription =
        "A standard native relay can advertise nw.net-host@1, store signed Noctweb publication bundles, and resolve names for its owned suffix. " +
        "Publishing writes require loopback access, native TLS, or a trusted TLS reverse proxy."

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
