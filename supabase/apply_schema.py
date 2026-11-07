#!/usr/bin/env python3
"""Apply supabase/schema.sql using Neon DATABASE_URL from env.local."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
ENV_FILE = ROOT / "env.local"
SCHEMA = ROOT / "schema.sql"


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
            "请在 supabase/env.local 填写 Neon 的 DATABASE_URL\n"
            "例: postgresql://user:pass@ep-xxxx.region.aws.neon.tech/neondb?sslmode=require"
        )
    if "supabase.co" in dsn:
        print(
            "警告: 当前 DATABASE_URL 仍指向 Supabase。"
            "国内访问 HTTPS/部分链路不稳；建议改成 Neon 连接串。",
            file=sys.stderr,
        )

    sql = SCHEMA.read_text(encoding="utf-8")
    try:
        import psycopg2
    except ImportError:
        print("正在安装 psycopg2-binary …")
        import subprocess

        subprocess.check_call(
            [sys.executable, "-m", "pip", "install", "psycopg2-binary", "-q"]
        )
        import psycopg2

    print("连接数据库并执行 schema.sql …")
    conn = psycopg2.connect(dsn)
    conn.autocommit = True
    try:
        with conn.cursor() as cur:
            cur.execute(sql)
        print("OK: schema.sql 已执行完成（Neon/Postgres）")
    finally:
        conn.close()

    print()
    print("下一步：确认 env.local 里 SYNC_OWNER_ID / SYNC_ENABLED，然后:")
    print("  .\\build_apk.ps1 -Install")


if __name__ == "__main__":
    main()
