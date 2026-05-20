#!/usr/bin/env bash
# 把仓库内的 hooks 目录注册给 git，无需复制文件。
# 克隆 / 拉取 Issuely 仓库后建议执行一次：
#   ./.issuely/bin/install_hooks.sh

set -eo pipefail

DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_ROOT="$(cd "$DIR/.." && pwd)"

if ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "[install_hooks] 当前目录不是 git 仓库：$REPO_ROOT" >&2
  exit 1
fi

# 用相对路径，方便 .issuely 做成符号链接到全局位置时也能正确解析
git -C "$REPO_ROOT" config core.hooksPath ".issuely/git-hooks"

# 确保 hook 可执行
chmod +x "$DIR/git-hooks/"*

echo "[install_hooks] 已启用 .issuely/git-hooks/"
echo "[install_hooks] 当前 hooks: $(ls "$DIR/git-hooks")"
