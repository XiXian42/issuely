#!/usr/bin/env bash
# Issuely 端到端集成测试。
# 不真的调 LLM——把 pi 替换成一个可控的 fake，让 dev/review 直接通过状态机推进，
# 从而验证：
#   - config.json 加载与路径解析
#   - 模板渲染 (无 shell 内插)
#   - run_while 调度 + dev/review 串行 + dev.done/review.done 立标
#   - .issuely 符号链接 (全局共享) 也能跑通
#   - PI_TOOLS 可配置；空时 pi 命令不带 --tools
#   - Claude 非交互模式默认使用 auto 权限；Codex 权限类参数默认不传；显式配置可覆盖

set -u

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
META_SRC="$REPO_ROOT/.issuely"

PASS=0
FAIL=0
TMP_ROOT_RAW="$(mktemp -d "${TMPDIR:-/tmp}/issuely-e2e.XXXXXX")"
# realpath ：macOS 的 /tmp 本身就是符号链接，loader 会走 realpath，
# 断言侧要跟它保持一致。
TMP_ROOT="$(cd "$TMP_ROOT_RAW" && pwd -P)"
TEST_HOME="$TMP_ROOT/home-empty"
mkdir -p "$TEST_HOME"
export HOME="$TEST_HOME"
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

assert_file_not_exists() {
  if [ ! -e "$1" ]; then ok "absent: $1"
  else ng "unexpected file: $1"; fi
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

if echo "$PROMPT" | grep -q "Issue Refine Agent"; then
  issue_file="${REFINE_ISSUE_FILE:-}"
  if [ -z "$issue_file" ]; then
    issue_file="$(printf '%s\n' "$PROMPT" | sed -n 's/.*issue：`\([^`]*\)`.*/\1/p' | head -n 1)"
  fi
  if [ -n "$issue_file" ] && [ -f "$WORKSPACE/issues/$issue_file" ]; then
    perl -0pi -e 's/^\[complex-issue\]\n\n?//m' "$WORKSPACE/issues/$issue_file"
    {
      echo
      echo "## refined $issue_file"
      echo "- removed [complex-issue]"
    } >> "$WORKSPACE/docs/issue-refine-report.md"
  fi
  exit 0
fi

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
echo "$out" | grep -q "WORKSPACE_REL='ws'" && ok "config exports workspace relative path" || ng "workspace rel"
echo "$out" | grep -q "DOCS_DIR_REL='ws/docs'" && ok "config exports docs relative path" || ng "docs rel"
# 确保 config.json 中是相对路径 (可移植)
grep -q '"workspace": "ws"' "$PROJ1/config.json" && ok "workspace stored as relative" \
  || ng "workspace should be relative in config.json"
GLOBAL_HOME="$TMP_ROOT/home"
mkdir -p "$GLOBAL_HOME/.issuely"
cat > "$GLOBAL_HOME/.issuely/config.json" <<'JSON'
{
  "roles": {
    "planner": {
      "agent": "omp",
      "model": "planner-model",
      "thinking": "medium"
    },
    "review": {
      "agent": "claude",
      "model": "review-model",
      "thinking": "high"
    }
  }
}
JSON
out="$(HOME="$GLOBAL_HOME" ISSUELY_PROJECT_DIR="$PROJ1" node "$META_SRC/lib/config.cjs" print-shell)"
echo "$out" | grep -q "PLANNER_AGENT='omp'" && ok "global config overrides planner agent" || ng "planner agent global override"
echo "$out" | grep -q "PLANNER_MODEL='planner-model'" && ok "global config overrides planner model" || ng "planner model global override"
echo "$out" | grep -q "REVIEW_AGENT='claude'" && ok "global config overrides review agent" || ng "review agent global override"
echo "$out" | grep -q "REVIEW_THINKING='high'" && ok "global config exports review thinking" || ng "review thinking global override"

PROJ_UNSAFE="$TMP_ROOT/proj-unsafe"
mkdir -p "$PROJ_UNSAFE"
ln -s "$META_SRC" "$PROJ_UNSAFE/.issuely"
echo '{"workspace":".."}' > "$PROJ_UNSAFE/config.json"
set +e
out="$(ISSUELY_PROJECT_DIR="$PROJ_UNSAFE" node "$META_SRC/lib/config.cjs" print-shell 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "unsafe workspace path"; then
  ok "config rejects workspace outside project"
else
  ng "unsafe workspace should be rejected (rc=$rc, out=$out)"
fi

# ─────────────────────────────────────────────────────────────────────────
# 2. .issuely 符号链接 / 全局共享 (B)
# ─────────────────────────────────────────────────────────────────────────
note "2. .issuely as symlink (global share)"
[ -L "$PROJ1/.issuely" ] && ok ".issuely is a symlink" || ng ".issuely symlink missing"

# 在 PROJ1 (符号链接 .issuely) 下能正常 print-shell
out="$(ISSUELY_PROJECT_DIR="$PROJ1" node "$META_SRC/lib/config.cjs" print-shell)"
echo "$out" | grep -q "META_DIR='$META_SRC'" && ok "META_DIR resolves through symlink" \
  || ng "META_DIR resolution: $(echo "$out" | grep META_DIR)"
WRAPPER_OUT="$(cd "$PROJ1" && HOME="$GLOBAL_HOME" ISSUELY_META_DIR="$META_SRC" "$REPO_ROOT/bin/issuely" status)"
if echo "$WRAPPER_OUT" | grep -q "global config :" && echo "$WRAPPER_OUT" | grep -q "review-model"; then
  ok "issuely status shows merged role config"
else
  ng "issuely status should show merged config"
fi

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

# Claude 非交互模式需要 auto 权限，否则写文件请求无法弹窗审批；Codex 权限类参数仍默认空
PROJ_AGENT_FLAGS="$TMP_ROOT/proj-agent-flags"
mkdir -p "$PROJ_AGENT_FLAGS/workspace/issues"
ln -s "$META_SRC" "$PROJ_AGENT_FLAGS/.issuely"
cat > "$PROJ_AGENT_FLAGS/workspace/issues/000-stub.md" <<'ISS'
# Issue 000 — stub
## 目标
do nothing
## 不做什么
none
## 输入 / 依赖
none
## 输出 / 产物
src/x.txt(new)
## 检查方法
true
## 完成标准
passed
ISS
cat > "$PROJ_AGENT_FLAGS/config.json" <<'JSON'
{
  "workspace": "workspace",
  "roles": {
    "dev": {
      "agent": "claude",
      "model": null,
      "thinking": null
    }
  }
}
JSON

out="$(ISSUELY_PROJECT_DIR="$PROJ_AGENT_FLAGS" node "$META_SRC/lib/config.cjs" print-shell)"
echo "$out" | grep -q "CLAUDE_PERMISSION_MODE='auto'" && ok "Claude permission mode defaults auto" || ng "Claude permission mode should default auto"
echo "$out" | grep -q "CODEX_SANDBOX=''" && ok "Codex sandbox defaults empty" || ng "Codex sandbox should default empty"
echo "$out" | grep -q "CODEX_APPROVAL=''" && ok "Codex approval defaults empty" || ng "Codex approval should default empty"

FAKE_CLAUDE_BIN="$TMP_ROOT/fake-claude-bin"
mkdir -p "$FAKE_CLAUDE_BIN"
cat > "$FAKE_CLAUDE_BIN/claude" <<'FAKE_CLAUDE'
#!/usr/bin/env bash
LOG="${ISSUELY_FAKE_LOG:-/tmp/issuely-fake-claude.log}"
{
  echo "--- claude call ---"
  for a in "$@"; do printf '  arg: %s\n' "$a"; done
} >> "$LOG"
exit 0
FAKE_CLAUDE
chmod +x "$FAKE_CLAUDE_BIN/claude"

FAKE_CLAUDE_LOG="$TMP_ROOT/fake-claude.log"
: > "$FAKE_CLAUDE_LOG"
ISSUELY_FAKE_LOG="$FAKE_CLAUDE_LOG" \
ISSUELY_PROJECT_DIR="$PROJ_AGENT_FLAGS" \
PATH="$FAKE_CLAUDE_BIN:$PATH" \
"$META_SRC/bin/run_dev.sh" >/dev/null 2>&1 || true

if grep -A1 -- "--permission-mode" "$FAKE_CLAUDE_LOG" | grep -q "auto"; then
  ok "Claude default invocation passes --permission-mode auto"
else
  ng "Claude default invocation should pass --permission-mode auto"
fi

cat > "$PROJ_AGENT_FLAGS/config.json" <<'JSON'
{
  "workspace": "workspace",
  "roles": {
    "dev": {
      "agent": "claude",
      "model": null,
      "thinking": null
    }
  },
  "agents": {
    "claude": {
      "permissionMode": "acceptEdits"
    }
  }
}
JSON
: > "$FAKE_CLAUDE_LOG"
ISSUELY_FAKE_LOG="$FAKE_CLAUDE_LOG" \
ISSUELY_PROJECT_DIR="$PROJ_AGENT_FLAGS" \
PATH="$FAKE_CLAUDE_BIN:$PATH" \
"$META_SRC/bin/run_dev.sh" >/dev/null 2>&1 || true

if grep -A1 -- "--permission-mode" "$FAKE_CLAUDE_LOG" | grep -q "acceptEdits"; then
  ok "Claude explicit permission mode is passed"
else
  ng "Claude explicit permission mode missing"
fi

PROJ_CUSTOM="$TMP_ROOT/proj-custom-workspace"
mkdir -p "$PROJ_CUSTOM/ws/issues"
ln -s "$META_SRC" "$PROJ_CUSTOM/.issuely"
cat > "$PROJ_CUSTOM/ws/issues/000-stub.md" <<'ISS'
# Issue 000 — stub
## 目标
custom workspace
## 不做什么
none
## 输入 / 依赖
none
## 输出 / 产物
src/custom.txt(new)
## 检查方法
true
## 完成标准
passed
ISS
echo '{"workspace":"ws","tools":""}' > "$PROJ_CUSTOM/config.json"
FAKE_LOG="$TMP_ROOT/fake-pi-custom-workspace.log"
: > "$FAKE_LOG"
ISSUELY_FAKE_LOG="$FAKE_LOG" \
ISSUELY_PROJECT_DIR="$PROJ_CUSTOM" \
PATH="$FAKE_BIN:$PATH" \
"$META_SRC/bin/run_dev.sh" >/dev/null 2>&1 || true
assert_file_exists "$PROJ_CUSTOM/ws/status.md"
assert_file_not_exists "$PROJ_CUSTOM/workspace/status.md"
if grep -q -- '--workspace-dir "ws"' "$FAKE_LOG"; then
  ok "prompt renders custom workspace path"
else
  ng "prompt should render custom workspace path"
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
echo "# prd" > "$PROJ_E2E/workspace/docs/prd.md"
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
# 5. dev 模式（./start.sh dev）：删 done 后再跑能重立
# ─────────────────────────────────────────────────────────────────────────
run_dev_subcmd_test() {
  local subcmd="$1" out="$2" label="$3"
  : > "$FAKE_LOG"
  rm -f "$PROJ_E2E/workspace/review.done"
  ISSUELY_FAKE_LOG="$FAKE_LOG" \
  ISSUELY_PROJECT_DIR="$PROJ_E2E" \
  PATH="$FAKE_BIN:$PATH" \
  "$REPO_ROOT/start.sh" "$subcmd" >"$out" 2>&1
  local rc=$?
  assert_eq "$rc" "0" "start.sh $subcmd exits 0 ($label)"
  assert_file_exists "$PROJ_E2E/workspace/review.done"
  if grep -q "启动 run_while" "$out" \
     && ! grep -q "请告诉 Issuely\|一句话需求" "$out"; then
    ok "$label skips intake"
  else
    ng "$label unexpected output"
    tail -n 20 "$out"
  fi
}

note "5. start.sh dev skips intake"
run_dev_subcmd_test "dev" "$TMP_ROOT/dev.out" "start.sh dev"

# ─────────────────────────────────────────────────────────────────────────
# 6. start.sh dev 在没有 issues/ 时应明确报错
# ─────────────────────────────────────────────────────────────────────────
note "6. start.sh dev without issues/"
PROJ_EMPTY="$TMP_ROOT/proj-empty"
mkdir -p "$PROJ_EMPTY"
ln -s "$META_SRC" "$PROJ_EMPTY/.issuely"
echo '{"workspace":"workspace"}' > "$PROJ_EMPTY/config.json"

set +e
out="$(ISSUELY_PROJECT_DIR="$PROJ_EMPTY" "$REPO_ROOT/start.sh" dev 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ] && echo "$out" | grep -q "issues/"; then
  ok "start.sh dev errors clearly without issues/"
else
  ng "start.sh dev should error without issues/ (rc=$rc, out=$out)"
fi

# ─────────────────────────────────────────────────────────────────────────
# 6b. run_while 在 issue 文件名不可调度时应提前失败，而不是进入 idle 死锁
# ─────────────────────────────────────────────────────────────────────────
note "6b. run_while issue preflight"

PROJ_INVALID_ISSUES="$TMP_ROOT/proj-invalid-issues"
mkdir -p "$PROJ_INVALID_ISSUES/workspace/issues"
ln -s "$META_SRC" "$PROJ_INVALID_ISSUES/.issuely"
echo '{"workspace":"workspace","tools":""}' > "$PROJ_INVALID_ISSUES/config.json"
cat > "$PROJ_INVALID_ISSUES/workspace/issues/not-an-issue.md" <<'ISS'
# invalid issue file
ISS

set +e
ISSUELY_PROJECT_DIR="$PROJ_INVALID_ISSUES" \
PATH="$FAKE_BIN:$PATH" \
"$META_SRC/bin/run_while.sh" >"$TMP_ROOT/invalid-issues.out" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ] \
   && grep -q "issue 目录不可调度" "$TMP_ROOT/invalid-issues.out" \
   && grep -q "invalid-issue-file: not-an-issue.md" "$TMP_ROOT/invalid-issues.out"; then
  ok "run_while fails fast on invalid issue file names"
else
  ng "run_while should fail fast on invalid issue file names (rc=$rc)"
  cat "$TMP_ROOT/invalid-issues.out"
fi

# ─────────────────────────────────────────────────────────────────────────
# 7. 六位 issue 编号与 issue refine
# ─────────────────────────────────────────────────────────────────────────
note "7. six-digit issues and issue refine"

PROJ_REFINE="$TMP_ROOT/proj-refine"
mkdir -p "$PROJ_REFINE"
ln -s "$META_SRC" "$PROJ_REFINE/.issuely"
echo '{"workspace":"workspace","tools":""}' > "$PROJ_REFINE/config.json"
mkdir -p "$PROJ_REFINE/workspace/issues" "$PROJ_REFINE/workspace/docs"
echo "# prd" > "$PROJ_REFINE/workspace/docs/prd.md"
echo "# spec" > "$PROJ_REFINE/workspace/docs/spec-project.md"
echo "# style" > "$PROJ_REFINE/workspace/docs/coding-style.md"
cat > "$PROJ_REFINE/workspace/issues/000100-bootstrap.md" <<'ISS'
# Issue 000100 — bootstrap

## 目标
bootstrap

## 不做什么

## 输入 / 依赖

## 相关 issue

## 输出 / 产物
workspace/src/bootstrap.txt(new)

## 集成要求

## 检查方法
true

## 完成标准
passed
ISS
cat > "$PROJ_REFINE/workspace/issues/000200-complex-flow.md" <<'ISS'
# Issue 000200 — complex flow

[complex-issue]

## 目标
complex

## 不做什么

## 输入 / 依赖

## 相关 issue

## 输出 / 产物
workspace/src/flow.txt(new)

## 集成要求

## 检查方法
true

## 完成标准
passed
ISS

v="$(node "$META_SRC/bin/status_manager.js" validate --workspace-dir "$PROJ_REFINE/workspace" --json)"
echo "$v" | grep -q '"ok": true' && ok "validate accepts six-digit issue files" || { ng "six-digit validate failed: $v"; }

FAKE_LOG="$TMP_ROOT/fake-pi-refine.log"
: > "$FAKE_LOG"
ISSUELY_FAKE_LOG="$FAKE_LOG" \
ISSUELY_PROJECT_DIR="$PROJ_REFINE" \
PATH="$FAKE_BIN:$PATH" \
"$REPO_ROOT/start.sh" issue refine >"$TMP_ROOT/refine.out" 2>&1
rc=$?
assert_eq "$rc" "0" "start.sh issue refine exits 0"
if grep -Rsl -- '^\[complex-issue\]$' "$PROJ_REFINE/workspace/issues" >/dev/null 2>&1; then
  ng "issue refine should remove all [complex-issue] markers"
else
  ok "issue refine removes [complex-issue] markers"
fi
assert_file_exists "$PROJ_REFINE/workspace/docs/issue-refine-report.md"
assert_file_not_exists "$PROJ_REFINE/workspace/docs/issue-refine-plan.md"

# ─────────────────────────────────────────────────────────────────────────
# 8. tracking docs lint + blocked state recovery
# ─────────────────────────────────────────────────────────────────────────
note "8. tracking docs lint and blocked recovery"

PROJ_STATE="$TMP_ROOT/proj-state"
mkdir -p "$PROJ_STATE/workspace/issues" "$PROJ_STATE/workspace/docs"
ln -s "$META_SRC" "$PROJ_STATE/.issuely"
echo '{"workspace":"workspace","tools":""}' > "$PROJ_STATE/config.json"
echo "# prd" > "$PROJ_STATE/workspace/docs/prd.md"
echo "# spec" > "$PROJ_STATE/workspace/docs/spec-project.md"
echo "# style" > "$PROJ_STATE/workspace/docs/coding-style.md"
cat > "$PROJ_STATE/workspace/issues/000100-blocked.md" <<'ISS'
# Issue 000100 — blocked

## 目标
blocked

## 不做什么

## 输入 / 依赖

## 相关 issue

## 输出 / 产物
workspace/docs/test-migration-matrix.md(mod)

## 集成要求

## 检查方法
true

## 完成标准
passed
ISS

set +e
v="$(node "$META_SRC/bin/status_manager.js" validate --workspace-dir "$PROJ_STATE/workspace" --json 2>&1)"
rc=$?
set -e
if [ "$rc" -ne 0 ] && echo "$v" | grep -q '"forbidden-doc-output"'; then
  ok "validate rejects mutable ordinary docs output"
else
  ng "validate should reject ordinary docs output (rc=$rc, out=$v)"
fi

perl -0pi -e 's#workspace/docs/test-migration-matrix\.md\(mod\)#workspace/docs/_tracking-test-migration-matrix.md(mod)#' "$PROJ_STATE/workspace/issues/000100-blocked.md"
v="$(node "$META_SRC/bin/status_manager.js" validate --workspace-dir "$PROJ_STATE/workspace" --json)"
echo "$v" | grep -q '"ok": true' && ok "validate accepts _tracking docs output" || { ng "tracking docs validate failed: $v"; }

node "$META_SRC/bin/status_manager.js" append begin --issue 000100 --workspace-dir "$PROJ_STATE/workspace" --json >/dev/null
node "$META_SRC/bin/status_manager.js" append blocked --issue 000100 \
     --message "waiting for fixture" --workspace-dir "$PROJ_STATE/workspace" --json >/dev/null
next="$(node "$META_SRC/bin/status_manager.js" next --role dev --workspace-dir "$PROJ_STATE/workspace" --json)"
action="$(node -e "process.stdout.write(JSON.parse(process.argv[1]).action)" "$next")"
assert_eq "$action" "resolve-blocked" "next dev triages blocked issue"

node "$META_SRC/bin/status_manager.js" append unblocked --issue 000100 \
     --message "fixture exists" --workspace-dir "$PROJ_STATE/workspace" --json >/dev/null
next="$(node "$META_SRC/bin/status_manager.js" next --role dev --workspace-dir "$PROJ_STATE/workspace" --json)"
action="$(node -e "process.stdout.write(JSON.parse(process.argv[1]).action)" "$next")"
assert_eq "$action" "continue-dev" "unblocked issue resumes dev"

PROJ_RESOLVE="$TMP_ROOT/proj-resolve"
mkdir -p "$PROJ_RESOLVE/workspace/issues"
ln -s "$META_SRC" "$PROJ_RESOLVE/.issuely"
echo '{"workspace":"workspace","tools":""}' > "$PROJ_RESOLVE/config.json"
cat > "$PROJ_RESOLVE/workspace/issues/000100-stuck.md" <<'ISS'
# Issue 000100 — stuck

## 目标
stuck

## 不做什么

## 输入 / 依赖

## 相关 issue

## 输出 / 产物
workspace/src/stuck.txt(new)

## 集成要求

## 检查方法
true

## 完成标准
passed
ISS
cat > "$PROJ_RESOLVE/workspace/issues/000200-cover.md" <<'ISS'
# Issue 000200 — cover

## 目标
cover

## 不做什么

## 输入 / 依赖

## 相关 issue

## 输出 / 产物
workspace/src/cover.txt(new)

## 集成要求

## 检查方法
true

## 完成标准
passed
ISS
node "$META_SRC/bin/status_manager.js" append begin --issue 000100 --workspace-dir "$PROJ_RESOLVE/workspace" --json >/dev/null
node "$META_SRC/bin/status_manager.js" append blocked --issue 000100 \
     --message "superseded by cover issue" --workspace-dir "$PROJ_RESOLVE/workspace" --json >/dev/null
node "$META_SRC/bin/status_manager.js" append begin --issue 000200 --workspace-dir "$PROJ_RESOLVE/workspace" --json >/dev/null
node "$META_SRC/bin/status_manager.js" append done --issue 000200 \
     --files "src/cover.txt(new)" --workspace-dir "$PROJ_RESOLVE/workspace" --json >/dev/null
node "$META_SRC/bin/status_manager.js" append review-begin --issue 000200 --workspace-dir "$PROJ_RESOLVE/workspace" --json >/dev/null
node "$META_SRC/bin/status_manager.js" append reviewed --issue 000200 --workspace-dir "$PROJ_RESOLVE/workspace" --json >/dev/null
node "$META_SRC/bin/status_manager.js" append resolved-by --issue 000100 --resolved-by 000200 \
     --message "covered by reviewed issue" --workspace-dir "$PROJ_RESOLVE/workspace" --json >/dev/null
v="$(node "$META_SRC/bin/status_manager.js" validate --workspace-dir "$PROJ_RESOLVE/workspace" --json)"
echo "$v" | grep -q '"ok": true' && ok "validate accepts resolved-by closure" || { ng "resolved-by validate failed: $v"; }
next="$(node "$META_SRC/bin/status_manager.js" next --role dev --workspace-dir "$PROJ_RESOLVE/workspace" --json)"
action="$(node -e "process.stdout.write(JSON.parse(process.argv[1]).action)" "$next")"
assert_eq "$action" "touch-dev-done" "resolved-by counts as closed for dev"

PROJ_BLOCKED_RUN="$TMP_ROOT/proj-blocked-run"
mkdir -p "$PROJ_BLOCKED_RUN/workspace/issues"
ln -s "$META_SRC" "$PROJ_BLOCKED_RUN/.issuely"
echo '{"workspace":"workspace","tools":""}' > "$PROJ_BLOCKED_RUN/config.json"
cat > "$PROJ_BLOCKED_RUN/workspace/issues/000100-blocked-run.md" <<'ISS'
# Issue 000100 — blocked run

## 目标
blocked run

## 不做什么

## 输入 / 依赖

## 相关 issue

## 输出 / 产物
workspace/src/blocked-run.txt(new)

## 集成要求

## 检查方法
true

## 完成标准
passed
ISS
node "$META_SRC/bin/status_manager.js" append begin --issue 000100 --workspace-dir "$PROJ_BLOCKED_RUN/workspace" --json >/dev/null
node "$META_SRC/bin/status_manager.js" append blocked --issue 000100 \
     --message "external prerequisite missing" --workspace-dir "$PROJ_BLOCKED_RUN/workspace" --json >/dev/null
set +e
ISSUELY_PROJECT_DIR="$PROJ_BLOCKED_RUN" \
PATH="$FAKE_BIN:$PATH" \
"$META_SRC/bin/run_while.sh" >"$TMP_ROOT/blocked-run.out" 2>&1
rc=$?
set -e
if [ "$rc" -ne 0 ] \
   && grep -q "全部阻塞" "$TMP_ROOT/blocked-run.out" \
   && grep -q "000100-blocked-run.md" "$TMP_ROOT/blocked-run.out"; then
  ok "run_while reports blocked terminal state"
else
  ng "run_while should report blocked terminal state (rc=$rc)"
  cat "$TMP_ROOT/blocked-run.out"
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
