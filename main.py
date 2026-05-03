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

from PyQt6.QtWidgets import QApplication, QWidget, QVBoxLayout, QTextEdit, QLabel
from PyQt6.QtCore import Qt, QThread, pyqtSignal, QObject, pyqtSlot

from core.hotkey import HotkeyListener
from core.audio_stream import AudioRecorder
from core.llm_client import LLMClient
from core.stt_client import STTClient

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
                print(f"[TIMING] STT 最终识别耗时: {time.time() - stt_start:.2f}s")
                self.signals.raw_text_ready.emit(full_text)
            except Exception as e:
                self.signals.error_occurred.emit(f"STT 错误: {str(e)}")

    def stop(self):
        self.is_running = False
        self.recorder.stop()

class PolishThread(QThread):
    def __init__(self, llm_client, raw_text, signals):
        super().__init__()
        self.llm_client = llm_client
        self.raw_text = raw_text
        self.signals = signals

    def _extract_final_text(self, raw_text):
        text = raw_text.replace("\r\n", "\n").replace("\r", "\n")
        text = re.sub(r"<think[\s\S]*?</think\s*>", "\n", text, flags=re.IGNORECASE)
        text = re.sub(r"</?think\s*>", "\n", text, flags=re.IGNORECASE)
        text = text.replace("<final>", "").replace("</final>", "")

        if "</think>" in raw_text:
            leading = re.sub(r"</?think\s*>", "", raw_text.split("</think>", 1)[0], flags=re.IGNORECASE).strip()
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
            if re.match(r'^[\"“].+[\"”]$', stripped) and not re.match(r"^\d+[\.、]\s*", stripped):
                continue
            if stripped.startswith(("*", "-", ">", "`")):
                continue
            latin_count = len(re.findall(r"[A-Za-z]", stripped))
            cjk_count = len(re.findall(r"[\u4e00-\u9fff]", stripped))
            if latin_count > max(6, cjk_count * 2):
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
        rule_text = self._rule_based_cleanup(self.raw_text)
        if self._should_use_fast_cleanup(self.raw_text, rule_text):
            print("[DEBUG] 使用快速规整路径，跳过 LLM")
            self.signals.polish_finished.emit(rule_text)
            return

        # 精简 system prompt — 越短 prefill 越快，TTFT 越低
        system_prompt = (
            "整理以下口语记录：保留原意，删除语气词和口头禅，"
            "有多个要点时用序号列出。直接输出结果，不要任何解释，不要输出思考过程。"
        )
        try:
            t0 = time.time()
            first_token_time = None
            for token_type, token in self.llm_client.stream_polish(self.raw_text, system_prompt):
                if token_type != "content" or not token:
                    continue
                if first_token_time is None:
                    first_token_time = time.time()
                    print(f"[TIMING] LLM 首字到达: {first_token_time - t0:.2f}s")
                raw_response += token

            print(f"[TIMING] LLM 总耗时: {time.time() - t0:.2f}s")
            final_text = self._extract_final_text(raw_response)
            if self._should_prefer_rule_result(final_text, rule_text):
                print("[DEBUG] 模型输出偏离原文或仍是分析体，回退到贴近原文的规则清洗")
                final_text = rule_text
            print(f"[DEBUG] 最终整理结果长度: {len(final_text)}")
            self.signals.polish_finished.emit(final_text)
        except Exception as e:
            self.signals.error_occurred.emit(f"LLM 错误: {str(e)}")

class VCAIWindow(QWidget):
    # 用于跨线程控制 UI 显隐的信号
    ui_visibility_signal = pyqtSignal(bool)

    def __init__(self):
        super().__init__()
        self.load_config()
        self.init_ui()
        
        self.llm_client = LLMClient()
        self.recorder = AudioRecorder()
        self.stt_client = STTClient()
        self.signals = WorkerSignals()
        
        # 严格的信号连接
        self.ui_visibility_signal.connect(self.set_ui_visible)
        self.signals.raw_text_update.connect(self.on_raw_text_update)
        self.signals.raw_text_ready.connect(self.on_raw_text_ready)
        self.signals.status_update.connect(self.status_label.setText)
        self.signals.error_occurred.connect(self.on_error)
        self.signals.polish_finished.connect(self.on_polish_finished)
        self.signals.reset_display.connect(self.reset_display)
        
        self.hotkey = HotkeyListener(
            self.config.get("hotkey", "cmd_r+'"),
            self.on_hotkey_press_worker,
            self.on_hotkey_release_worker
        )
        self.hotkey.start()
        
        self.trans_thread = None
        self.polish_thread = None
        self.target_app_name = None
        self.target_bundle_id = None

        # 后台发送 warmup 请求，触发 MLX JIT 编译，消除首次推理的冷启动延迟
        threading.Thread(target=self._warmup_llm, daemon=True).start()

    def _warmup_llm(self):
        """用与实际推理相同的 system prompt 预热，确保 prompt cache 命中"""
        try:
            t0 = time.time()
            print("[WARMUP] 正在预热 LLM...")
            warmup_sys = (
                "整理以下口语记录：保留原意，删除语气词和口头禅，"
                "有多个要点时用序号列出。直接输出结果，不要任何解释。"
            )
            for _ in self.llm_client.stream_polish("你好", warmup_sys):
                pass
            print(f"[WARMUP] LLM 预热完成: {time.time() - t0:.2f}s")
        except Exception as e:
            print(f"[WARMUP] LLM 预热失败 (不影响使用): {e}")

    def load_config(self):
        try:
            with open("config.json", "r") as f:
                self.config = json.load(f)
        except:
            self.config = {"hotkey": "cmd_r+'", "ui": {"opacity": 0.85}}

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

    @pyqtSlot(bool)
    def set_ui_visible(self, visible):
        if visible:
            self.show()
            self.raise_()
        else:
            self.hide()

    def on_hotkey_press_worker(self):
        # 此函数在 Hotkey 线程运行，不能直接操作 UI，只能发信号
        self._capture_target_app()
        self.ui_visibility_signal.emit(True)
        self.signals.reset_display.emit()
        hk_str = self.config.get("hotkey", "cmd_r+'").upper()
        self.signals.status_update.emit(f"正在录音 (松开 {hk_str} 停止)...")
        # 清空文本需通过信号或在 UI 线程处理。这里简单点，直接在 press 时清空（因为 press 时 UI 线程会响应信号显示）
        # 但为了极度安全，我们把清空也发出去，或者在 safe_show 里做。
        
        if self.trans_thread and self.trans_thread.isRunning():
            return
            
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
        if text and not text.startswith("["):
            self.signals.status_update.emit("识别完成，正在润色...")
            self.polish_thread = PolishThread(self.llm_client, text, self.signals)
            self.polish_thread.start()

    @pyqtSlot()
    def reset_display(self):
        self.raw_text_edit.clear()

    @pyqtSlot(str)
    def on_polish_finished(self, final_text):
        self.signals.status_update.emit("已完成并复制到剪贴板，正在粘贴...")
        pyperclip.copy(final_text)
        print(f"[PASTE] 已复制到剪贴板，目标应用: {self.target_app_name or 'unknown'} ({self.target_bundle_id or 'no-bundle'})")

        def auto_paste():
            self.hide()
            restored = self._restore_target_app()
            from PyQt6.QtCore import QTimer
            delay_ms = 180 if restored else 80
            QTimer.singleShot(delay_ms, self._send_paste_shortcut)

        from PyQt6.QtCore import QTimer
        QTimer.singleShot(120, auto_paste)

    def _run_osascript(self, script):
        try:
            result = subprocess.run(
                ["osascript", "-e", script],
                check=False,
                capture_output=True,
                text=True,
            )
            stdout = result.stdout.strip()
            stderr = result.stderr.strip()
            if result.returncode != 0:
                print(f"[PASTE] osascript 失败: {stderr or stdout}")
            return result.returncode == 0, stdout
        except Exception as e:
            print(f"[PASTE] 调用 osascript 失败: {e}")
            return False, ""

    def _capture_target_app(self):
        if sys.platform != "darwin":
            return
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
            print(f"[PASTE] 记录目标应用: {self.target_app_name} ({self.target_bundle_id or 'no-bundle'})")

    def _restore_target_app(self):
        if sys.platform != "darwin":
            return False
        if self.target_bundle_id:
            ok, _ = self._run_osascript(f'tell application id "{self.target_bundle_id}" to activate')
            if ok:
                print(f"[PASTE] 已恢复目标应用: {self.target_bundle_id}")
                return True
        if self.target_app_name:
            ok, _ = self._run_osascript(f'tell application "{self.target_app_name}" to activate')
            if ok:
                print(f"[PASTE] 已恢复目标应用: {self.target_app_name}")
                return True
        print("[PASTE] 未能恢复目标应用，将直接尝试发送粘贴快捷键")
        return False

    def _send_paste_shortcut(self):
        if sys.platform != "darwin":
            print("[PASTE] 当前仅实现 macOS 自动粘贴")
            return
        ok, _ = self._run_osascript(
            'tell application "System Events" to keystroke "v" using command down'
        )
        if ok:
            print("[PASTE] 已发送 Cmd+V")

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
