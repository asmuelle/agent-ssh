#!/usr/bin/env python3
"""Fail when a cargo-deny advisory exception is missing or past review."""

from __future__ import annotations

import datetime as dt
import pathlib
import re
import sys
import tomllib

ROOT = pathlib.Path(__file__).resolve().parents[1]
DENY = ROOT / "deny.toml"
REVIEW_RE = re.compile(r"review-by\s+(\d{4}-\d{2}-\d{2})")


def main() -> int:
    today = dt.date.today()
    failures: list[str] = []

    # Parse deny.toml structurally rather than regex-scanning the raw text, so a
    # reformatted or multi-line ignore entry can't silently drop out of the gate.
    data = tomllib.loads(DENY.read_text(encoding="utf-8"))
    ignores = data.get("advisories", {}).get("ignore", [])

    for entry in ignores:
        # Entries may be a bare advisory id string or a `{ id, reason }` table.
        if isinstance(entry, str):
            failures.append(f"{entry}: missing review-by YYYY-MM-DD (bare id, no reason)")
            continue
        advisory = entry.get("id", "<unknown>")
        reason = entry.get("reason", "")
        review_match = REVIEW_RE.search(reason)
        if not review_match:
            failures.append(f"{advisory}: missing review-by YYYY-MM-DD")
            continue
        review_date = dt.date.fromisoformat(review_match.group(1))
        if review_date <= today:
            failures.append(f"{advisory}: review expired on {review_date.isoformat()}")

    if failures:
        print("cargo-deny advisory exceptions require review:", file=sys.stderr)
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        return 1

    print("cargo-deny advisory exception review dates are current")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
