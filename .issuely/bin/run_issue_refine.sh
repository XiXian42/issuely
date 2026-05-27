#!/usr/bin/env bash
set -eo pipefail

# issue refine runner：开发前按 [complex-issue] 标记逐个精修复杂 issue。

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./_runner.sh
. "$DIR/_runner.sh"
issuely_load_config

if [ -f "$STATUS_PATH" ] || [ -f "$DEV_DONE" ] || [ -f "$REVIEW_DONE" ]; then
  echo "[run_issue_refine] issue refine 只能在开发前运行；检测到已有状态文件。" >&2
  exit 1
fi

if [ ! -d "$ISSUES_DIR" ]; then
  echo "[run_issue_refine] 未找到 issues 目录：$ISSUES_DIR" >&2
  exit 1
fi

complex_list() {
  grep -Rsl -- '^\[complex-issue\]$' "$ISSUES_DIR" 2>/dev/null | sort || true
}

complex_count() {
  complex_list | sed '/^$/d' | wc -l | tr -d ' '
}

count="$(complex_count)"
if [ "${count:-0}" -eq 0 ]; then
  echo "[run_issue_refine] 未检测到 [complex-issue]，无需 refine。"
  exit 0
fi

mkdir -p "$WORKSPACE/refine/backups" "$DOCS_DIR"
rm -f "$DOCS_DIR/issue-refine-plan.md"
backup_dir="$WORKSPACE/refine/backups/issues-$(date +%Y%m%d-%H%M%S)"
cp -R "$ISSUES_DIR" "$backup_dir"
echo "[run_issue_refine] 已备份当前 issues：$backup_dir"
echo "[run_issue_refine] 待 refine 复杂 issue：$count"

trap 'rm -f "$round_prompt"' EXIT
round=0
while true; do
  count="$(complex_count)"
  if [ "${count:-0}" -eq 0 ]; then
    break
  fi

  issue_path="$(complex_list | head -n 1)"
  issue_file="$(basename "$issue_path")"
  issue_number="${issue_file%%-*}"
  round=$((round + 1))
  echo
  echo "[run_issue_refine] round $round: $issue_file（剩余 $count）"

  before_count="$count"
  round_prompt="$(mktemp "${TMPDIR:-/tmp}/issue_refine_round.XXXXXX")"
  export REFINE_ISSUE_FILE="$issue_file"
  export REFINE_ISSUE_NUMBER="$issue_number"
  export REFINE_ROUND="$round"
  render_prompt "$META_DIR/core_prompts/refine_agent.tpl" "$round_prompt"
  echo "[run_issue_refine] $(role_summary planner)"
  run_role_prompt "planner" "$round_prompt" "issue_refine_round"
  rm -f "$round_prompt"

  after_count="$(complex_count)"
  if [ "${after_count:-0}" -ge "${before_count:-0}" ]; then
    echo "[run_issue_refine] 本轮后 [complex-issue] 数量未减少（$before_count -> $after_count），停止以避免循环。" >&2
    exit 1
  fi
done

if grep -Rsl -- '^\[complex-issue\]$' "$ISSUES_DIR" >/dev/null 2>&1; then
  echo "[run_issue_refine] refine 结束后仍有 [complex-issue] 残留。" >&2
  exit 1
fi

if ! node "$META_DIR/bin/status_manager.js" validate --workspace-dir "$WORKSPACE" --json > "$LOG_DIR/.validate.json" 2>&1; then
  echo "[run_issue_refine] issue 产物校验未通过："
  if command -v jq >/dev/null 2>&1; then
    jq -r '.problems[]? | "  - \(.type): \(.message)"' "$LOG_DIR/.validate.json" || cat "$LOG_DIR/.validate.json"
  else
    cat "$LOG_DIR/.validate.json"
  fi
  exit 1
fi

echo
echo "✅ issue refine 已完成；所有 [complex-issue] 标记已清除。"
echo "下一步：issuely dev"
