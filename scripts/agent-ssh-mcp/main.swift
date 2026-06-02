import Foundation

// Define socket path matching MCPServerManager
var socketPath: String {
    // Check if running on macOS and try to get App Group container path
    if let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.agent-ssh") {
        return groupURL.appendingPathComponent("agent-ssh-mcp.sock").path
    }
    // Fallback for development/non-signed environments
    return NSTemporaryDirectory() + "agent-ssh-mcp.sock"
}

func connectToSocket(path: String) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        fputs("Failed to create socket\n", stderr)
        return -1
    }
    
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    
    let pathBytes = path.utf8CString
    guard pathBytes.count <= 104 else {
        fputs("Socket path too long\n", stderr)
        close(fd)
        return -1
    }
    
    withUnsafeMutablePointer(to: &addr.sun_path) { sunPathPtr in
        let rawPtr = UnsafeMutableRawPointer(sunPathPtr)
        pathBytes.withUnsafeBytes { bytes in
            rawPtr.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
    }
    
    let size = MemoryLayout<sockaddr_un>.size
    let connectResult = withUnsafePointer(to: &addr) { addrPtr in
        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            connect(fd, sockaddrPtr, socklen_t(size))
        }
    }
    
    guard connectResult >= 0 else {
        fputs("Could not connect to agent-ssh socket at \(path). Make sure the agent-ssh application is running.\n", stderr)
        close(fd)
        return -1
    }
    
    return fd
}

func main() {
    let path = socketPath
    let clientFd = connectToSocket(path: path)
    guard clientFd >= 0 else {
        exit(1)
    }
    
    defer { close(clientFd) }
    
    // Set up a thread to read from UDS and write to stdout
    let udsReadQueue = DispatchQueue(label: "com.agent-ssh.mcp.uds-read")
    udsReadQueue.async {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var accumulatedData = Data()
        
        while true {
            let bytesRead = read(clientFd, &buffer, buffer.count)
            if bytesRead <= 0 {
                // Socket closed or errored
                exit(0)
            }
            
            accumulatedData.append(&buffer, count: bytesRead)
            
            while let newlineIndex = accumulatedData.firstIndex(of: UInt8(ascii: "\n")) {
                let messageData = accumulatedData.subdata(in: 0..<newlineIndex)
                accumulatedData.removeSubrange(0...newlineIndex)
                
                if let messageStr = String(data: messageData, encoding: .utf8) {
                    print(messageStr)
                    fflush(stdout)
                }
            }
        }
    }
    
    // Main thread: read from stdin and write to UDS
    while let line = readLine(strippingNewline: true) {
        let payload = line + "\n"
        let payloadData = payload.data(using: .utf8)!
        _ = payloadData.withUnsafeBytes { bytes in
            write(clientFd, bytes.baseAddress!, bytes.count)
        }
    }
}

main()
