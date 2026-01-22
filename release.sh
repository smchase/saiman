#!/bin/bash

# Release script for Saiman
# Quits the app, rebuilds, installs to /Applications, and relaunches

set -e

echo "Quitting Saiman..."
osascript -e 'quit app "Saiman"' 2>/dev/null || pkill -f "Saiman" 2>/dev/null || true
sleep 1

echo "Building release version..."
xcodebuild -scheme Saiman -configuration Release build 2>&1 | grep -E "(error:|warning:|BUILD)" | grep -v "warning: duplicate output"

echo "Installing to /Applications..."
rm -rf /Applications/Saiman.app
cp -R ~/Library/Developer/Xcode/DerivedData/Saiman-*/Build/Products/Release/Saiman.app /Applications/

echo "Launching Saiman..."
open /Applications/Saiman.app

echo "Done!"
