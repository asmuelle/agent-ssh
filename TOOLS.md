# TOOLS.md — In-app feature catalog

What agent-ssh actually does, surface by surface. Pair with [`AGENTS.md`](AGENTS.md) (architecture) and [`README.md`](README.md) (build).

> Conventions: each section names the **user-visible feature**, the **Swift entry point** (where the UI lives), and the **FFI / Rust call** behind it (where the work happens). Rust exports live in `src/ffi/` as `rshell_*` and surface to Swift as camelCase in `bindings/agent_ssh.swift` (`rshell_doctor_collect` → `rshellDoctorCollect`). When a feature is iPadOS-only, mac-only, or both, it's marked.

---

## Connection management

### Profiles & sidebar

- **macOS**: `SidebarView.swift`, `ConnectionStoreManager.swift`, `ConnectionEditView.swift`
- **iPadOS**: `MobileConnectionStore.swift`, `MobileConnectionEditorView.swift`, `MobileContentView.swift`
- Persistent connection profiles grouped in folders. Sidebar rows carry live badges: connection state, Security Patch Monitor summary, latest Server Doctor verdict, and the host's SSH algorithm inventory (`SSHAlgorithmProbe.swift`).
- iPadOS adds auto-connect on launch (`MobileAutoConnect.swift`) and deep-link routing (`MobileDeepLinkRouting.swift`).

### SSH key vault

- `SSHKeyVault.swift`, `SSHKeyAccessCoordinator.swift` (macOS) / `MobileSSHKeyVault.swift`, `MobileSSHKeyImportStore.swift`, `MobileSSHKeyBootstrapInstaller.swift` (iPadOS)
- Generated and imported private keys live in the Keychain. Access coordinators batch per-key auth prompts so one session doesn't re-prompt repeatedly.

### Advanced authentication (macOS, feature-flagged)

- `AdvancedAuthenticationView.swift`, `AdvancedAuthenticationStore.swift` (macOS) / `MobileAdvancedAuthenticationStore.swift` (iPadOS)
- Secure Enclave identities, security keys, SSH certificate identities. Gated behind `FeatureFlags.advancedAuthentication`.

### Credentials

- `CredentialResolver.swift`, `KeychainManager.swift` (macOS) / `MobileKeychainManager.swift` (iPadOS)
- FFI: `rshell_keychain_*` (load / save / list / delete / is_supported)
- Passwords and key passphrases live in Keychain only; never on disk in plaintext.

### Host-key trust

- `HostKeyPrompt.swift`
- TOFU store managed by `ssh-commander-core`; a mismatch surfaces both fingerprints in an alert. Trusting the new key evicts the stored entry via `rshell_forget_host_key`, then the next connect TOFU-trusts it.

### Import

- `ImportManager.swift` + `Sources/AgentSshMacOS/SSHConfigParser.swift` — imports connection profiles from an OpenSSH client config (`~/.ssh/config` one-click, or any file via the picker). Resolves `Include` directives, `Host *` defaults, and pattern stanzas with ssh's own first-obtained-wins semantics (validated against `ssh -G`). `IdentityFile` comes across as a key-path reference — private keys are never read; hosts without one default to SSH-agent auth. CSV import/export lives in `ConnectionCSVCodec.swift`.

---

## Terminal

### PTY sessions

- **macOS**: `TerminalView.swift`, `TerminalSessionManager.swift`, `TerminalTabsStore.swift`, `TerminalThemes.swift`, `TerminalSearchBar.swift`, `PTYBufferManager.swift`, `WriteBatcher.swift`
- **iPadOS**: `MobileTerminalView.swift`, `MobileTerminalSessionManager.swift`, `MobileTerminalPane.swift`, `MobileTerminalAccessoryBar.swift`, `MobileTerminalPreferences.swift`
- SwiftTerm renderer on both platforms, xterm-256color, regex search, theme picker.
- FFI: `rshell_connect`, `rshell_pty_start` / `rshell_pty_write` / `rshell_pty_resize` / `rshell_pty_close`. Output arrives as `PtyOutput` events on the typed event bus (`rshell_set_event_callback`, `McSshEventBus.swift`).

### Workspace layout (macOS)

- `ContentView.swift`, `PanelViews.swift`, `WorkspaceTabStripView.swift`, `WorkspaceSplitController.swift`, `LayoutManager.swift`
- Per-tab main panel (terminal + Files / Security sub-tabs), inspector panel (host monitor), plus workspace-wide panels toggled from the tab strip: Dashboard (multi-host monitor grid), Agent (triage), Files (multi-host file grid).

### Command palettes

- `CommandPaletteView.swift` (macOS ⌘K) / `MobileGlobalCommandPaletteView.swift`, `MobileTerminalCommandPaletteView.swift` (iPadOS)

### Snippets & tmux (iPadOS)

- `MobileSnippetsView.swift` — parameterized command snippets run against the active host.
- `MobileTmuxSessionManagerView.swift` — tmux session list / create / attach (feature-flagged).

### Shell integration

- Shared: `ShellIntegrationCommands.swift`; handlers: `ShellIntegrationCommandCenter.swift` (macOS), `MobileShellIntegrationCommandCenter.swift` (iPadOS)
- Remote scripts emit `notify` / `widget` / `liveActivity` commands that the terminal session manager parses out of session output → local notification + activity log, widget snapshot update, or Live Activity.

---

## File transfer

### Dual-pane file browser (macOS)

- `DualPaneFileBrowserView.swift`, `FileBrowserView.swift`, `LocalFileBrowserView.swift`, `FileOperationsManager.swift`, `FilePermissionsEditor.swift`
- Side-by-side local / remote, chmod / chown / chgrp, rename, mkdir, delete.
- FFI: `rshell_sftp_list_dir`, `rshell_sftp_upload` / `rshell_sftp_download` (with `TransferProgress` events), `rshell_sftp_rename`, `rshell_sftp_chmod` / `rshell_sftp_chown` / `rshell_sftp_chgrp`, `rshell_sftp_create_dir`, `rshell_sftp_delete_file` / `rshell_sftp_delete_dir`, `rshell_sftp_cancel`, `rshell_sftp_resolve_uid` / `rshell_sftp_resolve_gid`.

### Multi-host Files workspace (macOS)

- `FilesPanel.swift` — one browser pane per connected host in a grid; rows drag between panes for cross-server copy.
- `DirectServerCopy.swift`, `RemoteCopyCoordinator.swift` — server→server copy pushes the file straight from source to destination over SFTP with an ephemeral keypair; bytes never relay through the Mac.

### File edit & safe config save

- **macOS**: `FileEditView.swift`, `FileEditView+WritingTools.swift`, `FileDiffReviewSheet.swift`, `SafeConfigSave.swift`
- **iPadOS**: `MobileRemoteFileEditorView.swift`, `MobileSafeConfigSave.swift`
- Diff review before overwriting remote files. Safe config save takes a timestamped `.bak` copy on the host before writing known config paths, with optional validator commands (e.g. `nginx -t`) so a typo doesn't take the host down.

### Transfer queue

- `TransferQueueStore.swift`, `TransferProgressOverlay.swift` (macOS)
- Queued + in-flight transfers with progress, cancel, and completion notifications.

### Files.app provider & offline sync (iPadOS, feature-flagged)

- `AgentSshFileProvider/FileProviderExtension.swift` — `NSFileProviderReplicatedExtension`; SFTP hosts appear as Files.app locations. Backed by `MobileSFTPBridge.swift`, `Sources/AgentSshMacOS/OfflineSFTPFileProviderModels.swift`, `SharedUploadStagingStore.swift`.
- `MobileOfflineSFTPSyncEngine.swift` — pinned remote folders cached for offline use (item-capped).
- `AgentSshShareExtension/ShareViewController.swift` — uploads from other apps via the share sheet.

---

## Monitors (macOS)

### Host monitor

- `SystemMonitorView.swift` (+ `+Content` / `+Header` / `+Health` / `+Polling`), `MonitorPollingManager.swift`, `MonitorSharedViews.swift`
- CPU, memory, load, per-mount disk, UFW status badge; per-host poller. Lives in the inspector panel per tab and tiled in the Dashboard panel (`PanelViews.swift`).
- FFI: `rshell_get_system_stats`.
- `SystemMonitorView+Health.swift` + `HostHealthNarrator.swift` — one-line plain-language host verdict, on-device FoundationModels when available, deterministic fallback otherwise.
- `ConnectionWorldMapView.swift` — map of the host's outbound peers by geolocated IP.
- Alerts: `MonitoringAlertNotificationCenter.swift`, `WorkspaceNotifications.swift`, `MonitorDiagnostics.swift`.

### Drill-downs

- `MonitorDrillDownSheet.swift` (+ `+ContentSections` / `+DetailPanes` / `+ProcessViews` / `+Scripts`)
- Click any headline metric: CPU / memory (live `ps`-based process tables over the SSH session), per-mount disk usage, systemd service detail with journal, UFW rules + logs (`UFWMonitorModels.swift`).

### Docker monitor

- `DockerMonitorView.swift` (+ `+Actions` / `+AssetsEvents` / `+Disk`), `DockerModels.swift`
- Modes: containers, logs, images, volumes, networks, events, disk. Container lifecycle verbs and prune actions (build cache, dangling images, stopped containers, unused volumes / networks) run behind an explicit confirmation with the literal `docker …` command shown.
- All via docker CLI over the existing SSH session (`RemoteCommandRunner.swift` → `rshell_execute_command`).

### systemd monitor & journal

- `SystemdMonitorView.swift` (+ `+Actions` / `+Journal` / `+Lists`), `SystemdServicesPane.swift`, `SystemdSharedTypes.swift`
- Units, timers, per-unit detail; start / stop / restart actions.
- Journal panes: `MonitorJournalView.swift` (severity filter, follow-tail; `MonitorJournalLogView` is reused by the drill-down sheet), `JournalIssueClassifier.swift` groups recurring problems.
- `Sources/AgentSshMacOS/JournalSyntaxHighlighting.swift` — shared journal/log syntax highlighting: JSON and logfmt level detection (Bunyan numeric levels included), used by the macOS journal panes and the iPadOS server detail view.

### Postgres monitor

- `PostgresMonitorView.swift` (+ `+Actions` / `+QueryViews` / `+SlowReplBackup` / `+Vacuum`), `PostgresModels.swift`
- Modes: dashboard, sessions, locks, query, schema, explain, slow queries, replication, vacuum, backup (`pg_dump`).
- Everything runs as `psql` / `pg_dump` over the existing SSH session (`RemoteCommandRunner` → `rshell_execute_command`), optionally as a configured OS account via `sudo -n` / `su`. No separate DB connection or tunnel.
- Note: the native Rust Postgres FFI (`rshell_pg_*`, including the parquet export in `src/ffi/postgres/`) still exists but has **no UI** — the former native Postgres workspace was retired.

---

## Server Doctor (AI diagnosis)

- **macOS UI**: `ServerDoctorView.swift`, `ServerDoctorStore.swift`, `ServerDoctorSettingsView.swift`, `ServerDoctorReportGenerator.swift`, `ServerDoctorExplanationService.swift`
- **Shared**: `Sources/AgentSshMacOS/ServerDoctorModels.swift`, `ServerDoctorHeuristics.swift`, `ServerDoctorRedactor.swift`, `ServerDoctorReportValidator.swift`, `ServerDoctorProviderKind.swift`, `ServerDoctorSharedSummary.swift`
- Evidence collection is **read-only from a fixed command allowlist** (`src/doctor.rs`; profiles: host, systemd, nginx, disk). FFI: `rshell_doctor_preview` shows the exact commands before anything runs, `rshell_doctor_collect` executes them.
- Provider chain (`ServerDoctorProviderFactory.swift`): on-device Apple FoundationModels (`AppleFoundationModelsDoctorProvider.swift`) → user-configured loopback OpenAI-compatible / Ollama endpoint (`ServerDoctorLLMProvider.swift`) → deterministic heuristics. Evidence is redacted (privacy presets) before any model sees it; the heuristics path always works with no AI at all.
- Reports are validated against the evidence (`ServerDoctorReportValidator.swift`); latest verdict badges the sidebar via `ServerDoctorSharedSummary.swift`.
- **iPadOS**: `MobileServerDoctorView.swift`, `MobileServerDoctor.swift` — heuristic quick-check over the monitor bridge (stats + service probes); no LLM on mobile.

## Security Patch Monitor (macOS)

- UI: `SecurityPatchMonitorView.swift` — the "Security" sub-tab on every connected host's main panel; sidebar badges via `SecurityPatchMonitorSummaryStore.swift`.
- Stores: `SecurityPatchMonitorStore.swift`, `SecurityPatchMonitorResultStore.swift`, `SecurityPatchMonitorCache.swift`, `SecurityPatchAdvisoryStore.swift`; bridge: `BridgeManager+SecurityPatchMonitor.swift`.
- Shared logic: `Sources/AgentSshMacOS/SecurityPatchMonitorModels.swift`, `SecurityPatchMonitorParsers.swift`, `SecurityPatchMonitorScoring.swift`, `SecurityPatchMonitorAdvisoryCorrelation.swift`.
- FFI: `rshell_security_patch_preview` (show commands first), `rshell_security_patch_scan`. Read-only scan profiles: OS release, package manager (apt / dnf / yum / zypper / pacman / apk / homebrew), reboot-required, sshd hardening, network exposure.
- **CISA KEV correlation**: `SecurityPatchAdvisoryStore` fetches and caches the CISA Known Exploited Vulnerabilities catalog; CVE ids extracted from scan evidence are matched against it and escalate to critical findings.

## Agent triage panel (macOS)

- `AgentPanel.swift`, `AgentTriageStore.swift`
- Exception-based alternative to the dashboard ("dark cockpit"): near-empty when healthy, reorganizes around problems when not. Aggregates the dashboard health pipeline (CPU / memory / disk / UFW / monitor errors) and tab connection state; per-kind confirmation delays and snoozes prevent one-sample spikes from crying wolf. Badges the workspace tab strip.

## MCP server & AI command gate (macOS)

- `MCPServerManager.swift` — MCP (JSON-RPC) server on a unix socket in the app-group container. Tools: `run_command`, `read_file`, `write_file`, `list_dir`, `postgres_query`.
- `Sources/AgentSshMacOS/MCPSecurityGate.swift` — every tool call is classified safe vs. modifying (`ShellCommandClassifier` for shell, keyword tokenizer for SQL); anything unparseable or unknown fails closed as modifying. Modifying actions require Touch ID / local auth approval before execution.
- Audit log: every call recorded as an `MCPAuditEvent` (pending / approved / silent-allowed / denied / executed / failed), browsable in `MCPSettingsView.swift` (Settings), which also provides the client setup snippet.
- `scripts/agent-ssh-mcp/main.swift` — stdio↔socket bridge binary so external agents (Claude Code, etc.) can connect.
- FFI: `rshell_mcp_execute` performs the actual remote work over the existing SSH session.

---

## Runbooks (both platforms)

- **macOS**: `RunbooksPanelView.swift` — saved command sequences with per-runbook risk labels (read-only / changes server / dangerous).
- **iPadOS**: `MobileRunbooksView.swift` — built-in runbooks with a single templated variable (e.g. service name) plus user-saved ones; `MobileRunbookStores.swift` persists saved runbooks and an execution history with exit codes and output previews.

---

## Port forwarding & network tools

### Port forwarding (feature-flagged)

- **macOS**: `PortForwardingView.swift` (coordinator + per-host panel inside the host monitor; auto-start on connect via `TerminalTabsStore.swift`), `BridgeManager+PortForwarding.swift`
- **iPadOS**: `MobilePortForwardingView.swift`, `MobilePortForwardBridge.swift`
- FFI: `rshell_port_forward_start` / `rshell_port_forward_stop` / `rshell_port_forward_status` / `rshell_port_forward_list`.

### Network tools window (macOS)

- `NetworkToolsWindow.swift`, `BridgeManager+Tools.swift` — separate window, operates over already-connected SSH tabs.

| Tool | FFI | What it does |
|------|-----|---------------|
| **Git deploy-state** | `rshell_git_status` | Branch, HEAD, dirty flag, last commit of a remote repo |
| **DNS** | `rshell_dns_resolve` | Multi-perspective resolution across all live hosts + the Mac |
| **Listening ports** | `rshell_listening_ports` | `ss` / `netstat` inventory with PID + process name |
| **tcpdump** | `rshell_tcpdump_start` / `rshell_tcpdump_stop` | Streaming `tcpdump -lnn` lines over the event bus |

### Mobile network diagnostics (iPadOS)

- `MobileNetworkDiagnosticsView.swift` — listening ports, interface stats, DNS info, ARP table, connection summary.

### Network polish (feature-flagged)

- `NetworkPolishSettingsView.swift`, `Sources/AgentSshMacOS/NetworkPolishModels.swift` — Tailscale-aware resolution and Multipath TCP options.

---

## Cloud accounts (feature-flagged, basic)

- `CloudServerManagementView.swift`, `CloudServerTokenStore.swift` (API tokens in Keychain), `Sources/AgentSshMacOS/CloudProviderClients.swift`, `CloudServerProviderModels.swift`
- DigitalOcean and Hetzner only. Honest scope: account management, server inventory list, create, reboot, delete. No resize, snapshots, firewalls, or networking management. Deleting a server does not delete generated SSH profiles.

---

## Shortcuts, widgets, Live Activities, watch

| Surface | Where | Notes |
|---------|-------|-------|
| Shortcuts (iOS) | `AgentSshShortcutsExtension/ShortcutsExtension.swift` | App Intents: list servers, run command, upload / download file, open terminal, sync offline folder, tail logs, start monitor, check server health, diagnose server |
| macOS widget | `AgentSshWidgets/MidnightSSHMonitoringWidget.swift` | Monitoring snapshots from `WidgetMonitoringSnapshotCenter.swift` / `WidgetSnapshotBootstrapper.swift` |
| iOS widgets + Dynamic Island | `AgentSshMobileWidgets/MidnightSSHMobileWidgets.swift` | Monitoring timeline + Live Activity presentation; snapshots via `MobileWidgetSnapshotCenter.swift` |
| Live Activities (iPadOS) | `MobileLiveActivityCenter.swift`, `Sources/AgentSshMacOS/LiveActivityModels.swift` | Operation kinds: command, transfer, tunnel, offline sync, shortcut, file provider, share upload |
| Watch status | `Sources/AgentSshMacOS/WatchStatusModels.swift` | Status snapshot store feeding the widget pipeline; there is **no** dedicated watch app target |
| Alert delivery | `Sources/AgentSshMacOS/MonitoringAlertDeliveryPayload.swift`, `MobileMonitoringAlertNotificationCenter.swift` | Threshold alerts as local notifications on both platforms |

---

## iPadOS-specific surfaces

| Feature | File | Purpose |
|---------|------|---------|
| Fleet dashboard | `MobileFleetOverviewDashboardView.swift` | Landing view after auto-connect: fleet summary, "needs attention" section, live server tiles (30 s refresh) backed by `MobileServerHealthStore.swift` |
| Server dashboard / detail | `MobileServerDashboardView.swift`, `MobileServerDetailView.swift` | Per-host stats, process list with kill (`rshell_get_processes` / `rshell_signal_process` via `MobileMonitorBridge.swift`), journal with syntax highlighting |
| DevOps panels | `MobileDevOpsPanelsView.swift` | Logs + systemd services |
| Runtime panels | `MobileRuntimePanelsView.swift` | Docker and Postgres snapshots |
| Service inspector | `MobileServiceInspectorView.swift` | Per-service severity-ranked inspection results |
| Package updates | `MobilePackageUpdatesView.swift` | Pending updates with security-update count and OS release |
| Disk analyzer | `MobileDiskAnalyzerView.swift` | Navigable `du`-style directory size breakdown |
| Activity log | `MobileActivityLogStore.swift` | Per-session timeline of commands + results |
| Connection map | `MobileConnectionMapView.swift` | Reachability overview of the fleet |
| Privacy gate | `MobilePrivacyGateView.swift` | Face ID gates on destructive surfaces (kill process, delete file) |
| Security vault | `MobileSecurityVaultView.swift` | Master view of stored keys and trust state |
| Incident report builder | `MobileIncidentReportBuilder.swift` | Capture state + commands into a shareable bundle for postmortem |
| Diagnostics bundle | `MobileDiagnosticsBundle.swift` | Self-diag dump (Keychain reachability, FFI version, network status) |
| Remote task runner | `MobileRemoteTaskRunner.swift`, `MobileRemoteTaskModels.swift` | Risk-labelled remote commands with exit-code capture, used by runbooks and panels |

---

## App-level tooling

| Surface | File | Purpose |
|---------|------|---------|
| Auto-updates | `UpdateManager.swift`, Sparkle 2 | Background check + updates (macOS) |
| Crash reporter | `CrashReporter.swift` | Capture, store, and offer to share crash logs |
| Diagnostics bundle | `DiagnosticsBundle.swift` (macOS), `MobileDiagnosticsBundle.swift` (iPadOS) | One-shot state dump for support |
| Settings | `SettingsView.swift` | Terminal, Appearance, Credentials, License, and Privacy tabs; MCP settings via `MCPSettingsView.swift` |
| Workspace notifications | `WorkspaceNotifications.swift` | Hub for transfer progress, monitor alerts, completions |
| Activity log | `ActivityLogStore.swift` (macOS) | Timeline of app-initiated actions and shell-integration events |
| Connection confidence | `ConnectionConfidenceView.swift` (macOS), `MobileConnectionConfidenceView.swift` (iPadOS) | Per-host reliability signal |

---

## Licensing & feature flags

- `Sources/AgentSshMacOS/FeatureFlags.swift` — build-time flags gating non-v1 surfaces. Debug builds: everything on. Release builds enable only Shortcuts automation, Live Activity surfaces, Server Doctor, and Security Patch Monitor; everything else (remote desktop, standalone SFTP, FTP, drag-and-drop transfer, terminal images, GPU monitor, Files-app provider, share-sheet uploads, offline SFTP cache, iCloud sync, filename-aware terminal, tmux manager, port forwarding, advanced auth, cloud server management, network polish) stays hidden until flipped.
- **macOS licensing** — `EntitlementsStore.swift`: free / pro / team tiers with signed license-key validation, surfaced in Settings → License. **Status only: nothing in the macOS app currently gates features on it.**
- **iPadOS licensing** — `MobileEntitlementsStore.swift`: StoreKit lifetime Pro unlock. The free tier enforces limits on connection count and saved runbooks.

---

## Build & FFI tooling

| Tool | Where | Run via |
|------|-------|---------|
| Universal Rust static lib | `AgentSshApp/build_cargo.sh` | Xcode build phase, or `just mac-rust` |
| iOS Rust slices | `scripts/build_cargo_ios.sh` | Xcode build phase for the iOS target |
| Swift binding regen | `uniffi-bindgen.rs` | `just mac-bindings` |
| Xcode project regen | `project.yml` + xcodegen | `just mac-gen` |
| DMG packaging | `AgentSshApp/build_dmg.sh` | `just mac-dmg` |
| Release bundle | `scripts/mac_release.sh` | `just mac-release [notarize=true]` |
| Sparkle keygen / appcast | `scripts/find_sparkle_tool.sh` | `just mac-sparkle-keygen`, `just mac-sparkle-appcast` |
