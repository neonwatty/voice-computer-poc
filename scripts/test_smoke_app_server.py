"""Synthetic fail-closed receipts for the hardware smoke gate."""

import copy
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from smoke_app_server import (COMMANDS, Driver, canonical_app_path, mcp_case_phrase,
                              validate_mcp_cases, verify_mcp_receipt)  # noqa: E402


COMMAND_ID = "A1B2C3D4"
ITEM_ID = "item-1"
TURN_ID = "turn-1"


def row(event, **details):
    return {"event": event, "details": {"command_id": COMMAND_ID, **details}}


def valid_rows(direction="right", before=3, after=4):
    return [
        row("command_started", user_action="run"),
        row("mcp_action_requested", direction=direction),
        row("tool_started", item_id=ITEM_ID, server="desktop_tool",
            tool="switch_space", event_turn_id=TURN_ID, turn_matches="true"),
        row("approval_decided", server_name="desktop_tool", decision="Allowed once",
            request_id="17"),
        row("mcp_helper_bound", pid="123", path_matches_preflight="true",
            start_sec="100", start_usec="20"),
        row("mcp_bridge_accepted", direction=direction),
        row("native_space_requested", direction=direction,
            space_before_id=str(before), space_target_id=str(after)),
        row("native_space_ax_pressed", direction=direction),
        row("space_changed", live_space_id=str(after), causality="system_observation"),
        row("native_space_step_verified", direction=direction,
            space_before_id=str(before), space_target_id=str(after),
            space_after_id=str(after), space_change_events="1"),
        row("mcp_bridge_result", status="verified", verification="verified"),
        row("mcp_tool_result_correlated", tool_command_id=COMMAND_ID,
            direction=direction),
        row("tool_completed", item_id=ITEM_ID, server="desktop_tool",
            tool="switch_space", status="completed", result_is_error="false",
            typed_status="verified", typed_verified="true",
            typed_command_id=COMMAND_ID, typed_direction=direction),
        row("turn_completed", turn_id=TURN_ID, verification="verified"),
        row("command_finished", status="completed", verification="verified"),
    ]


class MCPReceiptTests(unittest.TestCase):
    def check(self, rows, direction="right", before=3, after=4):
        return verify_mcp_receipt(rows, "agent switch desktop space " + direction,
                                  direction, before, after, after)

    def test_valid_right_and_left(self):
        self.assertEqual(self.check(valid_rows())["command_id"], COMMAND_ID)
        self.assertEqual(self.check(valid_rows("left", 4, 3), "left", 4, 3)["after"], 3)

    def test_mcp_cua_budget_is_finite_and_allows_final_receipt(self):
        for case, limit in ((15, 24), (16, 24), (1, 12)):
            with self.subTest(case=case):
                driver = object.__new__(Driver)
                driver.command_index = case
                driver.tool_calls = 0
                driver.trace_tool_output = False
                driver.app_path = Path("/private/tmp/exact.app")
                driver.record = lambda *args, **kwargs: None
                notification = {"method": "item/started", "params": {"item": {
                    "type": "mcpToolCall", "server": "cua_repl", "tool": "js",
                    "arguments": "", "id": "synthetic-cua",
                }}}
                for _ in range(limit):
                    driver.handle_notification(notification)
                self.assertEqual(driver.tool_calls, limit)
                if case in (15, 16):
                    direction, before, after = ("right", 3, 4) if case == 15 else ("left", 4, 3)
                    self.assertEqual(verify_mcp_receipt(
                        valid_rows(direction, before, after), mcp_case_phrase(case),
                        direction, before, after, after)["after"], after)
                with self.assertRaisesRegex(RuntimeError, str(limit)):
                    driver.handle_notification(notification)

    def test_real_case_phrase_callsite_rejects_outer_and_legacy(self):
        for case, direction, before, after in ((15, "right", 3, 4), (16, "left", 4, 3)):
            with self.subTest(case=case):
                rows = valid_rows(direction, before, after)
                self.assertEqual(verify_mcp_receipt(
                    rows, mcp_case_phrase(case), direction, before, after, after)["after"], after)
                for wrong in (COMMANDS[case - 1], "Switch to the next desktop Space"):
                    with self.assertRaisesRegex(ValueError, "phrase"):
                        verify_mcp_receipt(rows, wrong, direction, before, after, after)

    def test_legacy_native_only_rejected(self):
        rows = valid_rows("left", 4, 3)
        rows = [entry for entry in rows if entry["event"] not in (
            "mcp_action_requested", "tool_started", "approval_decided",
            "mcp_helper_bound", "mcp_bridge_accepted", "tool_completed")]
        with self.assertRaisesRegex(ValueError, "acting MCP route"):
            self.check(rows, "left", 4, 3)

    def test_ambiguous_command_id_rejected(self):
        rows = valid_rows()
        rows.append(row("command_started", user_action="run"))
        with self.assertRaisesRegex(ValueError, "Ambiguous"):
            self.check(rows)

    def test_wrong_server_tool_item_direction_rejected(self):
        for index, field, value in (
            (2, "server", "other"), (2, "tool", "other"),
            (12, "item_id", "other"), (1, "direction", "left"),
            (5, "direction", "left"), (2, "event_turn_id", "missing"),
            (2, "turn_matches", "false"),
        ):
            with self.subTest(index=index, field=field):
                rows = copy.deepcopy(valid_rows())
                rows[index]["details"][field] = value
                with self.assertRaises(ValueError):
                    self.check(rows)

    def test_approval_failures_rejected(self):
        for decision in (None, "Declined", "Allowed for session"):
            with self.subTest(decision=decision):
                rows = valid_rows()
                if decision is None:
                    del rows[3]
                else:
                    rows[3]["details"]["decision"] = decision
                with self.assertRaisesRegex(ValueError, "Allow once"):
                    self.check(rows)

    def test_missing_helper_bridge_notification_rejected(self):
        for event in ("mcp_helper_bound", "mcp_bridge_accepted", "space_changed",
                      "native_space_ax_pressed", "native_space_step_verified"):
            with self.subTest(event=event):
                rows = [entry for entry in valid_rows() if entry["event"] != event]
                with self.assertRaises(ValueError):
                    self.check(rows)

    def test_mismatched_live_id_and_typed_result_rejected(self):
        rows = valid_rows()
        with self.assertRaisesRegex(ValueError, "Independent live"):
            verify_mcp_receipt(rows, "agent switch desktop space right", "right", 3, 4, 3)
        for index, field, value in ((8, "live_space_id", "3"),
                                    (9, "space_after_id", "3"),
                                    (12, "typed_verified", "false"),
                                    (12, "typed_command_id", "other")):
            with self.subTest(field=field):
                changed = copy.deepcopy(rows)
                changed[index]["details"][field] = value
                with self.assertRaises(ValueError):
                    self.check(changed)

    def test_private_command_body_rejected(self):
        rows = valid_rows()
        rows[0]["details"]["command_text"] = "private phrase"
        with self.assertRaisesRegex(ValueError, "Private"):
            self.check(rows)

    def test_case_sequence_is_bounded_and_alternating(self):
        for count in (1, 2, 3):
            validate_mcp_cases([15, 16] * count)
        validate_mcp_cases([15], single_step=True)
        for cases in ([15, 16], [16], [15, 15]):
            with self.subTest(single_step=cases), self.assertRaises(ValueError):
                validate_mcp_cases(cases, single_step=True)
        for cases in ([15], [16, 15], [15, 15], [15, 16] * 4, [15, 16, 9]):
            with self.subTest(cases=cases), self.assertRaises(ValueError):
                validate_mcp_cases(cases)

    def test_app_path_must_be_canonical_and_executable(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "VoiceComputerPOC.app"
            binary = app / "Contents/MacOS/VoiceComputerPOC"
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b"test")
            binary.chmod(0o755)
            with (app / "Contents/Info.plist").open("wb") as handle:
                plistlib.dump({"CFBundleIdentifier": "com.neonwatty.VoiceComputerPOC"}, handle)
            self.assertEqual(canonical_app_path(app.resolve()), app.resolve())
            alias = Path(directory) / "alias.app"
            alias.symlink_to(app)
            for invalid in (alias, Path("relative.app"), Path(directory) / "missing.app"):
                with self.subTest(path=invalid), self.assertRaises(ValueError):
                    canonical_app_path(invalid)


if __name__ == "__main__":
    unittest.main()
