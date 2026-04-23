#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

REMOTE_HOST="${CMUX_VM_HOST:-cmux-vm}"
REMOTE_REPO_DIR="${CMUX_VM_REPO_DIR:-/Users/cmux/GhosttyTabs}"
REMOTE_CACHE_TAR_DIR='~/.cache/cmux'

usage() {
  cat <<'EOF'
Usage:
  ./scripts/sync-cmux-vm.sh
  ./scripts/sync-cmux-vm.sh --run v1
  ./scripts/sync-cmux-vm.sh --run v2

Sync the localhost-style cmux-vm checkout to the current committed HEAD,
update submodules, rerun setup, and optionally launch one of the VM test suites.

Options:
  --run v1    Run ./scripts/run-tests-v1.sh after sync
  --run v2    Run ./scripts/run-tests-v2.sh after sync
  -h, --help  Show this help

Environment:
  CMUX_VM_HOST      SSH host alias to use (default: cmux-vm)
  CMUX_VM_REPO_DIR  Repo path on the remote host (default: /Users/cmux/GhosttyTabs)
EOF
}

RUN_MODE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run)
      if [[ $# -lt 2 ]]; then
        echo "error: --run requires v1 or v2" >&2
        exit 1
      fi
      RUN_MODE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -n "$RUN_MODE" && "$RUN_MODE" != "v1" && "$RUN_MODE" != "v2" ]]; then
  echo "error: --run must be v1 or v2" >&2
  exit 1
fi

cd "$PROJECT_DIR"

if ! git diff --quiet --ignore-submodules=all HEAD -- || [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
  echo "==> Warning: local worktree has uncommitted changes; syncing committed HEAD only" >&2
fi

HEAD_SHA="$(git rev-parse HEAD)"
BRANCH_NAME="$(git branch --show-current || true)"
SOURCE_REPO="$PROJECT_DIR"

echo "==> Syncing $REMOTE_HOST:$REMOTE_REPO_DIR to $HEAD_SHA${BRANCH_NAME:+ ($BRANCH_NAME)}"

ssh "$REMOTE_HOST" "mkdir -p '$REMOTE_REPO_DIR'"

# Seed the remote GhosttyKit cache from the host so setup.sh can reuse it.
if [[ -d "$HOME/.cache/cmux/ghosttykit" ]]; then
  echo "==> Syncing GhosttyKit cache to $REMOTE_HOST"
  tar -C "$HOME/.cache/cmux" -cf - ghosttykit \
    | ssh "$REMOTE_HOST" "mkdir -p $REMOTE_CACHE_TAR_DIR && tar -C $REMOTE_CACHE_TAR_DIR -xf -"
fi

ssh "$REMOTE_HOST" "
  set -euo pipefail

  if [[ ! -d '$REMOTE_REPO_DIR/.git' ]]; then
    git clone --recursive '$SOURCE_REPO' '$REMOTE_REPO_DIR'
  fi

  cd '$REMOTE_REPO_DIR'

  if ! git remote get-url local-host-source >/dev/null 2>&1; then
    git remote add local-host-source '$SOURCE_REPO'
  else
    git remote set-url local-host-source '$SOURCE_REPO'
  fi

  git fetch --no-tags local-host-source '$HEAD_SHA'
  git checkout --detach FETCH_HEAD
  git submodule sync --recursive
  git submodule update --init --recursive
  ./scripts/setup.sh
"

case "$RUN_MODE" in
  v1)
    echo "==> Running v1 suite on $REMOTE_HOST"
    ssh "$REMOTE_HOST" "cd '$REMOTE_REPO_DIR' && ./scripts/run-tests-v1.sh"
    ;;
  v2)
    echo "==> Running v2 suite on $REMOTE_HOST"
    ssh "$REMOTE_HOST" "cd '$REMOTE_REPO_DIR' && ./scripts/run-tests-v2.sh"
    ;;
  *)
    echo "==> Sync complete"
    ;;
esac
