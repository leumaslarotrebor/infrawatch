![CI](https://github.com/leumaslarotrebor/infrawatch/actions/workflows/ci.yml/badge.svg)

# InfraWatch

A lightweight Linux server health monitoring and auto-remediation agent with a Prometheus metrics endpoint, Grafana dashboards, Docker containerization, and Ansible-based deployment automation.

Built to demonstrate core SRE practices: observability, infrastructure-as-code, containerization, CI/CD, and incident response.

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  InfraWatch Agent                   │
│                  (Docker container)                 │
│                                                     │
│  ┌──────────────────┐    ┌───────────────────────┐  │
│  │   monitor.sh     │    │  metrics_server.py    │  │
│  │                  │───▶│                       │  │
│  │ • CPU check      │    │ GET /metrics  → Prom  │  │
│  │ • Memory check   │    │ GET /health   → JSON  │  │
│  │ • Disk check     │    │                       │  │
│  │ • DNS check      │    └───────────┬───────────┘  │
│  │ • Service check  │                │ :9100         │
│  │ • Auto-restart   │                │               │
│  └──────────────────┘                │               │
└──────────────────────────────────────┼───────────────┘
                                       │
                           ┌───────────▼──────────┐
                           │      Prometheus       │
                           │   scrapes /metrics    │
                           │   every 30 seconds    │
                           └───────────┬───────────┘
                                       │
                           ┌───────────▼──────────┐
                           │        Grafana        │
                           │   dashboards :3000    │
                           └──────────────────────┘

Deployment:
  GitHub Actions CI → lints + builds → Docker Hub
  Ansible playbook  → provisions server → pulls image → starts stack
```

---

## What it monitors

| Metric | Check | Action on breach |
|---|---|---|
| CPU usage | Every 30s via `/proc/stat` | Log incident + top consumers |
| Memory usage | Every 30s via `/proc/meminfo` | Log incident + top consumers |
| Disk usage | Every 30s via `df` | Log CRIT incident per mount |
| DNS resolution | Every 30s via `dig` | Log CRIT + emit metric |
| Service health | Every 30s via `systemctl` | Auto-restart + verify + log |

---

## Quick start

### Run locally with Docker Compose

```bash
git clone https://github.com/your-username/infrawatch
cd infrawatch
docker compose up -d
```

| Service | URL |
|---|---|
| Metrics | http://localhost:9100/metrics |
| Health check | http://localhost:9100/health |
| Prometheus | http://localhost:9090 |
| Grafana | http://localhost:3000 (admin / infrawatch) |

### Run monitor script directly (on Linux host)

```bash
chmod +x scripts/monitor.sh
CPU_THRESHOLD=70 CHECK_INTERVAL=10 bash scripts/monitor.sh
```

### Deploy to a remote server with Ansible

```bash
# 1. Edit ansible/inventory.ini with your server IP
# 2. Run the playbook
ansible-playbook -i ansible/inventory.ini ansible/deploy.yml

# Dry run first (recommended)
ansible-playbook -i ansible/inventory.ini ansible/deploy.yml --check

# Only run docker-related tasks
ansible-playbook -i ansible/inventory.ini ansible/deploy.yml --tags docker
```

---

## Configuration

All settings are environment variables — no config files to manage.

| Variable | Default | Description |
|---|---|---|
| `CPU_THRESHOLD` | `80` | CPU % that triggers a warning log |
| `MEM_THRESHOLD` | `85` | Memory % that triggers a warning log |
| `DISK_THRESHOLD` | `90` | Disk % that triggers a critical log |
| `SERVICES` | `""` | Space-separated services to monitor (e.g. `"nginx docker"`) |
| `CHECK_INTERVAL` | `30` | Seconds between health check cycles |
| `METRICS_PORT` | `9100` | Port for the Prometheus metrics endpoint |
| `LOG_FILE` | `/var/log/infrawatch/incidents.log` | Incident log path |

---

## Prometheus metrics exposed

```
infrawatch_cpu_usage_percent          gauge   Current CPU usage %
infrawatch_memory_usage_percent       gauge   Current memory usage %
infrawatch_memory_used_bytes          gauge   Memory used in bytes
infrawatch_memory_total_bytes         gauge   Total memory in bytes
infrawatch_disk_usage_percent{mount}  gauge   Disk usage % per mount
infrawatch_service_up{service}        gauge   1=running, 0=down
infrawatch_dns_ok                     gauge   1=resolving, 0=failing
infrawatch_remediation_count{service} counter Auto-restart actions taken
infrawatch_last_check_timestamp       gauge   Unix timestamp of last check
```

---

## Incident runbook

This runbook covers how to interpret and respond to InfraWatch alerts.

### CPU alert (WARN)

**Symptom:** `[WARN] CPU usage XX% exceeds threshold 80%`

**Immediate steps:**
1. Check which process is consuming CPU: `ps aux --sort=-%cpu | head -10`
2. Check if the process is expected: `systemctl status <process-name>`
3. If a runaway process: `kill -15 <PID>` (graceful) or `kill -9 <PID>` (force)
4. If sustained high CPU on a web service: check for traffic spike with `ss -s`

**Resolution:** Identify root cause, document in incident log, adjust threshold if the load is expected.

---

### Memory alert (WARN)

**Symptom:** `[WARN] Memory usage XX% exceeds threshold 85%`

**Immediate steps:**
1. Identify top memory consumers: `ps aux --sort=-%mem | head -10`
2. Check for memory leaks: compare memory over time in Grafana
3. If a specific service: `systemctl restart <service>` — InfraWatch will auto-log this
4. Clear page cache if needed (caution on production): `echo 1 > /proc/sys/vm/drop_caches`

---

### Disk critical (CRIT)

**Symptom:** `[CRIT] Disk /var at 92% — exceeds threshold 90%`

**Immediate steps:**
1. Find large files: `du -sh /* 2>/dev/null | sort -rh | head -20`
2. Check logs: `du -sh /var/log/*` — rotate or compress if needed
3. Check Docker images: `docker system df` → `docker system prune` if safe
4. Check for old kernels: `dpkg -l linux-image-* | grep ^ii`

---

### DNS failure (CRIT)

**Symptom:** `[CRIT] DNS resolution failed — check /etc/resolv.conf and upstream DNS`

**Immediate steps:**
1. Check current DNS config: `cat /etc/resolv.conf`
2. Test resolution manually: `dig google.com @8.8.8.8`
3. If upstream is down, temporarily set a working resolver: `echo "nameserver 8.8.8.8" > /etc/resolv.conf`
4. Check if systemd-resolved is running: `systemctl status systemd-resolved`

---

### Service down (CRIT)

**Symptom:** `[CRIT] Service nginx is DOWN — attempting restart`

InfraWatch auto-restarts the service. Check the follow-up log line:
- `[INFO] Service nginx successfully restarted` → monitor for recurrence
- `[CRIT] Service nginx restart FAILED` → manual intervention needed

**Manual steps if auto-restart failed:**
1. Check service status: `systemctl status nginx`
2. Check service logs: `journalctl -u nginx -n 50`
3. Check config: `nginx -t` (for nginx), adjust and restart manually
4. If port conflict: `ss -tulpn | grep :80`

---

## Project structure

```
infrawatch/
├── Dockerfile                    # Multi-stage Docker build
├── docker-compose.yml            # Full stack: agent + Prometheus + Grafana
├── docker-entrypoint.sh          # Starts monitor + metrics server
├── prometheus.yml                # Prometheus scrape config
├── scripts/
│   ├── monitor.sh                # Core monitoring + auto-remediation (Bash)
│   └── metrics_server.py         # Prometheus metrics HTTP server (Python)
├── ansible/
│   ├── deploy.yml                # Full deployment playbook
│   └── inventory.ini             # Server inventory (edit before use)
├── grafana/
│   └── dashboards/               # Pre-built Grafana dashboard JSON
└── .github/
    └── workflows/
        └── ci.yml                # GitHub Actions: lint → build → push
```

---

## Skills demonstrated

| Skill | Where |
|---|---|
| Linux CLI + Bash scripting | `scripts/monitor.sh` — reads `/proc/stat`, `/proc/meminfo`, uses `ss`, `dig`, `df`, `ps` |
| Process management | monitor.sh auto-restarts failed services via `systemctl` |
| Docker + Dockerfile | Multi-stage Dockerfile, HEALTHCHECK, non-root user, `.env` config |
| Ansible playbook authoring | `ansible/deploy.yml` — idempotent tasks, handlers, variables, tags |
| Prometheus/Grafana | Custom metrics endpoint + docker-compose Prometheus stack |
| CI/CD (GitHub Actions) | Lint (shellcheck, flake8, ansible-lint) → build → push pipeline |
| Incident response runbook | This README — structured runbook for every alert type |
| REST API / HTTP | `metrics_server.py` — `/metrics`, `/health`, `/` endpoints |

---

## Resume bullet points (ready to use)

```
InfraWatch — Linux Server Health Monitor & Auto-Remediation Agent
Python · Bash · Docker · Ansible · Prometheus/Grafana · GitHub Actions

• Built a real-time Linux health monitoring agent in Bash that reads /proc/stat,
  /proc/meminfo, and df to track CPU, memory, disk, DNS, and service health;
  implemented auto-remediation logic that detects downed services, triggers
  systemctl restart, verifies recovery, and logs structured incident reports

• Containerized the agent with a multi-stage Docker build (alpine base, non-root
  user, HEALTHCHECK); exposed a Prometheus-compatible /metrics endpoint via a
  Python HTTP server; integrated Prometheus + Grafana via docker-compose for
  end-to-end observability

• Authored an Ansible playbook with idempotent tasks, handlers, and tags to
  provision a fresh Ubuntu server, install Docker, deploy the full monitoring
  stack, and configure UFW firewall rules — zero-touch deployment

• Set up a GitHub Actions CI pipeline that runs shellcheck on Bash, flake8 on
  Python, ansible-lint on playbooks, and builds/tests the Docker image on every
  push — pushes to Docker Hub on main branch merge

• Wrote a production-style incident runbook covering CPU, memory, disk, DNS, and
  service failure scenarios with step-by-step diagnosis and resolution commands
```
