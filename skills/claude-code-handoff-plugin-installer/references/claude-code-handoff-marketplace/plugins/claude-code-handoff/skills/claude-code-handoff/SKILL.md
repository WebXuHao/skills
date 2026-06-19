---
name: claude-code-handoff
description: Delegate coding reviews, implementation subtasks, research checks, debugging investigations, test planning, refactor planning, docs-sync checks, or second-opinion analysis from Codex to the local Claude Code CLI. Use when the user asks Codex to hand work to Claude Code, claude, Claude, or another agent for review, implementation, investigation, validation, or common development collaboration scenarios, and when the result must be returned through auditable files and git diff rather than shared chat context.
---

# Claude Code Handoff

Use this skill to call `claude` as a worker from Codex. Codex and `claude` do not share conversation state. The contract is file based: Codex writes a prompt, the worker writes `result.json`, and Codex reads `result.json` plus git status/diff.

## Quick Start

Prefer the bundled companion instead of calling `claude` directly. It wraps the handoff script and records job status/result files per workspace:

```bash
node ~/.codex/skills/claude-code-handoff/scripts/claude-companion.mjs inspect --repo /path/to/repo
node ~/.codex/skills/claude-code-handoff/scripts/claude-companion.mjs scenario review-diff --repo /path/to/repo --base origin/main
node ~/.codex/skills/claude-code-handoff/scripts/claude-companion.mjs scenario second-opinion --repo /path/to/repo --prompt /path/to/prompt.md
node ~/.codex/skills/claude-code-handoff/scripts/claude-companion.mjs scenario implement-subtask --repo /path/to/repo --prompt /path/to/prompt.md
node ~/.codex/skills/claude-code-handoff/scripts/claude-companion.mjs status --repo /path/to/repo --all
node ~/.codex/skills/claude-code-handoff/scripts/claude-companion.mjs result --repo /path/to/repo
node ~/.codex/skills/claude-code-handoff/scripts/claude-companion.mjs cancel --repo /path/to/repo <job-id>
```

For a long run, add `--background` to `inspect`, `review`, `task`, or `scenario`, then use `status` and `result`.

If the companion is unavailable, run the bundled script:

```bash
~/.codex/skills/claude-code-handoff/scripts/claude_handoff.sh inspect --repo /path/to/repo
~/.codex/skills/claude-code-handoff/scripts/claude_handoff.sh review --repo /path/to/repo --base origin/main --prompt /path/to/prompt.md
~/.codex/skills/claude-code-handoff/scripts/claude_handoff.sh task --repo /path/to/repo --mode read-only --prompt /path/to/prompt.md
~/.codex/skills/claude-code-handoff/scripts/claude_handoff.sh task --repo /path/to/repo --mode write --prompt /path/to/prompt.md
~/.codex/skills/claude-code-handoff/scripts/claude_handoff.sh scenario review-diff --repo /path/to/repo --base origin/main
~/.codex/skills/claude-code-handoff/scripts/claude_handoff.sh scenario second-opinion --repo /path/to/repo --prompt /path/to/prompt.md
~/.codex/skills/claude-code-handoff/scripts/claude_handoff.sh scenario implement-subtask --repo /path/to/repo --prompt /path/to/prompt.md
```

The script prints the run directory and result path. Read `result.json` first. Use `stdout.log` and `stderr.log` only for troubleshooting.

## Workflow

1. Write the task to a prompt file. Be explicit about the expected review focus, implementation scope, and commands worth running.
2. Choose the mode:
   - `review`: inspect a diff and report findings. This must not modify the repo.
   - `task --mode read-only`: investigate or give a second opinion without modifying the repo.
   - `task --mode write`: allow the worker to edit the repo.
   - `scenario <preset>`: use a built-in development-collaboration prompt.
   - `inspect`: verify CLI discovery without calling the model.
3. Run `scripts/claude_handoff.sh` with absolute repo and prompt paths.
4. Read the generated `result.json`. Treat it as the handoff response.
5. If write mode was used, inspect git diff yourself before trusting the patch.

## Contract

Each run creates:

```text
~/.codex/agent_handoff_runs/<timestamp>_<mode>/
  prompt.md
  driver_prompt.md
  stdout.log
  stderr.log
  result.json
  metadata.json
```

`result.json` has this shape:

```json
{
  "status": "success",
  "summary": "中文摘要",
  "findings": [
    {
      "severity": "medium",
      "file": "src/example.ts",
      "line": 12,
      "body": "问题说明"
    }
  ],
  "files_touched": [],
  "commands_run": [],
  "tests": [
    {
      "command": "npm test",
      "status": "not_run",
      "summary": "未运行"
    }
  ],
  "next_actions": []
}
```

## Rules

- Do not read or summarize Claude Code logs or private config under `~/.claude`; they may contain personal or sensitive data.
- Do not rely on natural-language stdout as the source of truth. Use `result.json`.
- For `review` and `read-only`, treat any repo mutation as a failure unless the user explicitly asked for write mode.
- For `write`, verify changes with `git status --short` and `git diff` before reporting completion.
- Prefer `claude`. The script falls back to `$HOME/.local/bin/claude` only when `claude` is unavailable.

## Built-in Scenarios

Use scenario presets when the user asks for a common collaboration pattern and there is no need to hand-write a custom prompt.

- `review-diff`: read-only diff review. Use for “让 Claude/Claude Code review 当前 diff”.
- `second-opinion`: read-only critique of a plan, patch, or decision. Use after Codex has a proposed approach or patch.
- `implement-subtask`: write-mode implementation of a bounded subtask. Use only when the requested scope is narrow enough to delegate.
- `debug-investigation`: read-only bug investigation. Use when the user wants another agent to trace evidence before edits.
- `test-plan`: read-only test strategy. Use when deciding what tests or smoke checks a change needs.
- `refactor-plan`: read-only refactor plan. Use before broad refactors.
- `docs-sync`: read-only documentation check. Use when current code changes may require README, spec, or AGENTS updates.

Pass `--prompt` with extra context whenever available. `review-diff`, `test-plan`, and `docs-sync` can run without a prompt by inspecting the repo and current diff.

## Script Resources

- `scripts/claude_handoff.sh`: worker wrapper and audit-log generator.
- `scripts/claude-companion.mjs`: job lifecycle wrapper for foreground/background runs, status, result, and cancel.
- `scripts/result_schema.json`: expected result shape for worker output.

Set `CLAUDE_HANDOFF_TIMEOUT_SEC` to override the worker timeout. The default is 300 seconds.

## Companion State

The companion keeps a workspace-scoped job registry under `~/.codex/claude-companion/state/`.
It still treats `result.json` and git diff as the trusted deliverables. Use the shell script directly when you need the lowest-level audit run; use the companion when you want job lifecycle management.
