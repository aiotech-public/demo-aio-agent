#!/usr/bin/env bash
set -Eeuo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

readonly APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly COMPOSE_WRAPPER="${APP_DIR}/bin/compose.sh"

usage() {
  cat >&2 <<'EOF'
usage: aioctl.sh up|down|reload
EOF
  exit 2
}

action="${1:-}"

case "${action}" in
  up)
    exec "${COMPOSE_WRAPPER}" --profile main up -d
    ;;
  down)
    exec "${COMPOSE_WRAPPER}" --profile main --profile spare-agent down
    ;;
  reload)
    exec "${COMPOSE_WRAPPER}" --profile main up -d
    ;;
  *)
    usage
    ;;
esac
