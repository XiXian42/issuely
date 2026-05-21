#!/usr/bin/env bash
set -eo pipefail

# Issuely —— staged requirements → issues → dev/review pipeline.
# Single user entry point:
#   ./start.sh          print help
#   ./start.sh prd      collect/generate PRD via pi
#   ./start.sh issue    generate docs + issues via pi
#   ./start.sh dev      run dev/review loop

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
export ISSUELY_PROJECT_DIR="${ISSUELY_PROJECT_DIR:-$SELF_DIR}"

if [ -z "${ISSUELY_META_DIR:-}" ]; then
  if [ -d "$ISSUELY_PROJECT_DIR/.issuely" ]; then
    ISSUELY_META_DIR="$ISSUELY_PROJECT_DIR/.issuely"
  else
    echo "[Issuely] 找不到 .issuely 目录。请在项目根放置 .issuely/ 或设置 ISSUELY_META_DIR。" >&2
    exit 1
  fi
fi
ISSUELY_META_DIR="$(cd "$ISSUELY_META_DIR" && pwd)"
export ISSUELY_META_DIR

print_help() {
  cat <<'EOF'
Issuely — requirements → issues → dev/review

Usage:
  ./start.sh prd      生成/重写 PRD：调用 pi 多轮澄清，写入 workspace/docs/prd.md
  ./start.sh issue    生成/重写 issue：调用 pi 读取 PRD，写入 workspace/docs/spec-project.md、coding-style.md、workspace/issues/
  ./start.sh dev      进入开发：调用 run_while，启动 dev/review 双 agent 流水线
  ./start.sh          显示此帮助
  ./start.sh -h       显示此帮助

Typical flow:
  ./start.sh prd
  # pi 提示完成后，直接退出当前 pi 会话
  ./start.sh issue
  # pi 提示完成后，直接退出当前 pi 会话
  ./start.sh dev

Project layout:
  config.json                 项目配置
  workspace/docs/prd.md        产品需求文档
  workspace/docs/spec-project.md
  workspace/docs/coding-style.md
  workspace/issues/            有序任务包
  workspace/status.md          进度状态机（由工具维护）
  workspace/memo.md            项目记忆
  workspace/logs/              运行日志

Env overrides:
  ISSUELY_PROJECT_DIR          项目根，默认 start.sh 所在目录
  ISSUELY_META_DIR             框架目录，默认 $ISSUELY_PROJECT_DIR/.issuely
EOF
}

COMMAND="${1:-help}"
if [ $# -gt 1 ]; then
  echo "[Issuely] 参数过多。" >&2
  print_help
  exit 2
fi

case "$COMMAND" in
  help|-h|--help) print_help; exit 0 ;;
  prd|issue|dev) ;;
  *)
    echo "[Issuely] 未知命令：$COMMAND" >&2
    print_help
    exit 2
    ;;
esac

if [ ! -f "$ISSUELY_PROJECT_DIR/config.json" ]; then
  echo '{"workspace":"workspace"}' > "$ISSUELY_PROJECT_DIR/config.json"
fi

# shellcheck disable=SC1090
eval "$(node "$ISSUELY_META_DIR/lib/config.cjs" print-shell)"

mkdir -p "$WORKSPACE" "$DOCS_DIR" "$LOG_DIR"

ensure_safe_workspace() {
  if [ -z "${WORKSPACE:-}" ] || [ "$WORKSPACE" = "/" ] || [ "$WORKSPACE" = "$ISSUELY_PROJECT_DIR" ]; then
    echo "[Issuely] 不安全的 workspace 路径：${WORKSPACE:-<empty>}" >&2
    exit 1
  fi
}

build_system_prompt() {
  local role_tpl="$1"
  cat "$ISSUELY_META_DIR/agent.md"
  printf '\n\n---\n\n'
  cat "$role_tpl"
}

run_pi_interactive() {
  local role_tpl="$1" message="$2"
  local args=()
  [ -n "${PI_TOOLS:-}" ] && args+=(--tools "$PI_TOOLS")
  (cd "$ISSUELY_PROJECT_DIR" && pi "${args[@]}" \
    --system-prompt "$(build_system_prompt "$role_tpl")" \
    "$message")
}

run_while_with_log() {
  local ts log
  ts="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$LOG_DIR"
  log="$LOG_DIR/run-$ts.log"
  echo "[Issuely] 日志：$log"
  echo "[Issuely] 启动 run_while …（Ctrl+C 可中断；中断后重跑 ./start.sh dev 即可续跑）"
  echo
  set +e
  "$ISSUELY_META_DIR/bin/run_while.sh" 2>&1 | tee "$log"
  local rc=${PIPESTATUS[0]}
  set -e
  if [ "$rc" -ne 0 ]; then
    echo
    echo "=========================================================="
    echo "⚠️  [Issuely] run_while 以非零退出码 $rc 结束。"
    echo "----------------------------------------------------------"
    echo " 你可以："
    echo "   1) 查看日志末尾：tail -n 80 \"$log\""
    echo "   2) 查看当前状态：cat \"$STATUS_PATH\""
    echo "   3) 续跑：./start.sh dev"
    echo "=========================================================="
  fi
  return "$rc"
}

run_prd() {
  ensure_safe_workspace
  echo "[Issuely] prd 阶段会清空 workspace/，重新生成 workspace/docs/prd.md。"
  rm -rf "$WORKSPACE"
  mkdir -p "$DOCS_DIR" "$LOG_DIR"

  node "$ISSUELY_META_DIR/lib/config.cjs" write \
       --project-dir "$ISSUELY_PROJECT_DIR" \
       --workspace "$(basename "$WORKSPACE")" >/dev/null

  local message
  message="$(node - <<'BUILD_MSG'
process.stdout.write(`请启动 PRD 收集会话。

环境上下文：
- 当前工作目录是项目根
- 框架目录：.issuely
- workspace 路径：workspace
- PRD 输出：workspace/docs/prd.md

请先向用户问好，并请用户描述想做的产品或需求。
说明用户可以：
- 优先提供已有需求、业务说明、会议记录或竞品分析的文件路径作为参考，你可以读取相关文件；建议把参考文件放在项目目录或 workspace/docs/references/ 下，便于后续 issue 阶段继续读取。
- 如果暂时没有文件，也可以粘贴简短需求或只给一个模糊方向，之后你一步步引导讨论。

如果用户需求不明确，先讨论和追问；如果用户表述相对确定，只澄清影响 PRD 的不明之处。
技术栈方面，如果用户没有特别说明，请基于你最熟悉、最能稳定交付的方案给出建议并在预览中确认。
PRD 完成后提示用户直接退出当前 pi 会话即可。`);
BUILD_MSG
)"

  run_pi_interactive "$ISSUELY_META_DIR/core_prompts/prd_agent.tpl" "$message"

  if [ ! -f "$DOCS_DIR/prd.md" ]; then
    echo "⚠️ [Issuely] 未检测到 workspace/docs/prd.md。可重新运行 ./start.sh prd。" >&2
    exit 1
  fi

  echo
  echo "✅ PRD 已生成：workspace/docs/prd.md"
  echo "下一步：./start.sh issue"
}

run_issue() {
  ensure_safe_workspace
  if [ ! -f "$DOCS_DIR/prd.md" ]; then
    echo "[Issuely] 未找到 workspace/docs/prd.md。请先运行：./start.sh prd" >&2
    exit 1
  fi

  echo "[Issuely] issue 阶段会重写 workspace/issues/、spec-project.md、coding-style.md，并清理旧状态。"
  rm -rf "$ISSUES_DIR"
  rm -f "$DOCS_DIR/spec-project.md" "$DOCS_DIR/coding-style.md" \
        "$STATUS_PATH" "$DEV_DONE" "$REVIEW_DONE" "$LOG_DIR/.validate.json"
  mkdir -p "$ISSUES_DIR" "$LOG_DIR"

  local message
  message="$(node - <<'BUILD_MSG'
process.stdout.write(`请读取 workspace/docs/prd.md，生成工程规格文档和有序 issue。

环境上下文：
- 当前工作目录是项目根
- 框架目录：.issuely
- workspace 路径：workspace
- PRD 输入：workspace/docs/prd.md
- Issue 输出：workspace/issues/

请按 system-prompt 工作流执行。Issue 完成后提示用户直接退出当前 pi 会话即可。`);
BUILD_MSG
)"

  run_pi_interactive "$ISSUELY_META_DIR/core_prompts/issue_agent.tpl" "$message"

  if [ ! -d "$ISSUES_DIR" ] || [ -z "$(ls -A "$ISSUES_DIR" 2>/dev/null)" ] \
     || [ ! -f "$DOCS_DIR/spec-project.md" ] || [ ! -f "$DOCS_DIR/coding-style.md" ]; then
    echo "⚠️ [Issuely] 未检测到完整 issue 产物。可重新运行 ./start.sh issue。" >&2
    exit 1
  fi

  if ! node "$ISSUELY_META_DIR/bin/status_manager.js" validate \
        --workspace-dir "$WORKSPACE" --json > "$LOG_DIR/.validate.json" 2>&1; then
    echo "⚠️ [Issuely] issue 产物校验未通过："
    if command -v jq >/dev/null 2>&1; then
      jq -r '.problems[]? | "  - \(.type): \(.message)"' "$LOG_DIR/.validate.json" || cat "$LOG_DIR/.validate.json"
    else
      cat "$LOG_DIR/.validate.json"
    fi
    exit 1
  fi

  local issue_count
  issue_count=$(ls -1 "$ISSUES_DIR" 2>/dev/null | grep -cE '^[0-9]{3}-.*\.md$' || true)
  echo
  echo "✅ Issue 已生成：workspace/issues/（共 $issue_count 个）"
  echo "下一步：./start.sh dev"
}

run_dev() {
  if [ ! -d "$ISSUES_DIR" ] || [ -z "$(ls -A "$ISSUES_DIR" 2>/dev/null)" ]; then
    echo "[Issuely] 未找到 workspace/issues/。请先运行：./start.sh issue" >&2
    exit 1
  fi
  run_while_with_log
}

case "$COMMAND" in
  prd) run_prd ;;
  issue) run_issue ;;
  dev) run_dev ;;
esac
