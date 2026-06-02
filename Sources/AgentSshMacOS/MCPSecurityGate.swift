import Foundation
import LocalAuthentication

public class MCPSecurityGate {
    public static let shared = MCPSecurityGate()
    private init() {}
    
    public enum ActionRisk {
        case safe
        case modifying(reason: String)
    }
    
    public func classify(tool: String, arguments: [String: Any]) -> ActionRisk {
        switch tool {
        case "list_dir", "read_file":
            return .safe
            
        case "write_file":
            let path = arguments["path"] as? String ?? "file"
            return .modifying(reason: "Write file content to '\(path)'")
            
        case "run_command":
            guard let command = arguments["command"] as? String else {
                return .safe
            }
            return classifyShellCommand(command)
            
        case "postgres_query":
            guard let query = arguments["query"] as? String else {
                return .safe
            }
            return classifyPostgresQuery(query)
            
        default:
            return .modifying(reason: "Execute unknown tool '\(tool)'")
        }
    }
    
    private func classifyShellCommand(_ command: String) -> ActionRisk {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ").map { String($0).lowercased() }
        guard let first = parts.first else {
            return .safe
        }
        
        let unsafeCommands = [
            "rm", "mv", "cp", "sudo", "kill", "shutdown", "reboot",
            "systemctl", "service", "apt", "yum", "dnf", "pacman",
            "chmod", "chown", "chgrp", "dd", "mkfs", "fdisk", "parted"
        ]
        
        if unsafeCommands.contains(first) {
            return .modifying(reason: "Execute high-risk command '\(first)'")
        }
        
        // Check for git modification
        if first == "git" && parts.count > 1 {
            let sub = parts[1]
            let unsafeGit = ["commit", "push", "merge", "rebase", "reset", "clean", "checkout"]
            if unsafeGit.contains(sub) {
                return .modifying(reason: "Modify repository state via 'git \(sub)'")
            }
        }
        
        // Check for docker modification
        if first == "docker" && parts.count > 1 {
            let sub = parts[1]
            let unsafeDocker = ["run", "stop", "rm", "rmi", "exec", "build", "push"]
            if unsafeDocker.contains(sub) {
                return .modifying(reason: "Modify container state via 'docker \(sub)'")
            }
        }
        
        // Check for pipe or redirection writes
        if command.contains(">") || command.contains(">>") || command.contains("| sh") || command.contains("| bash") {
            return .modifying(reason: "Command contains shell redirection or piping to shell")
        }
        
        return .safe
    }
    
    private func classifyPostgresQuery(_ query: String) -> ActionRisk {
        let normalized = query.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        let modifyingKeywords = [
            "INSERT ", "UPDATE ", "DELETE ", "DROP ", "ALTER ",
            "CREATE ", "TRUNCATE ", "GRANT ", "REVOKE "
        ]
        
        for kw in modifyingKeywords {
            if normalized.contains(kw) {
                return .modifying(reason: "Execute database modification query (\(kw.trimmingCharacters(in: .whitespaces)))")
            }
        }
        
        return .safe
    }
    
    /// Requests biometric authentication for the modifying action.
    /// Returns true if approved, false otherwise.
    public func requestApproval(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        
        // Touch ID / Face ID / local passcode evaluates
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return await evaluatePolicy(context: context, reason: reason)
        }
        
        return await evaluatePolicy(context: context, reason: reason)
    }
    
    private func evaluatePolicy(context: LAContext, reason: String) async -> Bool {
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Authorize AI action: \(reason)") { success, error in
                if success {
                    continuation.resume(returning: true)
                } else {
                    continuation.resume(returning: false)
                }
            }
        }
    }
}
