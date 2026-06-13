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
            return URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-paraformer-zh-small-2024-03-09.tar.bz2")
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
        case .paraformerMini: return "sherpa-onnx-paraformer-zh-small-2024-03-09"
        case .zipformerBilingual: return "sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20"
        case .senseVoice: return "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17"
        }
    }
}

class SpeechRecognizer: ObservableObject {
    static let shared = SpeechRecognizer()
    
    @Published var currentText: String = ""
    @Published var isRecognizing: Bool = false
    @Published var selectedModel: ModelType = .native
    
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
        // 尝试初始化系统内置识别器，默认中文
        nativeRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
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
        self.currentText = ""
        self.isRecognizing = true
        self.offlineAudioBuffer.removeAll()
        
        switch selectedModel {
        case .native:
            startNativeRecognition()
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
            AudioStreamManager.shared.onAudioBufferReceived = { [weak self] samples in
                self?.offlineAudioBuffer.append(contentsOf: samples)
            }
        }
    }
    
    func stopRecognition(completion: @escaping (String) -> Void) {
        let finalModel = selectedModel
        
        if finalModel == .native {
            stopNativeRecognition()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.isRecognizing = false
                completion(self?.currentText ?? "")
            }
        } else if finalModel == .senseVoice {
            self.isRecognizing = false
            AudioStreamManager.shared.onAudioBufferReceived = nil
            
            let text = transcribeSenseVoiceOffline()
            self.currentText = text
            completion(text)
        } else {
            AudioStreamManager.shared.onAudioBufferReceived = nil
            stopOnlineSherpaRecognizer()
            self.isRecognizing = false
            completion(self.currentText)
        }
    }
    
    // MARK: - 1. 苹果原生 ASR 实现
    
    private func startNativeRecognition() {
        nativeTask?.cancel()
        nativeTask = nil
        
        nativeRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let request = nativeRequest, let recognizer = nativeRecognizer else {
            self.currentText = "❌ 原生 SpeechRecognizer 初始化失败"
            self.isRecognizing = false
            return
        }
        
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        
        AudioStreamManager.shared.onNativeBufferReceived = { [weak self] buffer in
            self?.nativeRequest?.append(buffer)
        }
        
        nativeTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                DispatchQueue.main.async {
                    self.currentText = result.bestTranscription.formattedString
                }
            }
            if error != nil {
                self.stopNativeRecognition()
            }
        }
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
        config.model_config.sense_voice.language = cString("")
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
        guard let url = model.downloadURL, let archiveName = model.archiveName else {
            completion(true)
            return
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
}
