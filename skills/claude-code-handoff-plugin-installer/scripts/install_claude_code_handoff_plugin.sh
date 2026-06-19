#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_MARKETPLACE="$SKILL_DIR/references/claude-code-handoff-marketplace"
TARGET_ROOT="$HOME/.agents/claude-code-marketplace"
CONFIG_PATH="${CODEX_CONFIG_PATH:-$HOME/.codex/config.toml}"
DRY_RUN=false
SKIP_MARKETPLACE_ADD=false
SKIP_CONFIG_ENABLE=false
SKIP_SMOKE=false
VERIFY_FAILURES=0
VERIFY_WARNINGS=0

usage() {
  cat <<'USAGE'
Usage:
  install_claude_code_handoff_plugin.sh [options]

Options:
  --target-root <path>       Install marketplace to this directory. Default: ~/.agents/claude-code-marketplace
  --config <path>            Codex config.toml path. Default: ~/.codex/config.toml
  --dry-run                  Print actions without changing files.
  --skip-marketplace-add     Do not run `codex plugin marketplace add`.
  --skip-config-enable       Do not edit config.toml.
  --skip-smoke               Do not run plugin inspect smoke.
  -h, --help                 Show this help.
USAGE
}

log() {
  printf '[claude-installer] %s\n' "$*"
}

verify_pass() {
  printf '[claude-verify] PASS %s\n' "$*"
}

verify_warn() {
  VERIFY_WARNINGS=$((VERIFY_WARNINGS + 1))
  printf '[claude-verify] WARN %s\n' "$*"
}

verify_fail() {
  VERIFY_FAILURES=$((VERIFY_FAILURES + 1))
  printf '[claude-verify] FAIL %s\n' "$*"
}

probe_claude_version() {
  local tmp pid elapsed rc
  tmp="$(mktemp /tmp/claude-installer-version.XXXXXX)"
  claude --version >"$tmp" 2>&1 &
  pid=$!
  elapsed=0
  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$elapsed" -ge 10 ]]; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true
      rm -f "$tmp"
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  wait "$pid" 2>/dev/null
  rc=$?
  head -n 1 "$tmp"
  rm -f "$tmp"
  return "$rc"
}

run() {
  if [[ "$DRY_RUN" == true ]]; then
    printf '[dry-run] '
    printf '%q ' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

verify_file() {
  local path="$1"
  local label="$2"
  if [[ -f "$path" ]]; then
    verify_pass "$label exists: $path"
  else
    verify_fail "$label missing: $path"
  fi
}

verify_config_enabled() {
  if [[ "$SKIP_CONFIG_ENABLE" == true ]]; then
    verify_warn "config enable was skipped"
    return
  fi
  if [[ "$DRY_RUN" == true ]]; then
    verify_warn "config enable was not applied because this is dry-run"
    return
  fi
  if [[ ! -f "$CONFIG_PATH" ]]; then
    verify_fail "config file missing: $CONFIG_PATH"
    return
  fi
  local config_rc
  set +e
  python3 - "$CONFIG_PATH" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
pattern = re.compile(r'(?ms)^\[plugins\."claude-code-handoff@claude-code-local"\]\s*(.*?)(?=^\[|\Z)')
match = pattern.search(text)
if not match:
    sys.exit(1)
if not re.search(r'(?m)^enabled\s*=\s*true\s*$', match.group(0)):
    sys.exit(2)
PY
  config_rc=$?
  set -e
  case "$config_rc" in
    0) verify_pass "plugin enabled in config: $CONFIG_PATH" ;;
    1) verify_fail "config missing [plugins.\"claude-code-handoff@claude-code-local\"]" ;;
    2) verify_fail "config has plugin block but enabled is not true" ;;
    *) verify_fail "could not parse config: $CONFIG_PATH" ;;
  esac
}

verify_marketplace_registered() {
  if [[ "$SKIP_MARKETPLACE_ADD" == true ]]; then
    verify_warn "marketplace registration was skipped"
    return
  fi
  if [[ ! -f "$CONFIG_PATH" ]]; then
    verify_warn "cannot verify marketplace registration because config is missing"
    return
  fi
  if grep -q '^\[marketplaces\.claude-code-local\]' "$CONFIG_PATH" && grep -q "source = \"$TARGET_ROOT\"" "$CONFIG_PATH"; then
    verify_pass "marketplace registered in config: claude-code-local"
  else
    verify_warn "marketplace registration not found in config; Codex app may still need a refresh or manual add"
  fi
}

verify_script_syntax() {
  local companion="$TARGET_ROOT/plugins/claude-code-handoff/scripts/claude-companion.mjs"
  local handoff="$TARGET_ROOT/plugins/claude-code-handoff/skills/claude-code-handoff/scripts/claude_handoff.sh"
  if command -v node >/dev/null 2>&1 && node --check "$companion" >/dev/null 2>&1; then
    verify_pass "companion syntax ok"
  else
    verify_fail "companion syntax check failed"
  fi
  if bash -n "$handoff" >/dev/null 2>&1; then
    verify_pass "handoff shell syntax ok"
  else
    verify_fail "handoff shell syntax check failed"
  fi
}

verify_claude() {
  if command -v claude >/dev/null 2>&1; then
    if version_line="$(probe_claude_version)"; then
      verify_pass "claude available: $version_line"
    else
      verify_warn "claude exists but version probe timed out or failed"
    fi
  else
    verify_warn "claude is not installed"
    log "install Claude Code with:"
    log "npm install -g @anthropic-ai/claude-code@latest"
  fi
}

run_smoke() {
  local companion="$TARGET_ROOT/plugins/claude-code-handoff/scripts/claude-companion.mjs"
  if [[ "$SKIP_SMOKE" == true ]]; then
    verify_warn "inspect smoke was skipped"
    return
  fi
  if [[ "$DRY_RUN" == true ]]; then
    verify_warn "inspect smoke skipped in dry-run"
    return
  fi
  if [[ ! -f "$companion" ]]; then
    verify_fail "cannot run inspect smoke because companion is missing"
    return
  fi
  log "running inspect smoke"
  if CODEWIZ_HANDOFF_TIMEOUT_SEC="${CODEWIZ_HANDOFF_TIMEOUT_SEC:-60}" node "$companion" inspect --repo "$PWD"; then
    verify_pass "inspect smoke completed"
  else
    verify_fail "inspect smoke failed; check claude installation and auth"
  fi
}

verify_installation() {
  log "verifying installation"
  verify_file "$TARGET_ROOT/.agents/plugins/marketplace.json" "marketplace manifest"
  verify_file "$TARGET_ROOT/plugins/claude-code-handoff/.codex-plugin/plugin.json" "plugin manifest"
  verify_file "$TARGET_ROOT/plugins/claude-code-handoff/scripts/claude-companion.mjs" "plugin companion"
  verify_file "$TARGET_ROOT/plugins/claude-code-handoff/skills/claude-code-handoff/SKILL.md" "plugin skill"
  verify_file "$TARGET_ROOT/plugins/claude-code-handoff/skills/claude-code-handoff/scripts/claude_handoff.sh" "handoff script"
  verify_file "$TARGET_ROOT/plugins/claude-code-handoff/skills/claude-code-handoff/scripts/result_schema.json" "result schema"
  if [[ "$DRY_RUN" == false ]]; then
    verify_script_syntax
  fi
  verify_marketplace_registered
  verify_config_enabled
  verify_claude
  run_smoke

  if [[ "$VERIFY_FAILURES" -gt 0 ]]; then
    log "verification failed: failures=$VERIFY_FAILURES warnings=$VERIFY_WARNINGS"
    exit 1
  fi
  log "verification passed: warnings=$VERIFY_WARNINGS"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-root)
      TARGET_ROOT="${2:?missing value for --target-root}"
      shift 2
      ;;
    --config)
      CONFIG_PATH="${2:?missing value for --config}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --skip-marketplace-add)
      SKIP_MARKETPLACE_ADD=true
      shift
      ;;
    --skip-config-enable)
      SKIP_CONFIG_ENABLE=true
      shift
      ;;
    --skip-smoke)
      SKIP_SMOKE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -d "$SOURCE_MARKETPLACE" ]] || {
  echo "missing bundled marketplace: $SOURCE_MARKETPLACE" >&2
  exit 1
}

log "source marketplace: $SOURCE_MARKETPLACE"
log "target marketplace: $TARGET_ROOT"

if [[ "$DRY_RUN" == false ]]; then
  rm -rf "$TARGET_ROOT"
  mkdir -p "$(dirname "$TARGET_ROOT")"
  cp -R "$SOURCE_MARKETPLACE" "$TARGET_ROOT"
else
  log "would replace target marketplace"
fi

PLUGIN_SCRIPT="$TARGET_ROOT/plugins/claude-code-handoff/scripts/claude-companion.mjs"
if [[ "$DRY_RUN" == false ]]; then
  chmod +x "$PLUGIN_SCRIPT" "$TARGET_ROOT/plugins/claude-code-handoff/skills/claude-code-handoff/scripts/claude_handoff.sh"
fi

if [[ "$SKIP_MARKETPLACE_ADD" == false ]]; then
  if command -v codex >/dev/null 2>&1; then
    log "registering marketplace with codex"
    run codex plugin marketplace add "$TARGET_ROOT" || log "marketplace add failed or already exists; continuing"
  else
    log "codex CLI not found; skipping marketplace registration"
  fi
fi

if [[ "$SKIP_CONFIG_ENABLE" == false ]]; then
  log "enabling plugin in $CONFIG_PATH"
  if [[ "$DRY_RUN" == true ]]; then
    log "would ensure [plugins.\"claude-code-handoff@claude-code-local\"] enabled = true"
  else
    mkdir -p "$(dirname "$CONFIG_PATH")"
    touch "$CONFIG_PATH"
    python3 - "$CONFIG_PATH" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
header = '[plugins."claude-code-handoff@claude-code-local"]'
pattern = re.compile(r'(?ms)^\[plugins\."claude-code-handoff@claude-code-local"\]\s*(.*?)(?=^\[|\Z)')
match = pattern.search(text)
if match:
    block = match.group(0)
    if re.search(r'(?m)^enabled\s*=', block):
        block = re.sub(r'(?m)^enabled\s*=.*$', 'enabled = true', block)
    else:
        block = block.rstrip() + "\nenabled = true\n"
    text = text[:match.start()] + block + text[match.end():]
else:
    if text and not text.endswith("\n"):
        text += "\n"
    text += f'\n{header}\nenabled = true\n'
path.write_text(text, encoding="utf-8")
PY
  fi
fi

verify_installation
log "done"
