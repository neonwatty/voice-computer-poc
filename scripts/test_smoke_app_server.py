"""Synthetic fail-closed receipts for the hardware smoke gate."""

import copy
import json
import plistlib
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).parent))
from smoke_app_server import (COMMANDS, Driver, app_log_rows, canonical_app_path,
                              cua_exact_path_call, mcp_case_phrase, parse_open_session_log,
                              running_app_pids, screen_is_locked, selected_cases,
                              validate_exact_space_state,
                              validate_mcp_cases, verify_mcp_receipt,
                              verify_read_only_receipt, verify_browser_receipt,
                              verify_browser_interruption_receipt,
                              verify_finder_receipt,
                              verify_finder_rejection_receipt,
                              verify_composed_receipt,
                              verify_composed_failure_receipt,
                              verify_composed_rejection_receipt,
                              verify_desktop_state_receipt,
                              verify_safari_context_receipt)  # noqa: E402


COMMAND_ID = "A1B2C3D4"
ITEM_ID = "item-1"
TURN_ID = "turn-1"


def row(event, **details):
    return {"event": event, "details": {"command_id": COMMAND_ID, **details}}


class SuiteSelectionTests(unittest.TestCase):
    def test_mission_control_is_explicit_for_browser_finder_suite(self):
        self.assertEqual(selected_cases(True, None, False), [20, 17, 18, 21, 19, 15, 16, 20])
        self.assertEqual(selected_cases(True, None, True), [13, 20, 17, 18, 21, 19, 15, 16, 20])
        with self.assertRaisesRegex(ValueError, "requires --suite"):
            selected_cases(False, [17], True)
        with self.assertRaisesRegex(ValueError, "cannot be combined"):
            selected_cases(True, [13], False)


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


def read_only_rows():
    return [
        row("command_started", user_action="run"),
        row("live_space_observed", phase="before_command", live_space_id="3"),
        row("mission_control_probe_started"),
        row("mission_control_ax_summary", trusted="true", dock_found="true",
            control_source="dock",
            mission_present="true", mission_active="true", limit_reached="false",
            controls="Desktop 1:exit to Desktop 1:AXPress,AXRemoveDesktop; "
                     "Desktop 2:exit to Desktop 2:AXPress,AXRemoveDesktop"),
        row("command_finished", status="completed"),
        row("live_space_observed", phase="after_completion", live_space_id="3"),
    ]


class ExactAppBindingTests(unittest.TestCase):
    def test_unlock_probe_accepts_current_root_flag(self):
        responses = [SimpleNamespace(stdout="IOResources without legacy lock flag"),
                     SimpleNamespace(stdout=plistlib.dumps({"IOConsoleLocked": False}))]
        with patch("smoke_app_server.sys.platform", "darwin"), patch(
                "smoke_app_server.subprocess.run", side_effect=responses):
            self.assertFalse(screen_is_locked())
        responses[1] = SimpleNamespace(stdout=plistlib.dumps({"IOConsoleLocked": True}))
        with patch("smoke_app_server.sys.platform", "darwin"), patch(
                "smoke_app_server.subprocess.run", side_effect=responses):
            self.assertTrue(screen_is_locked())

    def test_exact_cases_accept_host_ids_and_reject_wrong_start_or_topology(self):
        first = {"current": 5, "ordered": [5, 6]}
        second = {"current": 6, "ordered": [5, 6]}
        self.assertEqual(validate_exact_space_state(first, 13), first)
        self.assertEqual(validate_exact_space_state(second, 13), second)
        self.assertEqual(validate_exact_space_state(first, 15), first)
        self.assertEqual(validate_exact_space_state(second, 16), second)
        for state, case in ((first, 16), (second, 15),
                            ({"current": 5, "ordered": [5, 5]}, 13),
                            ({"current": 7, "ordered": [5, 6]}, 13),
                            ({"current": 5, "ordered": [5, 6, 7]}, 15),
                            (None, 13)):
            with self.subTest(state=state, case=case), self.assertRaises(RuntimeError):
                validate_exact_space_state(state, case)

    def test_sole_pid_matches_exact_executable_path(self):
        app = Path("/Users/jeremywatt/Desktop/VoiceComputerPOC-a8175c4.app")
        executable = app / "Contents/MacOS/VoiceComputerPOC"
        listing = (f"70331 {executable}\n" +
                   "55110 /private/tmp/other.app/Contents/MacOS/VoiceComputerPOC\n")
        with patch("smoke_app_server.subprocess.run",
                   return_value=SimpleNamespace(stdout=listing)):
            self.assertEqual(running_app_pids(app), [70331])
        with patch("smoke_app_server.subprocess.run",
                   return_value=SimpleNamespace(stdout=listing + f"70332 {executable}\n")):
            self.assertEqual(len(running_app_pids(app)), 2)

    def test_cua_requires_exact_path_without_bundle_fallback(self):
        path = Path("/Users/jeremywatt/Desktop/VoiceComputerPOC-a8175c4.app")
        self.assertTrue(cua_exact_path_call({"arguments": {"code":
            "let app = await cua.getApp('" + str(path) + "');"}}, path))
        self.assertFalse(cua_exact_path_call({"arguments": {"code":
            "let app = await cua.getApp('/tmp/other.app');"}}, path))
        with self.assertRaisesRegex(RuntimeError, "bundle-ID"):
            cua_exact_path_call({"arguments": {"code":
                "await cua.getApp('com.neonwatty.VoiceComputerPOC');"}}, path)

    def test_case13_and_15_observe_exact_cua_binding(self):
        path = Path("/Users/jeremywatt/Desktop/VoiceComputerPOC-a8175c4.app")
        for case in (13, 15):
            with self.subTest(case=case):
                driver = object.__new__(Driver)
                driver.command_index = case
                driver.tool_calls = 0
                driver.app_path = path
                driver.cua_binding_observed = False
                driver.trace_tool_output = False
                driver.record = lambda *args, **kwargs: None
                driver.handle_notification({"method": "item/started", "params": {"item": {
                    "type": "mcpToolCall", "server": "cua_repl", "tool": "js",
                    "arguments": {"code": f"await cua.getApp('{path}')"}, "id": "cua-1",
                }}})
                self.assertTrue(driver.cua_binding_observed)
                with self.assertRaisesRegex(RuntimeError, "bundle-ID"):
                    driver.handle_notification({"method": "item/started", "params": {"item": {
                        "type": "mcpToolCall", "server": "cua_repl", "tool": "js",
                        "arguments": {"code": "await cua.getApp('com.neonwatty.VoiceComputerPOC')"},
                        "id": "cua-2",
                    }}})

    def test_open_log_requires_one_pid_owned_writable_mode_0600_file(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory).resolve() / "session-123-A1B2-C3D4.jsonl"
            log.write_text("", encoding="utf-8")
            log.chmod(0o600)
            listing = f"p70331\nf3\naw\nn{log}\n"
            self.assertEqual(parse_open_session_log(listing, 70331, Path(directory)), log)
            for bad in ("", listing.replace("p70331", "p7"), listing + listing,
                        listing.replace("aw", "ar"), listing + f"f4\naw\nn{log}\n"):
                with self.subTest(bad=bad), self.assertRaises(ValueError):
                    parse_open_session_log(bad, 70331, Path(directory))
            log.chmod(0o644)
            with self.assertRaisesRegex(ValueError, "0600"):
                parse_open_session_log(listing, 70331, Path(directory))
            log.chmod(0o600)
            alias = log.parent / "session-456-A1B2-C3D4.jsonl"
            alias.symlink_to(log)
            with self.assertRaisesRegex(ValueError, "canonical"):
                parse_open_session_log(f"p70331\nf3\naw\nn{alias}\n", 70331,
                                       Path(directory))

    def test_log_offset_only_reads_fresh_command_window(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory).resolve() / "session-123-A1B2-C3D4.jsonl"
            timestamp = datetime.now(timezone.utc).isoformat()
            log.write_text(json.dumps({"timestamp": timestamp, "event": "old"}) + "\n")
            offset = log.stat().st_size
            with log.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps({"timestamp": timestamp, "event": "new"}) + "\n")
            self.assertEqual([entry["event"] for entry in app_log_rows(
                log, datetime.now(timezone.utc).timestamp(), offset)], ["new"])
            with self.assertRaisesRegex(ValueError, "truncated"):
                app_log_rows(log, 0, log.stat().st_size + 1)
            with log.open("a", encoding="utf-8") as handle:
                handle.write("invalid json\n")
            with self.assertRaisesRegex(ValueError, "Unreadable"):
                app_log_rows(log, 0, offset)

    def test_read_only_receipt_is_fresh_trusted_exact_and_no_action(self):
        self.assertEqual(verify_read_only_receipt(read_only_rows(), 3, 3)["command_id"],
                         COMMAND_ID)
        cases = [
            (0, "command_id", "old"), (3, "trusted", "false"),
            (3, "dock_found", "false"), (3, "control_source", "none"),
            (3, "mission_present", "false"),
            (3, "limit_reached", "true"), (3, "controls", "Desktop 1:wrong:AXPress"),
            (5, "live_space_id", "4"),
        ]
        for index, field, value in cases:
            with self.subTest(field=field):
                changed = copy.deepcopy(read_only_rows())
                changed[index]["details"][field] = value
                with self.assertRaises(ValueError):
                    verify_read_only_receipt(changed, 3, 3)
        with self.assertRaisesRegex(ValueError, "stale"):
            verify_read_only_receipt(read_only_rows(), 3, 3, {COMMAND_ID})
        manager_rows = read_only_rows()
        manager_rows[3]["details"].update(
            control_source="window_manager", dock_found="false",
            window_manager_found="true", window_manager_lists="1", wm_limit_reached="false")
        self.assertEqual(verify_read_only_receipt(manager_rows, 3, 3)["controls"], 2)
        manager_rows[3]["details"]["window_manager_lists"] = "2"
        with self.assertRaises(ValueError):
            verify_read_only_receipt(manager_rows, 3, 3)
        with self.assertRaisesRegex(ValueError, "changed"):
            verify_read_only_receipt(read_only_rows(), 3, 4)
        for event in ("native_space_requested", "native_space_ax_pressed",
                      "space_changed", "mcp_bridge_accepted", "approval_decided"):
            with self.subTest(event=event), self.assertRaisesRegex(ValueError, "native action"):
                verify_read_only_receipt(read_only_rows() + [row(event)], 3, 3)
        changed = read_only_rows()
        changed[3]["details"]["raw_audio"] = "private"
        with self.assertRaisesRegex(ValueError, "Private"):
            verify_read_only_receipt(changed, 3, 3)


class BrowserReceiptTests(unittest.TestCase):
    def test_safari_context_requires_same_owned_window_and_tab_cleanup(self):
        run_id, port = "fixture-1234", 49328
        uuid = "A1B2C3D4-1111-2222-3333-444455556666"
        other = "B1B2C3D4-1111-2222-3333-444455556666"
        prefix = (f'Window: "Fixture", App: Safari.\n0 standard window Fixture, '
                  f'ID: SafariWindow?IsSecure=false&UUID={uuid}\n')
        sentinel = (prefix + f'5 HTML content URL: 127.0.0.1:{port}/sentinel?run_id={run_id}\n'
                    f'6 heading Voice Computer Sentinel {run_id}\n')
        acted = (prefix + f'5 HTML content URL: 127.0.0.1:{port}/docs?run_id={run_id}\n'
                 f'6 heading Voice Computer Docs {run_id}\n'
                 f'24 tab group Description: Tab bar, 2 tabs\n'
                 f'25 tab Sentinel {run_id}, Value: off\n')
        rows = [row("command_started", user_action="run"),
                row("router_decided", route="browser", action="follow_docs",
                    target="loopback_fixture"),
                row("turn_requested", route="browser"),
                row("tool_started", server="cua_repl", tool="js"),
                row("fixture_ax_verification", target="browser", verified="true",
                    reason="exact_url_and_heading"),
                row("turn_completed", status="completed", verification="verified"),
                row("command_finished", status="completed", verification="verified")]
        requests = [{"method": "GET", "path": path, "run_id": [run_id]}
                    for path in ("/sentinel", "/home", "/docs")]
        before = {other}
        observations = [sentinel, acted, sentinel]
        receipt = verify_safari_context_receipt(
            rows, run_id, port, requests, observations, before, before, 5, 5)
        self.assertEqual(receipt["context_window_id"], uuid)
        with self.assertRaisesRegex(ValueError, "inventory"):
            verify_safari_context_receipt(rows, run_id, port, requests,
                                          observations, before, before | {uuid}, 5, 5)
        with self.assertRaisesRegex(ValueError, "did not correlate"):
            verify_safari_context_receipt(rows, run_id, port, requests,
                                          [sentinel, acted], before, before, 5, 5)
        with self.assertRaisesRegex(ValueError, "did not correlate"):
            verify_safari_context_receipt(rows, run_id, port, requests,
                                          [sentinel.replace(uuid, other), acted, sentinel],
                                          before, before, 5, 5)

    def test_form_receipt_requires_exact_query_and_rendered_result(self):
        run_id, port = "fixture-1234", 49328
        rows = [
            row("command_started", user_action="run"),
            row("router_decided", route="browser", action="submit_form", target="loopback_fixture"),
            row("turn_requested", route="browser"),
            row("tool_started", server="cua_repl", tool="js"),
            row("fixture_ax_verification", target="browser_form", verified="true",
                reason="exact_url_and_heading"),
            row("turn_completed", status="completed", verification="verified"),
            row("command_finished", status="completed", verification="verified"),
        ]
        requests = [
            {"method": "GET", "path": "/docs", "run_id": [run_id]},
            {"method": "GET", "path": "/submitted", "run_id": [run_id],
             "query": [f"test-{run_id}"]},
        ]
        url = (f"http://127.0.0.1:{port}/submitted?run_id={run_id}"
               f"&query=test-{run_id}")
        observation = (f"Window: Voice Computer Fixture, App: Safari\n"
                       f"HTML content URL: {url.removeprefix('http://')}\n"
                       f"2 heading Voice Computer Submitted {run_id} test-{run_id}")
        self.assertEqual(verify_browser_receipt(
            rows, run_id, port, requests, [observation], 5, 5,
            mode="form-submit")["scenario"], "form-submit")
        wrong = copy.deepcopy(requests)
        wrong[1]["query"] = ["wrong"]
        with self.assertRaisesRegex(ValueError, "request sequence"):
            verify_browser_receipt(rows, run_id, port, wrong, [observation], 5, 5,
                                   mode="form-submit")

    def test_interruption_requires_stop_and_no_docs_request(self):
        run_id = "fixture-1234"
        rows = [
            row("command_started", user_action="run"),
            row("router_decided", route="browser", action="follow_docs", target="loopback_fixture"),
            row("turn_requested", route="browser"),
            row("tool_started", server="cua_repl", tool="js"),
            row("stop_requested"),
            row("fixture_ax_verification", target="browser", verified="false",
                reason="turn_incomplete"),
            row("turn_completed", status="interrupted", verification="unverified"),
            row("command_finished", status="interrupted", verification="unverified"),
        ]
        requests = [{"method": "GET", "path": "/home", "run_id": [run_id]}]
        receipt = verify_browser_interruption_receipt(rows, run_id, requests, 5, 5)
        self.assertEqual(receipt["docs_requests"], 0)
        with self.assertRaisesRegex(ValueError, "requested Docs"):
            verify_browser_interruption_receipt(rows, run_id, requests + [
                {"method": "GET", "path": "/docs", "run_id": [run_id]}], 5, 5)
        with self.assertRaisesRegex(ValueError, "lifecycle"):
            verify_browser_interruption_receipt(
                [entry for entry in rows if entry["event"] != "stop_requested"],
                run_id, requests, 5, 5)
        premature = copy.deepcopy(rows)
        premature[6]["details"]["status"] = "completed"
        with self.assertRaisesRegex(ValueError, "successful"):
            verify_browser_interruption_receipt(premature, run_id, requests, 5, 5)

    def test_browser_receipt_requires_correlated_render_and_requests(self):
        run_id = "fixture-1234"
        port = 49328
        url = f"http://127.0.0.1:{port}/docs?run_id={run_id}"
        rows = [
            row("command_started", user_action="run"),
            row("router_decided", route="browser", action="follow_docs", target="loopback_fixture"),
            row("turn_requested", route="browser"),
            row("tool_started", server="cua_repl", tool="js"),
            row("approval_decided", server_name="cua_repl", decision="Allowed once"),
            row("tool_completed", server="cua_repl", tool="js", status="completed"),
            row("fixture_ax_verification", target="browser", verified="true",
                reason="exact_url_and_heading"),
            row("turn_completed", status="completed", verification="verified"),
            row("command_finished", status="completed", verification="verified"),
        ]
        requests = [
            {"method": "GET", "path": "/home", "run_id": [run_id]},
            {"method": "GET", "path": "/docs", "run_id": [run_id]},
        ]
        observations = [f"Window: Voice Computer Fixture, App: Safari\n"
                        f"HTML content URL: {url.removeprefix('http://')}\n"
                        f"2 heading Voice Computer Docs {run_id}"]
        self.assertEqual(verify_browser_receipt(
            rows, run_id, port, requests, observations, 5, 5)["command_id"], COMMAND_ID)
        session_rows = copy.deepcopy(rows)
        session_rows[4]["details"]["decision"] = "Allowed for session"
        self.assertEqual(verify_browser_receipt(
            session_rows, run_id, port, requests, observations, 5, 5)["command_id"], COMMAND_ID)
        reused_rows = [entry for entry in rows if entry["event"] != "approval_decided"]
        self.assertEqual(verify_browser_receipt(
            reused_rows, run_id, port, requests, observations, 5, 5)["command_id"], COMMAND_ID)
        declined_rows = copy.deepcopy(rows)
        declined_rows[4]["details"]["decision"] = "Declined"
        with self.assertRaisesRegex(ValueError, "unexpected or declined"):
            verify_browser_receipt(declined_rows, run_id, port, requests, observations, 5, 5)
        with self.assertRaisesRegex(ValueError, "stale"):
            verify_browser_receipt(rows, run_id, port, requests, observations, 5, 5, {COMMAND_ID})
        with self.assertRaisesRegex(ValueError, "rendered"):
            verify_browser_receipt(rows, run_id, port, requests, ["Docs loaded"], 5, 5)
        with self.assertRaisesRegex(ValueError, "request sequence"):
            verify_browser_receipt(rows, run_id, port, requests[:1], observations, 5, 5)
        with self.assertRaisesRegex(ValueError, "changed desktop"):
            verify_browser_receipt(rows, run_id, port, requests, observations, 5, 6)
        unsafe = copy.deepcopy(rows)
        unsafe[3]["details"]["server"] = "desktop_tool"
        with self.assertRaisesRegex(ValueError, "only Computer Use"):
            verify_browser_receipt(unsafe, run_id, port, requests, observations, 5, 5)
        missing_ax = [entry for entry in rows if entry["event"] != "fixture_ax_verification"]
        with self.assertRaisesRegex(ValueError, "app-owned"):
            verify_browser_receipt(missing_ax, run_id, port, requests, observations, 5, 5)

    def test_negative_browser_modes_require_exact_local_result(self):
        run_id = "fixture-1234"
        port = 49328
        rows = [
            row("command_started", user_action="run"),
            row("router_decided", route="browser", action="follow_docs", target="loopback_fixture"),
            row("turn_requested", route="browser"),
            row("tool_started", server="cua_repl", tool="js"),
            row("approval_decided", server_name="cua_repl", decision="Allowed once"),
            row("fixture_ax_verification", target="browser", verified="false",
                reason="url_or_heading_mismatch"),
            row("turn_completed", status="completed", verification="unverified"),
            row("command_finished", status="completed", verification="unverified"),
        ]
        for mode, paths, final_path, heading in [
            ("missing-link", ["/home"], "/home", f"Voice Computer Home {run_id}"),
            ("home-404", ["/home"], "/home", "Fixture page not found"),
            ("redirect", ["/home", "/docs", "/error"], "/error", "Fixture page not found"),
        ]:
            with self.subTest(mode=mode):
                requests = [{"method": "GET", "path": path, "run_id": [run_id]}
                            for path in paths]
                observation = (f"Window: Voice Computer Fixture, App: Safari\n"
                               f"HTML content URL: 127.0.0.1:{port}{final_path}?run_id={run_id}\n"
                               f"2 heading {heading}")
                receipt = verify_browser_receipt(rows, run_id, port, requests,
                                                 [observation], 5, 5, mode=mode)
                self.assertEqual(receipt["scenario"], mode)
                with self.assertRaisesRegex(ValueError, "request sequence"):
                    verify_browser_receipt(rows, run_id, port, requests + requests[:1],
                                           [observation], 5, 5, mode=mode)


class FinderReceiptTests(unittest.TestCase):
    def test_missing_and_symlinked_reports_start_no_actor(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = root / "report.txt"
            rows = [
                row("command_started", user_action="run"),
                row("router_requested", mode="isolated_codex_exec"),
                row("router_decided", route="clarification"),
                row("command_finished", status="clarification", verification="no_action"),
            ]
            self.assertEqual(verify_finder_rejection_receipt(
                rows, report, 5, 5)["scenario"], "missing-file")
            with self.assertRaisesRegex(ValueError, "started an action"):
                verify_finder_rejection_receipt(
                    rows[:3] + [row("turn_requested", route="finder")] + rows[3:],
                    report, 5, 5)
            with self.assertRaisesRegex(ValueError, "acting route"):
                verify_finder_rejection_receipt(
                    rows[:2] + [row("router_decided", route="finder")] + rows[3:],
                    report, 5, 5)
            with self.assertRaisesRegex(ValueError, "changed desktop"):
                verify_finder_rejection_receipt(rows, report, 5, 6)
            with self.assertRaisesRegex(ValueError, "stale"):
                verify_finder_rejection_receipt(rows, report, 5, 5, {COMMAND_ID})
            outside = root / "outside.txt"
            outside.write_text("outside")
            report.symlink_to(outside)
            self.assertEqual(verify_finder_rejection_receipt(
                rows, report, 5, 5, mode="symlink-escape")["scenario"],
                "symlink-escape")
            with self.assertRaisesRegex(ValueError, "unexpectedly exists"):
                verify_finder_rejection_receipt(rows, report, 5, 5)
            decoy = root / "report-copy.txt"
            decoy.write_text("decoy")
            self.assertEqual(verify_finder_rejection_receipt(
                rows, decoy, 5, 5, mode="decoy-target")["scenario"],
                "decoy-target")

    def test_exact_selected_report_and_decoy(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = root / "report.txt"
            report.write_text("test")
            decoy = root / "report-copy.txt"
            decoy.write_text("decoy")
            rows = [
                row("command_started", user_action="run"),
                row("router_decided", route="finder", action="reveal_file", target="fixture_report"),
                row("turn_requested", route="finder"),
                row("tool_started", server="cua_repl", tool="js"),
                row("approval_decided", server_name="cua_repl", decision="Allowed once"),
                row("tool_completed", server="cua_repl", tool="js", status="completed"),
                row("fixture_ax_verification", target="finder", verified="true",
                    reason="exact_selected_file"),
                row("turn_completed", status="completed", verification="verified"),
                row("command_finished", status="completed", verification="verified"),
            ]
            selected = ("Window: fixture, App: Finder\n"
                        f"10 row\n11 text field URL: {decoy.as_uri()}\n"
                        f"12 row (selected)\n13 cell (selected)\n"
                        f"14 text field URL: {report.as_uri()}\n")
            self.assertEqual(verify_finder_receipt(
                rows, report, [selected], 5, 5)["command_id"], COMMAND_ID)
            session_rows = copy.deepcopy(rows)
            session_rows[4]["details"]["decision"] = "Allowed for session"
            self.assertEqual(verify_finder_receipt(
                session_rows, report, [selected], 5, 5)["command_id"], COMMAND_ID)
            reused_rows = [entry for entry in rows if entry["event"] != "approval_decided"]
            self.assertEqual(verify_finder_receipt(
                reused_rows, report, [selected], 5, 5)["command_id"], COMMAND_ID)
            declined_rows = copy.deepcopy(rows)
            declined_rows[4]["details"]["decision"] = "Declined"
            with self.assertRaisesRegex(ValueError, "unexpected or declined"):
                verify_finder_receipt(declined_rows, report, [selected], 5, 5)
            self.assertEqual(verify_finder_receipt(
                rows, report, [selected + selected], 5, 5)["command_id"], COMMAND_ID)
            with self.assertRaisesRegex(ValueError, "selection"):
                verify_finder_receipt(rows, report, [selected.replace(
                    "12 row (selected)", "12 row")], 5, 5)
            with self.assertRaisesRegex(ValueError, "stale"):
                verify_finder_receipt(rows, report, [selected], 5, 5, {COMMAND_ID})
            with self.assertRaisesRegex(ValueError, "changed desktop"):
                verify_finder_receipt(rows, report, [selected], 5, 6)


class MCPReceiptTests(unittest.TestCase):
    def check(self, rows, direction="right", before=3, after=4):
        return verify_mcp_receipt(rows, "agent switch desktop space " + direction,
                                  direction, before, after, after)

    def test_valid_right_and_left(self):
        self.assertEqual(self.check(valid_rows())["command_id"], COMMAND_ID)
        self.assertEqual(self.check(valid_rows("left", 4, 3), "left", 4, 3)["after"], 3)
        with self.assertRaisesRegex(ValueError, "fresh"):
            verify_mcp_receipt(valid_rows(), mcp_case_phrase(15), "right", 3, 4, 4,
                               {COMMAND_ID})

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


class ComposedReceiptTests(unittest.TestCase):
    def test_failed_browser_and_unsafe_file_cannot_start_next_actor(self):
        run_id = "abcd1234abcd1234abcd1234abcd1234"
        failed_browser = [
            row("command_started", user_action="run"),
            row("router_decided", route="browser_finder"),
            row("turn_requested", route="browser"),
            row("fixture_ax_verification", target="browser", verified="false",
                reason="url_or_heading_mismatch"),
            row("turn_completed", status="completed", verification="unverified"),
            row("browser_step_failed", verification="unverified"),
            row("command_finished", status="completed", verification="unverified"),
        ]
        home = [{"method": "GET", "path": "/home", "run_id": [run_id]}]
        self.assertEqual(verify_composed_failure_receipt(
            failed_browser, run_id, home, 5, 5)["finder_turns"], 0)
        with self.assertRaisesRegex(ValueError, "continued"):
            verify_composed_failure_receipt(
                failed_browser + [row("turn_requested", route="finder")],
                run_id, home, 5, 5)
        rejected = [
            row("command_started", user_action="run"),
            row("router_decided", route="clarification"),
            row("command_finished", status="clarification", verification="no_action"),
        ]
        self.assertEqual(verify_composed_rejection_receipt(
            rejected, [], 5, 5)["browser_turns"], 0)
        with self.assertRaisesRegex(ValueError, "started an action"):
            verify_composed_rejection_receipt(rejected, home, 5, 5)

    def test_requires_ordered_verified_browser_then_finder_under_one_command(self):
        run_id, port = "abcd1234abcd1234abcd1234abcd1234", 49328
        with tempfile.TemporaryDirectory() as directory:
            report = Path(directory) / "report.txt"
            report.write_text("report")
            report.with_name("report-copy.txt").write_text("decoy")
            rows = [
                row("command_started", user_action="run"),
                row("router_decided", route="browser_finder"),
                row("turn_requested", route="browser"),
                row("tool_started", server="cua_repl", tool="js", item_id="browser-tool"),
                row("tool_completed", server="cua_repl", tool="js", item_id="browser-tool",
                    status="completed", result_is_error="false"),
                row("fixture_ax_verification", target="browser", verified="true",
                    reason="exact_url_and_heading"),
                row("turn_completed", status="completed", verification="verified"),
                row("browser_step_verified", turn_id="browser-turn"),
                row("turn_requested", route="finder"),
                row("tool_started", server="cua_repl", tool="js", item_id="finder-tool"),
                row("tool_completed", server="cua_repl", tool="js", item_id="finder-tool",
                    status="completed", result_is_error="false"),
                row("fixture_ax_verification", target="finder", verified="true",
                    reason="exact_selected_file"),
                row("turn_completed", status="completed", verification="verified"),
                row("finder_step_verified", turn_id="finder-turn"),
                row("command_finished", status="completed", verification="verified"),
            ]
            requests = [{"method": "GET", "path": path, "run_id": [run_id]}
                        for path in ("/home", "/docs")]
            browser = [f"Window: Safari\nHTML content URL: 127.0.0.1:{port}/docs?run_id={run_id}"
                       f"\n2 heading Voice Computer Docs {run_id}"]
            finder = [f"Window: Finder\n1 row (selected) URL: {report.as_uri()}"
                      f"\n2 row URL: {report.with_name('report-copy.txt').as_uri()}"]
            def check(current):
                return verify_composed_receipt(current, run_id, port, requests, report,
                                               browser, finder, 5, 5)
            self.assertEqual(check(rows)["turns"], 2)
            moved = copy.deepcopy(rows)
            moved.insert(7, moved.pop(8))
            with self.assertRaisesRegex(ValueError, "Finder started before"):
                check(moved)
            missing = [entry for entry in rows if entry["event"] != "browser_step_verified"]
            with self.assertRaises(ValueError):
                check(missing)
            with self.assertRaisesRegex(ValueError, "changed desktop Space"):
                verify_composed_receipt(rows, run_id, port, requests, report,
                                        browser, finder, 5, 6)
            wrong_selection = [
                f"Window: Finder\n1 row (selected) URL: {report.with_name('report-copy.txt').as_uri()}"
                f"\n2 row URL: {report.as_uri()}"]
            with self.assertRaisesRegex(ValueError, "Independent exact Finder selection missing"):
                verify_composed_receipt(rows, run_id, port, requests, report,
                                        browser, wrong_selection, 5, 5)
            failed_cua = copy.deepcopy(rows)
            failed_cua[4]["details"]["status"] = "failed"
            with self.assertRaisesRegex(ValueError, "call failed"):
                check(failed_cua)


class DesktopStateReceiptTests(unittest.TestCase):
    def test_requires_correlated_read_and_independent_state(self):
        now = datetime.now(timezone.utc).isoformat()
        rows = [
            row("command_started", user_action="run"),
            row("mcp_state_requested"),
            row("turn_requested", route="desktop_state"),
            row("tool_started", server="desktop_tool", tool="get_desktop_state",
                item_id="state-item"),
            row("approval_decided", server_name="desktop_tool", decision="Allowed once"),
            row("mcp_state_helper_bound", path_matches_preflight="true"),
            row("mcp_state_observed", status="observed", space_id="5",
                ordered_space_ids="5,6", frontmost_bundle_id="com.neonwatty.VoiceComputerPOC",
                observed_at=now),
            row("mcp_state_result_correlated", item_id="state-item"),
            row("tool_completed", item_id="state-item", status="completed",
                result_is_error="false", typed_status="observed", typed_verified="true"),
            row("turn_completed", verification="verified"),
            row("command_finished", verification="verified"),
        ]
        rows[6]["timestamp"] = now
        state = {"current": 5, "ordered": [5, 6]}
        def check(current=rows, after=state, frontmost="com.neonwatty.VoiceComputerPOC"):
            return verify_desktop_state_receipt(current, state, after, frontmost)
        self.assertEqual(check()["space_id"], 5)
        with self.assertRaisesRegex(ValueError, "Independent desktop Space"):
            check(after={"current": 6, "ordered": [5, 6]})
        with self.assertRaisesRegex(ValueError, "foreground app"):
            check(frontmost="com.apple.finder")
        changed = copy.deepcopy(rows)
        changed[4]["details"]["decision"] = "Allowed for session"
        with self.assertRaisesRegex(ValueError, "Allow once"):
            check(current=changed)


if __name__ == "__main__":
    unittest.main()
