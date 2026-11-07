#!/usr/bin/env python3
"""Probe SiliconFlow vision models with env.local ASR key."""
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


def png(w: int = 64, h: int = 64) -> bytes:
    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    raw = b"".join(b"\x00" + bytes((240, 240, 240)) * w for _ in range(h))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


def chat(base: str, key: str, model: str, b64: str) -> None:
    url = base.rstrip("/") + "/chat/completions"
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
                    {"type": "text", "text": "用中文一句话描述这张图。"},
                ],
            }
        ],
    }
    req = urllib.request.Request(
        url,
        data=json.dumps(body).encode(),
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {key}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as res:
            raw = res.read().decode("utf-8", "replace")
        data = json.loads(raw)
        content = data.get("choices", [{}])[0].get("message", {}).get("content")
        print(f"OK  {model}")
        print(f"    => {str(content)[:120]!r}")
    except urllib.error.HTTPError as e:
        err = e.read().decode("utf-8", "replace")
        print(f"ERR {model} HTTP {e.code}")
        print(f"    {err[:300]}")
    except Exception as e:
        print(f"ERR {model} {e}")


def main() -> None:
    env = load_env(ROOT / "supabase" / "env.local")
    key = env.get("ASR_API_KEY") or env.get("VISION_API_KEY") or ""
    base = env.get("VISION_BASE_URL") or env.get("ASR_BASE_URL") or "https://api.siliconflow.cn/v1"
    print("base=", base, "key_tail=", key[-4:] if key else "EMPTY")
    b64 = base64.b64encode(png()).decode()
    models = [
        "deepseek-ai/DeepSeek-OCR",
        "PaddlePaddle/PaddleOCR-VL-1.5",
        "deepseek-ai/deepseek-vl2",
        "Qwen/Qwen2-VL-72B-Instruct",
        "Pro/Qwen/Qwen2.5-VL-7B-Instruct",
        "Qwen/Qwen2.5-VL-7B-Instruct",
        "Qwen/Qwen3-VL-8B-Instruct",
        "THUDM/GLM-4.1V-9B-Thinking",
    ]
    for m in models:
        chat(base, key, m, b64)


if __name__ == "__main__":
    main()
