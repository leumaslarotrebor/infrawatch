#!/usr/bin/env python3
"""
InfraWatch metrics server — serves Prometheus-format metrics over HTTP.
Reads from the file written by monitor.sh and exposes /metrics endpoint.
"""

import http.server
import os
import time
import logging

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%dT%H:%M:%SZ",
)
logger = logging.getLogger("infrawatch.metrics-server")

METRICS_FILE = os.environ.get("METRICS_FILE", "/var/lib/infrawatch/metrics.prom")
LISTEN_PORT = int(os.environ.get("METRICS_PORT", 9100))
LISTEN_HOST = os.environ.get("METRICS_HOST", "0.0.0.0")


class MetricsHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):  # noqa: N802
        if self.path == "/metrics":
            self._serve_metrics()
        elif self.path == "/health":
            self._serve_health()
        elif self.path == "/":
            self._serve_index()
        else:
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"Not found\n")

    def _serve_metrics(self):
        try:
            with open(METRICS_FILE, "r") as f:
                content = f.read()
            self.send_response(200)
            self.send_header(
                "Content-Type",
                "text/plain; version=0.0.4; charset=utf-8",
            )
            self.end_headers()
            self.wfile.write(content.encode())
            logger.info("Metrics served — %d bytes", len(content))
        except FileNotFoundError:
            self.send_response(503)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"# Metrics file not yet available\n")
        except Exception as e:  # noqa: BLE001
            logger.error("Error serving metrics: %s", e)
            self.send_response(500)
            self.end_headers()

    def _serve_health(self):
        """Health check endpoint — used by Docker HEALTHCHECK."""
        metrics_age: int | None = None
        status = "degraded"

        try:
            mtime = os.path.getmtime(METRICS_FILE)
            metrics_age = int(time.time() - mtime)
            status = "ok" if metrics_age < 60 else "stale"
        except FileNotFoundError:
            status = "no-data"

        age_str = str(metrics_age) if metrics_age is not None else "null"
        body = (
            f'{{"status":"{status}",'
            f'"metrics_age_seconds":{age_str},'
            f'"service":"infrawatch"}}\n'
        )
        http_status = 200 if status == "ok" else 503

        self.send_response(http_status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body.encode())

    def _serve_index(self):
        body = b"""<!DOCTYPE html>
<html><head><title>InfraWatch</title></head><body>
<h1>InfraWatch Metrics Server</h1>
<ul>
  <li><a href="/metrics">/metrics</a> - Prometheus metrics</li>
  <li><a href="/health">/health</a> - Health check (JSON)</li>
</ul>
</body></html>"""
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):  # noqa: A002
        pass


def main():
    server = http.server.ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), MetricsHandler)
    logger.info(
        "InfraWatch metrics server listening on %s:%d",
        LISTEN_HOST,
        LISTEN_PORT,
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down")
        server.shutdown()


if __name__ == "__main__":
    main()
