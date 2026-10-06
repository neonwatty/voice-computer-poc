#!/usr/bin/env python3
"""Build one clean commit and run its unlocked-Mac desktop suite once."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time
import uuid

from smoke_app_server import (exact_build_identity, finder_window_inventory,
                              process_start_identity, running_app_pids,
                              safari_window_ids, screen_is_locked, selected_cases,
                              space_state)


ROOT = Path(__file__).resolve().parents[1]
SHA = re.compile(r"[0-9a-f]{40}\Z")


def git_output(*arguments):
    return subprocess.run(["git", *arguments], cwd=ROOT, check=True,
                          capture_output=True, text=True, timeout=15).stdout.strip()


def validate_checkout(sha):
    if not SHA.fullmatch(sha):
        raise ValueError("--sha must be an exact lowercase 40-character commit SHA")
    if git_output("rev-parse", "HEAD") != sha:
        raise ValueError("Checkout HEAD does not match --sha")
    if git_output("status", "--porcelain"):
        raise ValueError("Desktop suite requires a clean checkout")


def voice_processes():
    listing = subprocess.run(["ps", "-axo", "pid=,comm="], check=True,
                             capture_output=True, text=True, timeout=10).stdout
    return [int(match.group(1)) for line in listing.splitlines()
            if (match := re.fullmatch(r"\s*(\d+)\s+(.+?)\s*", line))
            and "/VoiceComputerPOC.app/Contents/MacOS/VoiceComputerPOC" in match.group(2)]


def run_gate(name, command, log_directory, timeout=1800):
    path = log_directory / f"{name}.log"
    with path.open("x", encoding="utf-8") as handle:
        print(f"Running {name}…", flush=True)
        result = subprocess.run(command, cwd=ROOT, stdout=handle,
                                stderr=subprocess.STDOUT, timeout=timeout,
                                check=False)
    if result.returncode:
        raise RuntimeError(f"{name} failed (exit {result.returncode}); see {path}")
    return path


def static_gate(derived_data, log_directory):
    run_gate("python-tests", [sys.executable, "-m", "unittest", "discover",
                              "-s", "scripts", "-p", "test_*.py"], log_directory)
    run_gate("swift-package", ["swift", "test", "--package-path", "DesktopToolServer"],
             log_directory)
    run_gate("swift-format", ["xcrun", "swift-format", "lint", "--strict",
                              "--recursive", "VoiceComputerPOC", "VoiceComputerPOCTests",
                              "DesktopToolServer"], log_directory)
    for helper in ("observe_safari_windows.swift", "observe_finder_windows.swift"):
        run_gate(helper.removesuffix(".swift") + "-typecheck",
                 ["swiftc", "-typecheck", str(ROOT / "scripts" / helper)],
                 log_directory)
    run_gate("xcode-debug-tests", [
        "xcodebuild", "-quiet", "-project", "VoiceComputerPOC.xcodeproj",
        "-scheme", "VoiceComputerPOC", "-configuration", "Debug",
        "-destination", "platform=macOS,arch=arm64",
        "-derivedDataPath", str(derived_data), "-parallel-testing-enabled", "NO",
        "test", "CODE_SIGNING_ALLOWED=NO",
    ], log_directory)
    run_gate("xcode-release-tests", [
        "xcodebuild", "-quiet", "-project", "VoiceComputerPOC.xcodeproj",
        "-scheme", "VoiceComputerPOC", "-configuration", "Release",
        "-destination", "platform=macOS,arch=arm64",
        "-derivedDataPath", str(derived_data), "-parallel-testing-enabled", "NO",
        "test", "CODE_SIGNING_ALLOWED=NO", "ENABLE_TESTABILITY=YES",
    ], log_directory)


def launch_exact_app(app_path):
    if voice_processes():
        raise RuntimeError("Another Voice Computer app process is already running")
    subprocess.run(["open", "-a", str(app_path)], check=True, timeout=20)
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        pids = running_app_pids(app_path)
        if len(pids) == 1 and voice_processes() == pids:
            return pids[0], process_start_identity(pids[0])
        time.sleep(0.25)
    raise RuntimeError("Exact app did not start as the sole Voice Computer process")


def summarize_smoke(path, expected_cases):
    rows = [json.loads(line) for line in path.read_text().splitlines()]
    finished = [row for row in rows if row.get("event") == "command_finished"]
    cases = [row.get("command_index") for row in finished]
    if cases != expected_cases or any(row.get("success") is not True for row in finished):
        raise ValueError("Machine receipt lacks the complete ordered passing suite")
    first, last = finished[0], finished[-1]
    start = (first.get("space_before") or {}).get("current")
    end = (last.get("space_after") or {}).get("current")
    if not isinstance(start, int) or end != start:
        raise ValueError("Machine suite did not return to its starting Space")
    if not any(row.get("event") == "safari_context_receipt_verified" for row in rows) \
            or not any(row.get("event") == "finder_context_receipt_verified" for row in rows):
        raise ValueError("Machine suite is missing context-window evidence")
    return {"case_ids": cases, "starting_space_id": start,
            "final_space_id": end, "all_cases_passed": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sha", required=True, help="Exact clean checkout commit")
    parser.add_argument("--derived-data-path", type=Path, required=True,
                        help="Absolute dedicated Xcode build directory")
    parser.add_argument("--log-directory", type=Path,
                        help="Private output directory; defaults under Application Support")
    args = parser.parse_args()
    os.umask(0o077)
    app_pid = None
    summary = {"sha": args.sha, "status": "failed"}
    try:
        validate_checkout(args.sha)
        if not args.derived_data_path.is_absolute():
            raise ValueError("--derived-data-path must be absolute")
        if screen_is_locked() is not False or space_state() is None:
            raise RuntimeError("Unlocked, readable Main desktop Space is required")
        if voice_processes():
            raise RuntimeError("Quit other Voice Computer copies before the exact-build run")
        log_directory = args.log_directory or (
            Path.home() / "Library/Application Support/VoiceComputerPOC/SmokeRuns" /
            f"{args.sha[:12]}-{uuid.uuid4().hex}")
        log_directory.mkdir(parents=True, mode=0o700, exist_ok=False)
        if log_directory.is_symlink() or log_directory.resolve() != log_directory:
            raise ValueError("Log directory must be a new canonical directory")
        summary["started_at"] = datetime.now(timezone.utc).isoformat()
        safari_before = safari_window_ids()
        finder_before = finder_window_inventory()["window_ids"]
        start_space = space_state()
        static_gate(args.derived_data_path, log_directory)
        app_path = args.derived_data_path / "Build/Products/Debug/VoiceComputerPOC.app"
        identity = exact_build_identity(app_path)
        if identity["source_sha"] != args.sha or not identity["source_clean"]:
            raise ValueError("Built app identity no longer matches clean source")
        app_pid, app_start = launch_exact_app(app_path)
        receipt = log_directory / "machine.jsonl"
        run_gate("machine-output", [sys.executable, str(ROOT / "scripts/smoke_app_server.py"),
                                    "--suite", "--app-path", str(app_path),
                                    "--log", str(receipt)], log_directory, timeout=2700)
        evidence = summarize_smoke(receipt, selected_cases(True, None, False))
        if running_app_pids(app_path) != [app_pid] \
                or process_start_identity(app_pid) != app_start:
            raise ValueError("App process identity changed during the machine suite")
        if safari_window_ids() != safari_before \
                or finder_window_inventory()["window_ids"] != finder_before:
            raise ValueError("Safari or Finder window inventory changed during the suite")
        if space_state() != start_space:
            raise ValueError("Main desktop Space state changed after the suite")
        summary.update(evidence)
        summary.update(status="passed", app_sha256=identity["app_sha256"],
                       helper_sha256=identity["helper_sha256"],
                       app_pid=app_pid, macos_version=identity["macos_version"])
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        summary["failure"] = str(error)
    finally:
        if app_pid is not None and app_pid in voice_processes():
            os.kill(app_pid, signal.SIGTERM)
        summary["finished_at"] = datetime.now(timezone.utc).isoformat()
        if "log_directory" in locals():
            output = log_directory / "summary.json"
            output.write_text(json.dumps(summary, sort_keys=True, indent=2) + "\n")
            print(f"Private receipt: {output}", flush=True)
        print(f"Desktop suite: {summary['status']}", flush=True)
        if summary.get("failure"):
            print(summary["failure"], file=sys.stderr)
    return 0 if summary["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
