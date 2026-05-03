from pynput import keyboard

try:
    from pynput._util.darwin_vks import SYMBOLS as DARWIN_SYMBOLS
except ImportError:
    DARWIN_SYMBOLS = {}

class HotkeyListener:
    def __init__(self, key_str, on_press_callback, on_release_callback):
        self.key_str = key_str.lower()
        self.on_press_callback = on_press_callback
        self.on_release_callback = on_release_callback
        self.pressed = False

        self.target_modifiers = set()
        self.target_char = None
        self.target_vks = set()

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

        if self.target_char is not None:
            self.target_vks = {
                vk for vk, symbol in DARWIN_SYMBOLS.items()
                if symbol == self.target_char
            }

        self.current_modifiers = set()
        self.char_pressed = False
        self.listener = keyboard.Listener(
            on_press=self._on_press,
            on_release=self._on_release,
            intercept=self._intercept,
        )

        self.mac_option_map = {
            '/': ['/', '÷'],
            'v': ['v', '√'],
            ' ': [' ', '\xa0']
        }

    def _matches_target_key(self, key):
        if self.target_char is None:
            return False

        if hasattr(key, 'vk') and key.vk in self.target_vks:
            return True

        if hasattr(key, 'char') and key.char is not None:
            char = key.char.lower()
            allowed_chars = self.mac_option_map.get(self.target_char, [self.target_char])
            return char in allowed_chars

        return False

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
        elif self._matches_target_key(key):
            self.char_pressed = True
        
        self._check_state()

    def _on_release(self, key):
        if self._is_modifier(key):
            norm_mod = self._normalize_modifier(key)
            if norm_mod in self.current_modifiers:
                self.current_modifiers.remove(norm_mod)
        elif self._matches_target_key(key):
            self.char_pressed = False
                
        self._check_state()

    def _check_state(self):
        mods_match = self.target_modifiers.issubset(self.current_modifiers)
        char_match = self.char_pressed if self.target_char else True

        is_match = mods_match and char_match

        if is_match and not self.pressed:
            self.pressed = True
            self.on_press_callback()
        elif not is_match and self.pressed:
            self.pressed = False
            self.on_release_callback()

    def _intercept(self, event_type, event):
        # Suppress all keyboard events while the hotkey is fully active
        if self.pressed:
            return None
        return event

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
