#!/bin/bash
# VoiceRTTrans Cross-Platform Build Script for macOS/Linux

set -e

echo "====================================================="
echo "VoiceRTTrans Cross-Platform Build"
echo "====================================================="

# Check if Python is installed
if ! command -v python3 &> /dev/null; then
    echo "Error: Python 3 is not installed"
    exit 1
fi

echo ""
echo "Python version:"
python3 --version

echo ""
echo "Installing PyInstaller..."
python3 -m pip install pyinstaller -q 2>&1 | grep -E "Successfully|already"

echo ""
echo "Building app..."
python3 -m PyInstaller VoiceRTTrans.spec --clean 2>&1 | tail -20

if [ -d "dist/VoiceRTTrans.app" ]; then
    echo ""
    echo "✓ Build successful!"
    echo "App created at: dist/VoiceRTTrans.app"
    
    echo ""
    echo "Creating ZIP archive..."
    cd dist
    rm -f VoiceRTTrans-macOS-*.zip
    zip -r "VoiceRTTrans-macOS-$(uname -m).zip" VoiceRTTrans.app > /dev/null
    echo "✓ ZIP archive created"
    cd ..
else
    echo ""
    echo "✗ Build failed! Check the output above for errors."
    exit 1
fi

echo ""
echo "====================================================="
echo "Build complete!"
echo "Artifacts in: dist/"
echo "====================================================="
