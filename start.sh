#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

# 激活虚拟环境
if [ -f "$SCRIPT_DIR/venv/bin/activate" ]; then
    source "$SCRIPT_DIR/venv/bin/activate"
else
    echo "错误: 未找到 venv，请先运行: python3 -m venv venv && source venv/bin/activate && pip install -r requirements.txt"
    exit 1
fi

# 检查 STT 服务
if ! curl -s --max-time 2 http://127.0.0.1:8001/v1/transcriptions > /dev/null 2>&1; then
    echo "警告: STT 服务未在 :8001 运行，录音转写将不可用"
fi

# 检查 LLM 服务（从 .env 读取地址）
LLM_URL="${LLM_BASE_URL:-http://127.0.0.1:8081/v1}"
LLM_HOST=$(echo "$LLM_URL" | sed 's|/v1.*||')
if ! curl -s --max-time 2 "$LLM_HOST" > /dev/null 2>&1; then
    echo "警告: LLM 服务未在 $LLM_HOST 运行，润色功能将不可用"
fi

echo "启动 VoiceRTTrans..."
"$SCRIPT_DIR/venv/bin/python" main.py
