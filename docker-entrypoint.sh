#!/usr/bin/env bash
set -euo pipefail

cleanup() {
  kill "$MONITOR_PID" "$SERVER_PID" 2>/dev/null || true
  wait "$MONITOR_PID" "$SERVER_PID" 2>/dev/null || true
  exit 0
}

trap cleanup SIGTERM SIGINT

bash /opt/infrawatch/scripts/monitor.sh &
MONITOR_PID=$!

python3 /opt/infrawatch/scripts/metrics_server.py 2>&1 &
SERVER_PID=$!

wait -n "$MONITOR_PID" "$SERVER_PID"
cleanup
