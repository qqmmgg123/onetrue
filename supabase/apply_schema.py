#!/usr/bin/env python3
"""Apply supabase/schema*.sql using DATABASE_URL from env.local."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
ENV_FILE = ROOT / "env.local"
SCHEMAS = [
    ROOT / "schema.sql",
    ROOT / "schema_social.sql",
    ROOT / "schema_feedback.sql",
    ROOT / "schema_reads.sql",
    ROOT / "schema_articles_public.sql",
    ROOT / "schema_admonition.sql",
    ROOT / "schema_article_availability.sql",
    ROOT / "schema_note_cover.sql",
    ROOT / "schema_note_pin_complete.sql",
    ROOT / "schema_notif_actor_select.sql",
    ROOT / "schema_notif_owner_delete.sql",
]


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


def main() -> None:
    env = load_env(ENV_FILE)
    dsn = env.get("DATABASE_URL", "").strip()
    if not dsn:
        raise SystemExit(
            "请在 supabase/env.local 填写 migrate 用 DATABASE_URL（勿 bake 进 App）\n"
            "Supabase: Dashboard → Database → Connection string"
        )

    try:
        import psycopg2
    except ImportError:
        print("正在安装 psycopg2-binary …")
        import subprocess

        subprocess.check_call(
            [sys.executable, "-m", "pip", "install", "psycopg2-binary", "-q"]
        )
        import psycopg2

    print("连接数据库 …")
    conn = psycopg2.connect(dsn)
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            for path in SCHEMAS:
                if not path.exists():
                    print(f"SKIP missing {path.name}")
                    continue
                print(f"执行 {path.name} …")
                cur.execute(path.read_text(encoding="utf-8"))
                print(f"OK: {path.name}")
    finally:
        conn.close()

    print()
    print("下一步：打包 .\\build_apk.ps1 -Install")


if __name__ == "__main__":
    main()
