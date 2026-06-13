import os
import subprocess
import shutil
from pathlib import Path
import urllib.request

def run_cmd(cmd, cwd=None):
    result = subprocess.run(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=cwd)
    if result.returncode != 0:
        print(f"命令执行失败: {cmd}\n错误信息: {result.stderr}")
        return False
    return True

def setup_libs():
    workspace = Path("/Users/hujia/Desktop/cla/2026-06_voiceflow")
    libs_dir = workspace / "libs"
    libs_dir.mkdir(exist_ok=True)
    
    print("正在通过 npm 拉取 prebuilt 库...")
    # 使用 npm 安装包 (自动匹配架构并拉取对应的 darwin 二进制包)
    if not run_cmd("npm install sherpa-onnx-node --no-save", cwd=str(workspace)):
        print("❌ npm install 失败，请检查网络或是否安装了 Node.js")
        return
        
    node_modules = workspace / "node_modules"
    
    # 寻找包含 dylib 的 darwin 原生目录
    # 可能是 sherpa-onnx-darwin-arm64 或 sherpa-onnx-darwin-x64
    native_dirs = list(node_modules.glob("sherpa-onnx-darwin-*"))
    if not native_dirs:
        print("❌ 未能在 node_modules 中找到 native 适配包")
        return
        
    native_dir = native_dirs[0]
    print(f"找到 Native 二进制包路径: {native_dir.name}")
    
    # 拷贝所有 dylib 到 libs/
    for dylib in native_dir.glob("*.dylib"):
        shutil.copy(dylib, libs_dir)
        print(f"已成功提取动态库: {dylib.name}")
        
    # 下载 C-API 头文件
    header_url = "https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/master/sherpa-onnx/c-api/c-api.h"
    dest_header = libs_dir / "c-api.h"
    
    print(f"正在从 GitHub 获取最新的 c-api.h 头文件...")
    try:
        req = urllib.request.Request(
            header_url, 
            headers={'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)'}
        )
        with urllib.request.urlopen(req, timeout=10) as response:
            with open(dest_header, 'wb') as f:
                f.write(response.read())
        print("已成功写入头文件: c-api.h")
    except Exception as e:
        print(f"❌ 下载 c-api.h 失败: {e}")
        return
        
    # 清理临时创建的 node_modules 目录
    shutil.rmtree(node_modules)
    print("🧹 临时 node_modules 目录已清理")
    print("🎉 sherpa-onnx C-API 动态库及头文件部署完成！")

if __name__ == "__main__":
    setup_libs()
