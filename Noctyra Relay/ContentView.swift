import SwiftUI
import NoctweaveCore
import StoreKit
import Combine

struct ContentView: View {
    @StateObject private var model = ServerViewModel()
    @AppStorage("noctyra.server.acceptedPrivacyPolicy.v1") private var acceptedPrivacyPolicy = false
    @AppStorage("noctyra.server.acceptedTermsOfUse.v1") private var acceptedTermsOfUse = false
    @AppStorage("noctyra.server.permissions.preflight.v1") private var completedPermissionPreflight = false
    @State private var pendingPrivacyAcceptance = false
    @State private var pendingTermsAcceptance = false
    @State private var showingLegalDetails = false
    @State private var showingDonateSheet = false
    @State private var selectedPanel: RelayPanel = .overview

    private enum RelayPanel: String, CaseIterable, Identifiable {
        case overview
        case profile
        case federation
        case storage
        case security
        case logs

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: return "Overview"
            case .profile: return "Relay Profile"
            case .federation: return "Federation"
            case .storage: return "Storage"
            case .security: return "Transport"
            case .logs: return "Logs"
            }
        }

        var symbol: String {
            switch self {
            case .overview: return "gauge.with.dots.needle.67percent"
            case .profile: return "slider.horizontal.3"
            case .federation: return "point.3.connected.trianglepath.dotted"
            case .storage: return "externaldrive"
            case .security: return "lock.shield"
            case .logs: return "text.alignleft"
            }
        }
    }

    private var requiresLegalAcceptance: Bool {
        !acceptedPrivacyPolicy || !acceptedTermsOfUse
    }

    private var requiresPermissionPreflight: Bool {
        !requiresLegalAcceptance && !completedPermissionPreflight
    }

    var body: some View {
        ZStack {
            mainContent
                .blur(radius: requiresLegalAcceptance || requiresPermissionPreflight ? 1.5 : 0)
                .disabled(requiresLegalAcceptance || requiresPermissionPreflight)
            if requiresLegalAcceptance {
                ServerLegalAcceptanceView(
                    acceptedPrivacyPolicy: $pendingPrivacyAcceptance,
                    acceptedTermsOfUse: $pendingTermsAcceptance,
                    onAccept: {
                        acceptedPrivacyPolicy = pendingPrivacyAcceptance
                        acceptedTermsOfUse = pendingTermsAcceptance
                    }
                )
            } else if requiresPermissionPreflight {
                ServerPermissionPreflightView(
                    localNetworkStatus: model.localNetworkPermissionStatus,
                    incomingStatus: model.incomingConnectionPermissionStatus,
                    detailMessage: model.permissionProbeMessage,
                    isRunningProbe: model.permissionProbeRunning,
                    canContinue: model.permissionPreflightReady,
                    onRequest: { model.runStartupPermissionProbe() },
                    onContinue: { completedPermissionPreflight = true }
                )
            }
        }
        .onAppear {
            pendingPrivacyAcceptance = acceptedPrivacyPolicy
            pendingTermsAcceptance = acceptedTermsOfUse
            if requiresPermissionPreflight && !model.permissionProbeHasRun {
                model.runStartupPermissionProbe()
            }
        }
    }

    private var mainContent: some View {
        ZStack {
            PremiumRelayBackground()

            HStack(spacing: 0) {
                relaySidebar

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            serverHeader
                                .id(RelayPanel.overview)

                            serverCard(
                        title: "Relay Profile",
                        subtitle: "Identity, mode, and operator metadata",
                        icon: "person.text.rectangle"
                    ) {
                        HStack {
                            Text("Relay Kind")
                            Spacer()
                            Picker("Relay Kind", selection: $model.relayKind) {
                                ForEach(RelayKind.allCases, id: \.self) { kind in
                                    Text(kind.rawValue.capitalized).tag(kind)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 220)
                        }
                        if model.federationMode == .manual {
                            Text("Manual federation accepts standard relays only. Set Relay Kind to Standard before starting.")
                                .font(.caption2)
                                .foregroundStyle(model.relayKind == .standard ? Color.secondary : Color.orange)
                        }
                        HStack {
                            Text("Federation Mode")
                            Spacer()
                            Picker("Federation Mode", selection: $model.federationMode) {
                                ForEach(FederationMode.allCases, id: \.self) { mode in
                                    Text(mode.rawValue.capitalized).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 220)
                        }
                        HStack {
                            Text("Bucket Strategy")
                            Spacer()
                            Picker("Bucket Strategy", selection: $model.temporalBucketMode) {
                                ForEach(RelayTemporalBucketMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 220)
                        }
                        if model.temporalBucketMode == .disabled {
                            Text("Temporal bucketing is disabled. This improves delivery immediacy but exposes precise relay arrival timing.")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        } else if model.temporalBucketMode == .single {
                            HStack {
                                Text("Temporal Bucket (minutes)")
                                Spacer()
                                TextField("5", text: $model.temporalBucketMinutes)
                                    .relayFieldStyle()
                                    .frame(width: 92)
                            }
                            Text("Single fixed bucket for all envelope timestamps.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            HStack {
                                Text("Multi-Bucket Schedule (minutes)")
                                Spacer()
                                TextField("2,5,11", text: $model.temporalBucketScheduleMinutes)
                                    .relayFieldStyle()
                                    .frame(width: 180)
                            }
                            Text("Comma-separated list. Relay picks one bucket per message to reduce timing correlation.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Toggle("Allow image and voice attachments", isOn: $model.attachmentsEnabled)
                        if model.attachmentsEnabled {
                            HStack {
                                Text("Attachment Default TTL (minutes)")
                                Spacer()
                                TextField("60", text: $model.attachmentDefaultTTLMinutes)
                                    .relayFieldStyle()
                                    .frame(width: 92)
                            }
                            HStack {
                                Text("Attachment Max TTL (minutes)")
                                Spacer()
                                TextField("360", text: $model.attachmentMaxTTLMinutes)
                                    .relayFieldStyle()
                                    .frame(width: 92)
                            }
                        }
                        Text(model.attachmentsEnabled
                             ? "Attachment uploads are capped by relay policy to control storage growth."
                             : "Text-only mode rejects attachment upload and download routes.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Toggle("Advertise hidden retrieval", isOn: $model.hiddenRetrievalEnabled)
                        if model.hiddenRetrievalEnabled {
                            Picker("Mode", selection: $model.hiddenRetrievalMode) {
                                Text("Cover Query").tag(HiddenRetrievalMode.coverQuery)
                                Text("Replicated XOR-PIR").tag(HiddenRetrievalMode.replicatedXorPIR)
                            }
                            .pickerStyle(.segmented)
                            HStack {
                                Text("Default Cover Set")
                                Spacer()
                                TextField("8", text: $model.hiddenRetrievalCoverSize)
                                    .relayFieldStyle()
                                    .frame(width: 92)
                            }
                            HStack {
                                Text("Max Cover Set")
                                Spacer()
                                TextField("32", text: $model.hiddenRetrievalMaxCoverSize)
                                    .relayFieldStyle()
                                    .frame(width: 92)
                            }
                        }
                        Text(model.hiddenRetrievalEnabled
                             ? "Cover-query mode requests fixed-size decoy sets. Replicated XOR-PIR mode is for non-colluding replicated buckets and hides the target from any single replica."
                             : "Hidden retrieval is not advertised. Clients use normal authenticated fetch.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Toggle("Advertise onion transport", isOn: $model.onionTransportEnabled)
                        if model.onionTransportEnabled {
                            HStack {
                                Text("Max Hops")
                                Spacer()
                                TextField("3", text: $model.onionTransportMaxHops)
                                    .relayFieldStyle()
                                    .frame(width: 92)
                            }
                            Toggle("Require fixed-size packets", isOn: $model.onionTransportRequiresFixedSizePackets)
                        }
                        Text(model.onionTransportEnabled
                             ? "Advertises support for PQ onion packet construction. This is a hop-by-hop privacy primitive, not a full mixnet scheduler."
                             : "Onion transport is not advertised.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Toggle("Advertise mixnet scheduling", isOn: $model.mixnetTransportEnabled)
                        if model.mixnetTransportEnabled {
                            HStack {
                                Text("Batch Interval (seconds)")
                                Spacer()
                                TextField("30", text: $model.mixnetBatchIntervalSeconds)
                                    .relayFieldStyle()
                                    .frame(width: 92)
                            }
                            HStack {
                                Text("Min Batch Size")
                                Spacer()
                                TextField("8", text: $model.mixnetMinBatchSize)
                                    .relayFieldStyle()
                                    .frame(width: 92)
                            }
                            HStack {
                                Text("Cover Packets")
                                Spacer()
                                TextField("2", text: $model.mixnetCoverPacketsPerBatch)
                                    .relayFieldStyle()
                                    .frame(width: 92)
                            }
                            HStack {
                                Text("Max Delay (seconds)")
                                Spacer()
                                TextField("120", text: $model.mixnetMaxDelaySeconds)
                                    .relayFieldStyle()
                                    .frame(width: 92)
                            }
                        }
                        Text(model.mixnetTransportEnabled
                             ? "Advertises deterministic batching, bounded release delay, and cover-packet scheduling for compatible clients. This still requires compatible multi-relay paths to behave like a network mixnet."
                             : "Mixnet scheduling is not advertised.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Toggle("Advertise decentralized wake policy", isOn: $model.wakeModeEnabled)
                        if model.wakeModeEnabled {
                            HStack {
                                Text("Wake Mode")
                                Spacer()
                                Picker("Wake Mode", selection: $model.wakeMode) {
                                    ForEach(DecentralizedWakeMode.allCases, id: \.self) { mode in
                                        Text(mode.rawValue).tag(mode)
                                    }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 180)
                            }
                            HStack {
                                Text("Min Poll")
                                Spacer()
                                TextField("60", text: $model.wakeMinPollSeconds)
                                    .relayFieldStyle()
                                    .frame(width: 92)
                            }
                            HStack {
                                Text("Max Poll")
                                Spacer()
                                TextField("300", text: $model.wakeMaxPollSeconds)
                                    .relayFieldStyle()
                                    .frame(width: 92)
                            }
                            HStack {
                                Text("Jitter Permille")
                                Spacer()
                                TextField("250", text: $model.wakeJitterPermille)
                                    .relayFieldStyle()
                                    .frame(width: 92)
                            }
                            if model.wakeMode == .longPoll {
                                HStack {
                                    Text("Long-Poll Timeout")
                                    Spacer()
                                    TextField("60", text: $model.wakeLongPollTimeoutSeconds)
                                        .relayFieldStyle()
                                        .frame(width: 92)
                                }
                            }
                        }
                        Text(model.wakeModeEnabled
                             ? "Clients can schedule jittered pull or long-poll fetches without a centralized push server."
                             : "No wake policy is advertised. Clients fall back to local polling defaults.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HStack {
                            Text("Group Creation")
                            Spacer()
                            Picker("Group Creation", selection: $model.groupCreationMode) {
                                ForEach(GroupCreationMode.allCases, id: \.self) { mode in
                                    Text(mode.rawValue.capitalized).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 220)
                        }
                        Text("Controls whether this relay accepts group registry creation requests.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HStack {
                            Text("Group Security Model")
                            Spacer()
                            Picker("Group Security Model", selection: $model.groupSecurityModel) {
                                ForEach(GroupSecurityModel.allCases, id: \.self) { model in
                                    Text(model.rawValue).tag(model)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 220)
                        }
                        Text(model.groupSecurityModel == .mlsDerivedTree
                             ? "Advertises the MLS-derived target model. Enable only with compatible group clients."
                             : "Current deployed group model: relay-backed membership with end-to-end encrypted pairwise delivery.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Divider().opacity(0.2)
                        TextField("Relay Name (optional)", text: $model.relayName)
                            .relayFieldStyle()
                        TextField("Operator Message (optional)", text: $model.operatorNote)
                            .relayFieldStyle()
                        Text("Software: \(model.softwareVersion)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(model.isRunning)
                    .id(RelayPanel.profile)

                    if model.federationMode != .solo {
                        serverCard(
                            title: model.federationMode == .manual ? "Manual Federation" : "Federation Source",
                            subtitle: model.federationMode == .manual ? "Operator-managed standard relay node list" : "Managed from remote JSON over HTTPS",
                            icon: "point.3.connected.trianglepath.dotted"
                        ) {
                            if model.federationMode == .manual {
                                Text("Add each federated standard relay explicitly. Manual mode does not use coordinators, DHT, peer exchange, or automatic discovery.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                manualFederationNodeEditor
                            } else {
                                TextField("https://example.org/federation.json", text: $model.federationSourceURL)
                                    .relayFieldStyle()
                                HStack(spacing: 8) {
                                    Button("Fetch Federation") {
                                        model.fetchFederationSource()
                                    }
                                    .relayButton(prominent: true)
                                    if let status = model.federationSourceStatus, !status.isEmpty {
                                        Text(status)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if let updated = model.federationSourceLastUpdated {
                                        Text("Updated \(formatUpdated(updated))")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Text("JSON may include mode, name, description, and allowlist entries (host:port or https URL).")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Divider().opacity(0.2)
                            if model.federationMode != .manual {
                                TextField("Federated nodes (comma-separated host:port, tls://, http://, or https://)", text: $model.federationAllowList)
                                    .relayFieldStyle()
                            }
                            SecureField("Inter-relay forwarding token (optional)", text: $model.federationForwardingAuthToken)
                                .relayFieldStyle()
                            Text("Used only for relay-to-relay forwarding authentication. Client passwords are never forwarded upstream.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if model.federationMode != .manual {
                                TextField("Coordinator endpoints (comma-separated host:port or https URL)", text: $model.federationCoordinatorList)
                                    .relayFieldStyle()
                                TextField("Coordinator signing keys (base64, aligned with endpoints)", text: $model.federationCoordinatorPublicKeys)
                                    .relayFieldStyle()
                                SecureField("Coordinator registration token (optional shared secret)", text: $model.coordinatorRegistrationToken)
                                    .relayFieldStyle()
                            }
                            if model.federationMode == .open {
                                Toggle(
                                    "Allow private/LAN federation endpoints",
                                    isOn: $model.allowPrivateFederationEndpoints
                                )
                                Text("Disabled by default to prevent open-federation requests from probing localhost or private networks. Enable only for an isolated development federation.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Divider().opacity(0.2)
                                Toggle("Become an open-federation DHT node", isOn: $model.openFederationDHTEnabled)
                                Text(model.openFederationDHTEnabled
                                     ? "This relay accepts and serves signed short-lived DHT relay records for the selected open federation namespace."
                                     : "DHT routes remain disabled. The relay can still use coordinators and bounded peer exchange if configured.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                if model.openFederationDHTEnabled {
                                    HStack {
                                        Text("DHT Max Records")
                                        Spacer()
                                        TextField("256", text: $model.openFederationDHTMaxRecords)
                                            .relayFieldStyle()
                                            .frame(width: 92)
                                    }
                                    HStack {
                                        Text("DHT Records Per Host")
                                        Spacer()
                                        TextField("4", text: $model.openFederationDHTMaxRecordsPerHost)
                                            .relayFieldStyle()
                                            .frame(width: 92)
                                    }
                                    HStack {
                                        Text("DHT Query Limit")
                                        Spacer()
                                        TextField("256", text: $model.openFederationDHTMaxQueryRecords)
                                            .relayFieldStyle()
                                            .frame(width: 92)
                                    }
                                }
                                HStack {
                                    Text("Peer Exchange Limit")
                                    Spacer()
                                    TextField("12", text: $model.relayPeerExchangeLimit)
                                        .relayFieldStyle()
                                        .frame(width: 92)
                                }
                                Text("PEX advertises a bounded list of already-known open relays through /info. Set to 0 to disable peer hints.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if model.federationMode != .manual {
                                HStack {
                                    Text("Heartbeat (seconds)")
                                    Spacer()
                                    TextField("45", text: $model.coordinatorHeartbeatSeconds)
                                        .relayFieldStyle()
                                        .frame(width: 92)
                                }
                                HStack {
                                    Text("Directory Max Staleness")
                                    Spacer()
                                    TextField("300", text: $model.coordinatorDirectoryMaxStalenessSeconds)
                                        .relayFieldStyle()
                                        .frame(width: 92)
                                }
                                Text("Coordinator directory entries older than this are ignored by clients and relays.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Manual mode forwards only to nodes in this list after they report federation mode manual and relay kind standard.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if model.federationMode == .curated {
                                Divider().opacity(0.2)
                                Toggle("Curated Strict Policy", isOn: $model.curatedStrictPolicyEnabled)
                                Toggle("Require Signed Directory", isOn: $model.curatedRequireSignedDirectory)
                                HStack {
                                    Text("Coordinator Quorum")
                                    Spacer()
                                    TextField("1", text: $model.curatedCoordinatorQuorum)
                                        .relayFieldStyle()
                                        .frame(width: 92)
                                }
                                Text("Strict policy enforces allowlist membership plus coordinator directory quorum before relay-to-relay forwarding.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Federation Details")
                                    .font(.subheadline.weight(.semibold))
                                federationDetailRow("Name", value: model.federationName)
                                federationDetailRow("Description", value: model.federationDescription)
                                federationDetailRow(model.federationMode == .manual ? "Manual Nodes" : "Allow List", value: model.federationAllowList)
                                if model.federationMode != .manual {
                                    federationDetailRow("Coordinators", value: model.federationCoordinatorList)
                                    federationDetailRow("Registration Auth", value: model.coordinatorRegistrationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Disabled" : "Token required")
                                }
                                federationDetailRow(
                                    "Inter-relay Auth",
                                    value: model.federationForwardingAuthToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Disabled" : "Token configured"
                                )
                                if model.federationMode == .open {
                                    federationDetailRow("DHT Node", value: model.openFederationDHTEnabled ? "Enabled" : "Disabled")
                                    federationDetailRow("PEX Limit", value: model.relayPeerExchangeLimit)
                                }
                                if model.federationMode == .curated {
                                    federationDetailRow("Strict Policy", value: model.curatedStrictPolicyEnabled ? "Enabled" : "Disabled")
                                    federationDetailRow("Require Signed", value: model.curatedRequireSignedDirectory ? "Yes" : "No")
                                    federationDetailRow("Quorum", value: model.curatedCoordinatorQuorum)
                                }
                            }
                        }
                        .disabled(model.isRunning)
                        .id(RelayPanel.federation)
                    }

                    serverCard(
                        title: "Storage",
                        subtitle: "Choose persistence strategy for relay state",
                        icon: "externaldrive.badge.checkmark"
                    ) {
                        Picker("Store Method", selection: $model.storageMode) {
                            Text("Disk").tag(RelayStorageMode.disk)
                            Text("RAM").tag(RelayStorageMode.memory)
                        }
                        .pickerStyle(.segmented)
                        if model.storageMode == .disk {
                            HStack(spacing: 8) {
                                TextField("Store file path", text: $model.storePath)
                                    .relayFieldStyle()
                                Button("Choose…") { model.chooseStorePath() }
                                    .relayButton()
                                Button("Default") { model.resetStorePathToDefault() }
                                    .relayButton()
                            }
                            Text("Disk mode persists relay state at the selected path.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(model.storageLocationDescription)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("RAM mode is ephemeral. Queues and prekeys are lost when the relay stops.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Max Inbox Messages")
                                    .font(.subheadline.weight(.semibold))
                                Text("Caps queued encrypted envelopes per inbox before the relay rejects new deliveries.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            TextField("1000", text: $model.maxInboxMessages)
                                .relayFieldStyle()
                                .frame(width: 92)
                        }
                        Divider()
                            .overlay(.white.opacity(0.08))
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Attachment Blob Storage")
                                    .font(.subheadline.weight(.semibold))
                                Text(model.attachmentStorageDescription)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Picker("Attachment Blob Storage", selection: $model.attachmentStorageBackend) {
                                ForEach(RelayAttachmentStorageBackend.allCases) { backend in
                                    Text(backend.displayName).tag(backend)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 220)
                            .disabled(!model.attachmentsEnabled)
                        }
                        if model.attachmentsEnabled, model.attachmentStorageBackend == .ipfs {
                            HStack {
                                Text("IPFS API")
                                Spacer()
                                TextField("http://127.0.0.1:5001", text: $model.ipfsAPIEndpoint)
                                    .relayFieldStyle()
                                    .frame(width: 260)
                            }
                            HStack {
                                Text("Gateway Fallback")
                                Spacer()
                                TextField("http://127.0.0.1:8080", text: $model.ipfsGatewayEndpoint)
                                    .relayFieldStyle()
                                    .frame(width: 260)
                            }
                            HStack {
                                Text("IPFS Timeout (seconds)")
                                Spacer()
                                TextField("10", text: $model.ipfsTimeoutSeconds)
                                    .relayFieldStyle()
                                    .frame(width: 92)
                            }
                            Text("IPFS offload pins encrypted chunks through the configured API. TTL cleanup removes relay metadata and attempts to unpin, but external IPFS peers may retain blocks.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(model.isRunning)
                    .id(RelayPanel.storage)

                    serverCard(
                        title: "Transport Security",
                        subtitle: "Communication protocol, TLS, and relay password",
                        icon: "lock.shield"
                    ) {
                        HStack {
                            Text("Protocol")
                            Spacer()
                            Picker("Protocol", selection: $model.communicationMode) {
                                ForEach(RelayCommunicationMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 300)
                        }
                        Text(model.communicationMode == .http
                            ? "HTTP mode exposes POST /relay (and GET /health, GET /info), ideal behind standard HTTPS reverse proxies."
                            : "TCP frame mode uses the native relay protocol directly, ideal for LAN or TCP stream proxies.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Divider().opacity(0.2)

                        HStack {
                            Text("Mode")
                            Spacer()
                            Picker("Transport Security Mode", selection: $model.transportSecurityMode) {
                                ForEach(RelayTransportSecurityMode.allCases) { mode in
                                    Text(mode.displayName).tag(mode)
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 300)
                        }
                        if model.transportSecurityMode == .relayManagedTLS {
                            HStack(spacing: 8) {
                                TextField("PKCS#12 identity path (.p12/.pfx)", text: $model.tlsIdentityPKCS12Path)
                                    .relayFieldStyle()
                                Button("Choose…") { model.chooseTLSIdentityPath() }
                                    .relayButton()
                            }
                            SecureField("PKCS#12 password (if any)", text: $model.tlsIdentityPassword)
                                .relayFieldStyle()
                            Text("TLS requires a PKCS#12 identity containing relay key + certificate chain.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else if model.transportSecurityMode == .reverseProxyTLS {
                            Text(model.communicationMode == .http
                                ? "TLS is terminated at your reverse proxy. The relay listens on plain HTTP behind it, so no local PKCS#12 certificate is required."
                                : "TLS is terminated at your reverse proxy. The relay listens on plain TCP behind it, so no local PKCS#12 certificate is required.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(model.communicationMode == .http
                                ? "Use HTTPS proxying to the relay's internal HTTP endpoint. This is compatible with standard Cloudflare and reverse proxy setups."
                                : "Use a TCP stream proxy (for example: NGINX stream, HAProxy TCP, or Cloudflare Spectrum). HTTP-only proxies cannot carry raw TCP frames.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text(model.communicationMode == .http
                                ? "Relay serves plain HTTP with no transport encryption."
                                : "Relay serves plain TCP with no transport encryption.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }

                        Divider().opacity(0.2)

                        TextField("Advertised endpoint (optional, e.g. tls://relay.example.org:443)", text: $model.advertisedEndpoint)
                            .relayFieldStyle()
                        Text("Used for coordinator registration and external discovery. Required in Proxy TLS mode.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                        Divider().opacity(0.2)

                        SecureField("Relay Password (optional)", text: $model.relayPassword)
                            .relayFieldStyle()
                        SecureField("Confirm Relay Password", text: $model.relayPasswordConfirmation)
                            .relayFieldStyle()
                        Text("When set, clients must provide this password for non-info requests.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)

                    }
                    .disabled(model.isRunning)
                    .id(RelayPanel.security)

                    serverCard(
                        title: "Relay Logs",
                        subtitle: "Recent runtime events",
                        icon: "text.append"
                    ) {
                        if model.logs.isEmpty {
                            Text("No logs yet.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 6) {
                                    ForEach(Array(model.logs.suffix(250).reversed()), id: \.self) { entry in
                                        Text(entry)
                                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(
                                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                    .fill(
                                                        LinearGradient(
                                                            colors: [
                                                                Color.black.opacity(0.28),
                                                                Color.indigo.opacity(0.14)
                                                            ],
                                                            startPoint: .topLeading,
                                                            endPoint: .bottomTrailing
                                                        )
                                                    )
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                            .stroke(Color.white.opacity(0.08), lineWidth: 0.7)
                                                    )
                                            )
                                    }
                                }
                            }
                            .frame(minHeight: 180, maxHeight: 260)
                        }
                    }
                    .id(RelayPanel.logs)
                        }
                        .padding(20)
                        .frame(maxWidth: 980, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .onChange(of: selectedPanel) { _, panel in
                        withAnimation(.easeInOut(duration: 0.28)) {
                            proxy.scrollTo(panel, anchor: .top)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .alert("Error", isPresented: Binding(get: { model.lastError != nil }, set: { _ in model.lastError = nil })) {
            Button("OK") {}
        } message: {
            Text(model.lastError ?? "")
        }
        .sheet(isPresented: $showingLegalDetails) {
            ServerLegalDocumentView()
        }
        .sheet(isPresented: $showingDonateSheet) {
            RelayDonationSheetView()
        }
    }

    private var relaySidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.cyan)
                Text(model.relayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Noctyra Relay"
                    : model.relayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(2)
                Text("Control Plane")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)

            VStack(spacing: 6) {
                ForEach(RelayPanel.allCases) { panel in
                    if panel != .federation || model.federationMode != .solo {
                        Button {
                            selectedPanel = panel
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: panel.symbol)
                                    .frame(width: 18)
                                Text(panel.title)
                                    .font(.subheadline.weight(selectedPanel == panel ? .semibold : .regular))
                                Spacer()
                            }
                            .foregroundStyle(selectedPanel == panel ? Color.white : Color.secondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(selectedPanel == panel ? Color.indigo.opacity(0.34) : Color.clear)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                                            .stroke(selectedPanel == panel ? Color.white.opacity(0.14) : Color.clear, lineWidth: 0.8)
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Label(
                    model.isRunning ? "Relay online" : "Relay stopped",
                    systemImage: model.isRunning ? "checkmark.circle.fill" : "pause.circle"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(model.isRunning ? Color.green : Color.secondary)
                Text(endpointPreview)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            .padding(12)
            .premiumSurface(cornerRadius: 14, tintOpacity: 0.10)
        }
        .padding(14)
        .frame(width: 210)
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 0.5)
        }
    }

    private var serverHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Noctyra Relay", systemImage: "dot.radiowaves.left.and.right")
                        .font(.title3.weight(.semibold))
                    Text("Control plane for transport, federation, storage, and security.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                statusBadges
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    listenerFields
                    headerActions
                }
                VStack(alignment: .leading, spacing: 10) {
                    listenerFields
                    headerActions
                }
            }
            Text("Endpoint preview: \(endpointPreview)")
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(16)
        .premiumSurface(cornerRadius: 20, tintOpacity: 0.22)
    }

    private var statusBadges: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                runningStatusBadge
                transportStatusBadge
                protocolStatusBadge
                permissionStatusBadge
            }
            VStack(alignment: .trailing, spacing: 7) {
                HStack(spacing: 8) {
                    runningStatusBadge
                    transportStatusBadge
                }
                HStack(spacing: 8) {
                    protocolStatusBadge
                    permissionStatusBadge
                }
            }
        }
    }

    private var runningStatusBadge: some View {
        statusBadge(
            model.isRunning ? "Running" : "Stopped",
            icon: model.isRunning ? "checkmark.circle.fill" : "pause.circle.fill",
            color: model.isRunning ? .green : .secondary
        )
    }

    private var transportStatusBadge: some View {
        statusBadge(
            model.transportSecurityMode == .relayManagedTLS
                ? "Relay TLS"
                : (model.transportSecurityMode == .reverseProxyTLS
                    ? "Proxy TLS"
                    : (model.communicationMode == .http ? "Plain HTTP" : "Plain TCP")),
            icon: model.transportSecurityMode == .plainTCP ? "lock.open" : "lock.fill",
            color: model.transportSecurityMode == .plainTCP ? .orange : .mint
        )
    }

    private var protocolStatusBadge: some View {
        statusBadge(
            model.communicationMode == .http ? "HTTP" : "TCP",
            icon: model.communicationMode == .http ? "network" : "arrow.left.arrow.right",
            color: model.communicationMode == .http ? .cyan : .secondary
        )
    }

    private var permissionStatusBadge: some View {
        statusBadge(
            permissionSummaryLabel,
            icon: permissionSummaryIcon,
            color: permissionSummaryColor
        )
    }

    private var listenerFields: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Listen Address")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("0.0.0.0", text: $model.host)
                    .relayFieldStyle()
                    .frame(width: 190)
                    .disabled(model.isRunning)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Port")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("9339", text: $model.port)
                    .relayFieldStyle()
                    .frame(width: 100)
                    .disabled(model.isRunning)
            }
        }
    }

    private var headerActions: some View {
        HStack(spacing: 8) {
            Button {
                if model.isRunning {
                    model.stop()
                } else {
                    model.start()
                }
            } label: {
                Label(
                    model.isRunning ? "Stop" : "Start",
                    systemImage: model.isRunning ? "stop.fill" : "play.fill"
                )
            }
            .relayButton(prominent: true)

            Button {
                model.runStartupPermissionProbe()
            } label: {
                Label(
                    model.permissionProbeRunning ? "Checking..." : "Permissions",
                    systemImage: "checklist"
                )
            }
            .relayButton()
            .disabled(model.permissionProbeRunning)

            Menu {
                Button {
                    showingLegalDetails = true
                } label: {
                    Label("Policies", systemImage: "doc.text")
                }
                Button {
                    showingDonateSheet = true
                } label: {
                    Label("Donate", systemImage: "heart.fill")
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .relayButton()
            .fixedSize()
        }
    }

    private var manualFederationNodeEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("relay.example.org:9339 or https://relay.example.org", text: $model.manualFederationEndpointDraft)
                    .relayFieldStyle()
                    .onSubmit {
                        model.addManualFederationNode()
                    }
                Button {
                    model.addManualFederationNode()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .relayButton(prominent: true)
                .disabled(!model.canAddManualFederationNode)
                .help("Add federated relay")
            }

            VStack(spacing: 0) {
                HStack {
                    Text("Federated Relay")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(model.manualFederationNodes.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.045))

                if model.manualFederationNodes.isEmpty {
                    Text("No federated relays added.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 12)
                } else {
                    ForEach(Array(model.manualFederationNodes.enumerated()), id: \.offset) { index, endpoint in
                        let healthStatus = model.manualFederationHealth[endpoint] ?? .idle
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(endpoint)
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                manualFederationHealthView(healthStatus)
                            }
                            Spacer()
                            Button {
                                model.checkManualFederationNodeHealth(endpoint)
                            } label: {
                                Image(systemName: "waveform.path.ecg")
                                    .font(.system(size: 12, weight: .bold))
                                    .frame(width: 24, height: 24)
                            }
                            .relayButton()
                            .disabled(healthStatus == .checking)
                            .help("Check federation health")
                            Button {
                                model.removeManualFederationNode(at: index)
                            } label: {
                                Image(systemName: "minus")
                                    .font(.system(size: 12, weight: .bold))
                                    .frame(width: 24, height: 24)
                            }
                            .relayButton()
                            .help("Remove federated relay")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        if index < model.manualFederationNodes.count - 1 {
                            Divider().opacity(0.18)
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.8)
            )
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.black.opacity(0.18))
            )
        }
    }

    @ViewBuilder
    private func manualFederationHealthView(_ status: FederatedRelayHealthStatus) -> some View {
        let display = manualFederationHealthDisplay(status)
        HStack(spacing: 6) {
            Image(systemName: display.icon)
                .font(.system(size: 10, weight: .semibold))
            Text(display.title)
                .font(.caption2.weight(.semibold))
            if let detail = display.detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .foregroundStyle(display.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(display.color.opacity(0.12))
        )
    }

    private func manualFederationHealthDisplay(_ status: FederatedRelayHealthStatus) -> (title: String, detail: String?, icon: String, color: Color) {
        switch status {
        case .idle:
            return (status.title, status.detail, "circle.dashed", .secondary)
        case .checking:
            return (status.title, status.detail, "arrow.triangle.2.circlepath", .cyan)
        case .healthy:
            return (status.title, status.detail, "checkmark.circle.fill", .green)
        case .failed:
            return (status.title, status.detail, "exclamationmark.triangle.fill", .orange)
        }
    }

    private func federationDetailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(title):")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.24))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.7)
                )
        )
    }

    private func serverCard<Content: View>(
        title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: icon)
                    .font(.headline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Divider().opacity(0.2)
            content()
        }
        .padding(16)
        .premiumSurface(cornerRadius: 18, tintOpacity: 0.16)
    }

    private var endpointPreview: String {
        let host = model.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = model.port.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedHost = host.isEmpty ? "0.0.0.0" : host
        let resolvedPort = port.isEmpty ? "9339" : port
        let listenerScheme: String
        switch model.communicationMode {
        case .tcp:
            listenerScheme = model.transportSecurityMode == .relayManagedTLS ? "tls" : "tcp"
        case .http:
            listenerScheme = model.transportSecurityMode == .relayManagedTLS ? "https" : "http"
        }
        let listener = "\(listenerScheme)://\(resolvedHost):\(resolvedPort)"
        let advertised = model.advertisedEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.transportSecurityMode == .reverseProxyTLS {
            if advertised.isEmpty {
                return "\(listener) (advertised endpoint required)"
            }
            return "\(listener) -> \(advertised)"
        }
        if !advertised.isEmpty {
            return "\(listener) (advertised: \(advertised))"
        }
        return listener
    }

    private func statusBadge(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(0.16))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(color.opacity(0.35), lineWidth: 0.7)
                    )
            )
    }

    private var permissionSummaryLabel: String {
        if model.permissionProbeRunning {
            return "Permissions: Checking"
        }
        switch (model.localNetworkPermissionStatus, model.incomingConnectionPermissionStatus) {
        case (.granted, .granted):
            return "Permissions: OK"
        case (.idle, .idle):
            return "Permissions: Not checked"
        case (.denied, _), (_, .denied):
            return "Permissions: Denied"
        case (.failed, _), (_, .failed):
            return "Permissions: Failed"
        default:
            return "Permissions: Partial"
        }
    }

    private var permissionSummaryIcon: String {
        if model.permissionProbeRunning {
            return "clock"
        }
        switch (model.localNetworkPermissionStatus, model.incomingConnectionPermissionStatus) {
        case (.granted, .granted):
            return "checkmark.shield.fill"
        case (.denied, _), (_, .denied):
            return "exclamationmark.triangle.fill"
        case (.failed, _), (_, .failed):
            return "xmark.octagon.fill"
        default:
            return "shield"
        }
    }

    private var permissionSummaryColor: Color {
        if model.permissionProbeRunning {
            return .yellow
        }
        switch (model.localNetworkPermissionStatus, model.incomingConnectionPermissionStatus) {
        case (.granted, .granted):
            return .green
        case (.denied, _), (_, .denied):
            return .orange
        case (.failed, _), (_, .failed):
            return .red
        default:
            return .secondary
        }
    }
}

private struct PremiumRelayBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.black.opacity(0.94),
                    Color.indigo.opacity(0.26),
                    Color.black.opacity(0.90)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [
                    Color.cyan.opacity(0.16),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 40,
                endRadius: 420
            )
            RadialGradient(
                colors: [
                    Color.blue.opacity(0.12),
                    Color.clear
                ],
                center: .bottomTrailing,
                startRadius: 60,
                endRadius: 520
            )
        }
        .ignoresSafeArea()
    }
}

private struct RelayPremiumSurface: ViewModifier {
    let cornerRadius: CGFloat
    let tintOpacity: Double

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.black.opacity(0.24),
                                        Color.indigo.opacity(tintOpacity),
                                        Color.black.opacity(0.16)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.16), lineWidth: 0.8)
                    )
                    .shadow(color: .black.opacity(0.24), radius: 16, x: 0, y: 7)
            )
    }
}

private struct RelayGlassButtonStyle: ButtonStyle {
    let prominent: Bool
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: prominent
                                        ? [
                                            Color.indigo.opacity(configuration.isPressed ? 0.48 : 0.38),
                                            Color.cyan.opacity(configuration.isPressed ? 0.24 : 0.18)
                                        ]
                                        : [
                                            Color.white.opacity(configuration.isPressed ? 0.10 : 0.05),
                                            Color.indigo.opacity(configuration.isPressed ? 0.15 : 0.09)
                                        ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(
                                isHovering
                                    ? Color.cyan.opacity(prominent ? 0.56 : 0.34)
                                    : Color.white.opacity(prominent ? 0.20 : 0.12),
                                lineWidth: isHovering ? 1.0 : 0.8
                            )
                    )
            )
            .shadow(
                color: Color.cyan.opacity(isHovering && isEnabled ? 0.18 : 0.06),
                radius: isHovering ? 10 : 4,
                y: isHovering ? 4 : 2
            )
            .scaleEffect(configuration.isPressed ? 0.98 : (isHovering ? 1.012 : 1))
            .opacity(isEnabled ? 1 : 0.42)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.16), value: isHovering)
            .onHover { isHovering = $0 }
    }
}

private extension View {
    func premiumSurface(cornerRadius: CGFloat = 16, tintOpacity: Double = 0.14) -> some View {
        modifier(RelayPremiumSurface(cornerRadius: cornerRadius, tintOpacity: tintOpacity))
    }

    func relayFieldStyle() -> some View {
        self
            .textFieldStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.26))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 0.7)
                    )
            )
    }

    func relayButton(prominent: Bool = false) -> some View {
        buttonStyle(RelayGlassButtonStyle(prominent: prominent))
    }
}

private func formatUpdated(_ date: Date) -> String {
    updatedFormatter.string(from: date)
}

private let updatedFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
}()

private struct RelaySheetTopBar<Trailing: View>: View {
    let onClose: () -> Void
    @ViewBuilder let trailing: () -> Trailing

    init(onClose: @escaping () -> Void, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.onClose = onClose
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 18, height: 18)
            }
            .accessibilityLabel("Close")
            .relayButton()
            Spacer()
            trailing()
        }
    }
}

private extension RelaySheetTopBar where Trailing == EmptyView {
    init(onClose: @escaping () -> Void) {
        self.init(onClose: onClose) { EmptyView() }
    }
}

private struct RelaySheetHero: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.cyan)
                .frame(width: 44, height: 44)
                .background(Color.cyan.opacity(0.13), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .premiumSurface(cornerRadius: 18, tintOpacity: 0.18)
    }
}

private struct RelaySheetSection<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.headline)
            content()
        }
        .padding(16)
        .premiumSurface(cornerRadius: 16, tintOpacity: 0.12)
    }
}

private struct ServerPermissionPreflightView: View {
    let localNetworkStatus: StartupPermissionStatus
    let incomingStatus: StartupPermissionStatus
    let detailMessage: String?
    let isRunningProbe: Bool
    let canContinue: Bool
    let onRequest: () -> Void
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                RelaySheetHero(
                    icon: "checkmark.shield.fill",
                    title: "Permissions Check",
                    subtitle: "Confirm networking access before starting the relay."
                )

                RelaySheetSection(title: "Required Access", icon: "network") {
                    permissionRow(
                        title: "Local network",
                        subtitle: "Federation discovery, health checks, and relay-to-relay communication.",
                        status: localNetworkStatus
                    )
                    permissionRow(
                        title: "Incoming listener",
                        subtitle: "Inbound client and inter-relay connections.",
                        status: incomingStatus
                    )
                }

                if let detailMessage, !detailMessage.isEmpty {
                    Text(detailMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack {
                    Button {
                        onRequest()
                    } label: {
                        Label(isRunningProbe ? "Requesting..." : "Request Permissions", systemImage: "checklist")
                    }
                    .relayButton(prominent: true)
                    .disabled(isRunningProbe)

                    Spacer()

                    Button("Continue") {
                        onContinue()
                    }
                    .relayButton()
                    .disabled(!canContinue || isRunningProbe)
                }
            }
            .frame(maxWidth: 720)
            .padding(20)
        }
    }

    private func permissionRow(title: String, subtitle: String, status: StartupPermissionStatus) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusIcon(status))
                .foregroundStyle(statusColor(status))
                .font(.headline)
                .frame(width: 20, alignment: .center)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(status.displayTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor(status))
                }
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.24))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.7)
                )
        )
    }

    private func statusColor(_ status: StartupPermissionStatus) -> Color {
        switch status {
        case .idle:
            return .secondary
        case .requesting:
            return .yellow
        case .granted:
            return .green
        case .denied:
            return .orange
        case .failed:
            return .red
        }
    }

    private func statusIcon(_ status: StartupPermissionStatus) -> String {
        switch status {
        case .idle:
            return "circle"
        case .requesting:
            return "clock"
        case .granted:
            return "checkmark.circle.fill"
        case .denied:
            return "exclamationmark.triangle.fill"
        case .failed:
            return "xmark.octagon.fill"
        }
    }
}

private struct ServerLegalAcceptanceView: View {
    @Binding var acceptedPrivacyPolicy: Bool
    @Binding var acceptedTermsOfUse: Bool
    let onAccept: () -> Void

    private var canAccept: Bool {
        acceptedPrivacyPolicy && acceptedTermsOfUse
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                RelaySheetHero(
                    icon: "doc.text.fill",
                    title: "Before You Operate This Relay",
                    subtitle: "Review operator responsibilities before continuing."
                )
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Privacy Policy")
                            .font(.headline)
                        Text(
                            "This relay software stores, routes, and forwards encrypted envelopes, but network and relay metadata can still be exposed. Operators and network observers may observe timestamps, IP addresses, inbox identifiers, relay topology, and traffic patterns. You are solely responsible for infrastructure security, lawful operation, data retention choices, backup handling, and jurisdictional compliance."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Divider().opacity(0.25)
                        Text("Terms of Use")
                            .font(.headline)
                        Text(
                            "By continuing, you agree this software is provided \"as is\" and \"as available\" without warranties or guarantees of any kind, express or implied, including merchantability, fitness for a particular purpose, availability, non-infringement, or security outcomes. There are no developer-hosted relays, managed infrastructure, moderation services, abuse handling services, legal compliance guarantees, or uptime guarantees. You are solely responsible for relay policy decisions, lawful operation, abuse reporting duties, and compliance with local regulations. To the maximum extent permitted by law, the software provider is not liable for any use or misuse of this software, including unlawful acts, data loss, metadata exposure, downtime, compromise, operational failures, or any direct, indirect, incidental, consequential, special, exemplary, or punitive damages. You agree to indemnify and hold harmless the software provider from claims, liabilities, losses, and expenses arising from your deployment or operation of the relay."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .premiumSurface(cornerRadius: 16, tintOpacity: 0.10)
                }
                .frame(minHeight: 180, maxHeight: 280)

                VStack(spacing: 10) {
                    Toggle("I accept the Privacy Policy", isOn: $acceptedPrivacyPolicy)
                    Toggle("I accept the Terms of Use", isOn: $acceptedTermsOfUse)
                }
                .padding(14)
                .premiumSurface(cornerRadius: 14, tintOpacity: 0.08)

                HStack {
                    Spacer()
                    Button("Accept and Continue") {
                        onAccept()
                    }
                    .relayButton(prominent: true)
                    .disabled(!canAccept)
                }
            }
            .frame(maxWidth: 720)
            .padding(20)
        }
    }
}

private struct ServerLegalDocumentView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            PremiumRelayBackground()
            VStack(spacing: 0) {
                RelaySheetTopBar {
                    dismiss()
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

            ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        RelaySheetHero(
                            icon: "doc.text.fill",
                            title: "Relay Policies",
                            subtitle: "Privacy disclosures and operator terms."
                        )

                        RelaySheetSection(title: "Privacy Policy", icon: "hand.raised.fill") {
                            Text(
                                "This relay software stores, routes, and forwards encrypted envelopes, but network and relay metadata can still be exposed. Operators and network observers may observe timestamps, IP addresses, inbox identifiers, relay topology, and traffic patterns. You are solely responsible for infrastructure security, lawful operation, data retention choices, backup handling, and jurisdictional compliance."
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        }

                        RelaySheetSection(title: "Terms of Use", icon: "checkmark.seal.fill") {
                            Text(
                                "By continuing, you agree this software is provided \"as is\" and \"as available\" without warranties or guarantees of any kind, express or implied, including merchantability, fitness for a particular purpose, availability, non-infringement, or security outcomes. There are no developer-hosted relays, managed infrastructure, moderation services, abuse handling services, legal compliance guarantees, or uptime guarantees. You are solely responsible for relay policy decisions, lawful operation, abuse reporting duties, and compliance with local regulations. To the maximum extent permitted by law, the software provider is not liable for any use or misuse of this software, including unlawful acts, data loss, metadata exposure, downtime, compromise, operational failures, or any direct, indirect, incidental, consequential, special, exemplary, or punitive damages. You agree to indemnify and hold harmless the software provider from claims, liabilities, losses, and expenses arising from your deployment or operation of the relay."
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: 760)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

private let relayDonationProductIDs: [String] = [
    "com.luizwidmer.noctyrarelay.donate.small",
    "com.luizwidmer.noctyrarelay.donate.medium",
    "com.luizwidmer.noctyrarelay.donate.large"
]

@MainActor
private final class RelayDonationStore: ObservableObject {
    @Published var products: [Product] = []
    @Published var isLoading = false
    @Published var statusMessage: String?

    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await Product.products(for: relayDonationProductIDs)
            products = loaded.sorted { $0.price < $1.price }
            if loaded.isEmpty {
                statusMessage = "No donation products were found. Add the product IDs in App Store Connect or a StoreKit config file."
            } else {
                statusMessage = nil
            }
        } catch {
            statusMessage = "Unable to load donation products: \(error.localizedDescription)"
        }
    }

    func donate(_ product: Product) async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    statusMessage = "Thanks for supporting Noctyra Relay."
                case .unverified(_, let error):
                    statusMessage = "Purchase could not be verified: \(error.localizedDescription)"
                }
            case .pending:
                statusMessage = "Purchase is pending approval."
            case .userCancelled:
                statusMessage = "Purchase cancelled."
            @unknown default:
                statusMessage = "Purchase failed. Try again."
            }
        } catch {
            statusMessage = "Purchase failed: \(error.localizedDescription)"
        }
    }
}

private struct RelayDonationSheetView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var store = RelayDonationStore()

    var body: some View {
        ZStack {
            PremiumRelayBackground()
            VStack(spacing: 0) {
                RelaySheetTopBar(onClose: { dismiss() }) {
                    Button {
                        Task { await store.loadProducts() }
                    } label: {
                        Label("Reload", systemImage: "arrow.clockwise")
                    }
                    .relayButton()
                    .disabled(store.isLoading)
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                    ScrollView {
                    VStack(spacing: 14) {
                        RelaySheetHero(
                            icon: "heart.fill",
                            title: "Support Noctyra Relay",
                            subtitle: "Fund continued relay maintenance and security work."
                        )

                        RelaySheetSection(title: "Donation Options", icon: "giftcard.fill") {
                            if store.isLoading && store.products.isEmpty {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("Loading donation options…")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 18)
                            } else if store.products.isEmpty {
                                VStack(spacing: 7) {
                                    Image(systemName: "shippingbox")
                                        .font(.system(size: 25))
                                        .foregroundStyle(.secondary)
                                    Text("No options available")
                                        .font(.subheadline.weight(.semibold))
                                    Text("Donation products are not currently available from the App Store.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                            } else {
                                LazyVStack(spacing: 10) {
                                    ForEach(store.products, id: \.id) { product in
                                        Button {
                                            Task { await store.donate(product) }
                                        } label: {
                                            HStack(spacing: 12) {
                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(product.displayName)
                                                        .font(.subheadline.weight(.semibold))
                                                    Text(product.description)
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                        .lineLimit(2)
                                                }
                                                Spacer()
                                                Text(product.displayPrice)
                                                    .font(.subheadline.weight(.semibold))
                                        }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                        .padding(12)
                                        .premiumSurface(cornerRadius: 13, tintOpacity: 0.08)
                                        .disabled(store.isLoading)
                                    }
                                }
                            }
                        }

                if let status = store.statusMessage {
                            Label(status, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .premiumSurface(cornerRadius: 13, tintOpacity: 0.08)
                        }
                    }
                    .frame(maxWidth: 700)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .task {
            await store.loadProducts()
        }
    }
}

#Preview {
    ContentView()
}
