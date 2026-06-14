# VoiceFlow 产品需求文档 (PRD)

---

## 1. 产品概述与愿景

### 1.1 产品定位
`VoiceFlow` 是一款专为 macOS 设计的**本地离线、高精度语音输入与听写增强工具**。它致力于通过全本地的自动语音识别（ASR）引擎，在完全保障用户隐私的前提下，为用户提供极其顺畅、即时、高精度且无缝的日常文本录入体验。

### 1.2 核心痛点
- **在线听写隐私泄露**：市面上大部分高精度输入法依赖云端 API，存在商业或隐私数据泄露风险。
- **系统听写灵活性差**：macOS 原生语音输入交互不够灵活，难以定制离线模型或在各软件间实现高度自定义的注入。
- **非流式模型无实时预览**：离线高精度模型（如 SenseVoice）是非流式的，录音中途悬浮窗空白，用户缺乏即时打字确认的安全感。

### 1.3 解决思路
全本地加载 ASR 引擎（如 Paraformer, SenseVoice），并通过**双引擎并行流式架构**（Apple Native ASR 实时流式预览 + SenseVoice 离线高精度覆盖），在实现 100% 离线隐私保护的同时，达成“录音期间字随音出，录音结束高精覆盖”的极致产品体验。

---

## 2. 核心功能需求 (Features)

### 2.1 语音输入激活与触发
- **按住说话模式**：
  - 用户按下修饰键（默认双击或长按 `Option` 键）即刻激活录音，屏幕中心弹出半透明悬浮窗（Bubble Overlay）。
  - 录音期间保持悬浮显示，松开 `Option` 键立即结束录音，并在当前光标处自动模拟打字输入文字。
- **单击开始/停止模式**：
  - 允许在偏好设置中切换为单击触发录音、再次单击停止录音的交互形式。
- **自适应悬浮 UI**：
  - 采用纯 SwiftUI 渲染的高保真自适应渐变半透明玻璃卡片背景（融合系统 Accent Color 液态流光与 windowBackgroundColor 自适应），配合外边缘 1.5pt 的左上角强反光折射描边、3D 线性反射亮面（上半部分 Specular highlight），以及双重环境悬浮投影（拉开深度的柔和阴影 + 固定轮廓的精细接触影）。
  - 100% 局限在 SwiftUI 圆角胶囊之内的剪裁，彻底抛弃了原生 NSVisualEffectView 的 behind-window 混合在 WindowServer 层面强行对物理矩形窗口进行磨砂而导致的直角方形漏角缺陷。
  - 悬浮窗宽度应随流式字符的长度自适应向右铺展。

### 2.2 多 ASR 引擎管理与按需下载
- **引擎切换**：用户可在菜单栏托盘或偏好设置中切换以下四种 ASR 引擎：
  1. **苹果内置 (Speech Framework)**：无需下载，即开即用。
  2. **极小流式模型 (Paraformer-mini)**：约 200MB，支持快速流式中英识别。
  3. **中等流式模型 (Zipformer-bilingual)**：中英双语流式。
  4. **高精度模型 (SenseVoice-Small)**：阿里巴巴开源的离线高性能多语言模型，支持中、英、粤、日、韩、粤语等，能自动输出标点符号及进行逆文本正则化（ITN，如将“二零二六”自动转为“2026”）。
- **模型按需托管与解包**：
  - 用户首次选择本地 ONNX 模型时，程序在后台启动 `URLSession` 自动断点下载。
  - **国内下载加速**：针对 GitHub Releases 容易被墙或限速的问题，代码中应拦截 GitHub 下载链接并自动拼装 `ghfast.top` 等镜像代理，提升国内用户的首次下载成功率。
  - 下载完成后使用 macOS 系统内置的 `tar` 自动解包并校验 `tokens.txt` 与 `model.int8.onnx` 文件，确认无误后激活该引擎。

### 2.3 混合流式输入架构 (SenseVoice Hybrid Streaming)
为了解决高精度 `SenseVoice-Small` 离线模型在录音期间没有实时文字反馈的问题，系统须实现**双引擎并行分流机制**：
- **音频双分流（Parallel Routing）**：
  - 麦克风录入的 PCM 样本（16kHz 16bit 单声道）实时追加到 SenseVoice 缓存数组中。
  - 同时，将格式化后的音频 Buffer 实时推送给苹果原生的 `SFSpeechAudioBufferRecognitionRequest`。
- **流式预览渲染**：
  - 在录音期间，由苹果原生听写引擎生成实时的、低延迟的增量文本流，不断驱动悬浮窗文字更新与动画展开。
- **高精结果覆盖**：
  - 录音停止时，立即切断并停用原生引擎，抛弃所有后续的原生回调（避免脏数据回流污染）。
  - 瞬间启动本地 SenseVoice 推理，读取完整的 PCM 数据包，进行多语言、高精度的快速离线转写。
  - 用 SenseVoice 最终输出的带有完美标点、高准确度的文本**覆盖**之前的 Apple ASR 临时文本，并模拟按键打入光标所在输入框。

---

## 3. 技术规格与关键调试记录

### 3.1 C-API 桥接与动态链接库 (libsherpa-onnx)
- 软件通过 Swift 调用桥接头文件（`VoiceFlow-Bridging-Header.h`）对 `libsherpa-onnx-c-api` 进行直接绑定。
- **动态装载修复**：
  - `libsherpa-onnx-c-api.dylib` 内部隐式依赖 `libonnxruntime.dylib`。
  - 编译打包时，在 `build.sh` 中使用 `install_name_tool` 对 dylib 的相互依赖路径进行修正，将它们重新指向 `@loader_path` 以实现免安装的 App 独立运行包：
    ```bash
    install_name_tool -change "libonnxruntime.dylib" "@loader_path/libonnxruntime.dylib" "VoiceFlow.app/Contents/Frameworks/libsherpa-onnx-c-api.dylib"
    ```
- **Ad-hoc 签名**：
  - 任何对 App Bundle 内 dylib 装载路径的修改都会破坏原本的二进制代码签名，导致 App 运行即闪退。
  - 构建脚本在打包的最后阶段，必须递归地对 `.app` 内所有库和主程序进行本地 Ad-hoc 代码签名：
    ```bash
    xattr -cr "VoiceFlow.app" && codesign --force --deep --sign - "VoiceFlow.app"
    ```

### 3.2 苹果原生 ASR 重启及安全网防线（防止闪退及文字污染）
在处理苹果原生听写引擎（`SFSpeechRecognitionTask`）的生命周期时，存在如下技术难点与调试优化：
- **防止取消级联风暴**：
  - **现象**：当旧任务仍在接收回调时，新任务的启动会对其发送 `.cancel()`，而 `.cancel()` 触发的回调内又极易因时序错乱触发级联重启，导致 App 在后台进入死循环甚至死机。
  - **优化**：在启动新识别任务前，先在主线程切断引用（`self.nativeTask = nil`），再调用 `oldTask?.cancel()`。这样旧任务的 Callback 执行时，`self.nativeTask === currentTask` 比对直接失效，完美阻断级联取消。
- **时间窗与安全网（防线）**：
  - 设定重启时间窗保护：距离上一次启动 Task 的时间必须大于 `1.2秒` 才能再次触发重启，防止高频 cancel 产生的级联回荡清空文本。
  - 文本长度安全网：只有当新拼接出的 ASR 文本长度大于已记录的 `historyText` 长度时，才允许用新文本更新状态，防止空回调在竞争时序中将已有的识别文字抹去。

### 3.3 AppKit 独立生命周期与多窗口冲突修复
- **单窗口与静默托盘启动**：
  - 摒弃了 SwiftUI 2.0 `@main` 属性引入的自动 Window 场景接管（该机制在无 Xcode Storyboard 模板的 App 切换激活策略时会强行渲染出一个空白窗口，且无法被强行 orderOut 彻底关闭）。
  - 引入纯 AppKit 的 [main.swift](file:///Users/hujia/.gemini/antigravity/worktrees/2026-06_voiceflow/fix-ui-initial-bugs/VoiceFlow/main.swift) 接管整个应用的运行入口，并维护了一个强引用的全局 `AppDelegate` 实例。应用完全以静默菜单托盘模式（`LSUIElement=1`）启动，彻底消灭了双窗口问题。
- **取消启动时自动激活偏好设置**：
  - 取消了原版本启动时自动强制激活 Settings 页面的设计，只在右上角状态栏展现简洁图标，用户可按需从托盘菜单点击进入，体验更加温和不打扰。
- **偏好设置窗口高度重构**：
  - 调整偏好设置窗口高度至 580：`contentRect: NSRect(x: 0, y: 0, width: 420, height: 580)`，使激活方式、热键、模型下载进度及授权状态一览无余，消除了滚动条。

---

## 4. 后续版本规划 (Roadmap)

### 4.1 UI 界面调优（已于 2026-06 分支重构交付）
- 悬浮窗宽度与文字字数变化的自适应动画弹性控制（解决文字快速跳动导致的框体闪烁问题）。
- 悬浮框边缘呼吸光晕效果，用于指示当前的音量大小（音频能量可视化）。
- 全局深浅色主题自适应（Dark/Light Mode 完美融入 macOS Sonoma/Sequoia）。

### 4.2 更多功能迭代
- 支持在偏好设置中编辑自定义热词过滤表，纠正特定专业术语的识别结果。
- 引入快捷指令触发及自定义短语替换。
