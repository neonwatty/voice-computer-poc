#!/usr/bin/env python3
"""Run the desktop suite for one approved, green PR head on this Mac."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import uuid

from run_desktop_suite import validate_checkout


REPOSITORY = "neonwatty/voice-computer-poc"
CONTEXT = "Voice Computer / desktop suite"
REQUIRED_CHECKS = {("CI", "Build and test"), ("CodeQL", "Analyze Swift")}


def pr_details(number):
    command = ["gh", "pr", "view", str(number), "--repo", REPOSITORY, "--json",
               "number,state,isDraft,baseRefName,headRefOid,headRepository,"
               "headRepositoryOwner,reviewDecision,statusCheckRollup"]
    output = subprocess.run(command, check=True, capture_output=True,
                            text=True, timeout=30).stdout
    return json.loads(output)


def pr_reviews(number):
    output = subprocess.run(["gh", "api", f"repos/{REPOSITORY}/pulls/{number}/reviews"],
                            check=True, capture_output=True, text=True, timeout=30).stdout
    return json.loads(output)


def validate_pr(pr, reviews, number, sha):
    if pr.get("number") != number or pr.get("state") != "OPEN" \
            or pr.get("isDraft") is not False or pr.get("baseRefName") != "main":
        raise ValueError("PR must be open, ready for review, and target main")
    if pr.get("headRefOid") != sha:
        raise ValueError("PR head does not match the exact local SHA")
    repository = pr.get("headRepository") or {}
    owner = pr.get("headRepositoryOwner") or {}
    if repository.get("name") != REPOSITORY.split("/")[1] \
            or owner.get("login") != REPOSITORY.split("/")[0]:
        raise ValueError("PR head must belong to the trusted repository")
    if pr.get("reviewDecision") != "APPROVED":
        raise ValueError("PR head requires an approved review")
    if not any(review.get("state") == "APPROVED" and review.get("commit_id") == sha
               for review in reviews):
        raise ValueError("Exact PR head SHA requires an approved review")
    checks = pr.get("statusCheckRollup") or []
    for workflow, name in REQUIRED_CHECKS:
        matching = [check for check in checks if check.get("workflowName") == workflow
                    and check.get("name") == name]
        if len(matching) != 1 or matching[0].get("status") != "COMPLETED" \
                or matching[0].get("conclusion") != "SUCCESS":
            raise ValueError(f"Required {workflow} / {name} check is not green")


def post_status(sha, state, description):
    if state not in {"pending", "success", "failure"} or len(description) > 140:
        raise ValueError("Invalid desktop suite commit status")
    subprocess.run(["gh", "api", "--method", "POST",
                    f"repos/{REPOSITORY}/statuses/{sha}",
                    "-f", f"state={state}", "-f", f"context={CONTEXT}",
                    "-f", f"description={description}"],
                   check=True, capture_output=True, text=True, timeout=30)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pr", type=int, required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--derived-data-path", type=Path, required=True)
    args = parser.parse_args()
    os.umask(0o077)
    pending_posted = False
    try:
        if args.pr <= 0 or not args.derived_data_path.is_absolute():
            raise ValueError("Positive PR number and absolute build path required")
        validate_checkout(args.sha)
        validate_pr(pr_details(args.pr), pr_reviews(args.pr), args.pr, args.sha)
        log_directory = (Path.home() / "Library/Application Support/VoiceComputerPOC/SmokeRuns" /
                         f"reviewed-{args.sha[:12]}-{uuid.uuid4().hex}")
        post_status(args.sha, "pending", "Exact-SHA desktop suite running on the Mac")
        pending_posted = True
        result = subprocess.run([sys.executable,
                                 str(Path(__file__).with_name("run_desktop_suite.py")),
                                 "--sha", args.sha,
                                 "--derived-data-path", str(args.derived_data_path),
                                 "--log-directory", str(log_directory)], check=False)
        summary_path = log_directory / "summary.json"
        summary = json.loads(summary_path.read_text()) if summary_path.is_file() else {}
        passed = (result.returncode == 0 and summary.get("status") == "passed"
                  and summary.get("sha") == args.sha
                  and summary.get("all_cases_passed") is True)
        if passed:
            cases = summary.get("case_ids") or []
            description = f"{len(cases)} desktop cases passed; Space and windows restored"
            post_status(args.sha, "success", description)
            pending_posted = False
            print(f"Desktop status attached to {args.sha}: success")
            return 0
        post_status(args.sha, "failure", "Desktop suite failed; inspect private Mac receipt")
        pending_posted = False
        print(f"Desktop status attached to {args.sha}: failure", file=sys.stderr)
        return 1
    except (OSError, ValueError, subprocess.SubprocessError, KeyboardInterrupt) as error:
        if pending_posted:
            try:
                post_status(args.sha, "failure", "Desktop trigger interrupted; inspect private Mac receipt")
            except (OSError, ValueError, subprocess.SubprocessError):
                print("Could not update pending desktop commit status", file=sys.stderr)
        print(f"Reviewed desktop trigger rejected: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
