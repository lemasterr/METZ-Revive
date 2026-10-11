#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build
swiftc -swift-version 5 StreamProtocol.swift StreamJournal.swift StreamTransport.swift FramePipeline.swift CaptureAccess.swift DisplayTopology.swift CoreCheck.swift -o build/core-check
build/core-check
swiftc -swift-version 5 StreamProtocol.swift StreamJournal.swift StreamJournalCheck.swift -o build/journal-check
build/journal-check
xcrun clang -fobjc-arc -fblocks -DMETZ_DISPLAY_TESTING=1 VirtualDisplay.m VirtualDisplayCheck.m \
    -framework Foundation -framework CoreGraphics -o build/virtual-display-check
build/virtual-display-check
