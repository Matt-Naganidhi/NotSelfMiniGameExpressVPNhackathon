#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════
#  EQGate — macOS Setup Utility
#  Usage:
#    chmod +x setup.sh && ./setup.sh          # install + start
#    ./setup.sh --install                     # install deps only
#    ./setup.sh --start                       # start server
#    ./setup.sh --ngrok                       # start server + ngrok tunnel
#    ./setup.sh --rename OldName NewName      # rebrand project
#    ./setup.sh --rename OldName NewName --preview
#    ./setup.sh --help
# ═══════════════════════════════════════════════════════════

set -euo pipefail

# ── Colours ───────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

ok()   { echo -e "  ${GREEN}[OK]${RESET} $*"; }
info() { echo -e "  ${CYAN}[INFO]${RESET} $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${RESET} $*"; }
err()  { echo -e "  ${RED}[ERROR]${RESET} $*"; }
die()  { err "$*"; exit 1; }

# ── Script directory (always run from project root) ────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Parse arguments ────────────────────────────────────────
MODE="full"
NGROK_MODE=0
OLD_BRAND=""
NEW_BRAND=""
PREVIEW=""

case "${1:-}" in
  --help|-h)     show_help; exit 0 ;;
  --install)     MODE="install" ;;
  --start)       MODE="start" ;;
  --ngrok)       NGROK_MODE=1 ;;
  --rename)
    OLD_BRAND="${2:-}"
    NEW_BRAND="${3:-}"
    PREVIEW="${4:-}"
    if [[ -z "$OLD_BRAND" || -z "$NEW_BRAND" ]]; then
      die "Usage: ./setup.sh --rename OldName NewName [--preview]"
    fi
    ;;
esac

# ── Help ───────────────────────────────────────────────────
show_help() {
  echo ""
  echo -e "  ${BOLD}EQGate Setup — macOS${RESET}"
  echo ""
  echo "  USAGE:  ./setup.sh [option]"
  echo ""
  echo "  OPTIONS:"
  echo "    (none)                  Install deps + start server"
  echo "    --install               Install npm deps only"
  echo "    --start                 Start server (skip install)"
  echo "    --ngrok                 Start server + ngrok tunnel"
  echo "    --rename OLD NEW        Rebrand project files"
  echo "    --rename OLD NEW --preview   Dry run only"
  echo "    --help                  Show this screen"
  echo ""
}

# ── Homebrew ───────────────────────────────────────────────
fn_homebrew() {
  if command -v brew &>/dev/null; then
    ok "Homebrew $(brew --version | head -1)"
    return 0
  fi
  info "Installing Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  # Add brew to PATH for Apple Silicon and Intel
  if [[ -f /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
    # Persist to shell profile
    PROFILE="$HOME/.zprofile"
    [[ "$SHELL" == *bash* ]] && PROFILE="$HOME/.bash_profile"
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$PROFILE"
  elif [[ -f /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi

  command -v brew &>/dev/null || die "Homebrew install failed. Visit https://brew.sh"
  ok "Homebrew installed"
}

# ── Node.js ────────────────────────────────────────────────
fn_node() {
  info "Checking Node.js..."

  if command -v node &>/dev/null; then
    NODE_MAJ=$(node -e "process.exit(parseInt(process.version.slice(1))>=18?0:1)" 2>/dev/null && echo "ok" || echo "old")
    if [[ "$NODE_MAJ" == "ok" ]]; then
      ok "Node.js $(node --version)"
      return 0
    fi
    warn "Node.js below v18 — upgrading..."
  fi

  fn_homebrew

  # Try nodenv / nvm first if present, then brew
  if command -v brew &>/dev/null; then
    info "Installing Node.js via Homebrew..."
    brew install node || brew upgrade node || true
  fi

  # Refresh PATH
  export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

  if command -v node &>/dev/null; then
    ok "Node.js $(node --version)"
    return 0
  fi

  # Fallback: official pkg installer
  info "Downloading Node.js LTS pkg installer..."
  TMP_PKG="$(mktemp /tmp/nodejs_lts.XXXXXX.pkg)"
  curl -fsSL "https://nodejs.org/dist/v20.18.0/node-v20.18.0.pkg" -o "$TMP_PKG"
  sudo installer -pkg "$TMP_PKG" -target / && rm -f "$TMP_PKG"
  export PATH="/usr/local/bin:$PATH"
  command -v node &>/dev/null || die "Node.js install failed. Install manually from https://nodejs.org"
  ok "Node.js $(node --version)"
}

# ── Python 3 ──────────────────────────────────────────────
fn_python() {
  info "Checking Python 3..."

  if command -v python3 &>/dev/null; then
    ok "$(python3 --version)"
    return 0
  fi

  warn "Python 3 not found — installing..."
  fn_homebrew
  brew install python3 || true
  export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

  if command -v python3 &>/dev/null; then
    ok "$(python3 --version)"
  else
    warn "Python 3 install failed — rename utility unavailable"
    return 1
  fi
}

# ── ngrok ──────────────────────────────────────────────────
fn_ngrok() {
  info "Checking ngrok..."

  if command -v ngrok &>/dev/null; then
    ok "ngrok found"
    return 0
  fi

  warn "ngrok not found — installing..."
  fn_homebrew

  # Try brew cask first
  if brew install --cask ngrok 2>/dev/null || brew install ngrok/ngrok/ngrok 2>/dev/null; then
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    command -v ngrok &>/dev/null && ok "ngrok installed" && return 0
  fi

  # Direct download fallback
  info "Downloading ngrok binary..."
  ARCH="$(uname -m)"
  if [[ "$ARCH" == "arm64" ]]; then
    NGROK_URL="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-darwin-arm64.zip"
  else
    NGROK_URL="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-darwin-amd64.zip"
  fi

  TMP_ZIP="$(mktemp /tmp/ngrok.XXXXXX.zip)"
  curl -fsSL "$NGROK_URL" -o "$TMP_ZIP"
  unzip -o "$TMP_ZIP" -d "$SCRIPT_DIR" && rm -f "$TMP_ZIP"
  chmod +x "$SCRIPT_DIR/ngrok"
  export PATH="$SCRIPT_DIR:$PATH"

  command -v ngrok &>/dev/null && ok "ngrok ready" || warn "Could not install ngrok. Download from https://ngrok.com/download"
}

# ── Install step ───────────────────────────────────────────
do_install() {
  echo ""
  echo -e "  ${BOLD}[INSTALL]${RESET} Setting up EQGate project..."
  echo "  Dir: $SCRIPT_DIR"
  echo ""

  fn_node
  fn_python || true

  [[ -f "$SCRIPT_DIR/package.json" ]] || die "package.json not found in $SCRIPT_DIR — make sure setup.sh is inside the EQGate folder"

  # Move index.html into public/
  mkdir -p "$SCRIPT_DIR/public"
  if [[ -f "$SCRIPT_DIR/index.html" ]]; then
    info "Moving index.html → public/index.html"
    mv -f "$SCRIPT_DIR/index.html" "$SCRIPT_DIR/public/index.html"
  fi

  info "Running npm install..."
  npm install || die "npm install failed"
  ok "npm install complete"
  echo ""

  # Install ngrok so it's ready for --ngrok flag
  fn_ngrok || true
  echo ""
}

# ── Start step ─────────────────────────────────────────────
do_start() {
  echo ""
  echo -e "  ${BOLD}╔══════════════════════════════════════════╗${RESET}"
  echo -e "  ${BOLD}║  Starting EQGate → http://localhost:3000  ║${RESET}"
  echo -e "  ${BOLD}╚══════════════════════════════════════════╝${RESET}"
  echo ""

  if [[ "$NGROK_MODE" -eq 1 ]]; then
    fn_ngrok

    echo ""
    info "Starting server in background..."
    node "$SCRIPT_DIR/server.js" &
    SERVER_PID=$!
    sleep 2

    info "Starting ngrok tunnel (Ctrl+C to stop)..."
    echo ""
    echo -e "  ${CYAN}The public URL will print in the server log automatically.${RESET}"
    echo ""
    ngrok http 3000

    # Clean up server when ngrok exits
    kill $SERVER_PID 2>/dev/null || true
  else
    # Open browser after a short delay
    (sleep 2 && open "http://localhost:3000") &
    echo -e "  ${CYAN}[TIP]${RESET} For remote access run:  ./setup.sh --ngrok"
    echo ""
    node "$SCRIPT_DIR/server.js"
  fi
}

# ── Rename step ────────────────────────────────────────────
do_rename() {
  fn_python || die "Python 3 required for --rename"
  echo ""
  info "Rebranding: $OLD_BRAND → $NEW_BRAND $PREVIEW"
  echo ""
  python3 "$SCRIPT_DIR/rename.py" --from "$OLD_BRAND" --to "$NEW_BRAND" $PREVIEW --rename-files
}

# ══════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════
echo ""
echo -e "  ${BOLD}+==============================================+${RESET}"
echo -e "  ${BOLD}|        EQGate — macOS Setup Utility         |${RESET}"
echo -e "  ${BOLD}+==============================================+${RESET}"
echo "  Project: $SCRIPT_DIR"
echo ""

if [[ -n "$OLD_BRAND" ]]; then
  do_rename
  exit 0
fi

if [[ "$MODE" == "start" ]]; then
  do_start
  exit 0
fi

if [[ "$MODE" == "install" ]]; then
  do_install
  ok "Done! Run: ./setup.sh --start"
  exit 0
fi

if [[ "$NGROK_MODE" -eq 1 ]]; then
  # Check npm deps are installed first
  if [[ ! -d "$SCRIPT_DIR/node_modules" ]]; then
    do_install
  fi
  do_start
  exit 0
fi

# Default: full install + start
do_install
do_start
