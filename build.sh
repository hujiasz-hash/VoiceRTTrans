#!/bin/bash
# VoiceRTTrans Cross-Platform Build Script for macOS/Linux

set -e

echo "====================================================="
echo "VoiceRTTrans Cross-Platform Build"
echo "====================================================="

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PYTHON=""

if [ -f "$SCRIPT_DIR/venv/bin/python3" ]; then
    PYTHON="$SCRIPT_DIR/venv/bin/python3"
    echo "Using venv Python: $PYTHON"
elif command -v python3 &> /dev/null; then
    PYTHON="python3"
    echo "Using system Python: $PYTHON"
else
    echo "Error: Python 3 is not installed"
    exit 1
fi

echo ""
echo "Python version:"
"$PYTHON" --version

echo ""
echo "Installing PyInstaller..."
"$PYTHON" -m pip install pyinstaller -q 2>&1 | grep -E "Successfully|already"

echo ""
echo "Building app..."
"$PYTHON" -m PyInstaller VoiceRTTrans.spec --clean -y 2>&1 | tail -20

if [ -d "dist/VoiceRTTrans.app" ]; then
    echo ""
    echo "✓ Build successful!"
    echo "App created at: dist/VoiceRTTrans.app"

    echo ""
    echo "Signing app bundle..."
    codesign --force --deep --sign - dist/VoiceRTTrans.app 2>&1
    echo "✓ Code signed"

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
