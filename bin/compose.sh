#!/usr/bin/env bash
set -Eeuo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

readonly PROJECT_DIR="${AIO_APP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
readonly COMPOSE_FILE="${COMPOSE_FILE:-${PROJECT_DIR}/docker-compose.yml}"

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  exec docker compose --project-directory "${PROJECT_DIR}" -f "${COMPOSE_FILE}" "$@"
fi

if command -v docker-compose >/dev/null 2>&1; then
  exec docker-compose -f "${COMPOSE_FILE}" "$@"
fi

echo "error: docker compose plugin or docker-compose binary is required" >&2
exit 127
