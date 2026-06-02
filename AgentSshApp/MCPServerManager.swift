import Foundation
import SwiftUI
import Combine
import AgentSshMacOS

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

class MCPServerManager: ObservableObject {
    static let shared = MCPServerManager()
    
    @Published var isServerEnabled: Bool = true {
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
        if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.agent-ssh") {
            return groupURL.appendingPathComponent("agent-ssh-mcp.sock").path
        }
        // Fallback for development/non-signed environments
        return NSTemporaryDirectory() + "agent-ssh-mcp.sock"
    }
    
    private init() {
        self.isServerEnabled = UserDefaults.standard.object(forKey: "agent_ssh_mcp_enabled") as? Bool ?? true
        if isServerEnabled {
            startServer()
        }
    }
    
    func startServer() {
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
    
    private func handleMessage(_ jsonStr: String, responseBlock: @escaping (String) -> Void) {
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            responseBlock(makeErrorResponse(code: -32700, message: "Parse error", id: nil))
            return
        }
        
        let id = json["id"]
        let method = json["method"] as? String ?? ""
        
        switch method {
        case "initialize":
            let response = [
                "jsonrpc": "2.0",
                "id": id ?? 1,
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
            
            DispatchQueue.global(qos: .userInitiated).async {
                self.executeToolCall(id: id, toolName: toolName, connectionId: connectionId, arguments: arguments, responseBlock: responseBlock)
            }
            
        default:
            responseBlock(makeErrorResponse(code: -32601, message: "Method not found", id: id))
        }
    }
    
    private func executeToolCall(id: Any?, toolName: String, connectionId: String, arguments: [String: Any], responseBlock: @escaping (String) -> Void) {
        let argsData = try? JSONSerialization.data(withJSONObject: arguments)
        let argsJson = argsData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        
        let eventId = UUID()
        let classification = MCPSecurityGate.shared.classify(tool: toolName, arguments: arguments)
        
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
    
    private func runCoreExecution(id: Any?, eventId: UUID, toolName: String, connectionId: String, argsJson: String, responseBlock: @escaping (String) -> Void) {
        do {
            let result = try rshellMcpExecute(connectionId: connectionId, tool: toolName, arguments: argsJson)
            self.updateEventStatus(eventId, to: .executed)
            
            // Format success response
            let response = [
                "jsonrpc": "2.0",
                "id": id ?? 1,
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
    
    private func updateEventStatus(_ id: UUID, to status: MCPAuditEvent.Status) {
        DispatchQueue.main.async {
            if let idx = self.auditLog.firstIndex(where: { $0.id == id }) {
                self.auditLog[idx].status = status
            }
        }
    }
    
    private func makeErrorResponse(code: Int, message: String, id: Any?) -> String {
        let errorDict = [
            "jsonrpc": "2.0",
            "id": id ?? 1,
            "error": [
                "code": code,
                "message": message
            ]
        ] as [String: Any]
        return serializeJson(errorDict)
    }
    
    private func serializeJson(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}

// MARK: - BSD Sockets Core

fileprivate class UnixSocketServer {
    private var serverFd: Int32 = -1
    private var isRunning = false
    private let path: String
    private let onDataReceived: (String, @escaping (String) -> Void) -> Void
    
    init(path: String, onDataReceived: @escaping (String, @escaping (String) -> Void) -> Void) {
        self.path = path
        self.onDataReceived = onDataReceived
    }
    
    func start() {
        guard !isRunning else { return }
        isRunning = true
        
        let socketPath = path
        unlink(socketPath)
        
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("Failed to create Unix socket")
            return
        }
        self.serverFd = fd
        
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= 104 else {
            print("Socket path too long")
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
            close(fd)
            return
        }
        
        guard listen(fd, 5) >= 0 else {
            print("Failed to listen on Unix socket")
            close(fd)
            return
        }
        
        print("Unix socket server listening on \(socketPath)")
        
        DispatchQueue.global(qos: .default).async { [weak self] in
            self?.acceptLoop()
        }
    }
    
    func stop() {
        isRunning = false
        if serverFd >= 0 {
            close(serverFd)
            serverFd = -1
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
                    var responseStr: String?
                    
                    onDataReceived(messageStr) { response in
                        responseStr = response
                        sem.signal()
                    }
                    
                    sem.wait()
                    
                    if let response = responseStr {
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
