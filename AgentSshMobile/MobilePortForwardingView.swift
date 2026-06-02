import SwiftUI

@MainActor
final class MobilePortForwardingStore: ObservableObject {
    @Published private(set) var profiles: [PortForwardProfileRecord] = []
    @Published private(set) var runtimeById: [String: PortForwardRuntimeRecord] = [:]
    @Published var errorMessage: String?

    private let integrationStore = PlatformIntegrationStore()
    private let runtimeStore = PortForwardRuntimeStore()

    func load(profileId: String) {
        do {
            profiles = try integrationStore.load().portForwards
                .filter { $0.profileId == profileId }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            runtimeById = Dictionary(
                uniqueKeysWithValues: try runtimeStore.load().records.map { ($0.id, $0) }
            )
            errorMessage = nil
        } catch {
            errorMessage = "Could not load port forwards: \(error.localizedDescription)"
        }
    }

    func runtime(for profile: PortForwardProfileRecord) -> PortForwardRuntimeRecord {
        runtimeById[profile.id] ?? .stopped(from: profile)
    }

    func save(_ profile: PortForwardProfileRecord, parentProfileId: String) {
        guard profile.validationError == nil else {
            errorMessage = profile.validationError
            return
        }
        do {
            var data = try integrationStore.load()
            if let index = data.portForwards.firstIndex(where: { $0.id == profile.id }) {
                data.portForwards[index] = profile
            } else {
                data.portForwards.append(profile)
            }
            try integrationStore.save(data)
            load(profileId: parentProfileId)
        } catch {
            errorMessage = "Could not save port forward: \(error.localizedDescription)"
        }
    }

    func delete(_ profile: PortForwardProfileRecord, parentProfileId: String) async {
        if runtime(for: profile).state.isActive {
            try? await MobilePortForwardBridge.shared.stop(id: profile.id)
        }
        do {
            var data = try integrationStore.load()
            data.portForwards.removeAll { $0.id == profile.id }
            try integrationStore.save(data)
            try? runtimeStore.remove(id: profile.id)
            MobileLiveActivityCenter.shared.remove(snapshotId: "tunnel:\(profile.id)")
            load(profileId: parentProfileId)
        } catch {
            errorMessage = "Could not delete port forward: \(error.localizedDescription)"
        }
    }

    func start(_ profile: PortForwardProfileRecord, connectionId: String) async {
        if let validationError = profile.validationError {
            publish(profile, connectionId: connectionId, state: .failed, error: validationError)
            return
        }

        publish(profile, connectionId: connectionId, state: .starting, error: nil)
        do {
            let record = try await MobilePortForwardBridge.shared.start(
                profile: profile,
                connectionId: connectionId
            )
            publish(record)
            MobileActivityLogStore.shared.record(
                title: "Port forward started",
                detail: record.summary,
                profileId: profile.profileId,
                connectionId: connectionId,
                systemImage: "point.3.connected.trianglepath.dotted",
                severity: .ok
            )
            errorMessage = nil
        } catch let error as MobilePortForwardBridgeError {
            let state: PortForwardRuntimeState = {
                if case .unsupported = error { return .unsupported }
                return .failed
            }()
            publish(profile, connectionId: connectionId, state: state, error: error.localizedDescription)
        } catch {
            publish(profile, connectionId: connectionId, state: .failed, error: error.localizedDescription)
        }
    }

    func stop(_ profile: PortForwardProfileRecord) async {
        do {
            try await MobilePortForwardBridge.shared.stop(id: profile.id)
        } catch let error as MobilePortForwardBridgeError {
            if case .notFound = error {
            } else {
                errorMessage = error.localizedDescription
                return
            }
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        var stopped = runtime(for: profile)
        stopped.state = .stopped
        stopped.updatedAt = Date()
        stopped.lastError = nil
        publish(stopped)
    }

    func restart(_ profile: PortForwardProfileRecord, connectionId: String) async {
        if runtime(for: profile).state.isActive {
            await stop(profile)
        }
        await start(profile, connectionId: connectionId)
    }

    func refresh(connectionId: String) async {
        let records = await MobilePortForwardBridge.shared.list(connectionId: connectionId)
        for record in records {
            publish(record)
        }
    }

    private func publish(
        _ profile: PortForwardProfileRecord,
        connectionId: String,
        state: PortForwardRuntimeState,
        error: String?
    ) {
        let record = PortForwardRuntimeRecord(
            id: profile.id,
            profileId: profile.profileId,
            connectionId: connectionId,
            name: profile.name,
            kind: profile.kind,
            state: state,
            bindHost: profile.bindHost,
            requestedBindPort: profile.bindPort,
            destinationHost: profile.destinationHost,
            destinationPort: profile.destinationPort,
            updatedAt: Date(),
            lastError: error
        )
        publish(record)
        errorMessage = error
    }

    private func publish(_ record: PortForwardRuntimeRecord) {
        runtimeById[record.id] = record
        try? runtimeStore.upsert(record)
        MobileLiveActivityCenter.shared.publish(.portForward(record))
    }
}

struct MobilePortForwardingView: View {
    let profile: MobileConnectionProfile
    let connectionId: String

    @StateObject private var store = MobilePortForwardingStore()
    @State private var editorTarget: MobilePortForwardEditorTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Port Forwarding", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Spacer()
                Button {
                    editorTarget = .new(profile.id)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Add port forward")
            }

            if store.profiles.isEmpty {
                Text("No forwarding profiles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.profiles) { forward in
                    row(forward)
                }
            }

            if let errorMessage = store.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        .task(id: connectionId) {
            store.load(profileId: profile.id)
            await store.refresh(connectionId: connectionId)
        }
        .sheet(item: $editorTarget) { target in
            MobilePortForwardEditor(target: target) { record in
                store.save(record, parentProfileId: profile.id)
            }
        }
    }

    private func row(_ forward: PortForwardProfileRecord) -> some View {
        let runtime = store.runtime(for: forward)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(color(for: runtime.state))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(forward.name)
                        .font(.subheadline.weight(.semibold))
                    Text(runtime.state.isActive ? runtime.summary : forward.routeSummary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if runtime.state.isActive {
                    Button {
                        Task { await store.stop(forward) }
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else {
                    Button {
                        Task { await store.start(forward, connectionId: connectionId) }
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            if runtime.state.isActive {
                HStack(spacing: 14) {
                    stat("In", formatBytes(runtime.bytesIn))
                    stat("Out", formatBytes(runtime.bytesOut))
                    stat("Conns", "\(runtime.connectionCount)")
                    Spacer()
                    Button {
                        Task { await store.restart(forward, connectionId: connectionId) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else if let lastError = runtime.lastError {
                Text(lastError)
                    .font(.caption2)
                    .foregroundStyle(runtime.state == .unsupported ? .orange : .red)
            }
        }
        .padding(10)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("Edit") { editorTarget = .edit(forward) }
            Button("Restart") {
                Task { await store.restart(forward, connectionId: connectionId) }
            }
            Button("Delete", role: .destructive) {
                Task { await store.delete(forward, parentProfileId: profile.id) }
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.monospacedDigit())
        }
    }

    private func color(for state: PortForwardRuntimeState) -> Color {
        switch state {
        case .running:
            return .green
        case .starting:
            return .orange
        case .stopped:
            return .secondary
        case .failed:
            return .red
        case .unsupported:
            return .yellow
        }
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }
}

struct MobilePortForwardEditorTarget: Identifiable {
    enum Mode {
        case new(String)
        case edit(PortForwardProfileRecord)
    }

    let id = UUID()
    let mode: Mode

    static func new(_ profileId: String) -> MobilePortForwardEditorTarget {
        MobilePortForwardEditorTarget(mode: .new(profileId))
    }

    static func edit(_ record: PortForwardProfileRecord) -> MobilePortForwardEditorTarget {
        MobilePortForwardEditorTarget(mode: .edit(record))
    }
}

private struct MobilePortForwardEditor: View {
    @Environment(\.dismiss) private var dismiss
    let target: MobilePortForwardEditorTarget
    let onSave: (PortForwardProfileRecord) -> Void

    @State private var name = ""
    @State private var kind: PortForwardKind = .local
    @State private var bindHost = "127.0.0.1"
    @State private var bindPort = "8080"
    @State private var destinationHost = "127.0.0.1"
    @State private var destinationPort = "80"
    @State private var autoStart = false
    @State private var error: String?

    private var existing: PortForwardProfileRecord? {
        if case .edit(let record) = target.mode { return record }
        return nil
    }

    private var profileId: String {
        switch target.mode {
        case .new(let profileId):
            return profileId
        case .edit(let record):
            return record.profileId
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Picker("Kind", selection: $kind) {
                    ForEach(PortForwardKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                TextField("Bind host", text: $bindHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Bind port", text: $bindPort)
                    .keyboardType(.numberPad)
                if kind.requiresDestination {
                    TextField("Destination host", text: $destinationHost)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Destination port", text: $destinationPort)
                        .keyboardType(.numberPad)
                }
                Toggle("Auto-start", isOn: $autoStart)
                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle(existing == nil ? "New Port Forward" : "Edit Port Forward")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard let existing else { return }
        name = existing.name
        kind = existing.kind
        bindHost = existing.bindHost
        bindPort = String(existing.bindPort)
        destinationHost = existing.destinationHost ?? ""
        destinationPort = existing.destinationPort.map(String.init) ?? ""
        autoStart = existing.autoStart
    }

    private func save() {
        guard let bindPortValue = UInt16(bindPort) else {
            error = "Bind port must be between 0 and 65535."
            return
        }
        let destinationPortValue: UInt16?
        if kind.requiresDestination {
            guard let parsed = UInt16(destinationPort), parsed > 0 else {
                error = "Destination port must be between 1 and 65535."
                return
            }
            destinationPortValue = parsed
        } else {
            destinationPortValue = nil
        }

        let record = PortForwardProfileRecord(
            id: existing?.id ?? UUID().uuidString,
            profileId: profileId,
            name: name,
            kind: kind,
            bindHost: bindHost,
            bindPort: bindPortValue,
            destinationHost: kind.requiresDestination ? destinationHost : nil,
            destinationPort: destinationPortValue,
            autoStart: autoStart
        )
        if let validationError = record.validationError {
            error = validationError
            return
        }
        onSave(record)
        dismiss()
    }
}
