# VISION.md — Midnight is a doctor, not a terminal

Date: 2026-09-17
Status: proposal

## The one sentence

Midnight is the app you open when a server is sick. Not the app you live in.
Not a terminal. A doctor.

Everything that does not serve "my box is misbehaving and I am on my phone" is
a distraction. Today, most of the app is distraction: roughly 60k lines of
Swift across 266 files doing a dozen jobs (terminal, SFTP, four monitors,
Server Doctor, patch monitor, runbooks, agent triage, MCP gate, port
forwarding, network tools, cloud accounts, widgets, Shortcuts, watch).

Termius, Blink and Prompt own "terminal". ShellFish owns "files". We will not
out-polish them on their turf and we do not need to. Nobody owns the moment of
panic. We own that.

## Who it is for

The DevSecOps indie: one person, a handful of Linux boxes, no on-call rota, no
SOC, no agent on the server. They get paged by a customer, a cron mail, or an
uptime bot. They are frequently not at a desk.

## What they actually do at 11pm

1. Something is down. They get a text.
2. They want to know what is wrong, in one screen, without typing.
3. They want to fix it with the smallest safe change, with a rollback.
4. They want proof of what happened, for the postmortem or the client.

That is four screens. **Diagnose. Fix. Prove. Watch.** That is the product.

## The four verbs

### Diagnose

Connect, and within five seconds see a graded report with evidence links.
Read only. Zero server agent. The "no agent" promise is the whole moat and it
belongs on the icon.

Docker, systemd, Postgres, disk, updates, SSH posture, CVEs: all of these are
evidence lines inside one report, not separate windows. Postgres is a finding
when it is unhealthy and invisible when it is fine.

### Fix

Every fix is a runbook: reviewed diff, backup, syntax check, rollback,
approval. Users write their own. The AI may propose one. Nothing runs
unreviewed, and unknown commands fail closed.

This is the existing "safe config save" plus the command gate, and it is the
best idea in the codebase. It becomes the only way to change a server from
inside the app.

### Prove

One tap exports the incident: findings, commands run, diffs, timestamps, as
Markdown. No competitor lists this. It is the smallest feature with the
biggest story.

### Watch

One widget, one Live Activity. Green or red per host. That is the entire fleet
view.

## The cuts

Anything not under one of the four verbs goes.

| Today | Decision | Why |
|---|---|---|
| Host, Docker, systemd, Postgres monitors as separate surfaces | Merge into the Doctor report | Four windows for one question ("is it healthy?") |
| Security Patch Monitor | Becomes one Doctor check plus one runbook | It is a finding and a fix, not a product |
| Cloud accounts (flagged) | Delete | Half-built, off-thesis |
| Network tools window, mobile network diagnostics, network polish (flagged) | Delete | WebSSH territory, not ours |
| Multi-host Files workspace | Delete | ShellFish territory |
| Files.app provider and offline sync (flagged) | Delete | Same |
| watch app | Delete | Watch is served by the widget |
| MCP server and agent triage panel as user-facing surfaces | Fold into runbook approval | The AI never gets its own tab. It writes findings and proposes runbooks; the human taps approve. One trust model, one UI |
| Terminal and SFTP | Keep, demote | Escape hatches. Second row. Never the first screen after connect |
| Feature flags | Ship or delete every one | A flagged feature is a decision we refused to make |
| Separate Mac purchase | One lifetime price, both platforms | See pricing |

Expected effect: roughly a third of the Swift and a matching slice of the FFI
surface disappear.

## What is sacred

- No agent on the server. Ever.
- Read-only by default. Writes only through reviewed runbooks.
- Host-key changes fail closed. Secrets stay in Keychain. Traffic goes device
  to server, nowhere else.
- The Doctor report is the first screen after connect on every platform.

## Pricing

One price, lifetime, macOS plus iOS. Indies are subscription-exhausted.
ServerCat anchors low; we do not compete there. We compete at Panic's price
with Panic's confidence.

## Sequence

1. **Rewrite the App Store description to the four verbs.** Do this before
   touching code. Any feature that does not fit under a verb is on the cut
   list. The copy forces the decision.
2. **Delete the flagged features and their FFI surface.** Regenerate bindings
   (`just mac-bindings`), commit.
3. **Merge the monitors into Doctor.** One report, evidence-linked, graded.
4. **Make the Doctor report the post-connect screen** on macOS, iPadOS and
   iPhone.
5. **Build incident export.** Markdown, one tap.
6. **Collapse pricing** to one lifetime product across platforms.

## Non-goals

- Team vaults, sync, shared hosts. Termius territory. Revisit only if solo
  users ask for it in numbers.
- Mosh or Eternal Terminal. If the terminal is the escape hatch, session
  resilience is tmux's job, as the store copy already says.
- Being a general sysadmin toolbox.

## The test for every future feature

Does it help someone whose server just went down, standing in a car park,
holding a phone? If not, no.

The app we have is a toolbox for a sysadmin with a desk. The app we should
ship fits in the pocket of someone whose server just went down. Say no to the
desk.
