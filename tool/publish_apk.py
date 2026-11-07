#!/usr/bin/env python3
"""Upload release APK + version.json to Qiniu (fallback R2 not implemented here).

Usage:
  python tool/publish_apk.py --apk build/app/outputs/flutter-apk/app-release.apk
  python tool/publish_apk.py --apk ... --changelog "修复视频更新"
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENV_FILE = ROOT / "supabase" / "env.local"
PUBSPEC = ROOT / "pubspec.yaml"


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


def parse_pubspec_version(path: Path) -> tuple[str, int]:
    text = path.read_text(encoding="utf-8")
    m = re.search(r"^version:\s*([^\s#]+)", text, re.M)
    if not m:
        raise SystemExit("pubspec.yaml 缺少 version")
    raw = m.group(1).strip()
    if "+" in raw:
        name, code = raw.split("+", 1)
    else:
        name, code = raw, "1"
    return name.strip(), int(code.strip())


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode("ascii")


def qiniu_upload_token(ak: str, sk: str, bucket: str, key: str, ttl: int = 3600) -> str:
    deadline = int(time.time()) + ttl
    policy = json.dumps(
        {"scope": f"{bucket}:{key}", "deadline": deadline},
        separators=(",", ":"),
    ).encode("utf-8")
    encoded = b64url(policy)
    sign = hmac.new(sk.encode("utf-8"), encoded.encode("utf-8"), hashlib.sha1).digest()
    return f"{ak}:{b64url(sign)}:{encoded}"


def qiniu_put_file(
    *,
    ak: str,
    sk: str,
    bucket: str,
    upload_host: str,
    key: str,
    file_path: Path,
    content_type: str,
) -> None:
    token = qiniu_upload_token(ak, sk, bucket, key)
    host = upload_host if "://" in upload_host else f"https://{upload_host}"
    boundary = f"----RentAgent{int(time.time())}"
    body = bytearray()

    def add_field(name: str, value: str) -> None:
        body.extend(f"--{boundary}\r\n".encode())
        body.extend(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        body.extend(value.encode("utf-8"))
        body.extend(b"\r\n")

    add_field("token", token)
    add_field("key", key)

    data = file_path.read_bytes()
    filename = file_path.name
    body.extend(f"--{boundary}\r\n".encode())
    body.extend(
        f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'.encode()
    )
    body.extend(f"Content-Type: {content_type}\r\n\r\n".encode())
    body.extend(data)
    body.extend(f"\r\n--{boundary}--\r\n".encode())

    req = urllib.request.Request(
        host.rstrip("/") + "/",
        data=bytes(body),
        method="POST",
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=600) as res:
            if res.status < 200 or res.status >= 300:
                raise SystemExit(f"上传失败 HTTP {res.status}: {res.read()[:500]!r}")
    except urllib.error.HTTPError as e:
        raise SystemExit(f"上传失败 HTTP {e.code}: {e.read()[:800]!r}") from e


def normalize_public_base(raw: str) -> str:
    s = raw.strip().rstrip("/")
    if s.startswith("https://") and (
        ".clouddn.com" in s or ".qiniudn.com" in s or ".qnssl.com" in s
    ):
        return "http://" + s[len("https://") :]
    return s


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apk", required=True, type=Path)
    ap.add_argument(
        "--changelog",
        default="",
        help="更新说明，会显示在 App 强制更新弹窗里",
    )
    ap.add_argument(
        "--force",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="强制更新（默认开启；--no-force 才允许跳过）",
    )
    args = ap.parse_args()

    apk: Path = args.apk
    if not apk.is_file():
        print(f"找不到 APK: {apk}", file=sys.stderr)
        return 1

    env = load_env(ENV_FILE)
    ak = env.get("QINIU_ACCESS_KEY", "").strip()
    sk = env.get("QINIU_SECRET_KEY", "").strip()
    bucket = env.get("QINIU_BUCKET", "").strip()
    public = normalize_public_base(env.get("QINIU_PUBLIC_BASE", ""))
    upload_host = env.get("QINIU_UPLOAD_HOST", "https://upload.qiniup.com").strip()
    if not (ak and sk and bucket and public):
        print("env.local 缺少七牛 QINIU_ACCESS_KEY/SECRET_KEY/BUCKET/PUBLIC_BASE", file=sys.stderr)
        return 1

    version_name, version_code = parse_pubspec_version(PUBSPEC)
    # 固定 key 覆盖上传：七牛只占一份 APK + 一份清单，不攒历史包
    apk_key = "app/rent_agent.apk"
    manifest_key = "app/version.json"

    print(f"==> 版本 {version_name}+{version_code}")
    print(f"==> 覆盖上传 {apk_key} ({apk.stat().st_size / 1024 / 1024:.1f} MB)")
    qiniu_put_file(
        ak=ak,
        sk=sk,
        bucket=bucket,
        upload_host=upload_host,
        key=apk_key,
        file_path=apk,
        content_type="application/vnd.android.package-archive",
    )

    # ?v=versionCode 逼 CDN/客户端别一直用旧包缓存
    apk_url = f"{public}/{apk_key}?v={version_code}"
    manifest = {
        "versionCode": version_code,
        "versionName": version_name,
        "apkUrl": apk_url,
        "force": bool(args.force),
        "changelog": (args.changelog or "").strip()
        or "请更新到最新版本以保持功能一致。",
        "publishedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    tmp = ROOT / "build" / "app_version.json"
    tmp.parent.mkdir(parents=True, exist_ok=True)
    tmp.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"==> 覆盖上传 {manifest_key}")
    qiniu_put_file(
        ak=ak,
        sk=sk,
        bucket=bucket,
        upload_host=upload_host,
        key=manifest_key,
        file_path=tmp,
        content_type="application/json; charset=utf-8",
    )

    print("发布完成（仅保留最新一份 APK）：")
    print(f"  manifest: {public}/{manifest_key}")
    print(f"  apk:      {apk_url}")
    print("手机端会在 Wi‑Fi 下后台下载，完成后提示安装。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
