import XCTest
@testable import AgentSshMacOS

final class MCPSecurityGateTests: XCTestCase {
    func testReadAndListToolsAreSafe() {
        let gate = MCPSecurityGate.shared
        
        let listResult = gate.classify(tool: "list_dir", arguments: ["path": "/etc"])
        switch listResult {
        case .safe:
            XCTAssert(true)
        default:
            XCTFail("list_dir should be classified as safe")
        }
        
        let readResult = gate.classify(tool: "read_file", arguments: ["path": "/etc/hosts"])
        switch readResult {
        case .safe:
            XCTAssert(true)
        default:
            XCTFail("read_file should be classified as safe")
        }
    }
    
    func testWriteToolIsModifying() {
        let gate = MCPSecurityGate.shared
        
        let result = gate.classify(tool: "write_file", arguments: ["path": "/etc/hosts", "content": "127.0.0.1 localhost"])
        switch result {
        case .modifying(let reason):
            XCTAssert(reason.contains("Write file"))
        default:
            XCTFail("write_file should be classified as modifying")
        }
    }
    
    func testSafeCommandsAreSafe() {
        let gate = MCPSecurityGate.shared
        
        let commands = [
            "uname -a",
            "df -h",
            "free -m",
            "uptime",
            "git status",
            "git diff",
            "docker ps",
            "ls -la /var/log"
        ]
        
        for cmd in commands {
            let result = gate.classify(tool: "run_command", arguments: ["command": cmd])
            switch result {
            case .safe:
                XCTAssert(true)
            default:
                XCTFail("Command '\(cmd)' should be safe")
            }
        }
    }
    
    func testUnsafeCommandsAreModifying() {
        let gate = MCPSecurityGate.shared
        
        let unsafeCmds = [
            "rm -rf /",
            "mv file.txt /tmp",
            "cp config.json backup.json",
            "sudo systemctl restart nginx",
            "kill -9 1234",
            "git commit -m 'oops'",
            "git push origin main",
            "docker run -d redis",
            "docker stop my-container",
            "chmod +x script.sh"
        ]
        
        for cmd in unsafeCmds {
            let result = gate.classify(tool: "run_command", arguments: ["command": cmd])
            switch result {
            case .modifying(let reason):
                XCTAssert(reason.contains("high-risk") || reason.contains("Modify") || reason.contains("redirection") || reason.contains("chmod"))
            default:
                XCTFail("Command '\(cmd)' should be modifying")
            }
        }
    }
    
    func testRedirectionAndPipingAreModifying() {
        let gate = MCPSecurityGate.shared
        
        let cmd = "echo 'malicious' > /etc/shadow"
        let result = gate.classify(tool: "run_command", arguments: ["command": cmd])
        switch result {
        case .modifying(let reason):
            XCTAssert(reason.contains("redirection"))
        default:
            XCTFail("Redirection command should be modifying")
        }
    }
    
    func testSafeQueriesAreSafe() {
        let gate = MCPSecurityGate.shared
        
        let queries = [
            "SELECT * FROM users;",
            "select id, name from products where price > 100;",
            "SELECT count(*) as total FROM sessions"
        ]
        
        for query in queries {
            let result = gate.classify(tool: "postgres_query", arguments: ["query": query])
            switch result {
            case .safe:
                XCTAssert(true)
            default:
                XCTFail("Query '\(query)' should be safe")
            }
        }
    }
    
    func testUnsafeQueriesAreModifying() {
        let gate = MCPSecurityGate.shared
        
        let queries = [
            "UPDATE users SET admin = true;",
            "INSERT INTO logs (message) VALUES ('test');",
            "DELETE FROM sessions WHERE expired = true;",
            "DROP TABLE users;",
            "ALTER TABLE products ADD COLUMN description text;",
            "CREATE TABLE temp_data (val int);"
        ]
        
        for query in queries {
            let result = gate.classify(tool: "postgres_query", arguments: ["query": query])
            switch result {
            case .modifying(let reason):
                XCTAssert(reason.contains("modification"))
            default:
                XCTFail("Query '\(query)' should be modifying")
            }
        }
    }
}
