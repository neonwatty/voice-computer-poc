#!/usr/bin/env python3
"""Evaluate the production one-phrase router and compiled route contract."""
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
EVALS = ROOT / "evals"
FIXTURES = json.loads((EVALS / "router-v6.json").read_text())
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
    unexpected = []
    for line in text.splitlines():
        event = json.loads(line)
        kind = event.get("type", "")
        if kind == "turn.completed":
            completed = True
        if kind.startswith("item.") and event.get("item", {}).get("type") not in ("agent_message", "reasoning"):
            unexpected.append(kind + ":" + str(event.get("item", {}).get("type", "missing")))
    return completed and not unexpected, sorted(set(unexpected)) if unexpected else (
        [] if completed else ["turn_incomplete"])


def classify(job):
    index, trial = job
    phrase = FIXTURES[index]["phrase"]
    with tempfile.TemporaryDirectory(prefix="voice-router-eval-") as temp:
        answer = Path(temp) / "answer.json"
        cmd = [executable(), *CLI_ARGS, "--output-schema", str(SCHEMA),
               "--output-last-message", str(answer), "-"]
        prompt = INSTRUCTION + "\nRequest: " + json.dumps(phrase, ensure_ascii=False) + "\n"
        try:
            completed = subprocess.run(cmd, input=prompt, text=True, capture_output=True,
                                       cwd=temp, timeout=120, check=False)
        except subprocess.TimeoutExpired:
            return index, trial, None, ["cli_timeout"]
        if completed.returncode:
            return index, trial, None, ["cli_exit_" + str(completed.returncode)]
        try:
            valid_trace, trace_errors = tool_free_trace(completed.stdout)
        except ValueError:
            return index, trial, None, ["invalid_cli_trace"]
        if not valid_trace:
            return index, trial, None, trace_errors
        try:
            return index, trial, json.loads(answer.read_text()), []
        except (OSError, ValueError):
            return index, trial, None, ["invalid_model_output"]


def handoffs(validator, results):
    payload = "".join(json.dumps({"phrase": FIXTURES[index]["phrase"], "output": output}) + "\n"
                      for index, trial, output, _ in results)
    run = subprocess.run([str(validator)], input=payload, text=True, capture_output=True,
                         check=True, timeout=30)
    rows = [json.loads(line) for line in run.stdout.splitlines()]
    if len(rows) != len(results):
        raise RuntimeError("Production route validator returned incomplete handoffs")
    return rows


def reusable_trials(report, templates):
    """Keep only completed tool-free turns for unchanged fixture templates."""
    rows = report.get("trials", [])
    run_id = next((match.group(1) for row in rows
                   if (match := re.search(r"run_id=([0-9a-f]{32})", row.get("phrase", "")))), None)
    reusable = {}
    for row in rows:
        index, trial = row.get("id"), row.get("trial")
        if not isinstance(index, int) or not isinstance(trial, int) \
                or not 0 <= index < len(templates) or trial not in (1, 2, 3) \
                or row.get("output") is None or row.get("trace_errors"):
            continue
        old_phrase = row.get("phrase", "")
        if run_id:
            old_phrase = old_phrase.replace(run_id, "@FINDER_RUN_ID@")
        if old_phrase == templates[index]["phrase"]:
            reusable[(index, trial)] = (index, trial, row["output"], [])
    return reusable


def evaluate(reusable=None):
    reusable = reusable or {}
    if len(FIXTURES) < 40:
        raise RuntimeError("Router corpus has fewer than 40 phrases")
    with tempfile.TemporaryDirectory(prefix="voice-router-validator-") as temp:
        validator = Path(temp) / "route-validator"
        subprocess.run(["swiftc", "-O", "-o", str(validator),
                        str(ROOT / "VoiceComputerPOC/CommandRoute.swift"),
                        str(ROOT / "scripts/route-validator.swift")], check=True)
        all_jobs = [(index, trial) for index in range(len(FIXTURES)) for trial in (1, 2, 3)]
        jobs = [job for job in all_jobs if job not in reusable]
        results = list(reusable.values())
        with ThreadPoolExecutor(max_workers=1 if reusable else 2) as pool:
            futures = {pool.submit(classify, job): job for job in jobs}
            new_count = 0
            for future in as_completed(futures):
                results.append(future.result())
                new_count += 1
                if new_count % 20 == 0:
                    print(f"Classified {new_count}/{len(jobs)} new independent turns", flush=True)
        results.sort(key=lambda row: (row[0], row[1]))
        valid_results = [row for row in results if row[2] is not None]
        valid_decisions = handoffs(validator, valid_results)
        decisions = { (index, trial): decision for (index, trial, _, _), decision
                      in zip(valid_results, valid_decisions) }

    report = {"corpus": "router-v6", "fixture_count": len(FIXTURES),
              "independent_model_turns": len(results), "reused_trial_count": len(reusable),
              "new_trial_count": len(jobs), "trials": [], "misses": []}
    report["trace_errors"] = []
    for index, trial, output, trace_errors in results:
        handoff = decisions.get((index, trial), {"route": "trace_error"})
        expected = FIXTURES[index]
        correct = (output is not None and set(output) == {"route", "directions", "target"}
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
        elif expected["route"] == "textedit":
            correct = correct and handoff.get("route") == "textedit" \
                and handoff.get("path") in expected["phrase"]
        elif expected["route"] == "browser_finder":
            correct = correct and handoff.get("route") == "browser_finder" \
                and handoff.get("url") in expected["phrase"] \
                and handoff.get("path") in expected["phrase"]
        else:
            correct = correct and handoff.get("route") == "clarification"
        row = {"id": index, "trial": trial, "phrase": expected["phrase"],
               "expected": {key: expected[key] for key in ("route", "directions", "target")},
               "output": output, "handoff": handoff, "correct": correct,
               "trace_errors": trace_errors}
        report["trials"].append(row)
        if trace_errors:
            report["trace_errors"].append({"id": index, "trial": trial,
                                           "errors": trace_errors})
        if not correct:
            report["misses"].append(row)
    report["accuracy"] = sum(row["correct"] for row in report["trials"]) / len(results)
    report["wrong_direction_actions"] = sum(
        row["expected"]["route"] == "space" and row["handoff"]["route"] == "space"
        and row["handoff"]["first"] != row["expected"]["directions"][0]
        for row in report["trials"])
    report["clarification_actions"] = sum(
        row["expected"]["route"] == "clarification"
        and row["handoff"]["route"] in ("space", "calculator", "browser", "browser_form", "finder", "textedit", "browser_finder")
        for row in report["trials"])
    (EVALS / "router-v6-report.json").write_text(
        json.dumps(report, indent=2).replace(FINDER_PATH, "@FINDER_REPORT@")
        .replace(TEXTEDIT_PATH, "@TEXTEDIT_NOTE@") + "\n")
    summary = {key: report[key] for key in ("fixture_count", "independent_model_turns", "accuracy",
                                          "wrong_direction_actions", "clarification_actions")}
    summary["miss_count"] = len(report["misses"])
    summary["trace_error_count"] = len(report["trace_errors"])
    print(json.dumps(summary))
    return 0 if report["accuracy"] >= .95 and report["wrong_direction_actions"] == 0 \
        and report["clarification_actions"] == 0 and not report["trace_errors"] else 1


def main():
    global FIXTURES, FINDER_PATH, TEXTEDIT_PATH
    if sys.argv[1:] not in ([], ["--resume"]):
        raise SystemExit("Usage: eval-router.py [--resume]")
    templates = FIXTURES
    saved_report = EVALS / "router-v6-report.json"
    reusable = reusable_trials(json.loads(saved_report.read_text()), templates) \
        if sys.argv[1:] == ["--resume"] else {}
    root = (Path.home() / "Library/Application Support/VoiceComputerPOC/TestFixtures"
            / uuid.uuid4().hex)
    root.mkdir(parents=True, mode=0o700)
    report = root / "report.txt"
    report.write_text("Router Finder fixture\n")
    FINDER_PATH = str(report)
    note = root / "note.txt"
    note.write_text(f"Voice Computer draft {root.name}")
    TEXTEDIT_PATH = str(note)
    FIXTURES = [{**row, "phrase": row["phrase"]
                 .replace("@FINDER_REPORT@", FINDER_PATH)
                 .replace("@TEXTEDIT_NOTE@", TEXTEDIT_PATH)
                 .replace("@FINDER_RUN_ID@", root.name)}
                for row in FIXTURES]
    try:
        return evaluate(reusable)
    finally:
        shutil.rmtree(root)


if __name__ == "__main__":
    sys.exit(main())
