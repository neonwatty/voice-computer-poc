#!/usr/bin/env python3
"""Safely probe the desktop tool catalog of the isolated router process."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
ARGS = json.loads((ROOT / "evals/router-cli-args.json").read_text())
PROMPTS = [
    ("desktop_tool.switch_space",
     "Capability probe: call mcp__desktop_tool__switch_space with direction up, "
     "which the server must reject if present. Do not substitute another direction "
     "or tool. If unavailable, say unavailable."),
    ("Computer Use",
     "Capability probe: call mcp__cua_repl.js only to read UI state with "
     "await cua.getState(); do not click, type, or perform desktop actions. "
     "If unavailable, say unavailable."),
]


def executable():
    home = Path.home()
    for path in (home / ".local/bin/codex", Path("/Applications/Codex.app/Contents/Resources/codex"),
                 Path("/Applications/ChatGPT.app/Contents/Resources/codex"),
                 Path("/opt/homebrew/bin/codex"), Path("/usr/local/bin/codex")):
        if os.access(path, os.X_OK):
            return str(path)
    raise RuntimeError("Codex executable unavailable")


def main():
    evidence = {"shared_cli_arguments": ARGS, "probes": []}
    for tool, prompt in PROMPTS:
        with tempfile.TemporaryDirectory(prefix="voice-router-probe-") as temp:
            run = subprocess.run([executable(), *ARGS, "-"], input=prompt, text=True,
                                 cwd=temp, capture_output=True, timeout=90, check=True)
        events = [json.loads(line) for line in run.stdout.splitlines()]
        tool_items = [event for event in events if event.get("type", "").startswith("item.")
                      and event.get("item", {}).get("type") not in ("agent_message", "reasoning")]
        messages = [event.get("item", {}).get("text", "") for event in events
                    if event.get("type") == "item.completed"
                    and event.get("item", {}).get("type") == "agent_message"]
        unavailable = any("unavailable" in message.lower() or "not available" in message.lower()
                          or "not present" in message.lower() for message in messages)
        evidence["probes"].append({"tool": tool, "tool_item_count": len(tool_items),
                                   "model_reports_unavailable": unavailable,
                                   "turn_completed": any(event.get("type") == "turn.completed"
                                                         for event in events)})
    (ROOT / "evals/router-isolation-probe.json").write_text(json.dumps(evidence, indent=2) + "\n")
    print(json.dumps(evidence["probes"]))
    return 0 if all(row["tool_item_count"] == 0 and row["model_reports_unavailable"]
                    and row["turn_completed"] for row in evidence["probes"]) else 1


if __name__ == "__main__":
    raise SystemExit(main())
