# shellcheck shell=bash
# Issuely runner 共享函数：
#   - issuely_load_config  从项目 config.json 加载所有路径与默认值
#   - render_prompt        把 .tpl 中的 {{VAR}} 占位用 env 注入 (防注入)
#   - run_pi_prompt        调用 pi (按 PI_TRACE 决定是否过滤 JSON 流)

# 加载配置：要求调用方已经 export 了 ISSUELY_PROJECT_DIR / ISSUELY_META_DIR。
# 没有就尝试从脚本相对路径推断 (.issuely/bin/_runner.sh → .issuely → 项目根)。
issuely_load_config() {
  if [ -z "${ISSUELY_META_DIR:-}" ]; then
    local self
    self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ISSUELY_META_DIR="$(cd "$self/.." && pwd)"
    export ISSUELY_META_DIR
  fi
  if [ -z "${ISSUELY_PROJECT_DIR:-}" ]; then
    # 默认回退：META_DIR 的上一级。但如果 .issuely 是符号链接指向全局共享目录，
    # 这条路径就不对——因此推荐 start.sh 显式 export ISSUELY_PROJECT_DIR。
    if [ -L "$ISSUELY_META_DIR" ] || [ "$(dirname "$ISSUELY_META_DIR")" = "/" ]; then
      echo "[runner] ISSUELY_PROJECT_DIR is required when .issuely is a symlink or global path." >&2
      return 1
    fi
    ISSUELY_PROJECT_DIR="$(cd "$ISSUELY_META_DIR/.." && pwd)"
    export ISSUELY_PROJECT_DIR
  fi
  # 调用 Node config 加载器，eval 输出
  # shellcheck disable=SC1090
  eval "$(node "$ISSUELY_META_DIR/lib/config.cjs" print-shell)"
}

timestamp_stream() {
  node -e '
const readline = require("readline");
const start = Date.now();
const pad = (v) => String(v).padStart(2, "0");
function ts(d){ return `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`; }
process.stdout.on("error",(e)=>{ if (e && e.code==="EPIPE") process.exit(0); throw e; });
const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on("line",(line)=>{
  const elapsed = Math.floor((Date.now()-start)/1000);
  process.stdout.write(`[${ts(new Date())} +${elapsed}s] ${line}\n`);
});
'
}

# render_prompt <tpl_path> <out_path>
# 通过 env 传所有变量；prompt 模板内 {{VAR}} 占位由 Node 替换。
# 绝不在 shell 字符串里内插用户/项目数据。
render_prompt() {
  local tpl="$1" out="$2"
  TPL_FILE="$tpl" OUT_FILE="$out" \
  WORKSPACE="$WORKSPACE" META_DIR="$META_DIR" ISSUES_DIR="$ISSUES_DIR" \
  PROJECT_NAME="$PROJECT_NAME" LANGUAGE="$LANGUAGE" \
  node - <<'RENDER_PROMPT'
const fs = require("fs");
const tpl = fs.readFileSync(process.env.TPL_FILE, "utf8");
const map = {
  WORKSPACE:    process.env.WORKSPACE    || "",
  META_DIR:     process.env.META_DIR     || "",
  ISSUES_DIR:   process.env.ISSUES_DIR   || "",
  PROJECT_NAME: process.env.PROJECT_NAME || "",
  LANGUAGE:     process.env.LANGUAGE     || ""
};
const out = tpl.replace(/\{\{(\w+)\}\}/g, (_, k) =>
  Object.prototype.hasOwnProperty.call(map, k) ? map[k] : `{{${k}}}`
);
fs.writeFileSync(process.env.OUT_FILE, out);
RENDER_PROMPT
}

# run_pi_prompt <prompt_path> <log_tag> <model_or_empty>
# - PI_TOOLS  非空时附加 --tools；空时 pi 走默认 (read,bash,edit,write)
# - PI_TRACE=1 时过滤 JSON 事件流；否则走原始 stdout
run_pi_prompt() {
  local prompt_file="$1" tag="$2" model="$3"
  local args=(--no-session)
  [ -n "${PI_TOOLS:-}" ] && args+=(--tools "$PI_TOOLS")
  [ -n "$model" ] && args+=(--model "$model")

  if [ "${PI_TRACE:-1}" = "1" ]; then
    echo "[$tag] pi trace: on (--mode json, filtered)"
    if command -v jq >/dev/null 2>&1; then
      pi "${args[@]}" --mode json -p "$(cat "$prompt_file")" | jq --unbuffered -r '
        if .type == "turn_start" then "[turn:start]"
        elif .type == "turn_end" then "[turn:end]"
        elif .type == "agent_end" then "[agent:end]"
        elif .type == "tool_execution_start" then "[tool:start] \(.toolName) \((.args // {}) | tojson)"
        elif .type == "tool_execution_update" then ((.partialResult.content // [])[]? | select(.type == "text") | "[tool:out] " + (.text | gsub("\\n$"; "")))
        elif .type == "tool_execution_end" then "[tool:end] \(.toolName) error=\(.isError)"
        elif .type == "message_update" and .assistantMessageEvent.type == "text_delta" then .assistantMessageEvent.delta
        else empty end
      ' | timestamp_stream
    else
      echo "[$tag] jq not found; falling back to raw stream"
      pi "${args[@]}" --mode json -p "$(cat "$prompt_file")"
    fi
  else
    pi "${args[@]}" -p "$(cat "$prompt_file")"
  fi
}
