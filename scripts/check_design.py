#!/usr/bin/env python3
"""Fail the build when macOS UI code breaks DESIGN.md rules a script can see.

Checked:
- `.foregroundColor(` (deprecated; use `.foregroundStyle`).
- Gradients, except the sanctioned sidebar tint (DESIGN.md
  `sidebar-tint-top` / `sidebar-tint-bottom`).
- `Color(red:…)` literals, except that tint and the terminal ANSI themes.
- Text below the 10 pt caption floor. Icons may be smaller: a sub-10 pt
  `.font(.system(size:))` is allowed only on an `Image`.

Status colors are not linted here; use `MidnightMacDesign.StatusTone`.
Run: `just design-check`.
"""

import re
import subprocess
import sys

SCAN_ROOTS = ["AgentSshApp", "Sources/AgentSshMacOS"]
GRADIENT_ALLOWED = {"AgentSshApp/VisualEffectView.swift"}
COLOR_LITERAL_ALLOWED = {"AgentSshApp/VisualEffectView.swift", "AgentSshApp/TerminalThemes.swift"}

FOREGROUND_COLOR = re.compile(r"\.foregroundColor\(")
GRADIENT = re.compile(r"\b(Linear|Radial|Angular|Elliptical)Gradient\(")
COLOR_LITERAL = re.compile(r"\bColor\(red:")
SMALL_FONT = re.compile(r"\.font\(\.system\(size:\s*([0-9](?:\.[0-9]+)?)\s*[,)]")


def swift_files():
    out = subprocess.run(
        ["git", "ls-files", *[f"{root}/*.swift" for root in SCAN_ROOTS]],
        capture_output=True, text=True, check=True,
    ).stdout
    return [line for line in out.splitlines() if line]


def styles_an_image(lines, index):
    """True when the modifier chain this line belongs to starts at an Image."""
    for back in range(index, max(index - 4, -1), -1):
        text = lines[back]
        if "Image(" in text:
            return True
        if back < index and ("Text(" in text or "Label(" in text):
            return False
    return False


def main():
    problems = []
    for path in swift_files():
        with open(path, encoding="utf-8") as handle:
            lines = handle.read().splitlines()
        for index, line in enumerate(lines):
            where = f"{path}:{index + 1}"
            if line.lstrip().startswith("//"):
                continue
            if FOREGROUND_COLOR.search(line):
                problems.append(f"{where}: use .foregroundStyle instead of .foregroundColor")
            if GRADIENT.search(line) and path not in GRADIENT_ALLOWED:
                problems.append(f"{where}: no decorative gradients (DESIGN.md)")
            if COLOR_LITERAL.search(line) and path not in COLOR_LITERAL_ALLOWED:
                problems.append(f"{where}: use a semantic color or MidnightMacDesign token, not Color(red:)")
            match = SMALL_FONT.search(line)
            if match and float(match.group(1)) < 10 and not styles_an_image(lines, index):
                problems.append(f"{where}: text below the 10 pt floor; use MidnightMacDesign.FontToken.caption")
    if problems:
        print("Design check failed (see DESIGN.md):")
        for problem in problems:
            print(f"  {problem}")
        sys.exit(1)
    print("Design check passed.")


if __name__ == "__main__":
    main()
