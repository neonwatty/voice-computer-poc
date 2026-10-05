"""Trusted PR and check boundaries for the Mac desktop trigger."""

import copy
import unittest

from run_reviewed_desktop_suite import validate_pr


SHA = "a" * 40


def approved_pr():
    return {"number": 42, "state": "OPEN", "isDraft": False,
            "baseRefName": "main", "headRefOid": SHA,
            "headRepository": {"name": "voice-computer-poc", "nameWithOwner": ""},
            "headRepositoryOwner": {"login": "neonwatty"},
            "reviewDecision": "APPROVED", "statusCheckRollup": [
                {"workflowName": "CI", "name": "Build and test",
                 "status": "COMPLETED", "conclusion": "SUCCESS"},
                {"workflowName": "CodeQL", "name": "Analyze Swift",
                 "status": "COMPLETED", "conclusion": "SUCCESS"},
            ]}


class ReviewedDesktopSuiteTests(unittest.TestCase):
    def test_requires_exact_approved_same_repository_pr(self):
        original = approved_pr()
        reviews = [{"state": "APPROVED", "commit_id": SHA}]
        validate_pr(original, reviews, 42, SHA)
        for field, value in (("number", 43), ("state", "CLOSED"),
                             ("isDraft", True), ("baseRefName", "other"),
                             ("headRefOid", "b" * 40),
                             ("reviewDecision", "REVIEW_REQUIRED")):
            candidate = copy.deepcopy(original)
            candidate[field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                validate_pr(candidate, reviews, 42, SHA)
        candidate = copy.deepcopy(original)
        candidate["headRepositoryOwner"]["login"] = "other"
        with self.assertRaisesRegex(ValueError, "trusted repository"):
            validate_pr(candidate, reviews, 42, SHA)
        with self.assertRaisesRegex(ValueError, "Exact PR head"):
            validate_pr(original, [{"state": "APPROVED", "commit_id": "b" * 40}], 42, SHA)

    def test_requires_both_successful_exact_checks(self):
        original = approved_pr()
        reviews = [{"state": "APPROVED", "commit_id": SHA}]
        for index in (0, 1):
            candidate = copy.deepcopy(original)
            candidate["statusCheckRollup"][index]["conclusion"] = "FAILURE"
            with self.subTest(index=index), self.assertRaisesRegex(ValueError, "not green"):
                validate_pr(candidate, reviews, 42, SHA)
        candidate = copy.deepcopy(original)
        candidate["statusCheckRollup"].append(candidate["statusCheckRollup"][0])
        with self.assertRaisesRegex(ValueError, "not green"):
            validate_pr(candidate, reviews, 42, SHA)


if __name__ == "__main__":
    unittest.main()
