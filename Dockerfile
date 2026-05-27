# InfraWatch — Dockerfile
# Multi-stage build to keep final image lean
# Covers: Docker, image management, Dockerfile authoring, best practices

# ── Stage 1: dependency check (could add pip installs here if needed) ─────────
FROM python:3.12-alpine AS base

RUN apk add --no-cache \
    bash \
    bc \
    bind-tools \
    iproute2 \
    procps \
    coreutils \
    && rm -rf /var/cache/apk/*

# ── Stage 2: runtime image ────────────────────────────────────────────────────
FROM base AS runtime

LABEL maintainer="Samuel Oral Robert V"
LABEL description="InfraWatch — Linux system health monitor with Prometheus metrics"
LABEL version="1.0.0"

# Create non-root user for security best practice
RUN addgroup -S infrawatch && adduser -S infrawatch -G infrawatch

# Create required directories with correct ownership
RUN mkdir -p /var/log/infrawatch /var/lib/infrawatch /opt/infrawatch/scripts \
    && chown -R infrawatch:infrawatch /var/log/infrawatch /var/lib/infrawatch

WORKDIR /opt/infrawatch

# Copy scripts
COPY scripts/monitor.sh scripts/
COPY scripts/metrics_server.py scripts/

RUN chmod +x scripts/monitor.sh

# Environment variable defaults (override with -e or docker-compose env)
ENV CPU_THRESHOLD=80 \
    MEM_THRESHOLD=85 \
    DISK_THRESHOLD=90 \
    SERVICES="" \
    CHECK_INTERVAL=30 \
    METRICS_PORT=9100 \
    LOG_FILE=/var/log/infrawatch/incidents.log \
    METRICS_FILE=/var/lib/infrawatch/metrics.prom

# Expose Prometheus metrics port
EXPOSE 9100

# Health check — calls our own /health endpoint
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -qO- http://localhost:9100/health || exit 1

# Entrypoint: run both monitor + metrics server
COPY docker-entrypoint.sh .
RUN chmod +x docker-entrypoint.sh

USER infrawatch

ENTRYPOINT ["./docker-entrypoint.sh"]
