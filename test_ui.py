import sys
from PyQt6.QtWidgets import QApplication, QWidget, QTextEdit, QVBoxLayout
from PyQt6.QtCore import Qt

app = QApplication(sys.argv)
w = QWidget()
w.setWindowFlags(Qt.WindowType.FramelessWindowHint | Qt.WindowType.WindowStaysOnTopHint | Qt.WindowType.Tool | Qt.WindowType.WindowDoesNotAcceptFocus)
w.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground)
w.resize(320, 200)
l = QVBoxLayout()
t = QTextEdit()
t.setText("Testing UI Visibility")
l.addWidget(t)
w.setLayout(l)
w.show()
w.raise_()
import threading
import time
def close_after():
    time.sleep(2)
    app.quit()
threading.Thread(target=close_after).start()
sys.exit(app.exec())
