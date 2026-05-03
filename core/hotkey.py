from pynput import keyboard

class HotkeyListener:
    def __init__(self, key_str, on_press_callback, on_release_callback):
        self.key_str = key_str.lower()
        self.on_press_callback = on_press_callback
        self.on_release_callback = on_release_callback
        self.pressed = False
        
        self.target_modifiers = set()
        self.target_char = None
        
        for part in self.key_str.split('+'):
            part = part.strip()
            if part in ['ctrl', 'cmd', 'command', 'cmd_r', 'right_command', 'alt', 'option', 'alt_r', 'right_option', 'shift']:
                if part == 'ctrl': self.target_modifiers.add(keyboard.Key.ctrl)
                elif part in ['cmd', 'command']: self.target_modifiers.add(keyboard.Key.cmd)
                elif part in ['cmd_r', 'right_command']: self.target_modifiers.add(keyboard.Key.cmd_r)
                elif part in ['alt', 'option']: self.target_modifiers.add(keyboard.Key.alt)
                elif part in ['alt_r', 'right_option']: self.target_modifiers.add(keyboard.Key.alt_r)
                elif part == 'shift': self.target_modifiers.add(keyboard.Key.shift)
            else:
                self.target_char = part
            
        self.current_modifiers = set()
        self.char_pressed = False
        self.listener = keyboard.Listener(on_press=self._on_press, on_release=self._on_release)
        
        # Mac 上的 Option + 字符 映射表
        self.mac_option_map = {
            '/': ['/', '÷'],
            'v': ['v', '√'],
            ' ': [' ', '\xa0']
        }

    def _is_modifier(self, key):
        return key in [keyboard.Key.ctrl, keyboard.Key.ctrl_l, keyboard.Key.ctrl_r,
                       keyboard.Key.cmd, keyboard.Key.cmd_l, keyboard.Key.cmd_r,
                       keyboard.Key.alt, keyboard.Key.alt_l, keyboard.Key.alt_r,
                       keyboard.Key.shift, keyboard.Key.shift_l, keyboard.Key.shift_r]

    def _normalize_modifier(self, key):
        if key in [keyboard.Key.ctrl_l, keyboard.Key.ctrl_r]: return keyboard.Key.ctrl
        if key == keyboard.Key.cmd_l: return keyboard.Key.cmd
        if key == keyboard.Key.cmd_r: return keyboard.Key.cmd_r
        if key == keyboard.Key.alt_r: return keyboard.Key.alt_r
        if key == keyboard.Key.alt_l: return keyboard.Key.alt
        if key in [keyboard.Key.shift_l, keyboard.Key.shift_r]: return keyboard.Key.shift
        return key

    def _on_press(self, key):
        if self._is_modifier(key):
            norm_mod = self._normalize_modifier(key)
            self.current_modifiers.add(norm_mod)
        elif hasattr(key, 'char') and key.char is not None:
            char = key.char.lower()
            allowed_chars = self.mac_option_map.get(self.target_char, [self.target_char])
            if char in allowed_chars:
                self.char_pressed = True
        
        self._check_state()

    def _on_release(self, key):
        if self._is_modifier(key):
            norm_mod = self._normalize_modifier(key)
            if norm_mod in self.current_modifiers:
                self.current_modifiers.remove(norm_mod)
        elif hasattr(key, 'char') and key.char is not None:
            char = key.char.lower()
            allowed_chars = self.mac_option_map.get(self.target_char, [self.target_char])
            if char in allowed_chars:
                self.char_pressed = False
                
        self._check_state()

    def _check_state(self):
        # 检查修饰键是否全部满足 (当前按下的修饰键包含目标修饰键)
        mods_match = self.target_modifiers.issubset(self.current_modifiers)
        char_match = self.char_pressed if self.target_char else True
        
        is_match = mods_match and char_match
        
        if is_match and not self.pressed:
            self.pressed = True
            self.on_press_callback()
        elif not is_match and self.pressed:
            self.pressed = False
            self.on_release_callback()

    def start(self):
        self.listener.start()
        print(f"Hotkey listener started for: {self.key_str}")

    def stop(self):
        self.listener.stop()

if __name__ == "__main__":
    import time
    def start_cb(): print("Pressed!")
    def stop_cb(): print("Released!")
    
    hk = HotkeyListener("alt_r+/", start_cb, stop_cb)
    hk.start()
    try:
        while True: time.sleep(1)
    except KeyboardInterrupt:
        hk.stop()
