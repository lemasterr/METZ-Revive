#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build/'METZ Display.app'/Contents/MacOS
xcrun clang -fobjc-arc -fblocks -target arm64-apple-macosx15.0 -c VirtualDisplay.m -o build/VirtualDisplay.o
swiftc -swift-version 5 -target arm64-apple-macosx15.0 -O -import-objc-header VirtualDisplay.h \
    StreamProtocol.swift StreamJournal.swift StreamTransport.swift FramePipeline.swift CaptureAccess.swift DisplayTopology.swift DisplayEngine.swift MetzTheme.swift DisplayApp.swift \
    build/VirtualDisplay.o -framework CoreGraphics -o build/'METZ Display.app'/Contents/MacOS/MetzDisplay
cat > build/'METZ Display.app'/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MetzDisplay</string>
<key>CFBundleIdentifier</key><string>com.metzrevive.display.mac</string>
<key>CFBundleName</key><string>METZ Display</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.4.3</string>
<key>CFBundleVersion</key><string>7</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSLocalNetworkUsageDescription</key><string>Защищённая передача второго экрана на выбранный телевизор METZ.</string>
</dict></plist>
PLIST
python3 ../../../scripts/sign_mac_app.py build/'METZ Display.app'
printf '%s\n' 'Built METZ Display.app; private API and capture were not executed.'
