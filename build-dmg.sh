#!/bin/bash
set -e

APP_NAME="Clippy"
DISPLAY_NAME="Clippy"
VERSION="1.0"

echo "🔨 Building release..."
swift build -c release

echo "📦 Creating app bundle..."
rm -rf "$APP_NAME.app"
mkdir -p "$APP_NAME.app/Contents/MacOS"
mkdir -p "$APP_NAME.app/Contents/Resources"

cp ".build/release/$APP_NAME" "$APP_NAME.app/Contents/MacOS/"

# Create Info.plist
cat > "$APP_NAME.app/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.yourteam.$APP_NAME</string>
    <key>CFBundleName</key>
    <string>$DISPLAY_NAME</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

# Copy icon if it exists
if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns "$APP_NAME.app/Contents/Resources/"
fi

# Remove quarantine attribute
echo "🔓 Removing quarantine attribute..."
xattr -cr "$APP_NAME.app"

# Ad-hoc code signing (helps with some Gatekeeper issues)
echo "🔏 Signing app with ad-hoc signature..."
codesign --force --deep --sign - "$APP_NAME.app"

echo "💿 Creating DMG..."
rm -f "$DISPLAY_NAME-$VERSION.dmg"

if command -v create-dmg &> /dev/null; then
    # Create a background image for the DMG
    echo "🎨 Creating DMG background..."
    mkdir -p dmg_background
    
    # Create a simple background with instructions using sips and text
    # We'll create a 600x400 background
    cat > dmg_background/create_bg.py << 'PYEOF'
import subprocess
import os

# Create a gradient background with arrow using basic commands
# This creates a simple but effective installer background

width, height = 600, 400

# Create SVG for background
svg_content = '''<?xml version="1.0" encoding="UTF-8"?>
<svg width="600" height="400" xmlns="http://www.w3.org/2000/svg">
  <defs>
    <linearGradient id="bg" x1="0%" y1="0%" x2="0%" y2="100%">
      <stop offset="0%" style="stop-color:#f5f5f7;stop-opacity:1" />
      <stop offset="100%" style="stop-color:#e8e8ed;stop-opacity:1" />
    </linearGradient>
  </defs>
  <rect width="600" height="400" fill="url(#bg)"/>
  <text x="300" y="350" font-family="SF Pro Display, Helvetica Neue, Arial" font-size="14" fill="#86868b" text-anchor="middle">Drag Clippy to Applications to install</text>
  <path d="M 270 200 L 330 200 L 330 190 L 350 205 L 330 220 L 330 210 L 270 210 Z" fill="#86868b" opacity="0.6"/>
</svg>
'''

with open('background.svg', 'w') as f:
    f.write(svg_content)

# Convert SVG to PNG using rsvg-convert or qlmanage
try:
    subprocess.run(['rsvg-convert', '-w', '600', '-h', '400', 'background.svg', '-o', 'background.png'], check=True)
except:
    # Fallback: create simple solid background
    subprocess.run(['sips', '-z', '400', '600', '-s', 'format', 'png', '--out', 'background.png', 
                   '/System/Library/Desktop Pictures/Solid Colors/Silver.png'], check=False)

print("Background created")
PYEOF

    # Try to create background, or skip if it fails
    python3 dmg_background/create_bg.py 2>/dev/null || true
    
    # Build create-dmg command
    DMG_ARGS=(
        --volname "$DISPLAY_NAME"
        --volicon "AppIcon.icns"
        --window-pos 200 120
        --window-size 600 400
        --icon-size 128
        --icon "$APP_NAME.app" 150 185
        --app-drop-link 450 185
        --hide-extension "$APP_NAME.app"
        --no-internet-enable
    )
    
    # Add background if it was created
    if [ -f "dmg_background/background.png" ]; then
        DMG_ARGS+=(--background "dmg_background/background.png")
    fi
    
    create-dmg "${DMG_ARGS[@]}" "$DISPLAY_NAME-$VERSION.dmg" "$APP_NAME.app"
    
    # Cleanup
    rm -rf dmg_background
else
    # Fallback to hdiutil
    mkdir -p dmg_temp
    cp -R "$APP_NAME.app" dmg_temp/
    ln -s /Applications dmg_temp/Applications
    hdiutil create -volname "$DISPLAY_NAME" \
      -srcfolder dmg_temp \
      -ov -format UDZO \
      "$DISPLAY_NAME-$VERSION.dmg"
    rm -rf dmg_temp
fi

echo "✅ Done! Created: $DISPLAY_NAME-$VERSION.dmg"