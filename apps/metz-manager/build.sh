#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build/'METZ Manager.app'/Contents/MacOS
display_sources=../metz-extended-display/mac
xcrun clang -fobjc-arc -fblocks -target arm64-apple-macosx15.0 -c "$display_sources/VirtualDisplay.m" -o build/VirtualDisplay.o
swiftc -swift-version 5 -target arm64-apple-macosx15.0 -O -D METZ_MANAGER -import-objc-header "$display_sources/VirtualDisplay.h" \
    Sources/DiagnosticsCore.swift Sources/TVControl.swift Sources/OwnedADBServer.swift Sources/LocalNetworkAccess.swift Sources/RemoteSession.swift Sources/DeviceMetrics.swift Sources/ControlExtras.swift Sources/ControlExtrasView.swift Sources/SnapshotHistory.swift Sources/ManagerApp.swift Sources/ManagerView.swift "$display_sources/MetzTheme.swift" \
    "$display_sources/StreamProtocol.swift" "$display_sources/StreamJournal.swift" "$display_sources/StreamTransport.swift" "$display_sources/FramePipeline.swift" \
    "$display_sources/CaptureAccess.swift" "$display_sources/DisplayTopology.swift" "$display_sources/DisplayEngine.swift" "$display_sources/DisplayApp.swift" build/VirtualDisplay.o -framework CoreGraphics \
    -o build/'METZ Manager.app'/Contents/MacOS/MetzManager
cat > build/'METZ Manager.app'/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MetzManager</string>
<key>CFBundleIdentifier</key><string>com.metzrevive.manager</string>
<key>CFBundleName</key><string>METZ Manager</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.9.6</string>
<key>CFBundleVersion</key><string>20</string>
<key>LSMinimumSystemVersion</key><string>15.0</string>
<key>NSLocalNetworkUsageDescription</key><string>Подключение к выбранному телевизору METZ: управление и второй экран.</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
python3 ../../scripts/sign_mac_app.py build/'METZ Manager.app'
printf '%s\n' 'Built: apps/metz-manager/build/METZ Manager.app'
