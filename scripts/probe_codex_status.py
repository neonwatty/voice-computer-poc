#!/usr/bin/env python3
"""Probe whether a separate app-server can read a Codex task's live state."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re

from smoke_app_server import Driver, default_codex


THREAD_ID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")


def interpret_status(thread):
    status = thread.get("status") or {}
    kind = status.get("type") if isinstance(status, dict) else None
    if kind == "notLoaded":
        return "unavailable_cross_process"
    if kind in {"active", "idle", "systemError"}:
        return "observed_in_probe_process"
    return "unknown"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--thread-id", required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--codex", default=default_codex())
    args = parser.parse_args()
    if not THREAD_ID.fullmatch(args.thread_id):
        parser.error("--thread-id must be an exact Codex UUID")
    os.umask(0o077)
    args.log.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    driver = Driver(args.codex, args.log)
    try:
        driver.wait_rpc(driver.rpc("initialize", {"clientInfo": {
            "name": "voice_status_probe", "title": "Voice Status Probe", "version": "0.1.0",
        }}))
        driver.send({"method": "initialized", "params": {}})
        try:
            result = driver.wait_rpc(driver.rpc("thread/read", {
                "threadId": args.thread_id, "includeTurns": False,
            }))
        except RuntimeError as error:
            if "thread not loaded:" not in str(error):
                raise
            report = {
                "thread_id": args.thread_id,
                "interpretation": "unknown_or_unavailable",
                "observed_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            }
            driver.record("codex_status_probe", **report)
            print(json.dumps(report, sort_keys=True))
            return 2
        thread = result.get("thread") or {}
        if thread.get("id") != args.thread_id:
            raise ValueError("thread/read returned a different task ID")
        report = {
            "thread_id": args.thread_id,
            "source": thread.get("source"),
            "protocol_status": (thread.get("status") or {}).get("type"),
            "interpretation": interpret_status(thread),
            "observed_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        }
        driver.record("codex_status_probe", **report)
        print(json.dumps(report, sort_keys=True))
        return 0
    finally:
        driver.close()


if __name__ == "__main__":
    raise SystemExit(main())
