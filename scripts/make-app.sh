#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist}"
BIN_OVERRIDE="${2:-}"

if [ -n "$BIN_OVERRIDE" ] && [ -f "$BIN_OVERRIDE" ]; then
  BIN="$BIN_OVERRIDE"
else
  ARCH="$(uname -m)"
  echo "== 构建 Release 二进制 ($ARCH) =="
  swift build -c release --package-path "$ROOT" --arch "$ARCH"
  BIN="$(swift build -c release --package-path "$ROOT" --arch "$ARCH" --show-bin-path)/CuktechMac10Ultra"
fi

test -f "$BIN" || { echo "未找到产物: $BIN" >&2; exit 1; }

APP="$OUT/CuktechMac10Ultra.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CuktechMac10Ultra"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
chmod +x "$APP/Contents/MacOS/CuktechMac10Ultra"

echo "== 生成应用图标 =="
mkdir -p "$ROOT/.build"
ICONSET="$ROOT/.build/AppIcon.iconset"
if xcrun -sdk macosx swiftc -O "$ROOT/scripts/make-icon.swift" -o "$ROOT/.build/make-icon" 2>/dev/null; then
  "$ROOT/.build/make-icon" "$ICONSET"
  xcrun iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null || true
fi

VER="$("$APP/Contents/MacOS/CuktechMac10Ultra" --version 2>/dev/null || echo "1.0.0")"
/usr/bin/sed -i '' "s/__VERSION__/$VER/g" "$APP/Contents/Info.plist"

codesign --force -s - "$APP"
codesign --verify --verbose "$APP" || true

echo "已生成: $APP"
du -sh "$APP"
