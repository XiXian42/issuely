#!/usr/bin/env bash
set -eo pipefail

# dev runner：单轮调用 dev agent，处理一个 issue 后退出。
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./_runner.sh
. "$DIR/_runner.sh"
issuely_load_config

if [ -f "$DEV_DONE" ]; then
  echo "[run_dev] dev.done 已立，跳过。"
  exit 0
fi

echo "[run_dev] $(role_summary dev)"

PROMPT_FILE="$(mktemp "${TMPDIR:-/tmp}/run_dev_prompt.XXXXXX")"
trap 'rm -f "$PROMPT_FILE"' EXIT

render_prompt "$META_DIR/core_prompts/dev_agent.tpl" "$PROMPT_FILE"
run_role_prompt "dev" "$PROMPT_FILE" "run_dev"
