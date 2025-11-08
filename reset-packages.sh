#!/bin/bash

# Script to reset Swift Package Manager caches for BetterBlue project

echo "🧹 Cleaning Swift Package caches..."

# Remove build artifacts
rm -rf build
rm -rf .build
rm -rf BetterBlueKit/.build

# Remove SPM cache
rm -rf ~/Library/Caches/org.swift.swiftpm

# Remove DerivedData
echo "🗑️  Removing DerivedData..."
rm -rf ~/Library/Developer/Xcode/DerivedData/BetterBlue-*

# Remove package resolved (will be regenerated)
rm -rf BetterBlue.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved

echo "✅ Caches cleared!"
echo ""
echo "Next steps:"
echo "1. Open BetterBlue.xcodeproj in Xcode"
echo "2. Go to File > Packages > Reset Package Caches"
echo "3. Clean Build Folder (Cmd+Shift+K)"
echo "4. Build (Cmd+B)"
