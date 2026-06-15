import Foundation
import Speech
import Combine

// Helper function to safely duplicate Swift string into a C string pointer
private func cString(_ str: String) -> UnsafePointer<Int8>? {
    guard let ptr = strdup(str) else { return nil }
    return UnsafePointer(ptr)
}


enum ModelType: Int, CaseIterable, Codable {
    case native = 0              // 苹果内置
    case paraformerMini = 1      // 极小模型 (Paraformer-mini)
    case zipformerBilingual = 2  // 中等模型 (Zipformer-bilingual 中英双语)
    case senseVoice = 3          // 较大性能好 (SenseVoice-Small)
    
    var name: String {
        switch self {
        case .native: return "苹果内置 (Speech Framework)"
        case .paraformerMini: return "极小流式模型 (Paraformer-mini)"
        case .zipformerBilingual: return "中等流式模型 (Zipformer-bilingual)"
        case .senseVoice: return "高精度模型 (SenseVoice-Small)"
        }
    }
    
    // 模型包下载链接
    var downloadURL: URL? {
        switch self {
        case .native: return nil
        case .paraformerMini:
            return URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-paraformer-bilingual-zh-en.tar.bz2")
        case .zipformerBilingual:
            return URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20.tar.bz2")
        case .senseVoice:
            return URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17.tar.bz2")
        }
    }
    
    // 下载后的压缩包文件名
    var archiveName: String? {
        guard let url = downloadURL else { return nil }
        return url.lastPathComponent
    }
    
    // 解压后的文件夹名称
    var folderName: String? {
        switch self {
        case .native: return nil
        case .paraformerMini: return "sherpa-onnx-streaming-paraformer-bilingual-zh-en"
        case .zipformerBilingual: return "sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20"
        case .senseVoice: return "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17"
        }
    }
}

class SpeechRecognizer: ObservableObject {
    static let shared = SpeechRecognizer()
    
    private var historyText: String = ""
    private var isRestartingTask = false
    private var lastStartTime: Date = Date()
    private var lastSeenText: String = ""
    private var lastCallbackTime: Date?
    
    @Published var currentText: String = ""
    @Published var isRecognizing: Bool = false
    @Published var selectedModel: ModelType = .native
    
    // ASR 语言设置：auto, zh, en
    @Published var selectedLanguage: String = "auto" {
        didSet {
            UserDefaults.standard.set(selectedLanguage, forKey: "selectedLanguage")
            updateNativeRecognizer()
        }
    }
    
    // ASR 自定义纠偏词典（每行 wrong -> right）
    @Published var customCorrectionsText: String = "" {
        didSet {
            UserDefaults.standard.set(customCorrectionsText, forKey: "customCorrectionsText")
        }
    }
    
    // 是否开机自启动
    @Published var launchAtLogin: Bool = false {
        didSet {
            updateLaunchAtLoginSetting()
        }
    }
    
    // 下载状态管理
    @Published var downloadProgress: Double = 0.0
    @Published var isDownloading = false
    
    // 1. 苹果原生 Speech 成员
    private var nativeRecognizer: SFSpeechRecognizer?
    private var nativeRequest: SFSpeechAudioBufferRecognitionRequest?
    private var nativeTask: SFSpeechRecognitionTask?
    
    // 2. Sherpa-onnx 流式/非流式 C 指针 (OpaquePointer)
    private var onlineRecognizer: OpaquePointer?
    private var onlineStream: OpaquePointer?
    private var offlineRecognizer: OpaquePointer?
    
    // 非流式模型（如 SenseVoice）音频缓存
    private var offlineAudioBuffer: [Float] = []
    
    
    private init() {
        let lang = UserDefaults.standard.string(forKey: "selectedLanguage") ?? "auto"
        self.selectedLanguage = lang
        
        self.customCorrectionsText = UserDefaults.standard.string(forKey: "customCorrectionsText") ?? ""
        
        // 检测本地 LaunchAgent 配置文件是否存在，以检测开机自启动真实状态
        let libraryDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let plistURL = libraryDir.appendingPathComponent("LaunchAgents/com.hujia.VoiceFlow.plist")
        self.launchAtLogin = FileManager.default.fileExists(atPath: plistURL.path)
        
        let localeId: String
        switch lang {
        case "zh": localeId = "zh-CN"
        case "en": localeId = "en-US"
        default: localeId = Locale.current.identifier.contains("en") ? "en-US" : "zh-CN"
        }
        self.nativeRecognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId))
    }
    
    private func updateNativeRecognizer() {
        let localeId: String
        switch selectedLanguage {
        case "zh": localeId = "zh-CN"
        case "en": localeId = "en-US"
        default: localeId = Locale.current.identifier.contains("en") ? "en-US" : "zh-CN"
        }
        nativeRecognizer = SFSpeechRecognizer(locale: Locale(identifier: localeId))
        print("[VoiceFlow] 原生 ASR 语言更新为: \(localeId)")
    }
    
    private var launchAgentPlistURL: URL {
        let libraryDir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        return libraryDir.appendingPathComponent("LaunchAgents/com.hujia.VoiceFlow.plist")
    }
    
    private func updateLaunchAtLoginSetting() {
        let plistURL = launchAgentPlistURL
        
        if launchAtLogin {
            let bundlePath = Bundle.main.bundlePath
            let dict: [String: Any] = [
                "Label": "com.hujia.VoiceFlow",
                "ProgramArguments": [bundlePath + "/Contents/MacOS/VoiceFlow"],
                "RunAtLoad": true
            ]
            
            if let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) {
                let launchAgentsDir = plistURL.deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true, attributes: nil)
                
                do {
                    try data.write(to: plistURL)
                    print("[VoiceFlow] 成功开启开机自启动: \(plistURL.path)")
                } catch {
                    print("[VoiceFlow] 开启开机自启动失败: \(error.localizedDescription)")
                }
            }
        } else {
            if FileManager.default.fileExists(atPath: plistURL.path) {
                do {
                    try FileManager.default.removeItem(at: plistURL)
                    print("[VoiceFlow] 成功取消开机自启动")
                } catch {
                    print("[VoiceFlow] 取消开机自启动失败: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - 模型存储路径管理
    
    var modelsDirectory: URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelsURL = appSupport.appendingPathComponent("VoiceFlow/models", isDirectory: true)
        try? fileManager.createDirectory(at: modelsURL, withIntermediateDirectories: true, attributes: nil)
        return modelsURL
    }
    
    func isModelDownloaded(_ model: ModelType) -> Bool {
        if model == .native { return true }
        guard let folderName = model.folderName else { return false }
        let modelFolder = modelsDirectory.appendingPathComponent(folderName, isDirectory: true)
        
        let tokensPath = modelFolder.appendingPathComponent("tokens.txt").path
        let hasTokens = FileManager.default.fileExists(atPath: tokensPath)
        
        switch model {
        case .paraformerMini:
            let hasEncoder = FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent("encoder.int8.onnx").path)
            return hasTokens && hasEncoder
        case .zipformerBilingual:
            let hasEncoder = FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent("encoder-epoch-99-avg-1.int8.onnx").path)
            return hasTokens && hasEncoder
        case .senseVoice:
            let hasModel = FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent("model.int8.onnx").path)
            return hasTokens && hasModel
        default:
            return false
        }
    }
    
    // MARK: - 引擎初始化与启动
    
    func startRecognition() {
        print("\n🔵🔵🔵 [DIAG] startRecognition() 被调用 🔵🔵🔵")
        self.currentText = ""
        self.historyText = ""
        self.isRecognizing = true
        self.offlineAudioBuffer.removeAll()
        
        switch selectedModel {
        case .native:
            startNativeRecognition(isRestart: false)
        case .paraformerMini, .zipformerBilingual:
            if startOnlineSherpaRecognizer() {
                // 绑定音频流监听回调，灌入 PCM 数据
                AudioStreamManager.shared.onAudioBufferReceived = { [weak self] samples in
                    self?.feedOnlineSamples(samples)
                }
            } else {
                self.currentText = "❌ 加载本地流式模型失败"
                self.isRecognizing = false
            }
        case .senseVoice:
            // 1. 绑定音频流回调，在后台收集完整音频以供最后 SenseVoice 一次性识别
            AudioStreamManager.shared.onAudioBufferReceived = { [weak self] samples in
                self?.offlineAudioBuffer.append(contentsOf: samples)
            }
            // 2. 同时启动苹果原生 ASR 作为辅助，在屏幕上显示实时流式字词
            startNativeRecognition(isRestart: false)
        }
    }
    
    func stopRecognition(completion: @escaping (String) -> Void) {
        print("\n🔴🔴🔴 [DIAG] stopRecognition() 被调用 🔴🔴🔴")
        print("[DIAG] currentText=\"\(currentText)\", historyText=\"\(historyText)\"")
        let finalModel = selectedModel
        
        if finalModel == .native {
            self.isRecognizing = false
            stopNativeRecognition()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                print("[DIAG] stopRecognition completion: finalText=\"\(self?.currentText ?? "")\"")
                let rawText = self?.currentText ?? ""
                self?.recordDictation(rawText) // 记录原始识别日志
                let correctedText = self?.applyCorrections(to: rawText) ?? rawText
                completion(correctedText)
            }
        } else if finalModel == .senseVoice {
            self.isRecognizing = false
            AudioStreamManager.shared.onAudioBufferReceived = nil
            // 停止辅助的苹果原生 ASR 引擎
            stopNativeRecognition()
            
            // 执行高精度 SenseVoice 识别，并用最终结果覆盖 currentText
            let text = transcribeSenseVoiceOffline()
            recordDictation(text) // 记录原始识别日志
            let corrected = applyCorrections(to: text)
            self.currentText = corrected
            completion(corrected)
        } else {
            AudioStreamManager.shared.onAudioBufferReceived = nil
            stopOnlineSherpaRecognizer()
            self.isRecognizing = false
            let rawText = self.currentText
            recordDictation(rawText) // 记录原始识别日志
            let correctedText = applyCorrections(to: rawText)
            completion(correctedText)
        }
    }
    
    // MARK: - 1. 苹果原生 ASR 实现
    
    private func startNativeRecognition(isRestart: Bool = false) {
        let taskId = Int.random(in: 1000...9999)  // 为每次调用生成唯一标识
        print("\n🟢 [DIAG-\(taskId)] startNativeRecognition(isRestart: \(isRestart)) 进入")
        print("[DIAG-\(taskId)] 当前 currentText=\"\(self.currentText)\"")
        print("[DIAG-\(taskId)] 当前 historyText=\"\(self.historyText)\"")
        print("[DIAG-\(taskId)] 当前 isRecognizing=\(self.isRecognizing)")
        print("[DIAG-\(taskId)] 当前线程: \(Thread.isMainThread ? "主线程" : "后台线程")")
        
        if !isRestart {
            self.historyText = ""
        }
        self.lastSeenText = ""
        self.lastCallbackTime = nil
        self.isRestartingTask = false
        self.lastStartTime = Date() // 记录本次 Task 的启动时间戳
        
        // 关键修复：先在主线程切断引用（nativeTask = nil），再发送取消信号
        // 这样一来，cancel() 触发的 cancellation 回调执行时，
        // self.nativeTask 已经是 nil，self.nativeTask === currentTask 必然为 false，
        // 旧闭包会被瞬间拦截，彻底阻断级联取消风暴
        let oldTask = nativeTask
        let oldRequest = nativeRequest
        nativeTask = nil
        nativeRequest = nil
        oldRequest?.endAudio()
        oldTask?.cancel()
        
        nativeRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = nativeRequest, let recognizer = nativeRecognizer else {
            print("❌ [DIAG-\(taskId)] 初始化失败！nativeRequest=\(nativeRequest == nil ? "nil" : "ok"), nativeRecognizer=\(nativeRecognizer == nil ? "nil" : "ok")")
            if !isRestart {
                self.currentText = "❌ 原生 SpeechRecognizer 初始化失败"
                self.isRecognizing = false
            }
            return
        }
        
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        
        var latestText = self.currentText
        print("[DIAG-\(taskId)] latestText 初始化为: \"\(latestText)\"")
        
        AudioStreamManager.shared.onNativeBufferReceived = { [weak self] buffer in
            self?.nativeRequest?.append(buffer)
        }
        
        // 1. 同步声明外部的可选变量，规避编译期自我捕获初始化错误
        var currentTask: SFSpeechRecognitionTask? = nil
        
        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            
            let isTaskMatch = self.nativeTask != nil && self.nativeTask === currentTask
            
            print("\n📨 [DIAG-\(taskId)] 回调触发: isTaskMatch=\(isTaskMatch), hasResult=\(result != nil), hasError=\(error != nil), isFinal=\(result?.isFinal ?? false)")
            print("[DIAG-\(taskId)] 回调线程: \(Thread.isMainThread ? "主线程" : "后台线程")")
            print("[DIAG-\(taskId)] isRecognizing=\(self.isRecognizing), isRestartingTask=\(self.isRestartingTask)")
            print("[DIAG-\(taskId)] currentText=\"\(self.currentText)\"")
            print("[DIAG-\(taskId)] historyText=\"\(self.historyText)\"")
            print("[DIAG-\(taskId)] latestText(闭包内)=\"\(latestText)\"")
            
            if let error = error {
                print("[DIAG-\(taskId)] error详情: \(error)")
            }
            if let result = result {
                print("[DIAG-\(taskId)] bestTranscription=\"\(result.bestTranscription.formattedString)\", isFinal=\(result.isFinal)")
            }
            
            // 2. 核心比对：使用 === 比对引用，只接受当前活跃 Task，忽略已废弃/设为 nil 的 Task 的回调
            guard isTaskMatch else {
                print("⛔ [DIAG-\(taskId)] 回调被 guard 拦截（task 不匹配或已 nil）")
                return
            }
            
            var shouldRestart = false
            
            if let result = result {
                let newText = result.bestTranscription.formattedString
                let currentTime = Date()
                
                // 探测 ASR 是否在内部重置了文本（比如在静音停顿后）
                var isInternalReset = false
                if !self.lastSeenText.isEmpty {
                    let timeGap = self.lastCallbackTime.map { currentTime.timeIntervalSince($0) } ?? 0
                    let prefixLen = self.commonPrefixLength(self.lastSeenText, newText)
                    
                    if timeGap > 1.5 && (newText.count < self.lastSeenText.count || prefixLen < 2) {
                        isInternalReset = true
                    } else if self.lastSeenText.count >= 4 && newText.count < self.lastSeenText.count - 2 && prefixLen < 2 {
                        isInternalReset = true
                    }
                }
                
                if isInternalReset {
                    let sep = self.shouldAddSpaceBetween(self.historyText, self.lastSeenText) ? " " : ""
                    self.historyText = self.historyText + sep + self.lastSeenText
                    print("🔄 [DIAG-\(taskId)] 检测到 ASR 内部重置! 将已识别文本 \"\(self.lastSeenText)\" 存入 historyText, 新 historyText=\"\(self.historyText)\"")
                }
                
                self.lastSeenText = newText
                self.lastCallbackTime = currentTime
                
                let separator = self.shouldAddSpaceBetween(self.historyText, newText) ? " " : ""
                let computedText = self.historyText + separator + newText
                print("[DIAG-\(taskId)] 拼接计算: historyText(\"\(self.historyText)\") + separator(\"\(separator)\") + newText(\"\(newText)\") = \"\(computedText)\"")
                latestText = computedText
                
                DispatchQueue.main.async {
                    print("[DIAG-\(taskId)] 主线程设置 currentText = \"\(latestText)\"")
                    self.currentText = latestText
                }
                
                // 防线一：只有当有实际识别文本时，isFinal 结束才触发重启；若为空 final 则直接忽略
                if result.isFinal && !newText.isEmpty {
                    print("🔄 [DIAG-\(taskId)] isFinal=true 且文本非空，标记 shouldRestart")
                    shouldRestart = true
                }
            }
            
            if let error = error {
                print("🔄 [DIAG-\(taskId)] 有 error，标记 shouldRestart: \(error.localizedDescription)")
                shouldRestart = true
            }
            
            if shouldRestart {
                // 防线二：距离上次启动必须大于 1.2 秒，防止高频 cancel 产生的级联回荡清空文本
                let timeSinceStart = Date().timeIntervalSince(self.lastStartTime)
                print("[DIAG-\(taskId)] shouldRestart=true, timeSinceStart=\(timeSinceStart)s, isRecognizing=\(self.isRecognizing), isRestartingTask=\(self.isRestartingTask)")
                
                if self.isRecognizing && !self.isRestartingTask && timeSinceStart > 1.2 {
                    self.isRestartingTask = true
                    // 防线三（最终安全网）：只有当 latestText 比当前 historyText 更长时才更新
                    // 这确保任何时序竞争或空回调都无法用更短/更空的文本覆写已积累的历史文本
                    let textToSave = latestText.count > self.historyText.count ? latestText : self.historyText
                    print("✅ [DIAG-\(taskId)] 将执行重启! textToSave=\"\(textToSave)\", latestText.count=\(latestText.count), historyText.count=\(self.historyText.count)")
                    DispatchQueue.main.async {
                        print("[DIAG-\(taskId)] 主线程重启: 设置 historyText=\"\(textToSave)\", 然后调用 startNativeRecognition(isRestart: true)")
                        self.historyText = textToSave
                        self.startNativeRecognition(isRestart: true)
                    }
                } else if !self.isRecognizing {
                    print("🛑 [DIAG-\(taskId)] isRecognizing=false, 调用 stopNativeRecognition()")
                    self.stopNativeRecognition()
                } else {
                    print("⏳ [DIAG-\(taskId)] 重启被阻止: timeSinceStart=\(timeSinceStart)s (需>1.2s), isRestartingTask=\(self.isRestartingTask)")
                }
            }
        }
        
        // 3. 同步赋值
        currentTask = task
        self.nativeTask = task
    }
    
    private func shouldAddSpaceBetween(_ prev: String, _ next: String) -> Bool {
        guard !prev.isEmpty, !next.isEmpty else { return false }
        guard let lastChar = prev.last, let firstChar = next.first else { return false }
        
        let isLastEnglishOrNum = (lastChar.isLetter || lastChar.isNumber) && lastChar.asciiValue != nil
        let isFirstEnglishOrNum = (firstChar.isLetter || firstChar.isNumber) && firstChar.asciiValue != nil
        
        return isLastEnglishOrNum && isFirstEnglishOrNum
    }
    
    private func commonPrefixLength(_ s1: String, _ s2: String) -> Int {
        var length = 0
        let chars1 = Array(s1)
        let chars2 = Array(s2)
        for i in 0..<min(chars1.count, chars2.count) {
            if chars1[i] == chars2[i] {
                length += 1
            } else {
                break
            }
        }
        return length
    }
    
    private func stopNativeRecognition() {
        AudioStreamManager.shared.onNativeBufferReceived = nil
        nativeRequest?.endAudio()
        nativeTask?.finish()
        nativeRequest = nil
        nativeTask = nil
    }
    
    // MARK: - 2. Sherpa-Onnx 流式 ASR 实现
    
    private func startOnlineSherpaRecognizer() -> Bool {
        guard isModelDownloaded(selectedModel) else { return false }
        
        let folder = modelsDirectory.appendingPathComponent(selectedModel.folderName!)
        
        var config = SherpaOnnxOnlineRecognizerConfig()
        
        config.feat_config.sample_rate = 16000
        config.feat_config.feature_dim = 80
        
        config.model_config.num_threads = 2
        config.model_config.provider = cString("cpu")
        config.decoding_method = cString("greedy_search")
        
        let tokensPath = folder.appendingPathComponent("tokens.txt").path
        config.model_config.tokens = cString(tokensPath)
        
        if selectedModel == .paraformerMini {
            let encoder = folder.appendingPathComponent("encoder.int8.onnx").path
            let decoder = folder.appendingPathComponent("decoder.int8.onnx").path
            config.model_config.paraformer.encoder = cString(encoder)
            config.model_config.paraformer.decoder = cString(decoder)
        } else if selectedModel == .zipformerBilingual {
            let encoder = folder.appendingPathComponent("encoder-epoch-99-avg-1.int8.onnx").path
            let decoder = folder.appendingPathComponent("decoder-epoch-99-avg-1.int8.onnx").path
            let joiner = folder.appendingPathComponent("joiner-epoch-99-avg-1.int8.onnx").path
            config.model_config.transducer.encoder = cString(encoder)
            config.model_config.transducer.decoder = cString(decoder)
            config.model_config.transducer.joiner = cString(joiner)
        }
        
        onlineRecognizer = SherpaOnnxCreateOnlineRecognizer(&config)
        guard onlineRecognizer != nil else { return false }
        
        onlineStream = SherpaOnnxCreateOnlineStream(onlineRecognizer)
        return onlineStream != nil
    }
    
    private func feedOnlineSamples(_ samples: [Float]) {
        guard let stream = onlineStream, let recognizer = onlineRecognizer else { return }
        
        SherpaOnnxOnlineStreamAcceptWaveform(stream, 16000, samples, Int32(samples.count))
        
        while SherpaOnnxIsOnlineStreamReady(recognizer, stream) != 0 {
            SherpaOnnxDecodeOnlineStream(recognizer, stream)
        }
        
        var text = ""
        // 传递 recognizer 和 stream 两个指针
        if let resultPtr = SherpaOnnxGetOnlineStreamResult(recognizer, stream) {
            if let textCStr = resultPtr.pointee.text {
                text = String(cString: textCStr)
            }
            SherpaOnnxDestroyOnlineRecognizerResult(resultPtr)
        }
        
        if !text.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.currentText = text
            }
        }
    }
    
    private func stopOnlineSherpaRecognizer() {
        if let stream = onlineStream {
            SherpaOnnxOnlineStreamInputFinished(stream)
            if let recognizer = onlineRecognizer {
                while SherpaOnnxIsOnlineStreamReady(recognizer, stream) != 0 {
                    SherpaOnnxDecodeOnlineStream(recognizer, stream)
                }
            }
            SherpaOnnxDestroyOnlineStream(stream)
        }
        if let recognizer = onlineRecognizer {
            SherpaOnnxDestroyOnlineRecognizer(recognizer)
        }
        onlineStream = nil
        onlineRecognizer = nil
    }
    
    // MARK: - 3. SenseVoice 非流式极速推理
    
    private func transcribeSenseVoiceOffline() -> String {
        guard isModelDownloaded(.senseVoice), !offlineAudioBuffer.isEmpty else { return "" }
        
        let folder = modelsDirectory.appendingPathComponent(ModelType.senseVoice.folderName!)
        
        var config = SherpaOnnxOfflineRecognizerConfig()
        
        config.feat_config.sample_rate = 16000
        config.feat_config.feature_dim = 80
        config.model_config.num_threads = 4
        config.model_config.provider = cString("cpu")
        
        let modelPath = folder.appendingPathComponent("model.int8.onnx").path
        let tokensPath = folder.appendingPathComponent("tokens.txt").path
        
        config.model_config.sense_voice.model = cString(modelPath)
        config.model_config.tokens = cString(tokensPath)
        config.model_config.sense_voice.language = cString(selectedLanguage)
        config.model_config.sense_voice.use_itn = 1
        
        let recognizer = SherpaOnnxCreateOfflineRecognizer(&config)
        guard let rec = recognizer else { return "❌ 无法创建 SenseVoice 识别器" }
        
        defer {
            SherpaOnnxDestroyOfflineRecognizer(rec)
        }
        
        let stream = SherpaOnnxCreateOfflineStream(rec)
        guard let str = stream else { return "❌ 无法创建 SenseVoice 音频流" }
        
        SherpaOnnxAcceptWaveformOffline(str, 16000, offlineAudioBuffer, Int32(offlineAudioBuffer.count))
        
        SherpaOnnxDecodeOfflineStream(rec, str)
        
        var resultText = ""
        if let resultPtr = SherpaOnnxGetOfflineStreamResult(str) {
            if let textCStr = resultPtr.pointee.text {
                resultText = String(cString: textCStr)
                resultText = cleanSenseVoiceOutput(resultText)
            }
            SherpaOnnxDestroyOfflineRecognizerResult(resultPtr)
        }
        
        SherpaOnnxDestroyOfflineStream(str)
        return resultText
    }
    
    private func cleanSenseVoiceOutput(_ text: String) -> String {
        var cleaned = text
        cleaned = cleaned.replacingOccurrences(of: "\\[laughter\\]", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\[applause\\]", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\[snort\\]", with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "\\[cough\\]", with: "", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - 4. 模型在线按需下载与解压 (Native tar)
    
    func downloadModel(for model: ModelType, completion: @escaping (Bool) -> Void) {
        guard var url = model.downloadURL, let archiveName = model.archiveName else {
            completion(true)
            return
        }
        
        // 使用 ghfast.top 镜像加速 GitHub 下载，解决国内下载卡住的问题
        let urlString = url.absoluteString
        if urlString.contains("github.com") {
            if let mirrorURL = URL(string: "https://ghfast.top/" + urlString) {
                url = mirrorURL
                print("[VoiceFlow] 检测到 GitHub 链接，启用 ghfast.top 镜像加速下载: \(url.absoluteString)")
            }
        }
        
        let destinationArchive = modelsDirectory.appendingPathComponent(archiveName)
        
        if isModelDownloaded(model) {
            completion(true)
            return
        }
        
        DispatchQueue.main.async {
            self.isDownloading = true
            self.downloadProgress = 0.0
        }
        
        let sessionConfig = URLSessionConfiguration.default
        let session = URLSession(configuration: sessionConfig)
        
        let progressObserver = session.downloadTask(with: url) { [weak self] (localURL, response, error) in
            guard let self = self else { return }
            if let localURL = localURL, error == nil {
                do {
                    try? FileManager.default.removeItem(at: destinationArchive)
                    try FileManager.default.moveItem(at: localURL, to: destinationArchive)
                    
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                    process.arguments = ["-xjf", destinationArchive.path, "-C", self.modelsDirectory.path]
                    try process.run()
                    process.waitUntilExit()
                    
                    try? FileManager.default.removeItem(at: destinationArchive)
                    
                    DispatchQueue.main.async {
                        self.isDownloading = false
                        self.downloadProgress = 1.0
                        completion(process.terminationStatus == 0)
                    }
                } catch {
                    DispatchQueue.main.async {
                        self.isDownloading = false
                        completion(false)
                    }
                }
            } else {
                DispatchQueue.main.async {
                    self.isDownloading = false
                    completion(false)
                }
            }
        }
        
        let _ = progressObserver.progress.observe(\.fractionCompleted) { [weak self] (progress, _) in
            DispatchQueue.main.async {
                self?.downloadProgress = progress.fractionCompleted
            }
        }
        
        progressObserver.resume()
    }
    
    func applyCorrections(to text: String) -> String {
        var processed = text
        
        // 1. 系统默认的高频纠偏映射
        let defaultCorrections: [(String, String)] = [
            ("openclaw", "open cloud"),
            ("open claw", "open cloud"),
            ("clod code", "Claude Code"),
            ("clode code", "Claude Code"),
            ("claud code", "Claude Code"),
            ("cloude code", "Claude Code"),
            ("claude code", "Claude Code"),
            ("her agent", "Hermes Agent"),
            ("hermesagent", "Hermes Agent"),
            ("hermes agent", "Hermes Agent"),
            ("hermes-agent", "Hermes Agent"),
            ("voiceflow", "VoiceFlow"),
            ("voice flow", "VoiceFlow"),
            ("github", "GitHub"),
            ("git commit", "git commit"),
            ("git push", "git push"),
            ("chatgpt", "ChatGPT"),
            ("gpt", "GPT")
        ]
        
        for (wrong, right) in defaultCorrections {
            processed = processed.replacingOccurrences(of: wrong, with: right, options: [.caseInsensitive])
        }
        
        // 2. 用户自定的纠偏映射，格式为 wrong:right 或者是 wrong->right
        let lines = customCorrectionsText.components(separatedBy: .newlines)
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 {
                let wrong = parts[0]
                let right = parts[1]
                if !wrong.isEmpty && !right.isEmpty {
                    processed = processed.replacingOccurrences(of: wrong, with: right, options: [.caseInsensitive])
                }
            } else {
                let arrowParts = line.components(separatedBy: "->").map { $0.trimmingCharacters(in: .whitespaces) }
                if arrowParts.count == 2 {
                    let wrong = arrowParts[0]
                    let right = arrowParts[1]
                    if !wrong.isEmpty && !right.isEmpty {
                        processed = processed.replacingOccurrences(of: wrong, with: right, options: [.caseInsensitive])
                    }
                }
            }
        }
        
        // 3. 智能过滤多余的口语语气词 (如：啊、嗯、呀、呃等)
        processed = removeFillerWords(from: processed)
        
        return processed
    }
    
    private func removeFillerWords(from text: String) -> String {
        var processed = text
        
        // 3.1 若整句仅仅是一个语气词本身，予以保留以防完全清空
        let trimmed = processed.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "嗯" || trimmed == "啊" || trimmed == "呀" || trimmed == "呃" || trimmed == "呢" || trimmed == "吧" || trimmed == "哦" {
            return processed
        }
        
        // 3.2 匹配并去除伴随标点的语气词
        let patterns = [
            ("[,，\\s]+(嗯|啊|呀|呃|哦|呢|吧|哈)+[,，\\s]+", "，"), // 句中夹带，收紧为单个逗号
            ("(嗯|啊|呀|呃|哦|呢|吧|哈)+[.。!！?？]+", "。"),     // 句末语气词直接剔除保留标点
            ("^\\s*(嗯|啊|呀|呃|哦|呢|吧|哈)+[,，\\s]*", ""),       // 句首语气词直接剥离
            ("(?<=.)(嗯|啊|呀|呃|哦|呢|吧|哈)(?=.)", "")            // 字与字之间的单音语气词直接干掉
        ]
        
        for (pattern, replacement) in patterns {
            processed = processed.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        
        // 3.3 针对特异性双重语气词直接全局替换
        let simpleWords = ["啊啊", "嗯嗯", "呀呀", "呃呃"]
        for word in simpleWords {
            processed = processed.replacingOccurrences(of: word, with: "")
        }
        
        return processed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // ASR 原始听写历史日志文件定位
    var dictationHistoryURL: URL {
        return modelsDirectory.deletingLastPathComponent().appendingPathComponent("dictation_history.txt")
    }
    
    // 写入听写历史 (记录纠偏前的原始识别结果)
    func recordDictation(_ text: String) {
        guard !text.isEmpty else { return }
        
        let logURL = dictationHistoryURL
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        let line = "[\(timestamp)] \(text)\n"
        
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let fileHandle = try? FileHandle(forWritingTo: logURL) {
                    fileHandle.seekToEndOfFile()
                    fileHandle.write(data)
                    fileHandle.closeFile()
                    print("[VoiceFlow] ASR 听写记录已追加到历史日志中")
                }
            } else {
                do {
                    try data.write(to: logURL)
                    print("[VoiceFlow] 首次创建并写入 ASR 听写历史日志")
                } catch {
                    print("[VoiceFlow] 写入听写历史失败: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // 清空听写历史日志
    func clearDictationHistory() {
        let logURL = dictationHistoryURL
        if FileManager.default.fileExists(atPath: logURL.path) {
            try? FileManager.default.removeItem(at: logURL)
            print("[VoiceFlow] ASR 听写历史日志已清空")
        }
    }
    
}
