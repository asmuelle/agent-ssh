use super::*;

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
                            client.execute_command(command).await
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
                            client.execute_command(&command).await
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
                            client.execute_command(&command).await
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

            let pg_res =
                rshell_pg_execute(connection_id, "mcp-session".into(), query.to_string(), 1000)
                    .map_err(|e| FfiMcpError::Execution {
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
