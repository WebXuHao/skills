# claude-code-handoff scripts

`claude_handoff.sh` wraps `claude` for Codex-to-worker handoffs.

## Setup

```bash
npm config set registry https://registry.npmjs.org
npm install -g @anthropic-ai/claude-code@latest
claude --version
claude --help
```

## Commands

```bash
./claude_handoff.sh inspect --repo /path/to/repo
./claude_handoff.sh review --repo /path/to/repo --base origin/main --prompt /path/to/prompt.md
./claude_handoff.sh task --repo /path/to/repo --mode read-only --prompt /path/to/prompt.md
./claude_handoff.sh task --repo /path/to/repo --mode write --prompt /path/to/prompt.md
./claude_handoff.sh scenario review-diff --repo /path/to/repo --base origin/main
./claude_handoff.sh scenario second-opinion --repo /path/to/repo --prompt /path/to/prompt.md
./claude_handoff.sh scenario implement-subtask --repo /path/to/repo --prompt /path/to/prompt.md
```

## Scenarios

- `review-diff`: read-only review of current diff against `--base` (default: `HEAD`).
- `second-opinion`: read-only independent critique of a plan, patch, or decision.
- `implement-subtask`: write-mode implementation of a bounded subtask.
- `debug-investigation`: read-only bug investigation with evidence and verification commands.
- `test-plan`: read-only test strategy and missing test analysis.
- `refactor-plan`: read-only refactor plan with risk and migration notes.
- `docs-sync`: read-only check for docs/spec/AGENTS updates needed by current changes.

Set `CLAUDE_HANDOFF_CLI=/path/to/cli` to override CLI discovery. The default lookup is `claude`, then `$HOME/.local/bin/claude`.

Set `CLAUDE_HANDOFF_TIMEOUT_SEC=120` to override the worker timeout. The default is 300 seconds. On timeout the wrapper writes a failed `result.json` and records the timeout in `stderr.log`.

Set `CLAUDE_HANDOFF_PROBE_TIMEOUT_SEC=5` to override the quick `-version` / `--help` probe timeout. The default is 10 seconds.

Each run writes an audit folder under `~/.codex/agent_handoff_runs/`. Consume `result.json`; use logs only for debugging.
