#!/usr/bin/env bash
set -eo pipefail

# Issuely —— staged requirements → issues → dev/review pipeline.
# Primary user entry points:
#   issuely prd          collect/generate PRD
#   issuely issue        generate docs + issues
#   issuely issue refine refine [complex-issue] tasks before development
#   issuely dev          run dev/review loop

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
  issuely prd           生成/重写 PRD：调用规划 agent 多轮澄清，写入 workspace/docs/prd.md
  issuely issue         生成/重写 issue：读取 PRD，写入 workspace/docs/spec-project.md、coding-style.md、workspace/issues/
  issuely issue refine  开发前 refine 带 [complex-issue] 标记的复杂 issue
  issuely dev           进入开发：调用 run_while，启动 dev/review 双 agent 流水线
  issuely help          显示此帮助
  ./start.sh ...        兼容旧入口；等价于上述 issuely 命令

Typical flow:
  issuely prd
  # 规划 agent 提示完成后，直接退出当前会话
  issuely issue
  # 规划 agent 提示完成后，直接退出当前会话
  issuely dev

Project layout:
  config.json                 项目配置（项目级覆盖）
  workspace/docs/prd.md       产品需求文档
  workspace/docs/spec-project.md
  workspace/docs/coding-style.md
  workspace/issues/           有序任务包
  workspace/status.md         进度状态机（由工具维护）
  workspace/memo.md           项目记忆
  workspace/logs/             运行日志

Env overrides:
  ISSUELY_PROJECT_DIR         项目根；issuely 命令默认使用当前目录
  ISSUELY_META_DIR            框架目录；默认项目根/.issuely 或全局安装目录
  ISSUELY_HOME                全局配置目录；默认 ~/.issuely
EOF
}

COMMAND="${1:-help}"
SUBCOMMAND="${2:-}"
if [ $# -gt 2 ]; then
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
if [ "$COMMAND" = "issue" ] && [ -n "$SUBCOMMAND" ] && [ "$SUBCOMMAND" != "refine" ]; then
  echo "[Issuely] 未知 issue 子命令：$SUBCOMMAND" >&2
  print_help
  exit 2
fi
if [ "$COMMAND" != "issue" ] && [ -n "$SUBCOMMAND" ]; then
  echo "[Issuely] $COMMAND 不支持子命令：$SUBCOMMAND" >&2
  print_help
  exit 2
fi

if [ ! -f "$ISSUELY_PROJECT_DIR/config.json" ]; then
  echo '{"workspace":"workspace"}' > "$ISSUELY_PROJECT_DIR/config.json"
fi

# shellcheck source=.issuely/bin/_runner.sh
. "$ISSUELY_META_DIR/bin/_runner.sh"
issuely_load_config

ensure_safe_workspace() {
  if [ -z "${WORKSPACE:-}" ] || [ "$WORKSPACE" = "/" ] || [ "$WORKSPACE" = "$ISSUELY_PROJECT_DIR" ]; then
    echo "[Issuely] 不安全的 workspace 路径：${WORKSPACE:-<empty>}" >&2
    exit 1
  fi
  case "$WORKSPACE" in
    "$ISSUELY_PROJECT_DIR"/*) ;;
    *)
      echo "[Issuely] 不安全的 workspace 路径：$WORKSPACE（必须位于项目根内）" >&2
      exit 1
      ;;
  esac
}

ensure_safe_workspace
mkdir -p "$WORKSPACE" "$DOCS_DIR" "$LOG_DIR"

build_system_prompt() {
  local role_tpl="$1"
  TPL_FILE="$role_tpl" AGENT_RULES_FILE="$ISSUELY_META_DIR/agent.md" \
  node - <<'RENDER_PROMPT'
const fs = require("fs");
const globalRules = fs.existsSync(process.env.AGENT_RULES_FILE)
  ? fs.readFileSync(process.env.AGENT_RULES_FILE, "utf8")
  : "";
const roleTpl = fs.readFileSync(process.env.TPL_FILE, "utf8");
const tpl = globalRules ? `${globalRules}\n\n---\n\n${roleTpl}` : roleTpl;
const workspace = process.env.WORKSPACE_REL || "workspace";
const map = {
  WORKSPACE: workspace,
  META_DIR: process.env.META_DIR_REF || ".issuely",
  ISSUES_DIR: process.env.ISSUES_DIR_REL || `${workspace}/issues`,
  DOCS_DIR: process.env.DOCS_DIR_REL || `${workspace}/docs`,
  STATUS_PATH: process.env.STATUS_PATH_REL || `${workspace}/status.md`,
  MEMO_PATH: process.env.MEMO_PATH_REL || `${workspace}/memo.md`,
  LOG_DIR: process.env.LOG_DIR_REL || `${workspace}/logs`,
  DEV_DONE: process.env.DEV_DONE_REL || `${workspace}/dev.done`,
  REVIEW_DONE: process.env.REVIEW_DONE_REL || `${workspace}/review.done`,
  PROJECT_NAME: process.env.PROJECT_NAME || "",
  LANGUAGE: process.env.LANGUAGE || "",
  REFINE_ISSUE_FILE: process.env.REFINE_ISSUE_FILE || "",
  REFINE_ISSUE_NUMBER: process.env.REFINE_ISSUE_NUMBER || "",
  REFINE_ROUND: process.env.REFINE_ROUND || ""
};
process.stdout.write(tpl.replace(/\{\{(\w+)\}\}/g, (_, k) =>
  Object.prototype.hasOwnProperty.call(map, k) ? map[k] : `{{${k}}}`
));
RENDER_PROMPT
}

run_planner_interactive() {
  local role_tpl="$1" message="$2"
  run_role_interactive "planner" "$(build_system_prompt "$role_tpl")" "$message"
}

run_while_with_log() {
  local ts log
  ts="$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$LOG_DIR"
  log="$LOG_DIR/run-$ts.log"
  echo "[Issuely] 日志：$log"
  echo "[Issuely] 启动 run_while …（Ctrl+C 可中断；中断后重跑 issuely dev 即可续跑）"
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
    echo "   3) 续跑：issuely dev"
    echo "=========================================================="
  fi
  return "$rc"
}

run_prd() {
  ensure_safe_workspace
  echo "[Issuely] prd 阶段会清空 $WORKSPACE_REL/，重新生成 $DOCS_DIR_REL/prd.md。"
  rm -rf "$WORKSPACE"
  mkdir -p "$DOCS_DIR" "$LOG_DIR"

  node "$ISSUELY_META_DIR/lib/config.cjs" write \
       --project-dir "$ISSUELY_PROJECT_DIR" \
       --workspace "$WORKSPACE_REL" >/dev/null

  local message
  message="$(node - <<'BUILD_MSG'
const ws = process.env.WORKSPACE_REL || "workspace";
const docs = process.env.DOCS_DIR_REL || `${ws}/docs`;
const meta = process.env.META_DIR_REF || ".issuely";
process.stdout.write(`请启动 PRD 收集会话。

环境上下文：
- 当前工作目录是项目根
- 框架目录：${meta}
- workspace 路径：${ws}
- PRD 输出：${docs}/prd.md

请先向用户问好，并请用户描述想做的产品或需求。
说明用户可以：
- 优先提供已有需求、业务说明、会议记录或竞品分析的文件路径作为参考，你可以读取相关文件；建议把参考文件放在项目目录的 docs/references/ 或 references/ 下，避免被 PRD 阶段清空 workspace 时误删；PRD 的参考文档小节应记录这些文件的项目相对路径，而不是只写文件名。
- 如果暂时没有文件，也可以粘贴简短需求或只给一个模糊方向，之后你一步步引导讨论。

如果用户需求不明确，先讨论和追问；如果用户表述相对确定，只澄清影响 PRD 的不明之处。
技术栈方面，如果用户没有特别说明，请基于你最熟悉、最能稳定交付的方案给出建议并在预览中确认。
PRD 完成后提示用户直接退出当前 agent 会话即可。`);
BUILD_MSG
)"

  run_planner_interactive "$ISSUELY_META_DIR/core_prompts/prd_agent.tpl" "$message"

  if [ ! -f "$DOCS_DIR/prd.md" ]; then
    echo "⚠️ [Issuely] 未检测到 $DOCS_DIR_REL/prd.md。可重新运行 issuely prd。" >&2
    exit 1
  fi

  echo
  echo "✅ PRD 已生成：$DOCS_DIR_REL/prd.md"
  echo "下一步："
  echo "  $ issuely issue"
}

run_issue() {
  ensure_safe_workspace
  if [ ! -f "$DOCS_DIR/prd.md" ]; then
    echo "[Issuely] 未找到 $DOCS_DIR_REL/prd.md。请先运行：issuely prd" >&2
    exit 1
  fi

  echo "[Issuely] issue 阶段会重写 $ISSUES_DIR_REL/、$DOCS_DIR_REL/spec-project.md、$DOCS_DIR_REL/coding-style.md，并清理旧状态。"
  rm -rf "$ISSUES_DIR"
  rm -f "$DOCS_DIR/spec-project.md" "$DOCS_DIR/coding-style.md" \
        "$STATUS_PATH" "$DEV_DONE" "$REVIEW_DONE" "$LOG_DIR/.validate.json"
  mkdir -p "$ISSUES_DIR" "$LOG_DIR"

  local message
  message="$(node - <<'BUILD_MSG'
const ws = process.env.WORKSPACE_REL || "workspace";
const docs = process.env.DOCS_DIR_REL || `${ws}/docs`;
const issues = process.env.ISSUES_DIR_REL || `${ws}/issues`;
const meta = process.env.META_DIR_REF || ".issuely";
process.stdout.write(`请读取 ${docs}/prd.md，生成工程规格文档和有序 issue。

环境上下文：
- 当前工作目录是项目根
- 框架目录：${meta}
- workspace 路径：${ws}
- PRD 输入：${docs}/prd.md
- Issue 输出：${issues}/

请按 system-prompt 工作流执行。Issue 完成后提示用户直接退出当前 agent 会话即可。`);
BUILD_MSG
)"

  run_planner_interactive "$ISSUELY_META_DIR/core_prompts/issue_agent.tpl" "$message"

  if [ ! -d "$ISSUES_DIR" ] || [ -z "$(ls -A "$ISSUES_DIR" 2>/dev/null)" ] \
     || [ ! -f "$DOCS_DIR/spec-project.md" ] || [ ! -f "$DOCS_DIR/coding-style.md" ]; then
    echo "⚠️ [Issuely] 未检测到完整 issue 产物。可重新运行 issuely issue。" >&2
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
  issue_count=$(ls -1 "$ISSUES_DIR" 2>/dev/null | grep -cE '^([0-9]{3}|[0-9]{6})-.*\.md$' || true)
  local complex_count
  complex_count=$(grep -Rsl -- '^\[complex-issue\]$' "$ISSUES_DIR" 2>/dev/null | wc -l | tr -d ' ')
  echo
  echo "✅ Issue 已生成：$ISSUES_DIR_REL/（共 $issue_count 个）"
  if [ "${complex_count:-0}" -gt 0 ]; then
    echo "检测到 $complex_count 个复杂 issue 标记为 [complex-issue]。"
    echo "建议下一步："
    echo "  $ issuely issue refine"
  else
    echo "下一步："
    echo "  $ issuely dev"
  fi
}

run_issue_refine() {
  ensure_safe_workspace
  if [ ! -d "$ISSUES_DIR" ] || [ -z "$(ls -A "$ISSUES_DIR" 2>/dev/null)" ]; then
    echo "[Issuely] 未找到 $ISSUES_DIR_REL/。请先运行：issuely issue" >&2
    exit 1
  fi
  if [ -f "$STATUS_PATH" ] || [ -f "$DEV_DONE" ] || [ -f "$REVIEW_DONE" ]; then
    echo "[Issuely] issue refine 只能在开发前运行；检测到已有 status/dev.done/review.done。" >&2
    exit 1
  fi
  "$ISSUELY_META_DIR/bin/run_issue_refine.sh"
}

run_dev() {
  ensure_safe_workspace
  if [ ! -d "$ISSUES_DIR" ] || [ -z "$(ls -A "$ISSUES_DIR" 2>/dev/null)" ]; then
    echo "[Issuely] 未找到 $ISSUES_DIR_REL/。请先运行：issuely issue" >&2
    exit 1
  fi
  run_while_with_log
}

case "$COMMAND" in
  prd) run_prd ;;
  issue)
    if [ "$SUBCOMMAND" = "refine" ]; then
      run_issue_refine
    else
      run_issue
    fi
    ;;
  dev) run_dev ;;
esac
