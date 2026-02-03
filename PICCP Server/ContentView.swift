import SwiftUI
import PICCPCore

struct ContentView: View {
    @StateObject private var model = ServerViewModel()

    var body: some View {
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

#Preview {
    ContentView()
}
