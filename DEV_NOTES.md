# VoiceRTTrans 开发踩坑记录（v0.1.0 → v0.1.1）

## 1. PyInstaller 打包后启动立即崩溃 — 缺少依赖

**现象**：打包的 .app 双击无反应，无 Dock 图标，无状态栏图标。

**原因**：`build.sh` 使用系统 Python（`python3`），但项目依赖安装在 `venv/` 虚拟环境中。PyInstaller 只打包它能 import 到的模块，系统 Python 里缺少 `pyperclip` 等库。

**修复**：`build.sh` 改为优先使用 `venv/bin/python3`。

```bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/venv/bin/python3" ]; then
    PYTHON="$SCRIPT_DIR/venv/bin/python3"
fi
```

## 2. 打包后热键不触发 — 辅助功能权限未授予 .app

**现象**：打包应用启动后状态栏图标正常，但按热键只有系统"哒哒"提示音，不触发录音。

**原因**：源码运行时辅助功能权限授予的是 Terminal.app。打包后 `AXIsProcessTrusted()` 对 VoiceRTTrans.app 返回 False，pynput 无法创建 `CGEventTap`，键盘事件不被拦截。

**关键发现**：pynput 的 `ListenerMixin._run()` 中，如果 `CGEventTapCreate` 返回 NULL，监听器线程直接退出，**没有任何异常抛出**。在 `console=False` 的打包应用中，这个失败完全静默。

**修复**：
- 在 `_start_hotkey_listener()` 中添加 1 秒延迟后检查 `listener.is_alive()`
- 引导用户在系统设置中为 VoiceRTTrans.app 授予辅助功能权限

## 3. 权限 Bootstrap 线程静默失败

**现象**：通过 Finder 启动打包应用时，bootstrap 权限引导线程不执行。

**原因**：
- `_bootstrap_macos_permissions()` 先调用 `_request_microphone_permission()`
- `AVCaptureDevice.requestAccessForMediaType_completionHandler_()` 在 LSUIElement 应用中会阻塞等待系统弹窗响应，最多 10 秒
- 麦克风权限返回 False 后，bootstrap 直接 `return`，根本没走到辅助功能权限检查

**修复**：重构 bootstrap 顺序——先检查辅助功能权限（热键必需），再检查麦克风和自动化。

## 4. AXIsProcessTrustedWithOptions 阻塞

**现象**：使用 `AXIsProcessTrustedWithOptions({"kAXTrustedCheckOptionPrompt": True})` 主动弹出系统权限对话框时，调用永远不返回。

**原因**：LSUIElement 应用（无 Dock 图标）无法正常显示系统辅助功能权限对话框，导致函数阻塞。

**修复**：改用 `AXIsProcessTrusted()` 仅检查不弹框，手动通过 `open x-apple.systempreferences:...` 打开隐私设置面板。

## 5. 热键按下的系统提示音

**现象**：功能正常但按下热键时听到系统"哒哒哒"声。

**原因**：pynput 默认使用 `kCGEventTapOptionListenOnly` 模式，只监听不拦截。键盘事件同时传递到前台应用，前台应用无法处理 `Cmd+'` 组合键就发出提示音。

**修复**：在 `keyboard.Listener` 中添加 `intercept` 回调。热键激活时返回 `None` 吞噬事件，阻止传递到前台应用。

```python
self.listener = keyboard.Listener(
    on_press=self._on_press,
    on_release=self._on_release,
    intercept=self._intercept,
)

def _intercept(self, event_type, event):
    if self.pressed:
        return None  # 吞噬事件
    return event     # 放行
```

## 6. cffi 架构不匹配

**现象**：`PyInstaller build` 报错 `_cffi_backend.cpython-310-darwin.so is incompatible with target arch arm64 (has arch: x86_64)`。

**原因**：系统 Python 安装的 cffi 是 x86_64 版本（Rosetta 环境安装的），但目标架构是 arm64。

**修复**：`pip install --force-reinstall cffi` 重新安装 arm64 版本。

## 7. PyInstaller hidden imports 缺失

**现象**：打包后 `pynput._util.darwin_vks` 未包含，导致虚拟键码匹配表为空。

**修复**：在 `VoiceRTTrans.spec` 中显式添加：

```python
hiddenimports=[
    'pynput._util.darwin',
    'pynput._util.darwin_vks',
]
```

## 8. 无 Entitlements 导致 CGEventTap 失败

**原因**：PyInstaller 打包的 .app 没有 entitlements 文件，macOS 对未声明权限的应用限制了部分框架访问。

**修复**：创建 `entitlements.plist`，在 spec 中引用：

```xml
<key>com.apple.security.cs.allow-unsigned-executable-memory</key>
<true/>
<key>com.apple.security.cs.disable-library-validation</key>
<true/>
```

## 9. Ad-hoc 签名与 TCC 权限

**现象**：每次重新打包后辅助功能权限失效。

**原因**：`codesign -s -` 是 ad-hoc 签名，每次构建签名都不同。macOS TCC 按签名记录权限，签名变化后权限失效。

**解决方案**：创建自签名代码签名证书（需通过「钥匙串访问」GUI 操作），或接受每次重新打包后需重新授权。

## 调试技巧

- **查看打包应用日志**：`cat ~/.voicerttrans/app.log`
- **命令行运行打包应用**：`dist/VoiceRTTrans.app/Contents/MacOS/VoiceRTTrans 2>&1`（可以看到 stderr 输出）
- **模拟 Finder 启动**：`open dist/VoiceRTTrans.app`（与双击效果相同）
- **检查辅助功能权限**：`python3 -c "from ApplicationServices import AXIsProcessTrusted; print(AXIsProcessTrusted())"`
