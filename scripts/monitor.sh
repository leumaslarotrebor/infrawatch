#!/usr/bin/env bash
# InfraWatch — system health monitor with auto-remediation
# shellcheck disable=SC2312

set -x
set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
CPU_THRESHOLD=${CPU_THRESHOLD:-80}
MEM_THRESHOLD=${MEM_THRESHOLD:-85}
DISK_THRESHOLD=${DISK_THRESHOLD:-90}
SERVICES=${SERVICES:-"nginx docker"}
LOG_FILE=${LOG_FILE:-"/var/log/infrawatch/incidents.log"}
METRICS_FILE=${METRICS_FILE:-"/var/lib/infrawatch/metrics.prom"}
CHECK_INTERVAL=${CHECK_INTERVAL:-30}

# ── Setup ─────────────────────────────────────────────────────────────────────
mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$METRICS_FILE")"

log_incident() {
  local severity="$1"
  local message="$2"
  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "[$timestamp] [$severity] $message" | tee -a "$LOG_FILE"
}

# ── CPU Check ─────────────────────────────────────────────────────────────────
check_cpu() {
  local cpu_idle cpu_usage
  cpu_idle=$(awk '/^cpu / {idle=$5; total=0; for(i=2;i<=NF;i++) total+=$i; printf "%.1f", idle/total*100}' /proc/stat)
  cpu_usage=$(echo "100 - $cpu_idle" | bc)

  echo "infrawatch_cpu_usage_percent $cpu_usage" >> "$METRICS_FILE"

  local threshold_exceeded
  threshold_exceeded=$(echo "$cpu_usage > $CPU_THRESHOLD" | bc -l)
  if [ "$threshold_exceeded" = "1" ]; then
    log_incident "WARN" "CPU usage ${cpu_usage}% exceeds threshold ${CPU_THRESHOLD}%"
    local top_procs
    top_procs=$(ps aux --sort=-%cpu | awk 'NR>1 && NR<=4 {print $11"("$3"%)"}')
    log_incident "INFO" "Top CPU consumers: $top_procs"
  fi

  echo "$cpu_usage"
}

# ── Memory Check ──────────────────────────────────────────────────────────────
check_memory() {
  local mem_total mem_available mem_used mem_pct
  mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
  mem_available=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
  mem_used=$(( mem_total - mem_available ))
  mem_pct=$(echo "scale=1; $mem_used * 100 / $mem_total" | bc)

  {
    echo "infrawatch_memory_usage_percent $mem_pct"
    echo "infrawatch_memory_used_bytes $(( mem_used * 1024 ))"
    echo "infrawatch_memory_total_bytes $(( mem_total * 1024 ))"
  } >> "$METRICS_FILE"

  local threshold_exceeded
  threshold_exceeded=$(echo "$mem_pct > $MEM_THRESHOLD" | bc -l)
  if [ "$threshold_exceeded" = "1" ]; then
    log_incident "WARN" "Memory usage ${mem_pct}% exceeds threshold ${MEM_THRESHOLD}%"
    local top_procs
    top_procs=$(ps aux --sort=-%mem | awk 'NR>1 && NR<=4 {print $11"("$4"%)"}')
    log_incident "INFO" "Top memory consumers: $top_procs"
  fi

  echo "$mem_pct"
}

# ── Disk Check ────────────────────────────────────────────────────────────────
check_disk() {
  local status=0
  while IFS= read -r line; do
    local use_pct mount
    use_pct=$(echo "$line" | awk '{print $1}' | tr -d '%')
    mount=$(echo "$line" | awk '{print $2}')

    echo "infrawatch_disk_usage_percent{mount=\"$mount\"} $use_pct" >> "$METRICS_FILE"

    if (( use_pct > DISK_THRESHOLD )); then
      log_incident "CRIT" "Disk ${mount} at ${use_pct}% — exceeds threshold ${DISK_THRESHOLD}%"
      status=1
    fi
  done < <(df -h --output=pcent,target | tail -n +2 | grep -v tmpfs)

  echo "$status"
}

# ── Network Check ─────────────────────────────────────────────────────────────
check_network() {
  if ! dig +short google.com > /dev/null 2>&1; then
    log_incident "CRIT" "DNS resolution failed — check /etc/resolv.conf and upstream DNS"
    echo "infrawatch_dns_ok 0" >> "$METRICS_FILE"
  else
    echo "infrawatch_dns_ok 1" >> "$METRICS_FILE"
  fi

  local open_ports
  open_ports=$(ss -tulpn | awk 'NR>1 {print $5}' | awk -F: '{print $NF}' | grep -E '^[0-9]+$' | sort -un | tr '\n' ',' | sed 's/,$//' || true)
  log_incident "INFO" "Open ports: $open_ports"
}

# ── Service Check + Auto-Remediation ─────────────────────────────────────────
check_services() {
  for svc in $SERVICES; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      echo "infrawatch_service_up{service=\"$svc\"} 1" >> "$METRICS_FILE"
      log_incident "INFO" "Service $svc is running"
    else
      echo "infrawatch_service_up{service=\"$svc\"} 0" >> "$METRICS_FILE"
      log_incident "CRIT" "Service $svc is DOWN — attempting restart"

      if systemctl restart "$svc" 2>/dev/null; then
        sleep 3
        if systemctl is-active --quiet "$svc"; then
          log_incident "INFO" "Service $svc successfully restarted"
          echo "infrawatch_service_up{service=\"$svc\"} 1" >> "$METRICS_FILE"
          echo "infrawatch_remediation_count{service=\"$svc\"} 1" >> "$METRICS_FILE"
        else
          log_incident "CRIT" "Service $svc restart FAILED — manual intervention required"
        fi
      else
        log_incident "CRIT" "Cannot restart $svc — insufficient privileges or systemd unavailable"
      fi
    fi
  done
}

# ── Prometheus Metrics Writer ─────────────────────────────────────────────────
write_metrics_header() {
  cat > "$METRICS_FILE" << EOF
# HELP infrawatch_cpu_usage_percent Current CPU usage percentage
# TYPE infrawatch_cpu_usage_percent gauge
# HELP infrawatch_memory_usage_percent Current memory usage percentage
# TYPE infrawatch_memory_usage_percent gauge
# HELP infrawatch_disk_usage_percent Disk usage percentage by mount
# TYPE infrawatch_disk_usage_percent gauge
# HELP infrawatch_service_up Service availability (1=up, 0=down)
# TYPE infrawatch_service_up gauge
# HELP infrawatch_dns_ok DNS resolution health (1=ok, 0=fail)
# TYPE infrawatch_dns_ok gauge
# HELP infrawatch_remediation_count Number of auto-remediation actions taken
# TYPE infrawatch_remediation_count counter
# HELP infrawatch_last_check_timestamp Unix timestamp of last check
# TYPE infrawatch_last_check_timestamp gauge
EOF
}

# ── Main Loop ─────────────────────────────────────────────────────────────────
main() {
  log_incident "INFO" "InfraWatch starting — interval=${CHECK_INTERVAL}s thresholds: CPU=${CPU_THRESHOLD}% MEM=${MEM_THRESHOLD}% DISK=${DISK_THRESHOLD}%"

  while true; do
    write_metrics_header

    log_incident "INFO" "--- Health check cycle start ---"

    cpu=$(check_cpu)
    mem=$(check_memory)
    disk_status=$(check_disk)
    check_network
    check_services

    echo "infrawatch_last_check_timestamp $(date +%s)" >> "$METRICS_FILE"

    log_incident "INFO" "Cycle complete — CPU:${cpu}% MEM:${mem}% DISK_ALERT:${disk_status}"
    sleep "$CHECK_INTERVAL"
  done
}

main "$@"
