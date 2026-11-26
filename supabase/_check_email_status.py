# -*- coding: utf-8 -*-
"""查询指定邮箱在 auth.users 中的确认状态（不打印密钥）。"""
from __future__ import annotations

import os
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
ENV = ROOT / "env.local"
EMAIL = (sys.argv[1] if len(sys.argv) > 1 else "qqmmgg123@gmail.com").strip().lower()


def load_env() -> None:
    if not ENV.exists():
        raise SystemExit(f"missing {ENV}")
    for line in ENV.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        k, v = k.strip(), v.strip().strip('"').strip("'")
        if k and k not in os.environ:
            os.environ[k] = v


def main() -> None:
    load_env()
    db = os.environ.get("DATABASE_URL", "").strip()
    if not db:
        raise SystemExit("DATABASE_URL not set")

    try:
        import psycopg2
    except ImportError:
        import subprocess

        subprocess.check_call(
            [sys.executable, "-m", "pip", "install", "psycopg2-binary", "-q"]
        )
        import psycopg2

    conn = psycopg2.connect(db)
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT
                  id::text,
                  email,
                  email_confirmed_at,
                  created_at,
                  last_sign_in_at,
                  banned_until,
                  (email_confirmed_at IS NOT NULL) AS is_confirmed
                FROM auth.users
                WHERE lower(email) = %s
                ORDER BY created_at DESC
                LIMIT 5
                """,
                (EMAIL,),
            )
            rows = cur.fetchall()
    finally:
        conn.close()

    print(f"query_email={EMAIL}")
    if not rows:
        print("result=NOT_FOUND")
        print("meaning=该邮箱不在 auth.users 中（未注册或已删除）")
        return

    for i, r in enumerate(rows, 1):
        uid, email, confirmed_at, created_at, last_sign_in, banned, is_confirmed = r
        print(f"--- user#{i} ---")
        print(f"id={uid}")
        print(f"email={email}")
        print(f"is_confirmed={'YES' if is_confirmed else 'NO'}")
        print(f"email_confirmed_at={confirmed_at}")
        print(f"created_at={created_at}")
        print(f"last_sign_in_at={last_sign_in}")
        print(f"banned_until={banned}")
        if is_confirmed:
            print("meaning=已验证：再次注册不会再发确认邮件，应直接登录或走忘记密码")
        else:
            print("meaning=未验证：应能重发 signup 验证码；若收不到是发信/限流问题")


if __name__ == "__main__":
    main()
