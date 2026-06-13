import SwiftUI

@main
struct VoiceFlowApp: App {
    // 绑定原生 AppDelegate 作为应用的生命周期代理
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        // 使用 Settings 场景作为主 Scene，且内容置空
        // 这在 macOS 上能完美隐藏默认的主 WindowGroup 弹窗，实现开机/启动时静默驻留托盘
        Settings {
            EmptyView()
        }
    }
}
