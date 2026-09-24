import Foundation
import SwiftUI
import Combine
import AgentSshMacOS
import Darwin
import os

struct MCPAuditEvent: Identifiable, Codable {
    let id: UUID
    let timestamp: Date
    let connectionId: String
    let tool: String
    let arguments: String
    var status: Status
    var reason: String?
    
    enum Status: String, Codable {
        case pending
        case approved
        case silentAllowed
        case denied
        case executed
        case failed
    }
}

/// JSON-RPC request id. Requests carry a number, a string, or nothing; this
/// keeps it a `Sendable` value so it can travel from the socket thread through
/// the approval flow and back into the response.
private enum JSONRPCID: Sendable {
    case int(Int)
    case double(Double)
    case string(String)

    init?(_ raw: Any?) {
        if let value = raw as? String {
            self = .string(value)
        } else if let value = raw as? Int {
            self = .int(value)
        } else if let value = raw as? Double {
            self = .double(value)
        } else {
            return nil
        }
    }

    var jsonValue: Any {
        switch self {
        case .int(let value): return value
        case .double(let value): return value
        case .string(let value): return value
        }
    }
}

/// Owns the MCP socket and the audit log shown in Settings.
///
/// UI state lives on the main actor. Request handling is `nonisolated`: the
/// socket server calls in from its own client threads, and only audit-log
/// updates hop back to the main queue.
@MainActor
final class MCPServerManager: ObservableObject {
    static let shared = MCPServerManager()
    
    @Published var isServerEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(isServerEnabled, forKey: "agent_ssh_mcp_enabled")
            if isServerEnabled {
                startServer()
            } else {
                stopServer()
            }
        }
    }
    
    @Published var auditLog: [MCPAuditEvent] = []
    
    private var socketServer: UnixSocketServer?
    private let loggerQueue = DispatchQueue(label: "com.agent-ssh.mcp.manager")
    
    var socketPath: String {
        // App group container secure directory
        if let groupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: MCPConfiguration.appGroupIdentifier
        ) {
            return groupURL.appendingPathComponent(MCPConfiguration.socketFileName).path
        }
        // Unsigned development builds have no App Group container. Keep the
        // fallback per-user and apply the same 0600 socket permissions below.
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-ssh-mcp-\(getuid()).sock")
            .path
    }
    
    private init() {
        // Off by default: an AI command socket must be an explicit opt-in,
        // not something running before the user has seen the settings pane.
        self.isServerEnabled = MCPConfiguration.enabled(
            from: UserDefaults.standard.object(forKey: "agent_ssh_mcp_enabled") as? Bool
        )
        if isServerEnabled {
            startServer()
        }
    }
    
    func startServer() {
        guard isServerEnabled else { return }
        guard socketServer == nil else { return }
        
        let path = socketPath
        let server = UnixSocketServer(path: path) { [weak self] message, responseBlock in
            self?.handleMessage(message, responseBlock: responseBlock)
        }
        
        self.socketServer = server
        server.start()
        print("MCP Server started at \(path)")
    }
    
    func stopServer() {
        socketServer?.stop()
        socketServer = nil
        print("MCP Server stopped.")
    }
    
    nonisolated private func handleMessage(_ jsonStr: String, responseBlock: @escaping @Sendable (String) -> Void) {
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            responseBlock(makeErrorResponse(code: -32700, message: "Parse error", id: nil))
            return
        }
        
        let id = JSONRPCID(json["id"])
        let method = json["method"] as? String ?? ""
        
        switch method {
        case "initialize":
            let response = [
                "jsonrpc": "2.0",
                "id": id?.jsonValue ?? 1,
                "result": [
                    "protocolVersion": "2024-11-05",
                    "capabilities": [
                        "tools": [:]
                    ],
                    "serverInfo": [
                        "name": "agent-ssh-embedded",
                        "version": "1.0.0"
                    ]
                ]
            ] as [String: Any]
            responseBlock(serializeJson(response))
            
        case "tools/list":
            let tools = [
                [
                    "name": "run_command",
                    "description": "Execute a shell command on the remote SSH server",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "connection_id": [
                                "type": "string",
                                "description": "The active SSH connection identifier (e.g. user@host:port)"
                            ],
                            "command": [
                                "type": "string",
                                "description": "The shell command to execute"
                            ]
                        ],
                        "required": ["connection_id", "command"]
                    ]
                ],
                [
                    "name": "read_file",
                    "description": "Read content of a remote file",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "connection_id": [
                                "type": "string",
                                "description": "The active SSH connection identifier (e.g. user@host:port)"
                            ],
                            "path": [
                                "type": "string",
                                "description": "The remote file path to read"
                            ]
                        ],
                        "required": ["connection_id", "path"]
                    ]
                ],
                [
                    "name": "write_file",
                    "description": "Write content to a remote file",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "connection_id": [
                                "type": "string",
                                "description": "The active SSH connection identifier (e.g. user@host:port)"
                            ],
                            "path": [
                                "type": "string",
                                "description": "The remote file path to write to"
                            ],
                            "content": [
                                "type": "string",
                                "description": "The text content to write"
                            ]
                        ],
                        "required": ["connection_id", "path", "content"]
                    ]
                ],
                [
                    "name": "list_dir",
                    "description": "List files in a remote directory via SFTP",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "connection_id": [
                                "type": "string",
                                "description": "The active SSH connection identifier (e.g. user@host:port)"
                            ],
                            "path": [
                                "type": "string",
                                "description": "The remote directory path"
                            ]
                        ],
                        "required": ["connection_id", "path"]
                    ]
                ],
                [
                    "name": "postgres_query",
                    "description": "Execute a PostgreSQL query on the remote database explorer",
                    "inputSchema": [
                        "type": "object",
                        "properties": [
                            "connection_id": [
                                "type": "string",
                                "description": "The active PostgreSQL database connection identifier (e.g. pg:user@host:port/db)"
                            ],
                            "query": [
                                "type": "string",
                                "description": "The SQL query to execute"
                            ]
                        ],
                        "required": ["connection_id", "query"]
                    ]
                ]
            ]
            let response = [
                "jsonrpc": "2.0",
                "id": id ?? 1,
                "result": [
                    "tools": tools
                ]
            ] as [String: Any]
            responseBlock(serializeJson(response))
            
        case "tools/call":
            guard let params = json["params"] as? [String: Any],
                  let toolName = params["name"] as? String,
                  let arguments = params["arguments"] as? [String: Any],
                  let connectionId = arguments["connection_id"] as? String else {
                responseBlock(makeErrorResponse(code: -32602, message: "Invalid params", id: id))
                return
            }
            
            // Serialize and classify here so only Sendable values cross
            // onto the worker queue.
            let argsData = try? JSONSerialization.data(withJSONObject: arguments)
            let argsJson = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            let classification = MCPSecurityGate.shared.classify(tool: toolName, arguments: arguments)

            DispatchQueue.global(qos: .userInitiated).async {
                self.executeToolCall(
                    id: id,
                    toolName: toolName,
                    connectionId: connectionId,
                    argsJson: argsJson,
                    classification: classification,
                    responseBlock: responseBlock
                )
            }
            
        default:
            responseBlock(makeErrorResponse(code: -32601, message: "Method not found", id: id))
        }
    }
    
    nonisolated private func executeToolCall(
        id: JSONRPCID?,
        toolName: String,
        connectionId: String,
        argsJson: String,
        classification: MCPSecurityGate.ActionRisk,
        responseBlock: @escaping @Sendable (String) -> Void
    ) {
        let eventId = UUID()
        
        // Log pending event
        let initialStatus: MCPAuditEvent.Status = {
            switch classification {
            case .safe: return .silentAllowed
            case .modifying: return .pending
            }
        }()
        
        let initialEvent = MCPAuditEvent(
            id: eventId,
            timestamp: Date(),
            connectionId: connectionId,
            tool: toolName,
            arguments: argsJson,
            status: initialStatus,
            reason: nil
        )
        
        DispatchQueue.main.async {
            self.auditLog.insert(initialEvent, at: 0)
        }
        
        switch classification {
        case .safe:
            // Safe read operations execute silently
            runCoreExecution(id: id, eventId: eventId, toolName: toolName, connectionId: connectionId, argsJson: argsJson, responseBlock: responseBlock)
            
        case .modifying(let reason):
            // Modifying operations must be biometrically approved
            DispatchQueue.main.async {
                // Update audit status to pending UI representation
                if let idx = self.auditLog.firstIndex(where: { $0.id == eventId }) {
                    self.auditLog[idx].reason = reason
                }
                
                Task {
                    let approved = await MCPSecurityGate.shared.requestApproval(reason: reason)
                    if approved {
                        self.updateEventStatus(eventId, to: .approved)
                        // Run FFI
                        DispatchQueue.global(qos: .userInitiated).async {
                            self.runCoreExecution(id: id, eventId: eventId, toolName: toolName, connectionId: connectionId, argsJson: argsJson, responseBlock: responseBlock)
                        }
                    } else {
                        self.updateEventStatus(eventId, to: .denied)
                        responseBlock(self.makeErrorResponse(code: -32603, message: "Biometric authorization denied by the user.", id: id))
                    }
                }
            }
        }
    }
    
    nonisolated private func runCoreExecution(id: JSONRPCID?, eventId: UUID, toolName: String, connectionId: String, argsJson: String, responseBlock: @escaping @Sendable (String) -> Void) {
        do {
            let result = try rshellMcpExecute(connectionId: connectionId, tool: toolName, arguments: argsJson)
            self.updateEventStatus(eventId, to: .executed)
            
            // Format success response
            let response = [
                "jsonrpc": "2.0",
                "id": id?.jsonValue ?? 1,
                "result": [
                    "content": [
                        [
                            "type": "text",
                            "text": result
                        ]
                    ]
                ]
            ] as [String: Any]
            responseBlock(serializeJson(response))
        } catch {
            self.updateEventStatus(eventId, to: .failed)
            responseBlock(makeErrorResponse(code: -32603, message: "Execution error: \(error.localizedDescription)", id: id))
        }
    }
    
    nonisolated private func updateEventStatus(_ id: UUID, to status: MCPAuditEvent.Status) {
        DispatchQueue.main.async {
            if let idx = self.auditLog.firstIndex(where: { $0.id == id }) {
                self.auditLog[idx].status = status
            }
        }
    }
    
    nonisolated private func makeErrorResponse(code: Int, message: String, id: JSONRPCID?) -> String {
        let errorDict = [
            "jsonrpc": "2.0",
            "id": id?.jsonValue ?? 1,
            "error": [
                "code": code,
                "message": message
            ]
        ] as [String: Any]
        return serializeJson(errorDict)
    }
    
    nonisolated private func serializeJson(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}

// MARK: - BSD Sockets Core

/// `start`/`stop` run on the main thread while the accept loop and client
/// handlers run on global queues, so the run flag and listening fd live
/// behind a lock.
fileprivate final class UnixSocketServer: Sendable {
    private struct State {
        var serverFd: Int32 = -1
        var isRunning = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let path: String
    private let onDataReceived: @Sendable (String, @escaping @Sendable (String) -> Void) -> Void

    private var isRunning: Bool {
        state.withLock { $0.isRunning }
    }

    private var serverFd: Int32 {
        state.withLock { $0.serverFd }
    }

    init(path: String, onDataReceived: @escaping @Sendable (String, @escaping @Sendable (String) -> Void) -> Void) {
        self.path = path
        self.onDataReceived = onDataReceived
    }

    private func markStopped() {
        state.withLock { $0.isRunning = false }
    }

    func start() {
        let didStart = state.withLock { state -> Bool in
            guard !state.isRunning else { return false }
            state.isRunning = true
            return true
        }
        guard didStart else { return }
        
        let socketPath = path
        unlink(socketPath)
        
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("Failed to create Unix socket")
            markStopped()
            return
        }
        state.withLock { $0.serverFd = fd }
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= 104 else {
            print("Socket path too long")
            markStopped()
            close(fd)
            return
        }
        
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
            let rawPtr = UnsafeMutableRawPointer(sunPathPtr)
            pathBytes.withUnsafeBytes { bytes in
                rawPtr.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            }
        }
        
        let size = MemoryLayout<sockaddr_un>.size
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(fd, sockaddrPtr, socklen_t(size))
            }
        }
        
        guard bindResult >= 0 else {
            print("Failed to bind Unix socket at \(socketPath)")
            markStopped()
            close(fd)
            return
        }

        do {
            // The socket is a local control plane. Restrict it to the owning
            // user even when the process umask is permissive.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: socketPath
            )
        } catch {
            print("Failed to secure Unix socket at \(socketPath): \(error)")
            markStopped()
            close(fd)
            unlink(socketPath)
            return
        }
        
        guard listen(fd, 5) >= 0 else {
            print("Failed to listen on Unix socket")
            markStopped()
            close(fd)
            unlink(socketPath)
            return
        }
        
        print("Unix socket server listening on \(socketPath)")
        
        DispatchQueue.global(qos: .default).async { [weak self] in
            self?.acceptLoop()
        }
    }
    
    func stop() {
        let fd = state.withLock { state -> Int32 in
            let fd = state.serverFd
            state.isRunning = false
            state.serverFd = -1
            return fd
        }
        if fd >= 0 {
            close(fd)
        }
        unlink(path)
    }
    
    private func acceptLoop() {
        while isRunning {
            var clientAddr = sockaddr_un()
            var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            
            let clientFd = withUnsafeMutablePointer(to: &clientAddr) { clientAddrPtr in
                clientAddrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(serverFd, sockaddrPtr, &clientLen)
                }
            }
            
            guard clientFd >= 0 else {
                if isRunning {
                    usleep(100_000)
                }
                continue
            }
            
            DispatchQueue.global(qos: .default).async { [weak self] in
                self?.handleClient(clientFd)
            }
        }
    }
    
    private func handleClient(_ clientFd: Int32) {
        defer { close(clientFd) }
        
        var buffer = [UInt8](repeating: 0, count: 4096)
        var accumulatedData = Data()
        
        while isRunning {
            let bytesRead = read(clientFd, &buffer, buffer.count)
            if bytesRead <= 0 {
                break
            }
            
            accumulatedData.append(&buffer, count: bytesRead)
            
            while let newlineIndex = accumulatedData.firstIndex(of: UInt8(ascii: "\n")) {
                let messageData = accumulatedData.subdata(in: 0..<newlineIndex)
                accumulatedData.removeSubrange(0...newlineIndex)
                
                if let messageStr = String(data: messageData, encoding: .utf8) {
                    let sem = DispatchSemaphore(value: 0)
                    let responseBox = OSAllocatedUnfairLock<String?>(initialState: nil)

                    onDataReceived(messageStr) { response in
                        responseBox.withLock { $0 = response }
                        sem.signal()
                    }

                    sem.wait()

                    if let response = responseBox.withLock({ $0 }) {
                        let responseData = (response + "\n").data(using: .utf8)!
                        responseData.withUnsafeBytes { bytes in
                            _ = write(clientFd, bytes.baseAddress!, bytes.count)
                        }
                    }
                }
            }
        }
    }
}
