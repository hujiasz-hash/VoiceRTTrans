import AVFoundation
import Combine

class AudioStreamManager: ObservableObject {
    static let shared = AudioStreamManager()
    
    private let audioEngine = AVAudioEngine()
    private var audioConverter: AVAudioConverter?
    
    // 实时振幅发布给 UI，范围约 0.0 ~ 1.0
    @Published var audioLevel: Float = 0.0
    @Published var isRecording = false
    
    // ASR 引擎所要求的标准音频格式 (16kHz, 单声道, Float32)
    let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000.0, channels: 1, interleaved: false)!
    
    // 实时音频切片回调 (将喂给 SpeechRecognizer 引擎)
    var onAudioBufferReceived: (([Float]) -> Void)?
    // 苹果原生 Speech 框架所需要的 PCM Buffer 回调
    var onNativeBufferReceived: ((AVAudioPCMBuffer) -> Void)?
    
    private init() {}
    
    /// 开始音频捕获
    func startRecording() throws {
        guard !isRecording else { return }
        
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // 1. 初始化重采样转换器 (从麦克风原生格式如 44.1k/48k 转换为 ASR 的 16k)
        if inputFormat.sampleRate != targetFormat.sampleRate || inputFormat.channelCount != targetFormat.channelCount {
            audioConverter = AVAudioConverter(from: inputFormat, to: targetFormat)
        } else {
            audioConverter = nil // 格式一致，无需转换
        }
        
        // 2. 安装 Tap
        // 缓冲块设为 1024 帧（在 16k 下约 64ms 周期，响应极其即时）
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] (buffer, time) in
            guard let self = self else { return }
            
            // 苹果原生 SpeechRecognizer 直接喂原始硬件 Buffer，以获得最佳识别效率
            self.onNativeBufferReceived?(buffer)
            
            // 计算实时音量 RMS 振幅 (基于首声道)
            if let channelData = buffer.floatChannelData?[0] {
                let frameLength = Int(buffer.frameLength)
                var sum: Float = 0.0
                for i in 0..<frameLength {
                    sum += channelData[i] * channelData[i]
                }
                let rms = sqrt(sum / Float(frameLength))
                
                // 平滑过滤一下振幅，使得 UI 变化更加流畅
                DispatchQueue.main.async {
                    self.audioLevel = self.audioLevel * 0.3 + rms * 0.7
                }
            }
            
            // 3. 执行重采样并派发给本地 ASR 模型
            self.processAndDispatchResampledAudio(buffer: buffer)
        }
        
        // 4. 启动音频引擎
        audioEngine.prepare()
        try audioEngine.start()
        
        DispatchQueue.main.async {
            self.isRecording = true
        }
        print("[VoiceFlow] 麦克风音频捕获已启动。")
    }
    
    /// 停止音频捕获
    func stopRecording() {
        guard isRecording else { return }
        
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioConverter = nil
        
        DispatchQueue.main.async {
            self.isRecording = false
            self.audioLevel = 0.0
        }
        print("[VoiceFlow] 麦克风音频捕获已停止。")
    }
    
    /// 将麦克风 Buffer 转换成 16kHz 单声道音频切片
    private func processAndDispatchResampledAudio(buffer: AVAudioPCMBuffer) {
        guard let onAudioBufferReceived = self.onAudioBufferReceived else { return }
        
        // 如果不需要转换，直接复制数据
        if audioConverter == nil {
            if let channelData = buffer.floatChannelData?[0] {
                let frameLength = Int(buffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
                onAudioBufferReceived(samples)
            }
            return
        }
        
        // 执行重采样转换
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let targetFrameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 10)
        
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: targetFrameCapacity) else { return }
        
        var error: NSError? = nil
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        
        let status = audioConverter?.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        
        if status == .error || error != nil {
            print("[VoiceFlow] 音频重采样错误: \(String(describing: error))")
            return
        }
        
        // 派发重采样后的 PCM 浮点数组
        if let convertedData = outputBuffer.floatChannelData?[0] {
            let frameLength = Int(outputBuffer.frameLength)
            if frameLength > 0 {
                let samples = Array(UnsafeBufferPointer(start: convertedData, count: frameLength))
                onAudioBufferReceived(samples)
            }
        }
    }
}
