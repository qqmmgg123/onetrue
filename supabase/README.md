# Supabase（Singapore）+ Email OTP + RLS

App 通过 **Supabase Auth（邮箱 OTP）** 登录，用 **PostgREST + RLS** 同步 `notes`；
大模型 / ASR / 识图走 **Edge Functions**，密钥放 secrets，不进 APK。

## 步骤

1. 在 [supabase.com](https://supabase.com) 新建项目，区域选 **Singapore**（或就近）
2. Authentication → Providers → **Email** 开启；注册需邮箱确认时打开 Confirm email + OTP  
   - **国内收信/短信**：见 [`AUTH_CN.md`](./AUTH_CN.md)（阿里云邮件推送 / 腾讯云 SES；短信可选）
3. 复制 Project URL、`anon` `public` key 到 `supabase/env.local`：
   - `SUPABASE_URL`
   - `SUPABASE_ANON_KEY`
4. Database → 连接串（migrate 机）填 `DATABASE_URL`（**不要** bake 进 App）
5. 建表 + RLS（含 notes / 社交 / feedback）：
   ```powershell
   python supabase/apply_schema.py
   ```
6. 部署 Edge stubs（并 `supabase secrets set` 上游 Key）：
   ```powershell
   supabase functions deploy llm-chat
   supabase functions deploy asr-transcribe
   supabase functions deploy vision-understand
   ```
7. 打包：
   ```powershell
   .\build_apk.ps1 -Install
   ```

## 说明

- APK 只应含 `SUPABASE_URL` + `SUPABASE_ANON_KEY`（公开）；**禁止** `service_role` / `DATABASE_URL` / 上游 LLM Key
- 行级安全：`notes.owner_id = auth.uid()`；已上架 `article` 可对 anon/authenticated 只读
- 多端：同一邮箱 OTP 登录即可同步（owner = Auth `user.id`）
- 旧 Neon 直连 / `postgres` Dart 包已从 App 运行时移除；`apply_schema.py` 仍用 Python `psycopg2`

## 同步范围

仅 `notes`（市集浏览含 `note_stats` 阅读数）。房源/租约表不再同步。
