#!/usr/bin/env python3
"""Promote a user to is_admin using DATABASE_URL / ADMIN_EMAIL from env.local."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
ENV_FILE = ROOT / "env.local"


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
        raise SystemExit("缺少 DATABASE_URL")
    admin_email = (
        env.get("ADMIN_EMAIL") or env.get("ADMIN_USER_EMAIL") or ""
    ).strip().lower()

    import psycopg2

    conn = psycopg2.connect(dsn)
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute(
        """
        select u.id::text, coalesce(u.email, ''), coalesce(p.is_admin, false)
        from auth.users u
        left join public.profiles p on p.id = u.id
        order by u.created_at nulls last
        limit 50
        """
    )
    rows = cur.fetchall()
    print("users:", len(rows))
    for uid, email, is_admin in rows:
        print(f"  {uid[:8]}…  {email or '(no email)'}  admin={is_admin}")

    target = None
    if admin_email:
        for uid, email, _ in rows:
            if email.lower() == admin_email:
                target = (uid, email)
                break
        if not target:
            raise SystemExit(f"未找到 ADMIN_EMAIL={admin_email}")
    elif len(rows) == 1:
        target = (rows[0][0], rows[0][1])
    else:
        for uid, email, _ in rows:
            if email:
                target = (uid, email)
                break
        if not target and rows:
            target = (rows[0][0], rows[0][1])

    if not target:
        raise SystemExit("没有可提升的用户")

    uid, email = target
    cur.execute(
        """
        insert into public.profiles (id, nickname, updated_at)
        values (%s, '', now())
        on conflict (id) do nothing
        """,
        (uid,),
    )
    cur.execute(
        "update public.profiles set is_admin = true where id = %s",
        (uid,),
    )
    print(f"SET ADMIN: {email or uid}")
    conn.close()


if __name__ == "__main__":
    main()
