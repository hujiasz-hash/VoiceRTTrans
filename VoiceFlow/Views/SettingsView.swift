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
                    
                    // 4. 权限授权状态卡片
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
}
