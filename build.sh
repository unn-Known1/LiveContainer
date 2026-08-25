#!/usr/bin/env bash
#
# build.sh — build a LiveContainer .ipa on macOS without Xcode UI.
#
# Requirements:
#   - macOS 14+ with Xcode 15+ installed
#   - git, xcodebuild, xcrun
#   - Apple Developer account (only required for non-ad-hoc signing)
#
# Usage:
#   ./build.sh                 # ad-hoc (default; no cert needed)
#   ./build.sh development     # development signing
#   ./build.sh enterprise      # enterprise signing
#   ./build.sh app-store       # app-store signing
#
# Output: build/ipa/<Scheme>.ipa

set -euo pipefail

if [ "$(uname -s)" != "Darwin" ]; then
    echo "error: build.sh must be run on macOS" >&2
    exit 1
fi

if [ ! -d "LiveContainer.xcodeproj" ]; then
    echo "error: must be run from the repository root" >&2
    exit 1
fi

METHOD="${1:-ad-hoc}"
SCHEME="${SCHEME:-LiveContainer}"
CONFIGURATION="${CONFIGURATION:-Release}"

case "$METHOD" in
    ad-hoc|development|enterprise|app-store) ;;
    *) echo "error: unknown method '$METHOD' (ad-hoc|development|enterprise|app-store)" >&2; exit 1 ;;
esac

echo "==> initializing submodules"
git submodule update --init --recursive || true

echo "==> listing schemes"
xcodebuild -list -project LiveContainer.xcodeproj

echo "==> building archive (scheme=$SCHEME configuration=$CONFIGURATION method=$METHOD)"
xcodebuild \
    -project LiveContainer.xcodeproj \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -sdk iphoneos \
    -destination "generic/platform=iOS" \
    -derivedDataPath build \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    ONLY_ACTIVE_ARCH=NO \
    clean archive

ARCHIVE=$(find build -name "*.xcarchive" -type d | head -n 1)
if [ -z "$ARCHIVE" ]; then
    echo "error: no .xcarchive produced" >&2
    exit 1
fi

echo "==> writing ExportOptions.plist"
cat > ExportOptions.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>$METHOD</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>compileBitcode</key>
    <false/>
    <key>thinning</key>
    <string>none</string>
    <key>stripSwiftSymbols</key>
    <true/>
</dict>
</plist>
EOF

echo "==> exporting .ipa"
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath build/ipa \
    -exportOptionsPlist ExportOptions.plist

echo "==> done. .ipa is in build/ipa/"
ls -la build/ipa
