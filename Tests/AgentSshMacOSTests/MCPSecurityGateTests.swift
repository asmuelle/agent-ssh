import XCTest
@testable import AgentSshMacOS

final class MCPSecurityGateTests: XCTestCase {
    private let gate = MCPSecurityGate.shared

    // MARK: - Helpers

    private func isSafe(_ command: String) -> Bool {
        if case .safe = gate.classify(tool: "run_command", arguments: ["command": command]) {
            return true
        }
        return false
    }

    private func isModifying(_ command: String) -> Bool {
        if case .modifying = gate.classify(tool: "run_command", arguments: ["command": command]) {
            return true
        }
        return false
    }

    // MARK: - Tool-level classification

    func testReadAndListToolsAreSafe() {
        if case .safe = gate.classify(tool: "list_dir", arguments: ["path": "/etc"]) {} else {
            XCTFail("list_dir should be safe")
        }
        if case .safe = gate.classify(tool: "read_file", arguments: ["path": "/etc/hosts"]) {} else {
            XCTFail("read_file should be safe")
        }
    }

    func testWriteToolIsModifying() {
        let result = gate.classify(tool: "write_file", arguments: ["path": "/etc/hosts", "content": "x"])
        guard case .modifying(let reason) = result else {
            return XCTFail("write_file should be modifying")
        }
        XCTAssertTrue(reason.contains("Write file"))
    }

    func testMissingCommandStringIsModifying() {
        // Fail safe: no readable command means we cannot prove it read-only.
        if case .modifying = gate.classify(tool: "run_command", arguments: [:]) {} else {
            XCTFail("absent command should be modifying")
        }
        if case .modifying = gate.classify(tool: "unknown_tool", arguments: [:]) {} else {
            XCTFail("unknown tool should be modifying")
        }
    }

    // MARK: - Read-only commands stay safe (no approval friction)

    func testDiagnosticCommandsAreSafe() {
        let safe = [
            "uname -a", "df -h", "free -m", "uptime", "ls -la /var/log",
            "git status", "git diff", "docker ps", "cat /etc/hosts",
            "grep -R needle /var/log", "ps aux",
            "tail -n 100 /var/log/syslog",
            "df -h 2>/dev/null", "ls 2>&1", "cat file | grep foo | wc -l",
            "echo \"a > b is just text\"",
        ]
        for cmd in safe {
            XCTAssertTrue(isSafe(cmd), "Command should be safe: \(cmd)")
        }
    }

    // MARK: - Original denylist still caught

    func testHighRiskCommandsAreModifying() {
        let modifying = [
            "rm -rf /", "mv file.txt /tmp", "cp config.json backup.json",
            "kill -9 1234", "chmod +x script.sh", "chown root:root file",
            "dd if=/dev/zero of=/dev/sda", "mkfs.ext4 /dev/sdb1",
            "git commit -m 'oops'", "git push origin main",
            "docker run -d redis", "docker stop c1",
        ]
        for cmd in modifying {
            XCTAssertTrue(isModifying(cmd), "Command should be modifying: \(cmd)")
        }
    }

    // MARK: - Bypass vectors the first-token denylist missed (the CRITICAL fix)

    func testCommandChainingIsCaught() {
        XCTAssertTrue(isModifying("echo hi; rm -rf ~"), "chained rm must be caught")
        XCTAssertTrue(isModifying("ls && rm -rf /tmp/x"), "&& rm must be caught")
        XCTAssertTrue(isModifying("true || shutdown now"), "|| shutdown must be caught")
        XCTAssertTrue(isModifying("cat a | xargs rm"), "piped xargs rm must be caught")
        XCTAssertTrue(isModifying("echo a\nrm -rf /"), "newline-separated rm must be caught")
    }

    func testAbsoluteAndRelativePathsAreCaught() {
        XCTAssertTrue(isModifying("/bin/rm -rf /"), "absolute path to rm must be caught")
        XCTAssertTrue(isModifying("./rm important"), "relative path to rm must be caught")
        XCTAssertTrue(isModifying("/usr/bin/chmod 777 /etc"), "absolute chmod must be caught")
    }

    func testInterpreterWrappersAreCaught() {
        XCTAssertTrue(isModifying("sh -c \"rm -rf /\""), "sh -c must be caught")
        XCTAssertTrue(isModifying("bash -c 'echo x > /etc/passwd'"), "bash -c must be caught")
        XCTAssertTrue(isModifying("python3 -c \"import os; os.remove('/x')\""), "python -c must be caught")
        XCTAssertTrue(isModifying("perl -e 'unlink \"x\"'"), "perl -e must be caught")
    }

    func testEnvAssignmentPrefixIsPeeled() {
        XCTAssertTrue(isModifying("FOO=bar rm x"), "leading env assignment must be peeled")
        XCTAssertTrue(isModifying("A=1 B=2 dd if=/dev/zero of=/x"), "multiple assignments peeled")
    }

    func testWrapperCommandsArePeeled() {
        XCTAssertTrue(isModifying("sudo systemctl restart nginx"), "sudo must be caught")
        XCTAssertTrue(isModifying("env rm -rf /tmp/x"), "env rm must be caught")
        XCTAssertTrue(isModifying("timeout 5 rm big"), "timeout rm must be caught")
        XCTAssertTrue(isModifying("nohup shutdown -h now"), "nohup shutdown must be caught")
    }

    func testCommandSubstitutionIsCaught() {
        XCTAssertTrue(isModifying("cat $(cat /etc/passwd)"), "$() substitution must be caught")
        XCTAssertTrue(isModifying("echo `whoami`"), "backtick substitution must be caught")
        XCTAssertTrue(isModifying("echo \"embedded $(rm x)\""), "substitution inside double quotes must be caught")
    }

    func testFileRedirectionIsCaught() {
        XCTAssertTrue(isModifying("echo malicious > /etc/shadow"), "file redirect must be caught")
        XCTAssertTrue(isModifying("cat x >> /etc/hosts"), "append redirect must be caught")
        // …but redirecting to a null sink is not a write.
        XCTAssertTrue(isSafe("grep foo bar 2>/dev/null"), "2>/dev/null is not a write")
        XCTAssertTrue(isSafe("ls -la > /dev/null"), ">/dev/null is not a write")
    }

    func testFindMutationIsCaught() {
        XCTAssertTrue(isModifying("find . -name '*.tmp' -delete"), "find -delete must be caught")
        XCTAssertTrue(isModifying("find /var -type f -exec rm {} \\;"), "find -exec must be caught")
        XCTAssertTrue(isSafe("find . -name '*.log' -type f"), "read-only find stays safe")
    }

    func testLoopBodyIsCaught() {
        XCTAssertTrue(isModifying("for f in *; do rm $f; done"), "rm inside a loop body must be caught")
    }

    // MARK: - Quoted metacharacters are NOT false positives

    func testQuotedMetacharactersAreSafe() {
        XCTAssertTrue(isSafe("grep 'a; b' file"), "semicolon inside quotes is literal")
        XCTAssertTrue(isSafe("echo 'rm -rf /'"), "denylisted word inside quotes is literal data")
        XCTAssertTrue(isSafe("grep \"pipe | char\" file"), "pipe inside quotes is literal")
    }

    // MARK: - Postgres

    func testSafeQueriesAreSafe() {
        let queries = [
            "SELECT * FROM users;",
            "select id, name from products where price > 100;",
            "SELECT count(*) as total FROM sessions",
        ]
        for q in queries {
            if case .safe = gate.classify(tool: "postgres_query", arguments: ["query": q]) {} else {
                XCTFail("Query should be safe: \(q)")
            }
        }
    }

    func testUnsafeQueriesAreModifying() {
        let queries = [
            "UPDATE users SET admin = true;",
            "INSERT INTO logs (message) VALUES ('test');",
            "DELETE FROM sessions WHERE expired = true;",
            "DROP TABLE users;",
            "ALTER TABLE products ADD COLUMN description text;",
            "CREATE TABLE temp_data (val int);",
            "TRUNCATE audit_log;",
            "delete\nfrom sessions",           // odd whitespace the old substring scan missed
            "WITH x AS (SELECT 1) DELETE FROM t",
        ]
        for q in queries {
            if case .modifying = gate.classify(tool: "postgres_query", arguments: ["query": q]) {} else {
                XCTFail("Query should be modifying: \(q)")
            }
        }
    }
}
