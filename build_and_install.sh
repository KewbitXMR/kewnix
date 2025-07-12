#!/bin/bash
set -e

echo "[*] Building and installing Kewnix Orchestrator..."

# 1. Set paths
INSTALL_DIR="$HOME/.local/share/kewnix"
BIN_DIR="$HOME/.local/bin"
REPO_ROOT="$(pwd)"

mkdir -p "$INSTALL_DIR" "$BIN_DIR"

# 2. Copy entire repo into install dir
echo "[+] Copying repo to $INSTALL_DIR"
rsync -a --exclude 'target' --exclude '.git' ./ "$INSTALL_DIR"

# 3. Build PacketGuard (optional Rust binary)
if [ -d "$INSTALL_DIR/packetguard" ]; then
  echo "[*] Found packetguard/ Rust module, compiling..."
  (cd "$INSTALL_DIR/packetguard" && cargo build --release)

  echo "[?] Install PacketGuard system-wide? (y/n)"
  read -r install_pg
  if [[ "$install_pg" == "y" || "$install_pg" == "Y" ]]; then
    cp "$INSTALL_DIR/packetguard/target/release/packetguard" "$BIN_DIR/packetguard"
    echo "[✓] PacketGuard installed to $BIN_DIR/packetguard"
  else
    echo "[!] Skipping PacketGuard binary installation"
  fi
fi

# 4. Symlink main orchestrator
ln -sf "$INSTALL_DIR/kewnix" "$BIN_DIR/kewnix"
chmod +x "$INSTALL_DIR/kewnix"

echo "[✓] Kewnix installed."
echo "➡️  Run it with:  kewnix"