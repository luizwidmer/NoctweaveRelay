import SwiftUI
import PICCPCore

struct ContentView: View {
    @StateObject private var model = ServerViewModel()
    @AppStorage("noctyra.server.acceptedPrivacyPolicy.v1") private var acceptedPrivacyPolicy = false
    @AppStorage("noctyra.server.acceptedTermsOfUse.v1") private var acceptedTermsOfUse = false
    @State private var pendingPrivacyAcceptance = false
    @State private var pendingTermsAcceptance = false
    @State private var showingLegalDetails = false

    private var requiresLegalAcceptance: Bool {
        !acceptedPrivacyPolicy || !acceptedTermsOfUse
    }

    var body: some View {
        ZStack {
            mainContent
                .blur(radius: requiresLegalAcceptance ? 1.5 : 0)
                .disabled(requiresLegalAcceptance)
            if requiresLegalAcceptance {
                ServerLegalAcceptanceView(
                    acceptedPrivacyPolicy: $pendingPrivacyAcceptance,
                    acceptedTermsOfUse: $pendingTermsAcceptance,
                    onAccept: {
                        acceptedPrivacyPolicy = pendingPrivacyAcceptance
                        acceptedTermsOfUse = pendingTermsAcceptance
                    }
                )
            }
        }
        .onAppear {
            pendingPrivacyAcceptance = acceptedPrivacyPolicy
            pendingTermsAcceptance = acceptedTermsOfUse
        }
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                TextField("Host", text: $model.host)
                    .frame(width: 160)
                TextField("Port", text: $model.port)
                    .frame(width: 80)
                Button(model.isRunning ? "Stop" : "Start") {
                    if model.isRunning {
                        model.stop()
                    } else {
                        model.start()
                    }
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("Policies") {
                    showingLegalDetails = true
                }
                .buttonStyle(.bordered)
                Text(model.isRunning ? "Running" : "Stopped")
                    .foregroundStyle(model.isRunning ? .green : .secondary)
            }

            GroupBox("Relay Configuration") {
                VStack(alignment: .leading, spacing: 12) {
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
                    HStack {
                        Text("Federation Mode")
                        Spacer()
                        Picker("Federation Mode", selection: $model.federationMode) {
                            ForEach(FederationMode.allCases.filter { $0 != .open }, id: \.self) { mode in
                                Text(mode.rawValue.capitalized).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 220)
                    }
                    if model.federationMode != .solo {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Federation Source (HTTPS)")
                                .font(.subheadline.weight(.semibold))
                            TextField("https://example.org/federation.json", text: $model.federationSourceURL)
                            HStack(spacing: 8) {
                                Button("Fetch Federation") {
                                    model.fetchFederationSource()
                                }
                                .buttonStyle(.bordered)
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
                            Text("JSON may include mode (solo/curated/open), name, description, and allowlist entries (host:port or https URL).")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Federation Details")
                                .font(.subheadline.weight(.semibold))
                            Text(model.federationName.isEmpty ? "Name: —" : "Name: \(model.federationName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(model.federationDescription.isEmpty ? "Description: —" : "Description: \(model.federationDescription)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(model.federationAllowList.isEmpty ? "Allow List: —" : "Allow List: \(model.federationAllowList)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("Temporal Bucket (minutes)")
                        Spacer()
                        TextField("5", text: $model.temporalBucketMinutes)
                            .frame(width: 80)
                    }
                    Divider().opacity(0.2)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Storage")
                            .font(.subheadline.weight(.semibold))
                        Picker("Store Method", selection: $model.storageMode) {
                            Text("Disk").tag(RelayStorageMode.disk)
                            Text("RAM").tag(RelayStorageMode.memory)
                        }
                        .pickerStyle(.segmented)
                        if model.storageMode == .disk {
                            HStack(spacing: 8) {
                                TextField("Store file path", text: $model.storePath)
                                Button("Choose…") {
                                    model.chooseStorePath()
                                }
                                .buttonStyle(.bordered)
                                Button("Default") {
                                    model.resetStorePathToDefault()
                                }
                                .buttonStyle(.bordered)
                            }
                            Text("Disk mode persists relay state at the selected path.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(model.storageLocationDescription)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("RAM mode is ephemeral. All queued envelopes and prekeys are lost when the relay stops.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider().opacity(0.2)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Transport Security")
                            .font(.subheadline.weight(.semibold))
                        Toggle("Enable TLS", isOn: $model.tlsEnabled)
                        if model.tlsEnabled {
                            HStack(spacing: 8) {
                                TextField("PKCS#12 identity path (.p12/.pfx)", text: $model.tlsIdentityPKCS12Path)
                                Button("Choose…") {
                                    model.chooseTLSIdentityPath()
                                }
                                .buttonStyle(.bordered)
                            }
                            SecureField("PKCS#12 password (if any)", text: $model.tlsIdentityPassword)
                            Text("TLS requires a PKCS#12 identity containing the relay private key and certificate chain.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Relay serves plain TCP when TLS is disabled.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Divider().opacity(0.2)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Access Control")
                            .font(.subheadline.weight(.semibold))
                        SecureField("Relay Password (optional)", text: $model.relayPassword)
                        SecureField("Confirm Relay Password", text: $model.relayPasswordConfirmation)
                        Text("When set, clients must provide this password for deliver/fetch and other non-info requests.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    TextField("Relay Name (optional)", text: $model.relayName)
                    TextField("Operator Note (optional)", text: $model.operatorNote)
                    Text("Software: \(model.softwareVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .disabled(model.isRunning)
            }

            Text("Relay Logs")
                .font(.headline)

            List {
                ForEach(model.logs.reversed(), id: \.self) { entry in
                    Text(entry)
                        .font(.callout)
                }
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 420)
        .alert("Error", isPresented: Binding(get: { model.lastError != nil }, set: { _ in model.lastError = nil })) {
            Button("OK") {}
        } message: {
            Text(model.lastError ?? "")
        }
        .sheet(isPresented: $showingLegalDetails) {
            ServerLegalDocumentView()
        }
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
                Text("Before You Operate This Relay")
                    .font(.title3.weight(.semibold))
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
                }
                .frame(minHeight: 180, maxHeight: 280)

                Toggle("I accept the Privacy Policy", isOn: $acceptedPrivacyPolicy)
                Toggle("I accept the Terms of Use", isOn: $acceptedTermsOfUse)

                HStack {
                    Spacer()
                    Button("Accept and Continue") {
                        onAccept()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAccept)
                }
            }
            .padding(18)
            .frame(maxWidth: 720)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .padding(20)
        }
    }
}

private struct ServerLegalDocumentView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Privacy Policy")
                        .font(.headline)
                    Text(
                        "This relay software stores, routes, and forwards encrypted envelopes, but network and relay metadata can still be exposed. Operators and network observers may observe timestamps, IP addresses, inbox identifiers, relay topology, and traffic patterns. You are solely responsible for infrastructure security, lawful operation, data retention choices, backup handling, and jurisdictional compliance."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    Divider().opacity(0.25)
                    Text("Terms of Use")
                        .font(.headline)
                    Text(
                        "By continuing, you agree this software is provided \"as is\" and \"as available\" without warranties or guarantees of any kind, express or implied, including merchantability, fitness for a particular purpose, availability, non-infringement, or security outcomes. There are no developer-hosted relays, managed infrastructure, moderation services, abuse handling services, legal compliance guarantees, or uptime guarantees. You are solely responsible for relay policy decisions, lawful operation, abuse reporting duties, and compliance with local regulations. To the maximum extent permitted by law, the software provider is not liable for any use or misuse of this software, including unlawful acts, data loss, metadata exposure, downtime, compromise, operational failures, or any direct, indirect, incidental, consequential, special, exemplary, or punitive damages. You agree to indemnify and hold harmless the software provider from claims, liabilities, losses, and expenses arising from your deployment or operation of the relay."
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .navigationTitle("Policies")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
    }
}

#Preview {
    ContentView()
}
