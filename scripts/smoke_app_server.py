#!/usr/bin/env python3
"""Run bounded, reversible Computer Use commands against local codex app-server.

This tests the same app-server protocol as the Mac app without requiring remote
screen-control credentials. It approves only Computer Use requests for the
app named by the selected case and writes a local JSONL diagnostic receipt.
"""

import argparse
import ctypes
import json
import os
import plistlib
import queue
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from datetime import datetime, timezone
from pathlib import Path

from browser_fixture import make_server


COMMANDS = [
    "Open Safari and verify that a Safari window is visible.",
    "In Calculator, enter 9 × 7 = and verify that the displayed result is 63.",
    'In TextEdit, create a new unsaved document, type "Voice Computer Air smoke test", and verify the text is visible. Do not save the document.',
    "Bring Finder to the foreground and report the title of its visible window.",
    'In Voice Computer POC, type "For this log test, reply with one sentence and do not use computer controls." into the command field and click Run. Wait for the result, then open Diagnostic Log and verify that command_started and command_finished are visible. Do not control other apps.',
    'In Voice Computer POC, replace its command field with "In Calculator, enter 4 + 5 = and verify the displayed result is 9", then click Run. If Voice Computer POC shows a Computer Use approval for Calculator, choose Allow for session. Wait for the app result, open Diagnostic Log, and verify that command_started, tool_completed, and command_finished are visible. Do not control other apps.',
    "Switch one desktop Space to the right using Control-Right Arrow, then report whether the desktop changed. Use Finder only if Computer Use needs an app target. Do not create or remove Spaces.",
    "Switch one desktop Space to the left using Control-Left Arrow, then report whether the desktop changed. Use Finder only if Computer Use needs an app target. Do not create or remove Spaces.",
    'In Voice Computer POC, enter "Switch to the next desktop Space" in the command field and click Run. Wait for its result, then inspect Diagnostic Log for native_space_finished. Report the app result. Do not control other apps.',
    'In Voice Computer POC, enter "Switch one desktop Space right and then back left" in the command field and click Run. Wait for its result, then inspect Diagnostic Log for two native_space_step_verified entries and native_space_finished with verification verified. Report the app result. Do not control other apps.',
    "Use Computer Use with Mission Control as the only app target. Begin with cua.getApp('Mission Control'), then inspect its UI and click the desktop Space immediately to the right of the current one if available. Do not access Voice Computer POC or other apps. Do not send Control-Right or use shell commands or AppleScript. Do not create or remove Spaces. Report whether the desktop changed.",
    "Use Finder as the only Computer Use app target. Press F3 to show Mission Control, inspect the resulting UI, and click the desktop Space immediately to the right of the current one if its thumbnail is available. Do not send Control-Right or use shell commands or AppleScript. Do not create or remove Spaces or access unrelated apps. Report whether the desktop changed.",
    'In Voice Computer POC, enter "Inspect Mission Control desktop controls" in the command field and click Run. Wait for its result, then inspect Diagnostic Log for mission_control_ax_summary. Report the result and whether any Desktop or Space controls appeared. Do not control other apps.',
    'In Voice Computer POC, enter "Switch to the previous desktop Space" in the command field and click Run. Wait for its result, then inspect Diagnostic Log for native_space_step_verified and native_space_finished. Report the app result. Do not control other apps.',
    'In the exact Voice Computer POC app, enter "agent switch desktop space right" in the command field and press Return once. Inspect the visible desktop_tool.switch_space approval and choose Allow once only. Wait for the app result. Report the command ID and visible result; do not submit another command.',
    'In the exact Voice Computer POC app, enter "agent switch desktop space left" in the command field and press Return once. Inspect the visible desktop_tool.switch_space approval and choose Allow once only. Wait for the app result. Report the command ID and visible result; do not submit another command.',
    None,  # Case 17 receives its unique Browser fixture URL at runtime.
    None,  # Case 18 receives its unique Finder fixture path at runtime.
]
CASE_APP = ["Safari", "Calculator", "TextEdit", "Finder", "Voice Computer POC", "Voice Computer POC", "Finder", "Finder", "Voice Computer POC", "Voice Computer POC", "Mission Control", "Finder", "Voice Computer POC", "Voice Computer POC", "Voice Computer POC", "Voice Computer POC", "Voice Computer POC", "Voice Computer POC"]
MCP_CASES = {15: "right", 16: "left"}
EXACT_APP_CASES = {13, 17, 18, *MCP_CASES}
APP_LOG_DIRECTORY = Path.home() / "Library/Application Support/VoiceComputerPOC/Logs"


def mcp_case_phrase(index):
    return "agent switch desktop space " + MCP_CASES[index]
EXPECTED_EVIDENCE = [
    re.compile(r"Window:.*Safari|standard window.*Safari", re.IGNORECASE),
    re.compile(r"(?<!\d)63(?!\d)"),
    re.compile(r"Voice Computer Air smoke test"),
    re.compile(r"Window:.*Finder|standard window.*Finder", re.IGNORECASE),
    re.compile(r"command_finished"),
    re.compile(r"command_finished"),
    None,
    None,
    re.compile(r"native_space_finished"),
    re.compile(r"native_space_step_verified"),
    None,
    None,
    re.compile(r"mission_control_ax_summary"),
    re.compile(r"native_space_step_verified"),
    None,
    None,
    None,
    None,
]
INSTRUCTION = (
    "This prototype is for reversible, low-impact desktop tests. For other requests, "
    "explain that the prototype does not support them. Use only mcp__cua_repl.js "
    "for desktop UI interaction. Do not use shell commands, AppleScript, or file "
    "operations. If Computer Use access is needed, request it. Check the visible "
    "result before reporting success. Distinguish a declined access request from "
    "a tool failure; do not call a tool failure an access denial. On macOS, do "
    "not call cua.computer.launch_app; it is unavailable in this connection. "
    "For Voice Computer POC, bind by bundle ID com.neonwatty.VoiceComputerPOC. "
    "If the requested app has no window or Computer Use reports cgWindowNotFound, "
    "report that after one retry. Do not inspect unrelated apps. User request: "
)


def stamp():
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def screen_is_locked():
    if sys.platform != "darwin":
        return None
    try:
        output = subprocess.run(
            ["ioreg", "-r", "-c", "IOResources", "-l", "-w0"],
            capture_output=True, text=True, timeout=5, check=True,
        ).stdout
        match = re.search(r'"CGSSessionScreenIsLocked"=(Yes|No)', output)
        if match:
            return match.group(1) == "Yes"
        root = subprocess.run(
            ["ioreg", "-n", "Root", "-d1", "-a"],
            capture_output=True, timeout=5, check=True,
        ).stdout
        locked = plistlib.loads(root).get("IOConsoleLocked")
        return locked if type(locked) is bool else None
    except (OSError, subprocess.SubprocessError, ValueError, AttributeError):
        return None


def space_state():
    """Read ordered Spaces from preferences and the live ID from WindowServer."""
    if sys.platform != "darwin":
        return None
    try:
        output = subprocess.run(
            ["defaults", "export", "com.apple.spaces", "-"],
            capture_output=True, timeout=5, check=True,
        ).stdout
        configuration = plistlib.loads(output)["SpacesDisplayConfiguration"]
        monitors = configuration["Management Data"]["Monitors"]
        main = next(m for m in monitors if m.get("Display Identifier") == "Main")
        skylight = ctypes.CDLL("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight")
        skylight._CGSDefaultConnection.restype = ctypes.c_uint32
        skylight.CGSGetActiveSpace.argtypes = [ctypes.c_uint32]
        skylight.CGSGetActiveSpace.restype = ctypes.c_uint64
        current = skylight.CGSGetActiveSpace(skylight._CGSDefaultConnection())
        return {
            "current": current,
            "ordered": [space["id64"] for space in main["Spaces"]],
        }
    except (OSError, subprocess.SubprocessError, KeyError, StopIteration, ValueError, AttributeError):
        return None


def validate_exact_space_state(state, case):
    """Require two distinct live Main desktops and the case's starting edge."""
    if not isinstance(state, dict):
        raise RuntimeError("Cannot read the host's live desktop Space state")
    ordered = state.get("ordered")
    current = state.get("current")
    if (not isinstance(ordered, list) or len(ordered) != 2
            or any(type(value) is not int or value <= 0 for value in ordered)
            or ordered[0] == ordered[1] or type(current) is not int
            or current not in ordered):
        raise RuntimeError("Exact app case requires two distinct Main desktop Spaces")
    if case == 15 and current != ordered[0]:
        raise RuntimeError("Rightward MCP case requires the first Main desktop Space")
    if case == 16 and current != ordered[1]:
        raise RuntimeError("Leftward MCP case requires the second Main desktop Space")
    return state


def default_codex():
    candidates = [
        Path.home() / ".local/bin/codex",
        Path("/Applications/Codex.app/Contents/Resources/codex"),
        Path("/Applications/ChatGPT.app/Contents/Resources/codex"),
        Path("/opt/homebrew/bin/codex"),
        Path("/usr/local/bin/codex"),
    ]
    return next((str(path) for path in candidates if os.access(path, os.X_OK)),
                shutil.which("codex") or "codex")


def canonical_app_path(value):
    """Reject aliases and stale paths; CUA must select this exact installed app."""
    path = Path(value)
    if not path.is_absolute() or path.suffix != ".app" or not path.is_dir():
        raise ValueError("--app-path must name an existing absolute .app directory")
    if path != path.resolve() or any(part == ".." for part in path.parts):
        raise ValueError("--app-path must be canonical, without symlinks or parent traversal")
    executable = path / "Contents/MacOS/VoiceComputerPOC"
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise ValueError("--app-path has no executable VoiceComputerPOC")
    with (path / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    if info.get("CFBundleIdentifier") != "com.neonwatty.VoiceComputerPOC":
        raise ValueError("--app-path has the wrong bundle identifier")
    return path


def running_app_pids(app_path):
    """Read the executable paths reported by the kernel, never select by bundle ID."""
    expected = str(app_path / "Contents/MacOS/VoiceComputerPOC")
    output = subprocess.run(["ps", "-axo", "pid=,comm="], capture_output=True,
                            text=True, check=True, timeout=5).stdout
    return [int(match.group(1)) for line in output.splitlines()
            if (match := re.fullmatch(r"\s*(\d+)\s+(.+?)\s*", line))
            and match.group(2) == expected]


def process_start_identity(pid):
    result = subprocess.run(["ps", "-p", str(pid), "-o", "lstart="], capture_output=True,
                            text=True, check=True, timeout=5).stdout.strip()
    if not result:
        raise ValueError("Exact app process has no start identity")
    return result


def parse_open_session_log(output, pid, directory):
    """Select one regular mode-0600 JSONL held writable by the exact app PID."""
    directory = directory.resolve()
    listed_pid = None
    access = None
    candidates = []
    for line in output.splitlines():
        if line.startswith("p"):
            if listed_pid is not None:
                raise ValueError("Ambiguous PID in open file inventory")
            listed_pid = line[1:]
        elif line.startswith("f"):
            access = None
        elif line.startswith("a"):
            access = line[1:]
        elif line.startswith("n") and access in ("w", "u"):
            path = Path(line[1:])
            if path.parent == directory and re.fullmatch(r"session-\d+-[A-Fa-f0-9-]+\.jsonl", path.name):
                candidates.append(path)
    if listed_pid != str(pid) or len(candidates) != 1:
        raise ValueError("Missing or ambiguous PID-owned open session JSONL")
    path = candidates[0]
    if path.is_symlink() or path.resolve() != path:
        raise ValueError("Session JSONL path is not canonical")
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or info.st_uid != os.getuid():
        raise ValueError("Session JSONL must be owner-held regular mode-0600")
    return path


def open_session_log(pid, directory):
    output = subprocess.run(["lsof", "-nP", "-a", "-p", str(pid), "-Fpafn"],
                            capture_output=True, text=True, check=True, timeout=5).stdout
    return parse_open_session_log(output, pid, directory)


def cua_exact_path_call(item, app_path):
    arguments = item.get("arguments") or item.get("input") or {}
    code = arguments.get("code", "") if isinstance(arguments, dict) else str(arguments)
    if "com.neonwatty.VoiceComputerPOC" in code:
        raise RuntimeError("Exact-app case attempted ambiguous bundle-ID CUA binding")
    pattern = r"cua\.getApp\(\s*(['\"])" + re.escape(str(app_path)) + r"\1\s*\)"
    return bool(re.search(pattern, code))


def validate_mcp_cases(selected, single_step=False):
    if single_step:
        if selected != [15]:
            raise ValueError("Single-step MCP mode permits only one rightward case")
        return
    if len(selected) > 6 or selected != [15, 16] * (len(selected) // 2):
        raise ValueError("MCP cases require one to three complete right/left pairs")


def app_log_rows(path, since, offset=0):
    """Read only new rows in the one PID-owned session file."""
    rows = []
    with path.open("rb") as handle:
        if handle.seek(0, os.SEEK_END) < offset:
            raise ValueError("Session JSONL was truncated")
        handle.seek(offset)
        for line in handle:
            try:
                row = json.loads(line)
                row_time = datetime.fromisoformat(row["timestamp"].replace("Z", "+00:00")).timestamp()
            except (json.JSONDecodeError, KeyError, TypeError, ValueError):
                raise ValueError("Unreadable app JSONL row or timestamp") from None
            if row_time < since - 2:
                raise ValueError("Stale row appended in command window")
            rows.append(row)
    return rows


def verify_read_only_receipt(rows, before, after, prior_command_ids=()):
    """Require fresh trusted exact controls and no native action in one session."""
    def event(name):
        return [(index, row.get("details", {})) for index, row in enumerate(rows)
                if row.get("event") == name]

    starts = event("command_started")
    if len(starts) != 1 or starts[0][1].get("user_action") != "run":
        raise ValueError("Missing or ambiguous read-only command start")
    command_id = starts[0][1].get("command_id")
    if not command_id or command_id in prior_command_ids:
        raise ValueError("Read-only command ID is missing or stale")
    if any(row.get("details", {}).get("command_id") not in (None, command_id) for row in rows):
        raise ValueError("Conflicting command ID in read-only window")
    if any(row.get("event") in ("mcp_action_requested", "mcp_helper_bound",
                                    "mcp_bridge_accepted", "native_space_requested",
                                    "native_space_ax_pressed", "native_space_step_verified",
                                    "native_space_finished", "space_changed",
                                    "approval_decided") for row in rows):
        raise ValueError("Read-only case reached a native action or approval")
    summaries, finishes, observations = event("mission_control_ax_summary"), event("command_finished"), event("live_space_observed")
    if len(summaries) != 1 or len(finishes) != 1 or len(observations) != 2:
        raise ValueError("Read-only AX summary, finish, or live IDs missing")
    if finishes[0][1].get("status") != "completed":
        raise ValueError("Read-only command did not finish")
    summary = summaries[0][1]
    if summary.get("trusted") != "true" or summary.get("mission_present") != "true":
        raise ValueError("Accessibility trust or Mission Control launch missing")
    source = summary.get("control_source")
    if source == "dock":
        complete = summary.get("dock_found") == "true" and summary.get("limit_reached") == "false"
    elif source == "window_manager":
        complete = (summary.get("window_manager_found") == "true"
                    and summary.get("window_manager_lists") == "1"
                    and summary.get("wm_limit_reached") == "false")
    else:
        complete = False
    if not complete:
        raise ValueError("Exact Mission Control control source or complete scan missing")
    controls = [part.strip().split(":", 2) for part in summary.get("controls", "").split(";")]
    if len(controls) != 2 or any(len(part) != 3 for part in controls):
        raise ValueError("Expected exactly two Desktop controls")
    for number, (title, description, actions) in enumerate(controls, 1):
        if title != f"Desktop {number}" or description != f"exit to Desktop {number}" or "AXPress" not in actions.split(","):
            raise ValueError("Desktop title, description, or AXPress mismatch")
    if [(item.get("phase"), item.get("live_space_id")) for _, item in observations] != [
        ("before_command", str(before)), ("after_completion", str(before))
    ] or after != before:
        raise ValueError("Read-only live Space ID changed")
    if not starts[0][0] < summaries[0][0] < finishes[0][0] < observations[1][0]:
        raise ValueError("Read-only event order invalid")
    assert_log_privacy(rows)
    return {"command_id": command_id, "before": before, "after": after,
            "trusted": True, "controls": 2}


def assert_log_privacy(rows):
    private_keys = {"command_text", "raw_audio", "transcript", "prompt", "screenshot"}
    if any(private_keys.intersection(row.get("details", {})) for row in rows):
        raise ValueError("Private command or screen content in normal JSONL")


def verify_browser_receipt(rows, run_id, port, fixture_rows, observations,
                           before, after, prior_command_ids=(), mode="normal"):
    """Correlate the exact app command with a rendered Safari page and server requests."""
    starts = [row for row in rows if row.get("event") == "command_started"
              and row.get("details", {}).get("user_action") == "run"]
    if len(starts) != 1:
        raise ValueError("Missing or ambiguous Browser command start")
    command_id = starts[0].get("details", {}).get("command_id")
    if not command_id or command_id in prior_command_ids:
        raise ValueError("Browser command ID missing or stale")
    command_rows = [row for row in rows
                    if row.get("details", {}).get("command_id") == command_id]
    def events(name):
        return [row.get("details", {}) for row in command_rows if row.get("event") == name]
    routes = events("router_decided")
    turns = events("turn_requested")
    tools = events("tool_started")
    finishes = events("command_finished")
    if len(routes) != 1 or routes[0].get("route") != "browser" \
            or routes[0].get("action") != "follow_docs" \
            or routes[0].get("target") != "loopback_fixture":
        raise ValueError("Expected Browser route was not selected")
    if len(turns) != 1 or turns[0].get("route") != "browser":
        raise ValueError("Browser acting turn missing")
    if not tools or any(tool.get("server") != "cua_repl" for tool in tools):
        raise ValueError("Browser action did not use only Computer Use")
    approvals = events("approval_decided")
    if any(approval.get("server_name") != "cua_repl"
           or approval.get("decision") not in ("Allowed once", "Allowed for session")
           for approval in approvals):
        raise ValueError("Browser Computer Use approval was unexpected or declined")
    if len(finishes) != 1 or finishes[0].get("status") != "completed":
        raise ValueError("Browser app command did not complete")
    if any(row.get("event") in ("native_space_requested", "mcp_action_requested",
                                    "space_changed") for row in command_rows):
        raise ValueError("Browser command invoked an unexpected desktop action")
    if before is None or after != before:
        raise ValueError("Browser command changed desktop Space")
    expected_paths = {
        "normal": ["/home", "/docs"],
        "missing-link": ["/home"],
        "home-404": ["/home"],
        "redirect": ["/home", "/docs", "/error"],
    }.get(mode)
    if expected_paths is None:
        raise ValueError("Unsupported Browser fixture mode")
    if [(row.get("method"), row.get("path"), row.get("run_id"))
            for row in fixture_rows] != [
                ("GET", path, [run_id]) for path in expected_paths]:
        raise ValueError("Fixture request sequence did not match Browser scenario")
    final_path = expected_paths[-1]
    expected_url = f"http://127.0.0.1:{port}{final_path}?run_id={run_id}"
    heading = (f"Voice Computer Docs {run_id}" if mode == "normal" else
               f"Voice Computer Home {run_id}" if mode == "missing-link" else
               "Fixture page not found")
    if not any(expected_url.removeprefix("http://") in observation and heading in observation
               and "heading" in observation for observation in observations):
        raise ValueError("Independent rendered Safari URL and heading missing")
    assert_log_privacy(rows)
    return {"command_id": command_id, "scenario": mode, "url": expected_url,
            "heading": heading, "approval_state": "prompted" if approvals else "no_new_prompt",
            "before": before, "after": after}


def verify_finder_receipt(rows, report, observations, before, after,
                          prior_command_ids=()):
    """Require one exact selected fixture file in Finder and no desktop move."""
    starts = [row for row in rows if row.get("event") == "command_started"
              and row.get("details", {}).get("user_action") == "run"]
    if len(starts) != 1:
        raise ValueError("Missing or ambiguous Finder command start")
    command_id = starts[0].get("details", {}).get("command_id")
    if not command_id or command_id in prior_command_ids:
        raise ValueError("Finder command ID missing or stale")
    command_rows = [row for row in rows if row.get("details", {}).get("command_id") == command_id]
    def events(name):
        return [row.get("details", {}) for row in command_rows if row.get("event") == name]
    routes, turns, tools = events("router_decided"), events("turn_requested"), events("tool_started")
    approvals, finishes = events("approval_decided"), events("command_finished")
    if len(routes) != 1 or routes[0].get("route") != "finder" \
            or routes[0].get("action") != "reveal_file" \
            or routes[0].get("target") != "fixture_report":
        raise ValueError("Expected Finder route was not selected")
    if len(turns) != 1 or turns[0].get("route") != "finder":
        raise ValueError("Finder acting turn missing")
    if not tools or any(tool.get("server") != "cua_repl" for tool in tools):
        raise ValueError("Finder action did not use only Computer Use")
    if any(approval.get("server_name") != "cua_repl"
           or approval.get("decision") not in ("Allowed once", "Allowed for session")
           for approval in approvals):
        raise ValueError("Finder Computer Use approval was unexpected or declined")
    if len(finishes) != 1 or finishes[0].get("status") != "completed":
        raise ValueError("Finder app command did not complete")
    if any(row.get("event") in ("native_space_requested", "mcp_action_requested",
                                    "space_changed") for row in command_rows):
        raise ValueError("Finder command invoked an unexpected desktop action")
    if before is None or after != before:
        raise ValueError("Finder command changed desktop Space")
    if not report.is_file() or report.is_symlink():
        raise ValueError("Fixture report missing or not regular")
    selected = re.compile(r"^\s*\d+ row \(selected\)(?:(?!^\s*\d+ row ).)*?URL: (file://\S+)",
                          re.MULTILINE | re.DOTALL)
    decoy_uri = report.with_name("report-copy.txt").as_uri()
    if not any(set(selected.findall(observation)) == {report.as_uri()}
               and decoy_uri in observation
               for observation in observations):
        raise ValueError("Independent Finder selection of exact report missing")
    assert_log_privacy(rows)
    return {"command_id": command_id, "path": str(report),
            "approval_state": "prompted" if approvals else "no_new_prompt",
            "before": before, "after": after}


def verify_mcp_receipt(rows, phrase, direction, before, expected, after,
                       prior_command_ids=()):
    """Fail closed on any missing or ambiguous app-owned MCP/native proof."""
    def matching(event, command_rows):
        return [row.get("details", {}) for row in command_rows if row.get("event") == event]

    if phrase != "agent switch desktop space " + direction:
        raise ValueError("MCP case phrase does not match direction")

    starts = [row for row in rows if row.get("event") == "command_started"
              and row.get("details", {}).get("user_action") == "run"]
    ids = {row.get("details", {}).get("command_id") for row in starts}
    if len(starts) != 1 or len(ids) != 1 or not next(iter(ids)):
        raise ValueError("Ambiguous or missing app command ID")
    command_id = next(iter(ids))
    if command_id in prior_command_ids:
        raise ValueError("MCP command ID was not fresh")
    command_rows = [row for row in rows if row.get("details", {}).get("command_id") == command_id]
    if any(row.get("event") in ("tool_started", "native_space_requested", "command_finished")
           and row.get("details", {}).get("command_id") not in (None, command_id)
           for row in rows):
        raise ValueError("Conflicting command ID in app JSONL window")
    if matching("mcp_action_requested", command_rows) != [{"command_id": command_id, "direction": direction}]:
        raise ValueError("Missing or wrong acting MCP route")
    items = matching("tool_started", command_rows)
    items = [item for item in items if item.get("server") == "desktop_tool"
             or item.get("tool") == "switch_space"]
    if len(items) != 1 or items[0].get("server") != "desktop_tool" or items[0].get("tool") != "switch_space":
        raise ValueError("Missing or ambiguous desktop_tool.switch_space item")
    item = items[0]
    if not item.get("item_id") or item.get("item_id") == "unknown" or item.get("turn_matches") != "true":
        raise ValueError("MCP item lacks current turn correlation")
    if not item.get("event_turn_id") or item.get("event_turn_id") == "missing":
        raise ValueError("MCP item lacks source turn ID")
    approvals = matching("approval_decided", command_rows)
    if len(approvals) != 1 or approvals[0].get("server_name") != "desktop_tool" or approvals[0].get("decision") != "Allowed once":
        raise ValueError("Visible per-item Allow once missing")
    if not approvals[0].get("request_id"):
        raise ValueError("Approval request ID missing")
    helpers = matching("mcp_helper_bound", command_rows)
    if len(helpers) != 1 or len(matching("mcp_bridge_accepted", command_rows)) != 1:
        raise ValueError("Helper binding or bridge acceptance missing")
    helper = helpers[0]
    if (helper.get("path_matches_preflight") != "true" or not helper.get("pid", "").isdigit()
        or int(helper["pid"]) <= 0 or not helper.get("start_sec", "").isdigit()
        or not helper.get("start_usec", "").isdigit()):
        raise ValueError("Helper path/PID/start identity unverified")
    if matching("mcp_bridge_accepted", command_rows)[0].get("direction") != direction:
        raise ValueError("Bridge direction mismatch")
    requests = matching("native_space_requested", command_rows)
    verified = matching("native_space_step_verified", command_rows)
    if len(requests) != 1 or len(verified) != 1:
        raise ValueError("Native Space request/verification missing")
    for detail in requests + verified:
        if (detail.get("direction"), detail.get("space_before_id"), detail.get("space_target_id")) != (direction, str(before), str(expected)):
            raise ValueError("Native Space before/target mismatch")
    if verified[0].get("space_after_id") != str(expected) or int(verified[0].get("space_change_events", "0")) != 1:
        raise ValueError("Native after ID or notification count mismatch")
    presses = matching("native_space_ax_pressed", command_rows)
    notifications = matching("space_changed", command_rows)
    if len(presses) != 1 or presses[0].get("direction") != direction or len(notifications) != 1:
        raise ValueError("AX press or active-Space notification missing")
    if notifications[0].get("live_space_id") != str(expected):
        raise ValueError("Notification live ID mismatch")
    bridge_results = matching("mcp_bridge_result", command_rows)
    if len(bridge_results) != 1 or bridge_results[0].get("status") != "verified" or bridge_results[0].get("verification") != "verified":
        raise ValueError("Bridge result not verified")
    completed = [detail for detail in matching("tool_completed", command_rows)
                 if detail.get("server") == "desktop_tool" or detail.get("tool") == "switch_space"]
    if len(completed) != 1 or completed[0].get("item_id") != item["item_id"] or completed[0].get("server") != "desktop_tool" or completed[0].get("tool") != "switch_space":
        raise ValueError("Wrong or missing completed MCP item")
    typed = completed[0]
    if (typed.get("status"), typed.get("result_is_error"), typed.get("typed_status"),
        typed.get("typed_verified"), typed.get("typed_command_id"), typed.get("typed_direction")) != (
        "completed", "false", "verified", "true", command_id, direction):
        raise ValueError("Typed MCP result is not correlated and verified")
    correlated = matching("mcp_tool_result_correlated", command_rows)
    if len(correlated) != 1 or correlated[0].get("tool_command_id") != command_id or correlated[0].get("direction") != direction:
        raise ValueError("Completed tool result not correlated")
    turns = matching("turn_completed", command_rows)
    if len(turns) != 1 or turns[0].get("turn_id") != item["event_turn_id"] or turns[0].get("verification") != "verified":
        raise ValueError("Turn completion not correlated")
    finished = matching("command_finished", command_rows)
    if len(finished) != 1 or finished[0].get("verification") != "verified" or finished[0].get("status") != "completed":
        raise ValueError("App command did not finish verified")
    if after != expected:
        raise ValueError("Independent live Space ID mismatch")
    ordered = ["command_started", "mcp_action_requested", "tool_started", "approval_decided",
               "mcp_helper_bound", "mcp_bridge_accepted", "native_space_requested",
               "native_space_ax_pressed", "space_changed", "native_space_step_verified",
               "mcp_bridge_result", "tool_completed", "turn_completed", "command_finished"]
    positions = [[i for i, row in enumerate(command_rows) if row.get("event") == event]
                 for event in ordered]
    if any(len(group) != 1 for group in positions) or positions != sorted(positions):
        raise ValueError("MCP approval/native/tool event order invalid")
    assert_log_privacy(rows)
    return {"command_id": command_id, "item_id": item["item_id"],
            "turn_id": item.get("event_turn_id"), "before": before,
            "expected": expected, "after": after}


class Driver:
    def __init__(self, executable, log_path, trace_tool_output=False, app_path=None):
        self.log = log_path.open("x", encoding="utf-8")
        self.events = queue.Queue()
        self.next_id = 0
        self.command_index = None
        self.last_result = ""
        self.completed_turn = None
        self.tool_failures = []
        self.evidence_matches = []
        self.tool_calls = 0
        self.approvals = []
        self.stderr_lines = 0
        self.trace_tool_output = trace_tool_output
        self.app_path = app_path
        self.cua_binding_observed = False
        self.browser_observations = []
        self.browser_run_id = None
        self.finder_observations = []
        self.process = subprocess.Popen(
            [executable, "app-server"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        for stream, kind in ((self.process.stdout, "stdout"), (self.process.stderr, "stderr")):
            threading.Thread(target=self._read, args=(stream, kind), daemon=True).start()
        self.record("server_started", executable=executable, pid=self.process.pid)

    def _read(self, stream, kind):
        for line in stream:
            self.events.put((kind, line))
        self.events.put((kind, None))

    def record(self, event, **details):
        entry = {"timestamp": stamp(), "event": event, "command_index": self.command_index}
        entry.update(details)
        self.log.write(json.dumps(entry, ensure_ascii=False) + "\n")
        self.log.flush()

    def send(self, message):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def rpc(self, method, params):
        self.next_id += 1
        request_id = self.next_id
        self.record("rpc_sent", id=request_id, method=method)
        self.send({"id": request_id, "method": method, "params": params})
        return request_id

    def receive(self, deadline):
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("app-server event deadline exceeded")
            try:
                kind, line = self.events.get(timeout=min(remaining, 1))
            except queue.Empty:
                if self.process.poll() is not None:
                    raise RuntimeError("app-server exited with code %s" % self.process.returncode)
                continue
            if line is None:
                if kind == "stdout":
                    raise RuntimeError("app-server stdout closed")
                continue
            if kind == "stderr":
                if self.stderr_lines < 200:
                    self.record("server_stderr", bytes=min(len(line), 2000))
                elif self.stderr_lines == 200:
                    self.record("server_stderr_limit_reached")
                self.stderr_lines += 1
                continue
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                self.record("unreadable_server_message", bytes=min(len(line), 2000))
                continue
            if "method" in message and "id" in message:
                self.handle_request(message)
                continue
            if "method" in message:
                self.handle_notification(message)
                return {"_notification": message["method"]}
            return message

    def handle_request(self, message):
        method = message["method"]
        params = message.get("params") or {}
        meta = params.get("_meta") or {}
        app_values = meta.get("tool_params_display") or []
        app = str(app_values[0].get("value", "")) if app_values else ""
        allowed = (
            method == "mcpServer/elicitation/request"
            and params.get("mode") == "form"
            and meta.get("connector_id") == "computer-use"
            and not ((params.get("requestedSchema") or {}).get("properties") or {})
            and self.command_index is not None
            and app in ({CASE_APP[self.command_index - 1], str(self.app_path),
                         "Safari", "com.apple.Safari"}
                        if self.command_index == 17 else
                        {CASE_APP[self.command_index - 1], str(self.app_path),
                         "Finder", "com.apple.finder"}
                        if self.command_index == 18 else
                        {CASE_APP[self.command_index - 1], str(self.app_path)}
                        if self.command_index in EXACT_APP_CASES else
                        {CASE_APP[self.command_index - 1]})
        )
        self.approvals.append({"app": app, "allowed": allowed})
        self.record("approval_requested", app=app, action=meta.get("tool_name"), allowed=allowed)
        if method != "mcpServer/elicitation/request":
            self.send({"id": message["id"], "error": {
                "code": -32601, "message": "Unsupported smoke-test request",
            }})
            raise RuntimeError("Unexpected app-server request: %s" % method)
        if allowed:
            result = {"action": "accept", "content": {}}
            if "session" in (meta.get("persist") or []):
                result["_meta"] = {"persist": "session"}
        else:
            result = {"action": "decline", "content": None}
        self.send({"id": message["id"], "result": result})
        if not allowed:
            raise RuntimeError("Computer Use requested out-of-scope app: %s" % (app or "unknown"))

    def handle_notification(self, message):
        method = message["method"]
        params = message.get("params") or {}
        item = params.get("item") or {}
        if method == "item/started" and item.get("type") == "mcpToolCall":
            if self.command_index in EXACT_APP_CASES and item.get("server") == "cua_repl":
                if cua_exact_path_call(item, self.app_path):
                    self.cua_binding_observed = True
                    self.record("cua_exact_path_requested")
            self.tool_calls += 1
            limit = 24 if self.command_index in (6, 9, 10, 14, 15, 16, 17, 18) else 12
            if self.tool_calls > limit:
                raise RuntimeError("Command exceeded %s Computer Use calls" % limit)
            self.record("tool_started", item_id=item.get("id"), tool=item.get("tool"))
            if self.trace_tool_output:
                self.record("tool_input_trace", item_id=item.get("id"),
                            arguments=str(item.get("arguments") or item.get("input") or "")[:3000])
        elif method == "item/completed":
            if item.get("type") == "agentMessage":
                self.last_result = item.get("text") or ""
            elif item.get("type") == "mcpToolCall":
                result = item.get("result") or {}
                error = (item.get("error") or {}).get("message")
                content = result.get("content") or []
                if self.command_index == 17 and item.get("server") == "cua_repl":
                    self.browser_observations.extend(
                        part.get("text") or "" for part in content
                        if part.get("type") == "text" and "Window:" in (part.get("text") or "")
                        and "Safari" in (part.get("text") or ""))
                if self.command_index == 18 and item.get("server") == "cua_repl":
                    self.finder_observations.extend(
                        part.get("text") or "" for part in content
                        if part.get("type") == "text" and "Window:" in (part.get("text") or "")
                        and "Finder" in (part.get("text") or ""))
                if self.trace_tool_output:
                    self.record("tool_output_trace", item_id=item.get("id"),
                                excerpt="\n".join(str(part.get("text") or "") for part in content)[:3000])
                if item.get("status") == "failed" or result.get("isError"):
                    error = error or next((part.get("text") for part in content if part.get("text")), None)
                    self.tool_failures.append(
                        "stale_ui_state" if error and
                        "Re-query the latest state with `get_app_state`" in error
                        else "tool_failed")
                elif self.command_index is not None:
                    pattern = EXPECTED_EVIDENCE[self.command_index - 1]
                    for part in content:
                        if pattern and pattern.search(part.get("text") or ""):
                            self.evidence_matches.append(item.get("id"))
                            self.record("verification_evidence", item_id=item.get("id"),
                                        pattern=pattern.pattern)
                self.record(
                    "tool_completed", item_id=item.get("id"), tool=item.get("tool"),
                    status=item.get("status"), is_error=bool(result.get("isError")),
                    error_present=bool(error),
                )
        elif method == "turn/completed":
            turn = params.get("turn") or {}
            self.record("turn_completed", turn_id=turn.get("id"), status=turn.get("status"),
                        result_present=bool(self.last_result), error_present=bool(turn.get("error")))
            self.completed_turn = turn

    def wait_rpc(self, request_id, seconds=60):
        deadline = time.monotonic() + seconds
        while True:
            message = self.receive(deadline)
            if "_notification" in message:
                continue
            if message.get("id") != request_id:
                raise RuntimeError("Unexpected RPC response: %r" % message)
            if "error" in message:
                raise RuntimeError("RPC error: %r" % message["error"])
            self.record("rpc_completed", id=request_id)
            return message.get("result") or {}

    def wait_turn(self, seconds=180):
        deadline = time.monotonic() + seconds
        while self.completed_turn is None:
            self.receive(deadline)
        return self.completed_turn

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        self.record("server_exited", exit_code=self.process.returncode)
        self.log.close()


def selected_cases(suite, cases, mission_control_gate):
    if mission_control_gate and not suite:
        raise ValueError("--mission-control-gate requires --suite")
    if suite and cases:
        raise ValueError("--suite cannot be combined with --case")
    if suite:
        return ([13] if mission_control_gate else []) + [17, 18]
    return cases or list(range(1, 7))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default=default_codex())
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--trace-tool-output", action="store_true",
                        help="Record bounded tool input/output excerpts; may contain private UI text")
    parser.add_argument("--case", type=int, action="append", choices=range(1, len(COMMANDS) + 1),
                        help="Run one numbered command; repeat to select multiple")
    parser.add_argument("--suite", action="store_true",
                        help="Run Browser, Finder, and Codex status feasibility probe")
    parser.add_argument("--mission-control-gate", action="store_true",
                        help="Require read-only Mission Control case 13 before --suite acts")
    parser.add_argument("--browser-mode", default="normal",
                        choices=("normal", "missing-link", "home-404", "redirect"),
                        help="Fixture scenario for a focused --case 17 run")
    parser.add_argument("--codex-thread-id",
                        help="Optional exact existing Codex task UUID for --suite's read-only status probe")
    parser.add_argument("--app-path", type=Path,
                        help="Canonical absolute VoiceComputerPOC.app path, required for cases 13, 15, 16, 17, and 18")
    parser.add_argument("--single-mcp-step", action="store_true",
                        help="Run only one rightward MCP case and stop regardless of result")
    args = parser.parse_args()
    try:
        selected = selected_cases(args.suite, args.case, args.mission_control_gate)
    except ValueError as error:
        parser.error(str(error))
    if args.browser_mode != "normal" and selected != [17]:
        parser.error("--browser-mode requires a focused --case 17 run")
    if args.codex_thread_id and not args.suite:
        parser.error("--codex-thread-id requires --suite")
    if args.codex_thread_id and not re.fullmatch(
            r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}",
            args.codex_thread_id):
        parser.error("--codex-thread-id requires an exact Codex task UUID")
    mcp_selected = any(index in MCP_CASES for index in selected)
    exact_selected = any(index in EXACT_APP_CASES for index in selected)
    if args.single_mcp_step and not mcp_selected:
        parser.error("--single-mcp-step requires --case 15")
    app_path = None
    if exact_selected:
        if not args.app_path:
            parser.error("Cases 13, 15, 16, 17, and 18 require --app-path")
        try:
            app_path = canonical_app_path(args.app_path)
        except (OSError, ValueError) as error:
            parser.error(str(error))
    if mcp_selected:
        try:
            validate_mcp_cases(selected, single_step=args.single_mcp_step)
        except ValueError as error:
            parser.error(str(error))
    os.umask(0o077)
    args.log.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    driver = Driver(args.codex, args.log, trace_tool_output=args.trace_tool_output,
                    app_path=app_path)
    failed = False
    fixtures = []
    finder_fixtures = []
    try:
        locked = screen_is_locked()
        driver.record("environment_check", screen_locked=locked)
        if locked is True or (exact_selected and locked is not False):
            print("SMOKE BLOCKED: macOS desktop unlock state is not verified", file=sys.stderr)
            return 2
        driver.wait_rpc(driver.rpc("initialize", {"clientInfo": {
            "name": "voice_computer_smoke", "title": "Voice Computer Smoke Test", "version": "0.1.0",
        }}))
        driver.send({"method": "initialized", "params": {}})
        models = driver.wait_rpc(driver.rpc("model/list", {})).get("data") or []
        available = [item["id"] for item in models if "id" in item]
        model = "gpt-5.6-sol" if "gpt-5.6-sol" in available else available[0]
        driver.record("model_selected", model=model)
        support = Path.home() / "Library/Application Support/VoiceComputerPOC"
        support.mkdir(parents=True, exist_ok=True)
        thread = driver.wait_rpc(driver.rpc("thread/start", {
            "model": model, "cwd": str(support), "approvalPolicy": "on-request", "sandbox": "read-only",
        }))["thread"]["id"]
        for index in selected:
            phrase = COMMANDS[index - 1]
            fixture = None
            if index == 17:
                run_id = uuid.uuid4().hex
                temporary = tempfile.TemporaryDirectory(prefix="voice-browser-smoke-")
                fixture_log = Path(temporary.name) / "requests.jsonl"
                server = make_server(run_id, fixture_log, args.browser_mode)
                fixture_thread = threading.Thread(target=server.serve_forever, daemon=True)
                fixture_thread.start()
                fixtures.append((server, fixture_thread, temporary))
                fixture = (run_id, server.server_port, fixture_log)
                url = f"http://127.0.0.1:{server.server_port}/home?run_id={run_id}"
                phrase = (f'In the exact Voice Computer POC app, enter "Open {url} '
                          'and follow the Docs link." in the command field and press Return once. '
                          'Approve only Safari if the app shows a Computer Use approval. '
                          'Wait for the app result, then independently inspect the Safari '
                          'window and report its exact URL and visible heading. Do not navigate Safari '
                          'yourself or submit a second app command.')
            if index == 18:
                fixture_root = support / "TestFixtures" / uuid.uuid4().hex
                fixture_root.mkdir(parents=True, mode=0o700)
                finder_fixtures.append(fixture_root)
                report = fixture_root / "report.txt"
                report.write_text("Voice Computer Finder fixture\n")
                (fixture_root / "report-copy.txt").write_text("Decoy\n")
                phrase = (f'In the exact Voice Computer POC app, enter "Reveal the test report '
                          f'at {report} in Finder." in the command field and press Return once. '
                          'Approve only Finder if the app shows a Computer Use approval. Wait for '
                          'the app result, then independently inspect Finder and report the exact '
                          'selected file URL. Do not open or edit the file or submit a second app command.')
            space_before = space_state() if index in (7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18) else None
            expected_space = None
            if index in EXACT_APP_CASES:
                validate_exact_space_state(space_before, index)
            if index in (7, 8, 9, 10, 11, 12, 14, 15, 16):
                if space_before is None:
                    raise RuntimeError("Cannot read current desktop Space before case %s" % index)
                ordered = space_before["ordered"]
                position = ordered.index(space_before["current"])
                destination = position + (1 if index in (7, 9, 10, 11, 12, 15) else -1)
                if not 0 <= destination < len(ordered):
                    driver.command_index = index
                    driver.record("command_skipped", reason="No adjacent desktop Space",
                                  space_before=space_before)
                    print("%s. SKIP: no adjacent desktop Space for this direction" % index,
                          flush=True)
                    failed = True
                    if index in MCP_CASES:
                        break
                    continue
                expected_space = (space_before["current"] if index == 10
                                  else ordered[destination])
            if index in EXACT_APP_CASES:
                pids = running_app_pids(app_path)
                if len(pids) != 1:
                    raise RuntimeError("Exact app executable must have one live process; found %s" % len(pids))
                app_pid = pids[0]
                app_start = process_start_identity(app_pid)
                session_log = open_session_log(app_pid, APP_LOG_DIRECTORY)
                log_info = session_log.stat()
                log_identity = (log_info.st_dev, log_info.st_ino)
                log_offset = log_info.st_size
                prior_ids = {row.get("details", {}).get("command_id")
                             for row in app_log_rows(session_log, 0)}
                driver.record("exact_app_bound", app_path=str(app_path), pid=app_pid,
                              process_start=app_start, session_log=str(session_log))
                app_since = time.time()
            driver.command_index = index
            driver.last_result = ""
            driver.completed_turn = None
            driver.tool_failures = []
            driver.evidence_matches = []
            driver.tool_calls = 0
            driver.approvals = []
            driver.cua_binding_observed = False
            driver.browser_observations = []
            driver.browser_run_id = fixture[0] if fixture else None
            driver.finder_observations = []
            driver.record("command_started",
                          space_before=space_before, expected_space=expected_space)
            started = time.monotonic()
            instruction = INSTRUCTION
            if index == 13:
                instruction = (
                    "Use only mcp__cua_repl.js for UI. Bind with cua.getApp to this exact full "
                    "app path: " + str(app_path) + ". Verify its visible Command and Run controls. "
                    "Enter the quoted read-only inspection phrase and submit once using Return. "
                    "Make the Return call by itself, without getAXState in the same call. "
                    "Wait five seconds without UI calls so Mission Control can appear and the "
                    "app can finish its scan. Then read the app Diagnostic Log and report its "
                    "new command ID, Accessibility "
                    "trusted state, Dock found state, and Desktop controls. Do not use a bundle-ID "
                    "fallback, press a Desktop, change Spaces, or approve an acting tool. User request: "
                )
            elif index in MCP_CASES:
                instruction = (
                    "Use only mcp__cua_repl.js for UI. Bind with cua.getApp to this exact full app path: "
                    + str(app_path) + ". The driver has already checked the running executable; "
                    "do not inspect app metadata, object properties, or processes. If the first "
                    "tool response shows only Computer Use documentation, call app.getAXState(). "
                    "Find the visible command field in its Accessibility state, enter the exact "
                    "quoted command, and submit once using Return. "
                    "Only if a desktop_tool.switch_space approval is visibly shown with the requested "
                    "direction, click Allow once. Do not choose session access or approve through protocol. "
                    "Wait for the visible app result. Do not switch Spaces yourself. If Computer Use "
                    "fails, report the error and stop; do not use a shell fallback. User request: "
                )
            elif index == 17:
                instruction = (
                    "Use only mcp__cua_repl.js for UI. Bind with cua.getApp to this exact full "
                    "app path: " + str(app_path) + ". Enter the exact quoted command and submit "
                    "once with Return. Approve only Computer Use for Safari using "
                    "the visible Allow for session button; never approve a shell or other app. Wait "
                    "for the app command to finish. Only after it finishes, use cua.getApp "
                    "for com.apple.Safari and getAXState({disableDiffing:true}) to inspect "
                    "the Safari window. Do not create or navigate a tab yourself. After recording "
                    "the URL and heading, close only the new fixture tab and verify the previous "
                    "tab remains. Report the observed Safari URL and heading, plus the app result. "
                    "Never inspect or control the "
                    "Codex or ChatGPT host app; any approval is inside Voice Computer POC. "
                    "User request: "
                )
            elif index == 18:
                instruction = (
                    "Use only mcp__cua_repl.js for UI. Start with this sole Computer Use call: "
                    "var vcFinderApp = await cua.getApp('" + str(app_path) + "'); Use this "
                    "fresh variable rather than an app variable from a prior case. First click "
                    "Diagnostic Log then Show File "
                    "to open a Finder window; do not inspect the log contents. Return to Voice "
                    "Computer POC. Enter the exact quoted command and submit "
                    "once with Return. Approve only Computer Use for Finder via the visible "
                    "Allow for session button; never approve a shell or another app. Wait for the app "
                    "command to finish. Then use cua.getApp('com.apple.finder') and a full "
                    "getAXState to inspect the selected row and its exact file URL. Do not "
                    "select the item yourself. After recording evidence, click the fixture "
                    "Finder window's close button, then stop; never call getAXState on that "
                    "closed Finder binding. Never inspect or control the Codex or ChatGPT "
                    "host app; any approval is inside Voice Computer POC. User request: "
                )
            response = driver.wait_rpc(driver.rpc("turn/start", {
                "threadId": thread, "input": [{"type": "text", "text": instruction + phrase}],
            }))
            turn = driver.wait_turn()
            space_after = None
            if expected_space is not None:
                for _ in range(10):
                    space_after = space_state()
                    if space_after and space_after["current"] == expected_space:
                        break
                    time.sleep(0.5)
            elif index in (13, 17, 18):
                space_after = space_state()
            negative_result = re.search(
                r"couldn.t|cannot|can.t|declined|unverified|failed|unable to",
                driver.last_result, re.IGNORECASE,
            ) is not None
            verified = (space_after is not None and space_after["current"] == expected_space
                        if expected_space is not None else bool(driver.evidence_matches))
            if index == 9:
                verified = (verified and bool(driver.evidence_matches)
                            and "Switched one desktop Space to the right" in driver.last_result)
            if index == 10:
                verified = (verified and bool(driver.evidence_matches)
                            and "returned left to the original Space" in driver.last_result)
            if index == 14:
                verified = (verified and bool(driver.evidence_matches)
                            and "Switched one desktop Space to the left" in driver.last_result)
            exact_receipt = None
            if index in EXACT_APP_CASES:
                try:
                    if not driver.cua_binding_observed:
                        raise ValueError("No observed CUA getApp call with exact app path")
                    if running_app_pids(app_path) != [app_pid] or process_start_identity(app_pid) != app_start:
                        raise ValueError("Exact app PID/start changed during CUA command")
                    if open_session_log(app_pid, APP_LOG_DIRECTORY) != session_log:
                        raise ValueError("PID-owned session log changed during CUA command")
                    current_log_info = session_log.stat()
                    if (current_log_info.st_dev, current_log_info.st_ino) != log_identity:
                        raise ValueError("PID-owned session log inode changed")
                    rows = app_log_rows(session_log, app_since, log_offset)
                    after_id = space_after["current"] if space_after else None
                    if index == 13:
                        exact_receipt = verify_read_only_receipt(
                            rows, space_before["current"], after_id, prior_ids)
                        driver.record("read_only_receipt_verified", **exact_receipt)
                    elif index == 17:
                        run_id, port, fixture_log = fixture
                        fixture_rows = [json.loads(line) for line in fixture_log.read_text().splitlines()]
                        exact_receipt = verify_browser_receipt(
                            rows, run_id, port, fixture_rows, driver.browser_observations,
                            space_before["current"], after_id, prior_ids,
                            mode=args.browser_mode)
                        driver.record("browser_receipt_verified", **exact_receipt)
                    elif index == 18:
                        exact_receipt = verify_finder_receipt(
                            rows, report, driver.finder_observations,
                            space_before["current"], after_id, prior_ids)
                        driver.record("finder_receipt_verified", **exact_receipt)
                    else:
                        exact_receipt = verify_mcp_receipt(
                            rows, mcp_case_phrase(index), MCP_CASES[index],
                            space_before["current"], expected_space, after_id, prior_ids)
                        driver.record("mcp_receipt_verified", **exact_receipt)
                except (OSError, ValueError) as error:
                    driver.record("exact_app_receipt_rejected", reason=str(error))
                    verified = False
                else:
                    verified = exact_receipt is not None and (verified or index in (13, 17, 18))
            recovered_stale_ui = (
                index == 13 and exact_receipt is not None
                and driver.tool_failures == ["stale_ui_state"])
            if recovered_stale_ui:
                driver.record("stale_ui_state_recovered")
            success = (turn.get("status") == "completed" and verified
                       and (not driver.tool_failures or recovered_stale_ui)
                       and all(a["allowed"] for a in driver.approvals)
                       and (expected_space is not None or index in (17, 18) or not negative_result))
            driver.record("command_finished", success=success,
                          elapsed_ms=round((time.monotonic() - started) * 1000),
                          tool_failures=driver.tool_failures, approvals=driver.approvals,
                          evidence_matches=driver.evidence_matches,
                          space_before=space_before, space_after=space_after,
                          expected_space=expected_space,
                          turn_id=(response.get("turn") or {}).get("id"))
            print("%s. %s: %s" % (index, "PASS" if success else "FAIL", phrase), flush=True)
            print("   result present: %s" % bool(driver.last_result), flush=True)
            failed = failed or not success
            if not success and (args.suite or index in MCP_CASES or index == 13):
                break
        if args.suite and not failed and args.codex_thread_id:
            response = driver.wait_rpc(driver.rpc("thread/read", {
                "threadId": args.codex_thread_id, "includeTurns": False,
            }))
            task = response.get("thread") or {}
            if task.get("id") != args.codex_thread_id:
                raise RuntimeError("Codex status probe returned a different task ID")
            protocol_status = (task.get("status") or {}).get("type")
            interpretation = ("unavailable_cross_process" if protocol_status == "notLoaded"
                              else "observed_in_driver_process")
            driver.record("codex_status_feasibility", thread_id=args.codex_thread_id,
                          protocol_status=protocol_status, interpretation=interpretation)
            print("Codex status: %s (%s)" % (interpretation, protocol_status), flush=True)
        elif args.suite and not failed:
            driver.record("codex_status_skipped", reason="no_exact_task_id")
    except Exception as error:
        failed = True
        driver.record("driver_error", error_type=type(error).__name__)
        print("SMOKE ERROR: %s" % error, file=sys.stderr)
    except KeyboardInterrupt:
        failed = True
        driver.record("driver_interrupted")
        print("Smoke test interrupted", file=sys.stderr)
    finally:
        for server, thread, temporary in fixtures:
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)
            temporary.cleanup()
        if fixtures:
            driver.record("fixtures_cleaned", count=len(fixtures))
        for directory in finder_fixtures:
            shutil.rmtree(directory)
        if finder_fixtures:
            driver.record("finder_fixtures_cleaned", count=len(finder_fixtures))
        driver.close()
        print("Log: %s" % args.log, flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
