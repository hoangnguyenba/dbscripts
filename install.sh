#!/bin/bash
# =============================================================================
# install.sh
# Installs dbexp and dbimp to /usr/local/bin
# =============================================================================

set -euo pipefail

REPO="https://raw.githubusercontent.com/hoangnguyenba/dbscripts/main"
INSTALL_DIR="/usr/local/bin"
SCRIPTS=("dbexp.sh" "dbimp.sh")
BINS=("dbexp" "dbimp")

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# Check for curl or wget
if command -v curl &>/dev/null; then
  FETCH="curl -fsSL"
elif command -v wget &>/dev/null; then
  FETCH="wget -qO-"
else
  error "Neither curl nor wget is installed. Please install one and try again."
fi

log "Installing dbscripts from ${CYAN}$REPO${NC}..."
echo ""

for i in "${!SCRIPTS[@]}"; do
  SCRIPT="${SCRIPTS[$i]}"
  BIN="${BINS[$i]}"
  DEST="$INSTALL_DIR/$BIN"

  log "Downloading $SCRIPT → $DEST"
  $FETCH "$REPO/$SCRIPT" | sudo tee "$DEST" > /dev/null
  sudo chmod +x "$DEST"
  log "Installed: ${CYAN}$DEST${NC}"
done

echo ""
log "Done! The following commands are now available:"
echo "  dbexp --help"
echo "  dbimp --help"