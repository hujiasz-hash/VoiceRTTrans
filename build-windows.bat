@echo off
REM VoiceRTTrans Windows Build Script
REM Run this on Windows with Python 3.9+ installed

echo =====================================================
echo VoiceRTTrans Windows Build
echo =====================================================

REM Check if Python is installed
python --version >nul 2>&1
if errorlevel 1 (
    echo Error: Python is not installed or not in PATH
    echo Please install Python from https://www.python.org/
    pause
    exit /b 1
)

echo.
echo Installing PyInstaller...
python -m pip install pyinstaller -q

echo.
echo Building Windows executable...
python -m PyInstaller VoiceRTTrans.spec --clean

echo.
if exist dist\VoiceRTTrans.exe (
    echo Build successful! 
    echo Executable created at: dist\VoiceRTTrans.exe
    echo.
    echo Creating ZIP archive...
    powershell -Command "Compress-Archive -Path dist\VoiceRTTrans.exe -DestinationPath dist\VoiceRTTrans-Windows-x64.zip -Force"
    echo ZIP archive created: dist\VoiceRTTrans-Windows-x64.zip
) else (
    echo Build failed! Check the output above for errors.
    pause
    exit /b 1
)

echo.
echo Build complete!
pause
