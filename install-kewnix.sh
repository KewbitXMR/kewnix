#!/bin/bash
set -e

SCRIPT_PREFIX="https://gist.githubusercontent.com/KewbitXMR/a5a781978f636aece211c63bc0bd958b/raw"

FILES=(
  kewnix
  .tor_gateway_docker_orchestrator.sh
  .tor_gateway_service_manager.sh
)

BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"

echo "[+] Installing kewnix scripts into $BIN_DIR..."

for f in "${FILES[@]}"; do
  curl -fsSL "$SCRIPT_PREFIX/$f" -o "$BIN_DIR/$f"
  chmod +x "$BIN_DIR/$f"
done

echo "export PATH=\"$BIN_DIR:\$PATH\"" >> ~/.bashrc
echo "[✓] Kewnix installed. Run with: kewnix"