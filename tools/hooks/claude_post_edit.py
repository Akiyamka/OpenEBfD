#!/usr/bin/env python3
"""Claude Code PostToolUse hook: report architecture findings right after an edit.

Wired up in .claude/settings.json for Write|Edit. Reads the hook payload on
stdin, does nothing unless the edited file is one the architecture manifest
covers, and otherwise runs the checker and feeds its findings back into the
model's context so a violation is seen at the moment it is introduced instead of
at commit time.

Always exits 0: this is a reporting hook, not a gate. The pre-commit hook and CI
are the gates.
"""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CHECKER = ROOT / "tools" / "check_architecture.py"

WATCHED_PREFIXES = ("scripts/",)
WATCHED_FILES = ("tools/architecture_rules.toml",)


def edited_path(payload: dict[str, object]) -> str | None:
    tool_input = payload.get("tool_input")
    response = payload.get("tool_response")
    for source, key in (
        (response, "filePath"),
        (tool_input, "file_path"),
    ):
        if isinstance(source, dict):
            value = source.get(key)
            if isinstance(value, str) and value:
                return value
    return None


def relevant(raw: str) -> bool:
    try:
        relative = Path(raw).resolve().relative_to(ROOT).as_posix()
    except ValueError:
        return False  # outside this repository
    return relative.startswith(WATCHED_PREFIXES) or relative in WATCHED_FILES


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError):
        return 0
    if not isinstance(payload, dict):
        return 0

    raw = edited_path(payload)
    if raw is None or not relevant(raw):
        return 0

    completed = subprocess.run(
        [sys.executable, str(CHECKER), str(ROOT)],
        capture_output=True,
        text=True,
    )
    if completed.returncode == 0:
        return 0

    report = (completed.stdout + completed.stderr).strip()
    label = (
        "The architecture checker reports a broken rule manifest"
        if completed.returncode == 2
        else "The architecture checker found violations"
    )
    print(
        json.dumps(
            {
                "systemMessage": f"{label} (python3 tools/check_architecture.py)",
                "hookSpecificOutput": {
                    "hookEventName": "PostToolUse",
                    "additionalContext": (
                        f"{label} after this edit. Fix them before moving on, or add a "
                        "documented `# arch-allow:` hatch if the violation is "
                        f"deliberate.\n\n{report}"
                    ),
                },
            }
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
