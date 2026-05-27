#!/usr/bin/env bash
set -eo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$DIR/../.." && pwd)"
CONFIG_HELPER="$ROOT_DIR/.issuely/lib/config.cjs"
GLOBAL_PATH="$(node "$CONFIG_HELPER" global-path)"
GLOBAL_VIEW="$(node "$CONFIG_HELPER" show-global)"

bold()   { printf "\033[1m%s\033[0m" "$*"; }
cyan()   { printf "\033[36m%s\033[0m" "$*"; }
green()  { printf "\033[32m%s\033[0m" "$*"; }
yellow() { printf "\033[33m%s\033[0m" "$*"; }
red()    { printf "\033[31m%s\033[0m" "$*"; }
dim()    { printf "\033[2m%s\033[0m" "$*"; }

PROMPT_OUT_FD=2
PROMPT_IN_FD=0
if { exec 9<>/dev/tty; } 2>/dev/null; then
  PROMPT_OUT_FD=9
  PROMPT_IN_FD=9
fi

prompt_line() {
  local text="$1"
  printf '%b' "$text" >&"$PROMPT_OUT_FD"
}

read_tty() {
  local var_name="$1"
  local value
  read -r value <&"$PROMPT_IN_FD" || value=""
  printf -v "$var_name" '%s' "$value"
}

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

agent_desc() {
  case "$1" in
    pi) printf 'balanced coding agent' ;;
    omp) printf 'pi-compatible agent' ;;
    claude) printf 'strong review / reasoning' ;;
    codex) printf 'strong implementation / repo work' ;;
    *) printf '%s' "$1" ;;
  esac
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

contains_value() {
  local needle="$1"
  shift
  local item
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

agent_menu() {
  AVAILABLE_AGENTS=()
  while IFS= read -r line; do
    [ -n "$line" ] && AVAILABLE_AGENTS+=("$line")
  done < <(collect_available_agents)
  if [ "${#AVAILABLE_AGENTS[@]}" -eq 0 ]; then
    AVAILABLE_AGENTS=(pi omp claude codex)
  fi
}

default_model_for() {
  local agent="$1" role="$2"
  case "$agent:$role" in
    pi:planner|omp:planner) printf '' ;;
    pi:dev|omp:dev) printf 'openai-codex/gpt-5.5' ;;
    pi:review|omp:review) printf 'openrouter/anthropic/claude-sonnet-4.6' ;;
    claude:*) printf 'sonnet' ;;
    codex:*) printf 'gpt-5.5' ;;
    *) printf '' ;;
  esac
}

model_examples_for() {
  case "$1" in
    pi|omp) printf 'openai-codex/gpt-5.5, openrouter/anthropic/claude-sonnet-4.6' ;;
    claude) printf 'sonnet, opus' ;;
    codex) printf 'gpt-5.5, gpt-5' ;;
    *) printf 'custom model id' ;;
  esac
}

thinking_values_for() {
  case "$1" in
    pi) printf '%s\n' off minimal low medium high xhigh ;;
    omp) printf '%s\n' minimal low medium high xhigh ;;
    claude) printf '%s\n' low medium high xhigh max ;;
    codex) printf '%s\n' minimal low medium high ;;
    *) printf '%s\n' low medium high ;;
  esac
}

recommended_thinking_for() {
  case "$1" in
    planner) printf 'high' ;;
    dev) printf 'high' ;;
    review) printf 'low' ;;
    *) printf '' ;;
  esac
}

role_title() {
  case "$1" in
    planner) printf 'Planner' ;;
    dev) printf 'Dev' ;;
    review) printf 'Review' ;;
    *) printf '%s' "$1" ;;
  esac
}

menu_pick() {
  local prompt="$1" default_index="$2"
  shift 2
  local options=("$@")
  local total="${#options[@]}"
  local i choice
  for ((i=0; i<total; i++)); do
    local index=$((i + 1))
    local marker=""
    [ "$index" = "$default_index" ] && marker=" $(dim "← default")"
    prompt_line "    $(cyan "$index)") ${options[$i]}${marker}\n"
  done
  while true; do
    prompt_line "  Choice [default=${default_index}]: "
    read_tty choice
    choice="${choice:-$default_index}"
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$total" ]; then
      printf '%s' "$choice"
      return 0
    fi
    prompt_line "  $(red "Invalid choice")\n"
  done
}

pick_agent_for_role() {
  local role="$1" default_agent="$2"
  local options=()
  local agents=()
  local default_index=1
  local i
  for ((i=0; i<${#AVAILABLE_AGENTS[@]}; i++)); do
    local agent="${AVAILABLE_AGENTS[$i]}"
    agents+=("$agent")
    options+=("$(bold "$agent") — $(dim "$(agent_desc "$agent")")")
    [ "$agent" = "$default_agent" ] && default_index=$((i + 1))
  done
  prompt_line "\n  $(bold "$(role_title "$role")") agent\n"
  local picked
  picked="$(menu_pick "agent" "$default_index" "${options[@]}")"
  printf '%s' "${agents[$((picked - 1))]}"
}

pick_model_for_role() {
  local role="$1" agent="$2" current_value="$3"
  local suggested default_label default_value
  suggested="$(default_model_for "$agent" "$role")"
  if [ -n "$current_value" ]; then
    default_label="Keep current: $(bold "$current_value")"
    default_value="$current_value"
  elif [ -n "$suggested" ]; then
    default_label="Use suggested default: $(bold "$suggested")"
    default_value="$suggested"
  else
    default_label="Use agent built-in default $(dim "(unset --model)")"
    default_value=""
  fi

  prompt_line "\n  $(bold "$(role_title "$role") model") $(dim "for $agent")\n"
  prompt_line "  Examples: $(dim "$(model_examples_for "$agent")")\n"
  local options=()
  local use_agent_default_option=1
  options+=("$default_label")
  if [ -n "$suggested" ] && [ "$default_value" != "$suggested" ]; then
    options+=("Use suggested default: $(bold "$suggested")")
  fi
  if [ -n "$default_value" ] || [ -n "$suggested" ]; then
    options+=("Use agent built-in default $(dim "(unset --model)")")
  else
    use_agent_default_option=0
  fi
  options+=("Enter a custom model id")
  local picked
  picked="$(menu_pick "model" 1 "${options[@]}")"
  case "$picked" in
    1)
      printf '%s' "$default_value"
      return 0
      ;;
    2)
      if [ -n "$suggested" ] && [ "$default_value" != "$suggested" ]; then
        printf '%s' "$suggested"
        return 0
      fi
      if [ "$use_agent_default_option" = "1" ]; then
        printf '%s' ""
        return 0
      fi
      ;;
    3)
      if [ -n "$suggested" ] && [ "$default_value" != "$suggested" ]; then
        printf '%s' ""
        return 0
      fi
      if [ "$use_agent_default_option" = "1" ]; then
        :
      else
        printf '%s' ""
        return 0
      fi
      ;;
  esac
  local custom
  prompt_line "  Custom model id: "
  read_tty custom
  printf '%s' "$custom"
}

pick_thinking_for_role() {
  local role="$1" agent="$2" current_value="$3"
  local recommended values=() options=() values_out=() value
  recommended="$(recommended_thinking_for "$role")"
  while IFS= read -r value; do
    [ -n "$value" ] && values+=("$value")
  done < <(thinking_values_for "$agent")

  prompt_line "\n  $(bold "$(role_title "$role") thinking / effort") $(dim "for $agent")\n"
  prompt_line "  Suggested for $(role_title "$role"): $(green "$recommended")\n"

  if [ -n "$current_value" ]; then
    options+=("Keep current: $(bold "$current_value")")
    values_out+=("$current_value")
  else
    options+=("Use recommended: $(green "$recommended")")
    values_out+=("$recommended")
  fi
  options+=("Use agent default $(dim "(unset)")")
  values_out+=("")

  for value in "${values[@]}"; do
    if [ "$value" = "${values_out[0]}" ]; then
      continue
    fi
    options+=("$value")
    values_out+=("$value")
  done

  local picked
  picked="$(menu_pick "thinking" 1 "${options[@]}")"
  printf '%s' "${values_out[$((picked - 1))]}"
}

echo ""
prompt_line "  $(bold "Issuely") — global configuration\n"
prompt_line "  $(dim "$GLOBAL_PATH")\n\n"

agent_menu
if contains_value pi "${AVAILABLE_AGENTS[@]}" || contains_value omp "${AVAILABLE_AGENTS[@]}" || contains_value claude "${AVAILABLE_AGENTS[@]}" || contains_value codex "${AVAILABLE_AGENTS[@]}"; then
  prompt_line "  Detected agents:\n"
  local_i=1
  for agent in "${AVAILABLE_AGENTS[@]}"; do
    prompt_line "    $(cyan "$local_i)") $(bold "$agent") — $(dim "$(agent_desc "$agent")")\n"
    local_i=$((local_i + 1))
  done
  prompt_line "\n"
fi

planner_agent_default="$(json_get config.roles.planner.agent)"
dev_agent_default="$(json_get config.roles.dev.agent)"
review_agent_default="$(json_get config.roles.review.agent)"
planner_agent_default="${planner_agent_default:-${AVAILABLE_AGENTS[0]:-pi}}"
dev_agent_default="${dev_agent_default:-$planner_agent_default}"
review_agent_default="${review_agent_default:-$dev_agent_default}"

prompt_line "  $(yellow "[1/4]") $(bold "Choose agents")\n"
base_agent="$(pick_agent_for_role planner "$planner_agent_default")"
use_same="$(menu_pick "same-agent" 1 "Yes — use $(bold "$base_agent") for planner / dev / review" "No — choose each role separately")"
if [ "$use_same" = "1" ]; then
  planner_agent="$base_agent"
  dev_agent="$base_agent"
  review_agent="$base_agent"
else
  planner_agent="$base_agent"
  dev_agent="$(pick_agent_for_role dev "$dev_agent_default")"
  review_agent="$(pick_agent_for_role review "$review_agent_default")"
fi

planner_model_current="$(json_get config.roles.planner.model)"
dev_model_current="$(json_get config.roles.dev.model)"
review_model_current="$(json_get config.roles.review.model)"
planner_thinking_current="$(json_get config.roles.planner.thinking)"
dev_thinking_current="$(json_get config.roles.dev.thinking)"
review_thinking_current="$(json_get config.roles.review.thinking)"

prompt_line "\n  $(yellow "[2/4]") $(bold "Planner")\n"
planner_model="$(pick_model_for_role planner "$planner_agent" "$planner_model_current")"
planner_thinking="$(pick_thinking_for_role planner "$planner_agent" "$planner_thinking_current")"

prompt_line "\n  $(yellow "[3/4]") $(bold "Dev")\n"
dev_model="$(pick_model_for_role dev "$dev_agent" "$dev_model_current")"
dev_thinking="$(pick_thinking_for_role dev "$dev_agent" "$dev_thinking_current")"

prompt_line "\n  $(yellow "[4/4]") $(bold "Review")\n"
review_model="$(pick_model_for_role review "$review_agent" "$review_model_current")"
review_thinking="$(pick_thinking_for_role review "$review_agent" "$review_thinking_current")"

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

prompt_line "\n  $(green "✓") Saved global config: $GLOBAL_PATH\n\n"
prompt_line "  $(bold "Planner") $(cyan "$planner_agent") $(dim "model=${planner_model:-<agent default>} thinking=${planner_thinking:-<agent default>}")\n"
prompt_line "  $(bold "Dev    ") $(cyan "$dev_agent") $(dim "model=${dev_model:-<agent default>} thinking=${dev_thinking:-<agent default>}")\n"
prompt_line "  $(bold "Review ") $(cyan "$review_agent") $(dim "model=${review_model:-<agent default>} thinking=${review_thinking:-<agent default>}")\n\n"
prompt_line "  Next:\\n    $ cd <your-project>\\n    $ issuely prd\\n"
