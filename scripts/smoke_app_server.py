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
import subprocess
import sys
import threading
import time
from datetime import datetime, timezone
from pathlib import Path


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
]
CASE_APP = ["Safari", "Calculator", "TextEdit", "Finder", "Voice Computer POC", "Voice Computer POC", "Finder", "Finder", "Voice Computer POC", "Voice Computer POC", "Mission Control", "Finder", "Voice Computer POC", "Voice Computer POC"]
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
    except (OSError, subprocess.SubprocessError):
        return None
    match = re.search(r'"CGSSessionScreenIsLocked"=(Yes|No)', output)
    return match.group(1) == "Yes" if match else None


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


class Driver:
    def __init__(self, executable, log_path, trace_tool_output=False):
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
                    self.record("server_stderr", line=line.rstrip()[:2000])
                elif self.stderr_lines == 200:
                    self.record("server_stderr_limit_reached")
                self.stderr_lines += 1
                continue
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                self.record("unreadable_server_message", line=line[:2000])
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
            and app == CASE_APP[self.command_index - 1]
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
            self.tool_calls += 1
            limit = 24 if self.command_index in (6, 9, 10, 14) else 12
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
                if self.trace_tool_output:
                    self.record("tool_output_trace", item_id=item.get("id"),
                                excerpt="\n".join(str(part.get("text") or "") for part in content)[:3000])
                if item.get("status") == "failed" or result.get("isError"):
                    error = error or next((part.get("text") for part in content if part.get("text")), None)
                    self.tool_failures.append(str(error or "Unknown tool error")[:500])
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
                    error=str(error or "")[:2000],
                )
        elif method == "turn/completed":
            turn = params.get("turn") or {}
            self.record("turn_completed", turn_id=turn.get("id"), status=turn.get("status"),
                        result=self.last_result[:2000], error=turn.get("error"))
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--codex", default=default_codex())
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--trace-tool-output", action="store_true",
                        help="Record bounded tool input/output excerpts; may contain private UI text")
    parser.add_argument("--case", type=int, action="append", choices=range(1, len(COMMANDS) + 1),
                        help="Run one numbered command; repeat to select multiple")
    args = parser.parse_args()
    os.umask(0o077)
    args.log.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    driver = Driver(args.codex, args.log, trace_tool_output=args.trace_tool_output)
    failed = False
    try:
        locked = screen_is_locked()
        driver.record("environment_check", screen_locked=locked)
        if locked:
            print("SMOKE BLOCKED: the macOS desktop session is locked", file=sys.stderr)
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
        for index in args.case or range(1, 7):
            phrase = COMMANDS[index - 1]
            space_before = space_state() if index in (7, 8, 9, 10, 11, 12, 14) else None
            expected_space = None
            if index in (7, 8, 9, 10, 11, 12, 14):
                if space_before is None:
                    raise RuntimeError("Cannot read current desktop Space before case %s" % index)
                ordered = space_before["ordered"]
                position = ordered.index(space_before["current"])
                destination = position + (1 if index in (7, 9, 10, 11, 12) else -1)
                if not 0 <= destination < len(ordered):
                    driver.command_index = index
                    driver.record("command_skipped", reason="No adjacent desktop Space",
                                  space_before=space_before)
                    print("%s. SKIP: no adjacent desktop Space for this direction" % index,
                          flush=True)
                    failed = True
                    continue
                expected_space = (space_before["current"] if index == 10
                                  else ordered[destination])
            driver.command_index = index
            driver.last_result = ""
            driver.completed_turn = None
            driver.tool_failures = []
            driver.evidence_matches = []
            driver.tool_calls = 0
            driver.approvals = []
            driver.record("command_started", phrase=phrase,
                          space_before=space_before, expected_space=expected_space)
            started = time.monotonic()
            response = driver.wait_rpc(driver.rpc("turn/start", {
                "threadId": thread, "input": [{"type": "text", "text": INSTRUCTION + phrase}],
            }))
            turn = driver.wait_turn()
            space_after = None
            if expected_space is not None:
                for _ in range(10):
                    space_after = space_state()
                    if space_after and space_after["current"] == expected_space:
                        break
                    time.sleep(0.5)
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
            success = (turn.get("status") == "completed" and verified
                       and not driver.tool_failures
                       and all(a["allowed"] for a in driver.approvals)
                       and (expected_space is not None or not negative_result))
            driver.record("command_finished", success=success,
                          elapsed_ms=round((time.monotonic() - started) * 1000),
                          tool_failures=driver.tool_failures, approvals=driver.approvals,
                          evidence_matches=driver.evidence_matches,
                          space_before=space_before, space_after=space_after,
                          expected_space=expected_space,
                          turn_id=(response.get("turn") or {}).get("id"))
            print("%s. %s: %s" % (index, "PASS" if success else "FAIL", phrase), flush=True)
            print("   %s" % driver.last_result.replace("\n", " ")[:500], flush=True)
            failed = failed or not success
    except Exception as error:
        failed = True
        driver.record("driver_error", error=str(error))
        print("SMOKE ERROR: %s" % error, file=sys.stderr)
    except KeyboardInterrupt:
        failed = True
        driver.record("driver_interrupted")
        print("Smoke test interrupted", file=sys.stderr)
    finally:
        driver.close()
        print("Log: %s" % args.log, flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
