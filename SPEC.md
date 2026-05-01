# Voice-to-Command AI Tool (VCAI) 技术规格说明书 (SPEC)

## 1. 目标概述
开发一个轻量级桌面端 AI 语音效率工具。用户通过全局快捷键输入语音，工具实时转录并利用云端 LLM 整理成逻辑通顺的文案，最终自动写入系统剪贴板。

## 2. 核心技术栈
- **语言**：Python 3.10+
- **UI 框架**：PyQt6 (支持多线程与原生置顶窗口)
- **快捷键**：`keyboard` 自定义
- **音频处理**：`pyaudio` (捕捉系统麦克风)
- **API 服务**：
    - **STT**：流式语音识别 (WebSocket 协议) 用环境变量里的博世的URL和Api Key。
    - **LLM**：GLM-4.5-Air (追求极速响应)
- **剪贴板**：`pyperclip`

## 3. 功能需求
### 3.1 全局控制
- 监听全局快捷键（预设 `Ctrl+V`）。
- **交互逻辑**：按下开始录音并唤起 UI，松开停止录音并触发 LLM 处理。

### 3.2 实时 UI 界面
- **特性**：窗口无边框或精简边框、始终置顶 (Always-on-Top)、半透明背景。
- **显示区 A (Raw Text)**：实时显示 STT 转录的口语化文字。
- **显示区 B (Polished Text)**：显示 LLM 整理后的最终文案。
- **状态栏**：显示当前状态（录音中、处理中、已复制）。

### 3.3 逻辑处理
- **多线程架构**：
    - **Thread 1**：UI 渲染主线程。
    - **Thread 2**：音频采集与 STT WebSocket 通信。
    - **Thread 3**：LLM 请求与处理。
- **Prompt 要求**：
    - **任务**：修正语病、去除语气词、保持原意、整理为命令/便签格式。
    - **约束**：仅输出正文，严禁解释。

## 4. 关键实现细节
### 4.1 响应优化
- LLM 调用必须开启 `stream=True`，实现字符级实时上屏。
- 优先选择各平台提供的 Turbo/Light 级别模型以降低 TTFT（首字延迟）。

### 4.2 Windows 适配
- 确保音频驱动在 Windows 环境下的兼容性。
- 提供 PyInstaller 打包配置脚本，生成单文件 `.exe`。

## 5. 项目结构建议
```plaintext
.
├── main.py              # 程序入口，UI 逻辑
├── core/
│   ├── audio_stream.py  # 录音与 STT 处理
│   ├── llm_client.py    # LLM API 交互
│   └── hotkey.py        # 快捷键监听
├── config.json          # API Keys 与 Prompt 配置
├── requirements.txt     # 依赖清单
└── build_exe.py         # 打包脚本
```

## 6. Prompt 指令 (System Role)
你是一个高效的文案整理助手。用户会提供一段口语化的语音转文字记录，请你将其整理为书面、通顺、逻辑清晰的指令或文案。去除“那个”、“然后”、“呃”等冗余词汇。直接输出整理后的结果，不要进行任何对话或说明。
