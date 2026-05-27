# shellcheck shell=bash
# Shared Issuely runner helpers.

issuely_load_config() {
  if [ -z "${ISSUELY_META_DIR:-}" ]; then
    local self
    self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    ISSUELY_META_DIR="$(cd "$self/.." && pwd)"
    export ISSUELY_META_DIR
  fi
  if [ -z "${ISSUELY_PROJECT_DIR:-}" ]; then
    if [ -L "$ISSUELY_META_DIR" ] || [ "$(dirname "$ISSUELY_META_DIR")" = "/" ]; then
      echo "[runner] ISSUELY_PROJECT_DIR is required when .issuely is a symlink or global path." >&2
      return 1
    fi
    ISSUELY_PROJECT_DIR="$(cd "$ISSUELY_META_DIR/.." && pwd)"
    export ISSUELY_PROJECT_DIR
  fi
  local shell_env
  if ! shell_env="$(node "$ISSUELY_META_DIR/lib/config.cjs" print-shell)"; then
    return 1
  fi
  # shellcheck disable=SC1090
  eval "$shell_env"
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

render_prompt() {
  local tpl="$1" out="$2"
  TPL_FILE="$tpl" OUT_FILE="$out" AGENT_RULES_FILE="$META_DIR/agent.md" \
  PROJECT_NAME="$PROJECT_NAME" LANGUAGE="$LANGUAGE" \
  node - <<'RENDER_PROMPT'
const fs = require("fs");
const globalRules = fs.existsSync(process.env.AGENT_RULES_FILE)
  ? fs.readFileSync(process.env.AGENT_RULES_FILE, "utf8")
  : "";
const roleTpl = fs.readFileSync(process.env.TPL_FILE, "utf8");
const tpl = globalRules ? `${globalRules}\n\n---\n\n${roleTpl}` : roleTpl;
const workspace = process.env.WORKSPACE || process.env.WORKSPACE_REL || "workspace";
const map = {
  WORKSPACE:    workspace,
  META_DIR:     process.env.META_DIR_REF || process.env.META_DIR || ".issuely",
  ISSUES_DIR:   process.env.ISSUES_DIR || `${workspace}/issues`,
  DOCS_DIR:     process.env.DOCS_DIR || `${workspace}/docs`,
  STATUS_PATH:  process.env.STATUS_PATH || `${workspace}/status.md`,
  MEMO_PATH:    process.env.MEMO_PATH || `${workspace}/memo.md`,
  LOG_DIR:      process.env.LOG_DIR || `${workspace}/logs`,
  DEV_DONE:     process.env.DEV_DONE || `${workspace}/dev.done`,
  REVIEW_DONE:  process.env.REVIEW_DONE || `${workspace}/review.done`,
  PROJECT_NAME: process.env.PROJECT_NAME || "",
  LANGUAGE:     process.env.LANGUAGE     || "",
  REFINE_ISSUE_FILE:   process.env.REFINE_ISSUE_FILE   || "",
  REFINE_ISSUE_NUMBER: process.env.REFINE_ISSUE_NUMBER || "",
  REFINE_ROUND:        process.env.REFINE_ROUND        || ""
};
const out = tpl.replace(/\{\{(\w+)\}\}/g, (_, k) =>
  Object.prototype.hasOwnProperty.call(map, k) ? map[k] : `{{${k}}}`
);
fs.writeFileSync(process.env.OUT_FILE, out);
RENDER_PROMPT
}

role_agent() {
  case "$1" in
    planner) printf '%s' "${PLANNER_AGENT:-pi}" ;;
    dev) printf '%s' "${DEV_AGENT:-pi}" ;;
    review) printf '%s' "${REVIEW_AGENT:-pi}" ;;
    *) echo "[runner] unknown role for agent lookup: $1" >&2; return 1 ;;
  esac
}

role_model() {
  case "$1" in
    planner) printf '%s' "${PLANNER_MODEL:-}" ;;
    dev) printf '%s' "${DEV_MODEL:-}" ;;
    review) printf '%s' "${REVIEW_MODEL:-}" ;;
    *) echo "[runner] unknown role for model lookup: $1" >&2; return 1 ;;
  esac
}

role_thinking() {
  case "$1" in
    planner) printf '%s' "${PLANNER_THINKING:-}" ;;
    dev) printf '%s' "${DEV_THINKING:-}" ;;
    review) printf '%s' "${REVIEW_THINKING:-}" ;;
    *) echo "[runner] unknown role for thinking lookup: $1" >&2; return 1 ;;
  esac
}

role_summary() {
  local role="$1"
  local agent model thinking
  agent="$(role_agent "$role")" || return 1
  model="$(role_model "$role")" || return 1
  thinking="$(role_thinking "$role")" || return 1
  printf '%s' "$agent"
  [ -n "$model" ] && printf ' model=%s' "$model"
  [ -n "$thinking" ] && printf ' thinking=%s' "$thinking"
}

validate_thinking_for_agent() {
  local agent="$1" thinking="$2"
  [ -z "$thinking" ] && return 0
  case "$agent:$thinking" in
    pi:off|pi:minimal|pi:low|pi:medium|pi:high|pi:xhigh) return 0 ;;
    omp:minimal|omp:low|omp:medium|omp:high|omp:xhigh) return 0 ;;
    claude:low|claude:medium|claude:high|claude:xhigh|claude:max) return 0 ;;
    codex:*) return 0 ;;
    *)
      echo "[runner] invalid thinking/effort '$thinking' for agent '$agent'" >&2
      return 1
      ;;
  esac
}

ensure_agent_available() {
  local agent="$1"
  if ! command -v "$agent" >/dev/null 2>&1; then
    echo "[runner] configured agent '$agent' not found in PATH" >&2
    return 1
  fi
}

render_agent_trace() {
  local agent="$1"
  node "$META_DIR/bin/trace_renderer.js" --agent "$agent"
}

run_pi_prompt() {
  local prompt_text="$1" tag="$2" model="$3" thinking="$4"
  local args=(--no-session)
  [ -n "${PI_TOOLS:-}" ] && args+=(--tools "$PI_TOOLS")
  [ -n "$model" ] && args+=(--model "$model")
  [ -n "$thinking" ] && args+=(--thinking "$thinking")
  if [ "${PI_TRACE:-1}" = "1" ]; then
    echo "[$tag] pi trace: on (--mode json, rendered)"
    (cd "$ISSUELY_PROJECT_DIR" && pi "${args[@]}" --mode json -p "$prompt_text") | render_agent_trace pi
  else
    (cd "$ISSUELY_PROJECT_DIR" && pi "${args[@]}" -p "$prompt_text")
  fi
}

run_omp_prompt() {
  local prompt_text="$1" model="$2" thinking="$3"
  local args=(--no-session)
  [ -n "${OMP_TOOLS:-}" ] && args+=(--tools "$OMP_TOOLS")
  [ -n "$model" ] && args+=(--model "$model")
  [ -n "$thinking" ] && args+=(--thinking "$thinking")
  if [ "${OMP_TRACE:-1}" = "1" ]; then
    echo "[omp] trace: on (--mode json, rendered)"
    (cd "$ISSUELY_PROJECT_DIR" && omp "${args[@]}" --mode json -p "$prompt_text") | render_agent_trace omp
  else
    (cd "$ISSUELY_PROJECT_DIR" && omp "${args[@]}" -p "$prompt_text")
  fi
}

run_claude_prompt() {
  local prompt_text="$1" model="$2" thinking="$3"
  local args=(--print --no-session-persistence)
  [ -n "$model" ] && args+=(--model "$model")
  [ -n "$thinking" ] && args+=(--effort "$thinking")
  [ -n "${CLAUDE_PERMISSION_MODE:-}" ] && args+=(--permission-mode "$CLAUDE_PERMISSION_MODE")
  if [ "${CLAUDE_TRACE:-1}" = "1" ]; then
    echo "[claude] trace: on (--output-format stream-json, rendered)"
    (cd "$ISSUELY_PROJECT_DIR" && claude "${args[@]}" --output-format stream-json --verbose --include-partial-messages "$prompt_text") | render_agent_trace claude
  else
    (cd "$ISSUELY_PROJECT_DIR" && claude "${args[@]}" --output-format text "$prompt_text")
  fi
}

run_codex_prompt() {
  local prompt_text="$1" model="$2" thinking="$3"
  local args=(exec --skip-git-repo-check --ephemeral)
  [ -n "$model" ] && args+=(--model "$model")
  [ -n "$thinking" ] && args+=(-c "model_reasoning_effort=\"$thinking\"")
  [ -n "${CODEX_SANDBOX:-}" ] && args+=(--sandbox "$CODEX_SANDBOX")
  [ -n "${CODEX_APPROVAL:-}" ] && args+=(--ask-for-approval "$CODEX_APPROVAL")
  if [ "${CODEX_TRACE:-1}" = "1" ]; then
    echo "[codex] trace: on (--json, rendered)"
    (cd "$ISSUELY_PROJECT_DIR" && codex "${args[@]}" --json "$prompt_text") | render_agent_trace codex
  else
    (cd "$ISSUELY_PROJECT_DIR" && codex "${args[@]}" "$prompt_text")
  fi
}

run_role_prompt() {
  local role="$1" prompt_file="$2" tag="$3"
  local agent model thinking prompt_text
  agent="$(role_agent "$role")" || return 1
  model="$(role_model "$role")" || return 1
  thinking="$(role_thinking "$role")" || return 1
  validate_thinking_for_agent "$agent" "$thinking" || return 1
  ensure_agent_available "$agent" || return 1
  prompt_text="$(cat "$prompt_file")"
  case "$agent" in
    pi) run_pi_prompt "$prompt_text" "$tag" "$model" "$thinking" ;;
    omp) run_omp_prompt "$prompt_text" "$model" "$thinking" ;;
    claude) run_claude_prompt "$prompt_text" "$model" "$thinking" ;;
    codex) run_codex_prompt "$prompt_text" "$model" "$thinking" ;;
    *) echo "[runner] unsupported agent: $agent" >&2; return 1 ;;
  esac
}

run_pi_interactive() {
  local system_prompt="$1" message="$2" model="$3" thinking="$4"
  local args=()
  [ -n "${PI_TOOLS:-}" ] && args+=(--tools "$PI_TOOLS")
  [ -n "$model" ] && args+=(--model "$model")
  [ -n "$thinking" ] && args+=(--thinking "$thinking")
  (cd "$ISSUELY_PROJECT_DIR" && pi "${args[@]}" --system-prompt "$system_prompt" "$message")
}

run_omp_interactive() {
  local system_prompt="$1" message="$2" model="$3" thinking="$4"
  local args=()
  [ -n "${OMP_TOOLS:-}" ] && args+=(--tools "$OMP_TOOLS")
  [ -n "$model" ] && args+=(--model "$model")
  [ -n "$thinking" ] && args+=(--thinking "$thinking")
  (cd "$ISSUELY_PROJECT_DIR" && omp "${args[@]}" --system-prompt "$system_prompt" "$message")
}

run_claude_interactive() {
  local system_prompt="$1" message="$2" model="$3" thinking="$4"
  local args=()
  [ -n "$model" ] && args+=(--model "$model")
  [ -n "$thinking" ] && args+=(--effort "$thinking")
  [ -n "${CLAUDE_PERMISSION_MODE:-}" ] && args+=(--permission-mode "$CLAUDE_PERMISSION_MODE")
  (cd "$ISSUELY_PROJECT_DIR" && claude "${args[@]}" --system-prompt "$system_prompt" "$message")
}

run_codex_interactive() {
  local system_prompt="$1" message="$2" model="$3" thinking="$4"
  local combined_prompt
  combined_prompt="$system_prompt

---

$message"
  local args=()
  [ -n "$model" ] && args+=(--model "$model")
  [ -n "$thinking" ] && args+=(-c "model_reasoning_effort=\"$thinking\"")
  [ -n "${CODEX_SANDBOX:-}" ] && args+=(--sandbox "$CODEX_SANDBOX")
  [ -n "${CODEX_APPROVAL:-}" ] && args+=(--ask-for-approval "$CODEX_APPROVAL")
  (cd "$ISSUELY_PROJECT_DIR" && codex "${args[@]}" "$combined_prompt")
}

run_role_interactive() {
  local role="$1" system_prompt="$2" message="$3"
  local agent model thinking
  agent="$(role_agent "$role")" || return 1
  model="$(role_model "$role")" || return 1
  thinking="$(role_thinking "$role")" || return 1
  validate_thinking_for_agent "$agent" "$thinking" || return 1
  ensure_agent_available "$agent" || return 1
  case "$agent" in
    pi) run_pi_interactive "$system_prompt" "$message" "$model" "$thinking" ;;
    omp) run_omp_interactive "$system_prompt" "$message" "$model" "$thinking" ;;
    claude) run_claude_interactive "$system_prompt" "$message" "$model" "$thinking" ;;
    codex) run_codex_interactive "$system_prompt" "$message" "$model" "$thinking" ;;
    *) echo "[runner] unsupported agent: $agent" >&2; return 1 ;;
  esac
}
