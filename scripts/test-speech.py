#!/usr/bin/env python3
"""Run speech tests with a local, resumable download fixture (no model download)."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import os
import subprocess
import sys
import threading
import time


class DownloadFixture(BaseHTTPRequestHandler):
    def do_GET(self):
        total = 2_097_152
        try:
            start = int(self.headers.get("Range", "bytes=0-").split("=")[1].split("-")[0])
            if not 0 <= start < total:
                raise ValueError()
        except (ValueError, IndexError):
            self.send_error(416)
            return
        self.send_response(206 if start else 200)
        self.send_header("Content-Length", str(total - start))
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("ETag", '"spectty-test-v1"')
        self.send_header("Last-Modified", "Wed, 11 Nov 2026 00:00:00 GMT")
        if start:
            self.send_header("Content-Range", f"bytes {start}-{total - 1}/{total}")
        self.end_headers()
        try:
            for position in range(start, total, 16_384):
                self.wfile.write(b"A" * min(16_384, total - position))
                self.wfile.flush()
                time.sleep(0.02)
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    root = Path(__file__).resolve().parent.parent
    with ThreadingHTTPServer(("127.0.0.1", 0), DownloadFixture) as server:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            result = subprocess.run(
                ["swift", "test", "--package-path", str(root / "Packages/SpecttySpeech"), *sys.argv[1:]],
                env={**os.environ, "SPECTTY_DOWNLOAD_TEST_URL": f"http://127.0.0.1:{server.server_port}"},
            )
        finally:
            server.shutdown()
    sys.exit(result.returncode)
