from pynput import keyboard

class HotkeyListener:
    def __init__(self, key_str, on_press_callback, on_release_callback):
        self.key_str = key_str.lower()
        self.on_press_callback = on_press_callback
        self.on_release_callback = on_release_callback
        self.pressed = False
        
        # 转换字符串为 pynput 格式，例如 "ctrl+v" -> {Key.ctrl, 'v'}
        self.target_keys = set()
        for part in self.key_str.split('+'):
            if part == 'ctrl':
                self.target_keys.add(keyboard.Key.ctrl)
            elif part == 'v':
                self.target_keys.add(keyboard.KeyCode.from_char('v'))
            # 可扩展其他按键
            
        self.current_keys = set()
        self.listener = keyboard.Listener(on_press=self._on_press, on_release=self._on_release)

    def _on_press(self, key):
        if key in self.target_keys:
            self.current_keys.add(key)
            if all(k in self.current_keys for k in self.target_keys):
                if not self.pressed:
                    self.pressed = True
                    self.on_press_callback()

    def _on_release(self, key):
        if key in self.target_keys:
            if all(k in self.current_keys for k in self.target_keys):
                if self.pressed:
                    self.pressed = False
                    self.on_release_callback()
            if key in self.current_keys:
                self.current_keys.remove(key)

    def start(self):
        self.listener.start()
        print(f"Hotkey listener started for: {self.key_str}")

    def stop(self):
        self.listener.stop()

if __name__ == "__main__":
    import time
    def start_cb(): print("Pressed!")
    def stop_cb(): print("Released!")
    
    hk = HotkeyListener("ctrl+v", start_cb, stop_cb)
    hk.start()
    try:
        while True: time.sleep(1)
    except KeyboardInterrupt:
        hk.stop()
