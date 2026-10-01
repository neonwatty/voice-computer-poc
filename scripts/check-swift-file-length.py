#!/usr/bin/env python3
"""Enforce a physical 300-line limit, including comments and blank lines."""

from pathlib import Path

MAX_LINES = 300
ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIRS = ("VoiceComputerPOC", "VoiceComputerPOCTests")


def main() -> int:
    violations = []
    for directory in SOURCE_DIRS:
        for path in sorted((ROOT / directory).rglob("*.swift")):
            with path.open(encoding="utf-8") as source:
                count = sum(1 for _ in source)
            if count > MAX_LINES:
                violations.append(f"{path.relative_to(ROOT)}: {count} lines (max {MAX_LINES})")
    if violations:
        print("\n".join(violations))
        return 1
    print(f"Swift source files are within the {MAX_LINES}-line limit.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
