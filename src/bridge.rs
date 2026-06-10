use std::sync::Arc;
use std::sync::OnceLock;

use ssh_commander_core::connection_manager::ConnectionManager;
use tokio::runtime::Runtime;

static BRIDGE: OnceLock<MacOsBridge> = OnceLock::new();

pub struct MacOsBridge {
    pub runtime: Runtime,
    pub connection_manager: Arc<ConnectionManager>,
}

impl MacOsBridge {
    /// Returns the global bridge, initializing it on first use.
    ///
    /// Lazy initialization (rather than `expect`) keeps a Rust panic from
    /// unwinding across the FFI boundary if Swift calls any `rshell_*`
    /// function before `rshell_init()`.
    pub fn global() -> &'static Self {
        Self::init()
    }

    pub fn init() -> &'static Self {
        BRIDGE.get_or_init(|| {
            let runtime = Runtime::new().expect("failed to create Tokio runtime");
            let connection_manager = Arc::new(ConnectionManager::new());
            MacOsBridge {
                runtime,
                connection_manager,
            }
        })
    }
}
