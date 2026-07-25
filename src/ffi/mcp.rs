use super::*;

static MCP_PG_SESSION_COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

// ---------------------------------------------------------------------------
// Model Context Protocol (MCP) Execution Engine
// ---------------------------------------------------------------------------

/// Builds a shell command that writes `content` verbatim to `path` on the
/// remote host.
///
/// Both arguments are passed as single-quoted shell tokens via
/// `shell_escape::unix::escape`, so neither the caller-supplied path nor the
/// content can break out of quoting to inject additional commands. This
/// replaces an earlier heredoc (`cat << 'EOF' …`) which terminated early — and
/// executed the remainder of `content` as shell commands — whenever the content
/// contained a line equal to the heredoc sentinel.
///
/// `printf '%s'` writes the content exactly as given: unlike `echo` or
/// `printf '%b'`, it performs no backslash-escape interpretation.
fn build_write_file_command(path: &str, content: &str) -> String {
    use std::borrow::Cow;
    let quoted_content = shell_escape::unix::escape(Cow::Borrowed(content));
    let quoted_path = shell_escape::unix::escape(Cow::Borrowed(path));
    format!("printf '%s' {quoted_content} > {quoted_path}")
}

/// Builds a shell command that reads `path` on the remote host.
///
/// The path is passed as a single-quoted shell token via
/// `shell_escape::unix::escape` — same quoting strategy as
/// `build_write_file_command` — so it cannot break out and inject commands.
fn build_read_file_command(path: &str) -> String {
    use std::borrow::Cow;
    let quoted_path = shell_escape::unix::escape(Cow::Borrowed(path));
    format!("cat {quoted_path}")
}

/// Read-only statement openers permitted for the AI-driven `postgres_query`
/// tool. A single statement starting with one of these — and nothing that can
/// re-enter a read-write transaction — is the boundary that makes the
/// server-side read-only session default (below) actually authoritative.
const READ_ONLY_OPENERS: [&str; 6] = ["SELECT", "WITH", "SHOW", "EXPLAIN", "TABLE", "VALUES"];

/// Rejects any `postgres_query` input that isn't a single, read-only statement.
///
/// This is the real read-only boundary. PostgreSQL's
/// `default_transaction_read_only` is *not* a security backstop on its own: any
/// transaction can opt out with `BEGIN READ WRITE` / `SET TRANSACTION READ
/// WRITE`, and the underlying execute path uses the simple-query protocol, which
/// runs several `;`-separated statements in one request. So a payload like
/// `BEGIN READ WRITE; DELETE FROM users` would otherwise override the default
/// and execute the write. Refusing multi-statement input and non-read-only
/// leading keywords removes that escape hatch before the query reaches the
/// server; the read-only session default then catches the residual case of a
/// data-modifying CTE (`WITH x AS (DELETE …) SELECT …`), which the engine
/// rejects while the default is on and which — having passed this check — has no
/// way to flip the default back.
///
/// Conservative by construction: anything it can't prove is a single read-only
/// statement is rejected.
fn validate_read_only_query(query: &str) -> Result<(), String> {
    let stripped = strip_sql_noise(query)?;
    let trimmed = stripped.trim();
    if trimmed.is_empty() {
        return Err("query is empty".into());
    }
    // At most one trailing ';' — anything after it is a second statement.
    let single = trimmed.strip_suffix(';').unwrap_or(trimmed).trim_end();
    if single.contains(';') {
        return Err("only a single read-only statement is allowed".into());
    }
    let leading = single
        .split(|c: char| c.is_whitespace() || c == '(')
        .find(|token| !token.is_empty())
        .unwrap_or("")
        .to_ascii_uppercase();
    if !READ_ONLY_OPENERS.contains(&leading.as_str()) {
        return Err(format!(
            "statement type '{leading}' is not permitted; only read-only queries are allowed"
        ));
    }
    // EXPLAIN ANALYZE actually executes the plan (and thus any writes in it).
    if leading == "EXPLAIN"
        && single
            .to_ascii_uppercase()
            .split(|c: char| !c.is_alphanumeric())
            .any(|token| token == "ANALYZE")
    {
        return Err("EXPLAIN ANALYZE executes the statement and is not permitted".into());
    }
    Ok(())
}

/// Replaces SQL string literals, dollar-quoted strings, quoted identifiers, and
/// comments with spaces so [`validate_read_only_query`]'s structural checks
/// (statement counting, leading keyword) can't be fooled by a `;` or keyword
/// appearing inside a literal. Errors on an unterminated literal/comment, which
/// we refuse to run rather than guess at.
fn strip_sql_noise(query: &str) -> Result<String, String> {
    let chars: Vec<char> = query.chars().collect();
    let n = chars.len();
    let mut out = String::with_capacity(query.len());
    let mut i = 0;
    while i < n {
        let c = chars[i];
        // Line comment: `-- …` to end of line.
        if c == '-' && i + 1 < n && chars[i + 1] == '-' {
            i += 2;
            while i < n && chars[i] != '\n' {
                i += 1;
            }
            out.push(' ');
            continue;
        }
        // Block comment: `/* … */`, nestable in PostgreSQL.
        if c == '/' && i + 1 < n && chars[i + 1] == '*' {
            i += 2;
            let mut depth = 1usize;
            while i < n && depth > 0 {
                if chars[i] == '/' && i + 1 < n && chars[i + 1] == '*' {
                    depth += 1;
                    i += 2;
                } else if chars[i] == '*' && i + 1 < n && chars[i + 1] == '/' {
                    depth -= 1;
                    i += 2;
                } else {
                    i += 1;
                }
            }
            if depth != 0 {
                return Err("unterminated block comment".into());
            }
            out.push(' ');
            continue;
        }
        // Single-quoted string literal ('' is an escaped quote).
        if c == '\'' {
            i += 1;
            loop {
                if i >= n {
                    return Err("unterminated string literal".into());
                }
                if chars[i] == '\'' {
                    if i + 1 < n && chars[i + 1] == '\'' {
                        i += 2;
                        continue;
                    }
                    i += 1;
                    break;
                }
                i += 1;
            }
            out.push(' ');
            continue;
        }
        // Quoted identifier ("" is an escaped quote).
        if c == '"' {
            i += 1;
            loop {
                if i >= n {
                    return Err("unterminated quoted identifier".into());
                }
                if chars[i] == '"' {
                    if i + 1 < n && chars[i + 1] == '"' {
                        i += 2;
                        continue;
                    }
                    i += 1;
                    break;
                }
                i += 1;
            }
            out.push(' ');
            continue;
        }
        // Dollar-quoted string: `$tag$ … $tag$` (tag may be empty: `$$`).
        // `$1` and the like are parameter placeholders, not dollar quotes.
        if c == '$'
            && let Some(tag) = dollar_tag(&chars[i..])
        {
            i += tag.len();
            let Some(pos) = find_subslice(&chars[i..], &tag) else {
                return Err("unterminated dollar-quoted string".into());
            };
            i += pos + tag.len();
            out.push(' ');
            continue;
        }
        out.push(c);
        i += 1;
    }
    Ok(out)
}

/// If `chars` starts with a dollar-quote opening delimiter (`$tag$` where `tag`
/// is empty or a valid identifier that doesn't start with a digit), returns the
/// delimiter including both `$`. Returns `None` for parameter placeholders
/// (`$1`) and anything that isn't a complete opening delimiter.
fn dollar_tag(chars: &[char]) -> Option<Vec<char>> {
    debug_assert_eq!(chars.first(), Some(&'$'));
    let mut j = 1;
    while j < chars.len() && chars[j] != '$' {
        let ch = chars[j];
        let valid = ch == '_' || ch.is_ascii_alphabetic() || (j > 1 && ch.is_ascii_digit());
        if !valid {
            return None;
        }
        j += 1;
    }
    if j < chars.len() && chars[j] == '$' {
        Some(chars[..=j].to_vec())
    } else {
        None
    }
}

/// Index of the first occurrence of `needle` within `haystack`, by char.
fn find_subslice(haystack: &[char], needle: &[char]) -> Option<usize> {
    if needle.is_empty() || needle.len() > haystack.len() {
        return None;
    }
    (0..=haystack.len() - needle.len())
        .find(|&start| &haystack[start..start + needle.len()] == needle)
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FfiMcpError {
    #[error("connection not found: {connection_id}")]
    ConnectionNotFound { connection_id: String },
    #[error("execution error: {message}")]
    Execution { message: String },
    #[error("json serialization error: {message}")]
    Serialization { message: String },
    #[error("invalid arguments: {message}")]
    InvalidArguments { message: String },
    #[error("unknown tool: {name}")]
    UnknownTool { name: String },
}

#[uniffi::export]
pub fn rshell_mcp_execute(
    connection_id: String,
    tool: String,
    arguments: String,
) -> Result<String, FfiMcpError> {
    let parsed_args: serde_json::Value =
        serde_json::from_str(&arguments).map_err(|e| FfiMcpError::Serialization {
            message: e.to_string(),
        })?;

    match tool.as_str() {
        // SECURITY: `run_command` is intentionally unrestricted (no read-only
        // allowlist). The Swift side gates AI-initiated tool calls behind
        // MCPSecurityGate (biometric auth for mutating commands); this layer
        // trusts its caller. Never route tool calls here from a remote or
        // otherwise untrusted source without adding a guard.
        "run_command" => {
            let command = parsed_args
                .get("command")
                .and_then(|v| v.as_str())
                .ok_or_else(|| FfiMcpError::InvalidArguments {
                    message: "missing 'command' parameter".into(),
                })?;

            let bridge = MacOsBridge::global();
            let cm = bridge.connection_manager.clone();
            let output = bridge
                .runtime
                .block_on(async move {
                    let client = cm.get_connection(&connection_id).await;
                    match client {
                        Some(c) => {
                            let client = c.read().await;
                            match tokio::time::timeout(
                                COMMAND_TIMEOUT,
                                client.execute_command(command),
                            )
                            .await
                            {
                                Ok(result) => result,
                                Err(_) => Err(anyhow::anyhow!(
                                    "command timed out after {}s",
                                    COMMAND_TIMEOUT.as_secs()
                                )),
                            }
                        }
                        None => Err(anyhow::anyhow!("Connection not found: {}", connection_id)),
                    }
                })
                .map_err(|e| FfiMcpError::Execution {
                    message: e.to_string(),
                })?;

            Ok(output)
        }
        "read_file" => {
            let path = parsed_args
                .get("path")
                .and_then(|v| v.as_str())
                .ok_or_else(|| FfiMcpError::InvalidArguments {
                    message: "missing 'path' parameter".into(),
                })?;

            let command = build_read_file_command(path);

            let bridge = MacOsBridge::global();
            let cm = bridge.connection_manager.clone();
            let output = bridge
                .runtime
                .block_on(async move {
                    let client = cm.get_connection(&connection_id).await;
                    match client {
                        Some(c) => {
                            let client = c.read().await;
                            match tokio::time::timeout(
                                COMMAND_TIMEOUT,
                                client.execute_command(&command),
                            )
                            .await
                            {
                                Ok(result) => result,
                                Err(_) => Err(anyhow::anyhow!(
                                    "command timed out after {}s",
                                    COMMAND_TIMEOUT.as_secs()
                                )),
                            }
                        }
                        None => Err(anyhow::anyhow!("Connection not found: {}", connection_id)),
                    }
                })
                .map_err(|e| FfiMcpError::Execution {
                    message: e.to_string(),
                })?;

            Ok(output)
        }
        "write_file" => {
            let path = parsed_args
                .get("path")
                .and_then(|v| v.as_str())
                .ok_or_else(|| FfiMcpError::InvalidArguments {
                    message: "missing 'path' parameter".into(),
                })?;
            let content = parsed_args
                .get("content")
                .and_then(|v| v.as_str())
                .ok_or_else(|| FfiMcpError::InvalidArguments {
                    message: "missing 'content' parameter".into(),
                })?;

            let command = build_write_file_command(path, content);

            let bridge = MacOsBridge::global();
            let cm = bridge.connection_manager.clone();
            let output = bridge
                .runtime
                .block_on(async move {
                    let client = cm.get_connection(&connection_id).await;
                    match client {
                        Some(c) => {
                            let client = c.read().await;
                            match tokio::time::timeout(
                                COMMAND_TIMEOUT,
                                client.execute_command(&command),
                            )
                            .await
                            {
                                Ok(result) => result,
                                Err(_) => Err(anyhow::anyhow!(
                                    "command timed out after {}s",
                                    COMMAND_TIMEOUT.as_secs()
                                )),
                            }
                        }
                        None => Err(anyhow::anyhow!("Connection not found: {}", connection_id)),
                    }
                })
                .map_err(|e| FfiMcpError::Execution {
                    message: e.to_string(),
                })?;

            Ok(output)
        }
        "list_dir" => {
            let path = parsed_args
                .get("path")
                .and_then(|v| v.as_str())
                .ok_or_else(|| FfiMcpError::InvalidArguments {
                    message: "missing 'path' parameter".into(),
                })?;

            let entries = rshell_sftp_list_dir(connection_id, path.to_string()).map_err(|e| {
                FfiMcpError::Execution {
                    message: e.to_string(),
                }
            })?;

            let serialized_entries: Vec<serde_json::Value> = entries
                .iter()
                .map(|e| {
                    let kind_str = match e.kind {
                        FfiFileKind::File => "file",
                        FfiFileKind::Directory => "directory",
                        FfiFileKind::Symlink => "symlink",
                    };
                    serde_json::json!({
                        "name": e.name,
                        "size": e.size,
                        "modified": e.modified,
                        "modified_unix": e.modified_unix,
                        "permissions": e.permissions,
                        "owner": e.owner,
                        "group": e.group,
                        "kind": kind_str
                    })
                })
                .collect();

            let json_str = serde_json::to_string(&serialized_entries).map_err(|e| {
                FfiMcpError::Serialization {
                    message: e.to_string(),
                }
            })?;

            Ok(json_str)
        }
        "postgres_query" => {
            let query = parsed_args
                .get("query")
                .and_then(|v| v.as_str())
                .ok_or_else(|| FfiMcpError::InvalidArguments {
                    message: "missing 'query' parameter".into(),
                })?;

            // Primary read-only boundary: refuse anything that isn't a single
            // read-only statement. Without this, `default_transaction_read_only`
            // (set below) is trivially overridable by a `BEGIN READ WRITE; …`
            // smuggled through the simple-query protocol. See
            // `validate_read_only_query`.
            validate_read_only_query(query).map_err(|message| FfiMcpError::InvalidArguments {
                message: format!("query rejected as not read-only: {message}"),
            })?;

            // Defense in depth: the Swift gate classifies SQL before it reaches
            // this layer, and the validation above bounds it to a single
            // read-only statement. A dedicated session with the read-only
            // default then makes PostgreSQL authoritative — a data-modifying CTE
            // that slips past a leading-keyword check is still rejected by the
            // engine, and (having passed validation) the query has no way to
            // flip the default back.
            let session_id = format!(
                "mcp-read-only-{}-{}",
                std::process::id(),
                MCP_PG_SESSION_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
            );
            if let Err(error) = rshell_pg_execute(
                connection_id.clone(),
                session_id.clone(),
                "SET default_transaction_read_only = on".into(),
                1,
            ) {
                let _ =
                    super::postgres::schema::rshell_pg_release_session(connection_id, session_id);
                return Err(FfiMcpError::Execution {
                    message: format!("failed to enforce PostgreSQL read-only mode: {error}"),
                });
            }

            let query_result = rshell_pg_execute(
                connection_id.clone(),
                session_id.clone(),
                query.to_string(),
                1000,
            );
            let reset_result = rshell_pg_execute(
                connection_id.clone(),
                session_id.clone(),
                "RESET default_transaction_read_only".into(),
                1,
            );

            if let Err(error) = reset_result {
                // Release only this leased session rather than tearing down the
                // whole shared pool (which would drop every unrelated UI tab on
                // the same server). A connection whose read-only default didn't
                // clear fails safe — subsequent leases stay read-only — so the
                // bounded action is strictly better than the pool-wide reset.
                let _ = super::postgres::schema::rshell_pg_release_session(
                    connection_id.clone(),
                    session_id.clone(),
                );
                return Err(FfiMcpError::Execution {
                    message: format!("failed to reset PostgreSQL read-only session: {error}"),
                });
            }
            let _ = super::postgres::schema::rshell_pg_release_session(connection_id, session_id);

            let pg_res = query_result.map_err(|e| FfiMcpError::Execution {
                message: e.to_string(),
            })?;

            let columns: Vec<serde_json::Value> = pg_res
                .columns
                .iter()
                .map(|c| {
                    serde_json::json!({
                        "name": c.name,
                        "type_oid": c.type_oid,
                        "type_name": c.type_name
                    })
                })
                .collect();

            let rows: Vec<serde_json::Value> = pg_res
                .rows
                .iter()
                .map(|r| {
                    serde_json::json!({
                        "cells": r.cells
                    })
                })
                .collect();

            let json_res = serde_json::json!({
                "columns": columns,
                "rows": rows,
                "rows_affected": pg_res.rows_affected,
                "cursor_id": pg_res.cursor_id
            });

            let json_str =
                serde_json::to_string(&json_res).map_err(|e| FfiMcpError::Serialization {
                    message: e.to_string(),
                })?;

            Ok(json_str)
        }
        _ => Err(FfiMcpError::UnknownTool { name: tool }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // The MCP `write_file` command is executed by a remote POSIX shell. These
    // tests run it through a local `sh` against a temp directory and assert on
    // real side effects, so they prove the actual shell-parsing behaviour
    // rather than coupling to `shell_escape`'s quoting internals.
    fn run_in_shell(cmd: &str) {
        let status = std::process::Command::new("sh")
            .arg("-c")
            .arg(cmd)
            .status()
            .expect("failed to spawn sh");
        assert!(status.success(), "shell command failed: {cmd}");
    }

    #[test]
    fn write_file_command_writes_exact_content() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("note.txt");
        let content = "hello world\nline two\n";
        run_in_shell(&build_write_file_command(target.to_str().unwrap(), content));
        assert_eq!(std::fs::read_to_string(&target).unwrap(), content);
    }

    #[test]
    fn write_file_command_neutralizes_heredoc_sentinel_injection() {
        // The old heredoc executed everything after a line equal to the
        // sentinel as shell commands. The payload here would `touch` a canary
        // file if it escaped the content token.
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("note.txt");
        let canary = dir.path().join("pwned");
        let content = format!("ok\nEOF_AGENT_SSH_MCP\ntouch {}\n", canary.display());
        run_in_shell(&build_write_file_command(
            target.to_str().unwrap(),
            &content,
        ));
        assert!(
            !canary.exists(),
            "injected command executed — heredoc sentinel still breaks out"
        );
        assert_eq!(std::fs::read_to_string(&target).unwrap(), content);
    }

    #[test]
    fn write_file_command_neutralizes_quote_and_metacharacter_injection() {
        let dir = tempfile::tempdir().unwrap();
        let canary = dir.path().join("pwned");
        let target = dir.path().join("weird");
        let content = format!(
            "a'b; touch {}; echo $(touch {})",
            canary.display(),
            canary.display()
        );
        run_in_shell(&build_write_file_command(
            target.to_str().unwrap(),
            &content,
        ));
        assert!(
            !canary.exists(),
            "metacharacter injection in content executed"
        );
        assert_eq!(std::fs::read_to_string(&target).unwrap(), content);
    }

    #[test]
    fn write_file_command_neutralizes_injection_via_path() {
        let dir = tempfile::tempdir().unwrap();
        let canary = dir.path().join("pwned");
        // A path containing shell metacharacters must not execute anything.
        let target = dir.path().join("x'; touch");
        run_in_shell(&build_write_file_command(target.to_str().unwrap(), "data"));
        assert!(!canary.exists());
        assert_eq!(std::fs::read_to_string(&target).unwrap(), "data");
    }

    #[test]
    fn read_file_command_reads_exact_content() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("note.txt");
        std::fs::write(&target, "hello\nworld\n").unwrap();
        let output = std::process::Command::new("sh")
            .arg("-c")
            .arg(build_read_file_command(target.to_str().unwrap()))
            .output()
            .expect("failed to spawn sh");
        assert!(output.status.success());
        assert_eq!(String::from_utf8_lossy(&output.stdout), "hello\nworld\n");
    }

    #[test]
    fn read_file_command_neutralizes_injection_via_path() {
        let dir = tempfile::tempdir().unwrap();
        let canary = dir.path().join("pwned");
        // A path with quotes and metacharacters must not execute anything —
        // `cat` just fails to find the literal filename.
        let target = dir
            .path()
            .join(format!("x'; touch {}; '", canary.display()));
        let _ = std::process::Command::new("sh")
            .arg("-c")
            .arg(build_read_file_command(target.to_str().unwrap()))
            .output()
            .expect("failed to spawn sh");
        assert!(!canary.exists(), "metacharacter injection in path executed");
    }

    #[test]
    fn read_only_validator_accepts_plain_reads() {
        for query in [
            "SELECT * FROM users",
            "  select 1  ",
            "SELECT * FROM users;",
            "WITH t AS (SELECT 1) SELECT * FROM t",
            "SHOW server_version",
            "EXPLAIN SELECT * FROM users",
            "TABLE users",
            "VALUES (1), (2)",
            "SELECT ';' AS not_a_separator",
            "SELECT $$ ; DROP $$ AS dollar_literal",
            "SELECT 1 -- ; DROP TABLE users\n",
        ] {
            assert!(
                validate_read_only_query(query).is_ok(),
                "expected accept: {query:?} -> {:?}",
                validate_read_only_query(query)
            );
        }
    }

    #[test]
    fn read_only_validator_rejects_write_and_transaction_escapes() {
        for query in [
            // The core bypass: overriding the read-only default in one request.
            "BEGIN READ WRITE; DELETE FROM users",
            "BEGIN READ WRITE; DROP TABLE customers; COMMIT",
            "SET TRANSACTION READ WRITE; UPDATE t SET x = 1",
            "START TRANSACTION READ WRITE; INSERT INTO t VALUES (1)",
            // Multiple statements smuggled after a read.
            "SELECT 1; DROP TABLE users",
            "SELECT 1;DELETE FROM t",
            // Plain writes / DDL / privileged ops.
            "DELETE FROM users",
            "UPDATE users SET admin = true",
            "INSERT INTO t VALUES (1)",
            "DROP TABLE users",
            "TRUNCATE users",
            "GRANT ALL ON t TO public",
            "CALL do_something()",
            "DO $$ BEGIN DELETE FROM t; END $$",
            "SET default_transaction_read_only = off",
            "RESET default_transaction_read_only",
            "COPY t FROM '/etc/passwd'",
            // EXPLAIN ANALYZE actually runs the statement.
            "EXPLAIN ANALYZE DELETE FROM users",
            "explain  analyze select 1",
            "",
            "   ",
        ] {
            assert!(
                validate_read_only_query(query).is_err(),
                "expected reject: {query:?}"
            );
        }
    }

    #[test]
    fn mcp_execute_unknown_tool_returns_error() {
        rshell_init();
        match rshell_mcp_execute(
            "ssh-missing".into(),
            "invalid_tool_name".into(),
            "{}".into(),
        ) {
            Err(FfiMcpError::UnknownTool { name }) => {
                assert_eq!(name, "invalid_tool_name");
            }
            other => panic!("expected UnknownTool, got {other:?}"),
        }
    }

    #[test]
    fn mcp_execute_missing_connection_returns_error() {
        rshell_init();
        match rshell_mcp_execute(
            "ssh-missing".into(),
            "run_command".into(),
            "{\"command\": \"whoami\"}".into(),
        ) {
            Err(FfiMcpError::Execution { message }) => {
                assert!(message.contains("Connection not found"));
            }
            other => panic!("expected ConnectionNotFound or Execution error, got {other:?}"),
        }
    }
}
