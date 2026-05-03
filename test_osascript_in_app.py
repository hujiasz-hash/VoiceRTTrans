#!/usr/bin/env python3
import subprocess
import sys

# Test if osascript is available from within app context
try:
    result = subprocess.run(
        ["osascript", "-e", 'say "test"'],
        check=False,
        capture_output=True,
        text=True,
        timeout=5
    )
    print(f"Return code: {result.returncode}")
    print(f"Stdout: {result.stdout}")
    print(f"Stderr: {result.stderr}")
    if result.returncode == 0:
        print("✓ osascript works!")
    else:
        print("✗ osascript failed")
except Exception as e:
    print(f"✗ Error: {e}")

# Check PATH
print(f"\nPATH: {os.environ.get('PATH', 'NOT SET')}")
os.system("which osascript")
