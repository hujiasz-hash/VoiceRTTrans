import SwiftUI
import Combine

// MARK: - 适配 SwiftUI 的 AppKit 毛玻璃材质组件
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// MARK: - 动态宽度溢出渐变淡出蒙版
struct FadeOutMask: ViewModifier {
    var isOverflowing: Bool
    
    func body(content: Content) -> some View {
        if isOverflowing {
            return AnyView(
                content.mask(
                    LinearGradient(
                        gradient: Gradient(stops: [
                            Gradient.Stop(color: Color.clear, location: 0.0),
                            Gradient.Stop(color: Color.black, location: 0.08),
                            Gradient.Stop(color: Color.black, location: 0.92),
                            Gradient.Stop(color: Color.clear, location: 1.0)
                        ]),
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
            )
        } else {
            return AnyView(content)
        }
    }
}

// MARK: - 动态运动的液态融合底色层 (纯 SwiftUI 运行时滤镜实现)
struct LiquidBackgroundView: View {
    @State private var animate = false
    
    var body: some View {
        ZStack {
            // 背景渐变圆球 1 (偏冷色调，使用 blue 替代较新系统的 indigo)
            Circle()
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.blue.opacity(0.85), Color.purple.opacity(0.85)]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 70, height: 70)
                .offset(x: animate ? -25 : 30, y: animate ? 10 : -15)
                .scaleEffect(animate ? 1.25 : 0.8)
            
            // 背景渐变圆球 2 (偏暖色调)
            Circle()
                .fill(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.pink.opacity(0.85), Color.orange.opacity(0.75)]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 80, height: 80)
                .offset(x: animate ? 30 : -25, y: animate ? -10 : 15)
                .scaleEffect(animate ? 0.8 : 1.2)
        }
        .blur(radius: 14)
        .contrast(25)
        .colorMultiply(Color.white.opacity(0.82))
        .onAppear {
            withAnimation(Animation.easeInOut(duration: 4.5).repeatForever(autoreverses: true)) {
                animate.toggle()
            }
        }
    }
}

// MARK: - 语音识别实时悬浮窗
struct SpeechOverlayView: View {
    @ObservedObject private var recognizer = SpeechRecognizer.shared
    @ObservedObject private var audioManager = AudioStreamManager.shared
    @ObservedObject private var monitor = GlobalInputMonitor.shared
    
    @State private var textWidth: CGFloat = 0
    @State private var isOverflowing = false
    
    private let minWidth: CGFloat = 160
    private let maxWidth: CGFloat = 500
    private let layoutPadding: CGFloat = 56
    
    private var panelWidth: CGFloat {
        let desired = textWidth + layoutPadding
        return min(max(desired, minWidth), maxWidth)
    }
    
    var body: some View {
        ZStack {
            // 1. 底层：Siri 风格液态流光融合
            LiquidBackgroundView()
            
            // 2. 中层：HUD 毛玻璃材质
            VisualEffectView(material: .hudWindow, blendingMode: .withinWindow, state: .active)
                .opacity(0.9)
            
            // 3. 内容层
            HStack(spacing: 8) {
                // 麦克风图标与音量缩放反馈
                ZStack {
                    Circle()
                        .fill(Color.red.opacity(0.15))
                        .frame(width: 24, height: 24)
                        .scaleEffect(1.0 + CGFloat(audioManager.audioLevel * 0.9))
                    
                    Image(systemName: "mic.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 11, weight: .bold))
                }
                .frame(width: 24, height: 24)
                
                // 转录结果文字与自适应滚动区域
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            if recognizer.currentText.isEmpty {
                                let placeholder = recognizer.selectedModel == .senseVoice 
                                    ? (monitor.currentMode == .pushToTalk ? "按住说话，松开即入..." : "单击开始，任意键停止...")
                                    : "正在听取并识别..."
                                Text(placeholder)
                                    .font(.system(size: 14, weight: .medium, design: .rounded))
                                    .foregroundColor(Color.white.opacity(0.6))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: true)
                                    .background(
                                        GeometryReader { geo in
                                            Color.clear.onAppear { measureWidth(geo.size.width) }
                                        }
                                    )
                            } else {
                                Text(recognizer.currentText)
                                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: true)
                                    .background(
                                        GeometryReader { geo in
                                            Color.clear
                                                .onAppear { measureWidth(geo.size.width) }
                                                .onChange(of: geo.size.width) { newWidth in
                                                    measureWidth(newWidth)
                                                }
                                        }
                                    )
                            }
                            
                            Color.clear
                                .frame(width: 1, height: 1)
                                .id("trailingAnchor")
                        }
                    }
                    .disabled(true)
                    .onChange(of: recognizer.currentText) { _ in
                        if isOverflowing {
                            withAnimation(.easeOut(duration: 0.15)) {
                                proxy.scrollTo("trailingAnchor", anchor: .trailing)
                            }
                        }
                    }
                }
                .modifier(FadeOutMask(isOverflowing: isOverflowing))
            }
            .padding(.horizontal, 12)
        }
        .frame(width: panelWidth, height: 42)
        .animation(.spring(response: 0.35, dampingFraction: 0.86, blendDuration: 0), value: panelWidth)
        .clipShape(RoundedRectangle(cornerRadius: 21, style: .continuous))
        .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 4)
        .overlay(
            RoundedRectangle(cornerRadius: 21, style: .continuous)
                .stroke(
                    LinearGradient(
                        gradient: Gradient(colors: [Color.white.opacity(0.3), Color.white.opacity(0.05), Color.clear, Color.white.opacity(0.1)]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }
    
    private func measureWidth(_ width: CGFloat) {
        DispatchQueue.main.async {
            self.textWidth = width
            self.isOverflowing = (width + self.layoutPadding) > self.maxWidth
        }
    }
}
