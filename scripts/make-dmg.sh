#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist}"
APP="$OUT/CuktechMac10Ultra.app"

test -d "$APP" || { echo "请先生成 $APP" >&2; exit 1; }

VER="$("$APP/Contents/MacOS/CuktechMac10Ultra" --version 2>/dev/null || echo "1.0.0")"
DMG="$OUT/CuktechMac10Ultra-${VER}-macOS.dmg"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/cuktech-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/CuktechMac10Ultra.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
echo "== 生成 DMG 安装包 =="
hdiutil create \
  -volname "CuktechMac10Ultra" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  "$DMG"

echo "已生成 DMG: $DMG"
shasum -a 256 "$DMG"
ls -lh "$DMG"
