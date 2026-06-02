import SwiftUI
import AgentSshMacOS

@MainActor
final class CloudServerManagementStore: ObservableObject {
    @Published private(set) var accounts: [CloudServerAccountRecord] = []
    @Published private(set) var serversByAccount: [String: [CloudServerRecord]] = [:]
    @Published var selectedAccountId: String?
    @Published var isLoading = false
    @Published var statusMessage: String?
    @Published var errorMessage: String?

    private let integrationStore = PlatformIntegrationStore()
    private let inventoryStore = CloudServerInventoryStore()
    private let tokenStore = CloudServerTokenStore.shared

    var selectedAccount: CloudServerAccountRecord? {
        guard let selectedAccountId else { return accounts.first }
        return accounts.first { $0.id == selectedAccountId }
    }

    func load() {
        do {
            accounts = try integrationStore.load().cloudAccounts.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            let inventory = try inventoryStore.load()
            serversByAccount = Dictionary(
                uniqueKeysWithValues: inventory.snapshots.map { ($0.accountId, $0.servers) }
            )
            if selectedAccountId == nil {
                selectedAccountId = accounts.first?.id
            }
            errorMessage = nil
        } catch {
            errorMessage = "Could not load cloud providers: \(error.localizedDescription)"
        }
    }

    func saveAccount(provider: CloudServerProvider, displayName: String, token: String) {
        let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            errorMessage = "Account name is required."
            return
        }
        guard !cleanToken.isEmpty else {
            errorMessage = "API token is required."
            return
        }

        do {
            var data = try integrationStore.load()
            let account = CloudServerAccountRecord(
                provider: provider,
                displayName: cleanName,
                keychainAccount: "cloud:\(provider.rawValue):\(UUID().uuidString)"
            )
            try tokenStore.saveToken(cleanToken, account: account.keychainAccount)
            data.cloudAccounts.append(account)
            data.cloudAccounts.sort {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            }
            try integrationStore.save(data)
            statusMessage = "\(account.displayName) saved."
            selectedAccountId = account.id
            load()
        } catch {
            errorMessage = "Could not save cloud provider: \(error.localizedDescription)"
        }
    }

    func deleteAccount(_ account: CloudServerAccountRecord) {
        do {
            var data = try integrationStore.load()
            data.cloudAccounts.removeAll { $0.id == account.id }
            try integrationStore.save(data)
            try? tokenStore.deleteToken(account: account.keychainAccount)
            try? inventoryStore.remove(accountId: account.id)
            statusMessage = "\(account.displayName) removed."
            selectedAccountId = nil
            load()
        } catch {
            errorMessage = "Could not remove cloud provider: \(error.localizedDescription)"
        }
    }

    func refreshSelectedAccount() async {
        guard let account = selectedAccount else { return }
        await refresh(account)
    }

    func refresh(_ account: CloudServerAccountRecord) async {
        await runCloudTask {
            let token = try self.requireToken(for: account)
            let client = CloudServerProviderClientFactory.client(for: account.provider)
            let servers = try await client.listServers(account: account, token: token)
            let snapshot = CloudServerInventorySnapshot(
                accountId: account.id,
                provider: account.provider,
                servers: servers
            )
            try self.inventoryStore.upsert(snapshot)
            try self.markRefreshed(account)
            self.serversByAccount[account.id] = servers
            self.statusMessage = "Refreshed \(servers.count) server\(servers.count == 1 ? "" : "s") from \(account.displayName)."
        }
    }

    func createServer(_ request: CloudServerCreateRequest, account: CloudServerAccountRecord) async {
        await runCloudTask {
            let token = try self.requireToken(for: account)
            let client = CloudServerProviderClientFactory.client(for: account.provider)
            let server = try await client.createServer(account: account, token: token, request: request)
            var servers = self.serversByAccount[account.id] ?? []
            servers.removeAll { $0.id == server.id }
            servers.append(server)
            servers.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            self.serversByAccount[account.id] = servers
            try self.inventoryStore.upsert(
                CloudServerInventorySnapshot(
                    accountId: account.id,
                    provider: account.provider,
                    servers: servers
                )
            )
            self.statusMessage = "Created \(server.name)."
        }
    }

    func reboot(_ server: CloudServerRecord, account: CloudServerAccountRecord) async {
        await runCloudTask {
            let token = try self.requireToken(for: account)
            let client = CloudServerProviderClientFactory.client(for: account.provider)
            let result = try await client.rebootServer(
                account: account,
                token: token,
                serverId: server.providerServerId
            )
            self.statusMessage = "\(server.name) reboot \(result.status)."
        }
    }

    func delete(_ server: CloudServerRecord, account: CloudServerAccountRecord) async {
        await runCloudTask {
            let token = try self.requireToken(for: account)
            let client = CloudServerProviderClientFactory.client(for: account.provider)
            let result = try await client.deleteServer(
                account: account,
                token: token,
                serverId: server.providerServerId
            )
            self.serversByAccount[account.id]?.removeAll { $0.id == server.id }
            if let servers = self.serversByAccount[account.id] {
                try self.inventoryStore.upsert(
                    CloudServerInventorySnapshot(
                        accountId: account.id,
                        provider: account.provider,
                        servers: servers
                    )
                )
            }
            self.statusMessage = "\(server.name) delete \(result.status)."
        }
    }

    private func requireToken(for account: CloudServerAccountRecord) throws -> String {
        guard let token = try tokenStore.loadToken(account: account.keychainAccount),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudServerAPIError.invalidAccount("API token is missing for \(account.displayName).")
        }
        return token
    }

    private func markRefreshed(_ account: CloudServerAccountRecord) throws {
        var data = try integrationStore.load()
        guard let index = data.cloudAccounts.firstIndex(where: { $0.id == account.id }) else { return }
        data.cloudAccounts[index].lastRefreshedAt = Date()
        try integrationStore.save(data)
        accounts = data.cloudAccounts.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    private func runCloudTask(_ task: @escaping () async throws -> Void) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            try await task()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct CloudServerManagementView: View {
    @ObservedObject var connectionStore: ConnectionStoreManager
    @StateObject private var store = CloudServerManagementStore()

    @State private var provider: CloudServerProvider = .digitalOcean
    @State private var displayName = ""
    @State private var token = ""
    @State private var createTarget: CloudServerAccountRecord?
    @State private var pendingDelete: CloudServerDeleteTarget?

    var body: some View {
        HStack(spacing: 0) {
            accountColumn
                .frame(width: 220)

            Divider()

            serverColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            store.load()
        }
        .alert(
            "Cloud Provider Error",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .confirmationDialog(
            "Delete Server",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pendingDelete {
                Button("Delete \(pendingDelete.server.name)", role: .destructive) {
                    Task {
                        await store.delete(pendingDelete.server, account: pendingDelete.account)
                        self.pendingDelete = nil
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                pendingDelete = nil
            }
        } message: {
            Text("This requests deletion at the cloud provider. It does not delete generated SSH profiles.")
        }
        .sheet(item: $createTarget) { account in
            CloudServerCreateSheet(account: account) { request in
                Task {
                    await store.createServer(request, account: account)
                    createTarget = nil
                }
            }
        }
    }

    private var accountColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Cloud Providers")
                .font(.headline)

            Picker("Provider", selection: $provider) {
                ForEach(CloudServerProvider.allCases, id: \.self) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.menu)

            TextField("Account name", text: $displayName)
            SecureField("API token", text: $token)

            Button {
                store.saveAccount(provider: provider, displayName: displayName, token: token)
                displayName = ""
                token = ""
            } label: {
                Label("Add Account", systemImage: "plus")
            }

            Divider()

            if store.accounts.isEmpty {
                Text("No cloud provider accounts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                List(selection: $store.selectedAccountId) {
                    ForEach(store.accounts) { account in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.displayName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(account.provider.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .tag(account.id as String?)
                    }
                }
                .listStyle(.sidebar)
            }

            Spacer(minLength: 0)
        }
        .padding()
    }

    private var serverColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let account = store.selectedAccount {
                header(for: account)
                serverList(for: account)
                footer
            } else {
                CloudEmptyState(
                    title: "No Cloud Account",
                    systemImage: "cloud",
                    message: "Add a DigitalOcean or Hetzner API token to manage servers."
                )
            }
        }
        .padding()
    }

    private func header(for account: CloudServerAccountRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(account.displayName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(account.provider.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                Task { await store.refresh(account) }
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            Button {
                createTarget = account
            } label: {
                Label("Create", systemImage: "plus")
            }
            Button(role: .destructive) {
                store.deleteAccount(account)
            } label: {
                Image(systemName: "trash")
            }
            .help("Remove cloud account")
        }
    }

    private func serverList(for account: CloudServerAccountRecord) -> some View {
        let servers = store.serversByAccount[account.id] ?? []
        return Group {
            if servers.isEmpty {
                CloudEmptyState(
                    title: "No Servers",
                    systemImage: "server.rack",
                    message: "Refresh inventory or create a server."
                )
            } else {
                List {
                    ForEach(servers) { server in
                        serverRow(server, account: account)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func serverRow(_ server: CloudServerRecord, account: CloudServerAccountRecord) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: server.status.systemImage)
                .foregroundStyle(server.status.tint)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(serverDetail(server))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Button {
                importProfile(server, account: account)
            } label: {
                Label("Profile", systemImage: "terminal")
            }
            .disabled(server.connectHost == nil)
            .help(server.connectHost == nil ? "No public IP address is available." : "Generate or update SSH profile")

            Button {
                Task { await store.reboot(server, account: account) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Reboot server")

            Button(role: .destructive) {
                pendingDelete = CloudServerDeleteTarget(server: server, account: account)
            } label: {
                Image(systemName: "trash")
            }
            .help("Delete server")
        }
        .padding(.vertical, 4)
    }

    private var footer: some View {
        HStack {
            if let statusMessage = store.statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if let account = store.selectedAccount {
                Button {
                    importAllProfiles(account: account)
                } label: {
                    Label("Import Reachable", systemImage: "square.and.arrow.down")
                }
            }
        }
    }

    private func serverDetail(_ server: CloudServerRecord) -> String {
        [
            server.status.rawValue,
            server.connectHost,
            server.locationLabel,
            server.sizeSlug,
            server.imageSlug ?? server.imageName,
        ]
        .compactMap { $0 }
        .joined(separator: " - ")
    }

    private func importProfile(_ server: CloudServerRecord, account: CloudServerAccountRecord) {
        let report = connectionStore.importCloudServerProfiles([server], account: account)
        store.statusMessage = "Profile import: \(report.summary)."
    }

    private func importAllProfiles(account: CloudServerAccountRecord) {
        let servers = store.serversByAccount[account.id] ?? []
        let report = connectionStore.importCloudServerProfiles(servers, account: account)
        store.statusMessage = "Profile import: \(report.summary)."
    }
}

private struct CloudServerCreateSheet: View {
    let account: CloudServerAccountRecord
    let onCreate: (CloudServerCreateRequest) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var region = ""
    @State private var size = ""
    @State private var image = ""
    @State private var sshKeys = ""
    @State private var tags = "agent-ssh"
    @State private var enableIPv6 = true
    @State private var enableBackups = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create \(account.provider.displayName) Server")
                .font(.headline)

            Form {
                TextField("Name", text: $name)
                TextField("Region", text: $region)
                TextField("Size", text: $size)
                TextField("Image", text: $image)
                TextField("SSH key IDs", text: $sshKeys)
                TextField("Tags", text: $tags)
                Toggle("Enable IPv6", isOn: $enableIPv6)
                Toggle("Enable backups", isOn: $enableBackups)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                Button("Create") {
                    onCreate(request)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(request.validationError != nil)
            }
        }
        .padding()
        .frame(width: 420)
        .onAppear {
            region = account.provider.defaultRegionSlug
            size = account.provider.defaultSizeSlug
            image = account.provider.defaultImageSlug
        }
    }

    private var request: CloudServerCreateRequest {
        CloudServerCreateRequest(
            name: name,
            regionSlug: region,
            sizeSlug: size,
            imageSlug: image,
            sshKeyIds: splitCSV(sshKeys),
            tags: splitCSV(tags),
            enableIPv6: enableIPv6,
            enableBackups: enableBackups
        )
    }

    private func splitCSV(_ value: String) -> [String] {
        value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

private struct CloudEmptyState: View {
    let title: String
    let systemImage: String
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CloudServerDeleteTarget: Identifiable {
    var id: String { "\(account.id):\(server.id)" }
    let server: CloudServerRecord
    let account: CloudServerAccountRecord
}

private extension CloudServerPowerState {
    var systemImage: String {
        switch self {
        case .running:
            return "checkmark.circle.fill"
        case .stopped:
            return "stop.circle.fill"
        case .provisioning:
            return "clock.fill"
        case .rebooting:
            return "arrow.clockwise.circle.fill"
        case .deleting:
            return "trash.circle.fill"
        case .error:
            return "xmark.octagon.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .running:
            return .green
        case .stopped:
            return .secondary
        case .provisioning, .rebooting:
            return .blue
        case .deleting:
            return .orange
        case .error:
            return .red
        case .unknown:
            return .gray
        }
    }
}
