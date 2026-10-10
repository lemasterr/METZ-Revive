#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 Sources/DiagnosticsCore.swift Sources/TVControl.swift Sources/OwnedADBServer.swift Sources/LocalNetworkAccess.swift Sources/RemoteSession.swift Sources/DeviceMetrics.swift Sources/ControlExtras.swift Sources/SnapshotHistory.swift Tests/ADBServerCheck.swift Tests/CoreCheck.swift -o build/core-check
build/core-check
