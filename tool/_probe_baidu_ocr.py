import base64
import json
import struct
import urllib.parse
import urllib.request
import zlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


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


def png(w: int, h: int, rgb=(255, 255, 255)) -> bytes:
    def chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    raw = b"".join(b"\x00" + bytes(rgb) * w for _ in range(h))
    return (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw))
        + chunk(b"IEND", b"")
    )


def main() -> None:
    env = load_env(ROOT / "supabase" / "env.local")
    ak = env.get("BAIDU_ASR_API_KEY", "")
    sk = env.get("BAIDU_ASR_SECRET_KEY", "")
    print(f"env AK={ak[:4]}...{ak[-4:]} len={len(ak)}")

    tok_url = "https://aip.baidubce.com/oauth/2.0/token?" + urllib.parse.urlencode(
        {
            "grant_type": "client_credentials",
            "client_id": ak,
            "client_secret": sk,
        }
    )
    tok = json.load(urllib.request.urlopen(tok_url, timeout=20))
    token = tok["access_token"]
    img = base64.b64encode(png(64, 64)).decode()

    for path in [
        "rest/2.0/ocr/v1/general_basic",
        "rest/2.0/ocr/v1/accurate_basic",
    ]:
        url = f"https://aip.baidubce.com/{path}?access_token={token}"
        data = urllib.parse.urlencode(
            {
                "image": img,
                "language_type": "CHN_ENG",
                "detect_direction": "true",
            }
        ).encode()
        req = urllib.request.Request(
            url,
            data=data,
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        body = json.load(urllib.request.urlopen(req, timeout=30))
        print(
            path,
            "error_code=",
            body.get("error_code"),
            "error_msg=",
            body.get("error_msg"),
            "words_result_num=",
            body.get("words_result_num"),
        )

    defines = ROOT / "supabase" / "dart_defines.json"
    if defines.exists():
        d = json.loads(defines.read_text(encoding="utf-8"))
        bak = d.get("BAIDU_ASR_API_KEY", "")
        print(
            "dart_defines AK=",
            (f"{bak[:4]}...{bak[-4:]}" if bak else "EMPTY"),
            "match_env=",
            bak == ak,
        )
    else:
        print("dart_defines.json missing")


if __name__ == "__main__":
    main()
