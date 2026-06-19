#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA_PATH="$SCRIPT_DIR/result_schema.json"
RUNS_ROOT="${CLAUDE_HANDOFF_RUNS_ROOT:-$HOME/.codex/agent_handoff_runs}"
TIMEOUT_SEC="${CLAUDE_HANDOFF_TIMEOUT_SEC:-300}"
PROBE_TIMEOUT_SEC="${CLAUDE_HANDOFF_PROBE_TIMEOUT_SEC:-10}"
SYSTEM_PROMPT='跟我使用中文进行交互。你是被 Codex 调用的 worker。你和 Codex 不共享会话上下文，唯一可信交付物是 result.json 和 git diff。'

usage() {
  cat <<'USAGE'
Usage:
  claude_handoff.sh inspect --repo <path>
  claude_handoff.sh review --repo <path> --base <ref> --prompt <file>
  claude_handoff.sh task --repo <path> --mode read-only|write --prompt <file>
  claude_handoff.sh scenario <preset> --repo <path> [--base <ref>] [--prompt <file>]

Scenarios:
  review-diff        Read-only review of current diff against --base (default: HEAD).
  second-opinion     Read-only independent critique of a plan, patch, or decision.
  implement-subtask  Write-mode implementation of a bounded subtask.
  debug-investigation Read-only bug investigation with evidence and verification commands.
  test-plan          Read-only test strategy and missing test analysis.
  refactor-plan      Read-only refactor plan with risk and migration notes.
  docs-sync          Read-only check for docs/spec/AGENTS updates needed by current changes.

Environment:
  CLAUDE_HANDOFF_CLI       Override worker CLI path.
  CLAUDE_HANDOFF_RUNS_ROOT Override audit run directory root.
  CLAUDE_HANDOFF_TIMEOUT_SEC Worker timeout in seconds. Default: 300.
  CLAUDE_HANDOFF_PROBE_TIMEOUT_SEC CLI version/help timeout in seconds. Default: 10.
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

json_string() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1], ensure_ascii=False))' "$1"
}

resolve_cli() {
  if [[ -n "${CLAUDE_HANDOFF_CLI:-}" ]]; then
    [[ -x "$CLAUDE_HANDOFF_CLI" || -n "$(command -v "$CLAUDE_HANDOFF_CLI" 2>/dev/null)" ]] || return 1
    command -v "$CLAUDE_HANDOFF_CLI" 2>/dev/null || printf '%s\n' "$CLAUDE_HANDOFF_CLI"
    return 0
  fi
  if command -v claude >/dev/null 2>&1; then
    command -v claude
    return 0
  fi
  if [[ -x "$HOME/.local/bin/claude" ]]; then
    printf '%s\n' "$HOME/.local/bin/claude"
    return 0
  fi
  return 1
}

status_short() {
  local repo="$1"
  git -C "$repo" status --short 2>/dev/null || true
}

diff_stat() {
  local repo="$1"
  git -C "$repo" diff --stat 2>/dev/null || true
}

write_metadata() {
  local path="$1"
  local cli="$2"
  local repo="$3"
  local command_name="$4"
  local mode="$5"
  local base="$6"
  local run_dir="$7"
  local started_at="$8"
  local ended_at="$9"
  local exit_code="${10}"
  local before_status="${11}"
  local after_status="${12}"
  local diff_stat_text="${13}"
  local version_text="${14}"
  python3 - "$path" "$cli" "$repo" "$command_name" "$mode" "$base" "$run_dir" "$started_at" "$ended_at" "$exit_code" "$before_status" "$after_status" "$diff_stat_text" "$version_text" <<'PY'
import json
import sys

path, cli, repo, command_name, mode, base, run_dir, started_at, ended_at, exit_code, before_status, after_status, diff_stat_text, version_text = sys.argv[1:]
payload = {
    "cli_path": cli,
    "cli_version": version_text,
    "repo": repo,
    "command": command_name,
    "mode": mode,
    "base": base,
    "run_dir": run_dir,
    "started_at": started_at,
    "ended_at": ended_at,
    "exit_code": int(exit_code),
    "git_status_before": before_status.splitlines(),
    "git_status_after": after_status.splitlines(),
    "git_diff_stat": diff_stat_text.splitlines(),
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
}

terminate_tree() {
  local pid="$1"
  local children
  children="$(pgrep -P "$pid" 2>/dev/null || true)"
  if [[ -n "$children" ]]; then
    for child in $children; do
      terminate_tree "$child"
    done
  fi
  kill -TERM "$pid" 2>/dev/null || true
}

probe_cli() {
  local cli="$1"
  shift
  local tmp pid elapsed rc
  tmp="$(mktemp /tmp/claude-code-handoff-probe.XXXXXX)"
  "$cli" "$@" >"$tmp" 2>&1 &
  pid=$!
  elapsed=0
  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$elapsed" -ge "$PROBE_TIMEOUT_SEC" ]]; then
      terminate_tree "$pid"
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true
      printf 'probe timed out after %ss: %s %s\n' "$PROBE_TIMEOUT_SEC" "$cli" "$*" >"$tmp"
      cat "$tmp"
      rm -f "$tmp"
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  wait "$pid" 2>/dev/null
  rc=$?
  cat "$tmp"
  rm -f "$tmp"
  return "$rc"
}

validate_result() {
  local result_path="$1"
  python3 - "$result_path" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8") as f:
        data = json.load(f)
except Exception as exc:
    print(f"invalid json: {exc}", file=sys.stderr)
    sys.exit(1)

required = {
    "status": str,
    "summary": str,
    "findings": list,
    "files_touched": list,
    "commands_run": list,
    "tests": list,
    "next_actions": list,
}
for key, typ in required.items():
    if key not in data:
        print(f"missing key: {key}", file=sys.stderr)
        sys.exit(1)
    if not isinstance(data[key], typ):
        print(f"wrong type for {key}", file=sys.stderr)
        sys.exit(1)
if data["status"] not in {"success", "needs_attention", "failed"}:
    print("invalid status", file=sys.stderr)
    sys.exit(1)
PY
}

extract_result_from_stdout() {
  local stdout_path="$1"
  local result_path="$2"
  python3 - "$stdout_path" "$result_path" <<'PY'
import json
import re
import sys

stdout_path, result_path = sys.argv[1:]
text = open(stdout_path, encoding="utf-8", errors="replace").read()

def try_payload(obj):
    if isinstance(obj, dict) and {"status", "summary", "findings", "files_touched", "commands_run", "tests", "next_actions"} <= obj.keys():
        return obj
    if isinstance(obj, dict) and isinstance(obj.get("result"), str):
        return extract_from_text(obj["result"])
    return None

def extract_from_text(value):
    for fenced in re.findall(r"```(?:json)?\s*(\{.*?\})\s*```", value, flags=re.S):
        try:
            obj = json.loads(fenced)
            payload = try_payload(obj)
            if payload:
                return payload
        except Exception:
            pass
    decoder = json.JSONDecoder()
    for match in re.finditer(r"\{", value):
        try:
            obj, _ = decoder.raw_decode(value[match.start():])
        except Exception:
            continue
        payload = try_payload(obj)
        if payload:
            return payload
    return None

payload = None
for line in text.splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    payload = try_payload(obj)
    if payload:
        break

if payload is None:
    payload = extract_from_text(text)

if payload is None:
    sys.exit(1)

with open(result_path, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
}

write_failed_result() {
  local result_path="$1"
  local summary="$2"
  python3 - "$result_path" "$summary" <<'PY'
import json
import sys

path, summary = sys.argv[1:]
payload = {
    "status": "failed",
    "summary": summary,
    "findings": [],
    "files_touched": [],
    "commands_run": [],
    "tests": [{"command": "", "status": "not_run", "summary": "未运行"}],
    "next_actions": ["查看 stdout.log、stderr.log 和 metadata.json。"],
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
}

parse_args() {
  COMMAND_NAME="${1:-}"
  [[ -n "$COMMAND_NAME" ]] || { usage; exit 2; }
  shift || true

  REPO=""
  PROMPT_FILE=""
  BASE=""
  MODE=""
  SCENARIO=""

  if [[ "$COMMAND_NAME" == "scenario" ]]; then
    SCENARIO="${1:-}"
    [[ -n "$SCENARIO" ]] || die "scenario preset is required"
    shift || true
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo)
        REPO="${2:-}"; shift 2 ;;
      --prompt)
        PROMPT_FILE="${2:-}"; shift 2 ;;
      --base)
        BASE="${2:-}"; shift 2 ;;
      --mode)
        MODE="${2:-}"; shift 2 ;;
      -h|--help)
        usage; exit 0 ;;
      *)
        die "unknown argument: $1" ;;
    esac
  done

  case "$COMMAND_NAME" in
    inspect)
      [[ -n "$REPO" ]] || die "--repo is required"
      MODE="inspect"
      ;;
    review)
      [[ -n "$REPO" ]] || die "--repo is required"
      [[ -n "$PROMPT_FILE" ]] || die "--prompt is required"
      [[ -n "$BASE" ]] || die "--base is required"
      MODE="read-only"
      ;;
    task)
      [[ -n "$REPO" ]] || die "--repo is required"
      [[ -n "$PROMPT_FILE" ]] || die "--prompt is required"
      [[ "$MODE" == "read-only" || "$MODE" == "write" ]] || die "--mode must be read-only or write"
      ;;
    scenario)
      [[ -n "$REPO" ]] || die "--repo is required"
      case "$SCENARIO" in
        review-diff)
          MODE="read-only"
          [[ -n "$BASE" ]] || BASE="HEAD"
          ;;
        second-opinion|debug-investigation|test-plan|refactor-plan|docs-sync)
          MODE="read-only"
          ;;
        implement-subtask)
          MODE="write"
          [[ -n "$PROMPT_FILE" ]] || die "--prompt is required for scenario implement-subtask"
          ;;
        *)
          die "unknown scenario preset: $SCENARIO" ;;
      esac
      ;;
    *)
      die "unknown command: $COMMAND_NAME" ;;
  esac

  [[ -d "$REPO" ]] || die "repo does not exist: $REPO"
  REPO="$(cd "$REPO" && pwd)"
  if [[ -n "$PROMPT_FILE" ]]; then
    [[ -f "$PROMPT_FILE" ]] || die "prompt file does not exist: $PROMPT_FILE"
    PROMPT_FILE="$(cd "$(dirname "$PROMPT_FILE")" && pwd)/$(basename "$PROMPT_FILE")"
  fi
}

append_optional_prompt() {
  local prompt_path="$1"
  if [[ -n "${PROMPT_FILE:-}" ]]; then
    {
      printf '\n## User-provided prompt\n\n'
      cat "$PROMPT_FILE"
      printf '\n'
    } >> "$prompt_path"
  fi
}

write_scenario_prompt() {
  local scenario="$1"
  local prompt_path="$2"
  local repo="$3"
  local base="$4"

  case "$scenario" in
    review-diff)
      cat > "$prompt_path" <<EOF
# Scenario: review-diff

Review the current git diff in this repo against ${base:-HEAD}. Focus only on actionable issues introduced by the diff.

Report findings for correctness, security, performance, maintainability, and developer experience. Do not report style preferences or broad refactor suggestions unless they point to a concrete bug or regression risk.

For each finding, include an exact repo-relative file path, 1-based line number, severity, and concise body.
EOF
      append_optional_prompt "$prompt_path"
      ;;
    second-opinion)
      cat > "$prompt_path" <<'EOF'
# Scenario: second-opinion

Give an independent second opinion on the plan, patch, or decision described below. Do not modify files.

Focus on:
- Hidden correctness risks
- Missing edge cases
- Overcomplicated or fragile implementation choices
- Better alternatives that fit the existing codebase
- Verification gaps

Return concrete findings and next actions. If the current direction is sound, say so and identify the remaining risk.
EOF
      append_optional_prompt "$prompt_path"
      ;;
    implement-subtask)
      cat > "$prompt_path" <<'EOF'
# Scenario: implement-subtask

Implement the bounded subtask described below. Keep edits narrow and aligned with existing project patterns.

Before editing, inspect the relevant files and current conventions. After editing, run the most relevant low-cost verification command available in the repo. Report files touched, commands run, tests, and any remaining risk.
EOF
      append_optional_prompt "$prompt_path"
      ;;
    debug-investigation)
      cat > "$prompt_path" <<'EOF'
# Scenario: debug-investigation

Investigate the bug or failure described below without modifying files.

Build an evidence chain:
- What is observed
- Where the behavior likely originates
- Relevant files, functions, or commands inspected
- Reproduction or verification commands worth running
- Most likely root cause and confidence
- Suggested fix, but no code edits
EOF
      append_optional_prompt "$prompt_path"
      ;;
    test-plan)
      cat > "$prompt_path" <<'EOF'
# Scenario: test-plan

Analyze the current change or described feature and propose a focused test plan. Do not modify files.

Cover:
- Existing tests that should be run
- Missing unit/integration/e2e coverage
- High-risk edge cases
- Suggested minimal tests to add
- Any manual smoke checks that are justified
EOF
      append_optional_prompt "$prompt_path"
      ;;
    refactor-plan)
      cat > "$prompt_path" <<'EOF'
# Scenario: refactor-plan

Propose a refactor plan for the code or problem described below. Do not modify files.

Keep the plan implementation-ready:
- Current code shape and constraints
- Target shape
- Step-by-step edits
- Compatibility risks
- Verification commands
- What to avoid changing
EOF
      append_optional_prompt "$prompt_path"
      ;;
    docs-sync)
      cat > "$prompt_path" <<'EOF'
# Scenario: docs-sync

Check whether the current repo changes require documentation updates. Do not modify files.

Inspect relevant README, docs, specs, AGENTS.md, or project guidance if present. Report:
- Docs that are stale or missing
- Exact sections likely needing updates
- Suggested wording at a high level
- Cases where no docs update is needed
EOF
      append_optional_prompt "$prompt_path"
      ;;
    *)
      die "unknown scenario preset: $scenario" ;;
  esac
}

build_driver_prompt() {
  local command_name="$1"
  local mode="$2"
  local repo="$3"
  local prompt_path="$4"
  local result_path="$5"
  local base="$6"
  local before_status="$7"

  local write_policy
  if [[ "$mode" == "write" ]]; then
    write_policy="你可以修改 repo 内文件。完成后记录实际修改、git status、git diff --stat，以及运行过的测试。"
  else
    write_policy="不要修改任何文件。只允许读取、分析和运行不会改动工作区的检查命令。"
  fi

  cat <<EOF
你是被 Codex 调用的 worker。请严格按以下文件协议交付。

Repo: $repo
任务类型: $command_name${SCENARIO:+:$SCENARIO}
模式: $mode
Base ref: ${base:-N/A}
用户任务文件: $prompt_path
结果输出文件: $result_path
JSON schema 文件: $SCHEMA_PATH

工作区执行前 git status --short:
$(printf '%s\n' "$before_status")

要求：
1. 先完整读取用户任务文件。
2. $write_policy
3. 如果是 review，请优先查看与 base ref 相关的 diff，并只报告 correctness、security、performance、maintainability、developer experience 相关的 actionable 问题。
4. 最终必须把一个 JSON object 写入结果输出文件。不要写 Markdown，不要包裹代码块。
5. JSON object 必须包含这些字段：status, summary, findings, files_touched, commands_run, tests, next_actions。
6. summary、finding body、next_actions 使用中文。
7. findings 中的 file 使用 repo 相对路径，line 使用 1-based 行号；没有问题时 findings 为空数组。
8. tests 中至少放一项；如果没有运行测试，使用 {"command":"","status":"not_run","summary":"未运行"}。
9. 不要读取或总结 ~/.claude 下的日志、token 或私有配置。

如果你无法完成，也必须写 result.json，status 设为 failed 或 needs_attention，并解释原因。
EOF
}

run_inspect() {
  local cli="$1"
  local run_dir="$2"
  local result_path="$run_dir/result.json"
  local metadata_path="$run_dir/metadata.json"
  local started_at ended_at version_text help_text supports_print supports_json supports_append supports_permission

  started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  version_text="$(probe_cli "$cli" -version || probe_cli "$cli" --version || true)"
  help_text="$(probe_cli "$cli" --help || true)"
  ended_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  [[ "$help_text" == *"--print"* ]] && supports_print=true || supports_print=false
  [[ "$help_text" == *"--output-format"* ]] && supports_json=true || supports_json=false
  [[ "$help_text" == *"--append-system-prompt"* ]] && supports_append=true || supports_append=false
  [[ "$help_text" == *"--permission-mode"* ]] && supports_permission=true || supports_permission=false

  python3 - "$result_path" "$cli" "$version_text" "$supports_print" "$supports_json" "$supports_append" "$supports_permission" <<'PY'
import json
import sys

path, cli, version, supports_print, supports_json, supports_append, supports_permission = sys.argv[1:]
payload = {
    "status": "success",
    "summary": f"已解析 worker CLI: {cli}; version: {version.strip()}",
    "findings": [],
    "files_touched": [],
    "commands_run": [f"{cli} -version", f"{cli} --help"],
    "tests": [{
        "command": "inspect",
        "status": "passed",
        "summary": f"supports_print={supports_print}, supports_json={supports_json}, supports_append_system_prompt={supports_append}, supports_permission_mode={supports_permission}",
    }],
    "next_actions": [],
}
with open(path, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
  write_metadata "$metadata_path" "$cli" "$REPO" "$COMMAND_NAME" "$MODE" "${BASE:-}" "$run_dir" "$started_at" "$ended_at" 0 "" "" "" "$version_text"
  printf 'run_dir=%s\nresult=%s\n' "$run_dir" "$result_path"
}

main() {
  parse_args "$@"

  local cli
  cli="$(resolve_cli)" || die "cannot find claude or fallback claude"

  local timestamp safe_mode run_dir result_path metadata_path prompt_copy driver_path stdout_path stderr_path
  timestamp="$(date +"%Y%m%d_%H%M%S")"
  safe_mode="${COMMAND_NAME}"
  [[ "$COMMAND_NAME" == "task" ]] && safe_mode="task_${MODE}"
  [[ "$COMMAND_NAME" == "scenario" ]] && safe_mode="scenario_${SCENARIO}"
  run_dir="$RUNS_ROOT/${timestamp}_${safe_mode}"
  mkdir -p "$run_dir"
  result_path="$run_dir/result.json"
  metadata_path="$run_dir/metadata.json"
  prompt_copy="$run_dir/prompt.md"
  driver_path="$run_dir/driver_prompt.md"
  stdout_path="$run_dir/stdout.log"
  stderr_path="$run_dir/stderr.log"

  if [[ "$COMMAND_NAME" == "inspect" ]]; then
    run_inspect "$cli" "$run_dir"
    return 0
  fi

  if [[ "$COMMAND_NAME" == "scenario" ]]; then
    write_scenario_prompt "$SCENARIO" "$prompt_copy" "$REPO" "${BASE:-}"
  else
    cp "$PROMPT_FILE" "$prompt_copy"
  fi

  local before_status after_status diff_stat_text started_at ended_at exit_code version_text help_text supports_headless
  before_status="$(status_short "$REPO")"
  started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  version_text="$(probe_cli "$cli" -version || probe_cli "$cli" --version || true)"
  help_text="$(probe_cli "$cli" --help || true)"
  if [[ "$help_text" == *"--print"* && "$help_text" == *"--output-format"* && "$help_text" == *"--permission-mode"* ]]; then
    supports_headless=true
  else
    supports_headless=false
  fi

  build_driver_prompt "$COMMAND_NAME" "$MODE" "$REPO" "$prompt_copy" "$result_path" "${BASE:-}" "$before_status" > "$driver_path"

  local worker_pid elapsed timed_out
  timed_out=false
  if [[ "$supports_headless" == true ]]; then
    (
      cd "$REPO" && "$cli" --print \
        --output-format json \
        --permission-mode bypassPermissions \
        --append-system-prompt "$SYSTEM_PROMPT" \
        "$(cat "$driver_path")"
    ) >"$stdout_path" 2>"$stderr_path" &
  else
    (
      cd "$REPO" && "$cli" \
        --dangerously-skip-permissions \
        --append-system-prompt "$SYSTEM_PROMPT" \
        "$(cat "$driver_path")"
    ) >"$stdout_path" 2>"$stderr_path" &
  fi
  worker_pid=$!
  elapsed=0
  while kill -0 "$worker_pid" 2>/dev/null; do
    if [[ "$elapsed" -ge "$TIMEOUT_SEC" ]]; then
      timed_out=true
      {
        printf '\nclaude_handoff: worker timed out after %s seconds; terminating process tree rooted at %s\n' "$TIMEOUT_SEC" "$worker_pid"
      } >>"$stderr_path"
      terminate_tree "$worker_pid"
      sleep 2
      kill -KILL "$worker_pid" 2>/dev/null || true
      break
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  wait "$worker_pid" 2>/dev/null
  exit_code=$?
  if [[ "$timed_out" == true ]]; then
    exit_code=124
  fi

  ended_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  after_status="$(status_short "$REPO")"
  diff_stat_text="$(diff_stat "$REPO")"

  if [[ "$timed_out" == true ]]; then
    write_failed_result "$result_path" "worker 超时。timeout=${TIMEOUT_SEC}s"
  elif ! validate_result "$result_path" >/dev/null 2>&1; then
    extract_result_from_stdout "$stdout_path" "$result_path" >/dev/null 2>&1 || true
  fi

  if ! validate_result "$result_path" >/dev/null 2>&1; then
    write_failed_result "$result_path" "worker 未生成合法 result.json。exit_code=$exit_code"
  fi

  if [[ "$MODE" != "write" && "$before_status" != "$after_status" ]]; then
    python3 - "$result_path" "$before_status" "$after_status" <<'PY'
import json
import sys

path, before, after = sys.argv[1:]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
data["status"] = "failed"
data["summary"] = "read-only/review 模式下工作区发生了变更，结果已标记为失败。"
data.setdefault("next_actions", []).append("检查 git status 和 git diff，确认是否需要保留 worker 的修改。")
data.setdefault("tests", []).append({
    "command": "git status --short before/after",
    "status": "failed",
    "summary": f"before={before!r}; after={after!r}",
})
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY
  fi

  write_metadata "$metadata_path" "$cli" "$REPO" "$COMMAND_NAME" "$MODE" "${BASE:-}" "$run_dir" "$started_at" "$ended_at" "$exit_code" "$before_status" "$after_status" "$diff_stat_text" "$version_text"
  printf 'run_dir=%s\nresult=%s\nexit_code=%s\n' "$run_dir" "$result_path" "$exit_code"
}

main "$@"
