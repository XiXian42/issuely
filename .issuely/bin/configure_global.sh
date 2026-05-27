#!/usr/bin/env bash
set -eo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$DIR/../.." && pwd)"
CONFIG_HELPER="$ROOT_DIR/.issuely/lib/config.cjs"
GLOBAL_PATH="$(node "$CONFIG_HELPER" global-path)"
GLOBAL_VIEW="$(node "$CONFIG_HELPER" show-global)"

bold()  { printf "\033[1m%s\033[0m" "$*"; }
cyan()  { printf "\033[36m%s\033[0m" "$*"; }
green() { printf "\033[32m%s\033[0m" "$*"; }
red()   { printf "\033[31m%s\033[0m" "$*"; }
dim()   { printf "\033[2m%s\033[0m" "$*"; }
PROMPT_OUT_FD=1
PROMPT_IN_FD=0
if { exec 9<>/dev/tty; } 2>/dev/null; then
  PROMPT_OUT_FD=9
  PROMPT_IN_FD=9
fi

json_get() {
  local path_expr="$1"
  JSON_INPUT="$GLOBAL_VIEW" JSON_PATH="$path_expr" node - <<'NODE'
const view = JSON.parse(process.env.JSON_INPUT || "{}");
const pathExpr = process.env.JSON_PATH || "";
let current = view;
for (const part of pathExpr.split(".")) {
  if (!part) continue;
  current = current && Object.prototype.hasOwnProperty.call(current, part) ? current[part] : undefined;
}
process.stdout.write(current == null ? "" : String(current));
NODE
}

default_model_for() {
  local agent="$1" role="$2"
  case "$agent:$role" in
    claude:*) printf 'sonnet' ;;
    codex:*) printf 'gpt-5.5' ;;
    pi:planner|omp:planner) printf '' ;;
    pi:dev|omp:dev) printf 'openai-codex/gpt-5.5' ;;
    pi:review|omp:review) printf 'openrouter/anthropic/claude-sonnet-4.6' ;;
    *) printf '' ;;
  esac
}

thinking_hint_for() {
  case "$1" in
    pi) printf 'off|minimal|low|medium|high|xhigh' ;;
    omp) printf 'minimal|low|medium|high|xhigh' ;;
    claude) printf 'low|medium|high|xhigh|max' ;;
    codex) printf 'minimal|low|medium|high (recommended)' ;;
    *) printf 'agent default' ;;
  esac
}

validate_agent() {
  case "$1" in
    pi|omp|claude|codex) return 0 ;;
    *) return 1 ;;
  esac
}

prompt_line() {
  local text="$1"
  printf '%s' "$text" >&"$PROMPT_OUT_FD"
}

read_tty() {
  local var_name="$1"
  local value
  read -r value <&"$PROMPT_IN_FD" || value=""
  printf -v "$var_name" '%s' "$value"
}

collect_available_agents() {
  local found=()
  local agent
  for agent in pi omp claude codex; do
    if command -v "$agent" >/dev/null 2>&1; then
      found+=("$agent")
    fi
  done
  printf '%s\n' "${found[@]}"
}

prompt_agent_for_role() {
  local role="$1" default_agent="$2"
  local choice
  while true; do
    prompt_line "  $(bold "$role") agent [${default_agent}]: "
    read_tty choice
    choice="${choice:-$default_agent}"
    if validate_agent "$choice"; then
      printf '%s' "$choice"
      return 0
    fi
    prompt_line "  $(red "Invalid agent") — use pi / omp / claude / codex\n"
  done
}


prompt_optional_for_role() {
  local label="$1" current_value="$2"
  local choice
  if [ -n "$current_value" ]; then
    prompt_line "  ${label} [${current_value}] (blank to keep, '-' to clear): "
    read_tty choice
    if [ "$choice" = "-" ]; then
      printf '%s' ""
    else
      printf '%s' "${choice:-$current_value}"
    fi
  else
    prompt_line "  ${label} [blank = agent default, '-' = clear]: "
    read_tty choice
    if [ "$choice" = "-" ]; then
      printf '%s' ""
    else
      printf '%s' "$choice"
    fi
  fi
}

echo ""
echo "  $(bold "Issuely") — global configuration"
echo "  $(dim "$GLOBAL_PATH")"
echo ""

AVAILABLE_AGENTS=()
while IFS= read -r line; do
  [ -n "$line" ] && AVAILABLE_AGENTS+=("$line")
done < <(collect_available_agents)
if [ "${#AVAILABLE_AGENTS[@]}" -eq 0 ]; then
  echo "  $(red "✗") No supported agent found in PATH."
  echo "  You can still save config now and install an agent later."
  echo ""
else
  echo "  Detected agents: $(cyan "${AVAILABLE_AGENTS[*]}")"
  echo ""
fi

planner_agent_default="$(json_get config.roles.planner.agent)"
dev_agent_default="$(json_get config.roles.dev.agent)"
review_agent_default="$(json_get config.roles.review.agent)"
planner_agent_default="${planner_agent_default:-${AVAILABLE_AGENTS[0]:-pi}}"
dev_agent_default="${dev_agent_default:-$planner_agent_default}"
review_agent_default="${review_agent_default:-${AVAILABLE_AGENTS[0]:-$dev_agent_default}}"

planner_agent="$(prompt_agent_for_role planner "$planner_agent_default")"
dev_agent="$(prompt_agent_for_role dev "$dev_agent_default")"
review_agent="$(prompt_agent_for_role review "$review_agent_default")"

echo ""
planner_model_default="$(json_get config.roles.planner.model)"
planner_model_default="${planner_model_default:-$(default_model_for "$planner_agent" planner)}"
planner_model="$(prompt_optional_for_role "planner model" "$planner_model_default")"
prompt_line "  planner thinking / effort ($(thinking_hint_for "$planner_agent"))"
planner_thinking="$(prompt_optional_for_role "  value" "$(json_get config.roles.planner.thinking)")"

echo ""
dev_model_default="$(json_get config.roles.dev.model)"
dev_model_default="${dev_model_default:-$(default_model_for "$dev_agent" dev)}"
dev_model="$(prompt_optional_for_role "dev model" "$dev_model_default")"
prompt_line "  dev thinking / effort ($(thinking_hint_for "$dev_agent"))"
dev_thinking="$(prompt_optional_for_role "  value" "$(json_get config.roles.dev.thinking)")"

echo ""
review_model_default="$(json_get config.roles.review.model)"
review_model_default="${review_model_default:-$(default_model_for "$review_agent" review)}"
review_model="$(prompt_optional_for_role "review model" "$review_model_default")"
prompt_line "  review thinking / effort ($(thinking_hint_for "$review_agent"))"
review_thinking="$(prompt_optional_for_role "  value" "$(json_get config.roles.review.thinking)")"

echo ""
CONFIG_JSON="$(PLANNER_AGENT="$planner_agent" DEV_AGENT="$dev_agent" REVIEW_AGENT="$review_agent" \
PLANNER_MODEL="$planner_model" DEV_MODEL="$dev_model" REVIEW_MODEL="$review_model" \
PLANNER_THINKING="$planner_thinking" DEV_THINKING="$dev_thinking" REVIEW_THINKING="$review_thinking" \
node - <<'NODE'
const emptyToNull = (value) => {
  const text = String(value || "").trim();
  return text ? text : null;
};
const config = {
  version: 1,
  roles: {
    planner: {
      agent: process.env.PLANNER_AGENT,
      model: emptyToNull(process.env.PLANNER_MODEL),
      thinking: emptyToNull(process.env.PLANNER_THINKING)
    },
    dev: {
      agent: process.env.DEV_AGENT,
      model: emptyToNull(process.env.DEV_MODEL),
      thinking: emptyToNull(process.env.DEV_THINKING)
    },
    review: {
      agent: process.env.REVIEW_AGENT,
      model: emptyToNull(process.env.REVIEW_MODEL),
      thinking: emptyToNull(process.env.REVIEW_THINKING)
    }
  },
  agents: {
    pi: { tools: "", trace: 1 },
    omp: { tools: "" },
    claude: { permissionMode: "dontAsk" },
    codex: { sandbox: "workspace-write", approval: "never" }
  }
};
process.stdout.write(JSON.stringify(config));
NODE
)"

CONFIG_JSON="$CONFIG_JSON" node "$CONFIG_HELPER" write-global --config-json-from-env CONFIG_JSON >/dev/null

echo "  $(green "✓") Saved global config: $GLOBAL_PATH"
echo ""
echo "  Planner: $(cyan "$planner_agent") $(dim "model=${planner_model:-<agent default>} thinking=${planner_thinking:-<agent default>}")"
echo "  Dev    : $(cyan "$dev_agent") $(dim "model=${dev_model:-<agent default>} thinking=${dev_thinking:-<agent default>}")"
echo "  Review : $(cyan "$review_agent") $(dim "model=${review_model:-<agent default>} thinking=${review_thinking:-<agent default>}")"
echo ""
echo "  Next: cd <your-project> && issuely prd"
