import AgentSshMacOS
import SwiftUI

struct ActuatorFleetSheet: View {
    let tabs: [TerminalTab]

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var monitor = ActuatorFleetMonitor.shared
    @ObservedObject private var connectionStore = ConnectionStoreManager.shared
    @State private var selectedServiceId: String?
    @State private var editingTarget: ActuatorServiceEditorTarget?
    @State private var showingAuthentication = false

    private var selectedService: ActuatorServiceConfiguration? {
        monitor.services.first { $0.id == selectedServiceId }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                serviceList
                    .frame(minWidth: 310, idealWidth: 360)
                detailPane
                    .frame(minWidth: 520, idealWidth: 720)
            }
        }
        .frame(minWidth: 920, idealWidth: 1_100, minHeight: 620, idealHeight: 760)
        .onAppear {
            if selectedServiceId == nil {
                selectedServiceId = monitor.services.first?.id
            }
            monitor.selectedServiceId = selectedServiceId
        }
        .onChange(of: selectedServiceId) { value in
            monitor.selectedServiceId = value
        }
        .sheet(item: $editingTarget) { target in
            ActuatorServiceEditor(
                target: target,
                profiles: connectionStore.connections
            ) { service in
                monitor.upsert(service)
                selectedServiceId = service.id
            }
        }
        .sheet(isPresented: $showingAuthentication) {
            ActuatorAuthenticationSheet(current: monitor.configuration.authentication) {
                kind, username, secret in
                monitor.saveAuthentication(kind: kind, username: username, secret: secret)
            }
        }
        .onDisappear {
            monitor.selectedServiceId = nil
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Spring Boot Actuator", systemImage: "heart.text.square")
                    .font(.headline)
                Text("Health is queried through ephemeral SSH tunnels; observations live only for this app session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if monitor.isPolling {
                Label("Polling", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Authentication") { showingAuthentication = true }
            Button {
                Task { await monitor.refreshNow() }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(monitor.services.isEmpty)
            Button {
                editingTarget = .new(defaultProfileId: tabs.first?.profile.id ?? connectionStore.connections.first?.id)
            } label: {
                Label("Add Service", systemImage: "plus")
            }
            .disabled(connectionStore.connections.isEmpty)
            Button("Close") { dismiss() }
        }
        .controlSize(.small)
        .padding(16)
    }

    private var serviceList: some View {
        VStack(spacing: 0) {
            if monitor.services.isEmpty {
                emptyState(
                    title: "No Actuator Services",
                    detail: "Add a Spring Boot management port associated with a saved SSH host."
                )
            } else {
                List(selection: $selectedServiceId) {
                    ForEach(monitor.services) { service in
                        serviceRow(service)
                            .tag(service.id as String?)
                            .contextMenu {
                                Button("Edit…") { editingTarget = .edit(service) }
                                Button("Refresh") {
                                    Task { await monitor.refreshNow(serviceId: service.id) }
                                }
                                Divider()
                                Button("Delete", role: .destructive) {
                                    Task { await monitor.delete(service) }
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
            }

            if let error = monitor.lastError {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
    }

    private func serviceRow(_ service: ActuatorServiceConfiguration) -> some View {
        let snapshot = monitor.snapshots[service.id]
        let state = snapshot?.effectiveState() ?? .discovering
        let profile = connectionStore.connections.first { $0.id == service.profileId }

        return HStack(spacing: 9) {
            Circle()
                .fill(color(state))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(service.name)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(label(state))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(color(state))
                }
                Text(profile?.name ?? "Unknown SSH host")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(service.managementHost):\(service.managementPort)\(service.basePath)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let service = selectedService {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    serviceHeader(service)
                    healthOverview(service)
                    componentSection(service)
                    sessionHistorySection(service)
                    securityFootnote(service)
                }
                .padding(18)
            }
        } else {
            emptyState(title: "Select an Actuator service", detail: nil)
        }
    }

    private func emptyState(title: String, detail: String?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "heart.text.square")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func serviceHeader(_ service: ActuatorServiceConfiguration) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(service.name)
                    .font(.title2.weight(.semibold))
                Text("Via \(profileName(service.profileId)) · \(service.scheme.rawValue)://\(service.managementHost):\(service.managementPort)\(service.basePath)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Edit…") { editingTarget = .edit(service) }
            Button {
                Task { await monitor.refreshNow(serviceId: service.id) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh now")
        }
        .controlSize(.small)
    }

    private func healthOverview(_ service: ActuatorServiceConfiguration) -> some View {
        let snapshot = monitor.snapshots[service.id]
        let state = snapshot?.effectiveState() ?? .discovering

        return GroupBox("Application Health") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ActuatorStatusTile(
                        title: "Effective",
                        value: label(state),
                        color: color(state),
                        icon: icon(state)
                    )
                    ActuatorStatusTile(
                        title: "Readiness",
                        value: statusLabel(snapshot?.readinessStatus, fallback: snapshot?.healthGroupsAvailable == false ? "Not configured" : "—"),
                        color: statusColor(snapshot?.readinessStatus),
                        icon: "checkmark.circle"
                    )
                    ActuatorStatusTile(
                        title: "Liveness",
                        value: statusLabel(snapshot?.livenessStatus, fallback: snapshot?.healthGroupsAvailable == false ? "Not configured" : "—"),
                        color: statusColor(snapshot?.livenessStatus),
                        icon: "waveform.path.ecg"
                    )
                    ActuatorStatusTile(
                        title: "Response",
                        value: responseLabel(snapshot?.responseTime),
                        color: .secondary,
                        icon: "timer"
                    )
                }

                if let snapshot {
                    HStack {
                        Text("Observed \(snapshot.observedAt.formatted(date: .omitted, time: .standard))")
                        if !snapshot.healthGroupsAvailable {
                            Text("· using overall /health fallback")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if let message = snapshot.message {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(color(state))
                            .textSelection(.enabled)
                    }
                } else {
                    Text("Waiting for the first observation. The SSH host must be connected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }

    @ViewBuilder
    private func componentSection(_ service: ActuatorServiceConfiguration) -> some View {
        let components = monitor.snapshots[service.id]?.components ?? []
        GroupBox("Health Components") {
            if components.isEmpty {
                Text("No component details were exposed. Configure show-components/details for the authenticated Actuator role if needed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 190), spacing: 8)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(components) { component in
                        HStack(spacing: 7) {
                            Circle()
                                .fill(statusColor(component.status))
                                .frame(width: 7, height: 7)
                            Text(component.path)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                            Spacer()
                            Text(component.status.rawValue)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(statusColor(component.status))
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))
                    }
                }
                .padding(8)
            }
        }
    }

    private func sessionHistorySection(_ service: ActuatorServiceConfiguration) -> some View {
        let history = monitor.history(for: service.id)
        let transitions = monitor.transitions(for: service.id)

        return GroupBox("This Session") {
            VStack(alignment: .leading, spacing: 10) {
                ActuatorHistoryStrip(history: history)
                    .frame(height: 28)
                HStack {
                    Text("\(history.count) observations")
                    Text("·")
                    Text("\(transitions.count) state transitions")
                    Spacer()
                    Text("History is discarded when agent-ssh closes")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                ForEach(Array(transitions.suffix(6).reversed().enumerated()), id: \.offset) { _, transition in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(color(transition.state))
                            .frame(width: 7, height: 7)
                        Text(label(transition.state))
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(transition.observedAt.formatted(date: .omitted, time: .standard))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(8)
        }
    }

    private func securityFootnote(_ service: ActuatorServiceConfiguration) -> some View {
        Label(
            "GET-only health requests travel through an ephemeral SSH local forward. Credentials remain in the macOS Keychain; component details are not persisted.",
            systemImage: "lock.shield"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func profileName(_ profileId: String) -> String {
        connectionStore.connections.first { $0.id == profileId }?.name ?? "Unknown host"
    }

    private func label(_ state: ActuatorServiceState) -> String {
        switch state {
        case .discovering: return "Discovering"
        case .healthy: return "Healthy"
        case .degraded: return "Degraded"
        case .unhealthy: return "Unhealthy"
        case .unreachable: return "Unreachable"
        case .unauthorized: return "Unauthorized"
        case .unsupported: return "Unsupported"
        case .stale: return "Stale"
        }
    }

    private func color(_ state: ActuatorServiceState) -> Color {
        switch state {
        case .healthy: return .green
        case .degraded, .stale, .discovering: return .orange
        case .unhealthy, .unreachable, .unauthorized: return .red
        case .unsupported: return .secondary
        }
    }

    private func icon(_ state: ActuatorServiceState) -> String {
        switch state {
        case .healthy: return "checkmark.circle.fill"
        case .discovering: return "ellipsis.circle"
        case .degraded, .stale: return "exclamationmark.triangle.fill"
        case .unhealthy: return "heart.slash.fill"
        case .unreachable: return "network.slash"
        case .unauthorized: return "lock.fill"
        case .unsupported: return "questionmark.circle"
        }
    }

    private func statusLabel(_ status: ActuatorHealthStatus?, fallback: String) -> String {
        status?.rawValue ?? fallback
    }

    private func statusColor(_ status: ActuatorHealthStatus?) -> Color {
        switch status {
        case .up: return .green
        case .down, .outOfService: return .red
        case .unknown: return .orange
        case nil: return .secondary
        }
    }

    private func responseLabel(_ duration: TimeInterval?) -> String {
        guard let duration else { return "—" }
        return "\(Int(duration * 1_000)) ms"
    }
}

private struct ActuatorStatusTile: View {
    let title: String
    let value: String
    let color: Color
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct ActuatorHistoryStrip: View {
    let history: [ActuatorHealthSnapshot]

    var body: some View {
        GeometryReader { proxy in
            let values = Array(history.suffix(120))
            let spacing: CGFloat = 1
            let width = max(2, (proxy.size.width - CGFloat(max(values.count - 1, 0)) * spacing) / CGFloat(max(values.count, 1)))
            HStack(spacing: spacing) {
                if values.isEmpty {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.secondary.opacity(0.12))
                } else {
                    ForEach(Array(values.enumerated()), id: \.offset) { _, observation in
                        Rectangle()
                            .fill(color(observation.state))
                            .frame(width: width)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func color(_ state: ActuatorServiceState) -> Color {
        switch state {
        case .healthy: return .green
        case .degraded, .stale, .discovering: return .orange
        case .unhealthy, .unreachable, .unauthorized: return .red
        case .unsupported: return .secondary
        }
    }
}

private struct ActuatorServiceEditorTarget: Identifiable {
    var id = UUID()
    var service: ActuatorServiceConfiguration?
    var defaultProfileId: String?

    static func new(defaultProfileId: String?) -> ActuatorServiceEditorTarget {
        ActuatorServiceEditorTarget(service: nil, defaultProfileId: defaultProfileId)
    }

    static func edit(_ service: ActuatorServiceConfiguration) -> ActuatorServiceEditorTarget {
        ActuatorServiceEditorTarget(service: service, defaultProfileId: service.profileId)
    }
}

private struct ActuatorServiceEditor: View {
    @Environment(\.dismiss) private var dismiss
    let target: ActuatorServiceEditorTarget
    let profiles: [ConnectionProfile]
    let onSave: (ActuatorServiceConfiguration) -> Void

    @State private var profileId: String
    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var scheme: ActuatorScheme
    @State private var basePath: String
    @State private var error: String?

    init(
        target: ActuatorServiceEditorTarget,
        profiles: [ConnectionProfile],
        onSave: @escaping (ActuatorServiceConfiguration) -> Void
    ) {
        self.target = target
        self.profiles = profiles
        self.onSave = onSave
        let existing = target.service
        _profileId = State(initialValue: existing?.profileId ?? target.defaultProfileId ?? profiles.first?.id ?? "")
        _name = State(initialValue: existing?.name ?? "")
        _host = State(initialValue: existing?.managementHost ?? "127.0.0.1")
        _port = State(initialValue: existing.map { String($0.managementPort) } ?? "8081")
        _scheme = State(initialValue: existing?.scheme ?? .http)
        _basePath = State(initialValue: existing?.basePath ?? "/actuator")
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(target.service == nil ? "Add Actuator Service" : "Edit Actuator Service")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            Divider()
            Form {
                Picker("SSH host", selection: $profileId) {
                    ForEach(profiles) { profile in
                        Text(profile.name).tag(profile.id)
                    }
                }
                TextField("Service name", text: $name)
                Picker("Scheme", selection: $scheme) {
                    ForEach(ActuatorScheme.allCases, id: \.self) { value in
                        Text(value.rawValue.uppercased()).tag(value)
                    }
                }
                TextField("Management host", text: $host)
                TextField("Management port", text: $port)
                TextField("Base path", text: $basePath)
                Text("The port is reached from the SSH host. Use 127.0.0.1 when Actuator is bound to host loopback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 16)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 470)
    }

    private func save() {
        guard let parsedPort = UInt16(port), parsedPort > 0 else {
            error = "Management port must be between 1 and 65535."
            return
        }
        let service = ActuatorServiceConfiguration(
            id: target.service?.id ?? UUID().uuidString,
            profileId: profileId,
            name: name,
            managementHost: host,
            managementPort: parsedPort,
            scheme: scheme,
            basePath: basePath,
            enabledMetrics: target.service?.enabledMetrics ?? ActuatorServiceConfiguration.defaultMetrics
        )
        if let validationError = service.validationError {
            error = validationError
            return
        }
        onSave(service)
        dismiss()
    }
}

private struct ActuatorAuthenticationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (ActuatorAuthenticationKind, String, String) -> Void

    @State private var kind: ActuatorAuthenticationKind
    @State private var username: String
    @State private var secret = ""

    init(
        current: ActuatorAuthenticationConfiguration,
        onSave: @escaping (ActuatorAuthenticationKind, String, String) -> Void
    ) {
        self.onSave = onSave
        _kind = State(initialValue: current.kind)
        _username = State(initialValue: current.username)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Shared Actuator Authentication")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            Divider()
            Form {
                Picker("Method", selection: $kind) {
                    Text("None").tag(ActuatorAuthenticationKind.none)
                    Text("Basic").tag(ActuatorAuthenticationKind.basic)
                    Text("Bearer token").tag(ActuatorAuthenticationKind.bearer)
                }
                .pickerStyle(.segmented)
                if kind == .basic {
                    TextField("Username", text: $username)
                }
                if kind != .none {
                    SecureField(kind == .basic ? "Password" : "Bearer token", text: $secret)
                    Text("Leave blank to preserve the existing Keychain secret.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    onSave(kind, username, secret)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 460)
    }
}
