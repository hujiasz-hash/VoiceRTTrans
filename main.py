import sys
import json
import pyperclip
import io
import wave
import os
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
    raw_text_ready = pyqtSignal(str)
    token_ready = pyqtSignal(str)
    status_update = pyqtSignal(str)
    error_occurred = pyqtSignal(str)
    polish_finished = pyqtSignal(str)

class TranscriptionThread(QThread):
    def __init__(self, recorder, stt_client, signals):
        super().__init__()
        self.recorder = recorder
        self.stt_client = stt_client
        self.signals = signals
        self.is_running = True

    def run(self):
        self.recorder.start()
        frames = []
        while self.is_running:
            try:
                for chunk in self.recorder.get_chunks():
                    frames.append(chunk)
                    if not self.is_running: break
            except:
                break
        
        if frames:
            self.signals.status_update.emit("正在识别语音...")
            try:
                audio_data = b"".join(frames)
                result = self.stt_client.recognize_audio(audio_data)
                self.signals.raw_text_ready.emit(result)
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

    def run(self):
        full_polished = ""
        system_prompt = "你是一个高效的文案整理助手。请将以下口语记录整理为书面、通顺的指令或文案。直接输出结果，不要对话。"
        try:
            for token in self.llm_client.stream_polish(self.raw_text, system_prompt):
                self.signals.token_ready.emit(token)
                full_polished += token
            self.signals.polish_finished.emit(full_polished)
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
        self.signals.raw_text_ready.connect(self.on_raw_text_ready)
        self.signals.token_ready.connect(self.append_polished_token)
        self.signals.status_update.connect(self.status_label.setText)
        self.signals.error_occurred.connect(self.on_error)
        self.signals.polish_finished.connect(self.on_polish_finished)
        
        self.hotkey = HotkeyListener(
            self.config.get("hotkey", "ctrl+v"),
            self.on_hotkey_press_worker,
            self.on_hotkey_release_worker
        )
        self.hotkey.start()
        
        self.trans_thread = None
        self.polish_thread = None

    def load_config(self):
        try:
            with open("config.json", "r") as f:
                self.config = json.load(f)
        except:
            self.config = {"hotkey": "ctrl+v", "ui": {"opacity": 0.85}}

    def init_ui(self):
        self.setWindowFlags(Qt.WindowType.FramelessWindowHint | Qt.WindowType.WindowStaysOnTopHint | Qt.WindowType.Tool)
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
        self.setWindowOpacity(self.config.get("ui", {}).get("opacity", 0.85))
        
        layout = QVBoxLayout()
        
        self.status_label = QLabel("准备就绪")
        self.status_label.setStyleSheet("color: white; background-color: rgba(50, 50, 50, 180); border-radius: 5px; padding: 5px;")
        layout.addWidget(self.status_label)
        
        self.raw_text_edit = QTextEdit()
        self.raw_text_edit.setPlaceholderText("录音文本显示区...")
        self.raw_text_edit.setReadOnly(True)
        self.raw_text_edit.setStyleSheet("background-color: rgba(30, 30, 30, 200); color: #AAAAAA; border: none; border-radius: 10px; padding: 10px;")
        self.raw_text_edit.setFixedHeight(70)
        layout.addWidget(self.raw_text_edit)
        
        self.polished_text_edit = QTextEdit()
        self.polished_text_edit.setPlaceholderText("AI 整理结果...")
        self.polished_text_edit.setReadOnly(True)
        self.polished_text_edit.setStyleSheet("background-color: rgba(40, 40, 40, 220); color: white; border: 1px solid #555; border-radius: 10px; padding: 10px;")
        self.polished_text_edit.setFixedHeight(120)
        layout.addWidget(self.polished_text_edit)
        
        self.setLayout(layout)
        self.resize(400, 280)
        self.hide()

    @pyqtSlot(bool)
    def set_ui_visible(self, visible):
        if visible:
            self.show()
            self.raise_()
            self.activateWindow()
        else:
            self.hide()

    def on_hotkey_press_worker(self):
        # 此函数在 Hotkey 线程运行，不能直接操作 UI，只能发信号
        self.ui_visibility_signal.emit(True)
        self.signals.status_update.emit("正在录音 (松开 Ctrl+V 停止)...")
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
    def on_raw_text_ready(self, text):
        self.raw_text_edit.setText(text)
        if text and not text.startswith("["):
            self.signals.status_update.emit("识别完成，正在润色...")
            self.polished_text_edit.clear()
            self.polish_thread = PolishThread(self.llm_client, text, self.signals)
            self.polish_thread.start()

    @pyqtSlot(str)
    def append_polished_token(self, token):
        cursor = self.polished_text_edit.textCursor()
        cursor.movePosition(cursor.MoveOperation.End)
        cursor.insertText(token)
        self.polished_text_edit.setTextCursor(cursor)

    @pyqtSlot(str)
    def on_polish_finished(self, final_text):
        self.signals.status_update.emit("已完成并复制到剪贴板")
        pyperclip.copy(final_text)

    @pyqtSlot(str)
    def on_error(self, err_msg):
        self.status_label.setText(f"错误: {err_msg}")

if __name__ == "__main__":
    app = QApplication(sys.argv)
    window = VCAIWindow()
    sys.exit(app.exec())
