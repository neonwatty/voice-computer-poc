import unittest

from probe_codex_status import interpret_status


class CodexStatusProbeTests(unittest.TestCase):
    def test_unloaded_is_not_a_live_task_state(self):
        self.assertEqual(interpret_status({"status": {"type": "notLoaded"}}),
                         "unavailable_cross_process")
        self.assertEqual(interpret_status({"status": {"type": "active"}}),
                         "observed_in_probe_process")
        self.assertEqual(interpret_status({"status": {"type": "unexpected"}}), "unknown")


if __name__ == "__main__":
    unittest.main()
