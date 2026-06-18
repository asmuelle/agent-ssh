use super::*;

// ---------------------------------------------------------------------------
// Postgres FFI — exposes the database explorer surface (Sprint 1: connect +
// introspect). Query execution and cursor paging land in later sprints.
// ---------------------------------------------------------------------------

#[derive(uniffi::Enum, Debug)]
pub enum FfiPgTlsMode {
    Disable,
    Prefer,
    Require,
    VerifyFull,
}

impl From<FfiPgTlsMode> for ssh_commander_core::PgTlsMode {
    fn from(m: FfiPgTlsMode) -> Self {
        match m {
            FfiPgTlsMode::Disable => Self::Disable,
            FfiPgTlsMode::Prefer => Self::Prefer,
            FfiPgTlsMode::Require => Self::Require,
            FfiPgTlsMode::VerifyFull => Self::VerifyFull,
        }
    }
}

/// How the Swift layer authenticates to Postgres. The two variants map 1:1
/// to `PgAuthMethod`. `Keychain` defers password lookup to the keychain at
/// connect time so the secret never crosses the FFI boundary.
#[derive(uniffi::Enum, Debug)]
pub enum FfiPgAuthMethod {
    Password { password: String },
    Keychain { account: String },
}

impl From<FfiPgAuthMethod> for ssh_commander_core::PgAuthMethod {
    fn from(a: FfiPgAuthMethod) -> Self {
        match a {
            FfiPgAuthMethod::Password { password } => Self::Password { password },
            FfiPgAuthMethod::Keychain { account } => Self::Keychain { account },
        }
    }
}

/// Optional SSH tunnel descriptor. Carries the `connection_id` of an
/// already-open SSH connection (managed by `ConnectionManager`) plus the
/// remote endpoint to forward to. Wired up in Sprint 2; Sprint 1 returns
/// `TunnelUnsupported` if this is supplied.
#[derive(uniffi::Record, Debug)]
pub struct FfiPgTunnel {
    pub ssh_connection_id: String,
    pub remote_host: String,
    pub remote_port: u16,
}

#[derive(uniffi::Record, Debug)]
pub struct FfiPgConfig {
    pub host: String,
    pub port: u16,
    pub database: String,
    pub user: String,
    pub auth: FfiPgAuthMethod,
    pub tls: FfiPgTlsMode,
    pub application_name: Option<String>,
    pub tunnel: Option<FfiPgTunnel>,
    /// Connection timeout in seconds. `None` falls back to the driver default.
    pub connect_timeout_secs: Option<u64>,
    /// Per-profile connection-pool tuning. All `None` to inherit
    /// the built-in defaults (5 max, 5 min idle timeout, 1 min
    /// idle); the macOS edit form surfaces these in an Advanced
    /// section.
    pub max_pool_size: Option<u32>,
    pub idle_timeout_secs: Option<u64>,
    pub min_idle_connections: Option<u32>,
    /// Optional app-owned profile/session identity. When supplied, it
    /// scopes the manager connection id so saved profiles sharing the
    /// same endpoint do not collide.
    pub profile_id: Option<String>,
}

impl From<FfiPgConfig> for ssh_commander_core::PgConfig {
    fn from(c: FfiPgConfig) -> Self {
        Self {
            host: c.host,
            port: c.port,
            database: c.database,
            user: c.user,
            auth: c.auth.into(),
            tls: c.tls.into(),
            application_name: c.application_name,
            connect_timeout_secs: c.connect_timeout_secs,
            max_pool_size: c.max_pool_size,
            idle_timeout_secs: c.idle_timeout_secs,
            min_idle_connections: c.min_idle_connections,
        }
    }
}

/// Typed Postgres errors surfaced to Swift. Matches the `PgError`
/// classifications the core layer produces; pattern-matchable from Swift
/// without substring-checking error strings.
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum FfiPgError {
    #[error("postgres connect failed: {detail}")]
    Connect { detail: String },
    #[error("postgres auth failed: {detail}")]
    Auth { detail: String },
    #[error("postgres tls setup failed: {detail}")]
    Tls { detail: String },
    #[error("ssh tunnel error: {detail}")]
    Tunnel { detail: String },
    /// Tunnel was requested but the SSH connection it depends on isn't
    /// registered in the manager. Distinct from `Tunnel { _ }` so the
    /// UI can offer the right remediation: open the SSH connection
    /// first, then retry.
    #[error("ssh tunnel source missing: {detail}")]
    TunnelSourceMissing { detail: String },
    /// The cursor handle no longer references the connection's
    /// active result set — a subsequent `execute` superseded it.
    /// UI shows "result no longer available" and pins what was
    /// already fetched.
    #[error("cursor no longer available: {detail}")]
    CursorExpired { detail: String },
    /// The pool is at its `max_size` and all connections are leased
    /// to other sessions. UI can show "too many open queries — close
    /// a tab to continue".
    #[error("connection pool exhausted: {detail}")]
    PoolExhausted { detail: String },
    #[error("postgres not connected: {detail}")]
    NotConnected { detail: String },
    #[error("{detail}")]
    Other { detail: String },
}

impl From<ssh_commander_core::PgError> for FfiPgError {
    fn from(e: ssh_commander_core::PgError) -> Self {
        match e {
            ssh_commander_core::PgError::Connect(detail) => Self::Connect { detail },
            ssh_commander_core::PgError::Auth(detail) => Self::Auth { detail },
            ssh_commander_core::PgError::Tls(detail) => Self::Tls { detail },
            // Client-side validation failures added to PgError in core 0.2;
            // surface as a generic error (no dedicated FFI variant needed).
            ssh_commander_core::PgError::InvalidInput(detail) => Self::Other { detail },
            ssh_commander_core::PgError::Tunnel(detail) => Self::Tunnel { detail },
            ssh_commander_core::PgError::TunnelSourceMissing(detail) => {
                Self::TunnelSourceMissing { detail }
            }
            ssh_commander_core::PgError::CursorExpired(detail) => Self::CursorExpired { detail },
            ssh_commander_core::PgError::PoolExhausted(used, max) => Self::PoolExhausted {
                detail: format!("{used} of {max} connections leased"),
            },
            ssh_commander_core::PgError::Driver(driver_err) => Self::Other {
                detail: driver_err.to_string(),
            },
        }
    }
}

#[derive(uniffi::Record, Debug)]
pub struct FfiPgDatabase {
    pub name: String,
    pub owner: String,
    pub is_template: bool,
}

#[derive(uniffi::Record, Debug)]
pub struct FfiPgSchema {
    pub name: String,
    pub owner: String,
    pub is_system: bool,
}

#[derive(uniffi::Enum, Debug)]
pub enum FfiPgRelationKind {
    Table,
    View,
    MaterializedView,
    PartitionedTable,
    ForeignTable,
}

impl From<ssh_commander_core::RelationKind> for FfiPgRelationKind {
    fn from(k: ssh_commander_core::RelationKind) -> Self {
        match k {
            ssh_commander_core::RelationKind::Table => Self::Table,
            ssh_commander_core::RelationKind::View => Self::View,
            ssh_commander_core::RelationKind::MaterializedView => Self::MaterializedView,
            ssh_commander_core::RelationKind::PartitionedTable => Self::PartitionedTable,
            ssh_commander_core::RelationKind::ForeignTable => Self::ForeignTable,
        }
    }
}

#[derive(uniffi::Record, Debug)]
pub struct FfiPgRelation {
    pub schema: String,
    pub name: String,
    pub kind: FfiPgRelationKind,
    pub owner: String,
    /// Estimated rows from `pg_class.reltuples`. Negative when statistics
    /// have not been gathered.
    pub estimated_rows: f32,
}

/// Build a stable connection id for the macOS connection map. Mirrors the
/// SSH form `user@host:port` but namespaces with `pg:` so a Postgres and
/// SSH connection sharing host/user/port can coexist in the same map.
fn pg_connection_id(cfg: &ssh_commander_core::PgConfig, profile_id: Option<&str>) -> String {
    let base = format!("pg:{}@{}:{}/{}", cfg.user, cfg.host, cfg.port, cfg.database);
    match profile_id.filter(|id| !id.is_empty()) {
        Some(id) => format!("{base}#{id}"),
        None => base,
    }
}

/// Establish a Postgres connection. Returns the canonical connection id
/// (`"pg:user@host:port/db"`) on success.
#[uniffi::export]
pub fn rshell_pg_connect(config: FfiPgConfig) -> Result<String, FfiPgError> {
    let bridge = MacOsBridge::global();
    let profile_id = config.profile_id.clone();
    // ssh-commander-core 0.2: the SSH tunnel is no longer a PgConfig field —
    // the ConnectionManager owns the tunnel seam and takes it as a separate
    // argument. Extract it before consuming `config`.
    let tunnel = config
        .tunnel
        .as_ref()
        .map(|t| ssh_commander_core::SshTunnelRef {
            ssh_connection_id: t.ssh_connection_id.clone(),
            remote_host: t.remote_host.clone(),
            remote_port: t.remote_port,
        });
    let core_cfg: ssh_commander_core::PgConfig = config.into();
    let connection_id = pg_connection_id(&core_cfg, profile_id.as_deref());
    let conn_id = connection_id.clone();
    let cm = bridge.connection_manager.clone();

    bridge
        .runtime
        .block_on(async move { cm.create_postgres_connection(conn_id, core_cfg, tunnel).await })
        .map_err(|e| {
            // The manager wraps PgError in anyhow; downcast back so we
            // keep the typed classification through to Swift.
            match e.downcast::<ssh_commander_core::PgError>() {
                Ok(pg_err) => FfiPgError::from(pg_err),
                Err(other) => FfiPgError::Other {
                    detail: sanitize_error(other),
                },
            }
        })?;

    if let Some(tx) = ssh_commander_core::event_bus::event_sender() {
        let _ = tx.send(ssh_commander_core::event_bus::CoreEvent::ConnectionStatus {
            connection_id: connection_id.clone(),
            status: ssh_commander_core::event_bus::ConnectionStatus::Connected,
        });
    }
    Ok(connection_id)
}

#[uniffi::export]
pub fn rshell_pg_disconnect(connection_id: String) -> FfiResult {
    let bridge = MacOsBridge::global();
    let cm = bridge.connection_manager.clone();
    let conn_id_for_close = connection_id.clone();
    let result = bridge
        .runtime
        .block_on(async move { cm.close_postgres_connection(&conn_id_for_close).await });

    if let Some(tx) = ssh_commander_core::event_bus::event_sender() {
        let _ = tx.send(ssh_commander_core::event_bus::CoreEvent::ConnectionStatus {
            connection_id: connection_id.clone(),
            status: ssh_commander_core::event_bus::ConnectionStatus::Disconnected,
        });
    }

    match result {
        Ok(_) => FfiResult {
            success: true,
            error: None,
            value: None,
        },
        Err(e) => FfiResult {
            success: false,
            error: Some(sanitize_error(e)),
            value: None,
        },
    }
}

async fn with_pg_pool<F, Fut, T>(connection_id: &str, op: F) -> Result<T, FfiPgError>
where
    F: FnOnce(std::sync::Arc<ssh_commander_core::PgPool>) -> Fut,
    Fut: std::future::Future<Output = Result<T, ssh_commander_core::PgError>>,
{
    let bridge = MacOsBridge::global();
    let pool = bridge
        .connection_manager
        .get_postgres_pool(connection_id)
        .await
        .ok_or_else(|| FfiPgError::NotConnected {
            detail: format!("no postgres connection registered as {connection_id}"),
        })?;
    op(pool).await.map_err(FfiPgError::from)
}

#[uniffi::export]
pub fn rshell_pg_list_databases(connection_id: String) -> Result<Vec<FfiPgDatabase>, FfiPgError> {
    let bridge = MacOsBridge::global();
    bridge.runtime.block_on(async move {
        with_pg_pool(
            &connection_id,
            |pool| async move { pool.list_databases().await },
        )
        .await
        .map(|dbs| {
            dbs.into_iter()
                .map(|d| FfiPgDatabase {
                    name: d.name,
                    owner: d.owner,
                    is_template: d.is_template,
                })
                .collect()
        })
    })
}

#[uniffi::export]
pub fn rshell_pg_list_schemas(
    connection_id: String,
    database: Option<String>,
) -> Result<Vec<FfiPgSchema>, FfiPgError> {
    let bridge = MacOsBridge::global();
    bridge.runtime.block_on(async move {
        with_pg_pool(&connection_id, |pool| async move {
            pool.list_schemas_in(database.as_deref()).await
        })
        .await
        .map(|schemas| {
            schemas
                .into_iter()
                .map(|s| FfiPgSchema {
                    name: s.name,
                    owner: s.owner,
                    is_system: s.is_system,
                })
                .collect()
        })
    })
}

#[derive(uniffi::Record, Debug)]
pub struct FfiPgColumn {
    pub name: String,
    /// Postgres type OID. Stable across server versions; the UI uses
    /// it to classify the column for alignment / formatting (numeric
    /// columns right-align, booleans render as ✓/✗, timestamps get
    /// special tooltips).
    pub type_oid: u32,
    /// Human-readable type name (`int4`, `timestamptz`, `jsonb`, …).
    /// Surfaces in tooltips and acts as a fallback label for OIDs
    /// the affinity decoder doesn't classify.
    pub type_name: String,
}

/// Single row of a query result. `cells.len() == columns.len()`.
/// Each cell is the server's text representation of the value, or
/// `None` for SQL NULL.
#[derive(uniffi::Record, Debug)]
pub struct FfiPgRow {
    pub cells: Vec<Option<String>>,
}

#[derive(uniffi::Record, Debug)]
pub struct FfiPgExecutionResult {
    pub columns: Vec<FfiPgColumn>,
    pub rows: Vec<FfiPgRow>,
    /// `RowsAffected` from the last completed statement, when the
    /// server reports one.
    pub rows_affected: Option<u64>,
    /// Opaque handle to the server-side cursor. `Some(_)` when more
    /// rows remain — call `rshell_pg_fetch_page` with this id to
    /// stream more, then `rshell_pg_close_query` when done. `None`
    /// when the result is fully contained or the statement does
    /// not return rows.
    pub cursor_id: Option<String>,
}

impl From<ssh_commander_core::ExecutionOutcome> for FfiPgExecutionResult {
    fn from(r: ssh_commander_core::ExecutionOutcome) -> Self {
        Self {
            columns: r
                .columns
                .into_iter()
                .map(|c| FfiPgColumn {
                    name: c.name,
                    type_oid: c.type_oid,
                    type_name: c.type_name,
                })
                .collect(),
            rows: r.rows.into_iter().map(|cells| FfiPgRow { cells }).collect(),
            rows_affected: r.rows_affected,
            cursor_id: r.cursor_id,
        }
    }
}

#[derive(uniffi::Record, Debug)]
pub struct FfiPgPageResult {
    pub rows: Vec<FfiPgRow>,
    /// `true` when the page filled to the requested count (more may
    /// be available); `false` when the cursor exhausted on this fetch.
    pub has_more: bool,
}

impl From<ssh_commander_core::PageResult> for FfiPgPageResult {
    fn from(p: ssh_commander_core::PageResult) -> Self {
        Self {
            rows: p.rows.into_iter().map(|cells| FfiPgRow { cells }).collect(),
            has_more: p.has_more,
        }
    }
}

/// Run a SQL statement against the pool's connection assigned to
/// `session_id`, leasing one if the session is new. When more rows
/// remain server-side, the result carries a `cursor_id` for use with
/// `rshell_pg_fetch_page`. Sessions are isolated: opening a cursor
/// in session A doesn't affect session B's cursor.
#[uniffi::export]
pub fn rshell_pg_execute(
    connection_id: String,
    session_id: String,
    sql: String,
    page_size: u32,
) -> Result<FfiPgExecutionResult, FfiPgError> {
    let bridge = MacOsBridge::global();
    bridge.runtime.block_on(async move {
        with_pg_pool(&connection_id, |pool| async move {
            pool.execute(&session_id, &sql, page_size as usize).await
        })
        .await
        .map(FfiPgExecutionResult::from)
    })
}

/// Fetch the next page from a cursor opened by `rshell_pg_execute`
/// in the same session. Returns `CursorExpired` if the same session
/// opened a different cursor in between, or if the session was
/// released.
#[uniffi::export]
pub fn rshell_pg_fetch_page(
    connection_id: String,
    session_id: String,
    cursor_id: String,
    count: u32,
) -> Result<FfiPgPageResult, FfiPgError> {
    let bridge = MacOsBridge::global();
    bridge.runtime.block_on(async move {
        with_pg_pool(&connection_id, |pool| async move {
            pool.fetch_page(&session_id, &cursor_id, count as usize)
                .await
        })
        .await
        .map(FfiPgPageResult::from)
    })
}

/// Close a cursor on the given session. Idempotent — closing a stale
/// cursor is a silent success.
#[uniffi::export]
pub fn rshell_pg_close_query(
    connection_id: String,
    session_id: String,
    cursor_id: String,
) -> FfiResult {
    let bridge = MacOsBridge::global();
    let result: Result<(), FfiPgError> = bridge.runtime.block_on(async move {
        with_pg_pool(&connection_id, |pool| async move {
            pool.close_query(&session_id, &cursor_id).await
        })
        .await
    });
    match result {
        Ok(()) => FfiResult {
            success: true,
            error: None,
            value: None,
        },
        Err(e) => FfiResult {
            success: false,
            error: Some(e.to_string()),
            value: None,
        },
    }
}

/// Result of a single-cell UPDATE. Surfaced as a typed record so the
/// UI can branch on `rows_affected == 0` (row was modified or deleted
/// by a concurrent session) without parsing strings.
#[derive(uniffi::Record, Debug)]
pub struct FfiPgUpdateResult {
    pub rows_affected: u64,
}

impl From<ssh_commander_core::UpdateOutcome> for FfiPgUpdateResult {
    fn from(o: ssh_commander_core::UpdateOutcome) -> Self {
        Self {
            rows_affected: o.rows_affected,
        }
    }
}

/// Update a single cell. `new_value: None` means SET NULL; the type
/// of a non-null value is bound as text and cast server-side
/// (`SET col = $1::<column_type>`). Identifiers are quoted defensively
/// in the core layer — callers don't need to escape `schema` / `table`
/// / `column`.
// The eight parameters mirror the uniffi-exported Swift signature. Bundling
// them into an `FfiPgUpdateCellRequest` record would satisfy clippy and read
// better on the Swift side, but that reshapes the FFI surface and the generated
// bindings — tracked as a follow-up rather than folded into a lint pass.
#[allow(clippy::too_many_arguments)]
#[uniffi::export]
pub fn rshell_pg_update_cell(
    connection_id: String,
    session_id: String,
    schema: String,
    table: String,
    column: String,
    column_type: String,
    new_value: Option<String>,
    row_id: String,
) -> Result<FfiPgUpdateResult, FfiPgError> {
    let bridge = MacOsBridge::global();
    bridge.runtime.block_on(async move {
        with_pg_pool(&connection_id, |pool| async move {
            pool.update_cell(
                &session_id,
                &schema,
                &table,
                &column,
                &column_type,
                new_value.as_deref(),
                &row_id,
            )
            .await
        })
        .await
        .map(FfiPgUpdateResult::from)
    })
}

/// Open a Parquet writer at `path` with the given column names.
/// All columns serialize as Utf8 (matches the explorer's text-only
/// model). Returns an opaque writer id; pass it to subsequent
/// `rshell_pg_parquet_append` calls and finally `rshell_pg_parquet_close`.
#[uniffi::export]
pub fn rshell_pg_parquet_open(path: String, columns: Vec<String>) -> Result<u64, FfiPgError> {
    ssh_commander_pg_parquet::ParquetRegistry::global()
        .open(std::path::Path::new(&path), &columns)
        .map_err(|e| FfiPgError::Other {
            detail: format!("parquet open failed: {e}"),
        })
}

/// Append a batch of rows to an open Parquet writer. `rows` is a
/// list of `FfiPgRow`; each row's `cells` must match the column
/// list passed to `rshell_pg_parquet_open` in length.
#[uniffi::export]
pub fn rshell_pg_parquet_append(writer_id: u64, rows: Vec<FfiPgRow>) -> Result<(), FfiPgError> {
    let row_vecs: Vec<Vec<Option<String>>> = rows.into_iter().map(|r| r.cells).collect();
    ssh_commander_pg_parquet::ParquetRegistry::global()
        .append(writer_id, &row_vecs)
        .map_err(|e| FfiPgError::Other {
            detail: format!("parquet append failed: {e}"),
        })
}

/// Close a Parquet writer. Flushes the metadata footer to disk;
/// the file isn't readable as Parquet until this returns. Idempotent
/// against the same id (subsequent calls return UnknownWriter; the
/// caller surfaces that as a no-op since the file is already valid).
#[uniffi::export]
pub fn rshell_pg_parquet_close(writer_id: u64) -> Result<(), FfiPgError> {
    ssh_commander_pg_parquet::ParquetRegistry::global()
        .close(writer_id)
        .map_err(|e| FfiPgError::Other {
            detail: format!("parquet close failed: {e}"),
        })
}

mod schema;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pg_connection_id_is_profile_scoped_when_profile_id_is_supplied() {
        let cfg = ssh_commander_core::PgConfig {
            host: "db.example.com".into(),
            port: 5432,
            database: "app".into(),
            user: "u".into(),
            auth: ssh_commander_core::PgAuthMethod::Password {
                password: "pw".into(),
            },
            tls: ssh_commander_core::PgTlsMode::Disable,
            application_name: None,
            connect_timeout_secs: None,
            max_pool_size: None,
            idle_timeout_secs: None,
            min_idle_connections: None,
        };

        assert_eq!(
            pg_connection_id(&cfg, Some("profile-a")),
            "pg:u@db.example.com:5432/app#profile-a"
        );
        assert_eq!(pg_connection_id(&cfg, None), "pg:u@db.example.com:5432/app");
        assert_eq!(
            pg_connection_id(&cfg, Some("")),
            "pg:u@db.example.com:5432/app"
        );
    }

    #[test]
    fn pg_connect_with_tunnel_to_unknown_ssh_returns_source_missing() {
        // A tunnel ref pointing at an SSH connection that isn't open
        // surfaces a typed `TunnelSourceMissing` so the UI can prompt
        // the user to open SSH first instead of opaquely failing.
        rshell_init();
        let cfg = FfiPgConfig {
            host: "127.0.0.1".into(),
            port: 5432,
            database: "test".into(),
            user: "u".into(),
            auth: FfiPgAuthMethod::Password {
                password: String::new(),
            },
            tls: FfiPgTlsMode::Disable,
            application_name: None,
            tunnel: Some(FfiPgTunnel {
                ssh_connection_id: "ghost-ssh-id".into(),
                remote_host: "db".into(),
                remote_port: 5432,
            }),
            connect_timeout_secs: Some(1),
            max_pool_size: None,
            idle_timeout_secs: None,
            min_idle_connections: None,
            profile_id: None,
        };
        match rshell_pg_connect(cfg) {
            Err(FfiPgError::TunnelSourceMissing { detail }) => {
                assert!(detail.contains("ghost-ssh-id"));
            }
            Err(other) => panic!("expected TunnelSourceMissing, got {other:?}"),
            Ok(id) => panic!("expected error, got connection id {id}"),
        }
    }

    #[test]
    fn pg_list_schemas_on_unknown_id_returns_not_connected() {
        rshell_init();
        match rshell_pg_list_schemas("pg:nobody@nowhere:5432/none".into(), None) {
            Err(FfiPgError::NotConnected { detail }) => {
                assert!(detail.contains("postgres"));
            }
            other => panic!("expected NotConnected, got {other:?}"),
        }
    }

    #[test]
    fn pg_disconnect_unknown_id_is_ok() {
        rshell_init();
        let result = rshell_pg_disconnect("pg:nobody@nowhere:5432/none".into());
        assert!(result.success);
    }

    #[test]
    fn pg_execute_on_unknown_id_returns_not_connected() {
        rshell_init();
        match rshell_pg_execute(
            "pg:nobody@nowhere:5432/none".into(),
            "session-1".into(),
            "SELECT 1".into(),
            100,
        ) {
            Err(FfiPgError::NotConnected { detail }) => {
                assert!(detail.contains("postgres"));
            }
            other => panic!("expected NotConnected, got {other:?}"),
        }
    }

    #[test]
    fn pg_fetch_page_on_unknown_id_returns_not_connected() {
        rshell_init();
        match rshell_pg_fetch_page(
            "pg:nobody@nowhere:5432/none".into(),
            "session-1".into(),
            "c_does_not_matter".into(),
            100,
        ) {
            Err(FfiPgError::NotConnected { .. }) => {}
            other => panic!("expected NotConnected, got {other:?}"),
        }
    }

    #[test]
    fn pg_close_query_on_unknown_id_is_failure_result() {
        rshell_init();
        let result = rshell_pg_close_query(
            "pg:nobody@nowhere:5432/none".into(),
            "session-1".into(),
            "c_irrelevant".into(),
        );
        assert!(!result.success);
    }

    #[test]
    fn pg_update_cell_on_unknown_id_returns_not_connected() {
        rshell_init();
        match rshell_pg_update_cell(
            "pg:nobody@nowhere:5432/none".into(),
            "session-1".into(),
            "public".into(),
            "users".into(),
            "name".into(),
            "text".into(),
            Some("alice".into()),
            "(0,1)".into(),
        ) {
            Err(FfiPgError::NotConnected { .. }) => {}
            other => panic!("expected NotConnected, got {other:?}"),
        }
    }
}
