#!/usr/bin/env bash
set -Eeuo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

readonly APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

exec "${APP_DIR}/bin/update.sh" "$@"
