#!/usr/bin/env python3
"""Run bounded, reversible Computer Use commands against local codex app-server.

This tests the same app-server protocol as the Mac app without requiring remote
screen-control credentials. It approves only Computer Use requests for the
app named by the selected case and writes a local JSONL diagnostic receipt.
"""

import argparse
import ctypes
import hashlib
import json
import os
import platform
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
    None,  # Case 19 submits one composed Browser -> Finder command.
    None,  # Case 20 reads the desktop state through MCP.
    None,  # Case 21 preserves a test-owned Safari sentinel tab.
    None,  # Case 22 selects a report in an already-open Finder window.
    None,  # Case 23 edits and reopens a run-owned TextEdit note.
    None,  # Case 24 creates and reopens a run-owned TextEdit note.
]
CASE_APP = ["Safari", "Calculator", "TextEdit", "Finder", "Voice Computer POC", "Voice Computer POC", "Finder", "Finder", "Voice Computer POC", "Voice Computer POC", "Voice Computer POC", "Voice Computer POC", "Voice Computer POC", "Voice Computer POC", "Voice Computer POC", "Voice Computer POC", "Voice Computer POC", "Voice Computer POC", "Voice Computer POC", "Voice Computer POC", "Voice Computer POC", "Voice Computer POC", "Voice Computer POC"]
MCP_CASES = {15: "right", 16: "left"}
CASE_APP.append("Voice Computer POC")  # Case 24 creates a TextEdit fixture note.
EXACT_APP_CASES = {13, 17, 18, 19, 20, 21, 22, 23, 24, *MCP_CASES}
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
    None,
    None,
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


def frontmost_bundle_id():
    """Observe macOS foreground app outside Voice Computer's process."""
    try:
        result = subprocess.run(
            ["swift", "-e", "import AppKit; print(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? \"\")"],
            capture_output=True, text=True, check=True, timeout=15)
        return result.stdout.strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


def safari_window_ids():
    """Independently observe Safari window UUIDs without reading page content."""
    helper = Path(__file__).with_name("observe_safari_windows.swift")
    result = subprocess.run(["swift", str(helper)], capture_output=True,
                            text=True, check=True, timeout=20)
    ids = json.loads(result.stdout)["window_ids"]
    if not isinstance(ids, list) or len(ids) != len(set(ids)) or any(
            not isinstance(item, str) or not re.fullmatch(
                r"[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}", item)
            for item in ids):
        raise ValueError("Safari window observer returned invalid IDs")
    return set(ids)


def finder_window_inventory(title=None):
    """Observe Finder's named window IDs without emitting unrelated titles."""
    helper = Path(__file__).with_name("observe_finder_windows.swift")
    command = ["swift", str(helper)] + ([title] if title else [])
    result = subprocess.run(command, capture_output=True, text=True,
                            check=True, timeout=20)
    inventory = json.loads(result.stdout)
    ids = inventory["window_ids"]
    matches = inventory["matching_window_ids"]
    if not isinstance(ids, list) or not isinstance(matches, list) \
            or len(ids) != len(set(ids)) or any(type(item) is not int or item <= 0
                                              for item in ids + matches) \
            or not set(matches).issubset(ids):
        raise ValueError("Finder window observer returned invalid IDs")
    return {"window_ids": set(ids), "matching_window_ids": set(matches)}


def textedit_window_inventory(title=None):
    """Observe TextEdit window IDs without publishing unrelated titles."""
    helper = Path(__file__).with_name("observe_textedit_windows.swift")
    command = ["swift", str(helper)] + ([title] if title else [])
    result = subprocess.run(command, capture_output=True, text=True,
                            check=True, timeout=20)
    inventory = json.loads(result.stdout)
    ids = inventory["window_ids"]
    matches = inventory["matching_window_ids"]
    if not isinstance(ids, list) or not isinstance(matches, list) \
            or len(ids) != len(set(ids)) or any(type(item) is not int or item <= 0
                                              for item in ids + matches) \
            or not set(matches).issubset(ids):
        raise ValueError("TextEdit window observer returned invalid IDs")
    return {"window_ids": set(ids), "matching_window_ids": set(matches)}


class TextEditWindowSampler:
    """Record run-time TextEdit window transitions independently of CUA events."""

    def __init__(self):
        helper = Path(__file__).with_name("observe_textedit_windows.swift")
        self.process = subprocess.Popen(
            ["swift", str(helper), "note.txt", "--watch"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
        self.transitions = []
        self.ready = threading.Event()
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()
        if not self.ready.wait(timeout=10):
            self.stop()
            raise RuntimeError("TextEdit window sampler did not start")

    def _read(self):
        for line in self.process.stdout:
            try:
                row = json.loads(line)
                ids = row["window_ids"]
                matches = row["matching_window_ids"]
                if not isinstance(ids, list) or not isinstance(matches, list) \
                        or any(type(value) is not int or value <= 0
                               for value in ids + matches) \
                        or not set(matches).issubset(ids):
                    raise ValueError("invalid TextEdit transition")
                self.transitions.append({"window_ids": ids,
                                         "matching_window_ids": matches})
            except (KeyError, TypeError, ValueError, json.JSONDecodeError):
                self.transitions.append({"invalid": True})
            finally:
                self.ready.set()

    def stop(self):
        if self.process.poll() is None:
            self.process.terminate()
        self.process.wait(timeout=5)
        self.reader.join(timeout=2)
        if not self.transitions or any(row.get("invalid") for row in self.transitions):
            raise ValueError("TextEdit window sampler returned invalid transitions")
        return list(self.transitions)


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


def exact_build_identity(app_path):
    """Bind a receipt to the source revision, app binary, and bundled helper."""
    root = Path(__file__).resolve().parents[1]
    revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=root,
                              capture_output=True, text=True, check=True, timeout=5).stdout.strip()
    changes = subprocess.run(["git", "status", "--porcelain"], cwd=root,
                             capture_output=True, text=True, check=True, timeout=5).stdout
    binary = app_path / "Contents/MacOS/VoiceComputerPOC"
    helper = app_path / "Contents/Helpers/DesktopToolServer"
    stamp = Path(str(helper) + ".sha256")
    if not helper.is_file() or helper.is_symlink() or not os.access(helper, os.X_OK) \
            or not stamp.is_file() or stamp.is_symlink():
        raise ValueError("Bundled desktop helper or checksum is unavailable")
    helper_hash = hashlib.sha256(helper.read_bytes()).hexdigest()
    if stamp.read_text().strip() != helper_hash:
        raise ValueError("Bundled desktop helper checksum does not match")
    return {"source_sha": revision, "source_clean": not changes,
            "macos_version": platform.mac_ver()[0],
            "app_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
            "helper_sha256": helper_hash}


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
    form = mode == "form-submit"
    if len(routes) != 1 or routes[0].get("route") != "browser" \
            or routes[0].get("action") != ("submit_form" if form else "follow_docs") \
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
    expected_verified = mode in ("normal", "form-submit")
    expected_status = "verified" if expected_verified else "unverified"
    ax, app_turns = events("fixture_ax_verification"), events("turn_completed")
    if len(ax) != 1 or ax[0].get("target") != ("browser_form" if form else "browser") \
            or ax[0].get("verified") != str(expected_verified).lower() \
            or ax[0].get("reason") != ("exact_url_and_heading" if expected_verified
                                            else "url_or_heading_mismatch") \
            or len(app_turns) != 1 \
            or app_turns[0].get("verification") != expected_status \
            or finishes[0].get("verification") != expected_status:
        raise ValueError("Browser app-owned Accessibility verification mismatch")
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
        "form-submit": ["/docs", "/submitted"],
    }.get(mode)
    if expected_paths is None:
        raise ValueError("Unsupported Browser fixture mode")
    if [(row.get("method"), row.get("path"), row.get("run_id"), row.get("query"))
            for row in fixture_rows] != [
                ("GET", path, [run_id], [f"test-{run_id}"] if path == "/submitted" else None)
                for path in expected_paths]:
        raise ValueError("Fixture request sequence did not match Browser scenario")
    final_path = expected_paths[-1]
    expected_url = f"http://127.0.0.1:{port}{final_path}?run_id={run_id}"
    if form:
        expected_url += f"&query=test-{run_id}"
    heading = (f"Voice Computer Submitted {run_id} test-{run_id}" if form else
               f"Voice Computer Docs {run_id}" if mode == "normal" else
               f"Voice Computer Home {run_id}" if mode == "missing-link" else
               "Fixture page not found")
    if not any(expected_url.removeprefix("http://") in observation and heading in observation
               and "heading" in observation for observation in observations):
        raise ValueError("Independent rendered Safari URL and heading missing")
    assert_log_privacy(rows)
    return {"command_id": command_id, "scenario": mode, "url": expected_url,
            "heading": heading, "approval_state": "prompted" if approvals else "no_new_prompt",
            "before": before, "after": after}


def safari_snapshot(text):
    """Extract a bounded identity from one full native Safari Accessibility state."""
    window = re.search(
        r'(?m)^0 standard window [^\n]*ID: SafariWindow\?[^\n]*UUID='
        r'([0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})', text)
    if not window or "App: Safari" not in text:
        return None
    return {"window_id": window.group(1).upper(), "state": text}


def verify_safari_context_receipt(rows, run_id, port, fixture_rows,
                                  observations, windows_before, windows_after,
                                  space_before, space_after, prior_command_ids=(),
                                  mode="normal", sentinel_count=1):
    """Prove a run-owned Safari window kept its sentinel through tab cleanup."""
    sentinel_request = {"method": "GET", "path": "/sentinel", "run_id": [run_id]}
    if sentinel_count not in (1, 2) or fixture_rows[:sentinel_count] != [sentinel_request] * sentinel_count:
        raise ValueError("Safari sentinel request missing or duplicated")
    browser = verify_browser_receipt(
        rows, run_id, port, fixture_rows[sentinel_count:], observations,
        space_before, space_after, prior_command_ids, mode=mode)
    if windows_after != windows_before:
        raise ValueError("Safari window inventory did not return to baseline")
    snapshots = [snapshot for text in observations
                 if (snapshot := safari_snapshot(text)) is not None]
    sentinel_url = f"127.0.0.1:{port}/sentinel?run_id={run_id}"
    final_path, final_heading = {
        "normal": ("docs", f"Voice Computer Docs {run_id}"),
        "missing-link": ("home", f"Voice Computer Home {run_id}"),
        "home-404": ("home", "Fixture page not found"),
        "redirect": ("error", "Fixture page not found"),
    }[mode]
    final_url = f"127.0.0.1:{port}/{final_path}?run_id={run_id}"
    sentinel_heading = f"heading Voice Computer Sentinel {run_id}"
    acted_heading = f"heading {final_heading}"
    for before_index, before in enumerate(snapshots):
        context_id = before["window_id"]
        if context_id in windows_before or sentinel_url not in before["state"] \
                or sentinel_heading not in before["state"] \
                or final_url in before["state"]:
            continue
        for after_index in range(before_index + 1, len(snapshots)):
            acted = snapshots[after_index]
            if acted["window_id"] != context_id or final_url not in acted["state"] \
                    or acted_heading not in acted["state"] \
                    or f"tab Sentinel {run_id}" not in acted["state"] \
                    or "Description: Tab bar, 2 tabs" not in acted["state"]:
                continue
            if any(cleaned["window_id"] == context_id
                   and sentinel_url in cleaned["state"]
                   and sentinel_heading in cleaned["state"]
                   and final_url not in cleaned["state"]
                   and "Description: Tab bar, 2 tabs" not in cleaned["state"]
                   for cleaned in snapshots[after_index + 1:]):
                decoy_id = None
                if sentinel_count == 2:
                    candidates = {snapshot["window_id"] for snapshot in snapshots[:before_index]
                                  if snapshot["window_id"] not in windows_before
                                  and snapshot["window_id"] != context_id
                                  and sentinel_url in snapshot["state"]
                                  and sentinel_heading in snapshot["state"]}
                    preserved = {snapshot["window_id"] for snapshot in snapshots[after_index + 1:]
                                 if snapshot["window_id"] in candidates
                                 and sentinel_url in snapshot["state"]
                                 and sentinel_heading in snapshot["state"]
                                 and final_url not in snapshot["state"]
                                 and "Description: Tab bar, 2 tabs" not in snapshot["state"]}
                    if len(preserved) != 1:
                        continue
                    decoy_id = next(iter(preserved))
                return {**browser, "context_window_id": context_id,
                        "decoy_window_id": decoy_id,
                        "sentinel_preserved": True, "window_cleanup_verified": True}
    raise ValueError("Safari sentinel, acted tab, and cleanup states did not correlate")


def verify_safari_context_interruption_receipt(rows, run_id, port, fixture_rows,
                                               observations, windows_before, windows_after,
                                               space_before, space_after,
                                               prior_command_ids=()):
    """A stopped Browser command must preserve its owned Safari sentinel."""
    sentinel_request = {"method": "GET", "path": "/sentinel", "run_id": [run_id]}
    if not fixture_rows or fixture_rows[0] != sentinel_request:
        raise ValueError("Safari sentinel request missing or duplicated")
    browser = verify_browser_interruption_receipt(
        rows, run_id, fixture_rows[1:], space_before, space_after, prior_command_ids)
    if windows_after != windows_before:
        raise ValueError("Stopped Safari window inventory did not return to baseline")
    snapshots = [snapshot for text in observations
                 if (snapshot := safari_snapshot(text)) is not None]
    sentinel_url = f"127.0.0.1:{port}/sentinel?run_id={run_id}"
    sentinel_heading = f"heading Voice Computer Sentinel {run_id}"
    home_url = f"127.0.0.1:{port}/home?run_id={run_id}"
    for before_index, prepared in enumerate(snapshots):
        context_id = prepared["window_id"]
        if context_id in windows_before or sentinel_url not in prepared["state"] \
                or sentinel_heading not in prepared["state"]:
            continue
        for acted_index in range(before_index + 1, len(snapshots)):
            acted = snapshots[acted_index]
            if acted["window_id"] != context_id or home_url not in acted["state"] \
                    or "Description: Tab bar, 2 tabs" not in acted["state"]:
                continue
            if any(cleaned["window_id"] == context_id
                   and sentinel_url in cleaned["state"]
                   and sentinel_heading in cleaned["state"]
                   and home_url not in cleaned["state"]
                   and "Description: Tab bar, 2 tabs" not in cleaned["state"]
                   for cleaned in snapshots[acted_index + 1:]):
                return {**browser, "context_window_id": context_id,
                        "sentinel_preserved": True, "window_cleanup_verified": True}
    raise ValueError("Stopped Safari tab and sentinel cleanup did not correlate")


def verify_injected_cua_failure_receipt(rows, run_id, target, before, after,
                                        prior_command_ids=()):
    """Correlate a synthetic Debug CUA failure with app-owned non-success."""
    starts = [row for row in rows if row.get("event") == "command_started"
              and row.get("details", {}).get("user_action") == "run"]
    if len(starts) != 1:
        raise ValueError("Injected CUA test lacks one app command")
    command_id = starts[0].get("details", {}).get("command_id")
    if not command_id or command_id in prior_command_ids:
        raise ValueError("Injected CUA test command ID missing or stale")
    command_rows = [row for row in rows if row.get("details", {}).get("command_id") == command_id]
    def events(name):
        return [row.get("details", {}) for row in command_rows if row.get("event") == name]
    routes, turns = events("router_decided"), events("turn_requested")
    started, completed = events("tool_started"), events("tool_completed")
    injection, ax = events("test_cua_failure_injected"), events("fixture_ax_verification")
    finished, turn_finished = events("command_finished"), events("turn_completed")
    if len(routes) != 1 or routes[0].get("route") != target \
            or len(turns) != 1 or turns[0].get("route") != target:
        raise ValueError("Injected CUA test used unexpected route or acting turn")
    if len(injection) != 1 or injection[0].get("target") != target \
            or injection[0].get("run_id") != run_id \
            or injection[0].get("source") != "synthetic_debug_event":
        raise ValueError("Synthetic CUA injection event missing or mismatched")
    item_id = injection[0].get("item_id")
    if not item_id or not any(entry.get("item_id") == item_id
                              and entry.get("server") == "cua_repl"
                              and entry.get("turn_matches") == "true" for entry in started):
        raise ValueError("Injected CUA item did not start in the acting turn")
    if not any(entry.get("item_id") == item_id and entry.get("server") == "cua_repl"
               and entry.get("status") == "failed" for entry in completed):
        raise ValueError("Injected CUA item did not reach the failure classifier")
    if len(ax) != 1 or ax[0].get("target") != target \
            or ax[0].get("verified") != "false" \
            or ax[0].get("reason") != "tool_failure":
        raise ValueError("App did not reject the failed CUA item")
    if len(finished) != 1 or finished[0].get("verification") != "tool_failed" \
            or len(turn_finished) != 1 \
            or turn_finished[0].get("verification") != "tool_failed":
        raise ValueError("Injected CUA failure produced a verified app result")
    if any(row.get("event") in ("native_space_requested", "mcp_action_requested",
                                    "space_changed", "finder_step_queued")
           for row in command_rows) or before is None or after != before:
        raise ValueError("Injected CUA failure changed Space or started a later step")
    assert_log_privacy(rows)
    return {"command_id": command_id, "target": target, "item_id": item_id,
            "source": "synthetic_debug_event", "verification": "tool_failed",
            "before": before, "after": after}


def verify_injected_safari_context(run_id, port, fixture_rows, observations,
                                   windows_before, windows_after):
    sentinel = {"method": "GET", "path": "/sentinel", "run_id": [run_id]}
    if not fixture_rows or fixture_rows[0] != sentinel \
            or any(row.get("path") not in ("/sentinel", "/home", "/docs")
                   or row.get("run_id") != [run_id] for row in fixture_rows):
        raise ValueError("Injected Safari test made unexpected fixture requests")
    if windows_after != windows_before:
        raise ValueError("Injected Safari test did not restore window inventory")
    snapshots = [snapshot for text in observations
                 if (snapshot := safari_snapshot(text)) is not None]
    sentinel_url = f"127.0.0.1:{port}/sentinel?run_id={run_id}"
    for index, prepared in enumerate(snapshots):
        window_id = prepared["window_id"]
        if window_id in windows_before or sentinel_url not in prepared["state"]:
            continue
        if any(later["window_id"] == window_id and sentinel_url in later["state"]
               and "Description: Tab bar, 2 tabs" not in later["state"]
               for later in snapshots[index + 1:]):
            return window_id
    raise ValueError("Injected Safari test did not preserve its sentinel")


def verify_injected_finder_context(report, observations,
                                   windows_before, windows_after):
    if windows_after != windows_before:
        raise ValueError("Injected Finder test did not restore window inventory")
    sentinel_url = report.with_name("sentinel.txt").as_uri()
    for index, prepared in enumerate(observations):
        window_id = prepared["window_id"]
        if window_id is None or window_id in windows_before \
                or sentinel_url not in prepared["state"]:
            continue
        if any(later["window_id"] == window_id and sentinel_url in later["state"]
               for later in observations[index + 1:]):
            return window_id
    raise ValueError("Injected Finder test did not preserve its prepared window")


def verify_browser_interruption_receipt(rows, run_id, fixture_rows, before, after,
                                        prior_command_ids=()):
    """Require a Stop during the held Home response and no subsequent Docs request."""
    starts = [row for row in rows if row.get("event") == "command_started"
              and row.get("details", {}).get("user_action") == "run"]
    if len(starts) != 1:
        raise ValueError("Missing or ambiguous Browser command start")
    command_id = starts[0].get("details", {}).get("command_id")
    if not command_id or command_id in prior_command_ids:
        raise ValueError("Browser command ID missing or stale")
    command_rows = [row for row in rows
                    if row.get("details", {}).get("command_id") == command_id]
    def indices(name):
        return [i for i, row in enumerate(command_rows) if row.get("event") == name]
    def details(name):
        return [command_rows[i].get("details", {}) for i in indices(name)]
    route, turn, stop, ax, completed, finished = (
        details(name) for name in ("router_decided", "turn_requested", "stop_requested",
                                   "fixture_ax_verification", "turn_completed", "command_finished"))
    if len(route) != 1 or route[0].get("route") != "browser" \
            or route[0].get("action") != "follow_docs" \
            or route[0].get("target") != "loopback_fixture" or len(turn) != 1 \
            or turn[0].get("route") != "browser":
        raise ValueError("Interrupted Browser route or acting turn missing")
    tools = details("tool_started")
    if not tools or any(tool.get("server") != "cua_repl" for tool in tools):
        raise ValueError("Interrupted Browser action did not use only Computer Use")
    if len(stop) != 1 or len(ax) != 1 or len(completed) != 1 or len(finished) != 1:
        raise ValueError("Interrupted Browser lifecycle is incomplete")
    if not indices("turn_requested")[0] < indices("stop_requested")[0] \
            < indices("turn_completed")[0] < indices("command_finished")[0]:
        raise ValueError("Browser Stop did not precede turn completion")
    if ax[0].get("target") != "browser" or ax[0].get("verified") != "false" \
            or ax[0].get("reason") != "turn_incomplete" \
            or completed[0].get("status") == "completed" \
            or completed[0].get("verification") != "unverified" \
            or finished[0].get("verification") != "unverified":
        raise ValueError("Interrupted Browser command reported a successful result")
    if [(row.get("method"), row.get("path"), row.get("run_id"))
            for row in fixture_rows] != [("GET", "/home", [run_id])]:
        raise ValueError("Browser requested Docs or an unexpected fixture path after Stop")
    if any(row.get("event") in ("native_space_requested", "mcp_action_requested",
                                    "space_changed") for row in command_rows):
        raise ValueError("Interrupted Browser command invoked a desktop action")
    if before is None or after != before:
        raise ValueError("Interrupted Browser command changed desktop Space")
    assert_log_privacy(rows)
    return {"command_id": command_id, "scenario": "stop-before-docs",
            "home_requests": 1, "docs_requests": 0, "before": before, "after": after}


def stop_browser_when_home(requested, release, app_pid, session_log, log_offset,
                           started_at, outcome):
    """Press the exact app's Stop button while the fixture holds Home's response."""
    try:
        if not requested.wait(timeout=80):
            raise TimeoutError("Safari did not request the held Home page")
        helper = Path(__file__).with_name("press_voice_stop.swift")
        pressed = subprocess.run(["swift", str(helper), str(app_pid)],
                                 capture_output=True, text=True, timeout=20, check=False)
        if pressed.returncode != 0 or pressed.stdout.strip() != "pressed_stop":
            raise RuntimeError("Exact-app Stop button could not be pressed")
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if any(row.get("event") == "stop_requested" for row in
                   app_log_rows(session_log, started_at, log_offset)):
                outcome["pressed"] = True
                return
            time.sleep(0.05)
        raise TimeoutError("Stop was pressed but the app did not record it")
    except (OSError, RuntimeError, TimeoutError, subprocess.SubprocessError) as error:
        outcome["error"] = str(error)
    finally:
        release.set()


def stop_textedit_before_approval(app_pid, session_log, log_offset, started_at, outcome):
    """Press Stop while exact-app TextEdit Computer Use still awaits approval."""
    try:
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            rows = app_log_rows(session_log, started_at, log_offset)
            if any(row.get("event") == "approval_requested"
                   and row.get("details", {}).get("server_name") == "cua_repl"
                   for row in rows):
                break
            time.sleep(0.05)
        else:
            raise TimeoutError("TextEdit CUA approval did not appear")
        helper = Path(__file__).with_name("press_voice_stop.swift")
        pressed = subprocess.run(["swift", str(helper), str(app_pid)],
                                 capture_output=True, text=True, timeout=20, check=False)
        if pressed.returncode != 0 or pressed.stdout.strip() != "pressed_stop":
            raise RuntimeError("Exact-app Stop button could not be pressed")
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if any(row.get("event") == "stop_requested" for row in
                   app_log_rows(session_log, started_at, log_offset)):
                outcome["pressed"] = True
                return
            time.sleep(0.05)
        raise TimeoutError("TextEdit Stop was pressed but not recorded")
    except (OSError, RuntimeError, TimeoutError, subprocess.SubprocessError) as error:
        outcome["error"] = str(error)


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
    ax, app_turns = events("fixture_ax_verification"), events("turn_completed")
    if len(ax) != 1 or ax[0].get("target") != "finder" \
            or ax[0].get("verified") != "true" \
            or ax[0].get("reason") != "exact_selected_file" \
            or len(app_turns) != 1 \
            or app_turns[0].get("verification") != "verified" \
            or finishes[0].get("verification") != "verified":
        raise ValueError("Finder app-owned Accessibility verification mismatch")
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


def verify_finder_context_receipt(rows, report, observations,
                                  windows_before, windows_after,
                                  space_before, space_after, prior_command_ids=(),
                                  decoy_report=None):
    """Require report selection in the same prepared Finder window."""
    finder = verify_finder_receipt(
        rows, report, [entry["state"] for entry in observations],
        space_before, space_after, prior_command_ids)
    if windows_after != windows_before:
        raise ValueError("Finder window inventory did not return to baseline")
    selected = re.compile(r"^\s*\d+ row \(selected\)(?:(?!^\s*\d+ row ).)*?URL: (file://\S+)",
                          re.MULTILINE | re.DOTALL)
    for before_index, prepared in enumerate(observations):
        window_id = prepared["window_id"]
        if window_id is None or window_id in windows_before \
                or report.as_uri() in selected.findall(prepared["state"]) \
                or report.with_name("sentinel.txt").as_uri() not in prepared["state"]:
            continue
        for acted in observations[before_index + 1:]:
            if acted["window_id"] == window_id \
                    and set(selected.findall(acted["state"])) == {report.as_uri()}:
                decoy_window_id = None
                if decoy_report is not None:
                    decoy_sentinel = decoy_report.with_name("sentinel.txt").as_uri()
                    candidates = {entry["window_id"] for entry in observations[:before_index]
                                  if entry["window_id"] is not None
                                  and entry["window_id"] not in windows_before
                                  and entry["window_id"] != window_id
                                  and decoy_sentinel in entry["state"]
                                  and not selected.findall(entry["state"])}
                    preserved = {entry["window_id"] for entry in observations[before_index + 1:]
                                 if entry["window_id"] in candidates
                                 and decoy_sentinel in entry["state"]
                                 and not selected.findall(entry["state"])
                                 and report.as_uri() not in entry["state"]}
                    if len(preserved) != 1:
                        continue
                    decoy_window_id = next(iter(preserved))
                return {**finder, "context_window_id": window_id,
                        "decoy_window_id": decoy_window_id,
                        "existing_window_reused": True,
                        "window_cleanup_verified": True}
    raise ValueError("Finder prepared window and selected report did not correlate")


def verify_finder_context_rejection_receipt(rows, report, observations,
                                            windows_before, windows_after,
                                            space_before, space_after,
                                            prior_command_ids=(), mode="missing-file"):
    """Rejected file requests must leave a prepared Finder window untouched."""
    finder = verify_finder_rejection_receipt(
        rows, report, space_before, space_after, prior_command_ids, mode=mode)
    if windows_after != windows_before:
        raise ValueError("Finder window inventory did not return to baseline")
    selected = re.compile(r"^\s*\d+ row \(selected\)(?:(?!^\s*\d+ row ).)*?URL: (file://\S+)",
                          re.MULTILINE | re.DOTALL)
    sentinel_url = report.with_name("sentinel.txt").as_uri()
    for before_index, prepared in enumerate(observations):
        window_id = prepared["window_id"]
        if window_id is None or window_id in windows_before \
                or sentinel_url not in prepared["state"]:
            continue
        for after in observations[before_index + 1:]:
            if after["window_id"] == window_id \
                    and sentinel_url in after["state"] \
                    and selected.findall(after["state"]) == selected.findall(prepared["state"]):
                return {**finder, "context_window_id": window_id,
                        "window_unchanged": True, "window_cleanup_verified": True}
    raise ValueError("Rejected Finder request changed its prepared window")


def verify_textedit_receipt(rows, note, observations, windows_before,
                            windows_after, space_before, space_after,
                            prior_command_ids=(), context_windows=0,
                            verifier_failure=False, window_transitions=None,
                            created=False):
    """Require exact app proof, saved bytes, and an independently reopened note."""
    starts = [row for row in rows if row.get("event") == "command_started"
              and row.get("details", {}).get("user_action") == "run"]
    if len(starts) != 1:
        raise ValueError("TextEdit command start missing or ambiguous")
    command_id = starts[0].get("details", {}).get("command_id")
    if not command_id or command_id in prior_command_ids:
        raise ValueError("TextEdit command ID missing or stale")
    command_rows = [row for row in rows if row.get("details", {}).get("command_id") == command_id]
    def events(name):
        return [row.get("details", {}) for row in command_rows if row.get("event") == name]
    routes, turns = events("router_decided"), events("turn_requested")
    tools, completed = events("tool_started"), events("tool_completed")
    ax, app_turns, finishes = (events("fixture_ax_verification"),
                                events("turn_completed"), events("command_finished"))
    if len(routes) != 1 or routes[0].get("route") != "textedit" \
            or routes[0].get("action") != ("create_note" if created else "save_note") \
            or routes[0].get("target") != ("fixture_new_note" if created else "fixture_note") \
            or len(turns) != 1 or turns[0].get("route") != "textedit":
        raise ValueError("TextEdit route or acting turn mismatch")
    if not tools or any(tool.get("server") != "cua_repl"
                        or tool.get("turn_matches") != "true" for tool in tools):
        raise ValueError("TextEdit acting turn lacked correlated Computer Use")
    started_ids = {tool.get("item_id") for tool in tools}
    completed_ids = {tool.get("item_id") for tool in completed
                     if tool.get("server") == "cua_repl" and tool.get("status") == "completed"
                     and tool.get("result_is_error") == "false"}
    if None in started_ids or started_ids != completed_ids:
        raise ValueError("TextEdit CUA item did not complete cleanly")
    expected_verification = "unverified" if verifier_failure else "verified"
    expected_reason = ("synthetic_accessibility_failure" if verifier_failure
                       else "exact_note_file_and_text")
    if len(ax) != 1 or ax[0].get("target") != "textedit" \
            or ax[0].get("verified") != str(not verifier_failure).lower() \
            or ax[0].get("reason") != expected_reason \
            or len(app_turns) != 1 \
            or app_turns[0].get("verification") != expected_verification \
            or len(finishes) != 1 \
            or finishes[0].get("verification") != expected_verification:
        raise ValueError("TextEdit app-owned saved-note verification mismatch")
    if windows_after != windows_before or space_before is None or space_after != space_before:
        raise ValueError("TextEdit windows or desktop Space were not restored")
    run_id = note.parent.name
    expected = f"Voice Computer saved {run_id}"
    if note.is_symlink() or not note.is_file() or note.read_bytes() != expected.encode():
        raise ValueError("TextEdit saved file bytes mismatch")
    decoy = note.parent / "note-copy.txt"
    if not decoy.is_file() or decoy.read_bytes() != b"Decoy note":
        raise ValueError("TextEdit decoy file changed")
    if any(row.get("event") in ("native_space_requested", "mcp_action_requested",
                                    "space_changed") for row in command_rows):
        raise ValueError("TextEdit command invoked unrelated desktop action")
    target_uri = note.as_uri()
    appearances = [(index, entry) for index, entry in enumerate(observations)
                   if target_uri in entry["state"] and expected in entry["state"]]
    if len(appearances) < 2 or not any(
            entry["window_id"] is None
            for entry in observations[appearances[0][0] + 1:appearances[-1][0]]):
        raise ValueError("TextEdit note was not visibly closed and reopened")
    if window_transitions is not None:
        samples = [row["matching_window_ids"] for row in window_transitions]
        identity = None
        for first_index, first in enumerate(samples):
            if len(first) != 1 or first[0] in windows_before:
                continue
            for closed_index in range(first_index + 1, len(samples)):
                if samples[closed_index]:
                    continue
                for reopened in samples[closed_index + 1:]:
                    if len(reopened) == 1 and reopened[0] != first[0] \
                            and reopened[0] not in windows_before:
                        identity = (first[0], reopened[0])
                        break
                if identity:
                    break
            if identity:
                break
        if identity is None:
            raise ValueError("TextEdit window transitions did not prove reopen")
        first_window_id, reopened_window_id = identity
        if appearances[0][1]["window_id"] not in (None, first_window_id) \
                or appearances[-1][1]["window_id"] not in (None, reopened_window_id):
            raise ValueError("TextEdit Accessibility and CG window identities disagree")
    else:
        first_window_id = appearances[0][1]["window_id"]
        reopened_window_id = appearances[-1][1]["window_id"]
        if first_window_id is None or reopened_window_id is None \
                or first_window_id == reopened_window_id \
                or first_window_id in windows_before \
                or reopened_window_id in windows_before:
            raise ValueError("TextEdit reopened document lacked a new live window")
    if context_windows:
        prepared = [(index, entry) for index, entry in enumerate(observations)
                    if target_uri in entry["state"]
                    and f"Voice Computer draft {run_id}" in entry["state"]
                    and entry["window_id"] is not None
                    and entry["window_id"] not in windows_before]
        if not prepared or prepared[0][0] >= appearances[0][0] \
                or prepared[0][1]["window_id"] != first_window_id:
            raise ValueError("TextEdit did not reuse the prepared draft window")
        if context_windows == 2:
            decoy_uri = decoy.as_uri()
            decoy_seen = [(index, entry["decoy_window_id"])
                          for index, entry in enumerate(observations)
                          if decoy_uri in entry["state"] and "Decoy note" in entry["state"]
                          and entry.get("decoy_window_id") is not None
                          and entry["decoy_window_id"] not in windows_before]
            prepared_decoy = {window_id for index, window_id in decoy_seen
                              if index < appearances[0][0]}
            preserved_decoy = {window_id for index, window_id in decoy_seen
                               if index > appearances[0][0]}
            if len(prepared_decoy) != 1 or prepared_decoy != preserved_decoy \
                    or first_window_id in prepared_decoy:
                raise ValueError("TextEdit decoy window identity was not preserved")
    assert_log_privacy(rows)
    return {"command_id": command_id, "run_id": run_id,
            "first_window_id": first_window_id,
            "reopened_window_id": reopened_window_id,
            "window_transitions_verified": window_transitions is not None,
            "prepared_window_reused": bool(context_windows),
            "decoy_window_preserved": context_windows == 2,
            "app_verifier_fail_closed": verifier_failure,
            "file_bytes_verified": True, "reopened_text_verified": True,
            "window_cleanup_verified": True, "before": space_before,
            "after": space_after}


def verify_textedit_cancel_receipt(rows, note, window_transitions, windows_before,
                                  windows_after, space_before, space_after,
                                  prior_command_ids=()):
    """Canceled Save stays unverified and never creates the destination."""
    starts = [row for row in rows if row.get("event") == "command_started"
              and row.get("details", {}).get("user_action") == "run"]
    if len(starts) != 1:
        raise ValueError("Canceled TextEdit command start missing")
    command_id = starts[0].get("details", {}).get("command_id")
    if not command_id or command_id in prior_command_ids:
        raise ValueError("Canceled TextEdit command ID missing or stale")
    command_rows = [row for row in rows if row.get("details", {}).get("command_id") == command_id]
    def events(name):
        return [row.get("details", {}) for row in command_rows if row.get("event") == name]
    routes, turns = events("router_decided"), events("turn_requested")
    tools, completed = events("tool_started"), events("tool_completed")
    ax, finishes = events("fixture_ax_verification"), events("command_finished")
    cleanup = events("textedit_cancel_cleanup")
    if len(routes) != 1 or routes[0].get("route") != "textedit" \
            or routes[0].get("action") != "create_note" \
            or routes[0].get("target") != "fixture_new_note" or len(turns) != 1:
        raise ValueError("Canceled TextEdit route or acting turn mismatch")
    started = {tool.get("item_id") for tool in tools if tool.get("server") == "cua_repl"}
    completed_ids = {tool.get("item_id") for tool in completed
                     if tool.get("server") == "cua_repl" and tool.get("status") == "completed"
                     and tool.get("result_is_error") == "false"}
    if not started or None in started or started != completed_ids:
        raise ValueError("Canceled TextEdit CUA item did not complete cleanly")
    if len(ax) != 1 or ax[0].get("target") != "textedit" \
            or ax[0].get("verified") != "false" \
            or ax[0].get("reason") != "file_bytes_mismatch" \
            or len(finishes) != 1 or finishes[0].get("verification") != "unverified":
        raise ValueError("Canceled TextEdit Save was not unverified")
    if len(cleanup) != 2 or [item.get("result") for item in cleanup] \
            != ["attempted", "discarded"]:
        raise ValueError("Canceled TextEdit cleanup was not exact")
    if note.exists() or note.is_symlink() or windows_after != windows_before \
            or space_before is None or space_after != space_before:
        raise ValueError("Canceled TextEdit Save changed file, windows, or Space")
    if (note.parent / "note-copy.txt").read_bytes() != b"Decoy note":
        raise ValueError("Canceled TextEdit Save changed decoy")
    counts = [len(item["window_ids"]) for item in window_transitions]
    if not any(counts[index:index + 3] == [1, 2, 1]
               for index in range(len(counts) - 2)) or not counts or counts[-1] != 0:
        raise ValueError("Canceled TextEdit Save lacks independent sheet transition")
    cleanup_index = next(index for index, row in enumerate(command_rows)
                         if row.get("event") == "textedit_cancel_cleanup")
    if any(row.get("event") == "tool_started" for row in command_rows[cleanup_index + 1:]):
        raise ValueError("Canceled TextEdit Save started a later actor")
    if any(row.get("event") in ("native_space_requested", "mcp_action_requested",
                                    "space_changed") for row in command_rows):
        raise ValueError("Canceled TextEdit command invoked unrelated desktop action")
    assert_log_privacy(rows)
    return {"command_id": command_id, "run_id": note.parent.name,
            "file_absent": True, "save_sheet_transition_verified": True,
            "window_cleanup_verified": True, "before": space_before, "after": space_after}


def verify_textedit_rejection_receipt(rows, note, windows_before, windows_after,
                                      space_before, space_after, prior_command_ids=()):
    """An unsafe TextEdit phrase must finish before any UI actor or file write."""
    starts = [row for row in rows if row.get("event") == "command_started"
              and row.get("details", {}).get("user_action") == "run"]
    if len(starts) != 1:
        raise ValueError("TextEdit rejection lacks one command")
    command_id = starts[0].get("details", {}).get("command_id")
    if not command_id or command_id in prior_command_ids:
        raise ValueError("TextEdit rejection command ID missing or stale")
    command_rows = [row for row in rows if row.get("details", {}).get("command_id") == command_id]
    routes = [row["details"] for row in command_rows if row.get("event") == "router_decided"]
    finishes = [row["details"] for row in command_rows if row.get("event") == "command_finished"]
    if len(routes) != 1 or routes[0].get("route") != "clarification" \
            or len(finishes) != 1 or finishes[0].get("verification") != "no_action" \
            or any(row.get("event") in ("turn_requested", "tool_started", "tool_completed",
                                       "fixture_ax_verification", "native_space_requested")
                   for row in command_rows):
        raise ValueError("Unsafe TextEdit request started an actor")
    draft = f"Voice Computer draft {note.parent.name}".encode()
    decoy = note.parent / "note-copy.txt"
    if note.read_bytes() != draft or decoy.read_bytes() != b"Decoy note" \
            or windows_after != windows_before \
            or space_before is None or space_after != space_before:
        raise ValueError("Unsafe TextEdit request changed file, windows, or Space")
    assert_log_privacy(rows)
    return {"command_id": command_id, "rejected_before_actor": True,
            "draft_unchanged": True, "window_cleanup_verified": True,
            "before": space_before, "after": space_after}


def verify_textedit_stop_receipt(rows, note, windows_before, windows_after,
                                 space_before, space_after, prior_command_ids=()):
    """A Stop at CUA approval must prevent the first TextEdit actor call."""
    starts = [row for row in rows if row.get("event") == "command_started"
              and row.get("details", {}).get("user_action") == "run"]
    if len(starts) != 1:
        raise ValueError("TextEdit Stop lacks one command")
    command_id = starts[0].get("details", {}).get("command_id")
    if not command_id or command_id in prior_command_ids:
        raise ValueError("TextEdit Stop command ID missing or stale")
    command_rows = [row for row in rows if row.get("details", {}).get("command_id") == command_id]
    def entries(name):
        return [(index, row.get("details", {})) for index, row in enumerate(command_rows)
                if row.get("event") == name]
    route, turn, approval, stop, finish = (
        entries(name) for name in ("router_decided", "turn_requested",
                                   "approval_requested", "stop_requested", "command_finished"))
    if len(route) != 1 or route[0][1].get("route") != "textedit" \
            or len(turn) != 1 or turn[0][1].get("route") != "textedit" \
            or len(approval) != 1 or approval[0][1].get("server_name") != "cua_repl" \
            or len(stop) != 1 or len(finish) != 1 \
            or not turn[0][0] < approval[0][0] < stop[0][0] < finish[0][0] \
            or finish[0][1].get("verification") == "verified":
        raise ValueError("TextEdit Stop lifecycle was not fail-closed")
    ax = entries("fixture_ax_verification")
    if any(item.get("verified") == "true" for _, item in ax):
        raise ValueError("TextEdit Stop reported verified Accessibility")
    tools = entries("tool_started")
    if len(tools) != 1 or tools[0][1].get("server") != "cua_repl" \
            or not turn[0][0] < tools[0][0] < approval[0][0]:
        raise ValueError("TextEdit Stop did not interrupt one pending CUA call")
    decisions = entries("approval_decided")
    if len(decisions) != 1 or decisions[0][1].get("decision") != "Declined on Stop" \
            or not stop[0][0] < decisions[0][0] < finish[0][0]:
        raise ValueError("TextEdit Stop did not decline pending approval")
    completed = entries("tool_completed")
    if any(item.get("status") == "completed" and item.get("result_is_error") == "false"
           for _, item in completed):
        raise ValueError("TextEdit actor completed after Stop")
    if any(row.get("event") in ("native_space_requested", "mcp_action_requested")
           for row in command_rows):
        raise ValueError("TextEdit Stop invoked an unrelated desktop action")
    draft = f"Voice Computer draft {note.parent.name}".encode()
    if note.read_bytes() != draft or (note.parent / "note-copy.txt").read_bytes() \
            != b"Decoy note" or windows_after != windows_before \
            or space_before is None or space_after != space_before:
        raise ValueError("TextEdit Stop changed fixture bytes, windows, or Space")
    assert_log_privacy(rows)
    return {"command_id": command_id, "stop_before_cua_approval": True,
            "draft_unchanged": True, "window_cleanup_verified": True,
            "before": space_before, "after": space_after}


def verify_composed_receipt(rows, run_id, port, fixture_rows, report,
                            browser_observations, finder_observations,
                            before, after, prior_command_ids=(),
                            finder_windows_before=None, finder_windows_after=None):
    """Require two verified app turns under one command and independent UI evidence."""
    starts = [row for row in rows if row.get("event") == "command_started"
              and row.get("details", {}).get("user_action") == "run"]
    if len(starts) != 1:
        raise ValueError("Composed request did not have exactly one app command")
    command_id = starts[0].get("details", {}).get("command_id")
    if not command_id or command_id in prior_command_ids:
        raise ValueError("Composed command ID missing or stale")
    command_rows = [row for row in rows if row.get("details", {}).get("command_id") == command_id]
    def details(name):
        return [row.get("details", {}) for row in command_rows if row.get("event") == name]
    def positions(name):
        return [i for i, row in enumerate(command_rows) if row.get("event") == name]
    routes, turns, completed = (details(name) for name in
                                ("router_decided", "turn_requested", "turn_completed"))
    ax, browser_step, finder_step = (details(name) for name in
                                     ("fixture_ax_verification", "browser_step_verified",
                                      "finder_step_verified"))
    finishes, tools, approvals = (details(name) for name in
                                  ("command_finished", "tool_started", "approval_decided"))
    if len(routes) != 1 or routes[0].get("route") != "browser_finder" \
            or len(turns) != 2 or [turn.get("route") for turn in turns] != ["browser", "finder"] \
            or len(completed) != 2 or any(turn.get("status") != "completed"
                                          or turn.get("verification") != "verified"
                                          for turn in completed):
        raise ValueError("Composed route or two verified turns missing")
    if len(ax) != 2 or [item.get("target") for item in ax] != ["browser", "finder"] \
            or [item.get("reason") for item in ax] != ["exact_url_and_heading", "exact_selected_file"] \
            or any(item.get("verified") != "true" for item in ax) \
            or len(browser_step) != 1 or len(finder_step) != 1:
        raise ValueError("Composed app-owned AX verification missing")
    if len(finishes) != 1:
        raise ValueError("Composed command finish missing or duplicated")
    if not positions("turn_requested")[0] < positions("browser_step_verified")[0] \
            < positions("turn_requested")[1] < positions("finder_step_verified")[0] \
            < positions("command_finished")[0]:
        raise ValueError("Finder started before Browser verification")
    bootstrap = details("finder_window_bootstrap")
    if finder_windows_before is not None:
        if finder_windows_before or finder_windows_after != finder_windows_before:
            raise ValueError("Headless Finder baseline or window restoration failed")
        if len(bootstrap) != 1 or bootstrap[0].get("result") != "opened_window" \
                or len(details("finder_window_bootstrap_ready")) != 1 \
                or not positions("browser_step_verified")[0] \
                    < positions("finder_window_bootstrap")[0] \
                    < positions("turn_requested")[1]:
            raise ValueError("App did not bootstrap headless Finder after Browser verification")
    if len(finishes) != 1 or finishes[0].get("status") != "completed" \
            or finishes[0].get("verification") != "verified":
        raise ValueError("Composed command did not finish verified")
    if not tools or any(tool.get("server") != "cua_repl" for tool in tools):
        raise ValueError("Composed action used a non-Computer-Use tool")
    completions = details("tool_completed")
    started_ids = [tool.get("item_id") for tool in tools]
    completed_ids = [tool.get("item_id") for tool in completions]
    if not all(started_ids) or len(set(started_ids)) != len(started_ids) \
            or sorted(started_ids) != sorted(completed_ids) \
            or any(item.get("server") != "cua_repl" or item.get("status") != "completed"
                   or item.get("result_is_error") != "false" for item in completions):
        raise ValueError("Composed Computer Use call failed or lost correlation")
    if any(item.get("server_name") != "cua_repl"
           or item.get("decision") not in ("Allowed once", "Allowed for session")
           for item in approvals):
        raise ValueError("Composed approval was declined or unexpected")
    if any(row.get("event") in ("native_space_requested", "mcp_action_requested", "space_changed")
           for row in command_rows) or before is None or before != after:
        raise ValueError("Composed request changed desktop Space")
    if [(row.get("method"), row.get("path"), row.get("run_id"))
            for row in fixture_rows] != [("GET", "/home", [run_id]), ("GET", "/docs", [run_id])]:
        raise ValueError("Composed fixture requests differ from Home -> Docs")
    docs_url = f"http://127.0.0.1:{port}/docs?run_id={run_id}"
    heading = f"Voice Computer Docs {run_id}"
    if not any(docs_url.removeprefix("http://") in item and heading in item
               and "heading" in item for item in browser_observations):
        raise ValueError("Independent Safari Docs observation missing")
    if not report.is_file() or report.is_symlink():
        raise ValueError("Composed report is not a regular file")
    selected = re.compile(r"^\s*\d+ row \(selected\)(?:(?!^\s*\d+ row ).)*?URL: (file://\S+)",
                          re.MULTILINE | re.DOTALL)
    decoy_uri = report.with_name("report-copy.txt").as_uri()
    if not any(set(selected.findall(item)) == {report.as_uri()} and decoy_uri in item
               for item in finder_observations):
        raise ValueError("Independent exact Finder selection missing")
    assert_log_privacy(rows)
    return {"command_id": command_id, "url": docs_url, "path": str(report),
            "turns": 2, "before": before, "after": after}


def verify_composed_failure_receipt(rows, run_id, fixture_rows, before, after,
                                    prior_command_ids=(), mode="missing-link"):
    """A failed Browser step must never start Finder within the command."""
    expected_paths = {
        "missing-link": ["/home"], "home-404": ["/home"],
        "redirect": ["/home", "/docs", "/error"],
        "stop-before-docs": ["/home"],
    }.get(mode)
    if expected_paths is None:
        raise ValueError("Unsupported composed Browser failure scenario")
    starts = [row for row in rows if row.get("event") == "command_started"
              and row.get("details", {}).get("user_action") == "run"]
    if len(starts) != 1:
        raise ValueError("Composed failure did not have one app command")
    command_id = starts[0].get("details", {}).get("command_id")
    if not command_id or command_id in prior_command_ids:
        raise ValueError("Composed failure command ID missing or stale")
    command_rows = [row for row in rows if row.get("details", {}).get("command_id") == command_id]
    def details(name):
        return [row.get("details", {}) for row in command_rows if row.get("event") == name]
    route, turns, ax, completed, finished = (details(name) for name in
                                           ("router_decided", "turn_requested",
                                            "fixture_ax_verification", "turn_completed",
                                            "command_finished"))
    if len(route) != 1 or route[0].get("route") != "browser_finder" \
            or len(turns) != 1 or turns[0].get("route") != "browser" \
            or len(ax) != 1 or ax[0].get("target") != "browser" \
            or ax[0].get("verified") != "false" \
            or len(completed) != 1 or completed[0].get("verification") != "unverified" \
            or len(finished) != 1 or finished[0].get("verification") != "unverified" \
            or len(details("browser_step_failed")) != 1 \
            or details("browser_step_verified") or details("finder_step_queued") \
            or details("finder_step_verified"):
        raise ValueError("Composed failure continued or claimed verification")
    if mode == "stop-before-docs":
        if len(details("stop_requested")) != 1 or completed[0].get("status") == "completed" \
                or ax[0].get("reason") != "turn_incomplete":
            raise ValueError("Composed Stop did not interrupt Browser")
    elif ax[0].get("reason") != "url_or_heading_mismatch":
        raise ValueError("Composed Browser failure reason mismatch")
    if [(row.get("method"), row.get("path"), row.get("run_id"))
            for row in fixture_rows] != [("GET", path, [run_id]) for path in expected_paths]:
        raise ValueError("Composed Browser failure requested unexpected path")
    if before is None or before != after or any(
            row.get("event") in ("native_space_requested", "mcp_action_requested", "space_changed")
            for row in command_rows):
        raise ValueError("Composed Browser failure changed desktop Space")
    assert_log_privacy(rows)
    return {"command_id": command_id, "scenario": mode, "browser_turns": 1,
            "finder_turns": 0, "before": before, "after": after}


def verify_composed_rejection_receipt(rows, fixture_rows, before, after,
                                      prior_command_ids=(), mode="missing-file"):
    """A missing or unsafe report must be rejected before Safari opens."""
    if mode not in ("missing-file", "symlink-escape", "decoy-target"):
        raise ValueError("Unsupported composed target rejection scenario")
    starts = [row for row in rows if row.get("event") == "command_started"
              and row.get("details", {}).get("user_action") == "run"]
    if len(starts) != 1:
        raise ValueError("Composed rejection did not have one app command")
    command_id = starts[0].get("details", {}).get("command_id")
    if not command_id or command_id in prior_command_ids:
        raise ValueError("Composed rejection command ID missing or stale")
    command_rows = [row for row in rows if row.get("details", {}).get("command_id") == command_id]
    if fixture_rows or any(row.get("event") in (
            "turn_requested", "tool_started", "approval_decided", "fixture_ax_verification",
            "native_space_requested", "mcp_action_requested", "space_changed")
            for row in command_rows):
        raise ValueError("Rejected composed target started an action")
    routes = [row.get("details", {}) for row in command_rows if row.get("event") == "router_decided"]
    finishes = [row.get("details", {}) for row in command_rows if row.get("event") == "command_finished"]
    if any(route.get("route") != "clarification" for route in routes) \
            or len(finishes) != 1 or finishes[0].get("verification") != "no_action":
        raise ValueError("Rejected composed target did not finish with no action")
    if before is None or before != after:
        raise ValueError("Rejected composed target changed desktop Space")
    assert_log_privacy(rows)
    return {"command_id": command_id, "scenario": mode, "browser_turns": 0,
            "finder_turns": 0, "before": before, "after": after}


def verify_desktop_state_receipt(rows, before, after, independent_frontmost,
                                 prior_command_ids=()):
    """Correlate one approved read-only MCP result with independent macOS state."""
    starts = [row for row in rows if row.get("event") == "command_started"
              and row.get("details", {}).get("user_action") == "run"]
    if len(starts) != 1:
        raise ValueError("Desktop-state read did not have one app command")
    command_id = starts[0].get("details", {}).get("command_id")
    if not command_id or command_id in prior_command_ids:
        raise ValueError("Desktop-state command ID missing or stale")
    command_rows = [row for row in rows if row.get("details", {}).get("command_id") == command_id]
    def events(name):
        return [row.get("details", {}) for row in command_rows if row.get("event") == name]
    requests, turns, tools, approvals = (events(name) for name in
                                       ("mcp_state_requested", "turn_requested",
                                        "tool_started", "approval_decided"))
    bound, observed, correlated, completed = (events(name) for name in
                                             ("mcp_state_helper_bound", "mcp_state_observed",
                                              "mcp_state_result_correlated", "tool_completed"))
    turn_end, finish = events("turn_completed"), events("command_finished")
    retries = events("mcp_state_discovery_retry")
    if len(retries) > 1 or any(retry.get("reason") != "no_tool_call" for retry in retries):
        raise ValueError("Desktop-state discovery retried outside its bounded contract")
    attempts = len(retries) + 1
    if len(requests) != attempts or len(turns) != attempts \
            or any(turn.get("route") != "desktop_state" for turn in turns) \
            or len(tools) != 1 or tools[0].get("server") != "desktop_tool" \
            or tools[0].get("tool") != "get_desktop_state":
        raise ValueError("Desktop-state read route or exact tool missing")
    if retries:
        retry_index = next(i for i, row in enumerate(command_rows)
                           if row.get("event") == "mcp_state_discovery_retry")
        if any(row.get("event") in ("tool_started", "approval_decided", "mcp_state_observed")
               for row in command_rows[:retry_index]) \
                or sum(row.get("event") == "turn_requested"
                       for row in command_rows[:retry_index]) != 1:
            raise ValueError("Desktop-state discovery retry followed a tool or approval")
    if len(approvals) != 1 or approvals[0].get("server_name") != "desktop_tool" \
            or approvals[0].get("decision") != "Allowed once":
        raise ValueError("Desktop-state read did not have one Allow once approval")
    if len(bound) != 1 or bound[0].get("path_matches_preflight") != "true" \
            or len(observed) != 1 or observed[0].get("status") != "observed" \
            or len(correlated) != 1 or correlated[0].get("item_id") != tools[0].get("item_id"):
        raise ValueError("Desktop-state helper or app observation not correlated")
    if len(completed) != 1 or completed[0].get("item_id") != tools[0].get("item_id") \
            or completed[0].get("status") != "completed" \
            or completed[0].get("result_is_error") != "false" \
            or completed[0].get("typed_status") != "observed" \
            or completed[0].get("typed_verified") != "true" \
            or len(turn_end) != 1 or turn_end[0].get("verification") != "verified" \
            or len(finish) != 1 or finish[0].get("verification") != "verified":
        raise ValueError("Desktop-state typed result or turn unverified")
    if before is None or after != before \
            or observed[0].get("space_id") != str(before["current"]) \
            or observed[0].get("ordered_space_ids") != ",".join(map(str, before["ordered"])):
        raise ValueError("Independent desktop Space observation differs")
    if not independent_frontmost \
            or observed[0].get("frontmost_bundle_id") != independent_frontmost:
        raise ValueError("Independent foreground app observation differs")
    try:
        tool_time = datetime.fromisoformat(observed[0]["observed_at"].replace("Z", "+00:00"))
        log_time = datetime.fromisoformat(next(row["timestamp"] for row in command_rows
                                         if row.get("event") == "mcp_state_observed")
                                         .replace("Z", "+00:00"))
        if abs((tool_time - log_time).total_seconds()) > 5:
            raise ValueError("Desktop-state observation timestamp is stale")
    except (KeyError, TypeError, ValueError) as error:
        raise ValueError("Desktop-state observation timestamp invalid") from error
    if any(row.get("event") in ("native_space_requested", "native_space_ax_pressed",
                                   "mcp_action_requested", "space_changed", "fixture_ax_verification")
           for row in command_rows):
        raise ValueError("Desktop-state read performed an action")
    assert_log_privacy(rows)
    return {"command_id": command_id, "item_id": tools[0]["item_id"],
            "read_attempts": attempts,
            "space_id": before["current"], "frontmost_bundle_id": independent_frontmost,
            "before": before, "after": after}


def verify_finder_rejection_receipt(rows, report, before, after,
                                    prior_command_ids=(), mode="missing-file"):
    """Require the unsafe Finder target to finish without starting an actor."""
    if mode not in ("missing-file", "symlink-escape", "decoy-target"):
        raise ValueError("Unsupported Finder rejection scenario")
    if mode == "missing-file" and report.exists():
        raise ValueError("Missing-file fixture unexpectedly exists")
    if mode == "symlink-escape" and not report.is_symlink():
        raise ValueError("Symlink-escape fixture is not a symlink")
    if mode == "decoy-target" and (report.name != "report-copy.txt" or not report.is_file()):
        raise ValueError("Decoy-target fixture is missing")
    starts = [row for row in rows if row.get("event") == "command_started"
              and row.get("details", {}).get("user_action") == "run"]
    if len(starts) != 1:
        raise ValueError("Missing or ambiguous Finder command start")
    command_id = starts[0].get("details", {}).get("command_id")
    if not command_id or command_id in prior_command_ids:
        raise ValueError("Finder command ID missing or stale")
    command_rows = [row for row in rows
                    if row.get("details", {}).get("command_id") == command_id]
    if any(row.get("event") in (
            "turn_requested", "tool_started", "approval_decided", "native_space_requested",
            "mcp_action_requested", "space_changed", "fixture_ax_verification")
            for row in command_rows):
        raise ValueError("Rejected Finder target started an action")
    routes = [row for row in command_rows if row.get("event") == "router_decided"]
    if any(row.get("details", {}).get("route") != "clarification" for row in routes):
        raise ValueError("Rejected Finder target received an acting route")
    finishes = [row.get("details", {}) for row in command_rows
                if row.get("event") == "command_finished"]
    if len(finishes) != 1 or finishes[0].get("status") != "clarification" \
            or finishes[0].get("verification") != "no_action":
        raise ValueError("Rejected Finder target did not finish with no action")
    if before is None or after != before:
        raise ValueError("Rejected Finder command changed desktop Space")
    assert_log_privacy(rows)
    return {"command_id": command_id, "scenario": mode, "path": str(report),
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
    def __init__(self, executable, log_path, trace_tool_output=False, app_path=None,
                 finder_mode="normal", browser_mode="normal"):
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
        self.finder_mode = finder_mode
        self.browser_mode = browser_mode
        self.cua_binding_observed = False
        self.browser_observations = []
        self.browser_run_id = None
        self.finder_observations = []
        self.finder_context_observations = []
        self.finder_run_id = None
        self.finder_decoy_run_id = None
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

    def textedit_decoy_window_id(self, state):
        uri = getattr(self, "textedit_decoy_uri", None)
        if not uri or uri not in state:
            return None
        try:
            matches = textedit_window_inventory("note-copy.txt")["matching_window_ids"]
        except (OSError, subprocess.SubprocessError, ValueError, KeyError) as error:
            self.record("textedit_decoy_observer_unavailable",
                        error_type=type(error).__name__)
            return None
        return next(iter(matches)) if len(matches) == 1 else None

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
            and app in ({CASE_APP[self.command_index - 1], str(self.app_path)}
                        | ({"Safari", "com.apple.Safari"}
                           if self.finder_mode == "normal" else set())
                        | ({"Finder", "com.apple.finder"}
                           if self.finder_mode == "normal" and self.browser_mode == "normal"
                           else set())
                        if self.command_index == 19 else
                        {CASE_APP[self.command_index - 1], str(self.app_path),
                         "Safari", "com.apple.Safari"}
                        if self.command_index in (17, 21) else
                        {CASE_APP[self.command_index - 1], str(self.app_path),
                         "Finder", "com.apple.finder"}
                        if self.command_index == 22 or \
                        (self.command_index == 18 and self.finder_mode == "normal") else
                        {CASE_APP[self.command_index - 1], str(self.app_path),
                         "TextEdit", "com.apple.TextEdit"}
                        if self.command_index in (23, 24) else
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
            limit = 44 if self.command_index in (21, 22, 23, 24) else \
                36 if self.command_index == 19 else \
                24 if self.command_index in (6, 9, 10, 14, 15, 16, 17, 18) else 12
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
                if self.command_index in (17, 19, 21) and item.get("server") == "cua_repl":
                    self.browser_observations.extend(
                        part.get("text") or "" for part in content
                        if part.get("type") == "text" and "Window:" in (part.get("text") or "")
                        and "Safari" in (part.get("text") or ""))
                if self.command_index in (18, 19, 22) and item.get("server") == "cua_repl":
                    self.finder_observations.extend(
                        part.get("text") or "" for part in content
                        if part.get("type") == "text" and "Window:" in (part.get("text") or "")
                        and "Finder" in (part.get("text") or ""))
                if self.command_index == 22 and item.get("server") == "cua_repl":
                    for part in content:
                        state = part.get("text") or ""
                        if "App: Finder" not in state:
                            continue
                        matched_run_id = next(
                            (candidate for candidate in
                             (self.finder_run_id, self.finder_decoy_run_id)
                             if candidate and f'Window: "{candidate}"' in state), None)
                        if matched_run_id is None:
                            continue
                        try:
                            matches = finder_window_inventory(
                                matched_run_id)["matching_window_ids"]
                        except (OSError, subprocess.SubprocessError, ValueError, KeyError) as error:
                            self.record("finder_context_observer_unavailable",
                                        error_type=type(error).__name__)
                            matches = set()
                        self.finder_context_observations.append({
                            "state": state,
                            "window_id": next(iter(matches)) if len(matches) == 1 else None,
                        })
                        self.record("finder_context_observed",
                                    window_id=next(iter(matches)) if len(matches) == 1 else None,
                                    sentinel_visible="sentinel.txt" in state)
                if self.command_index in (23, 24) and item.get("server") == "cua_repl":
                    for part in content:
                        state = part.get("text") or ""
                        if "App: TextEdit" not in state:
                            continue
                        try:
                            matches = textedit_window_inventory("note.txt")["matching_window_ids"]
                        except (OSError, subprocess.SubprocessError, ValueError, KeyError) as error:
                            self.record("textedit_context_observer_unavailable",
                                        error_type=type(error).__name__)
                            matches = set()
                        self.textedit_observations.append({
                            "state": state,
                            "window_id": next(iter(matches)) if len(matches) == 1 else None,
                            "decoy_window_id": self.textedit_decoy_window_id(state),
                        })
                        self.record("textedit_context_observed",
                                    window_id=next(iter(matches)) if len(matches) == 1 else None,
                                    decoy_window_id=self.textedit_observations[-1][
                                        "decoy_window_id"],
                                    matching_window_count=len(matches),
                                    open_panel='Window: "Open", App: TextEdit' in state,
                                    target_url_visible=bool(getattr(self, "textedit_note_uri", None)
                                                            and self.textedit_note_uri in state),
                                    saved_text_visible=bool(getattr(self, "textedit_saved_text", None)
                                                            and self.textedit_saved_text in state))
                if self.trace_tool_output:
                    self.record("tool_output_trace", item_id=item.get("id"),
                                excerpt="\n".join(str(part.get("text") or "") for part in content)[:3000])
                    if error:
                        self.record("tool_error_trace", item_id=item.get("id"),
                                    excerpt=error[:2000])
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
                    error_excerpt=str(error)[:300] if error else None,
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
        return ([13] if mission_control_gate else []) + [20, 17, 18, 21, 22, 23, 24, 19, 15, 16, 20]
    return cases or list(range(1, 7))


def preferred_available_model(available):
    """Use a supported ChatGPT-sign-in model; stale CLI catalogs fail closed."""
    preferred = ("gpt-5.6-sol", "gpt-6.1-sol", "gpt-6-sol", "gpt-6-luna",
                 "gpt-5.6-terra", "gpt-5.6-luna", "gpt-6-astra")
    for model in preferred:
        if model in available:
            return model
    raise ValueError("Codex CLI model catalog is outdated; update the standalone Codex CLI")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default=default_codex())
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--trace-tool-output", action="store_true",
                        help="Record bounded tool input/output excerpts; may contain private UI text")
    parser.add_argument("--case", type=int, action="append", choices=range(1, len(COMMANDS) + 1),
                        help="Run one numbered command; repeat to select multiple")
    parser.add_argument("--suite", action="store_true",
                        help="Run isolated Browser/Finder, composed Browser-Finder, and Codex feasibility")
    parser.add_argument("--mission-control-gate", action="store_true",
                        help="Require read-only Mission Control case 13 before --suite acts")
    parser.add_argument("--browser-mode", default="normal",
                        choices=("normal", "missing-link", "home-404", "redirect",
                                 "stop-before-docs", "form-submit"),
                        help="Fixture scenario for a focused --case 17, 19, or 21 run")
    parser.add_argument("--finder-mode", default="normal",
                        choices=("normal", "missing-file", "symlink-escape", "decoy-target"),
                        help="Fixture scenario for a focused --case 18, 19, or 22 run")
    parser.add_argument("--textedit-mode", default="normal",
        choices=("normal", "wrong-text", "wrong-file",
                                 "verifier-failure", "stop-before-save", "cancel-save"),
                        help="Fixture scenario for focused case 23 or 24")
    parser.add_argument("--textedit-context-windows", type=int, choices=(0, 1, 2), default=0,
                        help="Prepared TextEdit fixture windows for focused --case 23")
    parser.add_argument("--safari-context-windows", type=int, choices=(1, 2), default=1,
                        help="Number of test-owned sentinel windows for focused --case 21")
    parser.add_argument("--finder-context-windows", type=int, choices=(1, 2), default=1,
                        help="Number of test-owned fixture windows for focused --case 22")
    parser.add_argument("--inject-inner-cua-failure", action="store_true",
                        help="Synthetic Debug CUA completion failure for focused case 21, 22, or 23")
    parser.add_argument("--codex-thread-id",
                        help="Optional exact existing Codex task UUID for --suite's read-only status probe")
    parser.add_argument("--app-path", type=Path,
                        help="Canonical absolute VoiceComputerPOC.app path for exact-app cases")
    parser.add_argument("--single-mcp-step", action="store_true",
                        help="Run only one rightward MCP case and stop regardless of result")
    args = parser.parse_args()
    try:
        selected = selected_cases(args.suite, args.case, args.mission_control_gate)
    except ValueError as error:
        parser.error(str(error))
    if args.browser_mode != "normal" and selected not in ([17], [19], [21]):
        parser.error("--browser-mode requires a focused --case 17, 19, or 21 run")
    if selected == [21] and args.browser_mode == "form-submit":
        parser.error("--case 21 does not support form-submit")
    if args.safari_context_windows != 1 and (selected != [21] or args.browser_mode != "normal"):
        parser.error("Two Safari context windows require normal focused --case 21")
    if args.finder_context_windows != 1 and (selected != [22] or args.finder_mode != "normal"):
        parser.error("Two Finder context windows require normal focused --case 22")
    if args.inject_inner_cua_failure and (selected not in ([21], [22], [23])
            or args.browser_mode != "normal" or args.finder_mode != "normal"
            or args.safari_context_windows != 1 or args.finder_context_windows != 1):
        parser.error("Injected CUA failure requires one normal focused case 21, 22, or 23 window")
    if args.finder_mode != "normal" and selected not in ([18], [19], [22]):
        parser.error("--finder-mode requires a focused --case 18, 19, or 22 run")
    if args.textedit_mode == "cancel-save" and selected != [24]:
        parser.error("Canceled Save requires focused --case 24")
    if args.textedit_mode not in ("normal", "cancel-save") and selected != [23]:
        parser.error("--textedit-mode requires a focused --case 23 run")
    if args.textedit_context_windows and (selected != [23]
                                          or args.textedit_mode not in ("normal", "verifier-failure")
                                          or args.inject_inner_cua_failure):
        parser.error("Prepared TextEdit windows require normal or verifier focused --case 23")
    if args.textedit_mode != "normal" and args.inject_inner_cua_failure:
        parser.error("Use one TextEdit failure mode at a time")
    if selected == [19] and args.browser_mode == "form-submit":
        parser.error("--case 19 does not accept form-submit")
    if selected == [19] and args.browser_mode != "normal" and args.finder_mode != "normal":
        parser.error("Use one failure mode at a time for --case 19")
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
            parser.error("Exact-app cases require --app-path")
        try:
            app_path = canonical_app_path(args.app_path)
        except (OSError, ValueError) as error:
            parser.error(str(error))
    if args.inject_inner_cua_failure and "Debug" not in app_path.parts:
        parser.error("Injected CUA failure requires an exact Debug app")
    if args.textedit_mode == "verifier-failure" and "Debug" not in app_path.parts:
        parser.error("Synthetic TextEdit verifier failure requires a Debug app")
    if args.textedit_mode == "cancel-save" and "Debug" not in app_path.parts:
        parser.error("Canceled Save fixture requires a Debug app")
    if mcp_selected:
        try:
            validate_mcp_cases(
                [case for case in selected if case in MCP_CASES],
                single_step=args.single_mcp_step)
        except ValueError as error:
            parser.error(str(error))
    os.umask(0o077)
    args.log.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    driver = Driver(args.codex, args.log, trace_tool_output=args.trace_tool_output,
                    app_path=app_path, finder_mode=args.finder_mode,
                    browser_mode=args.browser_mode)
    failed = False
    fixtures = []
    finder_fixtures = []
    finder_outside_fixtures = []
    textedit_fixture_root = None
    textedit_windows_before = None
    textedit_sampler = None
    try:
        locked = screen_is_locked()
        driver.record("environment_check", screen_locked=locked)
        if locked is True or (exact_selected and locked is not False):
            print("SMOKE BLOCKED: macOS desktop unlock state is not verified", file=sys.stderr)
            return 2
        if exact_selected:
            identity = exact_build_identity(app_path)
            driver.record("exact_build_identity", **identity)
            if args.suite and not identity["source_clean"]:
                raise RuntimeError("Full suite requires a clean source commit")
        driver.wait_rpc(driver.rpc("initialize", {"clientInfo": {
            "name": "voice_computer_smoke", "title": "Voice Computer Smoke Test", "version": "0.1.0",
        }}))
        driver.send({"method": "initialized", "params": {}})
        models = driver.wait_rpc(driver.rpc("model/list", {})).get("data") or []
        available = [item["id"] for item in models if "id" in item]
        model = preferred_available_model(available)
        driver.record("model_selected", model=model)
        support = Path.home() / "Library/Application Support/VoiceComputerPOC"
        support.mkdir(parents=True, exist_ok=True)
        thread = driver.wait_rpc(driver.rpc("thread/start", {
            "model": model, "cwd": str(support), "approvalPolicy": "on-request", "sandbox": "read-only",
        }))["thread"]["id"]
        for index in selected:
            phrase = COMMANDS[index - 1]
            fixture = None
            sentinel_url = None
            safari_windows_before = None
            finder_windows_before = None
            finder_prepared_by_host = False
            finder_run_id = None
            finder_decoy_run_id = None
            finder_decoy_report = None
            textedit_note = None
            textedit_windows_before = None
            textedit_sampler = None
            home_requested = home_release = None
            if index in (17, 19, 21):
                run_id = uuid.uuid4().hex
                temporary = tempfile.TemporaryDirectory(prefix="voice-browser-smoke-")
                fixture_log = Path(temporary.name) / "requests.jsonl"
                if args.browser_mode == "stop-before-docs":
                    home_requested, home_release = threading.Event(), threading.Event()
                fixture_mode = "hold-home" if home_requested else args.browser_mode
                server = make_server(run_id, fixture_log, fixture_mode,
                                     home_requested=home_requested, home_release=home_release)
                fixture_thread = threading.Thread(target=server.serve_forever, daemon=True)
                fixture_thread.start()
                fixtures.append((server, fixture_thread, temporary, home_release))
                fixture = (run_id, server.server_port, fixture_log)
                form = index == 17 and args.browser_mode == "form-submit"
                path = "docs" if form else "home"
                url = f"http://127.0.0.1:{server.server_port}/{path}?run_id={run_id}"
                action = (f"submit query test-{run_id}" if form else "follow the Docs link")
                if index == 17:
                    phrase = (f'In the exact Voice Computer POC app, enter "Open {url} '
                              f'and {action}." in the command field and press Return once. '
                              'Approve only Safari if the app shows a Computer Use approval. '
                              'Wait for the app result, then independently inspect the Safari '
                              'window and report its exact URL and visible heading. Do not navigate Safari '
                              'yourself or submit a second app command.')
                if index == 21:
                    if args.inject_inner_cua_failure:
                        marker_root = support / "TestFixtures" / run_id
                        marker_root.mkdir(parents=True, mode=0o700)
                        finder_fixtures.append(marker_root)
                        (marker_root / "inject_cua_failure").write_text(
                            f"browser:{run_id}\n")
                    sentinel_url = (f"http://127.0.0.1:{server.server_port}/sentinel"
                                    f"?run_id={run_id}")
                    safari_windows_before = safari_window_ids()
                    windows = ("two new Safari windows, each" if args.safari_context_windows == 2
                               else "one new Safari window")
                    phrase = (f'Create {windows} with {sentinel_url} as its sentinel tab. '
                              'Then, in the exact Voice Computer POC app, '
                              f'enter "Open {url} and follow the Docs link." once. '
                              'After the app finishes, inspect the acted Safari window, close '
                              'only the new run-specific fixture tab, verify its sentinel remains, '
                              'then close only the test-created Safari window or windows.')
                    if args.inject_inner_cua_failure:
                        phrase = (f'Create one Safari window with {sentinel_url} as its sentinel '
                                  'tab. In the exact Voice Computer POC app, enter '
                                  f'"Open {url} and follow the Docs link." once. Wait for the '
                                  'injected tool failure. Verify the sentinel remains unchanged, '
                                  'then close only that test-created Safari window.')
            if index == 19:
                finder_windows_before = finder_window_inventory()["window_ids"]
                if args.browser_mode == "normal" and args.finder_mode == "normal" \
                        and finder_windows_before:
                    raise RuntimeError("Composed cold-start case requires no Finder windows")
                fixture_root = support / "TestFixtures" / run_id
                fixture_root.mkdir(parents=True, mode=0o700)
                finder_fixtures.append(fixture_root)
                report = fixture_root / "report.txt"
                if args.finder_mode in ("normal", "decoy-target"):
                    report.write_text("Voice Computer composed fixture\n")
                elif args.finder_mode == "symlink-escape":
                    outside = tempfile.TemporaryDirectory(prefix="voice-composed-outside-")
                    finder_outside_fixtures.append(outside)
                    outside_report = Path(outside.name) / "report.txt"
                    outside_report.write_text("Outside composed fixture\n")
                    report.symlink_to(outside_report)
                (fixture_root / "report-copy.txt").write_text("Decoy\n")
                if args.finder_mode == "decoy-target":
                    report = fixture_root / "report-copy.txt"
                phrase = (f'In the exact Voice Computer POC app, enter "Open {url} '
                          f'and follow the Docs link, then reveal the test report at {report} '
                          'in Finder." in the command field and press Return once. '
                          'Approve only Safari and Finder Computer Use inside the app. Wait for '
                          'the single app command to finish, then independently inspect both '
                          'Safari Docs and Finder selected report. Do not navigate or select '
                          'either target yourself or submit another app command.')
                if args.finder_mode != "normal":
                    phrase = (f'In the exact Voice Computer POC app, enter "Open {url} '
                              f'and follow the Docs link, then reveal the test report at {report} '
                              'in Finder." once. Wait for the preflight rejection. Do not '
                              'inspect or control Safari or Finder.')
                elif args.browser_mode != "normal":
                    phrase = (f'In the exact Voice Computer POC app, enter "Open {url} '
                              f'and follow the Docs link, then reveal the test report at {report} '
                              'in Finder." once. Approve only Safari Computer Use if prompted. '
                              'Wait for the failed or stopped Browser result. Inspect and close '
                              'only the fixture Safari tab; do not bind or inspect Finder.')
            if index in (18, 22):
                fixture_root = support / "TestFixtures" / uuid.uuid4().hex
                fixture_root.mkdir(parents=True, mode=0o700)
                finder_fixtures.append(fixture_root)
                finder_run_id = fixture_root.name
                report = fixture_root / "report.txt"
                if args.finder_mode in ("normal", "decoy-target"):
                    report.write_text("Voice Computer Finder fixture\n")
                elif args.finder_mode == "symlink-escape":
                    outside = tempfile.TemporaryDirectory(prefix="voice-finder-outside-")
                    finder_outside_fixtures.append(outside)
                    outside_report = Path(outside.name) / "report.txt"
                    outside_report.write_text("Outside Finder fixture\n")
                    report.symlink_to(outside_report)
                (fixture_root / "report-copy.txt").write_text("Decoy\n")
                if index == 22:
                    if args.inject_inner_cua_failure:
                        (fixture_root / "inject_cua_failure").write_text(
                            f"finder:{finder_run_id}\n")
                    (fixture_root / "sentinel.txt").write_text("Finder window sentinel\n")
                    finder_windows_before = finder_window_inventory()["window_ids"]
                    if (not finder_windows_before and args.finder_context_windows == 1
                            and args.finder_mode == "normal"
                            and not args.inject_inner_cua_failure):
                        subprocess.run(["open", "-a", "Finder", str(fixture_root)],
                                       check=True, timeout=15)
                        deadline = time.monotonic() + 10
                        while time.monotonic() < deadline:
                            if len(finder_window_inventory(finder_run_id)[
                                    "matching_window_ids"]) == 1:
                                finder_prepared_by_host = True
                                break
                            time.sleep(0.2)
                        if not finder_prepared_by_host:
                            raise RuntimeError("Test-owned Finder fixture window did not open")
                    if args.finder_context_windows == 2:
                        decoy_root = support / "TestFixtures" / f"{finder_run_id}-decoy"
                        decoy_root.mkdir(parents=True, mode=0o700)
                        finder_fixtures.append(decoy_root)
                        finder_decoy_run_id = decoy_root.name
                        finder_decoy_report = decoy_root / "report.txt"
                        finder_decoy_report.write_text("Decoy window report\n")
                        (decoy_root / "report-copy.txt").write_text("Decoy copy\n")
                        (decoy_root / "sentinel.txt").write_text("Decoy window sentinel\n")
                if args.finder_mode == "decoy-target":
                    report = fixture_root / "report-copy.txt"
                finder_instruction = (
                    'Approve only Finder if the app shows a Computer Use approval. Wait for '
                    'the app result, then independently inspect Finder and report the exact '
                    'selected file URL. Do not open or edit the file or submit a second app command.'
                    if args.finder_mode == "normal" else
                    'Wait for the app result. Report whether it rejected the unsafe target '
                    'without opening Finder or starting an acting turn. Do not submit a second app command.')
                phrase = (f'In the exact Voice Computer POC app, enter "Reveal the test report '
                          f'at {report} in Finder." in the command field and press Return once. '
                          + finder_instruction)
                if index == 22:
                    phrase = (f'Create one new Finder window and show the test folder '
                              f'{fixture_root} in list view, preserving its sentinel.txt file. '
                              f'Then, in the exact Voice Computer POC app, enter "Reveal the '
                              f'test report at {report} in Finder." once. After the app finishes, '
                              'inspect the exact report selection in that same Finder window '
                              'and close only the test-created window.')
                    if finder_prepared_by_host:
                        phrase = (f'A test-owned Finder window already shows {fixture_root}. '
                                  'In that window, verify sentinel.txt is present, then in the '
                                  'exact Voice Computer POC app enter "Reveal the test report at '
                                  f'{report} in Finder." once. After the app finishes, inspect '
                                  'the exact report selection in the same Finder window and '
                                  'close only that test-owned window.')
                    if args.finder_context_windows == 2:
                        phrase = (f'Create one Finder window showing decoy folder '
                                  f'{finder_decoy_report.parent} in list view, then a second '
                                  f'Finder window showing intended folder {fixture_root} '
                                  'in list view. Do not select a file in either. In the exact '
                                  'Voice Computer POC app, enter "Reveal the test report at '
                                  f'{report} in Finder." once. Verify the report is selected '
                                  'only in the second window, the decoy remains unchanged, '
                                  'then close only these two test-created windows.')
                    if args.finder_mode != "normal":
                        phrase = (f'Create one new Finder window and show the test folder '
                                  f'{fixture_root} in list view, preserving its sentinel.txt file. '
                                  f'Then, in the exact Voice Computer POC app, enter "Reveal the '
                                  f'test report at {report} in Finder." once. Wait for the unsafe '
                                  'target rejection, verify the prepared Finder window did not '
                                  'change, and close only that test-created window.')
                    if args.inject_inner_cua_failure:
                        phrase = (f'Create one Finder window showing {fixture_root} in list '
                                  'view with sentinel.txt. In the exact Voice Computer POC '
                                  f'app, enter "Reveal the test report at {report} in Finder." '
                                  'once. Wait for the injected tool failure, verify the '
                                  'sentinel and selection remain unchanged, then close only '
                                  'that test-created Finder window.')
            if index == 23:
                run_id = uuid.uuid4().hex
                fixture_root = support / "TestFixtures" / run_id
                fixture_root.mkdir(parents=True, mode=0o700)
                finder_fixtures.append(fixture_root)
                textedit_fixture_root = fixture_root
                textedit_note = fixture_root / "note.txt"
                textedit_note.write_text(f"Voice Computer draft {run_id}")
                driver.textedit_note_uri = textedit_note.as_uri()
                driver.textedit_saved_text = f"Voice Computer saved {run_id}"
                (fixture_root / "note-copy.txt").write_text("Decoy note")
                driver.textedit_decoy_uri = ((fixture_root / "note-copy.txt").as_uri()
                                           if args.textedit_context_windows == 2 else None)
                if args.inject_inner_cua_failure:
                    (fixture_root / "inject_cua_failure").write_text(
                        f"textedit:{run_id}\n")
                if args.textedit_mode == "verifier-failure":
                    (fixture_root / "inject_ax_failure").write_text(
                        f"textedit:{run_id}\n")
                textedit_windows_before = textedit_window_inventory()["window_ids"]
                if args.textedit_mode in ("normal", "verifier-failure") \
                        and not args.inject_inner_cua_failure:
                    textedit_sampler = TextEditWindowSampler()
                if not args.textedit_context_windows and args.textedit_mode in (
                        "normal", "verifier-failure"):
                    subprocess.run(["open", "-a", "TextEdit"], check=True, timeout=15)
                    time.sleep(0.5)
                if args.textedit_context_windows:
                    prepared_notes = ([fixture_root / "note-copy.txt"]
                                      if args.textedit_context_windows == 2 else [])
                    prepared_notes.append(textedit_note)
                    for prepared_note in prepared_notes:
                        subprocess.run(["open", "-a", "TextEdit", str(prepared_note)],
                                       check=True, timeout=15)
                        deadline = time.monotonic() + 10
                        while time.monotonic() < deadline:
                            if len(textedit_window_inventory(prepared_note.name)[
                                    "matching_window_ids"]) == 1:
                                break
                            time.sleep(0.2)
                        else:
                            raise RuntimeError("Prepared TextEdit fixture window did not open")
                phrase = (f'In the exact Voice Computer POC app, enter "In TextEdit, '
                          f'replace the test note at {textedit_note} with '
                          f'\"Voice Computer saved {run_id}\" and save it." once. '
                          'The test watcher approves TextEdit Computer Use; do not bind '
                          'or inspect UserNotificationCenter. Wait for the app result, '
                          'then inspect the exact TextEdit file URL and visible text. '
                          'Close only this test document, reopen the same file through '
                          'TextEdit, verify its saved text, and close it again.')
                if args.inject_inner_cua_failure:
                    phrase = (f'In the exact Voice Computer POC app, enter "In TextEdit, '
                              f'replace the test note at {textedit_note} with '
                              f'\"Voice Computer saved {run_id}\" and save it." once. '
                              'Wait for the injected tool failure; leave TextEdit untouched.')
                if args.textedit_context_windows:
                    command = (f'In TextEdit, replace the test note at {textedit_note} '
                               f'with "Voice Computer saved {run_id}" and save it.')
                    prelude = (f'The decoy at {fixture_root / "note-copy.txt"} is '
                               'already open in TextEdit. Capture its URL and text and leave '
                               'it open. '
                               if args.textedit_context_windows == 2 else '')
                    phrase = (prelude + f'The existing note at {textedit_note} is '
                              'already open in TextEdit. Capture its URL and draft text. '
                              'In the exact '
                              f'Voice Computer POC app, enter "{command}" once. '
                              'The test watcher approves TextEdit Computer Use; do not '
                              'bind or inspect UserNotificationCenter. After the app finishes, '
                              'verify the prepared note window shows the saved text. Close '
                              'only that note, observe it absent, reopen the same path, '
                              'verify its text and URL, and close it again. '
                              + ('Verify the decoy remains unchanged and close only its '
                                 'window.' if args.textedit_context_windows == 2 else ''))
                if args.textedit_mode == "stop-before-save":
                    phrase = (f'In the exact Voice Computer POC app, enter "In TextEdit, '
                              f'replace the test note at {textedit_note} with '
                              f'"Voice Computer saved {run_id}" and save it." once. '
                              'Wait for its TextEdit Computer Use approval without approving. '
                              'The test watcher will press Stop at that approval. Wait for '
                              'the interrupted result and leave TextEdit untouched.')
                if args.textedit_mode in ("wrong-file", "wrong-text"):
                    unsafe_note = (fixture_root / "note-copy.txt"
                                   if args.textedit_mode == "wrong-file" else textedit_note)
                    unsafe_text = ("Voice Computer different " + run_id
                                   if args.textedit_mode == "wrong-text"
                                   else "Voice Computer saved " + run_id)
                    phrase = (f'In the exact Voice Computer POC app, enter "In TextEdit, '
                              f'replace the test note at {unsafe_note} with '
                              f'\"{unsafe_text}\" and save it." once. Wait for the '
                              'preflight clarification; do not open or edit TextEdit.')
            if index == 24:
                run_id = uuid.uuid4().hex
                fixture_root = support / "TestFixtures" / run_id
                fixture_root.mkdir(parents=True, mode=0o700)
                finder_fixtures.append(fixture_root)
                textedit_fixture_root = fixture_root
                textedit_note = fixture_root / "note.txt"
                (fixture_root / "note-copy.txt").write_text("Decoy note")
                if args.textedit_mode == "cancel-save":
                    (fixture_root / "cancel_save").write_text(f"textedit:{run_id}\n")
                driver.textedit_note_uri = textedit_note.as_uri()
                driver.textedit_saved_text = f"Voice Computer saved {run_id}"
                textedit_windows_before = textedit_window_inventory()["window_ids"]
                if args.textedit_mode == "cancel-save" and textedit_windows_before:
                    raise RuntimeError("Canceled Save requires no initial TextEdit windows")
                textedit_sampler = TextEditWindowSampler()
                subprocess.run(["open", "-a", "TextEdit"], check=True, timeout=15)
                time.sleep(0.5)
                command = (f'In TextEdit, create the test note at {textedit_note} '
                           f'with "Voice Computer saved {run_id}" and save it.')
                phrase = (f'In the exact Voice Computer POC app, enter "{command}" '
                          'once. The test watcher approves TextEdit Computer Use; do not '
                          'bind or inspect UserNotificationCenter. Wait for the app result, '
                          'then inspect the exact TextEdit file URL and visible text. '
                          'Close only this test document, observe that it is absent, '
                          'reopen the same file through TextEdit, verify its saved text, '
                          'and close it again. Leave unrelated documents untouched.')
                if args.textedit_mode == "cancel-save":
                    phrase = (f'In the exact Voice Computer POC app, enter "{command}" '
                              'once. Approve only TextEdit Computer Use. Wait for the '
                              'unverified app result after the Save sheet is canceled. '
                              'Confirm no note.txt file or test document window remains. '
                              'Leave unrelated documents untouched.')
            if index == 20:
                phrase = ('In the exact Voice Computer POC app, enter "agent get desktop state" '
                          'in the command field and press Return once. Approve only the visible '
                          'desktop_tool.get_desktop_state read with Allow once. Wait for the '
                          'typed app result and report its Main Space ID, ordered IDs, '
                          'foreground bundle ID, and observation time. Do not switch Spaces.')
            space_before = space_state() if index in (7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24) else None
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
            driver.finder_context_observations = []
            driver.finder_run_id = finder_run_id
            driver.finder_decoy_run_id = finder_decoy_run_id
            driver.textedit_observations = []
            driver.record("command_started",
                          space_before=space_before, expected_space=expected_space)
            started = time.monotonic()
            stop_outcome = {}
            stop_thread = None
            if home_requested:
                stop_thread = threading.Thread(
                    target=stop_browser_when_home,
                    args=(home_requested, home_release, app_pid, session_log, log_offset,
                          app_since, stop_outcome), daemon=True)
                stop_thread.start()
            if index == 23 and args.textedit_mode == "stop-before-save":
                stop_thread = threading.Thread(
                    target=stop_textedit_before_approval,
                    args=(app_pid, session_log, log_offset, app_since, stop_outcome),
                    daemon=True)
                stop_thread.start()
            instruction = INSTRUCTION
            if index == 13:
                instruction = (
                    "Use only mcp__cua_repl.js for UI. First call: var vcProbeApp = await "
                    "cua.getApp('" + str(app_path) + "'); Reuse vcProbeApp. Verify its visible "
                    "Command and Run controls. "
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
                    "Use only mcp__cua_repl.js for UI. Your first Computer Use call must be "
                    "exactly: let vcSpaceApp = await cua.getApp('" + str(app_path) + "'); "
                    "Reuse vcSpaceApp; never assign to an undeclared app variable. "
                    "The driver has already checked the running executable; "
                    "do not inspect app metadata, object properties, or processes. If the first "
                    "tool response shows only Computer Use documentation, call vcSpaceApp.getAXState(). "
                    "Find the visible command field in its Accessibility state, enter the exact "
                    "quoted command, and submit once using Return. "
                    "Only if a desktop_tool.switch_space approval is visibly shown with the requested "
                    "direction, click Allow once. Do not choose session access or approve through protocol. "
                    "Wait for the visible app result. Do not switch Spaces yourself. If Computer Use "
                    "fails, report the error and stop; do not use a shell fallback. User request: "
                )
            elif index == 17:
                instruction = (
                    "Use only mcp__cua_repl.js for UI. First call: var vcBrowserApp = await "
                    "cua.getApp('" + str(app_path) + "'); Reuse vcBrowserApp. Enter the exact "
                    "quoted command and submit "
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
                if home_requested:
                    instruction = (
                        "Use only mcp__cua_repl.js for UI. First call: var vcBrowserApp = await "
                        "cua.getApp('" + str(app_path) + "'); Reuse vcBrowserApp. Enter the exact quoted command "
                        "and submit once with Return. Approve only Safari Computer Use through "
                        "the visible Allow for session button. The Home page may pause loading; "
                        "wait for the app's own Stop action to interrupt the run. Do not click "
                        "Stop yourself, follow Docs, or navigate Safari. After Voice Computer "
                        "finishes, report its visible stopped result and inspect Safari only to "
                        "close the new fixture tab. Never inspect the Codex or ChatGPT host app. "
                        "User request: "
                    )
            elif index == 18:
                instruction = (
                    "Use only mcp__cua_repl.js for UI. Start with this sole Computer Use call: "
                    "var vcFinderApp = await cua.getApp('" + str(app_path) + "'); Use this "
                    "fresh variable rather than an app variable from a prior case. First click "
                    "Diagnostic Log, refresh a full AX state, and click the Show File button "
                    "by its current index to open a Finder window. Do not parse an index from "
                    "a stale or diff-only tree; if Show File is absent, stop. Do not inspect "
                    "the log contents. Return to Voice "
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
                if args.finder_mode != "normal":
                    instruction = (
                        "Use only mcp__cua_repl.js for UI. Bind with cua.getApp to this exact "
                        "full app path: " + str(app_path) + ". Enter the quoted command and "
                        "submit once with Return. Wait for Voice Computer POC to finish routing, "
                        "then inspect its visible result. Do not bind, inspect, or control Finder; "
                        "the target is intentionally unsafe and must start no acting turn. "
                        "Never inspect or control the Codex or ChatGPT host app. User request: "
                    )
            elif index == 19:
                instruction = (
                    "Use only mcp__cua_repl.js for UI. First call: var vcComposedApp = await "
                    "cua.getApp('" + str(app_path) + "'); Reuse vcComposedApp. Enter the exact "
                    "quoted command and submit "
                    "it once with Return. Approve only Safari or Finder Computer Use through "
                    "the app's visible Allow for session button; decline any other target. "
                    "Wait for the app command to finish. Then independently inspect the Safari "
                    "fixture tab using cua.getApp('com.apple.Safari') and a full getAXState, "
                    "and the Finder selection using cua.getApp('com.apple.finder') and a full "
                    "getAXState. Do not navigate Safari or select the file yourself. Record "
                    "the exact Docs URL and heading and selected report URL. Safari is a native "
                    "app target here; never call cua.listTabs, cua.getBrowser, or createBrowserTab. "
                    "Close only the fixture Safari tab and Finder fixture window using their "
                    "visible native controls after recording evidence. If Finder has no other "
                    "window, close its fixture window in a final Computer Use call without "
                    "requesting another Finder AX state; the native observer verifies closure. "
                    "Never inspect the Codex or ChatGPT host app. User request: "
                )
                if args.finder_mode != "normal":
                    instruction = (
                        "Use only mcp__cua_repl.js for UI. First call: var vcComposedApp = await "
                        "cua.getApp('" + str(app_path) + "'); Reuse vcComposedApp. Enter the quoted command once and "
                        "press Return. The report target is intentionally unsafe. Wait for "
                        "Voice Computer to reject it, then report its visible result. Do not "
                        "bind Safari or Finder or approve an acting turn. User request: "
                    )
                elif args.browser_mode != "normal":
                    instruction = (
                        "Use only mcp__cua_repl.js for UI. First call: var vcComposedApp = await "
                        "cua.getApp('" + str(app_path) + "'); Reuse vcComposedApp. Enter the quoted command once and "
                        "press Return. Approve only Safari Computer Use through the app's "
                        "visible Allow for session button. Wait for the Browser failure; "
                        "do not open or inspect Finder. After Voice Computer finishes, "
                        "inspect the Safari fixture tab with cua.getApp('com.apple.Safari') "
                        "and getAXState without navigating it, then close only that tab using "
                        "Safari's native UI. Never call cua.listTabs, cua.getBrowser, or "
                        "createBrowserTab; those browser surfaces are unavailable. Never "
                        "inspect the Codex or ChatGPT host app. "
                        "User request: "
                    )
                if home_requested:
                    instruction = (
                        "Use only mcp__cua_repl.js for UI. First call: var vcComposedApp = await "
                        "cua.getApp('" + str(app_path) + "'); Reuse vcComposedApp. Enter the quoted command once and "
                        "press Return. Approve only Safari Computer Use through the app's "
                        "visible Allow for session button. The Home page may pause; wait "
                        "for the app's Stop action and report the stopped result. Do not "
                        "press Stop yourself, navigate Safari, bind Finder, or inspect Finder. Close only "
                        "the fixture Safari tab afterward using cua.getApp('com.apple.Safari') "
                        "and its native tab controls. Safari is a native app here: never call "
                        "cua.listTabs, cua.listBrowsers, cua.getBrowser, or createBrowserTab. "
                        "User request: "
                    )
            elif index == 20:
                instruction = (
                    "Use only mcp__cua_repl.js for UI. Your first Computer Use call must be "
                    "exactly: let vcStateApp = await cua.getApp('" + str(app_path) + "'); "
                    "Reuse vcStateApp for the rest of this case; do not assign to an "
                    "undeclared variable. Enter the exact quoted command and "
                    "submit once with Return. If the app visibly asks approval for "
                    "desktop_tool.get_desktop_state, choose Allow once only; do not approve "
                    "a Space move or session access. Wait for the app's typed result. Do not "
                    "switch Spaces yourself, inspect unrelated apps, or use a shell fallback. "
                    "User request: "
                )
            elif index == 21:
                final_path, final_heading = {
                    "normal": ("docs", f"Voice Computer Docs {fixture[0]}"),
                    "missing-link": ("home", f"Voice Computer Home {fixture[0]}"),
                    "home-404": ("home", "Fixture page not found"),
                    "redirect": ("error", "Fixture page not found"),
                    "stop-before-docs": ("home", ""),
                }[args.browser_mode]
                expected_page = (f"127.0.0.1:{fixture[1]}/{final_path}"
                                 f"?run_id={fixture[0]}")
                instruction = (
                    "Use only mcp__cua_repl.js for UI. Your first Computer Use call must be "
                    "var vcContextApp = await cua.getApp('" + str(app_path) + "'); "
                    "then use var vcContextSafari = await cua.getApp('com.apple.Safari'). "
                    "In Safari, press super+n once to create a new window; do not reuse or "
                    "navigate an existing window. Use Accessibility states without screenshots. "
                    "Read the new window's SafariWindow UUID, "
                    "enter the exact sentinel URL in its smart search field, and capture a "
                    "full getAXState({disableDiffing:true}) showing its URL and heading. "
                    "Return to vcContextApp and submit the quoted Voice Computer command once. "
                    "For Safari Computer Use inside that app, choose Allow for session; "
                    "decline any other target. Wait until the app result is no longer working. "
                    "Do not navigate Safari "
                    "yourself after submission. Once the app finishes, get a full Safari AX "
                    "state. Require the same window UUID, exact final URL " + expected_page +
                    " and heading " + final_heading + ", a two-tab "
                    "bar, and the Sentinel tab before closing anything. Close only the active "
                    "run-specific tab using its exposed close tab secondary action, then get a full "
                    "state showing the sentinel URL and heading in the same UUID. Close only "
                    "that test-created window through its visible close button; do not close "
                    "any unrelated Safari tab or window. If identity is ambiguous, stop and "
                    "report it without closing uncertain content. Never inspect or control the "
                    "Codex or ChatGPT host app. User request: "
                )
                if home_requested:
                    instruction = (
                        "Use only mcp__cua_repl.js for UI. First bind the exact app with "
                        "var vcContextApp = await cua.getApp('" + str(app_path) +
                        "'); then bind Safari with var vcContextSafari = await "
                        "cua.getApp('com.apple.Safari'). Press super+n once to create one new "
                        "Safari window, use Accessibility states without screenshots, load the "
                        "exact sentinel URL, and capture a "
                        "full AX state with its SafariWindow UUID. Return to vcContextApp "
                        "and submit the quoted command once. Grant Safari Computer Use "
                        "through Allow for session. Home may pause loading; wait for the "
                        "app's own Stop action. Do not press Stop yourself, follow Docs, or "
                        "navigate Safari. Once the app finishes, capture a full Safari AX "
                        "state. Close the new fixture tab only if its URL contains the exact "
                        "run ID and it belongs to the prepared window UUID. Capture a full "
                        "state proving the sentinel remains, then close only the prepared "
                        "window. If identity is ambiguous, leave it open and report that. "
                        "Never inspect the Codex or ChatGPT host app. User request: "
                    )
                if args.safari_context_windows == 2:
                    instruction = (
                        "Use only mcp__cua_repl.js for UI. First bind the exact app with "
                        "var vcContextApp = await cua.getApp('" + str(app_path) +
                        "'); then bind Safari with var vcContextSafari = await "
                        "cua.getApp('com.apple.Safari'). Press super+n to create a first "
                        "test-owned window, use Accessibility states without screenshots, "
                        "load the exact sentinel URL, "
                        "and capture a full AX state with its SafariWindow UUID. Press super+n "
                        "to create a second new window, load the same sentinel "
                        "URL, and capture its different UUID. The second window is the "
                        "intended one. Return to vcContextApp, submit the quoted command "
                        "once, and choose Allow for session only for Safari Computer Use. "
                        "After the app finishes, capture a full Safari AX state requiring "
                        "the second UUID, exact Docs URL and heading, two tabs, and its "
                        "sentinel. Close only that new run-specific Docs tab by its exposed "
                        "close tab action, then capture its restored sentinel state. Close "
                        "only the second test-created window. Inspect the first window with "
                        "a full AX state, require its original UUID and unchanged sentinel "
                        "without Docs, then close only that first test-created window. "
                        "If either window identity is ambiguous, leave it open. Do not "
                        "navigate Safari after submitting the app command or inspect the "
                    "Codex or ChatGPT host app. User request: "
                )
                if args.inject_inner_cua_failure:
                    instruction = (
                        "Use only mcp__cua_repl.js for UI. Bind the exact Voice Computer "
                        "app with cua.getApp('" + str(app_path) + "') and Safari with "
                        "cua.getApp('com.apple.Safari'). Create one new Safari window and "
                        "load the exact sentinel URL from the request. Capture its UUID and "
                        "sentinel state. Submit the quoted app command once and allow only "
                        "Safari Computer Use. Wait for the injected failure. Inspect the same "
                        "Safari UUID and require its sentinel URL and heading unchanged; no "
                        "Docs tab is expected. Close only that test-created Safari window "
                        "with its visible close button. Never inspect Codex or ChatGPT. "
                        "User request: "
                    )
            elif index == 22:
                instruction = (
                    "Use only mcp__cua_repl.js for UI. Your first Computer Use call must be "
                    "var vcFinderContextApp = await cua.getApp('" + str(app_path) + "'); "
                    "then use var vcFinderContext = await cua.getApp('com.apple.finder'). "
                    "In Finder, use the visible File menu's New Finder Window item. In that "
                    "new window use the visible Go menu's Go to Folder item to enter the "
                    "test folder path from the request, then switch to list view. Capture a "
                    "full getAXState({disableDiffing:true}) showing that folder's window "
                    "title, sentinel.txt, report.txt, and report-copy.txt without selecting "
                    "the report. Return to vcFinderContextApp and submit the quoted Voice "
                    "Computer command once. Choose Allow for session only for Finder Computer "
                    "Use inside the app; decline any other target. Wait until the app result "
                    "is no longer working. Then inspect Finder with a full AX state. Require "
                    "the same test folder window and exact selected report file URL. Do not "
                    "select the report yourself. Close only that test-created Finder window "
                    "using its visible close button. If window identity is ambiguous, stop "
                    "without closing unrelated windows. Never inspect or control the Codex "
                    "or ChatGPT host app. User request: "
                )
                if finder_prepared_by_host:
                    instruction = (
                        "Use only mcp__cua_repl.js for UI. First bind the exact Voice Computer "
                        "app with var vcFinderContextApp = await cua.getApp('" + str(app_path) +
                        "'); then bind Finder with var vcFinderContext = await "
                        "cua.getApp('com.apple.finder'). The test runner already opened one "
                        "test-owned Finder window on the folder named in the request. Do not "
                        "create another window. Switch that window to list view with super+2 "
                        "if needed, and capture a full AX state showing its title, sentinel.txt, "
                        "report.txt, and report-copy.txt without selecting report.txt. Use "
                        "that AX state for window identity; cua.listWindows is unavailable "
                        "on this Mac. Return to vcFinderContextApp and submit the "
                        "quoted command once. Choose Allow for session only for Finder Computer "
                        "Use inside the app. Wait for the app result, then inspect Finder with "
                        "a full AX state requiring the same prepared window and exact report "
                        "file URL. Do not select the report yourself. Close only that test-owned "
                        "Finder window with its visible close button in a final Computer Use "
                        "call. Do not ask Finder for another AX state after closing its last "
                        "window; the independent runner verifies window absence. If identity "
                        "is ambiguous, leave it open. Never inspect or control Codex or "
                        "ChatGPT. User request: "
                    )
                if args.finder_mode != "normal":
                    instruction = (
                        "Use only mcp__cua_repl.js for UI. First bind the exact Voice Computer "
                        "app with var vcFinderContextApp = await cua.getApp('" + str(app_path) +
                        "'); then bind Finder with var vcFinderContext = await "
                        "cua.getApp('com.apple.finder'). Use Finder's File menu to create one "
                        "new window. Use its Go menu's Go to Folder to show the test folder "
                        "from the request, switch to list view, and capture a full AX state "
                        "showing its window title and sentinel.txt. Do not select a file. "
                        "Return to vcFinderContextApp and submit the quoted command once. "
                        "The target is intentionally unsafe; the app must reject it before "
                        "any Finder acting turn. Do not approve Finder Computer Use inside the "
                        "app. After rejection, capture a full AX state of the same prepared "
                        "Finder window and its unchanged selection. Close only the test-created "
                        "window. Never inspect or control the Codex or ChatGPT host app. "
                        "User request: "
                    )
                if args.finder_context_windows == 2:
                    instruction = (
                        "Use only mcp__cua_repl.js for UI. First bind the exact app with "
                        "var vcFinderContextApp = await cua.getApp('" + str(app_path) +
                        "'); then bind Finder with var vcFinderContext = await "
                        "cua.getApp('com.apple.finder'). Create a first test-owned Finder "
                        "window with File > New Finder Window. Use Go > Go to Folder to "
                        "show the decoy folder from the request in list view. Capture a "
                        "full AX state showing its title, sentinel.txt, and no selected "
                        "report. Create a second new Finder window, show the intended test "
                        "folder from the request in list view, and capture its different "
                        "title, sentinel.txt, report.txt, and no selected report. Return "
                        "to vcFinderContextApp and submit the quoted command once. Choose "
                        "Allow for session only for Finder Computer Use. After the app "
                        "finishes, capture a full Finder AX state requiring the second "
                        "window and exact selected report URL. Do not select it yourself. "
                        "Close only the second test-created window, then inspect the first "
                        "window with a full AX state showing its unchanged sentinel and "
                        "selection. Close only that first test-created window. If either "
                        "identity is ambiguous, leave it open. Never inspect the Codex "
                        "or ChatGPT host app. User request: "
                    )
                if args.inject_inner_cua_failure:
                    instruction = (
                        "Use only mcp__cua_repl.js for UI. Bind the exact Voice Computer "
                        "app with cua.getApp('" + str(app_path) + "') and Finder with "
                        "cua.getApp('com.apple.finder'). Create one new Finder window, show "
                        "the test folder in list view, and capture its title, sentinel.txt, "
                        "and unselected report in a full getAXState({disableDiffing:true}). "
                        "Submit the quoted app command once and allow only Finder Computer "
                        "Use. Wait for the injected failure. Capture a second full "
                        "getAXState({disableDiffing:true}) requiring the same test folder "
                        "window, unchanged sentinel and selection, "
                        "then close only that test-created Finder window with its visible "
                        "close button. Never inspect Codex or ChatGPT. User request: "
                    )
            elif index == 23:
                instruction = (
                    "Use only mcp__cua_repl.js for UI. First bind to the exact Voice Computer "
                    "app path with cua.getApp('" + str(app_path) + "'). Enter the quoted command "
                    "once and press Return. Approve only TextEdit Computer Use through the "
                    "visible Allow for session button. Wait for the app's finished result; "
                    "do not edit the note yourself. Then bind with cua.getApp('com.apple.TextEdit') "
                    "and capture a full Accessibility state showing the exact note.txt URL "
                    "and saved text. Close only that URL-matched test document with its visible "
                    "close button. In a separate Computer Use call, capture a full TextEdit "
                    "state immediately after closing and before reopening; require no note.txt "
                    "window. Reopen the same exact path through TextEdit's Open dialog "
                    "using the CUA key name super+shift+g (never CMD), then capture a full "
                    "state showing its URL and "
                    "saved text. Close only the reopened test document. Leave other TextEdit "
                    "windows untouched. Never inspect Codex or ChatGPT. User request: "
                )
                if args.inject_inner_cua_failure:
                    instruction = (
                        "Use only mcp__cua_repl.js for UI. Bind the exact Voice Computer "
                        "app path with cua.getApp('" + str(app_path) + "'). Enter the quoted "
                        "command once and press Return. Approve only TextEdit Computer Use. "
                        "Wait for the injected tool failure and do not open or edit the note "
                        "yourself. Leave all TextEdit windows untouched. Never inspect Codex "
                        "or ChatGPT. User request: "
                    )
                elif args.textedit_mode == "stop-before-save":
                    instruction = (
                        "Use only mcp__cua_repl.js for UI. Bind the exact Voice Computer "
                        "app path with cua.getApp('" + str(app_path) + "'). Enter the quoted "
                        "command once and press Return. Do not approve the TextEdit "
                        "Computer Use request. The independent test watcher presses the "
                        "app's Stop button as soon as approval appears. Wait for the "
                        "interrupted app result. Do not open or edit TextEdit yourself. "
                        "Never inspect Codex or ChatGPT. User request: "
                    )
                elif args.textedit_mode in ("wrong-file", "wrong-text"):
                    instruction = (
                        "Use only mcp__cua_repl.js for UI. Bind the exact Voice Computer "
                        "app path with cua.getApp('" + str(app_path) + "'). Enter the quoted "
                        "command once and press Return. Wait for its clarification. Do not "
                        "approve TextEdit, open a document, or edit any file. Never inspect "
                        "Codex or ChatGPT. User request: "
                    )
                elif args.textedit_context_windows:
                    decoy_prelude = (
                        "The decoy is already open in a separate TextEdit window; "
                        "capture a full AX state with its URL and Decoy note text. Leave "
                        "that window open. " if args.textedit_context_windows == 2 else "")
                    decoy_epilogue = (
                        "Capture the still-open decoy URL and text, then close only its "
                        "window. " if args.textedit_context_windows == 2 else "")
                    instruction = (
                        "Use only mcp__cua_repl.js for UI. Bind TextEdit with "
                        "cua.getApp('com.apple.TextEdit'). " + decoy_prelude +
                        "The exact note is already open. Capture a full AX state showing "
                        "its URL and draft text before the command. Bind the exact "
                        "Voice Computer app with cua.getApp('" + str(app_path) + "'). "
                        "Enter the quoted command once, press Return, approve only "
                        "TextEdit Computer Use, then wait 15 seconds without another "
                        "Computer Use call before inspecting the app's finished result. Do not "
                        "edit either note yourself. Capture full TextEdit AX state showing "
                        "the exact note URL and saved text in the same prepared window. "
                        "Close only that URL-matched window with its visible close button. "
                        "In a separate call capture a full state with no note.txt window. "
                        "Reopen the same path through TextEdit's Open dialog, capture a "
                        "full state with its URL and saved text. In a separate read-only "
                        "Computer Use call capture that same reopened document again. "
                        "Wait five seconds with that window open, then close only that note. "
                        + decoy_epilogue + "Leave unrelated TextEdit windows untouched. "
                        "Never inspect Codex or ChatGPT. User request: "
                    )
            elif index == 24:
                instruction = (
                    "Use only mcp__cua_repl.js for UI. First bind to the exact Voice Computer "
                    "app path with cua.getApp('" + str(app_path) + "'). Enter the quoted command "
                    "once and press Return. Approve only TextEdit Computer Use through the "
                    "visible Allow for session button. Wait for the app's finished result; "
                    "do not create or edit the note yourself. Then bind TextEdit with "
                    "cua.getApp('com.apple.TextEdit') and capture full Accessibility state "
                    "showing the exact note.txt URL and saved text. Close only that URL-matched "
                    "test document using its visible close button. In a separate Computer Use "
                    "call require a full state with no note.txt window. Reopen the same exact "
                    "path through TextEdit's Open dialog using super+shift+g, capture full "
                    "state showing its URL and saved text, then close only that reopened "
                    "document. Leave other TextEdit windows untouched. Never inspect Codex "
                    "or ChatGPT. User request: "
                )
                if args.textedit_mode == "cancel-save":
                    instruction = (
                        "Use only mcp__cua_repl.js for UI. Bind the exact Voice Computer "
                        "app path with cua.getApp('" + str(app_path) + "'). Enter the quoted "
                        "command once and press Return. Approve only TextEdit Computer Use. "
                        "Keep inspecting only the app until its TextEdit approval appears, "
                        "then choose Allow for session. After that approval, wait 75 seconds "
                        "without inspecting Voice Computer. Then use one Computer Use call "
                        "for TextEdit: inside JavaScript try to bind "
                        "cua.getApp('com.apple.TextEdit'), inspect its AX state, and press "
                        "Escape only if its Open dialog is visible. Catch only a "
                        "noWindowsAvailable error inside that same JavaScript call and write "
                        "that TextEdit is already empty; rethrow any other error. Do not "
                        "request another TextEdit state after Escape. The independent "
                        "runner reads the app's correlated "
                        "diagnostic receipt and exact file and window state. Do not create, "
                        "edit, or inspect the note yourself. Leave other documents untouched. "
                        "Never inspect Codex or ChatGPT. "
                        "User request: "
                    )
            response = driver.wait_rpc(driver.rpc("turn/start", {
                "threadId": thread, "input": [{"type": "text", "text": instruction + phrase}],
            }))
            turn = driver.wait_turn(seconds=300 if index in (19, 21, 22, 23, 24) else 180)
            if stop_thread:
                stop_thread.join(timeout=85)
                if stop_thread.is_alive() or not stop_outcome.get("pressed"):
                    raise RuntimeError("Fixture Stop watchdog failed: %s" %
                                       stop_outcome.get("error", "watchdog still running"))
                if home_requested:
                    # Give any late browser request a bounded chance to reach the fixture.
                    time.sleep(1)
            space_after = None
            if expected_space is not None:
                for _ in range(10):
                    space_after = space_state()
                    if space_after and space_after["current"] == expected_space:
                        break
                    time.sleep(0.5)
            elif index in (13, 17, 18, 19, 20, 21, 22, 23, 24):
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
                        if home_requested:
                            exact_receipt = verify_browser_interruption_receipt(
                                rows, run_id, fixture_rows, space_before["current"],
                                after_id, prior_ids)
                        else:
                            exact_receipt = verify_browser_receipt(
                                rows, run_id, port, fixture_rows, driver.browser_observations,
                                space_before["current"], after_id, prior_ids,
                                mode=args.browser_mode)
                        driver.record("browser_receipt_verified", **exact_receipt)
                    elif index == 18:
                        if args.finder_mode == "normal":
                            exact_receipt = verify_finder_receipt(
                                rows, report, driver.finder_observations,
                                space_before["current"], after_id, prior_ids)
                            driver.record("finder_receipt_verified", **exact_receipt)
                        else:
                            exact_receipt = verify_finder_rejection_receipt(
                                rows, report, space_before["current"], after_id, prior_ids,
                                mode=args.finder_mode)
                            driver.record("finder_rejection_receipt_verified", **exact_receipt)
                    elif index == 19:
                        run_id, port, fixture_log = fixture
                        fixture_rows = [json.loads(line) for line in fixture_log.read_text().splitlines()]
                        if args.finder_mode != "normal":
                            exact_receipt = verify_composed_rejection_receipt(
                                rows, fixture_rows, space_before["current"], after_id,
                                prior_ids, mode=args.finder_mode)
                        elif args.browser_mode != "normal":
                            exact_receipt = verify_composed_failure_receipt(
                                rows, run_id, fixture_rows, space_before["current"],
                                after_id, prior_ids, mode=args.browser_mode)
                        else:
                            finder_windows_after = finder_window_inventory()["window_ids"]
                            exact_receipt = verify_composed_receipt(
                                rows, run_id, port, fixture_rows, report,
                                driver.browser_observations, driver.finder_observations,
                                space_before["current"], after_id, prior_ids,
                                finder_windows_before, finder_windows_after)
                        driver.record("composed_receipt_verified", **exact_receipt)
                    elif index == 20:
                        independent_frontmost = frontmost_bundle_id()
                        exact_receipt = verify_desktop_state_receipt(
                            rows, space_before, space_after, independent_frontmost,
                            prior_ids)
                        driver.record("desktop_state_receipt_verified", **exact_receipt)
                    elif index == 21:
                        run_id, port, fixture_log = fixture
                        fixture_rows = [json.loads(line) for line in fixture_log.read_text().splitlines()]
                        driver.record("safari_context_requests_observed",
                                      paths=[entry.get("path") for entry in fixture_rows])
                        safari_windows_after = safari_window_ids()
                        if args.inject_inner_cua_failure:
                            exact_receipt = verify_injected_cua_failure_receipt(
                                rows, run_id, "browser", space_before["current"],
                                after_id, prior_ids)
                            exact_receipt["context_window_id"] = verify_injected_safari_context(
                                run_id, port, fixture_rows, driver.browser_observations,
                                safari_windows_before, safari_windows_after)
                            driver.record("safari_context_injected_failure_verified",
                                          **exact_receipt)
                        elif home_requested:
                            exact_receipt = verify_safari_context_interruption_receipt(
                                rows, run_id, port, fixture_rows,
                                driver.browser_observations, safari_windows_before,
                                safari_windows_after, space_before["current"], after_id,
                                prior_ids)
                        else:
                            exact_receipt = verify_safari_context_receipt(
                                rows, run_id, port, fixture_rows,
                                driver.browser_observations, safari_windows_before,
                                safari_windows_after, space_before["current"], after_id,
                                prior_ids, mode=args.browser_mode,
                                sentinel_count=args.safari_context_windows)
                        driver.record("safari_context_receipt_verified", **exact_receipt)
                    elif index == 22:
                        finder_windows_after = finder_window_inventory()["window_ids"]
                        if args.inject_inner_cua_failure:
                            exact_receipt = verify_injected_cua_failure_receipt(
                                rows, finder_run_id, "finder", space_before["current"],
                                after_id, prior_ids)
                            exact_receipt["context_window_id"] = verify_injected_finder_context(
                                report, driver.finder_context_observations,
                                finder_windows_before, finder_windows_after)
                            driver.record("finder_context_injected_failure_verified",
                                          **exact_receipt)
                        elif args.finder_mode == "normal":
                            exact_receipt = verify_finder_context_receipt(
                                rows, report, driver.finder_context_observations,
                                finder_windows_before, finder_windows_after,
                                space_before["current"], after_id, prior_ids,
                                decoy_report=finder_decoy_report)
                        else:
                            exact_receipt = verify_finder_context_rejection_receipt(
                                rows, report, driver.finder_context_observations,
                                finder_windows_before, finder_windows_after,
                                space_before["current"], after_id, prior_ids,
                                mode=args.finder_mode)
                        driver.record("finder_context_receipt_verified", **exact_receipt)
                    elif index in (23, 24):
                        textedit_windows_after = textedit_window_inventory()["window_ids"]
                        textedit_transitions = []
                        if textedit_sampler is not None:
                            textedit_transitions = textedit_sampler.stop()
                            textedit_sampler = None
                            for transition in textedit_transitions:
                                driver.record("textedit_window_transition", **transition)
                        if index == 24 and args.textedit_mode == "cancel-save":
                            exact_receipt = verify_textedit_cancel_receipt(
                                rows, textedit_note, textedit_transitions,
                                textedit_windows_before, textedit_windows_after,
                                space_before["current"], after_id, prior_ids)
                            driver.record("textedit_cancel_save_verified", **exact_receipt)
                        elif args.inject_inner_cua_failure:
                            exact_receipt = verify_injected_cua_failure_receipt(
                                rows, textedit_note.parent.name, "textedit",
                                space_before["current"], after_id, prior_ids)
                            expected_draft = f"Voice Computer draft {textedit_note.parent.name}"
                            if textedit_note.read_bytes() != expected_draft.encode() \
                                    or (textedit_note.parent / "note-copy.txt").read_bytes() \
                                    != b"Decoy note":
                                raise ValueError("Injected TextEdit failure changed fixture bytes")
                            if textedit_windows_after != textedit_windows_before:
                                raise ValueError("Injected TextEdit failure changed document windows")
                            driver.record("textedit_injected_failure_verified", **exact_receipt)
                        elif args.textedit_mode == "stop-before-save":
                            exact_receipt = verify_textedit_stop_receipt(
                                rows, textedit_note, textedit_windows_before,
                                textedit_windows_after, space_before["current"],
                                after_id, prior_ids)
                            driver.record("textedit_stop_before_save_verified", **exact_receipt)
                        elif args.textedit_mode in ("wrong-file", "wrong-text"):
                            exact_receipt = verify_textedit_rejection_receipt(
                                rows, textedit_note, textedit_windows_before,
                                textedit_windows_after, space_before["current"],
                                after_id, prior_ids)
                            driver.record("textedit_rejection_receipt_verified", **exact_receipt)
                        else:
                            exact_receipt = verify_textedit_receipt(
                                rows, textedit_note, driver.textedit_observations,
                                textedit_windows_before, textedit_windows_after,
                                space_before["current"], after_id, prior_ids,
                                context_windows=args.textedit_context_windows,
                                verifier_failure=args.textedit_mode == "verifier-failure",
                                window_transitions=textedit_transitions,
                                created=index == 24)
                            driver.record("textedit_context_receipt_verified", **exact_receipt)
                    else:
                        exact_receipt = verify_mcp_receipt(
                            rows, mcp_case_phrase(index), MCP_CASES[index],
                            space_before["current"], expected_space, after_id, prior_ids)
                        driver.record("mcp_receipt_verified", **exact_receipt)
                except (OSError, ValueError) as error:
                    driver.record("exact_app_receipt_rejected", reason=str(error))
                    verified = False
                else:
                    verified = exact_receipt is not None and (verified or index in (13, 17, 18, 19, 20, 21, 22, 23, 24))
            recovered_stale_ui = (
                index == 13 and exact_receipt is not None
                and driver.tool_failures == ["stale_ui_state"])
            if recovered_stale_ui:
                driver.record("stale_ui_state_recovered")
            success = (turn.get("status") == "completed" and verified
                       and (not driver.tool_failures or recovered_stale_ui)
                       and all(a["allowed"] for a in driver.approvals)
                       and (expected_space is not None or index in (17, 18, 19, 20, 21, 22, 23, 24) or not negative_result))
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
        if textedit_sampler is not None:
            try:
                transitions = textedit_sampler.stop()
                driver.record("textedit_window_sampler_stopped",
                              transition_count=len(transitions))
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                driver.record("textedit_window_sampler_failed",
                              error_type=type(error).__name__)
                failed = True
        for server, thread, temporary, release in fixtures:
            if release:
                release.set()
            server.shutdown()
            server.server_close()
            thread.join(timeout=3)
            temporary.cleanup()
        if fixtures:
            driver.record("fixtures_cleaned", count=len(fixtures))
        cleaned_directories = 0
        for directory in finder_fixtures:
            if directory == textedit_fixture_root:
                try:
                    restored = (textedit_windows_before is not None and
                                textedit_window_inventory()["window_ids"] ==
                                textedit_windows_before)
                except (OSError, subprocess.SubprocessError, ValueError, KeyError):
                    restored = False
                if not restored:
                    driver.record("textedit_fixture_retained", path=str(directory),
                                  reason="document_window_inventory_not_restored")
                    continue
            shutil.rmtree(directory)
            cleaned_directories += 1
        for directory in finder_outside_fixtures:
            directory.cleanup()
        if finder_fixtures:
            driver.record("finder_fixtures_cleaned", count=cleaned_directories)
        driver.close()
        print("Log: %s" % args.log, flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
