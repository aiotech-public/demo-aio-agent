#!/usr/bin/env bash
set -Eeuo pipefail

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly APP_DIR="$(cd "${SCRIPT_DIR}/.." && pwd -P)"
readonly COMPOSE_WRAPPER="${APP_DIR}/bin/compose.sh"

readonly LOCK_FILE="${LOCK_FILE:-/var/run/aio-update.lock}"
readonly LOG_FILE="${LOG_FILE:-/var/log/aio-update.log}"
readonly STATE_DIR="${STATE_DIR:-/var/lib/aio-agent}"
readonly LAST_SUCCESS_FILE="${STATE_DIR}/last-successful-update.env"
readonly SELF_HEAL_MARKER="${STATE_DIR}/last-self-heal.epoch"
readonly PREFETCH_BACKOFF_FILE="${STATE_DIR}/image-prefetch-backoff.env"
readonly SERVICE_NAME="${SERVICE_NAME:-aio.service}"

readonly MAIN_CONTAINER="${MAIN_CONTAINER:-aio-agent}"
readonly SPARE_CONTAINER="${SPARE_CONTAINER:-aio-agent-spare}"
readonly PROXY_CONTAINER="${PROXY_CONTAINER:-proxy-nginx}"
readonly PING_URL="${PING_URL:-http://127.0.0.1/ping}"

readonly STREAM_DIR="${APP_DIR}/volumes/nginx/stream.d"
readonly MAIN_STREAM_ACTIVE="${STREAM_DIR}/regular.conf"
readonly MAIN_STREAM_INACTIVE="${STREAM_DIR}/regular"
readonly SPARE_STREAM_ACTIVE="${STREAM_DIR}/spare.conf"
readonly SPARE_STREAM_INACTIVE="${STREAM_DIR}/spare"

readonly CURL_TIMEOUT_SECONDS="${CURL_TIMEOUT_SECONDS:-10}"
readonly CURL_CONNECT_TIMEOUT_SECONDS="${CURL_CONNECT_TIMEOUT_SECONDS:-2}"
readonly CURL_MAX_TIME_SECONDS="${CURL_MAX_TIME_SECONDS:-5}"
readonly COMPOSE_TIMEOUT_SECONDS="${COMPOSE_TIMEOUT_SECONDS:-300}"
readonly DOCKER_TIMEOUT_SECONDS="${DOCKER_TIMEOUT_SECONDS:-60}"
readonly GIT_TIMEOUT_SECONDS="${GIT_TIMEOUT_SECONDS:-60}"
readonly HEALTH_TIMEOUT_SECONDS="${HEALTH_TIMEOUT_SECONDS:-180}"
readonly SELF_HEAL_COOLDOWN_SECONDS="${SELF_HEAL_COOLDOWN_SECONDS:-900}"
readonly IMAGE_PULL_BACKOFF_SECONDS="${IMAGE_PULL_BACKOFF_SECONDS:-3600}"
readonly IMAGE_PULL_TIMEOUT_SECONDS="${IMAGE_PULL_TIMEOUT_SECONDS:-90}"
readonly MAX_FORWARD_UPDATE_SECONDS="${MAX_FORWARD_UPDATE_SECONDS:-120}"
readonly MIN_LIVE_ROLLOUT_SECONDS="${MIN_LIVE_ROLLOUT_SECONDS:-60}"

readonly ALLOW_DIRTY_WORKTREE="${ALLOW_DIRTY_WORKTREE:-0}"
readonly DRY_RUN="${DRY_RUN:-0}"
readonly PREFETCH_SKIPPED_EXIT_CODE=20

CURRENT_BRANCH=""
CURRENT_COMMIT=""
TARGET_COMMIT=""
ACTIVE_TARGET=""
SPARE_STARTED=0
UPDATE_APPLIED=0
ROLLBACK_ATTEMPTED=0
UPDATE_SUCCEEDED=0
TEMP_WORKTREE=""
ROLLBACK_MODE=0
readonly UPDATE_STARTED_AT_EPOCH="$(date +%s)"
readonly FORWARD_DEADLINE_EPOCH="$((UPDATE_STARTED_AT_EPOCH + MAX_FORWARD_UPDATE_SECONDS))"

mkdir -p "$(dirname "${LOCK_FILE}")" "$(dirname "${LOG_FILE}")" "${STATE_DIR}"
exec >>"${LOG_FILE}" 2>&1

log() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

seconds_remaining() {
  local now remaining

  now="$(date +%s)"
  remaining="$((FORWARD_DEADLINE_EPOCH - now))"
  if (( remaining < 0 )); then
    remaining=0
  fi

  printf '%s\n' "${remaining}"
}

effective_timeout() {
  local requested="$1"
  local remaining

  if (( ROLLBACK_MODE )); then
    printf '%s\n' "${requested}"
    return 0
  fi

  remaining="$(seconds_remaining)"
  if (( remaining <= 0 )); then
    log "ERROR forward update time budget exhausted max_forward_update_seconds=${MAX_FORWARD_UPDATE_SECONDS}"
    return 124
  fi

  if (( requested > remaining )); then
    printf '%s\n' "${remaining}"
    return 0
  fi

  printf '%s\n' "${requested}"
}

require_remaining_budget() {
  local minimum_seconds="$1"
  local stage="$2"
  local remaining

  remaining="$(seconds_remaining)"
  if (( remaining < minimum_seconds )); then
    log "ERROR not enough forward update budget for ${stage}: remaining=${remaining}s required=${minimum_seconds}s"
    return 1
  fi
}

run_with_timeout() {
  local seconds="$1"
  shift
  seconds="$(effective_timeout "${seconds}")"

  if command -v timeout >/dev/null 2>&1; then
    timeout --foreground "${seconds}" "$@"
  else
    "$@"
  fi
}

run_action() {
  local timeout_seconds="$1"
  shift

  log "RUN $*"
  if [[ "${DRY_RUN}" == "1" ]]; then
    return 0
  fi

  run_with_timeout "${timeout_seconds}" "$@"
}

git_read() {
  run_with_timeout "${GIT_TIMEOUT_SECONDS}" git -C "${APP_DIR}" "$@"
}

git_mutate() {
  run_action "${GIT_TIMEOUT_SECONDS}" git -C "${APP_DIR}" "$@"
}

compose_action() {
  run_action "${COMPOSE_TIMEOUT_SECONDS}" "${COMPOSE_WRAPPER}" "$@"
}

docker_action() {
  run_action "${DOCKER_TIMEOUT_SECONDS}" docker "$@"
}

compose_up_main() {
  compose_action --profile main up -d "$@"
}

compose_up_spare() {
  compose_action --profile spare-agent up -d "${SPARE_CONTAINER}"
}

remove_spare() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    SPARE_STARTED=0
    return 0
  fi

  if ! run_with_timeout "${DOCKER_TIMEOUT_SECONDS}" docker inspect "${SPARE_CONTAINER}" >/dev/null 2>&1; then
    SPARE_STARTED=0
    return 0
  fi

  compose_action --profile spare-agent rm -sf "${SPARE_CONTAINER}"
  SPARE_STARTED=0
}

systemctl_action() {
  run_action "${DOCKER_TIMEOUT_SECONDS}" systemctl "$@"
}

check_ping() {
  run_with_timeout "${CURL_TIMEOUT_SECONDS}" \
    curl -fsS \
    --connect-timeout "${CURL_CONNECT_TIMEOUT_SECONDS}" \
    --max-time "${CURL_MAX_TIME_SECONDS}" \
    "${PING_URL}" >/dev/null
}

wait_ping() {
  local timeout_seconds="$1"
  timeout_seconds="$(effective_timeout "${timeout_seconds}")"
  local deadline=$((SECONDS + timeout_seconds))

  while (( SECONDS < deadline )); do
    if check_ping; then
      return 0
    fi
    sleep 2
  done

  return 1
}

container_health() {
  local container="$1"
  run_with_timeout "${DOCKER_TIMEOUT_SECONDS}" \
    docker inspect \
    --format '{{if .State.Running}}{{if .State.Health}}{{.State.Health.Status}}{{else}}running{{end}}{{else}}stopped{{end}}' \
    "${container}" 2>/dev/null || true
}

container_available() {
  local status
  status="$(container_health "$1")"
  [[ "${status}" == "healthy" || "${status}" == "running" ]]
}

wait_container_healthy() {
  local container="$1"
  local timeout_seconds="$2"
  timeout_seconds="$(effective_timeout "${timeout_seconds}")"
  local deadline=$((SECONDS + timeout_seconds))
  local status=""

  while (( SECONDS < deadline )); do
    status="$(container_health "${container}")"
    case "${status}" in
      healthy)
        return 0
        ;;
      running)
        log "WARN container=${container} has no Docker healthcheck, treating running as ready"
        return 0
        ;;
      unhealthy|starting|stopped|"")
        ;;
      *)
        log "WARN container=${container} unexpected health status=${status}"
        ;;
    esac
    sleep 2
  done

  log "ERROR container=${container} did not become healthy status=${status:-unknown}"
  return 1
}

activate_main_offline() {
  if [[ "${ACTIVE_TARGET}" == "main" ]]; then
    return 0
  fi

  log "WARN restoring main stream config offline before proxy recovery"

  if [[ "${DRY_RUN}" == "1" ]]; then
    ACTIVE_TARGET="main"
    return 0
  fi

  if [[ -f "${SPARE_STREAM_ACTIVE}" ]]; then
    mv "${SPARE_STREAM_ACTIVE}" "${SPARE_STREAM_INACTIVE}"
  fi

  if [[ -f "${MAIN_STREAM_INACTIVE}" ]]; then
    mv "${MAIN_STREAM_INACTIVE}" "${MAIN_STREAM_ACTIVE}"
  fi

  ACTIVE_TARGET="main"
}

detect_active_target() {
  if [[ -f "${MAIN_STREAM_ACTIVE}" && ! -f "${SPARE_STREAM_ACTIVE}" ]]; then
    printf 'main\n'
    return 0
  fi

  if [[ -f "${SPARE_STREAM_ACTIVE}" && ! -f "${MAIN_STREAM_ACTIVE}" ]]; then
    printf 'spare\n'
    return 0
  fi

  log "ERROR nginx stream config is in an ambiguous state"
  return 1
}

validate_proxy_config() {
  run_with_timeout "${DOCKER_TIMEOUT_SECONDS}" docker exec "${PROXY_CONTAINER}" nginx -t >/dev/null
}

reload_proxy() {
  docker_action exec "${PROXY_CONTAINER}" nginx -s reload >/dev/null
}

switch_to_spare() {
  local main_tmp="${STREAM_DIR}/regular.next"

  if [[ "${ACTIVE_TARGET}" == "spare" ]]; then
    return 0
  fi

  log "INFO switching proxy target to spare"

  if [[ "${DRY_RUN}" == "1" ]]; then
    ACTIVE_TARGET="spare"
    return 0
  fi

  mv "${MAIN_STREAM_ACTIVE}" "${main_tmp}"
  if ! mv "${SPARE_STREAM_INACTIVE}" "${SPARE_STREAM_ACTIVE}"; then
    mv "${main_tmp}" "${MAIN_STREAM_ACTIVE}"
    return 1
  fi

  if ! validate_proxy_config || ! reload_proxy; then
    mv "${SPARE_STREAM_ACTIVE}" "${SPARE_STREAM_INACTIVE}"
    mv "${main_tmp}" "${MAIN_STREAM_ACTIVE}"
    validate_proxy_config >/dev/null 2>&1 || true
    docker exec "${PROXY_CONTAINER}" nginx -s reload >/dev/null 2>&1 || true
    return 1
  fi

  mv "${main_tmp}" "${MAIN_STREAM_INACTIVE}"
  ACTIVE_TARGET="spare"
}

switch_to_main() {
  local spare_tmp="${STREAM_DIR}/spare.next"

  if [[ "${ACTIVE_TARGET}" == "main" ]]; then
    return 0
  fi

  log "INFO switching proxy target back to main"

  if [[ "${DRY_RUN}" == "1" ]]; then
    ACTIVE_TARGET="main"
    return 0
  fi

  mv "${SPARE_STREAM_ACTIVE}" "${spare_tmp}"
  if ! mv "${MAIN_STREAM_INACTIVE}" "${MAIN_STREAM_ACTIVE}"; then
    mv "${spare_tmp}" "${SPARE_STREAM_ACTIVE}"
    return 1
  fi

  if ! validate_proxy_config || ! reload_proxy; then
    mv "${MAIN_STREAM_ACTIVE}" "${MAIN_STREAM_INACTIVE}"
    mv "${spare_tmp}" "${SPARE_STREAM_ACTIVE}"
    validate_proxy_config >/dev/null 2>&1 || true
    docker exec "${PROXY_CONTAINER}" nginx -s reload >/dev/null 2>&1 || true
    return 1
  fi

  mv "${spare_tmp}" "${SPARE_STREAM_INACTIVE}"
  ACTIVE_TARGET="main"
}

record_success() {
  local timestamp
  timestamp="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

  cat >"${LAST_SUCCESS_FILE}" <<EOF
timestamp=${timestamp}
branch=${CURRENT_BRANCH}
commit=${TARGET_COMMIT}
result=success
active_target=${ACTIVE_TARGET}
EOF

  rm -f "${PREFETCH_BACKOFF_FILE}"
}

dirty_worktree() {
  [[ -n "$(git_read status --porcelain --untracked-files=normal)" ]]
}

is_self_heal_allowed() {
  local now last=0
  now="$(date +%s)"

  if [[ -f "${SELF_HEAL_MARKER}" ]]; then
    last="$(<"${SELF_HEAL_MARKER}")"
  fi

  (( now - last >= SELF_HEAL_COOLDOWN_SECONDS ))
}

perform_self_heal() {
  local now
  now="$(date +%s)"

  if ! is_self_heal_allowed; then
    log "WARN ping failed but self-heal cooldown is active"
    return 1
  fi

  log "WARN ping failed, running state-aware self-heal"
  printf '%s\n' "${now}" >"${SELF_HEAL_MARKER}"

  if [[ "${ACTIVE_TARGET}" == "spare" ]]; then
    if container_available "${SPARE_CONTAINER}"; then
      log "INFO active target is spare and spare container is available; bringing proxy/main side up without stopping spare"
      compose_up_spare
      compose_up_main "${MAIN_CONTAINER}" "${PROXY_CONTAINER}"
    else
      log "WARN active target is spare but spare container is unavailable; restoring main path first"
      compose_up_main "${MAIN_CONTAINER}"
      wait_container_healthy "${MAIN_CONTAINER}" "${HEALTH_TIMEOUT_SECONDS}"
      activate_main_offline
      compose_up_main "${MAIN_CONTAINER}" "${PROXY_CONTAINER}"
    fi
  else
    compose_up_main
  fi

  if ! wait_ping "${HEALTH_TIMEOUT_SECONDS}"; then
    log "ERROR self-heal did not restore service health"
    return 1
  fi

  log "INFO self-heal restored service health"
}

reconcile_broken_active_target() {
  if [[ "${ACTIVE_TARGET}" != "spare" ]]; then
    return 0
  fi

  if container_available "${SPARE_CONTAINER}"; then
    return 0
  fi

  log "WARN spare config is active but spare container is unavailable; restoring a safe main target before health checks"
  compose_up_main "${MAIN_CONTAINER}"
  wait_container_healthy "${MAIN_CONTAINER}" "${HEALTH_TIMEOUT_SECONDS}"
  activate_main_offline
  compose_up_main "${MAIN_CONTAINER}" "${PROXY_CONTAINER}"
  if ! wait_ping "${HEALTH_TIMEOUT_SECONDS}"; then
    log "ERROR main target did not become reachable after broken-spare recovery"
    return 1
  fi
}

recover_from_spare_if_needed() {
  if [[ "${ACTIVE_TARGET}" != "spare" ]]; then
    return 0
  fi

  log "WARN proxy is already pointing to spare, attempting recovery to steady-state main"
  compose_up_main "${MAIN_CONTAINER}"
  wait_container_healthy "${MAIN_CONTAINER}" "${HEALTH_TIMEOUT_SECONDS}"
  switch_to_main
  if ! wait_ping "${HEALTH_TIMEOUT_SECONDS}"; then
    log "ERROR main target did not become reachable after recovery switch"
    return 1
  fi
  remove_spare
}

prepare_target_worktree() {
  local worktree_dir

  if [[ -n "${TEMP_WORKTREE}" ]]; then
    return 0
  fi

  worktree_dir="$(mktemp -d "${TMPDIR:-/tmp}/aio-update.XXXXXX")"
  TEMP_WORKTREE="${worktree_dir}"

  log "INFO preparing target commit in temporary worktree ${worktree_dir}"
  run_with_timeout "${GIT_TIMEOUT_SECONDS}" git -C "${APP_DIR}" worktree add --detach "${worktree_dir}" "${TARGET_COMMIT}" >/dev/null

  if [[ -f "${APP_DIR}/.aio-env" ]]; then
    ln -s "${APP_DIR}/.aio-env" "${worktree_dir}/.aio-env"
  fi

  if [[ -d "${APP_DIR}/secrets" ]]; then
    rm -rf "${worktree_dir}/secrets"
    ln -s "${APP_DIR}/secrets" "${worktree_dir}/secrets"
  fi
}

target_worktree_compose() {
  AIO_APP_DIR="${TEMP_WORKTREE}" \
    COMPOSE_FILE="${TEMP_WORKTREE}/docker-compose.yml" \
    run_with_timeout "${COMPOSE_TIMEOUT_SECONDS}" "${TEMP_WORKTREE}/bin/compose.sh" "$@"
}

target_worktree_image_refs() {
  target_worktree_compose --profile main --profile spare-agent config \
    | awk '/^[[:space:]]+image: / {print $2}' \
    | sort -u
}

prefetch_backoff_until_epoch() {
  local until_epoch="0"

  if [[ -f "${PREFETCH_BACKOFF_FILE}" ]]; then
    until_epoch="$(awk -F= '/^until_epoch=/{print $2}' "${PREFETCH_BACKOFF_FILE}" | tail -n 1)"
  fi

  printf '%s\n' "${until_epoch:-0}"
}

prefetch_backoff_active() {
  local now until_epoch
  now="$(date +%s)"
  until_epoch="$(prefetch_backoff_until_epoch)"

  if (( until_epoch > now )); then
    log "WARN image prefetch backoff active until_epoch=${until_epoch}; skipping update"
    return 0
  fi

  rm -f "${PREFETCH_BACKOFF_FILE}"
  return 1
}

set_prefetch_backoff() {
  local reason="$1"
  local now until_epoch

  now="$(date +%s)"
  until_epoch="$((now + IMAGE_PULL_BACKOFF_SECONDS))"

  cat >"${PREFETCH_BACKOFF_FILE}" <<EOF
created_epoch=${now}
until_epoch=${until_epoch}
reason=${reason}
target_commit=${TARGET_COMMIT}
EOF
}

validate_target_compose_config() {
  log "INFO validating target compose config in temporary worktree ${TEMP_WORKTREE}"

  target_worktree_compose --profile main --profile spare-agent config -q
}

prefetch_target_images() {
  local image pull_log pull_status=0
  local -a images=()

  if prefetch_backoff_active; then
    return "${PREFETCH_SKIPPED_EXIT_CODE}"
  fi

  log "INFO prefetching target images before live promote"

  if [[ "${DRY_RUN}" == "1" ]]; then
    log "INFO dry-run mode, skipping target image prefetch"
    return 0
  fi

  mapfile -t images < <(target_worktree_image_refs)
  if (( ${#images[@]} == 0 )); then
    log "ERROR no image references found in target compose config"
    return 1
  fi

  for image in "${images[@]}"; do
    if run_with_timeout "${DOCKER_TIMEOUT_SECONDS}" docker image inspect "${image}" >/dev/null 2>&1; then
      log "INFO image already cached image=${image}"
      continue
    fi

    log "INFO pulling missing image=${image}"
    pull_log="$(mktemp "${TMPDIR:-/tmp}/aio-update-pull.XXXXXX")"
    if ! run_with_timeout "${IMAGE_PULL_TIMEOUT_SECONDS}" docker pull "${image}" >"${pull_log}" 2>&1; then
      pull_status=$?
      cat "${pull_log}"
      if grep -qiE '429|too many requests|pull rate limit|rate limit exceeded' "${pull_log}"; then
        set_prefetch_backoff "registry-rate-limit"
        log "WARN target image prefetch hit registry rate limit; leaving live checkout on commit=${CURRENT_COMMIT}"
        rm -f "${pull_log}"
        return "${PREFETCH_SKIPPED_EXIT_CODE}"
      fi

      log "ERROR target image prefetch failed before live promote image=${image} exit_code=${pull_status}"
      rm -f "${pull_log}"
      return "${pull_status}"
    fi

    cat "${pull_log}"
    rm -f "${pull_log}"
  done

  rm -f "${PREFETCH_BACKOFF_FILE}"
  log "INFO target images are present locally for commit=${TARGET_COMMIT}"
  return 0
}

rollback() {
  local reason="$1"

  if (( ROLLBACK_ATTEMPTED )); then
    return 0
  fi
  ROLLBACK_ATTEMPTED=1

  log "ERROR rollback requested reason=${reason}"
  set +e
  ROLLBACK_MODE=1

  if [[ "${ACTIVE_TARGET}" == "spare" ]]; then
    if wait_container_healthy "${MAIN_CONTAINER}" 15; then
      if switch_to_main && wait_ping "${HEALTH_TIMEOUT_SECONDS}"; then
        log "WARN rollback returned traffic to main"
        ACTIVE_TARGET="main"
      else
        log "ERROR rollback could not return traffic to main; leaving spare active"
      fi
    else
      log "ERROR main is not healthy, leaving spare active to preserve service availability"
    fi
  fi

  if (( SPARE_STARTED )) && [[ "${ACTIVE_TARGET}" == "main" ]]; then
    remove_spare || true
  fi

  if (( UPDATE_APPLIED )); then
    log "ERROR repository is already at target commit ${TARGET_COMMIT}; automatic git rollback is not attempted"
  fi

  set -e
}

cleanup() {
  local exit_code=$?

  set +e

  if [[ -n "${TEMP_WORKTREE}" ]]; then
    git -C "${APP_DIR}" worktree remove --force "${TEMP_WORKTREE}" >/dev/null 2>&1 || rm -rf "${TEMP_WORKTREE}"
  fi

  if (( exit_code != 0 )) && (( UPDATE_SUCCEEDED == 0 )); then
    rollback "exit_code=${exit_code}"
  fi

  log "INFO finished exit_code=${exit_code} branch=${CURRENT_BRANCH:-unknown} current_commit=${CURRENT_COMMIT:-unknown} target_commit=${TARGET_COMMIT:-unknown} active_target=${ACTIVE_TARGET:-unknown}"
}

handle_error() {
  local line="$1"
  local command="$2"
  local exit_code="$3"

  log "ERROR line=${line} exit_code=${exit_code} command=${command}"
  exit "${exit_code}"
}

trap 'handle_error "${LINENO}" "${BASH_COMMAND}" "$?"' ERR
trap cleanup EXIT

exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
  log "INFO update skipped because another run already holds ${LOCK_FILE}"
  exit 0
fi

cd "${APP_DIR}"

if [[ "$(git -C "${APP_DIR}" rev-parse --is-inside-work-tree 2>/dev/null || true)" != "true" ]]; then
  log "ERROR ${APP_DIR} is not a git worktree"
  exit 1
fi

ACTIVE_TARGET="$(detect_active_target)"

log "INFO update budget max_forward_update_seconds=${MAX_FORWARD_UPDATE_SECONDS} active_target=${ACTIVE_TARGET}"

reconcile_broken_active_target

if ! check_ping; then
  perform_self_heal
fi

recover_from_spare_if_needed

if dirty_worktree && [[ "${ALLOW_DIRTY_WORKTREE}" != "1" ]]; then
  log "WARN dirty worktree detected, skipping update; set ALLOW_DIRTY_WORKTREE=1 to opt in"
  exit 0
fi

if dirty_worktree; then
  log "WARN dirty worktree detected but ALLOW_DIRTY_WORKTREE=1, continuing carefully"
fi

CURRENT_BRANCH="$(git_read rev-parse --abbrev-ref HEAD)"
CURRENT_COMMIT="$(git_read rev-parse HEAD)"

log "INFO current branch=${CURRENT_BRANCH} commit=${CURRENT_COMMIT}"

run_with_timeout "${GIT_TIMEOUT_SECONDS}" git -C "${APP_DIR}" fetch --prune origin "${CURRENT_BRANCH}"
TARGET_COMMIT="$(git_read rev-parse "origin/${CURRENT_BRANCH}")"

log "INFO target branch=origin/${CURRENT_BRANCH} commit=${TARGET_COMMIT}"

if [[ "${CURRENT_COMMIT}" == "${TARGET_COMMIT}" ]]; then
  log "INFO no updates detected"
  UPDATE_SUCCEEDED=1
  exit 0
fi

if [[ "$(git_read merge-base HEAD "origin/${CURRENT_BRANCH}")" != "${CURRENT_COMMIT}" ]]; then
  log "ERROR local branch diverged from origin/${CURRENT_BRANCH}; refusing non-fast-forward update"
  exit 1
fi

if prefetch_backoff_active; then
  UPDATE_SUCCEEDED=1
  exit 0
fi

prepare_target_worktree
validate_target_compose_config
if prefetch_target_images; then
  :
else
  prefetch_status=$?
  if (( prefetch_status == PREFETCH_SKIPPED_EXIT_CODE )); then
    UPDATE_SUCCEEDED=1
    exit 0
  fi
  exit "${prefetch_status}"
fi

if [[ "${DRY_RUN}" == "1" ]]; then
  log "INFO dry-run preflight succeeded current_commit=${CURRENT_COMMIT} target_commit=${TARGET_COMMIT}"
  UPDATE_SUCCEEDED=1
  exit 0
fi

require_remaining_budget "${MIN_LIVE_ROLLOUT_SECONDS}" "live rollout"

git_mutate pull --ff-only origin "${CURRENT_BRANCH}"
UPDATE_APPLIED=1

run_with_timeout "${COMPOSE_TIMEOUT_SECONDS}" "${COMPOSE_WRAPPER}" --profile main --profile spare-agent config -q

compose_up_spare
SPARE_STARTED=1
wait_container_healthy "${SPARE_CONTAINER}" "${HEALTH_TIMEOUT_SECONDS}"

switch_to_spare
if ! wait_ping "${HEALTH_TIMEOUT_SECONDS}"; then
  rollback "spare target did not become reachable after switch"
  exit 1
fi

compose_up_main
wait_container_healthy "${MAIN_CONTAINER}" "${HEALTH_TIMEOUT_SECONDS}"

switch_to_main
if ! wait_ping "${HEALTH_TIMEOUT_SECONDS}"; then
  rollback "main target did not become reachable after update"
  exit 1
fi

remove_spare

record_success
UPDATE_SUCCEEDED=1

log "SUCCESS rollout completed current_commit=${CURRENT_COMMIT} target_commit=${TARGET_COMMIT}"
