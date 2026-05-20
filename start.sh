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
#   ./start.sh -c        续跑模式：跳过规划，直接进入 run_while
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
MODE="interactive"
while [ $# -gt 0 ]; do
  case "$1" in
    -c|--continue) MODE="continue" ;;
    -h|--help)
      cat <<EOF
Issuely — 全程软件工程 Agent

Usage:
  ./start.sh           交互模式：收集需求 → 生成 docs/ + issues/ → 自动开发与审查
  ./start.sh -c        续跑模式：跳过规划，直接重启 run_while
  ./start.sh -h        显示此帮助

Project layout:
  config.json          项目配置（单一事实源）
  workspace/docs/      系统设计与规范（规划阶段生成）
  workspace/issues/    有序任务包
  workspace/status.md  进度状态机（请勿手改）
  workspace/memo.md    项目记忆
  .issuely/logs/       运行日志（续跑时自动产生）

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
  echo "[Issuely] 启动 run_while …（Ctrl+C 可中断；中断后用 ./start.sh -c 续跑）"
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
    echo "   3) 续跑（不会丢数据）：./start.sh -c"
    echo "   4) 重新规划（会清空 workspace/）：./start.sh"
    echo "=========================================================="
  fi
  return "$rc"
}

# ─────────────────────────────────────────────────────────────
# 续跑模式
# ─────────────────────────────────────────────────────────────
if [ "$MODE" = "continue" ]; then
  if [ ! -d "$ISSUES_DIR" ] || [ -z "$(ls -A "$ISSUES_DIR" 2>/dev/null)" ]; then
    echo "[Issuely] 续跑模式需要已有规划产物，但未发现 issues/。请先运行 ./start.sh 规划。" >&2
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

decide_action() {
  if [ "$HAS_DEV_DONE" = 1 ] && [ "$HAS_REVIEW_DONE" = 1 ]; then
    echo "[Info] 上一轮已完整交付（dev.done + review.done 均存在）。"
    echo "  [r] 重新规划（清空 workspace/）"
    echo "  [q] 退出，仅查看产物"
    read -p "选择 (r/q) [默认 q]: " ANS
    case "${ANS:-q}" in
      r|R) return 1 ;;
      *)   exit 0 ;;
    esac
  elif [ "$HAS_STATUS" = 1 ]; then
    echo "[Info] 检测到进行中的项目（status.md 存在）。"
    echo "  [c] 续跑（推荐）"
    echo "  [r] 重新规划（清空 workspace/）"
    echo "  [q] 退出"
    read -p "选择 (c/r/q) [默认 c]: " ANS
    case "${ANS:-c}" in
      c|C) return 2 ;;
      r|R) return 1 ;;
      *)   exit 0 ;;
    esac
  elif [ "$HAS_ISSUES" = 1 ]; then
    echo "[Info] 已生成 issues/，但尚未开始开发。"
    echo "  [c] 直接开始开发（推荐）"
    echo "  [r] 重新规划（清空 workspace/）"
    echo "  [q] 退出"
    read -p "选择 (c/r/q) [默认 c]: " ANS
    case "${ANS:-c}" in
      c|C) return 2 ;;
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

if [ "$DECISION" = 2 ]; then
  run_while_with_log
  exit $?
fi

if [ "$DECISION" = 1 ]; then
  echo "[Info] 正在清空 workspace/ …"
  rm -rf "$WORKSPACE"
  mkdir -p "$WORKSPACE"
fi

# ─────────────────────────────────────────────────────────────
# 收集需求
# ─────────────────────────────────────────────────────────────
echo "💡 请告诉 Issuely，你今天想写点什么？"
echo "----------------------------------------------------------"
read -p "👉 1. 项目名称（例 next-todo）: " IN_PROJECT_NAME
[ -z "$IN_PROJECT_NAME" ] && IN_PROJECT_NAME="my-project"

read -p "👉 2. 技术栈/语言（例 NextJS + React / Python FastAPI / Go / Rust）: " IN_LANGUAGE
[ -z "$IN_LANGUAGE" ] && IN_LANGUAGE="JavaScript (Node.js)"

echo "👉 3. 规划深度："
echo "   [A] 快速规划（推荐）"
echo "   [B] 深度对话"
read -p "选择 (A/B) [默认 A]: " IN_MODE
[ -z "$IN_MODE" ] && IN_MODE="A"

echo "👉 4. 详细描述你的业务需求（越细越好；输入完成按 Ctrl+D 结束）："
echo "----------------------------------------------------------"
RAW_NEED=$(cat)
echo "----------------------------------------------------------"

if [ -z "$RAW_NEED" ]; then
  echo "[Error] 需求描述为空。Issuely 退出。" >&2
  exit 1
fi

# 写 config.json：通过 env 传 originalRequirement，避免任何 shell 内插
RAW_NEED="$RAW_NEED" \
node "$ISSUELY_META_DIR/lib/config.cjs" write \
     --project-dir "$ISSUELY_PROJECT_DIR" \
     --project-name "$IN_PROJECT_NAME" \
     --language "$IN_LANGUAGE" \
     --workspace "$(basename "$WORKSPACE")" \
     --original-requirement-from-env RAW_NEED >/dev/null

# 重新加载（取最新值）
eval "$(node "$ISSUELY_META_DIR/lib/config.cjs" print-shell)"

# 给 Planner 的初始 message：纯 env+stdin 拼，零 shell 内插
INITIAL_MESSAGE="$(PROJECT_NAME="$PROJECT_NAME" LANGUAGE="$LANGUAGE" \
                   MODE_CHOICE="$IN_MODE" RAW_NEED="$RAW_NEED" \
                   node - <<'BUILD_MSG'
process.stdout.write(`## 用户初始化输入
项目名称：${process.env.PROJECT_NAME}
技术栈选型：${process.env.LANGUAGE}
深度模式：${process.env.MODE_CHOICE}
业务原始需求：
${process.env.RAW_NEED}

如果是模式 A（快速规划）：直接调用 write 工具，把 docs/ 与 issues/ 一次性落盘到 workspace/ 下，落盘后输出"规划完毕"并退出。
如果是模式 B（深度对话）：先抛出第 1 个澄清问题，逐轮收敛，待用户确认后再一次性落盘。`);
BUILD_MSG
)"

# 构造 pi 调用参数（C 项：不写死 --tools）
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

echo
echo "🚀 [Issuely] 规划落盘成功！正在启动 dev / review 双 Agent 流水线…"
echo "----------------------------------------------------------"

run_while_with_log
RC=$?

if [ "$RC" -eq 0 ]; then
  echo
  echo "=========================================================="
  echo " 🎉 Issuely 自动化开发与审查工程已顺利竣工！"
  echo "=========================================================="
  echo "   产物源码：    $WORKSPACE/"
  echo "   设计文档：    $DOCS_DIR/"
  echo "   任务包：      $ISSUES_DIR/"
  echo "   进度记录：    $STATUS_PATH"
  echo "   项目记忆：    $MEMO_PATH"
  echo "=========================================================="
fi

exit $RC
