"use strict";

// Issuely 配置加载器：单一事实源 (config.json) → 给 shell 脚本和 Node 工具用。
//
// 解析顺序：
//   1) 项目根 (ISSUELY_PROJECT_DIR)
//        - 必须由调用方显式提供 (start.sh export)；
//        - .issuely/ 既可以是项目内子目录，也可以是符号链接 / 全局路径。
//   2) 项目根/config.json
//        - 缺失字段用 defaults 兜底；
//        - 全部产物路径相对项目根，存绝对路径供下游使用。
//   3) 默认值 (defaults)：模型、tools、PI_TRACE 等。

const fs = require("fs");
const path = require("path");

const DEFAULTS = Object.freeze({
  workspace: "workspace",                   // 相对项目根
  models: {
    dev: "openai-codex/gpt-5.5",
    review: "openrouter/anthropic/claude-sonnet-4.6",
    planner: null                           // null = 用 pi 当前默认
  },
  // 给 pi 的 --tools 参数；空数组 = 不传 --tools (pi 默认启用 read,bash,edit,write)。
  // 用户可在 config.json 写 "tools": "read,bash,edit,write" 显式锁定。
  tools: "",
  piTrace: 1
});

function realpath(p) {
  try { return fs.realpathSync(p); } catch (_) { return path.resolve(p); }
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

function readConfigFile(projectDir) {
  const configPath = path.join(projectDir, "config.json");
  if (!fs.existsSync(configPath)) return {};
  try {
    const raw = fs.readFileSync(configPath, "utf8");
    return JSON.parse(raw);
  } catch (e) {
    throw new Error(`failed to parse ${configPath}: ${e.message}`);
  }
}

function resolveWithin(projectDir, p) {
  if (!p) return null;
  return path.isAbsolute(p) ? p : path.resolve(projectDir, p);
}

// 主入口：返回完全解析过的运行时视图。
function loadConfig(opts = {}) {
  const projectDir = ensureProjectDir(opts.projectDir);
  const file = readConfigFile(projectDir);

  const projectName = file.projectName || path.basename(projectDir);
  const language    = file.language || "unspecified";
  const originalRequirement = file.originalRequirement || "";

  // workspace 字段兼容老数据：之前的 config.json 写过绝对路径，新版要求相对路径，
  // 但绝对路径仍可读取。
  const workspaceRel = file.workspace || DEFAULTS.workspace;
  const workspaceAbs = resolveWithin(projectDir, workspaceRel);

  const models = Object.assign({}, DEFAULTS.models, file.models || {});

  // tools 字段：可以是字符串 "a,b,c" 或数组 ["a","b","c"]
  let tools = file.tools !== undefined ? file.tools : DEFAULTS.tools;
  if (Array.isArray(tools)) tools = tools.join(",");
  if (typeof tools !== "string") tools = "";

  const piTrace = file.piTrace !== undefined ? Number(file.piTrace) : DEFAULTS.piTrace;

  // metaDir = 框架代码所在目录 (.issuely)。
  // 优先环境变量 ISSUELY_META_DIR (允许 start.sh 显式指定，比如全局安装路径)；
  // 否则尝试 projectDir/.issuely。
  let metaDir = opts.metaDir || process.env.ISSUELY_META_DIR;
  if (!metaDir) {
    const local = path.join(projectDir, ".issuely");
    if (fs.existsSync(local)) metaDir = local;
  }
  if (!metaDir) {
    throw new Error("Cannot locate .issuely (set ISSUELY_META_DIR or place .issuely under project root)");
  }
  metaDir = realpath(metaDir);  // 穿透符号链接到真实路径

  return {
    projectDir,
    metaDir,
    projectName,
    language,
    originalRequirement,
    workspace:    workspaceAbs,
    workspaceRel,
    issuesDir:    path.join(workspaceAbs, "issues"),
    docsDir:      path.join(workspaceAbs, "docs"),
    statusPath:   path.join(workspaceAbs, "status.md"),
    memoPath:     path.join(workspaceAbs, "memo.md"),
    devDone:      path.join(workspaceAbs, "dev.done"),
    reviewDone:   path.join(workspaceAbs, "review.done"),
    // 运行日志属于项目数据，必须放在 workspace/ 下；.issuely/ 只保留引擎代码。
    logDir:       path.join(workspaceAbs, "logs"),
    models,
    tools,
    piTrace
  };
}

// 把解析后的视图打成 shell 可 eval 的 `KEY=VALUE` 行（已 shell-quote）。
function toShellEnv(view) {
  const sq = (v) => `'${String(v == null ? "" : v).replace(/'/g, "'\\''")}'`;
  const lines = [
    `ISSUELY_PROJECT_DIR=${sq(view.projectDir)}`,
    `META_DIR=${sq(view.metaDir)}`,
    `PROJECT_NAME=${sq(view.projectName)}`,
    `LANGUAGE=${sq(view.language)}`,
    `WORKSPACE=${sq(view.workspace)}`,
    `ISSUES_DIR=${sq(view.issuesDir)}`,
    `DOCS_DIR=${sq(view.docsDir)}`,
    `STATUS_PATH=${sq(view.statusPath)}`,
    `MEMO_PATH=${sq(view.memoPath)}`,
    `DEV_DONE=${sq(view.devDone)}`,
    `REVIEW_DONE=${sq(view.reviewDone)}`,
    `LOG_DIR=${sq(view.logDir)}`,
    `DEV_MODEL=${sq(view.models.dev || "")}`,
    `REVIEW_MODEL=${sq(view.models.review || "")}`,
    `PLANNER_MODEL=${sq(view.models.planner || "")}`,
    `PI_TOOLS=${sq(view.tools || "")}`,
    `PI_TRACE=${sq(view.piTrace)}`
  ];
  return lines.join("\n") + "\nexport ISSUELY_PROJECT_DIR META_DIR PROJECT_NAME LANGUAGE WORKSPACE ISSUES_DIR DOCS_DIR STATUS_PATH MEMO_PATH DEV_DONE REVIEW_DONE LOG_DIR DEV_MODEL REVIEW_MODEL PLANNER_MODEL PI_TOOLS PI_TRACE\n";
}

// 写一份新的 config.json (interactive 模式落盘用)。
function writeConfig(projectDir, partial) {
  const target = path.join(projectDir, "config.json");
  let existing = {};
  if (fs.existsSync(target)) {
    try { existing = JSON.parse(fs.readFileSync(target, "utf8")); } catch (_) { existing = {}; }
  }
  const merged = Object.assign({}, existing, partial);
  // 标准化 workspace 为相对路径，保持配置可移植。
  if (merged.workspace) {
    const abs = path.isAbsolute(merged.workspace)
      ? merged.workspace
      : path.resolve(projectDir, merged.workspace);
    const rel = path.relative(projectDir, abs);
    merged.workspace = rel || "workspace";
  } else {
    merged.workspace = DEFAULTS.workspace;
  }
  fs.writeFileSync(target, JSON.stringify(merged, null, 2) + "\n", "utf8");
  return target;
}

// CLI: 调用方式
//   node config.cjs print-shell                # 输出 shell env
//   node config.cjs write --project-name X ... # 写 config.json
//   node config.cjs show                       # 输出 JSON 视图 (debug 用)
function cli(argv) {
  const [cmd, ...rest] = argv;
  function parseFlags(arr) {
    const out = {};
    for (let i = 0; i < arr.length; i++) {
      const t = arr[i];
      if (!t.startsWith("--")) continue;
      const k = t.slice(2);
      const v = arr[i + 1];
      if (v === undefined || v.startsWith("--")) { out[k] = true; }
      else { out[k] = v; i++; }
    }
    return out;
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
    if (flags["language"])     partial.language    = flags["language"];
    if (flags["workspace"])    partial.workspace   = flags["workspace"];
    if (flags["original-requirement"] !== undefined) {
      // 支持 --original-requirement-from-env=VARNAME 以避免 shell 长串 quoting
      partial.originalRequirement = flags["original-requirement"];
    }
    if (flags["original-requirement-from-env"]) {
      partial.originalRequirement = process.env[flags["original-requirement-from-env"]] || "";
    }
    const target = writeConfig(projectDir, partial);
    process.stdout.write(target + "\n");
    return;
  }
  process.stderr.write("Usage: config.cjs print-shell | show | write [--project-dir DIR] [--project-name N] [--language L] [--workspace W] [--original-requirement-from-env VAR]\n");
  process.exit(2);
}

if (require.main === module) {
  try { cli(process.argv.slice(2)); }
  catch (e) { process.stderr.write(`[issuely-config] ${e.message}\n`); process.exit(1); }
}

module.exports = { loadConfig, writeConfig, toShellEnv, DEFAULTS };
