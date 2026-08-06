# Midnight SSH — App Store Metadata

This file is the source of truth for customer-facing App Store Connect copy. Internal module names, bundle identifiers, the `agent-ssh://` compatibility URL, and the lifetime product identifier remain stable for migration compatibility.

## Identity

- **Name:** Midnight SSH
- **Subtitle:** Linux Server Doctor & SSH
- **Primary category:** Developer Tools
- **Secondary category:** Utilities
- **Copyright:** © 2026 Andreas Müller
- **Support URL:** https://asmuelle.github.io/agent-ssh/support.html
- **Privacy URL:** https://asmuelle.github.io/agent-ssh/privacy.html
- **Marketing URL:** https://asmuelle.github.io/agent-ssh/

## Keywords

`ssh,sftp,linux,server,terminal,sysadmin,devops,runbook,monitoring,diagnostics,incident`

## Promotional text

Diagnose Linux servers, review safe configuration changes, run repeatable procedures, and preserve incident evidence—directly over SSH, with no server agent to install.

## Description

Midnight SSH is a focused server-diagnosis and safe-operations workspace for iPhone and iPad.

Connect directly to a Linux server over SSH, inspect evidence-linked health findings, review configuration changes before they are applied, and keep repeatable procedures beside the host they operate on. No daemon or monitoring agent is installed on your server.

### Diagnose before changing

Server Doctor performs read-only checks for services, disk pressure, updates, SSH posture, and system health. Each finding links back to the evidence that produced it.

### Make safer changes

Review file diffs, preserve backups, validate configuration syntax, and keep a rollback path. Modifying AI-assisted operations require local approval; unknown commands fail closed.

### Keep the whole incident together

Use the native terminal and SFTP browser, save reusable runbooks, monitor fleet health, and export incident evidence without jumping between unrelated tools.

### Local-first security

Passwords and key-encryption secrets are stored in Apple Keychain; imported private keys are encrypted on device. Host-key changes fail closed. Connections go directly from your device to the server you choose. Optional public-IP geolocation is off until you opt in.

This App Store purchase applies to iPhone and iPad only; it does not unlock the separately distributed Mac build. Midnight SSH requires iOS/iPadOS 17 or later. iOS may suspend network sockets in the background; use tmux or screen for long-running terminal sessions.

## Screenshot sequence

Use real Release-build screenshots with populated demo fixtures and no customer infrastructure data.

1. **Know what needs attention** — Server Doctor overview with one meaningful finding.
2. **Trace every finding to evidence** — finding detail with the read-only command and output.
3. **Review changes before they reach production** — configuration diff and validation state.
4. **Turn procedures into safe runbooks** — ordered steps with verification and rollback.
5. **Keep every host in one operational context** — host workspace with terminal, files, and monitoring.
6. **Preserve an incident record** — evidence-export preview.
7. **Work natively on iPad** — iPad split-view server workspace.

Avoid architecture diagrams, terminal-only screenshots, fake metrics, unshipped extensions, iCloud sync, uninterrupted background execution, or claims that all database work is implemented without remote command-line tools.

## App Privacy draft

Confirm these answers in App Store Connect against the submitted binary and current Apple definitions:

- **Tracking:** No.
- **Data linked to identity:** None collected by the developer.
- **Other Data / app functionality:** Public source IP addresses are transmitted to ipwho.is only after the user explicitly enables Connection Map. They are used transiently to obtain approximate locations and are not used for tracking.
- **Diagnostics:** Anonymous diagnostics are disabled by default. Support bundles are created locally only on user request and are not uploaded automatically.
- **Purchases:** Apple processes StoreKit transactions.

## Review notes

- The app is an SSH client and requires a reachable server supplied by the reviewer. Provide a dedicated demo host and non-production credentials in App Review Information.
- Explain that Server Doctor checks are read-only and that modifying AI-assisted operations require local authentication.
- Explain that Connection Map's third-party IP lookup is opt-in and demonstrate the disclosure.
- State that background SSH continuity is not promised on iOS/iPadOS.
- Include steps for reaching the paywall, purchase restoration, Server Doctor, runbooks, and incident export.
- Before submission, verify the exact lifetime product `com.agent-ssh.mobile.pro.lifetime` exists, is cleared for sale, has localization and pricing, and is included with the app version.
