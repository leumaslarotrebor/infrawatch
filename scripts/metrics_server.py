#!/usr/bin/env python3
"""
InfraWatch metrics server — serves Prometheus-format metrics over HTTP.
Reads from the file written by monitor.sh and exposes /metrics endpoint.
Covers: REST/HTTP endpoints, observability, Python, structured responses.
"""

import http.server
import os
import time
import threading
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
    def do_GET(self):
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
            self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
            self.end_headers()
            self.wfile.write(content.encode())
            logger.info("Metrics served — %d bytes", len(content))
        except FileNotFoundError:
            self.send_response(503)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
            self.wfile.write(b"# Metrics file not yet available — monitor.sh may still be starting\n")
        except Exception as e:
            logger.error("Error serving metrics: %s", e)
            self.send_response(500)
            self.end_headers()

    def _serve_health(self):
        """Health check endpoint — used by Docker HEALTHCHECK and load balancers."""
        metrics_age = None
        status = "degraded"

        try:
            mtime = os.path.getmtime(METRICS_FILE)
            metrics_age = int(time.time() - mtime)
            # Healthy if metrics file updated within last 2 check intervals (60s default)
            status = "ok" if metrics_age < 60 else "stale"
        except FileNotFoundError:
            status = "no-data"

        body = f'{{"status":"{status}","metrics_age_seconds":{metrics_age},"service":"infrawatch"}}\n'
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
  <li><a href="/metrics">/metrics</a> — Prometheus metrics endpoint</li>
  <li><a href="/health">/health</a> — Health check (JSON)</li>
</ul>
</body></html>"""
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        # Suppress default access log — we use our own structured logger
        pass


def main():
    server = http.server.ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), MetricsHandler)
    logger.info("InfraWatch metrics server listening on %s:%d", LISTEN_HOST, LISTEN_PORT)
    logger.info("Endpoints: /metrics  /health  /")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down")
        server.shutdown()


if __name__ == "__main__":
    main()
