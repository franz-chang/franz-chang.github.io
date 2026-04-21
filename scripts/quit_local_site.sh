#!/usr/bin/env bash
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

PORT="${PORT:-6787}"
GRACE_SECONDS="${GRACE_SECONDS:-5}"
DRY_RUN=0
FORCE=0

usage() {
  cat <<'EOF'
Usage: scripts/quit_local_site.sh [options]

Stop the local Jekyll server for this repository.

Options:
  --port <port>         Target listening port (default: 6787)
  --grace <seconds>     Grace period before force-kill check (default: 5)
  --force               Send SIGKILL if the process does not exit in time
  --dry-run             Print matching processes without stopping them
  -h, --help            Show this help message

Environment variables:
  PORT, GRACE_SECONDS
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)
      PORT="${2:?Missing value for --port}"
      shift 2
      ;;
    --grace)
      GRACE_SECONDS="${2:?Missing value for --grace}"
      shift 2
      ;;
    --force)
      FORCE=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      echo
      usage
      exit 1
      ;;
  esac
done

require_cmd() {
  local cmd="$1"
  local hint="${2:-}"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "Error: '$cmd' is required but not found in PATH."
    if [[ -n "$hint" ]]; then
      echo "$hint"
    fi
    exit 1
  fi
}

repo_matches_pid() {
  local pid="$1"
  local cmd cwd
  cmd="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  cwd="$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)"

  [[ "$cmd" == *"jekyll serve"* ]] || return 1
  [[ "$cwd" == "$ROOT_DIR" ]] || return 1
  return 0
}

docker_site_matches_port() {
  local service_id mapped_port

  command -v docker >/dev/null 2>&1 || return 1
  docker compose version >/dev/null 2>&1 || return 1

  service_id="$(docker compose ps -q jekyll-site 2>/dev/null | head -n 1)"
  [[ -n "$service_id" ]] || return 1

  mapped_port="$(docker compose port jekyll-site 4000 2>/dev/null || true)"
  [[ -n "$mapped_port" ]] || return 1
  [[ "$mapped_port" == *":$PORT" ]] || return 1
  return 0
}

collect_pids() {
  local pids=()
  local pid pid_list

  if command -v lsof >/dev/null 2>&1; then
    pid_list="$(lsof -t -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | sort -u || true)"
    if [[ -n "$pid_list" ]]; then
      while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        if repo_matches_pid "$pid"; then
          pids+=("$pid")
        fi
      done <<EOF
$pid_list
EOF
    fi
  elif command -v pgrep >/dev/null 2>&1; then
    pid_list="$(pgrep -f "jekyll serve" 2>/dev/null | sort -u || true)"
    if [[ -n "$pid_list" ]]; then
      while IFS= read -r pid; do
        [[ -n "$pid" ]] || continue
        if repo_matches_pid "$pid"; then
          pids+=("$pid")
        fi
      done <<EOF
$pid_list
EOF
    fi
  fi

  printf '%s\n' "${pids[@]:-}"
}

require_cmd ps
if ! command -v lsof >/dev/null 2>&1 && ! command -v pgrep >/dev/null 2>&1; then
  echo "Error: either 'lsof' or 'pgrep' is required to locate local Jekyll processes."
  exit 1
fi

PIDS=()
PID_LIST="$(collect_pids | sed '/^$/d')"
if [[ -n "$PID_LIST" ]]; then
  while IFS= read -r pid; do
    [[ -n "$pid" ]] || continue
    PIDS+=("$pid")
  done <<EOF
$PID_LIST
EOF
fi

DOCKER_MATCH=0
if docker_site_matches_port; then
  DOCKER_MATCH=1
fi

if [[ "${#PIDS[@]}" -eq 0 && "$DOCKER_MATCH" -eq 0 ]]; then
  echo "No matching local site process found for this repository on port $PORT."
  exit 0
fi

echo "Repository : $ROOT_DIR"
echo "Port       : $PORT"
if [[ "${#PIDS[@]}" -gt 0 ]]; then
  echo "Matched PID(s): ${PIDS[*]}"
  for pid in "${PIDS[@]}"; do
    ps -p "$pid" -o pid,ppid,user,etime,command
  done
else
  echo "Matched PID(s): none"
fi

if [[ "$DOCKER_MATCH" -eq 1 ]]; then
  echo "Docker     : jekyll-site is publishing host port $PORT"
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  exit 0
fi

echo
echo "Stopping local site..."
if [[ "${#PIDS[@]}" -gt 0 ]]; then
  kill "${PIDS[@]}"
fi

if [[ "$DOCKER_MATCH" -eq 1 ]]; then
  docker compose down
fi

deadline=$((SECONDS + GRACE_SECONDS))
remaining=("${PIDS[@]}")
while [[ "${#remaining[@]}" -gt 0 && "$SECONDS" -lt "$deadline" ]]; do
  sleep 1
  next_remaining=()
  for pid in "${remaining[@]}"; do
    if kill -0 "$pid" >/dev/null 2>&1; then
      next_remaining+=("$pid")
    fi
  done
  remaining=()
  if [[ "${#next_remaining[@]}" -gt 0 ]]; then
    remaining=("${next_remaining[@]}")
  fi
done

if [[ "${#remaining[@]}" -eq 0 ]]; then
  echo "Stopped successfully."
  exit 0
fi

if [[ "$FORCE" -eq 1 ]]; then
  echo "Process still running after ${GRACE_SECONDS}s. Sending SIGKILL to: ${remaining[*]}"
  kill -9 "${remaining[@]}"
  echo "Force-stopped."
  exit 0
fi

echo "Some process(es) are still running after ${GRACE_SECONDS}s: ${remaining[*]}"
echo "Run again with --force if you want to terminate them with SIGKILL."
exit 1
