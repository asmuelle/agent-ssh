import SwiftUI
import AgentSshMacOS
import OSLog

// =============================================================================
// Network Tools — single window with four tabs:
//   • Git deploy-state    — current branch / HEAD / dirty / last commit
//   • DNS multi-perspective — parallel `dig` across all live SSH hosts + Mac
//   • Listening ports     — `ss -tunlp` / `netstat -tunlp` for one host
//   • Packet capture      — streaming `tcpdump -lnn` lines
//
// The window is opened from the new "Tools" menu in AgentSshApp.swift. It
// only operates on currently-connected SSH tabs; if none exist, every
// pane shows a "connect to a host first" empty state.
// =============================================================================

struct NetworkToolsWindow: View {
    @EnvironmentObject var tabsStore: TerminalTabsStore
    @State private var selection: ToolTab = .git

    enum ToolTab: String, CaseIterable, Hashable {
        case git, dns, ports, packets

        var label: String {
            switch self {
            case .git:     return "Git"
            case .dns:     return "DNS"
            case .ports:   return "Ports"
            case .packets: return "Packets"
            }
        }

        var symbol: String {
            switch self {
            case .git:     return "arrow.triangle.branch"
            case .dns:     return "globe"
            case .ports:   return "network"
            case .packets: return "waveform.path.ecg"
            }
        }
    }

    var body: some View {
        TabView(selection: $selection) {
            GitDeployTabView(connectedTabs: tabsStore.connectedSSHTabs)
                .tabItem { Label("Git", systemImage: ToolTab.git.symbol) }
                .tag(ToolTab.git)

            DnsMultiPerspectiveTabView(connectedTabs: tabsStore.connectedSSHTabs)
                .tabItem { Label("DNS", systemImage: ToolTab.dns.symbol) }
                .tag(ToolTab.dns)

            ListeningPortsTabView(connectedTabs: tabsStore.connectedSSHTabs)
                .tabItem { Label("Ports", systemImage: ToolTab.ports.symbol) }
                .tag(ToolTab.ports)

            PacketCaptureTabView(connectedTabs: tabsStore.connectedSSHTabs)
                .tabItem { Label("Packets", systemImage: ToolTab.packets.symbol) }
                .tag(ToolTab.packets)
        }
        .padding(12)
        .frame(minWidth: 760, minHeight: 480)
    }
}

// MARK: - Shared empty state

private struct NoConnectionsView: View {
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "powerplug")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("No SSH hosts connected")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HostPicker: View {
    let connectedTabs: [TerminalTab]
    @Binding var selectedConnectionId: String?

    var body: some View {
        Picker("Host", selection: $selectedConnectionId) {
            Text("Select a host…").tag(String?.none)
            ForEach(connectedTabs, id: \.connectionId) { tab in
                Text(tab.title.isEmpty ? tab.profile.name : tab.title)
                    .tag(Optional(tab.connectionId))
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: 320)
    }
}

// MARK: - Git deploy-state tab

private struct GitDeployTabView: View {
    let connectedTabs: [TerminalTab]
    @State private var selectedConnectionId: String?
    @State private var repoPath: String = "/srv/app"
    @State private var status: FfiGitStatus?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        if connectedTabs.isEmpty {
            NoConnectionsView(message: "Connect to a host in the sidebar to inspect a deployed repository.")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    HostPicker(connectedTabs: connectedTabs, selectedConnectionId: $selectedConnectionId)
                    TextField("Repo path (e.g. /srv/app)", text: $repoPath)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        Task { await load() }
                    } label: {
                        if loading { ProgressView().controlSize(.small) }
                        else       { Text("Inspect") }
                    }
                    .disabled(selectedConnectionId == nil || repoPath.isEmpty || loading)
                }

                Divider()

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                } else if let status {
                    GitStatusDetail(status: status)
                } else {
                    Text("Pick a host and a repo path, then Inspect.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                }

                Spacer()
            }
            .onAppear {
                if selectedConnectionId == nil, let first = connectedTabs.first {
                    selectedConnectionId = first.connectionId
                }
            }
        }
    }

    private func load() async {
        guard let connectionId = selectedConnectionId else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            status = try await BridgeManager.shared.toolsGitStatus(
                connectionId: connectionId,
                repoPath: repoPath
            )
        } catch {
            self.status = nil
            self.error = error.localizedDescription
        }
    }
}

private struct GitStatusDetail: View {
    let status: FfiGitStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.tint)
                Text(status.branch ?? "(detached)")
                    .font(.title2.weight(.semibold))
                if status.dirtyFiles + status.untrackedFiles > 0 {
                    Text("dirty")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.2), in: Capsule())
                        .foregroundStyle(Color.orange)
                } else {
                    Text("clean")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2), in: Capsule())
                        .foregroundStyle(Color.green)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("HEAD").foregroundStyle(.secondary)
                    Text(shortSha(status.head) ?? "—").font(.system(.body, design: .monospaced))
                }
                GridRow {
                    Text("Upstream").foregroundStyle(.secondary)
                    Text(status.upstream ?? "—")
                }
                GridRow {
                    Text("Ahead / Behind").foregroundStyle(.secondary)
                    Text("\(status.ahead) / \(status.behind)")
                }
                GridRow {
                    Text("Modified").foregroundStyle(.secondary)
                    Text("\(status.dirtyFiles) tracked, \(status.untrackedFiles) untracked")
                }
                GridRow {
                    Text("Last commit").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(status.lastCommitSubject ?? "—")
                        if let author = status.lastCommitAuthor, let age = status.lastCommitAge {
                            Text("\(author) — \(age)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .font(.body)
        }
        .padding(.vertical, 8)
    }

    private func shortSha(_ sha: String?) -> String? {
        guard let sha, sha.count >= 7 else { return sha }
        return String(sha.prefix(10))
    }
}

// MARK: - DNS tab

private struct DnsMultiPerspectiveTabView: View {
    let connectedTabs: [TerminalTab]
    @State private var name: String = ""
    @State private var recordType: FfiDnsRecordType = .a
    @State private var includeLocal: Bool = true
    @State private var answers: [FfiDnsAnswer] = []
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Hostname (e.g. example.com)", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Picker("Type", selection: $recordType) {
                    Text("A").tag(FfiDnsRecordType.a)
                    Text("AAAA").tag(FfiDnsRecordType.aaaa)
                    Text("CNAME").tag(FfiDnsRecordType.cname)
                    Text("MX").tag(FfiDnsRecordType.mx)
                    Text("TXT").tag(FfiDnsRecordType.txt)
                    Text("NS").tag(FfiDnsRecordType.ns)
                }
                .frame(maxWidth: 120)
                Toggle("Local Mac", isOn: $includeLocal)
                Button {
                    Task { await resolve() }
                } label: {
                    if loading { ProgressView().controlSize(.small) }
                    else       { Text("Resolve") }
                }
                .disabled(name.isEmpty || loading)
            }

            Divider()

            if answers.isEmpty {
                Text("Enter a hostname, then Resolve. Each connected SSH host plus your Mac will be queried in parallel — useful for spotting split-horizon or stale caches.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 24)
            } else {
                Table(answers.indexed) {
                    TableColumn("Perspective") { row in
                        Text(row.value.perspective)
                            .font(.system(.body, design: .monospaced))
                    }
                    TableColumn("Records") { row in
                        if let err = row.value.error, !err.isEmpty {
                            Text(err)
                                .foregroundStyle(.red)
                                .font(.system(.body, design: .monospaced))
                        } else if row.value.answers.isEmpty {
                            Text("—").foregroundStyle(.secondary)
                        } else {
                            Text(row.value.answers.joined(separator: "\n"))
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                    TableColumn("ms") { row in
                        Text("\(row.value.elapsedMs)").foregroundStyle(.secondary)
                    }
                    .width(50)
                }
            }

            Spacer()
        }
    }

    private func resolve() async {
        loading = true
        defer { loading = false }
        var perspectives = connectedTabs.map { $0.connectionId }
        if includeLocal { perspectives.insert("local", at: 0) }
        guard !perspectives.isEmpty else {
            answers = []
            return
        }
        answers = await BridgeManager.shared.toolsDnsResolve(
            name: name,
            recordType: recordType,
            perspectives: perspectives
        )
    }
}

// MARK: - Listening ports tab

private struct ListeningPortsTabView: View {
    let connectedTabs: [TerminalTab]
    @State private var selectedConnectionId: String?
    @State private var ports: [FfiListeningPort] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        if connectedTabs.isEmpty {
            NoConnectionsView(message: "Connect to a host first to inventory its listening ports.")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    HostPicker(connectedTabs: connectedTabs, selectedConnectionId: $selectedConnectionId)
                    Button {
                        Task { await load() }
                    } label: {
                        if loading { ProgressView().controlSize(.small) }
                        else       { Text("Refresh") }
                    }
                    .disabled(selectedConnectionId == nil || loading)
                    Spacer()
                    Text("\(ports.count) listeners")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }

                Divider()

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                } else if ports.isEmpty {
                    Text("Pick a host, then Refresh.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 24)
                } else {
                    Table(ports.indexed) {
                        TableColumn("Proto") { row in
                            Text(row.value.protocol).font(.system(.body, design: .monospaced))
                        }
                        .width(60)
                        TableColumn("Address") { row in
                            Text(row.value.localAddr).font(.system(.body, design: .monospaced))
                        }
                        TableColumn("Port") { row in
                            Text("\(row.value.port)")
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .width(70)
                        TableColumn("Process") { row in
                            HStack(spacing: 6) {
                                Text(row.value.process ?? "—")
                                    .font(.system(.body, design: .monospaced))
                                if let pid = row.value.pid {
                                    Text("(\(pid))").foregroundStyle(.secondary).font(.caption)
                                }
                            }
                        }
                    }
                }

                Spacer()
            }
            .onAppear {
                if selectedConnectionId == nil, let first = connectedTabs.first {
                    selectedConnectionId = first.connectionId
                }
            }
        }
    }

    private func load() async {
        guard let connectionId = selectedConnectionId else { return }
        loading = true
        error = nil
        defer { loading = false }
        do {
            ports = try await BridgeManager.shared.toolsListeningPorts(connectionId: connectionId)
        } catch {
            ports = []
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Packet capture tab

private struct PacketCaptureTabView: View {
    let connectedTabs: [TerminalTab]
    @StateObject private var capture = TcpdumpCaptureModel()

    var body: some View {
        if connectedTabs.isEmpty {
            NoConnectionsView(message: "Connect to a host first to start a packet capture.")
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    HostPicker(connectedTabs: connectedTabs, selectedConnectionId: $capture.selectedConnectionId)
                        .disabled(capture.isRunning)
                    TextField("Interface (e.g. any, eth0)", text: $capture.interface)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                        .disabled(capture.isRunning)
                    TextField("BPF filter (optional)", text: $capture.filter)
                        .textFieldStyle(.roundedBorder)
                        .disabled(capture.isRunning)
                    if capture.isRunning {
                        Button("Stop", role: .destructive) {
                            Task { await capture.stop() }
                        }
                    } else {
                        Button("Start") {
                            Task { await capture.start() }
                        }
                        .disabled(capture.selectedConnectionId == nil || capture.interface.isEmpty)
                    }
                    Button("Clear") { capture.clear() }
                        .disabled(capture.lines.isEmpty)
                }

                if let err = capture.error {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }

                Text("tcpdump runs via `sudo -n`; the SSH user must have a NOPASSWD sudo rule for tcpdump or be in a group that owns the capture interface.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(capture.lines) { line in
                                Text(line.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(line.isStderr ? Color.secondary : Color.primary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .background(Color(NSColor.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .onChange(of: capture.lines.count) { _ in
                        if let last = capture.lines.last {
                            withAnimation(.linear(duration: 0.1)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                Spacer()
            }
            .onAppear {
                if capture.selectedConnectionId == nil, let first = connectedTabs.first {
                    capture.selectedConnectionId = first.connectionId
                }
            }
            .onDisappear {
                Task { await capture.stop() }
            }
        }
    }
}

@MainActor
private final class TcpdumpCaptureModel: ObservableObject {
    private let logger = Logger(subsystem: "com.mc-ssh", category: "tcpdump")

    struct Line: Identifiable, Hashable {
        let id: UUID = UUID()
        let text: String
        let isStderr: Bool
    }

    @Published var selectedConnectionId: String?
    @Published var interface: String = "any"
    @Published var filter: String = ""
    @Published private(set) var lines: [Line] = []
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var captureId: UInt64?
    @Published var error: String?

    private static let maxLines = 5000
    private var subscription: Any?

    init() {
        // Subscribe once to the event bus and filter for our active capture id.
        subscription = AgentSshEventBus.shared.events.sink { [weak self] event in
            guard case let .tcpdumpLine(id, line, isStderr) = event else { return }
            Task { @MainActor in
                guard let self, self.captureId == id else { return }
                self.lines.append(Line(text: line, isStderr: isStderr))
                if self.lines.count > Self.maxLines {
                    self.lines.removeFirst(self.lines.count - Self.maxLines)
                }
            }
        }
    }

    func start() async {
        guard let connectionId = selectedConnectionId else { return }
        error = nil
        do {
            let id = try await BridgeManager.shared.toolsTcpdumpStart(
                connectionId: connectionId,
                interface: interface,
                filter: filter,
                snaplen: nil
            )
            captureId = id
            isRunning = true
        } catch {
            logger.error("tcpdump start failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
            isRunning = false
            captureId = nil
        }
    }

    func stop() async {
        guard let id = captureId else {
            isRunning = false
            return
        }
        do {
            try await BridgeManager.shared.toolsTcpdumpStop(captureId: id)
        } catch {
            logger.warning("tcpdump stop returned error: \(error.localizedDescription, privacy: .public)")
        }
        captureId = nil
        isRunning = false
    }

    func clear() {
        lines.removeAll()
    }
}

// MARK: - Helpers

private struct IndexedRow<T>: Identifiable {
    let id: Int
    let value: T
}

private extension Array {
    var indexed: [IndexedRow<Element>] {
        enumerated().map { IndexedRow(id: $0.offset, value: $0.element) }
    }
}
