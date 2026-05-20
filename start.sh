#!/usr/bin/env bash
set -eo pipefail

# Issuely —— 一键从需求到实现的 Agent 流水线入口
#
# 单一事实源：./config.json （由 .issuely/lib/config.cjs 读写）。
# 路径解析顺序：
#   1) ISSUELY_PROJECT_DIR   - 用户/外部脚本可显式指定项目根；缺省为 start.sh 所在目录。
#   2) ISSUELY_META_DIR      - .issuely 框架代码所在目录；缺省为 $ISSUELY_PROJECT_DIR/.issuely。
#                              支持把 .issuely 做成符号链接或全局共享路径。
#
# 用法：
#   ./start.sh           交互模式：收集需求 → 规划 → 自动开发与审查
#   ./start.sh dev       开发模式：跳过规划，直接进入 run_while
#   ./start.sh -h        帮助

# ── 项目根 / 框架目录解析 ────────────────────────────────────────
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
export ISSUELY_PROJECT_DIR="${ISSUELY_PROJECT_DIR:-$SELF_DIR}"

# .issuely 既可以是项目根下的子目录，也可以是符号链接指向全局安装路径。
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

# 解析参数
#   ./start.sh         规划模式：收集需求 → planner 多轮 → 落盘 docs/ + issues/，然后退出
#   ./start.sh dev     开发模式：跳过规划，直接跑 dev/review 双 agent (run_while)
#   ./start.sh -c      同 dev (兼容旧名)
#   ./start.sh -h      帮助
MODE="plan"
while [ $# -gt 0 ]; do
  case "$1" in
    dev|run|develop)   MODE="dev" ;;
    -c|--continue)     MODE="dev" ;;
    -h|--help|help)
      cat <<EOF
Issuely — 全程软件工程 Agent

Usage:
  ./start.sh           规划：收集需求 → planner 多轮对话 → 落盘 docs/ + issues/ → 退出
  ./start.sh dev       开发：跳过规划，直接启动 dev/review 双 agent 流水线
  ./start.sh -c        同 dev (兼容旧名)
  ./start.sh -h        显示此帮助

典型用法：
  ./start.sh           # 第一次：先把需求聊清楚，落盘
  ./start.sh dev       # 然后：让 agent 把项目跑出来
  ./start.sh dev       # 中断后：再跑一次即可续跑

Project layout:
  config.json          项目配置（单一事实源）
  workspace/docs/      系统设计与规范（规划阶段生成）
  workspace/issues/    有序任务包
  workspace/status.md  进度状态机（请勿手改）
  workspace/memo.md    项目记忆
  workspace/logs/      运行日志

Env overrides:
  ISSUELY_PROJECT_DIR  项目根（默认：start.sh 所在目录）
  ISSUELY_META_DIR     框架目录（默认：\$ISSUELY_PROJECT_DIR/.issuely，可指向全局安装路径）
EOF
      exit 0
      ;;
    *)
      echo "[Issuely] 未知参数：$1。使用 ./start.sh -h 查看帮助。" >&2
      exit 2
      ;;
  esac
  shift
done

# 如果还没有 config.json，先放一份最小占位（让 config 加载器有东西可读）
if [ ! -f "$ISSUELY_PROJECT_DIR/config.json" ]; then
  echo '{"workspace":"workspace"}' > "$ISSUELY_PROJECT_DIR/config.json"
fi

# 读 config，导出所有 shell 变量
# shellcheck disable=SC1090
eval "$(node "$ISSUELY_META_DIR/lib/config.cjs" print-shell)"

mkdir -p "$ISSUELY_META_DIR/bin" "$ISSUELY_META_DIR/core_prompts" "$LOG_DIR" "$WORKSPACE"

# ─────────────────────────────────────────────────────────────
# run_while 包装：tee 到日志，非零退出给恢复指引
# ─────────────────────────────────────────────────────────────
run_while_with_log() {
  local ts log
  ts="$(date +%Y%m%d-%H%M%S)"
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
    echo "   3) 续跑（不会丢数据）：./start.sh dev"
    echo "   4) 重新规划（会清空 workspace/）：./start.sh"
    echo "=========================================================="
  fi
  return "$rc"
}

# ─────────────────────────────────────────────────────────────
# 开发模式 (./start.sh dev / -c)：跳过规划，直接跑 run_while
# ─────────────────────────────────────────────────────────────
if [ "$MODE" = "dev" ]; then
  if [ ! -d "$ISSUES_DIR" ] || [ -z "$(ls -A "$ISSUES_DIR" 2>/dev/null)" ]; then
    echo "[Issuely] 开发模式需要已有 issues/ 产物。请先运行 ./start.sh 规划。" >&2
    exit 1
  fi
  run_while_with_log
  exit $?
fi

# ─────────────────────────────────────────────────────────────
# 交互模式：先做状态分支检测
# ─────────────────────────────────────────────────────────────
clear
echo "=========================================================="
echo "          🌌  I s s u e l y  -  全程软件工程 Agent"
echo "=========================================================="
echo "   一键需求收集 -> 任务规划 -> 自动开发与双 Agent 审查"
echo "----------------------------------------------------------"
echo

HAS_DEV_DONE=0;    [ -f "$DEV_DONE" ]    && HAS_DEV_DONE=1
HAS_REVIEW_DONE=0; [ -f "$REVIEW_DONE" ] && HAS_REVIEW_DONE=1
HAS_ISSUES=0;      [ -d "$ISSUES_DIR" ] && [ -n "$(ls -A "$ISSUES_DIR" 2>/dev/null)" ] && HAS_ISSUES=1
HAS_STATUS=0;      [ -f "$STATUS_PATH" ] && HAS_STATUS=1

# 已存在的项目状态如何处理：
#   0 = 全新项目，进入规划
#   1 = 用户选择重新规划，清空 workspace/ 后进入规划
#   3 = 已有进行中或已完成的项目；提示用户运行 ./start.sh dev / 重新规划，然后退出
decide_action() {
  if [ "$HAS_DEV_DONE" = 1 ] && [ "$HAS_REVIEW_DONE" = 1 ]; then
    echo "[Info] 上一轮已完整交付（dev.done + review.done 均存在）。"
    echo "  [r] 重新规划（清空 workspace/）"
    echo "  [q] 退出（推荐，仅查看产物）"
    read -p "选择 (r/q) [默认 q]: " ANS
    case "${ANS:-q}" in
      r|R) return 1 ;;
      *)   return 3 ;;
    esac
  elif [ "$HAS_STATUS" = 1 ]; then
    echo "[Info] 检测到进行中的项目（status.md 存在）。"
    echo "  [d] 立即跑开发（执行 ./start.sh dev）（推荐）"
    echo "  [r] 重新规划（清空 workspace/）"
    echo "  [q] 退出"
    read -p "选择 (d/r/q) [默认 d]: " ANS
    case "${ANS:-d}" in
      d|D) return 3 ;;
      r|R) return 1 ;;
      *)   exit 0 ;;
    esac
  elif [ "$HAS_ISSUES" = 1 ]; then
    echo "[Info] 已生成 issues/，但尚未开始开发。"
    echo "  [d] 立即跑开发（执行 ./start.sh dev）（推荐）"
    echo "  [r] 重新规划（清空 workspace/）"
    echo "  [q] 退出"
    read -p "选择 (d/r/q) [默认 d]: " ANS
    case "${ANS:-d}" in
      d|D) return 3 ;;
      r|R) return 1 ;;
      *)   exit 0 ;;
    esac
  fi
  return 0
}

set +e
decide_action
DECISION=$?
set -e

if [ "$DECISION" = 3 ]; then
  if [ ! -d "$ISSUES_DIR" ] || [ -z "$(ls -A "$ISSUES_DIR" 2>/dev/null)" ]; then
    echo "[Issuely] 没有 issues/，无法直接开发。请先运行 ./start.sh 进行规划。" >&2
    exit 1
  fi
  run_while_with_log
  exit $?
fi

if [ "$DECISION" = 1 ]; then
  echo "[Info] 正在清空 workspace/ …"
  rm -rf "$WORKSPACE"
  mkdir -p "$WORKSPACE"
fi

# ─────────────────────────────────────────────────────────────
# 收集需求：只问一句话，后续交给 Planner 在 TTY 内多轮追问
# ─────────────────────────────────────────────────────────────
echo "💡 一句话告诉 Issuely 你想做什么。Planner 会接管对话，主动追问到需求清晰为止。"
echo "----------------------------------------------------------"
read -p "👉 一句话需求（例如：我想一个 NextJS 代办小应用）: " RAW_NEED

if [ -z "$RAW_NEED" ]; then
  echo "[Error] 需求为空。Issuely 退出。" >&2
  exit 1
fi

# 先写一份临时 config.json：只保证 originalRequirement。projectName 与 language
# 由 Planner 多轮追问后调用 config.cjs write 自行回写。
RAW_NEED="$RAW_NEED" \
node "$ISSUELY_META_DIR/lib/config.cjs" write \
     --project-dir "$ISSUELY_PROJECT_DIR" \
     --workspace "$(basename "$WORKSPACE")" \
     --original-requirement-from-env RAW_NEED >/dev/null

# 重新加载
eval "$(node "$ISSUELY_META_DIR/lib/config.cjs" print-shell)"

# 给 Planner 的初始 message：只传一句话 + 路径上下文
INITIAL_MESSAGE="$(RAW_NEED="$RAW_NEED" \
                   ISSUELY_META_DIR="$ISSUELY_META_DIR" \
                   ISSUELY_PROJECT_DIR="$ISSUELY_PROJECT_DIR" \
                   WORKSPACE="$WORKSPACE" \
                   node - <<'BUILD_MSG'
process.stdout.write(`用户一句话需求：
${process.env.RAW_NEED}

环境上下文：
- 项目根：${process.env.ISSUELY_PROJECT_DIR}
- 框架目录：${process.env.ISSUELY_META_DIR}
- workspace 路径：${process.env.WORKSPACE}

请按 system-prompt 里的工作流，与用户多轮对话，在需求没有 gap 之前不要落盘。`);
BUILD_MSG
)"

# 不传 -p：pi 走交互式 TUI，接管用户输入/输出，支持多轮
PI_ARGS=()
[ -n "$PI_TOOLS" ] && PI_ARGS+=(--tools "$PI_TOOLS")
[ -n "$PLANNER_MODEL" ] && PI_ARGS+=(--model "$PLANNER_MODEL")

pi "${PI_ARGS[@]}" \
   --system-prompt "$(cat "$ISSUELY_META_DIR/core_prompts/planner_agent.tpl")" \
   "$INITIAL_MESSAGE"


# Planner 后置校验
if [ ! -d "$ISSUES_DIR" ] || [ -z "$(ls -A "$ISSUES_DIR" 2>/dev/null)" ] \
   || [ ! -d "$DOCS_DIR" ]; then
  echo
  echo "⚠️ [Issuely] 未检测到合法的 issues/ 或 docs/ 产物，规划阶段未完成。"
  echo "   你可以重新运行 ./start.sh 重试。"
  exit 1
fi

if ! node "$ISSUELY_META_DIR/bin/status_manager.js" validate \
        --workspace-dir "$WORKSPACE" --json > "$LOG_DIR/.validate.json" 2>&1; then
  echo
  echo "⚠️ [Issuely] Planner 产物校验未通过："
  if command -v jq >/dev/null 2>&1; then
    jq -r '.problems[]? | "  - \(.type): \(.message)"' "$LOG_DIR/.validate.json" || cat "$LOG_DIR/.validate.json"
  else
    cat "$LOG_DIR/.validate.json"
  fi
  echo "请修正后重新运行 ./start.sh"
  exit 1
fi

ISSUE_COUNT=$(ls -1 "$ISSUES_DIR" 2>/dev/null | grep -cE '^[0-9]{3}-.*\.md$' || echo 0)

echo
echo "=========================================================="
echo " ✅ 规划落盘成功"
echo "=========================================================="
echo "   设计文档：  $DOCS_DIR/"
echo "   任务包：    $ISSUES_DIR/  (共 $ISSUE_COUNT 个 issue)"
echo
echo " 下一步："
echo "   1) 翻翻 $ISSUES_DIR/ 看看 issue 是否符合预期"
echo "   2) 满意了就跑：./start.sh dev"
echo "      （这会启动 dev/review 双 agent 自动开发与审查；"
echo "        中断后再次执行 ./start.sh dev 即可续跑，不会丢数据）"
echo "   3) 若需重头规划：./start.sh 然后选择 [r] 重新规划"
echo "=========================================================="
exit 0
