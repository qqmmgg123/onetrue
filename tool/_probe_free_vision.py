#!/usr/bin/env python3
"""Probe which free SiliconFlow vision models work with env.local key."""
from __future__ import annotations

import base64
import json
import struct
import urllib.error
import urllib.request
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load_env(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        data[k.strip()] = v.strip().strip('"').strip("'")
    return data


def tiny_png() -> bytes:
    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    # 128x64 light gray — above tiny-image limits some OCR APIs enforce
    w, h = 128, 64
    raw = b"".join(b"\x00" + bytes((220, 220, 220)) * w for _ in range(h))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


def try_model(base: str, key: str, model: str, b64: str, prompt: str) -> None:
    body = {
        "model": model,
        "max_tokens": 256,
        "temperature": 0.1,
        "messages": [
            {
                "role": "user",
                "content": [
                    {
                        "type": "image_url",
                        "image_url": {"url": f"data:image/png;base64,{b64}"},
                    },
                    {"type": "text", "text": prompt},
                ],
            }
        ],
    }
    req = urllib.request.Request(
        base.rstrip("/") + "/chat/completions",
        data=json.dumps(body).encode(),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {key}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=90) as res:
            data = json.loads(res.read().decode("utf-8", "replace"))
        content = data.get("choices", [{}])[0].get("message", {}).get("content")
        print(f"OK  {model}")
        print(f"    {str(content)[:160]!r}")
    except urllib.error.HTTPError as e:
        err = e.read().decode("utf-8", "replace")
        print(f"ERR {model} HTTP {e.code} {err[:220]}")
    except Exception as e:
        print(f"ERR {model} {type(e).__name__}: {e}")


def main() -> None:
    env = load_env(ROOT / "supabase" / "env.local")
    key = env.get("ASR_API_KEY", "")
    base = env.get("ASR_BASE_URL", "https://api.siliconflow.cn/v1")
    defines = ROOT / "supabase" / "dart_defines.json"
    if defines.exists():
        d = json.loads(defines.read_text(encoding="utf-8"))
        print("dart_defines VISION_MODELS=", d.get("VISION_MODELS", "<missing>"))
        print("dart_defines ASR_API_KEY tail=", (d.get("ASR_API_KEY") or "")[-4:])
    print("env VISION_MODELS=", env.get("VISION_MODELS", "<missing>"))
    b64 = base64.b64encode(tiny_png()).decode()

    models = [
        ("deepseek-ai/DeepSeek-OCR", "Free OCR."),
        (
            "deepseek-ai/DeepSeek-OCR",
            "Free OCR.\n用中文输出电表读数。用户要求：帮我读电表录入201",
        ),
        ("PaddlePaddle/PaddleOCR-VL-1.5", "请用中文读出图中文字与数字"),
        ("PaddlePaddle/PaddleOCR-VL", "请用中文读出图中文字与数字"),
        ("THUDM/GLM-4.1V-9B-Thinking", "用中文一句话描述图片"),
        ("deepseek-ai/deepseek-vl2-small", "用中文一句话描述图片"),
        ("deepseek-ai/deepseek-vl2", "用中文一句话描述图片"),
        ("OpenGVLab/InternVL2-8B", "用中文一句话描述图片"),
        ("openbmb/MiniCPM-V-2_6", "用中文一句话描述图片"),
    ]
    for model, prompt in models:
        try_model(base, key, model, b64, prompt)


if __name__ == "__main__":
    main()
