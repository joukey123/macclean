#!/bin/bash
# MacClean 빌드 & 설치
#   bash build.sh                       → 빌드해서 /Applications 에 설치하고 실행
#   bash build.sh --build-only <폴더>   → 앱 안의 '업데이트' 버튼이 쓰는 모드 (빌드만)
set -euo pipefail
cd "$(dirname "$0")"

NAME="MacClean"
APP="$NAME.app"
BUNDLE_ID="com.personal.macclean"

BUILD_ONLY=""
if [ "${1:-}" = "--build-only" ]; then
  BUILD_ONLY="${2:?출력 폴더를 지정해주세요}"
fi

VERSION="$(/usr/bin/python3 -c 'import json;print(json.load(open("version.json"))["version"])' 2>/dev/null || echo 1.0.0)"
echo "🔧 $NAME v$VERSION 빌드를 시작해요"

# 1) 준비물 확인
if [ "$(uname)" != "Darwin" ]; then echo "맥에서 실행해주세요."; exit 1; fi
if [ "$(sw_vers -productVersion | cut -d. -f1)" -lt 13 ]; then
  echo "macOS 13(Ventura) 이상이 필요해요."; exit 1
fi
if ! xcode-select -p >/dev/null 2>&1 || ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "📦 Apple 명령어 도구(무료)가 필요해요. 설치 창이 뜨면 '설치'를 눌러주세요."
  echo "   설치가 끝나면 다시 'bash build.sh' 를 실행하세요."
  xcode-select --install 2>/dev/null || true
  exit 1
fi

rm -rf build "$APP"
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 2) 앱 컴파일
echo "1/4 앱 컴파일 중… (1~2분 걸릴 수 있어요)"
TARGET="$(uname -m)-apple-macos13.0"
xcrun swiftc -O -parse-as-library -target "$TARGET" MacClean.swift -o "$APP/Contents/MacOS/$NAME"

# 3) 아이콘
echo "2/4 아이콘 만드는 중…"
ICON_KEY=""
if xcrun swiftc -O makeicon.swift -o build/makeicon 2>/dev/null && build/makeicon build/icon.png; then
  mkdir -p build/AppIcon.iconset
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon.png --out "build/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d build/icon.png --out "build/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
  ICON_KEY="<key>CFBundleIconFile</key><string>AppIcon</string>"
else
  echo "   (아이콘은 건너뛸게요)"
fi

# 4) 청소 엔진 + 앱 정보
echo "3/4 앱 묶는 중…"
cp macclean.py "$APP/Contents/Resources/macclean.py"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>휴지통으로 옮기거나 휴지통을 비울 때 Finder를 사용해요.</string>
  $ICON_KEY
</dict>
</plist>
PLIST
codesign --force --deep -s - "$APP" >/dev/null 2>&1 || true

# 업데이트 모드: 빌드 결과만 넘겨주고 끝 (설치·재시작은 앱이 처리)
if [ -n "$BUILD_ONLY" ]; then
  mkdir -p "$BUILD_ONLY"
  rm -rf "$BUILD_ONLY/$APP"
  ditto "$APP" "$BUILD_ONLY/$APP"
  rm -rf build "$APP"
  echo "✅ 빌드 완료: $BUILD_ONLY/$APP"
  exit 0
fi

# 5) 설치
DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"
echo "4/4 $DEST 에 설치 중…"
osascript -e "tell application \"$NAME\" to quit" >/dev/null 2>&1 || true
rm -rf "$DEST/$APP"
ditto "$APP" "$DEST/$APP"
rm -rf build "$APP"
xattr -cr "$DEST/$APP" 2>/dev/null || true
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREG" ] && "$LSREG" -f "$DEST/$APP" >/dev/null 2>&1 || true

echo ""
echo "✅ 완료! $DEST/$APP (v$VERSION)"
echo "   Launchpad나 Spotlight(⌘+Space)에서 'MacClean'으로 실행할 수 있어요."
echo "   다음부터는 앱 왼쪽 아래 '업데이트' 버튼으로 새 버전을 받을 수 있어요."
sleep 1
open "$DEST/$APP" 2>/dev/null || {
  echo "⚠️  자동 실행이 안 됐어요. 아래 결과를 Claude에게 붙여주세요:"
  sw_vers -productVersion; uname -m
  vtool -show-build "$DEST/$APP/Contents/MacOS/$NAME" 2>/dev/null | grep -E "minos|sdk" || true
}
