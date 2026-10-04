#!/usr/bin/env python3
"""Evaluate the production one-phrase router and compiled route contract."""
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
EVALS = ROOT / "evals"
FIXTURES = json.loads((EVALS / "router-v4.json").read_text())
INSTRUCTION = (EVALS / "router-instruction.txt").read_text()
CLI_ARGS = json.loads((EVALS / "router-cli-args.json").read_text())
SCHEMA = EVALS / "router-output.schema.json"


def executable():
    home = Path.home()
    for path in (home / ".local/bin/codex", Path("/Applications/Codex.app/Contents/Resources/codex"),
                 Path("/Applications/ChatGPT.app/Contents/Resources/codex"),
                 Path("/opt/homebrew/bin/codex"), Path("/usr/local/bin/codex")):
        if os.access(path, os.X_OK):
            return str(path)
    raise RuntimeError("Codex executable unavailable")


def tool_free_trace(text):
    completed = False
    for line in text.splitlines():
        event = json.loads(line)
        kind = event.get("type", "")
        if kind == "turn.completed":
            completed = True
        if kind.startswith("item.") and event.get("item", {}).get("type") not in ("agent_message", "reasoning"):
            return False
    return completed


def classify(job):
    index, trial = job
    phrase = FIXTURES[index]["phrase"]
    with tempfile.TemporaryDirectory(prefix="voice-router-eval-") as temp:
        answer = Path(temp) / "answer.json"
        cmd = [executable(), *CLI_ARGS, "--output-schema", str(SCHEMA),
               "--output-last-message", str(answer), "-"]
        prompt = INSTRUCTION + "\nRequest: " + json.dumps(phrase, ensure_ascii=False) + "\n"
        completed = subprocess.run(cmd, input=prompt, text=True, capture_output=True,
                                   cwd=temp, timeout=120, check=False)
        if completed.returncode:
            raise RuntimeError(f"fixture {index}, trial {trial}: {completed.stderr[-500:]}")
        if not tool_free_trace(completed.stdout):
            raise RuntimeError(f"fixture {index}, trial {trial}: router tool event or incomplete turn")
        return index, trial, json.loads(answer.read_text())


def handoffs(validator, results):
    payload = "".join(json.dumps({"phrase": FIXTURES[index]["phrase"], "output": output}) + "\n"
                      for index, trial, output in results)
    run = subprocess.run([str(validator)], input=payload, text=True, capture_output=True,
                         check=True, timeout=30)
    rows = [json.loads(line) for line in run.stdout.splitlines()]
    if len(rows) != len(results):
        raise RuntimeError("Production route validator returned incomplete handoffs")
    return rows


def evaluate():
    if len(FIXTURES) < 40:
        raise RuntimeError("Router corpus has fewer than 40 phrases")
    with tempfile.TemporaryDirectory(prefix="voice-router-validator-") as temp:
        validator = Path(temp) / "route-validator"
        subprocess.run(["swiftc", "-O", "-o", str(validator),
                        str(ROOT / "VoiceComputerPOC/CommandRoute.swift"),
                        str(ROOT / "scripts/route-validator.swift")], check=True)
        jobs = [(index, trial) for index in range(len(FIXTURES)) for trial in (1, 2, 3)]
        results = []
        with ThreadPoolExecutor(max_workers=4) as pool:
            futures = {pool.submit(classify, job): job for job in jobs}
            for future in as_completed(futures):
                results.append(future.result())
                if len(results) % 20 == 0:
                    print(f"Classified {len(results)}/{len(jobs)} independent turns", flush=True)
        results.sort(key=lambda row: (row[0], row[1]))
        decisions = handoffs(validator, results)

    report = {"corpus": "router-v4", "fixture_count": len(FIXTURES),
              "independent_model_turns": len(results), "trials": [], "misses": []}
    for (index, trial, output), handoff in zip(results, decisions):
        expected = FIXTURES[index]
        correct = (set(output) == {"route", "directions", "target"}
                   and all(output.get(key) == expected[key]
                           for key in ("route", "directions", "target")))
        if expected["route"] == "space":
            correct = (correct and handoff.get("route") == "space"
                       and [handoff.get("first"), *handoff.get("remaining", [])] == expected["directions"])
        elif expected["route"] == "computer_use":
            correct = correct and handoff.get("route") == "calculator"
        elif expected["route"] == "browser":
            expected_handoff = ("browser_form" if expected["target"] == "local_form"
                                else "browser")
            correct = correct and handoff.get("route") == expected_handoff \
                and handoff.get("url") in expected["phrase"]
            if expected_handoff == "browser_form":
                correct = correct and handoff.get("query") == "test-fixture-1234"
        elif expected["route"] == "finder":
            correct = correct and handoff.get("route") == "finder" \
                and handoff.get("path") in expected["phrase"]
        else:
            correct = correct and handoff.get("route") == "clarification"
        row = {"id": index, "trial": trial, "phrase": expected["phrase"],
               "expected": {key: expected[key] for key in ("route", "directions", "target")},
               "output": output, "handoff": handoff, "correct": correct}
        report["trials"].append(row)
        if not correct:
            report["misses"].append(row)
    report["accuracy"] = sum(row["correct"] for row in report["trials"]) / len(results)
    report["wrong_direction_actions"] = sum(
        row["expected"]["route"] == "space" and row["handoff"]["route"] == "space"
        and row["handoff"]["first"] != row["expected"]["directions"][0]
        for row in report["trials"])
    report["clarification_actions"] = sum(
        row["expected"]["route"] == "clarification"
        and row["handoff"]["route"] in ("space", "calculator", "browser", "browser_form", "finder")
        for row in report["trials"])
    (EVALS / "router-v4-report.json").write_text(
        json.dumps(report, indent=2).replace(FINDER_PATH, "@FINDER_REPORT@") + "\n")
    summary = {key: report[key] for key in ("fixture_count", "independent_model_turns", "accuracy",
                                          "wrong_direction_actions", "clarification_actions")}
    summary["miss_count"] = len(report["misses"])
    print(json.dumps(summary))
    return 0 if report["accuracy"] >= .95 and report["wrong_direction_actions"] == 0 \
        and report["clarification_actions"] == 0 else 1


def main():
    global FIXTURES, FINDER_PATH
    root = (Path.home() / "Library/Application Support/VoiceComputerPOC/TestFixtures"
            / uuid.uuid4().hex)
    root.mkdir(parents=True, mode=0o700)
    report = root / "report.txt"
    report.write_text("Router Finder fixture\n")
    FINDER_PATH = str(report)
    FIXTURES = [{**row, "phrase": row["phrase"].replace("@FINDER_REPORT@", FINDER_PATH)}
                for row in FIXTURES]
    try:
        return evaluate()
    finally:
        shutil.rmtree(root)


if __name__ == "__main__":
    sys.exit(main())
