"""Failure boundaries for the one-command Mac suite wrapper."""

import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from run_desktop_suite import summarize_smoke, validate_checkout


SHA = "a" * 40


class DesktopSuiteRunnerTests(unittest.TestCase):
    def test_checkout_requires_exact_clean_head(self):
        with patch("run_desktop_suite.git_output", side_effect=[SHA, ""]):
            validate_checkout(SHA)
        with self.assertRaisesRegex(ValueError, "40-character"):
            validate_checkout("main")
        with patch("run_desktop_suite.git_output", return_value="b" * 40), \
                self.assertRaisesRegex(ValueError, "HEAD"):
            validate_checkout(SHA)
        with patch("run_desktop_suite.git_output", side_effect=[SHA, " M file.py"]), \
                self.assertRaisesRegex(ValueError, "clean"):
            validate_checkout(SHA)

    def test_receipt_requires_complete_ordered_suite_and_context_evidence(self):
        rows = [{"event": "safari_context_receipt_verified"},
                {"event": "finder_context_receipt_verified"},
                {"event": "textedit_context_receipt_verified"}]
        rows += [{"event": "command_finished", "command_index": index,
                  "success": True, "space_before": {"current": 5},
                  "space_after": {"current": 5}} for index in (20, 21, 22)]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "machine.jsonl"
            def verify(candidate, message=None):
                path.write_text("".join(json.dumps(row) + "\n" for row in candidate))
                if message:
                    with self.assertRaisesRegex(ValueError, message):
                        summarize_smoke(path, [20, 21, 22])
                else:
                    self.assertTrue(summarize_smoke(path, [20, 21, 22])["all_cases_passed"])
            verify(rows)
            verify(rows[:-1], "complete ordered")
            verify(rows[:2] + rows[3:], "context-window")
            changed = json.loads(json.dumps(rows))
            changed[-1]["space_after"]["current"] = 6
            verify(changed, "starting Space")
            changed = json.loads(json.dumps(rows))
            changed[-1]["success"] = False
            verify(changed, "complete ordered")


if __name__ == "__main__":
    unittest.main()
