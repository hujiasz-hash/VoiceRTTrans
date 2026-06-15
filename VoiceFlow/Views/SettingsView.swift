import SwiftUI

// MARK: - 全局热键配置结构体 (适配 Swift 5.3 严格的数据一致性协议)
struct HotkeyConfig: Identifiable, Hashable {
    var id: UInt16 { code }
    let name: String
    let code: UInt16
    let flags: CGEventFlags
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(code)
    }
    
    static func == (lhs: HotkeyConfig, rhs: HotkeyConfig) -> Bool {
        return lhs.code == rhs.code
    }
}

// 静态常量热键列表
private let hotkeysList = [
    HotkeyConfig(name: "右 Option 键", code: 61, flags: .maskAlternate),
    HotkeyConfig(name: "左 Option 键", code: 58, flags: .maskAlternate),
    HotkeyConfig(name: "右 Command 键", code: 54, flags: .maskCommand),
    HotkeyConfig(name: "F2 键", code: 120, flags: CGEventFlags(rawValue: 0)),
    HotkeyConfig(name: "F5 键", code: 96, flags: CGEventFlags(rawValue: 0)),
    HotkeyConfig(name: "引撇/波浪号 键 (`)", code: 50, flags: CGEventFlags(rawValue: 0))
]

struct SettingsView: View {
    // 改用 @StateObject 以解决老版本 Swift 的重绘与渲染期死锁问题
    @StateObject private var recognizer = SpeechRecognizer.shared
    @StateObject private var monitor = GlobalInputMonitor.shared
    
    @AppStorage("filterFillerWords") private var filterFillerWords = true
    @AppStorage("enableStructuredFormatting") private var enableStructuredFormatting = true
    
    @State private var selectedHotkeyIndex = 0
    @State private var permissionStatus = false
    
    // 计算属性 Binding，用于替代 onChange
    private var hotkeySelection: Binding<Int> {
        Binding<Int>(
            get: { self.selectedHotkeyIndex },
            set: { newValue in
                self.selectedHotkeyIndex = newValue
                let chosen = hotkeysList[newValue]
                self.monitor.hotkeyKeyCode = chosen.code
                self.monitor.hotkeyFlags = chosen.flags
                print("[VoiceFlow] 全局热键已变更为: \(chosen.name)")
            }
        )
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // 顶栏页眉
            HStack {
                Text("VoiceFlow 偏好设置")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Image(systemName: "waveform.circle.fill")
                    .font(.title3)
                    .foregroundColor(.accentColor)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor).opacity(0.4))
            
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    
                    // 1. 激活控制卡片
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "bolt.fill")
                                .foregroundColor(.orange)
                            Text("激活方式")
                                .font(.subheadline)
                                .bold()
                        }
                        
                        Picker("录音模式", selection: $monitor.currentMode) {
                            Text("按住说话，松开即入").tag(RecordingMode.pushToTalk)
                            Text("单击开始，任意键停止").tag(RecordingMode.toggleOrAnyKeyStop)
                        }
                        .pickerStyle(RadioGroupPickerStyle())
                        .padding(.vertical, 4)
                        
                        Text(monitor.currentMode == .pushToTalk 
                             ? "💡 按住全局热键开始说话，松开按键瞬间完成打字并自动上屏。" 
                             : "💡 点击热键开始说话，再次点击该键或在键盘上敲击**任何其他按键**立即打字上屏。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Divider()
                            .padding(.vertical, 2)
                        
                        Toggle("开机自动启动", isOn: $recognizer.launchAtLogin)
                            .toggleStyle(CheckboxToggleStyle())
                            .font(.subheadline)
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                    
                    // 2. 全局快捷键卡片
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "keyboard")
                                .foregroundColor(.blue)
                            Text("全局热键")
                                .font(.subheadline)
                                .bold()
                        }
                        
                        HStack {
                            Picker("热键选择", selection: hotkeySelection) {
                                ForEach(0..<6, id: \.self) { idx in
                                    Text(hotkeysList[idx].name).tag(idx)
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                    
                    // 3. ASR 本地模型卡片
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 6) {
                            Image(systemName: "cpu")
                                .foregroundColor(.purple)
                            Text("语音识别 (ASR) 本地引擎")
                                .font(.subheadline)
                                .bold()
                        }
                        
                        Picker("选择模型", selection: $recognizer.selectedModel) {
                            ForEach(ModelType.allCases, id: \.self) { model in
                                                Text(model.name).tag(model)
                            }
                        }
                        
                        if recognizer.selectedModel == .native || recognizer.selectedModel == .senseVoice {
                            HStack {
                                Text("识别语言")
                                    .font(.subheadline)
                                Spacer()
                                Picker("", selection: $recognizer.selectedLanguage) {
                                    Text("自动").tag("auto")
                                    Text("中文").tag("zh")
                                    Text("英文").tag("en")
                                }
                                .pickerStyle(SegmentedPickerStyle())
                                .labelsHidden()
                                .frame(width: 160)
                            }
                            .padding(.top, 4)
                        }
                        
                        if recognizer.selectedModel == .native {
                            Text("✅ 采用 macOS 系统原生 Speech 框架，零下载，ANE 硬件加速。")
                                .font(.caption)
                                .foregroundColor(.green)
                        } else {
                            if recognizer.isModelDownloaded(recognizer.selectedModel) {
                                Text("✅ 模型已就绪，保存在本地。")
                                    .font(.caption)
                                    .foregroundColor(.green)
                            } else {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("⚠️ 模型未下载，需要在线获取包（约需下载 \(recognizer.selectedModel == .paraformerMini ? "79MB" : recognizer.selectedModel == .zipformerBilingual ? "180MB" : "230MB")，解压后即刻离线运行）。")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                    
                                    if recognizer.isDownloading {
                                        HStack(spacing: 12) {
                                            ProgressView(value: recognizer.downloadProgress)
                                                .progressViewStyle(LinearProgressViewStyle())
                                                .frame(maxWidth: .infinity)
                                            
                                            Text(String(format: "%.0f%%", recognizer.downloadProgress * 100))
                                                .font(.caption)
                                                .bold()
                                        }
                                    } else {
                                        Button(action: {
                                            let targetToDownload = recognizer.selectedModel
                                            recognizer.downloadModel(for: targetToDownload) { success in
                                                if success {
                                                    print("[VoiceFlow] 本地模型下载成功")
                                                } else {
                                                    print("[VoiceFlow] 本地模型下载失败")
                                                }
                                            }
                                        }) {
                                            Text("立即下载模型")
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                    
                    // 3.5 ASR 自定义纠偏卡片
                    VStack(alignment: .leading, spacing: 10) {
                        DisclosureGroup("ASR 自定义纠偏词典") {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("💡 每一行一条规则，格式为：`识别错的词 -> 正确的词`")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.top, 6)
                                
                                TextEditor(text: $recognizer.customCorrectionsText)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(height: 80)
                                    .cornerRadius(6)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                                    )
                                
                                HStack(spacing: 8) {
                                    Button(action: importCorrections) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "square.and.arrow.down")
                                            Text("导入词典")
                                        }
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .foregroundColor(.accentColor)
                                    
                                    Button(action: exportCorrections) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "square.and.arrow.up")
                                            Text("导出词典")
                                        }
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .foregroundColor(.accentColor)
                                    
                                    Spacer()
                                    
                                    Button(action: exportDictationHistory) {
                                        HStack(spacing: 4) {
                                            Image(systemName: "doc.text")
                                            Text("导出历史 (给AI)")
                                        }
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .foregroundColor(.accentColor)
                                    
                                    Button(action: clearDictationHistoryConfirm) {
                                        Image(systemName: "trash")
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(PlainButtonStyle())
                                    .help("清空所有听写历史记录")
                                }
                                .font(.caption)
                                .padding(.top, 6)
                            }
                        }
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                    
                    // 4. 文本自动优化卡片
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .foregroundColor(Color(NSColor.systemTeal))
                            Text("文本自动优化")
                                .font(.subheadline)
                                .bold()
                        }
                        
                        VStack(spacing: 8) {
                            Toggle("过滤多余语气词 (如：呃、啊、嗯、那个等)", isOn: $filterFillerWords)
                                .toggleStyle(CheckboxToggleStyle())
                                .frame(maxWidth: .infinity, alignment: .leading)
                            
                            Toggle("智能列表排版 (自动分段 12345 结构化输入)", isOn: $enableStructuredFormatting)
                                .toggleStyle(CheckboxToggleStyle())
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 4)
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                    
                    // 5. 权限授权状态卡片
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.shield")
                                .foregroundColor(.green)
                            Text("权限授权状态")
                                .font(.subheadline)
                                .bold()
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("辅助功能 (Accessibility) 权限:")
                                Spacer()
                                if permissionStatus {
                                    Text("已授权").foregroundColor(.green).bold()
                                } else {
                                    Text("未授权").foregroundColor(.red).bold()
                                }
                            }
                            
                            if !permissionStatus {
                                Button("去系统设置开启权限") {
                                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                        NSWorkspace.shared.open(url)
                                    }
                                }
                                .font(.caption)
                            }
                        }
                    }
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                }
                .padding()
            }
        }
        // 显式限制大小，强行撑起 NSHostingController 的尺寸，绝对不让其折叠
        .frame(width: 420, height: 580)
        .onAppear {
            if let idx = hotkeysList.firstIndex(where: { $0.code == monitor.hotkeyKeyCode }) {
                selectedHotkeyIndex = idx
            }
            
            checkPermissions()
            Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
                checkPermissions()
            }
        }
    }
    
    private func checkPermissions() {
        let auth = monitor.checkAccessibilityPermissions(promptUser: false)
        if permissionStatus != auth {
            permissionStatus = auth
            if auth {
                _ = monitor.startMonitoring()
            }
        }
    }
    
    private func importCorrections() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedFileTypes = ["txt"]
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                let cleanedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleanedContent.isEmpty {
                    if recognizer.customCorrectionsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        recognizer.customCorrectionsText = cleanedContent
                    } else {
                        recognizer.customCorrectionsText += "\n" + cleanedContent
                    }
                }
                print("[VoiceFlow] 成功导入纠偏词典")
            } catch {
                print("[VoiceFlow] 导入失败: \(error.localizedDescription)")
            }
        }
    }
    
    private func exportCorrections() {
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["txt"]
        panel.nameFieldStringValue = "voiceflow_corrections.txt"
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try recognizer.customCorrectionsText.write(to: url, atomically: true, encoding: .utf8)
                print("[VoiceFlow] 成功导出纠偏词典")
            } catch {
                print("[VoiceFlow] 导出失败: \(error.localizedDescription)")
            }
        }
    }
    
    private func exportDictationHistory() {
        let logURL = recognizer.dictationHistoryURL
        guard FileManager.default.fileExists(atPath: logURL.path) else {
            let alert = NSAlert()
            alert.messageText = "提示"
            alert.informativeText = "目前还没有录制过任何听写历史记录。"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "确定")
            alert.runModal()
            return
        }
        
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["txt"]
        panel.nameFieldStringValue = "voiceflow_dictation_history.txt"
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let content = try String(contentsOf: logURL, encoding: .utf8)
                try content.write(to: url, atomically: true, encoding: .utf8)
                print("[VoiceFlow] 成功导出听写历史")
            } catch {
                print("[VoiceFlow] 导出听写历史失败: \(error.localizedDescription)")
            }
        }
    }
    
    private func clearDictationHistoryConfirm() {
        let alert = NSAlert()
        alert.messageText = "确认清空"
        alert.informativeText = "确定要清空所有的原始听写记录日志吗？清空后将无法导出该语料给 AI 分析。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        
        if alert.runModal() == .alertFirstButtonReturn {
            recognizer.clearDictationHistory()
        }
    }
    
}
