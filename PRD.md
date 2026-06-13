# VoiceRTTrans PRD

> 最后更新：2026-05-10 | 当前版本：v0.3 (dev)

## 1. 产品概述

VoiceRTTrans 是一个 macOS 桌面端 AI 语音效率工具。用户通过全局热键输入语音，工具实时转录并利用 LLM 整理为逻辑通顺的文案，最终自动粘贴到当前应用。

**核心交互**：按住热键 → 说话 → 松手 → 自动粘贴。零步骤、零思考。

**技术栈**：Python 3.10+, PyQt6, PyAudio, pynput, OpenAI-compatible API

---

## 2. 功能清单

### 2.1 已实现

| 功能 | 版本 | 说明 |
|------|------|------|
| 全局热键 | v0.1 | 按住录音、松开停止。默认 `右 Cmd + '`，可配置 |
| 实时 STT | v0.1 | 连接本地 Whisper 服务 (`:8001`)，录音中持续识别 |
| LLM 润色 | v0.1 | 流式调用 LLM 去除语气词、结构化整理，含快速规整路径和回退逻辑 |
| 自动粘贴 | v0.1 | 润色完成后自动切回目标应用并 `Cmd+V` 粘贴 |
| 浮动 UI | v0.1 | 无边框、半透明、置顶窗口，显示原始文本和状态，可拖动 |
| 菜单栏图标 | v0.1 | 系统托盘常驻，图标颜色反映状态（白/红/橙），点击切换录音 |
| 配置管理 | v0.1 | `~/.voicerttrans/config.json` 热键和 UI 配置 |
| macOS 打包 | v0.1 | PyInstaller 打包为 `.app`，含权限引导 |
| 场景模板 | v0.3 | 4 个内置场景（默认整理/商务邮件/Commit Message/自定义角色），每个场景独立 system prompt |
| 场景切换 | v0.3 | 托盘菜单子菜单切换场景，当前场景打钩，重启记忆 |
| 场景编辑 | v0.3 | 模态对话框编辑任意场景 prompt，支持恢复默认 |
| 场景指示 | v0.3 | 非默认场景时浮动窗口状态栏显示 `[{场景名}]` 前缀 |
| 右键菜单 | v0.3 | 场景快捷切换、编辑当前场景指令入口 |

### 2.2 计划中

| 功能 | 版本 | 说明 |
|------|------|------|
| 热键循环切换场景 | v0.4 | 热键双击循环切换 |
| 自定义新增场景 | v0.4 | 用户自由添加/删除场景 |
| 扩展场景 | v0.4 | 8+ 内置场景 |
| 语音回读 (TTS) | v0.5 | 润色结果语音回读 |
| 录音历史记录 | v0.5 | 历史录音和润色结果查看 |
| 场景导入/导出 | v0.5 | 场景配置分享 |
| 目标应用场景自动切换 | v0.6 | 根据前台应用自动切换场景 |
| 场景使用统计 | v0.6 | 智能推荐场景 |

### 2.3 明确不做

- 不修改 STT 服务逻辑（STT 为外部服务）
- 不新增/删除场景的 UI（v0.3 仅 4 个内置，可编辑 prompt，新增删除在 v0.4）

### 2.4 v0.3.1 改动 (2026-05-10)

| 改动 | 说明 |
|------|------|
| CGEvent Cmd+V 输入 | 替代 pyperclip.copy + osascript 粘贴。用 4 个 CGEvent 键盘事件发送 Cmd+V，剪贴板保存/恢复（600ms 延迟），不永久污染剪贴板 |
| 终端统一流程 | 终端不再特殊处理（之前仅复制不粘贴，需手动 Cmd+V），与其他应用走相同 CGEvent Cmd+V 流程 |
| 热键拦截重构 | 经历 4 轮迭代，详见 Issue #2 |

---

## 3. 架构设计

### 3.1 项目结构

```
main.py               # 主入口（UI、热键、权限、状态栏、粘贴）
core/
  hotkey.py           # 全局热键监听（pynput CGEventTap）
  audio_stream.py     # 录音（PyAudio 16kHz mono）
  stt_client.py       # STT 客户端（HTTP, OpenAI Whisper 兼容）
  llm_client.py       # LLM 客户端（OpenAI Chat Completions SSE 流式）
  scenario_manager.py # 场景管理（scenarios.json 加载/保存）
VoiceRTTrans.spec     # PyInstaller 打包配置
entitlements.plist    # macOS 权限声明
build.sh / build-windows.bat  # 构建脚本
```

### 3.2 线程模型

```
Thread 1 (主线程) — PyQt6 UI 渲染，信号分发
Thread 2 (pynput) — 全局热键监听，CGEventTap
Thread 3 (QThread) — 音频采集 + 每 0.5s 周期性 STT 请求
Thread 4 (QThread) — LLM 流式润色（松手后启动）
```

### 3.3 数据流

```
麦克风 → AudioRecorder → audio_buffer
                            ↓ (每 0.5s)
                       STTClient → raw_text_update 信号 → UI
                            ↓ (松开后)
                       STTClient (最终识别)
                            ↓
                       PolishThread (LLM 流式润色 + 规则回退)
                            ↓
                       pyperclip.copy → 恢复目标应用 → Cmd+V
```

### 3.4 润色回退逻辑

`PolishThread` 中三层策略：

1. **快速规整路径**：输入 ≤80 字符且有标点结构 → 跳过 LLM，仅规则清洗
2. **LLM 流式润色**：调用 LLM，`_extract_final_text()` 清洗元文本后输出
3. **回退到规则**：LLM 输出偏离原文（长度 >1.6x 或相似度 <72%）或疑似分析体 → 使用规则清洗结果

非默认场景 (`no_fallback=True`) 跳过第 3 步回退，直接使用 LLM 输出。

### 3.5 信号系统

`WorkerSignals` (QObject) 桥接工作线程与 UI 线程：

| 信号 | 触发时机 | 作用 |
|------|---------|------|
| `raw_text_update` | 录音中每 0.5s | 实时刷新原始文本 |
| `raw_text_ready` | 最终 STT 完成 | 触发 LLM 润色 |
| `status_update` | 状态变化 | 更新状态栏文字 |
| `polish_finished` | 润色完成 | 复制剪贴板 + 粘贴 |
| `reset_display` | 新录音开始 | 清空文本区 |
| `error_occurred` | 异常 | 显示错误 |

---

## 4. 配置说明

### 4.1 config.json (`~/.voicerttrans/config.json`)

```json
{
    "hotkey": "cmd_r+'",
    "ui": { "opacity": 0.85, "always_on_top": true }
}
```

支持修饰键：`ctrl`, `cmd`, `cmd_r`, `alt`, `alt_r`, `shift` + 单字符键

### 4.2 scenarios.json (`~/.voicerttrans/scenarios.json`)

```json
{
    "current": "default",
    "scenarios": [
        { "id": "default", "name": "默认整理", "icon": "📝", "prompt": "..." },
        { "id": "email", "name": "商务邮件", "icon": "✉️", "prompt": "..." },
        { "id": "commit", "name": "Commit Message", "icon": "💻", "prompt": "..." },
        { "id": "custom", "name": "自定义角色", "icon": "🎭", "prompt": "..." }
    ]
}
```

首次启动自动创建。字段缺失时合并内置默认值。

### 4.3 环境变量 (`.env`)

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `LLM_BASE_URL` | LLM API 地址 | `http://127.0.0.1:8081/v1` |
| `LLM_MODEL_NAME` | 模型名称 | `mlx-community/Qwen3.6-27B-4bit` |
| `LLM_API_KEY` | API 密钥（本地可空） | 空 |

STT 服务默认连接 `http://127.0.0.1:8001/v1/transcriptions`（硬编码在 `core/stt_client.py`）。

### 4.4 日志

`~/.voicerttrans/app.log`，DEBUG 级别写文件，INFO 级别输出控制台。

---

## 5. macOS 权限

| 权限 | 用途 | 必需 | 备注 |
|------|------|------|------|
| 辅助功能 (Accessibility) | 全局热键 CGEventTap | 是 | 每次 PyInstaller 重新打包后签名变化，需重新授权 |
| 麦克风 (Microphone) | PyAudio 录音 | 是 | — |
| 自动化 (Automation) | Cmd+V 粘贴 | 推荐 | — |

**注意事项**：
- `LSUIElement=True`（无 Dock 图标），`AXIsProcessTrustedWithOptions` 弹框会永久阻塞，只能用 `AXIsProcessTrusted()` 检查
- 权限 bootstrap 顺序：辅助功能 → 麦克风 → 自动化

---

## 6. 已知问题

### Issue #1：中文夹杂英文/数字时出现乱码 ✅ 已修复 (2026-05-10)

`PolishThread._extract_final_text()` 中 latin/CJK 过滤阈值过于激进。纯英文行阈值从 6 提高到 12，含中文行的拉丁/中文比从 2x 放宽到 10x。

### Issue #2：热键触发系统"哒哒哒"提示音 ⚠️ 未修复

**现象**：按住热键 `Cmd+'` 时，终端、访达搜索框、系统设置搜索框等出现连续系统提示音；Cursor 等 Electron 应用中无此问题。

**影响范围**：原生 macOS 应用（Terminal、Finder、System Settings），Electron 应用不受影响。

**根因分析**：`Cmd+'` 在这些原生应用中不是有效的菜单快捷键，macOS 收到未处理的 Cmd+key 组合键后发出默认警报声。这是 macOS 原生行为，与事件拦截方式无关。

**调试过程**（2026-05-10，4 轮迭代）：

| 轮次 | 策略 | 结果 |
|------|------|------|
| 1 | 只拦截热键字符键（`'`），修饰键放行；用 `_char_suppressed` 标记配对拦截 key-down/key-up | 系统 UI 仍有提示音 — 修饰键 Cmd 放行后，系统等待完整快捷键组合，等不到就报警 |
| 2 | 回到拦截所有事件，用 `_suppressed` set 追踪每个被拦 key-down 的 vk，确保 key-up 配对拦截 | 同上 — key-up/down 配对正确但仍报警 |
| 3 | 关闭所有事件拦截（`_intercept` 直接返回 event），验证根因 | Cursor 无提示音，终端/访达/系统设置仍有 → **确认提示音与拦截逻辑无关，是 Cmd+' 组合键本身在原生 App 中触发了 macOS 系统警报** |
| 4 | 不抑制事件，改为修改事件：`CGEventSetType` → `kCGEventNull`；`CGEventSetIntegerValueField(keycode→0xFF)` + `CGEventSetFlags→0` | 均无效，提示音依旧 |

**当前状态**：`core/hotkey.py:_intercept` 将所有事件键码改为越界值 0xFF、清除修饰键标志后放行。事件流完整但热键组合本身仍触发系统警报。

**可能的解决方向**：
- 使用 Carbon `RegisterEventHotKey` API（系统级热键注册，由系统接管组合键，不传递到目标应用）
- 更换热键为非字符键（如 F13-F19），避免 Cmd+字符触发系统快捷键处理
- 使用 `CGEventTap` passive 模式 + 事后删除误输入字符

---

## 7. 版本历史

| 版本 | 日期 | 内容 |
|------|------|------|
| v0.1.0 | 2025-05 | 初始发布：热键录音 + STT + LLM 润色 + 粘贴 |
| v0.1.1 | 2025-05 | 修复打包崩溃、权限引导、热键拦截等 9 个问题 |
| v0.3 | 2026-05 | 场景模板功能（4 场景 + 菜单切换 + prompt 编辑 + 状态指示），中英混排修复 |
| v0.3.1 | 2026-05 | CGEvent Cmd+V 替代剪贴板粘贴，热键拦截 4 轮调试（Issue #2 待修复） |
| v0.4 | 计划中 | 热键循环切换场景、自定义新增/删除场景、8+ 内置场景 |
| v0.5 | 计划中 | TTS 语音回读、录音历史记录、场景导入/导出 |
| v0.6 | 计划中 | 目标应用自动切换场景、使用统计与智能推荐 |
