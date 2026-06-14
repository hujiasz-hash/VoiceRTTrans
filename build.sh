#!/bin/bash

# 确保脚本发生任何错误时立即停止
set -e

WORKSPACE="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="VoiceFlow"
BUILD_DIR="$WORKSPACE/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"

echo "🚀 开始编译打包 $APP_NAME.app..."

# 1. 建立纯净的编译输出目录
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Frameworks"
mkdir -p "$APP_DIR/Contents/Resources"

# 1.5 拷贝本地 icon 资源文件
if [ -d "$WORKSPACE/icon" ]; then
    echo "🎨 发现本地 icon 目录，正在拷贝图标到 App Resources 目录..."
    cp "$WORKSPACE/icon/"*.png "$APP_DIR/Contents/Resources/" 2>/dev/null || true
fi

# 2. 编译 Swift 源码
echo "💻 正在编译 Swift 源代码..."
swiftc \
  -import-objc-header "$WORKSPACE/VoiceFlow-Bridging-Header.h" \
  -I "$WORKSPACE/libs" \
  -L "$WORKSPACE/libs" \
  -lsherpa-onnx-c-api \
  -Xlinker -rpath -Xlinker "@executable_path/../Frameworks" \
  "$WORKSPACE/VoiceFlow/main.swift" \
  "$WORKSPACE/VoiceFlow/AppDelegate.swift" \
  "$WORKSPACE/VoiceFlow/Services/GlobalInputMonitor.swift" \
  "$WORKSPACE/VoiceFlow/Services/TextInjector.swift" \
  "$WORKSPACE/VoiceFlow/Models/AudioStreamManager.swift" \
  "$WORKSPACE/VoiceFlow/Models/SpeechRecognizer.swift" \
  "$WORKSPACE/VoiceFlow/Views/FloatingPanel.swift" \
  "$WORKSPACE/VoiceFlow/Views/SpeechOverlayView.swift" \
  "$WORKSPACE/VoiceFlow/Views/SettingsView.swift" \
  -o "$APP_DIR/Contents/MacOS/$APP_NAME"
echo "✅ Swift 编译完成: $APP_NAME 二进制"

# 3. 拷贝 Dynamic Libraries 依赖库到 App 包内
echo "📦 正在拷贝并修正动态链接库..."
cp "$WORKSPACE/libs/"*.dylib "$APP_DIR/Contents/Frameworks/"

# 修正包内 dylib 相互依存关系和装载路径
# libsherpa-onnx-c-api 依赖 libonnxruntime.dylib，将其装载点修正为 @loader_path 相对路径
install_name_tool -change "libonnxruntime.dylib" "@loader_path/libonnxruntime.dylib" "$APP_DIR/Contents/Frameworks/libsherpa-onnx-c-api.dylib"
install_name_tool -change "libonnxruntime.1.24.4.dylib" "@loader_path/libonnxruntime.dylib" "$APP_DIR/Contents/Frameworks/libsherpa-onnx-c-api.dylib"

# 4. 写入 Info.plist 配置文件
echo "📝 写入 Info.plist 配置文件..."
cat <<EOF > "$APP_DIR/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.hujia.$APP_NAME</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>VoiceFlow 需要麦克风权限以捕获音频进行本地语音输入转写。</string>
    <key>LSUIElement</key>
    <string>1</string>
</dict>
</plist>
EOF

# 5. 对整个 App Bundle 进行本地 ad-hoc 重新签名，以修复因 install_name_tool 破坏的签名
echo "🔑 正在清理扩展属性并进行本地 ad-hoc 代码签名..."
xattr -cr "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR"
echo "✅ 代码签名完成！"

echo "🎉 $APP_NAME.app 打包成功！"
echo "👉 安装包位于: $APP_DIR"
