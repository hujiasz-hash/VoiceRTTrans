import Cocoa

class TextInjector {
    
    /// 将文本安全粘贴到当前激活焦点的文本框中，并在粘贴后自动恢复原剪贴板内容
    static func injectTextViaPasteboard(_ text: String) {
        var processedText = text
        
        let filterFiller = UserDefaults.standard.object(forKey: "filterFillerWords") as? Bool ?? true
        let formatStructured = UserDefaults.standard.object(forKey: "enableStructuredFormatting") as? Bool ?? true
        
        if filterFiller {
            processedText = ASRTextProcessor.filterFillerWords(processedText)
        }
        if formatStructured {
            processedText = ASRTextProcessor.formatStructuredInput(processedText)
        }
        
        if processedText.isEmpty {
            return
        }
        
        let pasteboard = NSPasteboard.general
        
        // 1. 备份原剪贴板内容（保存所有支持的类型和数据）
        var savedItems: [NSPasteboardItem] = []
        if let items = pasteboard.pasteboardItems {
            for item in items {
                let archivedItem = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) {
                        archivedItem.setData(data, forType: type)
                    }
                }
                savedItems.append(archivedItem)
            }
        }
        
        // 2. 将识别文本写入剪贴板
        pasteboard.clearContents()
        pasteboard.declareTypes([.string], owner: nil)
        pasteboard.setString(processedText, forType: .string)
        
        // 3. 模拟键盘按下 Command + V 组合键进行粘贴
        simulateCommandV()
        
        // 4. 延迟 150 毫秒，待目标程序将文字读取入框后，再默默还原用户的原始剪贴板
        // 150ms 是针对慢速富文本输入框（如 Web 微信、网页表单）的安全经验值
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            pasteboard.clearContents()
            if !savedItems.isEmpty {
                pasteboard.writeObjects(savedItems)
            }
        }
    }
    
    /// 发送全局虚拟键盘事件以模拟 Command+V 按下与释放
    private static func simulateCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        
        // 'V' 的虚拟键码在 macOS 下是 9
        guard let vKeyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) else { return }
        vKeyDown.flags = .maskCommand
        
        guard let vKeyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return }
        vKeyUp.flags = .maskCommand
        
        // 向全局 HID 机制派发事件
        vKeyDown.post(tap: .cgSessionEventTap)
        vKeyUp.post(tap: .cgSessionEventTap)
    }
}
