#!/usr/bin/env bash
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-6787}"
LIVERELOAD=1
LIVERELOAD_MIN_DELAY="${LIVERELOAD_MIN_DELAY:-10.0}"
LIVERELOAD_MAX_DELAY="${LIVERELOAD_MAX_DELAY:-10.0}"
INCREMENTAL=1
INSTALL_NODE=0
BUILD_JS=0
DRY_RUN=0
MODE="local"
TRACE=0
DEFAULT_LOG_FILE="${TMPDIR:-/tmp}/franz-chang-github-io-jekyll.log"
LOG_FILE="${LOG_FILE:-$DEFAULT_LOG_FILE}"
if [[ "$LOG_FILE" == "$ROOT_DIR" || "$LOG_FILE" == "$ROOT_DIR/"* ]]; then
  echo "[run_local_site] LOG_FILE points inside the repo and would trigger rebuild loops."
  echo "[run_local_site] Redirecting logs to: $DEFAULT_LOG_FILE"
  LOG_FILE="$DEFAULT_LOG_FILE"
fi

for ruby_bin_dir in /opt/homebrew/opt/ruby@3.3/bin /usr/local/opt/ruby@3.3/bin /opt/homebrew/opt/ruby/bin /usr/local/opt/ruby/bin; do
  if [[ -x "$ruby_bin_dir/ruby" && -x "$ruby_bin_dir/bundle" ]]; then
    export PATH="$ruby_bin_dir:$PATH"
    break
  fi
done

usage() {
  cat <<'EOF'
Usage: scripts/run_local_site.sh [options]

Start the local Jekyll server for this site.

Options:
  --host <host>         Bind host (default: 127.0.0.1)
  --port <port>         Bind port (default: 6787)
  --no-livereload       Disable Jekyll live reload
  --reload-min <sec>    Minimum live reload delay (default: 10.0)
  --reload-max <sec>    Maximum live reload delay (default: 10.0)
  --no-incremental      Disable incremental build
  --install-node        Run npm install when node_modules is missing
  --build-js            Build bundled JS assets before serving
  --trace               Enable full Ruby backtraces for debugging
  --docker              Start the site with docker compose instead of local Ruby
  --local               Force local Ruby mode (default)
  --dry-run             Print the final Jekyll command and exit
  -h, --help            Show this help message

Environment variables:
  HOST, PORT, LOG_FILE, LIVERELOAD_MIN_DELAY, LIVERELOAD_MAX_DELAY
EOF
}

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

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host)
      HOST="${2:?Missing value for --host}"
      shift 2
      ;;
    --port)
      PORT="${2:?Missing value for --port}"
      shift 2
      ;;
    --no-livereload)
      LIVERELOAD=0
      shift
      ;;
    --reload-min)
      LIVERELOAD_MIN_DELAY="${2:?Missing value for --reload-min}"
      shift 2
      ;;
    --reload-max)
      LIVERELOAD_MAX_DELAY="${2:?Missing value for --reload-max}"
      shift 2
      ;;
    --no-incremental)
      INCREMENTAL=0
      shift
      ;;
    --install-node)
      INSTALL_NODE=1
      shift
      ;;
    --build-js)
      BUILD_JS=1
      shift
      ;;
    --trace)
      TRACE=1
      shift
      ;;
    --docker)
      MODE="docker"
      shift
      ;;
    --local)
      MODE="local"
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

require_cmd ruby "Install Ruby first. On macOS: brew install ruby"
require_cmd bundle "Install Bundler first. Example: gem install bundler"

RUBY_VERSION_STR="$(ruby -e 'print RUBY_VERSION')"
if ! ruby -e 'exit Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.1.0") ? 0 : 1'; then
  echo "Error: Ruby $RUBY_VERSION_STR is too old for this Jekyll setup."
  echo "Install or use a newer Ruby first. On macOS, Homebrew Ruby usually works:"
  echo "  brew install ruby"
  echo "  export PATH=\"$(brew --prefix ruby)/bin:\$PATH\""
  exit 1
fi

if [[ "$DRY_RUN" -ne 1 ]] && command -v lsof >/dev/null 2>&1; then
  if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "Error: port $PORT is already in use."
    echo "Try another one, for example:"
    echo "  PORT=6788 bash scripts/run_local_site.sh"
    exit 1
  fi
fi

echo "Repository : $ROOT_DIR"
echo "Preview URL: http://$HOST:$PORT"
echo "Log file   : $LOG_FILE"
echo "Ruby       : $(ruby -v)"
if [[ "$LIVERELOAD" -eq 1 ]]; then
  echo "LiveReload : enabled (${LIVERELOAD_MIN_DELAY}s-${LIVERELOAD_MAX_DELAY}s delay)"
else
  echo "LiveReload : disabled"
fi
echo

if [[ "$MODE" == "docker" ]]; then
  CMD=(docker compose up --build)

  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf 'Command    :'
    printf ' %q' "${CMD[@]}"
    printf '\n'
    exit 0
  fi

  require_cmd docker "Install Docker Desktop first if you want to use --docker."
  if ! docker compose version >/dev/null 2>&1; then
    echo "Error: docker compose is required for --docker mode."
    exit 1
  fi

  "${CMD[@]}"
  exit 0
fi

CMD=(bundle exec jekyll serve --host "$HOST" --port "$PORT")

if [[ "$LIVERELOAD" -eq 1 ]]; then
  CMD+=(--livereload --livereload-min-delay "$LIVERELOAD_MIN_DELAY" --livereload-max-delay "$LIVERELOAD_MAX_DELAY")
fi

if [[ "$INCREMENTAL" -eq 1 ]]; then
  CMD+=(--incremental)
fi

if [[ "$TRACE" -eq 1 ]]; then
  CMD+=(--trace)
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf 'Command    :'
  printf ' %q' "${CMD[@]}"
  printf '\n'
  exit 0
fi

if [[ ! -f ".bundle/config" ]]; then
  bundle config set --local path "vendor/bundle" >/dev/null
fi

if ! bundle check >/dev/null 2>&1; then
  echo "[run_local_site] Installing Ruby dependencies with bundler..."
  if ! bundle install; then
    echo
    echo "Local dependency setup failed."
    echo "Recommended next steps:"
    echo "  1. Use Docker mode if Docker is available:"
    echo "     bash scripts/run_local_site.sh --docker"
    echo "  2. Or use a Ruby 3.2 environment, which matches this repo's Dockerfile."
    echo "  3. Avoid the system Ruby 2.6 on macOS for this project."
    exit 1
  fi
fi

if [[ "$INSTALL_NODE" -eq 1 || "$BUILD_JS" -eq 1 ]]; then
  require_cmd node "Install Node.js first. On macOS: brew install node"
  require_cmd npm "Install npm first. It usually comes with Node.js."

  if [[ ! -d "node_modules" ]]; then
    echo "[run_local_site] Installing Node dependencies..."
    npm install
  fi
fi

if [[ "$BUILD_JS" -eq 1 ]]; then
  echo "[run_local_site] Building JS assets..."
  npm run build:js
fi

mkdir -p "$(dirname "$LOG_FILE")"
: > "$LOG_FILE"

{
  printf '[%s] Starting local Jekyll server on http://%s:%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$HOST" "$PORT"
} >> "$LOG_FILE"

"${CMD[@]}" 2>&1 | tee -a "$LOG_FILE"
