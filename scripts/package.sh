#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist}"
APP="$OUT/CuktechMac10Ultra.app"

test -d "$APP" || { echo "请先生成 $APP" >&2; exit 1; }

VER="$("$APP/Contents/MacOS/CuktechMac10Ultra" --version 2>/dev/null || echo "1.0.0")"
ZIP="$OUT/CuktechMac10Ultra-${VER}-macOS.zip"

rm -f "$ZIP"
(cd "$OUT" && zip -qryX "$(basename "$ZIP")" "CuktechMac10Ultra.app")
echo "已生成 ZIP: $ZIP"
shasum -a 256 "$ZIP"
