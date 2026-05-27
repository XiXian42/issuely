#!/usr/bin/env bash
# Issuely installer for macOS / Linux
# Usage: curl -fsSL https://raw.githubusercontent.com/XiXian42/issuely/main/install.sh | bash
set -eo pipefail

ISSUELY_VERSION="0.1.0"
ISSUELY_REPO="https://github.com/XiXian42/issuely"
ISSUELY_ARCHIVE="https://codeload.github.com/XiXian42/issuely/tar.gz/refs/heads/main"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-/dev/stdin}")" 2>/dev/null && pwd || echo "")"
INSTALL_DIR="${ISSUELY_INSTALL_DIR:-${HOME}/.local/share/issuely}"
BIN_DIR="${ISSUELY_BIN_DIR:-${HOME}/.local/bin}"

bold()  { printf "\033[1m%s\033[0m" "$*"; }
green() { printf "\033[32m%s\033[0m" "$*"; }
cyan()  { printf "\033[36m%s\033[0m" "$*"; }
red()   { printf "\033[31m%s\033[0m" "$*"; }
dim()   { printf "\033[2m%s\033[0m" "$*"; }
hr() { echo "  ─────────────────────────────────────────────"; }

need() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "  $(red "✗") Required tool not found: $1"
    exit 1
  fi
}

copy_payload() {
  local src="$1"
  mkdir -p "$INSTALL_DIR"
  cp "$src/start.sh" "$INSTALL_DIR/start.sh"
  cp "$src/README.md" "$INSTALL_DIR/README.md"
  cp "$src/config.example.json" "$INSTALL_DIR/config.example.json"
  cp -R "$src/.issuely" "$INSTALL_DIR/.issuely"
  cp -R "$src/bin" "$INSTALL_DIR/bin"
}

echo ""
echo "  $(bold Issuely) $(dim "v${ISSUELY_VERSION}") — issue-driven agentic development"
echo "  $(dim "$ISSUELY_REPO")"
hr
echo ""

case "$(uname -s)" in
  Darwin|Linux) ;;
  *)
    echo "  $(red "✗") This installer currently supports macOS and Linux only."
    exit 1
    ;;
esac

need bash
need tar
if ! command -v git >/dev/null 2>&1 && ! command -v curl >/dev/null 2>&1; then
  echo "  $(red "✗") Need either git or curl to install Issuely."
  exit 1
fi

mkdir -p "$INSTALL_DIR" "$BIN_DIR"

echo "  Install dir : $(bold "$INSTALL_DIR")"
echo "  Bin dir     : $(bold "$BIN_DIR")"
echo ""

rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/start.sh" && -d "$SCRIPT_DIR/.issuely" && -f "$SCRIPT_DIR/bin/issuely" ]]; then
  echo "  $(cyan "→") Local install from: $SCRIPT_DIR"
  copy_payload "$SCRIPT_DIR"
else
  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/issuely-install.XXXXXX")"
  trap 'rm -rf "$TMP_ROOT"' EXIT
  if command -v git >/dev/null 2>&1; then
    echo "  $(cyan "→") Cloning Issuely…"
    git clone --depth=1 "$ISSUELY_REPO" "$TMP_ROOT/repo" >/dev/null 2>&1
    copy_payload "$TMP_ROOT/repo"
  else
    echo "  $(cyan "→") Downloading Issuely archive…"
    curl -fsSL "$ISSUELY_ARCHIVE" | tar -xz -C "$TMP_ROOT"
    copy_payload "$TMP_ROOT/issuely-main"
  fi
fi

chmod +x "$INSTALL_DIR/start.sh"
chmod +x "$INSTALL_DIR/bin/issuely"
find "$INSTALL_DIR/.issuely/bin" -type f -name '*.sh' -exec chmod +x {} \;

rm -f "$BIN_DIR/issuely"
ln -s "$INSTALL_DIR/bin/issuely" "$BIN_DIR/issuely"

echo "  $(green "✓") Installed issuely → $BIN_DIR/issuely"

auto_path_rc=""
current_shell="$(basename "${SHELL:-bash}")"
case "$current_shell" in
  zsh) auto_path_rc="${ZDOTDIR:-$HOME}/.zshrc" ;;
  bash) auto_path_rc="$HOME/.bashrc" ;;
  *) auto_path_rc="" ;;
esac
if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  path_export="export PATH=\"${BIN_DIR}:\$PATH\""
  if [[ -n "$auto_path_rc" ]] && ! grep -q "$BIN_DIR" "$auto_path_rc" 2>/dev/null; then
    printf "\n# issuely: add ~/.local/bin to PATH\n%s\n" "$path_export" >> "$auto_path_rc"
    echo "  $(green "✓") Added ${BIN_DIR} to PATH in $auto_path_rc"
  fi
  export PATH="${BIN_DIR}:$PATH"
fi

echo ""
"$INSTALL_DIR/.issuely/bin/configure_global.sh"

echo ""
hr
echo ""
echo "  $(green "$(bold "Issuely installed successfully!")")"
echo ""
echo "  Next steps"
echo "    1. mkdir my-project && cd my-project"
echo "    2. issuely prd"
echo "    3. issuely issue"
echo "    4. issuely dev"
echo ""
