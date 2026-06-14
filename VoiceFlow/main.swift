import Cocoa

// 全局强引用，确保在 app 运行期间 100% 存活，防止被 ARC 自动销毁
var globalAppDelegate: AppDelegate?

autoreleasepool {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    globalAppDelegate = delegate
    app.delegate = delegate
    app.run()
}
