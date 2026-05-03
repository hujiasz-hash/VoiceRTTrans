# Building Distributable Applications

This guide explains how to build VoiceRTTrans into standalone applications for macOS and Windows.

## Prerequisites

- Python 3.9 or higher
- All dependencies installed: `pip install -r requirements.txt`

## macOS Build

### Quick Build

```bash
./build.sh
```

This script will:
1. Install PyInstaller (if not already installed)
2. Build the app using `VoiceRTTrans.spec`
3. Create `dist/VoiceRTTrans.app` (ARM64 native)
4. Create `dist/VoiceRTTrans-macOS-arm64.zip` archive

### Manual Build

```bash
python3 -m pip install pyinstaller
python3 -m PyInstaller VoiceRTTrans.spec --clean
```

### Distribution

The resulting `dist/VoiceRTTrans-macOS-arm64.zip` contains:
- Fully self-contained macOS application
- No Python installation required
- All dependencies bundled inside the .app

**Requirements to run:**
- macOS 10.14 or later
- Microphone access permissions
- AppleScript/Automation permissions for auto-paste feature

## Windows Build

### Quick Build (Windows Command Prompt)

```cmd
build-windows.bat
```

This script will:
1. Check Python installation
2. Install PyInstaller
3. Build the executable
4. Create `dist/VoiceRTTrans-Windows-x64.zip` archive

### Manual Build

```cmd
python -m pip install pyinstaller
python -m PyInstaller VoiceRTTrans.spec --clean
```

### Distribution

The resulting `dist/VoiceRTTrans-Windows-x64.zip` contains:
- Standalone Windows executable
- No Python installation required
- All dependencies bundled

**Requirements to run:**
- Windows 10 or later
- Microphone access
- Microphone permissions (Windows will prompt)

## Build Configuration

Build configuration is defined in `VoiceRTTrans.spec`:
- Entry point: `main.py`
- Data files: `config.example.json`, `.env.example`
- Hidden imports: pynput, PyQt6, requests, etc.
- Output format: One-dir mode (for macOS .app bundle)

## Build Output

After building, artifacts are in the `dist/` directory:

```
dist/
├── VoiceRTTrans                      # macOS executable (arm64)
├── VoiceRTTrans.app/                 # macOS application bundle
│   ├── Contents/
│   │   ├── MacOS/VoiceRTTrans
│   │   ├── Resources/
│   │   └── Info.plist
│   └── ...
├── VoiceRTTrans-macOS-arm64.zip      # Distributable macOS package
└── VoiceRTTrans-Windows-x64.zip      # Distributable Windows package (if built on Windows)
```

## Code Signing and Notarization

### macOS Code Signing (Optional)

For production distribution, you should sign and notarize the app:

```bash
codesign -s - dist/VoiceRTTrans.app
```

For Apple notarization:
1. Create a developer account at developer.apple.com
2. Use `xcrun altool` to submit for notarization
3. Update the app bundle after approval

### Windows Code Signing (Optional)

For production distribution:
```cmd
signtool sign /f YourCertificate.pfx /p password dist\VoiceRTTrans.exe
```

## Troubleshooting

### macOS: "App is damaged" warning
- This is normal for unsigned apps
- Right-click the app → Open → Click "Open" again
- Or: `xattr -d com.apple.quarantine VoiceRTTrans.app`

### macOS: Permission denied for microphone
- System Preferences → Security & Privacy → Microphone
- Add VoiceRTTrans to the allowed list

### macOS: Cannot paste to applications
- System Preferences → Security & Privacy → Automation
- Add VoiceRTTrans to the allowed list (for target apps like TextEdit, etc.)

### Windows: Antivirus warnings
- This is normal for unsigned executables
- Add exception in antivirus software, or
- Submit to Windows Defender for analysis

### Build fails with "module not found"
- Ensure all dependencies are installed: `pip install -r requirements.txt`
- Check that you're in the correct directory
- Try: `python -m pip install --upgrade pyinstaller`

## Performance Notes

- First build may take 2-5 minutes (compilation and packaging)
- Subsequent builds are faster (~1-2 minutes)
- Resulting app is ~200MB (includes all dependencies)
- On first run, app may need 10-15 seconds to load (unpacking)

## CI/CD Integration

For automated builds in GitHub Actions, CI/CD, or other systems:

```bash
# Install and build in clean environment
python3 -m venv build_env
source build_env/bin/activate  # or build_env\Scripts\activate on Windows
pip install -r requirements.txt
pip install pyinstaller
python -m PyInstaller VoiceRTTrans.spec --clean

# Upload dist/ artifacts to release
```
