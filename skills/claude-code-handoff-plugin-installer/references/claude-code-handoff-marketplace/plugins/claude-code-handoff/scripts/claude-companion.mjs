#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import process from "node:process";
import { spawn, spawnSync } from "node:child_process";

const SCRIPT_DIR = path.resolve(new URL(".", import.meta.url).pathname);
const ROOT_DIR = path.resolve(SCRIPT_DIR, "..");
const HANDOFF_SCRIPT_CANDIDATES = [
  // Standalone skill layout:
  //   claude-code-handoff/scripts/claude-companion.mjs
  //   claude-code-handoff/scripts/claude_handoff.sh
  path.join(SCRIPT_DIR, "claude_handoff.sh"),
  // Codex plugin layout:
  //   claude-code-handoff/scripts/claude-companion.mjs
  //   claude-code-handoff/skills/claude-code-handoff/scripts/claude_handoff.sh
  path.join(ROOT_DIR, "skills", "claude-code-handoff", "scripts", "claude_handoff.sh")
];
const HANDOFF_SCRIPT = HANDOFF_SCRIPT_CANDIDATES.find((candidate) => fs.existsSync(candidate)) ?? HANDOFF_SCRIPT_CANDIDATES[0];
const STATE_ROOT = path.join(os.homedir(), ".codex", "claude-companion", "state");
const MAX_JOBS = 80;

function usage() {
  console.log(`Usage:
  claude-companion.mjs inspect --repo <path> [--background]
  claude-companion.mjs review --repo <path> --base <ref> --prompt <file> [--background]
  claude-companion.mjs task --repo <path> --mode read-only|write --prompt <file> [--background]
  claude-companion.mjs scenario <preset> --repo <path> [--base <ref>] [--prompt <file>] [--background]
  claude-companion.mjs status [job-id] [--all] [--json]
  claude-companion.mjs result [job-id] [--json]
  claude-companion.mjs cancel [job-id] [--json]`);
}

function nowIso() {
  return new Date().toISOString();
}

function parseArgs(argv) {
  const out = { positionals: [], options: {} };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (!arg.startsWith("--")) {
      out.positionals.push(arg);
      continue;
    }
    const key = arg.slice(2);
    if (["background", "json", "all"].includes(key)) {
      out.options[key] = true;
      continue;
    }
    if (i + 1 >= argv.length) {
      throw new Error(`Missing value for ${arg}`);
    }
    out.options[key] = argv[i + 1];
    i += 1;
  }
  return out;
}

function resolveRepo(options) {
  const repo = options.repo ? path.resolve(options.repo) : process.cwd();
  if (!fs.existsSync(repo) || !fs.statSync(repo).isDirectory()) {
    throw new Error(`Repo does not exist: ${repo}`);
  }
  return repo;
}

function workspaceRoot(repo) {
  const result = spawnSync("git", ["-C", repo, "rev-parse", "--show-toplevel"], {
    encoding: "utf8"
  });
  if (result.status === 0 && result.stdout.trim()) {
    return path.resolve(result.stdout.trim());
  }
  return repo;
}

function stateDirFor(repo) {
  const root = workspaceRoot(repo);
  const base = path.basename(root).replace(/[^a-zA-Z0-9._-]+/g, "-") || "workspace";
  const hash = crypto.createHash("sha256").update(root).digest("hex").slice(0, 16);
  return path.join(STATE_ROOT, `${base}-${hash}`);
}

function ensureState(repo) {
  const dir = stateDirFor(repo);
  fs.mkdirSync(path.join(dir, "jobs"), { recursive: true });
  return dir;
}

function stateFile(repo) {
  return path.join(ensureState(repo), "state.json");
}

function jobsDir(repo) {
  return path.join(ensureState(repo), "jobs");
}

function readState(repo) {
  const file = stateFile(repo);
  if (!fs.existsSync(file)) {
    return { version: 1, jobs: [] };
  }
  try {
    const parsed = JSON.parse(fs.readFileSync(file, "utf8"));
    return { version: 1, jobs: Array.isArray(parsed.jobs) ? parsed.jobs : [] };
  } catch {
    return { version: 1, jobs: [] };
  }
}

function saveState(repo, state) {
  const next = {
    version: 1,
    jobs: [...(state.jobs ?? [])]
      .sort((a, b) => String(b.updatedAt ?? "").localeCompare(String(a.updatedAt ?? "")))
      .slice(0, MAX_JOBS)
  };
  fs.writeFileSync(stateFile(repo), `${JSON.stringify(next, null, 2)}\n`, "utf8");
  return next;
}

function upsertJob(repo, patch) {
  const state = readState(repo);
  const index = state.jobs.findIndex((job) => job.id === patch.id);
  const timestamp = nowIso();
  if (index === -1) {
    state.jobs.unshift({ createdAt: timestamp, updatedAt: timestamp, ...patch });
  } else {
    state.jobs[index] = { ...state.jobs[index], ...patch, updatedAt: timestamp };
  }
  return saveState(repo, state);
}

function jobFile(repo, jobId) {
  return path.join(jobsDir(repo), `${jobId}.json`);
}

function logFile(repo, jobId) {
  return path.join(jobsDir(repo), `${jobId}.log`);
}

function writeJob(repo, job) {
  fs.writeFileSync(jobFile(repo, job.id), `${JSON.stringify(job, null, 2)}\n`, "utf8");
  upsertJob(repo, job);
}

function readJob(repo, jobId) {
  const file = jobFile(repo, jobId);
  if (!fs.existsSync(file)) {
    return null;
  }
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function generateJobId(kind) {
  return `${kind}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

function buildHandoffArgs(command, parsed) {
  const args = [command];
  if (command === "scenario") {
    const preset = parsed.positionals[0];
    if (!preset) {
      throw new Error("scenario preset is required");
    }
    args.push(preset);
  }
  for (const key of ["repo", "base", "prompt", "mode"]) {
    if (parsed.options[key]) {
      args.push(`--${key}`, parsed.options[key]);
    }
  }
  return args;
}

function parseRunOutput(stdout) {
  const out = {};
  for (const line of String(stdout ?? "").split(/\r?\n/)) {
    const match = line.match(/^([a-z_]+)=(.*)$/);
    if (match) {
      out[match[1]] = match[2];
    }
  }
  return out;
}

function readJsonIfExists(file) {
  if (!file || !fs.existsSync(file)) {
    return null;
  }
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

function runHandoff(repo, job, handoffArgs) {
  const startedAt = nowIso();
  const lf = logFile(repo, job.id);
  fs.appendFileSync(lf, `[${startedAt}] ${HANDOFF_SCRIPT} ${handoffArgs.join(" ")}\n`, "utf8");
  writeJob(repo, {
    ...job,
    status: "running",
    phase: "handoff",
    startedAt,
    pid: process.pid,
    logFile: lf
  });

  const result = spawnSync("bash", [HANDOFF_SCRIPT, ...handoffArgs], {
    cwd: repo,
    encoding: "utf8",
    env: process.env,
    maxBuffer: 20 * 1024 * 1024
  });
  fs.appendFileSync(lf, result.stdout ?? "", "utf8");
  fs.appendFileSync(lf, result.stderr ?? "", "utf8");

  const parsed = parseRunOutput(result.stdout);
  const payload = readJsonIfExists(parsed.result);
  const metadata = readJsonIfExists(parsed.run_dir ? path.join(parsed.run_dir, "metadata.json") : null);
  const completedAt = nowIso();
  const status = result.status === 0 && payload?.status !== "failed" ? "completed" : "failed";
  const nextJob = {
    ...job,
    status,
    phase: status === "completed" ? "done" : "failed",
    pid: null,
    startedAt,
    completedAt,
    exitCode: result.status ?? 1,
    signal: result.signal ?? null,
    logFile: lf,
    runDir: parsed.run_dir ?? null,
    resultPath: parsed.result ?? null,
    handoffExitCode: parsed.exit_code == null ? null : Number(parsed.exit_code),
    result: payload,
    metadata
  };
  writeJob(repo, nextJob);
  return nextJob;
}

function renderJob(job) {
  const status = job.status ?? "unknown";
  const summary = job.result?.summary ?? job.summary ?? "";
  const runDir = job.runDir ? `\nrun_dir: ${job.runDir}` : "";
  const resultPath = job.resultPath ? `\nresult: ${job.resultPath}` : "";
  return `${job.id} ${status} ${job.kind ?? ""} ${summary}${runDir}${resultPath}\n`;
}

function renderStatus(repo, asJson, all) {
  const jobs = readState(repo).jobs.filter((job) => all || job.status === "running" || job.status === "queued").slice(0, all ? 30 : 15);
  if (asJson) {
    console.log(JSON.stringify({ workspaceRoot: workspaceRoot(repo), jobs }, null, 2));
    return;
  }
  if (jobs.length === 0) {
    console.log("No Claude Code jobs found for this repository.");
    return;
  }
  console.log("| Job | Status | Kind | Summary | Follow-up |");
  console.log("| --- | --- | --- | --- | --- |");
  for (const job of jobs) {
    const summary = String(job.result?.summary ?? job.summary ?? "").replace(/\|/g, "\\|");
    console.log(`| ${job.id} | ${job.status ?? ""} | ${job.kind ?? ""} | ${summary} | result ${job.id} |`);
  }
}

function latestJob(repo) {
  return readState(repo).jobs[0] ?? null;
}

function resolveJob(repo, reference) {
  if (reference) {
    const exact = readJob(repo, reference);
    if (exact) {
      return exact;
    }
    const match = readState(repo).jobs.find((job) => job.id.startsWith(reference));
    if (match) {
      return readJob(repo, match.id) ?? match;
    }
    throw new Error(`No job found for ${reference}`);
  }
  const job = latestJob(repo);
  if (!job) {
    throw new Error("No Claude Code jobs found for this repository.");
  }
  return readJob(repo, job.id) ?? job;
}

function spawnBackground(repo, job, handoffArgs) {
  const child = spawn(process.execPath, [new URL(import.meta.url).pathname, "worker", "--repo", repo, "--job-id", job.id], {
    cwd: repo,
    detached: true,
    stdio: "ignore",
    env: process.env
  });
  child.unref();
  writeJob(repo, {
    ...job,
    status: "queued",
    phase: "queued",
    pid: child.pid ?? null,
    request: { handoffArgs }
  });
  console.log(`Claude Code job started in background: ${job.id}`);
  console.log(`Check: node ${new URL(import.meta.url).pathname} status --repo ${repo} --all`);
}

function cancelJob(repo, reference, asJson) {
  const job = resolveJob(repo, reference);
  if (job.pid) {
    try {
      process.kill(-job.pid, "SIGTERM");
    } catch {
      try {
        process.kill(job.pid, "SIGTERM");
      } catch {
        // Already gone.
      }
    }
  }
  const next = { ...job, status: "cancelled", phase: "cancelled", pid: null, completedAt: nowIso() };
  writeJob(repo, next);
  if (asJson) {
    console.log(JSON.stringify(next, null, 2));
  } else {
    console.log(`Cancelled ${next.id}`);
  }
}

async function main() {
  const [command, ...rest] = process.argv.slice(2);
  if (!command || command === "--help" || command === "-h") {
    usage();
    return;
  }

  if (command === "worker") {
    const parsed = parseArgs(rest);
    const repo = resolveRepo(parsed.options);
    const job = readJob(repo, parsed.options["job-id"]);
    if (!job?.request?.handoffArgs) {
      throw new Error("Stored job request is missing handoffArgs.");
    }
    runHandoff(repo, job, job.request.handoffArgs);
    return;
  }

  const parsed = parseArgs(rest);
  const repo = resolveRepo(parsed.options);

  if (command === "status") {
    renderStatus(repo, Boolean(parsed.options.json), Boolean(parsed.options.all));
    return;
  }
  if (command === "result") {
    const job = resolveJob(repo, parsed.positionals[0]);
    if (parsed.options.json) {
      console.log(JSON.stringify(job, null, 2));
    } else {
      process.stdout.write(renderJob(job));
      if (job.result) {
        console.log(JSON.stringify(job.result, null, 2));
      }
    }
    return;
  }
  if (command === "cancel") {
    cancelJob(repo, parsed.positionals[0], Boolean(parsed.options.json));
    return;
  }

  if (!["inspect", "review", "task", "scenario"].includes(command)) {
    throw new Error(`Unknown command: ${command}`);
  }

  const handoffArgs = buildHandoffArgs(command, parsed);
  const kind = command === "scenario" ? `scenario:${parsed.positionals[0]}` : command;
  const job = {
    id: generateJobId(command === "scenario" ? "scenario" : command),
    kind,
    title: `Claude Code ${kind}`,
    repo,
    workspaceRoot: workspaceRoot(repo),
    summary: handoffArgs.join(" ")
  };

  if (parsed.options.background) {
    spawnBackground(repo, job, handoffArgs);
    return;
  }

  const finished = runHandoff(repo, job, handoffArgs);
  process.stdout.write(renderJob(finished));
  if (finished.result) {
    console.log(JSON.stringify(finished.result, null, 2));
  }
  if (finished.status !== "completed") {
    process.exitCode = 1;
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
