import Cocoa
import SwiftUI

class FloatingPanel: NSPanel {
    
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            // .nonactivatingPanel 保证窗口激活时不抢占原焦点的 App 键盘输入
            // .borderless 无原生标题栏边框，.fullSizeContentView 允许内容填满整个容器
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        self.isFloatingPanel = true
        self.level = .statusBar // 置于状态栏层级之上，保障绝对置顶
        
        // 允许悬浮面板跨越所有的 Spaces（虚拟桌面）以及全屏应用
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        
        self.isOpaque = false
        self.backgroundColor = .clear // 透明背景，以便由 SwiftUI 毛玻璃面板接管外观
        
        self.hasShadow = true
        self.hidesOnDeactivate = false
        self.ignoresMouseEvents = false // 允许接收鼠标拖拽和点击（比如拖拽悬浮窗）
    }
    
    // 以下两处重写是无焦点悬浮窗的核心：防止窗口成为 Key Window/Main Window
    override var canBecomeKey: Bool {
        return false
    }
    
    override var canBecomeMain: Bool {
        return false
    }
}
