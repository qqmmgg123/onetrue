#!/usr/bin/env python3
"""Read supabase/env.local → supabase/dart_defines.json for Flutter --dart-define-from-file."""

from __future__ import annotations

import json
import sys
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
ENV_FILE = ROOT / "supabase" / "env.local"
OUT_FILE = ROOT / "supabase" / "dart_defines.json"

# App 会打进 APK 的键（正式版优先只 bake SUPABASE_*；LLM/ASR Key 应走 Edge）
APP_KEYS = {
    "SUPABASE_URL",
    "SUPABASE_ANON_KEY",
    "LLM_PROVIDER",
    "LLM_BASE_URL",
    "LLM_API_KEY",
    "LLM_MODEL",
    "USE_LLM",
    "ZHIPU_CHAT_MODEL",
    "BAIDU_LLM_API_KEY",
    "BAIDU_LLM_BASE_URL",
    "BAIDU_LLM_MODEL",
    "SILICON_CHAT_MODEL",
    "ONE_API_BASE_URL",
    "ONE_API_KEY",
    "ONE_API_MODEL",
    "BAIDU_ASR_API_KEY",
    "BAIDU_ASR_SECRET_KEY",
    "GROQ_API_KEY",
    "GROQ_BASE_URL",
    "GROQ_ASR_MODEL",
    "ASR_BASE_URL",
    "ASR_API_KEY",
    "ASR_MODEL",
    "USE_CLOUD_ASR",
    "GEMINI_API_KEY",
    "GEMINI_VISION_MODEL",
    "ZHIPU_API_KEY",
    "ZHIPU_BASE_URL",
    "ZHIPU_VISION_MODEL",
    "DEEPSEEK_VISION_MODEL",
    "VISION_BASE_URL",
    "VISION_API_KEY",
    "VISION_MODELS",
    "SYNC_OWNER_ID",
    "SYNC_ENABLED",
    "QINIU_ACCESS_KEY",
    "QINIU_SECRET_KEY",
    "QINIU_BUCKET",
    "QINIU_PUBLIC_BASE",
    "QINIU_UPLOAD_HOST",
    "QINIU_PIPELINE",
    "R2_ACCOUNT_ID",
    "R2_ACCESS_KEY_ID",
    "R2_SECRET_ACCESS_KEY",
    "R2_BUCKET",
    "R2_PUBLIC_BASE",
    "SHARE_WEB_BASE",
    "APP_DOWNLOAD_URL",
    "APP_DOWNLOAD_HINT",
    "APP_UPDATE_MANIFEST_URL",
    "WECHAT_APP_ID",
    "WECHAT_UNIVERSAL_LINK",
}

BOOL_KEYS = {"USE_LLM", "USE_CLOUD_ASR", "SYNC_ENABLED"}
SECRET_KEYS = {
    "SUPABASE_ANON_KEY",
    "LLM_API_KEY",
    "BAIDU_LLM_API_KEY",
    "ONE_API_KEY",
    "BAIDU_ASR_API_KEY",
    "BAIDU_ASR_SECRET_KEY",
    "GROQ_API_KEY",
    "ASR_API_KEY",
    "GEMINI_API_KEY",
    "ZHIPU_API_KEY",
    "VISION_API_KEY",
    "QINIU_ACCESS_KEY",
    "QINIU_SECRET_KEY",
    "R2_SECRET_ACCESS_KEY",
    "R2_ACCESS_KEY_ID",
}


def load_env(path: Path) -> dict[str, str]:
    data: dict[str, str] = {}
    if not path.exists():
        return data
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        data[k.strip()] = v.strip().strip('"').strip("'")
    return data


def to_bool_str(v: str) -> str:
    return "true" if v.strip().lower() in ("1", "true", "yes", "on") else "false"


def main() -> int:
    env = load_env(ENV_FILE)
    if not env:
        print(f"未找到或为空: {ENV_FILE}", file=sys.stderr)
        print("请复制 supabase/env.example 为 env.local 并填写。", file=sys.stderr)
        return 1

    # 兼容误写的公开域名键名
    if not env.get("R2_PUBLIC_BASE") and env.get("R2_PUBLIC_BASE_URL"):
        env["R2_PUBLIC_BASE"] = env["R2_PUBLIC_BASE_URL"]
        print("提示: 已将 R2_PUBLIC_BASE_URL 映射为 R2_PUBLIC_BASE")
    if not env.get("QINIU_PUBLIC_BASE") and env.get("QINIU_PUBLIC_BASE_URL"):
        env["QINIU_PUBLIC_BASE"] = env["QINIU_PUBLIC_BASE_URL"]
        print("提示: 已将 QINIU_PUBLIC_BASE_URL 映射为 QINIU_PUBLIC_BASE")
    # 七牛测试域名 https 证书常 Hostname mismatch，打包时改成 http
    qpb = env.get("QINIU_PUBLIC_BASE", "")
    if qpb.startswith("https://") and (
        ".clouddn.com" in qpb or ".qiniudn.com" in qpb or ".qnssl.com" in qpb
    ):
        env["QINIU_PUBLIC_BASE"] = "http://" + qpb[len("https://") :]
        print("提示: 七牛测试域名已改为 http（https 证书通常不匹配）")
        qpb = env["QINIU_PUBLIC_BASE"]

    # 分享页 / meta 下载链：未填时默认指向七牛覆盖发布的 APK
    if not env.get("APP_DOWNLOAD_URL", "").strip() and qpb.strip():
        env["APP_DOWNLOAD_URL"] = qpb.strip().rstrip("/") + "/app/rent_agent.apk"
        print(f"提示: APP_DOWNLOAD_URL 默认 -> {env['APP_DOWNLOAD_URL']}")

    defines: dict[str, str] = {}
    for key in sorted(APP_KEYS):
        if key not in env or env[key] == "":
            continue
        val = env[key]
        defines[key] = to_bool_str(val) if key in BOOL_KEYS else val
        if "&" in defines[key] and key not in BOOL_KEYS:
            print(
                f"警告: {key} 仍含 '&'，Windows 打包可能失败；请去掉多余查询参数。",
                file=sys.stderr,
            )

    OUT_FILE.write_text(
        json.dumps(defines, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    def mask(k: str, v: str) -> str:
        if k in BOOL_KEYS or k.endswith("_URL"):
            return v
        if k.endswith("_MODEL") or k == "SYNC_OWNER_ID":
            return v
        if k in SECRET_KEYS:
            if len(v) <= 8:
                return "***"
            return v[:4] + "…" + v[-4:]
        return v

    print(f"已写入 {OUT_FILE.relative_to(ROOT)}（{len(defines)} 项将打进 APK）:")
    for k, v in sorted(defines.items()):
        print(f"  {k}={mask(k, v)}")
    skip = sorted(APP_KEYS - set(defines))
    if skip:
        print("未设置（安装包内为空）:", ", ".join(skip))
    if not defines.get("SUPABASE_URL") or not defines.get("SUPABASE_ANON_KEY"):
        print(
            "警告: 未设置 SUPABASE_URL / SUPABASE_ANON_KEY，App 无法登录与同步。",
            file=sys.stderr,
        )
    if env.get("DATABASE_URL", "").strip():
        print("提示: DATABASE_URL 仅供 apply_schema.py，不会写入 dart_defines。")
    llm_keys = (
        "LLM_API_KEY",
        "ZHIPU_API_KEY",
        "BAIDU_LLM_API_KEY",
        "ASR_API_KEY",
        "ONE_API_KEY",
    )
    baked_llm = [k for k in llm_keys if k in defines]
    if baked_llm:
        print(
            "提示: 仍 bake 了上游 Key（"
            + ", ".join(baked_llm)
            + "）；正式分发请改 Edge secrets 并清空这些项。"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
