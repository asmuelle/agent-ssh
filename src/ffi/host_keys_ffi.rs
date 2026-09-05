//! First-connection host-key surfacing.
//!
//! `ssh-commander-core` trusts an unknown host key on first use and only
//! raises an error on a later *mismatch*. OpenSSH instead shows the
//! fingerprint and asks before the first connect. Until the core grows a
//! pre-auth confirmation hook, this module closes the gap post-connect:
//! `rshell_connect` records every key it pinned for the first time, the UI
//! takes that record, shows the fingerprint, and on rejection disconnects
//! and forgets the entry so the next attempt starts from a clean slate.
//!
//! The store's on-disk format is one `host_id key_blob` pair per line, where
//! `host_id` is `host` for port 22 and `[host]:port` otherwise (matching
//! `HostKeyStore::make_key`). The store writes through on every change, so
//! reading the file here is consistent with its in-memory view.

use std::sync::Arc;

use base64::Engine;
use sha2::{Digest, Sha256};
use ssh_commander_core::connection_manager::ConnectionManager;

use super::*;
use crate::bridge::FirstConnection;

/// A host key that the most recent connect trusted for the first time.
#[derive(uniffi::Record, Debug, Clone)]
pub struct FfiFirstConnection {
    /// Host as passed to the connect call (after any Tailscale resolution).
    pub host: String,
    pub port: u16,
    /// OpenSSH-style `SHA256:<base64 without padding>` fingerprint.
    pub fingerprint: String,
}

/// Return and clear the first-connection record for `connection_id`, if the
/// connect that produced this id pinned a previously unknown host key.
/// Returns `None` when the host was already trusted.
#[uniffi::export]
pub fn rshell_take_first_connection(connection_id: String) -> Option<FfiFirstConnection> {
    let bridge = MacOsBridge::global();
    let record = bridge
        .first_connections
        .lock()
        .ok()
        .and_then(|mut map| map.remove(&connection_id))?;
    Some(FfiFirstConnection {
        host: record.host,
        port: record.port,
        fingerprint: record.fingerprint,
    })
}

/// Whether the host-key store already has an entry for `(host, port)`.
#[uniffi::export]
pub fn rshell_host_key_is_known(host: String, port: u16) -> bool {
    host_key_is_known(&MacOsBridge::global().connection_manager, &host, port)
}

pub(crate) fn host_key_is_known(cm: &Arc<ConnectionManager>, host: &str, port: u16) -> bool {
    stored_key_blob(cm, host, port).is_some()
}

pub(crate) fn record_first_connection(
    bridge: &MacOsBridge,
    connection_id: &str,
    host: &str,
    port: u16,
) {
    let Some(blob) = stored_key_blob(&bridge.connection_manager, host, port) else {
        // The connect succeeded but nothing was written: the core changed its
        // policy or the write failed silently. Nothing to show the user.
        tracing::warn!("no host-key entry after first connect to {host}:{port}");
        return;
    };
    let fingerprint = fingerprint_from_blob(&blob);
    if let Ok(mut map) = bridge.first_connections.lock() {
        map.insert(
            connection_id.to_string(),
            FirstConnection {
                host: host.to_string(),
                port,
                fingerprint,
            },
        );
    }
}

fn host_key_id(host: &str, port: u16) -> String {
    if port == 22 {
        host.to_string()
    } else {
        format!("[{host}]:{port}")
    }
}

fn stored_key_blob(cm: &Arc<ConnectionManager>, host: &str, port: u16) -> Option<String> {
    let path = cm.host_keys().path().to_path_buf();
    let content = std::fs::read_to_string(path).ok()?;
    lookup_key_blob(&content, &host_key_id(host, port))
}

fn lookup_key_blob(content: &str, host_id: &str) -> Option<String> {
    content
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .find_map(|line| {
            let mut parts = line.splitn(2, char::is_whitespace);
            match (parts.next(), parts.next()) {
                (Some(id), Some(blob)) if id == host_id => Some(blob.trim().to_string()),
                _ => None,
            }
        })
}

/// OpenSSH `ssh-keygen -l` style fingerprint of a base64 public-key blob.
fn fingerprint_from_blob(blob_b64: &str) -> String {
    match base64::engine::general_purpose::STANDARD.decode(blob_b64.trim()) {
        Ok(bytes) => {
            let digest = Sha256::digest(&bytes);
            format!(
                "SHA256:{}",
                base64::engine::general_purpose::STANDARD_NO_PAD.encode(digest)
            )
        }
        Err(_) => String::from("SHA256:<unparseable stored key>"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_key_id_matches_openssh_forms() {
        assert_eq!(host_key_id("example.org", 22), "example.org");
        assert_eq!(host_key_id("example.org", 2222), "[example.org]:2222");
    }

    #[test]
    fn lookup_skips_comments_and_matches_exact_id() {
        let content = "# header\n\nexample.org AAAAblob1\n[example.org]:2222 AAAAblob2\n";
        assert_eq!(
            lookup_key_blob(content, "example.org").as_deref(),
            Some("AAAAblob1")
        );
        assert_eq!(
            lookup_key_blob(content, "[example.org]:2222").as_deref(),
            Some("AAAAblob2")
        );
        assert_eq!(lookup_key_blob(content, "other.org"), None);
    }

    #[test]
    fn fingerprint_matches_ssh_keygen() {
        // `ssh-keygen -lf` of this well-known test key yields this digest.
        let blob = "AAAAC3NzaC1lZDI1NTE5AAAAIGvXzbQ4NlZyq8zCzH1G0TnFL4X8m1q5F8k7l2bO2kX9";
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(blob)
            .unwrap();
        let expected = format!(
            "SHA256:{}",
            base64::engine::general_purpose::STANDARD_NO_PAD.encode(Sha256::digest(&bytes))
        );
        assert_eq!(fingerprint_from_blob(blob), expected);
        assert!(!expected.ends_with('='));
    }

    #[test]
    fn fingerprint_of_garbage_is_marked_unparseable() {
        assert_eq!(
            fingerprint_from_blob("!!not base64!!"),
            "SHA256:<unparseable stored key>"
        );
    }
}
