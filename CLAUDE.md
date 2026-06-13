# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
source venv/bin/activate
python main.py                          # 开发运行
bash build.sh                           # 打包 macOS .app → dist/VoiceRTTrans.app
python -m PyInstaller VoiceRTTrans.spec --clean  # 手动打包
```

## Architecture

VoiceRTTrans is a macOS voice-to-polished-text tool using PyQt6. The UI is a frameless, always-on-top overlay window + system tray icon.

**Threading model (4 threads):**
1. **Main thread** — PyQt6 UI rendering, signal dispatch
2. **Hotkey thread** — `pynput.keyboard.Listener` (global keyboard events via CGEventTap)
3. **TranscriptionThread** (QThread) — runs `AudioRecorder` + polls `STTClient` every 0.5s with accumulated PCM chunks
4. **PolishThread** (QThread) — streams LLM response via SSE, token-by-token

**Data flow:**
```
Hotkey press → capture target app → show UI → start AudioRecorder
→ PCM chunks fed to STT (local HTTP, OpenAI Whisper API format)
→ final text → LLM stream polish → paste (Cmd+V via osascript) → hide UI
```

**Key components:**
- `main.py` — `VCAIWindow` widget, all signal wiring, macOS permission bootstrap, tray icon
- `core/hotkey.py` — `HotkeyListener`, parses config key string (e.g. `cmd_r+'`), suppresses system beep via `intercept` callback
- `core/audio_stream.py` — `AudioRecorder`, PyAudio 16kHz mono, chunk queue
- `core/stt_client.py` — `STTClient`, posts WAV to `http://127.0.0.1:8001/v1/transcriptions`
- `core/llm_client.py` — `LLMClient`, OpenAI-compatible SSE streaming, configurable via `LLM_BASE_URL`/`LLM_MODEL_NAME`/`LLM_API_KEY` env vars
- `core/scenario_manager.py` — `ScenarioManager`, loads/saves `~/.voicerttrans/scenarios.json` with 4 built-in scenes (default, email, commit, custom). Each scene has a system prompt that shapes LLM output.

**PolishThread fallback logic:** When `no_fallback=False` (default scene), a rule-based cleanup runs in parallel. If LLM output looks like analysis/meta-text (detected via marker patterns), or deviates >1.6x length or <72% similarity from rule output, the rule-based result is used instead. For non-default scenes, `no_fallback=True` and the LLM output is used directly. Short structured input (≤80 chars with punctuation) skips LLM entirely.

**Signal-based UI updates:** `WorkerSignals` (QObject) bridges threads. Signals: `raw_text_update` (streaming), `raw_text_ready` (final STT), `token_ready`, `status_update`, `polish_finished`, `reset_display`. All UI mutations happen on the main thread via `@pyqtSlot`.

## Configuration

- **Config file:** `~/.voicerttrans/config.json` — hotkey and UI settings. User config is auto-created from defaults on first run.
- **Scenarios file:** `~/.voicerttrans/scenarios.json` — scene definitions and current selection.
- **Env vars (`.env`):** `LLM_BASE_URL`, `LLM_MODEL_NAME`, `LLM_API_KEY`
- **Log file:** `~/.voicerttrans/app.log`

## macOS Permissions

The app requires three permissions, checked in `_bootstrap_macos_permissions()`:
1. **Accessibility** — for CGEventTap (global hotkey). Must be checked first since hotkey is critical.
2. **Microphone** — for PyAudio recording.
3. **Automation** — for `Cmd+V` paste via AppleScript.

**Important packaging gotcha:** Each PyInstaller build produces a new ad-hoc signature, which resets TCC permissions. `LSUIElement=True` means no Dock icon; `AXIsProcessTrustedWithOptions` with prompt blocks indefinitely in LSUIElement apps, so only `AXIsProcessTrusted()` (check-only) is used.

## PyInstaller Packaging

- Entry: `main.py`, one-dir mode, `.app` bundle on macOS
- `entitlements.plist` enables unsigned executable memory (needed by pynput/CGEventTap)
- Hidden imports required: `pynput._util.darwin`, `pynput._util.darwin_vks`
- Data files bundled: `config.example.json`, `.env.example`, tray icon PNGs, `VoiceRTTrans.icns`
- Build must use venv Python, not system Python (missing deps → silent crash)
