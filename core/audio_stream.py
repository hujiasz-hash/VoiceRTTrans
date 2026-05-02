import pyaudio
import threading
import queue

class AudioRecorder:
    def __init__(self, rate=16000, chunk=1024):
        self.rate = rate
        self.chunk = chunk
        self.format = pyaudio.paInt16
        self.channels = 1
        
        self.p = pyaudio.PyAudio()
        self.stream = None
        self.recording = False
        self.audio_queue = queue.Queue()

    def _record_task(self):
        self.stream = self.p.open(
            format=self.format,
            channels=self.channels,
            rate=self.rate,
            input=True,
            frames_per_buffer=self.chunk
        )
        
        while self.recording:
            data = self.stream.read(self.chunk, exception_on_overflow=False)
            self.audio_queue.put(data)
            
        self.stream.stop_stream()
        self.stream.close()

    def start(self):
        if self.recording:
            return
        self.recording = True
        self.thread = threading.Thread(target=self._record_task)
        self.thread.start()
        print("Audio recording started...")

    def stop(self):
        self.recording = False
        if hasattr(self, 'thread'):
            self.thread.join()
        print("Audio recording stopped.")

    def get_chunks(self):
        while not self.audio_queue.empty() or self.recording:
            try:
                yield self.audio_queue.get(timeout=0.1)
            except queue.Empty:
                continue

if __name__ == "__main__":
    import time
    recorder = AudioRecorder()
    recorder.start()
    try:
        time.sleep(3)
    finally:
        recorder.stop()
        print(f"Captured {recorder.audio_queue.qsize()} chunks.")
