#!/bin/bash
set -euo pipefail

# Build script for QuickClipboard iOS tweak
# Run this on macOS with Theos installed.

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
THEOS="${THEOS:-$HOME/theos}"
export THEOS

cd "$PROJECT_DIR"

echo "[QuickClipboard] Cleaning..."
make clean

echo "[QuickClipboard] Building package..."
make package FINALPACKAGE=1

echo "[QuickClipboard] Build complete. Packages:"
ls -la "$PROJECT_DIR/packages/"
