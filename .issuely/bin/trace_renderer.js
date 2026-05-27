#!/usr/bin/env node
"use strict";

const readline = require("readline");

const args = process.argv.slice(2);
const agentIndex = args.indexOf("--agent");
const AGENT = agentIndex >= 0 ? args[agentIndex + 1] || "pi" : "pi";
const useColor = process.env.NO_COLOR ? false : process.env.ISSUELY_TRACE_COLOR !== "0";

const C = useColor
  ? {
      r: "\x1b[0m",
      dim: "\x1b[2m",
      bold: "\x1b[1m",
      cyan: "\x1b[36m",
      yellow: "\x1b[33m",
      green: "\x1b[32m",
      red: "\x1b[31m"
    }
  : { r: "", dim: "", bold: "", cyan: "", yellow: "", green: "", red: "" };

const FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"];
const SPIN_W = 96;
const IS_TTY = process.stdout.isTTY;
let needNl = false;
const TEXT_INDENT = "  ";
let textLineStart = true;

const write = (s) => process.stdout.write(s);

const spinner = {
  timer: null,
  frame: 0,
  label: "",
  lastNonTtyLabel: "",
  start(label = "") {
    this.stop();
    this.label = label;
    this.frame = 0;
    if (!IS_TTY) {
      if (label && label !== this.lastNonTtyLabel) {
        ensureNl();
        write(`${C.dim}  … ${label}${C.r}\n`);
        needNl = false;
        textLineStart = true;
        this.lastNonTtyLabel = label;
      }
      return;
    }
    this.timer = setInterval(() => {
      const f = FRAMES[this.frame++ % FRAMES.length];
      write(`\r${C.dim}  ${f}  ${this.label}${C.r}`);
    }, 80);
  },
  stop() {
    if (this.timer) {
      clearInterval(this.timer);
      this.timer = null;
      write("\r" + " ".repeat(SPIN_W) + "\r");
    }
    this.label = "";
  },
  get running() {
    return IS_TTY ? this.timer !== null : this.label !== "";
  }
};

function ensureNl() {
  if (needNl) {
    write("\n");
    needNl = false;
    textLineStart = true;
  }
}

function emitText(text) {
  if (!text) return;
  if (spinner.running) spinner.stop();

  for (const part of String(text).split(/(\n)/)) {
    if (!part) continue;
    if (part === "\n") {
      write("\n");
      needNl = false;
      textLineStart = true;
      continue;
    }
    if (textLineStart) {
      write(TEXT_INDENT);
      textLineStart = false;
    }
    write(part);
    needNl = true;
  }
}

function fmtCmd(value) {
  const text = String(value || "").replace(/\s+/g, " ").trim();
  return text.length > 120 ? text.slice(0, 120) + "…" : text;
}

function shortJson(value) {
  if (value == null) return "";
  if (typeof value === "string") return fmtCmd(value);
  try {
    return fmtCmd(JSON.stringify(value));
  } catch (_) {
    return fmtCmd(String(value));
  }
}

function firstText(value) {
  if (Array.isArray(value)) {
    return value
      .map((item) => (item && item.type === "text" ? item.text || "" : ""))
      .filter(Boolean)
      .join("");
  }
  return value == null ? "" : String(value);
}

function printToolStart(name, detail) {
  spinner.stop();
  ensureNl();
  write(`\n  ${C.dim}⚙  ${C.yellow}${name || "tool"}${C.r}${C.dim}${detail ? `  ${detail}` : ""}${C.r}\n`);
  needNl = false;
  spinner.start(`running ${name || "tool"}${detail ? `  ${detail}` : ""}`);
}

function printToolOutput(text) {
  if (!text) return;
  spinner.stop();
  ensureNl();
  const lines = String(text).replace(/\n$/, "").split("\n");
  for (const line of lines) write(`  ${C.dim}│ ${line}${C.r}\n`);
  needNl = false;
  spinner.start("thinking…");
}

function printToolEnd(isErr, output) {
  spinner.stop();
  const icon = isErr ? `${C.red}✗${C.r}` : `${C.green}✓${C.r}`;
  const text = String(output || "").trim();
  if (text) {
    const lines = text.split("\n");
    const preview = lines[0].slice(0, 160);
    const more = lines.length > 1 ? `  ${C.dim}(+${lines.length - 1} lines)${C.r}` : "";
    write(`  ${icon}  ${C.dim}${preview}${more}${C.r}\n`);
  } else {
    write(`  ${icon}  ${C.dim}(done)${C.r}\n`);
  }
  needNl = false;
}

function handlePi(obj) {
  const type = obj.type || "";
  if (type === "turn_start") {
    spinner.start("thinking…");
    return;
  }
  if (type === "message_update") {
    const event = obj.assistantMessageEvent || {};
    if (event.type === "text_delta") emitText(event.delta || "");
    return;
  }
  if (type === "tool_execution_start") {
    const toolName = obj.toolName || "tool";
    const toolArgs = obj.args || {};
    const detail = toolArgs.command ? fmtCmd(toolArgs.command) : toolArgs.path || shortJson(toolArgs);
    printToolStart(toolName, detail);
    return;
  }
  if (type === "tool_execution_update") {
    const content = obj.partialResult && obj.partialResult.content;
    printToolOutput(firstText(content));
    return;
  }
  if (type === "tool_execution_end") {
    const content = obj.result && obj.result.content;
    printToolEnd(Boolean(obj.isError), firstText(content));
    spinner.start("thinking…");
    return;
  }
  if (type === "turn_end" || type === "agent_end" || type === "message_end") {
    spinner.stop();
    ensureNl();
    return;
  }
  return;
}

const codexSeen = new Set();
function handleCodex(obj) {
  const type = obj.type || "";
  const item = obj.item || {};
  if (type === "turn.started") {
    spinner.start("thinking…");
    return;
  }
  if (type === "item.started" && item.type === "command_execution") {
    codexSeen.add(item.id);
    printToolStart("bash", fmtCmd(item.command || ""));
    return;
  }
  if (type === "item.completed" && item.type === "command_execution") {
    if (!codexSeen.has(item.id)) printToolStart("bash", fmtCmd(item.command || ""));
    printToolEnd(Number(item.exit_code || 0) !== 0, item.aggregated_output || "");
    spinner.start("thinking…");
    return;
  }
  if (type === "item.completed" && item.type === "agent_message") {
    emitText((item.text || "") + (item.text && item.text.endsWith("\n") ? "" : "\n"));
    return;
  }
  if (type === "turn.completed" || type === "agent_end" || type === "message_end") {
    spinner.stop();
    ensureNl();
    return;
  }
  return;
}

let claudeMessageHadDelta = false;
function handleClaude(obj) {
  const type = obj.type || "";
  if (type === "system") return;

  if (type === "stream_event") {
    const event = obj.event || {};
    if (event.type === "message_start") {
      claudeMessageHadDelta = false;
      spinner.start("thinking…");
      return;
    }
    if (event.type === "content_block_delta" && event.delta && event.delta.type === "text_delta") {
      claudeMessageHadDelta = true;
      emitText(event.delta.text || "");
      return;
    }
    if (event.type === "message_stop") {
      spinner.stop();
      ensureNl();
      return;
    }
  }

  if (type === "assistant") {
    const content = (obj.message && obj.message.content) || [];
    for (const part of content) {
      if (part.type === "tool_use") {
        const input = part.input || {};
        const detail = input.command ? fmtCmd(input.command) : input.path || shortJson(input);
        printToolStart(part.name || "tool", detail);
      } else if (part.type === "text" && part.text && !claudeMessageHadDelta) {
        emitText(part.text + (part.text.endsWith("\n") ? "" : "\n"));
      }
    }
    return;
  }

  if (type === "user") {
    const content = (obj.message && obj.message.content) || [];
    for (const part of content) {
      if (part.type === "tool_result") {
        printToolEnd(Boolean(part.is_error), firstText(part.content));
        spinner.start("thinking…");
      }
    }
    return;
  }

  if (type === "result" || type === "agent_end" || type === "message_end" || type === "turn_end") {
    spinner.stop();
    ensureNl();
    return;
  }
  return;
}

spinner.start("thinking…");

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on("line", (raw) => {
  const line = raw.trim();
  if (!line) return;
  let obj;
  try {
    obj = JSON.parse(line);
  } catch (_) {
    emitText(raw + "\n");
    return;
  }
  if (AGENT === "codex") handleCodex(obj);
  else if (AGENT === "claude") handleClaude(obj);
  else handlePi(obj);
});
rl.on("close", () => {
  spinner.stop();
  ensureNl();
});
process.on("SIGINT", () => {
  spinner.stop();
  ensureNl();
  process.exit(130);
});
