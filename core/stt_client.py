import os
import json
import requests
import io
import wave

class STTClient:
    """
    STT 客户端 - 支持本地 HTTP 模式与云端 WebSocket 模式
    """
    def __init__(self):
        # 本地服务默认地址
        self.local_url = "http://127.0.0.1:8001/v1/transcriptions"
        self.config_path = os.path.join(os.path.expanduser("~"), ".voicerttrans", "config.json")
        
        # 初始化云端服务参数（从环境变量或配置读取）
        self.stt_url = os.getenv("STT_URL", "wss://aigc.bosch.com.cn/llmservice/api/v1")
        self.api_key = os.getenv("STT_API_KEY", "")
        self.model_name = os.getenv("STT_API_SECRET", "qwen3-asr-flash")

    def _should_use_local(self) -> bool:
        """从配置文件动态获取是否应该使用本地模型，若无配置或未配置完成，则当本地 8001 端口可用时默认为 True"""
        try:
            if os.path.exists(self.config_path):
                with open(self.config_path, "r", encoding="utf-8") as f:
                    config = json.load(f)
                    stt_conf = config.get("stt", {})
                    # 如果用户显式配置了 prefer_local
                    if "prefer_local" in stt_conf and stt_conf["prefer_local"] is not None:
                        return bool(stt_conf["prefer_local"])
        except Exception:
            pass

        # 默认探测本地服务是否可用
        try:
            session = requests.Session()
            session.trust_env = False
            r = session.get("http://127.0.0.1:8001/health", timeout=0.5)
            return r.status_code == 200
        except Exception:
            return False

    def recognize_audio_stream(self, pcm_data):
        """语音转写核心方法"""
        if self._should_use_local():
            # 本地 ASR HTTP 路径
            yield from self._recognize_local_http(pcm_data)
        else:
            # 云端 ASR WebSocket 路径
            import asyncio
            try:
                # 获取并使用现有的事件循环，如果在新线程中则创建一个
                try:
                    loop = asyncio.get_event_loop()
                except RuntimeError:
                    loop = asyncio.new_event_loop()
                    asyncio.set_event_loop(loop)
                
                text = loop.run_until_complete(self._recognize_ws(pcm_data))
                yield text
            except Exception as e:
                print(f"WS Run Error: {e}")
                yield ""

    def _recognize_local_http(self, pcm_data):
        """通过本地 HTTP POST 请求转录"""
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
            session = requests.Session()
            session.trust_env = False
            response = session.post(self.local_url, files=files, data=data, timeout=10)
            if response.status_code == 200:
                result = response.json()
                yield result.get('text', '')
            else:
                print(f"Local STT Error {response.status_code}: {response.text}")
                yield ""
        except Exception as e:
            print(f"Local STT Connection Error: {e}")
            yield ""

    async def _recognize_ws(self, pcm_data):
        """通过云端 WebSocket 转录"""
        import websockets
        import uuid
        
        task_id = str(uuid.uuid4())
        headers = {
            "Authorization": f"Bearer {self.api_key}"
        }
        
        try:
            # 兼容 ws:// 或 wss:// 协议
            async with websockets.connect(self.stt_url, additional_headers=headers) as ws:
                # 1. 发送启动指令 (参考 Qwen ASR 协议格式)
                start_msg = {
                    "header": {"action": "run-task", "task_id": task_id},
                    "payload": {
                        "task_group": "audio",
                        "task": "asr",
                        "parameters": {
                            "model": self.model_name,
                            "format": "pcm",
                            "sample_rate": 16000
                        }
                    }
                }
                await ws.send(json.dumps(start_msg))
                
                # 接收确认消息
                try:
                    await asyncio.wait_for(ws.recv(), timeout=3.0)
                except asyncio.TimeoutError:
                    pass
                
                # 2. 发送二进制 PCM 音频数据
                # 分块发送以防止粘包或缓冲区溢出
                chunk_size = 16000  # 约 0.5s 的音频量
                for i in range(0, len(pcm_data), chunk_size):
                    chunk = pcm_data[i:i+chunk_size]
                    await ws.send(chunk)
                
                # 3. 发送完成标志
                finish_msg = {
                    "header": {"action": "finish-task", "task_id": task_id}
                }
                await ws.send(json.dumps(finish_msg))
                
                # 4. 接收转译结果，直到结束
                final_text = ""
                async for message in ws:
                    try:
                        resp = json.loads(message)
                        event = resp.get("header", {}).get("event", "")
                        if event == "result-generated":
                            text = resp.get("payload", {}).get("output", {}).get("text", "")
                            if text:
                                final_text = text
                        elif event == "task-finished":
                            break
                    except Exception:
                        pass
                return final_text
        except Exception as ws_err:
            print(f"Cloud STT WebSocket Connection Failed: {ws_err}")
            return ""

