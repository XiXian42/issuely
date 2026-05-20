#!/usr/bin/env bash
set -eo pipefail

# review runner：单轮调用 review agent，审核一个 issue 后退出。
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./_runner.sh
. "$DIR/_runner.sh"
issuely_load_config

if [ -f "$REVIEW_DONE" ]; then
  echo "[run_review] review.done 已立，跳过。"
  exit 0
fi

echo "[run_review] model: ${REVIEW_MODEL:-<pi default>}"

PROMPT_FILE="$(mktemp "${TMPDIR:-/tmp}/run_review_prompt.XXXXXX")"
trap 'rm -f "$PROMPT_FILE"' EXIT

render_prompt "$META_DIR/core_prompts/review_agent.tpl" "$PROMPT_FILE"
run_pi_prompt "$PROMPT_FILE" "run_review" "$REVIEW_MODEL"
