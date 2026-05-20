#!/usr/bin/env bash
set -eo pipefail

# Issuely 调度器：dev / review 串行循环，至 dev.done && review.done 双立才退出。
# 状态推进完全由 status_manager 驱动；本脚本只负责调度和死锁防护。

DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=./_runner.sh
. "$DIR/_runner.sh"
issuely_load_config

DEADLOCK_COUNTER=0
MAX_DEADLOCK_ROUNDS=3
ROUND=0

status_hash() {
  if [ -f "$STATUS_PATH" ]; then
    STATUS_FILE="$STATUS_PATH" node -e '
const fs = require("fs");
const crypto = require("crypto");
process.stdout.write(crypto.createHash("sha256").update(fs.readFileSync(process.env.STATUS_FILE)).digest("hex"));
'
  else
    printf 'missing'
  fi
}

done_state() {
  local d="0" r="0"
  [ -f "$DEV_DONE" ]    && d="1"
  [ -f "$REVIEW_DONE" ] && r="1"
  printf '%s:%s' "$d" "$r"
}

deadlock_exit() {
  printf '\n'
  echo "=========================================================="
  echo "⚠️  [run_while] 状态连续 $DEADLOCK_COUNTER 轮无变化，判定为死锁，已停止。"
  echo "----------------------------------------------------------"
  echo " 你可以："
  echo "   1) 查看最近状态：tail -n 30 \"$STATUS_PATH\""
  echo "   2) 看是否有 blocked：grep blocked \"$STATUS_PATH\" || true"
  echo "   3) 续跑（不会丢数据）：./start.sh dev"
  echo "   4) 修正 issue 后再续跑：编辑 \$ISSUES_DIR/NNN-*.md 后 ./start.sh dev"
  echo "=========================================================="
  exit 1
}

echo "[run_while] 启动循环调度"
echo "  project   : $ISSUELY_PROJECT_DIR"
echo "  workspace : $WORKSPACE"
echo "  issues    : $ISSUES_DIR"
echo "  status    : $STATUS_PATH"

while true; do
  if [ -f "$DEV_DONE" ] && [ -f "$REVIEW_DONE" ]; then
    echo "[run_while] dev.done && review.done 已立——项目交付完成。"
    exit 0
  fi

  ROUND=$((ROUND + 1))
  printf '\n================ Round %d (deadlock %d/%d) ================\n' \
         "$ROUND" "$DEADLOCK_COUNTER" "$MAX_DEADLOCK_ROUNDS"
  before_hash="$(status_hash)"
  before_done="$(done_state)"

  if [ ! -f "$DEV_DONE" ]; then
    echo "[run_while] dev agent (${DEV_MODEL:-<pi default>})"
    if ! "$DIR/run_dev.sh"; then
      RC=$?
      echo "[run_while] dev 退出非零 (rc=$RC)，本轮跳过 dev，继续 review。"
    fi
  else
    echo "[run_while] dev.done 已立，跳过 dev。"
  fi

  if [ ! -f "$REVIEW_DONE" ]; then
    echo "[run_while] review agent (${REVIEW_MODEL:-<pi default>})"
    if ! "$DIR/run_review.sh"; then
      RC=$?
      echo "[run_while] review 退出非零 (rc=$RC)，进入死锁判定。"
    fi
  else
    echo "[run_while] review.done 已立，跳过 review。"
  fi

  after_hash="$(status_hash)"
  after_done="$(done_state)"

  if [ "$before_hash" = "$after_hash" ] && [ "$before_done" = "$after_done" ]; then
    DEADLOCK_COUNTER=$((DEADLOCK_COUNTER + 1))
    echo "[run_while] 本轮无进展（计数 $DEADLOCK_COUNTER/$MAX_DEADLOCK_ROUNDS）"
    if [ "$DEADLOCK_COUNTER" -ge "$MAX_DEADLOCK_ROUNDS" ]; then
      deadlock_exit
    fi
  else
    DEADLOCK_COUNTER=0
  fi

  sleep 1
done
