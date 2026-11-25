#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
echo "== 编译 Universal 二进制 (arm64 + x86_64) =="
swift build -c release --package-path "$ROOT" --arch arm64 --arch x86_64

BIN_DIR="$(swift build -c release --package-path "$ROOT" --arch arm64 --arch x86_64 --show-bin-path)"
BIN="$BIN_DIR/CuktechMac10Ultra"
test -f "$BIN" || { echo "未找到 Universal 产物: $BIN" >&2; exit 1; }

DEST="$ROOT/.build/release/CuktechMac10Ultra"
mkdir -p "$ROOT/.build/release"
if [ ! "$BIN" -ef "$DEST" ]; then
  cp "$BIN" "$DEST"
fi
file "$DEST"
