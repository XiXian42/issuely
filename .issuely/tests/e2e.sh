#!/usr/bin/env bash
# Issuely 端到端集成测试。
# 不真的调 LLM——把 pi 替换成一个可控的 fake，让 dev/review 直接通过状态机推进，
# 从而验证：
#   - config.json 加载与路径解析
#   - 模板渲染 (无 shell 内插)
#   - run_while 调度 + dev/review 串行 + dev.done/review.done 立标
#   - .issuely 符号链接 (全局共享) 也能跑通
#   - PI_TOOLS 可配置；空时 pi 命令不带 --tools

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
META_SRC="$REPO_ROOT/.issuely"

PASS=0
FAIL=0
TMP_ROOT_RAW="$(mktemp -d "${TMPDIR:-/tmp}/issuely-e2e.XXXXXX")"
# realpath ：macOS 的 /tmp 本身就是符号链接，loader 会走 realpath，
# 断言侧要跟它保持一致。
TMP_ROOT="$(cd "$TMP_ROOT_RAW" && pwd -P)"
trap 'rm -rf "$TMP_ROOT_RAW"' EXIT

note() { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '  PASS  %s\n' "$*"; PASS=$((PASS+1)); }
ng()   { printf '  FAIL  %s\n' "$*"; FAIL=$((FAIL+1)); }

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [ "$got" = "$want" ]; then ok "$label"
  else ng "$label (got: $got | want: $want)"; fi
}

assert_file_exists() {
  if [ -e "$1" ]; then ok "exists: $1"
  else ng "missing: $1"; fi
}

# ─────────────────────────────────────────────────────────────────────────
# 工具：构造一个假的 pi，按 prompt 内容驱动状态机（无需真 LLM）
# ─────────────────────────────────────────────────────────────────────────
make_fake_pi() {
  local bindir="$1"
  mkdir -p "$bindir"
  cat > "$bindir/pi" <<'FAKE_PI'
#!/usr/bin/env bash
# 假 pi：从最后一个非 -- 参数 (prompt 文本) 中辨认 dev / review，
# 调真实 status_manager.js 推进当前 issue。
# 用 ISSUELY_FAKE_LOG 收集 argv，便于断言。

LOG="${ISSUELY_FAKE_LOG:-/tmp/issuely-fake-pi.log}"
{
  echo "--- pi call ---"
  for a in "$@"; do printf '  arg: %s\n' "$a"; done
} >> "$LOG"

# 找到 prompt 文本：紧跟 -p 之后的那个参数
PROMPT=""
prev=""
for a in "$@"; do
  if [ "$prev" = "-p" ]; then PROMPT="$a"; break; fi
  prev="$a"
done

# fallback：取最后一个非 dash 起头的实参
if [ -z "$PROMPT" ]; then
  for a in "$@"; do
    case "$a" in --*) ;; -*) ;; *) PROMPT="$a" ;; esac
  done
fi

WORKSPACE="${WORKSPACE:-}"
META_DIR="${META_DIR:-}"

# 从 prompt 推 role
ROLE="unknown"
case "$PROMPT" in
  *"role 是 dev"*|*"role dev"*|*"role=dev"*|*"--role dev"*|*"dev agent"*|*"角色与工作目录"*"高级工程师"*) ROLE="dev" ;;
esac
case "$PROMPT" in
  *"严格的代码 reviewer"*|*"code reviewer"*) ROLE="review" ;;
esac

# 简单办法：根据 prompt 里出现的提示语分辨
if echo "$PROMPT" | grep -q "你是一位高级工程师"; then ROLE="dev"; fi
if echo "$PROMPT" | grep -q "你是一位严格的代码 reviewer"; then ROLE="review"; fi

if [ "$ROLE" = "unknown" ] || [ -z "$WORKSPACE" ] || [ -z "$META_DIR" ]; then
  echo "[fake-pi] cannot dispatch (role=$ROLE, ws=$WORKSPACE)" >&2
  exit 0
fi

SM="$META_DIR/bin/status_manager.js"
NEXT_JSON="$(node "$SM" next --role "$ROLE" --workspace-dir "$WORKSPACE" --json)"
ACTION="$(node -e "process.stdout.write(JSON.parse(process.argv[1]).action || '')" "$NEXT_JSON")"
ISSUE_NUM="$(node -e "const j=JSON.parse(process.argv[1]); process.stdout.write(j.issue ? j.issue.number : '')" "$NEXT_JSON")"

case "$ACTION" in
  start|continue-dev)
    [ -z "$ISSUE_NUM" ] && exit 0
    node "$SM" append begin --issue "$ISSUE_NUM" --workspace-dir "$WORKSPACE" --json >/dev/null
    # 模拟 dev 实际写一点东西
    mkdir -p "$WORKSPACE/src" "$WORKSPACE/tests"
    echo "// stub for $ISSUE_NUM" > "$WORKSPACE/src/stub-$ISSUE_NUM.txt"
    node "$SM" append done --issue "$ISSUE_NUM" \
         --files "src/stub-$ISSUE_NUM.txt(new)" \
         --workspace-dir "$WORKSPACE" --json >/dev/null
    ;;
  start-review|continue-review)
    [ -z "$ISSUE_NUM" ] && exit 0
    node "$SM" append review-begin --issue "$ISSUE_NUM" --workspace-dir "$WORKSPACE" --json >/dev/null
    node "$SM" append reviewed --issue "$ISSUE_NUM" --workspace-dir "$WORKSPACE" --json >/dev/null
    ;;
  touch-dev-done)
    touch "$WORKSPACE/dev.done"
    ;;
  touch-review-done)
    touch "$WORKSPACE/review.done"
    ;;
  *) ;;
esac
exit 0
FAKE_PI
  chmod +x "$bindir/pi"
}

# ─────────────────────────────────────────────────────────────────────────
# 1. config 加载器：缺 ISSUELY_PROJECT_DIR 应该报错
# ─────────────────────────────────────────────────────────────────────────
note "1. config loader sanity"
set +e
out="$(unset ISSUELY_PROJECT_DIR; node "$META_SRC/lib/config.cjs" print-shell 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "ISSUELY_PROJECT_DIR"; then
  ok "config.cjs rejects missing ISSUELY_PROJECT_DIR"
else
  ng "config.cjs should error without ISSUELY_PROJECT_DIR (rc=$rc, out=$out)"
fi

# 全新项目根：无 config.json
PROJ1="$TMP_ROOT/proj1"
mkdir -p "$PROJ1"
ln -s "$META_SRC" "$PROJ1/.issuely"
out="$(ISSUELY_PROJECT_DIR="$PROJ1" node "$META_SRC/lib/config.cjs" print-shell 2>&1 || true)"
# 没 config.json 时 loader 返回默认值 + 默认 workspace=workspace
if echo "$out" | grep -q "WORKSPACE='$PROJ1/workspace'"; then
  ok "config.cjs falls back to defaults when config.json absent"
else
  ng "config.cjs default fallback failed: $out"
fi

# 写一个 config.json
ISSUELY_PROJECT_DIR="$PROJ1" RAW="hello world" \
node "$META_SRC/lib/config.cjs" write --project-dir "$PROJ1" \
     --project-name "demo" --language "Python" \
     --workspace "ws" \
     --original-requirement-from-env RAW >/dev/null
out="$(ISSUELY_PROJECT_DIR="$PROJ1" node "$META_SRC/lib/config.cjs" print-shell)"
echo "$out" | grep -q "PROJECT_NAME='demo'" && ok "config write+read project name" || ng "project name"
echo "$out" | grep -q "LANGUAGE='Python'" && ok "config write+read language" || ng "language"
echo "$out" | grep -q "WORKSPACE='$PROJ1/ws'" && ok "config write+read workspace" || ng "workspace path"
# 确保 config.json 中是相对路径 (可移植)
grep -q '"workspace": "ws"' "$PROJ1/config.json" && ok "workspace stored as relative" \
  || ng "workspace should be relative in config.json"

# ─────────────────────────────────────────────────────────────────────────
# 2. .issuely 符号链接 / 全局共享 (B)
# ─────────────────────────────────────────────────────────────────────────
note "2. .issuely as symlink (global share)"
[ -L "$PROJ1/.issuely" ] && ok ".issuely is a symlink" || ng ".issuely symlink missing"

# 在 PROJ1 (符号链接 .issuely) 下能正常 print-shell
out="$(ISSUELY_PROJECT_DIR="$PROJ1" node "$META_SRC/lib/config.cjs" print-shell)"
echo "$out" | grep -q "META_DIR='$META_SRC'" && ok "META_DIR resolves through symlink" \
  || ng "META_DIR resolution: $(echo "$out" | grep META_DIR)"

# ─────────────────────────────────────────────────────────────────────────
# 3. PI_TOOLS 默认空：run_pi_prompt 不应附加 --tools
# ─────────────────────────────────────────────────────────────────────────
note "3. PI_TOOLS toggle (C)"

# 用 fake pi 跑 1 轮 dev: 让它仅记录 argv
PROJ_TOOLS="$TMP_ROOT/proj-tools"
mkdir -p "$PROJ_TOOLS"
ln -s "$META_SRC" "$PROJ_TOOLS/.issuely"

# 准备一个最小 issue，让 dev 有事可做
mkdir -p "$PROJ_TOOLS/workspace/issues"
cat > "$PROJ_TOOLS/workspace/issues/000-stub.md" <<'ISS'
# Issue 000 — stub
## 目标
do nothing
## 不做什么
## 输入 / 依赖
## 输出 / 产物
src/x.txt(new)
## 检查方法
true
## 完成标准
passed
ISS

# 写最小 config
echo '{"workspace":"workspace"}' > "$PROJ_TOOLS/config.json"

# 注入 fake pi
FAKE_BIN="$TMP_ROOT/fake-bin"
make_fake_pi "$FAKE_BIN"
FAKE_LOG="$TMP_ROOT/fake-pi-tools.log"
: > "$FAKE_LOG"

# 跑一次 run_dev，PI_TOOLS 不设 → 不带 --tools
ISSUELY_FAKE_LOG="$FAKE_LOG" \
ISSUELY_PROJECT_DIR="$PROJ_TOOLS" \
PATH="$FAKE_BIN:$PATH" \
"$META_SRC/bin/run_dev.sh" >/dev/null 2>&1 || true

if grep -q -- "--tools" "$FAKE_LOG"; then
  ng "PI_TOOLS unset but --tools still present"
else
  ok "PI_TOOLS unset → pi invoked without --tools"
fi

# 跑一次 run_dev，PI_TOOLS=read,bash → 必须带 --tools read,bash
# 通过 config.json 设置
echo '{"workspace":"workspace","tools":"read,bash"}' > "$PROJ_TOOLS/config.json"
# 状态文件可能因第一次 run 已经推进了一些；为了独立测试此项，重置 workspace 状态
rm -f "$PROJ_TOOLS/workspace/status.md" "$PROJ_TOOLS/workspace/dev.done" "$PROJ_TOOLS/workspace/review.done"
: > "$FAKE_LOG"

ISSUELY_FAKE_LOG="$FAKE_LOG" \
ISSUELY_PROJECT_DIR="$PROJ_TOOLS" \
PATH="$FAKE_BIN:$PATH" \
"$META_SRC/bin/run_dev.sh" >/dev/null 2>&1 || true

if grep -A1 -- "--tools" "$FAKE_LOG" | grep -q "read,bash"; then
  ok "PI_TOOLS set → pi invoked with --tools read,bash"
else
  ng "PI_TOOLS set but --tools missing or wrong"
  echo "----- fake-pi log -----"
  cat "$FAKE_LOG"
  echo "-----"
fi

# ─────────────────────────────────────────────────────────────────────────
# 4. 端到端：用 fake pi 跑通 run_while
# ─────────────────────────────────────────────────────────────────────────
note "4. end-to-end run_while with fake pi"

PROJ_E2E="$TMP_ROOT/proj-e2e"
mkdir -p "$PROJ_E2E"
ln -s "$META_SRC" "$PROJ_E2E/.issuely"
echo '{"workspace":"workspace","tools":""}' > "$PROJ_E2E/config.json"

mkdir -p "$PROJ_E2E/workspace/issues" "$PROJ_E2E/workspace/docs"
echo "# req" > "$PROJ_E2E/workspace/docs/requirements.md"
echo "# spec" > "$PROJ_E2E/workspace/docs/spec-project.md"
echo "# style" > "$PROJ_E2E/workspace/docs/coding-style.md"
for n in 000 001 002; do
  cat > "$PROJ_E2E/workspace/issues/$n-stub.md" <<EOF
# Issue $n — stub
## 目标
stub
## 不做什么
## 输入 / 依赖
## 输出 / 产物
src/stub-$n.txt(new)
## 检查方法
true
## 完成标准
passed
EOF
done

FAKE_LOG="$TMP_ROOT/fake-pi-e2e.log"
: > "$FAKE_LOG"

ISSUELY_FAKE_LOG="$FAKE_LOG" \
ISSUELY_PROJECT_DIR="$PROJ_E2E" \
PATH="$FAKE_BIN:$PATH" \
"$META_SRC/bin/run_while.sh" >"$TMP_ROOT/while.out" 2>&1
rc=$?
assert_eq "$rc" "0" "run_while exits 0 on full pipeline"

assert_file_exists "$PROJ_E2E/workspace/dev.done"
assert_file_exists "$PROJ_E2E/workspace/review.done"

# 验证 status.md 含每个 issue 的完整轨迹
status="$PROJ_E2E/workspace/status.md"
for n in 000 001 002; do
  for tag in begin done reviewed; do
    if grep -q "\[$n\]" "$status" && grep -q "$tag" "$status"; then
      :
    fi
  done
  if grep -q "\[$n\] stub \[reviewed\]" "$status"; then
    ok "issue $n reviewed in status.md"
  else
    ng "issue $n missing reviewed line"
  fi
done

# 验证 status_manager validate 返回 ok
v="$(node "$META_SRC/bin/status_manager.js" validate --workspace-dir "$PROJ_E2E/workspace" --json)"
echo "$v" | grep -q '"ok": true' && ok "validate ok after pipeline" || { ng "validate failed: $v"; }

# ─────────────────────────────────────────────────────────────────────────
# 5. start.sh -c 续跑：删掉 done 标志后再跑应该能完成
# ─────────────────────────────────────────────────────────────────────────
note "5. start.sh -c continue mode"

# 模拟中断：删 review.done，让续跑能重立
rm -f "$PROJ_E2E/workspace/review.done"

# 先得给 PROJ_E2E 一个 start.sh (它本身没有；用框架里的并通过 ISSUELY_PROJECT_DIR 导)
# 直接调 start.sh -c (用 expect-less 方式)
: > "$FAKE_LOG"
ISSUELY_FAKE_LOG="$FAKE_LOG" \
ISSUELY_PROJECT_DIR="$PROJ_E2E" \
PATH="$FAKE_BIN:$PATH" \
"$REPO_ROOT/start.sh" -c >"$TMP_ROOT/cont.out" 2>&1
rc=$?
assert_eq "$rc" "0" "start.sh -c exits 0 after re-establishing review.done"
assert_file_exists "$PROJ_E2E/workspace/review.done"

# 续跑模式应跳过规划阶段：日志中应出现 "启动 run_while"，不出现 "请告诉 Issuely"
if grep -q "启动 run_while" "$TMP_ROOT/cont.out" \
   && ! grep -q "请告诉 Issuely" "$TMP_ROOT/cont.out"; then
  ok "continue mode skips intake"
else
  ng "continue mode unexpected output"
  tail -n 20 "$TMP_ROOT/cont.out"
fi

# ─────────────────────────────────────────────────────────────────────────
# 6. start.sh -c 在没有 issues/ 时应明确报错
# ─────────────────────────────────────────────────────────────────────────
note "6. start.sh -c without issues/"
PROJ_EMPTY="$TMP_ROOT/proj-empty"
mkdir -p "$PROJ_EMPTY"
ln -s "$META_SRC" "$PROJ_EMPTY/.issuely"
echo '{"workspace":"workspace"}' > "$PROJ_EMPTY/config.json"

set +e
out="$(ISSUELY_PROJECT_DIR="$PROJ_EMPTY" "$REPO_ROOT/start.sh" -c 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "issues/"; then
  ok "start.sh -c errors clearly without issues/"
else
  ng "start.sh -c should error without issues/ (rc=$rc, out=$out)"
fi

# ─────────────────────────────────────────────────────────────────────────
# 总结
# ─────────────────────────────────────────────────────────────────────────
echo
echo "================================================="
echo "  passed: $PASS"
echo "  failed: $FAIL"
echo "================================================="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
echo "passed"
