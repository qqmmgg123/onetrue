#!/usr/bin/env python3
"""Apply supabase/schema.sql using DATABASE_URL or URL+DB password."""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path
from urllib.parse import quote_plus, urlparse

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


def build_dsn(env: dict[str, str]) -> str:
    if env.get("DATABASE_URL"):
        return env["DATABASE_URL"]
    url = env.get("SUPABASE_URL", "").rstrip("/")
    password = env.get("SUPABASE_DB_PASSWORD", "")
    if not url or not password:
        raise SystemExit(
            "请在 supabase/env.local 填写 DATABASE_URL，"
            "或同时填写 SUPABASE_URL + SUPABASE_DB_PASSWORD"
        )
    # https://xxxx.supabase.co → xxxx
    host = urlparse(url).hostname or ""
    m = re.match(r"^([a-z0-9]+)\.supabase\.co$", host)
    if not m:
        raise SystemExit(f"无法从 SUPABASE_URL 解析项目 ref: {url}")
    ref = m.group(1)
    user = "postgres"
    # Direct connection
    return (
        f"postgresql://{user}:{quote_plus(password)}"
        f"@db.{ref}.supabase.co:5432/postgres"
        f"?sslmode=require"
    )


def main() -> None:
    env = load_env(ENV_FILE)
    dsn = build_dsn(env)
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
        print("OK: schema.sql 已执行完成")
    finally:
        conn.close()

    # 顺带写出给 App 用的提示（不含密码）
    url = env.get("SUPABASE_URL", "")
    anon = env.get("SUPABASE_ANON_KEY", "")
    if url and anon:
        print()
        print("App「对话设置」可填：")
        print(f"  Project URL = {url}")
        print(f"  anon key    = {anon[:12]}…（已配置在 env.local）")


if __name__ == "__main__":
    main()
