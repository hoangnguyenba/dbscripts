#!/bin/bash
# =============================================================================
# install.sh
# Installs dbexp and dbimp to ~/.local/bin
# =============================================================================

set -euo pipefail

REPO="https://raw.githubusercontent.com/hoangnguyenba/dbscripts/main"
INSTALL_DIR="$HOME/.local/bin"
SCRIPTS=("dbexp.sh" "dbimp.sh")
BINS=("dbexp" "dbimp")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# Check for curl or wget
if command -v curl &>/dev/null; then
  FETCH="curl -fsSL"
elif command -v wget &>/dev/null; then
  FETCH="wget -qO-"
else
  error "Neither curl nor wget is installed. Please install one and try again."
fi

# Ensure install directory exists
mkdir -p "$INSTALL_DIR"

# Warn if ~/.local/bin is not in PATH
if [[ ":$PATH:" != *":$INSTALL_DIR:"* ]]; then
  warn "$INSTALL_DIR is not in your PATH."
  warn "Add this to your ~/.bashrc or ~/.zshrc and restart your shell:"
  echo ""
  echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
  echo ""
fi

log "Installing dbscripts to ${CYAN}$INSTALL_DIR${NC}..."
echo ""

for i in "${!SCRIPTS[@]}"; do
  SCRIPT="${SCRIPTS[$i]}"
  BIN="${BINS[$i]}"
  DEST="$INSTALL_DIR/$BIN"

  log "Downloading $SCRIPT → $DEST"
  $FETCH "$REPO/$SCRIPT" > "$DEST"
  chmod +x "$DEST"
  log "Installed: ${CYAN}$DEST${NC}"
done

echo ""
log "Done! The following commands are now available:"
echo "  dbexp --help"
echo "  dbimp --help"