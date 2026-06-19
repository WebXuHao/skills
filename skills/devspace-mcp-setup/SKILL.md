---
name: devspace-mcp-setup
description: 当需要安装、配置、暴露、连接或验证 @waishnav/devspace MCP server，让 ChatGPT 或其他 MCP client 通过 Cloudflare/公网 HTTPS 调用本机 workspace 工具时使用。
---

# DevSpace MCP Setup

## 适用场景

使用本 skill 帮用户把 `@waishnav/devspace` 从零安装到可验证状态。目标不是只让服务启动，而是证明 MCP client 能通过真实协议完成 `tools/list`、`open_workspace` 和 `read`。

典型触发：

- 用户要把 ChatGPT 连接到本机项目目录。
- 用户要用 Cloudflare tunnel 或自有域名暴露 DevSpace MCP。
- 用户说 DevSpace App 显示异常，需要判断 UI 问题还是协议问题。
- 用户要做只读 smoke test，避免先开放写文件或 shell。
- 用户要检查 DevSpace 安全边界，例如 `allowedRoots`、owner password、`bash` 风险。

## 安全边界

DevSpace 可能暴露 `write`、`edit` 和 `bash`。把它当成 shell-capable 本机入口处理。

必须遵守：

- 不要打印、粘贴、提交 `~/.devspace/auth.json` 里的 owner password。
- `allowedRoots` 只允许必要项目目录。
- 先跑只读验证，再考虑 `write`、`edit`、`bash`。
- 长期公网 endpoint 使用自有域名、HTTPS 和额外访问控制。
- 不把随机 `trycloudflare.com` 临时 URL 当长期入口。
- 证据以 MCP 协议调用结果和 DevSpace server log 为准，ChatGPT UI app chip 只能作辅助参考。

## 安装流程

1. 安装 CLI。

```bash
npm install -g @waishnav/devspace
npm install -g cloudflared
```

2. 初始化 DevSpace。

```bash
devspace init
devspace doctor
```

3. 检查配置。

```bash
devspace config get
```

确认：

- `allowedRoots` 指向要开放给 MCP client 的项目目录。
- `publicBaseUrl` 是公网 HTTPS base URL，不包含 `/mcp`。

4. 本地启动并检查。

```bash
devspace serve
curl http://127.0.0.1:7676/healthz
```

5. 暴露公网入口。

## Cloudflare 转发流程

DevSpace 的本地服务默认监听 `http://127.0.0.1:7676`。Cloudflare 只负责把一个公网 HTTPS hostname 转发到这个本地地址。这里有两条路径：

- quick tunnel：最快拿到临时公网地址，适合首次 smoke test。
- named tunnel + 自有域名：适合长期使用，推荐用于 ChatGPT 或其他 MCP client 的固定配置。

### 路径 A：quick tunnel 临时公网地址

临时验证可用 quick tunnel。它会生成一个随机 `trycloudflare.com` 地址：

```bash
cloudflared tunnel --url http://127.0.0.1:7676
```

拿到地址后，把 DevSpace 的 public base URL 设置为该地址，不包含 `/mcp`：

```bash
devspace config set publicBaseUrl https://example.trycloudflare.com
```

MCP client 使用的最终 endpoint 是：

```text
https://example.trycloudflare.com/mcp
```

quick tunnel 的缺点是 URL 会变，适合临时验证，不适合长期写进 ChatGPT App 或团队配置。

### 路径 B：named tunnel + 自有域名

长期方案用 Cloudflare 账号下的 named tunnel，把自己的子域名转发到本机 DevSpace。

先登录 Cloudflare：

```bash
cloudflared tunnel login
```

创建 tunnel：

```bash
cloudflared tunnel create devspace
```

把子域名路由到 tunnel：

```bash
cloudflared tunnel route dns devspace devspace.example.com
```

创建 `~/.cloudflared/config.yml`，把公网 hostname 指向本机 DevSpace：

```yaml
tunnel: devspace
credentials-file: /Users/you/.cloudflared/<tunnel-id>.json

ingress:
  - hostname: devspace.example.com
    service: http://127.0.0.1:7676
  - service: http_status:404
```

启动 tunnel：

```bash
cloudflared tunnel run devspace
```

设置 DevSpace public base URL：

```bash
devspace config set publicBaseUrl https://devspace.example.com
```

MCP client 使用：

```text
https://devspace.example.com/mcp
```

如果用户已有自己的域名，优先走 named tunnel。配置成功后再考虑加 Cloudflare Access 或其他访问控制，尤其是在 DevSpace 暴露 `bash` 时。

## 验证流程

优先做协议层验证，不要只看网页 UI。

1. 准备 marker 文件。

```bash
mkdir -p adhoc_jobs/devspace_mcp_smoke
printf 'Marker: DEVSPACE_MCP_SMOKE_%s\n' "$(date +%Y%m%d%H%M%S)" > adhoc_jobs/devspace_mcp_smoke/task_input.md
```

2. 使用内置脚本跑 MCP smoke。

```bash
node ~/.codex/skills/devspace-mcp-setup/scripts/devspace_mcp_smoke.mjs \
  --url https://devspace.example.com/mcp \
  --workspace /absolute/path/to/project \
  --path adhoc_jobs/devspace_mcp_smoke/task_input.md \
  --expect DEVSPACE_MCP_SMOKE
```

默认从 `~/.devspace/auth.json` 读取 `ownerToken`。也可以用环境变量：

```bash
DEVSPACE_OWNER_TOKEN='...' node ~/.codex/skills/devspace-mcp-setup/scripts/devspace_mcp_smoke.mjs ...
```

3. 检查输出。

成功输出应包含：

```json
{
  "ok": true,
  "tools": ["open_workspace", "read", "..."],
  "markerSeen": true
}
```

4. 检查 DevSpace 日志。

```bash
tail -n 40 ~/.devspace/logs/launchd.out.log
```

应看到：

```text
tool_call open_workspace ... success:true
tool_call read ... success:true
```

## 判断结果

- 本地 `/healthz` 成功：只证明本地服务活着。
- 公网 `/healthz` 成功：证明 tunnel/DNS/HTTPS 到本地通。
- OAuth 成功：证明授权链路通。
- `tools/list` 成功：证明 MCP capability 暴露成功。
- `open_workspace/read` 成功并读到 marker：证明工具真实执行。
- server log 出现 `tool_call`：证明调用经过 DevSpace server。

只有最后三项成立，才算 MCP 调通。

## 常见问题

### ChatGPT UI 显示点击以重试

先不要下结论。检查 tool call card 和 DevSpace server log。UI chip 可能滞后或显示异常，协议调用结果和 server log 更可靠。

### 401 Unauthorized

通常是 OAuth token 缺失、过期、resource 不匹配，或 owner password 没通过授权。重新跑 OAuth flow 或直接用 smoke 脚本验证。

### `allowedRoots` 拒绝 workspace

把 workspace 放进 `~/.devspace/config.json` 的 `allowedRoots`，再重启 DevSpace。

### 只想给 ChatGPT 读文件

DevSpace 默认会暴露更多工具。更保守的做法是额外部署只读 adapter，或在网络/身份层限制可访问 client。

## 完成标准

汇报完成时必须说明：

- DevSpace endpoint。
- `devspace config get` 的非敏感摘要。
- `tools/list` 返回的工具名。
- `open_workspace` 返回的 workspaceId。
- `read` 读取到的 marker 或目标文件摘要。
- DevSpace server log 中对应的 `tool_call` 证据。

不要把 owner password、access token 或完整私密日志写进最终回复。
