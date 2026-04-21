#!/usr/bin/env bash
set -euo pipefail

EXPECTED_LABELS='[self-hosted, macOS, ARM64, cmux-macos-26-arm64]'
EXPECTED_ZIG_VERSION='0.15.2'

AUTO_FIX=false
VERBOSE=false

failures=0
warnings=0
fixes_applied=0
declare -a remediation_hints=()

usage() {
  cat <<'EOF'
Usage: ./scripts/check-runner-readiness.sh [--fix] [--verbose]

Checks whether the current Mac is ready to act as the cmux self-hosted GitHub
Actions runner.

Options:
  --fix       Attempt safe local remediations for missing tools.
  --verbose   Print extra diagnostic detail.
  -h, --help  Show this help.

Notes:
  - --fix is intentionally conservative. It only installs or prepares local
    dependencies that can be fixed safely on this machine.
  - GitHub runner registration, label assignment, and sudo policy changes are
    still manual steps.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --fix)
      AUTO_FIX=true
      shift
      ;;
    --verbose)
      VERBOSE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

pass() {
  printf 'PASS: %s\n' "$1"
}

warn() {
  printf 'WARN: %s\n' "$1"
  warnings=$((warnings + 1))
}

fail() {
  printf 'FAIL: %s\n' "$1"
  failures=$((failures + 1))
}

add_hint() {
  local hint="$1"
  local existing
  for existing in "${remediation_hints[@]:-}"; do
    if [ "$existing" = "$hint" ]; then
      return
    fi
  done
  remediation_hints+=("$hint")
}

info() {
  if [ "$VERBOSE" = true ]; then
    printf 'INFO: %s\n' "$1"
  fi
}

record_fix() {
  printf 'FIX: %s\n' "$1"
  fixes_applied=$((fixes_applied + 1))
}

run_fix() {
  local description="$1"
  shift

  if [ "$AUTO_FIX" != true ]; then
    return 1
  fi

  info "running fix: $description"
  if "$@"; then
    record_fix "$description"
    return 0
  fi

  warn "auto-fix failed: $description"
  return 1
}

check_cmd() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    pass "command available: $name -> $(command -v "$name")"
  else
    fail "missing command: $name"
    add_hint "Install $name and ensure it is on PATH before registering this machine as a runner."
  fi
}

check_cmd_version() {
  local name="$1"
  local expected="$2"
  local actual

  if ! command -v "$name" >/dev/null 2>&1; then
    fail "missing command: $name"
    add_hint "Install $name and ensure it is on PATH before registering this machine as a runner."
    return
  fi

  actual="$("$name" version 2>/dev/null | head -1 || true)"
  if printf '%s' "$actual" | grep -q "$expected"; then
    pass "$name version matches expectation: $actual"
  else
    fail "$name version mismatch: expected pattern '$expected', got '${actual:-<none>}'"
    add_hint "Install the expected $name version ($expected) or update the workflows if this fork is intentionally using a different version."
  fi
}

check_fixed_cmd() {
  local name="$1"
  shift

  if command -v "$name" >/dev/null 2>&1; then
    pass "command available: $name -> $(command -v "$name")"
    return
  fi

  if run_fix "install $name" "$@"; then
    hash -r
  fi

  if command -v "$name" >/dev/null 2>&1; then
    pass "command available after fix: $name -> $(command -v "$name")"
  else
    fail "missing command: $name"
    add_hint "Install $name manually or rerun this script with --fix if the dependency is safe to auto-install."
  fi
}

section() {
  printf '\n== %s ==\n' "$1"
}

install_homebrew_formula() {
  local formula="$1"
  brew install "$formula"
}

check_passwordless_sudo() {
  local label output status
  local allowed=0
  local sandbox_blocked=0

  while IFS='|' read -r label cmd; do
    set +e
    output="$(sh -c "$cmd" 2>&1)"
    status=$?
    set -e

    if [ "$status" -eq 0 ]; then
      pass "passwordless sudo allows workflow command: $label"
      allowed=1
      continue
    fi

    if printf '%s' "$output" | grep -qi "operation not permitted"; then
      sandbox_blocked=1
      info "sandbox blocked sudo probe for: $label"
      continue
    fi

    info "sudo probe failed for $label: ${output:-<no output>}"
  done <<'EOF'
mkdir|sudo -n mkdir -p /tmp/cmux-runner-sudo-check
cp|tmp_src="$(mktemp /tmp/cmux-runner-cp-src.XXXXXX)" && tmp_dst="/tmp/cmux-runner-cp-dst.$$" && touch "$tmp_src" && sudo -n cp "$tmp_src" "$tmp_dst" && rm -f "$tmp_src" "$tmp_dst"
sqlite3|sudo -n sqlite3 -version >/dev/null
EOF

  if [ "$allowed" -eq 1 ]; then
    return 0
  fi

  if [ "$sandbox_blocked" -eq 1 ]; then
    warn "sudo command probes are blocked by the current sandbox; verify them in a normal terminal"
    add_hint "Rerun this readiness script directly in Terminal to verify the specific passwordless sudo commands outside the Codex sandbox."
    return 2
  fi

  fail "passwordless sudo does not cover the workflow command set (mkdir/cp/sqlite3)"
  add_hint "Allow passwordless sudo for the specific workflow commands this repo uses: /bin/mkdir, /bin/cp, and /usr/bin/sqlite3."
  return 1
}

check_tcc_write_access() {
  local output
  local status

  if [ -w "$HOME/Library/Application Support/com.apple.TCC" ]; then
    pass "runner can modify the user TCC database path used by UI workflows"
    return 0
  fi

  set +e
  output="$(sudo -n test -w "/Library/Application Support/com.apple.TCC" 2>&1)"
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    pass "runner can modify the system TCC database path used by UI workflows"
    return 0
  fi

  if printf '%s' "$output" | grep -qi "operation not permitted"; then
    warn "TCC write-access check is blocked by the current sandbox; verify it in a normal terminal if UI recording still fails"
    add_hint "If UI recording permission steps fail on the real runner, verify TCC DB write access directly in Terminal outside the Codex sandbox."
    return 2
  fi

  warn "TCC database write access not confirmed; screen-recording grant step may fail"
  add_hint "Ensure the runner user can modify the user or system TCC database paths used by the UI workflows, or adjust the workflows to pre-grant screen-recording access another way."
  return 1
}

section "Runner Labels"
printf 'Expected GitHub runner labels: %s\n' "$EXPECTED_LABELS"

section "Core macOS Build Tools"
check_cmd xcodebuild
check_cmd xcrun
check_cmd clang
check_cmd sqlite3
check_cmd python3
check_cmd node
check_cmd npm
check_cmd brew
check_cmd gh
check_cmd_version zig "$EXPECTED_ZIG_VERSION"
check_fixed_cmd ffmpeg install_homebrew_formula ffmpeg

if command -v xcode-select >/dev/null 2>&1; then
  XCODE_DIR="$(xcode-select -p 2>/dev/null || true)"
  if [ "$XCODE_DIR" = "/Applications/Xcode.app/Contents/Developer" ]; then
    pass "active developer directory is full Xcode: $XCODE_DIR"
  else
    fail "active developer directory is not full Xcode: ${XCODE_DIR:-<unset>}"
    add_hint "Point the active developer directory at full Xcode with: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
  fi
fi

section "Workflow Assumptions"
check_passwordless_sudo

if command -v clang >/dev/null 2>&1; then
  TMP_BIN="$(mktemp /tmp/cmux-runner-vdisplay.XXXXXX)"
  rm -f "$TMP_BIN"
  if clang -framework Foundation -framework CoreGraphics -o "$TMP_BIN" scripts/create-virtual-display.m >/dev/null 2>&1; then
    pass "virtual display helper compiles"
    rm -f "$TMP_BIN"
  else
    fail "virtual display helper failed to compile"
    add_hint "Fix the local Xcode/SDK toolchain until scripts/create-virtual-display.m builds successfully with clang."
  fi
fi

check_tcc_write_access

section "Optional Release/Nightly Tooling"
check_cmd go
check_cmd security
check_cmd codesign
check_cmd spctl

if xcrun notarytool --version >/dev/null 2>&1; then
  pass "xcrun notarytool is available"
else
  warn "xcrun notarytool is not available; release/nightly notarization will fail"
  add_hint "Install or select an Xcode toolchain that includes xcrun notarytool before enabling release or nightly workflows on this runner."
fi

if command -v aws >/dev/null 2>&1; then
  pass "aws cli installed: $(aws --version 2>&1)"
else
  warn "aws cli missing; release/nightly R2 upload steps would install it at runtime"
  add_hint "Optional: preinstall awscli with Homebrew if you want release/nightly jobs to avoid runtime package installation."
fi

if command -v sentry-cli >/dev/null 2>&1; then
  pass "sentry-cli installed: $(sentry-cli --version 2>/dev/null)"
else
  warn "sentry-cli missing; release/nightly dSYM upload step would install it at runtime"
  add_hint "Optional: preinstall sentry-cli if you want release/nightly jobs to avoid runtime package installation."
fi

section "GitHub Runner Registration"
warn "register this machine in GitHub Actions with labels $EXPECTED_LABELS"
warn "keep public-repo workflows on workflow_dispatch unless you fully trust all code that can reach this runner"
add_hint "Register this Mac as a self-hosted GitHub Actions runner and assign the labels $EXPECTED_LABELS."
add_hint "Because this repo is public, keep dangerous workflows on workflow_dispatch unless you fully trust all code that can execute on this runner."

if [ "${#remediation_hints[@]}" -gt 0 ]; then
  section "Remediation Hints"
  for hint in "${remediation_hints[@]}"; do
    printf -- '- %s\n' "$hint"
  done
fi

printf '\nSummary: %d failure(s), %d warning(s), %d fix(es) applied\n' "$failures" "$warnings" "$fixes_applied"
if [ "$failures" -ne 0 ]; then
  exit 1
fi
