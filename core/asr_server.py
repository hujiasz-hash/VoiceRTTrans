#!/usr/bin/env python3
"""
ASR Server - 基于 SenseVoice-Small 的语音识别 HTTP API 服务
"""

import argparse
import os
import logging
import tempfile
import threading
import queue
import json
from typing import List
import numpy as np
import soundfile as sf
import wave

import mlx.core as mx
import mlx_audio.stt.utils as stt_utils
from flask import Flask, request, jsonify, Response
from flask_cors import CORS

# 初始化 Flask 应用
app = Flask(__name__)
CORS(app)  # 允许跨域请求

# 全局变量
model = None
model_lock = threading.Lock()

# 配置日志
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

def load_asr_model(model_id: str = "mlx-community/SenseVoiceSmall-4bit"):
    """加载 ASR 模型"""
    global model
    with model_lock:
        logger.info(f"正在加载模型: {model_id}")
        model = stt_utils.load(model_id)
        logger.info("✓ 模型加载完成")
    return model

def transcribe_streaming(audio_data: bytes, language: str = "Chinese",
                        stream_callback=None) -> List[str]:
    """流式转录音频"""
    with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as tmp_file:
        tmp_path = tmp_file.name
        tmp_file.write(audio_data)

    try:
        # 加载并规整音频
        with wave.open(tmp_path, 'rb') as wav_file:
            frames = wav_file.getnframes()
            rate = wav_file.getframerate()
            channels = wav_file.getnchannels()
            audio_raw = wav_file.readframes(frames)
            audio_array = np.frombuffer(audio_raw, dtype=np.int16)

            if channels > 1:
                audio_array = audio_array.reshape(-1, channels)
                audio_array = audio_array.mean(axis=1)

            temp_wav = tempfile.NamedTemporaryFile(suffix='.wav', delete=False)
            temp_path = temp_wav.name
            sf.write(temp_path, audio_array.astype(np.float32) / 32768.0, rate)
            temp_wav.close()

            results = []
            for chunk in model.generate(temp_path, stream=True, language=language):
                if stream_callback:
                    stream_callback(chunk)
                results.append(chunk.text)

            return results

    finally:
        try:
            os.unlink(tmp_path)
            if 'temp_path' in locals():
                os.unlink(temp_path)
        except:
            pass

# API 路由
@app.route('/health', methods=['GET'])
def health_check():
    """健康检查"""
    return jsonify({
        "status": "ok",
        "model_loaded": model is not None,
        "model_name": getattr(model, 'model_name', 'SenseVoiceSmall-4bit') if model else None
    })

@app.route('/v1/transcriptions', methods=['POST'])
def create_transcription():
    """语音转录 API"""
    try:
        if 'file' not in request.files:
            return jsonify({"error": "No audio file provided"}), 400

        audio_file = request.files['file']
        if audio_file.filename == '':
            return jsonify({"error": "No selected file"}), 400

        language = request.form.get('language', 'Chinese')
        stream = request.form.get('stream', 'false').lower() == 'true'
        audio_data = audio_file.read()

        if stream:
            def generate():
                q = queue.Queue()
                results = []
                def callback(chunk):
                    results.append(chunk.text)
                    data = {
                        "text": chunk.text,
                        "is_final": chunk.is_final,
                        "start_time": chunk.start_time,
                        "end_time": chunk.end_time
                    }
                    q.put(f"data: {json.dumps(data, ensure_ascii=False)}\n\n")

                def run_transcription_thread():
                    try:
                        transcribe_streaming(audio_data, language, callback)
                        q.put(f"data: {json.dumps({'type': 'done', 'results': results}, ensure_ascii=False)}\n\n")
                    except Exception as e:
                        q.put(f"data: {json.dumps({'error': str(e)}, ensure_ascii=False)}\n\n")
                    finally:
                        q.put(None)

                threading.Thread(target=run_transcription_thread).start()

                while True:
                    item = q.get()
                    if item is None:
                        break
                    yield item

            return Response(generate(), mimetype='text/event-stream')
        else:
            results = transcribe_streaming(audio_data, language)
            response_data = {
                "text": "".join(results),
                "language": language,
                "duration": len(audio_data) / 16000,
                "model": "SenseVoiceSmall-4bit"
            }
            return jsonify(response_data)

    except Exception as e:
        logger.error(f"转录失败: {str(e)}")
        return jsonify({"error": str(e)}), 500

@app.route('/v1/models', methods=['GET'])
def list_models():
    """列出可用模型"""
    return jsonify({
        "data": [
            {
                "id": "mlx-community/SenseVoiceSmall-4bit",
                "name": "SenseVoiceSmall-4bit",
                "description": "本地 SenseVoice-Small 4-bit 量化语音识别模型",
                "language": "Chinese/English",
                "size": "244M parameters",
                "quantization": "4-bit",
                "streaming": True
            }
        ]
    })

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description='ASR Server')
    parser.add_argument('--host', default='127.0.0.1', help='监听地址')
    parser.add_argument('--port', type=int, default=8001, help='监听端口')
    parser.add_argument('--model', default="mlx-community/SenseVoiceSmall-4bit", help='模型 ID')
    parser.add_argument('--debug', action='store_true', help='调试模式')

    args = parser.parse_args()

    os.environ['FLASK_ENV'] = 'production'
    app.config['DEBUG'] = args.debug

    # 加载模型
    load_asr_model(args.model)

    logger.info(f"ASR 服务启动成功!")
    logger.info(f"地址: http://{args.host}:{args.port}")
    logger.info(f"模型: {args.model}")

    app.run(host=args.host, port=args.port, threaded=True)
