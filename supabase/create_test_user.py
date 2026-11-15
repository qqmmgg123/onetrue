#!/usr/bin/env python3
"""Create a confirmed email+password user in Supabase Auth (migrate machine only)."""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
ENV_FILE = ROOT / "env.local"

# 测试号（可改）
EMAIL = "290448666@qq.com"
PASSWORD = "Test123456"


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
    dsn = (env.get("DATABASE_URL") or "").strip()
    if not dsn:
        raise SystemExit("请在 supabase/env.local 填写 DATABASE_URL")

    try:
        import psycopg2
        from psycopg2.extras import RealDictCursor
    except ImportError:
        import subprocess

        subprocess.check_call(
            [sys.executable, "-m", "pip", "install", "psycopg2-binary", "-q"]
        )
        import psycopg2
        from psycopg2.extras import RealDictCursor

    conn = psycopg2.connect(dsn)
    conn.autocommit = True
    try:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(
                "select id, email, email_confirmed_at is not null as confirmed "
                "from auth.users where lower(email) = lower(%s)",
                (EMAIL,),
            )
            row = cur.fetchone()
            if row:
                user_id = str(row["id"])
                cur.execute(
                    """
                    update auth.users
                    set encrypted_password = crypt(%s, gen_salt('bf')),
                        email_confirmed_at = coalesce(email_confirmed_at, now()),
                        updated_at = now()
                    where id = %s::uuid
                    """,
                    (PASSWORD, user_id),
                )
                # 确保有 email identity（新项目登录需要）
                cur.execute(
                    """
                    insert into auth.identities (
                      id, user_id, identity_data, provider, provider_id,
                      last_sign_in_at, created_at, updated_at
                    )
                    select
                      gen_random_uuid(),
                      u.id,
                      jsonb_build_object(
                        'sub', u.id::text,
                        'email', u.email,
                        'email_verified', true
                      ),
                      'email',
                      u.id::text,
                      now(), now(), now()
                    from auth.users u
                    where u.id = %s::uuid
                      and not exists (
                        select 1 from auth.identities i
                        where i.user_id = u.id and i.provider = 'email'
                      )
                    """,
                    (user_id,),
                )
                print(f"UPDATED existing user id={user_id} email={EMAIL}")
                cur.execute(
                    """
                    insert into public.profiles (id, nickname, avatar_url, updated_at)
                    values (%s::uuid, %s, '', now())
                    on conflict (id) do update
                      set nickname = excluded.nickname,
                          updated_at = now()
                    """,
                    (user_id, "醍醐测试"),
                )
                print("UPSERT profile nickname=醍醐测试")
            else:
                cur.execute(
                    """
                    with u as (
                      insert into auth.users (
                        instance_id, id, aud, role, email, encrypted_password,
                        email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                        created_at, updated_at,
                        confirmation_token, recovery_token,
                        email_change_token_new, email_change
                      ) values (
                        '00000000-0000-0000-0000-000000000000',
                        gen_random_uuid(),
                        'authenticated', 'authenticated',
                        %s, crypt(%s, gen_salt('bf')),
                        now(),
                        '{"provider":"email","providers":["email"]}'::jsonb,
                        '{}'::jsonb,
                        now(), now(),
                        '', '', '', ''
                      )
                      returning id, email
                    ),
                    i as (
                      insert into auth.identities (
                        id, user_id, identity_data, provider, provider_id,
                        last_sign_in_at, created_at, updated_at
                      )
                      select
                        gen_random_uuid(),
                        u.id,
                        jsonb_build_object(
                          'sub', u.id::text,
                          'email', u.email,
                          'email_verified', true
                        ),
                        'email',
                        u.id::text,
                        now(), now(), now()
                      from u
                      returning user_id
                    )
                    select u.id::text as id, u.email from u
                    """,
                    (EMAIL, PASSWORD),
                )
                created = cur.fetchone()
                user_id = created["id"]
                print(f"CREATED user id={user_id} email={EMAIL}")
                cur.execute(
                    """
                    insert into public.profiles (id, nickname, avatar_url, updated_at)
                    values (%s::uuid, %s, '', now())
                    on conflict (id) do update
                      set nickname = excluded.nickname,
                          updated_at = now()
                    """,
                    (user_id, "醍醐测试"),
                )
                print("UPSERT profile nickname=醍醐测试")
    finally:
        conn.close()

    print(f"password={PASSWORD}")
    print("App 请用「邮箱 + 密码」登录（勿再依赖 OTP）。")


if __name__ == "__main__":
    main()
