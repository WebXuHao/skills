# Skills

这个仓库用于存放可复用的 AI Agent skills。当前包含：

- `defining-goals`：定义目标
- `designing-loops`：设计 Loops
- `claude-code-handoff-plugin-installer`：安装 Claude Code Handoff Codex 插件
- `devspace-mcp-setup`：安装、配置并验证 DevSpace MCP

## Skill 列表

### `devspace-mcp-setup`

用于把 `@waishnav/devspace` 从零安装到真实 MCP 调通状态。

适合这些场景：

- 把 ChatGPT 或其他 MCP client 连接到本机项目目录。
- 用 Cloudflare tunnel、自有域名或公网 HTTPS 暴露 DevSpace MCP。
- 判断 ChatGPT UI 显示异常时，MCP 协议层是否真实可用。
- 通过只读 marker 文件验证 `tools/list`、`open_workspace` 和 `read`。
- 检查 `allowedRoots`、owner password、`bash` 暴露风险等安全边界。

这个 skill 自带 smoke 脚本：

```bash
~/.codex/skills/devspace-mcp-setup/scripts/devspace_mcp_smoke.mjs
```

脚本默认从 `~/.devspace/auth.json` 读取 owner token，但不会打印 secret。成功时会输出 endpoint、工具列表、workspaceId 和 marker 检查结果。

### `defining-goals`

用于把模糊需求澄清成有边界、可验证、可执行的目标。

适合这些场景：

- 用户说“优化一下”“做好一点”“自动处理一下”，但完成标准不清楚。
- 需要把 `/goal`、Agent 任务、OKR、成功指标或停止条件写清楚。
- 需要在执行前通过反问、项目代码、文档、测试、issue、PR、日志或连接器补齐上下文。
- 需要避免 Agent 为了通过验证器而删除测试、削弱断言、绕过检查或扩大范围。

核心产出：

- 目标
- 完成标准
- 已检查证据
- 待确认问题
- 边界
- 资源
- 失败处理
- 需要记录的状态

### `designing-loops`

用于设计、审查或加固可以反复运行的 Agent loop。

适合这些场景：

- 设计 `/loop`、定时任务、cron、hook、CI 修复循环、PR review 循环、issue triage 循环。
- 把人类反复提示 Agent 的流程，变成可控的自动系统。
- 需要定义 loop 的触发、发现、分流、worktree 隔离、知识体系、连接器、子 Agent、验证者、状态和停止规则。
- 需要避免验证债、理解债、成本漂移、权限膨胀和过期知识造成的自动化风险。

`designing-loops` 依赖 `defining-goals`：设计 loop 前必须先把目标定义清楚。目标不清楚时，不应该启动自动循环。

### `claude-code-handoff-plugin-installer`

用于安装社区版 `claude-code-handoff` Codex 插件。这个 skill 自带完整插件文件，放在：

```text
skills/claude-code-handoff-plugin-installer/references/claude-code-handoff-marketplace/
```

安装器会把内置 marketplace 复制到 `~/.agents/claude-code-marketplace/`，注册 Codex marketplace，启用插件配置，并验证：

- 插件文件完整性
- companion / handoff 脚本语法
- marketplace 和 `~/.codex/config.toml` 状态
- `claude` CLI 可用性
- `inspect` smoke

社区版依赖真正的 Claude Code CLI：

```bash
npm install -g @anthropic-ai/claude-code@latest
claude --version
```

安装这个 skill 后执行：

```bash
~/.codex/skills/claude-code-handoff-plugin-installer/scripts/install_claude_code_handoff_plugin.sh
```

## 让 AI 帮你安装

### Codex

把下面这段话发给 Codex：

```text
请使用 skill-installer 从 GitHub 仓库 WebXuHao/skills 安装这些 skill：
- skills/devspace-mcp-setup
- skills/defining-goals
- skills/designing-loops
- skills/claude-code-handoff-plugin-installer

安装到 ~/.codex/skills。安装完成后告诉我需要重启 Codex 或新开 thread 才能使用。
```

如果 Codex 不能直接使用安装器，也可以让它执行等价命令：

```bash
mkdir -p ~/.codex/skills
git clone https://github.com/WebXuHao/skills.git /tmp/webxuhao-skills
cp -R /tmp/webxuhao-skills/skills/devspace-mcp-setup ~/.codex/skills/devspace-mcp-setup
cp -R /tmp/webxuhao-skills/skills/defining-goals ~/.codex/skills/defining-goals
cp -R /tmp/webxuhao-skills/skills/designing-loops ~/.codex/skills/designing-loops
cp -R /tmp/webxuhao-skills/skills/claude-code-handoff-plugin-installer ~/.codex/skills/claude-code-handoff-plugin-installer
```

安装后重启 Codex，或新开一个 thread。然后可以这样触发：

```text
$devspace-mcp-setup
$defining-goals
$designing-loops
$claude-code-handoff-plugin-installer
```

### Claude Code

把下面这段话发给 Claude Code：

```text
请从 https://github.com/WebXuHao/skills 安装这些 skill：
- skills/devspace-mcp-setup
- skills/defining-goals
- skills/designing-loops
- skills/claude-code-handoff-plugin-installer

安装到 ~/.claude/skills。如果当前环境使用其他 skills 目录，请先告诉我目标目录，再复制。
```

等价手动命令：

```bash
mkdir -p ~/.claude/skills
git clone https://github.com/WebXuHao/skills.git /tmp/webxuhao-skills
cp -R /tmp/webxuhao-skills/skills/devspace-mcp-setup ~/.claude/skills/devspace-mcp-setup
cp -R /tmp/webxuhao-skills/skills/defining-goals ~/.claude/skills/defining-goals
cp -R /tmp/webxuhao-skills/skills/designing-loops ~/.claude/skills/designing-loops
cp -R /tmp/webxuhao-skills/skills/claude-code-handoff-plugin-installer ~/.claude/skills/claude-code-handoff-plugin-installer
```

## 仓库结构

```text
skills/
  devspace-mcp-setup/
    SKILL.md
    agents/openai.yaml
    scripts/devspace_mcp_smoke.mjs
  defining-goals/
    SKILL.md
    agents/openai.yaml
  designing-loops/
    SKILL.md
    agents/openai.yaml
  claude-code-handoff-plugin-installer/
    SKILL.md
    agents/openai.yaml
    scripts/install_claude_code_handoff_plugin.sh
    references/claude-code-handoff-marketplace/
```

## 使用建议

先用 `$defining-goals` 把目标定义清楚，再用 `$designing-loops` 设计自动循环。

不要在目标仍然模糊时启动 loop。Loop 会放大目标定义的质量：目标越清楚，自动化越可靠；目标越含糊，loop 跑得越快，偏得也越快。
