import asyncio
import websockets
import json
import os
from dotenv import load_dotenv

load_dotenv()

async def test_bosch_stt():
    # 使用用户建议的 wss 地址
    ws_url = "wss://aigc.bosch.com.cn/llmservice/api/v1"
    api_key = os.getenv("STT_API_KEY")
    model = os.getenv("STT_API_SECRET") # 用户把模型名写在了这里
    
    print(f"Connecting to {ws_url}...")
    headers = {
        "Authorization": f"Bearer {api_key}"
    }
    
    try:
        async with websockets.connect(ws_url, additional_headers=headers) as ws:
            print("Connected successfully!")
            
            # 尝试发送一个通用的启动指令 (参考 Qwen ASR 格式)
            start_msg = {
                "header": {"action": "run-task", "task_id": "test-123"},
                "payload": {
                    "task_group": "audio",
                    "task": "asr",
                    "parameters": {
                        "model": model,
                        "format": "pcm",
                        "sample_rate": 16000
                    }
                }
            }
            await ws.send(json.dumps(start_msg))
            print("Sent start message. Waiting for response...")
            
            # 接收响应
            response = await asyncio.wait_for(ws.recv(), timeout=5.0)
            print(f"Received: {response}")
            
    except Exception as e:
        print(f"Connection Failed: {str(e)}")

if __name__ == "__main__":
    asyncio.run(test_bosch_stt())
