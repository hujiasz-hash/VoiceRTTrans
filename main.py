import sys
import json
import pyperclip
import io
import wave
import os
import time
import threading
import subprocess
import re
import logging
from difflib import SequenceMatcher

# 尝试关闭终端对控制字符（如 ^V）的默认回显
try:
    import termios
    fd = sys.stdin.fileno()
    attr = termios.tcgetattr(fd)
    attr[3] = attr[3] & ~termios.ECHOCTL  # 关闭 ECHOCTL 标志
    termios.tcsetattr(fd, termios.TCSADRAIN, attr)
except Exception:
    pass

import platform

from PyQt6.QtWidgets import (
    QApplication, QWidget, QVBoxLayout, QTextEdit, QLabel,
    QSystemTrayIcon, QMenu, QDialog, QPushButton, QVBoxLayout as QVBoxLayout2,
    QMessageBox, QProgressDialog,
)
from PyQt6.QtGui import QIcon, QPixmap, QPainter, QColor, QFont
from PyQt6.QtCore import Qt, QThread, QTimer, pyqtSignal, QObject, pyqtSlot, QPoint

from core.hotkey import HotkeyListener
from core.audio_stream import AudioRecorder
from core.llm_client import LLMClient
from core.stt_client import STTClient
from core.scenario_manager import ScenarioManager


def _setup_logging():
    log_dir = os.path.join(os.path.expanduser("~"), ".voicerttrans")
    os.makedirs(log_dir, exist_ok=True)
    log_file = os.path.join(log_dir, "app.log")

    logger = logging.getLogger("voicerttrans")
    logger.setLevel(logging.DEBUG)

    file_handler = logging.FileHandler(log_file, encoding="utf-8")
    file_handler.setLevel(logging.DEBUG)
    file_fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")
    file_handler.setFormatter(file_fmt)
    logger.addHandler(file_handler)

    console_handler = logging.StreamHandler()
    console_handler.setLevel(logging.INFO)
    console_fmt = logging.Formatter("[%(levelname)s] %(message)s")
    console_handler.setFormatter(console_fmt)
    logger.addHandler(console_handler)

    return logger


log = _setup_logging()

DEFAULT_CONFIG = {
    "hotkey": "cmd_r+'",
    "ui": {
        "opacity": 0.85,
        "always_on_top": True,
    },
    "stt": {
        "prefer_local": None,
        "installed": False,
    },
}

if sys.platform == "darwin":
    try:
        from AppKit import NSRunningApplication, NSWorkspace
    except ImportError:
        NSRunningApplication = None
        NSWorkspace = None

    try:
        from ApplicationServices import AXIsProcessTrusted
    except ImportError:
        AXIsProcessTrusted = None

    try:
        from AVFoundation import (
            AVCaptureDevice,
            AVMediaTypeAudio,
            AVAuthorizationStatusAuthorized,
            AVAuthorizationStatusNotDetermined,
        )
    except ImportError:
        AVCaptureDevice = None
        AVMediaTypeAudio = None
        AVAuthorizationStatusAuthorized = None
        AVAuthorizationStatusNotDetermined = None

class EditPromptDialog(QDialog):
    """编辑场景指令的对话框。"""
    def __init__(self, scene, scenario_manager, parent=None):
        super().__init__(parent)
        self.scene = scene
        self.sm = scenario_manager
        self.setWindowTitle("编辑场景指令")
        self.setMinimumSize(500, 350)

        layout = QVBoxLayout2()

        self.name_label = QLabel(f"场景：{scene['name']} ({scene['id']})")
        layout.addWidget(self.name_label)

        self.text_edit = QTextEdit()
        self.text_edit.setPlainText(scene.get("prompt", ""))
        layout.addWidget(self.text_edit)

        btn_layout = QVBoxLayout2()
        self.reset_btn = QPushButton("恢复默认")
        self.reset_btn.clicked.connect(self._on_reset)
        btn_layout.addWidget(self.reset_btn)

        self.cancel_btn = QPushButton("取消")
        self.cancel_btn.clicked.connect(self.reject)
        btn_layout.addWidget(self.cancel_btn)

        self.save_btn = QPushButton("保存")
        self.save_btn.clicked.connect(self._on_save)
        btn_layout.addWidget(self.save_btn)

        layout.addLayout(btn_layout)
        self.setLayout(layout)

    def _on_reset(self):
        self.sm.reset_prompt(self.scene["id"])
        self.text_edit.setPlainText(self.sm.current.get("prompt", ""))

    def _on_save(self):
        self.sm.update_prompt(self.scene["id"], self.text_edit.toPlainText())
        self.accept()


class ASRInstallerThread(QThread):
    progress_signal = pyqtSignal(str, int)  # 信号 (消息描述, 进度百分比)
    finished_signal = pyqtSignal(bool, str) # 信号 (是否成功, 成功/错误信息)

    def run(self):
        import subprocess
        import os
        
        user_dir = os.path.join(os.path.expanduser("~"), ".voicerttrans")
        env_dir = os.path.join(user_dir, "asr-env")
        
        try:
            # 1. 创建 venv
            self.progress_signal.emit("正在创建 ASR 虚拟运行环境...", 10)
            if not os.path.exists(env_dir):
                # 使用系统自带的 python3 创建虚拟环境
                cmd = ["python3", "-m", "venv", env_dir]
                res = subprocess.run(cmd, capture_output=True, text=True)
                if res.returncode != 0:
                    raise Exception(f"创建虚拟环境失败: {res.stderr}")
            
            # 2. 安装 pip 依赖
            self.progress_signal.emit("正在安装 MLX 硬件加速库与语音依赖 (可能需要 1-2 分钟)...", 30)
            pip_path = os.path.join(env_dir, "bin", "pip")
            
            # 推荐使用清华源，国内飞速
            pip_cmd = [
                pip_path, "install", 
                "mlx-audio", "flask", "requests", "flask-cors", "soundfile", "sounddevice", "numpy",
                "-i", "https://pypi.tuna.tsinghua.edu.cn/simple"
            ]
            res = subprocess.run(pip_cmd, capture_output=True, text=True)
            if res.returncode != 0:
                # 备用源（原生源）
                pip_cmd_fallback = [
                    pip_path, "install", 
                    "mlx-audio", "flask", "requests", "flask-cors", "soundfile", "sounddevice", "numpy"
                ]
                res = subprocess.run(pip_cmd_fallback, capture_output=True, text=True)
                if res.returncode != 0:
                    raise Exception(f"依赖安装失败: {res.stderr}")

            # 3. 下载 SenseVoice-Small 4bit 模型权重
            self.progress_signal.emit("正在连接国内镜像并下载 SenseVoice-Small 模型 (大小约 220MB)...", 60)
            python_path = os.path.join(env_dir, "bin", "python")
            
            # 使用国内 HF 镜像源下载
            env = os.environ.copy()
            env["HF_ENDPOINT"] = "https://hf-mirror.com"
            
            # 运行 ASR 加载模型（利用 mlx-audio load 的内置 HuggingFace 自动拉取和缓存功能）
            download_code = (
                "from mlx_audio.stt import utils; "
                "print('Downloading SenseVoice-Small...'); "
                "utils.load('mlx-community/SenseVoiceSmall-4bit')"
            )
            download_cmd = [python_path, "-c", download_code]
            
            res = subprocess.run(download_cmd, capture_output=True, text=True, env=env)
            if res.returncode != 0:
                raise Exception(f"模型下载失败: {res.stderr}")
            
            self.progress_signal.emit("本地 ASR 环境配置成功！", 100)
            self.finished_signal.emit(True, "安装成功")
        except Exception as e:
            self.finished_signal.emit(False, str(e))


class WorkerSignals(QObject):
    """
    专门管理信号的类，确保信号在正确的线程上下文被处理。
    """
    raw_text_update = pyqtSignal(str)
    raw_text_ready = pyqtSignal(str)
    token_ready = pyqtSignal(str)
    status_update = pyqtSignal(str)
    error_occurred = pyqtSignal(str)
    polish_finished = pyqtSignal(str)
    reset_display = pyqtSignal()

class TranscriptionThread(QThread):
    def __init__(self, recorder, stt_client, signals):
        super().__init__()
        self.recorder = recorder
        self.stt_client = stt_client
        self.signals = signals
        self.is_running = True
        self.audio_buffer = []

    def run(self):
        self.recorder.start()
        self.audio_buffer = []

        # 启动一个后台子线程，专门用来在录音期间不断发送累积的音频
        def process_audio_continuously():
            last_length = 0
            while self.is_running:
                time.sleep(0.5)  # 每 0.5 秒检查一次
                current_buffer = list(self.audio_buffer)
                if len(current_buffer) > last_length and len(current_buffer) > 5:
                    # 将目前累积的所有录音发给模型
                    audio_data = b"".join(current_buffer)
                    try:
                        # 对于实时的短片段，直接获取最终结果即可（不需要流式解析，因为本身就是高频轮询）
                        full_text = ""
                        for chunk_text in self.stt_client.recognize_audio_stream(audio_data):
                            full_text += chunk_text
                            self.signals.raw_text_update.emit(full_text)
                    except Exception as e:
                        pass
                    last_length = len(current_buffer)

        worker_thread = threading.Thread(target=process_audio_continuously)
        worker_thread.start()

        # 主循环：持续从录音机获取音频块
        while self.is_running:
            try:
                for chunk in self.recorder.get_chunks():
                    self.audio_buffer.append(chunk)
                    if not self.is_running: break
            except:
                break

        worker_thread.join()

        # 录音结束后，发送最后一次完整的音频进行最终确认
        if self.audio_buffer:
            self.signals.status_update.emit("正在进行最终识别...")
            try:
                stt_start = time.time()
                audio_data = b"".join(self.audio_buffer)
                full_text = ""
                for chunk_text in self.stt_client.recognize_audio_stream(audio_data):
                    full_text += chunk_text
                    self.signals.raw_text_update.emit(full_text)
                log.info(f"STT 最终识别耗时: {time.time() - stt_start:.2f}s")
                self.signals.raw_text_ready.emit(full_text)
            except Exception as e:
                self.signals.error_occurred.emit(f"STT 错误: {str(e)}")

    def stop(self):
        self.is_running = False
        self.recorder.stop()

class PolishThread(QThread):
    def __init__(self, llm_client, raw_text, signals, system_prompt, no_fallback=False):
        super().__init__()
        self.llm_client = llm_client
        self.raw_text = raw_text
        self.signals = signals
        self.system_prompt = system_prompt
        self.no_fallback = no_fallback

    def _extract_final_text(self, raw_text):
        text = raw_text.replace("\r\n", "\n").replace("\r", "\n")
        text = re.sub(r"<think[\s\S]*?</think\s*>", "\n", text, flags=re.IGNORECASE)
        text = re.sub(r"</?think\s*>", "\n", text, flags=re.IGNORECASE)
        text = text.replace("<final>", "").replace("</final>", "")

        if "```" in raw_text:
            leading = re.sub(r"</?think\s*>", "", raw_text.split("```", 1)[0], flags=re.IGNORECASE).strip()
            if leading and "Thinking Process" not in leading:
                return leading

        noise_patterns = [
            r"Thinking Process",
            r"Analyze the Request",
            r"Analyze the Input",
            r"Identify Filler",
            r"Drafting the Output",
            r"Review against Constraints",
            r"Final Polish",
            r"Constraints?:",
            r"Input:",
            r"Task:",
            r"Role:",
            r"Meaning:",
            r"Filler words?",
            r"colloquial",
            r"verbal tics",
            r"keep the original meaning",
            r"output directly",
            r"wait, looking closer",
            r"actually,",
            r"let'?s check",
        ]
        noise_re = re.compile("|".join(noise_patterns), re.IGNORECASE)

        cleaned_lines = []
        for line in text.split("\n"):
            stripped = line.strip()
            if not stripped:
                continue
            if noise_re.search(stripped):
                continue
            if re.match(r'^[\"""].+["""]$', stripped) and not re.match(r"^\d+[\.、]\s*", stripped):
                continue
            if stripped.startswith(("*", "-", ">", "`")):
                continue
            latin_count = len(re.findall(r"[A-Za-z]", stripped))
            cjk_count = len(re.findall(r"[一-鿿]", stripped))
            # 纯英文行超过 12 字符才过滤；含中文行仅过滤拉丁字符远多于中文的极端情况
            if cjk_count == 0 and latin_count > 12:
                continue
            if cjk_count > 0 and latin_count > cjk_count * 10:
                continue
            cleaned_lines.append(stripped)

        if cleaned_lines and len(cleaned_lines) % 2 == 0:
            half = len(cleaned_lines) // 2
            if cleaned_lines[:half] == cleaned_lines[half:]:
                cleaned_lines = cleaned_lines[:half]

        numbered_lines = [line for line in cleaned_lines if re.match(r"^\d+[\.、]\s*", line)]
        if numbered_lines:
            return "\n".join(cleaned_lines).strip()

        return "\n".join(cleaned_lines).strip()

    def _looks_like_analysis(self, text):
        analysis_markers = [
            "用户要求",
            "输入文本",
            "分析：",
            "整理思路",
            "让我整理",
            "我需要",
            "这里“",
            "这里\"",
            "如果是指",
            "结合上下文",
            "看起来像是",
            "通常",
            "首先",
            "接下来",
            "我现在需要处理",
            "我现在需要",
            "Thinking Process",
        ]
        return any(marker in text for marker in analysis_markers)

    def _rule_based_cleanup(self, text):
        cleaned = text.replace("\r\n", "\n").replace("\r", "\n")
        cleaned = re.sub(r"[“”\"']", "", cleaned)
        cleaned = re.sub(r"(?:(?<=^)|(?<=[，,。！？；;、\\s]))[嗯呃额啊唉]+", "", cleaned)
        cleaned = re.sub(r"[嗯呃额啊唉]+(?=[，,。！？；;、\\s]|$)", "", cleaned)
        cleaned = re.sub(r"[，,]\\s*[，,]+", "，", cleaned)
        cleaned = re.sub(r"[。！？；;]+", "。", cleaned)
        cleaned = re.sub(r"[，,]\\s*", "，", cleaned)
        cleaned = re.sub(r"\s+", "", cleaned)
        cleaned = re.sub(r"([，,]){2,}", "，", cleaned)
        cleaned = re.sub(r"([，,])[。！？]", "。", cleaned)
        cleaned = re.sub(r"^[，。]+|[，。]+$", "", cleaned)
        cleaned = re.sub(r"(?<!^)(\d+[\.、]\s*)", r"\n\1", cleaned)

        explicit_numbering = False
        parts = []
        for line in cleaned.split("\n"):
            line = line.strip()
            if not line:
                continue
            numbered_match = re.match(r"^\d+[\.、]\s*(.*)$", line)
            if numbered_match:
                explicit_numbering = True
                content = numbered_match.group(1).strip("， ")
                if content:
                    parts.append(content)
                continue
            for sentence in re.split(r"[。！？；;]", line):
                sentence = sentence.strip("， ")
                if sentence:
                    parts.append(sentence)

        merged_parts = []
        for part in parts:
            if merged_parts and merged_parts[-1] == part:
                continue
            merged_parts.append(part)

        if self._should_number_parts(text, explicit_numbering, merged_parts):
            return "\n".join(f"{idx}. {self._ensure_sentence_end(part)}" for idx, part in enumerate(merged_parts, 1))
        if len(merged_parts) > 1:
            return "\n".join(self._ensure_sentence_end(part) for part in merged_parts)
        if merged_parts:
            return self._ensure_sentence_end(merged_parts[0])
        return text.strip()

    def _normalize_for_compare(self, text):
        normalized = re.sub(r"^\d+[\.、]\s*", "", text, flags=re.MULTILINE)
        normalized = re.sub(r"[\s，,。！？；;：:\n]+", "", normalized)
        return normalized

    def _should_prefer_rule_result(self, model_text, rule_text):
        if not model_text:
            return True
        if self._looks_like_analysis(model_text):
            return True

        normalized_model = self._normalize_for_compare(model_text)
        normalized_rule = self._normalize_for_compare(rule_text)
        if not normalized_rule:
            return False

        similarity = SequenceMatcher(None, normalized_model, normalized_rule).ratio()
        if len(normalized_model) > len(normalized_rule) * 1.6:
            return True
        return similarity < 0.72

    def _should_use_fast_cleanup(self, raw_text, rule_text):
        if not rule_text:
            return False
        has_structure = bool(re.search(r"[。！？；，,\n]|^\d+[\.、]", raw_text))
        short_enough = len(raw_text.strip()) <= 80
        return has_structure and short_enough

    def _ensure_sentence_end(self, text):
        return text if re.search(r"[。！？]$", text) else text + "。"

    def _should_number_parts(self, raw_text, explicit_numbering, parts):
        if explicit_numbering:
            return True
        if len(parts) < 2:
            return False
        list_cue_re = re.compile(r"(首先|其次|再次|最后|另外|其一|其二|其三|第一|第二|第三)")
        cue_count = len(list_cue_re.findall(raw_text))
        return cue_count >= 2

    def run(self):
        raw_response = ""
        use_fallback = not self.no_fallback
        rule_text = self._rule_based_cleanup(self.raw_text)
        if use_fallback and self._should_use_fast_cleanup(self.raw_text, rule_text):
            log.debug("使用快速规整路径，跳过 LLM")
            self.signals.polish_finished.emit(rule_text)
            return

        system_prompt = self.system_prompt
        try:
            t0 = time.time()
            first_token_time = None
            for token_type, token in self.llm_client.stream_polish(self.raw_text, system_prompt):
                if token_type != "content" or not token:
                    continue
                if first_token_time is None:
                    first_token_time = time.time()
                    log.info(f"LLM 首字到达: {first_token_time - t0:.2f}s")
                raw_response += token

            log.info(f"LLM 总耗时: {time.time() - t0:.2f}s")
            if self.no_fallback:
                final_text = raw_response.strip()
            else:
                final_text = self._extract_final_text(raw_response)
                if self._should_prefer_rule_result(final_text, rule_text):
                    log.debug("模型输出偏离原文或仍是分析体，回退到贴近原文的规则清洗")
                    final_text = rule_text
            log.debug(f"最终整理结果长度: {len(final_text)}")
            self.signals.polish_finished.emit(final_text)
        except Exception as e:
            self.signals.error_occurred.emit(f"LLM 错误: {str(e)}")

class VCAIWindow(QWidget):
    # 用于跨线程控制 UI 显隐的信号
    ui_visibility_signal = pyqtSignal(bool)

    def __init__(self):
        super().__init__()
        self.load_config()

        self.llm_client = LLMClient()
        self.recorder = AudioRecorder()
        self.stt_client = STTClient()
        self.signals = WorkerSignals()
        self.scenario_manager = ScenarioManager()

        self.init_ui()

        # 严格的信号连接
        self.ui_visibility_signal.connect(self.set_ui_visible)
        self.signals.raw_text_update.connect(self.on_raw_text_update)
        self.signals.raw_text_ready.connect(self.on_raw_text_ready)
        self.signals.status_update.connect(self.on_status_update)
        self.signals.error_occurred.connect(self.on_error)
        self.signals.polish_finished.connect(self.on_polish_finished)
        self.signals.reset_display.connect(self.reset_display)

        self.hotkey = None
        self.trans_thread = None
        self.polish_thread = None
        self.target_app_name = None
        self.target_bundle_id = None
        self.target_pid = None
        self.tray_auto_recording = False

        ax_status = "loaded" if AXIsProcessTrusted else "None"
        log.info(f"sys.platform={sys.platform}, AXIsProcessTrusted={ax_status}")

        if sys.platform != "darwin" or self._has_accessibility_permission():
            log.info("Accessibility permission OK, starting hotkey listener")
            self._start_hotkey_listener()
        else:
            log.warning("No accessibility permission, will bootstrap permissions")
            self.signals.status_update.emit("首次启动请允许\"辅助功能\"权限，授权后热键即可生效")
            threading.Thread(target=self._bootstrap_macos_permissions, daemon=True).start()

        # 后台发送 warmup 请求，触发 MLX JIT 编译，消除首次推理的冷启动延迟
        threading.Thread(target=self._warmup_llm, daemon=True).start()

        self.asr_process = None
        # 连接 App 退出信号，安全清理子进程
        QApplication.instance().aboutToQuit.connect(self.stop_local_asr_service)

        # 如果配置使用本地 ASR，则自动拉起
        if self.config.get("stt", {}).get("prefer_local") is True:
            self.start_local_asr_service()

        # 延时 1 秒进行首次运行 ASR 的检测/引导（仅在窗口呈现完毕后温和地引导）
        QTimer.singleShot(1000, self.check_first_run_asr)

    def _warmup_llm(self):
        """用与实际推理相同的 system prompt 预热，确保 prompt cache 命中"""
        try:
            t0 = time.time()
            log.info("正在预热 LLM...")
            warmup_sys = self.scenario_manager.get_current_prompt()
            for _ in self.llm_client.stream_polish("你好", warmup_sys):
                pass
            log.info(f"LLM 预热完成: {time.time() - t0:.2f}s")
        except Exception as e:
            log.warning(f"LLM 预热失败 (不影响使用): {e}")

    def save_config(self):
        user_config_path = os.path.join(os.path.expanduser("~"), ".voicerttrans", "config.json")
        try:
            with open(user_config_path, "w", encoding="utf-8") as f:
                json.dump(self.config, f, ensure_ascii=False, indent=4)
            log.info(f"配置已更新并保存至: {user_config_path}")
        except Exception as e:
            log.error(f"保存配置失败: {e}")

    def check_first_run_asr(self):
        is_apple_silicon = sys.platform == "darwin" and platform.machine() == "arm64"
        if not is_apple_silicon:
            # 非 Apple Silicon 不支持 MLX，默认直接使用云端
            stt_conf = self.config.setdefault("stt", {})
            stt_conf["prefer_local"] = False
            self.save_config()
            return

        stt_conf = self.config.setdefault("stt", {})
        if stt_conf.get("prefer_local") is None:
            # 首次启动，且是 Apple Silicon Mac
            reply = QMessageBox.question(
                self,
                "启用本地离线语音识别?",
                "检测到您的电脑支持本地硬件加速语音识别。\n\n"
                "是否下载并启用本地高性价比 ASR 模型 (SenseVoice-Small)？\n"
                "（大小约 220MB，启用后您的语音输入将在本地纯离线高速进行，完全不消耗云端流量，内存仅占用约 600MB；若选择“否”则默认使用云端接口）。",
                QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No,
                QMessageBox.StandardButton.Yes
            )
            
            if reply == QMessageBox.StandardButton.Yes:
                self.start_asr_installation()
            else:
                stt_conf["prefer_local"] = False
                self.save_config()

    def start_asr_installation(self):
        # 创建进度对话框
        self.install_dialog = QProgressDialog("正在准备安装本地 ASR 环境...", "取消", 0, 100, self)
        self.install_dialog.setWindowTitle("下载并配置 ASR 离线模型")
        self.install_dialog.setWindowModality(Qt.WindowModality.WindowModal)
        self.install_dialog.setAutoClose(True)
        self.install_dialog.setAutoReset(False)
        self.install_dialog.setMinimumWidth(450)
        self.install_dialog.show()

        # 创建并启动下载安装线程
        self.installer_thread = ASRInstallerThread()
        self.installer_thread.progress_signal.connect(self.on_install_progress)
        self.installer_thread.finished_signal.connect(self.on_install_finished)
        self.installer_thread.start()

    def on_install_progress(self, message, progress):
        if hasattr(self, "install_dialog") and self.install_dialog:
            self.install_dialog.setLabelText(message)
            self.install_dialog.setValue(progress)

    def on_install_finished(self, success, message):
        if hasattr(self, "install_dialog") and self.install_dialog:
            self.install_dialog.close()
        
        stt_conf = self.config.setdefault("stt", {})
        if success:
            stt_conf["prefer_local"] = True
            stt_conf["installed"] = True
            self.save_config()
            QMessageBox.information(self, "安装成功", "本地 ASR 离线模型已成功安装并启用！正在为您启动本地识别服务...")
            self.start_local_asr_service()
        else:
            stt_conf["prefer_local"] = False
            stt_conf["installed"] = False
            self.save_config()
            QMessageBox.warning(self, "安装失败", f"本地 ASR 配置失败，已自动切换为云端模式。\n错误详情: {message}")

    def start_local_asr_service(self):
        # 1. 检查是否在运行
        try:
            import requests
            session = requests.Session()
            session.trust_env = False
            r = session.get("http://127.0.0.1:8001/health", timeout=0.5)
            if r.status_code == 200:
                log.info("本地 ASR 服务已在运行中，无需重复拉起")
                return
        except Exception:
            pass

        # 2. 检查环境和脚本是否存在
        user_dir = os.path.join(os.path.expanduser("~"), ".voicerttrans")
        python_path = os.path.join(user_dir, "asr-env", "bin", "python")
        
        # 查找 core/asr_server.py 的路径
        if getattr(sys, 'frozen', False):
            bundle_dir = sys._MEIPASS
        else:
            bundle_dir = os.path.dirname(os.path.abspath(__file__))
        
        server_script = os.path.join(bundle_dir, "core", "asr_server.py")
        
        if not os.path.exists(python_path) or not os.path.exists(server_script):
            log.warning("ASR 环境或服务脚本不存在，无法启动本地服务")
            return

        # 3. 启动子进程
        log.info(f"正在后台启动本地 ASR 服务: {python_path} {server_script}")
        try:
            # 指定环境变量，以防代理污染 localhost
            env = os.environ.copy()
            env["NO_PROXY"] = "127.0.0.1,localhost"
            
            self.asr_process = subprocess.Popen(
                [python_path, server_script, "--port", "8001"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=env
            )
            log.info("✓ 本地 ASR 服务进程已拉起")
        except Exception as e:
            log.error(f"启动本地 ASR 服务进程失败: {e}")

    def stop_local_asr_service(self):
        if hasattr(self, "asr_process") and self.asr_process:
            log.info("正在停止本地 ASR 服务...")
            try:
                self.asr_process.terminate()
                self.asr_process.wait(timeout=2)
            except Exception:
                try:
                    self.asr_process.kill()
                except Exception:
                    pass
            self.asr_process = None
            log.info("✓ 本地 ASR 服务进程已注销")

    def _resource_candidates(self, filename):
        base_dir = os.path.dirname(os.path.abspath(__file__))
        candidates = [
            os.path.join(os.path.expanduser("~"), ".voicerttrans", filename),
            os.path.join(os.getcwd(), filename),
            os.path.join(base_dir, filename),
        ]
        if getattr(sys, "_MEIPASS", None):
            candidates.append(os.path.join(sys._MEIPASS, filename))
        return candidates

    def _normalize_hotkey(self, hotkey_value):
        if not isinstance(hotkey_value, str):
            return DEFAULT_CONFIG["hotkey"]

        hotkey = hotkey_value.strip().lower().replace(" ", "")
        hotkey = hotkey.replace("’", "'").replace("‘", "'")
        hotkey = hotkey.replace("right_option", "alt_r")
        hotkey = hotkey.replace("right_command", "cmd_r")
        hotkey = hotkey.replace("command", "cmd").replace("option", "alt")
        hotkey = hotkey.replace("cmd_r+", "__CMD_R__+")
        hotkey = hotkey.replace("alt_r+", "__ALT_R__+")
        hotkey = hotkey.replace("cmd_", "cmd+").replace("ctrl_", "ctrl+")
        hotkey = hotkey.replace("alt_", "alt+").replace("shift_", "shift+")
        hotkey = hotkey.replace("__CMD_R__+", "cmd_r+")
        hotkey = hotkey.replace("__ALT_R__+", "alt_r+")

        if hotkey.endswith("+"):
            return DEFAULT_CONFIG["hotkey"]

        parts = [part for part in hotkey.split("+") if part]
        if len(parts) < 2:
            return DEFAULT_CONFIG["hotkey"]

        valid_modifiers = {"cmd", "cmd_r", "ctrl", "alt", "alt_r", "right_option", "right_command", "shift"}
        modifiers = parts[:-1]
        target_key = parts[-1]
        if any(modifier not in valid_modifiers for modifier in modifiers):
            return DEFAULT_CONFIG["hotkey"]
        if len(target_key) != 1 or not re.match(r"[a-z0-9/']", target_key):
            return DEFAULT_CONFIG["hotkey"]
        return "+".join(modifiers + [target_key])

    def _merge_config(self, base_config, incoming_config):
        if not isinstance(incoming_config, dict):
            return base_config

        merged = {
            "hotkey": self._normalize_hotkey(incoming_config.get("hotkey", base_config["hotkey"])),
            "ui": dict(base_config.get("ui", {})),
        }
        if isinstance(incoming_config.get("ui"), dict):
            merged["ui"].update(incoming_config["ui"])
        return merged

    def load_config(self):
        self.config = json.loads(json.dumps(DEFAULT_CONFIG))
        loaded_path = None

        for candidate in self._resource_candidates("config.json") + self._resource_candidates("config.example.json"):
            if not os.path.exists(candidate):
                continue
            try:
                with open(candidate, "r", encoding="utf-8") as f:
                    self.config = self._merge_config(self.config, json.load(f))
                loaded_path = candidate
                log.info(f"已加载配置: {candidate}")
                break
            except Exception as e:
                log.error(f"读取配置失败: {candidate}: {e}")

        config_dir = os.path.join(os.path.expanduser("~"), ".voicerttrans")
        os.makedirs(config_dir, exist_ok=True)
        user_config_path = os.path.join(config_dir, "config.json")
        legacy_seeded_config = {
            "hotkey": "cmd+r",
            "ui": {
                "opacity": 0.85,
                "always_on_top": True,
            },
        }

        if loaded_path == user_config_path and self.config == legacy_seeded_config:
            self.config = json.loads(json.dumps(DEFAULT_CONFIG))
            try:
                with open(user_config_path, "w", encoding="utf-8") as f:
                    json.dump(self.config, f, ensure_ascii=False, indent=4)
                log.info(f"已将旧默认热键迁移为新默认值: {user_config_path}")
            except Exception as e:
                log.error(f"迁移用户配置失败: {e}")

        if not os.path.exists(user_config_path):
            try:
                with open(user_config_path, "w", encoding="utf-8") as f:
                    json.dump(self.config, f, ensure_ascii=False, indent=4)
                log.info(f"已写入默认用户配置: {user_config_path}")
            except Exception as e:
                log.error(f"写入用户配置失败: {e}")

    def _has_accessibility_permission(self):
        if sys.platform != "darwin" or AXIsProcessTrusted is None:
            return True
        try:
            return bool(AXIsProcessTrusted())
        except Exception as e:
            log.error(f"检查辅助功能权限失败: {e}")
            return False

    def _request_accessibility_permission(self):
        if sys.platform != "darwin":
            return True
        return self._has_accessibility_permission()

    def _open_macos_privacy_pane(self, pane):
        if sys.platform != "darwin":
            return False
        urls = {
            "microphone": "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
            "accessibility": "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "automation": "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation",
        }
        url = urls.get(pane)
        if not url:
            return False
        try:
            subprocess.run(["open", url], check=False, capture_output=True, text=True)
            return True
        except Exception as e:
            log.error(f"打开权限设置失败({pane}): {e}")
            return False

    def _request_microphone_permission(self):
        if sys.platform != "darwin" or AVCaptureDevice is None or AVMediaTypeAudio is None:
            return True

        try:
            status = AVCaptureDevice.authorizationStatusForMediaType_(AVMediaTypeAudio)
            if status == AVAuthorizationStatusAuthorized:
                return True
            if status != AVAuthorizationStatusNotDetermined:
                return False

            granted_holder = {"value": False}
            done = threading.Event()

            def completion(granted):
                granted_holder["value"] = bool(granted)
                done.set()

            AVCaptureDevice.requestAccessForMediaType_completionHandler_(AVMediaTypeAudio, completion)
            done.wait(10)
            return granted_holder["value"]
        except Exception as e:
            log.error(f"请求麦克风权限失败: {e}")
            return False

    def _prime_automation_permission(self):
        if sys.platform != "darwin":
            return True
        ok, _ = self._run_osascript('tell application "System Events" to count processes')
        return ok

    def _bootstrap_macos_permissions(self):
        try:
            log.info("Bootstrap: starting permission checks")
            time.sleep(0.3)
            log.info("Bootstrap: sleep done, checking accessibility")
            access_ok = self._request_accessibility_permission()
            log.info(f"Bootstrap: accessibility={access_ok}")
            if not access_ok:
                self.signals.status_update.emit("请在系统设置中授予辅助功能权限后重新打开应用")
                return

            # 辅助功能权限已授予，启动热键监听
            self._start_hotkey_listener()

            # 2. 麦克风权限（录音需要，可后续授权）
            mic_ok = self._request_microphone_permission()
            log.info(f"Bootstrap: microphone={mic_ok}")
            if not mic_ok:
                self._open_macos_privacy_pane("microphone")
                self.signals.status_update.emit("热键已就绪，请允许麦克风权限以使用录音功能")
                return

            # 3. 自动化权限（粘贴需要）
            automation_ok = self._prime_automation_permission()
            log.info(f"Bootstrap: automation={automation_ok}")
            if not automation_ok:
                self._open_macos_privacy_pane("automation")
                self.signals.status_update.emit("请允许自动化权限以使用自动粘贴功能")
                return

            self.signals.status_update.emit("准备就绪")
        except Exception as e:
            log.error(f"Bootstrap crashed: {e}", exc_info=True)

    def _start_hotkey_listener(self):
        log.info("_start_hotkey_listener called")
        if self.hotkey is not None:
            return

        # Diagnostic: check accessibility and try CGEventTapCreate directly
        if sys.platform == "darwin":
            try:
                ax_ok = AXIsProcessTrusted() if AXIsProcessTrusted else None
                log.info(f"Diagnostic: AXIsProcessTrusted={ax_ok}")

                from Quartz import CGEventTapCreate, kCGEventKeyDown, kCGEventTapOptionListenOnly, kCGHIDEventTap
                test_tap = CGEventTapCreate(
                    kCGHIDEventTap, 0, kCGEventTapOptionListenOnly,
                    1 << kCGEventKeyDown, lambda *args: None, None
                )
                log.info(f"Diagnostic: CGEventTapCreate test tap={'OK' if test_tap else 'NULL'}")
                if test_tap:
                    from Quartz import CFMachPortInvalidate
                    CFMachPortInvalidate(test_tap)
            except Exception as diag_err:
                log.warning(f"Diagnostic: CGEventTapCreate direct test failed: {diag_err}")

        try:
            self.hotkey = HotkeyListener(
                self.config.get("hotkey", DEFAULT_CONFIG["hotkey"]),
                self.on_hotkey_press_worker,
                self.on_hotkey_release_worker,
            )
            self.hotkey.start()

            # Check if listener thread is actually alive after a brief wait
            time.sleep(1.0)
            if hasattr(self.hotkey, "is_alive") and not self.hotkey.is_alive():
                log.error("HotkeyListener thread is NOT alive after start")
                self.signals.status_update.emit("热键监听线程启动后意外退出，请检查权限和配置")
            else:
                log.info("HotkeyListener started successfully")
        except Exception as e:
            self.hotkey = None
            log.error(f"启动热键监听失败: {e}")
            self.signals.status_update.emit("热键监听启动失败，请检查权限和配置")

    def _create_tray_pixmap(self, text, bg_color):
        pixmap = QPixmap(22, 22)
        pixmap.fill(QColor(0, 0, 0, 0))
        painter = QPainter(pixmap)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing)
        painter.setBrush(QColor(bg_color))
        painter.setPen(Qt.PenStyle.NoPen)
        painter.drawRoundedRect(0, 0, 22, 22, 4, 4)
        painter.setPen(QColor(255, 255, 255))
        font = QFont("Helvetica", 9, QFont.Weight.Bold)
        painter.setFont(font)
        painter.drawText(pixmap.rect(), Qt.AlignmentFlag.AlignCenter, text)
        painter.end()
        return pixmap

    def _load_tray_icons(self):
        self._tray_icons = {}
        for name, path in [
            ("ready", "icon_tray.png"),
            ("recording", "icon_tray_recording.png"),
            ("polishing", "icon_tray_polishing.png"),
        ]:
            for candidate in self._resource_candidates(path):
                if os.path.exists(candidate):
                    self._tray_icons[name] = QIcon(candidate)
                    break
            else:
                self._tray_icons[name] = QIcon(self._create_tray_pixmap("V", "#2196F3" if name == "ready" else ("#F44336" if name == "recording" else "#FF9800")))

    def _init_tray_icon(self):
        self._load_tray_icons()
        self.tray_icon = QSystemTrayIcon(self._tray_icons["ready"], self)

        tray_menu = QMenu()

        self.tray_toggle_action = QMenu.addAction(tray_menu, "开始录音")
        self.tray_toggle_action.triggered.connect(self._on_tray_toggle)

        self.tray_status_action = tray_menu.addAction("Status: ready")
        self.tray_status_action.setEnabled(False)

        hk_str = self.config.get("hotkey", DEFAULT_CONFIG["hotkey"]).upper()
        tray_menu.addAction(f"Hotkey: {hk_str}").setEnabled(False)

        tray_menu.addSeparator()

        self._scene_submenu = QMenu("📌 场景")
        self._rebuild_scene_submenu()
        tray_menu.addMenu(self._scene_submenu)

        self.tray_menu_edit_action = tray_menu.addAction("✏️ 编辑当前场景指令...")
        self.tray_menu_edit_action.triggered.connect(self._on_edit_current_scene)

        tray_menu.addSeparator()
        tray_menu.addAction("Quit", QApplication.quit)

        self._tray_menu = tray_menu
        self.tray_icon.setContextMenu(tray_menu)
        self.tray_icon.setToolTip("VoiceRTTrans - ready")
        self.tray_icon.activated.connect(self._on_tray_icon_activated)
        self.tray_icon.show()

    def _on_tray_icon_activated(self, reason):
        if reason == QSystemTrayIcon.ActivationReason.Trigger:
            self._on_tray_toggle()

    def _on_tray_toggle(self):
        if self.tray_auto_recording:
            self._stop_tray_auto_recording()
        else:
            self._start_tray_auto_recording()

    def _start_tray_auto_recording(self):
        self.tray_auto_recording = True
        self._capture_target_app()
        self.ui_visibility_signal.emit(True)
        self.signals.reset_display.emit()
        self.signals.status_update.emit("正在录音 (点击图标停止)...")
        self._update_tray_tooltip("recording")
        if hasattr(self, "tray_toggle_action"):
            self.tray_toggle_action.setText("停止录音")

        if self.trans_thread and self.trans_thread.isRunning():
            return

        self.trans_thread = TranscriptionThread(self.recorder, self.stt_client, self.signals)
        self.trans_thread.start()

    def _stop_tray_auto_recording(self):
        self.tray_auto_recording = False
        if self.trans_thread:
            self.trans_thread.stop()
        if hasattr(self, "tray_toggle_action"):
            self.tray_toggle_action.setText("开始录音")

    def _update_tray_tooltip(self, status_text):
        if not hasattr(self, "tray_icon") or not hasattr(self, "_tray_icons"):
            return
        icon = self._tray_icons.get(status_text, self._tray_icons.get("ready"))
        self.tray_icon.setIcon(icon)
        self.tray_icon.setToolTip(f"VoiceRTTrans - {status_text}")
        if hasattr(self, "tray_status_action"):
            self.tray_status_action.setText(f"Status: {status_text}")

    def init_ui(self):
        self.setWindowFlags(Qt.WindowType.FramelessWindowHint | Qt.WindowType.WindowStaysOnTopHint | Qt.WindowType.Tool | Qt.WindowType.WindowDoesNotAcceptFocus)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setWindowOpacity(self.config.get("ui", {}).get("opacity", 0.85))

        layout = QVBoxLayout()

        self.status_label = QLabel("准备就绪 (按住可拖动窗口)")
        self.status_label.setStyleSheet("color: white; background-color: rgba(50, 50, 50, 180); border-radius: 5px; padding: 5px;")
        layout.addWidget(self.status_label)

        self.raw_text_edit = QTextEdit()
        self.raw_text_edit.setPlaceholderText("录音文本显示区...")
        self.raw_text_edit.setReadOnly(True)
        self.raw_text_edit.setStyleSheet("background-color: rgba(30, 30, 30, 200); color: #AAAAAA; border: none; border-radius: 10px; padding: 10px;")
        self.raw_text_edit.setFixedHeight(120)
        layout.addWidget(self.raw_text_edit)

        self.setLayout(layout)
        self.resize(320, 165)

        # 默认显示在右下角
        screen_geometry = self.screen().availableGeometry()
        x = screen_geometry.width() - self.width() - 20
        y = screen_geometry.height() - self.height() - 20
        self.move(x, y)

        self.hide()
        self._init_tray_icon()

    @pyqtSlot(bool)
    def set_ui_visible(self, visible):
        if visible:
            self.show()
            self.raise_()
        else:
            self.hide()

    def on_hotkey_press_worker(self):
        # 如果正在录音，热键作为停止开关（兼容托盘启动后无法点击图标的情况）
        if self.trans_thread and self.trans_thread.isRunning():
            self.tray_auto_recording = False
            self.signals.status_update.emit("准备就绪")
            self.on_hotkey_release_worker()
            return

        self._capture_target_app()
        self.ui_visibility_signal.emit(True)
        self.signals.reset_display.emit()
        hk_str = self.config.get("hotkey", DEFAULT_CONFIG["hotkey"]).upper()
        self.signals.status_update.emit(f"正在录音 (松开 {hk_str} 停止)...")
        self._update_tray_tooltip("recording")

        self.trans_thread = TranscriptionThread(self.recorder, self.stt_client, self.signals)
        self.trans_thread.start()

    def on_hotkey_release_worker(self):
        if self.trans_thread:
            self.trans_thread.stop()

    @pyqtSlot(str)
    def on_raw_text_update(self, text):
        self.raw_text_edit.setText(text)
        self.raw_text_edit.moveCursor(self.raw_text_edit.textCursor().MoveOperation.End)

    @pyqtSlot(str)
    def on_raw_text_ready(self, text):
        self.raw_text_edit.setText(text)
        self.raw_text_edit.moveCursor(self.raw_text_edit.textCursor().MoveOperation.End)
        self._update_tray_tooltip("polishing")
        if text and not text.startswith("["):
            self.signals.status_update.emit("识别完成，正在润色...")
            current_scene_id = self.scenario_manager.current["id"]
            no_fallback = current_scene_id != "default"
            self.polish_thread = PolishThread(self.llm_client, text, self.signals, self.scenario_manager.get_current_prompt(), no_fallback=no_fallback)
            self.polish_thread.start()

    @pyqtSlot()
    def reset_display(self):
        self.raw_text_edit.clear()

    @pyqtSlot(str)
    def on_polish_finished(self, final_text):
        self.signals.status_update.emit("已完成，正在输入...")
        log.info(f"准备输入文本，目标应用: {self.target_app_name or 'unknown'} ({self.target_bundle_id or 'no-bundle'})")

        def do_type():
            self.hide()
            self._restore_target_app()
            # 等焦点完全恢复后再开始键入，避免 Electron 等复杂应用输入管线未就绪
            QTimer.singleShot(180, lambda: self._input_text(final_text))

        QTimer.singleShot(120, do_type)

    def _input_text(self, text):
        """保存旧剪贴板 → 复制新文本 → CGEvent Cmd+V → 恢复旧剪贴板。"""
        if not text or sys.platform != "darwin":
            return

        # 保存旧剪贴板 → 复制新文本 → CGEvent 发 Cmd+V → 延迟恢复旧剪贴板
        try:
            old_clip = pyperclip.paste()
        except Exception:
            old_clip = ""

        pyperclip.copy(text)
        self._send_cmd_v_cgevent()

        def restore_clip():
            try:
                pyperclip.copy(old_clip)
            except Exception:
                pass

        QTimer.singleShot(600, restore_clip)
        self._update_tray_tooltip("ready")

    def _send_cmd_v_cgevent(self):
        """通过 CGEvent 发送 Cmd+V，不依赖 osascript/System Events。"""
        try:
            from Quartz import (
                CGEventCreateKeyboardEvent,
                CGEventSetFlags,
                CGEventPost,
                kCGHIDEventTap,
                kCGEventFlagMaskCommand,
            )

            cmd_down = CGEventCreateKeyboardEvent(None, 55, True)
            CGEventPost(kCGHIDEventTap, cmd_down)

            v_down = CGEventCreateKeyboardEvent(None, 9, True)
            CGEventSetFlags(v_down, kCGEventFlagMaskCommand)
            CGEventPost(kCGHIDEventTap, v_down)

            v_up = CGEventCreateKeyboardEvent(None, 9, False)
            CGEventPost(kCGHIDEventTap, v_up)

            cmd_up = CGEventCreateKeyboardEvent(None, 55, False)
            CGEventPost(kCGHIDEventTap, cmd_up)
        except Exception:
            # CGEvent 不可用时回退到 osascript（剪贴板已有目标文本，由 _input_text 置入）
            QTimer.singleShot(80, self._send_paste_shortcut)

    def _run_osascript(self, script):
        try:
            # 确保在完整的 shell 环境中执行，包括 PATH
            env = os.environ.copy()
            if 'PATH' not in env:
                env['PATH'] = '/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'

            result = subprocess.run(
                ["osascript", "-e", script],
                check=False,
                capture_output=True,
                text=True,
                env=env,
            )
            stdout = result.stdout.strip()
            stderr = result.stderr.strip()
            if result.returncode != 0:
                log.error(f"osascript 失败 (code={result.returncode}): {stderr or stdout}")
            return result.returncode == 0, stdout
        except Exception as e:
            log.error(f"调用 osascript 失败: {e}")
            return False, ""

    def _capture_target_app(self):
        if sys.platform != "darwin":
            return
        if NSWorkspace is not None:
            try:
                front_app = NSWorkspace.sharedWorkspace().frontmostApplication()
                if front_app is not None:
                    self.target_app_name = front_app.localizedName() or None
                    self.target_bundle_id = front_app.bundleIdentifier() or None
                    self.target_pid = int(front_app.processIdentifier())
                    log.info(
                        f"记录目标应用: {self.target_app_name} "
                        f"({self.target_bundle_id or 'no-bundle'}, pid={self.target_pid})"
                    )
                    return
            except Exception as e:
                log.error(f"AppKit 获取目标应用失败: {e}")
        ok, output = self._run_osascript(
            'tell application "System Events"\n'
            'set frontApp to first application process whose frontmost is true\n'
            'set appName to name of frontApp\n'
            'try\n'
            'set bundleId to bundle identifier of frontApp\n'
            'on error\n'
            'set bundleId to ""\n'
            'end try\n'
            'return appName & "|" & bundleId\n'
            'end tell'
        )
        if ok and "|" in output:
            app_name, bundle_id = output.split("|", 1)
            self.target_app_name = app_name or None
            self.target_bundle_id = bundle_id or None
            self.target_pid = None
            log.info(f"记录目标应用: {self.target_app_name} ({self.target_bundle_id or 'no-bundle'})")

    def _restore_target_app(self):
        if sys.platform != "darwin":
            return False
        if self.target_pid and NSRunningApplication is not None:
            try:
                app = NSRunningApplication.runningApplicationWithProcessIdentifier_(self.target_pid)
                if app is not None and app.activateWithOptions_(1):
                    log.info(f"已恢复目标应用 PID: {self.target_pid}")
                    return True
            except Exception as e:
                log.error(f"AppKit 恢复目标应用失败: {e}")
        if self.target_bundle_id:
            ok, _ = self._run_osascript(f'tell application id "{self.target_bundle_id}" to activate')
            if ok:
                log.info(f"已恢复目标应用: {self.target_bundle_id}")
                return True
        if self.target_app_name:
            ok, _ = self._run_osascript(f'tell application "{self.target_app_name}" to activate')
            if ok:
                log.info(f"已恢复目标应用: {self.target_app_name}")
                return True
        log.warning("未能恢复目标应用，将直接尝试发送粘贴快捷键")
        return False

    def _send_paste_shortcut(self):
        if sys.platform != "darwin":
            log.info("当前仅实现 macOS 自动粘贴")
            return
        ok, _ = self._run_osascript(
            'tell application "System Events" to keystroke "v" using command down'
        )
        if ok:
            log.info("已发送 Cmd+V")

    def _rebuild_scene_submenu(self):
        """重建场景子菜单，更新选中状态。"""
        self._scene_submenu.clear()
        current_id = self.scenario_manager.current["id"]
        for scene in self.scenario_manager.list_all():
            action = self._scene_submenu.addAction(f"{scene['icon']} {scene['name']}")
            action.setCheckable(True)
            action.setChecked(scene["id"] == current_id)
            action.triggered.connect(
                lambda checked, sid=scene["id"]: self._on_scene_switch(sid)
            )

    def _on_scene_switch(self, scenario_id):
        """切换到指定场景。"""
        self.scenario_manager.switch_to(scenario_id)
        self._rebuild_scene_submenu()
        self._update_tray_tooltip("ready")

    def _on_edit_current_scene(self):
        """打开编辑当前场景指令的对话框。"""
        scene = self.scenario_manager.current
        dialog = EditPromptDialog(scene, self.scenario_manager, self)
        dialog.exec()

    def _format_status_text(self, base_text):
        """包装状态文本，非默认场景时加前缀。"""
        if self.scenario_manager.current["id"] == "default":
            return base_text
        return f"[{self.scenario_manager.current['name']}] {base_text}"

    @pyqtSlot(str)
    def on_status_update(self, base_text):
        self.status_label.setText(self._format_status_text(base_text))

    @pyqtSlot(str)
    def on_error(self, err_msg):
        self.status_label.setText(f"错误: {err_msg}")

    # 以下三个事件用于实现无边框窗口的鼠标拖动
    def mousePressEvent(self, event):
        if event.button() == Qt.MouseButton.LeftButton:
            self.drag_position = event.globalPosition().toPoint() - self.frameGeometry().topLeft()
            event.accept()

    def mouseMoveEvent(self, event):
        if event.buttons() == Qt.MouseButton.LeftButton and hasattr(self, 'drag_position'):
            self.move(event.globalPosition().toPoint() - self.drag_position)
            event.accept()

if __name__ == "__main__":
    app = QApplication(sys.argv)

    window = VCAIWindow()
    sys.exit(app.exec())
