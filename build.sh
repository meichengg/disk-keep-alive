#!/bin/bash
echo "🔨 Building Disk Keep Alive..."

swiftc -O -o DiskKeepAlive DiskKeepAlive.swift \
    -framework AppKit -framework SwiftUI -framework IOKit 2>&1

if [ $? -eq 0 ]; then
    echo "✅ Build successful!"
    echo ""
    echo "Run: ./DiskKeepAlive"
else
    echo "❌ Build failed"
    exit 1
fi
