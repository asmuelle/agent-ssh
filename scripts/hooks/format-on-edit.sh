#!/usr/bin/env bash
# Agent harness — PostToolUse sensor (runs after Claude Code Write/Edit).
#
# Feedforward + feedback in one cheap step:
#   1. Format the edited file in place (rustfmt / swiftformat) — "auto-format on
#      write" cuts token waste and keeps style off the agent's plate.
#   2. For Rust, run a fast `cargo check` and surface ONLY hard compile errors
#      back to the agent (exit 2). "Success is silent, failures are verbose."
#
# Generated / vendored / lock files are skipped — formatting them is harmful.
# See AGENTS.md → "Automated sensors (the feedback loop)".
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

input="$(cat)"
file="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)"

[ -z "${file:-}" ] && exit 0
[ -f "$file" ] || exit 0

# Never touch generated bindings, vendored sources, build output, or lock files.
case "$file" in
  */bindings/*|*/target/*|*/.build/*|*/.derivedData/*|*Cargo.lock|*/SwiftTerm/*) exit 0 ;;
esac

ext="${file##*.}"
case "$ext" in
  rs)
    rustfmt --edition 2024 "$file" >/dev/null 2>&1 || true
    # Advisory compile sensor. Surface only errors so mid-refactor warnings
    # don't spam the agent. Blocks (exit 2) so the agent fixes breakage early.
    if ! err="$(cd "$ROOT" && cargo check --quiet --message-format short 2>&1)"; then
      {
        echo "cargo check failed after editing ${file##*/} — address before continuing:"
        printf '%s\n' "$err" | grep -E '^error' | head -20
      } >&2
      exit 2
    fi
    ;;
  swift)
    swiftformat "$file" >/dev/null 2>&1 || true
    ;;
esac
exit 0
