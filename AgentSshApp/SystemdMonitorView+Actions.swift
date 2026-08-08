import AppKit
import Foundation
import AgentSshMacOS
import OSLog
import SwiftUI

extension SystemdMonitorView {
    // MARK: - Actions & loading

    @ViewBuilder
    func unitActions(_ unit: SystemdUnit) -> some View {
        let fragmentPath = unit.id == selectedUnit?.id ? unitProperties["FragmentPath", default: ""] : ""

        Button {
            pendingAction = UnitAction(verb: "start", unit: unit.name)
        } label: {
            Label("Start", systemImage: "play.fill")
        }
        .disabled(unit.isActive || unit.isTransitional || !unit.isLoaded)

        Button(role: .destructive) {
            pendingAction = UnitAction(verb: "stop", unit: unit.name)
        } label: {
            Label("Stop", systemImage: "stop.fill")
        }
        .disabled(!unit.isActive && !unit.isTransitional)

        Button(role: .destructive) {
            pendingAction = UnitAction(verb: "restart", unit: unit.name)
        } label: {
            Label("Restart", systemImage: "arrow.clockwise")
        }
        .disabled(!unit.isLoaded)

        Button {
            pendingAction = UnitAction(verb: "reload", unit: unit.name)
        } label: {
            Label("Reload", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(!unit.isActive)

        Divider()

        Button {
            pendingAction = UnitAction(verb: "enable", unit: unit.name)
        } label: {
            Label("Enable", systemImage: "checkmark.circle")
        }
        .disabled(unit.isEnabled || unit.unitFileState.lowercased() == "static" || unit.unitFileState.lowercased() == "generated")

        Button(role: .destructive) {
            pendingAction = UnitAction(verb: "disable", unit: unit.name)
        } label: {
            Label("Disable", systemImage: "slash.circle")
        }
        .disabled(!unit.isEnabled)

        Divider()

        Button {
            selectUnit(unit, resetDetailTab: false)
            unitDetailTab = .unitFile
            Task { await loadSelectedUnitDetail() }
        } label: {
            Label("View Unit File", systemImage: "doc.text.magnifyingglass")
        }

        Button {
            RemoteCommandRunner.copy(fragmentPath)
        } label: {
            Label("Copy Unit File Path", systemImage: "doc.on.doc")
        }
        .disabled(fragmentPath.isEmpty)

        Button {
            RemoteCommandRunner.copy(unit.name)
        } label: {
            Label("Copy Unit Name", systemImage: "doc.on.doc")
        }
    }

    func refresh() async {
        guard connectionId != nil else { return }
        switch mode {
        case .services, .failed:
            await loadUnits()
        case .timers:
            await loadTimers()
        case .journal:
            await loadJournal()
        }
    }

    func loadUnits() async {
        guard let connectionId else { return }
        loading = true
        defer { loading = false }
        let script = """
        command -v systemctl >/dev/null || { echo systemctl not found; exit 127; }
        export LC_ALL=C
        run_systemctl() {
          out=$(systemctl "$@" 2>&1)
          rc=$?
          if [ "$rc" -ne 0 ] && command -v sudo >/dev/null; then
            sudo -n systemctl "$@" 2>&1
          else
            printf '%s\\n' "$out"
            return "$rc"
          fi
        }
        out=$(systemctl list-units --type=service --all --no-legend --no-pager 2>&1)
        rc=$?
        if [ "$rc" -ne 0 ] && command -v sudo >/dev/null; then
          sudo_out=$(sudo -n systemctl list-units --type=service --all --no-legend --no-pager 2>&1)
          sudo_rc=$?
          if [ "$sudo_rc" -eq 0 ]; then
            out=$sudo_out
            rc=0
          else
            out=$(printf 'systemctl list-units failed:\\n%s\\n\\nsudo -n systemctl list-units failed:\\n%s\\n' "$out" "$sudo_out")
            rc=$sudo_rc
          fi
        fi
        if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
          out="systemctl list-units failed with exit code $rc and no output"
        fi
        if [ "$rc" -ne 0 ]; then
          printf '%s\\n' "$out"
          exit "$rc"
        fi
        files=$(run_systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null || true)
        echo '---UNITS---'
        printf '%s\\n' "$out"
        echo '---UNIT_FILES---'
        printf '%s\\n' "$files"
        echo '---JOURNAL_COUNTS---'
        if command -v journalctl >/dev/null 2>&1; then
          { journalctl -p warning --since '-1 hour' -n 5000 -o json --output-fields=_SYSTEMD_UNIT,PRIORITY --no-pager -q 2>/dev/null \
            || sudo -n journalctl -p warning --since '-1 hour' -n 5000 -o json --output-fields=_SYSTEMD_UNIT,PRIORITY --no-pager -q 2>/dev/null \
            || true; } \
          | awk -F'"' '
            {
              unit=""; prio=""
              for (i = 1; i < NF; i++) {
                if ($i == "_SYSTEMD_UNIT") unit = $(i+2)
                else if ($i == "PRIORITY") {
                  if ($(i+1) ~ /^:[0-9]/) { p = $(i+1); gsub(/[^0-9]/, "", p); prio = p }
                  else prio = $(i+2)
                }
              }
              if (unit == "") next
              if (prio != "" && prio + 0 <= 3) err[unit]++
              else warn[unit]++
            }
            END {
              for (u in err) { printf "%s\\t%d\\t%d\\n", u, err[u], warn[u] + 0; delete warn[u] }
              for (u in warn) printf "%s\\t0\\t%d\\n", u, warn[u]
            }'
        fi
        """
        do {
            let output = try await RemoteCommandRunner.runChecked(connectionId: connectionId, script: script)
            let unitOutput = output.section(after: "---UNITS---", before: "---UNIT_FILES---")
            let fileOutput = output.section(after: "---UNIT_FILES---", before: "---JOURNAL_COUNTS---")
            let countsOutput = output.section(after: "---JOURNAL_COUNTS---", before: nil)
            let fileStates = parseSystemdUnitFileStates(fileOutput)
            let journalCounts = parseSystemdJournalCounts(countsOutput)
            let parsed = unitOutput.lines()
                .compactMap { parseSystemdUnitLine($0, unitFileStates: fileStates) }
                .map { unit -> SystemdUnit in
                    guard let counts = journalCounts[unit.name] else { return unit }
                    var enriched = unit
                    enriched.journalErrors = counts.errors
                    enriched.journalWarnings = counts.warnings
                    return enriched
                }
            units = parsed
            if let selectedUnit,
               let refreshedSelection = parsed.first(where: { $0.id == selectedUnit.id }) {
                selectUnit(refreshedSelection, resetDetailTab: false)
            } else {
                selectUnit(parsed.first(where: \.hasOperationalProblem) ?? parsed.first)
            }
            ensureVisibleSelection()
            error = nil
            await loadSelectedUnitDetail()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadTimers() async {
        guard let connectionId else { return }
        loading = true
        defer { loading = false }
        let script = """
        command -v systemctl >/dev/null || { echo systemctl not found; exit 127; }
        export LC_ALL=C
        out=$(systemctl list-timers --all --no-legend --no-pager 2>&1)
        rc=$?
        if [ "$rc" -ne 0 ] && command -v sudo >/dev/null; then
          sudo_out=$(sudo -n systemctl list-timers --all --no-legend --no-pager 2>&1)
          sudo_rc=$?
          if [ "$sudo_rc" -eq 0 ]; then
            out=$sudo_out
            rc=0
          else
            out=$(printf 'systemctl list-timers failed:\\n%s\\n\\nsudo -n systemctl list-timers failed:\\n%s\\n' "$out" "$sudo_out")
            rc=$sudo_rc
          fi
        fi
        if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
          out="systemctl list-timers failed with exit code $rc and no output"
        fi
        if [ "$rc" -ne 0 ]; then
          printf '%s\\n' "$out"
          exit "$rc"
        fi
        printf '%s\\n' "$out"
        """
        do {
            let output = try await RemoteCommandRunner.runChecked(connectionId: connectionId, script: script)
            timers = output.lines().compactMap(parseSystemdTimerLine)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadSelectedUnitDetail() async {
        guard let connectionId, let selectedUnit else { return }
        let unit = RemoteCommandRunner.shellQuote(selectedUnit.name)
        let script = """
        command -v systemctl >/dev/null || { echo systemctl not found; exit 127; }
        run_systemctl() {
          out=$(systemctl "$@" 2>&1)
          rc=$?
          if [ "$rc" -ne 0 ] && command -v sudo >/dev/null; then
            sudo -n systemctl "$@" 2>&1
          else
            printf '%s\\n' "$out"
            return "$rc"
          fi
        }
        run_journalctl() {
          out=$(journalctl "$@" 2>&1)
          rc=$?
          if [ "$rc" -ne 0 ] && command -v sudo >/dev/null; then
            sudo -n journalctl "$@" 2>&1
          else
            printf '%s\\n' "$out"
            return "$rc"
          fi
        }
        echo '---PROPERTIES---'
        run_systemctl show \(unit) --no-pager -p Id -p Description -p LoadState -p ActiveState -p SubState -p UnitFileState -p NRestarts -p MainPID -p ActiveEnterTimestamp -p FragmentPath -p MemoryCurrent -p CPUUsageNSec || true
        echo '---DEPENDENCIES---'
        run_systemctl list-dependencies --plain --no-pager \(unit) | sed -n '1,120p' || true
        echo '---REVERSE---'
        run_systemctl list-dependencies --reverse --plain --no-pager \(unit) | sed -n '1,80p' || true
        echo '---UNIT_FILE---'
        run_systemctl cat \(unit) --no-pager || true
        echo '---JOURNAL---'
        run_journalctl -u \(unit) -n 160 --no-pager -o short-iso || true
        """
        do {
            let output = try await RemoteCommandRunner.runChecked(connectionId: connectionId, script: script)
            unitDetail = output.section(after: "---PROPERTIES---", before: "---DEPENDENCIES---")
            dependencies = output.section(after: "---DEPENDENCIES---", before: "---UNIT_FILE---")
            unitFileText = output.section(after: "---UNIT_FILE---", before: "---JOURNAL---")
            unitJournal = output.section(after: "---JOURNAL---", before: nil)
            error = nil
        } catch {
            unitDetail = "Could not load unit details: \(error.localizedDescription)"
            dependencies = ""
            unitFileText = ""
            unitJournal = ""
        }
    }

    func journalLoop() async {
        while !Task.isCancelled && liveJournal {
            await loadJournal()
            try? await Task.sleep(nanoseconds: Self.pollInterval)
        }
    }

    func loadJournal() async {
        guard let connectionId else { return }
        let priorityArg = journalPriority.flagValue.map { "-p \($0)" } ?? ""
        loading = true
        defer { loading = false }
        let script = """
        command -v journalctl >/dev/null || { echo journalctl not found; exit 127; }
        run_journalctl() {
          out=$(journalctl "$@" 2>&1)
          rc=$?
          if [ "$rc" -ne 0 ] && command -v sudo >/dev/null; then
            sudo -n journalctl "$@" 2>&1
          else
            printf '%s\\n' "$out"
            return "$rc"
          fi
        }
        run_journalctl \(priorityArg) -n \(journalTail) --no-pager -o short-iso || true
        """
        do {
            journal = try await RemoteCommandRunner.runChecked(connectionId: connectionId, script: script)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func run(_ action: UnitAction) async {
        guard let connectionId else { return }
        pendingAction = nil
        let script = "systemctl \(action.verb) \(RemoteCommandRunner.shellQuote(action.unit)) 2>&1"
        do {
            _ = try await RemoteCommandRunner.runChecked(connectionId: connectionId, script: script)
            await loadUnits()
        } catch {
            logger.error("systemctl \(action.verb, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }

    func errorPane(_ message: String) -> some View {
        placeholderView(icon: "exclamationmark.triangle", title: "systemd unavailable", message: message)
    }
}
