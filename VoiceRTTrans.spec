# -*- mode: python ; coding: utf-8 -*-
# PyInstaller spec for VoiceRTTrans

import sys
from pathlib import Path

a = Analysis(
    ['main.py'],
    pathex=[],
    binaries=[],
    datas=[
        ('config.example.json', '.'),
        ('.env.example', '.'),
    ],
    hiddenimports=[
        'pynput',
        'pynput.keyboard',
        'pynput.keyboard._darwin',
        'pynput._util.darwin',
        'pynput._util.darwin_vks',
        'PyQt6',
        'PyQt6.QtWidgets',
        'PyQt6.QtCore',
        'PyQt6.QtGui',
        'requests',
        'dotenv',
    ],
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludedimports=[],
    win_no_prefer_redirects=False,
    win_private_assemblies=False,
    cipher=None,
    noarchive=False,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=None)

if sys.platform == 'darwin':
    exe = EXE(
        pyz,
        a.scripts,
        [],
        exclude_binaries=True,
        name='VoiceRTTrans',
        debug=False,
        bootloader_ignore_signals=False,
        strip=False,
        upx=True,
        upx_exclude=[],
        runtime_tmpdir=None,
        console=False,
        disable_windowed_traceback=False,
        target_arch=None,
        codesign_identity=None,
        entitlements_file='entitlements.plist',
        icon=None,
    )

    coll = COLLECT(
        exe,
        a.binaries,
        a.zipfiles,
        a.datas,
        strip=False,
        upx=True,
        upx_exclude=[],
        name='VoiceRTTrans',
    )

    app = BUNDLE(
        coll,
        name='VoiceRTTrans.app',
        icon=None,
        bundle_identifier='com.voicerttrans.app',
        entitlements_file='entitlements.plist',
        info_plist={
            'NSPrincipalClass': 'NSApplication',
            'NSHighResolutionCapable': 'True',
            'NSRequiresIPhoneOS': False,
            'LSBackgroundOnly': False,
            'LSUIElement': True,
            'CFBundleDisplayName': 'VoiceRTTrans',
            'CFBundleShortVersionString': '0.1.0',
            'CFBundleVersion': '1',
            'NSMicrophoneUsageDescription': 'VoiceRTTrans needs microphone access to record voice.',
            'NSAppleEventsUsageDescription': 'VoiceRTTrans needs to send Apple Events to paste text.',
            # Allow environment variable access for subprocess
            'LSEnvironment': {
                'PATH': '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin',
            },
        },
    )
else:
    exe = EXE(
        pyz,
        a.scripts,
        a.binaries,
        a.zipfiles,
        a.datas,
        [],
        name='VoiceRTTrans',
        debug=False,
        bootloader_ignore_signals=False,
        strip=False,
        upx=True,
        upx_exclude=[],
        runtime_tmpdir=None,
        console=False,
        disable_windowed_traceback=False,
        target_arch=None,
        codesign_identity=None,
        entitlements_file=None,
        icon=None,
    )
