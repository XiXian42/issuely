"use strict";

const fs = require("fs");
const path = require("path");

const DEFAULTS = Object.freeze({
  workspace: "workspace",
  roles: Object.freeze({
    planner: Object.freeze({ agent: "pi", model: null, thinking: null }),
    dev: Object.freeze({ agent: "pi", model: "openai-codex/gpt-5.5", thinking: null }),
    review: Object.freeze({ agent: "pi", model: "openrouter/anthropic/claude-sonnet-4.6", thinking: null })
  }),
  agents: Object.freeze({
    pi: Object.freeze({ tools: "", trace: 1 }),
    omp: Object.freeze({ tools: "", trace: 1 }),
    claude: Object.freeze({ permissionMode: "auto", trace: 1 }),
    codex: Object.freeze({ sandbox: "", approval: "", trace: 1 })
  })
});

const ROLE_NAMES = ["planner", "dev", "review"];
const AGENT_NAMES = ["pi", "omp", "claude", "codex"];

function realpath(p) {
  try {
    return fs.realpathSync(p);
  } catch (_) {
    return path.resolve(p);
  }
}

function clone(value) {
  return value == null ? value : JSON.parse(JSON.stringify(value));
}

function deepMerge(base, override) {
  if (override === undefined) return base;
  if (Array.isArray(base) || Array.isArray(override)) return clone(override);
  if (!isObject(base) || !isObject(override)) return clone(override);
  const merged = { ...base };
  for (const [key, value] of Object.entries(override)) {
    merged[key] = key in merged ? deepMerge(merged[key], value) : clone(value);
  }
  return merged;
}

function isObject(value) {
  return value && typeof value === "object" && !Array.isArray(value);
}

function ensureProjectDir(explicit) {
  const root = explicit || process.env.ISSUELY_PROJECT_DIR;
  if (!root) {
    throw new Error("ISSUELY_PROJECT_DIR is not set; cannot locate project config");
  }
  if (!fs.existsSync(root)) {
    throw new Error(`ISSUELY_PROJECT_DIR does not exist: ${root}`);
  }
  return realpath(root);
}

function globalConfigHome(explicit) {
  const home = explicit || process.env.ISSUELY_HOME || (process.env.HOME ? path.join(process.env.HOME, ".issuely") : null);
  if (!home) {
    throw new Error("HOME is not set; cannot determine ~/.issuely config directory");
  }
  return path.resolve(home);
}

function globalConfigPath(explicitHome) {
  return path.join(globalConfigHome(explicitHome), "config.json");
}

function readJsonFile(filePath) {
  if (!filePath || !fs.existsSync(filePath)) return {};
  try {
    return JSON.parse(fs.readFileSync(filePath, "utf8"));
  } catch (e) {
    throw new Error(`failed to parse ${filePath}: ${e.message}`);
  }
}

function readProjectConfigFile(projectDir) {
  return readJsonFile(path.join(projectDir, "config.json"));
}

function resolveWithin(projectDir, p) {
  if (!p) return null;
  return path.isAbsolute(p) ? p : path.resolve(projectDir, p);
}

function normalizeRel(p) {
  return String(p || "").replace(/\\/g, "/");
}

function relativeToProject(projectDir, target) {
  const rel = path.relative(projectDir, target);
  return normalizeRel(rel || ".");
}

function assertWorkspaceInsideProject(projectDir, workspaceAbs) {
  const projectReal = realpath(projectDir);
  const workspaceResolved = path.resolve(workspaceAbs);

  function assertInside(candidate) {
    const rel = path.relative(projectReal, candidate);
    if (!rel || rel === "." || rel.startsWith("..") || path.isAbsolute(rel)) {
      throw new Error(`unsafe workspace path: ${workspaceAbs}; workspace must be inside project dir and not the project dir itself`);
    }
  }

  assertInside(workspaceResolved);
  if (fs.existsSync(workspaceResolved)) {
    assertInside(realpath(workspaceResolved));
  }
  return workspaceResolved;
}

function normalizeRoleConfig(value) {
  if (!isObject(value)) return {};
  const out = {};
  if (value.agent !== undefined) out.agent = String(value.agent || "").trim() || null;
  if (value.model !== undefined) out.model = value.model == null ? null : String(value.model);
  if (value.thinking !== undefined) out.thinking = value.thinking == null ? null : String(value.thinking);
  return out;
}

function normalizeAgentConfig(name, value) {
  if (!isObject(value)) return {};
  switch (name) {
    case "pi": {
      const out = {};
      if (value.tools !== undefined) out.tools = Array.isArray(value.tools) ? value.tools.join(",") : String(value.tools || "");
      if (value.trace !== undefined) out.trace = Number(value.trace);
      if (value.piTrace !== undefined) out.trace = Number(value.piTrace);
      return out;
    }
    case "omp": {
      const out = {};
      if (value.tools !== undefined) out.tools = Array.isArray(value.tools) ? value.tools.join(",") : String(value.tools || "");
      if (value.trace !== undefined) out.trace = Number(value.trace);
      return out;
    }
    case "claude": {
      const out = {};
      if (value.permissionMode !== undefined) {
        const permissionMode = value.permissionMode == null ? "" : String(value.permissionMode).trim();
        if (permissionMode) out.permissionMode = permissionMode;
      }
      if (value.trace !== undefined) out.trace = Number(value.trace);
      return out;
    }
    case "codex": {
      const out = {};
      if (value.sandbox !== undefined) out.sandbox = value.sandbox == null ? null : String(value.sandbox);
      if (value.approval !== undefined) out.approval = value.approval == null ? null : String(value.approval);
      if (value.trace !== undefined) out.trace = Number(value.trace);
      return out;
    }
    default:
      return {};
  }
}

function normalizeConfig(raw) {
  if (!isObject(raw)) return {};
  const out = {};
  if (raw.version !== undefined) out.version = raw.version;
  if (raw.projectName !== undefined) out.projectName = raw.projectName;
  if (raw.workspace !== undefined) out.workspace = raw.workspace;
  if (raw.language !== undefined) out.language = raw.language;
  if (raw.originalRequirement !== undefined) out.originalRequirement = raw.originalRequirement;

  const roles = {};
  if (isObject(raw.roles)) {
    for (const role of ROLE_NAMES) {
      if (raw.roles[role] !== undefined) roles[role] = normalizeRoleConfig(raw.roles[role]);
    }
  }
  if (isObject(raw.models)) {
    for (const role of ROLE_NAMES) {
      if (raw.models[role] !== undefined) {
        roles[role] = deepMerge(roles[role] || {}, { model: raw.models[role] == null ? null : String(raw.models[role]) });
      }
    }
  }
  if (isObject(raw.thinking)) {
    for (const role of ROLE_NAMES) {
      if (raw.thinking[role] !== undefined) {
        roles[role] = deepMerge(roles[role] || {}, { thinking: raw.thinking[role] == null ? null : String(raw.thinking[role]) });
      }
    }
  }
  if (Object.keys(roles).length > 0) out.roles = roles;

  const agents = {};
  if (isObject(raw.agents)) {
    for (const agent of AGENT_NAMES) {
      if (raw.agents[agent] !== undefined) agents[agent] = normalizeAgentConfig(agent, raw.agents[agent]);
    }
  }
  if (raw.tools !== undefined || raw.piTrace !== undefined) {
    agents.pi = deepMerge(agents.pi || {}, {
      ...(raw.tools !== undefined ? { tools: Array.isArray(raw.tools) ? raw.tools.join(",") : String(raw.tools || "") } : {}),
      ...(raw.piTrace !== undefined ? { trace: Number(raw.piTrace) } : {})
    });
  }
  if (Object.keys(agents).length > 0) out.agents = agents;

  return out;
}

function normalizeRoles(roles) {
  const defaults = clone(DEFAULTS.roles);
  const merged = deepMerge(defaults, roles || {});
  for (const role of ROLE_NAMES) {
    if (!merged[role].agent) merged[role].agent = defaults[role].agent;
  }
  return merged;
}

function normalizeAgents(agents) {
  const defaults = clone(DEFAULTS.agents);
  const merged = deepMerge(defaults, agents || {});
  for (const agent of ["pi", "omp", "claude", "codex"]) {
    if (merged[agent].trace == null || Number.isNaN(Number(merged[agent].trace))) merged[agent].trace = defaults[agent].trace;
    merged[agent].trace = Number(merged[agent].trace);
  }
  if (merged.pi.tools == null) merged.pi.tools = "";
  if (merged.omp.tools == null) merged.omp.tools = "";
  return merged;
}

function loadConfig(opts = {}) {
  const projectDir = ensureProjectDir(opts.projectDir);
  const projectConfigPath = path.join(projectDir, "config.json");
  const globalPath = globalConfigPath(opts.homeDir);
  const globalRaw = readJsonFile(globalPath);
  const projectRaw = readProjectConfigFile(projectDir);
  const merged = deepMerge(deepMerge(clone(DEFAULTS), normalizeConfig(globalRaw)), normalizeConfig(projectRaw));

  const projectName = projectRaw.projectName || merged.projectName || path.basename(projectDir);
  const language = projectRaw.language || merged.language || "unspecified";
  const originalRequirement = projectRaw.originalRequirement || merged.originalRequirement || "";

  const workspaceRelConfigured = merged.workspace || DEFAULTS.workspace;
  const workspaceAbs = assertWorkspaceInsideProject(projectDir, resolveWithin(projectDir, workspaceRelConfigured));
  const workspaceRel = relativeToProject(projectDir, workspaceAbs);

  let metaDir = opts.metaDir || process.env.ISSUELY_META_DIR;
  if (!metaDir) {
    const local = path.join(projectDir, ".issuely");
    if (fs.existsSync(local)) metaDir = local;
  }
  if (!metaDir) {
    throw new Error("Cannot locate .issuely (set ISSUELY_META_DIR or place .issuely under project root)");
  }
  metaDir = realpath(metaDir);

  const hasProjectMetaDir = fs.existsSync(path.join(projectDir, ".issuely"));
  const metaDirRef = hasProjectMetaDir ? ".issuely" : metaDir;

  const roles = normalizeRoles(merged.roles);
  const agents = normalizeAgents(merged.agents);

  return {
    projectDir,
    projectConfigPath,
    projectConfigExists: fs.existsSync(projectConfigPath),
    globalConfigDir: path.dirname(globalPath),
    globalConfigPath: globalPath,
    globalConfigExists: fs.existsSync(globalPath),
    metaDir,
    metaDirRef,
    projectName,
    language,
    originalRequirement,
    workspace: workspaceAbs,
    workspaceRel,
    issuesDir: path.join(workspaceAbs, "issues"),
    issuesDirRel: normalizeRel(path.join(workspaceRel, "issues")),
    docsDir: path.join(workspaceAbs, "docs"),
    docsDirRel: normalizeRel(path.join(workspaceRel, "docs")),
    statusPath: path.join(workspaceAbs, "status.md"),
    statusPathRel: normalizeRel(path.join(workspaceRel, "status.md")),
    memoPath: path.join(workspaceAbs, "memo.md"),
    memoPathRel: normalizeRel(path.join(workspaceRel, "memo.md")),
    devDone: path.join(workspaceAbs, "dev.done"),
    devDoneRel: normalizeRel(path.join(workspaceRel, "dev.done")),
    reviewDone: path.join(workspaceAbs, "review.done"),
    reviewDoneRel: normalizeRel(path.join(workspaceRel, "review.done")),
    logDir: path.join(workspaceAbs, "logs"),
    logDirRel: normalizeRel(path.join(workspaceRel, "logs")),
    roles,
    agents,
    models: {
      planner: roles.planner.model,
      dev: roles.dev.model,
      review: roles.review.model
    },
    thinking: {
      planner: roles.planner.thinking,
      dev: roles.dev.thinking,
      review: roles.review.thinking
    },
    tools: agents.pi.tools || "",
    piTrace: agents.pi.trace
  };
}

function ensureDir(filePath) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
}

function writeJson(target, value) {
  ensureDir(target);
  fs.writeFileSync(target, JSON.stringify(value, null, 2) + "\n", "utf8");
}

function writeConfig(projectDir, partial) {
  const target = path.join(projectDir, "config.json");
  const existing = readJsonFile(target);
  const merged = deepMerge(existing, partial);
  if (merged.workspace) {
    const abs = assertWorkspaceInsideProject(
      projectDir,
      path.isAbsolute(merged.workspace) ? merged.workspace : path.resolve(projectDir, merged.workspace)
    );
    merged.workspace = relativeToProject(projectDir, abs);
  } else {
    merged.workspace = DEFAULTS.workspace;
  }
  writeJson(target, merged);
  return target;
}

function writeGlobalConfig(partial, opts = {}) {
  const target = globalConfigPath(opts.homeDir);
  const existing = readJsonFile(target);
  const merged = deepMerge(existing, partial);
  writeJson(target, merged);
  return target;
}

function globalConfigView(opts = {}) {
  const target = globalConfigPath(opts.homeDir);
  const raw = readJsonFile(target);
  return {
    path: target,
    exists: fs.existsSync(target),
    config: deepMerge(clone(DEFAULTS), normalizeConfig(raw))
  };
}

function toShellEnv(view) {
  const sq = (v) => `'${String(v == null ? "" : v).replace(/'/g, "'\\''")}'`;
  const lines = [
    `ISSUELY_PROJECT_DIR=${sq(view.projectDir)}`,
    `ISSUELY_HOME=${sq(view.globalConfigDir)}`,
    `ISSUELY_GLOBAL_CONFIG=${sq(view.globalConfigPath)}`,
    `META_DIR=${sq(view.metaDir)}`,
    `META_DIR_REF=${sq(view.metaDirRef)}`,
    `PROJECT_NAME=${sq(view.projectName)}`,
    `LANGUAGE=${sq(view.language)}`,
    `WORKSPACE=${sq(view.workspace)}`,
    `WORKSPACE_REL=${sq(view.workspaceRel)}`,
    `ISSUES_DIR=${sq(view.issuesDir)}`,
    `ISSUES_DIR_REL=${sq(view.issuesDirRel)}`,
    `DOCS_DIR=${sq(view.docsDir)}`,
    `DOCS_DIR_REL=${sq(view.docsDirRel)}`,
    `STATUS_PATH=${sq(view.statusPath)}`,
    `STATUS_PATH_REL=${sq(view.statusPathRel)}`,
    `MEMO_PATH=${sq(view.memoPath)}`,
    `MEMO_PATH_REL=${sq(view.memoPathRel)}`,
    `DEV_DONE=${sq(view.devDone)}`,
    `DEV_DONE_REL=${sq(view.devDoneRel)}`,
    `REVIEW_DONE=${sq(view.reviewDone)}`,
    `REVIEW_DONE_REL=${sq(view.reviewDoneRel)}`,
    `LOG_DIR=${sq(view.logDir)}`,
    `LOG_DIR_REL=${sq(view.logDirRel)}`,
    `PLANNER_AGENT=${sq(view.roles.planner.agent)}`,
    `PLANNER_MODEL=${sq(view.roles.planner.model || "")}`,
    `PLANNER_THINKING=${sq(view.roles.planner.thinking || "")}`,
    `DEV_AGENT=${sq(view.roles.dev.agent)}`,
    `DEV_MODEL=${sq(view.roles.dev.model || "")}`,
    `DEV_THINKING=${sq(view.roles.dev.thinking || "")}`,
    `REVIEW_AGENT=${sq(view.roles.review.agent)}`,
    `REVIEW_MODEL=${sq(view.roles.review.model || "")}`,
    `REVIEW_THINKING=${sq(view.roles.review.thinking || "")}`,
    `PI_TOOLS=${sq(view.agents.pi.tools || "")}`,
    `PI_TRACE=${sq(view.agents.pi.trace)}`,
    `OMP_TOOLS=${sq(view.agents.omp.tools || "")}`,
    `OMP_TRACE=${sq(view.agents.omp.trace)}`,
    `CLAUDE_PERMISSION_MODE=${sq(view.agents.claude.permissionMode || "")}`,
    `CLAUDE_TRACE=${sq(view.agents.claude.trace)}`,
    `CODEX_SANDBOX=${sq(view.agents.codex.sandbox || "")}`,
    `CODEX_APPROVAL=${sq(view.agents.codex.approval || "")}`,
    `CODEX_TRACE=${sq(view.agents.codex.trace)}`
  ];
  return lines.join("\n") + "\nexport ISSUELY_PROJECT_DIR ISSUELY_HOME ISSUELY_GLOBAL_CONFIG META_DIR META_DIR_REF PROJECT_NAME LANGUAGE WORKSPACE WORKSPACE_REL ISSUES_DIR ISSUES_DIR_REL DOCS_DIR DOCS_DIR_REL STATUS_PATH STATUS_PATH_REL MEMO_PATH MEMO_PATH_REL DEV_DONE DEV_DONE_REL REVIEW_DONE REVIEW_DONE_REL LOG_DIR LOG_DIR_REL PLANNER_AGENT PLANNER_MODEL PLANNER_THINKING DEV_AGENT DEV_MODEL DEV_THINKING REVIEW_AGENT REVIEW_MODEL REVIEW_THINKING PI_TOOLS PI_TRACE OMP_TOOLS OMP_TRACE CLAUDE_PERMISSION_MODE CLAUDE_TRACE CODEX_SANDBOX CODEX_APPROVAL CODEX_TRACE\n";
}

function cli(argv) {
  const [cmd, ...rest] = argv;
  function parseFlags(arr) {
    const out = {};
    for (let i = 0; i < arr.length; i++) {
      const t = arr[i];
      if (!t.startsWith("--")) continue;
      const k = t.slice(2);
      const v = arr[i + 1];
      if (v === undefined || v.startsWith("--")) out[k] = true;
      else {
        out[k] = v;
        i++;
      }
    }
    return out;
  }

  if (cmd === "global-path") {
    process.stdout.write(globalConfigPath() + "\n");
    return;
  }
  if (cmd === "show-global") {
    process.stdout.write(JSON.stringify(globalConfigView(), null, 2) + "\n");
    return;
  }
  if (cmd === "print-shell") {
    const view = loadConfig();
    process.stdout.write(toShellEnv(view));
    return;
  }
  if (cmd === "show") {
    const view = loadConfig();
    process.stdout.write(JSON.stringify(view, null, 2) + "\n");
    return;
  }
  if (cmd === "write") {
    const flags = parseFlags(rest);
    const projectDir = ensureProjectDir(flags["project-dir"]);
    const partial = {};
    if (flags["project-name"]) partial.projectName = flags["project-name"];
    if (flags["language"]) partial.language = flags["language"];
    if (flags["workspace"]) partial.workspace = flags["workspace"];
    if (flags["original-requirement"] !== undefined) partial.originalRequirement = flags["original-requirement"];
    if (flags["original-requirement-from-env"]) partial.originalRequirement = process.env[flags["original-requirement-from-env"]] || "";
    const target = writeConfig(projectDir, partial);
    process.stdout.write(target + "\n");
    return;
  }
  if (cmd === "write-global") {
    const flags = parseFlags(rest);
    let partial = {};
    if (flags["config-json"]) partial = JSON.parse(flags["config-json"]);
    if (flags["config-json-from-env"]) partial = JSON.parse(process.env[flags["config-json-from-env"]] || "{}");
    const target = writeGlobalConfig(partial, { homeDir: flags.home });
    process.stdout.write(target + "\n");
    return;
  }
  process.stderr.write(
    "Usage: config.cjs global-path | show-global | print-shell | show | write [--project-dir DIR] [--project-name N] [--language L] [--workspace W] [--original-requirement-from-env VAR] | write-global [--config-json JSON|--config-json-from-env VAR]\n"
  );
  process.exit(2);
}

if (require.main === module) {
  try {
    cli(process.argv.slice(2));
  } catch (e) {
    process.stderr.write(`[issuely-config] ${e.message}\n`);
    process.exit(1);
  }
}

module.exports = {
  DEFAULTS,
  ROLE_NAMES,
  AGENT_NAMES,
  loadConfig,
  writeConfig,
  writeGlobalConfig,
  globalConfigHome,
  globalConfigPath,
  globalConfigView,
  normalizeConfig,
  toShellEnv,
  deepMerge
};
