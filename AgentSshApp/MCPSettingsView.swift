import SwiftUI
import AgentSshMacOS
import UniformTypeIdentifiers

struct MCPSettingsView: View {
    @ObservedObject private var mcpManager = MCPServerManager.shared
    @State private var expandedEventId: UUID?
    @State private var showCopyToast = false
    @State private var toastMessage = ""
    
    var body: some View {
        Form {
            // Header Card
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    // Modern AI Pulse Icon
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [.purple, .blue], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 44, height: 44)
                            .shadow(color: .purple.opacity(0.3), radius: 8, x: 0, y: 4)
                        
                        Image(systemName: "cpu.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                    }
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Secure AI Command Center")
                            .font(.title3.weight(.bold))
                        Text("Integrate external AI coding assistants securely with your remote servers.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    Spacer()
                    
                    Toggle("", isOn: $mcpManager.isServerEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .padding()
                .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
                .cornerRadius(12)
            }
            .listRowInsets(EdgeInsets())
            .padding(.bottom, 8)
            
            if mcpManager.isServerEnabled {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "circle.fill")
                                .font(.system(size: 8))
                                .foregroundColor(.green)
                            Text("Active and listening on App Group Socket:")
                                .font(.caption.weight(.medium))
                            Spacer()
                        }
                        
                        Text(mcpManager.socketPath)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .padding(6)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(6)
                            .contextMenu {
                                Button("Copy Path") {
                                    copyToClipboard(mcpManager.socketPath, message: "Copied socket path")
                                }
                            }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Connection Status")
                }
                
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("AI Clients communicate via a lightweight stdio-to-UDS helper CLI.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        TabView {
                            // Claude Desktop configuration
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Add this configuration to your Claude Desktop config:")
                                    .font(.caption.weight(.medium))
                                
                                Text(claudeConfigBlock)
                                    .font(.system(.caption, design: .monospaced))
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(NSColor.controlBackgroundColor))
                                    .cornerRadius(6)
                                    .textSelection(.enabled)
                                
                                Button(action: {
                                    copyToClipboard(claudeConfigBlock, message: "Copied Claude Desktop configuration")
                                }) {
                                    Label("Copy Configuration Block", systemImage: "doc.on.doc.fill")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding()
                            .tabItem { Text("Claude Desktop") }
                            
                            // Cursor configuration
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Add a new MCP server in Cursor settings:")
                                    .font(.caption.weight(.medium))
                                
                                VStack(alignment: .leading, spacing: 6) {
                                    LabeledContent("Type", value: "command")
                                    LabeledContent("Name", value: "agent-ssh")
                                    LabeledContent("Command", value: "agent-ssh-mcp")
                                }
                                .font(.caption)
                                .padding(8)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(6)
                                
                                Text("Make sure the 'agent-ssh-mcp' helper tool is installed in your local shell PATH.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding()
                            .tabItem { Text("Cursor Editor") }
                        }
                        .frame(height: 180)
                        .background(Color(NSColor.windowBackgroundColor).opacity(0.3))
                        .cornerRadius(8)
                    }
                } header: {
                    Text("AI Integration Setup")
                }
                
                Section {
                    if mcpManager.auditLog.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "list.bullet.rectangle.portrait")
                                .font(.system(size: 24))
                                .foregroundColor(.secondary)
                            Text("No AI activities recorded yet.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .background(Color(NSColor.windowBackgroundColor).opacity(0.3))
                        .cornerRadius(8)
                    } else {
                        List {
                            ForEach(mcpManager.auditLog) { event in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        // Timestamp
                                        Text(event.timestamp.formatted(.dateTime.hour().minute().second()))
                                            .font(.caption.monospacedDigit())
                                            .foregroundColor(.secondary)
                                        
                                        // Tool name tag
                                        Text(event.tool)
                                            .font(.caption.weight(.bold))
                                            .foregroundColor(.primary)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Color.purple.opacity(0.1))
                                            .cornerRadius(4)
                                        
                                        Spacer()
                                        
                                        // Connection Label
                                        Text(event.connectionId)
                                            .font(.caption.monospaced())
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                            .frame(maxWidth: 160, alignment: .trailing)
                                        
                                        // Status Pill
                                        statusPill(for: event.status)
                                    }
                                    
                                    if expandedEventId == event.id {
                                        VStack(alignment: .leading, spacing: 6) {
                                            if let reason = event.reason {
                                                Text("Gate Reason: \(reason)")
                                                    .font(.caption.weight(.medium))
                                                    .foregroundColor(.orange)
                                            }
                                            
                                            Text("Arguments:")
                                                .font(.caption.weight(.semibold))
                                            
                                            Text(event.arguments)
                                                .font(.system(.caption, design: .monospaced))
                                                .padding(6)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                                .background(Color(NSColor.controlBackgroundColor))
                                                .cornerRadius(6)
                                                .textSelection(.enabled)
                                        }
                                        .padding(.top, 4)
                                        .transition(.opacity.combined(with: .slide))
                                    }
                                }
                                .padding(.vertical, 6)
                                .background(Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                        if expandedEventId == event.id {
                                            expandedEventId = nil
                                        } else {
                                            expandedEventId = event.id
                                        }
                                    }
                                }
                            }
                        }
                        .frame(minHeight: 180, maxHeight: 300)
                        .cornerRadius(8)
                    }
                } header: {
                    HStack {
                        Text("AI Audit Timeline")
                        Spacer()
                        if !mcpManager.auditLog.isEmpty {
                            Button("Clear Log") {
                                mcpManager.auditLog.removeAll()
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.accentColor)
                            .font(.caption)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .overlay(
            toastOverlay
        )
    }
    
    private var claudeConfigBlock: String {
        return """
        {
          "mcpServers": {
            "agent-ssh": {
              "command": "agent-ssh-mcp"
            }
          }
        }
        """
    }
    
    private func statusPill(for status: MCPAuditEvent.Status) -> some View {
        let text: String
        let color: Color
        
        switch status {
        case .pending:
            text = "Pending Approve"
            color = .orange
        case .approved:
            text = "Approved"
            color = .green
        case .silentAllowed:
            text = "Silent Allowed"
            color = .blue
        case .denied:
            text = "Denied"
            color = .red
        case .executed:
            text = "Executed"
            color = .green
        case .failed:
            text = "Failed"
            color = .red
        }
        
        return Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(color.opacity(0.24), lineWidth: 1)
            )
    }
    
    private func copyToClipboard(_ text: String, message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        toastMessage = message
        withAnimation {
            showCopyToast = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation {
                showCopyToast = false
            }
        }
    }
    
    private var toastOverlay: some View {
        VStack {
            if showCopyToast {
                Spacer()
                Text(toastMessage)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.85))
                    .cornerRadius(20)
                    .shadow(radius: 5)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 24)
            }
        }
    }
}
