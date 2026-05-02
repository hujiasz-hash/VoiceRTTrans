import os
from openai import OpenAI
from dotenv import load_dotenv

load_dotenv()

class LLMClient:
    def __init__(self):
        self.api_key = os.getenv("LLM_API_KEY")
        self.base_url = os.getenv("LLM_BASE_URL")
        self.model_name = os.getenv("LLM_MODEL_NAME")
        
        if not self.api_key or not self.base_url or not self.model_name:
            print("Warning: LLM configuration is missing in .env")
            
        self.client = OpenAI(
            api_key=self.api_key,
            base_url=self.base_url
        )

    def stream_polish(self, raw_text, system_prompt):
        """
        流式整理文本
        """
        try:
            response = self.client.chat.completions.create(
                model=self.model_name,
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": raw_text}
                ],
                stream=True
            )
            for chunk in response:
                if chunk.choices and chunk.choices[0].delta.content:
                    yield chunk.choices[0].delta.content
        except Exception as e:
            yield f"\n[LLM Error: {str(e)}]"

if __name__ == "__main__":
    # 简单测试代码
    client = LLMClient()
    test_text = "那个，我今天想去吃个火锅，然后，呃，顺便看个电影吧。"
    sys_prompt = "你是一个高效的文案整理助手。请将口语记录整理为简洁通顺的文案。直接输出结果。"
    print("Testing LLM Stream:")
    for token in client.stream_polish(test_text, sys_prompt):
        print(token, end="", flush=True)
    print("\nTest Finished.")
