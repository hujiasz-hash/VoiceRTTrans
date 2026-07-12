import Cocoa
import Carbon
import CoreGraphics
import Combine

enum RecordingMode: Int, Codable {
    case pushToTalk = 0          // 模式 A (按住说话)
    case toggleOrAnyKeyStop = 1   // 模式 B (单击开关/任意键停止)
}

enum RecordingState {
    case idle
    case recording(mode: RecordingMode)
}

class GlobalInputMonitor: ObservableObject {
    static let shared = GlobalInputMonitor()
    
    // 全局配置参数 (响应式发布，支持 UI 双向绑定)
    @Published var currentMode: RecordingMode {
        didSet {
            UserDefaults.standard.set(currentMode.rawValue, forKey: "VoiceFlow_recordingMode")
        }
    }
    
    // 默认热键配置：Option (Carbon 键码: 58 (左Option) / 61 (右Option))
    // 默认使用右 Option (键码 61) 作为热键
    @Published var hotkeyKeyCode: UInt16 {
        didSet {
            UserDefaults.standard.set(hotkeyKeyCode, forKey: "VoiceFlow_hotkeyKeyCode")
        }
    }
    @Published var hotkeyFlags: CGEventFlags {
        didSet {
            UserDefaults.standard.set(hotkeyFlags.rawValue, forKey: "VoiceFlow_hotkeyFlags")
        }
    }
    
    // 是否为纯修饰键（如 Option, Command, Control, Shift）
    private var isModifierOnlyHotkey: Bool {
        return hotkeyKeyCode == 58 || hotkeyKeyCode == 61 || // Option
               hotkeyKeyCode == 55 || hotkeyKeyCode == 54 || // Command
               hotkeyKeyCode == 59 || hotkeyKeyCode == 62 || // Control
               hotkeyKeyCode == 56 || hotkeyKeyCode == 60    // Shift
    }
    
    // 回调通知
    var onStartRecording: (() -> Void)?
    var onStopRecording: (() -> Void)?
    
    private var eventTapPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var state: RecordingState = .idle
    private var retryTimer: Timer?
    private var tapCreateFailCount = 0
    private var ignoreNextModifierRelease = false
    
    // 关键设计：缓存被吞除的按键 keyCode 及其事件类型，用于防止按键粘滞 (Key Sticking)
    private var swallowedKeyCode: UInt16? = nil
    private var isSwallowedKeyModifier = false
    
    private init() {
        if let savedModeRaw = UserDefaults.standard.value(forKey: "VoiceFlow_recordingMode") as? Int,
           let savedMode = RecordingMode(rawValue: savedModeRaw) {
            self._currentMode = Published(initialValue: savedMode)
        } else {
            self._currentMode = Published(initialValue: .toggleOrAnyKeyStop)
        }
        
        if let savedCode = UserDefaults.standard.value(forKey: "VoiceFlow_hotkeyKeyCode") as? UInt16 {
            self._hotkeyKeyCode = Published(initialValue: savedCode)
        } else {
            self._hotkeyKeyCode = Published(initialValue: 61)
        }
        
        if let savedFlags = UserDefaults.standard.value(forKey: "VoiceFlow_hotkeyFlags") as? UInt64 {
            self._hotkeyFlags = Published(initialValue: CGEventFlags(rawValue: savedFlags))
        } else {
            self._hotkeyFlags = Published(initialValue: [.maskAlternate])
        }
    }
    
    /// 检查并检测辅助功能权限
    func checkAccessibilityPermissions(promptUser: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: promptUser] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
    
    /// 启动 EventTap 监听
    func startMonitoring() -> Bool {
        guard eventTapPort == nil else { return true }
        
        // 静默检测，如果没有权限则返回 false，在后台启动轮询
        if !checkAccessibilityPermissions(promptUser: false) {
            print("[VoiceFlow] 启动监听失败：缺少辅助功能（Accessibility）权限。将自动在后台轮询等待权限授予...")
            startRetryTimer()
            return false
        }
        
        // 监听 KeyDown, KeyUp 与 FlagsChanged
        let eventMask = (1 << CGEventType.keyDown.rawValue) |
                        (1 << CGEventType.keyUp.rawValue) |
                        (1 << CGEventType.flagsChanged.rawValue)
        
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        
        eventTapPort = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<GlobalInputMonitor>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: selfPointer
        )
        
        guard let tap = eventTapPort else {
            print("[VoiceFlow] 创建 EventTap 失败。尽管系统报告已授权辅助功能权限，但底层创建失败。这通常意味着 macOS TCC 数据库的签名缓存失效，请在“系统设置 -> 隐私与安全性 -> 辅助功能”中移除 VoiceFlow 并重新添加。")
            tapCreateFailCount += 1
            if tapCreateFailCount <= 3 {
                startRetryTimer()
            } else {
                print("[VoiceFlow] 底层创建 EventTap 连续失败多次，已停止自动重试，等待用户手动重启或重新授权。")
                stopRetryTimer()
            }
            return false
        }
        
        // 成功创建，重置计数器和定时器
        tapCreateFailCount = 0
        stopRetryTimer()
        
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            print("[VoiceFlow] 全局热键 EventTap 启动成功。")
            return true
        }
        
        startRetryTimer()
        return false
    }
    
    /// 停止 EventTap 监听
    func stopMonitoring() {
        stopRetryTimer()
        if let tap = eventTapPort {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTapPort = nil
        runLoopSource = nil
        state = .idle
        swallowedKeyCode = nil
    }
    
    private func startRetryTimer() {
        guard retryTimer == nil else { return }
        
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.retryTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                print("[VoiceFlow] 轮询尝试建立 EventTap...")
                if self.startMonitoring() {
                    print("[VoiceFlow] 轮询成功，EventTap 已激活，停止轮询定时器。")
                }
            }
        }
    }
    
    private func stopRetryTimer() {
        retryTimer?.invalidate()
        retryTimer = nil
    }
    
    /// 核心事件处理与状态机流转
    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 自动恢复超时被系统禁用的 EventTap
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTapPort {
                CGEvent.tapEnable(tap: tap, enable: true)
                print("[VoiceFlow] EventTap 被系统重新启用")
            }
            return nil
        }
        
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        
        // 1. 判断是否是配置的目标热键
        let isHotkey = checkIsHotkey(keyCode: keyCode, flags: flags, type: type)
        
        switch state {
        case .idle:
            // 防按键粘滞：在空闲状态下，如果收到之前被吞掉的“任意停止键”的释放事件，则予以拦截并吞掉
            if type == .keyUp {
                if let swallowed = swallowedKeyCode, keyCode == swallowed {
                    self.swallowedKeyCode = nil
                    return nil // 吞掉 KeyUp
                }
            } else if type == .flagsChanged && isModifierOnlyHotkey {
                // 如果是纯修饰键热键，防粘滞：在 flagsChanged 中如果释放了它，也清除 swallowed 状态
                if let swallowed = swallowedKeyCode, keyCode == swallowed && !isModifierPressed(flags) {
                    self.swallowedKeyCode = nil
                    return nil
                }
            }
            
            // 触发录音启动
            if isHotkey {
                // 如果是普通按键，需要是在按下 (keyDown) 时启动
                // 如果是修饰键热键，检测到对应的 flag 变化
                if !isModifierOnlyHotkey && type == .keyDown {
                    triggerStart()
                    return nil // 吞掉按键，不进入输入框
                } else if isModifierOnlyHotkey && type == .flagsChanged && isModifierPressed(flags) {
                    triggerStart()
                    return nil // 吞掉修饰键按下
                }
            }
            
        case .recording(let mode):
            if mode == .pushToTalk {
                // 【模式 A (按住说话)】：检测到热键释放即刻停止
                if isHotkey {
                    if !isModifierOnlyHotkey && type == .keyUp {
                        triggerStop()
                        return nil // 吞掉热键释放
                    } else if isModifierOnlyHotkey && type == .flagsChanged && !isModifierPressed(flags) {
                        triggerStop()
                        return nil // 吞掉修饰键释放
                    }
                }
                // 录音期间，透传其他所有键盘输入以防打断用户的交互
                return Unmanaged.passRetained(event)
                
            } else {
                // 【模式 B (单击开关/任意键停止)】：
                // 录音期间，一旦收到任何键盘按键的按下事件（KeyDown/或者是热键再次按下），立即触发停止
                
                if type == .flagsChanged {
                    if isHotkey {
                        if isModifierPressed(flags) {
                            // 再次按下热键修饰键，触发停止
                            triggerStop()
                            return nil
                        } else {
                            // 释放热键修饰键
                            if ignoreNextModifierRelease {
                                ignoreNextModifierRelease = false
                                return nil // 吞掉第一次松开
                            } else {
                                triggerStop()
                                return nil
                            }
                        }
                    }
                    return Unmanaged.passRetained(event)
                }
                
                if type == .keyDown {
                    // 标记该按键已被吞掉，当下一次 keyUp 到达时由防粘滞逻辑吞除
                    self.swallowedKeyCode = keyCode
                    self.isSwallowedKeyModifier = false
                    triggerStop()
                    return nil // 吞掉任意键的按下，不污染当前文本框
                }
            }
        }
        
        return Unmanaged.passRetained(event)
    }
    
    private func checkIsHotkey(keyCode: UInt16, flags: CGEventFlags, type: CGEventType) -> Bool {
        if isModifierOnlyHotkey {
            return keyCode == hotkeyKeyCode
        } else {
            let modifierMasks: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
            let eventModifiers = flags.intersection(modifierMasks)
            let targetModifiers = hotkeyFlags.intersection(modifierMasks)
            return keyCode == hotkeyKeyCode && eventModifiers == targetModifiers
        }
    }
    
    private func isModifierPressed(_ flags: CGEventFlags) -> Bool {
        switch hotkeyKeyCode {
        case 58, 61: // Option
            return flags.contains(.maskAlternate)
        case 55, 54: // Command
            return flags.contains(.maskCommand)
        case 59, 62: // Control
            return flags.contains(.maskControl)
        case 56, 60: // Shift
            return flags.contains(.maskShift)
        default:
            return false
        }
    }
    
    private func triggerStart() {
        state = .recording(mode: currentMode)
        if currentMode == .toggleOrAnyKeyStop && isModifierOnlyHotkey {
            ignoreNextModifierRelease = true
        }
        DispatchQueue.main.async { [weak self] in
            self?.onStartRecording?()
        }
    }
    
    private func triggerStop() {
        state = .idle
        DispatchQueue.main.async { [weak self] in
            self?.onStopRecording?()
        }
    }
    
    /// 强制停止当前录音状态（例如在音频流或者硬件设备配置改变时）
    func forceStopRecording() {
        print("[VoiceFlow] 全局输入监听器被强制停止录音状态")
        if case .recording = state {
            triggerStop()
        }
    }
}
