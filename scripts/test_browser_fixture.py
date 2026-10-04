import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from urllib.error import HTTPError
from urllib.request import urlopen

from browser_fixture import make_server


class BrowserFixtureTests(unittest.TestCase):
    def test_held_home_serves_docs_link_only_after_release(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "requests.jsonl"
            requested, release = threading.Event(), threading.Event()
            server = make_server("fixture-1234", log, "hold-home", requested, release)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            page = {}
            def fetch():
                with urlopen(f"http://127.0.0.1:{server.server_port}/home?run_id=fixture-1234",
                             timeout=5) as response:
                    page["body"] = response.read().decode()
            request = threading.Thread(target=fetch)
            request.start()
            try:
                self.assertTrue(requested.wait(timeout=2))
                time.sleep(0.1)
                self.assertTrue(request.is_alive())
                self.assertEqual([json.loads(line)["path"] for line in log.read_text().splitlines()],
                                 ["/home"])
                release.set()
                request.join(timeout=3)
                self.assertFalse(request.is_alive())
                self.assertIn('href="/docs?run_id=fixture-1234"', page["body"])
            finally:
                release.set()
                server.shutdown()
                server.server_close()
                thread.join(timeout=3)

    def request(self, mode, path):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "requests.jsonl"
            server = make_server("fixture-1234", log, mode)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                url = f"http://127.0.0.1:{server.server_port}{path}"
                try:
                    with urlopen(url, timeout=3) as response:
                        status, body, final_url = response.status, response.read().decode(), response.url
                except HTTPError as error:
                    status, body, final_url = error.code, error.read().decode(), error.url
                rows = [json.loads(line) for line in log.read_text().splitlines()]
                return status, body, final_url, rows
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=3)

    def test_home_docs_and_run_id_receipts(self):
        status, body, _, rows = self.request("normal", "/home?run_id=fixture-1234")
        self.assertEqual(status, 200)
        self.assertIn('href="/docs?run_id=fixture-1234"', body)
        self.assertEqual(rows, [{"method": "GET", "path": "/home", "run_id": ["fixture-1234"]}])
        status, body, final_url, _ = self.request("normal", "/docs?run_id=fixture-1234")
        self.assertEqual(status, 200)
        self.assertTrue(final_url.endswith("/docs?run_id=fixture-1234"))
        self.assertIn("Voice Computer Docs fixture-1234", body)

    def test_negative_pages_stay_on_loopback(self):
        status, body, _, _ = self.request("missing-link", "/home?run_id=fixture-1234")
        self.assertEqual(status, 200)
        self.assertNotIn("<a ", body)
        status, body, _, rows = self.request("home-404", "/home?run_id=fixture-1234")
        self.assertEqual(status, 404)
        self.assertIn("<h1>Fixture page not found</h1>", body)
        self.assertEqual([row["path"] for row in rows], ["/home"])
        status, _, final_url, rows = self.request("redirect", "/docs?run_id=fixture-1234")
        self.assertEqual(status, 404)
        self.assertIn("/error?run_id=fixture-1234", final_url)
        self.assertEqual([row["path"] for row in rows], ["/docs", "/error"])
        status, _, _, _ = self.request("normal", "/home?run_id=other-run")
        self.assertEqual(status, 404)

    def test_form_submission_requires_exact_query(self):
        run_id = "fixture-1234"
        status, body, _, rows = self.request(
            "form-submit", f"/submitted?run_id={run_id}&query=test-{run_id}")
        self.assertEqual(status, 200)
        self.assertIn(f"Voice Computer Submitted {run_id} test-{run_id}", body)
        self.assertEqual(rows[0]["query"], [f"test-{run_id}"])
        status, _, _, _ = self.request(
            "form-submit", f"/submitted?run_id={run_id}&query=wrong")
        self.assertEqual(status, 404)


if __name__ == "__main__":
    unittest.main()
