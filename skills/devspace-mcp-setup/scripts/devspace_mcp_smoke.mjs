#!/usr/bin/env node
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { createHash, randomBytes } from "node:crypto";
import { execFileSync } from "node:child_process";

function usage() {
  console.log(`Usage:
  devspace_mcp_smoke.mjs --url <https://host/mcp> --workspace <abs-path> --path <relative-file> [--expect <text>]

Options:
  --url               Public DevSpace MCP URL, including /mcp.
  --workspace         Absolute workspace path inside DevSpace allowedRoots.
  --path              File path to read, relative to workspace root.
  --expect            Optional text expected in the read result.
  --owner-token-file  Defaults to ~/.devspace/auth.json.

Environment:
  DEVSPACE_OWNER_TOKEN  Owner password. If omitted, owner-token-file is used.
`);
}

function parseArgs(argv) {
  const out = { ownerTokenFile: join(homedir(), ".devspace", "auth.json") };
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--help" || arg === "-h") {
      out.help = true;
    } else if (arg === "--url") {
      out.url = argv[++index];
    } else if (arg === "--workspace") {
      out.workspace = argv[++index];
    } else if (arg === "--path") {
      out.path = argv[++index];
    } else if (arg === "--expect") {
      out.expect = argv[++index];
    } else if (arg === "--owner-token-file") {
      out.ownerTokenFile = argv[++index];
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return out;
}

function base64url(buffer) {
  return Buffer.from(buffer).toString("base64url");
}

function form(data) {
  return new URLSearchParams(
    Object.entries(data).filter(([, value]) => value !== undefined),
  );
}

async function fetchJson(url, options = {}) {
  const response = await fetch(url, options);
  const text = await response.text();
  if (!response.ok) {
    throw new Error(`${options.method ?? "GET"} ${url} failed ${response.status}: ${text.slice(0, 500)}`);
  }
  return text ? JSON.parse(text) : {};
}

async function readOwnerToken(filePath) {
  if (process.env.DEVSPACE_OWNER_TOKEN) {
    return process.env.DEVSPACE_OWNER_TOKEN;
  }
  const auth = JSON.parse(await readFile(filePath, "utf8"));
  if (!auth.ownerToken) {
    throw new Error(`Missing ownerToken in ${filePath}`);
  }
  return auth.ownerToken;
}

function resolveSdkImports() {
  const npmRoot = execFileSync("npm", ["root", "-g"], { encoding: "utf8" }).trim();
  const sdkRoot = join(npmRoot, "@waishnav", "devspace", "node_modules", "@modelcontextprotocol", "sdk", "dist", "esm");
  return {
    client: pathToFileURL(join(sdkRoot, "client", "index.js")).href,
    streamableHttp: pathToFileURL(join(sdkRoot, "client", "streamableHttp.js")).href,
  };
}

async function getAccessToken({ mcpUrl, ownerToken }) {
  const url = new URL(mcpUrl);
  const baseUrl = `${url.origin}`;
  const redirectUri = "http://127.0.0.1/callback";
  const metadata = await fetchJson(`${baseUrl}/.well-known/oauth-authorization-server`);
  const registered = await fetchJson(metadata.registration_endpoint, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      client_name: "devspace-mcp-smoke",
      redirect_uris: [redirectUri],
      token_endpoint_auth_method: "none",
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      scope: "devspace",
    }),
  });

  const codeVerifier = base64url(randomBytes(32));
  const codeChallenge = base64url(createHash("sha256").update(codeVerifier).digest());
  const state = base64url(randomBytes(12));
  const authorizeResponse = await fetch(metadata.authorization_endpoint, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    redirect: "manual",
    body: form({
      response_type: "code",
      client_id: registered.client_id,
      redirect_uri: redirectUri,
      code_challenge: codeChallenge,
      code_challenge_method: "S256",
      scope: "devspace",
      state,
      resource: mcpUrl,
      owner_token: ownerToken,
    }),
  });

  if (authorizeResponse.status !== 302) {
    const text = await authorizeResponse.text();
    throw new Error(`authorize failed ${authorizeResponse.status}: ${text.slice(0, 500)}`);
  }

  const callbackUrl = new URL(authorizeResponse.headers.get("location"));
  if (callbackUrl.searchParams.get("state") !== state) {
    throw new Error("OAuth state mismatch");
  }
  const code = callbackUrl.searchParams.get("code");
  if (!code) {
    throw new Error("Missing authorization code");
  }

  return fetchJson(metadata.token_endpoint, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: form({
      grant_type: "authorization_code",
      client_id: registered.client_id,
      code,
      redirect_uri: redirectUri,
      code_verifier: codeVerifier,
      resource: mcpUrl,
    }),
  });
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    usage();
    return;
  }
  for (const key of ["url", "workspace", "path"]) {
    if (!args[key]) {
      usage();
      throw new Error(`Missing required option --${key}`);
    }
  }

  const imports = resolveSdkImports();
  const [{ Client }, { StreamableHTTPClientTransport }] = await Promise.all([
    import(imports.client),
    import(imports.streamableHttp),
  ]);

  const ownerToken = await readOwnerToken(args.ownerTokenFile);
  const tokens = await getAccessToken({ mcpUrl: args.url, ownerToken });
  const authProvider = { async tokens() { return tokens; } };
  const transport = new StreamableHTTPClientTransport(new URL(args.url), { authProvider });
  const client = new Client({ name: "devspace-mcp-smoke", version: "1.0.0" }, { capabilities: {} });

  await client.connect(transport);
  const listed = await client.listTools();
  const openResult = await client.callTool({
    name: "open_workspace",
    arguments: { path: args.workspace, mode: "checkout" },
  });
  const workspaceId = openResult.structuredContent?.workspaceId;
  if (!workspaceId) {
    throw new Error("open_workspace did not return workspaceId");
  }
  const readResult = await client.callTool({
    name: "read",
    arguments: { workspaceId, path: args.path },
  });
  await transport.close();

  const readText = String(
    readResult.structuredContent?.result ??
    readResult.content?.map((item) => item.text).join("\n") ??
    "",
  );
  const markerSeen = args.expect ? readText.includes(args.expect) : readText.length > 0;

  console.log(JSON.stringify({
    ok: markerSeen,
    endpoint: args.url,
    tools: listed.tools.map((tool) => tool.name),
    workspaceId,
    readPath: args.path,
    markerSeen,
  }, null, 2));

  if (!markerSeen) {
    process.exitCode = 2;
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
