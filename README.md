# VoiceRTTrans

macOS 语音实时转文字工具。按住热键开始录音，松开后自动识别、润色并粘贴到当前应用。

## 功能

- 全局热键触发录音（默认：右 Command + 引号）
- 实时语音转文字（STT）
- LLM 自动润色整理（去语气词、格式化）
- 自动粘贴到目标应用
- 菜单栏状态图标

## 系统要求

- macOS 13+（Apple Silicon 或 Intel）
- Python 3.10+
- 本地 STT 服务（默认端口 8001）
- 本地 LLM 服务（默认端口 8081）或云端 API

## 快速开始

### 1. 安装依赖

```bash
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

### 2. 配置环境

```bash
cp .env.example .env
mkdir -p ~/.voicerttrans
cp config.example.json ~/.voicerttrans/config.json
```

编辑 `.env` 配置 LLM 服务地址：

```bash
# 本地 LLM（推荐，零延迟）
LLM_BASE_URL=http://127.0.0.1:8081/v1
LLM_MODEL_NAME=your-model-name
LLM_API_KEY=

# 或使用云端 API
# LLM_BASE_URL=https://open.bigmodel.cn/api/coding/paas/v4
# LLM_MODEL_NAME=GLM-4.5-Air
# LLM_API_KEY=your-api-key
```

### 3. 运行

```bash
source venv/bin/activate
python main.py
```

首次运行会请求辅助功能权限，授权后热键生效。

### 4. 打包 Mac 应用

```bash
bash build.sh
```

产物在 `dist/VoiceRTTrans.app`。

## 配置说明

### 热键配置

编辑 `~/.voicerttrans/config.json`：

```json
{
    "hotkey": "cmd_r+'",
    "ui": {
        "opacity": 0.85,
        "always_on_top": true
    }
}
```

支持的修饰键：`ctrl`、`cmd`、`cmd_r`（右 Command）、`alt`、`alt_r`（右 Option）、`shift`

示例：
- `"cmd_r+'"` — 右 Command + 引号（默认）
- `"alt_r+/"` — 右 Option + 斜杠
- `"ctrl+alt+v"` — Ctrl + Option + V

### STT 服务

默认连接本地 STT 服务 `http://127.0.0.1:8001/v1/transcriptions`。

兼容 OpenAI Whisper API 格式（接收 WAV 文件，返回 `{"text": "..."}`）。

推荐使用 [whisper.cpp](https://github.com/ggml-org/whisper.cpp) 或 [faster-whisper-server](https://github.com/fedirz/faster-whisper-server) 搭建本地服务。

### LLM 服务

兼容 OpenAI Chat Completions API 格式。支持任何符合该协议的服务：

| 方案 | 配置 |
|------|------|
| 本地 MLX | `LLM_BASE_URL=http://127.0.0.1:8081/v1` |
| 本地 Ollama | `LLM_BASE_URL=http://127.0.0.1:11434/v1` |
| 智谱 GLM | `LLM_BASE_URL=https://open.bigmodel.cn/api/coding/paas/v4` |
| OpenAI | `LLM_BASE_URL=https://api.openai.com/v1` |

### 环境变量

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `LLM_BASE_URL` | LLM API 地址 | `http://127.0.0.1:8081/v1` |
| `LLM_MODEL_NAME` | 模型名称 | `mlx-community/Qwen3.6-27B-4bit` |
| `LLM_API_KEY` | API 密钥（本地可空） | 空 |

## macOS 权限说明

首次使用（源码运行或打包应用）需要授予以下权限：

| 权限 | 用途 | 必需 |
|------|------|------|
| 辅助功能 (Accessibility) | 监听全局热键 | 是 |
| 麦克风 (Microphone) | 录音 | 是 |
| 自动化 (Automation) | 自动粘贴到其他应用 | 推荐 |

**源码运行**：权限授予给 Terminal（或你使用的终端应用）
**打包应用**：权限授予给 VoiceRTTrans.app

### 打包应用权限设置

1. 打开 **系统设置 > 隐私与安全性 > 辅助功能**
2. 点击 `+` 添加 `VoiceRTTrans.app`，或找到已存在的条目启用
3. 对麦克风和自动化重复相同操作
4. 重新打开应用

> 每次重新打包后，应用签名会变化，可能需要重新授权。

## 项目结构

```
main.py               # 主入口（UI、热键、权限、状态栏图标）
core/
  hotkey.py           # 全局热键监听（pynput）
  audio_stream.py     # 录音（PyAudio）
  stt_client.py       # 语音转文字客户端
  llm_client.py       # LLM 润色客户端
VoiceRTTrans.spec     # PyInstaller 打包配置
entitlements.plist    # macOS 应用权限声明
build.sh              # macOS 构建脚本
```

## 许可证

MIT
