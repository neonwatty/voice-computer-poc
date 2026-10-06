"""Owner dispatch, exact-head checks, and Mac receipt boundaries."""

import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import run_reviewed_desktop_suite as trigger


SHA = "a" * 40
OTHER_SHA = "b" * 40
CASES = [20, 17, 18, 21, 22, 23, 19, 15, 16, 20]


def green_pr():
    return {"number": 42, "state": "OPEN", "isDraft": False,
            "baseRefName": "main", "headRefOid": SHA,
            "headRepository": {"name": "voice-computer-poc"},
            "headRepositoryOwner": {"login": "neonwatty"},
            "statusCheckRollup": [
                {"workflowName": "CI", "name": "Build and test",
                 "status": "COMPLETED", "conclusion": "SUCCESS"},
                {"workflowName": "CodeQL", "name": "Analyze Swift",
                 "status": "COMPLETED", "conclusion": "SUCCESS"},
            ]}


def passing_summary():
    return {"status": "passed", "sha": SHA, "all_cases_passed": True,
            "case_ids": CASES, "starting_space_id": 5, "final_space_id": 5}


class ReviewedDesktopSuiteTests(unittest.TestCase):
    def test_requires_same_repository_open_exact_head(self):
        original = green_pr()
        trigger.validate_pr(original, 42, SHA)
        for field, value in (("number", 43), ("state", "CLOSED"),
                             ("isDraft", True), ("baseRefName", "other"),
                             ("headRefOid", OTHER_SHA)):
            candidate = copy.deepcopy(original)
            candidate[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                trigger.validate_pr(candidate, 42, SHA)
        candidate = copy.deepcopy(original)
        candidate["headRepositoryOwner"]["login"] = "other"
        with self.assertRaisesRegex(ValueError, "trusted repository"):
            trigger.validate_pr(candidate, 42, SHA)

    def test_requires_owner_attestation_and_both_green_checks(self):
        trigger.validate_attestation(SHA, SHA, True)
        with self.assertRaisesRegex(ValueError, "attestation"):
            trigger.validate_attestation(SHA, OTHER_SHA, True)
        with self.assertRaisesRegex(ValueError, "repository owner"):
            trigger.validate_attestation(SHA, SHA, False)
        original = green_pr()
        for index in (0, 1):
            candidate = copy.deepcopy(original)
            candidate["statusCheckRollup"][index]["conclusion"] = "FAILURE"
            with self.subTest(index=index), self.assertRaisesRegex(ValueError, "not green"):
                trigger.validate_pr(candidate, 42, SHA)
        candidate = copy.deepcopy(original)
        candidate["statusCheckRollup"].append(candidate["statusCheckRollup"][0])
        with self.assertRaisesRegex(ValueError, "not green"):
            trigger.validate_pr(candidate, 42, SHA)

    def test_receipt_requires_exact_complete_restored_suite(self):
        result = subprocess.CompletedProcess([], 0)
        original = passing_summary()
        self.assertTrue(trigger.validate_receipt(result, original, SHA))
        for field, value in (("status", "failed"), ("sha", OTHER_SHA),
                             ("all_cases_passed", False), ("case_ids", CASES[:-1]),
                             ("starting_space_id", None), ("final_space_id", 6)):
            candidate = copy.deepcopy(original)
            candidate[field] = value
            with self.subTest(field=field):
                self.assertFalse(trigger.validate_receipt(result, candidate, SHA))
        self.assertFalse(trigger.validate_receipt(
            subprocess.CompletedProcess([], 1), original, SHA))

    def dispatch(self, summary, second_pr=None, runner_exit=0,
                 owner=True, status_side_effect=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            receipt_dir = (root / "Library/Application Support/VoiceComputerPOC/SmokeRuns" /
                           f"reviewed-{SHA[:12]}-testid")
            receipt_dir.mkdir(parents=True)
            (receipt_dir / "summary.json").write_text(json.dumps(summary))
            args = ["trigger", "--pr", "42", "--sha", SHA,
                    "--attest-sha", SHA, "--derived-data-path", str(root / "build")]
            pr_sequence = [green_pr(), second_pr or green_pr()]
            with mock.patch.object(sys, "argv", args), \
                    mock.patch.object(trigger.Path, "home", return_value=root), \
                    mock.patch.object(trigger.uuid, "uuid4") as uid, \
                    mock.patch.object(trigger, "validate_checkout"), \
                    mock.patch.object(trigger, "authenticated_owner", return_value=owner), \
                    mock.patch.object(trigger, "pr_details", side_effect=pr_sequence) as pr, \
                    mock.patch.object(trigger, "post_status",
                                      side_effect=status_side_effect) as status, \
                    mock.patch.object(trigger.subprocess, "run", return_value=
                                      subprocess.CompletedProcess([], runner_exit)) as runner:
                uid.return_value.hex = "testid"
                code = trigger.main()
            return code, status.call_args_list, pr.call_count, runner.call_count

    def test_live_dispatch_rechecks_head_before_success(self):
        code, statuses, pr_reads, runner_calls = self.dispatch(passing_summary())
        self.assertEqual((code, pr_reads, runner_calls), (0, 2, 1))
        self.assertEqual([call.args[1] for call in statuses], ["pending", "success"])
        changed = green_pr()
        changed["headRefOid"] = OTHER_SHA
        code, statuses, pr_reads, runner_calls = self.dispatch(passing_summary(), changed)
        self.assertEqual((code, pr_reads, runner_calls), (2, 2, 1))
        self.assertEqual([call.args[1] for call in statuses], ["pending", "failure"])

    def test_runner_failure_cannot_post_success(self):
        code, statuses, _, _ = self.dispatch(passing_summary(), runner_exit=1)
        self.assertEqual(code, 1)
        self.assertEqual([call.args[1] for call in statuses], ["pending", "failure"])

    def test_wrong_owner_stops_before_actor_or_status(self):
        code, statuses, pr_reads, runner_calls = self.dispatch(
            passing_summary(), owner=False)
        self.assertEqual((code, pr_reads, runner_calls), (2, 0, 0))
        self.assertEqual(statuses, [])

    def test_failed_success_status_is_replaced_by_failure(self):
        error = subprocess.CalledProcessError(1, ["gh", "api"])
        code, statuses, _, _ = self.dispatch(
            passing_summary(), status_side_effect=[None, error, None])
        self.assertEqual(code, 2)
        self.assertEqual([call.args[1] for call in statuses],
                         ["pending", "success", "failure"])


if __name__ == "__main__":
    unittest.main()
