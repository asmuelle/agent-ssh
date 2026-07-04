use std::sync::Arc;
use std::sync::OnceLock;

use ssh_commander_core::connection_manager::ConnectionManager;
use tokio::runtime::Runtime;

static BRIDGE: OnceLock<MacOsBridge> = OnceLock::new();

/// Worker-thread count for the shared Tokio runtime. The FFI workload is
/// overwhelmingly synchronous request/response (`block_on` per call), with a
/// handful of long-lived background tasks (event listener, per-PTY output
/// forwarders). A small fixed pool covers that concurrency while keeping the
/// fixed thread/memory cost bounded on memory-constrained iPad hardware — and
/// it shrinks the OS-thread-spawn surface that could make runtime creation
/// fail at launch.
const RUNTIME_WORKER_THREADS: usize = 2;

pub struct MacOsBridge {
    pub runtime: Runtime,
    pub connection_manager: Arc<ConnectionManager>,
}

impl MacOsBridge {
    /// Returns the global bridge, or panics if it hasn't been (successfully)
    /// initialized. Prefer [`MacOsBridge::init`] at the FFI entry point, which
    /// returns a `bool` the Swift side already gates on; this accessor exists
    /// for the many `rshell_*` functions that run only after a successful init.
    pub fn global() -> &'static Self {
        BRIDGE
            .get()
            .expect("MacOsBridge::global() called before a successful rshell_init()")
    }

    /// Initialize the global bridge on first use. Returns `true` once a bridge
    /// exists (either just created or already present), `false` if the Tokio
    /// runtime could not be built.
    ///
    /// Building the runtime can fail under OS thread/memory pressure (e.g. an
    /// iPad after many background/foreground cycles). Returning `false` here —
    /// rather than `expect`-ing — keeps that failure from unwinding across the
    /// FFI boundary into a Swift trap; the Swift `initialize()` path already
    /// treats a `false` return as a recoverable "bridge unavailable" state.
    pub fn init() -> bool {
        if BRIDGE.get().is_some() {
            return true;
        }

        let runtime = match Self::build_runtime() {
            Ok(runtime) => runtime,
            Err(e) => {
                tracing::error!("failed to create Tokio runtime: {e}");
                return false;
            }
        };

        let bridge = MacOsBridge {
            runtime,
            connection_manager: Arc::new(ConnectionManager::new()),
        };

        // `set` only fails if another thread won the init race; in that case a
        // bridge already exists, which is exactly the success we report.
        let _ = BRIDGE.set(bridge);
        BRIDGE.get().is_some()
    }

    fn build_runtime() -> std::io::Result<Runtime> {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(RUNTIME_WORKER_THREADS)
            .enable_all()
            .build()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn init_succeeds_and_is_idempotent() {
        // A successful build installs the bridge; a second call is a no-op
        // that still reports success rather than rebuilding the runtime.
        assert!(MacOsBridge::init());
        assert!(MacOsBridge::init());
        // `global()` must not panic once init has succeeded.
        let _ = MacOsBridge::global();
    }
}
