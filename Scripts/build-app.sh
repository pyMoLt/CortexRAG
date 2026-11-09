#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# 1. Ensure static llama.cpp (Metal) library is built
Scripts/build-llama-metal.sh

# 2. Generate AppIcon.icns from Resources/AppIcon_1024.png
ICONSET="Resources/AppIcon.iconset"
ICON_OUT="Resources/AppIcon.icns"
if [[ -f "Resources/AppIcon_1024.png" && ! -f "$ICON_OUT" ]]; then
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size "Resources/AppIcon_1024.png" --out "$ICONSET/icon_${size}x${size}.png" > /dev/null
    double=$((size * 2))
    sips -z $double $double "Resources/AppIcon_1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" > /dev/null
  done
  iconutil -c icns "$ICONSET" -o "$ICON_OUT"
  rm -rf "$ICONSET"
  echo "Generated $ICON_OUT"
fi

# 3. Build Release targets via xcodebuild (required so MLX Swift compiles mlx.metallib)
# Coverage off: the generated SwiftPM scheme otherwise instruments the release binaries.
xcodebuild -scheme CortexRAG-Package -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build-xcode \
  CLANG_ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO \
  build > /dev/null

PRODUCTS_DIR=".build-xcode/Build/Products/Release"
APP_BUNDLE="build/CortexRAG.app"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$PRODUCTS_DIR/CortexRAGApp" "$APP_BUNDLE/Contents/MacOS/CortexRAG"
cp "$PRODUCTS_DIR/cortexrag" "$APP_BUNDLE/Contents/MacOS/cortexrag-cli"

# Copy MLX Metal bundle and default.metallib beside the binaries and inside Contents/Resources
for bundle in "$PRODUCTS_DIR"/*.bundle; do
  if [[ -d "$bundle" ]]; then
    cp -R "$bundle" "$APP_BUNDLE/Contents/Resources/"
    cp -R "$bundle" "$APP_BUNDLE/Contents/MacOS/"
  fi
done
if [[ -f "$PRODUCTS_DIR/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" ]]; then
  cp "$PRODUCTS_DIR/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" "$APP_BUNDLE/Contents/Resources/default.metallib"
  cp "$PRODUCTS_DIR/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" "$APP_BUNDLE/Contents/MacOS/default.metallib"
  cp "$PRODUCTS_DIR/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" "$PRODUCTS_DIR/default.metallib"
fi

if [[ -f "$ICON_OUT" ]]; then
  cp "$ICON_OUT" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Interface translations (German keys, English table) – regenerate with Scripts/translations_en.py
python3 Scripts/translations_en.py > /dev/null
cp -R Resources/Localization/*.lproj "$APP_BUNDLE/Contents/Resources/"

cat > "$APP_BUNDLE/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>CortexRAG</string>
  <key>CFBundleDisplayName</key>
  <string>CortexRAG</string>
  <key>CFBundleIdentifier</key>
  <string>com.pymolt.CortexRAG</string>
  <key>CFBundleVersion</key>
  <string>1.0.0</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleExecutable</key>
  <string>CortexRAG</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>de</string>
  </array>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <!-- AI servers are user-configured (localhost, Tailscale IPs, LAN hosts) and usually speak plain HTTP. -->
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key>
    <true/>
  </dict>
</dict>
</plist>
EOF

# 4. Ad-hoc sign the app bundle and embedded binaries/metallibs
echo "Signing app bundle ad-hoc (-)"
for metallib in "$APP_BUNDLE/Contents/Resources"/*.metallib "$APP_BUNDLE/Contents/MacOS"/*.metallib "$APP_BUNDLE/Contents/Resources"/*.bundle/Contents/Resources/*.metallib "$APP_BUNDLE/Contents/MacOS"/*.bundle/Contents/Resources/*.metallib; do
  if [[ -f "$metallib" ]]; then
    codesign --force --sign "-" "$metallib"
  fi
done

for bundle in "$APP_BUNDLE/Contents/Resources"/*.bundle "$APP_BUNDLE/Contents/MacOS"/*.bundle; do
  if [[ -d "$bundle" ]]; then
    codesign --force --sign "-" "$bundle"
  fi
done

codesign --force --sign "-" "$APP_BUNDLE/Contents/MacOS/cortexrag-cli"
codesign --force --sign "-" "$APP_BUNDLE/Contents/MacOS/CortexRAG"
codesign --force --deep --sign "-" "$APP_BUNDLE"

# 5. Package release artifacts if ../releases exists
if [[ -d "../releases" ]]; then
  rm -rf "../releases/CortexRAG.app" "../releases/CortexRAG-1.0.0-macos-arm64.zip"
  cp -R "$APP_BUNDLE" "../releases/CortexRAG.app"
  ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "../releases/CortexRAG-1.0.0-macos-arm64.zip"
  echo "Packaged ../releases/CortexRAG-1.0.0-macos-arm64.zip"
fi

# Clean up intermediate xcodebuild artifacts and profraw files
rm -rf .build-xcode default.profraw

echo "✅ Built & ad-hoc signed $APP_BUNDLE (CLI/MCP: Contents/MacOS/cortexrag-cli)"
