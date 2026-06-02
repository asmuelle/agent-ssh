import SwiftUI
import AgentSshMacOS

@MainActor
final class PortForwardingCoordinator: ObservableObject {
    static let shared = PortForwardingCoordinator()

    @Published private(set) var profiles: [PortForwardProfileRecord] = []
    @Published private(set) var runtimeById: [String: PortForwardRuntimeRecord] = [:]
    @Published var lastError: String?

    private let integrationStore = PlatformIntegrationStore()
    private let runtimeStore = PortForwardRuntimeStore()

    private init() {
        loadProfiles()
        loadRuntime()
    }

    func profiles(for profileId: String) -> [PortForwardProfileRecord] {
        profiles
            .filter { $0.profileId == profileId }
            .sorted { lhs, rhs in
                lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    func runtime(for profile: PortForwardProfileRecord) -> PortForwardRuntimeRecord {
        runtimeById[profile.id] ?? .stopped(from: profile)
    }

    func loadProfiles() {
        do {
            profiles = try integrationStore.load().portForwards
        } catch {
            lastError = "Could not load port forwarding profiles: \(error.localizedDescription)"
        }
    }

    func loadRuntime() {
        do {
            runtimeById = Dictionary(
                uniqueKeysWithValues: try runtimeStore.load().records.map { ($0.id, $0) }
            )
        } catch {
            runtimeById = [:]
        }
    }

    func saveProfile(_ profile: PortForwardProfileRecord) {
        if let validationError = profile.validationError {
            lastError = validationError
            return
        }

        do {
            var data = try integrationStore.load()
            if let index = data.portForwards.firstIndex(where: { $0.id == profile.id }) {
                data.portForwards[index] = profile
            } else {
                data.portForwards.append(profile)
            }
            data.portForwards.sort {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            try integrationStore.save(data)
            profiles = data.portForwards
            lastError = nil
        } catch {
            lastError = "Could not save port forward: \(error.localizedDescription)"
        }
    }

    func deleteProfile(_ profile: PortForwardProfileRecord) async {
        if runtime(for: profile).state.isActive {
            try? await BridgeManager.shared.portForwardStop(id: profile.id)
        }

        do {
            var data = try integrationStore.load()
            data.portForwards.removeAll { $0.id == profile.id }
            try integrationStore.save(data)
            profiles = data.portForwards
            runtimeById.removeValue(forKey: profile.id)
            try? runtimeStore.remove(id: profile.id)
            WidgetMonitoringSnapshotCenter.shared.remove(id: "port-forward:\(profile.id)")
            try? LiveActivitySnapshotStore().remove(id: "tunnel:\(profile.id)")
            lastError = nil
        } catch {
            lastError = "Could not delete port forward: \(error.localizedDescription)"
        }
    }

    func start(_ profile: PortForwardProfileRecord, connectionId: String) async {
        if let validationError = profile.validationError {
            publishFailure(profile, connectionId: connectionId, error: validationError, state: .failed)
            return
        }

        let starting = PortForwardRuntimeRecord(
            id: profile.id,
            profileId: profile.profileId,
            connectionId: connectionId,
            name: profile.name,
            kind: profile.kind,
            state: .starting,
            bindHost: profile.bindHost,
            requestedBindPort: profile.bindPort,
            destinationHost: profile.destinationHost,
            destinationPort: profile.destinationPort,
            updatedAt: Date()
        )
        publish(starting)

        do {
            let running = try await BridgeManager.shared.portForwardStart(
                profile: profile,
                connectionId: connectionId
            )
            publish(running)
            ActivityLogStore.shared.record(
                title: "Port forward started",
                detail: running.summary,
                profileId: profile.profileId,
                connectionId: connectionId,
                icon: "point.3.connected.trianglepath.dotted",
                severity: .success
            )
            lastError = nil
        } catch let error as PortForwardBridgeError {
            let state: PortForwardRuntimeState = {
                if case .unsupported = error { return .unsupported }
                return .failed
            }()
            publishFailure(profile, connectionId: connectionId, error: error.localizedDescription, state: state)
        } catch {
            publishFailure(profile, connectionId: connectionId, error: error.localizedDescription, state: .failed)
        }
    }

    func stop(_ profile: PortForwardProfileRecord) async {
        do {
            try await BridgeManager.shared.portForwardStop(id: profile.id)
        } catch let error as PortForwardBridgeError {
            if case .notFound = error {
                // Runtime is already gone; continue and mark the stored view stopped.
            } else {
                lastError = error.localizedDescription
                return
            }
        } catch {
            lastError = error.localizedDescription
            return
        }

        var stopped = runtime(for: profile)
        stopped.state = .stopped
        stopped.updatedAt = Date()
        stopped.lastError = nil
        publish(stopped)
        ActivityLogStore.shared.record(
            title: "Port forward stopped",
            detail: profile.name,
            profileId: profile.profileId,
            connectionId: stopped.connectionId.isEmpty ? nil : stopped.connectionId,
            icon: "stop.circle",
            severity: .info
        )
    }

    func restart(_ profile: PortForwardProfileRecord, connectionId: String) async {
        if runtime(for: profile).state.isActive {
            await stop(profile)
        }
        await start(profile, connectionId: connectionId)
    }

    func refresh(connectionId: String) async {
        let records = await BridgeManager.shared.portForwardList(connectionId: connectionId)
        for record in records {
            publish(record)
        }
    }

    func autoStart(profileId: String, connectionId: String) async {
        loadProfiles()
        for profile in profiles(for: profileId) where profile.autoStart {
            await start(profile, connectionId: connectionId)
        }
    }

    func markStopped(profileId: String, connectionId: String) {
        for profile in profiles(for: profileId) {
            var runtime = runtime(for: profile)
            guard runtime.connectionId == connectionId, runtime.state.isActive else { continue }
            runtime.state = .stopped
            runtime.updatedAt = Date()
            runtime.lastError = nil
            publish(runtime)
        }
    }

    private func publishFailure(
        _ profile: PortForwardProfileRecord,
        connectionId: String,
        error: String,
        state: PortForwardRuntimeState
    ) {
        let failed = PortForwardRuntimeRecord(
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
        publish(failed)
        lastError = error
        ActivityLogStore.shared.record(
            title: "Port forward failed",
            detail: "\(profile.name): \(error)",
            profileId: profile.profileId,
            connectionId: connectionId,
            icon: "exclamationmark.triangle.fill",
            severity: .warning
        )
    }

    private func publish(_ record: PortForwardRuntimeRecord) {
        runtimeById[record.id] = record
        try? runtimeStore.upsert(record)
        WidgetMonitoringSnapshotCenter.shared.upsert(.portForward(record))
        try? LiveActivitySnapshotStore().upsert(.portForward(record))
    }
}

struct PortForwardingPanel: View {
    let profile: ConnectionProfile
    let connectionId: String
    var isActive: Bool = true

    @ObservedObject private var coordinator = PortForwardingCoordinator.shared
    @State private var editingProfile: PortForwardEditTarget?

    private var records: [PortForwardProfileRecord] {
        coordinator.profiles(for: profile.id)
    }

    var body: some View {
        if FeatureFlags.portForwarding.isEnabled {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Label("Port Forwarding", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                    Button {
                        editingProfile = .new(profile.id)
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Add port forward")
                }

                if records.isEmpty {
                    emptyState
                } else {
                    VStack(spacing: 8) {
                        ForEach(records) { record in
                            row(record)
                        }
                    }
                }

                if let lastError = coordinator.lastError {
                    Text(lastError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .task(id: "\(connectionId):\(isActive)") {
                guard isActive else { return }
                coordinator.loadProfiles()
                await coordinator.refresh(connectionId: connectionId)
            }
            .sheet(item: $editingProfile) { target in
                PortForwardEditSheet(target: target) { profile in
                    coordinator.saveProfile(profile)
                }
            }
        }
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(.tertiary)
            Text("No forwarding profiles")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ record: PortForwardProfileRecord) -> some View {
        let runtime = coordinator.runtime(for: record)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(color(for: runtime.state))
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(runtime.state.isActive ? runtime.summary : record.routeSummary)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                controls(for: record, runtime: runtime)
            }

            if runtime.state.isActive {
                HStack(spacing: 10) {
                    stat("Time", value: formatDuration(runtime.startedAt))
                    stat("In", value: formatBytes(runtime.bytesIn))
                    stat("Out", value: formatBytes(runtime.bytesOut))
                    stat("Conns", value: "\(runtime.connectionCount)")
                }
            } else if let error = runtime.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(runtime.state == .unsupported ? .orange : .red)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("Edit...") {
                editingProfile = .edit(record)
            }
            Button("Restart") {
                Task { await coordinator.restart(record, connectionId: connectionId) }
            }
            Divider()
            Button("Delete", role: .destructive) {
                Task { await coordinator.deleteProfile(record) }
            }
        }
    }

    private func controls(
        for record: PortForwardProfileRecord,
        runtime: PortForwardRuntimeRecord
    ) -> some View {
        HStack(spacing: 4) {
            if runtime.state.isActive {
                Button {
                    Task { await coordinator.stop(record) }
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .help("Stop")

                Button {
                    Task { await coordinator.restart(record, connectionId: connectionId) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Restart")
            } else {
                Button {
                    Task { await coordinator.start(record, connectionId: connectionId) }
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.borderless)
                .help("Start")
            }

            Button {
                editingProfile = .edit(record)
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(.borderless)
            .help("Edit")
        }
        .controlSize(.small)
    }

    private func stat(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
        }
    }

    private func color(for state: PortForwardRuntimeState) -> Color {
        switch state {
        case .starting:
            return .orange
        case .running:
            return .green
        case .stopped:
            return .secondary
        case .failed:
            return .red
        case .unsupported:
            return .yellow
        }
    }

    private func formatDuration(_ startedAt: Date?) -> String {
        guard let startedAt else { return "--" }
        let seconds = max(0, Int(Date().timeIntervalSince(startedAt)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return "\(minutes / 60)h \(minutes % 60)m"
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }
}

struct PortForwardEditTarget: Identifiable {
    enum Mode {
        case new(String)
        case edit(PortForwardProfileRecord)
    }

    let id = UUID()
    let mode: Mode

    static func new(_ profileId: String) -> PortForwardEditTarget {
        PortForwardEditTarget(mode: .new(profileId))
    }

    static func edit(_ profile: PortForwardProfileRecord) -> PortForwardEditTarget {
        PortForwardEditTarget(mode: .edit(profile))
    }
}

private struct PortForwardEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let target: PortForwardEditTarget
    let onSave: (PortForwardProfileRecord) -> Void

    @State private var name = ""
    @State private var kind: PortForwardKind = .local
    @State private var bindHost = "127.0.0.1"
    @State private var bindPort = ""
    @State private var destinationHost = ""
    @State private var destinationPort = ""
    @State private var autoStart = false
    @State private var error: String?

    private var existing: PortForwardProfileRecord? {
        if case .edit(let profile) = target.mode { return profile }
        return nil
    }

    private var profileId: String {
        switch target.mode {
        case .new(let profileId):
            return profileId
        case .edit(let profile):
            return profile.profileId
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(existing == nil ? "New Port Forward" : "Edit Port Forward")
                .font(.headline)
                .padding()

            Form {
                TextField("Name", text: $name)
                Picker("Kind", selection: $kind) {
                    ForEach(PortForwardKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                TextField("Bind host", text: $bindHost)
                TextField("Bind port", text: $bindPort)

                if kind.requiresDestination {
                    TextField("Destination host", text: $destinationHost)
                    TextField("Destination port", text: $destinationPort)
                }

                Toggle("Auto-start", isOn: $autoStart)
            }
            .formStyle(.grouped)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 430)
        .onAppear(perform: load)
    }

    private func load() {
        guard let existing else {
            bindPort = "8080"
            destinationHost = "127.0.0.1"
            destinationPort = "80"
            return
        }

        name = existing.name
        kind = existing.kind
        bindHost = existing.bindHost
        bindPort = String(existing.bindPort)
        destinationHost = existing.destinationHost ?? ""
        destinationPort = existing.destinationPort.map(String.init) ?? ""
        autoStart = existing.autoStart
    }

    private func save() {
        guard let bindPortValue = UInt16(bindPort), bindPortValue > 0 || bindPort == "0" else {
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
