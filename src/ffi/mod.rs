use std::sync::Arc;

pub(crate) use crate::bridge::MacOsBridge;

// ---------------------------------------------------------------------------
// Protocol types — shared between Rust and Swift via uniffi-generated bindings.
// These are the wire-format records for every FFI operation.
// ---------------------------------------------------------------------------

/// Parameters for creating an SSH connection.
/// Maps to a uniffi `dictionary` in Swift; generated bindings produce
/// a native Swift struct that callers construct inline.
#[derive(uniffi::Record)]
pub struct FfiConnectConfig {
    pub host: String,
    pub port: u16,
    pub username: String,
    /// Password for password-based auth. May be `None` when using key-based auth.
    pub password: Option<String>,
    /// Filesystem path to a private key for key-based auth. May be `None`
    /// when using password auth.
    pub key_path: Option<String>,
    /// Optional passphrase to decrypt the private key.
    pub passphrase: Option<String>,
    /// Use identities from SSH_AUTH_SOCK instead of a password or key file.
    pub use_agent: bool,
    /// Optional public-key-base64 substring used to select one agent identity.
    pub agent_identity_hint: Option<String>,
    /// Optional unique suffix that lets the same `(user, host, port)` triple
    /// be opened more than once (e.g., one terminal tab per session). When
    /// `Some("abc")`, the connection is keyed as `"user@host:port#abc"` in
    /// `pty_sessions`. When `None`, the bare key is used (suitable for the
    /// simple "single connection per host" case).
    pub session_id: Option<String>,
}

/// Universal result struct for FFI operations.
///
/// `success` indicates whether the operation completed. When `success` is
/// `false`, `error` contains a human-readable description of what went wrong.
/// When `success` is `true`, `value` may carry extra payload (e.g. a PTY
/// generation counter as a JSON string).
#[derive(uniffi::Record)]
pub struct FfiResult {
    pub success: bool,
    pub error: Option<String>,
    /// JSON-encoded extra payload (e.g. `{"generation": 3}` for PTY start)
    pub value: Option<String>,
}

/// An event emitted by the Rust core and delivered to the Swift layer via
/// the registered `FfiEventCallback`.
///
/// `ty` identifies the event kind: `"pty_output"`, `"connection_status"`,
/// `"transfer_progress"`, or `"action_complete"`.
///
/// `connection_id` is the connection this event relates to.
///
/// `payload` is a JSON-encoded string with the event-specific data.
#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiEvent {
    pub ty: String,
    pub connection_id: String,
    pub payload: String,
}

// ---------------------------------------------------------------------------
// Callback interface — the Swift side implements this to receive events.
// ---------------------------------------------------------------------------

/// Callback trait that the Swift layer implements to receive asynchronous
/// events from the Rust core. Registered once via `rshell_set_event_callback`.
///
/// `FfiEventCallback` is `Send + Sync` so it can be invoked from any Tokio
/// task spawned by the bridge.
#[uniffi::export(callback_interface)]
pub trait FfiEventCallback: Send + Sync {
    fn on_event(&self, event: FfiEvent);
}

// ---------------------------------------------------------------------------
// Event bus wiring — forwards ssh-commander-core events to the registered Swift
// callback. Runs inside the bridge's Tokio runtime, so the callback must be
// Send + Sync.
// ---------------------------------------------------------------------------

/// The most recently registered Swift callback. PTY output bypasses the
/// broadcast event bus and is delivered through this handle directly, so
/// terminal bytes are never subject to the bus's lossy overflow policy.
static EVENT_CALLBACK: std::sync::RwLock<Option<Arc<dyn FfiEventCallback>>> =
    std::sync::RwLock::new(None);

/// Store `callback` as the current event sink and return the shared handle.
fn register_event_callback(callback: Box<dyn FfiEventCallback>) -> Arc<dyn FfiEventCallback> {
    let callback: Arc<dyn FfiEventCallback> = Arc::from(callback);
    let mut slot = EVENT_CALLBACK
        .write()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    *slot = Some(Arc::clone(&callback));
    callback
}

/// The registered Swift callback, if any. Used by the PTY output forwarder.
pub(crate) fn event_callback() -> Option<Arc<dyn FfiEventCallback>> {
    EVENT_CALLBACK
        .read()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .clone()
}

/// Wire event for one PTY output chunk: `{"generation": N, "bytes": [...]}`
/// so the consumer can drop stale frames whose generation no longer matches
/// the active session.
pub(crate) fn pty_output_event(connection_id: &str, generation: u64, data: &[u8]) -> FfiEvent {
    FfiEvent {
        ty: "pty_output".into(),
        connection_id: connection_id.to_string(),
        payload: serde_json::json!({
            "generation": generation,
            "bytes": data,
        })
        .to_string(),
    }
}

/// Sentinel `connection_id` for events that aren't about one connection.
pub(crate) const BUS_CONNECTION_ID: &str = "bus";

/// Wire event telling the Swift side the monitoring bus dropped `dropped`
/// events. PTY bytes are not affected (they don't travel on the bus); status
/// and progress events may be stale until the next update.
pub(crate) fn event_bus_lagged_event(dropped: u64) -> FfiEvent {
    FfiEvent {
        ty: "event_bus_lagged".into(),
        connection_id: BUS_CONNECTION_ID.into(),
        payload: serde_json::json!({ "droppedEvents": dropped }).to_string(),
    }
}

/// Spawn a background Tokio task on the bridge runtime that drains the
/// core event bus and forwards monitoring events to the registered callback.
/// The task lives until the bridge runtime is dropped (process exit).
///
/// The bus is a bounded `tokio::sync::broadcast` channel: a slow consumer
/// gets `Lagged` and loses the oldest events. That is acceptable for status
/// and progress events, which are superseded by their successors, but not
/// for terminal bytes. PTY output therefore never travels on the bus — the
/// per-PTY forwarder in `connection.rs` calls the callback directly, back-
/// pressured by the SSH reader's channel — and is skipped here.
fn start_event_listener(callback: Arc<dyn FfiEventCallback>) {
    let bridge = MacOsBridge::global();
    let mut rx = ssh_commander_core::event_bus::subscribe();
    bridge.runtime.spawn(async move {
        use tokio::sync::broadcast::error::RecvError;
        loop {
            match rx.recv().await {
                Ok(core_event) => {
                    use ssh_commander_core::event_bus::{ConnectionStatus, CoreEvent};
                    let (ty, connection_id, payload) = match core_event {
                        // Delivered directly by the PTY forwarder; see above.
                        CoreEvent::PtyOutput { .. } => continue,
                        CoreEvent::ConnectionStatus {
                            connection_id,
                            status,
                        } => {
                            let status_str = match status {
                                ConnectionStatus::Connected => "connected",
                                ConnectionStatus::Disconnected => "disconnected",
                                ConnectionStatus::Error { .. } => "error",
                            };
                            (
                                "connection_status".into(),
                                connection_id,
                                format!("{{\"status\":\"{}\"}}", status_str),
                            )
                        }
                        CoreEvent::TransferProgress {
                            connection_id,
                            path,
                            bytes_transferred,
                            total_bytes,
                        } => (
                            "transfer_progress".into(),
                            connection_id,
                            serde_json::json!({
                                "path": path,
                                "bytesTransferred": bytes_transferred,
                                "totalBytes": total_bytes,
                            })
                            .to_string(),
                        ),
                        CoreEvent::TcpdumpLine {
                            capture_id,
                            line,
                            is_stderr,
                        } => (
                            "tcpdump_line".into(),
                            // Tcpdump captures aren't bound to a per-
                            // connection routing key on the Swift side;
                            // they're keyed by `capture_id` inside the
                            // payload. Use a stable sentinel for the
                            // connection_id field so the listener can
                            // dispatch based on `ty` alone.
                            "tcpdump".into(),
                            serde_json::json!({
                                "captureId": capture_id,
                                "line": line,
                                "isStderr": is_stderr,
                            })
                            .to_string(),
                        ),
                    };
                    let ffi_event = FfiEvent {
                        ty,
                        connection_id,
                        payload,
                    };
                    callback.on_event(ffi_event);
                }
                Err(RecvError::Lagged(n)) => {
                    tracing::warn!("macOS bridge event bus lagged by {} events", n);
                    callback.on_event(event_bus_lagged_event(n));
                }
                Err(RecvError::Closed) => {
                    tracing::info!("macOS bridge event bus closed, listener exiting");
                    break;
                }
            }
        }
    });
}

// ---------------------------------------------------------------------------
// FFI-exported functions — the native bridge contract.
// ---------------------------------------------------------------------------

/// Initialise the macOS bridge. Must be called once before any other
/// `rshell_*` function. Creates the Tokio runtime and connection manager.
/// Safe to call multiple times — subsequent calls are no-ops.
///
/// Returns `false` if the Tokio runtime could not be created (e.g. under OS
/// thread/memory pressure). The Swift `initialize()` path treats a `false`
/// return as a recoverable "bridge unavailable" state rather than crashing.
#[uniffi::export]
pub fn rshell_init() -> bool {
    MacOsBridge::init()
}

/// Register an event callback. The callback receives `FfiEvent` messages
/// for PTY output, connection status changes, and transfer progress.
/// The callback is moved into a background Tokio task and forwarded to
/// the Swift layer. Must be called at least once before any event-producing
/// operations (PTY start, file transfer, etc.).
#[uniffi::export]
pub fn rshell_set_event_callback(callback: Box<dyn FfiEventCallback>) {
    let callback = register_event_callback(callback);
    start_event_listener(callback);
}

/// Typed connect-time failures so the Swift side can pattern-match instead
/// of substring-checking the error string. Variants are classified from
/// the underlying `anyhow::Error` produced by `ssh-commander-core` based on
/// well-known message phrases — uniffi 0.28 doesn't propagate Rust types
/// through `anyhow`, so this is the natural place for the classification.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum ConnectError {
    /// Either no auth method was provided, or the request was missing a
    /// required field. The user can't recover by retrying — they need to
    /// fix the profile.
    #[error("invalid configuration: {detail}")]
    ConfigInvalid { detail: String },

    /// SSH key is encrypted and either no passphrase was supplied or the
    /// supplied one was wrong. The Swift side typically prompts and
    /// retries.
    #[error("SSH key needs a passphrase: {detail}")]
    PassphraseRequired { detail: String },

    /// Server rejected the credential — wrong password, key not in
    /// `authorized_keys`, etc. Distinct from `PassphraseRequired` because
    /// the recovery flow differs (re-prompt password vs unlock key).
    #[error("authentication failed: {detail}")]
    AuthFailed { detail: String },

    /// The stored host fingerprint doesn't match the offered one. Caller
    /// must surface the mismatch so the user can decide whether to
    /// re-trust the host (and removes the old TOFU entry).
    #[error("host key verification failed: {detail}")]
    HostKeyMismatch { detail: String },

    /// TCP-level failure: timeout, refused, reset, allow-list block.
    #[error("network error: {detail}")]
    Network { detail: String },

    /// Anything else — unknown error string from ssh-commander-core. Swift falls
    /// through to a generic alert.
    #[error("{detail}")]
    Other { detail: String },
}

/// Classify an `anyhow::Error` from ssh-commander-core into a typed `ConnectError`.
/// The match order matters: passphrase / encrypted-key failures must be
/// caught before the generic "authentication failed" check, since a wrong
/// key passphrase is user-correctable (re-prompt) whereas a remote auth
/// rejection means the credential itself is wrong.
pub(crate) fn classify_connect_error(e: &anyhow::Error) -> ConnectError {
    let msg = e.to_string();
    let lower = msg.to_lowercase();

    if lower.contains("passphrase") || lower.contains("encrypted") {
        ConnectError::PassphraseRequired { detail: msg }
    } else if lower.contains("authentication failed") {
        ConnectError::AuthFailed { detail: msg }
    } else if lower.contains("host key")
        || lower.contains("fingerprint")
        || lower.contains("verification failed")
    {
        ConnectError::HostKeyMismatch { detail: msg }
    } else if lower.contains("timed out")
        || lower.contains("reset")
        || lower.contains("refused")
        || lower.contains("connection")
    {
        ConnectError::Network { detail: msg }
    } else {
        ConnectError::Other { detail: msg }
    }
}

/// Strip redundant segments from `anyhow` error chains. When an
/// outer context and inner cause produce identical text (common
/// with SFTP "Permission denied" → "Permission denied" chains),
/// return a single clean message. Otherwise collapse adjacent
/// duplicate segments joined by `": "`.
pub(crate) fn sanitize_error(e: anyhow::Error) -> String {
    let full = e.to_string();
    let root = e.root_cause().to_string();
    if full == format!("{}: {}", root, root) {
        return root;
    }
    // Collapse adjacent identical segments.
    let parts: Vec<&str> = full.split(": ").collect();
    let mut deduped: Vec<&str> = Vec::new();
    for part in parts {
        if deduped.last() == Some(&part) {
            continue;
        }
        deduped.push(part);
    }
    deduped.join(": ")
}

/// Ceiling for the SSH connection handshake. A host behind a firewall that
/// silently drops packets (no TCP RST) would otherwise hang the calling native
/// thread forever; with the bounded runtime worker pool that can eventually
/// starve unrelated FFI work.
pub(crate) const CONNECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);

/// Ceiling for a one-shot `execute_command` round-trip. Generous enough for the
/// slow-but-legitimate maintenance commands the app runs, while still bounding a
/// wedged connection so repeated monitor polls can't pile up blocked threads.
/// Interactive shells use the PTY path, not this, so long-lived sessions are
/// unaffected.
pub(crate) const COMMAND_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(120);

pub(crate) fn command_failure_detail(
    output: &ssh_commander_core::ssh::CommandOutput,
    fallback: &str,
) -> String {
    let detail = output.combined().trim().to_string();
    if detail.is_empty() {
        fallback.to_string()
    } else {
        detail
    }
}

/// Wall-clock time in milliseconds since the Unix epoch, saturating at
/// `u64::MAX`. Shared by the doctor and security-patch collectors to stamp
/// evidence and audits.
pub(crate) fn doctor_now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_millis().min(u128::from(u64::MAX)) as u64)
        .unwrap_or(0)
}

mod connection;

mod sftp;
pub(crate) use sftp::*;

mod host_keys_ffi;
mod monitor_ffi;
pub use host_keys_ffi::*;

mod postgres;
pub(crate) use postgres::*;

mod keychain;

mod port_forward_ffi;

mod doctor_ffi;

mod security_patch_ffi;

mod tools;

mod mcp;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn init_succeeds() {
        assert!(rshell_init());
    }
}

#[cfg(test)]
mod event_tests {
    use super::*;
    use std::sync::Mutex;

    struct Recorder(Mutex<Vec<FfiEvent>>);
    impl FfiEventCallback for Recorder {
        fn on_event(&self, event: FfiEvent) {
            self.0.lock().unwrap().push(event);
        }
    }

    #[test]
    fn pty_output_event_carries_generation_and_bytes() {
        let event = pty_output_event("conn-1", 7, &[0x1b, b'[', b'm']);
        assert_eq!(event.ty, "pty_output");
        assert_eq!(event.connection_id, "conn-1");
        let payload: serde_json::Value = serde_json::from_str(&event.payload).unwrap();
        assert_eq!(payload["generation"], 7);
        assert_eq!(payload["bytes"], serde_json::json!([27, 91, 109]));
    }

    #[test]
    fn lag_event_reports_dropped_count_on_the_bus_sentinel() {
        let event = event_bus_lagged_event(42);
        assert_eq!(event.ty, "event_bus_lagged");
        assert_eq!(event.connection_id, BUS_CONNECTION_ID);
        let payload: serde_json::Value = serde_json::from_str(&event.payload).unwrap();
        assert_eq!(payload["droppedEvents"], 42);
    }

    #[test]
    fn forwarder_handle_is_the_registered_callback_and_preserves_order() {
        let registered = register_event_callback(Box::new(Recorder(Mutex::new(Vec::new()))));
        let sink = event_callback().expect("callback registered");
        assert!(
            Arc::ptr_eq(&registered, &sink),
            "forwarder must use the callback Swift registered"
        );

        let chunks: Vec<Vec<u8>> = (0..500u32).map(|i| i.to_le_bytes().to_vec()).collect();
        for chunk in &chunks {
            sink.on_event(pty_output_event("conn", 1, chunk));
        }

        // Every frame arrives, in order, with no lag/drop policy in between.
        let recorder = Recorder(Mutex::new(Vec::new()));
        for chunk in &chunks {
            recorder.on_event(pty_output_event("conn", 1, chunk));
        }
        let seen = recorder.0.lock().unwrap();
        assert_eq!(seen.len(), chunks.len());
        for (event, chunk) in seen.iter().zip(&chunks) {
            let payload: serde_json::Value = serde_json::from_str(&event.payload).unwrap();
            let bytes: Vec<u8> = serde_json::from_value(payload["bytes"].clone()).unwrap();
            assert_eq!(&bytes, chunk);
        }
    }
}
