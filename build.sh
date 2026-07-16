#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
APP="$ROOT/build/成步堂桌宠.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

mkdir -p "$MACOS" "$RESOURCES"

xcrun swiftc \
    -swift-version 5 \
    "$ROOT"/Sources/*.swift \
    -framework AppKit \
    -framework QuartzCore \
    -o "$MACOS/成步堂桌宠"

cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT"/Assets/*-cg.png "$RESOURCES/"

codesign --force --deep --sign - "$APP"
echo "已生成：$APP"
