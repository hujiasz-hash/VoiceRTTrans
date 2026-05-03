import os
import json
import time
import requests
from dotenv import load_dotenv

load_dotenv()

class LLMClient:
    def __init__(self):
        # 优先使用 .env 中配置的云端模型；若未配置则回退到本地服务
        self.base_url = os.getenv("LLM_BASE_URL", "http://127.0.0.1:8081/v1") + "/chat/completions"
        self.api_key = os.getenv("LLM_API_KEY", "")
        self.model = os.getenv("LLM_MODEL_NAME", "qwen36")

    def stream_polish(self, raw_text, system_prompt):
        """
        流式整理文本，逐 token 实时输出。
        使用真正的 HTTP SSE 流式请求，避免等待完整响应。
        """
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"

        data = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": raw_text},
                {"role": "assistant", "content": "<final>\n"},
            ],
            "stream": True,
            "max_tokens": 512,   # 文案整理任务上限，避免生成过长拖慢速度
            "thinking_level": "no",
            "thinking": False,
            "enable_thinking": False,
            # 不开启 thinking/reasoning 模式：对文案整理任务无需推理链，开启会大幅增加延迟
        }

        try:
            print(f"\n[DEBUG] 开始流式请求 LLM ({self.base_url}, model={self.model})...")
            t_start = time.time()
            session = requests.Session()
            session.trust_env = False
            response = session.post(
                self.base_url, headers=headers, json=data,
                timeout=180, stream=True,
            )
            print(f"[DEBUG] HTTP 连接建立: {time.time() - t_start:.2f}s")

            if response.status_code != 200:
                yield ("content", f"\n[LLM Error HTTP {response.status_code}: {response.text}]")
                return

            first_token = True
            for line in response.iter_lines():
                if not line:
                    continue
                line = line.decode("utf-8")
                if line.startswith("data: "):
                    line = line[6:]
                if line == "[DONE]":
                    break
                try:
                    chunk = json.loads(line)
                    delta = chunk.get("choices", [{}])[0].get("delta", {})
                    if delta.get("reasoning_content"):
                        continue
                    token = delta.get("content", "")
                    if token:
                        if first_token:
                            print(f"[DEBUG] 首 token 到达: {time.time() - t_start:.2f}s")
                            first_token = False
                        yield ("content", token)
                except json.JSONDecodeError:
                    continue

            print(f"[DEBUG] LLM 流式处理完成: {time.time() - t_start:.2f}s")
        except Exception as e:
            print(f"[DEBUG] 请求 LLM 时发生严重错误: {e}")
            yield ("content", f"\n[LLM Error: {str(e)}]")

if __name__ == "__main__":
    client = LLMClient()
    for token_type, token in client.stream_polish("测试文本", "请整理"):
        print(token, end="", flush=True)
