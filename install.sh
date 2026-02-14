#!/usr/bin/env bash
set -euo pipefail

echo "Installing myapp..."

INSTALL_DIR="/usr/local/bin"
BINARY_NAME="myapp"

TMP_FILE="$(mktemp)"

curl -fsSL https://example.com/myapp -o "$TMP_FILE"

chmod +x "$TMP_FILE"
sudo mv "$TMP_FILE" "$INSTALL_DIR/$BINARY_NAME"

echo "Done."
