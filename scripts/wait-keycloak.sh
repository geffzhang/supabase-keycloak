#!/usr/bin/env bash
# 等待 Keycloak 就绪。Keycloak 26 镜像没有 curl，所以从宿主机探。
# 用法: ./wait-keycloak.sh [url] [timeout_seconds]
set -euo pipefail

URL="${1:-http://127.0.0.1:8080/health/ready}"
TIMEOUT="${2:-180}"
DEADLINE=$(( $(date +%s) + TIMEOUT ))

echo "waiting for ${URL} (timeout ${TIMEOUT}s)"

while :; do
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$URL" || true)
  if [ "$code" = "200" ]; then
    echo "keycloak is ready"
    exit 0
  fi
  if [ "$(date +%s)" -ge "$DEADLINE" ]; then
    echo "TIMEOUT after ${TIMEOUT}s, last status=${code:-none}" >&2
    echo "查看日志: docker logs keycloak --tail 80" >&2
    exit 1
  fi
  sleep 2
done
