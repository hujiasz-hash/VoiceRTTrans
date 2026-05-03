class STTClient:
    """
    本地模型 STT 客户端
    """
    def __init__(self):
        self.base_url = "http://127.0.0.1:8001/v1/transcriptions"

    def recognize_audio_stream(self, pcm_data):
        import requests
        import io
        import wave
        import json
        
        wav_buf = io.BytesIO()
        with wave.open(wav_buf, 'wb') as wf:
            wf.setnchannels(1)
            wf.setsampwidth(2)
            wf.setframerate(16000)
            wf.writeframes(pcm_data)
        
        files = {"file": ("audio.wav", wav_buf.getvalue(), "audio/wav")}
        data = {
            "language": "Chinese",
            "stream": "false"
        }
        
        try:
            # trust_env=False：禁用系统代理环境变量，确保直连本地 STT 服务
            session = requests.Session()
            session.trust_env = False
            response = session.post(self.base_url, files=files, data=data, timeout=10)
            if response.status_code == 200:
                result = response.json()
                yield result.get('text', '')
            else:
                print(f"Error {response.status_code}: {response.text}")
                yield ""
        except Exception as e:
            print(f"STT Error: {e}")
            yield ""
