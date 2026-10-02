#!/bin/sh
# Builds an optimised VideoDAW.app in the package folder.
set -e
cd "$(dirname "$0")/.."
swift build -c release
APP=VideoDAW.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/VideoDAW "$APP/Contents/MacOS/VideoDAW"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>VideoDAW</string>
    <key>CFBundleDisplayName</key><string>VideoDAW</string>
    <key>CFBundleIdentifier</key><string>com.j.videodaw</string>
    <key>CFBundleExecutable</key><string>VideoDAW</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.j.videodaw.project</string>
            <key>UTTypeDescription</key><string>VideoDAW Project</string>
            <key>UTTypeConformsTo</key><array><string>com.apple.package</string></array>
            <key>UTTypeTagSpecification</key>
            <dict><key>public.filename-extension</key><array><string>vdaw</string></array></dict>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>VideoDAW Project</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSTypeIsPackage</key><true/>
            <key>LSItemContentTypes</key><array><string>com.j.videodaw.project</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "Built $APP"
