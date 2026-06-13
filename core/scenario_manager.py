"""
场景管理器 — 负责 scenarios.json 的加载、保存、查询。
"""

import copy
import os
import json
from typing import Optional

BUILTIN_SCENARIOS = [
    {
        "id": "default",
        "name": "默认整理",
        "icon": "📝",
        "description": "去语气词，结构化整理",
        "prompt": "整理以下口语记录：保留原意，删除语气词和口头禅，有多个要点时用序号列出。直接输出结果，不要任何解释，不要输出思考过程。"
    },
    {
        "id": "email",
        "name": "商务邮件",
        "icon": "✉️",
        "description": "口语→正式邮件语气",
        "prompt": "你是一位专业的商务写作助手。将以下口语内容改写为正式、专业的商务邮件正文。要求：使用敬语和得体措辞；按逻辑分段，每段一个要点；不要包含问候语和落款，只输出邮件正文。直接输出结果，不要任何解释。"
    },
    {
        "id": "commit",
        "name": "Commit Message",
        "icon": "💻",
        "description": "口述改动→git commit",
        "prompt": "你是一位资深软件工程师。将以下口语内容生成规范的 git commit message。格式：第一行为 50 字以内的祈使句标题；空一行后逐条列出改动点（每行不超过 72 字符）。只输出 commit message，不要任何解释。"
    },
    {
        "id": "custom",
        "name": "自定义角色",
        "icon": "🎭",
        "description": "自由定义改写风格",
        "prompt": "用鲁迅的文风改写以下内容。语气冷峻、简洁、富有嘲讽意味。善用'大抵''向来''然而''实在'等句式。短句，适当反语。保留原意的核心，改用第一人称叙述。直接输出结果，不要任何解释。"
    }
]

BUILTIN_MAP = {s["id"]: s for s in BUILTIN_SCENARIOS}


class ScenarioManager:
    def __init__(self, config_dir: str = "~/.voicerttrans"):
        self._config_dir = os.path.expanduser(config_dir)
        os.makedirs(self._config_dir, exist_ok=True)
        self._config_path = os.path.join(self._config_dir, "scenarios.json")
        self._scenarios = self._load()
        self._current_id = self._load_current_id()

    # ---- private ----

    def _load_current_id(self) -> str:
        if os.path.exists(self._config_path):
            try:
                with open(self._config_path, "r", encoding="utf-8") as f:
                    data = json.load(f)
                    cid = data.get("current", "default")
                    ids = {s["id"] for s in self._scenarios}
                    if cid in ids:
                        return cid
            except Exception:
                pass
        return "default"

    def _load(self) -> list[dict]:
        if not os.path.exists(self._config_path):
            self._save(BUILTIN_SCENARIOS, "default")
            return copy.deepcopy(BUILTIN_SCENARIOS)

        try:
            with open(self._config_path, "r", encoding="utf-8") as f:
                data = json.load(f)
        except Exception:
            data = {"scenarios": BUILTIN_SCENARIOS, "current": "default"}

        scenarios = data.get("scenarios", [])
        current = data.get("current", "default")

        # 合并缺失字段：用户文件缺少某场景的字段时用内置值填充
        filled = []
        for s in scenarios:
            builtin = BUILTIN_MAP.get(s.get("id"))
            if builtin and s.get("id") == builtin["id"]:
                merged = copy.deepcopy(builtin)
                merged.update({k: v for k, v in s.items() if v is not None})
                filled.append(merged)
            else:
                filled.append(copy.deepcopy(s))

        # 验证 current 是否合法
        ids = {s["id"] for s in filled}
        if current not in ids:
            current = "default"

        return filled

    def _save(self, scenarios: list[dict], current: str):
        data = {"scenarios": scenarios, "current": current}
        with open(self._config_path, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False, indent=4)

    # ---- public API ----

    @property
    def current(self) -> dict:
        """返回当前场景的完整 dict。"""
        for s in self._scenarios:
            if s["id"] == self._current_id:
                return s
        return self._scenarios[0]

    def get_current_prompt(self) -> str:
        """返回当前场景的 prompt 字符串。"""
        return self.current.get("prompt", "")

    def list_all(self) -> list[dict]:
        """返回所有场景列表。"""
        return list(self._scenarios)

    def switch_to(self, scenario_id: str) -> None:
        """切换到指定场景，写入 scenarios.json。"""
        ids = {s["id"] for s in self._scenarios}
        if scenario_id not in ids:
            raise ValueError(f"Unknown scenario id: {scenario_id}")
        self._current_id = scenario_id
        self._save(self._scenarios, scenario_id)

    def update_prompt(self, scenario_id: str, new_prompt: str) -> None:
        """更新指定场景的 prompt。"""
        for s in self._scenarios:
            if s["id"] == scenario_id:
                s["prompt"] = new_prompt
                self._save(self._scenarios, self._current_id)
                return

    def reset_prompt(self, scenario_id: str) -> None:
        """重置指定场景的 prompt 为内置默认值。"""
        builtin = BUILTIN_MAP.get(scenario_id)
        if not builtin:
            return
        for s in self._scenarios:
            if s["id"] == scenario_id:
                s["prompt"] = builtin["prompt"]
                self._save(self._scenarios, self._current_id)
                return
