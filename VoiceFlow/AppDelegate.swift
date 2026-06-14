import Cocoa
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    
    deinit {
        print("[VoiceFlow] ❌ 严重警告: AppDelegate 实例已被释放 (deinit)！")
    }
    
    // 状态托盘
    private var statusItem: NSStatusItem?
    
    // 悬浮面板与托管的 View
    private var overlayPanel: FloatingPanel?
    
    // 设置/偏好设置窗口
    private var settingsWindow: NSWindow?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 1. 优先初始化状态栏托盘，让其在最纯净的启动时刻渲染挂载
        setupStatusItem()
        
        // 2. 初始化键盘监听器与 ASR
        setupInteractions()
        
        // 3. 构造无焦点悬浮窗
        setupOverlayPanel()
        
        // 4. 首次启动主动弹出“偏好设置”窗口，延迟 0.3 秒执行以避免启动时激活策略切换导致的托盘刷新冲突
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.showSettings()
        }
    }
    
    // MARK: - 交互装配
    
    private func setupInteractions() {
        let monitor = GlobalInputMonitor.shared
        let recognizer = SpeechRecognizer.shared
        let audioManager = AudioStreamManager.shared
        
        // 当按下热键开始录音时
        monitor.onStartRecording = { [weak self] in
            guard let self = self else { return }
            
            // 展现悬浮面板
            self.showOverlayPanel()
            
            // 动态切换为录音中图标
            self.updateStatusIcon(named: "icon_tray_recording")
            
            // 启动录音与识别
            do {
                try audioManager.startRecording()
                recognizer.startRecognition()
            } catch {
                print("[VoiceFlow] 启动麦克风失败: \(error)")
                recognizer.currentText = "❌ 麦克风访问失败"
            }
        }
        
        // 当松开热键或按任意键切断录音时
        monitor.onStopRecording = { [weak self] in
            guard let self = self else { return }
            
            // 动态切换为识别中图标
            self.updateStatusIcon(named: "icon_tray_polishing")
            
            // 结束识别并自动注入粘贴
            recognizer.stopRecognition { finalOutput in
                if !finalOutput.isEmpty {
                    TextInjector.injectTextViaPasteboard(finalOutput)
                }
                
                // 延迟淡出隐藏悬浮面板，提供视觉缓冲并切回普通图标
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.hideOverlayPanel()
                    self.updateStatusIcon(named: "icon_tray")
                }
            }
            audioManager.stopRecording()
        }
        
        // 启动 EventTap 监听
        _ = monitor.startMonitoring()
    }
    
    /// 动态修改状态栏的托盘图标
    private func updateStatusIcon(named name: String) {
        print("[VoiceFlow] 尝试更新托盘图标为: \(name)...")
        guard let button = statusItem?.button else {
            print("[VoiceFlow] ❌ 失败: statusItem.button 不存在")
            return
        }
        
        var image: NSImage? = nil
        // 优先尝试从 Bundle 路径读取 PNG
        if let path = Bundle.main.path(forResource: name, ofType: "png") {
            image = NSImage(contentsOfFile: path)
            print("[VoiceFlow] 从 Bundle 路径成功读取: \(path)")
        }
        
        // Fallback 尝试使用 NSImage(named:)
        if image == nil {
            image = NSImage(named: name)
            if image != nil {
                print("[VoiceFlow] 通过 NSImage(named:) 成功加载: \(name)")
            }
        }
        
        if let customImage = image {
            // 关键：对物理分辨率是 64x64 的图片强制指定渲染逻辑大小为 18x18
            customImage.size = NSSize(width: 18, height: 18)
            customImage.isTemplate = true
            button.image = customImage
            print("[VoiceFlow] 自定义图标已成功设置到状态栏，并强制设定尺寸为 18x18")
        } else {
            print("[VoiceFlow] ⚠️ 加载自定义图标失败，正在退回至 SF Symbols...")
            let fallbackName = name == "icon_tray_recording" ? "mic.circle.fill" : "waveform.circle"
            if let fallbackImage = NSImage(systemSymbolName: fallbackName, accessibilityDescription: "VoiceFlow") {
                fallbackImage.isTemplate = true
                button.image = fallbackImage
                print("[VoiceFlow] 成功设置 SF Symbols 图标: \(fallbackName)")
            } else {
                print("[VoiceFlow] ❌ 严重错误: SF Symbols '\(fallbackName)' 加载失败")
            }
        }
    }
    
    // MARK: - 托盘与窗口管理
    
    private func setupStatusItem() {
        print("[VoiceFlow] 初始化状态栏托盘按钮...")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.title = "VF"
            print("[VoiceFlow] 成功获取 statusItem.button，设置临时 title='VF'，开始加载默认图标 'icon_tray'")
            
            var image: NSImage? = nil
            // 优先尝试从 Bundle 路径读取 PNG
            if let path = Bundle.main.path(forResource: "icon_tray", ofType: "png") {
                image = NSImage(contentsOfFile: path)
                print("[VoiceFlow] 默认图标从 Bundle 路径加载成功")
            }
            
            if image == nil {
                image = NSImage(named: "icon_tray")
                if image != nil {
                    print("[VoiceFlow] 默认图标通过 NSImage(named:) 加载成功")
                }
            }
            
            if let customImage = image {
                customImage.size = NSSize(width: 18, height: 18)
                customImage.isTemplate = true
                button.image = customImage
                print("[VoiceFlow] 默认自定义图标加载并设置成功 (18x18)")
            } else {
                print("[VoiceFlow] ⚠️ 默认自定义图标加载失败，退回至 SF Symbol 'waveform.circle'...")
                if let fallbackImage = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "VoiceFlow") {
                    fallbackImage.isTemplate = true
                    button.image = fallbackImage
                    print("[VoiceFlow] 成功设置默认 SF Symbol 图标")
                } else {
                    print("[VoiceFlow] ❌ 严重错误: 默认 SF Symbol 'waveform.circle' 加载失败")
                }
            }
        } else {
            print("[VoiceFlow] ❌ 严重错误: 无法获取 statusItem.button")
        }
        
        // 构造托盘下拉菜单并直接绑定到 statusItem，以实现更原生的点击交互且避免 popUpMenu 废弃警告
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "偏好设置...", action: #selector(showSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出 VoiceFlow", action: #selector(terminateApp), keyEquivalent: "q"))
        statusItem?.menu = menu
        print("[VoiceFlow] 托盘菜单绑定完成")
    }
    
    private func setupOverlayPanel() {
        let overlayView = SpeechOverlayView()
        let hostingView = NSHostingView(rootView: overlayView)
        
        // 计算位置：居中于主屏幕底部
        let screenSize = NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900)
        let initialWidth: CGFloat = 160 // 最小初始宽度
        let initialHeight: CGFloat = 42
        
        let rect = NSRect(
            x: (screenSize.width - initialWidth) / 2,
            y: 120, // 距离屏幕底部 120pt
            width: initialWidth,
            height: initialHeight
        )
        
        overlayPanel = FloatingPanel(contentRect: rect)
        overlayPanel?.contentView = hostingView
    }
    
    private func showOverlayPanel() {
        guard let panel = overlayPanel else { return }
        
        // 重新居中定位（防止用户切换了外接显示器或分辨率发生变化）
        if let mainScreen = NSScreen.main {
            let screenSize = mainScreen.frame.size
            let panelWidth = panel.frame.width
            let newFrame = NSRect(
                x: (screenSize.width - panelWidth) / 2,
                y: 120,
                width: panelWidth,
                height: panel.frame.height
            )
            panel.setFrame(newFrame, display: true)
        }
        
        panel.alphaValue = 0.0
        panel.makeKeyAndOrderFront(nil)
        
        // 淡入动画
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1.0
        }
    }
    
    private func hideOverlayPanel() {
        guard let panel = overlayPanel else { return }
        
        // 淡出动画
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0.0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }
    
    // MARK: - 偏好设置窗口装配
    
    @objc func showSettings() {
        if settingsWindow != nil {
            // 已打开，直接带到最前
            settingsWindow?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        
        // 激活 Dock 图标与菜单栏
        toggleDockIcon(show: true)
        
        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 380),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        window.center()
        window.title = "VoiceFlow 偏好设置"
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        
        // 监听关闭事件以还原后台运行模式
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsWindowClosed),
            name: NSWindow.willCloseNotification,
            object: window
        )
        
        self.settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc private func settingsWindowClosed(notification: Notification) {
        guard let window = notification.object as? NSWindow, window == settingsWindow else { return }
        
        // 隐藏 Dock 图标回到托盘状态
        toggleDockIcon(show: false)
        self.settingsWindow = nil
        
        // 移去通知观察者
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
    }
    
    /// 动态显示或隐藏应用在 Dock 栏的图标
    func toggleDockIcon(show: Bool) {
        if show {
            // 常规应用模式 (显示 Dock 和主菜单)
            NSApp.setActivationPolicy(.regular)
        } else {
            // 代理后台模式 (不显示 Dock 图标，不夺取应用切换焦点)
            NSApp.setActivationPolicy(.accessory)
        }
        // 强制刷新当前 App 激活状态
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
    
    @objc private func terminateApp() {
        GlobalInputMonitor.shared.stopMonitoring()
        AudioStreamManager.shared.stopRecording()
        NSApp.terminate(nil)
    }
}
