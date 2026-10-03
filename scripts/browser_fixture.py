#!/usr/bin/env python3
"""Disposable loopback pages for the Voice Computer Browser smoke test."""

import argparse
import html
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import re
from urllib.parse import parse_qs, urlsplit


RUN_ID = re.compile(r"[A-Za-z0-9-]{8,64}\Z")


def make_server(run_id, log_path, mode="normal"):
    if not RUN_ID.fullmatch(run_id):
        raise ValueError("run ID must be 8–64 letters, digits, or hyphens")
    if mode not in {"normal", "missing-link", "redirect", "home-404"}:
        raise ValueError("unsupported fixture mode")
    log_path.touch(mode=0o600, exist_ok=True)

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            parsed = urlsplit(self.path)
            supplied_id = parse_qs(parsed.query).get("run_id", [])
            path = parsed.path
            with log_path.open("a", encoding="utf-8") as receipt:
                receipt.write(json.dumps({"method": "GET", "path": path,
                                          "run_id": supplied_id}, sort_keys=True) + "\n")
            if supplied_id != [run_id]:
                self.respond(404, "Unknown test run")
            elif path == "/home" and mode == "home-404":
                self.respond(404, "<h1>Fixture page not found</h1>")
            elif path == "/home":
                link = ("" if mode == "missing-link" else
                        f'<a href="/docs?run_id={run_id}">Docs</a>')
                self.respond(200, f"<h1>Voice Computer Home {html.escape(run_id)}</h1>{link}")
            elif path == "/docs" and mode == "redirect":
                self.send_response(302)
                self.send_header("Location", f"/error?run_id={run_id}")
                self.end_headers()
            elif path == "/docs":
                self.respond(200, f"<h1>Voice Computer Docs {html.escape(run_id)}</h1>"
                         f'<form method="get" action="/submitted">'
                         f'<input name="run_id" value="{run_id}" type="hidden">'
                         '<input name="query" aria-label="Query"><button>Submit</button></form>')
            else:
                self.respond(404, "<h1>Fixture page not found</h1>")

        def respond(self, status, body):
            page = f"<!doctype html><html><head><title>Voice Computer Fixture</title></head>"
            page += f"<body>{body}</body></html>"
            encoded = page.encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'")
            self.send_header("Content-Length", str(len(encoded)))
            self.end_headers()
            self.wfile.write(encoded)

        def log_message(self, *_args):
            pass

    return ThreadingHTTPServer(("127.0.0.1", 0), Handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--mode", default="normal",
                        choices=("normal", "missing-link", "redirect", "home-404"))
    args = parser.parse_args()
    os.umask(0o077)
    args.log.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    args.log.touch(mode=0o600, exist_ok=True)
    server = make_server(args.run_id, args.log, args.mode)
    print(f"http://127.0.0.1:{server.server_port}/home?run_id={args.run_id}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
