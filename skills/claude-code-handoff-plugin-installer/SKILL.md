---
name: claude-code-handoff-plugin-installer
description: Install, update, verify, or package the bundled claude-code-handoff Codex plugin from this skill's references. Use when a user wants to share or install the claude-code-handoff plugin, set up claude for Codex delegation, register the local Codex marketplace, enable the plugin in config.toml, or validate the installation for another person.
---

# Claude Code Handoff Plugin Installer

Use this skill to install the bundled `claude-code-handoff` Codex plugin from `references/claude-code-handoff-marketplace/`.

This is an installer skill. It does not delegate work to `claude` itself. After installation, new Codex sessions can use the `claude-code-handoff` plugin/skill.

## Quick Start

Run the installer script from this skill:

```bash
~/.codex/skills/claude-code-handoff-plugin-installer/scripts/install_claude_code_handoff_plugin.sh
```

What it does:

1. Copies `references/claude-code-handoff-marketplace/` to `~/.agents/claude-code-marketplace/`.
2. Runs `codex plugin marketplace add ~/.agents/claude-code-marketplace` when `codex` supports it.
3. Ensures this config exists in `~/.codex/config.toml`:

```toml
[plugins."claude-code-handoff@claude-code-local"]
enabled = true
```

4. Checks whether `claude` is available.
5. Verifies the installed files, script syntax, marketplace registration, config enablement, and worker CLI.
6. Runs a lightweight plugin `inspect` smoke when possible.

## Prerequisites

The worker CLI should be installed globally:

```bash
npm install -g @anthropic-ai/claude-code@latest
claude --version
```

If `claude` is missing, the plugin can still be installed, but real handoff tasks will fail until the worker CLI is installed.

## Useful Options

```bash
scripts/install_claude_code_handoff_plugin.sh --dry-run
scripts/install_claude_code_handoff_plugin.sh --target-root /path/to/claude-code-marketplace
scripts/install_claude_code_handoff_plugin.sh --skip-marketplace-add
scripts/install_claude_code_handoff_plugin.sh --skip-config-enable
scripts/install_claude_code_handoff_plugin.sh --skip-smoke
```

Use `--target-root` when installing from a nonstandard location or preparing a shareable marketplace folder.

## Verification

The installer always runs a verification phase after installation. It checks:

- marketplace manifest exists;
- plugin manifest exists;
- companion, skill, handoff script, and result schema exist;
- `node --check` passes for the companion;
- `bash -n` passes for the handoff script;
- `~/.codex/config.toml` enables `claude-code-handoff@claude-code-local`;
- `claude` can be found and its version probe returns within 10 seconds;
- optional inspect smoke completes.

`--skip-smoke` only skips the live `inspect` smoke. It does not skip file/config/script verification.

After installation, users can also verify manually:

```bash
node ~/.agents/claude-code-marketplace/plugins/claude-code-handoff/scripts/claude-companion.mjs inspect --repo /path/to/repo
node ~/.agents/claude-code-marketplace/plugins/claude-code-handoff/scripts/claude-companion.mjs status --repo /path/to/repo --all
```

The trusted result is `result.json` under `~/.codex/agent_handoff_runs/`.

## Bundled Files

- `references/claude-code-handoff-marketplace/`: complete local Codex marketplace containing the plugin.
- `scripts/install_claude_code_handoff_plugin.sh`: deterministic installer and verifier.

Do not read or summarize Claude Code logs or private config under `~/.claude`; they may contain personal or sensitive data.
