#!/usr/bin/env python3
"""把 recovery-profiles.json 里的实际值同步到 begonia.yml 的下拉框 options。

GitHub 的 workflow_dispatch 不允许 options 写表达式，只能在 YAML 里写死，
所以这里用脚本代劳：JSON 是唯一事实来源，改完 JSON 跑一遍本脚本即可。

    python .github/scripts/sync-form.py           # 就地更新 begonia.yml
    python .github/scripts/sync-form.py --check   # 只校验，过期时退出码 1

被同步的列表用标记包裹（标记行本身不要动，脚本只改标记之间的内容）：
    # <sync-form:profile>
    - all
    # </sync-form:profile>
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PROFILES = ROOT / ".github" / "recovery-profiles.json"
WORKFLOW = ROOT / ".github" / "workflows" / "begonia.yml"

# 跟随预设的哨兵值，必须与 begonia.yml 里的 default 保持一致
FOLLOW = "跟随预设"
# JSON 里可能没写这些键，保留一组常用值，避免下拉选项被收窄
FALLBACK = {
    "build_target": ["recoveryimage", "bootimage", "vendor_bootimage"],
    "lunch_variant": ["eng", "userdebug", "user"],
}
GENERATED = ["profile", "device", "recovery_name", "manifest_branch", "build_target", "lunch_variant"]


def load_options():
    profiles = json.loads(PROFILES.read_text(encoding="utf-8"))
    options = {"profile": ["all"] + [p["profile"] for p in profiles]}
    for key in GENERATED[1:]:
        values = [str(p.get("config", {}).get(key, "")).strip() for p in profiles]
        values = [v for v in FALLBACK.get(key, []) + values if v]
        if values:
            # choice 的 default 必须是 options 之一，所以哨兵值要留在首位
            options[key] = [FOLLOW] + list(dict.fromkeys(values))
    return options


def render(text, name, values):
    begin, end = f"# <sync-form:{name}>", f"# </sync-form:{name}>"
    lines = text.splitlines()
    try:
        start = next(i for i, line in enumerate(lines) if line.strip() == begin)
        stop = next(i for i, line in enumerate(lines) if line.strip() == end)
    except StopIteration:
        raise SystemExit(f"begonia.yml 里找不到 {begin} / {end} 标记")
    indent = lines[start][: len(lines[start]) - len(lines[start].lstrip())]
    body = [f"{indent}- {value}" for value in values]
    text = "\n".join(lines[: start + 1] + body + lines[stop:])
    return text + "\n"


def main():
    options = load_options()
    original = WORKFLOW.read_text(encoding="utf-8")
    updated = original
    for name in GENERATED:
        updated = render(updated, name, options[name])

    if updated == original:
        print("begonia.yml 的 options 已与 JSON 一致")
        return 0
    if "--check" in sys.argv[1:]:
        print("begonia.yml 的 options 与 recovery-profiles.json 不一致，请运行 sync-form.py", file=sys.stderr)
        return 1
    WORKFLOW.write_text(updated, encoding="utf-8")
    print("已按 recovery-profiles.json 更新 begonia.yml 的 options")
    return 0


if __name__ == "__main__":
    sys.exit(main())
