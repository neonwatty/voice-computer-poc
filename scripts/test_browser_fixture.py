import json
from pathlib import Path
import tempfile
import threading
import unittest
from urllib.error import HTTPError
from urllib.request import urlopen

from browser_fixture import make_server


class BrowserFixtureTests(unittest.TestCase):
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
        status, _, final_url, rows = self.request("redirect", "/docs?run_id=fixture-1234")
        self.assertEqual(status, 404)
        self.assertIn("/error?run_id=fixture-1234", final_url)
        self.assertEqual([row["path"] for row in rows], ["/docs", "/error"])
        status, _, _, _ = self.request("normal", "/home?run_id=other-run")
        self.assertEqual(status, 404)


if __name__ == "__main__":
    unittest.main()
