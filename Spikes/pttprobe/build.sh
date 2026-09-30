#!/bin/bash
# Build the M0 spike. Ad-hoc signed: unsigned arm64 binaries won't run.
set -euo pipefail
cd "$(dirname "$0")"
swiftc -swift-version 5 -O main.swift -o pttprobe \
  -framework CoreGraphics -framework ApplicationServices -framework AppKit
codesign -s - -f pttprobe 2>/dev/null
echo "built: $(pwd)/pttprobe"
